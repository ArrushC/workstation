# WezTerm UX sweep — design

**Date:** 2026-07-09
**Status:** approved (brainstorm → design conversation, this session)
**Scope:** `chezmoi/dot_config/wezterm/wezterm.lua` (PR 1) + the `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` parity pair (PR 2)

## Context

The config already carries a mature UX layer: host-accent tabs, retro bottom bar,
right status (domain · zellij · line-count · battery · time · copied badge),
host picker, tab switcher, cheatsheet, reconnect binding, hyperlink→hx routing.
This sweep adds six feature groups selected in a two-round brainstorm.

Explicitly out of scope (previously tried and reverted, or declined):
Acrylic/translucency, any per-host render tuning (`max_fps` caps / OpenGL —
see `project_wezterm_render_webgpu_120fps`), `wezterm.gui.*` at config load
(see `project_wezterm_no_gui_calls_at_config_load`), font-zoom window pinning,
`check_for_updates=false`. Nothing in this sweep touches the render block or
the `HOSTS` sentinel.

## Delivery

Two PRs:

1. **PR 1 — wezterm.lua-only sweep** — features 1–5 below, plus cheatsheet
   rows, README keybind-table updates, changelog rows.
2. **PR 2 — semantic prompt zones** — feature 6: OSC 133 emission in the rc
   parity pair + the dependent WezTerm key/mouse bindings. Separate because
   the rc pair has its own tripwires (parity, `check-templates.sh`) and
   deserves independent revert.

## Feature 1 — Background-tab activity indicators

- `format-tab-title`: on **inactive** tabs only, prefix the label with:
  - an accent-colored `●` when `tab.active_pane.has_unseen_output` is true;
  - a bell glyph (`wezterm.nerdfonts.md_bell` / `󰂞`) when the pane rang BEL
    since the tab was last active.
- Bell tracking: `wezterm.on('bell', ...)` records the pane's tab id in a
  `bell_at` table; `format-tab-title` clears the entry when rendering the tab
  as active. (Mirrors the existing `copied_at` pattern.)
- **No WezTerm toast on bell.** `~/.claude/notify.sh` already fires a
  BurntToast toast + BEL for Claude Code notifications; a WezTerm toast would
  double-notify. The tab marker is the *visual* channel; notify.sh keeps the
  toast + audio channels.
- Marker colors: `●` in the tab's host accent (falls back to `mocha.peach`
  for local); bell glyph in `mocha.peach`.
- **Known risk:** Zellij redraws its UI inside SSH tabs, which may keep
  `has_unseen_output` perpetually true there. Plan: ship everywhere,
  live-test on the Windows clone; if SSH tabs are permanently dotted,
  restrict the output-dot (NOT the bell marker) to local/WSL panes.

## Feature 2 — Polish bundle

- **ALT+1..9**: generate the nine `ActivateTab` bindings in a loop, replacing
  the four hand-written entries. Cheatsheet row updates `ALT+1..4` → `1..9`.
- **`window_close_confirmation = 'NeverPrompt'`**: same rationale as the
  existing tab-close no-confirm — remote Zellij sessions survive and reattach.
- **Config-reloaded toast**: `window-config-reloaded` →
  `window:toast_notification('WezTerm', 'Config reloaded', nil, 1500)`.
  Fires on CTRL+SHIFT+R *and* auto-reload on file save (that's fine — it makes
  silent auto-reloads visible too).
- **`quick_select_patterns`**: add `\b\d{1,3}(\.\d{1,3}){3}\b` (IPv4 — covers
  the 10.21.x.x host fleet) and `#\d+` (PR/issue refs). Defaults (URLs,
  paths, hashes) are preserved — the option appends, not replaces.
- **Command palette parity**: `augment-command-palette` handler returning
  entries for: Connect to host (pick_host), Switch tab (pick_tab), Reconnect
  SSH pane, Rename tab, Copy entire scrollback, Show help/cheatsheet.

## Feature 3 — Icons + status coherence

- **Domain-type glyphs** in `format-tab-title`, before the index: SSH domains
  `wezterm.nerdfonts.md_ssh` (`󰣀`), WSL domains `wezterm.nerdfonts.fa_linux`
  (``), local `wezterm.nerdfonts.md_console` (``). Rendered in the tab's
  fg color; part of the label text, so no layout change beyond +2 cells.
- **Host-accent domain in right status**: the SSH-domain name part reuses
  `host_hash`/`HOST_ACCENTS` for its fg color, matching the tab accent.
- **Clock with day-of-week**: `%a %H:%M` (`Wed 14:32`) at ≥60 cols; bare
  `%H:%M` below.
- **Battery auto-hide**: hidden when state is `Full` (or 100% and not
  charging); still shown while charging or discharging.

## Feature 4 — Copy/search mode badge

- `render_right_status` reads `window:active_key_table()`:
  `copy_mode` → bold `mocha.yellow` `COPY`, `search_mode` → bold `mocha.sky`
  `SEARCH`, prepended as the leftmost part.
- Latency: up to ~1s (status tick) to appear/clear — same cadence as the rest
  of the bar; acceptable.

## Feature 5 — Scrollback → Helix (CTRL+SHIFT+O)

- New keybind CTRL+SHIFT+O (`O` = open; not a WezTerm default binding).
- Action callback:
  1. `pane:get_lines_as_text(dims.scrollback_rows)` → write to
     `%TEMP%\wezterm-scrollback-<pane_id>.txt` (Lua `io` runs Windows-side).
  2. Route by domain, mirroring the `open-uri` handler:
     - **local** → `SpawnCommandInNewTab { args = { 'hx', <win path> } }`
       (hx.exe is on the User PATH via the portable Helix install).
     - **WSL:*** → same file, opened in the SAME WSL domain at the translated
       `/mnt/c/...` path (deterministic `C:\` → `/mnt/c/`, backslash→slash,
       drive lowercased).
     - **SSH domain** → `window:toast_notification` "Zellij owns scrollback
       in SSH tabs" and return (WezTerm's buffer there is just alt-screen).
- Temp files are per-pane and overwritten on reuse; no cleanup needed beyond
  OS temp policy.

## Feature 6 — Semantic prompt zones (PR 2)

- **rc side** (both `dot_zshrc.tmpl` and `dot_bashrc.tmpl`, same commit —
  parity pair): emit OSC 133 marks, gated the same way as the existing
  `__wezterm_osc7` helper so non-WezTerm terminals aren't polluted:
  - `A` (prompt start) — zsh `precmd` / bash `PROMPT_COMMAND` (before PS1);
  - `B` (prompt end / input start) — end of PS1;
  - `C` (command start) — zsh `preexec` / bash `PS0`;
  - `D;<exit>` (command end) — start of the next `precmd`/`PROMPT_COMMAND`.
- **WezTerm side**:
  - `CTRL+SHIFT+UpArrow`/`DownArrow` → `ScrollToPrompt(-1/1)`. These override
    default pane-navigation assignments that Zellij makes redundant
    (Left/Right pane-nav defaults are left untouched).
  - `CTRL+triple-click` → `SelectTextAtMouseCursor 'SemanticZone'` (select a
    whole command's output). Plain triple-click keeps its default line-select.
- Scope honesty: benefits WSL, local, and raw-`ssh` panes. Inert inside
  SSH+Zellij tabs (alt-screen — same boundary as the line-count footer).
- Cheatsheet + README rows for both bindings.

## Error handling

- All new event handlers are additive registrations (WezTerm composes
  multiple handlers per event — precedent: update-status).
- Scrollback→hx: `io.open` failure → toast with the error, no tab spawned.
- Bell/unseen markers degrade to "no marker" if fields are absent (older
  WezTerm): guard with `and`-chains, never index into possibly-nil.
- OSC 133 emission is a no-op string print — no failure mode beyond a stray
  escape on terminals that ignore it (gating prevents even that).

## Testing / verification

- `luaparse` gate for wezterm.lua syntax (per `feedback_lua_syntax_use_luaparse_not_lsp`).
- `make -C makefile lint MODE=prod` (invariants incl. HOSTS sentinel intact) +
  `scripts/check-templates.sh` for the rc pair (PR 2).
- Live verification requires syncing the **Windows clone** (WezTerm reads it
  via `WEZTERM_CONFIG_FILE`) — a WSL-side edit is invisible until synced.
  Per-feature live checks:
  - background tab: run `printf '\a'` in tab 2, switch to tab 1 → bell glyph;
    `sleep 2 && echo hi` in tab 2 → unseen-output dot; activate → cleared.
  - ALT+5..9 jump; close window with 2+ tabs → no prompt; CTRL+SHIFT+R →
    toast; CTRL+SHIFT+Space → IPs/`#NN` selectable; CTRL+SHIFT+P lists the
    custom entries.
  - glyphs per domain type; right-status domain color matches tab; `Wed`
    prefix in clock; battery row vs charge state.
  - CTRL+SHIFT+X then check `COPY` badge; CTRL+SHIFT+F → `SEARCH`.
  - CTRL+SHIFT+O in a WSL tab → hx tab with scrollback; in an SSH tab → toast.
  - PR 2: in a WSL tab, run several commands, CTRL+SHIFT+↑ jumps prompts;
    CTRL+triple-click selects one command's output block.

## Documentation obligations

- README.html keybind table: CTRL+SHIFT+O, CTRL+SHIFT+↑/↓, CTRL+triple-click,
  ALT+1..9 update, window-close behavior note. Cheatsheet (`help_choices`)
  mirrors the same.
- CLAUDE_CHANGELOG.md: one row per PR.
- No new CLAUDE.md invariant expected; in-file comments carry the rationale
  (notify.sh no-toast coupling, Zellij unseen-output caveat).
