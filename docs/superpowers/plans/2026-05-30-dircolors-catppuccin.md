# dircolors (Catppuccin Mocha) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a committed Catppuccin Mocha `dircolors` database that themes `LS_COLORS` (eza, GNU `ls`, fzf) and colors zsh/bash tab-completion, on all Linux hosts.

**Architecture:** Add a static `chezmoi/dot_dircolors` database (GNU default recolored to Mocha truecolor). Both shell rc files `eval "$(dircolors -b ~/.dircolors)"` before their completion setup, then wire completion colors (zsh `list-colors`, bash readline `colored-stats`). Windows ignores the dotfile. No new binary, no Makefile change.

**Tech Stack:** GNU coreutils `dircolors`, chezmoi (source dir `chezmoi/`), zsh + bash rc templates.

---

## Environment note for the implementer

The repo-editing machine is **not** a chezmoi-managed target. Do **not** run `dircolors`, `chezmoi apply`, `eza`, or rely on the local coreutils version to author the database. The database content is fully specified below — copy it verbatim. Steps tagged **[target-host]** run on a real managed Linux host after `chezmoi apply`; steps tagged **[repo]** are static checks that run anywhere on the repo checkout.

## File Structure

- **Create** `chezmoi/dot_dircolors` — the Catppuccin Mocha LS_COLORS database (static, no `.tmpl`). Deploys to `~/.dircolors`. Single responsibility: the color database.
- **Modify** `chezmoi/.chezmoiignore.tmpl` — one line in the Windows-ignore branch so `dot_dircolors` isn't deployed to `%USERPROFILE%`.
- **Modify** `chezmoi/dot_zshrc.tmpl` — new Colors section (dircolors eval) + completion `list-colors`.
- **Modify** `chezmoi/dot_bashrc.tmpl` — mirror: Colors section + readline color binds (parity pair; same commit as zsh).
- **Modify** `CLAUDE_CHANGELOG.md` — one worked-example row.
- **Modify** `CLAUDE.md` — extend the parity-pair invariant + the chezmoi-diff verification list; add a "careful with" note for the new file.

---

## Task 1: Create the dircolors database + Windows ignore

**Files:**
- Create: `chezmoi/dot_dircolors`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows-ignore branch, after `dot_nbrc`)

- [ ] **Step 1: Create `chezmoi/dot_dircolors` with this exact content**

```
# ~/.dircolors — Catppuccin Mocha LS_COLORS database
#
# Consumed via:  eval "$(dircolors -b ~/.dircolors)"  (see ~/.zshrc / ~/.bashrc)
# Sets + exports LS_COLORS, used by: eza, GNU ls --color, fzf, and the shell's
# tab-completion menus. Derived from the GNU coreutils `dircolors -p` default,
# recolored to Catppuccin Mocha truecolor (38;2;R;G;B). Edit freely; re-run a
# shell (`exec zsh`) to pick changes up.
#
# Catppuccin Mocha palette (hex -> R;G;B):
#   base     #1e1e2e -> 30;30;46     surface0 #313244 -> 49;50;68
#   text     #cdd6f4 -> 205;214;244  subtext1 #bac2de -> 186;194;222
#   blue     #89b4fa -> 137;180;250  teal     #94e2d5 -> 148;226;213
#   sky      #89dceb -> 137;220;235  mauve    #cba6f7 -> 203;166;247
#   pink     #f5c2e7 -> 245;194;231  red      #f38ba8 -> 243;139;168
#   maroon   #eba0ac -> 235;160;172  peach    #fab387 -> 250;179;135
#   yellow   #f9e2af -> 249;226;175  green    #a6e3a1 -> 166;227;161
#
# Attributes: 00=none 01=bold 04=underline 07=reverse.
# 38;2;R;G;B = foreground, 48;2;R;G;B = background.

# --- Terminal capability gate ------------------------------------------------
# `COLORTERM ?*` matches any non-empty $COLORTERM. The hosts export
# COLORTERM=truecolor, so colors emit regardless of $TERM. `TERM wezterm` is
# listed explicitly because config.term='wezterm' is set fleet-wide (see
# CLAUDE.md) and would otherwise miss the GNU default TERM globs.
COLORTERM ?*
TERM Eterm
TERM ansi
TERM *color*
TERM con[0-9]*x[0-9]*
TERM cons25
TERM console
TERM cygwin
TERM dtterm
TERM gnome
TERM hurd
TERM jfbterm
TERM konsole
TERM kterm
TERM linux
TERM linux-c
TERM mlterm
TERM putty
TERM rxvt*
TERM screen*
TERM st
TERM terminator
TERM tmux*
TERM vt100
TERM wezterm
TERM xterm*

# --- File types --------------------------------------------------------------
#NORMAL 00          # normal text: terminal default
#FILE 00            # regular file: no color
RESET 0
DIR 01;38;2;137;180;250                              # directory            blue, bold
LINK 38;2;148;226;213                                # symlink              teal
MULTIHARDLINK 38;2;137;220;235                       # >1 hard link         sky
FIFO 38;2;249;226;175;48;2;49;50;68                  # named pipe           yellow on surface0
SOCK 38;2;245;194;231                                # socket               pink
DOOR 38;2;245;194;231                                # door (Solaris)       pink
BLK 01;38;2;249;226;175                              # block device         yellow, bold
CHR 01;38;2;250;179;135                              # char device          peach, bold
ORPHAN 01;38;2;243;139;168;48;2;49;50;68             # broken symlink       red on surface0, bold
MISSING 01;38;2;243;139;168                          # missing target       red, bold
SETUID 01;38;2;243;139;168                           # u+s                  red, bold
SETGID 01;38;2;235;160;172                           # g+s                  maroon, bold
CAPABILITY 38;2;235;160;172                          # file capabilities    maroon
STICKY_OTHER_WRITABLE 38;2;30;30;46;48;2;166;227;161 # +t,o+w dir           base on green
OTHER_WRITABLE 38;2;137;180;250;48;2;49;50;68        # o+w dir              blue on surface0
STICKY 38;2;30;30;46;48;2;137;180;250                # +t dir               base on blue
EXEC 01;38;2;166;227;161                             # executable           green, bold

# --- Archives / compressed (maroon, bold) ------------------------------------
.tar 01;38;2;235;160;172
.tgz 01;38;2;235;160;172
.arc 01;38;2;235;160;172
.arj 01;38;2;235;160;172
.taz 01;38;2;235;160;172
.lha 01;38;2;235;160;172
.lz4 01;38;2;235;160;172
.lzh 01;38;2;235;160;172
.lzma 01;38;2;235;160;172
.tlz 01;38;2;235;160;172
.txz 01;38;2;235;160;172
.tzo 01;38;2;235;160;172
.t7z 01;38;2;235;160;172
.zip 01;38;2;235;160;172
.z 01;38;2;235;160;172
.dz 01;38;2;235;160;172
.gz 01;38;2;235;160;172
.lrz 01;38;2;235;160;172
.lz 01;38;2;235;160;172
.lzo 01;38;2;235;160;172
.xz 01;38;2;235;160;172
.zst 01;38;2;235;160;172
.tzst 01;38;2;235;160;172
.bz2 01;38;2;235;160;172
.bz 01;38;2;235;160;172
.tbz 01;38;2;235;160;172
.tbz2 01;38;2;235;160;172
.tz 01;38;2;235;160;172
.deb 01;38;2;235;160;172
.rpm 01;38;2;235;160;172
.jar 01;38;2;235;160;172
.war 01;38;2;235;160;172
.ear 01;38;2;235;160;172
.sar 01;38;2;235;160;172
.rar 01;38;2;235;160;172
.alz 01;38;2;235;160;172
.ace 01;38;2;235;160;172
.zoo 01;38;2;235;160;172
.cpio 01;38;2;235;160;172
.7z 01;38;2;235;160;172
.rz 01;38;2;235;160;172
.cab 01;38;2;235;160;172
.wim 01;38;2;235;160;172
.swm 01;38;2;235;160;172
.dwm 01;38;2;235;160;172
.esd 01;38;2;235;160;172

# --- Images (mauve, bold) ----------------------------------------------------
.avif 01;38;2;203;166;247
.jpg 01;38;2;203;166;247
.jpeg 01;38;2;203;166;247
.mjpg 01;38;2;203;166;247
.mjpeg 01;38;2;203;166;247
.gif 01;38;2;203;166;247
.bmp 01;38;2;203;166;247
.pbm 01;38;2;203;166;247
.pgm 01;38;2;203;166;247
.ppm 01;38;2;203;166;247
.tga 01;38;2;203;166;247
.xbm 01;38;2;203;166;247
.xpm 01;38;2;203;166;247
.tif 01;38;2;203;166;247
.tiff 01;38;2;203;166;247
.png 01;38;2;203;166;247
.svg 01;38;2;203;166;247
.svgz 01;38;2;203;166;247
.mng 01;38;2;203;166;247
.pcx 01;38;2;203;166;247
.webp 01;38;2;203;166;247
.xcf 01;38;2;203;166;247
.xwd 01;38;2;203;166;247
.yuv 01;38;2;203;166;247
.cgm 01;38;2;203;166;247
.emf 01;38;2;203;166;247

# --- Video (pink, bold) ------------------------------------------------------
.mov 01;38;2;245;194;231
.mpg 01;38;2;245;194;231
.mpeg 01;38;2;245;194;231
.m2v 01;38;2;245;194;231
.mkv 01;38;2;245;194;231
.webm 01;38;2;245;194;231
.ogm 01;38;2;245;194;231
.mp4 01;38;2;245;194;231
.m4v 01;38;2;245;194;231
.mp4v 01;38;2;245;194;231
.vob 01;38;2;245;194;231
.qt 01;38;2;245;194;231
.nuv 01;38;2;245;194;231
.wmv 01;38;2;245;194;231
.asf 01;38;2;245;194;231
.rm 01;38;2;245;194;231
.rmvb 01;38;2;245;194;231
.flc 01;38;2;245;194;231
.avi 01;38;2;245;194;231
.fli 01;38;2;245;194;231
.flv 01;38;2;245;194;231
.gl 01;38;2;245;194;231
.dl 01;38;2;245;194;231
.ogv 01;38;2;245;194;231
.ogx 01;38;2;245;194;231

# --- Audio (sky) -------------------------------------------------------------
.aac 38;2;137;220;235
.au 38;2;137;220;235
.flac 38;2;137;220;235
.m4a 38;2;137;220;235
.mid 38;2;137;220;235
.midi 38;2;137;220;235
.mka 38;2;137;220;235
.mp3 38;2;137;220;235
.mpc 38;2;137;220;235
.ogg 38;2;137;220;235
.ra 38;2;137;220;235
.wav 38;2;137;220;235
.oga 38;2;137;220;235
.opus 38;2;137;220;235
.spx 38;2;137;220;235
.xspf 38;2;137;220;235

# --- Documents (subtext1) ----------------------------------------------------
.pdf 38;2;186;194;222
.md 38;2;186;194;222
.markdown 38;2;186;194;222
.txt 38;2;186;194;222
.tex 38;2;186;194;222
.rst 38;2;186;194;222
.epub 38;2;186;194;222
.odt 38;2;186;194;222
.doc 38;2;186;194;222
.docx 38;2;186;194;222
.rtf 38;2;186;194;222
```

- [ ] **Step 2: Add the Windows ignore line** — in `chezmoi/.chezmoiignore.tmpl`, inside the `{{ if eq .chezmoi.os "windows" }}` branch, add `dot_dircolors` right after the `dot_nbrc` line.

Find:
```
dot_bashrc.tmpl
dot_nbrc
dot_config/helix
```
Replace with:
```
dot_bashrc.tmpl
dot_nbrc
dot_dircolors
dot_config/helix
```

- [ ] **Step 3: [repo] Verify line endings + naming**

Run: `file chezmoi/dot_dircolors && git diff --cached --stat 2>/dev/null; grep -n 'dot_dircolors' chezmoi/.chezmoiignore.tmpl`
Expected: `file` does NOT report "CRLF"; grep shows `dot_dircolors` on one line in the Windows branch.

- [ ] **Step 4: [target-host] Verify the database parses with no warnings**

Run (on a managed Linux host, against the repo checkout): `dircolors -b chezmoi/dot_dircolors >/dev/null`
Expected: exit 0, **no** `dircolors: ...` warning lines on stderr. (Then `dircolors -b chezmoi/dot_dircolors | head -1` shows `LS_COLORS='...'`.)

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_dircolors chezmoi/.chezmoiignore.tmpl
git commit -m "feat(dircolors): add Catppuccin Mocha LS_COLORS database"
```

---

## Task 2: Wire LS_COLORS + completion colors into both shells (parity pair)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (Colors section before Completion; `list-colors` after `compinit`)
- Modify: `chezmoi/dot_bashrc.tmpl` (Colors section before Completion; readline binds in Completion)

> Both edits land in **one commit** — the zshrc/bashrc parity invariant (CLAUDE.md).

- [ ] **Step 1: zsh — add the Colors section before Completion**

In `chezmoi/dot_zshrc.tmpl`, find the start of the Completion section:
```
# --- Completion --------------------------------------------------------------
```
Insert this block **immediately before** that line:
```
# --- Colors (dircolors / LS_COLORS) ------------------------------------------
# Theme file-type/extension colors from ~/.dircolors (Catppuccin Mocha). Sets
# and exports LS_COLORS, consumed by eza, GNU ls --color, fzf, and the
# completion list-colors below. Falls back to dircolors' built-in palette if
# the dotfile isn't applied yet. No-op if dircolors is absent.
if command -v dircolors &>/dev/null; then
  if [[ -r "$HOME/.dircolors" ]]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
  else
    eval "$(dircolors -b)"
  fi
fi

```

- [ ] **Step 2: zsh — color the completion menus**

In `chezmoi/dot_zshrc.tmpl`, find:
```
autoload -Uz compinit && compinit -C
```
Insert immediately **after** that line:
```

# Color completion menus (filenames) with the same LS_COLORS palette.
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
```

- [ ] **Step 3: bash — add the Colors section before Completion**

In `chezmoi/dot_bashrc.tmpl`, find the start of the Completion section:
```
# --- Completion --------------------------------------------------------------
```
Insert this block **immediately before** that line:
```
# --- Colors (dircolors / LS_COLORS) ------------------------------------------
# Theme file-type/extension colors from ~/.dircolors (Catppuccin Mocha). Sets
# and exports LS_COLORS, consumed by eza, GNU ls --color, fzf, and the readline
# colored-stats below. Falls back to dircolors' built-in palette if the dotfile
# isn't applied yet. No-op if dircolors is absent. Mirrors the zsh block.
if command -v dircolors &>/dev/null; then
  if [[ -r "$HOME/.dircolors" ]]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
  else
    eval "$(dircolors -b)"
  fi
fi

```

- [ ] **Step 4: bash — color completion via readline**

In `chezmoi/dot_bashrc.tmpl`, find the last line of the Completion comment block:
```
# because zsh has no equivalent system-wide loader.
```
Insert immediately **after** that line (still inside the `# --- Completion ---`
section, before the blank line preceding `# --- fzf ---`):
```
# Color filename completion matches using LS_COLORS (readline 7+). The bashrc
# only runs for interactive shells (the `[[ $- != *i* ]] && return` guard at
# the top), so `bind` is always safe here.
bind 'set colored-stats on'
bind 'set colored-completion-prefix on'
```

- [ ] **Step 5: [repo] Static sanity check**

Run: `grep -n 'dircolors\|list-colors\|colored-stats' chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl && file chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl`
Expected: the dircolors eval appears in both files; `list-colors` only in zsh; `colored-stats` only in bash; neither file reports "CRLF".

- [ ] **Step 6: [target-host] Render + syntax check**

Run (managed Linux host):
```
chezmoi cat ~/.zshrc | zsh -n   # template renders to valid zsh
chezmoi cat ~/.bashrc | bash -n # template renders to valid bash
```
Expected: both exit 0 with no output.

- [ ] **Step 7: Commit (both files together)**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
git commit -m "feat(dircolors): wire LS_COLORS + colored completion into zsh/bash"
```

---

## Task 3: Documentation

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (new row at top, newest-first)
- Modify: `CLAUDE.md` (parity invariant + verification list + careful-with note)

- [ ] **Step 1: Add the changelog row**

In `CLAUDE_CHANGELOG.md`, insert this block immediately after the header lines (line 4, before the `## 2026-05-30 — Catppuccin Mocha theme sweep` entry):
```

## 2026-05-30 — dircolors integration (Catppuccin Mocha LS_COLORS)

**Change:** Added `chezmoi/dot_dircolors` (GNU default database recolored to Catppuccin Mocha truecolor) and wired `eval "$(dircolors -b ~/.dircolors)"` + colored tab-completion (zsh `list-colors`, bash readline `colored-stats`) into both shell rc files. Applies to all Linux hosts (dev + prod); ignored on Windows.

**Why:** Nothing set `LS_COLORS`, so eza used its built-in palette and completion menus were uncolored. This extends the Catppuccin Mocha sweep to the file-listing layer (eza, GNU ls, fzf, completions).

**README impact:** None — like the theme sweep, this adds no command/flag/operating step; the dotfile deploys on `chezmoi apply`. Passes the "could a user still operate the repo from README alone?" test.

**Files:** `chezmoi/dot_dircolors`, `chezmoi/.chezmoiignore.tmpl`, `chezmoi/dot_zshrc.tmpl`, `chezmoi/dot_bashrc.tmpl`, `CLAUDE.md`, `CLAUDE_CHANGELOG.md`, `docs/superpowers/specs/2026-05-30-dircolors-catppuccin-design.md`, `docs/superpowers/plans/2026-05-30-dircolors-catppuccin.md`.
```

- [ ] **Step 2: Extend the parity-pair invariant in `CLAUDE.md`**

Find:
```
Any change to env vars (EDITOR/VISUAL/PAGER/HIST*/FZF_*/NB*), aliases, functions, or the OSC 7 hook must land in BOTH files in the same commit.
```
Replace with:
```
Any change to env vars (EDITOR/VISUAL/PAGER/HIST*/FZF_*/NB*/LS_COLORS), the dircolors eval + completion-color wiring (zsh `list-colors` / bash readline `colored-stats`), aliases, functions, or the OSC 7 hook must land in BOTH files in the same commit.
```

- [ ] **Step 3: Add `dot_dircolors` to the chezmoi-diff verification list in `CLAUDE.md`**

Find:
```
Linux: only Linux-targeted paths (dot_zshrc, dot_bashrc, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc) + cross-platform `.ssh/config`.
```
Replace with:
```
Linux: only Linux-targeted paths (dot_zshrc, dot_bashrc, dot_dircolors, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc) + cross-platform `.ssh/config`.
```

- [ ] **Step 4: Add a careful-with note in `CLAUDE.md`**

Find the line that begins the wezterm.terminfo careful-with bullet:
```
- **`chezmoi/dot_local/share/wezterm/wezterm.terminfo`** — vendored from
```
Insert this bullet immediately **before** it:
```
- **`chezmoi/dot_dircolors`** — Catppuccin Mocha `LS_COLORS` database (GNU `dircolors -p` default recolored to truecolor), eval'd by both shell rc files. The leading `COLORTERM ?*` + `TERM wezterm` capability-gate lines are load-bearing: hosts run `TERM=wezterm` (see the `config.term` invariant), which misses the GNU default `TERM` globs, so without `COLORTERM ?*` (matched by the fleet's `COLORTERM=truecolor`) `dircolors` would emit an empty `LS_COLORS` and listings would lose color. Static, LF-only, applies to all Linux hosts (not behind the dev gate); Windows-ignored.
```

- [ ] **Step 5: [repo] Verify the edits applied**

Run: `grep -n 'LS_COLORS' CLAUDE.md && grep -c 'dircolors' CLAUDE_CHANGELOG.md`
Expected: `CLAUDE.md` shows the extended parity bullet + verification list + careful-with note; changelog grep count ≥ 2.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "docs(dircolors): changelog row + CLAUDE.md invariant/verification notes"
```

---

## Task 4: [target-host] End-to-end verification

Run on a managed Linux host after pulling the branch and `chezmoi apply` (then `exec zsh` / `exec bash`).

- [ ] **Step 1: LS_COLORS is set and truecolor**

Run: `exec zsh` then `echo "$LS_COLORS" | tr ':' '\n' | grep -c '38;2'`
Expected: a number > 0 (truecolor codes present). `echo "$LS_COLORS" | grep -o 'di=[^:]*'` shows `di=01;38;2;137;180;250`.

- [ ] **Step 2: ls / eza render Mocha**

Run: `ls --color=always -d /tmp | cat -v | head` and `eza -d /tmp`
Expected: directory shown in blue (`38;2;137;180;250`); no errors.

- [ ] **Step 3: zsh completion is colored**

Run (interactive zsh, in a dir with a directory + a regular file): type `ls ` then `<Tab>`.
Expected: the completion listing colorizes the directory (blue) vs file differently.

- [ ] **Step 4: bash completion is colored**

Run (interactive bash): `bind -v | grep -E 'colored-stats|colored-completion-prefix'`
Expected: both report `on`. Tab-completing a path shows colored matches.

- [ ] **Step 5: Windows host is unaffected**

Run (Windows host): `chezmoi diff`
Expected: no `dot_dircolors` / `.dircolors` in the diff.

- [ ] **Step 6: Finish the branch** — use superpowers:finishing-a-development-branch to merge/PR.

---

## Notes / risks

- **`COLORTERM ?*` is load-bearing** under `TERM=wezterm` (see Task 3 Step 4). The no-warning parse check (Task 1 Step 4) plus the non-empty-LS_COLORS check (Task 4 Step 1) together confirm it works.
- **GNU `dircolors` accepts `38;2;R;G;B` and combined `fg;bg` codes** as pass-through; the no-warning parse check is the gate.
- **Parity:** Task 2 must commit zsh + bash together.
- **Live sessions** keep their old (empty) `LS_COLORS` until re-sourced — expected; verification uses `exec zsh`/`exec bash`.
- **No Makefile/versions.mk change** — `dircolors` ships with coreutils; nothing to install or pin.
