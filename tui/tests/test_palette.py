"""Command palette providers (Phase C Task 6, spec §1).

Same `FakeRunner`/`fake_provider` fixtures as the rest of the suite, plus
hosts/pending fixtures matching test_fleet_panel.py/test_dotfiles_panel.py.
Providers are unit-tested directly — `Provider(app.screen)` then
`[h async for h in provider.search(query)]` — inside a running
`app.run_test()` pilot context, per the task-6 brief.
"""

from datetime import UTC, datetime, timedelta
from pathlib import Path

from textual.command import CommandPalette
from textual.widgets import DataTable, Static

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.palette import ActionsProvider, EntitiesProvider, HistoryProvider
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.core.history import HistoryEntry, HistoryStore
from workstation_tui.core.models import GitState, HostEntry, PendingChange
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

HOSTS = [
    HostEntry(name="web-01", address="10.0.0.1", user="u", group="dev_machine"),
    HostEntry(name="db-01", address="10.0.0.2", user="u", group="dev_machine"),
]

PENDING = [PendingChange(code="MM", path=".zshrc")]


async def fake_probe_all(entries, **kwargs):
    return {e.name: ("up", "setup") for e in entries}


def make_app(
    runner=None, hosts=None, history_store=None, sudo_status_fn=None,
) -> WorkstationApp:
    return WorkstationApp(
        summary_provider=fake_provider,
        runner=runner or FakeRunner(),
        tools_provider=tools_provider,
        sudo_status_fn=sudo_status_fn or (lambda: "valid"),
        hosts_provider=lambda: (hosts if hosts is not None else HOSTS, []),
        probe_all_fn=fake_probe_all,
        pending_provider=lambda: (PENDING, []),
        git_state_provider=lambda root: (GitState(branch="main", dirty=False, ahead=0, behind=0), []),
        target_diff_fn=lambda path: (f"--- {path}\n", None),
        history_store=history_store,
    )


async def _settle(pilot) -> None:
    for _ in range(4):
        await pilot.pause()


# -- 1. ctrl+p opens the palette ---------------------------------------------


async def test_ctrl_p_opens_the_palette() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await _settle(pilot)
        await pilot.press("ctrl+p")
        await pilot.pause()
        assert isinstance(app.screen, CommandPalette)


# -- 2. get_system_commands -> Quit only -------------------------------------


async def test_get_system_commands_yields_quit_only() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await _settle(pilot)
        commands = list(app.get_system_commands(app.screen))
        assert [c.title for c in commands] == ["Quit"]


# -- 3. ActionsProvider search + discover ------------------------------------


async def test_actions_provider_search_and_discover() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = ActionsProvider(app.screen)
        hits = [h async for h in provider.search("fleet")]
        names = [h.text for h in hits]
        assert "go to fleet" in names
        go_fleet = next(h for h in hits if h.text == "go to fleet")

        # provision panel is active by default? no -- dashboard; switch
        # away first so the callback's own switch is actually observable.
        app.switch_panel("provision")
        assert app.query_one("#content").current == "provision"
        result = go_fleet.command()
        if hasattr(result, "__await__"):
            await result
        await pilot.pause()
        assert app.query_one("#content").current == "fleet"

        discovered = [h async for h in provider.discover()]
        discovered_names = {h.text for h in discovered}
        # every "go to X" plus the fixed whole-app/whole-panel actions.
        for expected in (
            "go to dashboard", "go to provision", "go to dotfiles",
            "go to fleet", "go to health", "refresh", "toggle watch",
            "check updates", "task history", "help", "quit",
            "provision all", "apply all pending", "push all hosts",
            "run all health checks", "distribute keys",
        ):
            assert expected in discovered_names


# -- 4. EntitiesProvider: provision "run <tool>" reaches the run seam -------


async def test_entities_provider_run_tool_reaches_run_seam() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("run fz")]
        assert any(h.text == "run fzf" for h in hits)
        hit = next(h for h in hits if h.text == "run fzf")

        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        await _settle(pilot)

        assert app.query_one("#content").current == "provision"
        assert app.query_one("#provision").selected_tool() == "fzf"
        assert runner.commands, "run seam never reached"
        assert any("fzf" in cmd for cmd in runner.commands)


# -- Fix round 1: a stale hit (entity gone by invoke time) never acts on
#    whatever the cursor happens to be sitting on instead ------------------


async def test_row_action_notifies_when_entity_gone_before_invoke(monkeypatch) -> None:
    """Reviewer finding: `_row_action` used to discard `select_row`'s
    return value and call the action regardless. `EntitiesProvider.
    search()` snapshots the tool list at keystroke time; a refresh
    between typing and invoking the hit can drop the row `select_row`
    would need — silently falling through to running the action against
    whatever row the cursor is currently on (the WRONG tool) instead of
    refusing. Simulates exactly that race: get the `run fzf` hit, then
    replace the table's tools (a stand-in for an intervening refresh)
    with a list that no longer has fzf, and invoke."""
    runner = FakeRunner()
    app = make_app(runner)
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("run fz")]
        hit = next(h for h in hits if h.text == "run fzf")

        panel = app.query_one("#provision")
        panel.set_tools(
            [t for t in panel.tools if t.name != "fzf"], [],
        )
        await pilot.pause()

        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        await _settle(pilot)

        assert calls, "must notify the user"
        assert calls[0][1].get("severity") == "warning"
        assert runner.commands == [], "must not run against the wrong row"


# -- 5. EntitiesProvider: fleet "push <host>" opens a confirm modal ---------


async def test_entities_provider_push_host_opens_confirm() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("push web")]
        assert any(h.text == "push web-01" for h in hits)
        hit = next(h for h in hits if h.text == "push web-01")

        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        await _settle(pilot)

        assert app.query_one("#content").current == "fleet"
        assert isinstance(app.screen, ConfirmModal)


# -- 6. hostile entity name renders literally --------------------------------


async def test_hostile_entity_name_renders_literally() -> None:
    hostile = [HostEntry(name="[red]x[/red]", address="10.0.0.9", user="u",
                          group="dev_machine")]
    app = make_app(hosts=hostile)
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("red")]
        matches = [h for h in hits if "[red]x[/red]" in h.text]
        assert matches, f"no hostile-name hit among {[h.text for h in hits]}"
        hit = matches[0]
        # The literal brackets must survive -- a markup-parsed render
        # would have stripped them down to a styled bare "x".
        assert hit.match_display.plain == "push [red]x[/red]"


# -- 7. HistoryProvider surfaces re-runnable entries only --------------------


async def test_history_provider_surfaces_rerunnable_only(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    now = datetime.now(UTC)
    task_entry = HistoryEntry(
        id="20260101-000000-aaaa", started_at=(now - timedelta(minutes=2)).isoformat(),
        kind="task", command=["make", "doctor"], summary="make doctor",
        returncode=0, duration_secs=5.0, cancelled=False, outcome="ok",
        needs_sudo=False,
    )
    push_entry = HistoryEntry(
        id="20260101-000100-bbbb", started_at=(now - timedelta(minutes=1)).isoformat(),
        kind="push", command=None, summary="push web-01 — 1 ok, 0 failed",
        returncode=None, duration_secs=0.0, cancelled=False, outcome="ok",
        needs_sudo=False,
    )
    store.append(task_entry, ["$ make doctor"])
    store.append(push_entry, ["push web-01: ok"])

    calls: list[HistoryEntry] = []
    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _settle(pilot)
        app.rerun_history_entry = calls.append  # type: ignore[method-assign]
        provider = HistoryProvider(app.screen)
        hits = [h async for h in provider.search("doctor")]
        assert len(hits) == 1
        assert "make doctor" in hits[0].text
        assert "push" not in hits[0].text

        result = hits[0].command()
        if hasattr(result, "__await__"):
            await result
        assert calls == [task_entry]


# -- 7b. HistoryProvider (F4) scans past a page of non-re-runnable entries --


async def test_history_provider_finds_20_rerunnable_past_recent_pushes(
    tmp_path: Path,
) -> None:
    """F4 regression: `_history_candidates` used to `load(20)` THEN
    filter, so 20+ recent non-re-runnable (push/keydist) entries could
    starve the palette to 0 hits even though 20 older re-runnable
    entries exist further back in the store. It must now scan deep
    enough (`load(200)`) to still surface all 20.
    """
    store = HistoryStore(tmp_path / "h")
    now = datetime.now(UTC)

    # 20 re-runnable task entries, appended FIRST (oldest in the store).
    for i in range(20):
        entry = HistoryEntry(
            id=f"20260101-{i:06d}-task", started_at=(now - timedelta(hours=2)).isoformat(),
            kind="task", command=["make", f"doctor{i}"], summary=f"make doctor{i}",
            returncode=0, duration_secs=1.0, cancelled=False, outcome="ok",
            needs_sudo=False,
        )
        store.append(entry, [f"log {i}"])

    # 25 push entries appended AFTER — the 25 newest entries in the store,
    # none of them re-runnable, none matching the "doctor" query below.
    for i in range(25):
        entry = HistoryEntry(
            id=f"20260101-{i:06d}-push", started_at=now.isoformat(),
            kind="push", command=None, summary=f"push — {i} ok, 0 failed",
            returncode=None, duration_secs=0.0, cancelled=False, outcome="ok",
            needs_sudo=False,
        )
        store.append(entry, [f"push log {i}"])

    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = HistoryProvider(app.screen)
        hits = [h async for h in provider.search("doctor")]
        assert len(hits) == 20, f"expected all 20 re-runnable hits, got {len(hits)}"
        assert all("push" not in h.text for h in hits)


# -- 7c. HistoryProvider `re-run:` hit confirms before launching (F1) -------


async def test_history_provider_rerun_hit_confirms_before_launch(
    tmp_path: Path,
) -> None:
    """F1 regression: the palette's `re-run:` hit used to call
    `app.launch_task` straight through with no confirm at all — a
    `re-run:` hit for a destructive command (a Fleet host remove, a
    `chezmoi apply`) ran immediately on Enter. `rerun_history_entry` now
    owns a `ConfirmModal` (body: `re-run <summary>?` + the joined argv on
    a second line) that both this palette path and `HistoryScreen`'s `r`
    binding go through; decline must leave the runner untouched, accept
    must launch the EXACT recorded argv with the entry's own `needs_sudo`
    (proven here by a `needs_sudo=True` entry actually consulting
    `sudo_status_fn`, the same seam test_history_screen.py's HistoryScreen
    version of this test uses).
    """
    store = HistoryStore(tmp_path / "h")
    now = datetime.now(UTC)
    entry = HistoryEntry(
        id="20260101-000000-dddd", started_at=(now - timedelta(minutes=3)).isoformat(),
        kind="task", command=["make", "provision"], summary="make provision",
        returncode=0, duration_secs=5.0, cancelled=False, outcome="ok",
        needs_sudo=True,
    )
    store.append(entry, ["$ make provision"])

    sudo_calls: list[None] = []

    def sudo_status_fn():
        sudo_calls.append(None)
        return "valid"

    runner = FakeRunner()
    app = make_app(runner, history_store=store, sudo_status_fn=sudo_status_fn)
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = HistoryProvider(app.screen)
        hits = [h async for h in provider.search("provision")]
        assert len(hits) == 1
        hit = hits[0]

        # -- decline: ConfirmModal appears, runner is left untouched -----
        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        for _ in range(6):
            await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)
        message = str(app.screen.query_one("#confirm-message", Static).content)
        assert "re-run make provision?" in message
        assert "make provision" in message  # the joined argv, second line
        await pilot.press("n")
        for _ in range(4):
            await pilot.pause()
        assert runner.commands == []
        assert not sudo_calls

        # -- accept: exact argv + needs_sudo routed to launch_task -------
        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        for _ in range(6):
            await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)
        await pilot.press("y")
        for _ in range(6):
            await pilot.pause()
    assert runner.commands == [["make", "provision"]]
    assert sudo_calls  # needs_sudo=True was threaded through to _sudo_gate


# -- 8. a provider whose panel query raises yields nothing -------------------


class _Boom:
    def __iter__(self):
        raise RuntimeError("boom")


async def test_provider_exception_yields_nothing() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await _settle(pilot)
        app.query_one("#provision").tools = _Boom()  # type: ignore[assignment]
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("fzf")]
        assert hits == []
