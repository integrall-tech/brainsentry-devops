#!/usr/bin/env bash
# Apply the 9 brainsentry migrations to the dedicated Postgres. Runs
# psql inside the brainsentry-postgres container so no host psql or
# network exposure of the DB is required.
#
# Pass a directory containing the migration .up.sql files as $1, OR
# leave empty to use the canonical path inside the running container
# (/migrations — present in ghcr.io/integrall-tech/brainsentry-backend
# images).
#
# Idempotent: ADD COLUMN IF NOT EXISTS / CREATE EXTENSION IF NOT EXISTS
# semantics in the migrations themselves make repeated runs safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
STACK_NAME="${STACK_NAME:-brainsentry}"
PG_SERVICE="${STACK_NAME}_brainsentry-postgres"

MIGRATIONS_SRC="${1:-}"

# Find the postgres container running our service.
PG_CONTAINER=$(docker ps --filter "name=${PG_SERVICE}" --format "{{.ID}}" | head -1)
if [ -z "$PG_CONTAINER" ]; then
    echo "[fail] no running container for ${PG_SERVICE}" >&2
    echo "       deploy first with: scripts/deploy.sh" >&2
    exit 1
fi
echo "[info] postgres container: ${PG_CONTAINER}"

# Wait until the DB is ready (deploy.sh already does this but we may
# be invoked separately).
for _ in $(seq 1 30); do
    if docker exec "$PG_CONTAINER" pg_isready -U brainsentry -d brainsentry >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

run_sql() {
    local label="$1"; local sql="$2"
    echo "[migrate] ${label}"
    echo "$sql" | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U brainsentry -d brainsentry >/dev/null
}

apply_file() {
    local file="$1"
    echo "[migrate] applying $(basename "$file")"
    if [ -n "$MIGRATIONS_SRC" ]; then
        # Migrations from a host directory — pipe through stdin.
        docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U brainsentry -d brainsentry < "$file" >/dev/null
    else
        # Migrations from inside the backend image at /migrations —
        # use the backend container's filesystem via psql -f.
        local backend_container
        backend_container=$(docker ps --filter "name=${STACK_NAME}_brainsentry-backend" --format "{{.ID}}" | head -1)
        if [ -z "$backend_container" ]; then
            echo "[fail] no running backend container to read /migrations from" >&2
            echo "       pass an explicit migrations directory: $0 /path/to/migrations" >&2
            exit 1
        fi
        docker exec "$backend_container" cat "$file" | \
            docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U brainsentry -d brainsentry >/dev/null
    fi
}

# 1. The vector extension — needed by migration 8 (vector(1536) col).
run_sql "CREATE EXTENSION IF NOT EXISTS vector" \
        "CREATE EXTENSION IF NOT EXISTS vector;"

# 2. The 9 migrations in order.
if [ -n "$MIGRATIONS_SRC" ]; then
    if [ ! -d "$MIGRATIONS_SRC" ]; then
        echo "[fail] $MIGRATIONS_SRC is not a directory" >&2
        exit 1
    fi
    for f in $(ls "$MIGRATIONS_SRC"/0*.up.sql 2>/dev/null | sort); do
        apply_file "$f"
    done
else
    backend_container=$(docker ps --filter "name=${STACK_NAME}_brainsentry-backend" --format "{{.ID}}" | head -1)
    files=$(docker exec "$backend_container" sh -c 'ls /app/migrations/0*.up.sql' 2>/dev/null | sort)
    if [ -z "$files" ]; then
        echo "[fail] no migrations found in backend /app/migrations" >&2
        exit 1
    fi
    for f in $files; do
        apply_file "$f"
    done
fi

echo
echo "[ok] migrations applied. Verify with:"
echo "     docker exec -it ${PG_CONTAINER} psql -U brainsentry -d brainsentry -c '\\dt'"
