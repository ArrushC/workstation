# Bootstrap cleanup: prompted owned/shared mode, migration code removed, single-file refactor

Date: 2026-09-25 · Status: approved in brainstorming, pending spec review

## Goal

Replace `bootstrap.sh`'s required `--dev` / `--prod` flag with a mode that is
chosen by input (not a flag) and named generically, rename the dev/prod
vocabulary through the whole repo, delete the one-time chezmoi/Make → mise
migration code, and refactor both bootstrap scripts for readability — while
each stays a single self-contained file that works as a `curl … | bash` /
`curl.exe` one-liner.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Mode names | `owned` (your machine: sudo, full install) / `shared` (someone else's: no sudo, user-level toolbelt only). Same split as today's dev / prod. |
| Rename depth | Through the whole repo: token `dev` → `owned`, `config.dev.toml` → `config.owned.toml`, `mise.dev.lock` → `mise.owned.lock`, `locks/mise.dev/` → `locks/mise.owned/`. `host`, `wsl`, `native`, `linux`, `windows` tokens unchanged. |
| How the mode is supplied | Saved `vars.mode` → `WORKSTATION_MODE` env var → interactive prompt on `/dev/tty` → otherwise fail with instructions. |
| Windows | Never prompts; always `owned` (`MISE_ENV=windows,owned`, writes `vars.mode = "owned"`). |
| Cleanup scope | Mode rework + delete migration code + refactor, each script still one file. |
| Comments | Short why-comments only; incident narratives, fix-wave labels (I6, C1, Task 5, PR3) and dated verification stories removed (history stays in git, CLAUDE_CHANGELOG.md, docs/claude/). |

## 1. Mode model and resolution

- `config.local.toml` (git-ignored, per host) `[vars]` holds `name`, `email`,
  `mode`. The `group` key (`dev_machine` / `prod_machine`) is retired.
- `bootstrap.sh` resolves the mode in this order:
  1. **Saved** `vars.mode` in `config.local.toml` → used as-is; prints
     `mode: owned (saved in config.local.toml)`. Never prompts again (and
     `wsu` never involves the mode at all).
  2. **`WORKSTATION_MODE=owned|shared`** → used and saved. Any other value is
     rejected with a clear message.
  3. **Prompt** on `/dev/tty` (works under `curl | bash`):
     ```
     Is this host yours?
       1) owned    my machine — sudo, full install
       2) shared   someone else's — no sudo,
                   user-level toolbelt only
     Choose [1/2]:
     ```
     The first-run `name` / `email` prompts happen in the same step.
  4. **No saved mode, no variable, no terminal** → fail:
     ```
      ✗ No terminal to ask the setup mode on.
        Re-run interactively:  ssh -t <host> '...'
        or answer up front:    WORKSTATION_MODE=shared
     ```
- Changing a host's mode later: edit or delete `mode` in `config.local.toml`
  and re-run `bootstrap.sh`. No flag.
- `--reinstall` deletes the checkout, and `config.local.toml` lives inside it,
  so a reinstall asks for name / email / mode again (or reads
  `WORKSTATION_MODE`). Intended: a reinstall is a from-scratch setup.
- Remaining `bootstrap.sh` flags: `--reinstall`, `--yes`, `--doctor`,
  `--check-for-updates`, `--help`. `--dev`, `--prod`, `--full` are removed.
  `--doctor` / `--check-for-updates` read the saved mode and never prompt;
  with no saved mode, `--doctor` reports "mode not set".
- Mode semantics are unchanged from dev / prod: `owned` = full install
  (the owned tool layer + `config.host.toml` host state: dnf packages, `/etc`
  files, services, zsh as login shell via sudo); `shared` = base toolbelt,
  user-level, no sudo.

## 2. Rename map

| Today | After |
|---|---|
| `bootstrap.sh --dev` / `--prod` | the prompt (§1) |
| `vars.group = "dev_machine"` / `"prod_machine"` | `vars.mode = "owned"` / `"shared"` |
| `scripts/lib/mise-env.sh dev\|prod` | `scripts/lib/mise-env.sh owned\|shared` |
| `MISE_ENV` `linux,dev,host,wsl` / `linux,dev,host,native` | `linux,owned,host,wsl` / `linux,owned,host,native` |
| `MISE_ENV` `linux` (prod) | `linux` (shared), unchanged |
| `MISE_ENV` `windows,dev` | `windows,owned` |
| `config.dev.toml` | `config.owned.toml` |
| `mise.dev.lock`, `locks/mise.dev/` | `mise.owned.lock`, `locks/mise.owned/` — regenerated with `mise lock --global` (+ sidecar normalization), never hand-renamed |
| "dev_machine only" / "prod" wording (README, CLAUDE.md, docs/claude, badges, comments) | "owned hosts only" / "shared" |

Consumers to update: the three MISE_ENV-baking templates (`dotfiles/zshenv.tera`,
`dotfiles/bashrc.tera`, `dotfiles/config/environment.d/10-mise.conf.tera` —
condition becomes `vars.mode is defined and vars.mode == "owned"`), the zsh /
bash completions for `bootstrap.sh`, `scripts/check-invariants.sh` (three-way
render check uses `vars.mode` owned/shared; every `config.dev.toml` / token
reference), `scripts/check-templates.sh` (four env sets), `scripts/bump-versions.sh`
(lock env sets), `scripts/gen-tool-memory.sh` (section heading), the Claude
hooks (`session-context.sh`, `parity-reminder.sh`, `test-hooks.sh`),
`tasks/health`, `scripts/setup-ccstatusline.sh`, `scripts/lib/mise-install.sh`,
CI (`.github/workflows/*.yml`), `bootstrap.ps1`, the Windows profile templates
where they mention the token, the cheat sheet, `dotfiles/claude/*`, README,
CLAUDE.md, docs/claude/*, CLAUDE_CHANGELOG.md, project memory.

## 3. Deleted: migration code

`bootstrap.sh`:
- `relocate_repo` and every `LEGACY_REPO_DIR` path (reinstall, doctor, repo checks).
- The `chezmoi.toml` name/email/group import; `repair_config_local_group`.
- Legacy `pueued.service` retirement; chezmoi-state removal in `--reinstall`;
  the `--full` rejection; the closing "replace this shell — /usr/local binaries
  were swept" warning.

`bootstrap.ps1`:
- `Get-LegacyChezmoiIdentity`, `Test-ConfigLocalHasGroup`, `Repair-ConfigLocalGroup`.
- The `~\.local\share\chezmoi` relocation in `Invoke-CloneRepo`.
- The chezmoi-state sweep in `Invoke-Reinstall`, the portable-uv sweep,
  `Remove-RetiredTerminalHostProfiles`.

Repo:
- `tasks/migrate-legacy`, its call in `tasks/bootstrap`, the health task's
  "legacy sweep" row, and its cases in `scripts/test-mise-install.sh` (plus
  the matching check-invariants description).

Kept (renamed in wording only): the first-apply `--force-dotfiles` step. A
fresh host already has distro files (`~/.bashrc` …) that mise refuses to
overwrite without it, so it is not migration code. The marker file keeps its
existing name (`dotfiles-migrated`) so already-bootstrapped hosts do not
force-overwrite again.

Known consequence: the not-yet-migrated hosts (`atc-cache-dev10`, prod hosts)
keep old Make-installed binaries in `~/.local/bin` (and `/usr/local/bin` on the
dev host). Harmless after bootstrap (mise shims precede them on PATH); remove by
hand if wanted. Those hosts are set up with a fresh `--reinstall` bootstrap.

## 4. Refactor shape

Both scripts remain single, self-contained files.

`bootstrap.sh`, top to bottom:
1. Short header (~15 lines): one-liner, flags, what `owned` / `shared` install.
2. Constants: repo URL, paths, `MISE_VERSION` / `MISE_SHA256` (still the one
   version pin allowed here).
3. Output helpers, `is_wsl`.
4. Flag parsing + `usage`.
5. One function per step: `preflight`, `clone_or_update_repo`, `install_mise`,
   `resolve_host_config` (saved mode / `WORKSTATION_MODE` / prompt, plus
   name/email → `config.local.toml`), `apply` (`mise-install.sh`, then
   `mise bootstrap` with the first-apply force), `set_login_shell` (owned
   only), `do_reinstall`, `do_doctor`, `do_check_updates`.
6. `main "$@"` as the last line — bash reads the whole file before running
   anything, so a truncated `curl | bash` download cannot execute a partial
   script.

Only `resolve_host_config` and the `mise-env.sh` call know about modes.
`config.local.toml` is read and written with plain shell (no Python needed
before tools exist); the file is machine-written `key = "value"` lines.

`bootstrap.ps1`: keep the existing shape (`param()`, tool tables, helpers,
one function per step, run sequence at the bottom — PowerShell parses the
whole script before running, so truncation is already safe). Group by
concern with section banners, merge the three copies of the GitHub-API
header code into one helper, delete migration code and anything no longer
called. `Invoke-CurlRequest` stays byte-identical to
`scripts/install-nerd-fonts.ps1`'s copy (existing invariant).

Comments in both: short why-comments where the code is non-obvious or
load-bearing; no incident narratives.

## 5. Verification, delivery, rollout

Equivalence (behaviour unchanged apart from names and removed migration code):
- `MISE_ENV=<set> mise bootstrap plan --json` resource set and resolved tool
  list identical between old and new sets: `linux,dev,host,wsl` ↔
  `linux,owned,host,wsl`, `linux,dev,host,native` ↔ `linux,owned,host,native`,
  `linux` ↔ `linux`, `windows,dev` ↔ `windows,owned`.
- Every template rendered per env set: identical output except the `MISE_ENV`
  value.
- `check-invariants.sh`, `check-templates.sh`, `check-readme.mjs`,
  `test-hooks.sh`, `test-mise-install.sh`, shellcheck / shfmt,
  PSScriptAnalyzer, PS 5.1 parse + BOM all pass; CI green.

New tests:
- `scripts/test-bootstrap-mode.sh`: saved mode wins; `WORKSTATION_MODE` used
  and saved; invalid value rejected; no terminal + no variable fails with the
  message; a prompt answer is saved. `bootstrap.sh` skips `main` only when a
  test-only environment variable is set (so `curl | bash` is unaffected), and
  the prompt reads from a file descriptor the test can supply. Wired into
  `check-invariants.sh`.
- A `bootstrap.ps1` test in the style of `scripts/test-curl.ps1`: the
  `config.local.toml` writer produces `mode = "owned"`.

End-to-end: a real `bootstrap.sh` first run with `WORKSTATION_MODE=shared`
into a scratch `HOME`, cloning the branch (shared needs no sudo). A first run
in `owned` mode needs sudo and is covered by the real-host rollout.

Delivery: one branch, one PR, three commits — (1) drop migration code,
(2) owned/shared + rename, (3) refactor + comment trimming + docs (README,
CLAUDE.md, docs/claude/*, CLAUDE_CHANGELOG.md, cheat sheet, memory).

Rollout, immediately after merge (required: a host running new templates
without `vars.mode` would bake the shared `MISE_ENV=linux` and drop the owned
tools from new shells):
- WSL: set `mode = "owned"` in `config.local.toml` (replacing `group`), run
  `bootstrap.sh` in the foreground (plan shows nothing needing sudo; any sudo
  prompt is handed to the user).
- Windows: same `config.local.toml` edit, non-interactive `bootstrap.ps1`, so
  the persisted Windows `MISE_ENV` becomes `windows,owned`.
- Verify both: `mise run health` / `-Doctor`, no dotfile drift, owned tools
  resolve from a fresh shell.

## Out of scope

- Splitting either bootstrap into multiple files.
- A shared mode on Windows.
- Separate sudo / dev-tooling questions (the two stay coupled in the mode).
- Bootstrapping `atc-cache-dev10` and the prod hosts (a follow-up, using the
  new flow).
