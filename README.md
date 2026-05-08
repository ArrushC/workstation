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
├── bootstrap.sh                        ← VM entry point — thin seed, delegates to Ansible
├── hosts.conf                          ← single source of truth for VM list
├── wezterm.lua                         ← Windows terminal config (hardlinked to %USERPROFILE%\.config\wezterm\)
├── COMMANDS_WINDOWS.md                 ← one-liner to create the WezTerm hardlink
│
├── scripts/
│   ├── manage-hosts.sh                 ← Linux/RHEL host manager
│   └── manage-hosts.ps1                ← Windows host manager (feature-parity)
│
├── ansible/                            ← all provisioning lives here
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
└── chezmoi/                            ← personal dotfiles (no sudo)
    ├── .chezmoi.toml.tmpl              ← prompts for name/email on first init
    ├── .chezmoiignore
    ├── .chezmoiscripts/
    │   └── run_once_after_init.sh      ← runs once on first apply
    ├── home/
    │   ├── dot_bashrc.tmpl             ← main shell config, per-machine templated
    │   ├── dot_gitconfig.tmpl          ← git config
    │   └── dot_nbrc                    ← nb notes config
    └── dot_config/
        ├── starship.toml
        ├── helix/config.toml
        └── zellij/
            ├── config.kdl
            └── layouts/dev.kdl
```

## Setup

### 1. Configure once

Update before pushing your fork:
- [ ] `ansible/group_vars/all.yml` — set `dev_user` and `dotfiles_repo` to your fork's URL.
- [ ] `hosts.conf` — add VMs with `./scripts/manage-hosts.sh --add ...` (or edit and `--format`), or let `bootstrap.sh` self-register them.

You should not need to edit `ansible/inventory/hosts.ini` — it is regenerated from `hosts.conf` by the `manage-hosts` scripts.

### 2. On each RHEL VM

`bootstrap.sh` requires only `curl`, `git`, and `python3`. It installs `ansible-core` itself (via `pip3 install --user`) on first run, then hands off to Ansible.

**With sudo** (system-wide install to `/usr/local/bin`, plus `dnf` packages):
```bash
git clone https://github.com/ArrushC/workstation.git
cd workstation && ./bootstrap.sh --full
# or one-liner (fresh VM, repo not cloned yet):
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --full
```

**No sudo** (everything to `~/.local/bin`):
```bash
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
source ~/.bashrc
```

Both modes:
- Self-register the VM in `hosts.conf` (using `hostname -s`, detected primary IP, `whoami`, group `rhel_vms`).
- Are idempotent — re-run any time to pick up updates.
- Can be re-run to switch scopes; binaries left from the previous scope can be cleaned up manually if you want a tidy state.

### 3. On Windows

WezTerm reads `%USERPROFILE%\.config\wezterm\wezterm.lua`. Hard-link it to the repo so edits stay in source control:

```powershell
# Create the wezterm config dir if it doesn't exist
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.config\wezterm"

# Hard link — wezterm reads from here, git tracks from the repo
New-Item -ItemType HardLink `
    -Path "$env:USERPROFILE\.config\wezterm\wezterm.lua" `
    -Target "C:\Git\workstation\wezterm.lua"
```

(Same one-liner is in [COMMANDS_WINDOWS.md](COMMANDS_WINDOWS.md).)

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

> **Hardlink hazard**: editors that atomic-save (write-temp-then-rename) silently break the hardlink — the home-side file is left pointing at the old inode and WezTerm keeps loading the stale version. After any edit to `wezterm.lua`, compare `LastWriteTime` and `Length` between the repo path and `%USERPROFILE%\.config\wezterm\wezterm.lua`. If they diverge, recreate the link with the command above.

---

## Host management

`hosts.conf` is the single source of truth for VMs. Two outputs are regenerated from it:

- `ansible/inventory/hosts.ini` (full overwrite)
- `wezterm.lua` SSH-domains block (in-place replace between `-- HOSTS:START` and `-- HOSTS:END` sentinels)

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

---

## Daily workflows

### chezmoi (on any VM)

```bash
cze ~/.bashrc      # edit a dotfile
cza                # apply changes locally
czd                # diff — see what would change
czu                # pull latest from repo and apply
czs                # status

# Push changes back to the repo
cd ~/.local/share/chezmoi
git add -A && git commit -m "update bashrc" && git push
```

Per-machine overrides go in `~/.bashrc.local`, which is **not** tracked and is sourced last by the templated bashrc:

```bash
# ~/.bashrc.local
export GOPATH="/opt/go"
alias work='cd /opt/myproject'
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
3. Commit and push the updated `hosts.conf`, `hosts.ini`, and `wezterm.lua`.

---

## Troubleshooting

- **`bootstrap.sh` says `python3 is required`.** Install python3 via your distro's installer first (RHEL: `sudo dnf install python3 python3-pip`). The script needs it to install `ansible-core`.
- **`ansible-playbook: command not found` after a fresh `bootstrap.sh` run.** `pip install --user` puts it in `~/.local/bin`; either `source ~/.bashrc` or run `export PATH="$HOME/.local/bin:$PATH"` and retry.
- **WezTerm shows old config after an edit.** The hardlink broke (atomic-save). Compare `LastWriteTime`/`Length` between the repo path and `%USERPROFILE%\.config\wezterm\wezterm.lua` and recreate the link if they differ — see the warning in step 3 above.
- **`hosts.ini` is out of sync with `hosts.conf`.** Run `./scripts/manage-hosts.sh --sync`. Never edit `hosts.ini` directly — it's auto-generated.
- **`tool_scope=system` errored with "requires has_sudo=true".** Pass both flags: `-e "tool_scope=system has_sudo=true"`.
