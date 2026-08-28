# Architecture decisions & open follow-ups

Running log for this repo (the Home Assistant **add-on**). The companion
Assist integration lives in a separate sibling repo,
`ha-zeroclaw-conversation` — see its own `docs/DECISIONS.md` there.

## Why two repos

`app-*`/`addon-*` repos in the hassio-addons convention are one-add-on-per-repo
(Docker image + `config.yaml`, installed via the HA Add-on Store). The Assist
conversation agent is a *different* HA extension mechanism — Python code
loaded into HA core (`custom_components/`), typically distributed via HACS.
Mixing both in one repo would work technically but breaks the "one add-on per
repo" convention this repo otherwise follows for submission-quality. Decided
2026-08-25, user-confirmed.

## Why wrap ghcr.io/zeroclaw-labs/zeroclaw instead of building from source

ZeroClaw's own build (Rust + a Vite web dashboard, cross-compiled to
aarch64) is substantial and moves with upstream releases. Re-implementing it
inside a `hassio-addons/base` Alpine image would fork us from upstream
immediately and need re-syncing on every ZeroClaw release. Instead we lift
the finished artifacts out of ZeroClaw's own published image via multi-stage
`COPY --from=`.

The plan originally assumed a `ghcr.io/zeroclaw-labs/zeroclaw:*-debian` tag
existed (based on a comment in ZeroClaw's `docker-compose.yml`). Checking
ZeroClaw's actual CI (`dev/ci/docker-tags.toml`,
`.github/workflows/docker-publish.yml`) showed the **only tags that are
actually published** are `minimal`, `default-features`, `dist`,
`all-features` (+ pinned `-vX.Y.Z` variants), and **all of them build from
the distroless final stage** (no shell; `all-features` is amd64-only). Fixed
by using `ghcr.io/zeroclaw-labs/zeroclaw:dist-v0.8.4` (multi-arch, broadest
channel set among the multi-arch tags) as a `COPY --from=` source stage,
landing the binary + web dashboard assets into a normal `debian:trixie-slim`
final stage that has a shell for the bootstrap script. See `Dockerfile`.

Bump `ARG ZEROCLAW_IMAGE_TAG` on new ZeroClaw releases
(https://github.com/zeroclaw-labs/zeroclaw/releases). **Re-run the manual
verification steps below whenever you bump it** — several of the mechanisms
this add-on depends on turned out to differ between ZeroClaw's `master`
branch docs and the actual 0.8.4 release (see next section); a new release
could shift things again in either direction.

## Everything below was verified against a real running container, not just docs

The plan's original design (a `gateway.webhook_secret` config field / a
`zeroclaw config set mcp.servers.<name>.<field>` dotted CLI path) came from
reading ZeroClaw's `master`-branch docs and source. Building the image and
actually booting it (`docker build`, `docker run` with a fake
`/data/options.json`, `docker exec` + `curl` against the running gateway)
surfaced real differences between `master` and the pinned `v0.8.4` release.
Everything in this section reflects the **tested, working** behavior of
`ghcr.io/zeroclaw-labs/zeroclaw:dist-v0.8.4` specifically.

### `gateway.webhook_secret` does not exist in 0.8.4

`zeroclaw config list` on a running 0.8.4 container has no such field —
confirmed by grepping the full schema dump. It's real, but only on
ZeroClaw's unreleased `master` branch. **This add-on does not use it.**

### The mechanism that *does* work: pairing + a static `paired_tokens` entry

Confirmed end-to-end against a running container:

```
zeroclaw config set --no-interactive gateway.require_pairing true
zeroclaw config set --no-interactive gateway.paired_tokens '["<token>"]'
```

then `Authorization: Bearer <token>` on `POST /webhook` (and on `/api/*`)
returns normal responses; a missing or wrong bearer returns `401
{"error":"Unauthorized — pair first via POST /pair, then send Authorization:
Bearer <token>"}`. This is also exactly the pattern visible in a real,
working ZeroClaw user's own `config.toml` (`gateway.paired_tokens` set
directly, shared with the user during this project) — so it's a
production-proven mechanism, not a workaround. `rootfs/usr/bin/run.sh` uses
this; the add-on option is called `api_token` (not `webhook_secret`) to
match what it actually is.

**`--no-interactive` is required** — without it, `config set` on a
`#[secret]`-typed field (like `paired_tokens`) prompts for masked terminal
input and fails non-interactively with "Secret input requires a terminal on
stdin and stderr."

### `config set` cannot write a dynamic `mcp.servers.<name>.<field>` path in 0.8.4

`zeroclaw config set --no-interactive mcp.servers.home_assistant.transport
http` → `Error: Unknown property 'mcp.servers.home_assistant.transport'` on
a running 0.8.4 container, even though **reading** that exact path back via
`GET /api/config/list?prefix=mcp` works fine once the entry exists. The
README's `zeroclaw config set mcp.servers.filesystem.command npx` example is
either newer than 0.8.4 or needs a map-key-creation step this version's CLI
doesn't expose the same way.

**What works instead, confirmed against a running container:** append the
`[[mcp.servers]]` block directly to `config.toml` as raw TOML (see
`run.sh`), in the same shape ZeroClaw itself writes. The daemon loads it
correctly (confirmed via `GET /api/config/list?prefix=mcp` showing
`mcp.servers.home_assistant.*` populated) and starts without error. A
plaintext header value (`Authorization = "Bearer ..."`, not
`enc2:`-wrapped) is accepted on load exactly like an encrypted one — encryption at rest presumably applies the next time the config is saved
through the CLI/API/dashboard, not on load. This append only happens on
first boot (guarded on `config.toml` not existing yet), so it never fights
a value the user has since changed through ZeroClaw's own dashboard.

### The freshly-seeded config needs `config migrate` before any `config set`

Hit "`Error: config at ... is schema_version 1; run zeroclaw config migrate
to update before modifying`" once during testing (traced to an artifact in
an ad-hoc test script that re-copied the seed over an already-modified file,
not a bug in the real seeding path — the real `run.sh` only copies the seed
once, guarded on the config file not existing yet). Kept `zeroclaw config
migrate` as a defensive first step regardless: confirmed harmless
(`Config already at current schema version.`) when nothing needs migrating,
and cheap insurance against a future base-image bump shipping a seed at an
older schema version.

### Corrected MCP URL and Home Assistant host

The plan originally guessed `/api/mcp/assist`. The real, working example
config shared during this project uses `http://homeassistant:8123/api/mcp`
(no `/assist` suffix) — fixed in `run.sh` and the default
`home_assistant_url` option (`http://homeassistant:8123`, the Supervisor's
internal DNS name for Home Assistant Core itself — not
`http://supervisor/core`, which is the Supervisor's own REST API proxy, a
different endpoint).

## Why the add-on runs as root

Upstream's distroless image runs as UID 65534, with `/zeroclaw-data`
pre-chowned to that UID at their build time. Our persistent storage instead
lives under Home Assistant's bind-mounted `/data`, whose host-side ownership
we don't control at build time — reconciling that with a fixed non-root UID
would need a root-first entrypoint that `chown`s then drops privileges
(`gosu`/`su-exec`). Given this add-on requests no host network, no devices,
and no elevated capabilities, the blast radius of running as root **inside
this one unprivileged container** is small, and it's consistent with how a
large share of simple HA add-ons operate. Follow-up idea if this needs
hardening later: add a `gosu` step to run the daemon itself as a fixed
non-root UID after fixing `/data` ownership.

## Confirmed the gateway `/webhook` contract by reading source (still accurate for 0.8.4)

`crates/zeroclaw-gateway/src/lib.rs` (`handle_webhook`,
`authorize_webhook_request`, `WebhookBody`/`WebhookQuery`), cross-checked
against the running container:

- `POST /webhook?agent=<alias>` (agent optional)
- Headers: `Authorization: Bearer <token>` (checked against
  `gateway.paired_tokens` when `gateway.require_pairing = true`);
  `X-Session-Id: <id>` (alnum/`-`/`_`/`.`, ≤128 chars) for multi-turn
  continuity — **not** a body field.
- Body: `{"message": "<text>"}`
- Success `200`: `{"response": "<reply text>", "model": "<model label>"}`
- Errors confirmed live: `401` (bad/missing bearer when pairing is
  required), `503` `{"error":"needs_quickstart","url":"/quickstart"}` (no
  model configured yet), `500` `{"error":"LLM request failed"}` (model
  configured but the call itself failed, e.g. no valid API key).

This is what `ha-zeroclaw-conversation`'s `conversation.py` calls.

## Ingress iframe was blocked by ZeroClaw's own hardcoded security headers — fixed with an nginx front-end

Deploying to a real Home Assistant instance (2026.8.3) surfaced this
immediately: opening the add-on's Ingress panel failed in Firefox with
"homeassistant.local:8123 does not allow Firefox to display the page when
embedded within another site" — a classic anti-framing violation.

Root cause, found in `crates/zeroclaw-gateway/src/security_headers.rs`:
ZeroClaw's gateway unconditionally sets `x-frame-options: DENY` and a CSP
containing `frame-ancestors 'none'` on every response, via a compile-time
constant list with no config field or env var to change it. This makes the
gateway fundamentally unembeddable, which breaks Ingress (Home Assistant
embeds the add-on's web UI in an iframe within its own frontend — the same
mechanism Portainer, phpMyAdmin, etc. all rely on).

Since we only consume ZeroClaw's published binary (no fork, no source
changes), the fix is a thin **nginx front-end inside the container**:
- ZeroClaw now binds loopback-only (`127.0.0.1:8099`, no `allow_public_bind`
  needed since it's never non-loopback).
- nginx (`nginx-light`, added to the Dockerfile) listens on `42617` (the
  add-on's `ingress_port`) and reverse-proxies everything to `127.0.0.1:8099`,
  using `proxy_hide_header` to strip `X-Frame-Options` and
  `Content-Security-Policy` from the response before it reaches the browser.
  See `rootfs/etc/nginx/nginx.conf`.
- `run.sh` now starts both processes (ZeroClaw in the background, nginx in
  the foreground) with a `trap`-based shutdown so a container stop actually
  terminates both instead of leaving ZeroClaw orphaned.

**Confirmed working** (`docker build` + `docker run`, `curl -D -`): through
nginx on 42617, `x-frame-options` and `content-security-policy` are absent
from every response while the other ZeroClaw-set security headers
(`x-content-type-options`, `referrer-policy`, COOP/CORP,
`permissions-policy`) pass through unchanged; `/webhook` auth and the
dashboard HTML both still work identically to before. **Not yet confirmed**:
that this actually resolves the Ingress iframe in a real browser against a
real Home Assistant instance — the header-level fix is verified, the
visual/UI confirmation from inside HA is the next step.

## Ingress panel loaded but was blank — ZeroClaw's dashboard hardcodes root-absolute paths, fixed with nginx sub_filter

After the frame-headers fix above, the Ingress panel stopped showing
Firefox's frame-block error but rendered blank, with the browser console
showing every dashboard JS/CSS asset blocked for "disallowed MIME type
(text/plain)" on URLs like `http://homeassistant.local:8123/_app/assets/
index-*.js` — note: **no Ingress path prefix in that URL**.

Root cause: ZeroClaw's dashboard bundle references its own assets and API
calls with hardcoded, root-absolute paths (`href="/_app/logo.png"` in the
HTML; `` fetch(`/api/...`) ``, `` fetch(`/admin/...`) ``, `` fetch(`/health`)``
in the JS — confirmed by downloading and grepping the actual compiled
bundle, not guessed). A root-absolute path resolves against the *page's
origin root*, ignoring whatever subpath the page is actually served under.
Home Assistant serves Ingress content from a per-session
`/api/hassio_ingress/<token>/` prefix, so every one of these requests went
straight to `homeassistant.local:8123/...` instead — which is Home
Assistant's own frontend, not this add-on, and doesn't have those routes.
That's also why the MIME type was `text/plain`: the browser was hitting
Home Assistant's own fallback response, not ZeroClaw at all.

Fix: Home Assistant's Ingress proxy sends an `X-Ingress-Path` header
carrying the correct prefix specifically so apps can self-correct
(documented at developers.home-assistant.io, Add-ons → Presentation →
Ingress). Since nginx `sub_filter` only does literal substring replacement
(no regex), the fix rewrites each *known* absolute-path prefix — found by
grepping the real bundle, not enumerated from guesswork — prepending
`$http_x_ingress_path` (empty, and therefore a no-op, on a direct
non-Ingress request):

- `"/_app/` (HTML, double-quoted asset URLs)
- `` `/_app/ ``, `` `/api/ ``, `` `/admin/ ``, `` `/health `` , `` `/ws/ ``
  (JS, backtick template-literal fetch/URL targets)

**A real gotcha hit during this fix**: `sub_filter_types` must exactly match
the upstream `Content-Type`. ZeroClaw serves its JS chunks as
`text/javascript`, not `application/javascript` — the first attempt
declared only the latter, and every `/api/`/`/admin/` rewrite in the JS
silently no-op'd (zero error, just unrewritten output) until this was
caught by re-fetching the proxied response and diffing its `Content-Type`
header against what `sub_filter_types` declared. `text/javascript` is now
listed alongside `application/javascript` defensively.

**Confirmed working** end-to-end via `docker build`/`docker run` + `curl`:
with a simulated `X-Ingress-Path` header, every known prefix in the HTML,
the main dashboard bundle, and the `api-*.js` chunk (`/api/agents/`,
`/api/config/*`, `/api/browse`, `/admin/paircode`, `/admin/reload`, etc. —
confirmed the *whole* enumerated list, not just one example) comes back
correctly prefixed; without the header, output is byte-identical to before
this fix. Frame headers, `/webhook` auth, and CSS `Content-Type` were
re-verified unaffected. **Not yet confirmed**: an actual browser loading the
dashboard through a real Home Assistant Ingress session (only the header
rewriting itself was tested, not the full browser round-trip) — that's the
next thing to check. Also not found in the bundle at all (so not yet
handled, and unconfirmed either way): a WebSocket connection URL — the
`/ws/` prefix rule is included defensively, but no `new WebSocket(...)`
call was found in either JS chunk fetched during this investigation (the
app may lazy-load that from a chunk only reachable past ZeroClaw's own
quickstart flow, which requires a configured LLM provider to reach).

## The `/api/`, `/admin/`, `/health` rewrite rules above were wrong — replaced with ZeroClaw's own `window.__ZEROCLAW_BASE__` mechanism

After the `/_app/` static-asset fix, the dashboard loaded visually but got
stuck on ZeroClaw's own pairing screen — even with `require_pairing: false`
confirmed server-side (both via the daemon's own startup log line and via
`curl /health`), and even in a fresh incognito window on a different
browser (ruling out caching entirely). Chrome DevTools' Network tab traced
it to `GET http://homeassistant.local:8123/health` returning `404` — no
Ingress prefix at all, hitting Home Assistant's own server directly, not
this add-on.

Re-grepping the actual `api-*.js` chunk (the one that makes this call, not
the main bundle checked earlier) found the real mechanism, and it's more
interesting than a missing rewrite rule:

```js
var s = a() ? `` : (window.__ZEROCLAW_BASE__ ?? ``).replace(/\/+$/, ``)
```

(`a()` checks `"__TAURI__" in window`, i.e. whether this is ZeroClaw's
desktop app build.) ZeroClaw **already has** a runtime base-path variable
for exactly this scenario — it's simply never populated in a plain browser
deployment. Most API calls go through a shared `p(endpoint)` helper that
internally builds `` `${c}${s}${endpoint}` ``; a handful of calls
(`/health`, `/api/pair`, `/pair/code`, `/admin/paircode/new`) fetch directly
with `` `${s}/...` `` inline. Since `s` was always `""`, every one of these
went to the domain root instead of the add-on.

**This retroactively explained why the earlier `` `/api/ ``, `` `/admin/ ``
sub_filter prefix rules "worked" in testing**: they rewrote the *literal
argument strings* passed to `p()` (e.g. `` `/api/config` `` → prefixed),
which happened to produce the right final URL only because `s` was empty at
the time — `s` + already-rewritten-argument = correct by coincidence. Once
`window.__ZEROCLAW_BASE__` is properly populated (the real fix), `s` stops
being empty, and those same old rules would have **double-prefixed** every
`p()`-routed call. They were removed, not layered on top.

Replacement, precisely scoped after exhaustively grepping every literal
`fetch()` target in both compiled chunks (not guessing): inject
`window.__ZEROCLAW_BASE__ = "<X-Ingress-Path>"` via an inline `<script>`
right after `<head>`, so ZeroClaw's own `s` resolves correctly on its own
for every `p()`-routed call and all four direct `` `${s}/...` `` calls. Kept
only the `/_app/` asset-path rules (a separate, unrelated mechanism — those
paths are static HTML attributes, not runtime-computed, so they can't read
`__ZEROCLAW_BASE__` no matter what). Added exactly one more exact-literal
rule for the single confirmed exception: `` fetch(\`/admin/paircode\`) ``
(the GET status check) has no `${s}` at all in ZeroClaw's own source —
apparently a gap in their code, inconsistent with the otherwise-identical
`/admin/paircode/new` call two lines away, which does use `${s}`. The
sub_filter literal is closed on both sides (`` `/admin/paircode` ``, full
backtick-to-backtick) specifically so it can never also match
`` `/admin/paircode/new` ``.

**Confirmed working** via `docker build`/`run` + `curl` with a simulated
`X-Ingress-Path` header, checking every distinct call pattern found in the
bundles individually: the injected script tag carries the right value;
`/_app/` asset references still get prefixed; `p()`-routed literals
(`` `/api/config` `` etc.) are left **untouched** (correct — `s` does the
work at request time in the browser, not at proxy time); the four direct
`` `${s}/...` `` calls are also left untouched (same reason); the
`/admin/paircode` exception is prefixed; frame headers stay stripped;
direct (non-Ingress) access still gets an empty-string base, unaffected.

## The "1 path differ from on-disk" drift banner is a seed-image quirk, not something reload fixes

After the reload/quickstart items below were investigated, the same "1
path differ from on-disk" banner turned out to have a root cause worth
fixing outright rather than working around: `GET /api/config/drift` on a
**freshly booted, untouched** container already reports
`risk_profiles.default.auto_approve` as drifted — the in-memory value (this
ZeroClaw version's actual current default) has three entries
(`tool_search`, `browser`, `browser_open`) that the upstream image's
**baked-in seed config.toml** doesn't. This is present on every fresh boot
of `ghcr.io/zeroclaw-labs/zeroclaw:dist-v0.8.4`, independent of anything
this add-on's bootstrap does — a mismatch between what that image bakes in
and what its own binary now considers current.

Two things confirmed by testing, both non-obvious:

- **`POST /admin/reload` does NOT clear this drift.** Called it via loopback
  (the same container, `127.0.0.1:8099` directly) right after confirming
  the drift — the reported drift was byte-for-byte identical afterward.
  Reload re-applies the same mismatched defaults; it doesn't reconcile
  them.
- Also confirmed in passing while investigating the reload restriction: the
  "Reloading isn't available from this remote session" message the
  dashboard shows is a **frontend-only heuristic** (almost certainly a
  `window.location.hostname`-based check, same pattern as the Tauri-app
  detection found earlier), not a real backend restriction *in this add-on's
  specific setup* — `POST /admin/reload` through the published port with
  **no auth at all** returned `200 {"success":true,...}`, because nginx's
  own connection to ZeroClaw is always loopback (`127.0.0.1:8099`), so
  ZeroClaw's own loopback-only default policy is satisfied regardless of
  what the actual external caller was. (This doesn't contradict the
  documented `allow_remote_admin`/`require_pairing` gate described
  elsewhere in this file — that gate is about ZeroClaw's own *notion* of
  "remote," which in this proxied setup never actually triggers, since
  every caller looks loopback to it.)

Fix: reconcile the drift once, on first boot only, before the daemon starts
(see next point for why pre-start specifically). `run.sh` now writes the
complete 16-entry `auto_approve` list directly. This is admittedly a
hardcoded, version-specific value — if a future ZeroClaw release changes
its own defaults again, this would need updating (or dropping, if upstream
fixes their seed image). Confirmed via `GET /api/config/drift` on a fresh
boot with the real `run.sh`: `{"drifted":[]}`.

## `config set` against an *already-running* daemon silently fails to persist

Discovered while testing the drift fix: running `zeroclaw config set
--no-interactive risk_profiles.default.auto_approve '[...]'` via `docker
exec` against a container whose daemon was **already running** reported
`... updated.` (success) but the actual `config.toml` on disk was
**unchanged** afterward (verified with `cat`) — same value as before the
call, even after a full container restart. The identical command, run as
part of the boot sequence **before** `zeroclaw daemon` starts, persists
correctly every time. Not fully root-caused (a plausible theory: `config
set` against a live daemon may route through some in-memory/IPC path that
doesn't reliably flush to disk, rather than editing the file directly) —
but the practical rule is clear and now applied consistently: every
`config set` call in `run.sh` runs before the daemon starts, never after,
and this should be treated as a hard rule for any future additions too.

## Remote reload from the dashboard, and finding the quickstart page

Two smaller items found once the dashboard was fully working on a real
Home Assistant instance:

**Remote `/admin/reload`** (the dashboard's own "config drifted, reload?"
banner) failed with "Reloading isn't available from this remote session" —
this is a genuine, documented server-side restriction
(`ops/network-deployment.md`): `allow_remote_admin` only has any effect
when `gateway.require_pairing` is also `true` — with pairing off (this
add-on's default, per the sections above), remote reload is rejected by
design, not a bug. Added `zeroclaw config set --no-interactive gateway.
allow_remote_admin true` to `run.sh`, called unconditionally on every boot
(safe either way, per the same doc: it's a no-op unless pairing is also
on). Confirmed working end-to-end with `curl -X POST /admin/reload
-H "Authorization: Bearer <token>"` → `{"success":true,"message":"Daemon
reload initiated"}` — once an `api_token` is set (pairing on), the
dashboard's reload button should work.

Oddity noted in passing: right after boot, `zeroclaw config get
gateway.allow_remote_admin` (and `config list`) report `false` even though
`config.toml` on disk correctly has `allow_remote_admin = true` (verified
by `cat`) and the *functional* `/admin/reload` call succeeds. Whatever
`config get`/`list` query when a daemon is already running doesn't match
what the daemon actually enforces for this one field. Not investigated
further since the only thing that actually matters — the real HTTP
behavior — is correct.

**The quickstart wizard doesn't auto-show**: traced to the SPA's own
routing guard (found in the main bundle): on landing at `/`, it redirects
to `/quickstart` only if `!quickstart_completed && agents.length === 0`.
The image's baked-in seed config already defines an `[agents.default]`
entry, so `agents.length` is never `0`, and the guard never fires — even
though `quickstart_completed` is genuinely `false` (confirmed via `GET
/api/quickstart/state`). This is a property of ZeroClaw's own seed
config, not something this add-on's bootstrap does. `/quickstart` is a
perfectly normal client-side route otherwise (confirmed in the router:
`{path:"/quickstart", element:...}`, with its own sidebar nav entry
`nav.quickstart`) — reachable by clicking it in ZeroClaw's own in-app
sidebar (inside the Ingress iframe, not Home Assistant's sidebar).

## `api_token` schema bug: clearing it in the HA UI didn't actually clear it

On a real Home Assistant instance, after setting `api_token` once (pairing
active) then clearing it back to empty to switch to the "rely on network
isolation, no pairing friction" mode described in DOCS.md, the dashboard
kept showing the pairing screen. Root cause: `config.yaml`'s schema declared
`api_token: password` (no `?` suffix) — a **required** field. Home
Assistant's Configuration UI would not actually persist an empty value for
a required field, so `run.sh` kept re-asserting `require_pairing = true` on
every restart regardless of what the user typed in the UI. Fixed by
changing the schema to `api_token: password?` (optional), matching what
`run.sh` already expected (`if [ -n "${api_token}" ]`).

Confirmed via `docker`, simulating the exact scenario (a container already
paired from a prior boot, then restarted with `api_token` cleared in
`options.json`): `/health` correctly flips from `"require_pairing":true` to
`"require_pairing":false` on the next boot. The dashboard's own pairing-gate
logic (found by grepping the bundle) reads this exact live field from
`/health` on load (`Ga()` → `y().then(e=>e.require_pairing)`) — so once the
schema fix lets the empty value actually persist, the pairing screen should
stop appearing. `"paired"` stays `true` (a separate, historical "has this
gateway ever been paired" flag) but nothing in the bundle's pairing-gate
logic branches on it — only `require_pairing` gates the screen.

## MCP server was seeded but never usable — missing the bundle, and the timing problem that limits how far this can be automated

Reported by the user after getting the full loop working end-to-end
(Assist → `zeroclaw_conversation` → this add-on → a real agent configured
via ZeroClaw's own Quickstart wizard): the agent could not see the
`home_assistant` MCP server at all. Root cause: `run.sh` only ever seeded
the **server definition** (`[[mcp.servers]]`), never a **bundle**
(`[mcp_bundles.<name>]`) — and ZeroClaw's own docs are explicit that these
are separate, both-required steps: "An agent with no `mcp_bundles`
connects to no MCP servers, even when `mcp.servers` is non-empty."

Fixed the half that's actually automatable: `run.sh` now also appends a
`[mcp_bundles.home_assistant] servers = ["home_assistant"]` block on first
boot, alongside the server definition (confirmed loading correctly via
`GET /api/config/list?prefix=mcp_bundles` against a running container).

**What's structurally NOT automatable, and why**: granting that bundle to
a specific agent's own `mcp_bundles` field requires knowing which agent —
but the whole point of this add-on's minimal-options design (see README's
"Why so few options?") is that agent configuration happens later, inside
ZeroClaw's own dashboard/Quickstart wizard, which runs *after* this add-on
has already booted and finished its one-shot first-boot seeding. There is
no agent to grant the bundle to yet at the point `run.sh` runs. Documented
as a required one-click manual step in DOCS.md instead of pretending it
could be automated away.

## Auto-grant the home_assistant MCP bundle to every agent, every boot

User request, explicit and deliberate: rather than the one-click-per-agent
manual grant documented above, reconcile automatically at boot — check
every existing agent (including ones ZeroClaw's own Quickstart wizard
created after this add-on's first boot) and grant the `home_assistant` MCP
bundle to any that don't already have it.

**This goes against ZeroClaw's own "no implicit grants" security default**
(see the "No broadcast/global MCP grant" entry in the `ha-zeroclaw-
conversation` repo's DECISIONS.md, which covers the same question from the
integration side) — told the user this plainly before building it; it's a
tradeoff they're choosing, not a free enhancement.

### Why this had to go through the live HTTP API, not the offline CLI

Extensive empirical testing (all against a real running container, not
assumed) before settling on the final approach:

- `zeroclaw config get agents.<alias>.mcp_bundles` and `config set` on the
  same path both fail outright: `Error: Unknown property`. Same class of
  issue as the `mcp.servers.<name>.<field>` gap documented above —
  `agents.<alias>` is also a dynamic map the offline CLI's dotted-path
  resolver doesn't reach into.
- `zeroclaw config list --filter agents.<alias>` (offline, no daemon
  running) returns **nothing** for a dynamic map entry either — confirms
  dynamic-map introspection needs the live daemon's own API, not the
  static-schema-driven offline listing.
- `zeroclaw config set providers.models.anthropic.default.api_key "..."`
  (also a dynamic map, one level deeper) is the worst case found: it
  reports `... updated.` (apparent success) but **does not write anything
  to the file at all** — confirmed by immediate `cat` before and after,
  freshly, more than once. Silent no-op, not an error.
- `zeroclaw config patch` (JSON Patch, offline) *does* resolve
  `/agents/<alias>/mcp_bundles` correctly (no "Unknown property") — but a
  test patch against a synthetic fixture agent hit a hard `validation
  failed after applying patch` error over an unrelated field
  (`model_provider` "not configured") that could not be resolved even
  after matching the exact structure from a real, genuinely-working
  ZeroClaw config the user had shared earlier in this project. Root cause
  not identified.
- The **live HTTP API** (`GET`/`PUT /api/config/prop?path=agents.<alias>.
  mcp_bundles`, called over loopback from inside `run.sh` after starting
  the daemon) is the one path that reliably worked for both read and
  write, confirmed via direct file inspection after each write. Notably,
  the exact same "unconfigured model_provider" condition that hard-failed
  `config patch` only ever surfaced here as a non-blocking `warnings`
  entry in the response — the write itself still succeeded. This also
  explains why the daemon starts up and runs normally with a synthetic
  fixture that `config patch` refused to touch: whatever's stricter about
  `config patch`'s validation path isn't shared by daemon startup or by
  the live per-property API.

### Implementation

`run.sh`, after `zeroclaw daemon &`, before starting nginx:
1. Poll `GET /health` over loopback (up to 30s) until the daemon answers.
2. `GET /api/quickstart/state` for the current `"agents"` list (same
   endpoint already used elsewhere in this project for the same purpose).
3. Per agent: `GET /api/config/prop?path=agents.<alias>.mcp_bundles` (the
   response's `.value` is a JSON-encoded *string*, e.g. `"[\"wallet\"]"` —
   parsed with `jq 'fromjson'`, defaulting to `[]` when unset/unparseable).
4. If `"home_assistant"` isn't already in that list, `PUT` the list with it
   appended.

Gated on `ha_url`/`ha_token` being set (same as the server/bundle seeding
above) and runs on **every** boot, not just first boot — `curl` added to
the Dockerfile for this (wasn't needed before).

**Confirmed end-to-end** against a real running container, three boots in
sequence: (1) fresh boot, only the implicit "default" agent exists (no
literal `[agents.default]` TOML section at all, yet still correctly
reported by `/api/quickstart/state` and successfully granted — confirms
this handles ZeroClaw's synthesized default, not just literal agents);
(2) a second agent (`pongo`) added to config.toml between boots, restarted
— `default` was correctly *skipped* (already granted, no duplicate log
line, no duplicate array entry) while `pongo` was correctly *granted*;
(3) third boot with both agents already granted — neither touched, fully
idempotent. `mcp_bundles` arrays verified correct in the actual on-disk
`config.toml` after each step, not just via the API response.

## Model providers moved into the add-on's own options — live credential writes weren't reliable

User report from the `ha-zeroclaw-conversation` side of this project: an
agent created with a fresh Anthropic API key entered through that
integration's config flow (which wrote the key via ZeroClaw's *live* HTTP
API, same mechanism its own dashboard uses) kept failing at actual use
with `Anthropic credentials not set` — even after the key was later
re-set directly through ZeroClaw's dashboard, still against the running
daemon. Root cause not fully pinned down (plausibly the same class of
issue as the "config set against an already-running daemon doesn't
reliably persist" finding elsewhere in this file, or a provider client
that's constructed once and cached rather than re-read per-request) — but
the practical fix follows the same rule this file has landed on
repeatedly: **write it before the daemon starts, not after.**

Added a `providers` option to `config.yaml` — a repeatable group
(`provider_type`, `alias`, `api_key`, `model`, `uri`), the same "list
containing one schema map" syntax confirmed against a real, actively
maintained hassio-addons repo (`app-tailscale`'s `services` option) rather
than assumed. `run.sh` reconciles it every boot (not just first boot, so
adding a second provider later and restarting picks it up), each entry
guarded by a `grep -qF "[providers.models.<type>.<alias>]"` existence
check against `config.toml` — idempotent per-alias, not per-boot, and
consistent with the "seed once, never fight the user's later edits"
policy already used for the MCP server entry: an alias that already
exists is left untouched even if this boot's options now describe it
differently.

**Confirmed working end-to-end**, three real boots: (1) one provider
configured, fresh boot → seeded correctly, verified both in the raw
`config.toml` and via `GET /api/quickstart/state`'s `model_providers`
list; (2) restart with the same option unchanged → correctly skipped
("already configured; leaving it as-is"), no duplicate section (which
would have been a TOML parse error); (3) a *second* provider added to the
option, restart → the first was left alone, the second was newly seeded,
both coexist in `model_providers`. Then, closing the actual loop this was
meant to fix: created an agent via `POST /api/quickstart/apply` in
`"existing"` mode referencing the pre-seeded provider, and confirmed
`GET /api/config/prop?path=providers.models.anthropic.household.api_key`
reports `"populated": true` — a real, non-blank credential, the exact
thing that was failing before.

This is also **why `ha-zeroclaw-conversation`'s create-agent flow was
simplified** to stop collecting fresh provider credentials itself — see
that repo's `docs/DECISIONS.md`. It now only lets the user pick from
whatever providers are configured here.

## MCP seeding was first-boot-only — silently never happened for anyone who added the token later

User report: ZeroClaw's dashboard showed nothing at all under MCP Servers
or MCP Bundles, as if `home_assistant_token` had never been set — even
though it clearly was, in the add-on's Configuration tab.

Root cause: the MCP server/bundle seeding block was gated on `first_boot
= 1` — a reasonable-sounding "don't fight the user's later edits" guard,
same reasoning as the provider-seeding block above it. But it has a real
gap: **first_boot is a property of when `config.toml` was created, not of
when the user got around to setting `home_assistant_token`.** A perfectly
normal sequence — install the add-on, boot it once without the token
(config.toml gets created then), come back later and add the token, boot
again — meant `first_boot` was already `0` on every subsequent boot,
so the seeding block would silently never run again, for that install,
ever. This is exactly what happened on the real instance this project has
been testing against throughout.

Fixed the same way the provider-seeding block was already fixed earlier
for an analogous reason: replaced the `first_boot = 1` gate with a direct
existence check — `grep -qF "[mcp_bundles.home_assistant]" "${CONFIG_FILE}"`
— so seeding runs on **any** boot where the marker is genuinely still
missing, not just the very first one. Still idempotent (never re-seeds
once the marker exists, so no duplicate-TOML-section corruption risk).

**Confirmed working end-to-end**, three real boots reproducing the exact
reported scenario: (1) boot with `home_assistant_token` empty (matches a
real prior state) → correctly seeds nothing, confirmed via
`GET /api/config/list?prefix=mcp_bundles` returning an empty list; (2) same
`config.toml`, `home_assistant_token` now set, restart → the MCP server
and bundle are correctly seeded *this time*, and the existing "default"
agent is immediately granted the bundle by the reconciliation step that
already runs right after; (3) third boot, nothing changed → correctly
skipped ("already configured; leaving it as-is"), and `grep -c` on the
marker in the actual `config.toml` confirms exactly one occurrence — no
duplicate section, no TOML corruption, the daemon started and served API
requests normally on all three boots.

User also asked whether Home Assistant integration should use something
other than MCP given it "wasn't working." Given the root cause turned out
to be a straightforward bug in this add-on's own one-shot seeding logic —
not a limitation of MCP itself, which every other test in this project
against a real running gateway confirmed works correctly once actually
configured — recommended staying with MCP rather than switching approach.

## Not yet verified / open follow-ups

- **A real LLM provider was never configured during testing** (no API key
  used), so only the auth/routing layer of `/webhook` was confirmed, not an
  actual successful chat completion end-to-end. Do that once an API key is
  available.
- **At-rest encryption of the seeded HA MCP token**: the plaintext
  `Authorization` header written by the first-boot append stays plaintext on
  disk until the next time ZeroClaw itself saves the config (dashboard,
  CLI, API) — not a functional problem (confirmed the daemon loads it fine
  either way) but worth knowing.
- **`icon.png` / `logo.png`**: not created (no image-generation tool
  available in this session). The add-on will show a generic default icon
  until real branding artwork is added.
- **`repository.yaml`, `README.md`**: filled in with the real GitHub home
  (`LorenzoVasi/addon-zeroclaw`) once this repo was actually pushed
  (2026-08-27) — `IMAGE_NAME` in CI already derived it from
  `github.repository` automatically, nothing to fill in there.
- **Data volume mapping**: using implicit `/data` (always present, always
  backed up, no `map:` entry needed) rather than an explicit `map:` type.
  Confirmed `/data` bind-mounts and is readable/writable in local `docker
  run` testing; not yet confirmed included in an actual HA Backup (that
  needs a real Supervisor, not just `docker run`).
- **Not yet tested inside an actual Home Assistant Supervisor** — only
  `docker build` + `docker run` against a fake `/data/options.json` on a
  developer machine. Ingress routing, the add-on Store install flow, and
  Backups specifically still need a real HA instance (see the plan's
  Verification section) before calling this submission-ready.

## Default `home_assistant__*` risk-profile permissions: free in general, confirm-only for opening covers

User request (2026-08-26): once an agent is actually talking to Home
Assistant over MCP, configure its permissions so `home_assistant` MCP tools
need **zero confirmation in general**, but require **mandatory confirmation**
(not a hard block) specifically for opening doors, windows, and gates.

**The `HassTurnOn`/`HassTurnOff`/`HassToggle` gap — read this before touching
either tool list below.** ZeroClaw's risk profile (`docs/book/src/security/
autonomy.md`, confirmed) gates by **tool name only** — `auto_approve` /
`always_ask` / `excluded_tools` are flat lists, no per-entity or per-argument
matching. Home Assistant's own `home_assistant__HassTurnOn` /
`...HassTurnOff` / `...HassToggle` are **not** lights/switches-only: reading
`homeassistant/components/intent/__init__.py` (`OnOffIntentHandler`)
confirms they also lock/unlock `lock.*` entities and open/close `cover.*` /
`valve.*` entities — the exact same tool a plain "turn on the light" request
uses. So a rule that only gates the dedicated cover tools
(`HassOpenCover`/`HassCloseCover`/...) has a real bypass: an agent could
open a gate via `HassTurnOn` instead. Locks are worse — Home Assistant ships
**no dedicated lock intent at all** (`homeassistant/components/lock` has no
`intent.py`, confirmed by listing the component's files and by a zero-result
search for `HassLock`/`INTENT_LOCK` across `home-assistant/core`), so
lock/unlock has no tool-name-level lever to gate, ever, without also gating
the shared on/off tool the user wants free for lights.

Presented this tradeoff to the user directly (three options: gate only the
dedicated cover tools + reinforce via the agent's own personality file;
gate `HassTurnOn`/`HassTurnOff` too and accept confirmation prompts on
ordinary lights/switches; or hide the cover/lock entities from Assist
exposure entirely, losing agent control over them altogether). User chose
the first: dedicated-tools-only hard gate, plus a personality-file
instruction as the mitigation for the residual gap — accepting that this is
soft enforcement (a cooperative agent follows it; nothing stops a
sufficiently adversarial prompt from using the generic tool instead) since
ZeroClaw has no harder lever available for this specific case. The
personality-file reinforcement lives in the companion repo,
`ha-zeroclaw-conversation`'s `personality.py` (`HOME_ROLE_SOUL_ADDITION`) —
see that repo's `docs/DECISIONS.md` for the exact wording.

**Implementation** (`rootfs/usr/bin/run.sh`, in the existing per-agent MCP
bundle reconciliation loop that already runs on every boot for every agent):
for each agent, also read `agents.<alias>.risk_profile`, then GET/PUT
`risk_profiles.<alias>.auto_approve` and `...always_ask` via the same live
`/api/config/prop` mechanism already used for `mcp_bundles` (the offline CLI
doesn't support these dynamic paths either — same limitation as `mcp.servers`
and `providers.models.*`, see above). Two hardcoded tool-name lists:

- `HA_ALWAYS_ASK_TOOLS`: `HassOpenCover`, `HassCloseCover`, `HassSetPosition`,
  `HassStopMoving` — the dedicated cover-movement intents (covers `cover.*`
  domain entities: garage doors, gates, blinds, windows — HA has no separate
  "door" domain, so this is the correct and only enforceable target for
  "doors/windows/gates"). `HassSetPosition`/`HassStopMoving` included
  alongside open/close because both also directly move a cover (partial-open
  a gate; leave a closing gate ajar by stopping it mid-travel) — same risk
  class as open/close, not lumped in with the free list.
- `HA_AUTO_APPROVE_TOOLS`: every other confirmed `home_assistant__Hass*`
  intent tool name (lights, climate, fans, humidifiers, media player,
  volume, lists/shopping list, timers, date/time, weather, vacuum, lawn
  mower, `GetLiveContext`, the generic on/off/toggle/get-state/respond
  ones) — enumerated by reading each relevant HA core component's
  `intent.py`/`const.py` directly (`homeassistant/components/{cover,fan,
  todo,light,lawn_mower,vacuum,shopping_list,humidifier,media_player,
  climate,weather}` plus `helpers/intent.py`), not guessed. Same
  hardcoded-known-list pattern already used for the
  `risk_profiles.default.auto_approve` drift fix above — version-specific,
  documented as such; a future ZeroClaw or HA release adding new intents
  would need this list updated too.

Merge logic is additive-only, every boot, same "seed gaps, never fight later
edits" policy as the provider/MCP seeding: for each list, only add entries
from the hardcoded set that aren't already present in *either* of the
agent's current `auto_approve` or `always_ask` (so a user who later moves an
entry between the two lists themselves, e.g. via the dashboard, keeps their
own choice on every subsequent boot — confirmed by testing, see below).

**Verified end-to-end** against a real built image (`docker build` +
`docker run` with a fake `/data/options.json`, same methodology as
everywhere else in this file): first boot correctly seeded both lists onto
the seed image's `risk_profiles.default` profile (confirmed via `cat
config.toml` — all ~44 free tools in `auto_approve`, all 4 cover-movement
tools in `always_ask`); a second-boot test that manually moved
`HassGetWeather` into `always_ask` and `HassSetPosition` into `auto_approve`
before restarting confirmed both stayed exactly where moved — no log line
fired (nothing to reconcile), byte-identical file — proving the
"don't clobber a later edit, either direction" property actually holds, not
just in theory.

## Provider key rotation was silently broken: "seed once" was the wrong policy for providers

User report (2026-08-27): changed a provider's token in the add-on's
Configuration tab on an already-running install, restarted, and Assist kept
failing `unauthorized` — the new key never took effect.

Root cause: the provider-seeding loop (added during the provider-config
redesign, see above) copied the MCP server entry's "append only if the
section doesn't already exist" policy verbatim. That policy is correct for
the MCP server — nothing else ever legitimately owns that section, so
"don't fight a later edit" is the right default. It was wrong for
providers: the whole point of moving provider credentials into this add-on's
own Configuration tab (see the redesign entry above) was to make it the
**single source of truth** for `api_key`/`model`/`uri`, on the explicit
finding that editing them live through ZeroClaw's own dashboard doesn't
reliably take effect for actual LLM calls. "Leave the existing section
alone" directly contradicted that: once an alias existed on disk (which it
always does after the very first boot), every subsequent key change in
Configuration was silently ignored forever, with no error anywhere — the
add-on kept writing the *old* key's daemon, `unauthorized` at the LLM
provider, no indication the add-on itself was the reason why.

Fix: provider seeding is now a genuine reconcile, every boot, not a
seed-if-missing. Added `delete_toml_section()` (a small `awk` filter: strip
the exact `[section.header]` line through the next `[...]` header or EOF,
no-op if the section isn't present) and call it before re-appending each
configured provider's block, unconditionally. This is a full section
replace, not a field-level patch — any field ZeroClaw's own dashboard might
have independently added into that same section would be lost on the next
boot too, same as before for the fields this add-on does manage. Accepted
as consistent with the existing policy: this add-on's Configuration tab is
authoritative for add-on-managed providers, full stop, not a merge target.

Verified against a real container across three consecutive boots (`docker
run` → edit `options.json` → `docker restart`, each time inspecting
`config.toml` directly): boot 1 seeded `providers.models.openrouter.
household` with a placeholder key; boot 2, same alias with a *different*
key in `options.json`, confirmed the old key was gone, the new key present,
and exactly one `[providers.models.openrouter.household]` header in the
file (no duplicate section from a botched delete); boot 3, same key again,
confirmed the section count stayed at exactly one (true idempotency, not
just "works once after a change"). The unrelated `[providers.models.
openrouter.default]` section (ZeroClaw's own seed-image default) was left
untouched throughout, confirming `delete_toml_section` only ever touches
the one exact header it's given, not anything else matching a loose prefix.

## Scheduling and event-driven triggers: unblocking `cron_*` and `http_request`

User request (2026-08-27): manage scheduled jobs (ZeroClaw's own `cron`)
with the household notified via an AI-generated message when a job runs,
and — more importantly — a way for Home Assistant to trigger the agent
directly on a real event (their example: "tell me when the washing machine
finishes, then start the dryer"), explicitly *not* via a token-costing
`HeartBeat` poll.

This add-on's own part of that feature is entirely about unblocking two
tool families ZeroClaw already ships, not building anything new here — the
actual scheduling (`cron_add`/`cron_list`/`cron_remove`/`cron_update`/
`cron_run`/`cron_runs`, confirmed present and documented in ZeroClaw's own
`docs/book/src/tools/overview.md`) and the event-driven trigger mechanism
(a webhook the companion `ha-zeroclaw-conversation` integration registers,
and an agent's own `http_request` tool calling back into it — see that
repo's `docs/DECISIONS.md` for the full design, including why a
lightweight integration-owned "watch" was chosen over having the agent
author real Home Assistant automations) both live entirely in ZeroClaw
and that other repo. What was actually missing here: both tool families
default to needing an approval prompt (`cron_*`) or being flatly refused
(`http_request`, which has no allowlisted domain until configured) — which
would have made "the agent notices an event and reports back" either
interrupt-driven-with-a-prompt-every-time or simply not work at all.

**`[http_request]` domain allowlist** — confirmed by reading
`crates/zeroclaw-tools/src/http_request.rs`/`crates/zeroclaw-infra/src/
net_guard.rs`: every host is refused by default, and a *private* host
(which `home_assistant_url` almost always is — Supervisor's internal Docker
network) needs to pass two separate gates, `allowed_domains` **and**
`allowed_private_hosts`, not just one. Seeded once (same idempotent
marker-existence pattern as the MCP server block), scoped to exactly the
hostname parsed out of `home_assistant_url` — deliberately not a wildcard
`"*"`, so the tool can reach Home Assistant's webhook and nothing else.

**Risk-profile `auto_approve`** — extended the existing per-agent
reconciliation loop (the same one that seeds `home_assistant__*` MCP tool
permissions) with a second list, `ZC_AUTO_APPROVE_TOOLS`, covering the six
`cron_*` tools and `http_request`. Auto-approving `http_request` here is
safe specifically *because* the allowlist above already constrains its
capability to "can reach Home Assistant, nothing else" — approval policy
and capability boundary are independent controls in ZeroClaw's own model
(`docs/book/src/tools/mcp.md`, "Security and approval" vs "Authorization"),
so widening the former for a tool the latter has already narrowed doesn't
hand out anything broader than that.

Verified against a real container, same methodology as every entry above:
booted with `home_assistant_url`/`home_assistant_token` set, confirmed
`[http_request]` seeded with `allowed_domains = ["homeassistant"]` /
`allowed_private_hosts = ["homeassistant"]`, confirmed `GET /api/config/
drift` reports `{"drifted":[]}` (the new section is valid, not just present
on disk), confirmed all six `cron_*` names plus `http_request` landed in
`risk_profiles.default.auto_approve` alongside the existing
`home_assistant__*` entries, and confirmed a second boot re-seeded neither
section (exactly one `[http_request]` header, no duplicate reconciliation
log lines) — idempotent, not just correct once.

## Pushed to GitHub; CI's first real run caught two real issues

2026-08-27: repo pushed public to `github.com/LorenzoVasi/addon-zeroclaw`
(branch renamed `master` → `main` first, to match what `build.yml`/
`lint.yml` already trigger on). `REPLACE_WITH_GH_OWNER`/
`REPLACE_WITH_MAINTAINER_NAME` filled in across `repository.yaml`/
`README.md`/`DOCS.md`. First CI run on `main` failed both jobs — worth
recording since both were genuine findings, not CI flakiness:

- **shellcheck (SC2034)**: `first_boot` in `run.sh` was assigned (`0`, then
  `1` inside the seed branch) but never actually read anywhere — dead code
  left over from when MCP/provider seeding used to be gated on it, before
  both switched to marker-existence/reconcile-every-boot checks (see
  earlier entries). Removed outright; nothing referenced it.
- **yamllint**: `config.yaml`'s `provider_type` enum line (116 chars) and
  a shell-script line inside `build.yml`'s new `boot-test` job (104 chars)
  both exceeded yamllint's default 80-char line-length limit. Rather than
  manually wrapping either — the TOML-schema enum string can't be split
  without YAML-escaping tricks that would make it harder to read, and
  shell-script lines inside `run:` blocks will always occasionally run
  long — added `.yamllint` at the repo root raising the limit to 130 and
  disabling `document-start` (this repo's workflow files don't use a
  leading `---`, deliberately, matching common GitHub Actions convention)
  and `truthy` (a well-known yamllint false positive on GitHub Actions'
  own `on:` trigger key — YAML 1.1 treats bare `on` as a boolean, GitHub
  Actions treats it as a literal key name; every workflow file in this
  repo trips it for a reason that isn't actually a problem). Verified
  clean locally (`pip install yamllint && python -m yamllint .`) before
  pushing the fix, not just assumed from reading the rule.

`boot-test` (the new smoke-test job, see the entry above) passed on the
follow-up push. `build` did not — a third, separate issue, documented in
its own entry immediately below.

## GHCR image tags must be lowercase; `github.repository` isn't

Follow-up to the entry above: the `build` job's "Build and push" step
failed with `ERROR: failed to build: invalid tag "ghcr.io/LorenzoVasi/
addon-zeroclaw:latest": repository name must be lowercase`. `github.
repository` (used to build `IMAGE_NAME`) preserves the GitHub username's
actual case (`LorenzoVasi`), but Docker/OCI registry references must be
all-lowercase — a real constraint, not a GHCR quirk. GitHub Actions'
expression syntax (the `${{ }}` used in the workflow's `env:` block) has
no built-in string-lowercasing function, so this can't be fixed by
tweaking the expression — moved the computation into an actual shell step
(`tr '[:upper:]' '[:lower:]'`) that writes `IMAGE_NAME` to `$GITHUB_ENV`
instead of a workflow-level `env:` expression. Confirmed the fix the same
way as the line-length one above: not just reasoned through, but pushed
and watched the `build` job's own `Compute lowercase image name` step run
and the subsequent push succeed.

## README hero image, drawn from scratch with Pillow

User request (2026-08-28): a Home Assistant icon and a ZeroClaw icon side
by side at the top of this README. No image-generation tool was
available, so this was drawn programmatically with Pillow (plain shape
primitives, not traced from any existing logo file) — same house glyph
and crab glyph as the brand icon generated for the companion
`ha-zeroclaw-conversation` repo (`assets/ha-zeroclaw.png` here mirrors
`custom_components/zeroclaw_conversation/brand/icon.png` there, same
coordinate math, just laid out as two separate badges instead of one
diagonal split). See that repo's `docs/DECISIONS.md` for the full story,
including three earlier claw-icon attempts that didn't read correctly
before a whole crab silhouette did.

**Superseded the same session**: the drawn version above wasn't wanted —
"usa le icone originali di zeroclaw e homeassistant, non generartele te,
cercale su internet e usa quelle." User supplied the real icons directly
(exact source URLs: Home Assistant's own circuit-tree house mark, and
ZeroClaw's own official claw icon served from `zeroclaw.dev`, their own
domain). `assets/ha-zeroclaw.png` now composites those two real assets
side by side instead of the hand-drawn house/crab. Full story, including
why the first `curl` attempt silently returned an HTML bot-challenge page
instead of the image, in the companion `ha-zeroclaw-conversation` repo's
`docs/DECISIONS.md`.
