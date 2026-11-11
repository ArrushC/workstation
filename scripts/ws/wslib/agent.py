"""`ws agent` (also `ws-agent`): queued headless Claude Code jobs, and the orchestration line.

A job is the minimum coordination pueue lacks: a record of the base it starts from (SVN
URL@rev or git commit, taken when you ask), a private working copy, a resumable Claude
session, a derived state and the review artifacts. pueue does the queueing, concurrency
(group `agents`), persistence, logs and killing; Claude Code does the work.

    context                 the one-line [orchestration] summary (SessionStart hook)
    route [--json]          this repository: VCS, base, allowed?, queue, jobs
    allow <path> [--command RULE]... | disallow <path> | repos
                            which repositories jobs may use (refused inside Claude Code)
    run --title T (--prompt TEXT | --prompt-file F) [--repo P] [--rev R] [--timeout 2h]
        [--paths GLOB]... [--force]
    ls [--repo P | --all] [--json] | show <id> | result <id> [--diff]
    tell <id> TEXT | answer <id> TEXT   the person's words to a job (after its turn, or resuming it)
    interrupt <id> TEXT     stop the job's running turn now and resume it with the message
    publish-to <path> [--mode off|manual|auto] [--comment] [--draft-pr] [--svn-branch ^/P]
                            what may be written back for a repository (refused inside Claude Code)
    publish <id> [--dry-run] [--even-failing]
                            write a finished job's result back: a comment, a draft PR, an SVN branch
    inbox [--all] [--json] [--show ID] | accept <id> [--note TEXT] | dismiss <id>
                            what a watched source found, waiting for the person
    ui [--rows] [--fleet]   jobs and the inbox in one fzf list (enter result, alt-keys act)
    fleet [--json] | fleet add|remove <host>
                            the same lists from this host and your other hosts, over your SSH
    serve [--once]          the always-on loop (the ws-agent-serve service): recovery, sources
    close --empty           close every succeeded job whose patch is empty
    cancel <id> | retry <id> | close <id> | pause | resume | doctor
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import (agent_disk, agent_events, agent_exec, agent_inbox, agent_registry, agent_sandbox, agent_serve,
               agent_sources, core, engines, jobs, vcs)

MAX_CONTEXT = 400
_DURATION = re.compile(r"^\s*\d+\s*[smhd]?\s*$")


def _err(msg: str) -> None:
    sys.stderr.write(msg.rstrip("\n") + "\n")


# --- context and route ----------------------------------------------------------------

def _head(p: vcs.Probe) -> str:
    root = core.tilde(p.root) if p.root else "?"
    if p.kind == "svn":
        return f"svn {root} {vcs.short_url(p)}@{p.rev or '?'}"
    if p.github:
        return f"git {root} github {p.github}"
    return f"git {root} {p.branch}@{p.rev[:12]}" if p.rev else f"git {root} (no commits)"


def _queue_words(q: jobs.Queue | None, parallel: int) -> str:
    if q is None:
        return "queue: pueued not running"
    if q.group == "Paused":
        return "queue paused (ws-agent resume)"
    return f"queue {q.running}/{q.parallel if q.group else parallel} running, {q.queued} queued"


def _hhmm(iso: str) -> str:
    try:
        return dt.datetime.fromisoformat(iso).astimezone().strftime("%H:%M")
    except ValueError:
        return "?"


def _state_words(job: jobs.Job, st: str) -> str:
    """A job's state as the context line and `ls` say it: needs you, waiting (claude until
    15:30), succeeded checks fail (review)."""
    info = jobs.exit_info(job) or {}
    if st == "needs-you":
        return "needs you"
    if st == "waiting":
        return f"waiting ({info.get('engine') or job.engine or '?'} until {_hhmm(str(info.get('reset_at') or ''))})"
    if st == "succeeded":
        checks = info.get("checks")
        return ("succeeded" + (f" checks {checks}" if checks in ("pass", "fail", "not run") else "") + " (review)")
    return st


def _here(repo_key: str, tasks: dict[int, str] | None) -> str:
    rows = []
    for j in jobs.all_jobs():
        if j.repo != repo_key:
            continue
        st = jobs.state(j, tasks)
        if st == "closed":
            continue
        rows.append(f"{j.id} {_state_words(j, st)}")
    if not rows:
        return "here: none"
    extra = f", +{len(rows) - 4} more" if len(rows) > 4 else ""
    return "here: " + ", ".join(rows[-4:]) + extra


def context_line(cwd: Path) -> str:
    try:
        job = os.environ.get("WS_AGENT_JOB")
        if job:
            return f"[orchestration] queued job {job}: work directly in this working copy; no further delegation"
        p = vcs.probe(cwd)
        if p.kind == "none" or p.root is None:
            return "[orchestration] no repository here"
        _, parallel = agent_registry.load()
        entry = agent_registry.find(p.root)
        q = jobs.pueue_status() if entry is not None or jobs.all_jobs() else None
        parts = [f"[orchestration] {_head(p)}",
                 f"jobs: allowed ({', '.join(entry.engines)}); {_queue_words(q, parallel)}" if entry is not None
                 else "jobs: not allowed (ws-agent allow)",
                 _here(core.tilde(p.root), q.tasks if q else None)]
        waiting = len(agent_inbox.items(core.tilde(p.root)))
        if waiting:
            parts.append(f"inbox {waiting}")
        if agent_serve.configured():
            parts.append("serve up" if agent_serve.up() else "serve down")
        if agent_disk.low():
            parts.append("disk low")
        return " | ".join(parts)[:MAX_CONTEXT]
    except Exception:  # noqa: BLE001 - the hook must never fail a session start
        return ""


def _route(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.repo) if args.repo else Path.cwd())
    entry = agent_registry.find(p.root) if p.root else None
    _, parallel = agent_registry.load()
    q = jobs.pueue_status()
    base = ({"url": p.url, "repos_root": p.repos_root, "rev": p.rev} if p.kind == "svn"
            else {"commit": p.rev, "branch": p.branch} if p.kind == "git" else {})
    key = core.tilde(p.root) if p.root else ""
    here = [{"id": j.id, "title": j.title, "state": jobs.state(j, q.tasks if q else None)}
            for j in jobs.all_jobs() if key and j.repo == key]
    data = {"vcs": p.kind, "root": key, "base": base, "github": p.github, "allowed": entry is not None,
            "commands": list(entry.commands) if entry else [],
            "queue": None if q is None else {"group": q.group or "absent", "running": q.running, "queued": q.queued,
                                             "parallel": q.parallel if q.group else parallel},
            "jobs": here}
    if args.json:
        print(json.dumps(data, indent=2))
        return 0
    if p.kind == "none":
        print("No git or SVN working copy here: work directly or with subagents.")
        return 0
    print(f"{_head(p)}")
    print(f"Queued jobs: {'allowed' if entry else 'not allowed (the person runs: ws-agent allow ' + key + ')'}")
    if entry and entry.commands:
        print(f"Extra commands jobs may run: {', '.join(entry.commands)}")
    print(f"Queue: {_queue_words(q, parallel)}")
    for row in here:
        print(f"  {row['id']}  {row['state']:<11} {agent_inbox.printable(str(row['title']))}")
    return 0


# --- registry ---------------------------------------------------------------------------

def _allow(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    if p.kind == "none" or p.root is None:
        _err(f"ws-agent: {args.path} isn't in a git or SVN working copy")
        return 3
    try:
        repo = agent_registry.allow(p.root, p.kind, args.command or [], engines=tuple(args.engine or ("claude",)),
                                    checks=tuple(args.check or ()), fix_rounds=args.fix_rounds, review=args.review or "",
                                    network=args.network)
    except agent_registry.Refused as e:
        _err(str(e))
        return 3
    except ValueError as e:
        _err(str(e))
        return 2
    except agent_registry.Unreadable as e:
        _err(str(e))
        return 1
    print(f"allowed: {core.tilde(repo.path)} ({repo.vcs})")
    for line in _repo_words(repo):
        print(f"  {line}")
    if "codex" in repo.engines:
        print("Codex sends the code it reads to OpenAI. For company code that needs your organization's "
              "authorization for OpenAI, separate from Claude's.")
    print("Queued jobs run headless in a sandboxed private copy at a recorded base, with this host's logins;\n"
          "they never commit, push or otherwise write to the repository. ws-agent disallow undoes this.")
    return 0


def _repo_words(r: agent_registry.Repo) -> list[str]:
    words = [f"engines: {', '.join(r.engines)}"]
    if r.commands:
        words.append(f"commands: {', '.join(r.commands)}")
    if r.checks:
        words.append(f"checks: {', '.join(r.checks)} (fix rounds {r.fix_rounds})")
    if r.review:
        words.append(f"review: {r.review}")
    words.append(f"network: {'on' if r.network else 'off'}")
    if r.watch is not None:
        n = len(r.watch.rules)
        words.append(f"watch: {', '.join(r.watch.urls)} ({r.watch.mode}, {n} rule{'' if n == 1 else 's'})")
    if r.github is not None:
        words.append(f"github: {r.github.slug} ({r.github.mode}, logins: {', '.join(r.github.logins)})")
    if r.publish != agent_registry.Publish():
        words.append(f"publish: {_publish_words(r.publish)}")
    return words


def _source_change(fn: Callable[[Path, Any], agent_registry.Repo], root: Path,
                   value: object) -> tuple[int, agent_registry.Repo | None]:
    try:
        return 0, fn(root, value)
    except agent_registry.Refused as e:
        _err(str(e))
        return 3, None
    except ValueError as e:
        _err(str(e))
        return 2, None
    except KeyError as e:
        _err(str(e.args[0]))
        return 3, None
    except agent_registry.Unreadable as e:
        _err(str(e))
        return 1, None


def _watch(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    watch = None if args.cmd == "unwatch" else agent_registry.Watch(
        urls=tuple(args.url or ()), mode=args.mode, authors=tuple(args.author or ()), rules=tuple(args.rule or ()),
        interval=args.interval)
    prev = agent_registry.find(root)
    rc, repo = _source_change(agent_registry.set_watch, root, watch)
    if repo is not None:
        print(f"{'watching' if watch else 'no longer watching'}: {core.tilde(root)}"
              + (f" ({', '.join(watch.urls)}, {watch.mode})" if watch else ""))
        if watch is None:
            agent_sources.forget_sources(f"svn:{core.tilde(root)}:")
        elif watch.mode != "off":
            # new, or back from off: from HEAD now (nothing committed meanwhile); a changed setting keeps its cursor
            fresh = prev is None or prev.watch is None or prev.watch.mode == "off"
            try:
                agent_sources.start_watch(repo, fresh=fresh)
            except agent_sources.SourceError as e:
                _err(f"warning: {e}; the first poll starts the watch at HEAD once the URL answers")
    return rc


def _github(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    src = None
    if args.cmd == "github":
        logins = list(args.login or [])
        if not logins and os.environ.get("CLAUDECODE") != "1":
            gh = core.which("gh")
            r = subprocess.run([gh, "api", "user", "--jq", ".login"], capture_output=True, text=True, timeout=30) \
                if gh else None
            logins = [r.stdout.strip()] if r is not None and r.returncode == 0 and r.stdout.strip() else []
        src = agent_registry.GitHubSource(slug=p.github or "", mode=args.mode, logins=tuple(logins))
    prev = agent_registry.find(root)
    rc, repo = _source_change(agent_registry.set_github, root, src)
    if repo is not None:
        print(f"{'taking /agent requests' if src else 'no longer taking requests'}: {core.tilde(root)}"
              + (f" ({src.slug}, {src.mode}, logins: {', '.join(src.logins)})" if src else ""))
        if src is not None:
            if src.mode != "off":   # from now: new, or back from off, brings nothing from meanwhile
                agent_sources.start_github(repo, fresh=prev is None or prev.github is None or prev.github.mode == "off")
        elif prev is not None and prev.github is not None and prev.github.slug:
            agent_sources.update_source(f"gh:{prev.github.slug}", None)
    return rc


def _publish_to(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    pub = agent_registry.Publish(mode=args.mode, comment=bool(args.comment), draft_pr=bool(args.draft_pr),
                                 svn_branch=args.svn_branch or "")
    rc, repo = _source_change(agent_registry.set_publish, root, pub)
    if repo is not None:
        print(f"publishing for {core.tilde(root)}: {_publish_words(repo.publish)}")
        if pub.mode == "auto":
            _err("ws-agent serve will now write these for passing jobs from this repository's sources, with your "
                 "credentials, without asking per job. ws-agent publish-to <path> --mode off stops it.")
    return rc


def _publish_words(p: agent_registry.Publish) -> str:
    kinds = [w for w, on in (("GitHub comment", p.comment), ("draft PR", p.draft_pr),
                             (f"SVN branch under {p.svn_branch}", bool(p.svn_branch))) if on]
    return f"{p.mode}" + (f" ({', '.join(kinds)})" if kinds else " (no kind named: nothing is written)")


def _publish(args: argparse.Namespace) -> int:
    from . import agent_publish
    if os.environ.get("WS_AGENT_JOB"):
        _err("ws-agent: this is a queued job; it can't publish (work directly)")
        return 3
    job = _load(args.id)
    if job is None:
        return 1
    try:
        lines = agent_publish.publish(job, auto=False, even_failing=args.even_failing, dry_run=args.dry_run,
                                      allow_workflows=args.allow_workflows)
    except agent_publish.PublishError as e:
        _err(str(e))
        return 1
    for ln in lines:
        print(ln)
    done = any(": published " in ln or ": would publish " in ln for ln in lines)
    return 0 if done else 3


def _disallow(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    prev = agent_registry.find(root)
    try:
        removed = agent_registry.disallow(root)
    except agent_registry.Refused as e:
        _err(str(e))
        return 3
    except agent_registry.Unreadable as e:
        _err(str(e))
        return 1
    # its sources' cursors go too: allowed again later, a watch starts from then, not from now
    agent_sources.forget_sources(f"svn:{core.tilde(root)}:")
    if prev is not None and prev.github is not None and prev.github.slug:
        agent_sources.update_source(f"gh:{prev.github.slug}", None)
    print(f"{'disallowed' if removed else 'was not allowed'}: {core.tilde(root)}")
    return 0


def _repos(_: argparse.Namespace) -> int:
    repos, parallel = agent_registry.load()
    if not repos:
        print(f"no repositories allowed for queued jobs ({core.tilde(agent_registry.registry_path())}); "
              "ws-agent allow <path> adds one")
        return 0
    print(f"queue: pueue group {jobs.GROUP}, {parallel} at a time")
    for key, r in sorted(repos.items()):
        print(f"{key}  ({r.vcs}, since {r.allowed_at[:10]})  " + "; ".join(_repo_words(r)))
    return 0


# --- run ----------------------------------------------------------------------------------

def _prompt(args: argparse.Namespace) -> str | None:
    if args.prompt_file:
        try:
            return Path(args.prompt_file).read_text(encoding="utf-8")
        except OSError as e:
            _err(f"ws-agent: can't read {args.prompt_file}: {e.strerror}")
            return None
    return args.prompt


def _base(p: vcs.Probe, rev: str | None, warnings: list[str]) -> tuple[dict[str, str] | None, str]:
    """The base a new job starts from, or (None, why not)."""
    root = core.tilde(p.root) if p.root else "?"
    if p.kind == "svn":
        if (p.mixed or p.switched) and not rev:
            why = "mixed revisions" if p.mixed else "a switched subtree"
            return None, f"ws-agent: {root} has {why} ({p.version}); name the base with --rev <N>"
        base = {"url": p.url, "repos_root": p.repos_root, "rev": rev or p.rev}
        if p.modified:
            warnings.append(f"local modifications in {root} are not included: the job starts from "
                            f"{vcs.short_url(p)}@{base['rev']}")
        return base, ""
    commit = p.rev
    if rev:
        r = subprocess.run(["git", "-C", str(p.root), "rev-parse", "--verify", "-q", f"{rev}^{{commit}}"],
                           capture_output=True, text=True)
        commit = r.stdout.strip() if r.returncode == 0 else ""
        if not commit:
            return None, f"ws-agent: {rev!r} isn't a commit in {root}"
    if not commit:
        return None, f"ws-agent: {root} has no commits yet"
    if p.modified:
        warnings.append(f"uncommitted changes in {root} are not included: the job starts from {commit[:12]}")
    return {"commit": commit, "branch": p.branch}, ""


@dataclass
class Queued:
    """What queue_job did: the job (code 0), or why not (1 an error, 2 bad input, 3 refused)."""
    job: jobs.Job | None
    error: str
    code: int
    warnings: list[str]
    dup: jobs.Job | None = None
    paused: bool = False


def queue_job(root: Path, title: str, prompt: str, *, rev: str | None = None, paths: Sequence[str] = (),
              timeout: str = "2h", force: bool = False, origin: str = "",
              base: dict[str, str] | None = None) -> Queued:
    """The one way a job is made, for `run`, `accept` and serve alike: allowed, a base (the
    probe's, or the one a source gives), the duplicate and overlap checks, the record and the
    enqueue under the queue lock."""
    if os.environ.get("WS_AGENT_JOB"):
        return Queued(None, "ws-agent: this is a queued job; it can't queue jobs (work directly)", 3, [])
    if not prompt.strip():
        return Queued(None, "ws-agent: the prompt is empty", 2, [])
    if not _DURATION.match(timeout or ""):
        return Queued(None, f"ws-agent: --timeout {timeout!r} isn't a duration like 30m or 2h", 2, [])
    # A source hands over the base, so the copy's own state doesn't matter: the quick probe (no
    # svnversion over the tree, no git status taking the person's index lock from inside serve).
    p = vcs.probe(root, thorough=base is None)
    if p.kind == "none" or p.root is None:
        return Queued(None, f"ws-agent: {root} isn't in a git or SVN working copy", 3, [])
    key = core.tilde(p.root)
    if agent_registry.find(p.root) is None:
        return Queued(None, f"ws-agent: {key} isn't allowed for queued jobs; run 'ws-agent allow {key}' in your own "
                      "terminal", 3, [])
    if rev and p.kind == "svn" and not rev.isdigit():
        return Queued(None, f"ws-agent: --rev {rev!r} isn't an SVN revision number", 2, [])
    warnings: list[str] = []
    if base is None:
        base, why = _base(p, rev, warnings)
        if base is None:
            return Queued(None, why, 3, warnings)
    q = jobs.pueue_status()
    if q is None:
        return Queued(None, "ws-agent: pueued isn't running (systemctl --user start dev.mise.pueued)", 1, warnings)
    sha = hashlib.sha256(prompt.strip().encode("utf-8")).hexdigest()
    _, parallel = agent_registry.load()
    try:
        with jobs.queue_lock():   # the duplicate check, the record and the enqueue as one step
            all_ = jobs.all_jobs()
            dup = jobs.duplicate(key, sha, all_, q.tasks)
            if dup and not force:
                st = jobs.state(dup, q.tasks)
                hint = (f"ws-agent retry {dup.id} continues it" if st in ("failed", "interrupted")
                        else f"ws-agent result {dup.id} once it's done")
                return Queued(None, f"ws-agent: job {dup.id} already does this ({st}); {hint}; --force queues another",
                              3, warnings, dup=dup)
            for other in jobs.overlaps(key, list(paths), all_, q.tasks):
                warnings.append(f"job {other.id} ({jobs.state(other, q.tasks)}) also claims {', '.join(other.paths)}: "
                                "review the two patches together")
            job = jobs.Job(id=jobs.new_id(), title=title, repo=key, vcs=p.kind, base=base, prompt_sha=sha,
                           paths=list(paths), created=core.now_iso(), session_id="", timeout=timeout,
                           warnings=warnings, origin=origin)
            try:
                jobs.ensure_group(parallel)
                jobs.save(job)
                (jobs.job_dir(job.id) / "prompt.md").write_text(prompt, encoding="utf-8")
                jobs.enqueue(job, resume=False)
            except jobs.QueueError:
                shutil.rmtree(jobs.job_dir(job.id), ignore_errors=True)
                raise
    except jobs.QueueError as e:
        return Queued(None, str(e), 1, warnings)
    return Queued(job, "", 0, warnings, paused=q.group == "Paused")


def _run_job(args: argparse.Namespace) -> int:
    prompt = _prompt(args)
    if prompt is None:
        return 1
    q = queue_job(Path(args.repo) if args.repo else Path.cwd(), args.title, prompt, rev=args.rev,
                  paths=args.paths or [], timeout=args.timeout, force=args.force)
    return _report_queued(q)


def _report_queued(q: Queued) -> int:
    """What run and accept print: the job id on stdout, the rest on stderr."""
    if q.dup is not None:
        print(q.dup.id)
    if q.job is None:
        _err(q.error)
        return q.code
    job = q.job
    print(job.id)
    for w in q.warnings:
        _err(f"warning: {w}")
    _err(f"queued {job.id} in pueue group {jobs.GROUP} (task {job.pueue_id}); ws-agent ls, ws-agent result {job.id}")
    if q.paused:
        _err("warning: the queue is paused (pueue pauses it when its daemon stops); ws-agent resume starts it")
    low = agent_disk.low()
    if low:
        _err(f"warning: disk low: {low}; serve starts no source jobs until there's room")
    return 0


# --- the inbox -------------------------------------------------------------------------

def _decision_word(it: agent_inbox.Item) -> str:
    if it.decision:
        return str(it.decision.get("decision") or "-")
    return "request" if it.candidate.get("explicit") else "-"


def _inbox(args: argparse.Namespace) -> int:
    if args.show:
        return _inbox_show(args.show)
    rows = agent_inbox.items(all_=args.all)
    if args.json:
        print(json.dumps([dataclasses.asdict(i) for i in rows], indent=2))
        return 0
    if not rows:
        print("the inbox is empty" if args.all else "no open inbox items")
        return 0
    for it in rows:
        c = it.candidate
        tail = (f"  {it.status}" + (f" {it.job}" if it.job else "")) if args.all else ""
        title = agent_inbox.printable(str(c.get("title") or ""))
        print(f"{it.id}  {c.get('source', '?')!s:<7} {_decision_word(it):<8} {title}  ({c.get('repo', '?')}){tail}")
    return 0


def _inbox_show(prefix: str) -> int:
    try:
        it = agent_inbox.get(prefix)
    except KeyError as e:
        _err(str(e.args[0]))
        return 1
    c, d = it.candidate, it.decision or {}
    clean = agent_inbox.printable
    lines = [f"{it.id}  {it.status}" + (f" (job {it.job})" if it.job else "") + f"  {clean(str(c.get('title') or ''))}",
             f"  from: {c.get('source')} {clean(str(c.get('cid')))} by {clean(str(c.get('author') or '?'))}"
             + (f"  {clean(str(c['url']))}" if c.get("url") else ""),
             f"  repo: {c.get('repo')}   found: {it.created}"]
    if d:
        if not c.get("explicit"):   # an explicit request is never triaged: its decision only carries why it's held
            lines.append(f"  triage: {d.get('decision')}"
                         + (f" (rule: {clean(str(d['rule']))})" if d.get("rule") else ""))
        if d.get("reason"):
            lines.append(f"  reason: {clean(str(d['reason']))}")
    elif c.get("explicit"):
        lines.append("  a request (/agent): no triage")
    lines += ["", "their words (untrusted):"]
    lines += ["  " + ln for ln in clean(str(c.get("text") or ""), lines=True).splitlines()]
    if it.status != "accepted":
        lines += ["", f"ws-agent accept {it.id} [--note TEXT] | ws-agent dismiss {it.id}"]
    print("\n".join(lines))
    return 0


def _inbox_item(prefix: str) -> agent_inbox.Item | None:
    try:
        return agent_inbox.get(prefix)
    except KeyError as e:
        _err(str(e.args[0]))
        return None


def _accept(args: argparse.Namespace) -> int:
    it = _inbox_item(args.id)
    if it is None:
        return 1
    if it.status == "accepted":
        _err(f"ws-agent: {it.id} was already accepted: job {it.job} (ws-agent result {it.job})")
        return 3
    c = it.as_candidate()
    prompt = c.prompt
    if args.note and args.note.strip():
        prompt = prompt.rstrip("\n") + f"\n\nA note from the person who accepted this:\n{args.note.strip()}\n"
    # an item held without a base (its source couldn't fetch one) starts from your copy's HEAD
    q = queue_job(core.expand(c.repo), c.title, prompt, origin=c.cid, base=c.base or None)
    if q.job is not None:
        agent_inbox.resolve(it, "accepted", q.job.id)
        if c.thread:   # a later /agent on that issue goes to this job
            agent_sources.remember_thread(c.thread, q.job.id)
    return _report_queued(q)


def _dismiss(args: argparse.Namespace) -> int:
    it = _inbox_item(args.id)
    if it is None:
        return 1
    if it.status == "accepted":
        _err(f"ws-agent: {it.id} was accepted as job {it.job}; cancel or close that job instead")
        return 3
    agent_inbox.resolve(it, "dismissed")
    print(f"dismissed {it.id}: {agent_inbox.printable(str(it.candidate.get('title') or ''))}")
    return 0


# --- inspect, cancel, retry, close ----------------------------------------------------------

def _load(ident: str) -> jobs.Job | None:
    try:
        return jobs.load(ident)
    except KeyError as e:
        _err(str(e.args[0]))
        return None


def _tasks() -> dict[int, str] | None:
    q = jobs.pueue_status()
    return q.tasks if q else None


def _ls(args: argparse.Namespace) -> int:
    tasks = _tasks()
    key = ""
    if not args.all:
        p = vcs.probe(Path(args.repo) if args.repo else Path.cwd())
        key = core.tilde(p.root) if p.root else ""
    rows = []
    for j in jobs.all_jobs():
        st = jobs.state(j, tasks)
        if key and j.repo != key:
            continue
        if st == "closed" and not args.all:
            continue
        info = jobs.exit_info(j) or {}
        rows.append({"id": j.id, "state": st, "checks": str(info.get("checks") or "-") if info else "-",
                     "engine": j.engine or "-", "title": j.title, "repo": j.repo, "vcs": j.vcs, "created": j.created,
                     "attempts": j.attempts, "pueue_id": j.pueue_id})
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print("no jobs" + (f" in {key}" if key else ""))
        return 0
    for r in rows:
        where = "" if key else f"  {r['repo']}"
        checks = f"checks {r['checks']}" if r["checks"] not in ("-", "none") else "-"
        print(f"{r['id']}  {r['state']:<11} {checks:<14} {r['engine']:<7} {r['created'][:16]}  "
              f"{agent_inbox.printable(r['title'])}{where}")
    if tasks is None:
        _err("warning: pueued isn't running, so live states are unknown")
    return 0


def _show(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    jd = jobs.job_dir(job.id)
    print(f"{job.id}  {st}  {agent_inbox.printable(job.title)}")
    print(f"repository: {job.repo} ({job.vcs})   base: {_base_words(job)}")
    print(f"created {job.created}, attempts {job.attempts}, pueue task {job.pueue_id}, session {job.session_id or '-'}")
    print(f"directory: {jd}")
    for w in job.warnings:
        print(f"warning: {w}")
    talk = jobs.thread(job)
    if talk:
        print("conversation:")
        for m in talk:
            who = "you" if m.get("from") == "you" else "job"
            when = str(m.get("ts", ""))[:16]
            note = "" if who == "job" or m.get("delivered") else "  (not delivered yet)"
            body = str(m.get("text", "")).replace("\n", "\n        ")
            print(f"  {when}  {who}: {body}{note}")
    log = agent_exec._tail(jd / "exec.log", 15)
    if log:
        print("exec.log (end):")
        print("\n".join(f"  {line}" for line in log))
    if job.pueue_id is not None:
        print(f"full output: pueue log {job.pueue_id}")
    return 0


def _base_words(job: jobs.Job) -> str:
    if job.vcs == "svn":
        root, url = job.base.get("repos_root", ""), job.base.get("url", "")
        short = "^/" + url[len(root):].strip("/") if root and url.startswith(root) else url
        return f"{short}@{job.base.get('rev', '?')}"
    return f"{job.base.get('commit', '?')[:12]} ({job.base.get('branch', '')})"


def _result(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    res = jobs.job_dir(job.id) / "result"
    info = jobs.exit_info(job) or {}
    print(f"{job.id}  {st}  {agent_inbox.printable(job.title)}")
    print(f"base: {_base_words(job)}   attempts: {job.attempts}   engine: {info.get('engine') or job.engine or '-'}")
    if not (res / "exit.json").exists():
        print(f"no result yet ({st}); ws-agent show {job.id} has the log")
        return 0
    if st == "failed":
        why = (f"timed out after {job.timeout}" if info.get("timed_out") else str(info.get("reason") or "")
               or ("the engine reported an error" if info.get("is_error") else f"exit {info.get('exit_code')}"))
        print(f"failed: {why}")
        print("exec.log (end):")
        print("\n".join(f"  {line}" for line in agent_exec._tail(jobs.job_dir(job.id) / "exec.log", 10)))
    if st == "waiting":
        print(f"waiting: no allowed engine can run it until {info.get('reset_at') or '?'} ({info.get('reason') or ''}); "
              f"ws-agent retry {job.id} tries again")
    try:
        report = json.loads((res / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        report = None
    if isinstance(report, dict):
        print(f"report ({report.get('status')}):")
        print("\n".join(f"  {line}" for line in str(report.get("summary") or "").splitlines()))
        for key in ("tests", "notes"):
            if report.get(key):
                print(f"{key}: {report[key]}")
        if report.get("question"):
            print(f"question: {report['question']}")
            print(f"  answer with: ws-agent answer {job.id} \"...\"")
    _print_checks(info, res)
    _print_review(res)
    diff_path = res / "changes.diff"
    diff = diff_path.read_text(encoding="utf-8", errors="replace") if diff_path.exists() else ""
    stats = agent_exec._diff_stats(diff)
    print("Changes:" if stats else "Changes: none")
    print("\n".join(stats))
    print(f"patch: {diff_path}" + ("" if getattr(args, "diff", False) else f"  (printed by: ws-agent result {job.id} --diff)"))
    for name in ("manifest.txt", "props.txt", "status.txt"):
        if (res / name).exists():
            print(f"{name.split('.')[0]}: {res / name}")
    apply_txt = res / "apply.txt"
    if apply_txt.exists():
        print(apply_txt.read_text(encoding="utf-8").rstrip())
    warn_file = res / "warnings.txt"
    warnings = [*job.warnings, *(warn_file.read_text(encoding="utf-8").splitlines() if warn_file.exists() else [])]
    for w in warnings:
        print(f"warning: {w}")
    if getattr(args, "diff", False):
        manifest = res / "manifest.txt"
        if manifest.exists():
            print("--- manifest.txt")
            print(manifest.read_text(encoding="utf-8", errors="replace").rstrip())
        print("--- changes.diff")
        sys.stdout.write(diff if diff.endswith("\n") or not diff else diff + "\n")
    return 0


def _print_checks(info: dict[str, object], res: Path) -> None:
    verdict = info.get("checks")
    if verdict in (None, "none"):
        return
    rounds = info.get("fix_rounds") or 0
    print(f"checks: {verdict}" + (f" (after {rounds} fix round{'s' if rounds != 1 else ''})" if rounds else ""))
    try:
        runs = json.loads((res / "checks.json").read_text(encoding="utf-8"))
        text = (res / "checks.txt").read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        return
    blocks: dict[str, list[str]] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("$ "):
            current = line[2:].split("    (", 1)[0]
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line)
    for r in runs if isinstance(runs, list) else []:
        if not isinstance(r, dict) or (r.get("exit") == 0 and not r.get("timed_out")):
            continue
        how = "timed out" if r.get("timed_out") else f"exit {r.get('exit')}"
        print(f"  {r.get('cmd')}: {how}")
        tail = [ln for ln in blocks.get(str(r.get("cmd")), []) if ln.strip()][-20:]
        print("\n".join(f"    {ln}" for ln in tail))


def _print_review(res: Path) -> None:
    try:
        review = json.loads((res / "review.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    if not isinstance(review, dict):
        return
    print(f"review: {review.get('verdict')}: {review.get('summary')}")
    for f in review.get("findings") or []:
        if isinstance(f, dict):
            where = f"{f.get('file')}:{f.get('line')}" if f.get("line") is not None else str(f.get("file"))
            print(f"  {where}: {f.get('issue')}")


def _cancel(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    try:
        with jobs.queue_lock():   # serve recovers and requeues under it: it never writes an older copy back
            job = jobs.load(job.id)
            st = jobs.state(job, _tasks())
            if st not in ("queued", "running", "interrupted", "unknown", "waiting"):
                _err(f"ws-agent: {job.id} is {st}; nothing to cancel")
                return 3
            job.cancelled = True   # first, so an _exec that starts meanwhile refuses it
            jobs.save(job)
            confirmed = jobs.kill(job)
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    stopped = jobs.stop_run(job)   # outside the lock: it waits up to 10 s for the engine
    print(f"cancelled {job.id}{' and stopped its claude' if stopped else ''}; its working copy and log are kept "
          f"(ws-agent close {job.id} removes the copy)")
    if not confirmed:
        _err("warning: pueue didn't confirm removing the task; if it starts later it refuses to run (cancelled)")
    return 0


def _retry(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    q = jobs.pueue_status()
    st = jobs.state(job, q.tasks if q else None)
    if st not in ("failed", "interrupted", "waiting"):
        hint = f" (ws-agent answer {job.id} \"...\")" if st == "needs-you" else ""
        _err(f"ws-agent: {job.id} is {st}; only failed, interrupted or waiting jobs are retried{hint}")
        return 3
    if q is None:
        _err("ws-agent: pueued isn't running (systemctl --user start dev.mise.pueued)")
        return 1
    print(agent_exec.inspect(job), end="")
    try:
        with jobs.queue_lock():   # serve may be recovering this very job: one of you requeues it
            job = jobs.load(job.id)
            now_q = jobs.pueue_status()
            st = jobs.state(job, now_q.tasks if now_q else None)
            if st not in ("failed", "interrupted", "waiting"):
                _err(f"ws-agent: {job.id} is {st} now (serve may have requeued it); nothing retried")
                return 3
            res = jobs.job_dir(job.id) / "result"
            if (res / "exit.json").exists():
                (res / "exit.json").replace(res / f"exit-{job.attempts}.json")
            jobs.kill(job)   # drop the finished task from the queue
            jobs.enqueue(job, resume=True)
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    print(f"requeued {job.id} (task {job.pueue_id}): it resumes its session and reviews the state above first")
    if q.group == "Paused":
        _err("warning: the queue is paused; ws-agent resume starts it (other queued jobs start too)")
    return 0


def tell_job(job: jobs.Job, text: str, *, sender: str = "you") -> tuple[int, str]:
    """The person's words to a job, kept in its thread: delivered after its current turn if it
    runs, else by resuming its session now. (code, message): 0 told or requeued, 1 an error,
    2 an empty message, 3 refused."""
    if os.environ.get("WS_AGENT_JOB"):
        return 3, "ws-agent: this is a queued job; it can't message jobs (work directly)"
    text = text.strip()
    if not text:
        return 2, "ws-agent: the message is empty"
    try:
        with jobs.queue_lock():   # the executor checks for undelivered messages under it too
            q = jobs.pueue_status()
            st = jobs.state(job, q.tasks if q else None)
            if st in ("closed", "cancelled"):
                return 3, f"ws-agent: {job.id} is {st}; start a new job (ws-agent run)"
            jobs.post(job, sender, text)
            if st in ("running", "queued"):
                return 0, f"told {job.id}: delivered after its current turn"
            if q is None:
                return 1, ("ws-agent: pueued isn't running (systemctl --user start dev.mise.pueued); the message is "
                           f"kept and goes with ws-agent retry {job.id}")
            res = jobs.job_dir(job.id) / "result"
            for name in ("exit", "report"):
                cur = res / f"{name}.json"
                if cur.exists():
                    cur.replace(res / f"{name}-{job.attempts}.json")
            jobs.kill(job)   # drop the finished task from the queue
            jobs.enqueue(job, resume=True)
    except jobs.QueueError as e:
        return 1, str(e)
    msg = f"requeued {job.id} (task {job.pueue_id}): it resumes its session with your message"
    if q.group == "Paused":
        msg += "\nwarning: the queue is paused; ws-agent resume starts it (other queued jobs start too)"
    return 0, msg


def interrupt_job(job: jobs.Job, text: str) -> tuple[int, str]:
    """Stop the job's running turn and have it go on, in the same session, with the person's
    message. A job that isn't running gets the message as `tell` does. (code, message) as tell_job."""
    if os.environ.get("WS_AGENT_JOB"):
        return 3, "ws-agent: this is a queued job; it can't message jobs (work directly)"
    text = text.strip()
    if not text:
        return 2, "ws-agent: the message is empty"
    if jobs.live_run(job) is None:
        return tell_job(job, text)
    flag = jobs.job_dir(job.id) / "interrupt"
    jobs.post(job, "you", text)          # first, so the executor finds it when the turn ends
    flag.write_text(core.now_iso() + "\n", encoding="utf-8")
    if not jobs.stop_run(job, first=signal.SIGINT):
        flag.unlink(missing_ok=True)     # it finished by itself meanwhile: the message is delivered as a tell is
        return 0, f"told {job.id}: its turn had just ended; delivered next"
    return 0, f"interrupted {job.id}: its turn was stopped; it resumes its session with your message"


def _interrupt(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    code, msg = interrupt_job(job, " ".join(args.text))
    print(msg) if code == 0 else _err(msg)
    return code


def _tell(args: argparse.Namespace) -> int:
    if os.environ.get("WS_AGENT_JOB"):
        _err("ws-agent: this is a queued job; it can't message jobs (work directly)")
        return 3
    job = _load(args.id)
    if job is None:
        return 1
    code, msg = tell_job(job, " ".join(args.text))
    if code == 0:
        print(msg)
    else:
        _err(msg)
    return code


def _close(args: argparse.Namespace) -> int:
    if args.empty:
        if args.id:
            _err("ws-agent: close --empty takes no job id")
            return 2
        return _close_empty()
    if not args.id:
        _err("ws-agent: close needs a job id (or --empty: every succeeded job with an empty patch)")
        return 2
    job = _load(args.id)
    if job is None:
        return 1
    try:
        with jobs.queue_lock():   # serve requeues waiting jobs under it: never one this is closing
            job = jobs.load(job.id)
            st = jobs.state(job, _tasks())
            if st not in ("succeeded", "failed", "cancelled", "needs-you", "waiting"):
                _err(f"ws-agent: {job.id} is {st}; "
                     + ("retry or cancel it first" if st == "interrupted" else "wait, or cancel it"))
                return 3
            print(close_job(job))
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    return 0


def _close_empty() -> int:
    """Every succeeded job whose patch is empty (a review that changed nothing): their ids."""
    tasks = _tasks()
    closed = 0
    for job in jobs.all_jobs():
        if jobs.state(job, tasks) != "succeeded":
            continue
        res = jobs.job_dir(job.id) / "result"
        try:
            empty = not (res / "changes.diff").read_bytes().strip()
        except OSError:
            continue   # no patch recorded: not known to be empty
        try:
            left = [w for w in (res / "warnings.txt").read_text(encoding="utf-8").splitlines()
                    if w.strip() and not w.startswith("no changes")]
        except OSError:
            left = []
        if left or (res / "unversioned").is_dir() and any((res / "unversioned").iterdir()):
            continue   # an empty patch, but it left something (unversioned files, a conflict): yours to look at
        if empty:
            try:
                with jobs.queue_lock():
                    job = jobs.load(job.id)
                    if jobs.state(job, _tasks()) != "succeeded":
                        continue
                    close_job(job)
            except jobs.QueueError as e:
                _err(str(e))
                continue
            print(job.id)
            closed += 1
    _err(f"closed {closed} job{'s' if closed != 1 else ''} with an empty patch; their results stay")
    return 0


def close_job(job: jobs.Job) -> str:
    """Remove a finished job's working copy (and, for git, its worktree and branch); the result stays."""
    jd = jobs.job_dir(job.id)
    wc = jd / "wc"
    if job.vcs == "git":
        repo = str(core.expand(job.repo))
        if wc.exists():
            subprocess.run(["git", "-C", repo, "worktree", "remove", "--force", str(wc)], capture_output=True)
        subprocess.run(["git", "-C", repo, "branch", "-D", f"ws-agent/{job.id}"], capture_output=True)
    for d in (wc, jd / "bin", jd / "svn-config"):
        shutil.rmtree(d, ignore_errors=True)
    jobs.kill(job)
    job.closed = True
    jobs.save(job)
    return f"closed {job.id}: working copy removed; the result stays in {jd / 'result'}"


def _fleet(args: argparse.Namespace) -> int:
    from . import agent_fleet
    if args.action in ("add", "remove"):
        have = agent_registry.settings().fleet
        want = (*have, args.host or "") if args.action == "add" else tuple(h for h in have if h != args.host)
        try:
            agent_registry.set_fleet(want)
        except agent_registry.Refused as e:
            _err(str(e))
            return 3
        except ValueError as e:
            _err(str(e))
            return 2
        except agent_registry.Unreadable as e:
            _err(str(e))
            return 1
        print("fleet: " + (", ".join(agent_registry.settings().fleet) or "this host only"))
        return 0
    table = agent_fleet.table()
    if args.json:
        print(json.dumps([dict(zip(("host", "kind", "id", "state", "title", "repo"), r)) for r in table], indent=2))
        return 0
    if not table:
        print("no jobs and nothing in the inbox, here or on the fleet")
    for host, kind, ident, state, title, repo in table:
        what = state if kind != "inbox" else f"inbox:{state}"
        print(f"{host:<12} {ident:<10} {what:<14} {title}" + (f"  ({repo})" if repo else ""))
    return 0


def _on(args: argparse.Namespace) -> int:
    """`ws-agent <words>` on a fleet host (the fleet view's keys), or here for `local`."""
    from . import agent_fleet
    if os.environ.get("WS_AGENT_JOB"):
        _err("ws-agent: this is a queued job; it can't reach other hosts (work directly)")
        return 3
    try:
        argv = agent_fleet.on(args.host, list(args.words), tty=sys.stdin.isatty())
    except KeyError as e:
        _err(str(e.args[0]))
        return 3
    if argv is None:
        return main(list(args.words))
    return subprocess.run(argv).returncode


def _ui(args: argparse.Namespace) -> int:
    from . import agent_fleet, agent_ui
    source = agent_fleet.rows if args.fleet else agent_ui.rows
    if args.rows:
        for r in source():
            print(r)
        return 0
    fzf = core.which("fzf")
    if not fzf:
        _err("ws-agent: fzf isn't installed (mise install fzf); ws-agent ls and ws-agent inbox show the same lists")
        return 1
    argv = agent_ui.fzf_argv(core.shell_join(core.self_argv("agent")), fleet=args.fleet)
    argv[0] = fzf
    rows = source()
    if not rows:
        print("no jobs and nothing in the inbox")
        return 0
    r = subprocess.run(argv, input="\n".join(rows) + "\n", text=True)
    return 0 if r.returncode in (0, 1, 130) else r.returncode   # picked, no match, esc


def _serve(args: argparse.Namespace) -> int:
    if os.environ.get("WS_AGENT_JOB"):
        _err("ws-agent: this is a queued job; it can't run serve (work directly)")
        return 3
    if os.environ.get("CLAUDECODE") == "1" and not args.once:
        # The loop starts jobs on its own: it runs as the person's service, not from a session.
        _err("ws-agent: a Claude Code session doesn't start the serve loop; the service runs it "
             "(systemctl --user start dev.mise.ws-agent-serve), or use serve --once for one pass")
        return 3
    return agent_serve.serve(once=args.once)


def _pause(_: argparse.Namespace) -> int:
    try:
        jobs.pause()
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    print(f"paused pueue group {jobs.GROUP}: running jobs finish, queued ones wait (ws-agent resume)")
    return 0


def _resume(_: argparse.Namespace) -> int:
    try:
        jobs.resume()
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    print(f"started pueue group {jobs.GROUP}")
    return 0


# --- doctor ---------------------------------------------------------------------------------

def _doctor(args: argparse.Namespace) -> int:
    del args
    problems = 0

    def row(ok: bool, text: str) -> None:
        nonlocal problems
        problems += not ok
        print(f"{'ok' if ok else '!!'}  {text}")

    repos_now, _ = agent_registry.load()
    wanted = ["claude", *sorted({e for r in repos_now.values() for e in r.engines} - {"claude"})]
    for name in wanted:
        engine = engines.ENGINES[name]
        until = engines.cooling(name)
        cool = f"; cooling down until {until} (usage limit)" if until else ""
        problem = engine.available()
        path = core.which(name) or "-"
        if problem:
            row(False, f"engine {name}: {problem}{cool}")
            continue
        detail = ""
        if name == "claude":   # the method and plan only: never the account's email or organization
            try:
                r = subprocess.run([path, "auth", "status"], capture_output=True, text=True, timeout=30)
                info = json.loads(r.stdout[r.stdout.find("{"):]) if "{" in r.stdout else {}
            except (OSError, subprocess.TimeoutExpired, ValueError):
                info = {}
            detail = (f", signed in via {info.get('authMethod', '?')} ({info.get('apiProvider', '?')}, "
                      f"plan {info.get('subscriptionType', '?')})")
        row(True, f"engine {name}: {path}{detail}{cool}")
    why = agent_sandbox.probe(force=True)
    row(why is None, f"sandbox: {'bwrap works here (outer and nested)' if why is None else why}")
    around = [core.tilde(p) for p in agent_sandbox.surrounding_paths()]
    hide = [core.tilde(p) for p in agent_registry.settings().hide]
    row(True, "sandbox hides $HOME, /tmp, other jobs, the registered copies"
              + (f", the folders around those outside $HOME ({', '.join(around)})" if around else "")
              + (f", [sandbox] hide ({', '.join(hide)})" if hide else "")
              + "; other code outside $HOME stays readable to jobs: list its folders in [sandbox] hide")
    q = jobs.pueue_status()
    _, parallel = agent_registry.load()
    if q is None:
        row(False, "pueued: not running (systemctl --user start dev.mise.pueued)")
    else:
        group = f"group {jobs.GROUP} {q.group.lower()}, {q.parallel} at a time" if q.group else \
            f"group {jobs.GROUP} not created yet (the first run makes it, {parallel} at a time)"
        row(q.group != "Paused", f"pueued: running; {group}{' (ws-agent resume)' if q.group == 'Paused' else ''}")
    for tool, why in (("svn", "SVN jobs can't run"), ("git", "git jobs can't run"), ("timeout", "jobs can't be time-limited")):
        path = core.which(tool)
        row(bool(path), f"{tool}: {path}" if path else f"{tool}: not installed ({why})")
    repos, _ = agent_registry.load()
    row(True, f"registry: {core.tilde(agent_registry.registry_path())}, {len(repos)} repositories allowed")
    jd = jobs.jobs_dir()
    row(True, f"jobs: {core.tilde(jd)}, {len(jobs.all_jobs())} jobs, {len(agent_inbox.items())} open inbox items")
    usage = agent_disk.usage()
    if usage is not None:
        where, free, total = usage
        row(agent_disk.low() is None, f"disk: {free >> 30} GiB free ({int(100 * free / total) if total else 0}%) on "
            f"{core.tilde(where)}; source jobs don't start under {agent_disk.threshold()}")
    if not agent_serve.configured():
        row(True, "serve: no sources configured (ws-agent watch, ws-agent github)")
    elif agent_serve.up():
        st = agent_serve.status()
        ago = int(time.time() - float(st.get("last_tick") or 0))  # type: ignore[arg-type]
        row(True, f"serve: up since {st.get('started')} (last tick {ago} s ago)"
            + (f"; last error: {agent_inbox.printable(str(st['last_error']))}" if st.get("last_error") else ""))
    else:
        row(False, "serve: down (systemctl --user start dev.mise.ws-agent-serve)")
    return 1 if problems else 0


def _events(args: argparse.Namespace) -> int:
    """The UserPromptSubmit hook's lines: the hook JSON on stdin (session_id, cwd), the events this
    session hasn't seen on stdout. Files only (no pueue), and never an error."""
    del args
    try:
        data = json.loads(sys.stdin.read() or "{}")
        if not isinstance(data, dict):
            return 0
        p = vcs.probe(Path(str(data.get("cwd") or os.getcwd())))
        key = core.tilde(p.root) if p.root else ""
        for line in agent_events.lines_for(str(data.get("session_id") or ""), key):
            print(line)
    except Exception:  # noqa: BLE001 - a prompt hook must never fail the prompt
        pass
    return 0


def _exec(args: argparse.Namespace) -> int:
    return agent_exec.execute(args.id, resume=args.resume)


# --- the command line --------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="ws agent", description="Queued headless Claude Code jobs (see ws-agent --help).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("context", help="the one-line orchestration summary").set_defaults(fn=lambda a: print(context_line(Path.cwd())) or 0)
    sub.add_parser("events", help="job events a session hasn't seen (UserPromptSubmit hook)").set_defaults(fn=_events)
    r = sub.add_parser("route", help="this repository's execution options")
    r.add_argument("--json", action="store_true")
    r.add_argument("--repo")
    r.set_defaults(fn=_route)
    a = sub.add_parser("allow", help="let queued jobs use a repository (your own terminal only)")
    a.add_argument("path")
    a.add_argument("--command", action="append", help="an extra Bash permission rule for jobs, e.g. 'make *'")
    a.add_argument("--engine", action="append", choices=agent_registry.KNOWN_ENGINES,
                   help="an engine jobs may run on, in preference order (repeatable; default claude)")
    a.add_argument("--check", action="append", help="a command ws-agent runs on each job's result (repeatable)")
    a.add_argument("--fix-rounds", type=int, default=1, help="engine rounds to fix failing checks (default 1)")
    a.add_argument("--review", choices=agent_registry.KNOWN_ENGINES, help="a second-opinion review by this engine")
    a.add_argument("--network", action="store_true", help="let the agent's commands and the checks use the network")
    a.set_defaults(fn=_allow)
    pt = sub.add_parser("publish-to", help="what ws-agent may write back for a repository (your own terminal only)")
    pt.add_argument("path")
    pt.add_argument("--mode", default="manual", help="off, manual (default: only ws-agent publish <id>) or auto")
    pt.add_argument("--comment", action="store_true", help="GitHub: the report as a comment on the issue or PR that asked")
    pt.add_argument("--draft-pr", action="store_true", help="GitHub: the patch on a new branch, as a draft pull request")
    pt.add_argument("--svn-branch", help="SVN: the parent of new branches, e.g. ^/branches/ws-agent")
    pt.set_defaults(fn=_publish_to)
    pb = sub.add_parser("publish", help="write a finished job's result back, as its repository's publish settings say")
    pb.add_argument("id")
    pb.add_argument("--even-failing", action="store_true", help="although its checks failed")
    pb.add_argument("--dry-run", action="store_true", help="say what would be written; write nothing")
    pb.add_argument("--allow-workflows", action="store_true",
                    help="although its patch touches .github/ (workflows run with the repository's secrets)")
    pb.set_defaults(fn=_publish)
    d = sub.add_parser("disallow")
    d.add_argument("path")
    d.set_defaults(fn=_disallow)
    w = sub.add_parser("watch", help="turn new SVN revisions into candidates (your own terminal only)")
    w.add_argument("path")
    w.add_argument("--url", action="append", help="a URL to watch, e.g. ^/trunk (repeatable)")
    w.add_argument("--mode", default="observe", help="off, observe (default: inbox only) or act")
    w.add_argument("--author", action="append", help="only these authors' revisions (repeatable)")
    w.add_argument("--rule", action="append", help="what to look for, in plain words (repeatable)")
    w.add_argument("--interval", default="5m")
    w.set_defaults(fn=_watch)
    uw = sub.add_parser("unwatch")
    uw.add_argument("path")
    uw.set_defaults(fn=_watch)
    gh = sub.add_parser("github", help="take /agent requests from GitHub comments (your own terminal only)")
    gh.add_argument("path")
    gh.add_argument("--mode", default="observe", help="off, observe (default: inbox only) or act")
    gh.add_argument("--login", action="append", help="who may ask (repeatable; default: your gh login)")
    gh.set_defaults(fn=_github)
    ugh = sub.add_parser("ungithub")
    ugh.add_argument("path")
    ugh.set_defaults(fn=_github)
    sub.add_parser("repos").set_defaults(fn=_repos)
    run = sub.add_parser("run", help="queue a job")
    run.add_argument("--title", required=True)
    g = run.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt")
    g.add_argument("--prompt-file")
    run.add_argument("--repo")
    run.add_argument("--rev")
    run.add_argument("--timeout", default="2h")
    run.add_argument("--paths", action="append", help="a path or glob the job will change (repeatable)")
    run.add_argument("--force", action="store_true")
    run.set_defaults(fn=_run_job)
    ls = sub.add_parser("ls")
    ls.add_argument("--repo")
    ls.add_argument("--all", action="store_true")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(fn=_ls)
    for name, fn in (("show", _show), ("result", _result), ("cancel", _cancel), ("retry", _retry)):
        p = sub.add_parser(name)
        p.add_argument("id")
        if name == "result":
            p.add_argument("--diff", action="store_true", help="also print the manifest and the whole patch")
        p.set_defaults(fn=fn)
    cl = sub.add_parser("close", help="after review: delete a job's working copy, keep its result")
    cl.add_argument("id", nargs="?")
    cl.add_argument("--empty", action="store_true", help="every succeeded job whose patch is empty")
    cl.set_defaults(fn=_close)
    ui = sub.add_parser("ui", help="jobs and the inbox in one fzf list")
    ui.add_argument("--rows", action="store_true", help="print the list fzf shows, and exit")
    ui.add_argument("--fleet", action="store_true", help="this host and the fleet's hosts (ws-agent fleet add)")
    ui.set_defaults(fn=_ui)
    fl = sub.add_parser("fleet", help="jobs and inbox items here and on your other hosts, over your SSH")
    fl.add_argument("action", nargs="?", choices=("add", "remove"), help="change the host list (your own terminal only)")
    fl.add_argument("host", nargs="?")
    fl.add_argument("--json", action="store_true")
    fl.set_defaults(fn=_fleet)
    on = sub.add_parser("_on")
    on.add_argument("host")
    on.add_argument("words", nargs=argparse.REMAINDER)
    on.set_defaults(fn=_on)
    sv = sub.add_parser("serve", help="the always-on loop: recovery and the watched sources (the ws-agent-serve service)")
    sv.add_argument("--once", action="store_true", help="one pass, then exit")
    sv.set_defaults(fn=_serve)
    for name in ("tell", "answer"):
        t = sub.add_parser(name, help="send the job a message (answer: to the question it asked)")
        t.add_argument("id")
        t.add_argument("text", nargs="+")
        t.set_defaults(fn=_tell)
    it = sub.add_parser("interrupt", help="stop the job's running turn and resume it with your message")
    it.add_argument("id")
    it.add_argument("text", nargs="+")
    it.set_defaults(fn=_interrupt)
    ib = sub.add_parser("inbox", help="what sources found, waiting for you to accept or dismiss")
    ib.add_argument("--all", action="store_true", help="accepted and dismissed items too")
    ib.add_argument("--json", action="store_true")
    ib.add_argument("--show", metavar="ID", help="one item in full")
    ib.set_defaults(fn=_inbox)
    acc = sub.add_parser("accept", help="queue an inbox item as a job")
    acc.add_argument("id")
    acc.add_argument("--note", help="your words, added to the job's prompt")
    acc.set_defaults(fn=_accept)
    dis = sub.add_parser("dismiss")
    dis.add_argument("id")
    dis.set_defaults(fn=_dismiss)
    sub.add_parser("pause").set_defaults(fn=_pause)
    sub.add_parser("resume").set_defaults(fn=_resume)
    sub.add_parser("doctor").set_defaults(fn=_doctor)
    ex = sub.add_parser("_exec")
    ex.add_argument("id")
    ex.add_argument("--resume", action="store_true")
    ex.set_defaults(fn=_exec)
    return ap


SUBCOMMANDS = ("context", "events", "route", "allow", "disallow", "watch", "unwatch", "github", "ungithub", "publish-to", "publish", "repos", "run",
               "ls", "show", "result", "cancel", "retry", "close", "tell", "answer", "interrupt", "inbox", "accept", "dismiss", "ui", "fleet",
               "serve", "pause", "resume", "doctor", "--help")


def decode_argv(packed: str) -> list[str]:
    """The arguments a Windows forwarder sent: base64 of each argument followed by a NUL. They
    cross WSL's login shell as that one inert word, never as text a shell could parse."""
    raw = base64.b64decode(packed, validate=True).decode("utf-8")
    return raw.split("\0")[:-1] if raw.endswith("\0") else []


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--argv-b64":
        try:
            argv = decode_argv(argv[1])
        except ValueError:
            _err("ws-agent: --argv-b64 isn't what a forwarder sends")
            return 2
    try:
        args = _parser().parse_args(argv)
    except SystemExit as e:
        return int(e.code or 0)
    return int(args.fn(args) or 0)
