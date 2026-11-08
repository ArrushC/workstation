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
    cancel <id> | retry <id> | close <id> | pause | resume | doctor
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import agent_events, agent_exec, agent_registry, agent_sandbox, core, engines, jobs, vcs

MAX_CONTEXT = 400


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
        print(f"  {row['id']}  {row['state']:<11} {row['title']}")
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
    rc, repo = _source_change(agent_registry.set_watch, root, watch)
    if repo is not None:
        print(f"{'watching' if watch else 'no longer watching'}: {core.tilde(root)}"
              + (f" ({', '.join(watch.urls)}, {watch.mode})" if watch else ""))
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
    rc, repo = _source_change(agent_registry.set_github, root, src)
    if repo is not None:
        print(f"{'taking /agent requests' if src else 'no longer taking requests'}: {core.tilde(root)}"
              + (f" ({src.slug}, {src.mode}, logins: {', '.join(src.logins)})" if src else ""))
    return rc


def _disallow(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    try:
        removed = agent_registry.disallow(root)
    except agent_registry.Refused as e:
        _err(str(e))
        return 3
    except agent_registry.Unreadable as e:
        _err(str(e))
        return 1
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
    p = vcs.probe(root, thorough=True)
    if p.kind == "none" or p.root is None:
        return Queued(None, f"ws-agent: {root} isn't in a git or SVN working copy", 3, [])
    key = core.tilde(p.root)
    if agent_registry.find(p.root) is None:
        return Queued(None, f"ws-agent: {key} isn't allowed for queued jobs; run 'ws-agent allow {key}' in your own "
                      "terminal", 3, [])
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
        print(f"{r['id']}  {r['state']:<11} {checks:<14} {r['engine']:<7} {r['created'][:16]}  {r['title']}{where}")
    if tasks is None:
        _err("warning: pueued isn't running, so live states are unknown")
    return 0


def _show(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    jd = jobs.job_dir(job.id)
    print(f"{job.id}  {st}  {job.title}")
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
    print(f"{job.id}  {st}  {job.title}")
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
    st = jobs.state(job, _tasks())
    if st not in ("queued", "running", "interrupted", "unknown", "waiting"):
        _err(f"ws-agent: {job.id} is {st}; nothing to cancel")
        return 3
    job.cancelled = True   # first, so an _exec that starts meanwhile refuses it
    jobs.save(job)
    confirmed = jobs.kill(job)
    stopped = jobs.stop_run(job)
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
    res = jobs.job_dir(job.id) / "result"
    if (res / "exit.json").exists():
        (res / "exit.json").replace(res / f"exit-{job.attempts}.json")
    jobs.kill(job)   # drop the finished task from the queue
    try:
        jobs.enqueue(job, resume=True)
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    print(f"requeued {job.id} (task {job.pueue_id}): it resumes its session and reviews the state above first")
    if q.group == "Paused":
        _err("warning: the queue is paused; ws-agent resume starts it (other queued jobs start too)")
    return 0


def tell_job(job: jobs.Job, text: str) -> tuple[int, str]:
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
            jobs.post(job, "you", text)
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
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    if st not in ("succeeded", "failed", "cancelled", "needs-you", "waiting"):
        _err(f"ws-agent: {job.id} is {st}; " + ("retry or cancel it first" if st == "interrupted" else "wait, or cancel it"))
        return 3
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
    print(f"closed {job.id}: working copy removed; the result stays in {jd / 'result'}")
    return 0


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
            r = subprocess.run([path, "auth", "status"], capture_output=True, text=True, timeout=30)
            try:
                info = json.loads(r.stdout[r.stdout.find("{"):]) if "{" in r.stdout else {}
            except ValueError:
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
    probe_dir = jd if jd.exists() else core.state_dir() if core.state_dir().exists() else core.home()
    free = shutil.disk_usage(probe_dir).free
    row(free > 5 << 30, f"jobs: {core.tilde(jd)}, {len(jobs.all_jobs())} jobs, {free >> 30} GiB free")
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
    for name, fn in (("show", _show), ("result", _result), ("cancel", _cancel), ("retry", _retry), ("close", _close)):
        p = sub.add_parser(name)
        p.add_argument("id")
        if name == "result":
            p.add_argument("--diff", action="store_true", help="also print the manifest and the whole patch")
        p.set_defaults(fn=fn)
    for name in ("tell", "answer"):
        t = sub.add_parser(name, help="send the job a message (answer: to the question it asked)")
        t.add_argument("id")
        t.add_argument("text", nargs="+")
        t.set_defaults(fn=_tell)
    sub.add_parser("pause").set_defaults(fn=_pause)
    sub.add_parser("resume").set_defaults(fn=_resume)
    sub.add_parser("doctor").set_defaults(fn=_doctor)
    ex = sub.add_parser("_exec")
    ex.add_argument("id")
    ex.add_argument("--resume", action="store_true")
    ex.set_defaults(fn=_exec)
    return ap


SUBCOMMANDS = ("context", "events", "route", "allow", "disallow", "watch", "unwatch", "github", "ungithub", "repos", "run",
               "ls", "show", "result", "cancel", "retry", "close", "tell", "answer", "pause", "resume", "doctor", "--help")


def main(argv: list[str]) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as e:
        return int(e.code or 0)
    return int(args.fn(args) or 0)
