#!/usr/bin/env bash
# =============================================================================
# caddy-sync.sh — instala/atualiza o bloco de roteamento do brainsentry no
# Caddyfile compartilhado da VPS (bluevix-caddy) e recarrega o Caddy.
#
# O bloco é delimitado por "# >>> brainsentry >>>" e "# <<< brainsentry <<<".
# O script REMOVE qualquer bloco antigo entre os marcadores e ANEXA o
# renderizado a partir de caddy/brainsentry.caddy (com ${ROOT_DOMAIN}
# substituído). Idempotente. Valida antes de recarregar.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${ROOT_DOMAIN:?ROOT_DOMAIN obrigatório}"

CADDY_CONTAINER="${CADDY_CONTAINER:-bluevix-caddy}"
CADDYFILE_HOST="${CADDYFILE_HOST:-/opt/bluevix/caddy/Caddyfile}"
SNIPPET_SRC="$PROJECT_DIR/caddy/brainsentry.caddy"
MARK_BEGIN="# >>> brainsentry >>>"
MARK_END="# <<< brainsentry <<<"

[[ -f "$SNIPPET_SRC" ]]    || { echo "FATAL: $SNIPPET_SRC ausente." >&2; exit 1; }
[[ -f "$CADDYFILE_HOST" ]] || { echo "FATAL: Caddyfile $CADDYFILE_HOST não encontrado." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CADDY_CONTAINER" \
  || { echo "FATAL: container $CADDY_CONTAINER não está rodando." >&2; exit 1; }

echo "[caddy-sync] renderizando bloco (ROOT_DOMAIN=$ROOT_DOMAIN)"
RENDERED="$(ROOT_DOMAIN="$ROOT_DOMAIN" envsubst '$ROOT_DOMAIN' < "$SNIPPET_SRC")"

BACKUP="${CADDYFILE_HOST}.brainsentry.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$CADDYFILE_HOST" "$BACKUP"
echo "[caddy-sync] backup → $BACKUP"

# Remove o bloco antigo. Os marcadores casam por PREFIXO (index==1) porque a
# linha pode ter texto extra depois ("# >>> brainsentry >>> (bloco…)").
TMP="$(mktemp)"
awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
  index($0,b)==1          {inblk=1; next}
  inblk && index($0,e)==1 {inblk=0; next}
  !inblk {print}
' "$CADDYFILE_HOST" > "$TMP"

printf '\n%s\n' "$RENDERED" >> "$TMP"

echo "[caddy-sync] validando…"
if docker exec -i "$CADDY_CONTAINER" caddy validate --adapter caddyfile --config - < "$TMP" >/dev/null 2>&1; then
  cp "$TMP" "$CADDYFILE_HOST"
  rm -f "$TMP"
else
  echo "FATAL: Caddyfile resultante inválido — nada aplicado. Arquivo em $TMP" >&2
  exit 1
fi

echo "[caddy-sync] recarregando Caddy…"
docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile

echo "[caddy-sync] ok — hosts: app.$ROOT_DOMAIN, api.$ROOT_DOMAIN, $ROOT_DOMAIN (redir), deploy.$ROOT_DOMAIN"
