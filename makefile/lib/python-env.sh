#!/usr/bin/env bash
# python-env.sh — build the blessed dev Python scripting env with uv.
#
# Usage:
#   python-env.sh <python-version>
#
#   python-version   Pinned CPython, e.g. 3.14.6 (PYTHON_VERSION in
#                    versions.mk; dual-edits $PythonEnvVersion in
#                    bootstrap.ps1 — check-invariants.sh verifies).
#
# uv (the EGET_TOOL already on PATH) downloads the pinned CPython
# (python-build-standalone, user-level under ~/.local/share/uv) and builds
# the venv at ~/.local/share/workstation-python. USER-LEVEL like pip.sh —
# never run under sudo. The env is recreated from scratch every run
# (deterministic; ad-hoc `uv pip install -p <env> <pkg>` additions are
# deliberately disposable). Libs track LATEST at install time (glances
# precedent) — upgrading is `make python-env-rebuild` (serialized; a
# combined `clean-python-env python-env` goal list races under -j).

set -euo pipefail

version="${1:?usage: python-env.sh <python-version>}"

env_dir="$HOME/.local/share/workstation-python"
bin_dir="$HOME/.local/bin"

# Canonical lib list — KEEP ON ONE LINE (check-invariants.sh parses it and
# compares against $PythonLibs in bootstrap.ps1; parity pair).
PY_LIBS=(textual textual-dev click rich httpx pydantic typer polars duckdb)

if ! command -v uv >/dev/null 2>&1; then
  printf 'python-env.sh: uv not on PATH — run `make uv` first\n' >&2
  exit 1
fi

uv python install "$version"
rm -rf "$env_dir"
uv venv --python "$version" "$env_dir"
uv pip install --python "$env_dir/bin/python" --upgrade "${PY_LIBS[@]}"

# Launchers: wpy is a tiny WRAPPER SCRIPT, not a symlink — a symlink from
# outside the venv to bin/python loses the venv (CPython resolves the full
# symlink chain to the uv base interpreter and never finds pyvenv.cfg, so
# imports fail; verified 2026-08-03). Exec-ing the venv python by real path
# keeps the env, and nested shebangs (#!/usr/bin/env wpy) work — Linux
# accepts script interpreters. textual/typer STAY symlinks: they are venv
# entry-point scripts whose shebangs already point into the env.
mkdir -p "$bin_dir"
cat >"$bin_dir/wpy" <<EOF
#!/bin/sh
exec "$env_dir/bin/python" "\$@"
EOF
chmod 0755 "$bin_dir/wpy"
ln -sf "$env_dir/bin/textual" "$bin_dir/textual"
ln -sf "$env_dir/bin/typer" "$bin_dir/typer"

# Self-heal: remove artifacts from the removed workstation TUI (stale
# launcher from earlier provisions; TUI-only health/updates/history caches).
rm -f "$bin_dir/workstation"
rm -rf "$HOME/.cache/workstation-tui"

printf 'python-env: CPython %s + %d libs at %s (launchers: wpy, textual, typer)\n' \
  "$version" "${#PY_LIBS[@]}" "$env_dir"
