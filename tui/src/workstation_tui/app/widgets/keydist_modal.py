"""Guided key-distribution picker (spec §3, Task 6).

A `SelectionList` of fleet hosts, preselected to whichever hosts most need
it (their last setup probe came back `"ssh-failed"`) — the exact
`ssh-copy-id` targets a user opening this modal is most likely to want.
Each row's prompt is a plain `Text` (never markup — host names are
USER-TYPED, same discipline `panels/fleet.py`'s DataTable cells already
follow), so `SelectionList` never markup-parses a hostile stored name.

`enter` is bound here as a `priority=True` Binding — without it,
`SelectionList`'s OWN inherited `enter` binding (from `OptionList`, which
toggles the highlighted row) wins over a same-key ModalScreen-level
binding while the list holds focus, and `action_confirm` below would
never fire (confirmed empirically: a non-priority same-key Screen binding
is shadowed by a focused child widget's own binding). `space` is left
untouched — that's `SelectionList`'s own built-in per-row toggle.
"""

from pathlib import Path

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import SelectionList, Static
from textual.widgets.selection_list import Selection

from workstation_tui.app.theme import HOST_ICONS, M, SETUP_ICONS, icon
from workstation_tui.core.models import HostEntry


class KeyDistModal(ModalScreen[list[str] | None]):
    DEFAULT_CSS = f"""
    KeyDistModal {{
        align: center middle;
    }}
    #keydist-box {{
        width: 70;
        height: auto;
        max-height: 90%;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #keydist-title {{
        color: {M['mauve']};
        text-style: bold;
        height: auto;
    }}
    #keydist-header {{
        height: auto;
        padding: 0 0 1 0;
        color: {M['subtext0']};
    }}
    #keydist-list {{
        height: auto;
        max-height: 20;
    }}
    """

    BINDINGS = [
        ("a", "toggle_all", "Toggle all"),
        Binding("enter", "confirm", "Confirm", priority=True),
        ("escape", "cancel", "Cancel"),
    ]

    def __init__(
        self,
        hosts: list[HostEntry],
        probe_states: dict[str, tuple[str, str | None]],
        key_present: bool,
    ) -> None:
        super().__init__()
        self._hosts = hosts
        self._probe_states = probe_states
        self._key_present = key_present

    def compose(self) -> ComposeResult:
        key_path = Path.home() / ".ssh" / "id_ed25519.pub"
        status = (
            "present"
            if self._key_present
            else "MISSING — the script will offer to generate one"
        )
        with Vertical(id="keydist-box"):
            yield Static(
                "distribute ssh keys", id="keydist-title", markup=False
            )
            yield Static(
                f"key: {key_path} — {status}",
                id="keydist-header",
                markup=False,
            )
            selections = []
            for entry in self._hosts:
                state, setup_state = self._probe_states.get(
                    entry.name, ("unknown", None)
                )
                prompt = Text(f"{entry.name}  ")
                prompt.append(icon(state, HOST_ICONS))
                prompt.append(icon(setup_state or "unknown", SETUP_ICONS))
                selections.append(
                    Selection(prompt, entry.name, setup_state == "ssh-failed")
                )
            yield SelectionList(*selections, id="keydist-list")

    def on_mount(self) -> None:
        self.query_one("#keydist-list", SelectionList).focus()

    def action_toggle_all(self) -> None:
        """`all selected -> clear, else select all` (spec §3) — NOT
        `SelectionList.toggle_all()`, which flips each row's OWN state
        individually (a mixed selection would end up mixed again, not
        cleared/full)."""
        selection_list = self.query_one("#keydist-list", SelectionList)
        if len(selection_list.selected) == selection_list.option_count:
            selection_list.deselect_all()
        else:
            selection_list.select_all()

    def action_confirm(self) -> None:
        selected = self.query_one("#keydist-list", SelectionList).selected
        if not selected:
            self.notify("no hosts selected", severity="warning")
            return
        self.dismiss(list(selected))

    def action_cancel(self) -> None:
        self.dismiss(None)
