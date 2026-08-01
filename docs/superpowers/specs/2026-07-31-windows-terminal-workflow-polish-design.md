# Windows Terminal workflow + polish upgrade — design

**Date:** 2026-07-31
**Status:** approved (brainstorm 2026-07-31)
**Scope decision trail:** user selected *workflow power features* + *visual polish* from the settings-side buckets, then *marks-in-WSL/zsh*, *taskbar build progress*, and *fleet snippets* from the repo-leveraged adds; *keybind gap-fill*, *quake mode*, and *prod-host danger cues* were explicitly declined; window material stays **fully opaque**. Implementation approach: **one PR, existing files only** (no new generators).

## Goal

Carry the last high-value WezTerm/Warp-era UX into the managed Windows Terminal, using the repo's unique position: it owns the terminal `settings.json`, the Linux shell rc templates, and the Windows Nushell config, so it can wire both halves of every shell-integration feature (terminal setting + shell escape sequence) in one commit.

## Non-goals

- No pane-resize/tab-rename/export keybinds (declined bucket).
- No quake-mode/global-summon window (declined).
- No prod-host tab/background danger cues (declined; fragment generator untouched).
- No acrylic/Mica/opacity (declined — stay opaque; this is the Intel-iGPU laptop).
- No paste-trim settings — `trimPaste` and `trimBlockSelection` are already WT defaults (`true`); nothing to add.
- No new invariants, generators, version pins, or `check-invariants.sh` changes.

## Section 1 — Terminal side: tracked `settings.json`

File: `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json` — hand-edit preserving WT's canonical serialization (trailing space after `"key": ` before object/array values, WT key ordering, possible missing final newline). Per `docs/claude/file-care.md`, WT re-serializes on first launch; drift is recaptured with `chezmoi re-add` (accepted model).

### 1a. `profiles.defaults` additions

| Key | Value | Why |
|---|---|---|
| `autoMarkPrompts` | `true` | Marks prompts (stable since WT 1.21; full fidelity once the shell emits OSC 133) |
| `showMarksOnScrollbar` | `true` | Renders the marks on the scrollbar, exit-code colored |
| `adjustIndistinguishableColors` | `"indexed"` | Fixes low-contrast indexed-palette collisions; leaves true-color output alone (safe with Mocha) |

### 1b. Theme tweak

In the `Catppuccin Mocha` theme object: `tab.iconStyle` `"default"` → `"monochrome"` (calmer tab row; window material otherwise untouched — opaque stays).

### 1c. New actions + keybindings (nothing existing is remapped)

| Keys | Action |
|---|---|
| `ctrl+up` / `ctrl+down` | `scrollToMark` `"previous"` / `"next"` — jump between prompts in scrollback |
| `alt+shift+b` | `toggleBroadcastInput` — type into all panes of the tab (SSH fleet use) |
| `ctrl+shift+space` | `showSuggestions` with `{"source": ["tasks", "recentCommands"], "useCommandline": true}` |

### 1d. Fleet snippets (`sendInput` actions with `name`, surfaced by the Suggestions UI)

Snippets insert **editable text without a trailing `\r`** — never auto-execute.

| Name | Input |
|---|---|
| Snippet: chezmoi apply | `cza` |
| Snippet: chezmoi update (pull+apply) | `czu` |
| Snippet: chezmoi diff | `czd` |
| Snippet: chezmoi status | `czs` |
| Snippet: full dev provision (WSL) | `make -C ~/.local/share/chezmoi dev` |
| Snippet: lint + invariants (WSL) | `make -C ~/.local/share/chezmoi lint MODE=prod` |
| Snippet: fleet update (WSL) | `bash ~/.local/share/chezmoi/scripts/update-hosts.sh` |
| Snippet: zellij attach main | `zellij attach --create main` |

The `cz*` rows are shell-agnostic (aliases exist in zsh, bash, Nushell, PowerShell); the `make`/`update-hosts` rows are WSL-tab text.

### Known risk (Suggestions UI)

Microsoft's docs still banner `showSuggestions` as "Preview only" — almost certainly stale (shipped to stable ≥1.19), but **verify on the live host** during rollout. If stable WT ignores the action: the keybind is inert; drop the action + its README row in the follow-up re-add commit. Marks, broadcast, snippets-as-actions are unaffected either way.

## Section 2 — Shell side (the half plain WT settings cannot reach)

### 2a. `chezmoi/dot_zshrc.tmpl` — WT shell-integration block

New block, gated `[[ -n $WT_SESSION && -z $ZELLIJ ]]`:

- `WT_SESSION` crosses WSL interop, so it is set in local WSL tabs and unset over SSH — exactly the sessions where the sequences render.
- `$ZELLIJ` excludes in-multiplexer shells (zellij composites panes; the sequences would be swallowed noise).

Hooks (registered via `add-zsh-hook`, coexisting with starship/mise):

- **precmd**: emit `OSC 133;D;$?` (colors the *previous* command's mark by exit code — capture `$?` first) → `OSC 9;9;$(wslpath -w "$PWD")` (ConEmu CWD; **must be a Windows path**, hence `wslpath -w`; enables duplicate-tab/split into the same WSL directory) → `OSC 133;A` (prompt-start mark) → `OSC 9;4;0;0` (clear taskbar progress).
- **preexec**: emit `OSC 133;C` (output start), and when the command matches the curated progress patterns — first word in `make|cza|czu|dnf|cargo|npm|uv`, or the two-word prefixes `git push|pull|fetch|clone` — emit `OSC 9;4;3;0` (indeterminate taskbar progress, cleared at the next prompt).

`wslpath` is a ~1–2 ms per-prompt call; acceptable. If it ever bothers, cache via a `chpwd` hook (noted, not implemented — YAGNI).

### 2b. `chezmoi/dot_bashrc.tmpl` — parity pair, same commit

Prompt-side only, via a function **prepended** to `PROMPT_COMMAND` (before starship's entry): `133;D;$?` + `9;9` + `133;A` + `9;4;0;0`. **PARITY NOTE** in-file: bash has no `preexec` without bash-preexec, and starship owns bash's DEBUG trap — so no `133;C` and no progress-start (marks appear uncolored-in-flight but exit-coloring still works). Same precedent as the atuin parity note.

### 2c. `chezmoi/AppData/Roaming/nushell/config.nu.tmpl` — Windows Nushell

- Nushell already emits OSC 133 by default (`shell_integration.osc133`) — local Nushell tabs get marks with **zero change**.
- Add `$env.config.shell_integration.osc9_9 = true` (native Windows paths; no wslpath needed) for duplicate-tab CWD.
- Add `hooks.pre_execution` (inspect `commandline`; curated-list match → `OSC 9;4;3;0`) and `hooks.pre_prompt` (`OSC 9;4;0;0`), gated on `WT_SESSION` in `$env`.
- Validate the rendered template with `nu-check` (CI's templates job already runs it).

### 2d. PowerShell profile — parity note only

`Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl` gets a comment noting the hooks are reedline/Nushell-specific; the config.nu↔PowerShell parity pair rule covers only the `cz*`/`g*` aliases, which are untouched.

## Section 3 — Docs, guardrails, rollout

### Docs (same commit — README decision test: yes, operating surface changes)

- **`README.html` §setup-windows-terminal**: three new keybind-table rows (`ctrl+up/down`, `alt+shift+b`, `ctrl+shift+space`); a short paragraph covering scrollbar marks, the snippets list, broadcast input, and taskbar progress; a note that shell integration lights up in local Nushell + WSL zsh tabs but **not inside Zellij/SSH panes** (zellij composites its own scrollback — by construction, not a bug).
- **`CLAUDE_CHANGELOG.md`**: new row (README = Yes).
- **`docs/claude/file-care.md`** WT entry: extend the managed-keys list with `autoMarkPrompts`, `showMarksOnScrollbar`, `adjustIndistinguishableColors`, `tab.iconStyle: monochrome`, the four new action keybinds, and the snippet block.
- **`docs/claude/verification.md`** WT recipe additions: marks visible on scrollbar in a WSL zsh tab; `ctrl+up` jumps to the previous prompt; `alt+shift+b` shows the broadcast icon on every pane; `ctrl+shift+space` opens the Suggestions palette listing the 8 snippets; taskbar icon shows indeterminate progress during `make` and clears at the prompt; duplicate-tab opens in the same WSL directory.

### Guardrails

- No `check-invariants.sh` change (no new mechanical shapes; no version pins).
- `scripts/check-templates.sh` + CI cover the three edited templates (zsh/bash syntax + `nu-check`).
- The `parity-reminder.sh` hook already nudges the zshrc↔bashrc pair.
- rc/`.tmpl` files keep their existing modes; no LF/BOM tripwire files are touched except the always-LF templates.

### Rollout

1. PR → CI (lint + templates) → merge.
2. Windows host: `czu` — `settings.json` hot-reloads (README troubleshooting already documents this); WT may re-serialize the new keys → recapture with `chezmoi re-add` (accepted sync-from-host model).
3. WSL host: `czu` picks up the rc changes; new shell → verify per the verification.md additions.
4. If `showSuggestions` proves preview-only on stable: drop the action + README row in the re-add commit (see Section 1 risk).

## Error handling

- All emitted sequences are plain `printf`s guarded by the `WT_SESSION`/`ZELLIJ` gate — on any other terminal they are never emitted; if `wslpath` is absent (non-WSL Linux) the `9;9` emission is skipped via `command -v wslpath` guard.
- A failed/undefined WT action name would surface as a settings-UI warning, not a crash; the sync-from-host model means the live host is the final arbiter and `chezmoi re-add` reconciles.

## Testing

- Local: `make lint MODE=prod` (invariants + shellcheck + shfmt + gitleaks) and `scripts/check-templates.sh` (renders both host groups; zsh/bash/nu syntax checks).
- Live host: the verification.md recipe additions above.

## Amendment (2026-08-01, final whole-branch review)

`showSuggestions` rebound `ctrl+shift+space` → `alt+shift+s` (user decision): the original chord shadows Windows Terminal's default `openNewTabDropdown` binding — the keyboard route to the SSH-hosts dropdown. alt+shift+s joins the existing alt+shift mnemonic family with no WT-default collision.
