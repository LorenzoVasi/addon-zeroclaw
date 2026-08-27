# Contributing to addon-zeroclaw

Read [`CLAUDE.md`](CLAUDE.md) and [`docs/DECISIONS.md`](docs/DECISIONS.md)
before changing anything here. `DECISIONS.md` in particular is not
optional background reading — it's the record of everything that turned
out to work differently than the docs said, and several fixes here only
make sense once you know the specific runtime behavior they're working
around.

## The one rule that matters most: verify, don't assume

This add-on wraps a fast-moving upstream (ZeroClaw) whose own docs have
repeatedly not matched the actual behavior of the pinned image version —
not out of malice, just the normal drift between docs and a release. Every
non-trivial fix in `docs/DECISIONS.md` was found by actually running a
container and checking, not by reading harder. Before telling anyone
(including yourself) that a change to `Dockerfile`, `rootfs/`, or
`nginx.conf` works:

```sh
docker build -t zeroclaw-addon-test -f Dockerfile .

mkdir -p /tmp/zc-test/data
cat > /tmp/zc-test/options.json <<'EOF'
{
  "log_level": "info",
  "api_token": "test-token",
  "home_assistant_url": "http://homeassistant:8123",
  "home_assistant_token": "fake-token",
  "providers": []
}
EOF

docker run -d --name zc-test \
  -v /tmp/zc-test/options.json:/data/options.json:ro \
  -v /tmp/zc-test/data:/data/zeroclaw \
  zeroclaw-addon-test

docker logs -f zc-test   # watch it boot
docker exec zc-test curl -s http://127.0.0.1:8099/health
```

For anything touching the config-seeding logic in `run.sh` specifically,
test **at least two boots**, not one: `docker restart zc-test` after
changing `options.json`, then re-inspect
`/tmp/zc-test/data/.zeroclaw/config.toml` directly (`cat`/`grep`) to
confirm the second boot did what you expect — idempotency and
"does this correctly pick up a changed option" bugs only show up on the
second boot, never the first. CI runs a single-boot smoke test
(`.github/workflows/build.yml`, job `boot-test`) automatically, but it
can't catch a second-boot regression — that's still on you locally before
opening a PR.

Clean up when done: `docker rm -f zc-test && rm -rf /tmp/zc-test`.

## Two seeding patterns in `run.sh` — know which one you're extending

Boot-time config seeding in `run.sh` follows one of two deliberately
different patterns. Picking the wrong one for a new option is the most
likely way to introduce a subtle bug here:

- **Seed once, never fight a later edit** (marker-existence check, e.g. the
  `home_assistant` MCP server block): use this for anything the *user*
  might reasonably edit afterward through ZeroClaw's own dashboard/CLI,
  where this add-on's job is only to bootstrap a sane starting point. Once
  the marker exists on disk, the add-on leaves it alone forever.
- **Reconcile every boot** (delete-then-recreate a TOML section, or
  additive-merge for a list value, e.g. providers and risk-profile
  `auto_approve`/`always_ask`): use this for anything this add-on's own
  Configuration tab is the *authoritative* source for. Getting this wrong
  the first time (providers used the "seed once" pattern originally) broke
  API key rotation silently — see `docs/DECISIONS.md` for the full story;
  don't repeat it for a new option that belongs in this category.

If you're not sure which category a new option falls into, ask: "if the
user changes this in the Configuration tab and restarts, should the change
take effect?" Yes → reconcile every boot. No (it's a one-time bootstrap
value) → seed once.

## `config set` only works before the daemon starts

Every `zeroclaw config set` call and every direct `config.toml` edit in
`run.sh` happens **before** `zeroclaw daemon &` starts, never after —
confirmed the hard way that the same command against an already-running
daemon reports success but doesn't actually persist. Anything that needs
to happen against a *live* daemon (the MCP-bundle grant, the risk-profile
reconciliation) goes through the live `/api/config/prop` HTTP endpoint
instead, polled until `/health` responds, never the offline CLI. If you're
adding a new post-boot reconciliation step, follow that same pattern —
don't reach for `zeroclaw config set` there, it won't do what you expect.

## Documenting a finding: append to `docs/DECISIONS.md`, don't just fix it

When you find something that doesn't work the way the docs (ZeroClaw's or
Home Assistant's) say it should, add an entry to `docs/DECISIONS.md`
before or alongside the fix — not after, and not instead of. Entries
follow a loose pattern: what was expected, what was actually observed and
how it was confirmed (exact commands/output where it matters), what the
fix is, and what was verified afterward. Include near-misses and false
alarms too, not just confirmed bugs — a documented "this looked like a bug
but wasn't, here's why" saves the next person from re-investigating the
same dead end. Never edit an old entry to quietly remove a mistaken claim;
add a correction entry that references it instead — the history of what
was believed and why is as useful as the current truth.

## Before opening a PR

- [ ] Boot-tested locally per the section above (at least two boots for
      any seeding-logic change).
- [ ] `docs/DECISIONS.md` updated for anything non-obvious you found or
      changed.
- [ ] `hadolint`, `yamllint`, and `shellcheck` pass (CI runs these; running
      them locally first is faster than round-tripping through CI).
- [ ] If the change is user-visible, `DOCS.md`/`README.md` updated too.

## Why this repo is separate from `ha-zeroclaw-conversation`

Covered in `docs/DECISIONS.md`'s first entry — short version: they're two
different Home Assistant extension mechanisms (a Docker add-on vs. Python
loaded into HA core) with two different distribution channels (a
repository URL vs. HACS), and hassio-addons' own convention is one add-on
per repo. If a change here needs a matching change there (or vice versa),
say so explicitly in the PR description; the two repos don't share CI or
versioning.
