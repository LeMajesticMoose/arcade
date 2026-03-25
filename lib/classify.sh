#!/usr/bin/env bash
# lib/classify.sh — Chunk classification via configured local model or heuristics
# Sourced by masterarcade.sh
# Output: REASONING or SCAFFOLD

LUMINA_URL="${LUMINA_URL:-${ANTHROPIC_BASE_URL:-http://localhost:4000}}"
LUMINA_MODEL="${LUMINA_MODEL:-agent-lite}"

# Keyword sets for heuristic fallback
SCAFFOLD_KEYWORDS="create file generate boilerplate scaffold install dependency build format convert copy rename mkdir touch init template stub skeleton"
REASONING_KEYWORDS="design architecture debug review analyse analyze test plan decision refactor complex logic algorithm evaluate investigate"

# classify_chunk <chunk_text>
# Prints REASONING or SCAFFOLD to stdout
classify_chunk() {
  local chunk="$1"
  [ -n "$chunk" ] || { echo "REASONING"; return; }

  # Try configured local model first (if LITELLM_MASTER_KEY or OPENROUTER_API_KEY set)
  if _classify_via_lumina "$chunk"; then
    return
  fi

  # Fallback: keyword heuristics
  _classify_heuristic "$chunk"
}

_classify_via_lumina() {
  local chunk="$1"
  [ -n "${LITELLM_MASTER_KEY:-}${OPENROUTER_API_KEY:-}" ] || return 1

  local auth_header
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    auth_header="Bearer $LITELLM_MASTER_KEY"
  else
    auth_header="Bearer $OPENROUTER_API_KEY"
  fi

  local prompt
  prompt="Classify the following development task as either REASONING or SCAFFOLD. Reply with exactly one word: REASONING or SCAFFOLD.

REASONING = design decisions, architecture, debugging, code review, writing tests, analysis, complex logic
SCAFFOLD = file creation, boilerplate generation, refactoring known patterns, dependency installation, running builds, format conversion

Task: ${chunk}"

  # Escape for JSON
  local escaped_prompt
  escaped_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null) || return 1

  local response
  response=$(curl -sf --max-time 15 \
    -X POST "${LUMINA_URL}/v1/chat/completions" \
    -H "Authorization: ${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${LUMINA_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}],
      \"max_tokens\": 10,
      \"temperature\": 0
    }" 2>/dev/null) || return 1

  local result
  result=$(echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
content = d.get('choices',[{}])[0].get('message',{}).get('content','').strip().upper()
if 'SCAFFOLD' in content:
    print('SCAFFOLD')
elif 'REASONING' in content:
    print('REASONING')
else:
    sys.exit(1)
" 2>/dev/null) || return 1

  echo "$result"
  return 0
}

_classify_heuristic() {
  local chunk="$1"
  local lower
  lower=$(echo "$chunk" | tr '[:upper:]' '[:lower:]')

  # Count scaffold keyword hits
  local scaffold_hits=0
  for kw in $SCAFFOLD_KEYWORDS; do
    if echo "$lower" | grep -qw "$kw"; then
      scaffold_hits=$((scaffold_hits + 1))
    fi
  done

  # Count reasoning keyword hits
  local reasoning_hits=0
  for kw in $REASONING_KEYWORDS; do
    if echo "$lower" | grep -qw "$kw"; then
      reasoning_hits=$((reasoning_hits + 1))
    fi
  done

  # Tie-break toward REASONING (safer/more capable)
  if [ "$scaffold_hits" -gt "$reasoning_hits" ]; then
    echo "SCAFFOLD"
  else
    echo "REASONING"
  fi
}
