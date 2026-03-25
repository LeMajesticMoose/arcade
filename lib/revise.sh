#!/usr/bin/env bash
# lib/revise.sh — Chunk revision on gate failure
# Sourced by masterarcade.sh
# Calls a fast local model to decide: SPLIT, REDUCE, or HALT

LUMINA_URL="${LUMINA_URL:-${ANTHROPIC_BASE_URL:-http://localhost:4000}}"
LUMINA_MODEL="${LUMINA_MODEL:-agent-lite}"

# revise_chunk <chunk_text> <issues_file> <queue_file> <state_dir>
# Prints SPLIT, REDUCE, or HALT to stdout
# Side effect: modifies queue_file according to decision
revise_chunk() {
  local chunk="$1"
  local issues_file="$2"
  local queue_file="$3"
  local state_dir="$4"

  local open_issues=""
  if [ -f "$issues_file" ]; then
    open_issues=$(grep '^\s*- \[ \]' "$issues_file" 2>/dev/null || true)
  fi

  local decision
  decision=$(_revise_via_lumina "$chunk" "$open_issues") || \
    decision=$(_revise_heuristic "$chunk")

  log "Revision decision: $decision"

  case "$decision" in
    SPLIT)
      _apply_split "$chunk" "$queue_file" "$state_dir"
      ;;
    REDUCE)
      _apply_reduce "$chunk" "$queue_file" "$state_dir"
      ;;
    HALT)
      _apply_halt "$chunk" "$issues_file" "$state_dir"
      ;;
    *)
      # Unknown response — treat as HALT
      log "Unknown revise decision '$decision' — treating as HALT"
      _apply_halt "$chunk" "$issues_file" "$state_dir"
      decision="HALT"
      ;;
  esac

  echo "$decision"
}

_revise_via_lumina() {
  local chunk="$1" open_issues="$2"
  [ -n "${LITELLM_MASTER_KEY:-}${OPENROUTER_API_KEY:-}" ] || return 1

  local auth_header
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    auth_header="Bearer $LITELLM_MASTER_KEY"
  else
    auth_header="Bearer $OPENROUTER_API_KEY"
  fi

  local issues_section=""
  if [ -n "$open_issues" ]; then
    issues_section="Open issues blocking progress:
${open_issues}

"
  fi

  local prompt
  prompt="A development task chunk failed to complete after multiple attempts. Decide how to handle it.

${issues_section}Failed chunk:
${chunk}

Reply with exactly one word from these options:
- SPLIT: The chunk is too large. It should be broken into 2-3 smaller sequential chunks.
- REDUCE: The chunk has unclear or over-scoped requirements. Scope it down to a minimal viable version.
- HALT: The chunk is blocked by an external dependency, missing information, or unresolvable issue that requires human intervention.

Decision:"

  local escaped_prompt
  escaped_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null) || return 1

  local response
  response=$(curl -sf --max-time 20 \
    -X POST "${LUMINA_URL}/v1/chat/completions" \
    -H "Authorization: ${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${LUMINA_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}],
      \"max_tokens\": 20,
      \"temperature\": 0
    }" 2>/dev/null) || return 1

  local result
  result=$(echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
content = d.get('choices',[{}])[0].get('message',{}).get('content','').strip().upper()
for word in ['SPLIT','REDUCE','HALT']:
    if word in content:
        print(word)
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || return 1

  echo "$result"
  return 0
}

_revise_heuristic() {
  local chunk="$1"
  local word_count
  word_count=$(echo "$chunk" | wc -w)

  # Long chunks → SPLIT; short ones → REDUCE
  if [ "$word_count" -gt 30 ]; then
    echo "SPLIT"
  else
    echo "REDUCE"
  fi
}

_apply_split() {
  local chunk="$1" queue_file="$2" state_dir="$3"
  local runlog="$state_dir/run-log.md"

  log "Applying SPLIT: breaking chunk into smaller pieces"

  # Generate sub-chunks via fast model if possible
  local sub_chunks
  sub_chunks=$(_split_via_lumina "$chunk") || {
    # Fallback: mechanical split into two halves
    local half1 half2
    half1=$(echo "$chunk" | sed 's/^\(.*\) — .*/\1/' | head -c 80)
    half2="Continue: $chunk"
    sub_chunks="- [ ] [SPLIT-1] ${half1}
- [ ] [SPLIT-2] ${half2}"
  }

  # Remove original chunk from queue (mark it — actually replace with sub-chunks)
  _replace_chunk_in_queue "$chunk" "$sub_chunks" "$queue_file"

  {
    echo "### Revision: SPLIT — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Original: $chunk"
    echo "Sub-chunks:"
    echo "$sub_chunks"
    echo ""
  } >> "$runlog"
}

_split_via_lumina() {
  local chunk="$1"
  [ -n "${LITELLM_MASTER_KEY:-}${OPENROUTER_API_KEY:-}" ] || return 1

  local auth_header
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    auth_header="Bearer $LITELLM_MASTER_KEY"
  else
    auth_header="Bearer $OPENROUTER_API_KEY"
  fi

  local prompt
  prompt="Break this development task into 2-3 smaller, sequential sub-tasks. Each sub-task must be completable independently in one session.

Original task: ${chunk}

Format your response as a markdown list, one task per line, starting with '- [ ] ':
- [ ] First sub-task
- [ ] Second sub-task"

  local escaped_prompt
  escaped_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null) || return 1

  local response
  response=$(curl -sf --max-time 20 \
    -X POST "${LUMINA_URL}/v1/chat/completions" \
    -H "Authorization: ${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${LUMINA_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}],
      \"max_tokens\": 200,
      \"temperature\": 0.3
    }" 2>/dev/null) || return 1

  echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
content = d.get('choices',[{}])[0].get('message',{}).get('content','').strip()
# Extract lines starting with '- [ ]'
lines = [l for l in content.splitlines() if l.strip().startswith('- [ ]')]
if lines:
    print('\n'.join(lines))
else:
    sys.exit(1)
" 2>/dev/null
}

_apply_reduce() {
  local chunk="$1" queue_file="$2" state_dir="$3"
  local runlog="$state_dir/run-log.md"

  log "Applying REDUCE: scoping down chunk"

  local reduced_chunk
  reduced_chunk=$(_reduce_via_lumina "$chunk") || {
    # Fallback: prepend "Minimal version only:" to the chunk
    reduced_chunk="Minimal version only: $chunk"
  }

  local reduced_line="- [ ] [REDUCED] ${reduced_chunk}"
  _replace_chunk_in_queue "$chunk" "$reduced_line" "$queue_file"

  {
    echo "### Revision: REDUCE — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Original: $chunk"
    echo "Reduced:  $reduced_chunk"
    echo ""
  } >> "$runlog"
}

_reduce_via_lumina() {
  local chunk="$1"
  [ -n "${LITELLM_MASTER_KEY:-}${OPENROUTER_API_KEY:-}" ] || return 1

  local auth_header
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    auth_header="Bearer $LITELLM_MASTER_KEY"
  else
    auth_header="Bearer $OPENROUTER_API_KEY"
  fi

  local prompt
  prompt="Rewrite this development task as a minimal, completable version. Remove anything that is optional, ambiguous, or that could block progress. Keep only the core deliverable.

Original task: ${chunk}

Minimal version (one sentence):"

  local escaped_prompt
  escaped_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null) || return 1

  local response
  response=$(curl -sf --max-time 20 \
    -X POST "${LUMINA_URL}/v1/chat/completions" \
    -H "Authorization: ${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${LUMINA_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}],
      \"max_tokens\": 100,
      \"temperature\": 0.2
    }" 2>/dev/null) || return 1

  echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
content = d.get('choices',[{}])[0].get('message',{}).get('content','').strip()
if content:
    print(content)
else:
    sys.exit(1)
" 2>/dev/null
}

_apply_halt() {
  local chunk="$1" issues_file="$2" state_dir="$3"
  local runlog="$state_dir/run-log.md"

  log "Applying HALT: writing to issues.md and stopping loop"

  local timestamp
  timestamp=$(date -u '+%Y-%m-%d %H:%M UTC')

  # Append to issues.md (masterarcade.sh never marks issues resolved)
  {
    echo ""
    echo "- [ ] [HALT ${timestamp}] Chunk failed after max iterations: ${chunk}"
  } >> "$issues_file"

  {
    echo "### Revision: HALT — ${timestamp}"
    echo "Chunk: $chunk"
    echo "Reason: Max iterations reached, no progress — human intervention required"
    echo ""
  } >> "$runlog"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ARCADE HALT — human review required"
  echo " Chunk: $chunk"
  echo " Issue logged in: $issues_file"
  echo " Resume with: masterarcade.sh --project \$PROJECT --resume"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

_replace_chunk_in_queue() {
  local chunk="$1" replacement="$2" queue_file="$3"

  # Find the first matching pending line and replace it with the replacement lines
  python3 - <<PYEOF
import re

chunk = """$chunk"""
replacement = """$replacement"""
queue_file = "$queue_file"

with open(queue_file, 'r') as f:
    lines = f.readlines()

new_lines = []
replaced = False
for line in lines:
    stripped = line.rstrip('\n')
    # Match pending checkbox lines containing our chunk text
    if not replaced and re.match(r'^\s*- \[ \]', stripped) and chunk.strip() in stripped:
        # Insert replacement lines here
        for r_line in replacement.splitlines():
            new_lines.append(r_line + '\n')
        replaced = True
    else:
        new_lines.append(line)

with open(queue_file, 'w') as f:
    f.writelines(new_lines)

if not replaced:
    # Chunk not found — append replacement to Pending section
    with open(queue_file, 'a') as f:
        f.write('\n')
        f.write(replacement + '\n')
PYEOF
}
