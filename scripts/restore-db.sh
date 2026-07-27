#!/usr/bin/env bash
# =============================================================================
# restore-db.sh — restaura um dump por cima do database brainsentry.
#   scripts/restore-db.sh ./backups/brainsentry-20260727-030000.sql.gz
#
# DESTRUTIVO: o dump é gerado com --clean --if-exists, então cada objeto do
# dump é DROPado antes de recriado. Pede confirmação explícita.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

DUMP="${1:?uso: restore-db.sh <arquivo.sql.gz>}"
[[ -f "$DUMP" ]] || { echo "FATAL: $DUMP não encontrado" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

PG_CONTAINER="${POSTGRES_ADMIN_CONTAINER:-bluevix-postgres}"
DB_NAME="${BRAINSENTRY_DB_NAME:-brainsentry}"
DB_USER="${BRAINSENTRY_DB_USER:-brainsentry}"

echo "ATENÇÃO: isto SOBRESCREVE o database '${DB_NAME}' em ${PG_CONTAINER}"
echo "         com o conteúdo de ${DUMP}."
read -r -p "Digite 'restaurar' para confirmar: " answer
[[ "$answer" == "restaurar" ]] || { echo "abortado."; exit 1; }

# Para o backend durante a restauração — conexões abertas travam os DROPs.
echo "[restore] parando o backend…"
docker stop brainsentry-backend >/dev/null 2>&1 || true

echo "[restore] aplicando o dump…"
gunzip -c "$DUMP" | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME" >/dev/null

echo "[restore] subindo o backend…"
docker start brainsentry-backend >/dev/null

echo "[restore] ok. O grafo (FalkorDB) pode estar defasado — reconstrua com:"
echo "  docker exec brainsentry-backend /app/brainsentry --rebuild graph,embeddings,communities"
