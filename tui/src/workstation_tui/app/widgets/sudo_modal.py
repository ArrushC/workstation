"""Password overlay for the sudo gate (spec §Execution engine).

The password lives only in the Input widget and the validator call — never
on the app, never in a model, never logged.
"""

from typing import Callable

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Static

from workstation_tui.app.theme import M, muted


class SudoModal(ModalScreen[bool]):
    DEFAULT_CSS = f"""
    SudoModal {{
        align: center middle;
    }}
    #sudo-box {{
        width: 60;
        height: auto;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #sudo-error {{
        color: {M['red']};
        height: auto;
    }}
    """

    BINDINGS = [("escape", "dismiss_false", "Cancel")]

    def __init__(self, *, validator: Callable[[str], bool]) -> None:
        super().__init__()
        self._validator = validator

    def compose(self) -> ComposeResult:
        with Vertical(id="sudo-box"):
            yield Static(f"[bold {M['mauve']}]sudo password required[/]", markup=True)
            yield Static(muted("privileged make targets need a valid sudo timestamp"),
                         markup=True)
            yield Input(password=True, placeholder="password", id="sudo-input")
            yield Static("", id="sudo-error", markup=False)

    def on_mount(self) -> None:
        self.query_one("#sudo-input", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        password = event.value
        self.run_worker(lambda: self._check(password), thread=True, exclusive=True)

    def _check(self, password: str) -> None:
        ok = self._validator(password)
        self.app.call_from_thread(self._apply, ok)

    def _apply(self, ok: bool) -> None:
        if ok:
            self.dismiss(True)
        else:
            self.query_one("#sudo-error", Static).update(
                "authentication failed — try again"
            )
            field = self.query_one("#sudo-input", Input)
            field.value = ""
            field.focus()

    def action_dismiss_false(self) -> None:
        self.dismiss(False)
