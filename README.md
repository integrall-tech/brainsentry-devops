# brainsentry-devops

Deploy do **brainsentry** em produção.

Dois alvos, dois arquivos:

| Alvo | Arquivo | Quando usar |
| --- | --- | --- |
| **VPS 31.97.240.217** (docker compose) | `docker-compose.yml` | **É este.** Produção em `brainsentry.com.br`. |
| Swarm Integrall (`dev-env-devops`) | `swarm/docker-compose.swarm.yml` | Cluster antigo; mantido para referência — ver [swarm/](swarm/). |

O resto deste README é sobre o alvo VPS.

## Topologia

A VPS não usa Swarm: cada app é um projeto compose e existe **um Caddy
compartilhado** (`bluevix-caddy`) que termina TLS e roteia por hostname. O
brainsentry segue essa convenção e **reaproveita** o que já está no ar,
subindo só o que ninguém mais provê.

```
                    Internet :443
                          │
              ┌───────────▼────────────┐
              │  bluevix-caddy (TLS)   │   /opt/bluevix/caddy/Caddyfile
              └───┬───────────┬────────┘   ← bloco gerenciado por caddy-sync.sh
   app.brainsentry│           │api.brainsentry.com.br
      .com.br     │           │
      ┌───────────▼──┐     ┌──▼──────────────────┐
      │ brainsentry- │     │ brainsentry-backend │  Go, :8081
      │  frontend    │────▶│  (nginx /api proxy) │
      │  nginx :80   │     └──┬───────┬──────┬───┘
      └──────────────┘        │       │      │
                              │       │      └──▶ brainsentry-falkordb  ← NOSSO
                              │       │           (rede privada bsnet)
                              │       └─────────▶ bluevix-redis  (db 3)  ← reusado
                              └─────────────────▶ bluevix-postgres       ← reusado
                                                  db/role "brainsentry"
```

| Recurso | De onde vem | Observação |
| --- | --- | --- |
| TLS + roteamento | `bluevix-caddy` (existente) | bloco em `caddy/brainsentry.caddy` |
| Postgres + pgvector | `bluevix-postgres` (existente) | role/database dedicados `brainsentry` |
| Redis | `bluevix-redis` (existente) | **db 3** — o bluevix usa o db 0 |
| FalkorDB | **container desta stack** | nada na VPS provia grafo |
| Backend / Frontend | `ghcr.io/integrall-tech/brainsentry-*` | imagens públicas, buildadas pelo CI do repo da app |

### Hostnames

| Host | Destino |
| --- | --- |
| `app.brainsentry.com.br` | SPA (o nginx interno faz proxy de `/api/*` → backend) |
| `api.brainsentry.com.br` | backend direto — agentes MCP, CLI, TUI |
| `brainsentry.com.br`, `www.` | redirect 301 → `app.` |
| `deploy.brainsentry.com.br` | receiver de CD (exige header `X-Deploy-Token`) |

## Instalação do zero

Tudo roda **na VPS**, em `/opt/brainsentry-devops`:

```bash
# 1. Configuração + segredos (idempotente: não sobrescreve o que já existe)
./scripts/setup.sh
$EDITOR .env          # preencha BRAINSENTRY_AI_AGENTIC_MODEL_API_KEY

# 2. DNS na Cloudflare (A records → 31.97.240.217, proxy DESLIGADO)
./scripts/dns-sync.sh --dry-run
./scripts/dns-sync.sh

# 3. Deploy: db + stack + migrações + admin + Caddy (+ CD)
./scripts/deploy.sh --webhook

# 4. Verificação
./scripts/health-check.sh
```

O `deploy.sh` é idempotente — é o mesmo comando para instalar e para
atualizar.

> **Por que o proxy da Cloudflare fica desligado:** o Caddy emite o
> certificado por HTTP-01, que exige que a porta 80 do domínio chegue até a
> VPS. Com o proxy laranja ligado, a Cloudflare termina o TLS antes e o
> desafio nunca chega — o host passa a responder 525/526.

## Operação do dia a dia

```bash
./scripts/health-check.sh                     # containers + API + HTTPS
./scripts/deploy-component.sh backend sha-abc1234   # sobe uma tag específica
./scripts/deploy-component.sh all v0.2.0
./scripts/migrate.sh                          # migrações após um release
./scripts/seed-admin.sh --reset               # redefine a senha do admin
./scripts/backup-db.sh                        # → ./backups/*.sql.gz
./scripts/restore-db.sh ./backups/<arquivo>   # DESTRUTIVO
./scripts/caddy-sync.sh                       # só o roteamento
./scripts/undeploy.sh                         # para tudo (dados preservados)
./scripts/undeploy.sh --purge-graph --purge-db  # wipe completo
```

Backup diário (na VPS):

```bash
echo "0 3 * * * cd /opt/brainsentry-devops && ./scripts/backup-db.sh >> /var/log/bs-backup.log 2>&1" | crontab -
```

> **Upgrade de versão:** há uma ordem obrigatória (backend → migrate →
> frontend), porque os `.up.sql` viajam **dentro da imagem do backend**.
> `deploy-component.sh` já faz isso; o porquê está em
> [docs/RELEASE.md](docs/RELEASE.md).

## CD (deploy automático)

O receiver (`brainsentry-webhook`) escuta em `deploy.brainsentry.com.br` e
dispara `scripts/deploy-component.sh`. Do CI, depois que a imagem subiu:

```bash
curl -fsS https://deploy.brainsentry.com.br/hooks/deploy \
  -H "X-Deploy-Token: $DEPLOY_TOKEN" -H 'Content-Type: application/json' \
  -d '{"component":"backend","tag":"sha-abc1234"}'
```

`component` ∈ `backend | frontend | all`. Token inválido → 403. Chamadas
concorrentes são serializadas com `flock` e coalescem no último `tag`
(latest-wins). Log em `/tmp/brainsentry-deploy.log`.

## Configuração

Credenciais e hosts ficam no `.env` (ver `.env.example`); o que **não tem
variável de ambiente equivalente** fica em `config/config.production.yaml`,
montado em `/app/config.yaml`. Env sempre vence sobre o arquivo
(`internal/config/applyEnvOverrides`).

Dois valores que só existem no arquivo e importam:

- **`redis.db: 3`** — o Redis é compartilhado com o bluevix (db 0). Sem isso
  as chaves colidem.
- **`embedding.dimensions: 1536`** — a migração 8 cria `vector(1536)`; com os
  384 do dev, todo INSERT em `decisions`/`events` falharia.

### Qualidade da busca semântica (conhecido)

`ai.base_url` aponta para o OpenRouter, que **não tem endpoint
`/embeddings`**. O `EmbeddingService` tenta, falha e cai no fallback por hash
— determinístico, mas sem semântica (busca vetorial vira quase ruído) e com
um round-trip desperdiçado por chamada. Para embeddings reais é preciso uma
chave OpenAI com `ai.base_url=https://api.openai.com/v1`; note que o mesmo
par chave/base_url também serve o LLM de chat, então nesse caso configure o
LLM pelas chaves nativas (`ANTHROPIC_API_KEY` / `GEMINI_API_KEY`), que entram
na frente da chain.

## Layout

```
brainsentry-devops/
├── docker-compose.yml            falkordb + backend + frontend
├── docker-compose.webhook.yml    receiver de CD (projeto compose isolado)
├── .env.example
├── caddy/brainsentry.caddy       bloco do Caddy compartilhado
├── config/config.production.yaml montado em /app/config.yaml
├── webhook/                      Dockerfile + hooks.yaml
├── scripts/                      setup, ensure-db, deploy, migrate, …
├── docs/                         RELEASE, runbook, dns
└── swarm/                        alvo antigo (Swarm Integrall)
```

## Troubleshooting

- **`https://app.…` responde 525/526** — proxy da Cloudflare ligado. Desligue
  (`./scripts/dns-sync.sh` já grava `proxied=false`).
- **Caddy não emite certificado** — DNS ainda não propagou, ou a porta 80 não
  chega. `dig +short app.brainsentry.com.br` e
  `docker logs bluevix-caddy --tail 50`.
- **`/api/...` 502 no SPA** — backend não está healthy:
  `docker logs brainsentry-backend --tail 50`.
- **Backend recusa subir com "production requires a real security.jwt_secret"**
  — `JWT_SECRET` vazio/curto no `.env` (mínimo 32 chars). É fail-closed de
  propósito.
- **`relation "decisions" does not exist`** — faltou `./scripts/migrate.sh`.
- **`extensão pgvector ausente`** — rode `./scripts/ensure-db.sh` (o
  `CREATE EXTENSION` exige superusuário, por isso não está nas migrações).
- **`compression parse failed` no log** — o LLM configurado devolve JSON
  malformado. Use `anthropic/claude-haiku-4-5` ou `google/gemini-2.5-flash`.
- **Grafo vazio depois de um restore** — o FalkorDB é derivado:
  `docker exec brainsentry-backend /app/brainsentry --rebuild graph,embeddings,communities`.
