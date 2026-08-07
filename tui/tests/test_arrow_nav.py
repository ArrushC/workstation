from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import fake_provider


def make_app() -> WorkstationApp:
    return WorkstationApp(summary_provider=fake_provider)


async def test_dashboard_auto_focuses_first_card() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.focused is not None and app.focused.id == "card-provision"


async def test_arrow_walk_moves_between_cards() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("right")
        assert app.focused.id == "card-dotfiles"
        await pilot.press("down")
        assert app.focused.id == "card-health"
        await pilot.press("left")
        assert app.focused.id == "card-fleet"
        await pilot.press("up")
        assert app.focused.id == "card-provision"
        await pilot.press("left")            # edge: no wrap
        assert app.focused.id == "card-provision"
        await pilot.press("up")              # edge: no wrap
        assert app.focused.id == "card-provision"


async def test_ctrl_arrows_cycle_panels_with_wrap() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("ctrl+right")
        assert app.query_one("#content").current == "provision"
        await pilot.press("ctrl+left")
        assert app.query_one("#content").current == "dashboard"
        await pilot.press("ctrl+left")       # wrap backwards
        assert app.query_one("#content").current == "health"
        await pilot.press("ctrl+right")      # wrap forwards
        assert app.query_one("#content").current == "dashboard"


async def test_ctrl_arrows_work_from_focused_table() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("ctrl+right")
        assert app.query_one("#content").current == "dotfiles"


async def test_enter_still_opens_focused_card() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("right")
        await pilot.press("enter")
        assert app.query_one("#content").current == "dotfiles"


async def test_hidden_card_focus_does_not_walk_or_teleport() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")          # leave dashboard; hidden card keeps focus
        await pilot.pause()
        await pilot.press("down")       # must NOT walk the hidden grid
        await pilot.press("enter")      # must NOT teleport
        assert app.query_one("#content").current == "provision"
