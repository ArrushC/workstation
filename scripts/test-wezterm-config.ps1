# Loads dotfiles/config/wezterm/wezterm.lua in the real WezTerm nightly (`wezterm.exe
# show-keys`, no window) and checks WezTerm kept it. A config that fails to load, an unknown
# field included (config_builder raises on one), still exits 0 and lists WezTerm's default
# keys, so the check is that ours are listed and the defaults the config releases aren't.
# scripts/check-invariants.sh (check_wezterm_config) runs the event handlers; this catches
# what its stand-in can't: a field or action the nightly renamed or dropped.
# -WezTerm takes an installed wezterm.exe. Without it, scripts/wezterm-nightly.ps1 installs
# the nightly into a temp root (no Start Menu entry, throwaway toast-id and environment keys).
# Windows PowerShell 5.1 and pwsh; ASCII only.
param([string]$WezTerm)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$config = Join-Path $PSScriptRoot '..\dotfiles\config\wezterm\wezterm.lua'
$tmp = New-TestTempDir 'wezterm-config-'
$toastRoot = "HKCU:\Software\workstation-test-$([guid]::NewGuid())"

try {
    if (-not $WezTerm) {
        $shell = (Get-Process -Id $PID).Path
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'wezterm-nightly.ps1') `
            -Root (Join-Path $tmp 'wezterm') -ShortcutDir (Join-Path $tmp 'menu') `
            -ToastKey "$toastRoot\org.wezfurlong.wezterm" -EnvKey "$toastRoot\Environment" | Out-Host
        $WezTerm = Join-Path $tmp 'wezterm\current\wezterm.exe'
    }
    if (-not (Test-Path -LiteralPath $WezTerm)) { throw "no $WezTerm (the nightly download failed?)" }
    $version = (& $WezTerm --version 2>&1 | Out-String).Trim()
    $keys = & $WezTerm --config-file $config show-keys 2>&1 | Out-String

    Test-Case "WezTerm ($version) loads wezterm.lua: its keys and mouse bindings are listed" {
        foreach ($want in @(
                'ALT \| CTRL\s+l\s+->\s+ShowLauncherArgs',
                'CTRL\s+G\s+->\s+QuickSelectArgs',
                'CTRL\s+A\s+->\s+Multiple\(\[ActivateCopyMode',
                'CTRL\s+UpArrow\s+->\s+ScrollToPrompt\(-1\)',
                'SHIFT \| CTRL\s+UpArrow\s+->\s+ScrollToPrompt\(-1\)',
                'CTRL\s+Insert\s+->\s+EmitEvent',
                'CTRL\s+T\s+->\s+EmitEvent',
                'ALT\s+D\s+->\s+EmitEvent',
                'SUPER\s+Drag \{ streak: 1, button: Left \}\s+->\s+StartWindowDrag',
                'SHIFT\s+Down \{ streak: 1, button: Left \}\s+->\s+SelectTextAtMouseCursor\(Cell\)',
                'CTRL\s+W\s+->\s+CloseCurrentTab \{ confirm: false \}',
                'CTRL\s+Q\s+->\s+PaneSelect',
                'ALT\s+S\s+->\s+ActivateKeyTable \{ name: "resize_pane"',
                'Key Table: resize_pane',
                'CTRL\s+Up \{ streak: 1, button: Left \}\s+->\s+OpenLinkAtMouseCursor',
                'CTRL\s+Down \{ streak: 3, button: Left \}\s+->\s+SelectTextAtMouseCursor\(SemanticZone\)',
                '\n\s+Up \{ streak: 1, button: Left \}\s+->\s+Multiple\(\[CompleteSelection\(ClipboardAndPrimarySelection\)'
            )) {
            Assert ($keys -match $want) "show-keys lacks /$want/ (did the config fail to load?)`n$keys"
        }
    }
    Test-Case 'Ctrl+Shift+Left/Right reach the shell (the pane-move defaults are gone)' {
        Assert ($keys -notmatch 'SHIFT \| CTRL\s+(LeftArrow|RightArrow)\s+->') 'show-keys still binds Ctrl+Shift+Left/Right'
    }
} finally {
    $current = Join-Path $tmp 'wezterm\current'
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toastRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'wezterm-config'
