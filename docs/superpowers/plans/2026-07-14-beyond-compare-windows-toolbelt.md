# Beyond Compare Windows Toolbelt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-install Beyond Compare 5 on the Windows host as the sixth `$InstallerTools` app in `bootstrap.ps1` via a new opt-in `WingetVersions` version source (Scooter Software has NO GitHub presence — no releases AND no tags), silent per-user `/CURRENTUSER` Inno install, sha256 from the official winget manifest; move Beyond Compare to the auto-installed section of `application_list.md`.

**Architecture:** One new helper (`Get-LatestWingetVersion` — lists a `microsoft/winget-pkgs` manifest directory whose subdirectory names ARE the published 4-part versions) + a version-source branch inside `Install-InstallerTool`'s existing `UrlTemplate` path and the `-CheckForUpdates` installer loop + one data entry + a docs sweep. Everything downstream of version resolution (URL substitution, manifest hash pairing, hard-fail, download/install tail) is the WinSCP machinery, reused untouched. Version and sha256 come from the SAME authority, so a lagging winget seeds the prior version — still verified, never unverified.

**Tech Stack:** PowerShell 5.1-compatible script edits (`bootstrap.ps1`), HTML/Markdown docs.

**Spec:** `docs/superpowers/specs/2026-07-14-beyond-compare-windows-toolbelt-design.md` (approved 2026-07-14).

## Global Constraints

- Work on the existing `feat/beyond-compare-windows-toolbelt` branch (spec already committed as `9175515`).
- `bootstrap.ps1` MUST keep its **UTF-8 BOM** and **LF** line endings after every edit (PS 5.1 mis-decodes glyphs without the BOM). The repo's `post-edit-guard` hook auto-repairs both and tells you to re-read — obey it. Verify manually anyway (each bootstrap.ps1 task's final gate).
- All PowerShell must be **5.1-compatible**: no `??`, no ternary `? :`, hashtable key probes via `.ContainsKey()`, PSObject property probes via `.PSObject.Properties['name']` (StrictMode-safe).
- Installer-class rules: **no admin/UAC anywhere, nothing added to PATH**, existing entries (Obsidian/Zed/DevToys/DBeaver/WinSCP) behaviorally unchanged — both existing resolver paths must produce the same messages and outcomes as today.
- Per-user is load-bearing: Beyond Compare's `SilentArgs` MUST include `/CURRENTUSER` and MUST NOT include `/ALLUSERS`.
- Beyond Compare is **commercial trialware**: the seed installs the 30-day trial; the user's license key unlocks it (Standard vs Pro by key). No license automation anywhere.
- **No `versions.mk` change** → no `check-invariants.sh` addition, no TOOLS-block regeneration, no `cza` needed. No new bootstrap flags → no completion-parity edits.
- README/CLAUDE.md/changelog land in the same PR as the code (squash-merge satisfies the "same commit" doc rule).
- Windows-host runtime verification is **post-merge, manual, by the user** (no Windows here); this plan's verification is premise proofs + parser gates + lint. This WSL host has `powershell.exe` interop on PATH — the plan uses it as a real PS 5.1 parse/behavior gate; if interop is unavailable, note it and rely on CI's `ps-lint`.
- There is no Pester/test framework for `bootstrap.ps1` in this repo. The test cycle per task = premise-proof probes (prove upstream facts the code depends on) + a PS 5.1 parse gate after every edit + behavior probes of the REAL edited code (extracted from the file's AST) run through `powershell.exe`.
- Upstream moves: everywhere a probe expects `5.2.3.32296`, a NEWER 4-part version is equally a pass (same shape, same chain); an OLDER or non-4-part value is a failure.
- Line numbers cited below are as of commit `9175515` and shift as tasks land — locate edits by the quoted anchor text, not the number.

---

### Task 1: `Get-LatestWingetVersion` helper + class banner comment (`bootstrap.ps1`)

**Files:**
- Modify: `bootstrap.ps1:309-342` (class banner — resolver sentence + opt-in fields five → six)
- Modify: `bootstrap.ps1:1577` area (insert the helper right after `Get-LatestGitTag`'s closing brace, before the `Get-InstalledAppVersion` comment block)

**Interfaces:**
- Consumes: nothing new — same header/`$env:GITHUB_TOKEN` conventions as the GitHub-release resolver (`bootstrap.ps1:812-813`).
- Produces: `Get-LatestWingetVersion -Path <string>` → the raw subdirectory name of the highest `[version]` under `https://api.github.com/repos/microsoft/winget-pkgs/contents/<Path>`, as a string (e.g. `"5.2.3.32296"`), or `$null` on ANY failure (offline, rate-limited, path moved, nothing parses). Tasks 2 and 3 call it with exactly this contract.

- [ ] **Step 1: Prove the premises (anonymous listing works; names are 4-part versions; newest matches the download page)**

Run:

```bash
curl -s -H "User-Agent: workstation-bootstrap" \
  "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/s/ScooterSoftware/BeyondCompare/5" \
  | jq -r '[.[] | select(.type=="dir") | .name] | join(" ")'
```

Expected: a space-separated list of 4-part versions ending at `5.2.3.32296` (or newer) — verified 2026-07-14 (17 entries). Empty output or an error object means the winget tree moved — stop and re-check the spec.

Then confirm the newest name matches scootersoftware.com's current release:

```bash
curl -s -A "Mozilla/5.0" "https://www.scootersoftware.com/download" | rg -o 'BCompare-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.exe' | sort -u
```

Expected: `BCompare-<same version>.exe` (winget may lag a brand-new release by hours–days — a one-version gap is acceptable and documented; note it and continue).

- [ ] **Step 2: Update the class banner comment**

In `bootstrap.ps1`, replace the banner intro (lines 309-317). Old:

```powershell
# Installer-layout tools — apps that publish a silent, admin-free installer (.exe)
# instead of a portable zip. Unlike $PortableTools these are NOT version-pinned:
# we resolve the LATEST release at run time (the app self-updates after) — via
# the GitHub releases API + per-asset sha256 'digest' normally, or via git tags
# + a vendor URL template for apps with no GitHub release assets (UrlTemplate
# below) — then run the installer silently PER-USER (no admin), and add NOTHING
# to PATH (GUI apps create their own Start-menu shortcut). Presence is detected
# via the Uninstall registry (DisplayName), so a manual uninstall makes the next
# bootstrap reinstall. Force a reinstall with -ForceInstaller.
```

New:

```powershell
# Installer-layout tools — apps that publish a silent, admin-free installer (.exe)
# instead of a portable zip. Unlike $PortableTools these are NOT version-pinned:
# we resolve the LATEST release at run time (the app self-updates after) — via
# the GitHub releases API + per-asset sha256 'digest' normally, via git tags
# + a vendor URL template for apps with no GitHub release assets (UrlTemplate
# below), or via a winget-pkgs version listing for apps with no GitHub presence
# at all (WingetVersions below) — then run the installer silently PER-USER (no
# admin), and add NOTHING to PATH (GUI apps create their own Start-menu
# shortcut). Presence is detected via the Uninstall registry (DisplayName), so
# a manual uninstall makes the next bootstrap reinstall. Force a reinstall with
# -ForceInstaller.
```

Then change the opt-in list header (line 318). Old:

```powershell
# Five OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
```

New:

```powershell
# Six OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
```

Then append a sixth field description immediately after the `HashManifest` block (after the line ending `the same posture as a missing GitHub digest.`):

```powershell
#   WingetVersions     microsoft/winget-pkgs directory path whose subdirectory
#                      names ARE the published versions — the version source
#                      for upstreams with NO GitHub presence at all (Beyond
#                      Compare; WinSCP at least had tags). Its presence makes
#                      the UrlTemplate path (and the -CheckForUpdates lookup)
#                      resolve via Get-LatestWingetVersion instead of
#                      Get-LatestGitTag. Version + sha256 then come from the
#                      SAME authority: a lagging winget seeds the prior
#                      version — still hash-verified — never an unverified
#                      install.
```

- [ ] **Step 3: Add the helper function**

Insert after `Get-LatestGitTag`'s closing brace (line 1577), before the `# DisplayVersion from the Uninstall registry` comment:

```powershell
# Newest published version of a winget package, from the microsoft/winget-pkgs
# manifest tree: the given directory holds one subdirectory per published
# version and the names ARE the versions (Beyond Compare's are 4-part —
# 5.2.3.32296 — matching its download URLs, which embed the build number).
# The version source for $InstallerTools entries whose upstream has NO GitHub
# presence at all (no releases AND no tags). Anonymous API works (60 req/hr);
# $env:GITHUB_TOKEN lifts the limit like the release resolver. Returns the raw
# directory name of the highest [version], or $null on ANY failure (offline,
# rate-limited, tree moved, nothing parses) — callers warn + skip.
function Get-LatestWingetVersion {
    param([string]$Path)
    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    try {
        $entries = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/microsoft/winget-pkgs/contents/$Path" `
            -Headers $headers -UseBasicParsing
    } catch {
        return $null
    }
    $vers = @(foreach ($e in $entries) {
        if ($e.type -ne 'dir') { continue }   # skip stray files (.validation etc.)
        $v = $null
        if ([System.Version]::TryParse($e.name, [ref]$v)) { $e.name }
    })
    if ($vers.Count -eq 0) { return $null }
    return ($vers | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}
```

Style notes (match the file): the `$vers = @(foreach …)` collect + `Sort-Object { [version]$_ } -Descending | Select-Object -First 1` tail mirror `Get-LatestGitTag` exactly; `TryParse` (not a bare `[version]` cast) keeps a stray non-version name from throwing under `Set-StrictMode -Version Latest`. The `Invoke-RestMethod` assignment is deliberately BARE (no `@()`): PS 5.1's `Invoke-RestMethod` returns a JSON array as ONE `Object[]` — not pipeline-unrolled — so `@(...)` would nest it (count=1) and break the `foreach` (verified empirically on this host's PS 5.1.26100, 2026-07-14; the same latent nesting bug in the DevToys resolver is fixed by Task 2 Step 3b).

- [ ] **Step 4: PS 5.1 parse gate**

```bash
powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)', [ref]\$null, [ref]\$e); \$e.Count"
```

Expected: `0` (zero parse errors under real PowerShell 5.1).

- [ ] **Step 5: Behavior probe — run the REAL helper (extracted from the file's AST) under PS 5.1**

```bash
powershell.exe -NoProfile -Command '
  $f = "'"$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)"'"
  $e = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
  $fn = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-LatestWingetVersion"}, $true)
  Invoke-Expression $fn.Extent.Text
  "hit:  [{0}]" -f (Get-LatestWingetVersion -Path "manifests/s/ScooterSoftware/BeyondCompare/5")
  "miss: [{0}]" -f (Get-LatestWingetVersion -Path "manifests/z/Zzz/DoesNotExist")
'
```

Expected:

```
hit:  [5.2.3.32296]
miss: []
```

(`hit` may be newer; `miss` MUST be empty — the `$null` soft-fail contract Tasks 2/3 rely on.)

- [ ] **Step 6: BOM/LF + lint gate**

```bash
head -c3 /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1 | xxd | head -1   # must start ef bb bf
file /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1                       # must NOT say CRLF
make -C makefile ps-lint MODE=prod
```

Expected: BOM bytes `efbbbf`, no CRLF, PSScriptAnalyzer clean (warnings = fail; the repo gate runs at Warning+).

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): Get-LatestWingetVersion helper — winget-pkgs version listing (sixth installer-class opt-in)"
```

---

### Task 2: Version-source branch in `Install-InstallerTool` + `-CheckForUpdates` loop

**Files:**
- Modify: `bootstrap.ps1:756-770` (the `UrlTemplate` branch's version-resolution head inside `Install-InstallerTool`)
- Modify: `bootstrap.ps1:731-732` (the function's two-line docstring — "GitHub release" is stale now)
- Modify: `bootstrap.ps1:816-824` area (the `IncludePrerelease` resolver inside the GitHub-release branch — pre-existing PS 5.1 array-nesting bug, user-approved scope addition 2026-07-14)
- Modify: `bootstrap.ps1:1816-1819` (`-CheckForUpdates` installer loop — today it calls `Get-LatestGitTag -Repo $tool.Repo` unconditionally, which cannot work for a Repo-less entry)

**Interfaces:**
- Consumes: `Get-LatestWingetVersion -Path <string>` → version string or `$null` (Task 1).
- Produces: `Install-InstallerTool` and the `-CheckForUpdates` loop honoring the optional `WingetVersions` key — present → version via `Get-LatestWingetVersion`; absent → `Get-LatestGitTag` exactly as today. Task 3's entry supplies `WingetVersions` + `UrlTemplate` + `HashManifest` and NO `Repo` key. `-Doctor` needs zero changes (it reads only `DetectName`/`UpdateHint`).

- [ ] **Step 1: Update the function docstring**

Old (lines 731-732):

```powershell
# Install a silent, admin-free .exe installer at its LATEST GitHub release. NOT
# version-pinned (app self-updates after); verified against the API 'digest'.
```

New:

```powershell
# Install a silent, admin-free .exe installer at its LATEST release. NOT
# version-pinned (app self-updates after); sha256-verified (API digest or
# winget manifest — see the $InstallerTools banner for the resolver paths).
```

- [ ] **Step 2: Branch the version resolution inside the `UrlTemplate` path**

Replace the head of the `UrlTemplate` branch. Old (lines 756-770):

```powershell
    if ($Tool.ContainsKey('UrlTemplate')) {
        # --- Direct-URL path (WinSCP) — no GitHub release assets upstream. ---
        # Version = newest upstream git tag (the same Get-LatestGitTag lookup
        # -CheckForUpdates uses; TagPrefix-aware; its default filter drops
        # -beta tags). URL = {VERSION}-substituted vendor template. sha256 =
        # the official winget manifest for that version (the SSHFS-Win
        # Sha256Pin precedent, resolved at run time so the latest-release
        # model keeps working).
        $tagPrefix = if ($Tool.ContainsKey('TagPrefix')) { $Tool.TagPrefix } else { 'v' }
        $version   = Get-LatestGitTag -Repo $Tool.Repo -TagPrefix $tagPrefix
        if (-not $version) {
            Write-Warn "$($Tool.Name): couldn't resolve the latest version tag from $($Tool.Repo) (offline? tag scheme changed?)"
            Write-Warn "  Skipping — install it manually or re-run later."
            return
        }
```

New:

```powershell
    if ($Tool.ContainsKey('UrlTemplate')) {
        # --- Direct-URL path (WinSCP, Beyond Compare) — no GitHub release ---
        # assets upstream. Version source is one of two:
        #   WingetVersions — winget-pkgs directory listing (Beyond Compare:
        #     no GitHub presence at all; dir names ARE the 4-part versions
        #     its download URL needs).
        #   git tags — Get-LatestGitTag (WinSCP: tags only; TagPrefix-aware;
        #     its default filter drops -beta tags).
        # URL = {VERSION}-substituted vendor template. sha256 = the official
        # winget manifest for that version (the SSHFS-Win Sha256Pin precedent,
        # resolved at run time so the latest-release model keeps working).
        if ($Tool.ContainsKey('WingetVersions')) {
            $version   = Get-LatestWingetVersion -Path $Tool.WingetVersions
            $verSource = "the winget-pkgs listing $($Tool.WingetVersions)"
        } else {
            $tagPrefix = if ($Tool.ContainsKey('TagPrefix')) { $Tool.TagPrefix } else { 'v' }
            $version   = Get-LatestGitTag -Repo $Tool.Repo -TagPrefix $tagPrefix
            $verSource = "$($Tool.Repo) tags"
        }
        if (-not $version) {
            Write-Warn "$($Tool.Name): couldn't resolve the latest version from $verSource (offline? scheme changed?)"
            Write-Warn "  Skipping — install it manually or re-run later."
            return
        }
```

Everything after the `if (-not $version)` block (`$downloadUrl` substitution, `$versionLabel`, `$hashSource`, basename/manifest pairing, download/verify/install tail) is untouched.

- [ ] **Step 3: Branch the `-CheckForUpdates` installer loop**

Old (lines 1816-1819):

```powershell
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $tagPrefix = if ($tool.ContainsKey('TagPrefix')) { $tool.TagPrefix } else { 'v' }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix
```

New:

```powershell
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = if ($tool.ContainsKey('WingetVersions')) {
            Get-LatestWingetVersion -Path $tool.WingetVersions
        } else {
            $tagPrefix = if ($tool.ContainsKey('TagPrefix')) { $tool.TagPrefix } else { 'v' }
            Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix
        }
```

(`$tagPrefix` is not referenced later in the loop — verify with a quick read of the following ~15 lines before committing.)

- [ ] **Step 3b: Fix the pre-existing DevToys `IncludePrerelease` nesting bug (user-approved scope addition)**

PS 5.1's `Invoke-RestMethod` returns a JSON array as ONE `Object[]` (not
pipeline-unrolled), so the existing `@(...)` wrapper NESTS it: `$releases`
becomes a 1-element array whose only item is the whole release list,
`Where-Object { -not $_.draft }` tests that inner array as a single item and
drops it, and DevToys warn-skips instead of installing (reproduced live
2026-07-14: resolver returns NULL under PS 5.1.26100). Same bug class Task 1's
helper avoided.

In the GitHub-release branch of `Install-InstallerTool`, old:

```powershell
                # /releases/latest excludes prereleases, and some repos (DevToys)
                # flag EVERY release prerelease:true — take the newest non-draft
                # entry of /releases instead (the list is newest-first).
                $releases = @(Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases?per_page=10" `
                    -Headers $headers -UseBasicParsing)
                $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
                if (-not $release) { throw "no non-draft release among the newest $($releases.Count)" }
```

New:

```powershell
                # /releases/latest excludes prereleases, and some repos (DevToys)
                # flag EVERY release prerelease:true — take the newest non-draft
                # entry of /releases instead (the list is newest-first). NOTE:
                # the assignment is deliberately BARE — PS 5.1's Invoke-RestMethod
                # returns a JSON array as ONE Object[] (not pipeline-unrolled),
                # so @(...) would NEST it and Where-Object would test the whole
                # list as a single item (DevToys then warn-skipped instead of
                # installing; caught + fixed 2026-07-14).
                $releases = Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases?per_page=10" `
                    -Headers $headers -UseBasicParsing
                $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
                if (-not $release) { throw "no non-draft release among the newest $(@($releases).Count)" }
```

(The throw's interpolation gains `@(...)` around `$releases` — safe `.Count`
for both the array and a hypothetical single-release page; `@()` around a
VARIABLE preserves an existing array, unlike around a command's output.)

Behavior probe — the fixed resolver shape must now resolve a DevToys release
under real PS 5.1:

```bash
powershell.exe -NoProfile -Command '
  $headers = @{ "User-Agent" = "workstation-bootstrap" }
  $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/DevToys-app/DevToys/releases?per_page=10" -Headers $headers -UseBasicParsing
  $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
  if ($null -eq $release) { "STILL BROKEN" } else { "resolved: $($release.tag_name)" }
'
```

Expected: `resolved: v2.0.9.0` (or newer vX.Y.Z.W tag). `STILL BROKEN` fails the task.

- [ ] **Step 4: PS 5.1 parse gate**

Same command as Task 1 Step 4. Expected: `0`.

- [ ] **Step 5: Behavior probe — drive the REAL branch shapes under PS 5.1**

Extract both resolver functions from the edited file and replicate the new branch head against the two entry shapes Task 3 and WinSCP use (regression: WinSCP must still resolve via tags):

```bash
powershell.exe -NoProfile -Command '
  $f = "'"$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)"'"
  $e = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
  foreach ($n in @("Get-LatestGitTag","Get-LatestWingetVersion")) {
    $fn = $ast.Find({param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n}, $true)
    Invoke-Expression $fn.Extent.Text
  }
  foreach ($Tool in @(
    @{ Name = "Beyond Compare"; WingetVersions = "manifests/s/ScooterSoftware/BeyondCompare/5" },
    @{ Name = "WinSCP"; Repo = "winscp/winscp"; TagPrefix = "" }
  )) {
    if ($Tool.ContainsKey("WingetVersions")) {
      $version   = Get-LatestWingetVersion -Path $Tool.WingetVersions
      $verSource = "the winget-pkgs listing $($Tool.WingetVersions)"
    } else {
      $tagPrefix = if ($Tool.ContainsKey("TagPrefix")) { $Tool.TagPrefix } else { "v" }
      $version   = Get-LatestGitTag -Repo $Tool.Repo -TagPrefix $tagPrefix
      $verSource = "$($Tool.Repo) tags"
    }
    "{0}: {1} (from {2})" -f $Tool.Name, $version, $verSource
  }
'
```

Expected (versions may be newer; sources MUST match):

```
Beyond Compare: 5.2.3.32296 (from the winget-pkgs listing manifests/s/ScooterSoftware/BeyondCompare/5)
WinSCP: 6.5.6 (from winscp/winscp tags)
```

If `WinSCP:` comes back empty, Windows-side `git.exe` may be missing from interop PATH — run the WinSCP half from WSL bash instead: `git ls-remote --tags --refs https://github.com/winscp/winscp.git | tail -3` (must list stable tags).

- [ ] **Step 6: BOM/LF + lint gate**

Same three commands as Task 1 Step 6. Expected: BOM `efbbbf`, no CRLF, ps-lint clean.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): WingetVersions version-source branch in Install-InstallerTool + -CheckForUpdates

Also fixes the pre-existing DevToys IncludePrerelease resolver: PS 5.1's
Invoke-RestMethod returns a JSON array as one Object[], so the @() wrapper
nested it and DevToys warn-skipped instead of installing (user-approved
scope addition)."
```

---

### Task 3: `$InstallerTools` entry for Beyond Compare

**Files:**
- Modify: `bootstrap.ps1:375-385` (`$InstallerTools` — append the entry after WinSCP's closing `},` and before the array's closing `)`)

**Interfaces:**
- Consumes: the `WingetVersions` branch (Task 2) and `Get-LatestWingetVersion` (Task 1); the untouched `UrlTemplate`/`HashManifest`/`SilentArgs`/`DetectName`/`UpdateHint` machinery.
- Produces: the sixth installer-class app. The FIRST entry with **no `Repo` key** — both loops that touch `$InstallerTools` must already tolerate that (Task 2 made `-CheckForUpdates` safe; `-Doctor` never reads `Repo`).

- [ ] **Step 1: Append the entry**

After WinSCP's closing `},` (line 384), add:

```powershell
    @{
        Name           = "Beyond Compare"                                       # commercial trialware: seed = 30-day trial; the user's license key unlocks it (Standard vs Pro by key)
        WingetVersions = "manifests/s/ScooterSoftware/BeyondCompare/5"          # version source: subdir names ARE the 4-part versions (Scooter has NO GitHub presence; the URL needs the build number)
        UrlTemplate    = "https://www.scootersoftware.com/files/BCompare-{VERSION}.exe"  # first-party, direct (no redirect); English installer deliberate — localized siblings (BCompare-de-…) never match the hash lookup
        HashManifest   = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/s/ScooterSoftware/BeyondCompare/5/{VERSION}/ScooterSoftware.BeyondCompare.5.installer.yaml"
        SilentArgs     = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER"  # Inno silent + documented per-user mode -> no admin/UAC (NEVER /ALLUSERS)
        DetectName     = "Beyond Compare*"                                      # HKCU ...\Uninstall\BeyondCompare5_is1; glob also matches BC4 or a machine-wide HKLM install (intended: never seed a trial alongside a licensed copy)
        UpdateHint     = "in-app update check prompts to install (not silent) — or re-run bootstrap with -ForceInstaller"
    }
```

(Remember the comma after WinSCP's now-non-terminal `}`.)

- [ ] **Step 2: PS 5.1 parse gate**

Same command as Task 1 Step 4. Expected: `0`.

- [ ] **Step 3: Behavior probe — the entry's full resolve→URL→hash chain (no install)**

Proves the entry's data end-to-end under real PS 5.1: version resolves, the substituted URL serves the file, and the manifest pairing regex (the REAL one from the code) extracts an English-entry sha256 — all without installing anything:

```bash
powershell.exe -NoProfile -Command '
  $f = "'"$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)"'"
  $e = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
  $fn = $ast.Find({param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "Get-LatestWingetVersion"}, $true)
  Invoke-Expression $fn.Extent.Text
  $v = Get-LatestWingetVersion -Path "manifests/s/ScooterSoftware/BeyondCompare/5"
  $url = "https://www.scootersoftware.com/files/BCompare-{VERSION}.exe".Replace("{VERSION}", $v)
  $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing
  "{0} -> HTTP {1}" -f $v, $head.StatusCode
  $mu = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/s/ScooterSoftware/BeyondCompare/5/{VERSION}/ScooterSoftware.BeyondCompare.5.installer.yaml".Replace("{VERSION}", $v)
  $m = (Invoke-WebRequest -Uri $mu -UseBasicParsing).Content
  $baseName = ($url -replace "/download/?$", "").Split("/")[-1]
  $pairs = [regex]::Matches($m, "(?ms)InstallerUrl:\s*(\S+).*?InstallerSha256:\s*([0-9A-Fa-f]{64})")
  foreach ($p in $pairs) { if ($p.Groups[1].Value -like "*$baseName*") { $p.Groups[2].Value.ToLower(); break } }
'
```

Expected (for 5.2.3.32296; a newer version shows its own hash — MUST be 64 lowercase hex, and MUST come from a plain `BCompare-<ver>.exe` URL, not a localized `BCompare-de-…` one):

```
5.2.3.32296 -> HTTP 200
a74239803aa1a1373735dc092365cca85c726178625aa51821f35aaf42559621
```

The full-download hash was verified byte-for-byte during design (2026-07-14); the HEAD probe here avoids re-downloading 28 MB per run.

- [ ] **Step 4: BOM/LF + lint gate**

Same three commands as Task 1 Step 6. Expected: BOM `efbbbf`, no CRLF, ps-lint clean.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): Beyond Compare — sixth installer-class app (winget-listing resolver, per-user Inno)"
```

---

### Task 4: `docs/windows/application_list.md` — Beyond Compare moves to auto-installed

**Files:**
- Modify: `docs/windows/application_list.md:17` (delete from Manual installs) and `:29` (add after WinSCP in Auto-installed)

**Interfaces:**
- Consumes: nothing. Produces: nothing code-visible — docs only.

- [ ] **Step 1: Move the entry**

Delete the `- Beyond Compare` line from the `## Manual installs` list. Add `- Beyond Compare` to `## Auto-installed by bootstrap.ps1` immediately after the `- WinSCP` line. Resulting auto-installed section (context):

```markdown
- DBeaver
- WinSCP
- Beyond Compare
- Claude Code
```

- [ ] **Step 2: Verify + commit**

```bash
rg -n 'Beyond Compare' /home/arrush.chaturvedi/.local/share/chezmoi/docs/windows/application_list.md
```

Expected: exactly ONE hit, in the Auto-installed section (after WinSCP).

```bash
git add docs/windows/application_list.md
git commit -m "docs(windows): Beyond Compare moves to auto-installed in application_list.md"
```

---

### Task 5: `README.html` — installer-class entry + enumeration sweep

**Files:**
- Modify: `README.html:2900-2915` area (new `<li>` card after WinSCP's), `:3055` (`-ForceInstaller` flag line), `:3111-3116` (`-SkipToolInstall` prose), `:4694-4702` (troubleshooting sha256 entry)

**Interfaces:**
- Consumes: nothing. Produces: nothing code-visible — docs only.

- [ ] **Step 1: Locate every enumeration (guard against drift since planning)**

```bash
rg -n -i 'winscp' /home/arrush.chaturvedi/.local/share/chezmoi/README.html
```

Expected hits ≈ the four regions listed under Files. Update EVERY hit that enumerates installer-class apps; regions found at plan time are below — if the sweep finds more, extend the same pattern.

- [ ] **Step 2: Add the Beyond Compare card**

Insert after WinSCP's `</li>` (line 2914), before the SSHFS-Win `<li>`, matching the surrounding indentation:

```html
                        <li>
                            <strong>Beyond Compare</strong> &mdash; same
                            installer-class path with a further twist: Scooter
                            Software has no GitHub presence at all, so the
                            script resolves the newest published version from
                            the official winget manifest tree, downloads the
                            Inno Setup <code>.exe</code> straight from
                            scootersoftware.com, and verifies it against that
                            same manifest&rsquo;s sha256 &mdash; version and
                            hash from one authority. Silent per-user install
                            (<code>/VERYSILENT /CURRENTUSER</code> &mdash; no
                            admin). Commercial: runs as a 30-day trial until
                            your license key is entered; its in-app update
                            check prompts before installing &mdash;
                            <code>-ForceInstaller</code> to reseed.
                        </li>
```

- [ ] **Step 3: Extend the three enumerations**

Line 3055 — old:

```html
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys, DBeaver, WinSCP) even if present
```

New:

```html
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys, DBeaver, WinSCP, Beyond Compare) even if present
```

Lines 3113-3116 — old:

```html
                        installs, <em>and</em> the installer-class apps
                        (Obsidian, Zed, DevToys, DBeaver, WinSCP) and the native
                        <strong>Claude Code</strong> install entirely
                        (assumes they&rsquo;re already present). Obsidian, Zed, DevToys, DBeaver, and WinSCP install
```

New:

```html
                        installs, <em>and</em> the installer-class apps
                        (Obsidian, Zed, DevToys, DBeaver, WinSCP, Beyond
                        Compare) and the native
                        <strong>Claude Code</strong> install entirely
                        (assumes they&rsquo;re already present). Obsidian, Zed, DevToys, DBeaver, WinSCP, and Beyond Compare install
```

Lines 4694-4702 — old:

```html
                                binary. Installer-class tools
                                (<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys, DBeaver, WinSCP) are
                                <em>not</em> pinned &mdash; they verify against the
                                GitHub API&rsquo;s sha256 <code>digest</code> for
                                the latest asset (WinSCP, which has no GitHub
                                releases, verifies against the official winget
                                manifest&rsquo;s sha256 instead), and the same
                                hard-fail applies on a mismatch.
```

New:

```html
                                binary. Installer-class tools
                                (<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys, DBeaver, WinSCP, Beyond Compare)
                                are <em>not</em> pinned &mdash; they verify against
                                the GitHub API&rsquo;s sha256 <code>digest</code>
                                for the latest asset (WinSCP and Beyond Compare,
                                which publish no GitHub releases, verify against
                                the official winget manifest&rsquo;s sha256
                                instead), and the same hard-fail applies on a
                                mismatch.
```

- [ ] **Step 4: Verify + commit**

```bash
rg -c 'Beyond Compare' /home/arrush.chaturvedi/.local/share/chezmoi/README.html   # ≥ 4 (card + three enumerations)
```

Open `README.html` in a browser if convenient (renders from disk) — the new card must sit between WinSCP and SSHFS-Win with intact markup.

```bash
git add README.html
git commit -m "docs(readme): Beyond Compare installer-class entry + enumeration sweep"
```

---

### Task 6: `CLAUDE.md` + `docs/claude/file-care.md` + `CLAUDE_CHANGELOG.md` + final gates

**Files:**
- Modify: `CLAUDE.md:91` (the installer-class invariant paragraph)
- Modify: `docs/claude/file-care.md:37` (the `bootstrap.ps1` entry's installer-class tail)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: nothing. Produces: nothing code-visible — Claude-internal docs. (`docs/claude/invariants.md` has NO installer-class enumeration — verified at plan time with `rg -n -i 'winscp|installer' docs/claude/invariants.md`; do not add one.)

- [ ] **Step 1: CLAUDE.md invariant paragraph (line 91)**

Three surgical edits to the `**There is also an installer class …**` paragraph:

1. Example list: `e.g. Obsidian + Zed + DevToys + DBeaver + WinSCP` → `e.g. Obsidian + Zed + DevToys + DBeaver + WinSCP + Beyond Compare`.
2. Field count: `The class has five OPT-IN per-tool fields (absent = old behavior):` → `The class has six OPT-IN per-tool fields (absent = old behavior):`.
3. Append after the WinSCP field description (the text ending `update checks prompt in-app → \`UpdateHint\`)`), before the final period, as a new sentence-level clause:

```
; Beyond Compare carries `WingetVersions` + the same direct-URL pair (Scooter Software has NO GitHub presence at all — `Get-LatestWingetVersion` lists the winget-pkgs manifest directory, whose subdir names ARE the 4-part versions its scootersoftware.com `{VERSION}` URL needs, and sha256 comes from that same manifest: version + hash from ONE authority, so a lagging winget seeds the prior version still-verified; commercial trialware — the seed installs the 30-day trial, the user's license key unlocks it; update checks prompt in-app → `UpdateHint`)
```

- [ ] **Step 2: docs/claude/file-care.md (line 37)**

Append after the sentence ending `…installing per-user via Inno \`/CURRENTUSER\`.`:

```
Beyond Compare is the winget-listing variant — Scooter Software has no GitHub presence at all, so the opt-in `WingetVersions` field resolves the version from the winget-pkgs manifest-directory listing via `Get-LatestWingetVersion` (subdir names are the 4-part versions the download URL needs), with the installer from scootersoftware.com's `{VERSION}` template and sha256 from the same manifest (one authority for both).
```

- [ ] **Step 3: CLAUDE_CHANGELOG.md row**

Append to the table (match the existing 3-column shape):

```markdown
| Added Beyond Compare as the sixth installer-class app in `bootstrap.ps1`, via a new sixth opt-in field `WingetVersions` — Scooter Software has NO GitHub presence (WinSCP at least had tags), so `Get-LatestWingetVersion` lists the winget-pkgs manifest directory (subdir names ARE the 4-part versions the download URL needs, e.g. `BCompare-5.2.3.32296.exe`) and the existing `UrlTemplate`/`HashManifest` machinery does the rest — version + sha256 from the SAME authority (a lagging winget seeds the prior version, still hash-verified; mismatch hard-fails). Silent per-user Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER` — no admin; commercial trialware (seed = 30-day trial, license key unlocks); prompt-based in-app updates → `UpdateHint`; the `-CheckForUpdates` installer loop now branches on `WingetVersions` (first Repo-less entry). `application_list.md`: Beyond Compare moved to auto-installed. | **Yes** | §setup-windows: Beyond Compare installer-class entry after WinSCP; `-ForceInstaller` flag-line and `-SkipToolInstall` prose enumerations gain Beyond Compare; §troubleshooting sha256-mismatch entry's winget-manifest note covers WinSCP + Beyond Compare. |
```

- [ ] **Step 4: Final gates (whole branch)**

```bash
# parse gate (expected 0)
powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)', [ref]\$null, [ref]\$e); \$e.Count"
# stale-count sweep over the LIVE surfaces (expected: no hits — 'five OPT-IN' is gone).
# Deliberately excludes docs/superpowers/ — the WinSCP-era plan/spec quote the old banner historically.
rg -n -i 'five OPT-IN' /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1 /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE.md /home/arrush.chaturvedi/.local/share/chezmoi/docs/claude /home/arrush.chaturvedi/.local/share/chezmoi/README.html
# full repo lint (invariants, shfmt, shellcheck, gitleaks, BOM)
make -C makefile lint MODE=prod
make -C makefile ps-lint MODE=prod
```

Expected: `0` parse errors; zero `five OPT-IN` hits; both lint targets clean.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): installer-class invariant + file-care + changelog gain Beyond Compare / WingetVersions"
```

---

## Post-merge (manual, by the user — not plan tasks)

On the Windows host: re-run `bootstrap.ps1` — Beyond Compare installs silently per-user with **no UAC prompt**, Start-menu entry appears, HKCU `BeyondCompare5_is1` exists (record actual DisplayName/DisplayVersion — expected 4-part, matching `PackageVersion`, since the winget manifest carries no `AppsAndFeaturesEntries` override); immediate re-run skips it; `-Doctor` shows a green Beyond Compare row with the UpdateHint; `-CheckForUpdates` compares registry DisplayVersion against the winget-resolved 4-part latest; `-ForceInstaller` reinstalls; the five existing installer apps behave identically to before.
