# dircolors integration (Catppuccin Mocha) — design

**Date:** 2026-05-30
**Status:** Approved (design)
**Scope:** New `~/.dircolors` database + `LS_COLORS` wiring + colored tab-completion, on all Linux hosts (dev + prod). Windows unaffected.

## Goal

Set a Catppuccin Mocha-themed `LS_COLORS` from a hand-authored, committed
`dircolors` database, so file-type/extension colors are consistent and on-theme
across `eza`, GNU `ls --color`, `fzf`, and the shell's tab-completion menus.
Today nothing sets `LS_COLORS` — `eza` falls back to its built-in palette and
completion menus are uncolored. This extends the recent Catppuccin Mocha sweep
(see `2026-05-30-catppuccin-mocha-theme-design.md`) to the file-listing layer.

## Decisions (locked with user)

- **Approach:** GNU `dircolors` (coreutils — already present, no new install) eval'ing a
  vendored, hand-editable database. *Not* `vivid` (rejected: adds a provisioned
  binary that runs at every shell startup). *Not* the default 16-color palette
  (rejected: clashes with the new Mocha theme).
- **Database breadth:** recolor the **GNU default database** (`dircolors -p`
  structure — all standard file types + ~80 common extension entries) to
  Catppuccin Mocha truecolor. Comprehensive and recognizable, not a curated subset.
- **Completions:** yes — feed `LS_COLORS` into zsh completion `list-colors` and
  bash readline `colored-stats` / `colored-completion-prefix`.
- **Scope:** all Linux hosts (dev **and** prod). Plain Linux dotfile — **not**
  behind the dev-only `private_dot_claude` gate. Windows ignores it.
- **eza aliases unchanged:** `eza` auto-reads `LS_COLORS` for filename/extension
  colors; `EZA_COLORS` (eza's own UI columns) is left at eza defaults. No alias edits.

## Catppuccin Mocha palette (reference)

```
base #1e1e2e   mantle #181825   crust #11111b
surface0 #313244  surface1 #45475a  surface2 #585b70
overlay0 #6c7086  overlay1 #7f849c  overlay2 #9399b2
subtext0 #a6adc8  subtext1 #bac2de  text #cdd6f4
rosewater #f5e0dc  flamingo #f2cdcd  pink #f5c2e7  mauve #cba6f7
red #f38ba8  maroon #eba0ac  peach #fab387  yellow #f9e2af
green #a6e3a1  teal #94e2d5  sky #89dceb  sapphire #74c7ec
blue #89b4fa  lavender #b4befe
```

## Component changes

### A. New database — `chezmoi/dot_dircolors` → `~/.dircolors`

Static (no `.tmpl`). Derived from `dircolors -p` (GNU coreutils 8.x), with every
color value recolored to Catppuccin Mocha **truecolor** (`38;2;r;g;b`). Leading
comment block carries a palette legend + role→hex mapping. The `TERM`/`COLORTERM`
match lines from the default db are retained (harmless; the host advertises
`COLORTERM=truecolor`).

File-type role → Mocha mapping:

| dircolors key | role | Mocha |
|---|---|---|
| `NORMAL` / `FILE` | default text | (none — terminal default) |
| `RESET` | reset | `0` |
| `DIR` | directory | `blue #89b4fa` bold |
| `LINK` | symlink | `teal #94e2d5` |
| `MULTIHARDLINK` | hardlinked | `sky #89dceb` |
| `FIFO` (pipe) | named pipe | `yellow #f9e2af` on `surface0 #313244` |
| `SOCK` | socket | `pink #f5c2e7` |
| `DOOR` | door | `pink #f5c2e7` |
| `BLK` | block device | `yellow #f9e2af` bold |
| `CHR` | char device | `peach #fab387` bold |
| `ORPHAN` | broken symlink | `red #f38ba8` on `surface0 #313244` bold |
| `MISSING` | missing target | `red #f38ba8` bold |
| `EXEC` | executable | `green #a6e3a1` bold |
| `SETUID` | setuid | `red #f38ba8` bold |
| `SETGID` | setgid | `maroon #eba0ac` bold |
| `CAPABILITY` | file caps | `maroon #eba0ac` |
| `STICKY` | sticky dir | `base #1e1e2e` on `blue #89b4fa` |
| `OTHER_WRITABLE` | o+w dir | `blue #89b4fa` on `surface0 #313244` |
| `STICKY_OTHER_WRITABLE` | +t,o+w dir | `base #1e1e2e` on `green #a6e3a1` |

Extension-group → Mocha mapping (covers the ~80 default entries):

| group | examples | Mocha |
|---|---|---|
| archives / compressed | `.tar .tgz .zip .gz .xz .zst .7z .rar .bz2 .deb .rpm` | `maroon #eba0ac` |
| images | `.jpg .jpeg .png .gif .bmp .svg .webp .tiff .ico` | `mauve #cba6f7` |
| video | `.mkv .mp4 .mov .avi .webm .flv .m4v` | `pink #f5c2e7` |
| audio | `.mp3 .flac .wav .ogg .opus .aac .m4a` | `sky #89dceb` |
| documents | `.pdf .md .txt .tex .epub .odt` | `subtext1 #bac2de` |

(Anything outside these groups inherits `NORMAL`; `eza` adds its own built-in
knowledge for the long tail.) Final mapping refined during implementation; the
db must parse cleanly under `dircolors -b`.

### B. Shell wiring — `chezmoi/dot_zshrc.tmpl` AND `chezmoi/dot_bashrc.tmpl` (parity pair)

New `# --- Colors (dircolors / LS_COLORS) ---` section, placed **before** the
Completion section so `LS_COLORS` is exported when completion reads it. Identical
behavior in both files (syntax differs per shell):

```sh
if command -v dircolors >/dev/null 2>&1; then
  if [ -r "$HOME/.dircolors" ]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
  else
    eval "$(dircolors -b)"        # built-in fallback if dotfile not yet applied
  fi
fi
```

`dircolors -b` emits both `LS_COLORS='…'` and `export LS_COLORS`, so `eza` / `ls`
/ `fzf` children inherit it.

**Completion colors:**
- **zsh** (Completion section, after `compinit`): `zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"`
- **bash** (readline; interactive-guarded with `[[ $- == *i* ]]`):
  `bind 'set colored-stats on'` + `bind 'set colored-completion-prefix on'`

### C. `.chezmoiignore.tmpl`

Add `dot_dircolors` to the **Windows** ignore block (the
`{{ if eq .chezmoi.os "windows" }}` branch, alongside `dot_bashrc.tmpl` /
`dot_nbrc`) so it isn't deployed to `%USERPROFILE%`. No dev/prod gating (applies
to both Linux groups).

### D. Docs

- **No `README.html` change.** Consistent with the Catppuccin Mocha theme-sweep
  precedent ("tool color theme is not documented in README.html"). dircolors adds
  no new command, flag, or operating step — the dotfile deploys automatically on
  `chezmoi apply`. Passes the "could a user still operate the repo?" test.
- Append one `CLAUDE_CHANGELOG.md` row (README column: **No**).
- `CLAUDE.md` touch-ups (minimal):
  - Extend the `dot_zshrc.tmpl`/`dot_bashrc.tmpl` parity-pair bullet's env-var
    list to include the `dircolors`/`LS_COLORS` eval + completion-color wiring.
  - Add `dot_dircolors` to the Linux chezmoi-diff verification list under
    "Quick verification".

## Out of scope / non-goals

- `vivid`, or any new provisioned binary (rejected approach).
- `EZA_COLORS` (eza's own column theming) — left at eza defaults.
- `GREP_COLORS` / `grep --color` styling (separate mechanism; unchanged).
- `bat` / `delta` / other tool themes (handled by the prior theme sweep).
- macOS `gdircolors` handling — no macOS host in the fleet; the `command -v
  dircolors` guard simply no-ops if absent.

## Verification

- `dircolors -b chezmoi/dot_dircolors` → exits 0 with **no warnings** (valid db).
- `git diff` across the edited files: no CRLF introduced into the shell rc / db
  files; chezmoi naming untouched.
- After `chezmoi apply` on a Linux host:
  - `echo "$LS_COLORS" | tr ':' '\n' | grep -c '38;2'` → > 0 (truecolor codes present).
  - `ls --color=always` and `eza` render Mocha colors; `ls -d /tmp` (dir) shows blue.
  - zsh: trigger completion (`ls <Tab>` in a dir with mixed file types) → menu is colored.
  - bash: `bind -v | grep colored-stats` → `on`.
- `chezmoi diff` clean on a Windows host (no `dot_dircolors`).

## Risks / notes

- GNU `dircolors` accepts `38;2;r;g;b` truecolor codes (pass-through; validated by
  the no-warning parse check). The host already exports `COLORTERM=truecolor`.
- The two rc edits MUST land in the **same commit** (zshrc/bashrc parity invariant).
- `LS_COLORS` section must sit **before** completion wiring in each rc, or
  `list-colors` reads an empty value at source time.
- A running zsh/bash session keeps its old (empty) `LS_COLORS` until re-sourced
  (`exec zsh` / `exec bash`) — expected.
