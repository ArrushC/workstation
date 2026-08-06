from textual.app import App

from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.host_form import HostFormModal
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.models import HostEntry


class Host(App):
    def __init__(self, screen_factory):
        super().__init__()
        self.screen_factory = screen_factory
        self.result = "UNSET"

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(self.screen_factory())


async def test_confirm_yes_and_no() -> None:
    app = Host(lambda: ConfirmModal("apply these changes? [/tricky] markup"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert app.result is True

    app = Host(lambda: ConfirmModal("sure?"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is False


async def test_text_view_dismisses() -> None:
    app = Host(lambda: TextViewScreen("line1\n[/not-markup]\nline3", title="diff"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is None


async def test_host_form_submit_and_validation() -> None:
    app = Host(lambda: HostFormModal())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"box1")          # name field focused first
        await pilot.press("tab")
        await pilot.press(*"10.0.0.5")
        await pilot.press("tab")
        await pilot.press(*"me")
        await pilot.press("tab")            # group field, default prod_machine kept
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.pause()
    assert app.result == HostEntry(name="box1", address="10.0.0.5", user="me",
                                   group="prod_machine")


async def test_host_form_rejects_bad_group_then_escape() -> None:
    app = Host(lambda: HostFormModal())
    async with app.run_test() as pilot:
        await pilot.pause()
        for _ in range(3):
            await pilot.press("x")
            await pilot.press("tab")
        await pilot.press(*"staging")       # invalid group
        await pilot.press("ctrl+s")
        await pilot.pause()
        error = str(app.screen.query_one("#host-form-error").content)
        assert "group" in error.lower()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is None


async def test_host_form_prefill() -> None:
    initial = HostEntry(name="old", address="1.2.3.4", user="u", group="dev_machine")
    app = Host(lambda: HostFormModal(initial=initial))
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.screen.query_one("#host-form-name").value == "old"
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.pause()
    assert app.result == initial
