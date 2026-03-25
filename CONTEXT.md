# ARCADE — Project Context

## What is ARCADE

ARCADE (Autonomous Reasoning and Coding Execution) is a structured AI-assisted development
methodology. It combines Claude Code, Calx, OpenHands, and LiteLLM into a near-zero-cost
autonomous development loop controlled by a single orchestration script: masterarcade.sh.

## Component Stack

| Component | Required | Role |
|-----------|----------|------|
| Claude Code CLI | **Required** | Reasoning engine — executes task chunks, emits completion promise |
| masterarcade.sh | **Required** | Orchestrator — queue, classification, launch, gate, revision |
| start-arcade.sh | **Required** | Session launcher — model selection, Calx init, claude exec |
| lib/classify.sh | **Required** | Chunk classification via configured backend or heuristics |
| lib/gate.sh | **Required** | Feedback gate — evaluates promise token, handles revision triggers |
| lib/revise.sh | **Required** | Revision logic — SPLIT / REDUCE / HALT decisions |
| lib/cost_control.sh | **Required** | Spend reporting, balance checks, session summary |
| Inference backend | **Required** (any one) | Claude Max (OAuth), OpenRouter, Anthropic direct, or LiteLLM proxy |
| Calx (`getcalx`) | Optional | Behavioral correction — rule injection, drift prevention |
| OpenHands (or equivalent) | Optional | Execution agent for SCAFFOLD tasks via local model |
| LiteLLM proxy | Optional | Inference router — model aliases, spend logging, local routing |
| GitHub integration | Optional | Remote state backup — pushes run-log and queue after each chunk |
| MCP server/hub | Optional | Agentic control — agents can init, run, and monitor projects via tools |
| Local inference (Ollama) | Optional | Zero-cost model tier for classification and scaffold execution |

## Three Launch Modes

| Mode | Routes To | Billing |
|------|-----------|---------|
| oauth | Claude Max subscription | Monthly subscription quota |
| reasoning | Configured backend → claude-sonnet | Per token |
| scaffold | Configured backend → cheaper/local model | Per token or $0 if local |

Launch modes can alternate between chunks within a single project. A `queue.md` can mix
REASONING, SCAFFOLD, and OAUTH chunks freely — masterarcade.sh selects the appropriate
mode per chunk automatically based on the chunk type tag. You do not commit to a single
mode for the life of a project or session. A common pattern: use OAUTH for the heavy
reasoning chunks at the start of a project and SCAFFOLD for the mechanical work, minimising
API spend without manual intervention.

## Why Calx Matters

Claude Code sessions drift. This is not a flaw — it is a natural consequence of how large
language models work across long sessions. Instructions given at session start lose weight
as the context grows. CLAUDE.md instructions get buried. A model that starts a session
carefully following constraints may, ten exchanges later, be improvising freely. For a
single interactive session this is manageable — a human catches it. For an autonomous loop
running unattended, it is a failure mode.

Calx addresses this at the session level. It runs as an observer via Claude Code's native
hook system, checking session behaviour against defined rules at each tool call. When a
rule fires — Claude ignoring a constraint, attempting a previously failed approach,
outputting a completion signal prematurely — Calx injects a correction before the next
exchange. The loop continues. The human does not need to intervene.

In ARCADE's architecture, Calx is the mechanism that makes unattended multi-chunk runs
viable. Without it, autonomous runs require monitoring. With it, the feedback gate and
Calx together handle the two most common failure modes: task scope failure (the gate) and
behavioural drift (Calx). Calx was developed by Spencer Hardwick — see
[github.com/getcalx/oss](https://github.com/getcalx/oss).

## Full Loop Flow (Single Iteration)

1. masterarcade.sh reads queue.md from the state directory
2. Checks issues.md — injects open issues as context prefix if any exist
3. Classifies chunk via configured backend or keyword heuristics → REASONING or SCAFFOLD
4. Resolves effective mode: SCAFFOLD → scaffold tier, OAUTH → oauth, else project default
5. For paid modes: checks backend balance; halts if below ARCADE_MIN_BALANCE_USD
6. Launches start-arcade.sh with appropriate mode and prompt
7. start-arcade.sh: cds to state dir, runs _calx_ensure (init + hook fetch), execs claude
8. **Calx SessionStart hook fires** — domain rules injected into session context
9. Claude Code reads CONTEXT.md and CLAUDE.md, executes the task chunk
10. **Calx PreToolUse hooks fire** on each Edit/Write call (orientation gate, collapse guard)
11. Claude Code outputs `<promise>ITERATION_COMPLETE</promise>` when done
12. **Calx Stop hook fires** — writes .last_clean_exit marker
13. masterarcade.sh feedback gate evaluates transcript:
    - Promise found → mark chunk done, log cost+Calx metrics, push to GitHub (if configured)
    - Max iterations hit → revision call → SPLIT / REDUCE / HALT → requeue or halt

## Repo Structure

```
arcade/
  masterarcade.sh         the orchestrator
  start-arcade.sh         session launcher
  arcade.conf.example     configuration template (copy to arcade.conf)
  lib/
    classify.sh           chunk classification
    revise.sh             chunk revision on gate failure
    gate.sh               feedback gate logic
    cost_control.sh       spend reporting, balance checks, Calx metrics
  projects/               prep files per project
    {project-name}/
      queue.md
      CONTEXT.md
      CLAUDE.md
      issues.md
  projects.json           project registry
```

## State Directory Structure

```
$ARCADE_STATE_ROOT/
  {project-name}/
    queue.md
    issues.md
    run-log.md
    CLAUDE.md
    CONTEXT.md
    .calx/              (Calx state — created on first run)
```

ARCADE_STATE_ROOT defaults to `~/.arcade/projects` and is set in `arcade.conf`.

## Feedback Gate Logic

```
Promise fulfilled    →  mark chunk DONE in queue.md
                        push run-log.md to GitHub state repo (if configured)
                        load next chunk

Max iterations hit  →  call revise.sh (fast local model or fallback heuristic)
                        decision:
                          SPLIT   → replace chunk with 2-3 smaller chunks, requeue
                          REDUCE  → scope-down chunk to minimal version, requeue
                          HALT    → write to issues.md, stop loop, surface to human
```

## Chunk Classification

Each chunk is classified before launch. The classifier tries a configured local model call
first and falls back to keyword heuristics if no model is available.

| Class | Definition |
|-------|------------|
| REASONING | Design decisions, architecture, debugging, code review, writing tests, analysis |
| SCAFFOLD | File creation, boilerplate, refactoring known patterns, builds, format conversion |

REASONING → oauth or configured reasoning model
SCAFFOLD → configured cheaper/local model or OpenHands

## Cost Architecture

- Reasoning chunks → most expensive; minimize with good task decomposition
- Scaffold chunks → cheaper or free (local model)
- Classification calls → free if local model configured; minimal API cost otherwise
- Revision calls → same as classification
- OpenHands execution tasks → zero cost (local model)

## Key Decisions

- State in ARCADE_STATE_ROOT, separate from this repo — survives machine rebuilds
- Loop state in separate arcade-{project} GitHub repo — never pollutes code repo
- Human merge gate for all infrastructure changes
- Public code outputs are human-reviewed before publish
