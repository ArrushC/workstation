# Windows GUI apps from a declarative manifest — implementation plan (PR A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Windows GUI apps become data, `[bootstrap.packages]` in `config.windows.toml`, installed by `mise bootstrap --only packages`. `bootstrap.ps1` keeps only the SSHFS-Win install, which raises UAC.

**Architecture:**
- **The app list.** Eight `"winget:<Id>" = "latest"` entries in `config.windows.toml`.
- **Install scope.** A tracked winget `settings.json` dotfile tells winget to prefer per-user installers.
- **Run order.** `bootstrap.ps1` runs `mise -C ~ bootstrap --only packages --yes` after its existing `--only dotfiles,tools` call. Two calls are needed: within one call mise runs packages before dotfiles, so the winget settings would not be in place yet.
- **SSHFS-Win.** It stays a hand-written step because mise installs winget packages silently, and a silent MSI install cannot raise UAC.
- **Lint.** It keeps `winget:` entries in `config.windows.toml` only, and keeps SSHFS-Win out of the manifest.

**Tech Stack:** mise 2026.9.9 (`[bootstrap.packages]`, its winget manager), winget 1.29, Windows PowerShell 5.1 / pwsh 7, bash + python3 `tomllib` (lint).

**Spec:** `docs/superpowers/specs/2026-10-02-windows-nushell-apps-design.md` §5 (and §6–§7 for testing and delivery).

## Global Constraints

- **PowerShell files.** `bootstrap.ps1` and every `scripts/test-*.ps1` are UTF-8 with BOM and LF line endings.
  - They must parse and run under Windows PowerShell 5.1 and pwsh 7, with `Set-StrictMode -Version Latest`.
  - No ternary, no `??`, no `&&`/`||` pipeline chains.
  - In double-quoted strings write `${name}:`, never a bare `$name:`.
- **Parse check after every `bootstrap.ps1` edit.** Expected output: `parse OK`.
  ```bash
  cp bootstrap.ps1 /mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/bs-parse.ps1
  (cd /mnt/c/Users/arrush.chaturvedi && /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
    'Set-Location $env:USERPROFILE; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\bs-parse.ps1",[ref]$null,[ref]$e); if($e){$e|%{$_.ToString()}; exit 1}else{"parse OK"}' | tr -d '\r')
  ```
- **Every mise call in `bootstrap.ps1` is pinned with `-C $env:USERPROFILE`.**
- **Dotfile sources.** Every file under `dotfiles/` is git mode 100644 and LF (`check_dotfiles_mode`). The new winget `settings.json` must be strict JSON: no comments, so put notes in `config.windows.toml`.
- **Size budgets:**
  - `CLAUDE.md` ≤ 14,000 bytes. It is 13,999 now, so every addition needs an equal cut in the same section.
  - `CLAUDE.md` + `docs/claude/*` ≤ 30,000 bytes.
  - `README.md` ≤ 600 lines. It is 592 now.
- **Never run on the real Windows host:**
  - `bootstrap.ps1`
  - `winget install` / `winget upgrade`
  - `mise bootstrap packages apply` / `upgrade`
  - `mise dot apply` / `wsa`

  Read-only probes are fine: `winget list`, `winget --info`, `mise bootstrap packages status` (in a temp dir), and parsing.
- **Running the `.ps1` tests from WSL.**
  - Copy `bootstrap.ps1`, `scripts/*.ps1` and `scripts/python-env.txt` under `%TEMP%`, keeping the `scripts\` layout.
  - `cd /mnt/c/Users/arrush.chaturvedi`, then run with `-NoProfile -ExecutionPolicy Bypass -File` under both `powershell.exe` and `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`.
  - powershell.exe 5.1 needs the Machine PSModulePath:
    ```bash
    PSModulePath="$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('PSModulePath','Machine')" | tr -d '\r')" WSLENV=PSModulePath/w powershell.exe ...
    ```
- **Commits.** End every commit with these lines, and push after every commit (`git push`, branch `feat/windows-apps-manifest`). The pre-commit hook runs `mise run lint`; never use `--no-verify`.
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
  ```
- **Docs travel with behaviour:** `README.md` changes in the same commit as the behaviour it describes.

## Review Focus

1. **A broken winget never raises a surprise UAC prompt.** If `winget list` errors with anything other than "no installed package found" (`0x8A150014`), SSHFS-Win is not installed and the step warns. → Task 2, the "winget list errors" case.
2. **One failing app never stops the bootstrap.** A non-zero `mise bootstrap --only packages`, or a mise that won't start, warns, and SSHFS-Win and the rest of the run go on. → Task 2, the "mise packages fails" and "mise cannot start" cases.
3. **Invalid winget settings.** An invalid `settings.json` makes winget warn on every command and ignore the scope preference. → Task 1, the `python3 -m json.tool` step and the Windows `winget --info` probe.
4. **`-SkipElevated` still installs every non-UAC app.** → Task 2, the `-SkipElevated` case.
5. **A Linux host never sees a `winget:` entry.** → Task 1's lint rule and its mutation checks.

---

### Task 1: The manifest, winget's settings, and the lint rule

**Files:**
- Modify: `config.windows.toml`. Header comment, a new dotfile entry, and a new `[bootstrap.packages]` table at the end.
- Create: `dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json`, mode 100644, LF.
- Modify: `scripts/check-invariants.sh`, in `check_bootstrap_config`: the `hdr` text, a new `winget` block inside its Python heredoc, and the `shared-safety` message.

**Interfaces:**
- Produces: the eight `winget:` keys that Task 2's `mise bootstrap --only packages` installs, and a lint line `PASS|winget|…` / `FAIL|winget|…`.

- [ ] **Step 1: Record the Linux baseline (the change must not alter Linux).**

```bash
cd ~/.config/mise
for set in linux linux,owned,host,wsl linux,owned,host,native; do
  MISE_ENV=$set mise -C ~ bootstrap plan --json 2>/dev/null | jq -S 'del(.summary)' | md5sum
done > /tmp/claude-1000/pr-a-plan-before.txt
cat /tmp/claude-1000/pr-a-plan-before.txt
```

Expected: three hashes. Task 3 compares against them.

- [ ] **Step 2: Write the winget settings dotfile.**

Create `dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json` with exactly:

```json
{
    "$schema": "https://aka.ms/winget-settings.schema.json",
    "installBehavior": {
        "preferences": {
            "scope": "user"
        }
    }
}
```

Then:

```bash
python3 -m json.tool dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json >/dev/null && echo JSON-OK
git add dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json
git ls-files -s dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json
```

Expected: `JSON-OK`, and mode `100644`.

- [ ] **Step 3: Edit `config.windows.toml`.**

1. Replace the first comment line, `# config.windows.toml: Windows-only dotfiles (MISE_ENV token `windows`; loads`, with `# config.windows.toml: Windows-only dotfiles and GUI apps (MISE_ENV token `windows`; loads`.

2. After the `"~/AppData/Local/warp/Warp/config/keybindings.yaml"` entry, add:

```toml
# winget's user settings (`winget --info` shows the path). Edit-in-repo-only; JSON
# can't carry comments, so the rule lives here: installBehavior.preferences.scope
# = "user" makes every winget install, [bootstrap.packages] below included, pick a
# per-user installer when the package has one, and fall back to machine scope when
# it doesn't (Zed's only installer claims machine scope but installs per-user).
"~/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json" = { source = "dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json", mode = "copy" }
```

3. Append at the end of the file:

```toml

# GUI apps, installed by `mise bootstrap --only packages` (bootstrap.ps1 runs it after
# the dotfiles, so winget's scope preference above is already in place). An app counts
# as installed when `winget list --id <Id> --exact` finds it; "latest" because each one
# self-updates (`mise bootstrap packages upgrade --manager winget` updates them all).
# SSHFS-Win is not here: mise installs silently, and its WinFsp MSI must raise UAC, so
# bootstrap.ps1's Install-SshfsWin installs it (check_bootstrap_config keeps it out).
[bootstrap.packages]
"winget:Microsoft.WindowsTerminal" = "latest"
"winget:Warp.Warp" = "latest"
"winget:Obsidian.Obsidian" = "latest"
"winget:DevToys-app.DevToys" = "latest"
"winget:DBeaver.DBeaver.Community" = "latest"
"winget:WinSCP.WinSCP" = "latest"
"winget:ScooterSoftware.BeyondCompare.5" = "latest"
"winget:ZedIndustries.Zed" = "latest"
```

- [ ] **Step 4: Confirm every Id read-only on the Windows host.**

This trusts a throwaway temp dir, reads the status, then untrusts the dir and deletes it. Nothing is installed.

```bash
T=/mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/ws-apps-probe
rm -rf "$T" && mkdir -p "$T"
sed -n '/^\[bootstrap.packages\]/,$p' config.windows.toml > "$T/mise.toml"
cat "$T/mise.toml"
(cd /mnt/c/Users/arrush.chaturvedi && timeout 300 powershell.exe -NoProfile -Command '
  $t = "$env:LOCALAPPDATA\Temp\ws-apps-probe"; Set-Location $t
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  & mise trust $t *> $null
  & mise bootstrap packages status 2>&1 | ForEach-Object { "$_" }
  & mise trust --untrust $t *> $null
  "--- winget --info settings line:"; & winget --info 2>&1 | Select-String "User Settings" | ForEach-Object { $_.Line }' | tr -d '\r')
rm -rf "$T"
```

Expected: eight `winget  <Id>  <version>  installed` lines, no `missing`, and the `User Settings` path ending in `LocalState\settings.json`. Paste the output into the report.

- [ ] **Step 5: Write the lint rule.**

In `scripts/check-invariants.sh`, `check_bootstrap_config`:

1. Change the header line to:

```bash
  hdr "bootstrap-config invariants (config.host/native/wsl/linux/windows.toml)"
```

2. Inside the Python heredoc, directly after the `print(f"PASS|packages|…")` / `FAIL|packages` block and before `ruling_hits = []`, add:

```python
# winget GUI apps are Windows-only, so they live in config.windows.toml alone; SSHFS-Win
# stays in bootstrap.ps1 (mise installs silently, and its WinFsp MSI must raise UAC).
win_hits = []
n_winget = 0
for cf in ["config.toml", "config.linux.toml", "config.owned.toml", "config.host.toml",
           "config.native.toml", "config.wsl.toml", "config.windows.toml"]:
    try:
        with open(cf, "rb") as fh:
            pkgs = tomllib.load(fh).get("bootstrap", {}).get("packages", {})
    except FileNotFoundError:
        continue
    except Exception as e:
        win_hits.append(f"{cf} failed to parse: {e}")
        continue
    for key, val in pkgs.items():
        if cf == "config.windows.toml":
            if not key.startswith("winget:"):
                win_hits.append(f"{cf}:{key} (only winget: packages belong here)")
                continue
            n_winget += 1
            if key.lower() == "winget:sshfs-win.sshfs-win":
                win_hits.append(f"{cf}:{key} (SSHFS-Win must raise UAC; it stays in bootstrap.ps1's Install-SshfsWin)")
            if val != "latest":
                win_hits.append(f"{cf}:{key} = {val!r} (want \"latest\": the apps self-update)")
        elif key.startswith("winget:"):
            win_hits.append(f"{cf}:{key} (winget: packages belong in config.windows.toml)")
if win_hits:
    print("FAIL|winget|" + "; ".join(win_hits))
elif n_winget == 0:
    print("FAIL|winget|config.windows.toml declares no winget: packages")
else:
    print(f"PASS|winget|{n_winget} winget: GUI app(s), all in config.windows.toml, \"latest\", SSHFS-Win not among them")
```

3. Change the `shared-safety` FAIL message `(shared hosts / Windows must never load one)` to `(shared hosts and Windows load it; host state lives in the token-gated files)`.

- [ ] **Step 6: Check that the rule passes on the repo and fails on each kind of drift.**

```bash
bash scripts/check-invariants.sh --only check_bootstrap_config; echo "rc=$?"
```

Expected: rc 0, with a line `✓ 8 winget: GUI app(s), all in config.windows.toml, "latest", SSHFS-Win not among them`.

Then run the three mutations against temp copies:

```bash
mut() { # mut <label> <file> <sed-expression> <expected-text>
  local T; T="$(mktemp -d)"
  cp -p config*.toml "$T/" && cp -rp tasks "$T/" && mkdir -p "$T/scripts" && cp -p scripts/check-invariants.sh "$T/scripts/"
  sed -i "$3" "$T/$2"
  out="$(bash "$T/scripts/check-invariants.sh" --only check_bootstrap_config 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF -- "$4"; then echo "PASS $1"; else echo "FAIL $1 (rc=$rc)"; printf '%s\n' "$out" | tail -5; fi
  rm -rf "$T"
}
mut "winget outside config.windows.toml" config.host.toml '/^\[bootstrap.packages\]/a "winget:Foo.Bar" = "latest"' 'winget: packages belong in config.windows.toml'
mut "SSHFS-Win in the manifest" config.windows.toml '/^\[bootstrap.packages\]/a "winget:SSHFS-Win.SSHFS-Win" = "latest"' 'SSHFS-Win must raise UAC'
mut "a pinned version" config.windows.toml 's/^"winget:Warp.Warp" = "latest"/"winget:Warp.Warp" = "1.0"/' 'want "latest"'
```

Expected: three `PASS` lines. Paste them into the report.

- [ ] **Step 7: Run lint and the template check.**

```bash
mise run lint 2>&1 | tail -3
bash scripts/check-templates.sh 2>&1 | tail -2
```

Expected:
- `✓ all invariant checks passed`
- `all rendered templates pass, across all four MISE_ENV sets`
- The `dotfiles-config invariants` section counts 47 entries, one more than before.

- [ ] **Step 8: Commit and push.**

```bash
git add config.windows.toml scripts/check-invariants.sh dotfiles/windows/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json
git commit -F - <<'EOF'
feat(windows): GUI apps declared in config.windows.toml [bootstrap.packages] (winget); winget settings prefer per-user installers; lint keeps winget entries Windows-only and SSHFS-Win out

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
EOF
git push
```

`bootstrap.ps1` still installs the old table after this commit, so nothing on the host changes until Task 2.

---

### Task 2: bootstrap.ps1 installs the apps through mise; only SSHFS-Win stays

**Files:**
- Modify `bootstrap.ps1`:
  - the header comment (lines 1–12)
  - delete `$WingetApps` (from the `# winget installs these, then they self-update.` comment through the closing `)` of the table)
  - replace `Install-WingetApps` (and the comment above it), and add `Install-SshfsWin`
  - `Invoke-ToolInstall`: its skip log and the `Install-WingetApps` call
  - the comment above `Invoke-InstallClaudeCode` that mentions `$WingetApps`
  - the RUN SEQUENCE
- Rewrite: `scripts/test-winget-apps.ps1` (BOM, LF)
- Modify:
  - `PSScriptAnalyzerSettings.psd1`: the comment naming `Install-WingetApps` stays valid, since the function keeps its name; touch it only if the reviewer flags it
  - `README.md`
  - `CLAUDE.md`
  - `docs/claude/verification.md`

**Interfaces:**
- Consumes: Task 1's `[bootstrap.packages]` table, read by `mise bootstrap --only packages`.
- Produces:
  - `Install-WingetApps`, with no parameters. It reads `$SkipToolInstall`.
  - `Install-SshfsWin`, with no parameters. It reads `$SkipElevated`.
  - Both write only through `Write-Log` / `Write-Ok` / `Write-Warn`, and never throw.

- [ ] **Step 1: Write the new test (it fails against today's `bootstrap.ps1`).**

Replace `scripts/test-winget-apps.ps1` entirely. Write it with a UTF-8 BOM and LF; the post-edit hook restores the BOM if an edit drops it, so check with `head -c3 scripts/test-winget-apps.ps1 | od -An -tx1` → `ef bb bf`.

```powershell
# Tests bootstrap.ps1's GUI-app step without running the bootstrap: Install-WingetApps
# (mise bootstrap --only packages: config.windows.toml's winget list) and
# Install-SshfsWin (the one UAC install). Both are extracted from the script's AST,
# as scripts/test-ssh-launchers.ps1 does.
#
# Nothing is installed: `mise` and `winget` are function stubs that record their
# arguments (functions win over mise.exe/winget.exe on PATH), and the script stops
# unless both resolve to the stubs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$failures = New-Object System.Collections.Generic.List[string]
$wanted = 'Install-WingetApps', 'Install-SshfsWin'
$found = @()
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
    $found += $f.Name
}
foreach ($w in $wanted) { if ($found -notcontains $w) { $failures.Add("bootstrap.ps1 has no function $w") } }
if ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'WingetApps' }, $true)) {
    $failures.Add('bootstrap.ps1 still references $WingetApps (the apps live in config.windows.toml)')
}
if ($failures.Count -gt 0) { throw "winget apps: $($failures -join '; ')" }

# Every mise/winget call and log line, in order.
$script:events = New-Object System.Collections.Generic.List[string]
$script:miseExit = 0
$script:miseThrows = $false
$script:listExit = 0
$script:installExit = 0
$script:wingetThrows = $false
# The ErrorActionPreference winget runs under, and the one the warnings run under afterwards.
$script:wingetEap = New-Object System.Collections.Generic.List[string]
$script:warnEap = New-Object System.Collections.Generic.List[string]
function mise {
    $script:events.Add("mise $($args -join ' ')")
    if ($script:miseThrows) { throw [System.Management.Automation.ApplicationFailedException]::new('mise could not start') }
    $global:LASTEXITCODE = $script:miseExit
}
function winget {
    $script:events.Add("winget $($args -join ' ')")
    $script:wingetEap.Add("$ErrorActionPreference")
    if ($script:wingetThrows) { throw [System.Management.Automation.ApplicationFailedException]::new('The file cannot be accessed by the system.') }
    if ($args[0] -eq 'list') { $global:LASTEXITCODE = $script:listExit } else { $global:LASTEXITCODE = $script:installExit }
}
foreach ($c in 'mise', 'winget') {
    if ((Get-Command $c).CommandType -ne 'Function') { throw "refusing to run: $c does not resolve to the test stub" }
}
function Write-Log { param($m) $script:events.Add("log: $m") }
function Write-Ok { param($m) $script:events.Add("ok: $m") }
function Write-Warn { param($m) $script:events.Add("warn: $m"); $script:warnEap.Add("$ErrorActionPreference") }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }
function Get-Code([string]$Hex) { [Convert]::ToInt32($Hex, 16) }
function Get-Events([string]$Like) { @($script:events | Where-Object { $_ -like $Like }) }
function Show { $script:events -join ' | ' }

# One GUI-app run with the given stub behaviour.
function Invoke-Apps([switch]$SkipTools, [switch]$SkipElev, [int]$MiseExit = 0, [switch]$MiseThrows,
                     [int]$ListExit = 0, [int]$InstallExit = 0, [switch]$WingetThrows) {
    $script:SkipToolInstall = [bool]$SkipTools
    $script:SkipElevated = [bool]$SkipElev
    $script:miseExit = $MiseExit
    $script:miseThrows = [bool]$MiseThrows
    $script:listExit = $ListExit
    $script:installExit = $InstallExit
    $script:wingetThrows = [bool]$WingetThrows
    $script:events.Clear()
    $script:wingetEap.Clear()
    $script:warnEap.Clear()
    Install-WingetApps
}

$miseCall = "mise -C $env:USERPROFILE bootstrap --only packages --yes"
$listCall = 'winget list --id SSHFS-Win.SSHFS-Win --exact --disable-interactivity --accept-source-agreements'
$installCall = 'winget install --id SSHFS-Win.SSHFS-Win --exact --scope machine --disable-interactivity --accept-package-agreements --accept-source-agreements'
$notFound = Get-Code '8A150014'

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}

Test-Case '-SkipToolInstall: neither mise nor winget runs' {
    Invoke-Apps -SkipTools
    Assert ((Get-Events 'mise *').Count -eq 0 -and (Get-Events 'winget *').Count -eq 0) "calls: $(Show)"
    Assert ((Get-Events 'log: GUI apps skipped (-SkipToolInstall)').Count -eq 1) "log: $(Show)"
}

Test-Case 'the apps come from mise (pinned with -C), then SSHFS-Win is checked with winget list; present -> no install' {
    Invoke-Apps -ListExit 0
    Assert ((Get-Events 'mise *').Count -eq 1 -and (Get-Events 'mise *')[0] -ceq $miseCall) "mise calls: $(Show)"
    Assert ((Get-Events 'winget *').Count -eq 1 -and (Get-Events 'winget *')[0] -ceq $listCall) "winget calls: $(Show)"
    Assert ($script:events.IndexOf($miseCall) -lt $script:events.IndexOf($listCall)) "order: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win present').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'warn: *').Count -eq 0) "warned: $(Show)"
}

Test-Case 'SSHFS-Win missing (0x8A150014): machine scope, no --silent, the UAC warning (two prompts without WinFsp) before the install' {
    Invoke-Apps -ListExit $notFound
    $installs = Get-Events 'winget install *'
    Assert ($installs.Count -eq 1 -and $installs[0] -ceq $installCall) "install calls: $(Show)"
    Assert (($installs[0] -split ' ') -notcontains '--silent') "--silent in: $($installs[0])"
    $warn = Get-Events 'warn: SSHFS-Win installs machine-wide*expect a UAC prompt*'
    Assert ($warn.Count -eq 1 -and $warn[0] -like '*without WinFsp*two*one for WinFsp*one for SSHFS-Win*') "UAC warning: $(Show)"
    Assert ($script:events.IndexOf($warn[0]) -lt $script:events.IndexOf($installs[0])) "warning after the install: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win installed').Count -eq 1) "log: $(Show)"
}

Test-Case '-SkipElevated: the mise apps still install; SSHFS-Win is neither checked nor installed' {
    Invoke-Apps -SkipElev -ListExit $notFound
    Assert ((Get-Events 'mise *').Count -eq 1) "mise calls: $(Show)"
    Assert ((Get-Events 'winget *').Count -eq 0) "winget calls: $(Show)"
    Assert ((Get-Events 'log: SSHFS-Win skipped (-SkipElevated)').Count -eq 1) "log: $(Show)"
}

Test-Case 'mise packages fails: a warning with the retry command, and SSHFS-Win still runs' {
    Invoke-Apps -MiseExit 1 -ListExit 0
    Assert ((Get-Events 'warn: mise bootstrap --only packages exited 1*mise bootstrap packages apply --manager winget*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'winget list *').Count -eq 1) "SSHFS-Win skipped: $(Show)"
}

Test-Case 'mise cannot start: a warning, and SSHFS-Win still runs' {
    Invoke-Apps -MiseThrows -ListExit 0
    Assert ((Get-Events 'warn: mise bootstrap --only packages could not start*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'winget list *').Count -eq 1) "SSHFS-Win skipped: $(Show)"
}

Test-Case 'winget list errors (not 0x8A150014): a warning and NO install, so no surprise UAC prompt' {
    Invoke-Apps -ListExit (Get-Code '8A15000F')
    Assert ((Get-Events 'winget install *').Count -eq 0) "installed anyway: $(Show)"
    Assert ((Get-Events 'warn: SSHFS-Win: could not check it (winget list 0x8A15000F)*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events '*expect a UAC prompt*').Count -eq 0) "UAC warning without an install: $(Show)"
}

Test-Case 'an install failure warns with the hex code and the manual command' {
    Invoke-Apps -ListExit $notFound -InstallExit (Get-Code '8A150014')
    Assert ((Get-Events 'warn: SSHFS-Win: winget exited 0x8A150014*winget install --id SSHFS-Win.SSHFS-Win').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win installed').Count -eq 0) "reported success: $(Show)"
}

Test-Case 'winget "already installed" codes (0x8A15002B, 0x8A150061, 0x8A15010D) count as present' {
    foreach ($hex in '8A15002B', '8A150061', '8A15010D') {
        Invoke-Apps -ListExit $notFound -InstallExit (Get-Code $hex)
        Assert ((Get-Events 'ok: SSHFS-Win present (winget)').Count -eq 1) "0x${hex}: $(Show)"
        Assert ((Get-Events 'warn: SSHFS-Win:*').Count -eq 0) "0x${hex} warned: $(Show)"
    }
}

Test-Case 'a winget that cannot start: a warning, no install, winget ran under Continue and the warning under Stop' {
    Invoke-Apps -WingetThrows
    Assert ((Get-Events 'winget install *').Count -eq 0) "installed: $(Show)"
    Assert ((Get-Events 'warn: SSHFS-Win: could not check it (winget list error*').Count -eq 1) "log: $(Show)"
    Assert ((@($script:wingetEap | Where-Object { $_ -ne 'Continue' }).Count -eq 0) -and ($script:wingetEap.Count -eq 1)) "EAP inside winget: $($script:wingetEap -join ', ')"
    Assert ((@($script:warnEap | Where-Object { $_ -ne 'Stop' }).Count -eq 0) -and ($script:warnEap.Count -ge 1)) "EAP at the warning: $($script:warnEap -join ', ')"
}

if ($failures.Count -gt 0) { throw "winget apps: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "winget app checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
```

- [ ] **Step 2: Run it and watch it fail.** Use the WSL recipe in Global Constraints, in both shells.

Expected: `winget apps: bootstrap.ps1 has no function Install-SshfsWin; bootstrap.ps1 still references $WingetApps …`, non-zero exit.

- [ ] **Step 3: Change `bootstrap.ps1`.**

**(a) The header comment.** Replace lines 2–11 (from `# bootstrap.ps1 -- workstation setup` through `# bootstrap status, mise dot status, winget upgrade.`) with:

```powershell
# bootstrap.ps1 -- workstation setup (Windows), per-user, no admin. It checks
# for git and curl.exe (it never installs Git), installs the sha256-pinned mise,
# clones this repo, writes miserc.toml (windows,owned) and runs `mise bootstrap
# --only dotfiles,tools` (the dotfiles and every CLI tool), then `mise bootstrap
# --only packages` (config.windows.toml's winget GUI apps), then the steps under
# RUN SEQUENCE. The one admin step: SSHFS-Win raises UAC (two prompts on a host
# without WinFsp); declining it, or -SkipElevated, skips only that app.
# Run it as README.md's Windows setup shows. $env:GITHUB_TOKEN is optional (a
# private-fork clone; mise's GitHub API limit). Health: mise doctor, mise
# bootstrap status, mise dot status, mise bootstrap packages status.
```

**(b) The `$WingetApps` table.** Delete the whole block: the four comment lines starting `# winget installs these, then they self-update.`, `$WingetApps = @(`, its nine entries with their comment lines, and the closing `)`.

**(c) `Install-WingetApps`.** Replace the function and the three comment lines above it (starting `# winget checks each installer against its manifest sha256.`) with:

```powershell
# The GUI apps are config.windows.toml's [bootstrap.packages] (winget), installed by
# `mise bootstrap --only packages` once the dotfiles phase has deployed winget's
# settings.json (prefer per-user installers). mise installs silently, so SSHFS-Win,
# whose WinFsp MSI must raise UAC, is Install-SshfsWin's. Best-effort: a failure
# warns and the bootstrap goes on.
function Install-WingetApps {
    if ($SkipToolInstall) { Write-Log "GUI apps skipped (-SkipToolInstall)"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget not found — GUI apps skipped (install App Installer from the Microsoft Store, then re-run)"
        return
    }
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "mise not on PATH — the GUI apps in config.windows.toml were skipped (open a new shell and re-run .\bootstrap.ps1)"
    } else {
        Write-Log "Installing missing GUI apps (mise bootstrap --only packages: config.windows.toml's winget list)..."
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'   # PS 5.1 can turn native stderr into a terminating error under "Stop"
            & mise -C $env:USERPROFILE bootstrap --only packages --yes
            $code = $LASTEXITCODE
            $why = "exited $code"
        } catch {
            $code = -1
            $why = "could not start ($($_.Exception.Message))"
        } finally {
            $ErrorActionPreference = $oldEap
        }
        if ($code -eq 0) { Write-Ok "GUI apps installed or present ('mise bootstrap packages status' lists them)" }
        else { Write-Warn "mise bootstrap --only packages $why (output above) — retry: mise bootstrap packages apply --manager winget" }
    }
    Install-SshfsWin
}

# The one UAC install, from winget (sha256-checked). No --silent: it would run the
# MSI in-process at UI level None, where UAC can't appear (MSI error 1925). Only
# "no installed package found" (0x8A150014) from `winget list` installs, so a
# broken winget never raises a surprise prompt.
function Install-SshfsWin {
    $id = "SSHFS-Win.SSHFS-Win"
    if ($SkipElevated) { Write-Log "SSHFS-Win skipped (-SkipElevated)"; return }
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & winget list --id $id --exact --disable-interactivity --accept-source-agreements *> $null
        $listHex = '0x{0:X8}' -f [int]$LASTEXITCODE
    } catch {
        $listHex = "error: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($listHex -eq '0x00000000') { Write-Ok "SSHFS-Win present"; return }
    if ($listHex -ne '0x8A150014') {
        Write-Warn "SSHFS-Win: could not check it (winget list $listHex) — not installing; check with: winget list --id $id"
        return
    }
    Write-Warn "SSHFS-Win installs machine-wide — expect a UAC prompt; a host without WinFsp sees two, one for WinFsp and one for SSHFS-Win (skip with -SkipElevated)"
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & winget install --id $id --exact --scope machine --disable-interactivity --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE
        $why = "winget exited " + ('0x{0:X8}' -f [int]$code)
    } catch {
        $code = -1
        $why = "winget could not start ($($_.Exception.Message))"
    } finally {
        $ErrorActionPreference = $oldEap
    }
    # UPDATE_NOT_APPLICABLE, PACKAGE_ALREADY_INSTALLED, INSTALL_ALREADY_INSTALLED.
    if ($code -eq 0) { Write-Ok "SSHFS-Win installed" }
    elseif (@("0x8A15002B", "0x8A150061", "0x8A15010D") -contains ('0x{0:X8}' -f [int]$code)) { Write-Ok "SSHFS-Win present (winget)" }
    else { Write-Warn "SSHFS-Win: $why — install it later with: winget install --id $id" }
}
```

**(d) `Invoke-ToolInstall`:**
- Its skip line becomes:
  ```powershell
  Write-Log "Tool install skipped (-SkipToolInstall) — no mise install, mise tools, GUI apps, Python env or Claude Code"
  ```
- Delete the line `    Install-WingetApps      # the UAC entry (SSHFS-Win) comes last in the table`.

**(e) The comment above `Invoke-InstallClaudeCode`.** Replace `nor a $WingetApps entry` with `nor a winget GUI app`. Keep the rest of the sentence.

**(f) RUN SEQUENCE:**
- Change `Invoke-ToolInstall`'s trailing comment to `# the pinned mise under %LOCALAPPDATA%\workstation`.
- Directly after the `Invoke-MiseBootstrap` line, add:
  ```powershell
  Install-WingetApps        # GUI apps: mise bootstrap --only packages (config.windows.toml's winget list), then SSHFS-Win (UAC)
  ```

Then confirm nothing still names the table, and run the parse check:

```bash
rg -n 'WingetApps\b' bootstrap.ps1 | rg -v 'Install-WingetApps' || echo "no \$WingetApps left"
```

Expected: `no $WingetApps left`, then `parse OK`.

- [ ] **Step 4: Run the tests (both shells).**
  - `scripts/test-winget-apps.ps1`: expected `winget app checks passed on PowerShell 5.1…` and `…7.6.x`, 10 `ok` lines.
  - `scripts/test-ssh-launchers.ps1` and `scripts/test-mise-env.ps1` must still pass; they extract other functions from the same file.

- [ ] **Step 5: Docs.**

**`README.md`, "What `bootstrap.ps1` does"** (lines ~155–166). Delete step 3 ("Install the missing GUI apps through winget …"), renumber steps 4–6 as 3–5, and insert this as the new step 6 (the old steps 7–10 keep their numbers):

```markdown
6. Install the missing GUI apps: `mise bootstrap --only packages` installs `config.windows.toml`'s `[bootstrap.packages]` winget list (Windows Terminal, Warp, Obsidian, DevToys, DBeaver, WinSCP, Beyond Compare, Zed; latest, checked against the winget manifest's sha256, each self-updating). winget's own `settings.json`, a tracked dotfile, prefers per-user installers; Zed's only installer is machine scope but installs per-user, without admin. An app counts as installed when `winget list --id <Id> --exact` finds it, so an installed "DevToys Preview" counts as DevToys. Then SSHFS-Win (UAC). Without winget (App Installer) the step warns and skips.
```

**`README.md`, "Health and updates"** (line ~185). Replace the sentence starting `Update the GUI apps with` with:

```markdown
The GUI apps are `config.windows.toml`'s `[bootstrap.packages]`: `mise bootstrap packages status` lists them as installed or missing, `mise bootstrap packages apply --manager winget` installs the missing ones, and `mise bootstrap packages upgrade --manager winget` updates them. To add one, add a `"winget:<Id>" = "latest"` line (the Id from `winget search`).
```

Leave the troubleshooting entry `bootstrap.ps1 popped a UAC prompt` as it is: everything in it still holds. Check with `rg -n 'WingetApps|winget upgrade --all' README.md || echo clean` → `clean`.

**`CLAUDE.md`:**
- In the Layout table, the `config.windows.toml` row's "Holds" cell becomes `Windows-only dotfiles; winget GUI apps (\`[bootstrap.packages]\`)`.
- In **Windows**, replace the bullet beginning ``- `bootstrap.ps1` pins only mise and installs the `$WingetApps` GUI apps (winget); every CLI tool is a`` (two lines) with:
  ```markdown
  - `bootstrap.ps1` pins only mise; every CLI tool is a mise tool and the GUI apps are `config.windows.toml`'s winget
    `[bootstrap.packages]`, except SSHFS-Win (UAC). No User `MISE_ENV`; it stops before `mise bootstrap`/prune unless `config.owned.toml` loads.
  ```
- `wc -c CLAUDE.md` must be ≤ 14,000. If it's over, shorten words in the same Windows section; don't drop a rule.

**`docs/claude/verification.md`:**
- The `test-winget-apps.ps1` table row becomes:
  ```markdown
  | `test-winget-apps.ps1` | `Install-WingetApps` (`mise bootstrap --only packages`, pinned `-C`) and `Install-SshfsWin` (presence by `winget list`, no `--silent`, the UAC warning, `-SkipElevated`, exit codes) |
  ```
- Under "Live checks", add a bullet:
  ```markdown
  - `mise bootstrap packages status` lists the eight `config.windows.toml` apps as installed, and `winget --info` prints no settings warning.
  ```

- [ ] **Step 6: Lint and size checks.**

```bash
mise run lint 2>&1 | tail -2
wc -c CLAUDE.md
wc -c CLAUDE.md docs/claude/*.md | tail -1
wc -l README.md
```

Expected:
- `✓ all invariant checks passed`
- CLAUDE.md ≤ 14000
- CLAUDE.md + docs/claude ≤ 30000
- README ≤ 600

- [ ] **Step 7: Commit, push, and confirm CI is green.**

```bash
git add bootstrap.ps1 scripts/test-winget-apps.ps1 README.md CLAUDE.md docs/claude/verification.md
git commit -F - <<'EOF'
refactor(bootstrap.ps1): GUI apps come from mise bootstrap --only packages (config.windows.toml); only SSHFS-Win (UAC) stays hand-installed

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
EOF
git push
gh run list --branch feat/windows-apps-manifest --limit 1
gh run watch "$(gh run list --branch feat/windows-apps-manifest --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

Expected: every job passes, including `powershell` (PSScriptAnalyzer) and `windows-http`, which runs `test-winget-apps.ps1` in both shells.

---

### Task 3: Branch checks, the live Windows run, and the PR

- [ ] **Step 1: Branch checks (WSL).**

```bash
mise run lint 2>&1 | tail -1
bash scripts/check-templates.sh 2>&1 | tail -1
mise -C ~ tasks validate 2>&1 | tail -1
for set in linux linux,owned,host,wsl linux,owned,host,native; do
  MISE_ENV=$set mise -C ~ bootstrap plan --json 2>/dev/null | jq -S 'del(.summary)' | md5sum
done | diff /tmp/claude-1000/pr-a-plan-before.txt - && echo "Linux bootstrap plan unchanged"
git diff --stat main..HEAD
```

Expected:
- all pass
- `Linux bootstrap plan unchanged`
- the diff touches only:
  - `config.windows.toml`
  - the winget `settings.json`
  - `scripts/check-invariants.sh`
  - `bootstrap.ps1`
  - `scripts/test-winget-apps.ps1`
  - `README.md`, `CLAUDE.md` and `docs/claude/verification.md`
  - the spec and this plan

- [ ] **Step 2: The live run (the user runs it).** Hand the user these commands for a Windows PowerShell window:

```powershell
git -C $env:USERPROFILE\.config\mise fetch
git -C $env:USERPROFILE\.config\mise checkout feat/windows-apps-manifest
cd $env:USERPROFILE\.config\mise; .\bootstrap.ps1
mise bootstrap packages status
winget --info | Select-String 'User Settings'
Get-Content "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"
```

Expected:
- The bootstrap prints `Installing missing GUI apps (mise bootstrap --only packages…)`, then `GUI apps installed or present`, then `SSHFS-Win present`. It installs nothing and shows no UAC prompt.
- `mise bootstrap packages status` lists eight `installed` lines.
- The winget settings file holds the `scope: user` preference.
- `winget --info` prints no settings warning.

- [ ] **Step 3: Open the PR** once the user's live output is clean.

Title: `Windows GUI apps from a declarative manifest (mise bootstrap packages + winget)`.

The body:
- lists what moved: the 8 apps in `config.windows.toml`, the winget settings dotfile, the new `Install-WingetApps`/`Install-SshfsWin`, and the lint rule
- states what was removed: the `$WingetApps` table, the per-app registry detection, and the old test's `-HostCheck` mode
- gives the verification: the tests, the lint mutations, the read-only Windows status probe, the unchanged Linux plan, and the live run
- gives the after-merge steps: switch the Windows checkout back to `main` (`git checkout main; git pull`), and use `mise bootstrap packages status` / `upgrade --manager winget` from then on

End with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
```
