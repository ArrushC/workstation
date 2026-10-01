# CLAUDE.md

`workstation` provisions Linux hosts (owned or shared) and one Windows host with mise: tools
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
- **Checks:** `mise run lint` (`scripts/check-invariants.sh`; also CI and the pre-commit hook `mise run install-hooks` generates) and
  `bash scripts/check-templates.sh`. Add a check for any new mechanically checkable rule.
- **Task names** must not collide with mise built-ins (`mise fmt` is built in, so ours is
  `mise run fmt`).
- **Real `$HOME`:** agents never run `mise dot apply`, `wsa` or a bulk `mise bootstrap` against the
  real `$HOME` or host. Render into a scratch `$HOME` (`docs/claude/verification.md`) and hand real
  applies and sudo steps to the user.

## Layout

Token sets: `mise-env.sh`, saved in `miserc.toml`.

| File | Loads when the token set has | Holds |
|---|---|---|
| `config.toml` | always | uv, python, starship/gh/jq/helix (both OSes), `[vars]`, both-OS dotfiles |
| `config.linux.toml` | `linux` | Linux toolbelt (both modes), Linux dotfiles, `post-tools`/`post-dotfiles` hooks, the pueued service |
| `config.owned.toml` | `owned` | owned-host tools (node, LSP servers, go), Windows-only nushell/dnGrep/LogExpert, `~/.claude` dotfiles |
| `config.host.toml` | `host` | Linux owned host state: dnf batch, EPEL/CRB `pre-packages` hook, `final` hook (vcpkg, claude); `statusline`/`enable-el-repos` tasks; gdb, herdr, zed dotfiles |
| `config.native.toml` | `native` | non-WSL owned: NFS client packages, `final` hook (fonts) |
| `config.wsl.toml` | `wsl` | `/etc/wsl.conf` via `[bootstrap.files]` |
| `config.windows.toml` | `windows` | Windows-only dotfiles |
| `config.local.toml` | always, git-ignored | per-host `[vars] mode/name/email` and overrides |

Token sets come only from `scripts/lib/mise-env.sh`:
- shared: `linux`
- owned WSL: `linux,owned,host,wsl`
- owned native: `linux,owned,host,native`
- Windows: `windows,owned`

Locks: `mise.lock`, `mise.linux.lock`, `mise.owned.lock`, plus `locks/**` sidecars. Tasks: files in `tasks/` carry logic; one-line wrappers are `[tasks]` in `config.toml`.
mise always discovers them from the real home; `MISE_CONFIG_DIR` doesn't redirect them.

## Invariants

**Provisioning**
- `bootstrap.sh` is a thin seed; its only pin is `MISE_VERSION`/`MISE_SHA256`. Tools are mise pins,
  host state is `[bootstrap.*]` tables, procedural steps are tasks in `tasks/`. Don't add install
  logic to `bootstrap.sh` or new provisioning scripts.
- Shared hosts load no host state. Every sudo-needing table lives in `config.host.toml`,
  `config.native.toml` or `config.wsl.toml`, and those files declare no `[tools]`.
- `[bootstrap.*]` and `[dotfiles]` tables merge by union across loaded files. Declare each item once,
  in the file whose token gates it.
- Hooks are `mise run <task>`, or `mise run a ::: b` for several, because mise treats hook strings as
  opaque shell. A hook name may be declared in more than one loaded file, and all of them run. The one exception is
  the literal `post-dotfiles` chmod line in `config.linux.toml`. mise runs hooks under
  `sh -o errexit`, so each of its commands keeps its own `|| true`.
- Owned-only steps hang off `final` hooks in `config.host.toml` (vcpkg, claude) and `config.native.toml`
  (fonts). `final` runs only on a full `mise bootstrap`, never on `--only dotfiles`.
- dnf installs everything in one batch, so a single unresolvable name fails the whole run. Only add
  EL9-verified names. `ShellCheck` is capitalised; `fswatch`, `entr` and `cockpit-networkmanager`
  don't resolve.
- No `[bootstrap.linux.firewall]` table: it makes `mise bootstrap plan`/`status` re-exec with sudo,
  which breaks `mise run health`. No `[bootstrap.user] login_shell` either: it needs `chsh`.
  `bootstrap.sh`'s `set_login_shell` uses `sudo usermod`.
- `[vars]` pins (`vcpkg_version`, `zjstatus_zellij_floor`) reach
  tasks through `#MISE env={X="{{ vars.x }}"}`.
- Never hand-edit `mise*.lock` or `locks/**`. Regenerate them with `mise lock` (recipe in
  `scripts/bump-versions.sh` and `docs/claude/verification.md`).
- `tasks/verify-tools` (the `post-tools` hook) checks that every mise-installed ELF can run on this
  host. Static binaries must pass. A failure means pinning an explicit `github:` `asset_pattern`.
- vcpkg stays a task: `[bootstrap.repos]` can't shallow-clone or update. The C/C++ toolbelt
  spans dnf, mise and vcpkg on purpose; don't unify it.
- `/dev/tty` reads in `bootstrap.sh` and `tasks/bootstrap` are load-bearing under `curl | bash`.
- WSL detection is `is_wsl()` (in `bootstrap.sh` and `scripts/lib/mise-env.sh`, which must agree).

**Mode and `MISE_ENV`**
- The mode is `owned` or `shared`, saved as `vars.mode` in `config.local.toml`. It comes from the
  saved value, then `WORKSTATION_MODE`, then a prompt. Windows is always owned.
- `scripts/lib/mise-env.sh <mode> --write` writes the git-ignored `miserc.toml` (`env = [...]`,
  `auto_env = false`) from the saved mode. Every mise process reads it, shims under systemd
  included; nothing exports `MISE_ENV`. An exported value overrides it, so `bootstrap.sh` and
  `tasks/update` unset it, while CI and `check-templates.sh` may pin one.
- Every `ws*` command pins `mise -C` to the home directory. mise finds its config by walking up from
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
  `~/.local/state/workstation/dotfiles-migrated` is absent.
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
- `~/.claude/CLAUDE.md` is deployed from `dotfiles/claude/CLAUDE.md`. Its TOOLS block is generated.

**Windows**
- Never render Windows targets with the Linux mise: `os()` reflects the OS of the binary that is
  running.
- `bootstrap.ps1` applies dotfiles with `mise bootstrap --only dotfiles,tools`.
- Scripts never write Windows Terminal's tracked `settings.json`. SSH launchers go to a WT fragment,
  and Warp's `workstation-*.toml` tab configs are runtime artifacts.
- Warp is the primary terminal; Windows Terminal is the compatibility one (default-terminal role,
  Nushell).
- The rc files' `TERM_PROGRAM != WarpTerminal` guards must never wrap a plugin `source`
  (`check_warp_guards`).

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
  all 12 servers, and `claude plugin validate` tolerates it (which is all `check_lsp_plugin` runs). Check with
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
  - Each `.vendor` sidecar records provenance.
- **Generated blocks (never edit inside):**
  - `<!-- TOOLS:START/END -->` in `dotfiles/claude/CLAUDE.md`, from `scripts/gen-tool-memory.sh`
  - `# CCSTATUSLINE-OPTOUT:START/END` in `config.local.toml`, from `scripts/setup-ccstatusline.sh`
- **Parity pairs (change them together):**
  - `zshrc.tera` ↔ `bashrc.tera`
  - `zshenv.tera` ↔ the shims block in `bashrc.tera`
  - the Nushell `config.nu.tera` ↔ PowerShell profile `ws*`/`g*` aliases
  - script flags ↔ their completions (`_bootstrap.sh`, `completions.bash`, `config.nu.tera`'s flag
    record)
- **Values recorded in several places (checked by `check_version_pins` and friends):**
  - mise: `bootstrap.sh`, `bootstrap.ps1` `$MiseVersion`, `min_version`
  - `VCPKG_ROOT`: the rc files ↔ `tasks/vcpkg`
  - zellij ≥ `zjstatus_zellij_floor`; TypeScript major ≤ 5
  - `scripts/bump-versions.sh` covers each via `COUPLED_AUTO` or `EXCLUDE`.
- **Never hand-edit:**
  - deployed `$HOME` targets: edit the source, e.g. via `wse`
  - `/etc` copies

## Hooks

Repo hooks (`.claude/settings.json`). After editing any of them, re-run
`bash .claude/hooks/test-hooks.sh`.
- `post-edit-guard.sh` repairs CRLF, the exec bit and `.ps1` BOMs after an edit.
- `parity-reminder.sh` names the other half of a parity pair.
- `memory-routing-guard.sh` denies writes to the home-dir memory path.
- `sync-tool-memory.sh` regenerates the TOOLS block after a `config*.toml` edit.
- `session-context.sh` (SessionStart) reports dotfiles drift, host, mode, WSL interop, tool readiness.
- `session-end-notify.sh` (SessionEnd) notifies when the repo or dotfiles are left dirty.

Global hooks (`dotfiles/claude/hooks/` → `~/.claude/hooks/`, wired by `settings.enforced.json`):
- `secret-guard.sh` denies reading or editing private keys, `*.pem` and `*.key`.
- `dangerous-command-guard.sh` denies fork bombs, raw-device writes and `mkfs`. It asks before
  `rm -rf` of `/` or `~`, `curl | bash`, and force-push.
- Both match command *text*, so a commit message mentioning a pattern is screened.
