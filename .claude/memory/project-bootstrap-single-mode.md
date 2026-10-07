---
name: project-bootstrap-single-mode
description: "Since the single-mode PR (2026-10-07, branch feat/single-mode) there is no owned/shared mode: every host gets one setup, token sets are the OS only (`linux`, `windows`), and bootstrap.sh decides sudo once and saves it as vars.sudo. Never reintroduce a mode, a mode prompt, WORKSTATION_MODE, --dev/--prod or a group key."
metadata:
  type: project
---

History: `--dev`/`--prod` and `vars.group` became an owned/shared mode on 2026-09-25 (PR #3), saved as `vars.mode` and mapped to token sets `linux,owned,host` / `linux` / `windows,owned`. The user then merged the two modes (spec `docs/superpowers/specs/2026-10-06-single-mode-design.md`): "managing it is a pain and the workstation setup is going to be done carefully anyway"; no host ran shared.

**Now:**
- Three config files: `config.toml` (every host; absorbed `config.owned.toml`), `config.linux.toml` (Linux; absorbed `config.host.toml`: dnf batch, `/etc/wsl.conf`, packages-phase and `final` hooks), `config.windows.toml`. Locks `mise.lock` + `mise.linux.lock`; mise.lock's sidecars sit at `locks/<tool>/<ver>` (mise's naming for the root lock), mise.linux.lock's at `locks/mise.linux/`.
- `scripts/lib/mise-env.sh [--write]` emits `linux`; `bootstrap.ps1` writes `windows`. Old miserc token sets (`linux,owned,host[,wsl]`, `windows,owned`) still load correctly: mise ignores token files that don't exist.
- Sudo: `bootstrap.sh`'s `resolve_system_steps` → `detect_sudo` (0 yes: `sudo -n true` or a `sudo -v` prompt that succeeds; 1 no: no binary, wrong password, or Ctrl-C, trapped with `trap ':' INT` around `sudo -v` only; 2 undecided: no terminal). 0/1 are saved as `vars.sudo = "yes"|"no"`; 2 skips this run only. Missing means yes. `sudo = "no"` → `mise bootstrap --skip packages,files` (also skips the `pre-packages`/`post-packages` hooks) and no `set_login_shell`. `tasks/update` (`wsu`) never asks; it reads `sudo_state`.
- No migration code: the stale-`mode` cleanup shipped in #30 was removed once every host had run it (a leftover `mode` line is inert: nothing reads it). See [[feedback-no-migration-code]].
- Guards: `check_no_mode` (scripts/check-invariants.sh) fails on any template/script/task reading a mode; tests in `scripts/test-bootstrap.sh` (stub sudo: S1–S7, T1, U1/U2) and `scripts/test-config-local.ps1`.
- `--reinstall`, `--yes`, `-h` remain; `--reinstall` wipes `config.local.toml` (name, email, sudo), which are asked/decided again.

**How to apply:**
- Never reintroduce a mode, a second Linux token, `WORKSTATION_MODE`, `--dev`/`--prod`, or a `group` key. A host without sudo is handled by `vars.sudo`, not by a smaller setup.
- New sudo-needing state (dnf packages, `/etc` files) goes only in `config.linux.toml` (`check_mise_config_files` enforces it), so `--skip packages,files` covers it.
- A host stuck with `sudo = "no"` re-checks by re-running `./bootstrap.sh` from a terminal with sudo.
- Related: [[feedback-sudo-not-passwordless]], [[project-hosts-list-removed]].
