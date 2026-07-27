#!/usr/bin/env bash
# =============================================================================
# deploy-component.sh — atualiza UM componente para uma tag específica.
#   deploy-component.sh <backend|frontend|all> <tag>
#
# A tag é gravada de volta no .env (fonte de verdade do compose), então o
# próximo `deploy.sh` sem argumentos reaplica exatamente o que está no ar.
#
# Ordem no "all": backend → migrate → frontend. É deliberada — os .up.sql
# moram na imagem do backend, então o schema só pode avançar depois que a
# imagem nova está rodando (ver docs/RELEASE.md).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
COMPONENT="${1:?uso: deploy-component.sh <backend|frontend|all> <tag>}"
TAG="${2:?uso: deploy-component.sh <backend|frontend|all> <tag>}"

[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: tag inválida '$TAG'" >&2; exit 2; }

dc() { docker compose --env-file "$ENV_FILE" "$@"; }

set_tag() { # set_tag KEY value
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i.bak "s|^$1=.*|$1=$2|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

update_backend() {
  echo "[deploy-component] backend → $TAG"
  set_tag BACKEND_IMAGE_TAG "$TAG"
  dc -f docker-compose.yml pull brainsentry-backend
  dc -f docker-compose.yml up -d brainsentry-backend
  # Espera ficar healthy antes de migrar — migrate.sh lê /app/migrations dele.
  for _ in $(seq 1 45); do
    [[ "$(docker inspect --format '{{.State.Health.Status}}' brainsentry-backend 2>/dev/null)" == "healthy" ]] && break
    sleep 2
  done
  "$SCRIPT_DIR/migrate.sh"
}

update_frontend() {
  echo "[deploy-component] frontend → $TAG"
  set_tag FRONTEND_IMAGE_TAG "$TAG"
  dc -f docker-compose.yml pull brainsentry-frontend
  dc -f docker-compose.yml up -d brainsentry-frontend
}

case "$COMPONENT" in
  backend)  update_backend ;;
  frontend) update_frontend ;;
  all)      update_backend; update_frontend ;;
  *) echo "FATAL: componente inválido '$COMPONENT' (backend|frontend|all)" >&2; exit 2 ;;
esac

docker image prune -f >/dev/null 2>&1 || true
"$SCRIPT_DIR/health-check.sh"
