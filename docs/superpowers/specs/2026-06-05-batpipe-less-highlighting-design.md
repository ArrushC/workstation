# Design: bat-highlighted `less` via `batpipe`

- **Date:** 2026-06-05
- **Status:** Approved (ready for implementation plan)
- **Scope:** dev_machine + prod_machine (Linux/macOS shells); Windows excluded

## Summary

Wire **batpipe** (from `eth-p/bat-extras`) as the `less` input preprocessor
(`LESSOPEN`) so that `less <file>` is syntax-highlighted by `bat`, and common
container formats (directories, `tar`/`tar.gz`, `zip`/`jar`, `gz`, `xz`) get a
readable preview. The script is vendored into chezmoi (single self-contained
file) and activated from both `dot_zshrc.tmpl` and `dot_bashrc.tmpl` via the
repo's existing `eval "$(tool init)"` idiom, guarded on `bat` + `batpipe`
presence.

## Context & findings

These shaped the design and are worth recording because several are
counter-intuitive:

1. **lesspipe is already installed and wired on the RHEL hosts — by the base OS,
   not this repo.** `/usr/bin/lesspipe.sh` ships with the `less` package itself
   (`less-590-6.el9`), and `/etc/profile.d/less.sh` already exports
   `LESSOPEN="||/usr/bin/lesspipe.sh %s"` on every login shell. So
   decompression/archive previews in `less` already work with zero config.
2. **The shipped lesspipe is the basic Red Hat version** — it has **no**
   integration with `bat`/`source-highlight`. The one thing missing is **syntax
   highlighting of source files in `less`**. That gap is the entire scope of
   this change.
3. **batpipe is NOT part of `sharkdp/bat`.** Verified: it is absent from the
   `v0.26.1` source tree *and* the release tarball, and unmentioned in bat's
   README. batpipe lives in the separate **`eth-p/bat-extras`** project, whose
   releases ship pre-built standalone scripts.
4. **`bat` currently uses `less` as its pager** (`PAGER=less`, `BAT_PAGER`
   unset) and manages the flags itself (auto-adds `-R`/`-F` on `less` >= 530;
   host is `less 590`). No `bat` config is tracked by the repo, so `bat` runs on
   built-in defaults. The only existing bat rc wiring is the `MANPAGER` block
   and the yazi `y` preview.
5. **`bat` does not auto-color in this path.** When `less` calls batpipe,
   batpipe runs `bat` with output going into a **pipe** (to `less`), not a TTY,
   so `bat`'s `--color=auto` would turn color **off**. batpipe forces the
   decision explicitly (`--color=always|never`) and, *inside `less`*, defaults
   to `never` unless `BATPIPE=color` is set. Hence `BATPIPE=color` is **required**
   to get highlighting — it is not redundant with bat's auto-color.

## Decision

- Vendor the pre-built standalone `batpipe` from `eth-p/bat-extras` release
  **`v2024.08.24`** and deploy it to `~/.local/bin/batpipe` via chezmoi.
- Activate it in both shells with `eval "$(batpipe)"`, guarded by
  `command -v batpipe && command -v bat`.
- **Replace** the system lesspipe as the `LESSOPEN` handler (no chaining/fallback
  logic). The system lesspipe stays installed and untouched; it auto-reactivates
  on any host where the guard fails (no bat/batpipe). Chaining the two formats
  is explicitly out of scope for now (YAGNI).
- Keep **`BATPIPE=color` on by default** (highlighting inside `less`).

## Design details

### 1. Vendored script + provenance sidecar

- `chezmoi/dot_local/bin/executable_batpipe` — the upstream `bin/batpipe`
  verbatim (773-line self-contained bash; the build bundles its `bat-modules`
  lib inline, so no companion files are needed). LF line endings. The
  `executable_` prefix makes chezmoi deploy it mode `0755` to
  `~/.local/bin/batpipe` (already first on `$PATH`).
- `chezmoi/dot_local/bin/.vendor` — provenance sidecar (leading dot ->
  chezmoi-ignored, never deployed), matching the existing `.vendor` format used
  by the zsh plugins:
  - upstream: `https://github.com/eth-p/bat-extras`
  - release: `v2024.08.24`
  - asset: `https://github.com/eth-p/bat-extras/releases/download/v2024.08.24/bat-extras-2024.08.24.zip`
  - asset-sha256: `d79c085b9d0af7f56c3f69d766a83fe26405faac999c4ed7cdfc27417d2c736f`
  - file-sha256 (`bin/batpipe`): `fe085dc3f83f3e97b541210375b5cef46e3abc35e220175290e2a280e8ff8f27`
  - license: MIT
  - bump procedure: re-download the release zip, replace
    `executable_batpipe` with `bin/batpipe`, refresh release tag + both
    sha256s here.
- **No `versions.mk` entry.** Like the vendored zsh plugins, the version pin
  lives in `.vendor`; batpipe is chezmoi-deployed, not make-installed, and is
  not coupled to `BAT_VERSION` (it works with any recent `bat`).

### 2. Shell wiring (zsh + bash parity)

Inserted in **both** `dot_zshrc.tmpl` and `dot_bashrc.tmpl`, immediately after
the existing `PAGER`/`MANPAGER` block (zshrc ~51-58, bashrc same), identical in
both files:

```sh
# bat-highlighted `less`: batpipe (eth-p/bat-extras) as the LESSOPEN preprocessor.
# `eval "$(batpipe)"` sets LESSOPEN->batpipe, appends -R to LESS, and sets
# BATPIPE=color so source files are syntax-highlighted and dirs/tar/zip/gz/xz
# get a readable preview in `less`. Guarded so a host without bat/batpipe falls
# back to the system /usr/bin/lesspipe.sh (left installed, untouched).
if command -v batpipe &>/dev/null && command -v bat &>/dev/null; then
  eval "$(batpipe)"
fi
```

`eval "$(batpipe)"` emits exactly (POSIX, so zsh evals it fine):

```sh
LESSOPEN="|/home/<user>/.local/bin/batpipe %s";
export LESSOPEN;
unset LESSCLOSE;
LESS="$LESS -R";
BATPIPE="color";
export LESS;
export BATPIPE;
```

This matches the repo's established `eval "$(fzf --zsh)"` / `atuin init` /
`zoxide init` / `starship init` pattern, so startup cost is consistent with
existing inits.

### 3. Why `BATPIPE=color` is required (mechanism)

batpipe always passes an explicit `--color` flag to `bat` (never `auto`), and
inside `less` defaults to `--color=never` unless `BATPIPE=color`
(`batpipe:667-707`). Because `bat`'s output here is piped into `less` (not a
TTY), without the override there would be **no** highlighting. batpipe's own
setup also appends `-R` to `LESS` so the forced color renders instead of showing
as raw escape codes.

### 4. `bat` interaction — no conflict, no recursion

- Setting `LESS=-R` does not disturb `bat`: `bat` chooses its `less` flags from
  `BAT_PAGER`/`--pager` (untouched), not from the `LESS` env var, and `-R` is
  what `bat` already wants.
- `bat <file>` -> `less` is never reprocessed by batpipe: `bat` highlights the
  file itself and pipes the result into `less` over **stdin**, and `LESSOPEN`
  preprocessors fire only on *named file arguments*, never on piped stdin.
  (Belt-and-suspenders: batpipe self-detects `BATPIPE_INSIDE_BAT` and no-ops.)
- `man` is unaffected: `MANPAGER` replaces the pager outright, independent of
  `LESSOPEN`.

### 5. Trade-off (accepted)

Pointing `LESSOPEN` at batpipe means bare `less <file>` is handled by batpipe
instead of the system lesspipe. **Gained:** `bat` syntax highlighting +
directory/`tar`/`zip`/`gz`/`xz` previews. **Lost:** the base lesspipe's broader
but rarely-used handlers (pdf->text, rpm/deb listing, image metadata). For a dev
shell, highlighting is the bigger win. The system lesspipe is left installed and
untouched, and remains the automatic fallback on any host without bat/batpipe.

### 6. Scope & platform

- **Both dev and prod**, no `MODE` gating: `bat` is installed on both, and a
  chezmoi `$HOME` file deploys everywhere. Runtime deps are satisfied
  (`tar`/`gzip`/`xz` base; `unzip` in core packages; `eza` with `ls` fallback).
- **Windows:** add `dot_local/bin` to the existing Windows block in
  `chezmoi/.chezmoiignore.tmpl` (line ~14) so the bash script is not deposited
  in `%USERPROFILE%`.

## Files changed

| File | Change |
|---|---|
| `chezmoi/dot_local/bin/executable_batpipe` | **new** — vendored standalone batpipe (verbatim, LF, 0755 via prefix) |
| `chezmoi/dot_local/bin/.vendor` | **new** — provenance sidecar |
| `chezmoi/dot_zshrc.tmpl` | add guarded `eval "$(batpipe)"` block after MANPAGER |
| `chezmoi/dot_bashrc.tmpl` | same block (parity) |
| `chezmoi/.chezmoiignore.tmpl` | ignore `dot_local/bin` on Windows |
| `README.html` | document highlighted/preview `less` in the shell/daily section |
| `CLAUDE_CHANGELOG.md` | append a row for this user-facing change |
| `docs/claude/file-care.md` | add batpipe to the vendored-files list |
| `CLAUDE.md` | one line in the vendored-files tripwire |

## Invariants / tripwires touched

- **Parity pair** `dot_zshrc.tmpl` <-> `dot_bashrc.tmpl` — identical block in
  both, same commit.
- **New vendored file** — don't hand-edit; bump via the `.vendor` procedure.
- **LF + executable** — `executable_batpipe` must be LF (not CRLF); chezmoi
  handles the deployed mode via the `executable_` prefix.
- **New soft version pin** — batpipe release tag lives only in `.vendor`
  (no `versions.mk` bridge).
- **User-facing change** — README + CLAUDE_CHANGELOG update required per
  CLAUDE.md.

## Non-goals (YAGNI)

- No chaining/fallback to the system lesspipe for formats batpipe lacks.
- No `versions.mk` / Makefile entry (vendored, not make-installed).
- No change to `MANPAGER`, `BAT_PAGER`, or any `bat` config.
- No external batpipe viewers (`~/.config/batpipe/viewers.d/`).

## Verification

After `chezmoi apply` (or `cza`) on this host:

1. `file chezmoi/dot_local/bin/executable_batpipe` — must **not** report "CRLF".
2. `command -v batpipe` -> `~/.local/bin/batpipe`; `ls -l` shows it executable.
3. `echo "$LESSOPEN"` -> `|/home/<user>/.local/bin/batpipe %s`;
   `echo "$BATPIPE"` -> `color`; `echo "$LESS"` contains `-R`.
4. `less <some-source-file>` -> syntax-highlighted.
5. `less some.tar.gz`, `less some.gz`, `less <a-directory>` -> readable preview.
6. `bat <file>` still works (unchanged); `man <cmd>` still bat-colored.
7. Unset/guard check: in a shell where `batpipe` is not on `PATH`, confirm the
   block is skipped and the system lesspipe `LESSOPEN` remains.
