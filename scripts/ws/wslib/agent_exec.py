"""What pueue runs for a queued agent job (`ws.py agent _exec <id> [--resume]`).

1. Refuse when the repository is no longer allowed (`ws agent allow`).
2. Prepare a private working copy once: `svn checkout URL@REV` / `git worktree add` at the
   recorded base. This is the only step that uses the person's repository credentials.
3. Run headless Claude Code in it: `claude -p` under `timeout`, permission mode acceptEdits,
   nothing may prompt (`--permission-prompts none` denies it), a fixed allowlist, and an
   environment without the parent session's markers or repository credentials. `svn` and `git`
   on its PATH are shims that refuse writes to the repository: a guard against accidents, not a
   security boundary (an absolute path bypasses them).
4. Collect review artifacts: a patch that `svn patch`/`git apply` reproduce (binaries and
   svn properties included), a manifest of every changed path, unversioned files, warnings.
5. Record result/exit.json, which is what makes the job succeeded or failed.

A resumed attempt (`ws agent retry`) first inspects the working copy, writes that inspection
to result/inspect-<attempt>.txt and gives it to Claude before anything else.
"""

from __future__ import annotations

import contextlib
import dataclasses
import datetime as dt
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Mapping
from pathlib import Path
from typing import IO

from . import agent_checks, agent_events, agent_registry, agent_sandbox, core, engines, jobs

RULES = """\
You are a queued ws-agent job running unattended. Work only inside this working copy.
Do not delegate further: no ws-agent commands, and at most one writer at a time.
Never commit, push, copy, merge, switch, update, lock or change revision properties;
leave every change uncommitted (svn add the new files you create).
git: edit files only; never run git add, rm, mv, restore or apply (ws-agent stages everything
when you finish).
SVN: delete, move or copy versioned files with svn delete/move/copy, never plain rm/mv/cp.
This job has no credentials for the repository server, and no network unless its repository
allows it: work from the files here.
End with the structured report. status: done when finished (summary: what changed, the checks
you ran and their results, open risks); question when you need the person, with one concrete
question; blocked when a rule stops you; failed when the task can't be done.
"""

HANDOFF = """\
This job was started by another agent ({prev}), which stopped ({why}). Its last report: {report}
Review the working copy's current state below, keep what's done, and finish the task.

The task:
{task}

{inspection}"""

RETRY = """\
The previous turn stopped on a temporary provider error ({why}). Carry on with the task from
where it stopped, and end with the structured report."""

BACKOFF = (15, 60, 240)   # seconds before each retry of a transient provider or network failure
USAGE_COOLDOWN = 3600     # when a usage-limit message names no reset time

RESUME = """\
This queued job stopped before it finished (attempt {attempt}: interrupted, failed or timed out).
Before anything else, review the working copy's current state below: keep what is done, finish
what isn't, and don't repeat outside actions. Then continue the original task.

{inspection}"""

FRESH_AFTER_INTERRUPT = """\

---
An earlier attempt at this job was interrupted before its session was saved. Its working copy
is kept; review its current state below before you change anything.

{inspection}"""

UNVERSIONED_FILE_MAX = 1 << 20
UNVERSIONED_TOTAL_MAX = 20 << 20

# --- shims: accidental-write guards ------------------------------------------------

_URL = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
SVN_CANON = {"ci": "commit", "up": "update", "co": "checkout", "sw": "switch", "cp": "copy", "mv": "move",
             "ren": "move", "rename": "move", "rm": "delete", "del": "delete", "remove": "delete", "ps": "propset",
             "pset": "propset", "pd": "propdel", "pdel": "propdel", "pe": "propedit", "pedit": "propedit"}
SVN_READ = {"status", "st", "stat", "diff", "di", "info", "log", "cat", "list", "ls", "blame", "praise", "annotate",
            "ann", "propget", "pget", "pg", "proplist", "plist", "pl", "help", "h", "?", "mergeinfo"}
SVN_LOCAL = {"add", "delete", "del", "remove", "rm", "move", "mv", "rename", "ren", "copy", "cp", "propset", "pset",
             "ps", "propdel", "pdel", "pd", "revert", "resolve", "resolved", "cleanup", "patch", "changelist", "cl",
             "mkdir"}
SVN_VALUE_OPTS = {"--username", "--password", "--config-dir", "--config-option"}
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
# A job's git worktree shares refs, config, stash, hooks and objects with the person's
# repository (read-only inside the job sandbox), so git in a job only reads: the agent edits
# files, and ws-agent stages them itself when it collects the result.
GIT_READ = {"status", "diff", "log", "show", "blame", "annotate", "grep", "ls-files", "ls-tree", "cat-file", "rev-parse",
            "rev-list", "describe", "shortlog", "whatchanged", "diff-files", "diff-index", "diff-tree", "check-ignore",
            "var", "help", "version"}


def _inside(token: str, base: Path, wc: Path) -> bool:
    p = Path(os.path.expanduser(token))
    p = (p if p.is_absolute() else base / p).resolve()
    w = wc.resolve()
    return p == w or w in p.parents


def _confined(cwd: Path | None, wc: Path | None, tokens: list[str]) -> bool:
    """Whether a write-capable command stays in the job's copy: it runs there and names no path
    outside it (relative tokens resolve against cwd, so plain values such as `native` pass)."""
    if wc is None:
        return True
    here = cwd or Path.cwd()
    return _inside(".", here, wc) and all(_inside(t, here, wc) for t in tokens if not t.startswith("-"))


def _subcommand(args: list[str], value_opts: set[str]) -> tuple[str | None, list[str]]:
    i = 0
    while i < len(args):
        a = args[i]
        if a in value_opts:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        return a, args[i + 1:]
    return None, []


def _is_url(token: str) -> bool:
    return bool(_URL.match(token)) or token.startswith("^/")


def svn_refusal(args: list[str], wc: Path | None = None, cwd: Path | None = None) -> str | None:
    """Why the shim refuses this svn command line, or None when it may run. With `wc`, a
    working-copy write must also stay inside the job's copy."""
    if any(a == "--revprop" or a.startswith("--revprop=") for a in args):
        return "ws-agent: svn --revprop changes the repository; a person runs it"
    sub, rest = _subcommand(args, SVN_VALUE_OPTS)
    if sub is None or sub in SVN_READ:
        return None
    name = SVN_CANON.get(sub, sub)
    if sub in SVN_LOCAL and not any(_is_url(t) for t in rest):
        if _confined(cwd, wc, rest):
            return None
        return f"ws-agent: svn {name} outside the job's working copy ({wc}); a person runs it"
    return f"ws-agent: svn {name} writes to the repository; a person runs it"


def git_refusal(args: list[str], wc: Path | None = None, cwd: Path | None = None) -> str | None:
    del wc, cwd
    sub, _ = _subcommand(args, GIT_VALUE_OPTS)
    if sub is None or sub in GIT_READ:
        return None
    return (f"ws-agent: git {sub} writes; in a job git only reads (edit the files: ws-agent stages them "
            "when you finish)")


def shim(tool: str, real: str, args: list[str], svn_config: str | None = None, wc: str | None = None) -> int:
    """The body of bin/svn and bin/git in a job: refuse with exit 3, or exec the real binary
    (svn without cached credentials: --no-auth-cache --config-dir <empty job dir>)."""
    root = Path(wc) if wc else None
    reason = svn_refusal(args, root, Path.cwd()) if tool == "svn" else git_refusal(args, root, Path.cwd())
    if reason:
        sys.stderr.write(reason + "\n")
        return 3
    argv = [real, *args]
    if tool == "svn" and svn_config:
        argv = [real, "--non-interactive", "--no-auth-cache", "--config-dir", svn_config, *args]
    os.execv(real, argv)
    return 127   # not reached


def write_shims(bindir: Path, svn_config: Path, wc: Path | None = None) -> None:
    bindir.mkdir(parents=True, exist_ok=True)
    svn_config.mkdir(parents=True, exist_ok=True)
    search = os.pathsep.join(p for p in os.environ.get("PATH", "").split(os.pathsep) if Path(p) != bindir)
    root = str(wc) if wc else None
    for tool in ("svn", "git"):
        real = shutil.which(tool, path=search)
        if not real:
            continue
        cfg = str(svn_config) if tool == "svn" else None
        body = (f"#!{sys.executable} -I\nimport sys\nsys.path.insert(0, {str(core.WS_DIR)!r})\n"
                f"from wslib.agent_exec import shim\n"
                f"sys.exit(shim({tool!r}, {real!r}, sys.argv[1:], {cfg!r}, {root!r}))\n")
        target = bindir / tool
        core.atomic_write(target, body.encode("utf-8"), 0o755)


# --- environment and command line ----------------------------------------------------

_DROP = {"SSH_AUTH_SOCK", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "WS_AGENT_JOB"}
_NO_KEYS_SSH = "ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile=/dev/null"


def clean_env(base: Mapping[str, str], bindir: Path, job_id: str) -> dict[str, str]:
    """The job's environment: no parent-session markers (provider/auth CLAUDE_CODE_* stay), no
    repository credentials where that's practical (no SSH agent, no keys for git or svn+ssh, no
    git credential helpers, no tokens but Claude's own auth: jobs.is_token), the shims first on PATH."""
    env = {k: v for k, v in jobs.strip_session(base).items()
           if k not in _DROP and not jobs.is_token(k)
           and not k.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))}
    false = shutil.which("false") or "/bin/false"
    env.update({
        "PATH": f"{bindir}{os.pathsep}{base.get('PATH', '')}",
        "WS_AGENT_JOB": job_id,
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": false, "SSH_ASKPASS": false,
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "",
        "GIT_SSH_COMMAND": _NO_KEYS_SSH, "SVN_SSH": _NO_KEYS_SSH,
        "SVN_EDITOR": "false",
        "GIT_OPTIONAL_LOCKS": "0",   # git status never writes the gitdir, which the job sandbox mounts read-only
    })
    return env


# --- the working copy -----------------------------------------------------------------

class PrepareError(Exception):
    pass


def _run(argv: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(argv, cwd=cwd, capture_output=True)


def discard_wc(job: jobs.Job, jobdir: Path) -> None:
    """Remove a job's working copy and, for git, its worktree entry and branch in the person's
    repository (ws-agent/<id>, which holds no commits: jobs can't commit)."""
    wc = jobdir / "wc"
    (jobdir / "prepared").unlink(missing_ok=True)
    if job.vcs == "git":
        repo = str(core.expand(job.repo))
        if wc.exists():
            _run(["git", "-C", repo, "worktree", "remove", "--force", str(wc)])
        shutil.rmtree(wc, ignore_errors=True)
        _run(["git", "-C", repo, "worktree", "prune"])
        _run(["git", "-C", repo, "branch", "-D", f"ws-agent/{job.id}"])
    else:
        shutil.rmtree(wc, ignore_errors=True)


def prepare(job: jobs.Job, jobdir: Path) -> None:
    """The job's working copy at its base, made once: `prepared` marks a complete one, so a copy
    an interruption cut short (a long checkout) is thrown away and made again, never reused."""
    wc = jobdir / "wc"
    if (jobdir / "prepared").exists() and wc.exists():
        return
    discard_wc(job, jobdir)
    try:
        if job.vcs == "svn":
            r = _svn_checkout(job, wc)
        elif job.vcs == "git":
            r = _run(["git", "-C", str(core.expand(job.repo)), "worktree", "add", "-q", "-b", f"ws-agent/{job.id}",
                      str(wc), job.base["commit"]])
        else:
            raise PrepareError(f"ws-agent: can't prepare a {job.vcs!r} working copy")
    except OSError as e:
        raise PrepareError(f"ws-agent: {job.vcs} isn't runnable: {e}") from e
    if r.returncode != 0:
        discard_wc(job, jobdir)
        raise PrepareError(r.stderr.decode("utf-8", "replace").strip() or f"exit {r.returncode}")
    if job.vcs == "svn" and job.base.get("review_rev"):
        try:
            _review_input(job, jobdir)
        except PrepareError:
            discard_wc(job, jobdir)
            raise
    (jobdir / "prepared").write_text(core.now_iso() + "\n", encoding="utf-8")


def _svn_checkout(job: jobs.Job, wc: Path) -> subprocess.CompletedProcess[bytes]:
    """`URL@REV`, whole; or, with base["sparse"] (a watcher's review job), only the directories the
    revision touched: an empty checkout, the root's files first ('.': setting the root's depth
    later would drop the directories), then each directory and its parents."""
    url, rev = job.base["url"], job.base["rev"]
    dirs = [d.strip() for d in job.base.get("sparse", "").splitlines() if d.strip()]
    if not dirs:
        return _run(["svn", "checkout", "--non-interactive", "-q", f"{url}@{rev}", str(wc)])
    r = _run(["svn", "checkout", "--non-interactive", "-q", "--depth", "empty", f"{url}@{rev}", str(wc)])
    for d in sorted(dirs, key=lambda d: d != "."):
        if r.returncode != 0:
            break
        if d == ".":
            r = _run(["svn", "update", "--non-interactive", "-q", "--set-depth", "files", "-r", rev, str(wc)])
        elif not Path(d).is_absolute() and ".." not in Path(d).parts:
            r = _run(["svn", "update", "--non-interactive", "-q", "--parents", "--set-depth", "infinity", "-r", rev,
                      str(wc / d)])
    return r


def _review_input(job: jobs.Job, jobdir: Path) -> None:
    """The reviewed revision's diff and log entry in the job's input/ (outside the copy; the
    engine reads it): taken here, with the person's svn credentials, outside the sandbox."""
    rev, url = job.base["review_rev"], job.base["url"]
    inp = jobdir / "input"
    inp.mkdir(parents=True, exist_ok=True)
    for name, argv in ((f"r{rev}.diff", ["svn", "diff", "--non-interactive", "-c", rev, f"{url}@{rev}"]),
                       (f"r{rev}.log", ["svn", "log", "--non-interactive", "-v", "--xml", "-r", rev, f"{url}@{rev}"])):
        r = _run(argv)
        if r.returncode != 0:
            why = r.stderr.decode("utf-8", "replace").strip() or f"exit {r.returncode}"
            raise PrepareError(f"ws-agent: svn {argv[1]} of r{rev} failed: {why}")
        (inp / name).write_bytes(r.stdout)


def _text(r: subprocess.CompletedProcess[bytes]) -> str:
    return r.stdout.decode("utf-8", "replace")


def _diff_stats(diff: str) -> list[str]:
    counts: dict[str, list[int]] = {}
    current = ""
    for line in diff.splitlines():
        if line.startswith("Index: "):
            current = line[7:]
        elif line.startswith("diff --git "):
            current = line.split(" b/", 1)[-1] if " b/" in line else line
        elif current and line.startswith("+") and not line.startswith("+++"):
            counts.setdefault(current, [0, 0])[0] += 1
        elif current and line.startswith("-") and not line.startswith("---"):
            counts.setdefault(current, [0, 0])[1] += 1
    return [f"  {p}: +{a} -{d}" for p, (a, d) in counts.items()]


def _vcs_view(job: jobs.Job, wc: Path) -> tuple[str, str]:
    """(status text, patch text) of a job's working copy, read-only."""
    if job.vcs == "svn":
        return (_text(_run(["svn", "status", "--non-interactive"], cwd=wc)),
                _text(_run(["svn", "diff", "--non-interactive", "--git", "--show-copies-as-adds"], cwd=wc)))
    base = job.base.get("commit", "HEAD")
    return (_text(_run(["git", "status", "--short"], cwd=wc)),
            _text(_run(["git", "diff", "--binary", "-M", base], cwd=wc)))


def _tail(path: Path, n: int) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()[-n:]
    except OSError:
        return []


def inspect(job: jobs.Job) -> str:
    """What an interrupted job left behind: working-copy status, changes per file, the log's end."""
    jd = jobs.job_dir(job.id)
    wc = jd / "wc"
    lines = [f"Job {job.id}: {job.title}", f"Working copy: {wc}"]
    if not wc.exists():
        lines.append("(no working copy yet: nothing was changed)")
    else:
        status, diff = _vcs_view(job, wc)
        st = status.splitlines()
        lines += ["Status:", *(f"  {s}" for s in st[:200]), *(["  (clean)"] if not st else [])]
        if len(st) > 200:
            lines.append(f"  ... {len(st) - 200} more")
        stats = _diff_stats(diff)
        lines += ["Changed lines per file:", *(stats or ["  (none)"])]
    log = _tail(jd / "exec.log", 20)
    if log:
        lines += ["Last lines of exec.log:", *(f"  {s}" for s in log)]
    return "\n".join(lines) + "\n"


# --- review artifacts -------------------------------------------------------------------

def _binary_paths(diff: str) -> set[str]:
    found: set[str] = set()
    current = ""
    for line in diff.splitlines():
        if line.startswith("Index: "):
            current = line[7:]
        elif line.startswith("diff --git ") and not current:
            current = line.split(" b/", 1)[-1]
        elif line.startswith("GIT binary patch") and current:
            found.add(current)
    return found


# What an engine leaves in the copy for itself: Claude Code 2.1.319's sandbox keeps a directory
# .claude/.cc-writes/. Never part of a review, nor of a git job's patch.
ENGINE_FILES = (".claude/.cc-writes",)


def _ignores_itself(path: Path) -> bool:
    """A tool's state directory that marks itself ignored with a `*` .gitignore (.pytest_cache,
    .mypy_cache, the remember plugin's .remember), or one holding only an engine's own
    bookkeeping (ENGINE_FILES): never something to review."""
    if not path.is_dir():
        return False
    try:
        lines = (path / ".gitignore").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = []
    if any(line.strip() == "*" for line in lines):
        return True
    own = {Path(f) for f in ENGINE_FILES}
    root = path.parent
    entries = [p.relative_to(root) for p in path.rglob("*")]

    def engines_own(rel: Path) -> bool:   # an engine path, inside one, or a directory on the way to one
        return rel in own or any(o in rel.parents for o in own) or any(rel in o.parents for o in own)
    return any(e in own for e in entries) and all(engines_own(e) for e in entries)


def _copy_unversioned(wc: Path, paths: list[str], dest: Path) -> tuple[list[str], list[str]]:
    """Copy small unversioned files for review; returns (too large to copy, symlinks). Symlinks
    are never followed: one to / or /usr/include would walk the filesystem, one to a file
    outside the copy would copy that file into the result."""
    skipped: list[str] = []
    links: list[str] = []
    total = 0
    files: list[tuple[str, Path]] = []
    for rel in paths:
        p = wc / rel
        if p.is_symlink():
            links.append(rel)
        elif p.is_dir():
            for top, dirs, names in os.walk(p, followlinks=False):
                for name in sorted(names + dirs):
                    f = Path(top, name)
                    if f.is_symlink():
                        links.append(str(f.relative_to(wc)))
                    elif f.is_file():
                        files.append((str(f.relative_to(wc)), f))
        elif p.is_file():
            files.append((rel, p))
    for rel, p in files:
        size = p.stat().st_size
        if size > UNVERSIONED_FILE_MAX or total + size > UNVERSIONED_TOTAL_MAX:
            skipped.append(rel)
            continue
        total += size
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, target)
    return skipped, links


def _collect_svn(job: jobs.Job, wc: Path, res: Path) -> tuple[bytes, list[str], list[str]]:
    status = _run(["svn", "status", "--non-interactive"], cwd=wc)
    (res / "status.txt").write_bytes(status.stdout)
    diff = _run(["svn", "diff", "--non-interactive", "--git", "--show-copies-as-adds"], cwd=wc).stdout
    binary = _binary_paths(diff.decode("utf-8", "replace"))
    manifest: list[str] = []
    warnings: list[str] = []
    prop_paths: list[str] = []
    unversioned: list[str] = []
    xml = _run(["svn", "status", "--non-interactive", "--xml"], cwd=wc).stdout
    try:
        entries = ET.fromstring(xml).iter("entry")
    except ET.ParseError:
        entries = iter(())
        warnings.append("svn status --xml was unreadable: manifest.txt is incomplete")
    for e in entries:
        path = e.get("path", "")
        st = e.find("wc-status")
        if st is None:
            continue
        item, props = st.get("item", ""), st.get("props", "none")
        if item in ("missing", "incomplete", "obstructed", "conflicted"):
            why = {"missing": "deleted without svn delete, so not in the patch",
                   "incomplete": "an interrupted svn operation left it incomplete",
                   "obstructed": "a different kind of item is in its place",
                   "conflicted": "it has a conflict"}[item]
            warnings.append(f"{item}: {path} ({why})")
        if item == "unversioned":
            if _ignores_itself(wc / path):
                manifest.append(f"{path}\tunversioned tool directory (ignores itself)")
                continue
            unversioned.append(path)
            manifest.append(f"{path}\tunversioned (not in the patch)")
            continue
        notes = [item]
        if st.get("copied") == "true":
            notes.append("with history")
        if st.get("moved-from"):
            notes.append(f"moved from {st.get('moved-from')}")
        if st.get("moved-to"):
            notes.append(f"moved to {st.get('moved-to')}")
        if props == "modified" or (item == "added" and props != "none"):
            notes.append("properties changed")
            prop_paths.append(path)
        if path in binary:
            notes.append("binary")
        manifest.append(f"{path}\t{', '.join(notes)}")
    if prop_paths:
        props_out = _run(["svn", "proplist", "--non-interactive", "-v", *prop_paths], cwd=wc).stdout
        (res / "props.txt").write_bytes(props_out)
    else:
        (res / "props.txt").write_text("(no property changes)\n", encoding="utf-8")
    if unversioned:
        warnings += [f"unversioned, not in the patch: {p}" for p in unversioned]
        skipped, links = _copy_unversioned(wc, unversioned, res / "unversioned")
        warnings += [f"unversioned and too large to copy: {p}" for p in skipped]
        warnings += [f"unversioned symlink, not followed or copied: {p}" for p in links]
    url, root = job.base.get("url", ""), job.base.get("repos_root", "")
    rel = url[len(root):].strip("/") if root and url.startswith(root) else ""
    strip = len(rel.split("/")) if rel else 0
    short = "^/" + rel
    diff_path = res / "changes.diff"
    apply_text = (f"Base: {short} at r{job.base.get('rev', '?')}\n"
                  f"Apply in a working copy of {short} (keeps property changes, adds, deletes and binaries):\n"
                  f"  svn patch --dry-run --strip {strip} {diff_path}\n"
                  f"  svn patch --strip {strip} {diff_path}\n"
                  "Moves arrive as add + delete; manifest.txt names each move.\n")
    (res / "apply.txt").write_text(apply_text, encoding="utf-8")
    return diff, manifest, warnings


def _collect_git(job: jobs.Job, wc: Path, res: Path) -> tuple[bytes, list[str], list[str]]:
    base = job.base.get("commit", "HEAD")
    _run(["git", "add", "-A", "--", ".", *(f":(exclude){f}" for f in ENGINE_FILES)], cwd=wc)
    (res / "status.txt").write_bytes(_run(["git", "status", "--short"], cwd=wc).stdout)
    diff = _run(["git", "diff", "--cached", "--binary", "-M", base], cwd=wc).stdout
    names = _text(_run(["git", "diff", "--cached", "--name-status", "-M", base], cwd=wc)).splitlines()
    diff_path = res / "changes.diff"
    (res / "apply.txt").write_text(f"Base: commit {base}\nApply in your checkout:\n  git apply --check {diff_path}\n"
                                   f"  git apply --index {diff_path}\n",
                                   encoding="utf-8")
    return diff, names, []


def collect(job: jobs.Job, jobdir: Path) -> list[str]:
    wc = jobdir / "wc"
    res = jobdir / "result"
    res.mkdir(parents=True, exist_ok=True)
    if not wc.exists():
        warnings = ["no working copy: nothing to collect"]
        (res / "warnings.txt").write_text("\n".join(warnings) + "\n", encoding="utf-8")
        return warnings
    diff, manifest, warnings = (_collect_svn if job.vcs == "svn" else _collect_git)(job, wc, res)
    (res / "changes.diff").write_bytes(diff)
    (res / "manifest.txt").write_text("\n".join(manifest) + ("\n" if manifest else ""), encoding="utf-8")
    if not diff.strip():
        warnings.insert(0, "no changes: the patch is empty")
    (res / "warnings.txt").write_text("".join(f"{w}\n" for w in warnings), encoding="utf-8")
    return warnings


# --- the run ---------------------------------------------------------------------------

def _log(fh: IO[str], msg: str) -> None:
    fh.write(msg.rstrip("\n") + "\n")
    fh.flush()


def _die_with_parent() -> None:
    """In the child, before exec: get SIGTERM when _exec dies (pueue kill sends it SIGKILL), so
    `timeout` passes TERM on to the engine instead of leaving it running as an orphan."""
    try:
        import ctypes

        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


def _run_engine(job: jobs.Job, argv: list[str], prompt: str, out: IO[bytes], log: IO[str], cwd: Path,
                env: dict[str, str]) -> int:
    """The engine (under timeout, inside the job sandbox) as its own process group, recorded in
    run.pid while it runs; a TERM/HUP/INT to _exec goes on to that group."""
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=out, stderr=log, cwd=cwd, env=env,
                            start_new_session=True, preexec_fn=_die_with_parent)
    jobs.record_run(job, proc.pid)

    def forward(sig: int, _frame: object) -> None:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, sig)

    old = {s: signal.signal(s, forward) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        with contextlib.suppress(BrokenPipeError):
            proc.communicate(prompt.encode("utf-8"))
        return proc.wait()
    finally:
        for s, h in old.items():
            signal.signal(s, h)
        jobs.clear_run(job)


def _seconds(text: str) -> int:
    m = re.fullmatch(r"\s*(\d+)\s*([smhd]?)\s*", text or "")
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)] if m else 7200


def _archive_exit(job: jobs.Job, res: Path) -> None:
    """The previous attempt's result moves aside (exit-<n>.json, report-<n>.json): a new attempt
    never reads, and nobody mistakes, an old outcome for its own."""
    for name in ("exit", "report"):
        cur = res / f"{name}.json"
        if cur.exists():
            target = res / f"{name}-{job.attempts}.json"
            if target.exists():
                cur.unlink()
            else:
                cur.replace(target)


def _last_report(res: Path) -> str:
    for p in sorted(res.glob("report*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            return f"{data.get('status')}: {data.get('summary')}"
    return "(none)"


def _known_session(job: jobs.Job, res: Path, engine: engines.Engine) -> str:
    """The session this engine already has for the job: the recorded one, or (for an engine that
    names its session as it runs, like Codex) the one its last interrupted output names."""
    if job.session_id:
        return job.session_id
    for adir in sorted((res / "attempts").glob("*"), key=lambda p: p.stat().st_mtime, reverse=True):
        sid = engine.session_from(adir)
        if sid:
            return sid
    return ""


FIX = """\
The repository's checks failed after your change:
$ {cmd}    ({how})
{tail}
Fix the cause, then end with the structured report again."""

REVIEW_RULES = """\
You are reviewing the change a queued ws-agent job made. Read the files in this working copy as
you need; change nothing and run nothing that writes. End with the structured review: verdict ok
when the change does what the task asks and you can name no defect, else concerns, with each
finding's file, line (or null) and issue."""

REVIEW = """\
The task the job was given:
{task}

Its checks:
{checks}

Its change (also at {diff_path}):
{diff}"""

REVIEW_DIFF_MAX = 200_000

TELL = """\
The person wrote to this job:
{lines}
Take it into account and carry on; end with the structured report."""


def _requeue_if_told(job: jobs.Job, res: Path, log: IO[str]) -> bool:
    """A message that arrived while the job was finishing (its checks, collecting, its review):
    the job goes on in its session. Under the queue lock, as `tell` decides under it whether to
    requeue: whichever comes second finds the other's work done (exit.json already moved)."""
    try:
        with jobs.queue_lock():
            if jobs.undelivered(job) and (res / "exit.json").exists():
                _archive_exit(job, res)
                jobs.enqueue(job, resume=True)
                _log(log, f"ws-agent: the person wrote while it finished: requeued (task {job.pueue_id})")
                return True
    except jobs.QueueError as e:
        _log(log, f"ws-agent: a message is waiting, but requeueing failed ({e}); ws-agent retry {job.id} delivers it")
    return False


def _announce(job: jobs.Job, info: dict[str, object]) -> None:
    """The finished job as an event line for live sessions and a desktop notice."""
    st = jobs.outcome_state(info)
    checks = info.get("checks")
    if st == "succeeded":
        words = "succeeded" + (f" checks {checks}" if checks in ("pass", "fail", "not run") else "")
    elif st == "needs-you":
        words = "needs you"
    elif st == "waiting":
        words = f"waiting for {info.get('engine') or 'an engine'}"
    else:
        words = "failed"
    try:
        agent_events.append(st, job, f"{job.id} {words} ({job.title[:60]})")
        agent_events.notify(f"{job.id} {words}: {job.title[:80]}")
    except OSError:
        pass


def _prior_exit(res: Path, attempts: int) -> dict[str, object]:
    try:
        data = json.loads((res / f"exit-{attempts}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _check_env(env: Mapping[str, str]) -> dict[str, str]:
    """A check runs the repository's own code: no engine's login either."""
    return {k: v for k, v in env.items()
            if not k.startswith(("ANTHROPIC_", "OPENAI_", "CODEX_")) and k != "CLAUDE_CODE_OAUTH_TOKEN"}


def _review(job: jobs.Job, jd: Path, entry: agent_registry.Repo, task: str, log: IO[str], deadline: float,
            bindir: Path, attempt: int) -> tuple[str | None, str | None]:
    """A second-opinion review by `entry.review` in a fresh, read-only session: (verdict or None,
    a warning or None). It never touches the job's own session, and the patch was taken before it."""
    res, wc = jd / "result", jd / "wc"
    name = entry.review
    engine = engines.ENGINES.get(name)
    if engine is None or name not in entry.engines:
        return None, f"review skipped: {name} isn't one of this repository's engines"
    problem = engine.available() or (f"cooling down until {engines.cooling(name)}" if engines.cooling(name) else None)
    if problem:
        return None, f"review skipped: {name}: {problem}"
    remaining = int(min(deadline - time.monotonic(), 1800))
    if remaining <= 0:
        return None, "review skipped: the job's time ran out"
    diff = (res / "changes.diff").read_text(encoding="utf-8", errors="replace") if (res / "changes.diff").exists() else ""
    checks = (res / "checks.txt").read_text(encoding="utf-8", errors="replace") if (res / "checks.txt").exists() else "(none)"
    prompt = REVIEW.format(task=task, checks=checks[-20000:], diff_path=res / "changes.diff",
                           diff=diff[:REVIEW_DIFF_MAX] + ("\n... (cut)" if len(diff) > REVIEW_DIFF_MAX else ""))
    reviewer = dataclasses.replace(job, session_id=str(uuid.uuid4()) if engine.name == "claude" else "")
    adir = res / "attempts" / f"{attempt}.review"
    adir.mkdir(parents=True, exist_ok=True)
    c = engines.Confinement(wc=wc, network=False, commands=(), instructions=REVIEW_RULES, read_dirs=(res,),
                            read_only=True, schema=engines.REVIEW_SCHEMA)
    before = _vcs_view(job, wc)
    try:
        inner = agent_sandbox.wrap(engine.argv(reviewer, adir, resume=None, c=c,
                                               model=agent_registry.settings().engine(name).model),
                                   job_id=job.id, wc=wc, ro=engine.ro_paths(), rw=engine.rw_paths())
    except agent_sandbox.SandboxError as e:
        return None, f"review skipped: {e}"
    _log(log, f"ws-agent: review by {name}")
    with engines.slot(name, agent_registry.settings().engine(name).parallel), open(adir / "stdout", "wb") as out:
        rc = _run_engine(job, ["timeout", "--kill-after=60s", f"{remaining}s", *inner], prompt, out, log, wc,
                         engine.env(clean_env(os.environ, bindir, job.id)))
    outcome = engine.parse(adir, rc, schema=engines.REVIEW_SCHEMA)
    note = None
    if _vcs_view(job, wc) != before:
        note = "the review changed the working copy; the patch was taken before it"
    if outcome.kind != "ok" or outcome.report is None:
        return None, note or f"review by {name} failed ({outcome.kind}): {outcome.message[:200]}"
    core.atomic_write(res / "review.json", (json.dumps(outcome.report, indent=2) + "\n").encode("utf-8"))
    return str(outcome.report.get("verdict")), note


def execute(job_id: str, *, resume: bool) -> int:
    job = jobs.load(job_id)
    jd = jobs.job_dir(job.id)
    res = jd / "result"
    res.mkdir(parents=True, exist_ok=True)
    if job.cancelled or job.closed or jobs.live_run(job) is not None:
        why = ("cancelled" if job.cancelled else "closed") if (job.cancelled or job.closed) else \
            "still running in another attempt"
        with open(jd / "exec.log", "a", encoding="utf-8") as log:
            _log(log, f"ws-agent: not running {job.id}: it is {why} ({core.now_iso()})")
        return 1
    _archive_exit(job, res)
    attempt = job.attempts + 1
    with open(jd / "exec.log", "a", encoding="utf-8") as log:
        _log(log, f"--- attempt {attempt} {'resume' if resume else 'start'} {core.now_iso()}")

        def finish(code: int, *, kind: str, outcome: engines.Outcome | None = None, **extra: object) -> int:
            job.attempts = attempt
            jobs.save(job)
            report = outcome.report if outcome else None
            if report is not None:
                core.atomic_write(res / "report.json", (json.dumps(report, indent=2) + "\n").encode("utf-8"))
            info: dict[str, object] = {
                "exit_code": code, "finished": core.now_iso(), "attempt": attempt, "engine": job.engine,
                "kind": kind, "status": report.get("status") if report else None, "checks": extra.pop("checks", "none"),
                "session_id": job.session_id, "is_error": code != 0, "timed_out": kind == "timeout",
                "num_turns": outcome.turns if outcome else None,
                "duration_ms": outcome.duration_ms if outcome else None,
                "cost_usd": outcome.cost_usd if outcome else None, **extra}
            core.atomic_write(res / "exit.json", (json.dumps(info, indent=2) + "\n").encode("utf-8"))
            _log(log, f"--- attempt {attempt} finished: {kind}, exit {code}")
            if not (kind == "ok" and _requeue_if_told(job, res, log)):   # requeued: it isn't finished
                _announce(job, info)
            return 0 if code == 0 else 1

        entry = agent_registry.find(core.expand(job.repo))
        if entry is None:
            _log(log, f"ws-agent: {job.repo} isn't allowed for queued jobs any more (ws-agent allow <path>)")
            return finish(1, kind="not_allowed", reason="not allowed")
        try:
            prepare(job, jd)
        except PrepareError as e:
            _log(log, f"ws-agent: preparing the working copy failed: {e}")
            return finish(1, kind="prepare", reason="prepare failed")
        why = agent_sandbox.probe()
        if why:
            _log(log, f"ws-agent: no job sandbox on this host, so no job runs here: {why}")
            return finish(1, kind="sandbox", reason=f"no job sandbox on this host: {why}")
        wc = jd / "wc"
        bindir = jd / "bin"
        write_shims(bindir, jd / "svn-config", wc)
        (jd / "rules.md").write_text(RULES, encoding="utf-8")
        task = (jd / "prompt.md").read_text(encoding="utf-8")
        inspection = ""
        if resume:
            inspection = inspect(job)
            (res / f"inspect-{attempt}.txt").write_text(inspection, encoding="utf-8")
        deadline = time.monotonic() + _seconds(job.timeout)
        prev = job.engine or ("claude" if job.session_id else "")   # a phase-1 record was always claude
        intent = "resume" if resume else "start"
        handoff_why = "it was interrupted"
        stopped: set[str] = set()   # engines that hit their usage limit during this attempt
        retries = run_no = fix_used = 0
        outcome: engines.Outcome | None = None
        verdict = "none"
        fix_text = ""
        check_env = _check_env(clean_env(os.environ, bindir, job.id))
        while True:
            engine, reasons = engines.select(entry, exclude=stopped)
            if engine is None:
                # waiting as soon as one allowed engine will come back by itself (its usage limit
                # resets); serve requeues the job then. With none cooling, nothing will change on
                # its own (logged out, no sandbox): failed.
                waiting = any(n in stopped or engines.cooling(n) for n in entry.engines)
                until = min((u for u in (engines.cooling(n) for n in entry.engines) if u), default="")
                _log(log, "ws-agent: no engine can run this job now: " + "; ".join(reasons))
                if outcome is not None or wc.exists():
                    collect(job, jd)
                return finish(1, kind="usage_limit" if waiting else "error", outcome=outcome,
                              reason="; ".join(reasons), reset_at=until)
            sid = _known_session(job, res, engine) if prev == engine.name else ""
            resumable = bool(sid) and engine.transcript_exists(sid)
            resume_sid: str | None = None
            pending = jobs.undelivered(job)
            told = TELL.format(lines="\n".join(f"- {m.get('text')}" for m in pending)) if pending else ""
            if pending and intent in ("resume", "tell") and resumable and prev == engine.name and \
                    (intent == "tell" or _prior_exit(res, job.attempts).get("kind") == "ok"):
                # it finished or asked, and the person wrote: their words are the whole prompt
                prompt, resume_sid, told = told, sid, ""
            elif prev and prev != engine.name:
                prompt = HANDOFF.format(prev=prev, why=handoff_why, report=_last_report(res), task=task,
                                        inspection=inspection or inspect(job)) + (f"\n\n{fix_text}" if intent == "fix" else "")
            elif intent == "fix" and resumable:
                prompt, resume_sid = fix_text, sid
            elif intent == "fix":
                prompt = f"{task}\n\n---\n{fix_text}\n\n{inspect(job)}"
            elif intent == "retry" and resumable:
                prompt, resume_sid = RETRY.format(why=outcome.message[:200] if outcome else "?"), sid
            elif intent in ("resume", "retry") and resumable:
                prompt, resume_sid = RESUME.format(attempt=attempt, inspection=inspection or inspect(job)), sid
            elif intent in ("resume", "retry", "tell"):
                prompt = task + FRESH_AFTER_INTERRUPT.format(inspection=inspection or inspect(job))
            else:
                prompt = task
            if told:
                prompt = f"{prompt}\n\n---\n{told}"
            jobs.mark_delivered(job, [m.get("id") for m in pending], attempt)
            if resume_sid is None:
                job.session_id = str(uuid.uuid4()) if engine.name == "claude" else ""
            job.engine = engine.name
            jobs.save(job)
            remaining = int(deadline - time.monotonic())
            if remaining <= 0:
                collect(job, jd)
                return finish(124, kind="timeout", outcome=outcome, reason=f"timed out after {job.timeout}")
            run_no += 1
            adir = res / "attempts" / f"{attempt}.{run_no}"
            adir.mkdir(parents=True, exist_ok=True)
            c = engines.Confinement(wc=wc, network=entry.network, commands=entry.commands, instructions=RULES,
                                    read_dirs=tuple(p for p in (jd / "input",) if p.is_dir()))
            model = agent_registry.settings().engine(engine.name).model
            try:
                inner = agent_sandbox.wrap(engine.argv(job, adir, resume=resume_sid, c=c, model=model), job_id=job.id,
                                           wc=wc, ro=engine.ro_paths(), rw=engine.rw_paths())
            except agent_sandbox.SandboxError as e:
                _log(log, str(e))
                return finish(1, kind="sandbox", reason=str(e))
            argv = ["timeout", "--kill-after=60s", f"{remaining}s", *inner]
            env = engine.env(clean_env(os.environ, bindir, job.id))
            cap = agent_registry.settings().engine(engine.name).parallel
            with engines.slot(engine.name, cap):
                _log(log, f"ws-agent: running {engine.name} ({'resume ' + resume_sid if resume_sid else 'new session'})")
                with open(adir / "stdout", "wb") as out:
                    rc = _run_engine(job, argv, prompt, out, log, wc, env)
            outcome = engine.parse(adir, rc)
            if rc == 124:
                outcome.kind = "timeout"
            job.session_id = outcome.session_id or engine.session_from(adir) or job.session_id
            job.history.append({"attempt": attempt, "engine": engine.name, "session_id": job.session_id,
                                "started": core.now_iso(), "kind": outcome.kind})
            jobs.save(job)
            prev = engine.name
            if outcome.kind == "transient" and retries < len(BACKOFF):
                wait = BACKOFF[retries]
                retries += 1
                _log(log, f"ws-agent: {engine.name} hit a temporary error ({outcome.message[:200]}); "
                          f"retrying in {wait}s ({retries}/{len(BACKOFF)})")
                time.sleep(wait)
                intent = "retry"
                continue
            if outcome.kind == "usage_limit":
                until = outcome.reset_at or dt.datetime.fromtimestamp(time.time() + USAGE_COOLDOWN,
                                                                      tz=dt.timezone.utc).isoformat()
                engines.cool(engine.name, until)
                stopped.add(engine.name)
                handoff_why = f"it hit its usage limit, until {until}"
                _log(log, f"ws-agent: {engine.name} hit its usage limit (until {until}); trying the next allowed engine")
                intent = "fix" if intent == "fix" else "resume"
                continue
            if outcome.kind == "ok" and outcome.report:
                r = outcome.report
                jobs.post(job, "job", f"{r.get('status')}: {r.get('summary')}"
                          + (f"\nquestion: {r.get('question')}" if r.get("question") else ""), attempt=attempt)
                if jobs.undelivered(job):   # the person wrote during the turn: it goes on in the same session
                    intent, retries = "tell", 0
                    continue
            if outcome.kind == "ok" and outcome.report and outcome.report.get("status") == "done" and entry.checks:
                runs = agent_checks.run_checks(job, jd, entry, check_env)
                verdict = agent_checks.verdict(runs)
                bad = agent_checks.failing(runs) if runs else None
                _log(log, f"ws-agent: checks {verdict}")
                if verdict == "fail" and bad is not None and fix_used < entry.fix_rounds:
                    fix_used += 1
                    how = f"timed out after {agent_checks.CHECK_TIMEOUT}s" if bad.timed_out else f"exit {bad.exit}"
                    fix_text = FIX.format(cmd=bad.cmd, how=how, tail=agent_checks.fix_tail(bad))
                    intent, retries = "fix", 0
                    _log(log, f"ws-agent: fix round {fix_used}/{entry.fix_rounds}: {bad.cmd} ({how})")
                    continue
            break
        warnings = collect(job, jd)
        if outcome.kind == "timeout":
            return finish(124, kind="timeout", outcome=outcome, reason=f"timed out after {job.timeout}",
                          warnings=len(warnings), checks=verdict, fix_rounds=fix_used)
        if outcome.kind != "ok" or outcome.report is None:
            _log(log, f"ws-agent: {engine.name} failed ({outcome.kind}): {outcome.message[:300]}")
            return finish(1, kind=outcome.kind, outcome=outcome, reason=outcome.message[:500], warnings=len(warnings),
                          checks=verdict, fix_rounds=fix_used)
        status = outcome.report.get("status")
        review = None
        if status == "done" and entry.review:
            review, note = _review(job, jd, entry, task, log, deadline, bindir, attempt)
            if note:
                warnings.append(note)
                with open(res / "warnings.txt", "a", encoding="utf-8") as fh:
                    fh.write(note + "\n")
        return finish(0 if status == "done" else 1, kind="ok", outcome=outcome, warnings=len(warnings), checks=verdict,
                      fix_rounds=fix_used, review=review)
