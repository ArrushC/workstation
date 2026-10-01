---
name: project-bootstrap-owned-shared
description: "The --dev/--prod flags and vars.group are gone (2026-09-25) — bootstrap.sh now resolves an owned/shared mode (saved vars.mode in config.local.toml, else WORKSTATION_MODE, else an interactive /dev/tty prompt) and the dev MISE_ENV token is renamed owned (config.dev.toml -> config.owned.toml, mise.dev.lock -> mise.owned.lock). Windows is always owned. The chezmoi/Make migration code (tasks/migrate-legacy, relocate_repo, ensure_config_local's chezmoi.toml migration, the vars.group repair) is deleted entirely."
metadata:
  type: project
---

`bootstrap.sh --dev`/`--prod` are gone. Every host is now `owned` (your machine — sudo, host packages, zsh login shell, the full toolbelt) or `shared` (someone else's — no sudo, user-level toolbelt only); same semantics as the old dev/prod, new name.

**Resolution order** (`resolve_host_config()` in `bootstrap.sh`): (1) the saved `mode` line under `[vars]` in the host's git-ignored `config.local.toml`; (2) else the `WORKSTATION_MODE` env var (`owned`/`shared`), for an unattended first run such as `curl … | WORKSTATION_MODE=shared bash`; (3) else an interactive prompt on `/dev/tty` (`open_prompt_fd`/`prompt_mode`), which still works under `curl | bash`; (4) else `bootstrap.sh` fails and prints both ways to answer. The chosen mode is written back to `config.local.toml` so later runs don't ask again. Name/email are asked once on the same first run; without a terminal they're left unset with a warning, not blocked. To change a host's mode: edit or delete the `mode` line in `config.local.toml`, then re-run `./bootstrap.sh`.

**Windows is always owned.** `bootstrap.ps1`'s `Invoke-EnsureConfigLocal` (built on the new `Set-ConfigLocalVar` helper) always writes `mode = "owned"` to `config.local.toml` and never prompts for it — there is no shared mode on Windows.

**Token rename:** the `dev` `MISE_ENV` token is renamed `owned` throughout — `scripts/lib/mise-env.sh <owned|shared>` now prints `linux` (shared), `linux,owned,host,wsl` / `linux,owned,host,native` (owned Linux, WSL vs native), or is combined with `windows` as `windows,owned` for the one Windows host. `config.dev.toml` → `config.owned.toml`; `mise.dev.lock` → `mise.owned.lock`; `locks/mise.dev/` → `locks/mise.owned/`. (Since PR 3 the token set is persisted in the git-ignored `miserc.toml` by `mise-env.sh --write`; the rc templates and `10-mise.conf.tera` no longer export `MISE_ENV`.)

**Remaining `bootstrap.sh` flags:** `--reinstall` (now confirms on the terminal via `/dev/tty`, so `curl … | bash -s -- --reinstall` works interactively), `--yes`/`-y` (skips that confirmation), `-h`/`--help`. `--doctor`/`--check-for-updates` were removed on 2026-09-30 in favour of `mise run health`/`mise run check-updates`. `--reinstall` wipes the whole cloned repo, including `config.local.toml` — so the mode (and name/email) is asked again on the next run.

**Migration code is deleted entirely, not just renamed:** the chezmoi/Make migration path, `tasks/migrate-legacy` (the one-time pre-mise `/usr/local/bin` sweep), `relocate_repo` (the old chezmoi-checkout relocation), the `vars.group` presence-repair (`repair_config_local_group`), and `ensure_config_local`'s chezmoi.toml migration are all gone. What replaced `ensure_config_local()` is `resolve_host_config()` (Linux) / `Invoke-EnsureConfigLocal` (Windows) — mode + name/email only, no legacy-host detection. `--force-dotfiles` is still passed automatically on a host's FIRST dotfiles apply (the `~/.local/state/workstation/dotfiles-migrated` marker still gates it, kept under its old name so existing hosts don't force again) — but call it the "first-apply marker" now, not a migration: it exists because a pre-existing file (e.g. `/etc/skel`'s `~/.bashrc`) can occupy a target, not because of chezmoi.

**bootstrap.sh function renames:** `run_bootstrap` → `apply`; `set_default_shell` → `set_login_shell` (now owned-hosts-only — shared hosts get no login-shell change or `chsh` hint at all, since they have no sudo to attempt it with). New: `clone_or_update_repo`, `print_next_steps`, `confirm_reinstall`, `usage`.

**New tests:** `scripts/test-bootstrap-mode.sh` (offline, wired into `check-invariants.sh`) covers the resolution order above; `scripts/test-config-local.ps1` covers the Windows side (CI's `windows-http` job, PS 5.1 + pwsh).

**`wsu` / health guard:** `tasks/update` refuses without a valid `vars.mode` and rewrites `miserc.toml` from it (and unsets any exported `MISE_ENV`) before `mise install`/`mise prune`, so a stale shell env can't prune the owned tools; `tasks/health` flags a missing mode and compares `miserc.toml` against the expected token set derived from it.

**Rollout (done 2026-09-27, PR #3 → `3c67f89`):** the WSL host and the Windows host both run `mode = "owned"`. On each, the `group = "dev_machine"` line was replaced by `mode = "owned"`, the checkout pulled, then the NEW bootstrap run (WSL needed no sudo: every package was already installed). WSL health: 15 ok, 0 problems; Windows `-Doctor`: no ✗. Any other existing host (e.g. the native dev host, prod hosts) is still unmigrated.

**How to apply:**
- Never reintroduce `--dev`/`--prod` flags, a `group` key, or `dev_machine`/`prod_machine` values — the mode lives in `vars.mode` (`owned`/`shared`) only, resolved by a prompt/env var, never a flag.
- Migrating a remaining host: set `mode = "owned"`/`"shared"` in its `config.local.toml`, `git -C ~/.config/mise pull --ff-only`, then run the NEW `~/.config/mise/bootstrap.sh`. Never `wsu` first — the old `tasks/update` runs the new `mise-install.sh` under the stale `linux,dev,…` env and `mise prune` drops the owned tools. Alternatively bootstrap fresh with `curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --reinstall` (the curl form, so the NEW script runs; it wipes the repo and `config.local.toml`, so the mode is asked again).
- `tasks/health` and `.claude/hooks/session-context.sh` report `mode=owned|shared` now, not a dev/prod group.
- Related: CLAUDE.md (the rulebook; the old `vars.group` gap this supersedes), [[project-hosts-list-removed]], [[feedback-sudo-not-passwordless]].
