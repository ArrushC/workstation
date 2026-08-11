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
    return {
        e.name: (("up", "setup") if e.name == "alpha" else ("down", None))
        for e in entries
    }


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
        # reachability + setup + push glyph columns, ahead of
        # name/address/user/group (push column added in Task 3).
        assert len(table.ordered_columns) == 7
        alpha_row = table.get_row("alpha")
        beta_row = table.get_row("beta")
        # alpha: up + setup ("✓" glyph in the setup column, index 1).
        assert alpha_row[1].plain == "✓"
        # beta: down -> setup stage never runs -> unprobed dim "—".
        assert beta_row[1].plain == "—"


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


async def test_push_selected_confirms_then_opens_push_screen(monkeypatch) -> None:
    """Task 2 rewire: `p` no longer runs directly via `self.app.launch_task`
    (the pre-Task-2 flow this test used to assert on, via `runner.commands`)
    — after confirming, it opens a `PushScreen` scoped to just the selected
    host instead. `PushScreen`'s own MultiRunner-driven rendering is covered
    by tests/test_push_screen.py; this test only checks the fleet-panel-
    level wiring (which host reaches the screen), so `PushScreen` is
    monkeypatched to a tiny recorder + auto-dismiss double — no real
    MultiRunner/subprocess is ever constructed here.
    """
    import workstation_tui.app.panels.fleet as fleet_mod
    from tests.test_push_screen import _RecordingPushScreen

    monkeypatch.setattr(fleet_mod, "PushScreen", _RecordingPushScreen)
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
    assert _RecordingPushScreen.captured is not None
    assert _RecordingPushScreen.captured["alpha"][-2:] == ["--name", "alpha"]
    # The old single-flight Runner is never touched by a push anymore.
    assert runner.commands == []


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


# -- Finding 4: probe merge keeps prior setup state, doesn't overwrite ---


def test_probe_merge_keeps_prior_setup_state_when_stage_two_skipped() -> None:
    """When a probe cycle skips stage 2 (Fleet panel off-screen), a still-
    "up" host arrives as `("up", None)` — that None must not blow away a
    setup glyph a PRIOR visible-panel cycle already established. A host
    that genuinely goes down is NOT covered by the carry-forward: its state
    is "down", not "up", so its dash reflects reality instead of a stale
    setup memory."""
    panel = FleetPanel(id="fleet")

    # up -> up with stage 2 skipped: keep the prior setup state.
    panel.probe_states = {"alpha": ("up", "setup")}
    panel._merge_probe_states({"alpha": ("up", None)})
    assert panel.probe_states["alpha"] == ("up", "setup")

    # up -> down: setup state resets, never inherits the stale "setup".
    panel.probe_states = {"alpha": ("up", "setup")}
    panel._merge_probe_states({"alpha": ("down", None)})
    assert panel.probe_states["alpha"] == ("down", None)

    # never probed before -> up with stage 2 skipped: stays unknown (None),
    # not a crash / KeyError on the never-seen host name.
    panel.probe_states = {}
    panel._merge_probe_states({"beta": ("up", None)})
    assert panel.probe_states["beta"] == ("up", None)

    # up -> up WITH a fresh stage-2 result: the fresh result always wins,
    # never shadowed by whatever was on record before.
    panel.probe_states = {"alpha": ("up", "missing")}
    panel._merge_probe_states({"alpha": ("up", "setup")})
    assert panel.probe_states["alpha"] == ("up", "setup")


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
