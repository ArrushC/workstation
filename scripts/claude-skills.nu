# claude-skills.nu: Windows counterpart of tasks/claude's archify step. Copies mise's
# archify (github:tt-a1i/archify in config.toml; its release zip is the skill directory)
# to %USERPROFILE%\.claude\skills\archify, where Claude Code finds user skills. A copy,
# not a link: mise's `latest` is a plain file on Windows, and a junction to the versioned
# directory would dangle after the next bump. The `claude-skills-win` mise task runs it
# from config.windows.toml's post-tools hook (bootstrap.ps1, wsu). Idempotent: an
# up-to-date copy is left as it is. It always exits 0: a failing hook would stop
# `mise bootstrap`.
#   nu --no-config-file scripts/claude-skills.nu

def main [] {
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
