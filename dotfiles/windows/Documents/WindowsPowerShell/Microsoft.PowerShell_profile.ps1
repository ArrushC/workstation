# =============================================================================
# Windows PowerShell 5.1 profile — managed by mise dotfiles (dot-sources the PS 7 profile below)
#
# We keep one canonical profile under Documents\PowerShell\ (PS 7) and
# dot-source it from here so PS 5.1 (the default `powershell.exe`) gets the
# same aliases, prompt, and helpers. Most of the logic is PS-version-portable;
# anything that needs a 5.1-only path can be guarded with $PSVersionTable.
# =============================================================================

$ps7Profile = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
if (Test-Path $ps7Profile) {
    . $ps7Profile
}
