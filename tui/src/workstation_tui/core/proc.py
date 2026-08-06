"""Synchronous passthrough runner for headless commands.

The child inherits stdout/stderr/stdin, so make's sudo prompt, chezmoi's
pager-less diff, and doctor's colored report reach the terminal untouched.
The Phase 4 async engine (runner.py) supersedes this for the TUI; the CLI
keeps using this simple path. Scrubs MAKEFLAGS/MFLAGS/MAKELEVEL for the same
reason read_inventory does: inherited jobserver flags make nested make
ignore --no-print-directory.
"""

import os
import subprocess
import sys

_SCRUB = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")


def run_passthrough(cmd: list[str], *, run=subprocess.run) -> int:
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    try:
        return run(cmd, env=env).returncode
    except FileNotFoundError:
        print(f"workstation: command not found: {cmd[0]}", file=sys.stderr)
        return 127
    except OSError as exc:
        print(f"workstation: cannot execute {cmd[0]}: {exc}", file=sys.stderr)
        return 126
