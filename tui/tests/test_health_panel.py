import time
from pathlib import Path

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import CheckResult
from tests.test_app_shell import FAKE_SUMMARY, fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(tmp_path: Path, runner=None, services=None, interop="enabled"):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        health_cache_path=tmp_path / "health.json",
        services_reader=lambda: (services or {"docker": "active", "dozzle": "inactive",
                                             "cockpit": "unknown", "rsyslog": "active"}),
        interop_reader=lambda: interop,
    )


async def test_table_lists_four_checks_with_never_age(tmp_path: Path) -> None:
    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        table = app.query_one("#health-table")
        assert table.row_count == 4
        panel = app.query_one("#health")
        assert "never" in panel.rendered_text()


async def test_cached_result_shows_age_and_state(tmp_path: Path) -> None:
    from workstation_tui.core.health import save_cache
    save_cache(tmp_path / "health.json", {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=time.time() - 7200, returncode=0),
    })
    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        text = app.query_one("#health").rendered_text()
        assert "31/31 ok" in text
        assert "2h ago" in text


async def test_run_selected_check_records_result(tmp_path: Path) -> None:
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(5):
            await pilot.pause()
    assert runner.commands, "check never ran"
    from workstation_tui.core.health import load_cache
    cached = load_cache(tmp_path / "health.json")
    assert "doctor" in cached
    assert cached["doctor"].ok is True


async def test_services_and_interop_lines(tmp_path: Path) -> None:
    app = make_app(tmp_path, interop="disabled")
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        text = app.query_one("#health").rendered_text()
        # FAKE_SUMMARY is WSL dev → services line shows the reason, interop shows state
        assert "disabled" in text


async def test_run_all_streams_sequence(tmp_path: Path) -> None:
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("R")
        for _ in range(8):
            await pilot.pause()
    assert len(runner.commands) == 4  # all four checks (linux dev ctx, all available)


async def test_cancelled_check_not_recorded(tmp_path: Path) -> None:
    from workstation_tui.core.health import load_cache
    from workstation_tui.core.models import TaskResult

    class CancellingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("partial output")
            return TaskResult(command=command, returncode=-2, duration_secs=0.1,
                              cancelled=True)

    app = make_app(tmp_path, CancellingRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(5):
            await pilot.pause()
    assert load_cache(tmp_path / "health.json") == {}  # nothing recorded


async def test_summary_skips_command_echo_and_strips(tmp_path: Path) -> None:
    from workstation_tui.core.health import load_cache
    from workstation_tui.core.models import TaskResult

    class EchoRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("  padded real output  ")
            on_line("")                      # trailing blank
            return TaskResult(command=command, returncode=0, duration_secs=0.1)

    app = make_app(tmp_path, EchoRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
    cached = load_cache(tmp_path / "health.json")
    assert cached["doctor"].summary == "padded real output"   # stripped, not "$ ..." echo


async def test_summary_empty_when_only_echo_line_emitted(tmp_path: Path) -> None:
    """Fix-before-merge pin (Finding 5): a runner that emits NOTHING but the
    "$ " command echo (plus a trailing blank) must record an EMPTY summary
    — `_record_result`'s echo-skip filter refuses to fall back to the echo
    line itself when it's the only candidate. This is the unpinned branch:
    remove the `not line.strip().startswith("$ ")` guard from
    `_record_result` and this test fails (the echo becomes the summary
    instead of "").
    """
    from workstation_tui.core.health import load_cache
    from workstation_tui.core.models import TaskResult

    class EchoOnlyRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("$ make doctor")
            on_line("")  # trailing blank — no real output at all
            return TaskResult(command=command, returncode=0, duration_secs=0.1)

    app = make_app(tmp_path, EchoOnlyRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
    cached = load_cache(tmp_path / "health.json")
    assert cached["doctor"].summary == ""
