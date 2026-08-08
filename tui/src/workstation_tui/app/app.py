"""WorkstationApp — the sidebar-rail shell (spec layout A)."""

import asyncio
import subprocess
from pathlib import Path
from typing import Any, Callable, Coroutine, Literal

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.css.query import NoMatches
from textual.markup import escape
from textual.widgets import ContentSwitcher, Static

from workstation_tui.app.panels.dashboard import DashboardPanel
from workstation_tui.app.panels.dotfiles import DotfilesPanel
from workstation_tui.app.panels.fleet import FleetPanel
from workstation_tui.app.panels.health import HealthPanel
from workstation_tui.app.panels.provision import ProvisionPanel
from workstation_tui.app.theme import M, MOCHA_CSS, kb
from workstation_tui.app.widgets.help_screen import HelpScreen
from workstation_tui.app.widgets.sudo_modal import SudoModal
from workstation_tui.core.chezmoi import read_status, target_diff
from workstation_tui.core.context import detect_context
from workstation_tui.core.fleet import probe_all
from workstation_tui.core.gitstate import read_git_state
from workstation_tui.core.health import (
    build_health_rollup,
    load_cache,
    read_services,
    read_wsl_interop,
)
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
        ("R", "Provision"), ("x", "Cancel"),
    ],
    "dotfiles": [("a", "Apply"), ("U", "Update"), ("A", "Re-add"), ("d", "Diff")],
    "fleet": [
        ("s", "SSH"), ("p", "Push"), ("P", "Push all"),
        ("a", "Add"), ("e", "Edit"), ("x", "Remove"),
    ],
    "health": [("enter", "Run"), ("R", "Run all"), ("o", "Log")],
}

#: Bindings shown in the footer regardless of the active panel.
GLOBAL_KEYS: list[tuple[str, str]] = [
    ("1-5", "Panels"), ("ctrl+←/→", "Cycle"), ("g", "Refresh"),
    ("q", "Quit"), ("?", "Help"),
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
        health_cache_path: Path | None = None,
        services_reader: Callable[[], dict[str, str]] | None = None,
        interop_reader: Callable[[], str] | None = None,
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
        # Health panel providers (Phase 6 Task 2) — same injectable-default
        # convention as the providers above; health_cache_path defaults to
        # the standard XDG-ish per-user cache location (this is the only
        # file the TUI itself writes — checks otherwise run unprivileged).
        self.health_cache_path = (
            health_cache_path or Path.home() / ".cache/workstation-tui/health.json"
        )
        self.services_reader = services_reader or read_services
        self.interop_reader = interop_reader or read_wsl_interop
        # Guards the sudo-gate window (status check + modal) — the runner
        # isn't busy yet during that window, so a second launch_task() call
        # (e.g. a double "r" press) would otherwise slip past the
        # `self._runner.busy` check and stack a second modal. Set True
        # before the task worker starts, cleared in _task_flow's finally.
        self._task_inflight = False

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
        self.action_refresh()
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

    def action_help(self) -> None:
        self.push_screen(HelpScreen())

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

    def _apply_summary(self, summary: Summary, rollup: HealthRollup) -> None:
        self.summary = summary
        c = summary.context
        wsl = " · WSL" if c.is_wsl else ""
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] "
            f"[{M['subtext0']}]— {c.os} · group={c.group or '?'} · "
            f"mode={c.mode}{wsl}[/]"
        )
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

    def run_make_goals(self, goals: list[str], *, user_kind: bool) -> None:
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
        root = find_repo_root()
        if root is None:
            self.notify("workstation repo not found", severity="error")
            return
        mode = self.summary.context.mode
        cmd = make_command(root, goals, mode)
        # _task_flow gates this on a valid sudo timestamp before launching.
        needs_sudo = mode == "dev" and not user_kind
        self.launch_task(cmd, needs_sudo=needs_sudo)

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

    def launch_task(
        self,
        command: list[str],
        *,
        needs_sudo: bool = False,
        log_to: Callable[[str], None] | None = None,
        on_result: Callable[[TaskResult], None] | None = None,
        on_done: Callable[[], None] | None = None,
    ) -> None:
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
            log = self._resolve_log(log_to)
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
            log = self._resolve_log(log_to)
            # Tracks whether the loop ran every command to completion
            # (never cancelled, never a non-zero rc) — only that case earns
            # the "done" toast below; the cancelled/aborted branches already
            # notify their own outcome.
            completed = True
            for command in commands:
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
            self.action_refresh()
            if on_done is not None:
                on_done()
        finally:
            self._task_inflight = False

    def cancel_task(self) -> None:
        self._runner.cancel()
