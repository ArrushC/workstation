"""Read-only dashboard: one live summary card per domain."""

from textual.app import ComposeResult
from textual.containers import Grid
from textual.widgets import Static

from workstation_tui.app.theme import M, STAMP_ICONS, heading, muted
from workstation_tui.core.models import Summary

CARD_TARGETS = {
    "card-provision": "provision",
    "card-dotfiles": "dotfiles",
    "card-fleet": "fleet",
    "card-health": "health",
}

DASHBOARD_CSS = f"""
DashboardPanel {{
    padding: 1 1;
}}
#cards {{
    grid-size: 2 2;
    grid-gutter: 1 2;
    height: auto;
}}
.card {{
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
    height: auto;
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
    BINDINGS = [("enter", "open", "Open panel")]

    def __init__(self, card_id: str) -> None:
        super().__init__("", id=card_id, classes="card", markup=True)
        self.plain = ""

    def set_content(self, markup: str, plain: str) -> None:
        self.plain = plain
        self.update(markup)

    def action_open(self) -> None:
        self.app.switch_panel(CARD_TARGETS[self.id])  # type: ignore[attr-defined]


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
        health_plain = "open the Health panel (5) — checks · services · interop"
        self._card("card-health").set_content(
            heading("Health") + "\n" + muted(health_plain),
            health_plain,
        )
        warnings = [*s.inventory_errors, *s.dotfiles_errors, *s.hosts_errors]
        self.query_one("#dashboard-warnings", Static).update(
            "\n".join(f"warning  {w}" for w in warnings)
        )
        self._warnings_plain = "\n".join(warnings)

    def summary_text(self) -> str:
        parts = [card.plain for card in self.query(Card)]
        parts.append(getattr(self, "_warnings_plain", ""))
        return " · ".join(p for p in parts if p)

    def _card(self, card_id: str) -> Card:
        return self.query_one(f"#{card_id}", Card)
