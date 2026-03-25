# ARCADE — Project Context

## What is ARCADE

ARCADE (Autonomous Reasoning and Coding Execution) is a structured AI-assisted development
methodology. It combines Claude Code, Calx, OpenHands, and LiteLLM into a near-zero-cost
autonomous development loop controlled by a single orchestration script: masterarcade.sh.

## Component Stack

| Component | Role |
|-----------|------|
| Claude Code CLI | Reasoning anchor, loop session host |
| Calx / getcalx | Behavioral feedback — injects domain rules, captures corrections |
| OpenHands | Execution agent — scaffolding, file gen, builds via local model |
| LiteLLM Proxy | Unified inference router with model alias map (optional) |
| masterarcade.sh | Orchestrator — the one tool that runs everything |

## Three Launch Modes

| Mode | Routes To | Cost |
|------|-----------|------|
| oauth | Native Claude Max subscription | $0 |
| reasoning | Configured backend (LiteLLM or OpenRouter) → claude-sonnet | pay-per-token |
| scaffold | Configured backend → claude-haiku | lower cost |

Execution work delegated to OpenHands routes to a local Ollama model — zero cost.

## Full Loop Flow (Single Iteration)

1. masterarcade.sh reads queue.md from the state directory
2. Checks issues.md — injects open issues as context prefix
3. Classifies chunk via Lumina (local model, $0) → REASONING or SCAFFOLD
4. Launches start-arcade.sh with appropriate mode
5. Claude Code session starts — Calx hooks activate (SessionStart, PreToolUse, Stop)
6. Claude Code reads CONTEXT.md and CLAUDE.md at session start
7. Claude Code executes the task chunk
8. For execution subtasks: calls openhands_run_task MCP tool if available
9. Calx orientation gate and collapse guard fire on file edits
10. Claude Code outputs `<promise>ITERATION_COMPLETE</promise>` when done
11. masterarcade.sh feedback gate evaluates exit:
    - Promise fulfilled → mark chunk done, update run-log.md, next chunk
    - Max iterations hit → revision call (Lumina) → split/reduce chunk → requeue

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

ARCADE_STATE_ROOT defaults to `~/.arcade/projects` and is set in arcade.conf.

## Feedback Gate Logic

```
Promise fulfilled    →  mark chunk DONE in queue.md
                        push run-log.md to Gitea state repo (if configured)
                        load next chunk

Max iterations hit  →  call revise.sh (Lumina, free)
                        decision:
                          SPLIT   → replace chunk with 2-3 smaller chunks, requeue
                          REDUCE  → scope-down chunk to minimal version, requeue
                          HALT    → write to issues.md, stop loop, surface to human
```

## Chunk Classification

Each chunk classified before launch via a single Lumina call. Binary and deterministic:

| Class | Definition |
|-------|------------|
| REASONING | Design decisions, architecture, debugging, code review, writing tests, analysis |
| SCAFFOLD | File creation, boilerplate, refactoring known patterns, builds, format conversion |

REASONING → oauth or configured reasoning model
SCAFFOLD → claude-haiku or OpenHands directly

## Cost Architecture

- Reasoning (Claude Code) → expensive, minimize with good chunking
- Execution (OpenHands → local model) → $0, use liberally
- Classification (Lumina) → $0, run before every chunk
- Revision (Lumina) → $0, only on gate failure

## Key Decisions

- State in ARCADE_STATE_ROOT, separate from this repo — survives machine rebuilds
- Loop state in separate arcade-{project} Gitea repo — never pollutes code repo
- Human merge gate for all infrastructure changes
- GitHub publish is human-gated — public outputs only after review
