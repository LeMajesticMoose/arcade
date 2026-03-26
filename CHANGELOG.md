# Changelog

## v0.2.1 — 2026-03-26

### Fixed
- **pip optional** — missing pip/pip3 no longer exits setup; prints informational
  warning and continues; Calx install is skipped gracefully if pip is absent
- **python3-venv fallback** — before attempting venv creation for Calx, checks if
  `python3 -m venv` works; if not, attempts `apt-get install python3.11-venv` /
  `python3-venv`; if that fails, falls back to `pip install --user` without venv
- **LiteLLM cross-node false negative** — health check timeout increased to 3 seconds;
  result is now a warning (`–`) not a failure; URL is saved to arcade.conf regardless
- **GitHub validation HTTP code** — replaced `-sf` with `-s` (no fail-on-error) so
  curl always returns a clean numeric HTTP code; added explicit 401 case (invalid
  token / insufficient scope) in addition to 200, 404, and other
- **Non-TTY / automation flag** — added `--yes` flag for non-interactive use; skips
  all optional installs and interactive prompts, accepts defaults; reads credentials
  from env vars `ARCADE_BACKEND`, `ARCADE_API_KEY`, `ARCADE_STATE_ROOT`; documented
  in script header comment

## v0.2.0 — 2026-03-25

### Added
- **MCP server scaffold** — `mcp-server/` directory with complete FastMCP implementation:
  all 6 arcade tools (`arcade_init_project`, `arcade_start_project`, `arcade_get_status`,
  `arcade_list_projects`, `arcade_add_task`, `arcade_get_cost`) plus `arcade_get_balance`
- **5-provider balance support** in `arcade_get_balance`: OpenRouter (live API),
  Anthropic (dashboard link), OpenAI (key validation + dashboard link), Ollama
  (reachability + model list), Custom (attempts `/balance` endpoint, graceful 404 fallback)
- **TypeScript MCP stub** — `mcp-server/server.ts` with full tool signatures and conf
  loading; logic has TODO markers pointing to Python reference implementation
- **Guided Claude Code CLI install** in `setup.sh` Stage 2: three-option menu when
  `claude` is not found — npm install, manual link, or skip; checks for npm first and
  prints Node.js install instructions if missing
- **End-to-end backend verification** in `setup.sh` Stage 7 (stage 7b): tests the
  configured backend after writing `arcade.conf` — OAuth checks `claude --version`,
  OpenRouter/Anthropic/LiteLLM use targeted curl calls; never exits on failure
- **MCP server setup stage** in `setup.sh` Stage 6b: optional guided flow for
  framework selection, GitHub credentials, inference provider, and `mcp-server.conf`
  generation
- **`projects/example-project/`** — complete template with all 5 project files:
  `queue.md` (3 example chunks with inline type comments), `CONTEXT.md`, `CLAUDE.md`,
  `issues.md`, `run-log.md`

### Changed
- `setup.sh` version: `1.0.0` → `0.2.0`
- `mcp-server/mcp-server.conf` added to `.gitignore`

## v0.1.0 — 2026-03-25

### Added
- Core orchestration: `masterarcade.sh`, `lib/` scripts (`classify.sh`, `gate.sh`,
  `revise.sh`, `cost_control.sh`), `start-arcade.sh`
- Calx behavioral correction integration via Claude Code native hooks
  (`SessionStart`, `PreToolUse`, `Stop`)
- Cost + Calx metrics in run-log: `cost=`, `calx_active=`, `calx_corrections=`,
  `calx_rules=` fields per chunk; session summary block appended on queue completion
- `curl`-pipe bootstrap installer (`setup.sh`) with four backend options, Calx install,
  smoketest, and quick-start guide
- Full documentation: `README.md`, `SETUP.md`, `CONTEXT.md`, `CLAUDE.md`, `ADVANCED.md`
- Distributed architecture Mermaid diagram in `ADVANCED.md`
- `arcade.conf.example` configuration template
