# CLAUDE.md

Guidance for Claude Code working on this repository.

## What this repo is

`workstation` is a self-contained dev-environment-provisioning system. One Git repo manages:
- Multiple **Linux hosts** in two flavours: `dev_machine` (hosts you own, sudo, system-wide installs) and `prod_machine` (hosts you don't fully own, no sudo, user-wide installs).
- One **Windows host** (WezTerm config that auto-connects to the Linux hosts).

The repo is consumed three ways:
1. **From a Linux host** — clone, run `bootstrap.sh --dev` or `bootstrap.sh --prod`. The script seeds Ansible (via `pip3 install --user ansible-core` if missing), runs `playbooks/local.yml` with `-e "@group_vars/<group>.yml"`, and self-registers the host in `hosts.conf` under the chosen group.
2. **From the Windows host** — `bootstrap.ps1` (run from an **elevated** PowerShell) bootstraps Chocolatey, installs tooling via `choco` (chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode), clones the repo, and runs `chezmoi init --apply` to deploy `wezterm.lua`, the PowerShell profile, Zed/VSCode settings, etc. into `%USERPROFILE%\…`. Choco rather than winget because winget's PATH propagation is unreliable mid-session and leaves freshly-installed binaries unresolvable to the next step.
3. **From an ops machine** — run Ansible against every managed host at once via `playbooks/linux.yml` (targets `dev_machine:prod_machine`).

## Layered architecture

Two separate provisioning layers, intentionally decoupled:

| Layer | Tool | Where it runs | Needs sudo? |
|---|---|---|---|
| Provisioning | **Ansible** (`ansible/`) | Locally on a host, or against remote hosts | Optional — controlled by `tool_scope` and `has_sudo` |
| Dotfiles | **chezmoi** (`chezmoi/`) | On each host as the dev user | No |

Ansible drives **provisioning** but delegates **tool installs** to a parallel Makefile under `scripts/install/`. `bootstrap.sh` is a thin seed: it clones the repo, installs `ansible-core` via `pip3 --user` if missing, then runs `playbooks/local.yml`. The playbook handles dnf packages, PATH setup, chezmoi orchestration — and for static-binary tool installs (the ~55 things that used to be per-tool `unarchive`/`get_url` blocks in `tools.yml`), it calls `make -j8 all` inside `scripts/install/`. That Makefile is now the single source of truth for tool versions, URLs, and per-tool quirks. Adding a new tool means editing two lines (`scripts/install/versions.mk` + `scripts/install/tools.mk`), nothing else.

User-space tools (`fzf`, `zellij`, `helix`, etc.) are **always** installed as static binaries — never via `dnf` — but the **destination** is controlled by the `tool_scope` variable, which is set per host from its group_vars file:

| Group | `tool_scope` | `has_sudo` | `install_system_packages` | Binary destination | Helix runtime |
|---|---|---|---|---|---|
| `dev_machine` | `system` | `true` | `true` | `/usr/local/bin` | `/usr/local/lib/helix/runtime` |
| `prod_machine` | `user` | `false` | `false` | `~/.local/bin` | `~/.config/helix/runtime` |

The values live in `ansible/group_vars/{dev,prod}_machine.yml` — single source of truth. The remote `linux.yml` playbook picks them up automatically per host; `bootstrap.sh` loads the same file via `-e "@group_vars/<group>.yml"` for the local self-provisioning run.

`tool_scope=system` requires `has_sudo=true`; the role fails fast with a clear message otherwise. `tools.yml` is now a thin shim that invokes `make -j8 all` in `scripts/install/` with `DEST={{ tools_dest }}` and `become: "{{ tools_become }}"` — the same Makefile handles both scopes by reading `DEST` from the environment. Helix's runtime tree is handled by passing `HELIX_RUNTIME_DEST` separately (helix is the only tool that lays down more than just a binary).

## Repo layout

```
workstation/
├── bootstrap.sh                  ← Linux host entry point — thin Ansible seed
├── bootstrap.ps1                 ← Windows client entry point — choco tools + chezmoi apply (elevated)
├── .chezmoiroot                  ← contains "chezmoi" — redirects chezmoi's source state to the chezmoi/ subdir
├── hosts.conf                    ← single source of truth for host list
├── README.html                   ← user-facing setup + daily commands (structural HTML; loads README.css + README.js as siblings)
├── README.css                    ← all styles for README.html (theme tokens at the top)
├── README.js                     ← behavior for README.html (theme toggle, scroll-spy TOC, search, filter UIs)
│
├── scripts/
│   ├── manage-hosts.sh           ← Linux host manager
│   ├── manage-hosts.ps1          ← Windows host manager (feature-parity)
│   └── install/                  ← Makefile-driven tool installer (called from tools.yml)
│       ├── Makefile              ← orchestration + TOOL/USER_TOOL macros + phony targets
│       ├── versions.mk           ← single source of truth for tool versions
│       ├── tools.mk              ← per-tool install rules (one $(eval $(call ...)) line each)
│       └── lib/
│           ├── archive.sh        ← curl + extract + find-and-install (tar.gz/bz2/xz/zip)
│           ├── direct.sh         ← curl + chmod for raw binary URLs
│           ├── pipe.sh           ← curl-piped upstream installers (chezmoi, claude)
│           ├── pip.sh            ← pip install --user wrapper
│           └── helix.sh          ← multi-file: binary + runtime/ tree (special-cased)
│
├── ansible/                      ← provisioning + dotfiles orchestration
│   ├── ansible.cfg
│   ├── group_vars/
│   │   ├── all.yml               ← dev_user, dotfiles_repo, system-package lists
│   │   ├── dev_machine.yml       ← scope vars for sudo/system-wide hosts (tool_scope=system, has_sudo=true)
│   │   └── prod_machine.yml      ← scope vars for no-sudo/user-wide hosts (tool_scope=user, has_sudo=false)
│   ├── inventory/hosts.ini       ← AUTO-GENERATED — never edit
│   ├── playbooks/
│   │   ├── linux.yml             ← targets dev_machine:prod_machine (control-machine flow)
│   │   └── local.yml             ← targets localhost (used by bootstrap.sh; loads group_vars via -e "@...")
│   └── roles/linux-base/
│       ├── defaults/main.yml     ← install_*, has_sudo, tool_scope, arch
│       ├── handlers/main.yml
│       └── tasks/
│           ├── main.yml          ← validates + resolves scope vars, then orchestrates
│           ├── packages.yml      ← dnf (sudo)
│           ├── tools.yml         ← thin wrapper: `make -C scripts/install all/user-tools/claude-cli`
│           ├── shell.yml         ← PATH via /etc/profile.d (sudo fallback to ~/.bashrc)
│           └── dotfiles.yml      ← chezmoi init/update --apply (uses tools_dest)
│
└── chezmoi/                      ← chezmoi source state (set by .chezmoiroot at repo root)
    ├── .chezmoi.toml.tmpl        ← prompts for name/email on first init
    ├── .chezmoiignore.tmpl       ← OS-aware: ignores Linux-only on Windows, vice versa
    ├── .chezmoiscripts/
    │   └── run_once_after_init.sh.tmpl   ← inits ~/notes for nb (Linux only — renders empty on Windows)
    ├── dot_bashrc.tmpl           ← → ~/.bashrc       (Linux)
    ├── dot_gitconfig.tmpl        ← → ~/.gitconfig    (cross-platform)
    ├── dot_nbrc                  ← → ~/.nbrc         (Linux)
    ├── private_dot_ssh/          ← → ~/.ssh/         (cross-platform, 0700)
    │   └── private_config        ← → ~/.ssh/config   (0600; keepalives + Include config.local)
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

`hosts.conf` lists hosts. Format: 4 whitespace-separated columns — `name  ip  user  group`. Comments (`#`) are preserved at the top of the file. **Both manage-hosts scripts re-pad column widths dynamically on every save** — never hand-pad to fixed widths.

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
./scripts/manage-hosts.sh --copy-id --all       # copy to every host in hosts.conf (prompts confirm)
./scripts/manage-hosts.sh --copy-id --all --skip-confirm   # bulk, scripted (no prompt)
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
.\scripts\manage-hosts.ps1 -CopyId -All         # bulk copy to every host (prompts confirm)
.\scripts\manage-hosts.ps1 -CopyId -All -SkipConfirm
```

`--copy-id` / `-CopyId`: looks up the host in `hosts.conf`, prompts to generate `~/.ssh/id_ed25519` (passphrase-less) if missing, then either uses native `ssh-copy-id` (Linux) or emulates it via `ssh user@host "mkdir -p ~/.ssh && cat >> authorized_keys && ..."` (Windows OpenSSH ships no `ssh-copy-id`). Successful `--add` prints a tip line pointing at this command. The `--all` / `-All` variant loops over every host in `hosts.conf`, calls `ensure_ssh_key` (the keygen prompt) exactly once up front, then per-host prints `name (user@ip)... ✓` or `✗` and ends with an `N successful / M failed` summary. The loop is deliberately best-effort — partial success is normal (one host offline, password fatigue, etc.) — so it exits 0 even with failures. Pair with `--skip-confirm` / `-SkipConfirm` for scripted bulk runs.

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

A thin seed that delegates everything to Ansible. Exactly one of `--dev` or `--prod` is required — it decides both the group this host registers as AND the scope the local playbook runs in. No default — the choice is too load-bearing to silently fall through.

### `--dev` (dev_machine, sudo, system scope)
Runs:
```
ansible-playbook playbooks/local.yml -e "@group_vars/dev_machine.yml" --ask-become-pass
```
Installs `dnf` packages and writes static binaries to `/usr/local/bin`. Self-registers as `dev_machine`.

### `--prod` (prod_machine, no sudo, user scope)
Runs:
```
ansible-playbook playbooks/local.yml -e "@group_vars/prod_machine.yml"
```
Installs only the user-space tools to `~/.local/bin`. Skips dnf. Self-registers as `prod_machine`.

The scope values are not hardcoded in `bootstrap.sh` — they come from the same `ansible/group_vars/<group>.yml` file the remote `linux.yml` playbook uses, so a host configured locally and a host configured remotely end up identical. Keep that DRY: when scope semantics change, edit only the group_vars file; `bootstrap.sh` picks it up automatically.

### Common steps for both modes (in order)
1. **Preflight**: collect-all check for `curl`, `git`, `python3`, `python3 -m pip`, and `ip` (iproute) — reports every missing tool in one message rather than one at a time. Verifies `python3 ≥ 3.9` (ansible-core's floor) and that `python3 -m pip` works.
2. **Clone the repo** to `$HOME/.local/share/chezmoi` if not present (or `git pull --ff-only` if it is). If `GITHUB_TOKEN` is set in env, the script passes it via `git -c http.https://github.com/.extraheader=Authorization: bearer …` for the clone, and persists the same key into the cloned repo's `.git/config`. That single token then covers all subsequent git ops in this script (push), in Ansible (`chezmoi update`), and any manual `git pull`/`git push` the user runs in the repo. The header key is github.com-scoped, so the token never leaks to other remotes. To clear: `git config --unset http.https://github.com/.extraheader` in the repo.
3. **Self-registration** (now happens *before* Ansible runs): invokes `manage-hosts.sh --add` with detected `hostname -s` + IP from `ip route get 1.1.1.1` (fallback `ip addr`) + `whoami` + group `${MACHINE_TYPE}_machine` (i.e. `dev_machine` or `prod_machine` based on the flag). `--skip-confirm` is passed; if the host already exists the call returns silently. Then runs `manage-hosts.sh --sync` so the inventory and wezterm block are regenerated locally before the playbook runs (any chezmoi/Ansible logic that consumes `hosts.conf` sees the current list). **Auto-skipped inside WSL** — `is_wsl()` (checks `$WSL_DISTRO_NAME` and `/proc/version`'s microsoft marker) short-circuits this step because WSL distros are reached via wezterm WSL domains, not SSH; registering them would pollute `hosts.conf` with a WSL-internal IP and duplicate the WSL domain as an SSH-domain entry in `wezterm.lua`.
4. **Install `ansible-core`** via `pip3 install --user --upgrade ansible-core` if `ansible-playbook` is not on PATH. After install, smoke-tests with `ansible-playbook --version` to fail fast if `~/.local/bin` isn't actually picked up.
5. **Run the local playbook** with `-e "@group_vars/${GROUP_NAME}.yml"`. The playbook prints a colored **PLAY RECAP legend** afterwards explaining each count (ok/changed/failed/skipped/unreachable/rescued/ignored) — printed on both success and failure, then exit code is preserved.
5b. **Ensure chezmoi is initialized** — if `~/.config/chezmoi/chezmoi.toml` doesn't exist (first-ever bootstrap on this host), runs `chezmoi init --apply --source $CHEZMOI_SOURCE </dev/tty` interactively. The `</dev/tty` redirect is load-bearing: under `curl … | bash` the script's own stdin is the curl pipe, so `chezmoi`'s `promptStringOnce` calls for name/email would otherwise read EOF and fail. Ansible can't do this — its `command` module has no TTY — which is why the corresponding `dotfiles.yml` task is gated on the config existing and runs only `chezmoi update` (pull + apply), never `init`.
6. **Auto-commit + push** the host-list changes (`hosts.conf`, `ansible/inventory/hosts.ini`, `chezmoi/dot_config/wezterm/wezterm.lua`) with the message `chore(hosts): register <hostname>`. Identity priority for the commit: `GIT_USER_NAME` / `GIT_USER_EMAIL` env vars (highest — set in the bootstrap one-liner) → existing `git config user.name`/`user.email` (e.g. from a chezmoi-applied `~/.gitconfig`) → synthetic `whoami@hostname` fallback so the commit never fails outright. Warn-don't-fail on every error: if the commit or push fails (auth, conflict, no upstream), bootstrap prints the recovery `git push` command but does NOT abort. The playbook already succeeded by this point. **No-op inside WSL** — since `self_register` was skipped, none of the host-list files changed and the existing `git diff --quiet` guard at the top of `push_host_changes` returns early.

Both modes are idempotent. Tool versions and install logic live entirely in Ansible — `bootstrap.sh` has no per-tool knowledge.

`--full` was removed when `--dev`/`--prod` landed. The script gives a clear error if anyone passes `--full` so old paste-buffer one-liners fail loudly instead of silently doing the wrong thing.

The reordering is load-bearing: anything in Ansible/chezmoi that grows to read `hosts.conf` will see the new host. Don't move self-registration back to "after the playbook" without explicit reason.

### Running inside WSL

WSL distros are supported as managed hosts (tools + dotfiles) but NOT as SSH targets. `bootstrap.sh` defines `is_wsl()` and uses it to short-circuit two things: `self_register` (step 3) and the final "Enable passwordless SSH from your client" tip. Everything else — preflight, clone, ansible-core install, playbook run — is unchanged.

The complementary wezterm side is in `chezmoi/dot_config/wezterm/wezterm.lua` and has three load-bearing pieces:

1. **`default_cwd = '~'` loop** right after `wezterm.default_wsl_domains()`: mutates each returned WSL domain so the *first* tab in each distro opens in `/home/<wsl-user>` instead of inheriting wezterm's own cwd (typically `/mnt/c/Users/<windows-user>` when launched from a Start-menu shortcut).

2. **`smart_new_tab` callback** bound to `CTRL+SHIFT+T`: `act.SpawnTab 'CurrentPaneDomain'` inherits the *current pane's* cwd if known, else falls back to wezterm's own cwd — silently defeating `default_cwd` for every tab after the first. The callback checks `pane:get_domain_name()`: for WSL panes without a tracked cwd (`pane:get_current_working_dir()` returns nil), it spawns a fresh tab via `act.SpawnTab { DomainName = domain }` (same shape as `pick_host` uses for the host launcher) so wezterm uses the domain's `default_cwd='~'`; otherwise it defers to the default action. **Critically, do not "simplify" the WSL branch to `act.SpawnCommandInNewTab { cwd = '~' }`** — wezterm tilde-expands `cwd` on the Windows host side (resolving to `C:\Users\<windows-user>`), then passes that absolute Windows path to `wsl.exe`, which lands you in `/mnt/c/Users/<windows-user>` (same basename as the WSL home, so the bug looks superficially "fixed" but the working dir is the wrong filesystem). The conditional is what lets the callback be transparent once OSC 7 is emitted (see #3).

3. **OSC 7 emission** in `chezmoi/dot_bashrc.tmpl` (`__wezterm_osc7` registered in `PROMPT_COMMAND` with a case-guard against double-registration): emits `\e]7;file://<host><pwd>\e\\` after every prompt so wezterm tracks cwd across `cd` movements. Once a WSL distro has been bootstrapped (chezmoi-applied bashrc), `cd /tmp` then `CTRL+SHIFT+T` lands the new tab in `/tmp` instead of forcing `~`.

Without #1 the first tab is wrong. Without #2 every subsequent tab is wrong (pre-bootstrap WSL). Without #3 the user can never get same-cwd-as-current-tab behavior in WSL. Keep all three.

If `is_wsl()` ever needs to distinguish WSL 1 from WSL 2 or distro families, extend the helper rather than introducing parallel detection elsewhere in `bootstrap.sh`.

## Tool versions — single source of truth

All tool versions live in `scripts/install/versions.mk` (`FZF_VERSION`, `ZOXIDE_VERSION`, etc. — one uppercase variable per tool). `bootstrap.sh` and Ansible have no version pins. To bump a tool, edit `versions.mk`; the version is baked into the stamp filename at `$STAMP/<tool>-<version>.done`, so changing it invalidates the old stamp and triggers reinstall on the next `make all`. To add a new tool, add a `<NAME>_VERSION := X.Y.Z` line to `versions.mk` plus one `$(eval $(call TOOL,...))` line to `tools.mk` — pick the helper that matches the tool's release shape (`archive.sh` / `direct.sh` / `pip.sh` / `pipe.sh` / `helix.sh`).

The historical `bootstrap.sh` `*_VERSION` constants and the `*_version:` entries in `group_vars/all.yml` have been removed; do not re-introduce per-tool variables to either file.

## Ansible role: `linux-base`

Single role, four task files orchestrated by `tasks/main.yml`. Before any task imports run, `main.yml` validates `tool_scope` vs `has_sudo` and resolves three computed facts (`tools_dest`, `tools_become`, `helix_runtime_dest`) for downstream tasks to consume:

```yaml
- fail: msg=...   when: tool_scope == 'system' and not has_sudo
- set_fact: tools_dest, tools_become, helix_runtime_dest   # resolved from tool_scope
- import_tasks: packages.yml   when: install_system_packages and has_sudo   become: true
- import_tasks: tools.yml      when: install_user_tools
- import_tasks: shell.yml      # always
- import_tasks: dotfiles.yml   when: apply_dotfiles
```

Defaults from `roles/linux-base/defaults/main.yml`:
- `install_system_packages: true`
- `install_user_tools: true`
- `apply_dotfiles: true`
- `has_sudo: true`
- `tool_scope: user`
- `arch: "x86_64"`
- `linux_target: "unknown-linux-musl"`

Scope normally comes from group_vars — `group_vars/dev_machine.yml` for hosts in `[dev_machine]`, `group_vars/prod_machine.yml` for hosts in `[prod_machine]`. The role's defaults are only the fallback for ad-hoc runs without group membership.

For local self-provisioning (or any ad-hoc one-off), pass the group_vars file as extra-vars so values stay aligned with the remote flow:
- `-e "@group_vars/dev_machine.yml"` — what `bootstrap.sh --dev` passes (sudo, system scope)
- `-e "@group_vars/prod_machine.yml"` — what `bootstrap.sh --prod` passes (no sudo, user scope)
- `-e "install_user_tools=false"` — dotfiles only (orthogonal to scope; stack with either)

Avoid raw `-e "tool_scope=..."` overrides in normal use — they bypass the group_vars source of truth and quietly diverge from what the remote playbook would do to the same host.

`tools.yml` is a three-task wrapper around `scripts/install/Makefile`: it runs `make all DEST={{ tools_dest }} HELIX_RUNTIME_DEST={{ helix_runtime_dest }}` under `become: "{{ tools_become }}"`, then `make user-tools` without become (for the pip-installed Python tools), then `make claude-cli` without become and only when `tool_scope == 'system'` (preserves the historical dev_machine-only gate for the Claude Code CLI). The Helix runtime tree (`helix_runtime_dest`) is the one special case — `~/.config/helix/runtime` for user scope, `/usr/local/lib/helix/runtime` for system scope (both are paths Helix searches by default). `scripts/install/lib/helix.sh` handles the binary+runtime split.

`shell.yml` writes PATH to `/etc/profile.d/local-bin.sh` when `has_sudo`, otherwise `lineinfile`-appends `export PATH=...` to `~/.bashrc`. `dotfiles.yml` checks for an existing `chezmoi_source/.git` to decide between `chezmoi init --apply` and `chezmoi update`, and finds the `chezmoi` binary via `tools_dest` (so it works with either scope).

## chezmoi source layout & templating

- The chezmoi *source state* is the `chezmoi/` subdirectory of this repo. It's redirected there from the cloned repo root by **`.chezmoiroot`** at the repo root (a one-line file containing `chezmoi`). Without `.chezmoiroot` chezmoi treats the repo root as the source state, which would map `chezmoi/dot_bashrc.tmpl` to `~/chezmoi/.bashrc` (literal, broken) instead of `~/.bashrc`.
- Naming conventions (relative to `chezmoi/`):
  - `dot_X` → `~/.X` (e.g. `dot_bashrc.tmpl` → `~/.bashrc`).
  - `dot_config/X` → `~/.config/X` (cross-platform; chezmoi resolves `~/` to `%USERPROFILE%\` on Windows).
  - `AppData/Roaming/X/file` → `%USERPROFILE%\AppData\Roaming\X\file` (Windows-only by ignore rule).
  - `Documents/PowerShell/X` → `%USERPROFILE%\Documents\PowerShell\X` (Windows-only).
  - `private_X` prefix enforces restrictive Unix mode (file = 0600, dir = 0700) — required for `~/.ssh/` since OpenSSH on both Linux and Windows refuses world-readable config/keys. Example: `private_dot_ssh/private_config` → `~/.ssh/config` at 0600 inside `~/.ssh/` at 0700.
  - Trailing `.tmpl` triggers Go-template rendering.
  - `.chezmoiscripts/run_once_after_init.sh.tmpl` runs once after first `chezmoi apply`; rename to re-run on a new host. The `.tmpl` gates the body with `{{ if eq .chezmoi.os "linux" }}...{{ end }}` so on Windows it renders to an empty file and chezmoi skips zero-byte scripts. **`.chezmoiignore` does NOT apply to entries under `.chezmoiscripts/`** — chezmoi treats scripts specially (they have no destination path), so OS gating has to live inside the script via `.tmpl`, not in `.chezmoiignore.tmpl`.
- Cross-platform OS gating is in `.chezmoiignore.tmpl`. On Windows it ignores Linux-only files (`dot_bashrc.tmpl`, `dot_nbrc`, `dot_config/helix`, `dot_config/zellij`); on Linux it ignores Windows-only paths (`AppData`, `Documents`, `dot_config/wezterm`). Per-machine override files (`dot_bashrc.local`, PowerShell `*.local.ps1` variants) are always ignored. The Linux-only chezmoiscript is NOT in this list — it's gated inside the script itself (see above).
- Variables available in templates:
  - `{{ .name }}`, `{{ .email }}` — populated by `promptStringOnce` in `.chezmoi.toml.tmpl` on first init.
  - `{{ .chezmoi.hostname }}`, `{{ .chezmoi.username }}`, `{{ .chezmoi.os }}` — built-in.
- Per-machine overrides:
  - **Linux**: `~/.bashrc.local` — un-tracked, sourced last by `dot_bashrc.tmpl` if present.
  - **Windows**: `Microsoft.PowerShell_profile.local.ps1` next to the main profile — un-tracked, dot-sourced last by the templated profile.
  - **Both (SSH)**: `~/.ssh/config.local` — un-tracked, `Include`d at the top of the tracked `~/.ssh/config` so per-host blocks override the global `Host *` keepalive defaults.
- `dot_bashrc.tmpl` ends with a hostname-templated block (currently a `PROJECT_ROOT` switch on `rhel-dev-01`) before the `.bashrc.local` source. The Windows PS profile applies the same pattern.

## README.html must mirror user-facing changes

`README.html` is reference material the user runs against — setup commands, daily workflows, scope flags, file locations. It is split across three sibling files at the repo root: `README.html` (structural markup) loads `README.css` (all styles, with theme tokens at the top) and `README.js` (theme toggle, scroll-spy TOC, search, filter UIs) via relative `href`/`src`. All three must travel together — moving or copying the docs means moving all three. Opening `README.html` directly from the local clone in a browser pulls in the other two via relative paths, no server needed. There is no `README.md` (the GitHub landing page is deliberately bare). **Whenever you change something the user needs to know or maintain, update `README.html` (and `README.css` / `README.js` if needed) in the same change**, with concrete usage examples (a copyable command block, not just prose).

Authoring HTML by hand is heavier than markdown, so two practical rules:
- Match the existing visual primitives already in `README.html` — `<table>`, `.flow` chips, `.tabs` panels, `.os-card`, `<details>` for collapsible sections. Don't invent new components for a one-off addition.
- Add styles to `README.css` and behavior to `README.js` — don't re-introduce inline `<style>` or `<script>` blocks in `README.html`. Keep style additions cohesive with the existing CSS-variable token system (`--bg`, `--accent`, `--border`, etc. at the top of `README.css`).

This includes:
- Setup or install steps (new prerequisite, changed entry point, renamed flag).
- Daily-workflow surface (new `manage-hosts.sh` flag, new playbook, new chezmoi alias).
- Variables the user is expected to override (`tool_scope`, `has_sudo`, anything in `defaults/main.yml`).
- File locations the user reads/writes (`hosts.conf`, `~/.bashrc.local`, `chezmoi/home/`, `WEZTERM_CONFIG_FILE` target).
- New tool added — at minimum, mention it in the Stack table; if it has end-user CLI surface, show it.
- Deprecations or removals — don't leave stale instructions in `README.html` pointing at removed flags or files.

This does NOT include:
- Internal Ansible task refactors that don't change CLI overrides or file locations.
- Comment edits, formatting changes, variable renames invisible from outside the role.
- Bumping a tool version — `group_vars/all.yml` is the source of truth, `README.html` doesn't pin versions.

When in doubt, ask: "Would a user reading only `README.html` still be able to set up and operate this repo correctly after my change?" If no, update `README.html`.

### Worked examples

| Change | README update? | What to add |
|---|---|---|
| Added `tool_scope=system` support | **Yes** | Install scopes table + `-e "tool_scope=system"` example under Daily Ansible workflow |
| Renamed `manage-hosts.sh --sync` to `--regen` | **Yes** | Replace every command example, add a one-line "renamed from `--sync`" note for one release |
| Added `direnv` (one line in `tools.mk` + `DIRENV_VERSION` in `versions.mk`) | **Yes** | Add `direnv` to Stack table; show how `tool_scope` controls its destination |
| Bumped `FZF_VERSION` in `versions.mk` | No | Versions live in `scripts/install/versions.mk` only |
| Refactored `lib/archive.sh` to deduplicate extraction logic | No | No CLI surface changed |
| Migrated tools.yml's per-tool blocks into `scripts/install/Makefile` (this commit) | **Yes** | Rewrote "Adding a tool" + "Bumping a version" sections in README.html; removed the YAML example; added the Makefile example. |
| Added a new optional `-e "ansible_python_interpreter=..."` override | **Yes** | Add a "When to set this" note under Daily Ansible workflow |
| Added a wezterm keybind (e.g. `CTRL+SHIFT+H` cheatsheet) | **Yes** | Mention it under the Windows section so users know it exists |
| Added `--copy-id` / `-CopyId` to manage-hosts | **Yes** | New "Copy SSH key" subsection with both shells + a tip line in the post-bootstrap message |
| Added bulk `--copy-id --all` / `-CopyId -All` to manage-hosts (menu option 6, renumbers 7-9) | **Yes** | Existing "Copy SSH key" subsection gets new code-block lines for the bulk form in both shells, plus a one-sentence note that the loop is best-effort and per-host status is shown live. |
| Reordered `bootstrap.sh` flow (self-register before Ansible) | **Yes** | Setup section explains the new order and the auto-commit+push step |
| Added `GITHUB_TOKEN` + `GIT_USER_NAME` + `GIT_USER_EMAIL` env-var support to `bootstrap.sh` | **Yes** | Setup section shows the labelled per-machine one-liner, the env-var purpose table, and a troubleshooting entry for clone-failure recovery. Token kept as `<your-PAT>` placeholder; identity values can be concrete to your real setup since the repo is single-user. |
| Added `bootstrap.ps1` for the Windows client side | **Yes** | Setup → On Windows section shows the `irm \| iex` one-liner with `$env:GITHUB_TOKEN`, calls out that it must run elevated, lists the five-step flow (preflight → choco install → clone → chezmoi apply → ssh-key), and documents the flags. |
| Switched bootstrap.ps1 from winget to Chocolatey | **Yes** | "WHY CHOCOLATEY" rationale stays in the script's header for future-me; README needs the elevated-shell note and the package IDs (which differ from winget's). |
| Added wezterm hardlink step to bootstrap.ps1 (chezmoi-tracked + hardlinked hybrid) | **Yes** | Setup → On Windows section needs to call out that bootstrap re-hardlinks `wezterm.lua` after chezmoi apply, so manual `--sync` edits show up in WezTerm without an explicit `cza`. Troubleshooting entry on broken hardlinks → re-run bootstrap.ps1. |
| Replaced wezterm hardlink with `WEZTERM_CONFIG_FILE` env var + default `-RepoPath` flipped to `%USERPROFILE%\.local\share\chezmoi` (matches bootstrap.sh) | **Yes** | "Hybrid wezterm.lua model" paragraph in Setup → On Windows gets rewritten. Troubleshooting "WezTerm shows old config after an edit" entry updates the failure modes (env var unset, repo moved without re-running bootstrap). Default clone path in the manual-clone code block flips. `bootstrap.ps1` gains an auto-migrate prompt when a legacy `C:\Git\workstation` clone is detected and `-RepoPath` wasn't explicitly passed. |
| Added `--reinstall` / `-Reinstall` to both bootstrap scripts | **Yes** | New "Reinstalling from scratch" subsection under Setup. Calls out what's wiped (repo + chezmoi config), what isn't (installed tools, dotfiles, SSH keys), and the self-deletion guard (refuses if run from inside the about-to-be-deleted repo — use the curl/irm pipe form instead). |
| Made the chezmoi source state cross-platform (added `.chezmoiroot`, OS-aware `.chezmoiignore.tmpl`, Windows AppData/Documents paths, migrated `wezterm.lua` under chezmoi) | **Yes** | New "chezmoi cross-platform" subsection under Setup → On Windows; updated repo-structure tree; "Editing dotfiles" workflow gets `cza`/`czd`/`cze` alias mentions for Windows. |
| Replaced `rhel_vms` with `dev_machine`/`prod_machine` groups + removed `--full` from `bootstrap.sh` | **Yes** | Rewrote the "Machine types" table (groups now carry scope, replaces the old `tool_scope` table). New bootstrap one-liners use `--dev`/`--prod` instead of `--full`/default. Ansible workflow examples target `--limit dev_machine` / `--limit prod_machine` instead of `-e "tool_scope=..."`. Self-registration paragraph mentions the group is derived from the flag. Manage-hosts `--add` examples show `--group dev_machine` and call out group validation. Troubleshooting entries for "Missing required flag" and "Invalid group". |
| Made `bootstrap.sh` WSL-aware (auto-skip self-register inside WSL) + WSL UX in wezterm.lua (`default_cwd='~'` + `smart_new_tab` callback) + OSC 7 emission in `dot_bashrc.tmpl` | **Yes** | New "Bootstrapping WSL distros" `h4` under Setup → On Windows, with the one-liner and two note paragraphs: one explaining the `default_cwd` + `smart_new_tab` pair (covers first-tab vs new-tab semantics), one explaining OSC 7 cwd tracking. The TOC entry stays unchanged (h4 nested under the existing setup-windows h3). |
| Internal `set_fact` rename inside `main.yml` | No | Invisible from outside |

## Conventions and rules of thumb

- **Never edit `ansible/inventory/hosts.ini` by hand.** Edit `hosts.conf` and run `--sync`.
- **Never edit the wezterm SSH-domains block by hand** between the sentinel comments — it gets clobbered on the next sync.
- **Don't fixed-width-pad `hosts.conf`.** The save routine recalculates widths from data; manual padding gets normalised.
- **`scripts/manage-hosts.sh` and `scripts/manage-hosts.ps1` are a parity pair.** Every user-visible capability — flags, menu options, prompts, default values, post-add flow, output glyphs — MUST exist in both. When you change one, change the other in the same commit. The two scripts produce identical output for the same `hosts.conf`; that invariant is load-bearing because either side regenerates `inventory/hosts.ini` and the wezterm sentinel block. Drift between them silently breaks reproducibility across Linux/Windows.
- **All tool installs live in `scripts/install/Makefile`** (one `$(eval $(call TOOL,...))` line per tool in `tools.mk`, version in `versions.mk`). Ansible's `tools.yml` is a thin wrapper that invokes `make`. Never re-introduce per-tool install logic anywhere else — neither in `bootstrap.sh` nor as new per-tool YAML blocks in `tools.yml`.
- **Tool versions live only in `scripts/install/versions.mk`.** One file, one bump. The version is baked into the stamp filename, so changes auto-trigger reinstall on the next `make` run.
- **The chezmoi source dir is `chezmoi/`**, not the repo root. New dotfiles go under `chezmoi/home/` or `chezmoi/dot_config/`.
- **Per-machine overrides go in `~/.bashrc.local` on each host** — un-tracked, sourced last by the templated bashrc.
- **`wezterm.lua` is chezmoi-tracked but NOT deployed to `%USERPROFILE%`.** The chezmoi source at `chezmoi/dot_config/wezterm/wezterm.lua` is the canonical file, and `.chezmoiignore.tmpl` skips `dot_config/wezterm` on Windows so chezmoi never writes a copy under `%USERPROFILE%\.config\wezterm\`. Instead, `bootstrap.ps1` sets a User-scope environment variable **`WEZTERM_CONFIG_FILE`** pointing at the chezmoi source path — WezTerm reads the repo file directly. `automatically_reload_config` still picks up edits live (including from `manage-hosts.ps1 -Sync` rewriting the sentinel block). This replaces the pre-v2 hardlink hack, which broke whenever chezmoi atomic-wrote the target on a content mismatch. If a user ever unsets `WEZTERM_CONFIG_FILE`, WezTerm falls back to its default search path — `bootstrap.ps1` also cleans up the legacy home-path copy on each run so a stale fallback can't silently win.
- **Only two valid Ansible groups: `dev_machine` and `prod_machine`.** Both `manage-hosts` scripts validate the group on `--add`/`--edit` and reject anything else, because an unknown group means no `group_vars/<group>.yml` exists and downstream scope resolution silently breaks. The group's scope semantics (sudo? system or user?) live in `ansible/group_vars/<group>.yml` — that file is the single source of truth, used by both the remote `linux.yml` playbook and (via `-e "@..."`) by `bootstrap.sh` for the local self-provisioning run. Keep the two aligned: if `bootstrap.sh` ever needs different values than the remote flow, that's a smell — fix the group_vars file, not the script.
- **User-facing changes get mirrored into `README.html`** in the same commit (see the section above for what counts). There is no `README.md` — `README.html` is the only user-facing reference, opened in a browser from the local clone.

## Daily workflows

Dotfiles (on a host):
```bash
cze ~/.bashrc       # edit
cza                 # apply locally
czd                 # diff
czu                 # pull and apply
czs                 # status
# Push back:
cd ~/.local/share/chezmoi && git add -A && git commit -m "..." && git push
```

Ansible — remote (control machine, targets `dev_machine:prod_machine`):
```bash
cd ansible
ansible-playbook playbooks/linux.yml --ask-become-pass              # all managed hosts; sudo prompt is for dev_machine hosts
ansible-playbook playbooks/linux.yml --limit dev_machine --ask-become-pass
ansible-playbook playbooks/linux.yml --limit prod_machine           # no sudo prompt — group_vars sets has_sudo=false
ansible-playbook playbooks/linux.yml --limit <hostname>             # single host
ansible-playbook playbooks/linux.yml --check                        # dry run
```
Scope per host comes from its group_vars file. Don't pass raw `-e "tool_scope=..."` overrides in normal use.

Ansible — local (self-provisioning, used by `bootstrap.sh`):
```bash
cd ansible
ansible-playbook playbooks/local.yml -e "@group_vars/prod_machine.yml"
ansible-playbook playbooks/local.yml -e "@group_vars/dev_machine.yml" --ask-become-pass
```

Adding a host:
1. On the new host: `git clone … && ./bootstrap.sh --prod` (or `--dev` for sudo). Self-registration appends to `hosts.conf` under `prod_machine` or `dev_machine`.
2. From the Windows host or another machine, `git pull` and run `--sync` (or commit and push from the host, then pull elsewhere) so the inventory and `chezmoi/dot_config/wezterm/wezterm.lua` block update. On Windows, also run `chezmoi apply` (or the `cza` alias) to push the new wezterm config into `%USERPROFILE%\.config\wezterm\`.

Adding a tool:
1. Add `<NAME>_VERSION := X.Y.Z` to `scripts/install/versions.mk`.
2. Add one `$(eval $(call TOOL,...))` line to `scripts/install/tools.mk` — pick the helper that matches the release shape:
   - `$(LIB)/archive.sh <binary[:other_binary:...]> <url>` for tar.gz/tar.bz2/tar.xz/zip (covers ~85% of tools, including multi-binary ones like `age:age-keygen` or `yazi:ya`).
   - `$(LIB)/direct.sh <name> <url>` for raw binary URLs (jq, broot, sops).
   - `$(LIB)/pipe.sh <name> <url> [-- <installer args>]` for upstream `curl | sh` installers (chezmoi takes `-b $(DEST)`).
   - `$(LIB)/pip.sh <pkg>` for Python tools — register via `USER_TOOL` macro instead of `TOOL`, so it goes into `make user-tools` (no sudo, always `~/.local`).
   - `$(LIB)/helix.sh <version>` if the tool is helix-shaped (binary + a runtime tree). Currently helix only.
3. Test before pushing: `cd scripts/install && make <name> DEST=/tmp/test STAMP=/tmp/test-stamps`. Re-run should be a no-op (no `==>` line). For multi-binary tools, verify every binary lands in `/tmp/test/`.
4. If the tool has user-facing CLI surface, mention it in `README.html` (see "README.html must mirror user-facing changes").

## Files Claude should be careful with

- `ansible/inventory/hosts.ini` — auto-gen, never edit.
- `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block — auto-gen between `-- HOSTS:START` / `-- HOSTS:END` sentinels by both manage-hosts scripts. Edit anywhere outside the sentinels freely. On Windows, edits to this file appear in WezTerm immediately because `bootstrap.ps1` sets `WEZTERM_CONFIG_FILE` to point at this file directly; on Linux hosts without WezTerm the file is ignored by chezmoi.
- `hosts.conf` — edit via the manage-hosts scripts when possible; manual edits work but lose dynamic padding (and sort order) until next save. Column 4 (group) must be `dev_machine` or `prod_machine` — the manage-hosts scripts reject anything else on save.
- `.chezmoiroot` — one-line file at the repo root containing `chezmoi`. Required for chezmoi's source state to point at the `chezmoi/` subdirectory; without it, all `dot_*` paths break. Don't delete or edit.
- `bootstrap.sh` — keep it a thin seed. It must NOT contain per-tool versions or install logic. Tool versions live only in `scripts/install/versions.mk`; install logic lives only in `scripts/install/tools.mk` + `lib/*.sh`. Scope values (tool_scope, has_sudo, install_system_packages) must NOT be inlined — they come from `ansible/group_vars/<group>.yml` via `-e "@..."`. If `bootstrap.sh` and the group_vars file ever disagree on scope, fix the group_vars file.
- `scripts/install/Makefile` and `tools.mk` — the install machinery. The Makefile defines two macros (`TOOL` / `USER_TOOL`) plus a bespoke `claude-cli` rule; `tools.mk` is the per-tool data file. Recipe lines in the Makefile MUST be tab-indented (not spaces) — Make is strict. The TOOL macro's body uses `$$` to defer variable expansion to rule-fire time; don't switch to single `$` without testing.
- `scripts/install/versions.mk` — single source of truth for tool versions. Variables are uppercase (`FZF_VERSION`, `GITUI_VERSION`, etc.) and consumed by URL templates in `tools.mk`. Use `latest` for tools that have no upstream version pin (broot, nb, pip packages).
- `scripts/install/lib/*.sh` — install helpers. All shell scripts here MUST remain LF-only (same trap as `manage-hosts.sh`); `file scripts/install/lib/archive.sh` should say "Bourne-Again shell script", NOT "with CRLF line terminators". Repair with `sed -i 's/\r$//' scripts/install/lib/*.sh`.
- `ansible/group_vars/dev_machine.yml` and `ansible/group_vars/prod_machine.yml` — single source of truth for per-group scope. Used by both the remote `linux.yml` playbook (automatically) and `bootstrap.sh` (via `-e "@..."`). Adding a new scope-level variable means adding it to both files (or to `group_vars/all.yml` if it's shared).
- `chezmoi/.chezmoiignore.tmpl` — wrong entries here cause `chezmoi apply` to drop infrastructure files into `$HOME` (or to skip files you wanted applied). Edit-then-test: `chezmoi diff` on a sandbox host/Windows machine before pushing.
- `scripts/manage-hosts.ps1` and `bootstrap.ps1` **must remain UTF-8 with BOM**. PowerShell 5.1 (Windows PowerShell, the default `powershell.exe`) reads scripts as Windows-1252 unless a BOM is present, and both files contain Unicode glyphs (`✓`, `✗`, `─`) used in colored output. Without the BOM, PS 5.1 mis-decodes the multi-byte UTF-8 and the script fails to parse with cryptic "string missing terminator" errors. To restore the BOM after a tool overwrites it: `[System.IO.File]::WriteAllText($path, [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path)), [System.Text.UTF8Encoding]::new($true))`.
- `scripts/manage-hosts.sh` **must remain LF-only**. The Edit/Write tools on Windows tend to save with CRLF; the resulting file runs but `read -r` then leaks `\r` into parsed fields, polluting the inventory. After any edit, verify with `file scripts/manage-hosts.sh` (expect "Bourne-Again shell script", no "with CRLF line terminators"). Repair with `sed -i 's/\r$//' scripts/manage-hosts.sh`.

## Quick verification

After changes:
- `./scripts/manage-hosts.sh --sync` — regenerates inventory + the chezmoi-tracked wezterm block, no errors. Output `ansible/inventory/hosts.ini` should contain the host groups present in `hosts.conf` (currently `[prod_machine]`) and a single `[all:vars]` connection block — no orphaned `[rhel_vms:vars]`.
- `cd ansible && ansible-playbook playbooks/linux.yml --check` — dry-run on every managed host. Each host should resolve its own scope from its `group_vars/<group>.yml` (prod_machine hosts skip `packages.yml` since `install_system_packages=false`).
- `cd ansible && ansible-playbook playbooks/local.yml --check -e "@group_vars/prod_machine.yml"` — dry-run the local playbook in prod scope.
- `cd ansible && ansible-playbook playbooks/local.yml --check -e "@group_vars/dev_machine.yml"` — dry-run in dev scope (plans dnf installs to `/usr/local/bin`).
- `cd scripts/install && make list` — should show every managed tool grouped by target: ~55 scope-tools, 3 user-tools, plus claude-cli. If a tool isn't listed, its `$(eval $(call TOOL,...))` line in `tools.mk` didn't expand — usually because the `<NAME>_VERSION` variable referenced in the call wasn't defined in `versions.mk`.
- `cd scripts/install && make -j8 all DEST=/tmp/install-test HELIX_RUNTIME_DEST=/tmp/helix-rt STAMP=/tmp/install-test-stamps` — full install to a sandbox. Should finish in 25-30s on a reasonable connection; `ls /tmp/install-test | wc -l` ≈ 59 (the extra 4 are the multi-binary companions: `age-keygen`, `sg`, `ya`, `uvx`). Re-running the same command should be a sub-second no-op.
- `./bootstrap.sh` with no flags must error out (no default). `./bootstrap.sh --dev --prod` must error out (mutually exclusive). `./bootstrap.sh --full` must error out with a clear "use --dev or --prod" message.
- `./scripts/manage-hosts.sh --add --name t --ip 1.2.3.4 --user u --group foo --skip-confirm` must reject `foo` with a "must be dev_machine or prod_machine" error. The PowerShell side (`-Add -Group foo`) must reject the same way.
- `chezmoi diff` on a host (or Windows machine) — shows pending dotfile changes, no surprises. On Windows, the diff should mention only Windows-targeted paths (AppData, Documents, dot_config/wezterm) plus the cross-platform `.ssh/config`; on Linux only Linux-targeted paths (dot_bashrc, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc) plus the cross-platform `.ssh/config`.
- `ssh -G <managed-host> | grep -iE 'serveralive|tcpkeepalive|connecttimeout'` after `chezmoi apply` — confirms the keepalive defaults from `private_dot_ssh/private_config` made it into the live `~/.ssh/config`. Should print `serveraliveinterval 30`, `serveralivecountmax 3`, `tcpkeepalive yes`, `connecttimeout 10`.
- In WezTerm, press `CTRL+SHIFT+F5` inside an SSH tab — a new tab against the same domain spawns and Zellij reattaches. In a local tab, it shows a toast "Not an SSH pane — nothing to reconnect".
- `bootstrap.sh --dev` and `bootstrap.sh --prod` on fresh hosts — each completes idempotently and self-registers under the matching group.
- `bootstrap.sh --dev` *inside a WSL distro* — completes without touching `hosts.conf`, prints "Detected WSL — skipping hosts.conf self-registration", and the final tip line is the WSL-specific "open a new WezTerm WSL tab" message (not the SSH copy-id one). `git status` in the cloned repo afterwards shows no host-list changes.
- Opening a fresh WSL tab in WezTerm after `chezmoi apply` on Windows — `pwd` is the WSL user's home (`/home/<user>`), not `/mnt/c/Users/...`. Bash's default `\W` (or Starship after the WSL bootstrap) renders the cwd as `~`.
- Inside a WSL tab, press `CTRL+SHIFT+T` — pre-bootstrap (default bash, no OSC 7) the new tab lands in `~`; post-bootstrap (chezmoi-tracked bashrc + `__wezterm_osc7` in `PROMPT_COMMAND`) `cd /tmp` then `CTRL+SHIFT+T` lands the new tab in `/tmp`. Inside an SSH or local tab, `CTRL+SHIFT+T` keeps its existing behavior.
- `bootstrap.ps1` on a fresh Windows machine (from an **elevated** PowerShell) — choco bootstraps itself, the seven tracked tools install, chezmoi applies, wezterm picks up the deployed config.
- `git diff README.html README.css README.js` — verify the user-facing surface still matches reality. Open the file in a browser too — visual primitives (tabs, flow chips, accordion filter) need to render, not just diff cleanly. If the browser loads `README.html` but no styles or interactions apply, check that `README.css` / `README.js` are present as siblings (relative paths break if any of the three are moved without the others).
