# shellcheck shell=bash
# ~/.config/bash/completions.bash — first-party tab completion for the repo's
# flag-bearing script (bootstrap.sh) and for ws (bashrc.tera).
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
  mapfile -t COMPREPLY < <(compgen -W '--reinstall --yes --help' -- "$cur")
}

complete -F _workstation_complete_bootstrap bootstrap.sh ./bootstrap.sh

# ws: subcommands, project names after `ws open`, and flags, from `ws complete` (the same
# list zsh's _ws and Nushell's ws-complete offer). python-cli is bashrc.tera's.
_workstation_complete_ws() {
  mapfile -t COMPREPLY < <(python-cli "$HOME/.config/mise/scripts/ws/ws.py" complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
}

complete -F _workstation_complete_ws ws
