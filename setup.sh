#!/usr/bin/env bash
# ARCADE setup — curl-pipe bootstrap installer
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/LeMajesticMoose/arcade/main/setup.sh)"
set -euo pipefail

ARCADE_SETUP_VERSION="0.2.0"
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
  read -rp "  ${prompt} [y/N]: " result
  result="${result:-$default}"
  [[ "$result" =~ ^[Yy]$ ]]
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
read -rp "Press Enter to continue or Ctrl+C to exit." _discard
echo ""

# ── stage 2: dependency check ─────────────────────────────────────────────────

hdr "Dependencies"

# Required tools
req_missing=0
for tool in git curl python3; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool"
  else
    fail "$tool   required"
    req_missing=$((req_missing + 1))
  fi
done

# pip
pip_cmd=""
if command -v pip3 &>/dev/null; then
  ok "pip3"
  pip_cmd="pip3"
elif command -v pip &>/dev/null; then
  ok "pip"
  pip_cmd="pip"
else
  fail "pip   required for Calx install"
  req_missing=$((req_missing + 1))
fi

if [[ "$req_missing" -gt 0 ]]; then
  echo ""
  echo -e "${RED}${BOLD}Required tools are missing. Install them and re-run.${RESET}"
  echo ""
  echo "  Ubuntu/Debian:  sudo apt install git curl python3 python3-pip"
  echo "  macOS:          brew install git curl python3"
  echo "  Fedora/RHEL:    sudo dnf install git curl python3 python3-pip"
  echo ""
  exit 1
fi

# Claude Code CLI
echo ""
claude_ok=false
if command -v claude &>/dev/null; then
  ok "claude   Claude Code CLI"
  claude_ok=true
else
  fail "claude   Claude Code CLI — not found"
  echo ""
  echo "  Claude Code CLI is required to run ARCADE loops."
  echo ""
  echo "  [1] npm install -g @anthropic-ai/claude-code  (recommended)"
  echo "  [2] See manual install: https://docs.anthropic.com/en/docs/claude-code"
  echo "  [3] Skip for now (loops will not run)"
  echo ""
  read -rp "  Choice [1]: " claude_install_choice
  claude_install_choice="${claude_install_choice:-1}"

  case "$claude_install_choice" in
    1)
      echo ""
      if ! command -v npm &>/dev/null; then
        miss "npm not found — install Node.js first:"
        echo ""
        echo "    Ubuntu/Debian:  sudo apt install nodejs npm"
        echo "    macOS:          brew install node"
        echo "    Fedora/RHEL:    sudo dnf install nodejs npm"
        echo "    Or:             https://nodejs.org/en/download"
        echo ""
        echo "  After installing Node.js, run:"
        echo "    npm install -g @anthropic-ai/claude-code"
        echo "  then re-run this setup script."
        echo ""
      else
        echo "  Running: npm install -g @anthropic-ai/claude-code"
        echo ""
        if npm install -g @anthropic-ai/claude-code 2>&1; then
          if command -v claude &>/dev/null; then
            ok "claude   Claude Code CLI installed"
            claude_ok=true
          else
            miss "install completed but claude not found in PATH — open a new terminal and re-run setup"
          fi
        else
          miss "npm install failed — try manually: npm install -g @anthropic-ai/claude-code"
          echo "  Or see: https://docs.anthropic.com/en/docs/claude-code"
          echo ""
        fi
      fi
      ;;
    2)
      echo ""
      echo "  Manual install: https://docs.anthropic.com/en/docs/claude-code"
      echo "  After installing, re-run this setup script."
      echo ""
      ;;
    3)
      echo ""
      miss "claude   skipped — loops will not run until Claude Code is installed"
      ;;
    *)
      miss "claude   invalid choice — continuing without Claude Code"
      ;;
  esac
fi

# Optional: local inference stack
echo ""
ollama_ok=false
if command -v ollama &>/dev/null || curl -sf --max-time 2 "http://localhost:11434/api/tags" &>/dev/null; then
  ok "ollama   local inference available"
  ollama_ok=true
else
  miss "ollama   not detected"
fi

litellm_ok=false
if curl -sf --max-time 2 "http://localhost:4000/health" &>/dev/null; then
  ok "litellm  proxy detected on localhost:4000"
  litellm_ok=true
else
  miss "litellm  not detected on localhost:4000"
fi

mcp_ok=false
if curl -sf --max-time 2 "http://localhost:8000/" &>/dev/null; then
  ok "mcp      server detected on localhost:8000"
  mcp_ok=true
else
  miss "mcp      not detected on localhost:8000"
fi

ironclaw_ok=false
if command -v ironclaw &>/dev/null; then
  ok "ironclaw"
  ironclaw_ok=true
else
  miss "ironclaw not found"
fi

# Optional: Calx
echo ""
calx_ok=false
calx_venv_found=""
for candidate in \
    "$(command -v calx 2>/dev/null || true)" \
    "$(command -v getcalx 2>/dev/null || true)" \
    "${HOME}/.calx-venv/bin/calx" \
    "${HOME}/.local/bin/calx"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    calx_ok=true
    if [[ "$candidate" == *"/.calx-venv/bin/calx" ]]; then
      calx_venv_found="${HOME}/.calx-venv"
    fi
    break
  fi
done

if $calx_ok; then
  ok "calx     behavioral correction installed"
else
  miss "calx     not found — will offer install"
fi

# Summary
echo ""
echo -e "  ${BOLD}Summary${RESET}"
echo -e "  Required tools:  ${GREEN}OK${RESET}"
if $claude_ok; then
  echo -e "  Claude Code:     ${GREEN}OK${RESET}"
else
  echo -e "  Claude Code:     ${RED}NOT FOUND${RESET}  (loops will not run until installed)"
fi
if $calx_ok; then
  echo -e "  Calx:            ${GREEN}found${RESET}"
else
  echo -e "  Calx:            ${YELLOW}not found${RESET}  (will offer install)"
fi
_ollama_s="$( $ollama_ok  && echo "ollama OK"   || echo "ollama not found")"
_litellm_s="$($litellm_ok && echo "litellm OK"  || echo "litellm not found")"
_mcp_s="$(    $mcp_ok     && echo "MCP OK"      || echo "MCP not found")"
echo "  Local stack:     ${_ollama_s} / ${_litellm_s} / ${_mcp_s}"

# ── stage 3: install directory ────────────────────────────────────────────────

hdr "Install directory"

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

# ── stage 4: inference backend ────────────────────────────────────────────────

hdr "Inference backend"

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
read -rp "  Choice [1]: " backend_choice
backend_choice="${backend_choice:-1}"

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
    ;;
  3)
    INFERENCE_MODE="api"
    ANTHROPIC_BASE_URL="https://api.anthropic.com"
    echo ""
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

# ── stage 5: state directory ──────────────────────────────────────────────────

hdr "Project state"

echo "ARCADE stores project queues, run logs, and context files in a"
echo "persistent directory. This should survive reboots — avoid /tmp."
echo ""
raw_state_root="$(ask "State directory" "${HOME}/.arcade/projects")"
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

# ── stage 6: optional components ─────────────────────────────────────────────

hdr "Calx — behavioral correction"

echo "Calx observes Claude Code sessions and corrects behavioral drift."
echo "Without it the loop works, but long autonomous runs may go off-spec."
echo "Developed by Spencer Hardwick — github.com/getcalx/oss (MIT)"
echo ""

CALX_VENV="${calx_venv_found}"

if $calx_ok; then
  ok "Calx already installed"
else
  if ask_yn "Install Calx now?" "y"; then
    echo ""
    calx_install_ok=false

    if $pip_cmd install getcalx --quiet --user 2>/dev/null; then
      calx_install_ok=true
      ok "Calx installed via ${pip_cmd} --user"
    else
      echo "  User install failed — trying venv at ${HOME}/.calx-venv..."
      if python3 -m venv "${HOME}/.calx-venv" 2>/dev/null \
         && "${HOME}/.calx-venv/bin/pip" install getcalx --quiet 2>/dev/null; then
        calx_install_ok=true
        CALX_VENV="${HOME}/.calx-venv"
        ok "Calx installed in ${HOME}/.calx-venv"
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

# ── stage 6b: MCP server ─────────────────────────────────────────────────────

hdr "MCP server (optional)"

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

  # Validate token
  echo ""
  echo "  Validating GitHub token..."
  _gh_status=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${mcp_git_token}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${mcp_git_org}/${mcp_git_repo}" 2>/dev/null || echo "000")
  if [[ "$_gh_status" == "200" ]]; then
    ok "GitHub token valid — repo ${mcp_git_org}/${mcp_git_repo} found"
  elif [[ "$_gh_status" == "404" ]]; then
    miss "repo ${mcp_git_org}/${mcp_git_repo} not found — token may be valid but repo does not exist yet"
    echo "     You can create it later. MCP server will work once the repo exists."
  else
    miss "GitHub validation returned HTTP ${_gh_status} — token may be invalid or repo inaccessible"
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

# ── stage 7: write arcade.conf ────────────────────────────────────────────────

hdr "Writing configuration"

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

hdr "Verifying configuration"

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

# ── stage 9: quick start guide ────────────────────────────────────────────────

hdr "You're ready"

echo "ARCADE is installed at: ${INSTALL_DIR}"
echo "Configuration:          ${INSTALL_DIR}/arcade.conf"
echo "Project state:          ${STATE_ROOT}"
echo ""

hdr "Starting a real project"

echo "A project needs four files. Create them before running the loop:"
echo ""
echo "  queue.md      Ordered task list. One chunk = one loop run."
echo "  CONTEXT.md    Project background and constraints for Claude to read."
echo "  CLAUDE.md     Behavioral instructions: promise format, commit style."
echo "  issues.md     Known problems to address (can be empty)."
echo ""
echo "Place them in:"
echo "  ${INSTALL_DIR}/projects/my-project/"
echo ""
echo "Then run:"
echo "  cd ${INSTALL_DIR}"
echo "  ./masterarcade.sh --init --project my-project"
echo "  ./masterarcade.sh --project my-project"
echo ""

hdr "Writing queue.md"

echo "One chunk per line. Tag each with [REASONING], [SCAFFOLD], or [OAUTH]:"
echo ""
echo "  - [ ] [REASONING] Design the data model and document decisions"
echo "  - [ ] [SCAFFOLD] Generate project scaffold and directory structure"
echo "  - [ ] [REASONING] Implement core logic and write tests"
echo "  - [ ] [OAUTH] Heavy refactoring session — use subscription billing"
echo ""
echo "Keep chunks small enough to complete in one session."
echo "If a chunk fails repeatedly, ARCADE will split it automatically."
echo ""

hdr "Generating prep documents with AI"

echo "You can use Claude (in claude.ai or via API) to generate your prep"
echo "files. Describe your project and ask for:"
echo ""
echo '  "Generate queue.md, CONTEXT.md, and CLAUDE.md for this project'
echo '   following the ARCADE format. The project is: [your description]"'
echo ""
echo "See SETUP.md for a worked example and file templates."
echo ""

hdr "Commands"

echo "  ./masterarcade.sh --status"
echo "  ./masterarcade.sh --project NAME --status"
echo "  ./masterarcade.sh --project NAME --add-task \"task description\""
echo "  ./masterarcade.sh --project NAME --mode oauth"
echo "  ./masterarcade.sh --project NAME --resume"
echo ""
echo "Full documentation: ${INSTALL_DIR}/README.md"
echo "Setup reference:    ${INSTALL_DIR}/SETUP.md"
echo "Advanced options:   ${INSTALL_DIR}/ADVANCED.md"
echo ""
