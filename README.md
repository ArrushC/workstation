# workstation

Dev environment provisioning for RHEL VMs, plus the WezTerm config that connects to them from Windows.

Ansible owns **all** installations — system packages, user-space tools, and the chezmoi handoff for dotfiles. `bootstrap.sh` is a thin seed: it clones the repo, installs `ansible-core` via `pip3 --user` if needed, then runs a local Ansible playbook against the VM. There is no duplicated install logic — adding a tool is a one-file edit.

## Stack

| Layer | Tool | Purpose |
|---|---|---|
| Provisioning | **Ansible** | Packages, tool installs, PATH, dotfiles trigger |
| Dotfiles | **chezmoi** | Personal shell config, templated per machine |
| Shell | **starship** | Prompt |
| Multiplexer | **zellij** | Persistent sessions, layouts |
| Fuzzy find | **fzf** | History, files, SSH hosts |
| Jump | **zoxide** | Smarter `cd` |
| Editor | **helix** | Modal editor, zero config |
| Notes | **nb + glow** | CLI notes, markdown preview |
| Terminal | **WezTerm** | Windows terminal, auto-connects to VMs |

## Install scopes

User-space tools are installed as static binaries either to your home directory or system-wide. The destination is controlled by the `tool_scope` Ansible variable:

| `tool_scope` | Binary destination | Helix runtime | Needs sudo |
|---|---|---|---|
| `user` (default) | `~/.local/bin` | `~/.config/helix/runtime` | No |
| `system` | `/usr/local/bin` | `/usr/local/lib/helix/runtime` | Yes |

The same task definitions run for both — pick one with a single `-e` flag (or use the `bootstrap.sh` mode shortcut). `tool_scope=system` requires `has_sudo=true`; the role fails fast otherwise.

## Repo structure

```
workstation/
├── bootstrap.sh                        ← RHEL VM entry point — thin Ansible seed
├── bootstrap.ps1                       ← Windows client entry point — choco tools + chezmoi apply (run elevated)
├── .chezmoiroot                        ← redirects chezmoi's source state to chezmoi/ subdir
├── hosts.conf                          ← single source of truth for VM list
│
├── scripts/
│   ├── manage-hosts.sh                 ← Linux/RHEL host manager
│   └── manage-hosts.ps1                ← Windows host manager (feature-parity)
│
├── ansible/                            ← RHEL provisioning
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.ini                   ← AUTO-GENERATED from hosts.conf
│   ├── group_vars/
│   │   └── all.yml                     ← shared variables + tool versions (single source of truth)
│   ├── playbooks/
│   │   ├── rhel.yml                    ← targets remote rhel_vms group (control-machine flow)
│   │   └── local.yml                   ← targets localhost (used by bootstrap.sh)
│   └── roles/
│       └── rhel-base/
│           ├── defaults/main.yml       ← install_*, has_sudo, tool_scope, arch
│           ├── handlers/main.yml
│           └── tasks/
│               ├── main.yml            ← validates + resolves scope vars, then orchestrates
│               ├── packages.yml        ← dnf packages (sudo)
│               ├── tools.yml           ← static binaries; honours tool_scope (user/system)
│               ├── shell.yml           ← PATH config
│               └── dotfiles.yml        ← chezmoi apply (uses tools_dest to find chezmoi)
│
└── chezmoi/                            ← cross-platform dotfiles (Linux + Windows)
    ├── .chezmoi.toml.tmpl              ← prompts for name/email on first init
    ├── .chezmoiignore.tmpl             ← OS-aware: ignores Linux-only on Windows, vice versa
    ├── .chezmoiscripts/
    │   └── run_once_after_init.sh      ← runs once on first apply (Linux only)
    │
    ├── dot_bashrc.tmpl                 ← Linux: ~/.bashrc
    ├── dot_gitconfig.tmpl              ← cross-platform: ~/.gitconfig
    ├── dot_nbrc                        ← Linux: ~/.nbrc
    ├── dot_config/                     ← cross-platform: ~/.config/
    │   ├── starship.toml
    │   ├── helix/config.toml
    │   ├── zellij/{config.kdl, layouts/dev.kdl}    ← Linux only
    │   └── wezterm/wezterm.lua                     ← Windows only (Linux-ignored)
    │
    ├── AppData/Roaming/                ← Windows: %USERPROFILE%\AppData\Roaming\
    │   ├── Zed/settings.json
    │   └── Code/User/{settings.json, keybindings.json}
    │
    └── Documents/                      ← Windows: %USERPROFILE%\Documents\
        ├── PowerShell/Microsoft.PowerShell_profile.ps1.tmpl       ← PS 7
        └── WindowsPowerShell/Microsoft.PowerShell_profile.ps1     ← PS 5.1 (dot-sources PS 7)
```

## Setup

### 1. Configure once

Update before pushing your fork:
- [ ] `ansible/group_vars/all.yml` — set `dev_user` and `dotfiles_repo` to your fork's URL.
- [ ] `hosts.conf` — add VMs with `./scripts/manage-hosts.sh --add ...` (or edit and `--format`), or let `bootstrap.sh` self-register them.

You should not need to edit `ansible/inventory/hosts.ini` — it is regenerated from `hosts.conf` by the `manage-hosts` scripts.

### 2. On each RHEL VM

`bootstrap.sh` needs only `curl`, `git`, `python3` (≥ 3.9), `python3 -m pip`, and `iproute` (`ip` command). It does a single preflight check that reports **all** missing prereqs at once — no more discovering them one by one. It installs `ansible-core` itself (via `pip3 install --user`) on first run and smoke-tests it before handing off to Ansible.

#### Three env vars to set before running

| Var | Why | Where to keep it |
|---|---|---|
| `GITHUB_TOKEN` | Authenticates the curl fetch of `bootstrap.sh` AND the script's internal `git clone`/`pull`/`push` for this private repo. Persisted into `.git/config` (`http.https://github.com/.extraheader`) so `chezmoi update`, manual `git pull`, and the auto-push step keep working without re-passing it. | Password manager (1Password, Bitwarden, KeePass). **Never committed.** Generate with `repo` scope (classic) or Contents:Read (fine-grained) at https://github.com/settings/tokens. |
| `GIT_USER_NAME` | Author name on the auto-registration commit (the script falls back to `whoami` synthetic identity if unset). | Same — your password-manager note next to the token, so the values travel together. |
| `GIT_USER_EMAIL` | Author email on the auto-registration commit (synthetic fallback is `whoami@hostname`). | Same. |

#### Copy-paste one-liners (replace `<your-PAT>` with the real token from your password manager)

**Personal RHEL VMs (no sudo, install to `~/.local/bin`):**
```bash
# === Bootstrap: ATC personal RHEL VM (user-scope, ~/.local/bin) ===
export GITHUB_TOKEN='<your-PAT>' \
       GIT_USER_NAME='Arrush Chaturvedi' \
       GIT_USER_EMAIL='contact@arrushc.com' && \
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash && \
source ~/.bashrc
```

**Personal RHEL VMs with sudo (system-wide install to `/usr/local/bin` + `dnf` packages):**
```bash
# === Bootstrap: ATC personal RHEL VM (system-scope, sudo) ===
export GITHUB_TOKEN='<your-PAT>' \
       GIT_USER_NAME='Arrush Chaturvedi' \
       GIT_USER_EMAIL='contact@arrushc.com' && \
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --full
```

> If you bootstrap from machines with different identities (e.g., a work laptop where commits should use a different email), keep separate copy-paste blocks in your password manager — one per identity profile, with the comment line at the top labelling which machine it's for. The `GIT_USER_NAME`/`GIT_USER_EMAIL` envs override `~/.gitconfig` for the duration of that one bootstrap run only — your existing chezmoi-applied gitconfig is left untouched on disk.

What `bootstrap.sh` does, in order:
1. Preflight check (curl/git/python3/pip/iproute, python ≥ 3.9).
2. Clone the repo into `~/.local/share/chezmoi` (or `git pull --ff-only` if present).
3. **Self-register** the VM in `hosts.conf` (via `hostname -s`, detected primary IP, `whoami`, group `rhel_vms`) and run `manage-hosts.sh --sync` so inventory + the chezmoi-tracked `chezmoi/dot_config/wezterm/wezterm.lua` block are regenerated locally.
4. Install `ansible-core` via `pip3 --user` if missing, smoke-test `ansible-playbook --version`.
5. Run `playbooks/local.yml` against the VM.
6. **Auto-commit and push** the host-list changes (`hosts.conf`, `ansible/inventory/hosts.ini`, `chezmoi/dot_config/wezterm/wezterm.lua`) with the message `chore(hosts): register <hostname>`. If the push fails (auth, conflict, no upstream), the script warns with a recovery `git push` command — it does **not** abort. Provisioning has already succeeded by this point.

After bootstrap finishes, copy your SSH key from your client (Windows host or another VM) — see [Host management → Copy SSH key](#copy-ssh-key) below.

Both modes are idempotent — re-run any time to pick up updates. Re-running can also switch scopes; binaries left from the previous scope can be cleaned up manually if you want a tidy state.

### 3. On Windows

The Windows host is a **client** — no Ansible, but **chezmoi runs here too** to deploy the dotfiles tracked in this repo (`wezterm.lua`, the PowerShell profile, Zed settings, VSCode settings). `bootstrap.ps1` is the parallel of `bootstrap.sh`: preflight (admin check) → install Chocolatey + the dev tools → clone → `chezmoi init --apply` → optional SSH-key generation.

> **Run from an elevated PowerShell.** Chocolatey itself needs admin to install, as do most package installs. Right-click PowerShell → "Run as administrator", or use `Start-Process pwsh -Verb RunAs`. If you already have everything installed and just want the chezmoi-apply step, pass `-SkipToolInstall` to skip the elevation requirement.

**Tools installed by bootstrap.ps1 (via Chocolatey):** chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode. Optional ones warn-not-fail; chezmoi and Git are required. Choco rather than winget because winget's PATH propagation is unreliable mid-session — tools install but aren't always resolvable when chezmoi tries to use them in the next step.

**Recommended one-liner** (run from elevated PowerShell — private repo with the same `GITHUB_TOKEN`/`GIT_USER_NAME`/`GIT_USER_EMAIL` you'd use for a Linux bootstrap):

```powershell
# === Bootstrap: Windows client ===
$env:GITHUB_TOKEN  = '<your-PAT>'
$env:GIT_USER_NAME  = 'Arrush Chaturvedi'
$env:GIT_USER_EMAIL = 'contact@arrushc.com'
irm -Headers @{Authorization="token $env:GITHUB_TOKEN"} `
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1 | iex
```

Or after cloning the repo manually:

```powershell
git clone https://github.com/ArrushC/workstation.git C:\Git\workstation
cd C:\Git\workstation
.\bootstrap.ps1                                          # default flow (must be elevated)
.\bootstrap.ps1 -RepoPath D:\dev\workstation             # alternate clone path
.\bootstrap.ps1 -SkipToolInstall                         # skip choco step (tools already installed; non-elevated OK)
.\bootstrap.ps1 -SkipChezmoi                             # clone + install but don't deploy dotfiles yet
.\bootstrap.ps1 -SkipKeyGen                              # skip the SSH-key prompt
```

What `bootstrap.ps1` does:
1. **Preflight** — admin check (required unless `-SkipToolInstall` is passed). With `-SkipToolInstall`, expects `git` and `chezmoi` already on PATH. OpenSSH client is warned-not-failed either way.
2. **Bootstrap Chocolatey + install tools** — if `choco` isn't already on PATH, fetches and runs the official install script from `community.chocolatey.org`. Then `choco install -y` runs for each of: chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode. Required tools (chezmoi, Git) fail the whole script if their install errors; optional tools warn-and-continue. After installs, the session's `$env:PATH` is refreshed from the registry so the new binaries resolve in the next step.
3. **Clone the repo** into `-RepoPath` (default `C:\Git\workstation`), or `git pull --ff-only` if already present. `GITHUB_TOKEN` is persisted into `.git/config` (`http.https://github.com/.extraheader`, github.com-scoped) so subsequent `git push`, `git pull`, `chezmoi update`, and `manage-hosts.ps1` ops authenticate without re-passing the env var.
4. **Run `chezmoi init --apply --source <RepoPath>`** — `.chezmoiroot` at the repo root redirects the source state into the `chezmoi/` subdirectory, where the OS-aware `.chezmoiignore.tmpl` filters out Linux-only files (helix, zellij, dot_bashrc.tmpl, dot_nbrc) and applies the Windows-targeted ones (PowerShell profile to `%USERPROFILE%\Documents\PowerShell\`, Zed/VSCode settings to `%APPDATA%\…`, `wezterm.lua` to `%USERPROFILE%\.config\wezterm\`).
5. **Re-hardlink `wezterm.lua`** — replaces the chezmoi-written regular file at `%USERPROFILE%\.config\wezterm\wezterm.lua` with a hardlink to the chezmoi-tracked source at `chezmoi\dot_config\wezterm\wezterm.lua`. **Hybrid model**: chezmoi tracks the file (so it ships through the same `chezmoi apply` workflow as everything else), and the hardlink lets edits to the repo file — including from `manage-hosts.ps1 -Sync` — appear in WezTerm immediately via `automatically_reload_config`, without you having to run `cza` after every host-list change. If `chezmoi apply` ever atomic-writes the file (only if content has drifted out of band), the link breaks; re-run `bootstrap.ps1` to restore it.
6. **SSH key** — prompts to generate `%USERPROFILE%\.ssh\id_ed25519` if missing. Used by `manage-hosts.ps1 -CopyId` to copy your public key to VMs for passwordless SSH.

After bootstrap, restart your shell so the chezmoi-applied `$PROFILE` picks up — starship prompt, `cz`/`cza`/`cze`/`czd`/`czu`/`czs` aliases, git aliases, etc.

**Editing dotfiles**: same workflow as Linux. `cze <path>` opens the source-state copy in your editor; `cza` applies pending changes; `czd` shows the diff; `cz cd` jumps to the source dir for direct git ops.

WezTerm auto-opens a tab per VM on launch and attaches to a persistent Zellij session. Press **`CTRL+SHIFT+H`** inside WezTerm for a cheatsheet of keybinds, aliases, and hosts. Other useful binds:

| Bind | Action |
|---|---|
| `CTRL+SHIFT+H` | Cheatsheet overlay |
| `CTRL+SHIFT+J` | Pick a host (fuzzy) and spawn a tab to it |
| `CTRL+SHIFT+S` | Switch tab (fuzzy) |
| `CTRL+SHIFT+T` | New tab in current domain |
| `CTRL+SHIFT+W` | Close current tab (with confirm) |
| `CTRL+TAB` / `CTRL+SHIFT+TAB` | Cycle tabs |
| `ALT+1..9` | Jump to tab N |
| `CTRL+SHIFT+R` | Reload `wezterm.lua` |

---

## Host management

`hosts.conf` is the single source of truth for VMs. Two outputs are regenerated from it:

- `ansible/inventory/hosts.ini` (full overwrite)
- `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block (in-place replace between `-- HOSTS:START` and `-- HOSTS:END` sentinels). After running `--sync` on Windows, run `chezmoi apply` (or `cza`) to push the updated file into `%USERPROFILE%\.config\wezterm\`.

Use the manage-hosts scripts; they re-pad column widths automatically and keep both outputs in sync.

### Linux / RHEL

```bash
./scripts/manage-hosts.sh                # interactive menu
./scripts/manage-hosts.sh --sync         # regenerate inventory + wezterm block
./scripts/manage-hosts.sh --list         # print table
./scripts/manage-hosts.sh --format       # re-pad hosts.conf
./scripts/manage-hosts.sh --add --name N --ip I --user U --group G --skip-confirm
./scripts/manage-hosts.sh --remove
```

### Windows

```powershell
.\scripts\manage-hosts.ps1               # interactive menu
.\scripts\manage-hosts.ps1 -Sync
.\scripts\manage-hosts.ps1 -List
.\scripts\manage-hosts.ps1 -Format
.\scripts\manage-hosts.ps1 -Add -Name N -Ip I -User U -Group G -SkipConfirm
.\scripts\manage-hosts.ps1 -Remove
```

The two scripts produce **identical output** for the same `hosts.conf`. After any change to `hosts.conf`, run `--sync` (or `-Sync`) before committing so the inventory and wezterm block stay in lockstep.

> **Don't hand-pad `hosts.conf`** — the save routine recalculates column widths from data, so any manual fixed-width padding gets normalised away on next save.

> **`hosts.conf` is auto-sorted** by group, then by name, on every save (add / edit / remove / format / `bootstrap.sh` self-registration). Manual reordering won't survive the next save. If you want explicit grouping, use the group column.

### Copy SSH key

After a VM is registered, you still need your public key in its `~/.ssh/authorized_keys` before WezTerm or Ansible can connect without a password. Both scripts have a `--copy-id` / `-CopyId` command for this.

Linux / RHEL:
```bash
./scripts/manage-hosts.sh --copy-id --name rhel-dev-03   # explicit
./scripts/manage-hosts.sh --copy-id                      # interactive picker
```

Windows:
```powershell
.\scripts\manage-hosts.ps1 -CopyId -Name rhel-dev-03     # explicit
.\scripts\manage-hosts.ps1 -CopyId                       # interactive picker
```

Behaviour:
- Looks the host up in `hosts.conf` and uses its `User`/`Ip` columns.
- If `~/.ssh/id_ed25519` (Linux) or `%USERPROFILE%\.ssh\id_ed25519` (Windows) is missing, prompts to generate one with `ssh-keygen -t ed25519 -N ""` (no passphrase). Decline and the command exits without copying.
- Linux: uses the native `ssh-copy-id` if available; otherwise falls back to a manual `ssh user@host "mkdir -p ~/.ssh && cat >> authorized_keys && ..."` that also de-duplicates the file.
- Windows: always uses the manual SSH method — Windows OpenSSH ships no `ssh-copy-id`.
- After a successful `--add`, both scripts print a tip line that pre-fills the host name for you.

---

## Daily workflows

### chezmoi (Linux VM or Windows host)

The same aliases work on both OSes — defined in `dot_bashrc.tmpl` for Linux and the templated `Microsoft.PowerShell_profile.ps1.tmpl` for Windows:

```bash
cze ~/.bashrc      # edit a dotfile (Linux)         |  cze $PROFILE  on Windows
cza                # apply changes locally
czd                # diff — see what would change
czu                # pull latest from repo and apply
czs                # status

# Push changes back to the repo
cd ~/.local/share/chezmoi   # or wherever the source state lives
git add -A && git commit -m "update bashrc" && git push
```

**Per-machine overrides** are untracked and sourced last by the main config:

```bash
# Linux: ~/.bashrc.local
export GOPATH="/opt/go"
alias work='cd /opt/myproject'
```

```powershell
# Windows: %USERPROFILE%\Documents\PowerShell\Microsoft.PowerShell_profile.local.ps1
$env:GOPATH = "C:\Go"
function work { Set-Location "D:\dev\myproject" }
```

### Ansible — remote (control machine → all VMs in inventory)

```bash
cd ansible

# Default: provision all VMs in user scope (~/.local/bin)
ansible-playbook playbooks/rhel.yml --ask-become-pass

# System scope (install to /usr/local/bin instead)
ansible-playbook playbooks/rhel.yml -e "tool_scope=system" --ask-become-pass

# Single VM
ansible-playbook playbooks/rhel.yml --limit rhel-dev-01 --ask-become-pass

# Dotfiles + user tools only, no sudo
ansible-playbook playbooks/rhel.yml \
  -e "has_sudo=false install_system_packages=false"

# Dry run (show what would change)
ansible-playbook playbooks/rhel.yml --check
```

### Ansible — local (self-provisioning, what `bootstrap.sh` runs under the hood)

```bash
cd ansible

# User scope (no sudo)
ansible-playbook playbooks/local.yml \
  -e "tool_scope=user has_sudo=false install_system_packages=false"

# System scope (sudo)
ansible-playbook playbooks/local.yml \
  -e "tool_scope=system has_sudo=true" --ask-become-pass

# Dry run
ansible-playbook playbooks/local.yml --check \
  -e "tool_scope=user has_sudo=false install_system_packages=false"
```

---

## Adding a new tool

There is **one** place to edit, not two:

1. Add an install task in `ansible/roles/rhel-base/tasks/tools.yml`. Use `dest: "{{ tools_dest }}"` and `become: "{{ tools_become }}"` — the role resolves these from `tool_scope`.

   Example (a `direnv`-style static binary):
   ```yaml
   # --- direnv ----------------------------------------------------------------
   - name: "Install direnv"
     ansible.builtin.get_url:
       url: "https://github.com/direnv/direnv/releases/download/v{{ direnv_version }}/direnv.linux-amd64"
       dest: "{{ tools_dest }}/direnv"
       mode: "0755"
     args:
       creates: "{{ tools_dest }}/direnv"
     become: "{{ tools_become }}"
   ```

2. Pin the version in `ansible/group_vars/all.yml`:
   ```yaml
   direnv_version: "2.34.0"
   ```

Both user and system scope work automatically. **Do not** add tool-specific logic or version pins to `bootstrap.sh` — it intentionally has none.

## Bumping a tool version

Edit `ansible/group_vars/all.yml`, change one line, commit. The next `ansible-playbook` run picks up the new version. There is no second file to keep in sync.

---

## Adding a new VM

1. On the new VM:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
   ```
   Self-registration appends the VM to `hosts.conf`.
2. From any other machine with the repo: `git pull` and run `./scripts/manage-hosts.sh --sync` (or `-Sync` on Windows) so `hosts.ini` and the wezterm block update everywhere.
3. Commit and push the updated `hosts.conf`, `hosts.ini`, and `chezmoi/dot_config/wezterm/wezterm.lua`.

---

## Troubleshooting

- **Bootstrap reports "Missing required prerequisites: …".** Install all listed tools at once. RHEL: `sudo dnf install curl git python3 python3-pip iproute`. Bootstrap deliberately collects every gap up front so you only have to install once.
- **Bootstrap fails with "python3 ≥ 3.9 required for ansible-core".** Your distro's `python3` is too old. On RHEL 8: enable a newer module stream (`sudo dnf module install python39`) or install `python3.11` and ensure `python3` resolves to it.
- **Bootstrap fails with "ansible-playbook not on PATH after pip install".** `pip install --user` dropped the binary in `~/.local/bin` but your shell hasn't picked that up yet. Run `export PATH="$HOME/.local/bin:$PATH"` and re-run `./bootstrap.sh`. After this run completes, [shell.yml](ansible/roles/rhel-base/tasks/shell.yml) wires the PATH permanently.
- **Bootstrap finishes with "Push failed (auth, conflict, or no upstream)".** Provisioning succeeded — only the host-list push didn't. Recover with `cd ~/.local/share/chezmoi && git push`. Common causes: no SSH key for the git remote, a divergent upstream (`git pull --rebase` first), or you've forked and never set the remote.
- **Private repo: clone fails with "Authentication failed" or 404.** Set `GITHUB_TOKEN` to a PAT with `repo` (classic) or Contents:Read (fine-grained) scope and re-run. The token is written into `.git/config` as `http.https://github.com/.extraheader` so subsequent ops (push, `chezmoi update`, manual `git pull`) all work — re-passing the env var on later runs just refreshes the stored value. To clear it: `git -C ~/.local/share/chezmoi config --unset http.https://github.com/.extraheader`.
- **`./scripts/manage-hosts.sh --copy-id` keeps prompting for a password every connection.** The key landed but `sshd` isn't using it. Check the target's `/etc/ssh/sshd_config` (`PubkeyAuthentication yes`, `AuthorizedKeysFile .ssh/authorized_keys`) and the perms (`~/.ssh` = 700, `~/.ssh/authorized_keys` = 600). On SELinux RHEL: `restorecon -R -v ~/.ssh`.
- **`ssh-keygen` on Windows opens a passphrase prompt despite `-N '""'`.** Some PowerShell quoting variants strip the empty-passphrase argument. Re-run interactively and just press Enter twice; the rest of the flow is unchanged.
- **`ansible-playbook: command not found` after a fresh `bootstrap.sh` run.** Same root cause as above — PATH didn't include `~/.local/bin`. Either `source ~/.bashrc` or run `export PATH="$HOME/.local/bin:$PATH"` and retry.
- **WezTerm shows old config after an edit.** Normally edits to `chezmoi/dot_config/wezterm/wezterm.lua` are visible immediately because `bootstrap.ps1` hardlinks the home path to the chezmoi source. Confirm the link is intact: `fsutil hardlink list "$env:USERPROFILE\.config\wezterm\wezterm.lua"` should list **both** the home path and the repo path. If only the home path appears, the link broke (chezmoi atomic-write, an editor that doesn't preserve hardlinks, or someone deleted and re-created the file). Restore with `.\bootstrap.ps1 -SkipToolInstall -SkipChezmoi -SkipKeyGen` (just runs the hardlink step) — or run the full `bootstrap.ps1`.
- **`bootstrap.ps1` aborts with "This script must run from an elevated PowerShell".** Chocolatey and most package installs need admin. Close the shell, right-click PowerShell → "Run as administrator", re-run. If you already have every tool installed (chezmoi, git, starship, zoxide, WezTerm, Zed, VSCode), pass `-SkipToolInstall` to bypass the elevation requirement and only do the chezmoi-apply + ssh-key steps.
- **`bootstrap.ps1` reports "Chocolatey install completed but `choco` is not on PATH".** The choco installer succeeded but the current shell's PATH wasn't refreshed in time. Close the elevated PowerShell, open a new elevated PowerShell, and re-run — the new session inherits the updated machine PATH and picks up `choco` correctly.
- **A `choco install` step says "package not found" or "deprecated".** Choco package IDs occasionally get renamed/retired upstream. Edit `$ChocoTools` in `bootstrap.ps1` to point at the current ID (search at https://community.chocolatey.org/packages), or set the tool as `Required = $false` so the rest of the install proceeds and install it manually.
- **`hosts.ini` is out of sync with `hosts.conf`.** Run `./scripts/manage-hosts.sh --sync`. Never edit `hosts.ini` directly — it's auto-generated.
- **`tool_scope=system` errored with "requires has_sudo=true".** Pass both flags: `-e "tool_scope=system has_sudo=true"`.
