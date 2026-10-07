# CLAUDE.md

`workstation` provisions Linux hosts and one Windows host with mise: tools
(`[tools]`), host state (`[bootstrap.*]`, applied by `mise bootstrap`), and dotfiles (`[dotfiles]`,
`mise dot`). This checkout **is** mise's global config dir: `~/.config/mise`, or
`%USERPROFILE%\.config\mise` on Windows. User docs: `README.md`. Verification recipes:
`docs/claude/verification.md`.

## Working rules

- **Memory:** project memories go in `.claude/memory/<slug>.md` plus a one-line entry in
  `.claude/memory/MEMORY.md` (committed). Never write to `~/.claude/projects/*/memory/`
  (`memory-routing-guard.sh` denies it). Use a host-global location only when the user asks for
  cross-project scope, and say so in the reply.
- **History first:** before changing a tricky area, run `git log --oneline -- <path>` and
  `git log -p -S '<symbol>' -- <path>`. Most rules here exist because the opposite broke.
- **Docs travel with behaviour:** a user-facing change updates `README.md` in the same commit.
  Claude-internal files (`CLAUDE.md`, `docs/claude/`, `.claude/`) and version bumps don't.
- **The checkout is live config:** `mise use -g`, `mise settings set`, `mise dot add`/`wsr`, `wse` and
  `mise bootstrap` write tracked files here. Commit or revert first; `wsu`'s `git pull --ff-only`
  fails on a dirty tree.
- **Checks:** `mise run lint` (`scripts/check-invariants.sh`; CI and the pre-commit hook run it) and
  `bash scripts/check-templates.sh`. Add a check for any new mechanically checkable rule.
- **Task names** must not collide with mise built-ins (`mise fmt` is one; ours is `mise run fmt`).
- **Real `$HOME`:** agents never run `mise dot apply`, `wsa` or a bulk `mise bootstrap` against the
  real `$HOME` or host. Render into a scratch `$HOME` (`docs/claude/verification.md`) and hand real
  applies and sudo steps to the user.

## Layout

| File | Loads on | Holds |
|---|---|---|
| `config.toml` | every host | both-OS tools (uv, python, the CLI toolbelt, node, go, LSP servers, ccstatusline; Windows-only nushell/carapace/dnGrep/LogExpert carry `os = ["windows"]`), `~/.claude` dotfiles, `[vars]` |
| `config.linux.toml` | Linux | Linux toolbelt, dnf batch, `/etc/wsl.conf`, EPEL/CRB `pre-packages` hook, `post-packages`/`post-tools`/`post-dotfiles` hooks, `final` hook (vcpkg, claude, fonts), `statusline`/`enable-el-repos` tasks, Linux dotfiles (gdb, herdr, zed), the pueued service |
| `config.windows.toml` | Windows | Windows-only dotfiles; winget GUI apps (`[bootstrap.packages]`) |
| `config.local.toml` | every host, git-ignored | per-host `[vars] name/email/sudo` and overrides |

Token sets: Linux `linux`, Windows `windows` (from `scripts/lib/mise-env.sh` and `bootstrap.ps1`).

Locks: `mise.lock`, `mise.linux.lock`, plus `locks/**` sidecars. Tasks: files in `tasks/` carry logic; one-line wrappers are `[tasks]` in `config.toml`.
mise always discovers them from the real home; `MISE_CONFIG_DIR` doesn't redirect them.

## Invariants

**Provisioning**
- `bootstrap.sh` is a thin seed; its only pin is `MISE_VERSION`/`MISE_SHA256`. Tools are mise pins,
  host state is `[bootstrap.*]` tables, procedural steps are tasks in `tasks/`. Don't add install
  logic to `bootstrap.sh` or new provisioning scripts.
- Sudo-needing tables (dnf, `[bootstrap.files]`) live only in `config.linux.toml`; without sudo
  they're skipped with `--skip packages,files` (`vars.sudo`, decided by `bootstrap.sh`). A WSL-only
  step checks `is_wsl` at run time.
- `[bootstrap.*]` and `[dotfiles]` tables merge by union across loaded files. Declare each item once,
  in the file whose token gates it.
- Hooks are `mise run <task>` (or `mise run a ::: b`): mise treats hook strings as opaque shell.
  A hook name declared in several loaded files runs every one. The one exception is
  the literal `post-dotfiles` chmod line in `config.linux.toml`. mise runs hooks under
  `sh -o errexit`, so each of its commands keeps its own `|| true`.
- Linux-only steps hang off `config.linux.toml`'s `final` hook (vcpkg, claude, fonts). `final` runs
  only on a full `mise bootstrap`, never on `--only dotfiles`.
- dnf installs in one batch, so one unresolvable name fails the run. Only add names verified on EL8
  and EL9; one some releases lack goes in `tasks/optional-packages`. `ShellCheck` is capitalised;
  `fswatch`, `entr` and `cockpit-networkmanager` don't resolve.
- No `[bootstrap.linux.firewall]` table: it makes `mise bootstrap plan`/`status` re-exec with sudo,
  which breaks `mise run health`. No `[bootstrap.user] login_shell` either: it needs `chsh`.
  `bootstrap.sh`'s `set_login_shell` uses `sudo usermod`.
- `[vars]` pins (`vcpkg_version`, `zjstatus_zellij_floor`) reach
  tasks through `#MISE env={X="{{ vars.x }}"}`.
- Never hand-edit `mise*.lock` or `locks/**`. Regenerate them with `mise lock` (recipe:
  `docs/claude/verification.md`). `config.toml` sets `locked = true`: installs never rewrite locks
  (each OS's mise mangles the other's entries; a dirty tree breaks `wsu`). Lock-file-off installs
  pass `MISE_LOCKED=0`.
- `tasks/verify-tools` (the `post-tools` hook) checks every mise-installed ELF runs on this host;
  `disk-budget.yml` checks them against EL8's glibc 2.28. Fix: a musl `github:` asset, else `conda:`.
- vcpkg stays a task: `[bootstrap.repos]` can't shallow-clone or update. The C/C++ toolbelt
  spans dnf, mise and vcpkg on purpose; don't unify it.
- `/dev/tty` reads in `bootstrap.sh` and `tasks/bootstrap` are load-bearing under `curl | bash`.
- WSL detection is `bootstrap.sh`'s `is_wsl()`; tasks source it (`WORKSTATION_BOOTSTRAP_LIB=1`).

**`MISE_ENV` and sudo**
- One setup for every host; no mode. `scripts/lib/mise-env.sh --write` writes the git-ignored
  `miserc.toml` (`env = ["linux"]`); `bootstrap.ps1` writes `["windows"]`. Every mise process reads it;
  nothing exports `MISE_ENV` (`bootstrap.sh`, `bootstrap.ps1` and `tasks/update` unset it; CI and
  `check-templates.sh` may pin one). `check_no_mode` keeps a mode from coming back.
- `vars.sudo` (`config.local.toml`) is written only by `bootstrap.sh`; missing means yes.
- Every `ws*` command and `bootstrap.ps1` pin `mise -C` to the home directory. mise finds its config by walking up from
  the cwd, so an unpinned run from `/mnt/c/...` manages the wrong checkout. `wsa` also refuses unless
  `mise dot status --json`'s `.files[0].origin.config_root` is the pinned root (unknown proceeds).

**Dotfiles**
- `template` for the `.tera` sources, `copy` for everything else, never `symlink`/`symlink-each`
  (a directory symlink replaces the whole directory, deleting unmanaged files).
- One undefined variable or failing `exec()` in any template aborts the whole apply, so guard every
  `vars.*` with `is defined` or `default()`.
- Directory `copy` entries keep `exclude = [".vendor", ".gitkeep"]`. `copy` on a directory leaves
  unmanaged files in it alone.
- Deployed files are independent copies, so a live edit under `$HOME` doesn't reach the repo on its
  own:
  - `wsr` (`mise dot add --changed`) records file entries but skips directory entries.
  - For a directory entry, run `mise dot add <the directory>`. It replaces the source directory; it
    doesn't merge.
  - `mise dot apply` silently overwrites edits that were never recorded. `wsa` checks
    `mise dot status` for drift and asks first.
- Disabling an inherited entry needs `enabled = false` **and** a repeated `mode`.
- A host's first apply needs `--force-dotfiles`. `bootstrap.sh` and `bootstrap.ps1` pass it only while
  `dotfiles-migrated` is absent (`~/.local/state/workstation/`; Windows `%LOCALAPPDATA%\workstation\`).
- The `post-dotfiles` hook is the only thing that sets these modes:
  - `~/.ssh`, `~/.claude`: 700
  - `~/.ssh/config`: 600
  - source `dotfiles/ssh/config.tera`: 600, so mise stops reporting a mode diff
- `~/.claude/settings.json` isn't a dotfile. `scripts/lib/claude-settings-merge.sh` (on Windows,
  `Invoke-ClaudeSettingsMerge` with the same jq filter) merges three layers:
  `settings.seed.json` (only where a key is absent) → the live file → `settings.enforced.json`
  (always wins). Change cross-host keys in the enforced file.
- `/etc` files come from `configs/` via `[bootstrap.files]`. Today that is only `/etc/wsl.conf`, which
  keeps `appendWindowsPath=false` and stays LF-only (CRLF corrupts it). `[dotfiles]` owns `$HOME` only.
- `dotfiles/ssh/config.tera` gates SSH multiplexing out on Windows (its OpenSSH can't multiplex).
- zsh plugin order in `dotfiles/zshrc.tera`: fzf-tab after `compinit` → autosuggestions →
  syntax-highlighting → history-substring-search last. `bashrc.tera` carries PARITY NOTEs for what
  bash can't do.
- The fleet runs `TERM=xterm-256color` on purpose.

**Windows**
- Never render Windows targets with Linux mise (`os()` is its OS).
- `bootstrap.ps1` pins only mise; CLI tools are mise tools, GUI apps winget
  `[bootstrap.packages]` (not SSHFS-Win: UAC). No User `MISE_ENV`; it stops before `mise bootstrap`/prune unless `config.windows.toml` loads.
- Nushell runs via mise's `nu.exe` shim (`Install-Mise` renames a running `mise.exe`); `nu-init` (post-tools) writes vendor/autoload.
- `scripts/test-*.ps1` test Windows (CI `windows-http`, 5.1+pwsh).
- Scripts never write WT's tracked `settings.json`: SSH launchers → a WT fragment;
  Warp's `workstation-*.toml` are runtime.
- Warp is primary; WT is compat (default terminal, Nushell).
- `TERM_PROGRAM != WarpTerminal` rc guards must never wrap a plugin `source` (`check_warp_guards`).

**zellij**
- `copy_command` stays unset, because OSC 52 is the only clipboard path over SSH. `web_server` stays
  off. zjstatus loads from mise's install dir (`check_zellij_config`); no copy step.
- Never add `zellij-autolock` or an unmaintained plugin untested against the pinned zellij. Judge
  whether a plugin loaded from zellij's log, not `dump-layout`.

## File care

- **LF + git mode 100755:**
  - `scripts/*.sh`, `scripts/lib/*.sh`, every `tasks/*` file (mise silently skips a non-executable
    task), `.claude/hooks/*.sh`
  - executable dotfiles: `dotfiles/claude/hooks/*.sh`, `dotfiles/claude/notify.sh`,
    `dotfiles/local/bin/{batpipe,winterop}`
  - Repair: `sed -i 's/\r$//' <f>`; `git update-index --chmod=+x <f>`.
  - First-party shell must be `shfmt -i 2`-clean (`mise run fmt`) and gitleaks-clean.
  - Quote bash associative-array keys: shfmt rewrites an unquoted `[a-b]` as arithmetic.
- **`dotfiles/claude/skills/workstation-lsp/.lsp.json` must be strict JSON.** A `//` comment silently fails
  all 12 servers, and `claude plugin validate` (`check_lsp_plugin`) tolerates it. Check with
  `python3 -m json.tool`; put notes in `SKILL.md`.
- **Every other file under `dotfiles/` is 100644** (`check_dotfiles_mode`): `copy`/`template`
  propagate the source's exec bit into `$HOME`.
- **UTF-8 with BOM:** `bootstrap.ps1` and `scripts/install-nerd-fonts.ps1` (PowerShell 5.1 needs it).
  - Restore: `[IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($true))`.
  - In double-quoted strings write `${name}:`; a bare `$name:` is a drive-qualified parse error.
- **Vendored (re-download at the pinned tag, never hand-edit):**
  - the five zsh plugin dirs and `zsh-shift-select.zsh`
  - `_cht.sh`, a rolling snapshot
  - `dotfiles/local/bin/batpipe`: re-apply the 2-line patch recorded in its `.vendor`
  - `dotfiles/config/gdb/gef.py`: stay on GEF 2024.06 while the fleet is EL9 (newer needs Python 3.10)
- **Generated blocks (never edit inside):**
  - `<!-- TOOLS:START/END -->` in `dotfiles/claude/CLAUDE.md`, from `scripts/gen-tool-memory.sh`
  - `# CCSTATUSLINE-OPTOUT:START/END` in `config.local.toml`, from `scripts/setup-ccstatusline.sh`
  - `disk-budget.toml`, from `.github/workflows/disk-budget.yml`
- **Parity pairs (change them together):**
  - `zshrc.tera` ↔ `bashrc.tera`
  - `zshenv.tera` ↔ the shims block in `bashrc.tera`
  - the Nushell `config.nu.tera` ↔ PowerShell profile `ws*`/`g*` aliases
  - script flags ↔ their completions (`_bootstrap.sh`, `completions.bash`, `config.nu.tera`'s flag
    record)
- **Values recorded in several places (checked by `check_pins`):**
  - mise: `bootstrap.sh`, `bootstrap.ps1` `$MiseVersion`, `min_version`
  - `VCPKG_ROOT`: the rc files ↔ `tasks/vcpkg`
  - zellij ≥ `zjstatus_zellij_floor`; TypeScript major ≤ 5
  - `scripts/bump-versions.sh` covers each via `COUPLED_AUTO` or `EXCLUDE`.
- **Never hand-edit:**
  - deployed `$HOME` targets: edit the source, e.g. via `wse`
  - `/etc` copies

## Hooks

Repo hooks (`.claude/settings.json`) source `lib.sh` (JSON in/out; fail open). `mise run lint` runs `test-hooks.sh`.
- `post-edit-guard.sh` repairs CRLF, exec bits and `.ps1` BOMs.
- `parity-reminder.sh` names the other half of zshrc/bashrc or the Nushell/PowerShell profiles.
- `memory-routing-guard.sh` denies home-dir memory writes.
- `sync-tool-memory.sh` regenerates the TOOLS block after a `config*.toml` edit.
- `session-context.sh` (SessionStart) reports dotfiles drift, host, miserc tokens (and `sudo=no` where saved; an exported `MISE_ENV`), WSL interop, tools.
- `session-end-notify.sh` (SessionEnd) notifies when the repo or dotfiles are dirty.

Global hooks (`dotfiles/claude/hooks/` → `~/.claude/hooks/`, via `settings.enforced.json`):
- `secret-guard.sh` denies reading or editing private keys, `*.pem`, `*.key`.
- `dangerous-command-guard.sh` denies fork bombs, raw-device writes, `mkfs`. It asks before
  `rm -rf` of `/` or `~`, `curl | bash`, force-push.
- Both match command *text*, so a commit message naming a pattern is screened.
