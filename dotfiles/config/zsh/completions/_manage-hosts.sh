#compdef manage-hosts.sh
# First-party zsh completion for ./scripts/manage-hosts.sh (NOT vendored).
# Flat union of action flags + option flags (context-aware per-action
# completion is deliberately not attempted). Kept in lockstep with the script
# by scripts/check-invariants.sh. Windows parity: manage-hosts.ps1 completes
# via the Nushell external completer in config.nu. NOTE: the script has no
# help flag — none is completed.
_arguments \
  '--list[list hosts from hosts.conf]' \
  '--format[re-pad hosts.conf columns]' \
  '--add[add a host to hosts.conf (interactive when no option flags given)]' \
  '--remove[remove a host from hosts.conf]' \
  '--copy-id[push your SSH public key to a host]' \
  '--name[host name]:host name:' \
  '--ip[host IP address]:ip:' \
  '--user[SSH user]:user:' \
  '--group[host group]:group:(dev_machine prod_machine)' \
  '--skip-confirm[skip confirmation prompts]' \
  '--all[apply the key-copy to every host in hosts.conf]'
