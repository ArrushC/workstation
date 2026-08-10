"""Provision multi-select (spec §2): `space` marks the cursor row, `r` runs
ALL marked tools in ONE make invocation (table order), `esc` clears marks,
marks survive filtering, and a successful run clears marks while a failed
one leaves them in place."""

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import StampState, TaskResult, ToolStatus
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

TOOLS = [
    ToolStatus(name="fzf", kind="scope", version="0.74.2", state=StampState.FRESH),
    ToolStatus(name="zellij", kind="scope", version="0.44.3", state=StampState.STALE),
    ToolStatus(name="glances", kind="user", version="latest", state=StampState.MISSING),
]


def local_tools_provider():
    return TOOLS, []


class ScriptedRunner(FakeRunner):
    """Runner whose `run()` returns rc's off a scripted queue, one per call
    (falls back to rc=0 once the queue is exhausted)."""

    def __init__(self, rcs: list[int]) -> None:
        super().__init__()
        self.rcs = list(rcs)

    async def run(self, command, on_line):
        self.commands.append(command)
        on_line("out")
        rc = self.rcs.pop(0) if self.rcs else 0
        return TaskResult(command=command, returncode=rc, duration_secs=0.0)


def make_app(runner=None, *, tools_provider_fn=None):
    return WorkstationApp(
        summary_provider=fake_provider,
        runner=runner or FakeRunner(),
        tools_provider=tools_provider_fn or local_tools_provider,
        sudo_status_fn=lambda: "valid",
    )


def make_gate_app(runner, statuses: list[str]):
    """Same shape as test_sudo_gate.make_app, wired to this file's TOOLS
    (fzf/zellij=scope, glances=user) so the marked-run sudo formula
    (`all(kind == "user")`, T3-a) can be pinned by observing whether
    sudo_status_fn is consulted at all — `status_calls` stays empty when
    the gate is skipped (needs_sudo=False) and gets an entry when it's
    consulted (needs_sudo=True)."""
    status_calls: list[int] = []

    def status_fn():
        status_calls.append(1)
        return statuses.pop(0) if statuses else "valid"

    app = WorkstationApp(
        summary_provider=fake_provider,
        runner=runner,
        tools_provider=local_tools_provider,
        sudo_status_fn=status_fn,
    )
    return app, status_calls


async def test_space_marks_cursor_row_and_renders_glyph() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        panel = app.query_one("#provision")
        table = app.query_one("#provision-table")
        table.focus()
        assert panel.marked == set()
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf"}
        cell = table.get_cell("fzf", "mark")
        assert str(cell) == "●"  # SEL_ON glyph
        # toggling again unmarks
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == set()
        cell = table.get_cell("fzf", "mark")
        assert str(cell) == "·"  # SEL_OFF glyph


async def test_run_with_marks_is_one_invocation_all_names_in_table_order() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        # Mark glances (row 2) THEN fzf (row 0) — out of table order — the
        # invocation must still list them in TABLE order (fzf, glances),
        # not mark order.
        table.cursor_coordinate = (2, 0)
        await pilot.press("space")
        await pilot.pause()
        table.cursor_coordinate = (0, 0)
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf", "glances"}
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
        assert len(runner.commands) == 1, "marks must fire ONE invocation"
        cmd = runner.commands[0]
        assert cmd.index("fzf") < cmd.index("glances")


async def test_run_without_marks_uses_cursor_row_existing_behavior() -> None:
    """No marks -> `r` still runs just the cursor-row tool (pinned)."""
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        assert panel.marked == set()
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
        assert len(runner.commands) == 1
        cmd = runner.commands[0]
        assert "fzf" in cmd
        assert "zellij" not in cmd
        assert "glances" not in cmd


async def test_escape_clears_marks() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf"}
        await pilot.press("escape")
        await pilot.pause()
        assert panel.marked == set()
        cell = table.get_cell("fzf", "mark")
        assert str(cell) == "·"


async def test_marks_survive_filtering() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        await pilot.press("space")  # marks fzf (cursor row 0)
        await pilot.pause()
        assert panel.marked == {"fzf"}
        # filter to something that hides the marked row entirely
        app.query_one("#provision-filter").value = "zel"
        await pilot.pause()
        assert table.row_count == 1
        assert panel.marked == {"fzf"}, "a filtered-out marked tool stays marked"
        # clear filter — the marked row reappears still marked
        app.query_one("#provision-filter").value = ""
        await pilot.pause()
        assert table.row_count == 3
        cell = table.get_cell("fzf", "mark")
        assert str(cell) == "●"


async def test_clear_on_success_vs_persist_on_failure() -> None:
    runner = ScriptedRunner([0, 3])
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()

        # First run: rc=0 -> marks clear.
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf"}
        await pilot.press("r")
        for _ in range(5):
            await pilot.pause()
        assert panel.marked == set(), "marks must clear on a successful run"

        # Second run: rc=3 -> marks persist.
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf"}
        await pilot.press("r")
        for _ in range(5):
            await pilot.pause()
        assert panel.marked == {"fzf"}, "marks must persist after a failed run"


# -- Important 1: empty-`ordered` guard (vacuous-truth sudo-bypass hole) ----


async def test_marked_run_with_names_not_in_inventory_refuses(monkeypatch) -> None:
    """A watch tick / refresh can repopulate self.tools with [] (e.g.
    `make inventory` transiently failing) while self.marked (name-keyed,
    independent of the table) still holds stale names. `ordered` then comes
    out empty — without a guard, `all(<empty>) == True` (vacuous truth)
    would hand run_make_goals a user_kind bypass for a goal-less `make`
    invocation (make's .DEFAULT_GOAL, under no sudo gate). Must instead
    refuse: no runner invocation, marks preserved, a warning notified."""
    runner = FakeRunner()
    app = make_app(runner)
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf"}
        # Simulate the transient failure: set_tools([]) wholesale-replaces
        # self.tools, but marks survive (they're name-keyed, not row-keyed).
        panel.set_tools([], ["make inventory failed (rc=2): boom"])
        await pilot.pause()
        assert panel.marked == {"fzf"}, "marks survive an empty set_tools()"
        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands == [], "must not invoke make with no goals"
    assert panel.marked == {"fzf"}, "marks must NOT be cleared on refusal"
    assert calls, "must notify the user"
    assert calls[0][1].get("severity") == "warning"


async def test_marked_run_mixed_kinds_gates_sudo() -> None:
    """T3-a: a marked set with at least one non-`user`-kind tool must gate
    on sudo (needs_sudo=True) — the `all(kind == "user")` formula only
    skips the gate when EVERY marked tool is user-kind."""
    runner = FakeRunner()
    app, status_calls = make_gate_app(runner, ["valid"])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        # fzf = scope-kind, glances = user-kind: a mixed marked set.
        table.cursor_coordinate = (0, 0)
        await pilot.press("space")
        await pilot.pause()
        table.cursor_coordinate = (2, 0)
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"fzf", "glances"}
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
    assert status_calls, "a mixed marked set must consult the sudo gate"
    assert runner.commands, "gate reports 'valid' so the run must proceed"


async def test_marked_run_all_user_kind_skips_sudo_gate() -> None:
    """T3-a: an all-`user`-kind marked set must skip the sudo gate
    entirely (needs_sudo=False) — the non-vacuous side of the
    `all(kind == "user")` formula (the vacuous-empty side is the guard
    pinned by test_marked_run_with_names_not_in_inventory_refuses above)."""
    runner = FakeRunner()
    app, status_calls = make_gate_app(runner, ["needs_password"])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        panel = app.query_one("#provision")
        table.focus()
        table.cursor_coordinate = (2, 0)  # glances = user-kind
        await pilot.press("space")
        await pilot.pause()
        assert panel.marked == {"glances"}
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
    assert status_calls == [], "an all-user marked set must skip the sudo gate"
    assert runner.commands, "run proceeds unattended (no gate to fail)"
