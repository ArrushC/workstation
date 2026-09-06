"""WorkstationApp — the sidebar-rail shell (spec layout A)."""

import asyncio
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Coroutine, Iterable, Literal

from textual.app import App, ComposeResult, SystemCommand
from textual.containers import Horizontal, Vertical
from textual.css.query import NoMatches
from textual.markup import escape
from textual.screen import Screen
from textual.timer import Timer
from textual.widgets import ContentSwitcher, Static

from workstation_tui.app.palette import ActionsProvider, EntitiesProvider, HistoryProvider
from workstation_tui.app.panels.dashboard import DashboardPanel
from workstation_tui.app.panels.dotfiles import DotfilesPanel
from workstation_tui.app.panels.fleet import FleetPanel
from workstation_tui.app.panels.health import HealthPanel
from workstation_tui.app.panels.provision import ProvisionPanel
from workstation_tui.app.theme import M, MOCHA_CSS, kb
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.help_screen import HelpScreen
from workstation_tui.app.widgets.history_screen import HistoryScreen
from workstation_tui.app.widgets.sudo_modal import SudoModal
from workstation_tui.core.chezmoi import read_status, target_diff
from workstation_tui.core.context import detect_context
from workstation_tui.core.fleet import copy_id_command, probe_all
from workstation_tui.core.gitstate import read_git_state
from workstation_tui.core.health import (
    build_health_rollup,
    load_cache,
    read_services,
    read_wsl_interop,
)
from workstation_tui.core.history import HistoryEntry, HistoryStore, new_entry_id, outcome_for
from workstation_tui.core.hostsfile import read_hosts
from workstation_tui.core.makeiface import make_command, read_inventory
from workstation_tui.core.models import (
    GitState,
    HealthRollup,
    HostEntry,
    PendingChange,
    Summary,
    TaskResult,
    ToolStatus,
)
from workstation_tui.core.runner import Runner, TaskBusyError
from workstation_tui.core.stamps import DEFAULT_STAMP_DIR, scan
from workstation_tui.core.sudo import sudo_status, sudo_validate
from workstation_tui.core.summary import gather_summary
from workstation_tui.repo import find_repo_root

PANELS: list[tuple[str, str]] = [
    ("dashboard", "Dashboard"),
    ("provision", "Provision"),
    ("dotfiles", "Dotfiles"),
    ("fleet", "Fleet"),
    ("health", "Health"),
]

#: Per-panel key hints shown in the footer key bar (#key-bar) — swapped in
#: on switch_panel so the footer always reflects the ACTIVE panel's own
#: bindings instead of a static, panel-agnostic hint line living inside
#: each panel's compose() (the old #provision-keys/#dotfiles-keys/
#: #fleet-keys/#health-keys Statics this registry replaces).
PANEL_KEYS: dict[str, list[tuple[str, str]]] = {
    "dashboard": [("←→↑↓", "Move"), ("enter", "Open")],
    "provision": [
        ("r", "Run"), ("c", "Clean"), ("u", "Updates"),
        ("R", "Provision"), ("x", "Cancel"), ("space", "Mark"),
    ],
    "dotfiles": [
        ("enter", "Apply file"), ("a", "Apply"), ("U", "Update"),
        ("A", "Re-add"), ("d", "Diff"),
    ],
    "fleet": [
        ("s", "SSH"), ("p", "Push"), ("P", "Push all"),
        ("a", "Add"), ("e", "Edit"), ("x", "Remove"), ("enter", "Stats"),
        ("k", "Keys"),
    ],
    "health": [("enter", "Run"), ("R", "Run all"), ("o", "Log")],
}

#: Bindings shown in the footer regardless of the active panel. "ctrl+p"
#: is FIRST (Phase C Task 6, spec §1) — Textual's own COMMAND_PALETTE_
#: BINDING, injected into App._bindings at __init__ time (ENABLE_COMMAND_
#: PALETTE defaults True) rather than listed in WorkstationApp.BINDINGS,
#: so there's no class-level Binding entry to point at here; it's still
#: real and live (test_app_shell-style: `pilot.press("ctrl+p")` opens the
#: palette). test_footer_keys.py's drift guard only walks PANEL_KEYS, not
#: this list, so no exemption/carve-out is needed for it.
GLOBAL_KEYS: list[tuple[str, str]] = [
    ("ctrl+p", "Palette"),
    ("1-5", "Panels"), ("ctrl+←/→", "Cycle"), ("g", "Refresh"),
    ("w", "Watch"), ("H", "History"), ("q", "Quit"), ("?", "Help"),
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
CommandPalette > Vertical {{
    background: {M['mantle']};
}}
CommandPalette #--input {{
    border: hkey {M['surface1']};
}}
CommandPalette > .command-palette--highlight {{
    color: {M['mauve']};
    text-style: bold;
}}
CommandPalette > .command-palette--help-text {{
    color: {M['overlay0']};
}}
"""


def _default_provider() -> Summary:
    root = find_repo_root()
    if root is None:
        raise RuntimeError("workstation repo not found")
    return gather_summary(root)


def _command_summary(argv: list[str]) -> str:
    """Build a short, human-meaningful label for an OS toast from a task's
    argv (spec §4 example: `"make fzf — done (rc=0, 42s)"`).

    `" ".join(argv[:2])` (the prior formula) degenerates for every
    make-built command: `make_command()` (core/makeiface.py) always starts
    `["make", "--no-print-directory", "-C", <path>, *goals, "MODE=<mode>"]`,
    so argv[:2] is the byte-identical, tool-less `"make
    --no-print-directory"` for EVERY provision-panel task. Instead, keep
    argv[0] (the program) and pair it with the first subsequent token that
    isn't option-shaped: not `-`-prefixed, not `-C`'s path argument, and
    not a `VAR=value` assignment (`MODE=dev`). That yields `"make fzf"`,
    `"chezmoi apply"`, etc. Falls back to just argv[0] when nothing
    qualifies (e.g. the degenerate `["make", "--no-print-directory", "-C",
    "makefile", "MODE=dev"]` — no goals at all).
    """
    if not argv:
        return ""
    program = argv[0]
    skip_next = False
    for tok in argv[1:]:
        if skip_next:
            skip_next = False
            continue
        if tok == "-C":
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        name, sep, _value = tok.partition("=")
        if sep and name.isidentifier():
            continue
        return f"{program} {tok}"
    return program


def _default_updates_cache_path() -> Path:
    # Same XDG-ish per-user cache convention as health_cache_path above —
    # a sibling file in the same `workstation-tui` cache directory. A
    # module-level function (not inlined in __init__'s default) so tests'
    # autouse fixture can monkeypatch it wholesale (same shape as
    # `_no_real_notifier` patching `_default_notifier`), keeping every
    # un-injected test off the real `~/.cache`.
    return Path.home() / ".cache/workstation-tui/updates.json"


def _default_history_root() -> Path:
    # Same per-user cache convention + monkeypatch-for-tests shape as
    # _default_updates_cache_path above — a sibling directory in the same
    # workstation-tui cache tree, resolved lazily so the autouse test
    # fixture can redirect every un-injected test off the real
    # ~/.cache/workstation-tui/history.
    return Path.home() / ".cache/workstation-tui/history"


#: Cap on captured log lines tee'd into a history entry per task/sequence
#: command — mirrors MultiRunner's own `_LINE_CAP` (core/multirun.py),
#: dropping the oldest line once the cap is exceeded rather than growing
#: unbounded on a chatty/looping command.
_HISTORY_LOG_CAP = 5000


def _tee_log(
    log_target: Callable[[str], None]
) -> tuple[Callable[[str], None], list[str]]:
    """Wrap `log_target` with a capped capture buffer.

    Returns `(log, captured)`: `log` forwards every line to `log_target`
    (so callers can substitute it in place of the original with no
    behavior change) while also appending it to `captured`, dropping the
    oldest line once `_HISTORY_LOG_CAP` is exceeded. `captured` is the
    live list — read it after the run completes.
    """
    captured: list[str] = []

    def log(line: str) -> None:
        captured.append(line)
        if len(captured) > _HISTORY_LOG_CAP:
            del captured[0]
        log_target(line)

    return log, captured


def _default_notifier(title: str, msg: str) -> None:
    # Fire-and-forget OS toast via the repo's existing notify.sh (WSL→Windows
    # toast already handled inside it). Popen, not run — must never block
    # the event loop; the ENTIRE body (including resolving/probing the
    # script path) is wrapped so a missing/broken script (or a host with no
    # notify.sh at all, e.g. non-workstation checkouts) never raises into
    # the caller.
    try:
        script = Path.home() / ".claude/notify.sh"
        if not script.exists():
            return
        subprocess.Popen(
            [str(script), title, msg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except Exception:
        pass


class NavItem(Static):
    def __init__(self, panel_id: str, label: str) -> None:
        super().__init__(f" {label}", classes="nav-item")
        self.panel_id = panel_id

    def on_click(self) -> None:
        self.app.switch_panel(self.panel_id)  # type: ignore[attr-defined]


class WorkstationApp(App):
    CSS = MOCHA_CSS + APP_CSS
    TITLE = "workstation"
    #: Command palette providers (Phase C Task 6, spec §1) — `App.COMMANDS`
    #: is a set containing ONLY `get_system_commands_provider` (the lazy
    #: factory for `SystemCommandsProvider`, which calls back into
    #: `get_system_commands` below) — unioned, not replaced, so that
    #: curated Quit-only list still shows alongside the three providers
    #: here.
    COMMANDS = App.COMMANDS | {ActionsProvider, EntitiesProvider, HistoryProvider}
    BINDINGS = [
        *[(str(i + 1), f"switch('{pid}')", label)
          for i, (pid, label) in enumerate(PANELS)],
        ("g", "refresh", "Refresh"),
        ("w", "toggle_watch", "Watch"),
        ("H", "history", "History"),
        ("q", "quit", "Quit"),
        ("?", "help", "Help"),
        ("ctrl+left", "cycle_panel(-1)", "Prev panel"),
        ("ctrl+right", "cycle_panel(1)", "Next panel"),
    ]

    def __init__(
        self,
        *,
        summary_provider: Callable[[], Summary] | None = None,
        runner: Runner | None = None,
        tools_provider: Callable[[], tuple[list[ToolStatus], list[str]]] | None = None,
        sudo_status_fn: Callable[[], Literal["valid", "needs_password", "no_sudo"]]
        | None = None,
        sudo_validate_fn: Callable[[str], bool] | None = None,
        pending_provider: Callable[[], tuple[list[PendingChange], list[str]]]
        | None = None,
        git_state_provider: Callable[[Path], tuple[GitState | None, list[str]]]
        | None = None,
        target_diff_fn: Callable[[str], tuple[str, str | None]] | None = None,
        probe_all_fn: Callable[
            [list[HostEntry]], Coroutine[Any, Any, dict[str, tuple[str, str | None]]]
        ]
        | None = None,
        hosts_provider: Callable[[], tuple[list[HostEntry], list[str]]] | None = None,
        ssh_fn: Callable[[HostEntry], None] | None = None,
        copy_id_fn: Callable[[list[HostEntry]], list[tuple[str, int]]] | None = None,
        health_cache_path: Path | None = None,
        updates_cache_path: Path | None = None,
        history_store: HistoryStore | None = None,
        services_reader: Callable[[], dict[str, str]] | None = None,
        interop_reader: Callable[[], str] | None = None,
        notifier: Callable[[str, str], None] | None = None,
        watch_interval_secs: float = 30.0,
    ) -> None:
        super().__init__()
        self.summary_provider = summary_provider or _default_provider
        self.summary: Summary | None = None
        self._runner = runner or Runner()
        self.tools_provider = tools_provider or self._default_tools
        self.sudo_status_fn = sudo_status_fn or sudo_status
        self.sudo_validate_fn = sudo_validate_fn or sudo_validate
        self.sudo_keepalive_secs = 60.0
        # Panel data providers for the Dotfiles/Fleet panels (Tasks 6-7) —
        # wired here so the constructor surface is stable across those
        # tasks; nothing in this task calls them yet. Defaults are the real
        # core readers (hosts_provider wraps read_hosts with a resolved repo
        # root, matching the zero-arg calling convention the others share
        # natively); tests inject fakes/recorders.
        self.pending_provider = pending_provider or read_status
        self.git_state_provider = git_state_provider or read_git_state
        self.target_diff_fn = target_diff_fn or target_diff
        self.probe_all_fn = probe_all_fn or probe_all
        self.hosts_provider = hosts_provider or self._default_hosts
        self.ssh_fn = ssh_fn
        # Guided key distribution (Task 6) — same injectable-default seam as
        # ssh_fn above; None means "use the real _default_copy_id suspend
        # flow" (distribute_keys resolves which one to call).
        self.copy_id_fn = copy_id_fn
        # Health panel providers (Phase 6 Task 2) — same injectable-default
        # convention as the providers above; health_cache_path defaults to
        # the standard XDG-ish per-user cache location (this is the only
        # file the TUI itself writes — checks otherwise run unprivileged).
        self.health_cache_path = (
            health_cache_path or Path.home() / ".cache/workstation-tui/health.json"
        )
        # UpdatesScreen (Phase C) + the dashboard's provision-card 4th line
        # share this one cache — same injectable-default convention as
        # health_cache_path above, resolved lazily via a module-level
        # function (not a bare default expression) so the autouse test
        # fixture can monkeypatch it wholesale.
        self.updates_cache_path = updates_cache_path or _default_updates_cache_path()
        # Task/sequence/push/keydist recording (Phase C Task 4) — same
        # injectable-default convention as the caches above, resolved
        # lazily via a module-level function so the autouse test fixture
        # can monkeypatch it wholesale (tests never touch the real
        # ~/.cache/workstation-tui/history).
        self.history_store = history_store or HistoryStore(_default_history_root())
        self.services_reader = services_reader or read_services
        self.interop_reader = interop_reader or read_wsl_interop
        # Desktop notifications (spec §4) — injectable so tests never spawn
        # a real Popen; notify_threshold_secs is a plain post-construction
        # attribute (not a ctor param) so tests can tweak it per-test the
        # same way sudo_keepalive_secs above is tweaked.
        self.notifier = notifier or _default_notifier
        self.notify_threshold_secs = 10.0
        # Auto-refresh watch mode (spec §1) — `w` toggles; the interval
        # timer is created LAZILY on first enable (never in __init__/
        # on_mount, so app boot never pays for a timer nobody asked for)
        # and paused/resumed thereafter — never recreated, so the ticking
        # cadence a test (or a user) set up survives repeated toggles.
        self.watch_interval_secs = watch_interval_secs
        self.watch_enabled = False
        self._watch_timer: Timer | None = None
        # Guards the sudo-gate window (status check + modal) — the runner
        # isn't busy yet during that window, so a second launch_task() call
        # (e.g. a double "r" press) would otherwise slip past the
        # `self._runner.busy` check and stack a second modal. Set True
        # before the task worker starts, cleared in _task_flow's finally.
        self._task_inflight = False
        # Push mutual exclusion (spec §1): PushScreen sets this True the
        # instant its run worker starts, and clears it in a `finally` when
        # `run()` returns — NOT when the screen closes, so a finished push
        # dashboard left open never blocks a local task. launch_task/
        # run_task_sequence/_watch_tick all refuse while a push is in
        # flight, mirroring the _task_inflight/_runner.busy vocabulary
        # above with a distinct "push running" toast so the user knows
        # which kind of work is in the way.
        self._push_inflight = False
        # F3: an unwritable/broken history store used to drop every
        # record silently (spec says "the app logs a warning line"). One
        # warning toast per session is enough to tell the user something
        # is wrong without spamming one per run — set True the first time
        # `record_history`'s background write comes back False.
        self._history_warned = False

    def compose(self) -> ComposeResult:
        yield Static("", id="app-header", markup=True)
        with Horizontal(id="main"):
            with Vertical(id="sidebar"):
                for pid, label in PANELS:
                    yield NavItem(pid, label)
            with ContentSwitcher(initial="dashboard", id="content"):
                yield DashboardPanel(id="dashboard")
                yield ProvisionPanel(id="provision")
                yield DotfilesPanel(id="dotfiles")
                yield FleetPanel(id="fleet")
                yield HealthPanel(id="health")
        yield Static("", id="key-bar", markup=True)

    def on_mount(self) -> None:
        self._mark_active("dashboard")
        self._render_key_bar("dashboard")
        # DEFERRED, not called directly: App.on_mount fires before the panels
        # inside #content have finished mounting their own compose() children.
        # action_refresh() starts a thread worker whose call_from_thread
        # callbacks (_apply_summary / _apply_tools) query deep into those
        # panels, so a fast provider could win the race and raise NoMatches
        # *inside the worker* — surfacing as WorkerFailed and intermittently
        # reddening unrelated tests (seen on #provision-table and
        # #health-table). call_after_refresh runs after the next render pass,
        # by which point every panel's tree exists.
        self.call_after_refresh(self.action_refresh)
        try:
            self.query_one("#dashboard", DashboardPanel).focus_first_card()
        except NoMatches:
            pass

    def _render_key_bar(self, panel_id: str) -> None:
        # Panel keys FIRST, global keys last — #key-bar is height:1 and a
        # narrow terminal (~140 cols) truncates the tail of the line, so the
        # panel-specific hints (the actually-new information for whatever
        # you're looking at) must not be the part that gets clipped.
        # `.get(panel_id, [])` also means an unregistered panel_id renders
        # global-only instead of raising KeyError.
        self.query_one("#key-bar", Static).update(
            kb(*PANEL_KEYS.get(panel_id, []), *GLOBAL_KEYS)
        )

    def switch_panel(self, panel_id: str) -> None:
        self.query_one("#content", ContentSwitcher).current = panel_id
        self._mark_active(panel_id)
        self._render_key_bar(panel_id)
        if panel_id == "dashboard":
            self.query_one("#dashboard", DashboardPanel).focus_first_card()

    def action_switch(self, panel_id: str) -> None:
        self.switch_panel(panel_id)

    def action_cycle_panel(self, delta: int) -> None:
        ids = [pid for pid, _ in PANELS]
        current = self.query_one("#content", ContentSwitcher).current
        idx = ids.index(current) if current in ids else 0
        self.switch_panel(ids[(idx + delta) % len(ids)])

    def get_system_commands(self, screen: Screen[Any]) -> Iterable[SystemCommand]:
        """Curated system-commands list for the palette (Phase C Task 6):
        Quit only — deliberately NOT calling `super().get_system_commands`,
        which would also surface Textual's generic "Theme"/"Keys" commands
        that don't apply to this app's fixed Catppuccin-Mocha theme/no
        help-panel model. Everything else the palette needs (panel
        switches, refresh/watch/history/help, entities, history re-runs)
        comes from `ActionsProvider`/`EntitiesProvider`/`HistoryProvider`
        in `COMMANDS` above, not this system-commands hook.
        """
        yield SystemCommand("Quit", "Quit the application", self.action_quit)

    def action_help(self) -> None:
        self.push_screen(HelpScreen())

    def action_history(self) -> None:
        # F6: reachable a second time from the palette's "task history"
        # command while HistoryScreen is already the top screen (the
        # global `H` binding is inert under a ModalScreen, but the
        # palette's own priority binding still fires) — without this
        # guard that stacks a second, identical HistoryScreen instead of
        # just leaving the one already open in place.
        if isinstance(self.screen, HistoryScreen):
            return
        self.push_screen(HistoryScreen())

    def action_refresh(self) -> None:
        # Isolated in its own worker group ("summary") so that this
        # exclusive=True cancellation can never reach a task worker running
        # in the "task" group (see launch_task) — cross-group cancellation
        # was routing through the runner's exception boundary and SIGKILLing
        # an in-flight make with no toast.
        self.run_worker(
            self._load_summary, thread=True, exclusive=True, group="summary"
        )

    def _load_summary(self) -> None:
        try:
            summary = self.summary_provider()
        except Exception as exc:  # surface, never crash the shell
            self.call_from_thread(
                self._show_header_error, f"{type(exc).__name__}: {exc}"
            )
            return
        # Runs on this worker's own thread already (thread=True above), so
        # the blocking cache read + the gating-first services/interop reads
        # inside build_health_rollup happen here, same as tools_provider()
        # below — never on the event loop.
        cache = load_cache(self.health_cache_path)
        rollup = build_health_rollup(
            cache, summary.context, self.services_reader, self.interop_reader
        )
        self.call_from_thread(self._apply_summary, summary, rollup)
        tools, errors = self.tools_provider()
        self.call_from_thread(self._apply_tools, tools, errors)

    def _default_tools(self) -> tuple[list[ToolStatus], list[str]]:
        root = find_repo_root()
        if root is None:
            return [], ["workstation repo not found"]
        mode = self.summary.context.mode if self.summary else detect_context().mode
        rows, errs = read_inventory(root, mode)
        return scan(DEFAULT_STAMP_DIR, rows), errs

    def _default_hosts(self) -> tuple[list[HostEntry], list[str]]:
        root = find_repo_root()
        if root is None:
            return [], ["workstation repo not found"]
        return read_hosts(root)

    def _apply_tools(self, tools: list[ToolStatus], errors: list[str]) -> None:
        self.query_one("#provision", ProvisionPanel).set_tools(tools, errors)

    def _render_header(self) -> None:
        # Extracted so BOTH the normal post-refresh path (_apply_summary)
        # and the watch-mode toggle (action_toggle_watch) can push a fresh
        # header line — the toggle must reflect its new state IMMEDIATELY,
        # not wait for the next action_refresh() cycle. Handles the
        # pre-first-summary case (nothing loaded yet, e.g. `w` pressed
        # before boot's initial refresh lands) by rendering the bare title
        # instead of crashing on a None summary.
        if self.summary is None:
            self.query_one("#app-header", Static).update(
                f"[bold {M['mauve']}]workstation[/]"
            )
            return
        c = self.summary.context
        wsl = " · WSL" if c.is_wsl else ""
        watch = (
            f" · watch {int(self.watch_interval_secs)}s" if self.watch_enabled else ""
        )
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] "
            f"[{M['subtext0']}]— {c.os} · group={c.group or '?'} · "
            f"mode={c.mode}{wsl}{watch}[/]"
        )

    def action_toggle_watch(self) -> None:
        self.watch_enabled = not self.watch_enabled
        if self.watch_enabled:
            if self._watch_timer is None:
                self._watch_timer = self.set_interval(
                    self.watch_interval_secs, self._watch_tick, pause=False
                )
            else:
                self._watch_timer.resume()
        elif self._watch_timer is not None:
            self._watch_timer.pause()
        self._render_header()

    def _watch_tick(self) -> None:
        # Never compete with an in-flight task (sudo gate window OR an
        # actual running command) OR a push dashboard — same guard
        # vocabulary launch_task uses.
        if self._task_inflight or self._runner.busy or self._push_inflight:
            return
        self.action_refresh()

    def _apply_summary(self, summary: Summary, rollup: HealthRollup) -> None:
        self.summary = summary
        c = summary.context
        self._render_header()
        dashboard_panel = self.query_one("#dashboard", DashboardPanel)
        dashboard_panel.update_summary(summary)
        dashboard_panel.update_health(rollup)
        provision_panel = self.query_one("#provision", ProvisionPanel)
        if c.has_make:
            # Reset in case an earlier refresh (different host/context, or
            # a test swapping providers mid-session) had marked it
            # unavailable — set_tools() below no-ops while unavailable.
            provision_panel.unavailable = False
        else:
            provision_panel.set_unavailable(
                "provisioning not available here — make is absent "
                "(Windows hosts provision via bootstrap.ps1)"
            )
        dotfiles_panel = self.query_one("#dotfiles", DotfilesPanel)
        if c.has_chezmoi:
            # Same reset-on-availability-change rationale as provision_panel
            # above; refresh_panel() itself is safe to call every refresh
            # (it re-fetches pending + git state, not a one-shot log line).
            dotfiles_panel.unavailable = False
            dotfiles_panel.refresh_panel()
        elif not dotfiles_panel.unavailable:
            # Guarded so the unavailable message logs once per availability
            # CHANGE, not once per refresh (the Phase-4 parked lesson —
            # set_unavailable() itself appends a log line).
            dotfiles_panel.set_unavailable(
                "dotfiles not available here — chezmoi is absent"
            )
        # Fleet has no availability gate (hosts.conf is always readable via
        # the same repo checkout that ships make/chezmoi) — unlike
        # provision/dotfiles above, refresh unconditionally on every cycle
        # (panel mount is itself the first cycle, i.e. "on panel entry";
        # every subsequent action_refresh() call, e.g. `g` or a completed
        # task, is the "+ refresh" half).
        self.query_one("#fleet", FleetPanel).refresh_panel()
        # Health has no host-level availability gate either (individual
        # checks gate themselves via check_available() at run time) —
        # unconditional refresh every cycle, same rationale as fleet above.
        self.query_one("#health", HealthPanel).refresh_panel()

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

    def _make_context(self) -> tuple[Path, str]:
        """Resolve the repo root + active mode shared by every make-goal
        launcher (`run_make_goals` below, and `UpdatesScreen._start_check`).

        Extracted from `run_make_goals`'s own resolution (pure refactor —
        behavior there is unchanged). Never a synchronous `detect_context()`
        fallback for the ROOT half — `find_repo_root()` is a cheap path
        probe, not a subprocess — but `detect_context()` covers the same
        "summary hasn't loaded yet" case `_sudo_gate` already handles, for
        callers (UpdatesScreen) that may run before the first summary
        lands. Raises `RuntimeError("workstation repo not found")` — the
        exact message `run_make_goals` used to notify directly — when the
        repo can't be located, so its caller's error text/severity survive
        the extraction unchanged.
        """
        root = find_repo_root()
        if root is None:
            raise RuntimeError("workstation repo not found")
        mode = self.summary.context.mode if self.summary is not None else detect_context().mode
        return root, mode

    def run_make_goals(
        self,
        goals: list[str],
        *,
        user_kind: bool,
        on_result: Callable[[TaskResult], None] | None = None,
    ) -> None:
        # Resolve mode from the cached summary only — never a synchronous
        # detect_context() fallback here. detect_context() shells out to
        # chezmoi/which and is meant for off-loop use (see _task_flow's
        # asyncio.to_thread-free fallback, which only runs before the app
        # has ever loaded a summary at all). run_make_goals is called
        # synchronously from a key binding, so blocking the event loop on a
        # subprocess here would freeze the UI; if the summary hasn't loaded
        # yet we simply ask the user to retry instead.
        if self.summary is None:
            self.notify("still loading — try again", severity="warning")
            return
        if not self.summary.context.has_make:
            self.notify("make not available on this host", severity="warning")
            return
        try:
            root, mode = self._make_context()
        except RuntimeError as exc:
            self.notify(str(exc), severity="error")
            return
        cmd = make_command(root, goals, mode)
        # _task_flow gates this on a valid sudo timestamp before launching.
        needs_sudo = mode == "dev" and not user_kind
        # Minimal, backward-compatible passthrough (optional, keyword-only,
        # defaults to None — every pre-existing call site is unchanged): lets
        # a caller (the Provision panel's marked-run path) observe the
        # TaskResult without duplicating launch_task's sudo-gate/keepalive/
        # notify plumbing.
        self.launch_task(cmd, needs_sudo=needs_sudo, on_result=on_result)

    def ssh_to(self, entry: HostEntry) -> None:
        """SSH to a fleet host.

        A plain (non-worker) method — `self.suspend()` must run on the
        actual app event loop, not inside a background worker. Tests
        inject `ssh_fn` as a recorder; the real path requires a genuine
        TTY (Textual's suspend() needs a real driver), so it's never
        exercised headlessly.
        """
        if self.ssh_fn is not None:
            self.ssh_fn(entry)
            return
        with self.suspend():
            # `--` stops option injection from hostile stored entries (e.g.
            # a user/address value crafted to start with '-' being parsed
            # as an ssh flag instead of part of the destination).
            subprocess.run(["ssh", "--", f"{entry.user}@{entry.address}"])

    def distribute_keys(self, entries: list[HostEntry]) -> None:
        """Guided key-distribution resume flow (Task 6).

        A plain (non-worker) method — mirrors `ssh_to` exactly, for the
        same reason: the default path's `self.suspend()` (inside
        `_default_copy_id`) must run on the actual app event loop, not
        inside a background worker. Tests inject `copy_id_fn` as a
        recorder; the real suspend path requires a genuine TTY, so it's
        never exercised headlessly. The Fleet worker that calls this
        (`FleetPanel._keydist_flow`) already resolved the `entries` list
        in table order and checked the `_task_inflight`/`_push_inflight`
        gate before calling — this method just runs the copy (injected or
        default) and hands the results straight to the Fleet panel's
        resume-flow renderer.
        """
        if self.copy_id_fn is not None:
            results = self.copy_id_fn(entries)
        else:
            results = self._default_copy_id(entries)
        self.query_one("#fleet", FleetPanel)._apply_copy_id_results(results)

    def _default_copy_id(self, entries: list[HostEntry]) -> list[tuple[str, int]]:
        """Real (uninjected) copy-id path: suspend the TUI, run
        `manage-hosts.sh --copy-id --name <host>` once per entry IN ORDER
        (sequential, not parallel — each may need interactive password
        entry at the terminal), printing a banner between hosts so the
        user can tell which host's prompt they're looking at.
        """
        root = find_repo_root() or Path.cwd()
        results: list[tuple[str, int]] = []
        with self.suspend():
            n = len(entries)
            for i, entry in enumerate(entries, start=1):
                print(f"=== {entry.name} ({i}/{n}) ===")
                rc = subprocess.run(copy_id_command(root, entry.name)).returncode
                results.append((entry.name, rc))
        return results

    def launch_task(
        self,
        command: list[str],
        *,
        needs_sudo: bool = False,
        log_to: Callable[[str], None] | None = None,
        on_result: Callable[[TaskResult], None] | None = None,
        on_done: Callable[[], None] | None = None,
    ) -> None:
        # A running push dashboard (MultiRunner) refuses local tasks too —
        # checked FIRST so the toast names the actual blocker instead of
        # the generic "task running".
        if self._push_inflight:
            self.notify("push running", severity="warning")
            return
        # _task_inflight covers the gate window (status check + modal)
        # where self._runner.busy is still False — without it a second
        # launch_task() call (e.g. a double "r" press) slips past the busy
        # check and stacks a second sudo modal.
        if self._task_inflight or self._runner.busy:
            self.notify("task running", severity="warning")
            return
        self._task_inflight = True
        # Isolated in its own worker group ("task"), distinct from
        # action_refresh's "summary" group — see the comment there. Not
        # exclusive: only launch_task's own busy/_task_inflight check
        # single-flights this group; a stray group-wide cancel must never
        # be able to reach the running make via this worker.
        self.run_worker(
            self._task_flow(command, needs_sudo, log_to, on_result, on_done),
            exclusive=False, group="task",
        )

    async def _sudo_gate(self, needs_sudo: bool, command: list[str] | None = None) -> bool:
        """Returns True when it's OK to proceed, False when the caller
        should abort (already notified). `command` is only used to name the
        exact command in the timestamp_timeout=0 fallback message — sequences
        never pass needs_sudo=True in this phase, so they never need it.
        """
        context = self.summary.context if self.summary else detect_context()
        if not (needs_sudo and context.os == "linux"):
            return True
        status = await asyncio.to_thread(self.sudo_status_fn)
        if status == "no_sudo":
            self.notify("sudo not available", severity="error")
            return False
        if status == "needs_password":
            ok = await self.push_screen_wait(SudoModal(validator=self.sudo_validate_fn))
            if not ok:
                self.notify("cancelled", severity="warning")
                return False
            status = await asyncio.to_thread(self.sudo_status_fn)
            if status == "needs_password":
                # timestamp_timeout=0 sudoers: the validated password
                # doesn't cache, so the command still can't run
                # unattended. Fall back to naming the exact command for
                # the user to run themselves in a terminal (the full
                # app-suspend flow is deferred to the phase that needs
                # it).
                joined = " ".join(command) if command else ""
                self.notify(
                    "sudo timestamp caching disabled — run in a "
                    f"terminal: {joined}",
                    severity="error", markup=False,
                )
                return False
        return True

    def _resolve_log(self, log_to: Callable[[str], None] | None) -> Callable[[str], None]:
        if log_to is not None:
            return log_to
        return self.query_one("#provision", ProvisionPanel).append_log

    def _maybe_notify(self, result: TaskResult) -> None:
        # cancelled: never notify (the in-app "cancelled" toast already
        # covers it, and the user just triggered the cancel themselves —
        # an OS toast on top would be noise, not news).
        if result.cancelled:
            return
        summary = _command_summary(result.command)
        if result.returncode != 0:
            # failure: ALWAYS notify, regardless of duration.
            self.notifier("workstation", f"{summary} — failed (rc={result.returncode})")
            return
        # success: only worth a toast if it ran long enough that the user
        # plausibly tabbed away.
        if result.duration_secs >= self.notify_threshold_secs:
            self.notifier(
                "workstation",
                f"{summary} — done (rc=0, {round(result.duration_secs)}s)",
            )

    def _history_entry(
        self,
        kind: str,
        command: list[str],
        result: TaskResult,
        needs_sudo: bool,
        started_at: datetime,
    ) -> HistoryEntry:
        """Build a `task`/`sequence` `HistoryEntry` from a settled
        `TaskResult` (push/keydist entries are assembled inline at their
        own call sites — they have no single `TaskResult` to draw from).
        """
        return HistoryEntry(
            id=new_entry_id(started_at),
            started_at=started_at.isoformat(),
            kind=kind,
            command=command,
            summary=_command_summary(command),
            returncode=result.returncode,
            duration_secs=result.duration_secs,
            cancelled=result.cancelled,
            outcome=outcome_for(result.returncode, result.cancelled),
            needs_sudo=needs_sudo,
        )

    def record_history(self, entry: HistoryEntry, log_lines: list[str]) -> None:
        """Fire-and-forget history write (spec §3) — never blocks the
        caller and never raises. `HistoryStore.record` does file I/O, so
        it's pushed to a thread via a background task when an event loop
        is running (the normal case: every call site is inside a worker);
        with no running loop (e.g. a plain unit test calling this
        directly) it just runs synchronously instead. Either way, a
        `False` result (F3: e.g. an unwritable/broken cache directory)
        surfaces ONE warning toast per session via
        `_warn_history_write_failed`, instead of the record silently
        vanishing with no visible sign anything went wrong.
        """
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if loop is None:
            try:
                ok = self.history_store.record(entry, list(log_lines))
            except Exception:
                ok = False
            if not ok:
                self._warn_history_write_failed()
            return
        try:
            task = asyncio.create_task(
                asyncio.to_thread(self.history_store.record, entry, list(log_lines))
            )
        except Exception:
            return
        task.add_done_callback(self._on_history_recorded)

    def _on_history_recorded(self, task: "asyncio.Task[bool]") -> None:
        """Done-callback for `record_history`'s background write —
        surfaces the one-warning-per-session toast on a `False`/raised
        result (F3). Never itself raises: a cancelled task or one whose
        `to_thread` call somehow raised both count as "not recorded".
        """
        try:
            ok = task.result()
        except Exception:
            ok = False
        if not ok:
            self._warn_history_write_failed()

    def _warn_history_write_failed(self) -> None:
        if self._history_warned:
            return
        self._history_warned = True
        self.notify(
            "history write failed — see ~/.cache/workstation-tui/history",
            severity="warning", markup=False,
        )

    def rerun_history_entry(self, entry: HistoryEntry) -> bool:
        """Re-run a history entry — the SINGLE entry point for both
        `HistoryScreen`'s "r" binding and the palette's `re-run: <summary>`
        hit (`palette.py`'s `_rerun` callback calls this directly), so
        every caller confirms through the exact same `ConfirmModal` before
        anything launches (Finding F1: the palette used to call
        `launch_task` straight through with no confirm at all — a
        `re-run:` hit for a Fleet host remove or a `chezmoi apply` ran
        immediately on Enter).

        Only `task`/`sequence` entries with a recorded `command` are
        re-runnable from here (`push`/`keydist` runs have no single
        command — see `_history_entry`/push_screen.py/fleet.py, which all
        record `command=None` for those kinds); anything else degrades to
        a toast pointing at the panel that actually owns that kind of
        re-run — no confirm shown, nothing routed. Returns True once the
        request has been ROUTED to a background confirm+launch worker
        (group "history-confirm") — the confirm may still be declined, and
        the eventual `launch_task` call may still itself refuse (task/push
        already running) with its own toast; either is fine, since the
        caller (HistoryScreen) only uses the return value to decide
        whether to dismiss itself, and dismissing once the request has
        been routed is correct regardless of how the worker's confirm
        resolves.

        `push_screen_wait` needs a running screen stack and must be
        awaited, so the confirm+launch pair runs in its own worker rather
        than blocking this (synchronous) method — `run_worker` returns
        immediately, matching the "routed, not necessarily run" contract
        above.
        """
        if entry.kind in ("task", "sequence") and entry.command is not None:
            self.run_worker(
                self._rerun_confirm_flow(entry),
                exclusive=False, group="history-confirm",
            )
            return True
        self.notify("re-run from the Fleet panel", severity="warning")
        return False

    async def _rerun_confirm_flow(self, entry: HistoryEntry) -> None:
        """`ConfirmModal` -> `launch_task`, for a `rerun_history_entry`
        request already known re-runnable (`command is not None`). Body
        is two lines — `re-run <summary>?` then the joined argv — so an
        ambiguous summary (add/remove both summarize to the same
        `manage-hosts.sh` invocation, apply-one/apply-all both to
        `chezmoi apply`) still shows the user the EXACT command about to
        run; `ConfirmModal` is `markup=False`, so a hostile argv token
        can't inject markup into either line.
        """
        assert entry.command is not None  # guarded by the caller above
        body = f"re-run {entry.summary}?\n" + " ".join(entry.command)
        ok = await self.push_screen_wait(ConfirmModal(body))
        if not ok:
            return
        self.launch_task(entry.command, needs_sudo=entry.needs_sudo)

    async def _task_flow(
        self,
        command: list[str],
        needs_sudo: bool,
        log_to: Callable[[str], None] | None = None,
        on_result: Callable[[TaskResult], None] | None = None,
        on_done: Callable[[], None] | None = None,
    ) -> None:
        try:
            if not await self._sudo_gate(needs_sudo, command):
                return
            started_at = datetime.now(UTC)
            # Tee the resolved log AFTER resolution so the "$ cmd" echo
            # written through it just below is captured too, not just the
            # runner's own streamed lines.
            log, captured = _tee_log(self._resolve_log(log_to))
            log("$ " + " ".join(command))
            keepalive: asyncio.Task | None = None
            if needs_sudo:
                async def _keepalive() -> None:
                    while True:
                        await asyncio.sleep(self.sudo_keepalive_secs)
                        await asyncio.to_thread(self.sudo_status_fn)
                keepalive = asyncio.create_task(_keepalive())
            try:
                try:
                    result = await self._runner.run(command, log)
                except TaskBusyError:
                    self.notify("task running", severity="warning")
                    return
                except Exception as exc:  # surface, never die silently in the worker
                    # exc text is arbitrary (e.g. a path like "[/etc/foo]") — markup=False
                    # keeps Textual's notify() from parsing it as markup and crashing
                    # (same MarkupError class _show_header_error's escape() guards against).
                    self.notify(f"task failed: {type(exc).__name__}: {exc}",
                                severity="error", markup=False)
                    return
            finally:
                if keepalive is not None:
                    keepalive.cancel()
            # A TaskResult exists now — including the cancelled case — so
            # this is the one place a "task" entry is recorded. The
            # sudo-gate refusal, TaskBusyError, and spawn-exception
            # branches above all `return` before this point, deliberately
            # NOT recording anything (no TaskResult was ever produced).
            self.record_history(
                self._history_entry("task", command, result, needs_sudo, started_at),
                captured,
            )
            # Minimal, backward-compatible addition (optional, keyword-only,
            # defaults to None — every pre-existing call site is unchanged):
            # hands the TaskResult (incl. returncode) to the caller before
            # on_done, the same "before on_done" ordering on_done itself
            # already has relative to action_refresh() below. The health
            # panel is the first consumer — it needs the rc to record a
            # CheckResult, which neither on_done's zero-arg signature nor
            # the streamed log lines alone can give it.
            if on_result is not None:
                on_result(result)
            if result.cancelled:
                self.notify("cancelled", severity="warning")
            else:
                severity = "error" if result.returncode != 0 else "information"
                self.notify(f"done (rc={result.returncode})", severity=severity)
            self._maybe_notify(result)
            self.action_refresh()
            if on_done is not None:
                on_done()
        finally:
            self._task_inflight = False

    def run_task_sequence(
        self,
        commands: list[list[str]],
        *,
        log_to: Callable[[str], None] | None = None,
        on_done: Callable[[], None] | None = None,
    ) -> None:
        # Same push-inflight refusal as launch_task — checked first so the
        # toast names the actual blocker.
        if self._push_inflight:
            self.notify("push running", severity="warning")
            return
        # Same busy/_task_inflight refusal machinery as launch_task —
        # _task_inflight is held for the WHOLE sequence, not per-command, so
        # a second launch_task()/run_task_sequence() call can't interleave
        # with an in-progress sequence.
        if self._task_inflight or self._runner.busy:
            self.notify("task running", severity="warning")
            return
        self._task_inflight = True
        self.run_worker(
            self._sequence_flow(commands, log_to, on_done),
            exclusive=False, group="task",
        )

    async def _sequence_flow(
        self,
        commands: list[list[str]],
        log_to: Callable[[str], None] | None,
        on_done: Callable[[], None] | None,
    ) -> None:
        try:
            # Sequences are never sudo in this phase — gate with
            # needs_sudo=False, which returns True immediately.
            if not await self._sudo_gate(False):
                return
            log_target = self._resolve_log(log_to)
            # Tracks whether the loop ran every command to completion
            # (never cancelled, never a non-zero rc) — only that case earns
            # the "done" toast below; the cancelled/aborted branches already
            # notify their own outcome.
            completed = True
            # Sequence notification policy (spec §4): ONE desktop notify per
            # sequence, not one per command — a marked-tool run of N tools
            # firing N toasts would be spam, not signal. We track only the
            # LAST TaskResult seen (whichever command the loop stopped on,
            # by completion or by break) and hand just that one to
            # _maybe_notify after the loop: a completed run notifies on the
            # last command's own success/duration; an aborted run notifies
            # the failing command's rc (_maybe_notify's normal failure
            # path); a cancelled run's last result has cancelled=True, which
            # _maybe_notify already no-ops on — so "cancelled → no notify"
            # falls out of the shared helper for free, no extra branch here.
            last_result: TaskResult | None = None
            for command in commands:
                # A fresh tee per command — its own capped `captured` list
                # feeds that command's own "sequence" history entry, same
                # "wrap after resolution" ordering as _task_flow so the
                # per-command "$ cmd" echo is captured too.
                started_at = datetime.now(UTC)
                log, captured = _tee_log(log_target)
                log("$ " + " ".join(command))
                try:
                    result = await self._runner.run(command, log)
                except TaskBusyError:
                    self.notify("task running", severity="warning")
                    return
                except Exception as exc:  # surface, never die silently in the worker
                    self.notify(f"task failed: {type(exc).__name__}: {exc}",
                                severity="error", markup=False)
                    return
                # As in _task_flow: recorded only here, where a TaskResult
                # actually exists — the TaskBusyError/exception branches
                # above return before this, recording nothing for that
                # attempt (earlier commands' entries, if any, already
                # landed on their own iterations).
                self.record_history(
                    self._history_entry("sequence", command, result, False, started_at),
                    captured,
                )
                last_result = result
                if result.cancelled:
                    self.notify("cancelled", severity="warning")
                    completed = False
                    break
                if result.returncode != 0:
                    self.notify(f"sequence aborted (rc={result.returncode})",
                                severity="error", markup=False)
                    completed = False
                    break
            if completed:
                self.notify("done", severity="information")
            if last_result is not None:
                self._maybe_notify(last_result)
            self.action_refresh()
            if on_done is not None:
                on_done()
        finally:
            self._task_inflight = False

    def cancel_task(self) -> None:
        self._runner.cancel()
