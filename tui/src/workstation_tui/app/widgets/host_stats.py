"""HostStatsScreen — read-only quick-stats drill-in for a single fleet host
(design spec `docs/superpowers/specs/2026-08-10-tui-phase-b-design.md` §2
"Host drill-in quick-stats").

Opened via `FleetPanel.on_data_table_row_selected` (the health/dotfiles
enter-drills-into-DataTable precedent — DataTable consumes `enter` itself,
so this is never a FleetPanel-level BINDINGS entry). Two-stage on-loop
async worker, group `"host-stats"`, `exclusive=True` (an `R` re-run or a
second row-select cancels whatever probe cycle was still in flight, same
as fleet.py's own "probes" group):

1. TCP reachability (`probe_host` by default), timed with
   `time.monotonic()` for a locally-measured round-trip latency. `"down"`
   renders the unreachable banner WITHOUT ever spawning ssh — stage 2 never
   runs.
2. `stats_command(entry)` via `exec_fn` (BatchMode ssh running
   `STATS_REMOTE_SCRIPT`), `stdout=PIPE, stderr=DEVNULL`, given 15s to
   `communicate()`. A spawn failure, a `communicate()` timeout, or any
   other `communicate()` exception renders the same unreachable banner
   (never raises out of the worker). A worker cancellation arriving while
   `communicate()` is in flight (screen closed, or `R` pressed again) gets
   the SAME kill+reap treatment as a timeout — `core/fleet.probe_setup`'s
   documented discipline for exactly this class of leak — before letting
   the `CancelledError` propagate.

No caching: the screen instance owns all state, so closing (`esc`) and
reopening always re-probes from scratch; `R` re-runs the same two-stage
worker.

Every remote/user-derived value renders through a `markup=False` Static —
the title includes the host name, which is USER-TYPED via HostFormModal
(the same markup-crash class dotfiles.py/fleet.py call out for pending
paths/host fields).
"""

import asyncio
import contextlib
import time

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Static

from workstation_tui.app.theme import M
from workstation_tui.core.fleet import probe_host, rel_age
from workstation_tui.core.hoststats import HostStats, parse_stats, stats_command
from workstation_tui.core.models import HostEntry

#: (label, field-id) pairs per section — drives both compose()'s row
#: construction and _render_stats' Static.update() calls from the SAME
#: list, so a field can never drift out of sync between the two.
_VITALS_FIELDS = [
    ("uptime", "uptime"), ("mem", "mem"), ("disk", "disk"),
    ("kernel", "kernel"), ("os", "os"),
]
_WORKSTATION_FIELDS = [
    ("repo", "repo"), ("commit", "commit"), ("branch", "branch"),
    ("dirty", "dirty"), ("stamp age", "stamp"), ("drift", "drift"),
]
_SESSION_FIELDS = [("users", "users"), ("names", "names"), ("latency", "latency")]
_TOOLS_FIELDS = [("chezmoi", "chezmoi"), ("git", "git"), ("make", "make")]

_ALL_FIELDS = _VITALS_FIELDS + _WORKSTATION_FIELDS + _SESSION_FIELDS + _TOOLS_FIELDS

_DASH = "–"


def _text(value: str | None) -> str:
    return value if value is not None else _DASH


def _repo_text(present: bool | None) -> str:
    if present is None:
        return _DASH
    return "present" if present else "absent"


def _stamp_age(epoch: str | None) -> str:
    """`rel_age(time.time() - int(epoch))`, guarded: a non-numeric/absent
    `stamp_epoch` (parse_stats never guarantees the remote script's `stamp`
    line was itself numeric) renders the same dash as any other missing
    field instead of raising out of the render path.
    """
    if epoch is None:
        return _DASH
    try:
        secs = time.time() - int(epoch)
    except (TypeError, ValueError):
        return _DASH
    return rel_age(secs)


HOST_STATS_CSS = f"""
HostStatsScreen {{
    align: center middle;
}}
#host-stats-box {{
    width: 90%;
    height: 90%;
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
#host-stats-title {{
    color: {M['mauve']};
    text-style: bold;
    height: 1;
}}
#host-stats-status {{
    color: {M['subtext0']};
    height: 1;
}}
.host-stats-heading {{
    color: {M['subtext1']};
    text-style: bold;
    height: 1;
    margin-top: 1;
}}
.host-stats-row {{
    height: 1;
}}
.host-stats-label {{
    width: 14;
    color: {M['subtext0']};
}}
.host-stats-value {{
    width: 1fr;
    color: {M['text']};
}}
"""


class HostStatsScreen(ModalScreen[None]):
    """Read-only per-host quick-stats overlay — TextViewScreen's 90%-box
    model, but structured key/value rows (per-field Statics that update in
    place on `R`) instead of a single scrollable text blob."""

    DEFAULT_CSS = HOST_STATS_CSS

    BINDINGS = [
        ("escape", "close", "Close"),
        ("q", "close", "Close"),
        ("R", "rerun", "Refresh"),
    ]

    def __init__(
        self,
        entry: HostEntry,
        *,
        exec_fn=asyncio.create_subprocess_exec,
        probe=probe_host,
    ) -> None:
        super().__init__()
        self.entry = entry
        self._exec_fn = exec_fn
        self._probe = probe

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="host-stats-box"):
            # Host name is USER-TYPED (HostFormModal) -> markup=False, same
            # discipline as every other user-derived Static in this screen.
            yield Static(
                f"host stats — {self.entry.name}", id="host-stats-title",
                markup=False,
            )
            yield Static("loading…", id="host-stats-status", markup=False)
            with Vertical(id="host-stats-grid"):
                yield Static("Vitals", classes="host-stats-heading", markup=False)
                for label, field_id in _VITALS_FIELDS:
                    yield self._row(label, field_id)
                yield Static("Workstation", classes="host-stats-heading",
                              markup=False)
                for label, field_id in _WORKSTATION_FIELDS:
                    yield self._row(label, field_id)
                yield Static("Session", classes="host-stats-heading", markup=False)
                for label, field_id in _SESSION_FIELDS:
                    yield self._row(label, field_id)
                yield Static("Tools", classes="host-stats-heading", markup=False)
                for label, field_id in _TOOLS_FIELDS:
                    yield self._row(label, field_id)

    @staticmethod
    def _row(label: str, field_id: str) -> Horizontal:
        return Horizontal(
            Static(label, classes="host-stats-label", markup=False),
            Static(_DASH, id=f"host-stats-{field_id}", classes="host-stats-value",
                   markup=False),
            classes="host-stats-row",
        )

    def on_mount(self) -> None:
        self.query_one("#host-stats-box", VerticalScroll).focus()
        self._start_load()

    def action_close(self) -> None:
        self.dismiss(None)

    def action_rerun(self) -> None:
        self._start_load()

    def _start_load(self) -> None:
        self.query_one("#host-stats-grid", Vertical).display = False
        self._set_status("loading…")
        # Pass the bound METHOD, not an already-invoked coroutine (fleet.py
        # _apply_hosts' precedent): with exclusive=True, a group-cancel
        # landing before this worker's first tick (routine on a rapid
        # double `R`) would otherwise tear down a pre-built coroutine that
        # was never awaited, logging "coroutine was never awaited" at GC
        # time. A callable lets Textual construct the coroutine lazily.
        self.run_worker(self._load, exclusive=True, group="host-stats")

    def _set_status(self, text: str, *, visible: bool = True) -> None:
        status = self.query_one("#host-stats-status", Static)
        status.update(text)
        status.display = visible

    # -- worker -----------------------------------------------------------

    async def _load(self) -> None:
        t0 = time.monotonic()
        state = await self._probe(self.entry.address)
        latency = f"{(time.monotonic() - t0) * 1000:.0f}ms"

        if state == "down":
            self._render_unreachable(f"⚠ host unreachable — down ({latency})")
            return

        argv = stats_command(self.entry)
        try:
            proc = await self._exec_fn(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            self._render_unreachable(
                f"⚠ host unreachable — ssh failed ({latency})"
            )
            return

        try:
            stdout, _ = await asyncio.wait_for(proc.communicate(), 15.0)
        except asyncio.CancelledError:
            # Worker cancelled mid-communicate (screen closed, or a fresh
            # `R` restarting the exclusive group) — kill + reap the ssh
            # child (core/fleet.probe_setup's documented discipline) before
            # letting cancellation propagate; routine, not a failure to
            # swallow.
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            raise
        except Exception:
            # Covers both asyncio.wait_for's TimeoutError (TimeoutError is
            # an OSError subclass since 3.10 unification, but caught here
            # generically like probe_setup's own broad catch) and any other
            # communicate() failure — same kill+reap, then degrade to the
            # unreachable banner rather than raising out of the worker.
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            self._render_unreachable(
                f"⚠ host unreachable — ssh failed ({latency})"
            )
            return

        stats = parse_stats(stdout.decode(errors="replace"))
        self._render_stats(stats, latency)

    # -- rendering ----------------------------------------------------------

    def _render_unreachable(self, message: str) -> None:
        self.query_one("#host-stats-grid", Vertical).display = False
        self._set_status(message)

    def _render_stats(self, stats: HostStats, latency: str) -> None:
        self._set_status("", visible=False)
        self.query_one("#host-stats-grid", Vertical).display = True
        values = {
            "uptime": _text(stats.uptime),
            "mem": _text(stats.mem),
            "disk": _text(stats.disk),
            "kernel": _text(stats.kernel),
            "os": _text(stats.os),
            "repo": _repo_text(stats.repo_present),
            "commit": _text(stats.commit),
            "branch": _text(stats.branch),
            "dirty": _text(stats.dirty),
            "stamp": _stamp_age(stats.stamp_epoch),
            "drift": _text(stats.drift),
            "users": _text(stats.users),
            "names": _text(stats.names),
            "latency": latency,
            "chezmoi": _text(stats.tool_chezmoi),
            "git": _text(stats.tool_git),
            "make": _text(stats.tool_make),
        }
        for _label, field_id in _ALL_FIELDS:
            self.query_one(f"#host-stats-{field_id}", Static).update(
                values[field_id]
            )
