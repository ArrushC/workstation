# workstation

Dev environment provisioning for RHEL VMs.
Ansible handles system-level setup. Chezmoi manages personal dotfiles.

## Stack

| Layer | Tool | Purpose |
|---|---|---|
| System | **Ansible** | Packages, PATH, sudo-level config |
| Dotfiles | **chezmoi** | Personal shell config, templated per machine |
| Shell | **starship** | Prompt |
| Multiplexer | **zellij** | Persistent sessions, layouts |
| Fuzzy find | **fzf** | History, files, SSH hosts |
| Jump | **zoxide** | Smarter `cd` |
| Editor | **helix** | Modal editor, zero config |
| Notes | **nb + glow** | CLI notes, markdown preview |
| Terminal | **WezTerm** | Windows terminal, auto-connects to VMs |

## Repo structure

```
workstation/
├── bootstrap.sh                        ← entry point for any VM
├── wezterm.lua                         ← Windows terminal config (not deployed to VMs)
│
├── ansible/                            ← system provisioning (sudo)
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.ini                   ← your RHEL VMs
│   ├── group_vars/
│   │   └── all.yml                     ← shared variables + tool versions
│   ├── playbooks/
│   │   └── rhel.yml                    ← main playbook
│   └── roles/
│       └── rhel-base/
│           ├── defaults/main.yml
│           ├── handlers/main.yml
│           └── tasks/
│               ├── main.yml            ← orchestrates task files
│               ├── packages.yml        ← dnf packages (sudo)
│               ├── tools.yml           ← static binaries to ~/.local/bin
│               ├── shell.yml           ← PATH config
│               └── dotfiles.yml        ← chezmoi apply
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

### 1. Clone and configure

```bash
git clone https://github.com/ArrushC/workstation.git
cd workstation
```

Update before pushing:
- [ ] `ansible/inventory/hosts.ini` — add your RHEL VM IPs and username
- [ ] `ansible/group_vars/all.yml` — set `dev_user` and `dotfiles_repo`
- [x] `bootstrap.sh` — replace `YOUR_USERNAME`
- [x] `wezterm.lua` — replace `remote_address` and `username`

### 2. On each RHEL VM

**If you have sudo** (full provisioning via Ansible):
```bash
pip3 install --user ansible
git clone https://github.com/ArrushC/workstation.git
cd workstation && ./bootstrap.sh --full
```

**No sudo** (user-space only, works everywhere):
```bash
curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
source ~/.bashrc
```

### 3. On Windows

Copy `wezterm.lua` to `%USERPROFILE%\.config\wezterm\wezterm.lua`.
WezTerm auto-opens a tab per VM on launch and attaches to a persistent Zellij session.

---

## Daily chezmoi workflow

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

## Daily Ansible workflow

```bash
cd workstation/ansible

# Full provisioning on all VMs
ansible-playbook playbooks/rhel.yml -i inventory/hosts.ini --ask-become-pass

# Single VM
ansible-playbook playbooks/rhel.yml -i inventory/hosts.ini --limit rhel-dev-01 --ask-become-pass

# Dotfiles only, no sudo
ansible-playbook playbooks/rhel.yml -i inventory/hosts.ini \
  -e "install_system_packages=false has_sudo=false"

# Dry run
ansible-playbook playbooks/rhel.yml -i inventory/hosts.ini --check
```

## Per-machine overrides

`~/.bashrc.local` on any VM — not tracked, never committed:
```bash
export GOPATH="/opt/go"
alias work='cd /opt/myproject'
```
