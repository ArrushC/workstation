"""HistoryScreen — task/sequence/push/keydist history browser (spec §3).

Opened globally via the app's `H` binding (`WorkstationApp.action_history`)
rather than from a specific panel — history spans every kind of run, not
just one panel's own actions — so, like HelpScreen/SudoModal, this screen
takes no constructor arguments and reads everything (`app.history_store`,
`app.rerun_history_entry`) from `self.app` at call time.

Same 90%-box ModalScreen model as TextViewScreen/UpdatesScreen, with a
DataTable body (UpdatesScreen precedent) instead of a text blob. Unlike
UpdatesScreen (cache-first render, then a background re-check),
`HistoryStore.load` is itself the only data source here — there's nothing
to refresh in the background, so `on_mount` just loads once, in a thread
worker (file I/O) marshalled back via `call_from_thread`.

`_render_table` guards on `self.is_attached` — the #141-era unmount-race
class Task 2's fix round hardened: the screen may have been dismissed
(e.g. `escape`, or a dismiss from `r`'s confirm flow) while `_load` was
still running its thread worker, and that stray callback must not touch a
torn-down tree.

`enter` (via `on_data_table_row_selected`, the dotfiles/health/push_screen
precedent — DataTable owns `enter -> select_cursor` itself, so a same-key
screen-level BINDINGS entry would never fire while the table holds focus)
reads the selected entry's full log via `HistoryStore.read_log`, also
file I/O, hopped to a thread with `asyncio.to_thread` from this async
handler (Textual supports async message handlers) rather than the
run_worker/call_from_thread shape `_load` uses — there's no need for a
worker group here since nothing needs to cancel it.

`r` hands the cursor entry straight to `app.rerun_history_entry` (F1: the
ConfirmModal now lives THERE, not here, so this screen's `r` and the
palette's `re-run:` hit share one confirm — neither can bypass the other's
gate). `rerun_history_entry` returns True once it has ROUTED the request
to its own background confirm+launch worker (kind `task`/`sequence` with
a recorded `command`); this screen dismisses on that True regardless of
how the confirm is eventually answered — declining it just leaves nothing
running, which is fine, the screen was going to close either way. A
non-re-runnable entry (`push`/`keydist`, or a `task`/`sequence` recorded
with no command) returns False with `rerun_history_entry`'s own
"re-run from the Fleet panel" toast and no confirm at all — this screen
stays open.
"""

import asyncio
from datetime import UTC, datetime

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import DataTable, Static

from workstation_tui.app.theme import M, OUTCOME_ICONS, icon
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.fleet import rel_age
from workstation_tui.core.history import HistoryEntry

#: Row key used for the single placeholder row shown when the store holds
#: no entries — deliberately distinct from any real `new_entry_id()` shape
#: (see core/history.py's `_ENTRY_ID_RE`) so a stray cursor/enter/rerun on
#: it can never collide with `self._entries`.
_EMPTY_KEY = "__empty__"

HISTORY_CSS = f"""
HistoryScreen {{
    align: center middle;
}}
#history-box {{
    width: 90%;
    height: 90%;
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
#history-title {{
    color: {M['mauve']};
    text-style: bold;
    height: 1;
}}
#history-table {{
    height: 1fr;
}}
"""


def _when_text(started_at: str, now: datetime) -> str:
    """`rel_age()` of an entry's `started_at` relative to `now`, or `"?"`
    on any parse failure — never raises (mirrors updates_screen.py's
    `_age_text` degrade-to-placeholder discipline for a bad timestamp).
    """
    try:
        started = datetime.fromisoformat(started_at)
        delta = (now - started).total_seconds()
    except Exception:
        return "?"
    return rel_age(max(delta, 0.0))


def _format_duration(duration_secs: float) -> str:
    """`m:ss` for the `time` column — floors to whole seconds, never
    negative regardless of a malformed/negative `duration_secs`."""
    total = max(int(duration_secs), 0)
    return f"{total // 60}:{total % 60:02d}"


class HistoryScreen(ModalScreen[None]):
    """Read-only task/sequence/push/keydist history table with a log
    drill-in (`enter`) and a gated re-run (`r`)."""

    DEFAULT_CSS = HISTORY_CSS

    BINDINGS = [
        ("escape", "close", "Close"),
        ("q", "close", "Close"),
        ("r", "rerun", "Re-run"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._entries: dict[str, HistoryEntry] = {}

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="history-box"):
            yield Static("task history", id="history-title", markup=False)
            yield DataTable(id="history-table", cursor_type="row", zebra_stripes=True)

    def on_mount(self) -> None:
        table = self.query_one("#history-table", DataTable)
        table.add_column("when", key="when", width=6)
        table.add_column("st", key="st", width=2)
        table.add_column("kind", key="kind", width=9)
        table.add_column("summary", key="summary")
        table.add_column("rc", key="rc", width=4)
        table.add_column("time", key="time", width=6)
        table.focus()
        self.run_worker(self._load, thread=True, exclusive=True, group="history")

    def action_close(self) -> None:
        self.dismiss(None)

    # -- loading ------------------------------------------------------------

    def _load(self) -> None:
        entries = self.app.history_store.load(200)  # type: ignore[attr-defined]
        self.app.call_from_thread(self._render_table, entries)  # type: ignore[attr-defined]

    def _render_table(self, entries: list[HistoryEntry]) -> None:
        if not self.is_attached:
            return  # screen dismissed mid-load — ignore the stray callback
        self._entries = {entry.id: entry for entry in entries}
        table = self.query_one("#history-table", DataTable)
        table.clear()
        if not entries:
            table.add_row(
                Text(""), Text(""), Text(""),
                Text("no history yet", style=M["overlay0"]),
                Text(""), Text(""),
                key=_EMPTY_KEY,
            )
            return
        now = datetime.now(UTC)
        for entry in entries:
            table.add_row(
                Text(_when_text(entry.started_at, now)),
                icon(entry.outcome, OUTCOME_ICONS),
                Text(entry.kind),
                Text(entry.summary),
                Text(str(entry.returncode) if entry.returncode is not None else "—"),
                Text(_format_duration(entry.duration_secs)),
                key=entry.id,
            )

    # -- log drill-in (enter) -------------------------------------------------

    async def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        """`enter` on the history table -> full log view (dotfiles/health/
        push_screen precedent: DataTable posts its own RowSelected on
        `enter`, the actual dispatch point — see history_screen.py's module
        docstring for why this isn't a screen-level BINDINGS entry)."""
        if event.data_table.id != "history-table":
            return
        row_key = event.row_key
        entry_id = str(row_key.value) if row_key and row_key.value else None
        if entry_id is None:
            return
        entry = self._entries.get(entry_id)
        if entry is None:
            return  # the empty-state placeholder row, or a stale key
        text = await asyncio.to_thread(self.app.history_store.read_log, entry_id)  # type: ignore[attr-defined]
        self.app.push_screen(TextViewScreen(text, title=entry.summary))  # type: ignore[attr-defined]

    # -- gated re-run (r) -----------------------------------------------------

    def _cursor_entry(self) -> HistoryEntry | None:
        table = self.query_one("#history-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        entry_id = str(row_key.value) if row_key and row_key.value else None
        if entry_id is None:
            return None
        return self._entries.get(entry_id)

    def action_rerun(self) -> None:
        """Hand the cursor entry straight to `app.rerun_history_entry` —
        that method now OWNS the ConfirmModal (F1: it's the single entry
        point for both this binding and the palette's `re-run:` hit, so
        neither can bypass the confirm the other one shows). This screen
        no longer runs its own confirm flow; it just dismisses once the
        request has been ROUTED (return True) — a non-re-runnable entry
        (push/keydist, or a task/sequence recorded with no command)
        returns False with its own "re-run from the Fleet panel" toast
        and leaves this screen open.
        """
        entry = self._cursor_entry()
        if entry is None:
            return  # empty table / placeholder row — nothing to re-run
        if self.app.rerun_history_entry(entry):  # type: ignore[attr-defined]
            self.dismiss(None)
