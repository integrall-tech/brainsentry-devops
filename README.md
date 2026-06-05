# brainsentry-devops

Deploy infrastructure for **brainsentry** on the Integrall DevOps swarm.
Hybrid topology: brings its own Postgres (pgvector required) and reuses
Redis + FalkorDB from `dev-env-devops`.

## Topology

```
┌─────────────── DevOps swarm (dev-env-devops) ────────────────────┐
│                                                                  │
│   ┌─ redis ─────┐    ┌─ falkordb ──┐    ┌─ litellm (opt) ──┐    │
│   │ shared      │    │ shared      │    │ shared           │    │
│   └─────────────┘    └─────────────┘    └──────────────────┘    │
│         ▲                  ▲                                     │
│         │                  │      [overlay network: devops_devops]│
│  ┌──────┴──────────────────┴──────────────────────────────────┐  │
│  │                       brainsentry stack                     │  │
│  │  ┌─ brainsentry-postgres ─┐  ┌─ brainsentry-backend ─┐     │  │
│  │  │ pgvector/pgvector:pg18 │  │ ghcr.io/integrall-tech│     │  │
│  │  │ DEDICATED to this app  │◀─│  /brainsentry-backend │     │  │
│  │  │ port 5445 (host)       │  │ port 8081 (host)      │     │  │
│  │  └────────────────────────┘  └────────┬──────────────┘     │  │
│  │                                       │                     │  │
│  │  ┌─ brainsentry-frontend ──────────┐  │                     │  │
│  │  │ ghcr.io/integrall-tech/         │  │ nginx /api/* proxy  │  │
│  │  │   brainsentry-frontend          │──┘                     │  │
│  │  │ port 8086 (host)                │                        │  │
│  │  └─────────────────────────────────┘                        │  │
│  └─────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

| Service               | Image                                              | Port | Owns                          |
| --------------------- | -------------------------------------------------- | ---- | ----------------------------- |
| brainsentry-postgres  | `pgvector/pgvector:pg18`                           | 5445 | DB + brainsentry_postgres_data volume |
| brainsentry-backend   | `ghcr.io/integrall-tech/brainsentry-backend:latest`| 8081 | API (Go)                      |
| brainsentry-frontend  | `ghcr.io/integrall-tech/brainsentry-frontend:latest`| 8086 | SPA (React + nginx)           |

External dependencies (live in `dev-env-devops`):

- `redis` — cache, rate-limit, scheduler
- `falkordb` — graph features (`/v1/graph/*`)
- `devops_devops` overlay network — how this stack reaches the above
- `devops_redis_password` + `devops_falkordb_password` swarm secrets

## Prerequisites

1. `dev-env-devops` deployed and healthy. The overlay network and the
   `redis_password` / `falkordb_password` swarm secrets must exist.
2. Docker Swarm initialized on the manager node.
3. `psql` is NOT required on the host — `scripts/migrate.sh` runs all
   `psql` invocations inside the postgres container.
4. (Optional) the `brainsentry.io` source repo cloned next to this one
   if you want to run `scripts/smoke-test.sh`.

## First-time install

```bash
# 1. Configure
cp .env.example .env        # then edit (image tags, AI model, etc)

# 2. Generate secrets we own (postgres pw, JWT, LLM key)
./scripts/setup-secrets.sh   # prompts for the LLM key

# 3. Deploy the stack (pulls images, attaches to overlay)
./scripts/deploy.sh

# 4. Apply the 9 migrations (creates the schema, installs pgvector)
./scripts/migrate.sh

# 5. Verify
./scripts/health-check.sh
```

If everything went well:

```bash
curl http://localhost:8081/api/version
# {"version":"0.1.0","commit":"<sha>","buildTime":"..."}

open http://localhost:8086/    # the SPA
```

## Day 2 operations

> **Upgrading to a new version?** Follow [docs/RELEASE.md](docs/RELEASE.md).
> There's an ordering gotcha (update backend → migrate → update frontend,
> because `migrate.sh` reads the migrations from inside the backend image)
> — the guide explains why and gives a step-by-step + checklist.

```bash
# Update to a newer image tag (edit .env then redeploy)
./scripts/deploy.sh

# Apply a new migration after a backend release
./scripts/migrate.sh

# Full integration smoke (uses brain-sentry-explorer from the source repo)
./scripts/smoke-test.sh

# Backup the DB
./scripts/backup-db.sh             # → ./backups/brainsentry-YYYYMMDD-HHMMSS.sql.gz

# Cron the daily backup (manager node)
echo "0 3 * * * cd $(pwd) && ./scripts/backup-db.sh >> /var/log/bs-backup.log 2>&1" \
  | crontab -

# Restore from a backup (DESTRUCTIVE)
./scripts/restore-db.sh ./backups/brainsentry-20260601-030000.sql.gz

# Tear down (keeps data volume)
./scripts/undeploy.sh

# Tear down + delete data (clean reinstall)
./scripts/undeploy.sh --purge-volumes
```

## Environment knobs

See `.env.example` for the full list. The most-used:

| Variable                     | Default                          | Meaning                              |
| ---------------------------- | -------------------------------- | ------------------------------------ |
| `STACK_NAME`                 | `brainsentry`                    | Swarm stack name (prefix for services + secrets) |
| `BACKEND_IMAGE_TAG`          | `latest`                         | Pin to `v0.1.0` in production for reproducibility |
| `FRONTEND_IMAGE_TAG`         | `latest`                         | Same as above                        |
| `BRAINSENTRY_BACKEND_PORT`   | `8081`                           | Host port for the API                |
| `BRAINSENTRY_FRONTEND_PORT`  | `8086`                           | Host port for the SPA                |
| `BRAINSENTRY_POSTGRES_PORT`  | `5445`                           | Host port for direct DB access       |
| `BRAINSENTRY_AI_MODEL`       | `anthropic/claude-haiku-4-5`     | OpenRouter (or LiteLLM) model id     |
| `BRAINSENTRY_CORS_ORIGINS`   | localhost + integrall.tech       | Comma-separated allowed origins      |
| `GHCR_USERNAME`/`GHCR_TOKEN` | (empty)                          | Only needed if brainsentry packages are private |

## LiteLLM as LLM provider (alternative to OpenRouter direct)

Override two env vars on `brainsentry-backend` and ship the LiteLLM
master key in the LLM secret:

```yaml
- AI_BASE_URL=http://litellm:4000/v1
- AI_MODEL=<the model name configured in dev-env-devops's litellm/config.yaml>
```

Then in `secrets/brainsentry_llm_api_key.txt`, put the LiteLLM master key
instead of the OpenRouter PAT.

## Repository layout

```
brainsentry-devops/
├── README.md                    (this file)
├── .env.example                 (env vars; copy to .env to customize)
├── docker-compose.swarm.yml     (the 3 services + secrets + network)
├── scripts/
│   ├── setup-secrets.sh         (generate the 3 owned secrets)
│   ├── deploy.sh                (validate prereqs + stack deploy + converge wait)
│   ├── undeploy.sh              (stack rm; --purge-volumes for clean wipe)
│   ├── migrate.sh               (CREATE EXTENSION + 9 migrations via psql-in-container)
│   ├── health-check.sh          (curl /api/health + /api/version + frontend)
│   ├── smoke-test.sh            (run brain-sentry-explorer validate against live)
│   ├── backup-db.sh             (pg_dump + gzip; auto-rotates by mtime)
│   └── restore-db.sh            (gunzip + psql; destructive — drops DB first)
├── secrets/                     (gitignored; setup-secrets.sh fills it)
├── config/                      (placeholders for future overrides)
└── docs/                        (deeper ops/troubleshooting docs)
```

## Troubleshooting

- **`network devops_devops not found`** — `dev-env-devops` isn't
  deployed. Deploy it first: `cd ../dev-env-devops && scripts/deploy.sh`.
- **`secret devops_redis_password not found`** — same as above.
- **Backend log: `relation "decisions" does not exist`** — migration 8
  hasn't run. `./scripts/migrate.sh`.
- **Backend log: `compression parse failed`** — the configured LLM is
  returning malformed JSON. Switch `BRAINSENTRY_AI_MODEL` to
  `anthropic/claude-haiku-4-5` or `google/gemini-2.5-flash` (these
  produce reliable JSON; `deepseek/*` and others tend not to).
- **Frontend `/api/...` 502** — backend isn't healthy yet. Watch
  `docker service logs brainsentry_brainsentry-backend`.
- **`docker stack deploy` says "image cannot be accessed"** — the
  brainsentry GHCR packages are private; either make them public on
  github.com/orgs/integrall-tech/packages or set `GHCR_USERNAME` +
  `GHCR_TOKEN` in `.env` so `scripts/deploy.sh` logs in first AND uses
  `--with-registry-auth` to propagate the credential to workers.
