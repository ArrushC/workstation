from pathlib import Path

from workstation_tui.app.app import WorkstationApp, _command_summary
from workstation_tui.core.chezmoi import apply_command
from workstation_tui.core.makeiface import make_command
from workstation_tui.core.models import TaskResult
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None, notifier=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        notifier=notifier,
    )


async def test_failure_notifies() -> None:
    class FailingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=1, duration_secs=0.1)

    calls: list[tuple[str, str]] = []
    app = make_app(FailingRunner(), notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == [("workstation", "make fzf — failed (rc=1)")]


async def test_success_over_threshold_notifies() -> None:
    class SlowRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=0, duration_secs=42.4)

    calls: list[tuple[str, str]] = []
    app = make_app(SlowRunner(), notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.notify_threshold_secs = 10.0
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == [("workstation", "make fzf — done (rc=0, 42s)")]


async def test_quick_success_does_not_notify() -> None:
    calls: list[tuple[str, str]] = []
    app = make_app(FakeRunner(), notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.notify_threshold_secs = 10.0
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == []


async def test_cancelled_does_not_notify() -> None:
    class CancellingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=0, duration_secs=99.0,
                              cancelled=True)

    calls: list[tuple[str, str]] = []
    app = make_app(CancellingRunner(), notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.notify_threshold_secs = 0.0
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == []


async def test_sequence_abort_notifies_once() -> None:
    class ScriptedRunner(FakeRunner):
        def __init__(self):
            super().__init__()
            self.rcs = [0, 3, 0]

        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=self.rcs[len(self.commands) - 1],
                              duration_secs=0.0)

    calls: list[tuple[str, str]] = []
    runner = ScriptedRunner()
    app = make_app(runner, notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.run_task_sequence([["one"], ["two"], ["three"]], log_to=lambda _: None)
        for _ in range(6):
            await pilot.pause()
    assert runner.commands == [["one"], ["two"]]  # third never ran (rc=3 aborted)
    assert calls == [("workstation", "two — failed (rc=3)")]


# -- Important 2: toast summary must name the tool, not `--no-print-directory`


def test_command_summary_from_real_make_command() -> None:
    """`make_command()` (core/makeiface.py) always starts
    `["make", "--no-print-directory", "-C", <path>, *goals, "MODE=<mode>"]` —
    the prior `" ".join(argv[:2])` formula rendered every provision toast as
    the byte-identical `"make --no-print-directory"`."""
    argv = make_command(Path("/repo"), ["fzf"], "dev")
    assert _command_summary(argv) == "make fzf"


def test_command_summary_from_chezmoi_apply() -> None:
    assert _command_summary(apply_command()) == "chezmoi apply"


def test_command_summary_degenerate_no_goals_falls_back_to_program() -> None:
    """No goal tokens at all (just the make scaffolding) — nothing
    qualifies, so the summary falls back to argv[0] alone."""
    argv = ["make", "--no-print-directory", "-C", "makefile", "MODE=dev"]
    assert _command_summary(argv) == "make"


async def test_toast_notifies_with_tool_name_via_real_make_command() -> None:
    """End-to-end: a task launched with a REAL make_command()-built argv
    (not the other tests' `["make", "fzf"]` shorthand) must notify with
    the tool name, not the `--no-print-directory` flag."""
    class SlowRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=0, duration_secs=42.4)

    calls: list[tuple[str, str]] = []
    app = make_app(SlowRunner(), notifier=lambda title, msg: calls.append((title, msg)))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.notify_threshold_secs = 10.0
        argv = make_command(Path("/repo"), ["fzf"], "dev")
        app.launch_task(argv, log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == [("workstation", "make fzf — done (rc=0, 42s)")]


async def test_falls_back_to_default_notifier_when_none_injected(monkeypatch) -> None:
    # Pins the seam the autouse `_no_real_notifier` fixture (conftest.py)
    # patches: WorkstationApp constructed with NO notifier kwarg must
    # resolve `self.notifier` to the module-level `_default_notifier` at
    # construction time (`notifier or _default_notifier`), not some other
    # path — that's what makes patching the module attribute an effective,
    # global "never spawn the real notify.sh" seam for every other test in
    # the suite that doesn't inject its own capturing notifier.
    import workstation_tui.app.app as app_mod

    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        app_mod, "_default_notifier", lambda title, msg: calls.append((title, msg))
    )

    class FailingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            return TaskResult(command=command, returncode=1, duration_secs=0.1)

    app = make_app(FailingRunner())  # no notifier kwarg -> falls back to _default_notifier
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert calls == [("workstation", "make fzf — failed (rc=1)")]
