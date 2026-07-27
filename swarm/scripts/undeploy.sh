#!/usr/bin/env bash
# Tear down the brainsentry stack. By default keeps volumes (data is
# preserved). Pass --purge-volumes to also remove the brainsentry
# postgres data volume (destructive — only for clean re-installs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# shellcheck disable=SC1091
[ -f .env ] && source .env
STACK_NAME="${STACK_NAME:-brainsentry}"

PURGE=0
for arg in "$@"; do
    [ "$arg" = "--purge-volumes" ] && PURGE=1
done

echo "[1/2] removing stack '${STACK_NAME}'..."
docker stack rm "$STACK_NAME"

echo "[2/2] waiting for cleanup..."
for _ in $(seq 1 30); do
    remaining=$(docker service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" -q | wc -l | tr -d ' ')
    [ "$remaining" = "0" ] && break
    sleep 1
done

if [ "$PURGE" = "1" ]; then
    echo
    echo "[!] --purge-volumes — also removing brainsentry_postgres_data."
    echo "    THIS DELETES THE BRAINSENTRY DATABASE. Ctrl-C in 5s to abort."
    sleep 5
    docker volume rm "${STACK_NAME}_brainsentry_postgres_data" 2>&1 || echo "  (volume already gone)"
fi

echo
echo "Done. Re-deploy with: scripts/deploy.sh"
