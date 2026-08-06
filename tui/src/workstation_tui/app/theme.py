"""theme.py — Catppuccin Mocha theme for the workstation TUI.

Port of the user's AtcomSearch mocha_theme.py with an identical public API
(palette M/EXTRA, ROLE semantics, composable CSS fragments, keycap/kb markup
helpers, status vocabulary), so patterns transfer 1:1 between the projects.
AtcomSearch-specific vocabulary (TYPE_COLOUR, FILE_ICONS, size warnings) is
dropped; workstation vocabulary (STAMP_ICONS, HOST_ICONS) is added.
"""

from typing import Dict, Sequence, Tuple

from rich.text import Text

# ══════════════════════════════════════════════════════════════════════════
#  1. Palette — exactly the 20 keys the source module defines. Do not rename.
# ══════════════════════════════════════════════════════════════════════════

M: Dict[str, str] = {
    # backgrounds, darkest → lightest
    "base":     "#1e1e2e",   # app/screen background
    "mantle":   "#181825",   # header, key-bar, logs, inputs
    "crust":    "#11111b",   # deepest — kept for parity
    "surface0": "#313244",   # panels, table header, cursor row, keycap fill
    "surface1": "#45475a",   # borders, splitters
    "surface2": "#585b70",
    # dim foregrounds, dimmest → brightest
    "overlay0": "#6c7086",   # placeholders, absent, "—", timestamps
    "overlay1": "#7f849c",
    "subtext0": "#a6adc8",   # field labels, secondary names
    "subtext1": "#bac2de",   # section headings, keycap label text
    "text":     "#cdd6f4",   # primary values
    # accents
    "blue":     "#89b4fa",   # interactive, keycaps, selection, progress
    "mauve":    "#cba6f7",   # titles, table column headers
    "sapphire": "#74c7ec",   # in-progress / transient info
    "teal":     "#94e2d5",
    "green":    "#a6e3a1",   # success / complete / ok
    "yellow":   "#f9e2af",   # caution / pending / stale
    "peach":    "#fab387",   # live monitoring / streaming
    "red":      "#f38ba8",   # failure / danger
    "maroon":   "#eba0ac",   # secondary error detail
}

EXTRA: Dict[str, str] = {
    "rosewater": "#f5e0dc",
    "flamingo":  "#f2cdcd",
    "pink":      "#f5c2e7",
    "lavender":  "#b4befe",
    "sky":       "#89dceb",
}

# ══════════════════════════════════════════════════════════════════════════
#  2. Semantic roles
# ══════════════════════════════════════════════════════════════════════════

ROLE: Dict[str, str] = {
    "title":      M["mauve"],
    "accent":     M["blue"],      # anything the user can press or has selected
    "progress":   M["sapphire"],  # "Scanning…", "Refreshing…"
    "success":    M["green"],
    "warn":       M["yellow"],
    "danger":     M["red"],
    "danger_alt": M["maroon"],    # error detail lines under a red headline
    "live":       M["peach"],     # watch / streaming modes
    "special":    M["teal"],      # one-off screen accents
    "label":      M["subtext0"],
    "heading":    M["subtext1"],
    "value":      M["text"],
    "muted":      M["overlay0"],
}

# ══════════════════════════════════════════════════════════════════════════
#  3. CSS — composable fragments (workstation ids; source classes kept)
# ══════════════════════════════════════════════════════════════════════════

CORE_CSS = f"""
App, Screen {{
    background: {M['base']};
    color: {M['text']};
}}
Header {{
    background: {M['mantle']};
    color: {M['mauve']};
    text-style: bold;
}}
DataTable {{
    background: {M['base']};
    color: {M['text']};
    height: 1fr;
}}
DataTable > .datatable--header {{
    background: {M['surface0']};
    color: {M['mauve']};
    text-style: bold;
}}
DataTable > .datatable--cursor {{
    background: {M['surface0']};
    color: {M['blue']};
}}
DataTable > .datatable--even-row {{
    background: {M['mantle']};
}}
"""

BAR_CSS = f"""
#key-bar, .key-bar {{
    background: {M['mantle']};
    color: {M['subtext0']};
    height: 1;
    padding: 0 1;
    dock: bottom;
}}
#app-header, .dim-bar {{
    height: 1;
    padding: 0 1;
    background: {M['mantle']};
}}
.bar {{
    height: 1;
    padding: 0 1;
    background: {M['surface0']};
}}
.info-block {{
    height: auto;
    padding: 0 1;
    background: {M['mantle']};
}}
"""

PANEL_CSS = f"""
.panel {{
    height: 1fr;
    margin: 1 2;
    padding: 1;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
.empty {{
    height: 1fr;
    content-align: center middle;
    color: {M['overlay0']};
}}
"""

HOME_CSS = f"""
.section-title {{
    height: 1;
    padding: 0 2;
    color: {M['subtext1']};
    text-style: bold;
}}
.section-body {{
    height: auto;
    padding: 0 2;
}}
"""

LAYOUT_CSS = f"""
#main, .h-split {{
    layout: horizontal;
    height: 1fr;
}}
Splitter {{
    width: 1;
    background: {M['surface1']};
}}
Splitter:hover {{
    background: {M['overlay0']};
}}
"""

LOG_CSS = f"""
RichLog {{
    background: {M['mantle']};
    height: 1fr;
}}
.log {{
    height: 1fr;
    background: {M['mantle']};
}}
ProgressBar {{
    margin: 0 1;
    height: 1;
}}
ProgressBar > .bar--bar {{
    color: {M['blue']};
}}
ProgressBar > .bar--complete {{
    color: {M['green']};
}}
"""

INPUT_CSS = f"""
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

MODAL_CSS = f"""
.modal {{
    align: center middle;
}}
.modal-box {{
    width: 70;
    height: auto;
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
}}
"""

MOCHA_CSS = (CORE_CSS + BAR_CSS + PANEL_CSS + HOME_CSS
             + LAYOUT_CSS + LOG_CSS + INPUT_CSS + MODAL_CSS)

# ══════════════════════════════════════════════════════════════════════════
#  4. Markup helpers
# ══════════════════════════════════════════════════════════════════════════


def keycap(key: str) -> str:
    """A single keycap badge: blue bold on surface0, padded one space each side."""
    return f"[bold {M['blue']} on {M['surface0']}] {key} [/]"


def kb(*pairs: Tuple[str, str]) -> str:
    """Render a key bar: [ Key ] Label   [ Key ] Label …"""
    parts = [f"{keycap(k)} [{M['subtext1']}]{lbl}[/]" for k, lbl in pairs]
    return "  " + "   ".join(parts)


def action_line(key: str, name: str, desc: str = "", name_w: int = 8) -> str:
    """One row of an action menu: badge, bold name, dim description."""
    return (f"  {keycap(key)}  [bold {M['text']}]{name:<{name_w}}[/]"
            f"  [{M['subtext0']}]{desc}[/]")


def tab_label(label: str, active: bool) -> str:
    """Tab strip entry — filled keycap style when active, dim when not."""
    return (f"[bold {M['blue']} on {M['surface0']}] {label} [/]"
            if active else f"[{M['subtext0']}] {label} [/]")


def tab_bar(items: Sequence[Tuple[str, str]], current: str) -> str:
    return "  " + "  ".join(tab_label(lbl, tid == current) for tid, lbl in items)


def field(name: str, value: str, value_col: str = "") -> str:
    """`label:` dim, value bright — the standard key/value line."""
    return f"  [{M['subtext0']}]{name}:[/] [{value_col or M['text']}]{value}[/]"


def heading(text: str) -> str:
    return f"[bold {M['subtext1']}]{text}[/]"


def muted(text: str) -> str:
    return f"[{M['overlay0']}]{text}[/]"


def status_msg(text: str, role: str = "value") -> str:
    """Status-bar line coloured by semantic role name (see ROLE)."""
    return f"  [{ROLE.get(role, M['text'])}]{text}[/]"


# ══════════════════════════════════════════════════════════════════════════
#  5. Status vocabulary
# ══════════════════════════════════════════════════════════════════════════

TASK_ICONS: Dict[str, Tuple[str, str]] = {
    "pending": ("·", M["overlay0"]),
    "running": ("⟳", M["blue"]),
    "done":    ("✓", M["green"]),
    "failed":  ("✗", M["red"]),
}

# Workstation vocabulary — keys match StampState values / probe states.
STAMP_ICONS: Dict[str, Tuple[str, str]] = {
    "fresh":   ("✓", M["green"]),
    "stale":   ("⟳", M["yellow"]),
    "missing": ("✗", M["red"]),
}

HOST_ICONS: Dict[str, Tuple[str, str]] = {
    "up":      ("✓", M["green"]),
    "down":    ("✗", M["red"]),
    "unknown": ("—", M["overlay0"]),
}

SEL_ON = ("●", M["blue"])
SEL_OFF = ("·", M["overlay0"])

YES = ("✓", M["green"])
NO = ("✗", M["red"])
NA = ("—", M["overlay0"])


def icon(state: str, table: Dict[str, Tuple[str, str]] = TASK_ICONS) -> Text:
    """Styled glyph for a state name, falling back to a dim '?'."""
    ch, col = table.get(state, ("?", M["overlay0"]))
    return Text(ch, style=col)


def sel_marker(selected: bool) -> Text:
    ch, col = SEL_ON if selected else SEL_OFF
    return Text(ch, style=col)


def bool_marker(value: bool, absent_is_good: bool = False) -> Text:
    """✓/✗ glyph. Set absent_is_good when False is the healthy state."""
    if value:
        ch, col = YES if not absent_is_good else (YES[0], M["yellow"])
    else:
        ch, col = NO if not absent_is_good else (YES[0], M["green"])
    return Text(ch, style=col)


def count_text(n: int, col: str) -> Text:
    """Non-zero counts coloured, zero rendered as a dim em dash."""
    return Text(str(n) if n else "—", style=col if n else M["overlay0"])
