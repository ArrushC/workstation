"""Dynamic footer keys: #key-bar shows global + active-panel bindings."""

from textual.binding import Binding
from textual.widgets import DataTable

from workstation_tui.app.app import PANEL_KEYS, WorkstationApp
from workstation_tui.app.panels.dotfiles import DotfilesPanel
from workstation_tui.app.panels.fleet import FleetPanel
from workstation_tui.app.panels.health import HealthPanel
from workstation_tui.app.panels.provision import ProvisionPanel
from tests.test_app_shell import fake_provider


def make_app() -> WorkstationApp:
    return WorkstationApp(summary_provider=fake_provider)


async def test_boot_shows_dashboard_keys() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        footer = str(app.query_one("#key-bar").content)
        assert "Move" in footer
        assert "Help" in footer


async def test_provision_panel_swaps_footer_keys() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        footer = str(app.query_one("#key-bar").content)
        assert "Clean" in footer
        assert "Move" not in footer


async def test_fleet_panel_shows_push_all() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        footer = str(app.query_one("#key-bar").content)
        assert "Push all" in footer


async def test_health_panel_shows_run_all() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        footer = str(app.query_one("#key-bar").content)
        assert "Run all" in footer


async def test_provision_keys_static_removed() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert len(app.query("#provision-keys")) == 0


async def test_key_bar_shows_panel_keys_before_global_keys() -> None:
    """Finding 1: panel keys render FIRST, global keys LAST — #key-bar is
    height:1, so a narrow terminal (~140 cols) clips the tail of the line,
    and the tail must be the boilerplate ("1-5 Panels ... ? Help"), not the
    panel-specific hints that are the actually-new information."""
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")  # provision
        footer = str(app.query_one("#key-bar").content)
        assert footer.index("Run") < footer.index("Help")
        assert footer.index("Clean") < footer.index("Panels")


def _binding_keys(widget_cls: type) -> set[str]:
    """Extract the flat set of key names a widget class's BINDINGS covers
    (each entry may be a `Binding` instance or a bare (key, action, desc)
    tuple; a `key` may itself be a comma-separated alias list)."""
    keys: set[str] = set()
    for entry in widget_cls.BINDINGS:
        raw_key = entry.key if isinstance(entry, Binding) else entry[0]
        keys.update(raw_key.split(","))
    return keys


def test_panel_keys_are_real_bindings_on_their_panel() -> None:
    """Drift guard: every footer hint in PANEL_KEYS must name a key that
    actually does something on that panel — otherwise the footer is lying
    about what pressing the key will do.

    Dashboard is excluded: its "←→↑↓"/"enter" hints describe Card's
    BINDINGS (see dashboard.py), not a DashboardPanel-level binding, and
    "←→↑↓" isn't a single literal key to look up in the first place — this
    is the pragmatic "skip or check Card.BINDINGS" case called out for this
    guard; documented here instead of asserting against Card directly, since
    the combined-arrow glyph has no 1:1 key-string form to check.

    Health's "enter" hint is likewise not a HealthPanel-level Binding — the
    row-select is DataTable's own built-in `enter -> select_cursor`
    (surfaced to HealthPanel via `on_data_table_row_selected`, not a
    HealthPanel BINDINGS entry) — so DataTable's own bindings are folded in
    for that one panel only.
    """
    panel_classes: dict[str, type] = {
        "provision": ProvisionPanel,
        "dotfiles": DotfilesPanel,
        "fleet": FleetPanel,
        "health": HealthPanel,
    }
    for panel_id, panel_cls in panel_classes.items():
        available = _binding_keys(panel_cls)
        if panel_id == "health":
            available |= _binding_keys(DataTable)
        for key, label in PANEL_KEYS[panel_id]:
            assert key in available, (
                f"PANEL_KEYS[{panel_id!r}] hints {key!r} ({label!r}) but "
                f"{panel_cls.__name__}.BINDINGS has no such key"
            )
