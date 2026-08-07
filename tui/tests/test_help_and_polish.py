from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import GitState
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


async def test_question_mark_opens_help_and_escape_closes() -> None:
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("?")
        await pilot.pause()
        assert type(app.screen).__name__ == "HelpScreen"
        await pilot.press("escape")
        await pilot.pause()
        assert type(app.screen).__name__ != "HelpScreen"


async def test_dotfiles_in_sync_logged_once_across_refreshes() -> None:
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        pending_provider=lambda: ([], []),
        git_state_provider=lambda root: (
            GitState(branch="main", dirty=False, ahead=0, behind=0), []),
        target_diff_fn=lambda path: ("", None),
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        panel = app.query_one("#dotfiles")
        baseline = sum("in sync" in l for l in panel.log_lines)
        assert baseline == 1
        await pilot.press("g")          # summary refresh triggers panel refresh
        for _ in range(4):
            await pilot.pause()
        assert sum("in sync" in l for l in panel.log_lines) == 1


async def test_dotfiles_warnings_logged_once_across_refreshes() -> None:
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        pending_provider=lambda: ([], ["chezmoi status failed: boom"]),
        git_state_provider=lambda root: (
            GitState(branch="main", dirty=False, ahead=0, behind=0), []),
        target_diff_fn=lambda path: ("", None),
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        panel = app.query_one("#dotfiles")
        baseline = sum("boom" in l for l in panel.log_lines)
        assert baseline == 1
        await pilot.press("g")          # summary refresh triggers panel refresh
        for _ in range(4):
            await pilot.pause()
        assert sum("boom" in l for l in panel.log_lines) == 1
