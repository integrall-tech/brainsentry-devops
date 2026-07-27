#!/usr/bin/env bash
# =============================================================================
# watch-ghcr.sh — CD por PULL: a VPS consulta o GHCR e se atualiza sozinha.
#
# POR QUE PULL E NÃO WEBHOOK. O desenho anterior tinha o runner do GitHub
# chamando deploy.brainsentry.com.br. Essa direção não é confiável aqui:
#
#   runner do GitHub → VPS   : timeout no connect, 5 tentativas em 2 minutos
#   minha máquina    → VPS   : HTTP 200 em 0,098s no mesmo instante
#   VPS → GitHub/GHCR        : HTTP 200 em 0,03s
#
# O SYN não chega na máquina (fail2ban sem banidos, INPUT ACCEPT, nada nos
# logs do Caddy), então o bloqueio é upstream — provavelmente proteção do
# provedor contra faixas de datacenter, e runners do GitHub são Azure. Isso
# também explica o caso em que um job passou e o irmão falhou no mesmo minuto:
# depende do IP que o runner sorteia.
#
# Retry não resolve um bloqueio de rota. Inverter a direção resolve, e ainda
# elimina o webhook, o DEPLOY_TOKEN e um endpoint público destrutivo.
#
# Uso:
#   scripts/watch-ghcr.sh              # verifica e atualiza o que mudou
#   scripts/watch-ghcr.sh --dry-run    # só diz o que faria
#
# Cron (a cada 3 min):
#   */3 * * * * cd /opt/brainsentry-devops && ./scripts/watch-ghcr.sh >> /var/log/bs-watch.log 2>&1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# A tag observada. `main` move a cada merge; o deploy em si é feito pela tag
# imutável sha-<short>, derivada do label de revisão da própria imagem — assim
# o .env continua registrando exatamente qual commit está no ar.
WATCH_TAG="${WATCH_TAG:-main}"
REGISTRY="${REGISTRY:-ghcr.io/integrall-tech}"

log() { printf '[watch-ghcr] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Serializa: um deploy pode passar de 3 minutos e o cron não pode empilhar.
LOCK=/tmp/brainsentry-watch.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "outra execução em andamento — saindo"
  exit 0
fi

changed=0

check_component() {
  local component="$1" container="$2" image="$REGISTRY/brainsentry-$1"

  if ! docker pull -q "$image:$WATCH_TAG" >/dev/null 2>&1; then
    # Falha de rede/registro não é motivo para alarme: a próxima passada
    # tenta de novo. Só registra.
    log "aviso: não consegui consultar $image:$WATCH_TAG"
    return 0
  fi

  local remote_id running_id
  remote_id="$(docker image inspect "$image:$WATCH_TAG" --format '{{.Id}}' 2>/dev/null || echo "")"
  running_id="$(docker inspect "$container" --format '{{.Image}}' 2>/dev/null || echo "")"

  if [[ -z "$remote_id" ]]; then
    log "aviso: não consegui ler a imagem remota de $component"
    return 0
  fi
  if [[ "$remote_id" == "$running_id" ]]; then
    return 0   # em dia; silêncio de propósito, senão o cron vira ruído
  fi

  # A tag sha-<short> é derivada do label que o CI injeta (docker/metadata-action
  # grava org.opencontainers.image.revision). Preferida a :main porque é
  # imutável: o .env passa a apontar para um commit específico, não para um
  # ponteiro que se move.
  local revision short tag
  revision="$(docker image inspect "$image:$WATCH_TAG" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || echo "")"
  if [[ "$revision" =~ ^[0-9a-f]{7,40}$ ]]; then
    short="${revision:0:7}"
    tag="sha-$short"
  else
    # Sem label utilizável, cai para a própria tag observada. Perde a
    # rastreabilidade do commit, mas não deixa de atualizar.
    log "aviso: $component sem label de revisão utilizável; usando :$WATCH_TAG"
    tag="$WATCH_TAG"
  fi

  changed=1
  if [[ "$DRY" == "1" ]]; then
    log "[dry-run] $component atualizaria para $tag"
    return 0
  fi

  log "$component: imagem nova detectada → $tag"
  if "$SCRIPT_DIR/deploy-component.sh" "$component" "$tag"; then
    log "$component: deploy concluído em $tag"
  else
    # Falha de deploy PRECISA aparecer: em cron, silêncio passa por sucesso.
    log "ERRO: deploy de $component para $tag falhou"
    return 1
  fi
}

rc=0
# Ordem deliberada: backend primeiro (ele carrega as migrações), frontend
# depois — a mesma ordem que docs/RELEASE.md exige.
check_component backend brainsentry-backend || rc=1
check_component frontend brainsentry-frontend || rc=1

[[ "$changed" == "0" ]] && log "nada a fazer (imagens em dia)"
exit "$rc"
