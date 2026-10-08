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
# (Claude Code's ~\.local\bin, an IDE's tools). Keep the session's own PATH by wrapping
# mise's output, never editing it: a prologue saves the session's PATH and any
# __MISE_ORIG_PATH a parent shell passed down, and an epilogue restores PATH and sets
# __MISE_ORIG_PATH (which mise's prompt hook rebuilds PATH from) to the inherited value,
# else the session's PATH. mise's snapshot lines run in between and are undone, in
# whatever form mise writes them.
def live-path [text: string] {
    let prologue = [
        "# nu-init: keep the session's PATH (mise's lines below write the generator's)"
        '$env.__NU_INIT_PATH = $env.PATH'
        '$env.__NU_INIT_ORIG_PATH = $env.__MISE_ORIG_PATH?'
    ]
    let epilogue = [
        "# nu-init: restore the session's PATH; mise's prompt hook rebuilds PATH from __MISE_ORIG_PATH"
        '$env.PATH = $env.__NU_INIT_PATH'
        '$env.__MISE_ORIG_PATH = ($env.__NU_INIT_ORIG_PATH | default ($env.__NU_INIT_PATH | str join (char esep)))'
        'hide-env __NU_INIT_PATH __NU_INIT_ORIG_PATH'
    ]
    let sep = (if ($text | str ends-with "\n") { "" } else { "\n" })
    $"($prologue | str join "\n")\n($text)($sep)($epilogue | str join "\n")\n"
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
    if $g.file == "mise.nu" { $text = (live-path $text) }
    # atuin's hooks start background jobs (`history end` on every prompt, the search
    # index at startup) and starship's prompt counts `job list` for its jobs gear, so the
    # gear showed on nearly every prompt; in zsh atuin's work isn't a shell job. Label
    # atuin's jobs and leave them out of starship's count. A changed format is written
    # as-is with a warning (the gear may then count atuin's jobs again).
    if $g.file == "atuin.nu" and ($text | str contains "job spawn") {
        $text = ($text | str replace --all "job spawn {" "job spawn --description atuin {")
        let all = ($text | parse --regex 'job spawn' | length)
        if ($text | parse --regex 'job spawn --description atuin \{' | length) != $all {
            print "nu-init: warning: atuin.nu: unexpected `job spawn` form; starship's jobs gear may count atuin's background jobs"
        }
    }
    if $g.file == "starship.nu" and ($text | str contains "job list") {
        $text = ($text | str replace --all "(job list | length)" "(job list | where description? != 'atuin' | length)")
        if not ($text | str contains "description? != 'atuin'") {
            print "nu-init: warning: starship.nu: unexpected `job list` form; its jobs gear may count atuin's background jobs"
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
