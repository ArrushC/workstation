# WezTerm truecolor — design

**Status:** Approved
**Date:** 2026-05-26
**Owner:** Arrush Chaturvedi

## Goal

Make WezTerm advertise truecolor (24-bit RGB) capability to every TUI that runs in a WezTerm pane — local PowerShell, WSL, SSH-domain, and manual `ssh`. The renderer already handles 24-bit RGB; what's missing is the *signal* that tells apps to emit truecolor escape sequences instead of falling back to 256-color quantisation. Goal: richer colour schemes (Tokyo Night, helix highlighting, fzf previews, bat output, starship prompts) on every pane.

Non-goals: changing the active colour scheme, replacing the renderer (already `WebGpu`), or touching tool versions in `versions.mk`.

## Decisions

Captured before writing this spec, in order:

1. **Detection mechanism: both `COLORTERM` + wezterm terminfo.** `COLORTERM=truecolor` gives universal coverage across the user's toolchain (helix, zellij, starship, glow, eza, fzf, bat — all honor it). The wezterm terminfo entry advertises `Tc` plus `Smulx`/`Setulc` (undercurl, RGB underline color) that `xterm-256color` cannot. Belt and suspenders.
2. **Deploy scope: every chezmoi-managed host.** Both `dev_machine` and `prod_machine` groups + every WSL distro. Neither the vendored terminfo path (`dot_local/share/wezterm/wezterm.terminfo`) nor the script gets a dev-only entry added to `.chezmoiignore.tmpl`, so both groups receive them. The chezmoi script itself is OS-gated (Linux-only) via the standard `{{ if eq .chezmoi.os "linux" }}…{{ end }}` body wrapper, per the repo invariant that `.chezmoiscripts/` are not covered by `.chezmoiignore`.
3. **Rollout: phased, two PRs.** Phase 1 lands terminfo + `COLORTERM` and gives the user-visible win immediately. Phase 2 flips `config.term='wezterm'` once every host in the fleet has run `chezmoi update && chezmoi apply` and `infocmp wezterm` returns 0.

## Architecture

Five touchpoints across the two phases. All chezmoi-managed — no makefile, no `versions.mk`, no `bootstrap.sh`, no `hosts.conf` changes.

### Phase 1: ship terminfo + `COLORTERM`

1. **Vendor `wezterm.terminfo`** at `chezmoi/dot_local/share/wezterm/wezterm.terminfo` (deploys to `~/.local/share/wezterm/wezterm.terminfo`). Verbatim copy of the file at `https://raw.githubusercontent.com/wezterm/wezterm/<tag>/termwiz/data/wezterm.terminfo`, pinned to a specific WezTerm release tag chosen at vendoring time (writing-plans picks the tag — latest stable). Mode 0644 (chezmoi default). XDG-data path keeps it scoped to its tool.

2. **`chezmoi/.chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.tmpl`** (new). Linux-only via `{{ if eq .chezmoi.os "linux" }}…{{ end }}` body gate (`.chezmoiscripts/` is not in `.chezmoiignore`, so the gate goes in the body per the existing repo invariant). The script:
   - Embeds a `sha256sum` of the vendored terminfo as a comment — chezmoi diffs the script text per `run_onchange` semantics, so content changes to the source file mutate the comment and force a re-run.
   - Skips with a stderr warning + `exit 0` if either the source file or the `tic` binary is missing.
   - Compiles via `tic -x -o "$HOME/.terminfo" "$HOME/.local/share/wezterm/wezterm.terminfo" >/dev/null`. `-x` is load-bearing — without it, `Tc`/`Smulx`/`Setulc` get silently dropped. `-o "$HOME/.terminfo"` keeps the install user-scope (no sudo). ncurses's lookup order auto-finds `~/.terminfo/`.

   Sketch:
   ```bash
   {{ if eq .chezmoi.os "linux" -}}
   #!/usr/bin/env bash
   set -euo pipefail

   # Source hash — content changes here force this script to re-run:
   # {{ include (joinPath .chezmoi.sourceDir "dot_local/share/wezterm/wezterm.terminfo") | sha256sum }}

   SRC="$HOME/.local/share/wezterm/wezterm.terminfo"
   [ -f "$SRC" ]            || { echo "wezterm.terminfo missing at $SRC — skipping" >&2; exit 0; }
   command -v tic >/dev/null || { echo "tic (ncurses) not on PATH — skipping" >&2; exit 0; }
   tic -x -o "$HOME/.terminfo" "$SRC" >/dev/null
   {{ end -}}
   ```

3. **`chezmoi/dot_zshrc.tmpl`** — add `export COLORTERM=truecolor` next to the existing `EDITOR`/`VISUAL`/`PAGER` exports. One line.

4. **`chezmoi/dot_bashrc.tmpl`** — same line, same conceptual location, per the zsh-bash parity-pair invariant.

5. **`README.html` §appearance** — short paragraph: "WezTerm panes signal truecolor to apps via `COLORTERM=truecolor` (set in shells) and the vendored wezterm terminfo (compiled into `~/.terminfo/` on every chezmoi apply). Set automatically." Cross-reference: §troubleshooting gets a new row — "Colors look banded / 8-bit on host X" → "did `chezmoi apply` run? `infocmp wezterm` should exit 0."

6. **`CLAUDE_CHANGELOG.md`** — append a row for phase 1.

### Phase 2: flip `config.term`

7. **`chezmoi/dot_config/wezterm/wezterm.lua`** — add near the existing `config.front_end = 'WebGpu'` (around line 227):
   ```lua
   -- Advertise TERM=wezterm to spawned PTYs (local WSL + ssh). Unlocks Tc /
   -- Smulx / Setulc capability advertising in the wezterm terminfo entry
   -- deployed by .chezmoiscripts/run_onchange_install-wezterm-terminfo.sh.
   -- Pre-req: every target host must have the entry installed (run czu && cza).
   config.term = 'wezterm'
   ```

8. **`README.html`** + **`CLAUDE_CHANGELOG.md`** — second row for phase 2.

9. **New `CLAUDE.md` load-bearing-invariant entry** — under "Load-bearing invariants," a bullet documenting that `config.term='wezterm'` depends on the chezmoi-deployed terminfo. Cross-links the wezterm.lua line, the chezmoi script, and the verification recipe.

## Data flow

How the truecolor signal reaches a running TUI on each pane type post-phase-2:

- **Windows local (PowerShell) tab** — irrelevant; PowerShell ignores `$TERM`/`$COLORTERM`. WezTerm still renders any 24-bit sequences a program emits.
- **WSL tab** — wezterm spawns `wsl.exe`, propagating `TERM=wezterm` into the distro PTY. The chezmoi-managed `dot_zshrc.tmpl`/`dot_bashrc.tmpl` re-exports `COLORTERM=truecolor` on shell start. Apps see both. `infocmp wezterm` works inside WSL because chezmoi tic'd `~/.terminfo/w/wezterm` during `cza` inside that distro.
- **SSH-domain tab** — wezterm's `default_prog` is `zellij attach --create main`, but the local `ssh` process inherits `TERM=wezterm` from the pane env. OpenSSH hard-wires `TERM` propagation (unlike arbitrary env vars, which need `SendEnv`/`AcceptEnv`). Remote sshd's PTY ends up with `TERM=wezterm`; login shell starts and re-exports `COLORTERM=truecolor` from the chezmoi-managed rc.
- **Manual `ssh foo` from a local tab** — same as above, but `foo` must be chezmoi-managed (or have terminfo + rc exports otherwise) for the signals to land. Out of fleet → falls back to plain xterm-256color rendering (no error, just no truecolor advertising).

The **SSH AcceptEnv gotcha** is sidestepped: we don't try to forward `COLORTERM` over SSH at all. The remote shell re-sets it on startup.

## Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| `tic` missing on a host during `cza` | Script prints stderr warning, exits 0 (cza succeeds) | `dnf install ncurses` or `apt install ncurses-bin`, re-run `cza` |
| Phase 2 deployed but a host hasn't applied phase 1 | First TUI errors `Error opening terminal: wezterm` | `czu && cza` on that host; recoverable mid-session via `TERM=xterm-256color hx file` |
| Vendored terminfo drifts from upstream | No automatic detection | Re-vendor from upstream tag, commit; every host's next `cza` re-tic's it via the sha256sum-comment mechanism |
| User sets `TERMINFO` env var to a non-empty path | `~/.terminfo/` gets bypassed in ncurses lookup | Out of scope — surface in §troubleshooting if reported |
| ncurses too old to compile extended caps | `tic -x` warns, drops `Tc`/`Smulx`/`Setulc` from the binary | Degrades to plain xterm-256color-equivalent. Acceptable. |
| Phase 2 rollback needed | Comment out `config.term = 'wezterm'`, push, `cza` locally | One-line revert |

The script is `exit 0` on every soft failure deliberately — `cza` (`chezmoi apply` alias) is daily-workflow and must not gain a new failure mode just from a missing ncurses install.

## Verification

### Phase 1 (per host, after `cza`)
```bash
infocmp wezterm | head -3                        # exits 0
infocmp -1 wezterm | grep -E 'Tc|setrgbf|Smulx'  # extended caps present
echo "$COLORTERM"                                 # "truecolor" in any new shell
ls -la ~/.terminfo/w/wezterm                      # compiled binary exists
```

### Phase 2 (after merging the wezterm.lua flip + WezTerm `Ctrl+Shift+R`)
```bash
echo "$TERM"                                      # "wezterm" in any new pane
awk 'BEGIN{ for(c=0;c<256;c++){ printf "\033[38;2;%d;%d;%dm█",c,(c+85)%256,(c+170)%256 } print "\033[0m" }'
# Should render a smooth gradient with no banding
```

### CLAUDE.md "Quick verification" additions

Two new lines appended to the Quick verification section:

- `infocmp wezterm | head -1` on every managed host after `cza` — confirms the terminfo entry was tic'd. Should print `wezterm|Wez's terminal emulator,`.
- After phase 2 merge + WezTerm config reload, `echo $TERM` in any pane prints `wezterm`. A truecolor gradient (awk one-liner above) renders smooth, not banded.

## What does NOT change

- `bootstrap.sh` — still a thin seed.
- `makefile/Makefile`, `scope.mk`, `versions.mk`, `tools.mk` — no terminfo target (chezmoi-managed asset, not a tool install).
- `.chezmoiignore.tmpl` — no new entries (deploy applies to both groups).
- `hosts.conf`, `manage-hosts.{sh,ps1}` — untouched.
- WezTerm SSH-domains block, the 3-piece WSL invariant, the parity-pair invariants — all preserved.

## Rollout sequencing

1. Phase 1 PR merged → `czu && cza` on every host listed in `hosts.conf` (8 SSH targets) + every WSL distro + every dev_machine local. Approx 1 minute per host since the script just `tic`s a 3KB file.
2. Verify `infocmp wezterm` exits 0 on each.
3. Phase 2 PR merged → `czu && cza` locally (Windows WezTerm config gets the `config.term='wezterm'` flip via `WEZTERM_CONFIG_FILE`). Press `Ctrl+Shift+R` in WezTerm to reload. New panes inherit `TERM=wezterm`.

If a host gets missed between phase 1 and phase 2, the first TUI on that host fails clearly with `Error opening terminal: wezterm`; running `cza` fixes it.
