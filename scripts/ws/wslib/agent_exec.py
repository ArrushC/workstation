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
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Mapping
from pathlib import Path
from typing import IO

from . import agent_registry, core, jobs

RULES = """\
You are a queued ws-agent job running unattended. Work only inside this working copy.
Do not delegate further: no ws-agent commands, and at most one writer at a time.
Never commit, push, copy, merge, switch, update, lock or change revision properties;
leave every change uncommitted (svn add new files; for git, stage nothing yourself).
SVN: delete, move or copy versioned files with svn delete/move/copy, never plain rm/mv/cp.
This job has no credentials for the repository server: work from the files here.
When you finish, end with: what changed, the checks you ran and their results, open risks.
If you can't finish, start your final message with BLOCKED: and the reason.
"""

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

# No bare Edit/Write: acceptEdits already allows edits inside the job's copy, and a tool-wide
# rule would also allow them outside it (claude_argv blocks those writes outright too).
BASE_TOOLS = ("Read", "Glob", "Grep", "Bash(svn *)", "Bash(git *)", "Bash(rg *)", "Bash(fd *)",
              "Bash(ls *)", "Bash(cat *)", "Bash(head *)", "Bash(tail *)", "Bash(wc *)", "Bash(diff *)",
              "Bash(python3 -m unittest*)")

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
# A job's git worktree shares refs, config, stash and hooks with the person's repository, so
# git is default-deny: reads anywhere, and only these writes, inside the job's copy.
GIT_READ = {"status", "diff", "log", "show", "blame", "annotate", "grep", "ls-files", "ls-tree", "cat-file", "rev-parse",
            "rev-list", "describe", "shortlog", "whatchanged", "diff-files", "diff-index", "diff-tree", "check-ignore",
            "var", "help", "version"}
GIT_LOCAL = {"add", "rm", "mv", "restore", "apply"}


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
    sub, rest = _subcommand(args, GIT_VALUE_OPTS)
    if sub is None or sub in GIT_READ:
        return None
    if sub in GIT_LOCAL:
        here = cwd or Path.cwd()
        moved = [args[i + 1] for i, a in enumerate(args[:-1]) if a in ("-C", "--git-dir", "--work-tree")]
        moved += [a.split("=", 1)[1] for a in args if a.startswith(("--git-dir=", "--work-tree="))]
        if wc is None or (all(_inside(m, here, wc) for m in moved) and _confined(here, wc, rest)):
            return None
        return f"ws-agent: git {sub} outside the job's working copy ({wc}); a person runs it"
    return f"ws-agent: git {sub} changes the shared repository or reaches outside it; a person runs it"


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
    })
    return env


def permission_rules(job: jobs.Job, repo_commands: tuple[str, ...]) -> list[str]:
    del job
    return [*BASE_TOOLS, *(f"Bash({c})" for c in repo_commands)]


def claude_argv(job: jobs.Job, jobdir: Path, *, resume: bool, rules: list[str]) -> list[str]:
    del jobdir
    claude = shutil.which("claude") or "claude"
    session = ["--resume", job.session_id] if resume else ["--session-id", job.session_id]
    confine = json.dumps({"permissions": {"blockWritesOutsideWorkingDirectories": True}})
    return [claude, "-p", "--output-format", "json", "--permission-mode", "acceptEdits", "--permission-prompts", "none",
            *session, "--name", f"ws-agent {job.id}: {job.title}"[:80], "--append-system-prompt", RULES,
            "--settings", confine, "--allowedTools", *rules]


def transcript_exists(session_id: str) -> bool:
    if not session_id:
        return False
    base = Path(os.environ.get("CLAUDE_CONFIG_DIR") or core.home() / ".claude") / "projects"
    return any(base.glob(f"*/{session_id}.jsonl"))


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
            r = _run(["svn", "checkout", "--non-interactive", "-q", f"{job.base['url']}@{job.base['rev']}", str(wc)])
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
    (jobdir / "prepared").write_text(core.now_iso() + "\n", encoding="utf-8")


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


def _ignores_itself(path: Path) -> bool:
    """A tool's state directory that marks itself ignored with a `*` .gitignore (.pytest_cache,
    .mypy_cache, the remember plugin's .remember): never something to review."""
    try:
        lines = (path / ".gitignore").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return False
    return path.is_dir() and any(line.strip() == "*" for line in lines)


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
    _run(["git", "add", "-A"], cwd=wc)
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

def _pick_result(data: object) -> dict[str, object] | None:
    """The result message of `claude -p --output-format json`: claude 2.1.319 prints an array of
    every message ending in {"type": "result", ...}; other builds print that object alone."""
    if isinstance(data, dict):
        return data
    if isinstance(data, list):
        dicts = [m for m in data if isinstance(m, dict)]
        results = [m for m in dicts if m.get("type") == "result"]
        return (results or dicts or [None])[-1]
    return None


def _claude_result(path: Path) -> dict[str, object]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return {}
    try:
        found = _pick_result(json.loads(text))
    except ValueError:
        found = None
        for line in reversed(text.splitlines()):
            try:
                found = _pick_result(json.loads(line))
            except ValueError:
                continue
            if found is not None:
                break
    return found or {}


def _log(fh: IO[str], msg: str) -> None:
    fh.write(msg.rstrip("\n") + "\n")
    fh.flush()


def _die_with_parent() -> None:
    """In the child, before exec: get SIGTERM when _exec dies (pueue kill sends it SIGKILL), so
    `timeout` passes TERM on to claude instead of leaving it running as an orphan."""
    try:
        import ctypes

        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


def _run_claude(job: jobs.Job, argv: list[str], prompt: str, out: IO[bytes], log: IO[str], cwd: Path,
                env: dict[str, str]) -> int:
    """claude (under timeout) as its own process group, recorded in run.pid while it runs; a
    TERM/HUP/INT to _exec goes on to that group."""
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
    (res / "exit.json").unlink(missing_ok=True)
    attempt = job.attempts + 1
    with open(jd / "exec.log", "a", encoding="utf-8") as log:
        _log(log, f"--- attempt {attempt} {'resume' if resume else 'start'} {core.now_iso()}")

        def finish(code: int, **extra: object) -> int:
            job.attempts = attempt
            jobs.save(job)
            info = {"exit_code": code, "finished": core.now_iso(), "attempt": attempt, **extra}
            core.atomic_write(res / "exit.json", (json.dumps(info, indent=2) + "\n").encode("utf-8"))
            _log(log, f"--- attempt {attempt} finished: exit {code}")
            return 0 if code == 0 else 1

        entry = agent_registry.find(core.expand(job.repo))
        if entry is None:
            _log(log, f"ws-agent: {job.repo} isn't allowed for queued jobs any more (ws-agent allow <path>)")
            return finish(1, is_error=True, reason="not allowed")
        try:
            prepare(job, jd)
        except PrepareError as e:
            _log(log, f"ws-agent: preparing the working copy failed: {e}")
            return finish(1, is_error=True, reason="prepare failed")
        bindir = jd / "bin"
        write_shims(bindir, jd / "svn-config", jd / "wc")
        (jd / "rules.md").write_text(RULES, encoding="utf-8")
        use_resume = resume and transcript_exists(job.session_id)
        if not use_resume:
            job.session_id = str(uuid.uuid4())
            jobs.save(job)
        if resume:
            inspection = inspect(job)
            (res / f"inspect-{attempt}.txt").write_text(inspection, encoding="utf-8")
            prompt = (RESUME.format(attempt=attempt, inspection=inspection) if use_resume else
                      (jd / "prompt.md").read_text(encoding="utf-8")
                      + FRESH_AFTER_INTERRUPT.format(inspection=inspection))
        else:
            prompt = (jd / "prompt.md").read_text(encoding="utf-8")
        if not shutil.which("claude"):
            _log(log, "ws-agent: claude isn't on PATH")
            return finish(1, is_error=True, reason="no claude")
        argv = ["timeout", "--kill-after=60s", job.timeout,
                *claude_argv(job, jd, resume=use_resume, rules=permission_rules(job, entry.commands))]
        _log(log, f"ws-agent: running claude ({'resume ' + job.session_id if use_resume else 'session ' + job.session_id})")
        with open(res / "claude.json", "wb") as out:
            rc = _run_claude(job, argv, prompt, out, log, jd / "wc", clean_env(os.environ, bindir, job.id))
        out_info = _claude_result(res / "claude.json")
        warnings = collect(job, jd)
        is_error = bool(out_info.get("is_error", rc != 0))
        code = rc if rc != 0 else (1 if is_error else 0)
        return finish(code, is_error=is_error, timed_out=rc == 124,
                      session_id=str(out_info.get("session_id") or job.session_id),
                      num_turns=out_info.get("num_turns"), duration_ms=out_info.get("duration_ms"),
                      warnings=len(warnings))
