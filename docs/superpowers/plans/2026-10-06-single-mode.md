# Single Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One workstation setup for every host: no owned/shared mode, three config files, OS-only token sets, and system steps (sudo) detected and remembered automatically.

**Architecture:** `config.owned.toml` folds into `config.toml` and `config.host.toml` into `config.linux.toml`; `mise-env.sh` emits the OS token (`linux`; `bootstrap.ps1` writes `windows`). `bootstrap.sh` drops the mode prompt and instead decides, once, whether sudo works (saved as `vars.sudo` in `config.local.toml`); without it, `mise bootstrap --skip packages,files` and no login-shell change. Everything that read the mode (update, health, the session hook, checks, tests, docs) follows.

**Tech Stack:** bash (shfmt -i 2, shellcheck), PowerShell 5.1/7 (`bootstrap.ps1`, UTF-8 BOM), mise 2026.9.9 (`[tools]`, `[dotfiles]`, `[bootstrap.*]`, `mise lock`), Python tomllib (checks), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-06-single-mode-design.md`

## Global Constraints

- Branch `feat/single-mode` (already holds the spec commit). One PR at the end; it is squash-merged.
- Never hand-edit `mise*.lock` or `locks/**`: regenerate with `mise lock` from outside the checkout (recipe in Task 2), then fold any `.mise/locks/**` into `locks/**`.
- Every `scripts/*.sh`, `scripts/lib/*.sh`, `tasks/*`, `.claude/hooks/*.sh`: LF, git mode 100755, `shfmt -i 2` clean, shellcheck clean at warning+.
- `bootstrap.ps1` keeps its UTF-8 BOM; in double-quoted PowerShell strings write `${name}:`, never `$name:`.
- `zshrc.tera` and `bashrc.tera` are a parity pair: change both in the same commit.
- `CLAUDE.md` stays ≤ 14,000 bytes; `README.md` ≤ 600 lines.
- Agents never run `mise dot apply`, `wsa` or a bulk `mise bootstrap` against the real `$HOME`; render or install into scratch dirs run from `/tmp` (never from inside the checkout: mise would load the repo's own config and may rewrite its lock files).
- Token sets after this plan: Linux `linux`, Windows `windows`. Disk budget keys: `linux`, `windows`.
- `config.local.toml` `[vars]` keys after this plan: `name`, `email`, `sudo` (`"yes"`/`"no"`, written only by `bootstrap.sh`; a missing value means yes). No `mode`.
- Each task ends with `mise run lint` and `bash scripts/check-templates.sh` passing, then a commit ending with the trailers:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```

## Review Focus

1. A no-sudo host with a terminal: the first `bootstrap.sh` saves `sudo = "no"`; later `mise run update` runs must skip the system steps without any password prompt (Task 3, cases S3 and U2).
2. An unattended first run (no terminal, no cached sudo) must skip the system steps for that run only and save nothing, so a later interactive run re-checks (Task 3, case S4).
3. An existing host with a stale `mode = "owned"` line (possibly CRLF, indented or commented) and no `sudo` key: the next update drops the line and runs the full bootstrap (Task 3, cases T1 and U1).
4. A host whose `miserc.toml` still lists the old tokens (`linux,owned,host` or `windows,owned`) must keep loading `config.toml` + the OS file until it is rewritten (Task 2, step "old token sets").
5. Windows `bootstrap.ps1` must still stop before `mise bootstrap`/prune when `miserc.toml` isn't honoured, now detected by `config.windows.toml` missing from `mise config ls` (Task 2, PowerShell test case).

---

### Task 1: Disk budget keys become `linux` and `windows`

**Files:**
- Modify: `disk-budget.toml`
- Modify: `.github/workflows/disk-budget.yml`
- Modify: `scripts/lib/mise-install.sh` (`check_disk`)
- Modify: `bootstrap.ps1` (`Assert-ToolsDiskSpace`)
- Modify: `scripts/check-invariants.sh` (`check_disk_budget`)
- Test: `scripts/test-mise-install.sh` (cases 10–16), `scripts/test-mise-env.ps1` (disk cases)

**Interfaces:**
- Produces: `disk-budget.toml` with exactly `linux = <MB>` and `windows = <MB>`; `check_disk` reads `linux` regardless of tokens; `Assert-ToolsDiskSpace` reads `windows`.

- [ ] **Step 1: Update the tests first**

In `scripts/test-mise-install.sh`:
- The temp budget becomes `printf 'linux = 5000\nwindows = 3000\n' >"$R/disk-budget.toml"` and its comment says "says linux 5000 MB".
- Case 12 becomes "the linux figure applies whatever the token set":
  ```bash
  # 12. the linux figure applies whatever MISE_ENV says (one setup for every host):
  # 4.5 GB free, nothing installed, needs 5000 + 1024 MB.
  rc12=0
  MISE_ENV=linux FAKE_FREE_KB="$(gbkb 4.5)" bash "$mi" >/dev/null 2>&1 || rc12=$?
  [ "$rc12" = 1 ] || fail "disk check: 4.5 GB must not be enough (linux budget 5000 MB + 1 GB), got $rc12"
  ```
- Case 15 writes `printf 'windows = 3000\n'` and greps `disk check skipped: no linux figure`.
- Case 16 writes `printf 'linux = 5000\r\nwindows = 3000\r\n'`.
- Header comment: replace "(12) a shared host needs less than an owned one" with "(12) the linux figure applies whatever the token set".

In `scripts/test-mise-env.ps1`: `Set-Content -LiteralPath $budgetFile -Value 'windows-owned = 3000'` → `'windows = 3000'` (both places), the missing-figure case writes `'linux = 5000'` and expects `*disk check skipped: no windows figure*`, and its name says "no windows figure".

- [ ] **Step 2: Run the tests; they fail**

Run: `bash scripts/test-mise-install.sh`
Expected: FAIL at case 10 or 12 (the script still reads `linux-owned`).

- [ ] **Step 3: Change the readers and the file**

`scripts/lib/mise-install.sh` `check_disk`: delete the `tokens=` and `case "$tokens"` lines and the `key` local; read the fixed key:
```bash
  budget="$(tr -d '\r' <"$repo/disk-budget.toml" 2>/dev/null | sed -n 's/^linux *= *\([0-9][0-9]*\) *$/\1/p' || true)"
  if [ -z "$budget" ]; then
    printf '  ! disk check skipped: no linux figure in %s\n' "$repo/disk-budget.toml" >&2
    return 0
  fi
```
and update its comment block's first sentence to "The budget is what a fresh install writes on Linux, as measured by .github/workflows/disk-budget.yml into disk-budget.toml".

`bootstrap.ps1` `Assert-ToolsDiskSpace`: pattern `'^windows *= *(\d+) *$'`, warning `"disk check skipped: no windows figure in $budgetFile"`.

`scripts/check-invariants.sh` `check_disk_budget`: `for k in linux windows; do`, ok text `"disk-budget.toml: linux and windows figures present"`, and the comment "one `<os> = <MB>` line per OS".

`disk-budget.toml` (keep the 4-line header comment, replace "per host type" with "per OS"):
```toml
linux = 5900
windows = 3000
```

`.github/workflows/disk-budget.yml`:
- `linux` job: drop the `strategy.matrix`; set `key` literally. Its env `MISE_ENV: linux,owned,host` (Task 2 changes it to `linux`). Every `${{ matrix.key }}` becomes `linux`; artifact `name: budget-linux`, `path: ${{ runner.temp }}/budget/linux`; summary line `"linux: $mb MB"`; file line `echo "linux = $mb" >"$RUNNER_TEMP/budget/linux"`.
- `windows` job: `"windows: $mb MB"`, `"windows = $mb"`, file `budget\windows`, artifact `budget-windows`, path `${{ runner.temp }}/budget/windows`.
- `commit` job: `for k in linux windows; do`, and the header comment "per OS".

- [ ] **Step 4: Run the tests; they pass**

Run: `bash scripts/test-mise-install.sh` → `PASS: ...`
Run the PowerShell suite on both shells (from WSL, copy to a Windows temp dir):
```bash
T=/mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/ws-t-single; for exe in /mnt/c/Users/arrush.chaturvedi/AppData/Local/Microsoft/WindowsApps/pwsh.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do rm -rf $T && mkdir -p $T/scripts && cp bootstrap.ps1 $T/ && cp scripts/*.ps1 scripts/python-env.txt $T/scripts/ && (cd /mnt/c/Users/arrush.chaturvedi && $exe -NoProfile -ExecutionPolicy Bypass -Command "\$env:PSModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Machine'); & '$(wslpath -w $T)\\scripts\\test-mise-env.ps1'; exit \$LASTEXITCODE" 2>&1 | tr -d '\r' | grep -E 'FAIL|checks passed'); done; rm -rf $T
```
Expected: `mise plumbing checks passed` on 7.x and 5.1, no FAIL.
Run: `mise run lint` and `bash scripts/check-templates.sh` → pass.

- [ ] **Step 5: Commit**

```bash
git add disk-budget.toml .github/workflows/disk-budget.yml scripts/lib/mise-install.sh bootstrap.ps1 scripts/check-invariants.sh scripts/test-mise-install.sh scripts/test-mise-env.ps1
git commit -m "disk budget: one figure per OS (linux, windows)"   # body: two or three lines on why (one setup for every Linux host), then the Global Constraints trailers
```

---

### Task 2: Fold the owned and host files; OS-only token sets

**Files:**
- Modify: `config.toml` (gains `config.owned.toml`'s `[tools]` and `[dotfiles]`)
- Modify: `config.linux.toml` (gains `config.host.toml`'s tables)
- Delete: `config.owned.toml`, `config.host.toml`, `mise.owned.lock`, `locks/mise.owned/**`
- Modify: `mise.lock`, `locks/mise/**` (regenerated, never hand-edited)
- Modify: `scripts/lib/mise-env.sh` (no mode argument)
- Modify: `bootstrap.sh` (the `mise-env.sh` call only), `tasks/update` (the call only), `tasks/health` (the `canonical_env` line only)
- Modify: `bootstrap.ps1` (`$MiseEnvTokens`, `Initialize-MiseEnv` comment, the loaded-config guard, the node declaration path)
- Modify: `dotfiles/zshrc.tera`, `dotfiles/bashrc.tera` (vcpkg block unconditional)
- Modify: `scripts/check-invariants.sh`, `scripts/check-templates.sh`, `scripts/bump-versions.sh`, `scripts/gen-tool-memory.sh`, `scripts/lib/mise-install.sh`, `scripts/test-check-pins.sh`, `scripts/test-mise-install.sh`, `.claude/hooks/test-hooks.sh`, `.github/workflows/lint.yml`, `.github/workflows/disk-budget.yml`, `dotfiles/claude/CLAUDE.md` (TOOLS block regenerated)
- Test: `scripts/test-mise-env.ps1`

**Interfaces:**
- Consumes: Task 1's `linux`/`windows` budget keys.
- Produces: `scripts/lib/mise-env.sh [--write]` prints `linux` (and with `--write` writes `miserc.toml` with `env = ["linux"]`). `bootstrap.ps1` writes `env = ["windows"]`. Config files: `config.toml`, `config.linux.toml`, `config.windows.toml`. Locks: `mise.lock`, `mise.linux.lock`.

- [ ] **Step 1: Update the PowerShell tests first**

In `scripts/test-mise-env.ps1`:
- Every `$script:MiseEnvTokens = @('windows', 'owned')` → `@('windows')`; the miserc case expects `env = ["windows"]` and its name says `windows`; the "old miserc.toml kept" assertion expects `env = ["windows"]`.
- `$ownedLs` becomes the loaded list for a healthy Windows host and is renamed `$winLs`:
  ```powershell
  $winLs = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}, {"path": "C:\\Users\\u\\.config\\mise\\config.windows.toml"}]'
  ```
  (replace every `$ownedLs` use).
- The guard case becomes:
  ```powershell
  Test-Case 'mise bootstrap: stops before bootstrap/prune when config.windows.toml is not loaded' {
      $script:miseReply = @{ 'config ls' = @{ Out = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}]'; Exit = 0 } }
      $msg = Invoke-Bootstrap
      Assert ($msg -like 'WRITE-FAIL:*config.windows.toml*miserc.toml*') "got: $msg"
      Assert ($msg -notlike '*min_version*') "min_version hint for an exit-0 config ls: $msg"
      Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
      Assert (@(Get-MiseCall 'prune').Count -eq 0) 'mise prune ran'
      Assert ($script:events -notcontains 'cleanup') 'legacy cleanup ran'
  }
  ```
- The "error names config.owned.toml" case uses `config.windows.toml` in the fake error text and the assertion.

- [ ] **Step 2: Run them; they fail**

Run the PowerShell command from Task 1 step 4. Expected: FAIL on the miserc and guard cases.

- [ ] **Step 3: Fold the files**

Merge with this helper (run from the repo root; it appends each source table's body under the same table in the destination, creating the table when absent, and keeps comments). Save it to the scratchpad, not the repo:
```python
# fold.py <src> <dst>: move every top-level table of src into dst.
import re, sys
src, dst = sys.argv[1], sys.argv[2]
def split(text):
    parts, name, buf = [], None, []
    for line in text.splitlines(keepends=True):
        m = re.match(r'^\[([^\[\]]+)\]\s*(#.*)?$', line)
        if m:
            parts.append((name, buf)); name, buf = m.group(1).strip(), [line]
        else:
            buf.append(line)
    parts.append((name, buf))
    return parts
s_parts = split(open(src).read())
d_text = open(dst).read()
d_parts = split(d_text)
d_names = [n for n, _ in d_parts]
for name, buf in s_parts:
    if name is None:
        continue                      # src's file header comment: dropped
    body = ''.join(buf[1:]).rstrip('\n') + '\n'
    if name in d_names:
        i = d_names.index(name)
        n, dbuf = d_parts[i]
        d_parts[i] = (n, [''.join(dbuf).rstrip('\n') + '\n'] + [body, '\n'])
    else:
        d_parts.append((name, [''.join(buf).rstrip('\n') + '\n', '\n']))
        d_names.append(name)
open(dst, 'w').write(''.join(''.join(b) for _, b in d_parts).rstrip('\n') + '\n')
```
```bash
python3 "$SCRATCH/fold.py" config.owned.toml config.toml
python3 "$SCRATCH/fold.py" config.host.toml config.linux.toml
git rm -q config.owned.toml config.host.toml
```
Then edit by hand:
- `config.toml` header comment: list three files (`config.toml always`, `config.linux.toml linux`, `config.windows.toml windows`, `config.local.toml always, git-ignored`) and drop the owned/host lines. Rename the moved owned-tools comment banner (if it says "owned hosts") to "personal toolbelt (both OSes; Windows-only and Linux-only entries carry `os = [...]`)".
- `config.linux.toml`: the comment "Sudo-requiring state lives in config.host.toml (owned-only `host` token)" becomes "The sudo-requiring tables below (dnf, /etc files, their hooks) are skipped with `mise bootstrap --skip packages,files` where this host has no sudo (bootstrap.sh decides; vars.sudo)". The moved `config.host.toml` header comment and its "Dotfiles for Linux owned hosts only" banner become "Linux-only dotfiles (gdb, herdr, zed): dead files on Windows".
- Check with `python3 -c "import tomllib; [tomllib.load(open(f,'rb')) for f in ('config.toml','config.linux.toml')]"` that both still parse (one table per name).

- [ ] **Step 4: `mise-env.sh` emits the OS token**

Replace the top of `scripts/lib/mise-env.sh` (keep the `--write` block and the final `echo` unchanged):
```bash
#!/usr/bin/env bash
# mise-env.sh [--write] — the MISE_ENV token set for THIS Linux host: `linux`.
# Every host gets the same setup; the token only selects config.linux.toml
# (bootstrap.ps1 writes `windows` on Windows). --write also saves it to
# ~/.config/mise/miserc.toml (git-ignored). Every mise process reads that file
# (shells, shims under systemd, cron), so nothing exports MISE_ENV. An exported
# MISE_ENV still wins over miserc (CI and check-templates.sh set one).
set -euo pipefail
tokens="linux"
```
and change `if [ "${2:-}" = --write ]; then` to `if [ "${1:-}" = --write ]; then`.

Callers (find them all with `rg -n 'mise-env.sh' --glob '!docs/**'`):
- `bootstrap.sh` main: `TOKENS="$("$REPO_DIR/scripts/lib/mise-env.sh" --write)"`.
- `tasks/update`: `tokens="$("$root/scripts/lib/mise-env.sh" --write)"` (the mode check above it stays until Task 3).
- `tasks/health`: `canonical_env=$("$root/scripts/lib/mise-env.sh" 2>/dev/null)` placed unconditionally (delete the `case "$mode"` wrapper around it; the mode row stays until Task 4).

- [ ] **Step 5: `bootstrap.ps1`**

- `$MiseEnvTokens = @("windows")`.
- `Initialize-MiseEnv`: body header `"# Written by bootstrap.ps1 (Windows' token set).`n..."`.
- The guard after `config ls`: match `config\.windows\.toml` and fail with:
  ```powershell
  Write-Fail "mise did not load config.windows.toml, so miserc.toml (windows) was not honoured -- -RepoPath outside %USERPROFILE%\.config\mise? Stopping before mise bootstrap/prune; 'mise -C `$env:USERPROFILE config ls' shows what loaded."
  ```
  and update the comment above it ("Without config.windows.toml loaded (miserc.toml ignored), the Windows dotfiles and winget apps would be skipped and `mise prune` could remove Windows-only tools").
- The node declaration: `config get -f (Join-Path $RepoPath "config.toml") tools.node` and the warning text "could not read tools.node from config.toml".
- Verify the BOM: `head -c3 bootstrap.ps1 | xxd` → `efbb bf`.

- [ ] **Step 6: Run the PowerShell tests; they pass**

Run the Task 1 step 4 PowerShell command. Expected: passed on 7.x and 5.1.

- [ ] **Step 7: vcpkg block on every Linux host (parity pair)**

In `dotfiles/zshrc.tera` and `dotfiles/bashrc.tera`, delete the line `{% if vars.mode is defined and vars.mode == "owned" %}` and its matching `{% endif %}` (the first `{% endif %}` after it at the same nesting), keeping the block between; change the comment "vcpkg (Microsoft C/C++ package manager) — owned hosts only." to "vcpkg (Microsoft C/C++ package manager), cloned by `mise run vcpkg` on every Linux host." In both files' `alias devtoys=` comment drop "(owned-only install; harmless "command not found" on a shared host ...)" down to "# DevToys CLI".

- [ ] **Step 8: Regenerate the locks**

```bash
L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"; TOK="$(gh auth token)"
for pe in "linux-x64 linux" "windows-x64 windows"; do
  set -- $pe
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV="$2" MISE_LOCKED=0 MISE_GITHUB_TOKEN="$TOK" mise lock --global --platform "$1")
done
rm -rf "$L"
if [ -d .mise/locks ]; then mkdir -p locks && cp -a .mise/locks/. locks/ && rm -r .mise && sed -i 's#path = "\.mise/locks/#path = "locks/#g' mise.lock mise.linux.lock; fi
git rm -q mise.owned.lock; git rm -rq locks/mise.owned
git status --short mise*.lock locks/
```
Expected: `mise.lock` now holds the former owned entries (node, go, gopls, LSPs, basedpyright with `uv = { path = "locks/mise/pypi-basedpyright/..." }`, opencode, omp, pwndbg, nerd-fonts, ccstatusline, herdr, DevToys, nushell, carapace, dnGrep, LogExpert); `locks/mise/pypi-basedpyright/<ver>/` exists. If `git rm` reports `mise.owned.lock` already gone, that is fine.

- [ ] **Step 9: Every consumer of the old files and tokens**

Find them: `rg -n 'config\.owned|config\.host|mise\.owned|linux,owned|windows,owned|locks/mise\.owned' --glob '!docs/superpowers/**' --glob '!*.lock' --glob '!.remember/**' .` Then:
- `scripts/check-invariants.sh`:
  - `check_pins`: `config.owned.toml` → `config.toml` (typescript and typescript-language-server lines and the message).
  - `check_mise_config_files`: file list `config.toml config.linux.toml mise.lock mise.linux.lock`; `lockmap = {"config.toml": "mise.lock", "config.linux.toml": "mise.linux.lock"}`; loop `(("config.toml", True), ("config.linux.toml", False))`; the two hint strings use `MISE_ENV=linux` and `MISE_ENV=windows`.
  - Replace the `config.host.toml` "declares no [tools]" block with a placement check (keep it inside the `$PY` branch):
    ```bash
        if "$PY" - <<'PY'
    import sys, tomllib
    def pkgs(f):
        with open(f, "rb") as fh:
            return tomllib.load(fh).get("bootstrap", {})
    bad = []
    for f in ("config.toml", "config.windows.toml"):
        b = pkgs(f)
        bad += [f"{f}:{k}" for k in b.get("packages", {}) if k.startswith("dnf:")]
        bad += [f"{f}:[bootstrap.files]" for _ in [1] if b.get("files")]
    bad += [f"config.linux.toml:{k}" for k in pkgs("config.linux.toml").get("packages", {}) if k.startswith("winget:")]
    print("; ".join(bad)); sys.exit(1 if bad else 0)
    PY
        then
          ok "dnf: packages and [bootstrap.files] only in config.linux.toml; winget: only in config.windows.toml"
        else
          bad "system-state tables in the wrong file (dnf/files belong in config.linux.toml, winget in config.windows.toml)"
        fi
    ```
  - The `XDG_CONFIG_HOME="$tmp" MISE_ENV=linux,owned,host mise config ls` check: `MISE_ENV=linux`.
  - The sidecar loops `mise.lock mise.linux.lock mise.owned.lock` → `mise.lock mise.linux.lock` (both places).
  - `check_bootstrap_config`: header `(config.linux/windows.toml)`; `files = ["config.linux.toml", "config.windows.toml"]`; every `for cf in [...]` list becomes `["config.toml", "config.linux.toml", "config.windows.toml"]`; the dnf loop `for f in ("config.linux.toml",):` with message "in config.linux.toml"; the shared-safety block checks `for f in ("config.toml",):` with PASS text "config.toml carries no [bootstrap] table (both OSes load it; system state lives in the OS files)"; the bootstrap-plan check uses `MISE_ENV=linux` in the command and both messages.
  - `check_dotfiles_config`: header `(config.toml/linux/windows.toml [dotfiles])`; `files = ["config.toml", "config.linux.toml", "config.windows.toml"]`; the comment "config.host.toml is listed so its gdb/herdr entries..." becomes "config.linux.toml holds the Linux-only gdb/herdr/zed entries".
- `scripts/check-templates.sh`:
  - `FILES = ["config.toml", "config.linux.toml", "config.windows.toml"]`.
  - `ENVS=("linux" "windows")`.
  - `make_home`: drop `mode=shared` / the `case ",$env," in *,owned,*` line and any `mode = ` written into the scratch `config.local.toml` (keep name/email if it writes them).
  - The VCPKG assertion: a Linux render (`",$env," == *,linux,*`) of `~/.zshrc`/`~/.bashrc` must contain `VCPKG_ROOT`; message "rendered without the VCPKG_ROOT block"; delete the shared branch. Update the comment above to "The vcpkg block is in every Linux render."
- `scripts/bump-versions.sh`: comments listing `config.owned.toml` → drop it; `go_pin`, `node_line` and the postinstall `perl -i` / `grep -qF` lines read `config.toml`; bumped-summary text `(config.toml node postinstall)`; `normalize_lock_sidecars` list `"$ROOT/mise.lock" "$ROOT/mise.linux.lock"`; `mise_global linux,owned,host` → `mise_global linux` (three places); `lock_platform windows,owned windows-x64` → `lock_platform windows windows-x64`.
- `scripts/gen-tool-memory.sh`: drop the `("Owned-host tools (config.owned.toml)", "config.owned.toml")` section (its tools now print under the `config.toml` section, retitled "Cross-platform tools (config.toml; Windows-only and Linux-only entries carry os)"); the dnf section reads `config.linux.toml` and is titled "System packages (dnf, Linux; skipped without sudo)"; header comments follow.
- `scripts/lib/mise-install.sh`: `mise config get -f "$repo/config.toml" tools.node` and its warning; the comment "since PR2 is config.host.toml (it declares no tools)" becomes "is config.linux.toml (it declares no node)".
- `scripts/test-check-pins.sh`: `files=(... config.toml config.linux.toml ...)` without `config.owned.toml`; the two `sed` cases target `"$T/config.toml"`.
- `scripts/test-mise-install.sh`: `MISE_ENV=linux`.
- `.claude/hooks/test-hooks.sh`: the parity case uses `config.linux.toml` ("config.linux.toml -> silent"); the worktree `cp` copies `"$ROOT/config.toml" "$ROOT/config.linux.toml" "$ROOT/config.windows.toml"` (it still lists the deleted `config.native.toml` today).
- `.github/workflows/lint.yml`: the comment "Windows-only nushell pin in config.owned.toml" → "in config.toml".
- `.github/workflows/disk-budget.yml`: the Linux job's `MISE_ENV: linux`; the Windows job's `MISE_ENV: windows`.
- Regenerate the TOOLS block: `PATH="$(dirname "$(mise -C ~ which python)"):$PATH" scripts/gen-tool-memory.sh`.

- [ ] **Step 10: Old token sets still load (Review Focus 4)**

```bash
L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"
for t in linux linux,owned,host linux,owned,host,wsl windows,owned; do
  printf '%s: ' "$t"; (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=$t mise config ls 2>&1 | grep -o 'config\.[a-z]*\.toml\|config\.toml' | sort -u | tr '\n' ' '); echo
done; rm -rf "$L"
```
Expected: every Linux set lists `config.toml config.linux.toml` (plus `config.local.toml`), `windows,owned` lists `config.toml config.windows.toml`; no ERROR lines.

- [ ] **Step 11: Fresh isolated install and checks**

```bash
S=$SCRATCH/single; rm -rf $S && mkdir -p $S/home; L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"
m() { (cd /tmp && env HOME=$S/home XDG_DATA_HOME=$S/home/.local/share XDG_CACHE_HOME=$S/home/.cache XDG_STATE_HOME=$S/home/.local/state GOPATH=$S/home/go XDG_CONFIG_HOME="$L" MISE_ENV=linux MISE_GITHUB_TOKEN="$(gh auth token)" MISE_YES=1 "$@"); }
m mise install 2>&1 | tail -1
m env WORKSTATION_GLIBC_FLOOR=2.28 bash ~/.config/mise/tasks/verify-tools | tail -1
m bash ~/.config/mise/tasks/verify-tools | tail -1
git -C ~/.config/mise status --short | grep -v '^[MADR] ' ; chmod -R u+w $S; rm -rf $S "$L"
```
Expected: `installed 101 tools` (or all already installed), both verify-tools lines `✓ verify-tools: N ELF binaries pass`, and no unexpected repo changes.
Run: `mise run lint`, `bash scripts/check-templates.sh` (2 sets), `bash scripts/test-mise-install.sh`, `bash .claude/hooks/test-hooks.sh` → all pass.

- [ ] **Step 12: Commit**

```bash
git add -A config.toml config.linux.toml config.owned.toml config.host.toml mise.lock mise.linux.lock mise.owned.lock locks scripts bootstrap.sh bootstrap.ps1 tasks dotfiles .claude/hooks/test-hooks.sh .github
git commit -m "Fold config.owned.toml and config.host.toml; OS-only token sets"   # body: what moved where, the token sets, the lock regeneration; then the trailers
```
(`git add -A` with explicit paths stages deletions too; check `git status --short` shows nothing left unstaged.)

---

### Task 3: `bootstrap.sh` and `mise run update` without a mode; sudo detection

**Files:**
- Modify: `bootstrap.sh`
- Modify: `tasks/update`
- Create: `scripts/test-bootstrap.sh` (from `scripts/test-bootstrap-mode.sh`, which is deleted)
- Modify: `scripts/check-invariants.sh` (`check_bootstrap_mode` → `check_bootstrap`)

**Interfaces:**
- Consumes: `mise-env.sh [--write]` (Task 2).
- Produces (all in `bootstrap.sh`, callable with `WORKSTATION_BOOTSTRAP_LIB=1`):
  - `config_unset <file> <key>`: drop `<key>` from `[vars]`; no-op when absent.
  - `sudo_state <file>`: prints `no` when `vars.sudo` is `no`, else `yes`.
  - `detect_sudo`: returns 0 (sudo works), 1 (no sudo: no binary, or the prompt failed), 2 (undecided: no terminal and no cached credentials).
  - `resolve_system_steps`: sets `SYSTEM=yes|no`; saves `sudo = "yes"|"no"` only for return codes 0/1.
  - `SYSTEM` is read by `apply` (skip flags) and `main` (login shell).

- [ ] **Step 1: Write the new tests**

`git mv scripts/test-bootstrap-mode.sh scripts/test-bootstrap.sh`, then:
- Header: "Offline tests for bootstrap.sh: identity prompts and the config.local.toml writer, the sudo decision (stubbed sudo), the --reinstall confirmation."
- `run` prints `SYSTEM=$SYSTEM` after `resolve_system_steps` instead of `MODE`: its inner command becomes `'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; resolve_system_steps; echo "SYSTEM=$SYSTEM"'`.
- A stub `sudo` on PATH:
  ```bash
  mkdir -p "$T/bin"
  cat >"$T/bin/sudo" <<'EOF'
  #!/usr/bin/env bash
  echo "sudo $*" >>"${FAKE_SUDO_LOG:-/dev/null}"
  case "$1" in
  -n) exit "${FAKE_SUDO_N:-1}" ;;   # -n true: cached / NOPASSWD?
  -v) exit "${FAKE_SUDO_V:-1}" ;;   # the password prompt
  esac
  exit 0
  EOF
  chmod +x "$T/bin/sudo"
  export PATH="$T/bin:$PATH"
  ```
- Delete cases 1–5, 7 and 12's mode parts. New cases (identity input `$'Ann\nann@x'` where a terminal is needed):
  ```bash
  # S1. sudo -n works: yes, saved, no prompt.
  mkdir -p "$T/s1"; : >"$T/sudo.log"
  out=$(run "$T/s1" - FAKE_SUDO_N=0 FAKE_SUDO_LOG="$T/sudo.log") || fail "S1: exit — $out"
  grep -q '^SYSTEM=yes$' <<<"$out" || fail "S1: $out"
  grep -q '^sudo = "yes"$' "$T/s1/config.local.toml" || fail "S1: sudo = yes not saved"
  grep -q 'sudo -v' "$T/sudo.log" && fail "S1: prompted although sudo -n worked"
  # S2. terminal, prompt succeeds: yes, saved.
  mkdir -p "$T/s2"
  out=$(run "$T/s2" $'Ann\nann@x' FAKE_SUDO_N=1 FAKE_SUDO_V=0) || fail "S2: exit — $out"
  grep -q '^SYSTEM=yes$' <<<"$out" || fail "S2: $out"
  grep -q '^sudo = "yes"$' "$T/s2/config.local.toml" || fail "S2: not saved"
  # S3. terminal, prompt fails: no, saved, warning names how to apply later.
  mkdir -p "$T/s3"
  out=$(run "$T/s3" $'Ann\nann@x' FAKE_SUDO_N=1 FAKE_SUDO_V=1) || fail "S3: exit — $out"
  grep -q '^SYSTEM=no$' <<<"$out" || fail "S3: $out"
  grep -q '^sudo = "no"$' "$T/s3/config.local.toml" || fail "S3: no not saved"
  grep -q 're-run ./bootstrap.sh' <<<"$out" || fail "S3: no how-to: $out"
  # S4. no terminal, no cached sudo: no for this run, nothing saved.
  mkdir -p "$T/s4"
  out=$(run "$T/s4" - FAKE_SUDO_N=1) || fail "S4: exit — $out"
  grep -q '^SYSTEM=no$' <<<"$out" || fail "S4: $out"
  grep -q '^sudo = ' "$T/s4/config.local.toml" 2>/dev/null && fail "S4: saved a decision without asking"
  # S5. no sudo binary: no, saved.
  mkdir -p "$T/s5" "$T/nosudo"; for c in awk sed grep mktemp mv mkdir dirname cat; do ln -sf "$(command -v $c)" "$T/nosudo/$c"; done
  out=$(env PATH="$T/nosudo" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$T/s5" "$(command -v setsid)" -w "$(command -v bash)" -c 'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_system_steps; echo "SYSTEM=$SYSTEM"' "$root/bootstrap.sh" </dev/null 3<&- 2>&1) || fail "S5: exit — $out"
  grep -q '^SYSTEM=no$' <<<"$out" || fail "S5: $out"
  # S6. sudo_state: missing means yes; saved no is no.
  printf '[vars]\nname = "N"\n' >"$T/s6.toml"
  [ "$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; sudo_state "$1"' "$root/bootstrap.sh" "$T/s6.toml")" = yes ] || fail "S6: missing is not yes"
  printf '[vars]\nsudo = "no" # no sudo here\n' >"$T/s6.toml"
  [ "$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; sudo_state "$1"' "$root/bootstrap.sh" "$T/s6.toml")" = no ] || fail "S6: saved no not read"
  # T1. the stale mode line is dropped (indented, commented, CRLF), the rest kept; WORKSTATION_MODE is ignored with a note.
  mkdir -p "$T/t1"; printf '[vars]\r\n  mode = "owned" # laptop\r\nname = "N"\r\nemail = "e@x"\r\n' >"$T/t1/config.local.toml"
  out=$(run "$T/t1" - FAKE_SUDO_N=0 WORKSTATION_MODE=shared) || fail "T1: exit — $out"
  grep -q 'mode' "$T/t1/config.local.toml" && fail "T1: mode line kept: $(cat "$T/t1/config.local.toml")"
  grep -q '^name = "N"' "$T/t1/config.local.toml" || fail "T1: name lost"
  grep -q 'WORKSTATION_MODE is no longer used' <<<"$out" || fail "T1: no note for WORKSTATION_MODE: $out"
  ```
- Keep case 6 (config_set) but use key `sudo` instead of `mode`; keep 8 (pty), changing its inner command to `resolve_host_config; echo probe >&2`, its input to `'A\na@x\n'` and its assertions to the name prompt (`grep -q 'Name:'`) and `probe`; keep 9 with key `sudo`; keep 10 (confirm_reinstall); keep 11 (hand-edited TOML) minus the `run`/`MODE` lines at its end.
- Case 12 becomes: `--reinstall` without a terminal still wipes (no mode to ask), and the "Will REMOVE" list says `config.local.toml (name, email, sudo)`:
  ```bash
  mkdir -p "$T/c12/repo" && : >"$T/c12/repo/config.local.toml"
  out=$(reinstall "$T/c12/repo") || fail "--reinstall failed: $out"
  grep -q 'REINSTALL-DONE' <<<"$out" || fail "--reinstall did not finish: $out"
  grep -q 'config.local.toml (name, email, sudo)' <<<"$out" || fail "--reinstall REMOVE list: $out"
  [ ! -e "$T/c12/repo" ] || fail "--reinstall did not wipe the checkout"
  ```
- Final line: `echo "PASS: bootstrap.sh identity prompts, sudo decision (cached, prompt ok/fail, no terminal, no binary, saved state), stale mode cleanup, pty stderr safety, CRLF header, config.local.toml writer, hand-edited TOML, --reinstall"`.

`scripts/check-invariants.sh`: rename `check_bootstrap_mode` → `check_bootstrap` (definition and the call near the end), header `"bootstrap.sh (scripts/test-bootstrap.sh)"`, run `bash scripts/test-bootstrap.sh`, failure text names the new file.

- [ ] **Step 2: Run them; they fail**

Run: `bash scripts/test-bootstrap.sh`
Expected: FAIL at S1 (`resolve_system_steps: command not found`).

- [ ] **Step 3: Implement in `bootstrap.sh`**

- Header comment (lines 10–13): "Every host gets the same setup. The steps that need sudo (dnf packages, /etc files, zsh as login shell) run when sudo works and are skipped, with a warning, when it doesn't; see resolve_system_steps."
- `usage()`: replace the mode paragraph with:
  ```
  Sets up this host with mise: the toolbelt, dotfiles and, where sudo works,
  system packages, /etc files and zsh as login shell. Without sudo those are
  skipped (the result is saved as sudo = "no" in ~/.config/mise/config.local.toml;
  re-run with sudo to apply them).
  ```
- Delete `valid_mode` and `prompt_mode`.
- After `config_set`, add `config_unset` (same tolerant `[vars]` matching as `config_set`):
  ```bash
  config_unset() { # config_unset <file> <key> — drop <key> from [vars]; no-op when absent
    local file=$1 key=$2 tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    KEY="$key" awk '
      /^[[:space:]]*\[/ {
        in_vars = ($0 ~ /^[[:space:]]*\[[[:space:]]*vars[[:space:]]*\][[:space:]]*(#.*)?\r?$/)
        print; next
      }
      in_vars {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (index(line, ENVIRON["KEY"]) == 1 && substr(line, length(ENVIRON["KEY"]) + 1) ~ /^[[:space:]]*=/) next
      }
      { print }' "$file" >"$tmp" && mv "$tmp" "$file"
  }
  ```
- Add the sudo functions after `open_prompt_fd`:
  ```bash
  # sudo_state <file>: the saved decision; a missing value means yes (hosts set up
  # before the decision was saved all had sudo).
  sudo_state() {
    [[ "$(config_get "$1" sudo)" == no ]] && echo no || echo yes
  }

  # detect_sudo: 0 sudo works, 1 it doesn't (no binary, or the password prompt
  # failed), 2 undecided (no terminal to ask on and no cached credentials).
  # sudo -v reads the password from the terminal itself, and the credentials it
  # caches cover mise's own sudo calls for the rest of the run.
  detect_sudo() {
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true 2>/dev/null && return 0
    open_prompt_fd || return 2
    sudo -v && return 0
    return 1
  }

  # resolve_system_steps: SYSTEM=yes|no for this run. A real answer is saved as
  # vars.sudo, so `mise run update` never has to ask; "no terminal" decides
  # nothing beyond this run.
  resolve_system_steps() {
    local cfg="$REPO_DIR/config.local.toml" rc=0
    detect_sudo || rc=$?
    case "$rc" in
    0) SYSTEM=yes && config_set "$cfg" sudo yes ;;
    1) SYSTEM=no && config_set "$cfg" sudo no ;;
    *) SYSTEM=no ;;
    esac
    if [[ "$SYSTEM" == no ]]; then
      warn "No sudo here — skipping the system steps: dnf packages, /etc files, zsh as login shell."
      warn "  Everything user-level still installs. To apply them later: get sudo, then re-run ./bootstrap.sh"
    fi
  }
  ```
- `resolve_host_config`: delete the mode half (from `MODE=$(config_get` through `config_set "$cfg" mode "$MODE"`) and insert at its top:
  ```bash
    if [[ -n "$(config_get "$cfg" mode)" ]]; then
      config_unset "$cfg" mode
      ok "dropped the old mode line from config.local.toml (every host gets the same setup now)"
    fi
    if [[ -n "${WORKSTATION_MODE:-}" ]]; then
      warn "WORKSTATION_MODE is no longer used (every host gets the same setup) — ignored"
    fi
  ```
  and its comment: "Name/email are asked on a first run; ...". Keep the name/email logic unchanged.
- `apply()`: replace the `if [[ "$MODE" == "owned" ]]` log with a skip list and pass it:
  ```bash
    local skip_flags=()
    if [[ "$SYSTEM" == no ]]; then
      skip_flags=(--skip packages,files)
      log "skipping the system steps (no sudo): mise bootstrap --skip packages,files"
    fi
    if ! mise bootstrap --yes "${dotfiles_flags[@]}" "${skip_flags[@]}"; then
  ```
  and the APPLY comment's "Sudo (owned hosts only)" sentence becomes "Sudo is scoped to the dnf batch and /etc files inside mise's own elevation, and skipped entirely when SYSTEM=no."
- `set_login_shell` comment: "Only when SYSTEM=yes (it needs sudo usermod)."
- `print_next_steps`: the "On shared hosts set_login_shell never runs" sentence becomes "Without sudo set_login_shell never runs"; the statusline tip prints unconditionally (drop `if [[ "$MODE" == owned ]]`).
- `do_reinstall`: the REMOVE line says `config.local.toml (name, email, sudo) — asked again after the wipe`; delete the "The wipe takes the saved mode with it" block (the `WORKSTATION_MODE`/`open_prompt_fd` check).
- `main`: after `resolve_host_config`, call `resolve_system_steps` (before closing fd 3), then:
  ```bash
    TOKENS="$("$REPO_DIR/scripts/lib/mise-env.sh" --write)"
    ...
    apply
    if [[ "$SYSTEM" == yes ]]; then
      set_login_shell
    fi
    # ccstatusline setup — interactive prompt for the Claude Code statusline.
    # Re-runnable any time via `mise run statusline`.
    if [[ -t 0 ]]; then
      mise run statusline || true
    fi
  ```
  The fd 3 lines around them stay: `{ exec 3<&-; } 2>/dev/null || true; resolve_host_config; resolve_system_steps; { exec 3<&-; } 2>/dev/null || true`.

- [ ] **Step 4: `tasks/update`**

Replace its body after `git -C "$root" pull --ff-only`:
```bash
#!/usr/bin/env bash
#MISE description="git pull --ff-only, then mise install + mise bootstrap (system steps skipped where this host has no sudo)"
set -euo pipefail
root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

git -C "$root" pull --ff-only

# miserc.toml from mise-env.sh (the OS token set), then drop any exported
# MISE_ENV (it would override miserc and could make mise-install.sh's
# `mise prune` remove tools).
tokens="$("$root/scripts/lib/mise-env.sh" --write)"
unset MISE_ENV
printf '==> config set %s (miserc.toml)\n' "$tokens"

cfg="$root/config.local.toml"
lib() { WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$1"; shift; "$@"' _ "$root/bootstrap.sh" "$@"; }
# One-time tidy-up of the two-mode era's `mode` line.
if [ -n "$(lib config_get "$cfg" mode)" ]; then
  lib config_unset "$cfg" mode
  printf ' ✓ dropped the old mode line from config.local.toml\n'
fi
skip=()
if [ "$(lib sudo_state "$cfg")" = no ]; then
  skip=(--skip packages,files)
  printf ' ! sudo = "no" in config.local.toml: skipping the system steps (dnf, /etc files); re-run %s/bootstrap.sh with sudo to apply them\n' "$root"
fi

"$root/scripts/lib/mise-install.sh"
mise bootstrap --yes "${skip[@]}"
```
Add to `scripts/test-bootstrap.sh` (stub `git`, `mise` and `mise-install.sh` by running a copy of `tasks/update` in a temp repo):
```bash
# U1/U2. tasks/update: drops a stale mode line and runs the full bootstrap when
# sudo is unset; passes --skip packages,files when sudo = "no".
U="$T/u"; mkdir -p "$U/repo/tasks" "$U/repo/scripts/lib" "$U/bin"
cp "$root/tasks/update" "$U/repo/tasks/update"; cp "$root/bootstrap.sh" "$U/repo/"; cp "$root/scripts/lib/mise-env.sh" "$U/repo/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/repo/scripts/lib/mise-install.sh"; chmod +x "$U/repo/scripts/lib/mise-install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/bin/git"; printf '#!/usr/bin/env bash\necho "mise $*" >>"%s/mise.log"\n' "$U" >"$U/bin/mise"; chmod +x "$U/bin/git" "$U/bin/mise"
printf '[vars]\nmode = "owned"\nname = "N"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"; env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" bash -c 'mkdir -p "$XDG_CONFIG_HOME/mise"; "$0"' "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U1: update failed"
grep -q 'mode' "$U/repo/config.local.toml" && fail "U1: mode line kept"
grep -qx 'mise bootstrap --yes' "$U/mise.log" || fail "U1: expected a full bootstrap: $(cat "$U/mise.log")"
printf '[vars]\nsudo = "no"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"; env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U2: update failed"
grep -qx 'mise bootstrap --yes --skip packages,files' "$U/mise.log" || fail "U2: expected the skip: $(cat "$U/mise.log")"
```

- [ ] **Step 5: Run the tests; they pass**

Run: `bash scripts/test-bootstrap.sh` → `PASS: bootstrap.sh identity prompts, sudo decision ...`
Run: `rg -n 'MODE|valid_mode|prompt_mode|vars\.mode' bootstrap.sh tasks/update` → only the `WORKSTATION_MODE` note in `resolve_host_config`.
Run: `shfmt -i 2 -d bootstrap.sh tasks/update scripts/test-bootstrap.sh`, `shellcheck -S warning bootstrap.sh tasks/update scripts/test-bootstrap.sh`, `mise run lint`, `bash scripts/check-templates.sh` → clean.

- [ ] **Step 6: Commit**

```bash
git add bootstrap.sh tasks/update scripts/test-bootstrap.sh scripts/test-bootstrap-mode.sh scripts/check-invariants.sh
git commit -m "bootstrap: one setup for every host; sudo decided once and remembered"   # body: the prompt gone, detect_sudo/resolve_system_steps, vars.sudo, the update skip; then the trailers
```

---

### Task 4: Health, the session hook, check-updates, Windows `config.local.toml`, and a no-mode guard

**Files:**
- Modify: `tasks/health`, `tasks/check-updates`
- Modify: `.claude/hooks/session-context.sh`, `.claude/hooks/test-hooks.sh`
- Modify: `bootstrap.ps1` (`Invoke-EnsureConfigLocal`, new `Remove-ConfigLocalVar`)
- Modify: `scripts/test-config-local.ps1`
- Modify: `scripts/check-invariants.sh` (new `check_no_mode`)

**Interfaces:**
- Consumes: `sudo_state`, `config_get` from `bootstrap.sh` (Task 3); `mise-env.sh` (Task 2).
- Produces: `Remove-ConfigLocalVar -Path <file> -Key <key>` in `bootstrap.ps1` (mirrors `config_unset`).

- [ ] **Step 1: Tests first**

`.claude/hooks/test-hooks.sh` session-context block — replace the two mode assertions:
```bash
printf 'env = ["linux"]\nauto_env = false\n' >"$SC/miserc.toml"
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "reports the miserc tokens" has 'env=linux'
ok "no mode in the report" lacks 'mode='
ok "no exported MISE_ENV -> no warning" lacks 'overrides miserc'
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')" MISE_ENV=linux
ok "exported MISE_ENV -> warned" has 'MISE_ENV=linux (exported; overrides miserc)'
printf '[vars]\nsudo = "no"\n' >"$SC/config.local.toml"
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "sudo = no -> reported" has 'sudo=no'
rm -f "$SC/config.local.toml" "$SC/miserc.toml"
```
(delete the old `linux-only miserc -> mode=shared` pair; keep the `no miserc -> miserc=missing` case after this.)

`scripts/test-config-local.ps1`: extract `Remove-ConfigLocalVar` too (`$wanted = 'Set-ConfigLocalVar', 'Remove-ConfigLocalVar', 'Invoke-EnsureConfigLocal'`) and change the cases:
- 'existing file: mode added, rest kept' → 'existing file: a stale mode line is dropped, rest kept': start from `"[vars]`nmode = `"owned`"`nname = `"N`"`nemail = `"e@x`"`n`n[dotfiles]`n...`"`; assert no `(?m)^\s*mode\s*=` line, `name = "N"` and `[dotfiles]` kept.
- 'missing file, non-interactive: created with [vars] mode, no BOM' → 'missing file, non-interactive: nothing written': assert `-not (Test-Path $cfg)` and `$script:warnMsg -like '*name / email*'`.
- 'empty file': `Invoke-EnsureConfigLocal` leaves it empty (`(Read-Cfg $cfg) -ceq ''`).
- The Set-ConfigLocalVar cases keep using key `mode` as a sample key (they test the writer, not the mode); rename none.
- New: 'Remove-ConfigLocalVar: indented, commented key in [vars] removed; other tables untouched':
  ```powershell
  $cfg = New-CaseDir 'remove'
  [System.IO.File]::WriteAllText($cfg, "[vars]`n  mode = `"owned`" # laptop`nname = `"N`"`n[other]`nmode = 1`n")
  Remove-ConfigLocalVar -Path $cfg -Key 'mode'
  Assert ((Read-Cfg $cfg) -ceq "[vars]`nname = `"N`"`n[other]`nmode = 1`n") "got: $(Read-Cfg $cfg)"
  ```

- [ ] **Step 2: Run them; they fail**

Run: `bash .claude/hooks/test-hooks.sh` → FAIL on "no mode in the report". Run the PowerShell command from Task 1 step 4 with `test-config-local.ps1` → FAIL.

- [ ] **Step 3: Implement**

`.claude/hooks/session-context.sh` `seg_host`: drop `mode` (local and logic, and the `printf ' mode=%s'` line); keep `envseg="env=$tokens"`; add after the MISE_ENV line:
```bash
  # sudo = "no" (saved by bootstrap.sh) means the system steps are skipped here.
  if grep -Eqs '^[[:space:]]*sudo[[:space:]]*=[[:space:]]*"no"' "$root/config.local.toml"; then
    envseg="$envseg sudo=no"
  fi
```
and update its header comment line 9 ("host identity & scope (hostname, miserc tokens, sudo=no where saved, an exported MISE_ENV, distro / EL family)").

`tasks/health`:
- Description: `"Read-only health report: config set, system steps, bootstrap state, mise tools, free disk, pueued, python-env, extras"`.
- Replace the mode block (from `# The saved mode is the source of truth` through the end of the `hdr "mode (config.local.toml)"` section's `miserc` row) with:
  ```bash
  cfg="$root/config.local.toml"
  canonical_env=$("$root/scripts/lib/mise-env.sh" 2>/dev/null)
  rc_tokens=$(sed -n 's/^env = \[\(.*\)\]$/\1/p' "$root/miserc.toml" 2>/dev/null | tr -d '" ')
  sudo_saved=$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$1"; config_get "$2" sudo' _ "$root/bootstrap.sh" "$cfg" 2>/dev/null)

  hdr "workstation health — config=${rc_tokens:-unset} · read-only"
  echo ""

  hdr "config set and system steps"
  if [ "$rc_tokens" = "$canonical_env" ]; then
    row_ok "miserc" "$root/miserc.toml selects $rc_tokens"
  else
    row_bad "miserc" "$root/miserc.toml has \"${rc_tokens:-<missing>}\", this host needs \"$canonical_env\" — mise run update"
  fi
  if [ "$sudo_saved" = no ]; then
    row_warn "system steps" "skipped: sudo = \"no\" in config.local.toml (dnf, /etc files, login shell) — re-run $root/bootstrap.sh with sudo"
  else
    row_ok "system steps" "applied${sudo_saved:+ (sudo = $sudo_saved)}"
  fi
  ```
  (the `MISE_ENV export` rows that follow stay.)
- Delete `canon_has` if `rg -n 'canon_has' tasks/health` finds no other caller.
- `# 7. owned-only extras`: drop `if [ "$mode" = owned ]; then` and its `fi`, retitle `hdr "extras"`.
- Comment on line 12 "(both modes)" → drop the parenthetical; line 229–230 "both modes" phrasing → "every Linux host".

`tasks/check-updates`: description "dnf (Linux hosts with dnf)"; replace the `case ",${MISE_ENV:-}," in *,host,*)` block with:
```bash
if command -v dnf >/dev/null 2>&1; then
  printf '\n==> dnf\n'
  dnf -q check-update | head -40 || true # exit 100 means updates exist; never fail
fi
```

`bootstrap.ps1`: add after `Set-ConfigLocalVar`:
```powershell
# Drop a key from [vars] (the same header and key tolerance as Set-ConfigLocalVar).
function Remove-ConfigLocalVar {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @([System.IO.File]::ReadAllText($Path) -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @(if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] }) }
    $out = New-Object System.Collections.Generic.List[string]
    $inVars = $false
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    foreach ($l in $lines) {
        if ($l -match '^\s*\[') { $inVars = $l -match '^\s*\[\s*vars\s*\]\s*(#.*)?$'; $out.Add($l); continue }
        if ($inVars -and $l -match $keyPattern) { continue }
        $out.Add($l)
    }
    $text = if ($out.Count) { ($out -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
```
and change `Invoke-EnsureConfigLocal`:
```powershell
# Name/email are asked once; a non-interactive run leaves them to the user. A stale
# mode line from the two-mode era is dropped.
function Invoke-EnsureConfigLocal {
    $target = Join-Path $RepoPath "config.local.toml"
    Remove-ConfigLocalVar -Path $target -Key 'mode'
    $text = if (Test-Path -LiteralPath $target) { [System.IO.File]::ReadAllText($target) } else { '' }
    $hasName = $text -match '(?m)^[ \t]*name[ \t]*='
    $hasEmail = $text -match '(?m)^[ \t]*email[ \t]*='
    if ($hasName -and $hasEmail) {
        Write-Ok "config.local.toml ready ($target)"
        return
    }
    ...the rest unchanged...
```
Check the BOM (`efbb bf`) and that no `$name:` drive-qualified string was introduced.

`scripts/check-invariants.sh`: add and call (next to `check_disk_budget`):
```bash
# One setup for every host: nothing reads a mode, and mise-env.sh emits only the OS token.
check_no_mode() {
  hdr "no owned/shared mode (templates, scripts, tasks)"
  local hits tokens
  # Real readers only: the one-time tidy-up (`config_get "$cfg" mode` then config_unset)
  # and the test fixtures are allowed.
  hits=$(git grep -n -E 'vars\.mode|valid_mode|prompt_mode|\$\{?MODE\b|mode = "(owned|shared)"' -- 'dotfiles/*.tera' 'dotfiles/**/*.tera' 'scripts/*.sh' 'scripts/lib/*.sh' 'tasks/*' '.claude/hooks/*.sh' ':!scripts/test-*' ':!scripts/check-invariants.sh' || true)
  tokens=$(bash scripts/lib/mise-env.sh 2>/dev/null)
  if [ -n "$hits" ]; then
    bad "something still reads a mode:"
    printf '%s\n' "$hits" | sed 's/^/       /'
  elif [ "$tokens" != linux ]; then
    bad "scripts/lib/mise-env.sh emits \"$tokens\" (want linux)"
  else
    ok "nothing reads a mode; mise-env.sh emits linux"
  fi
}
```
(`bootstrap.sh`'s `WORKSTATION_MODE is no longer used` note and the tidy-up's `config_get "$cfg" mode` don't match the pattern; if the check flags anything else, fix the reader, not the pattern.)

- [ ] **Step 4: Run the tests; they pass**

Run: `bash .claude/hooks/test-hooks.sh`, the PowerShell suites (`test-config-local.ps1` and `test-mise-env.ps1`, both shells), `mise run health 2>&1 | grep -E 'miserc|system steps|extras'` (read-only; expect `miserc` bad until this host's update rewrites it and `system steps ✓ applied`), `mise run lint`, `bash scripts/check-templates.sh` → pass.

- [ ] **Step 5: Commit**

```bash
git add tasks/health tasks/check-updates .claude/hooks/session-context.sh .claude/hooks/test-hooks.sh bootstrap.ps1 scripts/test-config-local.ps1 scripts/check-invariants.sh
git commit -m "health, session hook, check-updates and Windows config.local.toml without a mode"   # body: the rows changed, Remove-ConfigLocalVar, check_no_mode; then the trailers
```

---

### Task 5: Docs

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/claude/verification.md`, `dotfiles/claude/CLAUDE.md` (the text above the TOOLS block), `dotfiles/claude/skills/workstation-lsp/SKILL.md`, `dotfiles/config/cheat/cheatsheets/personal/workstation`, `dotfiles/gdbinit.tera` (comments), `scripts/setup-ccstatusline.sh`, `scripts/lib/enable-el-repos.sh`, `scripts/lib/vcpkg.sh`, `scripts/lib/claude-settings-merge.sh`, `tasks/fonts`, `tasks/vcpkg`, `tasks/optional-packages` (comments/descriptions)

- [ ] **Step 1: Find every remaining mention**

Run: `rg -n -i '\bowned\b|\bshared\b|config\.owned|config\.host|mise\.owned|WORKSTATION_MODE|vars\.mode|token set' README.md CLAUDE.md docs/claude dotfiles scripts tasks .claude --glob '!dotfiles/claude/CLAUDE.md' | grep -v -i 'shared (config|dir|lib|memory|cache)'` and the same for `dotfiles/claude/CLAUDE.md` outside the TOOLS block. Every hit about the mode is rewritten below; unrelated uses of "shared" (zellij, herdr, shared libraries) stay.

- [ ] **Step 2: README**

- Delete the "## Owned and shared hosts" section (mode table, "How the mode is chosen", token-set and token→file tables) and the "### Changing a host between owned and shared" troubleshooting entry.
- Add, where the owned/shared section was:
  ```markdown
  ## One setup, two OS files

  Every host gets the same setup. Three config files hold it, and miserc.toml (git-ignored, written by `scripts/lib/mise-env.sh` on Linux and `bootstrap.ps1` on Windows) picks the OS file:

  | File | Loads on | Holds |
  |---|---|---|
  | `config.toml` | every host | tools for both OSes (Windows-only and Linux-only entries carry `os = [...]`), `[vars]` pins, cross-platform dotfiles |
  | `config.linux.toml` | Linux | the Linux toolbelt, dnf packages, `/etc/wsl.conf`, hooks, Linux dotfiles |
  | `config.windows.toml` | Windows | Windows dotfiles, winget GUI apps |
  | `config.local.toml` | every host, git-ignored | name, email, `sudo`, per-host overrides |

  **System steps and sudo.** dnf packages, `/etc` files and zsh as the login shell need sudo. `bootstrap.sh` checks once: cached sudo or a password prompt that succeeds means they run; a failed prompt saves `sudo = "no"` in `config.local.toml`, and from then on `bootstrap.sh`, `mise run update` and `wsu` skip them (`mise bootstrap --skip packages,files`) while everything user-level still installs. An unattended run with no terminal skips them for that run only. To apply them later, get sudo and re-run `./bootstrap.sh`. `mise run health` shows the state in its "system steps" row.
  ```
- Setup: drop the "Interactive — asks owned or shared" / `WORKSTATION_MODE=shared` lines (one `curl ... | bash` line stays); bootstrap steps list: step 4 "Resolve the mode..." becomes "Ask your name and email once (saved in `config.local.toml`) and decide the system steps (sudo; see above)", step 6 "Owned hosts only: set zsh as the login shell" becomes "With sudo: set zsh as the login shell"; "Both modes are idempotent" → "It is idempotent".
- Owned extras paragraph: "an owned host is offered the Claude Code status line" → "the bootstrap offers the Claude Code status line"; "so they run on owned Linux hosts only" → "on Linux hosts".
- Repo layout block: list `config.toml, config.linux.toml, config.windows.toml` and `config.local.toml`.
- Disk prerequisite sentence: "the host type's figure ... (a fresh owned host needs about 6.7 GB, a shared one about 3.6 GB)" → "the `linux` figure ... (about 6.9 GB fresh)".
- Adding things: "`config.linux.toml` is the Linux toolbelt (both modes), `config.owned.toml` is owned-only (...)" → "`config.toml` holds tools for both OSes (add `os = ["linux"]` or `os = ["windows"]` for single-OS ones) and `config.linux.toml` the Linux toolbelt"; "A dnf package. One line in `config.host.toml`" → "in `config.linux.toml`"; the `/etc` file example says `# config.linux.toml`; "A dotfile ... (cross-platform in `config.toml`, Linux `config.linux.toml`, Windows `config.windows.toml`, owned-only ..., Linux-owned-only ...)" → the three files.
- Health paragraph: "the saved mode" → "the config set and the system steps"; "owned extras (Claude Code, vcpkg, fonts)" → "extras (Claude Code, vcpkg, fonts)"; "it refuses to run without a valid saved mode" → delete.
- Keep `wc -l README.md` ≤ 600.

- [ ] **Step 3: CLAUDE.md**

- Opening paragraph: "`workstation` provisions Linux hosts (owned or shared) and one Windows host" → "Linux hosts and one Windows host".
- Layout table: three files plus `config.local.toml`, per the README table; token sets: "Linux `linux`, Windows `windows` (from `scripts/lib/mise-env.sh` and `bootstrap.ps1`)"; locks: `mise.lock`, `mise.linux.lock`.
- Invariants:
  - "Shared hosts load no host state. Every sudo-needing table lives in `config.host.toml`, which declares no `[tools]`..." → "Sudo-needing tables (dnf, `[bootstrap.files]`) live only in `config.linux.toml`; without sudo they're skipped with `--skip packages,files` (`vars.sudo`, decided by `bootstrap.sh`). A WSL-only step checks `is_wsl` at run time."
  - "Owned-only steps hang off `config.host.toml`'s `final` hook" → "Linux-only steps hang off `config.linux.toml`'s `final` hook (vcpkg, claude, fonts)".
  - Replace the whole "**Mode and `MISE_ENV`**" block with:
    ```markdown
    **`MISE_ENV` and sudo**
    - One setup for every host; no mode. `scripts/lib/mise-env.sh --write` writes the git-ignored
      `miserc.toml` (`env = ["linux"]`); `bootstrap.ps1` writes `["windows"]`. Every mise process reads it;
      nothing exports `MISE_ENV` (`bootstrap.sh`, `bootstrap.ps1` and `tasks/update` unset it; CI and
      `check-templates.sh` may pin one). `check_no_mode` keeps a mode from coming back.
    - `vars.sudo` (`config.local.toml`) is written only by `bootstrap.sh`; missing means yes.
    ```
    and keep the `mise -C` pinning bullet that followed.
  - "Windows" bullet "No User `MISE_ENV`; it stops before `mise bootstrap`/prune unless `config.owned.toml` loads." → "unless `config.windows.toml` loads."
- Generated blocks list: unchanged. Values-in-several-places list: unchanged.
- Check `wc -c CLAUDE.md` ≤ 14000.

- [ ] **Step 4: Everything else**

- `docs/claude/verification.md`: token sets "`linux` and `windows`"; the lock recipe's `MISE_ENV=linux` / `MISE_ENV=windows`.
- `dotfiles/claude/CLAUDE.md` (above the TOOLS block): "come from mise (`config.owned.toml`, installed by `./bootstrap.sh` in owned mode)" → "come from mise (`config.toml`, installed by `./bootstrap.sh`)". Regenerate the TOOLS block afterwards.
- `dotfiles/claude/skills/workstation-lsp/SKILL.md`: "(`config.owned.toml`, installed by `mise bootstrap` / `./bootstrap.sh` on an owned host; ...)" → "(`config.toml`, installed by `mise bootstrap` / `./bootstrap.sh`; ...)".
- Cheat sheet `workstation`: "./bootstrap.sh  # asks: owned ... or shared ..." → "./bootstrap.sh  # one setup; system steps need sudo (skipped without)"; delete the `WORKSTATION_MODE=shared` line; "dnf check-update (owned)" → "dnf check-update (where dnf exists)"; "(rlwrap on owned hosts)" → "(rlwrap, a dnf package)".
- `dotfiles/gdbinit.tera` comments: "in config.host.toml (owned+host gated), so they never deploy on shared hosts" → "in config.linux.toml (Linux only)"; "(a mise tool, config.owned.toml)" → "(a mise tool, config.toml)".
- `scripts/setup-ccstatusline.sh`, `scripts/lib/enable-el-repos.sh`, `scripts/lib/vcpkg.sh`, `scripts/lib/claude-settings-merge.sh`, `tasks/fonts`, `tasks/vcpkg`, `tasks/optional-packages`: comment/description wording only: "owned host(s)" → "Linux host(s)" or drop; `config.owned.toml` → `config.toml`; `config.host.toml` → `config.linux.toml`; "owned-gated" → "Linux".

- [ ] **Step 5: Verify and commit**

Run: the Step 1 `rg` again (only unrelated "shared" hits remain), `wc -c CLAUDE.md` (≤ 14000), `wc -l README.md` (≤ 600), `mise run lint`, `bash scripts/check-templates.sh`.
```bash
git add README.md CLAUDE.md docs/claude/verification.md dotfiles scripts tasks
git commit -m "docs: one setup for every host"   # body: README/CLAUDE.md sections replaced; then the trailers
```

---

### After the tasks (controller)

1. Push, open the PR (body: spec link, what changed, verification), wait for CI (lint, templates, PowerShell, windows-http, disk-budget with the `linux`/`windows` jobs).
2. After merge (user says "merge it"): `mise run update` here (expect `miserc` → `linux`, the mode line dropped, NFS packages installed, health clean); `wsu` then `bootstrap.ps1` on Windows (expect `miserc` → `windows`, the mode line dropped); the user bootstraps `atc-cache-dev10` (expect the sudo prompt, then the full install).
