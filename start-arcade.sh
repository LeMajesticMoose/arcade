#!/usr/bin/env bash
# start-arcade.sh — Claude Code launcher for ARCADE loop
# Usage: start-arcade.sh <mode> --print "<prompt>" --cwd "<dir>"
# Strips --cwd and handles it via cd instead (claude has no --cwd flag)

set -euo pipefail

mode="${1:-reasoning}"
shift

# Parse args — extract --cwd value, pass everything else to claude
cwd=""
claude_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)
      cwd="$2"
      shift 2
      ;;
    *)
      claude_args+=("$1")
      shift
      ;;
  esac
done

# cd to project directory if provided
if [[ -n "$cwd" ]]; then
  cd "$cwd"
fi

# ── Calx integration ──────────────────────────────────────────────────────────
# Calx is a behavioral correction layer for Claude Code. It injects rules at
# session start, captures corrections during the session, and guards against
# context collapse. It operates via Claude Code's native hooks mechanism.
#
# CALX_VENV: path to the venv containing the getcalx package.
# Override via env var to relocate the venv without editing this script.
CALX_VENV="${CALX_VENV:-/home/coder/.calx-venv}"
CALX_BIN="$CALX_VENV/bin/calx"

_calx_ensure() {
  local project_dir="$1"

  # Not installed — skip silently
  [[ -x "$CALX_BIN" ]] || return 0

  # Prepend venv to PATH so calx is available to hook scripts
  export PATH="$CALX_VENV/bin:$PATH"

  # Initialize .calx/ in the project dir if not already done (idempotent)
  # Use 'general' domain as default — ARCADE projects can run 'calx init -d <domains>'
  # manually to customise, after which this no-ops.
  if [[ ! -d "$project_dir/.calx" ]]; then
    echo "[arcade] Initializing Calx in $project_dir"
    (cd "$project_dir" && "$CALX_BIN" init -d general 2>&1 | sed 's/^/[calx] /') || true
  fi

  # Work around getcalx 0.3.0 packaging bug: hook shell scripts are present in
  # the GitHub source tree but not bundled into the wheel. Fetch them from the
  # known source URL if the hooks dir is empty after init.
  local hooks_dir="$project_dir/.calx/hooks"
  if [[ -d "$hooks_dir" ]]; then
    local _gh_raw="https://raw.githubusercontent.com/getcalx/oss/main/src/calx/hooks/templates"
    # Map: source_filename → installed_filename (installer.py uses tr '_' '-')
    declare -A _hook_map=(
      [session_start.sh]=session-start.sh
      [session_end.sh]=session-end.sh
      [orientation_gate.sh]=orientation-gate.sh
      [collapse_guard.sh]=collapse-guard.sh
    )
    for src_name in "${!_hook_map[@]}"; do
      dest_name="${_hook_map[$src_name]}"
      dest="$hooks_dir/$dest_name"
      if [[ ! -f "$dest" ]]; then
        if curl -sf --max-time 10 "$_gh_raw/$src_name" -o "$dest" 2>/dev/null; then
          chmod 755 "$dest"
          echo "[arcade] Installed Calx hook: $dest_name"
        else
          echo "[arcade] Warning: could not fetch Calx hook $dest_name (offline?)" >&2
        fi
      fi
    done
    unset _hook_map
  fi
}

# Run Calx setup for the current working directory
_calx_ensure "$(pwd)"

# ── Backend routing ───────────────────────────────────────────────────────────
# Load arcade.conf from the script's own directory (or ARCADE_CONF env override).
# arcade.conf is sourced *after* cd so we use the script's directory, not cwd.
_arcade_conf="${ARCADE_CONF:-$(dirname "$(realpath "$0")")/arcade.conf}"
if [[ -f "$_arcade_conf" ]]; then
  # shellcheck disable=SC1090
  source "$_arcade_conf"
fi

# Resolve which routing path applies for this invocation.
# BACKEND_MODE: oauth | api | mix  (default: oauth for backward compat)
_backend="${BACKEND_MODE:-oauth}"

if [[ "$_backend" == "mix" ]]; then
  # Detect chunk type from the next pending line in queue.md.
  # QUEUE_PATH must be set in arcade.conf or passed via environment.
  _queue="${QUEUE_PATH:-}"
  _chunk_label=""
  if [[ -n "$_queue" && -f "$_queue" ]]; then
    _chunk_label=$(grep -m1 '^\s*- \[ \]' "$_queue" 2>/dev/null \
      | grep -oP '\[(REASONING|SCAFFOLD|OAUTH)\]' | tr -d '[]' || true)
  fi
  case "${_chunk_label:-}" in
    SCAFFOLD) _backend="api"   ;;
    *)        _backend="oauth" ;;   # REASONING, OAUTH, or no label → oauth
  esac
  echo "[arcade] mix mode: chunk=${_chunk_label:-none} → ${_backend} path"
fi

# Apply the resolved backend path
case "$_backend" in
  oauth)
    case "${OAUTH_PROVIDER:-claude-max}" in
      claude-max)
        # Native auth — unset base URL so Claude Code uses its built-in default
        unset ANTHROPIC_BASE_URL 2>/dev/null || true
        ;;
      claude-pro)
        # API key is in ANTHROPIC_API_KEY from arcade.conf; just ensure base URL is clear
        export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
        unset ANTHROPIC_BASE_URL 2>/dev/null || true
        ;;
      custom)
        # Custom OAuth endpoint — strip /v1 if present (Claude Code appends it)
        export ANTHROPIC_BASE_URL="${OAUTH_ENDPOINT%/v1}"
        ;;
    esac
    ;;
  api)
    # Strip trailing /v1 — Claude Code appends /v1 automatically
    export ANTHROPIC_BASE_URL="${API_ENDPOINT%/v1}"
    export ANTHROPIC_API_KEY="${API_KEY:-${ANTHROPIC_API_KEY:-}}"
    ;;
esac

# ── Model selection ───────────────────────────────────────────────────────────
# API_MODEL (from arcade.conf) overrides mode defaults for api/mix paths.
# Per-mode env vars (ARCADE_REASONING_MODEL etc.) override the built-in defaults.
case "$mode" in
  scaffold)
    # On api path use API_MODEL if set; oauth path always uses subscription model
    if [[ "$_backend" == "api" && -n "${API_MODEL:-}" ]]; then
      MODEL="$API_MODEL"
    else
      MODEL="${ARCADE_SCAFFOLD_MODEL:-claude-haiku-4-5-20251001}"
    fi
    ;;
  oauth)
    MODEL="${ARCADE_OAUTH_MODEL:-claude-haiku-4-5-20251001}"
    ;;
  reasoning|*)
    if [[ "$_backend" == "api" && -n "${API_MODEL:-}" ]]; then
      MODEL="$API_MODEL"
    else
      MODEL="${ARCADE_REASONING_MODEL:-claude-sonnet-4-6}"
    fi
    ;;
esac

exec claude \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  "${claude_args[@]}"
