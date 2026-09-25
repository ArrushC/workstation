#!/usr/bin/env bash
# mise-env.sh <dev|prod> — print the MISE_ENV token set for THIS Linux host.
#   prod → linux
#   dev  → linux,owned,host,wsl   (WSL guest)  |  linux,owned,host,native (bare metal / VM)
# Single source for bootstrap.sh and tasks/*; the rc
# files persist the same value (chezmoi templates until PR3, Tera after).
set -euo pipefail
mode="${1:?usage: mise-env.sh <dev|prod>}"
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
case "$mode" in
dev) if is_wsl; then echo "linux,owned,host,wsl"; else echo "linux,owned,host,native"; fi ;;
prod) echo "linux" ;;
*)
  printf 'mise-env.sh: unknown mode %q (dev|prod)\n' "$mode" >&2
  exit 2
  ;;
esac
