# Alvo antigo: Swarm Integrall (`dev-env-devops`)

Este diretório guarda a stack **Docker Swarm** original, escrita para o
cluster onde `dev-env-devops` provê Redis, FalkorDB, a overlay
`devops_devops` e os secrets `devops_redis_password` /
`devops_falkordb_password`.

**Não é o que roda em produção hoje.** A VPS 31.97.240.217 não tem Swarm
inicializado e usa docker compose com um Caddy compartilhado — ver o
[README da raiz](../README.md).

Diferenças que importam se você for reaproveitar isto:

| | Swarm (aqui) | VPS (raiz) |
| --- | --- | --- |
| Postgres | container dedicado da stack | `bluevix-postgres` compartilhado |
| Redis / FalkorDB | do `dev-env-devops` | Redis compartilhado (db 3) + FalkorDB próprio |
| Segredos | swarm secrets em `secrets/*.txt` | `.env` (600) |
| Exposição | portas 8081/8086 no host | Caddy compartilhado com TLS |
| Deploy | `docker stack deploy` | `docker compose up -d` |

Uso (num manager de Swarm, com `dev-env-devops` no ar):

```bash
cp ../.env.example ../.env      # ajuste as portas/tags
./scripts/setup-secrets.sh
./scripts/deploy.sh
./scripts/migrate.sh
./scripts/health-check.sh
```

Os scripts aqui referenciam `docker-compose.swarm.yml` por caminho
relativo ao diretório do projeto — rode-os a partir de `swarm/`.
