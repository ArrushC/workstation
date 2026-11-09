"""What the person hears about jobs without asking.

- Every finished job (succeeded, failed, needs-you, waiting) is a line in <state>/agent-events.jsonl.
- Live Claude sessions get those lines on their next prompt (the workstation-orchestration
  plugin's UserPromptSubmit hook runs `ws-agent events`): at most 3, once per session, for jobs of
  that session's repository plus any job that needs the person. Reading them touches only this
  file and a per-session marker: no pueue, no network, so a prompt never waits on the queue.
- A desktop notice goes through ~/.claude/notify.sh, detached and non-blocking
  (NOTIFY_NO_MODAL=1: no MessageBox); hosts it can't reach (a dev server with no display) get
  the session lines only.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import subprocess
import time
from pathlib import Path

from . import agent_registry, core, jobs

EVENTS_MAX = 1 << 20
TAIL = 64 << 10
MAX_LINES = 3
MARKER_TTL = 7 * 86400
_SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def events_path() -> Path:
    return core.state_dir() / "agent-events.jsonl"


def marker_dir() -> Path:
    return core.state_dir() / "agent-sessions"


def append(kind: str, job: jobs.Job, text: str) -> None:
    """One event line. serve and every executor append from their own processes, so the size
    check, the rotation and the write happen under agent-events.lock."""
    _write({"ts": time.time(), "job": job.id, "repo": job.repo, "kind": kind, "text": text})


def append_inbox(item_id: str, repo: str, text: str) -> None:
    """An inbox item waits for the person. `text` never quotes the candidate: a live session
    reads it, and the candidate's words are someone else's."""
    _write({"ts": time.time(), "item": item_id, "repo": repo, "kind": "inbox", "text": text})


def _write(entry: dict[str, object]) -> None:
    path = events_path()
    core.private_dir(path.parent)
    line = json.dumps(entry)
    with open(path.with_name("agent-events.lock"), "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with contextlib.suppress(OSError):
            if path.stat().st_size > EVENTS_MAX:
                path.replace(path.with_suffix(".jsonl.1"))
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def _tail_events(path: Path) -> list[dict[str, object]]:
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - TAIL))
            data = fh.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    if size > TAIL and lines:
        lines = lines[1:]   # the first line is cut
    found = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            found.append(e)
    return found


def lines_for(session_id: str, repo_key: str) -> list[str]:
    """The event lines this session hasn't seen, newest last; the first call only starts it."""
    if not _SAFE_ID.match(session_id or ""):
        return []
    d = marker_dir()
    core.private_dir(d)
    marker = d / session_id
    now = time.time()
    try:
        since = float(marker.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        since = None
    core.atomic_write(marker, f"{now}\n".encode())
    for old in d.iterdir():
        with contextlib.suppress(OSError):
            if now - old.stat().st_mtime > MARKER_TTL:
                old.unlink()
    if since is None:
        return []
    events = _tail_events(events_path().with_suffix(".jsonl.1")) + _tail_events(events_path())
    seen = [e for e in events if isinstance(e.get("ts"), (int, float)) and since < float(e["ts"]) <= now  # type: ignore[arg-type]
            and (e.get("repo") == repo_key or e.get("kind") == "needs-you")]
    return [f"[orchestration] {e.get('text')}: "
            + (f"ws-agent inbox --show {e.get('item')}" if e.get("kind") == "inbox" else f"ws-agent result {e.get('job')}")
            for e in seen[-MAX_LINES:]]


def _plain(text: str) -> str:
    """Notice text with nothing a shell or PowerShell could read as code."""
    return re.sub(r"[^\w .,:()/@#+=-]", " ", text)[:200].strip()


def notify(text: str) -> None:
    if not agent_registry.settings().desktop:
        return
    script = core.home() / ".claude" / "notify.sh"
    if not script.is_file():
        return
    with contextlib.suppress(OSError):
        subprocess.Popen(["bash", str(script), "ws-agent", _plain(text)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                         env={**os.environ, "NOTIFY_NO_MODAL": "1"})
