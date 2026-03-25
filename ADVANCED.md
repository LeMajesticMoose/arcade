# ARCADE — Advanced Setup

For power users who want model routing, local inference, secrets management, and agent integration.

---

## LiteLLM proxy

LiteLLM sits between ARCADE and your inference providers. It handles model alias translation, fallbacks, spend logging, and routing to local Ollama. Once deployed, Claude Code never needs to know which actual model it's calling.

### Why the alias map matters

Claude Code sends specific model strings (`claude-sonnet-4-6`, `claude-sonnet-4.6[1m]`) that change with releases. The alias map absorbs any variant and routes it to your stable internal name. When Anthropic releases a new model, you update one line in LiteLLM config — not every script.

### Minimal LiteLLM config

```yaml
litellm_settings:
  drop_params: true
  model_alias_map:
    "claude-sonnet-4-6":          "claude-sonnet"
    "claude-sonnet-4.6":          "claude-sonnet"
    "claude-sonnet-4.6[1m]":      "claude-sonnet"
    "claude-3-5-sonnet-20241022": "claude-sonnet"
    "claude-haiku-4-5":           "claude-haiku"
    "claude-haiku-4.5":           "claude-haiku"
    "claude-opus-4-6":            "claude-opus"

router_settings:
  fallbacks:
    - {"default-coder": ["openrouter-free"]}
  num_retries: 1

model_list:
  - model_name: claude-sonnet
    litellm_params:
      model: openrouter/anthropic/claude-sonnet-4.6
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: claude-haiku
    litellm_params:
      model: openrouter/anthropic/claude-haiku-4.5
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: openrouter-auto
    litellm_params:
      model: openrouter/auto
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY

  - model_name: openrouter-free
    litellm_params:
      model: openrouter/google/gemini-2.5-flash
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY
```

### Connecting ARCADE to LiteLLM

```bash
# In .env or start-arcade.sh
ANTHROPIC_API_KEY=your-litellm-master-key
ANTHROPIC_BASE_URL=http://your-litellm-host:4000
ANTHROPIC_MODEL=claude-sonnet
```

---

## Local inference with Ollama

### Why local models

- Scaffolding tasks (file gen, boilerplate, format conversion) don't need Claude-quality reasoning
- Local models via Ollama run at LAN speed for $0
- OpenHands uses `default-coder` (qwen2.5-coder:7b) for all execution tasks

### Recommended models

| Model | Size | Use case |
|---|---|---|
| `qwen2.5-coder:7b` | ~5GB | Code scaffolding, OpenHands execution tier |
| `qwen3.5:9b` | ~6GB | General inference, Lumina tier |
| `qwen3.5:0.8b` | ~600MB | Chunk classification, revision calls (agent-lite) |
| `gemma3:4b` | ~3GB | Vision tasks, screenshot analysis |

### Add to LiteLLM config

```yaml
  - model_name: default-coder
    litellm_params:
      model: ollama/qwen2.5-coder:7b
      api_base: http://your-ollama-host:11434
      think: false

  - model_name: agent-lite
    litellm_params:
      model: ollama/qwen3.5:0.8b
      api_base: http://your-ollama-host:11434
      think: false
```

### Chunk classification with agent-lite

When `agent-lite` is available, `classify.sh` calls it for binary REASONING/SCAFFOLD classification. If no local model is available, it falls back to keyword heuristics (still accurate for most tasks).

---

## OpenHands execution tier

OpenHands is the free execution engine. Claude Code delegates scaffolding work to it via an MCP tool call — the ARCADE iteration continues normally while OpenHands handles the mechanical work.

### What OpenHands handles

- File generation and boilerplate
- Dependency installation
- Build runs
- Format conversion
- Any task Claude Code classifies as SCAFFOLD

### Setup

1. Install OpenHands on the same machine as Claude Code
2. Point it at LiteLLM with `default-coder` as the model
3. Deploy `openhands_run_task` MCP tool (see MCP tools section)
4. Add to `CLAUDE.md`: delegate scaffolding tasks via `openhands_run_task`

### Cost impact

Every task OpenHands handles burns zero API tokens. For a typical development session where 40-60% of work is scaffolding, this halves your token spend.

---

## Secrets management

### Simple approach — .env file

```bash
ANTHROPIC_API_KEY=...
OPENROUTER_API_KEY=...
LITELLM_MASTER_KEY=...
```

Source in `start-arcade.sh`:
```bash
set -a && source ~/.arcade/.env && set +a
```

### Team approach — Infisical

Infisical is a self-hostable secrets manager with an API. ARCADE retrieves the LiteLLM master key from Infisical at session launch rather than storing it in the script.

```bash
# Retrieve at launch time
LITELLM_KEY=$(infisical secrets get LITELLM_MASTER_KEY --plain)
export ANTHROPIC_API_KEY="$LITELLM_KEY"
```

Infisical gives you: audit logs, per-service scoping, rotation without touching scripts, and team access control.

---

## MCP tool server

An MCP server running alongside ARCADE unlocks agent-driven project management. Agents can init projects, start sessions, check status, and query costs — without touching the filesystem directly.

### ARCADE MCP tools

| Tool | Parameters | Description |
|---|---|---|
| `arcade_init_project` | project: str | Creates repos, copies prep files, sets up state directory |
| `arcade_start_project` | project: str, mode: str | Launches session in tmux. Returns session name. |
| `arcade_get_status` | project: str | Returns current chunk, last exit, open issue count |
| `arcade_list_projects` | none | Returns all projects with status summary |
| `arcade_add_task` | project: str, task: str | Appends task to queue.md |
| `arcade_get_cost` | project: str, scope: str | Cost for last_run / session / all_time |
| `arcade_get_balance` | none | OpenRouter balance, autofill threshold, sessions remaining |

### OpenHands MCP tool

| Tool | Parameters | Returns |
|---|---|---|
| `openhands_run_task` | task: str, working_dir: str | result summary, exit status, files modified |
| `openhands_get_status` | task_id: str | running / complete / failed + progress |

### FastMCP server (Python)

```python
from fastmcp import FastMCP
import subprocess

mcp = FastMCP("arcade")

@mcp.tool()
def arcade_get_status(project: str) -> dict:
    """Get current status of an ARCADE project."""
    state_dir = f"{ARCADE_STATE_ROOT}/{project}"
    run_log = open(f"{state_dir}/run-log.md").read()
    issues = open(f"{state_dir}/issues.md").read()
    return {"run_log": run_log[-2000:], "issues": issues}

@mcp.tool()
def arcade_start_project(project: str, mode: str = "reasoning") -> dict:
    """Launch an ARCADE session in tmux."""
    cmd = f"tmux new-session -d -s arcade-{project} 'cd {ARCADE_ROOT} && ./masterarcade.sh --project {project} --mode {mode}'"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return {"session": f"arcade-{project}", "status": "launched" if result.returncode == 0 else "failed"}
```

---

## Cost control

`cost_control.sh` is sourced by `masterarcade.sh`. Three functions, all passive observers.

### check_openrouter_balance

Queries the OpenRouter API before any paid chunk. If balance is at or below your threshold, halts with a clear message.

```bash
check_openrouter_balance() {
  BALANCE=$(curl -s https://openrouter.ai/api/v1/auth/key \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('limit_remaining', 999))")
  if python3 -c "exit(0 if float('${BALANCE}') > ${OPENROUTER_HALT_THRESHOLD:-2.0} else 1)"; then
    return 0
  fi
  echo "HALT: OpenRouter balance \$${BALANCE} at or below \$${OPENROUTER_HALT_THRESHOLD:-2.0} threshold"
  echo "Autofill will add credits automatically, or add credits manually and run --resume"
  exit 1
}
```

### watch_oauth_limit

Tails the Claude Code transcript in background. Signals restart on rate limit pattern.

```bash
watch_oauth_limit() {
  local transcript_dir="$HOME/.claude/projects/$(echo $PROJECT_PATH | tr '/' '-')"
  local transcript=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)
  [ -z "$transcript" ] && return
  tail -f "$transcript" 2>/dev/null | while read line; do
    if echo "$line" | grep -q "rate_limit_error\|overloaded_error"; then
      echo "OAuth rate limit hit — signaling restart via LiteLLM"
      kill -USR1 $MASTERARCADE_PID 2>/dev/null
      break
    fi
  done &
}
```

### report_chunk_cost

Reads LiteLLM spend logs after each chunk and appends to run-log.md.

```bash
report_chunk_cost() {
  local cost=0
  if [ -n "$LITELLM_URL" ] && [ -n "$LITELLM_MASTER_KEY" ]; then
    cost=$(curl -s "$LITELLM_URL/spend/logs?limit=10" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      | python3 -c "import sys,json; logs=json.load(sys.stdin).get('data',[]); print(sum(l.get('spend',0) for l in logs[:5]))" 2>/dev/null || echo 0)
  fi
  echo "## Chunk $CHUNK_INDEX — $(date '+%Y-%m-%d %H:%M') — $CHUNK_STATUS" >> "$STATE_DIR/run-log.md"
  echo "mode: $ARCADE_MODE | cost: \$$cost" >> "$STATE_DIR/run-log.md"
  echo "" >> "$STATE_DIR/run-log.md"
}
```

---

## Persistent state on a NAS or shared drive

By default ARCADE uses `~/.arcade/projects/`. For resilience across machine rebuilds, point it at a NAS mount or shared directory:

```bash
# In .env
ARCADE_STATE_ROOT=/mnt/nas/arcade/projects
```

`masterarcade.sh` uses `$ARCADE_STATE_ROOT` if set, otherwise `~/.arcade/projects`.

State is also synced to the `arcade-{project}` Git repo on every chunk completion, so it's recoverable even without NAS access.
