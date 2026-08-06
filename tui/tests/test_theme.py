from workstation_tui.app.theme import (
    HOST_ICONS,
    M,
    MOCHA_CSS,
    ROLE,
    STAMP_ICONS,
    TASK_ICONS,
    icon,
    kb,
    keycap,
    muted,
)
from workstation_tui.core.models import StampState


def test_palette_is_verbatim_catppuccin_mocha() -> None:
    assert len(M) == 20
    assert M["base"] == "#1e1e2e"
    assert M["mauve"] == "#cba6f7"
    assert M["green"] == "#a6e3a1"
    assert M["overlay0"] == "#6c7086"


def test_role_semantics() -> None:
    assert ROLE["title"] == M["mauve"]
    assert ROLE["accent"] == M["blue"]
    assert ROLE["danger"] == M["red"]
    assert ROLE["muted"] == M["overlay0"]


def test_markup_helpers() -> None:
    assert keycap("q") == f"[bold {M['blue']} on {M['surface0']}] q [/]"
    bar = kb(("q", "Quit"), ("g", "Refresh"))
    assert "Quit" in bar and "Refresh" in bar
    assert muted("x") == f"[{M['overlay0']}]x[/]"


def test_icon_fallback_and_task_icons() -> None:
    assert icon("running").plain == "⟳"
    assert icon("nonsense").plain == "?"
    assert set(TASK_ICONS) == {"pending", "running", "done", "failed"}


def test_workstation_vocabulary_covers_stamp_states() -> None:
    assert set(STAMP_ICONS) == {s.value for s in StampState}
    assert STAMP_ICONS["fresh"] == ("✓", M["green"])
    assert STAMP_ICONS["stale"] == ("⟳", M["yellow"])
    assert STAMP_ICONS["missing"] == ("✗", M["red"])
    assert set(HOST_ICONS) == {"up", "down", "unknown"}


def test_css_bundle_composes() -> None:
    assert "App, Screen" in MOCHA_CSS
    assert M["base"] in MOCHA_CSS
    assert "#key-bar" in MOCHA_CSS
