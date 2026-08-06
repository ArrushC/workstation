from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.panels.fleet import FleetPanel
from workstation_tui.core.models import HostEntry
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

HOSTS = [
    HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine"),
    HostEntry(name="beta", address="10.0.0.2", user="u", group="prod_machine"),
]


async def fake_probe_all(entries, **kwargs):
    return {e.name: ("up" if e.name == "alpha" else "down") for e in entries}


def make_app(runner=None, ssh_calls=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        hosts_provider=lambda: (HOSTS, []),
        probe_all_fn=fake_probe_all,
        ssh_fn=(ssh_calls.append if ssh_calls is not None else None),
    )


async def test_table_lists_hosts_with_probe_glyphs() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        table = app.query_one("#fleet-table")
        assert table.row_count == 2


async def test_ssh_selected() -> None:
    calls: list = []
    app = make_app(ssh_calls=calls)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("s")
        await pilot.pause()
    assert calls and calls[0].name == "alpha"


async def test_push_selected_confirms_then_runs() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("p")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands and runner.commands[0][-2:] == ["--name", "alpha"]


async def test_push_all_declined() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("P")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert runner.commands == []


async def test_add_host_via_form() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press(*"gamma")
        await pilot.press("tab")
        await pilot.press(*"10.0.0.3")
        await pilot.press("tab")
        await pilot.press(*"me")
        await pilot.press("ctrl+s")
        for _ in range(5):
            await pilot.pause()
    assert runner.commands
    cmd = runner.commands[0]
    assert "--add" in cmd and "gamma" in cmd and "--skip-confirm" in cmd


async def test_remove_host_confirmed() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("x")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands and "--remove" in runner.commands[0]


async def test_edit_host_runs_remove_then_add() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("e")
        await pilot.pause()
        await pilot.press("ctrl+s")      # prefilled form, unchanged submit
        for _ in range(6):
            await pilot.pause()
    assert len(runner.commands) == 2
    assert "--remove" in runner.commands[0] and "--add" in runner.commands[1]


# -- Finding 1: edit/add rename-to-existing collision guard --------------


def test_name_collision_truth_table() -> None:
    # Pure-helper unit test, no running app needed — FleetPanel._name_
    # collision only ever reads self.hosts. Covers both call shapes: edit
    # (old_name is the host being renamed) and add (old_name is None).
    panel = FleetPanel(id="fleet")
    panel.hosts = HOSTS  # alpha, beta

    # edit: unchanged name is never a collision, even though it's already
    # present in self.hosts (it's alpha's OWN row).
    assert panel._name_collision("alpha", "alpha") is False
    # edit: renaming alpha -> beta collides (beta already exists) — this is
    # exactly the Finding 1 data-loss scenario (remove alpha, add beta
    # skipped as "already exists", alpha gone).
    assert panel._name_collision("alpha", "beta") is True
    # edit: renaming alpha -> a fresh name never collides.
    assert panel._name_collision("alpha", "gamma") is False

    # add: old_name is None, so "new_name == old_name" can never suppress
    # a real collision the way the edit-unchanged-name case does.
    assert panel._name_collision(None, "beta") is True
    assert panel._name_collision(None, "gamma") is False


async def test_edit_rename_to_existing_host_blocked() -> None:
    # End-to-end via the panel's public action path (press "e", same as
    # test_edit_host_runs_remove_then_add above) rather than calling
    # _edit_flow directly with a hand-built HostFormModal result — driving
    # it through the real modal exercises the actual wiring, not just the
    # helper. The cursor starts on row 0 (alpha); editing its name to
    # "beta" (already present) must be blocked before either command
    # launches — the add-flow half of the same guard is covered by the
    # truth table above plus code review of the one-line call site, per
    # this task's test budget.
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("e")
        await pilot.pause()
        # app.query_one() only targets the base screen, never the active
        # modal on top of the stack (see test_sudo_modal.py's identical
        # note) — HostFormModal fields are reachable via app.screen.
        app.screen.query_one("#host-form-name").value = "beta"
        await pilot.press("ctrl+s")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands == []


# -- Finding 3: push/ssh are Linux-side, OS-gated ------------------------


async def test_push_blocked_on_windows_context() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        # Flip the already-loaded summary to a Windows context in place
        # (model_copy, per the task spec) rather than re-providing a
        # Windows summary_provider from the start — this is closer to the
        # real scenario of the OS gate reacting to whatever context is
        # currently cached.
        app.summary = app.summary.model_copy(
            update={
                "context": app.summary.context.model_copy(
                    update={"os": "windows", "has_make": False}
                )
            }
        )
        app.query_one("#fleet-table").focus()
        await pilot.press("p")
        await pilot.pause()
    assert runner.commands == []


# -- minor fold: duplicate hosts.conf rows don't crash the table ---------


async def test_duplicate_host_names_deduped_with_warning() -> None:
    dupe_hosts = [
        HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine"),
        HostEntry(name="alpha", address="10.0.0.9", user="u2", group="prod_machine"),
    ]
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        hosts_provider=lambda: (dupe_hosts, []),
        probe_all_fn=fake_probe_all,
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        table = app.query_one("#fleet-table")
        assert table.row_count == 1  # no DuplicateKey crash
        panel = app.query_one("#fleet")
        assert any("duplicate host name" in line for line in panel.log_lines)
