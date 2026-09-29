# Workstation simplification — design

- **Date:** 2026-09-29
- **Status:** approved in conversation; written spec pending review
- **Branch:** `refactor/simplify-purge` (PR 1; later PRs branch from `main` after each merge)

## 1. Goal

Make the repo smaller and easier to change by using mise features it currently hand-rolls, and by removing
stale, redundant and unnecessary parts. Every host must end up provisioned exactly as today: same tools,
same dotfiles, same owned/shared behaviour, same `ws*` commands. Only commands that duplicate mise built-ins
may disappear.

### Success criteria

| Measure | Today | Target |
|---|---|---|
| Version pins recorded in more than one place | 10 (mise, python, nerd font, jq, gh, helix, starship, opencode, omp, DevToys CLI) | 1 (mise itself — the bootstrap scripts must install it before any config exists) |
| `config.toml [vars]` pins | 4 | 2 (`vcpkg_version`, `zjstatus_zellij_floor`) |
| Files that bake `MISE_ENV` | 3 templates + systemd env + Windows User env var | 0 — one git-ignored `miserc.toml` per host |
| `bootstrap.ps1` | 2,838 lines | ≤ 1,400 |
| `scripts/check-invariants.sh` | 1,598 lines, 28 checks | ≤ 900 |
| `tasks/` files | 17 | ≤ 9 (logic-bearing tasks only) |
| Claude-internal docs (`CLAUDE.md` + `docs/claude/*`) | ~220 KB | ≤ 30 KB |
| User docs | `README.html` + CSS + JS (10.8k lines) + jsdom CI job | `README.md` ≤ 600 lines, no CI job |
| Historical docs | `docs/superpowers/` 109 files (46k lines), `CLAUDE_CHANGELOG.md` 248 KB | deleted (git history keeps them) |
| `mise run lint`, `scripts/check-templates.sh`, CI | green | green after every PR |
| `mise run health` on the WSL owned host; `bootstrap.ps1` on Windows | green / clean run | green / clean run after PRs 3 and 4 |

## 2. Decisions

From the brainstorming Q&A (2026-09-29):

| # | Decision | Choice |
|---|---|---|
| D1 | `README.html` console | Replace with a plain `README.md`; delete `docs/README/`, `scripts/check-readme.mjs`, the CI `readme` job |
| D2 | Windows scope | CLI tools move to mise; GUI apps move to one winget table (per-user where winget offers it) |
| D3 | Historical docs | Delete `docs/superpowers/` history and `CLAUDE_CHANGELOG.md`; this spec and its plans are the only files left there |
| D4 | Commands that duplicate mise | Remove: `bootstrap.sh --doctor/--check-for-updates`, `bootstrap.ps1 -Doctor/-CheckForUpdates`, `mise run inventory`, `REBUILD=1` |
| D5 | `auto_env` | Not adopted. `miserc.toml` pins `auto_env = false` explicitly (default flips in mise 2027.6.0) |
| D6 | LSP servers as separate `npm:` tools | Not adopted — node postinstall + the reinstall marker in `scripts/lib/mise-install.sh` stay |
| D7 | Zed on Windows | winget, machine scope, in the elevated best-effort group with SSHFS-Win (winget has no per-user Zed installer) |
| D8 | dnGrep, LogExpert | mise `github:` tools, `os = ["windows"]` (portable zips; dnGrep's winget package is machine-only, LogExpert's is `zarunbal.LogExpert`) |
| D9 | Windows health rows (fonts, BurntToast, WT/Warp presence) | Dropped with `-Doctor`; `mise doctor`, `mise bootstrap status`, `mise dot status`, `winget upgrade` remain |
| D10 | Owned-only step gating | Bootstrap hooks declared in the token-gated config files replace `env_has` checks in task bodies |
| D11 | Delivery | Five sequential PRs (§5), each green and host-verified on its own |

## 3. Verified mise 2026.9.9 facts

Each was tested against the installed binary in a throwaway `HOME`/XDG sandbox (no writes to the repo or the
real `$HOME`) unless marked otherwise. Implementers rely on these; anything not listed here must be verified
before use.

1. **`~/.config/mise/miserc.toml` with `env = [...]` selects the config set** from any cwd, with
   `XDG_CONFIG_HOME` set or unset: `mise config ls`, `mise dot status`, `mise run` (tasks see `MISE_ENV`),
   `mise bootstrap --dry-run`, and **shims run under `env -i`** (the pueued systemd unit case) all honour it.
   An exported `MISE_ENV` — even an empty one — overrides it. `auto_env` is accepted in `miserc.toml` (not in
   `config.toml [settings]`). Windows behaviour: **unverified** (PR 4 spike).
2. **TOML tasks work from the global config**: `run`, `dir`, `env`, `hide`, `description`, `depends`; extra
   CLI args pass through. `{{ config_root }}` is `$HOME` for the global config — use
   `dir = "{{ xdg_config_home }}/mise"`. A task that `depends` on a task defined only in a token-gated file
   fails with `task not found` on hosts that don't load it. File tasks get `MISE_TASK_DIR`/`MISE_TASK_NAME`.
   Task `usage` specs work (`flag "--rebuild"` → `$usage_rebuild`).
3. **Bootstrap hook names** (from the binary's own error list): `pre/post-packages`, `pre/post-repos`,
   `pre/post-dotfiles`, `pre/post-defaults`, `pre/post-user`, `pre/post-tools`, `final`. Hooks in a
   token-gated file run only when that token is active. A hook name defined in two loaded files runs **both**
   (`config.toml`'s first) — this settles the old "duplicate hook merge unverified" rule. Dry-run order puts
   `post-packages` before dotfiles and tools, so anything needing mise tools goes in `post-tools` or `final`.
4. **`github:ryanoasis/nerd-fonts` with `asset_pattern = "JetBrainsMono.tar.xz"`** installs the archive
   (98 TTFs incl. the six Mono variants); the lock records the same sha256 `font.sh` pins today
   (`04d5e8f9…10cf`); `mise outdated --bump` offers bumps. The archive is 7.3 MB.
5. **zellij 0.45.1 loads `file:~/…` plugin paths** (`RunPluginLocation::parse` has an explicit `file:~`
   branch, then `shellexpand::full`; verified from source, not a live session). mise maintains
   `installs/github-dj95-zjstatus/latest -> ./<version>`. The expanded absolute path becomes the plugin's
   permission-cache key (stable across bumps because it contains `latest`).
6. **typescript-language-server 6.0.1 cannot find TypeScript when installed as a separate `npm:` tool**
   (`Could not find a valid TypeScript installation` unless every client passes `tsserver.path`). Hence D6.
7. **`mise generate git-pre-commit --task lint --write`** writes a 4-line `.git/hooks/pre-commit` that runs
   `mise run lint`; it is ignored while `core.hooksPath` is set.
8. **A comment line starting `# MISE_ENV` in a file task is parsed as a `#MISE` directive** (`tasks/update:10`
   warns `unsupported spec key _ENV` in `mise tasks validate`).
9. mise does **not** delete a deployed dotfile when its `[dotfiles]` entry is removed.

## 4. End state

### Kept, simplified

- `bootstrap.sh` — clone, install pinned mise, resolve mode, write `config.local.toml` + `miserc.toml`,
  `mise install` + `mise bootstrap`, login shell, next steps. Flags: `--reinstall`, `--yes`, `--help`.
- `bootstrap.ps1` — install pinned mise, clone, `config.local.toml` + `miserc.toml`,
  `mise bootstrap --only dotfiles,tools`, winget apps, shortcuts, SSH launchers, Nushell init files,
  BurntToast, Claude Code + settings merge, python-env, fonts, SSH key.
- Config files and tokens unchanged in shape: `config.toml`, `config.linux.toml`, `config.owned.toml`,
  `config.host.toml`, `config.native.toml`, `config.wsl.toml`, `config.windows.toml`, `config.local.toml`;
  locks `mise.lock`, `mise.linux.lock`, `mise.owned.lock`. Comments become short, present-tense "why" notes
  with no PR/ruling/incident references.
- File tasks with real logic: `bootstrap`, `claude`, `health`, `update`, `python-env`, `fonts`, `vcpkg`,
  `verify-tools`, `check-updates`. No shared boilerplate preamble.
- TOML tasks: `lint`, `fmt`, `secrets`, `ps-lint`, `bump-versions`, `install-hooks` in `config.toml`;
  `statusline`, `enable-el-repos` (hidden) in `config.host.toml`.
- `scripts/`: `check-invariants.sh`, `check-templates.sh`, `check-ps.ps1`, `bump-versions.sh`,
  `gen-tool-memory.sh`, `setup-ccstatusline.sh`, `python-env.txt` (new, shared lib list), the remaining
  `test-*` scripts; `scripts/lib/`: `mise-env.sh`, `mise-install.sh`, `python-env.sh`, `vcpkg.sh`,
  `enable-el-repos.sh`, `claude-settings-merge.sh`, `verify-binary.sh`, `test-verify-binary.sh`.
- `README.md`, `CLAUDE.md`, `docs/claude/verification.md`, `docs/windows/application_list.md` (manual list
  only), `.claude/memory/` (pruned), `.claude/hooks/` (shared helper).

### Deleted

`README.html`, `docs/README/`, `scripts/check-readme.mjs`, `CLAUDE_CHANGELOG.md`,
`docs/superpowers/{plans,specs}/*` (except this spec and its plans), `docs/claude/invariants.md`,
`docs/claude/file-care.md`, `.githooks/`, `tasks/{inventory,install-hooks,lint,fmt,secrets,ps-lint,bump-versions,statusline,enable-el-repos}`
(→ TOML tasks), `scripts/lib/{check-updates,font,zellij-plugin}.sh`, `scripts/test-zellij-plugin.sh`,
`scripts/install-nerd-fonts.ps1`, `dotfiles/config/environment.d/10-mise.conf.tera`.

## 5. Delivery — five PRs

Each PR: feature branch → PR → user merges. Each PR deletes the checks and bump-script code that guarded any
duplication it removes, in the same PR, so lint stays meaningful. Each PR updates `README.md`/`CLAUDE.md`
for whatever user-facing or rule surface it changes.

### PR 1 — Purge and docs (no behaviour change)

1. Delete `docs/superpowers/` history (keep this spec + plans) and `CLAUDE_CHANGELOG.md`. The CLAUDE.md rule
   "update README.html in the same commit, then append a changelog row" becomes "update README.md in the
   same commit".
2. Replace `README.html` + `docs/README/` with `README.md`: what it is, owned vs shared, setup (Linux,
   Windows, WSL, the two Windows terminals), daily commands (`ws*`, `mise run health`, updating), adding a
   tool / a dotfile, troubleshooting entries that still apply (from the current 32). No tool catalogue —
   `config*.toml` and `mise ls` are the list. Delete `scripts/check-readme.mjs` and the CI `readme` job;
   drop `node_modules/` from `.gitignore`. Repoint every `README.html` reference (bootstrap script
   comments, CLAUDE.md, hooks, memory) to `README.md`.
3. Rewrite `CLAUDE.md` to current rules only (≤ 12 KB): purpose, memory routing, hooks, the load-bearing
   invariants as true one-liners, file-care tripwires, verification pointer. Fold the still-true content of
   `docs/claude/invariants.md` and `docs/claude/file-care.md` into it and delete both. Trim
   `docs/claude/verification.md` to recipes that still apply.
4. Rewrite `config*.toml` comments to present tense (~130 narrative lines), fixing the known false ones
   (`config.windows.toml:19` "12" → 11 templates, `:44` zed location, `config.owned.toml:68,71`,
   `config.toml:56-57` Git Credential Manager source).
5. Resolve every dangling reference: `final-fix-brief.md` (15 sites), `docs/superpowers/plans/…` and
   `specs/…` citations in code/config/docs, the memory files that cite them.
6. Stale code and comments, behaviour-neutral:
   - the removed-TUI clean-up in `scripts/lib/python-env.sh` and `bootstrap.ps1`
   - the pre-fix plugin-dir clean-up in `zellij-plugin.sh` (the file itself goes in PR 3)
   - WezTerm-nightly-only options in `bootstrap.ps1`: TagFilter/TagSort/StringSort, and the PIN-ME check that can never fire
   - chezmoi/Make references in comments across `scripts/`, `tasks/`, `dotfiles/*.tera`, `config.nu.tera`
   - `PSScriptAnalyzerSettings.psd1` names that no longer exist
   - the `.age` allowlist in `.gitleaks.toml`
   - `check-invariants.sh`'s stale "dropped packages" list and comments
   - the `tasks/update:10` comment parsed as a `#MISE` directive (§3.8)
   - the `$MigratedMarker` comment (the file name stays so existing hosts don't re-force)
7. `.claude/memory/`: delete or trim stale entries; keep the guardrails (TUI removed, hosts list removed),
   the feedback files, and the Windows/WSL gotchas; update `MEMORY.md`. Prune `.claude/settings.local.json`
   allowlist entries that name removed tools or paths (e.g. WezTerm).
8. `docs/windows/application_list.md`: keep only the manual-install list (the auto-installed section
   duplicates the tool tables); `bootstrap.ps1` keeps printing it.

Verification: `mise run lint`, `scripts/check-templates.sh`, `mise tasks validate`, CI green;
`rg -n 'final-fix-brief|README\.html|CLAUDE_CHANGELOG|docs/claude/(invariants|file-care)|docs/superpowers/'`
finds no reference to a deleted file (references to this spec and its plans are fine).

### PR 2 — Tasks on mise

1. Move `lint`, `fmt`, `secrets`, `ps-lint`, `bump-versions` into `config.toml [tasks]` with
   `dir = "{{ xdg_config_home }}/mise"`; `statusline` and hidden `enable-el-repos` into `config.host.toml`
   (Linux owned only, so no `env_has owned` check and no Windows exposure). Delete their `tasks/` files.
2. Replace `.githooks/` + `tasks/install-hooks` with an `install-hooks` TOML task:
   `git config --unset core.hooksPath` then `mise generate git-pre-commit --task lint --write`.
3. Remove the copy-pasted preamble (`root=`/`state=`/`env_has`/SC2034 disables) from the remaining file
   tasks; derive the repo root from `MISE_TASK_DIR`.
4. Gate owned-only work by where the hook lives, not by `env_has` (D10, §3.3):
   - Split the owned-only steps out of `tasks/bootstrap` into a new `tasks/claude`: Claude Code install,
     plugins, settings merge, `settings.local.json` seed, and the herdr plugin.
   - `config.host.toml` runs `vcpkg` and `claude` from a `final` hook.
   - `config.native.toml` runs `fonts` from a `final` hook.
   - `tasks/bootstrap` keeps only what every host runs: `depends = ["python-env"]`, cheat sheets, the nb
     notebook, the tldr seed, and zjstatus until PR 3.
   - `vcpkg`, `fonts` and `claude` no longer check `MISE_ENV` themselves.
5. `REBUILD=1` → a usage flag: `mise run python-env --rebuild`. (Refines the conversational "`--force`"
   note. Rebuilding on a `sources`/`outputs` key would need the python version in a template, and after
   PR 3 that version lives only in `[tools]`.)
6. `tasks/check-updates` becomes `mise outdated --bump`, `dnf check-update` (hosts that load
   `config.host.toml`), and one `git ls-remote --tags` comparison for `vars.vcpkg_version`. Delete
   `scripts/lib/check-updates.sh` and the `claude-cli` "rolling" row.
7. Remove `bootstrap.sh --doctor/--check-for-updates` and their helpers (`do_doctor`, `do_check_updates`,
   `report_repo_state`, `require_repo`) plus their entries in `_bootstrap.sh`, `completions.bash`, README.
   Delete `tasks/inventory`.
8. `tasks/health`: drop the legacy `/usr/local` and old-pueued-unit rows.
9. Checks: `check_completion_parity` shrinks to the remaining flags; LF/0755 and `fmt`/`check_shfmt` file
   lists follow the moved tasks and share one list (fixes the `completions.bash` drift); `mise tasks
   validate` must stay clean.

Verification: lint; `mise tasks ls` shows the same user-facing tasks minus `inventory`/`install-hooks`
file versions; `MISE_ENV=<each token set> mise bootstrap --dry-run` shows the new hooks only on the right
sets; `mise run install-hooks` then a test commit runs the hook; user runs `wsu` on WSL (sudo) and
`mise run health` is green.

### PR 3 — One place per value

1. **`miserc.toml`** (§3.1):
   - `scripts/lib/mise-env.sh` stays the only producer of the Linux token set and gains the job of writing
     `~/.config/mise/miserc.toml` (`env = [...]`, `auto_env = false`).
   - `bootstrap.sh` and `tasks/update` call it. `tasks/update` no longer exports `MISE_ENV`, and
     `mise-install.sh` drops its `MISE_ENV` guard.
   - `miserc.toml` joins `.gitignore`.
   - Removed:
     - the `MISE_ENV` conditional in `dotfiles/zshenv.tera` and `dotfiles/bashrc.tera`
     - `dotfiles/config/environment.d/10-mise.conf.tera` and its `[dotfiles]` entry
     - both `systemctl --user set-environment` calls
     - health's "MISE_ENV rc" and "MISE_ENV live" rows (replaced by one row: miserc tokens match the saved
       mode, and a warning if `MISE_ENV` is exported in the shell or the systemd user manager)
     - `check_mise_env_three_way`
   - **Host migration** (in `tasks/update` and `bootstrap.sh`, marked for removal once every host has run it):
     - delete `~/.config/environment.d/10-mise.conf` when it contains only our line
     - `systemctl --user unset-environment MISE_ENV`
     - tell the user to open a new shell
2. **Nerd Font as a mise tool** (§3.4):
   - `"github:ryanoasis/nerd-fonts" = { version = "3.5.1", asset_pattern = "JetBrainsMono.tar.xz" }` in
     `config.owned.toml`, for both OSes. WSL owned hosts download 7.3 MB they don't use; accepted.
   - `tasks/fonts` copies the six Mono TTFs from `mise where` into
     `~/.local/share/fonts/JetBrainsMonoNerdFontMono` and runs `fc-cache`.
   - Delete `scripts/lib/font.sh` and `vars.nerd_font_version`.
   - Until PR 4, Windows still pins the font in `install-nerd-fonts.ps1`, so two things stay for one PR:
     - `check_version_pins` compares the tool pin with that file (a two-way check instead of three-way)
     - the bump script keeps the font tool in `EXCLUDE`
   - The `vars` parts of `check_vars_pin_coverage` and `EXCLUDE_VARS` go now.
3. **python-env on mise's Python:**
   - `scripts/lib/python-env.sh` builds the venv with `uv venv --python "$(mise where python)/bin/python3"`
     and drops `uv python install`.
   - The stamp key becomes the interpreter path plus the lib-list checksum.
   - The lib list moves to `scripts/python-env.txt`, which Windows also reads in PR 4.
   - Delete `vars.python_version` and the `#MISE env` lines that read it.
   - Health compares `wpy`'s version to `mise current python`.
   - One-time: `uv python uninstall` the uv-managed CPython copies python-env used to install.
   - Remove the python parts of `check_version_pins` and `EXCLUDE_VARS`, and `check_python_env_parity`
     once PR 4 lands. Until then the parity check points at the file.
4. **zjstatus** (§3.5): `dotfiles/config/zellij/config.kdl` loads
   `file:~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm`.
   - Delete `scripts/lib/zellij-plugin.sh`, `scripts/test-zellij-plugin.sh`,
     `check_zellij_plugin_installer`, and the step in `tasks/bootstrap`.
   - The health row checks that path instead.
   - `check_zellij_config` asserts the new form.
   - Host migration: zellij asks once per host to re-grant the plugin's permissions.
   - Delete the stale `~/.local/share/zellij/plugins/zjstatus.wasm` copy.
5. `bump-versions.sh`: `EXCLUDE_VARS` and its special cases go. `check_bumper_exclude` and
   `check_vars_pin_coverage` shrink to what is left (vcpkg, the zjstatus floor).

Verification: lint; `scripts/check-templates.sh` (all four token sets still render; the template check sets
`MISE_ENV` explicitly, which overrides miserc); sandbox install of the font tool; user runs `wsu` on WSL,
opens a new shell, and `mise run health` is green. pueued is active, the zellij status bar loads, and `wpy`
reports the pinned python.

### PR 4 — Windows on mise

1. **Spike (first task):** on Windows, confirm miserc is honoured (sandbox `USERPROFILE`), and that
   `mise lock` covers `windows-x64` for every tool moving in step 2. Fallback if miserc isn't honoured:
   keep the User `MISE_ENV` variable on Windows only, and record why.
2. **CLI tools:**
   - starship, gh, jq and helix move from `config.linux.toml` to `config.toml`. They still load on every
     Linux host, and now on Windows too; their lock entries move to `mise.lock`.
   - OpenCode and Oh My Pi drop `os = ["linux"]`.
   - DevToys CLI gets a per-platform asset (syntax verified in the spike).
   - Nushell, dnGrep and LogExpert are added to `config.owned.toml` with `os = ["windows"]`.
   - Hard-coded `workstation\nu\nu.exe` paths (Windows Terminal settings, Warp tab configs) point at the
     mise-installed Nushell.
   - `$PortableTools` shrinks to mise alone, becoming a small `Install-Mise` like `bootstrap.sh`'s.
3. **GUI apps:**
   - One `$WingetApps` table plus one loop: `winget list --id --exact` for presence, else
     `winget install --id --exact --scope user --silent`.
   - Per-user: Obsidian, DevToys, DBeaver Community, WinSCP, Beyond Compare 5, Warp, Windows Terminal.
   - Elevated, best-effort, `-SkipElevated`: SSHFS-Win and Zed (winget only; the MSI fallback goes).
   - Delete `Install-PortableTool`, `Test-InstallerPresent`, `Install-InstallerTool`, `Install-ElevatedMsi`,
     `Install-ElevatedTool`, `Install-Warp`, `Install-WindowsTerminal`, and the GitHub/tag/winget-version
     resolvers.
   - `-ForceInstaller` is replaced by `winget upgrade`.
4. Remove `-Doctor`/`-CheckForUpdates` and their helpers (`Invoke-Doctor`, `Invoke-CheckForUpdates`,
   `Show-RepoState`, `Get-LatestGitTag`, `Get-LatestWingetVersion`, `Get-InstalledAppVersion`,
   `Write-UpdateStatus`, `Write-Bad`), and their entries in `config.nu.tera`'s flag record.
5. Delete `Invoke-MiseRuntimes`/`Get-MiseRuntimesStamp`. The node-postinstall marker and `mise prune` move
   into the post-`mise bootstrap` step, so they match `mise-install.sh`.
6. **Windows python-env** uses `(mise where python)\python.exe` and `scripts/python-env.txt`.
   `$PythonEnvVersion`/`$PythonLibs` go, and so does `check_python_env_parity`.
7. **Fonts:**
   - `Invoke-InstallNerdFonts` copies from `mise where github:ryanoasis/nerd-fonts` and registers them per
     user.
   - The font tool leaves the bump script's `EXCLUDE`, and its check in `check_version_pins` goes.
   - Delete `scripts/install-nerd-fonts.ps1`, and with it the duplicate `Invoke-CurlRequest`,
     `check_curl_helper_parity`, and the second target in `test-curl.ps1`.
8. **Remove the User `MISE_ENV` variable** after writing miserc (unless the step 1 fallback applies).
9. **Checks and bump script:**
   - `check_version_pins` keeps only the mise three-way.
   - `ps1_tool_version` goes.
   - `bump-versions.sh` loses `PS1_NAME`, `ps1_field`, `ps1_set`, `bump_ps1` and their loop branches.
   - `check_bumper_exclude` shrinks to match.

Verification: `mise run ps-lint`; the Windows CI jobs that remain; the user runs `bootstrap.ps1` (fresh
shell afterwards) and confirms: tools on PATH (`starship`, `gh`, `jq`, `hx`, `nu`, `opencode`, `omp`,
`DevToys.CLI`); winget apps present; Windows Terminal/Warp open Nushell; `wpy` works; font present;
`mise dot status` clean.

### PR 5 — Checks and hooks tidy

1. `.claude/hooks/lib.sh`: one JSON-reading helper (jq → python3 → fail-open) sourced by the repo hooks.
   The two global hooks deployed to `~/.claude/hooks` keep their own inline copy.
2. `parity-reminder.sh` keeps only the pairs that still exist: `zshrc` ↔ `bashrc`, and the Nushell ↔
   PowerShell profile aliases.
3. `session-context.sh` reports mode/tokens from miserc.
4. `test-hooks.sh` runs under `mise run lint`.
5. `secret-guard.sh` drops the chezmoi `key.txt` match.
6. `check-invariants.sh`:
   - Delete `check_go_gopls_coupling`. It makes a network call on every commit, and the bump script's
     gopls floor already covers it.
   - Fold what remains of the pin checks into one table-driven check.
   - Delete comment debris.
7. Update `CLAUDE.md`'s hooks section.

Verification: `bash .claude/hooks/test-hooks.sh`; lint; CI.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| miserc on Windows unverified | PR 4 spike first; fallback keeps the Windows User variable (one host, documented) |
| An exported `MISE_ENV` overrides miserc (stale shells, systemd manager, old `environment.d` file) | PR 3 migration deletes the file and unsets the manager variable; rc files stop exporting; health warns while any export remains; user opens a new shell |
| Removed dotfile targets linger (§3.9) | Explicit, content-checked deletes in the migration step |
| zjstatus plugin identity changes | One-time permission prompt per host, noted in the PR description |
| Python bump: `mise prune` removes the old interpreter before python-env rebuilds | The rebuild runs in the same `mise bootstrap`; a failure leaves `wpy` broken and health reports it (today it would be stale, not broken) |
| winget doesn't see an app installed by the old vendor installer | Presence check uses `winget list`, which reads the Uninstall registry the old code used; worst case, one reinstall over the top |
| Zed moves from per-user to machine scope | The existing per-user install is detected and left alone; new hosts get one extra UAC prompt |
| Hook ordering | Hook tasks are independent of each other and of the `bootstrap` task; anything needing mise tools is in `post-tools`/`final` |
| Sudo and Windows paths can't be run by Claude | The user runs `wsu`/`./bootstrap.sh` (sudo) and `bootstrap.ps1`; everything else is lint, dry-run and sandbox-verified first |
| `core.hooksPath` left pointing at the deleted `.githooks/` | `install-hooks` unsets it; the PR description tells existing clones to run `mise run install-hooks` |

## 7. Out of scope

- Vendored code (GEF, the zsh plugins, batpipe, `_cht.sh`) and their pins.
- The LSP postinstall / node reinstall marker (D6).
- Shell rc behaviour, keymaps, themes, Warp/Windows Terminal/VS Code/Zed settings content.
- The Nushell `starship.nu`/`mise.nu` generators (could become templates later; not needed for the goal).
- Consolidating config files or tokens (`config.native.toml` gains the fonts hook, so it keeps a purpose).
- New features.
