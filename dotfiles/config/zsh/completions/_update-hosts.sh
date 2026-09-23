#compdef update-hosts.sh
# First-party zsh completion for ./scripts/update-hosts.sh (NOT vendored).
# Kept in lockstep with the script by scripts/check-invariants.sh.
_arguments \
  '--group[only hosts in this group]:group:(dev_machine prod_machine)' \
  '--name[only this host]:host name:' \
  '--check[print planned actions, do not ssh]' \
  '--parallel[max concurrent hosts (default 4)]:count:' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
