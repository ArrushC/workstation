"""UpdatesScreen — parsed `check-updates` table + cache viewer (Phase C §2).

Opened from `ProvisionPanel.action_updates` (`u`) via `self.app.push_screen
(UpdatesScreen())` — same TextViewScreen/HostStatsScreen 90%-box ModalScreen
precedent, but a DataTable body instead of a text blob or key/value grid.

Unlike HostStatsScreen (no caching — always re-probes on open), this screen
is cache-FIRST: `on_mount` renders whatever `load_updates_cache` finds on
disk immediately (so reopening the screen is instant even offline), then
kicks off a fresh `check-updates` run in the background via the app's
normal `launch_task` machinery (the same one/queued-task discipline every
other panel action uses — `app._task_inflight`/`app._runner.busy`/
`app._push_inflight` all gate it, showing cached results with a banner
instead of queuing a second task).

The constructor takes no arguments — everything (`updates_cache_path`,
`_make_context()`, `_resolve_log()`, `launch_task`, the runner/task-inflight
state) is read from `self.app` at call time, so this screen never needs
injected fakes; tests drive it through a real `WorkstationApp` + `FakeRunner`
(Task 1's `check_updates_command(..., porcelain=True)` is what `_start_check`
runs). Logging the fresh check's output goes through `app._resolve_log(None)`
— the same provision-panel `append_log` fallback `launch_task` itself uses —
rather than this module querying/importing `ProvisionPanel` directly, which
would recreate the very import cycle panels/provision.py importing THIS
module (for `action_updates`) already sits on the other side of.

`_make_context()` can raise `RuntimeError("workstation repo not found")`
(e.g. a misconfigured `WORKSTATION_REPO` or a relocated install) — caught in
`_start_check` and degraded to a banner + a toast, never left to escape
`on_mount`/`action_recheck` and take the whole app down.

The fresh-check result callback is a genuine Python closure over a local
`buffer: list[str]` (captured by both the `tee` log function and the
`on_result` callback built in the SAME `_start_check()` call) — not an
instance attribute — so a check started just before the screen is
dismissed keeps writing into ITS OWN buffer/cache regardless of what
happens to `self` afterwards (`_task_inflight` already blocks a second
`_start_check` from running concurrently, but the closure means this
never needed to matter). `self.is_attached` gates every render/banner
mutation triggered by that callback — closing the screen mid-check never
raises trying to touch an unmounted widget, but the cache write to disk
(`save_updates_cache`) happens unconditionally on rc==0/not-cancelled,
BEFORE that gate — so a check started, then the screen closed, still
lands its result in the cache for next time.

Every DataTable cell is `Text()`-wrapped (the markup-crash class
dotfiles.py/provision.py/health.py all guard against — tool names here
come from `check-updates.sh`'s own tool registry, tame today, but the
convention stays uniform).
"""

from datetime import UTC, datetime

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import DataTable, Static

from workstation_tui.app.theme import M, UPDATE_ICONS, icon
from workstation_tui.core.fleet import rel_age
from workstation_tui.core.makeiface import check_updates_command
from workstation_tui.core.models import TaskResult
from workstation_tui.core.updates import (
    UpdatesCache,
    load_updates_cache,
    parse_updates,
    save_updates_cache,
    sort_rows,
)

UPDATES_CSS = f"""
UpdatesScreen {{
    align: center middle;
}}
#updates-box {{
    width: 90%;
    height: 90%;
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
#updates-title {{
    color: {M['mauve']};
    text-style: bold;
    height: 1;
}}
#updates-banner {{
    color: {M['subtext0']};
    height: 1;
}}
#updates-table {{
    height: 1fr;
}}
#updates-summary {{
    color: {M['subtext0']};
    height: 1;
}}
"""


def _age_text(checked_at: str | None) -> str:
    """`rel_age()` of an ISO-8601 `checked_at`, or `"never"` when absent,
    or `"?"` on any parse/computation failure (e.g. a hand-edited cache
    holding a malformed or naive/tz-less timestamp) — never raises.

    F9: the tz-aware subtraction below used to sit OUTSIDE the try, so a
    naive `datetime.fromisoformat` result (parses fine — `fromisoformat`
    doesn't require a `Z`/offset) raised an uncaught `TypeError` against
    `datetime.now(UTC)` instead of the `ValueError` this only used to
    guard against. That escaped from `_render_summary`, called from a
    `call_from_thread` callback, which meant `WorkerFailed` and the whole
    app dying on every refresh until the cache file was deleted by hand.
    The WHOLE computation is now inside one `try`, mirroring
    `history_screen.py`'s `_when_text`/`palette.py`'s `_history_name`
    degrade-to-placeholder discipline.
    """
    if not checked_at:
        return "never"
    try:
        checked_dt = datetime.fromisoformat(checked_at)
        delta = (datetime.now(UTC) - checked_dt).total_seconds()
    except Exception:
        return "?"
    return rel_age(max(delta, 0.0))


class UpdatesScreen(ModalScreen[None]):
    """Read-only `check-updates` table — TextViewScreen's 90%-box model
    with a DataTable body, cache-first render + background refresh."""

    DEFAULT_CSS = UPDATES_CSS

    BINDINGS = [
        ("escape", "close", "Close"),
        ("q", "close", "Close"),
        ("s", "sort", "Sort"),
        ("R", "recheck", "Re-check"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._cache: UpdatesCache = UpdatesCache()
        self._sort_key: str = "status"

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="updates-box"):
            yield Static("check updates", id="updates-title", markup=False)
            yield Static("", id="updates-banner", markup=False)
            yield DataTable(id="updates-table", zebra_stripes=True)
            yield Static("", id="updates-summary", markup=False)

    def on_mount(self) -> None:
        self.query_one("#updates-box", VerticalScroll).focus()
        table = self.query_one("#updates-table", DataTable)
        table.add_column("st", key="st", width=2)
        table.add_column("tool", key="tool", width=20)
        table.add_column("pinned", key="pinned", width=14)
        table.add_column("latest", key="latest", width=14)
        table.add_column("detail", key="detail")
        self._cache = load_updates_cache(self.app.updates_cache_path)  # type: ignore[attr-defined]
        self._render_table()
        self._start_check()

    def action_close(self) -> None:
        self.dismiss(None)

    def action_sort(self) -> None:
        self._sort_key = "name" if self._sort_key == "status" else "status"
        self._render_table()

    def action_recheck(self) -> None:
        self._start_check()

    # -- rendering ----------------------------------------------------------

    def _render_table(self) -> None:
        table = self.query_one("#updates-table", DataTable)
        table.clear()
        for row in sort_rows(self._cache.rows, self._sort_key):
            table.add_row(
                icon(row.status, UPDATE_ICONS),
                Text(row.name),
                Text(row.pinned or "—"),
                Text(row.latest or "—"),
                Text(row.detail),
                key=row.name,
            )
        self._render_summary()

    def _render_summary(self) -> None:
        rows = self._cache.rows
        n_update = sum(1 for r in rows if r.status == "update")
        n_ok = sum(1 for r in rows if r.status == "ok")
        n_rolling = sum(1 for r in rows if r.status == "rolling")
        n_unchecked = sum(1 for r in rows if r.status in ("ahead", "unknown"))
        age = _age_text(self._cache.checked_at)
        self.query_one("#updates-summary", Static).update(
            f"{n_update} updates · {n_ok} ok · {n_rolling} rolling · "
            f"{n_unchecked} unchecked · checked {age}"
        )

    def _set_banner(self, text: str) -> None:
        self.query_one("#updates-banner", Static).update(text)

    # -- fresh check ----------------------------------------------------------

    def _start_check(self) -> None:
        app = self.app
        if app._task_inflight or app._runner.busy or app._push_inflight:  # type: ignore[attr-defined]
            self._set_banner("task running — showing cached results")
            return
        try:
            root, mode = app._make_context()  # type: ignore[attr-defined]
        except RuntimeError as exc:
            # find_repo_root() came back None (misconfigured
            # WORKSTATION_REPO, a relocated install) — degrade to the
            # cached table instead of letting the RuntimeError escape
            # on_mount()/action_recheck() and crash the whole app.
            self._set_banner("repo not found — showing cached results")
            app.notify(str(exc), severity="error", markup=False)  # type: ignore[attr-defined]
            return
        # `app._resolve_log(None)` already returns the provision panel's
        # bound `append_log` (app.py's own log_to fallback for launch_task)
        # — reusing it here means this screen never needs to import/query
        # ProvisionPanel itself (panels/provision.py imports THIS module for
        # action_updates, so a module-level or lazy import the other way
        # would reintroduce the cycle #141-era review already killed).
        log = app._resolve_log(None)  # type: ignore[attr-defined]
        buffer: list[str] = []

        def tee(line: str) -> None:
            buffer.append(line)
            log(line)

        def on_result(result: TaskResult) -> None:
            self._on_check_result(result, buffer)

        app.launch_task(  # type: ignore[attr-defined]
            check_updates_command(root, mode), log_to=tee, on_result=on_result,
        )
        self._set_banner("checking…")

    def _on_check_result(self, result: TaskResult, buffer: list[str]) -> None:
        if result.cancelled:
            if self.is_attached:
                self._set_banner("check cancelled")
            return
        if result.returncode != 0:
            if self.is_attached:
                self._set_banner(f"last check failed (rc={result.returncode})")
            return
        rows = parse_updates("\n".join(buffer))
        cache = UpdatesCache(checked_at=datetime.now(UTC).isoformat(), rows=rows)
        save_updates_cache(self.app.updates_cache_path, cache)  # type: ignore[attr-defined]
        if self.is_attached:
            self._cache = cache
            self._render_table()
            self._set_banner("")
