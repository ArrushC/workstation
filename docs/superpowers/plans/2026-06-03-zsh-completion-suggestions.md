# zsh autosuggestions + syntax-highlighting + fzf-tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three hand-vendored, pinned zsh prompt plugins — fzf-tab (fzf-driven Tab menu), zsh-autosuggestions (inline history hints), zsh-syntax-highlighting (live coloring) — wired into `dot_zshrc.tmpl` in the correct load order and Catppuccin-themed, with bash parity notes and docs.

**Architecture:** Vendor each plugin verbatim into its own subdir under `chezmoi/dot_config/zsh/plugins/`, with provenance in a chezmoi-ignored `.vendor` sidecar (no upstream files hand-edited). A new "zsh plugins" block in `dot_zshrc.tmpl` sources them after the existing Shift+Arrow block in the load-bearing order fzf-tab → autosuggestions → syntax-highlighting (last). `compinit` and `fzf` are already wired; no Makefile/tool changes. Deploys on dev + prod; already Windows-ignored via `dot_config/zsh`.

**Tech Stack:** zsh ZLE plugins (shell), chezmoi (source-state dotfile management), git.

> **Spec:** `docs/superpowers/specs/2026-06-03-zsh-completion-suggestions-design.md`
> **Repo root:** `/home/arrush.chaturvedi/.local/share/chezmoi` (all paths below are relative to it).
> **Branch:** already on `feat/zsh-completion-suggestions`.
> **Note on "tests":** dotfiles have no unit-test framework. The verification analog for each task is a concrete command (`file`, `zsh -n`, `chezmoi diff`, interactive smoke check) with an expected result — run it and confirm before committing.

---

## File Structure

**New (vendored, committed):**
- `chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh` + `.vendor`
- `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh` + `highlighters/…` (+ `dot_version` if present) + `.vendor`
- `chezmoi/dot_config/zsh/plugins/fzf-tab/fzf-tab.zsh` + `lib/…` + `.vendor`

**Modified:**
- `chezmoi/dot_zshrc.tmpl` — new "zsh plugins" block (sources + zstyles + theming)
- `chezmoi/dot_bashrc.tmpl` — parity-note comment
- `README.html` — "Completion & suggestions" subsection + TOC entry
- `CLAUDE.md` — vendored-files bullet + load-order invariant
- `docs/claude/file-care.md` — per-plugin care entries + parity note
- `CLAUDE_CHANGELOG.md` — one row

**Untouched:** `makefile/*`, `.chezmoiignore.tmpl` (already covers `dot_config/zsh`), `scope.mk`, Windows scripts, existing `zsh-shift-select.zsh`.

---

## Preflight: confirm network + clean tree

- [ ] **Step 1: Verify outbound network to GitHub (vendoring needs it)**

Run:
```bash
curl -fsSI https://github.com >/dev/null && echo NET-OK || echo NET-FAIL
```
Expected: `NET-OK`. If `NET-FAIL`, **stop** and report — do not fabricate checksums or files.

- [ ] **Step 2: Confirm branch + clean working tree**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git branch --show-current   # expect: feat/zsh-completion-suggestions
git status --porcelain      # expect: empty
```

---

## Task 1: Vendor zsh-autosuggestions (v0.7.1)

**Files:**
- Create: `chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh`
- Create: `chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/.vendor`

- [ ] **Step 1: Fetch the pinned tarball and record its sha256**

```bash
cd /tmp && rm -rf zsh-as && mkdir zsh-as && cd zsh-as
curl -fsSL -o src.tar.gz https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v0.7.1.tar.gz
sha256sum src.tar.gz | tee /tmp/zsh-as.sha256
tar xzf src.tar.gz
ls zsh-autosuggestions-0.7.1/zsh-autosuggestions.zsh   # confirm the single combined file exists
```
Expected: the `.zsh` path lists; note the printed sha256 (used in Step 3).

- [ ] **Step 2: Place the file verbatim into the chezmoi source tree**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
mkdir -p chezmoi/dot_config/zsh/plugins/zsh-autosuggestions
cp /tmp/zsh-as/zsh-autosuggestions-0.7.1/zsh-autosuggestions.zsh \
   chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
chmod 0644 chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
```

- [ ] **Step 3: Write the `.vendor` provenance sidecar**

Create `chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/.vendor` (replace `<SHA256>` with the value from Step 1):
```
plugin:         zsh-autosuggestions
upstream:       https://github.com/zsh-users/zsh-autosuggestions
tag:            v0.7.1
tarball:        https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v0.7.1.tar.gz
tarball-sha256: <SHA256>
license:        MIT
vendored:       2026-06-03
files:          zsh-autosuggestions.zsh  (single combined upstream distributable, verbatim)
note:           Leading-dot filename → chezmoi-ignored; provenance only, never deployed.
                Bump: re-download the new tag, replace the .zsh, refresh tag + sha256 here.
```

- [ ] **Step 4: Verify LF-only + parses + not executable**

```bash
file chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh   # must NOT say "CRLF"
zsh -n chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh && echo PARSE-OK
git ls-files --others --exclude-standard chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/
```
Expected: `file` shows ASCII/UTF-8 text (no "CRLF"); `PARSE-OK`; the two new files listed. If `file` reports CRLF: `sed -i 's/\r$//' <path>`.

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/
git commit -m "feat(zsh): vendor zsh-autosuggestions v0.7.1 (pinned)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Vendor zsh-syntax-highlighting (0.8.0)

**Files:**
- Create: `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh`
- Create: `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/highlighters/**`
- Create (if present upstream): `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/dot_version`
- Create: `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/.vendor`

- [ ] **Step 1: Fetch the pinned tarball and record its sha256**

```bash
cd /tmp && rm -rf zsh-sh && mkdir zsh-sh && cd zsh-sh
curl -fsSL -o src.tar.gz https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/0.8.0.tar.gz
sha256sum src.tar.gz | tee /tmp/zsh-sh.sha256
tar xzf src.tar.gz
ls zsh-syntax-highlighting-0.8.0/zsh-syntax-highlighting.zsh
ls -d zsh-syntax-highlighting-0.8.0/highlighters/*/   # main brackets pattern cursor line regexp root
```
Expected: entry file + 7 highlighter dirs list; note the sha256.

- [ ] **Step 2: Place the entry file + the full `highlighters/` tree (verbatim)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
SRC=/tmp/zsh-sh/zsh-syntax-highlighting-0.8.0
DST=chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting
mkdir -p "$DST"
cp "$SRC/zsh-syntax-highlighting.zsh" "$DST/zsh-syntax-highlighting.zsh"
cp -R "$SRC/highlighters" "$DST/highlighters"
# Optional version file: the entry script reads ./.version for $ZSH_HIGHLIGHT_VERSION.
# chezmoi ignores leading-dot source names, so deploy it via the dot_ prefix.
[ -f "$SRC/.version" ] && cp "$SRC/.version" "$DST/dot_version"
# Drop anything that isn't needed at runtime (tests/docs/Makefile aren't copied
# because we only copied the entry file + highlighters/ above). Ensure 0644.
find "$DST" -type f -exec chmod 0644 {} +
```

- [ ] **Step 3: Write the `.vendor` provenance sidecar**

Create `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/.vendor` (replace `<SHA256>`):
```
plugin:         zsh-syntax-highlighting
upstream:       https://github.com/zsh-users/zsh-syntax-highlighting
tag:            0.8.0
tarball:        https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/0.8.0.tar.gz
tarball-sha256: <SHA256>
license:        BSD-3-Clause
vendored:       2026-06-03
files:          zsh-syntax-highlighting.zsh + highlighters/{main,brackets,pattern,cursor,line,regexp,root}/
                dot_version (deploys as .version → populates $ZSH_HIGHLIGHT_VERSION), if present upstream
note:           Leading-dot .vendor → chezmoi-ignored; provenance only, never deployed.
                Entry uses ${0:A:h} to find highlighters/ — keep the tree intact.
                Bump: re-download the new tag, replace files, refresh tag + sha256 here.
```

- [ ] **Step 4: Verify LF-only + entry parses**

```bash
DST=chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting
file "$DST/zsh-syntax-highlighting.zsh" "$DST"/highlighters/main/*.zsh   # none may say "CRLF"
zsh -n "$DST/zsh-syntax-highlighting.zsh" && echo PARSE-OK
find "$DST" -type f | sort
```
Expected: no "CRLF"; `PARSE-OK`; file list shows the entry, `highlighters/*/*.zsh`, `.vendor`, and `dot_version` (if upstream shipped it). If any CRLF: `find "$DST" -type f -exec sed -i 's/\r$//' {} +`.

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/
git commit -m "feat(zsh): vendor zsh-syntax-highlighting 0.8.0 (pinned)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Vendor fzf-tab (latest stable tag)

**Files:**
- Create: `chezmoi/dot_config/zsh/plugins/fzf-tab/fzf-tab.zsh`
- Create: `chezmoi/dot_config/zsh/plugins/fzf-tab/lib/**`
- Create: `chezmoi/dot_config/zsh/plugins/fzf-tab/.vendor`

- [ ] **Step 1: Discover the latest stable tag (fzf-tab ships tags, not always release assets)**

```bash
git ls-remote --tags --sort=-v:refname https://github.com/Aloxaf/fzf-tab \
  | grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | head -1
```
Expected: a tag like `refs/tags/vX.Y.Z`. Record `TAG=vX.Y.Z` for the next steps. (If no `vX.Y.Z` tag exists, fall back to the newest tag printed without the `^{}` suffix.)

- [ ] **Step 2: Fetch the pinned tarball and record its sha256**

```bash
cd /tmp && rm -rf fzf-tab && mkdir fzf-tab && cd fzf-tab
TAG=vX.Y.Z   # <- the tag from Step 1
curl -fsSL -o src.tar.gz "https://github.com/Aloxaf/fzf-tab/archive/refs/tags/${TAG}.tar.gz"
sha256sum src.tar.gz | tee /tmp/fzf-tab.sha256
tar xzf src.tar.gz
DIR=$(echo fzf-tab-*/)
ls "${DIR}fzf-tab.zsh"; ls -d "${DIR}lib/"
```
Expected: `fzf-tab.zsh` + `lib/` exist; note the sha256.

- [ ] **Step 3: Place `fzf-tab.zsh` + `lib/` (skip the optional compiled `modules/`)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
SRC=$(echo /tmp/fzf-tab/fzf-tab-*/)
DST=chezmoi/dot_config/zsh/plugins/fzf-tab
mkdir -p "$DST"
cp "${SRC}fzf-tab.zsh" "$DST/fzf-tab.zsh"
cp -R "${SRC}lib" "$DST/lib"
find "$DST" -type f -exec chmod 0644 {} +
# NOTE: we intentionally do NOT copy modules/ (compiled C, needs a build step);
# fzf-tab's pure-zsh path works without it.
```

- [ ] **Step 4: Write the `.vendor` provenance sidecar**

Create `chezmoi/dot_config/zsh/plugins/fzf-tab/.vendor` (replace `<TAG>` and `<SHA256>`):
```
plugin:         fzf-tab
upstream:       https://github.com/Aloxaf/fzf-tab
tag:            <TAG>
tarball:        https://github.com/Aloxaf/fzf-tab/archive/refs/tags/<TAG>.tar.gz
tarball-sha256: <SHA256>
license:        MIT
vendored:       2026-06-03
files:          fzf-tab.zsh + lib/  (modules/ deliberately omitted — optional compiled C)
note:           Leading-dot .vendor → chezmoi-ignored; provenance only, never deployed.
                Sourcing fzf-tab.zsh auto-calls enable-fzf-tab. Inherits FZF_DEFAULT_OPTS theme.
                Bump: re-run the ls-remote tag check, re-download, refresh tag + sha256 here.
```

- [ ] **Step 5: Verify LF-only + parses**

```bash
DST=chezmoi/dot_config/zsh/plugins/fzf-tab
file "$DST/fzf-tab.zsh" "$DST"/lib/*   # none may say "CRLF"
zsh -n "$DST/fzf-tab.zsh" && echo PARSE-OK
find "$DST" -type f | sort
```
Expected: no "CRLF"; `PARSE-OK`; file list shows `fzf-tab.zsh`, `lib/*`, `.vendor`. If any CRLF: `find "$DST" -type f -exec sed -i 's/\r$//' {} +`.

- [ ] **Step 6: Commit**

```bash
git add chezmoi/dot_config/zsh/plugins/fzf-tab/
git commit -m "feat(zsh): vendor fzf-tab (pinned; pure-zsh, no compiled module)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire the plugins into `dot_zshrc.tmpl`

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` — insert a new block immediately **after** the Shift+Arrow block (after its closing `fi` near line 205) and **before** the `# --- nb (notes)` section.

- [ ] **Step 1: Insert the "zsh plugins" block**

Find the end of the Shift+Arrow block (the line containing only `fi` that closes `if [[ -r "$HOME/.config/zsh/plugins/zsh-shift-select.zsh" ]]; then …`) and the following blank line, just before `# --- nb (notes) ---`. Insert this block there:

```zsh
# --- zsh plugins (load order matters) ----------------------------------------
# Three vendored, pinned plugins under ~/.config/zsh/plugins/ (see each dir's
# .vendor for provenance). The order below is LOAD-BEARING:
#   1. fzf-tab                — after compinit (above) + before widget-wrappers.
#   2. zsh-autosuggestions    — after fzf-tab.
#   3. zsh-syntax-highlighting — MUST be sourced LAST: it wraps ZLE widgets and
#      has to see every widget defined above (incl. the shift-select ones).
# Each source is [[ -r ]]-guarded so a not-yet-applied host degrades silently.
# NOTE: these load before ~/.zshrc.local (sourced at the very bottom), so custom
# ZLE widgets defined in a local override are not picked up by highlighting.

# fzf-tab — replace zsh's default completion menu with an fzf picker. It shells
# out to fzf, which inherits the Catppuccin FZF_DEFAULT_OPTS set above. `menu no`
# stops zsh's own menu from racing fzf-tab; the descriptions `format` turns on
# completion groups that `<` / `>` switch between.
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
if [[ -r "$HOME/.config/zsh/plugins/fzf-tab/fzf-tab.zsh" ]]; then
  source "$HOME/.config/zsh/plugins/fzf-tab/fzf-tab.zsh"
  zstyle ':fzf-tab:*' switch-group '<' '>'
fi

# zsh-autosuggestions — fish-style inline history hints. Accept the whole
# suggestion with → (forward-char) or End. Suggestion color = Catppuccin Mocha
# overlay0 (a muted grey-blue) so it reads as a hint, not real input.
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#6c7086'
[[ -r "$HOME/.config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] \
  && source "$HOME/.config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"

# zsh-syntax-highlighting — live command-line coloring. MUST be the last
# ZLE-touching source. Theme the token styles (Catppuccin Mocha) BEFORE sourcing
# so they apply on the first prompt; enable the brackets highlighter too.
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)
typeset -gA ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[default]='fg=#cdd6f4'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#f38ba8,bold'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=#f9e2af'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[global-alias]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[function]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[command]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=#a6e3a1,underline'
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=#94e2d5'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[path]='fg=#cdd6f4,underline'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=#89b4fa'
ZSH_HIGHLIGHT_STYLES[history-expansion]='fg=#cba6f7'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=#fab387'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=#fab387'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#f9e2af'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#f9e2af'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg=#f9e2af'
ZSH_HIGHLIGHT_STYLES[command-substitution]='fg=#94e2d5'
ZSH_HIGHLIGHT_STYLES[process-substitution]='fg=#94e2d5'
ZSH_HIGHLIGHT_STYLES[back-quoted-argument]='fg=#94e2d5'
ZSH_HIGHLIGHT_STYLES[comment]='fg=#6c7086,italic'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=#89dceb'
ZSH_HIGHLIGHT_STYLES[named-fd]='fg=#89dceb'
ZSH_HIGHLIGHT_STYLES[arg0]='fg=#a6e3a1'
ZSH_HIGHLIGHT_STYLES[bracket-error]='fg=#f38ba8,bold'
ZSH_HIGHLIGHT_STYLES[bracket-level-1]='fg=#89b4fa,bold'
ZSH_HIGHLIGHT_STYLES[bracket-level-2]='fg=#a6e3a1,bold'
ZSH_HIGHLIGHT_STYLES[bracket-level-3]='fg=#f9e2af,bold'
[[ -r "$HOME/.config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] \
  && source "$HOME/.config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
```

- [ ] **Step 2: Verify the template still renders + the rendered rc parses**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
chezmoi execute-template < chezmoi/dot_zshrc.tmpl > /tmp/zshrc.rendered && echo RENDER-OK
zsh -n /tmp/zshrc.rendered && echo PARSE-OK
chezmoi diff ~/.zshrc | head -80   # review: only the new block should be added
```
Expected: `RENDER-OK`, `PARSE-OK`; the diff shows the inserted block and nothing else changed. If `chezmoi execute-template` errors on missing vars, render via `chezmoi cat ~/.zshrc > /tmp/zshrc.rendered` instead.

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_zshrc.tmpl
git commit -m "feat(zsh): wire fzf-tab + autosuggestions + syntax-highlighting (themed)

Load order: fzf-tab (after compinit) -> autosuggestions -> syntax-highlighting
(last). Catppuccin Mocha styling; fzf-tab owns Tab.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: bash parity note in `dot_bashrc.tmpl`

**Files:**
- Modify: `chezmoi/dot_bashrc.tmpl` — add a comment in the Completion section (after the existing `PARITY NOTE (cht.sh)` block at lines ~91-94, before the `bind 'set colored-stats on'` lines).

- [ ] **Step 1: Insert the parity note**

After the existing `# PARITY NOTE (cht.sh): …` paragraph and before `# Color filename completion matches …`, insert:

```bash
# PARITY NOTE (zsh plugins): zsh additionally loads three interactive prompt
# plugins — fzf-tab (fzf-driven Tab completion menu), zsh-autosuggestions
# (fish-style inline history hints) and zsh-syntax-highlighting (live command
# coloring); see dot_zshrc.tmpl. All three require zsh's ZLE; bash's readline has
# no equivalent without a heavy third-party layer (ble.sh), so there is
# deliberately no bash counterpart. Same shape as the cht.sh asymmetry above and
# the Shift+Arrow asymmetry below. bash keeps colored completion via the
# colored-stats binding just below + the system bash-completion package.
```

- [ ] **Step 2: Verify it renders + parses**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
chezmoi cat ~/.bashrc > /tmp/bashrc.rendered && bash -n /tmp/bashrc.rendered && echo OK
chezmoi diff ~/.bashrc | head -40   # only the comment block added
```
Expected: `OK`; diff shows only the new comment.

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_bashrc.tmpl
git commit -m "docs(bash): parity note for the zsh-only prompt plugins

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Apply + interactive verification

This task changes no tracked files (it applies and exercises them). No commit unless a fix is needed.

- [ ] **Step 1: Apply to the live home dir**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
chezmoi apply
ls -R ~/.config/zsh/plugins/zsh-autosuggestions ~/.config/zsh/plugins/zsh-syntax-highlighting ~/.config/zsh/plugins/fzf-tab
```
Expected: the plugin files exist under `~/.config/zsh/plugins/…`; **no** `.vendor` file present in any deployed dir (chezmoi ignores leading-dot source names).

- [ ] **Step 2: Confirm all three load in a fresh interactive shell**

```bash
zsh -ic '
  print "autosuggest:" ${+functions[_zsh_autosuggest_start]}
  print "highlight:"   ${+functions[_zsh_highlight]}
  print "fzftab:"      ${+functions[fzf-tab-complete]}
  print "hl-version:"  ${ZSH_HIGHLIGHT_VERSION:-unset}
  zstyle -L ":fzf-tab:*" | head
'
```
Expected: `autosuggest:1`, `highlight:1`, `fzftab:1` (the `1` means the function is defined); the `switch-group` zstyle prints. `hl-version` shows `0.8.0` if `dot_version` was vendored, else `unset` (cosmetic only — not a failure).

- [ ] **Step 3: Confirm no load-time errors or stderr noise**

```bash
zsh -ic 'true' 2>/tmp/zsh-stderr; echo "exit=$?"; echo "--- stderr ---"; cat /tmp/zsh-stderr
```
Expected: `exit=0` and empty stderr. Any "no such file or directory" pointing at a highlighter/lib path means a vendored file is missing — re-check Task 2/3.

- [ ] **Step 4: Interactive smoke test in a real WezTerm pane (manual)**

Open a new pane (so it's a real TTY) and confirm:
- Typing a previously-run command shows a grey inline suggestion; `→` accepts it.
- A bogus command (e.g. `zzznotacmd`) is colored red; a real one (e.g. `ls`) is green.
- `cd ` then `Tab` opens an fzf picker of directories, themed Catppuccin; `<` / `>` switch groups when multiple groups exist.
- Shift+Arrow selection (existing feature) still selects, replace-on-type still works, `Alt+W` still copies — confirms no widget-wrap regression.

- [ ] **Step 5: Startup time sanity**

```bash
for i in 1 2 3 4 5; do /usr/bin/time -f '%e s' zsh -ic exit; done 2>&1
```
Expected: still sub-second on a warm cache (the three plugins add only a few ms; `compinit -C` already fast-paths). If a host is much slower, note it — not a blocker.

---

## Task 7: Documentation

**Files:**
- Modify: `README.html` (+ `docs/README/README.css` / `.js` only if the pattern needs it)
- Modify: `CLAUDE.md`
- Modify: `docs/claude/file-care.md`
- Modify: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: README.html — add a "Completion & suggestions" subsection**

First locate the existing prompt-keys section and its TOC entry:
```bash
grep -n 'id="prompt-keys"' README.html
grep -n 'prompt-keys' README.html   # find the matching TOC <a href="#prompt-keys">
```
Read ~40 lines around the `id="prompt-keys"` `<h3>` to learn the exact markup pattern (heading classes, surrounding `<section>`/`<div>`, list styling). Then, **mirroring that markup**, add a sibling subsection immediately after the prompt-keys block:

- Heading: `<h3 id="completion">Completion &amp; suggestions</h3>`
- Body prose (adapt to the surrounding HTML element/class conventions):
  > The zsh prompt loads three vendored plugins (pinned, in `~/.config/zsh/plugins/`):
  > **zsh-autosuggestions** shows a greyed-out suggestion from your history as you type — press **→** or **End** to accept it.
  > **zsh-syntax-highlighting** colors the command line live (unknown commands in red, valid ones in green, quoted strings and paths distinguished), themed Catppuccin Mocha.
  > **fzf-tab** turns **Tab** completion into an fzf picker that reuses the same Catppuccin theme as `Ctrl-R`/`Ctrl-T`; press **&lt;** / **&gt;** to switch between completion groups.
  > These are zsh-only (bash keeps its system completion); all deploy on dev and prod.
- Add a TOC entry `<a href="#completion">Completion &amp; suggestions</a>` mirroring the prompt-keys TOC link's nesting/markup.

- [ ] **Step 2: Verify README renders (structural sanity)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
grep -c 'id="completion"' README.html        # expect 1
grep -c 'href="#completion"' README.html      # expect 1 (the TOC link)
python3 -c "import html.parser,sys
class P(html.parser.HTMLParser):
    pass
P().feed(open('README.html',encoding='utf-8').read()); print('PARSE-OK')"
```
Expected: `1`, `1`, `PARSE-OK`. (Open `README.html` in a browser if you want a visual check; not required.)

- [ ] **Step 3: CLAUDE.md — extend the vendored-files bullet + add the load-order invariant**

In the "Files Claude should be careful with" section, edit the **Vendored** bullet to append the three new dirs. Change:
```
- **Vendored — don't hand-edit; re-download at the pinned tag + refresh sha256:** `chezmoi/dot_local/share/wezterm/wezterm.terminfo`, `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`, `chezmoi/dot_config/zsh/completions/_cht.sh` (rolling — no upstream tag; bump by snapshot date + sha256, `#compdef cht.sh` stays line 1).
```
to additionally list:
```
 Also the three pinned zsh plugin dirs `chezmoi/dot_config/zsh/plugins/{zsh-autosuggestions,zsh-syntax-highlighting,fzf-tab}/` — verbatim upstream, provenance in each dir's chezmoi-ignored `.vendor` sidecar; bump = re-download the pinned tag + refresh sha256 in `.vendor`.
```
(append as a new sentence at the end of that bullet).

In the "Load-bearing invariants" index list, add:
```
- **zsh interactive plugin load order** — in `dot_zshrc.tmpl`: fzf-tab sourced after `compinit`; **zsh-syntax-highlighting sourced LAST** (it wraps ZLE widgets, must see all prior ones incl. shift-select); zsh-autosuggestions between. Reorder → highlighting/suggestions silently break. Styling is inline Catppuccin Mocha. These are zsh-only — `dot_bashrc.tmpl` carries a PARITY NOTE, no bash counterpart.
```

- [ ] **Step 4: docs/claude/file-care.md — add per-plugin entries + parity note**

Add three bullets near the existing `zsh-shift-select.zsh` / `_cht.sh` entries:
```
- **`chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/`** — vendored `zsh-users/zsh-autosuggestions` v0.7.1 (MIT), single combined `zsh-autosuggestions.zsh`. Provenance in the chezmoi-ignored `.vendor` sidecar (leading-dot → not deployed). Static, **LF-only**, plain 0644 (sourced, not executed), deploys dev + prod, Windows-ignored via the `dot_config/zsh` block. Sourced from `dot_zshrc.tmpl` after fzf-tab; suggestion color set via `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE` (Catppuccin overlay0). Bump = re-download the tag, replace the file, refresh `.vendor`.
- **`chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/`** — vendored `zsh-users/zsh-syntax-highlighting` 0.8.0 (BSD-3-Clause): entry `zsh-syntax-highlighting.zsh` + the full `highlighters/` tree (entry uses `${0:A:h}` to locate it — keep intact). Optional `dot_version` deploys as `.version` to populate `$ZSH_HIGHLIGHT_VERSION` (cosmetic). `.vendor` sidecar chezmoi-ignored. Static, **LF-only**, 0644, dev + prod, Windows-ignored. **Sourced LAST** in `dot_zshrc.tmpl` (wraps ZLE widgets); `ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)` + an inline Catppuccin Mocha `ZSH_HIGHLIGHT_STYLES` map precede the source. Bump = re-download the tag, replace files, refresh `.vendor`.
- **`chezmoi/dot_config/zsh/plugins/fzf-tab/`** — vendored `Aloxaf/fzf-tab` (MIT): `fzf-tab.zsh` + `lib/`; the optional compiled C `modules/` is **deliberately not vendored** (pure-zsh path works). `.vendor` sidecar chezmoi-ignored, records the pinned tag + sha256. Static, **LF-only**, 0644, dev + prod, Windows-ignored. Sourced in `dot_zshrc.tmpl` after `compinit`, before the widget-wrapping plugins; inherits the Catppuccin `FZF_DEFAULT_OPTS`; `menu no` + `:completion:*:descriptions format` + `:fzf-tab:* switch-group` zstyles accompany it. Bump = re-run the `git ls-remote --tags` check, re-download, refresh `.vendor`.
```
Then extend the existing `dot_zshrc.tmpl` / `dot_bashrc.tmpl` parity-pair entry with a sentence: the three zsh-only plugins are a documented asymmetry (zsh-only, bash gets a PARITY NOTE) like cht.sh / Shift+Arrow.

- [ ] **Step 5: CLAUDE_CHANGELOG.md — append one row**

Append at the end of the table:
```
| Added three vendored, pinned zsh prompt plugins: `zsh-autosuggestions` v0.7.1 (MIT), `zsh-syntax-highlighting` 0.8.0 (BSD-3), `Aloxaf/fzf-tab` (MIT, pure-zsh — no compiled module), each in its own `chezmoi/dot_config/zsh/plugins/<name>/` subdir with provenance in a chezmoi-ignored `.vendor` sidecar (verbatim upstream, zero hand-edits). New "zsh plugins" block in `dot_zshrc.tmpl` sources them in the load-bearing order fzf-tab (after compinit) → autosuggestions → syntax-highlighting (LAST), Catppuccin Mocha-themed; fzf-tab owns Tab (`menu no` + descriptions `format` + `switch-group '<' '>'`). `compinit`/`fzf` were already wired; `zsh-completions` intentionally excluded. `dot_bashrc.tmpl` gets a PARITY NOTE (zsh-only; no readline equivalent). Deploys dev + prod; already Windows-ignored via `dot_config/zsh`. | **Yes** | New `<h3 id="completion">Completion &amp; suggestions</h3>` subsection + TOC entry after the prompt-keys section (autosuggestions accept keys, live highlighting, fzf-tab Tab menu + `<`/`>` group switch). CLAUDE.md gains the vendored-files bullet extension + a new "zsh interactive plugin load order" invariant; `docs/claude/file-care.md` gains three per-plugin entries + a parity-note sentence. No new tool/Makefile change. |
```

- [ ] **Step 6: Commit the docs**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html docs/README/README.css docs/README/README.js CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(zsh): README completion subsection + CLAUDE.md/file-care/changelog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(If README.css / README.js were not touched, drop them from the `git add`.)

---

## Task 8: Final verification sweep + branch handoff

- [ ] **Step 1: Full CRLF/mode audit on the vendored tree**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
find chezmoi/dot_config/zsh/plugins/{zsh-autosuggestions,zsh-syntax-highlighting,fzf-tab} -type f -print0 \
  | xargs -0 file | grep -i crlf && echo "CRLF FOUND (fix with sed)" || echo "LF-OK"
git ls-files -s chezmoi/dot_config/zsh/plugins/ | awk '$1!="100644"{print "UNEXPECTED MODE:",$0}'
```
Expected: `LF-OK`; no "UNEXPECTED MODE" lines (all vendored files 100644).

- [ ] **Step 2: Clean diff + clean status**

```bash
git status --porcelain          # expect empty
git log --oneline -8            # the 6 task commits + the spec commit
chezmoi diff                    # expect empty (everything applied)
```

- [ ] **Step 3: Re-run the load probe once more (regression catch)**

```bash
zsh -ic 'print ${+functions[_zsh_highlight]} ${+functions[_zsh_autosuggest_start]} ${+functions[fzf-tab-complete]}'
```
Expected: `1 1 1`.

- [ ] **Step 4: Hand off via finishing-a-development-branch**

Invoke the `superpowers:finishing-a-development-branch` skill to choose how to integrate (merge to `main` / open a PR / keep the branch). Do not merge without the user's choice.

---

## Self-Review (completed during plan authoring)

**Spec coverage:** vendoring (Tasks 1-3) ✓; load-order wiring + theming + fzf-tab-owns-Tab (Task 4) ✓; bash parity note (Task 5) ✓; dev+prod / Windows-ignored / `.vendor` not deployed (verified in Task 6 Step 1) ✓; README + CLAUDE.md + file-care + changelog (Task 7) ✓; verification recipe incl. shift-select non-regression (Tasks 6, 8) ✓; network-or-stop guard (Preflight) ✓. `zsh-completions` excluded per spec ✓.

**Placeholder scan:** the only intentional fill-ins are `<SHA256>` / `<TAG>` (computed at execution — the steps print them) and the README markup (engineer mirrors existing structure after a `grep`, with exact prose given). No "TBD"/"handle edge cases"/"similar to Task N".

**Type/name consistency:** plugin dir names, function-probe names (`_zsh_highlight`, `_zsh_autosuggest_start`, `fzf-tab-complete`), `.vendor` filename, env vars (`ZSH_HIGHLIGHT_HIGHLIGHTERS`, `ZSH_HIGHLIGHT_STYLES`, `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE`), and the load order are identical across spec, rc block, verification, and docs.
