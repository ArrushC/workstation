# batpipe (bat-highlighted `less`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `less <file>` syntax-highlighted (via `bat`) and give dirs/`tar`/`zip`/`gz`/`xz` a readable preview, by vendoring `batpipe` and wiring it as the `LESSOPEN` preprocessor.

**Architecture:** Vendor the pre-built standalone `batpipe` script from `eth-p/bat-extras` into chezmoi (`dot_local/bin/executable_batpipe` → deployed `~/.local/bin/batpipe`, 0755). Activate it in both `dot_zshrc.tmpl` and `dot_bashrc.tmpl` with a guarded `eval "$(batpipe)"`, which sets `LESSOPEN`→batpipe, appends `-R` to `LESS`, and sets `BATPIPE=color`. This replaces the base `less` package's `/usr/bin/lesspipe.sh` as the `LESSOPEN` handler; the system lesspipe stays installed and is the automatic fallback when the guard fails.

**Tech Stack:** chezmoi (Go templates, `executable_`/`dot_` source-naming, `.chezmoiignore.tmpl`), zsh + bash rc templates, vendored bash script with a `.vendor` provenance sidecar.

**Spec:** `docs/superpowers/specs/2026-06-05-batpipe-less-highlighting-design.md`

**Note on "tests":** This repo has no unit-test harness for shell rc / vendored scripts. The equivalent of a test here is a **verification command with expected output** (sha256 checks, `chezmoi diff`, `file` CRLF check, live `less`/`echo $LESSOPEN` behavior). Each task ends with these.

**Commits:** Work on a feature branch (we start on `main`). Commit per task. **Do not push.**

---

### Task 0: Create the feature branch

**Files:** none (git only)

- [ ] **Step 1: Confirm clean tree on main**

Run: `cd /home/arrush.chaturvedi/.local/share/chezmoi && git status --short && git branch --show-current`
Expected: no output from `git status --short` (clean) and branch `main`. (The two untracked spec/plan docs under `docs/superpowers/` may appear — that is expected; they are committed in Task 7.)

- [ ] **Step 2: Create and switch to the branch**

```bash
git switch -c feat/batpipe-less-highlighting
```

- [ ] **Step 3: Verify**

Run: `git branch --show-current`
Expected: `feat/batpipe-less-highlighting`

---

### Task 1: Vendor the `batpipe` script + provenance sidecar

**Files:**
- Create: `chezmoi/dot_local/bin/executable_batpipe`
- Create: `chezmoi/dot_local/bin/.vendor`

- [ ] **Step 1: Download the release zip and verify its sha256**

```bash
cd /tmp
curl -sL -o batx.zip "https://github.com/eth-p/bat-extras/releases/download/v2024.08.24/bat-extras-2024.08.24.zip"
echo "d79c085b9d0af7f56c3f69d766a83fe26405faac999c4ed7cdfc27417d2c736f  batx.zip" | sha256sum -c -
```
Expected: `batx.zip: OK`. If it fails, STOP — do not vendor an unverified asset.

- [ ] **Step 2: Extract `bin/batpipe` and verify its sha256**

```bash
cd /tmp
rm -rf bex && mkdir bex && unzip -q batx.zip -d bex
echo "fe085dc3f83f3e97b541210375b5cef46e3abc35e220175290e2a280e8ff8f27  bex/bin/batpipe" | sha256sum -c -
```
Expected: `bex/bin/batpipe: OK`.

- [ ] **Step 3: Place it as the chezmoi source file (LF endings preserved)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
mkdir -p chezmoi/dot_local/bin
cp /tmp/bex/bin/batpipe chezmoi/dot_local/bin/executable_batpipe
```

- [ ] **Step 4: Verify the vendored file is intact and LF-only**

Run:
```bash
file chezmoi/dot_local/bin/executable_batpipe
sha256sum chezmoi/dot_local/bin/executable_batpipe
```
Expected: `file` output contains `Bourne-Again shell script` and does **NOT** contain `CRLF`. sha256 is `fe085dc3f83f3e97b541210375b5cef46e3abc35e220175290e2a280e8ff8f27`.
If `file` reports CRLF, repair: `sed -i 's/\r$//' chezmoi/dot_local/bin/executable_batpipe` and re-check the sha (it must still match — if it changed, the source had CRLF and must be re-extracted).

- [ ] **Step 5: Create the `.vendor` provenance sidecar**

Create `chezmoi/dot_local/bin/.vendor` with exactly:

```
script:         batpipe (eth-p/bat-extras)
upstream:       https://github.com/eth-p/bat-extras
release:        v2024.08.24
asset:          https://github.com/eth-p/bat-extras/releases/download/v2024.08.24/bat-extras-2024.08.24.zip
asset-sha256:   d79c085b9d0af7f56c3f69d766a83fe26405faac999c4ed7cdfc27417d2c736f
file-sha256:    fe085dc3f83f3e97b541210375b5cef46e3abc35e220175290e2a280e8ff8f27
license:        MIT
vendored:       2026-06-05
files:          executable_batpipe  (prebuilt standalone `bin/batpipe` from the release zip; bat-modules bundled inline, verbatim)
note:           Leading-dot filename → chezmoi-ignored; provenance only, never deployed.
                Deploys 0755 to ~/.local/bin/batpipe (executable_ prefix); wired as the
                less LESSOPEN preprocessor via `eval "$(batpipe)"` in dot_zshrc.tmpl + dot_bashrc.tmpl.
                No versions.mk entry — pinned only here (not coupled to BAT_VERSION).
                Bump: re-download the release zip, replace executable_batpipe with bin/batpipe,
                refresh release + asset-sha256 + file-sha256 above.
```

- [ ] **Step 6: Confirm chezmoi sees the new managed file (and ignores `.vendor`)**

Run: `chezmoi managed | grep -E '\.local/bin'`
Expected: a line for `.local/bin/batpipe` (the deployed target). `.vendor` must **NOT** appear (chezmoi ignores leading-dot source entries).

- [ ] **Step 7: Commit**

```bash
git add chezmoi/dot_local/bin/executable_batpipe chezmoi/dot_local/bin/.vendor
git commit -m "feat(less): vendor batpipe (eth-p/bat-extras v2024.08.24)"
```

---

### Task 2: Wire batpipe in `dot_zshrc.tmpl`

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (insert after the MANPAGER block, before `export COLORTERM`)

- [ ] **Step 1: Add the guarded eval block**

Edit `chezmoi/dot_zshrc.tmpl` — replace this exact block:

```
fi
export COLORTERM=truecolor   # WezTerm advertises 24-bit RGB; apps honor this env-var convention (helix, zellij, starship, glow, eza, fzf, bat).
```

with:

```
fi
# bat-highlighted `less`: batpipe (eth-p/bat-extras) as the LESSOPEN preprocessor.
# `eval "$(batpipe)"` sets LESSOPEN->batpipe, appends -R to LESS, and sets
# BATPIPE=color so source files are syntax-highlighted and dirs/tar/zip/gz/xz
# get a readable preview in `less`. Guarded so a host without bat/batpipe falls
# back to the system /usr/bin/lesspipe.sh (left installed, untouched).
if command -v batpipe &>/dev/null && command -v bat &>/dev/null; then
  eval "$(batpipe)"
fi
export COLORTERM=truecolor   # WezTerm advertises 24-bit RGB; apps honor this env-var convention (helix, zellij, starship, glow, eza, fzf, bat).
```

- [ ] **Step 2: Verify the template still renders and the diff is correct**

Run:
```bash
chezmoi cat ~/.zshrc | grep -nA1 'eval "$(batpipe)"'
chezmoi diff ~/.zshrc
```
Expected: `chezmoi cat` shows the `eval "$(batpipe)"` line (template renders without error); `chezmoi diff` shows exactly the added block (and the `LESSOPEN`/`BATPIPE` lines it will produce are NOT in the source — they come from batpipe at runtime, not the template).

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_zshrc.tmpl
git commit -m "feat(zsh): wire batpipe as the less LESSOPEN preprocessor"
```

---

### Task 3: Wire batpipe in `dot_bashrc.tmpl` (parity)

**Files:**
- Modify: `chezmoi/dot_bashrc.tmpl` (same insertion point as zsh)

- [ ] **Step 1: Add the identical guarded eval block**

Edit `chezmoi/dot_bashrc.tmpl` — replace this exact block:

```
fi
export COLORTERM=truecolor   # WezTerm advertises 24-bit RGB; apps honor this env-var convention (helix, zellij, starship, glow, eza, fzf, bat).
```

with:

```
fi
# bat-highlighted `less`: batpipe (eth-p/bat-extras) as the LESSOPEN preprocessor.
# `eval "$(batpipe)"` sets LESSOPEN->batpipe, appends -R to LESS, and sets
# BATPIPE=color so source files are syntax-highlighted and dirs/tar/zip/gz/xz
# get a readable preview in `less`. Guarded so a host without bat/batpipe falls
# back to the system /usr/bin/lesspipe.sh (left installed, untouched).
if command -v batpipe &>/dev/null && command -v bat &>/dev/null; then
  eval "$(batpipe)"
fi
export COLORTERM=truecolor   # WezTerm advertises 24-bit RGB; apps honor this env-var convention (helix, zellij, starship, glow, eza, fzf, bat).
```

- [ ] **Step 2: Verify parity — the two blocks must be byte-identical**

Run:
```bash
diff <(grep -A6 'bat-highlighted `less`' chezmoi/dot_zshrc.tmpl) \
     <(grep -A6 'bat-highlighted `less`' chezmoi/dot_bashrc.tmpl) && echo "PARITY OK"
```
Expected: `PARITY OK` (no diff output). The wiring block is shell-agnostic, so it is identical in both files.

- [ ] **Step 3: Commit**

```bash
git add chezmoi/dot_bashrc.tmpl
git commit -m "feat(bash): wire batpipe as the less LESSOPEN preprocessor (parity)"
```

---

### Task 4: Ignore `dot_local/bin` on Windows

**Files:**
- Modify: `chezmoi/.chezmoiignore.tmpl` (inside the `{{ if eq .chezmoi.os "windows" }}` block)

- [ ] **Step 1: Add the ignore line**

Edit `chezmoi/.chezmoiignore.tmpl` — replace this exact line:

```
dot_config/zsh
```

with:

```
dot_config/zsh
# dot_local/bin holds the vendored batpipe bash script (bat-highlighted less),
# useless on Windows — don't deposit it in %USERPROFILE%.
dot_local/bin
```

- [ ] **Step 2: Verify it lands only in the Windows branch**

Run: `grep -n -B1 -A1 'dot_local/bin' chezmoi/.chezmoiignore.tmpl`
Expected: the `dot_local/bin` line appears once, immediately after `dot_config/zsh` and its comment — which are inside the `{{ if eq .chezmoi.os "windows" }}` block (NOT in the `{{ else }}` Linux/macOS branch).

- [ ] **Step 3: Commit**

```bash
git add chezmoi/.chezmoiignore.tmpl
git commit -m "chore(chezmoi): ignore dot_local/bin (batpipe) on Windows"
```

---

### Task 5: Apply on this host and verify behavior (integration check)

**Files:** none (deploys to `$HOME`, then verifies). This host is a dev_machine (AlmaLinux 9, WSL).

- [ ] **Step 1: Review the pending diff (scope to our files)**

Run:
```bash
chezmoi diff ~/.local/bin/batpipe ~/.zshrc ~/.bashrc
```
Expected: additions only — the new `batpipe` script and the two rc blocks. Eyeball that nothing unrelated is bundled.

- [ ] **Step 2: Apply only our three targets**

```bash
chezmoi apply ~/.local/bin/batpipe ~/.zshrc ~/.bashrc
```
Expected: no errors.

- [ ] **Step 3: Verify the deployed script**

Run:
```bash
ls -l ~/.local/bin/batpipe
file ~/.local/bin/batpipe
```
Expected: mode `-rwxr-xr-x` (0755), and `file` reports a shell script with **no** `CRLF`.

- [ ] **Step 4: Verify the env wiring in a fresh interactive zsh**

Run:
```bash
zsh -ic 'echo "LESSOPEN=$LESSOPEN"; echo "BATPIPE=$BATPIPE"; echo "LESS=$LESS"'
```
Expected:
- `LESSOPEN=|/home/arrush.chaturvedi/.local/bin/batpipe %s`
- `BATPIPE=color`
- `LESS` contains `-R`

- [ ] **Step 5: Verify the env wiring in a fresh interactive bash (parity)**

Run:
```bash
bash -ic 'echo "LESSOPEN=$LESSOPEN"; echo "BATPIPE=$BATPIPE"; echo "LESS=$LESS"'
```
Expected: same three values as Step 4.

- [ ] **Step 6: Verify highlighting and previews actually work**

Run:
```bash
# Source-file highlighting (force non-interactive so less just dumps the preprocessed output):
LESSOPEN="$(zsh -ic 'echo $LESSOPEN' | sed 's/^LESSOPEN=//')"
~/.local/bin/batpipe chezmoi/dot_local/bin/executable_batpipe 2>&1 | head -5
# Archive/dir previews:
echo "--- tar.gz ---"; ( cd /tmp && tar czf demo.tgz bex/doc 2>/dev/null && BATPIPE=color ~/.local/bin/batpipe /tmp/demo.tgz | head -5 )
echo "--- directory ---"; BATPIPE=color ~/.local/bin/batpipe /tmp/bex | head -5
```
Expected: the source-file output shows ANSI color escapes / bat styling (highlighting present); the tar.gz output lists archive contents; the directory output lists the dir (via eza/ls). 
Also do a real interactive smoke test by eye: open a new terminal and run `less chezmoi/dot_local/bin/executable_batpipe` — it should be syntax-highlighted.

- [ ] **Step 7: Verify bat and man are unaffected**

Run:
```bash
bat --version >/dev/null && echo "bat OK"
zsh -ic 'echo $MANPAGER'
```
Expected: `bat OK`, and `MANPAGER` is still `sh -c 'col -bx | bat -l man -p'` (unchanged).

- [ ] **Step 8: Verify the guard falls back when batpipe is absent**

Run:
```bash
zsh -ic 'PATH=/usr/bin:/bin; unset LESSOPEN; source ~/.zshrc 2>/dev/null; command -v batpipe >/dev/null || echo "guard: batpipe not found -> block skipped (system lesspipe stays)"'
```
Expected: prints the `guard: ...` line (proves the `command -v batpipe` guard skips the block cleanly rather than erroring). No "command not found: batpipe" error.

(No commit — this task only deploys + verifies.)

---

### Task 6: User-facing docs — README.html + CLAUDE_CHANGELOG.md

**Files:**
- Modify: `README.html` (§stack toolbelt — add a `batpipe` chip after the `bat` chip)
- Modify: `CLAUDE_CHANGELOG.md` (append a row)

- [ ] **Step 1: Add the `batpipe` chip to the toolbelt**

Edit `README.html` — replace this exact block (the `bat` chip):

```
                                    >bat<span class="sr-only">
                                        — syntax-highlighted `cat`</span
                                    ></span
                                >
```

with:

```
                                    >bat<span class="sr-only">
                                        — syntax-highlighted `cat`</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="bat-highlighted `less` (LESSOPEN preprocessor)"
                                    >batpipe<span class="sr-only">
                                        — bat-highlighted `less` preprocessor</span
                                    ></span
                                >
```

- [ ] **Step 2: Verify the chip renders in the source**

Run: `grep -n 'batpipe' README.html`
Expected: two lines — the `data-tip` and the `>batpipe<span` — inside the toolbelt chip group.

- [ ] **Step 3: Append the changelog row**

Edit `CLAUDE_CHANGELOG.md` — find the last table row (ends with `gains rows for \`czt\` and \`czh\`. |`) and append a new line immediately after it:

```
| Wired **batpipe** (`eth-p/bat-extras` v2024.08.24, vendored to `chezmoi/dot_local/bin/executable_batpipe` + a `.vendor` sidecar) as the `less` `LESSOPEN` preprocessor via guarded `eval "$(batpipe)"` in `dot_zshrc.tmpl` + `dot_bashrc.tmpl`: `less <file>` is now bat-syntax-highlighted and dirs/tar/zip/gz/xz get a preview (sets `BATPIPE=color` + appends `-R` to `LESS`). Replaces the base `less` package's `/usr/bin/lesspipe.sh` as the LESSOPEN handler (system lesspipe left installed as the guard-fail fallback). Both scopes; Windows-ignored via `dot_local/bin`. No `versions.mk` entry — pinned in `.vendor`. | **Yes** | README §stack toolbelt gains a `batpipe` chip. |
```

- [ ] **Step 4: Verify the row was appended cleanly**

Run: `tail -3 CLAUDE_CHANGELOG.md`
Expected: the new batpipe row is the last line and is a single well-formed table row (starts and ends with `|`).

- [ ] **Step 5: Commit**

```bash
git add README.html CLAUDE_CHANGELOG.md
git commit -m "docs: document batpipe (bat-highlighted less) in README + changelog"
```

---

### Task 7: Claude-internal docs + commit the spec/plan

**Files:**
- Modify: `docs/claude/file-care.md` (add batpipe to the vendored-files list)
- Modify: `CLAUDE.md` (extend the vendored-files tripwire line)
- Add: the spec + this plan under `docs/superpowers/`

- [ ] **Step 1: Add the batpipe entry to `docs/claude/file-care.md`**

Edit `docs/claude/file-care.md` — after the `zsh-you-should-use` vendored bullet (the line beginning ``- **`chezmoi/dot_config/zsh/plugins/zsh-you-should-use/`**`` and ending `Bump = re-download the tag, refresh `.vendor`.`), insert a new bullet on the next line:

```
- **`chezmoi/dot_local/bin/executable_batpipe`** — vendored `eth-p/bat-extras` standalone `batpipe` (release `v2024.08.24`, MIT), a single self-contained bash script (the build bundles its `bat-modules` lib inline — no companion files). Provenance in the chezmoi-ignored `chezmoi/dot_local/bin/.vendor` sidecar (release tag + asset-sha256 + file-sha256). **LF-only**, deploys 0755 to `~/.local/bin/batpipe` via the `executable_` prefix, BOTH dev + prod; Windows-ignored via the `dot_local/bin` line in the `.chezmoiignore.tmpl` Windows block. Wired as the `less` input preprocessor by `eval "$(batpipe)"` in `dot_zshrc.tmpl` + `dot_bashrc.tmpl` (guarded on `bat` + `batpipe`), which sets `LESSOPEN`→batpipe, appends `-R` to `LESS`, and sets `BATPIPE=color` — the latter is **required** (bat writing into a pipe to `less` defaults color off; `BATPIPE=color` forces `bat --color=always`). Replaces the base `less` package's `/usr/bin/lesspipe.sh` as `LESSOPEN` (system lesspipe left installed as the guard-fail fallback). No `versions.mk` entry — pinned only in `.vendor`. Bump = re-download the release zip, replace with `bin/batpipe`, refresh `.vendor`.
```

- [ ] **Step 2: Extend the vendored-files tripwire in `CLAUDE.md`**

Edit `CLAUDE.md` — at the END of the bullet that begins ``- **Vendored — don't hand-edit; re-download at the pinned tag + refresh sha256:**`` (the one ending `provenance in each dir's chezmoi-ignored `.vendor` sidecar; bump = re-download the pinned tag + refresh sha256 in `.vendor`.`), append this sentence to the same bullet:

```
 Also `chezmoi/dot_local/bin/executable_batpipe` — vendored `eth-p/bat-extras` batpipe (the `less` `LESSOPEN` preprocessor for bat-highlighted paging), single self-contained script, provenance in its `dot_local/bin/.vendor` sidecar; LF-only, deploys 0755, no `versions.mk` entry; bump = re-download the release + refresh `.vendor`.
```

- [ ] **Step 3: Verify both internal docs mention batpipe**

Run: `grep -c batpipe docs/claude/file-care.md CLAUDE.md`
Expected: `docs/claude/file-care.md:1` (at least), `CLAUDE.md:1` (at least).

- [ ] **Step 4: Commit the internal docs + the spec/plan**

```bash
git add docs/claude/file-care.md CLAUDE.md \
        docs/superpowers/specs/2026-06-05-batpipe-less-highlighting-design.md \
        docs/superpowers/plans/2026-06-05-batpipe-less-highlighting.md
git commit -m "docs(claude): record batpipe vendored-file invariant + spec/plan"
```

---

### Task 8: Final review

- [ ] **Step 1: Review the full branch diff against `main`**

Run: `git --no-pager diff main...HEAD --stat`
Expected exactly these paths changed:
- `CLAUDE.md`
- `CLAUDE_CHANGELOG.md`
- `README.html`
- `chezmoi/.chezmoiignore.tmpl`
- `chezmoi/dot_bashrc.tmpl`
- `chezmoi/dot_local/bin/.vendor`
- `chezmoi/dot_local/bin/executable_batpipe`
- `chezmoi/dot_zshrc.tmpl`
- `docs/claude/file-care.md`
- `docs/superpowers/plans/2026-06-05-batpipe-less-highlighting.md`
- `docs/superpowers/specs/2026-06-05-batpipe-less-highlighting-design.md`

- [ ] **Step 2: Confirm the working tree is clean and on the branch**

Run: `git status --short && git branch --show-current`
Expected: no output from `git status --short`; branch `feat/batpipe-less-highlighting`.

- [ ] **Step 3: Stop and report**

Summarize what was done and the verification results. **Do not push or merge** — leave that to the user (offer `finishing-a-development-branch` next).

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Vendored file + `.vendor` → Task 1. ✓
- Shell wiring zsh + bash parity → Tasks 2, 3. ✓
- Replace LESSOPEN / `BATPIPE=color` / `LESS -R` → produced by `eval "$(batpipe)"`, verified Task 5. ✓
- Color mechanism rationale → captured in Task 7 file-care entry + spec. ✓
- bat/man non-interference → verified Task 5 Step 7. ✓
- Trade-off (replace, fallback) → guard verified Task 5 Step 8; documented Task 6/7. ✓
- Scope both + Windows ignore → Task 4. ✓
- Docs: README + changelog + file-care + CLAUDE.md → Tasks 6, 7. ✓
- Verification recipe → Task 5. ✓

**Placeholder scan:** No TBD/TODO; all code, commands, and sha256s are literal. The only `<...>` tokens are in expected `echo` output for the per-host username path, which is correct.

**Type/name consistency:** `executable_batpipe` (source) ↔ `~/.local/bin/batpipe` (deployed) ↔ `dot_local/bin` (ignore path) ↔ `.vendor` sidecar — consistent across all tasks. Branch name `feat/batpipe-less-highlighting` consistent in Tasks 0 and 8.
