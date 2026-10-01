# Simplification PR 3 — One place per value — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store each Linux-side value once:
- the `MISE_ENV` token set goes in a git-ignored `miserc.toml`, not baked into three templates plus the systemd manager
- the Nerd Font becomes a mise tool
- python-env uses mise's own Python
- the Python library list lives in one file
- zjstatus loads straight from mise's install dir

**Architecture:**
- `scripts/lib/mise-env.sh <mode> --write` writes `~/.config/mise/miserc.toml` (`env = [...]`, `auto_env = false`). Every mise process reads it: shells, shims under `env -i` (the pueued unit), `mise dot`, `mise run`, and `mise bootstrap`. Nothing exports `MISE_ENV` any more.
- `[vars] nerd_font_version` and `python_version` disappear:
  - The font becomes `github:ryanoasis/nerd-fonts` in `config.owned.toml`. mise's lock file holds its checksum.
  - python-env builds its venv from `mise where python`.
- `config.kdl` points zjstatus at mise's `latest` install path, so the copy script goes.
- Windows still pins the font and python in `bootstrap.ps1` until PR 4, so those checks become two-way rather than disappearing.

**Tech Stack:** mise 2026.9.9 (`miserc.toml`, `github:` backend + lock, `mise lock <tool>`), bash, Tera templates, zellij 0.45.1.

**Spec:** `docs/superpowers/specs/2026-09-29-simplify-design.md` §5 PR 3 and §3.

## Global Constraints

- Branch `refactor/simplify-pins` (created from `main` at `a87b240`). Commit after each task and push. Never push to `main`, never force-push, never `--no-verify`. The pre-commit hook runs `mise run lint`.
- Every commit message ends with a blank line and then:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```
  Use these exact lines even if your own context suggests a different model name.
- This checkout IS the live mise config (`~/.config/mise`). Never run any of these:
  - `mise dot apply`, `wsa`, or `mise bootstrap` without `--dry-run`/`plan`/`status`
  - `mise install`, `mise run update`, `mise run fonts`, `mise run python-env --rebuild`, `./bootstrap.sh`, or anything with `sudo`
  - `scripts/lib/mise-env.sh … --write` against the real `$HOME` (use a scratch `HOME`/`XDG_CONFIG_HOME`)

  Task 5's live run belongs to the user.
- Verified facts this plan relies on (sandbox-tested 2026-09-29/10-01, mise 2026.9.9 / zellij 0.45.1):
  - **`miserc.toml`:** a `~/.config/mise/miserc.toml` containing `env = ["…"]` selects the config files from any cwd. It works for shims under `env -i`, `mise dot status`, `mise run` (tasks then see `MISE_ENV`), and `mise bootstrap --dry-run`. `auto_env` is accepted there.
  - **Exported `MISE_ENV` wins:** an exported `MISE_ENV`, even an empty one, overrides miserc.
  - **Nerd Font as a mise tool:** `"github:ryanoasis/nerd-fonts" = { version = "3.5.1", asset_pattern = "JetBrainsMono.tar.xz" }` locks `sha256:04d5e8f9…10cf` for both `linux-x64` and `windows-x64`. It installs the TTFs at the top level of `mise where`, including the six `JetBrainsMonoNerdFontMono-{Regular,Italic,Bold,BoldItalic,Medium,MediumItalic}.ttf`.
  - **Locking one tool:** `mise lock [TOOL]…` updates only the named tool.
  - **mise's Python:** `mise where python` is `~/.local/share/mise/installs/python/3.14.7`; `bin/python3` exists. `mise current python` prints `3.14.7`.
  - **zjstatus from mise's install dir:** zellij loads `file:~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm`. The log shows `Loaded plugin '/home/<user>/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm'`.
  - **Leftover deployed files:** mise doesn't delete a deployed dotfile when its `[dotfiles]` entry is removed.
- Mode/LF/shfmt rules as before (`post-edit-guard.sh` repairs mode, line endings and BOM). `mise tasks validate` prints no warnings.
- Size limits:
  - `CLAUDE.md` ≤ 14,000 bytes
  - `CLAUDE.md` + `docs/claude/*` ≤ 30,000 bytes
  - `README.md` ≤ 600 lines
- User-visible behaviour changes go into `README.md` in the same commit; rule changes go into `CLAUDE.md`.

## Review Focus

1. **A shell, unit or task still sees a stale exported `MISE_ENV` and silently loads the wrong config set** (an exported value beats miserc). Task 1:
   - step 1's test proves the rc templates and environment.d no longer export it
   - `mise-env.sh --write` cleans the old sources
   - `tasks/update` and `bootstrap.sh` `unset MISE_ENV` before running mise
   - health warns on any leftover
2. **A shared host gets owned tokens, or a WSL host gets `native`.** Task 1, step 1 pins `mise-env.sh --write`'s output file for owned-WSL, owned-native and shared (with a forced `WSL_DISTRO_NAME`).
3. **The python version moves, and `wpy` keeps pointing at a deleted interpreter** with nothing rebuilding it. Task 3's stamp key includes the interpreter path, so a python bump forces a rebuild (step 1's test).
4. **The font pin on Linux and Windows drifts apart while they're still in two places.** Task 2 keeps a two-way check and the bumper exclusion until PR 4.
5. **zellij shows a broken bar after the path change** (e.g. a non-default `MISE_DATA_DIR`, or the `latest` symlink missing). Task 4's health row checks the exact configured path, and Task 5's live step loads it.

---

### Task 1: The token set lives in `miserc.toml`

**Files:**
- Rewrite: `scripts/lib/mise-env.sh` (full content below)
- Modify:
  - `bootstrap.sh`: compute + `--write` + `unset MISE_ENV`; drop `systemctl set-environment` from `apply()`; log lines use the token variable
  - `tasks/update` (full content below)
  - `scripts/lib/mise-install.sh`: drop the `MISE_ENV` guard and the `MISE_ENV` print; header comment
- Modify:
  - `dotfiles/zshenv.tera`: delete the `MISE_ENV` block; the header says "two exports"
  - `dotfiles/bashrc.tera`: delete the `MISE_ENV` block (its header comment and the `export MISE_ENV=` line)
- Delete: `dotfiles/config/environment.d/10-mise.conf.tera`. In `config.linux.toml`, remove its `[dotfiles]` entry, its comment, and the "must render the same MISE_ENV" sentence, and rewrite the pueued comment: the shim reads `miserc.toml`.
- Modify: `tasks/health`:
  - replace the "MISE_ENV shell" row, the "MISE_ENV persisted" section and the header's `MISE_ENV=` with the miserc and legacy rows below
  - replace `export MISE_ENV="$canonical_env"` with `unset MISE_ENV`
- Modify:
  - `.claude/hooks/session-context.sh`: owned/shared comes from miserc's tokens, not `$MISE_ENV`
  - `.claude/hooks/parity-reminder.sh`: drop the `MISE_ENV` three-way clause; then run `bash .claude/hooks/test-hooks.sh`
- Modify:
  - `scripts/check-invariants.sh`: delete `check_mise_env_three_way`, `_render_baked_mise_env` and their call
  - `scripts/check-templates.sh`: drop `~/.config/environment.d/10-mise.conf` from `select_checker`
- Modify: `.gitignore` (add `miserc.toml`), and `config.toml`'s header comment (which files load is picked by `miserc.toml`'s `env`, written by `scripts/lib/mise-env.sh`; an exported `MISE_ENV` overrides it)
- Docs:
  - `CLAUDE.md`: the Mode and `MISE_ENV` section, the Layout token-set line, the pueued bullet
  - `README.md`: the owned/shared section's "how the mode becomes a config set", and the "pueue status fails" troubleshooting entry
  - `docs/claude/verification.md`: the pueued recipe
  - `.claude/memory/project-bootstrap-owned-shared.md`: any statement that rc files export `MISE_ENV`

**Interfaces:**
- Produces:
  - `scripts/lib/mise-env.sh <owned|shared>` prints the token set
  - `scripts/lib/mise-env.sh <owned|shared> --write` additionally writes `${XDG_CONFIG_HOME:-$HOME/.config}/mise/miserc.toml`, runs the one-time legacy cleanup, and prints the token set

- [ ] **Step 1: Write the test first (it fails now)**

Save as `.superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-miserc.sh` (create the directory):
```bash
#!/usr/bin/env bash
# miserc: mise-env.sh --write output per mode; templates no longer export MISE_ENV.
set -uo pipefail
cd ~/.config/mise
fail=0
t=$(mktemp -d)
# Stub systemctl: never touch the real user manager; log what --write asks for.
mkdir -p "$t/bin" "$t/h/.config/mise"
printf '#!/bin/sh\necho "$*" >> %s/systemctl.log\n[ "$2" = show-environment ] && echo MISE_ENV=linux\nexit 0\n' "$t" > "$t/bin/systemctl"; chmod +x "$t/bin/systemctl"
w() { env -u WSL_DISTRO_NAME HOME="$t/h" XDG_CONFIG_HOME="$t/h/.config" PATH="$t/bin:$PATH" "$@"; }
w WSL_DISTRO_NAME=Alma scripts/lib/mise-env.sh owned --write >/dev/null 2>&1
grep -qx 'env = \["linux", "owned", "host", "wsl"\]' "$t/h/.config/mise/miserc.toml" 2>/dev/null || { echo "FAIL owned+wsl miserc"; fail=1; }
grep -qx 'auto_env = false' "$t/h/.config/mise/miserc.toml" 2>/dev/null || { echo "FAIL auto_env"; fail=1; }
w scripts/lib/mise-env.sh shared --write >/dev/null 2>&1
grep -qx 'env = \["linux"\]' "$t/h/.config/mise/miserc.toml" 2>/dev/null || { echo "FAIL shared miserc"; fail=1; }
# a legacy environment.d file holding only our line is removed; a foreign one is kept
mkdir -p "$t/h/.config/environment.d"
printf '# managed\nMISE_ENV=linux\n' > "$t/h/.config/environment.d/10-mise.conf"
w scripts/lib/mise-env.sh shared --write >/dev/null 2>&1
[ ! -e "$t/h/.config/environment.d/10-mise.conf" ] || { echo "FAIL legacy environment.d not removed"; fail=1; }
printf 'MISE_ENV=linux\nFOO=bar\n' > "$t/h/.config/environment.d/10-mise.conf"
w scripts/lib/mise-env.sh shared --write >/dev/null 2>&1
[ -e "$t/h/.config/environment.d/10-mise.conf" ] || { echo "FAIL foreign environment.d removed"; fail=1; }
[ "$(scripts/lib/mise-env.sh shared)" = linux ] || { echo "FAIL print mode"; fail=1; }
grep -q -- '--user unset-environment MISE_ENV' "$t/systemctl.log" 2>/dev/null || { echo "FAIL --write did not unset the systemd MISE_ENV"; fail=1; }
grep -q 'MISE_ENV' dotfiles/zshenv.tera dotfiles/bashrc.tera && { echo "FAIL rc templates still mention MISE_ENV"; fail=1; }
[ -e dotfiles/config/environment.d/10-mise.conf.tera ] && { echo "FAIL environment.d template still present"; fail=1; }
grep -q '^miserc.toml$' .gitignore || { echo "FAIL miserc.toml not git-ignored"; fail=1; }
rm -rf "$t"
[ $fail -eq 0 ] && echo "miserc: PASS"
exit $fail
```
Run it. Expected now: several `FAIL` lines, because `--write` doesn't exist yet. The stub `systemctl` means the test never touches this host's real systemd user manager. Never run `--write` without it before the user's live run: until then, pueued depends on the exported value.

The test uses `env -u WSL_DISTRO_NAME` and an explicit `WSL_DISTRO_NAME=Alma` to steer `is_wsl()`. On this WSL host `/proc/version` also says `microsoft`, so only the explicit-WSL case is asserted, and the native token set is covered by reading the code.

- [ ] **Step 2: New `scripts/lib/mise-env.sh`**

```bash
#!/usr/bin/env bash
# mise-env.sh <owned|shared> [--write] — the MISE_ENV token set for THIS Linux host.
#   shared → linux
#   owned  → linux,owned,host,wsl (WSL guest) | linux,owned,host,native (bare metal / VM)
# --write also saves it to ~/.config/mise/miserc.toml (git-ignored). Every mise
# process reads that file — shells, shims under systemd, cron — so nothing
# exports MISE_ENV. An exported MISE_ENV still wins over miserc (CI and
# check-templates.sh set one to pick a token set explicitly).
set -euo pipefail
mode="${1:?usage: mise-env.sh <owned|shared> [--write]}"
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
case "$mode" in
owned) if is_wsl; then tokens="linux,owned,host,wsl"; else tokens="linux,owned,host,native"; fi ;;
shared) tokens="linux" ;;
*)
  printf 'mise-env.sh: unknown mode %q (owned|shared)\n' "$mode" >&2
  exit 2
  ;;
esac

if [ "${2:-}" = --write ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '# Written by scripts/lib/mise-env.sh from vars.mode in config.local.toml.\nenv = ["%s"]\nauto_env = false\n' \
    "${tokens//,/\", \"}" >"$cfg/mise/miserc.toml.tmp"
  mv "$cfg/mise/miserc.toml.tmp" "$cfg/mise/miserc.toml"
  # One-time cleanup of the old exported MISE_ENV (an export would override
  # miserc). Remove once every host has run it.
  envd="$cfg/environment.d/10-mise.conf"
  if [ -f "$envd" ] && ! grep -qvE '^(#.*|MISE_ENV=[a-z,]*|)$' "$envd"; then
    rm -f "$envd"
  fi
  if systemctl --user show-environment 2>/dev/null | grep -q '^MISE_ENV='; then
    systemctl --user unset-environment MISE_ENV || true
  fi
fi
echo "$tokens"
```

- [ ] **Step 3: Callers stop exporting**

`bootstrap.sh`:
- In `main`, replace
  ```bash
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
  export MISE_ENV
  log "mise environment: MISE_ENV=$MISE_ENV"
  ```
  with
  ```bash
  TOKENS="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE" --write)"
  # miserc.toml is the source from here on; an inherited export would override it.
  unset MISE_ENV
  log "mise config set: $TOKENS (saved in $REPO_DIR/miserc.toml)"
  ```
- In `apply()`, delete the `systemctl --user show-environment … set-environment …` block and its comment. Change `log "mise install (tools) — MISE_ENV=$MISE_ENV"` to `log "mise install (tools) — $TOKENS"`, and update the banner comment above `apply()` so it doesn't mention carrying `MISE_ENV` onto systemd.

`tasks/update`, full content:
```bash
#!/usr/bin/env bash
#MISE description="git pull --ff-only, then mise install + mise bootstrap for this host's saved mode"
set -euo pipefail
root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

git -C "$root" pull --ff-only

# The config set comes from the saved mode, not the calling shell. Rewrite
# miserc.toml from it, then drop any exported MISE_ENV (it would override
# miserc and could make mise-install.sh's `mise prune` remove tools).
cfg="$root/config.local.toml"
mode=$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$1"; config_get "$2" mode' _ "$root/bootstrap.sh" "$cfg")
case "$mode" in
owned | shared) ;;
*)
  printf ' ✗ no valid mode in %s%s — run %s/bootstrap.sh (it asks) or set mode = "owned" or "shared" under [vars]\n' \
    "$cfg" "${mode:+ (found \"$mode\")}" "$root" >&2
  exit 1
  ;;
esac
tokens="$("$root/scripts/lib/mise-env.sh" "$mode" --write)"
unset MISE_ENV
printf '==> mode: %s — config set %s (miserc.toml)\n' "$mode" "$tokens"

"$root/scripts/lib/mise-install.sh"
mise bootstrap --yes
```
`scripts/lib/mise-install.sh`:
- delete the line `: "${MISE_ENV:?…}"`
- the final line becomes `printf '  ✓ mise tools installed\n'`
- the header's first line becomes `# mise-install.sh — install every tool this host's config set (miserc.toml) declares.`

- [ ] **Step 4: Templates, environment.d, health, hooks, checks**

- **Templates:** remove the `MISE_ENV` blocks from `dotfiles/zshenv.tera` and `dotfiles/bashrc.tera`, then `git rm -q dotfiles/config/environment.d/10-mise.conf.tera`, and edit `config.linux.toml` as listed under Files.
- **`tasks/health`:**
  - The `mode` section keeps the `mode` row. Below it, add:
    ```bash
    rc_tokens=$(sed -n 's/^env = \[\(.*\)\]$/\1/p' "$root/miserc.toml" 2>/dev/null | tr -d '" ')
    if [ -z "$canonical_env" ]; then
      row_skip "miserc" "no valid mode — nothing to compare"
    elif [ "$rc_tokens" = "$canonical_env" ]; then
      row_ok "miserc" "$root/miserc.toml selects $rc_tokens"
    else
      row_bad "miserc" "$root/miserc.toml has \"${rc_tokens:-<missing>}\", the saved mode needs \"$canonical_env\" — mise run update"
    fi
    # Mise reads miserc unless MISE_ENV is exported; these were the old exporters.
    legacy=""
    grep -qs 'export MISE_ENV=' "$HOME/.zshenv" "$HOME/.bashrc" && legacy="$legacy rc-files"
    [ -e "$HOME/.config/environment.d/10-mise.conf" ] && legacy="$legacy environment.d"
    systemctl --user show-environment 2>/dev/null | grep -q '^MISE_ENV=' && legacy="$legacy systemd-user-manager"
    if [ -z "$legacy" ]; then
      row_ok "MISE_ENV export" "nothing exports it (miserc.toml rules)"
    else
      row_warn "MISE_ENV export" "still exported by:$legacy — mise run update, then open a new shell"
    fi
    unset MISE_ENV
    ```
  - Delete the "MISE_ENV shell" row and the old `export MISE_ENV="$canonical_env"`. Delete the whole "MISE_ENV persisted" section (`_baked_mise_env` and the rc/live rows).
  - The header line shows `config=${rc_tokens:-unset}` instead of `MISE_ENV=${shell_env:-unset}`, and the description drops "MISE_ENV wiring".
- **`.claude/hooks/session-context.sh`:** where it derives owned/shared from `$MISE_ENV`, read the `env = [...]` line of `$root/miserc.toml` with the same `sed` as health. Keep its fail-open behaviour.
- **`.claude/hooks/parity-reminder.sh`:** remove the clause that pairs `zshenv.tera`/`bashrc.tera`/`10-mise.conf.tera` for `MISE_ENV`. Keep the `zshrc`↔`bashrc` pair. Run `bash .claude/hooks/test-hooks.sh`; it must pass. If it asserts the removed clause, update that assertion.
- **`scripts/check-invariants.sh`:** delete `_render_baked_mise_env`, `check_mise_env_three_way` and its call. Fix any count of `.tera` files that a comment or message states (10 now).
- **`scripts/check-templates.sh`:** remove `"~/.config/environment.d/10-mise.conf"` from the `select_checker` case pattern.
- `.gitignore`: add a `miserc.toml` line under the per-host overrides comment.

- [ ] **Step 5: Verify**

```bash
cd ~/.config/mise
bash .superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-miserc.sh     # miserc: PASS
rg -n 'MISE_ENV' dotfiles/ || echo "dotfiles: no MISE_ENV"                         # expect "dotfiles: no MISE_ENV"
rg -n 'export MISE_ENV' scripts/ tasks/ bootstrap.sh || echo "no exports left"       # expect "no exports left"
bash scripts/check-templates.sh                                                    # 10 templates, all 4 sets pass
mise tasks validate 2>&1 | grep -c WARN                                            # 0
bash -n tasks/update tasks/health bootstrap.sh scripts/lib/mise-env.sh
bash scripts/test-bootstrap-mode.sh && bash scripts/test-mise-install.sh
mise run health; echo "rc=$?"   # miserc row: `bad` until the user's live run writes miserc.toml — expected here; record it
```

- [ ] **Step 6: Docs**

- `CLAUDE.md`:
  - Rewrite "Mode and `MISE_ENV`". The mode is saved in `config.local.toml`. `scripts/lib/mise-env.sh <mode> --write` writes the git-ignored `miserc.toml` (`env = […]`, `auto_env = false`). Every mise process reads it; nothing exports `MISE_ENV`. An exported value overrides it, which is why `bootstrap.sh` and `tasks/update` unset it and CI and `check-templates.sh` can pin one.
  - Delete the three-template bullet and the pueued-via-user-manager bullet.
  - Layout: token sets are produced by `mise-env.sh` and persisted in `miserc.toml`.
- `README.md`:
  - The owned/shared section says where the token set is saved.
  - "pueue status fails": the shim reads `~/.config/mise/miserc.toml`, so the fix is `mise run update` (it rewrites miserc) and then restarting the unit.
- `docs/claude/verification.md`: the pueued recipe checks `miserc.toml` and `systemctl --user is-active dev.mise.pueued`.
- Memory: fix the `project-bootstrap-owned-shared.md` lines that describe rc files exporting `MISE_ENV`.

- [ ] **Step 7: Commit and push**

```bash
mise run lint
git add -A scripts tasks bootstrap.sh dotfiles config.linux.toml config.toml .gitignore .claude CLAUDE.md README.md docs/claude
git commit -q -m "refactor(mise-env): the token set lives in miserc.toml; nothing exports MISE_ENV

scripts/lib/mise-env.sh --write saves it (and cleans the old environment.d
file and systemd export once); the rc templates, environment.d template,
systemctl set-environment calls, the three-way check and health's baked-value
rows are gone.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q -u origin refactor/simplify-pins
```

---

### Task 2: The Nerd Font is a mise tool

**Files:**
- Modify: `config.owned.toml` (add the tool), `mise.owned.lock` (regenerated for that tool only)
- Rewrite: `tasks/fonts` (full content below). Delete: `scripts/lib/font.sh`.
- Modify: `config.toml` (delete `nerd_font_version` from `[vars]`), `tasks/check-updates` (drop the nerd-fonts row and its `#MISE env` entry)
- Modify: `scripts/check-invariants.sh` `check_version_pins`. The nerd-font block becomes a two-way check: the `github:ryanoasis/nerd-fonts` version in `config.owned.toml` equals `$Version` in `scripts/install-nerd-fonts.ps1`. Drop the `font.sh` SHA-arm check.
- Modify: `scripts/bump-versions.sh`:
  - add `github:ryanoasis/nerd-fonts` to `EXCLUDE`, with a comment that the Windows half is still in `install-nerd-fonts.ps1` until PR 4
  - drop `nerd_font_version` from `EXCLUDE_VARS`, `VARS_KEY` and the vars specs
- Modify: `scripts/gen-tool-memory.sh` (drop `nerd_font_version`); regenerate the TOOLS block if the sync hook doesn't
- Docs:
  - `CLAUDE.md`: the `[vars]` list, the font entry in the pins list
  - `README.md`: the "Tofu boxes" entry's last bullet becomes "the `github:ryanoasis/nerd-fonts` pin in `config.owned.toml` must match `$Version` in `scripts/install-nerd-fonts.ps1`"; also any "bumped by hand" list that names `nerd_font_version`
  - `docs/claude/verification.md` if it names `font.sh`

- [ ] **Step 1: Write the test first (it fails now)**

Save as `.superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-fonts.sh`:
```bash
#!/usr/bin/env bash
# tasks/fonts copies the six Mono TTFs from the mise tool dir; stubbed mise + fc-cache, scratch HOME.
set -uo pipefail
cd ~/.config/mise
t=$(mktemp -d); mkdir -p "$t/bin" "$t/font"
for s in Regular Italic Bold BoldItalic Medium MediumItalic ExtraBold Light; do : > "$t/font/JetBrainsMonoNerdFontMono-$s.ttf"; done
: > "$t/font/JetBrainsMonoNerdFont-Regular.ttf"
printf '#!/bin/sh\n[ "$1" = where ] && echo %s\n' "$t/font" > "$t/bin/mise"; chmod +x "$t/bin/mise"
printf '#!/bin/sh\necho fc-cache "$@"\n' > "$t/bin/fc-cache"; chmod +x "$t/bin/fc-cache"
HOME="$t/h" PATH="$t/bin:$PATH" bash tasks/fonts >/dev/null || { echo "FAIL tasks/fonts exited non-zero"; exit 1; }
n=$(ls "$t/h/.local/share/fonts/JetBrainsMonoNerdFontMono/" 2>/dev/null | wc -l)
[ "$n" = 6 ] || { echo "FAIL want 6 Mono TTFs, got $n"; exit 1; }
grep -q '"github:ryanoasis/nerd-fonts"' config.owned.toml || { echo "FAIL tool not declared"; exit 1; }
grep -q 'nerd_font_version' config.toml && { echo "FAIL vars pin still present"; exit 1; }
rm -rf "$t"; echo "fonts: PASS"
```
Run it; expected: FAIL.

- [ ] **Step 2: The tool, its lock entry, the task**

`config.owned.toml` `[tools]`, after `"npm:ccstatusline"`:
```toml
"github:ryanoasis/nerd-fonts" = { version = "3.5.1", asset_pattern = "JetBrainsMono.tar.xz" }   # JetBrainsMono Nerd Font: tasks/fonts (Linux) copies its TTFs; Windows still pins it in scripts/install-nerd-fonts.ps1 until PR 4
```
Lock just this tool for both platforms with the verified out-of-checkout form (the same form `scripts/bump-versions.sh` uses):
```bash
L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"
(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=linux,owned,host,native mise lock --global --platform linux-x64 github:ryanoasis/nerd-fonts)
(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=windows,owned mise lock --global --platform windows-x64 github:ryanoasis/nerd-fonts)
rm -rf "$L"
git diff --stat -- mise*.lock locks/      # only mise.owned.lock changes; no other tool's entry moves
grep -A12 'nerd-fonts' mise.owned.lock    # linux-x64 + windows-x64, checksum sha256:04d5e8f9…10cf
```
If any other tool's lock entry changes, stop and report BLOCKED.

New `tasks/fonts`:
```bash
#!/usr/bin/env bash
#MISE description="JetBrainsMono Nerd Font Mono into ~/.local/share/fonts from the mise font tool (non-WSL owned hosts; config.native.toml's final hook runs it)"
set -euo pipefail
src="$(mise where github:ryanoasis/nerd-fonts)"
dest="$HOME/.local/share/fonts/JetBrainsMonoNerdFontMono"
mkdir -p "$dest"
changed=0
for s in Regular Italic Bold BoldItalic Medium MediumItalic; do
  f="JetBrainsMonoNerdFontMono-$s.ttf"
  if ! cmp -s "$src/$f" "$dest/$f"; then
    install -m 0644 "$src/$f" "$dest/$f"
    changed=1
  fi
done
if [ "$changed" = 1 ]; then
  if command -v fc-cache >/dev/null 2>&1; then fc-cache -f "$dest" >/dev/null; else echo "  ! fc-cache not on PATH — install fontconfig for font discovery" >&2; fi
  echo "  installed JetBrainsMono Nerd Font Mono into $dest"
else
  echo "  JetBrainsMono Nerd Font Mono up to date"
fi
```
Then `git rm -q scripts/lib/font.sh` and make the remaining edits listed under Files.

- [ ] **Step 3: Verify**

```bash
bash .superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-fonts.sh   # fonts: PASS
mise run check-updates 2>&1 | tail -4                                            # no nerd-fonts [vars] row
mise run lint                                                                    # incl. two-way font pin check, bumper coverage, vars coverage, TOOLS block
```

- [ ] **Step 4: Docs and commit**

Make the doc edits listed under Files, then:
```bash
git add -A config.owned.toml config.toml mise.owned.lock tasks scripts dotfiles/claude/CLAUDE.md CLAUDE.md README.md docs/claude
git commit -q -m "refactor(fonts): the Nerd Font is a mise github: tool; font.sh and vars.nerd_font_version removed

mise.owned.lock carries the checksum for linux-x64 and windows-x64;
tasks/fonts copies the six Mono TTFs from mise where. Windows keeps its
own pin until PR 4 (two-way check + bumper EXCLUDE).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q
```

---

### Task 3: python-env uses mise's Python; one library list

**Files:**
- Create: `scripts/python-env.txt`
- Modify: `scripts/lib/python-env.sh`:
  - its argument becomes the interpreter path
  - read the libraries from `scripts/python-env.txt`
  - drop `uv python install`
- Rewrite: `tasks/python-env` (full content below)
- Modify:
  - `config.toml`: delete `python_version` from `[vars]`; keep `tools.python` and fix its comment
  - `tasks/health`: the python-env row compares `wpy`'s version with `mise current python`, and `#MISE env` loses `PYTHON_VERSION`
  - `tasks/check-updates`: drop the python row and its env entry; only vcpkg is left among the `[vars]` rows
- Modify: `scripts/check-invariants.sh`:
  - `check_version_pins` python becomes two-way: `tools.python` equals `$PythonEnvVersion` in `bootstrap.ps1`
  - `check_python_env_parity` compares `scripts/python-env.txt` with `$PythonLibs`
  - `check_bumper_exclude` and `check_vars_pin_coverage` keep working with only `vcpkg_version` and `zjstatus_zellij_floor` in `[vars]`
- Modify: `scripts/bump-versions.sh`:
  - `EXCLUDE_VARS` is now empty, so delete it and the `case` that reads it
  - drop python from `VARS_KEY` and the vars specs
  - keep `python` in `EXCLUDE` (its wheel-coverage reason still stands)
  - fix the stale comment near the vars layer that says "check-updates spec name -> its config.toml [vars] key" (deferred from PR 2)
- Modify: `scripts/gen-tool-memory.sh` (drop `python_version`)
- Docs:
  - `CLAUDE.md`: the `[vars]` list, the python entry in the pins list, the `PY_LIBS` parity pair → `scripts/python-env.txt` ↔ `$PythonLibs`
  - `README.md`: the python-env mentions; "bumped by hand" lists naming `python_version`
  - `docs/claude/verification.md`: python-env recipe. Also re-wrap the over-long health line deferred from PR 2.

- [ ] **Step 1: Write the test first (it fails now)**

Save as `.superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-python.sh`:
```bash
#!/usr/bin/env bash
# python-env: builds from mise's python, libs from python-env.txt, and an interpreter change forces a rebuild.
set -uo pipefail
cd ~/.config/mise
t=$(mktemp -d); mkdir -p "$t/bin" "$t/py1/bin" "$t/py2/bin"
printf '#!/bin/sh\necho "uv $*" >> %s/uv.log\n' "$t" > "$t/bin/uv"; chmod +x "$t/bin/uv"
printf '#!/bin/sh\n[ "$1" = where ] && echo %s\n' "$t/py1" > "$t/bin/mise"; chmod +x "$t/bin/mise"
run() { HOME="$t/h" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" bash tasks/python-env; }
run >/dev/null; run | grep -q "up to date" || { echo "FAIL second run not up to date"; exit 1; }
grep -q "uv venv --python $t/py1/bin/python3" "$t/uv.log" || { echo "FAIL venv not built from mise python"; exit 1; }
grep -q 'uv python install' "$t/uv.log" && { echo "FAIL still runs uv python install"; exit 1; }
grep -q 'duckdb' "$t/uv.log" || { echo "FAIL libs not read from python-env.txt"; exit 1; }
printf '#!/bin/sh\n[ "$1" = where ] && echo %s\n' "$t/py2" > "$t/bin/mise"
run | grep -q "up to date" && { echo "FAIL interpreter change did not rebuild"; exit 1; }
grep -q 'python_version' config.toml && { echo "FAIL vars.python_version still present"; exit 1; }
rm -rf "$t"; echo "python-env: PASS"
```
Run it; expected: FAIL.

- [ ] **Step 2: Code**

`scripts/python-env.txt`:
```
# Libraries in the blessed python-env (latest at build time). Read by
# scripts/lib/python-env.sh; bootstrap.ps1 reads it on Windows from PR 4.
textual
textual-dev
click
rich
httpx
pydantic
typer
polars
duckdb
```
`scripts/lib/python-env.sh`:
- Usage becomes `python-env.sh <python-interpreter>`, with `python="${1:?usage: python-env.sh <python-interpreter>}"`.
- Replace the inline `PY_LIBS=(…)` with:
  ```bash
  mapfile -t PY_LIBS < <(grep -vE '^[[:space:]]*(#|$)' "$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)/scripts/python-env.txt")
  ```
- Delete `uv python install "$version"`.
- `uv venv --python "$version" "$env_dir"` → `uv venv --python "$python" "$env_dir"`.
- Update the header comments. The final printf names `$python`.

New `tasks/python-env`:
```bash
#!/usr/bin/env bash
#MISE description="Blessed Python scripting env: a venv on mise's python + launchers wpy/textual/typer (--rebuild forces a rebuild)"
#USAGE flag "--rebuild" help="Rebuild the env even when it is up to date (also upgrades its libraries)"
set -euo pipefail
root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
mkdir -p "$state"
python="$(mise where python)/bin/python3"
stamp="$state/python-env.stamp"
want="$python $(cat "$root/scripts/lib/python-env.sh" "$root/scripts/python-env.txt" | cksum | cut -d' ' -f1)"
if [ "${usage_rebuild:-false}" != true ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -x "$HOME/.local/bin/wpy" ]; then
  echo "  python-env up to date ($python; mise run python-env --rebuild to rebuild)"
  exit 0
fi
"$root/scripts/lib/python-env.sh" "$python"
printf '%s\n' "$want" >"$stamp"
```
Then make the remaining edits listed under Files. Do not automate `uv python uninstall`: other `uv` tools on a host may use those interpreters. The PR description tells the user how to reclaim the space by hand.

- [ ] **Step 3: Verify**

```bash
bash .superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-python.sh   # python-env: PASS
mise run check-updates 2>&1 | tail -3      # [vars] section: vcpkg only
mise run lint                              # two-way python pin, parity vs python-env.txt, bumper/vars coverage, TOOLS block
```

- [ ] **Step 4: Docs and commit**

```bash
git add -A scripts tasks config.toml dotfiles/claude/CLAUDE.md CLAUDE.md README.md docs/claude
git commit -q -m "refactor(python-env): build on mise's python; libraries in scripts/python-env.txt; vars.python_version removed

The stamp key is the interpreter path, so a tools.python bump rebuilds the env.
uv no longer downloads a second CPython. bump-versions loses EXCLUDE_VARS.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q
```

---

### Task 4: zjstatus loads from mise's install dir

**Files:**
- Modify: `dotfiles/config/zellij/config.kdl`:
  - the tab-bar alias location becomes `file:~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm`
  - rewrite the comment above it: mise keeps `latest` pointing at the installed pin, zellij expands `~`, and the expanded path is the permission-cache key, stable across bumps
- Modify: `tasks/bootstrap`: replace the zjstatus copy step with a one-time cleanup, marked for removal once every host has run it:
  ```bash
  # The zjstatus plugin now loads straight from mise's install dir (config.kdl);
  # drop the copy older provisioning left in zellij's data dir.
  rm -f "$HOME/.local/share/zellij/plugins/zjstatus.wasm"
  ```
  Then renumber the steps and drop `root=` from `tasks/bootstrap` if nothing else uses it.
- Delete: `scripts/lib/zellij-plugin.sh`, `scripts/test-zellij-plugin.sh`
- Modify: `scripts/check-invariants.sh`:
  - delete `check_zellij_plugin_installer` and its call
  - in `check_zellij_config`, the tab-bar assertion requires exactly the new location string; update its PASS message and comment
- Modify: `tasks/health`: the zjstatus row checks that `$HOME/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm` exists, with the fix hint `mise install github:dj95/zjstatus`. Drop the plugin-dir lookup.
- Docs:
  - `README.md`: the "Zellij's top bar…" troubleshooting entry (the path, and that there's no copy step), and any layout-tree mention of `zellij-plugin.sh`
  - `CLAUDE.md`: the zellij bullet
  - `docs/claude/verification.md`: the zjstatus recipe → the headless load check below

- [ ] **Step 1: Write the test first (it fails now)**

Save as `.superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-zjstatus.sh`:
```bash
#!/usr/bin/env bash
# zellij loads zjstatus from mise's latest path, using the tracked config, in a throwaway background session.
set -uo pipefail
cd ~/.config/mise
grep -q 'file:~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm' dotfiles/config/zellij/config.kdl || { echo "FAIL config.kdl location"; exit 1; }
z=$(mktemp -d); cp -r dotfiles/config/zellij/. "$z/"
log=/tmp/zellij-$(id -u)/zellij-log/zellij.log; before=$(wc -l < "$log" 2>/dev/null || echo 0)
ZELLIJ_CONFIG_DIR="$z" timeout 20 zellij attach --create-background claude-pr3-zjs >/dev/null 2>&1
for _ in 1 2 3 4 5; do tail -n +$((before+1)) "$log" 2>/dev/null | grep -q "Loaded plugin '.*github-dj95-zjstatus/latest/zjstatus.wasm'" && break; timeout 2 tail -f /dev/null; done
ok=$(tail -n +$((before+1)) "$log" 2>/dev/null | grep -c "Loaded plugin '.*github-dj95-zjstatus/latest/zjstatus.wasm'")
zellij kill-session claude-pr3-zjs >/dev/null 2>&1; rm -rf "$z"
[ "$ok" -ge 1 ] || { echo "FAIL zjstatus did not load from the mise path"; exit 1; }
[ -e scripts/lib/zellij-plugin.sh ] && { echo "FAIL copy script still present"; exit 1; }
echo "zjstatus: PASS"
```
Run it; expected: `FAIL config.kdl location`.

- [ ] **Step 2: Make the edits listed under Files**

- [ ] **Step 3: Verify**

```bash
bash .superpowers/sdd/2026-10-01-simplify-pr3-pins/checks/claude-pr3-zjstatus.sh   # zjstatus: PASS
zellij list-sessions 2>/dev/null | grep -c claude-pr3-zjs                           # 0 (the session was killed)
bash scripts/check-templates.sh                                                     # config.kdl is a copy, but templates still pass
mise run lint                                                                       # check_zellij_config asserts the new location
```

- [ ] **Step 4: Commit**

```bash
git add -A dotfiles/config/zellij tasks scripts README.md CLAUDE.md docs/claude
git commit -q -m "refactor(zellij): load zjstatus from mise's install dir; the copy script and its test are gone

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q
```

---

### Task 5: Whole-branch verification, a live run, and the PR

- [ ] **Step 1: Branch checks**

```bash
cd ~/.config/mise
W=.superpowers/sdd/2026-10-01-simplify-pr3-pins/checks
mise run lint && bash scripts/check-templates.sh
mise tasks validate 2>&1 | grep -c WARN                       # 0
for t in miserc fonts python zjstatus; do bash $W/claude-pr3-$t.sh; done   # four PASS lines
grep -n '^\[vars\]' -A4 config.toml                           # only vcpkg_version, zjstatus_zellij_floor
wc -c CLAUDE.md docs/claude/*.md; wc -l README.md             # within limits
```

- [ ] **Step 2: Declarative plan vs main**

Run the same two-worktree comparison as PR 1 Task 7, step 2, for `linux`, `linux,owned,host,wsl` and `linux,owned,host,native`. Expected differences:
- the removed `~/.config/environment.d/10-mise.conf` dotfile entry, in every token set
- the new `github:ryanoasis/nerd-fonts` tool, in the two owned sets

Nothing else may differ. Record the diffs.

- [ ] **Step 3: Live run (the user runs it — sudo + new shell)**

Ask the user to run:
```
! mise run update
```
then, in a NEW terminal tab:
```
echo "MISE_ENV=${MISE_ENV:-unset}"; cat ~/.config/mise/miserc.toml; mise run health
zellij   # a new session: grant zjstatus's permission once if asked, check the top bar, exit
```
Expected:
- `update` writes `miserc.toml`, removes the old environment.d file, unsets the systemd variable, installs the font tool (7 MB), and rebuilds python-env once.
- The new tab prints `MISE_ENV=unset`.
- health shows `miserc` ✓ and `MISE_ENV export` ✓.
- The zellij bar renders.

- [ ] **Step 4: Open the PR**

```bash
gh pr create --base main --head refactor/simplify-pins \
  --title "Simplify (3/5): one place per value — miserc.toml, font + python via mise, zjstatus from mise" \
  --body "$(cat <<'EOF'
Third of five PRs from docs/superpowers/specs/2026-09-29-simplify-design.md.

- MISE_ENV: scripts/lib/mise-env.sh --write saves the token set to the git-ignored ~/.config/mise/miserc.toml; the rc templates, the environment.d template and the systemctl set-environment calls are gone (one-time cleanup of the old exports included)
- Nerd Font: a mise github: tool (checksum in mise.owned.lock); scripts/lib/font.sh and vars.nerd_font_version removed
- python-env: a venv on mise's python, libraries in scripts/python-env.txt; vars.python_version removed; uv no longer downloads a second CPython
- zjstatus: config.kdl loads it from mise's install dir; scripts/lib/zellij-plugin.sh and its test removed
- [vars] now holds only vcpkg_version and zjstatus_zellij_floor; Windows' font/python pins stay two-way-checked until PR 4

Verification: lint, check-templates, mise tasks validate, four focused tests (miserc writer + legacy cleanup, fonts copy, python-env rebuild-on-interpreter-change, zjstatus headless load), bootstrap plan diff vs main limited to the expected two changes, and a live update + health + zellij on the WSL owned host.

After merging, on each Linux host: `mise run update`, then open a new shell (an old shell still exports MISE_ENV until it exits). zellij asks once to re-grant zjstatus's permissions (new plugin path). Optional: `uv python uninstall 3.14.6 3.14.7` reclaims ~225 MB if no other uv tool uses them.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
EOF
)"
```
