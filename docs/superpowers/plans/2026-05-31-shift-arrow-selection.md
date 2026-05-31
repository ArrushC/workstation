# Shift+Arrow editor-style selection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Shift+Arrow` perform editor-style text selection at the zsh prompt (and movement-parity in bash), fixing the `;2D` leak, without preventing other CLI tools from overriding `Shift+Arrow`.

**Architecture:** The fix lives entirely in the shell line editor — never in WezTerm, which keeps sending `ESC[1;2D`. zsh sources a pinned, vendored copy of `jirutka/zsh-shift-select` plus two small rc supplements (replace-on-type, OSC 52 clipboard copy). bash gets readline `bind` lines that map the same sequences to plain movement (readline can't render a live selection). Because ZLE/readline only act at the prompt, any full-screen tool receives the raw escape and applies its own binding.

**Tech Stack:** zsh ZLE (`region_active`, custom keymap, widgets), bash readline `bind`, chezmoi templates, vendored upstream file (MIT).

**Spec:** `docs/superpowers/specs/2026-05-31-shift-arrow-selection-design.md`

---

## File structure

| File | Responsibility |
|---|---|
| `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh` | **New.** Verbatim vendored jirutka v0.1.1 + provenance header. The selection engine. |
| `chezmoi/dot_zshrc.tmpl` | Source the plugin + two supplements (replace-on-type, OSC 52 copy). |
| `chezmoi/dot_bashrc.tmpl` | Parity `bind` lines (movement only). |
| `chezmoi/.chezmoiignore.tmpl` | Ignore `dot_config/zsh` on Windows. |
| `README.html` | New "Shell prompt selection" `<h3>` + key table + TOC entry. |
| `CLAUDE_CHANGELOG.md` | One precedent row. |
| `CLAUDE.md` | Two "Files Claude should be careful with" entries. |

Notes on conventions (already verified against the repo):
- The vendored `.zsh` is **static** (no `.tmpl`), deploys on **dev and prod** (general shell nicety, not behind the dev gate), must be **LF-only**.
- `dot_zshrc.tmpl` / `dot_bashrc.tmpl` are a **strict parity pair** — both edited in the same commit; a comment in each notes the deliberate zsh-only-highlight asymmetry.
- Commit trailer for every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- Run all commands from the repo root: `/home/arrush.chaturvedi/.local/share/chezmoi`.

---

## Task 1: Vendor the plugin + Windows ignore

**Files:**
- Create: `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows block)

- [ ] **Step 1: Download the pinned upstream file and write the vendored copy with a provenance header**

Run (from repo root):

```bash
mkdir -p chezmoi/dot_config/zsh/plugins
curl -fsSL https://raw.githubusercontent.com/jirutka/zsh-shift-select/v0.1.1/zsh-shift-select.plugin.zsh -o /tmp/zss-upstream.zsh
SHA=$(sha256sum /tmp/zss-upstream.zsh | awk '{print $1}')
{
  printf '# Vendored from jirutka/zsh-shift-select (MIT). DO NOT HAND-EDIT.\n'
  printf '# Upstream: https://github.com/jirutka/zsh-shift-select\n'
  printf '# Pinned:   tag v0.1.1 (commit 47296f18c52e9cdff5ddf0c28a5cc8c88ef8696e)\n'
  printf '# Upstream raw sha256: %s\n' "$SHA"
  printf '# This copy only prepends this header; the body below is byte-verbatim upstream.\n'
  printf '# Bump: re-download the pinned tag, refresh the sha256, update this header.\n'
  printf '# Sourced from ~/.zshrc; supplemented there (replace-on-type, OSC 52 copy).\n'
  printf '#\n'
  cat /tmp/zss-upstream.zsh
} > chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh
echo "vendored sha256: $SHA"
```

- [ ] **Step 2: Verify the vendored file is LF-only and contains the expected engine**

Run:

```bash
file chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh
grep -c "bindkey -N shift-select" chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh
grep -c "shift-select::deselect-and-input" chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh
zsh -n chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh && echo "syntax OK"
```

Expected: `file` output does **not** contain "CRLF"; both `grep -c` print `1` (the keymap) and `>=1` (the widget); `syntax OK`.

- [ ] **Step 3: Ignore the new path on Windows**

In `chezmoi/.chezmoiignore.tmpl`, the Windows block currently reads (lines ~14-30):

```
{{ if eq .chezmoi.os "windows" }}
# --- On Windows, ignore Linux-only dotfiles ---------------------------------
dot_bashrc.tmpl
dot_nbrc
dot_dircolors
dot_config/helix
dot_config/zellij
```

Add `dot_config/zsh` immediately after `dot_config/zellij`:

```
dot_config/helix
dot_config/zellij
dot_config/zsh
```

- [ ] **Step 4: Verify the ignore renders (Linux host must NOT ignore it)**

Run:

```bash
chezmoi execute-template < chezmoi/.chezmoiignore.tmpl | grep -n 'dot_config/zsh' || echo "not present on this (Linux) host — correct"
```

Expected: on a Linux host the line is absent from the rendered output (the Windows block doesn't render) → prints "not present on this (Linux) host — correct". (The entry only takes effect when `.chezmoi.os == windows`.)

- [ ] **Step 5: Commit**

```bash
git add chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh chezmoi/.chezmoiignore.tmpl
git commit -m "$(cat <<'EOF'
feat(zsh): vendor pinned jirutka/zsh-shift-select for Shift+Arrow selection

Pinned v0.1.1 (commit 47296f18). Static, LF-only, deploys dev+prod.
Windows ignores dot_config/zsh. Sourced + supplemented in dot_zshrc.tmpl
in the next commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: zsh — source the plugin + supplements

**Files:**
- Modify: `chezmoi/dot_zshrc.tmpl` (insert a new section after the WezTerm OSC 7 block)

- [ ] **Step 1: Insert the Shift+Arrow selection block**

In `chezmoi/dot_zshrc.tmpl`, find the end of the WezTerm OSC 7 section — the line:

```
add-zsh-hook -Uz precmd __wezterm_osc7
```

immediately followed by:

```
# --- nb (notes) --------------------------------------------------------------
```

Insert the following block **between** them (after `add-zsh-hook -Uz precmd __wezterm_osc7`, before `# --- nb (notes) ---`):

```zsh

# --- Shift+Arrow selection (zsh ZLE) -----------------------------------------
# Editor-style text selection at the prompt: Shift+arrows (and Shift+Ctrl+arrows
# / Shift+Home/End) extend a visible highlight; typing replaces it; Backspace/
# Delete removes it; Alt+W copies (kill-ring + system clipboard), Ctrl+W cuts,
# Ctrl+Y pastes. Ctrl+C is intentionally left alone (stays SIGINT).
#
# This lives in the line editor ON PURPOSE: ZLE only handles keys at the prompt,
# so any full-screen CLI tool (helix, fzf, less, `git rebase -i`, …) receives the
# raw ESC[1;2D escape and applies its OWN binding — full override, no per-tool
# config. Engine: vendored jirutka/zsh-shift-select (~/.config/zsh/plugins/).
# bash gets movement-only parity (no highlight — readline limitation); the two
# rc files are a parity pair, so the bash side lives in dot_bashrc.tmpl.
zmodload zsh/parameter zsh/zleparameter 2>/dev/null
if [[ -r "$HOME/.config/zsh/plugins/zsh-shift-select.zsh" ]]; then
  source "$HOME/.config/zsh/plugins/zsh-shift-select.zsh"

  # Supplement 1 — replace-on-type. The vendored plugin's deselect-and-input
  # only collapses the selection then re-inputs the key (leaving the selected
  # text in place). Override it so a single printable key first excises the
  # selected text via direct $BUFFER slicing (no kill-ring pollution), then the
  # re-pushed key self-inserts at the collapsed point — i.e. type-to-replace.
  if (( ${+functions[shift-select::deselect-and-input]} )); then
    function shift-select::deselect-and-input() {
      if (( REGION_ACTIVE )) && [[ ${#KEYS} -eq 1 && $KEYS == [[:print:]] ]]; then
        local from=$MARK to=$CURSOR
        (( from > to )) && { from=$CURSOR; to=$MARK; }
        BUFFER="${BUFFER[1,from]}${BUFFER[to+1,-1]}"
        CURSOR=$from
      fi
      zle deactivate-region -w
      zle -K main
      zle -U "$KEYS"
    }
  fi

  # Supplement 2 — Alt+W (copy-region-as-kill) also copies the selection to the
  # SYSTEM clipboard via OSC 52, so it works outside the shell and over SSH (the
  # terminal performs the write). Kill-ring behavior is preserved. No-op without
  # base64. The OSC 52 bytes are non-printing, so the line display is undisturbed.
  if (( ${+widgets[copy-region-as-kill]} )) && command -v base64 >/dev/null 2>&1; then
    function shift-select::copy-osc52() {
      zle .copy-region-as-kill -w
      local b64
      b64=$(printf '%s' "$CUTBUFFER" | base64 | tr -d '\n')
      print -rn -- $'\e]52;c;'"$b64"$'\a' >/dev/tty 2>/dev/null
    }
    zle -N copy-region-as-kill shift-select::copy-osc52
  fi
fi
```

- [ ] **Step 2: Verify the rendered template parses under zsh**

Run:

```bash
chezmoi execute-template < chezmoi/dot_zshrc.tmpl > /tmp/zshrc.rendered && zsh -n /tmp/zshrc.rendered && echo "zsh syntax OK"
```

Expected: `zsh syntax OK` (no parse errors).

- [ ] **Step 3: Apply the plugin file + zshrc to this host**

Run:

```bash
chezmoi apply "$HOME/.config/zsh/plugins/zsh-shift-select.zsh" "$HOME/.zshrc"
test -r "$HOME/.config/zsh/plugins/zsh-shift-select.zsh" && echo "plugin deployed"
```

Expected: `plugin deployed`.

- [ ] **Step 4: Verify the keymap, the replace-on-type override, and the OSC 52 override registered**

Run:

```bash
zsh -ic 'bindkey -l | grep -x shift-select && echo KEYMAP_OK'
zsh -ic 'echo "deselect: $functions[shift-select::deselect-and-input]" | grep -q "BUFFER\[1,from\]" && echo REPLACE_OK'
zsh -ic 'echo "copy widget: $widgets[copy-region-as-kill]"'
zsh -ic 'bindkey -M shift-select | grep -F "1;2D" && echo SHIFTLEFT_BOUND'
```

Expected:
- `shift-select` + `KEYMAP_OK`
- `REPLACE_OK` (our override body is in place — contains the `$BUFFER[1,from]` slice)
- `copy widget: user:shift-select::copy-osc52` (the Alt+W widget points at our wrapper)
- a line binding `^[[1;2D` to a `shift-select::` widget + `SHIFTLEFT_BOUND`

- [ ] **Step 5: Manual interactive smoke test (zsh, in a WezTerm pane)**

In a fresh zsh prompt inside WezTerm, type `hello world`, then:

1. `Shift+Left` ×5 — the last 5 chars highlight (no `;2D` text appears).
2. Type `x` — selection is replaced by `x` → buffer reads `hello x`.
3. `Shift+Ctrl+Left` — previous word highlights; `Backspace` deletes it.
4. Press plain `Left` — highlight collapses, cursor just moves.
5. Re-select a few chars, press `Alt+W`, then paste elsewhere (or `Ctrl+Y` in the line) — the text is on the clipboard.

Expected: all behave as described; `Ctrl+C` still aborts the line.

- [ ] **Step 6: Commit** (held until Task 3 so the parity pair lands together — see Task 3, Step 4.)

---

## Task 3: bash — movement-parity bind lines

**Files:**
- Modify: `chezmoi/dot_bashrc.tmpl` (insert after the colored-completion `bind` lines)

- [ ] **Step 1: Insert the bind block**

In `chezmoi/dot_bashrc.tmpl`, find:

```
bind 'set colored-stats on'
bind 'set colored-completion-prefix on'
```

Insert the following block immediately **after** `bind 'set colored-completion-prefix on'`:

```bash

# --- Shift+Arrow movement (readline) -----------------------------------------
# WezTerm sends ESC[1;2D etc. for Shift+Arrow; readline has no default binding,
# so the tail (";2D") leaks into the line. Bind them to plain movement so the
# leak is gone and navigation is sane. PARITY NOTE: zsh gets a real, visible
# shift-SELECT highlight (see dot_zshrc.tmpl); readline has no "active selection
# you can type over", so bash deliberately gets movement-only. Keep both files
# in sync per the parity-pair invariant.
bind '"\e[1;2D": backward-char'      # Shift + Left
bind '"\e[1;2C": forward-char'       # Shift + Right
bind '"\e[1;2A": previous-history'   # Shift + Up   (same as plain Up)
bind '"\e[1;2B": next-history'       # Shift + Down (same as plain Down)
bind '"\e[1;2H": beginning-of-line'  # Shift + Home
bind '"\e[1;2F": end-of-line'        # Shift + End
bind '"\e[1;6D": backward-word'      # Shift + Ctrl + Left
bind '"\e[1;6C": forward-word'       # Shift + Ctrl + Right
bind '"\e[1;6H": beginning-of-line'  # Shift + Ctrl + Home
bind '"\e[1;6F": end-of-line'        # Shift + Ctrl + End
```

- [ ] **Step 2: Verify the rendered template parses under bash**

Run:

```bash
chezmoi execute-template < chezmoi/dot_bashrc.tmpl > /tmp/bashrc.rendered && bash -n /tmp/bashrc.rendered && echo "bash syntax OK"
```

Expected: `bash syntax OK`.

- [ ] **Step 3: Apply and verify the bindings registered**

Run:

```bash
chezmoi apply "$HOME/.bashrc"
bash -ic 'bind -p 2>/dev/null | grep -F "\e[1;2D"'
bash -ic 'bind -p 2>/dev/null | grep -F "\e[1;6C"'
```

Expected: `"\e[1;2D": backward-char` and `"\e[1;6C": forward-word` (proves the leak is gone — Shift+Left now moves instead of self-inserting `;2D`).

- [ ] **Step 4: Commit the parity pair together**

```bash
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl
git commit -m "$(cat <<'EOF'
feat(shell): Shift+Arrow selection (zsh) + movement parity (bash)

zsh sources the vendored shift-select engine + two supplements:
replace-on-type (override deselect-and-input to excise the region via
$BUFFER slice) and OSC 52 system-clipboard copy (wrap copy-region-as-kill,
keeps kill-ring). Ctrl+C left as SIGINT. bash readline can't render a live
selection, so it gets the same keys as plain movement — kills the ;2D leak.
Parity pair: both rc files in one commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: README.html — document the prompt keys

**Files:**
- Modify: `README.html` (TOC list + new `<h3>` after the WezTerm keybinds section)

- [ ] **Step 1: Add the TOC entry**

In `README.html`, find this TOC sub-list entry:

```html
                            <li>
                                <a href="#setup-wezterm">WezTerm keybinds</a>
                            </li>
                        </ol>
```

Insert a new `<li>` after the WezTerm keybinds `</li>` and before `</ol>`:

```html
                            <li>
                                <a href="#setup-wezterm">WezTerm keybinds</a>
                            </li>
                            <li>
                                <a href="#prompt-keys">Shell prompt selection</a>
                            </li>
                        </ol>
```

- [ ] **Step 2: Add the section after the WezTerm keybinds table**

Find the end of the WezTerm keybinds section — the `</table>` followed by `</section>`:

```html
                        </tbody>
                    </table>
                </section>

                <section id="hosts">
```

Insert the new `<h3>` + table **between** `</table>` and `</section>` (i.e. inside the same section, after the WezTerm table):

```html
                        </tbody>
                    </table>

                    <h3 id="prompt-keys">Shell prompt selection</h3>
                    <p class="lede">
                        At the <code>zsh</code> prompt, <kbd>SHIFT</kbd>+arrow
                        keys select text like a normal editor — extend a
                        highlight, type to replace it, <kbd>BACKSPACE</kbd> to
                        delete it. These bind in the shell line editor only, so
                        any full-screen tool (helix, fzf, <code>less</code>)
                        keeps its own <kbd>SHIFT</kbd>+arrow behaviour.
                        <code>bash</code> maps the same keys to plain cursor
                        movement (no highlight — a readline limitation).
                    </p>
                    <table>
                        <thead>
                            <tr>
                                <th>Bind</th>
                                <th>Action</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr>
                                <td>
                                    <kbd>SHIFT</kbd>+<kbd>&larr;</kbd> /
                                    <kbd>SHIFT</kbd>+<kbd>&rarr;</kbd>
                                </td>
                                <td>Extend selection by character</td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>SHIFT</kbd>+<kbd>CTRL</kbd>+<kbd
                                        >&larr;</kbd
                                    >
                                    / <kbd>SHIFT</kbd>+<kbd>CTRL</kbd>+<kbd
                                        >&rarr;</kbd
                                    >
                                </td>
                                <td>Extend selection by word</td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>SHIFT</kbd>+<kbd>HOME</kbd> /
                                    <kbd>SHIFT</kbd>+<kbd>END</kbd>
                                </td>
                                <td>Extend selection to line start / end</td>
                            </tr>
                            <tr>
                                <td>Type any character</td>
                                <td>Replace the selection (zsh)</td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>BACKSPACE</kbd> / <kbd>DELETE</kbd>
                                </td>
                                <td>Delete the selection (zsh)</td>
                            </tr>
                            <tr>
                                <td>
                                    <kbd>ALT</kbd>+<kbd>W</kbd> /
                                    <kbd>CTRL</kbd>+<kbd>W</kbd> /
                                    <kbd>CTRL</kbd>+<kbd>Y</kbd>
                                </td>
                                <td>
                                    Copy / cut / paste selection (zsh) — copy
                                    also reaches the system clipboard via OSC 52,
                                    including over SSH
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </section>

                <section id="hosts">
```

- [ ] **Step 3: Verify the HTML is well-formed and the anchors line up**

Run:

```bash
grep -c 'id="prompt-keys"' README.html
grep -c 'href="#prompt-keys"' README.html
python3 -c "import html.parser,sys
class P(html.parser.HTMLParser):
    pass
P().feed(open('README.html',encoding='utf-8').read()); print('parsed OK')"
```

Expected: both `grep -c` print `1`; `parsed OK`. Then open `README.html` in a browser and confirm the new "Shell prompt selection" table renders styled (tabs/cards intact) and the TOC link scrolls to it.

- [ ] **Step 4: Commit**

```bash
git add README.html
git commit -m "$(cat <<'EOF'
docs(readme): document Shift+Arrow shell prompt selection keys

New "Shell prompt selection" section + key table after WezTerm keybinds,
plus a TOC entry. Notes zsh selection vs bash movement-only parity.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: CLAUDE_CHANGELOG.md + CLAUDE.md

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one table row at end of the table)
- Modify: `CLAUDE.md` ("Files Claude should be careful with" list)

- [ ] **Step 1: Append the changelog row**

Add this row as the **last line** of the table in `CLAUDE_CHANGELOG.md` (append after the final existing `|...|` row):

```
| Added Shift+Arrow editor-style text selection at the shell prompt: vendored `jirutka/zsh-shift-select` v0.1.1 (pinned, MIT, single file) to `chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`, sourced from `dot_zshrc.tmpl` with two rc supplements — replace-on-type (override `shift-select::deselect-and-input` to excise the region via a `$BUFFER` slice) and OSC 52 system-clipboard copy (wrap `copy-region-as-kill`, kill-ring preserved). `dot_bashrc.tmpl` gets movement-only parity `bind` lines (readline can't render a live selection). `dot_config/zsh` added to the Windows `.chezmoiignore.tmpl` block. The fix lives in the line editor on purpose so full-screen CLI tools keep overriding Shift+Arrow; `Ctrl+C` left as SIGINT. | **Yes** | New `<h3 id="prompt-keys">Shell prompt selection</h3>` + key table after the WezTerm keybinds section, plus a TOC entry nested under Setup. CLAUDE.md gains file-care entries for the vendored plugin file and the two `dot_zshrc.tmpl` supplements (with the parity-pair note pointing at `dot_bashrc.tmpl`). |
```

- [ ] **Step 2: Add the CLAUDE.md file-care entries**

In `CLAUDE.md`, under the `## Files Claude should be careful with` list, add these two bullets (place them after the existing `dot_dircolors` / wezterm-terminfo entries, anywhere in the list):

```markdown
- **`chezmoi/dot_config/zsh/plugins/zsh-shift-select.zsh`** — vendored from `jirutka/zsh-shift-select` at a pinned tag (recorded in the file's leading `#` header: tag `v0.1.1`, commit, upstream sha256). MIT, single file, zero deps. Provides the `shift-select` ZLE keymap + Shift+Arrow selection widgets at the prompt. Static (no `.tmpl`), **LF-only**, deploys on BOTH dev and prod (a general shell nicety, not behind the `.chezmoiignore.tmpl` dev gate); Windows-ignored via the `dot_config/zsh` line in the Windows block. Editing this file by hand defeats the vendoring contract — bump by re-downloading the pinned tag, refreshing the sha256, and updating the header. Sourced (and supplemented) by `dot_zshrc.tmpl`.
- **`chezmoi/dot_zshrc.tmpl` Shift+Arrow block** — sources the vendored `zsh-shift-select.zsh`, then layers two supplements the upstream plugin lacks: (1) **replace-on-type** — overrides `shift-select::deselect-and-input` so a single printable key excises the active region via a direct `$BUFFER[1,from]…$BUFFER[to+1,-1]` slice (no kill-ring pollution) before the key self-inserts; (2) **OSC 52 copy** — wraps the `copy-region-as-kill` widget (`Alt+W`) to also emit `\e]52;c;<base64>\a` so the selection reaches the system clipboard over SSH. Guarded by `zmodload zsh/parameter zsh/zleparameter` + `${+functions[…]}`/`${+widgets[…]}` existence checks, so it's a no-op if the vendored file isn't applied yet. `Ctrl+C` is deliberately NOT rebound (stays SIGINT). The override relies on the widget→function name mapping (redefining the function re-points the existing widget) — do not rename `shift-select::deselect-and-input` without re-checking against the vendored file. **Parity pair:** `dot_bashrc.tmpl` carries the bash side (movement-only `bind` lines — readline can't render a live selection); the asymmetry is intentional and commented in both files. Any change to the bound key set must land in both.
```

- [ ] **Step 3: Verify markdown table integrity**

Run:

```bash
tail -1 CLAUDE_CHANGELOG.md | grep -c '^| Added Shift+Arrow'
grep -c 'zsh-shift-select.zsh' CLAUDE.md
```

Expected: `1` and `>=1`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE_CHANGELOG.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): changelog row + file-care entries for Shift+Arrow selection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final integration verification

**Files:** none (verification only).

- [ ] **Step 1: Clean apply with no surprises**

Run:

```bash
chezmoi diff | head -40
chezmoi status
```

Expected: nothing unexpected; the only managed paths touched are `~/.zshrc`, `~/.bashrc`, and `~/.config/zsh/plugins/zsh-shift-select.zsh` (already applied in Tasks 2-3, so `chezmoi status` should be clean for them).

- [ ] **Step 2: Confirm the `;2D` leak is gone in both shells (structural)**

Run:

```bash
zsh -ic 'bindkey -M shift-select | grep -F "1;2D" >/dev/null && echo "zsh: Shift-Left bound"'
bash -ic 'bind -p 2>/dev/null | grep -F "\e[1;2D" >/dev/null && echo "bash: Shift-Left bound"'
```

Expected: `zsh: Shift-Left bound` and `bash: Shift-Left bound`.

- [ ] **Step 3: Confirm overriding still works in a full-screen tool**

Open a file in helix (`hx /tmp/x.txt`), enter insert mode, type a few words, and press `Shift+Left`. Expected: helix applies *its own* Shift+Left (extends helix selection / does helix's thing) — the shell binding does not interfere, proving the override requirement. Quit helix.

- [ ] **Step 4: Full interactive smoke test**

Repeat Task 2 Step 5 in a brand-new WezTerm tab (fresh login shell) to confirm the behavior survives a real shell startup, not just `zsh -ic`. Confirm: select → type replaces; `Backspace` deletes; plain arrow collapses; `Alt+W` → clipboard; `Ctrl+C` aborts the line.

- [ ] **Step 5: Push**

```bash
git push
```

Expected: all five commits (Tasks 1-5) land on `main`.

---

## Self-review notes (completed during plan authoring)

- **Spec coverage:** vendored file (T1), Windows ignore (T1), zsh source+replace-on-type+OSC52 (T2), bash parity (T3), README+TOC (T4), changelog+CLAUDE.md (T5), verification incl. override-still-works (T6). All spec sections map to a task.
- **No placeholders:** the sha256 is computed and embedded by the Step-1 command (not a literal TBD); all code blocks are complete.
- **Name consistency:** `shift-select::deselect-and-input`, `shift-select::copy-osc52`, `copy-region-as-kill`, keymap `shift-select`, path `~/.config/zsh/plugins/zsh-shift-select.zsh`, anchor `#prompt-keys` — used identically across tasks and match the verbatim vendored source.
- **Parity-pair invariant:** zsh (T2) + bash (T3) edited and committed together (T3 Step 4).
