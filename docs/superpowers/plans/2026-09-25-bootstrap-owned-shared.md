# Bootstrap owned/shared + cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `bootstrap.sh`'s required `--dev`/`--prod` flag with a prompted `owned`/`shared` mode, rename the dev/prod vocabulary through the repo, delete the chezmoi/Make migration code, and refactor both bootstrap scripts as single curl-able files.

**Architecture:** The mode lives in the git-ignored `config.local.toml` as `[vars] mode = "owned"|"shared"`; `bootstrap.sh` resolves it saved → `WORKSTATION_MODE` → `/dev/tty` prompt → fail, and maps it to `MISE_ENV` via `scripts/lib/mise-env.sh`. The `dev` MISE_ENV token becomes `owned` (so `config.dev.toml` → `config.owned.toml`, lockfiles regenerated). Windows is always `owned`. Both bootstraps stay one file each; `bootstrap.sh` gains a `main` guarded for tests.

**Tech Stack:** bash 5 (shellcheck, shfmt -i 2), PowerShell 5.1 + 7 (PSScriptAnalyzer, UTF-8 BOM), mise 2026.9.9 (`[dotfiles]` Tera templates, `mise bootstrap`, `mise lock`), jq, python3 tomllib (checks only), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-bootstrap-owned-shared-design.md`

## Global Constraints

- Repo: `~/.config/mise` (this checkout IS mise's global config dir). Branch: `feat/bootstrap-owned-shared`. Never commit to `main`; push after every commit.
- Mode names are exactly `owned` and `shared`. Stored key: `[vars] mode` in `config.local.toml`. Env var: `WORKSTATION_MODE`.
- MISE_ENV sets after the change: owned WSL `linux,owned,host,wsl`; owned native `linux,owned,host,native`; shared `linux`; Windows `windows,owned`.
- `bootstrap.sh` and `bootstrap.ps1` each remain ONE self-contained file (must work as `curl … | bash` and the `curl.exe` one-liner). No new sourced files.
- Remaining `bootstrap.sh` flags: `--reinstall`, `--yes`/`-y`, `--doctor`, `--check-for-updates` (alias `--checkforupdates`), `-h`/`--help`. No mode flags.
- `bootstrap.ps1` keeps its UTF-8 BOM and stays PowerShell 5.1-parseable; `Invoke-CurlRequest` stays byte-identical to `scripts/install-nerd-fonts.ps1`'s copy.
- Every `scripts/*.sh`, `scripts/lib/*.sh`, `tasks/*`, `.claude/hooks/*.sh`: LF-only, git mode 100755, `shfmt -i 2` clean, shellcheck clean at warning+.
- Never hand-edit `mise*.lock` or `locks/**`: regenerate with `mise lock --global` from OUTSIDE the checkout via the XDG symlink form, then normalize sidecar paths (see `scripts/bump-versions.sh` `mise_global` / `normalize_lock_sidecars`).
- Never run `mise dot apply` / `mise bootstrap` against the real `$HOME` from an agent, except the rollout task (Task 10), which the user has approved as part of the spec.
- Comments: short why-comments only; no incident narratives, fix-wave labels (I6, C1, Task 5, PR3), or dated verification stories.
- Verification gate for every task: `bash scripts/check-invariants.sh` ends with `✓ all invariant checks passed`.
- Commits: one per task (finer than the spec's three-commit grouping), all on the one branch and one PR.
- The first-apply `--force-dotfiles` marker file keeps its name `dotfiles-migrated`, but every log/comment describing it says "first dotfiles apply on this host" (not "migration").

---

## File map

| File | Change |
|---|---|
| `bootstrap.sh` | Tasks 1, 4, 6: migration code out; mode resolution + `main` guard; final shape |
| `bootstrap.ps1` | Tasks 2, 3, 5, 7: migration code out; token rename; `mode = "owned"`; final shape |
| `scripts/test-bootstrap-mode.sh` | Create (Task 4): mode-resolution tests |
| `scripts/test-config-local.ps1` | Create (Task 5): Windows config.local.toml writer test |
| `scripts/lib/mise-env.sh` | Tasks 3–4: emits `owned` token; takes `owned\|shared` |
| `config.dev.toml` → `config.owned.toml` | Task 3 (`git mv`) |
| `mise.dev.lock`, `locks/mise.dev/` → `mise.owned.lock`, `locks/mise.owned/` | Task 3 (regenerated) |
| `dotfiles/zshenv.tera`, `dotfiles/bashrc.tera`, `dotfiles/config/environment.d/10-mise.conf.tera`, `dotfiles/zshrc.tera` | Tasks 3–4: token + `vars.mode` |
| `dotfiles/config/zsh/completions/_bootstrap.sh`, `dotfiles/config/bash/completions.bash` | Task 4: drop `--dev`/`--prod` |
| `scripts/check-invariants.sh`, `scripts/check-templates.sh`, `scripts/bump-versions.sh`, `scripts/gen-tool-memory.sh`, `scripts/lib/mise-install.sh`, `scripts/setup-ccstatusline.sh`, `scripts/test-mise-install.sh`, `scripts/check-ps.ps1` | Tasks 1, 3, 4, 5 |
| `tasks/bootstrap`, `tasks/health`, `tasks/fonts`, `tasks/statusline`, `tasks/vcpkg`, `tasks/migrate-legacy` (delete) | Tasks 1, 3 |
| `.claude/hooks/session-context.sh`, `.claude/hooks/parity-reminder.sh`, `.claude/hooks/test-hooks.sh` | Task 3 |
| `.github/workflows/lint.yml` | Task 5 (new Windows test step) |
| `README.html`, `docs/README/README.css`, `docs/README/README.js`, `CLAUDE.md`, `docs/claude/*.md`, `CLAUDE_CHANGELOG.md`, `dotfiles/claude/CLAUDE.md`, `dotfiles/claude/skills/workstation-lsp/SKILL.md`, cheat sheet, `.claude/memory/*` | Task 8 |

---

### Task 1: Delete migration code — Linux side

**Files:**
- Modify: `bootstrap.sh`
- Delete: `tasks/migrate-legacy`
- Modify: `tasks/bootstrap` (line 34: the `"$root/tasks/migrate-legacy"` call), `tasks/health` (the `legacy sweep` row, ~line 289), `scripts/test-mise-install.sh` (cases 4, 6, 7, 8 and the migrate-legacy parts of the header/PASS line), `scripts/check-invariants.sh` (~line 1246 `hdr` text naming migrate-legacy)

**Interfaces:**
- Consumes: nothing new.
- Produces: `bootstrap.sh` with no `LEGACY_REPO_DIR`, `relocate_repo`, `repair_config_local_group`, chezmoi.toml import, pueued-retirement, `--full` case, or "replace this shell … swept" message. `ensure_config_local` still writes `group = "$GROUP_NAME"` for a NEW file (Task 4 replaces it); an existing file is left untouched.

- [ ] **Step 1: Write the failing guard (grep test)**

Run:
```bash
cd ~/.config/mise
git grep -n -E 'LEGACY_REPO_DIR|relocate_repo|repair_config_local_group|chezmoi|pueued\.service|--full\)|legacy sweep just removed' -- bootstrap.sh
test ! -e tasks/migrate-legacy && ! git grep -q migrate-legacy -- tasks scripts
```
Expected: FAIL (matches printed; second line exits non-zero).

- [ ] **Step 2: Remove the Linux migration code**

In `bootstrap.sh`:
- Delete the `LEGACY_REPO_DIR=` constant and the `relocate_repo` function + its call.
- In `do_reinstall`: delete the `LEGACY_REPO_DIR` and `~/.config/chezmoi` listing/removal blocks; the in-repo guard compares only against `$REPO_DIR`:
  ```bash
  if [[ "$script_real" == "$REPO_DIR"* ]]; then
  ```
- In `require_repo`: delete the `LEGACY_REPO_DIR` fallback branch (keep the "No workstation repo" fail).
- Delete `repair_config_local_group` entirely. In `ensure_config_local`: delete the tomllib python probe, the `repair_config_local_group` call, and the whole `legacy_toml` / chezmoi.toml parsing block; when the file exists just `ok "config.local.toml already present ($target)"; return 0`.
- In `run_bootstrap`: delete the `pueued.service` retirement block.
- Delete the `--full)` case in argument parsing.
- Delete the four `echo -e` lines starting `Replace this shell now:` … `every keystroke until it is replaced.` at the end.
- In `do_doctor`'s prerequisite loop, drop `ip`: `for cmd in curl git tar; do`.

- [ ] **Step 3: Remove `tasks/migrate-legacy` and its consumers**

```bash
git rm -q tasks/migrate-legacy
```
- `tasks/bootstrap`: delete the line `"$root/tasks/migrate-legacy"` (and a comment directly describing it).
- `tasks/health`: delete the `if [ -f "$state/legacy-tools-swept" ] …` block (the "legacy sweep" row) including its `else`/`fi`.
- `scripts/test-mise-install.sh`: delete cases 4, 6, 7, 8 (every block that runs `tasks/migrate-legacy`) and their header comment lines; rewrite the final PASS message to describe only what remains, e.g. `PASS: mise-install.sh installs/forces-node-once-on-change; verify-tools fails loudly on a broken mise bin-paths; an unreadable tools.node declaration forces the reinstall and writes NO marker` (keep every assertion that does not involve migrate-legacy).
- `scripts/check-invariants.sh`: in the `hdr` of the mise-install lib check, drop `tasks/migrate-legacy, ` from the title.

- [ ] **Step 4: Run the guard and the checks**

Run:
```bash
git grep -n -E 'LEGACY_REPO_DIR|relocate_repo|repair_config_local_group|chezmoi|pueued\.service|--full\)|legacy sweep just removed' -- bootstrap.sh; echo "grep exit=$?"
test ! -e tasks/migrate-legacy && ! git grep -q migrate-legacy -- tasks scripts && echo GONE
bash -n bootstrap.sh && shellcheck -S warning bootstrap.sh tasks/bootstrap tasks/health scripts/test-mise-install.sh && shfmt -i 2 -d bootstrap.sh tasks/bootstrap tasks/health scripts/test-mise-install.sh && echo LINT-OK
bash scripts/test-mise-install.sh
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: `grep exit=1`, `GONE`, `LINT-OK`, a `PASS:` line, `✓ all invariant checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A bootstrap.sh tasks scripts
git commit -m "refactor(bootstrap)!: drop the chezmoi/Make migration code (Linux)

Every host is either migrated (WSL) or will be set up fresh, so the
one-time migration paths go: checkout relocation from
~/.local/share/chezmoi, the chezmoi.toml identity import, the vars.group
repair, the legacy pueued.service retirement, the --full rejection, and
tasks/migrate-legacy with its health row and tests."
git push -q
```

---

### Task 2: Delete migration code — Windows side

**Files:**
- Modify: `bootstrap.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `bootstrap.ps1` without `Get-LegacyChezmoiIdentity`, `Test-ConfigLocalHasGroup`, `Repair-ConfigLocalGroup`, the chezmoi relocation in `Invoke-CloneRepo`, the chezmoi-state handling in `Invoke-Reinstall`, the portable-uv sweep, `Remove-RetiredTerminalHostProfiles` (+ its call). `Invoke-EnsureConfigLocal` keeps writing `group = "dev_machine"` for a NEW file (Task 5 replaces it); an existing file is left untouched.

- [ ] **Step 1: Write the failing guard**

```bash
cd ~/.config/mise
grep -n -E 'Get-LegacyChezmoiIdentity|Test-ConfigLocalHasGroup|Repair-ConfigLocalGroup|Remove-RetiredTerminalHostProfiles|\.local\\share\\chezmoi|\.config\\chezmoi|legacyUv' bootstrap.ps1
```
Expected: matches printed (FAIL).

- [ ] **Step 2: Remove the Windows migration code**

Edit `bootstrap.ps1` with a BOM-preserving method (python: read bytes, assert `b[:3] == b"\xef\xbb\xbf"`, decode `utf-8-sig`, edit, write `b"\xef\xbb\xbf" + s.encode("utf-8")`):
- Delete functions `Get-LegacyChezmoiIdentity`, `Test-ConfigLocalHasGroup`, `Repair-ConfigLocalGroup`.
- `Invoke-EnsureConfigLocal`: if the file exists → `Write-Ok "config.local.toml already present ($target)"; return`. Delete the `$legacyToml`/`$identity` block and the `Migrating name/email/group` log; `$group = "dev_machine"` stays as a plain assignment for the new-file path.
- `Invoke-CloneRepo`: delete everything from `$legacyRepo = Join-Path $env:USERPROFILE ".local\share\chezmoi"` through the relocation `Set-Location -LiteralPath $RepoPath` + closing `}`.
- `Invoke-Reinstall`: delete `$chezmoiCfg` and both blocks that list/remove it.
- `Invoke-MiseRuntimes`: delete the `$legacyUv` sweep (the `Test-Path $legacyUv` block and `Remove-FromUserPath $legacyUv`).
- Delete function `Remove-RetiredTerminalHostProfiles`, its `5c.` header-comment line pair, and its call in the run sequence.

- [ ] **Step 3: Verify**

```bash
grep -n -E 'Get-LegacyChezmoiIdentity|Test-ConfigLocalHasGroup|Repair-ConfigLocalGroup|Remove-RetiredTerminalHostProfiles|\.local\\share\\chezmoi|\.config\\chezmoi|legacyUv' bootstrap.ps1; echo "grep exit=$?"
head -c3 bootstrap.ps1 | od -An -tx1
W=$(wslpath -w ~/.config/mise/bootstrap.ps1); (cd /mnt/c && powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$W',[ref]\$null,[ref]\$e); 'parse errors: ' + \$e.Count" | tr -d '\r')
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: `grep exit=1`, ` ef bb bf`, `parse errors: 0`, `✓ all invariant checks passed`.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.ps1
git commit -m "refactor(bootstrap.ps1)!: drop the chezmoi migration code (Windows)

The Windows host is migrated: remove the chezmoi.toml identity import,
the vars.group repair, the ~\\.local\\share\\chezmoi relocation, the
chezmoi-state sweep in -Reinstall, the portable-uv sweep and
Remove-RetiredTerminalHostProfiles."
git push -q
```

---

### Task 3: Rename the `dev` token → `owned` (config file, locks, every consumer)

**Files:**
- Rename: `config.dev.toml` → `config.owned.toml`
- Regenerate: `mise.dev.lock` → `mise.owned.lock`, `locks/mise.dev/` → `locks/mise.owned/`
- Modify: `scripts/lib/mise-env.sh`, the 3 MISE_ENV templates + `dotfiles/zshrc.tera`/`dotfiles/bashrc.tera` dev-gate blocks (token only; still keyed on `vars.group` until Task 4), `scripts/check-invariants.sh`, `scripts/check-templates.sh`, `scripts/bump-versions.sh`, `scripts/gen-tool-memory.sh`, `scripts/lib/mise-install.sh`, `scripts/setup-ccstatusline.sh`, `scripts/test-mise-install.sh`, `tasks/bootstrap`, `tasks/health`, `tasks/fonts`, `tasks/statusline`, `tasks/vcpkg`, `.claude/hooks/session-context.sh`, `.claude/hooks/parity-reminder.sh`, `.claude/hooks/test-hooks.sh`, `bootstrap.ps1`, `dotfiles/claude/CLAUDE.md` (regenerated TOOLS block), comment references in `config*.toml`, `dotfiles/gdbinit.tera`, `dotfiles/config/gdb/.vendor`, `dotfiles/config/zellij/layouts/ops.kdl`, `dotfiles/claude/skills/workstation-lsp/SKILL.md`.

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `scripts/lib/mise-env.sh dev` prints `linux,owned,host,wsl|native` (the argument names change in Task 4). Token `owned` everywhere `dev` was a MISE_ENV token. `env_has owned` in tasks. `$MiseEnv = "windows,owned"` in `bootstrap.ps1`.

- [ ] **Step 1: Capture the pre-change baseline (the "failing test" is the diff in Step 6)**

```bash
cd ~/.config/mise
B=/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/baseline; rm -rf $B; mkdir -p $B
git worktree add -q --detach $B/tree origin/main
snap() { # snap <tree> <MISE_ENV> <out-prefix>
  local L; L=$(mktemp -d); ln -s "$1" "$L/mise"
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV="$2" mise bootstrap plan --json 2>/dev/null | jq -r '.resources[] | "\(.id.kind) \(.id.name)"' | sort) >"$3.plan"
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV="$2" mise ls --current --json 2>/dev/null | jq -r 'to_entries[] | "\(.key) \([.value[] | .requested_version // .version] | unique | join(","))"' | sort) >"$3.tools"
  rm -rf "$L"
}
snap $B/tree linux,dev,host,wsl $B/old-owned-wsl
snap $B/tree linux,dev,host,native $B/old-owned-native
snap $B/tree linux $B/old-shared
snap $B/tree windows,dev $B/old-windows
wc -l $B/*.plan $B/*.tools
```
Expected: non-empty `.plan` and `.tools` files (≈60+ plan lines for owned-wsl, ≈100 tool lines).

- [ ] **Step 2: Rename the config file and the token**

```bash
git mv config.dev.toml config.owned.toml
```
Then replace the MISE_ENV **token** (not the English word "dev" in prose, not `dev.kdl`, not `pueued` unit names like `dev.mise.pueued.service`, which mise generates):
- `scripts/lib/mise-env.sh`: `echo "linux,owned,host,wsl"` / `echo "linux,owned,host,native"`.
- Templates (`dotfiles/zshenv.tera`, `dotfiles/bashrc.tera`, `dotfiles/config/environment.d/10-mise.conf.tera`): `linux,dev,host,` → `linux,owned,host,` (keep the `vars.group == "dev_machine"` condition for now).
- `tasks/bootstrap`, `tasks/health`, `tasks/fonts`, `tasks/statusline`, `tasks/vcpkg`: `env_has dev` → `env_has owned`; `tasks/health` `mode="prod"`/`mode="dev"` → `mode="shared"`/`mode="owned"`; `tasks/statusline` message → `statusline is an owned-host target — skipping (MISE_ENV=${MISE_ENV:-unset})`.
- `.claude/hooks/session-context.sh`: `*,dev,*) group="dev_machine"` → `*,owned,*) group="owned"`, `*) group="prod_machine"` → `*) group="shared"`; rename the variable/label it prints from group to mode.
- `.claude/hooks/parity-reminder.sh`: `*/config.dev.toml` → `*/config.owned.toml`; message `(config.dev.toml)` → `(config.owned.toml)`.
- `.claude/hooks/test-hooks.sh`: every `config.dev.toml` → `config.owned.toml` (lines 78–79, 147).
- `scripts/check-invariants.sh`: every `config.dev.toml` → `config.owned.toml`, `mise.dev.lock` → `mise.owned.lock`, `"config.dev.toml": "mise.dev.lock"` → `"config.owned.toml": "mise.owned.lock"`, `MISE_ENV=linux,dev,host,native` → `MISE_ENV=linux,owned,host,native`, `MISE_ENV=windows,dev` → `MISE_ENV=windows,owned`; `print("PASS|prod-safety|config.toml and config.dev.toml carry no [bootstrap] table")` → `print("PASS|shared-safety|config.toml and config.owned.toml carry no [bootstrap] table")` (and the matching FAIL label if present).
- `scripts/check-templates.sh`: `FILES = [... "config.owned.toml" ...]`; `ENVS=("linux" "linux,owned,host,wsl" "linux,owned,host,native" "windows,owned")`.
- `scripts/bump-versions.sh`: `mise.dev.lock` → `mise.owned.lock`; `linux,dev,host,native` → `linux,owned,host,native` (3 places); `windows,dev` → `windows,owned`; `config.dev.toml` → `config.owned.toml` (5 places).
- `scripts/gen-tool-memory.sh`: `("Dev tools (config.dev.toml)", "config.dev.toml")` → `("Owned-host tools (config.owned.toml)", "config.owned.toml")`.
- `scripts/lib/mise-install.sh`, `scripts/setup-ccstatusline.sh`: `config.dev.toml` → `config.owned.toml`.
- `scripts/test-mise-install.sh`: `MISE_ENV=linux,dev,host,wsl` → `MISE_ENV=linux,owned,host,wsl`.
- `bootstrap.ps1` (BOM-preserving edit): `$MiseConfigFiles = @("config.toml", "config.owned.toml", "config.windows.toml")`, `$MiseEnv = "windows,owned"`, both `Join-Path $RepoPath "config.dev.toml"` → `"config.owned.toml"`, the three `UpdateHint` strings `config.dev.toml` → `config.owned.toml`.
- Comments naming `config.dev.toml` or the `dev` token in `config.toml`, `config.linux.toml`, `config.host.toml`, `config.owned.toml`, `config.windows.toml`, `dotfiles/gdbinit.tera`, `dotfiles/config/gdb/.vendor`, `dotfiles/config/zellij/layouts/ops.kdl`, `dotfiles/claude/skills/workstation-lsp/SKILL.md`: update to `config.owned.toml` / `owned`.

- [ ] **Step 3: Regenerate the lockfiles under the new name**

```bash
cd ~/.config/mise
L=$(mktemp -d); ln -s "$PWD" "$L/mise"
(cd /tmp && env -u MISE_CONFIG_DIR GITHUB_TOKEN="$(gh auth token)" XDG_CONFIG_HOME="$L" MISE_ENV=linux,owned,host,native mise lock --global --platform linux-x64)
(cd /tmp && env -u MISE_CONFIG_DIR GITHUB_TOKEN="$(gh auth token)" XDG_CONFIG_HOME="$L" MISE_ENV=windows,owned mise lock --global --platform windows-x64)
rm -rf "$L"
if [ -d .mise/locks ]; then mkdir -p locks && cp -a .mise/locks/. locks/ && rm -rf .mise; fi
sed -i 's#path = "\.mise/locks/#path = "locks/#g' mise.lock mise.linux.lock mise.owned.lock
git rm -rq mise.dev.lock locks/mise.dev
git add -A mise.owned.lock locks/mise.owned mise.lock mise.linux.lock
bash scripts/gen-tool-memory.sh >/dev/null
```
Expected: `mise.owned.lock` exists; `locks/mise.owned/{npm-ccstatusline,pypi-basedpyright}/…` exist; `git status` shows `mise.dev.lock` and `locks/mise.dev/` deleted.

- [ ] **Step 4: Completeness guard**

```bash
git grep -n -E 'config\.dev\.toml|mise\.dev\.lock|locks/mise\.dev|(linux|windows),dev\b|,dev,|env_has dev' -- . ':!docs/superpowers' ':!CLAUDE_CHANGELOG.md' ':!README.html' ':!CLAUDE.md' ':!docs/claude' ':!.claude/memory'
```
Expected: no output (docs are Task 8).

- [ ] **Step 5: Snapshot the renamed tree**

```bash
B=/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/baseline
snap() { local L; L=$(mktemp -d); ln -s "$1" "$L/mise"
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV="$2" mise bootstrap plan --json 2>/dev/null | jq -r '.resources[] | "\(.id.kind) \(.id.name)"' | sort) >"$3.plan"
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV="$2" mise ls --current --json 2>/dev/null | jq -r 'to_entries[] | "\(.key) \([.value[] | .requested_version // .version] | unique | join(","))"' | sort) >"$3.tools"
  rm -rf "$L"; }
snap ~/.config/mise linux,owned,host,wsl $B/new-owned-wsl
snap ~/.config/mise linux,owned,host,native $B/new-owned-native
snap ~/.config/mise linux $B/new-shared
snap ~/.config/mise windows,owned $B/new-windows
```

- [ ] **Step 6: Equivalence check**

```bash
for p in owned-wsl owned-native shared windows; do for k in plan tools; do diff -q $B/old-$p.$k $B/new-$p.$k >/dev/null && echo "$p.$k SAME" || { echo "$p.$k DIFF"; diff $B/old-$p.$k $B/new-$p.$k | head; }; done; done
```
Expected: all eight lines `SAME`, except that the plan may differ ONLY where the old baseline listed a resource that Task 1 deleted (none expected: migrate-legacy is a task, not a plan resource). Any other difference is a bug — fix before continuing.

- [ ] **Step 7: Checks**

```bash
bash scripts/check-invariants.sh 2>&1 | tail -1
bash scripts/check-templates.sh 2>&1 | tail -1
bash scripts/test-mise-install.sh
bash .claude/hooks/test-hooks.sh 2>&1 | tail -1
```
Expected: `✓ all invariant checks passed`; `all rendered templates pass, across all four MISE_ENV sets`; `PASS:`; hook tests pass except the known pre-existing `reason=clear -> silent` timing flake (1 failure max, that one only).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor!: rename the dev MISE_ENV token to owned

config.dev.toml -> config.owned.toml, mise.dev.lock -> mise.owned.lock
(regenerated with mise lock --global), locks/mise.dev -> locks/mise.owned,
and every consumer: mise-env.sh, templates, tasks (env_has owned),
check-invariants, check-templates, bump-versions, gen-tool-memory, hooks,
bootstrap.ps1 (MISE_ENV=windows,owned). mise bootstrap plan and the
resolved tool set are identical to the old token sets for owned WSL,
owned native, shared and Windows."
git push -q
```

---

### Task 4: `owned`/`shared` mode in bootstrap.sh (prompt, env var, saved), templates on `vars.mode`

**Files:**
- Create: `scripts/test-bootstrap-mode.sh`
- Modify: `bootstrap.sh`, `scripts/lib/mise-env.sh`, `dotfiles/zshenv.tera`, `dotfiles/bashrc.tera`, `dotfiles/zshrc.tera`, `dotfiles/config/environment.d/10-mise.conf.tera`, `scripts/check-invariants.sh` (render check + wire new test), `dotfiles/config/zsh/completions/_bootstrap.sh`, `dotfiles/config/bash/completions.bash`

**Interfaces:**
- Consumes: `scripts/lib/mise-env.sh` (Task 3 output tokens).
- Produces (all in `bootstrap.sh`, used by Task 6 and the test):
  - `config_get <file> <key>` → prints the `[vars]` value or nothing.
  - `config_set <file> <key> <value>` → sets/creates `key = "value"` under `[vars]`, preserving other tables; escapes `\` and `"`.
  - `valid_mode <mode>` → exit 0 for `owned`/`shared`.
  - `open_prompt_fd` → exit 0 if fd 3 is readable (already open, or opened on `/dev/tty`).
  - `prompt_mode` → prints `owned` or `shared` (reads fd 3; prompts on stderr).
  - `resolve_host_config` → sets global `MODE`; writes `mode` (always) and `name`/`email` (when obtained) to `$REPO_DIR/config.local.toml`.
  - `main "$@"` — runs the whole bootstrap; the file ends with `[[ "${WORKSTATION_BOOTSTRAP_LIB:-}" == 1 ]] || main "$@"`.
  - `fail` writes to stderr.
  - `scripts/lib/mise-env.sh <owned|shared>`.
  - Templates key on `vars.mode is defined and vars.mode == "owned"`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-bootstrap-mode.sh` (mode 100755, LF):
```bash
#!/usr/bin/env bash
# Offline tests for bootstrap.sh's mode resolution: saved mode, WORKSTATION_MODE,
# the prompt (fd 3), and the no-terminal failure. Sources bootstrap.sh with
# WORKSTATION_BOOTSTRAP_LIB=1 so main does not run.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

# run <case-dir> <stdin-for-fd3|-> [VAR=value ...] — resolve_host_config in a
# fresh shell with REPO_DIR=<case-dir>; prints MODE on success. "-" means no
# fd 3 is supplied (and setsid removes the controlling terminal).
run() {
  local dir=$1 input=$2
  shift 2
  if [ "$input" = - ]; then
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; echo "MODE=$MODE"' "$root/bootstrap.sh" </dev/null 2>&1
  else
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; echo "MODE=$MODE"' "$root/bootstrap.sh" 3<<<"$input" </dev/null 2>&1
  fi
}

# 1. A saved mode wins over WORKSTATION_MODE.
mkdir -p "$T/c1"
printf '[vars]\nname = "N"\nemail = "e@x"\nmode = "shared"\n' >"$T/c1/config.local.toml"
out=$(run "$T/c1" - WORKSTATION_MODE=owned) || fail "saved mode: exit $? — $out"
grep -q '^MODE=shared$' <<<"$out" || fail "saved mode did not win: $out"

# 2. WORKSTATION_MODE is used and saved (name/email from fd 3).
mkdir -p "$T/c2"
out=$(run "$T/c2" $'Ann\nann@x' WORKSTATION_MODE=owned) || fail "env mode: exit — $out"
grep -q '^MODE=owned$' <<<"$out" || fail "env mode not used: $out"
grep -q '^mode = "owned"$' "$T/c2/config.local.toml" || fail "env mode not saved"
grep -q '^name = "Ann"$' "$T/c2/config.local.toml" || fail "name not saved"

# 3. An invalid WORKSTATION_MODE is rejected.
mkdir -p "$T/c3"
if out=$(run "$T/c3" - WORKSTATION_MODE=prod); then fail "invalid env accepted: $out"; fi
grep -q 'expected owned or shared' <<<"$out" || fail "invalid env message: $out"

# 4. No saved mode, no variable, no terminal -> fails with both ways to answer.
mkdir -p "$T/c4"
if out=$(run "$T/c4" -); then fail "no-terminal case succeeded: $out"; fi
grep -q 'No terminal to ask the setup mode on' <<<"$out" || fail "no-terminal message: $out"
grep -q 'WORKSTATION_MODE=shared' <<<"$out" || fail "no-terminal hint: $out"

# 5. A prompt answer is saved; an invalid answer re-asks.
mkdir -p "$T/c5"
out=$(run "$T/c5" $'x\n2\nBea\nbea@x') || fail "prompt: exit — $out"
grep -q '^MODE=shared$' <<<"$out" || fail "prompt answer not used: $out"
grep -q 'Please answer 1 or 2' <<<"$out" || fail "invalid answer not re-asked: $out"
grep -q '^mode = "shared"$' "$T/c5/config.local.toml" || fail "prompt answer not saved"

# 6. config_set keeps other tables and escapes quotes; config_get reads back.
mkdir -p "$T/c6"
printf '[vars]\nname = "Old"\n\n[dotfiles]\n"~/.x" = { source = "x", mode = "copy", enabled = false }\n' >"$T/c6/config.local.toml"
WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_set "$1" name "Q \"q\""; config_set "$1" mode owned; config_get "$1" name' \
  "$root/bootstrap.sh" "$T/c6/config.local.toml" >"$T/c6/got" || fail "config_set/get failed"
grep -q '^\[dotfiles\]$' "$T/c6/config.local.toml" || fail "config_set dropped [dotfiles]"
grep -q '^mode = "owned"$' "$T/c6/config.local.toml" || fail "config_set did not add mode"
[ "$(grep -c '^name = ' "$T/c6/config.local.toml")" = 1 ] || fail "config_set duplicated name"
grep -qF 'name = "Q \"q\""' "$T/c6/config.local.toml" || fail "config_set did not escape quotes"

# 7. No terminal but WORKSTATION_MODE set and no identity: mode saved, warning only.
mkdir -p "$T/c7"
out=$(run "$T/c7" - WORKSTATION_MODE=shared) || fail "unattended shared failed: $out"
grep -q '^mode = "shared"$' "$T/c7/config.local.toml" || fail "unattended mode not saved"
grep -q 'name/email' <<<"$out" || fail "missing identity warning: $out"

echo "PASS: bootstrap.sh mode resolution (saved, WORKSTATION_MODE, prompt, no-terminal failure, config.local.toml writer)"
```
```bash
chmod +x scripts/test-bootstrap-mode.sh && git add scripts/test-bootstrap-mode.sh && git update-index --chmod=+x scripts/test-bootstrap-mode.sh
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/test-bootstrap-mode.sh`
Expected: `FAIL: …` (bootstrap.sh runs its flow when sourced / `resolve_host_config` undefined).

- [ ] **Step 3: Add the mode helpers to bootstrap.sh**

In `bootstrap.sh`, change `fail` to write to stderr:
```bash
fail() {
  echo -e "${RED} ✗${RESET} $*" >&2
  exit 1
}
```
Add after the helpers:
```bash
# config.local.toml is machine-written `key = "value"` lines under [vars], so
# plain awk reads and writes it — no Python needed before tools exist.
config_get() { # config_get <file> <key>
  [[ -f "$1" ]] || return 0
  KEY="$2" awk '
    /^\[/ { in_vars = ($0 == "[vars]"); next }
    in_vars && index($0, ENVIRON["KEY"]) == 1 && substr($0, length(ENVIRON["KEY"]) + 1) ~ /^[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, ""); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); print; exit
    }' "$1"
}

config_set() { # config_set <file> <key> <value>
  local file=$1 key=$2 val=$3 tmp
  val=${val//\\/\\\\}
  val=${val//\"/\\\"}
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : >"$file"
  tmp=$(mktemp)
  KEY="$key" LINE="$key = \"$val\"" awk '
    /^\[/ {
      if (in_vars && !done) { print ENVIRON["LINE"]; done = 1 }
      in_vars = ($0 == "[vars]"); if (in_vars) seen = 1
      print; next
    }
    in_vars && index($0, ENVIRON["KEY"]) == 1 && substr($0, length(ENVIRON["KEY"]) + 1) ~ /^[[:space:]]*=/ {
      if (!done) { print ENVIRON["LINE"]; done = 1 }
      next
    }
    { print }
    END { if (!done) { if (!seen) print "[vars]"; print ENVIRON["LINE"] } }' "$file" >"$tmp" && mv "$tmp" "$file"
}

valid_mode() { [[ "${1:-}" == owned || "${1:-}" == shared ]]; }

# Prompts read fd 3: /dev/tty in real runs (so `curl | bash` still prompts),
# a here-string in tests.
open_prompt_fd() {
  { true <&3; } 2>/dev/null && return 0
  exec 3</dev/tty 2>/dev/null
}

prompt_mode() {
  local choice
  {
    echo "Is this host yours?"
    echo "  1) owned    my machine — sudo, full install"
    echo "  2) shared   someone else's — no sudo,"
    echo "              user-level toolbelt only"
  } >&2
  while :; do
    printf 'Choose [1/2]: ' >&2
    IFS= read -r choice <&3 || fail "No answer to the setup-mode question."
    case "$choice" in
    1 | owned) echo owned && return 0 ;;
    2 | shared) echo shared && return 0 ;;
    *) echo "  Please answer 1 or 2." >&2 ;;
    esac
  done
}

# Mode: saved in config.local.toml, else WORKSTATION_MODE, else a prompt.
# Name/email are asked on a first run; without a terminal they are left
# unset (templates guard them) rather than blocking an unattended run.
resolve_host_config() {
  local cfg="$REPO_DIR/config.local.toml" name email
  MODE=$(config_get "$cfg" mode)
  if [[ -n "$MODE" ]]; then
    valid_mode "$MODE" || fail "$cfg has mode = \"$MODE\" — expected owned or shared. Fix or delete that line and re-run."
    ok "mode: $MODE (saved in config.local.toml)"
  elif [[ -n "${WORKSTATION_MODE:-}" ]]; then
    valid_mode "$WORKSTATION_MODE" || fail "WORKSTATION_MODE=$WORKSTATION_MODE — expected owned or shared."
    MODE=$WORKSTATION_MODE
    ok "mode: $MODE (from WORKSTATION_MODE)"
  elif open_prompt_fd; then
    MODE=$(prompt_mode)
    ok "mode: $MODE"
  else
    fail "No terminal to ask the setup mode on.
   Re-run interactively:  ssh -t <host> '...'
   or answer up front:    WORKSTATION_MODE=shared   (or owned)"
  fi
  config_set "$cfg" mode "$MODE"

  name=$(config_get "$cfg" name)
  email=$(config_get "$cfg" email)
  if [[ -n "$name" && -n "$email" ]]; then
    return 0
  fi
  if ! open_prompt_fd; then
    warn "No terminal to ask your name/email on — add them to $cfg ([vars] name = \"…\", email = \"…\") for git commits."
    return 0
  fi
  log "First-time setup — name/email for git commits and the SSH config comment..."
  if [[ -z "$name" ]]; then
    printf '  Name: ' >&2
    IFS= read -r name <&3 || true
  fi
  if [[ -z "$email" ]]; then
    printf '  Email: ' >&2
    IFS= read -r email <&3 || true
  fi
  [[ -z "$name" ]] || config_set "$cfg" name "$name"
  [[ -z "$email" ]] || config_set "$cfg" email "$email"
}
```

- [ ] **Step 4: Wire the mode into the flow, drop the flags, add `main`**

In `bootstrap.sh`:
- Wrap the argument parsing loop in `parse_args() { … }` and delete the `--dev)` / `--prod)` cases, the "Missing required flag" block, `MACHINE_TYPE=""` and `GROUP_NAME=`.
- Delete `ensure_config_local` (replaced by `resolve_host_config`); in `run_bootstrap` delete its call.
- Rewrite the `--help` text:
  ```
  Usage: ./bootstrap.sh [flags]

  Sets up this host with mise. The first run asks whether the host is yours:
    owned   your machine — sudo: system packages, /etc files, services, zsh
            login shell, plus the full developer toolbelt
    shared  someone else's — no sudo: the user-level toolbelt only
  The answer is saved in ~/.config/mise/config.local.toml (vars.mode).
  Unattended first run: WORKSTATION_MODE=owned|shared.

  Flags:
    --reinstall   Wipe the cloned repo (incl. config.local.toml), then bootstrap
                  fresh. Installed tools and deployed dotfiles stay.
    --yes, -y     Skip the --reinstall confirmation prompt.
    --doctor      Read-only health report, then exit.
    --check-for-updates
                  Read-only update scan, then exit (--checkforupdates alias).
    -h, --help    Show this message.
  ```
- Every `$MACHINE_TYPE == dev` / `"$MACHINE_TYPE" = "dev"` / `!= "dev"` → `$MODE == owned` / `!= owned`; every `--${MACHINE_TYPE}` in messages → removed (`./bootstrap.sh` alone). `log "Dev mode — sudo will prompt …"` → `log "owned host — sudo will prompt for the dnf batch and /etc files"`. Doctor's login-shell hint `(dev) / … (prod)` → `(owned) / … (shared)`.
- `do_doctor` / `do_check_updates`: replace `"$MACHINE_TYPE"` with the saved mode:
  ```bash
  MODE=$(config_get "$REPO_DIR/config.local.toml" mode)
  if ! valid_mode "$MODE"; then
    warn "mode not set — run ./bootstrap.sh once to choose owned or shared"
    report_repo_state
    exit 1
  fi
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
  export MISE_ENV
  ```
  (In `do_doctor`, keep the prerequisite and repo sections before this check.)
- Move all remaining top-level statements (from `if [[ -n "$ACTION" && "$REINSTALL" == true ]]` to the final `echo -e "Health check any time: …"`) into:
  ```bash
  main() {
    parse_args "$@"
    …existing flow, with `resolve_host_config` called right after `install_mise`
    and `MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"` after it…
  }

  [[ "${WORKSTATION_BOOTSTRAP_LIB:-}" == 1 ]] || main "$@"
  ```
- `scripts/lib/mise-env.sh`: accept `owned|shared`:
  ```bash
  # mise-env.sh <owned|shared> — print the MISE_ENV token set for THIS Linux host.
  #   shared → linux
  #   owned  → linux,owned,host,wsl (WSL) | linux,owned,host,native (bare metal / VM)
  set -euo pipefail
  mode="${1:?usage: mise-env.sh <owned|shared>}"
  is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
  case "$mode" in
  owned) if is_wsl; then echo "linux,owned,host,wsl"; else echo "linux,owned,host,native"; fi ;;
  shared) echo "linux" ;;
  *)
    printf 'mise-env.sh: unknown mode %q (owned|shared)\n' "$mode" >&2
    exit 2
    ;;
  esac
  ```

- [ ] **Step 5: Templates, render check, completions**

- In `dotfiles/zshenv.tera`, `dotfiles/bashrc.tera`, `dotfiles/config/environment.d/10-mise.conf.tera`, `dotfiles/zshrc.tera`, `dotfiles/bashrc.tera` (line 61 block): `vars.group is defined and vars.group == "dev_machine"` → `vars.mode is defined and vars.mode == "owned"`. The three MISE_ENV expressions must stay byte-identical to each other.
- `scripts/check-invariants.sh` render check: `_render_baked_mise_env` writes `mode = "$group"` instead of `group = "$group"` (rename the parameter to `mode`); `dev_env=$(scripts/lib/mise-env.sh owned)`, `prod_env=$(scripts/lib/mise-env.sh shared)` (rename to `owned_env`/`shared_env`); render with `"owned"` / `"shared"`; labels `[vars.mode=owned]` / `[vars.mode=shared]` and `mise-env.sh owned` / `shared`; error text `mise-env.sh owned/shared produced no output`.
- `scripts/check-invariants.sh` completion parity: `want=$(_sh_script_flags bootstrap.sh --checkforupdates)` (drop the now-absent `--full` exclusion).
- Wire the new test next to the mise-install lib check:
  ```bash
  check_bootstrap_mode() {
    hdr "bootstrap.sh mode resolution (scripts/test-bootstrap-mode.sh)"
    local out
    if out=$(bash scripts/test-bootstrap-mode.sh 2>&1); then
      ok "${out#PASS: }"
    else
      bad "scripts/test-bootstrap-mode.sh failed:"
      printf '%s\n' "$out" | sed 's/^/       /' | head -10
    fi
  }
  ```
  and call `check_bootstrap_mode` in the main call list right after the mise-install lib check.
- `dotfiles/config/zsh/completions/_bootstrap.sh`: delete the `--dev` and `--prod` spec lines.
- `dotfiles/config/bash/completions.bash`: word list → `'--reinstall --yes --doctor --check-for-updates --help'`.

- [ ] **Step 6: Run the tests**

```bash
bash scripts/test-bootstrap-mode.sh
bash -n bootstrap.sh && shellcheck -S warning bootstrap.sh scripts/lib/mise-env.sh scripts/test-bootstrap-mode.sh && shfmt -i 2 -d bootstrap.sh scripts/lib/mise-env.sh scripts/test-bootstrap-mode.sh && echo LINT-OK
bash scripts/check-invariants.sh 2>&1 | grep -E 'mode resolution|vars.mode|bootstrap.sh ==|all invariant|✗'
bash scripts/check-templates.sh 2>&1 | tail -1
bash bootstrap.sh --help | head -3
```
Expected: `PASS: bootstrap.sh mode resolution …`; `LINT-OK`; six `[vars.mode=…]` ✓ lines, the mode-resolution ✓, both `bootstrap.sh ==` completion ✓, `✓ all invariant checks passed`; templates pass; help starts `Usage: ./bootstrap.sh [flags]`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(bootstrap)!: choose owned/shared by prompt instead of --dev/--prod

bootstrap.sh reads the mode from config.local.toml (vars.mode), else
WORKSTATION_MODE, else asks on the terminal, and otherwise stops with
both ways to answer. The mode-resolution logic sits behind a main guard
so scripts/test-bootstrap-mode.sh can test it (wired into
check-invariants). mise-env.sh takes owned|shared; templates key on
vars.mode; --dev/--prod are gone from the script and completions."
git push -q
```

---

### Task 5: Windows writes `mode = "owned"`; test it

**Files:**
- Create: `scripts/test-config-local.ps1`
- Modify: `bootstrap.ps1` (`Invoke-EnsureConfigLocal`, new `Set-ConfigLocalVar`), `.github/workflows/lint.yml` (windows-http job), `scripts/check-ps.ps1` (targets list)

**Interfaces:**
- Consumes: Task 2's simplified `Invoke-EnsureConfigLocal`.
- Produces: `Set-ConfigLocalVar -Path <string> -Key <string> -Value <string>` (sets/creates `key = "value"` under `[vars]`, preserving other tables, escaping `\` and `"`, UTF-8 without BOM, LF). `Invoke-EnsureConfigLocal` always ensures `mode = "owned"`; prompts for name/email only when missing and interactive.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-config-local.ps1` (UTF-8 **with BOM**, LF):
```powershell
# Tests bootstrap.ps1's config.local.toml writer (Set-ConfigLocalVar and
# Invoke-EnsureConfigLocal) without running the bootstrap: the two functions
# are extracted from the script's AST, the same way scripts/test-curl.ps1 works.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Set-ConfigLocalVar', 'Invoke-EnsureConfigLocal'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Write-Ok { param($m) }
function Write-Log { param($m) }
function Write-Warn { param($m) }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfglocal-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # 1. Existing file (name/email/group + a [dotfiles] table): mode added, rest kept.
    $RepoPath = Join-Path $tmp 'a'; New-Item -ItemType Directory -Path $RepoPath | Out-Null
    $cfg = Join-Path $RepoPath 'config.local.toml'
    [System.IO.File]::WriteAllText($cfg, "[vars]`nname = `"N`"`nemail = `"e@x`"`ngroup = `"dev_machine`"`n`n[dotfiles]`n`"~/.x`" = { source = `"x`", mode = `"copy`", enabled = false }`n")
    $SkipToolInstall = $true
    Invoke-EnsureConfigLocal
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert ($text -match '(?m)^mode = "owned"$') 'existing file: mode = "owned" not added'
    Assert ($text -match '(?m)^name = "N"$') 'existing file: name lost'
    Assert ($text -match '(?m)^\[dotfiles\]$') 'existing file: [dotfiles] lost'
    Assert (([regex]::Matches($text, '(?m)^mode = ')).Count -eq 1) 'existing file: mode duplicated'

    # 2. No file, non-interactive: file created with mode only.
    $RepoPath = Join-Path $tmp 'b'; New-Item -ItemType Directory -Path $RepoPath | Out-Null
    $cfg = Join-Path $RepoPath 'config.local.toml'
    Invoke-EnsureConfigLocal
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert ($text -match '(?m)^\[vars\]$') 'new file: [vars] missing'
    Assert ($text -match '(?m)^mode = "owned"$') 'new file: mode missing'
    $bytes = [System.IO.File]::ReadAllBytes($cfg)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'new file: written with a BOM'

    # 3. Set-ConfigLocalVar escapes quotes and replaces in place.
    Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'Q "q"'
    Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'R'
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert (([regex]::Matches($text, '(?m)^name = ')).Count -eq 1) 'Set-ConfigLocalVar duplicated a key'
    Assert ($text -match '(?m)^name = "R"$') 'Set-ConfigLocalVar did not replace'
    Set-ConfigLocalVar -Path $cfg -Key 'email' -Value 'a\b"c'
    Assert ([System.IO.File]::ReadAllText($cfg) -match [regex]::Escape('email = "a\\b\"c"')) 'Set-ConfigLocalVar did not escape'

    Write-Host "config.local.toml writer checks passed on PowerShell $($PSVersionTable.PSVersion)"
} finally {
    Remove-Item -Recurse -Force $tmp
}
$global:LASTEXITCODE = 0
```

- [ ] **Step 2: Run it to see it fail**

```bash
W=$(wslpath -w ~/.config/mise/scripts/test-config-local.ps1); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$W'; exit \$LASTEXITCODE" 2>&1 | tr -d '\r' | tail -3)
```
Expected: an error (`Set-ConfigLocalVar` not recognized, or `FAIL: …`).

- [ ] **Step 3: Implement in bootstrap.ps1 (BOM-preserving edit)**

Add before `Invoke-EnsureConfigLocal`:
```powershell
# config.local.toml is machine-written `key = "value"` lines under [vars];
# set one key in place, keeping every other table. UTF-8 without BOM, LF.
function Set-ConfigLocalVar {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '\\', '\\' -replace '"', '\"'
    $line = "$Key = `"$escaped`""
    $lines = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) -split "`r?`n" } else { @() }
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        # PowerShell's 0..-1 counts down, so a one-element array needs its own case.
        $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $inVars = $false; $seen = $false; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\[') {
            if ($inVars -and -not $done) { $out.Add($line); $done = $true }
            $inVars = ($l -eq '[vars]'); if ($inVars) { $seen = $true }
            $out.Add($l); continue
        }
        if ($inVars -and $l -match ('^' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $done) { $out.Add($line); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if (-not $done) { if (-not $seen) { $out.Add('[vars]') }; $out.Add($line) }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
```
Replace `Invoke-EnsureConfigLocal` with:
```powershell
# Windows is always an owned host (no shared mode here). Name/email are asked
# once, interactively; a non-interactive run leaves them for the user to add.
function Invoke-EnsureConfigLocal {
    $target = Join-Path $RepoPath "config.local.toml"
    Set-ConfigLocalVar -Path $target -Key 'mode' -Value 'owned'
    $text = [System.IO.File]::ReadAllText($target)
    $hasName = $text -match '(?m)^name\s*='
    $hasEmail = $text -match '(?m)^email\s*='
    if ($hasName -and $hasEmail) {
        Write-Ok "config.local.toml ready ($target, mode = owned)"
        return
    }
    if ($SkipToolInstall -or [Console]::IsInputRedirected) {
        Write-Warn "No interactive console — add [vars] name / email to $target for git commits."
        return
    }
    Write-Log "First-time setup -- name/email for git commits and the SSH config comment..."
    if (-not $hasName) { Set-ConfigLocalVar -Path $target -Key 'name' -Value (Read-Host "  Name") }
    if (-not $hasEmail) { Set-ConfigLocalVar -Path $target -Key 'email' -Value (Read-Host "  Email") }
    Write-Ok "wrote $target"
}
```
Also: in `$PortableTools`-adjacent comments or any `dev_machine` string left in `bootstrap.ps1`, use `owned`.

- [ ] **Step 4: CI + lint wiring**

- `.github/workflows/lint.yml`, in the `windows-http` job after the two curl steps:
  ```yaml
      - name: Test config.local.toml writer (Windows PowerShell 5.1)
        if: always()
        shell: powershell
        run: ./scripts/test-config-local.ps1
      - name: Test config.local.toml writer (pwsh)
        if: always()
        shell: pwsh
        run: ./scripts/test-config-local.ps1
  ```
- `scripts/check-ps.ps1`: add `'scripts/test-config-local.ps1',` to `$targets`.
- `scripts/check-invariants.sh` `check_bom`: add `scripts/test-config-local.ps1` to `files=(…)` only if the BOM list is meant to cover tests (it currently lists `bootstrap.ps1 scripts/install-nerd-fonts.ps1`; `test-curl.ps1` is not in it — follow that precedent and do NOT add it).

- [ ] **Step 5: Run the tests**

```bash
W=$(wslpath -w ~/.config/mise/scripts/test-config-local.ps1)
(cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$W'; exit \$LASTEXITCODE" 2>&1 | tr -d '\r' | tail -1)
(cd /mnt/c && pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$W'; exit \$LASTEXITCODE" 2>&1 | tr -d '\r' | tail -1)
B=$(wslpath -w ~/.config/mise/bootstrap.ps1); (cd /mnt/c && powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$B',[ref]\$null,[ref]\$e); 'parse errors: ' + \$e.Count" | tr -d '\r')
head -c3 bootstrap.ps1 | od -An -tx1
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: `config.local.toml writer checks passed on PowerShell 5.1…` and `… 7.…`; `parse errors: 0`; ` ef bb bf`; `✓ all invariant checks passed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(bootstrap.ps1): always write mode = \"owned\" to config.local.toml

Windows has no shared mode. Set-ConfigLocalVar edits one [vars] key in
place (other tables kept, quotes escaped, UTF-8 without BOM), and
Invoke-EnsureConfigLocal uses it for mode, name and email. Tested by
scripts/test-config-local.ps1 on PowerShell 5.1 and 7 (CI windows-http job)."
git push -q
```

---

### Task 6: Refactor bootstrap.sh into its final shape

**Files:**
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: Task 4 functions (`config_get`, `config_set`, `valid_mode`, `open_prompt_fd`, `prompt_mode`, `resolve_host_config`, `main`, `parse_args`).
- Produces: the same external behaviour and the same function names used by `scripts/test-bootstrap-mode.sh`; renames `run_bootstrap` → `apply`, `set_default_shell` → `set_login_shell`, and extracts `clone_or_update_repo`.

- [ ] **Step 1: Record the behavioural baseline**

```bash
bash bootstrap.sh --help >/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/help-before.txt
bash scripts/test-bootstrap-mode.sh
```
Expected: help text saved; `PASS:`.

- [ ] **Step 2: Reshape the file**

Rewrite `bootstrap.sh` in this order (move code; do not change behaviour):
1. Shebang + a header of at most ~15 lines: what it does, the one-liner `curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash`, the two modes in one line each, `WORKSTATION_MODE`, `--help` for flags.
2. `set -euo pipefail`, colours, `log`/`ok`/`warn`/`fail`, `is_wsl`.
3. Constants: `DOTFILES_REPO`, `REPO_DIR`, `BIN`, `MISE_VERSION`, `MISE_SHA256`, `GH_HEADER_KEY`.
4. `usage`, `parse_args` (sets `REINSTALL`, `YES`, `ACTION`).
5. config helpers + mode functions from Task 4.
6. Step functions: `preflight`, `clone_or_update_repo` (the GITHUB_TOKEN header + clone-or-pull block currently inline in `main`), `install_mise`, `resolve_host_config`, `apply` (was `run_bootstrap`), `set_login_shell` (was `set_default_shell`), `print_next_steps` (the closing tips block), `do_reinstall`, `require_repo`, `report_repo_state`, `do_doctor`, `do_check_updates`.
7. `main`:
   ```bash
   main() {
     parse_args "$@"
     case "$ACTION" in
     doctor) do_doctor ;;
     check-updates) do_check_updates ;;
     esac
     [[ "$REINSTALL" == true ]] && do_reinstall
     preflight
     mkdir -p "$BIN"
     export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"
     clone_or_update_repo
     install_mise
     resolve_host_config
     MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
     export MISE_ENV
     log "mise environment: MISE_ENV=$MISE_ENV"
     apply
     [[ "$MODE" == owned ]] && set_login_shell
     if [[ "$MODE" == owned && -t 0 ]]; then mise run statusline || true; fi
     print_next_steps
   }

   [[ "${WORKSTATION_BOOTSTRAP_LIB:-}" == 1 ]] || main "$@"
   ```
   (`do_doctor`/`do_check_updates` end with `exit`; `set_login_shell` keeps its shared-mode chsh hint only if still reachable — since it is now only called for owned, delete the shared branch inside it.)
8. Output wording: the `--force-dotfiles` log line becomes `First dotfiles apply on this host — passing --force-dotfiles (marker absent: $marker)` and the marker-written line becomes `first-apply marker written ($marker)`; `mise bootstrap failed` hints say `re-run: ./bootstrap.sh`.
9. Comments: keep short why-comments (e.g. Basic vs Bearer for git auth; `--force-dotfiles` only on the first apply because distro files already exist; the marker file name `dotfiles-migrated` is kept so existing hosts do not force again; bash reads the whole file before `main` runs). Delete incident narratives, fix-wave labels (I6, C1, Task N, PR3), dated verification notes, and the long step-list block.

- [ ] **Step 3: Verify behaviour is unchanged**

```bash
diff <(bash bootstrap.sh --help) /tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/help-before.txt && echo HELP-SAME
bash scripts/test-bootstrap-mode.sh
bash -n bootstrap.sh && shellcheck -S warning bootstrap.sh && shfmt -i 2 -d bootstrap.sh && echo LINT-OK
grep -c -E '\b(I[0-9]|C[0-9]|PR[0-9]|Task [0-9])\b|verified on-host|fix wave' bootstrap.sh
wc -l bootstrap.sh
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: `HELP-SAME`, `PASS:`, `LINT-OK`, `0`, a line count well under the original 978, `✓ all invariant checks passed`.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "refactor(bootstrap): one function per step, main at the end, short comments

Same behaviour, same single file: a short header, helpers, flag
parsing, one function per step (clone_or_update_repo, apply,
set_login_shell, print_next_steps …), and main as the last call so a
truncated curl | bash download cannot run a partial script. Incident
narratives and fix-wave labels move out of the comments (history is in
git and CLAUDE_CHANGELOG.md)."
git push -q
```

---

### Task 7: Refactor bootstrap.ps1 (sections, one GitHub-API header helper, short comments)

**Files:**
- Modify: `bootstrap.ps1`

**Interfaces:**
- Consumes: Tasks 2, 3, 5.
- Produces: `Get-GitHubApiHeaders` → hashtable `@{ "User-Agent" = "workstation-bootstrap"; Authorization = "Bearer …" (only when $env:GITHUB_TOKEN is set) }`. All other function names and the parameter block unchanged.

- [ ] **Step 1: Baseline**

```bash
grep -c -F '$headers = @{ "User-Agent" = "workstation-bootstrap" }' bootstrap.ps1
grep -n -E '^function ' bootstrap.ps1 | awk -F'[ {]' '{print $2}' >/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/ps1-functions-before.txt
```
Expected: `3`.

- [ ] **Step 2: Add the helper and use it (BOM-preserving edit)**

Add near the other small helpers:
```powershell
# GitHub API headers: a User-Agent is required; $env:GITHUB_TOKEN (optional)
# lifts the 60-requests/hour anonymous limit.
function Get-GitHubApiHeaders {
    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    return $headers
}
```
Replace each of the three two-line blocks
```powershell
$headers = @{ "User-Agent" = "workstation-bootstrap" }
if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
```
with `$headers = Get-GitHubApiHeaders` (keep each site's indentation).

- [ ] **Step 3: Sections and comments**

- Group the file with section banners in this order (move whole functions; do not change their bodies except comments): parameters & usage header → constants and tool tables (`$PortableTools`, installer/elevated tables, paths) → output helpers → HTTP/GitHub helpers (`Invoke-CurlRequest` unchanged, `Get-GitHubApiHeaders`) → PATH helpers → install functions → repo & mise functions → shell/terminal integration → Claude/Python/fonts/SSH → doctor/update reporting → run sequence.
- Header comment: at most ~30 lines — what it does, the `curl.exe` one-liner, the parameters, "no admin needed" (with the SSHFS-Win UAC exception), Windows is always the `owned` mode.
- Trim comments to short why-notes; delete incident narratives, fix-wave labels (I3, I5, I8, C1, Task N, PR3), dated verification notes.
- Output wording: `Invoke-MiseBootstrap`'s `--force-dotfiles` line becomes `First dotfiles apply on this host -- passing --force-dotfiles (marker absent: $MigratedMarker)`; any "migration marker" wording becomes "first-apply marker".
- Delete any function no longer called (compare `grep -n '^function '` names against call sites; `Invoke-CurlRequest` stays).
- Keep: the BOM, `Set-StrictMode -Version Latest`, PS 5.1 compatibility, `Invoke-CurlRequest` byte-identical to `scripts/install-nerd-fonts.ps1`.

- [ ] **Step 4: Verify**

```bash
cd ~/.config/mise
grep -c -F '$headers = @{ "User-Agent" = "workstation-bootstrap" }' bootstrap.ps1
grep -c -E '\b(I[0-9]|C[0-9]|PR[0-9]|Task [0-9])\b|fix wave|final-fix-brief' bootstrap.ps1
head -c3 bootstrap.ps1 | od -An -tx1
B=$(wslpath -w ~/.config/mise/bootstrap.ps1); (cd /mnt/c && powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$B',[ref]\$null,[ref]\$e); 'parse errors: ' + \$e.Count" | tr -d '\r')
for t in test-curl test-config-local; do W=$(wslpath -w ~/.config/mise/scripts/$t.ps1); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$W'; exit \$LASTEXITCODE" 2>&1 | tr -d '\r' | tail -1); done
(cd /mnt/c && timeout 300 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Location \$env:USERPROFILE; & '$B' -Doctor" </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -E ' (X|!) ' | head)
wc -l bootstrap.ps1
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: `1` (only inside `Get-GitHubApiHeaders`); `0`; ` ef bb bf`; `parse errors: 0`; both test scripts pass; `-Doctor` shows no `X` rows (the known `!` rows only: VSCode not on PATH, Claude not on PATH in a -NoProfile shell); a line count well under 3,245; `✓ all invariant checks passed`.

Note: `-Doctor` runs the branch's `bootstrap.ps1` read-only against the live Windows host; it changes nothing.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.ps1
git commit -m "refactor(bootstrap.ps1): sections, one GitHub-API header helper, short comments

Same behaviour, same single file: functions grouped by concern under
section banners, the three copies of the GitHub API header code merged
into Get-GitHubApiHeaders, unused code removed, and comments cut to
short why-notes. Invoke-CurlRequest is unchanged (byte-identical to
install-nerd-fonts.ps1)."
git push -q
```

---

### Task 8: Docs, memory and cheat sheet

**Files:**
- Modify: `README.html`, `docs/README/README.css`, `docs/README/README.js`, `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `docs/claude/verification.md`, `CLAUDE_CHANGELOG.md`, `dotfiles/claude/CLAUDE.md` (outside the TOOLS sentinels), `dotfiles/claude/skills/workstation-lsp/SKILL.md`, `dotfiles/config/cheat/cheatsheets/personal/workstation`, `.claude/memory/project-mise-everything.md`, `.claude/memory/project-hosts-list-removed.md`, `.claude/memory/MEMORY.md`, plus a new `.claude/memory/project-bootstrap-owned-shared.md`

**Interfaces:**
- Consumes: final names from Tasks 3–7.
- Produces: docs that describe the prompt, `WORKSTATION_MODE`, `vars.mode`, `owned`/`shared`, `config.owned.toml`, `MISE_ENV` sets from Global Constraints.

- [ ] **Step 1: Failing guard**

```bash
cd ~/.config/mise
git grep -n -E -- '--dev\b|--prod\b|dev_machine|prod_machine|config\.dev\.toml|linux,dev|windows,dev|vars\.group|migrate-legacy' -- README.html CLAUDE.md docs/claude dotfiles/claude/CLAUDE.md dotfiles/claude/skills dotfiles/config/cheat .claude/memory/MEMORY.md | wc -l
```
Expected: a non-zero count.

- [ ] **Step 2: README.html + CSS/JS**

- Machines section: replace the dev_machine/prod_machine table with owned/shared (what each installs, sudo or not), how the mode is chosen (prompt, saved as `vars.mode` in `config.local.toml`, `WORKSTATION_MODE` for unattended first runs, edit/delete the line to change), and that Windows is always owned.
- Linux setup: one snippet (no prod/dev tabs) — `curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash` — plus the unattended form `curl -fsSL … | WORKSTATION_MODE=shared bash`. Remove the `pprod`/`pdev` radio tabs markup; delete their rules from `README.css` (the `#pprod`/`#pdev` selectors) and the `["panel-prod", "pprod"], ["panel-dev", "pdev"]` entries from `README.js`'s `tabInputs` map (leave the map empty-but-valid or remove it and its uses if nothing else feeds it).
- Quickstart Linux card, WSL section, reinstall section, doctor/check-for-updates examples: drop `--dev`/`--prod` (e.g. `./bootstrap.sh --doctor`, `curl … | bash -s -- --reinstall`).
- Badges: `badge dev`/`badge prod` → `badge owned`/`badge shared` in markup; rename `.badge.dev`/`.badge.prod` CSS rules accordingly; every "dev_machine only" → "owned hosts only", "prod_machine" → "shared hosts", "both dev_machine and prod_machine" → "both modes".
- Layout tree: `config.dev.toml` → `config.owned.toml`, `mise.dev.lock` → `mise.owned.lock`, add `scripts/test-bootstrap-mode.sh`, `scripts/test-config-local.ps1`; remove `tasks/migrate-legacy`.
- Troubleshooting: replace any entry about `--dev`/`--prod` choice or chezmoi relocation/migration with an entry "Changing a host between owned and shared" (edit `mode` in `config.local.toml`, re-run `./bootstrap.sh`).
- Run: `(npm ls jsdom >/dev/null 2>&1 || npm install --no-save --no-package-lock --no-audit --no-fund jsdom@30.0.1 >/dev/null 2>&1); node scripts/check-readme.mjs`
  Expected: `README checks passed (…)`.

- [ ] **Step 3: Claude docs, cheat sheet, memory**

- `CLAUDE.md` + `docs/claude/*.md`: every rule/tripwire naming dev/prod, `vars.group`, `config.dev.toml`, `mise.dev.lock`, `locks/mise.dev`, `migrate-legacy`, `--force-dotfiles` "migration", `relocate_repo`, `ensure_config_local`, or the chezmoi migration path — rewrite for owned/shared, `vars.mode`, `resolve_host_config`, `config.owned.toml`, `mise.owned.lock`; delete rules whose subject is gone (migrate-legacy, chezmoi relocation, the vars.group repair). Keep CLAUDE.md lean.
- `dotfiles/claude/CLAUDE.md` (outside `<!-- TOOLS:START/END -->`), `dotfiles/claude/skills/workstation-lsp/SKILL.md`: `config.dev.toml` → `config.owned.toml`, `./bootstrap.sh --dev` → `./bootstrap.sh` (owned mode).
- Cheat sheet `dotfiles/config/cheat/cheatsheets/personal/workstation`: drop `--dev`/`--prod`; mention `WORKSTATION_MODE` and `vars.mode`.
- `CLAUDE_CHANGELOG.md`: add a row at the top of the table: the change, `Yes`, and the README sections touched (machines, setup-linux, quickstart, WSL, reinstall, badges, layout, troubleshooting).
- Memory: create `.claude/memory/project-bootstrap-owned-shared.md` (type project: modes owned/shared, stored in `vars.mode`, resolution order, Windows always owned, token rename, migration code removed 2026-09-25, rollout set `mode = "owned"` on WSL + Windows; How to apply: never reintroduce `--dev`/`--prod` or a `group` key; unmigrated hosts bootstrap fresh with `--reinstall`); add its line to `.claude/memory/MEMORY.md`; update `project-mise-everything.md` and `project-hosts-list-removed.md` where they give instructions using `--dev`/`--prod`, `dev_machine`, `config.dev.toml` or `migrate-legacy`.

- [ ] **Step 4: Verify**

```bash
git grep -n -E -- '--dev\b|--prod\b|dev_machine|prod_machine|config\.dev\.toml|linux,dev|windows,dev|vars\.group|migrate-legacy' -- README.html CLAUDE.md docs/claude dotfiles/claude/CLAUDE.md dotfiles/claude/skills dotfiles/config/cheat .claude/memory/MEMORY.md
node scripts/check-readme.mjs
bash scripts/check-invariants.sh 2>&1 | tail -1
```
Expected: no output from the grep except lines that explicitly describe the rename/removal (keep those minimal; ideally none in README); `README checks passed`; `✓ all invariant checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: owned/shared modes, WORKSTATION_MODE, config.owned.toml

README (machines, Linux/WSL setup, quickstart, reinstall, badges,
layout, troubleshooting), CLAUDE.md, docs/claude, the cheat sheet, the
Claude memory file, CLAUDE_CHANGELOG.md and project memory describe the
prompted owned/shared mode and the renamed files; the migration-era
rules are gone."
git push -q
```

---

### Task 9: End-to-end first run (shared) and PR

**Files:** none changed (verification + PR).

- [ ] **Step 1: Fresh shared-mode first run into a scratch HOME**

`bootstrap.sh` clones `main`, so run a local copy patched to clone this branch:
```bash
S=/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/e2e; rm -rf $S; mkdir -p $S/home
cp ~/.config/mise/bootstrap.sh $S/bootstrap.sh
sed -i 's#git clone "$DOTFILES_REPO" "$REPO_DIR"#git clone --branch feat/bootstrap-owned-shared "$DOTFILES_REPO" "$REPO_DIR"#' $S/bootstrap.sh
grep -c 'clone --branch feat/bootstrap-owned-shared' $S/bootstrap.sh   # must print 1 (or 2 if the clone line appears twice); 0 = patch missed, fix the sed
cd /tmp && env -i HOME=$S/home PATH=/usr/bin:/bin USER="$USER" TERM=dumb GITHUB_TOKEN="$(gh auth token)" WORKSTATION_MODE=shared setsid -w bash $S/bootstrap.sh </dev/null >$S.log 2>&1; echo "exit=$?"
grep -E 'mode: shared|MISE_ENV=linux$|Bootstrap complete|✗' $S.log | head
cat $S/home/.config/mise/config.local.toml
grep -m1 'MISE_ENV=' $S/home/.zshenv
```
Expected: `mode: shared (from WORKSTATION_MODE)`, `MISE_ENV=linux`, `config.local.toml` contains `mode = "shared"` (plus a name/email warning — no terminal), `~/.zshenv` bakes `export MISE_ENV="linux"`, and ideally `exit=0` + `Bootstrap complete.`

Environment limit: this scratch run has no systemd user session (`env -i`, `setsid`), so the `pueued` user-service phase of `mise bootstrap` may fail. If the only `✗` is in the services phase, confirm everything before it succeeded (mode saved, MISE_ENV, tools installed into `$S/home/.local/share/mise`, dotfiles applied under `$S/home`) and record it as the known limit; any other failure is a bug. Then `rm -rf $S $S.log`.

- [ ] **Step 2: Final equivalence re-check**

Re-run Task 3 Steps 5–6 against the branch tip (all `SAME`). Then compare every rendered dotfile, old tree vs branch tip, ignoring only the `MISE_ENV` value:
```bash
B=/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/baseline
render() { # render <tree> <MISE_ENV> <extra [vars] line> <outdir>
  local h e b; h=$(mktemp -d); mkdir -p "$h/.config/mise" "$4"
  for e in "$1"/*; do b=$(basename "$e"); [ "$b" = config.local.toml ] && continue; ln -s "$e" "$h/.config/mise/$b"; done
  printf '[vars]\nname = "T"\nemail = "t@x"\n%s\n' "$3" >"$h/.config/mise/config.local.toml"
  (cd "$h" && HOME="$h" MISE_CONFIG_DIR="$h/.config/mise" MISE_ENV="$2" mise dot apply --force --yes >/dev/null 2>&1)
  (cd "$h" && find . -path ./.config/mise -prune -o -type f -print | sort | while read -r f; do printf '== %s\n' "$f"; grep -v 'MISE_ENV' "$f"; done) >"$4/all.txt"
  rm -rf "$h"
}
render $B/tree linux,dev,host,wsl 'group = "dev_machine"' $B/r-old-owned
render ~/.config/mise linux,owned,host,wsl 'mode = "owned"' $B/r-new-owned
render $B/tree linux 'group = "prod_machine"' $B/r-old-shared
render ~/.config/mise linux 'mode = "shared"' $B/r-new-shared
render $B/tree windows,dev 'group = "dev_machine"' $B/r-old-win
render ~/.config/mise windows,owned 'mode = "owned"' $B/r-new-win
for m in owned shared win; do diff -q $B/r-old-$m/all.txt $B/r-new-$m/all.txt >/dev/null && echo "$m renders SAME" || { echo "$m renders DIFF"; diff $B/r-old-$m/all.txt $B/r-new-$m/all.txt | head -20; }; done
```
Expected: `owned renders SAME`, `shared renders SAME`, `win renders SAME`. Allowed differences, and only these: comment/text lines in deployed files that Tasks 3–8 deliberately reworded (e.g. `config.dev.toml` → `config.owned.toml` in a comment, `dotfiles/claude/CLAUDE.md`'s TOOLS heading, the cheat sheet), plus the intended change to the deployed completions (`~/.config/zsh/completions/_bootstrap.sh`, `~/.config/bash/completions.bash` lose `--dev`/`--prod`) — inspect each remaining line and confirm it is a wording change, not a behaviour change. Then:
```bash
bash scripts/check-invariants.sh 2>&1 | tail -1 && bash scripts/check-templates.sh 2>&1 | tail -1 && bash scripts/test-bootstrap-mode.sh && bash scripts/test-mise-install.sh
git worktree remove --force /tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33014d75-d79f-4db2-b1bd-3d332a616c5e/scratchpad/baseline/tree
```

- [ ] **Step 3: Open the PR and wait for CI**

```bash
gh pr create --repo ArrushC/workstation --base main --head feat/bootstrap-owned-shared \
  --title "feat(bootstrap)!: prompted owned/shared mode; migration code removed; single-file refactor" \
  --body-file <(cat <<'EOF'
Implements docs/superpowers/specs/2026-09-25-bootstrap-owned-shared-design.md.

- `--dev`/`--prod` → a prompted mode, `owned` or `shared`, saved as `vars.mode` in config.local.toml (`WORKSTATION_MODE` for unattended first runs). Windows is always owned.
- Token `dev` → `owned`: config.owned.toml, mise.owned.lock, `MISE_ENV=linux,owned,host,…` / `windows,owned`. `mise bootstrap plan` and the resolved tool set match the old token sets exactly.
- Migration code removed from both bootstraps, and `tasks/migrate-legacy` deleted.
- Both bootstraps refactored as single files, with short comments.
- New tests: scripts/test-bootstrap-mode.sh, scripts/test-config-local.ps1 (PS 5.1 + 7 in CI).

**Rollout after merge (required):** set `mode = "owned"` in config.local.toml on WSL and Windows before their next `wsu`, then re-run each bootstrap once.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
gh pr checks --repo ArrushC/workstation feat/bootstrap-owned-shared --watch --interval 15
```
Expected: all checks pass. Report the PR URL to the user and ask for approval to merge.

---

### Task 10: Merge and roll out (requires the user's go-ahead to merge)

**Files:** live-host state only (`~/.config/mise/config.local.toml` on WSL and Windows, rendered dotfiles, persisted `MISE_ENV`).

- [ ] **Step 1: Merge (after user approval)**

```bash
gh pr merge feat/bootstrap-owned-shared --repo ArrushC/workstation --squash --delete-branch
cd ~/.config/mise && git switch -q main && git pull -q --ff-only
```

- [ ] **Step 2: WSL — set the mode, then bootstrap**

```bash
cd ~/.config/mise
grep -n -E '^(group|mode) *=' config.local.toml
sed -i -E 's/^group *= *"dev_machine"$/mode = "owned"/' config.local.toml
grep -n '^mode' config.local.toml
./bootstrap.sh </dev/null
```
Expected: `mode = "owned"`; the run prints `mode: owned (saved in config.local.toml)` and `MISE_ENV=linux,owned,host,wsl`, ends `Bootstrap complete.`. If it stops at a sudo password prompt, hand the command to the user (`! ./bootstrap.sh`).

- [ ] **Step 3: Windows — set the mode, then bootstrap**

```bash
cd /mnt/c && timeout 60 powershell.exe -NoProfile -Command '$r="$env:USERPROFILE\.config\mise"; git -C $r pull -q --ff-only; $f="$r\config.local.toml"; $t=[System.IO.File]::ReadAllText($f) -replace "(?m)^group\s*=\s*`"dev_machine`"\r?\n",""; [System.IO.File]::WriteAllText($f,$t,(New-Object System.Text.UTF8Encoding($false))); Get-Content $f' | tr -d '\r'
head -c3 /mnt/c/Users/arrush.chaturvedi/.config/mise/config.local.toml | od -An -tx1
cd /mnt/c && timeout 900 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'Set-Location $env:USERPROFILE\.config\mise; & .\bootstrap.ps1 -SkipKeyGen' </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -E ' (V|X|!) |complete' | tail -15
```
Expected: `config.local.toml` printed without `group`; the first three bytes are NOT `ef bb bf`; the bootstrap adds `mode = "owned"`, persists `MISE_ENV=windows,owned`, and ends `Bootstrap complete.`

- [ ] **Step 4: Verify both hosts**

```bash
env -i HOME=$HOME PATH=/usr/bin:/bin zsh -c 'echo "MISE_ENV=$MISE_ENV"; node --version; opencode --version'
systemctl --user show-environment | grep '^MISE_ENV='
grep -h 'MISE_ENV' ~/.config/environment.d/10-mise.conf
mise -C "$HOME" dot status 2>&1 | grep -c differs
mise -C "$HOME" run health 2>&1 | tail -2
cd /mnt/c && timeout 120 powershell.exe -NoProfile -Command '[Environment]::GetEnvironmentVariable("MISE_ENV","User"); $env:MISE_ENV="windows,owned"; @(mise -C $env:USERPROFILE dot status 2>$null | Select-String "differs|missing").Count' | tr -d '\r'
```
Expected: `MISE_ENV=linux,owned,host,wsl` (from zsh, the systemd user manager and environment.d), node and opencode versions print; `0` drift; `health: OK` with 0 problems; Windows prints `windows,owned` and `0`.
