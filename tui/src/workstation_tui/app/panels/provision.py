"""Provision panel: tool table + filter + streamed task log.

Multi-select (spec §2): `self.marked` is a name-keyed set of tool names,
independent of the DataTable's rows — it survives `_render_rows()` rebuilds
(filtering, refreshes) because membership is checked fresh against
`t.name`, not stored on the row itself. `action_toggle_mark`/
`action_clear_marks` update the mark column via `DataTable.update_cell`
rather than a full `_render_rows()` so the cursor position is never
disturbed by marking (a full re-render resets `cursor_coordinate` to
(0, 0) — see `DataTable.clear()` — which would fight arrow-key navigation
mid mark-and-move).
"""

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Input, RichLog, Static
from textual.widgets.data_table import CellDoesNotExist, RowDoesNotExist

from workstation_tui.app.theme import M, STAMP_ICONS, icon, sel_marker
from workstation_tui.app.widgets.updates_screen import UpdatesScreen
from workstation_tui.core.models import TaskResult, ToolStatus

PROVISION_CSS = f"""
ProvisionPanel {{
    padding: 0 1;
}}
#provision-filter-row {{
    height: 3;
}}
#provision-filter {{
    margin: 0;
    width: 1fr;
}}
#provision-marks {{
    width: auto;
    min-width: 10;
    padding: 0 1;
    color: {M['blue']};
    content-align: right middle;
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
        ("space", "toggle_mark", "Mark"),
        ("escape", "clear_marks", "Clear marks"),
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
        # False until compose()'s children are mounted. The app starts its
        # loader worker in App.on_mount, so set_tools()/append_log() can be
        # called BEFORE this panel's widget tree exists — every method that
        # touches the tree checks this and lets on_mount() replay the state.
        self._composed = False
        self.can_focus = True
        # True when this host has no make (e.g. Windows) — the panel
        # degrades honestly instead of pretending provisioning works here.
        self.unavailable = False
        # Marked tool names (spec §2) — name-keyed, not row-keyed, so marks
        # survive a filtered/rebuilt table. Cleared on `esc`, on a
        # successful (rc==0, not cancelled) marked run, and toggled by
        # `space` on the cursor row.
        self.marked: set[str] = set()

    def compose(self) -> ComposeResult:
        with Vertical():
            with Horizontal(id="provision-filter-row"):
                yield Input(placeholder="filter tools…", id="provision-filter")
                yield Static("", id="provision-marks", markup=False)
            yield DataTable(id="provision-table", cursor_type="row",
                            zebra_stripes=True)
            yield RichLog(id="provision-log", markup=False, wrap=False,
                          max_lines=self.MAX_LOG_LINES)

    def on_mount(self) -> None:
        table = self.query_one("#provision-table", DataTable)
        table.add_column("", key="mark", width=2)
        table.add_column("", key="state", width=3)
        table.add_column("tool", key="tool", width=24)
        table.add_column("kind", key="kind", width=8)
        table.add_column("version", key="version", width=20)
        # Children exist from here on. Anything that arrived while the tree was
        # still being composed lives in self.tools / self.log_lines / self.marked
        # rather than having been dropped, so draw it now.
        self._composed = True
        self._render_rows()
        self._update_marks_indicator()
        log = self.query_one("#provision-log", RichLog)
        for line in self.log_lines:
            log.write(line)

    def on_unmount(self) -> None:
        # `_composed` was only ever set True (on mount) and never reset —
        # a render/log callback (set_tools/append_log, both reachable from
        # background workers via call_from_thread/on_result) landing AFTER
        # this panel's tree was torn down (app exit, test teardown) would
        # still see `_composed is True` and crash with NoMatches trying to
        # query an unmounted widget. Reset it here so the guards below
        # correctly treat "was composed, now torn down" as not-renderable.
        self._composed = False

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
        if self._composed and self.is_attached:
            self.query_one("#provision-table", DataTable).clear()
        self.append_log(message)

    def _render_rows(self) -> None:
        if not (self._composed and self.is_attached):
            return  # on_mount() renders once the widget tree exists; torn-down tree ignores
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
            # Mark state is looked up fresh against `self.marked` on every
            # render — that's what makes marks survive filtering/refreshes
            # instead of being tied to a specific row instance.
            table.add_row(sel_marker(t.name in self.marked),
                          icon(t.state.value, STAMP_ICONS), Text(t.name),
                          Text(t.kind), Text(t.version), key=t.name)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "provision-filter":
            self._render_rows()

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        if len(self.log_lines) > self.MAX_LOG_LINES:
            del self.log_lines[: -self.MAX_LOG_LINES]
        if not (self._composed and self.is_attached):
            return  # on_mount() replays self.log_lines; torn-down tree ignores
        self.query_one("#provision-log", RichLog).write(line)

    def selected_tool(self) -> str | None:
        table = self.query_one("#provision-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        return str(row_key.value) if row_key and row_key.value else None

    def select_row(self, key: str) -> bool:
        """Move the cursor to the row keyed `key` (a tool name).

        Command palette (Phase C Task 6) seam: an EntitiesProvider "run
        <tool>"/"clean <tool>" hit calls this before the existing
        `action_run_tool`/`action_clean_tool` so the action's own
        `selected_tool()` lookup lands on the right row. Returns False —
        never raises — when the table isn't composed yet or `key` names
        no current row (e.g. a stale palette hit for a tool the filter/a
        refresh since dropped); `RowDoesNotExist` is exactly that "no
        such row" case, per `DataTable.get_row_index`.
        """
        if not (self._composed and self.is_attached):
            return False
        table = self.query_one("#provision-table", DataTable)
        try:
            idx = table.get_row_index(key)
        except RowDoesNotExist:
            return False
        table.move_cursor(row=idx)
        return True

    def _tool_kind(self, name: str) -> str:
        for t in self.tools:
            if t.name == name:
                return t.kind
        return "scope"

    def _update_marks_indicator(self) -> None:
        if not (self._composed and self.is_attached):
            return  # on_mount() renders the indicator; torn-down tree ignores
        n = len(self.marked)
        self.query_one("#provision-marks", Static).update(
            f"{n} marked" if n > 0 else ""
        )

    def _on_run_result(self, result: TaskResult) -> None:
        # Clear-on-success (spec §2): only a clean, non-cancelled run earns
        # a fresh slate — a failed or cancelled run leaves the marks in
        # place so the user can retry without re-selecting.
        if result.returncode == 0 and not result.cancelled:
            self.action_clear_marks()

    # -- actions delegate to the app (which owns runner + repo/mode) ----------

    def action_run_tool(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        if self.marked:
            # Marked run: ALL marked tools in ONE make invocation, in table
            # order (not mark order) — iterate self.tools, not self.marked,
            # since a set has no stable order and self.tools already IS the
            # canonical table order.
            ordered = [t.name for t in self.tools if t.name in self.marked]
            if not ordered:
                # Transient: a watch tick or refresh can repopulate
                # self.tools with [] (e.g. `make inventory` failing/
                # timing out) while self.marked (name-keyed, independent
                # of the table) still holds stale names. Without this
                # guard, `ordered` would be [] and `all(<empty>) == True`
                # (vacuous truth) would hand run_make_goals a user_kind
                # bypass for a goal-less `make` invocation (runs make's
                # .DEFAULT_GOAL under no sudo gate). Refuse instead, and
                # leave the marks alone so the user can retry once the
                # inventory recovers.
                self.app.notify(  # type: ignore[attr-defined]
                    "marked tools not found in current inventory — "
                    "refresh and retry", severity="warning")
                return
            user_kind = all(self._tool_kind(n) == "user" for n in ordered)
            self.app.run_make_goals(  # type: ignore[attr-defined]
                ordered, user_kind=user_kind, on_result=self._on_run_result)
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
        # F6: reachable a second time from the palette's "check updates"
        # command while UpdatesScreen is already the top screen (the
        # panel's own `u` binding is inert under a ModalScreen, but the
        # palette's priority `ctrl+p` binding still fires) — without this
        # guard that stacks a second, identical UpdatesScreen instead of
        # just leaving the one already open in place.
        if isinstance(self.app.screen, UpdatesScreen):  # type: ignore[attr-defined]
            return
        self.app.push_screen(UpdatesScreen())  # type: ignore[attr-defined]

    def action_full_provision(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        self.app.run_make_goals(["provision"], user_kind=False)  # type: ignore[attr-defined]

    def action_cancel_task(self) -> None:
        self.app.cancel_task()  # type: ignore[attr-defined]

    def action_toggle_mark(self) -> None:
        if self.unavailable:
            self.app.notify(  # type: ignore[attr-defined]
                "provisioning not available on this host", severity="warning")
            return
        tool = self.selected_tool()
        if tool is None:
            self.app.notify("no tool selected", severity="warning")  # type: ignore[attr-defined]
            return
        if tool in self.marked:
            self.marked.discard(tool)
        else:
            self.marked.add(tool)
        table = self.query_one("#provision-table", DataTable)
        try:
            table.update_cell(tool, "mark", sel_marker(tool in self.marked))
        except CellDoesNotExist:
            pass
        self._update_marks_indicator()

    def action_clear_marks(self) -> None:
        if not self.marked:
            return
        cleared = self.marked
        self.marked = set()
        table = self.query_one("#provision-table", DataTable)
        for name in cleared:
            try:
                table.update_cell(name, "mark", sel_marker(False))
            except CellDoesNotExist:
                # The tool may have been filtered out (marks survive
                # filtering even though the row isn't currently rendered).
                pass
        self._update_marks_indicator()
