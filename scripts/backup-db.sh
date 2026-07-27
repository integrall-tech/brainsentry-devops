#!/usr/bin/env bash
# =============================================================================
# backup-db.sh — pg_dump do database brainsentry (no Postgres compartilhado)
# comprimido em ./backups/. Rotaciona por idade (BACKUP_RETENTION_DAYS, 14).
#
# Cron diário (na VPS):
#   0 3 * * * cd /opt/brainsentry-devops && ./scripts/backup-db.sh >> /var/log/bs-backup.log 2>&1
#
# NOTA: o FalkorDB não entra aqui — o grafo é derivado do Postgres e se
# reconstrói (`brainsentry --rebuild graph`). O canônico é o Postgres.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
DB_USER="${BRAINSENTRY_DB_USER:-brainsentry}"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"
OUT_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/brainsentry-${STAMP}.sql.gz"

echo "[backup] pg_dump ${DB_NAME} → ${OUT}"
docker exec "$PG_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --no-owner --clean --if-exists \
  | gzip -9 > "$OUT"

size="$(du -h "$OUT" | cut -f1)"
echo "[backup] ok (${size})"

echo "[backup] removendo dumps com mais de ${RETENTION} dias"
find "$OUT_DIR" -name 'brainsentry-*.sql.gz' -type f -mtime "+${RETENTION}" -print -delete
