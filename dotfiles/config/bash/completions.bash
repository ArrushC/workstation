# shellcheck shell=bash
# ~/.config/bash/completions.bash — first-party tab completion for the repo's
# flag-bearing script (bootstrap.sh).
# Sourced from ~/.bashrc; mode 0644, no shebang — never executed.
# PARITY NOTE: zsh gets richer versions (descriptions + mutual exclusions) via
# ~/.config/zsh/completions/_bootstrap.sh; Nushell completes the Windows
# bootstrap.ps1 via the external completer in config.nu. Every surface is
# kept in lockstep with its script by
# scripts/check-invariants.sh (flag-parity check).
# bash keys completion on the EXACT command word (no basename fallback like
# zsh), so each script registers its common invocation spellings.

_workstation_complete_bootstrap() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  mapfile -t COMPREPLY < <(compgen -W '--dev --prod --reinstall --yes --doctor --check-for-updates --help' -- "$cur")
}

complete -F _workstation_complete_bootstrap bootstrap.sh ./bootstrap.sh
