# nu-init.nu: regenerate Nushell's generated init files, one per tool, in a vendor
# autoload dir (Nushell sources every *.nu there at startup), plus LS_COLORS from the
# repo's dircolors. On Windows it also writes the same tools' PowerShell init into
# %LOCALAPPDATA%\workstation\pwsh-init, which the PowerShell profile dot-sources. The
# `nu-init` mise task runs it from the Windows post-tools hook, so wsu and bootstrap.ps1
# refresh the files after a tool update. It always exits 0: a failing hook would stop
# `mise bootstrap`. The once-only atuin history import markers live in a state dir, not
# the output dir, so wiping the output dir never re-imports.
#   nu --no-config-file scripts/nu-init.nu [--dir <path>] [--state-dir <path>] [--ps-dir <path>]

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

# mise's hooks (every prompt, every cd) start mise.exe to ask whether anything changed:
# about 0.5 s on Windows. Its answer depends only on what it reads, so the gate below
# fingerprints that and calls mise's hook only when the fingerprint changes. Same idea
# as zshrc.tera's _ws_mise_gate. Without the expected hook line, mise.nu stays as mise
# wrote it (every prompt then runs mise) and the caller warns.
const mise_gate = r#'
# nu-init: run mise's hook only when what it reads changes (zshrc.tera's _ws_mise_gate).
# It reads the config files from $env.PWD up to the root, the global config, the
# installed tools, trusted configs and MISE_* variables. One directory listing per
# folder carries every entry's mtime; a single file check costs ~1 ms on Windows.
# WORKSTATION_MISE_GATE=0 hands every prompt and cd back to mise's own hook.
def ws-mise-listing [dir: string, pattern: string] {
    try {
        ls -a $dir | where {|e| ($e.name | path basename) =~ $pattern } | each {|e| $"($e.name)@($e.modified | into int)" }
    } catch { [] }
}
def ws-mise-inputs [] {
    let file = '^(\.?mise(\..+)?\.toml|\.tool-versions)$'
    let conf = '^(config|mise)(\..+)?\.toml$'
    let home = $nu.home-dir
    mut seen = []
    mut d = $env.PWD
    loop {
        let here = (try { ls -a $d } catch { [] })
        $seen = ($seen | append ($here | where {|e| ($e.name | path basename) =~ $file } | each {|e| $"($e.name)@($e.modified | into int)" }))
        let dirs = ($here | where type == dir | get name | path basename)
        for sub in ([mise .mise] | where {|s| $s in $dirs }) {
            $seen = ($seen | append (ws-mise-listing ($d | path join $sub) $conf) | append (ws-mise-listing ($d | path join $sub conf.d) '\.toml$'))
        }
        if '.config' in $dirs {
            $seen = ($seen | append (ws-mise-listing ($d | path join .config) '^mise(\..+)?\.toml$'))
            $seen = ($seen | append (ws-mise-listing ($d | path join .config mise) $conf) | append (ws-mise-listing ($d | path join .config mise conf.d) '\.toml$'))
        }
        let up = ($d | path dirname)
        if ($up | is-empty) or $up == $d { break }
        $d = $up
    }
    let config = ($env.MISE_CONFIG_DIR? | default (($env.XDG_CONFIG_HOME? | default ($home | path join .config)) | path join mise))
    let data = ($env.MISE_DATA_DIR? | default (if $nu.os-info.name == 'windows' { $env.LOCALAPPDATA | path join mise } else { ($env.XDG_DATA_HOME? | default ($home | path join .local share)) | path join mise }))
    let state = ($env.MISE_STATE_DIR? | default (($env.XDG_STATE_HOME? | default ($home | path join .local state)) | path join mise))
    $seen = ($seen
        | append (ws-mise-listing $config '\.toml$')
        | append (ws-mise-listing ($config | path join conf.d) '\.toml$')
        | append (ws-mise-listing ($data | path join installs) '.')
        | append (ws-mise-listing ($state | path join trusted-configs) '.'))
    let vars = ($env | columns | where {|n| $n starts-with 'MISE_' } | sort | each {|n| $"($n)=($env | get $n | to nuon)" })
    $seen | uniq | append $vars | str join "\n" | hash md5
}
def --env ws-mise-gate [] {
    if ($env.WORKSTATION_MISE_GATE? | default '1') == '1' {
        let sig = (ws-mise-inputs)
        if $sig == ($env.__WS_MISE_SIG? | default '') { return }
        $env.__WS_MISE_SIG = $sig
    }
    mise_hook
}
# A parent Nushell's fingerprint is not this session's: the first prompt runs the hook.
hide-env -i __WS_MISE_SIG
'#

# `mise activate pwsh` sets PATH to the PATH the generator saw (`${Env:Path}='...'`,
# twice), then runs mise's hook, which builds on whatever PATH is current. Dropping those
# assignments leaves each session its own PATH (Claude Code's ~\.local\bin, an IDE's
# tools) for the hook to build on. Any other literal PATH assignment gets a warning.
def keep-path-ps [text: string] {
    let snapshot = "${Env:Path}='"
    let kept = ($text | lines | each {|l|
        if ($l | str starts-with $snapshot) { "# nu-init: mise's PATH snapshot dropped; the session keeps its own" } else { $l }
    })
    if ($kept | any {|l| $l =~ '(?i)^\s*(\$\{env:path\}|\$env:path)\s*=\s*.' }) {
        print "nu-init: warning: mise.ps1: unexpected PATH assignment; PowerShell sessions may get the generator's PATH"
    }
    $kept | str join "\n" | $"($in)\n"
}

# starship's init always sets a right prompt. Without a right_format in starship.toml it
# starts starship a second time at every prompt only to print nothing; zshrc.tera
# clears RPROMPT for the same reason. A starship.toml it can't read keeps starship's.
const starship_no_right = r#'
# nu-init: no right_format in starship.toml, so no second starship run per prompt.
if not (try { open --raw ($env.STARSHIP_CONFIG? | default ($nu.home-dir | path join .config starship.toml)) | str contains right_format } catch { true }) {
    $env.PROMPT_COMMAND_RIGHT = ""
}
'#

# Points mise's hooks at ws-mise-gate and appends it, or returns the text unchanged.
def gate-mise [text: string] {
    let hook = 'code: { mise_hook }'
    if not ($text | str contains $hook) {
        if ($text | str contains 'mise_hook') {
            print "nu-init: warning: mise.nu: unexpected hook form; every prompt and cd runs mise (no gate)"
        }
        return $text
    }
    let sep = (if ($text | str ends-with "\n") { "" } else { "\n" })
    $"($text | str replace --all $hook 'code: { ws-mise-gate }')($sep)($mise_gate)"
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
    if $g.file == "mise.nu" { $text = (live-path (gate-mise $text)) }
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
    if $g.file == "starship.nu" {
        let sep = (if ($text | str ends-with "\n") { "" } else { "\n" })
        $text = $"($text)($sep)($starship_no_right)"
    }
    if $g.file == "mise.ps1" { $text = (keep-path-ps $text) }
    put $target $text
}

# Writes <text> to <target> only when it differs. Windows PowerShell 5.1 reads a
# BOM-less script in the ANSI code page, so a .ps1 gets one.
def put [target: string, text: string] {
    let text = (if ($target | str ends-with ".ps1") { $"\u{feff}($text)" } else { $text })
    let name = ($target | path basename)
    # Bytes, not text: decoding drops the BOM, so a .ps1 would never match.
    let old = (if ($target | path exists) { open --raw $target | into binary } else { 0x[] })
    if $old == ($text | encode utf-8) {
        print $"nu-init: ($name) unchanged"
    } else {
        $text | save --raw --force $target
        print $"nu-init: wrote ($name)"
    }
}

# LS_COLORS from the repo's dotfiles/dircolors, which Linux turns into LS_COLORS with
# `dircolors -b` (Windows has no dircolors): Catppuccin file types for Nushell's `ls`,
# its completion menu and eza, as on Linux. The same string `dircolors -b` prints.
def ls-colors [dircolors: string] {
    let keys = {
        RESET: rs NORMAL: no FILE: fi DIR: di LINK: ln MULTIHARDLINK: mh FIFO: pi SOCK: so
        DOOR: do BLK: bd CHR: cd ORPHAN: or MISSING: mi SETUID: su SETGID: sg
        CAPABILITY: ca STICKY_OTHER_WRITABLE: tw OTHER_WRITABLE: ow STICKY: st EXEC: ex
    }
    open --raw $dircolors | decode utf-8 | lines
    | each {|l| $l | str replace --regex '#.*$' '' | str trim }
    | where {|l| $l != "" }
    | each {|l| $l | split row --regex '\s+' }
    | where {|p| ($p | length) >= 2 and $p.0 not-in [TERM COLORTERM OPTIONS COLOR EIGHTBIT] }
    | each {|p|
        let key = (if ($p.0 | str starts-with ".") { $"*($p.0)" } else { $keys | get -o $p.0 | default $p.0 })
        $"($key)=($p.1):"
    }
    | str join ""
}

def main [--dir: path, --state-dir: path, --ps-dir: path] {
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
    let dircolors = ($env.CURRENT_FILE | path dirname | path join ".." "dotfiles" "dircolors" | path expand)
    let ls_colors = (try { ls-colors $dircolors } catch {|e| print $"nu-init: warning: LS_COLORS from ($dircolors) failed: (why $e)"; null })
    if $ls_colors != null {
        try { put ($dir | path join "ls_colors.nu") $"$env.LS_COLORS = ($ls_colors | to nuon)\n" } catch {|e| print $"nu-init: warning: ls_colors.nu failed: (why $e)" }
    }
    # The same tools' PowerShell init, which the PowerShell profile dot-sources: run in
    # every session (through mise's shims, before mise's hook has run) they cost 0.2-1 s
    # each. Windows only, unless --ps-dir names a directory.
    let ps_dir = ($ps_dir | default (if $nu.os-info.name == 'windows' { $env.LOCALAPPDATA | path join "workstation" "pwsh-init" }))
    if $ps_dir != null {
        try { mkdir $ps_dir } catch {|e| print $"nu-init: warning: could not create ($ps_dir): (why $e)" }
        let ps_gens = [
            { file: "starship.ps1", tool: "starship", args: ["init" "powershell" "--print-full-init"] }
            { file: "zoxide.ps1", tool: "zoxide", args: ["init" "powershell"] }
            { file: "atuin.ps1", tool: "atuin", args: ["init" "powershell" "--disable-up-arrow"] }
            { file: "mise.ps1", tool: "mise", args: ["-C" $nu.home-dir "activate" "pwsh"] }
        ]
        for g in $ps_gens {
            try { gen $ps_dir $g } catch {|e| print $"nu-init: warning: ($g.file) failed: (why $e)" }
        }
        if $ls_colors != null {
            try { put ($ps_dir | path join "ls_colors.ps1") $"$env:LS_COLORS = '($ls_colors)'\n" } catch {|e| print $"nu-init: warning: ls_colors.ps1 failed: (why $e)" }
        }
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
    # The same once for PowerShell's history (PSReadLine's file), where the profile loads atuin.
    if $ps_dir != null {
        try {
            let marker = ($state | path join ".atuin-pwsh-imported")
            let history = ($env.APPDATA? | default ($nu.home-dir | path join ".local" "share") | path join "Microsoft" "Windows" "PowerShell" "PSReadLine" "ConsoleHost_history.txt")
            if (which atuin | is-not-empty) and not ($marker | path exists) {
                mkdir $state
                if not ($history | path exists) {
                    touch $marker
                    print "nu-init: no PowerShell history yet, nothing to import"
                } else {
                    let r = (do { run-external "atuin" "import" "powershell" } | complete)
                    if $r.exit_code == 0 {
                        touch $marker
                        print "nu-init: imported PowerShell's history into atuin (once)"
                    } else {
                        print $"nu-init: warning: atuin import powershell exited ($r.exit_code); the next run retries"
                    }
                }
            }
        } catch {|e| print $"nu-init: warning: atuin PowerShell import step failed: (why $e)" }
    }
}
