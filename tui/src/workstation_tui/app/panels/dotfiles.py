"""Dotfiles panel: pending-change table + live diff pane + git line + task log.

All chezmoi/git access is indirected through app-owned providers
(pending_provider/git_state_provider/target_diff_fn) and the app's
launch_task/push_screen_wait machinery — this panel never shells out to
chezmoi or git itself (spec discipline carried over from provision.py, which
routes tool runs through app.run_make_goals the same way).
"""

from functools import partial
from pathlib import Path

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import DataTable, RichLog, Static

from workstation_tui.app.theme import M, kb, muted
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.chezmoi import apply_command, re_add_command, update_command
from workstation_tui.core.models import GitState, PendingChange
from workstation_tui.repo import find_repo_root

DOTFILES_CSS = f"""
DotfilesPanel {{
    padding: 0 1;
}}
#dotfiles-split {{
    height: 1fr;
}}
#dotfiles-table {{
    width: 45%;
}}
#dotfiles-diff-pane {{
    width: 1fr;
    background: {M['mantle']};
    border-left: solid {M['surface1']};
    padding: 0 1;
}}
#dotfiles-diff {{
    height: auto;
}}
#dotfiles-git {{
    height: 1;
    padding: 0 1;
    background: {M['mantle']};
}}
#dotfiles-keys {{
    height: 1;
    color: {M['subtext0']};
}}
#dotfiles-log {{
    height: 12;
    background: {M['mantle']};
    border-top: solid {M['surface1']};
}}
"""


def _assemble_full_diff(parts: list[str], errors: list[str]) -> str:
    """Pure text assembly for the full-diff TextViewScreen body.

    Split out of `_full_diff_worker` so the error-handling shape is
    unit-testable without a running app/worker. Finding 4: the previous
    version was `"\\n".join(parts) if parts else "\\n".join(errors) or "no
    changes"` — when SOME pending files diffed successfully and others
    errored, the successful parts silently ate the errors (the `if parts`
    branch never looks at `errors` at all). Now a non-empty `errors` list
    always earns a trailing "--- errors ---" section, whether or not any
    diff also succeeded.
    """
    sections = []
    if parts:
        sections.append("\n".join(parts))
    if errors:
        sections.append("--- errors ---\n" + "\n".join(errors))
    return "\n\n".join(sections) if sections else "no changes"


class DotfilesPanel(Static):
    DEFAULT_CSS = DOTFILES_CSS

    BINDINGS = [
        ("a", "apply_pending", "Apply"),
        ("U", "update_dotfiles", "Update"),
        ("A", "re_add_selected", "Re-add"),
        ("d", "full_diff", "Full diff"),
    ]

    #: Same rationale as ProvisionPanel.MAX_LOG_LINES — a long session
    #: shouldn't let the log grow unbounded.
    MAX_LOG_LINES = 5000

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)
        self.pending: list[PendingChange] = []
        self.errors: list[str] = []
        self.git_state: GitState | None = None
        self.log_lines: list[str] = []
        self.can_focus = True
        # True when this host has no chezmoi — the panel degrades honestly
        # instead of pretending dotfiles management works here.
        self.unavailable = False
        # Last logged in-sync state: None = never logged, True = in sync,
        # False = not in sync. Guards the "dotfiles in sync" log line so it
        # logs only once per CHANGE, not once per refresh (the Phase-4
        # parked lesson — mirrors the unavailable-message guard pattern above).
        self._last_in_sync_state: bool | None = None
        # Last logged warning set: an empty tuple initially means no warnings
        # have been logged yet. Guards warning lines so they log only once
        # per CHANGE to the error set (e.g. new error appears, or error clears).
        self._last_warnings: tuple[str, ...] = ()

    def compose(self) -> ComposeResult:
        with Vertical():
            with Horizontal(id="dotfiles-split", classes="h-split"):
                yield DataTable(id="dotfiles-table", cursor_type="row",
                                zebra_stripes=True)
                with VerticalScroll(id="dotfiles-diff-pane"):
                    yield Static("", id="dotfiles-diff", markup=False)
            yield Static(muted("loading…"), id="dotfiles-git", markup=True)
            yield Static(kb(("a", "Apply"), ("U", "Update"),
                            ("A", "Re-add"), ("d", "Full diff")),
                         id="dotfiles-keys", markup=True)
            yield RichLog(id="dotfiles-log", markup=False, wrap=False,
                          max_lines=self.MAX_LOG_LINES)

    def on_mount(self) -> None:
        table = self.query_one("#dotfiles-table", DataTable)
        table.add_column("code", key="code", width=6)
        table.add_column("path", key="path")

    # -- rendering ------------------------------------------------------

    def _render_rows(self) -> None:
        table = self.query_one("#dotfiles-table", DataTable)
        table.clear()
        for change in self.pending:
            # DataTable markup-parses str cells (default_cell_formatter) —
            # Text(...) is the markup=False of tables. Pending paths are
            # arbitrary chezmoi-status output, not our own controlled
            # markup, so they must render as literal text.
            table.add_row(Text(change.code), Text(change.path), key=change.path)

    def _render_git_line(self) -> None:
        widget = self.query_one("#dotfiles-git", Static)
        if self.git_state is None:
            widget.update(muted("git state unavailable"))
            return
        g = self.git_state
        dirty_text = "dirty" if g.dirty else "clean"
        dirty_col = M["yellow"] if g.dirty else M["green"]
        widget.update(
            f"[{M['subtext1']}]{g.branch}[/] · [{dirty_col}]{dirty_text}[/] · "
            f"[{M['green']}]↑{g.ahead}[/] [{M['red']}]↓{g.behind}[/]"
        )

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        if len(self.log_lines) > self.MAX_LOG_LINES:
            del self.log_lines[: -self.MAX_LOG_LINES]
        self.query_one("#dotfiles-log", RichLog).write(line)

    def selected_path(self) -> str | None:
        table = self.query_one("#dotfiles-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        return str(row_key.value) if row_key and row_key.value else None

    # -- availability + refresh -----------------------------------------

    def set_unavailable(self, message: str) -> None:
        """Degrade honestly on a host with no chezmoi."""
        self.unavailable = True
        self.pending = []
        self.errors = []
        self.git_state = None
        self.query_one("#dotfiles-table", DataTable).clear()
        self.query_one("#dotfiles-diff", Static).update("")
        self._render_git_line()
        self.append_log(message)

    def refresh_panel(self) -> None:
        if self.unavailable:
            return
        self.run_worker(
            self._refresh_worker, thread=True, exclusive=True,
            group="dotfiles-refresh",
        )

    def _refresh_worker(self) -> None:
        pending, errors = self.app.pending_provider()  # type: ignore[attr-defined]
        root = find_repo_root() or Path.cwd()
        git_state, git_errors = self.app.git_state_provider(root)  # type: ignore[attr-defined]
        self.app.call_from_thread(  # type: ignore[attr-defined]
            self._apply_refresh, pending, errors, git_state, git_errors
        )

    def _apply_refresh(
        self,
        pending: list[PendingChange],
        errors: list[str],
        git_state: GitState | None,
        git_errors: list[str],
    ) -> None:
        if self.unavailable:
            # A refresh that was in flight when the host was marked
            # unavailable (e.g. context flipped mid-worker) must not
            # repopulate the table set_unavailable() just cleared.
            return
        self.pending = pending
        self.errors = errors
        self.git_state = git_state
        self._render_rows()
        self._render_git_line()
        # Guard warning lines so they log once per CHANGE to the error set,
        # not once per refresh (same pattern as the "in sync" guard below).
        warnings = tuple(f"warning  {err}" for err in [*errors, *git_errors])
        if warnings != self._last_warnings:
            for warning in warnings:
                self.append_log(warning)
            self._last_warnings = warnings
        # Guard the "in sync" message so it logs once per CHANGE, not once
        # per refresh — mirrors the unavailable-message guard pattern above.
        in_sync = not pending
        if in_sync != self._last_in_sync_state:
            if in_sync:
                self.append_log("dotfiles in sync — nothing pending")
            self._last_in_sync_state = in_sync

    # -- diff pane (cursor-driven) ---------------------------------------

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        if event.data_table.id != "dotfiles-table":
            return
        row_key = event.row_key
        path = str(row_key.value) if row_key and row_key.value else None
        if path is None:
            return
        self.run_worker(
            partial(self._diff_worker, path), thread=True, exclusive=True,
            group="dotfiles-diff",
        )

    def _diff_worker(self, path: str) -> None:
        text, err = self.app.target_diff_fn(path)  # type: ignore[attr-defined]
        self.app.call_from_thread(self._apply_diff, text, err)  # type: ignore[attr-defined]

    def _apply_diff(self, text: str, err: str | None) -> None:
        widget = self.query_one("#dotfiles-diff", Static)
        widget.update(f"error: {err}" if err else text)

    # -- actions delegate to the app (which owns runner + providers) -----

    def _unavailable_notify(self) -> None:
        self.app.notify(  # type: ignore[attr-defined]
            "dotfiles not available on this host", severity="warning")

    async def _confirm_and_run(self, message: str, command: list[str]) -> None:
        ok = await self.app.push_screen_wait(ConfirmModal(message))  # type: ignore[attr-defined]
        if not ok:
            return
        self.app.launch_task(  # type: ignore[attr-defined]
            command, log_to=self.append_log, on_done=self.refresh_panel,
        )

    def action_apply_pending(self) -> None:
        if self.unavailable:
            self._unavailable_notify()
            return
        if not self.pending:
            self.app.notify("nothing pending", severity="information")  # type: ignore[attr-defined]
            return
        n = len(self.pending)
        self.run_worker(
            self._confirm_and_run(f"apply {n} pending changes?", apply_command()),
            exclusive=False, group="dotfiles-confirm",
        )

    def action_update_dotfiles(self) -> None:
        if self.unavailable:
            self._unavailable_notify()
            return
        self.run_worker(
            self._confirm_and_run("update dotfiles from git?", update_command()),
            exclusive=False, group="dotfiles-confirm",
        )

    def action_re_add_selected(self) -> None:
        if self.unavailable:
            self._unavailable_notify()
            return
        path = self.selected_path()
        if path is None:
            self.app.notify("no file selected", severity="warning")  # type: ignore[attr-defined]
            return
        self.run_worker(
            self._confirm_and_run(f"re-add {path}?", re_add_command(path)),
            exclusive=False, group="dotfiles-confirm",
        )

    def action_full_diff(self) -> None:
        if self.unavailable:
            self._unavailable_notify()
            return
        if not self.pending:
            self.app.notify("nothing pending", severity="information")  # type: ignore[attr-defined]
            return
        self.run_worker(
            self._full_diff_worker, thread=True, exclusive=True,
            group="dotfiles-full-diff",
        )

    def _full_diff_worker(self) -> None:
        # No standalone "whole-repo diff" provider is wired into the app
        # (only per-path target_diff_fn) — the full-diff view is the
        # concatenation of each pending file's captured diff, fetched
        # exclusively through the same provider the cursor-move pane uses.
        parts: list[str] = []
        errors: list[str] = []
        for change in self.pending:
            text, err = self.app.target_diff_fn(change.path)  # type: ignore[attr-defined]
            if err:
                errors.append(f"{change.path}: {err}")
            else:
                parts.append(text)
        body = _assemble_full_diff(parts, errors)
        self.app.call_from_thread(self._show_full_diff, body)  # type: ignore[attr-defined]

    def _show_full_diff(self, text: str) -> None:
        self.app.push_screen(TextViewScreen(text, title="chezmoi diff"))  # type: ignore[attr-defined]
