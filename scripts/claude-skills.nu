# claude-skills.nu: Windows counterpart of tasks/claude's archify and ccline steps. Copies mise's
# archify (github:tt-a1i/archify in config.toml; its release zip is the skill directory)
# to %USERPROFILE%\.claude\skills\archify, where Claude Code finds user skills. A copy,
# not a link: mise's `latest` is a plain file on Windows, and a junction to the versioned
# directory would dangle after the next bump. The `claude-skills-win` mise task runs it
# from config.windows.toml's post-tools hook (bootstrap.ps1, wsu). Idempotent: an
# up-to-date copy is left as it is. It always exits 0: a failing hook would stop
# `mise bootstrap`.
#   nu --no-config-file scripts/claude-skills.nu
#
# It also copies mise's ccline.exe (github:Haleclipse/CCometixLine) to
# %USERPROFILE%\.claude\ccline\ccline.exe, the status line command settings.enforced.json
# runs (~/.claude/ccline/ccline). Never plain `ccline`: a session whose PATH lacks the
# install directory reaches mise's shim, which starts mise on every refresh.

def main [] {
    try { copy-archify } catch {|e| print -e $"  ! archify skill copy failed: ($e.msg)" }
    try { copy-ccline } catch {|e| print -e $"  ! ccline copy failed \(retries next run\): ($e.msg)" }
}

# A status line refresh holds ccline.exe open for a few milliseconds, so a copy over it can
# fail once: main reports it and the next run copies.
def copy-ccline [] {
    let where = (do { ^mise where github:Haleclipse/CCometixLine } | complete)
    if $where.exit_code != 0 {
        print -e "  ccline not installed (mise install) — status line copy skipped"
        return
    }
    let src = ($where.stdout | str trim | path join ccline.exe)
    let dest = ($env.USERPROFILE | path join .claude ccline ccline.exe)
    let want = (open --raw $src | hash sha256)
    if ($dest | path exists) and (open --raw $dest | hash sha256) == $want { return }
    mkdir ($dest | path dirname)
    cp --force $src $dest
    print $"  ccline: copied to ($dest)"
}

def copy-archify [] {
    let where = (do { ^mise where github:tt-a1i/archify } | complete)
    if $where.exit_code != 0 {
        print -e "  archify not installed (mise install) — skill copy skipped"
        return
    }
    let src = ($where.stdout | str trim)
    let dest = ($env.USERPROFILE | path join .claude skills archify)
    let want = (open ($src | path join package.json) | get version)
    if ($dest | path exists) {
        # A link or junction (say, from `npx skills add`) is someone else's: removing
        # it recursively could reach its target.
        if ($dest | path type) != dir {
            print -e $"  ! ($dest) is not a plain directory — left alone \(remove it to use the pinned archify\)"
            return
        }
        let have = (try { open ($dest | path join package.json) | get version } catch { "" })
        if $have == $want { return }
        rm -r $dest
    }
    mkdir ($dest | path dirname)
    cp -r $src $dest
    print $"  archify ($want): copied to ($dest)"
}
