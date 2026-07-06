# Tool Wiring + Template Syntax CI + Root Make Shim — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the "installed but not wired" gap (activate mise, daemonize pueued, prune clipse, teach `make doctor` a wiring dimension), add rendered-template syntax checking to lint/CI, and kill the root-`make` footgun with a forwarding GNUmakefile.

**Architecture:** Three independent improvements to the workstation provisioning repo (Make + chezmoi). Wiring fixes ride existing patterns: rc parity pair for mise, a chezmoi-managed systemd *user* unit + `run_onchange` enable script for pueued (new but natural next to the root-level `configs/` service pattern), doctor.sh gains a read-only "wiring" section. Template checking is a new `scripts/check-templates.sh` (check-invariants.sh style: ok/bad/soft-skip) rendering templates via `chezmoi execute-template` with a synthetic config per host group, wired into `lint.yml` as a third job. The GNUmakefile exploits GNU make's lookup order (GNUmakefile → makefile → Makefile) to forward all goals to `makefile/`.

**Tech Stack:** GNU make, bash, chezmoi (Go templates), systemd user units, GitHub Actions.

## Global Constraints

- **This session cannot run sudo** (memory: `sudo` is not passwordless). Never run `make provision`/`make dev` or any `$(SUDO)`-wrapped target. `make lint MODE=prod`, `make doctor MODE=dev`, `chezmoi diff`, dry-runs are all fine.
- **New shell scripts:** LF-only, git mode 100755, `shfmt -i 2`-clean, shellcheck warning+-clean. `scripts/*.sh` is auto-globbed by check-invariants' shellcheck/shfmt targets; verify the LF+0755 array also covers the new file (Task 2 Step 6) — add it explicitly if that list is explicit.
- **The repo `.claude/hooks/post-edit-guard.sh` auto-repairs** CRLF/mode after edits — heed its output, re-read the file if it says so.
- **`.chezmoiignore.tmpl` patterns are TARGET paths** (`.config/systemd`), never source-state names (`dot_config/...`). Verify with `chezmoi ignored` after editing.
- **Parity pair:** `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` change in the same commit (mise task). The parity-reminder hook will nudge; that's expected.
- **`sync-tool-memory.sh` hook** auto-regenerates the `TOOLS` block in `chezmoi/private_dot_claude/CLAUDE.md` when `versions.mk`/`tools.mk` are edited (clipse task). Commit the regenerated file in the same commit; never hand-edit inside the sentinels.
- **README.html + CLAUDE_CHANGELOG.md:** every user-facing change updates README.html in the same commit and appends a row to CLAUDE_CHANGELOG.md (format: `| Change | README update? | What to add |`). Non-user-facing changes still get a changelog row with "No".
- **Commits:** conventional-commit style (`feat(...)`/`fix(...)`), end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` + the session URL trailer. **Push after every commit** (memory: standing instruction) — to the feature branch, never main. Work happens on a feature branch; a PR is opened at the end (memory: PR-review workflow; the user merges).
- **Branch:** `feat/wiring-templates-rootmake`, created via worktree isolation (superpowers:using-git-worktrees) so the live chezmoi source dir stays clean for the user.
- **MODE has no default** — every make invocation in verification steps carries `MODE=...`.

---

### Task 1: Root GNUmakefile forwarding shim

**Files:**
- Create: `GNUmakefile` (repo root)
- Modify: `CLAUDE.md` (the "Mechanical enforcement" paragraph's bare-make footgun parenthetical)
- Modify: `CLAUDE_CHANGELOG.md` (append row)

**Interfaces:**
- Produces: `make <goal> MODE=...` working from the repo root, forwarding verbatim to `makefile/`. Later tasks' verification steps may use root-level `make lint MODE=prod`.

- [ ] **Step 1: Capture the current failure (the "failing test")**

Run: `cd <worktree-root> && make lint MODE=prod 2>&1 | head -3`
Expected: `make: makefile: Is a directory` (or `*** No targets. Stop.`) — the documented footgun.

- [ ] **Step 2: Create `GNUmakefile`**

```make
# GNUmakefile — root convenience shim. The real build system lives entirely
# in makefile/ — NEVER add rules here.
#
# GNU make's makefile lookup order is GNUmakefile → makefile → Makefile, so
# this file wins over the `makefile/` DIRECTORY and fixes the documented
# footgun where `make lint MODE=prod` from the repo root died with
# `make: makefile: Is a directory`. Every goal forwards verbatim to
# makefile/; command-line variables (MODE=…) propagate automatically via
# MAKEFLAGS. With no goals it forwards goal-less, so makefile/Makefile's
# default behaviour (including scope.mk's informative MODE error) is
# identical to running `make -C makefile`.
#
# Multi-goal invocations (`make fmt lint MODE=prod`) forward ONCE with all
# goals: the first goal carries the recipe, the rest are no-op aliases that
# depend on it.

MAKEFLAGS += --no-print-directory

GOALS := $(or $(MAKECMDGOALS),__default)
FIRST := $(firstword $(GOALS))
REST  := $(filter-out $(FIRST),$(GOALS))

.PHONY: $(GOALS)

$(FIRST):
	@$(MAKE) -C makefile $(MAKECMDGOALS)

$(REST): $(FIRST)
	@:
```

(Recipe lines are TAB-indented — repo invariant.)

- [ ] **Step 3: Verify forwarding works**

Run (from repo root):
- `make lint MODE=prod` → Expected: the full invariant-check output, exit 0 (same as `make -C makefile lint MODE=prod`).
- `make list MODE=prod | head -5` → Expected: the tool listing.
- `make 2>&1 | head -3` → Expected: scope.mk's informative `MODE not set` error (parse-time, from the child make).
- `make fmt lint MODE=prod` → Expected: both targets run, single child invocation.
- `make -C makefile lint MODE=prod` → Expected: still works unchanged.

- [ ] **Step 4: Update `CLAUDE.md`**

In the "Mechanical enforcement" paragraph, replace the parenthetical

`(the makefile lives in `makefile/`, so a bare `make` from the repo root fails — `make: makefile: Is a directory`; use `-C makefile` or `cd makefile` first)`

with

`(a root `GNUmakefile` forwards all goals to `makefile/`, so `make lint MODE=prod` works from the repo root as well as via `-C makefile`)`

- [ ] **Step 5: Append CLAUDE_CHANGELOG.md row**

```markdown
| Added a root `GNUmakefile` forwarding shim — GNU make prefers `GNUmakefile` over the `makefile/` directory, so `make <goal> MODE=…` now works from the repo root (previously died with `make: makefile: Is a directory`). All goals + command-line vars forward verbatim to `makefile/`; multi-goal calls forward once. No rules may ever be added to the shim. | **Yes** | §daily: note that `make` commands work from the repo root as well as `makefile/` (one sentence next to the existing make-invocation examples). |
```

- [ ] **Step 6: Update README.html per the row** — find the §daily make-invocation prose (search for `-C makefile` / `cd makefile`) and add the one-sentence note that commands also work from the repo root.

- [ ] **Step 7: Commit + push**

```bash
git add GNUmakefile CLAUDE.md CLAUDE_CHANGELOG.md README.html
git commit -m "feat(make): root GNUmakefile forwards goals to makefile/ (kills the bare-make footgun)"
git push -u origin feat/wiring-templates-rootmake
```

---

### Task 2: `scripts/check-templates.sh` + lint.yml `templates` job

**Files:**
- Create: `scripts/check-templates.sh`
- Modify: `.github/workflows/lint.yml` (add `templates` job)
- Modify: `scripts/check-invariants.sh` (ONLY if its LF+0755 file list is an explicit array that doesn't glob `scripts/*.sh` — verify first)
- Modify: `CLAUDE.md` ("Mechanical enforcement" paragraph — one sentence), `CLAUDE_CHANGELOG.md` (row)

**Interfaces:**
- Produces: `bash scripts/check-templates.sh` — exit 0 all-pass, exit 1 on any failure; soft-skips missing checkers (zsh/nu/pwsh) with a note, like check-invariants does. Tasks 3–5 use it to verify template edits.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# check-templates.sh — render the chezmoi templates for each host group and
# syntax-check the rendered output. Catches Go-template errors and shell/nu/
# gitconfig syntax errors at lint time instead of at `chezmoi apply` time on
# a live host (where a broken .zshrc breaks every new shell).
#
# Renders happen on Linux, so `.chezmoi.os` is "linux": Linux-target files
# get full render+syntax coverage; Windows-target files (config.nu, the
# PowerShell profile) still get template-PARSE coverage plus a syntax check
# of their linux-rendered body (both barely branch on OS — see CLAUDE.md).
#
# Checkers soft-skip when absent (mirrors check-invariants.sh): zsh, nu and
# pwsh may be missing locally; CI (lint.yml `templates` job) installs them
# all, so the full matrix always enforces there.
#
# Usage: bash scripts/check-templates.sh          (from anywhere; repo-relative)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/chezmoi"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

fails=0
hdr() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok() { printf ' %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad() {
  printf ' %s✗%s %s\n' "$RED" "$RESET" "$*"
  fails=$((fails + 1))
}
note() { printf ' · %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || {
  note "chezmoi not installed — cannot render templates (CI enforces)"
  exit 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Synthetic chezmoi config per group. The templates under test reference
# .name / .email / .group (plus runtime .chezmoi.* values chezmoi provides).
make_cfg() { # $1=group → prints config path
  local cfg="$WORK/chezmoi-$1.toml"
  cat >"$cfg" <<EOF
[data]
  group = "$1"
  name = "Template Check"
  email = "check@example.invalid"
EOF
  printf '%s' "$cfg"
}

# render <group> <source-relative-template> <out-file>
render() {
  local cfg
  cfg="$(make_cfg "$1")"
  chezmoi --config "$cfg" --source "$SRC" execute-template \
    <"$SRC/$2" >"$3" 2>"$WORK/render-err"
}

# check <group> <template> <label> <checker-cmd...>   (checker gets $out appended)
check() {
  local group=$1 tmpl=$2 label=$3
  shift 3
  local out="$WORK/out"
  if ! render "$group" "$tmpl" "$out"; then
    bad "$label [$group]: template render failed: $(head -1 "$WORK/render-err")"
    return
  fi
  if [ "$#" -eq 0 ]; then
    ok "$label [$group]: renders"
    return
  fi
  if "$@" "$out" >"$WORK/check-err" 2>&1; then
    ok "$label [$group]: renders + syntax OK"
  else
    bad "$label [$group]: syntax check failed: $(head -1 "$WORK/check-err")"
  fi
}

zsh_check() { zsh -n "$1"; }
bash_check() { bash -n "$1"; }
git_check() { git config --file "$1" --list >/dev/null; }
nu_check() { nu --no-config-file --commands "if (nu-check '$1') { exit 0 } else { exit 1 }"; }
pwsh_check() {
  pwsh -NoProfile -Command \
    "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$1',[ref]\$null,[ref]\$e); if (\$e) { \$e | ForEach-Object { \$_.Message }; exit 1 }"
}

hdr "rendered-template syntax checks (dev_machine + prod_machine)"
for group in dev_machine prod_machine; do
  if command -v zsh >/dev/null 2>&1; then
    check "$group" dot_zshrc.tmpl ".zshrc" zsh_check
  else
    note ".zshrc [$group]: zsh not installed — render-only"
    check "$group" dot_zshrc.tmpl ".zshrc(render)"
  fi
  check "$group" dot_bashrc.tmpl ".bashrc" bash_check
  check "$group" dot_gitconfig.tmpl ".gitconfig" git_check
  check "$group" .chezmoiignore.tmpl ".chezmoiignore"
done

# Windows-target files: group-independent content; render once as dev_machine.
if command -v nu >/dev/null 2>&1; then
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu" nu_check
else
  note "config.nu: nu not installed — render-only (CI enforces)"
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu(render)"
fi
if command -v pwsh >/dev/null 2>&1; then
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile" pwsh_check
else
  note "PS profile: pwsh not installed — render-only (CI enforces)"
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile(render)"
fi

hdr "summary"
if ((fails > 0)); then
  printf '   %d failure(s)\n' "$fails"
  exit 1
fi
printf '   all rendered templates pass\n'
```

Set the executable bit: `chmod +x scripts/check-templates.sh` (post-edit-guard may do this for you — confirm `git ls-files --stage scripts/check-templates.sh` shows `100755` after `git add`).

**Implementation notes (verify live, adjust if needed):**
- `--source "$SRC"` points at `chezmoi/` directly (not the repo root) — sidesteps any `.chezmoiroot` handling differences in `execute-template`. If `include`-style template functions ever fail, try `--source "$REPO_ROOT"` instead.
- If `chezmoi execute-template` errors about a missing destination dir, add `--destination "$WORK/dest"` (create it).
- The nu-check invocation syntax may need adjusting to the installed nu version; verify against `nu --version` locally if nu exists, else trust CI iteration.

- [ ] **Step 2: Run it — expect current templates to PASS (green baseline)**

Run: `bash scripts/check-templates.sh`
Expected: all ✓/· rows, exit 0. (zsh IS installed on this host; nu/pwsh soft-skip.)

- [ ] **Step 3: Prove it catches breakage (the "failing test")**

Temporarily append `if [` to a COPY-based check: `cp chezmoi/dot_zshrc.tmpl /tmp/x && echo 'if [' >> chezmoi/dot_zshrc.tmpl && bash scripts/check-templates.sh; mv /tmp/x chezmoi/dot_zshrc.tmpl`
Expected: ✗ row for .zshrc, exit 1. Then confirm restored file passes again.

- [ ] **Step 4: Add the `templates` job to `.github/workflows/lint.yml`**

```yaml
  templates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Install chezmoi
        run: sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
      - name: Install zsh
        run: sudo apt-get update && sudo apt-get install -y zsh
      # nushell here is a CI-ONLY syntax checker for config.nu.tmpl — NOT a
      # fleet tool: no versions.mk entry, deliberately NOT an enforced
      # dual-edit with bootstrap.ps1's Nushell pin (drift is harmless; this
      # only parses). Bump ad-hoc when the check needs newer syntax.
      - name: Install nushell (pinned, CI-only)
        run: |
          NU=<copy the version from bootstrap.ps1 $PortableTools at implementation time>
          curl -fsSL "https://github.com/nushell/nushell/releases/download/${NU}/nu-${NU}-x86_64-unknown-linux-musl.tar.gz" -o /tmp/nu.tgz
          tar -xzf /tmp/nu.tgz -C /tmp
          sudo install -m 0755 /tmp/nu-${NU}-x86_64-unknown-linux-musl/nu /usr/local/bin/nu
          nu --version
      - name: Render + syntax-check templates
        run: PATH="$HOME/.local/bin:$PATH" bash scripts/check-templates.sh
```

(pwsh is preinstalled on ubuntu-latest. Read the actual Nushell pin out of `bootstrap.ps1`'s `$PortableTools` and substitute it for the placeholder — the placeholder MUST NOT survive to commit.)

- [ ] **Step 5: Verify workflow syntax**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml'))" && echo YAML-OK`
Expected: `YAML-OK`.

- [ ] **Step 6: Confirm invariant coverage of the new script**

Run: `bash scripts/check-invariants.sh 2>&1 | tail -20` (or root `make lint MODE=prod`).
Expected: passes; the shellcheck/shfmt sections glob `scripts/*.sh` so the new file is covered. Inspect the LF+0755 check (`hdr "line-endings (LF) + git mode (100755)"` section, ~line 132): if its file array globs `scripts/*.sh`, nothing to do; if it's an explicit list, add `scripts/check-templates.sh` to it.

- [ ] **Step 7: Update CLAUDE.md + changelog**

CLAUDE.md "Mechanical enforcement" paragraph — after the sentence describing what check-invariants.sh covers, add: `scripts/check-templates.sh` renders the tracked templates for both host groups and syntax-checks the output (zsh/bash/gitconfig/nu/pwsh; soft-skips missing checkers locally, the lint.yml `templates` job enforces the full set in CI).

CLAUDE_CHANGELOG.md row:

```markdown
| Added `scripts/check-templates.sh` + a `templates` CI job in `lint.yml` — renders `dot_zshrc/dot_bashrc/dot_gitconfig/.chezmoiignore` templates for BOTH host groups via `chezmoi execute-template` with a synthetic config, plus the Windows `config.nu`/PowerShell profile, and syntax-checks each (`zsh -n`, `bash -n`, `git config --list`, `nu-check`, PS `Parser::ParseFile`). Soft-skips missing checkers locally; CI installs chezmoi+zsh+nu (nu is a CI-only pin, deliberately NOT a versions.mk dual-edit). Template/shell breakage now surfaces at lint time, not `cza` time on a live host. | No | CI/lint internals — invisible to a README-only user. CLAUDE.md mechanical-enforcement paragraph updated instead. |
```

- [ ] **Step 8: Commit + push**

```bash
git add scripts/check-templates.sh .github/workflows/lint.yml scripts/check-invariants.sh CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "feat(lint): render + syntax-check chezmoi templates (script + CI job)"
git push
```

---

### Task 3: Prune clipse

**Files:**
- Modify: `makefile/tools.mk` (delete the clipse comment block + TOOL call, ~lines 288–299, and the `UPDATE_SPECS += clipse|...` line ~502)
- Modify: `makefile/versions.mk` (delete `CLIPSE_VERSION := 1.2.1`, ~line 152)
- Modify: `chezmoi/private_dot_claude/CLAUDE.md` (TOOLS block — regenerated AUTOMATICALLY by the sync-tool-memory hook on the tools.mk/versions.mk edits; just `git add` it)
- Modify: `README.html` (remove the clipse chip, ~line 1814, Shell & dev utilities card)
- Modify: `CLAUDE_CHANGELOG.md` (row)

**Interfaces:**
- Consumes: nothing. Produces: clipse fully deregistered; doctor/check-updates/list stop reporting it automatically (macro-registered rows disappear with the registration).

- [ ] **Step 1: Delete the clipse block from `makefile/tools.mk`**

Remove the full comment block + call (exact current text):

```make
# clipse — TUI clipboard manager. Publishes TWO linux builds (x11 + wayland);
...
# RUNTIME: needs a graphical clipboard + a background `clipse -listen` daemon;
...
$(eval $(call TOOL,clipse,$(CLIPSE_VERSION),\
  $(LIB)/archive.sh clipse-linux-x11-amd64=clipse https://github.com/savedra1/clipse/releases/download/v$(CLIPSE_VERSION)/clipse_v$(CLIPSE_VERSION)_linux_x11_amd64.tar.gz,clipse))
```

(Read the file first; delete the whole contiguous comment+call block, lines ~288–299.)

Also delete: `UPDATE_SPECS += clipse|$(CLIPSE_VERSION)|savedra1/clipse|v$(CLIPSE_VERSION)` (~line 502).

- [ ] **Step 2: Delete `CLIPSE_VERSION := 1.2.1` from `makefile/versions.mk`**

- [ ] **Step 3: Verify deregistration + hook regen**

- `rg -i clipse makefile/` → Expected: no hits.
- `make list MODE=prod | rg -i clipse` → Expected: no hits (run from repo root — Task 1's shim).
- `make lint MODE=prod` → Expected: pass (confirms no dangling pin references).
- `rg -c clipse chezmoi/private_dot_claude/CLAUDE.md` → Expected: 0 (hook regenerated the TOOLS block; if the hook didn't fire, run `bash scripts/gen-tool-memory.sh` manually).

- [ ] **Step 4: Remove the clipse chip from README.html** (~line 1814; delete the whole chip element including its `sr-only` span, matching neighboring chip markup exactly).

- [ ] **Step 5: Append CLAUDE_CHANGELOG.md row**

```markdown
| Pruned **clipse** from the toolbelt (`tools.mk` TOOL+UPDATE_SPECS entries + `CLIPSE_VERSION` pin) — added in the #11 gap-filler sweep but never wired: it needs a graphical clipboard AND a background `clipse -listen` daemon; the dev fleet is WSL (Windows has native Win+V history) and prod is headless, so it was dead weight by construction. Installed binaries on existing hosts are orphaned, not removed — `sudo rm /usr/local/bin/clipse` (dev) / `rm ~/.local/bin/clipse` (prod) to tidy. TOOLS memory block auto-regenerated. | **Yes** | Remove the `clipse` chip from the Shell & dev utilities Stack card. |
```

- [ ] **Step 6: Commit + push**

```bash
git add makefile/tools.mk makefile/versions.mk chezmoi/private_dot_claude/CLAUDE.md README.html CLAUDE_CHANGELOG.md
git commit -m "feat(tools): prune clipse — unwireable on this fleet (WSL dev + headless prod)"
git push
```

---

### Task 4: Wire mise activation (zsh + bash parity)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (insert after the broot block, ~line 175, before the starship block)
- Modify: `chezmoi/dot_bashrc.tmpl` (insert at the equivalent tool-init cluster — locate the zoxide/broot inits)
- Modify: `CLAUDE_CHANGELOG.md` (row)

**Interfaces:**
- Produces: `mise activate` eval'd in both interactive shells. Task 6's doctor check greps deployed `~/.zshrc` for `mise activate`.

- [ ] **Step 1: Insert into `dot_zshrc.tmpl`** (between the broot block and the starship block):

```zsh
# --- mise (per-project tool versions: node/python/go from mise.toml) ----------
# `mise activate` installs a precmd/chpwd hook that puts the active project's
# tools on PATH as you cd. Without it the mise binary is inert outside an
# explicit `mise exec` — installed-but-not-wired (caught by `make doctor`).
if command -v mise &>/dev/null; then
  eval "$(mise activate zsh)"
fi
```

- [ ] **Step 2: Insert the bash twin into `dot_bashrc.tmpl`** (same comment, `mise activate bash`; place next to its zoxide/broot inits — read the file to find the cluster):

```bash
# --- mise (per-project tool versions: node/python/go from mise.toml) ----------
# `mise activate` hooks PROMPT_COMMAND to put the active project's tools on
# PATH as you cd. Without it the mise binary is inert outside `mise exec`.
if command -v mise &>/dev/null; then
  eval "$(mise activate bash)"
fi
```

- [ ] **Step 3: Verify via the Task-2 harness + live shell**

- `bash scripts/check-templates.sh` → Expected: all pass (renders + `zsh -n`/`bash -n` on the new blocks).
- Live smoke (doesn't need `cza`): `zsh -c 'eval "$(mise activate zsh)" && typeset -f _mise_hook >/dev/null && echo zsh-hook-ok'` → Expected: `zsh-hook-ok` (function name may differ by mise version — any zero exit + no error output is a pass; adjust the probe to what `mise activate zsh | head` shows).
- `bash -c 'eval "$(mise activate bash)" && echo bash-hook-ok'` → Expected: `bash-hook-ok`.

- [ ] **Step 4: Append CLAUDE_CHANGELOG.md row**

```markdown
| Wired **mise** into both interactive shells — `eval "$(mise activate zsh|bash)"` (command-guarded) in the tool-init cluster of `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` (parity pair, same commit). The binary had been installed since the 2026-05 wave but was inert: no activation hook = no per-project PATH management. | No | Interactive-shell behavior, no new command/flag/path (precedent: the shell-ergonomics row). |
```

- [ ] **Step 5: Commit + push**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl CLAUDE_CHANGELOG.md
git commit -m "feat(shell): activate mise in zsh+bash — installed since 2026-05 but inert without the hook"
git push
```

---

### Task 5: pueued systemd user unit + enable script

**Files:**
- Create: `chezmoi/dot_config/systemd/user/pueued.service.tmpl`
- Create: `chezmoi/.chezmoiscripts/run_onchange_after_enable-pueued.sh.tmpl`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows block: add `.config/systemd` target path)
- Modify: `README.html` (§daily services / troubleshooting mention), `CLAUDE_CHANGELOG.md` (row)

**Interfaces:**
- Produces: `~/.config/systemd/user/pueued.service` deployed on Linux (both groups), auto-enabled on apply. Task 6's doctor check probes `systemctl --user is-active pueued.service`.

- [ ] **Step 1: Create `chezmoi/dot_config/systemd/user/pueued.service.tmpl`**

```ini
# ~/.config/systemd/user/pueued.service — managed by chezmoi.
# pueue's client is useless until this daemon runs; enabled automatically by
# the run_onchange_after_enable-pueued chezmoi script on apply.

[Unit]
Description=Pueue task-queue daemon (pueued)
Documentation=https://github.com/Nukesor/pueue

[Service]
{{- /* DEST is scope-dependent: dev installs to /usr/local/bin, prod to
       ~/.local/bin. systemd resolves ExecStart from a fixed compiled-in
       path list (never the user's PATH), so the absolute path must be
       templated by group. Hosts predating the `group` data field were all
       dev-era → default to the dev path. */}}
ExecStart={{ if and (hasKey . "group") (eq .group "prod_machine") }}{{ .chezmoi.homeDir }}/.local/bin{{ else }}/usr/local/bin{{ end }}/pueued -v
Restart=on-failure

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Create `chezmoi/.chezmoiscripts/run_onchange_after_enable-pueued.sh.tmpl`**

```bash
{{ if eq .chezmoi.os "linux" -}}
#!/bin/bash
# Enable (or refresh) the pueued user service. run_onchange: re-fires when
# this script's rendered body changes — the unit-file hash below ties it to
# the unit, so editing pueued.service re-runs the enable+restart.
# unit hash: {{ include "dot_config/systemd/user/pueued.service.tmpl" | sha256sum }}
# Fail-soft everywhere: a host without a systemd user manager (rare: no
# logind session) just gets told what to run by hand. Never blocks apply.
set -eu
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  if systemctl --user enable --now pueued.service >/dev/null 2>&1; then
    systemctl --user try-restart pueued.service >/dev/null 2>&1 || true
    echo "workstation: pueued user service enabled"
  else
    echo "workstation: could not enable pueued — run: systemctl --user enable --now pueued" >&2
  fi
else
  echo "workstation: no systemd user manager — start pueued manually: pueued -d" >&2
fi
{{ end -}}
```

(Non-Linux renders zero bytes → chezmoi skips it, same pattern as the existing OS-gated scripts; see the `.chezmoiignore.tmpl` comment about `.chezmoiscripts` not being ignorable.)

- [ ] **Step 3: Add `.config/systemd` to the WINDOWS ignore block in `chezmoi/.chezmoiignore.tmpl`**

In the `{{ if eq .chezmoi.os "windows" }}` block, after `.config/zsh`, add:

```
# pueued's systemd user unit is meaningless on Windows.
.config/systemd
```

(TARGET path, not `dot_config/...` — the tripwire.)

- [ ] **Step 4: Verify**

- `bash scripts/check-templates.sh` → Expected: pass (`.chezmoiignore` render check covers the edit).
- `chezmoi ignored | rg systemd` → Expected: NO hit on this Linux host (it's a Windows-only ignore); `chezmoi ignored` still lists the other expected targets (non-empty — an empty list = the target-path bug).
- `chezmoi diff 2>/dev/null | rg -A2 'pueued'` → Expected: shows the pending new unit file + script (do NOT apply; the user runs `cza`).
- Render the unit for both groups through the Task-2 harness pattern by hand:
  `chezmoi --config <(printf '[data]\n group = "prod_machine"\n name="x"\n email="x@x"') --source chezmoi execute-template < chezmoi/dot_config/systemd/user/pueued.service.tmpl | rg ExecStart` → Expected: `ExecStart=/home/.../.local/bin/pueued -v`; dev_machine variant → `/usr/local/bin/pueued -v`. (If process substitution for --config misbehaves, write the temp config to a file.)

- [ ] **Step 5: README.html + changelog**

README: in the services/daily area (where dozzle/cockpit service commands live), add a one-liner: pueue's daemon runs as a per-user service, auto-enabled by `chezmoi apply`; `systemctl --user status pueued` to inspect.

CLAUDE_CHANGELOG.md row:

```markdown
| **pueued** now runs as a chezmoi-managed systemd USER unit (`dot_config/systemd/user/pueued.service.tmpl`, ExecStart path templated by group: dev `/usr/local/bin`, prod `~/.local/bin`) + a `run_onchange` enable script (`daemon-reload` + `enable --now`, fail-soft, hash-tied to the unit). First systemd *user* unit in the repo — the user-scope sibling of the root-level `configs/` service pattern; `.config/systemd` added to the WINDOWS ignore block (target path). Previously `pueue` failed on every host until someone hand-started `pueued -d`. | **Yes** | One line in the services/daily section: pueued is a per-user service, auto-enabled on apply; `systemctl --user status pueued`. |
```

- [ ] **Step 6: Commit + push**

```bash
git add chezmoi/dot_config/systemd chezmoi/.chezmoiscripts/run_onchange_after_enable-pueued.sh.tmpl chezmoi/.chezmoiignore.tmpl README.html CLAUDE_CHANGELOG.md
git commit -m "feat(services): pueued as a chezmoi-managed systemd user unit, auto-enabled on apply"
git push
```

---

### Task 6: Doctor "wiring" dimension

**Files:**
- Modify: `makefile/lib/doctor.sh` (add `check_wiring` function + call it from `main` before the summary)
- Modify: `CLAUDE_CHANGELOG.md` (row)

**Interfaces:**
- Consumes: Task 4's rc grep target (`mise activate` in deployed `~/.zshrc`), Task 5's unit name (`pueued.service`).

- [ ] **Step 1: Read `doctor.sh`'s `main()`** to find the exact call sequence and insert `check_wiring` before the summary call.

- [ ] **Step 2: Add the function** (above `main`, matching existing style):

```bash
# --- wiring — tools that need more than a binary on PATH ---------------------
# verify-binary.sh gates "installed but won't RUN"; this gates "installed but
# won't DO anything": tools whose value depends on a shell hook or a running
# daemon. Read-only, like everything else in this report.
check_wiring() {
  hdr "wiring (shell hooks + daemons)"

  # mise — inert without `mise activate` in the interactive shell rc.
  if command -v mise >/dev/null 2>&1; then
    if grep -q 'mise activate' "$HOME/.zshrc" 2>/dev/null; then
      row_ok "mise" "activated in ~/.zshrc"
    else
      row_warn "mise" "no 'mise activate' in ~/.zshrc — run: chezmoi apply"
    fi
  else
    row_skip "mise" "not installed"
  fi

  # pueued — every pueue command fails until the daemon runs.
  if command -v pueued >/dev/null 2>&1; then
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
      row_skip "pueued" "no systemd user manager (start manually: pueued -d)"
    elif systemctl --user is-active --quiet pueued.service; then
      row_ok "pueued" "user service active"
    else
      row_warn "pueued" "daemon not running — run: systemctl --user enable --now pueued"
    fi
  else
    row_skip "pueued" "not installed"
  fi
}
```

- [ ] **Step 3: Run doctor and eyeball the section**

Run: `make doctor MODE=dev 2>&1 | tail -25` (root shim; doctor is sudo-free, read-only).
Expected: a `wiring (shell hooks + daemons)` section. On THIS host, before the user runs `cza`: mise → `!` warn (activation not yet deployed), pueued → `!` warn (unit not yet applied/enabled). These warns are the check working correctly against pre-apply reality.

- [ ] **Step 4: Lint** — `make lint MODE=prod` → Expected: pass (doctor.sh is in the shellcheck/shfmt set; `makefile/lib/*.sh` LF+0755 must hold — post-edit-guard repairs if needed).

- [ ] **Step 5: Append CLAUDE_CHANGELOG.md row**

```markdown
| `make doctor` gained a **wiring** section — extends the verify-binary philosophy ("installed must mean executable") to "installed must be WIRED": mise checks for `mise activate` in the deployed `~/.zshrc`, pueued checks `systemctl --user is-active pueued.service` (soft-skips where no user manager). Read-only, warn-with-repair-hint rows like the rest of the report. | No | doctor output format change only; README already documents `make doctor` / `--doctor` generically. |
```

- [ ] **Step 6: Commit + push**

```bash
git add makefile/lib/doctor.sh CLAUDE_CHANGELOG.md
git commit -m "feat(doctor): wiring section — flag installed-but-unwired tools (mise hook, pueued daemon)"
git push
```

---

### Task 7: Final verification sweep + PR

**Files:** none (verification only) — then PR.

- [ ] **Step 1: Full local gate**

- `make lint MODE=prod` (root shim) → pass.
- `bash scripts/check-templates.sh` → pass.
- `bash .claude/hooks/test-hooks.sh` → pass (hooks untouched, but cheap insurance).
- `make doctor MODE=dev 2>&1 | tail -30` → wiring section present; only the two expected pre-apply warns.
- `chezmoi diff | head -40` → pending changes are exactly: zshrc/bashrc mise blocks, pueued unit + script, TOOLS block (clipse gone). Nothing unexpected.
- `git ls-files --stage GNUmakefile scripts/check-templates.sh chezmoi/.chezmoiscripts/run_onchange_after_enable-pueued.sh.tmpl` → modes sane (script = 100755; tmpl/GNUmakefile 100644 is fine).
- `file scripts/check-templates.sh makefile/lib/doctor.sh` → no CRLF.

- [ ] **Step 2: Open the PR** (superpowers:finishing-a-development-branch; the user merges — never self-merge without an explicit named go-ahead):

```bash
gh pr create --title "feat: tool wiring (mise/pueued/clipse), template syntax CI, root make shim" --body "<summary of the 6 commits, per-area; note the two expected doctor warns clear after cza + the clipse orphan-binary cleanup one-liner>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01DYbuKJvpPaHKV7AFysMJ8s"
```

- [ ] **Step 3: Report to the user** — PR link, what lands on next `cza` (mise activation, pueued service), the clipse cleanup one-liner, and that CI now has a third lint job.

---

## Self-Review (done at write time)

- **Spec coverage:** item 1 (mise → Task 4, pueued → Task 5, clipse → Task 3, doctor wiring → Task 6), item 2 (Task 2), item 4 (Task 1). ✓
- **Placeholders:** one deliberate implementation-time substitution (Nushell CI pin version, marked MUST NOT survive to commit); all other code complete. ✓
- **Consistency:** doctor greps `mise activate` — matches Task 4's exact inserted text; unit name `pueued.service` consistent across Tasks 5/6; `check-templates.sh` path consistent across Tasks 2/4/5/7. ✓
