# WezTerm Quick-Wins Bundle + Shift-Click Link Opening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the approved quick-wins bundle — shift-click hyperlink opening, `#NN` hyperlink rule, three QuickSelect action bindings, a local-pane keybinding story, and three behavior flags — in `wezterm.lua`, with cheatsheet/palette/README/changelog parity.

**Architecture:** All feature code lands in `chezmoi/dot_config/wezterm/wezterm.lua` (the single Windows-read config; Linux copies deploy via chezmoi). Extracted `local` action values are shared between `config.keys`, `config.mouse_bindings`, and the `augment-command-palette` handler so surfaces can't drift (existing `rename_tab` / `copy_all_scrollback` precedent). Docs land in `README.html` §setup-wezterm + `CLAUDE_CHANGELOG.md`.

**Tech Stack:** WezTerm Lua config (pinned stable 20240203-110809-5046fc22), luaparse syntax harness, repo lint (`make lint MODE=prod`).

**Spec:** `docs/superpowers/specs/2026-07-10-wezterm-quickwins-design.md` (incl. the 2026-07-10 "shell wins" amendment in Feature 4).

## Global Constraints

- Branch: `feat/wezterm-quickwins` (already exists, tracks origin; spec committed on it).
- Pinned build 20240203: do NOT use nightly-only APIs (`wezterm.serde`, `pane:get_progress()`, `PromptInputLine initial_value`).
- No-gos (memory-guarded): never touch `config.front_end` / `max_fps` / `webgpu_power_preference`; never call `wezterm.gui.*` at config-load; never edit inside the `HOSTS:START/END` sentinel.
- Syntax check after EVERY wezterm.lua edit (NOT the LSP tool — `feedback_lua_syntax_use_luaparse_not_lsp`):
  `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua` → expect `OK`.
  If the harness is missing, recreate it first:
  ```bash
  mkdir -p /tmp/lua-syntax-check && cd /tmp/lua-syntax-check && npm init -y >/dev/null && npm i luaparse >/dev/null
  cat > check.js <<'EOF'
  const fs = require('fs');
  const luaparse = require('luaparse');
  try { luaparse.parse(fs.readFileSync(process.argv[2], 'utf8'), { luaVersion: '5.3' }); console.log('OK'); }
  catch (e) { console.error(e.message); process.exit(1); }
  EOF
  ```
- Commit after every task; push after every commit (`feedback_always_push_after_commit`). Commit messages end with the Co-Authored-By + Claude-Session footer.
- Do NOT merge the PR — the user merges (`feedback_use_pr_review_workflow`).
- House style in `wezterm.lua`: heavy *why* comments are the norm — keep the comment blocks in the code below verbatim.
- All `config.keys` letter bindings use lowercase `key` + mods string (existing file convention).

---

### Task 1: Shift-click opens hyperlinks

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (two edits: `config.mouse_bindings` table ~line 1349; `help_choices` rows ~line 971)

**Interfaces:**
- Consumes: existing `copy_and_announce` action_callback (defined ~line 1279, above `config.mouse_bindings` — order already correct).
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Insert the SHIFT mouse-binding pair**

In `config.mouse_bindings`, find the CTRL+click link-open pair — its closing entry is:

```lua
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'CTRL',
    action = act.OpenLinkAtMouseCursor,
  },
```

Immediately AFTER that entry (before the `-- Window drag-to-move` comment block), insert:

```lua
  -- SHIFT+click — open the hyperlink under the mouse. The stock SHIFT+Down
  -- default is ExtendSelectionToMouseCursor(Cell), which means the SHIFT+Up
  -- composite (CompleteSelectionOrOpenLinkAtMouseCursor) ALWAYS sees a live
  -- selection and takes the complete-selection branch — the link-open branch
  -- was unreachable (verified against inputmap.rs at the pinned 20240203
  -- tag). Overriding Down to START a fresh selection instead of extending
  -- makes a plain shift-click arrive at Up with an EMPTY selection → the
  -- link opens. Shift+drag still selects: Down anchors, the untouched
  -- SHIFT+Drag default extends, Up completes + copies (copy_and_announce
  -- re-copy is harmless; it no-ops when the selection is empty).
  -- SHIFT is the point: it's the bypass_mouse_reporting_modifier (default,
  -- unchanged), so this is the ONE modifier that reaches WezTerm's own mouse
  -- handling inside mouse-reporting panes (Zellij/Helix) — the CTRL+click
  -- binding above never fires there. Accepted loss: shift-click-to-EXTEND an
  -- existing selection (niche; drag selection covers it).
  {
    event = { Down = { streak = 1, button = 'Left' } },
    mods = 'SHIFT',
    action = act.SelectTextAtMouseCursor 'Cell',
  },
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'SHIFT',
    action = act.Multiple {
      act.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
      copy_and_announce,
    },
  },
```

- [ ] **Step 2: Add the cheatsheet row**

In `help_choices()`, find:

```lua
    { label = 'key   CTRL+3×click     Select a command\'s whole output + copy (WSL/local tabs)', id = '' },
```

Insert immediately after it:

```lua
    { label = 'key   SHIFT+click      Open link under mouse (the one modifier that works inside Zellij/Helix panes)', id = '' },
```

- [ ] **Step 3: Syntax check**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 4: Commit + push**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): shift-click opens hyperlinks (works inside Zellij panes)"
git push
```

---

### Task 2: Hyperlink rule — `#NN` → workstation PR/issue

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (after the `config.quick_select_patterns` block ~line 254; one `help_choices` row)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Add the hyperlink_rules block**

Find:

```lua
config.quick_select_patterns = {
  [[\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b]],
  [[#\d+]],
}
```

Insert immediately after the closing `}`:

```lua

-- Hyperlink rules — the built-in defaults (URLs, mailto:, file://) plus one
-- custom rule: bare #NN issue/PR refs link into the workstation repo
-- (GitHub auto-redirects /issues/NN → /pull/NN when NN is a PR). \B# keeps
-- word#12 unlinked; the trailing \b can't fire inside hex colors (#1e1e2e:
-- \d+ eats "1" but hits "e" — a word char — so there's no boundary and no
-- match). Deliberately NO bare owner/repo rule: in path-heavy output every
-- makefile/versions.mk would light up as a GitHub link. Open with
-- SHIFT+click (works in Zellij panes too) or CTRL+click (plain panes).
config.hyperlink_rules = wezterm.default_hyperlink_rules()
table.insert(config.hyperlink_rules, {
  regex  = [[\B#(\d+)\b]],
  format = 'https://github.com/ArrushC/workstation/issues/$1',
})
```

- [ ] **Step 2: Add the cheatsheet note row**

In `help_choices()`, find the row added in Task 1:

```lua
    { label = 'key   SHIFT+click      Open link under mouse (the one modifier that works inside Zellij/Helix panes)', id = '' },
```

Insert immediately after it:

```lua
    { label = 'note  #NN refs         Clickable → github.com/ArrushC/workstation PR/issue', id = '' },
```

- [ ] **Step 3: Syntax check**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 4: Commit + push**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): #NN hyperlink rule -> ArrushC/workstation"
git push
```

---

### Task 3: QuickSelect action bindings (CTRL+SHIFT+I / G / Y)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (four edits: new locals after `copy_all_scrollback` ~line 1441; three `config.keys` entries; three palette entries; three `help_choices` rows)

**Interfaces:**
- Consumes: `ssh_domains` (top-of-file table), `act`, `wezterm`.
- Produces: locals `quick_ssh_ip`, `quick_open_hx`, `quick_yank_sha` — referenced by BOTH `config.keys` and the `augment-command-palette` handler in this same task.

- [ ] **Step 1: Add the three QuickSelectArgs locals**

Find the end of the `copy_all_scrollback` definition:

```lua
local copy_all_scrollback = act.Multiple {
  act.ActivateCopyMode,
  act.CopyMode 'MoveToScrollbackTop',
  act.CopyMode { SetSelectionMode = 'Cell' },
  act.CopyMode 'MoveToScrollbackBottom',
  act.CopyTo 'Clipboard',
  act.CopyMode 'Close',
  act.EmitEvent 'copied',
}
```

Insert immediately after it:

```lua

-- ---------------------------------------------------------------------------
-- QuickSelect action bindings — Enter DOES something with the selection
-- ---------------------------------------------------------------------------
-- Pattern-restricted QuickSelect overlays whose action consumes the selection
-- instead of just copying it (the plain CTRL+SHIFT+Space overlay keeps its
-- copy behavior). Each `label` names the action in the overlay footer.
-- Extracted to locals so config.keys and the command palette share one
-- definition (rename_tab precedent).

-- CTRL+SHIFT+I — pick an IPv4 from the screen, open SSH to it. A managed
-- host (remote_address match in ssh_domains) opens as its domain tab, so
-- Zellij attaches via the per-domain default_prog; any other IP gets a plain
-- `ssh <ip>` in the CURRENT pane's domain (WSL/local both carry an ssh
-- client; from an SSH pane it chains a hop from that host).
local quick_ssh_ip = act.QuickSelectArgs {
  label    = 'open SSH to IP',
  patterns = { [[\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b]] },
  action   = wezterm.action_callback(function(window, pane)
    local ip = window:get_selection_text_for_pane(pane)
    if not ip or #ip == 0 then return end
    for _, d in ipairs(ssh_domains) do
      if d.remote_address == ip then
        window:perform_action(act.SpawnTab { DomainName = d.name }, pane)
        return
      end
    end
    window:perform_action(act.SpawnCommandInNewTab {
      domain = 'CurrentPaneDomain',
      args   = { 'ssh', ip },
    }, pane)
  end),
}

-- CTRL+SHIFT+G — pick a file:line[:col] (compiler error, grep -n, stack
-- trace) and open it in Helix at that position (hx accepts file:line:col
-- directly). Same-domain spawn mirrors the open-uri handler: WSL → hx in
-- the distro, SSH → one-shot hx tab on that host, local → portable hx.exe.
-- Relative paths resolve because SpawnCommandInNewTab inherits the pane's
-- OSC 7-tracked cwd.
local quick_open_hx = act.QuickSelectArgs {
  label    = 'open in Helix',
  patterns = { [[[\w./~_-]+:\d+(?::\d+)?]] },
  action   = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if not sel or #sel == 0 then return end
    window:perform_action(act.SpawnCommandInNewTab {
      domain = 'CurrentPaneDomain',
      args   = { 'hx', sel },
    }, pane)
  end),
}

-- CTRL+SHIFT+Y — pick a git SHA (7–40 hex chars) and type it into the
-- prompt: no clipboard round-trip for `git show <pick>` flows. All-digit
-- runs of 7+ (ports, sizes) match too — visual noise in the overlay, not a
-- correctness issue (you pick the label you want).
local quick_yank_sha = act.QuickSelectArgs {
  label    = 'paste into prompt',
  patterns = { [[\b[0-9a-f]{7,40}\b]] },
  action   = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if not sel or #sel == 0 then return end
    pane:send_text(sel)
  end),
}
```

- [ ] **Step 2: Add the key bindings**

In `config.keys`, find:

```lua
  { key = 'UpArrow',   mods = 'CTRL|SHIFT', action = act.ScrollToPrompt(-1) },
  { key = 'DownArrow', mods = 'CTRL|SHIFT', action = act.ScrollToPrompt(1) },
```

Insert immediately after:

```lua

  -- QuickSelect action bindings (locals above): I = IP → SSH, G = goto
  -- file:line in Helix, Y = yank SHA into the prompt.
  { key = 'i', mods = 'CTRL|SHIFT', action = quick_ssh_ip },
  { key = 'g', mods = 'CTRL|SHIFT', action = quick_open_hx },
  { key = 'y', mods = 'CTRL|SHIFT', action = quick_yank_sha },
```

- [ ] **Step 3: Add the palette entries**

In the `augment-command-palette` handler, find:

```lua
    { brief = 'Help / cheatsheet',        action = show_help },
```

Insert immediately after:

```lua
    { brief = 'QuickSelect: IP → open SSH',     action = quick_ssh_ip },
    { brief = 'QuickSelect: file:line → Helix', action = quick_open_hx },
    { brief = 'QuickSelect: SHA → prompt',      action = quick_yank_sha },
```

- [ ] **Step 4: Add the cheatsheet rows**

In `help_choices()`, find:

```lua
    { label = 'key   CTRL+SHIFT+Space Quick-select URLs/paths/hashes/IPs/#refs', id = '' },
```

Insert immediately after:

```lua
    { label = 'key   CTRL+SHIFT+I     Quick-select an IP → open SSH to it', id = '' },
    { label = 'key   CTRL+SHIFT+G     Quick-select file:line → open in Helix', id = '' },
    { label = 'key   CTRL+SHIFT+Y     Quick-select a git SHA → paste into prompt', id = '' },
```

- [ ] **Step 5: Syntax check**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 6: Commit + push**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): QuickSelect actions - IP->ssh, file:line->hx, SHA->prompt"
git push
```

---

### Task 4: Local pane story (splits, nav, zoom, picker; free CTRL+SHIFT+←/→ for the shell)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (five edits: locals; keys; DisableDefaultAssignment pair; palette entries; help rows; `unzoom_on_switch_pane` flag)

**Interfaces:**
- Consumes: `act`, `config`.
- Produces: locals `split_down`, `split_right`, `pane_picker` — referenced by BOTH `config.keys` and the palette in this same task.

- [ ] **Step 1: Add the pane-action locals**

Immediately after the `quick_yank_sha` local from Task 3 (after its closing `}`), insert:

```lua

-- ---------------------------------------------------------------------------
-- Local pane management — splits, nav, zoom, picker
-- ---------------------------------------------------------------------------
-- Zellij owns panes inside SSH tabs; these cover local/WSL tabs, which
-- previously had no ergonomic pane story at all. Split mnemonics match
-- Zellij's pane mode (d = down, r = right) so muscle memory transfers;
-- pane NAV lives on the same ALT+SHIFT layer (arrows).
local split_down  = act.SplitVertical   { domain = 'CurrentPaneDomain' }
local split_right = act.SplitHorizontal { domain = 'CurrentPaneDomain' }
local pane_picker = act.PaneSelect {}
```

- [ ] **Step 2: Add the key bindings + release CTRL+SHIFT+←/→ to the shell**

In `config.keys`, find the three QuickSelect entries added in Task 3:

```lua
  { key = 'i', mods = 'CTRL|SHIFT', action = quick_ssh_ip },
  { key = 'g', mods = 'CTRL|SHIFT', action = quick_open_hx },
  { key = 'y', mods = 'CTRL|SHIFT', action = quick_yank_sha },
```

Insert immediately after:

```lua

  -- Panes (local/WSL tabs — Zellij owns panes inside SSH tabs). ALT+SHIFT
  -- layer: D/R split (Zellij pane-mode mnemonics), arrows navigate.
  -- CTRL+SHIFT+Z restates the built-in zoom default so the cheatsheet and
  -- this config stay the source of truth; CTRL+SHIFT+Q = letter overlay.
  { key = 'd', mods = 'SHIFT|ALT', action = split_down },
  { key = 'r', mods = 'SHIFT|ALT', action = split_right },
  { key = 'z', mods = 'CTRL|SHIFT', action = act.TogglePaneZoomState },
  { key = 'q', mods = 'CTRL|SHIFT', action = pane_picker },
  { key = 'LeftArrow',  mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Right' },
  { key = 'UpArrow',    mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow',  mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Down' },

  -- Release CTRL+SHIFT+←/→ back to the SHELL. The build's defaults bind
  -- them to ActivatePaneDirection, and a bound chord is consumed even with
  -- a single pane — which silently shadowed the zsh shift-select
  -- word-extend (README §prompt-keys) in EVERY pane since that feature
  -- landed. Pane nav lives on ALT+SHIFT+arrows above; CTRL+SHIFT+Up/Down
  -- stay ScrollToPrompt overrides (they never reached the shell either way).
  { key = 'LeftArrow',  mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
  { key = 'RightArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
```

- [ ] **Step 3: Add the `unzoom_on_switch_pane` flag**

Find:

```lua
config.tab_max_width               = 32
```

Insert immediately after:

```lua

-- Switching panes while one is zoomed un-zooms instead of silently swapping
-- the zoomed content — pairs with the CTRL+SHIFT+Z zoom toggle.
config.unzoom_on_switch_pane = true
```

- [ ] **Step 4: Add the palette entries**

In the `augment-command-palette` handler, find the last entry added in Task 3:

```lua
    { brief = 'QuickSelect: SHA → prompt',      action = quick_yank_sha },
```

Insert immediately after:

```lua
    { brief = 'Split pane down',  action = split_down },
    { brief = 'Split pane right', action = split_right },
    { brief = 'Pane picker',      action = pane_picker },
```

- [ ] **Step 5: Add the cheatsheet rows**

In `help_choices()`, find the Task 3 rows:

```lua
    { label = 'key   CTRL+SHIFT+Y     Quick-select a git SHA → paste into prompt', id = '' },
```

Insert immediately after:

```lua
    -- Wezterm: panes (local/WSL tabs; Zellij owns panes inside SSH tabs)
    { label = 'key   ALT+SHIFT+D/R    Split pane down / right (local/WSL tabs)', id = '' },
    { label = 'key   ALT+SHIFT+arrows Move between panes', id = '' },
    { label = 'key   CTRL+SHIFT+Z     Toggle pane zoom', id = '' },
    { label = 'key   CTRL+SHIFT+Q     Pane picker (letter overlay)', id = '' },
    { label = 'note  CTRL+SHIFT+←/→   Reaches the shell now — zsh word-extend selection works', id = '' },
```

- [ ] **Step 6: Syntax check**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 7: Commit + push**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): local pane bindings; free CTRL+SHIFT+arrows for zsh shift-select"
git push
```

---

### Task 5: Behavior flags (kitty graphics, update check, quoted drops)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (one block after the `unzoom_on_switch_pane` flag from Task 4; one help row)

**Interfaces:** none.

- [ ] **Step 1: Add the three flags**

Find the block added in Task 4:

```lua
-- Switching panes while one is zoomed un-zooms instead of silently swapping
-- the zoomed content — pairs with the CTRL+SHIFT+Z zoom toggle.
config.unzoom_on_switch_pane = true
```

Insert immediately after:

```lua

-- Update-check toast off — the Windows build is deliberately pinned at
-- 20240203 (bootstrap.ps1 $PortableTools), so "new version available" is
-- pure noise. Re-enable if the pin policy ever changes. (Supersedes the
-- 2026-07-09 UX-sweep spec's decline — re-approved 2026-07-10.)
config.check_for_updates = false

-- Kitty graphics protocol — off by default on this build. Enables inline
-- image previews (yazi, wezterm imgcat) in local/WSL/raw-ssh panes. Known
-- limit: NOT through Zellij tabs (no kitty-graphics passthrough there).
config.enable_kitty_graphics = true

-- Drag-and-dropping a file onto the terminal pastes its path quoted
-- (Windows-style double quotes — also valid in POSIX shells). The
-- SpacesOnly default leaves parens/brackets in Windows paths unquoted.
config.quote_dropped_files = 'WindowsAlwaysQuoted'
```

- [ ] **Step 2: Add the cheatsheet note rows**

In `help_choices()`, find the Task 4 row:

```lua
    { label = 'note  CTRL+SHIFT+←/→   Reaches the shell now — zsh word-extend selection works', id = '' },
```

Insert immediately after:

```lua
    { label = 'note  drag & drop      Dropping a file pastes its quoted path', id = '' },
    { label = 'note  images           yazi/imgcat previews render inline (not through Zellij)', id = '' },
```

- [ ] **Step 3: Syntax check**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 4: Commit + push**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "feat(wezterm): kitty graphics on, update-check off, quoted file drops"
git push
```

---

### Task 6: README keybind table + changelog row

**Files:**
- Modify: `README.html` (§setup-wezterm keybind table, `<tbody>` ending ~line 3312)
- Modify: `CLAUDE_CHANGELOG.md` (append one table row)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add README keybind rows**

In `README.html`, find the final row of the §setup-wezterm table (the CTRL+SHIFT+drag / WIN+drag row) and insert BEFORE it (matching the file's `<kbd>` formatting style — attribute-wrapped closing brackets are fine to simplify to plain inline tags, both exist in the file):

```html
                            <tr>
                                <td><kbd>SHIFT</kbd>+click</td>
                                <td>
                                    Open the link under the mouse. SHIFT
                                    bypasses app mouse handling, so this is
                                    the click that works inside Zellij and
                                    Helix panes; bare <code>#NN</code> refs
                                    are linkified to the workstation repo's
                                    PR/issue pages.
                                </td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>I</kbd>
                                </td>
                                <td>
                                    Quick-select an IPv4 from the screen and
                                    open SSH to it (managed hosts attach
                                    their Zellij session; other IPs get a
                                    plain <code>ssh</code>).
                                </td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>G</kbd>
                                </td>
                                <td>
                                    Quick-select a <code>file:line</code>
                                    from build/grep output and open it in
                                    Helix at that position (same domain as
                                    the pane).
                                </td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>Y</kbd>
                                </td>
                                <td>
                                    Quick-select a git SHA and type it
                                    straight into the prompt (no clipboard
                                    round-trip).
                                </td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>ALT</kbd>+<kbd>SHIFT</kbd>+<kbd>D</kbd>
                                    / <kbd>R</kbd>
                                </td>
                                <td>
                                    Split the pane down / right (local and
                                    WSL tabs &mdash; Zellij owns panes inside
                                    SSH tabs). Navigate panes with
                                    <kbd>ALT</kbd>+<kbd>SHIFT</kbd>+arrows;
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>Z</kbd>
                                    zooms; <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>Q</kbd>
                                    opens a letter-overlay pane picker.
                                    <kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>&larr;</kbd>/<kbd>&rarr;</kbd>
                                    now pass through to the shell, so the
                                    word-extend selection documented under
                                    Shell prompt selection works inside
                                    WezTerm.
                                </td>
                            </tr>
```

- [ ] **Step 2: Append the changelog row**

Append to the table at the end of `CLAUDE_CHANGELOG.md` (single `|`-delimited row, following the existing three-column format — description | README? | rationale):

```markdown
| WezTerm quick-wins bundle in `chezmoi/dot_config/wezterm/wezterm.lua` (spec `docs/superpowers/specs/2026-07-10-wezterm-quickwins-design.md`): SHIFT+click opens hyperlinks (root cause: stock SHIFT+Down `ExtendSelectionToMouseCursor` starved the SHIFT+Up composite's link-open branch — overridden to start a fresh selection; SHIFT = the bypass_mouse_reporting_modifier, so links are now clickable inside Zellij/Helix panes; accepted loss: shift-click-extend); `#NN` hyperlink rule → ArrushC/workstation (defaults preserved; no bare owner/repo rule — path false-positives); QuickSelect action trio (CTRL+SHIFT+I IPv4→SSH tab w/ managed-host domain match, CTRL+SHIFT+G file:line→hx same-domain, CTRL+SHIFT+Y SHA→send_text); local pane story (ALT+SHIFT+D/R splits + ALT+SHIFT+arrows nav, CTRL+SHIFT+Z zoom restated, CTRL+SHIFT+Q PaneSelect, `unzoom_on_switch_pane`); CTRL+SHIFT+←/→ `DisableDefaultAssignment` — the pane-nav defaults had consumed the chord and silently shadowed zsh shift-select word-extend since it landed; flags `check_for_updates=false` (supersedes UX-sweep decline, re-approved), `enable_kitty_graphics=true` (yazi previews; not through Zellij), `quote_dropped_files='WindowsAlwaysQuoted'`. Cheatsheet + palette rows added in-config. | **Yes** | §setup-wezterm keybind table: SHIFT+click row, CTRL+SHIFT+I/G/Y rows, pane-management row (splits/nav/zoom/picker + the CTRL+SHIFT+←/→ pass-through note). |
```

- [ ] **Step 3: Commit + push**

```bash
git add README.html CLAUDE_CHANGELOG.md
git commit -m "docs: README keybind rows + changelog for wezterm quick-wins bundle"
git push
```

---

### Task 7: Full verification + PR

**Files:** none (verification + PR only).

- [ ] **Step 1: Syntax check (final)**

Run: `node /tmp/lua-syntax-check/check.js chezmoi/dot_config/wezterm/wezterm.lua`
Expected: `OK`

- [ ] **Step 2: Repo lint**

Run: `make lint MODE=prod` (from repo root; forwards to `makefile/`)
Expected: `✓ all invariant checks passed` + template checks pass. (wezterm.lua is not in the LF/0755 set, but the run guards against accidental collateral edits.)

- [ ] **Step 3: Spec coverage self-check**

Re-read `docs/superpowers/specs/2026-07-10-wezterm-quickwins-design.md` (incl. Feature 4 amendment) and confirm each feature maps to a landed commit. Confirm no edits landed inside the `HOSTS:START/END` sentinel: `git diff main -- chezmoi/dot_config/wezterm/wezterm.lua | grep -c "HOSTS:"` → expected `0`.

- [ ] **Step 4: Open the PR (do NOT merge)**

```bash
gh pr create --title "feat(wezterm): quick-wins bundle — shift-click links, #NN hyperlinks, QuickSelect actions, pane bindings, kitty graphics" --body "$(cat <<'EOF'
## Summary
- SHIFT+click opens hyperlinks — root-caused against the pinned build's inputmap.rs (stock SHIFT+Down extend starved the link-open branch); SHIFT is the mouse-reporting bypass, so links now open inside Zellij/Helix panes
- #NN refs linkify to ArrushC/workstation (defaults preserved)
- QuickSelect action trio: CTRL+SHIFT+I (IPv4 → SSH tab, managed-host aware), CTRL+SHIFT+G (file:line → Helix, same domain), CTRL+SHIFT+Y (SHA → prompt)
- Local pane story: ALT+SHIFT+D/R splits, ALT+SHIFT+arrows nav, CTRL+SHIFT+Z zoom, CTRL+SHIFT+Q PaneSelect, unzoom_on_switch_pane
- CTRL+SHIFT+←/→ released to the shell (DisableDefaultAssignment) — fixes the silently-shadowed zsh shift-select word-extend (README §prompt-keys)
- Flags: check_for_updates=false (pin is deliberate), enable_kitty_graphics=true (yazi previews), quote_dropped_files=WindowsAlwaysQuoted
- Cheatsheet + command-palette parity in-config; README §setup-wezterm keybind rows; changelog row

Spec: docs/superpowers/specs/2026-07-10-wezterm-quickwins-design.md

## Test plan
- [x] luaparse syntax check after every edit
- [x] make lint MODE=prod
- [ ] Live smoke on the Windows clone after merge+pull: reload toast; shift-click a URL inside a Zellij pane; click a #NN; CTRL+SHIFT+I/G/Y overlays; ALT+SHIFT+D split + arrows nav in a WSL tab; CTRL+SHIFT+←/→ word-extend at a zsh prompt; yazi image preview

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01NG51PLSe7BNWPA1ukVoYA7
EOF
)"
```

Expected: PR URL printed. Report it to the user; the user merges.

---

## Post-merge deployment notes (user-facing, not plan tasks)

- Windows reads `wezterm.lua` via `WEZTERM_CONFIG_FILE` from its own clone → `git pull` there (or chezmoi update via interop) + CTRL+SHIFT+R.
- Linux hosts pick the file up via `czu && cza` (no terminfo/rc changes in this PR).
