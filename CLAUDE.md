# CLAUDE.md

Guidance for Claude Code working on this repository.

## What this repo is

`workstation` is a self-contained dev-environment-provisioning system. One Git repo manages:
- Multiple **RHEL VMs** (system packages, user-space tools, dotfiles).
- One **Windows host** (WezTerm config that auto-connects to the VMs).

The repo is consumed three ways:
1. **From a RHEL VM** — clone, run `bootstrap.sh`. The script seeds Ansible (via `pip3 install --user ansible-core` if missing), runs `playbooks/local.yml` against the local machine, and self-registers the VM in `hosts.conf`.
2. **From the Windows host** — `bootstrap.ps1` (run from an **elevated** PowerShell) bootstraps Chocolatey, installs tooling via `choco` (chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode), clones the repo, and runs `chezmoi init --apply` to deploy `wezterm.lua`, the PowerShell profile, Zed/VSCode settings, etc. into `%USERPROFILE%\…`. Choco rather than winget because winget's PATH propagation is unreliable mid-session and leaves freshly-installed binaries unresolvable to the next step.
3. **From an ops machine** — run Ansible against multiple VMs at once via `playbooks/rhel.yml`.

## Layered architecture

Two separate provisioning layers, intentionally decoupled:

| Layer | Tool | Where it runs | Needs sudo? |
|---|---|---|---|
| Provisioning | **Ansible** (`ansible/`) | Locally on a VM, or against remote VMs | Optional — controlled by `tool_scope` and `has_sudo` |
| Dotfiles | **chezmoi** (`chezmoi/`) | On each VM as the dev user | No |

Ansible owns **all** installations. `bootstrap.sh` is a thin seed: it clones the repo, installs `ansible-core` via `pip3 --user` if missing, then runs `playbooks/local.yml` against the local machine. There is no duplicate install logic between the script and the role — adding a new tool means editing `tools.yml` (and bumping its version in `group_vars/all.yml`), nothing else.

User-space tools (`fzf`, `zellij`, `helix`, etc.) are **always** installed as static binaries — never via `dnf` — but the **destination** is controlled by the `tool_scope` variable:

| `tool_scope` | Binary destination | Helix runtime | Needs sudo |
|---|---|---|---|
| `user` (default) | `~/.local/bin` | `~/.config/helix/runtime` | No |
| `system` | `/usr/local/bin` | `/usr/local/lib/helix/runtime` | Yes |

`tool_scope=system` requires `has_sudo=true`; the role fails fast with a clear message otherwise. The same task definitions in `tools.yml` cover both scopes via `dest: "{{ tools_dest }}"` + `become: "{{ tools_become }}"`, both resolved in `tasks/main.yml` from `tool_scope`.

## Repo layout

```
workstation/
├── bootstrap.sh                  ← RHEL VM entry point — thin Ansible seed
├── bootstrap.ps1                 ← Windows client entry point — choco tools + chezmoi apply (elevated)
├── .chezmoiroot                  ← contains "chezmoi" — redirects chezmoi's source state to the chezmoi/ subdir
├── hosts.conf                    ← single source of truth for VM list
├── README.md                     ← user-facing setup + daily commands
│
├── scripts/
│   ├── manage-hosts.sh           ← Linux/RHEL host manager
│   └── manage-hosts.ps1          ← Windows host manager (feature-parity)
│
├── ansible/                      ← all provisioning lives here
│   ├── ansible.cfg
│   ├── group_vars/all.yml        ← dev_user, dotfiles_repo, tool versions (single source of truth)
│   ├── inventory/hosts.ini       ← AUTO-GENERATED — never edit
│   ├── playbooks/
│   │   ├── rhel.yml              ← targets remote rhel_vms group (control-machine flow)
│   │   └── local.yml             ← targets localhost (used by bootstrap.sh)
│   └── roles/rhel-base/
│       ├── defaults/main.yml     ← install_*, has_sudo, tool_scope, arch
│       ├── handlers/main.yml
│       └── tasks/
│           ├── main.yml          ← validates + resolves scope vars, then orchestrates
│           ├── packages.yml      ← dnf (sudo)
│           ├── tools.yml         ← static binaries; honors tool_scope (user/system)
│           ├── shell.yml         ← PATH via /etc/profile.d (sudo fallback to ~/.bashrc)
│           └── dotfiles.yml      ← chezmoi init/update --apply (uses tools_dest)
│
└── chezmoi/                      ← chezmoi source state (set by .chezmoiroot at repo root)
    ├── .chezmoi.toml.tmpl        ← prompts for name/email on first init
    ├── .chezmoiignore.tmpl       ← OS-aware: ignores Linux-only on Windows, vice versa
    ├── .chezmoiscripts/
    │   └── run_once_after_init.sh   ← inits ~/notes for nb (Linux only)
    ├── dot_bashrc.tmpl           ← → ~/.bashrc       (Linux)
    ├── dot_gitconfig.tmpl        ← → ~/.gitconfig    (cross-platform)
    ├── dot_nbrc                  ← → ~/.nbrc         (Linux)
    ├── dot_config/               ← → ~/.config/      (cross-platform)
    │   ├── starship.toml
    │   ├── helix/config.toml
    │   ├── zellij/{config.kdl, layouts/dev.kdl}
    │   └── wezterm/wezterm.lua   ← was at repo root; chezmoi-managed since the wezterm-migration commit
    ├── AppData/                  ← → %USERPROFILE%\AppData\… (Windows only)
    │   └── Roaming/
    │       ├── Zed/settings.json
    │       └── Code/User/{settings.json, keybindings.json}
    └── Documents/                ← → %USERPROFILE%\Documents\… (Windows only)
        ├── PowerShell/Microsoft.PowerShell_profile.ps1.tmpl       ← PS 7 profile
        └── WindowsPowerShell/Microsoft.PowerShell_profile.ps1     ← PS 5.1 stub, dot-sources PS 7
```

## hosts.conf is the single source of truth

`hosts.conf` lists VMs. Format: 4 whitespace-separated columns — `name  ip  user  group`. Comments (`#`) are preserved at the top of the file. **Both manage-hosts scripts re-pad column widths dynamically on every save** — never hand-pad to fixed widths.

`hosts.conf` is the only file you edit. Two outputs are regenerated from it:

| Output | Generated by | Marker |
|---|---|---|
| `ansible/inventory/hosts.ini` | full overwrite, banner at top | `# AUTO-GENERATED by scripts/manage-hosts.{sh,ps1}` |
| `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block | in-place replace between sentinels | `-- HOSTS:START` / `-- HOSTS:END` |

### Host management commands

Linux:
```bash
./scripts/manage-hosts.sh                # interactive menu
./scripts/manage-hosts.sh --sync         # regenerate inventory + wezterm block
./scripts/manage-hosts.sh --list         # print table
./scripts/manage-hosts.sh --format       # re-pad hosts.conf
./scripts/manage-hosts.sh --add --name N --ip I --user U --group G --skip-confirm
./scripts/manage-hosts.sh --remove
./scripts/manage-hosts.sh --copy-id --name N    # copy ~/.ssh/id_ed25519.pub to host N
```

Windows (feature-equivalent):
```powershell
.\scripts\manage-hosts.ps1
.\scripts\manage-hosts.ps1 -Sync
.\scripts\manage-hosts.ps1 -List
.\scripts\manage-hosts.ps1 -Format
.\scripts\manage-hosts.ps1 -Add -Name N -Ip I -User U -Group G -SkipConfirm
.\scripts\manage-hosts.ps1 -Remove
.\scripts\manage-hosts.ps1 -CopyId -Name N      # copy %USERPROFILE%\.ssh\id_ed25519.pub
```

`--copy-id` / `-CopyId`: looks up the host in `hosts.conf`, prompts to generate `~/.ssh/id_ed25519` (passphrase-less) if missing, then either uses native `ssh-copy-id` (Linux) or emulates it via `ssh user@host "mkdir -p ~/.ssh && cat >> authorized_keys && ..."` (Windows OpenSSH ships no `ssh-copy-id`). Successful `--add` prints a tip line pointing at this command.

The two scripts produce **the same output** for the same `hosts.conf`. The banner in `ansible/inventory/hosts.ini` records which one regenerated it last (handy when debugging line-ending or formatting drift).

### Wezterm sentinel mechanism

The wezterm sync replaces only the block between two sentinel comments in the chezmoi-tracked source file at `chezmoi/dot_config/wezterm/wezterm.lua`:

```lua
-- HOSTS:START
local ssh_domains = { ... }
-- HOSTS:END
```

Both sentinels must be present at column 0. The bash script uses `awk` to print everything outside the sentinels unchanged and substitute a freshly generated `local ssh_domains = { ... }` block between them; the PowerShell script does the equivalent with a `(?s)-- HOSTS:START.*?-- HOSTS:END` regex. If the sentinels are removed, bash silently no-ops and PowerShell prints a warning and skips — the rest of the file (keybinds, appearance, etc.) is never touched by sync, so it's safe to edit anywhere outside the sentinel block.

## bootstrap.sh

A thin seed that delegates everything to Ansible. Two modes, picked from `$1`:

### `--full` (system scope, requires sudo)
Runs:
```
ansible-playbook playbooks/local.yml -e "tool_scope=system has_sudo=true" --ask-become-pass
```
Installs `dnf` packages and writes static binaries to `/usr/local/bin`.

### Default / `user` mode (no sudo)
Runs:
```
ansible-playbook playbooks/local.yml -e "tool_scope=user has_sudo=false install_system_packages=false"
```
Installs only the user-space tools to `~/.local/bin`.

### Common steps for both modes (in order)
1. **Preflight**: collect-all check for `curl`, `git`, `python3`, `python3 -m pip`, and `ip` (iproute) — reports every missing tool in one message rather than one at a time. Verifies `python3 ≥ 3.9` (ansible-core's floor) and that `python3 -m pip` works.
2. **Clone the repo** to `$HOME/.local/share/chezmoi` if not present (or `git pull --ff-only` if it is). If `GITHUB_TOKEN` is set in env, the script passes it via `git -c http.https://github.com/.extraheader=Authorization: bearer …` for the clone, and persists the same key into the cloned repo's `.git/config`. That single token then covers all subsequent git ops in this script (push), in Ansible (`chezmoi update`), and any manual `git pull`/`git push` the user runs in the repo. The header key is github.com-scoped, so the token never leaks to other remotes. To clear: `git config --unset http.https://github.com/.extraheader` in the repo.
3. **Self-registration** (now happens *before* Ansible runs): invokes `manage-hosts.sh --add` with detected `hostname -s` + IP from `ip route get 1.1.1.1` (fallback `ip addr`) + `whoami` + group `rhel_vms`. `--skip-confirm` is passed; if the host already exists the call returns silently. Then runs `manage-hosts.sh --sync` so the inventory and wezterm block are regenerated locally before the playbook runs (any chezmoi/Ansible logic that consumes `hosts.conf` sees the current list).
4. **Install `ansible-core`** via `pip3 install --user --upgrade ansible-core` if `ansible-playbook` is not on PATH. After install, smoke-tests with `ansible-playbook --version` to fail fast if `~/.local/bin` isn't actually picked up.
5. **Run the local playbook** with the mode-appropriate `-e` overrides.
6. **Auto-commit + push** the host-list changes (`hosts.conf`, `ansible/inventory/hosts.ini`, `chezmoi/dot_config/wezterm/wezterm.lua`) with the message `chore(hosts): register <hostname>`. Identity priority for the commit: `GIT_USER_NAME` / `GIT_USER_EMAIL` env vars (highest — set in the bootstrap one-liner) → existing `git config user.name`/`user.email` (e.g. from a chezmoi-applied `~/.gitconfig`) → synthetic `whoami@hostname` fallback so the commit never fails outright. Warn-don't-fail on every error: if the commit or push fails (auth, conflict, no upstream), bootstrap prints the recovery `git push` command but does NOT abort. The playbook already succeeded by this point.

Both modes are idempotent. Tool versions and install logic live entirely in Ansible — `bootstrap.sh` has no per-tool knowledge.

The reordering is load-bearing: anything in Ansible/chezmoi that grows to read `hosts.conf` will see the new VM. Don't move self-registration back to "after the playbook" without explicit reason.

## Tool versions — single source of truth

All tool versions live in `ansible/group_vars/all.yml` (`fzf_version`, `zoxide_version`, `starship_version`, `zellij_version`, `glow_version`, `helix_version`, `chezmoi_version`). `bootstrap.sh` contains no version pins — it just hands off to Ansible. To bump a tool, edit one file. To add a new tool, add an install task in `ansible/roles/rhel-base/tasks/tools.yml` and the corresponding `<name>_version` variable in `group_vars/all.yml`.

The historical `bootstrap.sh` `*_VERSION` constants have been removed; do not re-introduce per-tool variables to the shell script.

## Ansible role: `rhel-base`

Single role, four task files orchestrated by `tasks/main.yml`. Before any task imports run, `main.yml` validates `tool_scope` vs `has_sudo` and resolves three computed facts (`tools_dest`, `tools_become`, `helix_runtime_dest`) for downstream tasks to consume:

```yaml
- fail: msg=...   when: tool_scope == 'system' and not has_sudo
- set_fact: tools_dest, tools_become, helix_runtime_dest   # resolved from tool_scope
- import_tasks: packages.yml   when: install_system_packages and has_sudo   become: true
- import_tasks: tools.yml      when: install_user_tools
- import_tasks: shell.yml      # always
- import_tasks: dotfiles.yml   when: apply_dotfiles
```

Defaults from `roles/rhel-base/defaults/main.yml`:
- `install_system_packages: true`
- `install_user_tools: true`
- `apply_dotfiles: true`
- `has_sudo: true`
- `tool_scope: user`
- `arch: "x86_64"`
- `linux_target: "unknown-linux-musl"`

Override via `-e` to change scope or skip steps, e.g.:
- `-e "tool_scope=system has_sudo=true"` — system-wide install to `/usr/local/bin`
- `-e "tool_scope=user has_sudo=false install_system_packages=false"` — pure user-space, no sudo
- `-e "install_user_tools=false"` — dotfiles only

`tools.yml` uses `dest: "{{ tools_dest }}"` and `become: "{{ tools_become }}"` on every install task, so a single set of task definitions covers both scopes. The Helix runtime is the one special case — it goes to `helix_runtime_dest`, which is `~/.config/helix/runtime` for user scope and `/usr/local/lib/helix/runtime` for system scope (both are paths Helix searches by default).

`shell.yml` writes PATH to `/etc/profile.d/local-bin.sh` when `has_sudo`, otherwise `lineinfile`-appends `export PATH=...` to `~/.bashrc`. `dotfiles.yml` checks for an existing `chezmoi_source/.git` to decide between `chezmoi init --apply` and `chezmoi update`, and finds the `chezmoi` binary via `tools_dest` (so it works with either scope).

## chezmoi source layout & templating

- The chezmoi *source state* is the `chezmoi/` subdirectory of this repo. It's redirected there from the cloned repo root by **`.chezmoiroot`** at the repo root (a one-line file containing `chezmoi`). Without `.chezmoiroot` chezmoi treats the repo root as the source state, which would map `chezmoi/dot_bashrc.tmpl` to `~/chezmoi/.bashrc` (literal, broken) instead of `~/.bashrc`.
- Naming conventions (relative to `chezmoi/`):
  - `dot_X` → `~/.X` (e.g. `dot_bashrc.tmpl` → `~/.bashrc`).
  - `dot_config/X` → `~/.config/X` (cross-platform; chezmoi resolves `~/` to `%USERPROFILE%\` on Windows).
  - `AppData/Roaming/X/file` → `%USERPROFILE%\AppData\Roaming\X\file` (Windows-only by ignore rule).
  - `Documents/PowerShell/X` → `%USERPROFILE%\Documents\PowerShell\X` (Windows-only).
  - Trailing `.tmpl` triggers Go-template rendering.
  - `.chezmoiscripts/run_once_after_init.sh` runs once after first `chezmoi apply`; rename to re-run on a new VM.
- Cross-platform OS gating is in `.chezmoiignore.tmpl`. On Windows it ignores Linux-only files (`dot_bashrc.tmpl`, `dot_nbrc`, `dot_config/helix`, `dot_config/zellij`, `.chezmoiscripts/run_once_after_init.sh`); on Linux it ignores Windows-only paths (`AppData`, `Documents`, `dot_config/wezterm`). Per-machine override files (`dot_bashrc.local`, PowerShell `*.local.ps1` variants) are always ignored.
- Variables available in templates:
  - `{{ .name }}`, `{{ .email }}` — populated by `promptStringOnce` in `.chezmoi.toml.tmpl` on first init.
  - `{{ .chezmoi.hostname }}`, `{{ .chezmoi.username }}`, `{{ .chezmoi.os }}` — built-in.
- Per-machine overrides:
  - **Linux**: `~/.bashrc.local` — un-tracked, sourced last by `dot_bashrc.tmpl` if present.
  - **Windows**: `Microsoft.PowerShell_profile.local.ps1` next to the main profile — un-tracked, dot-sourced last by the templated profile.
- `dot_bashrc.tmpl` ends with a hostname-templated block (currently a `PROJECT_ROOT` switch on `rhel-dev-01`) before the `.bashrc.local` source. The Windows PS profile applies the same pattern.

## README.md must mirror user-facing changes

`README.md` is reference material the user runs against — setup commands, daily workflows, scope flags, file locations. **Whenever you change something the user needs to know or maintain, update `README.md` in the same change**, with concrete usage examples (a copyable command block, not just prose).

This includes:
- Setup or install steps (new prerequisite, changed entry point, renamed flag).
- Daily-workflow surface (new `manage-hosts.sh` flag, new playbook, new chezmoi alias).
- Variables the user is expected to override (`tool_scope`, `has_sudo`, anything in `defaults/main.yml`).
- File locations the user reads/writes (`hosts.conf`, `~/.bashrc.local`, `chezmoi/home/`, hardlink target).
- New tool added — at minimum, mention it in the Stack table; if it has end-user CLI surface, show it.
- Deprecations or removals — don't leave stale instructions in README pointing at removed flags or files.

This does NOT include:
- Internal Ansible task refactors that don't change CLI overrides or file locations.
- Comment edits, formatting changes, variable renames invisible from outside the role.
- Bumping a tool version — `group_vars/all.yml` is the source of truth, README doesn't pin versions.

When in doubt, ask: "Would a user reading only README.md still be able to set up and operate this repo correctly after my change?" If no, update README.

### Worked examples

| Change | README update? | What to add |
|---|---|---|
| Added `tool_scope=system` support | **Yes** | Install scopes table + `-e "tool_scope=system"` example under Daily Ansible workflow |
| Renamed `manage-hosts.sh --sync` to `--regen` | **Yes** | Replace every command example, add a one-line "renamed from `--sync`" note for one release |
| Added `direnv` to `tools.yml` + `direnv_version` | **Yes** | Add `direnv` to Stack table; show how `tool_scope` controls its destination |
| Bumped `fzf_version: 0.54.0` → `0.55.0` | No | Versions live in `group_vars/all.yml` only |
| Refactored `tasks/tools.yml` to deduplicate the helix block | No | No CLI surface changed |
| Added a new optional `-e "ansible_python_interpreter=..."` override | **Yes** | Add a "When to set this" note under Daily Ansible workflow |
| Added a wezterm keybind (e.g. `CTRL+SHIFT+H` cheatsheet) | **Yes** | Mention it under the Windows section so users know it exists |
| Added `--copy-id` / `-CopyId` to manage-hosts | **Yes** | New "Copy SSH key" subsection with both shells + a tip line in the post-bootstrap message |
| Reordered `bootstrap.sh` flow (self-register before Ansible) | **Yes** | Setup section explains the new order and the auto-commit+push step |
| Added `GITHUB_TOKEN` + `GIT_USER_NAME` + `GIT_USER_EMAIL` env-var support to `bootstrap.sh` | **Yes** | Setup section shows the labelled per-machine one-liner, the env-var purpose table, and a troubleshooting entry for clone-failure recovery. Token kept as `<your-PAT>` placeholder; identity values can be concrete to your real setup since the repo is single-user. |
| Added `bootstrap.ps1` for the Windows client side | **Yes** | Setup → On Windows section shows the `irm \| iex` one-liner with `$env:GITHUB_TOKEN`, calls out that it must run elevated, lists the five-step flow (preflight → choco install → clone → chezmoi apply → ssh-key), and documents the flags. |
| Switched bootstrap.ps1 from winget to Chocolatey | **Yes** | "WHY CHOCOLATEY" rationale stays in the script's header for future-me; README needs the elevated-shell note and the package IDs (which differ from winget's). |
| Made the chezmoi source state cross-platform (added `.chezmoiroot`, OS-aware `.chezmoiignore.tmpl`, Windows AppData/Documents paths, migrated `wezterm.lua` under chezmoi) | **Yes** | New "chezmoi cross-platform" subsection under Setup → On Windows; updated repo-structure tree; "Editing dotfiles" workflow gets `cza`/`czd`/`cze` alias mentions for Windows. |
| Internal `set_fact` rename inside `main.yml` | No | Invisible from outside |

## Conventions and rules of thumb

- **Never edit `ansible/inventory/hosts.ini` by hand.** Edit `hosts.conf` and run `--sync`.
- **Never edit the wezterm SSH-domains block by hand** between the sentinel comments — it gets clobbered on the next sync.
- **Don't fixed-width-pad `hosts.conf`.** The save routine recalculates widths from data; manual padding gets normalised.
- **`scripts/manage-hosts.sh` and `scripts/manage-hosts.ps1` are a parity pair.** Every user-visible capability — flags, menu options, prompts, default values, post-add flow, output glyphs — MUST exist in both. When you change one, change the other in the same commit. The two scripts produce identical output for the same `hosts.conf`; that invariant is load-bearing because either side regenerates `inventory/hosts.ini` and the wezterm sentinel block. Drift between them silently breaks reproducibility across Linux/Windows.
- **All tool installs live in Ansible (`tasks/tools.yml`).** Never re-introduce per-tool install logic or version pins in `bootstrap.sh` — adding a tool there creates exactly the kind of drift this layout was rebuilt to eliminate. The shell script is a seed, nothing more.
- **Tool versions live only in `ansible/group_vars/all.yml`.** One file, one bump.
- **The chezmoi source dir is `chezmoi/`**, not the repo root. New dotfiles go under `chezmoi/home/` or `chezmoi/dot_config/`.
- **Per-machine overrides go in `~/.bashrc.local` on each VM** — un-tracked, sourced last by the templated bashrc.
- **`wezterm.lua` is chezmoi-managed** at `chezmoi/dot_config/wezterm/wezterm.lua` — edits in the repo, `chezmoi apply` to deploy. The previous repo↔home hardlink approach is gone (it had an atomic-save fragility); chezmoi writes a regular file at `%USERPROFILE%\.config\wezterm\wezterm.lua`.
- **User-facing changes get mirrored into `README.md`** in the same commit (see the section above for what counts).

## Daily workflows

Dotfiles (on a VM):
```bash
cze ~/.bashrc       # edit
cza                 # apply locally
czd                 # diff
czu                 # pull and apply
czs                 # status
# Push back:
cd ~/.local/share/chezmoi && git add -A && git commit -m "..." && git push
```

Ansible — remote (control machine, targets all `rhel_vms`):
```bash
cd ansible
ansible-playbook playbooks/rhel.yml --ask-become-pass
ansible-playbook playbooks/rhel.yml --limit <name> --ask-become-pass
ansible-playbook playbooks/rhel.yml --check                                          # dry run
ansible-playbook playbooks/rhel.yml -e "tool_scope=system" --ask-become-pass         # system-wide install
ansible-playbook playbooks/rhel.yml -e "has_sudo=false install_system_packages=false" # dotfiles + user tools only
```

Ansible — local (self-provisioning, used by `bootstrap.sh`):
```bash
cd ansible
ansible-playbook playbooks/local.yml -e "tool_scope=user has_sudo=false install_system_packages=false"
ansible-playbook playbooks/local.yml -e "tool_scope=system has_sudo=true" --ask-become-pass
```

Adding a VM:
1. On the new VM: `git clone … && ./bootstrap.sh` (or `--full`). Self-registration appends to `hosts.conf`.
2. From the Windows host or another machine, `git pull` and run `--sync` (or commit and push from the VM, then pull elsewhere) so the inventory and `chezmoi/dot_config/wezterm/wezterm.lua` block update. On Windows, also run `chezmoi apply` (or the `cza` alias) to push the new wezterm config into `%USERPROFILE%\.config\wezterm\`.

Adding a tool:
1. Add an install task in `ansible/roles/rhel-base/tasks/tools.yml` using `dest: "{{ tools_dest }}"` and `become: "{{ tools_become }}"`.
2. Add `<name>_version: "X.Y.Z"` to `ansible/group_vars/all.yml`.
3. If the tool has user-facing CLI surface, mention it in `README.md` (see "README.md must mirror user-facing changes").

## Files Claude should be careful with

- `ansible/inventory/hosts.ini` — auto-gen, never edit.
- `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block — auto-gen between `-- HOSTS:START` / `-- HOSTS:END` sentinels by both manage-hosts scripts. Edit anywhere outside the sentinels freely.
- `hosts.conf` — edit via the manage-hosts scripts when possible; manual edits work but lose dynamic padding (and sort order) until next save.
- `.chezmoiroot` — one-line file at the repo root containing `chezmoi`. Required for chezmoi's source state to point at the `chezmoi/` subdirectory; without it, all `dot_*` paths break. Don't delete or edit.
- `bootstrap.sh` — keep it a thin seed. It must NOT contain per-tool versions or install logic. Tool versions live only in `ansible/group_vars/all.yml`; install logic lives only in `ansible/roles/rhel-base/tasks/tools.yml`.
- `chezmoi/.chezmoiignore.tmpl` — wrong entries here cause `chezmoi apply` to drop infrastructure files into `$HOME` (or to skip files you wanted applied). Edit-then-test: `chezmoi diff` on a sandbox VM/Windows machine before pushing.
- `scripts/manage-hosts.ps1` and `bootstrap.ps1` **must remain UTF-8 with BOM**. PowerShell 5.1 (Windows PowerShell, the default `powershell.exe`) reads scripts as Windows-1252 unless a BOM is present, and both files contain Unicode glyphs (`✓`, `✗`, `─`) used in colored output. Without the BOM, PS 5.1 mis-decodes the multi-byte UTF-8 and the script fails to parse with cryptic "string missing terminator" errors. To restore the BOM after a tool overwrites it: `[System.IO.File]::WriteAllText($path, [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path)), [System.Text.UTF8Encoding]::new($true))`.
- `scripts/manage-hosts.sh` **must remain LF-only**. The Edit/Write tools on Windows tend to save with CRLF; the resulting file runs but `read -r` then leaks `\r` into parsed fields, polluting the inventory. After any edit, verify with `file scripts/manage-hosts.sh` (expect "Bourne-Again shell script", no "with CRLF line terminators"). Repair with `sed -i 's/\r$//' scripts/manage-hosts.sh`.

## Quick verification

After changes:
- `./scripts/manage-hosts.sh --sync` — regenerates inventory + the chezmoi-tracked wezterm block, no errors.
- `cd ansible && ansible-playbook playbooks/rhel.yml --check` — dry-run on all VMs.
- `cd ansible && ansible-playbook playbooks/local.yml --check -e "tool_scope=user has_sudo=false install_system_packages=false"` — dry-run the local playbook in user scope.
- `chezmoi diff` on a VM (or Windows machine) — shows pending dotfile changes, no surprises. On Windows, the diff should mention only Windows-targeted paths (AppData, Documents, dot_config/wezterm); on Linux only Linux-targeted paths (dot_bashrc, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc).
- `bootstrap.sh` on a fresh VM — completes both modes idempotently.
- `bootstrap.ps1` on a fresh Windows machine (from an **elevated** PowerShell) — choco bootstraps itself, the seven tracked tools install, chezmoi applies, wezterm picks up the deployed config.
- `git diff README.md` — verify the user-facing surface still matches reality.
