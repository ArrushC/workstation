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
NOTES = ("ack", "question", "stopped")   # what serve says in the thread while a job lives (phase 4)
STOP_MARK = "stop-requested"             # in the job directory: `/agent stop` came from its thread
MAX_QUESTIONS = 3       # questions posted per job; after that it waits for the person locally
QUESTION_MAX = 1500
MAX_UPDATES = 5         # commits added to one job's pull request after the first
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
    # Not in the job's own directory: that one is writable from inside the job's sandbox, and what
    # this record says decides what is pushed and where (the last commit, the pull request).
    return jobs.private_dir(job.id) / "published.json"


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
    with open(jobs.private_dir(job.id) / "publish.lock", "a+") as fh:
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
    mine = [int(str(key).lstrip("#")) for key, jid in (threads.items() if isinstance(threads, dict) else [])
            if jid == job.id and str(key).lstrip("#").isdigit()]
    # the thread that asked: its own pull request is a thread of the job too, and is always newer
    return Target(slug, min(mine, default=0))


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
    """Other jobs of this job's source with something published automatically today (UTC). Jobs,
    not writes: a job's draft PR and its comment are one; its own second kind is never capped."""
    day = (today or dt.datetime.now(dt.timezone.utc).date()).isoformat()
    key = agent_admit.source_key(job.origin)
    return sum(1 for j in jobs.all_jobs()
               if j.id != job.id and j.origin.startswith(f"{key}:")
               and any(e.get("auto") is True and e.get("url") and not e.get("note")
                       and str(e.get("at", "")).startswith(day) for e in record(j).values()))


def _tries(rec: dict[str, object]) -> int:
    """Automatic attempts so far; a value that isn't a count (a hand-edited file) reads as none."""
    n = rec.get("tries")
    return n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else 0


def gave_up(job: jobs.Job, kind: str) -> bool:
    """serve won't try this kind again by itself: a comment that may have been posted, or
    MAX_TRIES failures. `ws-agent publish <id>` is the person's way on."""
    rec = record(job).get(kind, {})
    if rec.get("url"):
        return False
    return bool(kind == "comment" and rec.get("attempting")) or _tries(rec) >= MAX_TRIES


def touches_workflows(patch: bytes) -> bool:
    """The patch adds or changes something under .github/ (workflows run with the repository's
    secrets as soon as a branch is pushed, before anyone has reviewed the draft PR)."""
    return re.search(rb"^(?:diff --git a/|\+\+\+ b/|--- a/)\.github/", patch, re.M) is not None


def allowed(job: jobs.Job, kind: str, *, auto: bool, even_failing: bool = False,
            allow_workflows: bool = False) -> str | None:
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
    if job.closed or job.cancelled or jobs.live_run(job) is not None or not info \
            or jobs.outcome_state(info) != "succeeded":
        return f"{job.id} hasn't succeeded (or is running again)"
    if kind == "svn_branch":   # checked when set, and again here: the file can be edited by hand
        why = agent_registry.svn_branch_problem(p.svn_branch, entry.watch)
        if why:
            return f"svn_branch {p.svn_branch} {why}"
    workflows = kind == "draft_pr" and touches_workflows(_patch(job))
    rec = record(job).get(kind, {})
    checks = info.get("checks")
    if auto:
        if not p.since or str(info.get("finished") or "") < p.since:
            return "it finished before publishing became automatic here (ws-agent publish does it by hand)"
        if workflows:
            return "its patch touches .github/ (workflows run with the repository's secrets): yours to publish"
        if kind == "comment" and rec.get("attempting") and not rec.get("url"):
            return ("an earlier attempt may have reached GitHub: look at the issue, then ws-agent publish "
                    f"{job.id} if it isn't there")
        if kind == "comment" and held_back(job):
            return "an earlier comment of this job may or may not have been posted: its comments keep their order"
        if not job.origin:
            return "only a job a source made is published automatically"
        if job.vcs == "svn" or kind == "svn_branch":
            return "an SVN job is never published automatically (reviews stay local)"
        if checks != "pass":
            return f"its checks are {checks or 'none'}: only passing work is published automatically"
        if info.get("review") == "concerns":
            return "its reviewer had concerns (ws-agent result shows them): yours to publish"
        if _tries(rec) >= MAX_TRIES:
            return f"{kind} failed {MAX_TRIES} times: {rec.get('error')}"
        if auto_count(job) >= AUTO_CAP:   # last: it reads every job's record
            return (f"the daily cap of {AUTO_CAP} automatically published jobs for "
                    f"{agent_admit.source_key(job.origin)} is reached")
    else:
        if kind == "svn_branch" and job.origin:
            return "a source's SVN job is a review: it stays local"
        if checks == "fail" and not even_failing:
            return "its checks failed (--even-failing publishes it anyway)"
        if workflows and not allow_workflows:
            return ("its patch touches .github/ (workflows run with the repository's secrets as soon as the "
                    "branch is pushed): read it first, then --allow-workflows")
    if kind in ("draft_pr", "svn_branch") and not _patch(job).strip():
        return "its patch is empty"
    return None


# --- the text --------------------------------------------------------------------------------

def fenced(text: str, limit: int) -> str:
    """Model or third-party text made safe to post under the person's name: printable, cut, and
    inside a code fence longer than any run of backticks in it. GitHub renders nothing inside a
    fence: no mention, no issue or commit reference, no link, image, HTML or entity."""
    t = agent_inbox.printable(text, lines=True)[:limit].strip("\n")
    run = max((len(m) for m in re.findall(r"`+", t)), default=0)
    fence = "`" * max(3, run + 1)
    return f"{fence}text\n{t}\n{fence}"


def _word(value: object) -> str:
    """A short field from a result file as plain words (the job's sandbox could write that file)."""
    return re.sub(r"[^A-Za-z0-9 ._-]", "", str(value or ""))[:40].strip()


def _files(job: jobs.Job) -> list[str]:
    try:
        lines = (jobs.job_dir(job.id) / "result" / "manifest.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [ln for ln in lines if ln.strip()]


def _summary(job: jobs.Job) -> str:
    try:
        rep = json.loads((jobs.job_dir(job.id) / "result" / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return str(rep.get("summary") or "") if isinstance(rep, dict) else ""


def comment_body(job: jobs.Job, pr_url: str = "") -> str:
    info = jobs.exit_info(job) or {}
    files = _files(job)
    lines = [f"Posted by an agent (ws-agent job `{job.id}`, {_word(info.get('engine') or job.engine) or 'engine unknown'}), "
             "not written by a person.", "",
             f"Checks: {_word(info.get('checks')) or 'none'}."]
    if info.get("review") in ("ok", "concerns"):
        lines.append(f"Review: {info['review']}.")
    if pr_url and re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+", pr_url):
        lines.append(f"Draft pull request: {pr_url}")
    if files:
        shown = files[:FILES_MAX] + ([f"... and {len(files) - FILES_MAX} more"] if len(files) > FILES_MAX else [])
        lines += ["", f"Changed files ({len(files)}):", "", fenced("\n".join(shown), 200 * FILES_MAX)]
    else:
        lines += ["", "No files changed."]
    if _summary(job).strip():
        lines += ["", "The job's own summary (generated text, shown as written):", "", fenced(_summary(job), SUMMARY_MAX)]
    return "\n".join(lines) + "\n"


def _instruction(job: jobs.Job) -> str:
    """The first line of the person's own words, for a commit or PR title; never a source's text."""
    if job.origin:
        return ""
    return agent_inbox.printable(job.title)[:72]


def commit_message(job: jobs.Job) -> str:
    head = _instruction(job)
    return f"ws-agent {job.id}" + (f": {head}" if head else "") + "\n\nMade by an agent (ws-agent); review before merging.\n"


# --- notes: what serve says in the thread while a job lives ------------------------------------

def _is_comment(key: str) -> bool:
    return key in ("comment", "ack", "stopped") or key.startswith(("question:", "update:"))


def held_back(job: jobs.Job) -> bool:
    """A comment of this job was sent and never confirmed. It is never sent again by itself, and
    nothing later is posted past it: a thread reads in the order things happened."""
    return any(_is_comment(k) and e.get("attempting") and not e.get("url") for k, e in record(job).items())


def _question(job: jobs.Job) -> str:
    try:
        rep = json.loads((jobs.job_dir(job.id) / "result" / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(rep, dict):
        return ""
    return str(rep.get("question") or rep.get("summary") or "").strip()


def _note_key(job: jobs.Job, kind: str) -> str:
    if kind != "question":
        return kind
    return f"question:{(jobs.exit_info(job) or {}).get('finished') or job.attempts}"   # one per time it asks


def note_due(job: jobs.Job, kind: str, entry: agent_registry.Repo | None = None) -> str | None:
    """None when serve should post this note for the job now, else why not. Notes are automatic by
    nature: only in auto mode, only for a GitHub request's job made since auto was switched on."""
    entry = entry or agent_registry.find(core.expand(job.repo))
    if entry is None:
        return f"{job.repo} is no longer allowed for queued jobs"
    p = entry.publish
    if kind not in NOTES or not (p.questions if kind == "question" else p.ack):
        return f"{job.repo}'s publish settings don't name {kind}"
    if p.mode != "auto" or not p.notes_since or job.created < p.notes_since:
        return "publishing isn't automatic here, or the job is older than this setting"
    if kind != "stopped" and agent_sources.unasked(job):
        return "nobody asked the agent on that thread: it says nothing there until it has a result"
    if job.vcs != "git" or not target(job).number:
        return "no GitHub thread asked for this job"
    rec = record(job)
    if held_back(job):
        return "an earlier comment of this job may or may not have been posted"
    if _note_key(job, kind) in rec:
        return "already said"
    if kind == "stopped":
        asked = (jobs.private_dir(job.id) / STOP_MARK).exists()
        return None if job.cancelled and asked else "it wasn't stopped from its thread"
    if job.closed or job.cancelled:
        return "the job is closed or cancelled"
    if kind == "ack" and (jobs.exit_info(job) is not None or rec):
        return "it has already finished or said something: an acknowledgement now would only be noise"
    if kind == "question":
        info = jobs.exit_info(job) or {}
        if jobs.live_run(job) is not None or not info or jobs.outcome_state(info) != "needs-you" or not _question(job):
            return "it isn't asking anything"
        if sum(1 for k, e in rec.items() if k.startswith("question:") and e.get("url")) >= MAX_QUESTIONS:
            return f"it has asked {MAX_QUESTIONS} times in the thread already: the rest waits for you here"
    return None


def note_body(job: jobs.Job, kind: str, entry: agent_registry.Repo) -> str:
    """Fixed words; the first line names the job (agent_sources.AGENT_LINE keeps them from coming
    back as follow-ups). Only a question carries model text, inside a fence."""
    engine = _word((jobs.exit_info(job) or {}).get("engine") or job.engine)   # unknown until it starts
    who = f"(ws-agent job `{job.id}`{', ' + engine if engine else ''})"
    follows = entry.github is not None and entry.github.follow
    if kind == "ack":
        more = ("Reply in this thread to add to the request. " if follows else "")
        return (f"Picked up by an agent {who}, not a person. It will write here again with a result or a question.\n\n"
                f"{more}A comment whose first line is `/agent stop` stops it.\n")
    if kind == "stopped":
        return f"Stopped on request (ws-agent job `{job.id}`). Nothing more will be posted for it.\n"
    how = ("Reply in this thread to answer." if follows
           else "The person running it has been asked; it waits for their answer.")
    return (f"An agent {who} needs an answer to go on. This was not written by a person.\n\n"
            f"{fenced(_question(job), QUESTION_MAX)}\n\n{how}\n")


def post_note(job: jobs.Job, kind: str) -> str:
    """Post one note; a line saying what happened. Marked before the write and kept marked if it
    fails, as a result comment is: it may have reached GitHub."""
    entry = agent_registry.find(core.expand(job.repo))
    with _lock(job):
        job = jobs.load(job.id)
        why = note_due(job, kind, entry)
        if why or entry is None:
            return f"{job.id}: {kind} not posted: {why}"
        key, t = _note_key(job, kind), target(job)
        _save(job, key, {"attempting": core.now_iso(), "note": True})
        body = json.dumps({"body": note_body(job, kind, entry)}).encode("utf-8")
        try:
            out = _ok(_run(["gh", "api", "--method", "POST", f"repos/{t.slug}/issues/{t.number}/comments", "--input", "-"],
                           stdin=body), f"posting to {t.slug}#{t.number}")
        except PublishError as e:
            _save(job, key, {"error": str(e), "at": core.now_iso()})
            return f"{job.id}: {kind} failed: {e}"
        url = _posted(out, t)
        _save(job, key, {"url": url, "at": core.now_iso(), "auto": True, "error": "", "attempting": ""})
        return f"{job.id}: posted {kind}: {url}"


def _posted(out: str, t: Target) -> str:
    """The new comment's URL from GitHub's reply; its id is remembered so it is never read back."""
    try:
        got = json.loads(out)
    except ValueError:
        got = {}
    if isinstance(got, dict):
        agent_sources.remember_posted(t.slug, got.get("id"))
        if got.get("html_url"):
            return str(got["html_url"])
    return f"https://github.com/{t.slug}/issues/{t.number}"


def mark_seen(job: jobs.Job) -> int:
    """The person looked at the thread: this job's unconfirmed notes are settled (never sent again,
    whether or not they arrived), so its later comments can go out. How many were settled."""
    n = 0
    with _lock(job):
        for key, e in record(job).items():
            if key != "comment" and _is_comment(key) and e.get("attempting") and not e.get("url"):
                _save(job, key, {"url": "unconfirmed", "attempting": "", "seen": core.now_iso()})
                n += 1
    return n


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
    return _posted(out, t)


def _tracking(git: list[str], branch: str, env: dict[str, str]) -> set[str]:
    """The remote-tracking refs for this branch name, under any remote."""
    r = _run([*git, "for-each-ref", "--format=%(refname)", f"refs/remotes/*/{branch}"], env=env)
    return set(r.stdout.decode("utf-8", "replace").split()) if r.returncode == 0 else set()


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
    git = ["git", "-C", str(repo), "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "push.followTags=false"]
    quiet = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    # One URL for every check and for the push itself (a remote can push elsewhere than it fetches),
    # and never the remote's name: a push to `origin` would write a remote-tracking ref here.
    url = _ok(_run([*git, "remote", "get-url", "--push", "origin"], env=quiet), "git remote get-url")
    into = _pr_base(job, slug)
    if not agent_sources._REF.match(into):
        raise PublishError(f"ws-agent: refusing the branch name {into!r}")
    # Only the job's own commit may go out. The branch pushes everything its base reaches, so the
    # base must already be on the target branch at origin: a fork pull request's commits (which
    # would then run this repository's workflows with its secrets) and the person's unpushed
    # local commits are not.
    tip = (_ok(_run([*git, "ls-remote", url, f"refs/heads/{into}"], env=quiet), "git ls-remote").split() or [""])[0]
    if not re.fullmatch(r"[0-9a-f]{40,64}", tip):
        raise PublishError(f"ws-agent: {into} isn't a branch at origin")
    _ok(_run([*git, "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--refmap=",
              url, f"refs/heads/{into}"], env=quiet), f"fetching {into}")
    if _run([*git, "merge-base", "--is-ancestor", base, tip], env=quiet).returncode != 0:
        raise PublishError(f"ws-agent: the job's base {base[:12]} isn't on {into} at origin, so a branch from it "
                           "would push commits that aren't the job's (a fork's, or unpushed local ones); nothing pushed")
    there = _ok(_run([*git, "ls-remote", url, ref], env=quiet), "git ls-remote").split()
    pushed = str(record(job).get("draft_pr", {}).get("commit") or "")
    if there and there[0] != pushed:
        raise PublishError(f"ws-agent: {branch} already exists on origin; nothing pushed")
    if not there:
        index = jobs.private_dir(job.id) / "publish.index"   # git follows a link here: never where the job writes
        env = {**quiet, "GIT_INDEX_FILE": str(index)}
        try:
            _ok(_run([*git, "read-tree", base], env=env), "git read-tree")
            _ok(_run([*git, "apply", "--cached", "--binary", "-"], env=env, stdin=_patch(job)), "applying the patch")
            tree = _ok(_run([*git, "write-tree"], env=env), "git write-tree")
            commit = _ok(_run([*git, "commit-tree", tree, "-p", base], env=env,
                              stdin=commit_message(job).encode("utf-8")), "git commit-tree")
        finally:
            index.unlink(missing_ok=True)
        # This one ref, and only if it still doesn't exist (an empty lease): never a tag, a
        # submodule, a fast-forward onto someone's branch, or a forced update.
        tracking = _tracking(git, branch, quiet)
        _ok(_run([*git, "push", "--quiet", "--no-follow-tags", "--recurse-submodules=no", f"--force-with-lease={ref}:",
                  url, f"{commit}:{ref}"], env=quiet), f"pushing {branch}")
        # git 2.56 writes a remote-tracking ref even for a push to a URL, when a remote has that
        # URL. The person's refs stay as they were: drop the one this push made, if it is ours.
        for made in _tracking(git, branch, quiet) - tracking:
            _run([*git, "update-ref", "-d", made, commit], env=quiet)
        # remembered, so a PR that fails to open is retried without pushing again
        _save(job, "draft_pr", {"branch": branch, "commit": commit, "patch": _patch_sha(job)})
    title = f"ws-agent {job.id}" + (f": {_instruction(job)}" if _instruction(job) else "")
    body = ("Draft, made by an agent (ws-agent), not written by a person. Review before merging.\n\n"
            + comment_body(job)).encode("utf-8")
    return _ok(_run(["gh", "pr", "create", "--draft", "--repo", slug, "--head", branch, "--base", into, "--title", title,
                     "--body-file", "-"], stdin=body), "opening the draft PR").splitlines()[-1]


def _patch_sha(job: jobs.Job) -> str:
    import hashlib
    return hashlib.sha256(_patch(job)).hexdigest()


_PR_URL = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)")


def _count(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def _remote_tip(git: list[str], url: str, ref: str, env: dict[str, str]) -> str:
    """The commit `ref` names at origin, or "". The exact ref: ls-remote also matches ref tails."""
    out = _ok(_run([*git, "ls-remote", url, ref], env=env), "git ls-remote")
    return next((ln.split()[0] for ln in out.splitlines() if ln.split()[1:] == [ref]), "")


def _own_pull_request(slug: str, number: int, branch: str) -> str | None:
    """None when pull request `number` is open and is this branch of this same repository, else why
    not. Asked before every push: a merged or closed one gets nothing more."""
    out = _ok(_run(["gh", "api", f"repos/{slug}/pulls/{number}", "--jq",
                    "[.state, .head.ref, .head.repo.full_name, .base.repo.full_name] | @tsv"]),
              f"reading pull request {number}")
    state, head, head_repo, base_repo = (out.split("\t") + ["", "", "", ""])[:4]
    if state != "open":
        return f"pull request {number} is {state or 'gone'}"
    if head != branch or head_repo.casefold() != base_repo.casefold() or base_repo.casefold() != slug.casefold():
        return f"pull request {number} isn't {branch} of {slug}"
    return None


def update_due(job: jobs.Job, *, auto: bool, allow_workflows: bool = False) -> str | None:
    """None when this delivered job's work has changed and may go to its pull request as one more
    commit on its own branch, else why not."""
    entry = agent_registry.find(core.expand(job.repo))
    if entry is None:
        return f"{job.repo} is no longer allowed for queued jobs"
    p = entry.publish
    if p.mode == "off" or (auto and p.mode != "auto") or not (p.draft_pr and p.pr_updates):
        return f"{job.repo}'s publish settings don't add commits to a pull request (publish-to --pr-updates)"
    rec = record(job).get("draft_pr", {})
    if not _PR_URL.fullmatch(str(rec.get("url") or "")) or not rec.get("commit"):
        return f"{job.id} has no pull request of its own"
    if rec.get("theirs"):
        return f"someone else has committed to ws-agent/{job.id}: the branch is theirs now"
    if _count(rec.get("update_tries")) >= MAX_TRIES and auto:
        return f"pushing an update failed {MAX_TRIES} times ({rec.get('update_error')}): ws-agent publish {job.id} tries again"
    info = jobs.exit_info(job) or {}
    if job.closed or job.cancelled or jobs.live_run(job) is not None or not info \
            or jobs.outcome_state(info) != "succeeded":
        return f"{job.id} hasn't succeeded (or is running again)"
    if not _patch(job).strip() or _patch_sha(job) == rec.get("patch"):
        return "its work hasn't changed since the last push"
    if _count(rec.get("updates")) >= MAX_UPDATES:
        return f"{MAX_UPDATES} updates went to this pull request already: the rest is yours to push"
    if auto:   # the rules every automatic write keeps
        if not p.updates_since or str(info.get("finished") or "") < p.updates_since:
            return "it finished before updates became automatic here (ws-agent publish does it by hand)"
        if info.get("review") == "concerns":
            return "its reviewer had concerns (ws-agent result shows them): yours to push"
    if held_back(job):
        return "an earlier comment of this job may or may not have been posted"
    checks = info.get("checks")
    if (auto and checks != "pass") or checks == "fail":
        return f"its checks are {checks or 'none'}: only passing work is pushed"
    if touches_workflows(_patch(job)) and (auto or not allow_workflows):
        return "its patch touches .github/ (workflows run with the repository's secrets): yours to push"
    return None


def update_gave_up(job: jobs.Job) -> bool:
    return _count(record(job).get("draft_pr", {}).get("update_tries")) >= MAX_TRIES


def push_update(job: jobs.Job, *, auto: bool, allow_workflows: bool = False) -> str:
    """One more commit on the job's own branch, then a short note on its pull request. Only while
    the branch's tip at origin is the commit ws-agent pushed last: a fast-forward of its own work,
    never over anyone else's. A line saying what happened."""
    with _lock(job):
        job = jobs.load(job.id)
        why = update_due(job, auto=auto, allow_workflows=allow_workflows)
        if why:
            return f"{job.id}: update not pushed: {why}"
        rec = record(job)["draft_pr"]
        m = _PR_URL.fullmatch(str(rec["url"]))
        assert m is not None
        slug, number, last = m.group(1), int(m.group(2)), str(rec["commit"])
        repo, branch = core.expand(job.repo), f"ws-agent/{job.id}"
        ref, base = f"refs/heads/{branch}", job.base.get("commit", "")
        git = ["git", "-C", str(repo), "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "push.followTags=false"]
        quiet = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        patch, n = _patch(job), _count(rec.get("updates")) + 1
        try:
            agent_sources._check_origin(repo, slug)
            not_ours = _own_pull_request(slug, number, branch)
            if not_ours:
                return f"{job.id}: update not pushed: {not_ours}"
            url = _ok(_run([*git, "remote", "get-url", "--push", "origin"], env=quiet), "git remote get-url")
            there = _remote_tip(git, url, ref, quiet)
            pushing = str(rec.get("pushing") or "")
            if there and there == pushing:
                commit = pushing      # an earlier run pushed this and died before it could say so: finish it
            elif there != last:
                _save(job, "draft_pr", {"theirs": True})
                return (f"{job.id}: update not pushed: ws-agent/{job.id} at origin isn't the commit ws-agent pushed "
                        "(someone committed to it, or it is gone): the branch is theirs now")
            else:
                if _run([*git, "cat-file", "-e", f"{last}^{{commit}}"], env=quiet).returncode != 0:
                    # nothing local names ws-agent's own commit, so a gc may have dropped it: it is origin's tip
                    _ok(_run([*git, "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                              "--refmap=", url, ref], env=quiet), f"fetching {branch}")
                index = jobs.private_dir(job.id) / "publish.index"
                env = {**quiet, "GIT_INDEX_FILE": str(index)}
                try:
                    _ok(_run([*git, "read-tree", base], env=env), "git read-tree")
                    _ok(_run([*git, "apply", "--cached", "--binary", "-"], env=env, stdin=patch), "applying the patch")
                    tree = _ok(_run([*git, "write-tree"], env=env), "git write-tree")
                finally:
                    index.unlink(missing_ok=True)
                if tree == _ok(_run([*git, "rev-parse", f"{last}^{{tree}}"], env=quiet), "git rev-parse"):
                    _save(job, "draft_pr", {"patch": _patch_sha(job)})
                    return f"{job.id}: update not pushed: its work is what the pull request already has"
                msg = f"ws-agent {job.id}: update {n}\n\nMade by an agent (ws-agent); review before merging.\n"
                commit = _ok(_run([*git, "commit-tree", tree, "-p", last], env=quiet, stdin=msg.encode("utf-8")),
                             "git commit-tree")
                # said before the push: if this dies right after it, the next run finds its own commit
                # at origin and doesn't take it for someone else's
                _save(job, "draft_pr", {"pushing": commit})
                tracking = _tracking(git, branch, quiet)
                # a fast-forward of ws-agent's own commit, and only if it is still the tip (the lease)
                _ok(_run([*git, "push", "--quiet", "--no-follow-tags", "--recurse-submodules=no",
                          f"--force-with-lease={ref}:{last}", url, f"{commit}:{ref}"], env=quiet), f"pushing {branch}")
                for made in _tracking(git, branch, quiet) - tracking:
                    _run([*git, "update-ref", "-d", made, commit], env=quiet)
            names = _ok(_run([*git, "diff-tree", "-r", "--name-status", "--no-commit-id", last, commit], env=quiet),
                        "git diff-tree")
        except (PublishError, agent_sources.SourceError) as e:
            tries = _count(rec.get("update_tries")) + (1 if auto else 0)   # only serve's own tries count
            _save(job, "draft_pr", {"update_tries": tries, "update_error": str(e)})
            return f"{job.id}: update failed: {e}"
        _save(job, "draft_pr", {"commit": commit, "updates": n, "patch": _patch_sha(job), "updated_at": core.now_iso(),
                                "pushing": "", "update_tries": 0, "update_error": ""})
        agent_sources.remember_pr(slug, job.id, number, commit)
        # the note: marked first and kept marked if it fails, as every comment is
        key = f"update:{n}"
        _save(job, key, {"attempting": core.now_iso(), "note": True})
        info = jobs.exit_info(job) or {}
        engine = _word(info.get("engine") or job.engine)
        lines = [f"Updated by an agent (ws-agent job `{job.id}`{', ' + engine if engine else ''}), not written by a person.",
                 "", f"Checks: {_word(info.get('checks')) or 'none'}. One more commit is on the branch.", "",
                 "Changed in this update:", "", fenced(names, 200 * FILES_MAX)]
        if _summary(job).strip():
            lines += ["", "The job's own summary (generated text, shown as written):", "", fenced(_summary(job), SUMMARY_MAX)]
        body = json.dumps({"body": "\n".join(lines) + "\n"}).encode("utf-8")
        try:
            out = _ok(_run(["gh", "api", "--method", "POST", f"repos/{slug}/issues/{number}/comments", "--input", "-"],
                           stdin=body), f"posting to {slug}#{number}")
        except PublishError as e:
            _save(job, key, {"error": str(e), "at": core.now_iso()})
            return f"{job.id}: pushed update {n} to {branch}; its note failed: {e}"
        _save(job, key, {"url": _posted(out, Target(slug, number)), "at": core.now_iso(), "auto": auto, "error": "",
                         "attempting": ""})
        return f"{job.id}: pushed update {n} to {branch}: {rec['url']}"


def _pr_base(job: jobs.Job, slug: str) -> str:
    """The branch a draft PR targets: a pull request's own branch when the request was on one from
    the same repository, else the repository's default branch."""
    m = re.fullmatch(r"pull/(\d+)/head", job.base.get("branch", ""))
    if m:
        # no answer is a failure, never "the default branch then": the PR would target the wrong one
        ref = _ok(_run(["gh", "api", f"repos/{slug}/pulls/{m.group(1)}", "--jq",
                        'if .head.repo.full_name == .base.repo.full_name then .head.ref else "" end']),
                  f"reading pull request {m.group(1)}")
        if ref and agent_sources._REF.match(ref):
            return ref
    return _ok(_run(["gh", "api", f"repos/{slug}", "--jq", ".default_branch"]), "reading the default branch")


def _svn_branch(job: jobs.Job, entry: agent_registry.Repo) -> str:
    """The job's patch as a NEW branch <svn_branch>/<id>, in one revision: a checkout of the job's
    base URL@rev, the patch applied and verified there, then `svn copy <that copy> <branch URL>`,
    which commits the branch and the change together. If anything fails before that, the server
    was only read."""
    import shutil
    root, url, rev = job.base.get("repos_root", "").rstrip("/"), job.base.get("url", "").rstrip("/"), job.base.get("rev", "")
    parent = entry.publish.svn_branch
    why = agent_registry.svn_branch_problem(parent, entry.watch)
    if why or not (root and url.startswith(root) and rev.isdigit()):
        raise PublishError(f"ws-agent: {job.id} has no SVN base, or svn_branch {parent} {why or 'is unset'}")
    dest_parent = root + parent[1:].rstrip("/")
    dest = f"{dest_parent}/{job.id}"
    if url == dest_parent or url.startswith(dest_parent + "/") or dest_parent.startswith(url + "/"):
        raise PublishError(f"ws-agent: {parent} is inside (or holds) the job's own URL; branches must live elsewhere")
    svn = ["svn", "--non-interactive"]
    probe = _run([*svn, "info", dest])
    if probe.returncode == 0:
        raise PublishError(f"ws-agent: {dest} already exists; nothing committed")
    if not re.search(rb"E200009|W170000|E160013|non-existent|not found", probe.stderr):
        _ok(probe, f"checking {dest}")   # the server didn't answer "no such path": don't guess
    rel = url[len(root):].strip("/")
    strip = str(len(rel.split("/")) if rel else 0)   # as apply.txt tells the person (agent_exec)
    diff = str(jobs.job_dir(job.id) / "result" / "changes.diff")
    wc = jobs.private_dir(job.id) / "publish-wc"
    shutil.rmtree(wc, ignore_errors=True)
    try:
        _ok(_run([*svn, "checkout", "-q", f"{url}@{rev}", str(wc)]), "svn checkout")
        dry = _ok(_run([*svn, "patch", "--dry-run", "--strip", strip, diff], cwd=wc), "svn patch --dry-run")
        bad = [ln for ln in dry.splitlines() if ln.startswith(("C", "Skipped", ">")) or "rejected" in ln]
        if bad or not any(ln[:1] in "UADG" and ln[1:2] in " U" for ln in dry.splitlines() if ln):
            raise PublishError(f"ws-agent: the patch doesn't apply cleanly to {rel or '/'}@{rev}: "
                               + agent_inbox.printable((bad or ['nothing applied'])[0])[:200])
        _ok(_run([*svn, "patch", "--strip", strip, diff], cwd=wc), "svn patch")
        if not _ok(_run([*svn, "status", "-q"], cwd=wc), "svn status") or any(wc.rglob("*.svnpatch.rej")):
            raise PublishError("ws-agent: the patch changed nothing, or left rejected hunks; nothing committed")
        out = _ok(_run([*svn, "copy", "--parents", str(wc), dest, "-m", commit_message(job)]), "svn copy")
    finally:
        shutil.rmtree(wc, ignore_errors=True)
    m = re.search(r"Committed revision (\d+)", out)
    if not m:
        raise PublishError(f"ws-agent: svn reported no committed revision for {dest}")
    return f"{dest}@{m.group(1)}"


def publish(job: jobs.Job, *, auto: bool, even_failing: bool = False, dry_run: bool = False,
            allow_workflows: bool = False) -> list[str]:
    """Publish every kind the settings name for this job; one line per kind saying what happened.
    A refusal or a failure of one kind doesn't stop the others. Nothing is written with dry_run."""
    entry = agent_registry.find(core.expand(job.repo))
    if entry is None:
        return [f"{job.id}: {job.repo} is no longer allowed for queued jobs"]
    out: list[str] = []
    with _lock(job):
        job = jobs.load(job.id)   # as it is now: closed or cancelled since the caller read it?
        kinds = kinds_for(job, entry)
        if not kinds:
            return [f"{job.id}: nothing to publish: {job.repo}'s publish settings name no kind for this job"]
        t = target(job)
        # the PR first, so the comment can link it
        for kind in sorted(kinds, key=lambda k: k != "draft_pr"):
            why = allowed(job, kind, auto=auto, even_failing=even_failing, allow_workflows=allow_workflows)
            if why:
                out.append(f"{job.id}: {kind} not published: {why}")
                continue
            if dry_run:
                where = {"comment": f"a comment on {t.slug}#{t.number}", "draft_pr": f"branch ws-agent/{job.id} and a draft PR",
                         "svn_branch": f"{entry.publish.svn_branch}/{job.id}"}[kind]
                out.append(f"{job.id}: would publish {kind}: {where}")
                continue
            # Marked before the write (if this can't be saved, nothing is written): a crash or a lost
            # reply after the server acted must not look like "never tried".
            _save(job, kind, {"attempting": core.now_iso()})
            try:
                url = {"comment": lambda: _post_comment(job, t, published(job, "draft_pr")),
                       "draft_pr": lambda: _draft_pr(job, entry, t),
                       "svn_branch": lambda: _svn_branch(job, entry)}[kind]()
            except PublishError as e:
                # only serve's own attempts count toward MAX_TRIES: the person may try as often as they like
                tries = _tries(record(job).get(kind, {})) + (1 if auto else 0)
                # a comment's failure can't be told from "created, then the reply was lost": it stays
                # marked, and serve never posts it again; a branch or PR is safe to try again
                keep = {} if kind == "comment" else {"attempting": ""}
                _save(job, kind, {"tries": tries, "error": str(e), "at": core.now_iso(), **keep})
                out.append(f"{job.id}: {kind} failed: {e}")
                continue
            _save(job, kind, {"url": url, "at": core.now_iso(), "auto": auto, "error": "", "attempting": ""})
            out.append(f"{job.id}: published {kind}: {url}")
            pr = _PR_URL.fullmatch(url) if kind == "draft_pr" else None
            if pr:   # its pull request is now a thread of this job, followed for review and checks
                agent_sources.remember_pr(pr.group(1), job.id, int(pr.group(2)),
                                          str(record(job).get("draft_pr", {}).get("commit") or ""))
    return out
