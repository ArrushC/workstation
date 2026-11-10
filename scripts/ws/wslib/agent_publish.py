"""Publishing: the one place ws-agent writes to a server.

A finished job's result can go back to where the request came from, when the repository's
`[repo.*.publish]` settings (the person's, set in their own terminal) name that kind of write:

- `comment`: the job's report as a comment on the GitHub issue or pull request that asked;
- `draft_pr`: the job's patch as one commit on a NEW branch `ws-agent/<id>`, and a draft PR;
- `svn_branch`: the job's patch committed to a NEW SVN branch under that parent. Never for a
  job a source made (reviews stay local): only `ws-agent publish <id>` on the person's own job.

Rules every path goes through (`allowed`): the repository still allows jobs and this kind; the
job succeeded; published automatically only if it came from a source and its checks passed;
once per job and kind (`published.json`); at most AUTO_CAP automatic publishes a day per source.
It only ever creates something new: no existing branch, trunk or default branch is written, no
force, no merge. The engine never publishes: this runs after the job, outside the sandbox, with
the person's own credentials.

What is posted is fixed text plus the person's own instruction. The job's summary is model
output about someone else's code: it is quoted, cut, and can't mention or link anyone.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from . import agent_admit, agent_inbox, agent_registry, agent_sources, core, jobs

KINDS = ("comment", "draft_pr", "svn_branch")
AUTO_CAP = 5            # automatic publishes a day per source
MAX_TRIES = 3           # automatic attempts per job and kind before it is left for the person
SUMMARY_MAX = 2000
FILES_MAX = 40
TIMEOUT = 300


class PublishError(Exception):
    """A write that didn't happen (refused by a guard, or the server said no)."""


@dataclass
class Target:
    slug: str = ""        # GitHub owner/name
    number: int = 0       # the issue or pull request that asked (0: none)


# --- the record ----------------------------------------------------------------------------

def _record_path(job: jobs.Job) -> Path:
    return jobs.job_dir(job.id) / "result" / "published.json"


def record(job: jobs.Job) -> dict[str, dict[str, object]]:
    try:
        data = json.loads(_record_path(job).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}


def _save(job: jobs.Job, kind: str, entry: dict[str, object]) -> None:
    data = record(job)
    data[kind] = {**data.get(kind, {}), **entry}
    core.atomic_write(_record_path(job), (json.dumps(data, indent=2) + "\n").encode("utf-8"))


def published(job: jobs.Job, kind: str) -> str:
    """The URL of what was published for this job and kind, or ""."""
    return str(record(job).get(kind, {}).get("url") or "")


@contextlib.contextmanager
def _lock(job: jobs.Job) -> Iterator[None]:
    """One publisher per job (serve and the person's `publish` at once): the other is refused."""
    res = jobs.job_dir(job.id) / "result"
    res.mkdir(parents=True, exist_ok=True)
    with open(res / "publish.lock", "a+") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PublishError(f"ws-agent: {job.id} is being published right now") from None
        yield


# --- what a job can publish ------------------------------------------------------------------

def target(job: jobs.Job) -> Target:
    """The GitHub issue or PR a source job answers: its slug from the origin (gh:<slug>:...), its
    number from the source's threads map (remember_thread)."""
    if not job.origin.startswith("gh:"):
        return Target()
    slug = job.origin[3:].rsplit(":", 1)[0]
    threads = agent_sources.source_state().get(f"gh:{slug}", {}).get("threads")
    for key, jid in (threads.items() if isinstance(threads, dict) else []):
        if jid == job.id and str(key).lstrip("#").isdigit():
            return Target(slug, int(str(key).lstrip("#")))
    return Target(slug, 0)


def _patch(job: jobs.Job) -> bytes:
    try:
        return (jobs.job_dir(job.id) / "result" / "changes.diff").read_bytes()
    except OSError:
        return b""


def kinds_for(job: jobs.Job, entry: agent_registry.Repo) -> list[str]:
    """The kinds this repository's settings name that make sense for this job, in order."""
    p = entry.publish
    out = []
    if p.comment and job.vcs == "git" and target(job).number:
        out.append("comment")
    if p.draft_pr and job.vcs == "git":
        out.append("draft_pr")
    if p.svn_branch and job.vcs == "svn":
        out.append("svn_branch")
    return out


def auto_count(job: jobs.Job, today: dt.date | None = None) -> int:
    """Automatic publishes today (UTC) for jobs of this job's source."""
    day = (today or dt.datetime.now(dt.timezone.utc).date()).isoformat()
    key = agent_admit.source_key(job.origin)
    n = 0
    for j in jobs.all_jobs():
        if j.origin.startswith(f"{key}:"):
            n += sum(1 for e in record(j).values() if e.get("auto") is True and str(e.get("at", "")).startswith(day))
    return n


def allowed(job: jobs.Job, kind: str, *, auto: bool, even_failing: bool = False) -> str | None:
    """None when this job may be published as `kind` now, else why not. Every publish asks."""
    entry = agent_registry.find(core.expand(job.repo))
    if entry is None:
        return f"{job.repo} is no longer allowed for queued jobs"
    p = entry.publish
    if p.mode == "off" or (auto and p.mode != "auto"):
        return f"publishing is {p.mode} for {job.repo} (ws-agent publish-to, in your own terminal)"
    if kind not in KINDS or kind not in kinds_for(job, entry):
        return f"{job.repo}'s publish settings don't name {kind} for this job"
    if published(job, kind):
        return f"{job.id} was already published ({kind}): {published(job, kind)}"
    info = jobs.exit_info(job) or {}
    if job.closed or job.cancelled or jobs.outcome_state(info) != "succeeded" or not info:
        return f"{job.id} hasn't succeeded"
    checks = info.get("checks")
    if auto:
        if not job.origin:
            return "only a job a source made is published automatically"
        if job.vcs == "svn" or kind == "svn_branch":
            return "an SVN job is never published automatically (reviews stay local)"
        if checks != "pass":
            return f"its checks are {checks or 'none'}: only passing work is published automatically"
        if auto_count(job) >= AUTO_CAP:
            return f"the daily cap of {AUTO_CAP} automatic publishes for {agent_admit.source_key(job.origin)} is reached"
        if int(record(job).get(kind, {}).get("tries", 0) or 0) >= MAX_TRIES:  # type: ignore[call-overload]
            return f"{kind} failed {MAX_TRIES} times: {record(job).get(kind, {}).get('error')}"
    else:
        if kind == "svn_branch" and job.origin:
            return "a source's SVN job is a review: it stays local"
        if checks == "fail" and not even_failing:
            return "its checks failed (--even-failing publishes it anyway)"
    if kind in ("draft_pr", "svn_branch") and not _patch(job).strip():
        return "its patch is empty"
    return None


# --- the text --------------------------------------------------------------------------------

def inert(text: str, limit: int) -> str:
    """Model or third-party text made safe to post under the person's name: printable, cut, and
    unable to mention a user or team (@), link an issue (#) or open a code fence or HTML."""
    t = agent_inbox.printable(text, lines=True)[:limit]
    t = re.sub(r"([@#])", "\\1\u200b", t)
    return t.replace("```", "'''").replace("<", "&lt;")


def _files(job: jobs.Job) -> list[str]:
    try:
        lines = (jobs.job_dir(job.id) / "result" / "manifest.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [inert(ln, 200) for ln in lines if ln.strip()]


def _summary(job: jobs.Job) -> str:
    try:
        rep = json.loads((jobs.job_dir(job.id) / "result" / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return str(rep.get("summary") or "") if isinstance(rep, dict) else ""


def comment_body(job: jobs.Job, pr_url: str = "") -> str:
    info = jobs.exit_info(job) or {}
    files = _files(job)
    lines = [f"Posted by an agent (ws-agent job `{job.id}`, {info.get('engine') or job.engine or 'engine unknown'}), "
             "not written by a person.", "",
             f"Checks: {info.get('checks') or 'none'}."]
    if pr_url:
        lines.append(f"Draft pull request: {pr_url}")
    if files:
        lines += ["", f"Changed files ({len(files)}):", *(f"    {f}" for f in files[:FILES_MAX])]
        if len(files) > FILES_MAX:
            lines.append(f"    ... and {len(files) - FILES_MAX} more")
    else:
        lines += ["", "No files changed."]
    summary = inert(_summary(job), SUMMARY_MAX)
    if summary:
        lines += ["", "The job's own summary (generated text, quoted as is):", "",
                  *(f"> {ln}" for ln in summary.splitlines())]
    return "\n".join(lines) + "\n"


def _instruction(job: jobs.Job) -> str:
    """The first line of the person's own words, for a commit or PR title; never a source's text."""
    if job.origin:
        return ""
    return agent_inbox.printable(job.title)[:72]


def commit_message(job: jobs.Job) -> str:
    head = _instruction(job)
    return f"ws-agent {job.id}" + (f": {head}" if head else "") + "\n\nMade by an agent (ws-agent); review before merging.\n"


# --- the writes ------------------------------------------------------------------------------

def _run(argv: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
         stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(argv, cwd=cwd, env=env, input=stdin, capture_output=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise PublishError(f"ws-agent: {argv[0]} {argv[1] if len(argv) > 1 else ''}: {e}") from e


def _ok(r: subprocess.CompletedProcess[bytes], what: str) -> str:
    if r.returncode != 0:
        tail = (r.stderr.decode("utf-8", "replace").strip().splitlines() or [f"exit {r.returncode}"])[-1]
        raise PublishError(f"ws-agent: {what}: {agent_inbox.printable(tail)[:300]}")
    return r.stdout.decode("utf-8", "replace").strip()


def _post_comment(job: jobs.Job, t: Target, pr_url: str = "") -> str:
    body = json.dumps({"body": comment_body(job, pr_url)}).encode("utf-8")
    out = _ok(_run(["gh", "api", "--method", "POST", f"repos/{t.slug}/issues/{t.number}/comments", "--input", "-"],
                   stdin=body), f"posting to {t.slug}#{t.number}")
    try:
        return str(json.loads(out).get("html_url") or f"https://github.com/{t.slug}/issues/{t.number}")
    except ValueError:
        return f"https://github.com/{t.slug}/issues/{t.number}"


def _draft_pr(job: jobs.Job, entry: agent_registry.Repo, t: Target) -> str:
    """The patch as one commit on the job's base, pushed as the new branch ws-agent/<id>, and a draft
    PR. Built with plumbing against a throwaway index: the person's branches, index, working tree
    and HEAD aren't touched; only new objects reach their repository."""
    repo = core.expand(job.repo)
    slug = t.slug or (entry.github.slug if entry.github else "") or \
        agent_sources.vcs.github_slug(_ok(_run(["git", "-C", str(repo), "config", "--get", "remote.origin.url"]), "git config"))
    if not slug:
        raise PublishError(f"ws-agent: {job.repo} has no github.com origin")
    try:
        agent_sources._check_origin(repo, slug)
    except agent_sources.SourceError as e:
        raise PublishError(f"ws-agent: {e}") from e
    base, branch = job.base.get("commit", ""), f"ws-agent/{job.id}"
    if not re.fullmatch(r"[0-9a-f]{40,64}", base):
        raise PublishError(f"ws-agent: {job.id} has no base commit")
    ref = f"refs/heads/{branch}"
    git = ["git", "-C", str(repo), "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
    quiet = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    there = _ok(_run([*git, "ls-remote", "origin", ref], env=quiet), "git ls-remote").split()
    pushed = str(record(job).get("draft_pr", {}).get("commit") or "")
    if there and there[0] != pushed:
        raise PublishError(f"ws-agent: {branch} already exists on origin; nothing pushed")
    if not there:
        index = jobs.job_dir(job.id) / "result" / "publish.index"
        env = {**quiet, "GIT_INDEX_FILE": str(index)}
        try:
            _ok(_run([*git, "read-tree", base], env=env), "git read-tree")
            _ok(_run([*git, "apply", "--cached", "--binary", "-"], env=env, stdin=_patch(job)), "applying the patch")
            tree = _ok(_run([*git, "write-tree"], env=env), "git write-tree")
            commit = _ok(_run([*git, "commit-tree", tree, "-p", base], env=env,
                              stdin=commit_message(job).encode("utf-8")), "git commit-tree")
        finally:
            index.unlink(missing_ok=True)
        # To the remote's URL, not its name: a push to `origin` would also write a remote-tracking
        # ref into the person's repository. A new branch only: no force, and it was absent a moment ago.
        url = _ok(_run([*git, "remote", "get-url", "--push", "origin"], env=quiet), "git remote get-url")
        _ok(_run([*git, "push", "--quiet", url, f"{commit}:{ref}"], env=quiet), f"pushing {branch}")
        # remembered, so a PR that fails to open is retried without pushing again
        _save(job, "draft_pr", {"branch": branch, "commit": commit})
    into = _pr_base(job, slug)
    title = f"ws-agent {job.id}" + (f": {_instruction(job)}" if _instruction(job) else "")
    body = ("Draft, made by an agent (ws-agent), not written by a person. Review before merging.\n\n"
            + comment_body(job)).encode("utf-8")
    return _ok(_run(["gh", "pr", "create", "--draft", "--repo", slug, "--head", branch, "--base", into, "--title", title,
                     "--body-file", "-"], stdin=body), "opening the draft PR").splitlines()[-1]


def _pr_base(job: jobs.Job, slug: str) -> str:
    """The branch a draft PR targets: a pull request's own branch when the request was on one from
    the same repository, else the repository's default branch."""
    m = re.fullmatch(r"pull/(\d+)/head", job.base.get("branch", ""))
    if m:
        r = _run(["gh", "api", f"repos/{slug}/pulls/{m.group(1)}", "--jq",
                  'if .head.repo.full_name == .base.repo.full_name then .head.ref else "" end'])
        ref = r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""
        if ref and agent_sources._REF.match(ref):
            return ref
    elif job.base.get("branch") and agent_sources._REF.match(job.base["branch"]) and not job.origin:
        pass   # the person's own job: its branch may not exist on origin; use the default branch
    return _ok(_run(["gh", "api", f"repos/{slug}", "--jq", ".default_branch"]), "reading the default branch")


def _svn_branch(job: jobs.Job, entry: agent_registry.Repo) -> str:
    """The patch committed to a NEW branch <svn_branch>/<id>, copied from the job's base URL@rev."""
    root, url, rev = job.base.get("repos_root", ""), job.base.get("url", ""), job.base.get("rev", "")
    parent = entry.publish.svn_branch
    if not (root and url and rev.isdigit() and parent.startswith("^/")):
        raise PublishError(f"ws-agent: {job.id} has no SVN base, or svn_branch isn't set")
    dest_parent = root.rstrip("/") + parent[1:].rstrip("/")
    dest = f"{dest_parent}/{job.id}"
    if url == dest_parent or url.startswith(dest_parent + "/") or dest_parent.startswith(url.rstrip("/") + "/"):
        raise PublishError(f"ws-agent: {parent} is inside (or holds) the job's own URL; branches must live elsewhere")
    svn = ["svn", "--non-interactive"]
    if _run([*svn, "info", dest]).returncode == 0:
        raise PublishError(f"ws-agent: {dest} already exists; nothing committed")
    msg = commit_message(job)
    _ok(_run([*svn, "copy", "--parents", f"{url}@{rev}", dest, "-m", msg.splitlines()[0] + " (branch)"]), "svn copy")
    wc = jobs.job_dir(job.id) / "publish-wc"
    try:
        _ok(_run([*svn, "checkout", "-q", dest, str(wc)]), "svn checkout")
        _ok(_run([*svn, "patch", "--strip", "1", str(jobs.job_dir(job.id) / "result" / "changes.diff")], cwd=wc),
            "svn patch")
        out = _ok(_run([*svn, "commit", "-m", msg], cwd=wc), "svn commit")
    finally:
        import shutil
        shutil.rmtree(wc, ignore_errors=True)
    m = re.search(r"Committed revision (\d+)", out)
    return f"{dest}@{m.group(1)}" if m else dest


def publish(job: jobs.Job, *, auto: bool, even_failing: bool = False, dry_run: bool = False) -> list[str]:
    """Publish every kind the settings name for this job; one line per kind saying what happened.
    A refusal or a failure of one kind doesn't stop the others. Nothing is written with dry_run."""
    entry = agent_registry.find(core.expand(job.repo))
    if entry is None:
        return [f"{job.id}: {job.repo} is no longer allowed for queued jobs"]
    out: list[str] = []
    with _lock(job):
        kinds = kinds_for(job, entry)
        if not kinds:
            return [f"{job.id}: nothing to publish: {job.repo}'s publish settings name no kind for this job"]
        t = target(job)
        # the PR first, so the comment can link it
        for kind in sorted(kinds, key=lambda k: k != "draft_pr"):
            why = allowed(job, kind, auto=auto, even_failing=even_failing)
            if why:
                out.append(f"{job.id}: {kind} not published: {why}")
                continue
            if dry_run:
                where = {"comment": f"a comment on {t.slug}#{t.number}", "draft_pr": f"branch ws-agent/{job.id} and a draft PR",
                         "svn_branch": f"{entry.publish.svn_branch}/{job.id}"}[kind]
                out.append(f"{job.id}: would publish {kind}: {where}")
                continue
            try:
                url = {"comment": lambda: _post_comment(job, t, published(job, "draft_pr")),
                       "draft_pr": lambda: _draft_pr(job, entry, t),
                       "svn_branch": lambda: _svn_branch(job, entry)}[kind]()
            except PublishError as e:
                tries = int(record(job).get(kind, {}).get("tries", 0) or 0) + 1  # type: ignore[call-overload]
                _save(job, kind, {"tries": tries, "error": str(e), "at": core.now_iso()})
                out.append(f"{job.id}: {kind} failed: {e}")
                continue
            _save(job, kind, {"url": url, "at": core.now_iso(), "auto": auto, "error": ""})
            out.append(f"{job.id}: published {kind}: {url}")
    return out
