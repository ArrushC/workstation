# Shift+Arrow editor-style selection at the shell prompt

**Date:** 2026-05-31
**Status:** Approved (design)
**Scope:** zsh + bash prompt line-editing; no WezTerm changes.

## Problem

Pressing `Shift+Left` at the zsh prompt leaks literal `;2D` into the command
line. WezTerm correctly sends the standard modifier-encoded escape sequence
`ESC[1;2D` (Shift+Left) to the running application, but zsh's ZLE (and bash's
readline) have no binding for it, so the unhandled tail is self-inserted as
text.

The goal: make `Shift+Arrow` perform editor-style text selection at the prompt,
**without** preventing other CLI tools (helix, fzf, less, `git rebase -i`, …)
from applying their own `Shift+Arrow` behavior.

## Key architectural decision

The fix lives in the **shell line editor**, not in WezTerm. WezTerm keeps
sending `ESC[1;2D` & friends unchanged. Because ZLE/readline only interpret
keys at the prompt, any full-screen CLI tool receives the raw escape sequence
and applies its own binding — the "overridable by other tools" requirement is
satisfied automatically, with zero per-tool configuration.

## Behavior

### zsh prompt — full shift-select

- `Shift+←/→` — extend a **visible** highlight by character.
- `Shift+Ctrl+←/→` — extend by word.
- `Shift+Home/End` — extend to start / end of line.
- `Shift+↑/↓` — extend by line (multi-line buffers).
- Typing a printable character **replaces** the highlighted text.
- `Backspace`/`Delete` **removes** the highlighted text.
- A plain (unshifted) arrow or any non-extending key **collapses** the
  highlight and acts normally.
- **Copy** — `Alt+W` (emacs-native `copy-region-as-kill`), extended to also push
  the selection to the system clipboard via OSC 52. `Ctrl+W` cuts to the
  kill-ring, `Ctrl+Y` pastes.

`Ctrl+C` is **not** rebound — it remains SIGINT (abort the current line).
Rebinding it to "copy" at a shell prompt would be a dangerous surprise.

### bash prompt — movement parity (readline limitation)

bash's readline has no bindable "active selection you can type over," so it
cannot render a real shift-select. It instead gets sane movement so the `;2D`
leak is gone:

- `Shift+←/→` → `backward-char` / `forward-char`
- `Shift+Ctrl+←/→` → `backward-word` / `forward-word`
- `Shift+Home/End` → `beginning-of-line` / `end-of-line`
- `Shift+↑/↓` → `previous-history` / `next-history` (same as plain ↑/↓)

The deliberate zsh-only-highlight asymmetry is documented in a comment in both
rc files (they are a strict parity pair; bash is the documented fallback shell).

## Implementation

### New vendored file

`chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`
(→ `~/.config/zsh/plugins/zsh-shift-select.zsh`)

- Verbatim **jirutka/zsh-shift-select v0.1.1**, commit
  `47296f18c52e9cdff5ddf0c28a5cc8c88ef8696e`. MIT, single file, zero deps.
- Static (no `.tmpl`), like `dot_dircolors` / `wezterm.terminfo`.
- Leading comment records the vendoring contract: upstream URL, pinned tag,
  commit SHA, and the file's sha256 (provenance + bump trigger).
- Deploys on **dev and prod** — a general shell nicety, not behind the dev gate.
- It binds exactly the sequences WezTerm emits (`\e[1;2D/C/A/B`, `\e[1;2H/F`,
  `\e[1;6D/C`, …) and creates a self-contained `shift-select` keymap; it does
  not override existing widgets.

`.chezmoiignore.tmpl`: ensure `dot_config/zsh` is ignored on Windows (only
AppData/Documents/dot_config/wezterm + `.ssh/config` deploy there). Add a
Windows ignore line only if not already covered.

### `chezmoi/dot_zshrc.tmpl`

New "Shift+Arrow selection" block, sourced after compinit/fzf so it owns the
keymap:

1. Guarded source:
   `[[ -r ~/.config/zsh/plugins/zsh-shift-select.zsh ]] && source …`
   (no-op if not yet applied).
2. **Supplement — replace-on-type:** wrap `shift-select::deselect-and-input` so
   that when the re-dispatched key is a printable self-insert and a region is
   active, excise the region by direct `$BUFFER` slicing (no kill-ring
   pollution) before the character is inserted.
3. **Supplement — clipboard copy:** wrap the `Alt+W` widget to run
   `copy-region-as-kill` (keeps kill-ring + clears highlight) *and* emit OSC 52
   with the base64-encoded selection so it reaches the system clipboard,
   including over SSH.

The block is guarded to run only in an interactive, ZLE-capable shell.

### `chezmoi/dot_bashrc.tmpl`

Parity block of `bind` lines (movement only), placed near the existing
`bind 'set colored-stats on'` block. Comment notes the zsh-only-highlight
asymmetry.

## Known interactions (intentional, not bugs)

- `Ctrl+C` stays SIGINT — never rebound.
- The plugin's `Ctrl+Shift+A` select-all never reaches zsh: WezTerm owns
  `Ctrl+Shift+A` (copy entire scrollback). Same for `Ctrl+Shift+C` (copy) and
  `Ctrl+Shift+V` (paste). These remain WezTerm-level actions.

## Files touched

- `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh` (new, vendored)
- `chezmoi/dot_zshrc.tmpl` (source + 2 supplements)
- `chezmoi/dot_bashrc.tmpl` (parity `bind` block)
- `chezmoi/.chezmoiignore.tmpl` (Windows ignore for `dot_config/zsh`, if needed)
- `README.html` (+ `docs/README/README.js`/`.css` only if needed) — user-facing keys
- `CLAUDE_CHANGELOG.md` — one row
- `CLAUDE.md` — "Files Claude should be careful with" entries for the vendored
  file + the rc supplements (parity-pair note)

## Verification

- `zsh -ic 'bindkey -l | grep -x shift-select'` — keymap exists.
- `zsh -ic 'bindkey -M shift-select'` — shifted sequences bound.
- Interactive smoke test in a WezTerm pane: select with `Shift+←/→`/word/line;
  type a char → replaces; `Backspace` → deletes selection; plain arrow →
  collapses; `Alt+W` → selection on system clipboard.
- No more `;2D` leak in either shell.
- `bash -ic 'bind -p | grep -F "1;2"'` — movement bindings present.
- `chezmoi diff` clean on a Linux host; nothing new on Windows.
- Vendored file: LF-only, sha256 matches the leading-comment record.

## Rejected alternatives

- **zsh-edit-select** (full-featured fork): auto-downloads pre-built compiled
  C agent binaries on first load, per-platform agents, rebinds `Ctrl+C`.
  Conflicts with the repo's pinned/vendored, no-supply-chain-surprise
  philosophy and the SIGINT concern.
- **Introduce a plugin manager** (zinit/antidote/sheldon): adds a network fetch
  at every shell startup and a major new moving part; against the Make+chezmoi
  design.
- **Hand-rolled inline ZLE block**: more custom code to own than vendoring a
  battle-tested, dependency-free upstream file (which matches the existing
  `wezterm.terminfo` vendoring precedent).
- **WezTerm-level Shift+Arrow handling**: would intercept the keys before the
  app, breaking the "overridable by other CLI tools" requirement.
