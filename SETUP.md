# ARCADE — Setup Guide

Run `./setup.sh` for an interactive setup experience that detects your environment,
walks you through backend selection, and writes `arcade.conf`. The rest of this document
covers each step in detail.

---

## Prerequisites

- **bash** 5.x — macOS and Linux. Windows via WSL2.
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Python 3.10+** — for classification, revision, and cost parsing
- **curl** — for API calls and Calx hook fetching
- **git** — for GitHub state repo integration (optional)
- **One inference backend** — see below
- **Calx** (optional) — `pip install getcalx`

---

## Understanding inference backends

Choose one backend to start. You can change it later by editing `arcade.conf`.

**Claude Max subscription (OAuth mode)**

Claude Code authenticates with your Anthropic account using your existing browser session or stored credentials. When a chunk runs in OAUTH mode, billing comes from your Claude Max subscription quota — not per-token API charges. This is the preferred mode for heavy development sessions. Claude Max is a paid subscription; "OAuth" refers to the authentication method, not a free tier.

Set `ANTHROPIC_BASE_URL` to `https://api.anthropic.com` (or leave it unset) and run chunks with `--mode oauth` or tag them `[OAUTH]` in your queue. No `ANTHROPIC_API_KEY` is required for OAuth-only setups — Claude Code uses your account session.

**OpenRouter API**

A third-party routing service providing access to Claude and many other models via a single API key. Pay per token at published rates. Recommended for API users who want access to multiple models without managing separate provider accounts. ARCADE's balance monitoring (`check_openrouter_balance`) queries your remaining credit before each paid chunk and halts cleanly if you're running low.

**Anthropic API direct**

Connect directly to Anthropic's API. Pay per token. Simpler setup than OpenRouter if you only use Claude models. No built-in balance monitoring beyond what Anthropic's dashboard provides.

**Local LiteLLM proxy**

A self-hosted proxy that can route to local Ollama models, API models, or both. In Standard and Distributed deployments, SCAFFOLD chunks route to local models at zero token cost while REASONING chunks route to API models. Requires more setup but significantly reduces spend on high-volume projects. Recommended if you have local inference hardware. See [ADVANCED.md](ADVANCED.md) for LiteLLM configuration.

**How modes interact.** ARCADE selects the backend per chunk based on chunk type and the mode configured in `arcade.conf`. A single project run can use OAUTH for REASONING chunks and a local LiteLLM model for SCAFFOLD chunks simultaneously. The cost control layer tracks spend across all modes.

---

## Configuration

Copy the example config and fill in your values:

```bash
cp arcade.conf.example arcade.conf
```

The three required fields:

```bash
ANTHROPIC_API_KEY="your-key-here"       # not required for OAuth-only setups
ANTHROPIC_BASE_URL="..."                # see backend options above
ARCADE_STATE_ROOT="${HOME}/.arcade/projects"
```

`arcade.conf` is gitignored and never committed.

### Backend-specific config

**OAuth (Claude Max subscription):**

```bash
ANTHROPIC_BASE_URL="https://api.anthropic.com"
ANTHROPIC_API_KEY=""   # leave blank if using OAuth-only
```

**OpenRouter:**

```bash
ANTHROPIC_BASE_URL="https://openrouter.ai/api/v1"
ANTHROPIC_API_KEY="sk-or-your-openrouter-key"
OPENROUTER_API_KEY="sk-or-your-openrouter-key"   # enables balance checks
```

**Anthropic direct:**

```bash
ANTHROPIC_BASE_URL="https://api.anthropic.com"
ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

**Local LiteLLM:**

```bash
ANTHROPIC_BASE_URL="http://your-litellm-host:4000"
ANTHROPIC_API_KEY="your-litellm-master-key"
LITELLM_MASTER_KEY="your-litellm-master-key"   # enables cost= field in run-log
LITELLM_URL="http://your-litellm-host:4000"
```

---

## State storage

`ARCADE_STATE_ROOT` is where ARCADE writes queue state, run logs, and project issues.
Default: `~/.arcade/projects`.

Requirements:
- Must be writable by the user running ARCADE
- Should be on persistent storage — losing this directory loses loop state
- Local disk works. NFS and network mounts work if the filesystem supports atomic writes

```bash
mkdir -p ~/.arcade/projects
```

For resilience across machine rebuilds, point it at a shared volume and configure GitHub
integration (below) to sync state after each chunk.

---

## GitHub integration (optional)

ARCADE pushes `run-log.md` and `queue.md` to a GitHub state repo (`arcade-{project}`)
after each chunk. This gives you a remote backup of loop state and a readable history.

```bash
GITHUB_URL="https://api.github.com"
GITHUB_TOKEN="your-personal-access-token"   # classic token, repo scope
GITHUB_ORG="your-username-or-org"
```

If these are blank, GitHub pushes are skipped silently and everything is local only.

---

## Calx (optional)

Calx is a behavioral correction layer for Claude Code by Spencer Hardwick.
Install: `pip install getcalx`

After installing, set `CALX_VENV` in `arcade.conf` to the Python venv path:

```bash
CALX_VENV="/path/to/your/calx-venv"
```

`start-arcade.sh` initializes `.calx/` in each project's state directory on first run
and registers Calx hooks in `.claude/settings.json`.

**Known issue — getcalx 0.3.0 packaging bug:** Hook shell scripts are missing from the
wheel. `start-arcade.sh` fetches them from the GitHub source automatically on first use.
An internet connection is required the first time Calx runs in a new project directory.
After that, scripts are cached locally.

If `CALX_VENV` is unset or the binary is not found, the loop continues without Calx.

---

## Planning your project

**The four project files.** Before running `--init`, create four files for your project:

| File | Purpose |
|---|---|
| `queue.md` | Ordered task list. One `- [ ] [TYPE] task` line per chunk. |
| `CONTEXT.md` | Background, architecture decisions, and domain constraints. Claude Code reads this at the start of every session. |
| `CLAUDE.md` | Behavioral instructions: promise format, commit style, delegation rules, what not to do. |
| `issues.md` | Known problems to address. ARCADE prepends open issues to the session prompt. Leave blank for new projects. |

**Task decomposition.** One chunk = one Claude Code session = one loop run. A chunk should be completable in a single session without mid-session scope changes. If a chunk feels large, split it. ARCADE's revision logic will also split chunks automatically when they fail repeatedly — but explicit splitting produces better sub-chunks.

**Worked example — a simple REST API:**

```markdown
## Pending
- [ ] [REASONING] Design the data model and API routes — document decisions in CONTEXT.md
- [ ] [SCAFFOLD] Generate project scaffold: directory structure, package.json, basic Express setup
- [ ] [SCAFFOLD] Generate all route handler stubs with JSDoc signatures
- [ ] [REASONING] Implement authentication middleware and write tests
- [ ] [REASONING] Code review pass — check for security issues and spec compliance
```

The first chunk is REASONING (design requires judgment). The next two are SCAFFOLD (mechanical generation). The last two are REASONING again (implementation and review require judgment).

**Dropping files and running init:**

```bash
mkdir -p projects/my-project
# place queue.md, CONTEXT.md, CLAUDE.md, issues.md in that directory
./masterarcade.sh --init --project my-project
./masterarcade.sh --project my-project
```

---

## First run

```bash
# Option 1: interactive setup
./setup.sh

# Option 2: manual
cp arcade.conf.example arcade.conf
# edit arcade.conf — set ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ARCADE_STATE_ROOT

mkdir -p projects/my-first-project
# write your four project files

./masterarcade.sh --init --project my-first-project
./masterarcade.sh --project my-first-project
```

---

## Queue format

```markdown
# Task queue — my-project
# Types: [REASONING] | [SCAFFOLD] | [OAUTH] (auto-classified if omitted)

## Pending
- [ ] [REASONING] Design the authentication architecture
- [ ] [SCAFFOLD] Generate boilerplate for all route handlers

## In Progress

## Complete
```

One chunk = one Claude Code session. Chunks without a type hint are auto-classified by
`lib/classify.sh` using keyword heuristics or a configured local model call.
