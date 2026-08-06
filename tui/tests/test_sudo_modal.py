from textual.app import App

from workstation_tui.app.widgets.sudo_modal import SudoModal


class Host(App):
    def __init__(self, validator):
        super().__init__()
        self.validator = validator
        self.result: bool | None = None

    def on_mount(self) -> None:
        # push_screen_wait requires a WORKER context — on_mount is not one.
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(SudoModal(validator=self.validator))


async def test_correct_password_dismisses_true() -> None:
    app = Host(lambda pw: pw == "hunter2")
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"hunter2")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
    assert app.result is True


async def test_wrong_password_shows_error_and_retries() -> None:
    attempts: list[str] = []

    def validator(pw: str) -> bool:
        attempts.append(pw)
        return pw == "right"

    app = Host(validator)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"wrong")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        # Textual 8.2.8 adaptation: App.query_one() targets only the base
        # `default_screen`, never the active modal on top of the stack
        # (see App._get_dom_base), so widgets inside SudoModal are only
        # reachable via app.screen (the current top-of-stack screen).
        error = str(app.screen.query_one("#sudo-error").content)
        assert "authentication failed" in error
        await pilot.press(*"right")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
    assert attempts == ["wrong", "right"]
    assert app.result is True


async def test_escape_dismisses_false() -> None:
    app = Host(lambda pw: True)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is False
