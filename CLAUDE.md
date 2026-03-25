# Claude Code Instructions — ARCADE

## Project Identity

ARCADE (Autonomous Reasoning and Coding Execution) is a structured AI-assisted development
methodology. This repo contains the orchestration layer: masterarcade.sh and all supporting
lib/ scripts.

## Loop Behavior

- Output `<promise>ITERATION_COMPLETE</promise>` only when the current task chunk is fully
  done and all acceptance criteria are met
- For scaffolding tasks (file gen, boilerplate, builds, format conversion), delegate to
  OpenHands via the openhands_run_task MCP tool if available
- Read CONTEXT.md at session start for full architecture context
- Check issues.md before starting any task — address open issues first
- Never modify queue.md — masterarcade.sh manages queue state
- Never mark issues.md entries resolved — gate logic handles that

## Commit Style

- Conventional commits: feat / fix / chore / docs / refactor
- Reference task chunk from queue.md in commit message
- Example: `feat(masterarcade): implement --init flag with dual repo creation`

## File Locations

- Orchestrator: arcade/masterarcade.sh
- Lib scripts: arcade/lib/
- Projects registry: arcade/projects.json
- State (per project): $ARCADE_STATE_ROOT/{project-name}/
- Queue: $ARCADE_STATE_ROOT/{project-name}/queue.md
- Issues: $ARCADE_STATE_ROOT/{project-name}/issues.md
- Run log: $ARCADE_STATE_ROOT/{project-name}/run-log.md
- Context: $ARCADE_STATE_ROOT/{project-name}/CONTEXT.md

## Configuration

All infrastructure endpoints and credentials are read from arcade.conf at the repo root.
See arcade.conf.example for the full list of variables.

## Model Routing

| Mode | Model tag | Notes |
|------|-----------|-------|
| oauth | claude-sonnet (Claude Max subscription) | subscription billing |
| reasoning | claude-sonnet via configured backend | pay-per-token |
| scaffold | claude-haiku via configured backend | lower cost |
| agent-lite | local model via LiteLLM | $0 if configured |

## GitHub Push Pattern

If GITHUB_URL, GITHUB_TOKEN, and GITHUB_ORG are configured in arcade.conf, the loop
automatically pushes run-log.md and queue.md updates to the state repo after each chunk.
If GitHub is not configured, state is managed locally only.

## Do Not

- Store credentials in any script or file (use arcade.conf, which is gitignored)
- Merge PRs without human review
- Modify queue.md or issues.md directly
- Output the promise string unless the task is genuinely complete
