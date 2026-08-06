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
