"""ws-agent's own sandbox around every engine run and every check (bubblewrap).

Whatever an engine reads goes to its model provider, so this layer is about reads as much as
writes. Everything is read-only; `/tmp` and the home directory are empty throwaway layers; only
the job's directory (and what a caller names in `rw`) is writable and kept. What it hides:

- the home directory, apart from what the engine and the shims need (mise's installs and
  shims, ~/.local/bin, this checkout's scripts/ws, the Python running ws, and the engine's own
  paths the caller passes);
- the other jobs' directories, every registered working copy (a git job's repository `.git`
  comes back read-only: its worktree needs the objects), and `[sandbox] hide` in agents.toml,
  because working copies outside the home directory (/data/svn/...) can't be found otherwise.

The network stays (the engine has to reach its provider) unless `network=False` (checks). An
engine's own sandbox runs nested inside this one and confines its shell commands further.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from . import agent_registry, core, jobs

CACHE_TTL = 24 * 3600


class SandboxError(Exception):
    pass


def bwrap() -> str | None:
    return shutil.which("bwrap")


def hidden_paths(job_id: str) -> list[Path]:
    """Every other job's directory, every registered repository, and the per-host hide list."""
    found: list[Path] = []
    jd = jobs.jobs_dir()
    if jd.is_dir():
        found += [p for p in sorted(jd.iterdir()) if p.is_dir() and p.name != job_id]
    found += [r.path.resolve() for r in agent_registry.load()[0].values()]
    found += list(agent_registry.settings().hide)
    return found


def surrounding_paths() -> list[Path]:
    """The folder around each registered copy outside the home directory (/data/svn/projB →
    /data/svn): unregistered code beside it (/data/svn/projA) is hidden too, never the root."""
    home = core.home().resolve()
    found = []
    for r in agent_registry.load()[0].values():
        parent = r.path.resolve().parent
        if parent != Path("/") and not _under(home, parent) and not _under(parent, home) and parent not in found:
            found.append(parent)
    return found


def _under(p: Path, root: Path) -> bool:
    return p == root or root in p.parents


# A git config can hold credentials: a token in a remote URL, an http.extraheader, a credential
# helper's settings. The engine sees a copy without those lines (and without [credential] and
# [http] sections); git still works from the rest.
_GIT_SECRET_KEY = re.compile(r"(?i)^\s*(url|pushurl|insteadof|pushinsteadof|extraheader|helper|password|token|"
                             r"cookiefile|sslkey|sslcert\w*|proxy\w*)\s*=")
_GIT_SECRET_SECTION = re.compile(r"(?i)^\s*\[\s*(credential|http)\b")


def sanitize_git_config(text: str) -> str:
    out: list[str] = []
    skipping = False
    for line in text.splitlines():
        if line.strip().startswith("["):
            skipping = bool(_GIT_SECRET_SECTION.match(line))
            if not skipping:
                out.append(line)
            continue
        if not skipping and not _GIT_SECRET_KEY.match(line):
            out.append(line)
    return "\n".join(out) + "\n"


def _git_configs(common: Path) -> list[Path]:
    return [p for p in (common / "config", common / "config.worktree", *common.glob("modules/**/config"),
                        *common.glob("worktrees/*/config.worktree")) if p.is_file()]


def _git_common_dir(wc: Path) -> Path | None:
    """The repository .git a worktree's `.git` file points into (…/.git/worktrees/<name>)."""
    try:
        text = (wc / ".git").read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("gitdir:"):
        return None
    gd = Path(text.split(":", 1)[1].strip())
    gd = gd if gd.is_absolute() else (wc / gd).resolve()
    return gd.parent.parent if gd.parent.name == "worktrees" else gd


# Blank in every sandbox, whatever the registry says: Windows drives under WSL (/mnt), removable
# media, and the other accounts' homes. Nothing an engine needs lives there, and whatever it can
# read can reach its provider. What a run does need under one of them (its job directory, a
# worktree's .git) is bound back after. A run that reads no code (triage) loses more.
BLANK = ("/mnt", "/media", "/home", "/root")
BLANK_SCRATCH = (*BLANK, "/srv", "/var/tmp")


def _base(bw: str, home: Path, blank: Sequence[str] = BLANK) -> list[str]:
    args = [bw, "--die-with-parent", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
    for d in blank:   # before the home layer: /home goes blank, then the person's own home is made on it
        if Path(d).is_dir() and not Path(d).is_symlink():
            args += ["--tmpfs", d]
    return [*args, "--tmpfs", str(home)]


def _layout(bw: str, *, own: Path, keep: Sequence[Path], hidden: list[Path], rw: Sequence[Path],
            ro: Sequence[Path], blank: Sequence[str] = BLANK) -> list[str]:
    """The layout every sandbox shares: everything read-only, /tmp and the home directory empty,
    the tools and `ro` bound back read-only, `own` and `rw` writable, and `hidden` (with the folders
    around outside registered copies) covered, except a path that holds `own` or `keep`."""
    home = core.home().resolve()
    args = _base(bw, home, blank)
    base_ro = [home / ".local" / "share" / "mise", home / ".local" / "bin", core.WS_DIR,
               Path(sys.prefix), Path(sys.base_prefix)]
    bound: list[Path] = []
    for p in (*base_ro, *ro):
        p = p.resolve()
        if p.exists() and p not in bound:
            args += ["--ro-bind", str(p), str(p)]
            bound.append(p)
    for p in (own, *rw):
        p = p.resolve()
        if p.exists():
            args += ["--bind", str(p), str(p)]
            bound.append(p)
    hidden_roots = (home, Path("/tmp"), *(Path(d) for d in blank))
    # Folders around outside registered copies go first and are skipped when they hold anything the
    # run needs (its directory, a bound tool); the named paths then go over them.
    candidates = [(h, True) for h in surrounding_paths()] + [(h, False) for h in hidden]
    for h, surrounding in candidates:
        h = h.resolve() if h.exists() else h
        if not h.exists() or any(_under(k, h) for k in (own, *keep)):
            continue
        if surrounding and any(_under(b, h) for b in bound):
            continue
        visible = not any(_under(h, r) for r in hidden_roots) or any(_under(h, b) for b in bound)
        if not visible:
            continue
        args += ["--tmpfs", str(h)] if h.is_dir() else ["--ro-bind", "/dev/null", str(h)]
    return args


def _bwrap_or_raise() -> str:
    bw = bwrap()
    if not bw:
        raise SandboxError("ws-agent: bwrap isn't installed (dnf install bubblewrap); jobs don't run without it")
    return bw


def wrap(argv: list[str], *, job_id: str, wc: Path, rw: Sequence[Path] = (), ro: Sequence[Path] = (),
         network: bool = True, chdir: Path | None = None) -> list[str]:
    bw = _bwrap_or_raise()
    jd = jobs.job_dir(job_id).resolve()
    wc = wc.resolve()
    args = _layout(bw, own=jd, keep=(wc,), hidden=hidden_paths(job_id), rw=rw, ro=ro)
    common = _git_common_dir(wc)
    if common is not None and common.exists():
        args += ["--ro-bind", str(common), str(common)]
        clean = jd / "git-config"
        clean.mkdir(exist_ok=True)
        for i, cfg in enumerate(_git_configs(common)):
            copy = clean / f"{i}.config"
            try:
                copy.write_text(sanitize_git_config(cfg.read_text(encoding="utf-8", errors="replace")), encoding="utf-8")
            except OSError:
                continue
            args += ["--ro-bind", str(copy), str(cfg)]
    if not network:
        args.append("--unshare-net")
    args += ["--chdir", str((chdir or wc).resolve()), "--", *argv]
    return args


def wrap_scratch(argv: list[str], *, workdir: Path, ro: Sequence[Path] = (), rw: Sequence[Path] = ()) -> list[str]:
    """wrap's layout for a run that reads no code (triage): `workdir` (and the engine's `rw`) is
    all it may write, every job directory and registered copy is hidden, and the network stays,
    since the engine has to reach its provider."""
    bw = _bwrap_or_raise()
    workdir = workdir.resolve()
    args = _layout(bw, own=workdir, keep=(), hidden=hidden_paths(""), rw=rw, ro=ro, blank=BLANK_SCRATCH)
    return [*args, "--chdir", str(workdir), "--", *argv]


def _cache() -> Path:
    return core.state_dir() / "agent-sandbox.json"


def probe(*, force: bool = False) -> str | None:
    """None when the sandbox works on this host (an outer no-op and a nested bwrap with its own
    network namespace, which is what the engines' sandboxes need), else why not. A success is
    cached for a day; a failure is checked again next time."""
    if not force:
        try:
            data = json.loads(_cache().read_text(encoding="utf-8"))
            if data.get("ok") is True and time.time() - float(data.get("at", 0)) < CACHE_TTL:
                return None
        except (OSError, ValueError, TypeError):
            pass
    bw = bwrap()
    if not bw:
        return "bwrap isn't installed (dnf install bubblewrap)"
    argv = [*_base(bw, core.home().resolve()), "--",
            bw, "--ro-bind", "/", "/", "--dev", "/dev", "--unshare-net", "--", "true"]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"bwrap didn't run: {e}"
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).strip().splitlines()[-1:] or [f"exit {r.returncode}"]
        return f"bwrap can't make a sandbox here: {tail[0]}"
    core.private_dir(core.state_dir())
    core.atomic_write(_cache(), json.dumps({"ok": True, "at": time.time(), "checked": core.now_iso()}).encode())
    return None
