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


def _under(p: Path, root: Path) -> bool:
    return p == root or root in p.parents


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


def _base(bw: str, home: Path) -> list[str]:
    return [bw, "--die-with-parent", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
            "--tmpfs", "/tmp", "--tmpfs", str(home)]


def wrap(argv: list[str], *, job_id: str, wc: Path, rw: Sequence[Path] = (), ro: Sequence[Path] = (),
         network: bool = True, chdir: Path | None = None) -> list[str]:
    bw = bwrap()
    if not bw:
        raise SandboxError("ws-agent: bwrap isn't installed (dnf install bubblewrap); jobs don't run without it")
    home = core.home().resolve()
    jd = jobs.job_dir(job_id).resolve()
    wc = wc.resolve()
    args = _base(bw, home)
    base_ro = [home / ".local" / "share" / "mise", home / ".local" / "bin", core.WS_DIR,
               Path(sys.prefix), Path(sys.base_prefix)]
    bound: list[Path] = []
    for p in (*base_ro, *ro):
        p = p.resolve()
        if p.exists() and p not in bound:
            args += ["--ro-bind", str(p), str(p)]
            bound.append(p)
    for p in (jd, *rw):
        p = p.resolve()
        if p.exists():
            args += ["--bind", str(p), str(p)]
            bound.append(p)
    hidden_roots = (home, Path("/tmp"))
    for h in hidden_paths(job_id):
        h = h.resolve() if h.exists() else h
        if not h.exists() or _under(jd, h) or _under(wc, h):
            continue
        visible = not any(_under(h, r) for r in hidden_roots) or any(_under(h, b) for b in bound)
        if not visible:
            continue
        args += ["--tmpfs", str(h)] if h.is_dir() else ["--ro-bind", "/dev/null", str(h)]
    common = _git_common_dir(wc)
    if common is not None and common.exists():
        args += ["--ro-bind", str(common), str(common)]
    if not network:
        args.append("--unshare-net")
    args += ["--chdir", str((chdir or wc).resolve()), "--", *argv]
    return args


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
