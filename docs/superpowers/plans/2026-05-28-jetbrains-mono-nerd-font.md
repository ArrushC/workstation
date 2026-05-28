# JetBrains Mono Nerd Font Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install JetBrainsMono Nerd Font Mono v3.4.0 on every interactive host the workstation manages and switch WezTerm + Zed + VS Code + starship to use it, so Nerd Font glyphs already present in chezmoi-tracked configs (starship icons, eza `--icons=auto`, lazygit, k9s, yazi, broot, helix file-tree icons, chezit, ccstatusline widgets, Claude Code TUI) finally render correctly.

**Architecture:** Linux install via a new bespoke `nerd-fonts` make target (mirrors `node-runtime`) that downloads `JetBrainsMono.tar.xz` from `ryanoasis/nerd-fonts` releases and deposits the six Mono variants under `~/.local/share/fonts/JetBrainsMonoNerdFontMono/` then runs `fc-cache`. Windows install via a new `scripts/install-nerd-fonts.ps1` invoked from `bootstrap.ps1` that downloads the `JetBrainsMono.zip` variant and registers the six TTFs per-user (HKCU). WSL hosts skip the Linux side — WezTerm rasterises on the Windows host. Config edits in WezTerm, Zed, VS Code, and starship switch the rendering target.

**Tech Stack:** Make (GNU Make), bash + curl + tar (Linux installer), PowerShell 5.1+ + Invoke-WebRequest + Expand-Archive (Windows installer), chezmoi (config delivery), fontconfig (Linux font discovery), Windows GDI + HKCU registry (Windows font discovery), WezTerm Lua config, Zed/VS Code JSON, starship TOML.

**Pinned values (used throughout):**
- `JETBRAINSMONO_NERD_VERSION = 3.4.0` (latest stable, published 2025-04-24)
- SHA256 of `JetBrainsMono.tar.xz`: `ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582`
- SHA256 of `JetBrainsMono.zip`: `76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c`
- Six Mono variants installed: `JetBrainsMonoNerdFontMono-{Regular,Italic,Bold,BoldItalic,Medium,MediumItalic}.ttf`

These values come from `https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/SHA-256.txt` (already fetched and recorded during writing-plans).

---

### Task 1: Add `JETBRAINSMONO_NERD_VERSION` to `makefile/versions.mk`

**Files:**
- Modify: `makefile/versions.mk` (append at end of file)

- [ ] **Step 1: Add the variable**

Use the Edit tool to append a new section at the end of `makefile/versions.mk`. The file currently ends with the `DOZZLE_VERSION := 10.6.1` line and trailing comment block; append below it:

```make

# --- Fonts (dev_machine only, makefile target deposits to ~/.local/share/fonts) -
# JetBrainsMono Nerd Font Mono — the six Mono-variant TTFs from the
# ryanoasis/nerd-fonts release archive. Pinned alongside its SHA256 in
# makefile/lib/font.sh (per-version case branch) and mirrored in the Windows
# installer script (scripts/install-nerd-fonts.ps1) — bumping the pin requires
# editing all three. See the dual-edit invariant in CLAUDE.md.
JETBRAINSMONO_NERD_VERSION := 3.4.0
```

- [ ] **Step 2: Verify the variable is exposed**

Run: `cd makefile && make help MODE=dev 2>&1 | head -3`

Expected: no `JETBRAINSMONO_NERD_VERSION undefined` errors. `make help` should display normally.

- [ ] **Step 3: Sanity-check the value is wired in**

Run: `cd makefile && make -p MODE=dev 2>/dev/null | grep '^JETBRAINSMONO_NERD_VERSION'`

Expected: `JETBRAINSMONO_NERD_VERSION := 3.4.0`

- [ ] **Step 4: Commit**

```bash
git add makefile/versions.mk
git commit -m "$(cat <<'EOF'
feat(versions): pin JETBRAINSMONO_NERD_VERSION for new nerd-fonts target

3.4.0 is the latest stable Nerd Fonts release (published 2025-04-24).
Used by the upcoming makefile/lib/font.sh + nerd-fonts make target and
mirrored in scripts/install-nerd-fonts.ps1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `IS_WSL` export to `makefile/scope.mk`

**Files:**
- Modify: `makefile/scope.mk` (append after the final `endif` at line 47)

The `nerd-fonts` target needs to skip on WSL hosts (font rasterisation happens on the Windows host running WezTerm). Centralising the WSL probe in `scope.mk` keeps detection logic in one place, parallel to `bootstrap.sh`'s `is_wsl()` helper.

- [ ] **Step 1: Append the IS_WSL block**

Use the Edit tool to append to `makefile/scope.mk`:

```make

# WSL detection — true if running inside a WSL distro (any version). Centralised
# here so targets that should no-op on WSL (e.g. nerd-fonts, where the Windows
# host already supplies the font to WezTerm) share one probe instead of
# duplicating the detection. Mirrors bootstrap.sh's is_wsl() helper.
IS_WSL := $(shell { [ -n "$$WSL_DISTRO_NAME" ] || grep -qi microsoft /proc/version 2>/dev/null; } && echo true || echo false)
export IS_WSL
```

- [ ] **Step 2: Verify the probe resolves**

Run: `cd makefile && make -p MODE=dev 2>/dev/null | grep '^IS_WSL'`

Expected (on a WSL host like the dev machine): `IS_WSL := true`. On bare-metal Linux: `IS_WSL := false`. Either is correct — the value reflects the local environment.

- [ ] **Step 3: Verify no impact on existing targets**

Run: `cd makefile && make -n MODE=dev provision 2>&1 | head -20`

Expected: same output as before this task (no errors, no new commands).

- [ ] **Step 4: Commit**

```bash
git add makefile/scope.mk
git commit -m "$(cat <<'EOF'
feat(scope): centralise IS_WSL detection for targets that skip on WSL

Mirrors bootstrap.sh's is_wsl() helper. Consumed by the upcoming
nerd-fonts target, which skips on WSL hosts because WezTerm runs on the
Windows host and uses Windows-registered fonts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Create `makefile/lib/font.sh`

**Files:**
- Create: `makefile/lib/font.sh` (mode 0755, LF-only)

This is the Linux-side installer helper. Invoked by the new `nerd-fonts` make target (Task 4). Mirrors `makefile/lib/node.sh` structurally — args + download + SHA verify + extract + cache refresh.

- [ ] **Step 1: Write the file**

Use the Write tool to create `makefile/lib/font.sh` with the content below. The shebang on line 1 is `#!/usr/bin/env bash`.

```bash
#!/usr/bin/env bash
# font.sh — install JetBrainsMono Nerd Font Mono variants for user-scope use.
#
# Invoked by makefile/Makefile's nerd-fonts target (NOT directly). Downloads
# the JetBrainsMono.tar.xz release archive from ryanoasis/nerd-fonts, verifies
# its SHA256 against a per-version pin, extracts the six Mono variants into
# $PARENT/JetBrainsMonoNerdFontMono/, refreshes fontconfig, writes a stamp.
#
# Args: $1 = parent dir under which JetBrainsMonoNerdFontMono/ is created
#               (passed as the value of ~/.local/share/fonts at call time)
#       $2 = upstream Nerd Fonts release version (e.g. 3.4.0)
#       $3 = stamp file path to touch on success
#
# Honours $GITHUB_TOKEN (Authorization: Bearer header) to avoid the
# 60-req/hour unauthenticated GitHub rate limit. Soft-fails with a stderr
# warning and exit 0 if fc-cache is absent (font deposit still succeeds);
# hard-fails on download or SHA256 issues.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'usage: font.sh <parent-dir> <version> <stamp-file>\n' >&2
  exit 2
fi

PARENT="$1"
VERSION="$2"
STAMP="$3"

# Per-version SHA256 of JetBrainsMono.tar.xz. Bump by adding a new branch
# and verifying against the upstream SHA-256.txt:
#   curl -sL https://github.com/ryanoasis/nerd-fonts/releases/download/v<VER>/SHA-256.txt | grep JetBrainsMono.tar.xz
case "$VERSION" in
  3.4.0) EXPECT_SHA='ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582' ;;
  *)
    printf 'font.sh: no SHA256 pinned for v%s — add a case branch and verify against upstream\n' "$VERSION" >&2
    exit 1
    ;;
esac

DEST_DIR="$PARENT/JetBrainsMonoNerdFontMono"
TARBALL_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${VERSION}/JetBrainsMono.tar.xz"

printf '==> JetBrainsMono Nerd Font Mono v%s\n' "$VERSION"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TARBALL="$TMPDIR/JetBrainsMono.tar.xz"
CURL_AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURL_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
curl -fsSL "${CURL_AUTH[@]}" -o "$TARBALL" "$TARBALL_URL"

ACTUAL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
  printf 'font.sh: SHA256 mismatch for v%s\n  expected: %s\n  actual:   %s\n' \
    "$VERSION" "$EXPECT_SHA" "$ACTUAL_SHA" >&2
  exit 1
fi

# Sweep stale install (in case upstream renames TTF files between releases),
# then recreate empty.
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# Extract only the six Mono variants. Top-level archive layout has all
# TTFs at the root of the tarball, so --strip-components is not needed.
tar -C "$DEST_DIR" -xJf "$TARBALL" \
  'JetBrainsMonoNerdFontMono-Regular.ttf' \
  'JetBrainsMonoNerdFontMono-Italic.ttf' \
  'JetBrainsMonoNerdFontMono-Bold.ttf' \
  'JetBrainsMonoNerdFontMono-BoldItalic.ttf' \
  'JetBrainsMonoNerdFontMono-Medium.ttf' \
  'JetBrainsMonoNerdFontMono-MediumItalic.ttf'

INSTALLED=$(find "$DEST_DIR" -maxdepth 1 -name 'JetBrainsMonoNerdFontMono-*.ttf' | wc -l)
if [ "$INSTALLED" -ne 6 ]; then
  printf 'font.sh: extracted %d of 6 expected TTF files\n' "$INSTALLED" >&2
  exit 1
fi

# Refresh fontconfig cache. Scope to the new dir so it's fast (<100ms). Soft-fail
# with a warning if fc-cache is missing — the deposit itself succeeded.
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f "$DEST_DIR" >/dev/null
else
  printf '  warning: fc-cache not on PATH — install `fontconfig` for font discovery\n' >&2
fi

mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
printf '  installed 6 Mono variants to %s\n' "$DEST_DIR"
```

- [ ] **Step 2: Make executable + verify LF endings**

```bash
chmod +x makefile/lib/font.sh
git update-index --add --chmod=+x makefile/lib/font.sh
file makefile/lib/font.sh
```

Expected: `file` output must say something like `Bourne-Again shell script, ASCII text executable` — must NOT contain "CRLF line terminators". If it does, run `sed -i 's/\r$//' makefile/lib/font.sh` and re-verify.

- [ ] **Step 3: Verify the staged file mode is 100755**

```bash
git ls-files --stage makefile/lib/font.sh
```

Expected output: `100755 <sha> 0	makefile/lib/font.sh` (note: 100755, not 100644).

- [ ] **Step 4: Syntax check**

```bash
bash -n makefile/lib/font.sh
```

Expected: no output (syntax OK).

- [ ] **Step 5: Smoke-test against a sandbox dir** (does not touch `~/.local/share/fonts/`)

```bash
SANDBOX=$(mktemp -d)
makefile/lib/font.sh "$SANDBOX" 3.4.0 "$SANDBOX/.stamp"
ls "$SANDBOX/JetBrainsMonoNerdFontMono/" | wc -l
ls "$SANDBOX/.stamp" && echo "stamp present"
rm -rf "$SANDBOX"
```

Expected: prints `==> JetBrainsMono Nerd Font Mono v3.4.0` and `installed 6 Mono variants to <sandbox>/JetBrainsMonoNerdFontMono`. The count prints `6`. Stamp file exists.

If the run hits a GitHub rate limit (403), set `GITHUB_TOKEN` and retry: `GITHUB_TOKEN=<token> makefile/lib/font.sh "$SANDBOX" 3.4.0 "$SANDBOX/.stamp"`.

- [ ] **Step 6: Commit**

```bash
git add makefile/lib/font.sh
git commit -m "$(cat <<'EOF'
feat(font): add lib/font.sh — JetBrainsMono Nerd Font Mono installer

Mirrors lib/node.sh structurally: takes parent-dir + version + stamp,
downloads JetBrainsMono.tar.xz from the ryanoasis/nerd-fonts release,
verifies SHA256 against a per-version pin, extracts the six Mono
variants under <parent>/JetBrainsMonoNerdFontMono/, refreshes
fontconfig, touches the stamp. Honours GITHUB_TOKEN for the
download. Soft-fails on missing fc-cache (warning + exit 0);
hard-fails on download or SHA issues.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add `nerd-fonts` target to `makefile/Makefile` and wire into `provision`

**Files:**
- Modify: `makefile/Makefile` (insert new target block after the `node-runtime` block ending at line 143; extend the dev-only `provision:` line at line 279)

- [ ] **Step 1: Insert the `nerd-fonts` target block**

Use the Edit tool. The `node-runtime` block ends at line 143 with `@$(SUDO) rm -rf $(DEST)/_node-*`. Insert the new target immediately after that block, before the `claude-statusline` block at line 145.

Find this string (after `node-runtime` and before `# claude-statusline`):

```make
clean-node-runtime:
	@rm -f $(STAMP)/node-*.done
	@$(SUDO) rm -f $(DEST)/node $(DEST)/npm $(DEST)/npx $(DEST)/corepack
	@$(SUDO) rm -rf $(DEST)/_node-*

# -----------------------------------------------------------------------------
# claude-statusline — interactive ccstatusline setup prompt.
```

Replace it with:

```make
clean-node-runtime:
	@rm -f $(STAMP)/node-*.done
	@$(SUDO) rm -f $(DEST)/node $(DEST)/npm $(DEST)/npx $(DEST)/corepack
	@$(SUDO) rm -rf $(DEST)/_node-*

# -----------------------------------------------------------------------------
# nerd-fonts — JetBrainsMono Nerd Font Mono variants from ryanoasis/nerd-fonts.
#   - dev_machine only (added to provision's deps only on MODE=dev, below).
#   - Skips on WSL hosts (IS_WSL=true) because WezTerm runs on the Windows
#     host where the Windows-side installer (scripts/install-nerd-fonts.ps1,
#     invoked from bootstrap.ps1) handles registration. Stamp still written
#     so `make nerd-fonts` returns fast on subsequent WSL runs.
#   - NO $(SUDO) — deposits to $HOME/.local/share/fonts/JetBrainsMonoNerdFontMono/
#     which is user-owned; fc-cache also runs against a user-scope dir. Other
#     bespoke targets (node-runtime, claude-cli) use $(SUDO) because they
#     deposit to $(DEST) (/usr/local/bin on dev) which is system-owned.
#   - Stamp encodes $(JETBRAINSMONO_NERD_VERSION); bumping the pin in
#     versions.mk invalidates the stamp on the next run.
# -----------------------------------------------------------------------------
.PHONY: nerd-fonts clean-nerd-fonts
nerd-fonts: $(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done
$(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done:
	@if [ "$(IS_WSL)" = "true" ]; then \
	  printf '  skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm\n'; \
	  mkdir -p $(@D) && touch $@; \
	else \
	  $(LIB)/font.sh "$$HOME/.local/share/fonts" $(JETBRAINSMONO_NERD_VERSION) $@; \
	fi
clean-nerd-fonts:
	@rm -rf "$$HOME/.local/share/fonts/JetBrainsMonoNerdFontMono"
	@rm -f $(STAMP)/nerd-fonts-*.done

# -----------------------------------------------------------------------------
# claude-statusline — interactive ccstatusline setup prompt.
```

- [ ] **Step 2: Wire `nerd-fonts` into the MODE=dev provision deps**

Find this string in `makefile/Makefile`:

```make
provision: packages tools user-tools shell dotfiles
ifeq ($(MODE),dev)
provision: claude-cli node-runtime dozzle-service cockpit-service
endif
```

Replace it with:

```make
provision: packages tools user-tools shell dotfiles
ifeq ($(MODE),dev)
provision: claude-cli node-runtime nerd-fonts dozzle-service cockpit-service
endif
```

- [ ] **Step 3: Add `nerd-fonts` to the `make list` output**

The `make list` target groups managed tools by category. Find the existing list-target body in `makefile/Makefile` (search for `make list` documentation around line 301 onward — look for the existing line that prints `claude-cli (provisioned on MODE=dev only)`).

Run to find the exact line:

```bash
grep -n "claude-cli (provisioned" makefile/Makefile
```

Expected output: one line, around line 301-302, like:

```
301:	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
```

Use the Edit tool to insert a parallel printf for nerd-fonts immediately after the line just found. If the existing pattern is:

```make
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
```

Replace it with:

```make
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
	@printf '\nnerd-fonts (provisioned on MODE=dev only; no-op on WSL)\n'
```

- [ ] **Step 4: Verify the target appears in `make help` / `make list`**

```bash
cd makefile && make list MODE=dev 2>&1 | grep -i nerd-fonts
```

Expected: a line containing `nerd-fonts (provisioned on MODE=dev only; no-op on WSL)`.

- [ ] **Step 5: Verify the dev provision wires it in**

```bash
cd makefile && make -n MODE=dev provision 2>&1 | grep -E 'nerd-fonts|font\.sh' | head -5
```

Expected: at least one line mentions either the `nerd-fonts` stamp file or the `font.sh` invocation (e.g. `lib/font.sh "$HOME/.local/share/fonts" 3.4.0 ...`).

- [ ] **Step 6: Verify prod provision does NOT include it**

```bash
cd makefile && make -n MODE=prod provision 2>&1 | grep -E 'nerd-fonts|font\.sh' | head -5
```

Expected: no matches.

- [ ] **Step 7: Verify WSL-skip path fires** (on the current host, which is WSL)

```bash
cd makefile && rm -f $STAMP/nerd-fonts-*.done 2>/dev/null
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps
```

Expected: prints `skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm` and exits 0. Stamp file at `/tmp/nerd-fonts-test-stamps/nerd-fonts-3.4.0.done` exists.

Cleanup: `rm -rf /tmp/nerd-fonts-test-stamps`.

- [ ] **Step 8: Verify the no-op re-run**

```bash
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps
```

(Re-run after step 7's stamp was deleted — actually the stamp dir was removed, so first run again, then re-run.)

Re-run from a fresh state:

```bash
rm -rf /tmp/nerd-fonts-test-stamps
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps   # first run: WSL-skip
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps   # second run: no-op via stamp
```

Expected on second run: no output (stamp hit, make sees target up-to-date).

Cleanup: `rm -rf /tmp/nerd-fonts-test-stamps`.

- [ ] **Step 9: Commit**

```bash
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(make): add nerd-fonts target (MODE=dev, skip on WSL)

Bespoke target mirroring node-runtime: stamp-based, scoped to
~/.local/share/fonts/JetBrainsMonoNerdFontMono/, no $(SUDO).
Joins provision's dev-only deps. WSL hosts get a no-op skip
because WezTerm runs on the Windows side and resolves fonts there.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Create `scripts/install-nerd-fonts.ps1`

**Files:**
- Create: `scripts/install-nerd-fonts.ps1` (UTF-8 with BOM)

Per-user Windows font installer. Mirrors the Linux helper conceptually. Invoked from `bootstrap.ps1` (Task 6).

- [ ] **Step 1: Write the file**

Use the Write tool to create `scripts/install-nerd-fonts.ps1` with the content below. After writing, Task 5's Step 3 re-encodes the file to UTF-8 with BOM (PowerShell 5.1 requirement, same pattern as the existing PS scripts).

```powershell
#Requires -Version 5.1
# =============================================================================
# install-nerd-fonts.ps1 — install JetBrainsMono Nerd Font Mono per-user.
#
# Invoked by bootstrap.ps1 (NOT directly). Downloads JetBrainsMono.zip from
# ryanoasis/nerd-fonts, verifies its SHA256 against the hard-coded pin below,
# extracts the six Mono variants, copies them to %LOCALAPPDATA%\Microsoft\Windows\Fonts\,
# and registers them in HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts
# (per-user — no admin needed for the registration even though bootstrap.ps1
# runs elevated). Honours $env:GITHUB_TOKEN (Authorization: Bearer header) to
# avoid the 60-req/hour unauthenticated GitHub rate limit.
#
# Idempotency: a no-op fast path returns early if a stamp file exists at
#   %LOCALAPPDATA%\workstation\nerd-fonts.<VERSION>.stamp
# AND all six TTFs are present AND all six HKCU registrations exist. Otherwise
# stale installs are swept (file + registry) before depositing the new set.
#
# Hard-fails on download or SHA256 issues (bootstrap.ps1 aborts). Soft-fails
# on registry-write failure (WezTerm still works via config.font_dirs;
# Zed/VS Code may not see the font until manual registration via Settings →
# Personalization → Fonts).
#
# Version + SHA256 are pinned in the script body — must mirror
# JETBRAINSMONO_NERD_VERSION in makefile/versions.mk + the per-version SHA in
# makefile/lib/font.sh (zip vs tar.xz hashes differ — see CLAUDE.md dual-edit
# invariant).
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Version = '3.4.0'
$Sha256  = '76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c'

$FontFamily = 'JetBrainsMonoNerdFontMono'
$FontDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$StampDir   = Join-Path $env:LOCALAPPDATA 'workstation'
$StampFile  = Join-Path $StampDir "nerd-fonts.$Version.stamp"
$RegPath    = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

$Variants  = @('Regular', 'Italic', 'Bold', 'BoldItalic', 'Medium', 'MediumItalic')
$FontFiles = $Variants | ForEach-Object { "$FontFamily-$_.ttf" }

function Test-Installed {
    if (-not (Test-Path $StampFile)) { return $false }
    foreach ($f in $FontFiles) {
        if (-not (Test-Path (Join-Path $FontDir $f))) { return $false }
    }
    $reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($f in $FontFiles) {
        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"
        if (-not $reg.PSObject.Properties[$regName]) { return $false }
    }
    return $true
}

if (Test-Installed) {
    Write-Host "  nerd-fonts already installed (v$Version)"
    return
}

Write-Host "==> Installing JetBrainsMono Nerd Font Mono v$Version"

# Sweep stale install (files + HKCU entries) before depositing the new set.
# Guards against upstream renaming TTF files between releases.
if (Test-Path $FontDir) {
    Get-ChildItem -Path $FontDir -Filter "$FontFamily-*.ttf" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue }
}
$reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if ($reg) {
    $reg.PSObject.Properties |
        Where-Object { $_.Name -like "$FontFamily-*" } |
        ForEach-Object {
            Remove-ItemProperty -Path $RegPath -Name $_.Name -ErrorAction SilentlyContinue
        }
}

# Download with optional GitHub auth.
$Url     = "https://github.com/ryanoasis/nerd-fonts/releases/download/v$Version/JetBrainsMono.zip"
$Headers = @{}
if ($env:GITHUB_TOKEN) {
    $Headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

$TmpDir = Join-Path $env:TEMP "nerd-fonts-$Version"
if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir }
New-Item -ItemType Directory -Path $TmpDir | Out-Null

$Archive = Join-Path $TmpDir 'JetBrainsMono.zip'
Write-Host "  downloading $Url"
Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive -Headers $Headers

# Verify SHA256.
$Actual = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLower()
if ($Actual -ne $Sha256.ToLower()) {
    throw "SHA256 mismatch for v${Version}: expected $Sha256, got $Actual"
}

# Extract.
$Extract = Join-Path $TmpDir 'extract'
Expand-Archive -Path $Archive -DestinationPath $Extract -Force

# Ensure font + stamp dirs exist.
New-Item -ItemType Directory -Path $FontDir  -Force | Out-Null
New-Item -ItemType Directory -Path $StampDir -Force | Out-Null

# Copy the six Mono variants.
$Copied = 0
foreach ($f in $FontFiles) {
    $src = Get-ChildItem -Path $Extract -Filter $f -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $src) { throw "Expected $f not found in extracted archive" }
    Copy-Item -Path $src.FullName -Destination (Join-Path $FontDir $f) -Force
    $Copied++
}
if ($Copied -ne 6) { throw "Copied $Copied of 6 expected TTF files" }

# Register in HKCU (per-user). Soft-fail per-file: if any one registration is
# blocked, continue with the rest and flag at the end.
$RegistrationFailed = $false
foreach ($f in $FontFiles) {
    $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"
    try {
        New-ItemProperty -Path $RegPath -Name $regName -Value $f `
            -PropertyType String -Force | Out-Null
    } catch {
        Write-Warning "Failed to register $regName in HKCU: $_"
        $RegistrationFailed = $true
    }
}

# Cleanup temp.
Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue

# Stamp.
Set-Content -Path $StampFile -Value $Version -Encoding ASCII

if ($RegistrationFailed) {
    Write-Warning ("Some HKCU registrations failed — WezTerm will work via " +
        "config.font_dirs, but Zed/VS Code may not see the font until manual " +
        "registration (Settings → Personalization → Fonts).")
} else {
    Write-Host "  installed 6 Mono variants to $FontDir + HKCU registrations"
}
```

- [ ] **Step 2: Re-encode as UTF-8 with BOM**

PowerShell 5.1 mis-decodes UTF-8 glyphs in script bodies without a BOM. Re-encode via Python so the file is exactly UTF-8-BOM (same approach as the existing `scripts/manage-hosts.ps1` and `bootstrap.ps1`).

```bash
python3 -c "
import pathlib
p = pathlib.Path('scripts/install-nerd-fonts.ps1')
content = p.read_text(encoding='utf-8')
p.write_bytes(b'\xef\xbb\xbf' + content.encode('utf-8'))
"
```

- [ ] **Step 3: Verify BOM and encoding**

```bash
head -c 3 scripts/install-nerd-fonts.ps1 | xxd
```

Expected: `00000000: efbb bf                                  ...` (UTF-8 BOM is the three bytes `EF BB BF`).

```bash
file scripts/install-nerd-fonts.ps1
```

Expected: output should contain `with BOM` and `UTF-8 Unicode` — must NOT contain "CRLF line terminators". If it does, run `sed -i 's/\r$//' scripts/install-nerd-fonts.ps1` (this preserves the BOM since `sed` doesn't touch the first three bytes for an `s/\r$//` substitution).

- [ ] **Step 4: PowerShell syntax check (best-effort from WSL)**

If `powershell.exe` is reachable from WSL (it usually is on WSL2):

```bash
powershell.exe -NoLogo -Command "& { try { [scriptblock]::Create((Get-Content -Raw -Path 'scripts/install-nerd-fonts.ps1')) | Out-Null; 'SYNTAX OK' } catch { Write-Host \"SYNTAX ERROR: \$_\" } }"
```

Expected: `SYNTAX OK`.

If `powershell.exe` is not reachable, skip this step and rely on the Windows-side test in Task 6 to surface syntax errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-nerd-fonts.ps1
git commit -m "$(cat <<'EOF'
feat(scripts): add install-nerd-fonts.ps1 — Windows-side font installer

Per-user font install: deposits the six JetBrainsMono Nerd Font Mono
variants into %LOCALAPPDATA%\Microsoft\Windows\Fonts\ and registers them
in HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts. Honours
GITHUB_TOKEN, verifies SHA256, soft-fails on per-file registry blocks.
Version + SHA256 are pinned in the script and must mirror versions.mk —
see the new CLAUDE.md dual-edit invariant (added in a later task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Wire `install-nerd-fonts.ps1` into `bootstrap.ps1`

**Files:**
- Modify: `bootstrap.ps1` (param block, header flow comment, new `Invoke-InstallNerdFonts` function, dispatch order at the bottom)

The new step inserts between step 7 (BurntToast) and step 8 (SSH key). bootstrap.ps1's existing comment-numbering shifts accordingly.

- [ ] **Step 1: Add `-SkipNerdFonts` to the param block**

Find this string in `bootstrap.ps1` (around line 97):

```powershell
    [switch]$SkipBurntToast,
    [switch]$Reinstall,
    [switch]$Yes
```

Replace it with:

```powershell
    [switch]$SkipBurntToast,
    [switch]$SkipNerdFonts,
    [switch]$Reinstall,
    [switch]$Yes
```

- [ ] **Step 2: Update the header flow comment**

Find this string in `bootstrap.ps1` (around line 37–45):

```
#   7. burnt toast     — install the BurntToast PowerShell module from
#                         PSGallery (CurrentUser scope) so Claude Code's
#                         WSL2 Notification hook (chezmoi/private_dot_claude/
#                         executable_notify.sh) can emit native Windows
#                         toasts instead of falling back to a MessageBox.
#                         Idempotent; soft-fails to a warning if PSGallery
#                         is offline or the module is unavailable.
#   8. ssh key          — generate %USERPROFILE%\.ssh\id_ed25519 if missing
```

Replace it with:

```
#   7. burnt toast     — install the BurntToast PowerShell module from
#                         PSGallery (CurrentUser scope) so Claude Code's
#                         WSL2 Notification hook (chezmoi/private_dot_claude/
#                         executable_notify.sh) can emit native Windows
#                         toasts instead of falling back to a MessageBox.
#                         Idempotent; soft-fails to a warning if PSGallery
#                         is offline or the module is unavailable.
#   8. nerd fonts       — install JetBrainsMono Nerd Font Mono per-user via
#                         scripts/install-nerd-fonts.ps1 (file + HKCU
#                         registration). Required for the Nerd Font glyphs
#                         in WezTerm + Zed + VS Code + starship.
#                         Idempotent; soft-fails registry blocks.
#   9. ssh key          — generate %USERPROFILE%\.ssh\id_ed25519 if missing
```

- [ ] **Step 3: Add the `Invoke-InstallNerdFonts` function**

Find this string in `bootstrap.ps1` (around line 665–671):

```powershell
        Write-Warn "  Claude Code WSL2 notifications will fall back to a MessageBox dialog."
        Write-Warn "  Retry manually:  Install-Module BurntToast -Scope CurrentUser"
    }
}

# =============================================================================
# 8. SSH KEY (optional, prompt-driven)
```

Replace it with:

```powershell
        Write-Warn "  Claude Code WSL2 notifications will fall back to a MessageBox dialog."
        Write-Warn "  Retry manually:  Install-Module BurntToast -Scope CurrentUser"
    }
}

# =============================================================================
# 8. NERD FONTS — JetBrainsMono Nerd Font Mono installed per-user.
#    Required by chezmoi-tracked configs that already assume Nerd Font glyphs
#    (starship prompt, eza --icons=auto, lazygit, k9s, yazi, broot, helix
#    file-tree, chezit, ccstatusline, Claude Code TUI). Invokes the standalone
#    scripts/install-nerd-fonts.ps1 helper. Soft-fails if -SkipNerdFonts is
#    passed or the helper script is missing (warning + continue).
# =============================================================================
function Invoke-InstallNerdFonts {
    if ($SkipNerdFonts) {
        Write-Log "Nerd Fonts install skipped (-SkipNerdFonts)"
        return
    }

    $InstallScript = Join-Path $RepoPath 'scripts\install-nerd-fonts.ps1'
    if (-not (Test-Path $InstallScript)) {
        Write-Warn "Nerd Fonts installer not found at $InstallScript — skipping"
        return
    }

    try {
        & $InstallScript
    } catch {
        Write-Warn "Nerd Fonts install failed: $_"
        Write-Warn "  Glyphs in starship / eza / lazygit / etc. will render as tofu."
        Write-Warn "  Retry manually:  & '$InstallScript'"
    }
}

# =============================================================================
# 9. SSH KEY (optional, prompt-driven)
```

- [ ] **Step 4: Insert the dispatch call**

Find this string in `bootstrap.ps1` (near the bottom, around line 717–719):

```powershell
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-EnsureSshKey
```

Replace it with:

```powershell
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey
```

- [ ] **Step 5: Re-encode bootstrap.ps1 as UTF-8 with BOM**

Editing bootstrap.ps1 via the Edit tool may strip the BOM. Re-encode to be safe:

```bash
python3 -c "
import pathlib
p = pathlib.Path('bootstrap.ps1')
data = p.read_bytes()
if data.startswith(b'\xef\xbb\xbf'):
    print('BOM already present, no-op')
else:
    p.write_bytes(b'\xef\xbb\xbf' + data)
    print('BOM restored')
"
```

- [ ] **Step 6: Verify BOM and LF endings**

```bash
head -c 3 bootstrap.ps1 | xxd
file bootstrap.ps1
```

Expected: BOM `efbbbf` at the start; `file` output does NOT contain "CRLF line terminators". If CRLF, `sed -i 's/\r$//' bootstrap.ps1`.

- [ ] **Step 7: PowerShell syntax check (best-effort from WSL)**

```bash
powershell.exe -NoLogo -Command "& { try { [scriptblock]::Create((Get-Content -Raw -Path 'bootstrap.ps1')) | Out-Null; 'SYNTAX OK' } catch { Write-Host \"SYNTAX ERROR: \$_\" } }"
```

Expected: `SYNTAX OK`.

- [ ] **Step 8: Commit**

```bash
git add bootstrap.ps1
git commit -m "$(cat <<'EOF'
feat(bootstrap): invoke install-nerd-fonts.ps1 between BurntToast and ssh-key

New step 8: Invoke-InstallNerdFonts dispatches the standalone
scripts/install-nerd-fonts.ps1 helper. SSH-key step renumbered 8 → 9.
Adds -SkipNerdFonts switch mirroring -SkipBurntToast. Wraps the
helper invocation in try/catch with a manual-retry message; the
helper's own internal soft-fails on per-file registry blocks bubble
up here as a non-blocking warning.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Update `wezterm.lua` to use the Nerd Font + add `font_dirs`

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (lines 140, 171–176, 173, 809; insert new font_dirs block)

- [ ] **Step 1: Swap the body font (`config.font`)**

Find this string (the only `config.font` assignment near line 140):

```lua
config.font         = wezterm.font('JetBrains Mono', { weight = 'Regular' })
```

Replace it with:

```lua
config.font         = wezterm.font('JetBrainsMono Nerd Font Mono', { weight = 'Regular' })

-- Belt-and-suspenders on Windows: also point at %LOCALAPPDATA%\Microsoft\Windows\Fonts\
-- directly. install-nerd-fonts.ps1 (invoked from bootstrap.ps1) deposits the
-- six Mono variants there + HKCU-registers them, but config.font_dirs guards
-- against bootstrap ordering races where wezterm reads its config before the
-- HKCU registration completes — the .ttf files are still accessible from the
-- font_dirs path. No-op on Linux (Linux WezTerm uses fontconfig instead).
if wezterm.target_triple:find('windows') then
  local localappdata = os.getenv('LOCALAPPDATA')
  if localappdata then
    config.font_dirs = { localappdata .. '\\Microsoft\\Windows\\Fonts' }
  end
end
```

- [ ] **Step 2: Swap the tab-bar font (`window_frame.font`)**

Find this string (the `window_frame.font` line around 176, including the surrounding context for uniqueness):

```lua
config.window_frame = {
  font                            = wezterm.font { family = 'JetBrains Mono', weight = 'Medium' },
```

Replace it with:

```lua
config.window_frame = {
  font                            = wezterm.font { family = 'JetBrainsMono Nerd Font Mono', weight = 'Medium' },
```

The `weight = 'Medium'` is preserved — load-bearing per the surrounding comments (Regular body / Medium tabs differentiation).

- [ ] **Step 3: Update the doc comments mentioning the font by name**

Find this comment block around line 170–174:

```lua
-- Fancy-mode chrome (Tokyo Night-matched). Ignored when use_fancy_tab_bar = false.
-- Font is JetBrains Mono Medium so the tab bar carries the terminal's identity
-- but stays distinct from body text (which uses Regular). The retro tab bar
-- inherits the main terminal font automatically, so JetBrains Mono is applied
-- in both modes without needing a separate retro override.
```

Replace it with:

```lua
-- Fancy-mode chrome (Tokyo Night-matched). Ignored when use_fancy_tab_bar = false.
-- Font is JetBrainsMono Nerd Font Mono (Medium weight) so the tab bar carries
-- the terminal's identity but stays distinct from body text (which uses
-- Regular weight of the same family). The retro tab bar inherits the main
-- terminal font automatically, so JetBrainsMono Nerd Font Mono is applied in
-- both modes without needing a separate retro override.
```

- [ ] **Step 4: Update the comment around line 809 (font-name mention)**

Run:

```bash
grep -n "JetBrains Mono" chezmoi/dot_config/wezterm/wezterm.lua
```

Expected: at this point in the task, all remaining occurrences should be in comments only (no more `wezterm.font('JetBrains Mono')` calls). Confirm and update each remaining hit. For the line ~809:

```lua
  -- doesn't dominate visually. The fancy tab bar font (JetBrains Mono Medium)
```

Replace with:

```lua
  -- doesn't dominate visually. The fancy tab bar font (JetBrainsMono Nerd Font Mono Medium)
```

- [ ] **Step 5: Final verification — no `'JetBrains Mono'` (base font name) remains**

```bash
grep -n "'JetBrains Mono'" chezmoi/dot_config/wezterm/wezterm.lua
grep -n 'family = .JetBrains Mono.,' chezmoi/dot_config/wezterm/wezterm.lua
```

Expected: both return no matches (the only occurrences should be inside string literals like the new `'JetBrainsMono Nerd Font Mono'`).

Run a positive check:

```bash
grep -n "JetBrainsMono Nerd Font Mono" chezmoi/dot_config/wezterm/wezterm.lua | wc -l
```

Expected: at least 4 (font line, window_frame line, two comment mentions).

- [ ] **Step 6: Lua syntax check**

```bash
luac -p chezmoi/dot_config/wezterm/wezterm.lua 2>&1 || echo "luac not available — skipping"
```

If `luac` is installed, expected: no output (syntax OK). If not installed, skip; the next chezmoi apply will surface any error.

- [ ] **Step 7: Commit**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "$(cat <<'EOF'
feat(wezterm): switch body + tab-bar font to JetBrainsMono Nerd Font Mono

Body uses Regular weight; tab bar keeps Medium weight (Regular/Medium
differentiation is load-bearing per the surrounding comments). On Windows,
adds config.font_dirs = { %LOCALAPPDATA%\Microsoft\Windows\Fonts } as a
belt-and-suspenders fallback for bootstrap ordering races where wezterm
reads its config before HKCU registration completes. Comments updated to
reflect the new font name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Update Zed settings to use the Nerd Font

**Files:**
- Modify: `chezmoi/AppData/Roaming/Zed/settings.json` (lines 16 and 76)

- [ ] **Step 1: Swap `buffer_font_family`**

Find this string:

```json
  "buffer_font_family": "JetBrains Mono",
```

Replace it with:

```json
  "buffer_font_family": "JetBrainsMono Nerd Font Mono",
```

- [ ] **Step 2: Swap the terminal `font_family`**

Find this string:

```json
    "font_family": "JetBrains Mono",
```

Replace it with:

```json
    "font_family": "JetBrainsMono Nerd Font Mono",
```

(Should be a single match — only one place inside `terminal` block carries `font_family: "JetBrains Mono"`. If there are more matches, use context lines to disambiguate.)

- [ ] **Step 3: Verify `ui_font_family` is untouched**

```bash
grep '"ui_font_family"' chezmoi/AppData/Roaming/Zed/settings.json
```

Expected: `"ui_font_family": ".ZedSans",` — proportional UI font, intentionally not changed.

- [ ] **Step 4: Verify both `JetBrains Mono` references are gone**

```bash
grep '"JetBrains Mono"' chezmoi/AppData/Roaming/Zed/settings.json
```

Expected: no matches.

```bash
grep '"JetBrainsMono Nerd Font Mono"' chezmoi/AppData/Roaming/Zed/settings.json | wc -l
```

Expected: 2.

- [ ] **Step 5: JSON syntax check**

```bash
python3 -c "import json; json.load(open('chezmoi/AppData/Roaming/Zed/settings.json'))" && echo "JSON OK"
```

Expected: `JSON OK`.

- [ ] **Step 6: Commit**

```bash
git add chezmoi/AppData/Roaming/Zed/settings.json
git commit -m "$(cat <<'EOF'
feat(zed): switch buffer + terminal font to JetBrainsMono Nerd Font Mono

ui_font_family stays at .ZedSans (proportional UI font, intentionally
not a monospace).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Update VS Code settings to use the Nerd Font

**Files:**
- Modify: `chezmoi/AppData/Roaming/Code/User/settings.json` (lines 5 and 24)

- [ ] **Step 1: Prepend Nerd Font to `editor.fontFamily`** (keep Monaspace Neon as fallback)

Find this string:

```json
  "editor.fontFamily": "Monaspace Neon, Consolas, 'Courier New', monospace",
```

Replace it with:

```json
  "editor.fontFamily": "JetBrainsMono Nerd Font Mono, Monaspace Neon, Consolas, 'Courier New', monospace",
```

- [ ] **Step 2: Swap `terminal.integrated.fontFamily`** (no fallback — VS Code resolves missing fonts gracefully)

Find this string:

```json
  "terminal.integrated.fontFamily": "Monaspace Neon",
```

Replace it with:

```json
  "terminal.integrated.fontFamily": "JetBrainsMono Nerd Font Mono",
```

- [ ] **Step 3: Verify both edits landed**

```bash
grep 'JetBrainsMono Nerd Font Mono' chezmoi/AppData/Roaming/Code/User/settings.json
```

Expected: two lines — one inside `editor.fontFamily`, one inside `terminal.integrated.fontFamily`.

```bash
grep '"terminal.integrated.fontFamily"' chezmoi/AppData/Roaming/Code/User/settings.json
```

Expected: `"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font Mono",`

- [ ] **Step 4: JSON syntax check**

```bash
python3 -c "import json; json.load(open('chezmoi/AppData/Roaming/Code/User/settings.json'))" && echo "JSON OK"
```

Expected: `JSON OK`.

- [ ] **Step 5: Commit**

```bash
git add chezmoi/AppData/Roaming/Code/User/settings.json
git commit -m "$(cat <<'EOF'
feat(vscode): switch editor + terminal font to JetBrainsMono Nerd Font Mono

editor.fontFamily prepends the Nerd Font and keeps Monaspace Neon as the
next fallback (graceful degradation if the font install fails on a host).
terminal.integrated.fontFamily swaps outright — VS Code resolves missing
fonts to a default monospace gracefully, no explicit fallback needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Polish three starship symbols to Nerd Font glyphs

**Files:**
- Modify: `chezmoi/dot_config/starship.toml` (`[shlvl]`, `[jobs]`, `[status]` blocks)

- [ ] **Step 1: Swap the `[shlvl]` symbol**

Find this string:

```toml
[shlvl]
# Surfaces shell-nesting depth past the outermost layer. Useful for
# chains like `WezTerm → zellij → ssh → zsh` where it's easy to lose
# track of which shell a command will run in. Default threshold is 2
# (renders when SHLVL >= 2 — i.e. you've sub-shelled at least once).
disabled  = false
threshold = 2
symbol    = "↕"
format    = "[$symbol$shlvl]($style) "
style     = "dimmed white"
```

Replace it with:

```toml
[shlvl]
# Surfaces shell-nesting depth past the outermost layer. Useful for
# chains like `WezTerm → zellij → ssh → zsh` where it's easy to lose
# track of which shell a command will run in. Default threshold is 2
# (renders when SHLVL >= 2 — i.e. you've sub-shelled at least once).
# Symbol is nf-md-layers-triple (U+F0F39) — visualises nested shell
# layers more directly than the previous ↕ up-down arrow.
disabled  = false
threshold = 2
symbol    = "󰼹"
format    = "[$symbol $shlvl]($style) "
style     = "dimmed white"
```

(Note: the new symbol is a single Nerd Font codepoint `󰼹` = U+F0F39. Added a space in the format string between `$symbol` and `$shlvl` since Nerd Font glyphs render at full cell width.)

- [ ] **Step 2: Swap the `[jobs]` symbol**

Find this string:

```toml
[jobs]
format    = "[$symbol$number]($style) "
symbol    = "✦"
style     = "bold cyan"
threshold = 1
```

Replace it with:

```toml
[jobs]
# Symbol is nf-fa-gear ( ) — visualises background work more clearly
# than the previous ✦ sparkle.
format    = "[$symbol $number]($style) "
symbol    = ""
style     = "bold cyan"
threshold = 1
```

(Single Nerd Font codepoint `` = U+F013, fa-gear. Added a space between `$symbol` and `$number`.)

- [ ] **Step 3: Swap the `[status]` symbol**

Find this string:

```toml
[status]
# `common_meaning` maps known codes to labels (1 → ERROR, 126 → NOPERM,
# 127 → NOTFOUND, 2 → USAGE); `$maybe_int` falls back to the raw number
# for everything else. `recognize_signal_code = false` is deliberate —
# tools like ssh use exit codes >=128 for non-signal reasons (ssh: 255),
# and enabling it would silently subtract 128 and mislabel them.
disabled              = false
recognize_signal_code = false
symbol                = "✘"
format                = '[$symbol $common_meaning$maybe_int]($style) '
style                 = "bold red"
```

Replace it with:

```toml
[status]
# `common_meaning` maps known codes to labels (1 → ERROR, 126 → NOPERM,
# 127 → NOTFOUND, 2 → USAGE); `$maybe_int` falls back to the raw number
# for everything else. `recognize_signal_code = false` is deliberate —
# tools like ssh use exit codes >=128 for non-signal reasons (ssh: 255),
# and enabling it would silently subtract 128 and mislabel them.
# Symbol is nf-fa-times-circle ( ) — matches the visual weight of the
# rest of the Nerd Font prompt; replaces the previous ✘ heavy ballot X.
disabled              = false
recognize_signal_code = false
symbol                = ""
format                = '[$symbol $common_meaning$maybe_int]($style) '
style                 = "bold red"
```

(Single Nerd Font codepoint `` = U+F057, fa-times-circle.)

- [ ] **Step 4: Verify the three swaps**

```bash
grep -A1 '^\[shlvl\]' chezmoi/dot_config/starship.toml | head -8
grep -A1 '^\[jobs\]' chezmoi/dot_config/starship.toml | head -8
grep -A1 '^\[status\]' chezmoi/dot_config/starship.toml | head -10
```

Expected: each block now references the new Nerd Font codepoint (the literal character) in the `symbol = ...` line; the previous `↕`, `✦`, `✘` are gone.

```bash
grep -E 'symbol\s*=\s*"(↕|✦|✘)"' chezmoi/dot_config/starship.toml
```

Expected: no matches.

- [ ] **Step 5: TOML syntax check**

```bash
python3 -c "
import sys
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib
import pathlib
tomllib.loads(pathlib.Path('chezmoi/dot_config/starship.toml').read_text())
print('TOML OK')
" 2>&1 || echo "tomllib unavailable — falling back to starship's own validator"
```

Expected: `TOML OK`. If neither tomllib nor tomli is available, skip — starship will surface a parse error on next prompt render.

- [ ] **Step 6: Commit**

```bash
git add chezmoi/dot_config/starship.toml
git commit -m "$(cat <<'EOF'
feat(starship): swap shlvl / jobs / status symbols to Nerd Font glyphs

- shlvl ↕ → nf-md-layers-triple (visualises nested shells directly)
- jobs ✦ → nf-fa-gear           (visualises background work)
- status ✘ → nf-fa-times-circle (matches rest of prompt's visual weight)

Existing Nerd Font glyphs in hostname.ssh_symbol, directory.read_only,
os.symbols.Linux, and git_branch.symbol are unchanged — they were
already correct, just not rendering until the font install lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Update `CLAUDE.md` — new invariant + file-care entries

**Files:**
- Modify: `CLAUDE.md` (add to "Load-bearing invariants" section + "Files Claude should be careful with" section + "Quick verification" section)

- [ ] **Step 1: Add the new dual-edit invariant**

Open `CLAUDE.md` and locate the existing invariant about `versions.mk` ↔ `private_settings.json.tmpl` dual-edit for `CCSTATUSLINE_VERSION` (search: `dual-edit for \`CCSTATUSLINE_VERSION\``). The new invariant goes immediately below it.

Find this string (in CLAUDE.md, the CCSTATUSLINE invariant):

```
- **`versions.mk` ↔ `private_settings.json.tmpl` dual-edit for `CCSTATUSLINE_VERSION`.** The version literal in `chezmoi/private_dot_claude/private_settings.json.tmpl` (the `npx -y ccstatusline@<pin>` command) MUST match `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Bumping the pin requires editing both — no chezmoi-template variable currently bridges them. Drift means Claude Code's `statusLine` command pins a different version than `setup-ccstatusline.sh` invokes interactively, with confusing UX (the interactive TUI uses one version, the live status line another).
```

Replace it with (appends a new bullet immediately after):

```
- **`versions.mk` ↔ `private_settings.json.tmpl` dual-edit for `CCSTATUSLINE_VERSION`.** The version literal in `chezmoi/private_dot_claude/private_settings.json.tmpl` (the `npx -y ccstatusline@<pin>` command) MUST match `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Bumping the pin requires editing both — no chezmoi-template variable currently bridges them. Drift means Claude Code's `statusLine` command pins a different version than `setup-ccstatusline.sh` invokes interactively, with confusing UX (the interactive TUI uses one version, the live status line another).
- **`versions.mk` ↔ `lib/font.sh` ↔ `install-nerd-fonts.ps1` triple-edit for `JETBRAINSMONO_NERD_VERSION`.** Three places must move together when bumping the Nerd Font pin: (1) `JETBRAINSMONO_NERD_VERSION` in `makefile/versions.mk`; (2) the `case "$VERSION" in 3.4.0) EXPECT_SHA='...' ;;` branch in `makefile/lib/font.sh` (SHA256 of `JetBrainsMono.tar.xz` from the matching `SHA-256.txt` upstream); (3) the `$Version` + `$Sha256` literals in `scripts/install-nerd-fonts.ps1` (SHA256 of `JetBrainsMono.zip` — different artifact, different hash). Procedure: bump the version variable; `curl -sL https://github.com/ryanoasis/nerd-fonts/releases/download/v<VER>/SHA-256.txt | grep -E 'JetBrainsMono\.(tar\.xz|zip)$'` for the two new SHAs; substitute both. Drift means Linux and Windows hosts can end up on different font versions across a mid-bump fleet, with subtle icon-rendering differences across host kinds. No chezmoi-template variable currently bridges them.
```

- [ ] **Step 2: Add `makefile/lib/font.sh` to the "Files Claude should be careful with" section**

Find the existing `makefile/lib/node.sh` care entry in CLAUDE.md (search: `**`makefile/lib/node.sh`**`). Insert the new entry immediately after it.

Find this string:

```
- **`makefile/lib/node.sh`** — LF-only, mode 100755. Downloads + extracts the official Node.js tarball + symlinks four bin entries (`node`, `npm`, `npx`, `corepack`) into `$(DEST)/`. The full lib tree must be preserved at `$(DEST)/_node-vX.Y.Z/` because npm/npx/corepack are JS scripts with relative symlinks into `../lib/node_modules/`. Re-installs sweep all older `_node-*` trees to avoid orphan version directories.
```

Replace it with:

```
- **`makefile/lib/node.sh`** — LF-only, mode 100755. Downloads + extracts the official Node.js tarball + symlinks four bin entries (`node`, `npm`, `npx`, `corepack`) into `$(DEST)/`. The full lib tree must be preserved at `$(DEST)/_node-vX.Y.Z/` because npm/npx/corepack are JS scripts with relative symlinks into `../lib/node_modules/`. Re-installs sweep all older `_node-*` trees to avoid orphan version directories.
- **`makefile/lib/font.sh`** — LF-only, mode 100755. Downloads `JetBrainsMono.tar.xz` from `ryanoasis/nerd-fonts` releases, verifies SHA256 via a per-version `case` branch (NOT a `versions.mk` variable — the SHA lives next to the version it pins), extracts six Mono variants to `$1/JetBrainsMonoNerdFontMono/`, runs `fc-cache` against that subdir. `$1` is `$HOME/.local/share/fonts` at call time. No `$(SUDO)` — the deposit target is user-owned (the Makefile recipe never wraps the call in `$(SUDO)`). Honours `$GITHUB_TOKEN` for the download. Soft-fails on missing `fc-cache` (stderr warning + `exit 0` so a daily `make dev` doesn't gain a phantom failure on hypothetical fontconfig-less hosts). Triple-edit with `versions.mk` + `scripts/install-nerd-fonts.ps1` per the invariant above.
- **`scripts/install-nerd-fonts.ps1`** — UTF-8 with BOM (PS 5.1 dependency). Per-user font install: copies six TTFs into `%LOCALAPPDATA%\Microsoft\Windows\Fonts\` + registers each in `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` with the `(TrueType)` name suffix. Pinned `$Version` + `$Sha256` in the script body — the SHA256 is for `JetBrainsMono.zip` (not `.tar.xz` — Windows uses zip via `Expand-Archive`). Stamp at `%LOCALAPPDATA%\workstation\nerd-fonts.<VERSION>.stamp` gates the fast-path no-op. Soft-fails per-file on HKCU write blocks (continues + emits a warning). Hard-fails on download / SHA256 errors (`bootstrap.ps1` aborts).
```

- [ ] **Step 3: Add two new lines to the "Quick verification" section**

Find the existing line in the Quick verification section that references `infocmp wezterm`:

```
- `infocmp wezterm | head -1` on every chezmoi-managed host after `cza` — confirms the terminfo entry was tic'd by `run_onchange_install-wezterm-terminfo.sh`. Should print `wezterm|Wez's terminal emulator,`.
```

Replace it with:

```
- `infocmp wezterm | head -1` on every chezmoi-managed host after `cza` — confirms the terminfo entry was tic'd by `run_onchange_install-wezterm-terminfo.sh`. Should print `wezterm|Wez's terminal emulator,`.
- `fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l` on every Linux **dev_machine** after `make dev` — should return `6`. WSL hosts deliberately return `0` (font is on the Windows side; the make target no-ops). prod_machine hosts return `0` (font is dev-only).
- After `bootstrap.ps1` on Windows: `(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf").Count` — should return `6`. `(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties.Name -like 'JetBrainsMonoNerdFontMono-*' | Measure-Object` should also show `Count: 6`.
- Visual smoke test in any post-install WezTerm pane (post `Ctrl+Shift+R` reload): `printf '     \n'` renders folder / home / megaphone / powerline arrow / calendar / github icons crisply — no tofu boxes.
```

- [ ] **Step 4: Verify the three edits landed**

```bash
grep -c 'JETBRAINSMONO_NERD_VERSION' CLAUDE.md
```

Expected: at least 2 (the invariant line + likely a mention in the file-care entry).

```bash
grep -c 'install-nerd-fonts.ps1' CLAUDE.md
```

Expected: at least 3 (invariant line + file-care entry + Quick verification).

```bash
grep -c 'jetbrainsmono nerd font mono' CLAUDE.md
```

Expected: at least 1 (the new Quick verification line).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): document JETBRAINSMONO_NERD_VERSION triple-edit invariant

New load-bearing invariant: versions.mk ↔ lib/font.sh ↔
install-nerd-fonts.ps1 all encode the Nerd Fonts version pin (plus a
SHA256, different artifact per OS — .tar.xz on Linux, .zip on Windows).
Adds file-care entries for both new files. Three new lines added to
Quick verification covering fc-list (Linux), HKCU registrations
(Windows), and a visual smoke test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Update `README.html` — setup bullets + troubleshooting entry

**Files:**
- Modify: `README.html` (insert bullets under §setup-linux and §setup-windows; add a new troubleshooting accordion entry)

- [ ] **Step 1: Find the §setup-linux bullet list**

Run:

```bash
grep -n 'setup-linux\|JetBrains\|JetBrainsMono' README.html | head -20
```

Expected: locates the `<section id="setup-linux">` (or similar anchor) and any existing font mentions.

- [ ] **Step 2: Add a setup-linux bullet for the font install**

Open the `<section id="setup-linux">` block. Locate the "What this installs" or similar bullet list — typically a `<ul>` near the section header that enumerates tools installed by `bootstrap.sh --dev`.

Add a new `<li>` (or matching list item structure) reading:

```html
<li><strong>JetBrainsMono Nerd Font Mono</strong> — installed to <code>~/.local/share/fonts/JetBrainsMonoNerdFontMono/</code> by the new <code>nerd-fonts</code> make target (dev_machine only; no-op on WSL since the Windows host supplies the font to WezTerm). Required for the Nerd Font glyphs in starship, eza <code>--icons=auto</code>, lazygit, k9s, yazi, broot, helix file-tree, chezit, ccstatusline, and the Claude Code TUI.</li>
```

If the surrounding markup uses a different idiom (e.g. cards or definition lists), adapt to match the existing style — the *content* matters more than the wrapping tag.

- [ ] **Step 3: Find the §setup-windows section**

```bash
grep -n 'setup-windows' README.html | head -5
```

- [ ] **Step 4: Add a setup-windows bullet for the font install**

Inside `<section id="setup-windows">` (or analogous), find the bullet list describing what `bootstrap.ps1` does. Insert a new bullet describing the Windows side. Existing list likely already mentions chezmoi, BurntToast, WezTerm env var, etc.

Add an `<li>` reading (adapted to match the existing markup):

```html
<li><strong>JetBrainsMono Nerd Font Mono</strong> (per-user) — installed to <code>%LOCALAPPDATA%\Microsoft\Windows\Fonts\</code> and registered under <code>HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts</code> by <code>scripts/install-nerd-fonts.ps1</code> (invoked from <code>bootstrap.ps1</code> step 8). Per-user install — no admin needed for the registration even though <code>bootstrap.ps1</code> itself runs elevated. Visible to WezTerm, Zed, VS Code, and any other Windows app.</li>
```

- [ ] **Step 5: Find the §troubleshooting accordion block**

```bash
grep -n 'troubleshooting\|details.*summary' README.html | head -20
```

Expected: locates the troubleshooting section and the `<details><summary>` pattern used for each entry.

- [ ] **Step 6: Add a new troubleshooting entry**

Insert a new `<details>` block in the troubleshooting section, immediately after one of the existing entries (e.g. after the "Colors look banded / 8-bit on host X" entry from the WezTerm truecolor work). Adapt the markup to match the surrounding style.

Suggested content:

```html
<details>
  <summary>Tofu boxes / missing icons after install</summary>
  <p>Symptom: starship prompt shows boxes instead of icons; <code>eza</code> rows show empty cells where icons should appear; lazygit / k9s / yazi look broken. JetBrainsMono Nerd Font Mono isn't loaded.</p>
  <p>Triage:</p>
  <ul>
    <li><strong>Linux:</strong> <code>fc-list | grep -i 'jetbrainsmono nerd font mono'</code> — expect 6 entries. Empty? Run <code>cd makefile &amp;&amp; make nerd-fonts MODE=dev</code>. Re-run starting shells to refresh.</li>
    <li><strong>Windows:</strong> <code>Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-Regular.ttf"</code> — expect <code>True</code>. False? Re-run <code>bootstrap.ps1</code> (the <code>Invoke-InstallNerdFonts</code> step is idempotent; passes a stamp-based fast path on a second run).</li>
    <li><strong>VS Code / Zed still showing tofu:</strong> apps cache font lists at launch. Quit and relaunch.</li>
    <li><strong>WezTerm still showing tofu:</strong> <code>Ctrl+Shift+R</code> in WezTerm reloads the config; if that doesn't help, restart WezTerm. Confirm <code>JETBRAINSMONO_NERD_VERSION</code> in <code>makefile/versions.mk</code> is the same as the <code>$Version</code> literal in <code>scripts/install-nerd-fonts.ps1</code> — drift between the two means Linux and Windows hosts can end up on different font versions.</li>
    <li><strong>WSL host running <code>make nerd-fonts</code> says "skipping on WSL":</strong> intentional. WSL apps render via the Windows host's WezTerm, which uses Windows-registered fonts. Run <code>bootstrap.ps1</code> on the Windows side instead.</li>
  </ul>
</details>
```

- [ ] **Step 7: Verify the edits**

```bash
grep -c 'JetBrainsMono Nerd Font Mono' README.html
```

Expected: at least 3 (one bullet per setup section + the troubleshooting entry).

```bash
grep -c 'nerd-fonts\|install-nerd-fonts' README.html
```

Expected: at least 2.

- [ ] **Step 8: Render the page in a browser to confirm formatting**

If the dev environment can launch a browser:

```bash
xdg-open README.html 2>/dev/null || powershell.exe -Command "Start-Process 'README.html'" 2>/dev/null || echo "open README.html manually in a browser"
```

Visual check: the new bullets render inside their lists, the troubleshooting accordion expands/collapses, no broken markup.

- [ ] **Step 9: Commit**

```bash
git add README.html
git commit -m "$(cat <<'EOF'
docs(readme): document JetBrainsMono Nerd Font Mono install + troubleshooting

setup-linux and setup-windows sections each get a bullet pointing at the
new install path. New troubleshooting accordion entry walks tofu-box
recovery for Linux, Windows, VS Code / Zed cache, WezTerm reload, and
the WSL no-op-is-intentional case.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Append a row to `CLAUDE_CHANGELOG.md`

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append at the end of the table)

- [ ] **Step 1: Append the row**

Use the Edit tool. Find the last row in the existing table (the row about "Added Claude Code `Notification` hooks for desk-side alerts") and append a new row beneath it.

The existing last row ends with a `|` and a newline. Append directly under it:

```
| Added JetBrainsMono Nerd Font Mono as a dev_machine-only managed asset (Linux: new `JETBRAINSMONO_NERD_VERSION` pin in `versions.mk`, new `makefile/lib/font.sh` downloader, new `nerd-fonts` bespoke target in `makefile/Makefile` joining `provision`'s dev-only deps; deposits six Mono variants to `~/.local/share/fonts/JetBrainsMonoNerdFontMono/` + runs `fc-cache`; SHA256-pinned, GITHUB_TOKEN-aware; soft-fails missing `fc-cache`; no `$(SUDO)` because the install target is user-owned; WSL hosts get a no-op-skip via a new `IS_WSL` export in `scope.mk` mirroring `bootstrap.sh`'s `is_wsl()` helper. Windows: new `scripts/install-nerd-fonts.ps1` per-user installer — copies TTFs to `%LOCALAPPDATA%\Microsoft\Windows\Fonts\` + HKCU registry registration; invoked from a new step 8 in `bootstrap.ps1` (between BurntToast and ssh-key, renumbers ssh-key 8 → 9); SHA256-pinned against `JetBrainsMono.zip` (different artifact than Linux's `.tar.xz`, different hash); soft-fails per-file on HKCU write blocks. Config-side activation: `chezmoi/dot_config/wezterm/wezterm.lua` swaps body + tab-bar font to `JetBrainsMono Nerd Font Mono` (keeps Regular/Medium weight differentiation) + adds `config.font_dirs = { %LOCALAPPDATA%\\Microsoft\\Windows\\Fonts }` on Windows as a belt-and-suspenders fallback for bootstrap ordering races; `chezmoi/AppData/Roaming/Zed/settings.json` flips `buffer_font_family` + terminal `font_family`; `chezmoi/AppData/Roaming/Code/User/settings.json` prepends the Nerd Font to `editor.fontFamily` (keeps Monaspace Neon as fallback) + swaps `terminal.integrated.fontFamily`; `chezmoi/dot_config/starship.toml` swaps three previously-Unicode-only symbols to Nerd Font equivalents (shlvl `↕` → nf-md-layers-triple, jobs `✦` → nf-fa-gear, status `✘` → nf-fa-times-circle); existing Nerd Font glyphs in the starship config (`hostname.ssh_symbol`, `directory.read_only`, `os.symbols.Linux`, `git_branch.symbol`) and in `eza --icons=auto` start rendering correctly once the font is installed — no edit needed there. CLAUDE.md gains the triple-edit invariant (`versions.mk` ↔ `lib/font.sh` ↔ `install-nerd-fonts.ps1`) and two new file-care entries; three new lines under Quick verification (Linux `fc-list`, Windows file + HKCU counts, visual smoke test). | **Yes** | `setup-linux` and `setup-windows` sections each get a bullet about the font install + path. New `<details>` accordion in §troubleshooting walks tofu-box recovery on both OSes, the VS Code / Zed cache-at-launch gotcha, the WezTerm reload, and the WSL no-op-is-intentional case (with the "run `bootstrap.ps1` on the Windows side instead" hint). |
```

(That's one giant table row — long descriptions match the style of existing rows like #33 and #48.)

- [ ] **Step 2: Verify the row landed**

```bash
tail -3 CLAUDE_CHANGELOG.md
```

Expected: the last non-empty line in the file is the new row, starting `| Added JetBrainsMono Nerd Font Mono as a dev_machine-only managed asset`.

```bash
grep -c 'JetBrainsMono Nerd Font Mono' CLAUDE_CHANGELOG.md
```

Expected: at least 1 (the new row).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(changelog): record JetBrainsMono Nerd Font Mono integration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Final verification — Linux WSL-skip path + sandbox-real-install path

**Files:**
- No file changes. Verification only.

The user's host is WSL2, so the production `make nerd-fonts` invocation against `~/.local/share/fonts/` would skip. We've already exercised that path in Task 4 step 7. This task exercises the *actual* download + extract path against a sandbox dir (parallel to Task 3 step 5) to confirm everything works end-to-end after the make target wiring landed.

- [ ] **Step 1: Run `lib/font.sh` directly against a sandbox dir**

```bash
SANDBOX=$(mktemp -d)
makefile/lib/font.sh "$SANDBOX" 3.4.0 "$SANDBOX/.stamp"
```

Expected: prints `==> JetBrainsMono Nerd Font Mono v3.4.0` and `installed 6 Mono variants to <sandbox>/JetBrainsMonoNerdFontMono`. Exit 0.

If you hit a GitHub rate limit (HTTP 403):

```bash
GITHUB_TOKEN=<token> makefile/lib/font.sh "$SANDBOX" 3.4.0 "$SANDBOX/.stamp"
```

- [ ] **Step 2: Verify six TTFs and stamp**

```bash
ls "$SANDBOX/JetBrainsMonoNerdFontMono/" | wc -l
ls "$SANDBOX/JetBrainsMonoNerdFontMono/" | sort
test -f "$SANDBOX/.stamp" && echo "stamp OK"
```

Expected:
- Count: `6`.
- Sorted listing exactly matches:
  ```
  JetBrainsMonoNerdFontMono-Bold.ttf
  JetBrainsMonoNerdFontMono-BoldItalic.ttf
  JetBrainsMonoNerdFontMono-Italic.ttf
  JetBrainsMonoNerdFontMono-Medium.ttf
  JetBrainsMonoNerdFontMono-MediumItalic.ttf
  JetBrainsMonoNerdFontMono-Regular.ttf
  ```
- `stamp OK`.

- [ ] **Step 3: Cleanup sandbox**

```bash
rm -rf "$SANDBOX"
```

- [ ] **Step 4: Verify Makefile target WSL-skip on the user's host**

```bash
rm -rf /tmp/nerd-fonts-test-stamps
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps
ls /tmp/nerd-fonts-test-stamps/
```

Expected:
- First make invocation prints `skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm`.
- Stamp file `nerd-fonts-3.4.0.done` is present.

```bash
cd makefile && make nerd-fonts MODE=dev STAMP=/tmp/nerd-fonts-test-stamps
```

Expected: silent no-op (make resolves the stamp file is up-to-date).

```bash
rm -rf /tmp/nerd-fonts-test-stamps
```

- [ ] **Step 5: Verify `make -n MODE=prod provision` excludes the new target**

```bash
cd makefile && make -n MODE=prod provision 2>&1 | grep -E 'nerd-fonts|font\.sh|JetBrainsMono'
```

Expected: no matches. prod_machine hosts get no font install.

- [ ] **Step 6: Verify scope.mk's IS_WSL export passes through correctly**

```bash
cd makefile && make -p MODE=dev 2>/dev/null | grep -E '^(IS_WSL|JETBRAINSMONO_NERD_VERSION)'
```

Expected:
- `IS_WSL := true` (running on WSL2)
- `JETBRAINSMONO_NERD_VERSION := 3.4.0`

- [ ] **Step 7: Lint the full repo for CRLF leaks in newly-edited files**

```bash
for f in makefile/versions.mk makefile/scope.mk makefile/Makefile makefile/lib/font.sh scripts/install-nerd-fonts.ps1 bootstrap.ps1; do
  echo "=== $f ==="
  file "$f"
done
```

Expected: no occurrences of "CRLF line terminators". For PowerShell files (`bootstrap.ps1`, `install-nerd-fonts.ps1`), the output should include "with BOM".

- [ ] **Step 8: Git lint** — confirm executables are mode 100755 in the index

```bash
git ls-files --stage makefile/lib/font.sh
```

Expected: `100755 <sha> 0	makefile/lib/font.sh`.

- [ ] **Step 9: (Optional, Windows-side test from WSL)** Run the PowerShell installer through the WSL→Windows passthrough

This actually installs the font on the Windows host. Only run if you want the install to take effect now (otherwise leave it for a clean `bootstrap.ps1` run on the Windows side).

```bash
powershell.exe -NoLogo -File "$(wslpath -w "$(pwd)/scripts/install-nerd-fonts.ps1")"
```

Expected: prints `==> Installing JetBrainsMono Nerd Font Mono v3.4.0` then `installed 6 Mono variants to ...`. On re-run, prints `nerd-fonts already installed (v3.4.0)`.

Verify Windows-side install:

```bash
powershell.exe -NoLogo -Command "(Get-ChildItem \"\$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf\").Count"
```

Expected: `6`.

```bash
powershell.exe -NoLogo -Command "(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties | Where-Object Name -Like 'JetBrainsMonoNerdFontMono-*' | Measure-Object | Select-Object -ExpandProperty Count"
```

Expected: `6`.

- [ ] **Step 10: Visual smoke test in WezTerm**

In any WezTerm pane, press `Ctrl+Shift+R` to reload the config (picks up the new `JetBrainsMono Nerd Font Mono` body font + Windows-side `config.font_dirs`).

In a new pane, run:

```bash
printf '     \n'
```

Expected: folder, home, megaphone, powerline arrow, calendar, github icons rendered crisply — no tofu boxes.

Also try starship's new glyphs:

```bash
# Should show the new nf-md-layers-triple icon, not the old ↕
exec zsh   # starts a sub-shell → SHLVL >= 2 → shlvl module fires
```

Expected: prompt shows the new layered-triple Nerd Font glyph for shell-nesting depth, plus all other prompt segments (hostname ssh icon, directory read-only padlock when in a read-only dir, status circle on `false; ` etc.) now render correctly.

- [ ] **Step 11: No commit** — this task is verification only.

If any step failed, fix the underlying issue in the relevant earlier task's file, re-verify, and commit the fix as its own commit (do NOT amend the original).

---

### Final state checklist

After all tasks complete:

- [ ] `git log --oneline -10` shows the chain of commits in order: versions.mk → scope.mk → lib/font.sh → Makefile → install-nerd-fonts.ps1 → bootstrap.ps1 → wezterm.lua → Zed → VS Code → starship → CLAUDE.md → README.html → CLAUDE_CHANGELOG.md.
- [ ] `git status` clean.
- [ ] All Quick verification commands in the spec (`docs/superpowers/specs/2026-05-28-jetbrains-mono-nerd-font-design.md`) pass on the host of execution.
- [ ] Linux dev_machine sandbox install succeeds (Task 14 steps 1–2).
- [ ] WSL-skip path fires correctly on the user's host (Task 14 step 4).
- [ ] prod_machine provision excludes the new target (Task 14 step 5).
- [ ] Optional: Windows-side install succeeds via WSL→Windows PowerShell passthrough (Task 14 step 9).
- [ ] Optional: visual smoke test in WezTerm shows Nerd Font glyphs rendering (Task 14 step 10).
