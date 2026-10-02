# nu-init.nu: regenerate Nushell's generated init files, one per tool, in a vendor
# autoload dir (Nushell sources every *.nu there at startup). The `nu-init` mise task
# runs it from the Windows post-tools hook, so wsu and bootstrap.ps1 refresh the files
# after a tool update. It always exits 0: a failing hook would stop `mise bootstrap`.
#   nu --no-config-file scripts/nu-init.nu [--dir <path>]
def main [--dir: path] {
    let dir = ($dir | default ($nu.data-dir | path join "vendor" "autoload"))
    mkdir $dir
    let gens = [
        { file: "starship.nu", tool: "starship", args: ["init" "nu"] }
        { file: "mise.nu", tool: "mise", args: ["-C" $nu.home-dir "activate" "nu"] }
        { file: "zoxide.nu", tool: "zoxide", args: ["init" "nushell"] }
        { file: "atuin.nu", tool: "atuin", args: ["init" "nu" "--disable-up-arrow"] }
    ]
    for g in $gens {
        let target = ($dir | path join $g.file)
        if (which $g.tool | is-empty) {
            if ($target | path exists) {
                rm --permanent --force $target
                print $"nu-init: removed ($g.file) \(($g.tool) is not on PATH\)"
            }
            continue
        }
        let out = (do { run-external $g.tool ...$g.args } | complete)
        if $out.exit_code != 0 or ($out.stdout | str trim | is-empty) {
            print $"nu-init: warning: ($g.tool) exited ($out.exit_code); kept the previous ($g.file)"
            continue
        }
        let old = (if ($target | path exists) { open --raw $target | decode utf-8 } else { "" })
        if $old == $out.stdout {
            print $"nu-init: ($g.file) unchanged"
        } else {
            $out.stdout | save --raw --force $target
            print $"nu-init: wrote ($g.file)"
        }
    }
    # atuin's database starts empty: import Nushell's existing history once.
    let marker = ($dir | path join ".atuin-nu-imported")
    if (which atuin | is-not-empty) and not ($marker | path exists) {
        let r = (do { run-external "atuin" "import" "nu" } | complete)
        if $r.exit_code == 0 {
            touch $marker
            print "nu-init: imported Nushell's history into atuin (once)"
        } else {
            print $"nu-init: warning: atuin import nu exited ($r.exit_code); the next run retries"
        }
    }
}
