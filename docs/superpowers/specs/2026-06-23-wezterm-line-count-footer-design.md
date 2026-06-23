# WezTerm — line-count readout in the right-status footer

**Date:** 2026-06-23
**Scope:** `chezmoi/dot_config/wezterm/wezterm.lua` (all edits outside the `HOSTS:START/END` sentinel block) + `README.html` + `CLAUDE_CHANGELOG.md` row. No Make/bootstrap/versions changes — pure config.
**Status:** Approved — every decision below was confirmed by the user via structured options (2026-06-23).

## Goal

Add a line-count readout to the WezTerm right-status footer (the bottom retro bar, next
to the battery/time block) for the **active** pane: how many lines of output the pane's
buffer holds, how many rows are visible on the monitor, and — when meaningful — which line
the cursor sits on.

## API grounding (why the feature is shaped the way it is)

WezTerm's Lua API exposes only three relevant quantities, all from methods callable on the
active pane inside the `update-status` handler:

- `pane:get_dimensions()` → `scrollback_rows` (total lines in scrollback **+** viewport),
  `viewport_rows` (rows visible on screen), `scrollback_top` (stable row index of the
  earliest remembered line), `physical_top`, `cols`.
- `pane:get_cursor_position()` → `.y`, a **stable row index** for the cursor.
- `pane:is_alt_screen_active()` → true while a full-screen TUI (Zellij, helix, less, htop,
  vim) owns the alternate screen.

**Two hard constraints, both confirmed against the WezTerm docs (2026-06-23):**

1. **The live scroll offset is NOT exposed.** There is no API for "how far the user has
   scrolled up into scrollback," and `update-status` does not fire on scroll (it is a
   periodic timer governed by `status_update_interval`, default ~1s). Therefore "lines
   currently displayed on the monitor" can only ever be the viewport **height**
   (`viewport_rows`), never a live "showing lines 4500–4538" range that tracks scrolling.
   That variant is simply not buildable in WezTerm and is out of scope.
2. **Alt-screen panes have no scrollback** — `scrollback_rows == viewport_rows` and the only
   thing that moves is the cursor row. Most of this workstation's SSH tabs run Zellij in the
   alternate screen, so a raw line-count readout there would be static noise. Hence the
   alt-screen suppression below.

## Decisions (user-confirmed 2026-06-23)

1. **Placement: active tab, in the right-status footer.** One readout reflecting the
   currently focused pane, rendered as a new `parts[]` entry inside the existing
   `render_right_status` (wezterm.lua ~lines 987–1077), updated at the existing ~1×/sec
   cadence. (Rejected: per-tab badges in every tab label, and "both" — too much clutter,
   and most per-tab numbers would be static Zellij noise.)
2. **Hidden in alt-screen tabs.** The module renders only on the main screen, where
   scrollback is meaningful (local/WSL shells, build logs, raw non-Zellij command output).
   In Zellij/TUI tabs the footer is unchanged from today (domain · zellij:main · battery ·
   time). (Rejected: an adapted "row 12/38" cursor ruler in alt-screen, and an
   always-same-format "38/38 · 38 rows".)
3. **Cursor position shown only when meaningful.** At a shell prompt the cursor sits on the
   last line, so a position number would read as ≈ total (10,234/10,234). Show
   `pos/total` only when the cursor is **not** on the last line (a main-screen program moved
   it up); otherwise show just the total. (Rejected: always show all three; drop the
   position entirely.)

## Behavior specification

Inside `render_right_status`, reusing the `dim_info = pane:get_dimensions()` already fetched
at the top of the function, plus `pane:is_alt_screen_active()` and
`pane:get_cursor_position()`:

**Visibility rule** — build the line-count part only when **all** hold:
- `not pane:is_alt_screen_active()` (skip Zellij/helix/less/htop/vim tabs), **and**
- `scrollback_rows > viewport_rows` (real scrollback exists — also suppresses the
  "38 · 38 rows" quirk on a fresh shell that hasn't produced a screenful yet), **and**
- `cols >= 100` (width gate — see below).

When the rule fails the module is simply absent and the footer renders exactly as today.

**Content** — with `total = scrollback_rows`, `rows = viewport_rows`, and
`pos = cursor.y - scrollback_top + 1` (1-based line within the buffer):
- cursor on the last line (`pos >= total`, i.e. at the prompt): `↕ 10,234 · 38 rows`
- cursor moved up by a main-screen program (`pos < total`): `↕ 9,800/10,234 · 38 rows`

`get_cursor_position()` is nil-guarded: if it returns nil, fall back to the
no-position form (`↕ total · rows`).

**Formatting**
- Icon: `↕` (U+2195). Separator: the existing ` · ` (`SEP`) and `FG_DIM` styling already in
  the function — the module reuses them, so it visually matches the battery/time block.
- Numbers: exact, thousands-grouped via a new local helper `group_thousands(n)` (Lua has no
  built-in), e.g. `10234` → `10,234`.
- Label wording: `<rows> rows` for the viewport count.

**Placement within the parts list** — inserted **immediately after the domain/`zellij:main`
block and before the battery entry**. Because the domain block is SSH-only, the line module
therefore *leads* the footer on local/WSL tabs (`↕ … · 🔋 … · 🌞 …`, no domain block) and
*follows* `domain` / `zellij:main` on the rare main-screen SSH tab. Among the adaptive
entries it is the **first to drop** as the window narrows: gated at `cols >= 100` (for
reference the existing gates are battery `>= 80`, zellij blob `>= 130`, time-icon `>= 60`).

**Free behaviors (no extra code)**
- The "Copied!" badge path (lines ~1059–1073) already replaces the entire right status with
  a width-matched centered badge for `COPIED_BADGE_DURATION` seconds, so it overlays the new
  module automatically.
- Width measurement: the module's text is appended to `plain` like every other part, so the
  existing `display_width(plain)` reservation and tab-layout logic account for it with no
  change.

## Files to touch

1. **`chezmoi/dot_config/wezterm/wezterm.lua`** — add the `group_thousands` helper (near the
   other right-status helpers `display_width` / `format_battery` / `time_icon`, ~lines
   945–977) and the visibility/content block inside `render_right_status`. All edits are
   OUTSIDE the `HOSTS:START/END` sentinel block. The file is read directly by the Windows
   host via `WEZTERM_CONFIG_FILE` and ignored on Linux (`.config/wezterm`), so the one edit
   covers both OSes — no parity pair.
2. **`chezmoi/dot_config/wezterm/wezterm.lua`** (same file) — add one `note` row to
   `help_choices` (the CTRL+SHIFT+H cheatsheet) describing the footer readout, e.g.
   `note  footer ↕      Active tab: total lines · rows shown (hidden in full-screen apps)`.
3. **`README.html`** — the WezTerm section: a sentence noting the footer now shows the active
   pane's line count (total · rows, with cursor position when a program moves it), hidden in
   full-screen apps. User-visible footer surface → README per CLAUDE.md.
4. **`CLAUDE_CHANGELOG.md`** — append a row.

No CLAUDE.md invariant and no `docs/claude/file-care.md` change: no new cross-file coupling
(the module is self-contained in one function), and `wezterm.lua` is already a listed
careful-edit file.

## Risks / verification

- **Lua syntax** — no `wezterm`/`lua` binary on this WSL host. Parse-check with the
  `luaparse` npm package via the available node toolchain (node 26.3.0), the same method
  used by the 2026-06-11 chrome-polish spec.
- **Sentinel intact** — `HOSTS:START/END` block byte-identical after edits.
- **LF preserved** — `file chezmoi/dot_config/wezterm/wezterm.lua` must not report CRLF;
  mode stays 100644.
- **Live behavior** (user, on the Windows host after `CTRL+SHIFT+R` reload):
  - a local/WSL tab with >1 screenful of output shows `↕ <total> · <rows> rows` next to
    battery/time; running a pager-free command that scrolls grows the total.
  - a Zellij SSH tab shows the footer exactly as before (no line module).
  - narrowing the window below ~100 cols drops the line module first.
  - the "Copied!" badge (CTRL+SHIFT+C with a selection) still overlays cleanly.
