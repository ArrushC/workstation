from pathlib import Path

from workstation_tui.core.models import (
    HostContext,
    HostEntry,
    InventoryRow,
    PendingChange,
)
from workstation_tui.core.summary import gather_summary

CTX = HostContext(
    os="linux", is_wsl=False, group="dev_machine", mode="dev",
    has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
)


def test_gather_summary_composes(tmp_path: Path) -> None:
    (tmp_path / "fzf-0.74.2.done").touch()
    rows = [
        InventoryRow(kind="scope", name="fzf", version="0.74.2"),
        InventoryRow(kind="scope", name="zellij", version="0.44.3"),
    ]
    s = gather_summary(
        tmp_path,
        context=CTX,
        stamp_dir=tmp_path,
        read_inventory=lambda root, mode: (rows, []),
        read_status=lambda: ([PendingChange(code="MM", path=".zshrc")], []),
        read_hosts=lambda root: (
            [HostEntry(name="a", address="1.2.3.4", user="u", group="dev_machine"),
             HostEntry(name="b", address="1.2.3.5", user="u", group="prod_machine")],
            [],
        ),
    )
    assert (s.tools_total, s.tools_fresh, s.tools_stale, s.tools_missing) == (2, 1, 0, 1)
    assert s.dotfiles_pending == 1
    assert (s.hosts_total, s.hosts_dev, s.hosts_prod) == (2, 1, 1)
    assert s.context.mode == "dev"


def test_gather_summary_propagates_errors(tmp_path: Path) -> None:
    s = gather_summary(
        tmp_path,
        context=CTX,
        stamp_dir=tmp_path,
        read_inventory=lambda root, mode: ([], ["make inventory failed"]),
        read_status=lambda: ([], ["chezmoi status failed"]),
        read_hosts=lambda root: ([], ["hosts.conf unreadable"]),
    )
    assert s.inventory_errors and s.dotfiles_errors and s.hosts_errors
    assert s.tools_total == 0
