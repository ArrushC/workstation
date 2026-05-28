# JetBrains Mono Nerd Font — design

**Status:** Approved
**Date:** 2026-05-28
**Owner:** Arrush Chaturvedi

## Goal

Install **JetBrainsMono Nerd Font Mono** on every interactive host the workstation repo manages, and switch WezTerm + tracked editors to use it. Pay-off: Nerd Font glyphs that the existing chezmoi-managed configs already assume (starship icons, eza `--icons=auto`, lazygit, k9s, yazi, broot, helix file-tree icons, chezit, ccstatusline widgets) finally render correctly instead of as tofu boxes. Claude Code, running inside WezTerm, picks this up "for free" since its rendering is whatever the host terminal applies.

Non-goals: replacing the colour scheme, redesigning the starship prompt structure, re-enabling the disabled `[git_branch]` / `[git_status]` modules (removed deliberately per commit `eae6956`), touching VS Code colour theme, vendoring TTF blobs in git.

## Decisions

Captured during brainstorming, in order:

1. **App scope: WezTerm + tracked editors.** WezTerm body + tab-bar font; Zed (currently `JetBrains Mono`); VS Code (currently `Monaspace Neon`, kept as a fallback after the swap). Not enforced as the OS-wide default monospace — other apps that ask fontconfig for `monospace` keep whatever they currently resolve to. Rationale: keeps the blast radius bounded to the apps we actually control via the repo.
2. **Variant: JetBrainsMono Nerd Font Mono** (strict single-cell width for all glyphs, including icons). Cleanest column alignment in Claude Code, lazygit, eza, and other grid-strict TUIs. Other Nerd Font variants (regular, Propo) explicitly rejected.
3. **Distribution: makefile target download** (mirrors `node-runtime`). Version pin in `versions.mk`; bespoke target downloads the official `JetBrainsMono.tar.xz` from `ryanoasis/nerd-fonts` releases at install time; no TTF binaries in git. Windows handled by a parallel `scripts/install-nerd-fonts.ps1` invoked from `bootstrap.ps1`. Vendoring (~20 MB blob) and pure chezmoi-script (chezmoi-owned versioning) explicitly rejected.
4. **VS Code: included.** Editor + integrated terminal font swap. Monaspace Neon retained as a fallback in the editor `fontFamily` list so a host without the font still has a readable monospace.
5. **Starship: folded in.** Three Unicode-only symbols swapped for Nerd Font equivalents (shlvl, jobs, status). All other existing Nerd Font glyphs already in the config (`hostname.ssh_symbol`, `directory.read_only`, `os.symbols.Linux`, `git_branch.symbol`) require zero edits — they're already correct and will start rendering once the font is installed.
6. **WSL hosts skip the Linux install.** WezTerm runs on the Windows host and rasterises text using Windows-registered fonts; running `fc-cache` inside the WSL distro adds nothing to the rendering path. The `nerd-fonts` target detects WSL via a new `IS_WSL` export in `scope.mk` and writes its stamp without doing work — re-runs stay fast and `make dev` doesn't grow a phantom "missing fonts" warning per WSL host.

## Architecture

Three asset-deployment surfaces plus four config-edit surfaces. All bounded; no new build patterns introduced.

### Surface 1: Linux install (`makefile/`)

1. **`makefile/versions.mk`** — new variable:
   ```make
   # --- Fonts (dev-only, MODE=dev hosts only) ----------------------------------
   JETBRAINSMONO_NERD_VERSION := <latest stable from ryanoasis/nerd-fonts/releases — pinned at writing-plans time>
   ```
   Same versioning pattern as `EGET_VERSION`, `NODE_VERSION`, etc. — single source of truth for the Linux install. Pin chosen at writing-plans time by querying the latest tag.

2. **`makefile/lib/font.sh`** (new, mode 0755, LF-only). Mirrors `makefile/lib/node.sh` structurally:
   - Args: `$1 = DEST_PARENT` (`~/.local/share/fonts` — note: this is *not* the same `$DEST` the binary tools install to; passed explicitly to keep the lib script general), `$2 = VERSION`, `$3 = STAMP_FILE`.
   - Downloads `https://github.com/ryanoasis/nerd-fonts/releases/download/v$2/JetBrainsMono.tar.xz` via `curl -L --fail -sS`; honours `GITHUB_TOKEN` for rate-limit headroom (Authorization header on the curl call, same pattern as `makefile/lib/archive.sh`).
   - Verifies SHA256 against a pin recorded at the top of the script (hand-recorded at the same moment as bumping `JETBRAINSMONO_NERD_VERSION`; same pattern as `chezmoi/dot_local/share/wezterm/wezterm.terminfo`'s pinned hash). Hard-fail on mismatch — no partial install.
   - Extracts only the six Mono variants — `JetBrainsMonoNerdFontMono-{Regular,Italic,Bold,BoldItalic,Medium,MediumItalic}.ttf` — via `tar -xJf <tarball> -C "$1/JetBrainsMonoNerdFontMono" --strip-components=0 --wildcards 'JetBrainsMonoNerdFontMono-*.ttf'` (or `tar` + post-filter, whichever lands cleanest at impl time).
   - `rm -rf "$1/JetBrainsMonoNerdFontMono"` before deposit, recreating the directory empty. Guards against orphaned files if Nerd Fonts upstream renames `.ttf` files between releases (their per-file naming has shifted historically). Same intent as `node.sh`'s old-version sweep.
   - Runs `fc-cache -f "$1/JetBrainsMonoNerdFontMono"` — scoped to the subdir so re-runs are <100ms. Soft-fail with warning if `fc-cache` not on PATH (exits 0, prints "fontconfig not installed — install `fontconfig` package to enable font discovery").
   - Touches the stamp file at the end. On any earlier failure, no stamp → re-run retries.

3. **`makefile/Makefile`** — new bespoke target (not via `EGET_TOOL` — this isn't a static binary going to `$DEST`). Pattern matches `node-runtime` and `claude-cli`:
   ```make
   .PHONY: nerd-fonts clean-nerd-fonts
   nerd-fonts: $(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done
   $(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done:
   	@if [ "$(IS_WSL)" = "true" ]; then \
   	  printf '  skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm\n'; \
   	  mkdir -p $(STAMP) && touch $@; \
   	else \
   	  lib/font.sh "$$HOME/.local/share/fonts" $(JETBRAINSMONO_NERD_VERSION) $@; \
   	fi
   clean-nerd-fonts:
   	@rm -rf "$$HOME/.local/share/fonts/JetBrainsMonoNerdFontMono" $(STAMP)/nerd-fonts-*.done
   ```
   **No `$(SUDO)`** — `~/.local/share/fonts/` is user-owned and `fc-cache` runs against a user dir. Other bespoke targets (`node-runtime`, `claude-cli`) use `$(SUDO)` because they deposit to `$(DEST)` (`/usr/local/bin` on dev) which is system-owned. The font target is deliberately user-scope to keep the install consistent across the SSH-user space; if a future change moves fonts to `/usr/share/fonts/` for any reason, `$(SUDO)` must be added.

4. **MODE=dev wiring.** Adds `nerd-fonts` to the `provision` target's deps. The existing line `provision: claude-cli node-runtime dozzle-service cockpit-service` (`Makefile:279`) is conditionally extended on `MODE=dev` only — parallel to how `claude-cli` and `node-runtime` already are dev-only. On `MODE=prod`, the target is unreachable and the stamp is never written. Implementation note: confirm at writing-plans time whether `provision`'s current deps are wrapped in a `MODE=dev` conditional or are unconditional (the comment at `:268` describes "tools.yml → tools (scope) + user-tools + claude-cli (dev only)" which suggests there's existing gating logic — extend rather than re-invent).

### Surface 2: WSL detection (`makefile/scope.mk`)

5. **`makefile/scope.mk`** — derive and export `IS_WSL`:
   ```make
   IS_WSL := $(shell { [ -n "$$WSL_DISTRO_NAME" ] || grep -qi microsoft /proc/version 2>/dev/null; } && echo true || echo false)
   export IS_WSL
   ```
   Same probe as `bootstrap.sh`'s `is_wsl()` helper (which checks `$WSL_DISTRO_NAME` then `/proc/version`). Centralising it here lets the `nerd-fonts` recipe skip on WSL hosts. If the probe needs to grow (e.g. WSL 1 vs WSL 2), this is the one place to extend it — parallel detection paths must not appear elsewhere.

### Surface 3: Windows install (`scripts/install-nerd-fonts.ps1` + `bootstrap.ps1`)

6. **`scripts/install-nerd-fonts.ps1`** (new, UTF-8 with BOM per the PowerShell-script convention). Mirrors the Linux side conceptually:
   - Header constants: `$Version = '<version pin>'` and `$Sha256 = '<sha>'` — hand-mirrored to `versions.mk`'s `JETBRAINSMONO_NERD_VERSION` (new CLAUDE.md dual-edit invariant — see Surface 7).
   - Fast-path no-op: if a stamp file at `$env:LOCALAPPDATA\workstation\nerd-fonts.$Version.stamp` exists AND all six `.ttf` files are present in `$env:LOCALAPPDATA\Microsoft\Windows\Fonts\` AND the matching `(TrueType)` registry entries exist in `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`, exit 0 with `"  nerd-fonts already installed (v$Version)"`.
   - Downloads to a temp dir via `Invoke-WebRequest -UseBasicParsing`. Honours `$env:GITHUB_TOKEN` (Authorization header).
   - Verifies `Get-FileHash -Algorithm SHA256` against `$Sha256`. Hard-fail on mismatch.
   - Sweeps stale `JetBrainsMonoNerdFontMono-*.ttf` files in the user fonts dir and their HKCU registry entries (idempotency on version bump).
   - Extracts via `Expand-Archive` (or `tar.exe -xJf` — `tar.exe` ships on Win10 1803+, supports `.xz`). Filters to the six Mono variants. Copies into `%LOCALAPPDATA%\Microsoft\Windows\Fonts\`.
   - Registers each file in `HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts` with the `(TrueType)` suffix convention. Per-user install — does NOT need admin for the registry write itself, even though `bootstrap.ps1` already runs elevated.
   - Soft-fails the registry step (continues with file-only deposit + warning) if the registry write is blocked. WezTerm via `config.font_dirs` still works; Zed/VS Code may not until manual registration.
   - Touches the stamp file at the end.
   - All file/registry operations bracketed with informative output mirroring `bootstrap.ps1`'s existing house style.

7. **`bootstrap.ps1`** — add a new step between step 7 (BurntToast) and step 8 (ssh key). Numbering shifts accordingly (step 8 → step 9; verification at the bottom updated). Step body invokes `scripts/install-nerd-fonts.ps1` from `$RepoPath`. Surfaces a clear progress line ("==> Installing JetBrainsMono Nerd Font Mono v$Version"). Unrecoverable font install hard-fails bootstrap (file download / SHA mismatch); recoverable (registry-write blocked) emits a warning and continues.

### Surface 4: WezTerm config (`chezmoi/dot_config/wezterm/wezterm.lua`)

8. Two font-name edits, one new `font_dirs` directive, three comment updates:
   - `:140` body font: `wezterm.font('JetBrains Mono', { weight = 'Regular' })` → `wezterm.font('JetBrainsMono Nerd Font Mono', { weight = 'Regular' })`.
   - `:176` `window_frame.font`: family changes; weight stays `'Medium'` (load-bearing per the surrounding comments — preserves the Regular-body / Medium-tabs visual differentiation).
   - New near the font directives: `config.font_dirs` populated only on Windows (via the existing `wezterm.target_triple` check that's already in the file for the WSL block); points at `os.getenv('LOCALAPPDATA') .. '/Microsoft/Windows/Fonts'`. Belt-and-suspenders against ordering races where WezTerm reads its config before Windows registers the freshly installed font.
   - Comments at `:171–176`, `:173`, `:809` mention "JetBrains Mono" / "JetBrains Mono Medium" by name — update to "JetBrainsMono Nerd Font Mono" so docs don't drift.

### Surface 5: Zed (`chezmoi/AppData/Roaming/Zed/settings.json`)

9. Two edits:
   - `:16` `"buffer_font_family": "JetBrains Mono"` → `"JetBrainsMono Nerd Font Mono"`.
   - `:76` terminal `"font_family": "JetBrains Mono"` → `"JetBrainsMono Nerd Font Mono"`.
   - `:15` `"ui_font_family": ".ZedSans"` stays — that's the proportional UI font, not a monospace.

### Surface 6: VS Code (`chezmoi/AppData/Roaming/Code/User/settings.json`)

10. Two edits:
    - `:5` `"editor.fontFamily"`: `"Monaspace Neon, Consolas, 'Courier New', monospace"` → `"JetBrainsMono Nerd Font Mono, Monaspace Neon, Consolas, 'Courier New', monospace"`. Keeps Monaspace Neon as the next fallback — graceful degradation on a host where the font install fails.
    - `:24` `"terminal.integrated.fontFamily"`: `"Monaspace Neon"` → `"JetBrainsMono Nerd Font Mono"`. Terminal needs the Nerd Font icons; VS Code resolves missing fonts to a default monospace gracefully, no explicit fallback needed.

### Surface 7: Starship polish (`chezmoi/dot_config/starship.toml`)

11. Three symbol swaps — all targeting symbols that are currently Unicode-only and would benefit from a Nerd Font glyph now that one exists:
    - `[shlvl] symbol = "↕"` → `"  "` (nf-md-layers-triple) — visualises nested shell layers.
    - `[jobs] symbol = "✦"` → `" "` (nf-fa-gear) — visualises background work.
    - `[status] symbol = "✘"` → `" "` (nf-fa-times-circle) — matches the visual weight of the rest of the prompt.
    - Explicitly NOT changed: `[character] success_symbol`/`error_symbol` (chevron `❯` is idiomatic), `[container] symbol = "⬢"` (the hex matches Docker's wordmark — disabled module anyway), `[time]` (no symbol).

### Surface 8: documentation

12. **`README.html`** — three edits:
    - §setup-linux: add bullet under "What this installs" calling out the font.
    - §setup-windows: same.
    - §troubleshooting: new accordion entry "Tofu boxes / missing icons after install" → "Run `fc-list | grep JetBrainsMono` (Linux) or check `%LOCALAPPDATA%\Microsoft\Windows\Fonts\` (Windows); restart WezTerm / VS Code / Zed if recently installed (apps cache font lists at launch); confirm `JETBRAINSMONO_NERD_VERSION` is pinned in `versions.mk`."
    - `docs/README/README.css` / `README.js` — untouched. No new UI primitives.

13. **`CLAUDE.md`** — new entries:
    - **Load-bearing invariants:** add a row mirroring the existing `CCSTATUSLINE_VERSION` dual-edit invariant: **`versions.mk` ↔ `scripts/install-nerd-fonts.ps1` dual-edit for `JETBRAINSMONO_NERD_VERSION`.** The `$Version`/`$Sha256` literals in the Windows script MUST mirror `JETBRAINSMONO_NERD_VERSION` (and its accompanying SHA256 record in `makefile/lib/font.sh`) in `makefile/versions.mk`. Bumping the pin requires editing both — no chezmoi-template variable currently bridges them. Drift means Linux and Windows install different font versions, with confusing UX (icons render slightly differently across host kinds; cacheable bugs from mid-rollout sets).
    - **Files Claude should be careful with:** rows for `makefile/lib/font.sh` (LF-only, 0755, GITHUB_TOKEN-aware, SHA-pinned, exits 0 on missing fc-cache) and `scripts/install-nerd-fonts.ps1` (UTF-8 with BOM, per-user font install convention, dual-edits with `versions.mk`).

14. **`CLAUDE_CHANGELOG.md`** — append a row per the existing pattern.

## Data flow

How the Nerd Font reaches each consumer post-install:

- **WezTerm on Windows** — reads `wezterm.lua` (via `WEZTERM_CONFIG_FILE`). Font name resolves through (a) Windows GDI font tables (populated by `install-nerd-fonts.ps1`'s registry writes), or (b) `config.font_dirs` directly pointing at `%LOCALAPPDATA%\Microsoft\Windows\Fonts\`. Belt-and-suspenders means at least one path works even if the other is mid-rollout.
- **Local PowerShell tab** — rendered by WezTerm. Font is WezTerm's, not PowerShell's. Automatic.
- **WSL tab** — rendered by WezTerm. Linux-side font install is irrelevant to *display*. (The Linux install matters only on bare-metal Linux desktop hosts that don't run WezTerm via the Windows route.)
- **SSH-domain tab** — rendered by WezTerm locally. Remote host needs no font.
- **Claude Code in any of the above** — outputs to its terminal; whatever WezTerm renders, Claude Code inherits. Automatic.
- **VS Code** — needs Windows GDI registration. Picked up after `install-nerd-fonts.ps1` runs; VS Code may need a restart to re-scan font lists (called out in the new troubleshooting entry).
- **Zed** — same as VS Code: needs Windows GDI registration.
- **Bare-metal Linux dev_machine host** (not WSL) — `make nerd-fonts MODE=dev` deposits files in `~/.local/share/fonts/JetBrainsMonoNerdFontMono/` and runs `fc-cache`. Native Linux WezTerm / Zed / VS Code now see the font via fontconfig.

The **`config.font_dirs` belt-and-suspenders** specifically guards against the bootstrap-ordering race where WezTerm reads `wezterm.lua` before `install-nerd-fonts.ps1` has finished registering the font with Windows GDI. In that window, GDI lookup misses, but `font_dirs` directly reads the file.

## Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| GitHub rate limit (Linux download) | `lib/font.sh` curl 403 → hard-fail with explicit message | Set `GITHUB_TOKEN` and re-run `make nerd-fonts` |
| GitHub rate limit (Windows download) | `Invoke-WebRequest` 403 → hard-fail; `bootstrap.ps1` aborts | Set `$env:GITHUB_TOKEN` and re-run `bootstrap.ps1` |
| SHA256 mismatch (either side) | Hash check fails — hard-fail, no partial install | Confirm upstream tag hasn't been re-released; if legitimate (Nerd Fonts re-cuts a release), bump the hash pin in both `lib/font.sh` and `install-nerd-fonts.ps1` |
| `fc-cache` not on PATH (Linux) | `lib/font.sh` prints warning, exits 0 (no stamp) | `dnf install fontconfig` (already standard on dev_machine distros; theoretical case); re-run `make nerd-fonts` |
| HKCU registry write blocked (Windows) | PowerShell catches exception, prints warning, continues with file-only deposit | WezTerm still works via `font_dirs`; manually register fonts via Settings → Personalization → Fonts (drag files), or re-run from an unrestricted user context |
| WSL host runs `make nerd-fonts` by mistake | `IS_WSL=true` branch fires "skipping" message, writes stamp | None needed — intentional no-op |
| `font_dirs` env var resolves empty | WezTerm logs missing-font warning, falls back to its built-in font | Windows-side install completes → restart WezTerm |
| Apps cache old font list at launch | VS Code/Zed render Monaspace Neon / .ZedSans after fresh install | Quit and relaunch the app |
| Bare-metal Linux without WezTerm | N/A — same install works for any Linux app that uses fontconfig | N/A |
| Old `JetBrainsMonoNerdFontMono` files left after version bump | `lib/font.sh` and `install-nerd-fonts.ps1` both sweep stale files before depositing new | Automatic |
| Version drift between `versions.mk` and `install-nerd-fonts.ps1` | New CLAUDE.md invariant calls this out. No automated detection. | Manual review; CLAUDE.md ↔ Quick-verification rule below catches it eventually |

The Linux helper is `exit 0` on the soft-failure paths so a daily `make dev` doesn't gain a new failure mode just from a missing `fontconfig` package on an unusual host. The Windows side is `bootstrap.ps1`-only (not part of any daily workflow), so it can be stricter — hard-fails on download/hash issues are surfaced as errors.

## Verification

### Linux dev_machine (after `make dev` or `make nerd-fonts MODE=dev`)
```bash
# Files deposited
ls ~/.local/share/fonts/JetBrainsMonoNerdFontMono/ | wc -l    # expect: 6

# fontconfig sees them
fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l       # expect: 6

# Idempotency
make nerd-fonts MODE=dev                                       # expect: no-op (stamp hit), <1s

# Sandbox sanity
cd makefile && make nerd-fonts MODE=dev DEST=/tmp/install-test STAMP=/tmp/install-test-stamps
ls /tmp/install-test-stamps/nerd-fonts-*.done                  # stamp written
```

### Linux prod_machine (no font should install)
```bash
cd makefile && make -n MODE=prod provision | grep nerd-fonts   # expect: no matches
```

### WSL dev_machine (should skip)
```bash
cd makefile && make nerd-fonts MODE=dev
# expect: "skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm"
ls $STAMP/nerd-fonts-*.done                                    # stamp still written (no-op marker)
```

### Windows (after `bootstrap.ps1`)
```powershell
# Files deposited
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf" | Measure-Object  # Count: 6

# Registry registration
$registered = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') | Get-Member -MemberType NoteProperty | Where-Object Name -Like 'JetBrainsMonoNerdFontMono-*'
$registered.Count                                                                                            # 6

# Idempotency
. $RepoPath\scripts\install-nerd-fonts.ps1                                                                  # "already installed" message
```

### Visual smoke test (any WezTerm pane post-install + WezTerm reload via Ctrl+Shift+R)
```bash
printf '          \n'
# expect: folder, home, megaphone, powerline arrow, calendar, github — all crisp, no tofu
```

### Starship polish (any new prompt after install)
- `cd <repo>; exec zsh` to start a sub-shell: `[shlvl]` glyph renders as a layered icon, not `↕`.
- Background a job (`sleep 60 &`): `[jobs]` glyph renders as a gear, not `✦`.
- Run a command that exits non-zero (`false`): `[status]` glyph renders as a circled-X, not `✘`.

### CLAUDE.md "Quick verification" additions

Two new lines, parallel to the existing wezterm-terminfo verification:

- `fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l` on every Linux dev_machine after `make dev` — should return `6`. WSL hosts return `0` deliberately (font is on the Windows side).
- After `bootstrap.ps1` on Windows: `(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf").Count` — should return `6`.

## What does NOT change

- `bootstrap.sh` — still a thin seed. No per-tool versions, no install logic. The `make nerd-fonts` recipe lives in the makefile layer where the rest of the tool installs are.
- `makefile/packages.mk` — no new packages required (`fontconfig` is transitively present on every supported distro via other base packages; we soft-fail if missing rather than depend on it).
- `makefile/tools.mk` — untouched. Fonts aren't binary tools; the `nerd-fonts` target is bespoke in `Makefile`, not registered via `EGET_TOOL`.
- `.chezmoiignore.tmpl` — no new entries. WezTerm config already Linux-ignored; Zed + VS Code settings already Windows-only via `AppData/Roaming/` rules.
- `hosts.conf`, `manage-hosts.{sh,ps1}` — untouched.
- The 3-piece WSL invariant, the wezterm sentinel block, the ccstatusline sentinel block, the parity-pair invariants — all preserved.
- `chezmoi/private_dot_claude/private_settings.json.tmpl` — untouched. Claude Code's rendering is the terminal's; no Claude-side setting affects font choice.

## Rollout sequencing

This is a single PR (unlike the two-phase wezterm-truecolor rollout) because (a) the surfaces are independent — the font install and the config edits both depend on the same one-PR atom, and (b) the soft-failure modes ensure no host breaks if it lands half-rolled.

1. Land the PR.
2. **Windows host:** `cd $RepoPath; git pull; .\bootstrap.ps1` (already elevated for the choco step). Step 7.5 fires the new font install; step 5 (`chezmoi apply`) deploys the updated Zed + VS Code settings. WezTerm picks up the new font name on next config reload (`Ctrl+Shift+R` or restart).
3. **Each managed Linux dev_machine:** `czu` (chezmoi update + apply — picks up nothing visible, since the WezTerm/Zed/VS Code config edits are Windows-only) followed by `cd <repo>/makefile && make nerd-fonts MODE=dev`. Bare-metal dev_machine hosts get the fonts; WSL hosts get the no-op skip and continue.
4. **prod_machine hosts:** nothing to do. `make -n MODE=prod provision` shows no `nerd-fonts` matches.

If a host gets missed between steps, the visible symptom is "still seeing tofu" — `make nerd-fonts MODE=dev` (Linux) or `.\bootstrap.ps1` (Windows) is the recovery. Re-runs are stamp-no-ops.
