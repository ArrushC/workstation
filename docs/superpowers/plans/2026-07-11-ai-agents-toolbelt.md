# AI Coding Agents Toolbelt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenCode + Oh My Pi (`omp`) to the Linux dev-mode and Windows toolbelts, and install Claude Code natively on Windows via a bespoke `bootstrap.ps1` step.

**Architecture:** Linux gets two MODE-gated `EGET_TOOL` entries (the existing `herdr` pattern — pinned GitHub-release binaries with the verify gate, doctor/check-updates rows, and prod skip-stubs for free). Windows gets two sha256-pinned `$PortableTools` entries plus a soft-fail `Invoke-InstallClaudeCode` function that runs Anthropic's official installer (which does its own manifest-sha256 verification and self-updates thereafter). Both new version pins become dual-edits (`versions.mk` ↔ `bootstrap.ps1`) enforced by `check-invariants.sh`.

**Tech Stack:** GNU Make macros (`makefile/versions.mk`, `makefile/tools.mk`), PowerShell 5.1 (`bootstrap.ps1`, UTF-8 **with BOM**), bash (`scripts/check-invariants.sh`, LF + `shfmt -i 2`), HTML (`README.html`).

**Spec:** `docs/superpowers/specs/2026-07-11-ai-agents-toolbelt-design.md`

## Global Constraints

- Pinned versions: OpenCode **1.17.18**, Oh My Pi **16.4.4** (both tags `v`-prefixed upstream).
- Windows sha256 pins (pre-computed from the real assets on 2026-07-11):
  - `opencode-windows-x64.zip` = `7d489fd9b314e25bccf9c5dd2f17ef2774902c7b7db9aa34f46b0aab4715c70c` (zip contains exactly one file, `opencode.exe`)
  - `omp-windows-x64.exe` = `d7c07164b357d787493781a13a5370941f98b3c8df617b428ab8009d117fc83d`
- Pre-verified facts (2026-07-11, this host): eget + filters `--asset '^musl' --asset '^baseline' --asset '^desktop'` selects `opencode-linux-x64.tar.gz` and the binary runs (`1.17.18`); eget names oh-my-pi's bare binary after the *repo* (`oh-my-pi`), so the entry MUST pass a trailing `--to $(DEST)/omp` (verified: the later `--to` wins; `omp --version` → `omp/16.4.4`).
- Makefile recipe lines are TAB-indented. `bash` files: LF-only, `shfmt -i 2`-clean; `bootstrap.ps1` must keep its UTF-8 BOM (the repo's `post-edit-guard.sh` hook auto-repairs both — re-read the file if it reports a repair).
- `bootstrap.ps1` targets PowerShell **5.1** — no PS7-only syntax.
- Every commit runs the pre-commit invariant hook; a red check blocks the commit. Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a`
- Work happens on branch `feat/ai-agents-toolbelt` (already exists; spec committed as `44d9c8b`).
- Set `GITHUB_TOKEN` in the environment before sandbox installs or eget may hit the 60-req/hour unauthenticated GitHub API limit.

---

### Task 1: Linux — version pins + dev-only EGET_TOOL entries

**Files:**
- Modify: `makefile/versions.mk` (append after `HERDR_VERSION := 0.7.1`, currently line 222)
- Modify: `makefile/tools.mk:332-353` (the DEV-ONLY MODE-gated block)
- Modify (auto-regenerated): `chezmoi/private_dot_claude/CLAUDE.md` (`<!-- TOOLS:START/END -->` block)

**Interfaces:**
- Produces: make vars `OPENCODE_VERSION` / `OMP_VERSION` (Task 3's invariant checks grep these exact names from `versions.mk`); phony targets `opencode` / `omp`; binaries `$(DEST)/opencode`, `$(DEST)/omp`.

- [ ] **Step 1: Append the pins to `versions.mk`**

Insert after the `HERDR_VERSION := 0.7.1` line (end of the herdr comment block):

```make

# --- (2026-07) AI coding agents (dev_machine only) ----------------------------
# Two terminal coding agents joining claude-cli (the bespoke Makefile target) in
# the dev-only AI belt. Both are Bun-compiled single-binary GitHub releases,
# installed via MODE-gated EGET_TOOLs in tools.mk (herdr's pattern). Both pins
# DUAL-EDIT with $PortableTools in bootstrap.ps1 (the Windows halves) — enforced
# by check-invariants.sh; bump both sides together and refresh the Sha256 there.
# opencode — open-source coding agent (anomalyco/opencode; repo moved from
#   sst/opencode, old path 301s). CAVEAT: the plain linux-x64 asset REQUIRES
#   AVX2 (Intel 2013+/AMD 2015+). verify-binary.sh can't catch a SIGILL (it
#   never executes the binary) — on a pre-AVX2 host, flip the tools.mk filters
#   to select the `-baseline` asset instead.
# omp — "Oh My Pi" (can1357/oh-my-pi): the maintained, batteries-included hard
#   fork of Mario Zechner's Pi (LSP, DAP debugger, subagents, plan mode; Rust
#   core). It REPLACES Pi — upstream Pi is deliberately NOT installed. Bare
#   per-platform binary assets; eget names the download after the REPO
#   (oh-my-pi), so the tools.mk entry passes a trailing `--to $(DEST)/omp` to
#   force the command name (verified: the later --to wins).
OPENCODE_VERSION := 1.17.18
OMP_VERSION      := 16.4.4
```

- [ ] **Step 2: Extend the MODE-gated block in `tools.mk`**

Replace the current block (lines 332-353) — header comment updated from "tool"
singular to the trio, eval + stub lines added. The exact result:

```make
# =============================================================================
# DEV-ONLY scope tools (MODE-gated) — the only scope tools that aren't both-scope.
# Every EGET_TOOL/TOOL above joins $(SCOPE_TOOLS) unconditionally (dev + prod).
# These three are dev_machine-only (herdr supervises AI coding agents; opencode
# and omp ARE AI coding agents — and Claude Code itself is dev-only-deployed),
# so we wrap the PREFERRED EGET_TOOL macro in a MODE guard: on dev they join
# $(SCOPE_TOOLS) and install with `make tools`/`provision` (auto-registering
# their doctor + check-updates rows); on prod the evals are skipped and a stub
# prints the same friendly "dev_machine tool — skipping" message the bespoke
# dev-only targets (pwndbg/vcpkg) use.
# herdr: textbook single-binary release — bare per-platform assets, eget
#   auto-selects herdr-linux-x86_64 (no --asset needed), tag v$(HERDR_VERSION).
#   It does NOT replace zellij — herdr is the agent-aware addition.
# opencode: tar.gz containing the single binary. Anti-match filters drop the
#   musl/baseline CPU-and-libc variants (EL9 = glibc; fleet CPUs have AVX2 —
#   see the versions.mk caveat) and the opencode-desktop-* app assets.
# omp: bare per-platform binary like herdr, BUT eget would name it after the
#   repo (oh-my-pi) — the trailing `--to $(DEST)/omp` overrides eget.sh's
#   earlier `--to $(DEST)` (later flag wins) to force the real command name.
# (gen-tool-memory.sh greps these call lines regardless of the ifeq, so the
# dev-only machine-memory TOOLS block still lists all three.)
# =============================================================================
ifeq ($(MODE),dev)
$(eval $(call EGET_TOOL,herdr,$(HERDR_VERSION),ogulcancelik/herdr))
$(eval $(call EGET_TOOL,opencode,$(OPENCODE_VERSION),anomalyco/opencode,,--asset '^musl' --asset '^baseline' --asset '^desktop'))
$(eval $(call EGET_TOOL,omp,$(OMP_VERSION),can1357/oh-my-pi,,--to $(DEST)/omp))
else
.PHONY: herdr opencode omp
herdr opencode omp:
	@echo "$@ is a dev_machine tool — skipping (MODE=$(MODE))"
endif
```

(The recipe line under `herdr opencode omp:` is a TAB. The 4th `$(call)` arg is
empty — both repos use default `v<version>` tags. The 6th is omitted — binary
basenames equal the tool names, so `verify_cmd` checks the right files.)

- [ ] **Step 3: Regenerate the machine-memory TOOLS block**

The `sync-tool-memory.sh` PostToolUse hook fires on these edits and regenerates
`chezmoi/private_dot_claude/CLAUDE.md`. Confirm, and run manually if it didn't:

Run: `git status --short chezmoi/private_dot_claude/CLAUDE.md`
Expected: ` M chezmoi/private_dot_claude/CLAUDE.md` (if unmodified, run
`bash scripts/gen-tool-memory.sh` and re-check)

Run: `rg -n 'opencode|`omp`' chezmoi/private_dot_claude/CLAUDE.md | head -5`
Expected: both tools listed inside the TOOLS block with their versions.

- [ ] **Step 4: Dry-run + sandbox install (no sudo, scratch DEST)**

```bash
cd makefile
make -n opencode omp MODE=dev | head -20          # recipes print eget.sh lines
mkdir -p /tmp/aitools-test /tmp/aitools-stamps
make opencode omp MODE=dev DEST=/tmp/aitools-test SUDO= STAMP=/tmp/aitools-stamps
/tmp/aitools-test/opencode --version
/tmp/aitools-test/omp --version
```

Expected: eget stamp installs first if missing; both installs end with the
`verify-binary.sh` PASS line; `1.17.18` and `omp/16.4.4` print. Re-run of the
same `make` line is a no-op (stamps).

- [ ] **Step 5: Prod-mode stub check**

Run: `make -C makefile opencode omp MODE=prod`
Expected (two lines):
```
opencode is a dev_machine tool — skipping (MODE=prod)
omp is a dev_machine tool — skipping (MODE=prod)
```

- [ ] **Step 6: Doctor + check-updates rows registered**

```bash
make -C makefile doctor MODE=dev 2>/dev/null | rg 'opencode|omp'
make -C makefile check-updates MODE=dev 2>/dev/null | rg 'opencode|omp|Oh My Pi'
```
Expected: a doctor row each (missing/stale is fine — the real install to
`/usr/local/bin` happens in Task 6); check-updates compares 1.17.18 / 16.4.4
against the latest upstream tags.

- [ ] **Step 7: Commit**

```bash
git add makefile/versions.mk makefile/tools.mk chezmoi/private_dot_claude/CLAUDE.md
git commit -m "feat(tools): add opencode + omp as dev-only EGET_TOOLs

OpenCode (anomalyco/opencode) and Oh My Pi (can1357/oh-my-pi) join herdr
in the MODE-gated dev-only block. opencode filters out musl/baseline/
desktop assets (AVX2 caveat documented in versions.mk); omp forces its
command name via a trailing --to (eget would name the bare binary after
the repo). Windows halves + dual-edit enforcement follow.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 2: Windows — `$PortableTools` entries

**Files:**
- Modify: `bootstrap.ps1:246-258` (append two entries after the `jq` entry, inside the `$PortableTools` array)

**Interfaces:**
- Consumes: `OPENCODE_VERSION`/`OMP_VERSION` values from Task 1 (the URLs below embed them — Task 3's checks verify the match).
- Produces: `$PortableTools` entries with `Exe = "opencode"` / `"omp"` — the existing `Install-PortableTool`, `Invoke-Doctor`, and `Invoke-CheckForUpdates` loops pick them up with zero further wiring.

- [ ] **Step 1: Append the two entries**

The `jq` entry (ending `UpdateHint = "dual-edit: ..."` + `}` around line 257) is
currently last. Add a comma after its closing `}` and append:

```powershell
    @{
        # OpenCode + Oh My Pi — AI coding agents; the Windows halves of the
        # Linux dev-only EGET_TOOLs (see the AI-agents section in
        # makefile/versions.mk). Bun-compiled x64 binaries: both REQUIRE AVX2
        # (any CPU since ~2013).
        Name       = "OpenCode"
        Exe        = "opencode"
        Version    = "1.17.18"
        Url        = "https://github.com/anomalyco/opencode/releases/download/v1.17.18/opencode-windows-x64.zip"
        Sha256     = "7d489fd9b314e25bccf9c5dd2f17ef2774902c7b7db9aa34f46b0aab4715c70c"
        Layout     = "single"   # zip contains exactly one opencode.exe (starship precedent)
        Dest       = $WsBin
        Repo       = "anomalyco/opencode"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND OPENCODE_VERSION in makefile/versions.mk"
    },
    @{
        Name       = "Oh My Pi"
        Exe        = "omp"
        Version    = "16.4.4"
        Url        = "https://github.com/can1357/oh-my-pi/releases/download/v16.4.4/omp-windows-x64.exe"
        Sha256     = "d7c07164b357d787493781a13a5370941f98b3c8df617b428ab8009d117fc83d"
        Layout     = "exe"      # bare single-.exe release asset (jq precedent)
        Dest       = $WsBin
        Repo       = "can1357/oh-my-pi"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND OMP_VERSION in makefile/versions.mk"
    }
)
```

(Backtick before `$PortableTools` in UpdateHint strings is required — it's a
literal `$` inside a double-quoted PS string; copy the jq entry's style. Before
writing, read `Install-PortableTool`'s `"exe"` branch once to confirm it saves
the download as `"$($tool.Exe).exe"` — the jq precedent implies it, and omp
relies on the same rename.)

- [ ] **Step 2: Verify BOM survived + PS syntax parses**

```bash
head -c 3 bootstrap.ps1 | xxd | head -1        # expect: ef bb bf
```
If `pwsh` is available locally, also run the PSScriptAnalyzer lint:
`make -C makefile ps-lint MODE=prod` → expect clean. (If pwsh is absent, CI's
lint.yml `ps-lint` job covers it — note that in the commit body.)

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): add OpenCode + Oh My Pi to \$PortableTools

Pinned, sha256-verified: opencode-windows-x64.zip (Layout single) and
the bare omp-windows-x64.exe (Layout exe), both into workstation\bin.
Dual-edit pins with OPENCODE_VERSION/OMP_VERSION in versions.mk;
check-invariants enforcement lands next.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 3: Dual-edit enforcement + CLAUDE.md / invariants docs

**Files:**
- Modify: `scripts/check-invariants.sh:86` (insert after the jq check, before the shfmt comment block)
- Modify: `CLAUDE.md` ("Version-pin dual/triple-edits" bullet in *Files Claude should be careful with*; the Windows-installs invariant bullet in *Load-bearing invariants*)
- Modify: `docs/claude/invariants.md` (matching detail under its Windows-installs section, if one exists — read it first)

**Interfaces:**
- Consumes: `OPENCODE_VERSION`/`OMP_VERSION` in `versions.mk` (Task 1) and the release-URL literals in `bootstrap.ps1` (Task 2).

- [ ] **Step 1: Add the two checks to `check_version_pins()`**

Insert after the jq check's closing `fi` (line ~86), before the shfmt comment:

```bash

  v=$(mkval OPENCODE_VERSION)
  ref=$(grep -oE 'anomalyco/opencode/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "opencode @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "opencode drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval OMP_VERSION)
  ref=$(grep -oE 'can1357/oh-my-pi/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "omp @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "omp drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi
```

- [ ] **Step 2: Red test — prove the check detects drift**

```bash
sed -i 's#opencode/releases/download/v1.17.18#opencode/releases/download/v1.17.17#' bootstrap.ps1
bash scripts/check-invariants.sh 2>&1 | rg 'opencode'
```
Expected: `✗ opencode drift: versions.mk='1.17.18' bootstrap.ps1='1.17.17'` and
a non-zero exit.

- [ ] **Step 3: Revert the perturbation — green**

```bash
git checkout -- bootstrap.ps1
bash scripts/check-invariants.sh 2>&1 | rg 'opencode|omp @'
```
Expected: `✓ opencode @ 1.17.18 (versions.mk == bootstrap.ps1)` and
`✓ omp @ 16.4.4 (versions.mk == bootstrap.ps1)`.

- [ ] **Step 4: CLAUDE.md — two list edits**

(a) In *Files Claude should be careful with* → the **Version-pin
dual/triple-edits** bullet, append to the list (matching the jq entry's style):

```
`OPENCODE_VERSION` + `OMP_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PortableTools` — the Windows halves of the dev-only AI agents; verified by `check-invariants.sh`);
```

(b) In the **Windows tool installs** invariant bullet (the one describing
`$PortableTools`), after the jq sentence, add:

```
**OpenCode and Oh My Pi (`omp`) are pinned portable tools too** (zip→`Layout "single"` / bare exe→`Layout "exe"`, both AVX2-requiring Bun binaries) — each pin dual-edits its `versions.mk` var (they're the Windows halves of the dev-only Linux EGET_TOOLs). **Claude Code installs natively via a bespoke `Invoke-InstallClaudeCode` step** — runs the OFFICIAL `claude.ai/install.ps1` (manifest-sha256-verified upstream), skip-if-present, self-updates thereafter (no pin — the rolling model of Linux's `CLAUDE_VERSION := latest`), warn-and-continue on failure, skipped by `-SkipToolInstall`.
```

- [ ] **Step 5: `docs/claude/invariants.md`** — read its Windows-installs
section; add a short matching paragraph (same content as Step 4b, may carry the
AVX2 failure-mode detail: "SIGILL on pre-2013 CPUs; switch to `-baseline`
assets"). If the file has no Windows-installs entry, skip — CLAUDE.md's bullet
is then the sole home (note it in the commit body).

- [ ] **Step 6: Full invariant run + shell format**

```bash
shfmt -d -i 2 scripts/check-invariants.sh    # expect: no diff
bash scripts/check-invariants.sh             # expect: all green, exit 0
```

- [ ] **Step 7: Commit**

```bash
git add scripts/check-invariants.sh CLAUDE.md docs/claude/invariants.md
git commit -m "feat(invariants): enforce opencode/omp dual-edit pins; document Windows AI-agent installs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 4: Windows — bespoke native Claude Code install

**Files:**
- Modify: `bootstrap.ps1` — new function after `Invoke-InstallBurntToast` (ends line ~1196); main-flow call after the `Invoke-InstallBurntToast` line (~1664); Doctor rows in "Installer apps + extras" (after the VSCode lines, ~1489); CheckForUpdates line in "Other components" (~1638); header flag-doc line for `-SkipToolInstall` (~81)
- Modify: `docs/windows/application_list.md` (remove the now-auto-installed `Claude Code` row)

**Interfaces:**
- Consumes: existing helpers `Write-Log`/`Write-Ok`/`Write-Warn`, `$SkipToolInstall` switch.
- Produces: `Invoke-InstallClaudeCode` (no params), called once from MAIN.

- [ ] **Step 1: Add the function** (after `Invoke-InstallBurntToast`'s closing brace):

```powershell

# =============================================================================
# 6b. CLAUDE CODE — native Windows install via the OFFICIAL installer script.
#     The script verifies claude.exe's sha256 against Anthropic's signed
#     release manifest, then `claude.exe install latest` sets up the launcher
#     (%USERPROFILE%\.local\bin), PATH, and shell integration itself.
#     NOT $PortableTools: native installs SELF-UPDATE in the background, so a
#     pin would fight the auto-updater (mirrors CLAUDE_VERSION := latest on
#     the Linux side — the claude-cli target in makefile/). NOT
#     $InstallerTools: no Uninstall-registry entry, not a GitHub release.
#     Detect-by-command, skip when present; soft-fails (warn-and-continue).
#     Runs in a CHILD powershell.exe — the installer script calls `exit` on
#     its error paths, which would kill this bootstrap if dot-run in-process.
# =============================================================================
function Invoke-InstallClaudeCode {
    if ($SkipToolInstall) {
        Write-Log "Claude Code install skipped (-SkipToolInstall)"
        return
    }
    $claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path $claudeExe)) {
        Write-Ok "Claude Code already installed (self-updates in the background)"
        return
    }
    Write-Log "Installing Claude Code (official installer, manifest-verified)..."
    $tmp = Join-Path $env:TEMP "claude-install-$PID.ps1"
    try {
        # Download-then-run (never `irm | iex`) — auditable, same posture as
        # the Linux side's pipe.sh.
        Invoke-WebRequest -Uri "https://claude.ai/install.ps1" -OutFile $tmp -ErrorAction Stop
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) { throw "installer exited with code $LASTEXITCODE" }
        Write-Ok "Claude Code installed (launcher in ~\.local\bin; self-updates)"
    } catch {
        Write-Warn "Claude Code install failed: $_"
        Write-Warn "  Retry manually:  irm https://claude.ai/install.ps1 | iex"
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Wire into MAIN** — after the `Invoke-InstallBurntToast` line:

```powershell
Invoke-InstallClaudeCode  # native Claude Code via the official installer (manifest-verified; self-updates)
```

- [ ] **Step 3: Doctor row** — in `Invoke-Doctor`'s "Installer apps + extras"
section, directly after the VSCode if/else pair:

```powershell
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    $claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if ($claudeCmd) {
        Write-Ok "Claude Code installed ($($claudeCmd.Source); self-updates in the background)"
    } elseif (Test-Path $claudeExe) {
        Write-Warn "Claude Code installed at $claudeExe but not on PATH — open a NEW shell"
    } else {
        Write-Bad "Claude Code not installed — re-run .\bootstrap.ps1"
    }
```

- [ ] **Step 4: CheckForUpdates line** — in `Invoke-CheckForUpdates`'s
"Other components" section, after the BurntToast if/else:

```powershell
    if ((Get-Command claude -ErrorAction SilentlyContinue) -or
        (Test-Path (Join-Path $env:USERPROFILE ".local\bin\claude.exe"))) {
        Write-Ok "Claude Code installed — self-updates in the background (no pin; rolling, like Linux CLAUDE_VERSION := latest)"
    } else {
        Write-Warn "Claude Code not installed — re-run .\bootstrap.ps1"
    }
```

- [ ] **Step 5: Header flag doc** — extend the `-SkipToolInstall` line (~81):

```
#   -SkipToolInstall    skip the chezmoi/WezTerm/Starship/Helix/Nushell/jq/
#                       OpenCode/omp auto-installs AND the Claude Code step
```
(Also update `Invoke-ToolInstall`'s skip-log string at ~868 to mention the new
tools if it enumerates: read it and keep the enumeration truthful.)

- [ ] **Step 6: `docs/windows/application_list.md`** — delete the
`- Claude Code` line and add `Claude Code` to the header's parenthetical list
of apps auto-installed by bootstrap.ps1.

- [ ] **Step 7: Verify BOM + lint + invariants**

```bash
head -c 3 bootstrap.ps1 | xxd | head -1        # expect: ef bb bf
bash scripts/check-invariants.sh               # all green
```
Run `make -C makefile ps-lint MODE=prod` if pwsh is available (else CI covers).

- [ ] **Step 8: Commit**

```bash
git add bootstrap.ps1 docs/windows/application_list.md
git commit -m "feat(windows): install Claude Code natively via the official installer

Bespoke Invoke-InstallClaudeCode: skip-if-present (self-updating),
download-then-run the official install.ps1 in a child process
(manifest-sha256-verified upstream), warn-and-continue on failure,
-SkipToolInstall aware; Doctor + CheckForUpdates rows added. Removed
Claude Code from the hand-install shopping list.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 5: README.html + CLAUDE_CHANGELOG.md

**Files:**
- Modify: `README.html:1878` (AI tool-card — two chips after `herdr`), `README.html:~2795` (Windows "What the script installs" list), `README.html:~3000` (`-SkipToolInstall` prose if it enumerates tools)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: AI tool-card chips** — inside the `cat-ai` article's
`<div class="chips">`, after the closing `</span>` of the `herdr` chip:

```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="OpenCode — open-source terminal coding agent (anomalyco/opencode, Bun-compiled single binary); also in the Windows portable belt"
                                    >opencode<span class="sr-only">
                                        — OpenCode: open-source terminal coding
                                        agent (Bun-compiled single binary,
                                        dev_machine only; Windows gets the
                                        pinned portable .zip via
                                        bootstrap.ps1)</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="omp — Oh My Pi, the batteries-included fork of the Pi coding agent (LSP, DAP debugger, subagents, plan mode); also in the Windows portable belt"
                                    >omp<span class="sr-only">
                                        — Oh My Pi: maintained hard fork of the
                                        Pi coding agent adding LSP, a DAP
                                        debugger, subagents and plan mode
                                        (dev_machine only; Windows gets the
                                        pinned portable .exe via
                                        bootstrap.ps1)</span
                                    ></span
                                >
```

- [ ] **Step 2: Windows install list** — in §setup-windows "What the script
installs", add three `<li>` entries: OpenCode + Oh My Pi right after the last
pinned-portable entry (read the list to find it — Nushell or jq, after the
Helix entry shown at ~2791), and Claude Code after the SSHFS-Win entry:

```html
                        <li>
                            <strong>OpenCode</strong> and <strong>Oh My Pi</strong>
                            (<code>omp</code>) &mdash; AI coding agents; pinned,
                            sha256-verified portable binaries into
                            <code>%LOCALAPPDATA%\workstation\bin</code>. The
                            Windows halves of the Linux dev-only installs
                            (versions dual-edit with
                            <code>makefile/versions.mk</code>).
                        </li>
```

```html
                        <li>
                            <strong>Claude Code</strong> &mdash; native install
                            via the <strong>official</strong> installer script,
                            which verifies the binary against Anthropic&rsquo;s
                            signed release manifest and then self-updates in
                            the background (nothing to pin). Skipped when
                            <code>claude</code> already resolves; soft-fails
                            with a manual-retry hint. The WSL2 copy (installed
                            by <code>make dev</code> inside the distro) is
                            independent and unaffected.
                        </li>
```

- [ ] **Step 3: `-SkipToolInstall` prose** (~line 3000) — if it enumerates the
skipped tools, extend the enumeration with OpenCode/omp/Claude Code to stay
truthful.

- [ ] **Step 4: Append the CLAUDE_CHANGELOG.md row**

```markdown
| Added AI coding agents: OpenCode + Oh My Pi (`omp`) as dev-only `EGET_TOOL`s (Linux) + pinned `$PortableTools` (Windows), and a bespoke native Claude Code install in `bootstrap.ps1` (official installer, self-updates, no pin). Two new dual-edit pins enforced by `check-invariants.sh`. Pi and Hermes deliberately excluded (omp replaces Pi). | **Yes** | Stack §AI card gains `opencode` + `omp` chips; Setup → On Windows "What the script installs" gains the OpenCode/omp portable entry + a Claude Code entry; `-SkipToolInstall` doc line extended. |
```

- [ ] **Step 5: Sanity-check the HTML + commit**

```bash
python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('README.html',encoding='utf-8').read()); print('parsed ok')"
git add README.html CLAUDE_CHANGELOG.md
git commit -m "docs(readme): OpenCode + omp chips and Windows install entries; changelog row

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 6: Real-host verification sweep (Linux side)

**Files:** none (verification only; commit only if something needed fixing)

- [ ] **Step 1: Real install on this dev host** (WSL AlmaLinux, MODE=dev —
installs to `/usr/local/bin` via sudo):

```bash
make -C makefile opencode omp MODE=dev
opencode --version     # expect: 1.17.18
omp --version          # expect: omp/16.4.4
```

- [ ] **Step 2: Doctor + check-updates on the real host**

```bash
make -C makefile doctor MODE=dev | rg 'opencode|omp'          # both: installed @ pin
make -C makefile check-updates MODE=dev | rg 'opencode|omp'   # pin vs upstream tag
```

- [ ] **Step 3: Full lint + invariants + template render**

```bash
make -C makefile lint MODE=prod
```
Expected: check-invariants (incl. the two new pin rows) + shellcheck + shfmt +
gitleaks + check-templates all green.

- [ ] **Step 4: Hook regression** (only if any `.claude/hooks/*.sh` changed —
none are planned; skip otherwise): `bash .claude/hooks/test-hooks.sh`

- [ ] **Step 5: Windows-side deferred checklist** — cannot run from WSL; print
it for the user (goes in the PR body):

```
On the Windows host, after pulling this branch:
  .\bootstrap.ps1                      # installs OpenCode + omp (sha256-verified) + Claude Code
  .\bootstrap.ps1 -Doctor              # three new rows green
  .\bootstrap.ps1 -CheckForUpdates     # opencode/omp pins compared; Claude Code "self-updates" line
  (new shell)  opencode --version ; omp --version ; claude --version
```

- [ ] **Step 6: Finish** — invoke `superpowers:finishing-a-development-branch`
(PR to `main` per repo habit; PR body carries the Windows checklist above).
