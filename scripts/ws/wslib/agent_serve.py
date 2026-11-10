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
LONG_TICK = 900
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
    """serve's process is alive and it ticked in the last UP_WITHIN seconds, or is inside a tick
    that began less than LONG_TICK ago (a triage or a fetch can take minutes)."""
    st = status()
    now = time.time()
    last, since = st.get("last_tick"), st.get("ticking_since")
    fresh = isinstance(last, (int, float)) and now - float(last) < UP_WITHIN
    ticking = isinstance(since, (int, float)) and now - float(since) < LONG_TICK
    return (fresh or ticking) and _alive(st.get("pid"))


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
    # lines quote svn/gh errors and triage reasons: someone else's text, on a terminal and in a log
    text = "".join(f"{stamp} {agent_inbox.printable(ln)}\n" for ln in lines)
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

def _allowed(job: jobs.Job, repos: dict[str, agent_registry.Repo]) -> agent_registry.Repo | None:
    """The job's registry entry, from one read of the registry per pass (job.repo is its key)."""
    return repos.get(job.repo)


def _recover(q: jobs.Queue | None) -> list[str]:
    """Interrupted jobs back in the queue with their session, each at most MAX_AUTO_RESUMES times."""
    if q is None or q.group == "Paused":
        return []
    out = []
    repos = agent_registry.load()[0]
    for j in jobs.all_jobs():
        if j.closed or j.cancelled or j.auto_resumes >= MAX_AUTO_RESUMES or _allowed(j, repos) is None:
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
    """A job waiting for an engine goes back once one of its repository's engines can run it
    (signed in, not cooling): one that is merely not cooling (logged out, not installed) would
    send it straight back to waiting, every tick, with a notice each time."""
    if q is None or q.group == "Paused":
        return []
    out = []
    repos = agent_registry.load()[0]
    for j in jobs.all_jobs():
        if j.closed or j.cancelled:
            continue
        entry = _allowed(j, repos)
        if entry is None or jobs.state(j, q.tasks) != "waiting":
            continue
        engine, _ = engines.select(entry)
        if engine is None:
            continue
        with jobs.queue_lock():
            now_q = jobs.pueue_status()
            cur = jobs.load(j.id)   # the person's cancel or close may have landed meanwhile
            if now_q is None or now_q.group == "Paused" or jobs.state(cur, now_q.tasks) != "waiting":
                continue
            _archive(cur)
            jobs.kill(cur)
            jobs.enqueue(cur, resume=True)
        agent_events.append("resumed", cur, f"{cur.id} resumed: {engine.name} is available again")
        out.append(f"requeued {cur.id}: {engine.name} is available again")
    return out


# --- sources --------------------------------------------------------------------------------

_new_items: list[str] = []   # inbox items this tick added: one notice for all of them


def _inbox(c: agent_inbox.Candidate, decision: dict[str, object] | None, why: str) -> str:
    item = agent_inbox.add(c, decision)
    agent_events.append_inbox(item.id, c.repo, f"inbox: {item.id} ({c.source}) waits for you")
    _new_items.append(item.id)
    return f"{c.cid}: in the inbox as {item.id} ({why})"


def _held(c: agent_inbox.Candidate, decision: dict[str, object] | None, reason: str) -> dict[str, object]:
    """The decision an accepted candidate keeps in the inbox when it couldn't become a job now."""
    base = decision or {"decision": "request", "rule": None, "title": c.title, "task": c.prompt}
    return {**base, "reason": reason}


def _queue(c: agent_inbox.Candidate, decision: dict[str, object] | None, capped: str) -> str:
    from . import agent   # the CLI module; imported here, since it imports this one
    if capped:
        return _inbox(c, _held(c, decision, f"{capped}; accept it to start it anyway"), "daily cap")
    low = agent_disk.low()
    if low:
        return _inbox(c, _held(c, decision, f"disk low: {low}; accept it once there's room"), "disk low")
    q = agent.queue_job(core.expand(c.repo), c.title, c.prompt, origin=c.cid, base=c.base)
    if q.job is None:
        return _inbox(c, _held(c, decision, f"couldn't queue it: {q.error}"), q.error)
    if c.thread:
        agent_sources.remember_thread(c.thread, q.job.id)
    return f"{c.cid}: queued job {q.job.id}"


def _same_rule(said: object, rules: tuple[str, ...]) -> str | None:
    """The watch's own rule triage named, or None: the model's text is derived from someone else's
    words, so only a rule the person wrote reaches the job's prompt."""
    if not isinstance(said, str):
        return None
    norm = " ".join(said.split()).strip(" .").casefold()
    return next((r for r in rules if " ".join(r.split()).strip(" .").casefold() == norm), None)


def _handle(c: agent_inbox.Candidate, entry: agent_registry.Repo, mode: str, authors: tuple[str, ...],
            rules: tuple[str, ...]) -> str:
    why = agent_admit.admit(c, agent_registry.find(entry.path), mode, authors)
    capped = why if why and agent_admit.is_cap(why) else ""
    if why and not capped:
        return f"{c.cid}: not admitted: {why}"
    if c.note:   # the source couldn't finish it (no base): the person decides
        return _inbox(c, _held(c, None, c.note), "held")
    decision: dict[str, object] | None = None
    if not c.explicit:
        decision = agent_triage.triage(c, rules, entry)
        if decision.get("decision") == "ignore":
            return f"{c.cid}: ignored by triage: {decision.get('reason')}"
        rule = _same_rule(decision.get("rule"), rules)
        if decision.get("decision") == "accept" and c.source == "svn" and rule:
            c = dataclasses.replace(c, prompt=agent_sources.review_prompt(
                c.base.get("review_rev", c.base.get("rev", "?")), c.author, rule))
    accepted = c.explicit or (decision is not None and decision.get("decision") == "accept")
    if mode == "act" and accepted:
        return _queue(c, decision, capped)
    return _inbox(c, decision, "observe" if mode == "observe" else "triage asks")


def _follow(job_id: str, text: str, login: str) -> str:
    from . import agent
    try:
        job = jobs.load(job_id)
    except KeyError:
        return f"follow-up for {job_id}: no such job"
    code, msg = agent.tell_job(job, text, sender=f"gh:{login}" if login else "you")
    return f"follow-up for {job_id}: " + (msg.splitlines()[0] if msg else f"exit {code}")


# Candidates a poll returned are kept in pending.json until handled: the poll has already moved
# the source's cursor past them, so a serve killed mid-batch (systemd's stop timeout, a WSL
# shutdown) picks them up on its next tick instead of losing them. One that fails MAX_TRIES times
# is dropped, with its error in the log.
MAX_TRIES = 3


def _pending_path() -> Path:
    return _dir() / "pending.json"


def _pending() -> list[dict[str, object]]:
    try:
        data = json.loads(_pending_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [d for d in data if isinstance(d, dict) and isinstance(d.get("c"), dict)] if isinstance(data, list) else []


def _save_pending(items: list[dict[str, object]]) -> None:
    core.private_dir(_dir())
    core.atomic_write(_pending_path(), (json.dumps(items, indent=1) + "\n").encode("utf-8"))


def _push(found: list[agent_inbox.Candidate]) -> None:
    if found:
        have = _pending()
        known = {str(d["c"].get("cid")) for d in have}  # type: ignore[union-attr]
        _save_pending(have + [{"c": dataclasses.asdict(c), "tries": 0} for c in found if c.cid not in known])


def _settings_for(c: agent_inbox.Candidate) -> tuple[agent_registry.Repo, str, tuple[str, ...], tuple[str, ...]] | None:
    """(entry, mode, authors, rules) of the source that found c, as configured now."""
    entry = agent_registry.find(core.expand(c.repo))
    if entry is None:
        return None
    if c.source == "svn" and entry.watch is not None:
        return entry, entry.watch.mode, entry.watch.authors, entry.watch.rules
    if c.source == "github" and entry.github is not None:
        return entry, entry.github.mode, entry.github.logins, ()
    return None


def _drain() -> list[str]:
    """Handle every pending candidate, oldest first, each on its own."""
    out = []
    for d in _pending():
        names = {f.name for f in dataclasses.fields(agent_inbox.Candidate)}
        c = agent_inbox.Candidate(**{k: v for k, v in d["c"].items() if k in names})  # type: ignore[union-attr,arg-type]
        how = _settings_for(c)
        keep = False
        if how is None:
            out.append(f"{c.cid}: dropped: its repository or source is gone")
        else:
            try:
                out.append(_handle(c, *how))
            except Exception as e:  # noqa: BLE001 - one candidate's failure never drops the others
                tries = int(d.get("tries") or 0) + 1  # type: ignore[call-overload]
                keep = tries < MAX_TRIES
                d["tries"] = tries
                out.append(f"{c.cid}: {type(e).__name__}: {e}" + ("" if keep else f" (dropped after {tries} tries)"))
        rest = [x for x in _pending() if x["c"].get("cid") != c.cid]  # type: ignore[union-attr]
        _save_pending(rest + ([d] if keep else []))
    return out


def _poll_svn(entry: agent_registry.Repo, now: float) -> list[str]:
    _push(agent_sources.poll_svn(entry, now))
    return _drain()


def _poll_github(entry: agent_registry.Repo, now: float) -> list[str]:
    found, follow = agent_sources.poll_github(entry, now)
    _push(found)
    return [_follow(jid, text, login) for jid, text, login in follow] + _drain()


def tick(now: float) -> list[str]:
    """One pass; what it did, as log lines. Each step fails on its own."""
    lines: list[str] = []
    _new_items.clear()

    def step(name: str, fn: Callable[[], list[str]]) -> None:
        try:
            lines.extend(fn())
        except Exception as e:  # noqa: BLE001 - one step's failure never stops the others
            lines.append(f"{name}: {type(e).__name__}: {e}")

    q = jobs.pueue_status()
    step("recover", lambda: _recover(q))
    step("waiting", lambda: _requeue_waiting(q))
    step("pending", _drain)   # what a serve killed mid-batch left
    for key, entry in sorted(agent_registry.load()[0].items()):
        if entry.watch is not None and entry.watch.mode in ("observe", "act"):
            step(f"svn {key}", lambda e=entry: _poll_svn(e, now))
        if entry.github is not None and entry.github.mode in ("observe", "act"):
            step(f"github {key}", lambda e=entry: _poll_github(e, now))
    if _new_items:
        n = len(_new_items)
        agent_events.notify(f"inbox: {n} new item{'s' if n != 1 else ''} wait for you (ws-agent inbox)")
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
        # Under its unit (systemd sets INVOCATION_ID) this isn't a failure: Restart=on-failure would
        # retry into the start limit and leave the unit failed after the other serve ends.
        return 0 if os.environ.get("INVOCATION_ID") else 3
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
            st["ticking_since"] = now
            _write_status(st)
            lines = tick(now)
            errors = [ln for ln in lines if ": " in ln and ("Error" in ln or "not running" in ln)]
            st.update(last_tick=time.time(), ticking_since=None,
                      last_error=agent_inbox.printable(errors[-1]) if errors else st.get("last_error", ""))
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
