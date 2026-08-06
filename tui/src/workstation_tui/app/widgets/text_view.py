"""Scrollable read-only text overlay (spec §Generic widgets) — diffs, logs, help.

Body text is arbitrary (diff output, command output) and rendered with
`markup=False` so literal `[..]` sequences never get interpreted as Rich
markup.
"""

from textual.app import ComposeResult
from textual.containers import VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Static

from workstation_tui.app.theme import M


class TextViewScreen(ModalScreen[None]):
    DEFAULT_CSS = f"""
    TextViewScreen {{
        align: center middle;
    }}
    #text-view-box {{
        width: 90%;
        height: 90%;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #text-view-title {{
        color: {M['mauve']};
        text-style: bold;
        height: 1;
    }}
    #text-view-text {{
        color: {M['text']};
        height: auto;
    }}
    """

    BINDINGS = [
        ("escape", "close", "Close"),
        ("q", "close", "Close"),
    ]

    def __init__(self, text: str, *, title: str) -> None:
        super().__init__()
        self._text = text
        self._title = title

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="text-view-box"):
            yield Static(self._title, id="text-view-title", markup=False)
            yield Static(self._text, id="text-view-text", markup=False)

    def on_mount(self) -> None:
        self.query_one("#text-view-box", VerticalScroll).focus()

    def action_close(self) -> None:
        self.dismiss(None)
