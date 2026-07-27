# Receiver de deploy (adnanh/webhook). Recebe POST do GitHub Actions e dispara
# os scripts de deploy no host via docker.sock. Roda como projeto compose
# isolado (docker-compose.webhook.yml, name: brainsentry-webhook) para
# sobreviver a `up --remove-orphans` da stack principal.
FROM alpine:3.20

RUN apk add --no-cache \
      docker-cli \
      docker-cli-compose \
      webhook \
      bash \
      flock \
      curl \
      coreutils

COPY hooks.yaml /etc/webhook/hooks.yaml

EXPOSE 9000
ENTRYPOINT ["webhook", "-hooks", "/etc/webhook/hooks.yaml", \
            "-template", "-verbose", "-port", "9000", "-urlprefix", "hooks"]
