#!/usr/bin/env bash
# backup.sh - dump the IT-Toolkit Enterprise DB to Enterprise/deploy/backups/.
#
# The dump is a custom-format (binary, pg_restore-ready) dated file that lives
# on the HOST filesystem (not in a container volume), so it survives
# `docker compose down -v`.
#
#   ./backup.sh                 # dump now (files kept forever / manage yourself)
#   BACKUP_KEEP=7 ./backup.sh   # keep the 7 newest, prune the rest
#
# Scheduling: crontab -e on Linux, launchd on macOS, Task Scheduler on Windows.
#   0 2 * * *  /path/to/Enterprise/deploy/backup.sh >> /var/log/ittk-backup.log

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HERE/.env"
BACKUP_DIR="$HERE/deploy/backups"
BACKUP_KEEP="${BACKUP_KEEP:-0}"

compose() { docker compose -f "$HERE/docker-compose.yml" "$@"; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
DB_USER="${POSTGRES_USER:-ittoolkit}"
DB_NAME="${POSTGRES_DB:-ittoolkit}"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="$BACKUP_DIR/ittoolkit-$STAMP.dump"

log() { printf '[backup] %s\n' "$*"; }

log "Dumping $DB_NAME to $FILE"
compose up -d db
compose exec -T db sh -lc \
    "until pg_isready -U '$DB_USER' -d '$DB_NAME' >/dev/null 2>&1; do sleep 1; done"
compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom > "$FILE"
chmod 600 "$FILE"
log "Wrote $FILE ($(du -h "$FILE" | cut -f1))"

if [ "$BACKUP_KEEP" -gt 0 ]; then
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR"/ittoolkit-*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
        rm -f "$old"
        log "Pruned $old"
    done
fi
log "Done"