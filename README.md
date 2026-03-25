# ARCADE

ARCADE (Autonomous Reasoning and Coding Execution) is an orchestration layer that wraps Claude Code with structured task classification, verifiable feedback gates, cost control, and behavioral correction. It runs a structured autonomous development loop: classify the next task, launch a Claude Code session with the right model and cost tier, evaluate a completion promise, revise or advance, and repeat until the queue is empty.

ARCADE runs in a VS Code integrated terminal, any Linux/Unix command line, or a remote code-server instance. Windows is supported via WSL2. No GUI required.

---

## Deployment tiers

ARCADE scales from a single laptop to a distributed multi-node setup. Each tier is a superset of the previous.

**Simple** — Single machine, API backend (OpenRouter or Anthropic direct), no local inference. Lowest setup friction. Suitable for solo developers. Configure `arcade.conf` with an API key and run.

**Standard** — Single machine with a LiteLLM proxy, mixing local model calls with API calls. SCAFFOLD chunks route to local models at zero token cost. Reduces API spend significantly on projects with a high proportion of mechanical tasks.

**Distributed** — Multi-node setup: dedicated inference hardware, a FastMCP hub for tool access, and agentic control via IronClaw or any MCP-capable agent. ARCADE becomes a managed service that agents can initiate, monitor, and steer. In this configuration, a human rarely interacts with ARCADE directly — the agent manages project state and loop execution.

ARCADE is designed to be initiated and monitored by agentic orchestration systems (IronClaw, Claude Code itself via MCP tools, or any MCP-capable agent) in addition to direct human use.

---

## Built on

ARCADE generalises and automates the **Ralph Loop** — a structured iterative development loop methodology developed as a precursor to ARCADE, where each session unit is defined by a verifiable completion criterion rather than elapsed time or token count.

The behavioral correction layer is provided by **Calx**, developed by Spencer Hardwick. Calx observes Claude Code sessions and fires corrections when defined behavioral rules are triggered — keeping sessions on-spec across long autonomous runs. Source: [github.com/getcalx/oss](https://github.com/getcalx/oss) · PyPI: [getcalx](https://pypi.org/project/getcalx/)

The reasoning engine is **Claude Code CLI**, Anthropic's agentic coding tool.

Agent control in distributed deployments uses **MCP (Model Context Protocol)**, the tool interface standard that allows agents to initiate and steer ARCADE without direct filesystem access.

---

## Why it exists

Running Claude Code in a loop without structure burns tokens on debugging cycles, produces no observable cost data, and loses state between sessions. ARCADE solves four specific problems:

| Problem | Solution |
|---|---|
| Loops retry blindly on failure | Gate evaluates a promise token; on failure, a local model decides split / reduce / halt |
| No cost visibility | Every chunk logs cost, Calx activity, and a session summary to run-log.md |
| Wrong model for the task | Chunks are classified as REASONING or SCAFFOLD and routed to the appropriate tier automatically |
| Sessions drift from instructions | Calx injects behavioral rules at session start and corrects drift mid-session |

---

## Stack

| Component | Role |
|---|---|
| `masterarcade.sh` | Orchestrator — reads queue, classifies, launches, gates, revises, writes run-log |
| `start-arcade.sh` | Session launcher — selects model by mode, initializes Calx, calls `claude` |
| `lib/classify.sh` | Chunk classification via configured backend or keyword heuristics |
| `lib/gate.sh` | Promise token detection and gate evaluation |
| `lib/revise.sh` | Calls a fast local model to decide SPLIT / REDUCE / HALT on max iterations |
| `lib/cost_control.sh` | Balance check, budget halt, oauth watcher, Calx metrics, session summary |
| Calx (`getcalx`) | Behavioral correction — rule injection, correction capture, context collapse guard |
| Claude Code | Reasoning engine — receives task prompt, executes work, emits promise token |
| LiteLLM (optional) | Inference router with model alias map and spend logging |
| OpenHands (optional) | Execution agent for scaffolding tasks; routes to local inference |

---

## Chunk types

Chunks are the unit of work in ARCADE — one chunk equals one Claude Code session equals one loop run. Each chunk carries a type tag that determines which inference tier handles it.

**REASONING** — Tasks requiring judgment: architecture decisions, debugging, code review, writing tests, analysis, anything where the right answer is not obvious from the task description. Routes to Claude via API or OAuth subscription. This is the default type — unlabelled chunks are classified as REASONING if no scaffold keywords match.

**SCAFFOLD** — Mechanical tasks: file generation, boilerplate, format conversion, dependency installation, running builds. Routes to a cheaper or local model automatically. Lower cost, faster turnaround. A common pattern is to follow a REASONING chunk that designs something with a SCAFFOLD chunk that generates it.

**OAUTH** — Same task classification as REASONING. The difference is billing: OAUTH explicitly routes through a Claude Max subscription rather than API tokens. Use when you have an active Claude Max subscription and want subscription billing for this chunk instead of per-token API charges.

---

> **REASONING vs OAUTH:** Both handle the same class of tasks. The difference is how you pay. REASONING routes through your API key and charges per token. OAUTH routes through a Claude Max subscription — billing comes from your monthly subscription fee rather than per-token API charges. Claude Max is a paid subscription tier; "OAuth" refers to the authentication method, not a free tier. For heavy development sessions with many reasoning chunks, OAUTH is typically more economical. For occasional or light use, API billing (REASONING) may cost less overall. Choose based on your usage pattern.

---

Add type hints to `queue.md` for explicit control. Unlabelled chunks are auto-classified:

```markdown
- [ ] [REASONING] Design the authentication architecture
- [ ] [SCAFFOLD] Generate boilerplate for all route handlers
- [ ] [OAUTH] Heavy refactoring session — use subscription billing
```

---

## Quick start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/LeMajesticMoose/arcade/main/setup.sh)"
```

The setup script checks your environment, clones ARCADE, walks through backend configuration, optionally installs Calx, and runs a smoketest. Requires `bash`, `git`, `curl`, and `python3`.

**Manual setup** (if you prefer to configure by hand):

```bash
git clone https://github.com/LeMajesticMoose/arcade ~/arcade
cd ~/arcade
cp arcade.conf.example arcade.conf
# edit arcade.conf — set ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ARCADE_STATE_ROOT
```

See [SETUP.md](SETUP.md) for full configuration details and all four backend options.

**Running the loop:**

```bash
cd ~/arcade
./masterarcade.sh --init --project my-project
./masterarcade.sh --project my-project

# Claude Max subscription billing
./masterarcade.sh --project my-project --mode oauth

# Cheaper model tier for scaffold-heavy projects
./masterarcade.sh --project my-project --mode scaffold
```

Other commands:

```bash
./masterarcade.sh --status
./masterarcade.sh --project my-project --status
./masterarcade.sh --project my-project --add-task "Implement signal routing"
./masterarcade.sh --project my-project --resume
```

---

## Run-log format

Each chunk appends one structured line to `run-log.md`:

```
[YYYY-MM-DD HH:MM] CHUNK N | MODE m | RESULT s | cost=$X.XXXX | calx_active=yes|no | calx_corrections=N | calx_rules=id1,id2
```

| Field | Values | Meaning |
|---|---|---|
| `RESULT` | `DONE`, `REVISED` | `DONE` = gate passed; `REVISED` = max iterations hit, revision called |
| `cost` | `$X.XXXX` | Spend from LiteLLM spend log; `$0.0000` when LiteLLM is not configured |
| `calx_active` | `yes`, `no` | Whether the Calx Stop hook fired for this session |
| `calx_corrections` | integer | Corrections logged during the session; 0 if none |
| `calx_rules` | comma-separated IDs | Rule IDs active in `.calx/rules/` at session start |

After all chunks complete, a session summary block is appended:

```
## Session Summary — YYYY-MM-DD
Chunks run: N | Passed: N | Revised: N | Halted: N
Total cost: $X.XX
Calx active chunks: N of N
Calx corrections fired: N
Most active rule: rule-id
```

---

## Calx integration

Calx is a correction engineering system for Claude Code, developed by Spencer Hardwick. Source: [github.com/getcalx/oss](https://github.com/getcalx/oss) · PyPI: [getcalx](https://pypi.org/project/getcalx/)

**What it does.** Calx observes Claude Code sessions and fires behavioral corrections when defined rules are triggered. It runs as an ambient layer via Claude Code's native hook system — not a wrapper or separate process. You define rules (or Calx promotes corrections to rules after enough recurrences), and those rules are injected into every session before any task work begins.

**Why it matters for ARCADE.** Without behavioral correction, Claude Code sessions drift. Claude may ignore CLAUDE.md instructions after several exchanges, attempt the same failing approach multiple times, or output the completion promise before the task is genuinely done. Calx enforces behavioral boundaries at the session level. This is the difference between a loop that self-corrects and one that requires human intervention every few chunks. In long autonomous runs — especially under agentic control where no human is watching — Calx is what keeps sessions on-spec.

**How it integrates.** `start-arcade.sh` registers four hooks in `.claude/settings.json` per project directory: a `SessionStart` hook that injects domain rules, two `PreToolUse` hooks (orientation gate and collapse guard), and a `Stop` hook that logs clean session exit. Claude Code fires these automatically.

**Packaging note.** Calx v0.3.0 has a known packaging bug: hook scripts are missing from the wheel. `start-arcade.sh` fetches them from the GitHub source automatically on first use. After the first run per project directory, no further fetching occurs.

**Optional.** The loop works without Calx. If `CALX_VENV` is unset or the binary is not found, ARCADE skips Calx silently. See [SETUP.md](SETUP.md) for installation.

---

## Dependencies & Attribution

| Dependency | Author | License | Link |
|---|---|---|---|
| Calx (`getcalx`) | Spencer Hardwick | MIT | [github.com/getcalx/oss](https://github.com/getcalx/oss) |
| Calx hook scripts | Spencer Hardwick | MIT | [github.com/getcalx/oss](https://github.com/getcalx/oss) |
| Claude Code CLI | Anthropic | Anthropic Terms of Service | [docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code) |

ARCADE's MIT license does not cover these dependencies. Users are responsible for reviewing and complying with each dependency's license and terms of service independently.

---

## License

MIT.
