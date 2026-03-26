# Task Queue — example-project
# One chunk = one Claude Code session = one loop run.
# Types: [REASONING] | [SCAFFOLD] | [OAUTH] (auto-classified if omitted)
# Keep each chunk completable in a single session.

## Pending

# REASONING: tasks requiring judgment — architecture, debugging, code review, tests.
# Routes to Claude via API key or OAuth subscription.
- [ ] [REASONING] Design the data model and API structure — document decisions in CONTEXT.md

# SCAFFOLD: mechanical tasks — file generation, boilerplate, builds, format conversion.
# Routes to a cheaper or local model automatically.
- [ ] [SCAFFOLD] Generate project scaffold: directory structure, package.json, route stubs

# OAUTH: same class as REASONING but billed to your Claude Max subscription
# rather than per-token API charges. Use for heavy sessions.
- [ ] [OAUTH] Implement authentication middleware and write integration tests

## In Progress

## Complete
