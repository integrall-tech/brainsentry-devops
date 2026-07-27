# DNS — brainsentry.com.br

Zona na **Cloudflare** (`aldo.ns.cloudflare.com` / `rihana.ns.cloudflare.com`).

## Registros

Todos apontam para a VPS, **A**, TTL 300, **proxy desligado** (nuvem cinza):

| Nome | Tipo | Conteúdo | Serve |
| --- | --- | --- | --- |
| `brainsentry.com.br` | A | `31.97.240.217` | redirect → `app.` |
| `www` | A | `31.97.240.217` | redirect → `app.` |
| `app` | A | `31.97.240.217` | SPA |
| `api` | A | `31.97.240.217` | backend (agentes MCP, CLI, TUI) |
| `deploy` | A | `31.97.240.217` | receiver de CD |

Aplicar/reconciliar:

```bash
./scripts/dns-sync.sh --dry-run
./scripts/dns-sync.sh
```

## Por que o proxy fica desligado

O Caddy emite os certificados por **HTTP-01**: a Let's Encrypt precisa
alcançar `http://<host>/.well-known/acme-challenge/...` **na VPS**. Com o
proxy laranja ligado, a Cloudflare termina o TLS/HTTP antes e o desafio
nunca chega — o Caddy fica em retry e o host responde 525/526.

Se um dia o proxy for desejado (WAF/CDN), troque a emissão para **DNS-01**
com o plugin `caddy-dns/cloudflare` no build do Caddy compartilhado, e só
então ligue a nuvem laranja. Não ligue antes.

## Verificação

```bash
dig +short app.brainsentry.com.br      # → 31.97.240.217
curl -sI https://app.brainsentry.com.br | head -1
docker logs bluevix-caddy --tail 30    # emissão/renovação de certificado
```

A primeira emissão leva alguns segundos depois que o DNS propaga. Enquanto
não propagar, `health-check.sh` marca os checks HTTPS como aviso (`!`), não
como falha.
