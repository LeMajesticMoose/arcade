# ARCADE — Setup Guide

## Prerequisites

- **bash** — tested on bash 5.x (macOS and Linux)
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Python 3.10+** — for classification, revision, and cost parsing
- **curl** — for API calls and Calx hook fetching
- **git** — for Gitea state repo integration (optional)
- **One inference backend** — see Configuration below
- **Calx** (optional) — `pip install getcalx` — see Calx section

---

## Configuration

Copy the example config and fill in your values:

```bash
cp arcade.conf.example arcade.conf
```

Edit `arcade.conf`. The three required fields are:

```bash
ANTHROPIC_API_KEY="your-key-here"
ANTHROPIC_BASE_URL="..."   # see backend options below
ARCADE_STATE_ROOT="${HOME}/.arcade/projects"
```

`arcade.conf` is gitignored and never committed.

### Backend options

**Option A — Local LiteLLM proxy (recommended for cost control)**

Run LiteLLM in front of your inference providers. ARCADE uses it for model alias
translation, spend logging, and routing to local Ollama models.

```bash
ANTHROPIC_BASE_URL="http://your-litellm-host:4000"
ANTHROPIC_API_KEY="your-litellm-master-key"
LITELLM_MASTER_KEY="your-litellm-master-key"   # enables cost= field in run-log
LITELLM_URL="http://your-litellm-host:4000"
```

See `ADVANCED.md` for a minimal LiteLLM config with model aliases and Ollama routing.

**Option B — OpenRouter (multi-model, single key)**

```bash
ANTHROPIC_BASE_URL="https://openrouter.ai/api/v1"
ANTHROPIC_API_KEY="sk-or-your-openrouter-key"
OPENROUTER_API_KEY="sk-or-your-openrouter-key"   # enables balance checks
```

OpenRouter gives access to Claude Sonnet, Haiku, and many other models under one key.
The balance check (`check_openrouter_balance`) queries your remaining credit before each
paid chunk and halts if balance is below `ARCADE_MIN_BALANCE_USD` (default: $1.00).

**Option C — Anthropic direct**

```bash
ANTHROPIC_BASE_URL="https://api.anthropic.com"
ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

For the oauth mode (Claude Max subscription at $0), leave `ANTHROPIC_BASE_URL` unset or
set it to `https://api.anthropic.com` and run sessions with `--mode oauth`. The `oauth`
mode uses Claude Code's native Max subscription authentication rather than the API key.

---

## State storage

`ARCADE_STATE_ROOT` is the directory where ARCADE writes queue state, run logs, and issues
for each project. It defaults to `~/.arcade/projects` if not set in `arcade.conf`.

Requirements:
- Must exist and be writable by the user running ARCADE
- Should be on persistent storage — losing this directory loses loop state
- Local disk works. NFS or other network mounts work if writable.

```bash
mkdir -p ~/.arcade/projects
```

For resilience across machine rebuilds, point it at a NAS or shared volume and set
`GITEA_URL`/`GITEA_TOKEN`/`GITEA_ORG` in `arcade.conf` to sync state to a Gitea repo
after each chunk.

---

## Gitea integration (optional)

ARCADE can push `run-log.md` and `queue.md` to a Gitea state repo after each chunk.
This gives you a remote backup of loop state and a readable history.

```bash
GITEA_URL="https://your-gitea-instance"
GITEA_TOKEN="your-personal-access-token"
GITEA_ORG="your-org"
```

If these are blank, Gitea pushes are silently skipped and everything is local only.

---

## Calx (optional)

Calx is a correction engineering layer for Claude Code. It captures behavioral corrections,
detects recurring mistakes, promotes them to rules, and injects those rules at every session
start via Claude Code's native hooks mechanism.

```bash
pip install getcalx
```

After installing, set `CALX_VENV` in `arcade.conf` to the path of the Python venv
where getcalx was installed:

```bash
CALX_VENV="/path/to/your/calx-venv"
```

`start-arcade.sh` will automatically initialize `.calx/` in each project's state directory
on first run and register the Calx hooks in `.claude/settings.json`.

**Known issue — getcalx 0.3.0 packaging bug:** The hook shell scripts are not bundled in
the wheel. `start-arcade.sh` works around this by fetching the four scripts from the
getcalx GitHub source on first use. An internet connection is required the first time Calx
runs in a new project directory. After the first run the scripts are cached locally and no
further fetching occurs.

If `CALX_VENV` is unset or the binary is not found, the loop continues without Calx. All
core ARCADE functionality works without it.

---

## First run

```bash
# 1. Configure
cp arcade.conf.example arcade.conf
# edit arcade.conf — set ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ARCADE_STATE_ROOT

# 2. Create a project
./masterarcade.sh --init --project my-first-project

# 3. Add tasks to the queue
# Edit ~/.arcade/projects/my-first-project/queue.md
# Or use:
./masterarcade.sh --project my-first-project --add-task "Design the data model"

# 4. Run the loop
./masterarcade.sh --project my-first-project

# 5. Check status
./masterarcade.sh --status
./masterarcade.sh --project my-first-project --status
```

---

## Queue format

```markdown
# Task queue — my-project
# Types: [REASONING] | [SCAFFOLD] | [OAUTH] | [GAUNTLET] (auto-classified if omitted)

## Pending
- [ ] [REASONING] Design the authentication architecture
- [ ] [SCAFFOLD] Generate boilerplate for all route handlers

## In Progress

## Complete
```

One chunk = one Claude Code session. Chunks without a type hint are auto-classified by
`lib/classify.sh` using keyword heuristics or a local Lumina model call.

---

## Project files

Each project needs these files in `$ARCADE_STATE_ROOT/{project-name}/`:

| File | Purpose |
|---|---|
| `queue.md` | Ordered task chunks |
| `CONTEXT.md` | Project background and architecture decisions for Claude Code |
| `CLAUDE.md` | Session instructions: promise format, delegation rules, commit style |
| `issues.md` | Open issues prepended to each session prompt |
| `run-log.md` | Written by ARCADE — do not edit manually |

`--init` creates all of these automatically. You can also pre-populate them by placing files
in `projects/{project-name}/` before running `--init`.
