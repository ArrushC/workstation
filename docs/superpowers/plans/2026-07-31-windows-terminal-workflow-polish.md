# Windows Terminal Workflow + Polish Upgrade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire shell-integration marks, fleet snippets, broadcast input, taskbar progress, and opaque visual polish into the managed Windows Terminal — terminal half in the tracked `settings.json`, shell half in the zsh/bash/Nushell configs.

**Architecture:** One PR on branch `wt-workflow-polish` (already created; spec committed at `docs/superpowers/specs/2026-07-31-windows-terminal-workflow-polish-design.md`). Five edited surfaces: the tracked WT `settings.json` (defaults + theme + actions/keybinds/snippets), `dot_zshrc.tmpl` (full OSC block), `dot_bashrc.tmpl` (prompt-side parity), `config.nu.tmpl` + PowerShell profile (Nushell hooks + parity note), docs (README/file-care/verification/changelog). No generators, no version pins, no new invariants.

**Tech Stack:** WT settings JSON (WT-canonical serialization), zsh/bash rc templates (chezmoi Go templates, static blocks), Nushell config, repo lint (`check-invariants.sh`, `check-templates.sh`).

## Global Constraints

- Branch: `wt-workflow-polish`; never commit on `main`.
- `settings.json` (`chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`) is **WT-canonical**: 4-space indent, object/array-valued keys serialize as `"key": ` **with a trailing space** before the newline — reproduce this style in added lines, never strip it from existing ones. `git diff --check` warnings on this file are expected. LF, UTF-8, **no BOM**, mode 100644. Alphabetical key order within objects.
- Shell gate everywhere: emit sequences only when `WT_SESSION` is set **and** `ZELLIJ` is not.
- Snippets insert text **without a trailing `\r`** — never auto-execute.
- Escape sequences: zsh/bash `printf '\e...\a'`; Nushell `"\u{1b}...\u{07}"` (nu has no `\a` escape).
- Curated progress commands (verbatim from spec): first word `make|cza|czu|dnf|cargo|npm|uv`, or two-word prefixes `git push|pull|fetch|clone`.
- rc templates are LF-only; `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` is a parity pair (the parity-reminder hook will nudge — both change in this plan).
- Verify commands run from the repo root `/home/arrush.chaturvedi/.local/share/chezmoi`.

---

### Task 1: WT `settings.json` — defaults, theme, actions, keybinds, snippets

**Files:**
- Modify: `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`

**Interfaces:**
- Produces: action IDs `User.scrollToMark.prev`, `User.scrollToMark.next`, `User.toggleBroadcastInput`, `User.showSuggestions`, `User.snippet.{cza,czu,czd,czs,makedev,lint,updatehosts,zellij}`; keybinds `ctrl+up`, `ctrl+down`, `alt+shift+b`, `ctrl+shift+space`; snippet display names `Snippet: …` (consumed verbatim by Task 5 docs).

- [ ] **Step 1: Read the file** (`Read` the whole file — Edit old_strings below must match byte-for-byte, including the trailing space after `"command": `/`"defaults": ` style keys).

- [ ] **Step 2: `profiles.defaults` — three new keys (alphabetical positions)**

Edit A (head of defaults — `adjustIndistinguishableColors` sorts before `antialiasingMode`, `autoMarkPrompts` after it):

```
old:            "antialiasingMode": "grayscale",
                "bellStyle": 
new:            "adjustIndistinguishableColors": "indexed",
                "antialiasingMode": "grayscale",
                "autoMarkPrompts": true,
                "bellStyle": 
```

(Include the trailing space after `"bellStyle": ` exactly as in the file.)

Edit B (tail of defaults):

```
old:            "padding": "8, 8, 8, 8",
                "useAcrylic": false
new:            "padding": "8, 8, 8, 8",
                "showMarksOnScrollbar": true,
                "useAcrylic": false
```

- [ ] **Step 3: theme tab icons monochrome** (single occurrence, inside `themes[0].tab`):

```
old:                "iconStyle": "default",
new:                "iconStyle": "monochrome",
```

- [ ] **Step 4: append 12 action entries** after the `User.resetFontSize` action (replace the array-closing fragment):

```json
old:
        {
            "command": "resetFontSize",
            "id": "User.resetFontSize"
        }
    ],
    "alwaysOnTop": false,
```

```json
new:
        {
            "command": "resetFontSize",
            "id": "User.resetFontSize"
        },
        {
            "command": 
            {
                "action": "scrollToMark",
                "direction": "previous"
            },
            "id": "User.scrollToMark.prev"
        },
        {
            "command": 
            {
                "action": "scrollToMark",
                "direction": "next"
            },
            "id": "User.scrollToMark.next"
        },
        {
            "command": "toggleBroadcastInput",
            "id": "User.toggleBroadcastInput"
        },
        {
            "command": 
            {
                "action": "showSuggestions",
                "source": 
                [
                    "tasks",
                    "recentCommands"
                ],
                "useCommandline": true
            },
            "id": "User.showSuggestions"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "cza"
            },
            "id": "User.snippet.cza",
            "name": "Snippet: chezmoi apply"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "czu"
            },
            "id": "User.snippet.czu",
            "name": "Snippet: chezmoi update (pull+apply)"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "czd"
            },
            "id": "User.snippet.czd",
            "name": "Snippet: chezmoi diff"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "czs"
            },
            "id": "User.snippet.czs",
            "name": "Snippet: chezmoi status"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "make -C ~/.local/share/chezmoi dev"
            },
            "id": "User.snippet.makedev",
            "name": "Snippet: full dev provision (WSL)"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "make -C ~/.local/share/chezmoi lint MODE=prod"
            },
            "id": "User.snippet.lint",
            "name": "Snippet: lint + invariants (WSL)"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "bash ~/.local/share/chezmoi/scripts/update-hosts.sh"
            },
            "id": "User.snippet.updatehosts",
            "name": "Snippet: fleet update (WSL)"
        },
        {
            "command": 
            {
                "action": "sendInput",
                "input": "zellij attach --create main"
            },
            "id": "User.snippet.zellij",
            "name": "Snippet: zellij attach main"
        }
    ],
    "alwaysOnTop": false,
```

Every `"command": ` line above (object-valued) carries the WT trailing space. Snippet entries get **no** keybindings — the Suggestions palette / command palette surfaces them by `name`.

- [ ] **Step 5: append 4 keybinding entries** after the `User.resetFontSize` binding:

```json
old:
        {
            "id": "User.resetFontSize",
            "keys": "ctrl+0"
        }
    ],
    "newTabMenu": 
```

```json
new:
        {
            "id": "User.resetFontSize",
            "keys": "ctrl+0"
        },
        {
            "id": "User.scrollToMark.prev",
            "keys": "ctrl+up"
        },
        {
            "id": "User.scrollToMark.next",
            "keys": "ctrl+down"
        },
        {
            "id": "User.toggleBroadcastInput",
            "keys": "alt+shift+b"
        },
        {
            "id": "User.showSuggestions",
            "keys": "ctrl+shift+space"
        }
    ],
    "newTabMenu": 
```

(Keep the trailing space after `"newTabMenu": `.)

- [ ] **Step 6: Verify**

```bash
F='chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json'
python3 -m json.tool "$F" > /dev/null && echo JSON-OK
jq -r '[.actions|length, .keybindings|length] | @tsv' "$F"          # expect: 25	17
jq -r '.profiles.defaults | .autoMarkPrompts, .showMarksOnScrollbar, .adjustIndistinguishableColors' "$F"   # true / true / indexed
jq -r '.themes[0].tab.iconStyle' "$F"                                # monochrome
jq -r '[.actions[] | select(.command.action? == "sendInput")] | length' "$F"   # 8
jq -r '.actions[] | select(.command.action? == "sendInput") | .command.input' "$F" | grep -c $'\r'  # 0 (no CRs)
```

`git diff --check` will flag trailing whitespace on the added `"command": ` lines — expected, do NOT fix.

- [ ] **Step 7: Commit**

```bash
git add "$F"
git commit -m "feat(windows-terminal): marks, broadcast, suggestions + 8 fleet snippets; indexed contrast + monochrome tab icons"
```

---

### Task 2: `dot_zshrc.tmpl` — full WT shell-integration block

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (insert after the starship block, ~line 191)

**Interfaces:**
- Produces: functions `_wt_precmd`/`_wt_preexec` (referenced by Task 3's PARITY NOTE and Task 5's docs). Prepends `_wt_precmd` to `precmd_functions` so it sees the real `$?`, and returns it so downstream hooks (starship) still see it.

- [ ] **Step 1: Insert the block**

```
old:
# --- starship prompt ---------------------------------------------------------
if command -v starship &>/dev/null; then
  eval "$(starship init zsh)"
fi

# --- Shift+Arrow selection (zsh ZLE) -----------------------------------------
```

```
new:
# --- starship prompt ---------------------------------------------------------
if command -v starship &>/dev/null; then
  eval "$(starship init zsh)"
fi

# --- Windows Terminal shell integration (WSL tabs) ---------------------------
# Emits the FTCS/ConEmu sequences Windows Terminal turns into UI: OSC 133 A/C/D
# prompt marks (scrollbar marks + ctrl+up/down prompt jumps, exit-code colored),
# OSC 9;9 cwd (duplicate-tab/split reopens the current directory — WT needs a
# WINDOWS path, hence wslpath -w), and OSC 9;4 taskbar progress (indeterminate
# while a curated long-runner executes; cleared at the next prompt). Gated hard:
# WT_SESSION crosses WSL interop only in local Windows Terminal tabs (unset over
# SSH), and $ZELLIJ excludes multiplexed shells — zellij composites panes, so
# the sequences would be swallowed there. _wt_precmd is PREPENDED to
# precmd_functions so it reads the real $? before other hooks run, and it
# returns that status so starship's exit-code module still sees it. bash gets
# the prompt-side half only (see the PARITY NOTE in dot_bashrc.tmpl).
if [[ -n "$WT_SESSION" && -z "$ZELLIJ" ]]; then
  _wt_precmd() {
    local _wt_status=$?
    # Previous command's mark: D;<exit> colors it green/red on the scrollbar.
    printf '\e]133;D;%s\a' "$_wt_status"
    # CWD for duplicate-tab/split (Windows path form).
    if command -v wslpath &>/dev/null; then
      printf '\e]9;9;%s\a' "$(wslpath -w "$PWD" 2>/dev/null)"
    fi
    # Prompt-start mark, then clear any taskbar progress.
    printf '\e]133;A\a'
    printf '\e]9;4;0;0\a'
    return "$_wt_status"
  }
  _wt_preexec() {
    # Output-start mark for the command about to run.
    printf '\e]133;C\a'
    # Indeterminate taskbar progress for curated long-runners.
    case "${1%% *}" in
      make | cza | czu | dnf | cargo | npm | uv) printf '\e]9;4;3;0\a' ;;
      git)
        case "$1" in
          git\ push* | git\ pull* | git\ fetch* | git\ clone*) printf '\e]9;4;3;0\a' ;;
        esac
        ;;
    esac
  }
  precmd_functions=(_wt_precmd "${precmd_functions[@]}")
  preexec_functions+=(_wt_preexec)
fi

# --- Shift+Arrow selection (zsh ZLE) -----------------------------------------
```

- [ ] **Step 2: Verify the template renders + parses**

```bash
bash scripts/check-templates.sh
```

Expected: PASS lines including `dot_zshrc.tmpl` for both host groups (zsh syntax check). Quick sanity on gating:

```bash
rg -n 'WT_SESSION' chezmoi/dot_zshrc.tmpl   # exactly the one new block
```

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_zshrc.tmpl
git commit -m "feat(zsh): WT shell integration — OSC 133 marks, 9;9 cwd, 9;4 curated taskbar progress (WT_SESSION-gated, zellij-excluded)"
```

---

### Task 3: `dot_bashrc.tmpl` — prompt-side parity block

**Files:**
- Modify: `chezmoi/dot_bashrc.tmpl` (insert after the starship block, ~line 234)

**Interfaces:**
- Consumes: naming/gating conventions from Task 2 (`_wt_` prefix, same gate).
- Produces: `_wt_prompt_cmd`, prepended to `PROMPT_COMMAND`, returning the original `$?` so `starship_precmd` (already in `PROMPT_COMMAND`) still reads the real status.

- [ ] **Step 1: Insert the block**

```
old:
# --- starship prompt ---------------------------------------------------------
if command -v starship &>/dev/null; then
  eval "$(starship init bash)"
fi

# --- nb (notes) --------------------------------------------------------------
```

```
new:
# --- starship prompt ---------------------------------------------------------
if command -v starship &>/dev/null; then
  eval "$(starship init bash)"
fi

# --- Windows Terminal shell integration (WSL tabs) ---------------------------
# Prompt-side half of the zsh block (see dot_zshrc.tmpl): OSC 133 A/D marks
# (scrollbar marks + ctrl+up/down jumps, exit-code colored), OSC 9;9 cwd
# (duplicate-tab reopens here — Windows path via wslpath -w), OSC 9;4;0
# progress clear. Runs FIRST in PROMPT_COMMAND and returns the original $? so
# starship's exit-code module still sees the real status.
# PARITY NOTE (WT preexec): zsh additionally emits OSC 133;C + OSC 9;4;3
# (output-start mark, in-flight taskbar progress) from a preexec hook. bash has
# no preexec without bash-preexec, and starship owns bash's DEBUG trap — so
# this fallback shell deliberately skips the preexec half (same precedent as
# atuin above). Marks still appear and color by exit code; there is just no
# in-flight taskbar progress.
if [[ -n "$WT_SESSION" && -z "$ZELLIJ" ]]; then
  _wt_prompt_cmd() {
    local _wt_status=$?
    printf '\e]133;D;%s\a' "$_wt_status"
    if command -v wslpath &>/dev/null; then
      printf '\e]9;9;%s\a' "$(wslpath -w "$PWD" 2>/dev/null)"
    fi
    printf '\e]133;A\a'
    printf '\e]9;4;0;0\a'
    return "$_wt_status"
  }
  PROMPT_COMMAND="_wt_prompt_cmd${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}"
fi

# --- nb (notes) --------------------------------------------------------------
```

- [ ] **Step 2: Verify**

```bash
bash scripts/check-templates.sh    # bash -n on rendered output, both host groups
```

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_bashrc.tmpl
git commit -m "feat(bash): WT shell integration parity — prompt-side OSC 133/9;9 + progress clear (PARITY NOTE: no preexec half)"
```

---

### Task 4: Nushell hooks + PowerShell parity note

**Files:**
- Modify: `chezmoi/AppData/Roaming/nushell/config.nu.tmpl` (after the Shell behaviour section)
- Modify: `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl` (header comment)

**Interfaces:**
- Consumes: curated command list from Global Constraints (regex form).
- Produces: nothing consumed downstream; Task 5 docs mention "Nushell marks are default-on".

- [ ] **Step 1: Insert the config.nu block**

```
old:
# --- Shell behaviour --------------------------------------------------------
# Mutate fields on the pre-populated default $env.config (never reassign the
# whole record — that would wipe Nushell's defaults).
$env.config.show_banner = false
```

```
new:
# --- Shell behaviour --------------------------------------------------------
# Mutate fields on the pre-populated default $env.config (never reassign the
# whole record — that would wipe Nushell's defaults).
$env.config.show_banner = false

# --- Windows Terminal shell integration --------------------------------------
# Nushell already emits the OSC 133 prompt marks WT renders on the scrollbar
# (shell_integration.osc133 defaults true) — zero config needed for marks. Two
# added halves: osc9_9 reports the cwd so duplicate-tab/split reopens the
# current directory (native Windows paths — no translation needed), and the
# hooks emit ConEmu OSC 9;4 taskbar progress (indeterminate while a curated
# long-runner executes; cleared at the next prompt — the same curated list as
# the zsh side: make/cza/czu/dnf/cargo/npm/uv + git push/pull/fetch/clone).
# Gated on WT_SESSION so nothing is emitted under any other host terminal.
# Escapes: nu has no \a — use \u{1b} (ESC) and \u{07} (BEL).
# PRE-1.0 CHURN: hooks + shell_integration are churn surfaces — re-check on
# every Nushell pin bump (see CLAUDE.md).
# PARITY NOTE: reedline/Nushell-specific — the PowerShell profile's parity
# obligation with this file covers the cz*/g* aliases only, not these hooks.
if "WT_SESSION" in $env {
    $env.config.shell_integration.osc9_9 = true

    $env.config.hooks.pre_execution = (
        $env.config.hooks.pre_execution? | default [] | append {||
            let cmd = (commandline | str trim)
            let simple = ($cmd | parse -r '^(?:make|cza|czu|dnf|cargo|npm|uv)(?:\s|$)' | is-not-empty)
            let git_net = ($cmd | parse -r '^git\s+(?:push|pull|fetch|clone)(?:\s|$)' | is-not-empty)
            if ($simple or $git_net) {
                print -n "\u{1b}]9;4;3;0\u{07}"
            }
        }
    )

    $env.config.hooks.pre_prompt = (
        $env.config.hooks.pre_prompt? | default [] | append {||
            print -n "\u{1b}]9;4;0;0\u{07}"
        }
    )
}
```

- [ ] **Step 2: Add the PowerShell profile parity note**

```
old:
# This file is rendered from chezmoi/Documents/PowerShell/<name>.tmpl on apply.
# For per-machine overrides that aren't tracked, drop the same logic into
# Microsoft.PowerShell_profile.local.ps1 next to this file (sourced last).
# =============================================================================
```

```
new:
# This file is rendered from chezmoi/Documents/PowerShell/<name>.tmpl on apply.
# For per-machine overrides that aren't tracked, drop the same logic into
# Microsoft.PowerShell_profile.local.ps1 next to this file (sourced last).
#
# PARITY NOTE (Windows Terminal shell integration): config.nu carries
# reedline-specific WT hooks (OSC 9;4 taskbar progress + osc9_9 cwd
# reporting). Those are Nushell-only by design — this profile's parity
# obligation with config.nu covers the cz*/g* aliases below, not the hooks.
# =============================================================================
```

- [ ] **Step 3: Verify**

```bash
bash scripts/check-templates.sh
```

Expected: PASS (nu-check soft-skips if `nu` is absent locally — the CI `templates` job enforces it; pwsh likewise).

- [ ] **Step 4: Commit**

```bash
git add chezmoi/AppData/Roaming/nushell/config.nu.tmpl chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl
git commit -m "feat(nushell): WT osc9_9 cwd + OSC 9;4 progress hooks (marks default-on); PS profile parity note"
```

---

### Task 5: Docs — README, file-care, verification, changelog

**Files:**
- Modify: `README.html` (§setup-windows-terminal: keybind table ~line 3373 + new paragraph after it)
- Modify: `docs/claude/file-care.md` (WT `settings.json` entry, the managed-keys sentence)
- Modify: `docs/claude/verification.md` (Windows Terminal recipe)
- Modify: `CLAUDE_CHANGELOG.md` (new first row)

**Interfaces:**
- Consumes: keybinds + snippet names from Task 1, shell-side behavior from Tasks 2–4.

- [ ] **Step 1: README keybind table — 3 rows** after the `CTRL+SHIFT+F` row (before the `CTRL+SHIFT+T` row):

```html
old:
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>F</kbd></td>
                                <td>Find in the scrollback (regex)</td>
                            </tr>
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>T</kbd> / <kbd>W</kbd></td>
```

```html
new:
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>F</kbd></td>
                                <td>Find in the scrollback (regex)</td>
                            </tr>
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>&uarr;</kbd> / <kbd>&darr;</kbd></td>
                                <td>Jump to the previous / next prompt mark in the scrollback (shell integration)</td>
                            </tr>
                            <tr>
                                <td><kbd>ALT</kbd>+<kbd>SHIFT</kbd>+<kbd>B</kbd></td>
                                <td>Broadcast input &mdash; type into every pane in the tab at once</td>
                            </tr>
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>SPACE</kbd></td>
                                <td>Suggestions palette &mdash; fuzzy-search the tracked snippets + recent commands</td>
                            </tr>
                            <tr>
                                <td><kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>T</kbd> / <kbd>W</kbd></td>
```

- [ ] **Step 2: README shell-integration paragraph** — insert directly after the keybind table's `</table>` (before the `<h3 id="prompt-keys">` heading):

```html
old:
                        </tbody>
                    </table>
                    <h3 id="prompt-keys">Shell prompt selection</h3>
```

```html
new:
                        </tbody>
                    </table>
                    <p>
                        Shell integration lights the rest up: local
                        <em>Nushell</em> and WSL <em>AlmaLinux-9</em> tabs emit
                        prompt marks (OSC 133), so the scrollbar shows one
                        exit-code-colored mark per command and
                        <kbd>CTRL</kbd>+<kbd>&uarr;</kbd>/<kbd>&darr;</kbd>
                        jump between them; duplicating a tab or pane reopens
                        the current directory (OSC 9;9); and long-running
                        commands (<code>make</code>, <code>cza</code>/<code>czu</code>,
                        <code>dnf</code>, <code>cargo</code>, <code>npm</code>,
                        <code>uv</code>, git network verbs) show indeterminate
                        progress on the taskbar icon (OSC 9;4) until the next
                        prompt. SSH tabs attach to Zellij, which composites its
                        own panes, so marks intentionally stop there. The
                        Suggestions palette
                        (<kbd>CTRL</kbd>+<kbd>SHIFT</kbd>+<kbd>SPACE</kbd>)
                        fuzzy-searches eight tracked snippets
                        (<code>cza</code>/<code>czu</code>/<code>czd</code>/<code>czs</code>,
                        full provision, lint, fleet update,
                        <code>zellij attach</code>) plus recent commands &mdash;
                        snippets insert editable text and never auto-execute.
                    </p>
                    <h3 id="prompt-keys">Shell prompt selection</h3>
```

- [ ] **Step 3: file-care.md** — extend the WT `settings.json` entry. Append this sentence to the end of the "Managed `profiles.defaults` / top-level keys" sentence (after "…groups the generated hosts under their own new-tab submenu)."):

```
Also managed (2026-07-31 workflow/polish PR): `profiles.defaults.autoMarkPrompts` + `showMarksOnScrollbar` (scrollbar prompt marks — the shell-side OSC 133 emitters live in `dot_zshrc.tmpl`/`dot_bashrc.tmpl`, WT_SESSION-gated and zellij-excluded; Nushell emits OSC 133 by default), `profiles.defaults.adjustIndistinguishableColors: "indexed"`, the theme's `tab.iconStyle: "monochrome"`, four action keybinds (`scrollToMark` prev/next on ctrl+up/down, `toggleBroadcastInput` on alt+shift+b, `showSuggestions` [tasks+recentCommands] on ctrl+shift+space), and eight named `sendInput` snippet actions (`User.snippet.*` — input text carries NO trailing `\r`: snippets insert, never execute).
```

- [ ] **Step 4: verification.md** — add to the Windows Terminal recipe, after the existing WSL-tab bullet (`- In a WSL tab: …one OSC 133 prompt-zone set.`):

```
- Marks: in a WSL zsh tab run `true` then `false` — two scrollbar marks (success/error colored);
  ctrl+up / ctrl+down jump between prompts; duplicate pane (alt+shift+d) reopens the same WSL dir.
- alt+shift+b: broadcast icon appears on every pane in the tab; typing reaches all panes.
- ctrl+shift+space: Suggestions palette lists the 8 "Snippet: …" entries; picking one inserts
  the text WITHOUT executing. (If stable WT lacks showSuggestions — MS docs banner still says
  Preview — drop the action + README row per the 2026-07-31 spec's documented fallback.)
- Taskbar: run `make -C ~/.local/share/chezmoi lint MODE=prod` in a WSL tab — indeterminate
  progress on the WT taskbar icon, cleared at the next prompt (needs Windows accessibility
  "Show animations" ON; same for a `cargo`/`npm`/`uv`/git-network command in a Nushell tab).
```

- [ ] **Step 5: CLAUDE_CHANGELOG.md** — insert as the FIRST data row (directly under the `|---|---|---|` separator):

```
| Windows Terminal workflow + polish upgrade (spec `docs/superpowers/specs/2026-07-31-windows-terminal-workflow-polish-design.md`). `settings.json`: `autoMarkPrompts` + `showMarksOnScrollbar` + `adjustIndistinguishableColors: indexed` in `profiles.defaults`, theme tab `iconStyle: monochrome`, new keybinds (ctrl+up/down `scrollToMark`, alt+shift+b `toggleBroadcastInput`, ctrl+shift+space `showSuggestions` over tasks+recentCommands), and 8 named `sendInput` fleet snippets (insert-only — no trailing `\r`). Shell side, all WT_SESSION-gated + zellij-excluded: zsh full block (OSC 133 A/C/D marks, OSC 9;9 cwd via `wslpath -w`, OSC 9;4 curated-command taskbar progress; `_wt_precmd` PREPENDED to precmd_functions and returns the real `$?` so starship still sees it), bash prompt-side only (PARITY NOTE: no preexec without bash-preexec; starship owns the DEBUG trap), Nushell `osc9_9` + pre_execution/pre_prompt progress hooks (OSC 133 marks are nu defaults; `\u{1b}`/`\u{07}` escapes — nu has no `\a`). Suggestions-UI risk documented: MS docs still banner it Preview; fallback = drop action + README row at live verification. | **Yes** | §setup-windows-terminal: three new keybind-table rows (ctrl+↑/↓ marks, alt+shift+b broadcast, ctrl+shift+space suggestions) + a shell-integration paragraph (marks/9;9/progress semantics, Zellij/SSH panes excluded by construction, snippets never auto-execute). file-care.md WT entry gains the new managed keys; verification.md WT recipe gains marks/broadcast/suggestions/taskbar checks. |
```

- [ ] **Step 6: Verify + commit**

```bash
python3 -c "import html.parser; p=html.parser.HTMLParser(); p.feed(open('README.html').read()); print('HTML-OK')"
git add README.html docs/claude/file-care.md docs/claude/verification.md CLAUDE_CHANGELOG.md
git commit -m "docs: WT workflow/polish — README keybinds + shell-integration paragraph, file-care managed keys, verification recipe, changelog row"
```

---

### Task 6: Full lint, push, PR

**Files:** none new.

- [ ] **Step 1: Full local gate**

```bash
make lint MODE=prod          # check-invariants: pins, LF/0755, BOMs, sentinels, parity, shellcheck, shfmt, gitleaks
bash scripts/check-templates.sh
```

Expected: all green (the settings.json `git diff --check` trailing-space warnings are NOT part of lint — no action).

- [ ] **Step 2: Push + PR**

```bash
git push -u origin wt-workflow-polish
gh pr create --title "feat(windows-terminal): shell-integration marks, fleet snippets, broadcast + taskbar progress" --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-07-31-windows-terminal-workflow-polish-design.md.

- settings.json: scrollbar prompt marks (autoMarkPrompts/showMarksOnScrollbar), adjustIndistinguishableColors=indexed, monochrome tab icons; ctrl+up/down scrollToMark, alt+shift+b broadcast, ctrl+shift+space Suggestions; 8 named sendInput fleet snippets (insert-only).
- zsh: full OSC 133/9;9/9;4 block (WT_SESSION-gated, zellij-excluded; precmd prepended + returns real $?).
- bash: prompt-side parity (PARITY NOTE: no preexec half — starship owns the DEBUG trap).
- Nushell: osc9_9 + curated OSC 9;4 progress hooks (marks are nu defaults); PS profile parity note.
- Docs: README §setup-windows-terminal (3 keybind rows + shell-integration paragraph), file-care managed keys, verification recipe, changelog row.

Known risk: MS docs still banner showSuggestions as Preview-only (likely stale). Fallback documented in verification.md: if stable WT ignores it, drop the action + README row at live verification.

Live rollout after merge: czu on the Windows host (settings.json hot-reloads; chezmoi re-add recaptures WT's re-serialization), czu on WSL, then the verification.md WT recipe.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01KNsoHtUoN3PHjh5PRLBt17
EOF
)"
```

- [ ] **Step 3: Watch CI** (`gh pr checks --watch`) — lint + templates jobs must pass (CI has `nu`/`pwsh` for the checks that soft-skip locally).
