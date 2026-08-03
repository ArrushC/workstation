# python-env: blessed Python scripting environment (Textual, Click, + friends)

**Date:** 2026-08-02
**Scope:** `makefile/versions.mk` (new `PYTHON_VERSION` pin), `makefile/Makefile` (new dev-only bespoke target `python-env` + `PROVISION_FANOUT` entry + doctor row), `makefile/lib/python-env.sh` (new), `bootstrap.ps1` (uv `$PortableTools` entry + new `Invoke-PythonEnv` step + Doctor/CheckForUpdates coverage), `scripts/check-invariants.sh` (two dual-edit pin checks + lib-list parity check), `scripts/bump-versions.sh` (UV_VERSION moves to report-only), `README.html`, `CLAUDE.md` (invariants + dual-edit list), `docs/claude/{invariants,file-care,verification}.md`, `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Give every **dev machine** (Linux + Windows, prod skips) one blessed Python
environment where ad-hoc personal scripts can `import textual` / `import click`
with zero per-script setup, reached through a **named launcher** so the system
Python is never shadowed.

**Library set (user decisions, 2026-08-02):**

| Library | Why |
|---|---|
| `textual` | TUI framework — the headline request |
| `textual-dev` | Textual devtools: the `textual` CLI (console, live-reload, CSS inspector) |
| `click` | CLI framework — the second headline request |
| `rich` | Pretty terminal output (already a Textual dep; made explicit) |
| `httpx` | Modern requests successor (sync + async + HTTP/2) |
| `pydantic` | Validation / typed settings |
| `typer` | Type-hint-driven CLI framework built on Click (ships the `typer` CLI) |
| `polars` | Fast dataframes |
| `duckdb` | Embedded analytics SQL (the Python lib — NOT the standalone duckdb CLI binary) |

**Consumption model (user decisions, 2026-08-02):**

- **Ad-hoc scripts** against one shared env — not per-project venvs, not
  PEP 723 on-demand resolution.
- **Named launcher** `wpy` (+ the `textual` / `typer` CLI entry points) on
  PATH; system `python3` untouched.
- **Libs track latest** at install time (the glances precedent); the **Python
  runtime is exact-pinned**.

## Architecture

uv (already a both-scopes Linux `EGET_TOOL`; added to Windows in this design)
is the single front door for the runtime and the env:

1. `uv python install <PYTHON_VERSION>` — pinned CPython
   (python-build-standalone), user-level, no sudo/admin. Exact pin settled at
   implementation (newest 3.x with full wheel coverage for the lib set —
   verify polars/duckdb/pydantic-core wheels exist for it on both platforms).
2. `uv venv --python <PYTHON_VERSION> <env>` — env at
   `~/.local/share/workstation-python` (Linux) /
   `%LOCALAPPDATA%\workstation\python-env` (Windows).
3. `uv pip install --python <env> --upgrade <the 9 libs>` — newest at install
   time.
4. Launchers: `wpy` → the env's python (Linux: a tiny wrapper script in
   `~/.local/bin` — NOT a symlink, which would lose the venv since CPython
   resolves the full symlink chain past `pyvenv.cfg`; works as
   `#!/usr/bin/env wpy`. Windows: `wpy.cmd` shim in `workstation\bin`) plus
   `textual` and `typer` entry points (symlinks — their venv shebangs hold).

**Rebuild/upgrade model:** the stamp bakes `PYTHON_VERSION` **plus a content
hash of the install script** (Linux: first 8 hex of `sha256sum
lib/python-env.sh`, the wsl-config content-hash precedent; Windows: stamp file
records version + lib list and `Invoke-PythonEnv` re-runs on mismatch). So:

- Bump `PYTHON_VERSION` → rebuild on next provision.
- Edit the lib list → rebuild on next provision.
- Upgrade libs to newest → `make python-env-rebuild` (Linux, a serialized
  `clean-python-env`→`python-env` wrapper — the combined goal list races
  under -j$(nproc)) / delete the `python-env.*.stamp` under
  `%LOCALAPPDATA%\workstation\stamps` and re-run bootstrap (Windows; settled
  at implementation — no new flag, to spare the flag↔completion parity
  surface). "latest" stamps deliberately never re-fire on plain re-provision.

**Ad-hoc extras** (not repo-managed, wiped on rebuild):
`uv pip install -p <env-path> <pkg>` — documented in README.

## Design

### 1. Linux — dev-only bespoke target `python-env`

The pwndbg/vcpkg bespoke shape, but **user-level — never `$(SUDO)`** (the
`pip.sh`/basedpyright "belongs to the dev user" posture):

- **`makefile/versions.mk`:** `PYTHON_VERSION := <exact>` with a comment
  carrying the Windows dual-edit pointer and the "libs track latest — see
  lib/python-env.sh for the list" note.
- **`makefile/lib/python-env.sh`** (new; LF, 0755, shfmt/shellcheck-clean):
  takes `<python-version>`; holds the canonical lib list as an array; does
  `uv python install` → recreate env (`rm -rf` first for determinism) →
  `uv pip install --python <env> --upgrade "${LIBS[@]}"` → force-refresh the
  three `~/.local/bin` launchers (`wpy` as a wrapper script — see
  Architecture; `textual`/`typer` as symlinks, their entry-point scripts
  carry venv shebangs). Uses the `uv` binary from `$DEST` (PATH), not a
  hardcoded path.
- **`makefile/Makefile`:** `ifeq ($(MODE),dev)` target following pwndbg's
  shape minus `$(SUDO)`; stamp
  `$(STAMP)/python-env-$(PYTHON_VERSION)-<script-hash>.done`; **order-only dep
  on uv's stamp *file*** (the stamp-on-stamp invariant — never the phony);
  joins the dev-only `PROVISION_FANOUT` block; prod prints the standard
  "dev_machine target — skipping" stub. `clean-python-env` removes stamps, the
  env dir, and the three symlinks. Doctor row added (bespoke-target
  precedent). No WSL skip (useful in a WSL dev guest, like pwndbg). No rc
  changes — `~/.local/bin` is already on PATH.

### 2. Windows — uv portable tool + bespoke `Invoke-PythonEnv` step

- **uv joins `$PortableTools`** — pinned + sha256-verified, `Repo =
  "astral-sh/uv"`, non-`v` tags (`TagPrefix = ""`), asset
  `uv-x86_64-pc-windows-msvc.zip`. Layout settled at implementation: the zip
  carries `uv.exe` + `uvx.exe` (both wanted) — `"tree"` into `$WsBin` if the
  archive is flat, else the appropriate extraction. This is the Windows half
  of the existing Linux `EGET_TOOL` → **new `UV_VERSION` dual-edit** (the gh
  precedent), noted in `UpdateHint`.
- **`Invoke-PythonEnv`** (new bespoke step): mirrors the Linux script — same
  uv commands, `$PythonLibs` array mirroring the Linux list, then writes
  `wpy.cmd` / `textual.cmd` / `typer.cmd` shims into `$WsBin` (already on
  User PATH; shims call the env's `Scripts\` executables with `%*`
  pass-through). Stamped on version + lib list; honors `-SkipToolInstall`;
  **warn-and-continue on failure** (standard tool-step posture); admin-free
  throughout. Doctor row (env present + `wpy --version`); CheckForUpdates
  prints the dual-edit hint for `PYTHON_VERSION`/`UV_VERSION` (no
  GitHub-release tag lookup for the env itself).

### 3. Invariants & enforcement

- **`UV_VERSION` dual-edit:** `versions.mk` ↔ `$PortableTools` — add to
  `check-invariants.sh` (jq/gh precedent) and CLAUDE.md's dual-edit list.
  **`bump-versions.sh` must move UV_VERSION to the report-only set** (it was
  auto-bumpable as a Linux-only pin; dual-edits are reported, not auto-edited).
- **`PYTHON_VERSION` dual-edit:** `versions.mk` ↔ the value in
  `bootstrap.ps1` (Make never runs on Windows — the Helix-pin posture).
  check-invariants + CLAUDE.md list. Report-only in bump-versions (and its
  upstream is python-build-standalone, not a plain `vX.Y.Z` GitHub tag).
- **Lib-list parity:** the array in `lib/python-env.sh` ↔ `$PythonLibs` in
  `bootstrap.ps1` must match exactly — new check-invariants extraction check
  (the script-flag↔completion parity precedent), and the pair joins
  CLAUDE.md's parity-pairs list.
- New CLAUDE.md invariant bullet: python-env is a dev-only bespoke target,
  user-level (never sudo), launcher-not-PATH-shadowing, libs-track-latest.
  Full why/failure modes in `docs/claude/invariants.md`; per-file entries in
  `file-care.md`.
- `lib/python-env.sh` joins the LF+0755 enforced set automatically
  (`makefile/lib/*.sh` glob) — no check changes needed there.
- No `.chezmoiignore` changes (nothing chezmoi-tracked is added). No rc/env
  changes on either OS.

### 4. Docs

- **`README.html`:** Python scripting env card in §stack (dev-only badge);
  `wpy` usage + shebang line + "add your own lib" (`uv pip install -p …`) in
  §daily; upgrade recipe (`make python-env-rebuild`); Windows note
  in §setup-windows (uv + `Invoke-PythonEnv`, shims in `workstation\bin`);
  one §troubleshooting entry (stale/broken env → clean + rebuild; `wpy` not
  found → PATH/provision checks).
- **`CLAUDE_CHANGELOG.md`:** one row.

### 5. Verification (per `docs/claude/verification.md` recipes)

- **Linux (this WSL host):** `make -C makefile python-env MODE=dev` →
  `wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"`,
  `textual --version`, `typer --version`; `wpy` shebang script smoke test;
  `make doctor MODE=dev` shows the row; prod dry-run shows the skip stub;
  `bash scripts/check-invariants.sh` + `make lint MODE=prod` green (incl. the
  three new checks); re-run `make python-env` → stamp hit (no rebuild); edit
  the lib list → rebuild fires.
- **Windows:** `bootstrap.ps1` installs uv (sha256-verified) + builds the
  env; `wpy -c ...` same import smoke; `textual --version` from a fresh
  Nushell; `-Doctor` lists the env; re-run bootstrap → stamp hit;
  `-SkipToolInstall` skips.

## Non-goals

- prod_machine installs (explicitly dev-only, per the request).
- Shadowing system `python3`/`python` with the env (named-launcher decision).
- Per-project venv management or PEP 723/`uv run` workflows (the env doesn't
  preclude them — uv is on PATH for both).
- The standalone duckdb CLI binary, ipython, pytest, or any lib beyond the
  nine selected.
- chezmoi-managed venv or run_onchange wiring (rejected: violates the
  installs-live-in-makefile invariant and slows `cza`).
- Pinning individual library versions (libs track latest by decision;
  revisit only if an upgrade breaks a personal script).
