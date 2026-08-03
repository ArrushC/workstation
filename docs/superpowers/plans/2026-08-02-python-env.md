# python-env Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One uv-built "blessed" Python scripting environment on every dev machine (Linux + Windows) with Textual, Click and seven friends preinstalled, reached via a `wpy` launcher (+ `textual`/`typer` CLIs) — system Python untouched, prod machines skip.

**Architecture:** Linux gets a dev-only bespoke Make target `python-env` (user-level, never sudo) driving a new `lib/python-env.sh`; Windows gets uv as a pinned `$PortableTools` entry plus a bespoke `Invoke-PythonEnv` step in `bootstrap.ps1`. Both run the same uv commands: install pinned CPython → recreate venv → `uv pip install --upgrade` the lib list → expose launchers. Three new cross-file surfaces (UV pin, Python pin, lib list) are enforced by `check-invariants.sh`.

**Tech Stack:** GNU Make, bash, PowerShell 5.1, uv 0.11.32, CPython 3.14.6 (python-build-standalone via uv).

**Spec:** `docs/superpowers/specs/2026-08-02-python-env-design.md`. (The original draft of this plan claimed bespoke pins skip `UPDATE_SPECS` — that premise was false, caught in final review: pwndbg/vcpkg ARE registered. As landed, PYTHON_VERSION is registered in `UPDATE_SPECS` (`python/cpython`, `v` tags) and joins UV_VERSION in bump-versions.sh's EXCLUDE — both report-only, matching the spec.)

## Global Constraints

- **Dev-only:** every new install path is gated `MODE=dev` (Linux) / runs only in the full bootstrap (Windows); prod prints the standard skip line.
- **Never sudo/admin:** `python-env` is user-level — no `$(SUDO)` anywhere in its recipe; Windows steps are per-user, no elevation.
- **Pins:** `PYTHON_VERSION := 3.14.6`, `UV_VERSION := 0.11.32` (unchanged value; gains a Windows dual-edit). uv Windows zip sha256: `acfde570451cfdb8689fa159a138ee805ba4e241c466432750302c86254b0984` (verified 2026-08-02 against `uv-x86_64-pc-windows-msvc.zip` of release 0.11.32; archive is FLAT: `uv.exe`, `uvw.exe`, `uvx.exe`).
- **Lib list (exact, 9 entries, this order):** `textual textual-dev click rich httpx pydantic typer polars duckdb`. Wheel coverage on CPython 3.14 verified 2026-08-02 (duckdb 1.5.5 + pydantic-core 2.47.0 ship cp314; polars 1.43.2 is py3-none-any over a cp310-abi3 runtime; the rest are pure Python).
- **One-line arrays:** the lib list must stay on ONE line in both `lib/python-env.sh` (`PY_LIBS=(…)`) and `bootstrap.ps1` (`$PythonLibs = @(…)`) — the new invariant check parses them with single-line greps.
- **Env paths:** Linux `$HOME/.local/share/workstation-python`; Windows `%LOCALAPPDATA%\workstation\python-env`. Launchers: Linux symlinks `wpy`/`textual`/`typer` in `~/.local/bin`; Windows `wpy.cmd`/`textual.cmd`/`typer.cmd` in `$WsBin`.
- **File care:** `makefile/lib/python-env.sh` must be LF-only, git mode 100755, `shfmt -i 2`-clean, shellcheck-clean at warning+. `bootstrap.ps1` must keep its UTF-8 BOM and stay PSScriptAnalyzer-clean.
- **Never `tree`-extract into `$WsBin`:** `Install-PortableTool`'s `tree` layout WIPES `$Tool.Dest` before extracting (bootstrap.ps1:805) — uv gets its own `$WsUv` dir.
- **Stamp-on-stamp:** the Make target order-only-deps on `$(STAMP)/uv-$(UV_VERSION).done` (the FILE, `|` prerequisite — never the `uv` phony).
- **Docs in the same PR:** README.html + CLAUDE_CHANGELOG.md updated before merge (user-facing surface).
- Work on branch `feat/python-env` (already exists, spec committed). Every commit message ends with the standard `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` + `Claude-Session:` trailer lines used by this session.

---

### Task 1: `lib/python-env.sh` + `PYTHON_VERSION` pin

**Files:**
- Create: `makefile/lib/python-env.sh`
- Modify: `makefile/versions.mk` (dev-only bespoke neighborhood, after the `PWNDBG_VERSION`/`VCPKG_VERSION` block around line 187)

**Interfaces:**
- Produces: `python-env.sh <python-version>` — builds/rebuilds the whole env; the one-line `PY_LIBS=(…)` array (Task 4's parity check greps `^PY_LIBS=\(`); `PYTHON_VERSION` make var (Tasks 2, 4).

- [ ] **Step 1: Write the install script**

Create `makefile/lib/python-env.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# python-env.sh — build the blessed dev Python scripting env with uv.
#
# Usage:
#   python-env.sh <python-version>
#
#   python-version   Pinned CPython, e.g. 3.14.6 (PYTHON_VERSION in
#                    versions.mk; dual-edits $PythonEnvVersion in
#                    bootstrap.ps1 — check-invariants.sh verifies).
#
# uv (the EGET_TOOL already on PATH) downloads the pinned CPython
# (python-build-standalone, user-level under ~/.local/share/uv) and builds
# the venv at ~/.local/share/workstation-python. USER-LEVEL like pip.sh —
# never run under sudo. The env is recreated from scratch every run
# (deterministic; ad-hoc `uv pip install -p <env> <pkg>` additions are
# deliberately disposable). Libs track LATEST at install time (glances
# precedent) — upgrading is `make python-env-rebuild`.

set -euo pipefail

version="${1:?usage: python-env.sh <python-version>}"

env_dir="$HOME/.local/share/workstation-python"
bin_dir="$HOME/.local/bin"

# Canonical lib list — KEEP ON ONE LINE (check-invariants.sh parses it and
# compares against $PythonLibs in bootstrap.ps1; parity pair).
PY_LIBS=(textual textual-dev click rich httpx pydantic typer polars duckdb)

if ! command -v uv >/dev/null 2>&1; then
  printf 'python-env.sh: uv not on PATH — run `make uv` first\n' >&2
  exit 1
fi

uv python install "$version"
rm -rf "$env_dir"
uv venv --python "$version" "$env_dir"
uv pip install --python "$env_dir/bin/python" --upgrade "${PY_LIBS[@]}"

# Launchers: wpy is a tiny WRAPPER SCRIPT, not a symlink — a symlink from
# outside the venv to bin/python loses the venv (CPython resolves the full
# symlink chain to the uv base interpreter and never finds pyvenv.cfg, so
# imports fail; verified 2026-08-03). Exec-ing the venv python by real path
# keeps the env, and nested shebangs (#!/usr/bin/env wpy) work — Linux
# accepts script interpreters. textual/typer STAY symlinks: they are venv
# entry-point scripts whose shebangs already point into the env.
mkdir -p "$bin_dir"
printf '#!/bin/sh\nexec "%s/bin/python" "$@"\n' "$env_dir" >"$bin_dir/wpy"
chmod 0755 "$bin_dir/wpy"
ln -sf "$env_dir/bin/textual" "$bin_dir/textual"
ln -sf "$env_dir/bin/typer" "$bin_dir/typer"

printf 'python-env: CPython %s + %d libs at %s (launchers: wpy, textual, typer)\n' \
  "$version" "${#PY_LIBS[@]}" "$env_dir"
```

- [ ] **Step 2: Add the pin to versions.mk**

In `makefile/versions.mk`, directly after the `VCPKG_VERSION := 2026.06.24` line (end of the C/C++ dev-only block, ~line 188), insert:

```make
# --- Blessed Python scripting env (dev_machine only) -------------------------
# python-env — uv-managed CPython + one venv (~/.local/share/workstation-python)
# with the ad-hoc-scripting libs (Textual/Click/&c). Canonical lib list lives in
# lib/python-env.sh (PY_LIBS — parity pair with $PythonLibs in bootstrap.ps1).
# Libs track LATEST at install time; only the interpreter is pinned. DUAL-EDIT:
# $PythonEnvVersion in bootstrap.ps1 (Make never runs on Windows — Helix
# precedent; check-invariants.sh verifies). Bump only to a CPython with full
# wheel coverage for the lib set on BOTH platforms (cp/abi3 check on PyPI —
# duckdb + pydantic-core are the usual laggards). Not in UPDATE_SPECS (bespoke
# pin, pwndbg precedent — bump by hand).
PYTHON_VERSION := 3.14.6
```

- [ ] **Step 3: Fix line endings + mode, then lint**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
sed -i 's/\r$//' makefile/lib/python-env.sh
chmod +x makefile/lib/python-env.sh
git add makefile/lib/python-env.sh   # stage so --stage shows mode
git update-index --chmod=+x makefile/lib/python-env.sh
file makefile/lib/python-env.sh                # must NOT say CRLF
git ls-files --stage makefile/lib/python-env.sh # must show 100755
shellcheck -S warning makefile/lib/python-env.sh
shfmt -i 2 -d makefile/lib/python-env.sh       # no diff output
```
Expected: no CRLF, mode 100755, both linters silent. (The `post-edit-guard.sh` hook auto-repairs CRLF/mode after edits, but verify anyway.)

- [ ] **Step 4: Run the script for real (this WSL host is a dev machine — this IS the test)**

```bash
bash makefile/lib/python-env.sh 3.14.6
~/.local/bin/wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"
~/.local/bin/wpy --version     # Python 3.14.6
~/.local/bin/textual --version
~/.local/bin/typer --version
```
Expected: `ok`, `Python 3.14.6`, both CLIs print versions. Everything is user-level and disposable (`rm -rf ~/.local/share/workstation-python` reverts).

- [ ] **Step 5: Commit**

```bash
git add makefile/lib/python-env.sh makefile/versions.mk
# If the sync-tool-memory hook regenerated chezmoi/private_dot_claude/CLAUDE.md
# (it fires on versions.mk edits), add that too.
git status --short
git commit -m "feat(python-env): lib/python-env.sh + PYTHON_VERSION pin (uv-built blessed scripting env)"
```

---

### Task 2: Make target, fanout, doctor

**Files:**
- Modify: `makefile/Makefile` — new target block after the `vcpkg` block (~line 359); `PROVISION_FANOUT` dev line (~line 729); `DOCTOR_ROWS` bespoke block (~line 775); help text (~line 868 area, optional one line)
- Modify: `makefile/lib/doctor.sh` — new case arm in `check_bespoke` (before the `*)` fallback, ~line 207)

**Interfaces:**
- Consumes: `PYTHON_VERSION` (Task 1), `$(STAMP)/uv-$(UV_VERSION).done` (existing EGET_TOOL stamp rule), `$(LIB)/python-env.sh` (Task 1).
- Produces: `make python-env MODE=dev`, `make clean-python-env`, stamp `python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done`, doctor row `bespoke|python-env|<version>-<cksum>`.

- [ ] **Step 1: Add the target block to makefile/Makefile**

Insert after the `clean-vcpkg` recipe (~line 359), before the lsp/go section:

```make
# -----------------------------------------------------------------------------
# python-env — blessed Python scripting env (dev_machine only). uv installs the
# pinned CPython and builds ~/.local/share/workstation-python with the ad-hoc
# scripting libs (Textual/Click/&c — canonical list in lib/python-env.sh),
# then installs launchers in ~/.local/bin (wpy WRAPPER SCRIPT — a symlink
# would lose the venv; textual/typer symlinks). USER-LEVEL like pip.sh —
# never $(SUDO). Stamp bakes PYTHON_VERSION + a cksum of lib/python-env.sh
# (lsp-servers hash precedent), so bumping the pin OR editing the lib list
# rebuilds on the next provision; upgrading the latest-tracking libs is
# `make python-env-rebuild`. Order-only dep on uv's stamp FILE
# (never the phony — EGET_TOOL stamp-on-stamp invariant). No WSL skip
# (useful in a WSL dev guest, like pwndbg). Windows half: Invoke-PythonEnv
# in bootstrap.ps1 ($PythonEnvVersion/$PythonLibs — check-invariants pairs).
# -----------------------------------------------------------------------------
PYTHON_ENV_STAMP := $(shell cksum $(LIB)/python-env.sh | cut -d' ' -f1)
.PHONY: python-env clean-python-env
ifeq ($(MODE),dev)
python-env: $(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done
$(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done: | $(STAMP)/uv-$(UV_VERSION).done
	@printf '==> python-env %s\n' "$(PYTHON_VERSION)"
	@$(LIB)/python-env.sh $(PYTHON_VERSION)
	@mkdir -p $(@D) && touch $@
else
python-env:
	@echo "python-env is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-python-env:
	@rm -f $(STAMP)/python-env-*.done
	@rm -rf $(HOME)/.local/share/workstation-python
	@rm -f $(HOME)/.local/bin/wpy $(HOME)/.local/bin/textual $(HOME)/.local/bin/typer
```

(Recipe lines are TAB-indented — copy carefully.)

- [ ] **Step 2: Join the dev fanout + doctor rows**

In `makefile/Makefile` change the dev `PROVISION_FANOUT` line (~729):

```make
PROVISION_FANOUT += pwndbg vcpkg go-runtime lsp-servers devtoys-cli python-env
```

And in the `DOCTOR_ROWS` bespoke block (after `bespoke|lsp-servers|-`, ~line 775):

```make
DOCTOR_ROWS += bespoke|python-env|$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP)
```

- [ ] **Step 3: Add the doctor.sh arm**

In `makefile/lib/doctor.sh`, inside `check_bespoke`'s `case`, before the `*)` fallback (after the `vcpkg)` arm):

```bash
  python-env)
    # $version is "<PYTHON_VERSION>-<cksum-of-lib/python-env.sh>" — matches the
    # stamp suffix, so a pin bump OR lib-list edit shows as "pin moved".
    check_component python-env python-env wpy "$HOME/.local/bin" "$version"
    ;;
```

- [ ] **Step 4: Test the Make surface**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
make -C makefile -n python-env MODE=prod   # dry-run: prints the skip echo only
make -C makefile python-env MODE=dev       # real run: uv fires, stamp written
make -C makefile python-env MODE=dev       # rerun: NO ==> output (stamp hit)
ls ~/.local/share/workstation-install/python-env-*.done
make -C makefile doctor MODE=dev | grep python-env   # ✓ row
```
Expected: prod prints "dev_machine target — skipping"; first dev run rebuilds (Task 1 already made the env — the recipe recreates it, ~30s warm-cached); second dev run is silent; doctor row is ✓.

- [ ] **Step 5: Test the rebuild triggers**

```bash
touch -d '2020-01-01' ~/.local/share/workstation-install/python-env-*.done
make -C makefile python-env MODE=dev   # still a stamp hit (order-only uv dep — no rebuild)
printf '# rebuild-trigger test\n' >> makefile/lib/python-env.sh
make -C makefile -n python-env MODE=dev | head -3   # dry-run NOW shows the recipe (hash moved)
git checkout -- makefile/lib/python-env.sh
```
Expected: stale mtime does NOT rebuild; a content edit DOES (dry-run shows `==> python-env`). Restore the script afterwards (git checkout). Re-run `chmod +x` + `git update-index --chmod=+x` if the checkout dropped the local mode.

- [ ] **Step 6: Commit**

```bash
git add makefile/Makefile makefile/lib/doctor.sh
git commit -m "feat(python-env): dev-only Make target + provision fanout + doctor coverage"
```

---

### Task 3: Windows half — uv portable tool + `Invoke-PythonEnv`

**Files:**
- Modify: `bootstrap.ps1` — `$WsUv` var (~line 193, next to `$WsNu`); uv entry in `$PortableTools` (after the jq entry); `$PythonEnvVersion` + `$PythonLibs` config (just after the `$PortableTools` array closes); new `Invoke-PythonEnv` function (after `Invoke-InstallClaudeCode`, ~line 1668); main-flow call (~line 2208); `-SkipToolInstall` log text (~line 1201); Doctor block (in `Invoke-Doctor`'s Environment section, ~line 2026); CheckForUpdates block (in "Other components", ~line 2170)

**Interfaces:**
- Consumes: `Install-PortableTool`, `$WsStamps`/`$WsBin`/`$WsRoot`, `Write-Log`/`Write-Ok`/`Write-Warn`/`Write-Bad`, `Get-LatestGitTag`, `Write-UpdateStatus` (all existing).
- Produces: `$PythonEnvVersion` (string `"3.14.6"`, greppable as `^\$PythonEnvVersion`), one-line `$PythonLibs` array (both parsed by Task 4's checks), `wpy.cmd`/`textual.cmd`/`typer.cmd` in `$WsBin`.

- [ ] **Step 1: Add `$WsUv` and the uv `$PortableTools` entry**

Next to the existing `$WsNu`-style definitions (~line 193):

```powershell
$WsUv         = Join-Path $WsRoot "uv"
```

In `$PortableTools`, after the jq entry:

```powershell
    @{
        # uv — Python front door for Invoke-PythonEnv (pinned CPython + the
        # blessed scripting env). Zip is FLAT (uv.exe + uvw.exe + uvx.exe) —
        # 'tree' into its OWN dir: tree-extract WIPES Dest, so $WsBin is off
        # limits (nu/helix precedent).
        Name       = "uv"
        Exe        = "uv"
        Version    = "0.11.32"
        Url        = "https://github.com/astral-sh/uv/releases/download/0.11.32/uv-x86_64-pc-windows-msvc.zip"
        Sha256     = "acfde570451cfdb8689fa159a138ee805ba4e241c466432750302c86254b0984"
        Layout     = "tree"
        Dest       = $WsUv
        Repo       = "astral-sh/uv"
        TagPrefix  = ""
        UpdateHint = "dual-edit: `$PortableTools here AND UV_VERSION in makefile/versions.mk"
    },
```

- [ ] **Step 2: Add the env config right after the `$PortableTools` array closes**

```powershell
# --- Blessed Python scripting env (Invoke-PythonEnv) -------------------------
# DUAL-EDIT: $PythonEnvVersion pairs with PYTHON_VERSION in makefile/versions.mk;
# $PythonLibs pairs with PY_LIBS in makefile/lib/python-env.sh. KEEP EACH ON ONE
# LINE — scripts/check-invariants.sh parses both with single-line greps.
$PythonEnvVersion = "3.14.6"
$PythonLibs = @("textual", "textual-dev", "click", "rich", "httpx", "pydantic", "typer", "polars", "duckdb")
$WsPythonEnv = Join-Path $WsRoot "python-env"
```

- [ ] **Step 3: Write `Invoke-PythonEnv`** (after `Invoke-InstallClaudeCode`, before the Nerd Fonts banner):

```powershell
# =============================================================================
# 6b. PYTHON SCRIPTING ENV — the blessed uv-built venv (Windows half of the
#    Linux `python-env` Make target). uv installs the pinned CPython
#    (python-build-standalone, per-user) and rebuilds the env from scratch,
#    then wpy/textual/typer .cmd shims land in $WsBin. Libs track LATEST at
#    install time; stamp bakes the pin + the lib list, so a bump or list edit
#    rebuilds on the next bootstrap and a lib upgrade is "delete the stamp,
#    re-run" (Linux: make python-env-rebuild). Per-user, no admin;
#    warn-and-continue (standard tool-step posture).
# =============================================================================
function Invoke-PythonEnv {
    if ($SkipToolInstall) {
        Write-Log "Python env skipped (-SkipToolInstall)"
        return
    }
    $uvExe = Join-Path $WsUv "uv.exe"
    if (-not (Test-Path $uvExe)) {
        Write-Warn "Python env skipped — uv not installed at $uvExe (portable-tool step failed?)"
        return
    }

    # Stamp bakes pin + lib list (the Linux stamp's cksum analog).
    $libBytes = [System.Text.Encoding]::UTF8.GetBytes(($PythonLibs -join ' '))
    $libStream = New-Object System.IO.MemoryStream (,$libBytes)
    $libHash = (Get-FileHash -InputStream $libStream -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
    $stamp = Join-Path $WsStamps "python-env.$PythonEnvVersion.$libHash.stamp"
    $wpyShim = Join-Path $WsBin "wpy.cmd"
    if ((Test-Path $stamp) -and (Test-Path $wpyShim)) {
        Write-Ok "Python env $PythonEnvVersion already built ($WsPythonEnv)"
        return
    }

    Write-Log "Building Python scripting env $PythonEnvVersion ($($PythonLibs.Count) libs)..."
    try {
        & $uvExe python install $PythonEnvVersion
        if ($LASTEXITCODE -ne 0) { throw "uv python install exited $LASTEXITCODE" }
        if (Test-Path $WsPythonEnv) { Remove-Item -Recurse -Force $WsPythonEnv }
        & $uvExe venv --python $PythonEnvVersion $WsPythonEnv
        if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        $envPy = Join-Path $WsPythonEnv "Scripts\python.exe"
        & $uvExe pip install --python $envPy --upgrade $PythonLibs
        if ($LASTEXITCODE -ne 0) { throw "uv pip install exited $LASTEXITCODE" }

        # Launcher shims — wpy calls the env python; textual/typer call the
        # env's entry-point exes. $WsBin is already on the User PATH.
        $scripts = Join-Path $WsPythonEnv "Scripts"
        Set-Content -Path $wpyShim -Value "@echo off`r`n`"$envPy`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "textual.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'textual.exe')`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "typer.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'typer.exe')`" %*" -Encoding Ascii

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        Get-ChildItem -Path $WsStamps -Filter "python-env.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "Python env $PythonEnvVersion built ($WsPythonEnv; launchers: wpy, textual, typer)"
    } catch {
        Write-Warn "Python env build failed: $($_.Exception.Message)"
        Write-Warn "  Re-run .\bootstrap.ps1 to retry (no stamp was written)."
    }
}
```

- [ ] **Step 4: Wire the main flow + skip text + report modes**

Main flow, directly after the `Invoke-InstallClaudeCode` call (~line 2208):

```powershell
Invoke-PythonEnv          # blessed uv-built Python scripting env (wpy/textual/typer shims)
```

`-SkipToolInstall` log line (~1201): append `/uv` after `omp` in the tool
enumeration and `; Python env not built` before the closing quote.

`Invoke-Doctor` — in the Environment section next to the Nushell-starship check (~line 2026):

```powershell
    $wpyShim = Join-Path $WsBin "wpy.cmd"
    $pyStamps = @(Get-ChildItem -Path $WsStamps -Filter "python-env.*.stamp" -ErrorAction SilentlyContinue)
    if ((Test-Path $wpyShim) -and ($pyStamps.Count -gt 0)) {
        Write-Ok "Python env $PythonEnvVersion built (wpy/textual/typer in $WsBin)"
    } elseif (Test-Path $wpyShim) {
        Write-Warn "Python env shims present but no stamp — pin or lib list moved? next bootstrap rebuilds"
    } else {
        Write-Bad "Python env not built — re-run .\bootstrap.ps1"
    }
```

`Invoke-CheckForUpdates` — in "Other components" next to the Nerd Fonts block (~line 2170):

```powershell
    $latestPy = Get-LatestGitTag -Repo 'python/cpython' -TagPrefix 'v'
    Write-UpdateStatus -Name 'Python env (CPython)' -Pinned $PythonEnvVersion -Latest $latestPy -Hint 'dual-edit: $PythonEnvVersion here AND PYTHON_VERSION in makefile/versions.mk; check cp-wheel coverage first (see versions.mk comment)'
```

(uv itself needs nothing — the `$PortableTools` loop already covers Doctor + CheckForUpdates for it.)

- [ ] **Step 5: Lint + BOM check**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
head -c 3 bootstrap.ps1 | xxd | head -1        # must show efbb bf
make -C makefile ps-lint MODE=prod || echo "pwsh unavailable locally — lint.yml enforces in CI"
```
Expected: BOM intact; PSScriptAnalyzer clean (or deferred to CI if pwsh is absent on this host — note which happened in the commit).

- [ ] **Step 6: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(python-env): Windows half — uv portable tool + Invoke-PythonEnv (wpy/textual/typer shims)"
```

**Deferred runtime verification (Windows host, after merge/pull there):**
`.\bootstrap.ps1` → uv sha256-verified into `workstation\uv`, env built; fresh Nushell: `wpy -c "import textual, click; print('ok')"`, `textual --version`; `.\bootstrap.ps1 -Doctor` shows uv + Python env rows; re-run bootstrap → both stamp-hit.

---

### Task 4: Invariant enforcement + bump-versions

**Files:**
- Modify: `scripts/check-invariants.sh` — two pin checks in `check_version_pins` (after the gh check, ~line 122); new `check_python_env_parity` function (after `check_completion_parity`, ~line 393) + its call in the runner list (~line 459)
- Modify: `scripts/bump-versions.sh` — EXCLUDE line (~line 28) + its comment

**Interfaces:**
- Consumes: `mkval` helper, `ok`/`bad`/`hdr` helpers (existing); `^PY_LIBS=\(` in `lib/python-env.sh` (Task 1); `^\$PythonEnvVersion` + `^\$PythonLibs` + the uv release URL in `bootstrap.ps1` (Task 3).

- [ ] **Step 1: Add the two pin checks** in `check_version_pins`, after the gh block:

```bash
  v=$(mkval UV_VERSION)
  ref=$(grep -oE 'astral-sh/uv/releases/download/[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "uv @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "uv drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval PYTHON_VERSION)
  ref=$(grep -oE '^\$PythonEnvVersion *= *"[0-9][0-9.]+"' bootstrap.ps1 |
    grep -oE '[0-9][0-9.]+' | head -1)
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "python-env @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "python-env drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi
```

- [ ] **Step 2: Add the lib-list parity check** after `check_completion_parity`:

```bash
# --- python-env lib-list parity ----------------------------------------------
# The blessed-env library list is defined twice (Make never runs on Windows):
# PY_LIBS in makefile/lib/python-env.sh and $PythonLibs in bootstrap.ps1. Both
# are one-line arrays by contract (comments at each site) so single-line greps
# can extract them. Order-insensitive compare (sort) — content is the contract.
check_python_env_parity() {
  hdr "python-env lib-list parity (python-env.sh == bootstrap.ps1)"
  local sh_libs ps_libs
  sh_libs=$(grep -oE '^PY_LIBS=\([^)]*\)' makefile/lib/python-env.sh |
    sed 's/^PY_LIBS=(//; s/)$//' | tr ' ' '\n' | grep -v '^$' | sort)
  ps_libs=$(grep -oE '^\$PythonLibs *= *@\([^)]*\)' bootstrap.ps1 |
    sed 's/.*@(//; s/)$//' | tr -d '",' | tr ' ' '\n' | grep -v '^$' | sort)
  if [ -n "$sh_libs" ] && [ "$sh_libs" = "$ps_libs" ]; then
    ok "$(printf '%s\n' "$sh_libs" | wc -l) libs match"
  else
    bad "lib-list drift (<:python-env.sh  >:bootstrap.ps1):"
    diff <(printf '%s\n' "$sh_libs") <(printf '%s\n' "$ps_libs") | sed 's/^/       /'
  fi
}
```

And add `check_python_env_parity` to the runner list after `check_completion_parity` (~line 459).

- [ ] **Step 3: Update bump-versions.sh**

Change the EXCLUDE line to append `UV_VERSION`:

```bash
EXCLUDE="HELIX_VERSION JETBRAINSMONO_NERD_VERSION CCSTATUSLINE_VERSION JQ_VERSION SHFMT_VERSION GITLEAKS_VERSION NCDU_VERSION UV_VERSION"
```

And extend reason (1) in the comment above it: after the lint.yml sentence, add `UV joins the list because its pin now dual-edits bootstrap.ps1's $PortableTools (Windows half of the Python env).` (PYTHON_VERSION needs no entry — bespoke pins aren't in UPDATE_SPECS, so the bumper never sees it.)

- [ ] **Step 4: Verify the checks fail, then pass (the RED→GREEN for invariant checks)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
sed -i 's/^\$PythonLibs = @("textual", /$PythonLibs = @(/' bootstrap.ps1   # drop textual — break parity
bash scripts/check-invariants.sh; echo "exit=$?"       # MUST report lib-list drift, exit 1
git checkout -- bootstrap.ps1
bash scripts/check-invariants.sh                        # all green, incl. uv + python-env + parity
shellcheck -S warning scripts/check-invariants.sh scripts/bump-versions.sh
shfmt -i 2 -d scripts/check-invariants.sh scripts/bump-versions.sh
```
Expected: broken state exits non-zero naming the drift; restored state is fully green; linters silent. Verify `git ls-files --stage bootstrap.ps1`-adjacent BOM survived the sed+checkout (`head -c 3 bootstrap.ps1 | xxd`).

- [ ] **Step 5: Commit**

```bash
git add scripts/check-invariants.sh scripts/bump-versions.sh
git commit -m "chore(python-env): enforce UV_VERSION + PYTHON_VERSION dual-edits and lib-list parity"
```

---

### Task 5: Docs — README, CLAUDE.md, claude-docs, changelog

**Files:**
- Modify: `README.html` — §stack chip (near the pwndbg/gef chips or the glances/harlequin neighborhood — put it with the dev-tool chips, ~line 1385); §daily usage block (~line 3750+); §setup-windows tool enumeration (uv + Python env mentions, near the OpenCode/omp lines ~2854 + the skip-list line ~3187); §troubleshooting `<details data-ts>` entry (~line 4295+)
- Modify: `CLAUDE.md` — new invariant bullet; dual-edit list; parity-pair list
- Modify: `docs/claude/invariants.md`, `docs/claude/file-care.md`, `docs/claude/verification.md`
- Modify: `CLAUDE_CHANGELOG.md` — one row

- [ ] **Step 1: README §stack chip** — add next to the pwndbg chip (same `<span class="chip">` shape, ~line 1385):

```html
<span
    class="chip"
    tabindex="0"
    data-tip="Blessed uv-built Python env — wpy launcher + Textual/Click/rich/httpx/pydantic/typer/polars/duckdb"
    >python-env <small>(dev)</small
    ><span class="sr-only">
        — blessed uv-managed Python scripting environment with
        Textual, Click and friends, reached via the wpy launcher
        (dev_machine only)</span
    ></span
>
```

- [ ] **Step 2: README §daily block** — add a short usage card/paragraph in §daily (match the surrounding markup — prose `<p>` + `<code>` shapes):

Content to convey (adapt to the section's existing structure):
```html
<h3>Python scripting env (dev)</h3>
<p>
    Ad-hoc scripts get a blessed uv-built environment —
    <code>wpy script.py</code> (or <code>#!/usr/bin/env wpy</code>) has
    <strong>Textual, Click, rich, httpx, pydantic, typer, polars,
    duckdb</strong> preinstalled; <code>textual</code> and
    <code>typer</code> CLIs are on PATH too.
</p>
<p>
    Libraries track latest at install time. Upgrade:
    <code>make python-env-rebuild MODE=dev</code> (Windows:
    delete the <code>python-env.*.stamp</code> under
    <code>%LOCALAPPDATA%\workstation\stamps</code> and re-run
    <code>bootstrap.ps1</code>). One-off additions:
    <code>uv pip install -p ~/.local/share/workstation-python
    &lt;pkg&gt;</code> — they last until the next rebuild.
</p>
```

- [ ] **Step 3: README §setup-windows mentions** — extend the portable-tool enumeration sentences (~line 2854 area) to include uv, and mention the Python env step: `uv (Python front door) lands in workstation\uv, and a bespoke step builds the blessed Python scripting env at %LOCALAPPDATA%\workstation\python-env with wpy/textual/typer shims in workstation\bin`. Update the `-SkipToolInstall` enumeration (~line 3187 + the mirrored one ~4584) to append uv + the Python env.

- [ ] **Step 4: README §troubleshooting entry** — new `<details data-ts>` following the existing shape:

```html
<details data-ts>
    <summary>
        <code>wpy</code> not found, or <code>import textual</code>
        fails in it
    </summary>
    <div class="ts-body">
        <p>
            The blessed Python env is dev_machine-only and built by
            provisioning. Rebuild it from scratch:
        </p>
        <p>
            <strong>Linux:</strong>
            <code>make python-env-rebuild MODE=dev</code>
        </p>
        <p>
            <strong>Windows:</strong> delete
            <code>%LOCALAPPDATA%\workstation\stamps\python-env.*.stamp</code>
            and re-run <code>.\bootstrap.ps1</code>.
        </p>
        <p>
            The same rebuild upgrades the latest-tracking libraries.
            If <code>wpy</code> resolves but an import fails, an ad-hoc
            <code>uv pip install</code> likely broke a dependency — the
            rebuild resets the env to the canonical nine libraries.
        </p>
    </div>
</details>
```

- [ ] **Step 5: CLAUDE.md edits** (root `CLAUDE.md`):
  - New invariant bullet in "Load-bearing invariants", after the devtoys-cli bullet:
    ```
    - **`python-env` is a dev-only bespoke target, USER-LEVEL (never `$(SUDO)`)** — uv builds a pinned CPython + one venv (`~/.local/share/workstation-python`) with the ad-hoc scripting libs; launchers `wpy`/`textual`/`typer` in `~/.local/bin` (system python never shadowed). Stamp bakes `PYTHON_VERSION` + a cksum of `lib/python-env.sh` (libs track latest — upgrade = `make python-env-rebuild`). Windows half: uv in `$PortableTools` (own `workstation\uv` dir — `tree` extraction WIPES its Dest, so never into `workstation\bin`) + `Invoke-PythonEnv` (`$PythonEnvVersion`/`$PythonLibs`). Order-only dep on uv's stamp *file*.
    ```
  - "Version-pin dual/triple-edits" list in *Files Claude should be careful with*: append `` `UV_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PortableTools`) and `PYTHON_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PythonEnvVersion`) — both verified by `check-invariants.sh` ``.
  - "Parity pairs" list: append `` `makefile/lib/python-env.sh` `PY_LIBS` ↔ `bootstrap.ps1` `$PythonLibs` (one-line arrays; verified by `check-invariants.sh`) ``.
- [ ] **Step 6: docs/claude updates**
  - `invariants.md`: full python-env entry — why user-level (pip.sh posture), why launcher-not-shadowing, the tree-wipe hazard, why libs track latest, the stamp composition, the EL9-3.9-floor rationale for uv-managed CPython.
  - `file-care.md`: entries for `makefile/lib/python-env.sh` (LF/0755/one-line PY_LIBS contract) and the new `bootstrap.ps1` surfaces (`$PythonEnvVersion`/`$PythonLibs` one-line contract).
  - `verification.md`: the python-env recipe — `make -C makefile python-env MODE=dev && wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')" && textual --version`; Windows analog; the rebuild-trigger test from Task 2 Step 5.
- [ ] **Step 7: CLAUDE_CHANGELOG.md row** — prepend as the FIRST data row (newest-first order), exactly:

```markdown
| Added the blessed Python scripting env (spec `docs/superpowers/specs/2026-08-02-python-env-design.md`): dev-only `python-env` — uv installs pinned CPython 3.14.6 (python-build-standalone, user-level) and builds one venv (`~/.local/share/workstation-python` / `%LOCALAPPDATA%\workstation\python-env`) with 9 latest-tracking libs (textual, textual-dev, click, rich, httpx, pydantic, typer, polars, duckdb), launchers `wpy`/`textual`/`typer` on PATH (system python never shadowed). Linux: bespoke Make target (never sudo, stamp = pin + `cksum lib/python-env.sh`, order-only dep on uv's stamp file) + doctor arm. Windows: uv joins `$PortableTools` (`tree` into its OWN `workstation\uv` dir — tree-extract WIPES Dest, `$WsBin` off limits) + `Invoke-PythonEnv` (`.cmd` shims, stamp = pin + lib-list hash, warn-and-continue). Three new `check-invariants.sh` checks: `UV_VERSION` + `PYTHON_VERSION` dual-edits, `PY_LIBS`↔`$PythonLibs` parity (one-line array contract); `UV_VERSION` joins bump-versions' EXCLUDE (now a dual-edit). | **Yes** | §stack: python-env chip (dev). §daily: new h3 — `wpy` usage/shebang, upgrade recipe (`make python-env-rebuild`; Windows stamp delete), ad-hoc `uv pip install -p` note. §setup-windows: uv in the portable enumeration + Python-env step + `-SkipToolInstall` rosters. §troubleshooting: "wpy not found / import fails" entry (rebuild recipe both OSes). |
```
- [ ] **Step 8: Verify + commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
bash scripts/check-invariants.sh    # still green
git add README.html CLAUDE.md docs/claude CLAUDE_CHANGELOG.md
git commit -m "docs(python-env): README (stack/daily/windows/troubleshooting) + CLAUDE invariants + changelog"
```

---

### Task 6: Final verification + PR

- [ ] **Step 1: Full lint + template checks**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
make lint MODE=prod
```
Expected: check-invariants (incl. the three new checks) + templates all green.

- [ ] **Step 2: End-to-end provision-path checks**

```bash
# provision recurses, so -n on it won't show fanout members — inspect the
# database instead: the provision-fanout prereq list must name python-env.
make -C makefile -np MODE=dev 2>/dev/null | grep '^provision-fanout:' | grep -o python-env
make -C makefile python-env MODE=dev            # stamp hit (built in Task 2)
make -C makefile doctor MODE=dev | grep -E 'python-env|uv'
wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"
textual --version && typer --version
printf '#!/usr/bin/env wpy\nimport click; click.echo("shebang ok")\n' > /tmp/claude-1000/-home-arrush-chaturvedi--local-share-chezmoi/4a789348-b820-4e8f-aba7-5965fa9574be/scratchpad/t.py
chmod +x /tmp/claude-1000/-home-arrush-chaturvedi--local-share-chezmoi/4a789348-b820-4e8f-aba7-5965fa9574be/scratchpad/t.py
/tmp/claude-1000/-home-arrush-chaturvedi--local-share-chezmoi/4a789348-b820-4e8f-aba7-5965fa9574be/scratchpad/t.py
```
Expected: fanout contains python-env; doctor ✓ rows; imports `ok`; shebang prints `shebang ok`.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feat/python-env
gh pr create --title "feat(python-env): blessed uv-managed Python scripting env — Textual/Click + 7 libs, dev-only, Linux + Windows" --body "$(cat <<'EOF'
## Summary
- Dev-only blessed Python scripting env: uv installs pinned CPython 3.14.6 and builds one venv with 9 latest-tracking libs (textual, textual-dev, click, rich, httpx, pydantic, typer, polars, duckdb); launchers `wpy`/`textual`/`typer` on PATH, system python untouched.
- Linux: bespoke `python-env` Make target (user-level, never sudo; stamp = pin + `cksum lib/python-env.sh`; order-only dep on uv's stamp file) + doctor arm + provision fanout.
- Windows: uv joins `$PortableTools` (sha256-pinned, `tree` into its own `workstation\uv` dir) + bespoke `Invoke-PythonEnv` (`.cmd` shims, stamped, warn-and-continue) + Doctor/CheckForUpdates rows.
- Enforcement: `check-invariants.sh` gains `UV_VERSION` + `PYTHON_VERSION` dual-edit checks and `PY_LIBS`↔`$PythonLibs` lib-list parity; `UV_VERSION` moves to bump-versions' EXCLUDE.
- Docs: README §stack/§daily/§setup-windows/§troubleshooting, CLAUDE.md invariants + dual-edit/parity lists, docs/claude trio, CLAUDE_CHANGELOG row.

Spec: `docs/superpowers/specs/2026-08-02-python-env-design.md` · Plan: `docs/superpowers/plans/2026-08-02-python-env.md`

## Verification
- Linux (WSL dev host): `make -C makefile python-env MODE=dev` idempotent; `wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"`; `textual --version`; shebang script runs; doctor rows green; `make lint MODE=prod` green incl. the 3 new checks.
- Windows (deferred to the Windows host): `.\bootstrap.ps1` → uv verified into `workstation\uv`, env built; fresh Nushell `wpy -c "import textual, click; print('ok')"`; `-Doctor` rows; re-run stamp-hits.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_012kcSCigSwPuCCgqRLKA145
EOF
)"
```

- [ ] **Step 4: Report back** — summarize what merged-state verification remains (the Windows host run), and flag the pre-existing doctor.sh gap (go-runtime/lsp-servers/devtoys-cli have DOCTOR_ROWS but no `check_bespoke` arms — they hit the "add one" fallback) as a candidate follow-up, NOT part of this PR.
