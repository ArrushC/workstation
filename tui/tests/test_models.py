import pytest
from pydantic import ValidationError

from workstation_tui.core.models import (
    HostEntry,
    InventoryRow,
    StampState,
    ToolStatus,
)


def test_stamp_state_values() -> None:
    assert StampState.FRESH.value == "fresh"
    assert StampState.STALE.value == "stale"
    assert StampState.MISSING.value == "missing"


def test_host_entry_rejects_unknown_group() -> None:
    with pytest.raises(ValidationError):
        HostEntry(name="x", address="10.0.0.1", user="u", group="staging")


def test_inventory_row_rejects_unknown_kind() -> None:
    with pytest.raises(ValidationError):
        InventoryRow(kind="magic", name="fzf", version="0.74.2")


def test_tool_status_round_trip() -> None:
    t = ToolStatus(name="fzf", kind="scope", version="0.74.2", state=StampState.FRESH)
    assert t.model_dump()["state"] == "fresh"


def test_pending_change_and_summary_round_trip() -> None:
    from workstation_tui.core.models import HostContext, PendingChange, Summary

    pc = PendingChange(code="MM", path=".claude/settings.json")
    assert pc.code == "MM"
    s = Summary(
        context=HostContext(
            os="linux", is_wsl=True, group="dev_machine", mode="dev",
            has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
        ),
        tools_total=105, tools_fresh=100, tools_stale=3, tools_missing=2,
        inventory_errors=[], dotfiles_pending=1, dotfiles_errors=[],
        hosts_total=9, hosts_dev=3, hosts_prod=6, hosts_errors=[],
    )
    assert '"tools_fresh":100' in s.model_dump_json()
