# DeepSeek Harness (Windows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows bootstrap or `wsu` installs DeepSeek's official DeepSeek Harness desktop app when it's missing, after verifying it. The app then updates itself.

**Architecture:** `scripts/deepseek-harness.ps1` runs from the Windows `post-tools` hook, in the same shape as `wezterm-nightly-win`. It looks for the app in the HKCU Uninstall keys and stops there if it's present. Otherwise it reads DeepSeek's electron-updater feed, downloads the named installer with curl.exe, checks its SHA-512 and its Authenticode signer, and runs it with `/S`. It warns and exits 0 on any failure.

**Tech Stack:** Windows PowerShell 5.1 and pwsh 7, curl.exe, mise tasks/hooks, GitHub Actions (`windows-http` job), PSScriptAnalyzer.

**Spec:** `docs/superpowers/specs/2026-11-06-deepseek-harness-design.md`

## Global Constraints

- Both new `.ps1` files: ASCII only, no BOM, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, run under Windows PowerShell 5.1 and pwsh 7.
- Feed URL: `https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml`
- Installer URL prefix: `https://download.deepseek.com/dsh-desk/bin/win-x64/`
- Signer (certificate SimpleName, exact, case-sensitive): `Hangzhou DeepSeek Artificial Intelligence Co., Ltd.`
- App name (Uninstall `DisplayName`, exact): `DeepSeek Harness`
- Uninstall key: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall`
- Installer arguments: `/S`. Time limit: 900 s.
- Every line the script prints starts with `  deepseek-harness: `, and the script always exits 0.
- When the app is installed, the script makes no network request.
- Downloads use curl.exe with `scripts/wezterm-nightly.ps1`'s `Get-Url` flags.
- No winget. No `[dotfiles]` entries. No version pin.
- Never run the real installer or write the real Uninstall key from a test or from an agent. The real install is the user's step (Task 4).
- README changes land in the same commit as the behaviour they describe (Task 3).
- End every commit message with the session's attribution lines (Co-Authored-By / Claude-Session).

## Review Focus

1. **5.1 launched from pwsh 7** inherits pwsh's `PSModulePath`, and then `Get-AuthenticodeSignature`/`Get-FileHash` don't load. The install must still check the signature and refuse an unsigned file (Task 2: `script: 5.1 under pwsh's PSModulePath still checks the signature`).
2. **The feed URL returns an HTML error page or garbage**: refuse with a reason and run nothing (Task 1: `Read-Feed: refuses what is not a usable feed`).
3. **A third-party lookalike is installed** (`DeepSeek Harness Desktop`): it doesn't count as installed (Task 1: `Get-InstalledHarness: missing key, lookalike, exact name`).
4. **The installer hangs** despite `/S`: the bootstrap is held for at most the time limit, then gets a warning (Task 2: `Invoke-Installer: a hung installer times out`).
5. **A temp path with spaces** (OneDrive-style profile): the download and installer path still work (Task 2's flow cases use a `WorkDir` named `work dir`; Task 1 hashes and signature-checks `fake installer.exe`).

## Files

| File | Change | Responsibility |
|---|---|---|
| `scripts/deepseek-harness.ps1` | create | the installer step: functions + entry point |
| `scripts/test-deepseek-harness.ps1` | create | its tests (AST-imported functions + whole-script runs) |
| `scripts/check-ps.ps1` | modify `$targets` | PSScriptAnalyzer covers both files |
| `.github/workflows/lint.yml` | modify `windows-http` | run the test under 5.1 and pwsh |
| `config.windows.toml` | modify | `[tasks.deepseek-harness-win]`; append it to `post-tools` |
| `README.md` | modify | a **DeepSeek Harness.** paragraph after **Codex.**; the `-SkipToolInstall` row |
| `CLAUDE.md` | modify | one Windows invariant |
| `docs/claude/verification.md` | modify | the test recipe |

## Running the Windows test from WSL

The test runs on the Windows side, from a copy under `%TEMP%`. Reset `PSModulePath` for the outer run: on this host, WSL hands Windows processes pwsh's `PSModulePath`. The test sets up the polluted case on purpose for its own child process.

```bash
T=$(wslpath -u "$(powershell.exe -NoProfile -Command '[IO.Path]::GetTempPath()' | tr -d '\r')")/dsh-test
rm -rf "$T" && mkdir -p "$T/scripts/lib"
cp scripts/deepseek-harness.ps1 scripts/test-deepseek-harness.ps1 "$T/scripts/" && cp scripts/lib/test-helpers.ps1 "$T/scripts/lib/"
W=$(wslpath -w "$T/scripts/test-deepseek-harness.ps1")
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$env:PSModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Machine'); & '$W'; exit \$LASTEXITCODE"
cd /mnt/c && powershell.exe -NoProfile -Command "pwsh -NoProfile -ExecutionPolicy Bypass -File '$W'; exit \$LASTEXITCODE"
```

Pass means each run ends with `deepseek-harness checks passed on PowerShell <version>` and exits 0.

---

### Task 1: Feed, hash, signer and install-state checks

**Files:**
- Create: `scripts/deepseek-harness.ps1` (header comment, `param` block, `Write-Step`, the four functions below; no entry point yet)
- Create: `scripts/test-deepseek-harness.ps1`

**Interfaces:**
- Produces (all in `scripts/deepseek-harness.ps1`; defaults are literals, not script variables, so the AST import works):
  - `Read-Feed([string]$Text, [string]$Prefix) -> [pscustomobject]@{ Version=[string]; Url=[string]; Sha512=[string] }`. It throws `[string]` details: `no version`, `no path`, `no sha512`, `bad version '<v>'`, `installer URL '<u>' is outside <prefix> or isn't one .exe`, `sha512 isn't a base64 SHA-512`.
  - `Test-Sha512([string]$Path, [string]$Expected) -> [bool]` (base64, ordinal compare)
  - `Test-Signer([string]$Path, [string]$Expected = 'Hangzhou DeepSeek Artificial Intelligence Co., Ltd.') -> [pscustomobject]@{ Ok=[bool]; Status=[string]; Signer=[string] }`
  - `Get-InstalledHarness([string]$Key, [string]$Name = 'DeepSeek Harness') -> $null | [pscustomobject]@{ Version=[string]; Name=[string] }` (`Name` is the subkey name, e.g. the guid)
  - `Write-Step([string]$Message)` prints `  deepseek-harness: $Message`.
  - Script `param`: `[string]$FeedUrl = '<feed URL>'`, `[string]$InstallerPrefix = '<prefix>'`, `[string]$UninstallKey = '<uninstall key>'`, `[string]$WorkDir = [IO.Path]::GetTempPath()`, `[int]$TimeoutSec = 900`.

- [ ] **Step 0: Branch and commit the design docs**

```bash
git switch -c deepseek-harness
git add docs/superpowers/specs/2026-11-06-deepseek-harness-design.md docs/superpowers/plans/2026-11-06-deepseek-harness.md
git commit -m "docs: DeepSeek Harness (Windows) design and plan"
```

- [ ] **Step 1: Write the failing tests**

`scripts/test-deepseek-harness.ps1` starts the way `scripts/test-wezterm-nightly.ps1` does: a header comment listing the cases, StrictMode, a dot-source of `lib\test-helpers.ps1`, `$script = Join-Path $PSScriptRoot 'deepseek-harness.ps1'`, `$shell = (Get-Process -Id $PID).Path`, and `$ast = Read-ScriptAst $script`. It then imports the functions with `. (Import-AstFunction $ast 'Read-Feed', 'Test-Sha512', 'Test-Signer', 'Get-InstalledHarness')`. Fixtures:

```powershell
$tmp = New-TestTempDir 'deepseek-harness-'
$work = Join-Path $tmp 'work dir'            # a space, as under a OneDrive profile
$regRoot = "HKCU:\Software\workstation-test-$([guid]::NewGuid())"
$uninstall = "$regRoot\Uninstall"            # throwaway; never the real Uninstall key
$prefix = 'https://download.deepseek.com/dsh-desk/bin/win-x64/'
$liveFeed = @'
<the 14-line nightly.yml from the spec's "Facts" section, verbatim, indentation included>
'@
function Get-B64Sha512([byte[]]$Bytes) { [Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash($Bytes)) }
function Assert-Throws([scriptblock]$Body, [string]$Like) {
    try { & $Body } catch { Assert ($_.Exception.Message -like $Like) "threw '$($_.Exception.Message)', wanted '$Like'"; return }
    throw "FAIL: no exception, wanted '$Like'"
}
```

Cases run inside `try { ... } finally { Remove-Item $regRoot, $tmp -Recurse -Force -ErrorAction SilentlyContinue }`, and the file ends with `Complete-Test 'deepseek-harness'`:

```powershell
Test-Case 'Read-Feed: the live feed shape' {
    $f = Read-Feed $liveFeed $prefix
    Assert ($f.Version -ceq '0.2.2-rc.1') "version $($f.Version)"
    Assert ($f.Url -ceq "${prefix}deepseek-harness-0.2.2-rc.1-win-x64.exe") "url $($f.Url)"
    Assert ($f.Sha512 -ceq 'swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==') "sha512 $($f.Sha512)"
}
Test-Case 'Read-Feed: top-level path wins over files[].url' {
    $f = Read-Feed ($liveFeed -replace '(?m)^(      )https://.*\.exe$', "`$1${prefix}other.exe") $prefix
    Assert ($f.Url -ceq "${prefix}deepseek-harness-0.2.2-rc.1-win-x64.exe") $f.Url
}
Test-Case 'Read-Feed: quoted one-line values' {
    $sha = Get-B64Sha512 ([byte[]](1, 2, 3))
    $f = Read-Feed "version: '0.3.0'`npath: `"${prefix}deepseek-harness-0.3.0-win-x64.exe`"`nsha512: $sha`n" $prefix
    Assert ($f.Version -ceq '0.3.0' -and $f.Sha512 -ceq $sha -and $f.Url -ceq "${prefix}deepseek-harness-0.3.0-win-x64.exe") 'parsed'
}
Test-Case 'Read-Feed: refuses what is not a usable feed' {
    $ok = "version: 0.3.0`npath: ${prefix}x.exe`nsha512: $(Get-B64Sha512 ([byte[]](1)))`n"
    Assert-Throws { Read-Feed '<!doctype html><html lang="en"><head><title>DeepSeek App</title></head><body></body></html>' $prefix } '*no version*'
    Assert-Throws { Read-Feed ($ok -replace '(?m)^sha512:.*$', '') $prefix } '*no sha512*'
    Assert-Throws { Read-Feed ($ok -replace '0\.3\.0', 'latest') $prefix } "*bad version*"
    foreach ($bad in 'http://download.deepseek.com/dsh-desk/bin/win-x64/x.exe', 'https://download.deepseek.com.evil.example/dsh-desk/bin/win-x64/x.exe',
                     "${prefix}../x.exe", "${prefix}x.exe?a=1", "${prefix}sub/x.exe", "${prefix}x.zip") {
        Assert-Throws { Read-Feed ($ok -replace '(?m)^path:.*$', "path: $bad") $prefix } '*outside*'
    }
    Assert-Throws { Read-Feed ($ok -replace '(?m)^sha512:.*$', 'sha512: abc') $prefix } '*SHA-512*'
}
Test-Case 'Test-Sha512: match and mismatch' {
    $p = Join-Path $tmp 'fake installer.exe'; New-TestFile $p 'fake installer'
    Assert (Test-Sha512 $p (Get-B64Sha512 ([IO.File]::ReadAllBytes($p)))) 'match'
    Assert (-not (Test-Sha512 $p (Get-B64Sha512 ([byte[]](0))))) 'mismatch'
}
Test-Case 'Test-Signer: an unsigned file is refused' {
    $p = Join-Path $tmp 'unsigned installer.exe'; New-TestFile $p 'fake installer'
    $r = Test-Signer $p
    Assert (-not $r.Ok -and $r.Status -ne 'Valid') "status $($r.Status)"
}
Test-Case 'Test-Signer: a valid signature from someone else is refused' {
    $r = Test-Signer (Join-Path $env:SystemRoot 'System32\cmd.exe')   # catalog-signed: Valid, "Microsoft Windows"
    Assert ($r.Status -eq 'Valid') "status $($r.Status)"
    Assert (-not $r.Ok) "accepted signer '$($r.Signer)'"
    Assert ($r.Signer -like '*Microsoft*') "signer '$($r.Signer)'"
}
Test-Case 'Get-InstalledHarness: missing key, lookalike, exact name' {
    Assert ($null -eq (Get-InstalledHarness $uninstall)) 'no key'
    New-Item -Path "$uninstall\{lookalike}" -Force | Out-Null
    Set-ItemProperty -Path "$uninstall\{lookalike}" -Name DisplayName -Value 'DeepSeek Harness Desktop'
    Assert ($null -eq (Get-InstalledHarness $uninstall)) 'lookalike counted'
    New-Item -Path "$uninstall\{dsh}" -Force | Out-Null
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayName -Value 'DeepSeek Harness'
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayVersion -Value '0.2.2-rc.1'
    $h = Get-InstalledHarness $uninstall
    Assert ($null -ne $h -and $h.Version -ceq '0.2.2-rc.1' -and $h.Name -ceq '{dsh}') 'exact name not found'
    Remove-Item -LiteralPath $uninstall -Recurse -Force
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run the recipe in "Running the Windows test from WSL" (5.1 leg).
Expected: the run stops at `Import-AstFunction` with `missing function(s): Read-Feed, Test-Sha512, Test-Signer, Get-InstalledHarness`, or with a missing-file error before `deepseek-harness.ps1` exists.

- [ ] **Step 3: Implement the four functions, the `param` block and `Write-Step` in `scripts/deepseek-harness.ps1`**

- Header comment in `wezterm-nightly.ps1`'s style. Say why it isn't winget (third-party repackages), name the feed and the two checks, say the app updates itself, say every failure warns and exits 0, and point to `scripts/test-deepseek-harness.ps1`.
- `Read-Feed`: read only top-level lines (`^(version|path|sha512):\s*(.*)$`, no leading whitespace), so `files:` entries are ignored. When the value is `>-`, `>`, `|` or `|-`, take the following lines indented deeper than column 0 and join them with `' '` after trimming. Strip one pair of surrounding `'` or `"`. Then validate:
  - Version: `^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$`
  - Url: `StartsWith($Prefix, [StringComparison]::Ordinal)`, and the rest must match `^[A-Za-z0-9._-]+\.exe$` and must not contain `..`.
  - Sha512: `[Convert]::FromBase64String` succeeds and yields 64 bytes.
- `Test-Sha512`: hash a `[IO.File]::OpenRead` stream with `[Security.Cryptography.SHA512]::Create()`. Don't use `Get-FileHash`; see Review Focus 1.
- `Test-Signer`: call `Get-AuthenticodeSignature -LiteralPath`. Status is `"$($s.Status)"`. Signer is `$s.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)`, or `''` when there's no certificate. `Ok = Status -eq 'Valid' -and Signer -ceq $Expected`.
- `Get-InstalledHarness`: return `$null` when `$Key` doesn't exist. Otherwise take the first subkey whose `DisplayName` is `-ceq $Name`. `Version` is `DisplayVersion`, or `''` when it's absent.

- [ ] **Step 4: Run the tests and see them pass**

Run the recipe, both legs. Expected: 8 `ok` lines, then `deepseek-harness checks passed on PowerShell 5.1.x`, and the same on 7.x.

- [ ] **Step 5: Commit**

```bash
git add scripts/deepseek-harness.ps1 scripts/test-deepseek-harness.ps1
git commit -m "deepseek-harness: feed, SHA-512, signer and install-state checks"
```

---

### Task 2: Install flow, entry point and CI

**Files:**
- Modify: `scripts/deepseek-harness.ps1` (add `Get-Url`, `Invoke-Installer`, `Install-Harness`, the `PSModulePath` reset and the entry point)
- Modify: `scripts/test-deepseek-harness.ps1`
- Modify: `scripts/check-ps.ps1` (`$targets`: add `'scripts/deepseek-harness.ps1'` and `'scripts/test-deepseek-harness.ps1'` after the WezTerm pair)
- Modify: `.github/workflows/lint.yml` (`windows-http`: after the two "Test WezTerm nightly installer" steps, add "Test DeepSeek Harness installer (Windows PowerShell 5.1)" and "(pwsh)", both `if: always()`, `run: ./scripts/test-deepseek-harness.ps1`)

**Interfaces:**
- Consumes: Task 1's `Read-Feed`, `Test-Sha512`, `Test-Signer`, `Get-InstalledHarness`, `Write-Step`, and the script `param` block.
- Produces:
  - `Get-Url([string]$Uri, [string]$OutFile)`: a copy of `wezterm-nightly.ps1`'s; it throws `curl.exe exit <n> for <uri>: <stderr>`.
  - `Invoke-Installer([string]$Path, [string[]]$ArgumentList = @('/S'), [int]$TimeoutSec = 900) -> [int]` (exit code). On timeout it throws `the installer didn't finish within <n> s (it may still be running)` and leaves the process running.
  - `Install-Harness([string]$FeedUrl, [string]$Prefix, [string]$UninstallKey, [string]$WorkDir, [int]$TimeoutSec = 900) -> [pscustomobject]@{ State = 'present'|'installed'; Version=[string] }`. It throws:
    - `the update feed <FeedUrl> isn't usable: <Read-Feed or curl detail>`
    - `the installer's SHA-512 doesn't match the feed's`
    - `the installer isn't signed by Hangzhou DeepSeek Artificial Intelligence Co., Ltd. (status <Status>, signer '<Signer>')`
    - `the installer exited <code>`
    - `the installer exited 0 but Windows lists no DeepSeek Harness`
  - Entry-point output: `DeepSeek Harness <v> is installed; it updates itself` | `installed DeepSeek Harness <v>; it updates itself from now on` | `not installed: <exception message>`. Each line goes through `Write-Step`, then `exit 0`.

- [ ] **Step 1: Write the failing tests**

Extend the import to `'Read-Feed', 'Test-Sha512', 'Test-Signer', 'Get-InstalledHarness', 'Write-Step', 'Get-Url', 'Invoke-Installer', 'Install-Harness'`. Add these helpers next to Task 1's fixtures, and append the cases below after Task 1's cases, inside the same `try`:

```powershell
$script:installs = New-Object System.Collections.Generic.List[string]
$script:installReply = @{ Exit = 0; Register = $true }
$script:signerOk = $true
function New-Feed([string]$Name, [byte[]]$Installer, [string]$Sha) {   # fixtures live under $tmp (no space: curl file:// URLs)
    $dir = Join-Path $tmp $Name
    $exe = Join-Path $dir 'bin\deepseek-harness-0.2.2-rc.1-win-x64.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
    [IO.File]::WriteAllBytes($exe, $Installer)
    $bin = 'file:///' + ((Join-Path $dir 'bin') -replace '\\', '/') + '/'
    if (-not $Sha) { $Sha = Get-B64Sha512 $Installer }
    New-TestFile (Join-Path $dir 'feeds\nightly.yml') "version: 0.2.2-rc.1`npath: ${bin}deepseek-harness-0.2.2-rc.1-win-x64.exe`nsha512: $Sha`n"
    [pscustomobject]@{ FeedUrl = 'file:///' + ((Join-Path $dir 'feeds\nightly.yml') -replace '\\', '/'); Prefix = $bin }
}
function Register-Fake { New-Item -Path "$uninstall\{dsh}" -Force | Out-Null
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayName -Value 'DeepSeek Harness'
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayVersion -Value '0.2.2-rc.1' }
function Reset-Flow { $script:installs.Clear(); $script:installReply = @{ Exit = 0; Register = $true }; $script:signerOk = $true
    Remove-Item -LiteralPath $uninstall -Recurse -Force -ErrorAction SilentlyContinue; New-Item -Path $uninstall -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $work | Out-Null }
function Get-WorkLeft { @(Get-ChildItem -LiteralPath $work -Force).Count }
function Invoke-Script([string]$FeedUrl, [string]$Prefix, [string]$Exe = $shell) {
    $out = & $Exe -NoProfile -ExecutionPolicy Bypass -File $script -FeedUrl $FeedUrl -InstallerPrefix $Prefix -UninstallKey $uninstall -WorkDir $work 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
$missingFeed = 'file:///' + ($tmp -replace '\\', '/') + '/missing.yml'
```

Cases for the real `Invoke-Installer`, then whole-script runs (the child process has the real functions):

```powershell
Test-Case 'Invoke-Installer: returns the exit code' {
    Assert ((Invoke-Installer -Path $shell -ArgumentList '-NoProfile', '-Command', 'exit 3' -TimeoutSec 60) -eq 3) 'exit code'
}
Test-Case 'Invoke-Installer: a hung installer times out' {
    $t = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throws { Invoke-Installer -Path $shell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 5' -TimeoutSec 1 } "*didn't finish within 1 s*"
    Assert ($t.Elapsed.TotalSeconds -lt 4) "took $($t.Elapsed.TotalSeconds) s"
}
Test-Case 'script: an unreachable feed warns and exits 0' {
    Reset-Flow; $r = Invoke-Script -FeedUrl $missingFeed -Prefix 'file:///nowhere/'
    Assert ($r.Code -eq 0) "exit $($r.Code)"; Assert ($r.Out -match '  deepseek-harness: not installed: ') $r.Out
}
Test-Case 'script: installed already prints and exits 0' {
    Reset-Flow; Register-Fake; $r = Invoke-Script -FeedUrl $missingFeed -Prefix 'file:///nowhere/'
    Assert ($r.Code -eq 0 -and $r.Out -match 'DeepSeek Harness 0\.2\.2-rc\.1 is installed; it updates itself') $r.Out
}
Test-Case "script: 5.1 under pwsh's PSModulePath still checks the signature" {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $mods = @($(if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'Modules' }), (Join-Path $env:ProgramFiles 'PowerShell\7\Modules')) |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'Microsoft.PowerShell.Security')) } | Select-Object -First 1
    if (-not $mods) { Write-Host '  skip  no pwsh 7 modules on this host'; return }
    Reset-Flow; $f = New-Feed 'unsigned' ([Text.Encoding]::ASCII.GetBytes('fake installer'))
    $old = $env:PSModulePath
    try { $env:PSModulePath = "$mods;$old"; $r = Invoke-Script -FeedUrl $f.FeedUrl -Prefix $f.Prefix -Exe $ps51 } finally { $env:PSModulePath = $old }
    Assert ($r.Code -eq 0) "exit $($r.Code)"
    Assert ($r.Out -match "isn't signed by Hangzhou DeepSeek") $r.Out
    Assert ($r.Out -notmatch 'could not be loaded|is not recognized') $r.Out
}
```

Then stub `Test-Signer` and `Invoke-Installer`. The later definitions win, and `Install-Harness` resolves names at call time:

```powershell
function Test-Signer([string]$Path) { [pscustomobject]@{ Ok = $script:signerOk; Status = 'Valid'; Signer = 'stub' } }
function Invoke-Installer([string]$Path, [string[]]$ArgumentList = @('/S'), [int]$TimeoutSec = 900) {
    $script:installs.Add("$Path|$($ArgumentList -join ' ')"); if ($script:installReply.Register) { Register-Fake }; return $script:installReply.Exit }
$fake = [Text.Encoding]::ASCII.GetBytes('fake installer')

Test-Case 'Install-Harness: installed already means no download' {
    Reset-Flow; Register-Fake
    $r = Install-Harness -FeedUrl $missingFeed -Prefix 'file:///nowhere/' -UninstallKey $uninstall -WorkDir $work
    Assert ($r.State -eq 'present' -and $r.Version -ceq '0.2.2-rc.1') "$($r.State)"; Assert ($script:installs.Count -eq 0) 'installer ran'
}
Test-Case 'Install-Harness: installs a verified build' {
    Reset-Flow; $f = New-Feed 'good' $fake
    $r = Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work
    Assert ($r.State -eq 'installed' -and $r.Version -ceq '0.2.2-rc.1') "$($r.State)"
    Assert ($script:installs.Count -eq 1 -and $script:installs[0] -like "$work\*\deepseek-harness-0.2.2-rc.1-win-x64.exe|/S") "$($script:installs)"
    Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
}
Test-Case 'Install-Harness: a SHA-512 mismatch runs nothing' {
    Reset-Flow; $f = New-Feed 'badsha' $fake (Get-B64Sha512 ([byte[]](0)))
    Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work } "*SHA-512 doesn't match*"
    Assert ($script:installs.Count -eq 0) 'installer ran'; Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
}
Test-Case 'Install-Harness: another signer runs nothing' {
    Reset-Flow; $script:signerOk = $false; $f = New-Feed 'badsig' $fake
    Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work } "*isn't signed by Hangzhou DeepSeek Artificial Intelligence Co., Ltd.*"
    Assert ($script:installs.Count -eq 0) 'installer ran'; Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
}
Test-Case 'Install-Harness: a failing installer is reported' {
    Reset-Flow; $script:installReply = @{ Exit = 2; Register = $false }; $f = New-Feed 'exit2' $fake
    Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work } '*installer exited 2*'
}
Test-Case 'Install-Harness: exit 0 without a listing is reported' {
    Reset-Flow; $script:installReply = @{ Exit = 0; Register = $false }; $f = New-Feed 'unlisted' $fake
    Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work } '*lists no DeepSeek Harness*'
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run the recipe (5.1 leg). Expected: `missing function(s): Get-Url, Invoke-Installer, Install-Harness`.

- [ ] **Step 3: Implement in `scripts/deepseek-harness.ps1`**

- Right after `Set-StrictMode`/`$ErrorActionPreference`, add `if ($PSVersionTable.PSEdition -ne 'Core') { $env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine') }`, with a comment explaining Review Focus 1. On this host it restored `Get-AuthenticodeSignature`.
- `Get-Url`: copy `wezterm-nightly.ps1`'s function.
- `Invoke-Installer`: `Start-Process -FilePath $Path -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden`, then `$null = $p.Handle` right away (without it, 5.1's `ExitCode` is `$null`), then `if (-not $p.WaitForExit($TimeoutSec * 1000)) { throw ... }`, then return `$p.ExitCode`.
- `Install-Harness`:
  1. Call `Get-InstalledHarness`. If it finds the app, return `present` and make no request.
  2. Create `Join-Path $WorkDir ('deepseek-harness-' + [guid]::NewGuid())` and remove it in `finally`.
  3. Fetch the feed with `Get-Url` and read it with `Read-Feed`. Wrap any failure from either in the "update feed isn't usable" message.
  4. Download the installer to `<that folder>\<leaf of Url>`.
  5. Check `Test-Sha512`, then `Test-Signer`.
  6. Run `Invoke-Installer`. A nonzero exit throws.
  7. Call `Get-InstalledHarness` again. If the app isn't there, throw. Otherwise return `installed` with the feed's version.
- Entry point: `try { $r = Install-Harness ...; Write-Step <present|installed line> } catch { Write-Step "not installed: $($_.Exception.Message)" }; exit 0`.

- [ ] **Step 4: Run the tests and see them pass**

Run the recipe, both legs. Expected: 19 `ok` lines (the PSModulePath case may print `skip`), then `deepseek-harness checks passed on PowerShell 5.1.x`, and the same on 7.x.

- [ ] **Step 5: Lint the PowerShell**

Run (Windows side, PSScriptAnalyzer installed): `cd /mnt/c && powershell.exe -NoProfile -Command "pwsh -NoProfile -File '$(wslpath -w scripts/check-ps.ps1)'"`. That's the same script as `mise run ps-lint` and CI's `powershell` job.
Expected: exit 0 with no findings. If PSScriptAnalyzer isn't installed (exit 2 with that message), say so in the PR and let CI's `powershell` job run it.

- [ ] **Step 6: Commit**

```bash
git add scripts/deepseek-harness.ps1 scripts/test-deepseek-harness.ps1 scripts/check-ps.ps1 .github/workflows/lint.yml
git commit -m "deepseek-harness: verified silent install from DeepSeek's nightly feed"
```

---

### Task 3: Wire it into the Windows bootstrap, and document it

**Files:**
- Modify: `config.windows.toml`: add a task after `[tasks.wezterm-nightly-win]`, and append `::: deepseek-harness-win` to `[bootstrap.hooks] post-tools`.
- Modify: `README.md`: add a paragraph after **Codex.** (around line 374), and extend the `-SkipToolInstall` row (around line 145).
- Modify: `CLAUDE.md`: add one line in **Windows** invariants.
- Modify: `docs/claude/verification.md`: add an installer recipe line after the WezTerm installer bullet.

**Interfaces:**
- Consumes: `scripts/deepseek-harness.ps1` with its default parameters (Task 2).
- Produces: `mise run deepseek-harness-win` on Windows.

- [ ] **Step 1: Add the task and hook**

```toml
# DeepSeek Harness's desktop app (DeepSeek's agent harness), per-user without UAC. Installed only
# when Windows doesn't list it; from then on its own updater keeps it current (nightly channel).
# Not winget: every "DeepSeek Harness" package there is a third-party repackage.
# scripts/deepseek-harness.ps1 checks the installer against the SHA-512 in DeepSeek's update feed
# and DeepSeek's code-signing certificate before it runs it.
[tasks.deepseek-harness-win]
description = "Install DeepSeek Harness's desktop app when it's missing (the post-tools hook); it updates itself"
dir = "{{ xdg_config_home }}/mise"
run = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/deepseek-harness.ps1 || exit /b 0"
```

`post-tools` becomes `"mise run tool-env-win ::: nu-init ::: nvim-plugins-win ::: claude-skills-win ::: claude-settings-win ::: wezterm-nightly-win ::: deepseek-harness-win"`.

- [ ] **Step 2: Check the config**

Run: `mise run lint && bash scripts/check-templates.sh`
Expected: both exit 0. (`check_bootstrap_config` still sees `tool-env-win` in `post-tools`, and the Windows render includes the new task.)

- [ ] **Step 3: Write the docs**

- README **DeepSeek Harness.** paragraph (Windows only), with these points:
  - [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) is DeepSeek's open-source agent harness. On Windows its desktop app opens from the Start Menu.
  - The post-tools hook (`bootstrap.ps1`, `ws update`) installs it per-user without UAC, only when Windows doesn't list it.
  - The installer comes from DeepSeek's nightly update feed. The script refuses one whose SHA-512 doesn't match the feed's or that isn't signed by Hangzhou DeepSeek Artificial Intelligence Co., Ltd.
  - From then on the app updates itself on the nightly channel: preview builds, and breaking changes are expected.
  - It's not installed from winget: the winget packages with that name are third-party.
  - Uninstalling it from Settings > Apps lasts only until the next `ws update`, which installs it again.
  - The app's settings are its own; the repo leaves them alone.
  - Linux and the `dsh` CLI (`npx @deepseek-ai/dsh web`) aren't set up.
- `-SkipToolInstall` row: "... the archify skill copy, the WezTerm nightly install and the DeepSeek Harness install, doesn't run either".
- CLAUDE.md, Windows: `- DeepSeek Harness: \`scripts/deepseek-harness.ps1\` (post-tools) installs the official desktop app only when Windows doesn't list it, from \`dsh-desk/feeds/win-x64/nightly.yml\` (its SHA-512, then the Hangzhou DeepSeek Authenticode signer); the app self-updates. Never winget: those ids are third-party repackages. A 5.1 child of pwsh inherits pwsh's PSModulePath and can't autoload core modules, so the script resets it.`
- verification.md: `- DeepSeek Harness installer: \`scripts/test-deepseek-harness.ps1\` under \`powershell.exe\` and pwsh, from a copy under \`%TEMP%\` with \`lib/test-helpers.ps1\`. Its Uninstall key is a throwaway HKCU path, and it never runs a real installer. Never run \`deepseek-harness.ps1\` with its defaults from an agent: that installs the real app.`

- [ ] **Step 4: Re-run the checks**

Run: `mise run lint && bash scripts/check-templates.sh`
Expected: both exit 0.

- [ ] **Step 5: Commit**

```bash
git add config.windows.toml README.md CLAUDE.md docs/claude/verification.md
git commit -m "tools: install DeepSeek Harness's desktop app on Windows"
```

---

### Task 4: Real-host check (the user's) and PR

**Files:** none.

- [ ] **Step 1: Hand the real install to the user.** Ask them to run this in a Windows PowerShell window. It installs the real app, which is why an agent doesn't run it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\AlmaLinux-9\home\arrush.chaturvedi\.config\mise\scripts\deepseek-harness.ps1
```

Expected first run: `  deepseek-harness: installed DeepSeek Harness 0.2.2-rc.1; it updates itself from now on` (or a newer version), and "DeepSeek Harness" appears in the Start Menu.
Expected second run: `  deepseek-harness: DeepSeek Harness <v> is installed; it updates itself`, within about a second.
If the first run says `the installer exited 0 but Windows lists no DeepSeek Harness`, have them run
`Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall | Get-ItemProperty | Where-Object DisplayName -like '*DeepSeek*' | Select-Object DisplayName, DisplayVersion, InstallLocation`
and fix the `$Name` default in `Get-InstalledHarness` (plus the spec's Facts) to the real `DisplayName`. Then re-run Task 1's tests.

- [ ] **Step 2: Push and open the PR** (only when the user says to): `git push -u origin deepseek-harness`, then `gh pr create` with a body summarising the spec's Goals/Anti-goals, the Review Focus and the real-host result. Wait for the `windows-http` and `powershell` jobs to pass.
