#!/usr/bin/env bash
# masterarcade.sh — ARCADE orchestrator
# Autonomous Reasoning and Coding Execution
# https://github.com/LeMajesticMoose/arcade
set -euo pipefail

ARCADE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$ARCADE_ROOT/lib"
PROJECTS_JSON="$ARCADE_ROOT/projects.json"
ARCADE_STATE_ROOT="${ARCADE_STATE_ROOT:-${HOME}/.arcade/projects}"

GIT_BASE="${GITHUB_URL:-}"
GIT_ORG="${GITHUB_ORG:-}"
GIT_TOKEN="${GITHUB_TOKEN:-}"

START_ARCADE="${ARCADE_ROOT}/start-arcade.sh"

# Load configuration from arcade.conf, falling back to arcade.conf.example
_conf_path="${ARCADE_ROOT}/arcade.conf"
_conf_example="${ARCADE_ROOT}/arcade.conf.example"
if [ -f "$_conf_path" ]; then
  set -a
  source "$_conf_path"
  set +a
elif [ -f "$_conf_example" ]; then
  echo "[arcade] WARNING: arcade.conf not found — using arcade.conf.example defaults."
  echo "[arcade] Copy arcade.conf.example to arcade.conf and fill in your values."
  set -a
  source "$_conf_example"
  set +a
else
  echo "[arcade] ERROR: No arcade.conf or arcade.conf.example found in $ARCADE_ROOT" >&2
  exit 1
fi
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"

export MASTERARCADE_PID=$$

source "$LIB_DIR/classify.sh"
source "$LIB_DIR/gate.sh"
source "$LIB_DIR/revise.sh"
source "$LIB_DIR/cost_control.sh"

# ── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[arcade] $*"; }
die() { echo "[arcade] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
masterarcade.sh — ARCADE orchestrator

Usage:
  masterarcade.sh --init --project <name>           Init project repos + state
  masterarcade.sh --project <name>                  Run loop (default mode)
  masterarcade.sh --project <name> --mode <mode>    Run loop with mode override
  masterarcade.sh --project <name> --resume         Resume from current queue position
  masterarcade.sh --project <name> --add-task "..."  Append task to queue.md
  masterarcade.sh --status                           List all projects
  masterarcade.sh --project <name> --status          Status for one project

Modes: oauth | reasoning | scaffold
EOF
  exit 0
}

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ── projects.json helpers ─────────────────────────────────────────────────────

projects_get() {
  local key="$1"
  python3 -c "import json,sys; d=json.load(open('$PROJECTS_JSON')); print(d.get('$key',''))"
}

projects_set_field() {
  local project="$1" field="$2" value="$3"
  python3 - <<PYEOF
import json
with open('$PROJECTS_JSON','r') as f:
    d = json.load(f)
if '$project' not in d:
    d['$project'] = {}
d['$project']['$field'] = '$value'
with open('$PROJECTS_JSON','w') as f:
    json.dump(d, f, indent=2)
PYEOF
}

projects_get_field() {
  local project="$1" field="$2"
  python3 -c "
import json
d = json.load(open('$PROJECTS_JSON'))
print(d.get('$project', {}).get('$field', ''))
"
}

projects_register() {
  local project="$1" mode="${2:-reasoning}"
  python3 - <<PYEOF
import json, datetime
try:
    d = json.load(open('$PROJECTS_JSON'))
except:
    d = {}
if '$project' not in d:
    d['$project'] = {}
d['$project'].update({
    'name': '$project',
    'mode': '$mode',
    'state_dir': '$ARCADE_STATE_ROOT/$project',
    'git_code_repo': '$GIT_ORG/$project',
    'git_state_repo': '$GIT_ORG/arcade-$project',
    'created': datetime.datetime.utcnow().isoformat(),
    'last_run': None,
    'last_status': None,
})
with open('$PROJECTS_JSON', 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
}

# ── state dir helpers ─────────────────────────────────────────────────────────

state_dir() { echo "$ARCADE_STATE_ROOT/$1"; }

require_state() {
  local d
  d="$(state_dir "$1")"
  [ -d "$d" ] || die "State directory not found: $d — run --init first"
  [ -f "$d/queue.md" ] || die "queue.md not found in $d"
  echo "$d"
}

# ── queue helpers ─────────────────────────────────────────────────────────────

# Returns the first pending chunk text (stripped of leading "- [ ] ")
next_chunk() {
  local queue="$1"
  grep -m1 '^\s*- \[ \]' "$queue" 2>/dev/null | sed 's/^\s*- \[ \] *//' || true
}

# Returns the chunk line including any [TYPE] hint
next_chunk_line() {
  local queue="$1"
  grep -m1 '^\s*- \[ \]' "$queue" 2>/dev/null || true
}

mark_chunk_done() {
  local queue="$1" chunk_line="$2"
  # Escape special chars for sed. Delimiter is | so | is escaped; / is NOT escaped
  # (file paths in chunk text were breaking s/.../.../  — delimiter changed to |).
  local escaped
  escaped=$(printf '%s\n' "$chunk_line" | sed 's/[[\.*^$()+?{]/\\&/g; s/|/\\|/g')
  local _tmp; _tmp=$(mktemp)
  sed "s|^\(\s*\)- \[ \] ${escaped}|\1- [x] ${escaped}|" "$queue" > "$_tmp" && mv "$_tmp" "$queue" || true
  # Move to Complete section if exists
  true
}

append_task() {
  local queue="$1" task="$2"
  # Find "## Pending" section and append after it
  if grep -q '^## Pending' "$queue"; then
    local _tmp; _tmp=$(mktemp)
    sed "/^## Pending/a - [ ] ${task}" "$queue" > "$_tmp" && mv "$_tmp" "$queue" || true
  else
    echo "- [ ] ${task}" >> "$queue"
  fi
  log "Task appended to queue: $task"
}

pending_count() {
  local queue="$1"
  grep -c '^\s*- \[ \]' "$queue" 2>/dev/null || echo 0
}

done_count() {
  local queue="$1"
  grep -c '^\s*- \[x\]' "$queue" 2>/dev/null || echo 0
}

# ── Git state repo helpers ─────────────────────────────────────────────────────────────

git_repo_exists() {
  local repo="$1"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GIT_TOKEN" \
    "$GIT_BASE/api/v1/repos/$repo")
  [ "$status" = "200" ]
}

git_create_repo() {
  local name="$1" private="${2:-false}" description="${3:-}"
  curl -s -X POST "$GIT_BASE/api/v1/orgs/$GIT_ORG/repos" \
    -H "Authorization: token $GIT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\",\"private\":${private},\"description\":\"${description}\",\"auto_init\":true}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url','ERROR'))"
}

git_get_sha() {
  local repo="$1" path="$2"
  curl -s -H "Authorization: token $GIT_TOKEN" \
    "$GIT_BASE/api/v1/repos/$repo/contents/$path" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || true
}

git_push_file() {
  local repo="$1" path="$2" local_file="$3" message="$4"
  # No-op if GitHub/Git integration is not configured
  [ -n "$GIT_BASE" ] && [ -n "$GIT_TOKEN" ] || return 0
  local content sha method url
  content=$(base64 -w0 < "$local_file")
  sha=$(git_get_sha "$repo" "$path")
  if [ -n "$sha" ]; then
    method="PUT"
    url="$GIT_BASE/api/v1/repos/$repo/contents/$path"
    curl -s -X PUT "$url" \
      -H "Authorization: token $GIT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"message\":\"${message}\",\"content\":\"${content}\",\"sha\":\"${sha}\"}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); c=d.get('content',{}); print('updated: ' + c.get('path','?'))" 2>/dev/null || true
  else
    curl -s -X POST "$GIT_BASE/api/v1/repos/$repo/contents/$path" \
      -H "Authorization: token $GIT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"message\":\"${message}\",\"content\":\"${content}\"}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); c=d.get('content',{}); print('created: ' + c.get('path','?'))" 2>/dev/null || true
  fi
}

# ── --init ────────────────────────────────────────────────────────────────────

cmd_init() {
  local project="$1"
  [ -n "$project" ] || die "--init requires --project <name>"
  require_cmd curl
  require_cmd python3
  require_cmd git

  log "Initializing project: $project"

  # 1. Create code repo
  local code_repo="${GIT_ORG}/${project}"
  local state_repo="${GIT_ORG}/arcade-${project}"

  if git_repo_exists "$code_repo"; then
    log "Code repo already exists: $code_repo"
  else
    log "Creating code repo: $code_repo"
    git_create_repo "$project" "false" "ARCADE project: $project"
  fi

  # 2. Create state repo (private)
  if git_repo_exists "$state_repo"; then
    log "State repo already exists: $state_repo"
  else
    log "Creating state repo: $state_repo (private)"
    git_create_repo "arcade-${project}" "true" "ARCADE loop state: $project"
  fi

  # 3. Set up state directory
  local state_dir_path
  state_dir_path="$(state_dir "$project")"
  if [ ! -d "$state_dir_path" ]; then
    log "Creating state directory: $state_dir_path"
    mkdir -p "$state_dir_path"
  fi

  # 4. Clone state repo into state dir if empty
  if [ ! -f "$state_dir_path/queue.md" ]; then
    # Check for prep files in arcade/projects/{project}/
    local prep_dir="$ARCADE_ROOT/projects/$project"
    if [ -d "$prep_dir" ]; then
      log "Copying prep files from $prep_dir"
      cp "$prep_dir"/*.md "$state_dir_path/" 2>/dev/null || true
    else
      log "No prep files found in $prep_dir — creating empty scaffolds"
      cat > "$state_dir_path/queue.md" <<'QEOF'
# Task queue
# One chunk = one ARCADE session
# Types: [REASONING] or [SCAFFOLD] (auto-classified if omitted)

## Pending

## In progress

## Complete
QEOF
      cat > "$state_dir_path/issues.md" <<'IEOF'
# Issues
# Open issues are injected as context prefix at each session start
# Never mark entries resolved — gate logic handles that

IEOF
      cat > "$state_dir_path/run-log.md" <<'LEOF'
# Run log

LEOF
      cat > "$state_dir_path/CONTEXT.md" <<'CEOF'
# Project context

CEOF
    fi
  fi

  # 5. Push prep files to state repo
  log "Pushing state files to $state_repo"
  for f in queue.md issues.md run-log.md CONTEXT.md; do
    if [ -f "$state_dir_path/$f" ]; then
      git_push_file "$state_repo" "$f" "$state_dir_path/$f" \
        "chore(init): initialize $f for $project"
    fi
  done

  # 6. Register in projects.json
  projects_register "$project"
  log "Registered in projects.json"

  log "Init complete for: $project"
  log "  Code repo:  $GIT_BASE/$code_repo"
  log "  State repo: $GIT_BASE/$state_repo"
  log "  State dir:  $state_dir_path"
  log ""
  log "Next: add tasks with --add-task, then run --project $project"
}

# ── --status ──────────────────────────────────────────────────────────────────

cmd_status() {
  local project="${1:-}"
  require_cmd python3

  if [ -z "$project" ]; then
    # All projects
    python3 - <<PYEOF
import json, os

try:
    d = json.load(open('$PROJECTS_JSON'))
except:
    d = {}

if not d:
    print("No projects registered. Run --init --project <name> to create one.")
else:
    print(f"{'PROJECT':<25} {'MODE':<12} {'STATUS':<12} {'PENDING':<8} {'DONE':<6}")
    print("-" * 70)
    for name, info in d.items():
        state_dir = info.get('state_dir', '$ARCADE_STATE_ROOT/' + name)
        queue = os.path.join(state_dir, 'queue.md')
        mode = info.get('mode', '?')
        last_status = info.get('last_status', '-')
        pending = 0
        done = 0
        if os.path.exists(queue):
            with open(queue) as f:
                for line in f:
                    if line.strip().startswith('- [ ]'):
                        pending += 1
                    elif line.strip().startswith('- [x]'):
                        done += 1
        issues_file = os.path.join(state_dir, 'issues.md')
        open_issues = 0
        if os.path.exists(issues_file):
            with open(issues_file) as f:
                for line in f:
                    if line.strip().startswith('- [ ]'):
                        open_issues += 1
        issue_str = f" [{open_issues} issues]" if open_issues else ""
        print(f"{name:<25} {mode:<12} {last_status:<12} {pending:<8} {done:<6}{issue_str}")
PYEOF
  else
    local d
    d="$(require_state "$project")"
    local queue="$d/queue.md"
    local issues_file="$d/issues.md"
    local runlog="$d/run-log.md"

    echo "Project: $project"
    echo "State:   $d"
    echo "Mode:    $(projects_get_field "$project" mode)"
    echo ""
    echo "Queue:"
    echo "  Pending: $(pending_count "$queue")"
    echo "  Done:    $(done_count "$queue")"
    local chunk
    chunk=$(next_chunk "$queue")
    if [ -n "$chunk" ]; then
      echo "  Next:    $chunk"
    fi
    echo ""
    echo "Open issues:"
    grep '^\s*- \[ \]' "$issues_file" 2>/dev/null || echo "  (none)"
    echo ""
    echo "Last runs:"
    tail -20 "$runlog" 2>/dev/null || echo "  (no runs yet)"
  fi
}

# ── --add-task ────────────────────────────────────────────────────────────────

cmd_add_task() {
  local project="$1" task="$2"
  [ -n "$task" ] || die "--add-task requires a task string"
  local d
  d="$(require_state "$project")"
  append_task "$d/queue.md" "$task"
}

# ── main loop ─────────────────────────────────────────────────────────────────

cmd_run() {
  local project="$1" mode="${2:-}" resume="${3:-false}"
  require_cmd claude
  require_cmd python3

  local d
  d="$(require_state "$project")"
  local queue="$d/queue.md"
  local issues_file="$d/issues.md"
  local runlog="$d/run-log.md"
  local state_repo="${GIT_ORG}/arcade-${project}"

  # Resolve mode from projects.json if not overridden
  if [ -z "$mode" ]; then
    mode=$(projects_get_field "$project" mode)
    mode="${mode:-reasoning}"
  fi

  log "Starting ARCADE loop: $project (mode=$mode)"

  local iteration=0

  while true; do
    local chunk_line chunk
    chunk_line=$(next_chunk_line "$queue")
    chunk=$(next_chunk "$queue")

    if [ -z "$chunk" ]; then
      log "Queue empty — all chunks complete for: $project"
      projects_set_field "$project" "last_status" "complete"
      break
    fi

    log "Chunk: $chunk"

    # ── open issues prefix ────────────────────────────────────────────────
    local issues_prefix=""
    if [ -f "$issues_file" ] && grep -q '^\s*- \[ \]' "$issues_file" 2>/dev/null; then
      issues_prefix="OPEN ISSUES (address before proceeding):\n"
      while IFS= read -r line; do
        issues_prefix+="$line\n"
      done < <(grep '^\s*- \[ \]' "$issues_file")
      issues_prefix+="\n---\n\n"
    fi

    # ── classify chunk ────────────────────────────────────────────────────
    local chunk_class
    # Check for explicit type hint in queue line
    if echo "$chunk_line" | grep -qi '\[REASONING\]'; then
      chunk_class="REASONING"
    elif echo "$chunk_line" | grep -qi '\[SCAFFOLD\]'; then
      chunk_class="SCAFFOLD"
    elif echo "$chunk_line" | grep -qi '\[OAUTH\]'; then
      chunk_class="OAUTH"
    elif echo "$chunk_line" | grep -qi '\[CI-GATE-TEST\]'; then
      chunk_class="CI-GATE-TEST"
    else
      chunk_class=$(classify_chunk "$chunk")
    fi
    log "Classification: $chunk_class"

    # Override mode for SCAFFOLD if not already explicit
    local effective_mode="$mode"
    if [ "$chunk_class" = "SCAFFOLD" ] && [ "$mode" = "reasoning" ]; then
      effective_mode="scaffold"
      log "Routing SCAFFOLD chunk to scaffold mode"
    elif [ "$chunk_class" = "OAUTH" ]; then
      effective_mode="oauth"
      log "Routing OAUTH chunk to oauth mode"
    fi

    # ── balance check (paid modes only) ──────────────────────────────────
    if [ "$effective_mode" != "oauth" ]; then
      check_openrouter_balance
    fi

    # ── launch session ────────────────────────────────────────────────────
    export ARCADE_PROJECT="$project"
    export ARCADE_MODE="$effective_mode"
    export ARCADE_STATE_DIR="$d"
    export CHUNK_INDEX="$iteration"

    local prompt
    prompt="${issues_prefix}TASK CHUNK:\n${chunk}\n\nARCADE_REVISION_COUNT=${ARCADE_REVISION_COUNT:-0}\n\nProject context is in CONTEXT.md. When this chunk is fully complete and all acceptance criteria are met, output: <promise>ITERATION_COMPLETE</promise>"

    log "Launching session (mode=$effective_mode, iteration=$iteration)"

    local exit_code=0
    local iter=0

    # OAuth rate limit watcher (background, only for oauth mode)
    if [ "$effective_mode" = "oauth" ]; then
      watch_oauth_limit "$d" &
      WATCHER_PID=$!
    fi

    while [ $iter -lt "$MAX_ITERATIONS" ]; do
      iter=$((iter + 1))
      export ARCADE_REVISION_COUNT=$((iter - 1))
      log "Session attempt $iter/$MAX_ITERATIONS"

      # ── oauth rate-limit sentinel check ──────────────────────────────
      local sentinel="$d/.oauth_rate_limit"
      if [ -f "$sentinel" ]; then
        rm -f "$sentinel"
        log "OAuth rate limit sentinel detected — switching to reasoning mode"
        # Kill watcher, fall through to reasoning restart
        if [ -n "${WATCHER_PID:-}" ]; then
          kill "$WATCHER_PID" 2>/dev/null || true
          unset WATCHER_PID
        fi
        effective_mode="reasoning"
        export ARCADE_MODE="reasoning"
        # Restart watcher loop with adjusted mode (no watcher needed for reasoning)
      fi

      # Build Claude Code command
      # Run non-interactively with --print to pass prompt
      if [ -f "$START_ARCADE" ]; then
        ARCADE_MODE="$effective_mode" \
        ARCADE_PROJECT="$project" \
          "$START_ARCADE" "$effective_mode" --print "$prompt" \
            --cwd "$d" \
            2>&1 | tee "$d/.last_transcript.txt" || exit_code=$?
      else
        # Fallback: direct claude call
        claude --print "$prompt" \
          --cwd "$d" \
          2>&1 | tee "$d/.last_transcript.txt" || exit_code=$?
      fi

      # ── check sentinel again after session (watcher fires during run) ─
      if [ -f "$sentinel" ]; then
        rm -f "$sentinel"
        log "OAuth rate limit hit mid-session — restarting in reasoning mode"
        if [ -n "${WATCHER_PID:-}" ]; then
          kill "$WATCHER_PID" 2>/dev/null || true
          unset WATCHER_PID
        fi
        effective_mode="reasoning"
        export ARCADE_MODE="reasoning"
        log "Gate FAIL (rate limit) — retrying in reasoning mode"
        continue
      fi

      # ── gate evaluation ────────────────────────────────────────────────
      local gate_result
      gate_result=$(evaluate_gate "$d/.last_transcript.txt" "$chunk")

      log "Gate result: $gate_result"

      if [ "$gate_result" = "PASS" ]; then
        # Mark chunk done
        mark_chunk_done "$queue" "$(echo "$chunk_line" | sed 's/^\s*- \[ \] *//')"
        log "Chunk DONE: $chunk"
        CHUNK_STATUS="DONE" report_chunk_cost "$d" "$iteration" "$effective_mode"
        # Budget check after cost is logged
        check_budget_halt "$d"
        # Sync run-log to state repo
        git_push_file "$state_repo" "run-log.md" "$runlog" \
          "chore(run): update run-log after chunk $iteration"
        break
      fi

      if [ $iter -ge "$MAX_ITERATIONS" ]; then
        log "Max iterations ($MAX_ITERATIONS) hit for chunk — calling revise"
        CHUNK_STATUS="REVISED" report_chunk_cost "$d" "$iteration" "$effective_mode"
        # Budget check after cost is logged
        check_budget_halt "$d"
        local revise_decision
        revise_decision=$(revise_chunk "$chunk" "$d/issues.md" "$queue" "$d")
        log "Revise decision: $revise_decision"
        # Sync after revision
        git_push_file "$state_repo" "run-log.md" "$runlog" \
          "chore(run): update run-log after chunk $iteration revision"
        git_push_file "$state_repo" "queue.md" "$queue" \
          "chore(queue): update queue after revision decision"
        break
      fi

      log "Gate FAIL — retrying (attempt $iter/$MAX_ITERATIONS)"
    done

    # Kill watcher if running
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      unset WATCHER_PID
    fi

    iteration=$((iteration + 1))
    projects_set_field "$project" "last_status" "running"
    projects_set_field "$project" "last_run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done

  report_session_summary "$d"
  log "Loop complete for: $project"
}

# ── argument parsing ──────────────────────────────────────────────────────────

main() {
  [ $# -eq 0 ] && usage

  local project="" mode="" action="run" init=false add_task="" resume=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --init)       init=true; shift ;;
      --project)    project="${2:-}"; shift 2 ;;
      --mode)       mode="${2:-}"; shift 2 ;;
      --status)     action="status"; shift ;;
      --resume)     resume=true; shift ;;
      --add-task)   action="add-task"; add_task="${2:-}"; shift 2 ;;
      --help|-h)    usage ;;
      *)            die "Unknown argument: $1" ;;
    esac
  done

  # Validate mode
  if [ -n "$mode" ]; then
    case "$mode" in
      oauth|reasoning|scaffold) ;;
      *) die "Invalid mode: $mode (must be oauth, reasoning, or scaffold)" ;;
    esac
  fi

  if $init; then
    [ -n "$project" ] || die "--init requires --project <name>"
    cmd_init "$project"
    return
  fi

  case "$action" in
    status)
      cmd_status "$project"
      ;;
    add-task)
      [ -n "$project" ] || die "--add-task requires --project <name>"
      cmd_add_task "$project" "$add_task"
      ;;
    run)
      [ -n "$project" ] || die "No project specified — use --project <name>"
      cmd_run "$project" "$mode" "$resume"
      ;;
  esac
}

main "$@"
