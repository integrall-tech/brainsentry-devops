#!/usr/bin/env bash
# Restore a brainsentry-postgres dump produced by backup-db.sh. Wipes
# the current `brainsentry` database before applying — DESTRUCTIVE.
# Usage: scripts/restore-db.sh ./backups/brainsentry-YYYYMMDD-HHMMSS.sql.gz

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
STACK_NAME="${STACK_NAME:-brainsentry}"
PG_SERVICE="${STACK_NAME}_brainsentry-postgres"

DUMP_FILE="${1:-}"
if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo "usage: $0 <dump.sql.gz>" >&2
    exit 1
fi

PG_CONTAINER=$(docker ps --filter "name=${PG_SERVICE}" --format "{{.ID}}" | head -1)
if [ -z "$PG_CONTAINER" ]; then
    echo "[fail] no running container for ${PG_SERVICE}" >&2
    exit 1
fi

echo "[!] About to DROP and recreate database 'brainsentry' inside ${PG_CONTAINER}"
echo "    and restore from: ${DUMP_FILE}"
echo "    Ctrl-C in 5s to abort."
sleep 5

# Reset DB.
docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U brainsentry -d postgres <<'EOF'
DROP DATABASE IF EXISTS brainsentry;
CREATE DATABASE brainsentry;
EOF

# Restore.
gunzip -c "$DUMP_FILE" \
  | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U brainsentry -d brainsentry >/dev/null

echo "[ok] restore complete. Restart the backend to drop stale connections:"
echo "  docker service update --force ${STACK_NAME}_brainsentry-backend"
