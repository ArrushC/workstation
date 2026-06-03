# CLAUDE.md

`workstation` is a self-contained dev-environment-provisioning system (Make + chezmoi) for Linux hosts + one Windows host.

**User-facing reference is `README.html`** (open in a browser from the repo root — loads `docs/README/README.css` + `docs/README/README.js`). When in doubt, point users at README.html sections rather than re-explaining them here.

This file is Claude-internal and deliberately kept lean (it loads into context every session). It carries the **rules and tripwires**; the verbose *why*, per-file gotchas, and verification recipes live in `docs/claude/` — pointers in "Claude-internal reference docs" below. When a tripwire fires (you're about to touch a listed area/file), read the matching doc before editing.

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

User-facing docs — point users here:

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
| Dozzle + Cockpit web admin (dev_machine only) | `README.html` §stack > Web admin card; §troubleshooting; §daily-services |

## Claude-internal reference docs

Deep detail split out of this file to keep it lean. Read the matching doc when its tripwire fires:

| Doc | Read it when | Tripwire below |
|---|---|---|
| `docs/claude/invariants.md` | About to touch an architectural area (Make scope, chezmoi gating, WSL, SSH, terminfo, version pins) — full *why* + failure modes | "Load-bearing invariants" index |
| `docs/claude/file-care.md` | About to edit a specific tracked file — full per-file CRLF/BOM/mode/vendoring/sentinel/parity constraints | "Files Claude should be careful with" summary |
| `docs/claude/verification.md` | Verifying a change — the copy-paste recipe for that subsystem | — |

## Load-bearing invariants

README documents the *what*; these are the *why* and the failure modes. Each exists because the opposite was tried and broke. **One-line index below — full detail (failure stories, verify commands) in `docs/claude/invariants.md`. Read that file before acting on any entry you're about to touch.**

- **`bootstrap.sh` is a thin seed** — no `*_VERSION`/install logic; everything in `makefile/`. If it and `scope.mk` disagree on scope, fix `scope.mk`.
- **Tool versions only in `makefile/versions.mk`** — baked into stamp filenames so bumps auto-reinstall. Never per-tool versions in `bootstrap.sh`/scripts/playbooks.
- **`$(SUDO)` thread** — macros (`TOOL`, `EGET_TOOL`) use `$(SUDO)` (= `sudo --preserve-env=DEST,HELIX_RUNTIME_DEST` on dev, empty on prod), never literal `sudo`. New scope-aware env vars join the `--preserve-env` list.
- **`MODE` has no default** — `scope.mk` errors at parse time if missing; `bootstrap.sh` rejects `--full`/missing flags.
- **`EGET_TOOL` stamp-on-stamp order-only dep** — per-tool stamps depend on the eget stamp *file*, NOT the phony, or `make -j` races.
- **Makefile recipe lines are tab-indented**; macro bodies use `$$` for deferred (rule-fire-time) expansion.
- **Wezterm `-- HOSTS:START/END` sentinel block** — auto-generated by both manage-hosts scripts (awk vs `(?s)` regex, identical output); never hand-edit inside.
- **ccstatusline `# CCSTATUSLINE:START/END` sentinel block** in `chezmoi/.chezmoiignore.tmpl` — auto-generated by `scripts/setup-ccstatusline.sh`; hand-edits inside get clobbered.
- **`CCSTATUSLINE_VERSION` dual-edit** — `versions.mk` ↔ the `ccstatusline@<pin>` literal in `private_settings.json.tmpl`. No template var bridges them.
- **`JETBRAINSMONO_NERD_VERSION` triple-edit** — `versions.mk` ↔ `lib/font.sh` SHA case ↔ `install-nerd-fonts.ps1` (`.tar.xz` vs `.zip`, different hashes).
- **Node.js is dev-only via `node-runtime`** — bespoke target (outside the macros) joining `provision` only when `MODE=dev`; `claude-statusline` deps on it for the Linux-native npx.
- **Helix dev runtime needs `HELIX_RUNTIME` exported from the rc** — the dev location (`/usr/local/lib/helix/runtime`) isn't auto-discovered; rc literal (zsh+bash, dev-gated) mirrors `HELIX_RUNTIME_DEST`. Missing → silent fallback to the default theme.
- **`~/.claude/settings.json` is hand-managed via the chezmoi template** — `setup-ccstatusline.sh` re-adds ONLY the widget config, never settings.json (would strip tracked keys). Cross-host changes = direct edits of `private_settings.json.tmpl`.
- **chezmoi dev/prod gating via the `group` data field** — `.chezmoi.toml.tmpl` sets `group` from `WORKSTATION_GROUP`; `.chezmoiignore.tmpl` consumes `.group` to skip dev-only paths on prod. New dev-only paths go inside the existing `{{ if and (hasKey . "group") (ne .group "dev_machine") }}` block. Re-run `chezmoi init` to migrate legacy hosts.
- **Three-piece WSL invariant** — (1) `default_cwd='~'` over `default_wsl_domains()`, (2) `smart_new_tab` spawns via `DomainName` (not tilde cwd), (3) OSC 7 `__wezterm_osc7` hook (zsh `precmd` + bash `PROMPT_COMMAND`). Distinct failure modes — keep all three, both shells.
- **`</dev/tty` redirect in chezmoi init** — load-bearing under `curl | bash` (else `promptStringOnce` reads EOF). First-run `init` is `bootstrap.sh`'s job; `dotfiles.mk` only `chezmoi update`s.
- **WSL detection centralized in `is_wsl()`** in `bootstrap.sh` — extend the helper, don't fork detection.
- **chezmoi source dir is `chezmoi/`** via `.chezmoiroot` (one-line file at root) — don't delete/edit it, or all `dot_*` paths break.
- **chezmoi naming conventions** — `dot_X`→`~/.X`; `dot_config/X`→`~/.config/X`; `private_X`→0600/0700; `.tmpl`→Go templates; `AppData/`,`Documents/` Windows-only.
- **`.chezmoiscripts/` are NOT covered by `.chezmoiignore`** — OS-gate via the script body's `{{ if eq .chezmoi.os "linux" }}…{{ end }}`, not ignore patterns.
- **Only two valid host groups** — `dev_machine`/`prod_machine`; both manage-hosts scripts reject others. A third needs `scope.mk` AND `update-hosts.sh` changes.
- **`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed** — deployed by paired `<tool>-service` make targets (`dozzle-service`, `cockpit-service`). Chezmoi owns `$HOME` only.
- **`config.term='wezterm'` ↔ wezterm-terminfo install chain** — four artifacts move together (`ncurses` package, vendored `.terminfo`, `run_onchange` script, `config.term` flip), or TUIs error on stale hosts.
- **SSH multiplexing is gated out on Windows** — the `ControlMaster`/`ControlPersist`/`ControlPath` block in `private_config.tmpl` sits under `{{ if ne .chezmoi.os "windows" }}`. Windows OpenSSH can't multiplex (breaks every ssh incl. git). Linux/macOS keep it.
- **zsh interactive plugin load order** — in `dot_zshrc.tmpl`: fzf-tab sourced after `compinit`; **zsh-syntax-highlighting sourced LAST** (it wraps ZLE widgets, must see all prior ones incl. shift-select); zsh-autosuggestions between. Reorder → highlighting/suggestions silently break. fzf-tab needs `use-fzf-default-opts yes` to inherit the Catppuccin `FZF_DEFAULT_OPTS`. These are zsh-only — `dot_bashrc.tmpl` carries a PARITY NOTE.

## Conventions and rules of thumb

- **Never edit the wezterm SSH-domains block by hand** between sentinels — clobbered on next sync.
- **Don't fixed-width-pad `hosts.conf`** — manage-hosts re-pads on every save.
- **`scripts/manage-hosts.sh` and `scripts/manage-hosts.ps1` are a parity pair.** Every user-visible capability (flags, menu options, prompts, defaults, post-add flow, output glyphs) must exist in both. Change them in the same commit. Drift silently breaks Linux/Windows reproducibility.
- **All tool installs live in `makefile/Makefile` + `tools.mk`** — never re-introduce per-tool install logic in `bootstrap.sh`, scripts, or a new playbook.
- **Per-machine overrides go in `~/.zshrc.local`** (Linux, sourced from `dot_zshrc.tmpl`; `~/.bashrc.local` still works if you've started an interactive bash) / `Microsoft.PowerShell_profile.local.ps1` (Windows) / `~/.ssh/config.local` (both). Un-tracked, sourced/included last.
- **`wezterm.lua` is chezmoi-tracked but NOT deployed to `%USERPROFILE%`.** `.chezmoiignore.tmpl` skips `dot_config/wezterm` on Windows; `bootstrap.ps1` sets `WEZTERM_CONFIG_FILE` to the chezmoi source path so WezTerm reads the repo file directly.
- **After editing any file under `makefile/lib/` or `scripts/`** (shell side): verify with `file <path>` (must NOT say "with CRLF line terminators") and `git ls-files --stage <path>` (must show `100755` for the lib scripts). Repairs: `sed -i 's/\r$//' <path>` and `git update-index --chmod=+x <path>`.
- **After editing `scripts/manage-hosts.ps1` or `bootstrap.ps1`**: verify they retain UTF-8 BOM. PowerShell 5.1 mis-decodes UTF-8 glyphs (`✓`, `✗`, `─`) without one and fails to parse. Restore with `[System.IO.File]::WriteAllText($path, ..., [System.Text.UTF8Encoding]::new($true))`.
- **When changing user-facing surface, update `README.html` (and `docs/README/README.css` / `docs/README/README.js` if needed) in the same commit, then append a row to `CLAUDE_CHANGELOG.md`.** Decision test: "Would a user reading only `README.html` still be able to operate this repo after my change?" If no, README needs an update.

What does NOT need a README update: internal Makefile refactors that don't change CLI overrides or file locations; comment edits / formatting / variable renames invisible outside `makefile/`; bumping a tool version (lives in `versions.mk`); internal shell-script refactors; edits to Claude-internal files (this `CLAUDE.md`, `docs/claude/*`, `.claude/`).

## Files Claude should be careful with

Per-file gotchas live in **`docs/claude/file-care.md`** — read a file's entry before editing it. The cross-cutting risk categories (the tripwires):

- **LF-only + mode 100755 in git:** `makefile/lib/*.sh`, `scripts/update-hosts.sh`, `scripts/manage-hosts.sh`, `scripts/setup-ccstatusline.sh`. CRLF or mode 100644 breaks fresh clones (`sudo: archive.sh: command not found`). Repair one-liners in Conventions above.
- **UTF-8 with BOM (PowerShell 5.1):** `scripts/manage-hosts.ps1`, `bootstrap.ps1`, `scripts/install-nerd-fonts.ps1`. Restore one-liner in Conventions above.
- **Vendored — don't hand-edit; re-download at the pinned tag + refresh sha256:** `chezmoi/dot_local/share/wezterm/wezterm.terminfo`, `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`, `chezmoi/dot_config/zsh/completions/_cht.sh` (rolling — no upstream tag; bump by snapshot date + sha256, `#compdef cht.sh` stays line 1). Also the three pinned zsh plugin dirs `chezmoi/dot_config/zsh/plugins/{zsh-autosuggestions,zsh-syntax-highlighting,fzf-tab}/` — verbatim upstream, provenance in each dir's chezmoi-ignored `.vendor` sidecar; bump = re-download the pinned tag + refresh sha256 in `.vendor`.
- **Sentinel blocks (auto-generated; never edit inside):** `wezterm.lua` (`-- HOSTS:START/END`), `chezmoi/.chezmoiignore.tmpl` (`# CCSTATUSLINE:START/END`).
- **Parity pairs (change both in the same commit):** `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl`; `manage-hosts.sh` ↔ `manage-hosts.ps1`.
- **Version-pin dual/triple-edits:** `CCSTATUSLINE_VERSION` (`versions.mk` + `private_settings.json.tmpl`); `JETBRAINSMONO_NERD_VERSION` (`versions.mk` + `lib/font.sh` + `install-nerd-fonts.ps1`); `HELIX_RUNTIME` rc literal ↔ `HELIX_RUNTIME_DEST` in `scope.mk`.
- **Don't hand-edit (regenerated / placeholder-substituted):** `hosts.conf` (manage-hosts re-pads/sorts), `.chezmoiroot` (one line `chezmoi`), `configs/dozzle/dozzle.env` (`@DOZZLE_VERSION@` is sed-substituted), any `/etc/`-deployed `configs/*` copy (overwritten by its `<tool>-service` target).
- **Single-source-of-truth files:** `makefile/scope.mk` (MODE→DEST/SUDO/…), `makefile/versions.mk` (tool versions + `EGET_VERSION`), `makefile/lib/eget.sh` (the asset anti-match filter), `private_settings.json.tmpl` (tracked `~/.claude/settings.json`, 12 keys + Notification hooks → `~/.claude/notify.sh`).

## Quick verification

Recipes per subsystem are in **`docs/claude/verification.md`** — copy-paste the one matching your change (Make scope/dry-runs, sandbox install, hosts/bootstrap, chezmoi diff, SSH keepalive/mux, WezTerm/WSL/OSC 7, services, terminfo, zellij, fonts, tldr, MANPAGER). Run the relevant check and confirm the stated output before claiming done.
