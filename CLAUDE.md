# CLAUDE.md

Guidance for Claude Code working on this repository.

## What this repo is

`workstation` is a self-contained dev-environment-provisioning system. One Git repo manages:
- Multiple **Linux hosts** in two flavours: `dev_machine` (hosts you own, sudo, system-wide installs) and `prod_machine` (hosts you don't fully own, no sudo, user-wide installs).
- One **Windows host** (WezTerm config that auto-connects to the Linux hosts).

The repo is consumed three ways:
1. **From a Linux host** — clone, run `bootstrap.sh --dev` or `bootstrap.sh --prod`. The script preflight-checks the toolchain (curl/git/make/tar/unzip/iproute), self-registers the host in `hosts.conf` under the chosen group, then runs `make MODE=dev|prod provision` inside `makefile/` — which handles dnf packages, PATH wiring, ~55 tool installs, and chezmoi orchestration in one parallel pass.
2. **From the Windows host** — `bootstrap.ps1` (run from an **elevated** PowerShell) bootstraps Chocolatey, installs tooling via `choco` (chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode), clones the repo, and runs `chezmoi init --apply` to deploy `wezterm.lua`, the PowerShell profile, Zed/VSCode settings, etc. into `%USERPROFILE%\…`. Choco rather than winget because winget's PATH propagation is unreliable mid-session and leaves freshly-installed binaries unresolvable to the next step.
3. **From an ops machine** — run `scripts/update-hosts.sh --group dev_machine` (or `--group prod_machine`, or no flag for all hosts) to ssh into every managed host in parallel and re-run `git pull && make provision`. Replaces the pre-migration `ansible-playbook playbooks/linux.yml --limit …` workflow.

## Layered architecture

Two separate concerns, intentionally decoupled:

| Concern | Tool | Where it runs | Needs sudo? |
|---|---|---|---|
| Provisioning | **Make** (`makefile/`) | Locally on a host (bootstrap.sh) or remotely (update-hosts.sh) | Per-recipe via `$(SUDO)` — empty for prod, `sudo` for dev |
| Dotfiles | **chezmoi** (`chezmoi/`) | On each host as the dev user | No |

Make drives **everything** under `makefile/`: dnf packages (`packages.mk`), PATH wiring (`shell.mk`), ~55 tool installs (`tools.mk` + `lib/*.sh`), chezmoi orchestration (`dotfiles.mk`), and scope-fact derivation (`scope.mk`). `bootstrap.sh` is a thin seed: it clones the repo, self-registers the host, then runs `make MODE=<dev|prod> provision` inside `makefile/`. Adding a new tool is two lines: one `<NAME>_VERSION` in `versions.mk` and one `$(eval $(call TOOL,...))` in `tools.mk`.

User-space tools (`fzf`, `zellij`, `helix`, etc.) are **always** installed as static binaries — never via `dnf` — but the **destination** is controlled by `MODE`, which is set per host based on its group in `hosts.conf`:

| Group | `MODE` | sudo? | dnf packages | Binary destination | Helix runtime |
|---|---|---|---|---|---|
| `dev_machine` | `dev` | yes | installed | `/usr/local/bin` | `/usr/local/lib/helix/runtime` |
| `prod_machine` | `prod` | no | skipped (no sudo) | `~/.local/bin` | `~/.config/helix/runtime` |

The mapping is resolved in `makefile/scope.mk` — single source of truth. `bootstrap.sh` picks `MODE` from its `--dev` / `--prod` flag, and `scripts/update-hosts.sh` derives `MODE` per host from the group column of `hosts.conf`.

`MODE=dev` parse-time-errors out unless sudo is available (system scope without sudo is impossible). The `$(SUDO)` prefix is threaded through the `TOOL` macro so individual recipe lines that write to `/usr/local/bin` get root, while make itself runs as the dev user end-to-end — pip user-site tools and the claude installer never accidentally get sudo'd. Helix's runtime tree is handled by `lib/helix.sh` (the only tool that lays down more than just a binary).

## Repo layout

```
workstation/
├── bootstrap.sh                  ← Linux host entry point — thin Make seed
├── bootstrap.ps1                 ← Windows client entry point — choco tools + chezmoi apply (elevated)
├── .chezmoiroot                  ← contains "chezmoi" — redirects chezmoi's source state to the chezmoi/ subdir
├── hosts.conf                    ← single source of truth for host list
├── README.html                   ← user-facing setup + daily commands (structural HTML; loads README.css + README.js as siblings)
├── README.css                    ← all styles for README.html (theme tokens at the top)
├── README.js                     ← behavior for README.html (theme toggle, scroll-spy TOC, search, filter UIs)
│
├── scripts/
│   ├── manage-hosts.sh           ← Linux host manager (CRUD hosts.conf + regenerate wezterm sentinel block)
│   ├── manage-hosts.ps1          ← Windows host manager (feature-parity)
│   └── update-hosts.sh           ← multi-host updater — ssh-loop over hosts.conf, runs `git pull && make provision`
│
├── makefile/                     ← provisioning (replaces the old ansible/ tree)
│   ├── Makefile                  ← top-level: include & provision/dev/prod targets + TOOL/USER_TOOL/EGET_TOOL macros
│   ├── scope.mk                  ← MODE=dev|prod → DEST / SUDO / HAS_SUDO / INSTALL_PACKAGES
│   ├── versions.mk               ← single source of truth for tool versions (incl. EGET_VERSION for the meta-installer)
│   ├── tools.mk                  ← per-tool install rules (one $(eval $(call ...)) line each)
│   ├── packages.mk               ← dnf core + EPEL (RHEL-family) + optional best-effort loop
│   ├── shell.mk                  ← PATH via /etc/profile.d (sudo) or ~/.bashrc (no sudo); bash-completion
│   ├── dotfiles.mk               ← `chezmoi update` gated on ~/.config/chezmoi/chezmoi.toml existing
│   └── lib/
│       ├── eget.sh               ← PREFERRED: thin wrapper around eget meta-installer (37 tools)
│       ├── archive.sh            ← curl + extract + find-and-install (tar.gz/bz2/xz/zip) — multi-binary/non-GH cases
│       ├── direct.sh             ← curl + chmod for raw binary URLs
│       ├── pipe.sh               ← curl-piped upstream installers (chezmoi, claude)
│       ├── pip.sh                ← pip install --user wrapper
│       └── helix.sh              ← multi-file: binary + runtime/ tree (special-cased)
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

`hosts.conf` is the only file you edit. One output is regenerated from it:

| Output | Generated by | Marker |
|---|---|---|
| `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block | in-place replace between sentinels | `-- HOSTS:START` / `-- HOSTS:END` |

`scripts/update-hosts.sh` also reads `hosts.conf` directly (no separate inventory file) — it parses the group column to derive `MODE=dev|prod` per host when running bulk updates.

### Host management commands

Linux:
```bash
./scripts/manage-hosts.sh                # interactive menu
./scripts/manage-hosts.sh --sync         # regenerate wezterm sentinel block
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

The two scripts produce **the same output** for the same `hosts.conf` — the same wezterm sentinel block, regardless of which platform regenerates it.

### Wezterm sentinel mechanism

The wezterm sync replaces only the block between two sentinel comments in the chezmoi-tracked source file at `chezmoi/dot_config/wezterm/wezterm.lua`:

```lua
-- HOSTS:START
local ssh_domains = { ... }
-- HOSTS:END
```

Both sentinels must be present at column 0. The bash script uses `awk` to print everything outside the sentinels unchanged and substitute a freshly generated `local ssh_domains = { ... }` block between them; the PowerShell script does the equivalent with a `(?s)-- HOSTS:START.*?-- HOSTS:END` regex. If the sentinels are removed, bash silently no-ops and PowerShell prints a warning and skips — the rest of the file (keybinds, appearance, etc.) is never touched by sync, so it's safe to edit anywhere outside the sentinel block.

## bootstrap.sh

A thin seed that delegates everything to `make`. Exactly one of `--dev` or `--prod` is required — it decides both the group this host registers as in `hosts.conf` AND the `MODE` `make provision` runs in. No default — the choice is too load-bearing to silently fall through.

### `--dev` (dev_machine, sudo, system scope)
Runs:
```
make -C makefile MODE=dev provision
```
Installs `dnf` packages (under `$(SUDO)`), writes static binaries to `/usr/local/bin`, wires PATH via `/etc/profile.d/local-bin.sh`, runs `chezmoi update` if config exists. Self-registers as `dev_machine` in `hosts.conf`.

### `--prod` (prod_machine, no sudo, user scope)
Runs:
```
make -C makefile MODE=prod provision
```
Installs only the user-space tools to `~/.local/bin`. Skips dnf (the `packages` target is a no-op when `INSTALL_PACKAGES=false`). Wires PATH via `~/.bashrc`. Self-registers as `prod_machine`.

The scope values are not hardcoded in `bootstrap.sh` — they come from `makefile/scope.mk`, which maps `MODE` to `DEST` / `SUDO` / `HAS_SUDO` / `INSTALL_PACKAGES`. `scripts/update-hosts.sh` reads the same Makefile for remote bulk updates, so a host configured locally and a host configured remotely end up identical.

### Common steps for both modes (in order)
1. **Preflight**: collect-all check for `curl`, `git`, `make`, `tar`, `unzip`, and `ip` (iproute) — reports every missing tool in one message rather than one at a time. No Python checks (Ansible is gone).
2. **Clone the repo** to `$HOME/.local/share/chezmoi` if not present (or `git pull --ff-only` if it is). If `GITHUB_TOKEN` is set in env, the script passes it via `git -c http.https://github.com/.extraheader=Authorization: Basic …` for the clone, and persists the same key into the cloned repo's `.git/config`. That single token then covers all subsequent git ops in this script (push), in `chezmoi update`, and any manual `git pull`/`git push` the user runs in the repo. The header key is github.com-scoped, so the token never leaks to other remotes. To clear: `git config --unset http.https://github.com/.extraheader` in the repo.
3. **Self-registration** (happens *before* `make` runs): invokes `manage-hosts.sh --add` with detected `hostname -s` + IP from `ip route get 1.1.1.1` (fallback `ip addr`) + `whoami` + group `${MACHINE_TYPE}_machine` (i.e. `dev_machine` or `prod_machine` based on the flag). `--skip-confirm` is passed; if the host already exists the call returns silently. The sync regenerates the wezterm sentinel block locally before `make` runs. **Auto-skipped inside WSL** — `is_wsl()` (checks `$WSL_DISTRO_NAME` and `/proc/version`'s microsoft marker) short-circuits this step because WSL distros are reached via wezterm WSL domains, not SSH; registering them would pollute `hosts.conf` with a WSL-internal IP and duplicate the WSL domain as an SSH-domain entry in `wezterm.lua`.
4. **Run `make MODE=<dev|prod> provision`** in `makefile/`. The Makefile resolves scope facts from `MODE` via `scope.mk`, then runs the equivalent of every old Ansible task in one parallel pass: dnf packages (`packages.mk`), static-binary tool installs (`tools.mk` × ~55 tools), PATH wiring (`shell.mk`), `chezmoi update` (`dotfiles.mk`), and the Claude Code CLI (only on dev mode). Sudo is prefixed onto recipe lines that need it — make itself never runs under sudo, so stamps stay user-owned and pip-installed tools never accidentally land in `/root`.
4b. **Ensure chezmoi is initialized** — if `~/.config/chezmoi/chezmoi.toml` doesn't exist (first-ever bootstrap on this host), runs `chezmoi init --apply --source $CHEZMOI_SOURCE </dev/tty` interactively. The `</dev/tty` redirect is load-bearing: under `curl … | bash` the script's own stdin is the curl pipe, so `chezmoi`'s `promptStringOnce` calls for name/email would otherwise read EOF and fail. Make recipes can't do this either — no TTY in `command`-style execution — which is why `dotfiles.mk` is gated on the config existing and runs only `chezmoi update` (pull + apply), never `init`.
5. **Auto-commit + push** the host-list changes (`hosts.conf`, `chezmoi/dot_config/wezterm/wezterm.lua`) with the message `chore(hosts): register <hostname>`. Identity priority for the commit: `GIT_USER_NAME` / `GIT_USER_EMAIL` env vars (highest — set in the bootstrap one-liner) → existing `git config user.name`/`user.email` (e.g. from a chezmoi-applied `~/.gitconfig`) → synthetic `whoami@hostname` fallback so the commit never fails outright. Warn-don't-fail on every error: if the commit or push fails (auth, conflict, no upstream), bootstrap prints the recovery `git push` command but does NOT abort. `make provision` already succeeded by this point. **No-op inside WSL** — since `self_register` was skipped, none of the host-list files changed and the existing `git diff --quiet` guard at the top of `push_host_changes` returns early.

Both modes are idempotent. Tool versions and install logic live entirely in `makefile/` — `bootstrap.sh` has no per-tool knowledge.

`--full` was removed when `--dev`/`--prod` landed. The script gives a clear error if anyone passes `--full` so old paste-buffer one-liners fail loudly instead of silently doing the wrong thing.

The reordering is load-bearing: anything in `make`/chezmoi that grows to read `hosts.conf` will see the new host. Don't move self-registration back to "after make runs" without explicit reason.

### Running inside WSL

WSL distros are supported as managed hosts (tools + dotfiles) but NOT as SSH targets. `bootstrap.sh` defines `is_wsl()` and uses it to short-circuit two things: `self_register` (step 3) and the final "Enable passwordless SSH from your client" tip. Everything else — preflight, clone, `make provision`, chezmoi init — is unchanged.

The complementary wezterm side is in `chezmoi/dot_config/wezterm/wezterm.lua` and has three load-bearing pieces:

1. **`default_cwd = '~'` loop** right after `wezterm.default_wsl_domains()`: mutates each returned WSL domain so the *first* tab in each distro opens in `/home/<wsl-user>` instead of inheriting wezterm's own cwd (typically `/mnt/c/Users/<windows-user>` when launched from a Start-menu shortcut).

2. **`smart_new_tab` callback** bound to `CTRL+SHIFT+T`: `act.SpawnTab 'CurrentPaneDomain'` inherits the *current pane's* cwd if known, else falls back to wezterm's own cwd — silently defeating `default_cwd` for every tab after the first. The callback checks `pane:get_domain_name()`: for WSL panes without a tracked cwd (`pane:get_current_working_dir()` returns nil), it spawns a fresh tab via `act.SpawnTab { DomainName = domain }` (same shape as `pick_host` uses for the host launcher) so wezterm uses the domain's `default_cwd='~'`; otherwise it defers to the default action. **Critically, do not "simplify" the WSL branch to `act.SpawnCommandInNewTab { cwd = '~' }`** — wezterm tilde-expands `cwd` on the Windows host side (resolving to `C:\Users\<windows-user>`), then passes that absolute Windows path to `wsl.exe`, which lands you in `/mnt/c/Users/<windows-user>` (same basename as the WSL home, so the bug looks superficially "fixed" but the working dir is the wrong filesystem). The conditional is what lets the callback be transparent once OSC 7 is emitted (see #3).

3. **OSC 7 emission** in `chezmoi/dot_bashrc.tmpl` (`__wezterm_osc7` registered in `PROMPT_COMMAND` with a case-guard against double-registration): emits `\e]7;file://<host><pwd>\e\\` after every prompt so wezterm tracks cwd across `cd` movements. Once a WSL distro has been bootstrapped (chezmoi-applied bashrc), `cd /tmp` then `CTRL+SHIFT+T` lands the new tab in `/tmp` instead of forcing `~`.

Without #1 the first tab is wrong. Without #2 every subsequent tab is wrong (pre-bootstrap WSL). Without #3 the user can never get same-cwd-as-current-tab behavior in WSL. Keep all three.

If `is_wsl()` ever needs to distinguish WSL 1 from WSL 2 or distro families, extend the helper rather than introducing parallel detection elsewhere in `bootstrap.sh`.

## Tool versions — single source of truth

All tool versions live in `makefile/versions.mk` (`FZF_VERSION`, `ZOXIDE_VERSION`, `EGET_VERSION`, etc. — one uppercase variable per tool). `bootstrap.sh` and the Makefile-driven provisioning layer have no inline version pins. To bump a tool, edit `versions.mk`; the version is baked into the stamp filename at `$STAMP/<tool>-<version>.done`, so changing it invalidates the old stamp and triggers reinstall on the next `make provision` (or targeted `make <tool>`). To add a new tool, add a `<NAME>_VERSION := X.Y.Z` line to `versions.mk` plus one `$(eval $(call EGET_TOOL,...))` line to `tools.mk` (or one of the fallback macros for non-eget cases — see "Adding a tool" below).

`bootstrap.sh` has never carried `*_VERSION` constants; the historical `group_vars/all.yml` `*_version:` entries are gone (along with the whole `ansible/` tree). Do not re-introduce per-tool variables anywhere outside `versions.mk`.

## Makefile layout: `makefile/`

Replaces the old `ansible/` tree. Composition (in include order — order matters for variable visibility):

```
include scope.mk      # MODE=dev|prod → DEST / SUDO / HAS_SUDO / INSTALL_PACKAGES
include versions.mk   # tool versions (single source of truth) — also EGET_VERSION
include tools.mk      # per-tool $(eval $(call EGET_TOOL|TOOL|USER_TOOL,…)) calls
include packages.mk   # dnf core + EPEL (RHEL-family conditional) + optional loop
include shell.mk      # PATH wiring
include dotfiles.mk   # chezmoi update gate
```

Three macros register tools:
- **`EGET_TOOL`** — preferred for single-binary GitHub releases (~38 of 56). Delegates to `lib/eget.sh` which wraps the [`eget` meta-installer](https://github.com/zyedidia/eget). One line per tool: `$(eval $(call EGET_TOOL,<name>,<version>,<user/repo>[,<tag>][,<extra args>]))`. eget itself is the first tool in `tools.mk` (installed via the regular `archive.sh` path); all EGET_TOOL rules add an order-only Make prerequisite on its stamp so `make -j8` always builds eget first.
- **`TOOL`** — used for tools eget can't cleanly install: non-GitHub URLs (ncdu/broot/nb/sysz/ssh-copy-id), multi-binary archives with junk files (age, yazi), helix's multi-file install, the chezmoi/claude curl-pipe installers.
- **`USER_TOOL`** — pip user-site tools (glances/asciinema/harlequin). Never under sudo. Joins `$(USER_TOOLS)`.

Top-level phony targets:

```
make dev              # MODE=dev provision (sudo, /usr/local/bin)
make prod             # MODE=prod provision (no sudo, ~/.local/bin)
make provision MODE=… # explicit MODE
make all MODE=…       # scope-tools only (~55 binaries); synonym retained from earlier migration
make user-tools       # pip tools (glances/asciinema/harlequin)
make claude-cli       # Claude Code CLI (dev_machine flow runs this; prod skips)
make <tool>           # single tool, e.g. make gitui MODE=prod
make clean-<tool>     # wipe stamp (+ binary for scope tools)
make list MODE=…      # list every managed tool, grouped
make help             # this help text
```

`provision` depends on: `packages` (no-op for prod), `tools` (= `$(SCOPE_TOOLS)`), `user-tools`, `shell`, `dotfiles`. On `MODE=dev` it additionally depends on `claude-cli`.

Scope is resolved at parse time by `scope.mk`. Without `MODE=…` (or `make dev`/`make prod`), `scope.mk` errors out — there is deliberately no default, because the two scopes are too load-bearing to silently fall through to one. The `make dev` / `make prod` aliases re-invoke make with `MODE=…` set, so users can stay scope-aware without typing `MODE=`.

The `$(SUDO)` thread: `scope.mk` sets `SUDO := sudo --preserve-env=DEST,HELIX_RUNTIME_DEST` for `MODE=dev` and `SUDO :=` (empty) for `MODE=prod`. Both `TOOL` and `EGET_TOOL` macros in `Makefile` prefix the install command with `$(SUDO)`, so dev-mode scope tools land in `/usr/local/bin` via sudo while prod-mode ones land in `~/.local/bin` as the dev user. The `--preserve-env=DEST,HELIX_RUNTIME_DEST` is load-bearing — sudo's default is env_reset and the lib scripts (archive.sh, eget.sh, helix.sh) read those vars to know where to install. `USER_TOOL` (used by pip targets) never gets `$(SUDO)` — pip user-site always belongs to the calling user. Claude's bespoke rule in `Makefile` also skips `$(SUDO)` for the same reason. Make itself runs as the dev user end-to-end, so stamps under `$HOME/.local/share/workstation-install/` stay readable on re-runs.

The Helix runtime tree (`helix_runtime_dest`) is the one special case — `~/.config/helix/runtime` for user scope, `/usr/local/lib/helix/runtime` for system scope (both are paths Helix searches by default). `makefile/lib/helix.sh` handles the binary+runtime split via the `TOOL` macro.

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
- Daily-workflow surface (new `manage-hosts.sh` flag, new `make` target, new chezmoi alias).
- Variables the user is expected to override (`MODE`, anything in `makefile/scope.mk`).
- File locations the user reads/writes (`hosts.conf`, `~/.bashrc.local`, `chezmoi/home/`, `WEZTERM_CONFIG_FILE` target).
- New tool added — at minimum, mention it in the Stack table; if it has end-user CLI surface, show it.
- Deprecations or removals — don't leave stale instructions in `README.html` pointing at removed flags or files.

This does NOT include:
- Internal Makefile refactors that don't change CLI overrides or file locations.
- Comment edits, formatting changes, variable renames invisible from outside `makefile/`.
- Bumping a tool version — `versions.mk` is the source of truth, `README.html` doesn't pin versions.

When in doubt, ask: "Would a user reading only `README.html` still be able to set up and operate this repo correctly after my change?" If no, update `README.html`.

### Worked examples

| Change | README update? | What to add |
|---|---|---|
| Added `MODE=dev|prod` support | **Yes** | Scope-mapping table + `make MODE=...` examples under Daily make workflow |
| Renamed `manage-hosts.sh --sync` to `--regen` | **Yes** | Replace every command example, add a one-line "renamed from `--sync`" note for one release |
| Added `direnv` (one line in `tools.mk` + `DIRENV_VERSION` in `versions.mk`) | **Yes** | Add `direnv` to Stack table; show how `MODE` controls its destination |
| Bumped `FZF_VERSION` in `versions.mk` | No | Versions live in `makefile/versions.mk` only |
| Refactored `lib/archive.sh` to deduplicate extraction logic | No | No CLI surface changed |
| Integrated eget meta-installer (new EGET_TOOL macro) | **Yes** | "Adding a tool" section gets EGET_TOOL as the preferred macro; existing tools listed by helper class; per-tool `--asset` patterns documented (`musl`, `static`, `.tar.gz`, `^server`, `64bit`). |
| Dropped Ansible entirely (this commit) | **Yes** | New "What changed if you used Ansible" callout under Daily workflows; commands `ansible-playbook playbooks/local.yml` → `make MODE=… provision`, `ansible-playbook playbooks/linux.yml --limit X` → `scripts/update-hosts.sh --group X`; preflight no longer needs python3 or pip; bootstrap no longer installs ansible-core. |
| Added a wezterm keybind (e.g. `CTRL+SHIFT+H` cheatsheet) | **Yes** | Mention it under the Windows section so users know it exists |
| Added `--copy-id` / `-CopyId` to manage-hosts | **Yes** | New "Copy SSH key" subsection with both shells + a tip line in the post-bootstrap message |
| Added bulk `--copy-id --all` / `-CopyId -All` to manage-hosts (menu option 6, renumbers 7-9) | **Yes** | Existing "Copy SSH key" subsection gets new code-block lines for the bulk form in both shells, plus a one-sentence note that the loop is best-effort and per-host status is shown live. |
| Reordered `bootstrap.sh` flow (self-register before make runs) | **Yes** | Setup section explains the new order and the auto-commit+push step |
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

- **Never edit the wezterm SSH-domains block by hand** between the sentinel comments — it gets clobbered on the next sync.
- **Don't fixed-width-pad `hosts.conf`.** The save routine recalculates widths from data; manual padding gets normalised.
- **`scripts/manage-hosts.sh` and `scripts/manage-hosts.ps1` are a parity pair.** Every user-visible capability — flags, menu options, prompts, default values, post-add flow, output glyphs — MUST exist in both. When you change one, change the other in the same commit. The two scripts produce identical output for the same `hosts.conf`; that invariant is load-bearing because either side regenerates the wezterm sentinel block. Drift between them silently breaks reproducibility across Linux/Windows.
- **All tool installs live in `makefile/Makefile` + `tools.mk`** (one `$(eval $(call TOOL,...))` line per tool in `tools.mk`, version in `versions.mk`). Never re-introduce per-tool install logic anywhere else — not in `bootstrap.sh`, not in a new playbook, not in a new shell script under `scripts/`.
- **Tool versions live only in `makefile/versions.mk`.** One file, one bump. The version is baked into the stamp filename, so changes auto-trigger reinstall on the next `make` run.
- **The chezmoi source dir is `chezmoi/`**, not the repo root. New dotfiles go under `chezmoi/home/` or `chezmoi/dot_config/`.
- **Per-machine overrides go in `~/.bashrc.local` on each host** — un-tracked, sourced last by the templated bashrc.
- **`wezterm.lua` is chezmoi-tracked but NOT deployed to `%USERPROFILE%`.** The chezmoi source at `chezmoi/dot_config/wezterm/wezterm.lua` is the canonical file, and `.chezmoiignore.tmpl` skips `dot_config/wezterm` on Windows so chezmoi never writes a copy under `%USERPROFILE%\.config\wezterm\`. Instead, `bootstrap.ps1` sets a User-scope environment variable **`WEZTERM_CONFIG_FILE`** pointing at the chezmoi source path — WezTerm reads the repo file directly. `automatically_reload_config` still picks up edits live (including from `manage-hosts.ps1 -Sync` rewriting the sentinel block). This replaces the pre-v2 hardlink hack, which broke whenever chezmoi atomic-wrote the target on a content mismatch. If a user ever unsets `WEZTERM_CONFIG_FILE`, WezTerm falls back to its default search path — `bootstrap.ps1` also cleans up the legacy home-path copy on each run so a stale fallback can't silently win.
- **Only two valid host groups: `dev_machine` and `prod_machine`.** Both `manage-hosts` scripts validate the group on `--add`/`--edit` and reject anything else. The group is the input to `MODE` derivation (dev_machine → MODE=dev, prod_machine → MODE=prod) — `scripts/update-hosts.sh` reads each host's group column and passes the matching `MODE` to its remote `make provision`. Add a third group only if you also extend `makefile/scope.mk` and `update-hosts.sh`'s case branch.
- **User-facing changes get mirrored into `README.html`** in the same commit (see the section above for what counts). There is no `README.md` — `README.html` is the only user-facing reference, opened in a browser from the local clone.

## Daily workflows

> **Migrating from the Ansible era?** Quick mapping:
> - `ansible-playbook playbooks/local.yml -e "@group_vars/dev_machine.yml" --ask-become-pass` → `make -C makefile MODE=dev provision` (or run `bootstrap.sh --dev`).
> - `ansible-playbook playbooks/linux.yml --limit dev_machine --ask-become-pass` → `./scripts/update-hosts.sh --group dev_machine`.
> - `ansible-playbook --check` → `make -n MODE=… provision` (Make's dry-run mode; prints the recipe lines without running them).
> - `pip install ansible-core` → not needed; `bootstrap.sh`'s preflight no longer checks for Python.

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

Provisioning — local (self-provisioning; same flow `bootstrap.sh` uses):
```bash
cd makefile
make MODE=prod provision                      # user scope (no sudo, ~/.local/bin)
make MODE=dev provision                       # system scope (sudo, /usr/local/bin)
make dev / make prod                          # friendly aliases for the above
make -n MODE=dev provision                    # dry-run: print recipe lines
make <tool> MODE=dev                          # single tool, e.g. make gitui MODE=dev
make clean-<tool> MODE=dev                    # wipe stamp (+ binary for scope tools)
make list MODE=dev                            # list every managed tool, grouped
```

Provisioning — remote (control machine, targets every managed host):
```bash
./scripts/update-hosts.sh                            # every host in hosts.conf
./scripts/update-hosts.sh --group dev_machine        # just dev hosts
./scripts/update-hosts.sh --group prod_machine       # just prod hosts
./scripts/update-hosts.sh --name dev-cache-qa1       # one specific host
./scripts/update-hosts.sh --check                    # print actions, don't ssh
./scripts/update-hosts.sh --parallel 1               # serialise (default 4)
```
MODE per host comes from its group column in `hosts.conf` (dev_machine → MODE=dev, prod_machine → MODE=prod). The script runs `git pull && make MODE=<derived> provision` on each match in parallel via `xargs -P`; per-host status is printed live and a final summary tells you how many succeeded.

Adding a host:
1. On the new host: `git clone … && ./bootstrap.sh --prod` (or `--dev` for sudo). Self-registration appends to `hosts.conf` under `prod_machine` or `dev_machine`, regenerates the wezterm sentinel block, commits, and pushes.
2. From the Windows host or another machine, `git pull` and run `--sync` (or commit and push from the host, then pull elsewhere) so the `chezmoi/dot_config/wezterm/wezterm.lua` block updates. On Windows, also run `chezmoi apply` (or the `cza` alias) to push the new wezterm config into `%USERPROFILE%\.config\wezterm\`. (Actually wezterm reads the chezmoi source directly via `WEZTERM_CONFIG_FILE` — no apply needed for that one file.)

Adding a tool:
1. Add `<NAME>_VERSION := X.Y.Z` to `makefile/versions.mk`.
2. Add one `$(eval $(call …,…))` line to `makefile/tools.mk` — **pick `EGET_TOOL` first**; only fall back to a direct helper for the cases eget can't handle.

   **`EGET_TOOL` — preferred for single-binary GitHub releases (~38 of the current 56 tools).**
   ```makefile
   $(eval $(call EGET_TOOL,<name>,<version>,<user/repo>[,<tag>][,<extra eget args>]))
   ```
   - `<tag>` defaults to `v$(version)`. Override for non-`v` tags (delta uses `0.19.2`, gping uses `gping-v1.20.1`).
   - `<extra eget args>` are forwarded to eget. Common ones:
     - `--asset musl` when upstream publishes both gnu+musl (we prefer musl for static linking)
     - `--asset .tar.gz` when upstream publishes the same binary in multiple archive formats (mise has 4; fastfetch has both `.tar.gz` and `.zip`)
     - `--asset static` for the static-linked variant (micro, usql)
     - `--asset 64bit` for repos using non-standard arch tokens (croc)
     - `--asset '^<pattern>'` to anti-match (atuin excludes `server` + `update`)
     - `--all` for archives containing only the binaries we want and nothing else (ast-grep, uv — `sg`/`ast-grep` and `uv`/`uvx` respectively)
   - `lib/eget.sh` already bakes in anti-matches for the common noise: `.sbom .sig .sha .asc .zip.gpg .deb .rpm .apk .pkg .proof`.

   **`TOOL` — direct helper. Use when EGET_TOOL doesn't fit:**
   - `$(LIB)/archive.sh <binary[:other:…]> <url>` for tar.gz/bz2/xz/zip. Used for non-GitHub URLs (ncdu) and multi-binary archives that contain LICENSE/completion files alongside the binaries (age has 5 files; yazi has a completions/ dir — `--all` would install all of them).
   - `$(LIB)/direct.sh <name> <url>` for raw binary URLs (jq, broot, sops, lazyjournal, sysz, ssh-copy-id, nb).
   - `$(LIB)/pipe.sh <name> <url> [-- <installer args>]` for upstream `curl | sh` installers (chezmoi takes `-b $(DEST)`).
   - `$(LIB)/helix.sh <version>` for helix specifically (binary + runtime tree; multi-file install).

   **`USER_TOOL` — pip user-site, never under sudo.** Used by `make user-tools`. Currently just glances/asciinema/harlequin.

3. Test before pushing: `cd makefile && make <name> MODE=prod DEST=/tmp/test STAMP=/tmp/test-stamps`. Re-run should be a no-op (no `==>` line). For multi-binary tools verify every binary lands in `/tmp/test/`. For EGET_TOOL tools, ensure `GITHUB_TOKEN` is set or you'll hit eget's unauthenticated rate limit after ~30 tool installs.
4. If the tool has user-facing CLI surface, mention it in `README.html` (see "README.html must mirror user-facing changes").

## Files Claude should be careful with

- `chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block — auto-gen between `-- HOSTS:START` / `-- HOSTS:END` sentinels by both manage-hosts scripts. Edit anywhere outside the sentinels freely. On Windows, edits to this file appear in WezTerm immediately because `bootstrap.ps1` sets `WEZTERM_CONFIG_FILE` to point at this file directly; on Linux hosts without WezTerm the file is ignored by chezmoi.
- `hosts.conf` — edit via the manage-hosts scripts when possible; manual edits work but lose dynamic padding (and sort order) until next save. Column 4 (group) must be `dev_machine` or `prod_machine` — the manage-hosts scripts reject anything else on save, and `scripts/update-hosts.sh` can't derive a `MODE` from any other value.
- `.chezmoiroot` — one-line file at the repo root containing `chezmoi`. Required for chezmoi's source state to point at the `chezmoi/` subdirectory; without it, all `dot_*` paths break. Don't delete or edit.
- `bootstrap.sh` — keep it a thin seed. It must NOT contain per-tool versions or install logic. Tool versions live only in `makefile/versions.mk`; install logic lives only in `makefile/tools.mk` + `makefile/lib/*.sh`. Scope values (`DEST`, `SUDO`, `HAS_SUDO`, `INSTALL_PACKAGES`) must NOT be inlined — they come from `makefile/scope.mk` via `MODE=dev|prod`. If `bootstrap.sh` and `scope.mk` ever disagree on scope, fix `scope.mk`.
- `makefile/Makefile` and `tools.mk` — the install machinery. The Makefile defines three macros (`TOOL`, `USER_TOOL`, `EGET_TOOL`) plus a bespoke `claude-cli` rule; `tools.mk` is the per-tool data file. Recipe lines in the Makefile MUST be tab-indented (not spaces) — Make is strict. Macro bodies use `$$` to defer variable expansion to rule-fire time; don't switch to single `$` without testing. **EGET_TOOL adds an order-only dep on `$(STAMP)/eget-$(EGET_VERSION).done` to the per-tool stamp rule** — this is load-bearing under `make -j`. The first attempt put the dep on the phony target and Make resolved the stamp directly, bypassing the order; if you ever refactor the macro, preserve the stamp-on-stamp dependency or parallel builds will race.
- `makefile/scope.mk` — single source of truth for MODE → DEST/SUDO/HAS_SUDO/INSTALL_PACKAGES. Errors at parse time if `MODE` is missing — that's intentional; don't add a default. The `$(SUDO)` thread through `Makefile`'s `TOOL` macro depends on this file resolving cleanly.
- `makefile/{packages,shell,dotfiles}.mk` — replace the old Ansible task files one-for-one. `packages.mk` is the only one that does anything when `MODE=prod` (where it's a no-op). `shell.mk` branches on `HAS_SUDO`. `dotfiles.mk` is gated on `~/.config/chezmoi/chezmoi.toml` existing — first-run init is bootstrap.sh's job.
- `makefile/versions.mk` — single source of truth for tool versions. Variables are uppercase (`FZF_VERSION`, `GITUI_VERSION`, etc.) and consumed by URL templates / repo paths in `tools.mk`. Use `latest` for tools that have no upstream version pin (broot, nb, pip packages). **`EGET_VERSION` pins the eget meta-installer itself** — bumping it triggers a fresh eget install via archive.sh, which then runs all the EGET_TOOL-registered installs.
- `makefile/lib/eget.sh` — wrapper that bakes in the `--to $DEST --quiet` flags plus a long anti-match `--asset '^…'` filter list (`.sbom .sig .sha .asc .zip.gpg .deb .rpm .apk .pkg .proof`). When upstream adds a new noise file type that breaks asset auto-detection (e.g. `.tar.zst.sbom`), add it to this list rather than per-tool. Pass-through `$@` carries per-tool extras from the macro's 5th arg.
- `makefile/lib/*.sh` and `scripts/update-hosts.sh` — install/orchestration helpers. All shell scripts here MUST remain LF-only (same trap as `manage-hosts.sh`); `file makefile/lib/archive.sh` should say "Bourne-Again shell script", NOT "with CRLF line terminators". Repair with `sed -i 's/\r$//' makefile/lib/*.sh scripts/update-hosts.sh`. **Executable bit:** the lib scripts must be mode 100755 in git (`git ls-files --stage makefile/lib/`); a fresh clone with mode 100644 will fail with `sudo: ... archive.sh: command not found`. Restore with `git update-index --chmod=+x makefile/lib/*.sh`.
- `chezmoi/.chezmoiignore.tmpl` — wrong entries here cause `chezmoi apply` to drop infrastructure files into `$HOME` (or to skip files you wanted applied). Edit-then-test: `chezmoi diff` on a sandbox host/Windows machine before pushing.
- `scripts/manage-hosts.ps1` and `bootstrap.ps1` **must remain UTF-8 with BOM**. PowerShell 5.1 (Windows PowerShell, the default `powershell.exe`) reads scripts as Windows-1252 unless a BOM is present, and both files contain Unicode glyphs (`✓`, `✗`, `─`) used in colored output. Without the BOM, PS 5.1 mis-decodes the multi-byte UTF-8 and the script fails to parse with cryptic "string missing terminator" errors. To restore the BOM after a tool overwrites it: `[System.IO.File]::WriteAllText($path, [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path)), [System.Text.UTF8Encoding]::new($true))`.
- `scripts/manage-hosts.sh` **must remain LF-only**. The Edit/Write tools on Windows tend to save with CRLF; the resulting file runs but `read -r` then leaks `\r` into parsed fields, polluting downstream regeneration. After any edit, verify with `file scripts/manage-hosts.sh` (expect "Bourne-Again shell script", no "with CRLF line terminators"). Repair with `sed -i 's/\r$//' scripts/manage-hosts.sh`.

## Quick verification

After changes:
- `./scripts/manage-hosts.sh --sync` — regenerates the chezmoi-tracked wezterm sentinel block, no errors.
- `cd makefile && make list MODE=dev` — should show every managed tool grouped by target: 56 scope-tools (incl. `eget` itself), 3 user-tools, plus claude-cli. If a tool isn't listed, its `$(eval $(call …,…))` line in `tools.mk` didn't expand — usually because the `<NAME>_VERSION` variable referenced in the call wasn't defined in `versions.mk`.
- `cd makefile && make -n MODE=prod provision` — dry-run the full provision flow. Should print "skipping system packages (MODE=prod, INSTALL_PACKAGES=false)" then the sequence of tool installs.
- `cd makefile && make -n MODE=dev provision` — dry-run dev scope. Should print the dnf install lines (under `sudo`), then EPEL, then optional packages, then the tool installs.
- `cd makefile && make help` (with or without MODE) — shows the top-level targets. Help-only commands don't trigger `scope.mk`'s error-out.
- `cd makefile && make -j8 all MODE=prod DEST=/tmp/install-test HELIX_RUNTIME_DEST=/tmp/helix-rt STAMP=/tmp/install-test-stamps` — full sandbox install. Should finish in 25-30s on a reasonable connection; `ls /tmp/install-test | wc -l` ≈ 60 (the extras are the multi-binary companions: `age-keygen`, `sg`, `ya`, `uvx`, plus `eget` itself). Re-running the same command should be a sub-second no-op. **Set `GITHUB_TOKEN`** before running or eget will hit the unauthenticated 60-req/hour API limit partway through (~30 tools is enough to exhaust it).
- `./scripts/update-hosts.sh --check --group dev_machine` — prints the planned action for each dev host without ssh'ing. Should derive MODE=dev correctly.
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
