#!/usr/bin/env bash
# lib/gate.sh — Feedback gate logic
# Sourced by masterarcade.sh

PROMISE_PATTERN='<promise>ITERATION_COMPLETE</promise>'

# evaluate_gate <transcript_file> <chunk_text>
# Prints PASS or FAIL to stdout
evaluate_gate() {
  local transcript="${1:-}"
  local chunk="${2:-}"

  [ -f "$transcript" ] || { echo "FAIL"; return; }

  # Gauntlet mode: mechanically fail first 2 passes regardless of output
  if echo "$chunk" | grep -qi "\[CI-GATE-TEST\]"; then
    local rev_count="${ARCADE_REVISION_COUNT:-0}"
    if [ "$rev_count" -lt 2 ]; then
      echo "FAIL"
      return
    fi
  fi

  # Primary: look for promise string in transcript
  if grep -qF "$PROMISE_PATTERN" "$transcript" 2>/dev/null; then
    echo "PASS"
    return
  fi

  # Secondary: look for JSONL transcript (Claude Code .jsonl format)
  # The promise may be inside a JSON message content field
  if grep -q '"content"' "$transcript" 2>/dev/null; then
    if python3 -c "
import sys, json
found = False
with open('$transcript') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except:
            # plain text line — check directly
            if '$PROMISE_PATTERN' in line:
                found = True
                break
            continue
        # Recursively search for promise in JSON values
        text = json.dumps(d)
        if '$PROMISE_PATTERN' in text:
            found = True
            break
sys.exit(0 if found else 1)
" 2>/dev/null; then
      echo "PASS"
      return
    fi
  fi

  echo "FAIL"
}

# log_gate_result <state_dir> <chunk_index> <result> <chunk_text>
log_gate_result() {
  local state_dir="$1" chunk_index="$2" result="$3" chunk="$4"
  local runlog="$state_dir/run-log.md"
  {
    echo "### Gate check — chunk $chunk_index — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Result: **$result**"
    echo "Chunk: $chunk"
    echo ""
  } >> "$runlog"
}
