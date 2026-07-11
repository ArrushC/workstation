# SSHFS-Win Elevated Install Class Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SSHFS-Win to the Windows bootstrap as a new best-effort elevated install class (`$ElevatedTools`): registry-detect → winget → digest/pin-verified MSI fallback → soft-fail, behind a new `-SkipElevated` flag, with `-Doctor`/`-CheckForUpdates` coverage and docs.

**Architecture:** A third declarative tool list in `bootstrap.ps1` mirroring `$PortableTools`/`$InstallerTools`, plus two functions: `Install-ElevatedTool` (winget path + orchestration) and `Install-ElevatedMsi` (one MSI of the fallback chain). Every failure path warns and continues — this class must never abort the bootstrap. Spec: `docs/superpowers/specs/2026-07-10-sshfs-win-elevated-install-design.md`.

**Tech Stack:** PowerShell 5.1-compatible script (`bootstrap.ps1`), GitHub REST API, winget, msiexec. No test framework exists for this script (no Pester in repo) — the repo's verification convention is: PowerShell parser check + PSScriptAnalyzer (`make ps-lint`, enforced in CI) + `scripts/check-invariants.sh` (BOM) + manual runs on the Windows host. "Test" steps below follow that convention.

## Global Constraints

- **Branch:** work happens on `feat/windows-sshfs-win` (already exists; spec committed as `5ea3443`).
- **PowerShell 5.1 compatibility:** no ternary operator, no `??`, no PS7-only syntax anywhere in `bootstrap.ps1`.
- **`Set-StrictMode -Version Latest` is active:** probe optional hashtable keys with `.ContainsKey('Key')`, probe API-object properties with `$obj.PSObject.Properties['name']` — never bare access.
- **`bootstrap.ps1` must keep its UTF-8 BOM** (`EF BB BF`) — PowerShell 5.1 mis-decodes `✓`/`✗` glyphs without it. The repo's `post-edit-guard.sh` hook auto-repairs this after edits; `scripts/check-invariants.sh` verifies it.
- **Best-effort invariant:** no code path added by this plan may call `Write-Fail` (it exits the script). Failure = `Write-Warn`/`Write-Bad` + return.
- **Style:** match existing helpers `Write-Log`/`Write-Ok`/`Write-Warn`/`Write-Bad` (defined at `bootstrap.ps1:122-126`), 4-space indent, comment style of `Install-InstallerTool`.
- **README.html house style:** HTML entities (`&mdash;`, `&rsquo;`, `&ldquo;`/`&rdquo;`), `<code>` for commands, `<details data-ts>` for troubleshooting entries.
- **Commit footer** (every commit):
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a
  ```
- **Parse-check command** (used by several tasks; run from the repo root in WSL — Windows interop is on):
  ```bash
  WINPATH=$(wslpath -w bootstrap.ps1)
  powershell.exe -NoProfile -Command "\$tok=\$null; \$err=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$WINPATH', [ref]\$tok, [ref]\$err); if (\$err.Count) { \$err | ForEach-Object { \$_.Message }; exit 1 } else { 'PARSE OK' }"
  ```
  Expected output: `PARSE OK`.

---

### Task 1: `-SkipElevated` flag, `$ElevatedTools` data, header docs

**Files:**
- Modify: `bootstrap.ps1` (header comment ~lines 9-93, param block ~line 103, after `$InstallerTools` closing `)` ~line 268)

**Interfaces:**
- Consumes: nothing (pure data + docs).
- Produces: `$ElevatedTools` — array of one hashtable with keys `Name` (string), `WingetId` (string), `DetectName` (string glob), `Repo` (string `owner/repo`), `Msi` (array of hashtables with keys `Name`, `WingetId`, `Repo`, `AssetMatch`, `DetectName`, and optional `Sha256Pin`). Also the script param `[switch]$SkipElevated`. Tasks 2 and 3 rely on these exact key names.

- [ ] **Step 1: Add the SSHFS-Win line to the header install-model block**

In the header comment, find:

```
#   - Helix     — pinned portable .zip (sha256-verified)    → workstation\helix
#                 (hx.exe + bundled runtime/; no HELIX_RUNTIME env var needed)
```

and append directly below:

```
#   - SSHFS-Win — BEST-EFFORT ELEVATED (the ONE exception to no-admin): mounts
#                 remote Unix filesystems over SSH (\\sshfs\user@host). Depends
#                 on the WinFsp kernel driver -> machine-scope MSIs -> UAC
#                 prompt. winget first, digest/pin-verified MSI fallback when
#                 winget is absent, soft-fail everywhere. Skip: -SkipElevated.
```

- [ ] **Step 2: Amend the header flow narrative (step 2 of the flow)**

Find:

```
#   2. tool install — chezmoi (official installer) + WezTerm/Starship/Helix (pinned
#                     portable downloads), all into %LOCALAPPDATA%\workstation.
```

Replace with:

```
#   2. tool install — chezmoi (official installer) + WezTerm/Starship/Helix (pinned
#                     portable downloads), all into %LOCALAPPDATA%\workstation;
#                     then the installer-class apps (Obsidian, Zed) and the
#                     best-effort elevated class (SSHFS-Win — may pop UAC).
```

- [ ] **Step 3: Amend the NO ADMIN REQUIRED header paragraph**

Find:

```
# NO ADMIN REQUIRED: every step writes to per-user locations (workstation\ on
# the User PATH, CurrentUser PSGallery, HKCU fonts, ~/.ssh).
```

Replace with:

```
# NO ADMIN REQUIRED: every step writes to per-user locations (workstation\ on
# the User PATH, CurrentUser PSGallery, HKCU fonts, ~/.ssh) — with ONE
# sanctioned, best-effort exception: $ElevatedTools (SSHFS-Win + its WinFsp
# kernel-driver dependency) pops UAC when not yet installed. Declining the
# prompt (or -SkipElevated, or no winget + no network) soft-fails that step
# only; everything else still completes with zero elevation.
```

- [ ] **Step 4: Document `-SkipElevated` in the header flags list**

Find:

```
#   -ForceInstaller     re-run installer-layout tool installs (e.g. Obsidian) even
#                       if already present. Portable tools (WezTerm/Starship/Helix)
#                       are unaffected — they reinstall on a version-pin bump.
```

Append directly below:

```
#   -SkipElevated       skip the best-effort ELEVATED installs ($ElevatedTools:
#                       SSHFS-Win + WinFsp). Everything else stays admin-free;
#                       this is the only step that can pop a UAC prompt.
```

- [ ] **Step 5: Add the param**

In the `param(...)` block, find `[switch]$ForceInstaller,` and add on the next line:

```powershell
    [switch]$SkipElevated,
```

- [ ] **Step 6: Add the `$ElevatedTools` list**

Immediately after the `$InstallerTools = @( ... )` closing `)` (the Zed entry is last), insert:

```powershell
# Elevated tools — the ONE sanctioned exception to the no-admin rule. SSHFS-Win
# mounts remote Unix filesystems over SSH (\\sshfs\user@host UNC paths / net use
# drive letters); it depends on WinFsp, a kernel-mode filesystem driver, so both
# MSIs are machine-scope and a UAC prompt is unavoidable. Install is BEST-EFFORT:
# Uninstall-registry detect first (an already-provisioned machine never sees
# UAC), then winget (its manifest pulls WinFsp.WinFsp as a dependency), then a
# digest/pin-verified direct-MSI fallback when winget is ABSENT. EVERY failure
# mode (declined UAC, offline, hash mismatch) warns and continues — this class
# never aborts the bootstrap. -SkipElevated skips it; -ForceInstaller reinstalls
# (and adds --force on the winget path). NOT pinned in versions.mk — latest-
# release model, same as $InstallerTools (winget installs latest anyway).
$ElevatedTools = @(
    @{
        Name       = "SSHFS-Win"
        WingetId   = "SSHFS-Win.SSHFS-Win"   # manifest declares WinFsp.WinFsp as a dependency
        DetectName = "SSHFS-Win*"            # HKLM Uninstall DisplayName glob (machine-scope MSI)
        Repo       = "winfsp/sshfs-win"      # for -CheckForUpdates tag lookups
        # MSI fallback chain (winget absent) — installed IN ORDER; each entry is
        # skipped when its own DetectName is already registered:
        Msi        = @(
            @{
                Name       = "WinFsp"
                WingetId   = "WinFsp.WinFsp"
                Repo       = "winfsp/winfsp"
                AssetMatch = "winfsp-*.msi"
                DetectName = "WinFsp*"
            },
            @{
                Name       = "SSHFS-Win"
                WingetId   = "SSHFS-Win.SSHFS-Win"
                Repo       = "winfsp/sshfs-win"
                AssetMatch = "sshfs-win-*-x64.msi"
                DetectName = "SSHFS-Win*"
                # v3.5.20357 (2020) predates GitHub's per-asset digests (the API
                # reports digest: null); official x64 sha256 from the winget
                # manifest (microsoft/winget-pkgs manifests/s/SSHFS-Win) instead:
                Sha256Pin  = "1657e397f8dce1c2d2e3220007f9c9f882631882b9bec4608f7835e87dcd096c"
            }
        )
    }
)
```

- [ ] **Step 7: Parse-check**

Run the parse-check command from Global Constraints.
Expected: `PARSE OK`.

- [ ] **Step 8: Invariants check (BOM etc.)**

Run: `bash scripts/check-invariants.sh`
Expected: `✓ all invariant checks passed` (specifically `3 .ps1 files carry EF BB BF`).

- [ ] **Step 9: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): add \$ElevatedTools class data + -SkipElevated flag

SSHFS-Win/WinFsp declarative entry (winget id, registry detect globs, MSI
fallback chain with the winget-manifest sha256 pin for the digest-less 2020
release) and header docs for the one sanctioned elevation exception."
```

(with the standard commit footer)

---

### Task 2: `Install-ElevatedMsi` + `Install-ElevatedTool` + wiring

**Files:**
- Modify: `bootstrap.ps1` (after `Install-InstallerTool`'s closing `}` ~line 662; inside `Invoke-ToolInstall` ~lines 664-688)

**Interfaces:**
- Consumes: `$ElevatedTools`, `$SkipElevated`, `$ForceInstaller` (Task 1); existing helpers `Test-InstallerPresent -DisplayName <glob>` (returns bool), `Write-Log`/`Write-Ok`/`Write-Warn`/`Write-Bad`.
- Produces: `Install-ElevatedTool -Tool <hashtable>` (returns nothing) and `Install-ElevatedMsi -Msi <hashtable>` (returns `$true`/`$false`). Task 3 does not call these, but relies on the same `$ElevatedTools` key names.

- [ ] **Step 1: Add `Install-ElevatedMsi`**

Insert after `Install-InstallerTool`'s closing `}` (before `function Invoke-ToolInstall`):

```powershell
# One MSI of an elevated tool's fallback chain: resolve the LATEST GitHub
# release, download, verify (API digest -> Sha256Pin -> warn+proceed), install
# via msiexec -Verb RunAs. A silent machine-scope msiexec from a non-elevated
# shell does NOT trigger UAC — it fails with MSI error 1925; -Verb RunAs is
# what pops the prompt, and a DECLINED prompt THROWS (caught into a soft-fail).
# A hash mismatch refuses this MSI (Write-Bad, never Write-Fail — this class
# must not abort the bootstrap; refusing to run an elevated binary is the safe
# side). Returns $true when the MSI is (already) installed, $false otherwise.
function Install-ElevatedMsi {
    param([hashtable]$Msi)

    if (Test-InstallerPresent -DisplayName $Msi.DetectName) {
        Write-Ok "$($Msi.Name) already installed"
        return $true
    }

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }

    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($Msi.Repo)/releases/latest" `
            -Headers $headers -UseBasicParsing
    } catch {
        Write-Warn "$($Msi.Name): GitHub API lookup failed: $($_.Exception.Message)"
        return $false
    }

    $assets = @($release.assets | Where-Object { $_.name -like $Msi.AssetMatch })
    if ($assets.Count -eq 0) {
        Write-Warn "$($Msi.Name): no asset matching '$($Msi.AssetMatch)' in $($release.tag_name)"
        return $false
    }
    if ($assets.Count -gt 1) {
        Write-Warn "$($Msi.Name): $($assets.Count) assets match '$($Msi.AssetMatch)' — using $($assets[0].name)"
    }
    $asset  = $assets[0]
    $tmpMsi = Join-Path $env:TEMP "ws-$($Msi.Name).msi"

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpMsi -UseBasicParsing
    } catch {
        Remove-Item $tmpMsi -Force -ErrorAction SilentlyContinue
        Write-Warn "$($Msi.Name) download failed: $($_.Exception.Message)"
        return $false
    }

    try {
        # Verify: GitHub API digest -> Sha256Pin fallback -> warn+proceed (same
        # escalation as Install-InstallerTool; the pin covers digest-less
        # pre-2025 releases like sshfs-win v3.5.20357). Probe 'digest' via
        # PSObject.Properties — StrictMode throws on bare access when absent.
        $digest   = if ($asset.PSObject.Properties['digest']) { $asset.digest } else { $null }
        $expected = $null
        if ($digest -and $digest.StartsWith("sha256:")) {
            $expected = $digest.Substring(7).ToLower()
        } elseif ($Msi.ContainsKey('Sha256Pin')) {
            $expected = $Msi.Sha256Pin.ToLower()
        }
        if ($expected) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $tmpMsi).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Bad "$($Msi.Name) sha256 mismatch — refusing to install (corrupted or tampered download)."
                Write-Bad "  expected: $expected"
                Write-Bad "  actual:   $actual"
                return $false
            }
        } else {
            Write-Warn "$($Msi.Name): no sha256 available for $($asset.name) — skipping hash verification."
        }

        try {
            $proc = Start-Process msiexec -ArgumentList "/i `"$tmpMsi`" /qn /norestart" `
                -Verb RunAs -Wait -PassThru
        } catch {
            Write-Warn "$($Msi.Name): elevation declined or unavailable ($($_.Exception.Message))"
            return $false
        }
        if ($proc.ExitCode -eq 3010) {
            Write-Ok "$($Msi.Name) installed ($($release.tag_name)) — reboot may be required"
            return $true
        }
        if ($proc.ExitCode -ne 0) {
            Write-Warn "$($Msi.Name): msiexec exited with code $($proc.ExitCode) — verify it installed"
            return $false
        }
        Write-Ok "$($Msi.Name) installed ($($release.tag_name))"
        return $true
    } finally {
        Remove-Item $tmpMsi -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Add `Install-ElevatedTool`**

Insert directly after `Install-ElevatedMsi`'s closing `}`:

```powershell
# Install an elevated (machine-scope) tool — the ONE exception to the no-admin
# rule; see $ElevatedTools. BEST-EFFORT: every failure path warns and returns.
# Chain: Uninstall-registry detect (no UAC when present) -> winget (manifest
# dependencies pull WinFsp; UAC pops) -> direct-MSI fallback ONLY when winget
# is ABSENT (a winget FAILURE is deliberately not retried via MSI — the cause,
# a declined UAC or no network, would recur and just pop a second prompt) ->
# manual instructions.
function Install-ElevatedTool {
    param([hashtable]$Tool)

    # Idempotency first — an already-provisioned machine must never see UAC.
    if ((-not $ForceInstaller) -and (Test-InstallerPresent -DisplayName $Tool.DetectName)) {
        Write-Ok "$($Tool.Name) already installed (use -ForceInstaller to reinstall)"
        return
    }

    Write-Log "Installing $($Tool.Name) (machine-scope)..."
    Write-Warn "$($Tool.Name) needs a machine-wide install (WinFsp kernel driver) — the ONE elevated step; expect a UAC prompt (skip with -SkipElevated)"

    $manualHint = "install manually later:  winget install $($Tool.WingetId)"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $wingetArgs = @(
            "install", "--id", $Tool.WingetId, "--exact",
            "--accept-source-agreements", "--accept-package-agreements"
        )
        if ($ForceInstaller) { $wingetArgs += "--force" }
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & winget @wingetArgs
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($code -eq 0) {
            Write-Ok "$($Tool.Name) installed (winget $($Tool.WingetId))"
        } else {
            Write-Warn "$($Tool.Name): winget exited with code $code (declined UAC? offline?) — skipping; $manualHint"
        }
        return
    }

    Write-Warn "winget not found — falling back to direct MSI downloads"
    foreach ($msi in $Tool.Msi) {
        if (-not (Install-ElevatedMsi -Msi $msi)) {
            Write-Warn "$($Tool.Name): MSI chain stopped at $($msi.Name) — $manualHint"
            return
        }
    }
    Write-Ok "$($Tool.Name) installed (MSI fallback)"
}
```

- [ ] **Step 3: Wire into `Invoke-ToolInstall`**

Find (inside `Invoke-ToolInstall`):

```powershell
    foreach ($tool in $InstallerTools) { Install-InstallerTool -Tool $tool }
```

Append directly below:

```powershell
    # Elevated class last, so a declined UAC can't interrupt the admin-free
    # installs above. Best-effort; -SkipElevated opts out entirely.
    if ($SkipElevated) {
        Write-Log "Elevated tool install skipped (-SkipElevated) — SSHFS-Win/WinFsp not installed"
    } else {
        foreach ($tool in $ElevatedTools) { Install-ElevatedTool -Tool $tool }
    }
```

- [ ] **Step 4: Update the `-SkipToolInstall` skip message**

In `Invoke-ToolInstall`, find:

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix on PATH; Obsidian/Zed not installed"
```

Replace with:

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix on PATH; Obsidian/Zed/SSHFS-Win not installed"
```

- [ ] **Step 5: Parse-check**

Run the parse-check command from Global Constraints.
Expected: `PARSE OK`.

- [ ] **Step 6: PSScriptAnalyzer (best-effort locally, enforced in CI)**

Run: `make -C makefile ps-lint MODE=prod`
Expected: either a clean pass, or `pwsh not installed — skipped (CI enforces PowerShell lint)` — in the latter case CI's `lint.yml` is the gate; do not skip the parse-check above.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): best-effort elevated install — winget, MSI fallback, soft-fail

Install-ElevatedTool: registry detect -> winget (--force with -ForceInstaller;
no MSI retry after a winget failure, the cause would just re-pop UAC) ->
Install-ElevatedMsi fallback when winget is absent (latest GitHub release,
digest/Sha256Pin verification, msiexec -Verb RunAs so a declined UAC throws
into a catch). No path calls Write-Fail; the bootstrap stays runnable with
zero elevation."
```

(with the standard commit footer)

---

### Task 3: `-Doctor` and `-CheckForUpdates` coverage

**Files:**
- Modify: `bootstrap.ps1` (`Invoke-Doctor` "Installer apps + extras" section ~line 1246-1255; `Invoke-CheckForUpdates` between the "Installer apps" stanza and "Other components" ~line 1362)

**Interfaces:**
- Consumes: `$ElevatedTools` (Task 1 key names, incl. per-`Msi` `WingetId`/`Repo`); existing helpers `Test-InstallerPresent`, `Get-InstalledAppVersion -DisplayName <glob>` (returns version string or `$null`), `Get-LatestGitTag -Repo <owner/repo>` (returns version string or `$null`), `Write-UpdateStatus -Name -Pinned -Latest -Hint`.
- Produces: report lines only.

- [ ] **Step 1: Doctor lines**

In `Invoke-Doctor`, find the `$InstallerTools` report loop:

```powershell
    foreach ($tool in $InstallerTools) {
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            Write-Ok "$($tool.Name)$verText installed (self-updates; -ForceInstaller to reseed)"
        } else {
            Write-Bad "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        }
    }
```

Append directly below (absence is Write-Warn, not Write-Bad — the class is best-effort/optional per the spec):

```powershell
    foreach ($tool in $ElevatedTools) {
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            Write-Ok "$($tool.Name)$verText installed (elevated class; update via: winget upgrade $($tool.WingetId))"
        } else {
            Write-Warn "$($tool.Name) not installed (best-effort elevated tool) — re-run .\bootstrap.ps1 (UAC prompt) or: winget install $($tool.WingetId)"
        }
        # Report the tool's dependency MSIs (WinFsp kernel driver) separately so
        # a half-install (driver without sshfs, or vice versa) is visible.
        foreach ($msi in $tool.Msi) {
            if ($msi.DetectName -eq $tool.DetectName) { continue }
            if (Test-InstallerPresent -DisplayName $msi.DetectName) {
                $depVer = Get-InstalledAppVersion -DisplayName $msi.DetectName
                $depText = if ($depVer) { " $depVer" } else { "" }
                Write-Ok "$($msi.Name)$depText installed ($($tool.Name)'s kernel-driver dependency)"
            } else {
                Write-Warn "$($msi.Name) not installed — $($tool.Name) can't mount without it (winget installs both)"
            }
        }
    }
```

- [ ] **Step 2: CheckForUpdates stanza**

In `Invoke-CheckForUpdates`, find the end of the "Installer apps" stanza:

```powershell
    Write-Log "Installer apps (install LATEST + self-update — nothing to pin)"
    foreach ($tool in $InstallerTools) {
```

…and locate the `Write-Host ""` that closes that stanza (immediately before `Write-Log "Other components"`). Insert between them:

```powershell
    Write-Log "Elevated tools (best-effort; update via winget when flagged)"
    foreach ($tool in $ElevatedTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = Get-LatestGitTag -Repo $tool.Repo
        if (-not (Test-InstallerPresent -DisplayName $tool.DetectName)) {
            Write-Warn "$($tool.Name) not installed (best-effort elevated tool) — re-run .\bootstrap.ps1 or: winget install $($tool.WingetId)"
        } elseif ($installed -and $latest) {
            Write-UpdateStatus -Name $tool.Name -Pinned $installed -Latest $latest -Hint "winget upgrade $($tool.WingetId)"
        } elseif ($latest) {
            Write-Ok "$($tool.Name) installed (latest upstream: $latest)"
        } else {
            Write-Ok "$($tool.Name) installed"
        }
        foreach ($msi in $tool.Msi) {
            if ($msi.DetectName -eq $tool.DetectName) { continue }
            $depInstalled = Get-InstalledAppVersion -DisplayName $msi.DetectName
            $depLatest    = Get-LatestGitTag -Repo $msi.Repo
            if ($depInstalled -and $depLatest) {
                Write-UpdateStatus -Name $msi.Name -Pinned $depInstalled -Latest $depLatest -Hint "winget upgrade $($msi.WingetId)"
            } elseif ($depLatest) {
                Write-Warn "$($msi.Name) not installed — $($tool.Name)'s kernel-driver dependency (latest upstream: $depLatest)"
            } else {
                Write-Warn "$($msi.Name): couldn't resolve installed or upstream version"
            }
        }
    }
    Write-Host ""
```

- [ ] **Step 3: Parse-check**

Run the parse-check command from Global Constraints.
Expected: `PARSE OK`.

- [ ] **Step 4: Live read-only run via WSL interop**

`-Doctor` is read-only by design, so it can run against the real Windows host from WSL:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w bootstrap.ps1)" -Doctor
```

Expected: the "Installer apps + extras" section now contains SSHFS-Win and WinFsp lines — `✓ ... installed` if present on the host, otherwise the two `!` warn lines. The script must complete without a thrown error (exit code 0; the report itself may contain `✗` for unrelated items).

- [ ] **Step 5: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): Doctor + CheckForUpdates coverage for elevated tools

SSHFS-Win and its WinFsp kernel-driver dependency get presence/version lines
in -Doctor and an update stanza in -CheckForUpdates (registry DisplayVersion
vs upstream tags; hint: winget upgrade). Absence is a warn, not a fail — the
class is best-effort."
```

(with the standard commit footer)

---

### Task 4: README.html — §setup-windows + §troubleshooting

**Files:**
- Modify: `README.html` (§setup-windows: no-admin callout ~line 2748, tool `<ul>` ~line 2760-2814, flags code block ~line 2914-2921, "No elevation anywhere" note-row ~line 2968; §troubleshooting: append one `<details data-ts>` entry)

**Interfaces:**
- Consumes: flag/behavior names from Tasks 1-2 (`-SkipElevated`, winget → MSI → soft-fail chain).
- Produces: user-facing docs; Task 5's CLAUDE.md troubleshooting count depends on the entry added here.

- [ ] **Step 1: Amend the "No admin required" callout**

Find (in the callout `<div class="callout">` under `<h3 id="setup-windows">`):

```html
                        <strong>No admin required.</strong> Everything installs
                        into your user profile (<code>%LOCALAPPDATA%\workstation</code>,
                        the User <code>PATH</code>, CurrentUser PSGallery, HKCU
                        fonts). <strong>Git is a prerequisite you install
                        yourself</strong> &mdash; the script hard-fails with an
                        install link if <code>git</code> isn&rsquo;t on PATH.
```

Replace with:

```html
                        <strong>No admin required.</strong> Everything installs
                        into your user profile (<code>%LOCALAPPDATA%\workstation</code>,
                        the User <code>PATH</code>, CurrentUser PSGallery, HKCU
                        fonts). <strong>Git is a prerequisite you install
                        yourself</strong> &mdash; the script hard-fails with an
                        install link if <code>git</code> isn&rsquo;t on PATH.
                        <strong>One best-effort exception:</strong> the
                        SSHFS-Win step (WinFsp kernel driver) is machine-scope
                        and pops a UAC prompt &mdash; decline it (or pass
                        <code>-SkipElevated</code>) and everything else still
                        completes admin-free.
```

- [ ] **Step 2: Add the SSHFS-Win entry to the tool list**

Find the closing `</li>` of the Zed entry (ends with `shortcut).`, followed by `</li>` and `</ul>`). Insert before the `</ul>`:

```html
                        <li>
                            <strong>SSHFS-Win</strong> &mdash; mounts remote
                            Unix filesystems over SSH as Windows drives
                            (<code>\\sshfs\user@host</code> UNC paths, or
                            <code>net use X: \\sshfs\user@host</code>).
                            <strong>The one elevated install:</strong> it
                            depends on WinFsp, a kernel-mode filesystem
                            driver, so both MSIs are machine-scope and a UAC
                            prompt is unavoidable. Best-effort &mdash;
                            installed via <code>winget</code> (which pulls
                            WinFsp automatically as a dependency), falling
                            back to sha256-verified direct MSI downloads when
                            winget is absent; declining the UAC prompt (or
                            passing <code>-SkipElevated</code>) skips the step
                            and the rest of the bootstrap completes normally.
                            Detected via the Uninstall registry, so an
                            already-provisioned machine never sees the prompt.
                        </li>
```

- [ ] **Step 3: Add `-SkipElevated` to the flags code block**

Find:

```
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed) even if present
```

Append directly below (inside the same `<pre><code>` block):

```
.\bootstrap.ps1 -SkipElevated                    # skip the UAC-prompting SSHFS-Win/WinFsp install
```

- [ ] **Step 4: Amend the "No elevation anywhere in this flow" note-row**

Find:

```html
                    <p class="note-row">
                        <strong>No elevation anywhere in this flow.</strong>
                        Pass <code>-SkipToolInstall</code> to skip the
```

Replace the first sentence so the paragraph starts:

```html
                    <p class="note-row">
                        <strong>No elevation anywhere in this flow</strong>
                        &mdash; except the best-effort SSHFS-Win/WinFsp step,
                        which pops a UAC prompt when not yet installed
                        (declining just skips it; suppress it entirely with
                        <code>-SkipElevated</code>).
                        Pass <code>-SkipToolInstall</code> to skip the
```

(rest of the paragraph unchanged)

- [ ] **Step 5: Add the troubleshooting entry**

Count entries first: `rg -c '<details data-ts>' README.html` — note the number (expected 24). Then find the LAST `</details>` inside `<section id="troubleshooting">` (immediately before that section's closing `</section>`) and insert after it:

```html
                    <details data-ts>
                        <summary>
                            <code>bootstrap.ps1</code> popped a UAC prompt (or
                            SSHFS-Win reports &ldquo;skipping&rdquo;)
                        </summary>
                        <div class="ts-body">
                            <p>
                                That&rsquo;s the <strong>SSHFS-Win</strong>
                                step &mdash; the one deliberate exception to
                                the otherwise admin-free bootstrap. SSHFS-Win
                                depends on <strong>WinFsp</strong>, a
                                kernel-mode filesystem driver; kernel drivers
                                install machine-wide, so elevation is
                                unavoidable. The step is best-effort: declining
                                the prompt, being offline, or having neither
                                <code>winget</code> nor network just skips it
                                &mdash; nothing else in the bootstrap is
                                affected, and an already-installed machine
                                never sees the prompt (Uninstall-registry
                                detection).
                            </p>
                            <p>
                                Install it later with
                                <code>winget install SSHFS-Win.SSHFS-Win</code>
                                (pulls WinFsp automatically) or re-run
                                <code>.\bootstrap.ps1</code> and accept the
                                prompt; suppress the attempt entirely with
                                <code>-SkipElevated</code>. Once installed,
                                mount with
                                <code>net use X: \\sshfs\user@host</code> or
                                browse <code>\\sshfs\user@host</code> directly
                                in Explorer.
                            </p>
                        </div>
                    </details>
```

- [ ] **Step 6: Verify**

```bash
rg -c '<details data-ts>' README.html      # expected: previous count + 1 (25)
rg -c 'SkipElevated' README.html           # expected: 5 (callout, tool-list li, flags block, note-row, troubleshooting)
rg -ci 'sshfs' README.html                 # expected: >= 8
```

Open `README.html` §setup-windows and §troubleshooting in a browser (or spot-check the HTML) — the new `<li>`, callout sentence, flag line, note-row, and details entry render with no broken tags (every opened tag in the inserted blocks is closed).

- [ ] **Step 7: Commit**

```bash
git add README.html
git commit -m "docs(readme): document SSHFS-Win elevated install + -SkipElevated

setup-windows: tool-list entry, no-admin callout + flow note-row amended for
the one UAC exception, -SkipElevated in the flags block; troubleshooting: new
'bootstrap popped a UAC prompt' entry (25 entries now)."
```

(with the standard commit footer)

---

### Task 5: CLAUDE.md invariant amendment + CLAUDE_CHANGELOG row

**Files:**
- Modify: `CLAUDE.md` (the "Windows tool installs are admin-free…" invariant bullet; the "Troubleshooting (24 entries)" table row)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: final behavior from Tasks 1-4 (class name, flag, chain, README sections touched).
- Produces: Claude-internal docs only. No `check-invariants.sh` addition — the `Sha256Pin` lives ONLY in `bootstrap.ps1` (no dual-edit), and the best-effort behavior isn't mechanically checkable.

- [ ] **Step 1: Amend the CLAUDE.md invariant bullet**

In the bullet beginning `**Windows tool installs are admin-free binary/portable downloads under `%LOCALAPPDATA%\workstation`** (no Chocolatey).`, find the sentence starting `**There is also an installer class (`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian + Zed)**` and append after that installer-class passage (same indented paragraph block, before the next bullet):

```markdown
  **And ONE best-effort ELEVATED class (`$ElevatedTools`, today only SSHFS-Win)** — the single sanctioned exception to no-admin: SSHFS-Win depends on the WinFsp **kernel driver**, so both MSIs are machine-scope and UAC is unavoidable. Chain: Uninstall-registry detect (already installed → no UAC, ever) → `winget install SSHFS-Win.SSHFS-Win` (manifest pulls WinFsp.WinFsp; `--force` under `-ForceInstaller`) → digest/`Sha256Pin`-verified direct-MSI fallback via `msiexec -Verb RunAs` ONLY when winget is ABSENT (a winget *failure* is never retried via MSI — the cause would recur and re-pop UAC) → every failure warns-and-continues. **No code path in this class may call `Write-Fail`** (it exits) — a hash mismatch refuses the tool loudly but the bootstrap completes; `-SkipElevated` skips the class. NOT pinned in `versions.mk` (latest-release model like `$InstallerTools`; the `Sha256Pin` for the digest-less 2020 sshfs-win MSI lives only in `bootstrap.ps1` — no dual-edit).
```

- [ ] **Step 2: Update the troubleshooting entry count**

In the CLAUDE.md "Where things are documented" table, change:

```
| Troubleshooting (24 entries) | `README.html` §troubleshooting |
```

to `(25 entries)` (match the actual count from Task 4 Step 6).

- [ ] **Step 3: Append the CLAUDE_CHANGELOG.md row**

Append to the table:

```markdown
| Added SSHFS-Win via a best-effort ELEVATED install class (`$ElevatedTools` in `bootstrap.ps1`: registry detect → winget → digest/pin-verified MSI fallback via `msiexec -Verb RunAs` → soft-fail; new `-SkipElevated` flag; `-Doctor`/`-CheckForUpdates` coverage; the ONE sanctioned exception to the admin-free invariant) | **Yes** | §setup-windows: SSHFS-Win entry in the tool list, "one best-effort exception" sentence in the no-admin callout and the "No elevation anywhere" note-row, `-SkipElevated` line in the flags block; §troubleshooting: new "bootstrap popped a UAC prompt / SSHFS-Win skipped" entry. |
```

- [ ] **Step 4: Verify + commit**

```bash
bash scripts/check-invariants.sh    # expected: ✓ all invariant checks passed
git add CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): amend admin-free invariant for \$ElevatedTools; changelog row"
```

(with the standard commit footer)

---

### Task 6: Windows-host verification (manual — needs UAC interaction)

**Files:** none (verification only; fix-forward commits if issues found)

**Interfaces:**
- Consumes: everything from Tasks 1-5, checked out on the Windows host.

This task CANNOT be fully automated: accepting a UAC prompt requires the user at the Windows desktop. The read-only parts run from WSL interop; the install runs on the Windows host's clone.

- [ ] **Step 1: Read-only checks from WSL (no UAC)**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w bootstrap.ps1)" -Doctor
```

Expected: SSHFS-Win/WinFsp warn lines (not yet installed) in "Installer apps + extras"; exit without thrown errors.

- [ ] **Step 2: On the Windows host — branch + skip-flag run (no UAC must appear)**

In a PowerShell/Nushell window on Windows, in `%USERPROFILE%\.local\share\chezmoi`:

```powershell
git fetch origin feat/windows-sshfs-win
git checkout feat/windows-sshfs-win
.\bootstrap.ps1 -SkipElevated
```

Expected: the line `==> Elevated tool install skipped (-SkipElevated) — SSHFS-Win/WinFsp not installed`, **no UAC prompt at any point**, bootstrap completes.

- [ ] **Step 3: Real install run (accept UAC)**

```powershell
.\bootstrap.ps1
```

Expected: the heads-up warn line, one winget install with a UAC prompt; after accepting: `✓ SSHFS-Win installed (winget SSHFS-Win.SSHFS-Win)`. (Optional negative test: run once and DECLINE the prompt first — expected: `! SSHFS-Win: winget exited with code <nonzero> ... — skipping; install manually later: ...` and the bootstrap still completes.)

- [ ] **Step 4: Idempotency — re-run must not elevate**

```powershell
.\bootstrap.ps1
```

Expected: `✓ SSHFS-Win already installed (use -ForceInstaller to reinstall)` and **no UAC prompt**.

- [ ] **Step 5: Doctor + CheckForUpdates now green**

```powershell
.\bootstrap.ps1 -Doctor            # ✓ SSHFS-Win <ver> installed (elevated class; ...) + ✓ WinFsp <ver> installed (...)
.\bootstrap.ps1 -CheckForUpdates   # "Elevated tools" stanza: up-to-date / newest-upstream lines, no errors
```

- [ ] **Step 6: Mount smoke test (against any provisioned Linux host from hosts.conf)**

```powershell
net use X: \\sshfs\arrush.chaturvedi@<linux-host>
dir X:
net use X: /delete
```

Expected: `dir X:` lists the remote `$HOME`. (First mount may prompt for the SSH password unless key auth is set up; `\\sshfs.k\user@host` variant uses the key from `%USERPROFILE%\.ssh\id_ed25519`.)

- [ ] **Step 7: Wrap up**

If all pass: push the branch and open the PR (`gh pr create`) per the repo's normal flow, PR body ending with the standard generated-with footer. Any failure: fix forward on the branch, re-run the failing step.

---

## Self-review notes (spec → plan)

- Spec §1 (`$ElevatedTools` shape) → Task 1 Step 6 (with `Repo`/`WingetId` keys added for Doctor/CheckForUpdates reuse — a strict superset of the spec's shape).
- Spec §2 (install flow incl. detect-first, winget no-retry, `-Verb RunAs`, 3010, mismatch-refuse-but-continue) → Task 2.
- Spec §3 (`-SkipElevated`, header docs) → Task 1 Steps 1-5 + Task 2 Steps 3-4.
- Spec §4 (Doctor warn-not-bad; CheckForUpdates stanza + winget-upgrade hint) → Task 3.
- Spec §5 (README ×2, CLAUDE.md, CHANGELOG, no application_list entry) → Tasks 4-5; application_list.md deliberately untouched.
- Spec "Testing" section → Tasks 2/3 parse+lint steps and Task 6 (Windows manual).
- Types/names consistent across tasks: `$ElevatedTools`, `Install-ElevatedTool -Tool`, `Install-ElevatedMsi -Msi` (returns bool), keys `Name/WingetId/DetectName/Repo/Msi/AssetMatch/Sha256Pin`, flag `$SkipElevated`.
