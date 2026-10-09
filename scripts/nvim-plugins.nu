# nvim-plugins.nu: Windows counterpart of tasks/nvim-plugins (bash). Headless Neovim
# runs lua/ws/provision.lua from the deployed %LOCALAPPDATA%\nvim: plugins at
# nvim-pack-lock.json's commits, blink.cmp's prebuilt matcher, and the treesitter
# parsers (tree-sitter CLI + llvm-mingw's clang; ws.treesitter sets CC for cc-rs).
# The `nvim-plugins-win` mise task runs it from config.windows.toml's post-tools hook
# (bootstrap.ps1, wsu). Idempotent: a second run is a ~2 s no-op. It always exits 0:
# a failing hook would stop `mise bootstrap`.
#   nu --no-config-file scripts/nvim-plugins.nu

def main [] {
    if (which nvim | is-empty) { return }
    let cfg = ($env.LOCALAPPDATA | path join nvim)
    if not ($cfg | path join lua ws provision.lua | path exists) {
        print -e $"  ! ($cfg) is not deployed yet \(dotfiles not applied?\) — skipped"
        return
    }
    # The trailing `cquit 1` ends Neovim if provision.lua fails to load (a -c error
    # leaves headless Neovim running); run() itself always quits.
    let out = (do {
        ^nvim --headless --cmd "let g:ws_pack_install = 1" -c "lua require('ws.provision').run()" -c "cquit 1"
    } o+e>| complete)
    let noise = '(Installing parser|Language installed|Compiling parser)$|Downloading tree-sitter-.*\.\.\.$|^\s*$'
    $out.stdout | lines | where { |l| $l !~ $noise } | each { |l| print $"  ($l)" } | ignore
    if $out.exit_code == 0 {
        print "  nvim: plugins, matcher and parsers ready"
    } else {
        print -e "  ! nvim plugins incomplete (offline?): re-run `mise run nvim-plugins-win`"
    }
}
