# Workstation TUI — Phase 3 (Textual Shell + Dashboard) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Textual application shell — mocha theme port, sidebar-rail layout, key navigation — with a live read-only Dashboard panel, and make bare `workstation` launch it.

**Architecture:** `app/` gains `theme.py` (a faithful port of the user's AtcomSearch `mocha_theme.py`, same public API), `app.py` (`WorkstationApp`: header, sidebar nav, `ContentSwitcher` content area, key-bar footer), and `panels/` (a live `DashboardPanel` + placeholder panels for Provision/Dotfiles/Fleet/Health, which later phases replace). Data comes exclusively from Phase 2's `gather_summary` via an injectable provider, fetched in a worker thread. `core/` remains Textual-free; `cli.py` imports the app lazily so headless subcommands never pay the Textual import.

**Tech Stack:** Python ≥3.14, Textual 8.x (env tracks latest — currently 8.2.8), click, pydantic v2, pytest + pytest-asyncio (Pilot tests), uv.

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` §Theming, §The five screens (layout A), §Code architecture. The user's `mocha_theme.py` source is reproduced in Task 1 — it is the porting ground truth.

## Global Constraints

- Branch: `feat/workstation-tui-phase3` (created off main). Push after every commit. PR at the end targets main.
- Nothing under `tui/src/workstation_tui/core/` may import `textual`. `app/` may.
- `theme.py` keeps the source module's public API names EXACTLY: `M`, `EXTRA`, `ROLE`, `CORE_CSS`, `BAR_CSS`, `PANEL_CSS`, `HOME_CSS`, `LAYOUT_CSS`, `LOG_CSS`, `INPUT_CSS`, `MODAL_CSS`, `MOCHA_CSS`, `keycap`, `kb`, `action_line`, `tab_label`, `tab_bar`, `field`, `heading`, `muted`, `status_msg`, `TASK_ICONS`, `SEL_ON`, `SEL_OFF`, `YES`, `NO`, `NA`, `icon`, `sel_marker`, `bool_marker`, `count_text`. Dropped (AtcomSearch-specific): `TYPE_COLOUR`, `FILE_ICONS`, `FILE_STATUS`, `SIZE_WARN_BYTES`, `size_style`, the `__main__` preview app. Added (workstation vocabulary): `STAMP_ICONS`, `HOST_ICONS`.
- The 20 `M` hex values and the `ROLE` mapping are copied byte-exact from the user's module — never "corrected".
- CSS fragments keep every CLASS selector and widget selector from the source; AtcomSearch-specific `#id` selectors are replaced by workstation ids (`#app-header`, `#sidebar`, `#content`, `#key-bar`) — the sanctioned adaptation.
- The app must boot cleanly on the pinned Textual (8.x): the Pilot boot test doubles as the stylesheet-compatibility check the spec requires (component classes like `datatable--header` fail loudly at mount if stale).
- All UI data flows through the injectable `summary_provider` / `context_provider` — Pilot tests NEVER hit real make/chezmoi.
- Tests: `cd tui && uv run pytest -q`. Suite enters at 62 passed.
- Pre-commit invariant hook must stay green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: Theme port (`app/theme.py`)

**Files:**
- Create: `tui/src/workstation_tui/app/__init__.py`
- Create: `tui/src/workstation_tui/app/theme.py`
- Test: `tui/tests/test_theme.py`

**Interfaces:**
- Produces: every name in the Global Constraints API list, importable as `from workstation_tui.app.theme import M, ROLE, MOCHA_CSS, kb, …`. `STAMP_ICONS: dict[str, tuple[str, str]]` keyed exactly `"fresh"/"stale"/"missing"` (matching `StampState` values); `HOST_ICONS` keyed `"up"/"down"/"unknown"`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_theme.py`:

```python
from workstation_tui.app.theme import (
    HOST_ICONS,
    M,
    MOCHA_CSS,
    ROLE,
    STAMP_ICONS,
    TASK_ICONS,
    icon,
    kb,
    keycap,
    muted,
)
from workstation_tui.core.models import StampState


def test_palette_is_verbatim_catppuccin_mocha() -> None:
    assert len(M) == 20
    assert M["base"] == "#1e1e2e"
    assert M["mauve"] == "#cba6f7"
    assert M["green"] == "#a6e3a1"
    assert M["overlay0"] == "#6c7086"


def test_role_semantics() -> None:
    assert ROLE["title"] == M["mauve"]
    assert ROLE["accent"] == M["blue"]
    assert ROLE["danger"] == M["red"]
    assert ROLE["muted"] == M["overlay0"]


def test_markup_helpers() -> None:
    assert keycap("q") == f"[bold {M['blue']} on {M['surface0']}] q [/]"
    bar = kb(("q", "Quit"), ("g", "Refresh"))
    assert "Quit" in bar and "Refresh" in bar
    assert muted("x") == f"[{M['overlay0']}]x[/]"


def test_icon_fallback_and_task_icons() -> None:
    assert icon("running").plain == "⟳"
    assert icon("nonsense").plain == "?"
    assert set(TASK_ICONS) == {"pending", "running", "done", "failed"}


def test_workstation_vocabulary_covers_stamp_states() -> None:
    assert set(STAMP_ICONS) == {s.value for s in StampState}
    assert STAMP_ICONS["fresh"] == ("✓", M["green"])
    assert STAMP_ICONS["stale"] == ("⟳", M["yellow"])
    assert STAMP_ICONS["missing"] == ("✗", M["red"])
    assert set(HOST_ICONS) == {"up", "down", "unknown"}


def test_css_bundle_composes() -> None:
    assert "App, Screen" in MOCHA_CSS
    assert M["base"] in MOCHA_CSS
    assert "#key-bar" in MOCHA_CSS
```

- [ ] **Step 2: Run to verify failure** — `cd tui && uv run pytest tests/test_theme.py -q` → ModuleNotFoundError.

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/app/__init__.py`:

```python
"""Textual layer — the only place allowed to import textual."""
```

`tui/src/workstation_tui/app/theme.py` — port of the user's AtcomSearch `mocha_theme.py` (same public API; `TYPE_COLOUR`/`FILE_ICONS`/`FILE_STATUS`/`SIZE_WARN_BYTES`/`size_style`/`__main__` preview dropped; `STAMP_ICONS`/`HOST_ICONS` added; AtcomSearch `#id`s in CSS swapped for workstation ids):

```python
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
```

- [ ] **Step 4: Run to verify pass** — `cd tui && uv run pytest tests/test_theme.py -q` → `6 passed`. Full suite → `68 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/app/ tui/tests/test_theme.py
git commit -m "feat(tui): mocha theme port (palette, CSS fragments, markup helpers, vocab)"
git push -u origin feat/workstation-tui-phase3
```

---

### Task 2: App shell — sidebar nav, placeholders, Pilot tests

**Files:**
- Create: `tui/src/workstation_tui/app/app.py`
- Create: `tui/src/workstation_tui/app/panels/__init__.py`
- Create: `tui/src/workstation_tui/app/panels/placeholder.py`
- Modify: `tui/pyproject.toml` (dev group + pytest-asyncio config)
- Test: `tui/tests/test_app_shell.py`

**Interfaces:**
- Consumes: `theme` (Task 1), `Summary`/`HostContext` models, `gather_summary`, `find_repo_root`.
- Produces: `WorkstationApp(App)` with constructor `WorkstationApp(*, summary_provider: Callable[[], Summary] | None = None)` (None → real `gather_summary(find_repo_root())`; a `find_repo_root()` of `None` raises `RuntimeError("workstation repo not found")` at provider call time). `PANELS: list[tuple[str, str]]` = `[("dashboard","Dashboard"),("provision","Provision"),("dotfiles","Dotfiles"),("fleet","Fleet"),("health","Health")]`. `PlaceholderPanel(Static)`. Key bindings: `1`-`5` switch panels, `g` refresh, `q` quit. Task 3 replaces the dashboard placeholder with the live panel; Task 4 wires `cli.py` to `WorkstationApp`.

- [ ] **Step 1: Add the async test dependency**

In `tui/pyproject.toml`: change the dev group to `dev = ["pytest", "pytest-asyncio"]` and append:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

- [ ] **Step 2: Write the failing test**

`tui/tests/test_app_shell.py`:

```python
from workstation_tui.app.app import PANELS, WorkstationApp
from workstation_tui.core.models import HostContext, Summary

FAKE_SUMMARY = Summary(
    context=HostContext(
        os="linux", is_wsl=True, group="dev_machine", mode="dev",
        has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
    ),
    tools_total=108, tools_fresh=104, tools_stale=0, tools_missing=4,
    inventory_errors=[], dotfiles_pending=2, dotfiles_errors=[],
    hosts_total=9, hosts_dev=3, hosts_prod=6, hosts_errors=[],
)


def fake_provider() -> Summary:
    return FAKE_SUMMARY


async def test_app_boots_and_shows_sidebar() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.query_one("#sidebar") is not None
        assert app.query_one("#content").current == "dashboard"
        labels = [item.panel_id for item in app.query(".nav-item")]
        assert labels == [pid for pid, _ in PANELS]


async def test_number_keys_switch_panels() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        assert app.query_one("#content").current == "provision"
        await pilot.press("5")
        assert app.query_one("#content").current == "health"
        await pilot.press("1")
        assert app.query_one("#content").current == "dashboard"


async def test_placeholder_panels_name_their_phase() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        text = app.query_one("#dotfiles").render_str_content()
        assert "later phase" in text


async def test_q_quits() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
    assert app.return_code in (0, None)
```

NOTE for the implementer: `render_str_content` is a helper YOU add to `PlaceholderPanel` (returns its plain text) — Textual widgets don't expose a stable plain-text getter across versions; a one-line method on our own widget is sturdier than reaching into render internals.

- [ ] **Step 3: Run to verify failure** — ModuleNotFoundError (first run also installs pytest-asyncio into the ephemeral env).

- [ ] **Step 4: Implement**

`tui/src/workstation_tui/app/panels/__init__.py`:

```python
"""Panel widgets — one per sidebar entry. Later phases replace placeholders."""
```

`tui/src/workstation_tui/app/panels/placeholder.py`:

```python
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
```

`tui/src/workstation_tui/app/app.py`:

```python
"""WorkstationApp — the sidebar-rail shell (spec layout A)."""

from typing import Callable

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import ContentSwitcher, Static

from workstation_tui.app.panels.placeholder import PlaceholderPanel
from workstation_tui.app.theme import M, MOCHA_CSS, kb
from workstation_tui.core.models import Summary
from workstation_tui.core.summary import gather_summary
from workstation_tui.repo import find_repo_root

PANELS: list[tuple[str, str]] = [
    ("dashboard", "Dashboard"),
    ("provision", "Provision"),
    ("dotfiles", "Dotfiles"),
    ("fleet", "Fleet"),
    ("health", "Health"),
]

APP_CSS = f"""
#sidebar {{
    width: 14;
    background: {M['mantle']};
    padding: 1 0;
}}
.nav-item {{
    height: 1;
    padding: 0 1;
    color: {M['subtext0']};
}}
.nav-item.active {{
    color: {M['blue']};
    text-style: bold;
    background: {M['surface0']};
}}
#content {{
    padding: 0 1;
}}
"""


def _default_provider() -> Summary:
    root = find_repo_root()
    if root is None:
        raise RuntimeError("workstation repo not found")
    return gather_summary(root)


class NavItem(Static):
    def __init__(self, panel_id: str, label: str) -> None:
        super().__init__(f" {label}", classes="nav-item")
        self.panel_id = panel_id

    def on_click(self) -> None:
        self.app.switch_panel(self.panel_id)  # type: ignore[attr-defined]


class WorkstationApp(App):
    CSS = MOCHA_CSS + APP_CSS
    TITLE = "workstation"
    BINDINGS = [
        *[(str(i + 1), f"switch('{pid}')", label)
          for i, (pid, label) in enumerate(PANELS)],
        ("g", "refresh", "Refresh"),
        ("q", "quit", "Quit"),
    ]

    def __init__(self, *, summary_provider: Callable[[], Summary] | None = None) -> None:
        super().__init__()
        self.summary_provider = summary_provider or _default_provider
        self.summary: Summary | None = None

    def compose(self) -> ComposeResult:
        yield Static("", id="app-header", markup=True)
        with Horizontal(id="main"):
            with Vertical(id="sidebar"):
                for pid, label in PANELS:
                    yield NavItem(pid, label)
            with ContentSwitcher(initial="dashboard", id="content"):
                yield PlaceholderPanel("Dashboard", id="dashboard")
                yield PlaceholderPanel("Provision", id="provision")
                yield PlaceholderPanel("Dotfiles", id="dotfiles")
                yield PlaceholderPanel("Fleet", id="fleet")
                yield PlaceholderPanel("Health", id="health")
        yield Static(
            kb(("1-5", "Panels"), ("g", "Refresh"), ("q", "Quit")),
            id="key-bar", markup=True,
        )

    def on_mount(self) -> None:
        self._mark_active("dashboard")
        self.action_refresh()

    def switch_panel(self, panel_id: str) -> None:
        self.query_one("#content", ContentSwitcher).current = panel_id
        self._mark_active(panel_id)

    def action_switch(self, panel_id: str) -> None:
        self.switch_panel(panel_id)

    def action_refresh(self) -> None:
        self.run_worker(self._load_summary, thread=True, exclusive=True)

    def _load_summary(self) -> None:
        try:
            summary = self.summary_provider()
        except Exception as exc:  # surface, never crash the shell
            self.call_from_thread(self._show_header_error, str(exc))
            return
        self.call_from_thread(self._apply_summary, summary)

    def _apply_summary(self, summary: Summary) -> None:
        self.summary = summary
        c = summary.context
        wsl = " · WSL" if c.is_wsl else ""
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] "
            f"[{M['subtext0']}]— {c.os} · group={c.group or '?'} · "
            f"mode={c.mode}{wsl}[/]"
        )

    def _show_header_error(self, message: str) -> None:
        self.query_one("#app-header", Static).update(
            f"[bold {M['mauve']}]workstation[/] [{M['red']}]{message}[/]"
        )

    def _mark_active(self, panel_id: str) -> None:
        for item in self.query(NavItem):
            item.set_class(item.panel_id == panel_id, "active")
```

- [ ] **Step 5: Run to verify pass** — `cd tui && uv run pytest tests/test_app_shell.py -q` → `4 passed`. Full suite → `72 passed`. If Textual rejects any CSS selector at mount, the boot test fails loudly — fix the selector, do not silence it.

- [ ] **Step 6: Commit**

```bash
git add tui/src/workstation_tui/app/ tui/pyproject.toml tui/tests/test_app_shell.py
git commit -m "feat(tui): WorkstationApp shell — sidebar nav, placeholders, pilot tests"
git push
```

---

### Task 3: Live Dashboard panel

**Files:**
- Create: `tui/src/workstation_tui/app/panels/dashboard.py`
- Modify: `tui/src/workstation_tui/app/app.py` (swap the dashboard placeholder; feed it on refresh)
- Test: `tui/tests/test_dashboard.py`

**Interfaces:**
- Consumes: `Summary`, theme helpers, `WorkstationApp` internals from Task 2.
- Produces: `DashboardPanel(Static)` with `update_summary(summary: Summary) -> None` and focusable `Card(Static)` widgets (ids `card-provision`, `card-dotfiles`, `card-fleet`, `card-health`; Enter on a focused card switches to its panel). `WorkstationApp._apply_summary` additionally calls the dashboard's `update_summary`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_dashboard.py`:

```python
from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import FAKE_SUMMARY, fake_provider


async def test_dashboard_renders_summary_counts() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        panel = app.query_one("#dashboard")
        text = panel.summary_text()
        assert "104/108" in text          # fresh/total
        assert "2 pending" in text        # dotfiles
        assert "9" in text and "3 dev" in text and "6 prod" in text


async def test_dashboard_card_enter_jumps_to_panel() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.query_one("#card-dotfiles").focus()
        await pilot.press("enter")
        assert app.query_one("#content").current == "dotfiles"


async def test_dashboard_shows_reader_warnings() -> None:
    bad = FAKE_SUMMARY.model_copy(
        update={"inventory_errors": ["make inventory failed: boom"]}
    )
    app = WorkstationApp(summary_provider=lambda: bad)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert "make inventory failed" in app.query_one("#dashboard").summary_text()


async def test_refresh_calls_provider_again() -> None:
    calls = []

    def counting_provider():
        calls.append(1)
        return FAKE_SUMMARY

    app = WorkstationApp(summary_provider=counting_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        first = len(calls)
        assert first >= 1
        await pilot.press("g")
        await pilot.pause()
        assert len(calls) > first
```

NOTE: `summary_text()` is a plain-text helper you add to `DashboardPanel` (concatenation of what the cards display) — same rationale as `render_str_content` in Task 2.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/app/panels/dashboard.py`:

```python
"""Read-only dashboard: one live summary card per domain."""

from textual.app import ComposeResult
from textual.containers import Grid
from textual.widgets import Static

from workstation_tui.app.theme import M, STAMP_ICONS, heading, muted
from workstation_tui.core.models import Summary

CARD_TARGETS = {
    "card-provision": "provision",
    "card-dotfiles": "dotfiles",
    "card-fleet": "fleet",
    "card-health": "health",
}

DASHBOARD_CSS = f"""
DashboardPanel {{
    padding: 1 1;
}}
#cards {{
    grid-size: 2 2;
    grid-gutter: 1 2;
    height: auto;
}}
.card {{
    padding: 1 2;
    background: {M['surface0']};
    border: solid {M['surface1']};
    height: auto;
}}
.card:focus {{
    border: solid {M['blue']};
}}
#dashboard-warnings {{
    color: {M['yellow']};
    padding: 0 2;
    height: auto;
}}
"""


class Card(Static, can_focus=True):
    BINDINGS = [("enter", "open", "Open panel")]

    def __init__(self, card_id: str) -> None:
        super().__init__("", id=card_id, classes="card", markup=True)
        self.plain = ""

    def set_content(self, markup: str, plain: str) -> None:
        self.plain = plain
        self.update(markup)

    def action_open(self) -> None:
        self.app.switch_panel(CARD_TARGETS[self.id])  # type: ignore[attr-defined]


class DashboardPanel(Static):
    DEFAULT_CSS = DASHBOARD_CSS

    def compose(self) -> ComposeResult:
        with Grid(id="cards"):
            for card_id in CARD_TARGETS:
                yield Card(card_id)
        yield Static("", id="dashboard-warnings", markup=False)

    def on_mount(self) -> None:
        for card in self.query(Card):
            card.set_content(muted("loading…"), "loading…")

    def update_summary(self, s: Summary) -> None:
        fresh_icon, fresh_col = STAMP_ICONS["fresh"]
        stale_icon, stale_col = STAMP_ICONS["stale"]
        miss_icon, miss_col = STAMP_ICONS["missing"]
        prov_plain = (f"{s.tools_fresh}/{s.tools_total} fresh · "
                      f"{s.tools_stale} stale · {s.tools_missing} missing")
        self._card("card-provision").set_content(
            heading("Provision") + "\n"
            f"[{fresh_col}]{fresh_icon} {s.tools_fresh}/{s.tools_total} fresh[/]\n"
            f"[{stale_col}]{stale_icon} {s.tools_stale} stale[/] · "
            f"[{miss_col}]{miss_icon} {s.tools_missing} missing[/]",
            prov_plain,
        )
        dot_plain = f"{s.dotfiles_pending} pending"
        dot_col = M["yellow"] if s.dotfiles_pending else M["green"]
        self._card("card-dotfiles").set_content(
            heading("Dotfiles") + f"\n[{dot_col}]{dot_plain}[/]",
            dot_plain,
        )
        fleet_plain = f"{s.hosts_total} hosts · {s.hosts_dev} dev · {s.hosts_prod} prod"
        self._card("card-fleet").set_content(
            heading("Fleet") + f"\n[{M['text']}]{s.hosts_total} hosts[/]\n"
            f"[{M['subtext0']}]{s.hosts_dev} dev · {s.hosts_prod} prod[/]",
            fleet_plain,
        )
        health_plain = "checks arrive in a later phase"
        self._card("card-health").set_content(
            heading("Health") + "\n" + muted(health_plain),
            health_plain,
        )
        warnings = [*s.inventory_errors, *s.dotfiles_errors, *s.hosts_errors]
        self.query_one("#dashboard-warnings", Static).update(
            "\n".join(f"warning  {w}" for w in warnings)
        )
        self._warnings_plain = "\n".join(warnings)

    def summary_text(self) -> str:
        parts = [card.plain for card in self.query(Card)]
        parts.append(getattr(self, "_warnings_plain", ""))
        return " · ".join(p for p in parts if p)

    def _card(self, card_id: str) -> Card:
        return self.query_one(f"#{card_id}", Card)
```

In `app.py`: import `DashboardPanel`, replace `PlaceholderPanel("Dashboard", id="dashboard")` with `DashboardPanel(id="dashboard")` (give `DashboardPanel.__init__` no custom signature — pass `id` through to `Static` via `super().__init__(id=id)`; add a thin `__init__(self, *, id: str)` if needed), and extend `_apply_summary` to also call `self.query_one("#dashboard", DashboardPanel).update_summary(summary)`.

- [ ] **Step 4: Run to verify pass** — `cd tui && uv run pytest tests/test_dashboard.py tests/test_app_shell.py -q` (the Task 2 placeholder test for dashboard no longer applies — `test_app_shell.py` only asserted placeholders for `#dotfiles`, which still holds). Full suite → `76 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/app/ tui/tests/test_dashboard.py
git commit -m "feat(tui): live dashboard panel with summary cards"
git push
```

---

### Task 4: Bare `workstation` launches the TUI

**Files:**
- Modify: `tui/src/workstation_tui/cli.py`
- Modify: `tui/tests/test_cli.py`

**Interfaces:**
- Consumes: `WorkstationApp` (lazy import inside the command body — headless subcommands must not import textual).
- Produces: bare `workstation` on a TTY launches the app; on a non-TTY prints `workstation: the TUI needs a terminal — see --help for headless commands.` to stderr and exits 1.

- [ ] **Step 1: Update the bare-invocation test**

In `tui/tests/test_cli.py` replace `test_bare_invocation_is_placeholder` with:

```python
def test_bare_invocation_without_tty_errors() -> None:
    # CliRunner streams are not TTYs, so the bare command must refuse
    # cleanly instead of launching Textual.
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 1
    assert "needs a terminal" in result.output


def test_bare_invocation_launches_app_on_tty(monkeypatch) -> None:
    # CliRunner swaps sys.stdout during invoke, so patch the SEAM
    # (_stdout_isatty), never sys.stdout itself.
    import workstation_tui.cli as cli

    launched = []
    monkeypatch.setattr(cli, "_stdout_isatty", lambda: True)
    monkeypatch.setattr(cli, "_launch_tui", lambda: launched.append(True))
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 0
    assert launched == [True]
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `cli.py`**

Replace the bare-invocation body of `main` and add the launcher seam:

```python
def _stdout_isatty() -> bool:
    # Seam: CliRunner swaps sys.stdout during invoke, so the TTY check must
    # read it at call time AND be patchable as cli._stdout_isatty in tests.
    return sys.stdout.isatty()


def _launch_tui() -> None:
    # Lazy import: headless subcommands never pay the textual import.
    from workstation_tui.app.app import WorkstationApp

    WorkstationApp().run()


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="workstation")
@click.pass_context
def main(ctx: click.Context) -> None:
    """Workstation control panel — TUI + headless subcommands."""
    if ctx.invoked_subcommand is None:
        if not _stdout_isatty():
            click.echo(
                "workstation: the TUI needs a terminal — "
                "see --help for headless commands.",
                err=True,
            )
            sys.exit(1)
        _launch_tui()
```

- [ ] **Step 4: Run to verify pass** — full suite → `77 passed`. Live smoke (real TTY): run `~/.local/bin/workstation` in the terminal, confirm the shell renders (sidebar, header identity line, dashboard numbers), press `2`/`3` to see placeholders, `g` refresh, `q` quits cleanly. Capture a one-line note of what you saw (this is the only manual step; Pilot covers the logic).

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/cli.py tui/tests/test_cli.py
git commit -m "feat(tui): bare workstation launches the Textual app (TTY-gated)"
git push
```

---

### Task 5: Docs + gate + PR

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (one row)
- Modify: `tui/src/workstation_tui/core/chezmoi.py` (ride-along carry-forward: docstring note)

- [ ] **Step 1: CLAUDE_CHANGELOG.md** — append:

```markdown
| workstation TUI Phase 3: Textual shell (mocha theme port, sidebar rail, live dashboard); bare `workstation` now launches the TUI on a TTY | No | README §tui still lands with the final phase; headless CLI unchanged |
```

- [ ] **Step 2: chezmoi.py docstring** (carry-forward from Phase 2's final review) — append one sentence to the module docstring: `Chezmoi surfaces deliberately ignore WORKSTATION_REPO: reads and mutations always target the user's real chezmoi-configured source, never an override.`

- [ ] **Step 3: Full gate**

```bash
make -C makefile lint MODE=prod
make -C makefile tui-test MODE=prod     # expect 77 passed
bash scripts/check-templates.sh
```

- [ ] **Step 4: Commit + PR**

```bash
git add CLAUDE_CHANGELOG.md tui/src/workstation_tui/core/chezmoi.py
git commit -m "docs: phase-3 changelog row + chezmoi WORKSTATION_REPO note"
git push
gh pr create --base main --title "feat(tui): workstation TUI Phase 3 — Textual shell + dashboard" --body "$(cat <<'EOF'
Phase 3 of the workstation TUI (spec §Theming + §screens, layout A):

- mocha_theme.py port: 20-key palette, ROLE map, composable CSS fragments,
  keycap/kb markup helpers, status vocabulary + workstation stamp/host icons
- WorkstationApp shell: sidebar rail, ContentSwitcher panels, key nav (1-5/g/q),
  worker-thread summary refresh, header identity line
- live Dashboard panel: focusable summary cards (Enter jumps to panel),
  reader warnings surfaced; Provision/Dotfiles/Fleet/Health placeholders
- bare `workstation` launches the TUI on a TTY (clean refusal otherwise);
  headless subcommands unchanged, textual imported lazily
- Pilot test suite (pytest-asyncio): boot, nav, dashboard, refresh, quit

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01UfFaGAdVaLjVVrnq4jNJ9p
EOF
)"
gh pr checks --watch
```

Hand the PR to the user for review/merge.
