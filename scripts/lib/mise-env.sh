#!/usr/bin/env bash
# mise-env.sh <owned|shared> [--write] — the MISE_ENV token set for THIS Linux host.
#   shared → linux
#   owned  → linux,owned,host,wsl (WSL guest) | linux,owned,host,native (bare metal / VM)
# --write also saves it to ~/.config/mise/miserc.toml (git-ignored). Every mise
# process reads that file — shells, shims under systemd, cron — so nothing
# exports MISE_ENV. An exported MISE_ENV still wins over miserc (CI and
# check-templates.sh set one to pick a token set explicitly).
set -euo pipefail
mode="${1:?usage: mise-env.sh <owned|shared> [--write]}"
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
case "$mode" in
owned) if is_wsl; then tokens="linux,owned,host,wsl"; else tokens="linux,owned,host,native"; fi ;;
shared) tokens="linux" ;;
*)
  printf 'mise-env.sh: unknown mode %q (owned|shared)\n' "$mode" >&2
  exit 2
  ;;
esac

if [ "${2:-}" = --write ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '# Written by scripts/lib/mise-env.sh from vars.mode in config.local.toml.\nenv = ["%s"]\nauto_env = false\n' \
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
