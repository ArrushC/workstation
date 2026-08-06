from textual.widgets import Static

from workstation_tui.app.theme import muted


class PlaceholderPanel(Static):
    """Stand-in for a panel that arrives in a later phase."""

    def __init__(self, title: str, *, id: str) -> None:  # noqa: A002 - Textual API
        self._title = title
        self._text = f"{title} — arrives in a later phase."
        super().__init__(muted(self._text), id=id, classes="empty")

    def render_str_content(self) -> str:
        return self._text
