# syntax=docker/dockerfile:1.7

# Pin to the "dist" tag: it's the broadest ZeroClaw feature set still
# published multi-arch (linux/amd64,linux/arm64) — see
# https://github.com/zeroclaw-labs/zeroclaw/blob/master/dev/ci/docker-tags.toml.
# Every officially published ZeroClaw tag is built from a distroless final
# stage (no shell), so we can't `FROM` it directly and run a bootstrap
# script inside it. Instead we lift the finished binary + web dashboard
# assets out of it via multi-stage COPY into a normal Debian base that has
# a shell, bump this ARG when ZeroClaw cuts a new release.
ARG ZEROCLAW_IMAGE_TAG=dist-v0.8.4

FROM ghcr.io/zeroclaw-labs/zeroclaw:${ZEROCLAW_IMAGE_TAG} AS zeroclaw

FROM debian:trixie-slim

# nginx: ZeroClaw's gateway hardcodes `X-Frame-Options: DENY` and a CSP with
# `frame-ancestors 'none'` (crates/zeroclaw-gateway/src/security_headers.rs),
# with no config toggle — that unconditionally blocks Home Assistant's
# Ingress iframe. nginx sits in front of it inside this container purely to
# strip those two response headers; see rootfs/etc/nginx/nginx.conf and
# docs/DECISIONS.md.
# curl: used by run.sh's post-boot agent/MCP-bundle reconciliation — talks
# to ZeroClaw's own live REST API over loopback (see docs/DECISIONS.md for
# why that's the only reliable way to read/write dynamic config maps like
# `agents.<alias>.mcp_bundles`; the offline CLI can't read or reliably
# write them).
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        nginx-light \
    && rm -rf /var/lib/apt/lists/*

COPY --from=zeroclaw /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw
COPY --from=zeroclaw /usr/share/zeroclawlabs/web/dist /usr/share/zeroclawlabs/web/dist
# The upstream image bakes a working default config.toml (gateway port,
# empty api_key, sane risk_profiles) at /zeroclaw-data. We keep a copy at a
# separate path and seed it into the add-on's persistent /data volume on
# first boot only (see rootfs/usr/bin/run.sh) — never overwriting a config
# the user has since edited through ZeroClaw's own dashboard.
COPY --from=zeroclaw /zeroclaw-data /opt/zeroclaw-seed

COPY rootfs/etc/nginx/nginx.conf /etc/nginx/nginx.conf
COPY rootfs/usr/bin/run.sh /usr/bin/run.sh
RUN chmod +x /usr/bin/run.sh

ENV LANG=C.UTF-8
ENV ZEROCLAW_gateway__web_dist_dir=/usr/share/zeroclawlabs/web/dist

HEALTHCHECK --interval=60s --timeout=10s --retries=3 --start-period=15s \
    CMD ["zeroclaw", "status", "--format=exit-code"]

ENTRYPOINT ["/usr/bin/run.sh"]
