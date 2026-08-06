"""sudo timestamp helpers for the TUI's privileged-command gate.

The overlay flow (spec §Execution engine): `sudo -n -v` short-circuits when
the timestamp is already valid; otherwise the app collects a password and
validates it via `sudo -S -v` — the real command then runs unmodified and
make's internal $(SUDO) calls hit the cached timestamp. The password is
passed straight to stdin and never stored or logged.
"""

import subprocess
from typing import Literal


def sudo_status(*, run=subprocess.run) -> Literal["valid", "needs_password", "no_sudo"]:
    try:
        proc = run(["sudo", "-n", "-v"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return "no_sudo"
    return "valid" if proc.returncode == 0 else "needs_password"


def sudo_validate(password: str, *, run=subprocess.run) -> bool:
    try:
        proc = run(
            ["sudo", "-S", "-v"],
            input=password + "\n",
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0
