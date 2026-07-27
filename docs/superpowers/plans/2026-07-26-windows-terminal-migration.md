# Windows Terminal Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire Warp and make Windows Terminal the single managed Windows terminal — seeded by `bootstrap.ps1`, per-host SSH+Zellij profiles regenerated from `hosts.conf` as a JSON fragment, durable WezTerm/Warp-era behaviors carried into the tracked `settings.json`.

**Architecture:** Whole-file static `settings.json` (existing sync-from-host model) + a bootstrap-regenerated JSON fragment (`Fragments\workstation\hosts.json`) for all `hosts.conf`-derived profiles; Warp retirement mirrors the #102 WezTerm pattern (removal + self-healing `Invoke-WarpRetire` + doc/invariant sweep).

**Tech Stack:** PowerShell 5.1 (`bootstrap.ps1`, BOM required), chezmoi (source dir `chezmoi/`, target-path semantics), Windows Terminal 1.24 stable schema, zsh/bash rc templates, `make lint` harness.

**Spec:** `docs/superpowers/specs/2026-07-26-windows-terminal-migration-design.md`

## Global Constraints

- `bootstrap.ps1` keeps its UTF-8 **BOM**; verify after every edit (`check-invariants.sh` enforces).
- All PowerShell must be **PS 5.1-safe**: no `` `u{} `` escapes (use `[char]0x…`), no `??`, no ternary; `ConvertTo-Json -InputObject` (never pipe — single-element array unwrap bug).
- WT `settings.json` + fragment: LF, UTF-8, **no BOM**, mode `100644`; preserve WT's `"key": `-trailing-space quirk in the tracked file; do NOT reformat untouched lines.
- The load-bearing SSH string is verbatim: `ssh -t <user>@<ip> zellij attach --create main`.
- Never delete anything Warp the user created: only `workstation-*.toml` Tab Configs and chezmoi-deployed files are removed; the fragment generator wipes only `*.json` under `Fragments\workstation\`.
- No new `bootstrap.ps1` `param()` flags (completion-parity check stays untouched). Reuse `-SkipToolInstall` / `-ForceInstaller`.
- Parity pairs change in the same commit: `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl`; `manage-hosts.sh` ↔ `manage-hosts.ps1`.
- Every task ends with `make -C makefile lint MODE=prod` green (add `ps-lint` when `.ps1` changed; it soft-skips without pwsh locally — CI enforces).
- User-facing changes → `README.html` in the same PR + a `CLAUDE_CHANGELOG.md` row (Task 9/10).
- No per-host GPU/rendering tuning anywhere (twice-reverted historical regression).
- Commits go on branch `feat/windows-terminal-migration`; PR at the end; commit messages end with the Co-Authored-By/Claude-Session trailer used in this repo.

---

### Task 0: Branch

**Files:** none

- [ ] **Step 1:** `git -C ~/.local/share/chezmoi switch -c feat/windows-terminal-migration` (from up-to-date `main`).
- [ ] **Step 2:** `git status` → clean tree on the new branch (the two `docs/superpowers/{specs,plans}` files from the design session may be present — commit them first: `git add docs/superpowers && git commit -m "docs(specs): windows-terminal migration design + plan"`).

---

### Task 1: Elevate the tracked Windows Terminal `settings.json`

**Files:**
- Modify: `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json` (251 lines)

**Interfaces:**
- Produces: `profiles.defaults` carrying font/cursor/history/bell/padding; `disabledProfileSources`; `firstWindowPreference`; `newTabMenu` SSH-hosts folder matching profile names `SSH: .*`; actions/keybindings ids `User.splitPane.down`, `User.splitPane.right`, `User.moveFocus.{left,right,up,down}`, `User.togglePaneZoom`, `User.adjustFontSize.{inc,dec}`, `User.resetFontSize`. Task 3's generated profiles rely on the `SSH: ` name prefix and on inheriting `profiles.defaults`.

- [ ] **Step 1: Expand `profiles.defaults`** (currently `{ "colorScheme": "Catppuccin Mocha" }`):

```json
"defaults": {
    "antialiasingMode": "grayscale",
    "bellStyle": ["audible", "taskbar"],
    "colorScheme": "Catppuccin Mocha",
    "cursorShape": "bar",
    "font": { "face": "JetBrainsMono NFM", "size": 10.5 },
    "historySize": 100000,
    "padding": "8, 8, 8, 8",
    "useAcrylic": false
}
```

Then delete the now-duplicated per-profile keys from the **Nushell** profile (`font`, `cursorShape`, `historySize`, `padding`, `useAcrylic`, `antialiasingMode` — keep `commandline`, `guid`, `name`, `startingDirectory`, `icon`/`tabTitle` if present). Leave `Windows PowerShell (Admin)`'s explicit Cascadia Mono font override alone.

- [ ] **Step 2: Prune stale profiles.** Delete the two hand-added SSH profile objects `atc-cache-dev09` (guid `{379331ae-…}`) and `atc-cache-dev10` (guid `{e3f008a6-…}`) — superseded by Task 3's generated fragment. Delete the **second** duplicate `AlmaLinux-9` WSL profile object (keep the first `source: "Microsoft.WSL"` entry). `defaultProfile` (`{a1337c9f-08c3-5ee9-ad61-dcc130796eb6}`, Nushell) is untouched.

- [ ] **Step 3: Add root-level globals** (alongside `copyOnSelect` etc.):

```json
"disabledProfileSources": ["Windows.Terminal.SSH"],
"firstWindowPreference": "persistedWindowLayout",
```

- [ ] **Step 4: Replace `newTabMenu`** (currently a bare `remainingProfiles`):

```json
"newTabMenu": [
    {
        "type": "folder",
        "name": "SSH hosts",
        "icon": "",
        "allowEmpty": false,
        "entries": [ { "type": "matchProfiles", "name": "SSH: .*" } ]
    },
    { "type": "remainingProfiles" }
]
```

(If on-machine testing shows `matchProfiles.name` is not regex-matched on stable 1.24, switch the entry to match on the fragment `source` value observed in Task 11 — record whichever key worked in `docs/claude/file-care.md`.)

- [ ] **Step 5: Extend `actions` + `keybindings`** (new-style split arrays; keep the four existing actions and their ids; edit the existing splitPane action in place):
  - Existing splitPane action: change `"split": "auto"` → `"split": "down"`; keep its id and `splitMode: "duplicate"`; keep its `alt+shift+d` keybinding.
  - Append actions:

```json
{ "command": { "action": "splitPane", "split": "right", "splitMode": "duplicate" }, "id": "User.splitPane.right" },
{ "command": { "action": "moveFocus", "direction": "left" }, "id": "User.moveFocus.left" },
{ "command": { "action": "moveFocus", "direction": "right" }, "id": "User.moveFocus.right" },
{ "command": { "action": "moveFocus", "direction": "up" }, "id": "User.moveFocus.up" },
{ "command": { "action": "moveFocus", "direction": "down" }, "id": "User.moveFocus.down" },
{ "command": "togglePaneZoom", "id": "User.togglePaneZoom" },
{ "command": { "action": "adjustFontSize", "delta": 1 }, "id": "User.adjustFontSize.inc" },
{ "command": { "action": "adjustFontSize", "delta": -1 }, "id": "User.adjustFontSize.dec" },
{ "command": "resetFontSize", "id": "User.resetFontSize" }
```

  - Append keybindings:

```json
{ "id": "User.splitPane.right", "keys": "alt+shift+r" },
{ "id": "User.moveFocus.left", "keys": "alt+shift+left" },
{ "id": "User.moveFocus.right", "keys": "alt+shift+right" },
{ "id": "User.moveFocus.up", "keys": "alt+shift+up" },
{ "id": "User.moveFocus.down", "keys": "alt+shift+down" },
{ "id": "User.togglePaneZoom", "keys": "ctrl+shift+z" },
{ "id": "User.adjustFontSize.inc", "keys": "ctrl+=" },
{ "id": "User.adjustFontSize.dec", "keys": "ctrl+-" },
{ "id": "User.resetFontSize", "keys": "ctrl+0" }
```

  Deliberate: `alt+shift+arrows` shadows WT's default `resizePane` bindings — pane resize stays available via the command palette / mouse drag (Zellij owns resize on remote anyway). Documented in Task 9's keybind table.

- [ ] **Step 6: Verify JSON validity + encoding:**

Run: `python3 -c "import json,sys; json.load(open('chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json')); print('valid')"`
Expected: `valid`
Run: `file chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`
Expected: no "CRLF", no "BOM".
Run: `jq -r '[.profiles.list[].name] | length' <same path>` → **8** (was 11); `jq -r '.disabledProfileSources[0]'` → `Windows.Terminal.SSH`.

- [ ] **Step 7: Commit** — `git add … && git commit -m "feat(windows-terminal): defaults/keybinds/newTabMenu elevation — WezTerm/Warp behaviors carried over"`.

---

### Task 2: `Install-WindowsTerminal` seed + Doctor/CheckForUpdates entries

**Files:**
- Modify: `bootstrap.ps1` — new function near `Install-Warp` (lines ~1187), call in `Invoke-ToolInstall` (~1229), Doctor "Installer apps" block (~2072), `Invoke-CheckForUpdates` (~2226)

**Interfaces:**
- Produces: `Install-WindowsTerminal` (no params; honors `$ForceInstaller`); detection expression `(Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) -or (Get-Command wt.exe -ErrorAction SilentlyContinue)` — reused by Tasks 3–4 and Doctor.

- [ ] **Step 1: Add the function** (best-effort, never `Write-Fail` — the `Install-Warp` posture):

```powershell
function Install-WindowsTerminal {
    # Evergreen MSIX seed: per-user by design (no admin), Store-serviced thereafter.
    # No versions.mk pin — same latest-release model as the installer-class apps.
    $present = (Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) -or
               (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if ($present -and -not $ForceInstaller) {
        Write-Ok "Windows Terminal already installed (self-updates via Microsoft Store)"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget not available — install Windows Terminal from the Microsoft Store: https://aka.ms/terminal"
        return
    }
    $wingetArgs = @("install", "--id", "Microsoft.WindowsTerminal", "--exact", "--silent",
                    "--accept-source-agreements", "--accept-package-agreements")
    if ($ForceInstaller) { $wingetArgs += "--force" }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & winget @wingetArgs
    $ErrorActionPreference = $prevEap
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Windows Terminal installed (self-updates via Microsoft Store)"
    } else {
        Write-Warn "winget could not install Windows Terminal (exit $LASTEXITCODE) — install from the Microsoft Store: https://aka.ms/terminal"
    }
}
```

- [ ] **Step 2: Wire it** in `Invoke-ToolInstall` where `Install-Warp` is called today (that call is removed in Task 4; this task adds `Install-WindowsTerminal` immediately after it so the tree always builds).
- [ ] **Step 3: Doctor** — in the "Installer apps + extras" block, add (modeled on the Warp lines, which Task 4 removes):

```powershell
$wtPkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
if ($wtPkg) { Write-Ok "Windows Terminal $($wtPkg.Version) installed (self-updates via Microsoft Store)" }
elseif (Get-Command wt.exe -ErrorAction SilentlyContinue) { Write-Ok "Windows Terminal installed (wt.exe on PATH)" }
else { Write-Bad "Windows Terminal not installed — re-run .\bootstrap.ps1 or: winget install Microsoft.WindowsTerminal" }
```

- [ ] **Step 4: CheckForUpdates** — under the installer-apps heading add the matching one-liner (`Write-Ok "Windows Terminal … (self-updates via Store; check with: winget upgrade Microsoft.WindowsTerminal)"` / `Write-Warn` when absent).
- [ ] **Step 5: Verify** — BOM intact: `head -c 3 bootstrap.ps1 | xxd` → `efbbbf`; `make -C makefile ps-lint` (or note soft-skip); `make -C makefile lint MODE=prod`.
- [ ] **Step 6: Commit** — `feat(windows-terminal): evergreen winget seed + doctor/update-check entries`.

---

### Task 3: `New-Uuid5` + `Invoke-WindowsTerminalFragments` (the `hosts.conf` generator)

**Files:**
- Modify: `bootstrap.ps1` — helper near the other small utilities (~line 678, next to `Remove-FromUserPath`); new section banner + function replacing the `Invoke-WarpTabConfigs` region (~1440); MAIN call at the old `Invoke-WarpTabConfigs` slot (~2328); Doctor fragment check near the old Warp tab-config check (~2161)

**Interfaces:**
- Consumes: detection expression from Task 2; existing `$hostsFile` resolution — copy the exact expression from `Invoke-WarpTabConfigs` (lines ~1502–1514) before Task 4 deletes it.
- Produces: `New-Uuid5 -Namespace <Guid> -Name <string> -> Guid` (WT UTF-16LE convention); fragment file `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\workstation\hosts.json` with profile names `SSH: <host>` (Task 1's `newTabMenu` matcher and Task 9's docs depend on this prefix).

- [ ] **Step 1: Add `New-Uuid5`** (RFC 4122 v5 over SHA-1; WT's documented convention hashes the name as UTF-16LE):

```powershell
function New-Uuid5 {
    # RFC 4122 v5 GUID. Windows Terminal's fragment convention: name bytes are UTF-16LE
    # (namespace {f65ddb7e-706b-4499-8a50-40313caf510a} -> app -> profile name).
    param([Parameter(Mandatory)][Guid]$Namespace, [Parameter(Mandatory)][string]$Name)
    $ns = $Namespace.ToByteArray()
    [Array]::Reverse($ns, 0, 4); [Array]::Reverse($ns, 4, 2); [Array]::Reverse($ns, 6, 2)  # to big-endian
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($Name)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($ns + $nameBytes) } finally { $sha1.Dispose() }
    $b = $hash[0..15]
    $b[6] = [byte](($b[6] -band 0x0F) -bor 0x50)   # version 5
    $b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)   # RFC 4122 variant
    [Array]::Reverse($b, 0, 4); [Array]::Reverse($b, 4, 2); [Array]::Reverse($b, 6, 2)     # back to GUID layout
    return [Guid]::new([byte[]]$b)
}
```

- [ ] **Step 2: Sanity-test the helper** before wiring (PS 5.1 semantics on the Windows host later; structural check now on Linux `pwsh` if present, else defer to Task 11):

Run (pwsh): `New-Uuid5 -Namespace ([Guid]"6ba7b810-9dad-11d1-80b4-00c04fd430c8") -Name "www.example.org"` — note WT uses UTF-16LE, so this differs from RFC's UTF-8 vector; assert instead: same inputs → same output across two calls, version nibble `5`, variant in `89ab`.

- [ ] **Step 3: Add the generator** (same warn-and-continue + prefix-scoped-wipe posture as `Invoke-WarpTabConfigs`; reuse its `$hostsFile` expression and hosts.conf parse loop verbatim):

```powershell
function Invoke-WindowsTerminalFragments {
    try {
        $present = (Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) -or
                   (Get-Command wt.exe -ErrorAction SilentlyContinue)
        if (-not $present) {
            Write-Warn "Windows Terminal not detected — skipping SSH profile fragment generation."
            return
        }
        $fragDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\workstation"
        if (-not (Test-Path $fragDir)) { New-Item -ItemType Directory -Path $fragDir -Force | Out-Null }
        # The 'workstation' app dir IS the managed namespace: wipe only *.json inside it.
        Get-ChildItem -Path $fragDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force

        $hostsFile = <same expression Invoke-WarpTabConfigs used>
        if (-not (Test-Path $hostsFile)) {
            Write-Warn "hosts.conf not found at $hostsFile — no Windows Terminal SSH profiles generated."
            return
        }
        $appNs = New-Uuid5 -Namespace ([Guid]"f65ddb7e-706b-4499-8a50-40313caf510a") -Name "workstation"
        $sshIcon = [string][char]0xE839
        $profiles = @()
        foreach ($line in Get-Content $hostsFile) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
            $parts = $trimmed -split '\s+'
            if ($parts.Count -lt 4) { Write-Warn "Skipping malformed hosts.conf row: $line"; continue }
            $hostName = $parts[0]; $ip = $parts[1]; $sshUser = $parts[2]; $group = $parts[3]
            $tabColor = if ($group -eq "dev_machine") { "#a6e3a1" } else { "#94e2d5" }  # Mocha green / teal
            $profileName = "SSH: $hostName"
            $profiles += [ordered]@{
                guid        = (New-Uuid5 -Namespace $appNs -Name $profileName).ToString("B")
                name        = $profileName
                commandline = "ssh -t $sshUser@$ip zellij attach --create main"
                tabTitle    = $hostName
                tabColor    = $tabColor
                icon        = $sshIcon
            }
        }
        $json = ConvertTo-Json -InputObject ([ordered]@{ profiles = $profiles }) -Depth 5
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $fragDir "hosts.json"), $json + "`n", $utf8)
        Write-Ok "Windows Terminal SSH profiles regenerated from hosts.conf ($($profiles.Count) host(s), $fragDir) — restart Windows Terminal to pick them up"
    } catch {
        Write-Warn "Could not generate Windows Terminal SSH profile fragment: $($_.Exception.Message)"
    }
}
```

(`<same expression Invoke-WarpTabConfigs used>` — copy it literally from the current function body while it still exists; it resolves `hosts.conf` beside the script.)

- [ ] **Step 4: Wire into MAIN** at the current `Invoke-WarpTabConfigs` position (between `Invoke-StartMenuShortcuts` and `Invoke-NushellStarship`).
- [ ] **Step 5: Doctor fragment check** (replaces the Warp tab-config count in spirit; keep beside it until Task 4 removes the Warp one):

```powershell
$fragFile = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\workstation\hosts.json"
if (Test-Path $fragFile) {
    try {
        $fragCount = ((Get-Content $fragFile -Raw | ConvertFrom-Json).profiles | Measure-Object).Count
        Write-Ok "$fragCount Windows Terminal SSH profile(s) in the workstation fragment"
    } catch { Write-Warn "Windows Terminal fragment unreadable — re-run .\bootstrap.ps1" }
} else { Write-Warn "Windows Terminal SSH fragment missing — re-run .\bootstrap.ps1" }
```

- [ ] **Step 6: Verify** — BOM `efbbbf`; `make -C makefile ps-lint`; `make -C makefile lint MODE=prod`.
- [ ] **Step 7: Commit** — `feat(windows-terminal): hosts.conf -> SSH profile fragment generator (UUID5 GUIDs, prefix-scoped wipe)`.

---

### Task 4: Warp retirement in `bootstrap.ps1`

**Files:**
- Modify: `bootstrap.ps1` — remove `$WarpTool` (472–480), `Install-Warp` (1187–1215) + its `Invoke-ToolInstall` call (1229) + `-SkipToolInstall` message text (1219), `Invoke-WarpTabConfigs` (banner 1440–1443, body 1445–1541) + MAIN call (2328), Doctor Warp entries (2072–2078, 2161–2164), CheckForUpdates entry (2226–2232); rewrite header/flow comments (6, 15–16, 36, 42, 48–50, 95, 113) and epilogue (2343–2345, 2369); add `Invoke-WarpRetire` + Doctor leftover check. (Line numbers are pre-Task-2/3 references — re-locate by symbol, not number.)

**Interfaces:**
- Consumes: `Test-InstallerPresent`, `Write-Ok/Warn`, winget-presence check (existing helpers).
- Produces: `Invoke-WarpRetire` wired in MAIN next to `Invoke-WeztermRetire` (~2331); Doctor `$warpLeftovers` check.

- [ ] **Step 1: Delete** `$WarpTool`, `Install-Warp` + its call, `Invoke-WarpTabConfigs` + its MAIN call; update the `-SkipToolInstall` message to name Windows Terminal instead of Warp.
- [ ] **Step 2: Replace Doctor/CheckForUpdates Warp entries** — delete the Warp presence lines (Task 2 added the WT ones) and the Warp tab-config count (Task 3 added the fragment check).
- [ ] **Step 3: Add `Invoke-WarpRetire`** (WezTerm-retire shape: independent existence-guarded try/catch blocks, silent no-op when clean), wired in MAIN immediately after `Invoke-WeztermRetire`:

```powershell
function Invoke-WarpRetire {
    # Managed Tab Configs (prefix-scoped: user-created Tab Configs are never touched)
    try {
        $warpTabs = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
        if (Test-Path $warpTabs) {
            $managed = @(Get-ChildItem -Path $warpTabs -Filter "workstation-*.toml" -File -ErrorAction SilentlyContinue)
            if ($managed.Count -gt 0) {
                $managed | Remove-Item -Force
                Write-Ok "Warp retired: removed $($managed.Count) managed Tab Config(s)"
            }
        }
    } catch { Write-Warn "Could not remove managed Warp Tab Configs: $($_.Exception.Message)" }
    # App uninstall — best-effort, never Write-Fail; deliberately leaves %APPDATA%\warp user data alone
    try {
        if (Test-InstallerPresent -DisplayName "Warp") {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
                & winget uninstall --id Warp.Warp --silent --accept-source-agreements
                $ErrorActionPreference = $prevEap
                if ($LASTEXITCODE -eq 0) { Write-Ok "Warp retired: uninstalled via winget" }
                else { Write-Warn "winget could not uninstall Warp (exit $LASTEXITCODE) — remove via Settings > Apps if desired" }
            } else {
                Write-Warn "Warp still installed and winget unavailable — remove via Settings > Apps if desired"
            }
        }
    } catch { Write-Warn "Could not uninstall Warp: $($_.Exception.Message)" }
}
```

- [ ] **Step 4: Doctor leftover check** (mirrors `$wezLeftovers`, 2136–2146):

```powershell
$warpLeftovers = @()
if (Test-InstallerPresent -DisplayName "Warp") { $warpLeftovers += "app installed" }
$warpManagedTabs = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
if ((Test-Path $warpManagedTabs) -and
    @(Get-ChildItem -Path $warpManagedTabs -Filter "workstation-*.toml" -File -ErrorAction SilentlyContinue).Count -gt 0) {
    $warpLeftovers += "managed Tab Configs"
}
if ($warpLeftovers.Count -gt 0) {
    Write-Warn ("retired-Warp leftovers present (" + ($warpLeftovers -join ", ") + ") — re-run .\bootstrap.ps1 (the retire step removes them)")
} else { Write-Ok "no retired-Warp leftovers" }
```

- [ ] **Step 5: Rewrite prose** — header blurb/flow steps (2, 4, 5c → "windows terminal fragments", 5f gains "warp retire"), `-SkipToolInstall`/`-Doctor` doc strings, epilogue: "Windows Terminal is the terminal — pick a host from the SSH hosts folder in the new-tab dropdown; Nushell is the default profile. Restart Windows Terminal if it was running (fragments are read at launch)."
- [ ] **Step 6: Grep gate:** `rg -i warp bootstrap.ps1` → only `Invoke-WarpRetire`/`$warpLeftovers`/retire-comment hits remain (plus `Invoke-WeztermRetire` references if any line mentions both).
- [ ] **Step 7: Verify** — BOM `efbbbf`; `make -C makefile ps-lint`; `make -C makefile lint MODE=prod`.
- [ ] **Step 8: Commit** — `feat(windows-terminal): complete the Warp retirement — self-healing Invoke-WarpRetire + doctor leftover check`.

---

### Task 5: Remove the chezmoi-tracked Warp configs (+ `.chezmoiremove`)

**Files:**
- Delete: `chezmoi/AppData/Local/warp/Warp/config/settings.toml`, `chezmoi/AppData/Local/warp/Warp/config/keybindings.yaml`, `chezmoi/AppData/Roaming/warp/Warp/data/themes/catppuccin-mocha.yaml`
- Modify: `chezmoi/.chezmoiremove` (13 lines today)

- [ ] **Step 1:** `git rm` the three Warp source files. (No `.chezmoiignore` change — the blanket non-Windows `AppData` ignore covered them.)
- [ ] **Step 2:** Append to `chezmoi/.chezmoiremove` (target paths; Windows chezmoi removes the deployed copies; Linux has no `$HOME/AppData` → no-op). Also fix the stale comment on its line 9 ("Warp runs TERM=xterm-256color" → "the Windows terminal runs TERM=xterm-256color"):

```
# Warp retirement (2026-07): chezmoi-deployed Warp configs; user-created Warp data is not touched.
AppData/Local/warp/Warp/config/settings.toml
AppData/Local/warp/Warp/config/keybindings.yaml
AppData/Roaming/warp/Warp/data/themes/catppuccin-mocha.yaml
```

- [ ] **Step 3: Verify:** `chezmoi ignored | rg -i warp` → nothing (entries were never in ignore); `make -C makefile lint MODE=prod`.
- [ ] **Step 4: Commit** — `feat(windows-terminal): drop tracked Warp configs; .chezmoiremove heals deployed copies`.

---

### Task 6: Remove the `TERM_PROGRAM != WarpTerminal` rc guards (parity pair)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (guards at ~145–148, 165, 191, 208, 261: fzf, atuin, starship, zsh-shift-select, fzf-tab zstyles)
- Modify: `chezmoi/dot_bashrc.tmpl` (~192–195, 233–235: fzf, starship)
- Modify (comment-only): `chezmoi/dot_dircolors:23`, `chezmoi/dot_config/starship.toml:52`, `chezmoi/AppData/Roaming/nushell/config.nu.tmpl:7`

- [ ] **Step 1:** In `dot_zshrc.tmpl`, unwrap each of the five guarded blocks: delete the `[[ ${TERM_PROGRAM:-} != WarpTerminal ]] && …` / `if [[ … != WarpTerminal ]]` wrapper (and its explanatory Warp comment), keeping the guarded body unconditional. The body content itself is unchanged — this re-enables fzf, atuin, starship, shift-select, and fzf-tab under Windows Terminal (deliberate; they were suppressed only because Warp's input editor collided with them).
- [ ] **Step 2:** Same for the two `dot_bashrc.tmpl` guards — **same commit** (parity pair; the `parity-reminder.sh` hook will nudge, that's expected).
- [ ] **Step 3:** Comment sweep: dircolors "fleet runs TERM=xterm-256color (Warp)" → "(Windows Terminal)"; starship.toml chain comment `Warp → ssh → zellij → zsh` → `Windows Terminal → ssh → zellij → zsh`; config.nu.tmpl line 7 drops "the Warp compatibility Tab Config" clause.
- [ ] **Step 4: Verify:** `bash scripts/check-templates.sh` (renders both groups, zsh/bash syntax-checked); `rg -i 'warpterminal|WarpTerminal' chezmoi/` → no hits; `make -C makefile lint MODE=prod`.
- [ ] **Step 5: Commit** — `feat(windows-terminal): drop Warp TERM_PROGRAM guards — fzf/atuin/starship/shift-select/fzf-tab active again (zshrc+bashrc parity)`.

---

### Task 7: `manage-hosts` note retarget (parity pair) + `bootstrap.sh` comment sweep

**Files:**
- Modify: `scripts/manage-hosts.sh` (header 10–11; `note_warp_refresh()` 129–134; call sites 337, 347, 377, 440)
- Modify: `scripts/manage-hosts.ps1` (header 9–10; `Show-WarpRefreshNote` 144–149; call sites 289, 299, 323, 371)
- Modify: `bootstrap.sh` (comments/output at 99, 319–325, 358, 789)

- [ ] **Step 1:** Rename `note_warp_refresh` → `note_terminal_refresh`; body message: `"Windows Terminal SSH profiles (workstation fragment) pick this up on the next bootstrap.ps1 run."` Update all 4 call sites + the header comment. No flag changes.
- [ ] **Step 2:** Same in `manage-hosts.ps1`: `Show-WarpRefreshNote` → `Show-TerminalRefreshNote`, same message, 4 call sites, header — **same commit**.
- [ ] **Step 3:** `bootstrap.sh` sweep: "Warp's WSL integration" → "Windows Terminal's WSL profile"; "the Windows-side Warp Tab Configs" → "the Windows-side Windows Terminal SSH profiles (fragment)"; "opening a new Warp tab" → "opening a new Windows Terminal tab".
- [ ] **Step 4: Verify:** `file scripts/manage-hosts.sh` (LF), `git ls-files --stage scripts/manage-hosts.sh` (100755); manage-hosts.ps1 BOM intact (`head -c 3 | xxd` → `efbbbf`); `make -C makefile lint MODE=prod` (completion-parity untouched — no flags changed); `rg -i warp scripts/ bootstrap.sh` → no hits.
- [ ] **Step 5: Commit** — `feat(windows-terminal): manage-hosts refresh notes point at the WT fragment (sh+ps1 parity)`.

---

### Task 8: CLAUDE.md + `docs/claude/` sweep

**Files:**
- Modify: `CLAUDE.md` (doc-map row 38; invariants ~92–94; verification pointer ~142)
- Modify: `docs/claude/invariants.md` (~39 area), `docs/claude/file-care.md` (~35 WT entry; delete ~62 Warp entry), `docs/claude/verification.md` (~30–31)

- [ ] **Step 1: CLAUDE.md** — doc-map row: `bootstrap.ps1 / Windows + Warp` → `bootstrap.ps1 / Windows + Windows Terminal`. Replace the Warp invariant bullet (~93) with:

> **Windows Terminal is the only managed Windows terminal.** `Install-WindowsTerminal` is a best-effort evergreen MSIX seed (winget `Microsoft.WindowsTerminal`, per-user by design, Store-serviced — no `versions.mk` pin; detect via `Get-AppxPackage`/`wt.exe`). Chezmoi owns the whole `settings.json` (Store path under `AppData/Local/Packages/...LocalState/`) as a **static sync-from-host file** (`chezmoi re-add` after Settings-UI edits — WT re-serializes the file; see `docs/claude/file-care.md`). Per-host SSH profiles are NOT in settings.json: `Invoke-WindowsTerminalFragments` regenerates `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\workstation\hosts.json` from `hosts.conf` every bootstrap (deterministic UUID5 GUIDs; wipes **only** `*.json` inside the `workstation` fragment dir — user fragments/profiles are untouchable by construction; WT reads fragments at launch → restart to pick up changes; `disabledProfileSources` keeps WT's 1.24 ssh_config generator from duplicating hosts without the `zellij attach` suffix). The Warp retirement follows the WezTerm pattern: `Invoke-WarpRetire` (every-run, warn-and-continue) removes managed `workstation-*.toml` Tab Configs and best-effort-uninstalls the app; `.chezmoiremove` heals the deployed configs; user-created Warp data is never touched.

  Delete the "Warp's Nushell exception" bullet (~94) entirely; in the Nushell-default bullet (~92) drop the Warp sentence (Nushell default is now unconditional; Windows Terminal `defaultProfile` + Zed). Update the verification pointer list ("Warp/WSL" → "Windows Terminal/WSL").
- [ ] **Step 2: `docs/claude/invariants.md`** — add a "Warp retired (2026-07)" entry beside the WezTerm one (retire step actions, leftover Doctor check, `.chezmoiremove` paths) and the full WT invariant detail (fragment namespace = managed prefix; UUID5 chain `{f65ddb7e-…}` → "workstation" → profile name, UTF-16LE; settings.json edits the generator must never make).
- [ ] **Step 3: `docs/claude/file-care.md`** — delete the Warp entry; expand the WT settings.json entry: new managed keys (defaults font/cursor/`historySize 100000` — record the on-machine effective ceiling if clamped, `bellStyle`, `firstWindowPreference`, `disabledProfileSources`, `newTabMenu` matcher), the fragment file's care rules (generated — never hand-edit; UTF-8 no BOM, LF), and the unchanged re-add/trailing-space/no-final-newline quirks.
- [ ] **Step 4: `docs/claude/verification.md`** — replace the Warp recipe:

```markdown
## Windows Terminal
On the Windows host after `bootstrap.ps1` + `chezmoi apply`, restart WT, then:
- Catppuccin Mocha chrome + scheme; JetBrainsMono NFM 10.5; bar cursor (defaults, all profiles).
- CTRL+SHIFT+T lands in Nushell (defaultProfile); new-tab dropdown shows an "SSH hosts" folder
  with one `SSH: <host>` entry per hosts.conf row (green dev / teal prod tab colors).
- Pick a host → lands in the remote zellij session (`ssh -t … zellij attach --create main`).
- alt+shift+d / alt+shift+r split panes; alt+shift+arrows move focus; ctrl+shift+z zooms.
- A hand-made profile in settings.json AND a foreign-named fragment file
  (`Fragments\other-app\x.json`) both survive a bootstrap re-run; only
  `Fragments\workstation\*.json` regenerates.
- Doctor: WT present, fragment count == hosts.conf rows, "no retired-Warp leftovers".
- In a WSL tab: starship prompt renders, atuin Ctrl-R works, fzf-tab completes (the Warp
  guards are gone); check a remote zellij pane for exactly one OSC 133 prompt-zone set.
- `$env:WT_SESSION` non-empty in a pwsh tab; scroll a long output to confirm the effective
  historySize (record the real ceiling in file-care.md if WT clamps below 100000).
```

- [ ] **Step 5: Verify:** `make -C makefile lint MODE=prod`; `rg -i warp CLAUDE.md docs/claude/` → only the retirement-invariant mentions remain.
- [ ] **Step 6: Commit** — `docs(claude): Windows Terminal invariants replace Warp; verification recipe swapped`.

---

### Task 9: README.html sweep (+ `docs/windows/application_list.md`)

**Files:**
- Modify: `README.html` — TOC 99; hero 135; Terminal card 309–311; §setup-linux 2544, 2647–2649; §setup-windows 2769–2830, 3026–3060, 3100, 3120–3216; §setup-wsl 3236–3300; **§setup-warp 3325–3416 → §setup-windows-terminal**; §hosts 3587–3600, 3656; §adding 4246; troubleshooting 4258, 4442, 4464–4490, 4735, 4820–4840
- Modify: `docs/README/README.js` only if the TOC/filter data hardcodes the `#setup-warp` anchor (check first: `rg 'setup-warp' docs/README/`)
- Modify: `docs/windows/application_list.md:21`

Copy points (translate into the existing HTML idiom of each section; keep section/card markup patterns):

- [ ] **Step 1: Global swaps** — hero tagline "…plus Windows Terminal as the Windows terminal"; Terminal card: `🖥️ Windows Terminal — the terminal: WSL, SSH+Zellij hosts, and local shells all launch from its profiles; per-host SSH profiles regenerate from hosts.conf as a JSON fragment.`; §setup-linux font sentence "WSL apps render via Windows Terminal on the Windows host"; doctor roster "…Windows Terminal, Nerd Fonts, …, the workstation SSH-profile fragment, retired-Warp/WezTerm leftovers".
- [ ] **Step 2: §setup-windows** — install card: evergreen winget/Store seed (per-user MSIX, no pin, self-updates), chezmoi owns `settings.json` (re-add model), fragment regeneration each run, "user-created profiles and fragments are never removed"; flow diagram step 2 "Install Windows Terminal + chezmoi + portable tools", step 5c "Windows Terminal SSH-profile fragment / from hosts.conf", step 5f "warp + wezterm retire"; "Warp config model" note → "Windows Terminal config model": chezmoi deploys settings.json to the Store `LocalState` path; the fragment lives under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\workstation\`; WT reads fragments at launch — restart after bootstrap; Settings-UI edits re-serialize the file — re-sync with `chezmoi re-add`.
- [ ] **Step 3: §setup-warp → §setup-windows-terminal** (retitle h3 + TOC anchor; update `README.js` if it names the anchor): launch flow (new-tab dropdown → "SSH hosts" folder; `wt` CLI examples: `wt nt -p "SSH: cache-apl"`, quake note optional), keybind table replacing the Warp one:

| Keys | Action |
|---|---|
| `alt+shift+d` / `alt+shift+r` | split pane down / right (Zellij mnemonics) |
| `alt+shift+arrows` | move pane focus (shadows WT's default resize — resize via palette/mouse) |
| `ctrl+shift+z` | toggle pane zoom |
| `ctrl+=` / `ctrl+-` / `ctrl+0` | font size bigger / smaller / reset |
| `ctrl+c` / `ctrl+v` | copy (multi-line) / paste |
| `ctrl+shift+f` | find (regex) |
| `ctrl+shift+t` / `ctrl+shift+w` | new tab (Nushell) / close |

  plus a migration note: fzf/atuin/starship/shift-select/fzf-tab are active again in WSL/SSH sessions (the Warp-era suppression guards are gone); Warp's Blocks/bookmarks/workflows have no WT equivalent.
- [ ] **Step 4: §setup-wsl** — AlmaLinux-9 sessions via the WT WSL profile (`wsl.exe -d AlmaLinux-9 --cd ~` semantics; long-lived work still lives in zellij); §hosts: "One output is regenerated from hosts.conf: the workstation SSH-profile fragment for Windows Terminal, rebuilt by `Invoke-WindowsTerminalFragments` on every Windows run. On Linux nothing is generated."; §adding: "…the Windows Terminal SSH profiles pick it up on the next `bootstrap.ps1` run (restart WT)".
- [ ] **Step 5: Troubleshooting** — retitle "Warp shows old settings after an edit" → "Windows Terminal shows old settings / missing SSH hosts": `chezmoi apply` + WT hot-reloads settings.json, but **fragments need a WT restart**; brand-new fragments may need a one-time enable on WT's Extensions page; stale/missing SSH entries → re-run `bootstrap.ps1`. Update the SSH-recovery entry (4442): "open the host's `SSH: <host>` profile again from the SSH hosts folder". Truecolor (4735) + tofu (4820–4840) entries: s/Warp/Windows Terminal/ (restart WT for fonts). Filter placeholder (4258): swap the example query `'warp'` → `'terminal'`. Keep CLAUDE.md's "(25 entries)" count accurate if any entry merges.
- [ ] **Step 6: `docs/windows/application_list.md:21`** — `- Warp (the terminal; official per-user WinGet seed)` → `- Windows Terminal (the terminal; evergreen per-user WinGet/Store seed)` (this list prints at the end of every bootstrap run).
- [ ] **Step 7: Verify:** open `README.html` in a browser — TOC link works, no dangling `#setup-warp` anchor (`rg -c 'setup-warp' README.html docs/README/` → 0); `rg -i 'warp' README.html` → only the retirement/migration notes remain deliberately.
- [ ] **Step 8: Commit** — `docs(readme): Windows Terminal replaces Warp across setup/hosts/troubleshooting`.

---

### Task 10: Changelog + final lint + PR

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (prepend row, matching existing format)

- [ ] **Step 1:** Add the row: date 2026-07-26 — "Windows Terminal migration: Warp retired (WezTerm-pattern retire step + `.chezmoiremove`), WT seeded evergreen via winget, `hosts.conf` → `Fragments\workstation\hosts.json` SSH profiles (UUID5), settings.json elevation (defaults/keybinds/newTabMenu/persistence), rc Warp-guards removed" — README-impact column: §setup-windows-terminal replaces §setup-warp; hosts/adding/troubleshooting/toolbelt updated.
- [ ] **Step 2:** Full gates: `make -C makefile lint MODE=prod && make -C makefile ps-lint && bash scripts/check-templates.sh`; `git log --oneline main..` reads as the task sequence.
- [ ] **Step 3:** Push + PR: `git push -u origin feat/windows-terminal-migration`, then `gh pr create` — title `feat(windows-terminal): Windows Terminal replaces Warp as the managed Windows terminal`, body: summary table (retire / seed / fragment / settings elevation / guards / docs), the three flagged decisions from the spec (Warp uninstall in retire step; font 10.5; Nushell stays default), verification checklist pointer, and the standard generated-with footer.

---

### Task 11: Windows-host validation (handed to the user — interactive)

Per the standing memory, Windows-side interactive commands are handed to the user, never driven through interop pipes. After the PR merges and the Windows host pulls:

- [ ] **Step 1:** User runs `.\bootstrap.ps1` then `chezmoi apply`, restarts Windows Terminal.
- [ ] **Step 2:** User walks the `docs/claude/verification.md` "Windows Terminal" recipe (Task 8 Step 4) — including the two on-machine unknowns: the effective `historySize` ceiling, and whether `matchProfiles` regex-matches `name` on stable 1.24 (fallback: match on the fragment's `source` value, then update settings.json + file-care.md).
- [ ] **Step 3:** Any drift WT writes on first launch → `chezmoi re-add` the settings.json and commit (expected, documented).

---

## Self-review notes

- Spec coverage: install seed (T2), settings elevation (T1), fragment generator (T3), Warp retirement bootstrap (T4) + chezmoi (T5), rc guards (T6), manage-hosts/bootstrap.sh (T7), invariants/docs (T8), README/application_list (T9), changelog/PR (T10), on-machine verification incl. flagged unknowns (T11). Deferred native-Windows zellij and rejected psmux are documented in the spec (§5) — deliberately no task here.
- Type/name consistency: `Install-WindowsTerminal`, `New-Uuid5`, `Invoke-WindowsTerminalFragments`, `Invoke-WarpRetire`, `note_terminal_refresh`/`Show-TerminalRefreshNote`, fragment path `Fragments\workstation\hosts.json`, profile prefix `SSH: ` — used identically across T1–T9.
- Line numbers are advisory (pre-edit snapshots); every task locates by symbol/content first.
