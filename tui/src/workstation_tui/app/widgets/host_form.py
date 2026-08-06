"""Add/edit host overlay (spec §Generic widgets) — builds a validated HostEntry.

Four Inputs (name/address/user/group); the group field is a plain Input
constrained by re-validating through `HostEntry`'s `Literal["dev_machine",
"prod_machine"]` rather than a dedicated select widget. Enter in the last
field and `ctrl+s` from anywhere both submit; validation failures render
inline via `#host-form-error` (`markup=False` — pydantic error text is
arbitrary). `escape` cancels with `dismiss(None)`.

Finding 2: name/address/user are additionally charset-checked against
`_TOKEN_RE` (letters/digits/`.`/`_`/`-`, no leading `-`, no whitespace or
`/`) HERE, in the form, rather than on `HostEntry` itself. `HostEntry` is
also the READ-side model for existing `hosts.conf` rows (see
core/hostsfile.py) — this form is the only place a human TYPES a fresh
entry, so it's the right chokepoint. Tightening `HostEntry` instead would
risk rejecting legacy hosts.conf content that predates this guard, turning
a read into a crash.
"""

import re

from pydantic import ValidationError
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Static

from workstation_tui.app.theme import M
from workstation_tui.core.models import HostEntry

DEFAULT_GROUP = "prod_machine"

# name/address/user charset: alnum start (blocks leading '-', which ssh and
# manage-hosts.sh's option parsers would otherwise mistake for a flag), then
# alnum/'.'/'_'/'-' (blocks whitespace and '/', which would break shell-word
# splitting and hosts.conf's pipe-delimited row format respectively).
_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class HostFormModal(ModalScreen[HostEntry | None]):
    DEFAULT_CSS = f"""
    HostFormModal {{
        align: center middle;
    }}
    #host-form-box {{
        width: 60;
        height: auto;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #host-form-title {{
        color: {M['mauve']};
        text-style: bold;
        height: auto;
    }}
    #host-form-error {{
        color: {M['red']};
        height: auto;
    }}
    Input {{
        margin: 0 0 1 0;
        background: {M['mantle']};
        border: tall {M['surface1']};
        color: {M['text']};
        height: 3;
    }}
    Input:focus {{
        border: tall {M['blue']};
    }}
    """

    BINDINGS = [
        ("escape", "cancel", "Cancel"),
        ("ctrl+s", "submit", "Save"),
    ]

    def __init__(self, *, initial: HostEntry | None = None) -> None:
        super().__init__()
        self._initial = initial

    def compose(self) -> ComposeResult:
        initial = self._initial
        with Vertical(id="host-form-box"):
            yield Static(
                "edit host" if initial else "add host",
                id="host-form-title",
                markup=False,
            )
            yield Input(
                value=initial.name if initial else "",
                placeholder="name",
                id="host-form-name",
            )
            yield Input(
                value=initial.address if initial else "",
                placeholder="address",
                id="host-form-address",
            )
            yield Input(
                value=initial.user if initial else "",
                placeholder="user",
                id="host-form-user",
            )
            yield Input(
                value=initial.group if initial else DEFAULT_GROUP,
                placeholder="group (dev_machine / prod_machine)",
                id="host-form-group",
            )
            yield Static("", id="host-form-error", markup=False)

    def on_mount(self) -> None:
        self.query_one("#host-form-name", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "host-form-group":
            self.action_submit()

    def action_submit(self) -> None:
        name = self.query_one("#host-form-name", Input).value.strip()
        address = self.query_one("#host-form-address", Input).value.strip()
        user = self.query_one("#host-form-user", Input).value.strip()
        group = self.query_one("#host-form-group", Input).value.strip()
        error = self.query_one("#host-form-error", Static)

        if not (name and address and user and group):
            error.update("all fields are required")
            return

        for field_name, value in (("name", name), ("address", address), ("user", user)):
            if not _TOKEN_RE.match(value):
                error.update(
                    f"{field_name}: only letters, digits, '.', '_', '-' "
                    "allowed, and it must not start with '-'"
                )
                return

        try:
            entry = HostEntry(name=name, address=address, user=user, group=group)
        except ValidationError as exc:
            first = exc.errors()[0]
            loc = ".".join(str(part) for part in first["loc"])
            error.update(f"{loc}: {first['msg']}")
            return

        self.dismiss(entry)

    def action_cancel(self) -> None:
        self.dismiss(None)
