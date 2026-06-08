# Add nnn, fx, gitlogue Tools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three single-binary CLI tools — `nnn` (file manager), `fx` (interactive JSON viewer), `gitlogue` (git-log replay) — to the make-driven toolbelt, with an `n()` cd-on-quit shell wrapper for nnn, installed on both dev and prod machines.

**Architecture:** All three register through the repo's preferred `EGET_TOOL` macro (single-binary GitHub releases), joining `SCOPE_TOOLS` so they install under both MODEs. Version pins live in `versions.mk`. The `n()` wrapper mirrors the existing yazi `y()` in both shell rc templates (parity pair). README.html + CLAUDE_CHANGELOG.md are updated in the same commits as the user-facing changes.

**Tech Stack:** GNU Make + `eget` meta-installer; chezmoi Go-template shell rc files; static HTML docs.

**Reference spec:** `docs/superpowers/specs/2026-06-08-add-nnn-fx-gitlogue-design.md`

> **As-built deltas (discovered during execution):** (1) **nnn** uses `TOOL` + `$(LIB)/archive.sh` with a new backward-compatible `src=dst` rename, NOT `EGET_TOOL` — its musl-static tarball's internal binary is `nnn-musl-static` and eget preserves archive-internal names. (2) The wrapper is **`nn()`**, not `n()` (`n` was already an `nb` note shortcut). (3) The wrapper scopes `NNN_TMPFILE="$tmp" command nnn "$@"` (no env leak) and guards with `[[ -s "$tmp" ]]`. fx + gitlogue are `EGET_TOOL` as planned.

**Testing note (host-specific):** This host is **dev_machine** scope (tools are root-owned in `/usr/local/bin`) and **sudo requires a password**, so the live system install can't run non-interactively. Tasks 1–2 are fully validated **without sudo** via the documented sandbox pattern (`MODE=prod DEST=/tmp/... STAMP=/tmp/...`) and a no-sudo `chezmoi apply` to `$HOME`. Task 3 is the real system install, run by the user with sudo.

---

### Task 1: Register the three tools in Make (+ README chips + CHANGELOG row)

**Files:**
- Modify: `makefile/versions.mk` (append new section after line 124, the `CHTSH_VERSION` line)
- Modify: `makefile/tools.mk` (add block after the `television` registration, ~line 119)
- Modify: `README.html` (add three `chip` spans)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Add version pins to `versions.mk`**

Append at the end of the file (after the `CHTSH_VERSION := latest` line):

```make

# --- (2026-06) interactive explorers + git replay ---------------------------
# nnn — ncurses file manager (jarun/nnn). Six linux variants published;
# tools.mk selects the plain musl static build via --asset musl-static.
# fx — interactive JSON viewer (antonmedv/fx). Non-v tag; raw-binary assets.
# gitlogue — cinematic git commit-replay TUI (unhappychoice/gitlogue).
# gnu-glibc only (no musl build) — fine on this glibc fleet.
NNN_VERSION      := 5.2
FX_VERSION       := 39.2.0
GITLOGUE_VERSION := 0.9.0
```

- [ ] **Step 2: Add the three `EGET_TOOL` registrations to `tools.mk`**

Insert immediately after the `television` registration line (`$(eval $(call EGET_TOOL,television,...))`):

```make

# --- (2026-06) interactive explorers + git replay ---------------------------
# nnn — six linux variants in the release; `--asset musl-static` uniquely picks
# the plain musl static build (the emoji variant is `musl-emoji-static`, so the
# contiguous substring can't collide). Binary inside the tarball is `nnn`.
$(eval $(call EGET_TOOL,nnn,$(NNN_VERSION),jarun/nnn,,--asset musl-static))

# fx — interactive JSON viewer. Non-v tag (like television), so pass it as the
# explicit 4th arg. Assets are raw binaries; eget auto-detects linux/amd64 and
# installs it as `fx`.
$(eval $(call EGET_TOOL,fx,$(FX_VERSION),antonmedv/fx,$(FX_VERSION)))

# gitlogue — cinematic git-log replay. Single linux asset (gnu-glibc only; no
# musl build), so no --asset filter. Tag defaults to v$(GITLOGUE_VERSION).
$(eval $(call EGET_TOOL,gitlogue,$(GITLOGUE_VERSION),unhappychoice/gitlogue))
```

- [ ] **Step 3: Verify the registrations parse and appear as scope-tools**

Run:
```bash
make -C makefile list MODE=prod 2>/dev/null | grep -E '\b(nnn|fx|gitlogue)\b'
```
Expected: all three names appear under `scope-tools` (proves the macros parse and registered into `SCOPE_TOOLS`).

- [ ] **Step 4: Sandbox-install the three tools (no sudo)**

Run:
```bash
rm -rf /tmp/tooltest /tmp/tooltest-stamps
make -C makefile nnn fx gitlogue \
  MODE=prod DEST=/tmp/tooltest STAMP=/tmp/tooltest-stamps
```
Expected: `eget` is built first (order-only dep), then each tool downloads and a stamp file is written. No password prompt (MODE=prod = no sudo). No "asset ambiguous" / TTY-hang errors.

- [ ] **Step 5: Verify binaries exist, are named correctly, and run**

Run:
```bash
ls -l /tmp/tooltest/nnn /tmp/tooltest/fx /tmp/tooltest/gitlogue
ls /tmp/tooltest/ | grep -i 'fx'        # fx-name check
/tmp/tooltest/nnn -V
echo '{"a":1}' | /tmp/tooltest/fx .a
/tmp/tooltest/gitlogue --version
```
Expected:
- All three files present and executable.
- **The fx binary is named exactly `fx`** — NOT `fx_linux_amd64`. If it came down as `fx_linux_amd64`, eget did not rename the raw binary: fix by changing the fx line to force the output name, e.g. append `--to fx` is not valid (eget `--to` is the dir); instead use eget's binary-rename via `--asset fx_linux_amd64 --to /tmp/tooltest/fx` is also dir-bound — the correct fix is to keep `EGET_TOOL` but add the post-extract rename used by other single-asset tools, OR switch fx to the `TOOL`+`direct.sh` path. Re-run Step 4–5 after the fix until the binary is `fx`.
- `nnn -V` prints `nnn: 5.2` (or similar), `fx .a` prints `1`, `gitlogue --version` prints `gitlogue 0.9.0`.

- [ ] **Step 6: Clean up the sandbox**

Run:
```bash
rm -rf /tmp/tooltest /tmp/tooltest-stamps
```
Expected: no output. (Leaves no trace; the real install happens in Task 3.)

- [ ] **Step 7: Add the three README tool chips**

In `README.html`, add a `chip` span for each tool, matching the existing markup exactly (32-space base indent).

**nnn** — insert immediately after the `yazi` chip (the block ending `>yazi<span class="sr-only">… — TUI file manager (Rust)</span></span>`):
```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="TUI file manager (ncurses)"
                                    >nnn<span class="sr-only">
                                        — TUI file manager (ncurses)</span
                                    ></span
                                >
```

**fx** — insert immediately after the `yq` chip (the block with `>yq<span class="sr-only">`):
```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Interactive JSON viewer"
                                    >fx<span class="sr-only">
                                        — interactive JSON viewer</span
                                    ></span
                                >
```

**gitlogue** — insert immediately after the `jj` chip (the block with `>jj<span class="sr-only">`):
```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Cinematic Git commit replay"
                                    >gitlogue<span class="sr-only">
                                        — cinematic Git commit replay</span
                                    ></span
                                >
```

- [ ] **Step 8: Append the CHANGELOG row for the tools**

In `CLAUDE_CHANGELOG.md`, append this row to the table (end of file):
```markdown
| Added `nnn`, `fx`, `gitlogue` (three `EGET_TOOL` lines in `tools.mk` + pins in `versions.mk`) | **Yes** | Add `nnn`/`fx`/`gitlogue` chips to the Stack tool cards (file-manager, data, and git categories respectively) |
```

- [ ] **Step 9: Commit**

```bash
git add makefile/versions.mk makefile/tools.mk README.html CLAUDE_CHANGELOG.md
git commit -m "feat(tools): add nnn, fx, gitlogue via eget

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: nnn `n()` cd-on-quit wrapper (+ README helper doc + CHANGELOG row)

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (insert after the yazi `y()` block, ~line 493)
- Modify: `chezmoi/dot_bashrc.tmpl` (insert after the yazi `y()` block, ~line 350)
- Modify: `README.html` (the daily/navigation `y` helper line, ~line 2443)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Add `n()` to `dot_zshrc.tmpl`**

Insert immediately after the closing `}` of the yazi `y()` function (after the `command rm -f -- "$tmp"` / `}` lines), before the `# --- Machine-specific overrides` comment:

```sh

# nnn file manager — `n` opens it; on quit, cd to wherever you ended up.
n() {
  local tmp
  tmp="$(mktemp -t nnn-cwd.XXXXXX)"
  export NNN_TMPFILE="$tmp"
  command nnn "$@"
  [[ -f "$tmp" ]] && source "$tmp"
  command rm -f -- "$tmp"
}
```

- [ ] **Step 2: Add the identical `n()` to `dot_bashrc.tmpl` (parity)**

Insert the **exact same block** (byte-for-byte) immediately after the yazi `y()` function in `chezmoi/dot_bashrc.tmpl`, before its `# --- Machine-specific overrides` comment:

```sh

# nnn file manager — `n` opens it; on quit, cd to wherever you ended up.
n() {
  local tmp
  tmp="$(mktemp -t nnn-cwd.XXXXXX)"
  export NNN_TMPFILE="$tmp"
  command nnn "$@"
  [[ -f "$tmp" ]] && source "$tmp"
  command rm -f -- "$tmp"
}
```

- [ ] **Step 3: Verify both templates render via chezmoi (no sudo)**

Run:
```bash
chezmoi cat ~/.zshrc  | grep -A8 '^# nnn file manager'
chezmoi cat ~/.bashrc | grep -A8 '^# nnn file manager'
chezmoi diff
```
Expected: the `n()` block appears in both rendered files; `chezmoi diff` shows only the two `n()` additions (no template errors).

- [ ] **Step 4: Apply to `$HOME` and confirm the function loads**

Run:
```bash
chezmoi apply ~/.bashrc ~/.zshrc
bash -ic 'type n' 2>/dev/null
```
Expected: `n is a function` followed by the body. (Applying to `$HOME` needs no sudo.)

- [ ] **Step 5: Update the README `y` helper line to document `n`**

In `README.html`, find the navigation helper sentence (~line 2443):
```html
                        <code>y</code> (yazi file manager &rarr; cd). atuin and
                        the five plugins are zsh-only;
                        <code>br</code>/<code>y</code> work in bash too.
```
Replace with:
```html
                        <code>y</code> (yazi file manager &rarr; cd),
                        <code>n</code> (nnn file manager &rarr; cd). atuin and
                        the five plugins are zsh-only;
                        <code>br</code>/<code>y</code>/<code>n</code> work in
                        bash too.
```

- [ ] **Step 6: Append the CHANGELOG row for the wrapper**

In `CLAUDE_CHANGELOG.md`, append:
```markdown
| Added `n()` cd-on-quit wrapper for nnn (zsh + bash parity, mirrors yazi `y()`) | **Yes** | Document `n` alongside `y` in the daily navigation helpers paragraph |
```

- [ ] **Step 7: Commit**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl README.html CLAUDE_CHANGELOG.md
git commit -m "feat(shell): add nnn n() cd-on-quit wrapper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Live system install on this host (sudo) + final verification

**Files:** none (verification only).

This is the real install to `/usr/local/bin` under dev scope; it needs the sudo password, so **the user runs it** (or runs it in-session via the `!` prefix).

- [ ] **Step 1: Install the three tools system-wide**

User runs (from the repo, will prompt for sudo password):
```bash
make -C ~/.local/share/chezmoi/makefile nnn fx gitlogue MODE=dev
```
Expected: eget installs each into `/usr/local/bin`; three stamp files written.

- [ ] **Step 2: Verify on the live PATH**

```bash
command -v nnn fx gitlogue
nnn -V; echo '{"a":1}' | fx .a; gitlogue --version
```
Expected: all resolve to `/usr/local/bin/...`; versions/smoke output as in Task 1 Step 5.

- [ ] **Step 3: Verify the `n` wrapper end-to-end in a fresh login shell**

```bash
zsh -ic 'type n'
```
Expected: `n is a shell function`. (Interactive round-trip: run `n`, navigate into a subdir, quit with `q` — the shell's `$PWD` should now be that subdir.)

- [ ] **Step 4: Confirm idempotency**

```bash
make -C ~/.local/share/chezmoi/makefile nnn fx gitlogue MODE=dev
```
Expected: all three report up-to-date (stamps satisfied), no re-download.

---

## Self-Review

**Spec coverage:**
- EGET_TOOL for all three (nnn `--asset musl-static`, fx explicit non-v tag, gitlogue defaults) → Task 1 Steps 1–2. ✓
- Universal scope (both dev/prod) → guaranteed by `SCOPE_TOOLS` registration; sandbox (prod) test in Task 1, live (dev) test in Task 3. ✓
- nnn `n()` wrapper in both shells (parity) → Task 2 Steps 1–2. ✓
- fx/gitlogue binary-only → no wiring tasks (correct). ✓
- README listing + `n` helper → Task 1 Step 7, Task 2 Step 5. ✓
- CLAUDE_CHANGELOG rows → Task 1 Step 8, Task 2 Step 6. ✓
- fx raw-binary naming uncertainty → explicit check Task 1 Step 5. ✓
- gitlogue gnu-only caveat → noted in versions.mk + tools.mk comments. ✓
- On-host test → sandbox (Tasks 1–2) + live install (Task 3). ✓

**Placeholder scan:** No TBD/TODO; every code/HTML/markdown block is literal. The only conditional is the fx-rename fallback, which is gated on an observed condition with a concrete fix path.

**Type/name consistency:** Version var names (`NNN_VERSION`/`FX_VERSION`/`GITLOGUE_VERSION`) match between `versions.mk` and `tools.mk`. Function name `n()` identical in both shells. Tool/binary names (`nnn`/`fx`/`gitlogue`) consistent across Make, README chips, and verification commands.
