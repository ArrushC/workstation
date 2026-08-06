"""chezmoi read layer + mutation command builders.

Reads never raise (rc!=0 / missing binary / timeout become error strings).
Mutations are BUILDERS only — the CLI/TUI streams them via proc.run_passthrough,
always after an in-band diff + explicit confirm, hence the hard-wired --force
(chezmoi's own overwrite prompts hang non-interactive runs; repo memory).
Chezmoi surfaces deliberately ignore WORKSTATION_REPO: reads and mutations always target the user's real chezmoi-configured source, never an override.
"""

import re
import subprocess

from workstation_tui.core.models import PendingChange

# `chezmoi status` porcelain: two status chars, space, target path.
_STATUS_RE = re.compile(r"^([A-Z ]{2}) (.+)$")


def parse_status_text(text: str) -> tuple[list[PendingChange], list[str]]:
    changes: list[PendingChange] = []
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        m = _STATUS_RE.match(line)
        if m is None:
            errors.append(f"line {lineno}: not a chezmoi status row: {line!r}")
            continue
        changes.append(PendingChange(code=m.group(1), path=m.group(2)))
    return changes, errors


def read_status(*, run=subprocess.run) -> tuple[list[PendingChange], list[str]]:
    try:
        proc = run(["chezmoi", "status"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return [], [f"chezmoi status failed: {exc}"]
    if proc.returncode != 0:
        return [], [f"chezmoi status failed (rc={proc.returncode}): {proc.stderr.strip()}"]
    return parse_status_text(proc.stdout)


def diff_command() -> list[str]:
    return ["chezmoi", "diff"]


def apply_command() -> list[str]:
    return ["chezmoi", "apply", "--force"]


def update_command() -> list[str]:
    return ["chezmoi", "update", "--force"]
