"""WorkstationApp — the sidebar-rail shell (spec layout A)."""

from typing import Callable

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.markup import escape
from textual.widgets import ContentSwitcher, Static

from workstation_tui.app.panels.dashboard import DashboardPanel
from workstation_tui.app.panels.placeholder import PlaceholderPanel
from workstation_tui.app.theme import M, MOCHA_CSS, kb
from workstation_tui.core.models import Summary
from workstation_tui.core.summary import gather_summary
from workstation_tui.repo import find_repo_root

PANELS: list[tuple[str, str]] = [
    ("dashboard", "Dashboard"),
    ("provision", "Provision"),
    ("dotfiles", "Dotfiles"),
    ("fleet", "Fleet"),
    ("health", "Health"),
]

APP_CSS = f"""
#sidebar {{
    width: 14;
    background: {M['mantle']};
    padding: 1 0;
}}
.nav-item {{
    height: 1;
    padding: 0 1;
    color: {M['subtext0']};
}}
.nav-item.active {{
    color: {M['blue']};
    text-style: bold;
    background: {M['surface0']};
}}
#content {{
    padding: 0 1;
}}
"""


def _default_provider() -> Summary:
    root = find_repo_root()
    if root is None:
        raise RuntimeError("workstation repo not found")
    return gather_summary(root)


class NavItem(Static):
    def __init__(self, panel_id: str, label: str) -> None:
        super().__init__(f" {label}", classes="nav-item")
        self.panel_id = panel_id

    def on_click(self) -> None:
        self.app.switch_panel(self.panel_id)  # type: ignore[attr-defined]


class WorkstationApp(App):
    CSS = MOCHA_CSS + APP_CSS
    TITLE = "workstation"
    BINDINGS = [
        *[(str(i + 1), f"switch('{pid}')", label)
          for i, (pid, label) in enumerate(PANELS)],
        ("g", "refresh", "Refresh"),
        ("q", "quit", "Quit"),
    ]

    def __init__(self, *, summary_provider: Callable[[], Summary] | None = None) -> None:
        super().__init__()
        self.summary_provider = summary_provider or _default_provider
        self.summary: Summary | None = None

    def compose(self) -> ComposeResult:
        yield Static("", id="app-header", markup=True)
        with Horizontal(id="main"):
            with Vertical(id="sidebar"):
                for pid, label in PANELS:
                    yield NavItem(pid, label)
            with ContentSwitcher(initial="dashboard", id="content"):
                yield DashboardPanel(id="dashboard")
                yield PlaceholderPanel("Provision", id="provision")
                yield PlaceholderPanel("Dotfiles", id="dotfiles")
                yield PlaceholderPanel("Fleet", id="fleet")
                yield PlaceholderPanel("Health", id="health")
        yield Static(
            kb(("1-5", "Panels"), ("g", "Refresh"), ("q", "Quit")),
            id="key-bar", markup=True,
        )

    def on_mount(self) -> None:
        self._mark_active("dashboard")
        self.action_refresh()

    def switch_panel(self, panel_id: str) -> None:
        self.query_one("#content", ContentSwitcher).current = panel_id
        self._mark_active(panel_id)

    def action_switch(self, panel_id: str) -> None:
        self.switch_panel(panel_id)

    def action_refresh(self) -> None:
        self.run_worker(self._load_summary, thread=True, exclusive=True)

    def _load_summary(self) -> None:
        try:
            summary = self.summary_provider()
        except Exception as exc:  # surface, never crash the shell
            self.call_from_thread(
                self._show_header_error, f"{type(exc).__name__}: {exc}"
            )
            return
        self.call_from_thread(self._apply_summary, summary)

    def _apply_summary(self, summary: Summary) -> None:
        self.summary = summary
        c = summary.context
        wsl = " · WSL" if c.is_wsl else ""
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] "
            f"[{M['subtext0']}]— {c.os} · group={c.group or '?'} · "
            f"mode={c.mode}{wsl}[/]"
        )
        self.query_one("#dashboard", DashboardPanel).update_summary(summary)

    def _show_header_error(self, message: str) -> None:
        # message may contain arbitrary exception text (e.g. a path like
        # "[/etc/foo]") — escape() neutralizes markup-shaped substrings so
        # Textual's markup=True renderer doesn't raise MarkupError.
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] [{M['red']}]{escape(message)}[/]"
        )

    def _mark_active(self, panel_id: str) -> None:
        for item in self.query(NavItem):
            item.set_class(item.panel_id == panel_id, "active")
