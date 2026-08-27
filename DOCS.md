# Home Assistant Add-on: ZeroClaw

## Installation

1. Add this repository to your Home Assistant add-on store
   (**Settings → Add-ons → Add-on Store → ⋮ → Repositories**).
2. Find **ZeroClaw** in the store and click **Install**.

## First-time setup

1. Open the add-on's **Configuration** tab and set:
   - **`api_token`** — any random string. This protects ZeroClaw's `/webhook`
     endpoint and REST API (via ZeroClaw's pairing mechanism), which is what
     the `zeroclaw_conversation` Home Assistant integration calls when
     Assist routes a message to ZeroClaw. Generate one with, e.g.,
     `openssl rand -hex 32` on any machine.
   - **`home_assistant_token`** *(optional but recommended)* — a
     [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile)
     from your Home Assistant user profile. Used **once**, on first boot
     only, to pre-configure ZeroClaw's connection to Home Assistant's
     [`mcp_server`](https://www.home-assistant.io/integrations/mcp_server/)
     integration. Skip it and configure the MCP server by hand later from
     ZeroClaw's own dashboard if you'd rather not paste a token here.
   - **`home_assistant_url`** — leave as the default
     (`http://homeassistant:8123`, the Supervisor's internal DNS name for
     Home Assistant Core itself) unless you know you need something else.
   - **`log_level`** — `info` is fine for normal use; `debug`/`trace` for
     troubleshooting.
   - **`providers`** *(optional, one or more)* — pre-configure one or more
     LLM model providers here (type, an alias name for this credential
     set, its API key, and optionally a default model / custom endpoint
     URI) rather than through ZeroClaw's own dashboard. Each entry is
     seeded into ZeroClaw **before** the daemon starts, every boot — add a
     new entry later and restart the add-on to pick it up. Do this if you
     plan to use the `zeroclaw_conversation` integration's "create a new
     agent" flow, which picks from these rather than asking for fresh
     credentials itself (more reliable — see docs/DECISIONS.md for why
     that changed). Not required: you can still add/edit providers
     entirely inside ZeroClaw's own dashboard instead, same as before —
     this is an additional option, not a replacement.
2. **Start** the add-on.
3. Open its **Web UI** (the Ingress panel, from the add-on's Info tab or the
   Home Assistant sidebar). This is ZeroClaw's own dashboard.
4. If you didn't pre-configure a provider in step 1, finish that part of
   ZeroClaw's own setup here instead: pick an LLM provider (Anthropic,
   OpenAI, OpenRouter, a local Ollama, or any of the ~20 others it
   supports) and paste that provider's API key. Either path works — see
   "Why so few options?" in the [README](README.md) for why most
   configuration still happens inside ZeroClaw's own dashboard rather than
   this add-on's Configuration tab.
5. If you supplied a Home Assistant token in step 1, check
   **Settings → MCP Servers** inside the ZeroClaw dashboard: you should see a
   `home_assistant` entry already configured, with a matching MCP bundle.
   Every agent — including ones you create later with ZeroClaw's own
   Quickstart wizard — is automatically granted this bundle **on every
   add-on boot** (not retroactively while it's running: create/rename an
   agent, then restart the add-on, or wait for its next natural restart,
   for it to pick up access). This is a deliberate departure from
   ZeroClaw's own default (which requires an explicit per-agent grant, by
   design, for security) — see docs/DECISIONS.md if you'd rather turn it
   off and grant bundles by hand instead.
   - If the entry's `Authorization` header wasn't set automatically (check
     the add-on's **Log** tab for a warning), add it by hand: header name
     `Authorization`, value `Bearer <your-token>`.
   - Every agent's **risk profile** is also seeded with a default permission
     policy for the `home_assistant` MCP tools, on every boot: general home
     control (lights, climate, media, timers, lists, and so on) is fully
     auto-approved, no confirmation of any kind. Opening/closing/moving a
     **cover** entity — garage door, gate, blinds, window — always asks for
     confirmation first, regardless of the agent's own autonomy level. This
     is additive-only: if you later change a tool's approval setting
     yourself (in ZeroClaw's own dashboard, under that risk profile), the
     add-on won't move it back on the next boot. **Important caveat:**
     Home Assistant's *generic* on/off/toggle tools can also open covers and
     lock/unlock doors, and those stay auto-approved (they're the same tools
     used for ordinary lights/switches) — see docs/DECISIONS.md
     ("Default `home_assistant__*` risk-profile permissions") for exactly
     why this can't be closed at the permission level, and how the
     companion `zeroclaw_conversation` integration's agent-creation flow
     mitigates it through the agent's own instructions instead.
   - Also unblocked, every boot, for the same agents: ZeroClaw's own
     `cron_*` tools (so it can manage scheduled jobs without an approval
     prompt on every add/list/remove) and `http_request`, scoped to only
     the `home_assistant_url` host — this is what lets an agent notify you
     or watch for an event-driven trigger (e.g. "tell me when the washing
     machine finishes") without polling. That side of the feature is set up
     in the companion `zeroclaw_conversation` integration, not here — see
     its own README.

## Enabling Assist

Making the Home Assistant **Assist** button talk to ZeroClaw needs a second,
separate piece: the
[`zeroclaw_conversation`](https://github.com/LorenzoVasi/ha-zeroclaw-conversation)
custom integration (install via HACS or manually into
`config/custom_components/`). It is *not* part of this add-on — it's Python
code that runs inside Home Assistant core, not inside this container. Once
installed:

1. **Settings → Devices & Services → Add Integration → ZeroClaw Conversation**.
2. Enter the add-on's internal address — `http://local-zeroclaw:42617`
   for a locally installed add-on (the common case; confirmed by running
   `hostname` inside the running container on a real Home Assistant
   instance). If installed from a published repository instead, or if you
   have another ZeroClaw instance also reachable on your network, don't
   assume — run `hostname` inside the container itself (Portainer's
   console, or the SSH add-on) to check. Note this is **not** the same as
   the Docker container name Portainer's list shows
   (`app_local_zeroclaw`, underscored) — Supervisor sanitizes container
   names into hyphenated hostnames, so the two strings differ. Also enter
   the same `api_token` you set above.
3. **Settings → Voice Assistants**, edit (or create) a pipeline, and pick
   **ZeroClaw** as its conversation agent.
4. Talk to Assist. ZeroClaw replies, and — if you granted it the
   `home_assistant` MCP server — can act on your entities/services too.

## Data & backups

ZeroClaw's config, memory, and workspace live in this add-on's private data
volume (`/data/zeroclaw` inside the container) and are included in Home
Assistant's normal Backups.

## Security notes

- This add-on publishes **no host ports**. It's reachable only via Ingress
  (gated by your Home Assistant login) and via the internal Supervisor
  network (used by `zeroclaw_conversation`).
- Setting an `api_token` turns on ZeroClaw's pairing enforcement
  (`gateway.require_pairing = true`) with that token pre-authorized, so both
  `/webhook` and the REST API require `Authorization: Bearer <api_token>`.
  Leaving it empty disables pairing entirely, relying only on network
  isolation (no published port) as the security boundary.
- Always set an `api_token`. An empty one leaves the gateway open to
  anything that can reach the add-on's internal address.

## Support

This is a community add-on wrapping the upstream
[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) project. For
ZeroClaw usage questions (providers, channels, agents, tools), see
[ZeroClaw's own docs](https://docs.zeroclawlabs.ai/). For issues specific to
this packaging (the add-on itself), open an issue on this repository.
