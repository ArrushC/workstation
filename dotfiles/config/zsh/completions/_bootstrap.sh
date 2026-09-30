#compdef bootstrap.sh
# First-party zsh completion for the repo's Linux seed script (./bootstrap.sh).
# NOT vendored — unlike the neighboring _cht.sh. The flag set mirrors
# bootstrap.sh's argument parser and is kept in lockstep by
# scripts/check-invariants.sh (flag-parity check). No mode flag: the first run
# asks whether the host is owned or shared (or reads WORKSTATION_MODE).
_arguments \
  '--reinstall[wipe the cloned repo (incl. config.local.toml), then bootstrap fresh]' \
  '(-y --yes)'{-y,--yes}'[skip the confirmation prompt when reinstalling]' \
  '(-h --help)'{-h,--help}'[show usage and exit]'
