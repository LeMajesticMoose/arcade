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
# Set in arcade.conf: CALX_VENV="/path/to/your/calx-venv"
# If unset or the binary is not found, Calx is skipped silently.
CALX_VENV="${CALX_VENV:-}"
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

# ── Model selection ───────────────────────────────────────────────────────────
case "$mode" in
  scaffold)
    MODEL="${ARCADE_SCAFFOLD_MODEL:-claude-haiku-4-5-20251001}"
    ;;
  oauth)
    MODEL="${ARCADE_OAUTH_MODEL:-claude-haiku-4-5-20251001}"
    ;;
  reasoning|*)
    MODEL="${ARCADE_REASONING_MODEL:-claude-sonnet-4-6}"
    ;;
esac

exec claude \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  "${claude_args[@]}"
