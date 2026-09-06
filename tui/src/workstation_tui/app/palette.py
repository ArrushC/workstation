"""Command palette providers (Phase C Task 6, spec §1).

Three `textual.command.Provider` subclasses feed Textual's built-in
`ctrl+p` command palette (already active — `App.ENABLE_COMMAND_PALETTE`
defaults True and `COMMAND_PALETTE_BINDING` is "ctrl+p"; `app.py` wires
them in via `WorkstationApp.COMMANDS`):

- `ActionsProvider` — every whole-app/whole-panel action (panel switches,
  refresh/watch/history/help/quit, and the panels' own "do it to
  everything" actions: full provision, apply all pending, push all
  hosts, run all health checks, distribute keys). Fixed, static command
  set — `search()` AND `discover()` are both implemented so the palette
  shows the full list before any typing.
- `EntitiesProvider` — one command per live row in a panel's own list
  (a tool, a host, a pending file, a health check) — "run fzf", "push
  web-01", "apply .zshrc", "run check doctor". Built fresh on every
  `search()` call from the panels' own state (`ProvisionPanel.tools`,
  `FleetPanel.hosts`, `DotfilesPanel.pending`, `core.health.CHECKS`) —
  `search()` only, no `discover()` (spec: entities appear as typed, the
  list would otherwise be as long as every tool+host+pending file in one
  screen).
- `HistoryProvider` — re-runnable (`task`/`sequence` with a recorded
  `command`) entries from `app.history_store`, most-recent-first via
  `HistoryStore.load` — `search()` only.

Every entity/history NAME is a live value a user or a file can shape
(tool/host/pending-path names, task summaries) — Textual's own
`Matcher.highlight()` markup-PARSES the candidate string it's given (it
calls `Content.from_markup(candidate)` internally before stylizing the
fuzzy-match offsets), so an unescaped hostile name like `[red]x[/red]`
would silently lose its literal brackets (`Content.from_markup` treats
them as real markup and strips them down to a styled "x"). Every such
name is therefore run through `textual.markup.escape()` before it ever
reaches `matcher.highlight()` — confirmed empirically against this
project's pinned Textual 8.2.8 (`Matcher.highlight` source inspected
directly, see task-6 verification notes) rather than trusted from prose
docs, since this is the one place a hostile name could otherwise corrupt
what the palette shows. `ActionsProvider`'s command names are fixed
literals we author ourselves (never user/file data) — no escaping needed
there, but `DiscoveryHit.display` values are still wrapped in
`rich.text.Text` (which `CommandPalette` special-cases to
`Content.from_rich_text`, bypassing markup parsing entirely) as the
belt-and-suspenders default for anything shown before a `matcher` exists
to highlight against.

Every provider's `search()` wraps ALL of its body (state-gathering *and*
matching) in one `try/except Exception: return` — a panel-state read
raising (a torn-down panel, a monkeypatched attribute in a test) makes
the WHOLE call yield nothing, never a partial result list assembled
before the exception hit. Callbacks never re-implement a panel's own
action: every one composes `switch_panel(panel_id)` -> (optionally)
`panel.select_row(key)` -> the panel's existing `action_*` method (or,
where a table row's `enter` behavior is a screen push rather than an
`action_*` method — Fleet's host stats, Health's `_run_check` — that same
existing call), so every gate/confirm/notify inside those methods runs
unchanged.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Callable

from rich.text import Text
from textual.command import DiscoveryHit, Hit, Hits, Provider
from textual.markup import escape

from workstation_tui.app.widgets.host_stats import HostStatsScreen
from workstation_tui.core.fleet import rel_age
from workstation_tui.core.health import CHECKS
from workstation_tui.core.history import HistoryEntry


def _go_to(app, panel_id: str) -> Callable[[], None]:
    """Callback: switch to `panel_id` and nothing else (the "go to X"
    commands — no row selection, no action call)."""

    def _run() -> None:
        app.switch_panel(panel_id)

    return _run


def _panel_action(app, panel_id: str, action_name: str) -> Callable[[], None]:
    """Callback: switch to `panel_id`, then call its existing
    `action_name` bound method — the "do it to everything" whole-panel
    commands (full provision, apply all pending, push all hosts, run all
    health checks, distribute keys, check updates)."""

    def _run() -> None:
        app.switch_panel(panel_id)
        panel = app.query_one(f"#{panel_id}")
        getattr(panel, action_name)()

    return _run


def _row_action(app, panel_id: str, row_key: str, action_name: str) -> Callable[[], None]:
    """Callback: switch to `panel_id`, move the cursor to `row_key` via
    the panel's `select_row` helper, then call its existing `action_name`
    bound method — every per-row EntitiesProvider command except Fleet's
    "stats" (a screen push, no `action_*` method) and Dotfiles' "diff"
    (select-only, no action at all — the diff pane already follows the
    cursor row).

    `EntitiesProvider.search()` snapshots a panel's list at keystroke
    time; by the time the user actually invokes the hit, a watch tick or
    refresh may have repopulated the table (provision.py's marked-run
    guard documents this exact race for `space`-marked tools). Every
    `action_*` this wires up resolves its target from the CURRENT
    CURSOR position (`selected_tool()`/`selected_entry()`/
    `selected_path()`), never from `row_key` directly — so a silently
    -ignored `select_row` failure would run the action against whatever
    row the cursor happens to be on instead: installing/pushing/applying
    the WRONG entity. `select_row`'s return is therefore checked BEFORE
    calling the action; on `False` (row gone) this notifies and returns
    without touching the panel at all.
    """

    def _run() -> None:
        app.switch_panel(panel_id)
        panel = app.query_one(f"#{panel_id}")
        if not panel.select_row(row_key):
            app.notify(f"{row_key} no longer available",
                       severity="warning", markup=False)
            return
        getattr(panel, action_name)()

    return _run


def _row_select(app, panel_id: str, row_key: str) -> Callable[[], None]:
    """Callback: switch to `panel_id` and move the cursor to `row_key`,
    with no further action — Dotfiles' "diff <path>" command: the diff
    pane already re-renders on cursor movement (`on_data_table_row_
    highlighted`), so selecting the row IS the whole command."""

    def _run() -> None:
        app.switch_panel(panel_id)
        panel = app.query_one(f"#{panel_id}")
        panel.select_row(row_key)

    return _run


def _fleet_stats(app, host_name: str) -> Callable[[], None]:
    """Callback: switch to fleet, select the row, then push
    `HostStatsScreen` for whichever entry currently has this name — the
    same screen `FleetPanel.on_data_table_row_selected` pushes on `enter`
    (not a new action). Resolves the entry fresh at call time (not
    captured at command-build time) so a stale palette hit for a host
    that's since been removed degrades to a no-op instead of pushing a
    screen for a `HostEntry` that no longer matches the live table."""

    def _run() -> None:
        app.switch_panel("fleet")
        panel = app.query_one("#fleet")
        panel.select_row(host_name)
        entry = next((e for e in panel.hosts if e.name == host_name), None)
        if entry is not None:
            app.push_screen(HostStatsScreen(entry))

    return _run


def _health_run_check(app, check_id: str) -> Callable[[], None]:
    """Callback: switch to health, select the row, then call the same
    private `_run_check(check_id)` `HealthPanel.on_data_table_row_
    selected` calls on `enter` — not a new action, the existing one."""

    def _run() -> None:
        app.switch_panel("health")
        panel = app.query_one("#health")
        panel.select_row(check_id)
        panel._run_check(check_id)

    return _run


def _rerun(app, entry: HistoryEntry) -> Callable[[], None]:
    """Callback: hand `entry` to the app's existing gated re-run path —
    same call `HistoryScreen`'s own `r` binding makes, so the
    task/sequence-only + command-not-None re-runnable check, the sudo
    gate, and the busy-refusal toast all run unchanged."""

    def _run() -> None:
        app.rerun_history_entry(entry)

    return _run


#: Panel ids the sidebar switches between — mirrors `app.py`'s `PANELS`
#: (bare ids only; every label there is simply `panel_id.capitalize()`,
#: true for all five entries today). Deliberately duplicated here rather
#: than imported from `app.py`: that module already imports THIS one at
#: class-body time (`WorkstationApp.COMMANDS`), so even a function-
#: deferred `from workstation_tui.app.app import PANELS` (fine at
#: runtime — by the time this function is first called, app.py has long
#: finished importing) is a real file-level dependency cycle that
#: basedpyright's `reportImportCycles` flags. Keep in sync with `PANELS`
#: if a panel is ever added/renamed there.
_PANEL_IDS: tuple[str, ...] = ("dashboard", "provision", "dotfiles", "fleet", "health")


def _actions_commands(app) -> list[tuple[str, str, Callable[[], None]]]:
    """The fixed `(name, help, callback)` list `ActionsProvider` searches
    and discovers. Built fresh on every call — cheap, it's a short static
    list — rather than cached at class-body time, which would need `app`
    before any instance exists.
    """
    cmds: list[tuple[str, str, Callable[[], None]]] = [
        (f"go to {panel_id}", f"switch to the {panel_id.capitalize()} panel",
         _go_to(app, panel_id))
        for panel_id in _PANEL_IDS
    ]
    cmds += [
        ("refresh", "reload the summary and every panel", app.action_refresh),
        ("toggle watch", "toggle auto-refresh watch mode", app.action_toggle_watch),
        ("check updates", "provision: check for tool updates",
         _panel_action(app, "provision", "action_updates")),
        ("task history", "open the task history browser", app.action_history),
        ("help", "show the keyboard help overlay", app.action_help),
        ("quit", "quit the application", app.action_quit),
        ("provision all", "provision: run full provision",
         _panel_action(app, "provision", "action_full_provision")),
        ("apply all pending", "dotfiles: apply every pending change",
         _panel_action(app, "dotfiles", "action_apply_pending")),
        ("push all hosts", "fleet: push to every host",
         _panel_action(app, "fleet", "action_push_all")),
        ("run all health checks", "health: run every available check",
         _panel_action(app, "health", "action_run_all")),
        ("distribute keys", "fleet: guided ssh key distribution",
         _panel_action(app, "fleet", "action_distribute_keys")),
    ]
    return cmds


class ActionsProvider(Provider):
    """Every whole-app/whole-panel action, fixed and static."""

    async def search(self, query: str) -> Hits:
        try:
            commands = _actions_commands(self.app)
            matcher = self.matcher(query)
            hits = [
                Hit(score, matcher.highlight(escape(name)), callback, text=name, help=help_text)
                for name, help_text, callback in commands
                if (score := matcher.match(name))
            ]
        except Exception:
            return
        for hit in hits:
            yield hit

    async def discover(self) -> Hits:
        try:
            commands = _actions_commands(self.app)
            hits = [
                DiscoveryHit(Text(name), callback, text=name, help=help_text)
                for name, help_text, callback in commands
            ]
        except Exception:
            return
        for hit in hits:
            yield hit


def _entities(app) -> list[tuple[str, str, Callable[[], None]]]:
    """The live `(name, help, callback)` list `EntitiesProvider` searches
    — one entry per row currently held by a panel's own state. Reads
    `ProvisionPanel.tools` / `FleetPanel.hosts` / `DotfilesPanel.pending`
    directly (not through a provider function) — same panel-owns-its-
    state discipline every other app-level reader (footer keys, the
    drift tests) already relies on. `CHECKS` is the module-level registry
    (`core/health.py`), not panel state — Health has no per-check list of
    its own beyond that constant.
    """
    out: list[tuple[str, str, Callable[[], None]]] = []

    provision = app.query_one("#provision")
    for tool in provision.tools:
        name = tool.name
        out.append((
            f"run {name}", "provision: run this tool",
            _row_action(app, "provision", name, "action_run_tool"),
        ))
        out.append((
            f"clean {name}", "provision: clean and reinstall this tool",
            _row_action(app, "provision", name, "action_clean_tool"),
        ))

    fleet = app.query_one("#fleet")
    for entry in fleet.hosts:
        name = entry.name
        out.append((
            f"push {name}", "fleet: push to this host",
            _row_action(app, "fleet", name, "action_push_selected"),
        ))
        out.append((
            f"ssh {name}", "fleet: ssh to this host",
            _row_action(app, "fleet", name, "action_ssh_selected"),
        ))
        out.append((
            f"zellij {name}", "fleet: ssh + remote zellij attach main",
            _row_action(app, "fleet", name, "action_zellij_selected"),
        ))
        out.append((
            f"stats {name}", "fleet: view quick stats for this host",
            _fleet_stats(app, name),
        ))

    dotfiles = app.query_one("#dotfiles")
    for change in dotfiles.pending:
        path = change.path
        out.append((
            f"apply {path}", "dotfiles: apply this pending file",
            _row_action(app, "dotfiles", path, "action_apply_selected"),
        ))
        out.append((
            f"diff {path}", "dotfiles: view the diff for this file",
            _row_select(app, "dotfiles", path),
        ))

    for check in CHECKS:
        out.append((
            f"run check {check.label}", "health: run this check",
            _health_run_check(app, check.check_id),
        ))

    return out


class EntitiesProvider(Provider):
    """One command per live row in a panel's own list. `search()` only —
    no `discover()`: entities appear as typed, not dumped in full before
    any input (the combined tool+host+pending-file+check list would
    otherwise be the whole app's data on screen 0 keystrokes in)."""

    async def search(self, query: str) -> Hits:
        try:
            entities = _entities(self.app)
            matcher = self.matcher(query)
            hits = [
                Hit(score, matcher.highlight(escape(name)), callback, text=name, help=help_text)
                for name, help_text, callback in entities
                if (score := matcher.match(name))
            ]
        except Exception:
            return
        for hit in hits:
            yield hit


#: How many re-runnable entries the palette surfaces (spec §1: "the
#: newest 20 re-runnable history entries").
_HISTORY_LIMIT = 20

#: How deep into the store `_history_candidates` looks before giving up —
#: deliberately much larger than `_HISTORY_LIMIT` (F4): filtering happens
#: AFTER loading, so a `load(_HISTORY_LIMIT)` would silently short the
#: palette to fewer than 20 re-runnable hits whenever recent history holds
#: any push/keydist runs (they don't count, but they DO occupy a load-20
#: slot) — a run of pushes/keydist can otherwise starve the palette down
#: to 0-19 re-runs even though 20 older re-runnable entries exist further
#: back in the store.
_HISTORY_SCAN = 200


def _history_candidates(app) -> list[tuple[str, HistoryEntry]]:
    """Re-runnable (`task`/`sequence` with a recorded `command`) entries
    from `app.history_store`, newest first, paired with the display name
    `re-run: <summary> (<rel_age>, rc <rc>)`. `push`/`keydist` entries
    (and any `task`/`sequence` recorded with no command — shouldn't
    happen, but `_history_entry`'s contract allows it) are filtered out
    here rather than surfaced with a dead-end command — the same
    kind-and-command gate `WorkstationApp.rerun_history_entry` itself
    checks before actually launching anything. Scans up to
    `_HISTORY_SCAN` entries so the filter (above) can still fill all
    `_HISTORY_LIMIT` slots even when recent history is push/keydist-heavy.
    """
    entries = app.history_store.load(_HISTORY_SCAN)
    now = datetime.now(UTC)
    out: list[tuple[str, HistoryEntry]] = []
    for entry in entries:
        if entry.kind not in ("task", "sequence") or entry.command is None:
            continue
        out.append((_history_name(entry, now), entry))
        if len(out) >= _HISTORY_LIMIT:
            break
    return out


def _history_name(entry: HistoryEntry, now: datetime) -> str:
    try:
        started = datetime.fromisoformat(entry.started_at)
        age = rel_age(max((now - started).total_seconds(), 0.0))
    except Exception:
        age = "?"
    rc = entry.returncode if entry.returncode is not None else "—"
    return f"re-run: {entry.summary} ({age}, rc {rc})"


class HistoryProvider(Provider):
    """Re-runnable task history entries, most-recent-first. `search()`
    only (history is meant to be searched for a specific past run, not
    dumped whole on an empty query)."""

    async def search(self, query: str) -> Hits:
        try:
            candidates = await asyncio.to_thread(_history_candidates, self.app)
            matcher = self.matcher(query)
            hits = [
                Hit(score, matcher.highlight(escape(name)), _rerun(self.app, entry),
                    text=name, help="re-run this entry")
                for name, entry in candidates
                if (score := matcher.match(name))
            ]
        except Exception:
            return
        for hit in hits:
            yield hit
