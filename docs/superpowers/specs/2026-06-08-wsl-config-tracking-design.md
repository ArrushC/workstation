# WSL config tracking — design

**Date:** 2026-06-08
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

This workstation runs inside WSL, but the repo tracks none of the host's
WSL configuration. The two files that actually configure WSL — the per-distro
`/etc/wsl.conf` (Linux side) and the global `%USERPROFILE%\.wslconfig`
(Windows side) — are currently hand-managed and unversioned. In particular
`/etc/wsl.conf` already carries the load-bearing `appendWindowsPath=false`
perf fix (see `.claude/memory/project_wsl_appendwindowspath_false.md`), which
today must be applied **by hand** on every WSL host; the tracked rc PATH
re-add is inert until someone does. We want both files version-controlled and
deployed by the repo like every other tool, so a fresh clone reproduces them.

## Goal

Make the repo the **source of truth** for both WSL config files and have
bootstrap/apply **deploy** them to the host:

- `/etc/wsl.conf` ← deployed by a Make target (sudo-install), Linux side.
- `%USERPROFILE%\.wslconfig` ← deployed by chezmoi, Windows side.

## Constraints that shape the design

Two hard repo invariants make a single unified mechanism impossible, so each
file uses the mechanism the repo already has for its location:

1. **Make never runs on Windows** → the Windows-side `.wslconfig` cannot be a
   Make target; it must be chezmoi-managed.
2. **chezmoi owns `$HOME` only** (`.chezmoiroot`, no system-wide target) → the
   root-owned `/etc/wsl.conf` cannot be chezmoi-managed; it uses the existing
   `configs/` → `/etc/` sudo-install pattern (`dozzle-service`/`cockpit-service`).

Rejected alternatives:
- *Both via chezmoi* — would require chezmoi to write outside `$HOME`, fighting
  the `$HOME`-only invariant.
- *One Make target for both* — Make can't touch the Windows file.

## Design

### Part A — `/etc/wsl.conf` (Linux-side, per-distro)

**Tracked source:** new file `configs/wsl/wsl.conf`, a **verbatim copy** of
this host's current `/etc/wsl.conf` (decision: hardcode current values,
including `[user] default=arrush.chaturvedi` — no sed-substitution, unlike
`dozzle.env`). Captured baseline:

```ini
[boot]
systemd=true

[automount]
enabled=true
options="metadata,umask=22,fmask=11"
mountFsTab=true

[network]
generateHosts=true
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false

[user]
default=arrush.chaturvedi
```

**Deploy target:** new `wsl-config` target in `makefile/Makefile`, modeled on
`cockpit-service`:

- **Gating:** runs only when `IS_WSL=true` **and** `HAS_SUDO=true`. `IS_WSL`
  already exists in `scope.mk`. On non-WSL hosts, or WSL without sudo (e.g.
  `MODE=prod`), the recipe prints a skip message and no-ops. Gate via a
  combined `ifeq` on `$(IS_WSL)`/`$(HAS_SUDO)` (analogous to cockpit's
  `ifeq ($(MODE),dev)` else-skip branch).
- **Install:** `$(SUDO) install -m 0644 ../configs/wsl/wsl.conf /etc/wsl.conf`.
- **Stamp:** content-hash stamp so editing the tracked file auto-redeploys —
  `$(STAMP)/wsl-config-<sha>.done`, where `<sha>` is a short
  `sha256sum ../configs/wsl/wsl.conf`. (Mirrors the "stamp filename encodes
  the re-run trigger" philosophy used for version-baked stamps; wsl.conf has
  no version, so content hash is the trigger.)
- **Restart reminder:** after installing, print a clear note that
  `wsl --shutdown` (run from a Windows terminal) is required for changes to
  take effect — the distro only re-reads `wsl.conf` on restart.
- **Clean target:** `clean-wsl-config` removes `/etc/wsl.conf` (via `$(SUDO)`)
  and the stamp. (Matches `clean-cockpit-service`.)
- **Wiring:** add `wsl-config` to the **base** `provision` line
  (`provision: packages tools user-tools shell dotfiles wsl-config`), NOT the
  `MODE=dev`-only block — WSL config is foundational, not dev-tooling, and the
  recipe self-skips off-WSL. Also surface it in the `list` and `help` target
  output (e.g. "wsl-config — install /etc/wsl.conf (WSL hosts only)").

**Synergy:** deploying `wsl.conf` from the repo **automates** the manual
`appendWindowsPath=false` flip described in
`project_wsl_appendwindowspath_false.md`. The tracked rc PATH re-add and the
`wsl.conf` flip now ship together, so the rc block is no longer inert on a
fresh host. (Restart still required; the target prints the reminder.) The
memory's "NOT repo-tracked" statement becomes false and must be updated.

### Part B — `%USERPROFILE%\.wslconfig` (Windows-side, global WSL2 VM)

**Tracked source:** new chezmoi file `chezmoi/dot_wslconfig` → target
`~/.wslconfig` (= `%USERPROFILE%\.wslconfig`). Plain file (not `.tmpl`):
`.wslconfig` is global per Windows machine, so no host-specific templating.

**Initial content (decision: commented template):** a documented `[wsl2]`
skeleton with all keys commented out, so deploying it is a safe no-op until
the user sets values. Sketch:

```ini
# .wslconfig — global WSL2 settings (all distros). Applies after `wsl --shutdown`.
# Uncomment and tune as needed. Docs: https://learn.microsoft.com/windows/wsl/wsl-config
[wsl2]
# memory=8GB          # cap VM memory (default: 50% of host)
# processors=4        # cap vCPUs (default: all)
# swap=0              # swap size; 0 disables
# networkingMode=NAT  # or 'mirrored'
# dnsTunneling=true
# firewall=true
```

**OS gating:** add `.wslconfig` (the **target path**, per the
`.chezmoiignore.tmpl` target-path tripwire) to the **Linux/macOS** ignore
block in `chezmoi/.chezmoiignore.tmpl`, so it only lands on Windows. The
Windows block leaves it deployed.

**Restart-reminder script (`run_onchange`):** new
`chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl`,
modeled on `run_onchange_install-wezterm-terminfo.sh.tmpl`:

- **OS gate in the body:** `{{ if eq .chezmoi.os "windows" -}}` … `{{ end -}}`
  (`.chezmoiscripts/` is NOT covered by `.chezmoiignore`; non-Windows renders
  empty and chezmoi skips zero-byte scripts).
- **Re-run trigger:** embed the rendered `.wslconfig` content hash in a comment
  (`# .wslconfig hash: {{ include "dot_wslconfig" | sha256sum }}`) so the
  `run_onchange` semantics fire the script **only when `.wslconfig` changes**.
- **Body:** prints a reminder to run `wsl --shutdown` for the change to take
  effect. **ASCII-only text** (no `⚠`/Unicode glyphs) to avoid the PowerShell
  5.1 BOM-decoding tripwire — a chezmoi-rendered temp script won't carry a BOM.
  Soft-fail / no side effects beyond the print.
- **Interpreter:** chezmoi's built-in default runs `.ps1` with
  `powershell -NoLogo` on Windows; `.chezmoi.toml.tmpl` has no interpreter
  override today. **Verify** during implementation that the script executes on
  a Windows apply; if not, add an `[interpreters.ps1]` entry to
  `.chezmoi.toml.tmpl`.

## Documentation & memory updates (required by CLAUDE.md)

This adds user-facing surface, so in the **same commit**:

- **README.html** (+ `docs/README/README.css`/`.js` if needed): a WSL-config
  subsection under §setup-wsl — the two files, what each controls, and the
  `wsl --shutdown` requirement; add `make wsl-config` to the make-target
  reference; optionally a §troubleshooting entry. Decision test passes (a
  README-only reader must be able to operate the new target).
- **CLAUDE.md:**
  - Extend the "`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed"
    invariant to list `/etc/wsl.conf` via the `wsl-config` target, noting the
    `IS_WSL`+`HAS_SUDO` gating.
  - Add `.wslconfig` to the Windows-gated chezmoi paths (and the
    `run_onchange` reminder script to the relevant notes).
- **docs/claude/file-care.md:** `configs/wsl/wsl.conf` is the source of truth;
  the deployed `/etc/wsl.conf` is overwritten by `wsl-config` (don't hand-edit
  the live file). `.wslconfig` initial content is a commented template.
- **.claude/memory/project_wsl_appendwindowspath_false.md:** update the "NOT
  repo-tracked" line — `wsl.conf` is now repo-deployed, and the rc re-add +
  `wsl.conf` flip ship together (restart still required).
- **CLAUDE_CHANGELOG.md:** append a row.

## File-care tripwires touched

- `chezmoi/.chezmoiignore.tmpl` — **target-path** patterns only (`.wslconfig`,
  not `dot_wslconfig`). Verify with `chezmoi ignored` (Linux lists
  `.wslconfig`) and the Windows-native check (does NOT list it).
- New `.chezmoiscripts/` PS1 script — OS-gate in the **body**, not
  `.chezmoiignore`. ASCII-only to avoid the PowerShell 5.1 BOM tripwire.
- `makefile/Makefile` recipe lines are **tab-indented**; follow the
  `cockpit-service` shape exactly (stamp dir `mkdir -p $(@D) && touch $@`).

## Verification

- `make wsl-config MODE=dev` on this WSL host installs `/etc/wsl.conf`
  (compare `diff configs/wsl/wsl.conf /etc/wsl.conf`), prints the restart
  reminder, writes a content-hash stamp; a second run is a no-op; editing
  `configs/wsl/wsl.conf` re-triggers.
- On a non-WSL host (or `MODE=prod`), `make wsl-config` prints the skip
  message and writes nothing.
- `chezmoi ignored` lists `.wslconfig` on Linux; Windows-native
  `chezmoi ignored --source <repo>` does not.
- `chezmoi apply` on Windows deploys `%USERPROFILE%\.wslconfig` and the
  `run_onchange` reminder fires only when `.wslconfig` changed.
- `configs/wsl/wsl.conf` is LF-only (it's a Linux `/etc` file).

## Out of scope (YAGNI)

- Per-host variation of `wsl.conf` (decision: hardcode; effectively
  single-user/host today). If a second distinct WSL host appears later,
  revisit with sed-substitution (`@WSL_DEFAULT_USER@`) — the `@DOZZLE_VERSION@`
  precedent.
- Automatically running `wsl --shutdown` (can't — it kills the running distro
  from inside; only a Windows-side action). We only remind.
- Tracking other WSL-adjacent state (distro list, `wsl --export` images).
