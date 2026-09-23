# shellcheck shell=bash
# ~/.config/bash/completions.bash — first-party tab completion for the repo's
# flag-bearing scripts (bootstrap.sh, manage-hosts.sh, update-hosts.sh).
# Sourced from ~/.bashrc; mode 0644, no shebang — never executed.
# PARITY NOTE: zsh gets richer versions (descriptions + mutual exclusions) via
# ~/.config/zsh/completions/_{bootstrap.sh,manage-hosts.sh,update-hosts.sh};
# Nushell completes the Windows .ps1 counterparts via the external completer
# in config.nu. Every surface is kept in lockstep with its script by
# scripts/check-invariants.sh (flag-parity check).
# bash keys completion on the EXACT command word (no basename fallback like
# zsh), so each script registers its common invocation spellings.

_workstation_complete_bootstrap() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  mapfile -t COMPREPLY < <(compgen -W '--dev --prod --reinstall --yes --doctor --check-for-updates --help' -- "$cur")
}

_workstation_complete_manage_hosts() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]}
  if [[ $prev == --group ]]; then
    mapfile -t COMPREPLY < <(compgen -W 'dev_machine prod_machine' -- "$cur")
    return
  fi
  mapfile -t COMPREPLY < <(compgen -W '--list --format --add --remove --copy-id --name --ip --user --group --skip-confirm --all' -- "$cur")
}

_workstation_complete_update_hosts() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]}
  if [[ $prev == --group ]]; then
    mapfile -t COMPREPLY < <(compgen -W 'dev_machine prod_machine' -- "$cur")
    return
  fi
  mapfile -t COMPREPLY < <(compgen -W '--group --name --check --parallel --help' -- "$cur")
}

complete -F _workstation_complete_bootstrap bootstrap.sh ./bootstrap.sh
complete -F _workstation_complete_manage_hosts manage-hosts.sh ./manage-hosts.sh scripts/manage-hosts.sh ./scripts/manage-hosts.sh
complete -F _workstation_complete_update_hosts update-hosts.sh ./update-hosts.sh scripts/update-hosts.sh ./scripts/update-hosts.sh
