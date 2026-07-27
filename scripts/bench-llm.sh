#!/usr/bin/env bash
# =============================================================================
# bench-llm.sh — compara modelos do OpenRouter no critério que de fato quebra
# o brainsentry: devolver JSON COMPLETO dentro de ai.max_tokens.
#
# Por que existe: o backend faz json.Unmarshal direto na resposta do LLM. Um
# modelo que "pensa" antes de escrever gasta o orçamento de tokens no
# raciocínio e devolve JSON truncado — o log mostra "compression parse failed:
# unexpected end of JSON input" e cada memória custa 3 retries (~45s). O
# CLAUDE.md do projeto já registrava o sintoma; este script mede a causa.
#
# Reproduz fielmente o CompressionService: mesmo system prompt, mesma
# temperatura e o mesmo max_tokens da config.
#
# Uso:
#   scripts/bench-llm.sh                          # lista padrão de candidatos
#   scripts/bench-llm.sh modelo-a modelo-b        # só estes
#   MAX_TOKENS=1500 scripts/bench-llm.sh          # testa outro orçamento
#
# Colunas:
#   raciocinio    tokens gastos ANTES de escrever. Alto = risco de truncar.
#   json          a resposta faz parse? É o teste que importa.
#   finish        "stop" = terminou; "length" = bateu no teto (truncou).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "FATAL: $ENV_FILE ausente." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

KEY="${BRAINSENTRY_AI_AGENTIC_MODEL_API_KEY:?chave do OpenRouter obrigatória}"
MAX_TOKENS="${MAX_TOKENS:-500}"      # espelha ai.max_tokens do config
TEMPERATURE="${TEMPERATURE:-0.2}"    # espelha ai.temperature
command -v jq >/dev/null || { echo "FATAL: jq é necessário." >&2; exit 1; }

# Candidatos ordenados grosso modo do mais barato para o mais caro. O critério
# do projeto é custo por chamada — mas custo só conta entre os que passam no
# teste de JSON: um modelo barato que trunca custa 3 retries e 45s por memória,
# o que sai mais caro que o "caro" que acerta de primeira.
DEFAULT_MODELS=(
  "google/gemini-2.5-flash-lite"
  "openai/gpt-4.1-nano"
  "meta-llama/llama-3.1-8b-instruct"
  "mistralai/ministral-8b"
  "amazon/nova-lite-v1"
  "openai/gpt-oss-120b"
  "deepseek/deepseek-chat-v3.1"
  "qwen/qwen3-30b-a3b"
  "google/gemini-2.5-flash"
  "openai/gpt-4o-mini"
  "openai/gpt-4.1-mini"
  "mistralai/mistral-small-3.2-24b-instruct"
  "x-ai/grok-4-fast"
  "anthropic/claude-haiku-4-5"
)
if [[ $# -gt 0 ]]; then MODELS=("$@"); else MODELS=("${DEFAULT_MODELS[@]}"); fi

# Conversa de teste. O CompressionService manda truncate(texto, 6000), então
# testar com um diálogo curtinho não separa os modelos: com pouco contexto até
# um modelo de raciocínio termina dentro do orçamento. O que revela o problema
# é o PIOR CASO de produção — daí o bloco base ser repetido até ~5000 chars.
read -r -d '' CONV_BASE <<'EOF' || true
User: precisamos decidir onde hospedar o brainsentry.
Dev: a VPS já roda bluevix, desklenz, archflow e alcada em docker compose.
User: e o Swarm que está no repo devops?
Dev: não tem Swarm inicializado na máquina, e o Caddy do bluevix já é dono do 443.
User: então reaproveita. Postgres e Redis também?
Dev: sim, Postgres com pgvector e Redis em db separado. Falta FalkorDB, esse a gente sobe.
User: ok. Erro pendente: a chave do OpenRouter estava revogada e derrubou o chat.
Dev: já trocamos. Falta plugar o webhook de deploy no CI e agendar o backup diário.
User: e o DNS? O apex estava com proxy da Cloudflare ligado.
Dev: desliguei, senão o Caddy não emite certificado por HTTP-01 e o host responde 525.
User: a senha do admin precisa ser mais forte.
Dev: gerei 28 chars sem caractere que precise de escape no .env; rodei seed-admin --reset.
User: os embeddings estão reais agora?
Dev: sim, openai/text-embedding-3-small pelo OpenRouter, 1536 dims, casando com a migração 8.
EOF

CONVERSATION="$CONV_BASE"
turn=2
while [[ ${#CONVERSATION} -lt 5000 ]]; do
  CONVERSATION="$CONVERSATION
--- continuação $turn ---
$CONV_BASE"
  turn=$((turn + 1))
done

SYSTEM="You are a conversation compressor. Create structured summaries that preserve essential context. Respond with valid JSON only."
read -r -d '' USER_PROMPT <<EOF || true
Compress the following conversation into a structured summary. Target approximately 30% of original size.
Extract and categorize:
1. A comprehensive summary of the conversation
2. Active goals or objectives
3. Key decisions made
4. Errors or issues encountered
5. Pending tasks or TODOs

Respond in JSON format only:
{
  "summary": "comprehensive summary",
  "goals": ["goal1", "goal2"],
  "decisions": ["decision1"],
  "errors": ["error1"],
  "todos": ["todo1"]
}

Conversation:
$CONVERSATION
EOF

REPS="${REPS:-3}"   # o gasto em raciocínio varia entre chamadas; 1 amostra engana

echo "prompt: CompressionService · conversa ${#CONVERSATION} chars · max_tokens=$MAX_TOKENS · temp=$TEMPERATURE · ${REPS}x por modelo"
printf '\n%-42s %9s %11s %8s %7s %13s\n' \
  MODELO LAT_MEDIA RACIOCINIO TRUNCOU JSON CUSTO_1K_USD
printf '%.0s─' {1..96}; echo

for M in "${MODELS[@]}"; do
  body="$(jq -nc --arg m "$M" --arg s "$SYSTEM" --arg u "$USER_PROMPT" \
          --argjson mt "$MAX_TOKENS" --argjson t "$TEMPERATURE" \
          '{model:$m,temperature:$t,max_tokens:$mt,
            messages:[{role:"system",content:$s},{role:"user",content:$u}]}')"

  ok=0; lat_total=0; cost_total=0; reason_max=0; trunc=0; runs=0; err=""
  for _ in $(seq 1 "$REPS"); do
    start=$(date +%s%3N)
    http=$(curl -s -o /tmp/bench-llm.json -w '%{http_code}' \
           https://openrouter.ai/api/v1/chat/completions \
           -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
           --data-binary "$body" || echo 000)
    elapsed=$(( $(date +%s%3N) - start ))

    if [[ "$http" != "200" ]]; then
      err="HTTP$http: $(jq -r '.error.message // "erro"' /tmp/bench-llm.json 2>/dev/null | head -c 38)"
      break
    fi

    runs=$((runs + 1))
    lat_total=$((lat_total + elapsed))
    # Uma linha TSV por chamada: ok, raciocínio, truncou, custo.
    read -r r_ok r_reason r_trunc r_cost < <(jq -r '
      (.choices[0].message.content // "")        as $c |
      ($c | gsub("^```(json)?\\s*|\\s*```$";"")) as $clean |
      [ ($clean | try (fromjson|"1") catch "0"),
        ((.usage.completion_tokens_details.reasoning_tokens // 0)|tostring),
        (if .choices[0].finish_reason == "length" then "1" else "0" end),
        ((.usage.cost // 0)|tostring)
      ] | @tsv' /tmp/bench-llm.json)
    ok=$((ok + r_ok))
    trunc=$((trunc + r_trunc))
    [[ "$r_reason" -gt "$reason_max" ]] && reason_max="$r_reason"
    cost_total=$(awk -v a="$cost_total" -v b="$r_cost" 'BEGIN{printf "%.10f", a+b}')
  done

  if [[ -n "$err" ]]; then
    printf '%-42s %9s %11s %8s %7s %13s\n' "$M" "-" "-" "-" "-" "$err"
    continue
  fi

  # Custo por 1000 chamadas: a escala em que a diferença entre modelos importa.
  printf '%-42s %9s %11s %8s %7s %13s\n' "$M" \
    "$((lat_total / runs))ms" "$reason_max" "$trunc/$runs" "$ok/$runs" \
    "$(awk -v c="$cost_total" -v n="$runs" 'BEGIN{printf "%.2f", c/n*1000}')"
done

echo
echo "JSON precisa ser $REPS/$REPS. Qualquer FALHA vira 3 retries e ~45s por memória"
echo "no backend — o modelo barato que trunca sai mais caro que o caro que acerta."
echo "RACIOCINIO é o pico observado: perto de $MAX_TOKENS significa que sobra pouco"
echo "orçamento para o JSON, e a próxima conversa mais longa trunca."
