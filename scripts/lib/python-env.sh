#!/usr/bin/env bash
# python-env.sh — build the blessed dev Python scripting env with uv.
#
# Usage:
#   python-env.sh <python-interpreter>
#
#   python-interpreter   Path to mise's python (tasks/python-env passes
#                        "$(mise where python)/bin/python3"; its version is
#                        tools.python in config.toml).
#
# uv (mise-managed — tasks/python-env runs under mise, so uv is on PATH)
# builds the venv at ~/.local/share/workstation-python on that interpreter;
# it downloads no CPython of its own. USER-LEVEL like pip.sh — never run
# under sudo. The env is recreated from scratch every run (deterministic;
# ad-hoc `uv pip install -p <env> <pkg>` additions are deliberately
# disposable). Libs (scripts/python-env.txt) track LATEST at install time
# (glances precedent) — upgrading is `mise run python-env --rebuild`.

set -euo pipefail

python="${1:?usage: python-env.sh <python-interpreter>}"

env_dir="$HOME/.local/share/workstation-python"
bin_dir="$HOME/.local/bin"

# The lib list: scripts/python-env.txt (bootstrap.ps1 reads it too), one name
# per line; `#` starts a comment (whole line, or after whitespace); surrounding
# whitespace and a CR are dropped.
mapfile -t PY_LIBS < <(sed -E 's/(^|[[:space:]]+)#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
  "$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)/scripts/python-env.txt" | grep -v '^$')

if ! command -v uv >/dev/null 2>&1; then
  printf 'python-env.sh: uv not on PATH — run ./bootstrap.sh (uv is mise-managed)\n' >&2
  exit 1
fi

rm -rf "$env_dir"
uv venv --python "$python" "$env_dir"
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

printf 'python-env: %s + %d libs at %s (launchers: wpy, textual, typer)\n' \
  "$python" "${#PY_LIBS[@]}" "$env_dir"
