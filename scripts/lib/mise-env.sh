#!/usr/bin/env bash
# mise-env.sh [--write] — the MISE_ENV token set for THIS Linux host: `linux`.
# Every host gets the same setup; the token only selects config.linux.toml
# (bootstrap.ps1 writes `windows` on Windows). --write also saves it to
# ~/.config/mise/miserc.toml (git-ignored). Every mise process reads that file
# (shells, shims under systemd, cron), so nothing exports MISE_ENV. An exported
# MISE_ENV still wins over miserc (CI and check-templates.sh set one).
set -euo pipefail
tokens="linux"

if [ "${1:-}" = --write ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '# Written by scripts/lib/mise-env.sh (the token set of this Linux host).\nenv = ["%s"]\nauto_env = false\n' \
    "${tokens//,/\", \"}" >"$cfg/mise/miserc.toml.tmp"
  mv "$cfg/mise/miserc.toml.tmp" "$cfg/mise/miserc.toml"
  # One-time cleanup of the old exported MISE_ENV (an export would override
  # miserc). Remove once every host has run it.
  envd="$cfg/environment.d/10-mise.conf"
  if [ -f "$envd" ] && ! grep -qvE '^(#.*|MISE_ENV=[a-z,]*|)$' "$envd"; then
    rm -f "$envd"
  fi
  if systemctl --user show-environment 2>/dev/null | grep '^MISE_ENV=' >/dev/null; then
    systemctl --user unset-environment MISE_ENV || true
  fi
fi
echo "$tokens"
