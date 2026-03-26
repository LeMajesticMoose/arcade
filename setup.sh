#!/usr/bin/env bash
# ARCADE setup — curl-pipe bootstrap installer
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/LeMajesticMoose/arcade/main/setup.sh)"
#
# Flags:
#   --yes          Non-interactive mode. Skips all optional installs (Claude CLI,
#                  Calx, MCP server setup) and accepts all directory/backend defaults.
#                  Supply credentials via environment variables:
#                    ARCADE_BACKEND     1=OAuth 2=OpenRouter 3=Anthropic 4=LiteLLM (default: 1)
#                    ARCADE_API_KEY     API key for chosen backend
#                    ARCADE_STATE_ROOT  State directory (default: ~/.arcade/projects)
#                  Example:
#                    ARCADE_BACKEND=2 ARCADE_API_KEY=sk-or-... \
#                      bash -c "$(curl -fsSL .../setup.sh)" -- --yes
#
#   --step <name>  Re-run a single setup stage without redoing the full install.
#                  Loads existing arcade.conf as defaults before running the stage.
#                  Stage names: deps | install | backend | state | calx | mcp | verify | summary
#                  Example:
#                    bash setup.sh --step backend
set -euo pipefail

ARCADE_SETUP_VERSION="0.3.0"

# ── flag parsing ──────────────────────────────────────────────────────────────
YES_MODE=false
STEP_MODE=""
_prev_arg=""
for _arg in "$@"; do
  if [[ "$_arg" == "--yes" ]]; then
    YES_MODE=true
  elif [[ "$_prev_arg" == "--step" ]]; then
    STEP_MODE="$_arg"
  fi
  _prev_arg="$_arg"
done
ARCADE_REPO="https://github.com/LeMajesticMoose/arcade"
ARCADE_RAW="https://raw.githubusercontent.com/LeMajesticMoose/arcade/main"

# ── colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}\xE2\x9C\x93${RESET}  $*"; }
miss() { echo -e "  ${YELLOW}\xe2\x80\x93${RESET}  $*"; }
fail() { echo -e "  ${RED}\xE2\x9C\x97${RESET}  $*"; }
hdr()  { echo ""; echo -e "${BOLD}── $* ──────────────────────────────────────────────${RESET}"; echo ""; }

die() {
  echo ""
  echo -e "${RED}${BOLD}Error:${RESET} $*"
  echo ""
  exit 1
}

ask() {
  local prompt="$1" default="${2:-}"
  local result
  if $YES_MODE; then
    echo "${default}"
    return
  fi
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " result
    echo "${result:-$default}"
  else
    read -rp "  ${prompt}: " result
    echo "$result"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-n}"
  local result
  if $YES_MODE; then
    # In --yes mode, only answer yes to truly optional prompts if default is y
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi
  read -rp "  ${prompt} [y/N]: " result
  result="${result:-$default}"
  [[ "$result" =~ ^[Yy]$ ]]
}

# ── print_header <step_name> <progress_line> ──────────────────────────────────
print_header() {
  local step_name="$1" progress_line="$2"
  local cabinet=(
    "  /^^^^^^^^^^\\  "
    "  |  +----+  | "
    "  | /|    |\\ | "
    "  |/ |    | \\| "
    "  || |    |  | "
    "  || +----+  | "
    "  ||  ARCADE || "
    "  ||=========|| "
    "  ||  o   o  || "
    "  |\\_________/| "
    "   \\_________/  "
  )
  local right=(
    "+---------------------------+"
    "|  ARCADE Setup v${ARCADE_SETUP_VERSION}  |"
    "+---------------------------+"
    ""
    "  Step: ${step_name}"
    ""
    "  ${progress_line}"
    ""
    ""
    ""
    ""
  )
  echo ""
  local i
  for i in 0 1 2 3 4 5 6 7 8 9 10; do
    printf "%-16s %s\n" "${cabinet[$i]}" "${right[$i]}"
  done
  echo ""
}

# ── stage 0: bootstrap check ─────────────────────────────────────────────────

missing_bootstrap=0
for tool in bash git curl python3; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Missing required tool: $tool"
    missing_bootstrap=$((missing_bootstrap + 1))
  fi
done

if [[ "$missing_bootstrap" -gt 0 ]]; then
  echo ""
  echo "Install missing tools, then re-run this script."
  echo ""
  echo "  Ubuntu/Debian:  sudo apt install git curl python3"
  echo "  macOS:          brew install git curl python3"
  echo "  Fedora/RHEL:    sudo dnf install git curl python3"
  echo ""
  exit 1
fi

# ── --step: load existing conf and jump to named stage ───────────────────────
INSTALL_DIR="${HOME}/arcade"
STATE_ROOT="${HOME}/.arcade/projects"
ANTHROPIC_BASE_URL=""
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
LITELLM_MASTER_KEY=""
INFERENCE_MODE="oauth"
CALX_VENV=""
backend_choice="1"

if [[ -n "$STEP_MODE" ]]; then
  # Load existing arcade.conf as defaults
  _conf_candidates=(
    "${INSTALL_DIR}/arcade.conf"
    "${HOME}/arcade/arcade.conf"
  )
  for _cf in "${_conf_candidates[@]}"; do
    if [[ -f "$_cf" ]]; then
      # shellcheck disable=SC1090
      source "$_cf" 2>/dev/null || true
      INSTALL_DIR="$(dirname "$_cf")"
      STATE_ROOT="${ARCADE_STATE_ROOT:-${STATE_ROOT}}"
      CALX_VENV="${CALX_VENV:-}"
      # Map INFERENCE_MODE back to backend_choice
      case "${INFERENCE_MODE:-oauth}" in
        oauth)  backend_choice="1" ;;
        api)
          case "${ANTHROPIC_BASE_URL:-}" in
            *openrouter*) backend_choice="2" ;;
            *anthropic*)  backend_choice="3" ;;
            *)            backend_choice="4" ;;
          esac
          ;;
      esac
      break
    fi
  done

  # Validate the step name
  case "$STEP_MODE" in
    deps|install|backend|state|calx|mcp|verify|summary) ;;
    *) echo "Unknown step: $STEP_MODE"; echo "Valid: deps install backend state calx mcp verify summary"; exit 1 ;;
  esac
fi

# _stage_active <step_name>: true when this stage should run
# In normal mode all stages run; in --step mode only the named stage runs
_stage_active() {
  [[ -z "$STEP_MODE" ]] || [[ "$STEP_MODE" == "$1" ]] || [[ "$1" == "summary" ]]
}

# ── stage 1: welcome ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}ARCADE — Autonomous Reasoning and Coding Execution${RESET}"
echo "Setup v${ARCADE_SETUP_VERSION}"
echo ""
echo "This script will:"
echo "  1. Check your environment"
echo "  2. Clone ARCADE to a directory you choose"
echo "  3. Configure your inference backend"
echo "  4. Install optional components"
echo "  5. Run a smoketest to verify everything works"
echo "  6. Show you how to start your first real project"
echo ""
if ! $YES_MODE; then
  read -rp "Press Enter to continue or Ctrl+C to exit." _discard
fi
echo ""

# ── stage 2: dependency check ─────────────────────────────────────────────────
if _stage_active "deps"; then

print_header "deps" "[deps] > install > backend > state > calx > mcp > verify"

# ── State variables used by downstream stages ─────────────────────────────────
claude_ok=false
calx_ok=false
calx_venv_found=""
pip_cmd=""
ollama_ok=false
litellm_ok=false
mcp_ok=false
ironclaw_ok=false

# ── Check all deps upfront — no installs yet ──────────────────────────────────
echo "Checking dependencies..."
echo ""

_missing=()   # names of missing deps, in display order

# python3
if command -v python3 &>/dev/null; then
  ok "python3"
else
  fail "python3   not found"
  _missing+=("python3")
fi

# pip3 / pip
if command -v pip3 &>/dev/null; then
  ok "pip3"
  pip_cmd="pip3"
elif command -v pip &>/dev/null; then
  ok "pip  (pip3 alias)"
  pip_cmd="pip"
else
  fail "pip3      not found"
  _missing+=("pip3")
fi

# node
if command -v node &>/dev/null; then
  ok "node"
else
  fail "node      not found"
  _missing+=("node")
fi

# npm
if command -v npm &>/dev/null; then
  ok "npm"
else
  fail "npm       not found"
  _missing+=("npm")
fi

# claude CLI
if command -v claude &>/dev/null; then
  ok "claude    Claude Code CLI"
  claude_ok=true
else
  fail "claude    Claude Code CLI — not found"
  _missing+=("claude")
fi

# calx
for _candidate in \
    "$(command -v calx 2>/dev/null || true)" \
    "$(command -v getcalx 2>/dev/null || true)" \
    "${HOME}/.calx-venv/bin/calx" \
    "${HOME}/.local/bin/calx"; do
  if [[ -n "$_candidate" && -x "$_candidate" ]]; then
    calx_ok=true
    if [[ "$_candidate" == *"/.calx-venv/bin/calx" ]]; then
      calx_venv_found="${HOME}/.calx-venv"
    fi
    break
  fi
done
if $calx_ok; then
  ok "calx      behavioral correction installed"
else
  miss "calx      not found"
  _missing+=("calx")
fi

# Optional: local inference stack (check-only, no install offered)
echo ""
if command -v ollama &>/dev/null || curl -sf --max-time 2 "http://localhost:11434/api/tags" &>/dev/null; then
  ok "ollama    local inference available"
  ollama_ok=true
else
  miss "ollama    not detected"
fi

if curl -sf --max-time 3 "http://localhost:4000/health" &>/dev/null; then
  ok "litellm   proxy detected on localhost:4000"
  litellm_ok=true
else
  miss "litellm   not responding — check connectivity after setup"
fi

if curl -sf --max-time 2 "http://localhost:8000/" &>/dev/null; then
  ok "mcp       server detected on localhost:8000"
  mcp_ok=true
else
  miss "mcp       not detected on localhost:8000"
fi

if command -v ironclaw &>/dev/null; then
  ok "ironclaw"
  ironclaw_ok=true
else
  miss "ironclaw  not found"
fi

# ── Single batch install prompt ───────────────────────────────────────────────
if [[ ${#_missing[@]} -gt 0 ]]; then
  echo ""
  _missing_list="$(IFS=', '; echo "${_missing[*]}")"
  echo -e "  ${YELLOW}${BOLD}The following dependencies are missing: ${_missing_list}${RESET}"
  echo ""

  _do_install=false
  if $YES_MODE; then
    echo "  (--yes mode: skipping dependency installs — install manually before running loops)"
  else
    read -rp "  Install them now? [Y/n]: " _install_ans
    _install_ans="${_install_ans:-Y}"
    if [[ "$_install_ans" =~ ^[Yy]$ ]]; then
      _do_install=true
    fi
  fi

  if $_do_install; then
    echo ""
    # ── system packages via apt ───────────────────────────────────────────────
    _apt_pkgs=()
    for _dep in "${_missing[@]}"; do
      case "$_dep" in
        python3) _apt_pkgs+=("python3") ;;
        pip3)    _apt_pkgs+=("python3-pip") ;;
        node)    _apt_pkgs+=("nodejs") ;;
        npm)     _apt_pkgs+=("npm") ;;
      esac
    done

    if [[ ${#_apt_pkgs[@]} -gt 0 ]]; then
      echo "  Installing system packages: ${_apt_pkgs[*]}"
      if sudo apt-get install -y "${_apt_pkgs[@]}" 2>&1 | sed 's/^/    /'; then
        for _dep in "${_missing[@]}"; do
          case "$_dep" in
            python3)
              command -v python3 &>/dev/null && ok "python3 installed" \
                || miss "python3 install may need a new shell to take effect"
              ;;
            pip3)
              if command -v pip3 &>/dev/null; then
                pip_cmd="pip3"
                ok "pip3 installed"
              elif command -v pip &>/dev/null; then
                pip_cmd="pip"
                ok "pip installed"
              else
                miss "pip3 install may need a new shell to take effect"
              fi
              ;;
            node)
              command -v node &>/dev/null && ok "node installed" \
                || miss "node install may need a new shell to take effect"
              ;;
            npm)
              command -v npm &>/dev/null && ok "npm installed" \
                || miss "npm install may need a new shell to take effect"
              ;;
          esac
        done
      else
        miss "apt install failed — try: sudo apt-get install ${_apt_pkgs[*]}"
      fi
      echo ""
    fi

    # ── claude CLI via npm ────────────────────────────────────────────────────
    if printf '%s\n' "${_missing[@]}" | grep -qx "claude"; then
      echo "  Installing Claude Code CLI..."
      if command -v npm &>/dev/null; then
        if npm install -g @anthropic-ai/claude-code 2>&1 | sed 's/^/    /'; then
          if command -v claude &>/dev/null; then
            ok "claude installed"
            claude_ok=true
          else
            miss "claude install completed but not in PATH — open a new shell and re-run setup"
          fi
        else
          miss "npm install failed — try: npm install -g @anthropic-ai/claude-code"
        fi
      else
        miss "npm not available — install node/npm first, then: npm install -g @anthropic-ai/claude-code"
      fi
      echo ""
    fi

    # ── calx via pip / venv ───────────────────────────────────────────────────
    if printf '%s\n' "${_missing[@]}" | grep -qx "calx"; then
      echo "  Installing Calx..."
      if [[ -z "$pip_cmd" ]]; then
        miss "Calx install skipped — pip not available (install python3-pip to enable)"
      else
        calx_install_ok=false

        if $pip_cmd install getcalx --quiet --user 2>/dev/null; then
          calx_install_ok=true
          ok "Calx installed via ${pip_cmd} --user"
        else
          echo "    User install failed — checking venv support..."
          if ! python3 -m venv --help &>/dev/null 2>&1; then
            echo "    python3-venv not found — attempting to install..."
            if sudo apt-get install -y python3.11-venv 2>/dev/null \
               || sudo apt-get install -y python3-venv 2>/dev/null; then
              ok "python3-venv installed"
            else
              miss "python3-venv install failed — falling back to pip --user"
            fi
          fi
          if python3 -m venv "${HOME}/.calx-venv" 2>/dev/null \
             && "${HOME}/.calx-venv/bin/pip" install getcalx --quiet 2>/dev/null; then
            calx_install_ok=true
            calx_venv_found="${HOME}/.calx-venv"
            ok "Calx installed in ${HOME}/.calx-venv"
          else
            echo "    Venv failed — retrying pip --user..."
            if $pip_cmd install --user getcalx --quiet 2>/dev/null; then
              calx_install_ok=true
              ok "Calx installed via ${pip_cmd} --user (fallback)"
            fi
          fi
        fi

        if $calx_install_ok; then
          calx_ok=true
        else
          miss "Calx install failed — install manually:"
          echo ""
          echo "    pip install getcalx"
          echo "    # or: python3 -m venv ~/.calx-venv && ~/.calx-venv/bin/pip install getcalx"
          echo ""
        fi
      fi
      echo ""
    fi

  else
    echo ""
    echo -e "  ${YELLOW}Warning: missing dependencies may prevent ARCADE from functioning correctly.${RESET}"
    echo ""
  fi
fi

# Summary
echo ""
echo -e "  ${BOLD}Summary${RESET}"
if command -v python3 &>/dev/null; then
  echo -e "  python3:         ${GREEN}OK${RESET}"
else
  echo -e "  python3:         ${RED}missing${RESET}"
fi
if $claude_ok; then
  echo -e "  Claude Code:     ${GREEN}OK${RESET}"
else
  echo -e "  Claude Code:     ${RED}NOT FOUND${RESET}  (loops will not run until installed)"
fi
if $calx_ok; then
  echo -e "  Calx:            ${GREEN}found${RESET}"
else
  echo -e "  Calx:            ${YELLOW}not found${RESET}  (will offer config in calx step)"
fi
_ollama_s="$( $ollama_ok  && echo "ollama OK"   || echo "ollama not found")"
_litellm_s="$($litellm_ok && echo "litellm OK"  || echo "litellm not found")"
_mcp_s="$(    $mcp_ok     && echo "MCP OK"      || echo "MCP not found")"
echo "  Local stack:     ${_ollama_s} / ${_litellm_s} / ${_mcp_s}"

fi

# ── stage 3: install directory ────────────────────────────────────────────────
if _stage_active "install"; then

print_header "install" "deps > [install] > backend > state > calx > mcp > verify"

echo "Where should ARCADE be installed?"
echo ""
raw_install_dir="$(ask "Install path" "${HOME}/arcade")"
INSTALL_DIR="${raw_install_dir/#\~/${HOME}}"

parent_dir="$(dirname "$INSTALL_DIR")"
if [[ ! -d "$parent_dir" ]]; then
  die "Parent directory does not exist: $parent_dir"
fi
if [[ ! -w "$parent_dir" ]]; then
  die "Parent directory is not writable: $parent_dir"
fi

if [[ -d "$INSTALL_DIR" ]]; then
  echo ""
  echo -e "  ${YELLOW}$INSTALL_DIR already exists.${RESET}"
  echo ""
  echo "  [1] Update existing install (git pull)"
  echo "  [2] Fresh install (backup existing to ${INSTALL_DIR}.bak.$(date +%Y%m%d))"
  echo "  [3] Exit"
  echo ""
  read -rp "  Choice [1]: " install_choice
  install_choice="${install_choice:-1}"

  case "$install_choice" in
    1)
      echo ""
      (cd "$INSTALL_DIR" && git pull --ff-only 2>&1) && ok "updated $INSTALL_DIR" \
        || die "git pull failed — check your network connection and try again."
      ;;
    2)
      backup_path="${INSTALL_DIR}.bak.$(date +%Y%m%d)"
      echo ""
      mv "$INSTALL_DIR" "$backup_path" && ok "backed up to $backup_path"
      echo ""
      git clone "$ARCADE_REPO" "$INSTALL_DIR" 2>&1 && ok "cloned to $INSTALL_DIR" \
        || die "git clone failed — check your network connection and try again."
      ;;
    3)
      echo ""
      echo "Exiting. Run setup again when ready."
      exit 0
      ;;
    *)
      die "Invalid choice."
      ;;
  esac
else
  echo ""
  git clone "$ARCADE_REPO" "$INSTALL_DIR" 2>&1 && ok "cloned to $INSTALL_DIR" \
    || die "git clone failed — check your network connection and try again."
fi

fi

# ── stage 4: inference backend ────────────────────────────────────────────────
if _stage_active "backend"; then

print_header "backend" "deps > install > [backend] > state > calx > mcp > verify"

echo "How will ARCADE connect to Claude?"
echo ""
echo "  [1] Claude Max subscription (OAuth)"
echo "      Use your Anthropic subscription — billed to your plan, not per token"
echo "      Best for: heavy development sessions, users with active Claude Max"
echo ""
echo "  [2] OpenRouter API"
echo "      Pay per token via openrouter.ai — access to Claude and other models"
echo "      Best for: API users, occasional use, multi-model access"
echo ""
echo "  [3] Anthropic API direct"
echo "      Pay per token directly with Anthropic"
echo "      Best for: simple setup, Claude-only users"
echo ""
echo "  [4] Local LiteLLM proxy"
echo "      Self-hosted proxy mixing local and API models"
echo "      Best for: distributed setups, users with local inference hardware"
echo "      Requires: LiteLLM running at a reachable address"
echo ""
if $YES_MODE; then
  backend_choice="${ARCADE_BACKEND:-1}"
  echo "  (--yes mode: using backend ${backend_choice})"
else
  read -rp "  Choice [1]: " backend_choice
  backend_choice="${backend_choice:-1}"
fi

ANTHROPIC_BASE_URL=""
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
LITELLM_MASTER_KEY=""
INFERENCE_MODE="oauth"

case "$backend_choice" in
  1)
    ANTHROPIC_BASE_URL=""
    ANTHROPIC_API_KEY=""
    INFERENCE_MODE="oauth"
    echo ""
    ok "OAuth mode selected — billing via Claude Max subscription"
    if command -v claude &>/dev/null; then
      echo ""
      if claude auth status 2>/dev/null | grep -qi "logged in"; then
        ok "claude auth   logged in"
      else
        miss "claude auth   run 'claude auth login' before running loops"
      fi
    fi
    ;;
  2)
    INFERENCE_MODE="api"
    ANTHROPIC_BASE_URL="https://openrouter.ai/api/v1"
    echo ""
    if $YES_MODE; then
      ANTHROPIC_API_KEY="${ARCADE_API_KEY:-}"
      OPENROUTER_API_KEY="${ARCADE_API_KEY:-}"
      [[ -n "$ANTHROPIC_API_KEY" ]] && ok "key accepted from ARCADE_API_KEY" \
        || miss "ARCADE_API_KEY not set — edit arcade.conf to add key"
    else
      echo "  Your OpenRouter API key (input hidden):"
      while true; do
        read -rsp "  Key: " raw_key
        echo ""
        if [[ "$raw_key" == sk-or-* ]]; then
          ANTHROPIC_API_KEY="$raw_key"
          OPENROUTER_API_KEY="$raw_key"
          ok "key accepted"
          break
        else
          echo -e "  ${YELLOW}Key should start with sk-or- — try again or Ctrl+C to exit${RESET}"
        fi
      done
    fi
    ;;
  3)
    INFERENCE_MODE="api"
    ANTHROPIC_BASE_URL="https://api.anthropic.com"
    echo ""
    if $YES_MODE; then
      ANTHROPIC_API_KEY="${ARCADE_API_KEY:-}"
      [[ -n "$ANTHROPIC_API_KEY" ]] && ok "key accepted from ARCADE_API_KEY" \
        || miss "ARCADE_API_KEY not set — edit arcade.conf to add key"
    else
      echo "  Your Anthropic API key (input hidden):"
      while true; do
        read -rsp "  Key: " raw_key
        echo ""
        if [[ "$raw_key" == sk-ant-* ]]; then
          ANTHROPIC_API_KEY="$raw_key"
          ok "key accepted"
          break
        else
          echo -e "  ${YELLOW}Key should start with sk-ant- — try again or Ctrl+C to exit${RESET}"
        fi
      done
    fi
    ;;
  4)
    INFERENCE_MODE="api"
    echo ""
    raw_litellm_url="$(ask "LiteLLM proxy URL" "http://localhost:4000")"
    ANTHROPIC_BASE_URL="$raw_litellm_url"
    echo ""
    if curl -sf --max-time 5 "${ANTHROPIC_BASE_URL}/health" &>/dev/null; then
      ok "LiteLLM reachable at $ANTHROPIC_BASE_URL"
    else
      miss "LiteLLM not responding at $ANTHROPIC_BASE_URL — check proxy before running loops"
    fi
    echo ""
    echo "  LiteLLM master key for spend logging (input hidden, press Enter to skip):"
    read -rsp "  Key: " LITELLM_MASTER_KEY || true
    echo ""
    if [[ -n "${LITELLM_MASTER_KEY}" ]]; then
      ok "LiteLLM key accepted"
    else
      miss "LiteLLM key not set — cost= field will show \$0.0000 in run-log"
    fi
    ;;
  *)
    die "Invalid backend choice."
    ;;
esac

fi

# ── stage 5: state directory ──────────────────────────────────────────────────
if _stage_active "state"; then

print_header "state" "deps > install > backend > [state] > calx > mcp > verify"

echo "ARCADE stores project queues, run logs, and context files in a"
echo "persistent directory. This should survive reboots — avoid /tmp."
echo ""
raw_state_root="$(ask "State directory" "${ARCADE_STATE_ROOT:-${HOME}/.arcade/projects}")"
STATE_ROOT="${raw_state_root/#\~/${HOME}}"

mkdir -p "$STATE_ROOT"

_test_file="${STATE_ROOT}/.arcade_write_test_$$"
if touch "$_test_file" 2>/dev/null; then
  rm -f "$_test_file"
  ok "state directory writable: $STATE_ROOT"
else
  die "Cannot write to $STATE_ROOT — check permissions."
fi

if [[ "$STATE_ROOT" == /mnt/* || "$STATE_ROOT" == /nfs/* ]]; then
  echo ""
  echo -e "  ${YELLOW}NFS/remote paths can cause issues with file operations."
  echo -e "  A local path is recommended.${RESET}"
  echo ""
  if ! ask_yn "Continue with this path anyway?"; then
    raw_state_root="$(ask "State directory" "${HOME}/.arcade/projects")"
    STATE_ROOT="${raw_state_root/#\~/${HOME}}"
    mkdir -p "$STATE_ROOT"
  fi
fi

fi

# ── stage 6: optional components ─────────────────────────────────────────────
if _stage_active "calx"; then

print_header "calx" "deps > install > backend > state > [calx] > mcp > verify"

echo "Calx observes Claude Code sessions and corrects behavioral drift."
echo "Without it the loop works, but long autonomous runs may go off-spec."
echo "Developed by Spencer Hardwick — github.com/getcalx/oss (MIT)"
echo ""

CALX_VENV="${calx_venv_found}"

if $calx_ok; then
  ok "Calx already installed"
else
  if [[ -z "$pip_cmd" ]]; then
    miss "Calx install skipped — pip not available (install python3-pip to enable)"
  elif ask_yn "Install Calx now?" "y"; then
    echo ""
    calx_install_ok=false

    # Try pip --user first
    if $pip_cmd install getcalx --quiet --user 2>/dev/null; then
      calx_install_ok=true
      ok "Calx installed via ${pip_cmd} --user"
    else
      # Try venv — check if python3-venv is available first
      echo "  User install failed — checking venv support..."
      if ! python3 -m venv --help &>/dev/null 2>&1; then
        echo "  python3-venv not found — attempting to install..."
        if apt-get install -y python3.11-venv 2>/dev/null \
           || apt-get install -y python3-venv 2>/dev/null; then
          ok "python3-venv installed"
        else
          miss "python3-venv install failed — falling back to pip --user"
        fi
      fi
      if python3 -m venv "${HOME}/.calx-venv" 2>/dev/null \
         && "${HOME}/.calx-venv/bin/pip" install getcalx --quiet 2>/dev/null; then
        calx_install_ok=true
        CALX_VENV="${HOME}/.calx-venv"
        ok "Calx installed in ${HOME}/.calx-venv"
      else
        # Final fallback: pip --user without venv
        echo "  Venv failed — retrying pip --user..."
        if $pip_cmd install --user getcalx --quiet 2>/dev/null; then
          calx_install_ok=true
          ok "Calx installed via ${pip_cmd} --user (fallback)"
        fi
      fi
    fi

    if ! $calx_install_ok; then
      miss "Calx install failed — install manually:"
      echo ""
      echo "    pip install getcalx"
      echo "    # or: python3 -m venv ~/.calx-venv && ~/.calx-venv/bin/pip install getcalx"
      echo ""
      echo "  Then set CALX_VENV in ${INSTALL_DIR}/arcade.conf"
    fi
  else
    miss "Calx install skipped"
  fi
fi

echo ""
if ! curl -sf --max-time 2 "http://localhost:3000/" &>/dev/null; then
  miss "OpenHands not detected"
  echo "     SCAFFOLD chunks will fall back to direct Claude Code execution."
  echo "     See ADVANCED.md for setup if you want delegated scaffolding."
else
  ok "OpenHands detected on localhost:3000"
fi

fi

# ── stage 6b: MCP server ─────────────────────────────────────────────────────
if _stage_active "mcp"; then

print_header "mcp" "deps > install > backend > state > calx > [mcp] > verify"

echo "An MCP server lets AI agents (IronClaw, Claude Code, or any"
echo "MCP-compatible agent) control ARCADE directly — start loops,"
echo "check costs, manage projects — without terminal access."
echo ""

if ask_yn "Set up an MCP server for agent control?"; then

  # Sub-stage A — framework
  echo ""
  echo "  MCP server framework:"
  echo ""
  echo "  [1] FastMCP (Python) — lightweight, no build step required"
  echo "  [2] TypeScript SDK   — Node.js based, broader ecosystem"
  echo ""
  read -rp "  Choice [1]: " mcp_framework_choice
  mcp_framework_choice="${mcp_framework_choice:-1}"

  # Sub-stage B — GitHub credentials
  echo ""
  echo "  The MCP server reads project state from GitHub repos."
  echo "  This requires a GitHub personal access token with repo scope."
  echo ""
  mcp_git_org="$(ask "GitHub username or org")"
  echo ""
  echo "  GitHub token (repo scope, input hidden):"
  read -rsp "  Token: " mcp_git_token
  echo ""
  mcp_git_repo="$(ask "GitHub repo name for ARCADE state" "arcade")"

  # Validate token — use -s (silent) without -f so curl exits 0 even on 4xx;
  # capture the HTTP code directly to avoid malformed codes from error paths
  echo ""
  echo "  Validating GitHub token..."
  _gh_status=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${mcp_git_token}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${mcp_git_org}/${mcp_git_repo}" 2>/dev/null)
  _gh_status="${_gh_status:-000}"
  if [[ "$_gh_status" == "200" ]]; then
    ok "GitHub token valid — repo ${mcp_git_org}/${mcp_git_repo} found"
  elif [[ "$_gh_status" == "401" ]]; then
    miss "GitHub token invalid or insufficient scope (HTTP 401)"
    echo "     Token needs 'repo' scope. Edit mcp-server.conf after setup."
  elif [[ "$_gh_status" == "404" ]]; then
    miss "repo ${mcp_git_org}/${mcp_git_repo} not found (HTTP 404) — token may be valid but repo does not exist yet"
    echo "     You can create it later. MCP server will work once the repo exists."
  else
    miss "GitHub validation returned HTTP ${_gh_status} — check token and org/repo name"
    echo "     Continuing — edit mcp-server.conf to correct credentials."
  fi

  # Sub-stage C — inference provider for balance checking
  echo ""
  echo "  Inference provider for balance monitoring:"
  echo ""
  echo "  [1] OpenRouter       — sk-or-..."
  echo "  [2] Anthropic direct — sk-ant-..."
  echo "  [3] OpenAI           — sk-..."
  echo "  [4] Local Ollama     — no balance API, usage from run-logs"
  echo "  [5] Custom URL       — enter endpoint manually"
  echo ""
  read -rp "  Choice [1]: " mcp_provider_choice
  mcp_provider_choice="${mcp_provider_choice:-1}"

  mcp_inference_provider=""
  mcp_inference_key=""
  mcp_inference_base_url=""

  case "$mcp_provider_choice" in
    1)
      mcp_inference_provider="openrouter"
      echo ""
      echo "  OpenRouter API key (input hidden):"
      read -rsp "  Key: " mcp_inference_key
      echo ""
      ok "key accepted"
      ;;
    2)
      mcp_inference_provider="anthropic"
      echo ""
      echo "  Anthropic API key (input hidden):"
      read -rsp "  Key: " mcp_inference_key
      echo ""
      ok "key accepted"
      ;;
    3)
      mcp_inference_provider="openai"
      echo ""
      echo "  OpenAI API key (input hidden):"
      read -rsp "  Key: " mcp_inference_key
      echo ""
      ok "key accepted"
      ;;
    4)
      mcp_inference_provider="ollama"
      mcp_inference_base_url="$(ask "Ollama URL" "http://localhost:11434")"
      miss "Ollama has no balance API — arcade_get_balance will return usage estimates from run-logs"
      ;;
    5)
      mcp_inference_provider="custom"
      mcp_inference_base_url="$(ask "Inference base URL")"
      echo ""
      echo "  API key for custom provider (input hidden, press Enter to skip):"
      read -rsp "  Key: " mcp_inference_key || true
      echo ""
      ;;
    *)
      mcp_inference_provider="openrouter"
      miss "invalid choice — defaulting to openrouter (edit mcp-server.conf to correct)"
      ;;
  esac

  # Sub-stage D — write mcp-server.conf and configure
  echo ""
  mcp_dir="${INSTALL_DIR}/mcp-server"

  if [[ ! -d "$mcp_dir" ]]; then
    miss "mcp-server/ directory not found in ${INSTALL_DIR}"
    echo "     Re-clone ARCADE or check your install directory."
  else
    chmod +x "${mcp_dir}/start.sh" 2>/dev/null || true

    cat > "${mcp_dir}/mcp-server.conf" << MCPCONF
# ARCADE MCP Server configuration — generated by setup.sh
# Do not commit this file.

# GitHub / Git provider
GIT_BASE_URL="https://api.github.com"
GIT_TOKEN="${mcp_git_token}"
GIT_ORG="${mcp_git_org}"
GIT_REPO="${mcp_git_repo}"

# Inference provider balance monitoring
INFERENCE_PROVIDER="${mcp_inference_provider}"
INFERENCE_API_KEY="${mcp_inference_key}"
INFERENCE_BASE_URL="${mcp_inference_base_url}"

# ARCADE state root — must match ARCADE_STATE_ROOT in arcade.conf
ARCADE_STATE_ROOT="${STATE_ROOT}"

# ARCADE installation root
ARCADE_ROOT="${INSTALL_DIR}"
MCPCONF

    ok "mcp-server.conf written"

    if [[ "$mcp_framework_choice" == "2" ]]; then
      miss "TypeScript path selected — run 'npm install && npm run build' in ${mcp_dir} before starting"
    fi

    echo ""
    echo -e "  ${GREEN}MCP server ready.${RESET} Start with:"
    echo "    cd ${mcp_dir} && ./start.sh"
    echo ""
    echo "  Register with Claude Code — add to ~/.claude/settings.json:"
    echo "    { \"mcpServers\": { \"arcade\": { \"command\": \"${mcp_dir}/start.sh\" } } }"
  fi

else
  miss "MCP server skipped — see ADVANCED.md to set up later"
fi

fi

# ── stage 7: write arcade.conf ────────────────────────────────────────────────
if _stage_active "verify"; then

print_header "verify" "deps > install > backend > state > calx > mcp > [verify]"

CONF_FILE="${INSTALL_DIR}/arcade.conf"

cat > "$CONF_FILE" << CONFEOF
# ARCADE configuration — generated by setup.sh v${ARCADE_SETUP_VERSION}
# Edit this file to change your configuration.
# Do not commit this file to version control.

# ── Inference backend ─────────────────────────────────────────────────────────
# ANTHROPIC_BASE_URL: inference endpoint
#   Claude Max (OAuth): leave empty
#   OpenRouter:         https://openrouter.ai/api/v1
#   Anthropic direct:   https://api.anthropic.com
#   LiteLLM proxy:      http://your-host:4000
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL}"

# ANTHROPIC_API_KEY: your API key (leave empty for OAuth mode)
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

# INFERENCE_MODE: set during setup — informational only
INFERENCE_MODE="${INFERENCE_MODE}"

# ── OpenRouter balance monitoring ─────────────────────────────────────────────
# Enables balance check before each paid chunk
OPENROUTER_API_KEY="${OPENROUTER_API_KEY}"

# ── LiteLLM spend logging ─────────────────────────────────────────────────────
# Enables the cost= field in run-log.md
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}"
LITELLM_URL="${ANTHROPIC_BASE_URL}"

# ── Project state ─────────────────────────────────────────────────────────────
ARCADE_STATE_ROOT="${STATE_ROOT}"

# ── Cost limits ───────────────────────────────────────────────────────────────
# Halt if cumulative session spend exceeds this amount
ARCADE_MAX_BUDGET_USD="5.00"
# Halt before a paid chunk if OpenRouter balance is below this amount
ARCADE_MIN_BALANCE_USD="1.00"

# ── Loop settings ─────────────────────────────────────────────────────────────
MAX_ITERATIONS="3"

# ── GitHub state repo sync ────────────────────────────────────────────────────
# Optional: pushes run-log.md and queue.md to a GitHub repo after each chunk
GITHUB_TOKEN=""
GITHUB_ORG=""
GITHUB_URL="https://api.github.com"

# ── Calx ─────────────────────────────────────────────────────────────────────
# Path to Python venv containing getcalx, or empty to use system PATH
CALX_VENV="${CALX_VENV}"
CONFEOF

ok "arcade.conf written to ${INSTALL_DIR}/arcade.conf"

# ── stage 7b: verify backend ──────────────────────────────────────────────────

print_header "verify" "deps > install > backend > state > calx > mcp > [verify]"

_verify_ok=false
_verify_err=""

case "$backend_choice" in
  1)
    # OAuth — check claude --version
    if command -v claude &>/dev/null && claude --version &>/dev/null 2>&1; then
      _verify_ok=true
    else
      _verify_err="claude CLI not found or not working"
    fi
    ;;
  2)
    # OpenRouter — GET /api/v1/auth/key
    if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
      _http_status=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${ANTHROPIC_API_KEY}" \
        "https://openrouter.ai/api/v1/auth/key" 2>/dev/null || echo "000")
      if [[ "$_http_status" == "200" ]]; then
        _verify_ok=true
      else
        _verify_err="HTTP ${_http_status} from openrouter.ai/api/v1/auth/key"
      fi
    else
      _verify_err="API key is empty"
    fi
    ;;
  3)
    # Anthropic direct — GET /v1/models
    if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
      _http_status=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" 2>/dev/null || echo "000")
      if [[ "$_http_status" == "200" ]]; then
        _verify_ok=true
      else
        _verify_err="HTTP ${_http_status} from api.anthropic.com/v1/models"
      fi
    else
      _verify_err="API key is empty"
    fi
    ;;
  4)
    # LiteLLM — GET {url}/health
    _http_status=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
      "${ANTHROPIC_BASE_URL}/health" 2>/dev/null || echo "000")
    if [[ "$_http_status" == "200" ]]; then
      _verify_ok=true
    else
      _verify_err="HTTP ${_http_status} from ${ANTHROPIC_BASE_URL}/health"
    fi
    ;;
esac

if $_verify_ok; then
  ok "backend reachable — credentials valid"
else
  fail "backend check failed: ${_verify_err}"
  echo ""
  echo "  arcade.conf written but loops may not work until this is resolved."
  echo "  Common causes: wrong API key, service not running, network issue."
  echo "  Edit ${INSTALL_DIR}/arcade.conf to correct credentials, then re-run."
fi

# ── stage 8: smoketest ────────────────────────────────────────────────────────

hdr "Smoketest"

echo "Run a single lightweight loop iteration to verify your setup?"
echo "This will use your configured backend to complete one small task."
echo ""
echo "Note: OAuth and API modes will consume a small number of tokens."
echo "      Local LiteLLM mode consumes no API tokens."
echo ""

smoketest_ok=false

if ask_yn "Run smoketest?" "y"; then
  smoketest_dir="${STATE_ROOT}/setup-smoketest"
  mkdir -p "$smoketest_dir"

  cat > "${smoketest_dir}/queue.md" << 'EOF'
# Task Queue — setup-smoketest
## Pending
- [ ] [SCAFFOLD] Write a file called arcade_ready.txt containing the text "ARCADE is configured correctly"
## In Progress
## Complete
EOF

  cat > "${smoketest_dir}/CONTEXT.md" << 'EOF'
# Context — setup-smoketest
This is an automated setup verification task. Write the requested file and emit the completion promise.
EOF

  cat > "${smoketest_dir}/CLAUDE.md" << 'EOF'
# Instructions — setup-smoketest
Write the requested file exactly as specified. When done, emit: <promise>ITERATION_COMPLETE</promise>
Do not ask questions. Complete the task and emit the promise.
EOF

  cat > "${smoketest_dir}/issues.md" << 'EOF'
EOF

  echo ""

  if (cd "$INSTALL_DIR" && ./masterarcade.sh --project setup-smoketest 2>&1); then
    if [[ -f "${smoketest_dir}/arcade_ready.txt" ]]; then
      ok "smoketest passed — arcade_ready.txt created"
      rm -f "${smoketest_dir}/arcade_ready.txt"
      smoketest_ok=true
    else
      miss "loop completed but arcade_ready.txt was not found"
      echo ""
      echo "  Run-log:"
      tail -5 "${smoketest_dir}/run-log.md" 2>/dev/null | sed 's/^/    /' || true
    fi
  else
    miss "loop exited with an error"
    echo ""
    echo "  Run-log:"
    tail -10 "${smoketest_dir}/run-log.md" 2>/dev/null | sed 's/^/    /' || true
    echo ""
    echo "  Common causes:"
    echo "    - Claude Code not logged in  (run: claude auth login)"
    echo "    - Invalid API key in arcade.conf"
    echo "    - LiteLLM proxy unreachable"
    echo ""
    echo "  Fix the issue and re-run:"
    echo "    cd ${INSTALL_DIR} && ./masterarcade.sh --project setup-smoketest"
  fi
else
  miss "smoketest skipped"
fi

fi

# ── stage 9: summary ──────────────────────────────────────────────────────────
if _stage_active "summary"; then

print_header "summary" "deps > install > backend > state > calx > mcp > verify > [done]"

# Read values — fall back to arcade.conf when running --step summary standalone
_conf_file="${INSTALL_DIR}/arcade.conf"
if [[ -f "$_conf_file" ]]; then
  source "$_conf_file" 2>/dev/null || true
fi

_backend_label="${INFERENCE_MODE:-oauth}"
_backend_url="${ANTHROPIC_BASE_URL:-OAuth / Claude Max}"
_state="${ARCADE_STATE_ROOT:-${STATE_ROOT}}"
_calx_val="${CALX_VENV:-not installed}"
_mcp_present="absent"
[[ -d "${INSTALL_DIR}/mcp-server" ]] && _mcp_present="present"
_claude_ver="$(claude --version 2>/dev/null || echo "not found")"

echo "  Setup complete."
echo ""
echo "  backend     ${_backend_label} (${_backend_url})"
echo "  state       ${_state}"
echo "  calx        ${_calx_val}"
echo "  mcp server  ${INSTALL_DIR}/mcp-server/ (${_mcp_present})"
echo "  claude      ${_claude_ver}"
echo ""
echo "  To start your first project:"
echo "    cd ${INSTALL_DIR}"
echo "    ./masterarcade.sh --init --project my-project"
echo "    ./masterarcade.sh --project my-project"
echo ""
echo "  Re-run any step:"
echo "    bash <(curl -fsSL https://raw.githubusercontent.com/LeMajesticMoose/arcade/main/setup.sh) --step backend"
echo ""
echo "  Full documentation: ${INSTALL_DIR}/README.md"
echo ""

fi