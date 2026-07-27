# Runbook — brainsentry na VPS

Host: `31.97.240.217` · Projeto: `/opt/brainsentry-devops` · Compose project: `brainsentry`

## Mapa rápido

| Container | Dono | Papel |
| --- | --- | --- |
| `brainsentry-frontend` | nós | SPA + nginx (proxy `/api` → backend) |
| `brainsentry-backend` | nós | API Go `:8081` |
| `brainsentry-falkordb` | nós | grafo (derivado — reconstruível) |
| `brainsentry-webhook` | nós | receiver de CD |
| `bluevix-postgres` | **bluevix** | canônico: db/role `brainsentry` |
| `bluevix-redis` | **bluevix** | cache/rate-limit/scheduler, **db 3** |
| `bluevix-caddy` | **bluevix** | TLS + roteamento |

> Os três últimos são **compartilhados com outros apps da VPS**. Nunca
> reinicie/derrube esses containers para resolver problema do brainsentry —
> derruba bluevix, desklenz, archflow e alcada junto.

## Sintomas → causa provável

| Sintoma | Causa | Ação |
| --- | --- | --- |
| `502` em `app.` | backend não healthy | `docker logs brainsentry-backend --tail 50` |
| `525/526` | proxy Cloudflare ligado | desligar (ver [dns.md](dns.md)) |
| Backend em restart loop, log `production requires a real security.jwt_secret` | `JWT_SECRET` vazio/curto | corrigir `.env`, `deploy.sh` |
| Backend sobe, mas escrita dá 500 (`relation … does not exist`) | migração pendente | `./scripts/migrate.sh` |
| Login sempre 401 | usuário não existe (não há registro público) | `./scripts/seed-admin.sh --reset` |
| `/v1/graph/*` vazio ou 503 | FalkorDB fora | `docker logs brainsentry-falkordb`; grafo é derivado, dá para reconstruir |
| Busca semântica sem sentido | fallback de embedding por hash | conhecido — ver README, seção *Qualidade da busca semântica* |
| Rate-limit/cache errado após deploy do bluevix | colisão de chaves no Redis | conferir `redis.db: 3` em `config/config.production.yaml` |

## Diagnóstico

```bash
./scripts/health-check.sh

docker logs brainsentry-backend --tail 100 -f
docker exec brainsentry-backend curl -s localhost:8081/api/health
docker exec brainsentry-backend curl -s localhost:8081/api/v1/diagnostics
docker exec brainsentry-backend curl -s localhost:8081/api/version

# Postgres da aplicação
docker exec -it bluevix-postgres psql -U brainsentry -d brainsentry -c '\dt'

# FalkorDB (a senha vem do REDISCLI_AUTH do próprio container)
docker exec -it brainsentry-falkordb redis-cli GRAPH.QUERY brainsentry "MATCH (n) RETURN count(n)"
```

## Reconstruir dados derivados

O Postgres é o sistema de registro; grafo, embeddings e comunidades são
cache e se reconstroem:

```bash
docker exec brainsentry-backend /app/brainsentry --rebuild graph,embeddings,communities
```

## Rotina de recuperação

1. `./scripts/health-check.sh` — identifica a camada quebrada.
2. Se for só o backend: `docker compose --env-file .env restart brainsentry-backend`.
3. Se for schema: `./scripts/migrate.sh` (idempotente).
4. Se for dado corrompido: `./scripts/restore-db.sh ./backups/<dump>` e depois
   o `--rebuild` acima.
5. Se for roteamento: `./scripts/caddy-sync.sh` (faz backup datado do
   Caddyfile compartilhado antes de tocar nele).

## Cuidados ao mexer no Caddyfile compartilhado

`/opt/bluevix/caddy/Caddyfile` é de todos os apps. Só edite o brainsentry
por `caddy/brainsentry.caddy` + `./scripts/caddy-sync.sh`: o script isola o
bloco pelos marcadores, faz backup datado e **valida antes de recarregar**.
Editar à mão é o caminho mais rápido para derrubar os quatro apps vizinhos.
