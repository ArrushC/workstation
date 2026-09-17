# mise everywhere: Make and chezmoi → mise (design)

Status: approved 2026-09-16 (plan-mode design review, sections 1–8). Supersedes the tool-layer half of
`2026-09-13-mise-runtimes-design.md` (its runtime decisions are carried forward unchanged).

## 1. Problem and decisions

`workstation` provisions ten Linux hosts (3 dev, 6 prod, 1 WSL dev) and one Windows host. Make is a
home-grown package manager here: `versions.mk` (~120 pins), `tools.mk` (90 tools via `EGET_TOOL`/`TOOL`/
`USER_TOOL`), `lib/*.sh` installers, stamp files, plus OS state in `packages.mk`/`shell.mk`/bespoke targets.
chezmoi owns `$HOME` through 99 source files, 19 Go templates, 7 lifecycle scripts, a 91-line ignore template.

mise 2026.9.x natively covers all of it: `[tools]` + `mise.lock`, `[bootstrap.*]` (packages, files,
services, compose, repos, user, hooks), `[dotfiles]` with Tera templates, config environments, global
file tasks. Decisions taken with the user, all binding:

1. **Everything moves.** Make vanishes; mise bootstrap owns dnf packages, `/etc` files, systemd services,
   Docker Compose, git checkouts and the login shell. A handful of file tasks carry what is procedural.
2. **User-level tools everywhere** (`~/.local/share/mise`). sudo is used only for dev-host OS state.
   The `/usr/local` vs `~/.local/bin` split and the `DEST`/`SUDO`/`--preserve-env` machinery are deleted.
3. **Windows shares the config files** (runtimes + LSP servers come from the same TOML).
   `$PortableTools`/`$InstallerTools` stay; pin checks re-point at the TOML. Migrating Windows portable
   tools into `[tools]`/winget is a separate future spec.
4. **chezmoi is replaced by mise `[dotfiles]` in this migration** (PR3). The subsystem is weeks old and
   still moving; the user weighed that and reaffirmed. Mitigation: it lands last, on a proven bootstrap
   flow, with a rendered-output CI check and a WSL-first rollout.
5. **The repo becomes `~/.config/mise`** (Linux) / `%USERPROFILE%\.config\mise` (Windows) — mise's adopt
   model. No symlink, no indirection.
6. **Sequence:** PR1 tools → PR2 host state + Make deleted → PR3 dotfiles + chezmoi deleted. Each PR
   leaves every host operable and carries its own README/CHANGELOG changes.

Deliberately NOT used: `[bootstrap.mise_shell_activate]` (would fight our rc templates on every apply)
and `[bootstrap.remote]` (hosts still need the checkout; `hosts.conf` also feeds the Windows terminals).

## 2. Verified facts (mise 2026.9.1 binary + docs + scratchpad spikes, 2026-09-16)

- `mise bootstrap` phases: accounts → plugins → pre-packages hook/files → packages → files/directories →
  services → firewall → compose → repos (pre/post hooks) → dotfiles (pre/post hooks) → shell activation →
  linux systemd units → user login shell → tools (pre/post hooks) → `bootstrap` task → final hook.
  `--only`/`--skip`, `plan`, `status --missing`, `--force-dotfiles`, `--adopt` (≥2026.9.3).
- Per-package `env` selector landed in 2026.9.4; dotfiles were rebuilt in 2026.9.2 and fixed through
  2026.9.9 (false-deletion fix). **Pin mise 2026.9.9**; `min_version = "2026.9.9"`.
- Global config dir loads `config.toml`, `config.<env>.toml`, `config.local.toml`, `conf.d/*.toml`.
  `[vars]` in `config.dev.toml` override `config.toml`. `[dotfiles]`/`[tools]` in an env file apply only
  when that env is active.
- Tera templates: `mise_env` is an **array** (`{% if "dev" in mise_env %}`), `vars`, `env`, `os()`,
  `exec()`, `is defined` all work. **An undefined var in any one template aborts the whole apply.**
  A boolean `false` var was invisible to templates → vars are strings; OS/mode tests use `mise_env`.
- Dotfiles: `symlink`, `symlink-each` (+ `exclude` globs), `copy`, `template` (keeps the source's +x),
  `track`. Windows: file symlinks need Developer Mode else copy fallback; directory symlinks are
  junctions; `symlink-each` copies. `mise bootstrap dotfiles add --changed` re-adds copy-mode files.
- Global file tasks: `~/.config/mise/tasks/**` discovered from any cwd; `mise <task>` shorthand works
  unless it collides with a built-in (`doctor` does → ours is `health`); `#MISE env={X="{{ vars.y }}"}`
  renders vars; **never set `[task_config].includes`** (it broke discovery).
- `mise bootstrap --only dotfiles,tools` leaves declared `/etc` entries untouched (Windows-safe).
- aqua registry covers ~65 toolbelt tools. Not in registry: ncdu bandwhich tldr dsq ouch sysz chezit
  ccstatusline dozzle nnn gitlogue csvlens trippy scc git-absorb procs pueue nnd pwndbg omp gopls glances
  asciinema harlequin nb eget zjstatus. aqua zellij = web-capable musl ✓; aqua fastfetch = plain glibc
  build ✗ (need `-polyfilled`); aqua usql = dynamic build ✗ (needs `usql_static`).
- EL9 `dnf repoquery`: `fswatch` and `entr` do not resolve → dropped (mise packages are all-or-nothing).
- `mise upgrade --bump`, `mise outdated --bump --json`, `mise lock --platform a,b`,
  `mise config set -f <file> tools.<x> <ver>` exist.
- Schemas: `[bootstrap.files."<path>"]` `source|content|template|owner|group|mode|notify|phase="pre-packages"`;
  `[bootstrap.services.<n>]` user scope `scope="user"|command|requires_tools|restart`, system scope
  `state|enabled|on_change|masked`; `[bootstrap.compose.<p>]` `project_dir|files|state|sudo`;
  `[bootstrap.repos."<path>"] = {url, ref}`; `[[bootstrap.linux.firewall.rules]]` `name|port|protocol|action`;
  `[bootstrap.user] login_shell`; hooks = string | array | `{run=...}`, run in the plain process env.

## 3. Target layout

```
config.toml            [settings] lockfile=true; min_version; [vars] defaults (group="prod_machine",
                       python_version, nerd_font_version, dozzle_version); [tools] uv; cross-platform [dotfiles]
config.linux.toml      Linux toolbelt (both scopes); Linux [dotfiles]; [bootstrap.services.pueued] (user); cheat community repo
config.windows.toml    Windows-only [dotfiles] (copy mode)
config.dev.toml        [vars] group="dev_machine"; dev tools on both OSes; Linux-only dev tools with os=["linux"]; dev [dotfiles]
config.host.toml       Linux dev host state: dnf packages, pre-packages EPEL/CRB hook, login shell, vcpkg repo + hook
config.native.toml     non-WSL dev extras: docker-ce repo/packages/service/usermod hook, cockpit, rsyslog, firewall rule, nfs/autofs, dozzle compose
config.wsl.toml        /etc/wsl.conf
config.local.toml      git-ignored per-host [vars] (name, email, optional project_root, dotfile overrides)
mise.lock              committed; linux-x64 + windows-x64
tasks/                 global file tasks
dotfiles/              real names; *.tera templates; windows/ subtree
configs/               /etc sources (cockpit, rsyslog, wsl, docker/docker-ce.repo, dozzle/compose.yaml.tera)
scripts/               helpers + scripts/lib/, check-invariants, check-templates, bump-versions, gen-tool-memory, manage-hosts.*, update-hosts, tests
bootstrap.sh bootstrap.ps1 hosts.conf README.html docs/ .claude/ .github/ .githooks/
```
Deleted by the end: `GNUmakefile`, `makefile/`, `chezmoi/`, `.chezmoiroot`, `scripts/gen-mise-config.sh`,
`scripts/test-mise.sh`, eget, chezit, chezmoi.

## 4. Environments

`MISE_ENV` = OS token + role tokens: `linux` (prod) · `linux,dev,host,native` · `linux,dev,host,wsl` ·
`windows,dev`. `bootstrap.sh --dev|--prod` computes it and passes `-E` on the first run; the rendered
`~/.zshenv`, the top of `~/.bashrc` (above the interactive guard) and `~/.config/environment.d/10-mise.conf`
persist it (the template emits the env it was rendered with). Windows persists a User environment variable.
Templates branch on `"dev" in mise_env`, `"wsl" in mise_env`, `os()`; strings come from `[vars]`.

## 5. Tools

- **aqua** short names (pin = version): fzf zoxide starship zellij glow helix fd bat btop jq yq witr
  lazydocker dive lnav gopass age gitui lazygit jj yazi ast-grep television xh gping atuin delta micro eza
  sd ctop k9s rclone croc hyperfine gh sops htmlq watchexec bottom systemctl-tui lazyjournal cheat fx
  ripgrep miller difftastic doggo miniserve numbat qsv grex shfmt gitleaks dust hexyl gum herdr opencode uv
  rust-analyzer marksman taplo lua-language-server (+ chezmoi until PR3).
- **github:** usql (`usql_static-{{version}}-linux-amd64.tar.bz2`, rename → usql), fastfetch
  (`fastfetch-linux-amd64-polyfilled.tar.gz`), procs (`procs-v{{version}}-x86_64-linux.zip`), bandwhich
  (musl), tealdeer (`tealdeer-linux-x86_64-musl`, bin `tldr`), nnn (`nnn-musl-static-{{version}}.x86_64.tar.gz`),
  csvlens (musl), trippy (musl, exe `trip`), git-absorb (musl), ouch (musl), scc, dsq, gitlogue, chezit (PR1–2),
  jless, broot (`bin_path="x86_64-unknown-linux-musl"`), nnd (bare asset), pwndbg (portable tar.xz, `bin_path`),
  devtoys-cli (zip tree, rename → `devtoys.cli`), omp (rename), zjstatus (`zjstatus.wasm`; `http:` fallback).
- **http:** ncdu (dev.yorhel.nl tarball), pueue + pueued (bare musl binaries), nb, ssh-copy-id, sysz.
- **core:** node, go. **pypi:** glances, asciinema, harlequin (`latest`, lockfile-pinned).
  **npm:** ccstatusline (pinned → statusLine command becomes plain `ccstatusline`; that dual-edit disappears).
- **Task steps, not tools:** Claude Code (native installer, skip-if-present), cht.sh (soft-fail).
  mise itself is installed by bootstrap: one pin in `bootstrap.sh` + `bootstrap.ps1` + `min_version`, asserted equal.
- **Capability gate:** `tasks/verify-tools` (`post-tools` hook) runs `scripts/lib/verify-binary.sh` over
  every Linux binary from `mise ls --json`; a failure fails the bootstrap loudly; the fix is an explicit
  `github:` asset for that tool.
- Helix: the aqua archive carries `runtime/` beside `hx`, which helix discovers itself → `HELIX_RUNTIME`
  disappears from both rc files and both scopes.
- `[settings] lockfile = true`; `mise.lock` committed and maintained for both platforms by the bumper.

**Amendment (2026-09-17), controller ruling during Task 9 (documentation):** reverses this section's original assumption that `python` is never declared in mise. It **IS** declared, in `config.toml` (`python = "3.14.7"`), as a three-way pin with `PYTHON_VERSION` in `makefile/versions.mk` and `$PythonEnvVersion` in `bootstrap.ps1`. Reason: the dependency-locked `pypi:`/`pipx:` tools this section lists (`glances`, `asciinema`, `harlequin`, plus `basedpyright`) need `mise lock` to run `uv sync --frozen --python <interpreter>` against a real interpreter to produce their lock entries; without one declared, mise falls back to the host's system Python (3.9 on EL9), which `uv sync --frozen` then refuses for these packages. The declared `python` shadows `python3` only in mise-activated shells — the system interpreter at `/usr/bin/python3` is untouched, so sudo and system services are unaffected. It is a separate install from `python-env`'s own uv-built CPython venv (`~/.local/share/workstation-python`) — the two share a version only because of the three-way pin, not because they are the same interpreter.

## 6. Host state (dev Linux only; prod declares none and never needs sudo)

- **Packages** (`config.host.toml`): today's core + optional lists as `dnf:` entries minus `make`,
  `fswatch`, `entr`. `pre-packages` hook `scripts/lib/enable-el-repos.sh` keeps the EPEL install + CRB
  enable logic (Fedora skip, dnf4 syntax). Cockpit + NFS/autofs packages live in `config.native.toml`.
- **Native extras** (`config.native.toml`): vendored `configs/docker/docker-ce.repo` as a `pre-packages`
  file, docker-ce/cli/containerd/buildx/compose packages, `docker` service, `post-packages` hook for
  `usermod -aG docker`; `/etc/cockpit/cockpit.conf` notifying `cockpit.socket`; firewall rule 9090/tcp
  (behaviour without firewalld verified on the first native host; today's `firewall-cmd` snippet is the
  fallback hook); `/etc/rsyslog.d/30-workstation.conf` notifying `rsyslog` with `on_change = "restart"`;
  `/etc/dozzle/` dir + `compose.yaml` (template on `vars.dozzle_version`) + `[bootstrap.compose.dozzle]`
  with `sudo = true`. The legacy dozzle unit/env are removed by the migration task.
- **WSL** (`config.wsl.toml`): `/etc/wsl.conf` as a `[bootstrap.files]` entry (mode 0644, owner root).
- **pueued**: `[bootstrap.services.pueued]` `scope="user"`, `command="~/.local/share/mise/shims/pueued -v"`,
  `requires_tools=true` (replaces the chezmoi unit + its run_onchange script).
- **vcpkg**: `[bootstrap.repos."~/.local/share/vcpkg"] = {url, ref}` + `post-repos` hook
  `scripts/lib/vcpkg-bootstrap.sh` (skip if built; symlink `~/.local/bin/vcpkg`); `VCPKG_ROOT` in the rc
  files follows; the invariant check ties them. Cheat community sheets: `[bootstrap.repos]` too.
- **Login shell**: `[bootstrap.user] login_shell = "/usr/bin/zsh"` in `config.host.toml`; prod keeps the
  printed manual `chsh` hint.

## 7. Tasks and hooks

| Task | Purpose |
|---|---|
| `bootstrap` | mise runs it after tools with tools on PATH. Idempotent steps: Claude Code install; Claude + herdr plugins (dev, marker files under `~/.local/state/workstation/`); zjstatus.wasm → zellij data dir; tldr cache seed; cht.sh (soft); nb notebook init; Claude `settings.json` merge (dev); legacy sweeps (marker-guarded). Depends on `python-env`, `fonts`. |
| `python-env` | today's script; `sources`/`outputs`; `vars.python_version` |
| `fonts` | today's `font.sh` (dev, skipped on WSL); `vars.nerd_font_version` |
| `verify-tools` | `post-tools` hook gate |
| `health` | the doctor: `mise bootstrap status --missing`, `mise ls --missing`, `mise doctor`, packages status, workstation wiring checks |
| `update` | `git pull --ff-only` + `mise bootstrap -y` |
| `update-hosts` | wraps `scripts/update-hosts.sh` |
| `lint` `fmt` `secrets` `ps-lint` `install-hooks` `bump-versions` `inventory` `statusline` | the remaining utility targets |
| `migrate-legacy` | hidden; the sweeps |

Hooks: `pre-packages` (EPEL/CRB), `post-packages` (docker group), `post-repos` (vcpkg), `post-dotfiles`
(`chmod 700 ~/.ssh ~/.claude; chmod 600 ~/.ssh/config`), `post-tools` (`mise run verify-tools`).
Hooks run without tools on PATH; anything needing a tool lives in the `bootstrap` task.

## 8. Dotfiles (PR3)

- `dotfiles/` uses real names; gating is by which env file declares the entry (replaces `.chezmoiignore.tmpl`).
- Modes: plain files/clean dirs → `symlink`; dirs with `.vendor`/`.gitkeep` sidecars (`~/.config/zsh`,
  `~/.local/bin`, `~/.config/gdb`, `~/.claude` subtrees) → `symlink-each` + `exclude=[".vendor",".gitkeep"]`;
  the 19 Go templates → 12 Tera templates (`template` mode); Windows entries → `copy` (re-add via
  `mise bootstrap dotfiles add --changed`). Helix config: one source, Linux + Windows targets.
- Conversions: `.group` → `"dev" in mise_env`; `.chezmoi.os` → `os()`; `.chezmoi.homeDir` → `env.HOME`;
  `.name/.email` → `vars.*`; hostname banners → `exec(command="hostname")`; the stale `rhel-dev-01`
  branch → `vars.project_root` in `config.local.toml`.
- `~/.claude/settings.json`: no `modify` equivalent → `scripts/lib/claude-settings-merge.sh` (jq) merges
  `dotfiles/claude/settings.seed.json` (set-if-absent) + `settings.enforced.json` (always wins) from the
  `bootstrap` task, dev only.
- The 7 scripts: pueued → user service; cheat community → repos; tldr/nb/claude-plugins/herdr-plugin →
  `bootstrap` steps; `.wslconfig` reminder → hash compare in bootstrap.ps1.
- ccstatusline per-host opt-out → `setup-ccstatusline.sh` writes an entry override into `config.local.toml`.
- age: dropped (dormant, zero encrypted files); future path is `encrypt=true` + `[history.encryption]`.
- Aliases `cz*` → `ws*`: `wsa` apply, `wsd` diff, `wss` status, `wse` edit, `wsr` add --changed, `wsu` update,
  `wsh` help — zsh, bash, nushell, PowerShell; completions + cheat sheet follow. `czt`/chezit retired.
- CI: `check-templates.sh` renders every env set into a throwaway `$HOME` via `mise bootstrap dotfiles apply`
  and runs today's syntax checkers; a Windows job renders `windows,dev`.

## 9. Bootstrap, fleet, doctor, updates, CI, invariants

- `bootstrap.sh` (~200 lines): same flags; preflight (`git`, `curl`; no `make`); clone or move the checkout
  to `~/.config/mise`; install the pinned, sha256-verified mise into `~/.local/bin`; write `config.local.toml`
  on first run (prompts via `/dev/tty`, or copied from an existing chezmoi config during migration);
  self-register in `hosts.conf`; `mise -E <env> bootstrap -y`; push `hosts.conf`. `--doctor` → `mise run health`;
  `--check-for-updates` → `mise outdated --bump` + `mise bootstrap packages upgrade --dry-run`.
- `bootstrap.ps1`: repo path default moves; `MISE_ENV=windows,dev` persisted; chezmoi steps become
  `mise bootstrap --only dotfiles,tools -y` (PR3); `$PortableTools` unchanged except chezmoi removed.
- Fleet: `update-hosts.sh` keeps its interface; remote command = `cd ~/.config/mise && git pull --ff-only &&
  mise -E <env> bootstrap -y`; env from the `hosts.conf` group + a remote WSL probe.
- Updates: `bump-versions.sh` → `mise outdated --bump --json` → `mise config set` (EXCLUDE: typescript,
  zjstatus, python, gopls, mise) → `mise lock --platform linux-x64,windows-x64`; weekly workflow unchanged.
- CI: `jdx/mise-action` with `MISE_CONFIG_DIR` = workspace; `mise install shfmt gitleaks`; `mise config ls`,
  `mise tasks validate`, `mise -E <env> bootstrap plan` per env set.
- Invariants: pins read from TOML (tomllib); LF/0755 (now incl. `tasks/*`), BOM, sentinels, completion
  parity, TS coupling, zjstatus floor, python-libs parity, lockfile coverage per tool, three-way mise pin
  equality, `VCPKG_ROOT` ↔ repos key. `gen-tool-memory.sh` reads the TOML; `.claude` hooks trigger on
  `config*.toml` and `tasks/`.

## 10. Migration of existing hosts, rollback, risks

- PR1: `bootstrap.sh` moves the checkout and writes `sourceDir` into the chezmoi config; `make tools` =
  `mise install` + verify; sweep removes the legacy binaries (`/usr/local/bin` on dev, `~/.local/bin` on
  prod), `/usr/local/lib/helix`, `/etc/profile.d/local-bin.sh`, eget, the stamps dir.
- PR2: `bootstrap.sh` runs `mise bootstrap`; sweep retires the dozzle unit/env, the chezmoi pueued unit,
  `/usr/local/share/vcpkg`; `chezmoi apply` runs from the `bootstrap` task for this PR only.
- PR3: first apply uses `--force-dotfiles`; sweep removes `~/.config/chezmoi` (keeping `key.txt` if
  present), the state db, the chezmoi binary; Windows drops the portable chezmoi.
- Rollback: each PR is a `git revert`; the previous `bootstrap.sh` reinstalls what its sweep removed.
- Risks: aqua asset vs glibc → verify gate + `github:` override; all-or-nothing dnf → EL9-verified list;
  firewall backend absent → fallback hook; mise churn → exact pin + `min_version`; Windows copy semantics
  → `wsr`; Claude Code session history keyed on the old path is orphaned (in-repo memory unaffected).
  Every PR is proven on the WSL host before `update-hosts.sh` touches the other nine.
