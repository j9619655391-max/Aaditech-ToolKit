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
    } > "$ENV_FILE"
    if compose volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'pgdata'; then
        die "A pgdata volume from a previous deploy already exists, but secrets were regenerated.\n   Reset it (destructive) and re-run:  docker compose -f $HERE/docker-compose.yml down -v && $0 --regen"
    fi
else
    log ".env exists — keeping it (SERVER_HOST=$([ -f "$ENV_FILE" ] && grep '^SERVER_HOST=' "$ENV_FILE" | cut -d= -f2))"
fi

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

cat > "$CONFIG_OUT" <<EOF
{
  "endpoint": "$SCHEME://$HOST/ingest",
  "token": "$API_TOKEN",
  "agent_version": "1.0.0",
  "interval_minutes": 30,
  "features": [
    { "name": "quickcheck", "script": "Scripts/QuickCheck.ps1", "enabled": true },
    { "name": "eventlogs",  "script": "Scripts/Export-EventLogs.ps1", "enabled": true },
    { "name": "network",    "script": "Scripts/Network-Diagnostic.ps1", "enabled": true },
    { "name": "firewall",   "script": "Scripts/Firewall-Test.ps1", "enabled": true },
    { "name": "users",      "script": "Scripts/User-Inventory.ps1", "enabled": false },
    { "name": "printers",   "script": "Scripts/Printer-Fix.ps1", "enabled": false }
  ]
}
EOF
log "Agent config written: $CONFIG_OUT (endpoint baked: $SCHEME://$HOST/ingest)"

# ---------------------------------------------------------------- bring up

log "Starting containers (db + api + caddy)"
export CADDY_HOST
compose up -d --build

log "Waiting for health..."
for i in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://localhost:80/healthz" >/dev/null 2>&1 || curl -fsS --max-time 3 "http://localhost:8000/healthz" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

printf '\n\033[1;32m✔ Enterprise server is up!\033[0m\n'
echo "  Portal:     $SCHEME://$HOST/"
echo "  API token:  $API_TOKEN  (also in .env)"
echo
echo "To make the agent downloadable from the portal (P3), upload the CI-built"
echo "generic IT-Toolkit-Agent.msi into the agent_artifacts volume:"
echo "  docker compose -f $HERE/docker-compose.yml cp <path>/IT-Toolkit-Agent.msi api:/artifacts/"
echo
echo "Next: build the agent exe/msi on Windows (or CI):"
echo "  1) .\\Enterprise\\agent\\build\\build-agent.ps1"
echo "  2) .\\Enterprise\\agent\\wix\\build-msi.ps1"
echo "Then push IT-Toolkit-Agent.msi via Intune/GPO/SCCM (silent: msiexec /i ... /qn)."
