# Windows: a better Nushell, and GUI apps from a declarative manifest — design

Date: 2026-10-02. Status: approved in conversation; this spec is the written record.

## 1. Intent

**What the user asked for:**
- Improve the Windows Nushell experience "significantly". They chose all four areas:
  - parity with the zsh toolbelt
  - completions everywhere
  - look, history and keys
  - self-healing setup
- Improve how Windows apps are installed. They chose a declarative app manifest. They did not choose:
  - automating the manual-install list
  - a separate apps command
  - optional app groups
- Use mise's own winget support (approach 1 of 3).

**Assumptions** (from the probes on 2026-10-01 and 2026-10-02):
- Warp stays the primary terminal; Windows Terminal is the compatibility one (CLAUDE.md).
- Every tool added on Windows is already pinned for Linux, and each publishes a Windows build at that version.
- `omp-env.nu` (untracked, in `vendor\autoload\`) holds the user's Vertex AI variables, which stay. Only its PATH line to the deleted `%LOCALAPPDATA%\omp` goes.
- `mise bootstrap packages status` works on this host. It reports installed apps through `winget list --id <Id> --exact`, and all of them are, once DevToys uses the Microsoft Store Id `9NBN8W1DS547` (winget can't match this host's Inno-installed preview to `DevToys-app.DevToys`).
- There is no winget `settings.json` on this host yet.

**Success:**
- A new Nushell tab has `z`/`zi`, Ctrl-R history search, Ctrl-T/Alt-C pickers, Tab completion for common CLIs, the Catppuccin Mocha theme, and atuin's searchable history.
- Login startup stays under 600 ms; it measured 350–400 ms on 2026-10-01.
- After `wsu` bumps a tool, the next Nushell tab uses that tool's new init code without re-running `bootstrap.ps1`.
- The GUI apps are declared once, as data, and `mise bootstrap packages status` reports them.
- Linux hosts end up with the same tools, versions and host state as before.

## 2. Tools on Windows

- `fzf`, `zoxide`, `fd`, `bat`, `delta`, `eza` and `ripgrep` move from `config.linux.toml` to `config.toml`, keeping the same pins. This mirrors PR 4's move of starship, gh, jq and helix. Locks are regenerated for both `linux-x64` and `windows-x64`.
- `github:sxyazi/yazi` and `github:atuinsh/atuin` move to `config.toml` in the `platforms = { linux-x64 = {…}, windows-x64 = {…} }` form:
  - `linux-x64` keeps today's musl `asset_pattern` (EL9's glibc is too old for the gnu builds).
  - `windows-x64` uses the `x86_64-pc-windows-msvc` zip.
- `carapace` (`github:carapace-sh/carapace-bin`, `windows_amd64` zip) is new and goes in `config.owned.toml` with `os = ["windows"]`. zsh on Linux has its own completion system and fzf-tab.
- `gitconfig.tera`: `pager` becomes `delta` on both OSes. It was `less` on Windows only because delta wasn't installed there.
- **Verification.** Record the Linux tool sets, then compare after the change, for the shared, owned-WSL and owned-native token sets: same tools, same versions. `mise bootstrap plan` must also match `main` for those three sets.

## 3. Self-healing init files

- New `scripts/nu-init.nu` (a Nushell script) writes one file per tool into `%APPDATA%\nushell\vendor\autoload\`, which Nushell loads automatically:
  - `starship.nu` from `starship init nu`
  - `mise.nu` from `mise -C <home> activate nu`
  - `zoxide.nu` from `zoxide init nushell`
  - `atuin.nu` from `atuin init nu --disable-up-arrow`

  carapace is called from `config.nu`'s external completer (after the `bootstrap.ps1` flags), because carapace's own snippet only installs a completer when none is set.
- **File rules:**
  - Each file is written without a BOM, and only when its content changed.
  - If a tool isn't on PATH, its file is removed rather than left stale.
  - The script never touches files it doesn't own; per-machine `*.nu` overrides and `omp-env.nu` stay.
- **New mise task `nu-init`** runs the script with the mise-installed `nu`. Callers:
  - `bootstrap.ps1`, replacing `Invoke-NushellStarship` and `Invoke-NushellMise`
  - a `post-tools` hook in `config.windows.toml`, so `wsu` (`mise bootstrap --only dotfiles,tools`) regenerates the files after a tool update
- **Open question, settled in the plan's first step:** does mise run bootstrap hooks on Windows, and under which shell? If not, the `wsu` definitions (Nushell and PowerShell) call `mise -C <home> run nu-init` after the bootstrap call instead, and the hook isn't added.
- **One-time cleanup.** Drop the dead PATH line from `omp-env.nu`. Done by hand on this host during rollout; not automated, because the file is untracked and personal.

## 4. config.nu

`dotfiles/windows/AppData/Roaming/nushell/config.nu.tera` keeps its current sections (ws*, git aliases, `ssh-copy-id`, `adminpw`, the WT shell-integration hooks, and the bootstrap.ps1 flag completer) and adds the following.

**Toolbelt:**
- **Navigation:** `z`/`zi` come from zoxide's init. `y` opens yazi and changes to the directory it exits in.
- **Listing:** `l`, `la`, `ll` and `lt` are aliases to `eza` with the zsh flags (`--group-directories-first --icons=auto --hyperlink`; `ll` adds `-lah --git --time-style=long-iso`; `lt` adds `--tree --level=2`). `ls` stays Nushell's structured `ls`.
- **History search:** atuin binds Ctrl-R. Up/Down stay default. If atuin's search fails inside Warp, the Ctrl-R binding is gated on `WT_SESSION`; checked live.
- **fzf pickers:**
  - Ctrl-T inserts a file picked by `fzf` (input from `fd --type f`, preview with `bat`) at the cursor.
  - Alt-C picks a directory (from `fd --type d`) and `cd`s to it.
  - Both are Nushell `keybindings` entries that run `commandline edit --insert` / `cd`.

**Completions:**
- The external completer checks the bootstrap.ps1 flag record first, then carapace, then falls back to Nushell's file completion.
- The `let workstation_bootstrap_flags` record keeps its column-0 `let`/closing lines for `check_completion_parity`.
- `completions.algorithm = "fuzzy"`, case-insensitive.

**Look:** the Catppuccin Mocha theme.
- The source is the official `catppuccin/nushell` `themes/catppuccin_mocha.nu`, vendored at a pinned commit under `dotfiles/windows/AppData/Roaming/nushell/themes/` with a `.vendor` sidecar.
- It deploys as a directory `copy` entry with `exclude = [".vendor", ".gitkeep"]`.
- `config.nu` sources it and applies its `color_config`.

**History:**
- History stays plaintext: Nushell fixes its history backend at startup, and `history import` run from a script writes into the live file (probed 2026-10-02). atuin's database carries cwd/duration/exit per command, and `nu-init` imports Nushell's history into atuin once (marker `.atuin-nu-imported` in the autoload dir).

**Editing:**
- `buffer_editor = "hx"`, so Ctrl-O opens the command line in Helix, and `$env.EDITOR = "hx"`.
- `cursor_shape.emacs = "line"`.
- `edit_mode` stays emacs.

**Safety:** `rm.always_trash = true`, so `rm` goes to the Recycle Bin and `rm --permanent` bypasses it.

**Kept:** the rounded tables, hints, `show_banner = false`, the OSC 9;9 working-directory signal and the OSC 9;4 progress hooks.

**Parity with the PowerShell profile:**
- The new `l`/`la`/`ll`/`lt`/`y` aliases are added to `Microsoft.PowerShell_profile.ps1.tera` as functions, and the `wsh` cheatsheets in both shells list them.
- Keybindings, hooks, history and theme are Nushell-only; a PARITY NOTE in config.nu says so.

## 5. GUI apps: a declarative manifest

- **The manifest.** `config.windows.toml` gains a `[bootstrap.packages]` table with eight entries, `"winget:<Id>" = "latest"`:
  - Microsoft.WindowsTerminal
  - Warp.Warp
  - Obsidian.Obsidian
  - 9NBN8W1DS547 (DevToys, Microsoft Store)
  - DBeaver.DBeaver.Community
  - WinSCP.WinSCP
  - ScooterSoftware.BeyondCompare.5
  - ZedIndustries.Zed
- **Install scope.** A new managed dotfile, `~/AppData/Local/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/settings.json` (winget's settings), sets `installBehavior.preferences.scope = "user"`. It is a preference, not a requirement, so Zed's machine-scope-only manifest still installs; its installer is per-user anyway (`PrivilegesRequired=lowest`).
- **bootstrap.ps1:**
  - After `mise bootstrap --only dotfiles,tools` (which deploys the winget settings), a second call `mise -C <home> bootstrap --only packages --yes` installs any missing apps. A single call can't do both, because mise runs packages before dotfiles.
  - Failures warn and don't stop the run, as today.
  - `-SkipToolInstall` skips the packages call.
- **SSHFS-Win stays in bootstrap.ps1** as its single special case. mise installs winget packages silently with interaction disabled, and a silent MSI install can't raise UAC.
  - The rest of `Install-WingetApps` and the `$WingetApps` table go, and SSHFS-Win's presence check becomes `winget list --id SSHFS-Win.SSHFS-Win --exact`.
  - The `Uac` handling (no `--silent`, the two-prompt warning, `-SkipElevated`) and the "already installed" exit codes stay.
  - `Test-InstallerPresent` stays, unchanged, for `Invoke-WarpTabConfigs`' Warp check.
  - `Test-WindowsTerminalPresent` stays for the WT fragments.
- **`wsu` doesn't touch apps.** A winget status check costs about 1–2 s per package.
- **README.** The Windows section says how to check and update apps: `mise bootstrap packages status`, `mise bootstrap packages apply --manager winget` and `mise bootstrap packages upgrade --manager winget`.
- **Lint (`check-invariants.sh`):**
  - every `winget:` package is declared in `config.windows.toml`
  - `winget:SSHFS-Win.SSHFS-Win` isn't in the manifest
- **Tests.** `scripts/test-winget-apps.ps1` shrinks to SSHFS-Win: no `--silent`, the UAC warning, `-SkipElevated`, the "already installed" codes, and a `winget list` hit counting as present.

## 6. Testing

**CI (the Linux `templates` job, which renders `config.nu` with mise and has the pinned `nu`; `config.nu.tera` uses no `os()`):**
- `check-templates.sh` evaluates the rendered `config.nu` and the theme with `nu`
- `scripts/test-nu-init.sh` runs `nu-init.nu` against stub tools and a temp dir
- The existing `test-winget-apps.ps1`, now SSHFS-Win only.

**Lint:** `check_completion_parity` still passes, and the new manifest check.

**Linux:** the tool-set comparison and the `mise bootstrap plan` comparison against `main` (section 2).

**Live (the user runs these on Windows):**
- **After PR A:** `.\bootstrap.ps1` reports all eight apps as already installed and installs nothing. `mise bootstrap packages status` lists eight installed.
- **After PR B:** `wsu`, then a new Windows Terminal tab. Check:
  - `z`/`zi`, Ctrl-R, Ctrl-T, Alt-C, and Tab after `git ch`
  - the theme
  - `atuin history list | first 5` lists earlier commands (imported once)
  - `rm` goes to the Recycle Bin
  - login startup under 600 ms (`Measure-Command { nu -l -c exit }`)
  - Warp's Nushell tab works, including Ctrl-R

## 7. Delivery

1. **PR A: app manifest** (section 5). Small, and independent of B.
2. **PR B: Nushell** (sections 2–4, with the Nushell tests). Its plan starts with the Windows-hooks check.

Each PR gets its own plan and live check. `README.md` changes ship with the behaviour, and `CLAUDE.md` changes stay within its 14,000-byte budget.

## 8. Out of scope

- automating the hand-install list (`docs/windows/application_list.md`)
- a dedicated apps command, and optional app groups
- replacing `ls`/`cat`
- Nushell plugins
- vi mode
- changing Warp or Windows Terminal settings
- Linux shell changes, except the `gitconfig` pager line, which renders the same on Linux

## 9. Risks

| Risk | Mitigation |
|---|---|
| Nushell config keys change across 0.x bumps | `check-templates.sh` evaluates `config.nu` with the pinned `nu`, failing a bump before it reaches the shell |
| `winget list` misses an app installed outside winget on a new host | winget installs over it once, which is harmless; on this host DevToys needed its Store Id; the probe in the plan catches such cases |
| atuin's TUI misbehaves in Warp | Ctrl-R binding gated on `WT_SESSION` if the live check fails |
| mise doesn't run bootstrap hooks on Windows | `wsu` calls `mise run nu-init` directly (decided in plan step 1) |
| Startup slows with four init files | Measured live; the budget is 600 ms. carapace's completer runs only on Tab |
| Moving tools to `config.toml` changes Linux | Tool-set and bootstrap-plan comparisons for all three Linux sets |
| The winget settings dotfile overwrites user settings | The file doesn't exist on this host; it's a managed `copy` entry, so later edits show as drift that `wsa` catches |
