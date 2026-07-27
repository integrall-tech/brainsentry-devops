#!/usr/bin/env bash
# =============================================================================
# run-deploy.sh — ponto de entrada chamado pelo receiver de webhook.
#   run-deploy.sh <env> <component> <tag>
# Sanitiza a entrada (vem da rede), serializa com flock (latest-wins) e
# despacha o deploy em background para o webhook responder rápido.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_ARG="${1:-}"
COMPONENT="${2:-}"
TAG="${3:-}"

log() { printf '[run-deploy] %s\n' "$*"; }

# --- Validação estrita ------------------------------------------------------
case "$ENV_ARG" in
  production) ;;
  *) log "env inválido: '$ENV_ARG' (esperado: production)"; exit 2 ;;
esac
case "$COMPONENT" in
  backend|frontend|all) ;;
  *) log "component inválido: '$COMPONENT'"; exit 2 ;;
esac
if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log "tag inválida: '$TAG'"; exit 2
fi

# --- Coalescing latest-wins -------------------------------------------------
LOCK="/tmp/brainsentry-deploy.lock"
PENDING="/tmp/brainsentry-deploy.pending"
printf '%s %s\n' "$COMPONENT" "$TAG" > "$PENDING"

(
  exec 9>"$LOCK"
  flock -w 900 9 || { log "timeout aguardando lock"; exit 1; }
  read -r c t < "$PENDING"
  log "aplicando $c → $t"
  "$SCRIPT_DIR/deploy-component.sh" "$c" "$t"
) >>/tmp/brainsentry-deploy.log 2>&1 &

log "deploy despachado ($COMPONENT $TAG)"
