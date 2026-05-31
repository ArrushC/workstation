# Doc & build tooling: man / info / pkg-config / tldr — design

**Date:** 2026-05-31
**Repo:** workstation (chezmoi + Make)
**Status:** approved, pre-implementation

## Problem

An audit asked whether four things are (a) installed by the repo's install
scripts, (b) tracked/configured by chezmoi, and (c) configured optimally:
`man` pages, `info`, `pkg-config`, and `tldr`.

Findings on the live AlmaLinux 9.7 host + repo inspection:

| Item | In install scripts? | chezmoi config? | Optimal? |
|---|---|---|---|
| **tldr** (tealdeer) | yes — `tools.mk:211`, pinned `TEALDEER_VERSION` | **no** | **no — broken OOTB** (empty cache, no auto-update) |
| **man pages** | no (present only transitively) | `MANPAGER="less"` only | suboptimal — `bat` installed but unused |
| **info** | no (`info` pkg present transitively) | no | reader present by luck only |
| **pkg-config** | no (present transitively) | n/a (build tool) | not guaranteed on minimal hosts |

Only `tldr` is actually managed, and it errors on first use
(`Page cache not found. Please run tldr --update`). The other three exist on
the dev WSL host only as transitive dependencies; nothing in `packages.mk`
guarantees them on a fresh/minimal prod host.

Verified facts that shaped the design:
- With `[updates] auto_update = true`, tealdeer **auto-downloads the cache on
  the first `tldr <cmd>` call when it is missing** (tested in an isolated
  `TEALDEER_CONFIG_DIR`: 7,232 pages fetched in ~1s). So config alone makes
  `tldr` self-heal; a seed step only removes first-use latency.
- EL9 package naming (verified resolvable via `dnf list`):
  - `texinfo` is **NOT** in base repos (CRB only) and is not needed to *read*
    info docs — the reader `/usr/bin/info` is owned by the **`info`** package.
  - the literal `pkg-config` package is **obsoleted** → `NOT FOUND`; the
    correct package is **`pkgconf-pkg-config`** (provides `/usr/bin/pkg-config`).
- In `bootstrap.sh` the order is `make provision` (step 4, installs `tldr`)
  **before** chezmoi `init --apply` (step 4b). So `tldr` is on PATH by the time
  any `.chezmoiscripts/` run-script fires — a seed script will not no-op for
  lack of the binary in the normal flow.

## Goals / non-goals

**Goals**
- Guarantee `man`, the `info` reader, and `pkg-config` are installed by the
  repo (not left to transitive luck), using correct EL9 package names.
- Make `tldr` work out of the box on a freshly provisioned host, and stay
  fresh thereafter, with config tracked by chezmoi.
- Use `bat` (already a tier-1 tool) as the man pager for colorized man pages,
  with a safe fallback.
- Respect all load-bearing invariants: shell-rc parity pair, chezmoi naming,
  `.chezmoiscripts/` body-gating + soft-fail, README/CHANGELOG sync.

**Non-goals**
- No `texinfo`/`makeinfo` authoring toolchain (out of scope; not in base repos).
- No apt/Debian package path (repo is RHEL-only today; documented branch point).
- No changes to the `TOOL`/`EGET_TOOL` macros.
- No tealdeer cache seeding in the makefile (ownership/scope mismatch — see
  "Rejected alternatives").

## Design

### 1. `makefile/packages.mk`

- **Core** (`LINUX_PACKAGES`, no `|| true`, must resolve): add
  `pkgconf-pkg-config`. It completes the build toolchain alongside the existing
  `gcc` / `make` / `openssl-devel` (C-extension pip builds), and is guaranteed
  resolvable on the only supported distro (EL9). Add a short comment noting EL9
  obsoletes the literal `pkg-config` in favor of `pkgconf-pkg-config`.
- **Optional** (`LINUX_OPTIONAL_PACKAGES`, per-package `|| true`): add
  `man-db man-pages info`.
  - `man-db` — the `man`/`mandb`/`apropos`/`whatis` binaries.
  - `man-pages` — base Linux man pages (syscalls / libc / conceptual).
  - `info` — the GNU info reader (`/usr/bin/info`). **Not** `texinfo`.

  These are documentation niceties, matching the existing optional tier
  (which already holds `vim-enhanced`, `htop`, etc.).

### 2. `MANPAGER` → bat (parity pair)

In **both** `chezmoi/dot_zshrc.tmpl` and `chezmoi/dot_bashrc.tmpl`, replace the
single line `export MANPAGER="less"` (line 41) with a guarded block:

```sh
if command -v bat &>/dev/null; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT="-c"
else
  export MANPAGER="less"
fi
```

- `col -bx` (from `util-linux`, always present) strips backspace overstrike;
  `bat -l man -p` highlights using the `man` syntax in plain mode.
- `MANROFFOPT="-c"` avoids groff output glitches under the bat pipe.
- The `command -v bat` guard preserves a `less` fallback if `bat` is ever
  absent (matches the existing `dircolors` guard style).
- **Parity invariant:** identical text in both files, same commit. The block is
  shell-syntax-neutral (works in zsh and bash).

### 3. tealdeer — config + run_once seed (Approach B)

Both files deploy in **dev and prod** (tldr is a scope-tool installed in both);
neither sits behind the `.chezmoiignore.tmpl` dev gate.

**New `chezmoi/dot_config/tealdeer/config.toml`** (static, no `.tmpl`, mode 0644
→ `~/.config/tealdeer/config.toml`):

```toml
# Tealdeer (tldr client) configuration — managed by chezmoi.
# auto_update keeps the page cache fresh; the initial cache is seeded by
# .chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl on first apply.
[updates]
auto_update = true
auto_update_interval_hours = 720   # refresh at most once per 30 days
```

This is the freshness safety net: even if the seed step is skipped, the first
`tldr` call downloads the cache.

**New `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl`** — seeds the
cache once so first use is instant and works offline-after-apply:

```sh
{{ if eq .chezmoi.os "linux" -}}
#!/usr/bin/env bash
# run_once_seed-tldr-cache.sh — populate the tealdeer (tldr) page cache once,
# so `tldr <cmd>` works immediately on a freshly provisioned host instead of
# erroring with "Page cache not found". Ongoing freshness is handled by
# auto_update in ~/.config/tealdeer/config.toml.
#
# .tmpl gate: linux only (.chezmoiscripts/ are NOT covered by .chezmoiignore,
# so the gate lives in the body; non-linux renders empty -> chezmoi skips it).
# Soft-fail: `cza` is daily-workflow; a missing tldr or a network blip must not
# turn `chezmoi apply` into a failure. auto_update is the backstop either way.
set -euo pipefail

if ! command -v tldr >/dev/null 2>&1; then
  printf 'tldr not on PATH — skipping tealdeer cache seed\n' >&2
  exit 0
fi
if [ -d "$HOME/.cache/tealdeer/tldr-pages" ]; then
  exit 0   # already seeded; auto_update owns refresh from here
fi
tldr --update >/dev/null 2>&1 \
  || printf 'tldr --update failed (offline?) — auto_update will retry on first use\n' >&2
{{- end }}
```

- `run_once` semantics: runs a single time per machine (keyed by rendered
  content hash); re-runs only if the script text later changes. The
  `[ -d ... ]` guard makes any such re-run a no-op once seeded.
- File must be **LF-only**. No executable bit needed (chezmoi invokes scripts).

### 4. Documentation

- **`CLAUDE.md`**
  - Add two "Files Claude should be careful with" entries:
    - `chezmoi/dot_config/tealdeer/config.toml` — auto_update is the freshness
      mechanism; deploys both scopes; static (no `.tmpl`).
    - `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` — Linux-gated
      body, soft-fail, depends on the `tldr` binary already being installed
      (true in the bootstrap order), backstopped by auto_update.
  - Add verification recipes (see below).
- **`README.html` + `CLAUDE_CHANGELOG.md`** — during implementation, check
  whether README's tool list / troubleshooting sections reference man/tldr; if
  so, update in the same commit and append a `CLAUDE_CHANGELOG.md` row. The
  package additions and MANPAGER change are largely transparent, so the README
  touch may be minimal or unnecessary; decide by the "could a user still
  operate the repo?" test.

## Rejected alternatives

- **tldr config-only (Approach A):** ship just `config.toml`, rely on
  auto_update. Functionally sufficient (verified), but leaves a first-use
  download delay and needs network at that moment. Rejected in favor of B,
  which adds an instant-first-use seed on top of the same safety net at the
  cost of one small, precedented chezmoi script.
- **tldr cache seed in the makefile (Approach C):** the dev-scope `TOOL` macro
  installs the binary as root via `$(SUDO)`, but the cache must populate the
  *invoking user's* `~/.cache`; threading that through the macro breaks its
  uniformity and puts user-home state in the provisioning layer that chezmoi
  should own. Rejected.
- **`texinfo` package:** not in EL9 base repos and unneeded for reading info
  docs. Rejected in favor of the `info` package (the reader).
- **literal `pkg-config` package:** obsoleted on EL9. Rejected in favor of
  `pkgconf-pkg-config`.

## Verification plan

- `cd makefile && make list MODE=dev` — still lists all managed tools.
- `cd makefile && make -n MODE=dev provision` — shows the new packages
  (`pkgconf-pkg-config` in core; `man-db man-pages info` in optional).
- `cd makefile && make -n MODE=prod provision` — packages still skipped
  (MODE=prod no-op message), tool installs unaffected.
- `file chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` — must NOT
  report CRLF. Same for the two edited rc files.
- `zsh -n chezmoi/dot_zshrc.tmpl`-equivalent / `bash -n` parse check on the
  rendered rc bodies (template-stripped) — clean parse; MANPAGER block present
  and identical in both files.
- `chezmoi diff` on a host — shows only: new `dot_config/tealdeer/config.toml`,
  new `.chezmoiscripts/run_once_seed-tldr-cache.sh`, and the two rc edits.
- Sandbox tealdeer check (isolated config/cache dir): `tldr tar | head -1`
  succeeds after a seed/auto_update.
- After `cza` on a real host: `tldr tar | head -1` works; `man ls` renders
  colorized (bat). `command -v pkg-config && pkg-config --version` succeeds.

## Files touched

- `makefile/packages.mk` (core + optional package lists)
- `chezmoi/dot_zshrc.tmpl` (MANPAGER block)
- `chezmoi/dot_bashrc.tmpl` (MANPAGER block — parity)
- `chezmoi/dot_config/tealdeer/config.toml` (new)
- `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` (new)
- `CLAUDE.md` (careful-with entries + verification recipes)
- `README.html` + `CLAUDE_CHANGELOG.md` (conditional, per the user-facing test)
