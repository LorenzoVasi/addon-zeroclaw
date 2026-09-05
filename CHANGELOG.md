# Changelog

Home Assistant shows this file when an update is available, so it's
written for whoever is deciding whether to press the button. Versioning
rules are in [`docs/DECISIONS.md`](docs/DECISIONS.md) ("Versioning and
releases").

## 0.2.0

**Runs ZeroClaw 0.8.5** (was 0.8.4). Real security fixes upstream — a
sandbox escape and a path-traversal write — plus live thinking display
for Anthropic models and several conversations per agent in ZeroClaw's
own dashboard. Nothing in that release's breaking-changes list applies to
this add-on; the whole boot sequence was re-verified against a real
container on the new version before pinning it.

**Costs now show up on ZeroClaw's dashboard.** Every configured provider
is set up to pull live per-token prices from its own model listing, so
the Cost tab shows real figures without you hand-entering a rate sheet.

**Memory keeps what matters instead of everything.** On a fresh install
the agent no longer logs every message you send as conversation history —
it keeps what it deliberately decides to remember (where things are, how
you like things done). It also now backs its durable memories up to a
readable file, collapses near-duplicates, strips secrets and personal
details before saving, and reuses answers to repeated questions instead
of paying for them twice.

> These memory settings are applied on a **fresh install only**, so they
> won't change an add-on that's already running. That's deliberate —
> they're a starting point, not something re-imposed on your own later
> edits.

**New optional `webhook_secret` option.** A second lock on the
agent-facing endpoint, in addition to the API token. If you set it, set
the same value in the `zeroclaw_conversation` integration (0.2.0 or
later) — otherwise its AI Tasks, `notify_agent` calls and watch
follow-ups will be rejected. Assist is unaffected either way. Leave it
blank and nothing changes.

**Self-hosted models no longer "think" out loud.** Providers of type
`ollama` or `custom` are configured to suppress reasoning output, which
the chat-template-aware backends (vLLM, SGLang, llama.cpp) understand.
Cloud providers ignore this, so it isn't written for them.

Smaller things: the README is friendlier and states the MCP Server
requirement up front, there's a one-click "Add repository" badge, and CI
now checks that the boot sequence actually wrote what it claims rather
than only that the container started.

## 0.1.0

- Initial release: packages ZeroClaw (`dist-v0.8.4`) as a Home Assistant add-on
  with Ingress web UI, a curated bootstrap-only options set
  (`log_level`, `api_token`, `home_assistant_url`, `home_assistant_token`),
  and first-boot seeding of a `home_assistant` MCP server entry.
- Verified end-to-end against a real running container: pairing-based
  bearer-token auth on `/webhook` and the REST API, and the MCP server
  seeding, both confirmed working on ZeroClaw `v0.8.4` specifically.
