# Design: add `nnn`, `fx`, `gitlogue` to the toolset

- **Date:** 2026-06-08
- **Status:** Implemented (commits in `feat(tools)` + `feat(shell)`); see as-built deltas below.
- **Scope:** dev_machine + prod_machine (Linux). No `MODE` gating — universal, like yazi/lnav/fzf.

> **As-built deltas (this spec describes the original design; three things changed during implementation):**
> 1. **nnn is installed via `TOOL` + `archive.sh`, not `EGET_TOOL`.** The musl-static tarball's internal binary is named `nnn-musl-static` (not `nnn`), and eget preserves archive-internal names (its repo-name rename only applies to *raw-binary* assets like fx). So `archive.sh` gained a backward-compatible `src=dst` rename spec, and nnn registers as `TOOL,nnn,…,$(LIB)/archive.sh nnn-musl-static=nnn <url>`.
> 2. **The wrapper is named `nn()`, not `n()`.** `n()` was already a pre-existing `nb` quick-note shortcut in both shells; `nn` was chosen to avoid clobbering it.
> 3. **`NNN_TMPFILE` is scoped to the call, not exported.** The body uses `NNN_TMPFILE="$tmp" command nnn "$@"` (prefix assignment, no shell-env leak) and `[[ -s "$tmp" ]]` (source only if non-empty) instead of the `export …` / `-f` shown in §Design details below.

## Summary

Add three single-binary CLI tools to the make-driven toolbelt:

- **nnn** (`jarun/nnn`) — fast ncurses terminal file manager. Installed binary
  **plus** a shell `n()` cd-on-quit wrapper (parity pair, mirroring yazi's `y()`).
- **fx** (`antonmedv/fx`) — interactive terminal JSON viewer (the one niche not
  already covered by `jq`/`yq`, which are non-interactive). Binary only.
- **gitlogue** (`unhappychoice/gitlogue`) — cinematic Git commit-replay tool.
  Binary only.

All three register through the repo's preferred `EGET_TOOL` macro, so they join
`SCOPE_TOOLS` and install on **both** dev and prod (the only per-MODE difference
is `DEST`/`$(SUDO)`, identical to every other tool). Version pins live in
`versions.mk`. The change is user-facing, so `README.html` and
`CLAUDE_CHANGELOG.md` are updated in the same commit.

## Context & findings

Release-asset shapes (from the GitHub releases API) drove the macro choices:

1. **fx** — latest tag **`39.2.0`** (non-`v`, like television). Assets are **raw
   binaries**, not archives: `fx_linux_amd64`, `fx_linux_arm64`,
   `fx_darwin_amd64`, `fx_windows_amd64.exe`. eget auto-detects linux/amd64. The
   non-`v` tag must be passed explicitly as the 4th macro arg (television
   precedent), else the macro would request `v39.2.0` and 404.
2. **gitlogue** — latest tag **`v0.9.0`**. Single linux asset
   `gitlogue-v0.9.0-x86_64-unknown-linux-gnu.tar.gz`. **gnu-glibc only — no musl
   build.** Acceptable: the fleet is glibc (WSL/RHEL). It is the only tool here
   that can't go musl; worth a one-line note. No `--asset` filter needed (one
   linux x86_64 asset). Tag defaults to `v0.9.0`.
3. **nnn** — latest tag **`v5.2`**. Six linux x86_64 tarballs (plain / emoji /
   icons / nerd, each × musl). We want the plain musl static build:
   `nnn-musl-static-5.2.x86_64.tar.gz`. The eget disambiguator **`--asset
   musl-static`** uniquely selects it — the emoji variant is
   `nnn-musl-emoji-static-…`, so the contiguous substring `musl-static` does not
   collide. Tag defaults to `v5.2`. Binary inside the tarball is `nnn`.
4. **All three install on both machine types.** `EGET_TOOL` appends to
   `SCOPE_TOOLS` (`Makefile:61`); `tools: $(SCOPE_TOOLS)` is a dep of `provision`
   unconditionally. Only the bespoke extras
   (`claude-cli`/`node-runtime`/`nerd-fonts`/`dozzle-service`/`cockpit-service`)
   are `ifeq ($(MODE),dev)`-gated. Nothing in the normal macro list is gated.
5. **`n`, `fx`, `nnn`, `gitlogue` are all free names** on this host
   (`command -v` returned not-installed for each); no alias/function collision.
6. **nnn cd-on-quit needs a shell wrapper.** nnn writes the exit directory to the
   file named by the exported `NNN_TMPFILE`; the wrapper sources it after nnn
   exits. This is the established pattern the repo already uses for yazi (`y()`),
   so `n()` mirrors it.

## Decision

- Register all three via `EGET_TOOL` in `makefile/tools.mk`; pin versions in
  `makefile/versions.mk`.
- nnn gets `--asset musl-static`; fx passes its non-`v` tag explicitly; gitlogue
  takes macro defaults.
- Add an `n()` cd-on-quit wrapper to **both** `dot_zshrc.tmpl` and
  `dot_bashrc.tmpl`, modeled on the existing `y()`. fx and gitlogue get no shell
  wiring (plain commands).
- Universal scope (no `MODE` gating), matching yazi/lnav.
- Update `README.html` (tool listing + the `n` helper alongside `y`) and append a
  `CLAUDE_CHANGELOG.md` row.

## Design details

### 1. `makefile/versions.mk`

New dated section (matching the existing "second-wave"/"gap-fillers" comment
style):

```make
# --- (2026-06) interactive explorers + git replay ---------------------------
NNN_VERSION      := 5.2
FX_VERSION       := 39.2.0
GITLOGUE_VERSION := 0.9.0
```

### 2. `makefile/tools.mk`

Three `EGET_TOOL` registrations (placed with the other static-binary tools):

```make
# nnn — six linux variants in the release; `--asset musl-static` uniquely picks
# the plain musl static build (the emoji one is `musl-emoji-static`, so the
# substring can't collide). Binary inside the tarball is `nnn`.
$(eval $(call EGET_TOOL,nnn,$(NNN_VERSION),jarun/nnn,,--asset musl-static))

# fx — interactive JSON viewer. Non-`v` tag (like television), so pass it as the
# explicit 4th arg. Assets are raw binaries; eget auto-detects linux/amd64.
$(eval $(call EGET_TOOL,fx,$(FX_VERSION),antonmedv/fx,$(FX_VERSION)))

# gitlogue — cinematic git-log replay. Single linux asset (gnu-glibc only; no
# musl build), so no --asset filter. Tag defaults to v$(GITLOGUE_VERSION).
$(eval $(call EGET_TOOL,gitlogue,$(GITLOGUE_VERSION),unhappychoice/gitlogue))
```

### 3. Shell wiring — `n()` cd-on-quit wrapper (zsh + bash parity)

Added to **both** `dot_zshrc.tmpl` and `dot_bashrc.tmpl`, immediately after the
existing yazi `y()` block, identical in both files:

```sh
# nnn file manager — `n` opens it; on quit, cd to wherever you ended up.
n() {
  local tmp
  tmp="$(mktemp -t nnn-cwd.XXXXXX)"
  export NNN_TMPFILE="$tmp"
  command nnn "$@"
  [[ -f "$tmp" ]] && source "$tmp"
  command rm -f -- "$tmp"
}
```

Mechanism: nnn writes a `cd '<dir>'` line to `$NNN_TMPFILE` on quit (because the
var is exported); sourcing it performs the cd. `command nnn` prevents infinite
recursion if a user later aliases `nnn`→`n`. `mktemp` matches the repo's `y()`
idiom rather than nnn's default fixed `~/.config/nnn/.lastd` path.

fx and gitlogue: **no wiring** — invoked directly as `fx <file>` /
`gitlogue [path]`.

### 4. Docs

- **`README.html`** — add nnn / fx / gitlogue to the tool listing (where
  yazi/lnav/television are enumerated) and document the `n` helper next to `y` in
  the shell/daily section.
- **`CLAUDE_CHANGELOG.md`** — append one row for this user-facing change.

### 5. Scope & platform

- **Both dev and prod**, no `MODE` gating (universal macro list). Install
  location differs only by scope (`/usr/local/bin` + sudo on dev; `~/.local/bin`
  on prod).
- **Windows:** unaffected. These are Linux make-installed tools; Windows installs
  are the separate `bootstrap.ps1` portable set. The `n()` wrapper lives in the
  bash/zsh rc, which Windows does not deploy.

## Files changed

| File | Change |
|---|---|
| `makefile/versions.mk` | **new section** — `NNN_VERSION`, `FX_VERSION`, `GITLOGUE_VERSION` |
| `makefile/tools.mk` | three `EGET_TOOL` registrations |
| `chezmoi/dot_zshrc.tmpl` | add `n()` cd-on-quit wrapper after `y()` |
| `chezmoi/dot_bashrc.tmpl` | same block (parity) |
| `README.html` | tool listing + `n` helper documented |
| `CLAUDE_CHANGELOG.md` | append a row |

## Invariants / tripwires touched

- **Parity pair** `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` — identical `n()` block in
  both, same commit.
- **Tool versions only in `versions.mk`** — no version literals in tools.mk /
  scripts / bootstrap.
- **`EGET_TOOL` is the preferred macro** for single-binary GitHub releases —
  no per-tool install logic introduced anywhere else.
- **Non-`v` tag handling** for fx (explicit 4th arg) — same precedent as
  television.
- **User-facing change** — README + CLAUDE_CHANGELOG update required per
  CLAUDE.md.
- **No CRLF/BOM/mode concerns** — only `.mk`, `.tmpl`, `.html`, `.md` touched
  (no `lib/*.sh`, `scripts/*`, or `.ps1`).

## Non-goals (YAGNI)

- No fx/gitlogue shell wiring, aliases, or keybindings.
- No nnn plugins, config (`NNN_OPTS`, `NNN_PLUG`, bookmarks), or `nnn-static`
  emoji/icon/nerd variants — plain musl static only.
- No musl fallback engineering for gitlogue (gnu-only is accepted on a glibc
  fleet).
- No Windows install of any of the three.
- No replacement/retirement of existing tools (yazi/broot/jq/yq stay).

## Verification (on this host)

1. `make nnn fx gitlogue` (host's normal MODE/scope) completes without prompting.
2. `command -v nnn fx gitlogue` — all three resolve under `$DEST`.
3. **fx name check:** the installed binary is `fx`, **not** `fx_linux_amd64`
   (the one real uncertainty, since fx ships a raw binary; if eget keeps the
   asset name, add a rename/`--to` flag and re-test).
4. Smoke tests: `nnn -V`, `echo '{"a":1}' | fx .a` (or `fx --help`),
   `gitlogue --version`.
5. `chezmoi diff` shows the `n()` block in both rc files and renders cleanly;
   after apply, `type n` reports the function and a `cd`-on-quit round-trip works.
6. Re-run `make nnn fx gitlogue` → all report up-to-date (stamp idempotency).
