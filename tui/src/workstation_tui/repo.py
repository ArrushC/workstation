"""Locate the workstation repo checkout (the chezmoi source dir)."""

import os
from pathlib import Path

import workstation_tui


def _is_repo(path: Path) -> bool:
    return (path / "makefile" / "Makefile").is_file()


def find_repo_root() -> Path | None:
    env = os.environ.get("WORKSTATION_REPO")
    if env:
        p = Path(env).expanduser()
        if _is_repo(p):
            return p
        # An explicit override that's wrong must fail loudly, not silently
        # retarget mutations at the default checkout.
        return None
    default = Path.home() / ".local/share/chezmoi"
    if _is_repo(default):
        return default
    # Editable install: tui/src/workstation_tui/__init__.py -> repo is parents[3].
    editable = Path(workstation_tui.__file__).resolve().parents[3]
    if _is_repo(editable):
        return editable
    return None
