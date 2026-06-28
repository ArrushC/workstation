# Zed Integrated-Terminal Nushell Shell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Zed's integrated terminal launch Nushell instead of the system shell (PowerShell/cmd.exe) on Windows.

**Architecture:** Add a single `terminal.shell.program` key to the chezmoi-tracked Zed config. The value is bare `nu`, resolved via the User PATH entry `bootstrap.ps1` adds (`%LOCALAPPDATA%\workstation\nu`) — mirroring wezterm's `nu_prog()` bare-`nu` fallback. Two doc updates (README paragraph + changelog row) keep the repo's self-documentation accurate.

**Tech Stack:** chezmoi (dotfile management), Zed `settings.json` (JSONC), README.html, Markdown changelog.

## Global Constraints

- **Windows-only effect.** Target file is under `AppData/`, ignored on Linux via `chezmoi/.chezmoiignore.tmpl`. No `.chezmoiignore` change. Applying on Linux/WSL does not touch this file.
- **JSONC, not strict JSON.** `chezmoi/AppData/Roaming/Zed/settings.json` uses `//` comments and trailing commas. Preserve that style: 2-space indent, trailing comma after the new key, do not reflow or reformat existing keys.
- **File mechanics unchanged.** Plain `.json` (deployed verbatim, not a template), LF line endings, mode 0644. No CRLF/BOM/mode concerns.
- **Program value is exactly `nu`** (bare name, PATH-resolved). Not an absolute path, not `nu.exe`.
- **No CLAUDE.md change.** The "Two places set the default and must agree" invariant stays as-is (see spec).
- **Commit only when the user gives the go-ahead** (user's standing rule). Branch off `main` first; PR per the user's review workflow. All file edits (Tasks 1-3) happen before any commit; committing is the final, gated task.
- Spec: `docs/superpowers/specs/2026-06-28-zed-nushell-shell-design.md`.

---

### Task 1: Add Nushell as Zed's integrated-terminal shell

**Files:**
- Modify: `chezmoi/AppData/Roaming/Zed/settings.json` (the `terminal` block, currently starting at line 99)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a `terminal.shell.program = "nu"` setting that Zed reads on Windows. No later task depends on its internals; Tasks 2-3 only describe it.

- [ ] **Step 1: Create the working branch** (we are on `main`, the default branch)

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git switch -c zed-nushell-shell
```

Expected: `Switched to a new branch 'zed-nushell-shell'`

- [ ] **Step 2: Add the `shell` key as the first key of the `terminal` block**

Apply this exact edit to `chezmoi/AppData/Roaming/Zed/settings.json`.

Old (lines 99-100):

```jsonc
  "terminal": {
    "font_size": 13.0,
```

New:

```jsonc
  "terminal": {
    "shell": { "program": "nu" },
    "font_size": 13.0,
```

Rationale baked into the value: bare `nu` resolves through the User PATH entry (`%LOCALAPPDATA%\workstation\nu`) that `bootstrap.ps1` adds; Zed spawns the integrated terminal as a child process inheriting that PATH. No env-var expansion or absolute path needed.

- [ ] **Step 3: Verify the file is still valid JSONC and the key landed**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
python3 - <<'PY'
import json, re, pathlib
src = pathlib.Path("chezmoi/AppData/Roaming/Zed/settings.json").read_text()
# Drop full-line // comments. (Every // in this file is a full-line comment;
# none appear inside JSON string values, so this is safe here.)
no_comments = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("//"))
# Remove trailing commas before } or ] so strict json.loads accepts the JSONC.
no_trailing = re.sub(r",(\s*[}\]])", r"\1", no_comments)
data = json.loads(no_trailing)
assert data["terminal"]["shell"] == {"program": "nu"}, data["terminal"].get("shell")
print("OK: JSONC valid; terminal.shell =", data["terminal"]["shell"])
PY
```

Expected output:

```
OK: JSONC valid; terminal.shell = {'program': 'nu'}
```

If it raises `json.JSONDecodeError`, the edit broke the JSONC (likely a missing/extra comma) — fix and re-run before proceeding.

- [ ] **Step 4: Confirm file mechanics are unchanged (LF, no BOM)**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
file chezmoi/AppData/Roaming/Zed/settings.json
git diff --stat chezmoi/AppData/Roaming/Zed/settings.json
```

Expected: `file` output does **not** contain "CRLF" or "with BOM"; `git diff --stat` shows `1 file changed, 1 insertion(+)` (one added line).

---

### Task 2: Update the README "Nushell is the default local shell" paragraph

**Files:**
- Modify: `README.html` (the paragraph at lines ~2756-2777)

**Interfaces:**
- Consumes: the setting added in Task 1 (describes it, no code dependency).
- Produces: accurate user-facing docs listing three Nushell-default surfaces.

- [ ] **Step 1: Replace the two-surface enumeration with three surfaces**

Apply this exact edit to `README.html`.

Old:

```html
                        <strong>Nushell is the default local shell.</strong> It
                        replaces PowerShell as the default in both WezTerm
                        (<code>default_prog</code> in <code>wezterm.lua</code>) and
                        Windows Terminal (the <em>Nushell</em> profile +
                        <code>defaultProfile</code>) &mdash; a structured-data,
                        cross-platform modern shell.
```

New:

```html
                        <strong>Nushell is the default local shell.</strong> It
                        replaces PowerShell as the default in WezTerm
                        (<code>default_prog</code> in <code>wezterm.lua</code>),
                        Windows Terminal (the <em>Nushell</em> profile +
                        <code>defaultProfile</code>), and Zed&rsquo;s integrated
                        terminal (<code>terminal.shell.program</code>) &mdash; a
                        structured-data, cross-platform modern shell.
```

(Drops "both"; adds Zed as the third item with an Oxford comma.)

- [ ] **Step 2: Verify the edit**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
grep -n "integrated" README.html | grep -i zed
grep -c "in both WezTerm" README.html
```

Expected: the first `grep` prints the new `Zed&rsquo;s integrated` line; the second prints `0` (the old "both WezTerm" wording is gone).

---

### Task 3: Append the changelog row

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row to the end of the table)

**Interfaces:**
- Consumes: Tasks 1-2 (documents both).
- Produces: a precedent row in the worked-examples log.

- [ ] **Step 1: Append the row as the new final line of the table**

Add this exact row to the end of `CLAUDE_CHANGELOG.md` (it is the last table row; the table has columns `| Change | README update? | What to add |`):

```markdown
| Set Zed's integrated-terminal default shell to Nushell — added `"shell": { "program": "nu" }` to the `terminal` block of `chezmoi/AppData/Roaming/Zed/settings.json` (Windows-only; `AppData` is ignored on Linux). Bare `nu` resolves via the User PATH entry `bootstrap.ps1` adds (`%LOCALAPPDATA%\workstation\nu`), mirroring wezterm's `nu_prog()` bare-`nu` fallback. | **Yes** | The "Nushell is the default local shell" paragraph in `README.html` gains Zed's integrated terminal (`terminal.shell.program`) as a third Nushell-default surface alongside WezTerm `default_prog` and Windows Terminal `defaultProfile`. No CLAUDE.md invariant change — Zed's integrated terminal is a per-app setting, not the OS-level default shell, so it need not "agree" with the other two. |
```

- [ ] **Step 2: Verify the row is present and well-formed**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
tail -n 1 CLAUDE_CHANGELOG.md | grep -c "Zed's integrated-terminal default shell"
awk 'END{print NR}' CLAUDE_CHANGELOG.md   # sanity: file still ends with the new row
```

Expected: first command prints `1`; the new row is the final line.

---

### Task 4: Commit, push, and open PR (GATED — only on user go-ahead)

**Files:** none (git operations only).

**Interfaces:**
- Consumes: the working tree from Tasks 1-3 on branch `zed-nushell-shell`.
- Produces: a commit + PR for review.

> **Do not run this task until the user explicitly approves committing.** Per the user's standing rule, commit/push only when asked. This is one atomic logical change (config + its docs), so a single commit is correct.

- [ ] **Step 1: Review the full diff before committing**

Run:

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git status
git diff
```

Expected: exactly three files changed — `chezmoi/AppData/Roaming/Zed/settings.json`, `README.html`, `CLAUDE_CHANGELOG.md` — plus the new spec/plan docs under `docs/superpowers/` if those are to be committed too (confirm with the user whether to include them).

- [ ] **Step 2: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/AppData/Roaming/Zed/settings.json README.html CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
feat(zed): default integrated terminal to Nushell on Windows

Add terminal.shell.program = "nu" to the chezmoi-tracked Zed config so
Zed's integrated terminal launches Nushell (PATH-resolved via the
%LOCALAPPDATA%\workstation\nu entry bootstrap.ps1 adds), matching the
rest of the Windows shell setup. Update the README "default local shell"
paragraph + changelog.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015G1erqcyigJjy6TWvrTNdm
EOF
)"
```

- [ ] **Step 3: Push and open the PR** (per the user's PR review workflow)

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git push -u origin zed-nushell-shell
gh pr create --fill --base main
```

Expected: a PR URL is printed.

- [ ] **Step 4: Real verification (Windows host — manual, post-merge or on a Windows checkout)**

On the Windows dev host: `chezmoi apply`, then open Zed's integrated terminal (`` Ctrl-` ``). Confirm the Nushell prompt appears, and run:

```nushell
$nu.current-exe
```

Expected: a path ending in `\workstation\nu\nu.exe`.

---

## Self-Review

**Spec coverage:**
- Core change (`terminal.shell.program = "nu"`) → Task 1. ✓
- JSONC-style preservation + file mechanics → Task 1 Steps 2-4 + Global Constraints. ✓
- Windows-only / no `.chezmoiignore` change → Global Constraints. ✓
- README paragraph update → Task 2. ✓
- CLAUDE_CHANGELOG row → Task 3. ✓
- Explicitly-no CLAUDE.md change → Global Constraints + changelog row text. ✓
- Verification (local JSONC + Windows manual) → Task 1 Step 3 + Task 4 Step 4. ✓
- Risks (PATH race, Zed rewrite) → covered in spec; bare-`nu` choice locked in Global Constraints. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to" — every step has exact paths, exact edits, exact commands, and expected output. ✓

**Type/value consistency:** The setting value is `nu` everywhere (Task 1 edit, Task 1 verify assertion, changelog row, commit message). README references `terminal.shell.program` consistently. ✓
