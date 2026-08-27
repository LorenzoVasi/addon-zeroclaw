#!/usr/bin/env bash
# Bootstraps ZeroClaw inside the Home Assistant add-on container: reads
# /data/options.json (the add-on's HA-managed options), seeds a default
# ZeroClaw config on first boot only, maps the curated options onto
# ZeroClaw's config (env vars where available, `config set` / direct TOML
# append otherwise — see docs/DECISIONS.md for why), then starts ZeroClaw
# (loopback-only) behind the nginx front-end from rootfs/etc/nginx/nginx.conf
# — required because ZeroClaw's gateway hardcodes `X-Frame-Options: DENY` /
# a frame-denying CSP with no config toggle, which otherwise breaks Home
# Assistant's Ingress iframe outright (confirmed against a real HA instance).
#
# Every non-obvious step below was verified against a real
# ghcr.io/zeroclaw-labs/zeroclaw:dist-v0.8.4 container, not just the docs —
# several things documented on ZeroClaw's `master` branch (a `gateway.
# webhook_secret` field, `config set` on a dynamic mcp.servers.<name>.<field>
# path) do not exist yet in the 0.8.4 release this add-on pins. See
# docs/DECISIONS.md for what was actually tested and how.
set -euo pipefail

OPTIONS_FILE="/data/options.json"
DATA_DIR="/data/zeroclaw"
SEED_DIR="/opt/zeroclaw-seed"
ZEROCLAW_HOME_DIR="${DATA_DIR}/.zeroclaw"
CONFIG_FILE="${ZEROCLAW_HOME_DIR}/config.toml"

mkdir -p "${DATA_DIR}"

export HOME="${DATA_DIR}"
export ZEROCLAW_DATA_DIR="${DATA_DIR}/data"

first_boot=0
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "[zeroclaw-addon] No existing config at ${CONFIG_FILE}; seeding ZeroClaw's default config."
    cp -r "${SEED_DIR}/.zeroclaw" "${DATA_DIR}/"
    first_boot=1
    # The baked-in seed's schema version has, in practice, always been
    # current for the pinned image tag, but `config migrate` is a cheap
    # no-op when it already is — cheaper than assuming and finding out
    # `config set` refuses to run against a stale schema version.
    zeroclaw config migrate || true

    # The baked-in seed's `risk_profiles.default.auto_approve` list is
    # missing three entries (`tool_search`, `browser`, `browser_open`) that
    # this same ZeroClaw version's own in-memory defaults already include —
    # a genuine mismatch in the upstream image, confirmed via
    # `GET /api/config/drift` on a freshly booted container, present on
    # every fresh boot regardless of anything this add-on does. It shows up
    # in the dashboard as a persistent "1 path differ from on-disk" banner.
    # `/admin/reload` does NOT clear it (confirmed — reload just re-applies
    # the same mismatched defaults); only writing the reconciled value to
    # disk does. Must run before `zeroclaw daemon` starts — the same
    # `config set` command against an *already-running* daemon silently
    # fails to persist (confirmed by inspecting config.toml directly
    # afterward), for reasons not fully understood; every other `config
    # set` call in this script is pre-daemon-start for the same reason.
    zeroclaw config set --no-interactive risk_profiles.default.auto_approve \
        '["file_read","file_write","file_edit","memory_recall","memory_store","web_search_tool","web_fetch","calculator","glob_search","content_search","image_info","weather","git_operations","tool_search","browser","browser_open"]' \
        || echo "[zeroclaw-addon] WARNING: could not reconcile risk_profiles.default.auto_approve drift — the dashboard may show a one-time 'path differs from on-disk' banner."
fi

# ZeroClaw binds loopback-only on an internal port; nginx (started below) is
# the only thing that talks to it, listening on 42617 (the add-on's
# ingress_port) and proxying through — see the nginx-in-front rationale
# above CONFIG_FILE and docs/DECISIONS.md. No `allow_public_bind` needed
# since this never binds a non-loopback address.
export ZEROCLAW_gateway__host="127.0.0.1"
export ZEROCLAW_gateway__port="8099"

log_level="$(jq -r '.log_level // "info"' "${OPTIONS_FILE}")"
api_token="$(jq -r '.api_token // empty' "${OPTIONS_FILE}")"
ha_url="$(jq -r '.home_assistant_url // empty' "${OPTIONS_FILE}")"
ha_token="$(jq -r '.home_assistant_token // empty' "${OPTIONS_FILE}")"

# Diagnostic only — never logs the actual secret values, just whether they
# were read as empty or not and the raw options.json keys, so a "pairing
# still asked for" report can be root-caused from the Log tab alone instead
# of guessing blind. Safe to remove once the api_token empty-value path is
# confirmed working against a real Supervisor.
echo "[zeroclaw-addon] DEBUG options.json keys: $(jq -r 'keys | join(", ")' "${OPTIONS_FILE}")"
echo "[zeroclaw-addon] DEBUG api_token: $([ -n "${api_token}" ] && echo "non-empty (${#api_token} chars)" || echo "EMPTY")"

# Standard Rust/tracing log-level env var — ZeroClaw has no dedicated
# `log_level` config field, see docs/ops/service.md upstream.
export RUST_LOG="zeroclaw=${log_level}"

# Authentication for machine callers (the zeroclaw_conversation integration's
# calls to /webhook): ZeroClaw 0.8.4 has no generic webhook-secret header —
# that only exists on ZeroClaw's unreleased `master` branch. The mechanism
# that *does* work in 0.8.4, confirmed against a running container, is
# pairing: `gateway.require_pairing = true` + a statically pre-provisioned
# `gateway.paired_tokens` entry, checked as a normal `Authorization: Bearer
# <token>` header — the same pattern ZeroClaw's own docs show for a
# long-lived, non-interactive pairing. `--no-interactive` is required for
# `config set` on this field; without it, a #[secret]-typed field prompts
# for masked terminal input and fails non-interactively.
if [ -n "${api_token}" ]; then
    zeroclaw config set --no-interactive gateway.require_pairing true
    zeroclaw config set --no-interactive gateway.paired_tokens "[\"${api_token}\"]"
else
    echo "[zeroclaw-addon] WARNING: no api_token set in add-on options — /webhook and the REST API are open to anything that can reach the add-on's internal address. Set one in the add-on Configuration tab."
    zeroclaw config set --no-interactive gateway.require_pairing false
fi

# Lets the dashboard's own "reload" action (shown when it detects the
# on-disk config drifted from what the running daemon has in memory) work
# from inside the Ingress iframe. Documented as safe to set unconditionally:
# ZeroClaw only honors `allow_remote_admin` when `gateway.require_pairing`
# is ALSO true — with pairing off (the branch above, when api_token is
# empty), a remote /admin/reload is rejected with 403 regardless of this
# flag, by ZeroClaw's own design ("impossible to expose an unauthenticated
# remote reload by flipping a single flag"). So this line only actually
# does anything once an api_token is set.
zeroclaw config set --no-interactive gateway.allow_remote_admin true

# MCP server seeding — idempotent on the `[mcp_bundles.home_assistant]`
# marker existing in the file, NOT gated on first_boot. It used to be
# first-boot-only, on the theory of "never fight the user's own later
# edits" (same reasoning still applied to the *provider* seeding above) —
# but that guard means "never seed at all" for anyone who sets
# home_assistant_token *after* their first boot (i.e. anyone who installs
# the add-on, boots it once without a token, then comes back to add one —
# an entirely normal sequence, confirmed the hard way: a real install
# where config.toml already existed by the time the token was set never
# got the MCP entry at all, on any subsequent boot, silently). Checking
# for the specific marker instead of first_boot fixes that while keeping
# the same "don't re-seed / don't clobber" property once it *has* been
# seeded once — same pattern as the provider-seeding loop below.
#
# `zeroclaw config set` does NOT support writing into a dynamic
# `mcp.servers.<name>.<field>` map path in 0.8.4 (`Error: Unknown property
# ...` — confirmed against a running container; reading that same path
# back via `GET /api/config/list` works fine, so this is a write-side gap
# in this release's CLI, not a runtime limitation). Appending the
# `[[mcp.servers]]` TOML block directly, in the exact shape ZeroClaw
# itself writes, is the verified-working alternative — confirmed the
# daemon loads it (visible via the config API) and starts cleanly. A
# plaintext header value here is accepted on load same as an
# `enc2:`-encrypted one; ZeroClaw re-encrypts it the next time it's saved
# through the CLI/API/dashboard.
if [ -n "${ha_url}" ] && [ -n "${ha_token}" ] \
    && ! grep -qF "[mcp_bundles.home_assistant]" "${CONFIG_FILE}" 2>/dev/null; then
    echo "[zeroclaw-addon] Seeding a home_assistant MCP server entry."
    cat >> "${CONFIG_FILE}" <<EOF

[[mcp.servers]]
args = []
command = ""
name = "home_assistant"
transport = "http"
url = "${ha_url%/}/api/mcp"

[mcp.servers.env]

[mcp.servers.headers]
Authorization = "Bearer ${ha_token}"

[mcp_bundles.home_assistant]
servers = ["home_assistant"]
exclude = []
EOF
    # Defining the server and the bundle here is as far as *this* step can
    # go: ZeroClaw requires an agent to explicitly list a bundle in its own
    # `mcp_bundles` before it connects to anything ("an agent with no
    # mcp_bundles connects to no MCP servers, even when mcp.servers is
    # non-empty" — ZeroClaw's own docs), and no agent exists yet at this
    # point in the boot sequence (including one ZeroClaw's own Quickstart
    # wizard creates later). Granting every *existing* agent this bundle —
    # including ones created after this add-on's first boot — is handled
    # below, once ZeroClaw is actually running, on every boot.
    echo "[zeroclaw-addon] home_assistant MCP server and bundle configured."
elif [ -n "${ha_url}" ] && [ -n "${ha_token}" ]; then
    echo "[zeroclaw-addon] home_assistant MCP server already configured; leaving it as-is."
fi

# `http_request` domain allowlist seeding — lets an agent call back into
# Home Assistant with its own built-in `http_request` tool (POST/GET, not
# MCP), needed for the "AI proactively notifies the household" flow: the
# companion `zeroclaw_conversation` integration registers an HA webhook an
# agent can POST a message to, and ZeroClaw's `http_request` tool refuses
# every host by default unless it's explicitly allowlisted — confirmed by
# reading `crates/zeroclaw-tools/src/http_request.rs`: a *private* host
# (which `home_assistant_url` almost always is — Supervisor's internal
# Docker network) needs to pass two separate gates, `[http_request].
# allowed_domains` AND `.allowed_private_hosts`, not just one; a bare
# hostname with no scheme/port is the correct entry for both (`domain_guard
# ::host_matches_allowlist` matches on host only). Deliberately scoped to
# exactly the Home Assistant hostname, not a wildcard `"*"` — the tool can
# then reach HA's webhook endpoint and nothing else, so auto-approving it
# below (see the risk-profile reconciliation) doesn't hand out open
# internet/internal-network access, only "can call Home Assistant."
# Seeded once, same idempotent marker-existence pattern as the MCP server
# block above (a hostname derived from `home_assistant_url` essentially
# never changes; if it ever does, this is a one-line hand-edit away).
if [ -n "${ha_url}" ] \
    && ! grep -qF "[http_request]" "${CONFIG_FILE}" 2>/dev/null; then
    ha_host="$(echo "${ha_url}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/].*$##')"
    if [ -n "${ha_host}" ]; then
        echo "[zeroclaw-addon] Seeding http_request allowlist for Home Assistant host '${ha_host}'."
        cat >> "${CONFIG_FILE}" <<EOF

[http_request]
allowed_domains = ["${ha_host}"]
allowed_private_hosts = ["${ha_host}"]
EOF
    fi
elif [ -n "${ha_url}" ]; then
    echo "[zeroclaw-addon] http_request allowlist already configured; leaving it as-is."
fi

# Model provider seeding — runs every boot, and *reconciles* (not just
# seeds-if-missing): the add-on's Configuration tab is the authoritative
# source for these fields, so a changed api_key/model/uri there must
# actually take effect on the next restart, not be silently ignored because
# a section with that alias already exists on disk. Originally this was
# "append only if missing" (matching the MCP server's own "seed once, never
# fight later edits" policy above) — but that was wrong for providers
# specifically: unlike the MCP server (which nothing else ever legitimately
# rewrites), this add-on's whole provider-config redesign made
# api_key/model/uri here the single source of truth for these fields, on
# the explicit basis that live-dashboard edits don't reliably take effect
# (see the note below) — so "already exists, leave it alone" quietly broke
# key rotation: a user who pasted a new token into Configuration and
# restarted kept hitting `unauthorized`, because the *old* key was still
# the one on disk. Confirmed and fixed 2026-08-27.
#
# Reconciliation is delete-section-then-append: `delete_toml_section` strips
# every line from the exact `[providers.models.<type>.<alias>]` header up to
# (not including) the next `[...]` header or EOF, then the fresh block is
# appended with whatever `providers.json` currently says — a full replace,
# not a field-by-field patch, so any field ZeroClaw's own dashboard might
# have added into that same section independently would be lost too. That's
# an accepted tradeoff, not an oversight: the "live dashboard edits don't
# reliably take effect for provider credentials anyway" finding below
# already made this add-on's Configuration tab the only supported way to
# manage these fields.
#
# Written into config.toml directly (not through `zeroclaw config set`,
# which does not support this dynamic map path either — see the mcp.servers
# entry above for the same limitation) and — critically — *before*
# `zeroclaw daemon` starts. This is deliberate: writing provider credentials
# through the *live* API (`PUT /api/config/prop` on an already-running
# daemon, e.g. from ZeroClaw's own dashboard) does not reliably take effect
# for LLM calls even though the write itself succeeds and persists to disk
# — confirmed the hard way (a real agent kept failing with "credentials not
# set" after its api_key was set live through the dashboard). Every other
# `config set`/file-write in this script already happens pre-daemon-start
# for a related but distinct reliability reason (see docs/DECISIONS.md) —
# this is the same rule applied to a new case.
delete_toml_section() {
    # $1 = config file, $2 = exact "[section.header]" line to remove, along
    # with every line after it up to (not including) the next top-level
    # `[...]` header or EOF. A no-op (byte-identical output) if the section
    # isn't present at all.
    awk -v section="$2" '
        $0 == section { skip=1; next }
        skip && /^\[/ { skip=0 }
        skip { next }
        { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

provider_count="$(jq '(.providers // []) | length' "${OPTIONS_FILE}")"
if [ "${provider_count}" -gt 0 ]; then
    echo "[zeroclaw-addon] Reconciling ${provider_count} configured model provider(s)."
    i=0
    while [ "${i}" -lt "${provider_count}" ]; do
        entry="$(jq -c ".providers[${i}]" "${OPTIONS_FILE}")"
        p_type="$(echo "${entry}" | jq -r '.provider_type // empty')"
        p_alias="$(echo "${entry}" | jq -r '.alias // empty')"
        p_api_key="$(echo "${entry}" | jq -r '.api_key // empty')"
        p_model="$(echo "${entry}" | jq -r '.model // empty')"
        p_uri="$(echo "${entry}" | jq -r '.uri // empty')"
        i=$((i + 1))

        if [ -z "${p_type}" ] || [ -z "${p_alias}" ]; then
            echo "[zeroclaw-addon] WARNING: skipping a provider entry missing provider_type or alias."
            continue
        fi

        section="[providers.models.${p_type}.${p_alias}]"
        if grep -qF "${section}" "${CONFIG_FILE}" 2>/dev/null; then
            echo "[zeroclaw-addon] Provider ${p_type}.${p_alias} already configured; reconciling to match the Configuration tab."
            delete_toml_section "${CONFIG_FILE}" "${section}"
        else
            echo "[zeroclaw-addon] Seeding provider ${p_type}.${p_alias}."
        fi

        {
            echo ""
            echo "${section}"
            [ -n "${p_api_key}" ] && printf 'api_key = "%s"\n' "${p_api_key}"
            [ -n "${p_model}" ] && printf 'model = "%s"\n' "${p_model}"
            [ -n "${p_uri}" ] && printf 'uri = "%s"\n' "${p_uri}"
        } >> "${CONFIG_FILE}"
    done
fi

nginx -t

# Two long-lived processes, no s6-overlay (this is otherwise a
# single-process wrapper, not worth the extra machinery): start ZeroClaw in
# the background, run nginx in the foreground, and propagate a stop signal
# to both so `docker stop` / HA's add-on stop actually terminates the
# container instead of leaving an orphaned ZeroClaw process behind.
zeroclaw daemon &
ZEROCLAW_PID=$!

# Grant every *existing* agent the home_assistant MCP bundle, every boot —
# not just agents that existed at first-boot seed time. Runs against the
# LIVE daemon over loopback (always allowed regardless of pairing), because
# this is the only reliable way to read or write a dynamic config map like
# `agents.<alias>.mcp_bundles` at all: confirmed against a running
# container that the offline CLI (`config get`/`config set`) fails outright
# ("Unknown property") for this path, `config list` doesn't surface it
# either, and even `config patch` — which does resolve the path — hit an
# unrelated hard validation error in testing that the live HTTP API only
# ever surfaced as a non-blocking warning. The live `/api/config/prop`
# GET+PUT round trip was the one path confirmed to both read and persist
# correctly. See docs/DECISIONS.md.
#
# Deliberately goes against ZeroClaw's own "no implicit grants" default —
# the user explicitly asked for auto-granting every agent, understanding
# the tradeoff (see docs/DECISIONS.md); this is not ZeroClaw's own behavior.
# Default risk-profile permissions for the home_assistant MCP tools, applied
# below to every agent's risk profile alongside the bundle grant. Split into
# two tool-name lists per the user's explicit policy: general home control
# stays fully auto-approved (no confirmation of any kind), while the cover
# tools that can open a garage door/gate/window (or leave one ajar) always
# require operator approval.
#
# This is tool-*name* granularity only — ZeroClaw's risk profile has no
# concept of "this entity" vs "that entity" within one tool call (confirmed
# in ZeroClaw's own docs/book/src/security/autonomy.md: auto_approve/
# always_ask/excluded_tools are flat tool-name lists). That matters because
# Home Assistant's own generic `HassTurnOn`/`HassTurnOff`/`HassToggle`
# intents are NOT lights/switches-only — confirmed by reading
# homeassistant/components/intent/__init__.py (OnOffIntentHandler): they
# also lock/unlock `lock.*` entities and open/close `cover.*` and `valve.*`
# entities. Since those three generic tools must stay in auto_approve for
# ordinary "turn on the light" requests to stay confirmation-free (the
# user's explicit ask), a cooperative-but-careless agent could technically
# open a gate via `HassTurnOn` instead of the gated `HassOpenCover` — ZeroClaw
# has no lever to close that specific gap without also gating ordinary
# lights/switches, which the user does not want. Locks have the same gap and
# no dedicated tool to gate at all: Home Assistant ships no `HassLock`/
# `HassUnlock` intent (confirmed — the `lock` component has no intent.py),
# so lock/unlock ONLY ever goes through the generic always-free
# HassTurnOn/HassTurnOff/HassToggle. The user chose (2026-08-26, see
# docs/DECISIONS.md) to accept this and mitigate it with an explicit
# personality-file instruction telling the agent to always use the dedicated
# cover tools and to always ask before locking/unlocking — soft enforcement,
# not a hard gate, since ZeroClaw has no harder lever available here.
HA_ALWAYS_ASK_TOOLS='["home_assistant__HassOpenCover","home_assistant__HassCloseCover","home_assistant__HassSetPosition","home_assistant__HassStopMoving"]'
HA_AUTO_APPROVE_TOOLS='["home_assistant__HassTurnOn","home_assistant__HassTurnOff","home_assistant__HassToggle","home_assistant__HassGetState","home_assistant__HassNevermind","home_assistant__HassRespond","home_assistant__HassBroadcast","home_assistant__HassLightSet","home_assistant__HassClimateSetTemperature","home_assistant__HassClimateGetTemperature","home_assistant__HassFanSetSpeed","home_assistant__HassHumidifierSetpoint","home_assistant__HassHumidifierMode","home_assistant__HassMediaPause","home_assistant__HassMediaUnpause","home_assistant__HassMediaNext","home_assistant__HassMediaPrevious","home_assistant__HassMediaPlayerMute","home_assistant__HassMediaPlayerUnmute","home_assistant__HassSetVolume","home_assistant__HassSetVolumeRelative","home_assistant__HassMediaSearchAndPlay","home_assistant__HassListAddItem","home_assistant__HassListCompleteItem","home_assistant__HassListRemoveItem","home_assistant__HassShoppingListAddItem","home_assistant__HassShoppingListCompleteItem","home_assistant__HassShoppingListLastItems","home_assistant__HassStartTimer","home_assistant__HassCancelTimer","home_assistant__HassCancelAllTimers","home_assistant__HassIncreaseTimer","home_assistant__HassDecreaseTimer","home_assistant__HassPauseTimer","home_assistant__HassUnpauseTimer","home_assistant__HassTimerStatus","home_assistant__HassGetCurrentDate","home_assistant__HassGetCurrentTime","home_assistant__HassGetWeather","home_assistant__HassVacuumStart","home_assistant__HassVacuumReturnToBase","home_assistant__HassVacuumCleanArea","home_assistant__HassLawnMowerStartMowing","home_assistant__HassLawnMowerDock","home_assistant__GetLiveContext"]'

# ZeroClaw's own built-in (non-MCP) tools needed for the scheduling +
# proactive-notification feature: `cron_*` so an agent can manage its own
# scheduled jobs ("ricordami ogni mattina alle 8 di...") without an approval
# prompt on every single add/list/remove call, and `http_request` so it can
# call the notify webhook the `zeroclaw_conversation` integration registers
# (see docs/DECISIONS.md) without a prompt either. Auto-approving
# `http_request` here is safe specifically *because* it's scoped to only
# the Home Assistant host via `[http_request].allowed_domains`/
# `.allowed_private_hosts` above — the approval gate and the capability
# boundary are two different, independent controls (see ZeroClaw's own
# docs/book/src/tools/mcp.md, "Security and approval" vs "Authorization"),
# and this only widens the former for a tool the latter has already
# constrained to "can reach Home Assistant, nothing else."
ZC_AUTO_APPROVE_TOOLS='["cron_add","cron_list","cron_remove","cron_update","cron_run","cron_runs","http_request"]'

if [ -n "${ha_url}" ] && [ -n "${ha_token}" ]; then
    echo "[zeroclaw-addon] Waiting for ZeroClaw to come up for MCP bundle reconciliation..."
    zc_ready=0
    for _ in $(seq 1 30); do
        if curl -sf -m 2 "http://127.0.0.1:8099/health" >/dev/null 2>&1; then
            zc_ready=1
            break
        fi
        sleep 1
    done

    if [ "${zc_ready}" = "1" ]; then
        auth_args=()
        if [ -n "${api_token}" ]; then
            auth_args=(-H "Authorization: Bearer ${api_token}")
        fi

        agents_response="$(curl -sf -m 10 "${auth_args[@]}" "http://127.0.0.1:8099/api/quickstart/state" 2>/dev/null || echo '{}')"
        agent_list="$(echo "${agents_response}" | jq -r '.agents[]? // empty' 2>/dev/null || true)"

        if [ -n "${agent_list}" ]; then
            echo "[zeroclaw-addon] Reconciling home_assistant MCP bundle and tool permissions for agents: $(echo "${agent_list}" | tr '\n' ' ')"
            while IFS= read -r agent; do
                [ -z "${agent}" ] && continue
                prop_response="$(curl -sf -m 10 "${auth_args[@]}" "http://127.0.0.1:8099/api/config/prop?path=agents.${agent}.mcp_bundles" 2>/dev/null || echo '{}')"
                current_bundles="$(echo "${prop_response}" | jq -c '(.value // "[]") | fromjson? // []' 2>/dev/null || echo '[]')"
                already_granted="$(echo "${current_bundles}" | jq 'index("home_assistant") != null' 2>/dev/null || echo 'true')"
                if [ "${already_granted}" != "true" ]; then
                    new_bundles="$(echo "${current_bundles}" | jq -c '. + ["home_assistant"]')"
                    if curl -sf -m 10 -X PUT "${auth_args[@]}" -H "Content-Type: application/json" \
                        -d "{\"path\":\"agents.${agent}.mcp_bundles\",\"value\":${new_bundles}}" \
                        "http://127.0.0.1:8099/api/config/prop" >/dev/null 2>&1; then
                        echo "[zeroclaw-addon] Granted home_assistant MCP bundle to agent '${agent}'."
                    else
                        echo "[zeroclaw-addon] WARNING: failed to grant home_assistant MCP bundle to agent '${agent}'."
                    fi
                fi

                # Risk-profile tool permissions — additive only, every boot,
                # regardless of whether the bundle grant above just happened
                # or was already in place: fills in whichever of the two
                # lists above are still missing from the agent's risk
                # profile, but never removes or moves an entry the user (or
                # ZeroClaw's own dashboard) already set explicitly in either
                # direction. Same "seed gaps, never fight later edits"
                # policy as the provider/MCP seeding above.
                rp_prop_response="$(curl -sf -m 10 "${auth_args[@]}" "http://127.0.0.1:8099/api/config/prop?path=agents.${agent}.risk_profile" 2>/dev/null || echo '{}')"
                risk_profile="$(echo "${rp_prop_response}" | jq -r '(.value // empty) as $v | ($v | fromjson? // $v)' 2>/dev/null || true)"

                if [ -n "${risk_profile}" ]; then
                    auto_prop_response="$(curl -sf -m 10 "${auth_args[@]}" "http://127.0.0.1:8099/api/config/prop?path=risk_profiles.${risk_profile}.auto_approve" 2>/dev/null || echo '{}')"
                    current_auto="$(echo "${auto_prop_response}" | jq -c '(.value // "[]") | fromjson? // []' 2>/dev/null || echo '[]')"
                    ask_prop_response="$(curl -sf -m 10 "${auth_args[@]}" "http://127.0.0.1:8099/api/config/prop?path=risk_profiles.${risk_profile}.always_ask" 2>/dev/null || echo '{}')"
                    current_ask="$(echo "${ask_prop_response}" | jq -c '(.value // "[]") | fromjson? // []' 2>/dev/null || echo '[]')"

                    new_auto="$(jq -cn --argjson current "${current_auto}" --argjson ask "${current_ask}" \
                        --argjson add "${HA_AUTO_APPROVE_TOOLS}" --argjson add2 "${ZC_AUTO_APPROVE_TOOLS}" \
                        '($add + $add2) as $addall | $current + ($addall - $current - $ask) | unique')"
                    new_ask="$(jq -cn --argjson current "${current_ask}" --argjson approve "${current_auto}" --argjson add "${HA_ALWAYS_ASK_TOOLS}" \
                        '$current + ($add - $current - $approve) | unique')"

                    if [ "${new_auto}" != "$(echo "${current_auto}" | jq -c '.')" ]; then
                        if curl -sf -m 10 -X PUT "${auth_args[@]}" -H "Content-Type: application/json" \
                            -d "{\"path\":\"risk_profiles.${risk_profile}.auto_approve\",\"value\":${new_auto}}" \
                            "http://127.0.0.1:8099/api/config/prop" >/dev/null 2>&1; then
                            echo "[zeroclaw-addon] Auto-approved general home_assistant tools on risk profile '${risk_profile}' (agent '${agent}')."
                        else
                            echo "[zeroclaw-addon] WARNING: failed to update auto_approve on risk profile '${risk_profile}' (agent '${agent}')."
                        fi
                    fi
                    if [ "${new_ask}" != "$(echo "${current_ask}" | jq -c '.')" ]; then
                        if curl -sf -m 10 -X PUT "${auth_args[@]}" -H "Content-Type: application/json" \
                            -d "{\"path\":\"risk_profiles.${risk_profile}.always_ask\",\"value\":${new_ask}}" \
                            "http://127.0.0.1:8099/api/config/prop" >/dev/null 2>&1; then
                            echo "[zeroclaw-addon] Required confirmation for cover-opening home_assistant tools on risk profile '${risk_profile}' (agent '${agent}')."
                        else
                            echo "[zeroclaw-addon] WARNING: failed to update always_ask on risk profile '${risk_profile}' (agent '${agent}')."
                        fi
                    fi
                else
                    echo "[zeroclaw-addon] WARNING: agent '${agent}' has no risk_profile set; skipped home_assistant tool permission seeding for it."
                fi
            done <<< "${agent_list}"
        fi
    else
        echo "[zeroclaw-addon] WARNING: ZeroClaw did not become ready in time; skipped MCP bundle and tool permission reconciliation this boot."
    fi
fi

nginx -g "daemon off;" &
NGINX_PID=$!

trap 'kill -TERM "${ZEROCLAW_PID}" "${NGINX_PID}" 2>/dev/null || true' TERM INT

# `set -e` would otherwise abort the script on `wait`'s own exit code before
# the cleanup below runs, so disable it just for this one command.
set +e
wait -n "${ZEROCLAW_PID}" "${NGINX_PID}"
exit_code=$?
set -e

kill -TERM "${ZEROCLAW_PID}" "${NGINX_PID}" 2>/dev/null || true
exit "${exit_code}"
