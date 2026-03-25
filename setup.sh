#!/usr/bin/env bash
# setup.sh — ARCADE quickstart for claw-ecosystem deployments
# Detects your environment, walks through backend selection, writes arcade.conf
set -euo pipefail

ARCADE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$ARCADE_ROOT/arcade.conf"
CONF_EXAMPLE="$ARCADE_ROOT/arcade.conf.example"

# ── colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "  ${GREEN}[OK]${NC}  %s\n" "$1"; }
miss() { printf "  ${YELLOW}[--]${NC}  %s  ${YELLOW}(not found)${NC}\n" "$1"; }
err()  { printf "  ${RED}[!!]${NC}  %s  ${RED}(required — see below)${NC}\n" "$1"; }
info() { printf "  ${BOLD}%s${NC}\n" "$1"; }

ask() {
  local prompt="$1" default="${2:-}"
  local result
  if [ -n "$default" ]; then
    read -rp "  $prompt [$default]: " result
    echo "${result:-$default}"
  else
    read -rp "  $prompt: " result
    echo "$result"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-n}"
  local result
  read -rp "  $prompt [y/N]: " result
  result="${result:-$default}"
  [[ "$result" =~ ^[Yy]$ ]]
}

# ── banner ────────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}ARCADE setup${NC}"
echo "────────────────────────────────────────────────"
echo ""

# ── section 1: environment detection ─────────────────────────────────────────
echo "${BOLD}Checking required tools...${NC}"

missing_required=0

# Required tools
for tool in claude python3 pip git curl; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool"
  else
    err "$tool"
    missing_required=$((missing_required + 1))
  fi
done

echo ""
echo "${BOLD}Checking agent ecosystem...${NC}"

# Agent ecosystem — detect if present, not required
for tool in ironclaw; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool  (agent control available)"
  else
    miss "$tool"
  fi
done

# Check for MCP server on localhost common ports
mcp_found=false
for port in 8000 8080 3000; do
  if curl -sf --max-time 2 "http://localhost:$port/" &>/dev/null; then
    ok "MCP server  (detected on localhost:$port)"
    mcp_found=true
    break
  fi
done
if ! $mcp_found; then
  miss "MCP server  (not detected on localhost)"
fi

echo ""
echo "${BOLD}Checking local inference stack...${NC}"

# Ollama
if command -v ollama &>/dev/null; then
  ok "ollama"
elif curl -sf --max-time 2 "http://localhost:11434/" &>/dev/null; then
  ok "ollama  (running on localhost:11434)"
else
  miss "ollama"
fi

# LiteLLM — check if port 4000 is listening
if curl -sf --max-time 2 "http://localhost:4000/" &>/dev/null; then
  ok "litellm  (detected on localhost:4000)"
else
  miss "litellm  (not detected on localhost:4000)"
fi

# FastMCP — check if mcp package or fastmcp is available
if python3 -c "import fastmcp" &>/dev/null 2>&1; then
  ok "fastmcp  (Python package available)"
else
  miss "fastmcp  (pip install fastmcp to enable MCP server)"
fi

echo ""
echo "${BOLD}Checking Calx...${NC}"

calx_found=false
calx_venv=""

# Check PATH
if command -v calx &>/dev/null; then
  calx_version=$(calx --version 2>/dev/null || echo "unknown")
  ok "calx  ($calx_version)"
  calx_found=true
else
  # Check common venv locations
  for venv_path in "$HOME/.calx-venv" "$HOME/.local/share/calx-venv" "$ARCADE_ROOT/.calx-venv"; do
    if [ -x "$venv_path/bin/calx" ]; then
      calx_version=$("$venv_path/bin/calx" --version 2>/dev/null || echo "unknown")
      ok "calx  ($calx_version — found at $venv_path)"
      calx_found=true
      calx_venv="$venv_path"
      break
    fi
  done
  if ! $calx_found; then
    miss "calx  (pip install getcalx)"
  fi
fi

echo ""

# Bail if required tools are missing
if [ "$missing_required" -gt 0 ]; then
  echo "${RED}${BOLD}Required tools missing. Please install them before continuing:${NC}"
  echo ""
  [ ! "$(command -v claude)" ] && echo "  Claude Code CLI: npm install -g @anthropic-ai/claude-code"
  [ ! "$(command -v python3)" ] && echo "  Python 3.10+:    see https://python.org"
  [ ! "$(command -v pip)" ]    && echo "  pip:             comes with Python 3.10+"
  [ ! "$(command -v git)" ]    && echo "  git:             apt/brew install git"
  [ ! "$(command -v curl)" ]   && echo "  curl:            apt/brew install curl"
  echo ""
  exit 1
fi

# ── section 2: install missing optional tools ─────────────────────────────────
if ! $calx_found; then
  echo "${BOLD}Optional: Calx (behavioral correction for Claude Code)${NC}"
  echo "  Calx injects behavioral rules at session start and corrects drift mid-session."
  echo "  Author: Spencer Hardwick — https://github.com/getcalx/oss"
  echo ""
  if ask_yn "Install Calx now? (pip install getcalx)"; then
    echo ""
    # Try user install first, fall back to venv
    if pip install --user getcalx 2>/dev/null; then
      calx_found=true
      echo "  Calx installed to user packages."
    else
      echo "  User install failed — creating venv at ~/.calx-venv"
      python3 -m venv "$HOME/.calx-venv"
      "$HOME/.calx-venv/bin/pip" install getcalx
      calx_found=true
      calx_venv="$HOME/.calx-venv"
      echo "  Calx installed to $HOME/.calx-venv"
    fi
  fi
fi

echo ""

# ── section 3: backend selection ─────────────────────────────────────────────
echo "${BOLD}Select your inference backend:${NC}"
echo ""
echo "  1) Claude Max subscription (OAuth)  — subscription billing, no API key required"
echo "  2) OpenRouter API                   — pay per token, multi-model access"
echo "  3) Anthropic API direct             — pay per token, Claude only"
echo "  4) Local LiteLLM proxy              — self-hosted, mixed local/API routing"
echo ""
read -rp "  Enter 1-4: " backend_choice

backend_url=""
backend_key=""
openrouter_key=""
litellm_key=""
litellm_url=""

case "$backend_choice" in
  1)
    echo ""
    info "OAuth mode: Claude Code will authenticate using your Anthropic account."
    info "No API key required. Billing comes from your Claude Max subscription."
    backend_url="https://api.anthropic.com"
    backend_key=""
    ;;
  2)
    echo ""
    info "OpenRouter: pay per token, access to many models via one key."
    info "Get your key at: https://openrouter.ai/keys"
    echo ""
    backend_url="https://openrouter.ai/api/v1"
    openrouter_key=$(ask "OpenRouter API key (sk-or-...)")
    backend_key="$openrouter_key"
    ;;
  3)
    echo ""
    info "Anthropic direct: pay per token, Claude models only."
    info "Get your key at: https://console.anthropic.com/keys"
    echo ""
    backend_url="https://api.anthropic.com"
    backend_key=$(ask "Anthropic API key (sk-ant-...)")
    ;;
  4)
    echo ""
    info "Local LiteLLM: self-hosted proxy, mixed local/API routing."
    info "See ADVANCED.md for LiteLLM configuration."
    echo ""
    backend_url=$(ask "LiteLLM base URL" "http://localhost:4000")
    backend_key=$(ask "LiteLLM master key")
    litellm_key="$backend_key"
    litellm_url="$backend_url"
    ;;
  *)
    echo "${RED}Invalid selection.${NC}"
    exit 1
    ;;
esac

echo ""

# ── section 4: state storage ─────────────────────────────────────────────────
echo "${BOLD}State storage location${NC}"
echo "  ARCADE writes queue state, run logs, and issues here."
echo "  Local disk recommended. NFS works if writable."
echo ""
state_root=$(ask "State root directory" "$HOME/.arcade/projects")

# Validate/create
if [ ! -d "$state_root" ]; then
  echo "  Creating $state_root..."
  mkdir -p "$state_root"
fi

# Test write permissions
test_file="$state_root/.arcade_write_test_$$"
if touch "$test_file" 2>/dev/null; then
  rm -f "$test_file"
  ok "State directory writable: $state_root"
else
  echo "${RED}Cannot write to $state_root — check permissions.${NC}"
  exit 1
fi

# Warn on NFS-like paths
if [[ "$state_root" == /mnt/* ]] || [[ "$state_root" == /nfs/* ]]; then
  echo ""
  echo "${YELLOW}  Note: NFS/remote paths can cause issues with sed queue operations."
  echo "  If you see queue corruption, switch to a local path.${NC}"
fi

echo ""

# ── section 5: github integration ────────────────────────────────────────────
echo "${BOLD}GitHub integration (optional)${NC}"
echo "  ARCADE can push run-log.md and queue.md to a GitHub state repo after each chunk."
echo "  Requires a classic personal access token with 'repo' scope."
echo ""
github_url=""
github_token=""
github_org=""

if ask_yn "Configure GitHub integration?"; then
  github_url="https://api.github.com"
  github_org=$(ask "GitHub username or org")
  github_token=$(ask "GitHub personal access token (classic, repo scope)")
fi

echo ""

# ── section 6: write arcade.conf ─────────────────────────────────────────────
echo "${BOLD}Writing arcade.conf${NC}"

if [ -f "$CONF_FILE" ]; then
  echo ""
  if ! ask_yn "arcade.conf already exists. Overwrite?"; then
    echo "  Skipping — keeping existing arcade.conf."
    echo ""
  else
    write_conf=true
  fi
else
  write_conf=true
fi

if [ "${write_conf:-false}" = "true" ]; then
  cat > "$CONF_FILE" << CONFEOF
# ARCADE Configuration — generated by setup.sh
# arcade.conf is gitignored — never commit it.

# ── Inference backend ─────────────────────────────────────────────────────────
ANTHROPIC_BASE_URL="${backend_url}"
ANTHROPIC_API_KEY="${backend_key}"

# ── OpenRouter (for balance checks) ──────────────────────────────────────────
OPENROUTER_API_KEY="${openrouter_key}"

# ── LiteLLM spend logging ─────────────────────────────────────────────────────
LITELLM_MASTER_KEY="${litellm_key}"
LITELLM_URL="${litellm_url}"

# ── GitHub state repo management ─────────────────────────────────────────────
GITHUB_URL="${github_url}"
GITHUB_TOKEN="${github_token}"
GITHUB_ORG="${github_org}"

# ── State storage root ────────────────────────────────────────────────────────
ARCADE_STATE_ROOT="${state_root}"

# ── Cost limits ───────────────────────────────────────────────────────────────
ARCADE_MAX_BUDGET_USD="5.00"
ARCADE_MIN_BALANCE_USD="1.00"

# ── Loop settings ─────────────────────────────────────────────────────────────
MAX_ITERATIONS="3"

# ── Calx (optional) ──────────────────────────────────────────────────────────
CALX_VENV="${calx_venv}"
CONFEOF
  ok "arcade.conf written"
fi

echo ""

# ── section 7: summary ───────────────────────────────────────────────────────
echo "${BOLD}Setup complete.${NC}"
echo ""

echo "  Backend:     $([ "$backend_choice" = "1" ] && echo "Claude Max (OAuth)" || echo "$backend_url")"
echo "  State root:  $state_root"
echo "  Calx:        $(${calx_found} && echo "installed" || echo "not installed")"
echo "  GitHub:      $([ -n "$github_org" ] && echo "$github_org" || echo "not configured")"
echo ""
echo "  To start your first project:"
echo ""
echo "    mkdir -p projects/my-project"
echo "    # place queue.md, CONTEXT.md, CLAUDE.md, issues.md in projects/my-project/"
echo ""
echo "    ./masterarcade.sh --init --project my-project"
echo "    ./masterarcade.sh --project my-project"
echo ""
echo "  To use Claude Max subscription billing:"
echo "    ./masterarcade.sh --project my-project --mode oauth"
echo ""
echo "  Documentation:"
echo "    README.md    — overview and chunk types"
echo "    SETUP.md     — full configuration reference"
echo "    ADVANCED.md  — LiteLLM, MCP, distributed setup"
echo ""
