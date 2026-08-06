from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import TaskResult
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )


async def test_log_to_routes_lines() -> None:
    app = make_app()
    captured: list[str] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["fake", "cmd"], log_to=captured.append)
        for _ in range(4):
            await pilot.pause()
    assert any("fake output" in line for line in captured)
    assert any("$ fake cmd" in line for line in captured)


async def test_sequence_runs_in_order_and_aborts_on_failure() -> None:
    class ScriptedRunner(FakeRunner):
        def __init__(self):
            super().__init__()
            self.rcs = [0, 3, 0]

        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("out")
            return TaskResult(command=command, returncode=self.rcs[len(self.commands) - 1],
                              duration_secs=0.0)

    runner = ScriptedRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.run_task_sequence([["one"], ["two"], ["three"]], log_to=lambda _: None)
        for _ in range(6):
            await pilot.pause()
    assert runner.commands == [["one"], ["two"]]  # third never ran (rc=3 aborted)


async def test_on_done_called() -> None:
    app = make_app()
    done: list[bool] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["x"], log_to=lambda _: None, on_done=lambda: done.append(True))
        for _ in range(4):
            await pilot.pause()
    assert done == [True]


async def test_sequence_stops_on_cancelled_even_rc_zero() -> None:
    class CancellingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=0, duration_secs=0.0,
                              cancelled=True)

    runner = CancellingRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.run_task_sequence([["one"], ["two"]], log_to=lambda _: None)
        for _ in range(5):
            await pilot.pause()
    assert runner.commands == [["one"]]  # second never ran despite rc=0
