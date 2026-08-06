"""WorkstationApp — the sidebar-rail shell (spec layout A)."""

import asyncio
from typing import Callable, Literal

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.markup import escape
from textual.widgets import ContentSwitcher, Static

from workstation_tui.app.panels.dashboard import DashboardPanel
from workstation_tui.app.panels.placeholder import PlaceholderPanel
from workstation_tui.app.panels.provision import ProvisionPanel
from workstation_tui.app.theme import M, MOCHA_CSS, kb
from workstation_tui.app.widgets.sudo_modal import SudoModal
from workstation_tui.core.context import detect_context
from workstation_tui.core.makeiface import make_command, read_inventory
from workstation_tui.core.models import Summary, ToolStatus
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
    ) -> None:
        super().__init__()
        self.summary_provider = summary_provider or _default_provider
        self.summary: Summary | None = None
        self._runner = runner or Runner()
        self.tools_provider = tools_provider or self._default_tools
        self.sudo_status_fn = sudo_status_fn or sudo_status
        self.sudo_validate_fn = sudo_validate_fn or sudo_validate
        self.sudo_keepalive_secs = 60.0
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
                yield PlaceholderPanel("Dotfiles", id="dotfiles")
                yield PlaceholderPanel("Fleet", id="fleet")
                yield PlaceholderPanel("Health", id="health")
        yield Static(
            kb(("1-5", "Panels"), ("g", "Refresh"), ("q", "Quit")),
            id="key-bar", markup=True,
        )

    def on_mount(self) -> None:
        self._mark_active("dashboard")
        self.action_refresh()

    def switch_panel(self, panel_id: str) -> None:
        self.query_one("#content", ContentSwitcher).current = panel_id
        self._mark_active(panel_id)

    def action_switch(self, panel_id: str) -> None:
        self.switch_panel(panel_id)

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
        self.call_from_thread(self._apply_summary, summary)
        tools, errors = self.tools_provider()
        self.call_from_thread(self._apply_tools, tools, errors)

    def _default_tools(self) -> tuple[list[ToolStatus], list[str]]:
        root = find_repo_root()
        if root is None:
            return [], ["workstation repo not found"]
        mode = self.summary.context.mode if self.summary else detect_context().mode
        rows, errs = read_inventory(root, mode)
        return scan(DEFAULT_STAMP_DIR, rows), errs

    def _apply_tools(self, tools: list[ToolStatus], errors: list[str]) -> None:
        self.query_one("#provision", ProvisionPanel).set_tools(tools, errors)

    def _apply_summary(self, summary: Summary) -> None:
        self.summary = summary
        c = summary.context
        wsl = " · WSL" if c.is_wsl else ""
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] "
            f"[{M['subtext0']}]— {c.os} · group={c.group or '?'} · "
            f"mode={c.mode}{wsl}[/]"
        )
        self.query_one("#dashboard", DashboardPanel).update_summary(summary)
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

    def launch_task(self, command: list[str], *, needs_sudo: bool = False) -> None:
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
            self._task_flow(command, needs_sudo), exclusive=False, group="task"
        )

    async def _task_flow(self, command: list[str], needs_sudo: bool) -> None:
        try:
            context = self.summary.context if self.summary else detect_context()
            if needs_sudo and context.os == "linux":
                status = await asyncio.to_thread(self.sudo_status_fn)
                if status == "no_sudo":
                    self.notify("sudo not available", severity="error")
                    return
                if status == "needs_password":
                    ok = await self.push_screen_wait(
                        SudoModal(validator=self.sudo_validate_fn)
                    )
                    if not ok:
                        self.notify("cancelled", severity="warning")
                        return
                    status = await asyncio.to_thread(self.sudo_status_fn)
                    if status == "needs_password":
                        # timestamp_timeout=0 sudoers: the validated password
                        # doesn't cache, so the command still can't run
                        # unattended. Fall back to naming the exact command for
                        # the user to run themselves in a terminal (the full
                        # app-suspend flow is deferred to the phase that needs
                        # it).
                        joined = " ".join(command)
                        self.notify(
                            "sudo timestamp caching disabled — run in a "
                            f"terminal: {joined}",
                            severity="error", markup=False,
                        )
                        return
            panel = self.query_one("#provision", ProvisionPanel)
            panel.append_log("$ " + " ".join(command))
            keepalive: asyncio.Task | None = None
            if needs_sudo:
                async def _keepalive() -> None:
                    while True:
                        await asyncio.sleep(self.sudo_keepalive_secs)
                        await asyncio.to_thread(self.sudo_status_fn)
                keepalive = asyncio.create_task(_keepalive())
            try:
                try:
                    result = await self._runner.run(command, panel.append_log)
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
            if result.cancelled:
                self.notify("cancelled", severity="warning")
            else:
                severity = "error" if result.returncode != 0 else "information"
                self.notify(f"done (rc={result.returncode})", severity=severity)
            self.action_refresh()
        finally:
            self._task_inflight = False

    def cancel_task(self) -> None:
        self._runner.cancel()
