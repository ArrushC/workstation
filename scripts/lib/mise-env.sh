#!/usr/bin/env bash
# mise-env.sh <owned|shared> — print the MISE_ENV token set for THIS Linux host.
#   shared → linux
#   owned  → linux,owned,host,wsl   (WSL guest)  |  linux,owned,host,native (bare metal / VM)
# Single source for bootstrap.sh and tasks/*; the rc
# files persist the same value (chezmoi templates until PR3, Tera after).
set -euo pipefail
mode="${1:?usage: mise-env.sh <owned|shared>}"
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
case "$mode" in
owned) if is_wsl; then echo "linux,owned,host,wsl"; else echo "linux,owned,host,native"; fi ;;
shared) echo "linux" ;;
*)
  printf 'mise-env.sh: unknown mode %q (owned|shared)\n' "$mode" >&2
  exit 2
  ;;
esac
