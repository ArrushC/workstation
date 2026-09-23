#compdef cht.sh
# Vendored from cht.sh (chubin/cheat.sh). DO NOT HAND-EDIT.
# Upstream: https://cheat.sh/:zsh  (rolling — no upstream version tag)
# Snapshot: 2026-06-02
# Upstream body sha256 (bytes served at cht.sh/:zsh): af384d0a3342e0156be150d4c1f64ccd94bcfde65f52f7f03b1becf359cdef24
# This copy inserts the header above AFTER the mandatory `#compdef cht.sh` first
# line; everything below is byte-verbatim upstream.
# Bump: re-download https://cheat.sh/:zsh, refresh the sha256 (hash the raw
# download — `curl -fsSL https://cheat.sh/:zsh | sha256sum` — BEFORE inserting
# this header) + snapshot date, keep `#compdef cht.sh` as the literal first
# line. Provides Tab-completion for
# the `cht.sh` command (fetches the language list from cheat.sh/:list at
# completion time — needs network).

__CHTSH_LANGS=($(curl -s cheat.sh/:list))
_arguments -C \
  '--help[show this help message and exit]: :->noargs' \
  '--shell[enter shell repl]: :->noargs' \
  '1:Cheat Sheet:->lang' \
  '*::: :->noargs' && return 0

if [[ CURRENT -ge 1 ]]; then
    case $state in
        noargs)
             _message "nothing to complete";;
        lang)
             compadd -X "Cheat Sheets" ${__CHTSH_LANGS[@]};;
        *)
             _message "Unknown state, error in autocomplete";;
    esac

    return
fi
