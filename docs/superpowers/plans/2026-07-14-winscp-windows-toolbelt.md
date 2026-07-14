# WinSCP Windows Toolbelt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-install WinSCP on the Windows host as the fifth `$InstallerTools` app in `bootstrap.ps1` via a new opt-in direct-URL resolver (WinSCP publishes no GitHub release assets), silent per-user `/CURRENTUSER` install, sha256 from the official winget manifest; move WinSCP to the auto-installed section of `application_list.md` and remove FileZilla.

**Architecture:** One mechanism change (`Install-InstallerTool` gains a `UrlTemplate`/`HashManifest` branch: version from `Get-LatestGitTag`, URL from a `{VERSION}` template, hash from the winget manifest — converging on the existing download/verify/install tail) + one data entry + a docs sweep. No new files, no version pins, no Linux half.

**Tech Stack:** PowerShell 5.1-compatible script edits (`bootstrap.ps1`), HTML/Markdown docs.

**Spec:** `docs/superpowers/specs/2026-07-14-winscp-windows-toolbelt-design.md` (approved 2026-07-14).

## Global Constraints

- Work on the existing `feat/winscp-windows-toolbelt` branch (spec already committed as `5f38c67`).
- `bootstrap.ps1` MUST keep its **UTF-8 BOM** and **LF** line endings after every edit (PS 5.1 mis-decodes glyphs without the BOM). The repo's `post-edit-guard` hook auto-repairs both and tells you to re-read — obey it. Verify manually anyway (Task 1 Step 6).
- All PowerShell must be **5.1-compatible**: no `??`, no ternary `? :`, hashtable key probes via `.ContainsKey()`, PSObject property probes via `.PSObject.Properties['name']` (StrictMode-safe).
- Installer-class rules: **no admin/UAC anywhere, nothing added to PATH**, existing entries (Obsidian/Zed/DevToys/DBeaver) behaviorally unchanged — the GitHub-release path must produce the same messages and outcomes as today.
- Per-user is load-bearing: WinSCP's `SilentArgs` MUST include `/CURRENTUSER` and MUST NOT include `/ALLUSERS`.
- **No `versions.mk` change** → no `check-invariants.sh` addition, no TOOLS-block regeneration, no `cza` needed. No new bootstrap flags → no completion-parity edits.
- README/CLAUDE.md/changelog land in the same PR as the code (squash-merge satisfies the "same commit" doc rule).
- Windows-host runtime verification is **post-merge, manual, by the user** (no Windows here); this plan's verification is premise proofs + parser gates + lint. This WSL host has `powershell.exe` interop on PATH — the plan uses it as a real PS 5.1 parse/behavior gate; if interop is unavailable, note it and rely on CI's `ps-lint`.
- There is no Pester/test framework for `bootstrap.ps1` in this repo. The test cycle per task = premise-proof probes (prove upstream facts the code depends on) + a PS 5.1 parse gate after every edit + behavior probes of extracted logic run through `powershell.exe`.

---

### Task 1: `bootstrap.ps1` — opt-in direct-URL resolver in `Install-InstallerTool`

**Files:**
- Modify: `bootstrap.ps1:309-327` (class banner comment — resolver sentence + opt-in fields three → five)
- Modify: `bootstrap.ps1:708-807` (`Install-InstallerTool` — branch into two resolver paths converging on a shared download/verify/install tail)

**Interfaces:**
- Consumes: `Get-LatestGitTag -Repo <owner/repo> -TagPrefix <string>` (exists at `bootstrap.ps1:1458`; returns newest matching tag as a string or `$null`; its default filter `^\d+(\.\d+)*$` drops `-beta` tags), `Test-InstallerPresent`, `Write-Log/Ok/Warn/Fail`, `$ForceInstaller`.
- Produces: `Install-InstallerTool` honoring two new optional hashtable keys — `UrlTemplate` (string; `{VERSION}` placeholder; presence switches resolution from the GitHub releases API + `AssetMatch` to git tags + template substitution) and `HashManifest` (string; `{VERSION}`-templated winget-manifest URL; source of the enforced sha256). Task 2's entry supplies exactly these keys.

- [ ] **Step 1: Prove the premises (no GitHub releases; the manifest pairing regex works on real data)**

Run:

```bash
curl -s 'https://api.github.com/repos/winscp/winscp/releases?per_page=5'
```

Expected: `[]` (zero releases — this is why the GitHub-release resolver cannot work and the direct-URL branch exists). Verified 2026-07-14; if non-empty, upstream started publishing releases — stop and re-check the spec (the plain `AssetMatch` path might suffice).

Then prove the hash-pairing regex extracts the Setup.exe hash (not the sibling MSI hash) from the real 6.5.6 winget manifest, running under real PS 5.1 via WSL interop:

```bash
powershell.exe -NoProfile -Command '
  $m = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/WinSCP/WinSCP/6.5.6/WinSCP.WinSCP.installer.yaml" -UseBasicParsing).Content
  $pairs = [regex]::Matches($m, "(?ms)InstallerUrl:\s*(\S+).*?InstallerSha256:\s*([0-9A-Fa-f]{64})")
  foreach ($p in $pairs) { if ($p.Groups[1].Value -like "*WinSCP-6.5.6-Setup.exe*") { $p.Groups[2].Value.ToLower(); break } }
'
```

Expected output (the Setup.exe hash; the manifest also lists MSI hash `d3ef315e...` — getting that one means the pairing is broken):

```
4488c493bafca6af4e7ae54ed39cb71479e65dc192c4d1a471647bf9cb9d6db0
```

- [ ] **Step 2: Update the class banner comment**

In `bootstrap.ps1`, replace the banner's resolver sentence (lines 309-316). Old:

```powershell
# Installer-layout tools — apps that publish a silent, admin-free installer (.exe)
# instead of a portable zip. Unlike $PortableTools these are NOT version-pinned:
# we resolve the LATEST GitHub release at run time (the app self-updates after),
# verify the download against the GitHub API's per-asset sha256 'digest', run the
# installer silently PER-USER (no admin), and add NOTHING to PATH (GUI apps create
# their own Start-menu shortcut). Presence is detected via the Uninstall registry
# (DisplayName), so a manual uninstall makes the next bootstrap reinstall. Force a
# reinstall with -ForceInstaller.
```

New:

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

Then replace the opt-in fields list (lines 317-327). Old:

```powershell
# Three OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
#   IncludePrerelease  resolve the newest NON-DRAFT release from /releases
#                      instead of /releases/latest — DevToys flags EVERY 2.x
#                      release prerelease:true, so "latest" returns 2023's
#                      v1.0.13.0 (an MSIX-only release with no .exe asset).
#   UpdateHint         status text for -Doctor/-CheckForUpdates when the
#                      default "self-updates" story is wrong — DevToys' in-app
#                      update check is notification-only (it never installs).
#   TagPrefix          git-tag prefix for the -CheckForUpdates version lookup
#                      (default "v") — DBeaver's tags are bare (26.1.2), so it
#                      overrides with "" or the update scan resolves nothing.
```

New:

```powershell
# Five OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
#   IncludePrerelease  resolve the newest NON-DRAFT release from /releases
#                      instead of /releases/latest — DevToys flags EVERY 2.x
#                      release prerelease:true, so "latest" returns 2023's
#                      v1.0.13.0 (an MSIX-only release with no .exe asset).
#   UpdateHint         status text for -Doctor/-CheckForUpdates when the
#                      default "self-updates" story is wrong — DevToys' in-app
#                      update check is notification-only (it never installs);
#                      WinSCP's prompts before installing.
#   TagPrefix          git-tag prefix for the -CheckForUpdates version lookup
#                      AND the UrlTemplate version resolve (default "v") —
#                      DBeaver's/WinSCP's tags are bare (26.1.2 / 6.5.6), so
#                      they override with "" or the lookup resolves nothing.
#   UrlTemplate        direct download URL with a {VERSION} placeholder — for
#                      apps with NO GitHub release assets (WinSCP publishes
#                      tags only). Its presence switches Install-InstallerTool
#                      from the releases API + AssetMatch to: version =
#                      Get-LatestGitTag (beta tags dropped by its default
#                      filter), URL = template substitution.
#   HashManifest       {VERSION}-templated URL of the official winget
#                      installer manifest — the sha256 source for UrlTemplate
#                      installs (no GitHub digest exists there). Mismatch
#                      hard-fails; a missing/lagging manifest (winget trails
#                      brand-new releases by hours-days) warns and proceeds —
#                      the same posture as a missing GitHub digest.
```

- [ ] **Step 3: Rewrite `Install-InstallerTool` with the two-path resolver**

Replace the whole function (`bootstrap.ps1:708-807`) with the following. The GitHub branch is today's code verbatim (same messages); the tail is today's code with `$asset.browser_download_url`/`$release.tag_name`/digest-probe generalized to the four branch-produced facts:

```powershell
function Install-InstallerTool {
    param([hashtable]$Tool)

    # Idempotency: skip if already installed, unless -ForceInstaller. Detection is by
    # Uninstall-registry DisplayName (not a version stamp) — these are LATEST/
    # self-updating, so there is no version to stamp.
    if ((-not $ForceInstaller) -and (Test-InstallerPresent -DisplayName $Tool.DetectName)) {
        Write-Ok "$($Tool.Name) already installed (use -ForceInstaller to reinstall)"
        return
    }

    Write-Log "Installing $($Tool.Name) (latest, installer)..."

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    # Two resolver paths produce the same four facts for the shared
    # download/verify/install tail below:
    #   $downloadUrl    where the installer .exe comes from
    #   $expectedSha    lowercase sha256 to enforce, or $null (warn+proceed)
    #   $noHashWarning  warn text used when $expectedSha is $null
    #   $versionLabel   what the success line reports
    #   $hashSource     names the hash authority in the mismatch hard-fail
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
        $downloadUrl  = $Tool.UrlTemplate.Replace('{VERSION}', $version)
        $versionLabel = $version
        $hashSource   = "winget-manifest InstallerSha256"
        # The installer's basename picks the right InstallerSha256 out of the
        # manifest (which also hashes sibling assets — WinSCP's .msi). Vendor
        # URLs end in a /download action segment (winscp.net, SourceForge) —
        # strip it before taking the basename.
        $baseName      = ($downloadUrl -replace '/download/?$', '').Split('/')[-1]
        $expectedSha   = $null
        $noHashWarning = "$($Tool.Name): no HashManifest configured — skipping hash verification."
        if ($Tool.ContainsKey('HashManifest')) {
            $manifestUrl   = $Tool.HashManifest.Replace('{VERSION}', $version)
            $noHashWarning = "$($Tool.Name): winget manifest fetch failed for $version (not published there yet?) — skipping hash verification."
            try {
                $manifest = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing).Content
                # komac-emitted manifests put InstallerUrl before its
                # InstallerSha256 within each installer entry; the lazy match
                # pairs each URL with the nearest FOLLOWING hash.
                $pairs = [regex]::Matches($manifest, '(?ms)InstallerUrl:\s*(\S+).*?InstallerSha256:\s*([0-9A-Fa-f]{64})')
                foreach ($m in $pairs) {
                    if ($m.Groups[1].Value -like "*$baseName*") {
                        $expectedSha = $m.Groups[2].Value.ToLower()
                        break
                    }
                }
                if (-not $expectedSha) {
                    $noHashWarning = "$($Tool.Name): winget manifest has no entry matching $baseName — skipping hash verification."
                }
            } catch {
                # 404 = winget lags this brand-new release -> $noHashWarning
                # fires in the warn+proceed branch below. (The assignment also
                # keeps the catch non-empty for PSAvoidUsingEmptyCatchBlock —
                # the repo's PSSA gate runs at Warning+.)
                $expectedSha = $null
            }
        }
    } else {
        # --- GitHub-release path (Obsidian/Zed/DevToys/DBeaver) ---
        # Resolve the latest release. $env:GITHUB_TOKEN (already used for the private-repo
        # clone) lifts the 60-req/hr anonymous API rate limit. A User-Agent is required
        # by the GitHub API.
        $headers = @{ "User-Agent" = "workstation-bootstrap" }
        if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }

        try {
            if ($Tool.ContainsKey('IncludePrerelease') -and $Tool.IncludePrerelease) {
                # /releases/latest excludes prereleases, and some repos (DevToys)
                # flag EVERY release prerelease:true — take the newest non-draft
                # entry of /releases instead (the list is newest-first).
                $releases = @(Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases?per_page=10" `
                    -Headers $headers -UseBasicParsing)
                $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
                if (-not $release) { throw "no non-draft release among the newest $($releases.Count)" }
            } else {
                $release = Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
                    -Headers $headers -UseBasicParsing
            }
        } catch {
            Write-Warn "$($Tool.Name): GitHub API lookup failed: $($_.Exception.Message)"
            Write-Warn "  Skipping — install it manually or re-run later."
            return
        }

        $assets = @($release.assets | Where-Object { $_.name -like $Tool.AssetMatch })
        if ($assets.Count -eq 0) {
            Write-Warn "$($Tool.Name): no asset matching '$($Tool.AssetMatch)' in $($release.tag_name) — skipping"
            return
        }
        if ($assets.Count -gt 1) {
            Write-Warn "$($Tool.Name): $($assets.Count) assets match '$($Tool.AssetMatch)' — using $($assets[0].name)"
        }
        $asset        = $assets[0]
        $downloadUrl  = $asset.browser_download_url
        $versionLabel = $release.tag_name
        $hashSource   = "GitHub-reported digest"
        # Under Set-StrictMode -Version Latest an absent 'digest' property
        # THROWS on access, so probe it via PSObject.Properties (not
        # $asset.digest directly) to keep the warn-and-proceed path working.
        $digest      = if ($asset.PSObject.Properties['digest']) { $asset.digest } else { $null }
        $expectedSha = $null
        if ($digest -and $digest.StartsWith("sha256:")) {
            $expectedSha = $digest.Substring(7).ToLower()
        }
        $noHashWarning = "$($Tool.Name): GitHub published no sha256 digest for $($asset.name) — skipping hash verification."
    }

    $tmpExe = Join-Path $env:TEMP "ws-$($Tool.Name)-installer.exe"

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpExe -UseBasicParsing
    } catch {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    try {
        # Verify against the published sha256. Mismatch is a HARD fail
        # (corruption/tamper); an unavailable hash warns but proceeds (HTTPS +
        # a trusted host). NOTE: Write-Fail calls exit 1; remove the temp file
        # BEFORE it so cleanup is guaranteed regardless of whether finally
        # runs on exit — mirrors Install-PortableTool.
        if ($expectedSha) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $tmpExe).Hash.ToLower()
            if ($actual -ne $expectedSha) {
                Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
                Write-Fail @"
$($Tool.Name) sha256 mismatch — refusing to install.
  expected: $expectedSha
  actual:   $actual
The $hashSource doesn't match the download (corrupted or tampered).
"@
            }
        } else {
            Write-Warn $noHashWarning
        }

        # Silent, per-user install. No Add-ToUserPath — GUI apps make their own
        # Start-menu shortcut and self-update from here.
        $proc = Start-Process -FilePath $tmpExe -ArgumentList $Tool.SilentArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warn "$($Tool.Name) installer exited with code $($proc.ExitCode) — verify it installed."
        } else {
            Write-Ok "$($Tool.Name) installed ($versionLabel)"
        }
    } finally {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    }
}
```

Behavioral equivalences to preserve (reviewer checklist): GitHub-path messages are byte-identical to today's; the digest-absent warn still fires only at verify time (after download), not at resolve time; `Write-Fail`'s text for GitHub apps still reads "The GitHub-reported digest doesn't match the download (corrupted or tampered)."; the `finally` cleanup and pre-`Write-Fail` `Remove-Item` are unchanged.

- [ ] **Step 4: PS 5.1 parse gate**

Run:

```bash
powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(wslpath -w /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1)', [ref]\$null, [ref]\$e); \$e.Count"
```

Expected: `0` (zero parse errors). Any other number: fix the edit before proceeding.

- [ ] **Step 5: Lint**

Run:

```bash
make -C makefile ps-lint MODE=prod
```

Expected: `pwsh not installed — skipped (CI enforces PowerShell lint)` on this host (soft-skip is fine — CI's `lint.yml` runs PSScriptAnalyzer for real), or a clean PSScriptAnalyzer pass if pwsh exists.

- [ ] **Step 6: BOM + LF verify**

Run:

```bash
head -c3 /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1 | xxd | head -1
file /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.ps1
```

Expected: first line starts `00000000: efbb bf` (UTF-8 BOM); `file` output does NOT say "with CRLF line terminators".

- [ ] **Step 7: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add bootstrap.ps1
git commit -m "feat(windows): installer-class direct-URL resolver — opt-in UrlTemplate/HashManifest fields"
```

---

### Task 2: `bootstrap.ps1` — WinSCP entry

**Files:**
- Modify: `bootstrap.ps1:352-359` region (append the WinSCP entry after DBeaver's, before the closing `)` of `$InstallerTools`)

**Interfaces:**
- Consumes: Task 1's `UrlTemplate`/`HashManifest` handling in `Install-InstallerTool`; the existing `-Doctor` loop (honors `UpdateHint`, `bootstrap.ps1:1587-1596`) and `-CheckForUpdates` loop (honors `TagPrefix` + `UpdateHint`, `bootstrap.ps1:1721-1738`) — **zero changes to either loop**.
- Produces: `$InstallerTools` entry `Name = "WinSCP"` — the data Tasks 3-5's docs describe.

- [ ] **Step 1: Prove the entry's premises (tag resolve, URL, per-user switch)**

Run:

```bash
GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs https://github.com/winscp/winscp.git \
  | awk -F/ '{print $NF}' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
curl -sIL -o /dev/null -w '%{http_code}\n' 'https://winscp.net/download/WinSCP-6.5.6-Setup.exe/download'
```

Expected: first command prints a bare stable version `>= 6.5.6` (this mirrors `Get-LatestGitTag`'s default filter — the `-beta` tags visible in the raw ref list must NOT appear); second prints `200` (the `{VERSION}` URL template is live; it redirects to a SourceForge mirror, which `Invoke-WebRequest` follows). Per-user premise (no probe possible from Linux): winscp.net/eng/docs/installation documents `/CURRENTUSER` as "non administrative install mode", and the winget user-scope variant passes exactly that switch — verified 2026-07-14 in the spec.

- [ ] **Step 2: Append the WinSCP entry**

In `bootstrap.ps1`, replace DBeaver's closing brace + the array's closing paren:

```powershell
        TagPrefix  = ""                                # tags are bare (26.1.2, no v) — read by the -CheckForUpdates lookup only
    }
)
```

with:

```powershell
        TagPrefix  = ""                                # tags are bare (26.1.2, no v) — read by the -CheckForUpdates lookup only
    },
    @{
        Name         = "WinSCP"
        Repo         = "winscp/winscp"                 # tags only — NO release assets; version source for UrlTemplate + -CheckForUpdates
        TagPrefix    = ""                              # bare tags (6.5.6); Get-LatestGitTag's default filter drops 6.6-beta et al.
        UrlTemplate  = "https://winscp.net/download/WinSCP-{VERSION}-Setup.exe/download"  # first-party; redirects to a SourceForge mirror
        HashManifest = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/WinSCP/WinSCP/{VERSION}/WinSCP.WinSCP.installer.yaml"
        SilentArgs   = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER"  # Inno silent + documented per-user mode -> no admin/UAC (NEVER /ALLUSERS)
        DetectName   = "WinSCP*"                       # HKCU ...\Uninstall\winscp3_is1, DisplayName version-suffixed ("WinSCP 6.5.6"); glob also matches a machine-wide HKLM install (intended: never double-install alongside an admin install); MS-Store MSIX copies are invisible here and would double-install (known class caveat, same as DevToys/DBeaver)
        UpdateHint   = "in-app update check prompts to install (not silent) — or re-run bootstrap with -ForceInstaller"
    }
)
```

Note: no `AssetMatch` — the direct-URL path never reads it (mutually exclusive resolvers by construction), and no `IncludePrerelease` — releases aren't consulted at all.

- [ ] **Step 3: PS 5.1 parse gate + entry sanity probe**

Run the same parse gate as Task 1 Step 4 (expected `0`), then prove the entry's template substitution and DBeaver's continued API routing by extracting both entries under real PS 5.1:

```bash
powershell.exe -NoProfile -Command '
  $winscp = @{ UrlTemplate = "https://winscp.net/download/WinSCP-{VERSION}-Setup.exe/download" }
  $dbeaver = @{ Name = "DBeaver"; Repo = "dbeaver/dbeaver"; AssetMatch = "dbeaver-ce-*-windows-x86_64.exe"; SilentArgs = "/S /currentuser"; DetectName = "DBeaver*"; TagPrefix = "" }
  Write-Output ("winscp-direct: " + $winscp.ContainsKey("UrlTemplate"))
  Write-Output ("dbeaver-github: " + (-not $dbeaver.ContainsKey("UrlTemplate")))
  Write-Output $winscp.UrlTemplate.Replace("{VERSION}", "6.5.6")
'
```

Expected:

```
winscp-direct: True
dbeaver-github: True
https://winscp.net/download/WinSCP-6.5.6-Setup.exe/download
```

- [ ] **Step 4: BOM + LF verify**

Same commands as Task 1 Step 6; same expectations.

- [ ] **Step 5: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add bootstrap.ps1
git commit -m "feat(windows): WinSCP — fifth installer-class app, per-user /CURRENTUSER, winget-manifest sha256"
```

---

### Task 3: `docs/windows/application_list.md` — WinSCP moves, FileZilla removed

**Files:**
- Modify: `docs/windows/application_list.md` (delete Manual row line 7; insert into the auto list after DBeaver, line 35-36 region)

**Interfaces:**
- Consumes: Task 2's entry (the doc claims must match: WinSCP auto-installed by `bootstrap.ps1`).
- Produces: the authoritative Windows app checklist Tasks 4-5 stay consistent with.

- [ ] **Step 1: Edit the file**

Delete line 7 entirely (FileZilla is deliberately NOT kept as a manual alternative — explicit user decision 2026-07-14, deviating from the line-2 "alternatives are kept" convention; the convention line itself stays, it still describes every other row):

```markdown
- WinSCP / FileZilla
```

And in the `## Auto-installed by bootstrap.ps1` section, insert after `- DBeaver`:

```markdown
- WinSCP
```

Resulting auto section (full, for the reviewer):

```markdown
## Auto-installed by bootstrap.ps1

- WezTerm
- Starship
- Obsidian
- Zed
- DevToys
- DBeaver
- WinSCP
- Claude Code
- chezmoi, Helix, and the JetBrainsMono Nerd Font (were never in the manual list)
```

- [ ] **Step 2: Verify**

Run:

```bash
rg -n -i 'winscp|filezilla' /home/arrush.chaturvedi/.local/share/chezmoi/docs/windows/application_list.md
```

Expected: exactly one hit — the `- WinSCP` line inside the Auto-installed section. Zero `filezilla` hits.

- [ ] **Step 3: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add docs/windows/application_list.md
git commit -m "docs(windows): WinSCP to auto-installed list; drop FileZilla"
```

---

### Task 4: `README.html` — setup-windows entry + enumeration sweep

**Files:**
- Modify: `README.html:2899` (new `<li>` after DBeaver's, before SSHFS-Win's)
- Modify: `README.html:3040` (`-ForceInstaller` flag comment)
- Modify: `README.html:3099-3101` (two enumerations in the "No elevation anywhere" note-row)
- Modify: `README.html:4680-4685` (troubleshooting sha256-mismatch entry)

**Interfaces:**
- Consumes: Tasks 1-2 (the prose must describe exactly the shipped mechanism: git-tag version, winscp.net→SourceForge download, winget-manifest sha256, `/VERYSILENT /CURRENTUSER`, prompt-based updates).
- Produces: user-facing README truth Task 5's changelog row points at.

- [ ] **Step 1: Re-locate the four sites (line numbers drift)**

Run:

```bash
rg -n 'DBeaver' /home/arrush.chaturvedi/.local/share/chezmoi/README.html
```

Expected: five hits ≈ lines 2890, 3040, 3099, 3101, 4681. If more appear, a new enumeration was added since planning — update it too, same pattern.

- [ ] **Step 2: Insert the WinSCP `<li>` after DBeaver's closing `</li>` (≈ line 2899)**

```html
                        <li>
                            <strong>WinSCP</strong> &mdash; same
                            installer-class path with one twist: WinSCP
                            publishes no GitHub release assets, so the script
                            resolves the newest git tag, downloads the Inno
                            Setup <code>.exe</code> from winscp.net (which
                            redirects to a SourceForge mirror), and verifies
                            it against the official winget manifest&rsquo;s
                            sha256 for that version instead of a GitHub
                            digest. Silent per-user install
                            (<code>/VERYSILENT /CURRENTUSER</code> &mdash; no
                            admin); its in-app update check prompts before
                            installing &mdash; <code>-ForceInstaller</code> to
                            reseed from the script.
                        </li>
```

- [ ] **Step 3: Extend the three enumerations**

Line ≈3040, old:

```
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys, DBeaver) even if present
```

New:

```
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys, DBeaver, WinSCP) even if present
```

Lines ≈3098-3101, old:

```html
                        <em>and</em> the installer-class apps
                        (Obsidian, Zed, DevToys, DBeaver) and the native
                        <strong>Claude Code</strong> install entirely
                        (assumes they&rsquo;re already present). Obsidian, Zed, DevToys, and DBeaver install
```

New:

```html
                        <em>and</em> the installer-class apps
                        (Obsidian, Zed, DevToys, DBeaver, WinSCP) and the native
                        <strong>Claude Code</strong> install entirely
                        (assumes they&rsquo;re already present). Obsidian, Zed, DevToys, DBeaver, and WinSCP install
```

- [ ] **Step 4: Troubleshooting sha256-mismatch entry (≈ lines 4679-4685)**

Old:

```html
                                The script refuses to install an unverified
                                binary. Installer-class tools
                                (<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys, DBeaver) are
                                <em>not</em> pinned &mdash; they verify against the
                                GitHub API&rsquo;s sha256 <code>digest</code> for
                                the latest asset, and the same hard-fail applies on
                                a mismatch.
```

New:

```html
                                The script refuses to install an unverified
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

- [ ] **Step 5: Verify + commit**

Run:

```bash
rg -c -i 'winscp' /home/arrush.chaturvedi/.local/share/chezmoi/README.html
```

Expected: `4` or more (the four sites; the `<li>` mentions WinSCP twice → count may read higher — confirm each of the four sites individually with `rg -n -i 'winscp'`). Then:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html
git commit -m "docs(readme): WinSCP installer-class entry + enumeration sweep"
```

---

### Task 5: `CLAUDE.md` + `docs/claude/file-care.md` + `CLAUDE_CHANGELOG.md`

**Files:**
- Modify: `CLAUDE.md:91` (the installer-class invariant bullet)
- Modify: `docs/claude/file-care.md:37` (the `$InstallerTools` sentence)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: Tasks 1-4 (describes exactly what shipped).
- Produces: the Claude-internal invariant text future sessions rely on.

- [ ] **Step 1: Confirm `docs/claude/invariants.md` needs no edit**

Run:

```bash
rg -n -i 'InstallerTools|installer-class' /home/arrush.chaturvedi/.local/share/chezmoi/docs/claude/invariants.md
```

Expected: zero hits (verified 2026-07-14 — the installer class is documented in CLAUDE.md + file-care.md only). If hits appear, sweep them with the same wording as Step 2.

- [ ] **Step 2: `CLAUDE.md` bullet (line 91)**

Three surgical replacements inside the existing bullet:

1. `(`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian + Zed + DevToys + DBeaver)` → `(`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian + Zed + DevToys + DBeaver + WinSCP)`
2. `DBeaver = NSIS MultiUser `/S /currentuser`), never `/allusers`/machine-wide` → `DBeaver = NSIS MultiUser `/S /currentuser`; WinSCP = Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`), never `/allusers`/machine-wide`
3. Two edits to the opt-in-fields sentence. It currently ends:

```
...so the `-CheckForUpdates` tag lookup overrides the default `v` with `""`).
```

   First change its opener `The class has three OPT-IN per-tool fields` → `The class has five OPT-IN per-tool fields`. Then replace that ending shown above with:

```
...so the `-CheckForUpdates` tag lookup overrides the default `v` with `""`); WinSCP carries `TagPrefix` too plus the direct-URL pair `UrlTemplate` + `HashManifest` (it publishes NO GitHub release assets — version resolves from its bare git tags via `Get-LatestGitTag` [beta tags dropped by the default filter], the installer downloads from winscp.net's `{VERSION}` URL template [redirects to a SourceForge mirror], and sha256 comes from the official winget manifest for that version: hard-fail on mismatch, warn+proceed when the manifest lags a brand-new release — the missing-digest posture; install is Inno per-user `/CURRENTUSER`, update checks prompt in-app → `UpdateHint`).
```

- [ ] **Step 3: `docs/claude/file-care.md` (line 37)**

After the sentence ending `` `-ForceInstaller` forces reinstall.`` append:

```
WinSCP is the class's direct-URL variant — no GitHub releases exist, so opt-in `UrlTemplate`/`HashManifest` fields resolve the version from bare git tags and verify sha256 via the official winget manifest for that version (hard-fail on mismatch; warn+proceed when the manifest lags a brand-new release), installing per-user via Inno `/CURRENTUSER`.
```

- [ ] **Step 4: `CLAUDE_CHANGELOG.md` row**

Append after the tab-completion row (current last row):

```markdown
| Added WinSCP as the fifth installer-class app in `bootstrap.ps1`, via a new opt-in direct-URL resolver — WinSCP publishes NO GitHub release assets, so two new opt-in fields (`UrlTemplate` + `HashManifest`, now five class opt-ins) route `Install-InstallerTool` through git tags + a `{VERSION}` vendor URL template, with sha256 from the official winget manifest (hard-fail on mismatch; warn+proceed when winget lags a new release — the missing-digest posture). Silent per-user Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER` — no admin; prompt-based in-app updates → `UpdateHint`; `TagPrefix ""` (bare tags, beta tags filtered). `application_list.md`: WinSCP moved to auto-installed; FileZilla removed entirely (explicit user decision — deliberate deviation from the "in-row alternatives are kept" convention). | **Yes** | §setup-windows: WinSCP installer-class entry after DBeaver; `-ForceInstaller` flag-line and `-SkipToolInstall` prose enumerations gain WinSCP; §troubleshooting sha256-mismatch entry notes the winget-manifest hash source for WinSCP. |
```

- [ ] **Step 5: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): installer-class invariant gains WinSCP + UrlTemplate/HashManifest opt-ins; changelog row"
```

---

### Task 6: Full verification sweep + PR

**Files:** none modified (fix-forward only if a check fails).

**Interfaces:**
- Consumes: everything above.
- Produces: a green branch ready for PR; the Windows-host runtime checklist for the user.

- [ ] **Step 1: Full lint**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
make lint MODE=prod
```

Expected: `✓ all invariant checks passed` (no new pins were added, so no check-invariants.sh changes were needed; shellcheck/shfmt/gitleaks untouched by this PR's file set).

- [ ] **Step 2: Final parse gate + BOM/LF on bootstrap.ps1**

Re-run Task 1 Steps 4 and 6 commands. Expected: `0` parse errors; BOM `efbbbf` present; no CRLF.

- [ ] **Step 3: Diff review against the spec**

Run:

```bash
git log --oneline main..HEAD
git diff main..HEAD --stat
```

Expected: the spec commit + five task commits; files touched = `bootstrap.ps1`, `docs/windows/application_list.md`, `README.html`, `CLAUDE.md`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`, the spec, this plan. Nothing else.

- [ ] **Step 4: Push + PR**

```bash
git push -u origin feat/winscp-windows-toolbelt
gh pr create --title "feat(windows): WinSCP — fifth installer-class app via direct-URL resolver (per-user, winget-manifest sha256)" --body "$(cat <<'EOF'
## Summary
- WinSCP auto-installs on the Windows host as the fifth `$InstallerTools` app — silent per-user Inno (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`), no admin/UAC, nothing on PATH
- New opt-in direct-URL resolver in `Install-InstallerTool` (`UrlTemplate` + `HashManifest`): WinSCP publishes NO GitHub release assets, so version resolves from its bare git tags, the .exe downloads from winscp.net's `{VERSION}` template (SourceForge mirror redirect), and sha256 is enforced from the official winget manifest (hard-fail mismatch; warn+proceed when winget lags a brand-new release). Obsidian/Zed/DevToys/DBeaver keep the GitHub path unchanged
- `application_list.md`: WinSCP moves Manual → Auto-installed; FileZilla removed entirely (explicit decision)
- README/CLAUDE.md/file-care/changelog swept

Spec: `docs/superpowers/specs/2026-07-14-winscp-windows-toolbelt-design.md`
Plan: `docs/superpowers/plans/2026-07-14-winscp-windows-toolbelt.md`

## Post-merge Windows validation (manual)
- [ ] `.\bootstrap.ps1` — WinSCP installs with NO UAC prompt (the load-bearing per-user requirement)
- [ ] HKCU `...\Uninstall\winscp3_is1` exists; record actual DisplayName/DisplayVersion
- [ ] Start-menu shortcut present; immediate re-run skips (registry detect)
- [ ] `-Doctor` shows a green WinSCP row with the UpdateHint; `-CheckForUpdates` resolves the latest bare tag (beta tags filtered)
- [ ] `-ForceInstaller` reinstalls; Obsidian/Zed/DevToys/DBeaver rows unchanged

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a
EOF
)"
```

Expected: PR URL printed. Do NOT merge — the user merges after review; Windows runtime validation happens post-merge per the checklist in the PR body.
