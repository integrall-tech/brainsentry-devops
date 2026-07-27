#!/usr/bin/env bash
# Deploy or update the brainsentry swarm stack. Assumes:
#  - dev-env-devops is already deployed (provides the 'devops' overlay
#    network and the redis_password + falkordb_password swarm secrets)
#  - scripts/setup-secrets.sh has been run at least once
#  - .env exists (copy from .env.example and edit)
#
# Run from the swarm manager node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if [ ! -f ".env" ]; then
    echo "[fail] .env not found — copy .env.example and edit" >&2
    exit 1
fi

# Auto-export every var from .env so `docker stack deploy` (which reads
# from process env, not the .env file directly like `docker compose`
# does) sees BACKEND_IMAGE_TAG / GHCR_* / etc. Without `set -a` the
# vars are shell-local and the compose file's ${VAR:-default} falls
# back to the defaults silently — we hit this in production where
# `:latest` got pulled instead of the pinned `:0.1.0`.
# shellcheck disable=SC1091
set -a
source .env
set +a
STACK_NAME="${STACK_NAME:-brainsentry}"

# Sanity: external resources must exist before stack deploy can attach.
echo "[1/5] checking external resources from dev-env-devops..."
if ! docker network inspect devops_devops >/dev/null 2>&1; then
    echo "[fail] external network 'devops_devops' not found" >&2
    echo "       Deploy dev-env-devops first: cd ../dev-env-devops && scripts/deploy.sh" >&2
    exit 1
fi
for s in devops_redis_password devops_falkordb_password; do
    if ! docker secret inspect "$s" >/dev/null 2>&1; then
        echo "[fail] external secret '$s' not found" >&2
        echo "       Deploy dev-env-devops first." >&2
        exit 1
    fi
done

# Sanity: our local secrets must be on disk for swarm to read them.
echo "[2/5] checking brainsentry secrets on disk..."
for s in brainsentry_postgres_password brainsentry_jwt_secret brainsentry_llm_api_key; do
    if [ ! -s "secrets/${s}.txt" ]; then
        echo "[fail] secrets/${s}.txt missing — run scripts/setup-secrets.sh first" >&2
        exit 1
    fi
done

# Optional: GHCR login if packages are private.
if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_USERNAME:-}" ]; then
    echo "[3/5] logging in to ghcr.io..."
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

echo "[4/5] deploying stack '${STACK_NAME}'..."
docker stack deploy \
    --compose-file docker-compose.swarm.yml \
    --with-registry-auth \
    "$STACK_NAME"

echo "[5/5] waiting for services to converge..."
for svc in brainsentry-postgres brainsentry-backend brainsentry-frontend; do
    full="${STACK_NAME}_${svc}"
    for _ in $(seq 1 60); do
        replicas=$(docker service ls --filter "name=${full}" --format "{{.Replicas}}" 2>/dev/null || echo "")
        if [ "$replicas" = "1/1" ]; then
            echo "  [ok]   ${full}"
            break
        fi
        sleep 2
    done
    if [ "$replicas" != "1/1" ]; then
        echo "  [warn] ${full} not converged after 120s; check with: docker service ps ${full}" >&2
    fi
done

echo
echo "Done. Verify with: scripts/health-check.sh"
