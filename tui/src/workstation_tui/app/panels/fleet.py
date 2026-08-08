"""Fleet panel: host table + reachability probes + ssh/push/add/edit/remove.

All fleet data flows through app-owned providers (hosts_provider/
probe_all_fn/ssh_fn) and the app's launch_task/run_task_sequence
machinery — this panel never shells out to manage-hosts.sh, update-hosts.sh,
or ssh itself (same provider-only discipline as dotfiles.py/provision.py).

Host name/address/user/group are USER-TYPED via HostFormModal — the
markup-crash class dotfiles.py first called out for pending paths is live
here too, so every DataTable cell is wrapped in Text(...) (the probe glyph
via theme.icon() already returns one).
"""

from pathlib import Path

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, RichLog, Static

from workstation_tui.app.theme import HOST_ICONS, M, SETUP_ICONS, icon
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.host_form import HostFormModal
from workstation_tui.core.fleet import (
    manage_hosts_add_command,
    manage_hosts_remove_command,
    push_command,
)
from workstation_tui.core.models import HostEntry
from workstation_tui.repo import find_repo_root

FLEET_CSS = f"""
FleetPanel {{
    padding: 0 1;
}}
#fleet-table {{
    height: 1fr;
}}
#fleet-log {{
    height: 12;
    background: {M['mantle']};
    border-top: solid {M['surface1']};
}}
"""


class FleetPanel(Static):
    DEFAULT_CSS = FLEET_CSS

    BINDINGS = [
        ("s", "ssh_selected", "SSH"),
        ("p", "push_selected", "Push"),
        ("P", "push_all", "Push all"),
        ("a", "add_host", "Add"),
        ("e", "edit_host", "Edit"),
        ("x", "remove_host", "Remove"),
    ]

    #: Same rationale as ProvisionPanel/DotfilesPanel.MAX_LOG_LINES — a long
    #: session shouldn't let the log grow unbounded.
    MAX_LOG_LINES = 5000

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)
        self.hosts: list[HostEntry] = []
        self.errors: list[str] = []
        # name -> (reachability, setup) e.g. ("up", "setup") / ("down",
        # None); a host absent from this dict (not yet probed) renders
        # "unknown"/"unknown" via HOST_ICONS/SETUP_ICONS.
        self.probe_states: dict[str, tuple[str, str | None]] = {}
        self.log_lines: list[str] = []
        self.can_focus = True

    def compose(self) -> ComposeResult:
        with Vertical():
            yield DataTable(id="fleet-table", cursor_type="row",
                            zebra_stripes=True)
            yield RichLog(id="fleet-log", markup=False, wrap=False,
                          max_lines=self.MAX_LOG_LINES)

    def on_mount(self) -> None:
        table = self.query_one("#fleet-table", DataTable)
        table.add_column("net", key="state", width=3)
        table.add_column("repo", key="setup", width=4)
        table.add_column("name", key="name", width=18)
        table.add_column("address", key="address", width=16)
        table.add_column("user", key="user", width=12)
        table.add_column("group", key="group", width=14)

    # -- rendering ------------------------------------------------------

    def _render_rows(self) -> None:
        table = self.query_one("#fleet-table", DataTable)
        table.clear()
        for entry in self.hosts:
            state, setup_state = self.probe_states.get(entry.name, ("unknown", None))
            # DataTable markup-parses str cells (default_cell_formatter) —
            # Text(...) is the markup=False of tables. name/address/user/
            # group are USER-TYPED via the add/edit form, not our own
            # controlled markup, so they must render as literal text
            # (icon() already returns a Text).
            table.add_row(
                icon(state, HOST_ICONS),
                icon(setup_state or "unknown", SETUP_ICONS),
                Text(entry.name), Text(entry.address),
                Text(entry.user), Text(entry.group), key=entry.name,
            )

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        if len(self.log_lines) > self.MAX_LOG_LINES:
            del self.log_lines[: -self.MAX_LOG_LINES]
        self.query_one("#fleet-log", RichLog).write(line)

    def selected_entry(self) -> HostEntry | None:
        table = self.query_one("#fleet-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        name = str(row_key.value) if row_key and row_key.value else None
        if name is None:
            return None
        return next((e for e in self.hosts if e.name == name), None)

    def _os_name(self) -> str:
        summary = self.app.summary  # type: ignore[attr-defined]
        return summary.context.os if summary else "linux"

    # -- refresh + probing (called by the app on entry/refresh cycles) ----

    def refresh_panel(self) -> None:
        self.run_worker(
            self._refresh_worker, thread=True, exclusive=True,
            group="fleet-refresh",
        )

    def _refresh_worker(self) -> None:
        hosts, errors = self.app.hosts_provider()  # type: ignore[attr-defined]
        self.app.call_from_thread(  # type: ignore[attr-defined]
            self._apply_hosts, hosts, errors
        )

    @staticmethod
    def _dedupe_hosts(hosts: list[HostEntry]) -> tuple[list[HostEntry], list[str]]:
        """First-wins dedupe by name.

        `_render_rows` keys each DataTable row by `entry.name` — a
        hand-edited hosts.conf with a repeated name would otherwise crash
        `add_row` with a DuplicateKey error before any panel data renders
        at all. Returns the deduped list plus the names that were dropped
        (for a warning log line), so a malformed file degrades to "some
        rows visible + a warning" instead of a blank crashed panel.
        """
        seen: set[str] = set()
        deduped: list[HostEntry] = []
        dupes: list[str] = []
        for entry in hosts:
            if entry.name in seen:
                dupes.append(entry.name)
                continue
            seen.add(entry.name)
            deduped.append(entry)
        return deduped, dupes

    def _apply_hosts(self, hosts: list[HostEntry], errors: list[str]) -> None:
        hosts, dupes = self._dedupe_hosts(hosts)
        self.hosts = hosts
        self.errors = errors
        self._render_rows()
        for err in errors:
            self.append_log(f"warning  {err}")
        for name in dupes:
            self.append_log(
                f"warning  duplicate host name {name!r} in hosts.conf — "
                "keeping the first row, dropping the rest"
            )
        if self.hosts:
            # On-loop async worker (not thread) — probe_all_fn is a
            # coroutine, so no call_from_thread hop is needed to apply
            # results back onto widgets. Pass the bound METHOD, not an
            # already-invoked coroutine: with exclusive=True, a group
            # cancel landing before this worker's first tick (every
            # mutation triggers refresh_panel twice — via action_refresh
            # and on_done) would otherwise tear down a pre-built coroutine
            # that was never awaited, logging "coroutine was never
            # awaited" at GC time. A callable lets Textual construct the
            # coroutine lazily, so a cancelled-before-start worker never
            # constructs one at all.
            self.run_worker(self._probe_worker, exclusive=True, group="probes")

    async def _probe_worker(self) -> None:
        try:
            # Finding 4 (ssh probe storm): stage 2 (the ssh setup probe) is
            # only worth its cost while a human is actually looking at the
            # Fleet table. `is_on_screen` is the same compositor-backed
            # "actually visible right now" check Dashboard's Card already
            # relies on (see dashboard.py's Card.action_open/action_move
            # comment) — every refresh from ANY panel, including Dashboard,
            # otherwise escalated to up-to-9 concurrent ssh connections.
            states = await self.app.probe_all_fn(  # type: ignore[attr-defined]
                self.hosts, include_setup=self.is_on_screen
            )
        except Exception as exc:  # surface, never crash the worker
            self.append_log(f"probe failed: {type(exc).__name__}: {exc}")
            return
        self._merge_probe_states(states)
        self._render_rows()

    def _merge_probe_states(
        self, new_states: dict[str, tuple[str, str | None]]
    ) -> None:
        """Apply a probe cycle's results without regressing a previously
        known setup state to unknown.

        Finding 4 CRITICAL detail: when the Fleet panel isn't on screen,
        `probe_all_fn` runs with `include_setup=False` — reachable hosts
        come back `("up", None)`, where `None` means "stage 2 didn't run
        this cycle", not "unknown/never probed". A plain
        `self.probe_states.update(new_states)` would blow away a setup
        glyph (✓/○/✗) a PRIOR visible-panel cycle already established,
        flickering it back to the dim unknown dash on every off-screen
        refresh even though nothing about the host's setup state actually
        changed. So: for a host that's still "up" with no fresh setup
        result, keep whatever setup state is already on record. A host that
        genuinely went down is NOT covered by this carry-forward — its
        `state` is "down", not "up", so the dash it renders reflects reality
        (unreachable), not a stale setup memory.
        """
        for name, (state, setup_state) in new_states.items():
            if state == "up" and setup_state is None:
                _, prior_setup = self.probe_states.get(name, ("unknown", None))
                setup_state = prior_setup
            self.probe_states[name] = (state, setup_state)

    # -- actions delegate to the app (which owns runner + providers) -----

    async def _confirm_and_run(self, message: str, command: list[str]) -> None:
        ok = await self.app.push_screen_wait(ConfirmModal(message))  # type: ignore[attr-defined]
        if not ok:
            return
        self.app.launch_task(  # type: ignore[attr-defined]
            command, log_to=self.append_log, on_done=self.refresh_panel,
        )

    def _name_collision(self, old_name: str | None, new_name: str) -> bool:
        """True when `new_name` collides with a DIFFERENT existing host.

        Pure helper (touches only `self.hosts`) so it's directly
        unit-testable and reused by both `_add_flow` and `_edit_flow`.
        `old_name` is the name of the host being edited (None for add) —
        renaming a host to its own unchanged name is never a collision,
        which is why this isn't just `new_name in {e.name for e in
        self.hosts}`.

        Finding 1: manage-hosts.sh's `--add` treats "name already exists"
        as an rc-0 SKIP (load-bearing for bootstrap re-runs — that script
        behavior must not change). `_edit_flow` runs [remove old, add
        new]: renaming alpha->beta when beta already exists would remove
        alpha, then silently skip the add — alpha is gone with no error.
        This guard runs BEFORE launching either flow so that case (and the
        analogous "add a name that already exists" case) surfaces an error
        instead of silently losing/no-opping.
        """
        if new_name == old_name:
            return False
        return new_name in {e.name for e in self.hosts}

    async def _add_flow(self) -> None:
        entry = await self.app.push_screen_wait(HostFormModal())  # type: ignore[attr-defined]
        if entry is None:
            return
        if self._name_collision(None, entry.name):
            self.app.notify(  # type: ignore[attr-defined]
                f"host {entry.name} already exists",
                severity="error", markup=False,
            )
            return
        root = find_repo_root() or Path.cwd()
        self.app.launch_task(  # type: ignore[attr-defined]
            manage_hosts_add_command(root, entry, os_name=self._os_name()),
            log_to=self.append_log, on_done=self.refresh_panel,
        )

    async def _edit_flow(self, old: HostEntry) -> None:
        new_entry = await self.app.push_screen_wait(  # type: ignore[attr-defined]
            HostFormModal(initial=old)
        )
        if new_entry is None:
            return
        if self._name_collision(old.name, new_entry.name):
            self.app.notify(  # type: ignore[attr-defined]
                f"host {new_entry.name} already exists",
                severity="error", markup=False,
            )
            return
        root = find_repo_root() or Path.cwd()
        os_name = self._os_name()
        self.app.run_task_sequence(  # type: ignore[attr-defined]
            [
                manage_hosts_remove_command(root, old.name, os_name=os_name),
                manage_hosts_add_command(root, new_entry, os_name=os_name),
            ],
            log_to=self.append_log, on_done=self.refresh_panel,
        )

    def _linux_only_gate(self) -> bool:
        """True when a push/ssh action may proceed.

        Finding 3: push (update-hosts.sh) and ssh are Linux-side tools —
        a Windows host manages the fleet's hosts.conf but has neither. Mirrors
        `_os_name()`'s "no summary yet -> treat as linux" fallback so an
        action pressed before the first refresh completes isn't spuriously
        blocked.
        """
        if self._os_name() != "linux":
            self.app.notify(  # type: ignore[attr-defined]
                "not available here: pushes/ssh are Linux-side "
                "(Windows manages hosts only)",
                severity="warning", markup=False,
            )
            return False
        return True

    def action_ssh_selected(self) -> None:
        if not self._linux_only_gate():
            return
        entry = self.selected_entry()
        if entry is None:
            self.app.notify("no host selected", severity="warning")  # type: ignore[attr-defined]
            return
        self.app.ssh_to(entry)  # type: ignore[attr-defined]

    def action_push_selected(self) -> None:
        if not self._linux_only_gate():
            return
        entry = self.selected_entry()
        if entry is None:
            self.app.notify("no host selected", severity="warning")  # type: ignore[attr-defined]
            return
        root = find_repo_root() or Path.cwd()
        self.run_worker(
            self._confirm_and_run(
                f"push {entry.name}?", push_command(root, entry.name)
            ),
            exclusive=False, group="fleet-confirm",
        )

    def action_push_all(self) -> None:
        if not self._linux_only_gate():
            return
        if not self.hosts:
            self.app.notify("no hosts", severity="information")  # type: ignore[attr-defined]
            return
        root = find_repo_root() or Path.cwd()
        self.run_worker(
            self._confirm_and_run("push ALL hosts?", push_command(root, None)),
            exclusive=False, group="fleet-confirm",
        )

    def action_add_host(self) -> None:
        self.run_worker(self._add_flow(), exclusive=False, group="fleet-confirm")

    def action_edit_host(self) -> None:
        entry = self.selected_entry()
        if entry is None:
            self.app.notify("no host selected", severity="warning")  # type: ignore[attr-defined]
            return
        self.run_worker(
            self._edit_flow(entry), exclusive=False, group="fleet-confirm"
        )

    def action_remove_host(self) -> None:
        entry = self.selected_entry()
        if entry is None:
            self.app.notify("no host selected", severity="warning")  # type: ignore[attr-defined]
            return
        root = find_repo_root() or Path.cwd()
        self.run_worker(
            self._confirm_and_run(
                f"remove {entry.name}?",
                manage_hosts_remove_command(
                    root, entry.name, os_name=self._os_name()
                ),
            ),
            exclusive=False, group="fleet-confirm",
        )
