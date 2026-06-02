# cheat + cht.sh Cheatsheet Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and configure the `cheat` offline cheatsheet CLI and the `cht.sh` online cheat.sh client across dev + prod Linux hosts, with chezmoi-synced personal sheets, a seeded community pack, dev-only `rlwrap`, and zsh completion.

**Architecture:** `cheat` installs as an `EGET_TOOL` (eget decompresses its `.gz` single binary to `cheat`); `cht.sh` installs via `TOOL`+`direct.sh` (a rolling raw script). Both join `SCOPE_TOOLS` → dev + prod. chezmoi tracks `~/.config/cheat/conf.yml` + a personal sheet; a `run_once` script git-clones the community pack; a vendored `#compdef` file gives zsh-only Tab-completion; bash documents the absent upstream completion as a parity note.

**Tech Stack:** GNU Make + `makefile/lib/*` helpers, chezmoi (Go templates, `.chezmoiscripts`), zsh/bash rc, dnf (rlwrap), eget meta-installer.

**Spec:** `docs/superpowers/specs/2026-06-02-cheat-chtsh-design.md`

**Branch:** `feat/cheat-chtsh` (already created; the spec is committed there as `b7efee5`).

**Repo testing note:** This is an infra repo with no unit-test framework. "Verify" steps are exact shell commands with expected output (sandbox installs into throwaway dirs, `chezmoi cat`/`execute-template`, and `file`/`git ls-files` hygiene checks) — run each and confirm the stated result *before* the commit step.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `makefile/versions.mk` | version pins `CHEAT_VERSION`, `CHTSH_VERSION` | 1 |
| `makefile/tools.mk` | install rules for `cheat` + `cht.sh` | 1 |
| `makefile/packages.mk` | `rlwrap` in dev-only optional packages | 1 |
| `chezmoi/dot_config/cheat/conf.yml.tmpl` | cheat config + cheatpaths | 2 |
| `chezmoi/dot_config/cheat/cheatsheets/personal/workstation` | tracked starter personal sheet | 2 |
| `chezmoi/.chezmoiignore.tmpl` | Windows-ignore `dot_config/cheat` | 2 |
| `chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl` | clone community pack once | 3 |
| `chezmoi/dot_config/zsh/completions/_cht.sh` | vendored zsh completion | 4 |
| `chezmoi/dot_zshrc.tmpl` | prepend completions dir to `$fpath` | 4 |
| `chezmoi/dot_bashrc.tmpl` | parity note (no bash completion) | 4 |
| `README.html` | two tool chips (`cheat`, `cht.sh`) | 5 |
| `CLAUDE_CHANGELOG.md` | worked-example row | 5 |
| `CLAUDE.md` | `_cht.sh` in vendored careful-files bullet | 5 |
| `docs/claude/file-care.md` | per-file entry for `_cht.sh` | 5 |

---

## Task 1: Install layer (cheat + cht.sh + rlwrap)

**Files:**
- Modify: `makefile/versions.mk` (append new section after line 116)
- Modify: `makefile/tools.mk` (append new section after line 267)
- Modify: `makefile/packages.mk:43-53` (add `rlwrap` to `LINUX_OPTIONAL_PACKAGES`)

- [ ] **Step 1: Add version pins**

In `makefile/versions.mk`, after the final line (`JETBRAINSMONO_NERD_VERSION := 3.4.0`), append:

```make

# --- Cheatsheets (cheat + cht.sh) -------------------------------------------
# cheat — offline cheatsheet CLI (cheat/cheat). Non-v tag; release assets are
# gzipped single binaries (cheat-linux-amd64.gz) which eget decompresses.
# cht.sh — client for the cheat.sh online service; a rolling raw script (no
# release), so it has no real version (direct.sh always fetches latest).
CHEAT_VERSION := 5.1.0
CHTSH_VERSION := latest
```

- [ ] **Step 2: Add install rules**

In `makefile/tools.mk`, after the final `chezit` entry (the line ending `daptify14/chezit,,--asset linux_amd64))`), append:

```make

# =============================================================================
# CHEATSHEETS  (cheat — offline CLI; cht.sh — online cheat.sh client)
# Both join $(SCOPE_TOOLS) → installed on dev AND prod.
# =============================================================================

# cheat — non-v tag (5.1.0); assets are gzipped single binaries
# (cheat-linux-amd64.gz). Verified: eget 1.3.4 decompresses the .gz and installs
# a binary named `cheat` (not the asset name). --asset amd64 excludes the
# arm5/6/7/arm64 Linux variants published in the same release.
$(eval $(call EGET_TOOL,cheat,$(CHEAT_VERSION),cheat/cheat,$(CHEAT_VERSION),--asset amd64))

# cht.sh — rolling bash script served at cht.sh/:cht.sh (not a GitHub release),
# so direct.sh fetches the raw URL and installs it 0755 as `cht.sh`. On an
# offline host it simply errors at query time; cheat + tldr stay offline-capable.
$(eval $(call TOOL,cht.sh,$(CHTSH_VERSION),\
  $(LIB)/direct.sh cht.sh https://cht.sh/:cht.sh))
```

- [ ] **Step 3: Add rlwrap to dev-only optional packages**

In `makefile/packages.mk`, the `LINUX_OPTIONAL_PACKAGES := \` block (lines 43-53). Change the line:

```make
  parallel pv entr tree strace perf cronie time \
```

to:

```make
  parallel pv entr tree strace perf cronie time \
  rlwrap \
```

(`rlwrap` gives `cht.sh --shell` readline history/editing. This list is best-effort `|| true` and the whole file is a no-op unless `INSTALL_PACKAGES=true`, i.e. dev only — so rlwrap is dev-only by construction.)

- [ ] **Step 4: Verify — sandbox install (no sudo, throwaway dirs)**

Run:
```bash
rm -rf /tmp/cheattest /tmp/cheatstamp
make -C makefile cheat cht.sh MODE=prod DEST=/tmp/cheattest STAMP=/tmp/cheatstamp
ls -l /tmp/cheattest/cheat /tmp/cheattest/cht.sh
/tmp/cheattest/cheat --version
head -1 /tmp/cheattest/cht.sh
```
Expected:
- both `cheat` and `cht.sh` exist and are mode `-rwxr-xr-x`,
- `cheat --version` prints `5.1.0` (or `cheat 5.1.0`),
- `head -1 /tmp/cheattest/cht.sh` shows a shebang (e.g. `#!/bin/bash` / `#!/usr/bin/env bash`).

If `make` errors that `eget` is missing, that's expected on first run — it builds `eget` first via its order-only dep; let it finish. Clean up: `rm -rf /tmp/cheattest /tmp/cheatstamp`.

- [ ] **Step 5: Verify — no other targets broke**

Run:
```bash
make -C makefile show-tools MODE=prod 2>/dev/null | grep -E 'cheat|cht\.sh'
```
Expected: both `cheat` and `cht.sh` appear in the scope-tools list. (If `show-tools` isn't the exact target name, use `make -C makefile -n cheat MODE=prod DEST=/tmp/x STAMP=/tmp/y` and confirm it prints an eget/direct command without error.)

- [ ] **Step 6: Commit**

```bash
git add makefile/versions.mk makefile/tools.mk makefile/packages.mk
git commit -m "feat(cheat): install cheat + cht.sh (both scopes), rlwrap (dev)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: cheat config + tracked personal sheet + Windows gating

**Files:**
- Create: `chezmoi/dot_config/cheat/conf.yml.tmpl`
- Create: `chezmoi/dot_config/cheat/cheatsheets/personal/workstation`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows block, after `dot_config/helix`)

- [ ] **Step 1: Create the cheat config**

Create `chezmoi/dot_config/cheat/conf.yml.tmpl` with exactly:

```yaml
# cheat configuration — managed by chezmoi (renders to ~/.config/cheat/conf.yml).
# Templated only to expand the home dir in cheatpaths (robust vs `~`).
# `editor` is intentionally omitted so cheat inherits $EDITOR (= hx, set
# repo-wide in the rc) — no dual-edit coupling.
colorize: true
style: monokai          # chroma style (built into the cheat binary)
formatter: terminal16m  # truecolor; WezTerm supports it
pager: less -FRX
cheatpaths:
  - name: personal      # listed first -> personal sheets take precedence
    path: {{ .chezmoi.homeDir }}/.config/cheat/cheatsheets/personal
    tags: [ personal ]
    readonly: false
  - name: community     # seeded by run_once_seed-cheat-community.sh.tmpl
    path: {{ .chezmoi.homeDir }}/.config/cheat/cheatsheets/community
    tags: [ community ]
    readonly: true
```

- [ ] **Step 2: Create the starter personal sheet**

Create `chezmoi/dot_config/cheat/cheatsheets/personal/workstation` with exactly:

```
# workstation — quick reference for this dev environment.
# Synced via chezmoi. Edit with:  cheat -e workstation

# --- chezmoi (dotfiles) ---
cza          # apply tracked dotfiles
cze <file>   # edit a tracked file in source state
czd          # diff pending changes
czu          # update: pull repo + apply
czs          # status
czt          # chezit (chezmoi TUI)

# --- zellij (multiplexer) ---
zj           # zellij
zjl          # list-sessions
zja          # attach

# --- cheatsheets ---
cheat -l                  # list all sheets (personal + community)
cheat <topic>             # view a sheet (e.g. cheat tar)
cheat -e <topic>          # create/edit a personal sheet in $EDITOR
cheat -s <keyword>        # search across sheets
cht.sh <lang> <query>     # online answer (e.g. cht.sh python 'reverse a list')
cht.sh --shell            # interactive cheat.sh REPL (rlwrap on dev)

# --- provisioning ---
make MODE=dev provision   # full provisioning (dev: system-wide, sudo)
make MODE=prod provision  # per-user provisioning (prod: ~/.local)
```

- [ ] **Step 3: Gate the config out on Windows**

In `chezmoi/.chezmoiignore.tmpl`, inside the `{{ if eq .chezmoi.os "windows" }}` block, find:

```
dot_config/helix
dot_config/zellij
dot_config/zsh
```

and replace with:

```
dot_config/cheat
dot_config/helix
dot_config/zellij
dot_config/zsh
```

(cheat is not installed on the Windows host, so its config + sheets are Linux-only. The zsh completion added in Task 4 needs no new entry — `dot_config/zsh` already covers it.)

- [ ] **Step 4: Verify — templating + hygiene**

Run:
```bash
chezmoi cat ~/.config/cheat/conf.yml
chezmoi cat ~/.config/cheat/cheatsheets/personal/workstation | head -3
file chezmoi/dot_config/cheat/cheatsheets/personal/workstation
chezmoi diff | grep -E 'cheat/conf.yml|personal/workstation'
```
Expected:
- `conf.yml` renders with `{{ .chezmoi.homeDir }}` expanded to your real home (e.g. `/home/arrush.chaturvedi/.config/cheat/cheatsheets/personal`),
- the workstation sheet prints its first lines,
- `file` does NOT say "CRLF line terminators",
- `chezmoi diff` shows both as additions.

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/cheat chezmoi/.chezmoiignore.tmpl
git commit -m "feat(cheat): chezmoi config + synced personal sheet + Windows gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Community-sheets seed (run_once)

**Files:**
- Create: `chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl`

- [ ] **Step 1: Create the seed script**

Create `chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl` with exactly:

```bash
{{ if eq .chezmoi.os "linux" -}}
#!/usr/bin/env bash
# run_once_seed-cheat-community.sh — clone the cheat community cheatsheets once
# into ~/.config/cheat/cheatsheets/community, so `cheat <topic>` has the upstream
# pack available offline on a freshly provisioned host. The personal cheatpath
# and the conf.yml that references both are chezmoi-tracked and deploy normally.
#
# .tmpl gate: linux only (.chezmoiscripts/ are NOT covered by .chezmoiignore, so
# the gate lives in the body; non-linux renders empty -> chezmoi skips it).
# Soft-fail: `cza` is daily-workflow; a missing cheat/git or a network blip must
# never turn `chezmoi apply` into a failure.
set -euo pipefail

dest="$HOME/.config/cheat/cheatsheets/community"

if ! command -v cheat >/dev/null 2>&1; then
  printf 'cheat not on PATH — skipping community cheatsheet seed\n' >&2
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'git not on PATH — skipping community cheatsheet seed\n' >&2
  exit 0
fi
if [ -d "$dest" ]; then
  exit 0   # already seeded
fi
git clone --depth 1 https://github.com/cheat/cheatsheets "$dest" >/dev/null 2>&1 \
  || printf 'cheat community clone failed (offline?) — re-run later: git clone --depth 1 https://github.com/cheat/cheatsheets %s\n' "$dest" >&2
{{- end }}
```

- [ ] **Step 2: Verify — renders to valid bash**

Run:
```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl | tee /tmp/cheat-seed.rendered | head -3
bash -n /tmp/cheat-seed.rendered && echo "SYNTAX OK"
grep -c 'git clone --depth 1 https://github.com/cheat/cheatsheets' /tmp/cheat-seed.rendered
file chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl
rm -f /tmp/cheat-seed.rendered
```
Expected: renders to a `#!/usr/bin/env bash` script (linux), `bash -n` prints `SYNTAX OK`, the grep count is `1`, and `file` does NOT report CRLF.

- [ ] **Step 3: Commit**

```bash
git add chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl
git commit -m "feat(cheat): run_once seed for the community cheatsheet pack

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: zsh completion (vendored) + fpath wiring + bash parity note

**Files:**
- Create: `chezmoi/dot_config/zsh/completions/_cht.sh`
- Modify: `chezmoi/dot_zshrc.tmpl` (Completion block, before the `compinit` line ~97)
- Modify: `chezmoi/dot_bashrc.tmpl` (Completion block, ~line 90)

- [ ] **Step 1: Create the vendored zsh completion**

Create `chezmoi/dot_config/zsh/completions/_cht.sh` with exactly this content. **`#compdef cht.sh` MUST be line 1** (zsh autoload tag); the vendored header is on lines 2+:

```zsh
#compdef cht.sh
# Vendored from cht.sh (chubin/cheat.sh). DO NOT HAND-EDIT.
# Upstream: https://cheat.sh/:zsh  (rolling — no upstream version tag)
# Snapshot: 2026-06-02
# Upstream body sha256 (bytes served at cht.sh/:zsh): af384d0a3342e0156be150d4c1f64ccd94bcfde65f52f7f03b1becf359cdef24
# This copy inserts the header above AFTER the mandatory `#compdef cht.sh` first
# line; everything below is byte-verbatim upstream.
# Bump: re-download https://cheat.sh/:zsh, refresh the sha256 + snapshot date,
# keep `#compdef cht.sh` as the literal first line. Provides Tab-completion for
# the `cht.sh` command (fetches the language list from cheat.sh/:list at
# completion time — needs network).

__CHTSH_LANGS=($(curl -s cheat.sh/:list))
_arguments -C \
  '--help[show this help message and exit]: :->noargs' \
  '--shell[enter shell repl]: :->noargs' \
  '1:Cheat Sheet:->lang' \
  '*::: :->noargs' && return 0

if [[ CURRENT -ge 1 ]]; then
    case $state in
        noargs)
             _message "nothing to complete";;
        lang)
             compadd -X "Cheat Sheets" ${__CHTSH_LANGS[@]};;
        *)
             _message "Unknown state, error in autocomplete";;
    esac

    return
fi
```

- [ ] **Step 2: Verify the vendored body matches upstream**

Run:
```bash
curl -fsSL https://cheat.sh/:zsh | sha256sum
```
Expected: `af384d0a3342e0156be150d4c1f64ccd94bcfde65f52f7f03b1becf359cdef24  -`. If upstream has drifted (rolling source), update both the file body (below the header) and the header's sha256 + snapshot date to match, then continue.

- [ ] **Step 3: Wire the completions dir into zsh `$fpath`**

In `chezmoi/dot_zshrc.tmpl`, find (in the `# --- Completion ---` block, ~lines 96-97):

```
#   rm -f ~/.zcompdump && exec zsh
autoload -Uz compinit && compinit -C
```

and replace with:

```
#   rm -f ~/.zcompdump && exec zsh
# cht.sh ships a zsh completion (#compdef cht.sh) installed to
# ~/.config/zsh/completions/_cht.sh; add that dir to fpath so compinit
# autoloads it. MUST precede the compinit call below.
fpath=("$HOME/.config/zsh/completions" $fpath)
autoload -Uz compinit && compinit -C
```

- [ ] **Step 4: Add the bash parity note**

In `chezmoi/dot_bashrc.tmpl`, find (in the `# --- Completion ---` block, ~lines 89-91):

```
# because zsh has no equivalent system-wide loader.

# Color filename completion matches using LS_COLORS (readline 7+). The bashrc
```

and replace with:

```
# because zsh has no equivalent system-wide loader.

# PARITY NOTE (cht.sh): cht.sh ships completions for zsh/fish/emacs but NOT bash
# (upstream has no :bash endpoint), so there is deliberately no cht.sh
# tab-completion here. zsh gets it via ~/.config/zsh/completions/_cht.sh (see
# dot_zshrc.tmpl). Same shape as the Shift+Arrow asymmetry below.

# Color filename completion matches using LS_COLORS (readline 7+). The bashrc
```

- [ ] **Step 5: Verify — hygiene + fpath ordering**

Run:
```bash
head -1 chezmoi/dot_config/zsh/completions/_cht.sh
file chezmoi/dot_config/zsh/completions/_cht.sh
chezmoi cat ~/.zshrc | grep -nE 'completions" \$fpath|compinit'
grep -n 'PARITY NOTE (cht.sh)' chezmoi/dot_bashrc.tmpl
```
Expected:
- line 1 is exactly `#compdef cht.sh`,
- `file` does NOT report CRLF,
- in the rendered `~/.zshrc`, the `fpath=(...completions...)` line number is **smaller** than the `compinit` line number (fpath set before compinit),
- the bash parity note is present.

- [ ] **Step 6: Verify — zsh actually loads the completion (optional, if zsh present)**

Run:
```bash
zsh -fc 'fpath=("'"$PWD"'/chezmoi/dot_config/zsh/completions" $fpath); autoload -Uz compinit; compinit -u -d /tmp/zcd-cht; print -r -- ${+_comps[cht.sh]}'
rm -f /tmp/zcd-cht*
```
Expected: prints `1` (the `cht.sh` completion is registered). If `zsh` isn't installed in this environment, skip this step.

- [ ] **Step 7: Commit**

```bash
git add chezmoi/dot_config/zsh/completions/_cht.sh chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
git commit -m "feat(cheat): vendored zsh completion for cht.sh + bash parity note

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Docs + tripwire bookkeeping

**Files:**
- Modify: `README.html` (shellaug tool-card, after the `tldr` chip ~line 1011)
- Modify: `CLAUDE_CHANGELOG.md` (append table row)
- Modify: `CLAUDE.md:104` (vendored careful-files bullet)
- Modify: `docs/claude/file-care.md` (after the zsh-shift-select entry ~line 13)

- [ ] **Step 1: Add the two tool chips to README**

In `README.html`, inside the `data-cat="shellaug"` tool-card, find the `tldr` chip:

```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Practical command examples"
                                    >tldr<span class="sr-only">
                                        — practical command examples
                                        (tealdeer)</span
                                    ></span
                                >
```

and replace it with (the tldr chip unchanged, plus two new chips after it):

```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Practical command examples"
                                    >tldr<span class="sr-only">
                                        — practical command examples
                                        (tealdeer)</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Offline cheatsheets — your own (synced) + community pack"
                                    >cheat<span class="sr-only">
                                        — offline cheatsheets: personal
                                        (chezmoi-synced) + community pack</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Online cheat.sh answers (cht.sh python reverse list)"
                                    >cht.sh<span class="sr-only">
                                        — online cheat.sh client; needs
                                        network</span
                                    ></span
                                >
```

- [ ] **Step 2: Append the changelog row**

In `CLAUDE_CHANGELOG.md`, append at the end of the table (after the last `| Added shell aliases for the new dev_machine services ... |` row):

```
| Added `cheat` (offline cheatsheet CLI, `EGET_TOOL`) + `cht.sh` (online cheat.sh client, `direct.sh` raw script), both scopes; chezmoi-tracked `~/.config/cheat/conf.yml` + a synced personal sheet (`personal/workstation`); `run_once` seed git-clones the community pack; dev-only `rlwrap` for `cht.sh --shell`; vendored zsh completion `_cht.sh` (upstream ships no bash completion). | **Yes** | Two chips (`cheat`, `cht.sh`) added to the `shellaug` tool-card with offline/online `data-tip`s. No new sections — matches the atuin/tldr/asciinema single-chip precedent. CLAUDE.md gains `_cht.sh` in the vendored careful-files bullet; `docs/claude/file-care.md` gains a per-file entry. No new invariant. |
```

- [ ] **Step 3: Add `_cht.sh` to the CLAUDE.md vendored bullet**

In `CLAUDE.md`, line 104, find:

```
- **Vendored — don't hand-edit; re-download at the pinned tag + refresh sha256:** `chezmoi/dot_local/share/wezterm/wezterm.terminfo`, `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`.
```

and replace with:

```
- **Vendored — don't hand-edit; re-download at the pinned tag + refresh sha256:** `chezmoi/dot_local/share/wezterm/wezterm.terminfo`, `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`, `chezmoi/dot_config/zsh/completions/_cht.sh` (rolling source — `#compdef cht.sh` must stay line 1).
```

- [ ] **Step 4: Add the file-care entry for `_cht.sh`**

In `docs/claude/file-care.md`, immediately after the `zsh-shift-select.zsh` bullet (the line starting ``- **`chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`**``), add a new bullet:

```
- **`chezmoi/dot_config/zsh/completions/_cht.sh`** — vendored zsh completion for the `cht.sh` command, from `https://cheat.sh/:zsh` (rolling source — pinned by snapshot date + body sha256 in the file's header, since upstream publishes no version tag). **`#compdef cht.sh` MUST be the literal first line** (zsh's autoload tag); the vendored header sits on lines 2+, never above it. Static (no `.tmpl`), **LF-only**, deploys on BOTH dev and prod; Windows-ignored via the `dot_config/zsh` line in the `.chezmoiignore.tmpl` Windows block. Autoloaded because `dot_zshrc.tmpl` prepends `~/.config/zsh/completions` to `$fpath` *before* `compinit`. Calls `curl cheat.sh/:list` at completion time (needs network). bash has no counterpart — upstream ships no `:bash` completion (parity note in `dot_bashrc.tmpl`). Bump: re-download, refresh the sha256 + snapshot date, keep `#compdef` first.
```

- [ ] **Step 5: Verify — docs sanity**

Run:
```bash
grep -c '>cheat<\|>cht.sh<' README.html
grep -c '_cht.sh' CLAUDE.md docs/claude/file-care.md
grep -c 'Added `cheat`' CLAUDE_CHANGELOG.md
python3 -c "import html.parser,sys; p=html.parser.HTMLParser(); p.feed(open('README.html').read()); print('README parses')"
```
Expected: README grep ≥ 2 (both chips present), `_cht.sh` found in both CLAUDE.md and file-care.md (count ≥ 1 each), changelog row count `1`, and "README parses" prints with no exception.

- [ ] **Step 6: Commit**

```bash
git add README.html CLAUDE_CHANGELOG.md CLAUDE.md docs/claude/file-care.md
git commit -m "docs(cheat): README chips + changelog row + vendored-file tripwires

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] **End-to-end sandbox + chezmoi dry-run**

```bash
# 1. tools install clean
rm -rf /tmp/cheattest /tmp/cheatstamp
make -C makefile cheat cht.sh MODE=prod DEST=/tmp/cheattest STAMP=/tmp/cheatstamp
/tmp/cheattest/cheat --version && echo "cheat OK"
rm -rf /tmp/cheattest /tmp/cheatstamp

# 2. chezmoi sees all new tracked files, renders cleanly
chezmoi diff | grep -E 'cheat/conf.yml|personal/workstation|seed-cheat-community'
chezmoi cat ~/.config/cheat/conf.yml >/dev/null && echo "conf renders OK"

# 3. parity pair + vendored hygiene
file chezmoi/dot_config/zsh/completions/_cht.sh chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl | grep -v CRLF && echo "LF OK"
git log --oneline feat/cheat-chtsh -6
```
Expected: cheat installs + reports its version; chezmoi diff lists the new config/sheet/seed; no CRLF; six commits on the branch (spec + 5 task commits).

- [ ] **Optional: real apply on this host** (only if you want it live now)

```bash
chezmoi apply ~/.config/cheat
cheat -l            # lists personal (workstation) + community sheets
cht.sh python 'reverse a list'   # online query (needs network)
```

## Handoff / next steps

After the branch is green, use **superpowers:finishing-a-development-branch** to choose merge / PR / cleanup. The work is user-facing, so confirm `README.html` renders in a browser before merging to `main`.

---

## Self-review notes (author)

- **Spec coverage:** install (T1 ✓), rlwrap dev-only (T1 ✓), conf + personal sheet (T2 ✓), Windows gate (T2 ✓), community seed (T3 ✓), zsh completion + fpath + bash parity (T4 ✓), README/changelog/CLAUDE.md/file-care (T5 ✓). All spec §3 layers mapped.
- **No aliases** — confirmed none added (decision §2); the rc edits are fpath + a comment only.
- **Type/name consistency:** `cht.sh` is the binary name everywhere (target, alias-less invocation, `#compdef cht.sh`, `_cht.sh` filename); `cheat` binary name consistent; `community`/`personal` cheatpath names match between `conf.yml.tmpl` and the seed script's `$dest`.
- **Placeholder scan:** every step has concrete content/commands; the only "latest" is `CHTSH_VERSION` (intentional — rolling raw script, documented).
