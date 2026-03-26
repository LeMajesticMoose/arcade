"""
ARCADE MCP Tools
Implements all 6 arcade tools plus arcade_get_balance.
Credentials are read from environment variables (loaded from mcp-server.conf by server.py).
"""

import os
import re
import json
import subprocess
import urllib.request
import urllib.error
from datetime import datetime, timezone


# ── environment helpers ───────────────────────────────────────────────────────

def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def _git_base() -> str:
    return _env("GIT_BASE_URL", "https://api.github.com")


def _git_headers() -> dict:
    token = _env("GIT_TOKEN")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "arcade-mcp/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def _state_root() -> str:
    return _env("ARCADE_STATE_ROOT", os.path.expanduser("~/.arcade/projects"))


def _arcade_root() -> str:
    # Try to find masterarcade.sh relative to this file, or from env
    here = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.join(here, "..", "masterarcade.sh")
    if os.path.exists(candidate):
        return os.path.normpath(os.path.join(here, ".."))
    return _env("ARCADE_ROOT", os.path.expanduser("~/arcade"))


def _http_get(url: str, headers: dict | None = None) -> tuple[int, dict | str]:
    """Return (status_code, parsed_json_or_text)."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode()
            try:
                return resp.status, json.loads(body)
            except json.JSONDecodeError:
                return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, body
    except Exception as exc:
        return 0, str(exc)


# ── tool implementations ──────────────────────────────────────────────────────

def _arcade_init_project(project: str, mode: str = "reasoning") -> dict:
    """
    Create a new ARCADE project: state directory, placeholder files, and
    optionally GitHub repos.
    """
    state_root = _state_root()
    project_dir = os.path.join(state_root, project)

    if os.path.exists(project_dir):
        return {"status": "exists", "state_dir": project_dir,
                "message": f"Project '{project}' already exists at {project_dir}"}

    os.makedirs(project_dir, exist_ok=True)

    # Write scaffold files
    scaffolds = {
        "queue.md": f"# Task Queue — {project}\n## Pending\n\n## In Progress\n\n## Complete\n",
        "issues.md": f"# Issues — {project}\n## Open\n\n## Resolved\n",
        "run-log.md": f"# Run Log — {project}\n# Format: [YYYY-MM-DD HH:MM] CHUNK N | MODE m | RESULT s | cost=$X.XXXX\n",
        "CONTEXT.md": f"# Project Context — {project}\n\n## What this project is\n\n## Key decisions\n\n## Constraints\n",
        "CLAUDE.md": (
            f"# Claude Code Instructions — {project}\n\n"
            "## Session behavior\n"
            "- Output `<promise>ITERATION_COMPLETE</promise>` only when the chunk is fully done\n"
            "- Read CONTEXT.md at session start\n"
            "- Check issues.md before starting\n\n"
            "## Do not\n"
            "- Modify queue.md\n"
            "- Mark issues.md entries as resolved\n"
            "- Output the promise unless the task is genuinely complete\n"
        ),
    }

    for filename, content in scaffolds.items():
        with open(os.path.join(project_dir, filename), "w") as f:
            f.write(content)

    # Attempt GitHub repo creation if configured
    git_org = _env("GIT_ORG")
    git_base = _git_base()
    git_token = _env("GIT_TOKEN")
    git_repo_url = None

    if git_org and git_token:
        create_url = f"{git_base}/orgs/{git_org}/repos"
        payload = json.dumps({"name": f"arcade-{project}", "private": True,
                               "description": f"ARCADE loop state: {project}"}).encode()
        req = urllib.request.Request(
            create_url,
            data=payload,
            headers={**_git_headers(), "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
                git_repo_url = data.get("html_url")
        except Exception:
            pass  # non-fatal

    return {
        "status": "created",
        "project": project,
        "state_dir": project_dir,
        "mode": mode,
        "git_repo": git_repo_url or "not configured",
        "files_created": list(scaffolds.keys()),
    }


def _arcade_start_project(project: str, mode: str = "reasoning") -> dict:
    """Launch an ARCADE loop session in tmux."""
    arcade_root = _arcade_root()
    script = os.path.join(arcade_root, "masterarcade.sh")

    if not os.path.exists(script):
        return {"status": "error", "message": f"masterarcade.sh not found at {script}"}

    session_name = f"arcade-{project}"
    cmd = (
        f"tmux new-session -d -s {session_name} "
        f"'cd {arcade_root} && ./masterarcade.sh --project {project} --mode {mode}'"
    )
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

    if result.returncode == 0:
        return {"status": "launched", "session": session_name,
                "message": f"Started in tmux session '{session_name}'"}
    else:
        # tmux may already have a session with this name
        if "duplicate session" in (result.stderr or "").lower():
            return {"status": "already_running", "session": session_name,
                    "message": f"Session '{session_name}' is already running"}
        return {"status": "error", "message": result.stderr or result.stdout}


def _arcade_get_status(project: str) -> dict:
    """Return current chunk, last exit, and open issue count for a project."""
    state_dir = os.path.join(_state_root(), project)

    if not os.path.isdir(state_dir):
        return {"status": "not_found", "project": project,
                "message": f"No state directory at {state_dir}"}

    # Queue analysis
    queue_file = os.path.join(state_dir, "queue.md")
    pending, done = 0, 0
    next_chunk = None

    if os.path.exists(queue_file):
        with open(queue_file) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("- [ ]"):
                    pending += 1
                    if next_chunk is None:
                        next_chunk = stripped[5:].strip()
                elif stripped.startswith("- [x]"):
                    done += 1

    # Issues
    issues_file = os.path.join(state_dir, "issues.md")
    open_issues = 0
    if os.path.exists(issues_file):
        with open(issues_file) as f:
            open_issues = sum(1 for l in f if l.strip().startswith("- [ ]"))

    # Last run-log entry
    run_log_file = os.path.join(state_dir, "run-log.md")
    last_entry = None
    if os.path.exists(run_log_file):
        with open(run_log_file) as f:
            lines = [l.strip() for l in f if re.match(r"^\[\d{4}-", l.strip())]
        if lines:
            last_entry = lines[-1]

    return {
        "project": project,
        "state_dir": state_dir,
        "queue": {"pending": pending, "done": done, "next_chunk": next_chunk},
        "open_issues": open_issues,
        "last_run_log_entry": last_entry,
    }


def _arcade_list_projects() -> dict:
    """List all registered ARCADE projects."""
    state_root = _state_root()
    projects = []

    if not os.path.isdir(state_root):
        return {"projects": [], "state_root": state_root}

    for name in sorted(os.listdir(state_root)):
        project_dir = os.path.join(state_root, name)
        if not os.path.isdir(project_dir):
            continue
        status = _arcade_get_status(name)
        projects.append({
            "name": name,
            "pending": status.get("queue", {}).get("pending", 0),
            "done": status.get("queue", {}).get("done", 0),
            "open_issues": status.get("open_issues", 0),
            "last_entry": status.get("last_run_log_entry"),
        })

    return {"projects": projects, "count": len(projects), "state_root": state_root}


def _arcade_add_task(project: str, task: str) -> dict:
    """Append a task chunk to a project's queue.md."""
    state_dir = os.path.join(_state_root(), project)
    queue_file = os.path.join(state_dir, "queue.md")

    if not os.path.exists(queue_file):
        return {"status": "error", "message": f"queue.md not found at {queue_file}"}

    with open(queue_file, "r") as f:
        content = f.read()

    task_line = f"- [ ] {task}\n"

    # Insert after ## Pending if it exists, otherwise append
    if "## Pending" in content:
        content = content.replace("## Pending\n", f"## Pending\n{task_line}", 1)
    else:
        content += f"\n{task_line}"

    with open(queue_file, "w") as f:
        f.write(content)

    return {"status": "added", "task": task, "project": project, "queue_file": queue_file}


def _arcade_get_cost(project: str, scope: str = "last_run") -> dict:
    """
    Return cost data from run-log.md.
    scope: "last_run" | "session" | "all_time"
    """
    state_dir = os.path.join(_state_root(), project)
    run_log_file = os.path.join(state_dir, "run-log.md")

    if not os.path.exists(run_log_file):
        return {"project": project, "scope": scope, "total_cost": "$0.0000",
                "chunks": 0, "note": "run-log.md not found"}

    with open(run_log_file) as f:
        lines = [l.strip() for l in f if re.match(r"^\[\d{4}-", l.strip())]

    total = 0.0
    partial = False
    chunks = 0

    for line in lines:
        m = re.search(r"cost=\$([0-9]+\.[0-9]+)", line)
        if m:
            total += float(m.group(1))
            chunks += 1
        elif "cost=" in line:
            partial = True

    result = {
        "project": project,
        "scope": scope,
        "total_cost": f"${total:.4f}",
        "chunks": chunks,
    }
    if partial:
        result["note"] = "some chunks have no cost data (partial)"
    return result


def _arcade_get_balance() -> dict:
    """
    Return inference provider balance or usage estimate.
    Handles OpenRouter, Anthropic, OpenAI, Ollama, and custom endpoints.
    """
    provider = _env("INFERENCE_PROVIDER", "openrouter").lower()
    api_key = _env("INFERENCE_API_KEY")
    base_url = _env("INFERENCE_BASE_URL")

    if provider == "openrouter":
        if not api_key:
            return {"provider": "openrouter", "status": "no_key",
                    "message": "INFERENCE_API_KEY not set in mcp-server.conf"}
        status, data = _http_get(
            "https://openrouter.ai/api/v1/auth/key",
            headers={"Authorization": f"Bearer {api_key}"}
        )
        if status == 200 and isinstance(data, dict):
            info = data.get("data", {})
            return {
                "provider": "openrouter",
                "status": "ok",
                "limit": info.get("limit"),
                "limit_remaining": info.get("limit_remaining"),
                "usage": info.get("usage"),
                "is_free_tier": info.get("is_free_tier", False),
            }
        return {"provider": "openrouter", "status": "error",
                "http_status": status, "message": str(data)[:200]}

    elif provider == "anthropic":
        return {
            "provider": "anthropic",
            "status": "not_available",
            "message": (
                "Anthropic does not expose an account balance via API. "
                "Check your usage at https://console.anthropic.com/settings/billing"
            ),
        }

    elif provider == "openai":
        if not api_key:
            return {"provider": "openai", "status": "no_key",
                    "message": "INFERENCE_API_KEY not set in mcp-server.conf"}
        # OpenAI credit balance is not available via API — use models endpoint to verify key
        status, data = _http_get(
            "https://api.openai.com/v1/models",
            headers={"Authorization": f"Bearer {api_key}"}
        )
        if status == 200:
            return {
                "provider": "openai",
                "status": "key_valid",
                "message": (
                    "OpenAI credit balance is not available via API. "
                    "Check https://platform.openai.com/usage"
                ),
            }
        return {"provider": "openai", "status": "error",
                "http_status": status, "message": str(data)[:200]}

    elif provider == "ollama":
        ollama_url = base_url or "http://localhost:11434"
        status, data = _http_get(f"{ollama_url}/api/tags")
        if status == 200:
            models = [m.get("name", "?") for m in (data.get("models", []) if isinstance(data, dict) else [])]
            return {
                "provider": "ollama",
                "status": "reachable",
                "models": models[:10],
                "note": "Ollama has no balance API — cost tracking uses run-log.md estimates only",
            }
        return {"provider": "ollama", "status": "unreachable",
                "url": ollama_url, "message": str(data)[:200]}

    else:
        # Custom provider
        if not base_url:
            return {"provider": "custom", "status": "no_url",
                    "message": "INFERENCE_BASE_URL not set in mcp-server.conf"}
        status, data = _http_get(
            f"{base_url}/balance",
            headers={"Authorization": f"Bearer {api_key}"} if api_key else {}
        )
        if status == 200:
            return {"provider": "custom", "status": "ok", "data": data}
        elif status == 404:
            return {
                "provider": "custom",
                "status": "no_balance_endpoint",
                "message": (
                    f"{base_url}/balance returned 404. "
                    "This provider does not expose a balance API. "
                    "Cost tracking uses run-log.md estimates only."
                ),
            }
        return {"provider": "custom", "status": "error",
                "http_status": status, "message": str(data)[:200]}


# ── registration ──────────────────────────────────────────────────────────────

def register_arcade_tools(mcp) -> None:
    """Register all ARCADE tools with a FastMCP instance."""

    @mcp.tool()
    def arcade_init_project(project: str, mode: str = "reasoning") -> dict:
        """
        Initialize a new ARCADE project.
        Creates the state directory, scaffold files (queue.md, CONTEXT.md, CLAUDE.md,
        issues.md, run-log.md), and optionally a GitHub state repo.
        Returns the state directory path and list of files created.
        """
        return _arcade_init_project(project, mode)

    @mcp.tool()
    def arcade_start_project(project: str, mode: str = "reasoning") -> dict:
        """
        Launch an ARCADE loop session for the given project.
        Starts masterarcade.sh in a detached tmux session.
        mode: reasoning | scaffold | oauth
        Returns the tmux session name and launch status.
        """
        return _arcade_start_project(project, mode)

    @mcp.tool()
    def arcade_get_status(project: str) -> dict:
        """
        Get current status of an ARCADE project.
        Returns queue counts (pending/done), next chunk text, open issue count,
        and the most recent run-log entry.
        """
        return _arcade_get_status(project)

    @mcp.tool()
    def arcade_list_projects() -> dict:
        """
        List all ARCADE projects in ARCADE_STATE_ROOT.
        Returns project names, queue counts, and open issue counts.
        """
        return _arcade_list_projects()

    @mcp.tool()
    def arcade_add_task(project: str, task: str) -> dict:
        """
        Append a task chunk to a project's queue.md.
        The task string should include a type hint: [REASONING], [SCAFFOLD], or [OAUTH].
        Example: "[REASONING] Design the authentication architecture"
        """
        return _arcade_add_task(project, task)

    @mcp.tool()
    def arcade_get_cost(project: str, scope: str = "last_run") -> dict:
        """
        Get cost data for an ARCADE project from its run-log.md.
        scope: "last_run" (default), "session", or "all_time"
        Returns total spend and chunk count. Cost is $0.0000 when LiteLLM is not configured.
        """
        return _arcade_get_cost(project, scope)

    @mcp.tool()
    def arcade_get_balance() -> dict:
        """
        Get inference provider balance or usage information.
        Reads INFERENCE_PROVIDER from mcp-server.conf.
        Supports: openrouter, anthropic, openai, ollama, custom.
        Returns balance, remaining credit, or an explanation if the provider
        does not expose a balance API.
        """
        return _arcade_get_balance()
