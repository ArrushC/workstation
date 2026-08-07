"""Health check readers — registry, availability gating, cache, service/interop state.

Checks run unprivileged (MODE=prod-safe); the cache is the only file the TUI writes.
"""

import json
import os
import subprocess
from pathlib import Path
from typing import Callable

from workstation_tui.core.makeiface import make_command
from workstation_tui.core.models import CheckResult, HealthCheck, HostContext

# Module-level constant for WSL interop path (monkeypatchable for testing)
_INTEROP_PATH = Path("/proc/sys/fs/binfmt_misc/WSLInterop")

# Service units mapping
_SERVICE_UNITS = {
    "docker": "docker",
    "dozzle": "dozzle",
    "cockpit": "cockpit.socket",
    "rsyslog": "rsyslog",
}

# Health check registry
CHECKS: list[HealthCheck] = [
    HealthCheck(
        check_id="doctor",
        label="doctor",
        kind="make",
        goals=["doctor"],
    ),
    HealthCheck(
        check_id="check-updates",
        label="check-updates",
        kind="make",
        goals=["check-updates"],
    ),
    HealthCheck(
        check_id="invariants",
        label="invariants",
        kind="script",
        goals=["scripts/check-invariants.sh"],
    ),
    HealthCheck(
        check_id="templates",
        label="templates",
        kind="script",
        goals=["scripts/check-templates.sh"],
    ),
]


def check_available(check: HealthCheck, ctx: HostContext) -> str | None:
    """Check if a health check is available.

    Returns None if available, otherwise a reason string.
    - make-kind needs ctx.has_make
    - script-kind always available on linux, unavailable on windows
    """
    if check.kind == "make" and not ctx.has_make:
        return "make is not available"
    if check.kind == "script" and ctx.os == "windows":
        return "bash scripts are Linux-side"
    return None


def check_command(repo_root: Path, check: HealthCheck, mode: str) -> list[str]:
    """Build the command to run a health check.

    make-kind: calls make_command with goals
    script-kind: ["bash", path/to/script, *args]
    """
    if check.kind == "make":
        return make_command(repo_root, check.goals, mode)
    else:  # script
        return ["bash", str(repo_root / check.goals[0]), *check.goals[1:]]


def load_cache(path: Path) -> dict[str, CheckResult]:
    """Load health check cache from JSON.

    Returns {} on missing file, corrupt JSON, or schema mismatch.
    Never raises.
    """
    try:
        if not path.exists():
            return {}
        text = path.read_text()
        data = json.loads(text)
        result = {}
        for check_id, record in data.items():
            try:
                result[check_id] = CheckResult(**record)
            except (TypeError, ValueError):
                # Schema mismatch or invalid data
                return {}
        return result
    except Exception:
        # Missing file, corrupt JSON, read error, etc.
        return {}


def save_cache(path: Path, results: dict[str, CheckResult]) -> None:
    """Save health check results to JSON cache atomically.

    Uses tmp + os.replace pattern; creates parents if needed.
    Never raises.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = path.with_suffix(".tmp")
        data = {check_id: result.model_dump() for check_id, result in results.items()}
        tmp_path.write_text(json.dumps(data, indent=2))
        os.replace(tmp_path, path)
    except Exception:
        # Write error, permission issue, etc.
        pass


def read_services(*, run: Callable = subprocess.run) -> dict[str, str]:
    """Read systemctl service states.

    For each service (docker, dozzle, cockpit.socket, rsyslog):
    - rc 0: "active"
    - rc != 0: "inactive"
    - exception: "unknown"

    Never raises.
    """
    states = {}
    for service_name, unit in _SERVICE_UNITS.items():
        try:
            proc = run(
                ["systemctl", "is-active", unit],
                capture_output=True,
                text=True,
                timeout=5,
            )
            states[service_name] = "active" if proc.returncode == 0 else "inactive"
        except Exception:
            states[service_name] = "unknown"
    return states


def read_wsl_interop() -> str:
    """Read WSL interop state.

    - first line "enabled": "enabled"
    - readable but other: "disabled"
    - unreadable/absent: "absent"

    Never raises.
    """
    try:
        if not _INTEROP_PATH.exists():
            return "absent"
        text = _INTEROP_PATH.read_text().strip()
        if text.startswith("enabled"):
            return "enabled"
        else:
            return "disabled"
    except Exception:
        # Permission error, read error, etc.
        return "absent"
