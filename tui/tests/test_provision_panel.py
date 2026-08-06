import asyncio

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import StampState, TaskResult, ToolStatus
from tests.test_app_shell import FAKE_SUMMARY, fake_provider

TOOLS = [
    ToolStatus(name="fzf", kind="scope", version="0.74.2", state=StampState.FRESH),
    ToolStatus(name="zellij", kind="scope", version="0.44.3", state=StampState.STALE),
    ToolStatus(name="glances", kind="user", version="latest", state=StampState.MISSING),
]


def tools_provider():
    return TOOLS, []


class FakeRunner:
    def __init__(self) -> None:
        self.commands: list[list[str]] = []
        self.busy = False

    async def run(self, command, on_line):
        self.commands.append(command)
        on_line("==> fake output")
        return TaskResult(command=command, returncode=0, duration_secs=0.1)

    def cancel(self) -> None:
        pass


def make_app() -> tuple[WorkstationApp, FakeRunner]:
    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=fake_provider,
        runner=runner,
        tools_provider=tools_provider,
        # Pilot tests never hit real make/sudo: fake a valid timestamp so
        # the sudo gate proceeds immediately instead of consulting the
        # host's ambient `sudo -n -v` state (or pushing a modal nothing
        # here drives).
        sudo_status_fn=lambda: "valid",
    )
    return app, runner


async def test_table_lists_tools_and_filter() -> None:
    app, _ = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        assert table.row_count == 3
        app.query_one("#provision-filter").value = "zel"
        await pilot.pause()
        assert table.row_count == 1


async def test_run_selected_tool_streams_to_log() -> None:
    app, runner = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands, "runner never invoked"
        cmd = runner.commands[0]
        assert cmd[-2:] == ["fzf", f"MODE={app.summary.context.mode}"] or "fzf" in cmd
        log_lines = app.query_one("#provision").log_lines
        assert any("fake output" in line for line in log_lines)


async def test_busy_refusal_notifies() -> None:
    app, runner = make_app()

    class BusyRunner(FakeRunner):
        def __init__(self):
            super().__init__()
            self.busy = True

        async def run(self, command, on_line):
            from workstation_tui.core.runner import TaskBusyError
            raise TaskBusyError()

    app._runner = BusyRunner()  # swap before mount wiring
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        # refusal shows as a notification, not a crash
        assert app.is_running


async def test_filter_keystrokes_do_not_duplicate_warnings() -> None:
    def erroring_provider():
        return TOOLS, ["make inventory failed: boom"]

    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=erroring_provider,
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        panel = app.query_one("#provision")
        baseline = sum("boom" in line for line in panel.log_lines)
        assert baseline == 1
        app.query_one("#provision-filter").focus()
        await pilot.press(*"zel")
        await pilot.pause()
        assert sum("boom" in line for line in panel.log_lines) == baseline


async def test_refresh_mid_task_does_not_cancel_task() -> None:
    """Finding 1 regression: `g` mid-task must not SIGKILL the running task.

    Before the fix, action_refresh's exclusive=True run_worker shared the
    default worker group with _task_flow's run_worker, so refreshing while
    a task was in flight cancelled the task worker outright (routing
    through the runner's exception boundary in the real Runner, with no
    toast). Isolating the groups ("summary" vs "task") is the fix; this
    test proves the task now runs to completion despite a concurrent `g`.
    """

    class SlowRunner(FakeRunner):
        def __init__(self) -> None:
            super().__init__()
            self.completed = False

        async def run(self, command, on_line):
            self.commands.append(command)
            self.busy = True
            on_line("started")
            await asyncio.sleep(0.3)
            self.busy = False
            self.completed = True
            return TaskResult(command=command, returncode=0, duration_secs=0.3)

    runner = SlowRunner()
    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press("g")          # refresh while task in flight
        await asyncio.sleep(0.5)
        await pilot.pause()
        # the task RAN TO COMPLETION rather than being cancelled by the
        # concurrent refresh
        assert runner.completed is True
        assert runner.commands           # ran


async def test_provision_unavailable_when_no_make() -> None:
    """Finding 3: a host with no make (e.g. Windows) degrades honestly."""

    def no_make_provider():
        context = FAKE_SUMMARY.context.model_copy(
            update={"has_make": False, "os": "windows"}
        )
        return FAKE_SUMMARY.model_copy(update={"context": context})

    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=no_make_provider, runner=runner,
        tools_provider=tools_provider,
        sudo_status_fn=lambda: "valid",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        panel = app.query_one("#provision")
        assert panel.unavailable is True
        assert any("not available" in line for line in panel.log_lines)
        table = app.query_one("#provision-table")
        assert table.row_count == 0
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        assert runner.commands == []


async def test_task_failure_with_markup_text_notifies_without_crash() -> None:
    class ExplodingRunner(FakeRunner):
        async def run(self, command, on_line):
            raise RuntimeError("boom: [/etc/foo] missing")

    app = WorkstationApp(
        summary_provider=fake_provider, runner=ExplodingRunner(),
        tools_provider=tools_provider,
        # Same ambient-sudo independence as make_app() above — this test
        # presses "r" too.
        sudo_status_fn=lambda: "valid",
    )
    async with app.run_test(notifications=True) as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
        assert app.is_running  # toast rendered without MarkupError
