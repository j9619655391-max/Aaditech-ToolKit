#!/usr/bin/env bash
# restore.sh - restore the IT-Toolkit Enterprise DB from a backup.sh dump.
#
# Usage:
#   ./restore.sh                                # latest dump in deploy/backups/
#   ./restore.sh path/to/ittoolkit-<date>.dump  # explicit file
#
# Steps:
#   1. stop caddy + api (no writers)
#   2. ensure db is up
#   3. docker cp the dump into the db container and pg_restore --clean
#   4. start api + caddy again
#
# NOTE: replaces current DB contents with the dump.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HERE/.env"
BACKUP_DIR="$HERE/deploy/backups"

compose() { docker compose -f "$HERE/docker-compose.yml" "$@"; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
DB_USER="${POSTGRES_USER:-ittoolkit}"
DB_NAME="${POSTGRES_DB:-ittoolkit}"

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [dump-file]" >&2
    exit 1
fi

if [ "$#" -eq 1 ]; then
    FILE="$1"
    [ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }
else
    FILE="$(ls -1t "$BACKUP_DIR"/ittoolkit-*.dump 2>/dev/null | head -1 || true)"
    [ -n "$FILE" ] || { echo "no backup found in $BACKUP_DIR (run ./backup.sh first)" >&2; exit 1; }
fi

log() { printf '[restore] %s\n' "$*"; }

log "Restoring from: $FILE"
log "Stopping caddy + api (no writers during restore) — ok if already down"
compose stop caddy api || true

log "Ensuring db is up + healthy (schema.sql init runs on fresh volume)"
compose up -d db
compose exec -T db sh -lc \
    "until pg_isready -U '$DB_USER' -d '$DB_NAME' >/dev/null 2>&1; do sleep 1; done"

CID="$(compose ps -q db)"
docker cp "$FILE" "$CID:/tmp/itk-restore.dump"

log "pg_restore --clean --if-exists"
compose exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
    --no-owner --no-privileges /tmp/itk-restore.dump
compose exec -T db rm -f /tmp/itk-restore.dump

log "Regenerating mTLS CA + server cert (down -v wiped /data/certs)"
compose up -d api
HOST="$(grep '^SERVER_HOST=' "$ENV_FILE" | cut -d= -f2)"
if [ -z "$HOST" ] || [ "$HOST" = "auto" ]; then
    HOST="$(ifconfig 2>/dev/null | awk '/^((en[0-9])|(eth[0-9])):/ {f=1} f && /inet / && $2 !~ /^127\./ && $2 !~ /^169\.254\./ { print $2; exit }')"
fi
compose exec -T api python -c "from app.certs import ensure_certs; ensure_certs('$HOST')"
log "Certs regenerated for SAN=$HOST"

log "Bringing api + caddy back up"
compose up -d api caddy

log "Restore complete."