"""Paths, host state, subprocess and terminal helpers shared by every ws command."""

from __future__ import annotations

import datetime as _dt
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

IS_WINDOWS = os.name == "nt"
OS = "windows" if IS_WINDOWS else "linux"

WS_DIR = Path(__file__).resolve().parent.parent  # scripts/ws
WS_PY = WS_DIR / "ws.py"


def home() -> Path:
    # $HOME on Linux (a scratch HOME in tests), %USERPROFILE% on Windows: the home
    # `mise -C` is pinned to, as every ws* command pins it.
    return Path(os.path.expanduser("~"))


def repo() -> Path:
    """This checkout (mise's global config dir)."""
    env = os.environ.get("WS_REPO")
    return Path(env) if env else WS_DIR.parent.parent


def state_dir() -> Path:
    """Host-specific state, never in the checkout: ~/.local/state/workstation (bootstrap.sh's
    marker dir) or %LOCALAPPDATA%\\workstation."""
    env = os.environ.get("WS_STATE_DIR")
    if env:
        return Path(env)
    if IS_WINDOWS:
        base = os.environ.get("LOCALAPPDATA") or str(home() / "AppData" / "Local")
        return Path(base) / "workstation"
    base = os.environ.get("XDG_STATE_HOME") or str(home() / ".local" / "state")
    return Path(base) / "workstation"


def config_dir() -> Path:
    """Per-host user settings for ws (projects.toml): ~/.config/workstation on both OSes."""
    env = os.environ.get("WS_CONFIG_DIR")
    if env:
        return Path(env)
    base = (not IS_WINDOWS and os.environ.get("XDG_CONFIG_HOME")) or str(home() / ".config")
    return Path(base) / "workstation"


def expand(target: str) -> Path:
    """mise's "~/x" spelling to a real path."""
    if target == "~":
        return home()
    if target.startswith(("~/", "~\\")):
        return home() / target[2:]
    return Path(target)


def tilde(path: Path | str) -> str:
    """A path for display, "~/..." under the home."""
    p = Path(path)
    try:
        rel = p.relative_to(home())
    except ValueError:
        return str(p)
    return "~" if str(rel) == "." else "~/" + rel.as_posix()


def home_key(path: Path) -> str:
    """The baseline key of a live file: its home-relative path, with forward slashes."""
    return path.relative_to(home()).as_posix()


def which(name: str) -> str | None:
    return shutil.which(name)


def run(argv: list[str], *, cwd: Path | str | None = None, env: dict[str, str] | None = None,
        capture: bool = True, input: str | None = None, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    """Run an argv (never a shell string). Captured output is text; a missing program is
    returned as exit code 127 rather than raised."""
    full_env: dict[str, str] | None = None
    if env is not None:
        full_env = dict(os.environ)
        full_env.update(env)
    try:
        return subprocess.run(
            argv, cwd=cwd, env=full_env, input=input, timeout=timeout,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            text=True, encoding="utf-8", errors="replace",
        )
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(argv, 127, "", str(e))
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(argv, 124, "", f"timed out after {e.timeout}s")


def mise_argv(*args: str) -> list[str]:
    # Pinned to the home like every ws* alias: mise finds its config root by walking up
    # from the cwd, and a stray .config/mise on the way would be managed instead.
    return ["mise", "-C", str(home()), *args]


def mise(*args: str, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return run(mise_argv(*args), capture=capture, env={"NO_COLOR": "1"} if capture else None)


def read_bytes(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except (FileNotFoundError, NotADirectoryError, IsADirectoryError):
        return None


def fingerprint(path: Path, data: bytes | None) -> tuple[str, int] | None:
    """What a plan saw of a path: the sha256 of `data` (its content as read; "" when it isn't a
    file) and its st_mode, or None when nothing was there."""
    try:
        st = path.stat()
    except OSError:
        return None if data is None else (hashlib.sha256(data).hexdigest(), -1)
    return (hashlib.sha256(data).hexdigest() if data is not None else "", st.st_mode)


def atomic_write(path: Path, data: bytes, mode: int | None = None) -> None:
    """Write via a sibling temp file and a rename, so a crash never leaves half a file. The
    temp file is created with `mode`, so a private file is never readable on the way."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.ws-tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_BINARY", 0)
    with os.fdopen(os.open(tmp, flags, 0o666 if mode is None else mode), "wb") as fh:
        fh.write(data)
    if mode is not None and not IS_WINDOWS:
        os.chmod(tmp, mode)  # noqa
    os.replace(tmp, path)


def private_dir(path: Path) -> Path:
    """`path` as a directory only its owner can enter (0700): created so, or tightened."""
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not IS_WINDOWS and path.stat().st_mode & 0o077:
        os.chmod(path, 0o700)
    return path


def is_executable(path: Path) -> bool:
    if IS_WINDOWS:
        return False
    try:
        return bool(path.stat().st_mode & 0o111)
    except OSError:
        return False


def stamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()


# --- terminal -------------------------------------------------------------------

def color_on(stream: object = None) -> bool:
    stream = stream or sys.stdout
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("WS_COLOR") == "1":
        return True
    isatty = getattr(stream, "isatty", None)
    return bool(isatty and isatty())


_CODES = {"red": "31", "green": "32", "yellow": "33", "blue": "34", "mauve": "35", "cyan": "36",
          "dim": "2", "bold": "1"}


def paint(text: str, *styles: str, on: bool | None = None) -> str:
    if on is None:
        on = color_on()
    if not on or not styles:
        return text
    codes = ";".join(_CODES[s] for s in styles)
    return f"\033[{codes}m{text}\033[0m"


def interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty() and os.environ.get("WS_NONINTERACTIVE") != "1"


def shell_join(argv: list[str]) -> str:
    """An argv as the user would type it (for display, and for fzf's preview commands)."""
    if IS_WINDOWS:
        return subprocess.list2cmdline(argv)
    return shlex.join(argv)


def self_argv(*args: str) -> list[str]:
    """This program, run by the interpreter running it now (fzf previews call back in)."""
    return [sys.executable, str(WS_PY), *args]


def emit(kind: str, value: str) -> bool:
    """Ask the calling shell's `ws` wrapper to do what a child process can't: `cd` (change
    the shell's directory) or `insert` (put a command on the prompt for the user to run).
    The wrapper passes a file in WS_OUT and reads it back; without one, say what to do."""
    out = os.environ.get("WS_OUT")
    if not out:
        return False
    with open(out, "a", encoding="utf-8") as fh:
        fh.write(f"{kind}\t{value}\n")
    return True


def shell_name() -> str:
    """The shell whose `ws` wrapper started us: zsh, bash, nu or pwsh (WS_SHELL)."""
    return os.environ.get("WS_SHELL", "")


def die(msg: str, code: int = 1) -> int:
    print(f"ws: {msg}", file=sys.stderr)
    return code
