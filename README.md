# workstation

Dev-environment provisioning for Linux hosts (native and WSL), plus Warp and Windows Terminal on Windows. One command per host installs the tools, system packages, `/etc` files, services and dotfiles.

## What this is

One entry script per OS (`bootstrap.sh`, `bootstrap.ps1`) installs a pinned mise (mise.jdx.dev) and hands off to it. mise owns every tool and every piece of host state. **This checkout is mise's global config directory**: `~/.config/mise` on Linux, `%USERPROFILE%\.config\mise` on Windows.

| Piece | Role |
|---|---|
| `bootstrap.sh` / `bootstrap.ps1` | Install pinned mise, decide the system steps, run mise. Nothing is installed by hand in the scripts beyond mise (and, on Windows, SSHFS-Win). |
| mise tools | Every tool is a pin in `config.toml` / `config.linux.toml`. `mise ls` is the tool list. |
| `mise bootstrap` | Host state from `[bootstrap.*]` tables: dnf packages, `/etc` files, services, repos, dotfiles, then the tools and the `bootstrap` task. |
| `mise dot` (`[dotfiles]`) | Personal config under `$HOME`, templated per machine. Every deployed file is an independent copy, never a symlink into the checkout. |
| starship, zsh plugins, fzf, zoxide | Prompt, completion, fuzzy find and directory jumping. |
| zellij | Persistent sessions; runs on the remote host so a dropped SSH tab loses nothing. |
| helix | Modal editor. |
| Warp, Windows Terminal | The two Windows terminals (see [Terminals](#terminals-warp-and-windows-terminal)). |

Nothing is pushed anywhere and there is no host list: each host keeps itself current with `wsu`.

## One setup, two OS files

Every host gets the same setup. Three tracked config files hold it, plus the git-ignored `config.local.toml` for per-host values, and miserc.toml (git-ignored, written by `scripts/lib/mise-env.sh` on Linux and `bootstrap.ps1` on Windows) picks the OS file:

| File | Loads on | Holds |
|---|---|---|
| `config.toml` | every host | tools for both OSes (Windows-only and Linux-only entries carry `os = [...]`), `[vars]` pins, cross-platform dotfiles |
| `config.linux.toml` | Linux | the Linux toolbelt, dnf packages, `/etc/wsl.conf`, hooks, Linux dotfiles |
| `config.windows.toml` | Windows | Windows dotfiles, winget GUI apps |
| `config.local.toml` | every host, git-ignored | name, email, `sudo`, per-host overrides |

**System steps and sudo.** dnf packages, `/etc` files and zsh as the login shell need sudo. `bootstrap.sh` checks once: cached sudo or a password prompt that succeeds means they run; a failed prompt saves `sudo = "no"` in `config.local.toml`, and from then on `bootstrap.sh`, `mise run update` and `wsu` skip them (`mise bootstrap --skip packages,files`) while everything user-level still installs. An unattended run with no terminal skips them for that run only. To apply them later, get sudo and re-run `./bootstrap.sh`. `mise run health` shows the state in its "system steps" row.

## Repo layout

```
bootstrap.sh, bootstrap.ps1   entry points (Linux; Windows, no admin)
config.toml, config.linux.toml, config.windows.toml
                              mise tool pins, [vars] pins, [dotfiles] entries,
                              host state as [bootstrap.*] tables (Linux)
config.local.toml             git-ignored: this host's name, email, sudo
mise.lock, mise.linux.lock, locks/
                              generated lockfiles; never hand-edit
tasks/                        file tasks with real logic: bootstrap, health, update,
                              check-updates, python-env, fonts, vcpkg, claude,
                              verify-tools
                              (statusline, enable-el-repos, install-tools: Linux,
                              in config.linux.toml)
                              (one-line wrappers — lint, fmt, secrets, ps-lint,
                              bump-versions, install-hooks — are [tasks] in config.toml)
scripts/, scripts/lib/        checks (check-invariants.sh, check-templates.sh), helpers, tests
dotfiles/                     every deployed source under its real name
  *.tera                      templates (zshrc, bashrc, zshenv, gitconfig, ssh/config, ...)
  config/                     ~/.config/*: starship, helix, zellij, zsh plugins, ...
  claude/                     ~/.claude/*: CLAUDE.md, hooks, skills, settings seed and enforced keys
  local/bin/                  ~/.local/bin: batpipe, winterop
  windows/                    the Windows-only sources
configs/wsl/wsl.conf          source of /etc/wsl.conf ([bootstrap.files], not [dotfiles])
docs/claude/, .claude/        notes, hooks and settings for Claude Code
docs/windows/application_list.md   apps to hand-install on a fresh Windows machine
```

Dotfile modes: `template` for the `.tera` sources, `copy` for everything else, on every platform. A directory source carries `exclude = [".vendor", ".gitkeep"]`. `~/.claude/settings.json` is not a dotfile entry: a jq merge (`scripts/lib/claude-settings-merge.sh`) combines `dotfiles/claude/settings.seed.json`, the live file and `settings.enforced.json`, the last winning.

## Setup

### Linux

Prerequisites: `curl`, `git`, `tar` (a single preflight lists every missing one at once), and free space in `$HOME` for the tools: the `linux` figure in [`disk-budget.toml`](disk-budget.toml) plus 1 GB, less what is already installed (about 6.9 GB fresh). Without it the tools step stops before installing anything and lists the largest folders in your home; `WORKSTATION_SKIP_DISK_CHECK=1` overrides. RHEL-family EL8 and EL9 are supported (tested on AlmaLinux 9.8 and RHEL 8.10). On EL8, `bear` isn't packaged and is skipped; plain `gdb` is pwndbg's bundled GDB 17 on every host, so GEF gets a modern gdb there too. Then, on the host:

```bash
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash && \
exec zsh   # or: source ~/.bashrc, if you can't chsh on this host
```

The repo is public, so no token or SSH key is needed. `GITHUB_TOKEN` is optional: mise uses it to lift GitHub's 60-requests/hour anonymous API limit. To use a (public) fork, change `DOTFILES_REPO` at the top of `bootstrap.sh` (`$DotfilesRepo` in `bootstrap.ps1`). Your git name and email are asked once and stored in `config.local.toml`.

What `bootstrap.sh` does:

1. Preflight: `curl`, `git`, `tar`.
2. Clone this repo to `~/.config/mise` (or pull it), then carry on in the checkout's own `bootstrap.sh`, so a pull's changes apply in the same run.
3. Install the pinned, sha256-verified mise into `~/.local/bin`.
4. Ask your name and email once (saved in `config.local.toml`) and decide the system steps (sudo; see above).
5. Write the token set to `miserc.toml`, then run `mise bootstrap --yes` (packages, `/etc` files, services, repos, dotfiles, the tools, the `bootstrap` task, then the Linux-only `final` hook in `config.linux.toml`: vcpkg, `claude` and fonts, which skips itself under WSL). The tools come from its `pre-tools` hook (`scripts/lib/mise-install.sh`: the disk check, then `mise install`), after the dnf batch, because node needs dnf's `libatomic` to start. The first run passes `--force-dotfiles` ([why](#mise-dot-apply--mise-bootstrap-refuses-with-refusing-to-overwrite-existing-files-use---force)).
6. With sudo: set zsh as the login shell: `sudo usermod -s` for a local account, or, for a directory (AD/LDAP) account served by SSSD, a per-host `sss_override` (installing `sssd-tools`) and an `sssd` restart.

It is idempotent; re-run any time. Copy your SSH key from a client with `ssh-copy-id <user>@<host>`.

| Flag | Meaning |
|---|---|
| `--reinstall` | Wipe the cloned repo (including `config.local.toml`, so name and email are asked again), then re-bootstrap. Prompts first. Installed tools, deployed dotfiles, SSH keys and system packages are kept. |
| `--yes`, `-y` | Skip the `--reinstall` confirmation. |
| `--help`, `-h` | Usage. |

Running `--reinstall` from inside the repo is refused (the script would delete itself); run it from outside, with the script in memory:

```bash
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --reinstall
```

`mise run check-updates` runs `mise outdated --bump` for every pinned tool, `dnf check-update` on Linux hosts, and `git ls-remote` for the `[vars]` pins. Tools tracking `latest` (the `pypi:` tools) are reported as rolling. It only reports; the weekly bump workflow (see [Adding things](#adding-things)) does the bumping.

**Extras.** A host's first bootstrap ends by offering the Claude Code status line (ccstatusline), also under `curl | bash`: use the tracked config, define one for this machine only (persisted as a per-host opt-out in `config.local.toml`), set a new global one (committed back to `dotfiles/config/ccstatusline/settings.json`), or skip. Re-run any time with `mise run statusline`. On native (non-WSL) Linux hosts the `fonts` task installs JetBrainsMono Nerd Font Mono to `~/.local/share/fonts/JetBrainsMonoNerdFontMono/` (needed for glyphs in starship, eza, lazygit, yazi, helix); WSL hosts skip it because Windows Terminal reads Windows-registered fonts. The Claude Code installer, plugins, settings merge and herdr plugin run from `tasks/claude`, a `final` hook in `config.linux.toml`, so they run on Linux hosts only and only on a full `mise bootstrap` (not `wsa`). Re-run with `mise run fonts` or `mise run claude`.

### Windows

The Windows host is a client. No admin is needed: everything installs under your user profile (`%LOCALAPPDATA%\workstation`, mise's `%LOCALAPPDATA%\mise`, the User PATH, CurrentUser PSGallery, HKCU fonts). One best-effort exception: SSHFS-Win depends on WinFsp, a kernel driver, so its first install raises UAC (two prompts on a host without WinFsp: one for WinFsp, one for SSHFS-Win); decline them or pass `-SkipElevated` and everything else still completes.

Prerequisites: Git (the script hard-fails with a link if it is missing; `winget install Git.Git`), a working `curl.exe` (`curl.exe --version`), and room on the drive holding `%LOCALAPPDATA%` for the tools: `disk-budget.toml`'s `windows` figure plus 1 GB, less what is already installed (about 4 GB fresh; `$env:WORKSTATION_SKIP_DISK_CHECK = '1'` overrides). PowerShell 5.1 and 7 are supported. Windows HTTP downloads use `curl.exe` with redirects, retries and checked exit codes.

```powershell
$f = "$env:TEMP\bootstrap.ps1"; curl.exe -fsSL --retry 3 -o $f https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1
if ($?) { powershell -NoProfile -ExecutionPolicy Bypass -File $f }
```

Paste both lines into PowerShell. The script runs in its own Windows PowerShell process with the execution policy bypassed for that process only, so it works on a machine still at the default `Restricted` policy, and a failure leaves your window open with the error. Flags go at the end of the second line (`... -File $f -SkipKeyGen`). Re-run the same two lines any time, or `.\bootstrap.ps1` from the clone if your execution policy allows scripts.

What `bootstrap.ps1` does:

1. Preflight: require `curl.exe` and git (it never installs Git).
2. Clone this repo to `%USERPROFILE%\.config\mise` (or pull it), then carry on in the checkout's own `bootstrap.ps1`, so a pull's changes apply in the same run.
3. Install the pinned, sha256-verified mise into `%LOCALAPPDATA%\workstation\mise`. mise is the only version `bootstrap.ps1` pins; every CLI tool is a mise pin in `config*.toml`.
4. Write `miserc.toml` (`windows`), ask once for your git name and email, check that mise loads `config.windows.toml` (it stops otherwise: the Windows dotfiles and apps would be skipped silently), and run `mise bootstrap --only dotfiles,tools`: the dotfiles plus every CLI tool (gh, Starship, Helix, Nushell, jq, OpenCode, omp, DevToys CLI, dnGrep, LogExpert, Node, Go, uv, gopls, language servers, ccstatusline). The first run passes `--force-dotfiles`.
5. After a successful tools phase: add mise's shims dir to the User PATH, reinstall node when its declaration changed (its postinstall carries the language servers), then `mise prune` and `mise reshim`. A changed `.wslconfig` prints the `wsl --shutdown` reminder. `mise bootstrap`'s `post-tools` hook (`config.windows.toml`) runs `mise run nu-init`, which regenerates Nushell's init files (starship, mise, zoxide, atuin) in `%APPDATA%\nushell\vendor\autoload`, so `wsu` refreshes them too. Its `mise.nu` builds on each session's own PATH rather than the PATH `mise activate nu` saw, so Nushell finds what its terminal passes down, as PowerShell does.
6. Install the missing GUI apps: `mise bootstrap --only packages` installs `config.windows.toml`'s `[bootstrap.packages]` winget list (Windows Terminal, Warp, Obsidian, DevToys, DBeaver, WinSCP, Beyond Compare, Zed; latest, checked against the winget manifest's sha256, each self-updating). winget's own `settings.json`, a tracked dotfile, prefers per-user installers; Zed's only installer is machine scope but installs per-user, without admin. An app counts as installed when `winget list --id <Id> --exact` finds it. DevToys is the Microsoft Store build (`9NBN8W1DS547`). Then SSHFS-Win (UAC). Without winget (App Installer) the step warns and skips.
7. Add Start Menu shortcuts for dnGrep and LogExpert, generate the Warp Tab Configs (local shells plus one per SSH host) and the Windows Terminal SSH fragment, seed dnGrep's settings, and install the PowerShell profile loader when Documents is redirected.
8. Install BurntToast and Claude Code (native installer, self-updating; `~\.local\bin` goes on the User PATH), merge `~/.claude/settings.json` and seed `settings.local.json`.
9. Build the `wpy` Python env (a uv venv on mise's python with the libraries in `scripts/python-env.txt`) and install the Nerd Font (mise's `github:ryanoasis/nerd-fonts`, registered per-user by `scripts/install-nerd-fonts.ps1` with a logon task that re-activates it).
10. Prompt for an SSH key, then print [docs/windows/application_list.md](docs/windows/application_list.md) as a hand-install checklist.

Restart the shell afterwards so the new profile loads. Nushell is the default local shell (in Windows Terminal and Zed, both through mise's shim, `%LOCALAPPDATA%\mise\shims\nu.exe`); PowerShell stays for .NET/COM/registry tasks. Zed's SSH remote terminals use the remote's login shell instead: Zed sends its settings to the remote, so the Nushell setting sits under its `"windows"` key. Nushell's command-line colours match zsh's on the Linux hosts (commands green, unknown commands red, quoted strings yellow, flags peach, paths underlined): `autoload/syntax-highlight.nu` overrides the vendored Catppuccin theme's, and lint keeps the two in step. One gap: Nushell gives every argument of an external command (`ssh`, `git`) one colour, so its flags and quoted strings stay plain where zsh colours them. atuin's own background jobs don't light starship's jobs gear (`scripts/nu-init.nu` labels them). Nushell carries the zsh toolbelt:
- `z`/`zi` (zoxide)
- Ctrl-R history search (atuin, local only; Nushell's earlier history is imported once)
- Ctrl-T to insert a file and Alt-C to cd into a directory (fzf, with bat/eza previews)
- `l`/`la`/`ll`/`lt` (eza) and `y` (yazi)
- Tab completion for about 1,000 CLIs through carapace, after `bootstrap.ps1`'s own flags
- Ctrl-O to edit the command line in Helix

`rm` goes to the Recycle Bin (`rm --permanent` skips it). The theme is Catppuccin Mocha, vendored into `%APPDATA%\nushell\autoload\`. PowerShell gets the same `l`/`la`/`ll`/`lt`/`y` and `z`; `wsh` lists them all.

| Flag | Meaning |
|---|---|
| `-RepoPath <dir>` | Clone somewhere other than `%USERPROFILE%\.config\mise`. |
| `-SkipKeyGen` | Skip the SSH-key prompt. |
| `-SkipToolInstall` | Skip mise, the mise tools phase, the winget GUI apps, the Python env and Claude Code (assume present; the post-tools hook, nu-init, doesn't run either). |
| `-SkipDotfiles` | Clone and install tools but do not apply dotfiles. On a host's first run this also skips winget's `settings.json` (the per-user preference), so the GUI apps install with winget's default scope. |
| `-SkipBurntToast` | Skip the BurntToast PowerShell module install. |
| `-SkipNerdFonts` | Skip the Nerd Font install. |
| `-SkipElevated` | Skip SSHFS-Win/WinFsp, the one UAC prompt. Warp's VC++ runtime dependency can also raise UAC on a host without that runtime; this flag does not cover it. |
| `-Reinstall` | Wipe the cloned repo, then re-bootstrap. Prompts unless `-Yes`. |
| `-Yes` | Skip confirmation prompts (`-Reinstall`). |

`-Reinstall` from inside the repo is refused, since the script would delete itself; the download above runs a copy from `%TEMP%`, so put `-Reinstall` at the end of its second line.

**Health and updates.** There is no report mode in `bootstrap.ps1`. Use `mise doctor`, `mise bootstrap status` and `mise dot status` for the tools, host state and dotfiles. `wsu` updates the dotfiles and every CLI tool. The GUI apps are `config.windows.toml`'s `[bootstrap.packages]`: `mise bootstrap packages status` lists them as installed or missing, `mise bootstrap packages apply --manager winget` installs the missing ones, and `mise bootstrap packages upgrade --manager winget` updates them. To add one, add a `"winget:<Id>" = "latest"` line (the Id from `winget search`).

A mise version bump reaches Windows through `wsu`'s pull, but the installed mise is then older than `config.toml`'s `min_version` and refuses the new config, and so does every mise shim, including Windows Terminal's Nushell. Re-run `.\bootstrap.ps1` from a Windows PowerShell window to install the new mise.

Windows Terminal's `settings.json` (Catppuccin Mocha, Nushell default profile) is a tracked `copy` dotfile deployed straight to the Store package's `LocalState`. Warp's `settings.toml` and `keybindings.yaml` (`%LOCALAPPDATA%\warp\Warp\config\`) and theme (`%APPDATA%\warp\Warp\data\themes\`) are tracked too. Both apps rewrite their own files, so record changes made in their UIs with `wsr`. The generated parts are separate: Warp `workstation-*.toml` Tab Configs in `%APPDATA%\warp\Warp\data\tab_configs\`, and the Windows Terminal fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\workstation\`. Your own Tab Configs and profiles are never touched.

**SSH host launchers.** Every concrete `Host` alias in the git-ignored `~/.ssh/config.local` becomes an `SSH: <alias>` Warp Tab Config and Windows Terminal profile that runs `ssh -t <alias> zellij attach --create main`. Patterns and `!` negations are skipped. Re-run `.\bootstrap.ps1` after editing, then restart the terminal.

Example: `Host build1` with `HostName build1.example.com` in `%USERPROFILE%\.ssh\config.local`.

### WSL

WSL distros are ordinary managed Linux hosts, reached through the AlmaLinux-9 profile in Windows Terminal or Warp (or `wsl.exe`). `bootstrap.sh` detects WSL (`$WSL_DISTRO_NAME`, `/proc/version`) and the rest of the flow is unchanged. Inside the distro:

```bash
sudo dnf install -y curl git tar python3 python3-pip    # RHEL / AlmaLinux / Fedora
sudo apt install -y curl git tar python3 python3-pip   # Debian / Ubuntu
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
```

Run it where you have sudo (the usual case); without it the system steps, `/etc/wsl.conf` included, are skipped. Two files configure WSL and the repo owns both:

- `/etc/wsl.conf` (per-distro: systemd, automount, interop, default user, `appendWindowsPath=false`): deployed on Linux hosts by `config.linux.toml` from `configs/wsl/wsl.conf` (on a non-WSL host nothing reads it).
- `%USERPROFILE%\.wslconfig` (VM memory, CPU, networking, all distros): deployed on the Windows host by a `copy` dotfile from `dotfiles/wslconfig`. It enables `autoMemoryReclaim=gradual` and pre-opts into `sparseVhd=true`.

Both need `wsl --shutdown` from a Windows terminal to take effect. `bootstrap.ps1` prints that reminder when `.wslconfig` changes; on Linux, remember it yourself after a `/etc/wsl.conf` change. WSL tabs open in `~` because the WSL Terminal fragment launches `wsl.exe -d AlmaLinux-9 --cd ~`. Every tracked shell exports `COLORTERM=truecolor`, so 24-bit color works in Windows Terminal. Keep long-lived work in a zellij session.

### Terminals (Warp and Windows Terminal)

Warp is the day-to-day Windows terminal and opens into AlmaLinux-9 (WSL zsh). Its "+" menu (CTRL+ALT+L) lists the generated Tab Configs. Windows Terminal stays fully configured because Warp cannot run Nushell (its supported shells are PowerShell, WSL2 and Git Bash) and cannot take Windows' default-terminal role. Warp skips the shell-side fzf, atuin, starship, shift-select and fzf-tab wiring (`TERM_PROGRAM=WarpTerminal`), since its own editor handles those. The pane mnemonics follow zellij's pane mode (d = down, r = right) so muscle memory transfers between local panes and SSH plus zellij.

| Warp | Action |
|---|---|
| ALT+SHIFT+D / R | Split pane down / right |
| ALT+SHIFT+arrows | Move between panes |
| CTRL+SHIFT+Z | Toggle pane maximize |
| CTRL+= / - / 0 | Font size bigger / smaller / reset |
| CTRL+R | Command history search |
| CTRL+↑/↓ | Select previous / next block |
| ALT+↑/↓ | Jump between bookmarked blocks |
| CTRL+SHIFT+P | Command palette |
| CTRL+ALT+L | Tab Config palette |

| Windows Terminal | Action |
|---|---|
| ALT+SHIFT+D / R | Split pane down / right |
| ALT+SHIFT+arrows | Move pane focus (shadows the default resize) |
| CTRL+SHIFT+Z | Toggle pane zoom |
| CTRL+= / - / 0 | Font size bigger / smaller / reset |
| CTRL+C / CTRL+V | Copy / paste (CTRL+C with no selection still sends SIGINT) |
| CTRL+SHIFT+F | Find in the scrollback (regex) |
| CTRL+↑ / ↓ | Previous / next prompt mark |
| ALT+SHIFT+B | Broadcast input to every pane in the tab |

Windows Terminal's profiles are also reachable from the `wt` CLI, e.g. `wt -w 0 nt -p "PowerShell"` (new tab, current window), `wt -p "AlmaLinux-9"` (new window in the WSL distro).

Local Nushell and WSL tabs emit prompt marks (OSC 133) and report the working directory (OSC 9;9), and long commands show taskbar progress. An SSH tab running zellij composites its own panes, so marks stop there.

### Shell prompt and completion

Starship draws the prompt. At the zsh prompt, SHIFT+arrows select text (SHIFT+←/→ by character, CTRL+SHIFT+←/→ by word, SHIFT+HOME/END to line ends, type to replace, BACKSPACE to delete, ALT+W / CTRL+W / CTRL+Y copy / cut / paste, copy also reaching the system clipboard over OSC 52). Five pinned, vendored plugins load from `~/.config/zsh/plugins/`:

| Plugin | What it does |
|---|---|
| zsh-autosuggestions | Greyed suggestion from history; → or End accepts |
| zsh-syntax-highlighting | Live command coloring (Catppuccin Mocha) |
| fzf-tab | Tab becomes an fzf picker with bat/eza previews; `<` / `>` switch groups |
| zsh-history-substring-search | Type part of a command, ↑ / ↓ walk matches |
| zsh-you-should-use | Reminds you of an alias after you type the long form |

Key map: Ctrl-R atuin history · ↑/↓ substring search · → accept suggestion · Tab fzf completion · Shift+arrows select. Directory navigation: `z`/`zi` (zoxide), `br` (broot), `y` (yazi), `nn` (nnn). atuin and the plugins are zsh-only; bash keeps system completion and readline history search on ↑/↓, and `br`/`y`/`nn` work in both.

The repo's own scripts complete their flags: `bootstrap.sh` in zsh and bash, `bootstrap.ps1` in Nushell (kept in step by `scripts/check-invariants.sh`).

**Greeting (Linux).** A new terminal window or SSH login prints a [fastfetch](https://github.com/fastfetch-cli/fastfetch) summary in Catppuccin Mocha: the distro logo beside system (OS, kernel, OS age, uptime, load, IP), software (shell, python / node / go versions), hardware (CPU, memory and swap bars) and storage (`/`, `/home`, the Windows C: drive) groups, about 30 ms. Plain `fastfetch` prints the same. It stays quiet in zellij panes, nested shells, Claude Code and piped output, and drops the logo below 105 columns. Turn it off with `WORKSTATION_FASTFETCH=0` in `~/.zshrc.local` (or `~/.bashrc.local`); change the layout with `wse ~/.config/fastfetch/config.jsonc`.

**Themes.** Everything draws in Catppuccin Mocha with a mauve accent. That covers the prompt, zellij, zsh highlighting, fzf, delta, helix, `ls` colours and fastfetch; bat, eza, yazi and atuin on both OSes; and btop, lazygit, lazydocker, glow, k9s, gitui, tv and broot on Linux. The theme files are vendored under `dotfiles/config/<tool>/`, with provenance and bump steps in each `.vendor`. A tool's own config file stays the tool's: mise adds one line to it (bat, btop) or a marked block (atuin `[theme]`, lazygit and lazydocker `gui:`, tv `[ui.theme_overrides]`). Put your own settings under those keys in the block's source in `dotfiles/config/<tool>/`, not in a second copy of the key in the live file, which is a parse error. k9s and glow are selected by `K9S_SKIN` and a `glow -s` alias in the rc files, and broot by `tasks/broot-skin` on a full bootstrap. A theme you pick inside btop is replaced by Mocha again on the next apply.

## Daily use

The same workflow commands exist in bash and zsh on Linux and in Nushell and PowerShell on Windows (`dotfiles/zshrc.tera`, `dotfiles/bashrc.tera`, and the Windows profiles):

| Command | What it does |
|---|---|
| `wse <path>` | `mise dot edit`: edit a dotfile's source (`wse ~/.zshrc`, `wse $PROFILE`) |
| `wsd` | `mise dot diff`: preview pending changes to `$HOME` |
| `wsa` | Apply tracked state to `$HOME`. First checks `mise dot status` for an un-recorded live edit (`differs`); if found, prints the diff and asks (refuses when non-interactive). The raw `mise bootstrap --only dotfiles --yes` skips that check and overwrites silently. |
| `wsr` | `mise dot add --changed`: record an edited copy-mode file back to its source |
| `wss` | `mise dot status`: every managed file and its state |
| `wsu` | `mise run update`: `git pull --ff-only`, then `mise bootstrap`, which installs the tools too (system steps per the saved `sudo`) |
| `wsh` | Print the workstation cheatsheet |

Every `ws*` command pins `mise -C` to the host's own home, so it acts on this host's checkout from any directory. (mise finds its config root by walking up from the current directory, and a stray `.config/mise` on that path, such as a Windows drive mount under WSL, would otherwise be managed instead.) `wsa` also refuses if mise resolves a different config root. The Windows versions cover what differs there: `wsu` is a pull plus a dotfiles-and-tools bootstrap, and mise itself and the GUI apps are left to `bootstrap.ps1`.

**Editing dotfiles.** A deployed file is an independent copy. Editing `~/.claude/CLAUDE.md` (by hand or by an agent) does not touch `dotfiles/`, and the next `wsa` overwrites it unless you record it first. Either edit the source with `wse <path>`, or record a live edit: `wsr` for a file entry, and for a directory entry (`~/.claude/agents`, `~/.claude/commands`, `~/.claude/hooks`, `~/.claude/skills`, `~/.config/zellij`, `~/.config/zsh/completions`, `~/.config/gdb`, `~/.local/bin`) name the directory itself, because `--changed` does not look inside them:

```bash
mise dot add ~/.claude/agents
```

`mise dot add <directory>` replaces the source directory's contents (a source-only `.gitkeep` drops out, which is harmless once the directory has real files). Then commit and push:

```bash
cd ~/.config/mise && git add -A && git commit -m "update zshrc" && git push
```

**Per-machine overrides** (untracked, sourced last): `~/.zshrc.local` (or `~/.bashrc.local`), `Microsoft.PowerShell_profile.local.ps1` on Windows, and `~/.ssh/config.local` on both.

Example: `export GOPATH="/opt/go"` in `~/.zshrc.local`.

**Health and updates.** `mise run health` prints one row per check with the exact repair command: the config set and the system steps, `mise bootstrap status --missing`, toolbelt completeness, free disk space where mise installs tools (a warning below 2 GB), `miserc.toml`, pueued, python-env, extras (Claude Code, vcpkg, fonts), the zjstatus plugin, the login shell, dotfiles drift, and a dirty checkout (which would block the next `wsu`). `mise run check-updates` is the update scan. To update another host, SSH in (`ssh -t`, since dnf and `/etc` files can prompt for sudo) and run `wsu` there.

**Re-provisioning by hand.** `mise bootstrap` works from any directory because this checkout is mise's global config:

```bash
mise bootstrap --yes                   # full re-provision
mise bootstrap plan                    # dry run: print the plan, change nothing
mise bootstrap status --missing        # read-only: only what's missing/drifted
mise bootstrap --only packages --yes   # narrow to one phase
```

`plan` and `status` never need sudo. Only the packages phase and the `/etc` files it writes elevate (mise re-execs itself with sudo, one password prompt for the whole dnf batch).

**Runtimes.** Node, Go, uv, Python, the language servers and everything else come from mise. Interactive shells see them via `mise activate`; non-interactive ones (`ssh host cmd`, IDEs) via the shims exported from `~/.zshenv` and `~/.bashrc`. In zsh, mise's hook re-runs only when something it reads changes: a project config file between the current directory and `/`, the global config, the installed tools, trusted configs or a `MISE_*` variable. So `cd` outside a project skips the ~100 ms it costs to re-resolve every tool. `WORKSTATION_MISE_GATE=0` in `~/.zshrc.local` restores mise's own hooks. `mise install <tool>` installs one, `mise uninstall <tool>` removes one.

**Python env.** `wpy script.py` (or `#!/usr/bin/env wpy`) runs in a uv-built venv on mise's Python (`tools.python` in `config.toml`) with Textual, Click, rich, httpx, pydantic, typer, polars and duckdb; `textual` and `typer` CLIs are on PATH. Libraries (listed in `scripts/python-env.txt`) track latest at build time. A `tools.python` bump rebuilds the env on the next `mise run python-env`. On Windows `bootstrap.ps1` builds the same env (`%LOCALAPPDATA%\workstation\python-env`, `.cmd` launchers) and rebuilds it after a `tools.python` bump or a `python-env.txt` edit. Rebuild to upgrade the libraries:

```bash
mise run python-env --rebuild   # runs on every host; upgrades to latest libs
```

**Zellij.** Connect with `ssh -t <user>@<host> zellij attach --create main`. `zs` attaches to (or creates) the `main` session, `zs <session>` a named one, `zs <session> dev` (or `zellij -l dev`) opens an editor pane left with terminal and run panes stacked right, and `zs <session> ops` puts btop on top with lazyjournal and a shell below. The layout applies only when the session is created. `zr <cmd>` runs a command in a floating pane (`zr lazygit`; bare `zr` gives a floating shell). The top bar is the zjstatus plugin (mode badge, numbered tabs, session name); the first session on a host asks once for its permission (press Y). Sessions, including 10 000 lines of scrollback, survive a reboot under `~/.cache/zellij/`; the config warns that this cache may hold secrets and is protected only by being user-owned and mode 700 (drop `serialize_pane_viewport` if you do not want that). Config changes need a new session: `zellij kill-session main`, then reattach.

| Bind | Action |
|---|---|
| CTRL+S | Session mode (manager, detach) |
| ALT+S | Scroll mode, then `/` to search |
| ALT+1…9 | Jump to that tab |
| ALT+H/J/K/L | Move focus between panes |
| CTRL+G | Lock / unlock (passes every key to the pane; use it in helix) |
| CTRL+T then S | Broadcast input to every pane in the tab |

Tabs rename themselves to the current directory's basename on `cd`; set `WORKSTATION_ZELLIJ_TAB_NAMES=0` in `~/.zshrc.local` to opt out.

**pueue.** The pueue daemon runs as a per-user systemd unit (`dev.mise.pueued`, declared in `config.linux.toml`): `systemctl --user status dev.mise.pueued`. It stops with your last login session; use `loginctl enable-linger` if jobs must survive logout.

**gdb (Linux).** Plain `gdb ./a.out` is pwndbg's bundled GDB 17 (first on `PATH`) with GEF, `pwndbg ./a.out` is pwndbg, `/usr/bin/gdb` is the system gdb (16 on EL9, 8.2 on EL8), `gdb -nx` is vanilla and `nnd ./a.out` is a TUI debugger. All but the last two read `~/.gdbinit` (`dotfiles/gdbinit.tera`; a gdb too old for a setting skips just that one). It gives you:
- libstdc++'s pretty printers, and `step` that skips the STL headers. A lambda called through `std::function` or `std::sort` is skipped too, so break inside it or run `skip disable`;
- one shared history in `~/.gdb_history`, no paging and no confirmation prompts, and a pending breakpoint for a function that isn't loaded yet;
- decimal output (GEF forces hex; pwndbg keeps hex) and up to 1000 elements per print.

GEF loads only in gdb, not inside pwndbg. pwndbg no longer runs a project's `./.gdbinit` by itself: use `pwndbg -x .gdbinit`.

Debug info for system libraries comes from debuginfod.elfutils.org when that server answers within 1.5 s at startup. It covers RHEL 8 fully but AlmaLinux 9 only in part. The build IDs of the loaded objects go to sourceware.org. `DEBUGINFOD_URLS=` (empty) turns this off, and a URL list replaces the server.

**Valgrind (Linux).** `~/.valgrindrc` (`dotfiles/valgrindrc`) applies to every valgrind run, CTest and meson included. It holds only cheap defaults: 30-frame stacks, full leak reports, and kept debug info for `dlclose`d libraries. Memcheck options in it are written `--memcheck:…`, so other tools still start. The file can't hold `#` comments. `vgm ./prog` is the thorough run: it adds `--track-origins=yes` (where each uninitialised value came from; about 2x slower, +100 MB) and `--track-fds=yes` (leaked file descriptors).

```bash
vgm ./prog                                     # memcheck + origins + fd report
valgrind --tool=massif --massif-out-file=massif.out ./prog && ms_print massif.out | less
valgrind --tool=callgrind --callgrind-out-file=cg.out ./prog && callgrind_annotate cg.out | less
valgrind --tool=helgrind ./prog                # data races and lock order (or --tool=drd)
valgrind --trace-children=yes --log-file=vg.%p.log ./script.sh   # one log per process
valgrind --gen-suppressions=all ./prog         # print a suppression for each error
```

To debug under Memcheck:
1. Run `valgrind --vgdb-error=0 ./prog`. Use `=1` instead to run to the first error.
2. In another pane, run `/usr/bin/gdb -nx ./prog -ex 'target remote | vgdb'`. `continue` stops at each error, and `monitor leak_check full` queries Memcheck live.

For an interpreter, add `--errors-for-leak-kinds=definite --show-leak-kinds=definite`: Python alone reports thousands of "possibly lost" blocks. A cloned project's `./.valgrindrc` overrides yours; `valgrind --command-line-only=yes` ignores every rc file.

**winterop** (in `~/.local/bin` on Linux and WSL, WSL-only) talks to the Windows host: no arguments shows the detected environment and live channels, and `winterop run <cmd>`, `path <p>`, `clip [get|set]`, `open <path|url>`, `host` cover the common cases (`winterop help` lists the rest). In a plain VM it points you at SSH, shared folders or RDP.

## Adding things

**A tool.** One line in the right file; every tool is a mise pin. `config.toml` holds tools for both OSes (add `os = ["linux"]` or `os = ["windows"]` for single-OS ones) and `config.linux.toml` the Linux toolbelt. Prefer the aqua registry short name; use `github:` with `asset_pattern` only when the registry picks the wrong asset. Every Linux asset must run on EL8's glibc 2.28: prefer a musl build (see the gping, yazi, delta and bottom entries); when a project ships only newer-glibc builds, take conda-forge's (`conda:`, built against glibc 2.17 or 2.28; see helix and ast-grep). After an install, `tasks/verify-tools` checks every binary runs on the host, and `disk-budget.yml` checks them against glibc 2.28 in CI.

```toml
# config.linux.toml — [tools] (aqua registry short name)
direnv = "2.34.0"
# pin an explicit asset when the registry default won't run on EL8 (glibc 2.28)
"github:direnv/direnv" = { version = "2.34.0", asset_pattern = "direnv.linux-amd64" }
```

Installs are locked (`locked = true` in `config.toml`: they read the lockfiles and never rewrite them), so a new pin installs only after its lock entry exists. Refresh the lockfiles first, then check it with `mise install direnv` and `mise where direnv`. `tasks/verify-tools` runs after every install and fails loudly if a binary cannot run on this host; that is the cue to pick an explicit `github:` asset. Multi-binary archives install every binary; restrict with `bin` or `bin_path` on the `github:` entry (see qsv, pwndbg). Commit the config, both lockfiles and any new `locks/**` sidecar. The refresh:

```bash
mise run bump-versions
```

It also bumps every other outdated pin (`mise run bump-versions -- --dry-run` previews without writing), so expect unrelated bumps in the diff. It refreshes the lockfiles for every platform the verified way (from outside the checkout through an `XDG_CONFIG_HOME` symlink, then normalising the `.mise/locks` sidecar paths). A hand-run `mise lock` inside the checkout can write sidecar refs to the wrong layout. Do not add tool-specific logic to `bootstrap.sh`. The Claude tool inventory regenerates from `config*.toml` on edit (`scripts/gen-tool-memory.sh`).

**A version bump.** A weekly workflow (`version-bumps.yml`) runs `mise run bump-versions`: it bumps mise tool pins with `mise outdated --bump` plus an in-place rewrite that keeps comments, refreshes the lockfiles, bumps drifted `config.toml` `[vars]` pins, and opens a PR. GitHub holds workflow runs on a PR from `github-actions[bot]` until someone approves them, so click **Approve workflows to run** on the PR to start lint, and merge once it passes. A version `mise lock` refuses is put back and listed for review. zjstatus, ncdu and python (the tool pin) are bumped by hand, and so is mise itself: `MISE_VERSION`/`MISE_SHA256` in `bootstrap.sh`, `$MiseVersion`/`$MiseSha256` in `bootstrap.ps1`, `min_version` in `config.toml` and each workflow's `jdx/mise-action` `version:` (lint checks the versions agree). To do it manually, edit the version in `config*.toml`, refresh the lockfiles with `mise run bump-versions` as above, commit.

**Disk budget.** After a change to `config*.toml`, `mise*.lock` or `locks/` reaches `main`, `disk-budget.yml` installs the toolbelt fresh for each OS (Linux, Windows), measures everything the install wrote (tools, downloads, uv/go/npm caches) and commits the figures, rounded up to 100 MB, to `disk-budget.toml`. The free-space checks in `scripts/lib/mise-install.sh` and `bootstrap.ps1` read it. Run it by hand with `gh workflow run disk-budget.yml`.

**A dotfile.** One `[dotfiles]` entry keyed by the target, plus the source under `dotfiles/`, in the config file whose `MISE_ENV` token should gate it (cross-platform in `config.toml`, Linux `config.linux.toml`, Windows `config.windows.toml`):

```toml
# config.linux.toml — [dotfiles]
"~/.config/example/config.toml" = { source = "dotfiles/config/example/config.toml", mode = "copy" }
```

Use `mode = "copy"` for plain files (add `exclude = [".vendor", ".gitkeep"]` for a whole directory) and `mode = "template"` for a `.tera` source that needs a rendered value. For a file the application writes itself (its own config), use an edit entry instead: a copy would refuse to overwrite the application's file. A `line` is appended if missing; a `block` is kept between marker comments and can come from a file (`"~/.config/lazygit/config.yml/theme" = { source = "dotfiles/config/lazygit/theme.yml", template = "tera" }`). The pinned mise has no `merge`, and lint refuses one. Guard every `vars.*` reference in a template with `is defined` or `default()`: one undefined variable aborts the entire apply and writes nothing. Render it alone first, then apply just that entry and check:

```bash
mise dot apply --yes -- "<target>"   # apply just that entry
mise dot status; mise dot diff       # confirm it lands as expected
bash scripts/check-invariants.sh
```

Every `dotfiles/**/*.tera` file is rendered by `scripts/check-templates.sh` automatically; the one manual step is mapping a syntax checker for the new target in its `select_checker()`. To disable an entry inherited from a less-specific file, override it with `enabled = false` **and** a repeated `mode` (`enabled = false` alone is ignored). A host's first apply forces over pre-existing files ([why](#mise-dot-apply--mise-bootstrap-refuses-with-refusing-to-overwrite-existing-files-use---force)). Commit the config edit and the new source.

**A dnf package.** One line in `config.linux.toml`. The whole table installs as one `sudo dnf install -y` batch, so a single unresolvable name fails everything: verify the name first.

```toml
# config.linux.toml — [bootstrap.packages]
"dnf:tig" = "latest"
```

```bash
dnf repoquery tig          # confirm the exact name resolves on EL8 and EL9
mise bootstrap --only packages --yes   # or: MISE_ENV=<your set> mise bootstrap plan
```

Do not re-add names known not to resolve on EL9: `fswatch`, `entr`, `cockpit-networkmanager`. Nor `curl`: EL9 ships `curl-minimal`, which conflicts with it, and the bootstrap needs a curl before it starts anyway. `ShellCheck` is capitalised (EPEL). The batch is all-or-nothing, so a package only some EL releases carry goes in `tasks/optional-packages` instead (the `post-packages` hook), which installs with dnf's `strict=0` and skips it where it is missing: `bear` is there because EL8 has no package.

**A service or `/etc` file.** In `config.linux.toml`: a `[bootstrap.files."/etc/<path>"]` table (source relative to the repo root, under `configs/`; phase is only `pre-packages` or `post-packages`; mise elevates itself) and a `[bootstrap.services.<name>]` table for the unit it belongs to:

```toml
# config.linux.toml
[bootstrap.files."/etc/example/example.conf"]
source = "configs/example/example.conf"
owner = "root"
group = "root"
mode = "0644"
notify = ["example"]          # restart this service when the file changes

[bootstrap.services.example]
state = "running"
enabled = true
on_change = "restart"
```

Verify with `mise bootstrap plan`, then `mise bootstrap status --missing` after a real run. Never add a `[bootstrap.linux.firewall]` table (see Troubleshooting).

Before committing, `mise run lint` runs `scripts/check-invariants.sh` (version-pin dual edits, LF and executable bits, PowerShell BOMs, sentinel blocks, `[dotfiles]` tables), shellcheck, `shfmt -i 2` and gitleaks; `mise run install-hooks` installs mise's generated pre-commit hook (`.git/hooks/pre-commit`, runs `mise run lint`; run it once per clone, it also clears an old `core.hooksPath`), and CI (`.github/workflows/lint.yml`) runs the same checks.

## Troubleshooting

### Bootstrap reports "Missing required prerequisites: …"

Install everything listed at once (the script collects every gap up front): `sudo dnf install curl git tar` (RHEL/Fedora) or `sudo apt install curl git tar` (Debian/Ubuntu).

### The tools step stops with "Not enough disk space for the mise tools"

The check runs before `mise install` because a disk that fills mid-install leaves tools half-extracted that mise still counts as installed. The message gives the free and needed space and the largest folders in your home; IDE remote-server caches are the usual culprits (`~/.cache/JetBrains/RemoteDev`, old `~/.vscode-server/cli/servers/*`, `~/.local/share/zed`). Free the space and re-run. If an earlier run already filled the disk, force the tools it cut short (`mise install --force <tool>`, for example `go` when gopls fails with "package cmp is not in std").

### Pull fails with "Authentication failed"

The bootstrap scripts clone and pull anonymously. A checkout made while the repo was private may still hold that era's token in `.git/config`, and once it expires GitHub rejects it instead of falling back to anonymous access. Remove it: `git -C ~/.config/mise config --unset http.https://github.com/.extraheader` (on Windows, `-C $env:USERPROFILE\.config\mise`).

### SSH keeps prompting for a password after ssh-copy-id

The key landed but sshd is not using it. On the target, check `/etc/ssh/sshd_config` has `PubkeyAuthentication yes` and `AuthorizedKeysFile .ssh/authorized_keys`, that `~/.ssh` is 700 and `~/.ssh/authorized_keys` is 600, and on SELinux run `restorecon -R -v ~/.ssh`.

### ssh-keygen on Windows opens a passphrase prompt despite -N '""'

Some PowerShell quoting variants strip the empty-passphrase argument. Re-run interactively and press Enter twice; the rest of the flow is unchanged.

### Copying inside a remote Zellij session doesn't reach the Windows clipboard

Zellij runs remotely, so the only path to your clipboard is the OSC 52 escape sequence, which it uses only while `copy_command` is unset in `~/.config/zellij/config.kdl`. Setting it (xclip, wl-copy, pbcopy) runs a program on the remote box, where there is no display, and every yank silently goes nowhere; the tracked config leaves it unset on purpose. Both terminals accept OSC 52 (Warp via `osc52_clipboard_access = "write_only"` in its tracked settings). If copy still fails, reconnect (zellij reads its config at session creation: `zellij kill-session main`) and check the config parsed with `zellij setup --check` (must say `Well defined`; KDL comments are `//`, and a single `#` line invalidates the file so zellij silently uses defaults).

### Zellij's tabs and pane borders are green, not mauve

Green is zellij's built-in catppuccin-mocha. The repo's `catppuccin-mocha-mauve` theme (`~/.config/zellij/themes/`) re-accents the chrome to mauve `#cba6f7`. Seeing green means it is not in effect: the session predates the change (zellij reads config at creation; `zellij kill-session main` and reattach), or the theme file did not deploy (`ls ~/.config/zellij/themes/` on the host zellij runs on, the remote box; if missing run `wsu` there). `zellij setup --check` says `Well defined` even for a nonexistent theme name, which is why `scripts/check-invariants.sh` checks the `theme "<name>"` line against `themes/*.kdl`; run `mise run lint` if you suspect the config. Green pane exit codes are deliberate (success green, failure red).

### SSH tab dies with "client_loop: send disconnect: Broken pipe" and floods the pane with garbage

The tracked `~/.ssh/config` sets `ServerAliveInterval 30`, `ServerAliveCountMax 3` and `TCPKeepAlive yes`, so dead connections are detected in about 90 seconds (confirm with `ssh -G <hostname> | grep -i serveralive`). When a pipe does break, reconnect from a new tab with `ssh -t <user>@<host> zellij attach --create main`, which reattaches the same session; then close the dead tab. Per-host overrides go in `~/.ssh/config.local`, which the tracked config includes at the top so it wins over the `Host *` defaults.

### Warp: missing Tab Configs, wrong theme, or it opened PowerShell instead of AlmaLinux-9

Warp hot-reloads `settings.toml`, so `wsa` lands theme and font changes at once, but it reads Tab Configs only at launch, so a regenerated set needs a full Warp restart. Missing Tab Configs: re-run `.\bootstrap.ps1` (it rebuilds the local-shell entries every run; if it says Warp is not installed while it is, the Uninstall-registry DisplayName changed, which the generator keys off). Stock theme: it is referenced as `catppuccin-mocha.yaml` under `%APPDATA%\warp\Warp\data\themes\`; `wsa` restores it. Opened PowerShell: Warp falls back when it rejects `new_session_shell_override`; use the WSL AlmaLinux-9 Tab Config and re-check the key against Warp's settings schema. Edits keep coming back: change them in the Settings panel, then `wsr`, and keep Warp's `is_settings_sync_enabled` off so cloud sync does not fight `wsa`. The same host in two tabs mirrors itself (both attach the same zellij session). Nushell looks broken in Warp because Warp does not support it; use Windows Terminal.

### Windows Terminal shows old settings / leftover SSH host profiles

An edit in the repo needs `wsa` before Windows Terminal sees it; `settings.json` then hot-reloads. SSH profiles come from `%USERPROFILE%\.ssh\config.local`: re-run `.\bootstrap.ps1` after editing, then close every Windows Terminal window (it reads `Fragments\` only at launch). If edits keep reverting, the Settings UI re-serialised `settings.json`; run `wsr` before the next `wsa`.

### bootstrap.ps1 aborts with "Git is required but isn't on PATH"

Git is a prerequisite the script does not install. Install Git for Windows (`winget install Git.Git`), reopen PowerShell and re-run. The GitHub CLI is not one (mise installs it); authenticate once afterwards with `gh auth login`.

### bootstrap.ps1 says the mise download "did not match the pinned checksum"

Only mise is checksum-pinned by `bootstrap.ps1` (`$MiseSha256` for `$MiseVersion`). Every other CLI tool is verified by mise against the sha256 in `mise*.lock`, and winget checks each GUI app's installer against its manifest. The script never installs an unverified mise: with an older mise installed it warns and carries on with that one, and with none it stops. A one-off mismatch is usually a corrupted download, so re-run `.\bootstrap.ps1`. If it persists, the pin is stale (upstream re-published the asset) or the download is being tampered with: re-download the pinned zip, recompute its hash, and update `$MiseSha256`:

```powershell
(Get-FileHash -Algorithm SHA256 .\<asset>.zip).Hash.ToLower()
```

### bootstrap.ps1 stops with "mise did not load config.windows.toml" or "'mise config ls' failed"

Both stop the run before `mise bootstrap` and `mise prune` (continuing would skip the Windows dotfiles and apps). "Did not load config.windows.toml" means `miserc.toml` was not honoured, usually because `-RepoPath` is outside `%USERPROFILE%\.config\mise` (mise reads `miserc.toml` from there); `mise -C $env:USERPROFILE config ls` shows what loaded. "'mise config ls' failed" prints mise's own error: usually an installed mise older than `config.toml`'s `min_version` (a mise download that failed after a bump; re-run once the download succeeds), or a TOML error in a config file.

### PowerShell aliases / adminpw / ws* don't load (the profile seems ignored)

Usually Documents folder redirection (OneDrive or corporate): PowerShell loads `$PROFILE` from the redirected location, but the managed profile deploys to the literal `%USERPROFILE%\Documents\PowerShell\`. `bootstrap.ps1` drops a one-line loader at the real `$PROFILE` automatically. Before re-running it, confirm the mismatch and create the loader yourself:

```powershell
# differs from %USERPROFILE%\Documents\WindowsPowerShell\...? Documents is redirected
$PROFILE.CurrentUserCurrentHost
# point the real $PROFILE at the managed canonical
$dir = Split-Path $PROFILE.CurrentUserCurrentHost
New-Item -ItemType Directory -Force -Path $dir | Out-Null
'. "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"' | Set-Content $PROFILE.CurrentUserCurrentHost
```

### mise bootstrap failed with a dnf error naming one package

The dnf batch is all-or-nothing: one unresolvable name fails the whole install. Confirm the name for this host's repos with `dnf repoquery <name>`; a metadata refresh, a disabled repo, or a typo in a new line are the usual causes. Fix the entry and re-run `mise bootstrap --only packages --yes`.

### A bootstrap phase fails and blocks the rest

`mise bootstrap` runs phases in fixed order (packages, files/services/compose, repos, dotfiles, tools, then the bootstrap task) and stops at the first failure. Re-running `./bootstrap.sh` is idempotent and only retries what failed. If one phase is wedged on something outside your control (a flaky mirror, a proxy), skip it to make progress, then re-run the full script once the cause is fixed, because a skipped phase leaves real drift (see `mise run health`). Use `mise bootstrap plan` first to see what a phase would do.

Example: `mise bootstrap --skip packages --yes` (comma-separate or repeat `--skip`).

### mise dot apply / mise bootstrap fails with "Variable … is not defined" — and nothing got applied

One broken template aborts the whole dotfiles apply and writes nothing: a single undefined Tera variable or failing `exec()` in any `template` entry fails the run. mise prints the target, the source file and the error first, then generic boilerplate you can ignore. To find the culprit, apply template entries one at a time, or run the repo check that does this for every `.tera` file under both `MISE_ENV` sets (`linux`, `windows`). Then fix the template (guard with `is defined` or `default(value=...)`) and re-run `wsa`. CI runs `scripts/check-templates.sh` so this is caught before it reaches a host.

```bash
mise dot apply --force --yes -- "<target>"   # one entry at a time, names the failure precisely
bash scripts/check-templates.sh                    # does exactly this for every .tera file, both MISE_ENV sets
```

### mise dot apply / mise bootstrap refuses with "refusing to overwrite existing files (use --force)"

`copy` and `template` targets refuse to replace a pre-existing file that already differs (even `--dry-run` exits 1). That is expected on a fresh host's first apply (for example `/etc/skel`'s `~/.bashrc`), and the bootstrap scripts pass `--force-dotfiles` automatically while the `dotfiles-first-apply-done` marker is absent (`~/.local/state/workstation/`, or `%LOCALAPPDATA%\workstation\` on Windows). Once it is written, the message means a real conflict: a file you or another tool created at that exact path. Inspect it, then either let the dotfiles win with `mise dot apply --force --yes -- "<target>"` or move the file aside. Do not use `--force-dotfiles` or `--force` as a reflex; it discards whatever was there.

### wsu fails with "fatal: Not possible to fast-forward, aborting"

This checkout has an uncommitted change (a hand-edited pin, a `wse` edit to a `dotfiles/` source, a `wsr` write, or mise rewriting a lock file), and `git pull --ff-only` refuses to run against it. `mise run health` has a "repo checkout" row with the count. Commit and push the change, or stash it, then re-run `wsu`:

```bash
git -C ~/.config/mise status --porcelain          # see what's dirty
git add -A && git commit -m '...' && git push   # keep the edit (or: git stash)
```

### A copy-mode file (Warp / Windows Terminal / Zed / VS Code settings) reverts after wsa

Expected: those apps rewrite their file in place from their UI, so the copy in `$HOME` and the tracked source drift apart, and the next `wsa` overwrites your UI edit with the stale source (`wsa` warns first if it notices). Record the live file back to source before the next `wsa`/`wsu` with `wsr` (every changed tracked file) or `mise dot add --changed -- "<target>"` (just the one you edited), then commit the updated source.

### I edited a file in $HOME directly (e.g. ~/.claude/CLAUDE.md) and wsa reverted it

Deployed targets are independent copies, so a direct edit never reaches `dotfiles/`. `wsa` prints the diff and asks before overwriting; a silent overwrite means it went through the raw `mise bootstrap --only dotfiles --yes` form, which overwrites by design. Record the edit before re-running `wsa`: `wsr` records FILE entries; for a DIRECTORY entry use `mise dot add <the directory>`, e.g. `mise dot add ~/.claude/agents`; then commit.

### mise bootstrap plan / status asks for a sudo password and hangs (no TTY)

Any `[bootstrap.linux.firewall]` table makes mise re-exec itself with sudo even for read-only `plan`/`status`, and a non-interactive session has no TTY to answer, so it hangs or fails with "sudo: a password is required". This repo ships no such table on purpose (`mise run health` would break on every host). If one was added to a config that loads unconditionally, remove it, and open ports the `firewall-cmd` way inside a `post-packages` hook task, which only runs during a real `mise bootstrap --yes`.

### pueue status fails, or pueued isn't running

Check the unit, then its log: `systemctl --user is-active dev.mise.pueued.service` and `journalctl --user -u dev.mise.pueued -n 20`. The usual cause is a missing or stale `~/.config/mise/miserc.toml`, so the shim errors with something like "No version is set for shim: pueued". The unit has no `Environment=MISE_ENV`; the shim reads `miserc.toml`. Fix with `mise run update` (it rewrites `miserc.toml` and clears any old `MISE_ENV` export), then `systemctl --user restart dev.mise.pueued.service`.

### Colors look banded or 8-bit on a remote host

The remote app only emits truecolor if `$COLORTERM=truecolor` is set, which the tracked `zshrc`/`bashrc` do (and, on Windows, the PowerShell and Nushell profiles). Run `wsu` on the affected host, open a new shell, and check that `echo "$COLORTERM"` prints `truecolor`.

### Tofu boxes / missing icons after install

Symptoms: starship shows boxes, eza rows show empty cells, lazygit/k9s/yazi look broken, or Windows Terminal says "Unable to find the following fonts: JetBrainsMono NFM". JetBrainsMono Nerd Font Mono is not loaded.

- **Linux:** `fc-list | grep -i 'jetbrainsmono nerd font mono'` should list 6 entries; if empty, `mise run fonts`, then restart shells. A WSL host says fonts are skipped: intentional, run `bootstrap.ps1` on the Windows side.
- **Windows:** `Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-Regular.ttf"` should be `True`; if not, re-run `bootstrap.ps1` (idempotent). If the file exists but apps cannot find the font after a reboot, Windows did not load the HKCU per-user font at logon; re-run `bootstrap.ps1` to re-create the `WorkstationNerdFontActivate` logon task and re-activate the current session.
- VS Code and Zed cache font lists at launch: quit and relaunch. On Windows the family name must be `JetBrainsMono NFM`, not `JetBrainsMono Nerd Font Mono` (Nerd Fonts shortens the GDI name to fit 31 characters). Restart Windows Terminal to re-enumerate fonts.
- Both OSes install the font from the one `github:ryanoasis/nerd-fonts` pin in `config.toml`. `mise where github:ryanoasis/nerd-fonts` must list the six `JetBrainsMonoNerdFontMono-*.ttf` files; if not, run `mise install github:ryanoasis/nerd-fonts` (on Windows from `%USERPROFILE%`), then `mise run fonts` (Linux) or `bootstrap.ps1` (Windows).

### Shell startup / a PATH-scanning command feels slow on WSL

With `appendWindowsPath=true`, WSL2 appends the whole Windows `%PATH%` (about 90 `/mnt/c` directories), and looking up a binary that does not exist stat-walks every one over the slow 9p mount (about 1.5 s per miss, compounding with every probe a shell rc runs). The tracked `/etc/wsl.conf` sets `appendWindowsPath=false` (deployed by `mise bootstrap` from `configs/wsl/wsl.conf`); run `wsl --shutdown` from a Windows terminal and reopen. The tracked `~/.zshrc` and `~/.bashrc` re-add only the two Windows dirs still needed (PowerShell for `~/.claude/notify.sh` toasts, and system32 for `clip.exe`). Verify in a fresh tab that `echo $PATH | tr ':' '\n' | grep -c /mnt/` drops from about 90 to about 2.

Other Windows executables (explorer.exe, VS Code's `code`) leave the WSL `$PATH`; re-add any you want in `~/.zshrc.local`.

### WSL disk (ext4.vhdx) keeps growing — freed space never returns to Windows

WSL2 VHDs grow on demand and never shrink by themselves. The auto-shrink feature (sparse VHD) is disabled upstream on WSL 2.5 and later after data-corruption reports (microsoft/WSL #13075), so the tracked `sparseVhd=true` is inert for now and `wsl --manage <Distro> --set-sparse true` refuses unless forced. Reclaiming is manual and the repo deliberately does not automate it. Find the VHD (regular PowerShell), then reclaim in an admin PowerShell (`Optimize-VHD` needs the Hyper-V module; without it use diskpart). Both are manual maintenance:

```powershell
Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss | ForEach-Object { Get-ItemProperty $_.PSPath } | Select-Object DistributionName, BasePath
wsl --shutdown
Optimize-VHD -Path "<BasePath>\ext4.vhdx" -Mode Full
# no Hyper-V module: run diskpart, then inside it
select vdisk file="<BasePath>\ext4.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
```

Unsafe opt-in, only if you accept the corruption risk Microsoft disabled it over (back up first): `wsl --export <Distro> D:\backup\<Distro>.tar`, then `wsl --manage <Distro> --set-sparse true --allow-unsafe`.

RAM is the separate, already-solved half: `autoMemoryReclaim=gradual` in the tracked `.wslconfig` returns cached VM memory to Windows.

### LSP servers — a language server is missing after mise bootstrap

`mise bootstrap`'s tools phase installs the whole stack. rust-analyzer, marksman and taplo are aqua-registry tools. gopls, lua-language-server, basedpyright, typescript-language-server, bash-language-server, yaml-language-server and vscode-json-language-server come from `config.toml`. `mise ls --missing` lists what did not install; `mise doctor` must report `activated: yes` and `shims_on_path: yes` (else `wsa` and open a new shell). A stale npm server after a pin bump means node's postinstall did not re-run: `mise install --force node`. TypeScript is held on 5.x on purpose (TypeScript 7 ships no `tsserver.js`). clangd comes from dnf (`clang-tools-extra` in `config.linux.toml`); `mise run health` does not check it, so use `command -v clangd`. On Windows the same servers install through `mise bootstrap` (run by `bootstrap.ps1` and `wsu`); check with `mise ls --missing` and `mise doctor`, and open a new terminal after the first run. Re-run the stack with `mise bootstrap --only tools --yes`, or force one tool with `mise uninstall <name> && mise install <name>`.

### C / C++ toolchain — a tool is missing, or ninja / vcpkg behaves oddly

The compilers, debuggers and analysis tools (gcc-c++, clang, clangd/clang-tidy/clang-format, lldb, valgrind, cppcheck, cmake, meson, ninja-build, heaptrack, sanitizer runtimes) install through dnf (with sudo). Several come from EPEL/CRB; the `config.linux.toml` `pre-packages` hook (`mise run enable-el-repos`) enables both before the batch. If a package still does not resolve, enable them by hand and re-run:

```bash
sudo dnf install epel-release
sudo dnf config-manager --set-enabled crb   # EL9 Alma/Rocky/Stream (powertools on EL8)
# subscribed RHEL instead: sudo subscription-manager repos --enable codeready-builder-for-rhel-<8|9>-$(uname -m)-rpms
mise bootstrap --only packages --yes
```

`ninja: command not found`: on RHEL the binary is `ninja-build`; if a project hard-codes `ninja`, link it once with `ln -s "$(command -v ninja-build)" ~/.local/bin/ninja`. Which gdb is which: see **gdb** under Daily use. vcpkg lives at `$VCPKG_ROOT` (`~/.local/share/vcpkg`, a user-owned clone at the pinned tag, exported by the shell rc on Linux hosts), so classic `vcpkg install <pkg>` needs no sudo (manifest mode is still preferred); missing entirely, run `mise run vcpkg`. Prefer compiler sanitizers (`-fsanitize=address,undefined`, 2 to 4 times overhead) over Valgrind (20 to 50 times) for everyday checks.

### wpy not found, or import textual fails in it

Provisioning builds the env on every host. Rebuild it from scratch with `mise run python-env --rebuild` (the same rebuild upgrades the latest-tracking libraries and resets the env to the canonical nine, undoing any ad-hoc `uv pip install`). On Windows the env is built on `mise where python` (run from `%USERPROFILE%`; it must print an install dir), so a missing `wpy` usually means the mise tools phase failed. To rebuild, delete `%LOCALAPPDATA%\workstation\stamps\python-env.stamp` and re-run `.\bootstrap.ps1`. On a host set up before mise managed Python, `uv python uninstall --all` and `uv cache clean` reclaim uv's old interpreters and cache (not automated; mise keeps using uv to install `pypi:` tools).

### NFS tools (showmount, nfsstat, autofs) are missing on a host

The NFS client group (`nfs-utils`, `nfs4-acl-tools`, `autofs`) is in `config.linux.toml`'s dnf batch, so every Linux host with sudo gets it (on WSL it is inert: Windows is the NFS/SMB client). Re-run `mise bootstrap --only packages --yes`. `autofs` is installed but not enabled (no maps yet does nothing): write your maps, then `sudo systemctl enable --now autofs`.

### bootstrap.ps1 popped a UAC prompt (or SSHFS-Win reports "winget exited")

That is the SSHFS-Win install, the one deliberate exception to the admin-free bootstrap: it depends on WinFsp, a kernel-mode driver, so elevation is unavoidable. A host without WinFsp sees two prompts, one for WinFsp and one for SSHFS-Win. It needs winget (App Installer); without it the GUI-app step is skipped. It is best-effort: declining or being offline skips it with a warning, and an already-installed machine never sees the prompt. Install it later with `winget install --id SSHFS-Win.SSHFS-Win` (pulls WinFsp) or re-run `.\bootstrap.ps1` and accept; suppress the attempt with `-SkipElevated`. A prompt while Warp installs is winget adding the VC++ runtime Warp depends on (`-SkipElevated` does not cover it). Once installed, mount with `net use X: \\sshfs\user@host` or browse `\\sshfs\user@host` in Explorer.

### Zellij's top bar is plain, shows a "permission" request, or renders boxes instead of rounded pills

The top bar is the zjstatus plugin. A permission request is the one-time first-run prompt on that host: click the bar (or CTRL+P then ↑) and press Y; the grant is cached in `~/.cache/zellij/permissions.kdl`. A plain built-in bar, or an "ERROR IN PLUGIN" bar, means `~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm` is missing on that host: zellij loads the plugin straight from mise's install dir (no copy step, not a `[dotfiles]` entry), and `/tmp/zellij-<uid>/zellij-log/zellij.log` names the path zellij tried. Reinstall it with `mise install github:dj95/zjstatus` (user-level, no sudo), then `zellij kill-session main` (plugins load when a session is created).

Boxes instead of pills mean the terminal you attach from is not using a Nerd Font (JetBrainsMono NFM on the client side).
