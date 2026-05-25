# CLAUDE.md

`workstation` is a self-contained dev-environment-provisioning system (Make + chezmoi) for Linux hosts + one Windows host.

**User-facing reference is `README.html`** (open in a browser from the repo root — loads `README.css` + `README.js` as siblings). This file is Claude-internal: load-bearing invariants, file-handling gotchas, verification recipes. When in doubt, point users at README.html sections rather than re-explaining them here.

## Claude memory routing

Project-scoped memories (user/feedback/project/reference, per the standard `auto memory` taxonomy in the system prompt) live in **`.claude/memory/`** at the repo root — committed, code-reviewable, reproducible after a fresh clone. Write new memory files to `.claude/memory/<slug>.md` and update the index at `.claude/memory/MEMORY.md`. **Do NOT write to the home-dir memory path the system prompt suggests** (`~/.claude/projects/.../memory/`) — that path is intentionally left unsymlinked, so writes there would land outside source control and be invisible to other checkouts and reviewers. Escalate to a host-global memory location ONLY when the user explicitly asks for a memory to apply across all projects (and surface that scope choice in your reply so it's auditable).

## Before you change anything

The repo has a long history of regressions, and the load-bearing rules below were written in response to specific past breakage. Before editing a tricky area:

```bash
git log --oneline -- <path>            # prior fixes/reverts on this file
git log -p -S '<symbol>' -- <path>     # when a symbol was added/removed and why
git log --all --grep='<keyword>'       # search commit subjects (e.g. "crlf", "chmod", "preserve-env")
```

Also skim `CLAUDE_CHANGELOG.md` — the worked-examples archive of past user-facing changes and what README updates each required. If a change you're about to make rhymes with a row in that file, follow the same pattern.

If a fix smells like it could re-break a past pattern (CRLF endings, executable bits, `$(SUDO)` threading, sentinel blocks, parallel-make ordering), `git log` the affected file FIRST.

## Where things are documented

| Topic | See |
|---|---|
| What the repo is, three consumption modes | `README.html` §intro |
| `dev_machine` vs `prod_machine` table, MODE mapping | `README.html` §machines |
| Repo layout tree | `README.html` §layout |
| `hosts.conf` format + `manage-hosts` CLI (bash + ps1) | `README.html` §hosts |
| `bootstrap.sh` flags + 6-step flow | `README.html` §setup-linux |
| `bootstrap.ps1` / Windows + `WEZTERM_CONFIG_FILE` | `README.html` §setup-windows |
| WSL setup | `README.html` §setup-wsl |
| Adding a tool / adding a host walkthrough | `README.html` §adding |
| Daily workflows (`cze`/`cza`/`czd`/`czu`/`czs`, `make`, `update-hosts.sh`) | `README.html` §daily |
| Troubleshooting (17 entries) | `README.html` §troubleshooting |

## Load-bearing invariants

README documents the *what*; these are the *why* and the failure modes. Each one exists because the opposite was tried at some point and broke.

- **`bootstrap.sh` is a thin seed.** No `*_VERSION` constants, no install logic. Everything in `makefile/`. If `bootstrap.sh` and `scope.mk` ever disagree on scope, fix `scope.mk`.
- **Tool versions only in `makefile/versions.mk`.** Baked into the stamp filename, so bumps auto-trigger reinstall. Never re-introduce per-tool versions in `bootstrap.sh`, scripts, or new playbooks.
- **`$(SUDO)` thread.** `scope.mk` sets `SUDO := sudo --preserve-env=DEST,HELIX_RUNTIME_DEST` for dev, empty for prod. Macros (`TOOL`, `EGET_TOOL`) must use `$(SUDO)`, never literal `sudo`. The `--preserve-env` list is load-bearing — sudo's `env_reset` strips DEST otherwise. New scope-aware env vars must be added to the list.
- **`MODE` has no default.** `scope.mk` errors at parse time if missing. The choice (dev vs prod) is too load-bearing to silently fall through. `bootstrap.sh` rejects `--full` and missing flags for the same reason.
- **`EGET_TOOL` stamp-on-stamp order-only dep.** Per-tool stamps depend on `$(STAMP)/eget-$(EGET_VERSION).done` (the stamp file), NOT a phony. Putting the dep on the phony breaks `make -j` (Make resolves the stamp directly, bypassing order).
- **Makefile recipe lines must be tab-indented**, not spaces. Macro bodies use `$$` to defer expansion to rule-fire time — don't switch to single `$` without testing.
- **Wezterm sentinel block.** Auto-generated between `-- HOSTS:START` / `-- HOSTS:END` (column 0) by both manage-hosts scripts. Edit outside the sentinels freely; inside gets clobbered on the next sync. Bash uses `awk`, PowerShell uses a `(?s)` regex — both must produce identical output for the same `hosts.conf`.
- **ccstatusline sentinel block.** Auto-generated between `# CCSTATUSLINE:START` / `# CCSTATUSLINE:END` (column 0) in `chezmoi/.chezmoiignore.tmpl` by `scripts/setup-ccstatusline.sh`. Each opt-out host contributes one line of the form `{{ if eq .chezmoi.hostname "<host>" }}dot_config/ccstatusline/settings.json{{ end }}`. Hand-edits inside the markers get clobbered on any subsequent setup-ccstatusline.sh run that hits options 1, 2-persist, or 3.
- **`versions.mk` ↔ `private_settings.json.tmpl` dual-edit for `CCSTATUSLINE_VERSION`.** The version literal in `chezmoi/private_dot_claude/private_settings.json.tmpl` (the `npx -y ccstatusline@<pin>` command) MUST match `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Bumping the pin requires editing both — no chezmoi-template variable currently bridges them. Drift means Claude Code's `statusLine` command pins a different version than `setup-ccstatusline.sh` invokes interactively, with confusing UX (the interactive TUI uses one version, the live status line another).
- **Node.js is dev-only and managed via `node-runtime`.** `makefile/lib/node.sh` extracts `node-v$(NODE_VERSION)-linux-<arch>.tar.xz` from nodejs.org into `$(DEST)/_node-vX.Y.Z/` and symlinks `node`/`npm`/`npx`/`corepack` into `$(DEST)/`. Like `claude-cli`, the `node-runtime` target is bespoke (outside the macros) and only joins `provision`'s deps when `MODE=dev`. `claude-statusline` adds a dev-only dep on it so the npx the script invokes is the chezmoi-managed Linux-native one — never the Windows passthrough that crashes on WSL working dirs.
- **Claude Code `~/.claude/settings.json` is hand-managed via the chezmoi template.** `option_set_global` in `setup-ccstatusline.sh` deliberately re-adds ONLY the widget config (`~/.config/ccstatusline/settings.json`), NOT the settings.json. The ccstatusline TUI's "Install to Claude Code" path overwrites the local file with a statusLine-only block, so re-adding it would strip the other tracked keys (`skipAutoPermissionPrompt`, `tui`, `theme`, etc.) on every save. Cross-host settings changes are direct edits of `chezmoi/private_dot_claude/private_settings.json.tmpl`, committed and pushed.
- **chezmoi-level dev/prod gating via the `group` data field.** `chezmoi/.chezmoi.toml.tmpl` `[data]` block has a `group` field populated from the `WORKSTATION_GROUP` env var (bootstrap.sh sets it from the `--dev`/`--prod` flag → `GROUP_NAME="${MACHINE_TYPE}_machine"`), falling back to `promptStringOnce` for stand-alone `chezmoi init` runs. `.chezmoiignore.tmpl` consumes `.group` to ignore dev-only paths (`private_dot_claude`, `dot_config/ccstatusline`) on prod_machine hosts. A `hasKey` guard makes the gate no-op on legacy chezmoi.toml files (pre-`group`-field), so re-running `chezmoi init` (or `bootstrap.sh --dev|--prod`) on existing hosts is the migration step. When you add a new chezmoi-tracked path that should be dev-only, list it inside the existing `{{ if and (hasKey . "group") (ne .group "dev_machine") }}` block.
- **Three-piece WSL invariant** in `chezmoi/dot_config/wezterm/wezterm.lua` + `chezmoi/dot_bashrc.tmpl`:
  1. `default_cwd='~'` loop over `wezterm.default_wsl_domains()` — first tab opens in `/home/<user>`.
  2. `smart_new_tab` callback on `CTRL+SHIFT+T` — for WSL panes without tracked cwd, spawns via `DomainName` (NOT `SpawnCommandInNewTab { cwd='~' }`, which tilde-expands on Windows and lands you in `/mnt/c/Users/<user>`).
  3. OSC 7 emission via `__wezterm_osc7` in `PROMPT_COMMAND` — lets `CTRL+SHIFT+T` inherit current pane's cwd post-bootstrap.
  Each piece covers a distinct failure mode. Keep all three.
- **`</dev/tty` redirect in chezmoi init.** Load-bearing under `curl | bash` — script stdin is the pipe, so `chezmoi`'s `promptStringOnce` reads EOF without the redirect. Make recipes can't do this either, which is why `dotfiles.mk` only runs `chezmoi update`, never `init`. First-run `init` is `bootstrap.sh`'s job.
- **WSL detection is centralized in `is_wsl()`** in `bootstrap.sh` (checks `$WSL_DISTRO_NAME` + `/proc/version`). If it ever needs to distinguish WSL 1 / WSL 2, extend the helper — don't introduce parallel detection.
- **chezmoi source dir is `chezmoi/`**, not the repo root. `.chezmoiroot` (one-line file at root containing `chezmoi`) redirects chezmoi there. Without it, `dot_bashrc.tmpl` would map to `~/chezmoi/.bashrc`. Don't delete or edit `.chezmoiroot`.
- **chezmoi naming conventions** (relative to `chezmoi/`): `dot_X` → `~/.X`; `dot_config/X` → `~/.config/X`; `private_X` enforces 0600 files / 0700 dirs (required for `~/.ssh/` since OpenSSH refuses world-readable config); `.tmpl` triggers Go templates; `AppData/`, `Documents/` are Windows-only (gated via `.chezmoiignore.tmpl`).
- **`.chezmoiscripts/` are NOT covered by `.chezmoiignore`.** OS-gate via the script body's `{{ if eq .chezmoi.os "linux" }}…{{ end }}` (empty render → chezmoi skips zero-byte scripts), not via ignore patterns.
- **Only two valid host groups**: `dev_machine` and `prod_machine`. Both manage-hosts scripts reject anything else. The group drives `MODE` derivation in `update-hosts.sh`. A third group requires extending `scope.mk` AND `update-hosts.sh`'s case branch.

## Conventions and rules of thumb

- **Never edit the wezterm SSH-domains block by hand** between sentinels — clobbered on next sync.
- **Don't fixed-width-pad `hosts.conf`** — manage-hosts re-pads on every save.
- **`scripts/manage-hosts.sh` and `scripts/manage-hosts.ps1` are a parity pair.** Every user-visible capability (flags, menu options, prompts, defaults, post-add flow, output glyphs) must exist in both. Change them in the same commit. Drift silently breaks Linux/Windows reproducibility.
- **All tool installs live in `makefile/Makefile` + `tools.mk`** — never re-introduce per-tool install logic in `bootstrap.sh`, scripts, or a new playbook.
- **Per-machine overrides go in `~/.bashrc.local`** (Linux) / `Microsoft.PowerShell_profile.local.ps1` (Windows) / `~/.ssh/config.local` (both). Un-tracked, sourced/included last.
- **`wezterm.lua` is chezmoi-tracked but NOT deployed to `%USERPROFILE%`.** `.chezmoiignore.tmpl` skips `dot_config/wezterm` on Windows; `bootstrap.ps1` sets `WEZTERM_CONFIG_FILE` to the chezmoi source path so WezTerm reads the repo file directly.
- **After editing any file under `makefile/lib/` or `scripts/`** (shell side): verify with `file <path>` (must NOT say "with CRLF line terminators") and `git ls-files --stage <path>` (must show `100755` for the lib scripts). Repairs: `sed -i 's/\r$//' <path>` and `git update-index --chmod=+x <path>`.
- **After editing `scripts/manage-hosts.ps1` or `bootstrap.ps1`**: verify they retain UTF-8 BOM. PowerShell 5.1 mis-decodes UTF-8 glyphs (`✓`, `✗`, `─`) without one and fails to parse. Restore with `[System.IO.File]::WriteAllText($path, ..., [System.Text.UTF8Encoding]::new($true))`.
- **When changing user-facing surface, update `README.html` (and `README.css` / `README.js` if needed) in the same commit, then append a row to `CLAUDE_CHANGELOG.md`.** Decision test: "Would a user reading only `README.html` still be able to operate this repo after my change?" If no, README needs an update.

What does NOT need a README update: internal Makefile refactors that don't change CLI overrides or file locations; comment edits / formatting / variable renames invisible outside `makefile/`; bumping a tool version (lives in `versions.mk`); internal shell-script refactors.

## Files Claude should be careful with

- **`chezmoi/dot_config/wezterm/wezterm.lua` SSH-domains block** — auto-gen between sentinels. Edit anywhere outside freely. On Windows, edits propagate to WezTerm immediately via `WEZTERM_CONFIG_FILE`; on non-WezTerm Linux hosts the file is ignored by chezmoi.
- **`hosts.conf`** — prefer the manage-hosts scripts; manual edits lose dynamic padding/sort until next save. Column 4 (group) must be `dev_machine` or `prod_machine`.
- **`.chezmoiroot`** — one-line file containing `chezmoi`. Don't delete or edit; without it, all `dot_*` paths break.
- **`bootstrap.sh`** — thin seed only. No per-tool versions, no install logic, no inlined scope values (they come from `scope.mk`).
- **`makefile/Makefile` and `tools.mk`** — recipe lines must be tab-indented. Macro bodies use `$$` for deferred expansion. `EGET_TOOL` adds an order-only dep on the eget stamp, not the phony — preserve under any refactor or parallel builds will race.
- **`makefile/scope.mk`** — single source for `MODE` → `DEST` / `SUDO` / `HAS_SUDO` / `INSTALL_PACKAGES`. Parse-time error on missing MODE is intentional.
- **`makefile/{packages,shell,dotfiles}.mk`** — `packages.mk` is a no-op when `INSTALL_PACKAGES=false`. `shell.mk` branches on `HAS_SUDO`. `dotfiles.mk` is gated on `~/.config/chezmoi/chezmoi.toml` existing (first-run init is `bootstrap.sh`'s job).
- **`makefile/versions.mk`** — single source for tool versions. `EGET_VERSION` pins the meta-installer itself; bumping it triggers a fresh eget install via `archive.sh`, which then runs every `EGET_TOOL` install.
- **`makefile/lib/eget.sh`** — bakes in `--to $DEST --quiet` plus an asset anti-match filter (`.sbom .sig .sha .asc .zip.gpg .deb .rpm .apk .pkg .proof`). When upstream adds a new noise file type that breaks auto-detection, add it here, not per-tool.
- **`makefile/lib/*.sh` and `scripts/update-hosts.sh`** — must be LF-only AND mode 100755 in git. A fresh clone with mode 100644 fails with `sudo: archive.sh: command not found`. See the conventions section for repair commands.
- **`chezmoi/.chezmoiignore.tmpl`** — wrong entries drop infra files into `$HOME` or skip intended dotfiles. Edit-then-test: `chezmoi diff` on a sandbox host or Windows machine before pushing.
- **`scripts/manage-hosts.ps1` and `bootstrap.ps1`** — UTF-8 with BOM (PS 5.1 dependency). See conventions section for the restore one-liner.
- **`scripts/manage-hosts.sh`** — LF-only. Edit/Write tools on Windows tend to save with CRLF; `read -r` then leaks `\r` into parsed fields. Verify with `file scripts/manage-hosts.sh`.
- **`scripts/setup-ccstatusline.sh`** — LF-only, mode 100755. Manages the `# CCSTATUSLINE:START/END` sentinel block in `chezmoi/.chezmoiignore.tmpl` via in-place awk. Edit-then-test: `bash -n scripts/setup-ccstatusline.sh` confirms syntax; a smoke run picking option 4 (skip) confirms the menu wiring before re-running for real.
- **`chezmoi/private_dot_claude/private_settings.json.tmpl`** — tracked Claude Code user settings (currently 9 keys: `statusLine`, `skipAutoPermissionPrompt`, `tui`, `theme`, `editorMode`, `verbose`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`). The `statusLine.command` line carries the pinned `ccstatusline@<version>` and MUST mirror `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Hand-managed (NOT re-added by `setup-ccstatusline.sh` — see Claude-settings invariant above). Edits apply to `~/.claude/settings.json` on `chezmoi apply` with mode 0600 (parent dir 0700 via the `private_` prefix).
- **`chezmoi/private_dot_claude/private_settings.local.json`** — tracked per-user Claude Code overrides (not `*.local`-ignored, despite the conventional name). Plain JSON (no `.tmpl` suffix). If a setting genuinely needs to vary per host, add a per-host ignore line in `chezmoi/.chezmoiignore.tmpl` rather than removing this file from tracking.
- **`makefile/lib/node.sh`** — LF-only, mode 100755. Downloads + extracts the official Node.js tarball + symlinks four bin entries (`node`, `npm`, `npx`, `corepack`) into `$(DEST)/`. The full lib tree must be preserved at `$(DEST)/_node-vX.Y.Z/` because npm/npx/corepack are JS scripts with relative symlinks into `../lib/node_modules/`. Re-installs sweep all older `_node-*` trees to avoid orphan version directories.

## Quick verification

After changes:
- `./scripts/manage-hosts.sh --sync` — regenerates the chezmoi-tracked wezterm sentinel block, no errors.
- `cd makefile && make list MODE=dev` — should show every managed tool grouped by target: 56 scope-tools (incl. `eget` itself), 3 user-tools, plus claude-cli. If a tool isn't listed, its `$(eval $(call …,…))` line in `tools.mk` didn't expand — usually because the `<NAME>_VERSION` variable referenced wasn't defined in `versions.mk`.
- `cd makefile && make -n MODE=prod provision` — dry-run prod. Should print "skipping system packages (MODE=prod, INSTALL_PACKAGES=false)" then the tool installs.
- `cd makefile && make -n MODE=dev provision` — dry-run dev. Should print dnf lines under `sudo`, then EPEL, then optional packages, then tool installs.
- `cd makefile && make help` — top-level targets. Help-only commands don't trigger `scope.mk`'s error-out.
- `cd makefile && make -j8 all MODE=prod DEST=/tmp/install-test HELIX_RUNTIME_DEST=/tmp/helix-rt STAMP=/tmp/install-test-stamps` — full sandbox install. Finishes in 25-30s; `ls /tmp/install-test | wc -l` ≈ 60. Re-run should be a sub-second no-op. **Set `GITHUB_TOKEN`** or eget hits the 60-req/hour unauthenticated limit.
- `./scripts/update-hosts.sh --check --group dev_machine` — prints planned actions without ssh'ing. Should derive `MODE=dev`.
- `./bootstrap.sh` with no flags must error. `./bootstrap.sh --dev --prod` must error. `./bootstrap.sh --full` must error with "use --dev or --prod".
- `./scripts/manage-hosts.sh --add --name t --ip 1.2.3.4 --user u --group foo --skip-confirm` must reject `foo`. PowerShell side (`-Add -Group foo`) must reject the same way.
- `chezmoi diff` on a host — no surprises. Linux: only Linux-targeted paths (dot_bashrc, dot_config/{starship,helix,zellij}, dot_gitconfig, dot_nbrc) + cross-platform `.ssh/config`. Windows: only AppData/Documents/dot_config/wezterm + cross-platform `.ssh/config`.
- `ssh -G <managed-host> | grep -iE 'serveralive|tcpkeepalive|connecttimeout'` after `chezmoi apply` — confirms keepalive defaults: `serveraliveinterval 30`, `serveralivecountmax 3`, `tcpkeepalive yes`, `connecttimeout 10`.
- WezTerm `CTRL+SHIFT+F5` in SSH tab — spawns new tab against same domain, zellij reattaches. In a local tab — toast "Not an SSH pane — nothing to reconnect".
- `bootstrap.sh --dev` and `--prod` on fresh hosts — idempotent, self-register under matching group.
- `bootstrap.sh --dev` *inside WSL* — no `hosts.conf` changes, prints "Detected WSL — skipping hosts.conf self-registration", final tip is WSL-specific.
- Fresh WSL tab after Windows `chezmoi apply` — `pwd` is `/home/<user>`, not `/mnt/c/...`.
- Inside WSL tab, `CTRL+SHIFT+T` — pre-bootstrap lands in `~`; post-bootstrap (OSC 7 active) `cd /tmp` then new-tab lands in `/tmp`.
- `bootstrap.ps1` on fresh Windows (elevated PowerShell) — choco bootstraps, tracked tools install, chezmoi applies, wezterm picks up deployed config.
- `git diff README.html README.css README.js` — verify user-facing surface still matches reality. Open in a browser — primitives (tabs, flow chips, accordion filter) must render, not just diff cleanly. If unstyled, the three files were separated; they must travel together.
