---
name: project-mise-everything
description: PR1/3 of the Make→mise migration shipped (2026-09-17) — every tool is a mise pin in config*.toml at the repo root, which IS mise's global config dir now; env-token scheme, asset rulings, python declared, per-file locks, mise config set's comment-eating bug
metadata:
  type: project
---

PR1 of the Make→mise migration (spec `docs/superpowers/specs/2026-09-16-mise-everything-design.md`) is merged. Every tool that used to be a `tools.mk` macro (`EGET_TOOL`/`TOOL`/`USER_TOOL`) is now a mise pin. `makefile/`, chezmoi, and the non-tool Make targets (packages, dotfiles handoff, bespoke targets like `vcpkg`/`nerd-fonts`/`python-env`/`docker-engine`) stay for PR2/PR3 — this PR is the tool layer only.

**The repo root IS mise's global config dir.** Linux: `~/.config/mise` (relocated from the old `~/.local/share/chezmoi` by `bootstrap.sh`, one-time, moving a pre-existing `~/.config/mise` aside as `*.pre-relocation.<timestamp>` and writing `sourceDir` into chezmoi's own config so `cza`/`czd`/… keep working). Windows: `%USERPROFILE%\.config\mise`, same relocation dance in `bootstrap.ps1`. No symlink, no indirection — mise reads `config*.toml` straight off the checkout.

**Env token table** (`MISE_ENV`, computed by `scripts/lib/mise-env.sh <dev|prod>` on Linux, a literal on Windows; exported by the rc files / a Windows User var):

| Host | `MISE_ENV` |
|---|---|
| prod (any Linux) | `linux` |
| dev, WSL guest | `linux,dev,host,wsl` |
| dev, bare metal / VM | `linux,dev,host,native` |
| Windows dev | `windows,dev` |

Config files load by token: `config.toml` always (cross-platform: `uv`, `python`); `config.linux.toml` when `linux` is in the set (the Linux toolbelt, both scopes); `config.dev.toml` when `dev` is in the set (dev tools on both OSes — Linux-only dev tools carry `os = ["linux"]` so they never try to install on Windows). `config.linux.toml` never loads on Windows (no `linux` token there), which is why herdr/opencode/omp/pwndbg/DevToys CLI stay separate `$PortableTools` pins in `bootstrap.ps1` instead of riding the shared config.

**`make tools`** = `scripts/lib/mise-install.sh` (`mise install`, force-reinstall `node` once when its declaration changed while already installed — a cksum marker under `~/.local/state/workstation/` — then `mise prune`) → `tasks/verify-tools` (post-install capability gate: ELF/arch/`ldd`/glibc-floor over every binary `mise bin-paths` exposes, symlinks followed) → `tasks/migrate-legacy` (one-time sweep of the pre-mise binaries, sudo only for `/usr/local` on a dev host with sudo, skipped entirely — not path-by-path — when there's no sudo). Plus a copy of `zjstatus.wasm` into zellij's data dir via `scripts/lib/zellij-plugin.sh`.

**Asset rulings made during the PR1 spike** (why several `config.linux.toml`/`config.dev.toml` entries carry explicit `github:`/`http:` backends instead of the aqua-registry short name):
- `usql`: aqua's default is a dynamic build needing glibc ≥ 2.38 (EL9 has 2.34) → pin `usql_static-{{version}}-linux-amd64.tar.bz2`, rename to `usql`.
- `fastfetch`: aqua's default build's loader fails on EL9 → pin the `-polyfilled` asset.
- `gping`/`yazi`/`television`/`atuin`/`qsv`: aqua's registry defaults to the gnu build, which needs a glibc/glibcxx floor above EL9's → pin the explicit `-musl` asset for each. `qsv`'s archive ships 6 binaries; `bin = "qsv"` picks the full-feature one.
- `pwndbg`: `bin_path = "pwndbg/bin"` — the release archive extracts a top-level `pwndbg/` wrapper dir.
- `oh-my-pi`: `bin = "omp"` — the asset is a bare per-platform binary (`omp-linux-x64`), `bin=` names the installed command.
- `nnd`: bare `nnd` asset_pattern — the release has no os/arch tokens, so even mise needs the override (same class of problem `jq`/`shfmt`/`witr` used to solve via the now-deleted `direct.sh`).
- `cht.sh`: `"http:cht.sh"` with `version = "0"` — the `http:` backend rejects `"latest"` outright and the URL has no `{{version}}` template to substitute into, so the pin value is a bookkeeping placeholder; the script itself is what's rolling.

**`python` IS declared** in `config.toml` (`python = "3.14.7"`), a three-way pin with `PYTHON_VERSION` in `makefile/versions.mk` and `$PythonEnvVersion` in `bootstrap.ps1`. This is a deliberate reversal of the earlier mise-runtimes design's "python is NEVER declared" rule: `mise lock` needs a real interpreter to solve the dependency-locked `pypi:`/`pipx:` tools (`basedpyright`, `glances`, `asciinema`, `harlequin` — `uv sync --frozen --python <mise python>`), and without one mise falls back to the system 3.9, which refuses those installs. It shadows `python3` only in mise-activated shells; `/usr/bin/python3` (and everything sudo/system-service touches) is untouched. This is a *different* Python from `python-env`'s own uv-built CPython (`~/.local/share/workstation-python`) — same version by coincidence of the three-way pin, not the same interpreter, and `python-env` stays a separate bespoke Make target.

**Lock artifact set is FOUR things, never "mise.lock" alone**: `mise.lock` (for `config.toml`), `mise.linux.lock` (for `config.linux.toml`), `mise.dev.lock` (for `config.dev.toml`), and `locks/**` (per-tool sidecars for the dependency-locked `pypi:`/`npm:` tools, e.g. `locks/mise.dev/npm-ccstatusline`). All four are mise-generated — never hand-edit; regenerate with `mise lock --global --platform linux-x64` (Linux) and `mise lock --global --platform windows-x64` (Windows-installing tools only) after any pin change, run from OUTSIDE the checkout via an `XDG_CONFIG_HOME` symlink dir (unset `MISE_CONFIG_DIR`). **mise 2026.9.9 quirk (Task 10 fix wave):** `mise lock` itself always writes the pypi:/npm: sidecar refs under a stale `.mise/locks/**` layout regardless of invocation form — never the tracked `locks/**` layout — so every regen must fold `.mise/locks/**` into `locks/**` and repoint the lock files' `path = ` refs afterward (`scripts/bump-versions.sh`'s `normalize_lock_sidecars()` does this; `mise install` can write `locks/**` directly but only when its config root is literally `$HOME/.config/mise` — not `MISE_CONFIG_DIR`, an XDG-symlink dir, or any other directory, all of which get `.mise/locks/**` instead — which is why `lint.yml`'s install step runs with `MISE_LOCKFILE=false` rather than relying on it).

**`mise config set` eats comments.** It drops a same-line comment on the string entry it bumps, and a leading comment above a table's first key. This bit the weekly-bumper design directly — a reviewer of a `version-bumps.yml` PR should expect those two comment shapes to vanish from a bumped line's diff even when nothing else changed, and re-add them by hand if they carried real information (an EL9-glibc-floor rationale, an asset-pattern reason).

**`find -L` for symlinked bins**: `tasks/verify-tools` must follow symlinks when walking `mise bin-paths` output — mise's `.mise-bins/` shim indirection means a bin-path entry is often a symlink, and `[ -f ]`/`head -c4`/`verify-binary.sh` all need `-L`-equivalent resolution or they silently skip real binaries.

**Windows runs are the user's** — Claude does not drive `bootstrap.ps1`/`chezmoi apply`/interactive PowerShell sessions (see `[[feedback-windows-commands-user-runs-them]]`); Windows-side verification of this PR's changes is handed to the user via the `!` prefix, same as always.

See also `[[project-mise-runtimes-shipped]]` — the earlier mise-runtimes-only design (node/Go/uv/LSP servers via a generated conf.d) that this PR supersedes; its Windows-interop-probe gotchas (UNC cwd walks, winget long-path uninstall failures, PS 5.1 vs pwsh 7 `Sort-Object` ordering) still apply verbatim to the new architecture.
