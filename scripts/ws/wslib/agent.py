"""`ws agent` (also `ws-agent`): queued headless Claude Code jobs, and the orchestration line.

A job is the minimum coordination pueue lacks: a record of the base it starts from (SVN
URL@rev or git commit, taken when you ask), a private working copy, a resumable Claude
session, a derived state and the review artifacts. pueue does the queueing, concurrency
(group `agents`), persistence, logs and killing; Claude Code does the work.

    context                 the one-line [orchestration] summary (SessionStart hook)
    route [--json]          this repository: VCS, base, allowed?, queue, jobs, Super-agent
    allow <path> [--command RULE]... | disallow <path> | repos
                            which repositories jobs may use (refused inside Claude Code)
    run --title T (--prompt TEXT | --prompt-file F) [--repo P] [--rev R] [--timeout 2h]
        [--paths GLOB]... [--force]
    ls [--repo P | --all] [--json] | show <id> | result <id>
    cancel <id> | retry <id> | close <id> | pause | resume | doctor
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import agent_exec, agent_registry, core, jobs, vcs

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


def _here(repo_key: str, tasks: dict[int, str] | None) -> str:
    rows = []
    for j in jobs.all_jobs():
        if j.repo != repo_key:
            continue
        st = jobs.state(j, tasks)
        if st == "closed":
            continue
        rows.append(f"{j.id} {st}{' (review)' if st == 'succeeded' else ''}")
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
            return "[orchestration] no repository here | superagent: none"
        _, parallel = agent_registry.load()
        allowed = agent_registry.find(p.root) is not None
        q = jobs.pueue_status() if allowed or jobs.all_jobs() else None
        parts = [f"[orchestration] {_head(p)}",
                 f"jobs: allowed; {_queue_words(q, parallel)}" if allowed else "jobs: not allowed (ws-agent allow)",
                 _here(core.tilde(p.root), q.tasks if q else None),
                 "superagent: none"]
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
            "jobs": here, "superagent": "none"}
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
    print("DeepSeek Super-agent: none registered for this repository")
    return 0


# --- registry ---------------------------------------------------------------------------

def _allow(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    if p.kind == "none" or p.root is None:
        _err(f"ws-agent: {args.path} isn't in a git or SVN working copy")
        return 3
    try:
        repo = agent_registry.allow(p.root, p.kind, args.command or [])
    except agent_registry.Refused as e:
        _err(str(e))
        return 3
    print(f"allowed: {core.tilde(repo.path)} ({repo.vcs})")
    if repo.commands:
        print(f"jobs may also run: {', '.join(repo.commands)}")
    print("Queued jobs run headless Claude Code with this host's login in a private copy at a recorded base;\n"
          "they never commit, push or otherwise write to the repository. ws-agent disallow undoes this.")
    return 0


def _disallow(args: argparse.Namespace) -> int:
    p = vcs.probe(Path(args.path))
    root = p.root or Path(args.path).resolve()
    try:
        removed = agent_registry.disallow(root)
    except agent_registry.Refused as e:
        _err(str(e))
        return 3
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
        extra = f"  commands: {', '.join(r.commands)}" if r.commands else ""
        print(f"{key}  ({r.vcs}, since {r.allowed_at[:10]}){extra}")
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


def _base(p: vcs.Probe, rev: str | None, warnings: list[str]) -> dict[str, str] | None:
    root = core.tilde(p.root) if p.root else "?"
    if p.kind == "svn":
        if (p.mixed or p.switched) and not rev:
            why = "mixed revisions" if p.mixed else "a switched subtree"
            _err(f"ws-agent: {root} has {why} ({p.version}); name the base with --rev <N>")
            return None
        base = {"url": p.url, "repos_root": p.repos_root, "rev": rev or p.rev}
        if p.modified:
            warnings.append(f"local modifications in {root} are not included: the job starts from "
                            f"{vcs.short_url(p)}@{base['rev']}")
        return base
    commit = p.rev
    if rev:
        r = subprocess.run(["git", "-C", str(p.root), "rev-parse", "--verify", "-q", f"{rev}^{{commit}}"],
                           capture_output=True, text=True)
        commit = r.stdout.strip() if r.returncode == 0 else ""
        if not commit:
            _err(f"ws-agent: {rev!r} isn't a commit in {root}")
            return None
    if not commit:
        _err(f"ws-agent: {root} has no commits yet")
        return None
    if p.modified:
        warnings.append(f"uncommitted changes in {root} are not included: the job starts from {commit[:12]}")
    return {"commit": commit, "branch": p.branch}


def _run_job(args: argparse.Namespace) -> int:
    if os.environ.get("WS_AGENT_JOB"):
        _err("ws-agent: this is a queued job; it can't queue jobs (work directly)")
        return 3
    prompt = _prompt(args)
    if prompt is None:
        return 1
    if not prompt.strip():
        _err("ws-agent: the prompt is empty")
        return 2
    p = vcs.probe(Path(args.repo) if args.repo else Path.cwd(), thorough=True)
    if p.kind == "none" or p.root is None:
        _err(f"ws-agent: {args.repo or Path.cwd()} isn't in a git or SVN working copy")
        return 3
    key = core.tilde(p.root)
    if agent_registry.find(p.root) is None:
        _err(f"ws-agent: {key} isn't allowed for queued jobs; run 'ws-agent allow {key}' in your own terminal")
        return 3
    warnings: list[str] = []
    base = _base(p, args.rev, warnings)
    if base is None:
        return 3
    q = jobs.pueue_status()
    if q is None:
        _err("ws-agent: pueued isn't running (systemctl --user start dev.mise.pueued)")
        return 1
    sha = hashlib.sha256(prompt.strip().encode("utf-8")).hexdigest()
    _, parallel = agent_registry.load()
    try:
        with jobs.queue_lock():   # the duplicate check, the record and the enqueue as one step
            all_ = jobs.all_jobs()
            dup = jobs.duplicate(key, sha, all_, q.tasks)
            if dup and not args.force:
                st = jobs.state(dup, q.tasks)
                print(dup.id)
                hint = (f"ws-agent retry {dup.id} continues it" if st in ("failed", "interrupted")
                        else f"ws-agent result {dup.id} once it's done")
                _err(f"ws-agent: job {dup.id} already does this ({st}); {hint}; --force queues another")
                return 3
            for other in jobs.overlaps(key, args.paths or [], all_, q.tasks):
                warnings.append(f"job {other.id} ({jobs.state(other, q.tasks)}) also claims {', '.join(other.paths)}: "
                                "review the two patches together")
            job = jobs.Job(id=jobs.new_id(), title=args.title, repo=key, vcs=p.kind, base=base, prompt_sha=sha,
                           paths=list(args.paths or []), created=core.now_iso(), session_id="", timeout=args.timeout,
                           warnings=warnings)
            try:
                jobs.ensure_group(parallel)
                jobs.save(job)
                (jobs.job_dir(job.id) / "prompt.md").write_text(prompt, encoding="utf-8")
                jobs.enqueue(job, resume=False)
            except jobs.QueueError:
                shutil.rmtree(jobs.job_dir(job.id), ignore_errors=True)
                raise
    except jobs.QueueError as e:
        _err(str(e))
        return 1
    print(job.id)
    for w in warnings:
        _err(f"warning: {w}")
    _err(f"queued {job.id} in pueue group {jobs.GROUP} (task {job.pueue_id}); ws-agent ls, ws-agent result {job.id}")
    if q.group == "Paused":
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
        rows.append({"id": j.id, "state": st, "title": j.title, "repo": j.repo, "vcs": j.vcs, "created": j.created,
                     "attempts": j.attempts, "pueue_id": j.pueue_id})
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print("no jobs" + (f" in {key}" if key else ""))
        return 0
    for r in rows:
        where = "" if key else f"  {r['repo']}"
        print(f"{r['id']}  {r['state']:<11} {r['created'][:16]}  {r['title']}{where}")
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
    print(f"{job.id}  {st}  {job.title}")
    print(f"base: {_base_words(job)}   attempts: {job.attempts}")
    if not (res / "exit.json").exists():
        print(f"no result yet ({st}); ws-agent show {job.id} has the log")
        return 0
    if st == "failed":
        info = jobs.exit_info(job) or {}
        why = (f"timed out after {job.timeout}" if info.get("timed_out") else str(info.get("reason") or "")
               or ("Claude reported an error" if info.get("is_error") else f"exit {info.get('exit_code')}"))
        print(f"failed: {why}")
        print("exec.log (end):")
        print("\n".join(f"  {line}" for line in agent_exec._tail(jobs.job_dir(job.id) / "exec.log", 10)))
    claude = agent_exec._claude_result(res / "claude.json")
    if claude.get("result"):
        print("Claude's report:")
        print("\n".join(f"  {line}" for line in str(claude["result"]).splitlines()))
    diff_path = res / "changes.diff"
    diff = diff_path.read_text(encoding="utf-8", errors="replace") if diff_path.exists() else ""
    stats = agent_exec._diff_stats(diff)
    print("Changes:" if stats else "Changes: none")
    print("\n".join(stats))
    print(f"patch: {diff_path}")
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
    return 0


def _cancel(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    if st not in ("queued", "running", "interrupted", "unknown"):
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
    if st not in ("failed", "interrupted"):
        _err(f"ws-agent: {job.id} is {st}; only failed or interrupted jobs are retried")
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


def _close(args: argparse.Namespace) -> int:
    job = _load(args.id)
    if job is None:
        return 1
    st = jobs.state(job, _tasks())
    if st not in ("succeeded", "failed", "cancelled"):
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

def _doctor(_: argparse.Namespace) -> int:
    problems = 0

    def row(ok: bool, text: str) -> None:
        nonlocal problems
        problems += not ok
        print(f"{'ok' if ok else '!!'}  {text}")

    claude = core.which("claude")
    if not claude:
        row(False, "claude: not installed (queued jobs need Claude Code)")
    else:
        r = subprocess.run([claude, "auth", "status"], capture_output=True, text=True, timeout=30)
        try:
            info = json.loads(r.stdout[r.stdout.find("{"):]) if "{" in r.stdout else {}
        except ValueError:
            info = {}
        if info.get("loggedIn"):
            row(True, f"claude: {claude}, signed in via {info.get('authMethod', '?')} "
                      f"({info.get('apiProvider', '?')}, plan {info.get('subscriptionType', '?')})")
        else:
            row(False, f"claude: {claude}, not signed in (claude auth login)")
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


def _exec(args: argparse.Namespace) -> int:
    return agent_exec.execute(args.id, resume=args.resume)


# --- the command line --------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="ws agent", description="Queued headless Claude Code jobs (see ws-agent --help).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("context", help="the one-line orchestration summary").set_defaults(fn=lambda a: print(context_line(Path.cwd())) or 0)
    r = sub.add_parser("route", help="this repository's execution options")
    r.add_argument("--json", action="store_true")
    r.add_argument("--repo")
    r.set_defaults(fn=_route)
    a = sub.add_parser("allow", help="let queued jobs use a repository (your own terminal only)")
    a.add_argument("path")
    a.add_argument("--command", action="append", help="an extra Bash permission rule for jobs, e.g. 'make *'")
    a.set_defaults(fn=_allow)
    d = sub.add_parser("disallow")
    d.add_argument("path")
    d.set_defaults(fn=_disallow)
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
        p.set_defaults(fn=fn)
    sub.add_parser("pause").set_defaults(fn=_pause)
    sub.add_parser("resume").set_defaults(fn=_resume)
    sub.add_parser("doctor").set_defaults(fn=_doctor)
    ex = sub.add_parser("_exec")
    ex.add_argument("id")
    ex.add_argument("--resume", action="store_true")
    ex.set_defaults(fn=_exec)
    return ap


SUBCOMMANDS = ("context", "route", "allow", "disallow", "repos", "run", "ls", "show", "result", "cancel", "retry", "close",
               "pause", "resume", "doctor", "--help")


def main(argv: list[str]) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as e:
        return int(e.code or 0)
    return int(args.fn(args) or 0)
