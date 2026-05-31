# Doc & Build Tooling (man / info / pkg-config / tldr) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `man`/`info`/`pkg-config` guaranteed by the install scripts (correct EL9 package names) and make `tldr` work out-of-the-box with chezmoi-tracked config, plus colorized man pages via `bat`.

**Architecture:** Four independent edits to an existing Make + chezmoi repo: (1) `packages.mk` package-list additions; (2) a `bat`-based `MANPAGER` block in the zsh/bash rc parity pair; (3) a new tracked tealdeer `config.toml` (`auto_update`) plus a Linux-gated `run_once` chezmoi script that seeds the page cache; (4) internal docs (`CLAUDE.md` + `CLAUDE_CHANGELOG.md`). README.html is intentionally left unchanged (see "Docs decision" below).

**Tech Stack:** GNU Make, chezmoi (Go templates, `.chezmoiscripts`), zsh/bash, tealdeer, AlmaLinux 9 / dnf.

**Spec:** `docs/superpowers/specs/2026-05-31-doc-tooling-design.md`

**Conventions for every task:** Work on `main` (never branch). After each task's commit, `git push origin main` immediately. This repo has no unit-test framework — "verification" uses the repo's own idioms (`make -n`, CRLF/`file` checks, grep-parity, `chezmoi execute-template`, isolated sandbox runs). Each task ends only after its verify step shows the expected output.

**Docs decision (resolved during planning):** README.html needs no change — verified the only README hits are unrelated ("system info" banner text, chezit's "Info" tab, and the existing tldr chip whose text makes no cache/config claim). The package adds are plumbing and the MANPAGER/tldr changes add no command or operating step, matching prior "No README" changelog rows (ncurses, dircolors, theme). A single `CLAUDE_CHANGELOG.md` row is still appended (Task 4).

---

### Task 1: Add doc/build packages to `packages.mk`

**Files:**
- Modify: `makefile/packages.mk` (core list `LINUX_PACKAGES` ~lines 17-29; optional list `LINUX_OPTIONAL_PACKAGES` ~lines 42-51)

- [ ] **Step 1: Add `pkgconf-pkg-config` to the core list**

The current core list ends with `zsh` and `ncurses`. Change the tail of `LINUX_PACKAGES` from:

```make
  zsh \
  ncurses
```

to:

```make
  zsh \
  ncurses \
  pkgconf-pkg-config
```

Rationale comment is not strictly required inline, but if adding one, place it just above the `pkgconf-pkg-config` line:

```make
  ncurses \
  pkgconf-pkg-config
  # pkgconf-pkg-config provides /usr/bin/pkg-config on EL9 (the literal
  # `pkg-config` package is obsoleted there). Build prereq alongside gcc/make.
```

> Note: a `\` continuation must be the LAST character on its line — do NOT put the comment between `ncurses \` and the next item on the same continued logical line. Put `pkgconf-pkg-config` as the final list item (no trailing `\`), then the comment on the following physical line is fine because the list has ended. Simplest safe form (use this):

```make
LINUX_PACKAGES := \
  git \
  curl \
  wget \
  unzip \
  tar \
  make \
  gcc \
  openssl-devel \
  python3 \
  python3-pip \
  zsh \
  ncurses \
  pkgconf-pkg-config
```

- [ ] **Step 2: Add `man-db man-pages info` to the optional list**

Add one grouped line to `LINUX_OPTIONAL_PACKAGES`. Insert it right after the `inotify-tools fswatch` line so it sits with the other system utilities:

Change:

```make
  inotify-tools fswatch \
  rsync vim-common vim-enhanced \
```

to:

```make
  inotify-tools fswatch \
  man-db man-pages info \
  rsync vim-common vim-enhanced \
```

(`man-db` = the `man`/`apropos`/`whatis` binaries; `man-pages` = base Linux man pages; `info` = the GNU info reader. Deliberately NOT `texinfo`, which is not in EL9 base repos and is unneeded to *read* info docs.)

- [ ] **Step 3: Verify the core-list addition appears in the dry-run recipe**

Run:
```bash
cd makefile && make -n MODE=dev packages-core | grep -o 'pkgconf-pkg-config'
```
Expected output: `pkgconf-pkg-config` (the make variable expands into the printed `for pkg in …` recipe).

- [ ] **Step 4: Verify the optional-list additions appear**

Run:
```bash
cd makefile && make -n MODE=dev packages-optional | grep -oE 'man-db|man-pages|\binfo\b' | sort -u
```
Expected output (three lines):
```
info
man-db
man-pages
```

- [ ] **Step 5: Verify prod scope still skips packages**

Run:
```bash
cd makefile && make -n MODE=prod provision | grep -c 'pkgconf-pkg-config'
```
Expected output: `0` (prod sets `INSTALL_PACKAGES=false`; the `packages` target is the skip-message no-op).

- [ ] **Step 6: Verify tool listing is unaffected**

Run:
```bash
cd makefile && make list MODE=dev >/dev/null && echo OK
```
Expected output: `OK` (packages don't appear in `make list`; this just confirms the makefile still parses).

- [ ] **Step 7: Commit and push**

```bash
git add makefile/packages.mk
git commit -m "feat(packages): guarantee pkg-config (core) + man-db/man-pages/info (optional)

EL9: pkgconf-pkg-config provides /usr/bin/pkg-config (literal pkg-config
is obsoleted); man-db/man-pages/info are the man tooling + base man pages
+ GNU info reader (not texinfo, which is CRB-only and not needed to read).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

### Task 2: `bat`-based `MANPAGER` in the zsh/bash parity pair

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl:41`
- Modify: `chezmoi/dot_bashrc.tmpl:41`

Both files currently have the identical line `export MANPAGER="less"` in the `--- Core env ---` block (zsh line 41; bash line 41). They MUST be edited identically in the SAME commit (parity-pair invariant).

- [ ] **Step 1: Replace the MANPAGER line in `chezmoi/dot_zshrc.tmpl`**

Replace:
```sh
export MANPAGER="less"
```
with:
```sh
# Colorized man pages via bat when available; plain less otherwise.
if command -v bat &>/dev/null; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT="-c"
else
  export MANPAGER="less"
fi
```

- [ ] **Step 2: Replace the MANPAGER line in `chezmoi/dot_bashrc.tmpl` (identical block)**

Replace the identical `export MANPAGER="less"` line with the exact same block as Step 1 (byte-for-byte identical — `&>/dev/null` is valid in both zsh and bash).

- [ ] **Step 3: Verify the two blocks are byte-identical (parity)**

Run:
```bash
diff <(grep -A5 'Colorized man pages via bat' chezmoi/dot_zshrc.tmpl) \
     <(grep -A5 'Colorized man pages via bat' chezmoi/dot_bashrc.tmpl) \
  && echo "PARITY OK"
```
Expected output: `PARITY OK` (no diff lines).

- [ ] **Step 4: Verify neither file gained CRLF line endings**

Run:
```bash
file chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
```
Expected: neither line contains "CRLF" / "with CRLF line terminators". (If it does: `sed -i 's/\r$//' <file>`.)

- [ ] **Step 5: Verify the rendered shell body parses (template-stripped)**

The files are `.tmpl`; strip Go-template directives, then `bash -n` the result to confirm the new block is syntactically valid in context:
```bash
chezmoi execute-template < chezmoi/dot_bashrc.tmpl | bash -n && echo "BASH PARSE OK"
```
Expected output: `BASH PARSE OK` (no syntax errors). (chezmoi is initialized on this host, so `execute-template` renders with real data.)

- [ ] **Step 6: Commit and push (both files, one commit)**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
git commit -m "feat(shell): use bat as MANPAGER for colorized man pages (parity pair)

Guarded with command -v bat; falls back to less. MANROFFOPT=-c avoids
groff glitches under the bat pipe. Identical block in zsh + bash rc.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

### Task 3: tealdeer config + `run_once` cache-seed script

**Files:**
- Create: `chezmoi/dot_config/tealdeer/config.toml`
- Create: `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl`

- [ ] **Step 1: Create the tealdeer config**

Create `chezmoi/dot_config/tealdeer/config.toml` with exactly:

```toml
# Tealdeer (tldr client) configuration — managed by chezmoi.
# auto_update keeps the page cache fresh; the initial cache is seeded by
# .chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl on first apply.
[updates]
auto_update = true
auto_update_interval_hours = 720
```

(Deploys to `~/.config/tealdeer/config.toml`, mode 0644, on both dev and prod — tldr is a scope-tool. No `.tmpl` suffix; static content.)

- [ ] **Step 2: Create the run_once seed script**

Create `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` with exactly:

```bash
{{ if eq .chezmoi.os "linux" -}}
#!/usr/bin/env bash
# run_once_seed-tldr-cache.sh — populate the tealdeer (tldr) page cache once,
# so `tldr <cmd>` works immediately on a freshly provisioned host instead of
# erroring with "Page cache not found". Ongoing freshness is handled by
# auto_update in ~/.config/tealdeer/config.toml.
#
# .tmpl gate: linux only (.chezmoiscripts/ are NOT covered by .chezmoiignore,
# so the gate lives in the body; non-linux renders empty -> chezmoi skips it).
# Soft-fail: `cza` is daily-workflow; a missing tldr or a network blip must not
# turn `chezmoi apply` into a failure. auto_update is the backstop either way.
set -euo pipefail

if ! command -v tldr >/dev/null 2>&1; then
  printf 'tldr not on PATH — skipping tealdeer cache seed\n' >&2
  exit 0
fi
if [ -d "$HOME/.cache/tealdeer/tldr-pages" ]; then
  exit 0   # already seeded; auto_update owns refresh from here
fi
tldr --update >/dev/null 2>&1 \
  || printf 'tldr --update failed (offline?) — auto_update will retry on first use\n' >&2
{{- end }}
```

- [ ] **Step 3: Verify the script has no CRLF**

Run:
```bash
file chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl
```
Expected: no "CRLF" in the output. (If present: `sed -i 's/\r$//' <file>`.)

- [ ] **Step 4: Verify the template renders to valid bash on linux**

Run:
```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl | tee /tmp/seed-rendered.sh | bash -n && echo "RENDER+PARSE OK"
```
Expected output: the rendered bash script (starting `#!/usr/bin/env bash`) followed by `RENDER+PARSE OK`. Confirms the `{{ if eq .chezmoi.os "linux" }}` branch fires and produces syntactically valid bash.

- [ ] **Step 5: Verify the rendered script actually seeds (isolated sandbox)**

Run the rendered script against a throwaway HOME (with XDG cache/config unset so tealdeer can't escape the sandbox), and confirm it seeds, then is a silent no-op on re-run:
```bash
SB=$(mktemp -d)
env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME HOME="$SB" bash /tmp/seed-rendered.sh; echo "seed1 exit=$?"
n1=$(find "$SB/.cache/tealdeer/tldr-pages" -name '*.md' 2>/dev/null | wc -l)
env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME HOME="$SB" bash /tmp/seed-rendered.sh; echo "seed2 exit=$?"
echo "pages: $n1"
rm -rf "$SB" /tmp/seed-rendered.sh
```
Expected: `seed1 exit=0`, `seed2 exit=0`, and `pages:` a few thousand (non-zero). The second run hits the `[ -d … ]` guard and exits 0 silently without re-downloading. (Requires network; if offline, the script prints the offline warning and still exits 0 — also acceptable, but `pages:` will be 0.)

- [ ] **Step 6: Verify chezmoi sees exactly the two new files**

Run:
```bash
chezmoi status | grep -E 'tealdeer|tldr-cache'
```
Expected: two entries — the new `dot_config/tealdeer/config.toml` (target `~/.config/tealdeer/config.toml`) and the `run_once_seed-tldr-cache.sh` script chezmoi will run on next apply. Optionally confirm the config content with `chezmoi cat ~/.config/tealdeer/config.toml | head`. No other unexpected paths.

- [ ] **Step 7: Commit and push**

```bash
git add chezmoi/dot_config/tealdeer/config.toml chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl
git commit -m "feat(tldr): track tealdeer config (auto_update) + run_once cache seed

tldr errored OOTB on an empty cache. config.toml enables auto_update
(30-day max staleness); the Linux-gated, soft-failing run_once script
seeds the cache on first apply so first use is instant. Deploys on both
dev and prod (tldr is a scope-tool). Mirrors the wezterm-terminfo script.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

### Task 4: Internal docs — `CLAUDE.md` + `CLAUDE_CHANGELOG.md`

**Files:**
- Modify: `CLAUDE.md` (Files-to-be-careful-with section; the dot_zshrc/dot_bashrc parity-pair entry; Quick verification section)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Add `MANPAGER`/`MANROFFOPT` to the parity-pair entry**

In `CLAUDE.md`, find the `chezmoi/dot_zshrc.tmpl and chezmoi/dot_bashrc.tmpl — parity pair.` bullet. Its env-var list reads `(EDITOR/VISUAL/PAGER/HIST*/FZF_*/NB*/LS_COLORS)`. Change it to include the man vars:

Replace:
```
env vars (EDITOR/VISUAL/PAGER/HIST*/FZF_*/NB*/LS_COLORS)
```
with:
```
env vars (EDITOR/VISUAL/PAGER/MANPAGER/MANROFFOPT/HIST*/FZF_*/NB*/LS_COLORS)
```

- [ ] **Step 2: Add two "Files Claude should be careful with" entries**

In `CLAUDE.md`, in the "Files Claude should be careful with" list, add these two bullets (place them after the existing `run_onchange_install-wezterm-terminfo.sh.tmpl` entry, since they're conceptually adjacent):

```markdown
- **`chezmoi/dot_config/tealdeer/config.toml`** — tracked tealdeer (tldr) config. `[updates] auto_update = true` is the freshness mechanism: tealdeer auto-downloads the page cache on the first `tldr <cmd>` when the cache is missing or older than `auto_update_interval_hours` (720h). Static (no `.tmpl`), deploys on BOTH dev and prod (tldr is a scope-tool, not behind the `.chezmoiignore.tmpl` dev gate). Removing `auto_update` re-breaks `tldr` on fresh hosts (empty-cache → "Page cache not found"). Paired with the run_once seed script below.
- **`chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl`** — seeds the tealdeer cache once so `tldr` works instantly post-provision instead of erroring until the first auto_update. Linux-only via the body `{{ if eq .chezmoi.os "linux" }}…{{ end }}` gate (`.chezmoiscripts/` are not in `.chezmoiignore`). Soft-fails with `exit 0` if `tldr` isn't on PATH yet (in the bootstrap flow `make provision` installs tldr at step 4, BEFORE chezmoi apply at 4b, so it's present) or if `tldr --update` fails (offline) — `auto_update` in `config.toml` is the backstop in every skip path, so the seed being best-effort is safe. `run_once`: runs a single time per host; the `[ -d ~/.cache/tealdeer/tldr-pages ]` guard makes any content-triggered re-run a no-op. Must be LF-only.
```

- [ ] **Step 3: Add Quick verification lines**

In `CLAUDE.md`'s "Quick verification" list, add:

```markdown
- `tldr tar | head -1` on any host after `cza` — prints the tar page's first line (not "Page cache not found"); confirms the tealdeer cache seed + `auto_update` config landed.
- `man ls | head` in a post-apply shell — renders colorized (bat) when `bat` is on PATH; confirms the `MANPAGER` block. `command -v pkg-config && pkg-config --version` — non-empty version string.
```

- [ ] **Step 4: Append a `CLAUDE_CHANGELOG.md` row**

Append one new table row at the end of `CLAUDE_CHANGELOG.md` (match the existing 3-column `| change | README updated? | README/notes |` format):

```markdown
| Doc/build tooling audit fixes: promoted `pkgconf-pkg-config` (provides `/usr/bin/pkg-config`; the literal `pkg-config` is obsoleted on EL9) into core `LINUX_PACKAGES`; added `man-db man-pages info` to `LINUX_OPTIONAL_PACKAGES` (man tooling + base man pages + GNU info reader — deliberately NOT `texinfo`, CRB-only and unneeded to read info docs). Switched `MANPAGER` from `less` to a `command -v bat`-guarded `sh -c 'col -bx \| bat -l man -p'` + `MANROFFOPT=-c` block in `chezmoi/dot_zshrc.tmpl` + `chezmoi/dot_bashrc.tmpl` (parity pair, identical body, less fallback). Fixed `tldr` being broken OOTB (empty cache → "Page cache not found"): new tracked `chezmoi/dot_config/tealdeer/config.toml` with `[updates] auto_update = true` (verified: tealdeer auto-downloads on missing cache) + new `chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` (Linux-gated body, soft-fail, `[ -d cache ]` guard) that seeds the cache on first apply so first use is instant; both deploy on dev + prod (tldr is a scope-tool). | No | Package adds are plumbing (cf. the `ncurses` promotion row → "No"); the MANPAGER + tldr changes add no command or operating step and pass the "could a user still operate the repo from README alone?" test (cf. dircolors / Catppuccin-theme rows → "No"). The README tldr/tealdeer chip already lists the tool and makes no cache/config claim, so it doesn't go stale. CLAUDE.md gains two `Files Claude should be careful with` entries (tealdeer config + run_once seed), `MANPAGER`/`MANROFFOPT` added to the zsh/bash parity-pair env-var list, and three Quick-verification lines (`tldr tar`, `man ls`, `pkg-config --version`). Design + plan archived under `docs/superpowers/`. |
```

- [ ] **Step 5: Verify the docs edits landed**

Run:
```bash
grep -q 'run_once_seed-tldr-cache' CLAUDE.md && \
grep -q 'MANPAGER/MANROFFOPT' CLAUDE.md && \
grep -q 'tldr tar | head -1' CLAUDE.md && \
tail -1 CLAUDE_CHANGELOG.md | grep -q 'Doc/build tooling audit fixes' && \
echo "DOCS OK"
```
Expected output: `DOCS OK`.

- [ ] **Step 6: Commit and push**

```bash
git add CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): document tealdeer config/seed + MANPAGER; changelog row

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Final verification (after all tasks)

- [ ] `cd makefile && make list MODE=dev >/dev/null && echo OK` → `OK` (makefile parses).
- [ ] `cd makefile && make -n MODE=dev provision | grep -E 'pkgconf-pkg-config|man-db|man-pages|\binfo\b' | sort -u` → shows the four package names.
- [ ] `diff <(grep -A5 'Colorized man pages via bat' chezmoi/dot_zshrc.tmpl) <(grep -A5 'Colorized man pages via bat' chezmoi/dot_bashrc.tmpl) && echo PARITY` → `PARITY`.
- [ ] `file chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl chezmoi/.chezmoiscripts/run_once_seed-tldr-cache.sh.tmpl` → no "CRLF".
- [ ] `chezmoi diff` → only the new tealdeer config + the run_once script + the two rc MANPAGER edits.
- [ ] `git log --oneline -4` → the four task commits present on `main`; `git status` clean.

## Notes / gotchas the implementer must respect

- **Parity-pair invariant:** Task 2 MUST edit both rc files in the same commit with byte-identical blocks. Never edit one without the other.
- **No feature branches:** every commit goes to `main` and is pushed immediately (repo owner's standing instruction).
- **`.chezmoiscripts/` are not covered by `.chezmoiignore`** — the Linux gate lives in the script body (`{{ if eq .chezmoi.os "linux" }}`), not in an ignore pattern. A non-linux render produces empty output and chezmoi skips it.
- **EL9 package names are load-bearing:** `pkgconf-pkg-config` (NOT `pkg-config`), `info` (NOT `texinfo`). Both verified resolvable via `dnf list` on AlmaLinux 9.7.
- **LF-only** for the new chezmoi script and both rc files; repair with `sed -i 's/\r$//'`.
- **Make continuation lines:** in `LINUX_PACKAGES`, the last list item must NOT have a trailing `\`; don't insert a comment between a `\`-continued line and its successor.
