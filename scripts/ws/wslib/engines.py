"""The engines a queued job runs on: Claude Code and Codex, behind one interface.

Each engine builds its own command line from a backend-neutral Confinement (the copy it may
write, network on or off, the repository's extra commands, the job's rules), reads its own
output into an Outcome (ok, transient, usage_limit, auth, error) with the structured report,
and says whether it can run here (installed, logged in). `select` picks, per attempt, the
first engine the repository allows that is available and not cooling down after a usage
limit; a repository's code never goes to an engine it doesn't list.

What each enforces differs, and `enforces` says so: Claude Code has a per-command allowlist
and its own sandbox; Codex has only its sandbox (workspace-write, network off), so its
commands are confined by that and by ws-agent's job sandbox around both.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import time
from collections.abc import Collection, Iterator, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from . import agent_registry, agent_sandbox, core, jobs

STATUSES = ("done", "question", "blocked", "failed")
# Every property is required (OpenAI's strict structured outputs insist); the optional ones are
# nullable instead.
REPORT_SCHEMA: dict[str, object] = {
    "type": "object", "additionalProperties": False,
    "required": ["status", "summary", "question", "tests", "notes"],
    "properties": {
        "status": {"type": "string", "enum": list(STATUSES)},
        "summary": {"type": "string"},
        "question": {"type": ["string", "null"]},
        "tests": {"type": ["string", "null"]},
        "notes": {"type": ["string", "null"]},
    },
}

REVIEW_SCHEMA: dict[str, object] = {
    "type": "object", "additionalProperties": False,
    "required": ["verdict", "summary", "findings"],
    "properties": {
        "verdict": {"type": "string", "enum": ["ok", "concerns"]},
        "summary": {"type": "string"},
        "findings": {"type": "array", "items": {
            "type": "object", "additionalProperties": False, "required": ["file", "line", "issue"],
            "properties": {"file": {"type": "string"}, "line": {"type": ["integer", "null"]},
                           "issue": {"type": "string"}}}},
    },
}
READ_TOOLS = ("Read", "Glob", "Grep")

# No bare Edit/Write: acceptEdits allows edits inside the copy, and a tool-wide rule would also
# allow them outside it (blockWritesOutsideWorkingDirectories blocks those writes outright too).
CLAUDE_TOOLS = ("Read", "Glob", "Grep", "Bash(svn *)", "Bash(git *)", "Bash(rg *)", "Bash(fd *)",
                "Bash(ls *)", "Bash(cat *)", "Bash(head *)", "Bash(tail *)", "Bash(wc *)", "Bash(diff *)",
                "Bash(python3 -m unittest*)")

# Failure signatures, measured or documented; one line each so a newly seen shape is a one-line change.
CLAUDE_AUTH = re.compile(r"(?i)invalid api key|/login|oauth token (has )?expired|authentication_error|not logged in")
CLAUDE_USAGE = re.compile(r"(?i)usage limit|\b\d+-hour limit|weekly limit|limit reached.*reset|out of (extra )?usage")
CLAUDE_TRANSIENT = re.compile(r"(?i)api error: (5\d\d|429|408)|overloaded|request timed out|connection error|"
                              r"econnreset|socket hang up|fetch failed|network error")
CODEX_AUTH = re.compile(r"(?i)unauthorized|not logged in|please (log|sign) in|invalid api key|token (has )?expired")
CODEX_USAGE = re.compile(r"(?i)usage limit|hit your (usage )?limit|insufficient_quota|usage_limit_reached|quota")
CODEX_TRANSIENT = re.compile(r"(?i)stream (error|disconnected)|timed? ?out|connection|overloaded|reconnect|"
                             r"temporar|rate limit|server error")
AUTH_STATUS = {401, 403}
TRANSIENT_STATUS = {408, 409, 429, 500, 502, 503, 504, 529}


@dataclass(frozen=True)
class Confinement:
    wc: Path
    network: bool
    commands: tuple[str, ...]
    instructions: str
    read_dirs: tuple[Path, ...] = ()
    read_only: bool = False                         # a review: reads only, changes nothing
    schema: Mapping[str, object] = field(default_factory=lambda: REPORT_SCHEMA)


@dataclass
class Outcome:
    kind: str                       # ok | transient | usage_limit | auth | error
    report: dict[str, object] | None
    session_id: str
    turns: int | None = None
    duration_ms: int | None = None
    cost_usd: float | None = None
    reset_at: str = ""
    message: str = ""


class Engine(Protocol):
    name: str
    enforces: frozenset[str]

    def ro_paths(self) -> list[Path]: ...
    def rw_paths(self) -> list[Path]: ...
    def available(self) -> str | None: ...
    def argv(self, job: jobs.Job, adir: Path, *, resume: str | None, c: Confinement, model: str) -> list[str]: ...
    def env(self, base: Mapping[str, str]) -> dict[str, str]: ...
    def session_from(self, adir: Path) -> str | None: ...
    def transcript_exists(self, sid: str) -> bool: ...
    def parse(self, adir: Path, rc: int, *, schema: Mapping[str, object] = REPORT_SCHEMA) -> Outcome: ...


def conform(value: object, schema: Mapping[str, object]) -> dict[str, object] | None:
    """`value` (an object, or its JSON text) as the schema's required fields: None when one that
    isn't nullable is missing or an enum doesn't match; a missing nullable one becomes None."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return None
    props = schema.get("properties")
    required = schema.get("required")
    if not isinstance(value, dict) or not isinstance(props, dict) or not isinstance(required, list):
        return None
    out: dict[str, object] = {}
    for key in required:
        spec = props.get(key) if isinstance(props.get(key), dict) else {}
        assert isinstance(spec, dict)
        types = spec.get("type")
        if value.get(key) is None:
            if isinstance(types, list) and "null" in types:
                out[key] = None
                continue
            return None
        enum = spec.get("enum")
        if isinstance(enum, list) and value[key] not in enum:
            return None
        out[key] = value[key]
    return out


def _bin_dir(name: str) -> list[Path]:
    found = shutil.which(name)
    return [Path(found).resolve().parent] if found else []


def _toml(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def _int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


# --- Claude Code ---------------------------------------------------------------------------

def claude_result(path: Path) -> dict[str, object]:
    """The result message of `claude -p --output-format json` (2.1.319 prints an array of every
    message ending in {"type": "result"}; other builds print that object alone), or {}."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return {}
    candidates: list[object] = []
    try:
        candidates.append(json.loads(text))
    except ValueError:
        for line in text.splitlines():
            try:
                candidates.append(json.loads(line))
            except ValueError:
                continue
    for data in reversed(candidates):
        items = data if isinstance(data, list) else [data]
        results = [m for m in items if isinstance(m, dict) and m.get("type") == "result"]
        if results:
            return results[-1]
    return {}


def _reset_from(text: str) -> str:
    m = re.search(r"\|(\d{9,11})\b", text)
    if not m:
        return ""
    return dt.datetime.fromtimestamp(int(m.group(1)), tz=dt.timezone.utc).isoformat()


class ClaudeEngine:
    name = "claude"
    enforces = frozenset({"cmd-allowlist", "os-sandbox", "path-confine", "no-network"})

    def _home(self) -> Path:
        return Path(os.environ.get("CLAUDE_CONFIG_DIR") or core.home() / ".claude")

    def ro_paths(self) -> list[Path]:
        return _bin_dir("claude")

    def rw_paths(self) -> list[Path]:
        return [core.home() / ".claude", core.home() / ".claude.json"]

    def available(self) -> str | None:
        claude = shutil.which("claude")
        if not claude:
            return "not installed"
        try:
            r = subprocess.run([claude, "auth", "status"], capture_output=True, text=True, timeout=30)
            info = json.loads(r.stdout[r.stdout.find("{"):]) if "{" in r.stdout else {}
        except (OSError, subprocess.TimeoutExpired, ValueError):
            info = {}
        return None if isinstance(info, dict) and info.get("loggedIn") else "not signed in (claude auth login)"

    def argv(self, job: jobs.Job, adir: Path, *, resume: str | None, c: Confinement, model: str) -> list[str]:
        del adir
        sandbox: dict[str, object] = {
            "enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False,
            "filesystem": {"allowWrite": [] if c.read_only else [str(c.wc)],
                           "denyRead": [str(core.home() / ".claude" / ".credentials.json")]},
        }
        if not c.network:
            sandbox["network"] = {"allowedDomains": []}
        settings = {"permissions": {"blockWritesOutsideWorkingDirectories": True}, "sandbox": sandbox}
        session = ["--resume", resume] if resume else ["--session-id", job.session_id]
        # A review runs in the default mode with read tools only: an edit would need approval,
        # and --permission-prompts none denies it.
        mode = "default" if c.read_only else "acceptEdits"
        tools = list(READ_TOOLS) if c.read_only else [*CLAUDE_TOOLS, *(f"Bash({cmd})" for cmd in c.commands)]
        # A source's job runs on someone else's code (a PR head, any committer's revision): the copy's
        # own .claude settings (hooks run outside Claude's command sandbox) and .mcp.json don't load.
        foreign = ["--setting-sources", "user", "--strict-mcp-config"] if job.origin else []
        name = f"ws-agent {job.id}: {job.title}"[:80] if not job.origin else f"ws-agent {job.id}"
        return [shutil.which("claude") or "claude", "-p", "--output-format", "json", "--permission-mode", mode,
                "--permission-prompts", "none", *foreign, *session, "--name", name,
                "--append-system-prompt", c.instructions, "--json-schema", json.dumps(c.schema),
                "--settings", json.dumps(settings), *(["--model", model] if model else []),
                *(a for d in c.read_dirs for a in ("--add-dir", str(d))),
                "--allowedTools", *tools]

    def env(self, base: Mapping[str, str]) -> dict[str, str]:
        return {k: v for k, v in base.items() if not k.startswith(("OPENAI_", "CODEX_"))}

    def session_from(self, adir: Path) -> str | None:
        sid = claude_result(adir / "stdout").get("session_id")
        return str(sid) if sid else None

    def transcript_exists(self, sid: str) -> bool:
        return bool(sid) and any((self._home() / "projects").glob(f"*/{sid}.jsonl"))

    def parse(self, adir: Path, rc: int, *, schema: Mapping[str, object] = REPORT_SCHEMA) -> Outcome:
        res = claude_result(adir / "stdout")
        if not res:
            return Outcome("error", None, "", message=f"claude printed no result (exit {rc})")
        sid = str(res.get("session_id") or "")
        text = str(res.get("result") or "")
        cost = res.get("total_cost_usd")
        out = Outcome("ok", None, sid, turns=_int(res.get("num_turns")), duration_ms=_int(res.get("duration_ms")),
                      cost_usd=float(cost) if isinstance(cost, (int, float)) and not isinstance(cost, bool) else None,
                      message=text[:500])
        if res.get("is_error"):
            status = _int(res.get("api_error_status"))
            if status in AUTH_STATUS or CLAUDE_AUTH.search(text):
                out.kind = "auth"
            elif CLAUDE_USAGE.search(text):
                out.kind, out.reset_at = "usage_limit", _reset_from(text)
            elif status in TRANSIENT_STATUS or CLAUDE_TRANSIENT.search(text):
                out.kind = "transient"
            else:
                out.kind = "error"
            return out
        out.report = conform(res.get("structured_output"), schema)
        if out.report is None:
            out.kind, out.message = "error", "claude ended without the structured report"
        return out


# --- Codex ----------------------------------------------------------------------------------

def _events(path: Path) -> list[dict[str, object]]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    found = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            found.append(e)
    return found


def _codex_kind(message: str) -> str:
    status, code, text = None, "", message
    try:
        doc = json.loads(message)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        status = _int(doc.get("status"))
        err = doc.get("error") if isinstance(doc.get("error"), dict) else {}
        assert isinstance(err, dict)
        code = str(err.get("code") or err.get("type") or "")
        text = f"{err.get('message', '')} {code}"
    if status in AUTH_STATUS or CODEX_AUTH.search(text):
        return "auth"
    if CODEX_USAGE.search(text):
        return "usage_limit"
    if status in TRANSIENT_STATUS or CODEX_TRANSIENT.search(text):
        return "transient"
    return "error"


class CodexEngine:
    name = "codex"
    enforces = frozenset({"os-sandbox", "path-confine", "no-network"})

    def ro_paths(self) -> list[Path]:
        return _bin_dir("codex")

    def rw_paths(self) -> list[Path]:
        return [core.home() / ".codex"]

    def available(self) -> str | None:
        codex = shutil.which("codex")
        if not codex:
            return "not installed"
        try:
            r = subprocess.run([codex, "login", "status"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return "codex login status didn't answer"
        return None if r.returncode == 0 and "Logged in" in r.stdout + r.stderr else "not logged in (codex login)"

    def argv(self, job: jobs.Job, adir: Path, *, resume: str | None, c: Confinement, model: str) -> list[str]:
        del job
        adir.mkdir(parents=True, exist_ok=True)
        schema = adir / "schema.json"
        schema.write_text(json.dumps(c.schema), encoding="utf-8")
        common = ["--json", "-o", str(adir / "last.json"), "--output-schema", str(schema), "--skip-git-repo-check",
                  "--ignore-rules", "--ignore-user-config"]
        conf = ["-c", 'approval_policy="never"',
                "-c", f"sandbox_workspace_write.network_access={'true' if c.network else 'false'}",
                "-c", f"developer_instructions={_toml(c.instructions)}"]
        codex = shutil.which("codex") or "codex"
        tail = [*(["-m", model] if model else []), "-"]
        if resume:   # `exec resume` takes no -s/-C: the sandbox comes by -c, the directory is the cwd
            return [codex, "exec", "resume", resume, *common, "-c", 'sandbox_mode="workspace-write"', *conf, *tail]
        mode = "read-only" if c.read_only else "workspace-write"
        return [codex, "exec", *common, "-s", mode, "-C", str(c.wc), *conf, *tail]

    def env(self, base: Mapping[str, str]) -> dict[str, str]:
        return {k: v for k, v in base.items() if not k.startswith("ANTHROPIC_") and k != "CLAUDE_CODE_OAUTH_TOKEN"}

    def session_from(self, adir: Path) -> str | None:
        for e in _events(adir / "stdout"):
            if e.get("type") == "thread.started" and e.get("thread_id"):
                return str(e["thread_id"])
        return None

    def transcript_exists(self, sid: str) -> bool:
        return bool(sid) and any((core.home() / ".codex" / "sessions").glob(f"**/rollout-*-{sid}.jsonl"))

    def parse(self, adir: Path, rc: int, *, schema: Mapping[str, object] = REPORT_SCHEMA) -> Outcome:
        events = _events(adir / "stdout")
        sid = self.session_from(adir) or ""
        turns = sum(1 for e in events if e.get("type") == "turn.completed")
        errors = []
        for e in events:
            if e.get("type") == "error":
                errors.append(str(e.get("message", "")))
            elif e.get("type") == "turn.failed":
                err = e.get("error")
                errors.append(str(err.get("message", "")) if isinstance(err, dict) else str(err))
        last = events[-1].get("type") if events else None
        if errors and last != "turn.completed":
            kind = _codex_kind(errors[-1])
            return Outcome(kind, None, sid, turns=turns, message=errors[-1][:500])
        if last != "turn.completed":
            return Outcome("error", None, sid, turns=turns, message=f"codex stopped before finishing (exit {rc})")
        report = None
        try:
            report = conform((adir / "last.json").read_text(encoding="utf-8"), schema)
        except OSError:
            pass
        if report is None:
            texts = [e["item"].get("text") for e in events if e.get("type") == "item.completed"
                     and isinstance(e.get("item"), dict) and e["item"].get("type") == "agent_message"]  # type: ignore[union-attr]
            report = conform(texts[-1], schema) if texts else None
        if report is None:
            return Outcome("error", None, sid, turns=turns, message="codex ended without the structured report")
        return Outcome("ok", report, sid, turns=turns, message=str(report.get("summary") or "")[:500])


ENGINES: dict[str, Engine] = {"claude": ClaudeEngine(), "codex": CodexEngine()}


# --- cooldowns, selection, slots -------------------------------------------------------------

def _cooldowns() -> Path:
    return core.state_dir() / "agent-engines.json"


def _read_cooldowns() -> dict[str, str]:
    try:
        data = json.loads(_cooldowns().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}


def cooling(name: str) -> str:
    """The ISO time this engine's usage-limit cooldown ends, or "" when it isn't cooling down."""
    until = _read_cooldowns().get(name, "")
    try:
        return until if until and dt.datetime.fromisoformat(until) > dt.datetime.now(dt.timezone.utc) else ""
    except ValueError:
        return ""


def cool(name: str, until: str) -> None:
    data = _read_cooldowns()
    data[name] = until
    core.private_dir(core.state_dir())
    core.atomic_write(_cooldowns(), (json.dumps(data, indent=2) + "\n").encode("utf-8"))


def select(entry: agent_registry.Repo, *, exclude: Collection[str] = ()) -> tuple[Engine | None, list[str]]:
    """The first engine `entry` allows that can run now, and why each one before it can't."""
    why = agent_sandbox.probe()
    if why:
        return None, [f"sandbox: {why}"]
    reasons: list[str] = []
    for name in entry.engines:
        if name in exclude:
            reasons.append(f"{name}: already stopped in this attempt")
            continue
        until = cooling(name)
        if until:
            reasons.append(f"{name}: cooling down until {until} (usage limit)")
            continue
        engine = ENGINES.get(name)
        if engine is None:
            reasons.append(f"{name}: unknown engine")
            continue
        problem = engine.available()
        if problem:
            reasons.append(f"{name}: {problem}")
            continue
        return engine, reasons
    return None, reasons


@contextlib.contextmanager
def slot(name: str, cap: int, *, poll: float = 0.5) -> Iterator[None]:
    """One of `cap` run slots for this engine on this host (flock files), waiting for a free one."""
    d = core.state_dir() / "agent-engines"
    core.private_dir(d)
    while True:
        for i in range(max(1, cap)):
            fh = open(d / f"{name}.{i}.lock", "a+")  # noqa: SIM115 - held for the with-block
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fh.close()
                continue
            try:
                yield
            finally:
                fh.close()
            return
        time.sleep(poll)
