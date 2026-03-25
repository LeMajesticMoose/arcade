# ARCADE

ARCADE (Autonomous Reasoning and Coding Execution) is an orchestration layer that wraps Claude Code with chunk classification, feedback gating, cost control, and behavioral correction. It runs a structured autonomous development loop: classify the next task, launch a Claude Code session with the right model and cost tier, gate on a verifiable completion promise, revise or advance, and repeat until the queue is empty.

---

## Why it exists

Running Claude Code in a loop without structure burns tokens on debugging cycles, produces no observable cost data, and loses state between sessions. ARCADE solves four specific problems:

| Problem | Solution |
|---|---|
| Loops retry blindly on failure | Gate evaluates a promise token; on failure, a local model decides split / reduce / halt |
| No cost visibility | Every chunk logs cost, Calx activity, and a session summary to run-log.md |
| Wrong model for the task | Chunks are classified as REASONING or SCAFFOLD and routed to the appropriate tier automatically |
| Sessions drift from instructions | Calx injects behavioral rules at session start and guards against context collapse |

---

## Stack

| Component | Role |
|---|---|
| `masterarcade.sh` | Orchestrator — reads queue, classifies, launches, gates, revises, writes run-log |
| `start-arcade.sh` | Session launcher — selects model by mode, initializes Calx, calls `claude` |
| `lib/classify.sh` | Chunk classification via LiteLLM or keyword heuristics |
| `lib/gate.sh` | Promise token detection; GAUNTLET mode for gate stress-testing |
| `lib/revise.sh` | Calls Lumina to decide SPLIT / REDUCE / HALT on max iterations |
| `lib/cost_control.sh` | Balance check, budget halt, oauth watcher, Calx metrics, session summary |
| Calx (`getcalx`) | Correction engineering — rule injection, correction capture, context collapse guard |
| Claude Code | Reasoning anchor — receives task prompt, executes work, emits promise token |
| LiteLLM (optional) | Inference router with model alias map and spend logging |
| OpenHands (optional) | Execution agent for scaffolding tasks, routes to local Ollama |

---

## Chunk types

| Type | Mode | Gate behaviour |
|---|---|---|
| `REASONING` | `reasoning` or `oauth` | Normal — pass on promise token |
| `SCAFFOLD` | `scaffold` (Haiku) | Normal — pass on promise token |
| `OAUTH` | `oauth` (Claude Max) | Normal — pass on promise token |
| `GAUNTLET` | `reasoning` | Force-fail passes 1 and 2; pass 3 evaluated normally — for testing gate recovery |

Add type hints to `queue.md` for explicit control. Unlabelled chunks are auto-classified.

---

## Quick start

See [SETUP.md](SETUP.md) for full configuration including all three backend options
(LiteLLM, OpenRouter, Anthropic direct).

```bash
# 1. Configure
cp arcade.conf.example arcade.conf
# edit arcade.conf

# 2. Initialize a project
./masterarcade.sh --init --project my-project

# 3. Run the loop
./masterarcade.sh --project my-project

# Free tier (Claude Max subscription)
./masterarcade.sh --project my-project --mode oauth

# Lower cost (Haiku)
./masterarcade.sh --project my-project --mode scaffold
```

Other commands:

```bash
./masterarcade.sh --status                           # all projects
./masterarcade.sh --project my-project --status      # single project
./masterarcade.sh --project my-project --add-task "..." 
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
| `RESULT` | `DONE`, `REVISED` | `DONE` = gate passed; `REVISED` = max iterations hit |
| `cost` | `$X.XXXX` | Spend from LiteLLM spend log; `$0.0000` when not configured |
| `calx_active` | `yes`, `no` | Whether the Calx Stop hook fired (`.last_clean_exit` exists) |
| `calx_corrections` | integer | Lines in `corrections.jsonl`; 0 if none logged this session |
| `calx_rules` | comma-separated IDs | Rule IDs injected from `.calx/rules/` |

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

Calx is a correction engineering system for Claude Code (PyPI: `getcalx`). It is optional
— the loop works without it. When configured, it adds:

- **Rule injection**: domain rules are read from `.calx/rules/` and injected into every
  session via the `SessionStart` hook before any task work begins
- **Correction capture**: when you or the agent runs `calx correct "..."`, the correction
  is logged and tracked for recurrence; after 3 occurrences it can be promoted to a rule
- **Orientation gate**: blocks file edits until rules have been read (`PreToolUse` hook)
- **Collapse guard**: warns if a protected file would shrink by more than 20%
- **Session lifecycle**: `Stop` hook writes a clean-exit marker used by `cost_control.sh`
  to populate the `calx_active` field in the run-log

Calx integrates via Claude Code's native hooks in `.claude/settings.json`. `start-arcade.sh`
initializes `.calx/` automatically on first run in each project directory.

See [SETUP.md](SETUP.md) for installation and configuration. See the
[getcalx documentation](https://github.com/getcalx/oss) for the full correction engineering
workflow.

---

## License

MIT.
