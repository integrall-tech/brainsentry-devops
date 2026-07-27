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
| `/v1/graph/*` vazio | grafo nunca reconstruído (o backend não escreve nele em runtime) | `./scripts/rebuild-graph.sh` — e agende o cron |
| `/v1/graph/*` 503 | FalkorDB fora | `docker logs brainsentry-falkordb` |
| `vector search failed, falling back to access-based` | assinatura de `db.idx.vector.queryNodes` mudou nesta versão do FalkorDB | não é fatal (cai para busca por acesso); ver README |
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

## Reconstruir dados derivados — precisa de cron

O Postgres é o sistema de registro; grafo, embeddings e comunidades são cache.
Só que o backend **nunca escreve no FalkorDB durante a operação normal**:
`SaveToGraph` é chamado apenas pelo rebuild (`internal/rebuild/targets.go`).
Criar memória grava no Postgres e o grafo só enxerga no próximo rebuild.

Consequências práticas:

- Deploy novo → `/v1/graph/ego`, GraphRAG e comunidades respondem **vazio**
  até o primeiro rebuild (o `deploy.sh` já roda um).
- Sem cron, o grafo é um retrato congelado no último rebuild.

```bash
./scripts/rebuild-graph.sh              # graph,embeddings,communities
./scripts/rebuild-graph.sh --dry-run    # mostra sem executar
```

Cron diário (na VPS), logo depois do backup:

```bash
30 3 * * * cd /opt/brainsentry-devops && ./scripts/rebuild-graph.sh >> /var/log/bs-rebuild.log 2>&1
```

> O binário faz **dry-run por padrão** e sai com 0 — rodar
> `/app/brainsentry --rebuild ...` na mão sem `--confirm-destructive` parece
> ter funcionado e não fez nada. O script cuida disso.

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
