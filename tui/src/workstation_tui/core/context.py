"""Resolve host identity + capabilities once at startup.

Group comes from `chezmoi data` (.group — set by .chezmoi.toml.tmpl from
WORKSTATION_GROUP at init). WSL detection mirrors bootstrap.sh is_wsl():
"microsoft" in /proc/version, case-insensitive. Unknown group → prod mode
(the no-sudo scope is the safe default).
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

from workstation_tui.core.models import HostContext


def _detect_group(run) -> str | None:
    try:
        proc = run(
            ["chezmoi", "data", "--format", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            return None
        value = json.loads(proc.stdout).get("group")
        return value if isinstance(value, str) else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def detect_context(
    *,
    which=shutil.which,
    run=subprocess.run,
    proc_version: Path = Path("/proc/version"),
    platform: str = sys.platform,
) -> HostContext:
    os_name = "windows" if platform.startswith("win") else "linux"
    try:
        is_wsl = os_name == "linux" and "microsoft" in proc_version.read_text().lower()
    except OSError:
        is_wsl = False
    group = _detect_group(run) if which("chezmoi") else None
    return HostContext(
        os=os_name,
        is_wsl=is_wsl,
        group=group,
        mode="dev" if group == "dev_machine" else "prod",
        has_make=which("make") is not None,
        has_chezmoi=which("chezmoi") is not None,
        has_systemctl=which("systemctl") is not None,
        has_sudo=which("sudo") is not None,
    )
