# Windows Terminal — Catppuccin Mocha Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track the single Windows host's Windows Terminal `settings.json` in chezmoi with Catppuccin Mocha applied — color scheme + app theme, on all profiles.

**Architecture:** Add one Windows-only static file to the chezmoi source by seeding it byte-for-byte from the host's current `settings.json` (reachable from WSL at `/mnt/c/...`) and applying five surgical edits. No `.chezmoiignore` change (Linux already ignores `AppData`), no template, no Make/`bootstrap.ps1` change (WT is a Store app the repo doesn't install). Update the three docs CLAUDE.md requires for a user-facing surface, all in one commit. The host-side `chezmoi apply` + visual verification runs separately on Windows.

**Tech Stack:** chezmoi (source-state file management), JSON, Windows Terminal settings schema, the repo's existing `AppData/` Windows-config convention (mirrors tracked Zed/VSCode `settings.json`).

**Spec:** `docs/superpowers/specs/2026-06-08-windows-terminal-catppuccin-design.md`

---

## File Structure

| Path | Responsibility | Action |
|---|---|---|
| `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json` | The tracked WT config (host file + Catppuccin) | **Create** |
| `README.html` | User-facing: client-deploys sentence, a WT note paragraph, layout-tree node | Modify |
| `docs/claude/file-care.md` | Claude-internal: per-file gotchas for the new WT file | Modify |
| `CLAUDE_CHANGELOG.md` | Claude-internal: worked-example row | Modify |

**Commit policy for this plan:** CLAUDE.md requires the user-facing change + `README.html` + a `CLAUDE_CHANGELOG.md` row in the **same commit**. So Tasks 1–4 make edits with **no intermediate commits**; Task 5 verifies everything and commits once. Task 6 (host-side apply) is run on Windows and may produce a second, follow-up commit if WT reformats the file.

---

## Task 1: Create the tracked Windows Terminal settings.json

**Files:**
- Create: `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`
- Source of truth to seed from: `/mnt/c/Users/arrush.chaturvedi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`

- [ ] **Step 1: Seed the source file byte-for-byte from the host's live settings.json**

Run (from repo root `/home/arrush.chaturvedi/.local/share/chezmoi`):

```bash
SRC="chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState"
HOST="/mnt/c/Users/arrush.chaturvedi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
mkdir -p "$SRC"
cp "$HOST" "$SRC/settings.json"
```

Expected: the file exists at the source path. Verify it matches the bytes the edits below assume:

```bash
diff <(printf '    "schemes": [],\n    "themes": []\n}\n') <(tail -n 3 "$SRC/settings.json") && echo "TAIL OK (empty schemes/themes confirmed)"
grep -c '"colorScheme": "Campbell",' "$SRC/settings.json"
```

Expected: `TAIL OK ...` printed, and the `grep -c` prints `3`. **If either differs, WT rewrote the host file since the spec was authored — re-read the host file and re-derive the old_strings in Steps 3–7 before continuing.**

- [ ] **Step 2: Read the seeded file** (required before Edit tool use). Read the full file so the exact lines are in context.

- [ ] **Step 3: Edit A — populate `schemes` with the Catppuccin Mocha color scheme**

Replace the exact line:

```
    "schemes": [],
```

with (note the trailing space after `"schemes":`, matching WT's formatting style — keep it):

```
    "schemes": 
    [
        {
            "name": "Catppuccin Mocha",
            "cursorColor": "#F5E0DC",
            "selectionBackground": "#585B70",
            "background": "#1E1E2E",
            "foreground": "#CDD6F4",
            "black": "#45475A",
            "red": "#F38BA8",
            "green": "#A6E3A1",
            "yellow": "#F9E2AF",
            "blue": "#89B4FA",
            "purple": "#F5C2E7",
            "cyan": "#94E2D5",
            "white": "#BAC2DE",
            "brightBlack": "#585B70",
            "brightRed": "#F38BA8",
            "brightGreen": "#A6E3A1",
            "brightYellow": "#F9E2AF",
            "brightBlue": "#89B4FA",
            "brightPurple": "#F5C2E7",
            "brightCyan": "#94E2D5",
            "brightWhite": "#A6ADC8"
        }
    ],
```

- [ ] **Step 4: Edit B — populate `themes` with the Catppuccin Mocha app theme**

Replace the exact line (this is the last key — no trailing comma):

```
    "themes": []
```

with:

```
    "themes": 
    [
        {
            "name": "Catppuccin Mocha",
            "tab": 
            {
                "background": "#1E1E2EFF",
                "showCloseButton": "always",
                "unfocusedBackground": null
            },
            "tabRow": 
            {
                "background": "#181825FF",
                "unfocusedBackground": "#11111BFF"
            },
            "window": 
            {
                "applicationTheme": "dark"
            }
        }
    ]
```

- [ ] **Step 5: Edit C — set the default color scheme on all profiles**

Replace the exact line:

```
        "defaults": {},
```

with (trailing space after `"defaults":` kept to match WT style):

```
        "defaults": 
        {
            "colorScheme": "Catppuccin Mocha"
        },
```

- [ ] **Step 6: Edit D — add the top-level app-theme reference**

Replace the exact line:

```
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
```

with (adds a new top-level `theme` key right after it):

```
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
    "theme": "Catppuccin Mocha",
```

- [ ] **Step 7: Edit E — remove the three per-profile `Campbell` overrides**

Delete all three occurrences of the line (16-space indent). Use the Edit tool with `replace_all: true`, `old_string` = the line **including its trailing newline**, `new_string` = empty:

```
                "colorScheme": "Campbell",
```

After this, the three profiles (`Windows PowerShell (Admin)`, `atc-cache-dev09`, `atc-cache-dev10`) inherit `defaults.colorScheme` = `Catppuccin Mocha`.

- [ ] **Step 8: Verify the result is valid JSON, LF-only, no BOM**

Run:

```bash
SRC="chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
python3 -m json.tool "$SRC" > /dev/null && echo "JSON OK"
# LF only (no CR):
if grep -lU $'\r' "$SRC" >/dev/null 2>&1; then echo "FAIL: has CRLF"; else echo "LF OK"; fi
# No BOM (first 3 bytes must NOT be ef bb bf):
head -c3 "$SRC" | od -An -tx1
# The three Campbell overrides are gone; Catppuccin Mocha is referenced:
echo "Campbell count: $(grep -c 'Campbell' "$SRC")  (expect 0)"
echo "Mocha refs: $(grep -c 'Catppuccin Mocha' "$SRC")  (expect 4: scheme name, theme name, defaults.colorScheme, top-level theme)"
```

Expected: `JSON OK`, `LF OK`, the `od` line shows bytes that are **not** `ef bb bf` (e.g. `7b 0a 20` = `{\n `), `Campbell count: 0`, `Mocha refs: 4`.

- [ ] **Step 9: Confirm Linux treats it as Windows-only (not deployed here)**

Run:

```bash
chezmoi managed | grep -i WindowsTerminal && echo "UNEXPECTED: managed on Linux" || echo "OK: not managed on Linux (AppData ignored)"
```

Expected: `OK: not managed on Linux ...` (the `AppData` Linux-ignore rule covers `AppData/Local/...`).

> No commit in this task — see the commit policy above. Continue to Task 2.

---

## Task 2: Update README.html (user-facing surface)

**Files:**
- Modify: `README.html` (three edits: client-deploys sentence, new WT note paragraph, layout-tree node)

- [ ] **Step 1: Edit the "client deploys" sentence to name Windows Terminal**

Replace the exact block:

```html
                        <code>wezterm.lua</code>, the PowerShell profile,
                        Zed/VSCode settings. <code>bootstrap.ps1</code> is the
                        parallel of <code>bootstrap.sh</code>.
```

with:

```html
                        <code>wezterm.lua</code>, the PowerShell profile,
                        Zed/VSCode settings, and the Windows Terminal
                        <code>settings.json</code> (themed Catppuccin Mocha).
                        <code>bootstrap.ps1</code> is the
                        parallel of <code>bootstrap.sh</code>.
```

- [ ] **Step 2: Add a WT note paragraph after the Zed/VSCode/helix paragraph**

Replace the exact block:

```html
                        (Helix&rsquo;s Windows config dir).
                    </p>
                    <p class="note-row">
```

with:

```html
                        (Helix&rsquo;s Windows config dir).
                    </p>
                    <p>
                        <strong>Windows Terminal</strong> is themed
                        <strong>Catppuccin Mocha</strong> (color scheme + app
                        theme, applied to all profiles). Its
                        <code>settings.json</code> is chezmoi-tracked at
                        <code>%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json</code>,
                        the same sync-from-host pattern as the Zed/VSCode
                        configs. Windows Terminal owns and rewrites that file
                        on its own, so expect it to drift &mdash; re-capture
                        with <code>chezmoi re-add</code> (like Zed) when it does.
                    </p>
                    <p class="note-row">
```

- [ ] **Step 3: Add an `AppData/Local/` node to the repo-layout tree**

Replace the exact block (the boundary between the `AppData/Roaming/` and `Documents/` tree nodes):

```html
                                    </details>
                                    <details>
                                        <summary>
                                            Documents/
```

with:

```html
                                    </details>
                                    <details>
                                        <summary>
                                            AppData/Local/
                                            <span class="note"
                                                >&mdash; Windows</span
                                            >
                                        </summary>
                                        <ul>
                                            <li>
                                                Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json
                                                <span class="note"
                                                    >&mdash; Windows Terminal
                                                    (Catppuccin Mocha)</span
                                                >
                                            </li>
                                        </ul>
                                    </details>
                                    <details>
                                        <summary>
                                            Documents/
```

- [ ] **Step 4: Sanity-check the HTML edits landed**

Run:

```bash
grep -c "Windows Terminal" README.html   # expect >= 3 (was 1: the WezTerm card "Windows terminal")
grep -n "AppData/Local/" README.html
```

Expected: count is at least 3; the `AppData/Local/` grep shows the new tree node line.

> No commit in this task. Continue to Task 3.

---

## Task 3: Add a docs/claude/file-care.md entry

**Files:**
- Modify: `docs/claude/file-care.md`

- [ ] **Step 1: Insert a new bullet after the `bootstrap.ps1` Windows-tools bullet**

The target bullet (line ~34) ends with this exact text:

```
All four land under `%LOCALAPPDATA%\workstation` on the User PATH; the script needs no admin.
```

Insert a new bullet immediately after that line (i.e. add a new line beginning `- **` right after the one ending in `...the script needs no admin.`):

```
- **`chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`** — the single Windows host's Windows Terminal config, tracked Catppuccin Mocha (scheme in `schemes[]` + app theme in `themes[]` + `profiles.defaults.colorScheme` + top-level `theme`). **Windows Terminal owns and rewrites this file** (reorders keys, regenerates dynamic profiles), so expect drift on `chezmoi status` — re-capture with `chezmoi re-add` exactly like the tracked Zed/VSCode `settings.json` (this is the accepted tradeoff; no `modify_`/merge script — overkill for one host). **Per-profile `colorScheme` overrides the `defaults`** — keep new profiles override-free (or set them to `Catppuccin Mocha`) or they fall back to their own scheme (the three former-`Campbell` profiles had their overrides removed for this reason). LF, UTF-8, **no BOM**, mode `100644` (matches Zed/VSCode — NOT a CRLF/BOM tripwire file). Windows-only via the existing `AppData` Linux-ignore in `.chezmoiignore.tmpl` (no ignore entry needed); plain static JSON, not a `.tmpl`.
```

- [ ] **Step 2: Confirm the bullet was added**

Run:

```bash
grep -c "WindowsTerminal" docs/claude/file-care.md   # expect 1
```

Expected: `1`.

> No commit in this task. Continue to Task 4.

---

## Task 4: Append a CLAUDE_CHANGELOG.md row

**Files:**
- Modify: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Append a new table row at the end of the file**

The file is a markdown table. Append this row as the final line (after the current last row, which ends `...need no new invariant). |`):

```
| Tracked the single Windows host's Windows Terminal `settings.json` in chezmoi (new `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`, seeded from the host) with Catppuccin Mocha applied: color scheme in `schemes[]`, app theme in `themes[]`, `profiles.defaults.colorScheme = "Catppuccin Mocha"`, top-level `theme = "Catppuccin Mocha"`, and the three per-profile `Campbell` overrides removed so all profiles inherit. No `.chezmoiignore` change (Linux already ignores `AppData`), no `bootstrap.ps1`/Make change (WT is a Store app the repo doesn't install). Full sync-from-host tracking like Zed/VSCode — accepted that WT rewrites the file so it drifts and is re-captured via `chezmoi re-add`; a `modify_`/merge script was rejected as overkill for one host. | **Yes** | New `AppData/Local/` node in the repo-layout tree (sibling of `AppData/Roaming/`); the Windows-host "client deploys ..." sentence now names Windows Terminal; a new note paragraph under Setup → On Windows states WT is themed Catppuccin Mocha, gives the `LocalState` path, and notes WT owns/rewrites the file so it re-syncs like Zed. CLAUDE.md needs no new invariant; `docs/claude/file-care.md` gains a per-file entry (WT-owned/re-sync, `colorScheme`-override gotcha, LF/no-BOM/100644, Windows-only via the `AppData` ignore). |
```

- [ ] **Step 2: Confirm the row was added**

Run:

```bash
tail -1 CLAUDE_CHANGELOG.md | grep -c "Windows Terminal"   # expect 1
```

Expected: `1`.

> No commit in this task. Continue to Task 5.

---

## Task 5: Verify everything together and commit (single commit)

**Files:** all four from Tasks 1–4.

- [ ] **Step 1: Re-run the JSON + line-ending guard on the source file**

```bash
SRC="chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
python3 -m json.tool "$SRC" > /dev/null && echo "JSON OK"
file "$SRC"   # must NOT contain "CRLF"
```

Expected: `JSON OK`; `file` output has no "CRLF".

- [ ] **Step 2: Stage and confirm the new file's git mode is 100644**

```bash
git add -A
git ls-files --stage chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json
```

Expected: the line starts with `100644` (NOT `100755`). If it shows `100755`, fix with `git update-index --chmod=-x <path>`.

- [ ] **Step 3: Review the full diff**

```bash
git status
git diff --cached --stat
```

Expected: exactly four paths staged — the new `settings.json`, `README.html`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`. No other files.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(windows-terminal): track settings.json themed Catppuccin Mocha

$(cat <<'EOF'
Add the single Windows host's Windows Terminal settings.json to chezmoi
(AppData/Local/Packages/.../LocalState/settings.json), seeded from the host
and themed Catppuccin Mocha: color scheme in schemes[], app theme in themes[],
colorScheme set in profiles.defaults, top-level theme set, and the three
per-profile Campbell overrides removed so all profiles inherit. Windows-only
via the existing AppData Linux-ignore; same sync-from-host pattern as the
tracked Zed/VSCode settings.json.

README: layout-tree AppData/Local/ node, client-deploys sentence, a WT note
paragraph. file-care.md: per-file entry. CLAUDE_CHANGELOG: row.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
git log --oneline -1
```

Expected: commit succeeds; the four files are in it.

---

## Task 6: Apply on the Windows host and verify (run on Windows / PowerShell)

> This task runs on the Windows host, not in WSL — the Linux chezmoi manages `$HOME`, not the Windows target. Adjust the repo path if your clone isn't at the default `%USERPROFILE%\.local\share\chezmoi`.

- [ ] **Step 1: Pull the commit on the Windows host**

```powershell
cd $env:USERPROFILE\.local\share\chezmoi
git pull
```

- [ ] **Step 2: Preview the change against the live settings.json**

```powershell
chezmoi managed | Select-String WindowsTerminal   # confirms it's managed on Windows
chezmoi diff
```

Expected: `chezmoi managed` lists the WT `settings.json`; `chezmoi diff` shows **only** the Catppuccin edits (added scheme, added theme, `defaults.colorScheme`, top-level `theme`, three removed `Campbell` lines) against the live file. If the diff shows large reformatting, WT rewrote the live file since seeding — that's fine, just confirm the Catppuccin edits are present in the diff.

- [ ] **Step 3: Apply**

```powershell
chezmoi apply
```

- [ ] **Step 4: Verify in Windows Terminal (visual)**

Open a new Windows Terminal window (or relaunch). Confirm:
- All profiles (PowerShell, the two `atc-cache-dev*` SSH profiles, the WSL/AlmaLinux profile, etc.) render with the Catppuccin Mocha palette — dark `#1E1E2E` background, `#CDD6F4` foreground. In particular the three formerly-`Campbell` profiles are now Mocha.
- The tab bar / title bar use the Catppuccin chrome (dark `applicationTheme`, `#181825` tab row) — i.e. the app theme took, not just the scheme.

- [ ] **Step 5: Canonicalize if WT reformats (optional follow-up commit)**

WT may rewrite/reorder `settings.json` on first launch. If so:

```powershell
chezmoi status   # shows the WT file as modified if WT reformatted it
chezmoi re-add $env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json
git diff   # should be only WT's reformatting (no semantic change)
git commit -am "chore(windows-terminal): canonicalize settings.json to WT's on-disk format"
git push
```

Expected: future `chezmoi status` is clean until the next time WT rewrites the file. (This re-add/commit is the same drift workflow already used for Zed — see the file-care entry.)

---

## Self-Review (completed during planning)

**1. Spec coverage** — every spec section maps to a task:
- "The tracked file" + "The five edits" → Task 1 (Steps 1–7), exact JSON for all five edits.
- "chezmoi mechanics" (LF/no-BOM/100644, Windows-only, no ignore change, no template) → Task 1 Steps 8–9 + Task 5 Step 2.
- "How it lands on the host" → Task 6.
- "Accepted tradeoff" (drift / re-add, no modify_ script) → documented in Task 6 Step 5, file-care entry (Task 3), changelog (Task 4).
- Docs ("Files to touch" 2–4: README, file-care, changelog) → Tasks 2, 3, 4.
- "Risks / things to verify" (valid JSON, LF, Windows-only deploy, all profiles themed, app theme applied, drift) → Task 1 Step 8, Task 1 Step 9, Task 6 Steps 2/4/5.
- No `CLAUDE.md` invariant, no `.chezmoiignore` change, no `bootstrap.ps1`/`versions.mk`/Make change → reflected by their absence from the File Structure table and Task 5 Step 3's "exactly four paths" check.

**2. Placeholder scan** — no TBD/TODO/"handle edge cases"; every code/edit step shows exact content; every command states expected output. The only conditional ("if WT rewrote the host file…") gives an explicit recovery action.

**3. Type/name consistency** — the scheme/theme `name` (`"Catppuccin Mocha"`) used in `schemes[]`/`themes[]` matches the values set in `profiles.defaults.colorScheme` and the top-level `theme`; the source path string is identical across Task 1, Task 5, file-care, changelog, and the README tree node; the host path is identical in Task 1 Step 1 and Task 6 Step 5.
