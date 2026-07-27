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

O CD não expõe host nenhum: é por pull (ver abaixo).

## Instalação do zero

Tudo roda **na VPS**, em `/opt/brainsentry-devops`:

```bash
# 1. Configuração + segredos (idempotente: não sobrescreve o que já existe)
./scripts/setup.sh
$EDITOR .env          # preencha BRAINSENTRY_AI_AGENTIC_MODEL_API_KEY

# 2. DNS na Cloudflare (A records → 31.97.240.217, proxy DESLIGADO)
./scripts/dns-sync.sh --dry-run
./scripts/dns-sync.sh

# 3. Deploy: db + stack + migrações + admin + grafo + Caddy
./scripts/deploy.sh

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

Os três cron da VPS (`crontab -l`):

```cron
0  3 * * * cd /opt/brainsentry-devops && ./scripts/backup-db.sh    >> /var/log/bs-backup.log 2>&1
30 3 * * * cd /opt/brainsentry-devops && ./scripts/rebuild-graph.sh >> /var/log/bs-rebuild.log 2>&1
*/3 * * * * cd /opt/brainsentry-devops && ./scripts/watch-ghcr.sh   >> /var/log/bs-watch.log 2>&1
```

O do meio não é opcional: o backend nunca escreve no FalkorDB em runtime, então
sem ele `/v1/graph/*` congela no último rebuild.

> **Upgrade de versão:** há uma ordem obrigatória (backend → migrate →
> frontend), porque os `.up.sql` viajam **dentro da imagem do backend**.
> `deploy-component.sh` já faz isso; o porquê está em
> [docs/RELEASE.md](docs/RELEASE.md).

## CD (deploy automático) — por pull

A VPS consulta o GHCR e se atualiza sozinha. Nada é exposto para isso: não há
webhook, token de deploy nem host `deploy.*`.

```bash
./scripts/watch-ghcr.sh --dry-run   # diz o que faria
./scripts/watch-ghcr.sh             # atualiza o que mudou
```

Cron (a cada 3 minutos):

```bash
*/3 * * * * cd /opt/brainsentry-devops && ./scripts/watch-ghcr.sh >> /var/log/bs-watch.log 2>&1
```

Compara o ID da imagem `:main` no GHCR com o que o container roda; quando
diverge, deriva a tag imutável `sha-<short>` do label
`org.opencontainers.image.revision` e chama o `deploy-component.sh`. Assim o
`.env` registra o commit exato, não um ponteiro que se move. Backend antes do
frontend, como o `docs/RELEASE.md` exige.

> **Por que pull e não webhook.** O desenho anterior tinha o runner do GitHub
> chamando `deploy.brainsentry.com.br`, e essa direção não é confiável aqui:
> 5 tentativas de connect em 2 minutos deram timeout enquanto a mesma URL
> respondia em 0,098s de outra origem — e a VPS alcança o GHCR em 0,03s. O SYN
> não chega na máquina (fail2ban sem banidos, `INPUT ACCEPT`, nada nos logs do
> Caddy), então o bloqueio é upstream, provavelmente proteção do provedor
> contra faixas de datacenter — e runners do GitHub são Azure. Retry não
> resolve rota bloqueada; inverter a direção resolve.

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

### Embeddings

Chat e embedding compartilham o mesmo par chave/base_url: o
`EmbeddingService` é construído com `cfg.AI.APIKey` + `cfg.AI.BaseURL` e o
`cfg.Embedding.Model` (`cmd/server/main.go`). Não há como apontá-los para
fornecedores diferentes sem mudar o código.

Isso não é problema porque o OpenRouter serve `/api/v1/embeddings` além de
`/chat/completions`, espelhando o schema da OpenAI — então o mesmo
`ai.api_key` cobre os dois. O que precisa casar:

- `embedding.model: openai/text-embedding-3-small` — id no formato do
  OpenRouter (`vendor/modelo`), não o nome curto da OpenAI.
- `embedding.dimensions: 1536` — é a dimensão desse modelo **e** a largura
  das colunas `vector(1536)` criadas pela migração 8.

Se a chave estiver inválida ou o modelo não existir, o `EmbeddingService`
não quebra: loga `embedding API call failed, using hash fallback` e devolve
um vetor por hash — determinístico, mas sem semântica. Ou seja, **busca
vetorial ruim é sintoma de chave/modelo errados**, não de bug: procure esse
WARN no log antes de investigar qualquer outra coisa.

## Layout

```
brainsentry-devops/
├── docker-compose.yml            falkordb + backend + frontend
├── .env.example
├── caddy/brainsentry.caddy       bloco do Caddy compartilhado
├── config/config.production.yaml montado em /app/config.yaml
├── scripts/                      setup, ensure-db, deploy, migrate, watch-ghcr, …
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
- **`compression parse failed: unexpected end of JSON input`** — o modelo é de
  raciocínio e gastou o `ai.max_tokens` pensando antes de escrever o JSON, que
  chega truncado. Sintomas colaterais: `POST /v1/memories` levando 20-45s (são
  3 retries) e 502 no Caddy. Meça antes de escolher o substituto:
  `./scripts/bench-llm.sh <modelo>` — a coluna `RACIOCINIO` é o diagnóstico.
- **Grafo vazio depois de um restore** — o FalkorDB é derivado:
  `docker exec brainsentry-backend /app/brainsentry --rebuild graph,embeddings,communities`.
