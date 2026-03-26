# ARCADE MCP Server

Allows AI agents (IronClaw, Claude Code, or any MCP-compatible client) to control ARCADE
directly — start loops, check costs, manage projects — without terminal access.

## Quick start

```bash
# 1. Copy and configure
cp mcp-server.conf.example mcp-server.conf
# edit mcp-server.conf — set GIT_TOKEN, GIT_ORG, INFERENCE_API_KEY, ARCADE_STATE_ROOT

# 2. Start
./start.sh
```

`start.sh` installs `fastmcp` if needed and launches `server.py` on stdio.

## Register with Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "arcade": {
      "command": "/path/to/arcade/mcp-server/start.sh",
      "args": []
    }
  }
}
```

Replace `/path/to/arcade` with your ARCADE install directory.

## Register with IronClaw

Point IronClaw's MCP endpoint configuration at the running server. If IronClaw connects
via HTTP rather than stdio, use a wrapper like `mcp-proxy` or `npx @modelcontextprotocol/server-stdio-to-http`
to expose the stdio server over HTTP.

## Tools

| Tool | Description |
|---|---|
| `arcade_init_project` | Create a new project — state directory, scaffold files, optional GitHub repo |
| `arcade_start_project` | Launch a loop session in tmux for the given project |
| `arcade_get_status` | Queue counts, next chunk, open issues, last run-log entry |
| `arcade_list_projects` | All projects in ARCADE_STATE_ROOT with summary stats |
| `arcade_add_task` | Append a task chunk to a project's queue.md |
| `arcade_get_cost` | Cost totals from run-log.md (last_run / session / all_time) |
| `arcade_get_balance` | Inference provider balance or usage (OpenRouter, Anthropic, OpenAI, Ollama, custom) |

## Updating credentials

Edit `mcp-server.conf` and restart `./start.sh`. The conf file is read at startup.

## Framework

**FastMCP (Python)** — `server.py` + `arcade_tools.py` — is the reference implementation.
All tools are fully implemented here.

**TypeScript** — `server.ts` — is a stub scaffold. Tool signatures and the conf loading
pattern are implemented; tool logic has TODO markers pointing to the Python reference.
To use TypeScript: `npm install && npm run build && npm start`.

## Configuration reference (mcp-server.conf)

| Variable | Purpose |
|---|---|
| `GIT_BASE_URL` | GitHub API base (default: `https://api.github.com`) |
| `GIT_TOKEN` | Personal access token, repo scope |
| `GIT_ORG` | GitHub username or org for state repos |
| `GIT_REPO` | ARCADE state repo name (default: `arcade`) |
| `INFERENCE_PROVIDER` | `openrouter` \| `anthropic` \| `openai` \| `ollama` \| `custom` |
| `INFERENCE_API_KEY` | API key for the selected provider |
| `INFERENCE_BASE_URL` | Base URL for custom provider or Ollama |
| `ARCADE_STATE_ROOT` | Must match `ARCADE_STATE_ROOT` in `arcade.conf` |
| `ARCADE_ROOT` | Path to ARCADE install (defaults to parent of `mcp-server/`) |
