"""Provision panel: tool table + filter + streamed task log."""

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Input, RichLog, Static

from workstation_tui.app.theme import M, STAMP_ICONS, icon
from workstation_tui.core.models import ToolStatus

PROVISION_CSS = f"""
ProvisionPanel {{
    padding: 0 1;
}}
#provision-filter {{
    margin: 0;
}}
#provision-table {{
    height: 1fr;
}}
#provision-log {{
    height: 12;
    background: {M['mantle']};
    border-top: solid {M['surface1']};
}}
"""


class ProvisionPanel(Static):
    DEFAULT_CSS = PROVISION_CSS

    BINDINGS = [
        ("r", "run_tool", "Run"),
        ("c", "clean_tool", "Clean+reinstall"),
        ("u", "updates", "Check updates"),
        ("R", "full_provision", "Full provision"),
        ("x", "cancel_task", "Cancel task"),
    ]

    #: Bound on retained log lines — a long-running `provision` can emit far
    #: more output than any UI needs to keep around; unbounded growth would
    #: be a slow memory leak over a session.
    MAX_LOG_LINES = 5000

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)
        self.tools: list[ToolStatus] = []
        self.errors: list[str] = []
        self.log_lines: list[str] = []
        self.can_focus = True
        # True when this host has no make (e.g. Windows) — the panel
        # degrades honestly instead of pretending provisioning works here.
        self.unavailable = False

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Input(placeholder="filter tools…", id="provision-filter")
            yield DataTable(id="provision-table", cursor_type="row",
                            zebra_stripes=True)
            yield RichLog(id="provision-log", markup=False, wrap=False,
                          max_lines=self.MAX_LOG_LINES)

    def on_mount(self) -> None:
        table = self.query_one("#provision-table", DataTable)
        table.add_column("", key="state", width=3)
        table.add_column("tool", key="tool", width=24)
        table.add_column("kind", key="kind", width=8)
        table.add_column("version", key="version", width=20)

    def set_tools(self, tools: list[ToolStatus], errors: list[str]) -> None:
        if self.unavailable:
            # Host has no make — stay on the unavailable message rather
            # than letting a stale/unrelated tools_provider() result
            # repopulate the table.
            return
        self.tools = tools
        self.errors = errors
        self._render_rows()
        for err in self.errors:
            self.append_log(f"warning  {err}")

    def set_unavailable(self, message: str) -> None:
        """Degrade honestly on a host with no make (e.g. Windows)."""
        self.unavailable = True
        self.tools = []
        self.errors = []
        self.query_one("#provision-table", DataTable).clear()
        self.append_log(message)

    def _render_rows(self) -> None:
        table = self.query_one("#provision-table", DataTable)
        table.clear()
        needle = self.query_one("#provision-filter", Input).value.strip().lower()
        for t in self.tools:
            if needle and needle not in t.name.lower():
                continue
            # DataTable markup-parses str cells (default_cell_formatter) —
            # Text(...) is the markup=False of tables. name/kind/version
            # are tame today (inventory rows), but the fleet panel lands
            # next on user-typed values, so the convention must be uniform.
            table.add_row(icon(t.state.value, STAMP_ICONS), Text(t.name),
                          Text(t.kind), Text(t.version), key=t.name)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "provision-filter":
            self._render_rows()

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        if len(self.log_lines) > self.MAX_LOG_LINES:
            del self.log_lines[: -self.MAX_LOG_LINES]
        self.query_one("#provision-log", RichLog).write(line)

    def selected_tool(self) -> str | None:
        table = self.query_one("#provision-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        return str(row_key.value) if row_key and row_key.value else None

    def _tool_kind(self, name: str) -> str:
        for t in self.tools:
            if t.name == name:
                return t.kind
        return "scope"

    # -- actions delegate to the app (which owns runner + repo/mode) ----------

    def action_run_tool(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        tool = self.selected_tool()
        if tool is None:
            self.app.notify("no tool selected", severity="warning")  # type: ignore[attr-defined]
            return
        self.app.run_make_goals(  # type: ignore[attr-defined]
            [tool], user_kind=self._tool_kind(tool) == "user")

    def action_clean_tool(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        tool = self.selected_tool()
        if tool is None:
            self.app.notify("no tool selected", severity="warning")  # type: ignore[attr-defined]
            return
        self.app.run_make_goals(  # type: ignore[attr-defined]
            ["-j1", f"clean-{tool}", tool],
            user_kind=self._tool_kind(tool) == "user")

    def action_updates(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        self.app.run_make_goals(["check-updates"], user_kind=True)  # type: ignore[attr-defined]

    def action_full_provision(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        self.app.run_make_goals(["provision"], user_kind=False)  # type: ignore[attr-defined]

    def action_cancel_task(self) -> None:
        self.app.cancel_task()  # type: ignore[attr-defined]
