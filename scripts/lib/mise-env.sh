#!/usr/bin/env bash
# mise-env.sh [--write] — print the MISE_ENV token set for THIS Linux host: `linux`.
# Every host gets the same setup; the token only selects config.linux.toml
# (bootstrap.ps1 writes `windows` on Windows). --write also saves it to
# ~/.config/mise/miserc.toml (git-ignored). Every mise process reads that file
# (shells, shims under systemd, cron), so nothing exports MISE_ENV. An exported
# MISE_ENV still wins over miserc (CI and check-templates.sh set one).
set -euo pipefail
if [ "${1:-}" = --write ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
  printf '# Written by scripts/lib/mise-env.sh.\nenv = ["linux"]\nauto_env = false\n' >"$cfg/miserc.toml.tmp"
  mv "$cfg/miserc.toml.tmp" "$cfg/miserc.toml"
fi
echo linux
