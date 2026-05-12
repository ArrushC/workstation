# workstation

Dev environment provisioning for Linux hosts, plus the WezTerm config that connects to them from Windows.

Ansible owns **all** installations — system packages, user-space tools, and the chezmoi handoff for dotfiles. `bootstrap.sh` is a thin seed: it clones the repo, installs `ansible-core` via `pip3 --user` if needed, then runs a local Ansible playbook against the host. There is no duplicated install logic — adding a tool is a one-file edit.

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
| Terminal | **WezTerm** | Windows terminal, auto-connects to hosts |

## Machine types

Every host belongs to exactly one of two Ansible groups. The group decides the install scope — there is no separate scope flag.

| Group | Sudo? | Binary destination | Helix runtime | Used for |
|---|---|---|---|---|
| `dev_machine` | Yes | `/usr/local/bin` | `/usr/local/lib/helix/runtime` | Hosts you own — full system-wide install via the OS package manager (dnf on RHEL/Fedora today) + `/usr/local/bin`. |
| `prod_machine` | No | `~/.local/bin` | `~/.config/helix/runtime` | Hosts you don't fully own — user-wide install only, no system packages. |

The scope values for each group live in `ansible/group_vars/dev_machine.yml` and `ansible/group_vars/prod_machine.yml`. Ansible loads them automatically for remote runs; `bootstrap.sh` loads the same file for its local self-provisioning run via `-e "@group_vars/<group>.yml"`. Same file, same values — local and remote stay aligned.

Pick a group with `./bootstrap.sh --dev` or `./bootstrap.sh --prod`. Exactly one of the two is required.

## Repo structure

```
workstation/
├── bootstrap.sh                        ← Linux host entry point — thin Ansible seed
├── bootstrap.ps1                       ← Windows client entry point — choco tools + chezmoi apply (run elevated)
├── .chezmoiroot                        ← redirects chezmoi's source state to chezmoi/ subdir
├── hosts.conf                          ← single source of truth for host list
│
├── scripts/
│   ├── manage-hosts.sh                 ← Linux host manager
│   └── manage-hosts.ps1                ← Windows host manager (feature-parity)
│
├── ansible/                            ← Linux provisioning
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.ini                   ← AUTO-GENERATED from hosts.conf
│   ├── group_vars/
│   │   ├── all.yml                     ← shared variables + tool versions (single source of truth)
│   │   ├── dev_machine.yml             ← sudo, system-wide install (tool_scope=system, has_sudo=true)
│   │   └── prod_machine.yml            ← no sudo, user-wide install  (tool_scope=user,  has_sudo=false)
│   ├── playbooks/
│   │   ├── linux.yml                   ← targets dev_machine + prod_machine groups (control-machine flow)
│   │   └── local.yml                   ← targets localhost (used by bootstrap.sh; group_vars loaded via -e "@...")
│   └── roles/
│       └── linux-base/
│           ├── defaults/main.yml       ← install_*, has_sudo, tool_scope, arch
│           ├── handlers/main.yml
│           └── tasks/
│               ├── main.yml            ← validates + resolves scope vars, then orchestrates
│               ├── packages.yml        ← system packages via ansible.builtin.package (sudo)
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
- [ ] `hosts.conf` — add hosts with `./scripts/manage-hosts.sh --add ...` (or edit and `--format`), or let `bootstrap.sh` self-register them.

You should not need to edit `ansible/inventory/hosts.ini` — it is regenerated from `hosts.conf` by the `manage-hosts` scripts.

### 2. On each Linux host

`bootstrap.sh` needs only `curl`, `git`, `python3` (≥ 3.9), `python3 -m pip`, and `iproute` (`ip` command). It does a single preflight check that reports **all** missing prereqs at once — no more discovering them one by one. It installs `ansible-core` itself (via `pip3 install --user`) on first run and smoke-tests it before handing off to Ansible.

#### Three env vars to set before running

| Var | Why | Where to keep it |
|---|---|---|
| `GITHUB_TOKEN` | Authenticates the curl fetch of `bootstrap.sh` AND the script's internal `git clone`/`pull`/`push` for this private repo. Persisted into `.git/config` (`http.https://github.com/.extraheader`) so `chezmoi update`, manual `git pull`, and the auto-push step keep working without re-passing it. | Password manager (1Password, Bitwarden, KeePass). **Never committed.** Generate with `repo` scope (classic) or Contents:Read (fine-grained) at https://github.com/settings/tokens. |
| `GIT_USER_NAME` | Author name on the auto-registration commit (the script falls back to `whoami` synthetic identity if unset). | Same — your password-manager note next to the token, so the values travel together. |
| `GIT_USER_EMAIL` | Author email on the auto-registration commit (synthetic fallback is `whoami@hostname`). | Same. |

#### Copy-paste one-liners (replace `<your-PAT>` with the real token from your password manager)

Exactly one of `--dev` or `--prod` is required — it decides both the group this host registers as in `hosts.conf` and the scope the local playbook runs in. There is no default.

**Prod machine (host you don't fully own — no sudo, install to `~/.local/bin`):**
```bash
# === Bootstrap: prod machine (no sudo, ~/.local/bin) ===
export GITHUB_TOKEN='<your-PAT>' \
       GIT_USER_NAME='Arrush Chaturvedi' \
       GIT_USER_EMAIL='contact@arrushc.com' && \
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod && \
source ~/.bashrc
```

**Dev machine (host you own — sudo, system-wide install to `/usr/local/bin` + system packages):**
```bash
# === Bootstrap: dev machine (sudo, /usr/local/bin + system packages) ===
export GITHUB_TOKEN='<your-PAT>' \
       GIT_USER_NAME='Arrush Chaturvedi' \
       GIT_USER_EMAIL='contact@arrushc.com' && \
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --dev
```

> If you bootstrap from machines with different identities (e.g., a work laptop where commits should use a different email), keep separate copy-paste blocks in your password manager — one per identity profile, with the comment line at the top labelling which machine it's for. The `GIT_USER_NAME`/`GIT_USER_EMAIL` envs override `~/.gitconfig` for the duration of that one bootstrap run only — your existing chezmoi-applied gitconfig is left untouched on disk.

What `bootstrap.sh` does, in order:
1. Preflight check (curl/git/python3/pip/iproute, python ≥ 3.9).
2. Clone the repo into `~/.local/share/chezmoi` (or `git pull --ff-only` if present).
3. **Self-register** the host in `hosts.conf` (via `hostname -s`, detected primary IP, `whoami`, and the group derived from the `--dev`/`--prod` flag — `dev_machine` or `prod_machine`) and run `manage-hosts.sh --sync` so inventory + the chezmoi-tracked `chezmoi/dot_config/wezterm/wezterm.lua` block are regenerated locally.
4. Install `ansible-core` via `pip3 --user` if missing, smoke-test `ansible-playbook --version`.
5. Run `playbooks/local.yml` with `-e "@group_vars/<dev|prod>_machine.yml"` so scope (`tool_scope`, `has_sudo`, `install_system_packages`) comes from the same file that the remote `linux.yml` playbook uses.
6. **Auto-commit and push** the host-list changes (`hosts.conf`, `ansible/inventory/hosts.ini`, `chezmoi/dot_config/wezterm/wezterm.lua`) with the message `chore(hosts): register <hostname>`. If the push fails (auth, conflict, no upstream), the script warns with a recovery `git push` command — it does **not** abort. Provisioning has already succeeded by this point.

After bootstrap finishes, copy your SSH key from your client (Windows host or another Linux host) — see [Host management → Copy SSH key](#copy-ssh-key) below.

Both modes are idempotent — re-run any time to pick up updates. Re-running with a different `--dev`/`--prod` flag changes the host's group and scope; binaries left from the previous scope can be cleaned up manually if you want a tidy state.

#### Reinstalling from scratch (`--reinstall`)

If the local state has drifted, you've half-uninstalled chezmoi, or you just want a clean slate:

```bash
./bootstrap.sh --prod --reinstall              # prod machine (prompts before wiping)
./bootstrap.sh --dev  --reinstall --yes        # dev machine, skip prompt

# Or from outside the repo (script streams from memory, won't self-delete):
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod --reinstall --yes
```

```powershell
.\bootstrap.ps1 -Reinstall          # prompts before wiping
.\bootstrap.ps1 -Reinstall -Yes     # skip prompt

# Or from outside the repo:
irm -Headers @{Authorization="token $env:GITHUB_TOKEN"} `
  https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1 | iex
```

`--reinstall` wipes:
- The cloned repo (`~/.local/share/chezmoi` on Linux, `C:\Git\workstation` on Windows by default)
- chezmoi's config dir (`~/.config/chezmoi/`) — so `chezmoi init` re-prompts for name/email

It deliberately does **not** wipe:
- Installed tools (re-bootstrap detects them and skips — no-op)
- Deployed dotfiles in `$HOME` (chezmoi re-applies over them)
- SSH keys, ansible-core, system packages

If you also want to uninstall the tools themselves, do that manually first (`choco uninstall …` on Windows, `rm ~/.local/bin/{fzf,zoxide,…}` on Linux) — the script intentionally won't touch those.

> **Self-deletion guard**: running `.\bootstrap.ps1 -Reinstall` from inside the repo would delete the script while it's executing. Both scripts detect this and refuse with a clear instruction to use the curl-pipe form (script runs from memory) or copy the script outside the repo first.

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
1. **Preflight** — surveys what's already installed (`Get-Command` for each tool's binary). Admin is required **only if** there are required tools to install (or Chocolatey itself is missing). If everything's already on PATH, no admin needed and the install step short-circuits. If only optional tools are missing, the script warns and continues without admin. With `-SkipToolInstall` the elevation check is skipped entirely; `git` (always) and `chezmoi` (unless `-SkipChezmoi`) must already be on PATH. OpenSSH client is warned-not-failed either way.
2. **Bootstrap Chocolatey + install tools** — if `choco` isn't already on PATH, fetches and runs the official install script from `community.chocolatey.org`. Then `choco install -y` runs for each of: chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode. Required tools (chezmoi, Git) fail the whole script if their install errors; optional tools warn-and-continue. After installs, the session's `$env:PATH` is refreshed from the registry so the new binaries resolve in the next step.
3. **Clone the repo** into `-RepoPath` (default `C:\Git\workstation`), or `git pull --ff-only` if already present. `GITHUB_TOKEN` is persisted into `.git/config` (`http.https://github.com/.extraheader`, github.com-scoped) so subsequent `git push`, `git pull`, `chezmoi update`, and `manage-hosts.ps1` ops authenticate without re-passing the env var.
4. **Run `chezmoi init --apply --source <RepoPath>`** — `.chezmoiroot` at the repo root redirects the source state into the `chezmoi/` subdirectory, where the OS-aware `.chezmoiignore.tmpl` filters out Linux-only files (helix, zellij, dot_bashrc.tmpl, dot_nbrc) and applies the Windows-targeted ones (PowerShell profile to `%USERPROFILE%\Documents\PowerShell\`, Zed/VSCode settings to `%APPDATA%\…`, `wezterm.lua` to `%USERPROFILE%\.config\wezterm\`).
5. **Re-hardlink `wezterm.lua`** — replaces the chezmoi-written regular file at `%USERPROFILE%\.config\wezterm\wezterm.lua` with a hardlink to the chezmoi-tracked source at `chezmoi\dot_config\wezterm\wezterm.lua`. **Hybrid model**: chezmoi tracks the file (so it ships through the same `chezmoi apply` workflow as everything else), and the hardlink lets edits to the repo file — including from `manage-hosts.ps1 -Sync` — appear in WezTerm immediately via `automatically_reload_config`, without you having to run `cza` after every host-list change. If `chezmoi apply` ever atomic-writes the file (only if content has drifted out of band), the link breaks; re-run `bootstrap.ps1` to restore it.
6. **SSH key** — prompts to generate `%USERPROFILE%\.ssh\id_ed25519` if missing. Used by `manage-hosts.ps1 -CopyId` to copy your public key to hosts for passwordless SSH.

After bootstrap, restart your shell so the chezmoi-applied `$PROFILE` picks up — starship prompt, `cz`/`cza`/`cze`/`czd`/`czu`/`czs` aliases, git aliases, etc.

**Editing dotfiles**: same workflow as Linux. `cze <path>` opens the source-state copy in your editor; `cza` applies pending changes; `czd` shows the diff; `cz cd` jumps to the source dir for direct git ops.

WezTerm auto-opens a tab per host on launch and attaches to a persistent Zellij session. Press **`CTRL+SHIFT+H`** inside WezTerm for a cheatsheet of keybinds, aliases, and hosts. Other useful binds:

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

`hosts.conf` is the single source of truth for hosts. Two outputs are regenerated from it:

- `ansible/inventory/hosts.ini` (full overwrite)
- `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block (in-place replace between `-- HOSTS:START` and `-- HOSTS:END` sentinels). After running `--sync` on Windows, run `chezmoi apply` (or `cza`) to push the updated file into `%USERPROFILE%\.config\wezterm\`.

Use the manage-hosts scripts; they re-pad column widths automatically and keep both outputs in sync.

### Linux

```bash
./scripts/manage-hosts.sh                # interactive menu
./scripts/manage-hosts.sh --sync         # regenerate inventory + wezterm block
./scripts/manage-hosts.sh --list         # print table
./scripts/manage-hosts.sh --format       # re-pad hosts.conf
./scripts/manage-hosts.sh --add --name N --ip I --user U --group dev_machine --skip-confirm
./scripts/manage-hosts.sh --remove
```

### Windows

```powershell
.\scripts\manage-hosts.ps1               # interactive menu
.\scripts\manage-hosts.ps1 -Sync
.\scripts\manage-hosts.ps1 -List
.\scripts\manage-hosts.ps1 -Format
.\scripts\manage-hosts.ps1 -Add -Name N -Ip I -User U -Group prod_machine -SkipConfirm
.\scripts\manage-hosts.ps1 -Remove
```

> **Group must be `dev_machine` or `prod_machine`.** Both scripts validate the input and reject anything else, because an unknown group means no `group_vars/<group>.yml` exists and scope resolution silently breaks. The interactive prompt defaults to `prod_machine`.

The two scripts produce **identical output** for the same `hosts.conf`. After any change to `hosts.conf`, run `--sync` (or `-Sync`) before committing so the inventory and wezterm block stay in lockstep.

> **Don't hand-pad `hosts.conf`** — the save routine recalculates column widths from data, so any manual fixed-width padding gets normalised away on next save.

> **`hosts.conf` is auto-sorted** by group, then by name, on every save (add / edit / remove / format / `bootstrap.sh` self-registration). Manual reordering won't survive the next save. If you want explicit grouping, use the group column.

### Copy SSH key

After a host is registered, you still need your public key in its `~/.ssh/authorized_keys` before WezTerm or Ansible can connect without a password. Both scripts have a `--copy-id` / `-CopyId` command for this.

Linux:
```bash
./scripts/manage-hosts.sh --copy-id --name dev-01        # explicit
./scripts/manage-hosts.sh --copy-id                      # interactive picker
```

Windows:
```powershell
.\scripts\manage-hosts.ps1 -CopyId -Name dev-01          # explicit
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

### chezmoi (Linux or Windows host)

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

### Ansible — remote (control machine → all hosts in inventory)

Scope per host comes from its `group_vars/<group>.yml`. You don't normally pass `tool_scope` / `has_sudo` on the CLI — the group decides.

```bash
cd ansible

# Provision every managed host (both groups). Sudo prompt is for dev_machine hosts.
ansible-playbook playbooks/linux.yml --ask-become-pass

# Only one group
ansible-playbook playbooks/linux.yml --limit dev_machine --ask-become-pass
ansible-playbook playbooks/linux.yml --limit prod_machine

# Single host
ansible-playbook playbooks/linux.yml --limit atc-cache-dev09

# Dry run (show what would change)
ansible-playbook playbooks/linux.yml --check
```

### Ansible — local (self-provisioning, what `bootstrap.sh` runs under the hood)

`bootstrap.sh` loads the relevant group_vars file as extra-vars so the local playbook sees the same scope values that the remote playbook would apply to a host in that group.

```bash
cd ansible

# Prod machine (no sudo)
ansible-playbook playbooks/local.yml -e "@group_vars/prod_machine.yml"

# Dev machine (sudo)
ansible-playbook playbooks/local.yml -e "@group_vars/dev_machine.yml" --ask-become-pass

# Dry run
ansible-playbook playbooks/local.yml --check -e "@group_vars/prod_machine.yml"
```

---

## Adding a new tool

There is **one** place to edit, not two:

1. Add an install task in `ansible/roles/linux-base/tasks/tools.yml`. Use `dest: "{{ tools_dest }}"` and `become: "{{ tools_become }}"` — the role resolves these from `tool_scope`.

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

## Adding a new host

1. On the new host, pick the group with the appropriate flag:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod  # or --dev
   ```
   Self-registration appends the host to `hosts.conf` under `prod_machine` or `dev_machine`.
2. From any other machine with the repo: `git pull` and run `./scripts/manage-hosts.sh --sync` (or `-Sync` on Windows) so `hosts.ini` and the wezterm block update everywhere.
3. Commit and push the updated `hosts.conf`, `hosts.ini`, and `chezmoi/dot_config/wezterm/wezterm.lua`.

---

## Troubleshooting

- **Bootstrap reports "Missing required prerequisites: …".** Install all listed tools at once via your distro's package manager. RHEL/Fedora: `sudo dnf install curl git python3 python3-pip iproute`. Debian/Ubuntu: `sudo apt install curl git python3 python3-pip iproute2`. Bootstrap deliberately collects every gap up front so you only have to install once.
- **Bootstrap fails with "python3 ≥ 3.9 required for ansible-core".** Your distro's `python3` is too old. On RHEL 8: enable a newer module stream (`sudo dnf module install python39`) or install `python3.11` and ensure `python3` resolves to it.
- **Bootstrap fails with "ansible-playbook not on PATH after pip install".** `pip install --user` dropped the binary in `~/.local/bin` but your shell hasn't picked that up yet. Run `export PATH="$HOME/.local/bin:$PATH"` and re-run `./bootstrap.sh`. After this run completes, [shell.yml](ansible/roles/linux-base/tasks/shell.yml) wires the PATH permanently.
- **Bootstrap finishes with "Push failed (auth, conflict, or no upstream)".** Provisioning succeeded — only the host-list push didn't. Recover with `cd ~/.local/share/chezmoi && git push`. Common causes: no SSH key for the git remote, a divergent upstream (`git pull --rebase` first), or you've forked and never set the remote.
- **Private repo: clone fails with "Authentication failed" or 404.** Set `GITHUB_TOKEN` to a PAT with `repo` (classic) or Contents:Read (fine-grained) scope and re-run. The token is written into `.git/config` as `http.https://github.com/.extraheader` so subsequent ops (push, `chezmoi update`, manual `git pull`) all work — re-passing the env var on later runs just refreshes the stored value. To clear it: `git -C ~/.local/share/chezmoi config --unset http.https://github.com/.extraheader`.
- **`./scripts/manage-hosts.sh --copy-id` keeps prompting for a password every connection.** The key landed but `sshd` isn't using it. Check the target's `/etc/ssh/sshd_config` (`PubkeyAuthentication yes`, `AuthorizedKeysFile .ssh/authorized_keys`) and the perms (`~/.ssh` = 700, `~/.ssh/authorized_keys` = 600). On SELinux RHEL: `restorecon -R -v ~/.ssh`.
- **`ssh-keygen` on Windows opens a passphrase prompt despite `-N '""'`.** Some PowerShell quoting variants strip the empty-passphrase argument. Re-run interactively and just press Enter twice; the rest of the flow is unchanged.
- **`ansible-playbook: command not found` after a fresh `bootstrap.sh` run.** Same root cause as above — PATH didn't include `~/.local/bin`. Either `source ~/.bashrc` or run `export PATH="$HOME/.local/bin:$PATH"` and retry.
- **WezTerm shows old config after an edit.** Normally edits to `chezmoi/dot_config/wezterm/wezterm.lua` are visible immediately because `bootstrap.ps1` hardlinks the home path to the chezmoi source. Confirm the link is intact: `fsutil hardlink list "$env:USERPROFILE\.config\wezterm\wezterm.lua"` should list **both** the home path and the repo path. If only the home path appears, the link broke (chezmoi atomic-write, an editor that doesn't preserve hardlinks, or someone deleted and re-created the file). Restore with `.\bootstrap.ps1 -SkipToolInstall -SkipChezmoi -SkipKeyGen` (just runs the hardlink step) — or run the full `bootstrap.ps1`.
- **`bootstrap.ps1` aborts with "Admin required to install: …".** The preflight names exactly which tools are missing and require elevation. Two paths: (a) close the shell, right-click PowerShell → "Run as administrator", re-run; (b) `choco install -y` the named packages yourself in an admin one-shot, then re-run non-elevated with `-SkipToolInstall`. If every tool is already installed and on PATH, the script just notes "All Chocolatey-managed tools already installed" and proceeds without asking for admin.
- **`bootstrap.ps1` says `<Tool> is registered with choco but its binary isn't on PATH — re-installing with --force`.** This is a recoverable warning — choco's local database lists the package as installed but the binary's missing (usually from an interrupted install or someone removing files). The script automatically passes `--force` to reinstall it. If `choco install --force` itself fails, run `choco uninstall <id> -y` then `choco install -y <id>` from an admin shell.
- **`bootstrap.ps1` reports "Chocolatey install completed but `choco` is not on PATH".** The choco installer succeeded but the current shell's PATH wasn't refreshed in time. Close the elevated PowerShell, open a new elevated PowerShell, and re-run — the new session inherits the updated machine PATH and picks up `choco` correctly.
- **A `choco install` step says "package not found" or "deprecated".** Choco package IDs occasionally get renamed/retired upstream. Edit `$ChocoTools` in `bootstrap.ps1` to point at the current ID (search at https://community.chocolatey.org/packages), or set the tool as `Required = $false` so the rest of the install proceeds and install it manually.
- **`hosts.ini` is out of sync with `hosts.conf`.** Run `./scripts/manage-hosts.sh --sync`. Never edit `hosts.ini` directly — it's auto-generated.
- **Bootstrap errored with "Missing required flag: --dev or --prod".** The script no longer has a default scope — exactly one of `--dev` (sudo, system-wide) or `--prod` (no sudo, user-wide) must be passed. The old `--full` flag was removed; if you still have it in a script or paste buffer, replace it with `--dev`.
- **`manage-hosts.{sh,ps1} --add` errored with "Invalid group".** The only valid groups are `dev_machine` and `prod_machine` — anything else means there's no `group_vars/<group>.yml` to source scope from. Re-run with one of those two values (default is `prod_machine`).
- **An Ansible run errored with "tool_scope=system requires has_sudo=true".** A host's `group_vars` and the playbook's CLI overrides disagreed — usually because something passed `-e "tool_scope=system"` against a `prod_machine` host. Drop the `-e` override and let the group decide, or use `--limit dev_machine` to scope the run to hosts that actually have sudo.
