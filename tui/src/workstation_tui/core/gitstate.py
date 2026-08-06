"""Source-repo git state for the Dotfiles panel (never raises)."""

import subprocess
from pathlib import Path

from workstation_tui.core.models import GitState


def read_git_state(repo_root: Path, *, run=subprocess.run) -> tuple[GitState | None, list[str]]:
    try:
        proc = run(
            ["git", "-C", str(repo_root), "status", "--porcelain=v2", "--branch"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, [f"git status failed: {exc}"]
    if proc.returncode != 0:
        return None, [f"git status failed (rc={proc.returncode}): {proc.stderr.strip()}"]
    branch, ahead, behind, dirty = "?", 0, 0, False
    for line in proc.stdout.splitlines():
        if line.startswith("# branch.head "):
            branch = line.removeprefix("# branch.head ").strip()
        elif line.startswith("# branch.ab "):
            parts = line.removeprefix("# branch.ab ").split()
            try:
                ahead = int(parts[0].lstrip("+"))
                behind = int(parts[1].lstrip("-"))
            except (IndexError, ValueError):
                ahead, behind = 0, 0  # malformed ab line — treat as no divergence
        elif line and not line.startswith("#"):
            dirty = True
    return GitState(branch=branch, dirty=dirty, ahead=ahead, behind=behind), []
