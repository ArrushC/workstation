"""`ws-agent serve`: the always-on loop (the dev.mise.ws-agent-serve user service).

Every TICK seconds it:
1. resumes interrupted jobs (a reboot, a killed pueued), at most MAX_AUTO_RESUMES times per job,
   counted in the job's record so a serve restart doesn't reset it;
2. requeues `waiting` jobs once one of their repository's engines is out of its cooldown;
3. polls each configured source (SVN watches, GitHub /agent requests). A candidate passes the
   fixed admission rules, then triage when it was inferred; an accepted one in act mode, or an
   explicit request, becomes a job; everything else the person should see goes to the inbox.
   Follow-ups on a ticket go to its job.
A paused queue is never started, and while disk space is low no source job starts (its
candidate waits in the inbox). Each step and each source fails on its own: it is logged, and the
rest of the tick goes on. One serve per host (a lock); SIGTERM/SIGINT end it after the tick.
It never writes to a server: sources read, jobs end in patches.
"""

from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import json
import os
import signal
import sys
import time
from collections.abc import Callable, Iterable
from pathlib import Path

from . import (agent_admit, agent_disk, agent_events, agent_inbox, agent_registry, agent_sources, agent_triage, core,
               engines, jobs)

TICK = 30
MAX_AUTO_RESUMES = 2
UP_WITHIN = 120
LOG_MAX = 1 << 20


def _dir() -> Path:
    return core.state_dir() / "agent-serve"


def log_path() -> Path:
    return core.state_dir() / "agent-serve.log"


# --- status ---------------------------------------------------------------------------------

def status() -> dict[str, object]:
    try:
        data = json.loads((_dir() / "status.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def up() -> bool:
    """serve ticked in the last UP_WITHIN seconds and its process is alive."""
    st = status()
    last = st.get("last_tick")
    return isinstance(last, (int, float)) and time.time() - float(last) < UP_WITHIN and _alive(st.get("pid"))


def configured() -> bool:
    """Any allowed repository with a source that isn't off."""
    return any((r.watch is not None and r.watch.mode in ("observe", "act"))
               or (r.github is not None and r.github.mode in ("observe", "act"))
               for r in agent_registry.load()[0].values())


def _write_status(st: dict[str, object]) -> None:
    core.private_dir(_dir())
    core.atomic_write(_dir() / "status.json", (json.dumps(st, indent=1) + "\n").encode("utf-8"))


def _log(lines: Iterable[str]) -> None:
    lines = list(lines)
    if not lines:
        return
    stamp = core.now_iso()
    text = "".join(f"{stamp} {ln}\n" for ln in lines)
    sys.stdout.write(text)
    sys.stdout.flush()
    p = log_path()
    core.private_dir(p.parent)
    with contextlib.suppress(OSError):
        if p.stat().st_size > LOG_MAX:
            p.replace(p.with_suffix(".log.1"))
    with open(p, "a", encoding="utf-8") as fh:
        fh.write(text)


# --- recovery -------------------------------------------------------------------------------

def _allowed(job: jobs.Job) -> agent_registry.Repo | None:
    return agent_registry.find(core.expand(job.repo))


def _recover(q: jobs.Queue | None) -> list[str]:
    """Interrupted jobs back in the queue with their session, each at most MAX_AUTO_RESUMES times."""
    if q is None or q.group == "Paused":
        return []
    out = []
    for j in jobs.all_jobs():
        if j.closed or j.cancelled or j.auto_resumes >= MAX_AUTO_RESUMES or _allowed(j) is None:
            continue
        with jobs.queue_lock():
            now_q = jobs.pueue_status()
            if now_q is None or now_q.group == "Paused":
                return out
            j = jobs.load(j.id)
            if j.auto_resumes >= MAX_AUTO_RESUMES or jobs.state(j, now_q.tasks) != "interrupted":
                continue
            j.auto_resumes += 1
            jobs.save(j)   # counted before the enqueue: a crash in between never earns a third
            jobs.kill(j)
            jobs.enqueue(j, resume=True)
        agent_events.append("resumed", j, f"{j.id} resumed after an interruption ({j.auto_resumes}/{MAX_AUTO_RESUMES})")
        out.append(f"resumed {j.id} after an interruption ({j.auto_resumes}/{MAX_AUTO_RESUMES})")
    return out


def _archive(job: jobs.Job) -> None:
    res = jobs.job_dir(job.id) / "result"
    for name in ("exit", "report"):
        cur = res / f"{name}.json"
        if cur.exists():
            cur.replace(res / f"{name}-{job.attempts}.json")


def _requeue_waiting(q: jobs.Queue | None) -> list[str]:
    """A job waiting for an engine goes back once one of its repository's engines isn't cooling."""
    if q is None or q.group == "Paused":
        return []
    out = []
    for j in jobs.all_jobs():
        entry = _allowed(j)
        if entry is None or jobs.state(j, q.tasks) != "waiting":
            continue
        free = [n for n in entry.engines if not engines.cooling(n)]
        if not free:
            continue
        with jobs.queue_lock():
            now_q = jobs.pueue_status()
            if now_q is None or now_q.group == "Paused" or jobs.state(jobs.load(j.id), now_q.tasks) != "waiting":
                continue
            _archive(j)
            jobs.kill(j)
            jobs.enqueue(j, resume=True)
        agent_events.append("resumed", j, f"{j.id} resumed: {free[0]} is available again")
        out.append(f"requeued {j.id}: {free[0]} is available again")
    return out


# --- sources --------------------------------------------------------------------------------

def _inbox(c: agent_inbox.Candidate, decision: dict[str, object] | None, why: str) -> str:
    item = agent_inbox.add(c, decision)
    agent_events.append_inbox(item.id, c.repo, f"inbox: {item.id} ({c.source}) waits for you")
    agent_events.notify(f"inbox {item.id} ({c.source}, {c.repo}): {agent_inbox.printable(c.title)[:80]}")
    return f"{c.cid}: in the inbox as {item.id} ({why})"


def _held(c: agent_inbox.Candidate, decision: dict[str, object] | None, reason: str) -> dict[str, object]:
    """The decision an accepted candidate keeps in the inbox when it couldn't become a job now."""
    base = decision or {"decision": "accept", "rule": None, "title": c.title, "task": c.prompt}
    return {**base, "reason": reason}


def _queue(c: agent_inbox.Candidate, decision: dict[str, object] | None) -> str:
    from . import agent   # the CLI module; imported here, since it imports this one
    low = agent_disk.low()
    if low:
        return _inbox(c, _held(c, decision, f"disk low: {low}; accept it once there's room"), "disk low")
    q = agent.queue_job(core.expand(c.repo), c.title, c.prompt, origin=c.cid, base=c.base)
    if q.job is None:
        return _inbox(c, _held(c, decision, f"couldn't queue it: {q.error}"), q.error)
    if c.thread:
        agent_sources.remember_thread(c.thread, q.job.id)
    return f"{c.cid}: queued job {q.job.id}"


def _handle(c: agent_inbox.Candidate, entry: agent_registry.Repo, mode: str, authors: tuple[str, ...],
            rules: tuple[str, ...]) -> str:
    why = agent_admit.admit(c, agent_registry.find(entry.path), mode, authors)
    if why:
        return f"{c.cid}: not admitted: {why}"
    decision: dict[str, object] | None = None
    if not c.explicit:
        decision = agent_triage.triage(c, rules, entry)
        if decision.get("decision") == "ignore":
            return f"{c.cid}: ignored by triage: {decision.get('reason')}"
        if decision.get("decision") == "accept" and c.source == "svn" and isinstance(decision.get("rule"), str):
            c = dataclasses.replace(c, prompt=agent_sources.review_prompt(
                c.base.get("review_rev", c.base.get("rev", "?")), c.author, str(decision["rule"])))
    accepted = c.explicit or (decision is not None and decision.get("decision") == "accept")
    if mode == "act" and accepted:
        return _queue(c, decision)
    return _inbox(c, decision, "observe" if mode == "observe" else "triage asks")


def _follow(job_id: str, text: str) -> str:
    from . import agent
    try:
        job = jobs.load(job_id)
    except KeyError:
        return f"follow-up for {job_id}: no such job"
    code, msg = agent.tell_job(job, text)
    return f"follow-up for {job_id}: " + (msg.splitlines()[0] if msg else f"exit {code}")


def _poll_svn(entry: agent_registry.Repo, now: float) -> list[str]:
    assert entry.watch is not None
    return [_handle(c, entry, entry.watch.mode, entry.watch.authors, entry.watch.rules)
            for c in agent_sources.poll_svn(entry, now)]


def _poll_github(entry: agent_registry.Repo, now: float) -> list[str]:
    assert entry.github is not None
    found, follow = agent_sources.poll_github(entry, now)
    return [_follow(jid, text) for jid, text in follow] + \
        [_handle(c, entry, entry.github.mode, entry.github.logins, ()) for c in found]


def tick(now: float) -> list[str]:
    """One pass; what it did, as log lines. Each step fails on its own."""
    lines: list[str] = []

    def step(name: str, fn: Callable[[], list[str]]) -> None:
        try:
            lines.extend(fn())
        except Exception as e:  # noqa: BLE001 - one step's failure never stops the others
            lines.append(f"{name}: {type(e).__name__}: {e}")

    q = jobs.pueue_status()
    step("recover", lambda: _recover(q))
    step("waiting", lambda: _requeue_waiting(q))
    for key, entry in sorted(agent_registry.load()[0].items()):
        if entry.watch is not None and entry.watch.mode in ("observe", "act"):
            step(f"svn {key}", lambda e=entry: _poll_svn(e, now))
        if entry.github is not None and entry.github.mode in ("observe", "act"):
            step(f"github {key}", lambda e=entry: _poll_github(e, now))
    return lines


# --- the loop -------------------------------------------------------------------------------

def serve(*, once: bool) -> int:
    d = core.private_dir(_dir())
    lock = open(d / "serve.lock", "a+")  # noqa: SIM115 - held for the whole run
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.seek(0)
        pid = lock.read().strip() or str(status().get("pid") or "?")
        lock.close()
        print(f"ws-agent serve is already running (pid {pid})")
        return 3
    lock.seek(0)
    lock.truncate()
    lock.write(f"{os.getpid()}\n")
    lock.flush()
    stopping = False

    def stop(_sig: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    old = {s: signal.signal(s, stop) for s in (signal.SIGTERM, signal.SIGINT)}
    st: dict[str, object] = {"pid": os.getpid(), "started": core.now_iso(), "last_tick": None, "last_error": ""}
    try:
        _write_status(st)
        _log([f"serve started (pid {os.getpid()}, every {TICK} s)"])
        while True:
            now = time.time()
            lines = tick(now)
            errors = [ln for ln in lines if ": " in ln and ("Error" in ln or "not running" in ln)]
            st.update(last_tick=time.time(), last_error=errors[-1] if errors else st.get("last_error", ""))
            _write_status(st)
            _log(lines)
            if once or stopping:
                return 0
            while not stopping and time.time() - now < TICK:
                time.sleep(1)
            if stopping:
                _log(["serve stopping"])
                return 0
    finally:
        for s, h in old.items():
            signal.signal(s, h)
        lock.close()
