"""HostFormModal charset validation (Finding 2).

Follows the same `push_screen_wait`-from-a-worker harness as
test_sudo_modal.py (push_screen_wait needs a worker context, not
on_mount directly) and its `app.screen.query_one(...)` convention for
reaching widgets inside the active modal (app.query_one() only targets
the base screen — see that file's comment).
"""

from textual.app import App

from workstation_tui.app.widgets.host_form import HostFormModal
from workstation_tui.core.models import HostEntry

_UNSUBMITTED = "not-submitted"  # sentinel distinct from a real None/HostEntry result


class Host(App):
    def __init__(self, *, initial: HostEntry | None = None) -> None:
        super().__init__()
        self._initial = initial
        self.result: HostEntry | None | str = _UNSUBMITTED

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(HostFormModal(initial=self._initial))


async def _fill(pilot, app, *, name, address="10.0.0.1", user="me", group="prod_machine"):
    screen = app.screen
    screen.query_one("#host-form-name").value = name
    screen.query_one("#host-form-address").value = address
    screen.query_one("#host-form-user").value = user
    screen.query_one("#host-form-group").value = group
    screen.action_submit()
    await pilot.pause()


async def test_rejects_invalid_chars_field_named_error() -> None:
    # Covers all three shapes the task spec calls out (space, leading
    # dash, slash) plus one address- and one user-field case, in a single
    # test — each asserts the error names the OFFENDING field and that
    # nothing was dismissed (the modal stays open, app.result untouched).
    cases = [
        ("name", "bad name"),      # inner whitespace
        ("name", "-flag"),         # leading dash (option-injection shape)
        ("name", "web/01"),        # slash (hosts.conf field separator)
        ("address", "bad address"),
        ("user", "bad user"),
    ]
    for field, value in cases:
        app = Host()
        async with app.run_test() as pilot:
            await pilot.pause()
            kwargs = {"name": "ok", "address": "10.0.0.1", "user": "me"}
            kwargs[field] = value
            await _fill(pilot, app, **kwargs)
            error = str(app.screen.query_one("#host-form-error").content)
        assert error.startswith(f"{field}:"), f"{field}={value!r} -> {error!r}"
        assert app.result == _UNSUBMITTED, f"{field}={value!r} should not have submitted"


async def test_accepts_dotted_and_dashed_names() -> None:
    for name in ("web.01", "web-01"):
        app = Host()
        async with app.run_test() as pilot:
            await pilot.pause()
            await _fill(pilot, app, name=name)
        assert isinstance(app.result, HostEntry), f"{name!r} -> {app.result!r}"
        assert app.result.name == name
