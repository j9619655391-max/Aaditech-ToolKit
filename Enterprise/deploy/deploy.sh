#!/usr/bin/env bash
# deploy.sh - one-command IT-Toolkit Enterprise server bring-up.
#
# What it does:
#   1. Detects this machine's IP (public if reachable, else LAN) — or uses
#      SERVER_HOST from .env to pin a domain/FQDN.
#   2. Generates .env (secrets) if missing.
#   3. Generates Enterprise/agent/agent-config.json with the endpoint + token
#      baked in — this is what flows into the .exe/.msi (auto-IP requirement).
#   4. docker compose up -d --build
#   5. Prints next steps (agent build + MSI).
#
# Idempotent: re-running only recreates changed containers; DB persists.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HERE/.env"
CONFIG_OUT="$HERE/agent/agent-config.json"

compose() { docker compose -f "$HERE/docker-compose.yml" "$@"; }

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- IP detection

detect_ip() {
    # prefer public IP when the host is reachable; fall back to LAN
    for src in "https://api.ipify.org" "https://ifconfig.me"; do
        if PUB="$(curl -fsS --max-time 5 "$src" 2>/dev/null)"; then
            if [[ "$PUB" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
                echo "$PUB"; return
            fi
        fi
    done
    # LAN IP
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
        || ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 \
        || die "Cannot auto-detect IP. Set SERVER_HOST=<your-ip-or-domain> in .env"
}

# ---------------------------------------------------------------- .env

generate_secret() { openssl rand -hex 24 2>/dev/null || date +%s | shasum | cut -d' ' -f1; }

if [ ! -f "$ENV_FILE" ]; then
    log "Creating .env with generated secrets"
    SERVER_IP="$(detect_ip)"
    log "Detected server IP: $SERVER_IP"
    {
        echo "POSTGRES_DB=ittoolkit"
        echo "POSTGRES_USER=ittoolkit"
        echo "POSTGRES_PASSWORD=$(generate_secret)"
        echo "API_TOKEN=$(generate_secret)"
        echo "SERVER_HOST=$SERVER_IP"
        echo "CADDY_HOST="
    } > "$ENV_FILE"
    if compose volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'pgdata'; then
        die "A pgdata volume from a previous deploy already exists, but secrets were regenerated.\n   Reset it (destructive) and re-run:  docker compose -f $HERE/docker-compose.yml down -v && $0"
    fi
else
    log ".env exists — keeping it (remove it to regenerate with a new IP)"
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# ---------------------------------------------------------------- agent config

if [ -n "${SERVER_HOST:-}" ] && [ "$SERVER_HOST" != "auto" ]; then
    HOST="$SERVER_HOST"
    # domain → let Caddy do real HTTPS; bare IP → plain HTTP
    if [[ "$HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        SCHEME="http"
        CADDY_HOST=":80"
    else
        SCHEME="https"
        CADDY_HOST="$HOST"
    fi
    log "Serving on $SCHEME://$HOST"
else
    IP="$(detect_ip)"
    SCHEME="http"; HOST="$IP"; CADDY_HOST=":80"
    log "Auto-detected IP: $HOST (over http; set SERVER_HOST to a domain for TLS)"
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
echo "Next: build the agent exe/msi on Windows (or CI):"
echo "  1) .\\Enterprise\\agent\\build\\build-agent.ps1"
echo "  2) .\\Enterprise\\agent\\wix\\build-msi.ps1"
echo "Then push IT-Toolkit-Agent.msi via Intune/GPO/SCCM (silent: msiexec /i ... /qn)."
