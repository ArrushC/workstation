# Simplification PR 1 — Purge and docs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove stale history and the HTML docs console, and make every remaining doc and comment describe the repo as it is today, with no change to how any host is provisioned.

**Architecture:** Deletions (history docs, `README.html` console, two Claude-internal docs), rewrites (`README.md`, `CLAUDE.md`, `config*.toml` comments, `.claude/memory/`), and comment-level edits in scripts. Every edit is either docs-only or behaviour-neutral. The checks that prove this: TOML parses to identical data, lint passes, and `rg` finds no reference to a deleted file.

**Tech Stack:** Markdown, TOML (mise config), bash, PowerShell, `rg`, `python3` (`tomllib`), `jq`, mise 2026.9.9.

**Spec:** `docs/superpowers/specs/2026-09-29-simplify-design.md` (§5, PR 1). Read it before starting.

## Global Constraints

- Branch: `refactor/simplify-purge` (already exists, carries the spec commit). Commit after each task and push the branch (standing instruction); never push to `main`.
- No provisioning behaviour changes. Every `config*.toml` must parse to exactly the same data as `main` (Task 3's check).
- `bootstrap.ps1` and `scripts/install-nerd-fonts.ps1` must keep their UTF-8 BOM. `scripts/*.sh`, `scripts/lib/*.sh`, `tasks/*`, `.claude/hooks/*.sh` stay LF and git mode 100755. The `post-edit-guard.sh` hook repairs these automatically after an edit; re-read a file if it says it did.
- First-party shell stays `shfmt -i 2`-clean and shellcheck-clean (`mise run lint` enforces it).
- Keep `docs/superpowers/specs/2026-09-29-simplify-design.md` and every `docs/superpowers/plans/2026-09-29-simplify-*.md`.
- Present-tense comments only: say what is true and why. No PR numbers, "ruling N", "I4/I7/C2", "final-fix-brief", "PR3 Task 3", "controller review", dates of incidents, or "was X / used to be Y" narrative, unless the history is the reason a rule exists (then one clause, no ticket IDs).
- Code slated for deletion in later PRs is left alone. Spec §5 PR 1 item 6 listed some of these; this plan moves them to the PR that deletes the code:
  - `scripts/lib/zellij-plugin.sh`'s stale-dir cleanup (deleted in PR 3)
  - in `bootstrap.ps1`, deleted in PR 4:
    - the WezTerm-nightly TagFilter/TagSort/StringSort options
    - the PIN-ME check in `Install-PortableTool`
    - the `CLAUDE_VERSION := latest` comment in `Invoke-CheckForUpdates`
    - the `NODE_VERSION` comment in `Invoke-MiseRuntimes`
- Keep the file name `~/.local/state/workstation/dotfiles-migrated` (and `$MigratedMarker`'s value): existing hosts must not re-force their first apply.

## Review Focus

1. **A troubleshooting fix that stops working after condensing.** Readers copy commands from README.md into a terminal, so every command must match the source exactly (Task 2, step 5 checks this mechanically).
2. **Losing a rule that still applies.** A reader of the new CLAUDE.md should find every true rule from the old CLAUDE.md, `invariants.md` and `file-care.md` (Task 5, step 4: a headline-by-headline checklist).
3. **A config comment rewrite that changes TOML data.** A misplaced `#` or deleted line would change what mise loads; the parsed data must be identical (Task 3, step 1).
4. **Memory links that dangle after deleting or renaming files.** Every `[[slug]]` must resolve (Task 6, step 3).
5. **A new clone that sees gitleaks false positives** once the `node_modules/` and `README.html` allowlist entries go. `mise run secrets` must stay clean (Task 4, step 5).

---

### Task 1: Delete the historical docs

**Files:**
- Delete: every file under `docs/superpowers/plans/` and `docs/superpowers/specs/` except `specs/2026-09-29-simplify-design.md` and `plans/2026-09-29-simplify-*.md`
- Delete: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Record the failing check**

Run:
```bash
cd ~/.config/mise
git ls-files docs/superpowers CLAUDE_CHANGELOG.md | rg -v '2026-09-29-simplify' | wc -l
```
Expected: `110` (109 historical docs + the changelog). Anything non-zero means the task isn't done.

- [ ] **Step 2: Delete them**

```bash
cd ~/.config/mise
git ls-files docs/superpowers CLAUDE_CHANGELOG.md | rg -v '2026-09-29-simplify' | xargs git rm -q
```

- [ ] **Step 3: Verify**

```bash
git ls-files docs/superpowers CLAUDE_CHANGELOG.md
```
Expected: exactly the simplify spec and the simplify plan file(s).

- [ ] **Step 4: Commit and push**

```bash
git commit -q -m "chore(docs): delete historical plans, specs and CLAUDE_CHANGELOG.md

git history keeps them; nothing in them describes work still in flight."
git push -q
```
(The pre-commit hook runs `scripts/check-invariants.sh`; it must pass. Dangling references to the deleted files are fixed in Tasks 2–6; none of the invariant checks read these files.)

---

### Task 2: README.md replaces the HTML console

**Files:**
- Create: `README.md`
- Delete: `README.html`, `docs/README/README.css`, `docs/README/README.js`, `scripts/check-readme.mjs`
- Modify: `.github/workflows/lint.yml` (delete the `readme` job, lines 76–86 plus its preceding comment block)
- Modify: `.gitignore` (delete the `# Node (CI-only jsdom …)` comment and `node_modules/` line)
- Modify: `bootstrap.ps1:20` and `bootstrap.ps1:585` (`README.html` → `README.md`)
- Modify: `dotfiles/wslconfig:21` (`README.html > Troubleshooting > "WSL disk keeps growing"` → `README.md > Troubleshooting > "WSL disk keeps growing"`)
- Modify: `dotfiles/windows/AppData/Local/warp/Warp/config/settings.toml:79` (`README §setup-wsl` → `README.md, "WSL"`)
- Delete locally (untracked): `node_modules/` (jsdom installed for `check-readme.mjs`)

**Interfaces:**
- Produces: `README.md` with these exact top-level headings, in order. Later tasks and PRs link to them by name:
  `## What this is`, `## Owned and shared hosts`, `## Repo layout`, `## Setup`, `## Daily use`, `## Adding things`, `## Troubleshooting`.
  Under `## Setup` the `###` headings are `Linux`, `Windows`, `WSL`, `Terminals (Warp and Windows Terminal)`, `Shell prompt and completion`.
  Under `## Troubleshooting` each entry is a `###` heading whose text is the symptom.

- [ ] **Step 1: Write the check first (it fails now)**

Save as `/tmp/claude-readme-check.sh` (scratch, not committed):
```bash
#!/usr/bin/env bash
# Checks README.md against the sources it documents. Exit 1 on any gap.
set -uo pipefail
cd ~/.config/mise
f=README.md
fail=0
[ -f "$f" ] || { echo "missing $f"; exit 1; }
n=$(wc -l <"$f"); [ "$n" -le 600 ] || { echo "README.md is $n lines (> 600)"; fail=1; }
for h in '## What this is' '## Owned and shared hosts' '## Repo layout' '## Setup' '## Daily use' '## Adding things' '## Troubleshooting' \
         '### Linux' '### Windows' '### WSL' '### Terminals (Warp and Windows Terminal)' '### Shell prompt and completion'; do
  rg -qxF "$h" "$f" || { echo "missing heading: $h"; fail=1; }
done
# every bootstrap.sh flag from parse_args (the --checkforupdates compat alias is exempt)
for fl in $(sed -n '/^parse_args()/,/^}/p' bootstrap.sh | rg -o -- '--[a-z-]+' | sort -u | rg -vx -- '--checkforupdates'); do
  rg -qF -- "$fl" "$f" || { echo "bootstrap.sh flag not documented: $fl"; fail=1; }
done
# every bootstrap.ps1 param
for p in $(sed -n '/^param(/,/^)/p' bootstrap.ps1 | rg -o '\$[A-Z][A-Za-z]+' | tr -d '$' | rg -v '^RepoPath$'); do
  rg -qF -- "-$p" "$f" || { echo "bootstrap.ps1 flag not documented: -$p"; fail=1; }
done
# every ws* command defined in the zsh rc
for w in $(rg -o '^(ws[a-z]+)\(\)|^alias (ws[a-z]+)=' -r '$1$2' dotfiles/zshrc.tera | sort -u); do   # wse wsd wss wsr wsu wsa wsh
  rg -q "\b$w\b" "$f" || { echo "ws command not documented: $w"; fail=1; }
done
# 32 troubleshooting entries
t=$(awk '/^## Troubleshooting/{on=1;next} /^## /{on=0} on && /^### /' "$f" | wc -l)
[ "$t" -ge 32 ] || { echo "troubleshooting has $t entries (< 32)"; fail=1; }
# relative links resolve
rg -o '\]\(([^)#:]+)[^)]*\)' -r '$1' "$f" | sort -u | while read -r l; do [ -e "$l" ] || { echo "dead link: $l"; exit 1; }; done || fail=1
# the Windows download block and the Linux one-liner, verbatim
rg -qF 'https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh' "$f" || { echo "Linux one-liner URL missing"; fail=1; }
rg -qF 'https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1' "$f" || { echo "Windows download URL missing"; fail=1; }
rg -qF -- '--disable --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 30' "$f" || { echo "Windows curl.exe flags not verbatim"; fail=1; }
exit $fail
```
Run: `bash /tmp/claude-readme-check.sh`
Expected: FAIL with `missing README.md`.

- [ ] **Step 2: Write README.md**

Derive every statement from `README.html` (read the line ranges below) and the code it describes. Where the HTML and the code disagree, the code wins; note what you corrected in the commit message. Condense hard: plain Markdown, tables where the HTML had tables, fenced code blocks for commands, no HTML, no badges, no tool catalogue (the `#toolbelt` section, L317–1920, is dropped: `config*.toml` and `mise ls` are the list). Target ≤ 600 lines.

Skeleton (these headings exactly; subheadings under "Daily use" and "Adding things" are free):

```markdown
# workstation

## What this is
<!-- L1–215 intro + L216–316 #stack: 1 short paragraph + a 5–8 row "piece → role" table
     (bootstrap.sh/bootstrap.ps1, mise tools, mise bootstrap, mise dot, starship/zellij/helix/fzf).
     State that the checkout IS ~/.config/mise (%USERPROFILE%\.config\mise on Windows). -->

## Owned and shared hosts
<!-- L1922–2015: the owned vs shared table; how the mode is chosen (saved vars.mode in
     config.local.toml → WORKSTATION_MODE → prompt; Windows always owned); the MISE_ENV token-set
     table (shared `linux`; owned WSL `linux,owned,host,wsl`; owned native `linux,owned,host,native`;
     Windows `windows,owned`) and which config file each token loads. -->

## Repo layout
<!-- L2017–2525 condensed to one annotated tree of ≤ 30 lines: config*.toml, mise*.lock + locks/,
     tasks/, scripts/ + scripts/lib/, dotfiles/, configs/wsl/, bootstrap.sh, bootstrap.ps1,
     docs/claude/, docs/windows/application_list.md, .claude/. -->

## Setup
### Linux
<!-- L2528–3001: prerequisites (curl, git, tar); the curl|bash one-liner verbatim; WORKSTATION_MODE and
     the optional GITHUB_TOKEN; "what bootstrap.sh does" as a ≤ 8-item numbered list; every flag
     (--reinstall, --yes/-y, --doctor, --check-for-updates, --help); owned-only extras
     (statusline prompt, JetBrainsMono Nerd Font on non-WSL hosts). -->
### Windows
<!-- L3002–3609: no admin (except the optional SSHFS-Win UAC prompt); git prerequisite; the checked
     curl.exe download block verbatim (it is also in bootstrap.ps1's header, lines 19–32); the
     clone-and-run alternative; "what bootstrap.ps1 does" as a ≤ 10-item list; every flag from its
     param() block with a one-line meaning. -->
### WSL
<!-- L3610–3705: bootstrapping the AlmaLinux-9 distro, .wslconfig vs /etc/wsl.conf, `wsl --shutdown`
     after changes. -->
### Terminals (Warp and Windows Terminal)
<!-- L3706–3943: which is primary and why WT stays (default-terminal role, Nushell); one keybind table
     per terminal, ≤ 15 rows each, keeping the shared zellij-mnemonic rows. -->
### Shell prompt and completion
<!-- L3944–4112: starship, zsh plugins and their keys (Ctrl-R atuin, ↑/↓ substring search, → accept
     suggestion, Tab fzf-tab), bash parity notes in one sentence. -->

## Daily use
<!-- L4114–4770: the ws* command table (every ws* function/alias in dotfiles/zshrc.tera with one-line
     meaning and the Windows equivalents); per-machine overrides (~/.zshrc.local, ~/.bashrc.local,
     Microsoft.PowerShell_profile.local.ps1, ~/.ssh/config.local); `mise run health`; updating other
     hosts (wsu); runtimes via mise; python env (wpy, `REBUILD=1 mise run python-env`); Claude Code
     statusline (`mise run statusline`); zellij essentials (≤ 12 lines); pueued; winterop. -->

## Adding things
<!-- L4771–5052: adding a tool, bumping a version (weekly bump PR + `mise run bump-versions`),
     adding a dotfile, adding a dnf package (EL9-verified names only, one batch), adding a service or
     /etc file. Each ≤ 12 lines with the exact config snippet. -->

## Troubleshooting
<!-- L5054–6579: all 32 entries, each as `### <symptom>` + 1–6 lines: cause, then the fix command(s)
     verbatim. Entry titles and their source lines: see the list below. -->
```

The 32 troubleshooting entries (source line in `README.html`). Keep them all, in this order:
```
L5067 Bootstrap reports "Missing required prerequisites: …"
L5099 Changing a host between owned and shared
L5142 Clone or pull fails with "Authentication failed" or 404
L5181 SSH keeps prompting for a password after ssh-copy-id
L5211 ssh-keygen on Windows opens a passphrase prompt despite -N '""'
L5229 Copying inside a remote Zellij session doesn't reach the Windows clipboard
L5284 Zellij's tabs and pane borders are green, not mauve
L5352 SSH tab dies with "client_loop: send disconnect: Broken pipe" and floods the pane with garbage
L5407 Warp: missing Tab Configs, wrong theme, or it opened PowerShell instead of AlmaLinux-9
L5496 Windows Terminal shows old settings / leftover SSH host profiles
L5545 bootstrap.ps1 aborts with "Git is required but isn't on PATH"
L5570 bootstrap.ps1 aborts with "<Tool> sha256 mismatch — refusing to install"
L5608 PowerShell aliases / adminpw / ws* don't load (the profile seems ignored)
L5649 mise bootstrap failed with a dnf error naming one package
L5680 A bootstrap phase fails and blocks the rest
L5721 mise dot apply / mise bootstrap fails with "Variable … is not defined" — and nothing got applied
L5769 mise dot apply / mise bootstrap refuses with "refusing to overwrite existing files (use --force)"
L5825 wsu fails with "fatal: Not possible to fast-forward, aborting"
L5882 A copy-mode file (Warp / Windows Terminal / Zed / VS Code settings) reverts after wsa
L5920 I edited a file in $HOME directly (e.g. ~/.claude/CLAUDE.md) and wsa reverted it
L5979 mise bootstrap plan / status asks for a sudo password and hangs (no TTY)
L6016 pueue status fails, or pueued isn't running
L6059 Colors look banded or 8-bit on a remote host
L6082 Tofu boxes / missing icons after install
L6179 Shell startup / a PATH-scanning command feels slow on WSL
L6254 WSL disk (ext4.vhdx) keeps growing — freed space never returns to Windows
L6321 LSP servers — a language server is missing after mise bootstrap
L6356 C / C++ toolchain — a tool is missing, or ninja / vcpkg behaves oddly
L6437 wpy not found, or import textual fails in it
L6470 NFS tools (showmount, nfsstat, autofs) are missing on an owned host
L6501 bootstrap.ps1 popped a UAC prompt (or SSHFS-Win reports "skipping")
L6536 Zellij's top bar is plain, shows a "permission" request, or renders boxes instead of rounded pills
```
The last entry's text in `dotfiles/wslconfig:21` must match the WSL-disk heading exactly.

Also fix while writing: the HTML claims at L3003–3005 that there's "no provisioning Makefile (that's Linux-only)". There is no Makefile anywhere, so drop it. Drop the other Make/chezmoi leftovers the HTML carries (L2247, L2909, L3692, L4679, L5004–5009, L6190, L6329): state the current mechanism instead.

- [ ] **Step 3: Delete the console and its CI job; repoint references**

```bash
cd ~/.config/mise
git rm -q README.html docs/README/README.css docs/README/README.js scripts/check-readme.mjs
```
- `.github/workflows/lint.yml`: delete the whole `readme:` job and the 3-line `# jsdom here is a CI-ONLY …` comment above it.
- `.gitignore`: delete these two lines:
  ```
  # Node (CI-only jsdom for scripts/check-readme.mjs; never committed)
  node_modules/
  ```
- `bootstrap.ps1:20`: `# download, same form as README.html's Windows quickstart:` → `# download, same form as README.md's Windows setup:`
- `bootstrap.ps1:585`: `  1. Use the checked curl.exe download from README.html with -Reinstall.` → `  1. Use the checked curl.exe download from README.md with -Reinstall.`
- `dotfiles/wslconfig:21`: `# VHD, see README.html > Troubleshooting > "WSL disk keeps growing".` → `# VHD, see README.md > Troubleshooting > "WSL disk (ext4.vhdx) keeps growing".`
- `dotfiles/windows/AppData/Local/warp/Warp/config/settings.toml:79`: replace `(see README §setup-wsl)` with `(see README.md, Setup > WSL)`.
- Look at the untracked `node_modules/` before removing it: `ls node_modules | head; git status --short --ignored node_modules`. It must be the `!! node_modules/` jsdom install. Then `rm -rf node_modules`.

- [ ] **Step 4: Run the README check**

Run: `bash /tmp/claude-readme-check.sh`
Expected: exit 0, no output. Fix README.md until it passes.

- [ ] **Step 5: Check commands are verbatim**

For every fenced code block in README.md, confirm each command line appears in `README.html`, in `bootstrap.sh`/`bootstrap.ps1`, or in the file it documents:
```bash
cd ~/.config/mise
git show HEAD:README.html > /tmp/claude-readme-old.html
python3 - <<'EOF'
import re, html, subprocess
md = open('README.md').read()
old = html.unescape(re.sub(r'<[^>]+>', '', open('/tmp/claude-readme-old.html').read()))
src = old + ''.join(open(p).read() for p in ['bootstrap.sh','bootstrap.ps1'])
for block in re.findall(r'```[a-z]*\n(.*?)```', md, re.S):
    for line in block.splitlines():
        l = line.strip()
        if l and not l.startswith('#') and l not in src:
            print('NOT IN SOURCE:', l)
EOF
```
Expected: no output. Anything printed is one of:
- a transcription error: fix it
- a deliberate correction you already verified against the code: note it in the commit message
- an example config snippet under "Adding things": check that it parses (`python3 -c 'import tomllib,sys;tomllib.loads(sys.stdin.read())'`)

- [ ] **Step 6: Lint and commit**

```bash
mise run lint
git add -A README.md .github/workflows/lint.yml .gitignore bootstrap.ps1 dotfiles/wslconfig dotfiles/windows/AppData/Local/warp/Warp/config/settings.toml
git commit -q -m "docs: README.md replaces the README.html console

Plain Markdown covering setup, daily use, adding things and all 32
troubleshooting entries. Drops the toolbelt catalogue (config*.toml and
mise ls are the list), docs/README/, scripts/check-readme.mjs and the CI
readme job."
git push -q
```

---

### Task 3: Rewrite the config*.toml comments

**Files:**
- Modify: `config.toml`, `config.linux.toml`, `config.owned.toml`, `config.host.toml`, `config.native.toml`, `config.wsl.toml`, `config.windows.toml` (comments only)

- [ ] **Step 1: Write the data-identity check**

Save as `/tmp/claude-toml-same.sh`:
```bash
#!/usr/bin/env bash
# Every config*.toml must parse to the same data as on main. Exit 1 on any difference.
set -uo pipefail
cd ~/.config/mise
fail=0
for f in config.toml config.linux.toml config.owned.toml config.host.toml config.native.toml config.wsl.toml config.windows.toml; do
  if ! diff <(git show main:"$f" | python3 -c 'import sys,tomllib,json;print(json.dumps(tomllib.load(sys.stdin.buffer),sort_keys=True,indent=1))') \
            <(python3 -c 'import sys,tomllib,json;print(json.dumps(tomllib.load(open(sys.argv[1],"rb")),sort_keys=True,indent=1))' "$f") >/dev/null; then
    echo "DATA CHANGED: $f"; fail=1
  fi
done
exit $fail
```
And the narrative-marker check:
```bash
rg -n '#[^"]*(final-fix-brief|[Rr]uling [0-9]|\bI[0-9]\b|\bC2\b|\bPR ?[0-9]|controller review|chezmoi|Make-era|Make used|the Make\b|makefile|versions\.mk|inventory §|docs/superpowers|docs/claude/(invariants|file-care)|2026-09-2[0-9])' config*.toml
```
Run both. Expected now: the data check passes (nothing edited yet) and the marker search prints about 60 hits. Both must end at "pass / no output".

- [ ] **Step 2: Rewrite the comments**

Rules:
- Keep each comment that explains a non-obvious *why*; rewrite it as one to three present-tense lines.
- Delete comments that only restate the key/value or narrate history.
- Keep every inline trailing comment on a tool pin that explains an asset choice (musl vs gnu, glibc floor, `bin=`, cosign note). Shorten each to one line.
- Keep the file-map header in `config.toml` (the "which files load" list), updated to present tense.
- Fix the known-false comments:
  - `config.windows.toml:19`: "template for the 12". There are 11 `.tera` sources; say "`template` for the `.tera` sources" without a count.
  - `config.windows.toml:44`: the Linux Zed entry lives in `config.host.toml`, not `config.owned.toml`.
  - `config.owned.toml:68–72`: `settings.json` is merged by `scripts/lib/claude-settings-merge.sh`, and `settings.local.json` is seeded if absent by `tasks/bootstrap`. Neither is a `[dotfiles]` entry, because Claude Code rewrites them. There are no Zed/Warp/WT/Code entries in `config.linux.toml`, so drop that clause.
  - `config.toml:56–57`: the Windows `~/.gitconfig` uses Git Credential Manager, which ships with Git for Windows (a prerequisite `bootstrap.ps1` checks but doesn't install).
  - `config.toml` / `config.owned.toml` / `config.linux.toml` references to `docs/claude/file-care.md` or `docs/claude/invariants.md` → `CLAUDE.md`.
- Don't touch non-comment text, key order, blank-line placement inside arrays or inline tables, or the `post-dotfiles` string.

Example (config.toml, current lines 63–71):
```toml
# Not in chezmoi's Windows-ignore block — Starship's own config already
# deploys to the same relative path on both OSes today. mode = "copy", not
# "symlink" (I4, final-fix-brief.md; broadened by the 2026-09-22
# copy-migration to every entry, not just this one — see ruling 7 in
# config.windows.toml's header comment). Trade-off accepted: editing this
# file needs `wsr` (`mise dot add --changed`) to round-trip, the same as
# every other entry now.
"~/.config/starship.toml" = { source = "dotfiles/config/starship.toml", mode = "copy" }
```
becomes:
```toml
# Same path on both OSes.
"~/.config/starship.toml" = { source = "dotfiles/config/starship.toml", mode = "copy" }
```
and the `[dotfiles]` header of `config.toml` states the repo-wide rule once:
```toml
# [dotfiles]: `template` for .tera sources, `copy` for everything else, never
# symlink (apps on both OSes replace symlinks). Deployed files are independent
# copies: record a live edit back with `wsr` (`mise dot add --changed`), or
# `mise dot add <dir>` for a directory entry. Entries here load on every host,
# so only files meaningful on both OSes belong here.
```
The other files' `[dotfiles]` headers then say only what is specific to that file (e.g. `config.linux.toml`: "Linux, both modes. Directory entries keep `exclude = [\".vendor\", \".gitkeep\"]` so provenance sidecars and placeholders never land in `$HOME`.").

- [ ] **Step 3: Run both checks**

Run: `bash /tmp/claude-toml-same.sh` and the marker `rg` from step 1
Expected: the data check exits 0; the marker search prints nothing.
Also run: `wc -l config*.toml` and record the before/after comment totals (`rg -c '^\s*#' config*.toml`) in the commit message. The target is about 180 comment lines in total, down from 317.

- [ ] **Step 4: Lint and commit**

```bash
mise run lint && mise tasks validate
git add config.toml config.linux.toml config.owned.toml config.host.toml config.native.toml config.wsl.toml config.windows.toml
git commit -q -m "chore(config): present-tense comments in config*.toml

Comments only; every file parses to the same data as main."
git push -q
```

---

### Task 4: Stale references and dead code in scripts, tasks and dotfiles

**Files (modify; each change is comment-level unless marked **code**):**
- `tasks/update:10–13`: reword the comment so no line starts `# MISE` (§3.8 of the spec: `# MISE_ENV …` is parsed as a `#MISE` directive). **Code-adjacent.**
- `tasks/health:4-5` (Make/doctor.sh history), `tasks/health:186` (`I1 (final-fix-brief.md)`)
- `tasks/verify-tools:3` ("the Make macros used to &&-chain")
- `tasks/bootstrap:21-24,33-34,63-64,98-101,106-114,128-131,145` (the `(was run_once_….tmpl)` / `[bootstrap.repos]` / `ruling 5` / `I5, final-fix-brief.md` narrative → present tense)
- `scripts/lib/python-env.sh:57-61`: **code**. Delete the TUI self-heal block (`# Self-heal: remove artifacts…`, `rm -f "$bin_dir/workstation"`, `rm -rf "$HOME/.cache/workstation-tui"`).
- `scripts/lib/mise-env.sh:6` ("chezmoi templates until PR3, Tera after") → "the rc templates render the same value".
- `scripts/lib/vcpkg.sh:11` (`dot_zshrc.tmpl / dot_bashrc.tmpl`) → `dotfiles/zshrc.tera / dotfiles/bashrc.tera`
- `scripts/lib/enable-el-repos.sh:4` (Make-era packages-epel)
- `scripts/lib/claude-settings-merge.sh:3-4,21` (chezmoi/ruling/docs path)
- `scripts/check-templates.sh:4-5,25,47` (chezmoi history, plan path)
- `scripts/check-invariants.sh` comments at 3, 190–191 (repoint `docs/claude/invariants.md` → `CLAUDE.md`, drop the chezmoi clause; the function itself goes in PR 3), 521–526, 679, 774, 995–1010, 1127–1132, 1166, 1197–1201 (a python-env comment sitting above `check_zjstatus_zellij_coupling`; move it above `check_python_env_parity` and drop "Make never runs on Windows"), 1447, 1459 (`tools.mk`)
- `scripts/check-invariants.sh`'s dropped-dnf-names guard (`cockpit-networkmanager`, lowercase `shellcheck`, …) is **not** stale: it stops known-unresolvable names being re-added. Leave it.
- `scripts/bump-versions.sh:147` (`docs/claude/file-care.md` → `CLAUDE.md`)
- `scripts/gen-tool-memory.sh:92` ("Host pins Make used to own")
- `scripts/setup-ccstatusline.sh:6-19,85,89,170-172` (copy-migration/I4/ruling/chezmoi narrative; keep the explanation of how the opt-out works)
- `dotfiles/claude/hooks/secret-guard.sh:9-10` (plan path → "age support was dropped"). Leave the `*/chezmoi/key.txt` match itself for PR 5.
- `dotfiles/zshenv.tera:10,21,24`, `dotfiles/bashrc.tera:11,97,129,136,141,154,164,183,208,221,235,256,287,356,410,602`, `dotfiles/zshrc.tera:203,273,505,559,753` (`dot_*.tmpl` → `*.tera`; "chezmoi-style prompt"/"chezmoi prompted here" → "no built-in prompt")
- `dotfiles/gdbinit.tera:11` ("This is a .tmpl ONLY" → "This is a template ONLY")
- `dotfiles/config/cheat/conf.yml.tera:14` (`seeded by run_once_seed-cheat-community.sh.tmpl` → `seeded by tasks/bootstrap`)
- `dotfiles/config/zellij/themes/catppuccin-mocha-mauve.kdl:6` (`dot_zshrc.tmpl` → `zshrc.tera`)
- `dotfiles/local/bin/.vendor:27` (`dot_zshrc.tmpl + dot_bashrc.tmpl` → `zshrc.tera + bashrc.tera`)
- `dotfiles/windows/AppData/Roaming/nushell/config.nu.tera:79,120,270`: 79 and 120 are comments; 270 is **code**, the `-Reinstall` completion description string `"wipe the cloned repo + chezmoi config, bootstrap fresh"` → `"wipe the cloned repo (incl. config.local.toml), bootstrap fresh"`.
- `dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera:60,101`
- `bootstrap.ps1:2121` ("the Linux side's pipe.sh" → "the Linux side's `curl -fsSL … | bash`"), `bootstrap.ps1:2195-2197`: **code**, delete the TUI `workstation.cmd` self-heal (comment + `Remove-Item` line). `bootstrap.ps1:1250`: add the comment `# First-apply marker; the name predates mise and stays so existing hosts don't re-force.` above `$MigratedMarker`.
- `PSScriptAnalyzerSettings.psd1`: rule-exclusion comments name `Remove-HostEntry`, `Read-Hosts`, `Show-Hosts` (none exist). Use current examples: `Update-SessionPath`, `Add-ToUserPath` for ShouldProcess; `Get-SshLauncherHosts`, `Invoke-CheckForUpdates` for singular nouns. Keep "Singularizing would collide with the built-in Read-Host" only if still true; otherwise drop it.
- `.gitleaks.toml`: header lines 4–8 ("docs-heavy, age-encrypted repo", "the age identity"). Delete the `'''\.age$'''` allowlist entry and its comment, the `'''(^|/)README\.html$'''` entry, and the `node_modules/` entry with its 3-line comment.

**Interfaces:** none (no names change).

- [ ] **Step 1: Write the failing checks**

```bash
cd ~/.config/mise
# 1. stale-reference scan over surviving code (expected hits listed below are allowed)
rg -n --hidden -g '!.git/' -g '!.superpowers/' -g '!docs/superpowers/**' -g '!CLAUDE.md' -g '!docs/claude/**' \
   -g '!.claude/memory/**' -g '!.claude/settings.local.json' -g '!config*.toml' -g '!*.lock' -g '!locks/**' \
   -g '!dotfiles/config/zsh/plugins/**' -g '!dotfiles/config/gdb/gef.py' -g '!dotfiles/local/bin/batpipe' \
   '\bchezmoi\b|\.tmpl\b|makefile/|Make-era|Make used|the Make\b|Make macros|Make `doctor`|Make never|versions\.mk|tools\.mk|packages\.mk|workstation-tui|workstation TUI|run_once|final-fix-brief|[Rr]uling [0-9]|docs/superpowers/(plans|specs)/20|docs/claude/(invariants|file-care)|README\.html'
# 2. the #MISE parse bug
mise tasks validate 2>&1 | rg -c 'unsupported spec key'
```
Expected now: scan 1 prints ~70 lines; check 2 prints `1`.
Allowed hits after the task (don't "fix" these):
- `dotfiles/claude/hooks/secret-guard.sh`: the `*/chezmoi/key.txt` match and its deny message (PR 5)
- `.claude/hooks/test-hooks.sh:88,96` (PR 5)
- `scripts/lib/zellij-plugin.sh` (PR 3)
- `bootstrap.ps1` lines inside `Install-PortableTool`, `Invoke-MiseRuntimes`, `Invoke-CheckForUpdates` and `Get-LatestGitTag` (PR 4)
- `dotfiles/windows/AppData/Roaming/Code/User/settings.json` `ms-vscode.makefile-tools` (a VS Code extension id)
- `docs/superpowers/specs/2026-09-29-simplify-design.md` and `docs/superpowers/plans/2026-09-29-simplify-*.md`

- [ ] **Step 2: Make the edits listed under Files**

For each `.tera` file, edit comments only (lines starting `#` in shell templates, `//` in KDL, and `{# … #}` if present). After editing, render-check them in Step 4.

- [ ] **Step 3: Re-run the checks**

Expected: scan 1 prints only the allowed hits; check 2 prints `0`.

- [ ] **Step 4: Behaviour checks**

```bash
cd ~/.config/mise
mise run lint                         # shellcheck, shfmt, LF/0755, BOM, gitleaks, parity, …
bash scripts/check-templates.sh       # all 11 templates render + syntax-check for all 4 token sets
mise tasks validate                   # no warnings
bash -n scripts/lib/python-env.sh tasks/bootstrap tasks/update tasks/health
```
Expected: all pass. Then parse-check `bootstrap.ps1` with Windows PowerShell (read-only interop probe; no pwsh on this host):
```bash
cp bootstrap.ps1 /mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/bs-parse.ps1
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
  'Set-Location $env:USERPROFILE; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\bs-parse.ps1",[ref]$null,[ref]$e); if($e){$e|%{$_.ToString()}; exit 1}else{"parse OK"}' | tr -d '\r'
```
Expected: `parse OK`.

- [ ] **Step 5: Secrets scan without the removed allowlist entries**

Run: `mise run secrets`
Expected: `no leaks found`. If a finding appears in a now-unlisted path, report it; don't re-add a blanket allowlist.

- [ ] **Step 6: Commit and push**

```bash
git add -A tasks scripts dotfiles bootstrap.ps1 PSScriptAnalyzerSettings.psd1 .gitleaks.toml
git commit -q -m "chore: drop stale history from comments; remove TUI self-heal leftovers

Comment rewrites to present tense across tasks/, scripts/, dotfiles/ and
bootstrap.ps1; fixes the tasks/update comment mise parsed as a #MISE
directive; deletes the removed TUI's self-heal code on both OSes; drops
dead names from PSScriptAnalyzerSettings and dead .gitleaks allowlist
entries."
git push -q
```

---

### Task 5: CLAUDE.md holds the rules; fold in invariants.md and file-care.md

**Files:**
- Rewrite: `CLAUDE.md` (the full text is below)
- Delete: `docs/claude/invariants.md`, `docs/claude/file-care.md`
- Modify: `docs/claude/verification.md`

- [ ] **Step 1: Record the size baseline (it fails the target)**

Run: `wc -c CLAUDE.md docs/claude/*.md`
Expected now: CLAUDE.md about 45,380 bytes; total about 219,000 bytes. Target: CLAUDE.md ≤ 12,500 bytes, `docs/claude/` total ≤ 20,000 bytes.

- [ ] **Step 2: Write the new CLAUDE.md**

Replace the file with exactly this content, then re-verify every factual claim against the code before committing. If something is false, fix the sentence and note the fix in the commit message.

````markdown
# CLAUDE.md

`workstation` provisions Linux hosts (owned or shared) and one Windows host with mise: tools
(`[tools]`), host state (`[bootstrap.*]`, applied by `mise bootstrap`), and dotfiles (`[dotfiles]`,
`mise dot`). This checkout **is** mise's global config dir: `~/.config/mise`, or
`%USERPROFILE%\.config\mise` on Windows. User docs: `README.md`. Verification recipes:
`docs/claude/verification.md`.

## Working rules

- **Memory:** project memories go in `.claude/memory/<slug>.md` plus a one-line entry in
  `.claude/memory/MEMORY.md` (committed). Never write to `~/.claude/projects/*/memory/`
  (`memory-routing-guard.sh` denies it). Use a host-global location only when the user asks for
  cross-project scope, and say so in the reply.
- **History first:** before changing a tricky area, run `git log --oneline -- <path>` and
  `git log -p -S '<symbol>' -- <path>`. Most rules below exist because the opposite broke.
- **Docs travel with behaviour:** a user-facing change updates `README.md` in the same commit.
  Claude-internal files (`CLAUDE.md`, `docs/claude/`, `.claude/`) and version bumps don't need
  README changes.
- **The checkout is live config:** `mise use -g`, `mise settings set`, `mise dot add`/`wsr`, `wse` and
  `mise bootstrap` write tracked files here. Commit or revert before moving on, because `wsu`'s
  `git pull --ff-only` fails on a dirty tree.
- **Checks:** `mise run lint` (`scripts/check-invariants.sh`, also the pre-commit hook and CI) and
  `bash scripts/check-templates.sh`. When a new rule can be checked mechanically, add a check.
- **Task names** must not collide with mise built-ins (`mise fmt` is built in, so ours is
  `mise run fmt`).

## Layout

| File | Loads when `MISE_ENV` has | Holds |
|---|---|---|
| `config.toml` | always | uv, python, `[vars]` pins, dotfiles for both OSes |
| `config.linux.toml` | `linux` | Linux toolbelt (both modes), Linux dotfiles, `post-tools`/`post-dotfiles` hooks, the pueued service |
| `config.owned.toml` | `owned` | owned-host tools on both OSes (node + LSP servers, go, …), `~/.claude` dotfiles, ccstatusline |
| `config.host.toml` | `host` | Linux owned host state: dnf batch, EPEL/CRB `pre-packages` hook; gdb, herdr, zed dotfiles |
| `config.native.toml` | `native` | non-WSL owned: NFS client packages |
| `config.wsl.toml` | `wsl` | `/etc/wsl.conf` via `[bootstrap.files]` |
| `config.windows.toml` | `windows` | Windows-only dotfiles |
| `config.local.toml` | always, git-ignored | per-host `[vars] mode/name/email` and overrides |

Token sets come only from `scripts/lib/mise-env.sh`:
- shared: `linux`
- owned WSL: `linux,owned,host,wsl`
- owned native: `linux,owned,host,native`
- Windows: `windows,owned`

Locks: `mise.lock`, `mise.linux.lock`, `mise.owned.lock`, plus `locks/**` sidecars. Global tasks live in
`tasks/`. mise always discovers them from the real home; `MISE_CONFIG_DIR` doesn't redirect them.

## Invariants

**Provisioning**
- `bootstrap.sh` is a thin seed. Its only pin is `MISE_VERSION`/`MISE_SHA256`. Tools are mise pins,
  host state is `[bootstrap.*]` tables, and procedural steps are tasks in `tasks/`. Don't add install
  logic to `bootstrap.sh` or new provisioning scripts.
- Shared hosts load no host state. Every sudo-needing table lives in `config.host.toml`,
  `config.native.toml` or `config.wsl.toml`, and those files declare no `[tools]`.
- `[bootstrap.*]` and `[dotfiles]` tables merge by union across loaded files. Declare each item once,
  in the file whose token gates it.
- Hooks are `mise run <task>`, because mise treats hook strings as opaque shell. The one exception is
  the literal `post-dotfiles` chmod line in `config.linux.toml`. mise runs hooks under
  `sh -o errexit`, so each of its commands keeps its own `|| true`.
- dnf installs everything in one batch, so a single unresolvable name fails the whole run. Only add
  EL9-verified names. `ShellCheck` is capitalised; `fswatch`, `entr` and `cockpit-networkmanager`
  don't resolve.
- No `[bootstrap.linux.firewall]` table: it makes `mise bootstrap plan`/`status` re-exec with sudo,
  which breaks `mise run health`. No `[bootstrap.user] login_shell` either: it needs `chsh`.
  `bootstrap.sh`'s `set_login_shell` uses `sudo usermod`.
- `[vars]` pins (`python_version`, `nerd_font_version`, `vcpkg_version`, `zjstatus_zellij_floor`) reach
  tasks through `#MISE env={X="{{ vars.x }}"}`.
- Never hand-edit `mise*.lock` or `locks/**`. Regenerate them with `mise lock` (recipe in
  `scripts/bump-versions.sh` and `docs/claude/verification.md`).
- `tasks/verify-tools` (the `post-tools` hook) checks that every mise-installed ELF can run on this
  host. Static binaries must pass. A failure means pinning an explicit `github:` `asset_pattern`.
- vcpkg stays a task: `[bootstrap.repos]` can't shallow-clone or update. The C/C++ toolbelt
  deliberately spans dnf, mise and vcpkg; don't unify it.
- `</dev/tty` reads in `bootstrap.sh` and `tasks/bootstrap` are load-bearing under `curl | bash`.
- WSL detection is `is_wsl()` (in `bootstrap.sh` and `scripts/lib/mise-env.sh`, which must agree).

**Mode and `MISE_ENV`**
- The mode is `owned` or `shared`, saved as `vars.mode` in `config.local.toml`. It comes from the
  saved value, then `WORKSTATION_MODE`, then a prompt. Windows is always owned.
- `tasks/update` and `tasks/health` derive `MISE_ENV` from the saved mode, never from the calling
  shell: a stale value makes `mise prune` remove tools.
- The `MISE_ENV` Tera conditional is byte-identical in `dotfiles/zshenv.tera`, `dotfiles/bashrc.tera`
  and `dotfiles/config/environment.d/10-mise.conf.tera` (checked).
- The pueued unit gets `MISE_ENV` from the systemd user manager, not from the unit itself.
- Every `ws*` command pins `mise -C` to the home directory. mise finds its config by walking up from
  the cwd, so an unpinned run from `/mnt/c/...` manages the wrong checkout.

**Dotfiles**
- `template` for the `.tera` sources, `copy` for everything else, never `symlink`/`symlink-each`.
- One undefined variable or failing `exec()` in any template aborts the whole apply, so guard every
  `vars.*` with `is defined` or `default()`.
- Directory `copy` entries keep `exclude = [".vendor", ".gitkeep"]`. `copy` on a directory leaves
  unmanaged files in it alone.
- Deployed files are independent copies, so a live edit under `$HOME` doesn't reach the repo on its
  own:
  - `wsr` (`mise dot add --changed`) records file entries but skips directory entries.
  - For a directory entry, run `mise dot add <the directory>`. It replaces the source directory; it
    doesn't merge.
  - `mise dot apply` silently overwrites edits that were never recorded. `wsa` checks
    `mise dot status` for drift and asks first.
- Disabling an inherited entry needs `enabled = false` **and** a repeated `mode`.
- A host's first apply needs `--force-dotfiles`. `bootstrap.sh` and `bootstrap.ps1` pass it only while
  `~/.local/state/workstation/dotfiles-migrated` is absent.
- The `post-dotfiles` hook is the only thing that sets these modes:
  - `~/.ssh` and `~/.claude`: 700
  - `~/.ssh/config`: 600
  - the source `dotfiles/ssh/config.tera`: 600, so mise stops reporting a mode diff
- `~/.claude/settings.json` isn't a dotfile. `scripts/lib/claude-settings-merge.sh` (on Windows,
  `Invoke-ClaudeSettingsMerge` with the same jq filter) merges three layers:
  `settings.seed.json` (only where a key is absent) → the live file → `settings.enforced.json`
  (always wins). Change cross-host keys in the enforced file.
- `/etc` files come from `configs/` via `[bootstrap.files]`. Today that is only `/etc/wsl.conf`, which
  keeps `appendWindowsPath=false`. `[dotfiles]` owns `$HOME` only.
- `dotfiles/ssh/config.tera` gates SSH multiplexing (`ControlMaster`…) out on Windows, whose OpenSSH
  can't multiplex.
- zsh plugin order in `dotfiles/zshrc.tera`: fzf-tab after `compinit` → autosuggestions →
  syntax-highlighting → history-substring-search last. `bashrc.tera` carries PARITY NOTEs for what
  bash can't do.
- The fleet runs `TERM=xterm-256color` on purpose.
- `~/.claude/CLAUDE.md` is deployed from `dotfiles/claude/CLAUDE.md`. Its TOOLS block is generated.

**Windows**
- Never render Windows targets with the Linux mise: `os()` reflects the OS of the binary that is
  running.
- `bootstrap.ps1` applies dotfiles with `mise bootstrap --only dotfiles,tools`.
- Scripts never write Windows Terminal's tracked `settings.json`. SSH launchers go to a WT fragment,
  and Warp's `workstation-*.toml` tab configs are runtime artifacts.
- Warp is the primary terminal. Windows Terminal is the compatibility one: it keeps the
  default-terminal role and Nushell.
- The rc files' `TERM_PROGRAM != WarpTerminal` guards must never wrap a plugin `source`
  (`check_warp_guards`).

**zellij**
- `copy_command` stays unset, because OSC 52 is the only clipboard path over SSH. `web_server` stays
  off.
- Don't add `zellij-autolock` or any unmaintained plugin without testing it against the pinned
  zellij. Judge whether a plugin loaded from zellij's log, not `dump-layout`.

## File care

- **LF + git mode 100755:**
  - `scripts/*.sh`, `scripts/lib/*.sh`, every `tasks/*` file (mise silently skips a non-executable
    task), `.claude/hooks/*.sh`, `.githooks/pre-commit`
  - the executable dotfiles: `dotfiles/claude/hooks/*.sh`, `dotfiles/claude/notify.sh`,
    `dotfiles/local/bin/{batpipe,winterop}`
  - Repair with `sed -i 's/\r$//' <f>` and `git update-index --chmod=+x <f>`.
  - First-party shell must be `shfmt -i 2`-clean (`mise run fmt`) and gitleaks-clean.
  - Quote bash associative-array keys: shfmt rewrites an unquoted `[a-b]` as arithmetic.
- **Every other file under `dotfiles/` is 100644** (`check_dotfiles_mode`): `copy`/`template`
  propagate the source's exec bit into `$HOME`.
- **UTF-8 with BOM:** `bootstrap.ps1` and `scripts/install-nerd-fonts.ps1` (PowerShell 5.1 needs it).
  - Restore with `[IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($true))`.
  - Inside double-quoted strings write `${name}:`; a bare `$name:` is a drive-qualified parse error.
- **Vendored (re-download at the pinned tag, never hand-edit):**
  - the five zsh plugin dirs and `zsh-shift-select.zsh`
  - `_cht.sh`, a rolling snapshot
  - `dotfiles/local/bin/batpipe`: re-apply the 2-line patch recorded in its `.vendor`
  - `dotfiles/config/gdb/gef.py`: stay on GEF 2024.06 while the fleet is EL9, because newer GEF
    needs Python ≥ 3.10
  - Each `.vendor` sidecar records provenance.
- **Generated blocks (never edit inside):**
  - `<!-- TOOLS:START/END -->` in `dotfiles/claude/CLAUDE.md`, from `scripts/gen-tool-memory.sh`
  - `# CCSTATUSLINE-OPTOUT:START/END` in `config.local.toml`, from `scripts/setup-ccstatusline.sh`
- **Parity pairs (change them together):**
  - `zshrc.tera` ↔ `bashrc.tera`
  - `zshenv.tera` ↔ the shims block in `bashrc.tera`
  - the Nushell `config.nu.tera` ↔ PowerShell profile `ws*`/`g*` aliases
  - `PY_LIBS` in `scripts/lib/python-env.sh` ↔ `$PythonLibs` in `bootstrap.ps1`
  - `Invoke-CurlRequest` in `bootstrap.ps1` ↔ `scripts/install-nerd-fonts.ps1`
  - script flags ↔ their completions (`_bootstrap.sh`, `completions.bash`, `config.nu.tera`'s flag
    record)
- **Values recorded in several places (checked by `check_version_pins` and friends):**
  - mise: `bootstrap.sh`, `bootstrap.ps1`, `min_version`
  - python: `vars`, `tools.python`, `$PythonEnvVersion`
  - Nerd Font: `vars`, the `font.sh` checksum case, `install-nerd-fonts.ps1`
  - jq, gh, helix, opencode, omp and the DevToys CLI: `config*.toml` ↔ `$PortableTools`
  - `VCPKG_ROOT`: the rc files ↔ `tasks/vcpkg`
  - zellij ≥ `zjstatus_zellij_floor`; TypeScript major ≤ 5
  - `scripts/bump-versions.sh` must cover each through `PS1_NAME`, `COUPLED_AUTO` or `EXCLUDE`.
- **Never hand-edit:**
  - deployed `$HOME` targets: edit the source, e.g. via `wse`
  - `/etc` copies
  - lock files

## Hooks

Repo hooks (`.claude/settings.json`). After editing any of them, re-run
`bash .claude/hooks/test-hooks.sh`.
- `post-edit-guard.sh` repairs CRLF, the exec bit and `.ps1` BOMs after an edit.
- `parity-reminder.sh` names the other half of a parity pair.
- `memory-routing-guard.sh` denies writes to the home-dir memory path.
- `sync-tool-memory.sh` regenerates the TOOLS block after a `config*.toml` edit.
- `session-context.sh` (SessionStart) reports dotfiles drift, host and mode, WSL interop, and whether
  the check tools are ready.
- `session-end-notify.sh` (SessionEnd) shows a desktop notification when the repo or dotfiles are left
  dirty.

Global hooks (`dotfiles/claude/hooks/` → `~/.claude/hooks/`, wired by `settings.enforced.json`):
- `secret-guard.sh` denies reading or editing private keys, `*.pem` and `*.key`.
- `dangerous-command-guard.sh` denies fork bombs, raw-device writes and `mkfs`. It asks before
  `rm -rf` of `/` or `~`, `curl | bash`, and force-push.
- Both match command *text*, so a commit message that mentions a pattern gets screened too.
````

- [ ] **Step 3: Delete the folded docs and trim verification.md**

```bash
git rm -q docs/claude/invariants.md docs/claude/file-care.md
```
In `docs/claude/verification.md`:
- Replace lines 3–4 (the "split out of CLAUDE.md" blurb) with: `> Recipes for verifying a change, grouped by subsystem. The rules they protect are in CLAUDE.md.`
- Delete the bullets that are stale or point at deleted files:
  - the README console bullet (`README.html` + jsdom, line 12)
  - `./bootstrap.sh --dev`/`--full` (line 25)
  - `git diff README.html …` (line 34)
  - the Docker/Cockpit tombstone (line 37)
- Line 110: replace "per the 2026-07-31 spec's documented fallback" with "(the fallback is to drop the action and its README row)".
- Line 115: `record the real ceiling in file-care.md` → `record the real ceiling in CLAUDE.md`.
- Rewrite any remaining sentence that narrates history, or names a Make/chezmoi mechanism, in the present tense.

- [ ] **Step 4: Nothing true was lost**

Go through every bullet headline of the *old* files one by one: `git show main:CLAUDE.md` (the "Load-bearing invariants" and "Files Claude should be careful with" sections), `git show main:docs/claude/invariants.md` and `git show main:docs/claude/file-care.md`. For each, record one of:
- covered by `<CLAUDE.md line>`
- covered by `README.md` (user-facing how-to)
- no longer true: `<why>` (e.g. describes Make, chezmoi, Docker or a retired incident)
- too detailed for CLAUDE.md, lives in the code comment at `<file:line>`

Put the table in the task report. Any headline with none of these gets a one-liner in CLAUDE.md.

- [ ] **Step 5: Size and reference checks**

```bash
wc -c CLAUDE.md docs/claude/*.md          # CLAUDE.md ≤ 12,500; docs/claude total ≤ 20,000
rg -n 'docs/claude/(invariants|file-care)' --hidden -g '!.git/' -g '!.superpowers/' -g '!docs/superpowers/**'
```
Expected: sizes within target; the `rg` prints nothing.

- [ ] **Step 6: Commit and push**

```bash
mise run lint
git add -A CLAUDE.md docs/claude
git commit -q -m "docs(claude): CLAUDE.md carries the current rules; fold and delete invariants.md and file-care.md

Keeps every rule that is still true as a one-liner, drops the history,
trims verification.md to recipes that still apply."
git push -q
```

---

### Task 6: Memory, local allowlist, application list

**Files:**
- Delete: `.claude/memory/project-mise-everything.md` (its still-true rules are now in CLAUDE.md)
- Modify:
  - `.claude/memory/project-mise-runtimes-shipped.md`: keep only the three Windows interop gotchas. New description: "Windows mise-via-interop gotchas: Set-Location before mise, winget long-path uninstall, Sort-Object order differs 5.1 vs 7". Drop the spec path and the PR history.
  - `.claude/memory/project-workstation-tui-removed.md`: keep the decision, the reason quote, "DO NOT re-propose a TUI", and "python-env stays". Drop the removal inventory and the self-heal notes (that code is gone after Task 4).
  - `.claude/memory/project-warp-coexist-shipped.md`: drop the `docs/superpowers/specs/...` sentence. The R1 probe instructions stay; they point at `docs/claude/verification.md` §Warp, which still exists.
  - `.claude/memory/project-wsl-appendwindowspath-false.md`: the last bullet becomes "Documented in README.md → Troubleshooting".
  - `.claude/memory/feedback-app-list-means-manual-list.md`: "No README.html or CLAUDE_CHANGELOG.md updates" → "No README.md update".
  - `.claude/memory/project-bootstrap-owned-shared.md`: replace any `[[project-mise-everything]]` link with a pointer to CLAUDE.md.
  - `.claude/memory/MEMORY.md`: rewrite as one line per file, each ≤ 200 characters. Remove the deleted file's entry.
  - `.claude/settings.local.json`: remove the allowlist entries naming removed tools or paths (below).
  - `docs/windows/application_list.md`: keep the intro's Git sentence and `## Manual installs` only; delete `## Auto-installed by bootstrap.ps1` and the intro's first sentence about it. Remove "Go, Python" from the "C, C++, Go, Python, Bun" row (mise installs Go and Python on Windows): it becomes "C, C++, Bun".

- [ ] **Step 1: Write the failing checks**

```bash
cd ~/.config/mise
# a) memory references to deleted things
rg -n 'docs/superpowers/|CLAUDE_CHANGELOG|README\.html|docs/claude/(invariants|file-care)|\[\[project-mise-everything\]\]' .claude/memory
# b) every [[link]] resolves to a memory file's name
python3 - <<'EOF'
import re,glob,os
names={}
for p in glob.glob('.claude/memory/*.md'):
    m=re.search(r'^name:\s*(\S+)',open(p).read(),re.M)
    if m: names[m.group(1)]=p
for p in glob.glob('.claude/memory/*.md'):
    for l in re.findall(r'\[\[([^\]]+)\]\]',open(p).read()):
        if l not in names: print('DANGLING',p,l)
idx=open('.claude/memory/MEMORY.md').read()
for f in re.findall(r'\]\(([^)]+\.md)\)',idx):
    if not os.path.exists('.claude/memory/'+f): print('INDEX DEAD',f)
for p in glob.glob('.claude/memory/*.md'):
    b=os.path.basename(p)
    if b!='MEMORY.md' and b not in idx: print('NOT INDEXED',b)
for line in idx.splitlines():
    if line.startswith('- ') and len(line)>200: print('LONG INDEX LINE',len(line),line[:60])
EOF
# c) stale local allowlist entries
jq -r '.permissions.allow[]' .claude/settings.local.json | rg -i 'wezterm|chezmoi|^Bash\(make list'
```
Expected now: (a) prints about 6 lines, (b) prints the `LONG INDEX LINE` rows (most of them), (c) prints 7 entries.

- [ ] **Step 2: Make the edits**

For `.claude/settings.local.json`:
```bash
jq '.permissions.allow |= map(select(test("(?i)wezterm|chezmoi|^Bash\\(make list") | not))' .claude/settings.local.json > /tmp/claude-sl.json \
  && mv /tmp/claude-sl.json .claude/settings.local.json
```
Check the file still parses and lost exactly 7 entries: `jq '.permissions.allow|length' .claude/settings.local.json` → `48`.

Memory file bodies: keep frontmatter shape (`name`, `description`, `metadata.type`).

- [ ] **Step 3: Re-run the checks**

Expected: (a) nothing, (b) nothing, (c) nothing.

- [ ] **Step 4: Commit and push**

```bash
git add -A .claude/memory .claude/settings.local.json docs/windows/application_list.md
git commit -q -m "chore(claude): prune stale memory and allowlist entries; manual-only application list"
git push -q
```

---

### Task 7: Whole-branch verification and the PR

**Files:** none new.

- [ ] **Step 1: Spec PR 1 verification**

```bash
cd ~/.config/mise
mise run lint
bash scripts/check-templates.sh
mise tasks validate 2>&1 | rg -c 'WARN' || true      # expect 0
rg -n --hidden -g '!.git/' -g '!.superpowers/' 'final-fix-brief|README\.html|CLAUDE_CHANGELOG|docs/claude/(invariants|file-care)|docs/superpowers/(plans|specs)/20' \
   | rg -v '2026-09-29-simplify'
bash /tmp/claude-toml-same.sh
bash /tmp/claude-readme-check.sh
```
Expected: lint and templates pass; 0 warnings; the reference scan prints only the lines inside the simplify spec/plan; both scratch checks exit 0.

- [ ] **Step 2: No provisioning drift**

Compare `mise bootstrap plan` for `main` and this branch, both from clean worktrees, so the local
`config.local.toml` affects neither side:
```bash
cd ~/.config/mise
git worktree add -q /tmp/claude-wt-main main
git worktree add -q /tmp/claude-wt-branch HEAD
for e in linux linux,owned,host,wsl linux,owned,host,native; do
  for side in main branch; do
    (cd /tmp/claude-wt-$side && MISE_CONFIG_DIR=/tmp/claude-wt-$side MISE_ENV=$e mise bootstrap plan --json) \
      | jq -S 'del(..|.source?)' > /tmp/claude-plan-$side-$e.json
  done
  diff -q /tmp/claude-plan-main-$e.json /tmp/claude-plan-branch-$e.json && echo "plan identical: $e"
done
git worktree remove /tmp/claude-wt-main; git worktree remove /tmp/claude-wt-branch
```
Expected: `plan identical` for all three token sets. The `.source` paths differ only by checkout root,
so they're dropped before comparing. Dotfile *content* changes (comments in `.tera` sources) are
expected and aren't part of the plan output.

- [ ] **Step 3: Open the PR**

```bash
gh pr create --base main --head refactor/simplify-purge \
  --title "Simplify (1/5): purge history, README.md, lean CLAUDE.md" \
  --body "$(cat <<'EOF'
First of five PRs from docs/superpowers/specs/2026-09-29-simplify-design.md. No provisioning change.

- Deletes docs/superpowers history (109 files) and CLAUDE_CHANGELOG.md
- README.md replaces README.html + docs/README/ + the jsdom CI job
- CLAUDE.md now carries only current rules; invariants.md and file-care.md folded in and deleted
- config*.toml comments rewritten to present tense (parsed data identical to main)
- Stale comments/leftovers removed in tasks/, scripts/, dotfiles/, bootstrap.ps1; fixes the tasks/update comment mise parsed as a #MISE directive
- Memory and local allowlist pruned; application_list.md is manual-only

Verification: mise run lint, scripts/check-templates.sh, mise tasks validate (no warnings), TOML data identity vs main, mise bootstrap plan identical for all three Linux token sets, bootstrap.ps1 parse check under Windows PowerShell.

After merging: wsa on each host picks up the comment-only changes to deployed dotfiles (zshrc/bashrc/zshenv/gdbinit/cheat conf/zellij theme/wslconfig/Warp settings/Nushell and PowerShell profiles).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01KC7PnCUgH75cjvuryy91Mp
EOF
)"
```
Expected: a PR URL. Report it; the user merges.
