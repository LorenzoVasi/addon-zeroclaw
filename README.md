# ZeroClaw — Home Assistant Add-on

Runs [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — a self-hosted,
provider-agnostic autonomous AI agent — as a Home Assistant add-on, with:

- A **web dashboard** (chat, memory, config, cron, tool inspection) exposed
  through Home Assistant **Ingress** — no port forwarding, no separate login,
  reachable straight from the Home Assistant sidebar.
- First-boot seeding of an **MCP server entry** pointed at Home Assistant's
  own [`mcp_server`](https://www.home-assistant.io/integrations/mcp_server/)
  integration, so ZeroClaw can discover and act on your entities/services as
  tools.
- A shared bearer token (`api_token`) that lets the companion
  [`zeroclaw_conversation`](https://github.com/LorenzoVasi/ha-zeroclaw-conversation)
  custom integration register ZeroClaw as an **Assist conversation agent** —
  so the Assist mic/text box talks to ZeroClaw directly.

## Install

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**,
   add this repository's URL.
2. Install **ZeroClaw**, open its **Configuration** tab, set an `api_token`
   (any random string — reuse it later in the `zeroclaw_conversation`
   integration's setup).
3. Optional but recommended: paste a Home Assistant
   [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile)
   into `home_assistant_token` so ZeroClaw is pre-wired to control Home
   Assistant via MCP on first boot.
4. Start the add-on, open its **Web UI** (Ingress panel) and finish setup
   inside ZeroClaw itself — pick your LLM provider and paste its API key
   there. This add-on deliberately does not duplicate ZeroClaw's own
   configuration UI; only the bootstrap options above live in the HA
   Configuration tab.
5. (Optional) Install the
   [`zeroclaw_conversation`](https://github.com/LorenzoVasi/ha-zeroclaw-conversation)
   custom integration to wire ZeroClaw into the Assist pipeline.

Full walkthrough: [DOCS.md](DOCS.md).

## Why so few options here?

ZeroClaw already ships a complete configuration UI and REST API of its own
(`/api/config/*`, reachable through this add-on's Ingress web UI). Mirroring
that as Home Assistant add-on options would just create two out-of-sync
places to configure the same thing. This add-on's options are limited to what
is needed to get ZeroClaw booted, reachable, and securable — everything else
(LLM provider, channels, agents, risk profiles) is configured live inside
ZeroClaw's own dashboard, and persists across add-on restarts/updates in the
add-on's data volume.

## Architectures

`amd64`, `aarch64` — matches ZeroClaw's own published multi-arch images.

## License

This repository is MIT-licensed (see [LICENSE](LICENSE)). It builds on top of
ZeroClaw's own published container images; ZeroClaw itself is licensed
separately by ZeroClaw Labs (Apache-2.0 OR MIT).
