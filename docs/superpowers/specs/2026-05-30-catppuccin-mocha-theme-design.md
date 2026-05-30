# Catppuccin Mocha theme sweep — design

**Date:** 2026-05-30
**Status:** Approved (design)
**Scope:** WezTerm + zellij + fzf + delta. Helix explicitly excluded.

## Goal

Replace the current Tokyo Night theme with **Catppuccin Mocha** as the
workstation's single dark theme, and make the other tools that don't auto-inherit
the terminal palette fit the same scheme.

## Decisions (locked with user)

- **Breadth:** WezTerm + zellij (explicit theme), plus fzf (`--color`) and delta
  (git-diff pager). `starship`, `eza`, `grep` are *not* touched — they use ANSI
  named colors / no explicit colors and re-tint automatically from WezTerm's new
  16-color palette. **Helix is out of scope.**
- **Replace, not toggle:** Catppuccin Mocha becomes the only theme. WezTerm's
  inline hexes are extracted into a named palette table (cleaner than today's
  scattered hexes); a future toggle stays trivial but is not built now (YAGNI).

## Catppuccin Mocha palette (reference)

```
base #1e1e2e   mantle #181825   crust #11111b
surface0 #313244  surface1 #45475a  surface2 #585b70
overlay0 #6c7086  overlay1 #7f849c  overlay2 #9399b2
subtext0 #a6adc8  subtext1 #bac2de  text #cdd6f4
rosewater #f5e0dc  lavender #b4befe
blue #89b4fa  mauve #cba6f7  sky #89dceb  green #a6e3a1
yellow #f9e2af  peach #fab387  red #f38ba8  teal #94e2d5
```

## Component changes

### A. WezTerm — `chezmoi/dot_config/wezterm/wezterm.lua`

1. `config.color_scheme = 'Tokyo Night'` → `'Catppuccin Mocha'` (WezTerm built-in,
   same mechanism as before). This drives the ANSI palette that starship/eza/grep
   inherit.
2. Add a named Mocha palette table near the appearance block; route every
   currently-hardcoded Tokyo Night hex through it. Behavior (8-bucket host hash,
   tab-state progression, status layout) is unchanged — only color *values* move.

   Role → Mocha mapping:

   | Role (current TN hex) | Mocha |
   |---|---|
   | main bg / `BAR_BG` / tab_bar bg (`#1a1b26`) | `base #1e1e2e` |
   | active titlebar + button bg (`#1f2335`) | `surface0 #313244` |
   | inactive titlebar bg (`#16161e`) | `mantle #181825` |
   | hover / active border (`#292e42`) | `surface1 #45475a` |
   | inactive border (`#15161e`) | `crust #11111b` |
   | fg / `FG` (`#c0caf5`) | `text #cdd6f4` |
   | muted fg / `FG_DIM` (`#565f89`) | `overlay0 #6c7086` |
   | active-local tab bg + scrollbar (`#414868`) | `surface2 #585b70` |
   | active-host tab fg (`#15161e`) | `crust #11111b` |
   | copied-badge green (`#9ece6a`) | `green #a6e3a1` |
   | HOST_ACCENTS blue/magenta/cyan/green/yellow/orange/red/teal | `blue #89b4fa · mauve #cba6f7 · sky #89dceb · green #a6e3a1 · yellow #f9e2af · peach #fab387 · red #f38ba8 · teal #94e2d5` |

3. Update stale `Tokyo Night` references in comments to `Catppuccin Mocha`.

### B. zellij — `chezmoi/dot_config/zellij/config.kdl`

`theme "tokyo-night-dark"` → `theme "catppuccin-mocha"` (verified built-in in the
pinned zellij 0.40.1; clean `setup --check`). A running `main` session keeps its
old theme until recreated (`zellij kill-session main`).

### C. fzf — `chezmoi/dot_zshrc.tmpl` AND `chezmoi/dot_bashrc.tmpl` (parity pair)

Append the official Catppuccin Mocha `--color` spec to the existing
`FZF_DEFAULT_OPTS`. Identical text in both files (the `FZF_*` parity invariant).

```
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc
  --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8
  --color=selected-bg:#45475a,border:#6c7086,label:#cdd6f4
```

### D. delta — `chezmoi/dot_gitconfig.tmpl`

`core.pager = delta` already set. Add a `[delta]` section with
`syntax-theme = "Catppuccin Mocha"` (bundled in delta 0.19.2) and Catppuccin-Mocha
UI colors: `minus-style` / `plus-style` (+ emph variants), `line-numbers` colors,
`file-style` / `hunk-header` decorations, plus `navigate = true` and
`line-numbers = true` quality-of-life.

### E. Docs

- **No README change** — the tool color theme is not documented in `README.html`
  (only the doc page's own light/dark toggle). Passes the "could a user still
  operate the repo?" test.
- Append one `CLAUDE_CHANGELOG.md` row (README column: **No**) so the worked-example
  archive stays complete.

## Out of scope / non-goals

- Helix (excluded by request).
- bat / btop / yazi / gitui / glow theme files (the "comprehensive" tier was not chosen).
- starship.toml (keeps ANSI named colors; inherits the new palette).
- No theme toggle / dual-palette support.

## Verification

- `zellij setup --check` against the edited config staged with `layouts/` → clean parse.
- Lua syntax check of `wezterm.lua` if an interpreter is present (`luac -p` / `lua -p`),
  else careful diff review.
- `git diff` across all five files; confirm no CRLF introduced into the shell rc /
  lua files and chezmoi naming is untouched.
- Visual smoke test after WezTerm `Ctrl+Shift+R` reload and a *fresh* zellij session
  (`zellij kill-session main` then reattach); fzf popup and `git diff` (delta) eyeballed.

## Risks / notes

- WezTerm built-in scheme name must be exactly `Catppuccin Mocha` — confirmed as a
  standard bundled scheme; same trust model as the existing `Tokyo Night` name.
- zellij theme change won't show in a live `main` session until recreated.
- fzf edit MUST land in both rc files in the same commit (parity invariant).
