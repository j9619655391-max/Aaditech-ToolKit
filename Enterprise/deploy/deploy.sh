#!/usr/bin/env bash
# deploy.sh - one-command IT-Toolkit Enterprise server bring-up (intranet-first).
#
# Default mode is LAN / intranet: the server advertises its LOCAL network IP
# (e.g. http://192.168.1.50) so clients on the same network can reach it —
# exactly right for office deployments. No internet access is required.
#
# What it does:
#   1. Detects this machine's LAN IP (macOS + Linux) — or pins SERVER_HOST in
#      .env to a fixed IP/FQDN.
#   2. Generates .env (secrets) if missing.
#   3. Generates Enterprise/agent/agent-config.json with the LAN endpoint +
#      token baked in — this is what flows into the .exe/.msi (auto-IP).
#   4. docker compose up -d --build
#   5. Prints next steps (agent build + MSI).
#
# Flags / env:
#   --public          advertise the public IP instead (internet clients)
#   --regen           delete .env and regenerate with a freshly detected IP
#                     (use when moving the server to a new machine/network)
#   DEPLOY_MODE=public  same as --public (env form)
#
# Idempotent: re-running only recreates changed containers; DB persists.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HERE/.env"
CONFIG_OUT="$HERE/agent/agent-config.json"

compose() { docker compose -f "$HERE/docker-compose.yml" "$@"; }

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- args / mode

MODE="lan"
REGEN=0
for arg in "$@"; do
    case "$arg" in
        --public) MODE="public" ;;
        --regen)  REGEN=1 ;;
        *) die "Unknown argument: $arg (supported: --public, --regen)" ;;
    esac
done
[ "${DEPLOY_MODE:-lan}" = "public" ] && MODE="public"

# ---------------------------------------------------------------- IP detection

detect_lan_ip() {
    # prefer physical interfaces (en0/en1/eth0/eth1) so VPNs don't win
    local ip=""
    ip="$(ifconfig 2>/dev/null | awk '/^((en[0-9])|(eth[0-9])):/ {f=1} f && /inet / && $2 !~ /^127\./ && $2 !~ /^169\.254\./ { print $2; exit }')"
    if [ -z "$ip" ]; then
        # Linux alternative (hostname -I) and any-interface fallback
        ip="$(hostname -I 2>/dev/null | awk '{ for(i=1;i<=NF;i++) if ($i !~ /^127\./) { print $i; exit } }')"
    fi
    if [ -z "$ip" ]; then
        ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ && $2 !~ /^169\.254\./ { print $2; exit }')"
    fi
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    return 1
}

detect_public_ip() {
    for src in "https://api.ipify.org" "https://ifconfig.me"; do
        local PUB
        if PUB="$(curl -fsS --max-time 5 "$src" 2>/dev/null)"; then
            if [[ "$PUB" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
                echo "$PUB"; return 0
            fi
        fi
    done
    return 1
}

detect_ip() {
    if [ "$MODE" = "public" ]; then
        detect_public_ip || detect_lan_ip || die "Cannot detect IP. Set SERVER_HOST in .env."
    else
        detect_lan_ip || die "Cannot detect LAN IP. Set SERVER_HOST in .env."
    fi
}

# ---------------------------------------------------------------- .env

generate_secret() { openssl rand -hex 24 2>/dev/null || date +%s | shasum | cut -d' ' -f1; }

if [ "$REGEN" = "1" ] && [ -f "$ENV_FILE" ]; then
    log "--regen: removing existing .env to regenerate"
    rm -f "$ENV_FILE"
fi

if [ ! -f "$ENV_FILE" ]; then
    log "Creating .env with generated secrets (mode: $MODE)"
    SERVER_IP="$(detect_ip)"
    log "Detected server IP: $SERVER_IP"
    {
        echo "POSTGRES_DB=ittoolkit"
        echo "POSTGRES_USER=ittoolkit"
        echo "POSTGRES_PASSWORD=$(generate_secret)"
        echo "API_TOKEN=$(generate_secret)"
        echo "SERVER_HOST=auto"
        echo "CADDY_HOST="
        echo "ENVIRONMENT=prod"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"  # A7: secrets must not be world-readable
    if compose volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'pgdata'; then
        die "A pgdata volume from a previous deploy already exists, but secrets were regenerated.\n   Reset it (destructive) and re-run:  docker compose -f $HERE/docker-compose.yml down -v && $0 --regen"
    fi
else
    log ".env exists — keeping it (SERVER_HOST=$([ -f "$ENV_FILE" ] && grep '^SERVER_HOST=' "$ENV_FILE" | cut -d= -f2))"
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true  # A7: harden even pre-existing .env

# Auto-regenerate placeholder/empty secrets so a manual .env.example copy can
# never ship with known credentials.
fix_placeholder() {
    local key="$1"
    local val
    val="$(grep "^$key=" "$ENV_FILE" | cut -d= -f2)"
    if [ -z "$val" ] || [ "$val" = "change-me" ] || [ "$val" = "change-me-strong" ] || [ "$val" = "change-me-random-token" ]; then
        local new
        new="$(generate_secret)"
        if [ "$(uname)" = "Darwin" ]; then
            sed -i '' "s|^$key=.*|$key=$new|" "$ENV_FILE"
        else
            sed -i "s|^$key=.*|$key=$new|" "$ENV_FILE"
        fi
        log "$key was placeholder — auto-regenerated"
        if [ "$key" = "POSTGRES_PASSWORD" ] && compose volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'pgdata'; then
            die "POSTGRES_PASSWORD changed but an old pgdata volume exists.\n   Reset it (destructive):  docker compose -f $HERE/docker-compose.yml down -v && $0"
        fi
    fi
}
fix_placeholder "API_TOKEN"
fix_placeholder "POSTGRES_PASSWORD"

# B4: default ENVIRONMENT=prod for pre-existing .env (idempotent).
if ! grep -q "^ENVIRONMENT=" "$ENV_FILE"; then
    echo "ENVIRONMENT=prod" >> "$ENV_FILE"
    log "Added ENVIRONMENT=prod to .env (edit to 'dev' to expose API docs)"
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# ---------------------------------------------------------------- agent config

# SERVER_HOST=auto → re-detect current machine's IP every run (easy migration:
# same repo, new server, just re-run deploy.sh).
if [ -n "${SERVER_HOST:-}" ] && [ "$SERVER_HOST" != "auto" ]; then
    HOST="$SERVER_HOST"
    if [[ "$HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        SCHEME="http"; CADDY_HOST=":80"
    else
        SCHEME="https"; CADDY_HOST="$HOST"
    fi
    log "Serving on $SCHEME://$HOST (pinned via SERVER_HOST)"
else
    HOST="$(detect_ip)"
    SCHEME="http"; CADDY_HOST=":80"
    log "Serving on http://$HOST  (intranet; set SERVER_HOST=<domain> in .env for TLS)"
fi

# persist resolved CADDY_HOST back into .env (idempotent)
if ! grep -q "^CADDY_HOST=" "$ENV_FILE"; then
    echo "CADDY_HOST=$CADDY_HOST" >> "$ENV_FILE"
fi

# ---------------------------------------------------------------- Caddyfile (B3)

# Render the per-mode Caddyfile from the template. Hostname/public deploys keep
# ACME auto-TLS on {$CADDY_HOST}; bare-IP deploys add an internal-CA TLS site on
# :443 (for agents/browsers that trust our CA) AND keep the plain :80 HTTP site
# so the first-time setup wizard works exactly as before the change.
#
# Also gates /docs + /openapi.json (B4): proxied only when ENVIRONMENT=dev,
# otherwise blocked at the edge (defense-in-depth on top of FastAPI's gating).
render_caddyfile() {
    local out="$HERE/deploy/Caddyfile"
    if [ "$SCHEME" = "https" ]; then
        MAIN_SITES='{$CADDY_HOST} {
    encode gzip

    import main_routes
}'
        log "Caddyfile: ACME auto-TLS on $HOST (hostname mode)"
    else
        MAIN_SITES=':443 {
    encode gzip
    tls /agent_data/certs/server.crt /agent_data/certs/server.key
    import main_routes
}

:80 {
    encode gzip
    import main_routes
}'
        log "Caddyfile: :443 (internal CA TLS) + :80 (HTTP wizard) on $HOST"
    fi
    if [ "${ENVIRONMENT:-prod}" = "dev" ]; then
        DOCS_RULE='    reverse_proxy /api-docs* api:8000
    reverse_proxy /openapi.json api:8000
    reverse_proxy /redoc api:8000
    reverse_proxy /docs api:8000'
    else
        DOCS_RULE='    @docs path /docs /redoc /openapi.json /api-docs/*
    respond @docs 404'
        log "Caddyfile: API docs blocked (ENVIRONMENT != dev)"
    fi
    # shellcheck disable=SC2016
    python3 -c '
import sys
tpl = open(sys.argv[1], encoding="utf-8").read()
out = tpl.replace("__URL_MAIN_SITES__", sys.argv[2])
out = out.replace("__DOCS_RULE__", sys.argv[3])
open(sys.argv[4], "w", encoding="utf-8").write(out)
' "$HERE/deploy/Caddyfile.template" "$MAIN_SITES" "$DOCS_RULE" "$out"
}

render_caddyfile

# Feature list comes from api/features.json (single source of truth) so the
# deploy-time agent-config.json never drifts from the portal manifest.
FEATURES_JSON="$(python3 - "$HERE/api/features.json" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    manifest = json.load(fh)["features"]
out = []
for f in manifest:
    out.append({
        "name": f["name"],
        "script": f["script"],
        "enabled": f.get("default_enabled", True),
        "requires_elevation": f.get("requires_elevation", False),
    })
print(json.dumps(out))
PY
)"

# Agent version + interval come from agent/agent-version.json (single source of
# truth, A2). Also copy it into the api build context so the running container
# can read the same values (bundle.py).
AGENT_VERSION_JSON="$HERE/agent/agent-version.json"
AGENT_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["agent_version"])' "$AGENT_VERSION_JSON")"
INTERVAL_MINUTES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["interval_minutes"])' "$AGENT_VERSION_JSON")"
cp "$AGENT_VERSION_JSON" "$HERE/api/agent-version.json"

# C5: mirror the run-script allowlist into agent-config so the agent enforces it
# itself (defense-in-depth) and refuses anything not on the list. Comma-separated
# list (same as RUN_SCRIPT_ALLOWLIST env / docker-compose) → JSON array; empty → [].
IFS=',' read -r -a _run_scripts <<< "${RUN_SCRIPT_ALLOWLIST:-}"
RUN_SCRIPT_ALLOWLIST_JSON="$(python3 -c 'import json,sys; print(json.dumps([s.strip() for s in sys.argv[1:] if s.strip()]))' "${_run_scripts[@]}" 2>/dev/null)"
[ -z "$RUN_SCRIPT_ALLOWLIST_JSON" ] && RUN_SCRIPT_ALLOWLIST_JSON="[]"

# mTLS: agents always talk to the :9443 client-auth port (TLS via internal CA).
# enroll_url goes over the MAIN port because Caddy :9443 only routes /ingest and
# /api/commands/* (a fresh agent has no client cert yet to enroll over 9443).
cat > "$CONFIG_OUT" <<EOF
{
  "endpoint": "https://$HOST:9443/ingest",
  "enroll_url": "$SCHEME://$HOST/api/agent/enroll",
  "token": "$API_TOKEN",
  "agent_version": "$AGENT_VERSION",
  "interval_minutes": $INTERVAL_MINUTES,
  "run_script_allowlist": $RUN_SCRIPT_ALLOWLIST_JSON,
  "features": $FEATURES_JSON
}
EOF
log "Agent config written: $CONFIG_OUT (endpoint baked: https://$HOST:9443/ingest)"
chmod 600 "$CONFIG_OUT" 2>/dev/null || true  # A7: contains API token

# ---------------------------------------------------------------- bring up

# A5 (Caddy cert timing): Caddy :9443 (agent mTLS) needs server.crt/ca.crt,
# but Caddy FAILS to start when those files are missing. So we cannot start
# Caddy before setup. Instead: bring up db+api, generate the certs inside the
# api container (it owns /data/certs), then start Caddy. The wizard's later
# ensure_certs() is idempotent and keeps these files (SAN matches $HOST).

log "Starting containers (db + api) and waiting for health"
export CADDY_HOST
compose up -d --build --wait --wait-timeout 120 db api

log "api healthy — generating mTLS CA + server cert for $HOST (A5)"
compose exec -T api python -c "from app.certs import ensure_certs; ensure_certs('$HOST')"

log "Starting Caddy (certs now present)"
compose up -d caddy

log "Waiting for health (main + mTLS :9443)..."
UP=0
for i in $(seq 1 30); do
    MAIN_OK=0; MTLS_OK=0
    if curl -fsS --max-time 3 "http://localhost:80/healthz" >/dev/null 2>&1; then MAIN_OK=1; fi
    if echo | openssl s_client -connect localhost:9443 -CAfile <(compose exec -T api cat /data/certs/ca.crt) 2>/dev/null | grep -q 'Verify return code: 0'; then MTLS_OK=1; fi
    if [ "$MAIN_OK" = "1" ] && [ "$MTLS_OK" = "1" ]; then UP=1; break; fi
    sleep 2
done
if [ "$UP" != "1" ]; then
    die "server never became healthy — main:${MAIN_OK:-0} mTLS:${MTLS_OK:-0} — check 'docker compose -f $HERE/docker-compose.yml logs'"
fi

printf '\n\033[1;32m✔ Enterprise server is up!\033[0m\n'
echo "  Portal:     $SCHEME://$HOST/"
echo "  API token:  $API_TOKEN  (also in .env)"
echo
echo "To make the agent downloadable from the portal (P3), upload the CI-built"
echo "generic IT-Toolkit-Agent-<version>.msi into the agent_artifacts volume:"
echo "  docker compose -f $HERE/docker-compose.yml cp <path>/IT-Toolkit-Agent-1.1.1.msi api:/artifacts/IT-Toolkit-Agent.msi"
echo
echo "Next: build the agent exe/msi on Windows (or CI):"
echo "  1) .\\Enterprise\\agent\\build\\build-agent.ps1"
echo "  2) .\\Enterprise\\agent\\wix\\build-msi.ps1"
echo "Then push IT-Toolkit-Agent-<version>.msi via Intune/GPO/SCCM (silent: msiexec /i ... /qn)."
