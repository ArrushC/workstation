#!/usr/bin/env bash
# pip.sh — install a Python tool to the user site (~/.local/bin).
#
# Usage:
#   pip.sh <package> [<package>...]
#
# Note: pip ignores $DEST. Python user-site is always under ~/.local. This
# is the right behavior for tools like glances/asciinema/harlequin that
# should belong to the dev user, never installed system-wide via sudo.

set -euo pipefail

if (($# < 1)); then
  printf 'pip.sh: usage: %s <package> [<package>...]\n' "$0" >&2
  exit 2
fi

python3 -m pip install --user --upgrade --disable-pip-version-check "$@"
