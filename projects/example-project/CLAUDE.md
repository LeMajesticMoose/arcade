# Claude Code Instructions — example-project

## Session behavior
- Output `<promise>ITERATION_COMPLETE</promise>` only when the current chunk
  is fully done and all acceptance criteria are met
- Read CONTEXT.md at session start — do this before writing any code
- Check issues.md before starting — address any open issues first
- For scaffolding tasks (file gen, boilerplate, builds), use OpenHands via
  openhands_run_task MCP tool if available

## Commit style
- Conventional commits: feat / fix / chore / docs / refactor
- Reference the task chunk from queue.md in the commit message
- Example: `feat(api): implement user authentication middleware`

## Promise rules
- Do not output the promise string unless the task is genuinely complete
- Do not output the promise string if tests are failing
- Do not output the promise string if files are missing that the chunk requires

## Do not
- Modify queue.md — masterarcade.sh manages queue state
- Mark issues.md entries as resolved — gate logic handles that
- Create files outside the project directory
- Install global npm packages without checking with the user first
