# Windows installer-layout tools (Obsidian) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an installer-layout tool class to `bootstrap.ps1` (silent, admin-free `.exe` installers resolved at LATEST and verified against the GitHub API's sha256 digest) and use it to auto-install Obsidian on the Windows client.

**Architecture:** A new `$InstallerTools` manifest + `Install-InstallerTool`/`Test-InstallerPresent` functions, parallel to the existing `$PortableTools`/`Install-PortableTool` path (left untouched). Installer tools resolve the latest GitHub release at run time, verify the download against the asset's API-reported `digest`, run the installer silently per-user, add nothing to PATH, and detect prior installs via the Uninstall registry. A new `-ForceInstaller` switch forces reinstall.

**Tech Stack:** PowerShell 5.1+ (Windows-only), GitHub REST API (`releases/latest`), NSIS silent install (`/S`), Windows Uninstall registry.

---

## Testing reality (read before starting)

This is a **Windows-only PowerShell script**. There is **no automated test harness** in this repo for `bootstrap.ps1`, and the dev host has **no `pwsh`** — so behavioral TDD is not possible cross-platform. The plan substitutes two layers of verification:

1. **Static checks runnable on the Linux dev host (every code task):**
   - `file bootstrap.ps1` → must report **`with BOM`** and must **NOT** report `CRLF` (PS 5.1 tripwire — CLAUDE.md).
   - `git diff --check` → no trailing whitespace / conflict markers.
   - `grep` → the new symbols are present / old text is gone.
   - If you happen to run this on a machine with `pwsh` or PowerShell, optionally parse-check:
     `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('bootstrap.ps1',[ref]$null,[ref]$null); 'parse-ok'"`
2. **On-Windows smoke test (final task, Task 8):** the real behavioral verification — exact PowerShell commands + expected output, run on a Windows host.

**BOM safety:** the Edit tool preserves the file's leading BOM as long as you never edit line 1 (`# bootstrap.ps1 — workstation setup (Windows client side)`). No task touches line 1. Still, every code task re-checks `file bootstrap.ps1` after editing.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `bootstrap.ps1` | Windows client bootstrap — tool installs | Add `-ForceInstaller` param, `$InstallerTools` manifest, `Test-InstallerPresent` + `Install-InstallerTool` functions, installer loop in `Invoke-ToolInstall` |
| `docs/windows/application_list.md` | Manual Windows app inventory | Annotate Obsidian as auto-installed |
| `README.html` | User-facing reference | §setup-windows install list + flags + no-elevation note; troubleshooting; §adding |
| `CLAUDE.md` | Claude-internal invariants | Extend the Windows-installs invariant for the installer class |
| `docs/claude/file-care.md` | Per-file gotchas | Extend the `bootstrap.ps1` entry for `$InstallerTools` |
| `CLAUDE_CHANGELOG.md` | Worked-examples archive | Append one row |

Each task below produces a self-contained commit. Tasks 1→3 are ordered (Task 3 wires functions defined in Task 2). Tasks 4→7 (docs) are independent of each other.

---

### Task 1: Add the `-ForceInstaller` flag (param + header doc)

**Files:**
- Modify: `bootstrap.ps1` (param block ~line 88; header comment ~line 73)

- [ ] **Step 1: Add the switch to the `param()` block**

Find (around line 87-90):

```powershell
    [switch]$SkipNerdFonts,
    [switch]$Reinstall,
    [switch]$Yes
)
```

Replace with:

```powershell
    [switch]$SkipNerdFonts,
    [switch]$ForceInstaller,
    [switch]$Reinstall,
    [switch]$Yes
)
```

- [ ] **Step 2: Document the flag in the header comment block**

Find (around line 72-73):

```
#   -SkipNerdFonts      skip the Nerd Font install
#   -Reinstall          wipe the cloned repo + chezmoi config first, then run the
```

Replace with:

```
#   -SkipNerdFonts      skip the Nerd Font install
#   -ForceInstaller     re-run installer-layout tool installs (e.g. Obsidian) even
#                       if already present. Portable tools (WezTerm/Starship/Helix)
#                       are unaffected — they reinstall on a version-pin bump.
#   -Reinstall          wipe the cloned repo + chezmoi config first, then run the
```

- [ ] **Step 3: Static verify**

Run:
```bash
grep -n 'ForceInstaller' bootstrap.ps1
file bootstrap.ps1
git diff --check
```
Expected: two `ForceInstaller` hits (param + comment); `file` says `UTF-8 Unicode (with BOM) text` (no `CRLF`); `git diff --check` prints nothing.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): add -ForceInstaller flag to bootstrap.ps1"
```

---

### Task 2: Add the installer engine (`$InstallerTools` + `Test-InstallerPresent` + `Install-InstallerTool`)

**Files:**
- Modify: `bootstrap.ps1` (manifest after `$PortableTools` ~line 161; functions before `Invoke-ToolInstall` ~line 435)

- [ ] **Step 1: Add the `$InstallerTools` manifest after `$PortableTools`**

Find the end of the `$PortableTools` array and the start of the REINSTALL section (around lines 160-164):

```powershell
    }
)

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + chezmoi config, then let the
```

Replace with (inserts the manifest between them):

```powershell
    }
)

# Installer-layout tools — apps that publish a silent, admin-free installer (.exe)
# instead of a portable zip. Unlike $PortableTools these are NOT version-pinned:
# we resolve the LATEST GitHub release at run time (the app self-updates after),
# verify the download against the GitHub API's per-asset sha256 'digest', run the
# installer silently PER-USER (no admin), and add NOTHING to PATH (GUI apps create
# their own Start-menu shortcut). Presence is detected via the Uninstall registry
# (DisplayName), so a manual uninstall makes the next bootstrap reinstall. Force a
# reinstall with -ForceInstaller.
$InstallerTools = @(
    @{
        Name       = "Obsidian"
        Repo       = "obsidianmd/obsidian-releases"  # GitHub owner/repo for LATEST
        AssetMatch = "Obsidian-*.exe"                # selects the Windows installer asset
        SilentArgs = "/S"                            # NSIS per-user silent (NO /allusers -> no admin)
        DetectName = "Obsidian*"                      # HKCU/HKLM Uninstall DisplayName glob
    }
)

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + chezmoi config, then let the
```

- [ ] **Step 2: Add the two functions immediately before `function Invoke-ToolInstall {`**

Find (around line 433-435 — the end of `Install-PortableTool` and the start of `Invoke-ToolInstall`):

```powershell
}

function Invoke-ToolInstall {
```

Replace with (inserts both new functions between them):

```powershell
}

# True if an app with a matching Uninstall-registry DisplayName is installed —
# per-user (HKCU) or machine-wide (HKLM / WOW6432Node). Path-independent presence
# check; a Control-Panel uninstall removes the key, so the next bootstrap reinstalls.
function Test-InstallerPresent {
    param([string]$DisplayName)
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $hit = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like $DisplayName }
        if ($hit) { return $true }
    }
    return $false
}

# Install a silent, admin-free .exe installer at its LATEST GitHub release. NOT
# version-pinned (app self-updates after); verified against the API 'digest'.
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

    # Resolve the latest release. $env:GITHUB_TOKEN (already used for the private-repo
    # clone) lifts the 60-req/hr anonymous API rate limit. A User-Agent is required
    # by the GitHub API.
    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }

    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
            -Headers $headers -UseBasicParsing
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
    $asset  = $assets[0]
    $tmpExe = Join-Path $env:TEMP "ws-$($Tool.Name)-installer.exe"

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpExe -UseBasicParsing
    } catch {
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    try {
        # Verify against the API-reported sha256 digest. Mismatch is a HARD fail
        # (corruption/tamper); a missing digest warns but proceeds (HTTPS + GitHub).
        # NOTE: Write-Fail calls exit 1, so the temp file is removed BEFORE it (a
        # finally block would NOT run on exit) — mirrors Install-PortableTool.
        if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
            $expected = $asset.digest.Substring(7).ToLower()
            $actual   = (Get-FileHash -Algorithm SHA256 -Path $tmpExe).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
                Write-Fail @"
$($Tool.Name) sha256 mismatch — refusing to install.
  expected: $expected
  actual:   $actual
The GitHub-reported digest doesn't match the download (corrupted or tampered).
"@
            }
        } else {
            Write-Warn "$($Tool.Name): GitHub published no sha256 digest for $($asset.name) — skipping hash verification."
        }

        # Silent, per-user install. No Add-ToUserPath — GUI apps make their own
        # Start-menu shortcut and self-update from here.
        $proc = Start-Process -FilePath $tmpExe -ArgumentList $Tool.SilentArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warn "$($Tool.Name) installer exited with code $($proc.ExitCode) — verify it installed."
        } else {
            Write-Ok "$($Tool.Name) installed ($($release.tag_name))"
        }
    } finally {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ToolInstall {
```

- [ ] **Step 3: Static verify**

Run:
```bash
grep -n 'InstallerTools\|Install-InstallerTool\|Test-InstallerPresent' bootstrap.ps1
file bootstrap.ps1
git diff --check
```
Expected: the manifest, both function definitions, and (later, in Task 3) the loop reference the symbols; `file` reports `with BOM` (no `CRLF`); `git diff --check` is clean. If `pwsh` is available, run the optional parse-check from the "Testing reality" section — expect `parse-ok`.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): add installer-layout tool engine + Obsidian manifest"
```

---

### Task 3: Wire the installer loop into `Invoke-ToolInstall`

**Files:**
- Modify: `bootstrap.ps1` (`Invoke-ToolInstall` body ~lines 437, 446)

- [ ] **Step 1: Run the installer loop after the portable loop**

Find (around line 446):

```powershell
    Install-Chezmoi
    foreach ($tool in $PortableTools) { Install-PortableTool -Tool $tool }
```

Replace with:

```powershell
    Install-Chezmoi
    foreach ($tool in $PortableTools) { Install-PortableTool -Tool $tool }
    foreach ($tool in $InstallerTools) { Install-InstallerTool -Tool $tool }
```

- [ ] **Step 2: Mention installer tools in the skip message**

Find (around line 437):

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix are on PATH"
```

Replace with:

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix on PATH; Obsidian not installed"
```

- [ ] **Step 3: Static verify**

Run:
```bash
grep -n 'Install-InstallerTool -Tool\|Obsidian not installed' bootstrap.ps1
file bootstrap.ps1
git diff --check
```
Expected: the loop line and the updated skip message are present; `file` reports `with BOM`; `git diff --check` clean.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): run installer-tool loop in Invoke-ToolInstall"
```

---

### Task 4: Annotate Obsidian in the manual app list

**Files:**
- Modify: `docs/windows/application_list.md` (line 5)

- [ ] **Step 1: Mark Obsidian as auto-installed**

Find:

```
- Obsidian / Notion / Typora
```

Replace with:

```
- Obsidian *(auto-installed by `bootstrap.ps1`)* / Notion / Typora
```

(Keeps the file a complete inventory — per the spec, annotate rather than delete, since `bootstrap.ps1` prints this list verbatim as a setup checklist.)

- [ ] **Step 2: Verify**

Run:
```bash
grep -n 'Obsidian' docs/windows/application_list.md
```
Expected: the annotated line.

- [ ] **Step 3: Commit**

```bash
git add docs/windows/application_list.md
git commit -m "docs(windows): mark Obsidian as auto-installed in app list"
```

---

### Task 5: Update README.html (user-facing surface)

**Files:**
- Modify: `README.html` (§setup-windows install list ~line 1933; flags block ~line 2010; no-elevation note ~line 2057; troubleshooting ~line 3290; §adding — locate by grep)

- [ ] **Step 1: Add Obsidian to the "What the script installs" list**

Find (around lines 1933-1939, the Helix `<li>` and the closing `</ul>`):

```html
                        <li>
                            <strong>Helix</strong> (<code>hx</code>) &mdash;
                            pinned, sha256-verified portable <code>.zip</code>
                            into <code>%LOCALAPPDATA%\workstation\helix</code>
                            (binary + bundled runtime). The git/chezmoi editor.
                        </li>
                    </ul>
```

Replace with:

```html
                        <li>
                            <strong>Helix</strong> (<code>hx</code>) &mdash;
                            pinned, sha256-verified portable <code>.zip</code>
                            into <code>%LOCALAPPDATA%\workstation\helix</code>
                            (binary + bundled runtime). The git/chezmoi editor.
                        </li>
                        <li>
                            <strong>Obsidian</strong> &mdash; silent, per-user
                            install of its <code>.exe</code> (no portable
                            <code>.zip</code> exists). Unlike the pinned tools
                            above it installs the <strong>latest</strong> GitHub
                            release (Obsidian self-updates after) and is verified
                            against the GitHub API&rsquo;s sha256 digest. Detected
                            via the Uninstall registry; re-run with
                            <code>-ForceInstaller</code>. Not added to
                            <code>PATH</code> (it&rsquo;s a GUI app).
                        </li>
                    </ul>
```

- [ ] **Step 2: Add `-ForceInstaller` to the flags example block**

Find (around lines 2008-2010):

```html
.\bootstrap.ps1 -SkipToolInstall                 # chezmoi/WezTerm/Starship/Helix already on PATH
.\bootstrap.ps1 -SkipChezmoi                     # clone + install but don&rsquo;t deploy dotfiles
.\bootstrap.ps1 -SkipKeyGen                      # skip the SSH-key prompt</code></pre>
```

Replace with:

```html
.\bootstrap.ps1 -SkipToolInstall                 # chezmoi/WezTerm/Starship/Helix already on PATH
.\bootstrap.ps1 -SkipChezmoi                     # clone + install but don&rsquo;t deploy dotfiles
.\bootstrap.ps1 -SkipKeyGen                      # skip the SSH-key prompt
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian) even if present</code></pre>
```

- [ ] **Step 3: Note the installer class in the no-elevation paragraph**

Find (around lines 2057-2061):

```html
                    <p class="note-row">
                        <strong>No elevation anywhere in this flow.</strong>
                        Pass <code>-SkipToolInstall</code> to skip the
                        chezmoi/WezTerm/Starship/Helix installs entirely (assumes
                        they&rsquo;re already on PATH). The diagram is a
```

Replace with:

```html
                    <p class="note-row">
                        <strong>No elevation anywhere in this flow.</strong>
                        Pass <code>-SkipToolInstall</code> to skip the
                        chezmoi/WezTerm/Starship/Helix installs <em>and</em> the
                        installer-class apps (Obsidian) entirely (assumes
                        they&rsquo;re already present). Obsidian installs silently
                        per-user via its own <code>.exe</code> at the latest
                        release; pass <code>-ForceInstaller</code> to reinstall it
                        even when already present. The diagram is a
```

- [ ] **Step 4: Note installer digest verification in the sha256 troubleshooting entry**

Find (around lines 3289-3297):

```html
                            <p>
                                WezTerm/Starship/Helix are pinned to a specific version
                                <em>and</em> sha256 in
                                <code>$PortableTools</code> inside
                                <code>bootstrap.ps1</code>. A mismatch means the
                                pinned hash is stale (upstream re-published the
                                asset) or the download was corrupted/tampered.
                                The script refuses to install an unverified
                                binary.
                            </p>
```

Replace with:

```html
                            <p>
                                WezTerm/Starship/Helix are pinned to a specific version
                                <em>and</em> sha256 in
                                <code>$PortableTools</code> inside
                                <code>bootstrap.ps1</code>. A mismatch means the
                                pinned hash is stale (upstream re-published the
                                asset) or the download was corrupted/tampered.
                                The script refuses to install an unverified
                                binary. Installer-class tools
                                (<code>$InstallerTools</code>, e.g. Obsidian) are
                                <em>not</em> pinned &mdash; they verify against the
                                GitHub API&rsquo;s sha256 <code>digest</code> for
                                the latest asset, and the same hard-fail applies on
                                a mismatch.
                            </p>
```

- [ ] **Step 5: Add an installer-tool note to the §adding walkthrough**

Locate the section:
```bash
grep -n 'id="adding"' README.html
```
Read the surrounding subsection that describes adding a **Windows** tool (it discusses `$PortableTools`). At the end of that Windows paragraph/list item, add a sentence matching the surrounding markup. The content to add:

> For an app that ships only a silent installer (no portable zip), add an entry to `$InstallerTools` instead — `Name`, `Repo` (GitHub `owner/repo`), `AssetMatch` (a glob picking the Windows `.exe`), `SilentArgs` (e.g. `/S`), and `DetectName` (an Uninstall-registry `DisplayName` glob). It installs the latest release, verifies the API digest, and adds nothing to PATH.

Wrap it as a `<p>` (or `<li>`) using the same tag style as its neighbors (use `<code>` for the literals). If §adding does not enumerate Windows tools at all, skip this step (the install-list `<li>` from Step 1 already documents it).

- [ ] **Step 6: Verify**

Run:
```bash
grep -n 'ForceInstaller\|InstallerTools\|Obsidian' README.html
git diff --check
```
Expected: the new install-list `<li>`, the flags line, the no-elevation note, and the troubleshooting note all reference the additions; `git diff --check` clean.

- [ ] **Step 7: Commit**

```bash
git add README.html
git commit -m "docs(readme): document installer-class tools + Obsidian + -ForceInstaller"
```

---

### Task 6: Update CLAUDE.md invariant + file-care.md

**Files:**
- Modify: `CLAUDE.md` (the "Windows tool installs are admin-free binary/portable downloads" invariant bullet)
- Modify: `docs/claude/file-care.md` (line 34, the `bootstrap.ps1` entry)

- [ ] **Step 1: Extend the Windows-installs invariant in CLAUDE.md**

Find the start of the bullet:

```
- **Windows tool installs are admin-free binary/portable downloads under `%LOCALAPPDATA%\workstation`** (no Chocolatey).
```

Append the following sentences to the END of that same bullet (after its final sentence, before the next `- **` bullet). Keep it on the bullet:

```
  **There is also an installer class (`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian)** for apps that ship only a silent `.exe` (no portable zip): `Install-InstallerTool` resolves the **LATEST** GitHub release (NOT version-pinned — the app self-updates after the seed; so **no `versions.mk`/`$PortableTools`-style pin**), verifies the download against the GitHub API's per-asset sha256 `digest` (hard-fail on mismatch, warn+proceed if absent), runs it silently **per-user** (`/S`, never `/allusers` → no admin), and **adds nothing to PATH** (GUI apps make their own shortcut). Idempotency is by **Uninstall-registry `DisplayName`** via `Test-InstallerPresent` (HKCU + HKLM/WOW6432Node), not a version stamp — a manual uninstall makes the next run reinstall. `-ForceInstaller` forces reinstall; `-SkipToolInstall` skips installer tools too.
```

- [ ] **Step 2: Extend the `bootstrap.ps1` entry in file-care.md**

Find the end of line 34 (the `bootstrap.ps1` entry ends with):

```
All four land under `%LOCALAPPDATA%\workstation` on the User PATH; the script needs no admin.
```

Replace with:

```
All four land under `%LOCALAPPDATA%\workstation` on the User PATH; the script needs no admin. Separately, `bootstrap.ps1` carries an **`$InstallerTools` manifest** (installer-layout class, e.g. Obsidian) — **unpinned/LATEST** (resolved via the GitHub `releases/latest` API; the app self-updates after, so no `Version`/`Sha256` pin), verified against the API's per-asset sha256 `digest`, installed silently per-user (`/S`, no admin), **not** added to PATH, and detected via the Uninstall registry (`Test-InstallerPresent`) rather than a stamp. `-ForceInstaller` forces reinstall.
```

- [ ] **Step 3: Verify**

Run:
```bash
grep -n 'InstallerTools\|ForceInstaller' CLAUDE.md docs/claude/file-care.md
```
Expected: hits in both files.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/claude/file-care.md
git commit -m "docs(claude): document installer-class tools in invariants + file-care"
```

---

### Task 7: Append a CLAUDE_CHANGELOG.md row

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append a row to the table)

- [ ] **Step 1: Append the row**

Add a new table row at the end of the changelog table (match the existing `| change | README? | notes |` column structure — confirm the exact columns by reading the last existing row):

```
| Added an installer-layout tool class to `bootstrap.ps1` (`$InstallerTools` + `Install-InstallerTool`/`Test-InstallerPresent`, new `-ForceInstaller` flag) and used it to auto-install **Obsidian** on Windows | **Yes** | New `<li>` under setup-windows ("What the script installs") describing the installer class: LATEST GitHub release (Obsidian self-updates after the seed — not version-pinned), verified against the GitHub API's per-asset sha256 `digest`, silent per-user `/S` install (no admin), not added to PATH, detected via the Uninstall registry. Added `-ForceInstaller` to the flags block + no-elevation note, and a digest-verify note to the sha256 troubleshooting entry. `docs/windows/application_list.md` annotates Obsidian as auto-installed (kept in the list — bootstrap prints it as a checklist). CLAUDE.md's Windows-installs invariant + file-care.md extended for the new class. |
```

- [ ] **Step 2: Verify**

Run:
```bash
tail -n 3 CLAUDE_CHANGELOG.md
git diff --check
```
Expected: the new row present; clean.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE_CHANGELOG.md
git commit -m "docs(changelog): record Windows installer-class tools + Obsidian"
```

---

### Task 8: Final verification (static sweep + Windows-host smoke test)

**Files:** none (verification only)

- [ ] **Step 1: Full static sweep on the dev host**

Run:
```bash
file bootstrap.ps1
git diff --check main..HEAD
grep -n 'ForceInstaller\|InstallerTools\|Install-InstallerTool\|Test-InstallerPresent' bootstrap.ps1
```
Expected: `bootstrap.ps1` → `UTF-8 Unicode (with BOM) text` (NO `CRLF`); `git diff --check` clean; all four symbols present (manifest, two functions, the param/flag).

- [ ] **Step 2: Optional parse-check (if `pwsh`/PowerShell available anywhere)**

Run:
```bash
pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile('bootstrap.ps1',[ref]$null,[ref]$errs); if($errs){$errs;exit 1}else{'parse-ok'}"
```
Expected: `parse-ok` (no parser errors).

- [ ] **Step 3: Windows-host smoke test (the real behavioral verification)**

On a Windows host with the branch checked out, run these and confirm each expectation:

1. **Fresh install (Obsidian absent):**
   ```powershell
   .\bootstrap.ps1 -SkipKeyGen -SkipChezmoi
   ```
   Expected: log shows `Installing Obsidian (latest, installer)...` then `✓ Obsidian installed (vX.Y.Z)`; no UAC/elevation prompt; the silent install does not pop Obsidian's window during bootstrap (if it does, note it — cosmetic only).

2. **Confirm presence detection:**
   ```powershell
   Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
     Where-Object DisplayName -like 'Obsidian*' | Select-Object DisplayName, DisplayVersion
   ```
   Expected: one row with `DisplayName` like `Obsidian` — confirms the `DetectName = "Obsidian*"` glob matches the real registry entry.

3. **Idempotent re-run (no reinstall):**
   ```powershell
   .\bootstrap.ps1 -SkipKeyGen -SkipChezmoi
   ```
   Expected: `✓ Obsidian already installed (use -ForceInstaller to reinstall)`; no download.

4. **Force reinstall:**
   ```powershell
   .\bootstrap.ps1 -SkipKeyGen -SkipChezmoi -ForceInstaller
   ```
   Expected: re-downloads + re-runs the installer (`Installing Obsidian (latest, installer)...`), and portable tools (WezTerm/Starship/Helix) report `already installed` (untouched by `-ForceInstaller`).

5. **Skip path:**
   ```powershell
   .\bootstrap.ps1 -SkipToolInstall -SkipKeyGen -SkipChezmoi
   ```
   Expected: `Tool install skipped ... Obsidian not installed`; no Obsidian download.

- [ ] **Step 4: Finish the branch**

Invoke the `superpowers:finishing-a-development-branch` skill to choose how to integrate (merge to `main` / open a PR / keep the branch). Do this only after Step 3 passes (or, if no Windows host is available now, after the static sweep passes and with an explicit note that the on-host smoke test is still pending).

---

## Self-Review

**Spec coverage** (each spec Design section → task):
- §1 separate `$InstallerTools` + `Install-InstallerTool` → Task 2 ✓
- §2 LATEST resolve + API-digest verify + silent run + no PATH + optional token → Task 2 ✓
- §3 registry presence detection (`Test-InstallerPresent`, HKCU+HKLM) → Task 2 ✓
- §4 `-ForceInstaller` flag → Task 1 (param/doc) + Task 2 (gate) + Task 3 (skip msg) ✓
- §5 wire into `Invoke-ToolInstall` → Task 3 ✓
- §6 repo-convention follow-through: BOM (every code task verify) ✓; application_list.md → Task 4 ✓; README → Task 5 ✓; CLAUDE.md + file-care.md → Task 6 ✓; CLAUDE_CHANGELOG.md → Task 7 ✓
- Spec Risks/verify list → Task 8 Step 3 (BOM, registry DisplayName, `/S` no-admin, auto-launch, digest-present, AssetMatch uniqueness via the `>1` warn coded in Task 2, rate limit/token, `-ForceInstaller`, `-SkipToolInstall`) ✓

**Placeholder scan:** No TBD/TODO; all code blocks are complete; the only "locate it" step (Task 5 Step 5, §adding) gives exact content + a fallback to skip — acceptable because the target HTML is unknown and the install-list `<li>` already covers the user-facing need.

**Type/name consistency:** `$InstallerTools` (manifest) ↔ `foreach ($tool in $InstallerTools)` (Task 3); `Install-InstallerTool -Tool` ↔ `function Install-InstallerTool { param([hashtable]$Tool) }`; `Test-InstallerPresent -DisplayName` ↔ `function Test-InstallerPresent { param([string]$DisplayName) }`; entry keys `Name/Repo/AssetMatch/SilentArgs/DetectName` ↔ used as `$Tool.Name/$Tool.Repo/$Tool.AssetMatch/$Tool.SilentArgs/$Tool.DetectName`; `$ForceInstaller` (param) ↔ `-not $ForceInstaller` (gate). Consistent.
