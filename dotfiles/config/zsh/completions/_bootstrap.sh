#compdef bootstrap.sh
# First-party zsh completion for the repo's Linux seed script (./bootstrap.sh).
# NOT vendored — unlike the neighboring _cht.sh. The flag set mirrors
# bootstrap.sh's argument parser and is kept in lockstep by
# scripts/check-invariants.sh (flag-parity check). Deliberately NOT completed:
# "--checkforupdates" (compat alias). No mode flag: the first run asks
# whether the host is owned or shared (or reads WORKSTATION_MODE).
_arguments \
  '--reinstall[wipe the cloned repo (incl. config.local.toml), then bootstrap fresh]' \
  '(-y --yes)'{-y,--yes}'[skip the confirmation prompt when reinstalling]' \
  '(--check-for-updates)--doctor[read-only health report, then exit]' \
  '(--doctor)--check-for-updates[read-only update scan, then exit]' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
