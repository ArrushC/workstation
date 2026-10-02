# Windows Nushell: toolbelt, self-healing init files, config — implementation plan (PR B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nushell on Windows gets the zsh toolbelt (zoxide, atuin, fzf pickers, eza, yazi, delta), carapace completions, the Catppuccin Mocha theme, and safer defaults. Its generated init files refresh themselves whenever `wsu` or `bootstrap.ps1` updates a tool.

**Architecture:**
- **Shared tools.** Seven tools move from `config.linux.toml` to `config.toml`, and yazi and atuin gain Windows assets, so both OSes install them. carapace is a new Windows-only tool.
- **Init files.** One Nushell script, `scripts/nu-init.nu`, writes the four generated init files (starship, mise, zoxide, atuin) into `vendor\autoload`. The mise task `nu-init` runs it from a Windows `post-tools` hook.
- **Hook behaviour.** Probed on the host on 2026-10-02: mise runs the hook through `cmd /c`, including on `--only dotfiles,tools`.
- **`config.nu`** gains the keybindings, aliases, completer chain and settings.
- **Theme.** A vendored theme file deploys to Nushell's user `autoload` dir.
- **CI.** The CI `templates` job, which already renders `config.nu` and has the pinned `nu`, evaluates the config and runs the nu-init test.

**Tech Stack:** mise 2026.9.9, Nushell 0.113.1, PowerShell 5.1/7, bash, aqua/github mise backends.

**Spec:** `docs/superpowers/specs/2026-10-02-windows-nushell-apps-design.md` §2–§4, §6, §9.

**Deviations from the spec**, decided while planning. Task 1 amends the spec to match.
1. **Four generated files, not five.** carapace's own Nushell snippet only installs its completer when none is set, and `config.nu` sets one for the `bootstrap.ps1` flags. So carapace is called from `config.nu`'s completer chain (flags → carapace → file completion), and there is no `carapace.nu`.
2. **History stays plaintext.**
   - A script can't switch Nushell's history backend: it is fixed at startup. A probe on 2026-10-02 showed `history import` run from a script writes into the live `history.txt`. The three stray lines were removed and the file restored byte-for-byte from the backup Nushell made.
   - atuin's database (cwd, duration and exit code per command) provides the richer history, and nu-init imports Nushell's history into atuin once.
3. **The Nushell tests run in the Linux `templates` CI job,** not `windows-http`.
   - That job already renders `config.nu` with mise and installs the pinned `nu`.
   - `config.nu.tera` uses no `os()`, so a Linux render is faithful.

## Global Constraints

- **Pins.** Tools keep their pins exactly:
  - fzf 0.74.4, zoxide 0.10.0, fd 10.5.0, bat 0.26.1, delta 0.19.2, eza 0.23.5, ripgrep 15.2.0
  - yazi 26.9.1, atuin 18.23.0, carapace 1.8.0
  - nushell 0.113.1 (unchanged)
- **Linux hosts are unchanged.** The same tools at the same versions for the `linux`, `linux,owned,host,wsl` and `linux,owned,host,native` token sets, and the same `mise bootstrap plan`.
- **Locks are never hand-edited.** Regenerate from outside the checkout (recipe in Task 1), then fold any `.mise/locks/` into `locks/` exactly as `normalize_lock_sidecars` in `scripts/bump-versions.sh` does.
- **Line endings and modes.** LF everywhere. `scripts/*.sh` are 100755; every file under `dotfiles/` is 100644; `scripts/nu-init.nu` is 100644, because it is run by `nu`, not executed.
- **Shell scripts.** First-party shell is `shfmt -i 2`-clean and shellcheck-clean (warning and above), and that includes `scripts/test-nu-init.sh`. Add it to `shell_targets()` in `scripts/check-invariants.sh`.
- **The PowerShell profile** (`Microsoft.PowerShell_profile.ps1.tera`) is BOM-less and read by 5.1 in the ANSI codepage, so new text in it is ASCII only, comments included.
- **`config.nu.tera`:**
  - The `let workstation_bootstrap_flags = [` line and its closing `]` stay at column 0, because `check_completion_parity` parses them.
  - Every hand-written `ws*`/`g*` alias keeps its PowerShell twin.
  - New aliases (`l`, `la`, `ll`, `lt`, `y`) get PowerShell twins too.
- **Size budgets:**
  - `CLAUDE.md` ≤ 14,000 bytes. It is 13,999 now, so every addition needs an equal cut in the same section, never a dropped rule.
  - `CLAUDE.md` + `docs/claude/*` ≤ 30,000 bytes.
  - `README.md` ≤ 600 lines. It is 592 now.
- **Hard limits on the real Windows host.** Never run any of these:
  - `wsa`, `wsu`, `mise dot apply`, `bootstrap.ps1`, `mise bootstrap` (any phase)
  - `mise install`
  - `history import` or `atuin import`
  - `nu-init` without `--dir <temp dir>`

  Never write under the real `%APPDATA%\nushell`. Read-only probes are fine: `mise ls`, `mise which`, `--help`, `--dry-run`, and parsing.
- **Linux `nu` for local test runs** (a CI-only checker, not a fleet tool):
  ```bash
  NU=0.113.1; D=/tmp/claude-1000/nu-$NU
  [ -x "$D/nu" ] || { mkdir -p "$D" && curl -fsSL "https://github.com/nushell/nushell/releases/download/$NU/nu-$NU-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C "$D" --strip-components=1; }
  export PATH="$D:$PATH"; nu --version
  ```
- **Commits.** End each commit with these two lines, then push (`git push`, branch `feat/windows-nushell`). The pre-commit hook runs `mise run lint`; never use `--no-verify`.
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
  ```
- **Docs travel with behaviour.** `README.md` changes go in the same commit as the behaviour they describe.

## Review Focus

1. **nu-init never fails the hook.** A missing tool, a tool that errors, a missing `nu`, or a failed `atuin import` must still let `mise bootstrap` finish. → Task 2: the "tool fails", "no tools", and "atuin import fails" cases, plus the task's `|| exit /b 0`.
2. **A failing tool never blanks its init file.** The last good file stays. → Task 2, "tool fails" case.
3. **A config key this Nushell doesn't know fails CI, not your shell.** → Task 3: `check-templates.sh` evaluates `config.nu` plus the theme, and the step shows a bogus key makes it fail.
4. **Linux hosts see no change.** → Task 1: the tool-set and bootstrap-plan comparisons.
5. **Cancelling the fzf picker (Esc) changes nothing.** The command line and directory stay as they were. → Task 3: the keybinding commands guard on `is-not-empty`; checked live in Task 4.

---

### Task 1: The toolbelt on Windows (config, locks, delta pager)

**Files:**
- Modify `config.linux.toml`: delete the `fzf`, `zoxide`, `fd`, `bat`, `delta`, `eza` and `ripgrep` lines, and the `"github:sxyazi/yazi"` and `"github:atuinsh/atuin"` lines.
- Modify `config.toml`: add them under `[tools]`, after `gh = "2.101.0"`.
- Modify `config.owned.toml`: add carapace.
- Regenerate `mise.lock`, `mise.linux.lock`, `mise.owned.lock` and `locks/**` with `mise lock`, never by hand.
- Modify `dotfiles/gitconfig.tera`: the pager becomes `delta` on both OSes.
- Modify `docs/superpowers/specs/2026-10-02-windows-nushell-apps-design.md`: apply the three deviations listed in the header.
- `dotfiles/claude/CLAUDE.md`'s TOOLS block is regenerated by the `sync-tool-memory` hook. Commit it if it changed.

**Interfaces:** Produces the tools Tasks 2–3 call on Windows: `zoxide`, `atuin`, `fzf`, `fd`, `bat`, `eza`, `rg`, `delta`, `yazi` and `carapace`, all on PATH through mise's shims.

- [ ] **Step 1: Record the Linux baseline.**

```bash
cd ~/.config/mise
snap() {
  for set in linux linux,owned,host,wsl linux,owned,host,native; do
    echo "== $set"
    MISE_ENV=$set mise -C ~ ls --current --json 2>/dev/null |
      jq -S '[to_entries[] | {tool: .key, versions: ([.value[].version] | sort)}] | sort_by(.tool)'
    MISE_ENV=$set mise -C ~ bootstrap plan --json 2>/dev/null | jq -S 'del(.summary)' | md5sum
  done
}
snap > /tmp/claude-1000/pr-b-before.txt; wc -l /tmp/claude-1000/pr-b-before.txt
```

- [ ] **Step 2: Move the tools.**

1. In `config.linux.toml`, delete these lines:
   - `fzf = "0.74.4"`
   - `zoxide = "0.10.0"`
   - `fd = "10.5.0"`
   - `bat = "0.26.1"`
   - `delta = "0.19.2"`
   - `eza = "0.23.5"`
   - `ripgrep = "15.2.0"`
   - the `"github:sxyazi/yazi" = …` line
   - the `"github:atuinsh/atuin" = …` line

   Keep any comment lines that sit above them only if they describe a tool that stays.
2. In `config.toml`, directly after `gh = "2.101.0"`, add:

```toml
# The zsh toolbelt Nushell on Windows shares (pickers, z/zi, Ctrl-R history, eza listings, delta pager).
fzf = "0.74.4"
zoxide = "0.10.0"
fd = "10.5.0"
bat = "0.26.1"
delta = "0.19.2"
eza = "0.23.5"
ripgrep = "15.2.0"
# aqua's Linux builds are gnu (GLIBC_2.39/2.38 > EL9's 2.34), so Linux pins musl; Windows takes the msvc zip.
"github:sxyazi/yazi" = { version = "26.9.1", platforms = { linux-x64 = { asset_pattern = "yazi-x86_64-unknown-linux-musl.zip" }, windows-x64 = { asset_pattern = "yazi-x86_64-pc-windows-msvc.zip" } } }
"github:atuinsh/atuin" = { version = "18.23.0", platforms = { linux-x64 = { asset_pattern = "atuin-x86_64-unknown-linux-musl.tar.gz" }, windows-x64 = { asset_pattern = "atuin-x86_64-pc-windows-msvc.zip" } } }
```

3. In `config.owned.toml`, after the `nushell = …` line, add:

```toml
"github:carapace-sh/carapace-bin" = { version = "1.8.0", os = ["windows"], asset_pattern = "carapace-bin_{{version}}_windows_amd64.zip" }   # Nushell's Tab completion for ~1000 CLIs (config.nu's external completer)
```

- [ ] **Step 3: Regenerate the locks** for the changed tools, from outside the checkout.

```bash
L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"
TOOLS="fzf zoxide fd bat delta eza ripgrep github:sxyazi/yazi github:atuinsh/atuin"
(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=linux,owned,host,native mise lock --global --platform linux-x64 $TOOLS github:carapace-sh/carapace-bin)
(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=windows,owned mise lock --global --platform windows-x64 $TOOLS github:carapace-sh/carapace-bin)
rm -rf "$L"
ls -d .mise/locks 2>/dev/null && echo "fold .mise/locks into locks/ (normalize_lock_sidecars)"
rg -n '^\[\[tools\.(fzf|zoxide|fd|bat|delta|eza|ripgrep|"github:sxyazi/yazi"|"github:atuinsh/atuin")\]\]' mise.linux.lock || echo "no stale entries in mise.linux.lock"
```

- If `mise.linux.lock` still has entries for the moved tools, run the full Linux relock to drop them: the first command again without the tool list. Pins are unchanged, so it only removes entries.
- If `mise lock` refuses a tool for `windows-x64` (the aqua registry has no Windows asset), switch that one tool to the `github:` platforms form, as yazi uses. The Windows assets at these pins are:
  - `fzf-0.74.4-windows_amd64.zip` (`junegunn/fzf`)
  - `zoxide-0.10.0-x86_64-pc-windows-msvc.zip` (`ajeetdsouza/zoxide`)
  - `fd-v10.5.0-x86_64-pc-windows-msvc.zip` (`sharkdp/fd`)
  - `bat-v0.26.1-x86_64-pc-windows-msvc.zip` (`sharkdp/bat`)
  - `ripgrep-15.2.0-x86_64-pc-windows-msvc.zip` (`BurntSushi/ripgrep`)
  - `delta-0.19.2-x86_64-pc-windows-msvc.zip` (`dandavison/delta`)
  - `eza.exe_x86_64-pc-windows-gnu.zip` (`eza-community/eza`)

  Keep the Linux side on the asset it used before (`mise.linux.lock` shows it). Record each switch as a deviation.

Then check the result:

```bash
git diff --stat -- 'mise*.lock' locks
```

Expected: only the moved tools and carapace change.

- [ ] **Step 4: Set the delta pager in `dotfiles/gitconfig.tera`.** Replace the six comment lines starting `# \`delta\` is a Linux-only tool` and the `pager = {% if os() == "windows" %}less{% else %}delta{% endif %}` line with:

```
    # delta is a mise tool on both OSes. On Windows, git runs the pager through its
    # own sh, so delta finds Git-for-Windows' bundled less there.
    pager      = delta
```

- [ ] **Step 5: Amend the spec.** In `docs/superpowers/specs/2026-10-02-windows-nushell-apps-design.md`:
- **§3:** the bullet list of files becomes four files (starship, mise, zoxide, atuin). Delete the `carapace.nu` bullet and add the sentence: "carapace is called from `config.nu`'s external completer (after the `bootstrap.ps1` flags), because carapace's own snippet only installs a completer when none is set."
- **§4, History:** replace the bullet with: "History stays plaintext: Nushell fixes its history backend at startup, and `history import` run from a script writes into the live file (probed 2026-10-02). atuin's database carries cwd/duration/exit per command, and `nu-init` imports Nushell's history into atuin once (marker `.atuin-nu-imported` in the autoload dir)."
- **§6, CI:** change "(`windows-http` job …)" to "(the Linux `templates` job, which renders `config.nu` with mise and has the pinned `nu`; `config.nu.tera` uses no `os()`)". Replace the two test bullets with:
  - "`check-templates.sh` evaluates the rendered `config.nu` and the theme with `nu`"
  - "`scripts/test-nu-init.sh` runs `nu-init.nu` against stub tools and a temp dir"

  Drop "five files" wording everywhere.
- **§9:** the risk row "Startup slows with five init files" becomes "… four init files".

- [ ] **Step 6: Verify Linux is unchanged, and check the Windows view read-only.**

```bash
snap > /tmp/claude-1000/pr-b-after.txt; diff /tmp/claude-1000/pr-b-before.txt /tmp/claude-1000/pr-b-after.txt && echo "Linux tools, versions and bootstrap plan unchanged"
mise run lint 2>&1 | tail -1
bash scripts/check-templates.sh 2>&1 | tail -1
(cd /mnt/c/Users/arrush.chaturvedi && powershell.exe -NoProfile -Command 'Set-Location $env:USERPROFILE; $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User"); & mise -C $env:USERPROFILE ls --missing 2>&1 | ForEach-Object { "$_" }' | tr -d '\r')
```

Expected:
- `Linux tools, versions and bootstrap plan unchanged`
- lint passes
- templates pass, and the gitconfig render shows `pager      = delta` for `windows,owned`
- The Windows `ls --missing` probe reads the Windows checkout, which is still on `main`. It shows what exists on Windows today, not this branch. Record its output as context only.

- [ ] **Step 7: Commit and push.**

```bash
git add config.toml config.linux.toml config.owned.toml mise.lock mise.linux.lock mise.owned.lock locks dotfiles/gitconfig.tera docs/superpowers/specs/2026-10-02-windows-nushell-apps-design.md
git add dotfiles/claude/CLAUDE.md 2>/dev/null; git status --short
git commit -F - <<'EOF'
feat(tools): the zsh toolbelt installs on Windows too (fzf/zoxide/fd/bat/delta/eza/ripgrep/yazi/atuin in config.toml), carapace for Windows; delta pages git on both OSes

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
EOF
git push
```

---

### Task 2: nu-init: self-healing generated init files

**Files:**
- Create: `scripts/nu-init.nu` (100644, LF)
- Create: `scripts/test-nu-init.sh` (100755, LF, `shfmt -i 2`-clean)
- Modify: `scripts/check-invariants.sh`
  - `shell_targets()`: add `scripts/test-nu-init.sh`. It is already matched by `scripts/*.sh`, so confirm with `bash scripts/check-invariants.sh --shell-files | rg test-nu-init`.
  - `check_bootstrap_config`: add `"config.windows.toml"` to the Python `files` list, so its hook is validated.
- Modify: `config.windows.toml`. Add the `[tasks.nu-init]` table and the `[bootstrap.hooks]` table.
- Modify: `bootstrap.ps1`.
  - Delete `Invoke-NushellStarship` and `Invoke-NushellMise`, together with their comment blocks.
  - Delete their two RUN SEQUENCE lines.
- Modify: `.github/workflows/lint.yml`. In the `templates` job, add a step after "Render + syntax-check dotfiles templates".
- Modify:
  - `dotfiles/windows/AppData/Roaming/nushell/config.nu.tera`: the header comment, lines 10–15 and 21–22.
  - `README.md`: step 7.
  - `CLAUDE.md`: the Windows section.

**Interfaces:**
- Produces: `nu --no-config-file scripts/nu-init.nu [--dir <path>]`.
  - The default dir is `$nu.data-dir/vendor/autoload`, which is `%APPDATA%\nushell\vendor\autoload` on Windows.
  - It writes `starship.nu`, `mise.nu`, `zoxide.nu` and `atuin.nu`, plus the marker `.atuin-nu-imported`.
  - It always exits 0.
- Produces: the mise task `nu-init`, and the Windows hook `post-tools = "mise run nu-init"`.

- [ ] **Step 1: Write the failing test** `scripts/test-nu-init.sh`:

```bash
#!/usr/bin/env bash
# test-nu-init.sh: scripts/nu-init.nu writes one init file per tool into a vendor
# autoload dir, leaves unchanged files alone, drops a missing tool's file, keeps the
# last good file when a tool fails, never touches files it doesn't own, imports
# Nushell's history into atuin once, and always exits 0. The tools are stubs on PATH.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v nu >/dev/null 2>&1; then
  echo "nu not installed: skipped (CI's templates job installs the pinned nu)"
  exit 0
fi
NU="$(command -v nu)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"
DIR="$T/autoload"
LOG="$T/calls.log"
mkdir -p "$BIN"
pass=0
fail=0

# stub <tool> [exit-code]: records its args, then prints "# <tool> init" (or fails).
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n[ "%s" -eq 0 ] || exit %s\nprintf "# %s init\\n"\n' \
    "$1" "$LOG" "${2:-0}" "${2:-0}" "$1" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
# atuin's stub answers `import` with $ATUIN_IMPORT_RC and anything else with an init.
stub_atuin() {
  printf '#!/usr/bin/env bash\necho "atuin $*" >>"%s"\nif [ "$1" = import ]; then exit "${ATUIN_IMPORT_RC:-0}"; fi\nprintf "# atuin init\\n"\n' \
    "$LOG" >"$BIN/atuin"
  chmod +x "$BIN/atuin"
}
run() {
  OUT="$(PATH="$BIN:/usr/bin:/bin" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" 2>&1)"
  RC=$?
}
check() {
  local name="$1"
  shift
  if "$@"; then
    printf '  \033[0;32mPASS\033[0m %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s\n' "$name"
    printf '%s\n' "$OUT" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}
has_out() { printf '%s' "$OUT" | grep -qF -- "$1"; }
file_is() { [ "$(cat "$DIR/$1")" = "$2" ]; }
no_bom() { [ "$(head -c3 "$DIR/$1" | od -An -tx1 | tr -d ' \n')" != efbbbf ]; }
calls() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

for t in starship mise zoxide; do stub "$t"; done
stub_atuin
mkdir -p "$DIR"
printf '$env.FOO = 1\n' >"$DIR/omp-env.nu"

run
check "first run exits 0" [ "$RC" -eq 0 ]
for t in starship mise zoxide atuin; do
  check "$t.nu written from '$t' (no BOM)" bash -c "[ \"\$(cat '$DIR/$t.nu')\" = '# $t init' ] && [ \"\$(head -c3 '$DIR/$t.nu' | od -An -tx1 | tr -d ' \n')\" != efbbbf ]"
done
check "mise is called with -C <home> activate nu" grep -qE '^mise -C /.+ activate nu$' "$LOG"
check "atuin init uses --disable-up-arrow" grep -qF 'atuin init nu --disable-up-arrow' "$LOG"
check "atuin imports Nushell history on the first run" [ "$(calls 'atuin import nu')" -eq 1 ]
check "the import marker is written" [ -f "$DIR/.atuin-nu-imported" ]

before="$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')"
sleep 1
run
check "second run exits 0" [ "$RC" -eq 0 ]
check "second run rewrites nothing (mtimes unchanged)" [ "$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')" = "$before" ]
check "second run reports every file unchanged" [ "$(printf '%s' "$OUT" | grep -c 'unchanged')" -eq 4 ]
check "atuin import runs only once" [ "$(calls 'atuin import nu')" -eq 1 ]
check "an unowned file (omp-env.nu) survives" file_is omp-env.nu '$env.FOO = 1'

stub starship 1
run
check "a failing tool: still exits 0" [ "$RC" -eq 0 ]
check "a failing tool: its last good file is kept" file_is starship.nu '# starship init'
check "a failing tool: a warning names it" has_out 'warning: starship'
stub starship

rm "$BIN/zoxide"
run
check "a missing tool: still exits 0" [ "$RC" -eq 0 ]
check "a missing tool: its file is removed" [ ! -e "$DIR/zoxide.nu" ]
check "a missing tool: the others stay" bash -c "[ -f '$DIR/starship.nu' ] && [ -f '$DIR/mise.nu' ] && [ -f '$DIR/atuin.nu' ]"

rm -rf "$DIR"
: >"$LOG"
export ATUIN_IMPORT_RC=1
run
check "atuin import fails: exits 0, no marker, a warning" bash -c "[ $RC -eq 0 ] && [ ! -e '$DIR/.atuin-nu-imported' ]"
check "atuin import fails: the warning says it retries" has_out 'the next run retries'
export ATUIN_IMPORT_RC=0
run
check "atuin import retried and succeeded: marker written" [ -f "$DIR/.atuin-nu-imported" ]

rm -f "$BIN"/*
rm -rf "$DIR"
run
check "no tools at all: exits 0 and writes no init file" bash -c "[ $RC -eq 0 ] && [ -z \"\$(ls '$DIR'/*.nu 2>/dev/null)\" ]"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d nu-init cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d nu-init cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
```

Run `git add scripts/test-nu-init.sh && git update-index --chmod=+x scripts/test-nu-init.sh`.

- [ ] **Step 2: Run the test and check it fails.**

Get Linux `nu` with the Global Constraints recipe, then run `bash scripts/test-nu-init.sh`.

Expected: failures, because `scripts/nu-init.nu` doesn't exist.

- [ ] **Step 3: Write `scripts/nu-init.nu`.**

```nu
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
        { file: "mise.nu", tool: "mise", args: ["-C" $nu.home-path "activate" "nu"] }
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
```

If `open --raw … | decode utf-8` errors on 0.113.1, because `open --raw` already returns a string for `.nu`, drop `| decode utf-8`. The "second run rewrites nothing" case decides which form is right. Record it as a deviation.

- [ ] **Step 4: Run the test and check it passes.**

Run `bash scripts/test-nu-init.sh`.

Expected: `✓ all 24 nu-init cases passed`.

- [ ] **Step 5: Wire the task and hook in `config.windows.toml`.** Add these lines before the `# GUI apps, installed by` comment block:

```toml
# Nushell's generated init files (starship, mise, zoxide, atuin in vendor\autoload)
# follow the installed tools: the post-tools hook reruns nu-init after every tools
# phase (bootstrap.ps1, wsu). Windows runs tasks and hooks with `cmd /c`; a failing
# hook stops `mise bootstrap`, so the task ends `|| exit /b 0` (a stale init file
# is better than a stopped bootstrap).
[tasks.nu-init]
description = "Regenerate Nushell's vendor/autoload init files (starship, mise, zoxide, atuin)"
dir = "{{ xdg_config_home }}/mise"
run = "nu --no-config-file scripts/nu-init.nu || exit /b 0"

[bootstrap.hooks]
post-tools = "mise run nu-init"
```

In `scripts/check-invariants.sh`'s `check_bootstrap_config` Python block, change:
```python
files = ["config.host.toml", "config.native.toml", "config.wsl.toml", "config.linux.toml"]
```
to:
```python
files = ["config.host.toml", "config.native.toml", "config.wsl.toml", "config.linux.toml", "config.windows.toml"]
```

Then confirm on Windows, read-only, that the task and the hook resolve. The Windows checkout is on `main`, so use a temp copy:

```bash
T=/mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/ws-nuinit-probe; rm -rf "$T"; mkdir -p "$T"
sed -n '/^\[tasks.nu-init\]/,/^post-tools/p' config.windows.toml | sed 's/{{ xdg_config_home }}\/mise/./' > "$T/mise.toml"
cat "$T/mise.toml"
(cd /mnt/c/Users/arrush.chaturvedi && powershell.exe -NoProfile -Command '$t="$env:LOCALAPPDATA\Temp\ws-nuinit-probe"; Set-Location $t; $env:Path=[Environment]::GetEnvironmentVariable("Path","Machine")+";"+[Environment]::GetEnvironmentVariable("Path","User"); & mise trust $t *> $null; & mise bootstrap --only tools --dry-run 2>&1 | Select-String "post-tools|nu-init" | % { $_.Line }; & mise trust --untrust $t *> $null' | tr -d '\r')
rm -rf "$T"
```

Expected: `mise bootstrap: post-tools hooks` and `cmd /c 'mise run nu-init'`. This is a dry run, so nothing runs.

- [ ] **Step 6: Make the `bootstrap.ps1` changes.**
- Delete the `Invoke-NushellStarship` function and the two comment lines above it (`# Nushell can't \`eval\`, so starship's init goes to a generated, auto-sourced` …).
- Delete the `Invoke-NushellMise` function and the two comment lines above it (`# Like starship.nu, rewritten every run …`).
- Delete their RUN SEQUENCE lines (`Invoke-NushellStarship    # …` and `Invoke-NushellMise        # …`).
- Update the `Invoke-MiseBootstrap` RUN SEQUENCE comment's tail: `…; .wslconfig reminder` becomes `…; .wslconfig reminder; its post-tools hook regenerates Nushell's init files (mise run nu-init)`.

Then check:
- Run the Global Constraints parse check. Use the recipe in docs/claude/verification.md, Windows section.
- `rg -n 'NushellStarship|NushellMise' --glob '!docs/superpowers/**' .` finds nothing.
- `scripts/test-mise-env.ps1`, `test-winget-apps.ps1` and `test-ssh-launchers.ps1` still pass under 5.1 and pwsh. The interop recipe is in docs/claude/verification.md.

- [ ] **Step 7: Run the test in CI.** In `.github/workflows/lint.yml`, in the `templates` job, after the `Render + syntax-check dotfiles templates` step, add:

```yaml
      - name: Test nu-init (generated Nushell init files)
        run: bash scripts/test-nu-init.sh
```

- [ ] **Step 8: Docs.**
- **`config.nu.tera` header**, lines 10–15. Replace the sentence that starts "This file owns the HAND-WRITTEN config" through "…ahead of the shims dir)." with:

```
# This file owns the HAND-WRITTEN config (aliases, env, keys, helpers). The tool init
# code is GENERATED into %APPDATA%\nushell\vendor\autoload\ (auto-sourced at startup,
# so no `source` lines here) by scripts/nu-init.nu: starship.nu, mise.nu, zoxide.nu
# and atuin.nu. The `nu-init` mise task reruns it after every tools phase (the
# Windows post-tools hook), so a tool update reaches the next Nushell tab.
```

  Lines 21–22, the "Per-machine overrides" lines: point to `%APPDATA%\nushell\autoload\` (the user autoload dir), not `vendor\autoload`, which nu-init manages.

- **`README.md` step 7.** Replace "the Windows Terminal SSH fragment and Nushell's starship and mise autoload files" with "and the Windows Terminal SSH fragment". Then add a sentence to step 5: "Its `post-tools` hook runs `mise run nu-init`, which regenerates Nushell's init files (starship, mise, zoxide, atuin) in `%APPDATA%\nushell\vendor\autoload`, so `wsu` refreshes them too."

- **`CLAUDE.md`, Windows section.** Append to the Nushell bullet: `nu-init (post-tools hook) writes its vendor/autoload init files.` Keep the file ≤ 14,000 bytes by shortening words in the same section.

- [ ] **Step 9: Verify and commit.**

```bash
bash scripts/test-nu-init.sh | tail -1
mise run lint 2>&1 | tail -1
bash scripts/check-templates.sh 2>&1 | tail -1
wc -c CLAUDE.md
git add scripts/nu-init.nu scripts/test-nu-init.sh scripts/check-invariants.sh config.windows.toml bootstrap.ps1 .github/workflows/lint.yml dotfiles/windows/AppData/Roaming/nushell/config.nu.tera README.md CLAUDE.md
git commit -F - <<'EOF'
feat(nushell): nu-init regenerates Nushell's init files (starship, mise, zoxide, atuin) from a Windows post-tools hook; bootstrap.ps1's two generators removed

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
EOF
git push
gh run watch "$(gh run list --branch feat/windows-nushell --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

Expected: all CI jobs pass, including the new `Test nu-init` step.

---

### Task 3: config.nu, the theme, PowerShell parity, and evaluating config.nu in CI

**Files:**
- Modify: `dotfiles/windows/AppData/Roaming/nushell/config.nu.tera`
- Create (vendored):
  - `dotfiles/windows/AppData/Roaming/nushell/autoload/catppuccin_mocha.nu`, verbatim upstream at commit `815dfc6ea61f2746ff27b54ef425cfeb7b51dda8`
  - `dotfiles/windows/AppData/Roaming/nushell/autoload/.vendor`
- Modify: `config.windows.toml`, with a file entry deploying the theme
- Modify: `dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera` (ASCII only)
- Modify: `scripts/check-templates.sh`. `nu_check` evaluates instead of only parsing.
- Modify: `README.md`, the Windows Nushell paragraph

**Interfaces:**
- Consumes:
  - Task 1's tools, all on PATH on Windows: `eza`, `fzf`, `fd`, `bat`, `yazi`, `carapace`, `hx`.
  - Task 2's generated `zoxide.nu`, which defines `z`/`zi`, and `atuin.nu`, which binds Ctrl-R. config.nu doesn't re-declare either.

- [ ] **Step 1: Make the CI check evaluate `config.nu` (the failing test).**

In `scripts/check-templates.sh`, replace the `nu_check` line with:

```bash
# config.nu is evaluated, not only parsed: a $env.config key this Nushell doesn't
# know fails only at evaluation. A bulk render also deploys the theme into the
# sibling autoload dir; it's sourced after config.nu, as Nushell does.
# USERPROFILE stands in for Windows'.
nu_check() {
  local src theme
  src="source '$1'"
  theme="$(dirname "$1")/autoload/catppuccin_mocha.nu"
  [ -f "$theme" ] && src="$src; source '$theme'"
  USERPROFILE="${TMPDIR:-/tmp}" nu --no-config-file --commands "$src"
}
```

With Linux `nu` on PATH (Global Constraints recipe), prove the check now catches a bad key:

```bash
cp dotfiles/windows/AppData/Roaming/nushell/config.nu.tera /tmp/claude-1000/config.nu.tera.bak
printf '\n$env.config.not_a_real_key = 1\n' >> dotfiles/windows/AppData/Roaming/nushell/config.nu.tera
bash scripts/check-templates.sh 2>&1 | grep -E 'config.nu.*(failed|OK)' | head -3
cp /tmp/claude-1000/config.nu.tera.bak dotfiles/windows/AppData/Roaming/nushell/config.nu.tera
git diff --quiet dotfiles/windows/AppData/Roaming/nushell/config.nu.tera && echo restored
```

Expected: a `syntax check failed` line naming config.nu, then `restored`. Then run `bash scripts/check-templates.sh 2>&1 | tail -1` on the clean tree: all templates pass. That proves today's `config.nu` evaluates cleanly, so later failures come from the new code.

- [ ] **Step 2: Vendor the theme.**

```bash
D=dotfiles/windows/AppData/Roaming/nushell/autoload; mkdir -p "$D"
curl -fsSL https://raw.githubusercontent.com/catppuccin/nushell/815dfc6ea61f2746ff27b54ef425cfeb7b51dda8/themes/catppuccin_mocha.nu -o "$D/catppuccin_mocha.nu"
sha256sum "$D/catppuccin_mocha.nu"
```

Write `$D/.vendor` (use the sha256 printed above):

```
theme:          catppuccin_mocha.nu (Catppuccin Mocha for Nushell)
upstream:       https://github.com/catppuccin/nushell
license:        MIT
pin-kind:       commit (the repo has no release tags)
commit:         815dfc6ea61f2746ff27b54ef425cfeb7b51dda8 (2025-12-24, "date -> datetime" color key fix)
asset:          https://raw.githubusercontent.com/catppuccin/nushell/815dfc6ea61f2746ff27b54ef425cfeb7b51dda8/themes/catppuccin_mocha.nu
file-sha256:    <sha256 from above>  (verbatim upstream)
vendored:       2026-10-02
note:           Deploys as a single-file `copy` entry to %APPDATA%\nushell\autoload\ (Nushell's user
                autoload dir: sourced after config.nu, so its color_config wins); this sidecar is
                never deployed. check-templates.sh sources it with the rendered config.nu, so a
                Nushell bump that drops a key it sets fails CI.
                Bump: re-download at a newer commit, refresh commit + asset + file-sha256 + vendored.
```

Both files are 100644 and LF. In `config.windows.toml`, after the `"~/AppData/Roaming/nushell/config.nu"` entry, add:

```toml
# Vendored Catppuccin Mocha theme (provenance in the source dir's .vendor); Nushell's user autoload
# dir sources it after config.nu. Edit-in-repo-only (re-vendor to change it).
"~/AppData/Roaming/nushell/autoload/catppuccin_mocha.nu" = { source = "dotfiles/windows/AppData/Roaming/nushell/autoload/catppuccin_mocha.nu", mode = "copy" }
```

- [ ] **Step 3: Edit `config.nu.tera`.**

**(a)** After the `$env.config.show_banner = false` line, add:

```nu

# Ctrl-O opens the command line in Helix; EDITOR serves everything else.
$env.EDITOR = "hx"
$env.config.buffer_editor = "hx"
$env.config.cursor_shape.emacs = "line"
# Deletes go to the Recycle Bin; `rm --permanent` skips it.
$env.config.rm.always_trash = true
# Fuzzy, case-insensitive matching in the completion menu (gco -> git checkout).
$env.config.completions.algorithm = "fuzzy"

# --- fzf: the zsh side's look and file list ---------------------------------
$env.FZF_DEFAULT_OPTS = "--height 40% --layout=reverse --border --info=inline --bind=ctrl-/:toggle-preview --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 --color=selected-bg:#45475a,border:#6c7086,label:#cdd6f4"
$env.FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob "!.git"'

# Ctrl-T inserts a picked file at the cursor; Alt-C cds into a picked directory
# (fzf's own shell integration has no Nushell mode). Esc in the picker changes
# nothing. Ctrl-R (atuin) and z/zi (zoxide) come from vendor/autoload.
$env.config.keybindings = ($env.config.keybindings | append [
    {
        name: fzf_file
        modifier: control
        keycode: char_t
        mode: [emacs vi_insert vi_normal]
        event: {
            send: executehostcommand
            cmd: r#'let f = (fd --type f --hidden --exclude .git | fzf --preview "bat --color=always --style=numbers --line-range=:200 {}" | str trim); if ($f | is-not-empty) { commandline edit --insert ($f | to nuon) }'#
        }
    }
    {
        name: fzf_cd
        modifier: alt
        keycode: char_c
        mode: [emacs vi_insert vi_normal]
        event: {
            send: executehostcommand
            cmd: r#'let d = (fd --type d --hidden --exclude .git | fzf --preview "eza --tree --level=1 --icons=always --color=always {}" | str trim); if ($d | is-not-empty) { cd $d }'#
        }
    }
])
```

**(b)** After the git aliases block (the `alias gbr = git branch` line), add:

```nu

# --- eza listings + yazi (mirror the zsh aliases and the PowerShell profile) --
# Plain `ls` stays Nushell's structured table (filter it: ls | where size > 1mb).
alias l = eza --group-directories-first --icons=auto --hyperlink
alias la = eza -a --group-directories-first --icons=auto --hyperlink
alias ll = eza -lah --group-directories-first --icons=auto --git --time-style=long-iso --hyperlink
alias lt = eza --tree --level=2 --group-directories-first --icons=auto --hyperlink

# yazi: `y` opens it; on quit, cd to wherever you ended up.
def --env y [...args] {
    let tmp = (mktemp -t "yazi-cwd.XXXXXX")
    yazi ...$args --cwd-file $tmp
    let cwd = (open --raw $tmp | str trim)
    if $cwd != "" and $cwd != $env.PWD { cd $cwd }
    rm --permanent --force $tmp
}
```

**(c)** The completer.
1. Replace the comment block above `let workstation_bootstrap_flags` (from `# --- Repo-script flag completion (external completer)` through `# re-check this block on every Nushell pin bump (see CLAUDE.md).`) with:

```nu
# --- External completions -----------------------------------------------------
# Tab on an external command: bootstrap.ps1's flags first (Nushell can't read a
# .ps1 param() block), then carapace (git, mise, winget, gh, ssh and ~1000 more),
# then Nushell's own file completion when both return null. The flag record mirrors
# bootstrap.ps1's param() block; check-invariants.sh's flag-parity check parses its
# `let`/closing-bracket lines, so keep them at column 0. carapace runs only on Tab.
# PRE-1.0 CHURN: the external-completer API is a churn surface; CI evaluates this
# file with the pinned nu (check-templates.sh), so a bump that breaks it fails CI.
```

2. Keep the `let workstation_bootstrap_flags = [ … ]` record exactly as it is.
3. Replace the `$env.config.completions.external = { … }` block with:

```nu

# carapace's own completer (its `_carapace nushell` snippet): an alias completes as
# its expansion (gs -> git status), and Windows' .exe suffix is dropped.
let carapace_completer = {|spans|
    if (which carapace | is-empty) { return null }
    let expanded_alias = (scope aliases | where name == $spans.0 | $in.0?.expansion?)
    let spans = (if $expanded_alias != null {
        $spans | skip 1 | prepend ($expanded_alias | split row " " | take 1 | str replace --regex '\.exe$' '')
    } else {
        $spans | skip 1 | prepend ($spans.0 | str replace --regex '\.exe$' '')
    })
    if ($spans | length) == 1 { return null }
    with-env { CARAPACE_SHELL: "nushell" } { carapace $spans.0 nushell ...$spans | from json }
}

$env.config.completions.external = {
    enable: true
    max_results: 100
    completer: {|spans|
        if ($spans | first | path basename | str downcase) == "bootstrap.ps1" {
            let word = ($spans | last | str downcase)
            let matches = ($workstation_bootstrap_flags | where {|f| $f.value | str downcase | str starts-with $word })
            if ($matches | is-empty) { null } else { $matches }
        } else {
            do $carapace_completer $spans
        }
    }
}
```

**(d)** In the PARITY NOTE near the top (lines 17–19), add one sentence: "The eza listings and `y` mirror the PowerShell profile too; keybindings, hooks and the external completer are Nushell-only."

**(e)** In `def wsh`'s raw string, after the `  wsh  this help` line and its blank line, add this section. It must be identical in the PowerShell profile:

```
Shell shortcuts:
  l / la / ll / lt   eza listings (ll: long + git; lt: tree)
  y                  yazi; on quit, cd to where you ended up
  z <dir> / zi       zoxide: jump to / pick a visited directory
  Nushell only: Ctrl-R history (atuin), Ctrl-T insert a file,
  Alt-C cd into a directory (fzf), Ctrl-O edit the line in hx
```

- [ ] **Step 4: Mirror it in the PowerShell profile** (ASCII only). In `Microsoft.PowerShell_profile.ps1.tera`:
- Insert the same `Shell shortcuts:` section in `wsh`'s here-string, at the same spot.
- After the git functions block (the `function gbr { git branch @args }` line), add:

```powershell

# --- eza listings + yazi (mirror config.nu and the zsh aliases) -------------
function l  { eza --group-directories-first --icons=auto --hyperlink @args }
function la { eza -a --group-directories-first --icons=auto --hyperlink @args }
function ll { eza -lah --group-directories-first --icons=auto --git --time-style=long-iso --hyperlink @args }
function lt { eza --tree --level=2 --group-directories-first --icons=auto --hyperlink @args }
# yazi: `y` opens it; on quit, Set-Location to wherever you ended up.
function y {
    $tmp = (New-TemporaryFile).FullName
    yazi @args --cwd-file="$tmp"
    $cwd = Get-Content -Path $tmp -Encoding UTF8
    if (-not [String]::IsNullOrEmpty($cwd) -and $cwd -ne $PWD.Path) {
        Set-Location -LiteralPath (Resolve-Path -LiteralPath $cwd).Path
    }
    Remove-Item -Path $tmp
}
```

Check the result: `LC_ALL=C grep -nP '[^\x00-\x7F]' dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera` must print nothing new. Lines that already contained non-ASCII before this task may stay, so compare against `git show HEAD:…`.

- [ ] **Step 5: Verify.**

```bash
bash scripts/check-templates.sh 2>&1 | grep -E 'config.nu|PowerShell_profile|summary' | head -8
bash scripts/check-templates.sh 2>&1 | tail -1
mise run lint 2>&1 | tail -1
```

Expected:
- `config.nu: renders + syntax OK` for `windows,owned`, now evaluated together with the theme in the bulk pass
- the profile renders and parses
- all templates pass
- lint passes, including flag parity and the dotfiles entry count (+1: the theme)

Startup time is measured on Windows in Task 4: the budget is under 600 ms for a login shell.

- [ ] **Step 6: README.** Replace the paragraph that starts `Restart the shell afterwards so the new profile loads. Nushell is the default local shell` with:

```markdown
Restart the shell afterwards so the new profile loads. Nushell is the default local shell (in Windows Terminal and Zed, both through mise's shim, `%LOCALAPPDATA%\mise\shims\nu.exe`); PowerShell stays for .NET/COM/registry tasks. Nushell carries the zsh toolbelt:
- `z`/`zi` (zoxide)
- Ctrl-R history search (atuin, local only; Nushell's earlier history is imported once)
- Ctrl-T to insert a file and Alt-C to cd into a directory (fzf, with bat/eza previews)
- `l`/`la`/`ll`/`lt` (eza)
- `y` (yazi)
- Tab completion for about 1,000 CLIs through carapace, after `bootstrap.ps1`'s own flags
- Ctrl-O to edit the command line in Helix

`rm` goes to the Recycle Bin (`rm --permanent` skips it). The theme is Catppuccin Mocha, vendored into `%APPDATA%\nushell\autoload\`. PowerShell gets the same `l`/`la`/`ll`/`lt`/`y` and `z`; `wsh` lists them all.
```

Run `wc -l README.md`; it must be ≤ 600.

- [ ] **Step 7: Commit and push.**

```bash
git add dotfiles/windows/AppData/Roaming/nushell config.windows.toml dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera scripts/check-templates.sh README.md
git commit -F - <<'EOF'
feat(nushell): fzf pickers, eza/yazi, carapace completions after the bootstrap.ps1 flags, Catppuccin Mocha, Helix editing, trash-by-default rm; CI evaluates config.nu with the pinned nu

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
EOF
git push
gh run watch "$(gh run list --branch feat/windows-nushell --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

---

### Task 4: Branch checks, the live Windows run, and the PR

- [ ] **Step 1: Run the branch checks on WSL.**

```bash
mise run lint 2>&1 | tail -1
bash scripts/check-templates.sh 2>&1 | tail -1
bash scripts/test-nu-init.sh | tail -1
mise -C ~ tasks validate 2>&1 | tail -1
snap > /tmp/claude-1000/pr-b-final.txt; diff /tmp/claude-1000/pr-b-before.txt /tmp/claude-1000/pr-b-final.txt && echo "Linux unchanged"
git diff --stat main..HEAD
```

`snap` is the function from Task 1, Step 1. Expected: everything passes, `Linux unchanged`, and CI is green.

- [ ] **Step 2: Hand the live run to the user** (they run it in Windows PowerShell).

```powershell
git -C $env:USERPROFILE\.config\mise fetch
git -C $env:USERPROFILE\.config\mise checkout feat/windows-nushell
wsu
Get-ChildItem $env:APPDATA\nushell\vendor\autoload, $env:APPDATA\nushell\autoload | Select-Object Name
Measure-Command { & "$env:LOCALAPPDATA\mise\shims\nu.exe" -l -c exit } | Select-Object TotalMilliseconds
```

`wsu` is the PowerShell profile's update command. It installs the new tools, and its post-tools hook runs nu-init.

Then, in a **new Windows Terminal tab** (Nushell):
- `z mise` then `zi`
- Ctrl-R
- Ctrl-T, then Esc
- Alt-C, then pick a directory
- `git ch<Tab>`
- `ll`, then `y`, then quit
- `history | last 3`
- `rm` a scratch file, and check it is in the Recycle Bin
- `git log -p -1`, which should page through delta
- `atuin history list | first 5`

Then **Warp's Nushell tab**: Ctrl-R, and `z`.

Last, one manual step: remove the dead PATH line from `%APPDATA%\nushell\vendor\autoload\omp-env.nu`, the `$env.PATH = ($env.PATH | append $"($env.LOCALAPPDATA)\\omp")` line.

Expected:
- `vendor\autoload` holds `starship.nu`, `mise.nu`, `zoxide.nu`, `atuin.nu` and `omp-env.nu`, plus the `.atuin-nu-imported` marker.
- `autoload` holds `catppuccin_mocha.nu`.
- Startup takes under 600 ms.
- Every key and command works, and Esc in a picker changes nothing.
- If atuin's Ctrl-R misbehaves in Warp, gate its keybinding on `WT_SESSION` (spec §9) in a follow-up commit.

- [ ] **Step 3: Open the PR** once the live run is clean. Title: `Windows Nushell: zsh toolbelt, self-healing init files, carapace completions, Catppuccin`. The body lists:
- the tool moves, and that Linux is unchanged
- nu-init and its hook
- the config.nu changes
- the theme
- the three spec deviations, with their reasons
- the verification: CI, nu-init cases, the bad-key mutation, the live run, startup ms
- after merge: on Windows, `git checkout main; git pull`; on Linux hosts, `mise run update` (lock moves only; no tool changes)

End with:
```
🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01VZCEand55U8LGSmXzP5B9D
```
