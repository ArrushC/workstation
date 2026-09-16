# mise-runtimes (PR 2, Windows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Windows host the same mise-owned runtime layer PR 1 gave Linux: mise as a pinned portable tool, an `Invoke-MiseRuntimes` step that installs from the chezmoi-deployed conf.d, shell activation for Nushell and PowerShell, the Python env resolving uv through mise, and the `UV_VERSION`→`MISE_VERSION` dual-edit swap.

**Architecture:** `bootstrap.ps1` gains one portable-tool entry (mise, `tree` layout with a new opt-in `BinSubdir` key because the zip nests `bin\mise.exe` + `mise-shim.exe`) and loses the uv entry. A new step right after `Invoke-Chezmoi` reads the two conf.d files chezmoi just deployed to `%USERPROFILE%\.config\mise\conf.d\` (mise's config dir is `~/.config/mise` on every platform; its data dir on Windows is `%LOCALAPPDATA%\mise`), stamps on their hash, runs `mise install`, and re-adds `%LOCALAPPDATA%\mise\shims` to the User PATH every run. Nushell gets a generated `vendor\autoload\mise.nu` (the starship precedent), the PowerShell profile a guarded `mise activate pwsh`. No runtime pin table exists on the Windows side — `versions.mk` stays the single source through the generated TOML.

**Tech Stack:** PowerShell 5.1-compatible `bootstrap.ps1` (UTF-8 BOM, PSScriptAnalyzer in CI), chezmoi templates (Nushell `config.nu.tmpl`, PowerShell profile `.tmpl`), mise 2026.9.1 Windows x64 zip, bash for `check-invariants.sh` / `bump-versions.sh`.

**Spec:** `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md` — decisions 10–14 plus the PR 2 half of decision 8. PR 1 (Linux) merged as `0b8faa0` (#153); read its plan `docs/superpowers/plans/2026-09-13-mise-runtimes-linux.md` only for the Linux facts it records (the `mise where node` gate, the TypeScript 5.x pin, the ts-ls `initialize` probe).

## Global Constraints

- Windows installs are admin-free, per-user, under `%LOCALAPPDATA%\workstation` (portable tools) — no elevation anywhere; every download goes through `Invoke-CurlRequest` (byte-identical copy in `scripts/install-nerd-fonts.ps1`; `check_curl_helper_parity` enforces — do NOT edit that helper).
- mise portable entry, verbatim: `Version = "2026.9.1"`, `Url = "https://github.com/jdx/mise/releases/download/v2026.9.1/mise-v2026.9.1-windows-x64.zip"`, `Sha256 = "9556296db217774e7dae8fc241542d6bbc2351122ba93c8df2a65d3b921d7a28"`, `Layout = "tree"`, `BinSubdir = "bin"`, `Dest = $WsMise` (= `workstation\mise`), `Repo = "jdx/mise"`, `TagPrefix = "v"`. The zip nests `mise\bin\mise.exe` + `mise\bin\mise-shim.exe` (the template mise copies for native `.exe` shims); the tree flattener already strips the single top-level `mise\` folder, so the exe lands at `Dest\bin\mise.exe`.
- `BinSubdir` is honoured in EXACTLY two places of `Install-PortableTool`: the stamp fast-path's exe existence check and the directory handed to `Add-ToUserPath` in the `tree` branch. Absent key = today's behaviour for every other tool.
- Dual-edit swap (spec decision 8, PR 2 half): `MISE_VERSION` in `makefile/versions.mk` ↔ the `jdx/mise/releases/download/v<ver>` URL in `bootstrap.ps1`, verified by `check_version_pins`; `MISE_VERSION` joins `EXCLUDE` in `scripts/bump-versions.sh`; `UV_VERSION` leaves both (uv has no Windows half any more). `check_bumper_exclude` derives the required EXCLUDE set from `check_version_pins`' `mkval` calls — keep the two edits in one commit.
- `Invoke-MiseRuntimes`: runs right after `Invoke-Chezmoi`; skipped by `-SkipToolInstall`; warn-and-continue (never `Write-Fail`); stamp `mise-runtimes.<sha256[0:8] of both conf.d files>.stamp` under `$WsStamps` via `Get-MiseRuntimesStamp` (shared with `-Doctor`); `mise install --yes`, then `mise install --yes --force node` only when the DECLARED node version was already present before the install AND node is declared (`mise where node` exit 0 — the Linux gate), then `mise prune --yes`; `Add-ToUserPath "$env:LOCALAPPDATA\mise\shims"` every run.
- `Invoke-PythonEnv` resolves `$uvExe` via `mise which uv` and warns-and-skips when empty; `$PythonEnvVersion`, `$PythonLibs`, `Get-PythonEnvStamp` and the lib-list parity check are untouched (both variables MUST stay one line at column 0).
- `Invoke-NushellMise` writes `%APPDATA%\nushell\vendor\autoload\mise.nu` from `mise activate nu` every run, UTF-8 WITHOUT BOM (nu chokes on a BOM); `config.nu.tmpl` gains only a comment. PowerShell profile: `Get-Command`-guarded `(& mise activate pwsh) | Out-String | Invoke-Expression` next to starship/zoxide.
- `.ps1` files keep their UTF-8 BOM (a PostToolUse hook auto-repairs it; verify with `head -c3 bootstrap.ps1 | xxd`). `scripts/check-invariants.sh` (pre-commit) must stay green — never `--no-verify`. CI's `powershell` job runs PSScriptAnalyzer over `bootstrap.ps1`; locally `pwsh` is absent on the WSL host, so use the Windows-side parse check via interop (Task 1 step) and, if the module exists there, `pwsh.exe -File scripts/check-ps.ps1`.
- Windows-side commands that install or prompt are run by the USER in a Windows terminal (`.\bootstrap.ps1`); the executor only runs read-only probes through `powershell.exe -NoProfile -Command …` from WSL (interop is on; `winterop` confirms).
- No `.chezmoiignore.tmpl` change: `.config/mise` is not in the Windows ignore block, so both conf.d files already deploy to `%USERPROFILE%\.config\mise\conf.d\` on the next Windows `chezmoi apply` (the Windows host today has neither mise nor the conf.d — verified read-only 2026-09-16).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG
  ```
- Branch: `feat/mise-runtimes-windows` (from `main` at `0b8faa0`+). Push after every commit.

---

## File map

| File | Responsibility |
|---|---|
| `bootstrap.ps1` | `$WsMise` path + comment table; `BinSubdir` in `Install-PortableTool`; mise entry replaces uv in `$PortableTools`; `-SkipToolInstall` text; `Get-MiseRuntimesStamp` + `Invoke-MiseRuntimes` (new 4b); `Invoke-NushellMise` (new 5g); `Invoke-PythonEnv` uv resolution; `-Doctor` rows; main flow |
| `makefile/versions.mk` | comments on `MISE_VERSION` (now dual-edit) and `UV_VERSION` (no Windows half) |
| `scripts/check-invariants.sh` | `check_version_pins`: uv block → mise block |
| `scripts/bump-versions.sh` | `EXCLUDE`: `UV_VERSION` out, `MISE_VERSION` in; header rationale |
| `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl` | mise activate block |
| `chezmoi/AppData/Roaming/nushell/config.nu.tmpl` | header comment mentions `mise.nu` |
| `CLAUDE.md`, `docs/claude/{invariants,file-care,verification}.md`, `README.html`, `CLAUDE_CHANGELOG.md` | docs |

---

### Task 1: mise as a portable tool (BinSubdir), uv retired, pin bookkeeping swapped

**Files:**
- Modify: `bootstrap.ps1` — path vars + comment table (~lines 260-277), `$PortableTools` doc comment (~281-296), `Install-PortableTool` (~854-940), the uv entry (~67-82 inside `$PortableTools`), `Invoke-ToolInstall` skip text (~1357)
- Modify: `makefile/versions.mk` (`MISE_VERSION` / `UV_VERSION` comments)
- Modify: `scripts/check-invariants.sh:124-131` (uv block), `scripts/bump-versions.sh:53` (`EXCLUDE`) + header rationale

**Interfaces:**
- Produces: `$WsMise` (`workstation\mise`), the `BinSubdir` opt-in key semantics, `mise.exe` on the User PATH at `workstation\mise\bin` after `Invoke-ToolInstall`; Task 2 depends on `mise` resolving in-session after this step (`Add-ToUserPath` refreshes `$env:PATH`).
- Removes: `$WsUv` and the uv portable entry — Task 2 changes the only consumer (`Invoke-PythonEnv`); until then that function's `Join-Path $WsUv "uv.exe"` would be a dangling variable, so Task 1 must also apply the ONE-line interim change in Step 4 (the full rewrite is Task 2).

- [ ] **Step 1: Path variable + comment table**

In `bootstrap.ps1`, in the `# Per-user install root …` comment block replace the line
`#   workstation\uv           — the uv portable tree (CPython/venvs)  → on User PATH`
with
`#   workstation\mise         — the mise portable tree (bin\mise.exe + mise-shim.exe) → bin\ on User PATH`
and replace `$WsUv         = Join-Path $WsRoot "uv"` with `$WsMise       = Join-Path $WsRoot "mise"`.

- [ ] **Step 2: Document the `BinSubdir` opt-in key and honour it in `Install-PortableTool`**

In the `$PortableTools` doc comment, after the `OPT-IN key \`Shortcut = …\`` paragraph add:

```powershell
#
# OPT-IN key `BinSubdir = "<subdir>"` — for 'tree' archives that nest their
# binaries below the (flattened) top level: <Dest>\<BinSubdir> holds <Exe>.exe
# and is the directory that joins the User PATH. Absent = Dest itself (every
# other tool). Only mise uses it today (mise\bin\mise.exe + mise-shim.exe —
# the shim template must sit next to mise.exe for native .exe shims).
```

In `Install-PortableTool`, directly after `$stamp = Join-Path $WsStamps "$($tool.Exe).$($tool.Version).stamp"` add:

```powershell
    # BinSubdir (opt-in): where <Exe>.exe lives under Dest and what joins the
    # PATH — see the $PortableTools comment. Honoured in exactly two places
    # (the stamp fast-path check below and the 'tree' branch's Add-ToUserPath).
    $binDir = if ($Tool.ContainsKey('BinSubdir')) { Join-Path $Tool.Dest $Tool.BinSubdir } else { $Tool.Dest }
```

Then change the fast-path condition `(Test-Path (Join-Path $Tool.Dest "$($Tool.Exe).exe"))` → `(Test-Path (Join-Path $binDir "$($Tool.Exe).exe"))` and the fast-path `Add-ToUserPath $Tool.Dest` → `Add-ToUserPath $binDir`; and in the `'tree'` branch (the `else` after the `single` branch) change its `Add-ToUserPath $Tool.Dest` → `Add-ToUserPath $binDir`. Leave the `exe` and `single` branches untouched.

- [ ] **Step 3: Replace the uv entry with the mise entry**

Replace the whole uv hashtable (from `@{` + `# uv — Python front door …` through its closing `},`) with:

```powershell
    @{
        # mise — the runtime manager (node / Go / uv / gopls / the LSP
        # servers): the Windows half of the Linux both-scopes EGET_TOOL. The
        # zip nests mise\bin\mise.exe + mise-shim.exe (the template mise
        # copies for native .exe shims — without it shims degrade to .cmd
        # wrappers), so 'tree' into its OWN dir with BinSubdir pointing the
        # PATH at bin\. WHAT mise installs is declared by the chezmoi-deployed
        # %USERPROFILE%\.config\mise\conf.d\*.toml (GENERATED from
        # makefile/versions.mk — no runtime pin table lives here) and driven
        # by Invoke-MiseRuntimes after chezmoi apply. uv is one of those
        # runtimes now (it was a portable tool of its own until 2026-09).
        Name       = "mise"
        Exe        = "mise"
        Version    = "2026.9.1"
        Url        = "https://github.com/jdx/mise/releases/download/v2026.9.1/mise-v2026.9.1-windows-x64.zip"
        Sha256     = "9556296db217774e7dae8fc241542d6bbc2351122ba93c8df2a65d3b921d7a28"
        Layout     = "tree"
        BinSubdir  = "bin"
        Dest       = $WsMise
        Repo       = "jdx/mise"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND MISE_VERSION in makefile/versions.mk"
    },
```

Update the `-SkipToolInstall` message in `Invoke-ToolInstall`: `…/jq/OpenCode/omp/uv/DevToys CLI/dnGrep/LogExpert on PATH; … Python env not built` → `…/jq/OpenCode/omp/mise/DevToys CLI/dnGrep/LogExpert on PATH; … mise runtimes not installed, Python env not built`.

- [ ] **Step 4: Interim `Invoke-PythonEnv` line (keeps the script consistent until Task 2)**

In `Invoke-PythonEnv` replace `$uvExe = Join-Path $WsUv "uv.exe"` with `$uvExe = Join-Path $WsRoot "uv\uv.exe"   # interim: Task 2 resolves uv through mise` — `$WsUv` no longer exists; Task 2 rewrites this block.

- [ ] **Step 5: versions.mk comments + the dual-edit swap**

`makefile/versions.mk`: above `MISE_VERSION       := 2026.9.1` add
```make
# mise — DUAL-EDIT with bootstrap.ps1's $PortableTools (Windows portable mise:
# Layout tree + BinSubdir bin; check-invariants.sh verifies). Both scopes on
# Linux (EGET_TOOL); it installs everything in the generated conf.d.
```
and change the `UV_VERSION` comment's last sentence `Dual-edits bootstrap.ps1's $PortableTools until PR 2.` → `No Windows half: Windows installs uv through mise too (bootstrap.ps1's Invoke-MiseRuntimes).`

`scripts/check-invariants.sh`: replace the uv block (lines 124-131) with
```bash
  v=$(mkval MISE_VERSION)
  ref=$(grep -oE 'jdx/mise/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "mise @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "mise drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi
```
`scripts/bump-versions.sh`: in `EXCLUDE="…"` replace `UV_VERSION` with `MISE_VERSION`; in the header comment's numbered rationale, replace the UV sentence (it names `uv` as a bootstrap.ps1 dual-edit) with `MISE_VERSION — dual-edits bootstrap.ps1's $PortableTools (Windows portable mise; sha256 refresh needed)`; if `UV_VERSION` is mentioned there as a dual-edit, delete that mention (uv is a plain pin again).

- [ ] **Step 6: Verify**

```bash
head -c3 bootstrap.ps1 | xxd | head -1                      # ef bb bf (BOM kept)
rg -n 'WsUv|astral-sh/uv' bootstrap.ps1 ; echo "(expect no output)"
rg -n 'BinSubdir' bootstrap.ps1 | wc -l                     # 5 lines: doc comment, entry, 3 in Install-PortableTool
scripts/check-invariants.sh 2>&1 | grep -E 'mise @|uv @|EXCLUDE|✗'   # mise @ 2026.9.1 ok; no uv line; EXCLUDE ok; no ✗
W=$(wslpath -w "$PWD/bootstrap.ps1") && powershell.exe -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$W',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\$_.Message}}else{'parse-ok'}" | tr -d '\r'
```
Expected: BOM present, no uv remnants, `BinSubdir` on 5 lines, invariants green with the mise line, `parse-ok`. Optional if PSScriptAnalyzer exists on Windows: `W=$(wslpath -w "$PWD") && pwsh.exe -NoProfile -Command "Set-Location '$W'; ./scripts/check-ps.ps1" | tr -d '\r'`.

- [ ] **Step 7: Commit + push**

```bash
git add bootstrap.ps1 makefile/versions.mk scripts/check-invariants.sh scripts/bump-versions.sh
git commit -m "feat(windows): mise is a pinned portable tool (tree + BinSubdir); uv retired from \$PortableTools; MISE_VERSION dual-edit replaces UV_VERSION

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
git push -u origin feat/mise-runtimes-windows
```
(The versions.mk edit fires the tool-memory hook; the regenerated TOOLS block is a content no-op — leave `chezmoi/private_dot_claude/CLAUDE.md` out unless `git diff` shows a real change.)

---

### Task 2: `Invoke-MiseRuntimes`, doctor rows, Python env via mise

**Files:**
- Modify: `bootstrap.ps1` — new section 4b after `Invoke-Chezmoi`'s section; `Invoke-PythonEnv` (section 6c) uv resolution + header comment; `Invoke-Doctor` (after the Python env rows); main flow

**Interfaces:**
- Consumes: `mise` on PATH (Task 1), conf.d deployed by `Invoke-Chezmoi`.
- Produces: `$MiseConfDir`, `$MiseShims`, `Get-MiseRuntimesStamp` (returns the stamp path or `$null` when no conf.d file exists), `Invoke-MiseRuntimes`. Task 3's `Invoke-NushellMise` and the doctor rows rely on `$MiseShims`.

- [ ] **Step 1: Section 4b**

Insert after `Invoke-Chezmoi`'s closing `}` (before the `# 5. POWERSHELL PROFILE SHIM` banner):

```powershell
# =============================================================================
# 4b. MISE RUNTIMES — node / Go / uv / gopls / the LSP servers via mise (the
#    Windows half of the Linux `mise-runtimes` Make target). WHAT to install is
#    declared by the two conf.d files chezmoi has just deployed to
#    %USERPROFILE%\.config\mise\conf.d\ (GENERATED from makefile/versions.mk
#    by scripts/gen-mise-config.sh — the single source of every runtime pin;
#    this script carries NO runtime pin table). mise's config dir is
#    %USERPROFILE%\.config\mise on every platform; its data dir (installs +
#    shims) is %LOCALAPPDATA%\mise. Stamp = sha256 of both conf.d files, so any
#    pin change re-runs it. node is force-reinstalled only when the DECLARED
#    version was already present and node is still declared — its npm
#    postinstall carries the language servers, and a changed postinstall only
#    re-runs on a reinstall (the lib/mise.sh gate). Every run re-adds the
#    shims dir to the User PATH (self-heals like the Start Menu shortcuts).
#    Per-user, no admin; warn-and-continue; -SkipToolInstall skips it.
# =============================================================================
$MiseConfDir = Join-Path $env:USERPROFILE ".config\mise\conf.d"
$MiseShims   = Join-Path $env:LOCALAPPDATA "mise\shims"

# Get-MiseRuntimesStamp — the exact stamp path Invoke-MiseRuntimes writes on
# success: a hash of the conf.d files it consumed (sorted by name). Doctor
# calls this SAME helper so its verdict can never drift onto a stale stamp
# (the Get-PythonEnvStamp precedent). $null when no conf.d file is deployed.
function Get-MiseRuntimesStamp {
    $files = @(Get-ChildItem -Path $MiseConfDir -Filter "workstation*.toml" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return $null }
    $text   = ($files | ForEach-Object { Get-Content -Raw -Path $_.FullName }) -join "`n"
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($text)
    $stream = New-Object System.IO.MemoryStream (,$bytes)
    $hash   = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
    return Join-Path $WsStamps "mise-runtimes.$hash.stamp"
}

function Invoke-MiseRuntimes {
    if ($SkipToolInstall) {
        Write-Log "mise runtimes skipped (-SkipToolInstall)"
        return
    }
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "mise runtimes skipped — mise not on PATH (portable-tool step failed? open a NEW shell and re-run .\bootstrap.ps1)"
        return
    }
    $stamp = Get-MiseRuntimesStamp
    if ($null -eq $stamp) {
        Write-Warn "mise runtimes skipped — no $MiseConfDir\workstation*.toml deployed (chezmoi step skipped or failed?)"
        return
    }

    # Shims on the User PATH every run (self-heals) and in-session, so later
    # steps (Invoke-PythonEnv's `mise which uv`, Claude Code's npx) resolve.
    if (-not (Test-Path $MiseShims)) { New-Item -ItemType Directory -Force -Path $MiseShims | Out-Null }
    Add-ToUserPath $MiseShims

    if (Test-Path $stamp) {
        Write-Ok "mise runtimes already installed (conf.d unchanged — $(Split-Path -Leaf $stamp))"
        return
    }

    Write-Log "Installing mise runtimes from $MiseConfDir (node / Go / uv / gopls / LSP servers — a few minutes on first run)..."
    # Native commands chatter on stderr; keep that from tripping an EAP=Stop
    # session (the chezmoi --version precedent in Invoke-CheckForUpdates).
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # `mise where node` succeeds only when the DECLARED node version is
        # already installed — a NODE_VERSION bump therefore installs once.
        & mise where node *> $null
        $hadNode = ($LASTEXITCODE -eq 0)
        $nodeDeclared = [bool](Select-String -Path (Join-Path $MiseConfDir "workstation*.toml") -Pattern '^node\s*=' -Quiet)

        & mise install --yes
        if ($LASTEXITCODE -ne 0) { throw "mise install exited $LASTEXITCODE" }
        if ($hadNode -and $nodeDeclared) {
            Write-Log "  node was already installed — forcing a reinstall so its npm postinstall re-runs"
            & mise install --yes --force node
            if ($LASTEXITCODE -ne 0) { throw "mise install --force node exited $LASTEXITCODE" }
        }
        & mise prune --yes
        if ($LASTEXITCODE -ne 0) { Write-Warn "mise prune exited $LASTEXITCODE (non-fatal)" }

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        Get-ChildItem -Path $WsStamps -Filter "mise-runtimes.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "mise runtimes installed ($MiseShims is on the User PATH)"
    } catch {
        Write-Warn "mise runtimes install failed: $($_.Exception.Message)"
        Write-Warn "  Re-run .\bootstrap.ps1 to retry (no stamp was written); diagnose with: mise doctor ; mise ls --missing"
    } finally {
        $ErrorActionPreference = $oldEap
    }
}
```

- [ ] **Step 2: `Invoke-PythonEnv` resolves uv through mise**

Section 6c header comment: `uv installs the pinned CPython` → `uv (mise-managed — resolved via \`mise which uv\`, so Invoke-MiseRuntimes must have run) installs the pinned CPython`. In the function, replace the block

```powershell
    $uvExe = Join-Path $WsRoot "uv\uv.exe"   # interim: Task 2 resolves uv through mise
    if (-not (Test-Path $uvExe)) {
        Write-Warn "Python env skipped — uv not installed at $uvExe (portable-tool step failed?)"
        return
    }
```
with
```powershell
    # uv is a mise runtime now: ask mise for the binary the deployed conf.d
    # declares (no fixed path — mise's data dir owns the install).
    $uvExe = $null
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $uvExe = (& mise which uv 2>$null | Select-Object -First 1)
        $ErrorActionPreference = $oldEap
    }
    if (-not $uvExe -or -not (Test-Path $uvExe)) {
        Write-Warn "Python env skipped — uv not resolvable via 'mise which uv' (mise runtimes step failed?)"
        return
    }
```

- [ ] **Step 3: Doctor rows**

In `Invoke-Doctor`, directly after the Python env `if/elseif/else` block, add:

```powershell
    $miseStamp = Get-MiseRuntimesStamp
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Bad "mise runtimes: mise not on PATH — re-run .\bootstrap.ps1"
    } elseif ($null -eq $miseStamp) {
        Write-Bad "mise runtimes: no conf.d deployed under $MiseConfDir — re-run .\bootstrap.ps1 (chezmoi step)"
    } else {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $missing = ((& mise ls --missing 2>$null) | Out-String).Trim()
        $ErrorActionPreference = $oldEap
        if ((Test-Path $miseStamp) -and -not $missing) {
            Write-Ok "mise runtimes installed (nothing missing; $(Split-Path -Leaf $miseStamp))"
        } elseif (-not $missing) {
            Write-Warn "mise runtimes present but conf.d moved (no $(Split-Path -Leaf $miseStamp)) — next bootstrap reinstalls"
        } else {
            Write-Bad "mise runtimes missing: $(($missing -split "`r?`n") -join ', ') — re-run .\bootstrap.ps1"
        }
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $shimsOnPath = @(($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $MiseShims.TrimEnd('\') }).Count -gt 0
        if ($shimsOnPath) { Write-Ok "mise shims dir on the User PATH ($MiseShims)" }
        else { Write-Warn "mise shims dir NOT on the User PATH — re-run .\bootstrap.ps1 (self-heals)" }
    }
```

- [ ] **Step 4: Main flow**

After the `Invoke-Chezmoi` line add
`Invoke-MiseRuntimes       # node/Go/uv/gopls/LSP servers from the chezmoi-deployed conf.d (self-heals the shims PATH)`.
Also update the step list in the header comment near the top of the script (the `#   4. chezmoi apply— …` list): add `#   4b. mise runtimes — installs node/Go/uv/gopls/LSP servers from the deployed conf.d` after the chezmoi line.

- [ ] **Step 5: Verify**

```bash
head -c3 bootstrap.ps1 | xxd | head -1
rg -n 'Invoke-MiseRuntimes|Get-MiseRuntimesStamp|Invoke-NushellStarship' bootstrap.ps1 | head   # definitions + main-flow call present; MiseRuntimes call sits between Invoke-Chezmoi and Test-AgeIdentity
rg -n 'WsUv|uv\\uv.exe' bootstrap.ps1 ; echo "(expect no output)"
scripts/check-invariants.sh | tail -1
W=$(wslpath -w "$PWD/bootstrap.ps1") && powershell.exe -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$W',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\$_.Message}}else{'parse-ok'}" | tr -d '\r'
```
Read-only dry check of the stamp hashing (the same pipeline as `Get-MiseRuntimesStamp`, on two scratch files; no install):
```bash
powershell.exe -NoProfile -Command '$d=Join-Path $env:TEMP "mise-stamp-probe"; New-Item -ItemType Directory -Force $d | Out-Null; Set-Content "$d\workstation.toml" "a"; Set-Content "$d\workstation-dev.toml" "b"; $files=@(Get-ChildItem $d -Filter "workstation*.toml" | Sort-Object Name); $text=($files | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"; $s=New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes($text)); (Get-FileHash -InputStream $s -Algorithm SHA256).Hash.Substring(0,8).ToLower(); Remove-Item -Recurse $d' | tr -d '\r'
```
Expected: one 8-hex string; running it twice prints the same string (deterministic, name-sorted).

- [ ] **Step 6: Commit + push**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): Invoke-MiseRuntimes installs from the deployed conf.d; Invoke-PythonEnv resolves uv via mise; doctor rows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
git push
```

---

### Task 3: Shell activation — Nushell autoload + PowerShell profile

**Files:**
- Modify: `bootstrap.ps1` — new section 5g after `Invoke-NushellStarship`; `Invoke-Doctor` (next to the starship.nu row); main flow
- Modify: `chezmoi/AppData/Roaming/nushell/config.nu.tmpl:10-14` (comment)
- Modify: `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl` (after the zoxide block)

**Interfaces:**
- Consumes: `mise` on PATH (Task 1); `$MiseShims` (Task 2) only in prose.
- Produces: `Invoke-NushellMise`; `%APPDATA%\nushell\vendor\autoload\mise.nu`.

- [ ] **Step 1: `Invoke-NushellMise`**

Insert after `Invoke-NushellStarship`'s closing `}` (before the `# 5f. DNGREP CONFIG SEED` banner):

```powershell
# =============================================================================
# 5g. NUSHELL MISE ACTIVATION — Nushell cannot `eval`, so `mise activate nu` is
#    saved as a GENERATED file under vendor\autoload (auto-sourced on startup,
#    exactly like starship.nu) and regenerated every run (self-heals; tracks
#    the installed mise). Never hand-edited, never in config.nu. Verified on
#    nu 0.113.1: an autoloaded activate file is picked up (its export-env
#    runs) — the hook then puts mise's real bin dirs on PATH ahead of the shims
#    dir Invoke-MiseRuntimes added.
# =============================================================================
function Invoke-NushellMise {
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell mise activation — mise not on PATH (install step skipped?)."
        return
    }
    if (-not (Get-Command nu -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell mise activation — nu not on PATH (install step skipped?)."
        return
    }

    $autoload = Join-Path $env:APPDATA "nushell\vendor\autoload"
    $target   = Join-Path $autoload "mise.nu"
    try {
        if (-not (Test-Path $autoload)) { New-Item -ItemType Directory -Force -Path $autoload | Out-Null }
        # UTF-8 WITHOUT a BOM — nu chokes on a leading BOM in sourced scripts.
        $init = (& mise activate nu) -join "`n"
        [System.IO.File]::WriteAllText($target, $init, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Nushell mise activation generated ($target)"
    } catch {
        Write-Warn "Could not generate the Nushell mise activation: $($_.Exception.Message)"
    }
}
```

Main flow: after the `Invoke-NushellStarship` line add
`Invoke-NushellMise        # generate the Nushell mise activation (vendor/autoload — self-heals)`.

Doctor: after the `$nuStarship` row add
```powershell
    $nuMise = Join-Path $env:APPDATA "nushell\vendor\autoload\mise.nu"
    if (Test-Path $nuMise) { Write-Ok "Nushell mise activation generated ($nuMise)" }
    else { Write-Warn "Nushell mise activation missing — re-run .\bootstrap.ps1 (regenerates it)" }
```

- [ ] **Step 2: `config.nu.tmpl` comment**

Replace lines 10-14 (`# This file owns the HAND-WRITTEN config … so there is no \`source\` line for it here).`) with:

```nu
# This file owns the HAND-WRITTEN config (aliases, env, helpers). Two things are
# wired separately by GENERATED files under %APPDATA%\nushell\vendor\autoload\
# (everything there is auto-sourced on startup, so no `source` lines here):
# starship.nu (the prompt — bootstrap.ps1's Invoke-NushellStarship) and mise.nu
# (`mise activate nu` — Invoke-NushellMise; puts the mise-managed node/Go/uv/
# LSP servers on PATH ahead of the shims dir).
```

- [ ] **Step 3: PowerShell profile block**

In `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl`, after the zoxide block add:

```powershell
# --- mise (runtimes: node / Go / uv / LSP servers + per-project mise.toml) ----
# Global pins live in %USERPROFILE%\.config\mise\conf.d (chezmoi-deployed,
# generated from makefile/versions.mk; installed by bootstrap.ps1's
# Invoke-MiseRuntimes). The hook puts the real bin dirs on PATH ahead of the
# shims dir bootstrap added to the User PATH. Dot-sourced by the 5.1 profile
# too — `mise activate pwsh` output is plain PowerShell.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    (& mise activate pwsh) | Out-String | Invoke-Expression
}
```

- [ ] **Step 4: Verify**

```bash
head -c3 bootstrap.ps1 | xxd | head -1
scripts/check-templates.sh 2>&1 | tail -3        # renders config.nu.tmpl + the profile for both groups (nu syntax is checked in CI's templates job; pwsh soft-skips locally)
scripts/check-invariants.sh | tail -1
W=$(wslpath -w "$PWD/bootstrap.ps1") && powershell.exe -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$W',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\$_.Message}}else{'parse-ok'}" | tr -d '\r'
P=$(wslpath -w "$PWD/chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl") && powershell.exe -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$P',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\$_.Message}}else{'profile-parse-ok'}" | tr -d '\r'
```
(The profile's `{{ .chezmoi.hostname }}` sits inside `#` comments, so the raw template parses as PowerShell.)

- [ ] **Step 5: Commit + push**

```bash
git add bootstrap.ps1 chezmoi/AppData/Roaming/nushell/config.nu.tmpl chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl
git commit -m "feat(windows): mise activation for Nushell (vendor/autoload/mise.nu) and PowerShell (profile)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
git push
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md` (mise-runtimes bullet's "Windows half in PR 2" sentence; python-env bullet's Windows half; the Windows-installs bullet; the dual-edit list; careful-files if `BinSubdir` deserves a mention)
- Modify: `docs/claude/invariants.md` (same three bullets), `docs/claude/file-care.md` (`bootstrap.ps1` entry; the conf.d bullet), `docs/claude/verification.md` (line 24 list + a Windows recipe)
- Modify: `README.html` (Windows tools list `<li>`; the two `-SkipToolInstall` / portable lists at ~3316 and ~5346; §setup-windows sentence), `CLAUDE_CHANGELOG.md` (first row)

- [ ] **Step 1: `CLAUDE.md`**

(a) mise-runtimes bullet: replace `Windows half in PR 2 (spec …)` with: `**Windows half:** mise is a pinned portable tool (\`Layout = "tree"\` + the opt-in \`BinSubdir = "bin"\` → \`workstation\mise\bin\` on the User PATH — the zip nests \`mise.exe\` + \`mise-shim.exe\`, the latter is what makes native \`.exe\` shims; dual-edits \`MISE_VERSION\`); \`Invoke-MiseRuntimes\` runs right after \`Invoke-Chezmoi\` and installs from the deployed \`%USERPROFILE%\.config\mise\conf.d\` (stamp = sha256 of both files; \`mise where node\` gate; \`%LOCALAPPDATA%\mise\shims\` re-added to the User PATH every run); Nushell gets a generated \`vendor\autoload\mise.nu\`, the PowerShell profile \`mise activate pwsh\`; \`Invoke-PythonEnv\` resolves uv via \`mise which uv\`. No runtime pin table on Windows.`
(b) python-env bullet: `Windows half: uv in \`$PortableTools\` (own \`workstation\uv\` dir — \`tree\` extraction WIPES its Dest, so never into \`workstation\bin\`) + \`Invoke-PythonEnv\`` → `Windows half: uv is mise-installed (\`Invoke-PythonEnv\` resolves it via \`mise which uv\` after \`Invoke-MiseRuntimes\`) + \`Invoke-PythonEnv\``.
(c) Windows-installs bullet (it never mentioned uv — uv lived only in the python-env bullet): after the sentence that begins `**DevToys CLI is a pinned portable tool too**` insert `**mise is a pinned portable tool too** (2026-09-16; \`Layout = "tree"\` into \`workstation\mise\` with the opt-in \`BinSubdir = "bin"\` — the only user of that key, \`Install-PortableTool\` honours it in the stamp check and the PATH entry; dual-edits \`MISE_VERSION\`); it installs node/Go/uv/gopls/the LSP servers from the chezmoi-deployed conf.d via \`Invoke-MiseRuntimes\` (step 4b, right after chezmoi apply) — uv is a mise runtime on Windows, not a portable tool.`
(d) dual-edit list: replace `\`UV_VERSION\` (\`versions.mk\` ↔ \`bootstrap.ps1\` \`$PortableTools\`)` with `\`MISE_VERSION\` (\`versions.mk\` ↔ \`bootstrap.ps1\` \`$PortableTools\`, \`Layout = "tree"\` + \`BinSubdir = "bin"\` — verified by \`check-invariants.sh\`)`; keep `PYTHON_VERSION`.

- [ ] **Step 2: `docs/claude/*.md`**

`invariants.md`: apply the three CLAUDE.md edits (a)–(c) to the matching bullets (the mise-runtimes one, the python-env one, the Windows-installs one) with the same text. `file-care.md`: in the `scripts/manage-hosts.ps1 and bootstrap.ps1` bullet replace `+ uv + DevToys CLI` with `+ mise + DevToys CLI`, and the parenthetical `uv is a \`tree\`-layout install into its OWN \`workstation\uv\` directory — … — and its pin dual-edits \`UV_VERSION\`` with `mise is a \`tree\`-layout install into its OWN \`workstation\mise\` directory with the opt-in \`BinSubdir = "bin"\` (the zip nests \`bin\mise.exe\` + \`mise-shim.exe\`; \`Install-PortableTool\` honours the key in the stamp check and the PATH entry only) and its pin dual-edits \`MISE_VERSION\`; uv is a mise runtime, not a portable tool`; in the conf.d bullet append `Deploys to Windows too (\`%USERPROFILE%\.config\mise\conf.d\` — mise's config dir on every platform); \`Invoke-MiseRuntimes\` hashes both files for its stamp.` `verification.md`: line 24 list `OpenCode, omp, uv, DevToys CLI` → `OpenCode, omp, mise, DevToys CLI`; append after it:
```markdown
- **mise runtimes on Windows** (after touching `Invoke-MiseRuntimes`, `Invoke-NushellMise`, the mise `$PortableTools` entry, `Invoke-PythonEnv`, or the two shell templates): the user runs `.\bootstrap.ps1` in a Windows terminal (first run: mise portable install, then a few minutes of `mise install`, then the Python env rebuild). Read-only probes from WSL via `powershell.exe -NoProfile -Command …`: `mise doctor` (data dir `%LOCALAPPDATA%\mise`, config `~\.config\mise`), `mise ls --missing` (empty), `Get-Command node, go, uv, gopls, typescript-language-server, lua-language-server, basedpyright-langserver` (all under `%LOCALAPPDATA%\mise\shims`), `Test-Path "$(mise where node)\node_modules\typescript\lib\tsserver.js"` (True — the 5.x pin), `nu -c 'which node'`, `pwsh -NoProfile -Command 'Get-Command node'` (profile activation), `.\bootstrap.ps1 -Doctor` (✓ mise 2026.9.1 portable, ✓ mise runtimes installed, ✓ shims dir on the User PATH, ✓ Nushell mise activation, ✓ Python env), `.\bootstrap.ps1 -CheckForUpdates` (a mise row against jdx/mise tags). A second `.\bootstrap.ps1` prints "mise runtimes already installed" (stamp hit).
```

- [ ] **Step 3: `README.html`**

(a) Windows tools list: replace the uv `<li>` (`<strong>uv</strong> &mdash; the Python front door; … re-run <code>bootstrap.ps1</code>.` — the whole list item) with:
```html
                        <li>
                            <strong>mise</strong> &mdash; the runtime manager;
                            pinned, sha256-verified portable tree into its own
                            <code>%LOCALAPPDATA%\workstation\mise</code>
                            directory (<code>bin\</code> joins the PATH: the
                            zip nests <code>mise.exe</code> next to the
                            <code>mise-shim.exe</code> template that gives
                            every tool a native <code>.exe</code> shim). The
                            pin dual-edits <code>MISE_VERSION</code> in
                            <code>makefile/versions.mk</code> (the Linux half
                            is the eget-installed <code>mise</code>, both
                            dev_machine and prod_machine). Right after chezmoi
                            applies, a bespoke step installs what the deployed
                            <code>%USERPROFILE%\.config\mise\conf.d\</code>
                            declares &mdash; Node.js, Go, uv, gopls and the
                            language servers, pinned in <code>versions.mk</code>
                            and rendered into that config &mdash; and puts
                            <code>%LOCALAPPDATA%\mise\shims</code> on the User
                            PATH. The blessed Python scripting env at
                            <code>%LOCALAPPDATA%\workstation\python-env</code>
                            (a pinned CPython plus
                            Textual/Click/rich/httpx/pydantic/typer/polars/duckdb)
                            is then built with mise's uv, dropping
                            <code>wpy</code>/<code>textual</code>/<code>typer</code>
                            shims into <code>workstation\bin</code>. Upgrade the
                            libs: delete the <code>python-env.*.stamp</code>
                            under <code>%LOCALAPPDATA%\workstation\stamps</code>
                            and re-run <code>bootstrap.ps1</code>.
                        </li>
```
(keep whatever trailing sentences the old `<li>` carried that are still true — read it first; the old text about `%LOCALAPPDATA%\workstation\python-env` and the stamp upgrade is preserved above).
(b) The two lists `Terminal/Starship/Helix/Nushell/jq/OpenCode/omp/uv/DevToys` (≈3316) and `(Starship/Helix/Nushell/jq/OpenCode/omp/uv/DevToys` (≈5346): `uv` → `mise`; in the first, `installs and the Python scripting env build,` → `installs, the mise runtimes and the Python scripting env build,`.
(c) No other README prose needs changing: `rg -n 'Windows-side|node\.exe' README.html` shows only the ccstatusline WSL-trap sentences (still true — a Windows npx must never run from a WSL working dir). Run that grep and confirm; do not edit those passages.
(d) Troubleshooting: in the LSP entry add one `<li>`: `<li><strong>Windows</strong> &mdash; the same servers install via <code>bootstrap.ps1</code>'s mise step; <code>mise ls --missing</code> and <code>.\bootstrap.ps1 -Doctor</code> are the checks; open a new terminal after the first run (User PATH).</li>`.

- [ ] **Step 4: `CLAUDE_CHANGELOG.md` first row**

```markdown
| **mise owns the runtime layer on Windows too (PR 2 of 2).** `bootstrap.ps1`: mise is a pinned portable tool (`Layout = "tree"` + new opt-in `BinSubdir = "bin"` → `workstation\mise\bin` on the User PATH; dual-edits `MISE_VERSION` — `UV_VERSION`'s Windows dual-edit retired, uv is a mise runtime now); new step 4b `Invoke-MiseRuntimes` right after chezmoi apply installs node/Go/uv/gopls/LSP servers from the deployed `%USERPROFILE%\.config\mise\conf.d\` (stamp = sha256 of both files; `mise where node` gate; `%LOCALAPPDATA%\mise\shims` re-added to the User PATH every run); `Invoke-NushellMise` generates `vendor\autoload\mise.nu`, the PowerShell profile runs `mise activate pwsh`; `Invoke-PythonEnv` resolves uv via `mise which uv`; `-Doctor` gains mise-runtimes / shims / mise.nu rows. Side effect: the Windows host gets the LSP servers for the first time. | **Yes** | Windows tools list (mise `<li>` replaces uv), the two `-SkipToolInstall`/portable lists, one Windows sentence in the LSP troubleshooting entry. |
```

- [ ] **Step 5: Verify + commit + push**

```bash
npm install --no-save --no-package-lock jsdom@30.0.1 >/dev/null 2>&1 && node scripts/check-readme.mjs && scripts/check-invariants.sh | tail -1
rg -n 'workstation\\uv|UV_VERSION.*bootstrap|uv.*\$PortableTools' CLAUDE.md docs/claude README.html ; echo "(expect no live claims that uv is a portable tool)"
git add CLAUDE.md docs/claude README.html CLAUDE_CHANGELOG.md
git commit -m "docs(windows): mise portable + Invoke-MiseRuntimes, uv via mise, MISE_VERSION dual-edit

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
git push
```

---

### Task 5: Windows host run, verification, PR

**Files:** none (verification only)

- [ ] **Step 1: The user runs the bootstrap on Windows**

The Windows clone lives at `%USERPROFILE%\.local\share\chezmoi`. Ask the user to run, in a Windows terminal (pwsh or Windows PowerShell):
```
cd ~\.local\share\chezmoi; git fetch origin; git checkout feat/mise-runtimes-windows; git pull; .\bootstrap.ps1
```
Expected: `mise 2026.9.1 installed to …\workstation\mise` (portable step), `chezmoi applied`, `Installing mise runtimes from …\.config\mise\conf.d …` then every tool `✓ installed` (node / go / uv / gopls / lua-language-server / basedpyright — first run takes a few minutes; gopls compiles), `mise runtimes installed (…\mise\shims is on the User PATH)`, `Nushell mise activation generated`, `Python env 3.14.7 built` (rebuilds: the deployed stamp is the old 3.14.6 one). Then a second `.\bootstrap.ps1` (fast): `mise 2026.9.1 already installed`, `mise runtimes already installed (conf.d unchanged — …)`, `Python env 3.14.7 already built`.

- [ ] **Step 2: Read-only probes from WSL**

```bash
powershell.exe -NoProfile -Command '$ErrorActionPreference="Continue"; mise doctor 2>&1 | Select-String "version|activated|shims_on_path|config:|data:"; mise ls --missing; "missing-above-should-be-empty"; (Get-Command node,go,uv,gopls,typescript-language-server,lua-language-server,basedpyright-langserver -ErrorAction SilentlyContinue).Source; "tsserver: " + (Test-Path ((& mise where node) + "\node_modules\typescript\lib\tsserver.js")); "ts-ls cmd: " + (Test-Path ((& mise where node) + "\typescript-language-server.cmd")); "ts-ls: " + (& typescript-language-server --version); "legacy uv dir: " + (Test-Path "$env:LOCALAPPDATA\workstation\uv"); nu -c "which node | get path.0"; pwsh -Command "(Get-Command node).Source"; powershell -Command "(Get-Command node).Source"' | tr -d '\r'
# Windows PowerShell 5.1 must load the mise-activating profile cleanly (no red text above the value):
powershell.exe -NoProfile -Command "powershell -Command \"'profile-ok'\"" | tr -d '\r'
powershell.exe -NoProfile -Command 'Set-Location $env:USERPROFILE\.local\share\chezmoi; .\bootstrap.ps1 -Doctor' | tr -d '\r' | grep -iE 'mise|python env|nushell'
powershell.exe -NoProfile -Command 'Set-Location $env:USERPROFILE\.local\share\chezmoi; .\bootstrap.ps1 -CheckForUpdates' | tr -d '\r' | grep -i mise
```
Expected: `mise doctor` shows version 2026.9.1, `shims_on_path: yes` from ANY new shell (the shims dir is on the User PATH) and `activated: yes` ONLY in an activated shell — nu (the autoloaded `mise.nu`) or pwsh/powershell with the profile loaded; the outer `-NoProfile` probe reporting `activated: no` is correct, not a failure. Config `~\.config\mise`, data `%LOCALAPPDATA%\mise`; `mise ls --missing` empty; every `Get-Command` resolves under `…\mise\shims`; `tsserver: True`; `ts-ls cmd: True` (the npm postinstall ran — the `.cmd` wrapper sits beside mise's node) and `ts-ls: 6.0.0` through the shim; `legacy uv dir: False` with `(Get-Command uv).Source` under `…\mise\shims` (the retired portable uv, its stamp and its User PATH entry were swept); nu resolves node (activation via autoload); `pwsh -Command` AND `powershell -Command` — both WITHOUT `-NoProfile`, since 5.1 loads the same profile through its loader — resolve node through the profile's `mise activate pwsh`; `powershell -Command "'profile-ok'"` prints `profile-ok` with NO red error text above it (mise's pwsh activation must be 5.1-safe); `-Doctor` rows ✓ for mise portable, mise runtimes, shims dir, Nushell mise activation, Python env; `-CheckForUpdates` shows a mise row (`2026.9.1 → 2026.9.x available` with the dual-edit hint is fine). If `mise doctor` reports `shims_on_path: no` even in a fresh shell, the User PATH entry is missing — `Add-ToUserPath` was not reached.

**winget node caveat.** The host has a winget `OpenJS.NodeJS.LTS` node (24.x) on the User PATH ahead of the shims dir. Decide BEFORE the run: `winget uninstall OpenJS.NodeJS.LTS` (mise owns node now — recommended) or keep it, in which case non-activated shells (cmd, Git Bash, `-NoProfile`) resolve node 24 while activated nu/pwsh get 26.8.1 and the LSP `.cmd` wrappers still use their sibling node; the `Get-Command node` probe expects the shims path only after the uninstall.

- [ ] **Step 3: PSScriptAnalyzer (CI) + open the PR**

```bash
scripts/check-invariants.sh | tail -1 && bash .claude/hooks/test-hooks.sh | tail -1 && scripts/check-templates.sh | tail -1
gh pr create --title "feat(windows): mise-runtimes on Windows — portable mise + Invoke-MiseRuntimes (PR 2/2)" --body "$(cat <<'EOF'
## Summary
- mise is a pinned portable tool (`Layout = "tree"` + new opt-in `BinSubdir = "bin"` → `workstation\mise\bin` on the User PATH); uv leaves `$PortableTools` (it is a mise runtime now); `MISE_VERSION` replaces `UV_VERSION` as the `versions.mk` ↔ `bootstrap.ps1` dual-edit (bumper EXCLUDE + `check_version_pins`)
- new step 4b `Invoke-MiseRuntimes` right after chezmoi apply: installs node/Go/uv/gopls/LSP servers from the deployed `%USERPROFILE%\.config\mise\conf.d\` (generated from `versions.mk` — no Windows pin table), stamp = sha256 of both files, `mise where node` force gate, `%LOCALAPPDATA%\mise\shims` re-added to the User PATH every run; warn-and-continue
- `Invoke-NushellMise` generates `vendor\autoload\mise.nu`; the PowerShell profile runs `mise activate pwsh`; `Invoke-PythonEnv` resolves uv via `mise which uv`; `-Doctor` rows for mise runtimes / shims / mise.nu
- docs: CLAUDE.md, docs/claude, README Windows list + troubleshooting, changelog; spec decisions 10–14 (`docs/superpowers/specs/2026-09-13-mise-runtimes-design.md`)

## Test plan
- [x] `scripts/check-invariants.sh` (mise dual-edit, EXCLUDE), hook tests, `check-templates.sh`, `check-readme.mjs`; PowerShell parse checks via interop; CI `powershell` job (PSScriptAnalyzer)
- [x] Windows host: `.\bootstrap.ps1` twice (install, then stamp hits), `mise doctor`, `mise ls --missing` empty, every server resolves under `%LOCALAPPDATA%\mise\shims`, `tsserver.js` present under mise's node, `nu -c 'which node'` + pwsh `Get-Command node` via activation, `-Doctor` / `-CheckForUpdates` rows

Side effect: the Windows host installs the LSP servers for the first time; the Claude Code LSP plugin resolves them by bare name through the shims dir.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG
EOF
)"
gh pr checks --watch
```
