# Single mode: one workstation setup for every host

Date: 2026-10-06. Status: approved in conversation; this file is the written spec.

## Why

The repo provisions hosts in one of two modes, owned or shared, chosen by a prompt and
saved per host. Managing two modes is a pain: two token sets, five config files and three
lock files encode the split, and every change has to reason about both. Every host is now
owned (there are no shared hosts), and hosts are set up deliberately, so the safety of a
minimal mode isn't needed.

## Goal and success criteria

One setup for every host:

- No mode prompt, no saved `mode`, no `WORKSTATION_MODE`.
- Three config files (`config.toml`, `config.linux.toml`, `config.windows.toml`) plus the
  git-ignored `config.local.toml`; two lock files (`mise.lock`, `mise.linux.lock`).
- Token sets are the OS only: `linux` or `windows`.
- Every Linux host gets what an owned host gets today; Windows is unchanged.
- The steps that need sudo run when sudo is available and are skipped, with a clear
  warning, when it isn't. Nothing to choose or remember.
- No tool version, dotfile content or installed behaviour changes on existing hosts.

Non-goals: changing the toolbelt, the dotfiles, Windows provisioning, the disk check's
logic, or the EL8/EL9 support work.

## 1. Config layout and token sets

| File | Loads on | Holds |
|---|---|---|
| `config.toml` | every host | today's `config.toml` + all of `config.owned.toml` (node, go, LSP servers, `~/.claude` dotfiles, opencode, omp, the fonts tool, Windows-only nushell/carapace/dnGrep/LogExpert with their `os = ["windows"]`) |
| `config.linux.toml` | Linux | today's `config.linux.toml` + all of `config.host.toml` (dnf batch, `/etc/wsl.conf`, `pre-packages`/`post-packages`/`final` hooks, gdb/herdr/zed dotfiles, `statusline`/`enable-el-repos` tasks) |
| `config.windows.toml` | Windows | unchanged |
| `config.local.toml` | every host, git-ignored | name, email, the saved `sudo` result, overrides; no `mode` |

- `scripts/lib/mise-env.sh` takes no argument and writes `miserc.toml` with `env = ["linux"]`;
  `bootstrap.ps1` writes `env = ["windows"]`. mise selects the OS file only through this token.
- `mise.owned.lock`'s entries move into `mise.lock`, regenerated with `mise lock` (never hand-
  edited). Dependency-lock sidecars under `locks/mise.owned/` move to `locks/mise/`.
- `[bootstrap.*]` and `[dotfiles]` tables still merge by union, and each item is declared once.

## 2. Sudo detection

`bootstrap.sh` decides once, just before `mise bootstrap`:

1. `sudo -n true` succeeds (cached credentials or NOPASSWD): sudo is available.
2. Otherwise, with a terminal, `sudo -v` prompts once (it also covers mise's own sudo calls for
   the rest of the run). Success: available. Failure (not a sudoer, wrong password, Ctrl-C):
   not available.
3. No terminal (unattended run, SSH without `-t`): skip the system steps for this run only and
   save nothing, so the next run from a terminal decides again.

The result of a real check (1 or 2) is saved in `config.local.toml` `[vars]` as
`sudo = "yes"` or `sudo = "no"`. A missing value means yes.

- yes: `bootstrap.sh`, `mise run update` and `wsu` run `mise bootstrap` as owned hosts do today;
  mise asks for sudo only when there is system work (a new package, a changed `/etc` file).
- no: they run `mise bootstrap --skip packages,files` and skip the login-shell change.

Skipped without sudo: the dnf batch, the EPEL/CRB hook, the best-effort `bear` step, `/etc/wsl.conf`,
zsh as login shell. Still run: every mise tool, the dotfiles, the pueued user service, vcpkg,
Claude Code, fonts.

When it skips, the bootstrap prints what was skipped and how to apply it later (get sudo, re-run
`./bootstrap.sh`, which re-checks). `mise run health` gains a "system steps" row (applied, or
skipped and why).

## 3. Removing the mode

- `bootstrap.sh`: drop `valid_mode`, `prompt_mode`, the mode half of `resolve_host_config`,
  `WORKSTATION_MODE` and its usage text. First-time setup still asks for name and email once.
  `--reinstall` keeps working without re-asking a mode. The login-shell change (sudo-gated) and
  the ccstatusline offer run on every Linux host.
- `tasks/update`: no valid mode required.
- `bootstrap.ps1`: stops writing `mode = "owned"`; its guard checks that `config.windows.toml`
  loads (it guarded `config.owned.toml`, whose tools now live in the always-loaded `config.toml`).
- `zshrc.tera`/`bashrc.tera`: the vcpkg block loses its `vars.mode == "owned"` condition.
- `mise run health`: drop the mode row; the miserc row compares against the OS token; the Claude
  Code, vcpkg and fonts rows apply on every Linux host; add the "system steps" row.
- `.claude/hooks/session-context.sh`: reports the token set and the sudo status, not a mode.
- An exported `WORKSTATION_MODE` is ignored, with a one-line note.

## 4. Migrating existing hosts

All hosts are owned today, so what they install doesn't change. On a host's next update:

1. The pull brings the new layout (owned and host files folded in, `mise.owned.lock` merged).
2. Linux: `mise run update` rewrites `miserc.toml` to `linux` before any mise call. Windows:
   `wsu` doesn't write `miserc.toml`; the old `windows,owned` keeps working (the `owned` token
   names a missing file, which mise ignores) until `bootstrap.ps1` writes `windows`. A host not
   yet updated (`linux,owned,host`) also keeps working, since `config.toml` and
   `config.linux.toml` now hold everything.
3. No saved `sudo` value on existing hosts means yes, so updates behave exactly as today.
4. The next bootstrap or update drops the stale `mode = "owned"` line from `config.local.toml`
   (a one-time cleanup, like the old `MISE_ENV` export cleanup).
5. Versions don't change. A pypi tool whose dependency-lock sidecar moves (basedpyright) may
   reinstall once if mise's install key includes the sidecar path.
6. `atc-cache-dev10` isn't fully set up yet; its next bootstrap uses the new flow.
7. `disk-budget.toml` keys become `linux` and `windows`; the readers change in the same PR.

## 5. Checks, tests, docs

- `check-invariants.sh`: lock coverage over two locks and `locks/mise/`; replace the
  "host-state file declares no `[tools]`" rule with "`dnf:` packages and `[bootstrap.files]` only
  in `config.linux.toml`; `winget:` only in `config.windows.toml`"; token strings become `linux`
  and `windows` (also in `bump-versions.sh`, `check-templates.sh` with 2 sets, and the bootstrap-
  plan check). New check: no template or script reads `vars.mode`, and `mise-env.sh` emits only
  `linux` or `windows`.
- `scripts/test-bootstrap-mode.sh` becomes `scripts/test-bootstrap.sh`: sudo-detection cases with a
  stubbed `sudo` (no password needed; prompt succeeds; prompt fails, saving `no` and skipping;
  no terminal, skipping without saving; saved yes; saved no; missing means yes), plus the cases
  that still apply (the `config.local.toml` writer, the name/email prompt, CRLF handling, the
  `--reinstall` confirmation).
- Windows tests (`test-mise-env.ps1`, `test-config-local.ps1`): no mode writes, `miserc` is
  `windows`, the guard checks `config.windows.toml`. `test-mise-install.sh`: `MISE_ENV=linux`,
  the `linux` budget key.
- Disk budget: `disk-budget.yml` runs one Linux job (key `linux`) and the Windows job (key
  `windows`); `scripts/lib/mise-install.sh` and `bootstrap.ps1` read those keys.
- `scripts/gen-tool-memory.sh`: the TOOLS block's headings follow the new files.
- Docs: README drops the owned/shared sections and the mode-change guide and gains a short
  "System steps and sudo" section; layout tables shrink to three files. CLAUDE.md layout, token
  sets and invariants follow (it gets shorter). Also `docs/claude/verification.md`, the
  `workstation` cheat sheet, the LSP skill's note, and the machine-memory text around the TOOLS
  block.

## Verification

Before merge: `mise run lint`, `check-templates.sh`, the bash suites, the PowerShell suites on 5.1
and 7, a fresh isolated `MISE_ENV=linux` install of all tools with `verify-tools` (also at the
glibc 2.28 floor), a dry-run `mise bootstrap plan`, and CI including the disk-budget run.

After merge: `mise run update` here (miserc becomes `linux`), `wsu` and `bootstrap.ps1` on Windows,
and the bootstrap on `atc-cache-dev10`.

Delivery: one PR, implemented task by task from a written plan.

## Risks

- A no-sudo host with a TTY whose first check failed saves `sudo = "no"`; it stays skipped until
  `./bootstrap.sh` is re-run with sudo. Intended, and stated in the warning and the health row.
- `mise bootstrap --skip packages,files` must also skip the packages-phase hooks
  (`pre-packages`/`post-packages`); the plan verifies this with `mise bootstrap plan` before
  relying on it.
- Moving dependency-lock sidecars may reinstall basedpyright once (a few hundred MB).
