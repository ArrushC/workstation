"""Compose the dashboard rollup from the individual core readers."""

from pathlib import Path

from workstation_tui.core.chezmoi import read_status as _read_status
from workstation_tui.core.context import detect_context
from workstation_tui.core.hostsfile import read_hosts as _read_hosts
from workstation_tui.core.makeiface import read_inventory as _read_inventory
from workstation_tui.core.models import HostContext, StampState, Summary
from workstation_tui.core.stamps import DEFAULT_STAMP_DIR, scan


def gather_summary(
    repo_root: Path,
    *,
    context: HostContext | None = None,
    stamp_dir: Path | None = None,
    read_inventory=_read_inventory,
    read_status=_read_status,
    read_hosts=_read_hosts,
) -> Summary:
    ctx = context if context is not None else detect_context()
    rows, inv_errors = read_inventory(repo_root, ctx.mode)
    statuses = scan(stamp_dir if stamp_dir is not None else DEFAULT_STAMP_DIR, rows)
    pending, dot_errors = read_status()
    hosts, host_errors = read_hosts(repo_root)
    return Summary(
        context=ctx,
        tools_total=len(statuses),
        tools_fresh=sum(t.state is StampState.FRESH for t in statuses),
        tools_stale=sum(t.state is StampState.STALE for t in statuses),
        tools_missing=sum(t.state is StampState.MISSING for t in statuses),
        inventory_errors=inv_errors,
        dotfiles_pending=len(pending),
        dotfiles_errors=dot_errors,
        hosts_total=len(hosts),
        hosts_dev=sum(h.group == "dev_machine" for h in hosts),
        hosts_prod=sum(h.group == "prod_machine" for h in hosts),
        hosts_errors=host_errors,
    )
