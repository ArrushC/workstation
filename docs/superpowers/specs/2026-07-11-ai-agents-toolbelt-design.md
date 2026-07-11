# AI coding agents in the toolbelt: OpenCode + Oh My Pi, Claude Code native on Windows

**Date:** 2026-07-11
**Scope:** `makefile/versions.mk` + `makefile/tools.mk` (two new dev-only `EGET_TOOL`s), `bootstrap.ps1` (two `$PortableTools` entries + bespoke Claude Code step + Doctor/CheckForUpdates coverage), `scripts/check-invariants.sh` (two dual-edit pin checks), `README.html`, `CLAUDE.md` (dual-edit list + Windows-installs invariant), `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add two AI coding-agent CLIs to both the Linux dev-mode and Windows toolbelts:

- **[OpenCode](https://opencode.ai)** (`anomalyco/opencode`) — open-source terminal
  coding agent, Bun-compiled single binary.
- **[Oh My Pi](https://omp.sh)** (`can1357/oh-my-pi`, command `omp`) — batteries-included
  hard fork of Mario Zechner's Pi (LSP, DAP debugger, subagents, plan mode, Rust core),
  Bun-compiled single binary.

And close the one Claude Code gap: it is already in the Linux dev toolbelt
(`claude-cli`), but the Windows host has no native install — add a bespoke
`bootstrap.ps1` step running the official installer.

**Explicitly excluded (user decisions, 2026-07-11):**

- **Pi** (`earendil-works/pi`) — omp is an independent hard fork that fully replaces it
  (different author/binary/config dir/versioning; installing omp neither needs nor
  installs Pi). One agent covers the niche.
- **Hermes** (`NousResearch/hermes-agent`) — skipped entirely.

## Verified upstream facts (2026-07-11)

- **OpenCode** repo is `anomalyco/opencode` (`sst/opencode` 301-redirects — transferred).
  Latest **v1.17.18**. Linux x64 CLI assets: `opencode-linux-x64.tar.gz` (single binary
  inside) plus `-musl`, `-baseline`, `-baseline-musl` variants and separate
  `opencode-desktop-*` assets. Windows: `opencode-windows-x64.zip`. Tags are
  `v`-prefixed. npm `opencode-ai` exists but just wraps the same binary.
- **OpenCode AVX2 caveat:** the official installer (`https://opencode.ai/install`,
  inspected) probes `/proc/cpuinfo` for AVX2 (Windows: `IsProcessorFeaturePresent(40)`)
  and falls back to the `-baseline` asset — the regular Bun-compiled binary **requires
  AVX2** (Intel Haswell 2013+/AMD Excavator 2015+). Our `verify-binary.sh` gate is
  deliberately non-executing, so it cannot catch the SIGILL on a pre-AVX2 host. The
  fleet is modern; pin the plain asset and document `-baseline` as the escape hatch.
  The installer performs **no checksum verification**, so the eget path loses nothing.
- **Oh My Pi** latest **v16.4.4** (npm matches). Release assets are **bare single
  binaries** (`omp-linux-x64`, `omp-windows-x64.exe`, …) — no archive. Tags
  `v`-prefixed. The official installer's `--binary` mode (inspected) just curls the
  bare asset and chmods it — exactly what eget does. Binaries are self-contained
  (Bun runtime + Rust engine baked in); Bun ≥1.3.14 only matters for source installs.
- **Claude Code Windows** is GA native (Win10 1809+, no admin). The official
  `https://claude.ai/install.ps1` (inspected): resolves the latest version, downloads
  `claude.exe` from `downloads.claude.ai/claude-code-releases/<ver>/win32-x64/`,
  **verifies sha256 against the signed release manifest**, then runs
  `claude.exe install latest` which sets up the launcher (`%USERPROFILE%\.local\bin`),
  PATH, and shell integration itself. Native installs self-update in the background —
  the rolling model our Linux `CLAUDE_VERSION := latest` already uses.

## Design

### 1. Linux — dev-only `EGET_TOOL` entries (the herdr pattern)

`makefile/versions.mk` — new pins in the dev-only AI-agent neighborhood (next to
`HERDR_VERSION`):

```make
OPENCODE_VERSION := 1.17.18
OMP_VERSION      := 16.4.4
```

Each with a comment block carrying: dev-only rationale (AI coding agents, same as
herdr), the **AVX2/`-baseline` caveat** (OpenCode), the **fork-of-Pi note** (omp — why
Pi itself is absent), and the **Windows dual-edit** pointer (`$PortableTools` in
`bootstrap.ps1`).

`makefile/tools.mk` — MODE-gated block exactly like herdr's:

```make
ifeq ($(MODE),dev)
$(eval $(call EGET_TOOL,opencode,$(OPENCODE_VERSION),anomalyco/opencode,,--asset ^musl --asset ^baseline --asset ^desktop))
$(eval $(call EGET_TOOL,omp,$(OMP_VERSION),can1357/oh-my-pi))
else
.PHONY: opencode omp
opencode omp:
	@echo "$@ is a dev_machine tool — skipping (MODE=$(MODE))"
endif
```

- OpenCode's anti-match filters leave exactly `opencode-linux-x64.tar.gz` (glibc EL9
  hosts, modern CPUs, CLI not desktop). The global side-file filter in `lib/eget.sh`
  already excludes checksums/SBOMs.
- omp: eget must match the bare `omp-linux-x64` asset (the `x64` arch token, herdr's
  `x86_64` precedent). **Settle with a dry-run during implementation**; if eget's
  auto-detection balks, fall back to the `direct.sh` raw-binary shape (`nnd`
  precedent) — the pin/stamp model is identical either way.
- Free with the macro: install-time `verify-binary.sh` gate (glibc floor covers the
  Bun binaries; EL9's 2.34 ≥ Bun's ~2.27 floor), `DOCTOR_ROWS`/`UPDATE_SPECS`
  self-registration, weekly `version-bumps.yml` PRs, and the machine-memory `TOOLS`
  block regenerating via the `sync-tool-memory.sh` hook on the versions.mk edit.
- Claude Code Linux: **no change** — `claude-cli` already covers it.

### 2. Windows — `$PortableTools` entries + bespoke Claude Code step

Two pinned, sha256-verified `$PortableTools` entries, both → `$WsBin`:

```powershell
@{  Name = "OpenCode";  Exe = "opencode"
    Version = "1.17.18"
    Url = ".../anomalyco/opencode/releases/download/v1.17.18/opencode-windows-x64.zip"
    Sha256 = "<computed at implementation>"
    Layout = "single"          # zip contains the one opencode.exe (starship precedent)
    Repo = "anomalyco/opencode"; TagPrefix = "v"
    UpdateHint = "dual-edit: $PortableTools here AND OPENCODE_VERSION in makefile/versions.mk" }

@{  Name = "Oh My Pi";  Exe = "omp"
    Version = "16.4.4"
    Url = ".../can1357/oh-my-pi/releases/download/v16.4.4/omp-windows-x64.exe"
    Sha256 = "<computed at implementation>"
    Layout = "exe"             # bare .exe asset (jq precedent)
    Repo = "can1357/oh-my-pi"; TagPrefix = "v"
    UpdateHint = "dual-edit: $PortableTools here AND OMP_VERSION in makefile/versions.mk" }
```

(OpenCode's Windows binary also needs AVX2 — note it in the entry comment; the Windows
host is modern.)

**Bespoke `Invoke-InstallClaudeCode`** — the `Invoke-WeztermShortcut`/BurntToast tier,
NOT `$InstallerTools` (no Uninstall-registry entry to detect, not a GitHub-release
`.exe`) and NOT `$PortableTools` (rolling + self-updating — pinning would fight the
auto-updater):

- **Detect:** `claude` resolves on PATH or `%USERPROFILE%\.local\bin\claude.exe`
  exists → present → skip silently (it self-updates in the background; matching the
  Linux `CLAUDE_VERSION := latest` rolling model).
- **Install:** download the official `install.ps1` to a temp file (auditable,
  `pipe.sh` analog — never `irm | iex`), run it with the default `latest` target. The
  script does manifest-sha256 verification and `claude install` handles
  launcher/PATH/shell-integration itself.
- **Failure:** warn-and-continue (never `Write-Fail` — same soft-fail posture as
  BurntToast). Respects `-SkipToolInstall`.
- **Doctor:** row showing present/absent + `claude --version`. **CheckForUpdates:**
  one "self-updating — no pin" line (no Repo/tag comparison).

### 3. Invariants & enforcement

- **Two new dual-edit pins:** `OPENCODE_VERSION` and `OMP_VERSION`
  (`versions.mk` ↔ `$PortableTools`) — add both to `check-invariants.sh`'s dual-edit
  checks (jq/Helix precedent) and to the CLAUDE.md "Version-pin dual/triple-edits"
  list in *Files Claude should be careful with*.
- **CLAUDE.md Windows-installs invariant:** one added sentence covering the bespoke
  Claude Code step (official installer, self-updating, warn-and-continue, no pin).
- No `.chezmoiignore` changes (no new tracked dotfiles), no new chezmoi state.

### 4. Docs

- **`README.html`:** OpenCode + omp added to the tool inventory (dev-only column/badge
  as appropriate) and the Windows §setup-windows tool table; Claude Code
  native-Windows install mentioned in §setup-windows. Update
  `docs/windows/application_list.md` only if it enumerates bootstrap-installed tools
  (checked at implementation).
- **`CLAUDE_CHANGELOG.md`:** one row.

### 5. Verification (per `docs/claude/verification.md` recipes)

- Linux (this WSL host): `make -C makefile opencode omp MODE=dev` → binaries land in
  `/usr/local/bin`, `opencode --version` / `omp --version` run; `make doctor MODE=dev`
  and `make check-updates MODE=dev` show the new rows; `scripts/check-invariants.sh`
  and `make lint MODE=prod` green; prod-mode dry-run shows the skip stubs.
- Windows: `bootstrap.ps1` run installs both portable tools (sha256 verified) +
  Claude Code; `-Doctor` and `-CheckForUpdates` list all three; `claude`, `opencode`,
  `omp` resolve in a fresh Nushell.

## Non-goals

- Managing the agents' config dirs (`~/.config/opencode`, `~/.omp`, `~/.claude` on
  Windows) via chezmoi — follow-up once configs settle.
- Pi and Hermes installs (excluded above).
- prod_machine installs (AI agents are dev-only, herdr rationale).
- Replacing the `claude-cli` Linux target or its `latest` model.
