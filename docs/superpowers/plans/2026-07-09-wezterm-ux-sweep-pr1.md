# WezTerm UX Sweep — PR 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add background-tab activity indicators, a polish bundle (ALT+1..9, window-close no-confirm, reload toast, quick-select patterns), domain glyphs + status coherence, a copy/search mode badge, a scrollback→Helix keybind, and command-palette parity — all inside `chezmoi/dot_config/wezterm/wezterm.lua`.

**Architecture:** Single-file Lua config sweep. All changes are additive event handlers / config keys / small refactors of existing helpers, outside the `HOSTS:START/END` sentinel. Spec: `docs/superpowers/specs/2026-07-09-wezterm-ux-sweep-design.md` (PR 2 — OSC 133 — is a separate plan, written after PR 1 lands).

**Tech Stack:** WezTerm Lua config (pinned WezTerm 20240203-110809-5046fc22), luaparse syntax gate, repo `make lint`.

## Global Constraints

- **Branch:** work on `wezterm-ux-sweep` (already exists, spec committed on it).
- **NEVER call `wezterm.gui.*` at config-parse time** — deadlocks WezTerm (memory `project-wezterm-no-gui-calls-at-config-load`). Event handlers are fine.
- **NEVER touch the render block** (`front_end`/`webgpu_power_preference`/`render_fps` — memory `project-wezterm-render-webgpu-120fps`).
- **NEVER edit between `-- HOSTS:START` and `-- HOSTS:END`.**
- **Syntax gate after every wezterm.lua edit:** `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua` must print `SYNTAX OK`. Do NOT use the LSP tool for Lua (memory `feedback-lua-syntax-use-luaparse-not-lsp`). If `/tmp/lua-syntax-check` is missing, recreate it: `mkdir -p /tmp/lua-syntax-check && cd /tmp/lua-syntax-check && npm init -y >/dev/null && npm install luaparse@^0.3.1 >/dev/null` and write `check.js`:
  ```js
  const fs = require('fs'), luaparse = require('luaparse');
  try { luaparse.parse(fs.readFileSync(process.argv[2], 'utf8'), { luaVersion: '5.3' }); console.log('SYNTAX OK'); }
  catch (e) { console.error('SYNTAX ERROR: ' + e.message); process.exit(1); }
  ```
- **Repo lint before every commit:** `make -C makefile lint MODE=prod` from repo root `/home/arrush.chaturvedi/.local/share/chezmoi` — must end `all invariant checks passed`. (The pre-commit hook runs it anyway; running it first avoids failed commits.)
- **No live-GUI verification in this plan's tasks** — WezTerm reads the *Windows clone* via `WEZTERM_CONFIG_FILE`; live checks happen after merge/sync (spec §Testing). Each task's gate is syntax + lint only.
- There is **no unit-test harness** for wezterm.lua; the repo precedent (line-count-footer plan) is luaparse + lint + a live checklist. TDD steps are therefore "syntax-gate fails/passes" shaped.
- All file paths below are relative to `/home/arrush.chaturvedi/.local/share/chezmoi`.

---

### Task 1: Activity indicators (bell marker + unseen-output dot) + `host_accent` helper

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (three regions: after `host_hash`, inside `tab_colors`, inside `format-tab-title`)

**Interfaces:**
- Produces: `local function host_accent(host)` → returns a Catppuccin hex string (accent for a host name, `mocha.mauve` for nil/local). Used again in Task 3.
- Produces: `bell_panes` table + `wezterm.on('bell', ...)` handler (self-contained).

- [ ] **Step 1: Add the `host_accent` helper and refactor `tab_colors` to use it**

Find (immediately after the `host_hash` function's closing `end`, before the `LOCAL_HOSTNAME` comment block):

```lua
local function host_hash(name)
  local h = 0
  for i = 1, #name do
    h = (h * 131 + name:byte(i)) % 65521
  end
  return h
end
```

Append directly below it:

```lua
-- Accent hex for a host name (HOST_ACCENTS bucket via host_hash); mauve for
-- nil (local tabs) — the same mauve identity as the cursor + active local tab.
-- Single source for tab_colors, the tab activity dot, and the right-status
-- domain color.
local function host_accent(host)
  if not host then return mocha.mauve end
  return HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1]
end
```

Then inside `tab_colors`, replace:

```lua
    local accent = wezterm.color.parse(HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1])
```

with:

```lua
    local accent = wezterm.color.parse(host_accent(host))
```

- [ ] **Step 2: Add bell tracking state + handler**

Insert immediately BEFORE the `wezterm.on('format-tab-title', ...)` line (after the `tab_colors` function's closing `end`):

```lua
-- Bell markers — pane_id → true when BEL rang in that pane. format-tab-title
-- clears the mark when it renders the tab as ACTIVE, so the glyph survives
-- exactly until the tab is next viewed. Deliberately NO toast here:
-- ~/.claude/notify.sh already fires a BurntToast Windows toast + this same
-- BEL for Claude Code notifications — a WezTerm toast would double-notify.
-- The tab marker is the visual channel; notify.sh keeps toast + audio.
local bell_panes = {}

wezterm.on('bell', function(_window, pane)
  bell_panes[pane:pane_id()] = true
end)

-- Nerd Font glyphs (JetBrainsMono NF ships the md_/fa_ sets). Defensive
-- fallbacks: a nil table key would crash string concat at render time.
local nf = wezterm.nerdfonts or {}
local GLYPH_BELL = nf.md_bell or '🔔'
```

- [ ] **Step 3: Compute + render the markers in `format-tab-title`**

Inside the `format-tab-title` handler, find:

```lua
  local label = string.format(' %d: %s ', idx, title)
```

Replace with:

```lua
  -- Activity markers — INACTIVE tabs only. '●' = unseen output since last
  -- viewed; bell glyph = BEL rang in the pane (Claude Code notify.sh, remote
  -- printf '\a', finished builds). Cleared when the tab is activated. Bell
  -- outranks the dot (a bell also produces output). Known Zellij caveat:
  -- SSH+Zellij tabs redraw their UI, which can keep has_unseen_output
  -- permanently true — if live testing confirms, gate the DOT (never the
  -- bell) on non-SSH domains; see the spec's fallback plan.
  local marker
  if tab.is_active then
    bell_panes[pane.pane_id] = nil
  elseif bell_panes[pane.pane_id] then
    marker = GLYPH_BELL
  elseif pane.has_unseen_output then
    marker = '●'
  end

  local label = string.format('%d: %s ', idx, title)
```

(Note: `pane` here is the existing `local pane = tab.active_pane` — a
PaneInformation table, so `.pane_id`/`.has_unseen_output` are FIELDS; the
bell handler's live Pane object uses the `:pane_id()` METHOD.)

Then find the item-assembly block:

```lua
  local bg, fg = tab_colors(host, tab.is_active, hover)
  local items = {
    { Background = { Color = bg } },
    { Foreground = { Color = fg } },
  }
  if tab.is_active then
    table.insert(items, { Attribute = { Intensity = 'Bold' } })
  end
  table.insert(items, { Text = label })
  return items
```

Replace with:

```lua
  local bg, fg = tab_colors(host, tab.is_active, hover)
  local items = { { Background = { Color = bg } } }
  -- Leading space + optional marker; the marker carries its own fg (host
  -- accent for the dot, peach for the bell) against the tab bg.
  if marker then
    local mfg = (marker == GLYPH_BELL) and mocha.peach or host_accent(host)
    table.insert(items, { Foreground = { Color = mfg } })
    table.insert(items, { Text = ' ' .. marker .. ' ' })
  else
    table.insert(items, { Text = ' ' })
  end
  table.insert(items, { Foreground = { Color = fg } })
  if tab.is_active then
    table.insert(items, { Attribute = { Intensity = 'Bold' } })
  end
  table.insert(items, { Text = label })
  return items
```

- [ ] **Step 4: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): background-tab activity markers (unseen-output dot + bell glyph)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Polish — ALT+1..9, window-close no-confirm, config-reload toast, quick-select patterns

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (near `switch_to_last_active_tab_when_closing_tab`; the ALT entries in `config.keys`; after `config.keys`' closing brace)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: `window_close_confirmation` + quick-select patterns**

Find:

```lua
config.switch_to_last_active_tab_when_closing_tab = true
```

Append directly below:

```lua
-- Closing the WINDOW never prompts either — same rationale as the
-- no-confirm tab close (CTRL+SHIFT+W): SSH tabs run inside remote Zellij
-- sessions that survive and reattach; local/WSL shells hold no state worth
-- a modal.
config.window_close_confirmation = 'NeverPrompt'

-- Extra quick-select atoms (CTRL+SHIFT+Space) — APPENDED to the built-in
-- URL/path/hash patterns, not replacing them: IPv4 addresses (the
-- 10.21.x.x host fleet) and #NN PR/issue refs.
config.quick_select_patterns = {
  [[\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b]],
  [[#\d+]],
}
```

- [ ] **Step 2: ALT+1..9 loop**

In `config.keys`, find and DELETE:

```lua
  -- Jump to tab by number
  { key = '1', mods = 'ALT', action = act.ActivateTab(0) },
  { key = '2', mods = 'ALT', action = act.ActivateTab(1) },
  { key = '3', mods = 'ALT', action = act.ActivateTab(2) },
  { key = '4', mods = 'ALT', action = act.ActivateTab(3) },
```

Then find the closing of the keys table (the lines after the four
`DisableDefaultAssignment` SUPER-arrow entries):

```lua
  { key = 'DownArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
}
```

Replace with:

```lua
  { key = 'DownArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
}

-- Jump to tab by number — ALT+1..9. README.html's keybind table already
-- documents 1..9; this loop makes the config match it (was 1..4).
for i = 1, 9 do
  table.insert(config.keys, {
    key = tostring(i), mods = 'ALT', action = act.ActivateTab(i - 1),
  })
end
```

- [ ] **Step 3: Config-reloaded toast**

Insert after the ALT loop added in Step 2:

```lua
-- Feedback for CTRL+SHIFT+R and silent auto-reloads on file save: a brief
-- toast confirms the new config actually loaded (a Lua error surfaces
-- WezTerm's own error window instead — so silence means it didn't apply).
-- The first fire per window is (or may be) window creation, not a reload;
-- swallow it so launching WezTerm doesn't toast. If live testing shows the
-- event does NOT fire at creation, the cost is one swallowed toast on the
-- first real reload per window — acceptable; re-check live and simplify if so.
local config_reload_seen = {}
wezterm.on('window-config-reloaded', function(window, _pane)
  local wid = window:window_id()
  if not config_reload_seen[wid] then
    config_reload_seen[wid] = true
    return
  end
  window:toast_notification('WezTerm', 'Config reloaded', nil, 1500)
end)
```

- [ ] **Step 4: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): polish — ALT+1..9, window-close no-confirm, reload toast, quick-select IPs/#refs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Domain glyphs + right-status coherence (accent domain, day-of-week clock, battery auto-hide)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (glyph constants from Task 1's `nf` block; `format-tab-title`; `format_battery`; `render_right_status`)

**Interfaces:**
- Consumes: `nf` table + glyph-constant pattern (Task 1), `host_accent(host)` (Task 1).

- [ ] **Step 1: Add the three domain glyph constants**

Find (added in Task 1):

```lua
local nf = wezterm.nerdfonts or {}
local GLYPH_BELL = nf.md_bell or '🔔'
```

Replace with:

```lua
local nf = wezterm.nerdfonts or {}
local GLYPH_BELL  = nf.md_bell    or '🔔'
-- Domain-type glyphs for tab titles: what kind of thing the pane is talking
-- to — an ssh session (domain tab OR embedded ssh detected in a WSL pane),
-- a WSL distro shell, or the local Nushell.
local GLYPH_SSH   = nf.md_ssh     or nf.fa_terminal or ''
local GLYPH_WSL   = nf.fa_linux   or ''
local GLYPH_LOCAL = nf.md_console or nf.fa_terminal or ''
```

- [ ] **Step 2: Prefix the glyph in `format-tab-title`**

Find (Task 1's version):

```lua
  local label = string.format('%d: %s ', idx, title)
```

Replace with:

```lua
  -- Domain-type glyph: ssh (incl. embedded ssh inside a WSL pane — the
  -- wsl_remote_host detection above), WSL distro shell, or local.
  local glyph
  if is_wsl then
    glyph = wsl_remote_host and GLYPH_SSH or GLYPH_WSL
  elseif host then
    glyph = GLYPH_SSH
  else
    glyph = GLYPH_LOCAL
  end
  local label = string.format('%s %d: %s ', glyph, idx, title)
```

- [ ] **Step 3: Host-accent domain color in the right status**

In `render_right_status`, find:

```lua
  if domain and domain ~= 'local' and not domain:find('^WSL:') then
    table.insert(parts, { text = domain })
```

Replace with:

```lua
  if domain and domain ~= 'local' and not domain:find('^WSL:') then
    -- Same accent as the tab (host_accent shares the HOST_ACCENTS bucket) —
    -- the status bar and tab bar agree on which host you're looking at.
    table.insert(parts, { text = domain, fg = host_accent(domain) })
```

- [ ] **Step 4: Day-of-week clock**

In `render_right_status`, find:

```lua
    table.insert(parts, { text = time_icon() .. ' ' .. wezterm.strftime('%H:%M') })
```

Replace with:

```lua
    table.insert(parts, { text = time_icon() .. ' ' .. wezterm.strftime('%a %H:%M') })
```

(The narrow `< 60` cols branch keeps bare `%H:%M`.)

- [ ] **Step 5: Battery auto-hide when full**

In `format_battery`, find:

```lua
  local pct = math.floor((b.state_of_charge or 0) * 100 + 0.5)
```

Append directly below:

```lua
  -- Fully charged = zero information — hide the module. Still shown while
  -- charging (progress) or actively discharging (drain rate matters).
  if b.state == 'Full' or (pct >= 100 and b.state ~= 'Discharging') then
    return nil
  end
```

- [ ] **Step 6: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 7: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): domain glyphs in tabs + accent domain, day-of-week clock, battery auto-hide in status

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Copy/search mode badge in the right status

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (`render_right_status`)

**Interfaces:**
- Consumes: the `parts` list convention in `render_right_status` (`{ text, fg?, bold? }`).

- [ ] **Step 1: Add the badge as the leftmost part**

In `render_right_status`, find:

```lua
  -- Each part: { text = string, fg = '#hex' (optional), bold = bool (optional) }
  local parts = {}
```

Append directly below:

```lua
  -- Modal-state badge — copy mode / search overlay are otherwise invisible.
  -- window:active_key_table() reports the built-in modal tables
  -- ('copy_mode' / 'search_mode'). Read on the ~1s status tick; up to a
  -- tick of latency to appear/clear — same cadence as the whole bar.
  local key_table = window:active_key_table()
  if key_table == 'copy_mode' then
    table.insert(parts, { text = 'COPY', fg = mocha.yellow, bold = true })
  elseif key_table == 'search_mode' then
    table.insert(parts, { text = 'SEARCH', fg = mocha.sky, bold = true })
  end
```

- [ ] **Step 2: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): COPY/SEARCH mode badge in right status

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Scrollback → Helix (CTRL+SHIFT+O)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (new callback after `copy_and_announce`; new entry in `config.keys`)

**Interfaces:**
- Produces: `local scrollback_to_helix` (a `wezterm.action_callback` value) — referenced again by Task 6's palette.

- [ ] **Step 1: Add the callback**

Find the end of the `copy_and_announce` block:

```lua
local copy_and_announce = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if not sel or #sel == 0 then return end
  window:perform_action(act.CopyTo 'Clipboard', pane)
  copied_at[window:window_id()] = os.time()
  render_right_status(window, pane)
end)
```

Append directly below:

```lua
-- ---------------------------------------------------------------------------
-- Scrollback → Helix — dump the pane's scrollback to a temp file, open in hx
-- ---------------------------------------------------------------------------
-- Bound to CTRL|SHIFT+O below (O = open); also in the command palette.
-- Complements CTRL+SHIFT+A (copy to clipboard): same text, but landed in an
-- editor with search/jump instead. Routing mirrors the open-uri handler:
--   • local pane → hx.exe (on the User PATH via the portable Helix install)
--     opening the Windows temp path.
--   • WSL pane   → hx inside the SAME distro, opening the /mnt/c translation
--     of that temp path (Lua io runs on the Windows side, so the file is
--     written under %TEMP% either way).
--   • SSH pane   → toast and bail: WezTerm's buffer for an SSH+Zellij tab is
--     just the alt screen; Zellij owns the real scrollback there.
-- Per-pane filename, overwritten on reuse; cleanup is OS temp policy's job.
local scrollback_to_helix = wezterm.action_callback(function(window, pane)
  local domain = pane:get_domain_name() or ''
  local is_wsl = domain:find('^WSL:') ~= nil
  if domain ~= 'local' and not is_wsl then
    window:toast_notification('WezTerm',
      'Zellij owns scrollback in SSH tabs — use its search there', nil, 4000)
    return
  end
  local dims   = pane:get_dimensions()
  local nlines = (dims and dims.scrollback_rows) or 10000
  local text   = pane:get_lines_as_text(nlines)
  local tmp    = (os.getenv('TEMP') or os.getenv('TMP') or '.')
    .. '\\wezterm-scrollback-' .. pane:pane_id() .. '.txt'
  local f, err = io.open(tmp, 'w')
  if not f then
    window:toast_notification('WezTerm',
      'Scrollback dump failed: ' .. tostring(err), nil, 4000)
    return
  end
  f:write(text)
  f:close()
  local path = tmp
  if is_wsl then
    -- C:\Users\me\...\x.txt → /mnt/c/Users/me/.../x.txt
    path = tmp:gsub('\\', '/'):gsub('^(%a):', function(drive)
      return '/mnt/' .. drive:lower()
    end)
  end
  window:perform_action(
    act.SpawnCommandInNewTab {
      domain = { DomainName = domain },
      args   = { 'hx', path },
    },
    pane
  )
end)
```

- [ ] **Step 2: Bind CTRL+SHIFT+O**

In `config.keys`, find:

```lua
  -- Copy entire scrollback to clipboard (enters copy mode, selects all, copies, exits)
```

Insert directly ABOVE that comment:

```lua
  -- Dump scrollback to a temp file and open it in Helix (local/WSL panes;
  -- SSH panes toast — Zellij owns their scrollback). O = open.
  { key = 'o', mods = 'CTRL|SHIFT', action = scrollback_to_helix },

```

- [ ] **Step 3: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 4: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): CTRL+SHIFT+O opens scrollback in Helix (local/WSL; SSH toasts)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Command-palette parity (extract `rename_tab` + `copy_all_scrollback`, add `augment-command-palette`)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (extract two inline actions from `config.keys`; new handler before `config.keys`)

**Interfaces:**
- Consumes: `pick_host`, `pick_tab`, `reconnect_ssh_pane`, `show_help`, `scrollback_to_helix` (all already-defined locals), plus the two extracted here.

- [ ] **Step 1: Extract the two inline actions**

Insert directly BEFORE the `config.keys = {` line (after the
`scrollback_to_helix` block from Task 5):

```lua
-- Rename current tab — extracted to a named value so the CTRL+SHIFT+E
-- keybind and the command-palette entry share one definition.
local rename_tab = act.PromptInputLine {
  description = 'New tab title (empty = reset):',
  action = wezterm.action_callback(function(window, _pane, line)
    if line == nil then return end  -- Esc cancels
    window:active_tab():set_title(line)
  end),
}

-- Copy entire scrollback — extracted for the same keybind/palette sharing.
local copy_all_scrollback = act.Multiple {
  act.ActivateCopyMode,
  act.CopyMode 'MoveToScrollbackTop',
  act.CopyMode { SetSelectionMode = 'Cell' },
  act.CopyMode 'MoveToScrollbackBottom',
  act.CopyTo 'Clipboard',
  act.CopyMode 'Close',
  act.EmitEvent 'copied',
}

-- Custom actions mirrored into the command palette (CTRL+SHIFT+P). Without
-- this the palette lists only built-ins — a misleading "second surface" that
-- omits every bespoke binding. Entries reuse the SAME action values as
-- config.keys, so the two can't drift.
wezterm.on('augment-command-palette', function(_window, _pane)
  return {
    { brief = 'Connect to host (fuzzy)',  action = pick_host },
    { brief = 'Switch tab (fuzzy)',       action = pick_tab },
    { brief = 'Reconnect SSH pane',       action = reconnect_ssh_pane },
    { brief = 'Rename current tab',       action = rename_tab },
    { brief = 'Copy entire scrollback',   action = copy_all_scrollback },
    { brief = 'Open scrollback in Helix', action = scrollback_to_helix },
    { brief = 'Help / cheatsheet',        action = show_help },
  }
end)
```

- [ ] **Step 2: Point the two keybinds at the extracted values**

In `config.keys`, find the rename entry:

```lua
  {
    key = 'e', mods = 'CTRL|SHIFT',
    action = act.PromptInputLine {
      description = 'New tab title (empty = reset):',
      action = wezterm.action_callback(function(window, _pane, line)
        if line == nil then return end  -- Esc cancels
        window:active_tab():set_title(line)
      end),
    },
  },
```

Replace with:

```lua
  { key = 'e', mods = 'CTRL|SHIFT', action = rename_tab },
```

Then find the scrollback-copy entry:

```lua
  {
    key = 'a', mods = 'CTRL|SHIFT',
    action = act.Multiple {
      act.ActivateCopyMode,
      act.CopyMode 'MoveToScrollbackTop',
      act.CopyMode { SetSelectionMode = 'Cell' },
      act.CopyMode 'MoveToScrollbackBottom',
      act.CopyTo 'Clipboard',
      act.CopyMode 'Close',
      act.EmitEvent 'copied',
    },
  },
```

Replace with:

```lua
  { key = 'a', mods = 'CTRL|SHIFT', action = copy_all_scrollback },
```

(The `-- Rename current tab` and `-- Copy entire scrollback` comment lines
above each original entry stay — they now document the one-liners.)

- [ ] **Step 3: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 4: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): mirror custom actions into the command palette

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Cheatsheet rows + README keybind row + changelog

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (`help_choices`)
- Modify: `README.html` (keybind table `tbody`, §setup-wezterm ~line 3159)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: feature set from Tasks 1–6 (documentation only).

- [ ] **Step 1: Update `help_choices` rows**

Find:

```lua
    { label = 'key   ALT+1..4         Jump directly to tab 1-4',            id = '' },
```

Replace with:

```lua
    { label = 'key   ALT+1..9         Jump directly to tab 1-9',            id = '' },
```

Find:

```lua
    { label = 'key   CTRL+SHIFT+A     Copy entire scrollback to clipboard', id = '' },
```

Append directly below:

```lua
    { label = 'key   CTRL+SHIFT+O     Open scrollback in Helix (local/WSL tabs)', id = '' },
    { label = 'note  tab markers      ● unseen output · 󰂞 bell rang (background tabs; clear on view)', id = '' },
```

Find:

```lua
    { label = 'key   CTRL+SHIFT+Space Quick-select URLs/paths/hashes',      id = '' },
```

Replace with:

```lua
    { label = 'key   CTRL+SHIFT+Space Quick-select URLs/paths/hashes/IPs/#refs', id = '' },
    { label = 'key   CTRL+SHIFT+U     Character/emoji picker',              id = '' },
    { label = 'key   CTRL+SHIFT+L     Debug overlay (Lua REPL + logs)',     id = '' },
```

(If the bell glyph `󰂞` renders as tofu in your editor that's fine — it
resolves inside WezTerm via the Nerd Font.)

- [ ] **Step 2: README keybind table**

In `README.html`, find the `CTRL+SHIFT+A` row in the §setup-wezterm table:

```html
                            <tr>
                                <td>
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd
                                        >A</kbd
                                    >
                                </td>
                                <td>Copy entire scrollback to clipboard</td>
                            </tr>
```

Append directly below it:

```html
                            <tr>
                                <td>
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd
                                        >O</kbd
                                    >
                                </td>
                                <td>
                                    Open the scrollback in Helix in a new
                                    tab (local and WSL tabs; SSH tabs show a
                                    toast instead &mdash; Zellij owns their
                                    scrollback).
                                </td>
                            </tr>
```

Then extend the `CTRL+SHIFT+W` row's cell. Find:

```html
                                <td>
                                    Close current tab (no confirmation
                                    prompt; remote Zellij sessions survive
                                    and reattach)
                                </td>
```

Replace with:

```html
                                <td>
                                    Close current tab (no confirmation
                                    prompt; remote Zellij sessions survive
                                    and reattach). Closing the whole window
                                    never prompts either.
                                </td>
```

- [ ] **Step 3: Changelog row**

Append to the table in `CLAUDE_CHANGELOG.md` (match the existing two-column
`| change | README? |` row format; write it as ONE table row):

```markdown
| WezTerm UX sweep PR 1 in `chezmoi/dot_config/wezterm/wezterm.lua` (spec `docs/superpowers/specs/2026-07-09-wezterm-ux-sweep-design.md`): background-tab activity markers (accent `●` unseen output via `has_unseen_output`, peach bell glyph via a `bell`-event `bell_panes` table, cleared on activation; NO WezTerm toast — `notify.sh` already toasts, marker is the visual channel; known Zellij may-stay-dotted caveat noted in-file with the gate-the-dot fallback); polish (ALT+1..9 loop matching the README's existing 1..9 row, `window_close_confirmation='NeverPrompt'`, config-reloaded toast with first-fire-per-window swallow, `quick_select_patterns` for IPv4 + `#NN`); domain-type Nerd Font glyphs in tab titles (ssh/WSL/local, embedded-ssh-aware) + host-accent domain color in right status via new shared `host_accent()` + `%a` day-of-week clock + battery hidden when full; COPY/SEARCH badge from `window:active_key_table()`; CTRL+SHIFT+O scrollback→Helix (Windows `%TEMP%` dump; `/mnt/c` translation for WSL; SSH toasts); `augment-command-palette` mirroring all custom actions (rename + copy-scrollback extracted to shared `rename_tab`/`copy_all_scrollback`). | **Yes** | §setup-wezterm keybind table: new CTRL+SHIFT+O row; CTRL+SHIFT+W cell notes window-close never prompts. ALT+1..9 row already documented 1..9 (config catches up — no edit). Cheatsheet updated in-app (ALT row, O row, markers note, quick-select row, CharSelect + debug-overlay rows). |
```

- [ ] **Step 4: Syntax gate + lint**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `SYNTAX OK`
Run: `make -C makefile lint MODE=prod`
Expected: ends `✓ all invariant checks passed`

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua README.html CLAUDE_CHANGELOG.md
git commit -m "docs(wezterm): cheatsheet + README + changelog for the UX sweep

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Push branch + open PR

**Files:** none (git/gh only)

- [ ] **Step 1: Push**

```bash
git push -u origin wezterm-ux-sweep
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(wezterm): UX sweep — activity markers, polish bundle, glyphs, mode badge, scrollback→hx, palette parity" --body "$(cat <<'EOF'
Implements PR 1 of docs/superpowers/specs/2026-07-09-wezterm-ux-sweep-design.md.

- Background-tab activity markers: accent ● (unseen output) + peach 󰂞 (bell), cleared on activation. No WezTerm toast — notify.sh owns toasting.
- Polish: ALT+1..9 (config catches up to the README), window_close_confirmation=NeverPrompt, config-reloaded toast, quick-select IPv4 + #NN patterns.
- Domain-type glyphs in tab titles (ssh/WSL/local, embedded-ssh-aware); right-status domain in the host accent; day-of-week clock; battery hidden when full.
- COPY/SEARCH mode badge in the right status.
- CTRL+SHIFT+O: dump scrollback to %TEMP% and open in Helix (WSL gets the /mnt/c path; SSH tabs toast — Zellij owns their scrollback).
- augment-command-palette mirrors every custom action (rename + copy-scrollback extracted to shared values).

Known live-test checkpoints (Windows clone must be synced first — WEZTERM_CONFIG_FILE):
- Zellij tabs may keep has_unseen_output permanently true → if confirmed, gate the dot (not the bell) on non-SSH domains.
- window-config-reloaded first-fire swallow: verify launch doesn't toast AND first reload does.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. **Do not merge** — merging needs explicit user
go-ahead (memory: auto-mode classifier denies self-merge).

- [ ] **Step 3: Report the live-verification checklist**

Post-merge, after syncing the Windows clone, the user (or a follow-up
session via powershell.exe interop) walks the spec's §Testing list:
markers, ALT+5..9, window close, reload toast, quick-select, palette,
glyphs, clock, battery, COPY/SEARCH badge, CTRL+SHIFT+O in WSL + SSH tabs.
