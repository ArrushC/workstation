# Catppuccin Mocha Theme Sweep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Tokyo Night with Catppuccin Mocha across WezTerm, zellij, fzf, and delta — one cohesive dark theme.

**Architecture:** WezTerm's built-in `Catppuccin Mocha` color scheme drives the 16-color ANSI palette (so starship/eza/grep re-tint for free); the WezTerm chrome hexes are routed through a named `mocha` palette table instead of scattered inline hexes; zellij and delta use bundled Catppuccin Mocha themes; fzf gets the official Mocha `--color` spec in both shell rc files.

**Tech Stack:** WezTerm (Lua), zellij (KDL), fzf (shell env), delta (gitconfig), chezmoi templates.

> **Commit policy (overrides skill default):** Do NOT commit until the user explicitly approves. The repo is on `main` — create a branch first (`git switch -c feat/catppuccin-mocha`). The per-task "Commit" steps below are written for completeness but are gated on that approval. Preferred grouping: one `feat(theme):` commit for the five config files (atomic — fzf parity requires both rc files together), one `docs:` commit for the spec + plan + changelog row.

> **No-CRLF / mode reminders:** `wezterm.lua`, `config.kdl`, `dot_zshrc.tmpl`, `dot_bashrc.tmpl`, `dot_gitconfig.tmpl` are all LF-only text. After editing, the final verification task runs `file` on them to confirm no `with CRLF line terminators` crept in.

---

## File map

| File | Change |
|---|---|
| `chezmoi/dot_config/wezterm/wezterm.lua` | Add `mocha` palette table; flip `color_scheme`; route all chrome/tab/status hexes through `mocha`; update stale "Tokyo Night" comments |
| `chezmoi/dot_config/zellij/config.kdl` | `theme "tokyo-night-dark"` → `"catppuccin-mocha"` |
| `chezmoi/dot_zshrc.tmpl` | Append Mocha `--color` lines to `FZF_DEFAULT_OPTS` |
| `chezmoi/dot_bashrc.tmpl` | Identical `FZF_DEFAULT_OPTS` edit (parity) |
| `chezmoi/dot_gitconfig.tmpl` | Add `[delta]` Catppuccin Mocha section |
| `CLAUDE_CHANGELOG.md` | Append one row (README column: No) |

**Catppuccin Mocha palette (canonical):**
```
base #1e1e2e   mantle #181825   crust #11111b
surface0 #313244  surface1 #45475a  surface2 #585b70
overlay0 #6c7086
text #cdd6f4   rosewater #f5e0dc   lavender #b4befe
blue #89b4fa  mauve #cba6f7  sky #89dceb  green #a6e3a1
yellow #f9e2af  peach #fab387  red #f38ba8  teal #94e2d5
```

---

## Task 1: WezTerm — palette table + color_scheme flip

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (line ~139 + new table above it)

- [ ] **Step 1: Insert the `mocha` palette table immediately before `config.color_scheme`**

Find (line ~139):
```lua
config.color_scheme = 'Tokyo Night'
```

Replace with:
```lua
-- Catppuccin Mocha palette — single source for every hardcoded chrome/tab/status
-- color below. The 16-color ANSI palette + default bg/fg come from the built-in
-- 'Catppuccin Mocha' color_scheme; this table only covers the surfaces WezTerm
-- doesn't theme for us (window frame, tab bar, scrollbar, per-host tab accents,
-- right-status text). Values are the canonical Catppuccin Mocha hexes.
local mocha = {
  base     = '#1e1e2e',
  mantle   = '#181825',
  crust    = '#11111b',
  surface0 = '#313244',
  surface1 = '#45475a',
  surface2 = '#585b70',
  overlay0 = '#6c7086',
  text     = '#cdd6f4',
  blue     = '#89b4fa',
  mauve    = '#cba6f7',
  sky      = '#89dceb',
  green    = '#a6e3a1',
  yellow   = '#f9e2af',
  peach    = '#fab387',
  red      = '#f38ba8',
  teal     = '#94e2d5',
}

config.color_scheme = 'Catppuccin Mocha'
```

- [ ] **Step 2: Verify the table is in scope before first use**

Run: `grep -n "local mocha = {" chezmoi/dot_config/wezterm/wezterm.lua; grep -n "config.color_scheme" chezmoi/dot_config/wezterm/wezterm.lua`
Expected: the `local mocha` line number is **less than** the `config.color_scheme` line, and far less than the window_frame block (~190). (mocha must be defined before any reference.)

---

## Task 2: WezTerm — window_frame chrome

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua:183-204`

- [ ] **Step 1: Replace the window_frame comment + block**

Find:
```lua
-- Fancy-mode chrome (Tokyo Night-matched). Ignored when use_fancy_tab_bar = false.
```
Replace with:
```lua
-- Fancy-mode chrome (Catppuccin Mocha-matched). Ignored when use_fancy_tab_bar = false.
```

Find:
```lua
  -- Active bar sits slightly elevated above main bg (#1a1b26) for separation;
  -- inactive drops down to Tokyo Night bg_dark.
  active_titlebar_bg              = '#1f2335',
  inactive_titlebar_bg            = '#16161e',
  active_titlebar_fg              = '#c0caf5',
  inactive_titlebar_fg            = '#565f89',
  active_titlebar_border_bottom   = '#292e42',
  inactive_titlebar_border_bottom = '#15161e',
  button_bg                       = '#1f2335',
  button_fg                       = '#c0caf5',
  button_hover_bg                 = '#292e42',
  button_hover_fg                 = '#c0caf5',
```
Replace with:
```lua
  -- Active bar sits slightly elevated above base (surface0) for separation;
  -- inactive drops down to mantle.
  active_titlebar_bg              = mocha.surface0,
  inactive_titlebar_bg            = mocha.mantle,
  active_titlebar_fg              = mocha.text,
  inactive_titlebar_fg            = mocha.overlay0,
  active_titlebar_border_bottom   = mocha.surface1,
  inactive_titlebar_border_bottom = mocha.crust,
  button_bg                       = mocha.surface0,
  button_fg                       = mocha.text,
  button_hover_bg                 = mocha.surface1,
  button_hover_fg                 = mocha.text,
```

- [ ] **Step 2: Verify no stray hexes remain in this block**

Run: `sed -n '183,210p' chezmoi/dot_config/wezterm/wezterm.lua | grep -nE "#[0-9a-fA-F]{6}"`
Expected: no matches (every value now references `mocha.*`).

---

## Task 3: WezTerm — tab_bar surfaces + scrollbar

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua:211-224`

- [ ] **Step 1: Replace the config.colors block**

Find:
```lua
config.colors = {
  tab_bar = {
    background        = '#1a1b26',
    -- Hide the thin tab-edge divider — the default color is a light gray that
    -- pops against the bar bg only when the adjacent surface lightens (e.g.
    -- when hovering the "+" button). Match the bar bg so it disappears in
    -- every state.
    inactive_tab_edge = '#1a1b26',
    new_tab           = { bg_color = '#1a1b26', fg_color = '#565f89' },
    new_tab_hover     = { bg_color = '#292e42', fg_color = '#c0caf5' },
  },
  -- Scrollbar thumb — visible against the Tokyo Night bg without screaming
  scrollbar_thumb = '#414868',
}
```
Replace with:
```lua
config.colors = {
  tab_bar = {
    background        = mocha.base,
    -- Hide the thin tab-edge divider — the default color is a light gray that
    -- pops against the bar bg only when the adjacent surface lightens (e.g.
    -- when hovering the "+" button). Match the bar bg so it disappears in
    -- every state.
    inactive_tab_edge = mocha.base,
    new_tab           = { bg_color = mocha.base, fg_color = mocha.overlay0 },
    new_tab_hover     = { bg_color = mocha.surface1, fg_color = mocha.text },
  },
  -- Scrollbar thumb — visible against the Catppuccin Mocha bg without screaming
  scrollbar_thumb = mocha.surface2,
}
```

- [ ] **Step 2: Verify**

Run: `sed -n '211,225p' chezmoi/dot_config/wezterm/wezterm.lua | grep -nE "#[0-9a-fA-F]{6}"`
Expected: no matches.

---

## Task 4: WezTerm — HOST_ACCENTS palette

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua:306-322`

- [ ] **Step 1: Replace the accent comment header + palette**

Find:
```lua
-- Tab colors — Tokyo Night accent palette + state variants
```
Replace with:
```lua
-- Tab colors — Catppuccin Mocha accent palette + state variants
```

Find:
```lua
-- Each SSH host gets a stable accent from this curated Tokyo Night palette
-- (8-bucket hash on the host name), so there's a cheap visual guard against
-- typing into the wrong host. The per-state mapping lives in tab_colors
-- below; this block just defines the palette + hash.
local HOST_ACCENTS = {
  '#7aa2f7',  -- blue
  '#bb9af7',  -- magenta
  '#7dcfff',  -- cyan
  '#9ece6a',  -- green
  '#e0af68',  -- yellow
  '#ff9e64',  -- orange
  '#f7768e',  -- red
  '#73daca',  -- teal
}
```
Replace with:
```lua
-- Each SSH host gets a stable accent from this curated Catppuccin Mocha palette
-- (8-bucket hash on the host name), so there's a cheap visual guard against
-- typing into the wrong host. The per-state mapping lives in tab_colors
-- below; this block just defines the palette + hash.
local HOST_ACCENTS = {
  mocha.blue,    -- blue
  mocha.mauve,   -- mauve (magenta)
  mocha.sky,     -- sky (cyan)
  mocha.green,   -- green
  mocha.yellow,  -- yellow
  mocha.peach,   -- peach (orange)
  mocha.red,     -- red
  mocha.teal,    -- teal
}
```

- [ ] **Step 2: Verify accent count unchanged (8) and no hexes**

Run: `awk '/local HOST_ACCENTS = {/,/^}/' chezmoi/dot_config/wezterm/wezterm.lua | grep -c "mocha\."`
Expected: `8`

---

## Task 5: WezTerm — tab_colors function

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua:331-358`

- [ ] **Step 1: Replace the BAR_BG + active-host fg line**

Find:
```lua
-- Inactive tabs match the bar bg (#1a1b26 — see config.colors.tab_bar below)
```
Replace with:
```lua
-- Inactive tabs match the bar bg (mocha.base — see config.colors.tab_bar below)
```

Find:
```lua
  local BAR_BG = '#1a1b26'
  if host then
    local accent = wezterm.color.parse(HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1])
    if is_active then
      return tostring(accent),                                '#15161e'
    elseif is_hover then
      return tostring(accent:desaturate(0.50):darken(0.50)),  '#c0caf5'
    end
    return   BAR_BG,                                          tostring(accent:desaturate(0.40):darken(0.10))
  end
```
Replace with:
```lua
  local BAR_BG = mocha.base
  if host then
    local accent = wezterm.color.parse(HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1])
    if is_active then
      return tostring(accent),                                mocha.crust
    elseif is_hover then
      return tostring(accent:desaturate(0.50):darken(0.50)),  mocha.text
    end
    return   BAR_BG,                                          tostring(accent:desaturate(0.40):darken(0.10))
  end
```

- [ ] **Step 2: Replace the local-tab comment + returns**

Find:
```lua
  -- Local tab — same progression against neutral Tokyo Night surfaces.
  -- Active uses terminal_black (#414868) instead of bg_highlight (#292e42)
  -- so the contrast against the now-blended inactive tabs still pops.
  if is_active then
    return '#414868', '#c0caf5'
  elseif is_hover then
    return '#292e42', '#c0caf5'
  end
  return BAR_BG, '#565f89'
```
Replace with:
```lua
  -- Local tab — same progression against neutral Catppuccin Mocha surfaces.
  -- Active uses surface2 instead of surface1 so the contrast against the
  -- now-blended inactive tabs still pops.
  if is_active then
    return mocha.surface2, mocha.text
  elseif is_hover then
    return mocha.surface1, mocha.text
  end
  return BAR_BG, mocha.overlay0
```

- [ ] **Step 3: Verify**

Run: `awk '/^local function tab_colors/,/^end/' chezmoi/dot_config/wezterm/wezterm.lua | grep -nE "#[0-9a-fA-F]{6}"`
Expected: no matches.

---

## Task 6: WezTerm — right-status FG + copied badge

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua:859-861, 906`

- [ ] **Step 1: Replace the FG / FG_DIM definitions**

Find:
```lua
  local FG     = '#c0caf5'
  local FG_DIM = '#565f89'
```
Replace with:
```lua
  local FG     = mocha.text
  local FG_DIM = mocha.overlay0
```

- [ ] **Step 2: Replace the copied-badge green**

Find:
```lua
      { Foreground = { Color = '#9ece6a' } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = badge },
```
Replace with:
```lua
      { Foreground = { Color = mocha.green } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = badge },
```

- [ ] **Step 3: Whole-file verification — only the ANSI palette name should reference Tokyo Night nowhere; no Tokyo Night hexes left**

Run: `grep -niE "tokyo" chezmoi/dot_config/wezterm/wezterm.lua`
Expected: no matches.

Run: `grep -nE "'#(1a1b26|1f2335|16161e|c0caf5|565f89|292e42|15161e|414868|9ece6a|7aa2f7|bb9af7|7dcfff|9ece6a|e0af68|ff9e64|f7768e|73daca)'" chezmoi/dot_config/wezterm/wezterm.lua`
Expected: no matches (every old Tokyo Night hex is gone).

- [ ] **Step 4: Lua syntax check (if an interpreter is present)**

Run: `command -v luac >/dev/null && luac -p chezmoi/dot_config/wezterm/wezterm.lua && echo "LUA OK" || command -v lua >/dev/null && lua -e "assert(loadfile('chezmoi/dot_config/wezterm/wezterm.lua'))" && echo "LUA OK" || echo "no lua interpreter — rely on diff review + in-app Ctrl+Shift+R"`
Expected: `LUA OK`, or the graceful "no lua interpreter" note.

---

## Task 7: zellij theme

**Files:**
- Modify: `chezmoi/dot_config/zellij/config.kdl:25` (the `theme` line)

- [ ] **Step 1: Swap the theme name**

Find:
```kdl
theme "tokyo-night-dark"
```
Replace with:
```kdl
theme "catppuccin-mocha"
```

- [ ] **Step 2: Parse-check the config the way CLAUDE.md prescribes (stage with layouts/)**

Run:
```bash
tmpz=$(mktemp -d) && cp chezmoi/dot_config/zellij/config.kdl "$tmpz/" && mkdir -p "$tmpz/layouts" && cp chezmoi/dot_config/zellij/layouts/dev.kdl "$tmpz/layouts/" && ZELLIJ_CONFIG_DIR="$tmpz" zellij setup --check; echo "exit=$?"; rm -rf "$tmpz"
```
Expected: clean output (no `theme ... not found`, no parse error), `exit=0`.

---

## Task 8: fzf Catppuccin Mocha `--color` (both rc files, parity)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (FZF_DEFAULT_OPTS block, ~line 45)
- Modify: `chezmoi/dot_bashrc.tmpl` (FZF_DEFAULT_OPTS block, ~line 37)

- [ ] **Step 1: Edit `dot_zshrc.tmpl` — append the color lines inside the existing quoted block**

Find:
```
export FZF_DEFAULT_OPTS="
  --height 40%
  --layout=reverse
  --border
  --info=inline
  --bind='ctrl-/:toggle-preview'
"
```
Replace with:
```
export FZF_DEFAULT_OPTS="
  --height 40%
  --layout=reverse
  --border
  --info=inline
  --bind='ctrl-/:toggle-preview'
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc
  --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8
  --color=selected-bg:#45475a,border:#6c7086,label:#cdd6f4
"
```

- [ ] **Step 2: Apply the IDENTICAL edit to `dot_bashrc.tmpl`**

Same find/replace as Step 1, in `chezmoi/dot_bashrc.tmpl`.

- [ ] **Step 3: Verify both files carry the same fzf color spec (parity)**

Run:
```bash
diff <(grep -A4 -- '--bind=.ctrl-/:toggle-preview' chezmoi/dot_zshrc.tmpl | grep -- '--color=') \
     <(grep -A4 -- '--bind=.ctrl-/:toggle-preview' chezmoi/dot_bashrc.tmpl | grep -- '--color=') && echo "FZF PARITY OK"
```
Expected: `FZF PARITY OK` (no diff between the two files' color lines).

---

## Task 9: delta Catppuccin Mocha section

**Files:**
- Modify: `chezmoi/dot_gitconfig.tmpl` (append a `[delta]` section)

- [ ] **Step 1: Cross-check the upstream Catppuccin Mocha delta values (avoid shipping wrong blended diff backgrounds)**

Run (or WebFetch the same URL): `curl -fsSL https://raw.githubusercontent.com/catppuccin/delta/main/catppuccin.gitconfig | sed -n '/catppuccin-mocha/,/^$/p'`
Use the upstream `minus-style` / `plus-style` / `*-emph-style` / `line-numbers-*` / `hunk-header-*` values verbatim if they differ from Step 2's block. (Step 2 ships a known-good Mocha set; only override if upstream is newer.)

- [ ] **Step 2: Append the `[delta]` section after the existing `[color]` block**

Find (end of file):
```
[color]
    ui = auto
```
Replace with:
```
[color]
    ui = auto

[delta]
    # Catppuccin Mocha. syntax-theme is bundled in delta 0.19.2
    # (`delta --list-syntax-themes` shows "Catppuccin Mocha"). The UI colors
    # below are the canonical Catppuccin Mocha delta palette.
    navigate = true
    line-numbers = true
    syntax-theme = "Catppuccin Mocha"
    dark = true
    file-style = "#cdd6f4"
    file-decoration-style = "#cdd6f4"
    hunk-header-decoration-style = "#89b4fa" box ul
    hunk-header-file-style = "#cdd6f4"
    hunk-header-line-number-style = "#b4befe"
    hunk-header-style = file line-number syntax
    line-numbers-left-style = "#6c7086"
    line-numbers-right-style = "#6c7086"
    line-numbers-zero-style = "#6c7086"
    line-numbers-minus-style = "#f38ba8"
    line-numbers-plus-style = "#a6e3a1"
    minus-style = syntax "#39293a"
    minus-emph-style = bold syntax "#53394c"
    plus-style = syntax "#2c3b35"
    plus-emph-style = bold syntax "#404f4a"
    blame-palette = "#1e1e2e #181825 #11111b #313244 #45475a"
    commit-decoration-style = "#b4befe" box ul
```

- [ ] **Step 3: Render the chezmoi template + validate git accepts the config**

Run:
```bash
chezmoi execute-template < chezmoi/dot_gitconfig.tmpl > /tmp/gitconfig.test && git config -f /tmp/gitconfig.test --get delta.syntax-theme && echo "GITCONFIG OK"; rm -f /tmp/gitconfig.test
```
Expected: prints `Catppuccin Mocha` then `GITCONFIG OK` (template renders, git parses the `[delta]` section).

- [ ] **Step 4: Smoke-test delta rendering with the new theme**

Run: `git -c include.path=/dev/null -c delta.syntax-theme="Catppuccin Mocha" -c core.pager=delta diff HEAD~1 HEAD | head -40 || true`
Expected: a syntax-highlighted diff renders without delta erroring on the theme name.

---

## Task 10: Changelog + whole-repo verification

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Append the changelog row**

Add a new row to the table (match the existing column shape: change description | README update? | notes). Content:
```
| Switched the workstation dark theme from Tokyo Night to **Catppuccin Mocha** across WezTerm (`color_scheme` flip + new `mocha` palette table replacing all inline chrome/tab/status hexes + HOST_ACCENTS remap), zellij (`theme "catppuccin-mocha"`, a built-in in pinned 0.40.1), fzf (official Mocha `--color` spec appended to `FZF_DEFAULT_OPTS` in both `dot_zshrc.tmpl` and `dot_bashrc.tmpl` — parity pair), and delta (new `[delta]` section in `dot_gitconfig.tmpl`, `syntax-theme = "Catppuccin Mocha"` bundled in delta 0.19.2 + Mocha UI colors). Helix deliberately left on `tokyo_night`. starship/eza/grep untouched — they use ANSI named colors and re-tint from WezTerm's new 16-color palette automatically. | No | Tool color theme is not documented in `README.html` (only the doc page's own light/dark toggle), so README is unchanged. No CLAUDE.md invariant added — the change rides existing invariants (zsh/bash FZF_* parity pair; KDL `//`-comment + space-modifier rules for `config.kdl`). |
```

- [ ] **Step 2: CRLF / line-ending sweep on every edited text file**

Run:
```bash
file chezmoi/dot_config/wezterm/wezterm.lua chezmoi/dot_config/zellij/config.kdl chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl chezmoi/dot_gitconfig.tmpl | grep -i crlf && echo "!!! CRLF FOUND — repair with sed -i 's/\r$//'" || echo "NO CRLF — OK"
```
Expected: `NO CRLF — OK`

- [ ] **Step 3: Full diff review**

Run: `git --no-pager diff --stat && git --no-pager diff chezmoi/ CLAUDE_CHANGELOG.md`
Expected: only the 6 intended files changed (5 config + changelog); the spec/plan docs are new untracked files; no accidental edits to the HOSTS sentinel block or unrelated lines.

- [ ] **Step 4: Commit (GATED on user approval — see commit policy at top)**

```bash
git switch -c feat/catppuccin-mocha
git add chezmoi/dot_config/wezterm/wezterm.lua chezmoi/dot_config/zellij/config.kdl chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl chezmoi/dot_gitconfig.tmpl
git commit -m "feat(theme): switch WezTerm/zellij/fzf/delta to Catppuccin Mocha"
git add docs/superpowers/specs/2026-05-30-catppuccin-mocha-theme-design.md docs/superpowers/plans/2026-05-30-catppuccin-mocha-theme.md CLAUDE_CHANGELOG.md
git commit -m "docs(theme): add Catppuccin Mocha spec, plan, and changelog row"
```

---

## Manual / visual verification (post-apply, by the user)

These can't be automated here (WezTerm runs on the Windows side; zellij `main` is a live remote session):

- [ ] WezTerm `Ctrl+Shift+R` reload → background is Mocha base (`#1e1e2e`), tab bar + per-host accent tints look Catppuccin, copied-badge is Mocha green.
- [ ] `cza` on a managed host, then a **fresh** zellij session (`zellij kill-session main` then reattach, or open a new SSH tab) → status bar is Catppuccin Mocha (a running `main` keeps the old theme until recreated).
- [ ] Open fzf (e.g. `Ctrl+R`) → prompt/pointer/hl colors are Mocha mauve/red/rosewater.
- [ ] `git diff` on any repo → delta add/remove backgrounds + line numbers are Catppuccin Mocha.

---

## Self-review notes

- **Spec coverage:** A=Tasks 1-6, B=Task 7, C=Task 8, D=Task 9, E=Task 10 (changelog; README confirmed unneeded). All spec sections mapped.
- **No placeholders:** every edit step has concrete before/after. Task 9 Step 1 is a real cross-check (not a TODO) guarding the only uncertain values (delta blended diff backgrounds); Step 2 ships a known-good set regardless.
- **Type/name consistency:** the `mocha` table keys (`base/mantle/crust/surface0/surface1/surface2/overlay0/text/blue/mauve/sky/green/yellow/peach/red/teal`) are defined in Task 1 and every later reference (Tasks 2-6) uses only those keys.
