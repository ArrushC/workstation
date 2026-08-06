"""Fleet reachability probes + hosts.conf mutation command builders.

The TUI never writes hosts.conf directly — `manage_hosts_add_command` and
`manage_hosts_remove_command` (which shell out to the parity-pair
`scripts/manage-hosts.sh` / `scripts/manage-hosts.ps1`) are the ONLY
mutation path. This module builds argv lists; callers execute them via the
runner.
"""

import asyncio
from pathlib import Path
from typing import Literal

from workstation_tui.core.models import HostEntry


async def probe_host(
    address: str, *, port: int = 22, timeout: float = 3.0
) -> Literal["up", "down"]:
    """TCP-connect probe. ANY exception (timeout, refused, unreachable, ...) -> "down"."""
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(address, port), timeout=timeout
        )
    except Exception:
        return "down"
    try:
        writer.close()
        wait_closed = getattr(writer, "wait_closed", None)
        if wait_closed is not None:
            await wait_closed()
    except Exception:
        pass
    return "up"


async def probe_all(
    entries: list[HostEntry], *, probe=probe_host
) -> dict[str, str]:
    """Probe every entry's address concurrently; return name -> state."""
    states = await asyncio.gather(*(probe(entry.address) for entry in entries))
    return {entry.name: state for entry, state in zip(entries, states, strict=True)}


def push_command(repo_root: Path, name: str | None) -> list[str]:
    """Build the `update-hosts.sh` argv: bare pushes all hosts, --name scopes one."""
    cmd = [str(repo_root / "scripts" / "update-hosts.sh")]
    if name is not None:
        cmd += ["--name", name]
    return cmd


def manage_hosts_add_command(
    repo_root: Path, entry: HostEntry, *, os_name: str = "linux"
) -> list[str]:
    """Build the manage-hosts --add argv for the given HostEntry."""
    if os_name == "windows":
        script = repo_root / "scripts" / "manage-hosts.ps1"
        return [
            "powershell.exe",
            "-NoProfile",
            "-File",
            str(script),
            "-Add",
            "-Name",
            entry.name,
            "-Ip",
            entry.address,
            "-User",
            entry.user,
            "-Group",
            entry.group,
            "-SkipConfirm",
        ]
    script = repo_root / "scripts" / "manage-hosts.sh"
    return [
        "bash",
        str(script),
        "--add",
        "--name",
        entry.name,
        "--ip",
        entry.address,
        "--user",
        entry.user,
        "--group",
        entry.group,
        "--skip-confirm",
    ]


def manage_hosts_remove_command(
    repo_root: Path, name: str, *, os_name: str = "linux"
) -> list[str]:
    """Build the manage-hosts --remove argv for the given host name."""
    if os_name == "windows":
        script = repo_root / "scripts" / "manage-hosts.ps1"
        return [
            "powershell.exe",
            "-NoProfile",
            "-File",
            str(script),
            "-Remove",
            "-Name",
            name,
            "-SkipConfirm",
        ]
    script = repo_root / "scripts" / "manage-hosts.sh"
    return [
        "bash",
        str(script),
        "--remove",
        "--name",
        name,
        "--skip-confirm",
    ]
