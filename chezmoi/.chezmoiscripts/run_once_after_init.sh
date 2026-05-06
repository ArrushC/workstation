#!/usr/bin/env bash
# run_once_after_init.sh — chezmoi runs this exactly once after first apply
# Sets up nb notebook and any first-time config

set -euo pipefail

BIN="$HOME/.local/bin"
export PATH="$BIN:$PATH"

# Initialise nb notebook if not already done
if command -v nb &>/dev/null; then
  if [[ ! -d "$HOME/notes" ]]; then
    nb notebooks init home "$HOME/notes" 2>/dev/null || nb init 2>/dev/null || true
    echo "nb notebook initialised at ~/notes"
  fi
fi

# Set bash as default shell hint (can't chsh without root, but record preference)
echo "Bootstrap complete on $(hostname) at $(date)" >> "$HOME/.local/share/chezmoi-init.log"
