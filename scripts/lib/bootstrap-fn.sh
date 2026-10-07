#!/usr/bin/env bash
# bootstrap-fn.sh <function> [args...] — run one bootstrap.sh library function
# (config_get, is_wsl, ...) in this child shell, so tasks reuse bootstrap.sh's
# implementation instead of copying it. bootstrap.sh's `set -euo pipefail` stays
# confined to this process.
# shellcheck source=../../bootstrap.sh
WORKSTATION_BOOTSTRAP_LIB=1 source "$(dirname "$(readlink -f "$0")")/../../bootstrap.sh" && "$@"
