# WezTerm line-count footer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a line-count readout to the active pane's slot in the WezTerm right-status footer — total buffer lines, rows on screen, and cursor line when a main-screen program moves it — hidden in alt-screen (Zellij/TUI) tabs.

**Architecture:** Two pure local helpers (`group_thousands`, `format_line_status`) added to the existing right-status helper cluster in `wezterm.lua`, plus one `table.insert` into `render_right_status`. The module reuses the dimensions, separator, width-adaptation, and "Copied!" badge machinery already in that function. No new files, no new wezterm events, no new keybinds.

**Tech Stack:** Lua (WezTerm config). Syntax validated with `luaparse` via the local node toolchain; behavior verified live on the Windows host.

## Global Constraints

- **Single file for the feature logic:** `chezmoi/dot_config/wezterm/wezterm.lua`. All edits OUTSIDE the `-- HOSTS:START` / `-- HOSTS:END` sentinel block (lines 18–75) — never touch inside it.
- **Consumed on Windows** via `WEZTERM_CONFIG_FILE` pointing at the chezmoi **source** path; the file is LF, mode `100644`, UTF-8 (already contains emoji). Keep LF — no CRLF.
- **API facts (do not deviate):** the live scroll offset is NOT exposed by WezTerm and `update-status` does not fire on scroll, so "rows on screen" is the viewport **height** only. `pane:get_dimensions()` → `scrollback_rows` (total scrollback+viewport), `viewport_rows`, `scrollback_top` (stable index of earliest line), `cols`. `pane:get_cursor_position().y` is a stable row index. `pane:is_alt_screen_active()` is true under Zellij/helix/less/htop/vim.
- **Visibility rule (all must hold):** not alt-screen, `scrollback_rows > viewport_rows`, `cols >= 100`.
- **Format:** icon `↕` (U+2195), separator ` · `, exact thousands-grouped numbers, label `<rows> rows`. `↕ <total> · <rows> rows` normally; `↕ <pos>/<total> · <rows> rows` when `pos < total`.
- **Syntax gate (run after every `wezterm.lua` edit):**
  ```bash
  cd /tmp/lua-syntax-check && node check.js /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/wezterm/wezterm.lua
  ```
  Expected: `SYNTAX OK: …/wezterm.lua`. (Setup for this harness is Task 0.)
- **No README update for the footer cosmetics is strictly required** (the existing battery/time/copied-badge modules are undocumented), but the approved spec calls for a one-line lede note + a changelog row — included as Task 3. No CLAUDE.md invariant or `docs/claude/file-care.md` change (self-contained, no new cross-file coupling).

---

### Task 0: Set up the Lua syntax-check harness

One-time scaffolding so every later task has a real, reproducible syntax gate (no Lua interpreter exists on this host; `sudo` is not passwordless; node + npx are present).

**Files:**
- Create: `/tmp/lua-syntax-check/check.js` (throwaway, not committed)

- [ ] **Step 1: Create the harness and install luaparse**

```bash
cd /tmp && rm -rf lua-syntax-check && mkdir lua-syntax-check && cd lua-syntax-check
npm install luaparse@0.3.1
cat > check.js <<'EOF'
const fs = require('fs');
const luaparse = require('luaparse');
const file = process.argv[2];
try {
  luaparse.parse(fs.readFileSync(file, 'utf8'), { luaVersion: '5.3' });
  console.log('SYNTAX OK:', file);
  process.exit(0);
} catch (e) {
  console.error('SYNTAX ERROR:', file);
  console.error(e.message);
  process.exit(1);
}
EOF
```

- [ ] **Step 2: Verify it passes on the current (unmodified) file**

Run:
```bash
cd /tmp/lua-syntax-check && node check.js /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: `SYNTAX OK: …/wezterm.lua` (exit 0). This is the baseline — the file parses cleanly before any edits.

No commit (the harness lives in `/tmp`, outside the repo).

---

### Task 1: Add the helpers and wire the line-count into the footer

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` — add two local helpers after `time_icon` (currently ends line 977), and one `table.insert` inside `render_right_status` (after the domain/`zellij:main` block, currently the `end` at line 1006, before the battery block at line 1008).

**Interfaces:**
- Consumes: `pane:get_dimensions()`, `pane:get_cursor_position()`, `pane:is_alt_screen_active()` (WezTerm Pane API); the `dim_info` and `cols` locals already computed at the top of `render_right_status` (lines 988–989).
- Produces: `format_line_status(pane, dim_info, cols)` → `string | nil`; `group_thousands(n)` → `string`.

- [ ] **Step 1: Add the `group_thousands` and `format_line_status` helpers**

Insert immediately AFTER the closing `end` of `time_icon` (line 977) and BEFORE the `-- "Copied!" badge` comment (line 979):

```lua

-- group_thousands(10234) -> '10,234'. Lua has no built-in digit grouping.
-- Non-negative integers only (line counts), so no sign handling.
local function group_thousands(n)
  local s   = tostring(math.floor(n))
  local rev = s:reverse():gsub('(%d%d%d)', '%1,')  -- comma after every 3 digits
  local out = rev:reverse():gsub('^,', '')         -- un-reverse, drop leading comma
  return out
end

-- Active-pane line-count for the right status. Returns a display string, or nil
-- when the module should be HIDDEN: dimensions unavailable, window too narrow,
-- the pane is on the alternate screen (Zellij/helix/less/htop — no scrollback),
-- or there's no real scrollback yet (total <= rows-on-screen; also covers a
-- fresh shell). WezTerm exposes no live scroll offset and update-status doesn't
-- fire on scroll, so 'rows' is the viewport HEIGHT, never a scrolled range.
--   '↕ 10,234 · 38 rows'        cursor on the last line (at a shell prompt)
--   '↕ 9,800/10,234 · 38 rows'  a main-screen program moved the cursor up
local function format_line_status(pane, dim_info, cols)
  if not dim_info then return nil end
  if cols < 100 then return nil end
  if pane:is_alt_screen_active() then return nil end
  local total = dim_info.scrollback_rows or 0
  local rows  = dim_info.viewport_rows or 0
  if total <= rows then return nil end
  local pos = total
  local cur = pane:get_cursor_position()
  if cur and dim_info.scrollback_top then
    pos = math.max(1, math.min(total, cur.y - dim_info.scrollback_top + 1))
  end
  if pos < total then
    return string.format('↕ %s/%s · %d rows',
      group_thousands(pos), group_thousands(total), rows)
  end
  return string.format('↕ %s · %d rows', group_thousands(total), rows)
end
```

- [ ] **Step 2: Syntax gate**

Run:
```bash
cd /tmp/lua-syntax-check && node check.js /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: `SYNTAX OK: …/wezterm.lua`. If `SYNTAX ERROR`, fix the reported line before continuing.

- [ ] **Step 3: Wire the part into `render_right_status`**

In `render_right_status`, find the end of the domain/`zellij:main` block and the start of the battery block:

```lua
    if cols >= 130 then
      table.insert(parts, { text = 'zellij:main' })
    end
  end

  if cols >= 80 then
```

Insert the line-status block BETWEEN the domain block's closing `end` and the `if cols >= 80 then` battery block, so it reads:

```lua
    if cols >= 130 then
      table.insert(parts, { text = 'zellij:main' })
    end
  end

  local line_status = format_line_status(pane, dim_info, cols)
  if line_status then
    table.insert(parts, { text = line_status })
  end

  if cols >= 80 then
```

(Placement rationale: after the SSH-only domain block, so on local/WSL tabs — which have no domain block — it leads the footer, and on a main-screen SSH tab it follows `domain · zellij:main`. It precedes battery/time and is the first adaptive entry to drop, via its own `cols >= 100` gate.)

- [ ] **Step 4: Syntax gate**

Run:
```bash
cd /tmp/lua-syntax-check && node check.js /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: `SYNTAX OK: …/wezterm.lua`.

- [ ] **Step 5: Verify line-endings and mode are unchanged**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
file chezmoi/dot_config/wezterm/wezterm.lua
git ls-files --stage chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: `file` output does NOT contain "CRLF"; `git ls-files --stage` shows mode `100644`. (If CRLF appears: `sed -i 's/\r$//' chezmoi/dot_config/wezterm/wezterm.lua`.)

- [ ] **Step 6: Confirm the HOSTS sentinel block is untouched**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git diff -U0 chezmoi/dot_config/wezterm/wezterm.lua | rg -n 'HOSTS:START|HOSTS:END|remote_address|ssh_domains' || echo "sentinel block untouched (good)"
```
Expected: `sentinel block untouched (good)` — the diff must not touch any line inside `-- HOSTS:START`/`-- HOSTS:END`.

- [ ] **Step 7: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "$(cat <<'EOF'
feat(wezterm): show active-tab line count in the right-status footer

Adds group_thousands + format_line_status helpers and inserts a
line-count part into render_right_status: total scrollback lines +
viewport height, with cursor position shown only when a main-screen
program moves the cursor off the last line. Hidden in alt-screen
(Zellij/TUI) tabs, when no real scrollback exists, and below 100 cols.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NxVVdpEjLEZrTiuNvLKZVc
EOF
)"
```

---

### Task 2: Add a cheatsheet note for the footer readout

The in-app `CTRL+SHIFT+H` overlay is the real discoverability surface. Add one informational `note` row to `help_choices`.

**Files:**
- Modify: `chezmoi/dot_config/wezterm/wezterm.lua` — `help_choices`, immediately after the `CTRL+SHIFT+A     Copy entire scrollback to clipboard` row (line 854).

- [ ] **Step 1: Add the note row**

Find this line in `help_choices`:

```lua
    { label = 'key   CTRL+SHIFT+A     Copy entire scrollback to clipboard', id = '' },
```

Insert directly AFTER it:

```lua
    { label = 'note  footer ↕        Active tab line count: total · rows on screen (cursor line when a program moves it; hidden in full-screen apps)', id = '' },
```

- [ ] **Step 2: Syntax gate**

Run:
```bash
cd /tmp/lua-syntax-check && node check.js /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/wezterm/wezterm.lua
```
Expected: `SYNTAX OK: …/wezterm.lua`.

- [ ] **Step 3: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/dot_config/wezterm/wezterm.lua
git commit -m "$(cat <<'EOF'
docs(wezterm): note the footer line-count readout in the CTRL+SHIFT+H cheatsheet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NxVVdpEjLEZrTiuNvLKZVc
EOF
)"
```

---

### Task 3: README lede sentence + changelog row

**Files:**
- Modify: `README.html` — the `#setup-wezterm` lede (lines 3058–3068).
- Modify: `CLAUDE_CHANGELOG.md` — append one table row.

- [ ] **Step 1: Add a sentence to the WezTerm lede**

Find the end of the lede paragraph:

```html
                        <kbd>WIN</kbd>+drag); <kbd>WIN</kbd>+arrow snapping and
                        edge resizing still work as usual.
                    </p>
```

Replace it with (adds one sentence before `</p>`):

```html
                        <kbd>WIN</kbd>+drag); <kbd>WIN</kbd>+arrow snapping and
                        edge resizing still work as usual. The bottom status
                        bar shows the active tab&rsquo;s line count &mdash;
                        total scrollback lines and rows on screen (plus the
                        cursor&rsquo;s line when a program moves it off the
                        bottom); it&rsquo;s hidden inside full-screen apps like
                        Zellij.
                    </p>
```

- [ ] **Step 2: Confirm README is well-formed (no stray tag breakage)**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
rg -n 'edge resizing still work as usual\.' README.html
rg -c '<p class="lede">' README.html
```
Expected: the first command shows the sentence now continues past "as usual." within the same `<p>`; the second prints an unchanged count of lede paragraphs (sanity that no `<p>` was duplicated/dropped).

- [ ] **Step 3: Append a CLAUDE_CHANGELOG row**

Append this row to the table at the end of `CLAUDE_CHANGELOG.md` (match the existing `| change | README? | reasoning |` 3-column format):

```markdown
| Added an active-tab line-count readout to the WezTerm right-status footer (`render_right_status` in `chezmoi/dot_config/wezterm/wezterm.lua`): `↕ <total> · <rows> rows`, with `<pos>/<total>` shown only when a main-screen program moves the cursor off the last line. New `group_thousands` + `format_line_status` helpers; hidden in alt-screen (Zellij/TUI) tabs, when `scrollback_rows <= viewport_rows`, and below 100 cols. WezTerm exposes no live scroll offset, so "rows" is the viewport height, not a scrolled range. Also a `CTRL+SHIFT+H` cheatsheet `note` row. | Yes | New user-visible footer surface → one-sentence note added to the `#setup-wezterm` lede (consistent with where the 2026-06-11 chrome-polish change documented the title-bar removal). |
```

- [ ] **Step 4: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: note the WezTerm footer line-count readout (README lede + changelog)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NxVVdpEjLEZrTiuNvLKZVc
EOF
)"
```

---

### Task 4: Live verification on the Windows host

The only way to confirm the WezTerm API field names and the visual integration (no Lua runtime here, GUI app not installed on this box). Run after the commits land and the Windows host has the updated repo.

**Files:** none (manual verification).

- [ ] **Step 1: Pull the change onto the Windows host**

On Windows, the config is read directly from the repo via `WEZTERM_CONFIG_FILE`. Update the working tree on that host (or this branch), then in WezTerm press `CTRL`+`SHIFT`+`R` to reload. Expected: no config-error toast (a Lua error would show a red error overlay and fall back to defaults).

- [ ] **Step 2: Local/WSL tab — readout appears with scrollback**

In a local Nushell or WSL tab, run something that prints well over one screenful, e.g. `seq 1 500`. Expected: the footer (next to 🔋/🕐) shows `↕ <n> · <rows> rows` where `<n>` grows past the viewport height and `<rows>` equals the window's row count. At the prompt no `pos/total` slash appears.

- [ ] **Step 3: Zellij/SSH tab — readout hidden**

Open an SSH host tab (runs Zellij). Expected: the footer looks exactly as before — `domain · zellij:main · 🔋 … · 🕐 …`, with NO `↕` line-count segment.

- [ ] **Step 4: Width gate**

Narrow the window below ~100 columns. Expected: the `↕` segment drops out first (battery/time persist down to their own lower thresholds).

- [ ] **Step 5: Copy badge still overlays**

With output on screen, select text and press `CTRL`+`SHIFT`+`C`. Expected: the `📋 Copied!` badge replaces the whole right status for ~2s (covering the line-count segment), then the line-count returns.

- [ ] **Step 6: Cheatsheet note**

Press `CTRL`+`SHIFT`+`H` and type `footer`. Expected: the new `note  footer ↕  …` row is listed.

---

## Self-review notes

- **Spec coverage:** placement (Task 1 wiring), alt-screen hide (`is_alt_screen_active` guard, Task 1 Step 1), no-scrollback hide (`total <= rows`), cursor-only-when-meaningful (`pos < total` branch), width gate (`cols >= 100`), `group_thousands` formatting, cheatsheet note (Task 2), README + changelog (Task 3), live verification incl. badge interaction (Task 4). All spec sections map to a task.
- **No placeholders:** every code/edit step shows the exact content; every command states expected output.
- **Type/name consistency:** `group_thousands` and `format_line_status` are defined in Task 1 Step 1 and called with the same signatures in the Task 1 Step 3 wiring; field names (`scrollback_rows`, `viewport_rows`, `scrollback_top`, `cur.y`) match the Global Constraints API facts.
