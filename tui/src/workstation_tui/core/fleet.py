"""Fleet reachability probes + hosts.conf mutation command builders.

The TUI never writes hosts.conf directly — `manage_hosts_add_command` and
`manage_hosts_remove_command` (which shell out to the parity-pair
`scripts/manage-hosts.sh` / `scripts/manage-hosts.ps1`) are the ONLY
mutation path. This module builds argv lists; callers execute them via the
runner.
"""

import asyncio
import contextlib
from pathlib import Path
from typing import Literal

from workstation_tui.core.models import HostEntry

#: Coarse boundaries (seconds) for `rel_age` below — chosen so a fresh push
#: reads in seconds, a same-session push in minutes, a same-day push in
#: hours, and anything older in whole days.
_AGE_MINUTE = 60
_AGE_HOUR = 3600
_AGE_DAY = 86400


def rel_age(delta_secs: float) -> str:
    """Coarse relative-age label for a `last_push` timestamp (spec §1):
    `<60s` -> `"42s"`, `<3600s` -> `"7m"`, `<86400s` -> `"3h"`, else ->
    `"2d"` (int floor throughout — never rounds up past a boundary).

    Pure function, module-level (not a method) so the Fleet table's push
    column, HostStatsScreen's stamp-age field, and any future consumer
    (e.g. a health/last-run column) can import it directly without
    touching a `FleetPanel` instance. Lives in `core/` (textual-free) —
    `panels/fleet.py` re-exports it for backward-compatible imports, and
    `widgets/host_stats.py` imports it directly, avoiding the
    panels<->widgets import cycle a `panels.fleet` import would create
    (`panels/fleet.py` imports `widgets/host_stats.py` for routing).
    """
    secs = int(delta_secs)
    if secs < _AGE_MINUTE:
        return f"{secs}s"
    if secs < _AGE_HOUR:
        return f"{secs // _AGE_MINUTE}m"
    if secs < _AGE_DAY:
        return f"{secs // _AGE_HOUR}h"
    return f"{secs // _AGE_DAY}d"


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


async def probe_setup(
    entry: HostEntry,
    *,
    timeout: float = 6.0,
    exec_fn=asyncio.create_subprocess_exec,
) -> Literal["setup", "missing", "ssh-failed"]:
    """SSH-exec probe: is the workstation repo checked out on `entry`?

    Stage 2 of the two-stage fleet probe (`probe_host` is stage 1, TCP-only
    reachability). Runs a BatchMode ssh (never prompts, so it can't hang a
    worker on a password) with a short ConnectTimeout, testing for the
    `.local/share/chezmoi` checkout directory. Degrades to "ssh-failed" on
    anything but a clean 0/1 exit — a non-BatchMode-compatible host, an ssh
    process that itself hangs past `timeout` (killed before returning, so no
    zombie subprocess survives the probe), or any exception raised
    constructing/awaiting the subprocess. Never raises for an ordinary
    Exception, so one unreachable/misconfigured host can't take down
    `probe_all`'s gather.

    `asyncio.CancelledError` (BaseException, not Exception) is the one
    exception this DOES propagate — by design. Exclusive-group cancellation
    is routine here (every FleetPanel refresh restarts the probe worker via
    `run_worker(..., exclusive=True, group="probes")`, cancelling whatever
    probe cycle was still in flight), so a cancelled probe is not a failure
    to swallow into "ssh-failed". What must never happen is leaking the ssh
    child: whenever cancellation lands while a child is running, it's killed
    AND reaped (`proc.wait()` under `contextlib.suppress`, mirroring the
    timeout branch below) before the CancelledError is re-raised, so the
    orphaned-ssh-child window closes even though the probe itself aborts.
    """
    argv = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
        f"{entry.user}@{entry.address}", "test", "-d",
        ".local/share/chezmoi",
    ]
    try:
        proc = await exec_fn(
            *argv,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            rc = await asyncio.wait_for(proc.wait(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            return "ssh-failed"
        except asyncio.CancelledError:
            # Worker cancelled (routine under exclusive groups): kill + reap
            # the child, then let cancellation propagate — by design, not a
            # failure.
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            raise
    except Exception:
        return "ssh-failed"
    if rc == 0:
        return "setup"
    if rc == 1:
        return "missing"
    return "ssh-failed"


async def probe_all(
    entries: list[HostEntry], *, probe=probe_host, setup_probe=probe_setup,
    include_setup: bool = True,
) -> dict[str, tuple[str, str | None]]:
    """Probe every entry concurrently; return name -> (reachability, setup).

    Two stages per host, run back to back but hosts run concurrently with
    each other: a "down" TCP result short-circuits to `("down", None)` —
    there's no point ssh-ing into an address that isn't even reachable; an
    "up" result additionally runs `setup_probe`, giving `("up", state)`.

    `include_setup=False` (Finding 4: every refresh from ANY panel,
    including Dashboard, was escalating up to 9 concurrent ssh connections)
    skips stage 2 entirely — reachable hosts come back as `("up", None)`
    without ever invoking `setup_probe`. Callers that gate this on Fleet
    panel visibility get ssh probing only while a human is actually looking
    at the Fleet table; `None` here means "stage 2 didn't run this cycle",
    which callers holding a previous cycle's setup state should treat as
    "unknown, don't regress" rather than overwrite (see FleetPanel's
    `_merge_probe_states`).
    """

    async def _probe_one(entry: HostEntry) -> tuple[str, tuple[str, str | None]]:
        state = await probe(entry.address)
        if state == "down":
            return entry.name, ("down", None)
        if not include_setup:
            return entry.name, ("up", None)
        setup_state = await setup_probe(entry)
        return entry.name, ("up", setup_state)

    results = await asyncio.gather(*(_probe_one(entry) for entry in entries))
    return dict(results)


def zellij_ssh_command(entry: HostEntry) -> list[str]:
    """Build the ssh argv for the Fleet panel's `z` action: ssh in and
    attach (creating if absent) a remote zellij session named "main".

    The `--` before the destination is the same established option-
    injection hardening `probe_setup`/`ssh_to` use — a user/address value
    crafted to start with '-' can't be parsed as an ssh flag instead of
    part of the destination. The remote tokens (`zellij attach --create
    main`) match bootstrap.ps1's Windows Terminal fragment and Warp tab
    config generators EXACTLY, so a host behaves identically whether it's
    reached from this TUI, Windows Terminal, or Warp.
    """
    return [
        "ssh", "-t", "--", f"{entry.user}@{entry.address}",
        "zellij", "attach", "--create", "main",
    ]


def push_command(repo_root: Path, name: str) -> list[str]:
    """Build the `update-hosts.sh --name` argv for a single host.

    The bare (all-hosts) form is gone (Task 2 tightening) — a PushScreen
    run always builds one command per host (fleet.py's action_push_all
    builds one `--name`-scoped command per entry, run in parallel via
    MultiRunner, rather than shelling out to a single bare invocation).
    """
    return [str(repo_root / "scripts" / "update-hosts.sh"), "--name", name]


def copy_id_command(repo_root: Path, name: str) -> list[str]:
    """Build the manage-hosts `--copy-id --name` argv for a single host
    (Task 6, spec §3).

    Linux-only, unlike `manage_hosts_add_command`/`manage_hosts_remove_
    command` above — there is no Windows branch because `manage-hosts.ps1`
    has no `-CopyId` equivalent, and the Fleet panel's `_linux_only_gate`
    already keeps the `k` action from ever reaching a Windows host in the
    first place.
    """
    script = repo_root / "scripts" / "manage-hosts.sh"
    return ["bash", str(script), "--copy-id", "--name", name]


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
