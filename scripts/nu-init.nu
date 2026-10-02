# nu-init.nu: regenerate Nushell's generated init files, one per tool, in a vendor
# autoload dir (Nushell sources every *.nu there at startup). The `nu-init` mise task
# runs it from the Windows post-tools hook, so wsu and bootstrap.ps1 refresh the files
# after a tool update. It always exits 0: a failing hook would stop `mise bootstrap`.
# The once-only atuin history import marker lives in a state dir, not the output dir,
# so wiping the output dir never re-imports.
#   nu --no-config-file scripts/nu-init.nu [--dir <path>] [--state-dir <path>]

# An error's headline plus its first label ("I/O error: Permission denied").
def why [e: record] {
    let label = (try { $e.json | from json | get -o labels.0.text } catch { null })
    if ($label | is-empty) or $label == $e.msg { $e.msg } else { $"($e.msg): ($label)" }
}

# `mise activate nu` writes the PATH it sees into the file. PowerShell evaluates its
# activation in every session; Nushell sources this generated file instead, so each
# session would get the generator's PATH and lose whatever its terminal passed down
# (Claude Code's ~\.local\bin, an IDE's tools). Rebase it on the session's own PATH:
# __MISE_ORIG_PATH, which mise's prompt hook rebuilds PATH from, comes from the session
# (or the parent shell, as mise itself does when it omits the line), and the two lines
# that overwrite PATH with the snapshot become no-ops. Returns null when mise's output
# no longer has that shape.
def live-path [text: string] {
    let orig = r##'(?m)^[ \t]*\$env\.__MISE_ORIG_PATH = r#'[^\r\n]*'#[ \t]*\r?\n'##
    let snap = r##'(?mi)^[ \t]*\$env\.path = \(r#'[^\r\n]*'# \| split row \(char esep\)\)[ \t]*\r?\n'##
    let row = r##'(?mi)^([ \t]*'?)set,path,[^'\r\n]*'##
    let start = r##'(?m)^export-env \{[ \t]*\r?\n'##
    let count = {|re| $text | parse --regex $re | length }
    if (do $count $orig) > 1 or (do $count $snap) != 1 or (do $count $row) != 1 or (do $count $start) != 1 {
        return null
    }
    $text
    | str replace --regex $orig ''
    | str replace --regex $snap ''
    | str replace --regex $row '${1}hide,__MISE_NO_PATH_SNAPSHOT,'
    | str replace --regex $start r#'export-env {
  $$env.__MISE_ORIG_PATH = ($$env.__MISE_ORIG_PATH? | default ($$env.PATH | str join (char esep)))
'#
}

# One generated file: rewrite only on change; a failing tool keeps the last good file.
def gen [dir: string, g: record] {
    let target = ($dir | path join $g.file)
    if (which $g.tool | is-empty) {
        if ($target | path exists) {
            rm --permanent --force $target
            print $"nu-init: removed ($g.file) \(($g.tool) is not on PATH\)"
        }
        return
    }
    let out = (do { run-external $g.tool ...$g.args } | complete)
    if $out.exit_code != 0 or ($out.stdout | str trim | is-empty) {
        print $"nu-init: warning: ($g.tool) exited ($out.exit_code); kept the previous ($g.file)"
        return
    }
    mut text = $out.stdout
    if $g.file == "mise.nu" {
        let live = (live-path $text)
        if $live == null {
            print $"nu-init: warning: mise.nu: unexpected `mise activate nu` output, written as-is \(Nushell sessions get its PATH snapshot\)"
        } else {
            $text = $live
        }
    }
    let old = (if ($target | path exists) { open --raw $target | decode utf-8 } else { "" })
    if $old == $text {
        print $"nu-init: ($g.file) unchanged"
    } else {
        $text | save --raw --force $target
        print $"nu-init: wrote ($g.file)"
    }
}

def main [--dir: path, --state-dir: path] {
    let dir = ($dir | default ($nu.data-dir | path join "vendor" "autoload"))
    let state = ($state_dir | default (($env.LOCALAPPDATA? | default ($nu.home-dir | path join ".local" "state")) | path join "workstation" "stamps"))
    try { mkdir $dir } catch {|e| print $"nu-init: warning: could not create ($dir): (why $e)" }
    let gens = [
        { file: "starship.nu", tool: "starship", args: ["init" "nu"] }
        { file: "mise.nu", tool: "mise", args: ["-C" $nu.home-dir "activate" "nu"] }
        { file: "zoxide.nu", tool: "zoxide", args: ["init" "nushell"] }
        { file: "atuin.nu", tool: "atuin", args: ["init" "nu" "--disable-up-arrow"] }
    ]
    for g in $gens {
        try { gen $dir $g } catch {|e| print $"nu-init: warning: ($g.file) failed: (why $e)" }
    }
    # atuin's database starts empty: import Nushell's existing history once. With no
    # history file there is nothing from before atuin to bring over.
    try {
        let marker = ($state | path join ".atuin-nu-imported")
        if (which atuin | is-not-empty) and not ($marker | path exists) {
            mkdir $state
            if not ($nu.history-path | path exists) {
                touch $marker
                print "nu-init: no Nushell history yet, nothing to import"
            } else {
                let r = (do { run-external "atuin" "import" "nu" } | complete)
                if $r.exit_code == 0 {
                    touch $marker
                    print "nu-init: imported Nushell's history into atuin (once)"
                } else {
                    print $"nu-init: warning: atuin import nu exited ($r.exit_code); the next run retries"
                }
            }
        }
    } catch {|e| print $"nu-init: warning: atuin import step failed: (why $e)" }
}
