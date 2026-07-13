# Script Flag Completions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tab completion for the five flag-bearing repo scripts — `bootstrap.sh`/`manage-hosts.sh`/`update-hosts.sh` in zsh+bash (Linux), `bootstrap.ps1`/`manage-hosts.ps1` in Nushell (Windows) — kept in lockstep with the scripts by a new `check-invariants.sh` flag-parity check.

**Architecture:** Static hand-written completions in the repo's existing homes (zsh completions dir on `fpath`; a new sourced bash file; an external-completer block in `config.nu.tmpl`), plus mechanical drift enforcement. No new dependencies, no generators.

**Tech Stack:** zsh compsys (`_arguments`), bash programmable completion (`complete -F`/`compgen`), Nushell 0.113.1 external completer, bash for the invariant check.

**Spec:** `docs/superpowers/specs/2026-07-13-script-flag-completions-design.md` (approved 2026-07-13).

## Global Constraints

- Work on the existing `feat/script-completions` branch (spec committed as `64d5520`).
- **Flag sets are LOCKED to these exact values** (verified from the scripts 2026-07-13). Long-form only; sorted:
  - `bootstrap.sh` (7): `--check-for-updates --dev --doctor --help --prod --reinstall --yes` — deliberately EXCLUDED from completion: `--full` (removed-flag fail arm), `--checkforupdates` (compat alias).
  - `manage-hosts.sh` (12): `--add --all --copy-id --format --group --ip --list --name --remove --skip-confirm --sync --user` — NOTE: no `--help` arm exists; do not complete it.
  - `update-hosts.sh` (5): `--check --group --help --name --parallel`
  - `bootstrap.ps1` (12): `-CheckForUpdates -Doctor -ForceInstaller -Reinstall -RepoPath -SkipBurntToast -SkipChezmoi -SkipElevated -SkipKeyGen -SkipNerdFonts -SkipToolInstall -Yes`
  - `manage-hosts.ps1` (12): `-Add -All -CopyId -Format -Group -Ip -List -Name -Remove -SkipConfirm -Sync -User`
- `--group` completes the only two valid host groups: `dev_machine prod_machine`.
- New shell files: LF-only. `completions.bash` is sourced-not-executed → **mode 0644** (do NOT `chmod +x`, do NOT add to the LF+0755 invariant list); it must be `shfmt -i 2`-clean and shellcheck-warning-clean (it joins those target arrays). The three zsh `_*` files are zsh syntax — they must NOT join the shellcheck/shfmt bash arrays.
- `config.nu.tmpl` house rule: mutate fields on the default `$env.config`, never reassign the whole record; assigning the `$env.config.completions.external` subrecord is fine (matches the `show_banner` precedent).
- `check-invariants.sh` is deliberately NOT `set -e` (it is `set -uo pipefail` and tallies `fails`); new code must follow that pattern — explicit conditionals, no abort-on-first-failure.
- `.chezmoiignore.tmpl` patterns are TARGET paths — the new `.config/bash` Windows-ignore entry must be the target path, not a `dot_*` source name.
- Every commit message ends with the two trailers:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a
  ```
- The pre-commit hook runs the invariant check on every commit; it must pass.
- Editing only ONE side of the zshrc↔bashrc parity pair fires the `parity-reminder` hook nudge — expected here (Task 1 touches zshrc, Task 2 bashrc); do not "fix" by editing the sibling outside your task.

---

### Task 1: zsh completion files (Linux)

**Files:**
- Create: `chezmoi/dot_config/zsh/completions/_bootstrap.sh`
- Create: `chezmoi/dot_config/zsh/completions/_manage-hosts.sh`
- Create: `chezmoi/dot_config/zsh/completions/_update-hosts.sh`
- Modify: `chezmoi/dot_zshrc.tmpl` (the completions comment, ~line 112)

**Interfaces:**
- Consumes: the completions dir is already on `fpath` before `compinit` (`dot_zshrc.tmpl:115`) — no wiring needed. zsh completion dispatch strips directory prefixes, so `#compdef bootstrap.sh` matches `./bootstrap.sh`.
- Produces: files whose **non-comment lines'** `--flag` tokens are extracted by Task 4's `_zsh_completion_flags` helper (`grep -v '^#' | grep -oE -- '--[a-z-]+' | sort -u`) and must equal the locked sets above. Comments MAY name excluded flags; descriptions must not name any flag outside the script's locked set.

- [ ] **Step 1: Create `chezmoi/dot_config/zsh/completions/_bootstrap.sh`** (exactly this content):

```zsh
#compdef bootstrap.sh
# First-party zsh completion for the repo's Linux seed script (./bootstrap.sh).
# NOT vendored — unlike the neighboring _cht.sh. The flag set mirrors
# bootstrap.sh's argument parser and is kept in lockstep by
# scripts/check-invariants.sh (flag-parity check). Deliberately NOT completed:
# "--full" (removed-flag fail arm) and "--checkforupdates" (compat alias).
_arguments \
  '(--prod)--dev[host you own: sudo, /usr/local/bin + system packages (dev_machine)]' \
  '(--dev)--prod[host you do not own: no sudo, ~/.local/bin (prod_machine)]' \
  '--reinstall[wipe the cloned repo + chezmoi config, then bootstrap fresh]' \
  '(-y --yes)'{-y,--yes}'[skip the confirmation prompt when reinstalling]' \
  '(--check-for-updates)--doctor[read-only health report, then exit]' \
  '(--doctor)--check-for-updates[read-only update scan, then exit]' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
```

(Description for `--yes` deliberately avoids the token `--reinstall` — descriptions must not add flag tokens beyond the completed set, to keep Task 4's text extraction exact. `--reinstall` IS separately completed, so either way the set is identical; the rule keeps the extraction honest.)

- [ ] **Step 2: Create `chezmoi/dot_config/zsh/completions/_manage-hosts.sh`**:

```zsh
#compdef manage-hosts.sh
# First-party zsh completion for ./scripts/manage-hosts.sh (NOT vendored).
# Flat union of action flags + option flags (context-aware per-action
# completion is deliberately not attempted). Kept in lockstep with the script
# by scripts/check-invariants.sh. Windows parity: manage-hosts.ps1 completes
# via the Nushell external completer in config.nu. NOTE: the script has no
# help flag — none is completed.
_arguments \
  '--sync[regenerate the wezterm.lua SSH domains block from hosts.conf]' \
  '--list[list hosts from hosts.conf]' \
  '--format[re-pad hosts.conf columns]' \
  '--add[add a host to hosts.conf (interactive when no option flags given)]' \
  '--remove[remove a host from hosts.conf]' \
  '--copy-id[push your SSH public key to a host]' \
  '--name[host name]:host name:' \
  '--ip[host IP address]:ip:' \
  '--user[SSH user]:user:' \
  '--group[host group]:group:(dev_machine prod_machine)' \
  '--skip-confirm[skip confirmation prompts]' \
  '--all[apply the key-copy to every host in hosts.conf]'
```

- [ ] **Step 3: Create `chezmoi/dot_config/zsh/completions/_update-hosts.sh`**:

```zsh
#compdef update-hosts.sh
# First-party zsh completion for ./scripts/update-hosts.sh (NOT vendored).
# Kept in lockstep with the script by scripts/check-invariants.sh.
_arguments \
  '--group[only hosts in this group]:group:(dev_machine prod_machine)' \
  '--name[only this host]:host name:' \
  '--check[print planned actions, do not ssh]' \
  '--parallel[max concurrent hosts (default 4)]:count:' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
```

- [ ] **Step 4: Extend the zshrc completions comment.** In `chezmoi/dot_zshrc.tmpl`, replace:

```
# cht.sh ships a zsh completion (#compdef cht.sh) installed to
# ~/.config/zsh/completions/_cht.sh; add that dir to fpath so compinit
# autoloads it. MUST precede the compinit call below.
```

with:

```
# cht.sh ships a zsh completion (#compdef cht.sh) installed to
# ~/.config/zsh/completions/_cht.sh (vendored), and the repo's own
# first-party completions live next to it: _bootstrap.sh, _manage-hosts.sh,
# _update-hosts.sh (flag completion for the repo scripts; kept in lockstep
# with the scripts by check-invariants.sh, bash parity via
# ~/.config/bash/completions.bash). Add that dir to fpath so compinit
# autoloads them. MUST precede the compinit call below.
```

- [ ] **Step 5: Verify syntax + autoloadability + encoding**

Run:

```bash
for f in chezmoi/dot_config/zsh/completions/_{bootstrap.sh,manage-hosts.sh,update-hosts.sh}; do
  zsh -n "$f" && echo "PARSE OK: $f"
  head -c 200 "$f" | head -1
  file "$f"
done
zsh -f -c '
  fpath=(chezmoi/dot_config/zsh/completions $fpath)
  for fn in _bootstrap.sh _manage-hosts.sh _update-hosts.sh; do
    autoload -Uz "$fn" && autoload +X "$fn" && echo "AUTOLOAD OK: $fn"
  done'
```

Expected: three `PARSE OK` lines; each file's line 1 is its `#compdef` line; `file` reports plain text (no CRLF); three `AUTOLOAD OK` lines.

- [ ] **Step 6: Lint and commit**

```bash
make -C makefile lint MODE=prod    # must stay green (zsh files are NOT in the bash lint sets)
git add chezmoi/dot_config/zsh/completions/_bootstrap.sh \
        chezmoi/dot_config/zsh/completions/_manage-hosts.sh \
        chezmoi/dot_config/zsh/completions/_update-hosts.sh \
        chezmoi/dot_zshrc.tmpl
git commit -m "feat(completions): zsh flag completion for bootstrap.sh, manage-hosts.sh, update-hosts.sh"
```

---

### Task 2: bash completions file + bashrc wiring + Windows ignore (Linux)

**Files:**
- Create: `chezmoi/dot_config/bash/completions.bash`
- Modify: `chezmoi/dot_bashrc.tmpl` (insert after the `/etc/bash_completion` source line, ~line 110)
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows block gains `.config/bash`)
- Modify: `scripts/check-invariants.sh` (the file joins BOTH first-party lint target arrays)

**Interfaces:**
- Consumes: locked flag sets from Global Constraints.
- Produces: functions `_workstation_complete_bootstrap`, `_workstation_complete_manage_hosts`, `_workstation_complete_update_hosts` — Task 4's `_bash_completion_flags` helper extracts each function body's `--flag` tokens by awk-ranging from `^<fn>()` to `^}` in this file; each body's token set must equal the locked set.

- [ ] **Step 1: Write the failing behavior test** (TDD — run before the file exists):

```bash
bash --noprofile --norc <<'EOF'
set -u
source chezmoi/dot_config/bash/completions.bash || { echo "RED: file missing"; exit 1; }
EOF
```

Expected: `RED: file missing`, exit 1.

- [ ] **Step 2: Create `chezmoi/dot_config/bash/completions.bash`** (exactly this content):

```bash
# shellcheck shell=bash
# ~/.config/bash/completions.bash — first-party tab completion for the repo's
# flag-bearing scripts (bootstrap.sh, manage-hosts.sh, update-hosts.sh).
# Sourced from ~/.bashrc; mode 0644, no shebang — never executed.
# PARITY NOTE: zsh gets richer versions (descriptions + mutual exclusions) via
# ~/.config/zsh/completions/_{bootstrap.sh,manage-hosts.sh,update-hosts.sh};
# Nushell completes the Windows .ps1 counterparts via the external completer
# in config.nu. Every surface is kept in lockstep with its script by
# scripts/check-invariants.sh (flag-parity check).
# bash keys completion on the EXACT command word (no basename fallback like
# zsh), so each script registers its common invocation spellings.

_workstation_complete_bootstrap() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  mapfile -t COMPREPLY < <(compgen -W '--dev --prod --reinstall --yes --doctor --check-for-updates --help' -- "$cur")
}

_workstation_complete_manage_hosts() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]}
  if [[ $prev == --group ]]; then
    mapfile -t COMPREPLY < <(compgen -W 'dev_machine prod_machine' -- "$cur")
    return
  fi
  mapfile -t COMPREPLY < <(compgen -W '--sync --list --format --add --remove --copy-id --name --ip --user --group --skip-confirm --all' -- "$cur")
}

_workstation_complete_update_hosts() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]}
  if [[ $prev == --group ]]; then
    mapfile -t COMPREPLY < <(compgen -W 'dev_machine prod_machine' -- "$cur")
    return
  fi
  mapfile -t COMPREPLY < <(compgen -W '--group --name --check --parallel --help' -- "$cur")
}

complete -F _workstation_complete_bootstrap bootstrap.sh ./bootstrap.sh
complete -F _workstation_complete_manage_hosts manage-hosts.sh ./manage-hosts.sh scripts/manage-hosts.sh ./scripts/manage-hosts.sh
complete -F _workstation_complete_update_hosts update-hosts.sh ./update-hosts.sh scripts/update-hosts.sh ./scripts/update-hosts.sh
```

- [ ] **Step 3: Run the behavior tests** (must all pass now):

```bash
bash --noprofile --norc <<'EOF'
set -u
source chezmoi/dot_config/bash/completions.bash
fail=0
COMP_WORDS=(./bootstrap.sh --d); COMP_CWORD=1; COMPREPLY=()
_workstation_complete_bootstrap
[[ "${COMPREPLY[*]}" == "--dev --doctor" ]] || { echo "FAIL bootstrap --d -> '${COMPREPLY[*]}'"; fail=1; }
COMP_WORDS=(./bootstrap.sh ""); COMP_CWORD=1; COMPREPLY=()
_workstation_complete_bootstrap
[[ ${#COMPREPLY[@]} -eq 7 ]] || { echo "FAIL bootstrap all -> ${#COMPREPLY[@]} words"; fail=1; }
COMP_WORDS=(./scripts/manage-hosts.sh --add --group d); COMP_CWORD=3; COMPREPLY=()
_workstation_complete_manage_hosts
[[ "${COMPREPLY[*]}" == "dev_machine" ]] || { echo "FAIL manage-hosts group -> '${COMPREPLY[*]}'"; fail=1; }
COMP_WORDS=(./scripts/manage-hosts.sh --s); COMP_CWORD=1; COMPREPLY=()
_workstation_complete_manage_hosts
[[ "${COMPREPLY[*]}" == "--sync --skip-confirm" ]] || { echo "FAIL manage-hosts --s -> '${COMPREPLY[*]}'"; fail=1; }
COMP_WORDS=(./scripts/update-hosts.sh --p); COMP_CWORD=1; COMPREPLY=()
_workstation_complete_update_hosts
[[ "${COMPREPLY[*]}" == "--parallel" ]] || { echo "FAIL update-hosts --p -> '${COMPREPLY[*]}'"; fail=1; }
complete -p ./bootstrap.sh >/dev/null 2>&1 || { echo "FAIL: ./bootstrap.sh not registered"; fail=1; }
complete -p scripts/update-hosts.sh >/dev/null 2>&1 || { echo "FAIL: scripts/update-hosts.sh not registered"; fail=1; }
[[ $fail -eq 0 ]] && echo "ALL PASS"
exit $fail
EOF
```

Expected: `ALL PASS`, exit 0.

- [ ] **Step 4: Source it from bashrc.** In `chezmoi/dot_bashrc.tmpl`, replace:

```
[[ -f /etc/bash_completion ]] && source /etc/bash_completion
```

with:

```
[[ -f /etc/bash_completion ]] && source /etc/bash_completion

# First-party completions for the repo's own scripts (bootstrap.sh,
# manage-hosts.sh, update-hosts.sh — flag words + --group values), deployed
# by chezmoi to ~/.config/bash/completions.bash. PARITY NOTE: zsh gets
# richer versions (descriptions + exclusions) via
# ~/.config/zsh/completions/_* (see dot_zshrc.tmpl); all surfaces are kept
# in lockstep with the scripts by check-invariants.sh's flag-parity check.
[[ -f "$HOME/.config/bash/completions.bash" ]] && source "$HOME/.config/bash/completions.bash"
```

- [ ] **Step 5: Windows must not receive `.config/bash`.** In `chezmoi/.chezmoiignore.tmpl`'s Windows block, replace:

```
.config/cheat
```

with:

```
.config/bash
.config/cheat
```

(TARGET path, alphabetical slot before `.config/cheat` — the tripwire: a `dot_config/bash` source-state pattern would be a silent no-op.)

- [ ] **Step 6: The new bash file joins the first-party lint sets.** In `scripts/check-invariants.sh`, BOTH `check_shellcheck` and `check_shfmt` contain this identical array; in each, replace:

```
  local -a targets=(bootstrap.sh makefile/lib/*.sh scripts/*.sh
    .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh
    chezmoi/private_dot_claude/executable_notify.sh
    chezmoi/dot_local/bin/executable_winterop)
```

with:

```
  local -a targets=(bootstrap.sh makefile/lib/*.sh scripts/*.sh
    .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh
    chezmoi/private_dot_claude/executable_notify.sh
    chezmoi/dot_local/bin/executable_winterop
    chezmoi/dot_config/bash/completions.bash)
```

(Use `replace_all` or two targeted edits — the array text appears exactly twice. The zsh `_*` files must NOT be added — they are zsh syntax, excluded like the zsh plugin files.)

- [ ] **Step 7: Verify + lint**

```bash
file chezmoi/dot_config/bash/completions.bash           # no CRLF
git ls-files --stage chezmoi/dot_config/bash/completions.bash || true  # after add: expect 100644
shellcheck -x -S warning chezmoi/dot_config/bash/completions.bash && echo SHELLCHECK-OK
shfmt -d -i 2 chezmoi/dot_config/bash/completions.bash && echo SHFMT-OK
make -C makefile lint MODE=prod
```

Expected: no CRLF; SHELLCHECK-OK; SHFMT-OK; lint all-green with the shell-file count up by 1 (36 → 37).

- [ ] **Step 8: Commit**

```bash
git add chezmoi/dot_config/bash/completions.bash chezmoi/dot_bashrc.tmpl \
        chezmoi/.chezmoiignore.tmpl scripts/check-invariants.sh
git commit -m "feat(completions): bash flag completion, sourced from bashrc; ignore .config/bash on Windows"
```

---

### Task 3: Nushell external completer (Windows)

**Files:**
- Modify: `chezmoi/AppData/Roaming/nushell/config.nu.tmpl` (append a new section at end of file, after the `adminpw` def)

**Interfaces:**
- Consumes: locked `-Flag` sets from Global Constraints; nu 0.113.1 external-completer API (`$env.config.completions.external = {enable, max_results, completer}`; closure receives `$spans` list-of-strings; returns list of `{value, description}` records; `null` → default file completion).
- Produces: two top-level `let` lists named `workstation_bootstrap_flags` and `workstation_manage_hosts_flags` — Task 4's `_nu_completion_flags` helper awk-ranges from `^let <name>` to the first `^]` and extracts standalone `"-Flag"` quoted tokens; each list's set must equal the locked set. Keep the list opener `let <name> = [` and closer `]` at column 0.

- [ ] **Step 1: Append to `chezmoi/AppData/Roaming/nushell/config.nu.tmpl`** (after the final `adminpw` def, exactly this content):

```nu

# --- Repo-script flag completion (external completer) ------------------------
# Nushell only completes flags for commands with declared signatures; external
# commands (the repo's .ps1 scripts) otherwise fall back to file completion —
# the "NO RECORDS FOUND" menu. This external completer recognises the two
# flag-bearing repo scripts BY BASENAME — `.\bootstrap.ps1`, a full path, and
# `scripts\manage-hosts.ps1` all match — and returns their flags with
# descriptions; anything else returns null -> Nushell's default file
# completion (behavior everywhere else is unchanged). Flag lists mirror each
# script's param() block and are kept in lockstep by check-invariants.sh's
# flag-parity check (which parses the two `let workstation_*_flags` lists —
# keep their `let`/closing-bracket lines at column 0). Classic PowerShell
# needs none of this: it tab-completes param() flags natively.
# PRE-1.0 CHURN: the external-completer API is a known churn surface —
# re-check this block on every Nushell pin bump (see CLAUDE.md).

let workstation_bootstrap_flags = [
    { value: "-RepoPath", description: "alternate clone path (default %USERPROFILE%\\.local\\share\\chezmoi)" }
    { value: "-SkipKeyGen", description: "skip the SSH-key prompt" }
    { value: "-SkipToolInstall", description: "skip portable tools, installer apps and Claude Code" }
    { value: "-SkipChezmoi", description: "clone + install but don't deploy dotfiles" }
    { value: "-SkipBurntToast", description: "skip the BurntToast notification module" }
    { value: "-SkipNerdFonts", description: "skip the JetBrainsMono Nerd Font install" }
    { value: "-ForceInstaller", description: "re-install installer apps even if present" }
    { value: "-SkipElevated", description: "skip the UAC-prompting SSHFS-Win/WinFsp install" }
    { value: "-Reinstall", description: "wipe the cloned repo + chezmoi config, bootstrap fresh" }
    { value: "-Yes", description: "skip the reinstall confirmation prompt" }
    { value: "-Doctor", description: "read-only health report, then exit" }
    { value: "-CheckForUpdates", description: "read-only update scan, then exit" }
]

let workstation_manage_hosts_flags = [
    { value: "-Sync", description: "regenerate the wezterm.lua SSH domains block from hosts.conf" }
    { value: "-List", description: "list hosts from hosts.conf" }
    { value: "-Format", description: "re-pad hosts.conf columns" }
    { value: "-Add", description: "add a host to hosts.conf" }
    { value: "-Remove", description: "remove a host from hosts.conf" }
    { value: "-CopyId", description: "push your SSH public key to a host" }
    { value: "-All", description: "apply the key-copy to every host" }
    { value: "-Name", description: "host name" }
    { value: "-Ip", description: "host IP address" }
    { value: "-User", description: "SSH user" }
    { value: "-Group", description: "host group (dev_machine | prod_machine)" }
    { value: "-SkipConfirm", description: "skip confirmation prompts" }
]

$env.config.completions.external = {
    enable: true
    max_results: 100
    completer: {|spans|
        let cmd = ($spans | first | path basename | str downcase)
        let flags = if $cmd == "bootstrap.ps1" {
            $workstation_bootstrap_flags
        } else if $cmd == "manage-hosts.ps1" {
            $workstation_manage_hosts_flags
        } else {
            null
        }
        if $flags == null {
            null
        } else {
            let word = ($spans | last | str downcase)
            let matches = ($flags | where {|f| $f.value | str downcase | str starts-with $word })
            if ($matches | is-empty) { null } else { $matches }
        }
    }
}
```

Notes baked into the code: `spans | last` is the command itself when no argument has been typed yet (no flag starts with it → `null` → file completion, correct); a non-matching word (e.g. a path value after `-RepoPath`) also falls back to file completion via the `is-empty` guard.

- [ ] **Step 2: Verify the template renders and the lists parse**

```bash
make -C makefile lint MODE=prod
```

Expected: all-green. `check-templates.sh` (inside lint) renders `config.nu.tmpl` for the dev group; with `nu` absent on this host it notes "config.nu: nu not installed — render-only (CI enforces)" — that soft-skip is expected; CI's templates job runs the real `nu-check`.

```bash
awk '/^let workstation_bootstrap_flags/{f=1} f{print} f&&/^\]/{exit}' chezmoi/AppData/Roaming/nushell/config.nu.tmpl | grep -cE '^\s*\{ value: "-'
awk '/^let workstation_manage_hosts_flags/{f=1} f{print} f&&/^\]/{exit}' chezmoi/AppData/Roaming/nushell/config.nu.tmpl | grep -cE '^\s*\{ value: "-'
```

Expected: `12` and `12`.

- [ ] **Step 3: Commit**

```bash
git add chezmoi/AppData/Roaming/nushell/config.nu.tmpl
git commit -m "feat(completions): nushell external completer for bootstrap.ps1 + manage-hosts.ps1 flags"
```

---

### Task 4: `check-invariants.sh` flag-parity check

**Files:**
- Modify: `scripts/check-invariants.sh` (new helpers + `check_completion_parity()` + registration in the call list at the bottom, after `check_chezmoiignore_targets`)

**Interfaces:**
- Consumes: Task 1's zsh files (comment-stripped `--flag` tokens), Task 2's bash functions (awk range `^<fn>()`…`^}`), Task 3's nu `let` lists (awk range `^let <name>`…`^]`, quoted `"-Flag"` tokens), and the five scripts themselves.
- Produces: a `check_completion_parity` section in the invariant output; the pre-commit hook and CI now fail on any script↔completion flag drift.

- [ ] **Step 1: Add the helpers + check.** Insert after the `check_chezmoiignore_targets()` function (before `check_shellcheck()`):

```bash
# --- flag-parity: repo-script flags == completion-surface flags --------------
# Spec: docs/superpowers/specs/2026-07-13-script-flag-completions-design.md.
# Five pairs: the three .sh scripts -> zsh _<name> files + completions.bash;
# the two .ps1 scripts -> the workstation_*_flags records in config.nu.tmpl.
# Long-form flags only. Trailing args to _sh_script_flags are EXCLUSIONS —
# flags the script accepts but completions deliberately omit
# (bootstrap.sh: the removed-flag --full fail arm, the --checkforupdates
# compat alias).

# Long flags a bash script accepts: its case arms (any nesting depth),
# alternatives split, short forms dropped. $2+ = exclusions.
_sh_script_flags() {
  local script=$1 out f
  shift
  out=$(grep -E '^[[:space:]]*-{1,2}[A-Za-z-]+([[:space:]]*\|[[:space:]]*-{1,2}[A-Za-z-]+)*\)' "$script" |
    grep -oE -- '--[a-z-]+' | sort -u)
  for f in "$@"; do
    out=$(printf '%s\n' "$out" | grep -vx -- "$f")
  done
  printf '%s\n' "$out"
}

# -Flag names from a PowerShell script's param() block.
_ps_script_flags() {
  awk '/^param\(/{f=1} f{print} f&&/^\)/{exit}' "$1" |
    grep -oE '\[(switch|string)\]\$[A-Za-z]+' | sed 's/.*\$/-/' | sort -u
}

# --flag tokens from a zsh completion file (full-line comments stripped —
# comments may legitimately name excluded flags).
_zsh_completion_flags() {
  grep -v '^#' "$1" | grep -oE -- '--[a-z-]+' | sort -u
}

# --flag tokens from one function body in completions.bash.
_bash_completion_flags() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" {f=1} f{print} f&&/^}/{exit}' \
    chezmoi/dot_config/bash/completions.bash |
    grep -oE -- '--[a-z-]+' | sort -u
}

# Quoted "-Flag" values from one `let workstation_*_flags` list in config.nu.tmpl.
_nu_completion_flags() {
  awk -v v="$1" '$0 ~ "^let "v {f=1} f{print} f&&/^\]/{exit}' \
    chezmoi/AppData/Roaming/nushell/config.nu.tmpl |
    grep -oE '"-[A-Za-z]+"' | tr -d '"' | sort -u
}

_flags_eq() { # $1=label  $2=script-side set  $3=completion-side set
  if [ -n "$2" ] && [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 drift (<:script-only  >:completion-only):"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/       /' | head -20
  fi
}

check_completion_parity() {
  hdr "script-flag <-> completion parity"
  local want

  want=$(_sh_script_flags bootstrap.sh --full --checkforupdates)
  _flags_eq "bootstrap.sh == _bootstrap.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_bootstrap.sh)"
  _flags_eq "bootstrap.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_bootstrap)"

  want=$(_sh_script_flags scripts/manage-hosts.sh)
  _flags_eq "manage-hosts.sh == _manage-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_manage-hosts.sh)"
  _flags_eq "manage-hosts.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_manage_hosts)"

  want=$(_sh_script_flags scripts/update-hosts.sh)
  _flags_eq "update-hosts.sh == _update-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_update-hosts.sh)"
  _flags_eq "update-hosts.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_update_hosts)"

  want=$(_ps_script_flags bootstrap.ps1)
  _flags_eq "bootstrap.ps1 == config.nu (nushell)" "$want" \
    "$(_nu_completion_flags workstation_bootstrap_flags)"

  want=$(_ps_script_flags scripts/manage-hosts.ps1)
  _flags_eq "manage-hosts.ps1 == config.nu (nushell)" "$want" \
    "$(_nu_completion_flags workstation_manage_hosts_flags)"
}
```

- [ ] **Step 2: Register the check.** In the call list at the bottom of `scripts/check-invariants.sh`, replace:

```
check_chezmoiignore_targets
check_shellcheck
```

with:

```
check_chezmoiignore_targets
check_completion_parity
check_shellcheck
```

- [ ] **Step 3: Sanity-check the extraction helpers directly** (expected outputs are the locked sets):

```bash
bash -c 'source /dev/stdin <<<"$(sed -n "/^_sh_script_flags()/,/^}/p;/^_ps_script_flags()/,/^}/p" scripts/check-invariants.sh)"
_sh_script_flags bootstrap.sh --full --checkforupdates
echo ---
_ps_script_flags bootstrap.ps1'
```

Expected output (exactly):

```
--check-for-updates
--dev
--doctor
--help
--prod
--reinstall
--yes
---
-CheckForUpdates
-Doctor
-ForceInstaller
-Reinstall
-RepoPath
-SkipBurntToast
-SkipChezmoi
-SkipElevated
-SkipKeyGen
-SkipNerdFonts
-SkipToolInstall
-Yes
```

If the `.sh` side shows an unexpected flag (e.g. an undocumented case arm), STOP and report DONE_WITH_CONCERNS — do not silently widen a completion list or an exclusion.

- [ ] **Step 4: Prove RED.** Temporarily break one pair and confirm the check catches it:

```bash
sed -i "s/'--sync\[regenerate/'--sink[regenerate/" chezmoi/dot_config/zsh/completions/_manage-hosts.sh
bash scripts/check-invariants.sh; echo "exit=$?"
git checkout -- chezmoi/dot_config/zsh/completions/_manage-hosts.sh
```

Expected: the parity section shows `✗ manage-hosts.sh == _manage-hosts.sh (zsh) drift` with `< --sync` / `> --sink` in the diff, overall `exit=1`. After the `git checkout`, re-run `bash scripts/check-invariants.sh` → all green, `exit=0` (GREEN).

- [ ] **Step 5: Full lint + commit**

```bash
make -C makefile lint MODE=prod     # parity section green, shellcheck/shfmt still clean (the new helpers are part of the linted file)
git add scripts/check-invariants.sh
git commit -m "feat(invariants): flag-parity check — script flags == completion surfaces (5 pairs)"
```

---

### Task 5: Docs sweep (README, CLAUDE.md, file-care, changelog)

**Files:**
- Modify: `README.html` (§daily note-row; §setup-windows Nushell paragraph)
- Modify: `CLAUDE.md` (mechanical-enforcement enumeration; version-pin/parity bullet list; nushell bullet)
- Modify: `docs/claude/file-care.md` (new entry after the `_cht.sh` bullet)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: everything Tasks 1–4 landed (file paths, function/list names, check name) — the doc text below already matches them verbatim.
- Produces: nothing downstream (terminal task).

- [ ] **Step 1: README §daily note.** Replace:

```html
                    <h3>chezmoi (Linux or Windows)</h3>
```

with:

```html
                    <p class="note-row">
                        <strong>Tab completion:</strong> the repo&rsquo;s own
                        scripts complete their flags &mdash;
                        <code>bootstrap.sh</code>,
                        <code>manage-hosts.sh</code> and
                        <code>update-hosts.sh</code> in zsh and bash on Linux
                        (plus <code>--group</code> values); on Windows,
                        Nushell completes <code>bootstrap.ps1</code> and
                        <code>manage-hosts.ps1</code> flags (PowerShell does
                        this natively). Kept in lockstep with the scripts by
                        the repo&rsquo;s invariant check.
                    </p>
                    <h3>chezmoi (Linux or Windows)</h3>
```

(That `<h3>` line appears once in `README.html` — verified 2026-07-13; the Edit fails loudly if that changes.)

- [ ] **Step 2: README §setup-windows Nushell paragraph.** Replace:

```html
                        <code>config.nu</code>) intentionally, upgrading
                        <em>incrementally</em> rather than skipping releases.
                    </p>
```

with:

```html
                        <code>config.nu</code>) intentionally, upgrading
                        <em>incrementally</em> rather than skipping releases.
                        Nushell also tab-completes the repo&rsquo;s own
                        scripts: <code>.\bootstrap.ps1 -</code> + Tab and
                        <code>manage-hosts.ps1 -</code> + Tab list their flags
                        with descriptions (an external completer in
                        <code>config.nu</code>; classic PowerShell completes
                        <code>param()</code> flags natively, no setup).
                    </p>
```

- [ ] **Step 3: CLAUDE.md mechanical-enforcement enumeration.** Replace:

```
sentinel-block matching, chezmoiignore target-paths)
```

with:

```
sentinel-block matching, chezmoiignore target-paths, script-flag↔completion parity)
```

- [ ] **Step 4: CLAUDE.md parity list.** In the "Files Claude should be careful with" section, the **Version-pin dual/triple-edits** bullet ends with:

```
`DEVTOYS_CLI_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PortableTools`, `Layout = "tree"` — verified by `check-invariants.sh`).
```

Replace that fragment with:

```
`DEVTOYS_CLI_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PortableTools`, `Layout = "tree"` — verified by `check-invariants.sh`); **script-flag↔completion parity** — `bootstrap.sh`/`manage-hosts.sh`/`update-hosts.sh` ↔ `chezmoi/dot_config/zsh/completions/_*` + `chezmoi/dot_config/bash/completions.bash`, and `bootstrap.ps1`/`manage-hosts.ps1` ↔ the `workstation_*_flags` records in `config.nu.tmpl` (all five pairs verified by `check-invariants.sh`; add a flag → update every surface, or deliberately exclude it in the check like `--full`/`--checkforupdates`).
```

- [ ] **Step 5: CLAUDE.md nushell bullet.** In the Nushell invariant bullet, replace:

```
bump the pin deliberately, upgrade **incrementally** (skipping releases can break `config.nu`), and re-check `config.nu` on every bump.
```

with:

```
bump the pin deliberately, upgrade **incrementally** (skipping releases can break `config.nu`), and re-check `config.nu` on every bump — the repo-script flag completions (external completer + `workstation_*_flags` records at the end of `config.nu`) are a known churn surface.
```

- [ ] **Step 6: file-care.md entry.** Immediately after the `_cht.sh` bullet (line 14), insert this new bullet:

```markdown
- **`chezmoi/dot_config/zsh/completions/_{bootstrap.sh,manage-hosts.sh,update-hosts.sh}` + `chezmoi/dot_config/bash/completions.bash`** — FIRST-PARTY flag completions for the repo scripts (unlike the vendored `_cht.sh` above — edit these normally, no `.vendor` bump dance). The zsh trio autoloads from the same fpath dir as `_cht.sh` (`#compdef` on the script basename, so `./bootstrap.sh` and `scripts/manage-hosts.sh` invocations both match); the bash file is SOURCED from `dot_bashrc.tmpl` (mode 0644, no shebang — it is not a script; it IS in the shellcheck/shfmt first-party arrays, while the zsh files are zsh syntax and stay out). Their Windows counterpart is the external completer + `workstation_*_flags` records in `config.nu.tmpl`. ALL surfaces are locked to their scripts' actual flags by `check-invariants.sh`'s flag-parity check — adding/renaming a flag in `bootstrap.sh`/`manage-hosts.sh`/`update-hosts.sh`/`bootstrap.ps1`/`manage-hosts.ps1` fails the check until every completion surface is updated (or the flag is deliberately excluded in the check, like bootstrap.sh's removed `--full` and its `--checkforupdates` alias). `.config/bash` is Windows-ignored in `.chezmoiignore.tmpl` (target path).
```

- [ ] **Step 7: CLAUDE_CHANGELOG.md row** (append as the last table row, single line):

```markdown
| Added tab completion for the repo's flag-bearing scripts: zsh (`~/.config/zsh/completions/_{bootstrap.sh,manage-hosts.sh,update-hosts.sh}` — first-party, with descriptions + mutual exclusions + `--group` value enums) and bash (`~/.config/bash/completions.bash`, sourced from bashrc; `.config/bash` Windows-ignored) on Linux; a Nushell external completer in `config.nu` for `bootstrap.ps1`/`manage-hosts.ps1` on Windows (basename-keyed so any invocation path completes; returns null otherwise so default file completion is untouched; PowerShell already completes `param()` natively). New `check-invariants.sh` flag-parity check locks all five script↔completion pairs (long flags; bootstrap.sh's removed `--full` + `--checkforupdates` alias deliberately excluded; manage-hosts.sh has no help flag so none is offered). | **Yes** | §daily: tab-completion note-row before the chezmoi h3; §setup-windows: completion sentence in the Nushell paragraph. |
```

- [ ] **Step 8: Lint + commit**

```bash
make -C makefile lint MODE=prod
bash .claude/hooks/test-hooks.sh
git add README.html CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs: tab completion in daily + windows sections, parity invariant, file-care + changelog"
```

Expected: lint all-green; 51/51 hook assertions.

---

## Post-merge (user — NOT part of this plan)

- Linux: `cza`, then `rm -f ~/.zcompdump && exec zsh` (compinit caches the completion map; new `_*` files need a dump rebuild). Test: `./bootstrap.sh --<Tab>`, `./scripts/manage-hosts.sh --<Tab>`, `./scripts/update-hosts.sh --group <Tab>`; in a bash subshell: same.
- Windows: apply chezmoi (per the check-Windows-chezmoi-first memory), open a fresh Nushell, test `.\bootstrap.ps1 -` + Tab (expect the 12 flags with descriptions instead of "NO RECORDS FOUND") and `.\scripts\manage-hosts.ps1 -` + Tab; confirm unrelated completion (e.g. `git ` + Tab file fallback) unchanged.
