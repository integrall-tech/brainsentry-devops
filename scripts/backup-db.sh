#!/usr/bin/env bash
# pg_dump the brainsentry-postgres into a timestamped file under ./backups.
# Designed to be cron-friendly — outputs only on failure or with -v.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
STACK_NAME="${STACK_NAME:-brainsentry}"
PG_SERVICE="${STACK_NAME}_brainsentry-postgres"

BACKUP_DIR="${PROJECT_DIR}/backups"
mkdir -p "$BACKUP_DIR"

PG_CONTAINER=$(docker ps --filter "name=${PG_SERVICE}" --format "{{.ID}}" | head -1)
if [ -z "$PG_CONTAINER" ]; then
    echo "[fail] no running container for ${PG_SERVICE}" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUTFILE="${BACKUP_DIR}/brainsentry-${STAMP}.sql.gz"

# pg_dump inside the container, stream out via stdout, gzip on host.
# --no-owner --no-acl makes the dump portable to a fresh DB.
docker exec "$PG_CONTAINER" pg_dump \
    --no-owner --no-acl \
    -U brainsentry -d brainsentry \
  | gzip -c > "$OUTFILE"

SIZE=$(du -h "$OUTFILE" | cut -f1)
echo "[ok] backup -> ${OUTFILE} (${SIZE})"

# Retention: keep the last 14 daily dumps; drop older. Adjust to taste.
RETAIN_DAYS=${BACKUP_RETAIN_DAYS:-14}
find "$BACKUP_DIR" -name "brainsentry-*.sql.gz" -type f -mtime "+${RETAIN_DAYS}" -delete -print \
  | sed 's/^/[gc] /'
