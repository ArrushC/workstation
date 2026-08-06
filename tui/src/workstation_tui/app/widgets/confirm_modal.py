"""Generic yes/no confirmation overlay (spec §Generic widgets).

Message text is arbitrary (diff summaries, warnings) and rendered with
`markup=False` — it may contain literal `[..]` sequences that must not be
interpreted as Rich markup.
"""

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Static

from workstation_tui.app.theme import M


class ConfirmModal(ModalScreen[bool]):
    DEFAULT_CSS = f"""
    ConfirmModal {{
        align: center middle;
    }}
    #confirm-box {{
        width: 60;
        height: auto;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #confirm-title {{
        color: {M['mauve']};
        text-style: bold;
        height: auto;
    }}
    #confirm-message {{
        height: auto;
        padding: 1 0;
        color: {M['text']};
    }}
    """

    BINDINGS = [
        ("y", "confirm", "Yes"),
        ("n", "reject", "No"),
        ("escape", "reject", "Cancel"),
    ]

    def __init__(self, message: str, *, title: str = "confirm") -> None:
        super().__init__()
        self._message = message
        self._title = title

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box"):
            yield Static(self._title, id="confirm-title", markup=False)
            yield Static(self._message, id="confirm-message", markup=False)

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_reject(self) -> None:
        self.dismiss(False)
