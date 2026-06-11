# WezTerm — borderless chrome + appearance/behavior polish

**Date:** 2026-06-11
**Scope:** `chezmoi/dot_config/wezterm/wezterm.lua` (all edits outside the `HOSTS:START/END` sentinel block) + `README.html` keybind table + `CLAUDE_CHANGELOG.md` row. No Make/bootstrap/versions changes — pure config.
**Status:** Approved — every decision below was confirmed by the user via structured options (2026-06-11); implemented in the same session.

## Goal

Remove the OS window borders/title bar from the WezTerm window without breaking Windows
window management, and land a set of polish tweaks the user selected from a proposed menu.

## Decisions (user-confirmed 2026-06-11)

1. **Window chrome: `RESIZE` + drag-to-move bindings** (chosen over fully-borderless `NONE`,
   integrated-buttons fancy mode, and keep-title-bar). The retro branch of
   `config.window_decorations` flips `'TITLE | RESIZE'` → `'RESIZE'`: no title bar, but the
   invisible thin resize frame stays, so Win+Arrow snap, drag-to-edge snap, mouse resize, and
   minimize keep working. `'NONE'` was explicitly rejected — the in-file comment (from past
   testing) records that it breaks Win+Arrow snap, minimize, and mouse resizing. Because the
   retro tab bar sits at the BOTTOM there is no built-in drag area, so two `StartWindowDrag`
   mouse bindings are added (the canonical pair from wezterm.org's `window_decorations` docs):
   `CTRL|SHIFT`+Left-drag and `SUPER`(Win)+Left-drag. `StartWindowDrag` hands off to the OS
   move loop, so drag-to-edge snapping still works. The fancy branch
   (`INTEGRATED_BUTTONS|RESIZE`) is unchanged.
2. **Polish — all four selected:**
   - **Themed fuzzy overlays:** `command_palette_bg_color = mocha.crust`,
     `command_palette_fg_color = mocha.text`, `command_palette_font_size = 12.0`. These drive
     the command palette AND every `InputSelector` overlay (host picker `CTRL+SHIFT+J`, tab
     switcher `CTRL+SHIFT+S`, help `CTRL+SHIFT+H`, WSL distro picker) — the one surface that
     still rendered WezTerm's stock dark-gray.
   - **Acrylic translucency:** `win32_system_backdrop = 'Acrylic'` +
     `window_background_opacity = 0.92` (was `1.0`; backdrop is invisible at exactly 1.0).
     Win11 renders Acrylic well; Win10 can lag while dragging. Silently ignored off Windows.
   - **Visual bell:** brief cursor-color flash on BEL (`target = 'CursorColor'`, eased by the
     existing `animation_fps = 120`), flash color `colors.visual_bell = mocha.peach` (distinct
     from the mauve cursor). Complements `~/.claude/notify.sh`, which rings the terminal bell
     for Claude Code notifications — visible cue even when muted. The audible bell is
     deliberately untouched (an addition, NOT a replacement — notify.sh depends on BEL).
   - **Bigger initial window:** `initial_cols = 140`, `initial_rows = 38` (default 80×24 is
     cramped and below the 130-col threshold where the right status shows the zellij blob).
3. **Behavior — two of four selected:**
   - **`switch_to_last_active_tab_when_closing_tab = true`** — closing a tab returns to the
     last-active tab, not the adjacent one.
   - **Cheatsheet built-ins:** new `help_choices` rows for default bindings the help omitted —
     `CTRL+SHIFT+F` (search scrollback), `CTRL+SHIFT+Space` (quick-select), `CTRL+SHIFT+P`
     (command palette), `F11` (fullscreen) — plus the two new drag-to-move bindings.
   - *Rejected by user:* `adjust_window_size_when_changing_font_size = false` (pin window size
     on font zoom) and `check_for_updates = false` (silence update toasts).

## Files to touch

1. **`chezmoi/dot_config/wezterm/wezterm.lua`** — all edits above. Everything is OUTSIDE the
   `HOSTS:START/END` sentinel block. Consumed only by the Windows host (via
   `WEZTERM_CONFIG_FILE`); Linux ignores `.config/wezterm`.
2. **`README.html`** — §setup-wezterm: lede gains a sentence about the removed title bar; the
   keybind table gains a `CTRL+SHIFT+drag / WIN+drag → move window` row. (New user-facing
   keybind + changed window interaction → README per CLAUDE.md; the pure-appearance tweaks
   need no README per the "What does NOT need a README update" list.)
3. **`CLAUDE_CHANGELOG.md`** — append a row.

No CLAUDE.md invariant: no new cross-file coupling — the drag-binding ↔ no-title-bar pairing
is documented in-file, and `wezterm.lua` is already a careful-edit file. No
`docs/claude/file-care.md` change.

## Risks / verification

- **Lua syntax** — no `wezterm` or `lua` binary on this WSL host; parse-check with the
  `luaparse` npm package via the available node toolchain.
- **Sentinel intact** — `HOSTS:START/END` block byte-identical after edits.
- **LF preserved** — `file` must not report CRLF.
- **Live behavior** (user, on the Windows host after `CTRL+SHIFT+R` reload): title bar gone,
  `CTRL+SHIFT`/`WIN`+drag moves the window, Win+Arrow snap works, Acrylic blur visible,
  pickers Mocha-themed, `printf '\a'` flashes the cursor peach.
