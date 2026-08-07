"""Read-only dashboard: one live summary card per domain."""

from textual.app import ComposeResult
from textual.containers import Grid
from textual.widgets import Static

from workstation_tui.app.theme import M, STAMP_ICONS, heading, muted
from workstation_tui.core.health import CHECKS
from workstation_tui.core.models import HealthRollup, Summary

CARD_TARGETS = {
    "card-provision": "provision",
    "card-dotfiles": "dotfiles",
    "card-fleet": "fleet",
    "card-health": "health",
}

#: Short display labels for the health card's glyph line — the full
#: HealthCheck.label ("check-updates") is too wide for a quadrant card, so
#: this maps check_id -> the brief's shorter "doctor/updates/invariants/
#: templates" vocabulary. Falls back to check.label for any future check
#: this map hasn't been extended for.
_HEALTH_CARD_LABELS: dict[str, str] = {
    "doctor": "doctor",
    "check-updates": "updates",
    "invariants": "invariants",
    "templates": "templates",
}

DASHBOARD_CSS = f"""
DashboardPanel {{
    height: 1fr;
    padding: 1 1;
}}
#cards {{
    height: 1fr;
    grid-size: 2 2;
    grid-rows: 1fr 1fr;
    grid-columns: 1fr 1fr;
    grid-gutter: 1 2;
}}
.card {{
    height: 100%;
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
.card:focus {{
    border: solid {M['blue']};
}}
#dashboard-warnings {{
    color: {M['yellow']};
    padding: 0 2;
    height: auto;
}}
"""


class Card(Static, can_focus=True):
    # ContentSwitcher hides an inactive panel via `display: none` on the
    # panel widget only — it never touches focus, and Textual's own
    # focus-chain traversal (Screen.focus_chain) walks displayed_children
    # without checking whether an ANCESTOR is display:none, so a Card left
    # focused when its panel goes hidden keeps receiving key events. Worse,
    # Textual's on-hide auto-blur (Widget._on_hide -> blur() ->
    # Screen._reset_focus) re-homes focus onto a SIBLING Card still inside
    # the same hidden grid (visible_siblings only checks each sibling's own
    # .display, not its ancestors), so arrow/enter can land on a different
    # hidden card than the one that had focus a moment ago.
    #
    # `self.display` and `self.visible` were both verified NOT to reflect
    # an ancestor's display:none on this Textual version (8.2.8) — a Card
    # under a hidden DashboardPanel still reports display=True/visible=True
    # (see tui/tests/test_arrow_nav.py::test_hidden_card_focus_does_not_walk_or_teleport
    # and the mechanism note above). `Widget.is_on_screen` (public API:
    # "Check if the node was displayed in the last screen update") DOES
    # correctly return False once the ancestor panel is hidden and a screen
    # update has run — verified via the compositor's find_widget lookup —
    # so it's the guard used below instead of display/visible/region size.
    BINDINGS = [
        ("enter", "open", "Open panel"),
        ("left", "move('left')", "Move left"),
        ("right", "move('right')", "Move right"),
        ("up", "move('up')", "Move up"),
        ("down", "move('down')", "Move down"),
    ]

    def __init__(self, card_id: str) -> None:
        super().__init__("", id=card_id, classes="card", markup=True)
        self.plain = ""

    def set_content(self, markup: str, plain: str) -> None:
        self.plain = plain
        self.update(markup)

    def action_open(self) -> None:
        if not self.is_on_screen:
            return  # hidden card (another panel active) — Enter must not teleport
        self.app.switch_panel(CARD_TARGETS[self.id])  # type: ignore[attr-defined]

    def action_move(self, direction: str) -> None:
        if not self.is_on_screen:
            return  # hidden card (another panel active) — arrows must not walk
        self.app.query_one("#dashboard", DashboardPanel).move_focus(  # type: ignore[attr-defined]
            self.id, direction
        )


class DashboardPanel(Static):
    DEFAULT_CSS = DASHBOARD_CSS

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)

    def compose(self) -> ComposeResult:
        with Grid(id="cards"):
            for card_id in CARD_TARGETS:
                yield Card(card_id)
        yield Static("", id="dashboard-warnings", markup=False)

    def on_mount(self) -> None:
        for card in self.query(Card):
            card.set_content(muted("loading…"), "loading…")

    def update_summary(self, s: Summary) -> None:
        fresh_icon, fresh_col = STAMP_ICONS["fresh"]
        stale_icon, stale_col = STAMP_ICONS["stale"]
        miss_icon, miss_col = STAMP_ICONS["missing"]
        prov_plain = (f"{s.tools_fresh}/{s.tools_total} fresh · "
                      f"{s.tools_stale} stale · {s.tools_missing} missing")
        self._card("card-provision").set_content(
            heading("Provision") + "\n"
            f"[{fresh_col}]{fresh_icon} {s.tools_fresh}/{s.tools_total} fresh[/]\n"
            f"[{stale_col}]{stale_icon} {s.tools_stale} stale[/] · "
            f"[{miss_col}]{miss_icon} {s.tools_missing} missing[/]",
            prov_plain,
        )
        dot_plain = f"{s.dotfiles_pending} pending"
        dot_col = M["yellow"] if s.dotfiles_pending else M["green"]
        self._card("card-dotfiles").set_content(
            heading("Dotfiles") + f"\n[{dot_col}]{dot_plain}[/]",
            dot_plain,
        )
        fleet_plain = f"{s.hosts_total} hosts · {s.hosts_dev} dev · {s.hosts_prod} prod"
        self._card("card-fleet").set_content(
            heading("Fleet") + f"\n[{M['text']}]{s.hosts_total} hosts[/]\n"
            f"[{M['subtext0']}]{s.hosts_dev} dev · {s.hosts_prod} prod[/]",
            fleet_plain,
        )
        warnings = [*s.inventory_errors, *s.dotfiles_errors, *s.hosts_errors]
        self.query_one("#dashboard-warnings", Static).update(
            "\n".join(f"warning  {w}" for w in warnings)
        )
        self._warnings_plain = "\n".join(warnings)

    def update_health(self, r: HealthRollup) -> None:
        # Fixed-vocabulary states + theme glyphs only — every value below
        # comes from CHECKS/HealthRollup, never free-form/user text, so the
        # markup built here is safe by construction (same discipline as
        # update_summary's other cards).
        glyph_segments: list[str] = []
        glyph_plain: list[str] = []
        for check in CHECKS:
            state = r.checks.get(check.check_id)
            if state is True:
                glyph, col = "✓", M["green"]
            elif state is False:
                glyph, col = "✗", M["red"]
            else:
                glyph, col = "—", M["overlay0"]
            label = _HEALTH_CARD_LABELS.get(check.check_id, check.label)
            glyph_segments.append(f"[{col}]{glyph}[/] {label}")
            glyph_plain.append(f"{glyph} {label}")
        checks_line = " · ".join(glyph_segments)
        checks_plain = " · ".join(glyph_plain)

        services_line = f"{muted('services')} {r.services}"
        services_plain = f"services {r.services}"

        lines = [heading("Health"), checks_line, services_line]
        plain_parts = [checks_plain, services_plain]
        if r.interop is not None:
            lines.append(f"{muted('interop')} {r.interop}")
            plain_parts.append(f"interop {r.interop}")

        self._card("card-health").set_content("\n".join(lines), " · ".join(plain_parts))

    def focus_first_card(self) -> None:
        self._card("card-provision").focus()

    def move_focus(self, from_card_id: str, direction: str) -> None:
        ids = list(CARD_TARGETS)
        row, col = divmod(ids.index(from_card_id), 2)
        if direction == "left":
            col = max(col - 1, 0)
        elif direction == "right":
            col = min(col + 1, 1)
        elif direction == "up":
            row = max(row - 1, 0)
        elif direction == "down":
            row = min(row + 1, 1)
        self._card(ids[row * 2 + col]).focus()

    def summary_text(self) -> str:
        parts = [card.plain for card in self.query(Card)]
        parts.append(getattr(self, "_warnings_plain", ""))
        return " · ".join(p for p in parts if p)

    def _card(self, card_id: str) -> Card:
        return self.query_one(f"#{card_id}", Card)
