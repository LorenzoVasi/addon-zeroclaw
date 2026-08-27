# Changelog

## 0.1.0

- Initial release: packages ZeroClaw (`dist-v0.8.4`) as a Home Assistant add-on
  with Ingress web UI, a curated bootstrap-only options set
  (`log_level`, `api_token`, `home_assistant_url`, `home_assistant_token`),
  and first-boot seeding of a `home_assistant` MCP server entry.
- Verified end-to-end against a real running container: pairing-based
  bearer-token auth on `/webhook` and the REST API, and the MCP server
  seeding, both confirmed working on ZeroClaw `v0.8.4` specifically.
