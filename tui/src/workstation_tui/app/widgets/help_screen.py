"""Help overlay showing all keybindings (spec §Generic widgets).

Static keymap reference built from theme markup helpers (kb/action_line).
Content is safe to markup=True since it's all from theme constants.
"""

from textual.app import ComposeResult
from textual.containers import VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Static

from workstation_tui.app.theme import M, action_line, heading, kb


class HelpScreen(ModalScreen[None]):
    DEFAULT_CSS = f"""
    HelpScreen {{
        align: center middle;
    }}
    #help-box {{
        width: 90%;
        height: 90%;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #help-title {{
        color: {M['mauve']};
        text-style: bold;
        height: 1;
    }}
    #help-content {{
        color: {M['text']};
        height: auto;
    }}
    """

    BINDINGS = [
        ("escape", "close", "Close"),
        ("q", "close", "Close"),
        ("?", "close", "Close"),
    ]

    def compose(self) -> ComposeResult:
        content = "\n".join([
            # Global keys
            heading("Global Keys"),
            action_line("1-5", "Panels"),
            action_line("g", "Refresh"),
            action_line("q", "Quit"),
            action_line("?", "Help"),
            "",
            # Provision panel
            heading("Provision"),
            action_line("r", "Run", "run selected tool"),
            action_line("c", "Clean", "clean and reinstall"),
            action_line("u", "Updates", "check for updates"),
            action_line("R", "Full", "full provision"),
            action_line("x", "Cancel", "cancel task"),
            "",
            # Dotfiles panel
            heading("Dotfiles"),
            action_line("a", "Apply", "apply pending changes"),
            action_line("U", "Update", "update from git"),
            action_line("A", "Re-add", "re-add selected file"),
            action_line("d", "Diff", "view full diff"),
            "",
            # Fleet panel
            heading("Fleet"),
            action_line("s", "SSH", "ssh to selected host"),
            action_line("p", "Push", "push to selected host"),
            action_line("P", "Push all", "push to all hosts"),
            action_line("a", "Add", "add new host"),
            action_line("e", "Edit", "edit selected host"),
            action_line("x", "Remove", "remove host"),
            "",
            # Health panel
            heading("Health"),
            action_line("↵", "Run", "run selected check"),
            action_line("R", "Run all", "run all available checks"),
            action_line("o", "Open log", "view full health log"),
        ])

        with VerticalScroll(id="help-box"):
            yield Static("Workstation TUI — Keyboard Help", id="help-title", markup=True)
            yield Static(content, id="help-content", markup=True)

    def on_mount(self) -> None:
        self.query_one("#help-box", VerticalScroll).focus()

    def action_close(self) -> None:
        self.dismiss(None)
