# =============================================================================
# bootstrap.ps1 -- workstation setup (Windows client side)
#
# No admin rights needed: installs mise + a few first-party binaries
# per-user (%LOCALAPPDATA%\workstation), seeds Warp + Windows Terminal via
# WinGet, then runs `mise bootstrap --only dotfiles,tools` to deploy the
# tracked dotfiles and install the runtime tools those files declare.
# Windows is always the `owned` mode (MISE_ENV=windows,owned). Git is a
# hard prerequisite (install it yourself); Zed/VSCode are hand-installed --
# their dotfiles still deploy without them.
#
# ONE exception to "no admin": $ElevatedTools (SSHFS-Win + its WinFsp
# kernel-driver dependency) can pop a UAC prompt on first install. Declining
# it (or -SkipElevated) soft-fails only that step.
#
# Public repo, no token needed. $env:GITHUB_TOKEN is optional: lifts the
# 60-req/hr anonymous GitHub API rate limit; used for a private-fork clone.
#
# Bootstrap a fresh machine (no elevation needed):
#   $curl = Get-Command curl.exe -CommandType Application | Select-Object -First 1
#   & $curl.Source --disable --fail --silent --show-error --location `
#     --output "$env:TEMP\bootstrap.ps1" `
#     https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1
#   & ([scriptblock]::Create([IO.File]::ReadAllText("$env:TEMP\bootstrap.ps1")))
#
# Or clone + run:
#   git clone https://github.com/ArrushC/workstation.git "$env:USERPROFILE\.config\mise"
#   cd "$env:USERPROFILE\.config\mise"; .\bootstrap.ps1
#
# Flags (see param() below): -RepoPath -SkipKeyGen -SkipToolInstall
#   -SkipDotfiles -SkipBurntToast -SkipNerdFonts -ForceInstaller
#   -SkipElevated -Reinstall -Yes -Doctor -CheckForUpdates
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:USERPROFILE ".config\mise"),
    [switch]$SkipKeyGen,       # skip the SSH-key generation prompt
    [switch]$SkipToolInstall,  # skip all portable/installer tool installs + Claude Code
    [switch]$SkipDotfiles,     # clone + install tools but don't apply dotfiles yet
    [switch]$SkipBurntToast,   # skip the BurntToast PSGallery module install
    [switch]$SkipNerdFonts,    # skip the Nerd Font install
    [switch]$ForceInstaller,   # re-seed installer-class + Warp/Windows Terminal installs even if present
    [switch]$SkipElevated,     # skip SSHFS-Win/WinFsp (the only step that can pop UAC)
    [switch]$Reinstall,        # wipe the cloned repo, then re-bootstrap (prompts unless -Yes)
    [switch]$Yes,              # skip confirmation prompts (-Reinstall)
    [switch]$Doctor,           # read-only health report, then exit -- installs nothing
    [switch]$CheckForUpdates   # read-only update scan vs upstream tags, then exit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# CONSTANTS & TOOL TABLES -- repo/install paths and the pinned or
# latest-release tool manifests everything below reads from.
# =============================================================================

$DotfilesRepo = "https://github.com/ArrushC/workstation.git"
$SshKey       = "$env:USERPROFILE\.ssh\id_ed25519"

# Token persisted into .git/config under this key — scoped to github.com so
# it never leaks to other remotes.
$GhHeaderKey = "http.https://github.com/.extraheader"

# Per-user install root for every binary this script provisions. Admin-free:
#   workstation\bin          — single-exe tools (starship, gh, jq)   → on User PATH
#   workstation\helix        — the multi-file Helix portable tree    → on User PATH
#   workstation\nu           — the multi-file Nushell portable tree  → on User PATH
#   workstation\devtoys-cli  — the DevToys CLI portable tree         → on User PATH
#   workstation\dngrep       — the dnGrep portable GUI tree          → on User PATH
#   workstation\logexpert    — the LogExpert portable GUI tree       → on User PATH
#   workstation\mise         — the mise portable tree (bin\mise.exe + mise-shim.exe) → bin\ on User PATH
#   workstation\stamps       — "<exe>.<version>.stamp" idempotency markers
$WsRoot       = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin        = Join-Path $WsRoot "bin"
$WsHelix      = Join-Path $WsRoot "helix"
$WsNu         = Join-Path $WsRoot "nu"
$WsDevToysCli = Join-Path $WsRoot "devtoys-cli"
$WsDnGrep     = Join-Path $WsRoot "dngrep"
$WsLogExpert  = Join-Path $WsRoot "logexpert"
$WsMise       = Join-Path $WsRoot "mise"
$WsStamps     = Join-Path $WsRoot "stamps"

# Pinned portable tools: version + sha256 live HERE (same pattern as
# scripts\install-nerd-fonts.ps1), not in a Linux config*.toml -- mise's
# Linux-side [bootstrap.*] tables never run on Windows. Bump = update
# Version + refresh Sha256. Layout 'single' copies <Exe>.exe into Dest;
# 'tree' extracts the whole archive into Dest.
#
# Repo/Tag* keys feed -CheckForUpdates only (latest tag via git ls-remote).
# Opt-in Shortcut = @{ Target; Description } makes Invoke-StartMenuShortcuts
# drop a per-user Start Menu .lnk for a GUI tool with none in its zip.
# Opt-in BinSubdir points the User PATH at a nested bin dir instead of Dest
# (only mise needs it: mise\bin\mise.exe + mise-shim.exe).
$PortableTools = @(
    @{
        Name       = "Starship"
        Exe        = "starship"
        Version    = "1.25.1"
        Url        = "https://github.com/starship/starship/releases/download/v1.25.1/starship-x86_64-pc-windows-msvc.zip"
        Sha256     = "a07cf3e428afab09324e510fb786041ebcc491a68b1ca6fba044c5a461f9b017"
        Layout     = "single"
        Dest       = $WsBin
        Repo       = "starship/starship"
        TagPrefix  = "v"
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools"
    },
    @{
        Name       = "GitHub CLI"
        Exe        = "gh"
        Version    = "2.101.0"
        Url        = "https://github.com/cli/cli/releases/download/v2.101.0/gh_2.101.0_windows_amd64.zip"
        Sha256     = "bc6c814367b193cd8e713611d61e36013c0ef843b8f516458fe3eda039192794"
        Layout     = "single"
        Dest       = $WsBin
        Repo       = "cli/cli"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND tools.gh in config.linux.toml"
    },
    @{
        Name       = "Helix"
        Exe        = "hx"
        Version    = "25.07.1"
        Url        = "https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip"
        Sha256     = "5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6"
        Layout     = "tree"
        Dest       = $WsHelix
        Repo       = "helix-editor/helix"
        TagPrefix  = ""
        UpdateHint = "dual-edit: `$PortableTools here AND tools.helix in config.linux.toml"
    },
    @{
        # Nushell — the default LOCAL Windows shell (the Windows Terminal
        # "Nushell" profile points at this install).
        # Pre-1.0 and churny: bump deliberately and upgrade INCREMENTALLY (the
        # pin/stamp model here is exactly the "pin it, read the changelog" hygiene
        # Nushell's 0.x cadence needs). Tags are bare "0.113.1" (no prefix).
        Name       = "Nushell"
        Exe        = "nu"
        Version    = "0.113.1"
        Url        = "https://github.com/nushell/nushell/releases/download/0.113.1/nu-0.113.1-x86_64-pc-windows-msvc.zip"
        Sha256     = "fd3e56dac9f866d2d3fe2fabd6580c14371afdcec9ddda54624a50986d36b3d2"
        Layout     = "tree"   # zip bundles nu.exe + nu_plugin_*.exe
        Dest       = $WsNu
        Repo       = "nushell/nushell"
        TagPrefix  = ""
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools — pre-1.0: READ the release's Breaking-changes section and upgrade incrementally (skipping releases can break config.nu)"
    },
    @{
        Name       = "jq"
        Exe        = "jq"
        Version    = "1.8.2"
        Url        = "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe"
        Sha256     = "a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627"
        Layout     = "exe"
        Dest       = $WsBin
        Repo       = "jqlang/jq"
        TagPrefix  = "jq-"
        UpdateHint = "dual-edit: `$PortableTools here AND tools.jq in config.linux.toml (jq powers the Claude Code hooks' JSON parsing on Windows)"
    },
    @{
        # mise — the runtime manager (node / Go / uv / gopls / the LSP
        # servers): the Windows half of the Linux both-scopes EGET_TOOL. The
        # zip nests mise\bin\mise.exe + mise-shim.exe (the template mise
        # copies for native .exe shims — without it shims degrade to .cmd
        # wrappers), so 'tree' into its OWN dir with BinSubdir pointing the
        # PATH at bin\. WHAT mise installs is declared by config.toml +
        # config.owned.toml at the root of the checkout — %USERPROFILE%\.config\mise
        # IS the checkout, read directly by Invoke-MiseRuntimes after the
        # dotfiles+tools bootstrap. uv is one of those tools now.
        Name       = "mise"
        Exe        = "mise"
        Version    = "2026.9.9"
        Url        = "https://github.com/jdx/mise/releases/download/v2026.9.9/mise-v2026.9.9-windows-x64.zip"
        Sha256     = "f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07"
        Layout     = "tree"
        BinSubdir  = "bin"
        Dest       = $WsMise
        Repo       = "jdx/mise"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND MISE_VERSION in bootstrap.sh AND min_version in config.toml"
    },
    @{
        # OpenCode + Oh My Pi — AI coding agents; the Windows halves of the
        # Linux dev-only mise tools (see config.owned.toml's opencode / omp
        # entries). Bun-compiled x64 binaries: both REQUIRE AVX2
        # (any CPU since ~2013).
        Name       = "OpenCode"
        Exe        = "opencode"
        Version    = "1.18.32"
        Url        = "https://github.com/anomalyco/opencode/releases/download/v1.18.32/opencode-windows-x64.zip"
        Sha256     = "1483c72d5adced825590a0ecf8cc18b3e87e535960a125dbf539d33bce135d0f"
        Layout     = "single"   # zip contains exactly one opencode.exe (starship precedent)
        Dest       = $WsBin
        Repo       = "anomalyco/opencode"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND opencode in config.owned.toml"
    },
    @{
        Name       = "Oh My Pi"
        Exe        = "omp"
        Version    = "18.2.8"
        Url        = "https://github.com/can1357/oh-my-pi/releases/download/v18.2.8/omp-windows-x64.exe"
        Sha256     = "b95431cb63b073c36c3664f6d9e2611de8d28d6e6e21ede657c8f83f0e7034b3"
        Layout     = "exe"      # bare single-.exe release asset (jq precedent)
        Dest       = $WsBin
        Repo       = "can1357/oh-my-pi"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND github:can1357/oh-my-pi in config.owned.toml"
    },
    @{
        # DevToys CLI — scriptable command-line half of DevToys; the Windows
        # half of the Linux dev-only devtoys-cli mise tool (config.owned.toml).
        # The *_portable zip is self-contained .NET (the plain zip needs a
        # system .NET 8 runtime — never use it). NOT Layout 'single': the
        # single-file DevToys.CLI.exe REQUIRES its sibling Plugins\ tree.
        # Invoked as `devtoys.cli` (Windows resolves DevToys.CLI.exe
        # case-insensitively).
        Name       = "DevToys CLI"
        Exe        = "DevToys.CLI"
        Version    = "2.0.9.0"
        Url        = "https://github.com/DevToys-app/DevToys/releases/download/v2.0.9.0/devtoys.cli_win_x64_portable.zip"
        Sha256     = "27327ad18c06d5bba4356f039c76203b0099f864d10f6de0d833225077dd310a"
        Layout     = "tree"
        Dest       = $WsDevToysCli
        Repo       = "DevToys-app/DevToys"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND the DevToys-app/DevToys tool in config.owned.toml (NOTE: this repo flags all releases prerelease — check the releases PAGE, not /latest)"
    },
    @{
        # dnGrep — search/replace GUI (grep for Windows). Portable, NOT
        # installer class: dnGrep publishes only machine-scope WiX .msi
        # installers (Scope: machine per its winget manifest → UAC, and the
        # installer class has no msiexec path anyway) plus these per-arch
        # portable zips — flat root, self-contained .NET. dnGrep stores its
        # settings NEXT TO THE EXE when that dir is writable (always true
        # here), and the 'tree' wipe on a pin bump would destroy them — so
        # step 5e (Invoke-DnGrepConfig) seeds a dnGrep.config.xml redirecting
        # its data dir to %APPDATA%\dnGREP. Windows-only GUI tool: no
        # config.toml [vars] pin, no dual-edit (Nushell precedent).
        Name       = "dnGrep"
        Exe        = "dnGREP"
        Version    = "5.0.30.0"
        Url        = "https://github.com/dnGrep/dnGrep/releases/download/v5.0.30.0/dnGrep.5.0.30.0.x64.zip"
        Sha256     = "27e79603d8a743e16ab97aa4b83b50a56061faa9c79b68bfe13b64ba9c45bd32"
        Layout     = "tree"
        Dest       = $WsDnGrep
        Repo       = "dnGrep/dnGrep"
        TagPrefix  = "v"
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools (in-app updater targets the machine-scope MSI — don't use it)"
        Shortcut   = @{ Target = "dnGREP"; Description = "dnGrep — search and replace in files (grep GUI)" }
    },
    @{
        # LogExpert — tabbed log-file viewer (tail-follow, filters,
        # columnizers). Portable, NOT installer class: its Setup .exe is Inno
        # with DefaultDirName={commonpf} and no PrivilegesRequired override →
        # admin-only; winget itself packages this same zip as a portable.
        # FRAMEWORK-DEPENDENT: needs the .NET 10 Desktop Runtime (the Setup
        # exe exists to chain-install it) — hand-installed, this script
        # installs no runtimes; first launch prompts with a download link if
        # it's missing. Settings live in %APPDATA%\LogExpert (safe across pin
        # bumps); only its sessionFiles\ sit next to the exe — minor loss on
        # a bump. Windows-only GUI tool: no config.toml [vars] pin, no dual-edit.
        Name       = "LogExpert"
        Exe        = "LogExpert"
        Version    = "1.41.0"
        Url        = "https://github.com/LogExperts/LogExpert/releases/download/v1.41.0/LogExpert.1.41.0.zip"
        Sha256     = "74524db34332aed480c5c631ca9023118140bc120075c1365ae6713620673c89"
        Layout     = "tree"
        Dest       = $WsLogExpert
        Repo       = "LogExperts/LogExpert"
        TagPrefix  = "v"
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools"
        Shortcut   = @{ Target = "LogExpert"; Description = "LogExpert — tabbed log-file viewer with tail-follow" }
    }
)

# --- Blessed Python scripting env (Invoke-PythonEnv) -------------------------
# DUAL-EDIT: $PythonEnvVersion pairs with vars.python_version in config.toml;
# $PythonLibs pairs with PY_LIBS in scripts/lib/python-env.sh. KEEP EACH ON ONE
# LINE — scripts/check-invariants.sh parses both with single-line greps.
$PythonEnvVersion = "3.14.7"
$PythonLibs = @("textual", "textual-dev", "click", "rich", "httpx", "pydantic", "typer", "polars", "duckdb")
$WsPythonEnv = Join-Path $WsRoot "python-env"

# Installer-layout tools: apps that publish a silent, admin-free .exe
# installer instead of a portable zip. NOT version-pinned -- resolves the
# LATEST release at run time (the app self-updates after), via the GitHub
# releases API + per-asset sha256 digest, via git tags + a vendor URL
# template (UrlTemplate, for apps with no GitHub release assets), or via a
# winget-pkgs version listing (WingetVersions, for apps with no GitHub
# presence at all). Runs the installer silently PER-USER, adds nothing to
# PATH. Presence = Uninstall-registry DisplayName; -ForceInstaller reinstalls.
#
# Opt-in per-tool fields (absent = old behavior):
#   IncludePrerelease  newest non-draft /releases entry instead of
#                      /releases/latest (DevToys flags every 2.x prerelease)
#   UpdateHint         -Doctor/-CheckForUpdates text when "self-updates"
#                      is wrong (DevToys/WinSCP need a manual nudge)
#   TagPrefix          tag prefix for -CheckForUpdates + UrlTemplate
#                      (default "v"; DBeaver/WinSCP tags are bare)
#   UrlTemplate        {VERSION}-templated download URL for apps with no
#                      GitHub release assets (version via Get-LatestGitTag)
#   HashManifest       {VERSION}-templated winget manifest URL -- the
#                      sha256 source when UrlTemplate has no GitHub digest
#   WingetVersions     winget-pkgs directory path whose subdir names ARE
#                      the versions -- for upstreams with no GitHub
#                      presence at all (version + sha256 from the same
#                      winget authority, so a lagging winget just seeds an
#                      older but still hash-verified install)
$InstallerTools = @(
    @{
        Name       = "Obsidian"
        Repo       = "obsidianmd/obsidian-releases"  # GitHub owner/repo for LATEST
        AssetMatch = "Obsidian-*.exe"                # selects the Windows installer asset
        SilentArgs = "/S"                            # NSIS per-user silent (NO /allusers -> no admin)
        DetectName = "Obsidian*"                      # HKCU/HKLM Uninstall DisplayName glob
    },
    @{
        Name       = "Zed"
        Repo       = "zed-industries/zed"             # GitHub owner/repo for LATEST (stable; /releases/latest skips -pre)
        AssetMatch = "Zed-x86_64.exe"                 # x64 Windows installer asset (NOT Zed-aarch64.exe)
        SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno Setup silent; PrivilegesRequired=lowest -> per-user, no admin (NOT NSIS /S)
        DetectName = "Zed"                            # exact HKCU Uninstall DisplayName (avoids "Zed Preview"/"Zed Nightly")
    },
    @{
        Name              = "DevToys"
        Repo              = "DevToys-app/DevToys"
        AssetMatch        = "devtoys_win_x64.exe"     # Inno Setup installer (x64 only; NOT arm64/x86, NOT the *_portable.zip)
        SilentArgs        = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno; PrivilegesRequired=lowest -> per-user, no admin
        DetectName        = "DevToys*"                # HKCU ...\Uninstall\DevToys_is1 -> DisplayName "DevToys <ver>" (version-suffixed; glob also matches a user's "DevToys Preview" — intended: don't force a stable seed alongside)
        IncludePrerelease = $true                     # see banner: /releases/latest lies for this repo
        UpdateHint        = "update-checks in-app only (no self-update); re-run bootstrap with -ForceInstaller to update"
    },
    @{
        Name       = "DBeaver"
        Repo       = "dbeaver/dbeaver"                 # CE; /releases/latest is honest here (unlike DevToys)
        AssetMatch = "dbeaver-ce-*-windows-x86_64.exe" # NSIS installer (NOT -aarch64.exe, NOT the .zip archives)
        SilentArgs = "/S /currentuser"                 # NSIS silent + MultiUser per-user pin -> no admin/UAC
        DetectName = "DBeaver*"                        # HKCU ...\Uninstall\"DBeaver (current user)"; glob also matches commercial editions (intended: never force CE alongside a licensed install); MS-Store MSIX copies are invisible here and would double-install (known class caveat, same as DevToys)
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
    },
    @{
        Name           = "Beyond Compare"                                       # commercial trialware: seed = 30-day trial; the user's license key unlocks it (Standard vs Pro by key)
        WingetVersions = "manifests/s/ScooterSoftware/BeyondCompare/5"          # version source: subdir names ARE the 4-part versions (Scooter has NO GitHub presence; the URL needs the build number)
        UrlTemplate    = "https://www.scootersoftware.com/files/BCompare-{VERSION}.exe"  # first-party, direct (no redirect); English installer deliberate — localized siblings (BCompare-de-…) never match the hash lookup
        HashManifest   = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/s/ScooterSoftware/BeyondCompare/5/{VERSION}/ScooterSoftware.BeyondCompare.5.installer.yaml"
        SilentArgs     = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER"  # Inno silent + documented per-user mode -> no admin/UAC (NEVER /ALLUSERS)
        DetectName     = "Beyond Compare*"                                      # HKCU ...\Uninstall\BeyondCompare5_is1; glob also matches BC4 or a machine-wide HKLM install (intended: never seed a trial alongside a licensed copy)
        UpdateHint     = "in-app update check prompts to install (not silent) — or re-run bootstrap with -ForceInstaller"
    }
)

# Warp -- the PRIMARY terminal. Its Windows distribution is a WinGet
# package (no GitHub release assets to hash), so this is a bespoke
# best-effort seed rather than an $InstallerTools entry -- WinGet's
# manifest enforces the hash and Warp self-updates after, evergreen like
# the Windows Terminal seed. Windows Terminal stays the compatibility path
# (keeps the OS default-terminal role Warp can't register for). Warp does
# NOT support Nushell -- see Invoke-WarpTabConfigs.
$WarpTool = @{
    Name       = "Warp"
    WingetId   = "Warp.Warp"
    DetectName = "Warp*"     # HKCU ...\Uninstall\warp-terminal-stable_is1 (Inno, per-user). GLOB, not an exact
                             # match: Test-InstallerPresent uses -like, and an exact "Warp" would
                             # silently double-fail if the DisplayName is "Warp Terminal" — winget
                             # would reinstall every run AND Invoke-WarpTabConfigs would skip.
}

# Elevated tools -- the ONE sanctioned exception to the no-admin rule.
# SSHFS-Win mounts remote Unix filesystems over SSH; it depends on WinFsp
# (a kernel-mode driver), so both MSIs are machine-scope and UAC is
# unavoidable. BEST-EFFORT: Uninstall-registry detect first (no UAC once
# provisioned), then winget (pulls WinFsp as a dependency), then a
# digest/pin-verified direct-MSI fallback when winget is absent. Every
# failure (declined UAC, offline, hash mismatch) warns and continues --
# this class never aborts the bootstrap. -SkipElevated skips it.
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

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

# --- ANSI escape codes -------------------------------------------------------
$Esc    = [char]27
$Bold   = "$Esc" + "[1m"
$Reset  = "$Esc" + "[0m"
$Red    = "$Esc" + "[0;31m"
$Green  = "$Esc" + "[0;32m"
$Yellow = "$Esc" + "[1;33m"
$Blue   = "$Esc" + "[0;34m"

function Write-Log    { param($msg) Write-Host "${Blue}==>${Reset} ${Bold}$msg${Reset}" }
function Write-Ok     { param($msg) Write-Host "${Green} ✓${Reset} $msg" }
function Write-Warn   { param($msg) Write-Host "${Yellow} !${Reset} $msg" }
function Write-Fail   { param($msg) Write-Host "${Red} ✗${Reset} $msg"; exit 1 }
function Write-Bad    { param($msg) Write-Host "${Red} ✗${Reset} $msg" }  # Write-Fail minus the exit — -Doctor reports, never aborts

# =============================================================================
# HTTP / GITHUB HELPERS
# =============================================================================

# Kept self-contained: bootstrap also runs from memory before the repo exists.
# The font script carries the same helper for its independent execution context.
function Invoke-CurlRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$OutFile
    )

    # Get-Command lists EVERY curl.exe on PATH (System32 + Git's mingw64\bin is
    # the everyday case) - take the first, i.e. the one a bare `curl.exe` runs.
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) {
        throw 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $headerFile = $null
    try {
        # --speed-limit/--speed-time: a connected-but-stalled transfer aborts
        # (exit 28, which --retry treats as transient) instead of hanging forever.
        $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location',
            '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
            '--speed-limit', '1', '--speed-time', '60',
            '--output', $tempFile)
        if ($Headers.Count -gt 0) {
            # Headers travel via a file, never argv: a PAT on a command line is
            # visible to process auditing. One header per line; no BOM, or curl
            # would send it as part of the first header name.
            $headerFile = [System.IO.Path]::GetTempFileName()
            $headerLines = @(foreach ($key in $Headers.Keys) { '{0}: {1}' -f $key, $Headers[$key] })
            [System.IO.File]::WriteAllLines($headerFile, [string[]]$headerLines, [System.Text.UTF8Encoding]::new($false))
            $curlArgs += @('--header', "@$headerFile")
        }
        $curlArgs += @('--url', $Uri)
        # PS 5.1 can turn redirected native stderr into PowerShell errors;
        # PS 7 can optionally throw on native exit codes. Handle both ourselves.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $curlOutput = & $curl.Source @curlArgs 2>&1
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            # --silent --show-error leaves only curl's own diagnostic on stderr
            # (e.g. "curl: (22) The requested URL returned error: 404"); surface it.
            $detail = ((@($curlOutput) | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
            throw "curl.exe request failed (exit $curlExitCode): $Uri [$detail]"
        }
        if ($OutFile) {
            Move-Item -LiteralPath $tempFile -Destination $OutFile -Force -ErrorAction Stop
        } else {
            [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
        }
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        if ($headerFile) { Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue }
    }
}

# GitHub API headers: a User-Agent is required; $env:GITHUB_TOKEN (optional)
# lifts the 60-requests/hour anonymous limit.
function Get-GitHubApiHeaders {
    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    return $headers
}

# =============================================================================
# PATH HELPERS
# =============================================================================

function Update-SessionPath {
    # New PATH entries are written to the User registry scope; the current
    # session keeps its own copy. Rebuild $env:PATH from Machine + User so
    # freshly-installed tools resolve right away.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Add-ToUserPath {
    param([string]$Dir)

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $userPath) { $userPath = "" }

    # Idempotent: append to the User PATH only if not already present
    # (case-insensitive, trailing-slash-insensitive).
    $present = $userPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $present) {
        $base = $userPath.TrimEnd(';')
        $newPath = if ($base) { "$base;$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Ok "Added $Dir to User PATH"
    }

    # Always refresh the in-session PATH so later steps + spawned procs resolve.
    $inSession = ($env:PATH).Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $inSession) {
        $env:PATH = "$(($env:PATH).TrimEnd(';'));$Dir"
    }
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

# Invoke-Reinstall -- wipe the cloned repo, then let the rest of the script
# re-bootstrap fresh. Installed tools + deployed dotfiles are left alone.
function Invoke-Reinstall {
    Write-Log "Reinstall mode — wipe + re-bootstrap"
    Write-Host ""
    Write-Host "  Will REMOVE:"
    Write-Host "    - $RepoPath  (cloned workstation repo)"
    Write-Host ""
    Write-Host "  Will NOT remove (leaving for re-bootstrap to no-op over):"
    Write-Host "    - Binary tools under $WsRoot (re-bootstrap detects + skips them)"
    Write-Host "    - Deployed dotfiles in `$HOME / `$env:APPDATA (the mise dotfiles+tools bootstrap will re-apply)"
    Write-Host "    - SSH keys"
    Write-Host ""
    Write-Host "  For a deeper uninstall (remove the portable tools too), do that manually first:"
    Write-Host "    Remove-Item -Recurse -Force '$WsRoot'   # mise + every portable tool re-downloads next run"
    Write-Host ""

    # Self-deletion guard: if this script is being run from inside the path we're
    # about to delete, refuse. Use the checked curl.exe download form instead, which runs
    # from memory and isn't backed by a file on disk. $PSCommandPath is $null
    # when the script is executed from a string (a scriptblock).
    if ($PSCommandPath -and $PSCommandPath.StartsWith($RepoPath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail @"
Refusing to reinstall — the running script is inside $RepoPath, which would
be deleted, leaving this invocation orphaned. Either:

  1. Use the checked curl.exe download from README.html with -Reinstall.
     It runs from memory after the complete download succeeds.

  2. Copy this script somewhere outside the repo first, then re-run:
       Copy-Item $PSCommandPath `$env:TEMP\bootstrap.ps1
       & `$env:TEMP\bootstrap.ps1 -Reinstall
"@
    }

    if (-not $Yes) {
        $ans = Read-Host "  Proceed? [y/N]"
        if ($ans -notmatch '^[Yy]') {
            Write-Warn "Aborted."
            exit 0
        }
    }

    if (Test-Path $RepoPath) {
        Write-Log "Removing $RepoPath..."
        Remove-Item -Recurse -Force $RepoPath
        Write-Ok "Repo removed"
    } else {
        Write-Log "$RepoPath not present — nothing to remove"
    }

    Write-Host ""
    Write-Log "Wipe complete — continuing with fresh bootstrap..."
    Write-Host ""
}

# Git is a hard prerequisite; mise presence only matters when
# -SkipToolInstall is set and the dotfiles+tools step will run;
# ssh-keygen soft-warns. No admin check needed.
function Invoke-Preflight {
    Write-Log "Checking prerequisites..."
    $curlCmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curlCmd) {
        Write-Fail 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }
    Write-Ok "curl.exe found ($($curlCmd.Source))"

    # Git is a hard prerequisite — you install it yourself. Needed for the
    # clone and for git operations mise performs against this same checkout
    # (dotfiles history — ruling 8). This script does NOT install Git.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Fail @"
Git is required but isn't on PATH.

Install Git for Windows (an admin-free per-user install is available), then
re-run this script:
  https://git-scm.com/download/win
or:  winget install Git.Git

This script does NOT install Git for you.
"@
    }
    Write-Ok "git found ($((Get-Command git).Source))"

    # mise is installed by the tool step unless skipped. If -SkipToolInstall
    # is set and the dotfiles+tools bootstrap step will run, mise must already
    # be present.
    if ($SkipToolInstall -and -not $SkipDotfiles -and -not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Fail @"
-SkipToolInstall was passed but mise isn't on PATH and the dotfiles+tools
bootstrap step will run. Either drop -SkipToolInstall (so the script installs
mise), pass -SkipDotfiles (skip the dotfiles+tools bootstrap), or install mise
yourself first.
"@
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen not on PATH — install OpenSSH client to enable the SSH-key step:"
        Write-Warn "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }

    Write-Ok "Prerequisites OK"
}

function Install-PortableTool {
    param([hashtable]$Tool)

    $stamp = Join-Path $WsStamps "$($Tool.Exe).$($Tool.Version).stamp"

    # BinSubdir (opt-in): where <Exe>.exe lives under Dest and what joins the
    # PATH — see the $PortableTools comment. Honoured in exactly two places
    # (the stamp fast-path check below and the 'tree' branch's Add-ToUserPath).
    $binDir = if ($Tool.ContainsKey('BinSubdir')) { Join-Path $Tool.Dest $Tool.BinSubdir } else { $Tool.Dest }

    # Idempotency: stamp present AND the pinned exe exists on disk → already
    # done. A version bump changes the stamp name, so the old stamp won't
    # match → reinstall. Deliberately NOT Get-Command: PATH resolution depends
    # on the CALLING session's environment, so a session started before the
    # tool's dir joined the User PATH re-installed forever (bit DevToys CLI —
    # the only tool with its own PATH dir — 2026-07-14). The Add-ToUserPath
    # below keeps the User PATH entry self-healing on the skip path (idempotent
    # and silent when already present).
    if ((Test-Path $stamp) -and (Test-Path (Join-Path $binDir "$($Tool.Exe).exe"))) {
        Add-ToUserPath $binDir
        Write-Ok "$($Tool.Name) $($Tool.Version) already installed"
        return
    }

    if ($Tool.Sha256 -like "*PIN-ME*") {
        Write-Fail "$($Tool.Name) has an unfilled sha256 pin ($($Tool.Sha256)). Fill it in `$PortableTools before running."
    }

    Write-Log "Installing $($Tool.Name) $($Tool.Version) (portable)..."

    $tmpZip = Join-Path $env:TEMP "ws-$($Tool.Exe)-$($Tool.Version).zip"
    $tmpDir = Join-Path $env:TEMP "ws-$($Tool.Exe)-$($Tool.Version)"

    try {
        Invoke-CurlRequest -Uri $Tool.Url -OutFile $tmpZip
    } catch {
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    # sha256 verify — the ONE hard-fail inside this helper (tamper/corruption).
    $actual = (Get-FileHash -Algorithm SHA256 -Path $tmpZip).Hash.ToLower()
    if ($actual -ne $Tool.Sha256.ToLower()) {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Write-Fail @"
$($Tool.Name) sha256 mismatch — refusing to install.
  expected: $($Tool.Sha256.ToLower())
  actual:   $actual
The pinned hash in `$PortableTools is stale, or the download was corrupted/tampered.
"@
    }

    try {
        if ($Tool.Layout -eq "exe") {
            # Bare single-binary release (jq ships jq-windows-amd64.exe, not a
            # .zip) — the sha256-verified download IS the binary; place it under
            # Dest as <Exe>.exe, no Expand-Archive. ($tmpZip holds the raw .exe.)
            if (-not (Test-Path $Tool.Dest)) { New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null }
            Copy-Item $tmpZip -Destination (Join-Path $Tool.Dest "$($Tool.Exe).exe") -Force
            Add-ToUserPath $Tool.Dest
            if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
            New-Item -ItemType File -Force -Path $stamp | Out-Null
            Write-Ok "$($Tool.Name) $($Tool.Version) installed to $($Tool.Dest)"
            return
        }
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

        if ($Tool.Layout -eq "single") {
            if (-not (Test-Path $Tool.Dest)) { New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null }
            $exe = Get-ChildItem -Path $tmpDir -Recurse -Filter "$($Tool.Exe).exe" | Select-Object -First 1
            if (-not $exe) {
                Write-Warn "$($Tool.Name): $($Tool.Exe).exe not found in archive — skipping"
                return
            }
            Copy-Item $exe.FullName -Destination (Join-Path $Tool.Dest "$($Tool.Exe).exe") -Force
            Add-ToUserPath $Tool.Dest
        } else {
            # 'tree' — the archive may wrap everything in a single top-level
            # folder; flatten that so the exe lands directly in Dest.
            $top = @(Get-ChildItem -Path $tmpDir)
            $src = if (($top.Count -eq 1) -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmpDir }
            # NOTE: if the tool is running from $Dest its files are locked — this wipe then throws and the outer try/catch warn-not-fails. Close the app (Helix/dnGrep) before re-running to refresh it.
            if (Test-Path $Tool.Dest) { Remove-Item -Recurse -Force $Tool.Dest }
            New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $Tool.Dest -Recurse -Force
            Add-ToUserPath $binDir
        }

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "$($Tool.Name) $($Tool.Version) installed to $($Tool.Dest)"
    } catch {
        Write-Warn "$($Tool.Name) install failed during extract/place: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
               Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayName }
        if ($hit) { return $true }
    }
    return $false
}

# Install a silent, admin-free .exe installer at its LATEST release. NOT
# version-pinned (app self-updates after); sha256-verified (API digest or
# winget manifest — see the $InstallerTools banner for the resolver paths).
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

    # Two resolver paths produce the same four facts for the shared
    # download/verify/install tail below:
    #   $downloadUrl    where the installer .exe comes from
    #   $expectedSha    lowercase sha256 to enforce, or $null (warn+proceed)
    #   $noHashWarning  warn text used when $expectedSha is $null
    #   $versionLabel   what the success line reports
    #   $hashSource     names the hash authority in the mismatch hard-fail
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
                $manifest = (Invoke-CurlRequest -Uri $manifestUrl)
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
        $headers = Get-GitHubApiHeaders

        try {
            if ($Tool.ContainsKey('IncludePrerelease') -and $Tool.IncludePrerelease) {
                # /releases/latest excludes prereleases, and some repos (DevToys)
                # flag EVERY release prerelease:true — take the newest non-draft
                # entry of /releases instead (the list is newest-first).
                # Parse the complete JSON string; bare assignment avoids nesting
                # JSON arrays on PS 5.1. Do not wrap this assignment in @(...).
                $releases = Invoke-CurlRequest `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases?per_page=10" `
                    -Headers $headers | ConvertFrom-Json -ErrorAction Stop
                $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
                if (-not $release) { throw "no non-draft release among the newest $(@($releases).Count)" }
            } else {
                $release = Invoke-CurlRequest `
                    -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
                    -Headers $headers | ConvertFrom-Json -ErrorAction Stop
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
        Invoke-CurlRequest -Uri $downloadUrl -OutFile $tmpExe
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

    $headers = Get-GitHubApiHeaders

    try {
        $release = Invoke-CurlRequest `
            -Uri "https://api.github.com/repos/$($Msi.Repo)/releases/latest" `
            -Headers $headers | ConvertFrom-Json -ErrorAction Stop
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
        Invoke-CurlRequest -Uri $asset.browser_download_url -OutFile $tmpMsi
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

# Best-effort, per-user Warp seed. A missing WinGet or failed install must not
# block the portable toolbelt or the dotfiles+tools bootstrap; Warp's official installer self-updates.
# --scope user maps to the Inno /CURRENTUSER switch, so Warp itself never needs
# admin. One asterisk on that, and it is NOT a new exception to the no-admin rule
# ($ElevatedTools remains the only sanctioned one): Warp's winget manifest
# declares a Microsoft.VCRedist.2015+ dependency, so on a box that has no VC++
# runtime at all, WINGET (not us) may try to install that dependency machine-wide.
# Nothing here elevates, and declining is survivable — Warp just doesn't install
# and the warning below says where to get it.
function Install-Warp {
    if ((-not $ForceInstaller) -and (Test-InstallerPresent -DisplayName $WarpTool.DetectName)) {
        Write-Ok "Warp already installed (use -ForceInstaller to reinstall)"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "Warp not installed — winget is unavailable; install manually from https://www.warp.dev/download"
        return
    }

    Write-Log "Installing Warp (official WinGet package, per-user)..."
    $wingetArgs = @(
        "install", "--id", $WarpTool.WingetId, "--exact", "--scope", "user",
        "--silent", "--accept-source-agreements", "--accept-package-agreements"
    )
    if ($ForceInstaller) { $wingetArgs += "--force" }
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & winget @wingetArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    if ($code -eq 0) {
        Write-Ok "Warp installed (winget $($WarpTool.WingetId))"
    } else {
        Write-Warn "Warp: winget exited with code $code — install manually from https://www.warp.dev/download or re-run later"
    }
}

function Install-WindowsTerminal {
    # Evergreen MSIX seed: per-user by design (no admin), Store-serviced thereafter.
    # No config.toml [vars] pin — same latest-release model as the installer-class apps.
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

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming Warp/Windows Terminal/Starship/Helix/Nushell/jq/OpenCode/omp/mise/DevToys CLI/dnGrep/LogExpert on PATH; Obsidian/Zed/DevToys/SSHFS-Win/Claude Code not installed; mise-installed tools not installed, Python env not built"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsHelix, $WsNu, $WsStamps)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    foreach ($tool in $PortableTools) { Install-PortableTool -Tool $tool }
    Install-WindowsTerminal
    Install-Warp
    foreach ($tool in $InstallerTools) { Install-InstallerTool -Tool $tool }

    # Elevated class last, so a declined UAC can't interrupt the admin-free
    # installs above. Best-effort; -SkipElevated opts out entirely.
    if ($SkipElevated) {
        Write-Log "Elevated tool install skipped (-SkipElevated) — SSHFS-Win/WinFsp not installed"
    } else {
        foreach ($tool in $ElevatedTools) { Install-ElevatedTool -Tool $tool }
    }

    Update-SessionPath

    # Soft-warn for the hand-installed editor (VSCode). Zed is auto-installed via
    # $InstallerTools above; VSCode's dotfiles config deploys regardless, and the
    # script never installs or fails on it.
    foreach ($app in @(@{ Cmd = 'code'; Name = 'VSCode' })) {
        if (-not (Get-Command $app.Cmd -ErrorAction SilentlyContinue)) {
            Write-Warn "$($app.Name) not on PATH — install it yourself when you want it; its dotfiles still deploy."
        }
    }
}

# =============================================================================
# REPO & MISE FUNCTIONS
# =============================================================================

# Clone the workstation repo (public; optional $env:GITHUB_TOKEN for a private fork).
function Invoke-CloneRepo {
    # HTTP Basic with base64-encoded "x-access-token:<PAT>" — same scheme
    # actions/checkout uses. "Authorization: bearer" works for the REST/raw API
    # (how curl.exe fetches bootstrap.ps1) but is NOT accepted by git's smart-HTTP
    # endpoint on github.com — git silently falls through to credential
    # prompting, breaking any non-interactive clone.
    $headerVal = ""
    if ($env:GITHUB_TOKEN) {
        $b64 = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes("x-access-token:$env:GITHUB_TOKEN"))
        $headerVal = "Authorization: Basic $b64"
    }

    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Log "Cloning workstation repo into $RepoPath..."
        $parent = Split-Path $RepoPath -Parent
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        if ($headerVal) {
            git -c "$GhHeaderKey=$headerVal" clone $DotfilesRepo $RepoPath
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Clone failed. Check network access to github.com, and that `$env:GITHUB_TOKEN is a valid PAT (it is only needed for a private fork)."
            }
            git -C $RepoPath config $GhHeaderKey $headerVal
        } else {
            git clone $DotfilesRepo $RepoPath
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Clone failed. Check network access to github.com (a private fork also needs `$env:GITHUB_TOKEN set to a PAT with repo read)."
            }
        }
        Write-Ok "Repo cloned"
    } else {
        Write-Log "Repo already at $RepoPath — pulling latest..."
        if ($headerVal) {
            git -C $RepoPath config $GhHeaderKey $headerVal
        }
        git -C $RepoPath pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not fast-forward — continuing with current state"
        } else {
            Write-Ok "Repo up to date"
        }
    }
}

# Invoke-MiseBootstrap -- `mise bootstrap --only dotfiles,tools` applies the
# [dotfiles] entries (config.toml/config.owned.toml/config.windows.toml) to
# %USERPROFILE% AND installs the tools those same files declare, in one
# call; `--only dotfiles,tools` skips [bootstrap.files] entirely, so no
# sudo-only /etc entry can ever fire here. -SkipToolInstall drops to `--only
# dotfiles` so it doesn't silently install tools anyway (Invoke-MiseRuntimes
# below has its own, separate -SkipToolInstall gate).
#
# A host still on the old chezmoi-based deploy has every dotfiles target
# already on disk as a real file, and template/copy modes refuse to
# overwrite one that already differs -- so the FIRST apply here needs
# --force-dotfiles (mirrors bootstrap.sh's own apply()). Passed only until
# $MigratedMarker exists, so a later real conflict still surfaces loudly.
# Invoke-MiseRuntimes (below) runs afterward for a separate reason -- see
# its own comment.
$MigratedMarker = Join-Path $WsRoot "dotfiles-migrated"

function Initialize-MiseEnv {
    # Persist MISE_ENV to the User registry AND this session before any mise
    # invocation that must see it. Invoke-MiseBootstrap and Invoke-MiseRuntimes
    # can each run independently of the other (-SkipDotfiles / -SkipToolInstall
    # are orthogonal), so both call this rather than relying on the other
    # having already run. Idempotent.
    [Environment]::SetEnvironmentVariable("MISE_ENV", $MiseEnv, "User")
    $env:MISE_ENV = $MiseEnv
}

function Set-ConfigLocalVar {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '\\', '\\' -replace '"', '\"'
    $line = "$Key = `"$escaped`""
    $lines = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) -split "`r?`n" } else { @() }
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        # PowerShell's 0..-1 counts down, so a one-element array needs its own case.
        $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $inVars = $false; $seen = $false; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\[') {
            if ($inVars -and -not $done) { $out.Add($line); $done = $true }
            $inVars = ($l -eq '[vars]'); if ($inVars) { $seen = $true }
            $out.Add($l); continue
        }
        if ($inVars -and $l -match ('^' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $done) { $out.Add($line); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if (-not $done) { if (-not $seen) { $out.Add('[vars]') }; $out.Add($line) }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Windows is always an owned host (no shared mode here). Name/email are asked
# once, interactively; a non-interactive run leaves them for the user to add.
function Invoke-EnsureConfigLocal {
    $target = Join-Path $RepoPath "config.local.toml"
    Set-ConfigLocalVar -Path $target -Key 'mode' -Value 'owned'
    $text = [System.IO.File]::ReadAllText($target)
    $hasName = $text -match '(?m)^name\s*='
    $hasEmail = $text -match '(?m)^email\s*='
    if ($hasName -and $hasEmail) {
        Write-Ok "config.local.toml ready ($target, mode = owned)"
        return
    }
    if ($SkipToolInstall -or [Console]::IsInputRedirected) {
        Write-Warn "No interactive console — add [vars] name / email to $target for git commits."
        return
    }
    Write-Log "First-time setup -- name/email for git commits and the SSH config comment..."
    if (-not $hasName) { Set-ConfigLocalVar -Path $target -Key 'name' -Value (Read-Host "  Name") }
    if (-not $hasEmail) { Set-ConfigLocalVar -Path $target -Key 'email' -Value (Read-Host "  Email") }
    Write-Ok "wrote $target"
}

function Invoke-WslConfigReminder {
    # mise has no run_onchange_* equivalent, and .wslconfig only takes effect
    # after `wsl --shutdown` restarts every distro -- so remind the user only
    # when the deployed content actually changed. Hashes the REPO source
    # (dotfiles/wslconfig): a matching stamp file means "unchanged"; no
    # match means the hash moved, so the reminder fires and a fresh stamp
    # is written.
    $source = Join-Path $RepoPath "dotfiles\wslconfig"
    if (-not (Test-Path -LiteralPath $source)) { return }

    $hash  = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.Substring(0, 8).ToLower()
    $stamp = Join-Path $WsStamps "wslconfig.$hash.stamp"
    if (Test-Path -LiteralPath $stamp) { return }

    if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
    Get-ChildItem -Path $WsStamps -Filter "wslconfig.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force -Path $stamp | Out-Null

    Write-Host ""
    Write-Warn ".wslconfig changed -- run 'wsl --shutdown' from a Windows terminal"
    Write-Warn "for the new WSL2 settings to take effect (restarts all distros)."
}

function Invoke-MiseBootstrap {
    if ($SkipDotfiles) {
        Write-Log "mise dotfiles+tools bootstrap skipped (-SkipDotfiles)"
        return
    }

    Initialize-MiseEnv

    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "mise not on PATH after install. Open a new shell and re-run, or install manually from https://mise.jdx.dev/installing-mise.html"
        return
    }

    # config.local.toml must exist BEFORE the dotfiles apply below -- the
    # Tera templates guard every vars.* reference, but a real value still
    # shapes the rendered git identity.
    Invoke-EnsureConfigLocal

    # -SkipToolInstall must skip the tools phase HERE too, not just in
    # Invoke-MiseRuntimes below -- otherwise "just reapply my dotfiles,
    # don't touch my tools" silently installs/updates node/Go/uv/gopls/the
    # LSP servers/ccstatusline anyway on any host where mise is already on
    # PATH (Invoke-MiseRuntimes's own -SkipToolInstall gate only skips ITS
    # later, separate pass -- by then this step has already done the work).
    # PS 5.1 has no ternary, hence the if/else-as-expression form.
    $onlyPhases = if ($SkipToolInstall) { 'dotfiles' } else { 'dotfiles,tools' }
    if ($SkipToolInstall) {
        Write-Log "-SkipToolInstall passed -- mise bootstrap will run --only dotfiles (tools phase skipped)"
    }

    $forceFlags = @()
    if (-not (Test-Path -LiteralPath $MigratedMarker)) {
        $forceFlags = @('--force-dotfiles')
        Write-Log "First dotfiles apply on this host -- passing --force-dotfiles (marker absent: $MigratedMarker)"
    }

    Write-Log "Running mise bootstrap --only $onlyPhases (source: $RepoPath)..."
    $bootstrapArgs = @('bootstrap', '--only', $onlyPhases, '--yes') + $forceFlags
    & mise @bootstrapArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail @"
mise bootstrap (dotfiles + tools) failed -- see the failing phase above.

A dotfiles conflict aborts the WHOLE dotfiles phase (one bad entry blocks
every entry -- nothing gets applied). If the failure names a target that
already exists as a real file:
  1. resolve that one entry directly:  mise dot apply --force <the path mise named above>
  2. then re-run:                      .\bootstrap.ps1
Any other failure (the tools phase) is idempotent to retry -- fix what's
reported above and re-run.
"@
    }
    Write-Ok "mise bootstrap (--only $onlyPhases) complete"

    if (-not (Test-Path -LiteralPath $MigratedMarker)) {
        $markerDir = Split-Path $MigratedMarker -Parent
        if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
        New-Item -ItemType File -Force -Path $MigratedMarker | Out-Null
        Write-Ok "dotfiles first-apply marker written ($MigratedMarker) -- future runs no longer force-reclaim dotfiles targets"
    }

    Invoke-WslConfigReminder
}

# node/Go/uv/gopls/the LSP servers/ccstatusline via mise -- the Windows
# half of the Linux mise-driven install. Invoke-MiseBootstrap's own tools
# phase already installed these; this is NOT redundant with that -- it's
# the Windows-specific idempotency layer on the same `mise install`:
# sweeps the retired portable uv, force-reinstalls node only when its npm
# postinstall (the LSP servers) needs to re-run, and self-heals the shims
# PATH. Gated by its own change-detection stamp, so a repeat run right
# after Invoke-MiseBootstrap is a fast no-op. Reads config.toml +
# config.owned.toml + config.windows.toml directly from the checkout root
# (config.linux.toml never loads -- MISE_ENV carries no `linux` token on
# Windows). When Windows can't replace a locked node install (a running
# editor LSP holds it open), falls back to running node's declared
# postinstall directly against the existing install so the language
# servers still refresh. -SkipToolInstall skips this too, independently
# of -SkipDotfiles.
$MiseConfigFiles = @("config.toml", "config.owned.toml", "config.windows.toml")
$MiseShims       = Join-Path $env:LOCALAPPDATA "mise\shims"
$MiseEnv         = "windows,owned"

# Get-MiseRuntimesStamp — the exact stamp path Invoke-MiseRuntimes writes on
# success: a hash of $MiseConfigFiles (config.toml + config.owned.toml +
# config.windows.toml) under $RepoPath. Doctor calls this SAME helper so its
# verdict can never drift onto a stale stamp. $null when config.toml is
# missing (repo not cloned yet).
function Get-MiseRuntimesStamp {
    # FIXED order, not Sort-Object: the two names differ only by a middle
    # token, and culture-aware sorting orders them differently under .NET
    # Framework (5.1, NLS) and .NET Core (pwsh 7, ICU) — the stamp must not
    # depend on which PowerShell ran the bootstrap (bit the first Windows run,
    # 2026-09-16).
    $files = @($MiseConfigFiles | ForEach-Object { Join-Path $RepoPath $_ })
    if (-not (Test-Path -LiteralPath $files[0])) { return $null }
    $existing = @($files | Where-Object { Test-Path -LiteralPath $_ })
    $text   = ($existing | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_ }) -join "`n"
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

    # Persist MISE_ENV as a User env var right after we know mise is present
    # and before any `mise` invocation below — every process that resolves
    # tools (shells, Claude Code hooks, this session) must see the same set.
    # Idempotent; Invoke-MiseBootstrap also calls this (they're independently
    # skippable — see its header comment).
    Initialize-MiseEnv

    $stamp = Get-MiseRuntimesStamp
    if ($null -eq $stamp) {
        Write-Warn "mise tools skipped — $RepoPath\config.toml missing (clone step failed?)"
        return
    }

    # Shims on the User PATH every run (self-heals) and in-session, so later
    # steps (Invoke-PythonEnv's `mise which uv`, Claude Code's npx) resolve.
    if (-not (Test-Path $MiseShims)) { New-Item -ItemType Directory -Force -Path $MiseShims | Out-Null }
    Add-ToUserPath $MiseShims

    if (Test-Path $stamp) {
        Write-Ok "mise runtimes already installed (config unchanged — $(Split-Path -Leaf $stamp))"
        return
    }

    Write-Log "Installing mise tools from $RepoPath\config*.toml (node / Go / uv / gopls / LSP servers / ccstatusline — a few minutes on first run)..."
    # Native commands chatter on stderr; keep that from tripping an EAP=Stop
    # session (the git ls-remote precedent in Get-LatestGitTag).
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # `mise where node` succeeds only when the DECLARED node version is
        # already installed — a NODE_VERSION bump therefore installs once.
        & mise where node *> $null
        $hadNode = ($LASTEXITCODE -eq 0)
        $nodeDeclared = [bool](Select-String -Path (Join-Path $RepoPath "config.owned.toml") -Pattern '^node\s*=' -Quiet)

        & mise install --yes
        if ($LASTEXITCODE -ne 0) { throw "mise install exited $LASTEXITCODE" }
        if ($hadNode -and $nodeDeclared) {
            Write-Log "  node was already installed — forcing a reinstall so its npm postinstall re-runs"
            # Captured (not streamed): the only way to inspect it for the
            # Windows file-lock signature below.
            $forceOutput = & mise install --yes --force node 2>&1
            $forceExit = $LASTEXITCODE
            if ($forceExit -ne 0) {
                $forceText = $forceOutput -join "`n"
                $isLocked = ($forceText -match 'os error 32') -or ($forceText -match 'being used by another process')
                Write-Warn "  mise install --force node exited $forceExit — falling back to node's declared npm postinstall (existing node install untouched)"

                # The force-reinstall exists ONLY to re-run node's declared npm
                # postinstall (the language servers) — mise re-runs postinstall
                # hooks solely on (re)install. When mise can't replace the install
                # (most commonly Windows holding a file under it open), running
                # that SAME postinstall command directly against the
                # already-installed node/npm gets the identical result without
                # replacing anything. Read it fresh from config.owned.toml every
                # time (never hardcode it) with an explicit `-f`, the same way
                # scripts/lib/mise-install.sh reads it on Linux — a bare
                # `mise config get` resolves only the highest-precedence loaded
                # file, which here is config.windows.toml (declares no tools).
                $postinstallOk = $false
                $nodeConfigPath = Join-Path $RepoPath "config.owned.toml"
                $declOutput = & mise config get -f $nodeConfigPath "tools.node.postinstall" 2>&1
                $declExit = $LASTEXITCODE
                $postinstallCmd = $null
                if ($declExit -eq 0) { $postinstallCmd = ($declOutput -join "`n").Trim() }

                if ([string]::IsNullOrWhiteSpace($postinstallCmd)) {
                    # Unreadable declaration: nothing safe to run (a hardcoded
                    # guess could silently drift from config.owned.toml) — skip
                    # straight to the warn below instead of half-fixing it.
                    Write-Warn "  could not read tools.node.postinstall from $nodeConfigPath — skipping the postinstall fallback"
                } else {
                    Write-Log "  running node's declared postinstall directly: $postinstallCmd"
                    $postinstallParts = $postinstallCmd -split '\s+'
                    $postinstallArgs = @()
                    if ($postinstallParts.Length -gt 1) { $postinstallArgs = $postinstallParts[1..($postinstallParts.Length - 1)] }
                    & $postinstallParts[0] @postinstallArgs
                    if ($LASTEXITCODE -eq 0) {
                        $postinstallOk = $true
                        Write-Ok "  postinstall re-run directly (language servers refreshed)"
                    } else {
                        Write-Warn "  fallback postinstall command exited $LASTEXITCODE"
                    }
                }

                if (-not $postinstallOk) {
                    if ($isLocked) {
                        Write-Warn "  a running program is holding the node install open — commonly an editor's language server, a dev server, or a running agent."
                        Write-Warn "  the existing node install and its language servers are untouched; close that program and re-run .\bootstrap.ps1 to complete the refresh."
                    }
                    throw "mise install --force node exited $forceExit and the postinstall fallback also failed"
                }
                # Fallback succeeded: the postinstall genuinely re-ran, so fall
                # through and let the stamp be written below like any other
                # successful run.
            }
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

# =============================================================================
# SHELL / TERMINAL INTEGRATION
# =============================================================================

# Bridges Documents redirection (OneDrive): $PROFILE then resolves to the
# redirected dir, but the dotfiles apply writes the canonical profile to
# the LITERAL %USERPROFILE%\Documents\PowerShell, so PowerShell would never
# load it. Drops a tiny loader at the real $PROFILE dir(s) that dot-sources
# the canonical one. No-op when Documents isn't redirected.
function Invoke-ProfileShim {
    $canonical = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    if (-not (Test-Path $canonical)) {
        Write-Warn "Canonical PowerShell profile not at $canonical — skipping profile shim."
        return
    }
    $realDocs    = [Environment]::GetFolderPath("MyDocuments")
    $literalDocs = Join-Path $env:USERPROFILE "Documents"
    if ([string]::IsNullOrEmpty($realDocs) -or ($realDocs -eq $literalDocs)) {
        Write-Ok "Documents not redirected — PowerShell loads the managed profile directly."
        return
    }

    Write-Log "Documents redirected to $realDocs — installing profile loader(s)..."
    $loader = @'
# Loader (managed by bootstrap.ps1) — Documents is redirected (OneDrive / folder
# redirection), so PowerShell loads $PROFILE from here. Source the
# dotfiles-managed canonical profile at the literal %USERPROFILE%\Documents.
$canonical = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
if (Test-Path $canonical) { . $canonical }
'@
    foreach ($sub in @("WindowsPowerShell", "PowerShell")) {
        $dir    = Join-Path $realDocs $sub
        $target = Join-Path $dir "Microsoft.PowerShell_profile.ps1"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Back up a pre-existing non-loader profile once, so we never silently
        # clobber a hand-written one.
        if ((Test-Path $target) -and -not (Select-String -Path $target -Pattern "managed by bootstrap.ps1" -Quiet)) {
            $bak = "$target.pre-dotfiles.bak"
            if (-not (Test-Path $bak)) { Copy-Item $target $bak -Force; Write-Warn "Backed up existing $sub profile to $bak" }
        }
        Set-Content -Path $target -Value $loader -Encoding UTF8
        Write-Ok "Profile loader installed: $target"
    }
    Write-Warn "Restart PowerShell to pick up the managed profile."
}

# The portable GUI .zips ship no Start Menu shortcut, so the GUI hides
# behind the PATH'd exe. Data-driven: every $PortableTools entry with the
# opt-in Shortcut key (dnGrep/LogExpert) gets a per-user "<Name>.lnk".
# Fixed filename per tool -> idempotent + duplicate-proof; runs every
# bootstrap (self-heals a deleted shortcut). Soft-fails per tool.
function Invoke-StartMenuShortcuts {
    foreach ($tool in ($PortableTools | Where-Object { $_.ContainsKey('Shortcut') })) {
        # Resolve the GUI launcher. Prefer the portable install dir; fall back to
        # PATH (e.g. -SkipToolInstall with the tool already installed elsewhere).
        $target = $tool.Shortcut.Target
        $exe = Join-Path $tool.Dest "$target.exe"
        if (-not (Test-Path $exe)) {
            $cmd = Get-Command $target -ErrorAction SilentlyContinue
            if ($cmd) {
                $exe = $cmd.Source
            } else {
                Write-Warn "Skipping $($tool.Name) Start Menu shortcut — $target.exe not found at $($tool.Dest) or on PATH."
                continue
            }
        }

        # Fixed filename in the per-user Start Menu Programs folder (no admin). The
        # deterministic path is what makes this duplicate-proof: .Save() overwrites.
        $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$($tool.Name).lnk"

        try {
            $existed = Test-Path $lnk
            $wsh = New-Object -ComObject WScript.Shell
            try {
                # CreateShortcut loads the existing .lnk when present, so its current
                # TargetPath is readable — skip the rewrite when it already matches.
                $sc = $wsh.CreateShortcut($lnk)
                if ($existed -and ($sc.TargetPath -eq $exe)) {
                    Write-Ok "$($tool.Name) Start Menu shortcut already present"
                    continue
                }
                $sc.TargetPath       = $exe
                $sc.WorkingDirectory = $env:USERPROFILE
                $sc.Description       = $tool.Shortcut.Description
                $sc.Save()
                if ($existed) {
                    Write-Ok "$($tool.Name) Start Menu shortcut updated (target: $exe)"
                } else {
                    Write-Ok "$($tool.Name) Start Menu shortcut created at $lnk"
                }
            } finally {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
            }
        } catch {
            Write-Warn "Could not create the $($tool.Name) Start Menu shortcut: $($_.Exception.Message)"
        }
    }
}

# Deterministic Warp launch entries. Warp's + menu is its launch surface
# (no profile list), so unlike Windows Terminal the local shells need
# generated entries. Files prefixed workstation- are owned by this
# function; every run wipes and rewrites them; user-created configs are
# never touched. Warp supports pwsh/PowerShell 5/WSL2/Git Bash only, NOT
# Nushell -- the Nushell entry is a compatibility shim (pwsh launches the
# portable nu.exe as a child); Nushell's first-class home stays Windows
# Terminal's defaultProfile.
function Invoke-WarpTabConfigs {
    if (-not (Test-InstallerPresent -DisplayName $WarpTool.DetectName)) {
        Write-Warn "Skipping Warp Tab Config generation — Warp is not installed."
        return
    }

    $dir = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # The workstation- prefix IS the managed namespace: wipe only those.
        Get-ChildItem -Path $dir -Filter "workstation-*.toml" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $configs = @{
            "workstation-wsl-almalinux-9.toml" = @'
name = "WSL: AlmaLinux-9"
title = "AlmaLinux-9"
color = "blue"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = ['wsl.exe --distribution AlmaLinux-9 --cd ~']
is_focused = true
'@
            "workstation-powershell.toml" = @'
name = "Windows PowerShell"
title = "PowerShell"
color = "blue"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = []
is_focused = true
'@
            "workstation-nushell-compat.toml" = @'
name = "Nushell (compatibility)"
title = "Nushell compatibility"
color = "magenta"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = ['& "$env:LOCALAPPDATA\workstation\nu\nu.exe" --login']
is_focused = true
'@
        }
        foreach ($entry in $configs.GetEnumerator()) {
            [System.IO.File]::WriteAllText((Join-Path $dir $entry.Key), $entry.Value.Trim() + "`n", $utf8)
        }
        Write-Ok "Warp Tab Configs regenerated ($($configs.Count) local shells, $dir)"
    } catch {
        Write-Warn "Could not generate Warp Tab Configs: $($_.Exception.Message)"
    }
}

# Nushell can't `eval`, so the Starship prompt is a GENERATED file written
# to %APPDATA%\nushell\vendor\autoload\starship.nu (auto-sourced on every
# nu startup). config.nu owns the hand-written config; this owns only the
# generated prompt. Runs every bootstrap, no stamp -- self-heals a deleted
# file or a Starship pin-bump.
function Invoke-NushellStarship {
    if (-not (Get-Command starship -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell starship prompt — starship not on PATH (install step skipped?)."
        return
    }
    if (-not (Get-Command nu -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell starship prompt — nu not on PATH (install step skipped?)."
        return
    }

    $autoload = Join-Path $env:APPDATA "nushell\vendor\autoload"
    $target   = Join-Path $autoload "starship.nu"
    try {
        if (-not (Test-Path $autoload)) { New-Item -ItemType Directory -Force -Path $autoload | Out-Null }
        # starship emits the nu prompt wiring on stdout. Write UTF-8 WITHOUT a
        # BOM — nu chokes on a leading BOM in sourced scripts.
        $init = (& starship init nu) -join "`n"
        [System.IO.File]::WriteAllText($target, $init, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Nushell starship prompt generated ($target)"
    } catch {
        Write-Warn "Could not generate the Nushell starship prompt: $($_.Exception.Message)"
    }
}

# dnGrep stores settings NEXT TO THE EXE, so a pin bump's 'tree' wipe would
# destroy them. Seeds dnGrep.config.xml redirecting DataDirectory/
# LogDirectory to %APPDATA%\dnGREP instead (values must be EXPANDED paths
# -- dnGrep doesn't expand %ENV% vars). Seed-if-absent ONLY: dnGrep's
# Options dialog rewrites this same file, so overwriting every run would
# clobber a user's choice.
function Invoke-DnGrepConfig {
    if (-not (Test-Path (Join-Path $WsDnGrep "dnGREP.exe"))) {
        Write-Warn "Skipping dnGrep config seed — dnGREP.exe not found at $WsDnGrep (install step skipped?)."
        return
    }

    $cfg = Join-Path $WsDnGrep "dnGrep.config.xml"

    # The redirect TARGETS must exist, not just the config file: dnGrep
    # enumerates DataDirectory at startup (AppTheme.LoadExternalThemes does
    # Directory.GetFiles over it) and CRASHES with DirectoryNotFoundException
    # if it's missing — it auto-creates only its DEFAULT data folder, never a
    # config-file value (caught on first launch, 2026-07-15). On the
    # already-present path, read the dirs from the file itself so a
    # user-customized location is healed too.
    if (Test-Path $cfg) {
        try {
            $existing = [xml](Get-Content -Raw $cfg)
            foreach ($dir in @($existing.DirectoryConfiguration.DataDirectory,
                               $existing.DirectoryConfiguration.LogDirectory)) {
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            }
        } catch {
            Write-Warn "Could not verify the dnGrep data dirs: $($_.Exception.Message)"
        }
        Write-Ok "dnGrep config already present ($cfg)"
        return
    }

    $dataDir = Join-Path $env:APPDATA "dnGREP"
    $logDir  = Join-Path $dataDir "logs"
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<DirectoryConfiguration>
  <DataDirectory>$dataDir</DataDirectory>
  <LogDirectory>$logDir</LogDirectory>
</DirectoryConfiguration>
"@
    try {
        # Dirs first, config second — if creation fails, no config is written
        # and dnGrep falls back to its built-in (exe-dir) behavior instead of
        # crashing on a dangling redirect. -Force creates $dataDir with it.
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        # UTF-8 without BOM (matches the XML declaration; dnGrep reads it fine).
        [System.IO.File]::WriteAllText($cfg, $xml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "dnGrep config seeded (settings dir -> $dataDir)"
    } catch {
        Write-Warn "Could not seed the dnGrep config: $($_.Exception.Message)"
    }
}

# `mise activate nu` output saved as a GENERATED file under vendor\autoload
# (auto-sourced on startup, exactly like starship.nu), regenerated every
# run so it tracks the installed mise. Never hand-edited, never in
# config.nu; its export-env hook puts mise's real bin dirs on PATH ahead of
# the shims dir Invoke-MiseRuntimes added.
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

# =============================================================================
# CLAUDE / PYTHON / FONTS / SSH
# =============================================================================

# BurntToast -- lets `New-BurntToastNotification` surface native Windows
# toasts. Used by the WSL2 branch of dotfiles/claude/notify.sh (deployed to
# ~/.claude/notify.sh on owned Linux hosts) to ping Windows when Claude
# Code needs attention; falls back to a MessageBox if the module is absent.
function Invoke-InstallBurntToast {
    if ($SkipBurntToast) {
        Write-Log "BurntToast install skipped (-SkipBurntToast)"
        return
    }

    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
        Write-Ok "BurntToast already installed"
        return
    }

    Write-Log "Installing BurntToast PowerShell module (CurrentUser scope)..."

    try {
        # PSGallery defaults to Untrusted — Install-Module would prompt
        # interactively. Flip to Trusted (process-wide, idempotent) so the
        # install runs unattended. -ErrorAction SilentlyContinue covers the
        # case where PSGallery isn't registered at all (very old PS).
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Ok "BurntToast installed"
    } catch {
        Write-Warn "BurntToast install failed: $_"
        Write-Warn "  Claude Code WSL2 notifications will fall back to a MessageBox dialog."
        Write-Warn "  Retry manually:  Install-Module BurntToast -Scope CurrentUser"
    }
}

function Invoke-ClaudeSettingsMerge {
    # ~/.claude/settings.json three-layer merge: seed (personal defaults,
    # set-if-absent) -> live file -> enforced (infra keys that always win).
    # Ports the SAME jq filter (`.[0] * .[1] * .[2]`) scripts/lib/
    # claude-settings-merge.sh uses on Linux -- one source of truth for the
    # merge semantics, two callers. Soft-failing by design: every expected
    # failure (no jq, missing source, invalid JSON, a write failure) warns
    # and returns, never aborts bootstrap.
    $seed     = Join-Path $RepoPath "dotfiles\claude\settings.seed.json"
    $enforced = Join-Path $RepoPath "dotfiles\claude\settings.enforced.json"
    $dest     = Join-Path $env:USERPROFILE ".claude\settings.json"

    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        Write-Warn "jq not found on PATH -- skipping Claude settings merge ($dest left as-is)"
        return
    }
    if (-not (Test-Path -LiteralPath $seed)) {
        Write-Warn "missing $seed -- skipping Claude settings merge"
        return
    }
    if (-not (Test-Path -LiteralPath $enforced)) {
        Write-Warn "missing $enforced -- skipping Claude settings merge"
        return
    }

    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    # jq.exe writes UTF-8; force the same on the read side regardless of the
    # console's default code page (mirrors $PROFILE's own
    # [Console]::OutputEncoding override) so a non-ASCII value round-trips.
    $prevOutputEncoding = $OutputEncoding
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $currentTmp = Join-Path $destDir ".settings.json.current.$PID.tmp"
    $outTmp     = Join-Path $destDir ".settings.json.$PID.tmp"
    try {
        if (Test-Path -LiteralPath $dest) {
            $currentOut = & jq -c '.' $dest 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $currentOut) {
                Write-Warn "$dest is not valid JSON -- leaving it untouched"
                return
            }
            [System.IO.File]::WriteAllText($currentTmp, ($currentOut -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        } else {
            [System.IO.File]::WriteAllText($currentTmp, '{}', (New-Object System.Text.UTF8Encoding($false)))
        }

        $mergedOut = & jq -s '.[0] * .[1] * .[2]' $seed $currentTmp $enforced 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $mergedOut) {
            Write-Warn "jq merge failed -- leaving $dest untouched"
            return
        }

        [System.IO.File]::WriteAllText($outTmp, ($mergedOut -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Force -LiteralPath $outTmp -Destination $dest
        Write-Ok "merged seed + live + enforced -> $dest"
    } catch {
        Write-Warn "Claude settings merge failed: $_"
    } finally {
        $OutputEncoding = $prevOutputEncoding
        Remove-Item -Force -ErrorAction SilentlyContinue $currentTmp
        Remove-Item -Force -ErrorAction SilentlyContinue $outTmp
    }
}

function Invoke-ClaudeSettingsLocalSeed {
    # ~/.claude/settings.local.json -- seed-if-absent (Windows half of Linux
    # tasks/bootstrap step 6b). Unlike settings.json there's no enforced
    # layer reapplied every run: a plain seed, written ONLY when the live
    # file doesn't exist yet, so a fresh host gets the tracked default
    # ({"spinnerTipsEnabled": false}) without ever clobbering a later edit.
    $seedSrc = Join-Path $RepoPath "dotfiles\claude\settings.local.json"
    $dest    = Join-Path $env:USERPROFILE ".claude\settings.local.json"

    if (-not (Test-Path -LiteralPath $seedSrc)) {
        Write-Warn "missing $seedSrc -- skipping settings.local.json seed"
        return
    }
    if (Test-Path -LiteralPath $dest) {
        return # already present -- never overwrite a live file here (seed-if-absent only)
    }
    try {
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $seedSrc -Destination $dest
        Write-Ok "seeded $dest"
    } catch {
        Write-Warn "failed to seed $dest -- inspect by hand: $_"
    }
}

# Native Windows install via Anthropic's official installer script (verifies
# claude.exe's sha256 against the signed release manifest, then wires up the
# launcher/PATH/shell integration itself). NOT $PortableTools -- it
# self-updates in the background (mirrors the rolling Linux install). NOT
# $InstallerTools -- no Uninstall-registry entry, no GitHub release.
# Detect-by-command, skip when present. Runs in a CHILD powershell.exe: the
# installer script calls `exit` on its error paths, which would kill this
# bootstrap if dot-run in-process.
function Invoke-InstallClaudeCode {
    if ($SkipToolInstall) {
        Write-Log "Claude Code install skipped (-SkipToolInstall)"
        return
    }
    $claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path $claudeExe)) {
        Write-Ok "Claude Code already installed (self-updates in the background)"
        return
    }
    Write-Log "Installing Claude Code (official installer, manifest-verified)..."
    $tmp = Join-Path $env:TEMP "claude-install-$PID.ps1"
    try {
        # Download-then-run with checked curl.exe status — same posture as
        # the Linux side's pipe.sh.
        Invoke-CurlRequest -Uri "https://claude.ai/install.ps1" -OutFile $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) { throw "installer exited with code $LASTEXITCODE" }
        Write-Ok "Claude Code installed (launcher in ~\.local\bin; self-updates)"
    } catch {
        Write-Warn "Claude Code install failed: $_"
        Write-Warn "  Retry by re-running bootstrap.ps1 (leave -SkipToolInstall unset)."
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# The blessed uv-built venv (Windows half of the Linux `python-env` mise
# task). uv (mise-managed, via `mise which uv`) installs the pinned CPython
# and rebuilds the env from scratch; wpy/textual/typer .cmd shims land in
# $WsBin. Stamp bakes the pin + lib list, so a bump rebuilds on the next
# bootstrap (a lib upgrade alone is "delete the stamp, re-run").
# Get-PythonEnvStamp — the exact stamp path Invoke-PythonEnv writes on
# success (pin + a hash of the lib list). Doctor calls this SAME helper so
# its "already built" check can never drift onto a stale stamp left behind
# by an older pin.
function Get-PythonEnvStamp {
    $libBytes = [System.Text.Encoding]::UTF8.GetBytes(($PythonLibs -join ' '))
    $libStream = New-Object System.IO.MemoryStream (,$libBytes)
    $libHash = (Get-FileHash -InputStream $libStream -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
    return Join-Path $WsStamps "python-env.$PythonEnvVersion.$libHash.stamp"
}

function Invoke-PythonEnv {
    if ($SkipToolInstall) {
        Write-Log "Python env skipped (-SkipToolInstall)"
        return
    }
    # uv is a mise runtime now: ask mise for the binary config.toml declares
    # (no fixed path — mise's data dir owns the install).
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

    # Stamp bakes pin + lib list (the Linux stamp's cksum analog); shared with
    # Doctor via Get-PythonEnvStamp so the two checks can't drift apart.
    $stamp = Get-PythonEnvStamp
    $wpyShim = Join-Path $WsBin "wpy.cmd"
    if ((Test-Path $stamp) -and (Test-Path $wpyShim)) {
        Write-Ok "Python env $PythonEnvVersion already built ($WsPythonEnv)"
        return
    }

    Write-Log "Building Python scripting env $PythonEnvVersion ($($PythonLibs.Count) libs)..."
    try {
        & $uvExe python install $PythonEnvVersion
        if ($LASTEXITCODE -ne 0) { throw "uv python install exited $LASTEXITCODE" }
        if (Test-Path $WsPythonEnv) { Remove-Item -Recurse -Force $WsPythonEnv }
        & $uvExe venv --python $PythonEnvVersion $WsPythonEnv
        if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        $envPy = Join-Path $WsPythonEnv "Scripts\python.exe"
        & $uvExe pip install --python $envPy --upgrade $PythonLibs
        if ($LASTEXITCODE -ne 0) { throw "uv pip install exited $LASTEXITCODE" }

        # Launcher shims — wpy calls the env python; textual/typer call the
        # env's entry-point exes. $WsBin is already on the User PATH.
        $scripts = Join-Path $WsPythonEnv "Scripts"
        Set-Content -Path $wpyShim -Value "@echo off`r`n`"$envPy`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "textual.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'textual.exe')`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "typer.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'typer.exe')`" %*" -Encoding Ascii

        # Self-heal: remove the workstation.cmd shim from the removed
        # workstation TUI (stale shim from earlier bootstraps).
        Remove-Item -Path (Join-Path $WsBin "workstation.cmd") -ErrorAction SilentlyContinue

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        Get-ChildItem -Path $WsStamps -Filter "python-env.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "Python env $PythonEnvVersion built ($WsPythonEnv; launchers: wpy, textual, typer)"
    } catch {
        Write-Warn "Python env build failed: $($_.Exception.Message)"
        Write-Warn "  Re-run .\bootstrap.ps1 to retry (no stamp was written)."
    }
}

# JetBrainsMono Nerd Font Mono, per-user. Required by dotfiles-tracked
# configs that assume Nerd Font glyphs (starship, eza, lazygit, k9s, yazi,
# broot, helix, ccstatusline, Claude Code TUI). Delegates to
# scripts/install-nerd-fonts.ps1, which also registers a per-user at-logon
# scheduled task -- HKCU per-user fonts don't reliably load at logon alone.
function Invoke-InstallNerdFonts {
    if ($SkipNerdFonts) {
        Write-Log "Nerd Fonts install skipped (-SkipNerdFonts)"
        return
    }

    $InstallScript = Join-Path $RepoPath 'scripts\install-nerd-fonts.ps1'
    if (-not (Test-Path $InstallScript)) {
        Write-Warn "Nerd Fonts installer not found at $InstallScript — skipping"
        return
    }

    try {
        & $InstallScript
    } catch {
        Write-Warn "Nerd Fonts install failed: $_"
        Write-Warn "  Glyphs in starship / eza / lazygit / etc. will render as tofu."
        Write-Warn "  Retry manually:  & '$InstallScript'"
    }
}

# SSH key (optional, prompt-driven).
function Invoke-EnsureSshKey {
    if ($SkipKeyGen) {
        Write-Log "SSH-key check skipped (-SkipKeyGen)"
        return
    }

    if (Test-Path "$SshKey.pub") {
        Write-Ok "SSH key already present at $SshKey"
        return
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen unavailable — install OpenSSH client and re-run, or pass -SkipKeyGen."
        return
    }

    Write-Warn "No SSH key at $SshKey"
    $ans = Read-Host "  Generate one now? [Y/n]"
    if (-not $ans) { $ans = "Y" }
    if ($ans -notmatch '^[Yy]') {
        Write-Warn "Skipped — generate later with:  ssh-keygen -t ed25519"
        return
    }

    $sshDir = Split-Path $SshKey -Parent
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }

    ssh-keygen -t ed25519 -f $SshKey -N '""' -C "$env:USERNAME@$env:COMPUTERNAME"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "ssh-keygen failed"
    }
    Write-Ok "Generated $SshKey"
}

# =============================================================================
# DOCTOR / CHECK-FOR-UPDATES -- read-only report modes (-Doctor /
# -CheckForUpdates). Both exit before the provisioning flow starts: nothing
# is installed, cloned, applied, or written. The Windows counterpart of
# bootstrap.sh --doctor / --check-for-updates (whose tool knowledge lives in
# config*.toml + tasks/; here the manifests in THIS script are the source of truth).
# =============================================================================

# Shared by both modes: fetch (best-effort), then report branch, ahead/behind
# the upstream, and working-tree cleanliness. Returns $true when a repo exists.
function Show-RepoState {
    Write-Log "Workstation repo ($RepoPath)"
    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Bad "no repo at $RepoPath — run .\bootstrap.ps1 first (or pass -RepoPath)"
        return $false
    }

    # PS 5.1: native stderr + 2>$null under $ErrorActionPreference=Stop throws
    # NativeCommandError — relax EAP around every git call in this function.
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $null = git -C $RepoPath fetch --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "git fetch failed (offline or stale credentials) — using last-known remote state"
        } else {
            Write-Ok "fetched origin"
        }

        $branch   = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
        $dirty    = @(git -C $RepoPath status --porcelain 2>$null).Count
        $upstream = git -C $RepoPath rev-parse --abbrev-ref '@{upstream}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $upstream) {
            $behind = [int](git -C $RepoPath rev-list --count "HEAD..@{upstream}" 2>$null)
            $ahead  = [int](git -C $RepoPath rev-list --count "@{upstream}..HEAD" 2>$null)
            if ($behind -gt 0) {
                Write-Warn "branch $branch is $behind commit(s) behind $upstream — update with: git -C $RepoPath pull --ff-only"
            } else {
                Write-Ok "branch $branch is up to date with $upstream"
            }
            if ($ahead -gt 0) { Write-Warn "$ahead local commit(s) not pushed — push with: git -C $RepoPath push" }
        } else {
            Write-Warn "branch $branch has no upstream — behind/ahead unknown"
        }

        if ($dirty -gt 0) {
            Write-Warn "$dirty uncommitted change(s) — review with: git -C $RepoPath status"
        } else {
            Write-Ok "working tree clean"
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return $true
}

# Newest upstream tag via `git ls-remote --tags` — plain git, no GitHub API,
# no rate limits. $Repo is owner/repo or a full git URL; $TagPrefix is what
# precedes the version in the tag name; $Filter accepts version shapes after
# the prefix strip (default: clean dotted numerics — drops -rc/-pre tags);
# -StringSort for date-style tags [version] can't parse.
# Returns $null when nothing matches (offline, renamed tag scheme).
function Get-LatestGitTag {
    param(
        [string]$Repo,
        [string]$TagPrefix = "v",
        [string]$Filter = '^\d+(\.\d+)*$',
        [switch]$StringSort
    )
    $url = if ($Repo -match '://') { $Repo } else { "https://github.com/$Repo.git" }

    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'
    $refs = git ls-remote --tags --refs $url "refs/tags/$TagPrefix*" 2>$null
    $ErrorActionPreference = $oldEap
    if ($LASTEXITCODE -ne 0 -or -not $refs) { return $null }

    $vers = @(foreach ($line in @($refs)) {
        $tag = ($line -split "`t")[-1] -replace '^refs/tags/', ''
        if ($TagPrefix -and -not $tag.StartsWith($TagPrefix)) { continue }
        $v = $tag.Substring($TagPrefix.Length)
        if ($v -match $Filter) { $v }
    })
    if ($vers.Count -eq 0) { return $null }
    if ($StringSort) { return ($vers | Sort-Object -Descending | Select-Object -First 1) }
    return ($vers | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

# Newest published version of a winget package, from the microsoft/winget-pkgs
# manifest tree: the given directory holds one subdirectory per published
# version and the names ARE the versions (Beyond Compare's are 4-part —
# 5.2.3.32296 — matching its download URLs, which embed the build number).
# The version source for $InstallerTools entries whose upstream has NO GitHub
# presence at all (no releases AND no tags). Anonymous API works (60 req/hr);
# Get-GitHubApiHeaders lifts the limit when $env:GITHUB_TOKEN is set.
# Returns the raw directory name of the highest [version], or $null on ANY
# failure (offline, rate-limited, tree moved, nothing parses) — callers
# warn + skip.
function Get-LatestWingetVersion {
    param([string]$Path)
    $headers = Get-GitHubApiHeaders
    try {
        $entries = Invoke-CurlRequest `
            -Uri "https://api.github.com/repos/microsoft/winget-pkgs/contents/$Path" `
            -Headers $headers | ConvertFrom-Json -ErrorAction Stop
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

# DisplayVersion from the Uninstall registry (same three roots as
# Test-InstallerPresent). $null when not installed or no version recorded.
function Get-InstalledAppVersion {
    param([string]$DisplayName)
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $hit = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
               Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayName } |
               Select-Object -First 1
        if ($hit -and $hit.PSObject.Properties['DisplayVersion']) { return $hit.DisplayVersion }
    }
    return $null
}

# One report line comparing a pinned/installed version against the upstream
# latest. -StringSort for date-style tags; otherwise [version] comparison with
# a string-inequality fallback.
function Write-UpdateStatus {
    param([string]$Name, [string]$Pinned, [string]$Latest, [string]$Hint = "", [switch]$StringSort)
    if (-not $Latest) {
        Write-Warn "${Name}: couldn't resolve the latest release (offline? upstream tag scheme changed?)"
        return
    }
    if ($Latest -eq $Pinned) {
        Write-Ok "$Name $Pinned is up to date"
        return
    }
    $newer = $false
    if ($StringSort) {
        $newer = ($Latest -gt $Pinned)
    } else {
        try   { $newer = ([version]$Latest -gt [version]$Pinned) }
        catch { $newer = $true }   # unparseable mismatch — surface it as an update
    }
    if ($newer) {
        $suffix = if ($Hint) { " — $Hint" } else { "" }
        Write-Warn "$Name $Pinned -> $Latest available$suffix"
    } else {
        Write-Ok "$Name $Pinned (newest upstream tag: $Latest)"
    }
}

function Invoke-Doctor {
    Write-Log "Doctor — read-only health report; nothing is installed or changed"
    Write-Host ""

    Write-Log "Prerequisites"
    $curlCmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curlCmd) { Write-Ok "curl.exe ($($curlCmd.Source))" }
    else { Write-Bad "curl.exe missing (hard prerequisite) — https://curl.se/windows/" }
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { Write-Ok "git ($($gitCmd.Source))" }
    else         { Write-Bad "git missing (hard prerequisite) — https://git-scm.com/download/win or: winget install Git.Git" }
    if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) { Write-Ok "ssh-keygen" }
    else { Write-Warn "ssh-keygen not on PATH — Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" }
    Write-Host ""

    if ($gitCmd) { $null = Show-RepoState; Write-Host "" }

    Write-Log "mise dotfiles"
    $miseCmd = Get-Command mise -ErrorAction SilentlyContinue
    if ($miseCmd) {
        Write-Ok "mise on PATH ($($miseCmd.Source))"
        Initialize-MiseEnv
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & mise dot status --missing *> $null
        $statusRc = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($statusRc -eq 0) {
            Write-Ok "deployed dotfiles in sync with the source (mise dot status)"
        } else {
            Write-Warn "drift, or not yet applied — inspect: mise dot status · apply: wsa (asks before overwriting a local edit)"
        }
    } else {
        Write-Warn "mise not on PATH — re-run .\bootstrap.ps1 (or open a NEW shell if it just installed)"
    }
    Write-Host ""

    Write-Log "Portable tools ($WsRoot)"
    foreach ($tool in $PortableTools) {
        $stamp = Join-Path $WsStamps "$($tool.Exe).$($tool.Version).stamp"
        $cmd   = Get-Command $tool.Exe -ErrorAction SilentlyContinue
        if ($cmd -and (Test-Path $stamp)) {
            Write-Ok "$($tool.Name) $($tool.Version) installed ($($cmd.Source))"
        } elseif ($cmd) {
            Write-Warn "$($tool.Name) on PATH but no $($tool.Version) stamp — pin moved? next bootstrap reinstalls"
        } elseif (Test-Path $stamp) {
            Write-Bad "$($tool.Name) stamped but $($tool.Exe).exe doesn't resolve — open a NEW shell, or re-run .\bootstrap.ps1"
        } else {
            Write-Bad "$($tool.Name) missing — re-run .\bootstrap.ps1"
        }
    }
    Write-Host ""

    Write-Log "Installer apps + extras"
    if (Test-InstallerPresent -DisplayName $WarpTool.DetectName) {
        $warpVer  = Get-InstalledAppVersion -DisplayName $WarpTool.DetectName
        $warpText = if ($warpVer) { " $warpVer" } else { "" }
        Write-Ok "Warp$warpText installed (the primary terminal; self-updates; official WinGet package)"
    } else {
        Write-Bad "Warp not installed — re-run .\bootstrap.ps1 or: winget install Warp.Warp"
    }
    $wtPkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
    if ($wtPkg) { Write-Ok "Windows Terminal $($wtPkg.Version) installed (self-updates via Microsoft Store)" }
    elseif (Get-Command wt.exe -ErrorAction SilentlyContinue) { Write-Ok "Windows Terminal installed (wt.exe on PATH)" }
    else { Write-Bad "Windows Terminal not installed — re-run .\bootstrap.ps1 or: winget install Microsoft.WindowsTerminal" }
    foreach ($tool in $InstallerTools) {
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            $hint = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "self-updates; -ForceInstaller to reseed" }
            Write-Ok "$($tool.Name)$verText installed ($hint)"
        } else {
            Write-Bad "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        }
    }

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
    if (Get-Command code -ErrorAction SilentlyContinue) { Write-Ok "VSCode on PATH (hand-installed)" }
    else { Write-Warn "VSCode not on PATH — hand-install when wanted; its dotfiles deploy regardless" }
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    $claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if ($claudeCmd) {
        Write-Ok "Claude Code installed ($($claudeCmd.Source); self-updates in the background)"
    } elseif (Test-Path $claudeExe) {
        Write-Warn "Claude Code installed at $claudeExe but not on PATH — open a NEW shell"
    } else {
        Write-Bad "Claude Code not installed — re-run .\bootstrap.ps1"
    }
    $bt = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue |
          Sort-Object Version -Descending | Select-Object -First 1
    if ($bt) { Write-Ok "BurntToast $($bt.Version) module available (WSL2 toast notifications)" }
    else { Write-Warn "BurntToast module missing — Claude Code WSL2 toasts fall back to a MessageBox; re-run .\bootstrap.ps1" }
    $fontStamps = @(Get-ChildItem -Path $WsRoot -Filter "nerd-fonts.*.stamp" -ErrorAction SilentlyContinue)
    if ($fontStamps.Count -gt 0) {
        $fontVer = $fontStamps[0].Name -replace '^nerd-fonts\.', '' -replace '\.stamp$', ''
        Write-Ok "Nerd Fonts (JetBrainsMono) $fontVer installed (per-user)"
    } else {
        Write-Warn "Nerd Fonts not stamped — glyphs may render as tofu; re-run .\bootstrap.ps1 (or scripts\install-nerd-fonts.ps1)"
    }
    Write-Host ""

    Write-Log "Environment"
    foreach ($tool in ($PortableTools | Where-Object { $_.ContainsKey('Shortcut') })) {
        $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$($tool.Name).lnk"
        if (Test-Path $lnk) { Write-Ok "$($tool.Name) Start Menu shortcut present" }
        else { Write-Warn "$($tool.Name) Start Menu shortcut missing — re-run .\bootstrap.ps1 (self-heals it)" }
    }

    $nuStarship = Join-Path $env:APPDATA "nushell\vendor\autoload\starship.nu"
    if (Test-Path $nuStarship) { Write-Ok "Nushell starship prompt generated ($nuStarship)" }
    else { Write-Warn "Nushell starship prompt missing — re-run .\bootstrap.ps1 (regenerates it)" }

    $nuMise = Join-Path $env:APPDATA "nushell\vendor\autoload\mise.nu"
    if (Test-Path $nuMise) { Write-Ok "Nushell mise activation generated ($nuMise)" }
    else { Write-Warn "Nushell mise activation missing — re-run .\bootstrap.ps1 (regenerates it)" }

    $wpyShim = Join-Path $WsBin "wpy.cmd"
    $pyStamp = Get-PythonEnvStamp
    if ((Test-Path $wpyShim) -and (Test-Path $pyStamp)) {
        Write-Ok "Python env $PythonEnvVersion built (wpy/textual/typer in $WsBin)"
    } elseif (Test-Path $wpyShim) {
        Write-Warn "Python env shims present but pin or lib list moved — next bootstrap rebuilds"
    } else {
        Write-Bad "Python env not built — re-run .\bootstrap.ps1"
    }

    $miseStamp = Get-MiseRuntimesStamp
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Bad "mise runtimes: mise not on PATH — re-run .\bootstrap.ps1"
    } elseif ($null -eq $miseStamp) {
        Write-Bad "mise runtimes: no config.toml under $RepoPath — re-run .\bootstrap.ps1 (clone step)"
    } else {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $missing = ((& mise ls --missing --global 2>$null) | Out-String).Trim()
        $ErrorActionPreference = $oldEap
        if ((Test-Path $miseStamp) -and -not $missing) {
            Write-Ok "mise runtimes installed (nothing missing; $(Split-Path -Leaf $miseStamp))"
        } elseif (-not $missing) {
            Write-Warn "mise runtimes present but config*.toml moved (no $(Split-Path -Leaf $miseStamp)) — next bootstrap reinstalls"
        } else {
            Write-Bad "mise runtimes missing: $(($missing -split "`r?`n") -join ', ') — re-run .\bootstrap.ps1"
        }
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $shimsOnPath = @(($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $MiseShims.TrimEnd('\') }).Count -gt 0
        if ($shimsOnPath) { Write-Ok "mise shims dir on the User PATH ($MiseShims)" }
        else { Write-Warn "mise shims dir NOT on the User PATH — re-run .\bootstrap.ps1 (self-heals)" }
    }

    # MISE_ENV is set by Invoke-MiseRuntimes right after it finds mise on PATH;
    # check it independently so Doctor still reports a missing/stale value even
    # when the tool-install branches above never ran this session.
    if ([Environment]::GetEnvironmentVariable("MISE_ENV", "User") -eq $MiseEnv) {
        Write-Ok "MISE_ENV=$MiseEnv persisted (User)"
    } else {
        Write-Warn "MISE_ENV not persisted — re-run .\bootstrap.ps1"
    }

    $dnGrepCfg = Join-Path $WsDnGrep "dnGrep.config.xml"
    if (Test-Path $dnGrepCfg) { Write-Ok "dnGrep config seeded ($dnGrepCfg)" }
    else { Write-Warn "dnGrep config not seeded — settings would die with a pin bump; re-run .\bootstrap.ps1 (re-seeds it)" }

    $warpTabDir  = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
    $warpTabs    = @(Get-ChildItem -Path $warpTabDir -Filter "workstation-*.toml" -File -ErrorAction SilentlyContinue)
    if ($warpTabs.Count -gt 0) {
        Write-Ok "$($warpTabs.Count) managed Warp Tab Config(s) present"
    } else {
        Write-Warn "managed Warp Tab Configs missing — re-run .\bootstrap.ps1 (regenerates them)"
    }

    $realDocs    = [Environment]::GetFolderPath("MyDocuments")
    $literalDocs = Join-Path $env:USERPROFILE "Documents"
    if ([string]::IsNullOrEmpty($realDocs) -or ($realDocs -eq $literalDocs)) {
        Write-Ok "Documents not redirected — PowerShell loads the managed profile directly"
    } else {
        $loaderOk = $true
        foreach ($sub in @("WindowsPowerShell", "PowerShell")) {
            if (-not (Test-Path (Join-Path (Join-Path $realDocs $sub) "Microsoft.PowerShell_profile.ps1"))) { $loaderOk = $false }
        }
        if ($loaderOk) { Write-Ok "Documents redirected ($realDocs) — profile loaders in place" }
        else { Write-Warn "Documents redirected ($realDocs) but profile loader(s) missing — re-run .\bootstrap.ps1" }
    }

    if (Test-Path "$SshKey.pub") { Write-Ok "SSH key present ($SshKey)" }
    else { Write-Warn "no SSH key at $SshKey — generate with: ssh-keygen -t ed25519 (or re-run .\bootstrap.ps1)" }
}

function Invoke-CheckForUpdates {
    Write-Log "Check for updates — workstation repo first, then tool pins vs upstream (read-only)"
    Write-Host ""

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Fail "git is required for -CheckForUpdates (repo state + ls-remote tag lookups)."
    }

    $repoOk = Show-RepoState
    if ($repoOk) {
        Write-Host "    (tool pins live in `$PortableTools of THIS clone's bootstrap.ps1 — if the repo"
        Write-Host "     is behind, pull first so the pins you're comparing are current)"
    }
    Write-Host ""

    Write-Log "Pinned portable tools"
    foreach ($tool in $PortableTools) {
        $filter    = if ($tool.ContainsKey('TagFilter')) { $tool.TagFilter } else { '^\d+(\.\d+)*$' }
        $useString = ($tool.ContainsKey('TagSort') -and $tool.TagSort -eq 'string')
        $hint      = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "" }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tool.TagPrefix -Filter $filter -StringSort:$useString
        Write-UpdateStatus -Name $tool.Name -Pinned $tool.Version -Latest $latest -Hint $hint -StringSort:$useString
    }
    Write-Host ""

    Write-Log "Installer apps (install LATEST — nothing to pin; most self-update)"
    if (Test-InstallerPresent -DisplayName $WarpTool.DetectName) {
        $warpVer  = Get-InstalledAppVersion -DisplayName $WarpTool.DetectName
        $warpText = if ($warpVer) { " $warpVer" } else { "" }
        Write-Ok "Warp$warpText installed (self-updates; check with: winget upgrade Warp.Warp)"
    } else {
        Write-Warn "Warp not installed — re-run .\bootstrap.ps1 or: winget install Warp.Warp"
    }
    $wtPkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
    if ($wtPkg) {
        Write-Ok "Windows Terminal $($wtPkg.Version) installed (self-updates via Store; check with: winget upgrade Microsoft.WindowsTerminal)"
    } elseif (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        Write-Ok "Windows Terminal installed (self-updates via Store; check with: winget upgrade Microsoft.WindowsTerminal)"
    } else {
        Write-Warn "Windows Terminal not installed — re-run .\bootstrap.ps1 or: winget install Microsoft.WindowsTerminal"
    }
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = if ($tool.ContainsKey('WingetVersions')) {
            Get-LatestWingetVersion -Path $tool.WingetVersions
        } else {
            $tagPrefix = if ($tool.ContainsKey('TagPrefix')) { $tool.TagPrefix } else { 'v' }
            Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix
        }
        $hasHint   = $tool.ContainsKey('UpdateHint')
        if (-not (Test-InstallerPresent -DisplayName $tool.DetectName)) {
            Write-Warn "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        } elseif ($installed -and $latest) {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app; -ForceInstaller reseeds' }
            Write-UpdateStatus -Name $tool.Name -Pinned $installed -Latest $latest -Hint $hint
        } elseif ($latest) {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app' }
            Write-Ok "$($tool.Name) installed (latest upstream: $latest; $hint)"
        } else {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app' }
            Write-Ok "$($tool.Name) installed ($hint)"
        }
    }
    Write-Host ""

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
            if (-not (Test-InstallerPresent -DisplayName $msi.DetectName)) {
                Write-Warn "$($msi.Name) not installed — $($tool.Name)'s kernel-driver dependency"
            } elseif ($depInstalled -and $depLatest) {
                Write-UpdateStatus -Name $msi.Name -Pinned $depInstalled -Latest $depLatest -Hint "winget upgrade $($msi.WingetId)"
            } elseif ($depLatest) {
                Write-Ok "$($msi.Name) installed ($($tool.Name)'s kernel-driver dependency; latest upstream: $depLatest)"
            } else {
                Write-Ok "$($msi.Name) installed ($($tool.Name)'s kernel-driver dependency)"
            }
        }
    }
    Write-Host ""

    Write-Log "Other components"
    $fontStamps = @(Get-ChildItem -Path $WsRoot -Filter "nerd-fonts.*.stamp" -ErrorAction SilentlyContinue)
    if ($fontStamps.Count -gt 0) {
        $fontVer = $fontStamps[0].Name -replace '^nerd-fonts\.', '' -replace '\.stamp$', ''
        $latest  = Get-LatestGitTag -Repo 'ryanoasis/nerd-fonts'
        Write-UpdateStatus -Name 'Nerd Fonts (JetBrainsMono)' -Pinned $fontVer -Latest $latest -Hint 'triple-edit: config.toml [vars] nerd_font_version + scripts/lib/font.sh + install-nerd-fonts.ps1 (see CLAUDE.md)'
    } else {
        Write-Warn "Nerd Fonts not stamped — re-run .\bootstrap.ps1 (or scripts\install-nerd-fonts.ps1)"
    }
    $latestPy = Get-LatestGitTag -Repo 'python/cpython' -TagPrefix 'v'
    Write-UpdateStatus -Name 'Python env (CPython)' -Pinned $PythonEnvVersion -Latest $latestPy -Hint 'dual-edit: $PythonEnvVersion here AND vars.python_version in config.toml; check cp-wheel coverage first (see config.toml [vars] comment)'
    $bt = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue |
          Sort-Object Version -Descending | Select-Object -First 1
    if ($bt) { Write-Ok "BurntToast $($bt.Version) installed — update via: Update-Module BurntToast" }
    else { Write-Warn "BurntToast module missing — re-run .\bootstrap.ps1" }
    if ((Get-Command claude -ErrorAction SilentlyContinue) -or
        (Test-Path (Join-Path $env:USERPROFILE ".local\bin\claude.exe"))) {
        Write-Ok "Claude Code installed — self-updates in the background (no pin; rolling, like Linux CLAUDE_VERSION := latest)"
    } else {
        Write-Warn "Claude Code not installed — re-run .\bootstrap.ps1"
    }
}

# =============================================================================
# RUN SEQUENCE
# =============================================================================

# Read-only report modes exit here, before any provisioning state changes.
if ($Doctor -and $CheckForUpdates) {
    Write-Fail "-Doctor and -CheckForUpdates are mutually exclusive (run them one at a time)."
}
if (($Doctor -or $CheckForUpdates) -and $Reinstall) {
    Write-Fail "-Reinstall can't be combined with -Doctor/-CheckForUpdates (they are read-only and exit early)."
}
if ($Doctor)          { Invoke-Doctor;          exit 0 }
if ($CheckForUpdates) { Invoke-CheckForUpdates; exit 0 }

if ($Reinstall) { Invoke-Reinstall }
Invoke-Preflight
Invoke-ToolInstall        # admin-free binary/portable installs under %LOCALAPPDATA%\workstation
Invoke-CloneRepo
Invoke-MiseBootstrap      # `mise bootstrap --only dotfiles,tools` -- dotfiles apply + a tools pass, then the .wslconfig restart reminder
Invoke-MiseRuntimes       # node/Go/uv/gopls/LSP servers/ccstatusline from config*.toml at the repo root (self-heals the shims PATH)
Invoke-StartMenuShortcuts # per-user Start Menu .lnks for the portable GUI tools (dnGrep/LogExpert)
Invoke-WarpTabConfigs     # regenerate Warp Tab Configs (local shells) — self-heals
Invoke-NushellStarship    # generate the Nushell starship prompt (vendor/autoload — self-heals)
Invoke-DnGrepConfig       # seed dnGrep.config.xml (settings dir -> %APPDATA%\dnGREP; survives pin-bump wipes)
Invoke-NushellMise        # generate the Nushell mise activation (vendor/autoload — self-heals)
Invoke-ProfileShim        # bridge Documents redirection (OneDrive) so $PROFILE loads the managed profile
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallClaudeCode  # native Claude Code via the official installer (manifest-verified; self-updates)
Invoke-ClaudeSettingsMerge     # ~/.claude/settings.json seed+live+enforced jq merge
Invoke-ClaudeSettingsLocalSeed # ~/.claude/settings.local.json seed-if-absent
Invoke-PythonEnv          # blessed uv-built Python scripting env (wpy/textual/typer shims)
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Open a NEW shell so the updated User PATH (${Bold}$WsBin${Reset}, ${Bold}$WsHelix${Reset}, ${Bold}$WsNu${Reset},"
Write-Host "${Bold}$WsMise\bin${Reset}, ${Bold}$MiseShims${Reset} — mise-installed tools) and the mise-applied dotfiles pick up — starship prompt,"
Write-Host "git aliases, etc."
Write-Host ""
Write-Host "${Bold}Two terminals are managed.${Reset} Warp is the day-to-day one: it opens into"
Write-Host "AlmaLinux-9 (WSL zsh), and its + menu carries the generated Tab Configs for"
Write-Host "WSL, PowerShell and Nushell-compat. Windows Terminal stays fully configured as"
Write-Host "the compatibility path: Nushell is its default profile, and it keeps the"
Write-Host "Windows default-terminal-application role (Warp cannot take it). Warp"
Write-Host "hot-reloads its settings but needs a restart to notice new Tab Configs."
Write-Host ""
Write-Host "Not installed by this script (install yourself if you want it):"
Write-Host "  VSCode  — its dotfiles are already deployed."
Write-Host ""

# Print the curated hand-install shopping list (docs/windows/application_list.md).
# Personal preference order — terminals, file managers, search, editors, etc.
# Soft-skip if the file is missing (partial clone, older repo snapshot).
$appList = Join-Path $RepoPath "docs\windows\application_list.md"
if (Test-Path $appList) {
    Write-Host "${Bold}Hand-install shopping list${Reset} (docs\windows\application_list.md):"
    # -Encoding UTF8: the list is UTF-8 without a BOM, so PowerShell 5.1's
    # default (the ANSI codepage) printed every em dash as "â€”".
    Get-Content -Encoding UTF8 $appList | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

Write-Host "Editing dotfiles (new Nushell/PowerShell shell):"
Write-Host "  wse <path>   # edit a tracked file in the repo source"
Write-Host "  wsd          # see what would change"
Write-Host "  wsa          # apply; asks first if a deployed file has a local edit it would overwrite"
Write-Host "  wsr          # record an app's own edit to a deployed file back into the repo"
