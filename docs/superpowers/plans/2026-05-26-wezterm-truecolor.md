# WezTerm Truecolor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make WezTerm advertise truecolor (24-bit RGB) to every TUI that runs in a WezTerm pane — local PowerShell, WSL, SSH-domain, and manual `ssh` — using two signals: `COLORTERM=truecolor` in shell rc files (universal app-detection convention) plus a vendored `wezterm` terminfo entry (`Tc`/`Smulx`/`Setulc` capability advertising).

**Architecture:** Two-phase rollout, two commits, two PRs. Phase 1 vendors the terminfo, adds a chezmoi `run_onchange` script that `tic`'s it into `~/.terminfo/` on every host, and adds `COLORTERM=truecolor` to `dot_zshrc.tmpl` + `dot_bashrc.tmpl`. Phase 2 flips `config.term='wezterm'` in `wezterm.lua` *after* the fleet has applied phase 1 (verified via `infocmp wezterm` on every host). All chezmoi-managed; no makefile changes.

**Tech Stack:** chezmoi (templated dotfiles, `.chezmoiscripts/run_onchange_*.sh.tmpl`), bash scripting, ncurses `tic`/`infocmp`, WezTerm Lua config, Git/GitHub.

**Spec:** `docs/superpowers/specs/2026-05-26-wezterm-truecolor-design.md`

---

## File Structure

**Phase 1** (one commit covering all six items):
- Create: `chezmoi/dot_local/share/wezterm/wezterm.terminfo` (vendored upstream file, ~3 KB)
- Create: `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl` (Linux-only `tic` invocation, sha256sum-pinned)
- Modify: `chezmoi/dot_zshrc.tmpl` (add `export COLORTERM=truecolor` to Core env block)
- Modify: `chezmoi/dot_bashrc.tmpl` (same line, parity pair)
- Modify: `README.html` (§appearance note + new troubleshooting entry)
- Modify: `CLAUDE_CHANGELOG.md` (append phase-1 row)

**Phase 2** (separate commit, after fleet has applied phase 1):
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (add `config.term = 'wezterm'` near the `front_end` block)
- Modify: `CLAUDE.md` (add load-bearing-invariant entry: TERM-wezterm depends on terminfo install)
- Modify: `README.html` (extend §appearance note)
- Modify: `CLAUDE_CHANGELOG.md` (append phase-2 row)

Files that change together commit together. The two phases are sequenced by a rollout gate (run `czu && cza` on every host between them), not by code dependency — phase 2 just adds one line.

---

# Phase 1 — Ship terminfo + COLORTERM

### Task 1: Pin and vendor `wezterm.terminfo` from upstream

**Files:**
- Create: `chezmoi/dot_local/share/wezterm/wezterm.terminfo`

WezTerm tags releases as `YYYYMMDD-HHMMSS-<sha>`. Pin to the latest stable release at vendoring time so the file is reproducible after future upstream changes. The chezmoi `run_onchange` script (Task 2) hashes this file's content, so future upstream bumps are picked up by re-running this task and committing the new content — chezmoi auto-re-tic's on the next `cza`.

- [ ] **Step 1: Discover the latest stable WezTerm release tag**

Run:
```bash
gh api repos/wezterm/wezterm/releases/latest --jq '.tag_name'
```
Expected: a single line like `20250712-094732-7f4d3fdb` (the exact tag will vary). Capture it into a shell variable for the next step:
```bash
WEZTERM_TAG="$(gh api repos/wezterm/wezterm/releases/latest --jq '.tag_name')"
echo "$WEZTERM_TAG"   # sanity check — non-empty
```

If `gh` isn't authenticated or returns nothing, fall back to:
```bash
curl -fsSL https://api.github.com/repos/wezterm/wezterm/releases/latest | jq -r '.tag_name'
```

- [ ] **Step 2: Download the terminfo source at that tag and stage it in chezmoi**

```bash
mkdir -p chezmoi/dot_local/share/wezterm
curl -fsSL "https://raw.githubusercontent.com/wezterm/wezterm/${WEZTERM_TAG}/termwiz/data/wezterm.terminfo" \
  -o chezmoi/dot_local/share/wezterm/wezterm.terminfo
```

- [ ] **Step 3: Verify the file looks correct (failing-test equivalent — content shape check)**

Run:
```bash
head -3 chezmoi/dot_local/share/wezterm/wezterm.terminfo
grep -c 'Tc,' chezmoi/dot_local/share/wezterm/wezterm.terminfo
```
Expected: header begins with `# Terminfo describing wezterm` (or similar wezterm-authored preamble); the grep returns `1` (the `Tc` boolean is exactly once in the file). If grep returns 0, the upstream file shape changed and the spec assumption breaks — stop and surface to the user.

- [ ] **Step 4: Verify it compiles with extended capabilities preserved**

Run:
```bash
TMP_TI="$(mktemp -d)"
tic -x -o "$TMP_TI" chezmoi/dot_local/share/wezterm/wezterm.terminfo
infocmp -A "$TMP_TI" -1 wezterm | grep -E '^\s*(Tc|setrgbf|Smulx|Setulc)' | sort
rm -rf "$TMP_TI"
```
Expected: all four capabilities (`Tc`, `setrgbf`, `Smulx`, `Setulc`) appear in the output. If any are missing, the `-x` flag isn't doing its job or the source file is wrong — stop.

- [ ] **Step 5: Record the pinned tag inside the file as a comment header (above the upstream content)**

Open `chezmoi/dot_local/share/wezterm/wezterm.terminfo` and prepend the following two lines at the very top (above the existing upstream content). The terminfo grammar treats `#`-prefixed lines as comments, so prepending is safe:

```
# Vendored from wezterm/wezterm@<TAG> termwiz/data/wezterm.terminfo
# Bump: re-download from https://raw.githubusercontent.com/wezterm/wezterm/<new-tag>/termwiz/data/wezterm.terminfo; chezmoi's run_onchange script auto-re-tic's on next cza.
```

Replace `<TAG>` with the exact tag from Step 1 (e.g., `20250712-094732-7f4d3fdb`). Then re-run the compile check from Step 4 to confirm the prepended comments didn't break the entry.

- [ ] **Step 6: Stage but do not commit yet** — the rest of phase 1 (script + shells + docs) lands in the same commit.

```bash
git add chezmoi/dot_local/share/wezterm/wezterm.terminfo
git status --short    # should show "A  chezmoi/dot_local/share/wezterm/wezterm.terminfo"
```

---

### Task 2: Create the chezmoi `run_onchange` script

**Files:**
- Create: `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl`

The script body is gated by the `{{ if eq .chezmoi.os "linux" -}}...{{- end }}` wrapper per the repo invariant (`.chezmoiscripts/` is not covered by `.chezmoiignore.tmpl`, so the OS gate lives in the script body — same pattern as `run_once_install-claude-plugins.sh.tmpl`). The sha256sum line is what chezmoi diffs to detect "source-file content changed → re-run script."

- [ ] **Step 1: Write the script file**

Path: `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl`

Content (exact):

```bash
{{ if eq .chezmoi.os "linux" -}}
#!/usr/bin/env bash
# run_onchange_install-wezterm-terminfo.sh — compiles the vendored wezterm
# terminfo (chezmoi/dot_local/share/wezterm/wezterm.terminfo) into the user's
# ~/.terminfo/ database via `tic`, so apps querying terminfo on this host see
# the wezterm entry advertising Tc / Smulx / Setulc (truecolor + extended
# underline capabilities). Idempotent: re-runs only when the embedded source
# hash differs from the previous apply (run_onchange semantics — chezmoi
# diffs the rendered script text).
#
# .tmpl gate: linux only. .chezmoiignore does NOT apply to .chezmoiscripts/,
# so the gate lives in the body; on non-linux hosts the file renders empty
# and chezmoi skips it.
#
# Soft-fail on missing prerequisites — chezmoi apply (alias `cza`) is daily-
# workflow and shouldn't gain a new failure mode just because ncurses isn't
# installed.

set -euo pipefail

# Source hash — content changes here force this script to re-run.
# {{ include (joinPath .chezmoi.sourceDir "dot_local/share/wezterm/wezterm.terminfo") | sha256sum }}

SRC="$HOME/.local/share/wezterm/wezterm.terminfo"
if [ ! -f "$SRC" ]; then
  printf 'wezterm.terminfo missing at %s — skipping tic\n' "$SRC" >&2
  exit 0
fi
if ! command -v tic >/dev/null 2>&1; then
  printf 'tic (ncurses) not on PATH — skipping wezterm terminfo install\n' >&2
  exit 0
fi

# -x preserves extended capabilities (Tc, Smulx, Setulc) — load-bearing.
# -o writes to user scope; no sudo needed; ncurses auto-finds ~/.terminfo/.
tic -x -o "$HOME/.terminfo" "$SRC" >/dev/null
{{- end }}
```

- [ ] **Step 2: Render-check the template via chezmoi (no apply, just template expansion)**

Run:
```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl | head -5
```
Expected on a Linux host: prints `#!/usr/bin/env bash` and the next few lines of the rendered body. The sha256sum comment line should resolve to a 64-char hex hash (not the literal `{{ include ... }}` template syntax). If you see `{{` in the output, the template didn't render — chezmoi can't find the source path.

- [ ] **Step 3: Validate the rendered script's shell syntax**

```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl > /tmp/rendered.sh
bash -n /tmp/rendered.sh
echo $?
rm /tmp/rendered.sh
```
Expected: `bash -n` produces no output, `echo $?` prints `0`.

- [ ] **Step 4: Preview the apply with `chezmoi diff` to confirm chezmoi sees both new files**

```bash
chezmoi diff | grep -E 'wezterm.terminfo|run_onchange_install-wezterm-terminfo' | head -20
```
Expected: at least two diff lines — one for the new `~/.local/share/wezterm/wezterm.terminfo` file, one for the chezmoi script being scheduled to run.

- [ ] **Step 5: Run `chezmoi apply` (locally — this is your dev host)**

```bash
chezmoi apply -v 2>&1 | tail -20
```
Expected: shows the install of `~/.local/share/wezterm/wezterm.terminfo` and the execution of the `run_onchange_install-wezterm-terminfo.sh` script. No errors.

- [ ] **Step 6: Verify the compiled terminfo entry is live**

```bash
ls -la ~/.terminfo/w/wezterm
infocmp wezterm | head -1
infocmp -1 wezterm | grep -E '^\s*(Tc|setrgbf|Smulx|Setulc)' | sort
```
Expected:
1. The file `~/.terminfo/w/wezterm` exists (any non-zero size).
2. `infocmp` exit 0 and the first line begins with `wezterm|`.
3. All four capabilities appear in the grep output.

If any of these fails, recover by:
- Missing file: re-run `cza`; if still missing, manually `tic -x -o "$HOME/.terminfo" "$HOME/.local/share/wezterm/wezterm.terminfo"` and inspect the error.
- Missing capabilities: the source file is corrupted or `tic` ran without `-x` — re-check Task 1 Step 4.

- [ ] **Step 7: Stage the script**

```bash
git add chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl
git status --short
```

---

### Task 3: Add `COLORTERM=truecolor` to both shell rcs (parity pair)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl:13-16` (Core env block — currently has `EDITOR`, `VISUAL`, `PAGER`, `MANPAGER`)
- Modify: `chezmoi/dot_bashrc.tmpl:13-16` (same block, same lines, parity pair)

Per the CLAUDE.md parity-pair invariant: any change to env vars / aliases / functions / OSC 7 emission must land in BOTH files in the same commit. Both files currently have a `# --- Core env ---` section with `export EDITOR="hx"` etc. on lines 13-16. We append the `COLORTERM` export to the bottom of that block.

- [ ] **Step 1: Edit `chezmoi/dot_zshrc.tmpl`**

Locate the Core env block:
```
# --- Core env ----------------------------------------------------------------
export EDITOR="hx"
export VISUAL="hx"
export PAGER="less"
export MANPAGER="less"
```

Append `export COLORTERM=truecolor` immediately after `export MANPAGER="less"` so the block becomes:
```
# --- Core env ----------------------------------------------------------------
export EDITOR="hx"
export VISUAL="hx"
export PAGER="less"
export MANPAGER="less"
export COLORTERM=truecolor   # WezTerm advertises 24-bit RGB; apps honor this env-var convention (helix, zellij, starship, glow, eza, fzf, bat).
```

- [ ] **Step 2: Edit `chezmoi/dot_bashrc.tmpl` with the identical line**

Same Core env block (same line numbers; the file is the parity sibling). Append the identical `export COLORTERM=truecolor` line with the same comment, in the same position.

- [ ] **Step 3: Verify parity — both files must have the COLORTERM export in identical form**

Run:
```bash
diff <(grep -n 'COLORTERM' chezmoi/dot_zshrc.tmpl) <(grep -n 'COLORTERM' chezmoi/dot_bashrc.tmpl)
```
Expected: no output (the two greps produce identical lines including the same line number — both files share the same Core env block structure).

- [ ] **Step 4: Apply locally and verify in a new shell**

```bash
chezmoi apply -v 2>&1 | tail -5
zsh -i -c 'echo "$COLORTERM"'      # if zsh is your default
bash -i -c 'echo "$COLORTERM"'     # parity check
```
Expected: both print `truecolor`. If either prints empty, the file didn't apply or the variable assignment is wrong.

- [ ] **Step 5: Stage both files**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
git status --short
```

---

### Task 4: Update README.html for Phase 1

**Files:**
- Modify: `README.html` (§appearance — short note; §troubleshooting — new entry)

The CLAUDE.md decision test: "Would a user reading only README.html still be able to operate this repo after my change?" Phase 1 surfaces a new "expected behavior" (richer colors via COLORTERM) and a new failure mode (`infocmp wezterm` exit 0 as a healthcheck). Both go in README.

- [ ] **Step 1: Locate the §appearance section in README.html**

Run:
```bash
grep -n -E 'id="(appearance|stack)"' README.html | head -5
```
Expected: a line like `<section id="appearance">` (or whichever section currently covers terminal styling — Tokyo Night palette, fonts, etc.). If there's no dedicated `appearance` section, the relevant home is wherever the existing WezTerm-styling prose lives — `git log -S 'Tokyo Night' -- README.html` or `grep -n 'JetBrains Mono\|Tokyo Night' README.html` will find it.

- [ ] **Step 2: Add a paragraph (under the existing appearance/styling content) explaining truecolor signaling**

Exact prose to add (HTML-escape any markup if the surrounding section uses it; the repo's README.html is plain HTML, no Markdown processing):

```html
<p>
  <strong>Truecolor signaling.</strong> Every chezmoi-managed shell exports
  <code>COLORTERM=truecolor</code> on startup (see <code>dot_zshrc.tmpl</code> /
  <code>dot_bashrc.tmpl</code>), so apps like helix, zellij, starship, eza, and bat
  emit 24-bit RGB sequences instead of falling back to 256-color. A second signal
  channel (terminfo) ships via the vendored <code>wezterm.terminfo</code> at
  <code>chezmoi/dot_local/share/wezterm/</code>, which a chezmoi
  <code>run_onchange</code> script compiles into <code>~/.terminfo/</code> on every
  apply. Verify with <code>infocmp wezterm</code> — should exit 0 and list
  <code>Tc</code>, <code>setrgbf</code>, <code>Smulx</code>, <code>Setulc</code>.
</p>
```

Place this paragraph at the natural end of the existing styling/appearance prose. If there's no §appearance, place it inside the toolbelt section's WezTerm card or wherever existing terminal-styling content lives — grep result from Step 1 tells you where.

- [ ] **Step 3: Locate §troubleshooting and add a new entry**

Run:
```bash
grep -n 'id="troubleshooting"' README.html
```
Expected: a single line near line ~2617 (per earlier scan). Find the existing pattern for a troubleshooting entry by inspecting one nearby:
```bash
sed -n '2617,2700p' README.html | head -80
```

- [ ] **Step 4: Add the new troubleshooting entry following the existing pattern**

The entry's symptom is "Colors look banded / 8-bit on host X" and the resolution is "did chezmoi apply run? infocmp wezterm should exit 0." Add it as a new troubleshooting item in the same HTML structure other items use (detail/summary, list item, or accordion section — match the surrounding pattern). Suggested body:

> **Colors look banded or 8-bit on a remote host.** WezTerm renders 24-bit color, but the remote app needs to emit truecolor sequences — it won't unless `$COLORTERM=truecolor` is set in the shell (via the chezmoi-managed `dot_zshrc.tmpl` / `dot_bashrc.tmpl`) or `~/.terminfo/w/wezterm` exists. Run `chezmoi update && chezmoi apply` (`czu && cza`) on the affected host, then verify with `infocmp wezterm` (exit 0) and `echo "$COLORTERM"` (`truecolor` in a new shell).

- [ ] **Step 5: Render-check the README.html in a browser**

CLAUDE.md verification recipe: open README.html in a browser, confirm primitives still render (tabs, flow chips, accordion filter) — not just that the diff is clean. If unstyled, asset paths broke.

```bash
git diff README.html docs/README/README.css docs/README/README.js
```
Should show only README.html changed (no CSS/JS deltas). Visually inspect the new paragraph + troubleshooting entry in a browser.

- [ ] **Step 6: Stage**

```bash
git add README.html
git status --short
```

---

### Task 5: Append a CLAUDE_CHANGELOG.md row for Phase 1

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row to the table)

Per CLAUDE.md: "When changing user-facing surface, update README.html ... in the same commit, then append a row to CLAUDE_CHANGELOG.md." Phase 1 changes user-facing surface (richer colors, new troubleshooting recipe), so it gets a changelog row.

- [ ] **Step 1: Append the row**

Open `CLAUDE_CHANGELOG.md`, find the last row (currently row 44 — the CTRL+click `Down → Nop` follow-up), and append a new row below it. Match the existing row format exactly (three columns: Change, README update?, What to add). Use the exact text:

```
| Phase 1 of WezTerm truecolor: vendored `chezmoi/dot_local/share/wezterm/wezterm.terminfo` (pinned to wezterm/wezterm@<TAG>) + new `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl` (Linux-only via `{{ if eq .chezmoi.os "linux" -}}…{{- end }}` body gate; embeds a sha256sum of the source as a comment so chezmoi's `run_onchange` detection fires on content bumps; soft-fails with stderr-and-exit-0 if `tic` or the source file are missing — keeps `cza` daily-workflow safe). Added `export COLORTERM=truecolor` to `chezmoi/dot_zshrc.tmpl` + `chezmoi/dot_bashrc.tmpl` (parity pair) in the existing Core-env block. `wezterm.lua` is unchanged in this phase — `TERM` continues to advertise as `xterm-256color`; `COLORTERM` alone gets every modern TUI to emit truecolor sequences. Phase 2 (separate commit) flips `config.term='wezterm'` once the fleet has applied phase 1. Deploy scope is every chezmoi-managed host (dev_machine + prod_machine + WSL) — no group gate. | **Yes** | New §appearance paragraph ("Truecolor signaling") explains the two-signal design, points at the source files, and gives `infocmp wezterm` as the healthcheck. New §troubleshooting entry covers "Colors look banded / 8-bit on host X" → `czu && cza` + `infocmp wezterm` + `echo $COLORTERM` triage. No CLAUDE.md invariant in this phase (vendored asset follows existing chezmoi-managed conventions; parity-pair invariant already covers the shell-rc edits). |
```

Replace `<TAG>` with the exact tag pinned in Task 1.

- [ ] **Step 2: Stage**

```bash
git add CLAUDE_CHANGELOG.md
git status --short
```

---

### Task 6: Final phase-1 verification, commit, push, then fleet rollout

- [ ] **Step 1: Confirm the staged set**

```bash
git status --short
```
Expected (six lines):
```
A  chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl
A  chezmoi/dot_local/share/wezterm/wezterm.terminfo
M  chezmoi/dot_bashrc.tmpl
M  chezmoi/dot_zshrc.tmpl
M  README.html
M  CLAUDE_CHANGELOG.md
```
If anything else is staged, unstage it (`git restore --staged <path>`). If anything in the expected list is missing, complete that task first.

- [ ] **Step 2: Re-run local end-to-end verification (regression check)**

```bash
chezmoi apply -v 2>&1 | tail -10
infocmp wezterm | head -1                              # exits 0
infocmp -1 wezterm | grep -E '^\s*(Tc|setrgbf|Smulx|Setulc)' | sort   # all four caps
zsh -i -c 'echo "$COLORTERM"'                           # truecolor
bash -i -c 'echo "$COLORTERM"'                          # truecolor
ls -la ~/.terminfo/w/wezterm                            # non-zero size
```
All must succeed. If any fail, fix before committing.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(wezterm,shell): advertise truecolor via wezterm terminfo + COLORTERM

Vendor wezterm.terminfo (pinned to wezterm/wezterm@<TAG>) into chezmoi at
dot_local/share/wezterm/, with a new run_onchange chezmoi script that
compiles it into ~/.terminfo/ on every apply (tic -x -o ~/.terminfo).
Script embeds a sha256sum of the source as a comment so chezmoi's
run_onchange detection fires when the source is bumped. Soft-fails
(stderr + exit 0) if tic or the source file are missing.

Export COLORTERM=truecolor in dot_zshrc.tmpl + dot_bashrc.tmpl (parity
pair) so every modern TUI (helix, zellij, starship, eza, bat, glow,
fzf) emits 24-bit RGB sequences instead of 256-color quantization.

wezterm.lua is unchanged — TERM stays as xterm-256color in this phase.
Phase 2 (separate commit) flips config.term='wezterm' once the fleet
has applied phase 1; verified per host via `infocmp wezterm` exit 0.

Deploy scope is every chezmoi-managed host (dev + prod + WSL) — the
vendored asset and script aren't gated by .group.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Replace `<TAG>` with the pinned tag from Task 1.

- [ ] **Step 4: Push (per standing memory `feedback-always-push-after-commit`)**

```bash
git push
```
Expected: fast-forward push to main. If denied by auto-mode or rejected by remote, surface the error.

- [ ] **Step 5: Roll out to the fleet**

Run `chezmoi update && chezmoi apply` (= `czu && cza`) on every host that should receive the new terminfo. The 8 hosts in `hosts.conf` plus any WSL distros plus the local dev_machine. Use the existing playbook:

```bash
./scripts/update-hosts.sh --group dev_machine
./scripts/update-hosts.sh --group prod_machine
```

…or run `czu && cza` directly inside each WSL distro / SSH'd host. On each host, the run_onchange script fires and tic's the entry.

- [ ] **Step 6: Verify fleet-wide**

For each host (parallelizable via the update-hosts loop, or one-by-one):
```bash
ssh <host> 'infocmp wezterm >/dev/null && echo OK || echo MISSING-on-<host>'
```
Expected: every host prints `OK`. Any `MISSING-on-X` host needs `czu && cza` run there before phase 2 can proceed safely.

**Phase 1 done. Do not start phase 2 until every host reports `OK` above.**

---

# Phase 2 — Flip `config.term='wezterm'`

### Task 7: Add `config.term = 'wezterm'` to `wezterm.lua`

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` (insert ~3 lines, near line 227 below the existing `config.front_end = 'WebGpu'`)

- [ ] **Step 1: Locate the existing `front_end` block as insertion anchor**

Run:
```bash
grep -n 'config.front_end' chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: a single hit, around line 227 (the `config.front_end = 'WebGpu'` line). The `config.term` line + its comment block goes immediately below it.

- [ ] **Step 2: Insert the new config + comment**

Below the existing `-- GPU rendering` block (which ends at the `config.front_end = 'WebGpu'` line), insert this new block:

```lua

-- TERM advertising — pair with the chezmoi-deployed wezterm terminfo
-- (.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl). Setting
-- TERM=wezterm lets apps query terminfo for Tc / Smulx / Setulc instead of
-- inferring capabilities from the looser xterm-256color entry. PTYs
-- inheriting this TERM: local WSL panes, SSH-domain panes (default_prog
-- zellij attach), and any manual `ssh` from a local tab.
--
-- Pre-req: every target host must have ~/.terminfo/w/wezterm installed,
-- compiled from chezmoi/dot_local/share/wezterm/wezterm.terminfo by the
-- run_onchange script above. Verify per host via `infocmp wezterm`
-- (must exit 0) after `czu && cza`. Hosts without the entry will error
-- on first TUI launch with `Error opening terminal: wezterm` — recover
-- with `cza` on that host (or `TERM=xterm-256color hx file` ad hoc).
config.term = 'wezterm'
```

- [ ] **Step 3: Render-check the file**

Run:
```bash
grep -n 'config.term' chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: a single hit, with the value `'wezterm'`.

Optional Lua-syntax sanity:
```bash
lua -e "loadfile('chezmoi/dot_config/wezterm/wezterm.lua')" 2>&1 || true
```
Note: this won't fully execute (wezterm globals aren't available outside wezterm), but if there's a syntax error, `loadfile` will report it.

- [ ] **Step 4: Apply and reload WezTerm**

If you're editing on a Windows host: `chezmoi apply` updates the source file; WezTerm reads it directly via `WEZTERM_CONFIG_FILE` so no copy step is needed. Press `Ctrl+Shift+R` inside WezTerm to trigger a config reload (or open a brand-new tab — wezterm auto-reloads on file change).

If you're editing on Linux (local) and want WezTerm picked up: same — `cza` propagates the file; on Windows-WezTerm it's read directly from chezmoi source via the env var.

- [ ] **Step 5: Verify the new `TERM` is live in fresh panes**

Open a fresh tab in WezTerm (CTRL+SHIFT+T):
```bash
echo "$TERM"
```
Expected: `wezterm`. Existing panes still show their old `TERM` — only new panes inherit the new value.

- [ ] **Step 6: Verify rendering — truecolor smooth gradient**

In the new pane:
```bash
awk 'BEGIN{ for(c=0;c<256;c++){ printf "\033[38;2;%d;%d;%dm█",c,(c+85)%256,(c+170)%256 } print "\033[0m" }'
```
Expected: a smooth color gradient with no visible banding. Banded output = truecolor isn't being emitted (TERM/COLORTERM not flowing correctly).

- [ ] **Step 7: Stage**

```bash
git add chezmoi/dot_config/wezterm/wezterm.lua
git status --short
```

---

### Task 8: Add CLAUDE.md load-bearing-invariant entry

**Files:**
- Modify: `CLAUDE.md` (insert a new bullet in the `## Load-bearing invariants` section)

- [ ] **Step 1: Locate the invariants section**

Run:
```bash
grep -n '^## Load-bearing invariants' CLAUDE.md
```
Expected: a single hit. Inspect the existing bullets:
```bash
awk '/^## Load-bearing invariants/,/^## /{print NR": "$0}' CLAUDE.md | head -60
```

- [ ] **Step 2: Append a new bullet at the end of the load-bearing-invariants list**

Pattern-match the existing bullet style (each bullet starts with `**Short rule.**` then explanation). Add:

```markdown
- **`config.term='wezterm'` ↔ wezterm-terminfo install chain.** `chezmoi/dot_config/wezterm/wezterm.lua` sets `config.term = 'wezterm'` so every spawned PTY (local WSL, SSH-domain default_prog, manual `ssh`) gets `TERM=wezterm`. That entry MUST exist in `~/.terminfo/w/wezterm` on every host where a TUI eventually runs, or apps error with `Error opening terminal: wezterm`. The entry is installed by `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl`, which runs on `chezmoi apply` and tic-compiles `chezmoi/dot_local/share/wezterm/wezterm.terminfo` (vendored upstream, sha256sum-pinned in the script body to force re-run on bumps). Three artifacts move together — flipping `config.term` without the other two breaks TUIs on stale hosts. Verify per host: `infocmp wezterm` exits 0.
```

- [ ] **Step 3: Also add a `Files Claude should be careful with` entry for the vendored terminfo + script**

Run:
```bash
grep -n '^## Files Claude should be careful with' CLAUDE.md
```

Append (or insert at a natural position — the existing entries are sorted by topical relatedness, e.g. wezterm-related entries are grouped):

```markdown
- **`chezmoi/dot_local/share/wezterm/wezterm.terminfo`** — vendored from wezterm/wezterm upstream at a pinned release tag (recorded in the file's leading `#` comment). Editing this file by hand defeats the vendoring contract; bump by re-downloading from the upstream tag and committing. The pair `chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl` re-tic's it into `~/.terminfo/` on every `cza` when the content hash differs.
- **`chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl`** — Linux-only via the body `{{ if eq .chezmoi.os "linux" }}…{{ end }}` gate (`.chezmoiscripts/` are not in `.chezmoiignore`). Soft-fails with `exit 0` if `tic` or the source file are missing — `cza` is daily-workflow and shouldn't gain a new failure mode just from missing ncurses. The `tic -x` flag preserves `Tc`/`Smulx`/`Setulc`; dropping it silently degrades capability advertising.
```

- [ ] **Step 4: Add Quick verification entries**

Run:
```bash
grep -n '^## Quick verification' CLAUDE.md
```

Append two new bullet lines at the end of that section:

```markdown
- `infocmp wezterm | head -1` on every chezmoi-managed host after `cza` — confirms the terminfo entry was tic'd by `run_onchange_install-wezterm-terminfo.sh`. Should print `wezterm|Wez's terminal emulator,`.
- New WezTerm panes after phase-2 config reload — `echo $TERM` prints `wezterm`. Smooth-gradient awk one-liner renders without banding: `awk 'BEGIN{ for(c=0;c<256;c++){ printf "\033[38;2;%d;%d;%dm█",c,(c+85)%256,(c+170)%256 } print "\033[0m" }'`.
```

- [ ] **Step 5: Stage**

```bash
git add CLAUDE.md
git status --short
```

---

### Task 9: Update README.html for Phase 2

**Files:**
- Modify: `README.html` (extend the Phase-1 §appearance paragraph)

- [ ] **Step 1: Locate the Phase-1 §appearance paragraph**

Run:
```bash
grep -n 'Truecolor signaling' README.html
```

- [ ] **Step 2: Replace the existing paragraph with the extended version**

The phase-1 prose talked about `COLORTERM` + the vendored terminfo. Phase 2 also flips `config.term='wezterm'`, so the paragraph gets a second half. Replace the existing `<p><strong>Truecolor signaling.</strong>…</p>` (added in Task 4) with:

```html
<p>
  <strong>Truecolor signaling.</strong> Every chezmoi-managed shell exports
  <code>COLORTERM=truecolor</code> on startup (see <code>dot_zshrc.tmpl</code> /
  <code>dot_bashrc.tmpl</code>) and WezTerm advertises <code>TERM=wezterm</code>
  to every spawned PTY (<code>config.term</code> in <code>wezterm.lua</code>).
  Apps querying terminfo see <code>Tc</code>, <code>Smulx</code>, and
  <code>Setulc</code> — full 24-bit RGB plus extended underline capabilities —
  via the vendored <code>wezterm.terminfo</code> at
  <code>chezmoi/dot_local/share/wezterm/</code>, which a chezmoi
  <code>run_onchange</code> script compiles into <code>~/.terminfo/</code> on
  every apply. Verify with <code>infocmp wezterm</code> (exit 0; lists
  <code>Tc</code>, <code>setrgbf</code>, <code>Smulx</code>, <code>Setulc</code>)
  and <code>echo $TERM</code> in a new pane (prints <code>wezterm</code>).
</p>
```

- [ ] **Step 3: Render-check in a browser** — same as phase-1 task 4 step 5.

- [ ] **Step 4: Stage**

```bash
git add README.html
git status --short
```

---

### Task 10: Append a CLAUDE_CHANGELOG.md row for Phase 2

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Append the row**

Append at the bottom of the table (below the Phase-1 row added in Task 5):

```
| Phase 2 of WezTerm truecolor: added `config.term = 'wezterm'` to `chezmoi/dot_config/wezterm/wezterm.lua` (~3 lines including comment, below the existing `config.front_end = 'WebGpu'`). Every spawned PTY now advertises `TERM=wezterm` so apps query the wezterm terminfo entry installed in phase 1 and see `Tc` / `Smulx` / `Setulc` instead of the looser xterm-256color caps. Pre-req sanity-checked before merging: `infocmp wezterm` exits 0 on every host listed in `hosts.conf` + every WSL distro + the local dev_machine. Hosts without the entry error on first TUI launch — recover with `cza`. | **Yes** | The phase-1 §appearance paragraph ("Truecolor signaling") gains the second half describing the `TERM=wezterm` flip; verification recipe extends with `echo $TERM` (prints `wezterm` in a new pane) and the awk gradient one-liner. CLAUDE.md gains a new load-bearing-invariant entry ("`config.term='wezterm'` ↔ wezterm-terminfo install chain" — flipping `config.term` without the deployed terminfo breaks TUIs), two new `Files Claude should be careful with` entries (the vendored .terminfo file and the run_onchange script), and two new Quick verification lines (per-host `infocmp wezterm` and the post-reload `echo $TERM` + gradient render). |
```

- [ ] **Step 2: Stage**

```bash
git add CLAUDE_CHANGELOG.md
git status --short
```

---

### Task 11: Final phase-2 verification, commit, push

- [ ] **Step 1: Confirm the staged set**

```bash
git status --short
```
Expected (four lines):
```
M  CLAUDE.md
M  CLAUDE_CHANGELOG.md
M  README.html
M  chezmoi/dot_config/wezterm/wezterm.lua
```

- [ ] **Step 2: Re-verify phase-2 success criteria locally**

```bash
chezmoi apply -v 2>&1 | tail -5
# Open a NEW WezTerm tab (Ctrl+Shift+T or Ctrl+Shift+R to reload), then:
echo "$TERM"                                                                  # wezterm
awk 'BEGIN{ for(c=0;c<256;c++){ printf "\033[38;2;%d;%d;%dm█",c,(c+85)%256,(c+170)%256 } print "\033[0m" }'   # smooth gradient
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(wezterm): advertise TERM=wezterm so apps see the deployed terminfo

Adds config.term = 'wezterm' in chezmoi/dot_config/wezterm/wezterm.lua,
~3 lines including the comment. Every spawned PTY (local WSL, SSH-domain
default_prog, manual ssh) now sets TERM=wezterm; apps querying terminfo
see Tc / Smulx / Setulc — full 24-bit RGB plus extended underline caps —
instead of the looser xterm-256color entry.

Pre-req checked before merging: `infocmp wezterm` exits 0 on every host
in hosts.conf + every WSL distro + the local dev_machine. Hosts without
the entry error on first TUI launch (recover with `cza`).

Pairs with phase 1 (vendored wezterm.terminfo + run_onchange tic). The
three artifacts — vendored .terminfo source, tic'ing chezmoi script,
config.term flip — must move together; CLAUDE.md captures this as a
new load-bearing invariant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push**

```bash
git push
```

- [ ] **Step 5: Final cross-host verification (rollout window)**

For each host, after they pull the phase-2 change (`czu && cza`):
- The wezterm.lua change applies (Windows: read directly via `WEZTERM_CONFIG_FILE`; Linux dev_machine local: tracked under chezmoi but `wezterm.lua` is gated to Windows hosts in `.chezmoiignore.tmpl` per the repo invariant — so on Linux hosts there's nothing to apply).
- WezTerm picks up the new config on next reload / new tab.
- New panes report `TERM=wezterm`.

**Plan complete.**

---

## Self-Review (post-write)

**Spec coverage check.** Every section of the spec maps to at least one task:
- Goal / detection mechanism: Tasks 1-3 (vendoring + script + COLORTERM exports) cover both signal channels.
- Deploy scope (every chezmoi-managed host, no group gate): Task 2 script has no `.group` check; Task 6 fleet rollout uses `update-hosts.sh --group dev_machine` + `--group prod_machine` for both groups; Task 1 file path uses no `.chezmoiignore` gate.
- Rollout (phased, two PRs): Tasks 1-6 = phase 1 commit; Tasks 7-11 = phase 2 commit; rollout gate is Task 6 Step 6 ("every host reports OK before phase 2").
- Architecture components 1-9: Tasks 1, 2, 3, 4, 5, 7, 8, 9, 10 hit all nine.
- Data flow: covered implicitly by the verification steps in Task 6 Step 6 and Task 7 Steps 5-6.
- Failure modes: surfaced inline (Task 2 Step 6 troubleshooting, Task 7 Step 6 banding triage, soft-fail in the script body itself).
- Verification recipes: Task 6 Step 2, Task 7 Steps 5-6, Task 11 Step 2 — covers both phases' verification blocks from the spec.

**Placeholder scan.** Searched for "TBD", "TODO", "implement later", "fill in details", "Add appropriate", "handle edge cases", "Similar to Task N". One placeholder remains intentional: `<TAG>` in Tasks 1, 5, 6 — the WezTerm release tag is determined at execution time (Task 1 Step 1) and substituted everywhere. Documented inline.

**Type / name consistency.** Cross-checked: `config.term`, `COLORTERM`, `~/.terminfo/w/wezterm`, `wezterm.terminfo`, `run_onchange_install-wezterm-terminfo.sh.tmpl`, `tic -x -o`, `cza` / `czu` — all spelled identically across every task. No drift.

**One gap reconsidered.** Task 1 Step 5 prepends provenance comments to the vendored file. This means the sha256sum embedded in the chezmoi script is hashing the file *with* those leading comments — which is fine (the script is idempotent on hash); but if a future bump re-downloads from upstream and the tag in the comment header is updated, the sha256sum changes naturally and the run_onchange fires. Verified.
