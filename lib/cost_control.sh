#!/usr/bin/env bash
# lib/cost_control.sh — Spend reporting and OpenRouter balance checks
# Sourced by masterarcade.sh

LITELLM_URL="${LITELLM_URL:-${ANTHROPIC_BASE_URL:-http://localhost:4000}}"

# ARCADE_MIN_BALANCE_USD — halt before a paid chunk if OR balance is below this
ARCADE_MIN_BALANCE_USD="${ARCADE_MIN_BALANCE_USD:-1.00}"

# ARCADE_MAX_BUDGET_USD — halt the session loop if cumulative spend exceeds this
ARCADE_MAX_BUDGET_USD="${ARCADE_MAX_BUDGET_USD:-5.00}"

# ── check_openrouter_balance ───────────────────────────────────────────────────
# Halts with exit 1 if OpenRouter balance is below ARCADE_MIN_BALANCE_USD.
# No-op if OPENROUTER_API_KEY is not set.
check_openrouter_balance() {
  [ -n "${OPENROUTER_API_KEY:-}" ] || return 0

  local balance
  balance=$(curl -sf --max-time 10 \
    https://openrouter.ai/api/v1/auth/key \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    remaining = d.get('data', {}).get('limit_remaining')
    if remaining is None:
        print('999')
    else:
        print(str(remaining))
except Exception:
    print('999')
" 2>/dev/null) || balance="999"

  if python3 -c "import sys; sys.exit(0 if float('${balance}') > float('${ARCADE_MIN_BALANCE_USD}') else 1)" 2>/dev/null; then
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ARCADE HALT — OpenRouter balance low"
  echo " Balance:   \$${balance}"
  echo " Minimum:   \$${ARCADE_MIN_BALANCE_USD}"
  echo " Action:    Add credits at https://openrouter.ai/credits"
  echo "            then resume with: masterarcade.sh --project \$ARCADE_PROJECT --resume"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  exit 1
}

# ── check_budget_halt ─────────────────────────────────────────────────────────
# Halts with exit 1 if cumulative session spend in run-log.md exceeds
# ARCADE_MAX_BUDGET_USD. No-op if no cost entries exist yet.
check_budget_halt() {
  local state_dir="$1"
  local runlog="$state_dir/run-log.md"
  [ -f "$runlog" ] || return 0

  local spent
  spent=$(python3 - <<PYEOF
import re
total = 0.0
with open("$runlog") as f:
    for line in f:
        m = re.search(r'cost=\\\$([0-9]+\.[0-9]+)', line)
        if m:
            try:
                total += float(m.group(1))
            except ValueError:
                pass
print(f"{total:.4f}")
PYEOF
)

  if python3 -c "import sys; sys.exit(0 if float('${spent}') < float('${ARCADE_MAX_BUDGET_USD}') else 1)" 2>/dev/null; then
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ARCADE HALT — session budget exceeded"
  echo " Spent:   \$${spent}"
  echo " Budget:  \$${ARCADE_MAX_BUDGET_USD}"
  echo " Action:  Increase ARCADE_MAX_BUDGET_USD or review run-log.md"
  echo "          Resume: masterarcade.sh --project \$ARCADE_PROJECT --resume"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  exit 1
}

# ── watch_oauth_limit <state_dir> ─────────────────────────────────────────────
# Runs in background during oauth sessions.
# Tails the Claude Code transcript; if a rate-limit error is detected, writes
# a sentinel file so the inner loop can clean up and restart in reasoning mode.
watch_oauth_limit() {
  local state_dir="${1:-$HOME}"
  local sentinel="$state_dir/.oauth_rate_limit"

  # Locate most recent Claude Code JSONL transcript
  local project_path_slug
  project_path_slug=$(echo "$state_dir" | tr '/' '-' | sed 's/^-//')
  local transcript_dir="$HOME/.claude/projects/${project_path_slug}"

  local transcript=""
  if [ -d "$transcript_dir" ]; then
    transcript=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1 || true)
  fi

  if [ -z "$transcript" ]; then
    transcript=$(find "$HOME/.claude/projects" -name '*.jsonl' \
      -newer "$HOME/.claude" 2>/dev/null | head -1 || true)
  fi

  [ -f "$transcript" ] || return 0

  tail -f "$transcript" 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -qE 'rate_limit_error|overloaded_error|too_many_requests'; then
      echo "[arcade] OAuth rate limit detected — writing sentinel for restart"
      touch "$sentinel"
      break
    fi
  done
}

# ── _calx_metrics <state_dir> ─────────────────────────────────────────────────
# Internal helper. Prints three lines to stdout:
#   calx_active=yes|no
#   calx_corrections=N|unknown
#   calx_rules=name1 name2|none|unknown
# All parsing is in a subshell — never raises an error to the caller.
_calx_metrics() {
  local state_dir="$1"
  local calx_dir="$state_dir/.calx"

  # Calx not initialized for this project
  if [[ ! -d "$calx_dir" ]]; then
    echo "calx_active=no"
    echo "calx_corrections=unknown"
    echo "calx_rules=unknown"
    return
  fi

  # calx_active: yes if .last_clean_exit exists (session-end hook fired)
  local active="no"
  if [[ -f "$calx_dir/health/.last_clean_exit" ]]; then
    active="yes"
  fi
  echo "calx_active=${active}"

  # calx_corrections: parse corrections.jsonl if it exists.
  # corrections.jsonl is an append-only event log written by `calx correct`.
  # It is gitignored and local-only; may not exist if no corrections were logged.
  local corrections="unknown"
  if [[ "$active" = "yes" ]]; then
    corrections="0"
    if [[ -f "$calx_dir/corrections.jsonl" ]]; then
      corrections=$(( $(wc -l < "$calx_dir/corrections.jsonl" 2>/dev/null || echo 0) ))
    fi
  fi
  echo "calx_corrections=${corrections}"

  # calx_rules: parse rule names from .calx/rules/*.md headers.
  # Each rule file contains lines like: ### domain-RXXX: Rule title
  # We extract the full "domain-RXXX" ID as the rule name.
  local rules="unknown"
  if [[ "$active" = "yes" ]]; then
    rules="none"
    local rule_names=()
    if [[ -d "$calx_dir/rules" ]]; then
      while IFS= read -r rule_id; do
        [[ -n "$rule_id" ]] && rule_names+=("$rule_id")
      done < <(grep -rh '^### ' "$calx_dir/rules/"*.md 2>/dev/null \
               | sed 's/^### \([^:]*\):.*/\1/' | sort -u)
    fi
    if [[ ${#rule_names[@]} -gt 0 ]]; then
      # Join with comma
      rules=$(IFS=','; echo "${rule_names[*]}")
    fi
  fi
  echo "calx_rules=${rules}"
}

# ── report_chunk_cost <state_dir> <chunk_index> <mode> ────────────────────────
# Appends a single-line cost+calx entry to run-log.md.
# Format: [YYYY-MM-DD HH:MM] CHUNK N | MODE m | RESULT s | cost=$X.XXXX | calx_active=yes|no | calx_corrections=N | calx_rules=...
#
# Cost source: LiteLLM /spend/logs endpoint, queried with LITELLM_MASTER_KEY.
# cost=N/A when: LITELLM_MASTER_KEY is unset (LiteLLM not configured), the
# LiteLLM host is unreachable, or the API call fails. In those cases we fall
# back to $0.0000 so run-log arithmetic never encounters a non-numeric value.
report_chunk_cost() {
  local state_dir="$1"
  local chunk_index="${2:-?}"
  local mode="${3:-unknown}"
  local chunk_status="${CHUNK_STATUS:-unknown}"
  local runlog="$state_dir/run-log.md"

  # ── cost ──────────────────────────────────────────────────────────────────
  local cost="\$0.0000"

  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    local raw_cost
    raw_cost=$(curl -sf --max-time 10 \
      "${LITELLM_URL}/spend/logs?limit=10" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    logs = d.get('data', [])
    total = sum(float(l.get('spend', 0)) for l in logs[:5])
    print(f'{total:.4f}')
except Exception:
    print('')
" 2>/dev/null) || raw_cost=""
    if [[ -n "$raw_cost" && "$raw_cost" != "N/A" ]]; then
      cost="\$${raw_cost}"
    fi
    # If raw_cost is empty or N/A, keep the $0.0000 fallback
  fi

  # ── Calx metrics ──────────────────────────────────────────────────────────
  local calx_active="no" calx_corrections="unknown" calx_rules="unknown"
  # Parse in a subshell; any failure leaves defaults in place
  local calx_out
  calx_out=$(_calx_metrics "$state_dir" 2>/dev/null) || true
  if [[ -n "$calx_out" ]]; then
    calx_active=$(echo  "$calx_out" | grep '^calx_active='     | cut -d= -f2)
    calx_corrections=$(echo "$calx_out" | grep '^calx_corrections=' | cut -d= -f2)
    calx_rules=$(echo   "$calx_out" | grep '^calx_rules='      | cut -d= -f2-)
  fi

  # ── write log line ────────────────────────────────────────────────────────
  local ts
  ts=$(date -u '+%Y-%m-%d %H:%M')

  echo "[${ts}] CHUNK ${chunk_index} | MODE ${mode} | RESULT ${chunk_status} | cost=${cost} | calx_active=${calx_active} | calx_corrections=${calx_corrections} | calx_rules=${calx_rules}" >> "$runlog"
}

# ── report_session_summary <state_dir> ────────────────────────────────────────
# Appends a summary block to run-log.md after all chunks complete.
# Reads the run-log to sum cost= values and calx_corrections= values.
# Fields containing "unknown" are excluded from arithmetic and flagged as
# "(partial data)".
report_session_summary() {
  local state_dir="$1"
  local runlog="$state_dir/run-log.md"
  [[ -f "$runlog" ]] || return 0

  local ts
  ts=$(date -u '+%Y-%m-%d')

  python3 - <<PYEOF >> "$runlog"
import re, os, sys

runlog = "$runlog"
lines = open(runlog).readlines()

# Parse only the structured chunk lines (start with [YYYY-)
chunk_lines = [l for l in lines if re.match(r'^\[\d{4}-', l)]

total_chunks = len(chunk_lines)
passed   = sum(1 for l in chunk_lines if 'RESULT DONE'    in l)
revised  = sum(1 for l in chunk_lines if 'RESULT REVISED' in l)
halted   = sum(1 for l in chunk_lines if 'RESULT HALTED'  in l)

# Cost sum — skip non-numeric values
cost_total = 0.0
cost_partial = False
for l in chunk_lines:
    m = re.search(r'cost=\\\$([0-9]+\.[0-9]+)', l)
    if m:
        cost_total += float(m.group(1))
    elif 'cost=' in l and 'cost=\$0.0000' not in l:
        cost_partial = True

cost_str = f"\${cost_total:.2f}"
if cost_partial:
    cost_str += " (partial data)"

# Calx active count
calx_active_count = sum(1 for l in chunk_lines if 'calx_active=yes' in l)

# calx_corrections sum — skip "unknown"
corr_total = 0
corr_partial = False
for l in chunk_lines:
    m = re.search(r'calx_corrections=(\d+)', l)
    if m:
        corr_total += int(m.group(1))
    elif 'calx_corrections=unknown' in l:
        corr_partial = True

corr_str = str(corr_total)
if corr_partial:
    corr_str += " (partial data)"

# Most active rule: parse calx_rules= fields, count occurrences
rule_counts = {}
for l in chunk_lines:
    m = re.search(r'calx_rules=([^\s|]+)', l)
    if m:
        val = m.group(1)
        if val not in ('none', 'unknown'):
            for r in val.split(','):
                r = r.strip()
                if r:
                    rule_counts[r] = rule_counts.get(r, 0) + 1
most_active = max(rule_counts, key=rule_counts.get) if rule_counts else "none"

print(f"""
## Session Summary — $ts
Chunks run: {total_chunks} | Passed: {passed} | Revised: {revised} | Halted: {halted}
Total cost: {cost_str}
Calx active chunks: {calx_active_count} of {total_chunks}
Calx corrections fired: {corr_str}
Most active rule: {most_active}
""")
PYEOF
}

# ── query_session_cost <state_dir> ────────────────────────────────────────────
# Prints total spend accumulated in run-log.md this session.
query_session_cost() {
  local state_dir="$1"
  local runlog="$state_dir/run-log.md"

  [ -f "$runlog" ] || { echo "\$0.0000"; return; }

  python3 - <<PYEOF
import re
total = 0.0
with open("$runlog") as f:
    for line in f:
        m = re.search(r'cost=\\\$([0-9]+\.[0-9]+)', line)
        if m:
            try:
                total += float(m.group(1))
            except ValueError:
                pass
print(f"\${total:.4f}")
PYEOF
}
