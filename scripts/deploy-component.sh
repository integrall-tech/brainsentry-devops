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
  # --no-deps: sem isto o compose reavalia as dependências e recria o que
  # estiver fora de sincronia. Um deploy só do frontend chegou a recriar o
  # backend a partir da imagem `latest` já em cache — ou seja, um componente
  # arrastava o outro para uma versão que ninguém pediu.
  dc -f docker-compose.yml up -d --no-deps brainsentry-backend
  # Espera ficar healthy antes de migrar — migrate.sh lê /app/migrations dele.
  wait_healthy brainsentry-backend
  "$SCRIPT_DIR/migrate.sh"
}

update_frontend() {
  echo "[deploy-component] frontend → $TAG"
  set_tag FRONTEND_IMAGE_TAG "$TAG"
  dc -f docker-compose.yml pull brainsentry-frontend
  # --no-deps pelo mesmo motivo do backend: isolar o componente pedido.
  dc -f docker-compose.yml up -d --no-deps brainsentry-frontend
  # Esperar aqui também: sem isto o health-check do fim roda com o container
  # ainda em "starting" e reporta FALHOU num deploy que deu certo — foi o que
  # apareceu no log do primeiro CD automático.
  wait_healthy brainsentry-frontend
}

# wait_healthy bloqueia até o container ficar healthy (ou ~90s). Não falha por
# conta própria: quem decide é o health-check no fim, com diagnóstico melhor.
wait_healthy() {
  local name="$1" status=""
  for _ in $(seq 1 45); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  echo "[deploy-component] aviso: $name não ficou healthy (último estado: $status)" >&2
  return 0
}

case "$COMPONENT" in
  backend)  update_backend ;;
  frontend) update_frontend ;;
  all)      update_backend; update_frontend ;;
  *) echo "FATAL: componente inválido '$COMPONENT' (backend|frontend|all)" >&2; exit 2 ;;
esac

docker image prune -f >/dev/null 2>&1 || true
"$SCRIPT_DIR/health-check.sh"
