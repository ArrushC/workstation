"""Push dashboard screen (spec §1 "PushScreen") — per-host push rows with a
drill-in log.

A genuine `Screen` (not a `ModalScreen`) — it replaces the view rather than
floating over it, matching the panels' own full-page feel. Drives a
`MultiRunner` (core/multirun.py) whose `on_update(name)` callback fires
SYNCHRONOUSLY on this same event loop (MultiRunner has no thread of its
own — it's pure asyncio), so `_apply_run_update` can touch widgets
directly with no `call_from_thread` hop, unlike the thread-worker
providers elsewhere in the app.

`enter` drills into a host's full scrollback via the existing
`TextViewScreen` — routed through `on_data_table_row_selected`, NOT a
BINDINGS entry, mirroring dotfiles.py's `action_apply_selected` precedent:
DataTable owns `enter -> select_cursor` itself when focused, so a
same-key Screen-level BINDINGS entry would never be reached.
"""

import contextlib
import time
from collections import Counter
from datetime import UTC, datetime

from rich.text import Text
from textual.app import ComposeResult
from textual.screen import Screen
from textual.widgets import DataTable, Static
from textual.worker import Worker, WorkerCancelled, WorkerFailed

from workstation_tui.app.theme import M, PUSH_ICONS, icon
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.history import HistoryEntry, new_entry_id
from workstation_tui.core.multirun import HostRun, MultiRunner

PUSH_SCREEN_CSS = f"""
#push-table {{
    height: 1fr;
}}
#push-summary {{
    height: 1;
    padding: 0 1;
    background: {M['mantle']};
    color: {M['subtext0']};
}}
"""

#: Fixed ordering for the summary line (spec: "N running · N done · N
#: failed · N queued"); "cancelled" is appended separately, only when > 0.
_SUMMARY_ORDER = ("running", "done", "failed", "queued")

#: States that still mean "not finished yet" — gate both the `esc`
#: confirm-before-close prompt and (implicitly, via the caller) whether a
#: cancel is meaningful.
_UNFINISHED_STATES = ("queued", "running")


def _format_elapsed(seconds: float | None) -> str:
    """`m:ss`, or empty before a host has started (elapsed() returns None)."""
    if seconds is None:
        return ""
    total = int(seconds)
    return f"{total // 60}:{total % 60:02d}"


class PushScreen(Screen[dict[str, str] | None]):
    """Per-host push dashboard: one DataTable row per host, live-updated."""

    DEFAULT_CSS = PUSH_SCREEN_CSS

    BINDINGS = [
        ("x", "cancel_push", "Cancel"),
        ("escape", "close", "Close"),
    ]

    def __init__(
        self, commands: dict[str, list[str]], *, runner_factory=MultiRunner
    ) -> None:
        super().__init__()
        self.commands = dict(commands)
        self._runner = runner_factory(self.commands)
        self._elapsed_timer = None
        self._push_worker: Worker | None = None

    def compose(self) -> ComposeResult:
        yield DataTable(id="push-table", cursor_type="row", zebra_stripes=True)
        yield Static("", id="push-summary", markup=False)

    def on_mount(self) -> None:
        # Wall-clock start of the whole push (spec §3 recording) — the
        # per-host HostRun.started/finished timestamps below are
        # time.monotonic() (elapsed-duration math only, never a real
        # clock), so the history entry's started_at needs its own wall
        # clock captured here, at the earliest point this run exists.
        self._started_at = datetime.now(UTC)
        table = self.query_one("#push-table", DataTable)
        table.add_column("st", key="st", width=2)
        table.add_column("host", key="host", width=18)
        table.add_column("time", key="time", width=7)
        table.add_column("last line", key="last")
        for name in self.commands:
            run = self._runner.runs[name]
            table.add_row(
                icon(run.state, PUSH_ICONS), Text(name), Text(""), Text(""),
                key=name,
            )
        table.focus()
        self._render_summary()
        self._elapsed_timer = self.set_interval(1.0, self._render_elapsed)
        self._push_worker = self.run_worker(
            self._run_push(), group="push", exclusive=True
        )

    async def _run_push(self) -> None:
        # Push mutual exclusion (spec §1): set True the instant the run
        # actually starts, cleared in `finally` when `run()` returns — NOT
        # on screen close (see `_close_flow`/`action_close`), so a finished
        # dashboard left open never blocks a local task. The `finally` also
        # covers an external cancellation of THIS worker (e.g. app shutdown
        # mid-run): the flag always clears even when `run()` never returns
        # normally.
        self.app._push_inflight = True  # type: ignore[attr-defined]
        try:
            await self._runner.run(self._apply_run_update)
            self._notify_completion()
        finally:
            # "stopped when the run completes" — also covers an external
            # cancellation of this worker (e.g. app shutdown mid-run), so
            # the timer never outlives the screen it renders into.
            if self._elapsed_timer is not None:
                self._elapsed_timer.stop()
            self.app._push_inflight = False  # type: ignore[attr-defined]

    def _notify_completion(self) -> None:
        """One OS toast per push run (spec §1), composed the instant the
        run settles — the same completion point `_push_inflight` clears at
        (the dashboard may still be on screen; that's the point of the
        toast). Counts only (`n_ok`/`n_failed`), NEVER host names.

        Rules: any failure -> ALWAYS notify, regardless of duration; all ok
        -> notify only when the run took long enough
        (`app.notify_threshold_secs`) that the user plausibly tabbed away;
        every host cancelled -> never notify (the in-app "cancel push?"
        confirm the user just answered already covers it).
        """
        runs = list(self._runner.runs.values())
        # Recorded unconditionally — including the all-cancelled case the
        # toast logic below skips entirely (that's a notification-noise
        # decision, not a "nothing happened" one; the browser (Task 5)
        # still wants a cancelled entry to show).
        self._record_push_history(runs)
        if runs and all(run.state == "cancelled" for run in runs):
            return
        n_ok = sum(1 for run in runs if run.state == "done")
        n_failed = sum(1 for run in runs if run.state == "failed")
        started = [run.started for run in runs if run.started is not None]
        finished = [run.finished for run in runs if run.finished is not None]
        duration = (max(finished) - min(started)) if started else 0.0
        message = f"push — {n_ok} ok, {n_failed} failed ({int(duration)}s)"
        if n_failed:
            self.app.notifier("workstation", message)  # type: ignore[attr-defined]
        elif duration >= self.app.notify_threshold_secs:  # type: ignore[attr-defined]
            self.app.notifier("workstation", message)  # type: ignore[attr-defined]

    def _record_push_history(self, runs: list[HostRun]) -> None:
        """Record one "push" history entry (spec §3) for the whole run.

        Same counts (`n_ok`/`n_failed`) and duration math as
        `_notify_completion` above, plus `n_cancelled` for the outcome
        rule: any failure wins outcome="failed"; else outcome="cancelled"
        only when EVERY host was cancelled; else "ok". The summary line is
        counts-only (never a host name, mirroring the toast policy above)
        but the log this entry stores DOES carry host names, one `===
        <name> (<state>, rc=<rc>) ===` banner per host followed by that
        host's captured lines — it's the markup=False on-disk log a user
        opts into reading later (Task 5's browser), not an OS toast.
        """
        n_ok = sum(1 for run in runs if run.state == "done")
        n_failed = sum(1 for run in runs if run.state == "failed")
        n_cancelled = sum(1 for run in runs if run.state == "cancelled")
        started = [run.started for run in runs if run.started is not None]
        finished = [run.finished for run in runs if run.finished is not None]
        duration = (max(finished) - min(started)) if started else 0.0
        outcome = "failed" if n_failed else ("cancelled" if n_cancelled == len(runs) else "ok")
        entry = HistoryEntry(
            id=new_entry_id(self._started_at),
            started_at=self._started_at.isoformat(),
            kind="push",
            command=None,
            summary=f"push — {n_ok} ok, {n_failed} failed",
            returncode=None,
            duration_secs=duration,
            cancelled=outcome == "cancelled",
            outcome=outcome,
            needs_sudo=False,
        )
        lines: list[str] = []
        for run in runs:
            lines.append(f"=== {run.name} ({run.state}, rc={run.rc}) ===")
            lines.extend(run.lines)
        self.app.record_history(entry, lines)  # type: ignore[attr-defined]

    # -- rendering (same event loop as MultiRunner — direct widget access) --

    def _apply_run_update(self, name: str) -> None:
        # NOT named `_on_update`/`on_update` — Textual's message dispatch
        # (`_get_dispatch_methods`) treats ANY method matching `_on_<msg>`
        # or `on_<msg>` as an auto-handler for that message class, and
        # `textual.messages.Update` is a real internal message; a method
        # literally named `_on_update` gets invoked BY THE MESSAGE PUMP
        # with an `Update` message object in place of MultiRunner's host
        # name string, crashing `_render_row`'s dict lookup.
        self._render_row(name)
        self._render_summary()

    def _render_row(self, name: str) -> None:
        run = self._runner.runs.get(name)
        if run is None:
            return
        table = self.query_one("#push-table", DataTable)
        table.update_cell(name, "st", icon(run.state, PUSH_ICONS))
        table.update_cell(
            name, "time", Text(_format_elapsed(run.elapsed(time.monotonic())))
        )
        table.update_cell(name, "last", Text(run.lines[-1] if run.lines else ""))

    def _render_elapsed(self) -> None:
        table = self.query_one("#push-table", DataTable)
        now = time.monotonic()
        for name, run in self._runner.runs.items():
            if run.state != "running":
                continue
            table.update_cell(name, "time", Text(_format_elapsed(run.elapsed(now))))

    def _render_summary(self) -> None:
        counts = Counter(run.state for run in self._runner.runs.values())
        parts = [f"{counts.get(s, 0)} {s}" for s in _SUMMARY_ORDER]
        if counts.get("cancelled", 0):
            parts.append(f"{counts['cancelled']} cancelled")
        self.query_one("#push-summary", Static).update(" · ".join(parts))

    # -- outcomes -------------------------------------------------------

    def _outcomes(self) -> dict[str, str]:
        return {name: run.state for name, run in self._runner.runs.items()}

    # -- keys -------------------------------------------------------------

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "push-table":
            return
        row_key = event.row_key
        name = str(row_key.value) if row_key and row_key.value else None
        if name is None:
            return
        run = self._runner.runs.get(name)
        if run is None:
            return
        self.app.push_screen(TextViewScreen("\n".join(run.lines), title=name))

    def action_cancel_push(self) -> None:
        self.run_worker(self._cancel_flow(), exclusive=False, group="push-confirm")

    async def _cancel_flow(self) -> None:
        ok = await self.app.push_screen_wait(ConfirmModal("cancel push?"))
        if not ok:
            return
        self._runner.cancel()

    def action_close(self) -> None:
        self.run_worker(self._close_flow(), exclusive=False, group="push-confirm")

    async def _close_flow(self) -> None:
        running = any(
            run.state in _UNFINISHED_STATES for run in self._runner.runs.values()
        )
        if running:
            ok = await self.app.push_screen_wait(
                ConfirmModal("push still running — cancel and close?")
            )
            if not ok:
                return
            self._runner.cancel()
            # `MultiRunner.cancel()` only requests cancellation of the
            # per-host tasks — each HostRun's actual state="cancelled"
            # transition happens inside that task's own
            # `except asyncio.CancelledError` handler on ITS next
            # scheduling turn, not synchronously here. Without waiting for
            # the "push" worker (which awaits `runner.run()`, i.e. every
            # per-host task) to actually finish settling, `_outcomes()`
            # below would read whatever state each host happened to be in
            # the instant `cancel()` returned — usually still "running",
            # never "cancelled".
            await self._await_push_worker_settled()
        self.dismiss(self._outcomes())

    async def _await_push_worker_settled(self) -> None:
        if self._push_worker is None:
            return
        with contextlib.suppress(WorkerCancelled, WorkerFailed):
            await self._push_worker.wait()
