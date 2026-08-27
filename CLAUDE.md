# addon-zeroclaw

Home Assistant add-on that packages [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw)
(a self-hosted, provider-agnostic AI agent runtime) as a Docker add-on with
an Ingress-embedded web UI, wired for MCP control of Home Assistant and for
the companion `zeroclaw_conversation` integration to talk to it.

**Companion repo**: `../ha-zeroclaw-conversation` — a custom Home Assistant
integration (Assist conversation agent + `ai_task` provider) that calls
this add-on's gateway over HTTP. The two are separate repos deliberately
(different HA extension mechanisms — see this repo's `docs/DECISIONS.md`
for why) but form one project; changes here often need a matching change
or at least a compatibility check there, and vice versa.

**Read `docs/DECISIONS.md` before assuming anything about how this works.**
It's the detailed, continuously-updated record of every architecture
decision and every bug found — most of them by testing against a real
running container or a real Home Assistant instance, because ZeroClaw's
own docs (and sometimes Home Assistant's) didn't match actual runtime
behavior on the pinned version. Do not re-derive things from the public
docs alone; check DECISIONS.md first, and add to it (don't just fix
silently) when you find something new the hard way.

## Architecture at a glance

- `Dockerfile`: multi-stage — lifts the ZeroClaw binary + web dashboard out
  of `ghcr.io/zeroclaw-labs/zeroclaw:dist-v0.8.4` (distroless, no shell)
  into a `debian:trixie-slim` stage with `nginx-light`, `curl`, `jq`.
- `rootfs/etc/nginx/nginx.conf`: nginx sits in front of ZeroClaw purely to
  (a) strip ZeroClaw's hardcoded anti-iframe headers (breaks HA Ingress
  otherwise) and (b) rewrite ZeroClaw's absolute asset/API paths to carry
  Home Assistant's `X-Ingress-Path` prefix.
- `rootfs/usr/bin/run.sh`: the whole boot sequence — options.json → env
  vars / `config set` calls, first-boot MCP server+bundle seeding, then a
  post-boot reconciliation loop (over the live API, not the offline CLI —
  see DECISIONS.md for why) that grants every existing ZeroClaw agent the
  `home_assistant` MCP bundle, every boot.
- `config.yaml`: deliberately minimal add-on options (bootstrap only —
  `log_level`, `api_token`, `home_assistant_url`, `home_assistant_token`).
  Everything else (LLM provider, agents, channels) is configured inside
  ZeroClaw's own dashboard, reachable via Ingress — see README's "Why so
  few options?".

## Deployment

The user has a real Home Assistant OS instance reachable via Samba shares
mapped as `Y:` (the `addons` share) and `Z:` (the `config` share). After
changing anything here, sync to the live instance with:

```
robocopy "c:\Users\loren\Desktop\addon-zeroclaw" "Y:\zeroclaw" /E /XD .git .claude /XF .gitignore .gitattributes /MIR
```

Then, on the real instance: a `Dockerfile`/`rootfs` change needs an add-on
**rebuild**; a `config.yaml`-only change just needs the Add-on Store
**reloaded**.

**Never touch `Z:\zeroclaw`** — that's the user's own separate, pre-existing,
real ZeroClaw instance (manual setup, real Telegram bots), unrelated to
this add-on.

## Verifying changes before shipping

This project's working method, established the hard way: verify against a
real running container (`docker build` + `docker run` with a fake
`/data/options.json`, `curl` against it) before telling the user something
works. Several "should work per the docs" assumptions turned out wrong on
the actual pinned ZeroClaw version. Don't skip this step for anything
touching `run.sh`, the `Dockerfile`, or `nginx.conf`.
