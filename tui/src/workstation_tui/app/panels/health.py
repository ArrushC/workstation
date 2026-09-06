"""Health panel: check-registry table + services/interop lines + task log.

All health data flows through app-owned providers (health_cache_path/
services_reader/interop_reader) and the app's launch_task/run_task_sequence
machinery — this panel never shells out to make/systemctl/the WSLInterop
proc file itself (same provider-only discipline as fleet.py/dotfiles.py).

Every DataTable cell is Text-wrapped (the markup-crash class dotfiles.py
first called out for pending paths — check labels/ages/summaries are all
tame today, but the convention stays uniform with the other panels so a
future change to check labels/log-derived summaries can't reopen it).

Run-one (`enter`) records a CheckResult into the on-disk cache: `on_result`
(a minimal, backward-compatible addition to `launch_task`/`_task_flow` —
see app.py) hands back the TaskResult with its returncode, which `enter`
uses to compute ok=rc==0, summary=last non-empty streamed log line
(truncated to 80 chars), finished_at=now.

Run-all (`R`) uses `run_task_sequence`, which streams combined output to
the log but exposes no per-command rc hook — so a run-all pass does NOT
update any row's cached result (rows keep showing whatever the last
individual `enter` run recorded, or "never"). Use `enter` on a row to
record/refresh that row specifically. This is a deliberate v1 scope
decision, not an oversight.
"""

import time
from pathlib import Path

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, RichLog, Static
from textual.widgets.data_table import RowDoesNotExist

from workstation_tui.app.theme import M, icon, muted
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.health import (
    CHECKS,
    check_available,
    check_command,
    load_cache,
    save_cache,
)
from workstation_tui.core.models import CheckResult, HostContext, TaskResult
from workstation_tui.repo import find_repo_root

HEALTH_CSS = f"""
HealthPanel {{
    padding: 0 1;
}}
#health-table {{
    height: 1fr;
}}
#health-services {{
    height: 1;
    padding: 0 1;
    background: {M['mantle']};
}}
#health-interop {{
    height: 1;
    padding: 0 1;
    background: {M['mantle']};
}}
#health-log {{
    height: 12;
    background: {M['mantle']};
    border-top: solid {M['surface1']};
}}
"""

#: bool_marker-style tri-state mapping — a recorded cache entry earns
#: ok/failed; anything with no entry (never run, OR currently unavailable
#: with nothing cached yet) renders the same dim "never-ran" dash.
HEALTH_ICONS: dict[str, tuple[str, str]] = {
    "ok":     ("✓", M["green"]),
    "failed": ("✗", M["red"]),
    "never":  ("—", M["overlay0"]),
}

SERVICE_ICONS: dict[str, tuple[str, str]] = {
    "active":   ("✓", M["green"]),
    "inactive": ("✗", M["red"]),
    "unknown":  ("—", M["overlay0"]),
}

INTEROP_ICONS: dict[str, tuple[str, str]] = {
    "enabled":  ("✓", M["green"]),
    "disabled": ("✗", M["yellow"]),
    "absent":   ("—", M["overlay0"]),
}


def _age(epoch: float) -> str:
    """Format a cache timestamp's age. Caller handles the "never" case
    (no cache entry at all) — this only ever sees a real `finished_at`.
    """
    delta = max(0.0, time.time() - epoch)
    if delta < 60:
        return "just now"
    if delta < 3600:
        return f"{int(delta // 60)}m ago"
    if delta < 86400:
        return f"{int(delta // 3600)}h ago"
    return f"{int(delta // 86400)}d ago"


def _services_unavailable_reason(ctx: HostContext | None) -> str:
    """Pure helper (no widget access) so the reason text is unit-testable
    on its own — same rationale as dotfiles.py's `_assemble_full_diff`.
    """
    if ctx is None:
        return "services — waiting for host context"
    if ctx.is_wsl:
        return ("services — not shown under WSL (dozzle/cockpit/rsyslog run "
                 "on the Linux side; check inside the WSL distro directly)")
    if not ctx.has_systemctl:
        return "services — systemctl not available on this host"
    if ctx.mode != "dev":
        return "services — dev-only (dozzle/cockpit/rsyslog are MODE=dev services)"
    return "services unavailable"


class HealthPanel(Static):
    DEFAULT_CSS = HEALTH_CSS

    BINDINGS = [
        ("R", "run_all", "Run all"),
        ("o", "open_log", "Open log"),
    ]

    #: Same rationale as the other panels' MAX_LOG_LINES — a long session
    #: shouldn't let the log grow unbounded.
    MAX_LOG_LINES = 5000

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)
        self.cache: dict[str, CheckResult] = {}
        self.services: dict[str, str] = {}
        self.interop: str = "absent"
        self.log_lines: list[str] = []
        self._services_plain = ""
        self._interop_plain = ""
        # False until compose()'s children are mounted. refresh_panel() (via
        # its "health-refresh" thread worker's call_from_thread) and
        # append_log() (via launch_task/run_task_sequence's log_to callback)
        # are public and reachable from other async paths BEFORE this
        # panel's widget tree exists — same _composed discipline as
        # ProvisionPanel (#141), applied here since HealthPanel has its own
        # independent worker chain (refresh_panel -> _refresh_worker ->
        # call_from_thread(_apply_refresh)) sitting downstream of the app's
        # startup call_after_refresh guard, so it isn't covered by that
        # guard alone. Every method that touches the tree checks this and
        # lets on_mount() replay the accumulated state instead.
        self._composed = False
        self.can_focus = True

    def compose(self) -> ComposeResult:
        with Vertical():
            yield DataTable(id="health-table", cursor_type="row",
                            zebra_stripes=True)
            yield Static("", id="health-services", markup=True)
            yield Static("", id="health-interop", markup=True)
            yield RichLog(id="health-log", markup=False, wrap=False,
                          max_lines=self.MAX_LOG_LINES)

    def on_mount(self) -> None:
        table = self.query_one("#health-table", DataTable)
        table.add_column("", key="state", width=3)
        table.add_column("check", key="label", width=16)
        table.add_column("age", key="age", width=12)
        table.add_column("summary", key="summary")
        # Children exist from here on. Anything that arrived while the tree
        # was still being composed lives in self.cache/self.services/
        # self.interop/self.log_lines rather than having been dropped, so
        # draw it now.
        self._composed = True
        self._render_rows()
        self._render_services_line()
        self._render_interop_line()
        log = self.query_one("#health-log", RichLog)
        for line in self.log_lines:
            log.write(line)

    def on_unmount(self) -> None:
        # `_composed` was only ever set True (on mount) and never reset —
        # a render/log callback landing AFTER this panel's tree was torn
        # down (app exit, test teardown) — refresh_panel's thread worker
        # and _run_check's on_result both reach this panel via
        # call_from_thread/launch_task well after the key that triggered
        # them was pressed — would still see `_composed is True` and crash
        # with NoMatches. Reset it here so the guards below correctly
        # treat "was composed, now torn down" as not-renderable.
        self._composed = False

    # -- rendering ------------------------------------------------------

    def _render_rows(self) -> None:
        if not (self._composed and self.is_attached):
            return  # on_mount() renders once the widget tree exists; torn-down tree ignores
        table = self.query_one("#health-table", DataTable)
        table.clear()
        for check in CHECKS:
            entry = self.cache.get(check.check_id)
            if entry is None:
                state, age, summary = "never", "never", ""
            else:
                state = "ok" if entry.ok else "failed"
                age = _age(entry.finished_at)
                summary = entry.summary
            # DataTable markup-parses str cells (default_cell_formatter) —
            # Text(...) is the markup=False of tables (same convention as
            # provision.py/dotfiles.py/fleet.py).
            table.add_row(
                icon(state, HEALTH_ICONS), Text(check.label), Text(age),
                Text(summary.strip(), no_wrap=True, overflow="ellipsis"), key=check.check_id,
            )

    def _render_services_line(self) -> None:
        if not (self._composed and self.is_attached):
            return  # on_mount() renders once the widget tree exists; torn-down tree ignores
        widget = self.query_one("#health-services", Static)
        ctx = self._host_context()
        if ctx is not None and ctx.has_systemctl and not ctx.is_wsl and ctx.mode == "dev":
            segments = []
            plain = []
            for name, state in self.services.items():
                glyph, col = SERVICE_ICONS.get(state, ("?", M["overlay0"]))
                # service names are a fixed vocabulary (docker/dozzle/
                # cockpit/rsyslog), never user input — safe to interpolate
                # directly into markup=True content.
                segments.append(f"[{M['subtext0']}]{name}[/] [{col}]{glyph}[/]")
                plain.append(f"{name} {state}")
            widget.update("  ".join(segments) if segments else muted("no services"))
            self._services_plain = "  ".join(plain)
        else:
            reason = _services_unavailable_reason(ctx)
            widget.update(muted(reason))
            self._services_plain = reason

    def _render_interop_line(self) -> None:
        if not (self._composed and self.is_attached):
            return  # on_mount() renders once the widget tree exists; torn-down tree ignores
        widget = self.query_one("#health-interop", Static)
        ctx = self._host_context()
        if ctx is not None and ctx.is_wsl:
            glyph, col = INTEROP_ICONS.get(self.interop, ("?", M["overlay0"]))
            widget.update(
                f"[{M['subtext0']}]WSL interop:[/] [{col}]{glyph} {self.interop}[/]"
            )
            self._interop_plain = f"WSL interop: {self.interop}"
        else:
            widget.update("")
            self._interop_plain = ""

    def rendered_text(self) -> str:
        """Plain-text aggregation of the panel (table cells + services/
        interop lines + log) — lets tests assert on content without
        depending on DataTable's internal Rich rendering (same rationale
        as DashboardPanel.summary_text()).
        """
        parts: list[str] = []
        for check in CHECKS:
            entry = self.cache.get(check.check_id)
            if entry is None:
                parts.append(f"{check.label} never")
            else:
                parts.append(f"{check.label} {_age(entry.finished_at)} {entry.summary}")
        parts.append(self._services_plain)
        parts.append(self._interop_plain)
        parts.extend(self.log_lines)
        return " · ".join(p for p in parts if p)

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        if len(self.log_lines) > self.MAX_LOG_LINES:
            del self.log_lines[: -self.MAX_LOG_LINES]
        if not (self._composed and self.is_attached):
            return  # on_mount() replays self.log_lines; torn-down tree ignores
        self.query_one("#health-log", RichLog).write(line)

    def _host_context(self) -> HostContext | None:
        # NOTE: deliberately NOT named `_context` — MessagePump/DOMNode
        # already defines a private `_context()` used internally for its
        # own contextvars plumbing (`with self._context():` in
        # `_process_messages`); shadowing it here silently broke the
        # widget's message pump (TypeError: 'NoneType' object does not
        # support the context manager protocol) the first time this was
        # named `_context`. Lesson learned the hard way — keep this name.
        summary = self.app.summary  # type: ignore[attr-defined]
        return summary.context if summary else None

    def select_row(self, key: str) -> bool:
        """Move the cursor to the row keyed `key` (a `check_id`).

        Command palette (Phase C Task 6) seam — same shape as
        ProvisionPanel.select_row: an EntitiesProvider "run check <label>"
        hit calls this before the existing `_run_check(check_id)` (the
        same call `on_data_table_row_selected` makes on `enter`). Returns
        False — never raises — when the table isn't composed yet or
        `key` names no current row.
        """
        if not (self._composed and self.is_attached):
            return False
        table = self.query_one("#health-table", DataTable)
        try:
            idx = table.get_row_index(key)
        except RowDoesNotExist:
            return False
        table.move_cursor(row=idx)
        return True

    # -- refresh (called by the app on entry/refresh cycles) -------------

    def refresh_panel(self) -> None:
        self.run_worker(
            self._refresh_worker, thread=True, exclusive=True,
            group="health-refresh",
        )

    def _refresh_worker(self) -> None:
        cache = load_cache(self.app.health_cache_path)  # type: ignore[attr-defined]
        services = self.app.services_reader()  # type: ignore[attr-defined]
        interop = self.app.interop_reader()  # type: ignore[attr-defined]
        self.app.call_from_thread(  # type: ignore[attr-defined]
            self._apply_refresh, cache, services, interop
        )

    def _apply_refresh(
        self, cache: dict[str, CheckResult], services: dict[str, str], interop: str,
    ) -> None:
        self.cache = cache
        self.services = services
        self.interop = interop
        self._render_rows()
        self._render_services_line()
        self._render_interop_line()

    # -- actions delegate to the app (which owns runner + providers) -----

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "health-table":
            return
        row_key = event.row_key
        check_id = str(row_key.value) if row_key and row_key.value else None
        if check_id is None:
            return
        self._run_check(check_id)

    def _run_check(self, check_id: str) -> None:
        check = next((c for c in CHECKS if c.check_id == check_id), None)
        if check is None:
            return
        ctx = self._host_context()
        # No summary yet -> availability is unknown; fall through and let
        # the run attempt proceed rather than spuriously refusing it (same
        # "no summary -> don't block" fallback as fleet.py's _os_name()).
        reason = check_available(check, ctx) if ctx is not None else None
        if reason is not None:
            self.app.notify(  # type: ignore[attr-defined]
                f"{check.label} unavailable: {reason}", severity="warning")
            return
        root = find_repo_root() or Path.cwd()
        mode = ctx.mode if ctx is not None else "dev"
        command = check_command(root, check, mode)
        lines: list[str] = []

        def _log(line: str) -> None:
            lines.append(line)
            self.append_log(line)

        def _on_result(result: TaskResult) -> None:
            self._record_result(check.check_id, result, lines)

        self.app.launch_task(  # type: ignore[attr-defined]
            command, log_to=_log, on_result=_on_result,
        )

    def _record_result(
        self, check_id: str, result: TaskResult, lines: list[str],
    ) -> None:
        if result.cancelled:
            # An aborted check (e.g. Provision's shared-runner `x` cancel
            # mid-run) is not a FAILED check — leave whatever the cache
            # already has (possibly nothing) rather than persisting a
            # bogus ok=False row for a run that never actually finished.
            return
        # Pick last non-empty line after strip, skip lines starting with "$ " (command echoes),
        # truncate to 80 chars. This filters out command prompts while preserving real output.
        summary = next(
            (line.strip()[:80] for line in reversed(lines)
             if line.strip() and not line.strip().startswith("$ ")),
            ""
        )
        res = CheckResult(
            check_id=check_id, ok=result.returncode == 0, summary=summary,
            finished_at=time.time(), returncode=result.returncode,
        )
        # load+save is blocking file I/O — offload to a thread worker
        # (same convention as refresh_panel's own "health-refresh" thread
        # worker) so a slow filesystem (e.g. WSL 9P) can't hitch the UI.
        # Not exclusive/grouped with "health-refresh": a write must never
        # be silently cancelled by a concurrent refresh.
        self.run_worker(
            lambda: self._write_result(check_id, res),
            thread=True, exclusive=False, group="health-write",
        )

    def _write_result(self, check_id: str, res: CheckResult) -> None:
        path = self.app.health_cache_path  # type: ignore[attr-defined]
        cache = load_cache(path)
        cache[check_id] = res
        save_cache(path, cache)
        self.app.call_from_thread(self.refresh_panel)  # type: ignore[attr-defined]

    def action_run_all(self) -> None:
        ctx = self._host_context()
        root = find_repo_root() or Path.cwd()
        mode = ctx.mode if ctx is not None else "dev"
        available = [c for c in CHECKS if ctx is None or check_available(c, ctx) is None]
        if not available:
            self.app.notify("no checks available", severity="information")  # type: ignore[attr-defined]
            return
        commands = [check_command(root, c, mode) for c in available]
        self.app.run_task_sequence(  # type: ignore[attr-defined]
            commands, log_to=self.append_log, on_done=self.refresh_panel,
        )

    def action_open_log(self) -> None:
        text = "\n".join(self.log_lines) if self.log_lines else "no log output yet"
        self.app.push_screen(TextViewScreen(text, title="health log"))  # type: ignore[attr-defined]
