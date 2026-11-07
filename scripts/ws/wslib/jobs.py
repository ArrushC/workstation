"""Queued agent jobs: a record per job under the host state dir, a thin adapter over pueue (the
process queue: persistence, concurrency, logs, kill), and the job state derived from both.

Nothing here runs in the background. A job's state is worked out each time from its record,
its result/exit.json (written by the executor when it finishes) and pueue's view of its task:

  closed > cancelled > exit.json (succeeded/failed) > the pueue task:
  Running -> running; Queued/Stashed/Paused/Locked -> queued; Done Killed or missing -> interrupted
  (the daemon or the host stopped under it); Done Failed/Success without exit.json -> failed
  (the executor itself crashed; exec.log says why). pueued unreachable -> unknown.
"""

from __future__ import annotations

import contextlib
import fcntl
import fnmatch
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
from collections.abc import Iterator, Mapping
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import core

GROUP = "agents"
ACTIVE = ("queued", "running")
# Repository tokens a queued job never needs, kept out of what pueue stores per task (its
# state.json holds every task's environment) and out of the job itself.
TOKENS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GITLAB_TOKEN")
_SESSION_MARK = re.compile(r"SESSION|MESSAGING|BRIDGE|ENTRYPOINT|EXECPATH|ATTENDED|CHILD")


def strip_session(base: Mapping[str, str]) -> dict[str, str]:
    """`base` without what ties a process to the Claude Code session that started it: CLAUDECODE
    and the CLAUDE_CODE_* session variables. Provider/auth ones (CLAUDE_CODE_OAUTH_TOKEN,
    CLAUDE_CODE_USE_*) stay: a job authenticates with them."""
    return {k: v for k, v in base.items() if k != "CLAUDECODE"
            and not (k.startswith("CLAUDE_CODE_") and _SESSION_MARK.search(k[len("CLAUDE_CODE_"):]))}


def queue_env(base: Mapping[str, str]) -> dict[str, str]:
    """The environment `pueue add` records for a task (and hands to _exec): no session markers,
    no repository tokens. SSH_AUTH_SOCK stays (a path): an svn+ssh checkout in prepare needs it."""
    return {k: v for k, v in strip_session(base).items() if k not in TOKENS}


class QueueError(Exception):
    """pueue refused or failed a request that changes the queue."""


@dataclass
class Job:
    id: str
    title: str
    repo: str                 # the working copy root, tilde form (the registry key)
    vcs: str                  # "svn" | "git"
    base: dict[str, str]      # svn: url, repos_root, rev; git: commit, branch
    prompt_sha: str
    paths: list[str]
    created: str
    session_id: str
    timeout: str
    pueue_id: int | None = None
    attempts: int = 0
    cancelled: bool = False
    closed: bool = False
    warnings: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Queue:
    tasks: dict[int, str]     # every pueue task: Queued Running Paused Stashed Locked Success Failed Killed
    running: int              # tasks of the agents group running
    queued: int               # tasks of the agents group waiting (Queued)
    group: str                # the agents group: "Running", "Paused", or "" when it doesn't exist
    parallel: int


# --- records -----------------------------------------------------------------------

def jobs_dir() -> Path:
    return core.state_dir() / "agent-jobs"


def job_dir(job_id: str) -> Path:
    return jobs_dir() / job_id


def new_id() -> str:
    while True:
        cand = secrets.token_hex(3)
        if not job_dir(cand).exists():
            return cand


def save(job: Job) -> None:
    core.private_dir(job_dir(job.id))
    core.atomic_write(job_dir(job.id) / "job.json", (json.dumps(asdict(job), indent=2) + "\n").encode("utf-8"))


def _read(path: Path) -> Job:
    data = json.loads(path.read_text(encoding="utf-8"))
    return Job(**{k: v for k, v in data.items() if k in Job.__dataclass_fields__})


def load(prefix: str) -> Job:
    """The job whose id is `prefix` or starts with it; KeyError when none or several do."""
    exact = job_dir(prefix) / "job.json"
    if prefix and exact.is_file():
        return _read(exact)
    hits = [p for p in jobs_dir().glob(f"{prefix}*/job.json")] if prefix and jobs_dir().is_dir() else []
    if len(hits) != 1:
        raise KeyError(f"ws-agent: {'no job' if not hits else 'several jobs'} match {prefix!r}")
    return _read(hits[0])


def all_jobs() -> list[Job]:
    if not jobs_dir().is_dir():
        return []
    found = []
    for p in jobs_dir().glob("*/job.json"):
        try:
            found.append(_read(p))
        except (OSError, ValueError, TypeError):
            continue
    return sorted(found, key=lambda j: (j.created, j.id))


def exit_info(job: Job) -> dict[str, object] | None:
    try:
        data = json.loads((job_dir(job.id) / "result" / "exit.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# --- pueue -------------------------------------------------------------------------

def pueue_argv(*args: str) -> list[str]:
    cfg = os.environ.get("WS_AGENT_PUEUE_CONFIG")
    return ["pueue", *(["-c", cfg] if cfg else []), *args]


def _pueue(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(pueue_argv(*args), capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _status_word(status: object) -> str:
    """pueue 4's task status ({"Running": {...}}, {"Done": {"result": ...}}) as one word."""
    if isinstance(status, str):
        return status
    if not isinstance(status, dict) or not status:
        return ""
    kind, body = next(iter(status.items()))
    if kind != "Done":
        return str(kind)
    result = body.get("result") if isinstance(body, dict) else None
    if result == "Success":
        return "Success"
    if result == "Killed":
        return "Killed"
    return "Failed"   # {"Failed": n}, FailedToSpawn, DependencyFailed, Errored


def pueue_status() -> Queue | None:
    r = _pueue("status", "--json")
    if r is None or r.returncode != 0:
        return None
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        return None
    tasks: dict[int, str] = {}
    running = queued = 0
    for key, task in (doc.get("tasks") or {}).items():
        if not isinstance(task, dict):
            continue
        word = _status_word(task.get("status"))
        tasks[int(key)] = word
        if task.get("group") == GROUP:
            running += word == "Running"
            queued += word == "Queued"
    group = (doc.get("groups") or {}).get(GROUP)
    if isinstance(group, dict):
        return Queue(tasks, running, queued, str(group.get("status", "")), int(group.get("parallel_tasks", 1)))
    return Queue(tasks, running, queued, "", 0)


def _change(*args: str) -> None:
    r = _pueue(*args)
    if r is None:
        raise QueueError("ws-agent: pueue isn't installed or didn't answer")
    if r.returncode != 0:
        raise QueueError(f"ws-agent: pueue {args[0]} failed: {(r.stderr or r.stdout).strip()}")


def ensure_group(parallel: int) -> None:
    q = pueue_status()
    if q is None:
        raise QueueError("ws-agent: pueued isn't running (systemctl --user start dev.mise.pueued)")
    if not q.group:
        _change("group", "add", GROUP, "--parallel", str(parallel))
    elif q.parallel != parallel:
        _change("parallel", str(parallel), "--group", GROUP)


def enqueue(job: Job, *, resume: bool) -> int:
    """Queue `ws.py agent _exec <id>` in the agents group; records and returns the task id."""
    cmd = [sys.executable, str(core.WS_PY), "agent", "_exec", job.id, *(["--resume"] if resume else [])]
    r = _pueue("add", "--print-task-id", "--group", GROUP, "--label", f"ws-agent:{job.id}",
               "--working-directory", str(job_dir(job.id)), "--", *cmd, env=queue_env(os.environ))
    if r is None or r.returncode != 0:
        raise QueueError(f"ws-agent: pueue add failed: {((r.stderr or r.stdout) if r else 'no pueue').strip()}")
    try:
        job.pueue_id = int(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError) as e:
        raise QueueError(f"ws-agent: pueue add printed no task id: {r.stdout!r}") from e
    save(job)
    return job.pueue_id


def kill(job: Job) -> bool:
    """Stop the job's pueue task if it runs, then drop it from the queue; True when pueue
    answered. (The claude it started is stopped by stop_run: pueue kills only the task's own
    process group, and `timeout` puts claude in another.)"""
    if job.pueue_id is None:
        return True
    k = _pueue("kill", str(job.pueue_id))
    deadline = time.monotonic() + 3   # pueue refuses to remove a task that is still stopping
    while time.monotonic() < deadline:
        q = pueue_status()
        if q is None or q.tasks.get(job.pueue_id) not in ("Running", "Paused"):
            break
        time.sleep(0.1)
    r = _pueue("remove", str(job.pueue_id))
    return k is not None and r is not None and (k.returncode == 0 or r.returncode == 0)


@contextlib.contextmanager
def queue_lock() -> Iterator[None]:
    """Serialise run's duplicate check, record and enqueue across processes (two sessions, or a
    Bash call retried after a timeout, queue at the same moment)."""
    core.private_dir(jobs_dir())
    fh = open(jobs_dir() / ".queue.lock", "a+")  # noqa: SIM115 - held for the with-block
    deadline = time.monotonic() + float(os.environ.get("WS_AGENT_LOCK_TIMEOUT", "30"))
    try:
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise QueueError("ws-agent: another ws-agent run is queuing a job; try again") from None
                time.sleep(0.05)
        yield
    finally:
        fh.close()


# --- the claude a job runs ------------------------------------------------------------
# _exec records the process group of what it started (timeout and claude) in run.pid with the
# process's start time, so a reused pid is never mistaken for it. While that group lives the
# job is running, whatever pueue says: a daemon stop or `pueue kill` takes only _exec itself.

def _proc(pid: int) -> tuple[str, str] | None:
    """(state, start time) of a process from /proc/<pid>/stat, or None when it doesn't exist."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    fields = stat[stat.rfind(")") + 2:].split()
    return (fields[0], fields[19]) if len(fields) > 19 else None


def record_run(job: Job, pgid: int) -> None:
    info = _proc(pgid)
    core.atomic_write(job_dir(job.id) / "run.pid", json.dumps({"pgid": pgid, "start": info[1] if info else ""}).encode())


def clear_run(job: Job) -> None:
    (job_dir(job.id) / "run.pid").unlink(missing_ok=True)


def live_run(job: Job) -> int | None:
    """The process group of the job's claude while it still runs."""
    try:
        data = json.loads((job_dir(job.id) / "run.pid").read_text(encoding="utf-8"))
        pgid, start = int(data["pgid"]), str(data["start"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    info = _proc(pgid)
    return pgid if info and info[1] == start and info[0] != "Z" else None


def stop_run(job: Job, grace: float = 10.0) -> bool:
    """Stop the job's claude (its whole process group): TERM, then KILL after `grace` seconds.
    False when nothing was running."""
    pgid = live_run(job)
    if pgid is None:
        return False
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while live_run(job) is not None and time.monotonic() < deadline:
        time.sleep(0.1)
    if live_run(job) is not None:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(pgid, signal.SIGKILL)
    return True


def pause() -> None:
    _change("pause", "--group", GROUP)


def resume() -> None:
    _change("start", "--group", GROUP)


# --- derived state -----------------------------------------------------------------

def state(job: Job, tasks: dict[int, str] | None) -> str:
    if job.closed:
        return "closed"
    if job.cancelled:
        return "cancelled"
    info = exit_info(job)
    if info is not None:
        return "succeeded" if info.get("exit_code") == 0 else "failed"
    if live_run(job) is not None:
        return "running"
    if tasks is None:
        return "unknown"
    word = tasks.get(job.pueue_id) if job.pueue_id is not None else None
    if word == "Running":
        return "running"
    if word in ("Queued", "Stashed", "Paused", "Locked"):
        return "queued"
    if word in (None, "Killed"):
        return "interrupted"
    return "failed"


def duplicate(repo: str, prompt_sha: str, all_: list[Job], tasks: dict[int, str] | None) -> Job | None:
    """A job of the same repository and prompt that isn't closed or cancelled: queued, running,
    awaiting review, or failed/interrupted (`ws agent retry` continues those)."""
    for job in all_:
        if job.repo == repo and job.prompt_sha == prompt_sha and \
                state(job, tasks) in (*ACTIVE, "succeeded", "failed", "interrupted"):
            return job
    return None


def _overlap(a: str, b: str) -> bool:
    return a == b or fnmatch.fnmatch(a, b) or fnmatch.fnmatch(b, a)


def overlaps(repo: str, paths: list[str], all_: list[Job], tasks: dict[int, str] | None) -> list[Job]:
    """Active jobs in the same repository that claimed a path these paths share or match."""
    if not paths:
        return []
    return [j for j in all_ if j.repo == repo and state(j, tasks) in ACTIVE
            and any(_overlap(a, b) for a in paths for b in j.paths)]
