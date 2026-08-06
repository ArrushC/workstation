import asyncio

from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(statuses: list[str], validate_results: list[bool]):
    runner = FakeRunner()
    status_calls: list[int] = []
    validate_calls: list[str] = []

    def status_fn():
        status_calls.append(1)
        return statuses.pop(0) if statuses else "valid"

    def validate_fn(pw: str) -> bool:
        validate_calls.append(pw)
        return validate_results.pop(0)

    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=tools_provider,
        sudo_status_fn=status_fn, sudo_validate_fn=validate_fn,
    )
    return app, runner, status_calls, validate_calls


async def test_valid_timestamp_runs_without_modal() -> None:
    app, runner, status_calls, _ = make_app(["valid"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands
        assert status_calls


async def test_password_flow_then_run() -> None:
    app, runner, _, validate_calls = make_app(
        ["needs_password", "valid"], [True]
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press(*"pw")
        await pilot.press("enter")
        for _ in range(4):
            await pilot.pause()
        assert validate_calls == ["pw"]
        assert runner.commands


async def test_modal_escape_aborts() -> None:
    app, runner, _, _ = make_app(["needs_password"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press("escape")
        for _ in range(3):
            await pilot.pause()
        assert runner.commands == []


async def test_user_kind_skips_gate() -> None:
    app, runner, status_calls, _ = make_app(["needs_password"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-filter").value = "glances"
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands          # ran
        assert status_calls == []       # gate never consulted for user-kind


async def test_no_sudo_status_never_runs() -> None:
    """Finding 4: status_fn == "no_sudo" must refuse without invoking the runner."""
    app, runner, status_calls, _ = make_app(["no_sudo"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands == []
        assert status_calls


async def test_timestamp_timeout_zero_aborts_after_password() -> None:
    """Finding 4: timestamp_timeout=0 sudoers — the post-password re-check
    still reports "needs_password" (the validated password never cached),
    so the task must abort rather than run unattended.
    """
    app, runner, _, validate_calls = make_app(
        ["needs_password", "needs_password"], [True]
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press(*"pw")
        await pilot.press("enter")
        for _ in range(4):
            await pilot.pause()
        assert validate_calls == ["pw"]
        assert runner.commands == []


async def test_double_r_during_gate_single_modal() -> None:
    """Finding 2: launch_task's gate window (status check + modal) isn't
    covered by `self._runner.busy` alone — a second "r" press landing in
    that window must not stack a second SudoModal.
    """
    import time

    def slow_status():
        time.sleep(0.2)
        return "needs_password"

    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=tools_provider,
        sudo_status_fn=slow_status, sudo_validate_fn=lambda pw: True,
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.press("r")          # second press lands in the gate window
        await pilot.pause()
        await asyncio.sleep(0.4)
        await pilot.pause()
        modal_count = sum(type(s).__name__ == "SudoModal" for s in app.screen_stack)
        assert modal_count == 1
        await pilot.press("escape")
        await pilot.pause()
