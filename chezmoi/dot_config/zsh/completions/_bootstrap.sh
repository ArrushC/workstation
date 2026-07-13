#compdef bootstrap.sh
# First-party zsh completion for the repo's Linux seed script (./bootstrap.sh).
# NOT vendored — unlike the neighboring _cht.sh. The flag set mirrors
# bootstrap.sh's argument parser and is kept in lockstep by
# scripts/check-invariants.sh (flag-parity check). Deliberately NOT completed:
# "--full" (removed-flag fail arm) and "--checkforupdates" (compat alias).
_arguments \
  '(--prod)--dev[host you own: sudo, /usr/local/bin + system packages (dev_machine)]' \
  '(--dev)--prod[host you do not own: no sudo, ~/.local/bin (prod_machine)]' \
  '--reinstall[wipe the cloned repo + chezmoi config, then bootstrap fresh]' \
  '(-y --yes)'{-y,--yes}'[skip the confirmation prompt when reinstalling]' \
  '(--check-for-updates)--doctor[read-only health report, then exit]' \
  '(--doctor)--check-for-updates[read-only update scan, then exit]' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
