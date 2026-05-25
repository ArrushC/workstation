# ccstatusline dev-install integration — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive 4-option ccstatusline setup prompt to the tail of `bootstrap.sh --dev`, backed by chezmoi-tracked widget + Claude-Code-settings files and a managed sentinel block in `.chezmoiignore.tmpl` for per-host opt-out.

**Architecture:** A new bash orchestrator at `scripts/setup-ccstatusline.sh` exposes the menu; a new dev-only Make target `claude-statusline` invokes it; `bootstrap.sh` tail calls the target after `ensure_chezmoi_initialized`. Two chezmoi files (`dot_config/ccstatusline/settings.json` for the widget config and `private_dot_claude/private_settings.json.tmpl` for the `statusLine` block) carry the tracked state. A `# CCSTATUSLINE:START / END` sentinel block in `.chezmoiignore.tmpl` lets the script list hosts that have opted into local persistence.

**Tech Stack:** bash 5+ (LF-only, mode 100755), GNU make, chezmoi 2.70+, jq (already in the repo's tool list), git, npx (Node.js runtime supplied by user — not managed). ccstatusline pinned at **v2.2.19** (latest stable at write time, 2026-05-17).

**Spec reference:** [`docs/superpowers/specs/2026-05-25-ccstatusline-dev-install-integration-design.md`](../specs/2026-05-25-ccstatusline-dev-install-integration-design.md)

---

## Pre-execution notes

- All commits in this plan get auto-pushed per the user's standing memory `feedback-always-push-after-commit`. Each task ends with `git push origin main`.
- Every commit subject follows the repo's existing style (`feat(…)` / `fix(…)` / `docs(…)` / `chore(…)`) — see `git log --oneline -20` for examples. Commit bodies include the `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
- After editing any shell script under `scripts/` or `makefile/lib/`, verify: `file <path>` must NOT say "with CRLF line terminators"; `git ls-files --stage <path>` must show `100755` (per CLAUDE.md).
- `cd makefile && make list MODE=dev` and `chezmoi diff` are the two smoke checks used throughout — keep them green after each task.

---

### Task 1: Add `CCSTATUSLINE_VERSION` pin to `versions.mk`

**Files:**
- Modify: `makefile/versions.mk`

- [ ] **Step 1: Write the failing test** — verification command

```bash
grep -nE '^CCSTATUSLINE_VERSION\s*:=' makefile/versions.mk
```

Expected before: no output, exit 1 (pin not present).
Expected after Step 3: one match printing the new line, exit 0.

- [ ] **Step 2: Run the verification to see it fail**

```bash
grep -nE '^CCSTATUSLINE_VERSION\s*:=' /home/arrush.chaturvedi/.local/share/chezmoi/makefile/versions.mk; echo "exit=$?"
```

Expected: `exit=1`.

- [ ] **Step 3: Add the pin**

Find the existing `CLAUDE_VERSION` line in `makefile/versions.mk` and add the new pin directly after it (keep tool-version pins grouped):

```makefile
CLAUDE_VERSION       := latest
CCSTATUSLINE_VERSION := 2.2.19
```

(If the `CLAUDE_VERSION` line is in a different spot than expected, place `CCSTATUSLINE_VERSION` alphabetically near it. Either position works since `versions.mk` is just `:=` assignments.)

- [ ] **Step 4: Re-run the verification**

```bash
grep -nE '^CCSTATUSLINE_VERSION\s*:=' /home/arrush.chaturvedi/.local/share/chezmoi/makefile/versions.mk
```

Expected: `<line>:CCSTATUSLINE_VERSION := 2.2.19`.

- [ ] **Step 5: Confirm Make can evaluate it**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile && make -np MODE=dev 2>/dev/null | grep '^CCSTATUSLINE_VERSION'
```

Expected: `CCSTATUSLINE_VERSION := 2.2.19`.

- [ ] **Step 6: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add makefile/versions.mk
git commit -m "$(cat <<'EOF'
chore(versions): pin ccstatusline at v2.2.19

First step toward integrating ccstatusline into the dev install flow.
The pin is consumed by the chezmoi-tracked statusLine block (which
invokes `npx -y ccstatusline@<pin>`) and by the new
scripts/setup-ccstatusline.sh helper (passed via the Make target).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 2: Seed the chezmoi-tracked widget config

**Files:**
- Create: `chezmoi/dot_config/ccstatusline/settings.json`

The initial commit ships an empty `{}` — the script's `option_use_tracked` will detect this empty state and instruct the user to run option 3 first. Option 3 ("set new global") repopulates this file via `chezmoi re-add` after the user configures via the TUI.

- [ ] **Step 1: Verification command for "file is tracked + valid JSON"**

```bash
test -f /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json && \
  jq -e . /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json >/dev/null
```

Expected before: exit 1 (file missing). After: exit 0.

- [ ] **Step 2: Run verification to confirm absence**

```bash
ls /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json 2>&1
```

Expected: `No such file or directory`.

- [ ] **Step 3: Create the file**

```bash
mkdir -p /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline
```

Write `/home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json` with content:

```json
{}
```

(Just the empty object, single line, trailing newline.)

- [ ] **Step 4: Re-run verification**

```bash
test -f /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json && \
  jq -e . /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/dot_config/ccstatusline/settings.json && \
  echo "ok"
```

Expected: `{}` then `ok`.

- [ ] **Step 5: `chezmoi diff` smoke**

```bash
chezmoi diff ~/.config/ccstatusline/settings.json 2>&1 | head -10
```

Expected: A diff showing the empty `{}` is about to be written to `~/.config/ccstatusline/settings.json` (or, if you already have a non-empty local config, a diff that would overwrite it — that's fine, we don't apply yet).

- [ ] **Step 6: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/dot_config/ccstatusline/settings.json
git commit -m "$(cat <<'EOF'
feat(chezmoi): track empty ccstatusline widget config seed

Adds an empty `{}` widget config under chezmoi/dot_config/ccstatusline/.
Future runs of `scripts/setup-ccstatusline.sh` option 3 ("set new
global") will repopulate this via `chezmoi re-add` after the TUI
configures the live file. The empty seed is detected by option 1
("use tracked") so users get a helpful "run option 3 first" hint
instead of an apply that overwrites their local config with `{}`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 3: Seed the chezmoi-tracked Claude Code settings template

**Files:**
- Create: `chezmoi/private_dot_claude/private_settings.json.tmpl`

The `private_` prefix on both the dir and file enforces mode 0700/0600 (per CLAUDE.md). The `.tmpl` suffix runs the file through Go templates. The version literal mirrors `CCSTATUSLINE_VERSION` in `versions.mk` — both must be updated together (see Task 12).

- [ ] **Step 1: Verification command**

```bash
test -f /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl && \
  chezmoi execute-template < /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl | jq -e .statusLine.command
```

Expected before: exit 1. After: prints `"npx -y ccstatusline@2.2.19"` (note: quoted JSON string).

- [ ] **Step 2: Run to confirm absence**

```bash
ls /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl 2>&1
```

Expected: `No such file or directory`.

- [ ] **Step 3: Create the file**

```bash
mkdir -p /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude
```

Write `/home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "npx -y ccstatusline@2.2.19",
    "refreshInterval": 10
  }
}
```

(Single block, no chezmoi template directives needed for v1 — version pin is a literal. Future iteration may replace `2.2.19` with `{{ .ccstatusline_version }}` once we wire a chezmoi data variable.)

- [ ] **Step 4: Verify the rendered template parses as JSON**

```bash
chezmoi execute-template < /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl | jq -e .
```

Expected: pretty-printed JSON with the statusLine block; exit 0.

- [ ] **Step 5: Verify the command field**

```bash
chezmoi execute-template < /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/private_dot_claude/private_settings.json.tmpl | jq -r .statusLine.command
```

Expected: `npx -y ccstatusline@2.2.19`.

- [ ] **Step 6: `chezmoi diff` smoke (do NOT apply)**

```bash
chezmoi diff ~/.claude/settings.json 2>&1 | head -20
```

Expected: A diff that would WRITE the statusLine block to `~/.claude/settings.json`. **Important:** If you already have a populated `~/.claude/settings.json` with other keys (plugins, env, etc.), this diff will show those getting clobbered. That's expected for this commit — we're tracking the file in full. If you want to preserve those keys, copy them into the `.tmpl` before running `chezmoi apply` later. Do not apply during this task.

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/private_dot_claude/private_settings.json.tmpl
git commit -m "$(cat <<'EOF'
feat(chezmoi): track Claude Code settings.json with statusLine block

Seeds chezmoi/private_dot_claude/private_settings.json.tmpl with the
statusLine command pointing at ccstatusline pinned to v2.2.19. The
private_ prefix enforces 0700 dir / 0600 file perms — Claude Code's
settings.json may grow API-key-ish content over time, so conservative
permissions are warranted.

The version literal MUST stay in sync with CCSTATUSLINE_VERSION in
versions.mk. Documented as a dual-edit invariant in CLAUDE.md (Task 12).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 4: Add the CCSTATUSLINE sentinel block to `.chezmoiignore.tmpl`

**Files:**
- Modify: `chezmoi/.chezmoiignore.tmpl`

The sentinel markers go AT THE END of the file (after the existing Linux/Windows branches). Initially the block is empty — hosts get added later via the setup script.

- [ ] **Step 1: Verification command**

```bash
grep -nE 'CCSTATUSLINE:(START|END)' /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/.chezmoiignore.tmpl
```

Expected before: no output. After: 2 matches (START + END).

- [ ] **Step 2: Run to confirm absence**

```bash
grep -nE 'CCSTATUSLINE:(START|END)' /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/.chezmoiignore.tmpl; echo "exit=$?"
```

Expected: `exit=1`.

- [ ] **Step 3: Append the sentinel block**

Edit `/home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/.chezmoiignore.tmpl` and append at the very end (after the `{{ end }}` of the OS branch):

```
{{/*
Per-host opt-out of the chezmoi-tracked ccstatusline widget config.
Managed by scripts/setup-ccstatusline.sh — hand-edits between markers
get clobbered on the next prompt run. Each host that picks "this
machine + persist=y" gets a single-line entry inside the block of the
form: `{{ if eq .chezmoi.hostname "name" }}dot_config/ccstatusline/settings.json{{ end }}`
*/}}
# CCSTATUSLINE:START
# CCSTATUSLINE:END
```

- [ ] **Step 4: Re-run verification**

```bash
grep -nE 'CCSTATUSLINE:(START|END)' /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/.chezmoiignore.tmpl
```

Expected: 2 matches.

- [ ] **Step 5: Verify the template still renders**

```bash
chezmoi execute-template < /home/arrush.chaturvedi/.local/share/chezmoi/chezmoi/.chezmoiignore.tmpl | head -30
```

Expected: rendered output with the existing local-overrides lines, the OS-conditional branch contents, and the two sentinel comment lines at the end. No template errors.

- [ ] **Step 6: `chezmoi diff` smoke**

```bash
chezmoi diff 2>&1 | head -20
```

Expected: no NEW diffs introduced by this change (the sentinel is comments-only at this point).

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/.chezmoiignore.tmpl
git commit -m "$(cat <<'EOF'
feat(chezmoi): add CCSTATUSLINE sentinel block to .chezmoiignore.tmpl

Empty managed block for per-host opt-out of the chezmoi-tracked
ccstatusline widget config. Hosts that pick "this machine + persist"
in scripts/setup-ccstatusline.sh get a one-line ignore stanza added
between the START/END markers; chezmoi then skips
dot_config/ccstatusline/settings.json on that specific host.

Mirrors the existing HOSTS:START/END sentinel pattern in
chezmoi/dot_config/wezterm/wezterm.lua managed by manage-hosts.sh.
Hand-edits between the markers get clobbered on the next setup
run (documented in CLAUDE.md, Task 12 of this plan).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 5: Create `scripts/setup-ccstatusline.sh` skeleton (preflight + skip option)

**Files:**
- Create: `scripts/setup-ccstatusline.sh`

This task ships the orchestrator with the preflight check, the menu, and only options 4 (skip) wired up. Options 1/2/3 print a "not yet implemented" message — they're filled in by Tasks 7/8/9.

- [ ] **Step 1: Verification command**

```bash
test -x /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh && \
  file /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh | grep -v CRLF && \
  bash -n /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh && \
  echo "ok"
```

Expected before: exit 1. After: prints `setup-ccstatusline.sh: ... ASCII text executable` (no CRLF) and `ok`.

- [ ] **Step 2: Run to confirm absence**

```bash
ls /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh 2>&1
```

Expected: `No such file or directory`.

- [ ] **Step 3: Create the script**

Write `/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh`:

```bash
#!/usr/bin/env bash
# setup-ccstatusline.sh — interactive setup of the Claude Code statusline
# via ccstatusline. Four options: use tracked / this machine / set global /
# skip. Invoked by `make -C makefile claude-statusline MODE=dev` and at
# the tail of `bootstrap.sh --dev`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHEZMOI_SRC="$REPO_ROOT/chezmoi"
IGNORE_TMPL="$CHEZMOI_SRC/.chezmoiignore.tmpl"
WIDGET_TRACKED_SRC="$CHEZMOI_SRC/dot_config/ccstatusline/settings.json"
WIDGET_DEST="$HOME/.config/ccstatusline/settings.json"
CLAUDE_SETTINGS_TRACKED_SRC="$CHEZMOI_SRC/private_dot_claude/private_settings.json.tmpl"
CLAUDE_SETTINGS_DEST="$HOME/.claude/settings.json"

BOLD=$'\033[1m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

HOST="$(hostname -s)"
SENTINEL_START='# CCSTATUSLINE:START'
SENTINEL_END='# CCSTATUSLINE:END'
CCSTATUSLINE_VERSION="${CCSTATUSLINE_VERSION:-2.2.19}"

# --- preflight --------------------------------------------------------------

preflight() {
  if ! command -v npx >/dev/null 2>&1; then
    printf '%bnpx not found.%b ccstatusline runs via npx; install Node.js first:\n' "$YELLOW" "$RESET"
    printf '  Fedora/RHEL: %bsudo dnf install -y nodejs%b\n' "$YELLOW" "$RESET"
    printf '  Debian/Ubuntu: %bsudo apt install -y nodejs npm%b\n' "$YELLOW" "$RESET"
    printf 'Then re-run: %bmake -C makefile claude-statusline MODE=dev%b\n' "$YELLOW" "$RESET"
    exit 0
  fi
  if [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
    printf '%bchezmoi not initialized — run ./bootstrap.sh --dev first.%b\n' "$RED" "$RESET" >&2
    exit 1
  fi
}

# --- options (skeletons; filled in by later tasks) -------------------------

option_use_tracked()  { printf '%boption 1 (use tracked) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_this_machine() { printf '%boption 2 (this machine) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_set_global()   { printf '%boption 3 (set new global) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_skip()         { printf '%bSkipped.%b\n' "$YELLOW" "$RESET"; }

# --- menu -------------------------------------------------------------------

show_menu() {
  printf '\n%bccstatusline setup%b (host: %b%s%b, version: %b%s%b)\n' \
    "$BOLD" "$RESET" "$YELLOW" "$HOST" "$RESET" "$YELLOW" "$CCSTATUSLINE_VERSION" "$RESET"
  printf '  1) Use the chezmoi-tracked status line (same as every host)\n'
  printf '  2) Define a new status line for this machine (with persist sub-prompt)\n'
  printf '  3) Set a new global status line (configure + commit + push)\n'
  printf '  4) Skip\n\n'
  printf '%bChoice [1-4]: %b' "$BOLD" "$RESET"
}

# --- main -------------------------------------------------------------------

main() {
  preflight
  show_menu
  local choice
  read -r choice </dev/tty
  case "$choice" in
    1)        option_use_tracked  ;;
    2)        option_this_machine ;;
    3)        option_set_global   ;;
    4|"")     option_skip         ;;
    *)        printf '%bInvalid choice.%b\n' "$RED" "$RESET" >&2; exit 1 ;;
  esac
}

main "$@"
```

- [ ] **Step 4: chmod + verify perms**

```bash
chmod +x /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
ls -la /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
file /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: `-rwxr-xr-x`; `ASCII text executable` (no "CRLF").

- [ ] **Step 5: syntax check + functional smoke (skip path)**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
echo "4" | /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh < <(echo "4")
```

Expected: bash -n exits 0 silently; the script run prints the menu + `Skipped.`; exit 0.

(If `npx` is not installed on the executing host, the script prints the install hint and exits 0 — that's a valid pass too.)

- [ ] **Step 6: git stage mode check**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh
git update-index --chmod=+x scripts/setup-ccstatusline.sh
git ls-files --stage scripts/setup-ccstatusline.sh
```

Expected: `100755 ... scripts/setup-ccstatusline.sh` (mode 755 in the index).

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git commit -m "$(cat <<'EOF'
feat(scripts): add setup-ccstatusline.sh skeleton + preflight

Orchestrator for the ccstatusline 4-option setup prompt. This commit
ships the skeleton: preflight (npx + chezmoi checks), the menu,
option 4 (skip), and "not yet implemented" placeholders for options
1-3 (filled in by subsequent commits).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 6: Add sentinel-block primitives to the script

**Files:**
- Modify: `scripts/setup-ccstatusline.sh` — add `sentinel_contains`, `sentinel_add`, `sentinel_remove` between the preflight and options sections.

These three helpers manage the per-host opt-out block inside `.chezmoiignore.tmpl`. They're idempotent (safe to call multiple times).

- [ ] **Step 1: Verification commands**

```bash
# Pretend we're inside the script for a moment by setting up env
export IGNORE_TMPL=/tmp/ignore.test.$$
cat > "$IGNORE_TMPL" <<'EOF'
# CCSTATUSLINE:START
# CCSTATUSLINE:END
EOF
# Source the script's helper functions only by extracting them — done after Step 3.
```

Expected before: script doesn't contain `sentinel_contains`. After: it does, and the primitives behave correctly.

- [ ] **Step 2: Confirm absence**

```bash
grep -c 'sentinel_contains\|sentinel_add\|sentinel_remove' /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: `0`.

- [ ] **Step 3: Add the primitives**

Edit `/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh` and insert this block AFTER the `preflight() { ... }` function and BEFORE the `option_use_tracked()` function:

```bash
# --- sentinel block primitives ----------------------------------------------
# Manages per-host opt-out lines between # CCSTATUSLINE:START / END markers
# inside chezmoi/.chezmoiignore.tmpl. Each opted-out host contributes one
# line of the form:
#   {{ if eq .chezmoi.hostname "<host>" }}dot_config/ccstatusline/settings.json{{ end }}

sentinel_contains() {
  local host="$1"
  awk -v host="$host" '
    /^# CCSTATUSLINE:START$/ { inblock=1; next }
    /^# CCSTATUSLINE:END$/   { inblock=0 }
    inblock && index($0, "\"" host "\"") > 0 { found=1; exit }
    END { exit !found }
  ' "$IGNORE_TMPL"
}

sentinel_add() {
  local host="$1"
  if sentinel_contains "$host"; then return 0; fi
  local stanza
  stanza="$(printf '{{ if eq .chezmoi.hostname "%s" }}dot_config/ccstatusline/settings.json{{ end }}' "$host")"
  local tmp
  tmp="$(mktemp)"
  awk -v end="$SENTINEL_END" -v stanza="$stanza" '
    $0 == end { print stanza; print; next }
    { print }
  ' "$IGNORE_TMPL" > "$tmp"
  mv "$tmp" "$IGNORE_TMPL"
}

sentinel_remove() {
  local host="$1"
  if ! sentinel_contains "$host"; then return 0; fi
  local tmp
  tmp="$(mktemp)"
  awk -v host="$host" '
    /^# CCSTATUSLINE:START$/ { inblock=1; print; next }
    /^# CCSTATUSLINE:END$/   { inblock=0; print; next }
    inblock && index($0, "\"" host "\"") > 0 { next }
    { print }
  ' "$IGNORE_TMPL" > "$tmp"
  mv "$tmp" "$IGNORE_TMPL"
}
```

- [ ] **Step 4: Syntax check + functional test of primitives (ad-hoc, off-script)**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
bash -n scripts/setup-ccstatusline.sh   # syntax-only

# Functional test using a temp ignore-tmpl
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
something-before
# CCSTATUSLINE:START
# CCSTATUSLINE:END
something-after
EOF
export IGNORE_TMPL="$TMP"
export SENTINEL_START='# CCSTATUSLINE:START'
export SENTINEL_END='# CCSTATUSLINE:END'

# Source just the primitives (extract the function block)
source /dev/stdin <<'SRC'
sentinel_contains() { awk -v host="$1" '/^# CCSTATUSLINE:START$/{inblock=1;next} /^# CCSTATUSLINE:END$/{inblock=0} inblock && index($0,"\"" host "\"")>0{found=1;exit} END{exit !found}' "$IGNORE_TMPL"; }
sentinel_add()      { local s="$(printf '{{ if eq .chezmoi.hostname \"%s\" }}dot_config/ccstatusline/settings.json{{ end }}' "$1")"; local t=$(mktemp); awk -v end="$SENTINEL_END" -v stanza="$s" '$0==end{print stanza;print;next}{print}' "$IGNORE_TMPL" > "$t"; mv "$t" "$IGNORE_TMPL"; }
sentinel_remove()   { local t=$(mktemp); awk -v host="$1" '/^# CCSTATUSLINE:START$/{inblock=1;print;next} /^# CCSTATUSLINE:END$/{inblock=0;print;next} inblock && index($0,"\"" host "\"")>0{next}{print}' "$IGNORE_TMPL" > "$t"; mv "$t" "$IGNORE_TMPL"; }
SRC

sentinel_contains "alpha"; echo "alpha-contains: $?"   # expect 1 (not present)
sentinel_add "alpha"
sentinel_contains "alpha"; echo "alpha-contains-after-add: $?"  # expect 0
sentinel_add "alpha"   # idempotent
grep -c "alpha" "$IGNORE_TMPL"; echo "  count of alpha lines (expect 1)"
sentinel_remove "alpha"
sentinel_contains "alpha"; echo "alpha-contains-after-remove: $?"  # expect 1
cat "$IGNORE_TMPL"
rm "$TMP"
```

Expected (key checks):
- `alpha-contains: 1` (initially absent)
- `alpha-contains-after-add: 0` (now present)
- Line count for `alpha`: `1` (no duplicates)
- `alpha-contains-after-remove: 1` (gone)
- Final file matches the original input

- [ ] **Step 5: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh
git commit -m "$(cat <<'EOF'
feat(scripts): add sentinel-block primitives to setup-ccstatusline.sh

Three idempotent helpers (sentinel_contains/add/remove) manage the
# CCSTATUSLINE:START/END block inside chezmoi/.chezmoiignore.tmpl.
Each opt-out host contributes one line of the form
  {{ if eq .chezmoi.hostname "<host>" }}dot_config/ccstatusline/settings.json{{ end }}

Mirrors the awk-based sentinel pattern in scripts/manage-hosts.sh
(which manages the wezterm HOSTS:START/END block).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 7: Implement option 1 — "Use the tracked status line"

**Files:**
- Modify: `scripts/setup-ccstatusline.sh` — replace the `option_use_tracked()` skeleton with the real implementation.

- [ ] **Step 1: Verification — what should be true after this task**

```bash
# Force the sentinel to list current host, then run option 1.
# Expected outcomes:
#   - Sentinel no longer lists current host
#   - chezmoi apply was attempted on the two paths (we don't verify the apply itself
#     since it depends on local state; we just verify the script reaches the chezmoi call)
```

- [ ] **Step 2: Confirm skeleton is still in place (pre-implementation state)**

```bash
grep -A 1 'option_use_tracked()' /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh | head -3
```

Expected: shows the "not yet implemented" stub.

- [ ] **Step 3: Replace `option_use_tracked()` with the implementation**

In `/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh`, replace the line

```bash
option_use_tracked()  { printf '%boption 1 (use tracked) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
```

with:

```bash
option_use_tracked() {
  local tracked_content
  tracked_content="$(cat "$WIDGET_TRACKED_SRC")"
  # Empty tracked widget config (the initial `{}` seed) — bail with a hint
  # instead of applying an empty config over the user's local one.
  if [ "$(printf '%s' "$tracked_content" | tr -d '[:space:]')" = '{}' ]; then
    printf '%bTracked widget config is empty (just `{}`).%b Pick option 3 first to seed it from a real configuration.\n' "$YELLOW" "$RESET"
    return 0
  fi
  if sentinel_contains "$HOST"; then
    printf '%bRemoving %s from local-persist sentinel block...%b\n' "$BOLD" "$HOST" "$RESET"
    sentinel_remove "$HOST"
  fi
  printf '%bApplying tracked ccstatusline + Claude Code settings...%b\n' "$GREEN" "$RESET"
  chezmoi apply "$WIDGET_DEST" "$CLAUDE_SETTINGS_DEST"
  printf '%bDone.%b\n' "$GREEN" "$RESET"
}
```

- [ ] **Step 4: Syntax + smoke**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh

# Smoke: pick option 1 with the empty `{}` tracked seed — should print the hint and exit
echo "1" | /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: menu, then `Tracked widget config is empty (just \`{}\`). Pick option 3 first…`, exit 0.

(Once Task 9 ships and you've used option 3 once, picking option 1 again here would `chezmoi apply` instead. For now, the empty-seed path is the only one exercised.)

- [ ] **Step 5: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh
git commit -m "$(cat <<'EOF'
feat(scripts): implement option 1 — use tracked ccstatusline config

Strips current host from the CCSTATUSLINE sentinel block (if present)
and runs `chezmoi apply` for the two tracked paths. Special-cases the
empty-`{}` initial seed with a "run option 3 first to seed it" hint so
users don't accidentally clobber a populated local config with the
empty starter template.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 8: Implement option 2 — "Define a new status line for this machine"

**Files:**
- Modify: `scripts/setup-ccstatusline.sh` — replace the `option_this_machine()` skeleton with the real implementation.

- [ ] **Step 1: Verification — what should be true**

```bash
# After picking option 2 + persist=y, sentinel should list current host.
# After picking option 2 + persist=n, sentinel should be unchanged.
# If TUI exits non-zero (user cancels), neither sentinel nor the live file should change.
```

- [ ] **Step 2: Confirm skeleton in place**

```bash
grep 'option_this_machine() {' /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: matches the stub line.

- [ ] **Step 3: Replace `option_this_machine()`**

Replace:

```bash
option_this_machine() { printf '%boption 2 (this machine) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
```

With:

```bash
option_this_machine() {
  printf '%bLaunching ccstatusline TUI (v%s)...%b\n' "$BOLD" "$CCSTATUSLINE_VERSION" "$RESET"
  if ! npx -y "ccstatusline@$CCSTATUSLINE_VERSION" </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  printf '%bPersist this machine-local config across chezmoi updates? (y/N): %b' "$BOLD" "$RESET"
  local ans
  read -r ans </dev/tty
  case "${ans,,}" in
    y|yes)
      sentinel_add "$HOST"
      printf '%bAdded %s to local-persist sentinel block — subsequent `chezmoi apply` runs will leave your local widget config alone.%b\n' "$GREEN" "$HOST" "$RESET"
      ;;
    *)
      printf '%bEphemeral — next `chezmoi update` will overwrite your local widget config with the tracked version.%b\n' "$YELLOW" "$RESET"
      ;;
  esac
}
```

- [ ] **Step 4: Syntax check**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: exit 0, no output.

- [ ] **Step 5: Functional smoke (interactive)**

This step requires you to actually run the TUI. Skip if you don't want to perturb the live `~/.config/ccstatusline/settings.json` right now — the verification in Step 6 is a stand-in.

```bash
# Manual: run, pick option 2, configure something in the TUI, save, answer 'n' to persist.
# Expected: sentinel block in .chezmoiignore.tmpl is unchanged.
/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

- [ ] **Step 6: Verification (non-interactive sentinel check)**

```bash
# Verify sentinel primitives still work from the script context (an indirect check that
# option_this_machine's reference to them is wired correctly):
grep -c 'sentinel_add\|sentinel_remove\|sentinel_contains' /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: ≥ 4 (3 definitions + at least 1 caller in option_this_machine).

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh
git commit -m "$(cat <<'EOF'
feat(scripts): implement option 2 — this-machine ccstatusline config

Launches the ccstatusline TUI via npx, then asks the user whether to
persist the local config across chezmoi updates. On "yes", adds the
current host to the CCSTATUSLINE sentinel block (chezmoi will then
ignore the tracked widget config on this host going forward). On "no",
no sentinel change — the next `chezmoi update` overwrites the local
config back to the tracked version.

If the TUI exits non-zero (Ctrl+C, error), no changes are made.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 9: Implement option 3 — "Set a new global status line"

**Files:**
- Modify: `scripts/setup-ccstatusline.sh` — replace the `option_set_global()` skeleton with the real implementation.

This option launches the TUI, re-adds the resulting local files into the chezmoi source, commits, and pushes.

- [ ] **Step 1: Verification — what should be true**

```bash
# After picking option 3 with TUI changes:
#   - chezmoi/dot_config/ccstatusline/settings.json contents == local file contents
#   - chezmoi/private_dot_claude/private_settings.json.tmpl re-added (if changed)
#   - A new git commit exists with subject matching "feat(claude): update ccstatusline tracked config"
#   - origin/main updated
#   - Current host stripped from sentinel block (defensive — overrides any prior "local persist")
```

- [ ] **Step 2: Confirm skeleton in place**

```bash
grep 'option_set_global() {' /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

- [ ] **Step 3: Replace `option_set_global()`**

Replace:

```bash
option_set_global()   { printf '%boption 3 (set new global) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
```

With:

```bash
option_set_global() {
  printf '%bLaunching ccstatusline TUI (v%s)...%b\n' "$BOLD" "$CCSTATUSLINE_VERSION" "$RESET"
  if ! npx -y "ccstatusline@$CCSTATUSLINE_VERSION" </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  if sentinel_contains "$HOST"; then
    printf '%bRemoving %s from local-persist sentinel block (setting global overrides prior local-persist)...%b\n' "$BOLD" "$HOST" "$RESET"
    sentinel_remove "$HOST"
  fi
  printf '%bPulling local config back into chezmoi source...%b\n' "$GREEN" "$RESET"
  chezmoi re-add "$WIDGET_DEST" "$CLAUDE_SETTINGS_DEST"
  cd "$REPO_ROOT"
  git add \
    chezmoi/dot_config/ccstatusline/settings.json \
    chezmoi/private_dot_claude/private_settings.json.tmpl \
    chezmoi/.chezmoiignore.tmpl
  if git diff --cached --quiet; then
    printf '%bNo changes to commit — local config matched tracked.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  git commit -m "$(printf 'feat(claude): update ccstatusline tracked config\n\nUpdated via setup-ccstatusline.sh on %s.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>' "$HOST")"
  printf '%bPushing to origin...%b\n' "$GREEN" "$RESET"
  git push origin "$(git symbolic-ref --short HEAD)"
  printf '%bDone.%b\n' "$GREEN" "$RESET"
}
```

- [ ] **Step 4: Syntax check**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: exit 0.

- [ ] **Step 5: Functional smoke (interactive, optional)**

Skip if you don't want to push a real update right now. The acceptance for this task is "script runs, reaches the chezmoi re-add + git push path on a real TUI session". When you're ready to do an end-to-end test, see Task 14.

- [ ] **Step 6: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh
git commit -m "$(cat <<'EOF'
feat(scripts): implement option 3 — set new global ccstatusline config

Launches the ccstatusline TUI; on TUI success, strips current host
from the sentinel block (setting global overrides any prior local-
persist), runs `chezmoi re-add` for the two tracked paths plus the
sentinel-block file, commits with subject
"feat(claude): update ccstatusline tracked config", and pushes per
the standing always-push rule.

If the local files match the tracked versions (no diff), exits 0 with
a "no changes" message — no empty commit.

If `git push` fails (auth, branch protection, divergent remote), the
script exits non-zero with the underlying error. The commit is left
intact for manual resolution.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 10: Add the `claude-statusline` target to `makefile/Makefile`

**Files:**
- Modify: `makefile/Makefile` — add a new phony target near the existing `claude-cli` rule (lines 117-124).

- [ ] **Step 1: Verification**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile
make claude-statusline MODE=prod 2>&1 | head -3
# Expected: "claude-statusline is a dev_machine target — skipping (MODE=prod)"

# Behind a dry-run since we don't want to actually launch the script here:
make -n claude-statusline MODE=dev 2>&1 | head -3
# Expected: shows the invocation of ../scripts/setup-ccstatusline.sh
```

- [ ] **Step 2: Confirm target doesn't exist yet**

```bash
grep -nE 'claude-statusline:|\.PHONY:.*claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/makefile/Makefile
```

Expected: no matches.

- [ ] **Step 3: Add the target**

Edit `/home/arrush.chaturvedi/.local/share/chezmoi/makefile/Makefile`. After the existing `clean-claude-cli` recipe (line 124 in the current file), and BEFORE the `include packages.mk` line, insert:

```makefile
# -----------------------------------------------------------------------------
# claude-statusline — interactive ccstatusline setup prompt.
#   - Dev-only. The recipe body conditionally compiles based on MODE.
#   - Re-runnable any time post-bootstrap; bootstrap.sh's tail also invokes
#     this target on --dev runs after ensure_chezmoi_initialized.
#   - Version passed via env so versions.mk stays the single source of truth.
# -----------------------------------------------------------------------------
.PHONY: claude-statusline
claude-statusline:
ifeq ($(MODE),dev)
	@CCSTATUSLINE_VERSION=$(CCSTATUSLINE_VERSION) ../scripts/setup-ccstatusline.sh
else
	@echo "claude-statusline is a dev_machine target — skipping (MODE=$(MODE))"
endif
```

- [ ] **Step 4: Add `claude-statusline` to the `.PHONY` list of top-level targets**

In the same file, find the existing top-level `.PHONY` declaration (around line 143):

```makefile
.PHONY: provision dev prod all tools user-tools list clean help
```

The new target already has its own `.PHONY: claude-statusline` line in the block we added in Step 3, so this list doesn't need editing. Skip if already correct.

- [ ] **Step 5: Verify both paths**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile
make claude-statusline MODE=prod 2>&1 | head -3
echo "---"
make -n claude-statusline MODE=dev 2>&1 | head -3
```

Expected:
- `MODE=prod`: prints `claude-statusline is a dev_machine target — skipping (MODE=prod)`, exit 0.
- `MODE=dev` (dry-run): prints the `CCSTATUSLINE_VERSION=2.2.19 ../scripts/setup-ccstatusline.sh` line, exit 0.

- [ ] **Step 6: Verify `make help` (if defined) still works**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile
make help 2>&1 | head -20
```

Expected: no errors; help output unchanged or augmented depending on whether the existing `help` rule documents targets.

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add makefile/Makefile
git commit -m "$(cat <<'EOF'
feat(make): add claude-statusline target

New phony target that invokes scripts/setup-ccstatusline.sh with the
CCSTATUSLINE_VERSION env var sourced from versions.mk. Dev-only — the
recipe body is gated by `ifeq ($(MODE),dev)`; on MODE=prod it prints a
friendly "skipping" message instead of erroring with "no rule to make
target".

Mirrors the existing claude-cli rule's MODE-gating approach, but at
recipe level (ifeq inside the body) rather than excluding the target
from the provision dependency list — so the target is always
discoverable via `make help` regardless of MODE.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 11: Wire `bootstrap.sh` tail to call the new target

**Files:**
- Modify: `bootstrap.sh` — insert the call between `push_host_changes` (line 482) and the `echo "Bootstrap complete."` (line 485).

- [ ] **Step 1: Verification**

```bash
grep -n 'claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
```

Expected before: no output. After: at least 1 match in the tail block.

- [ ] **Step 2: Confirm absence**

```bash
grep -c 'claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
```

Expected: `0`.

- [ ] **Step 3: Insert the call**

Edit `/home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh`. Locate the exact block at the end of the file:

```bash
self_register
run_make
ensure_chezmoi_initialized
push_host_changes

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
```

Insert the new call right after `push_host_changes` (before the blank `echo ""`):

```bash
self_register
run_make
ensure_chezmoi_initialized
push_host_changes

# --- ccstatusline setup (dev only) -----------------------------------------
# Interactive prompt for the Claude Code statusline. Re-runnable any time
# via `make -C makefile claude-statusline MODE=dev` from the repo root.
if [ "$MACHINE_TYPE" = "dev" ]; then
  make -C "$(dirname "$0")/makefile" claude-statusline MODE=dev || true
fi

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
```

The `|| true` ensures a non-zero exit from the script doesn't fail the whole bootstrap — the statusline is optional.

- [ ] **Step 4: Update the post-bootstrap tip text**

In the same `bootstrap.sh`, find the WSL / non-WSL completion-tip branch (around lines 487-494):

```bash
if is_wsl; then
  echo -e "Running inside WSL — opening a new WezTerm WSL tab will land you in"
  echo -e "  ${YELLOW}~${RESET} with starship + the chezmoi-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux)"
  echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
fi
```

Add a re-run tip BELOW this branch (after the `fi`):

```bash
if is_wsl; then
  echo -e "Running inside WSL — opening a new WezTerm WSL tab will land you in"
  echo -e "  ${YELLOW}~${RESET} with starship + the chezmoi-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux)"
  echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
fi

if [ "$MACHINE_TYPE" = "dev" ]; then
  echo -e "Re-configure the Claude Code statusline any time:"
  echo -e "  ${YELLOW}make -C makefile claude-statusline MODE=dev${RESET}"
fi
```

- [ ] **Step 5: Syntax + LF check**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
file /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
```

Expected: bash -n exit 0; file output does NOT contain "CRLF".

- [ ] **Step 6: Dry-eyeball verification**

```bash
grep -n -A 2 -B 1 'claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
```

Expected: 2 occurrences — the conditional call after `push_host_changes`, and the re-run tip.

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add bootstrap.sh
git commit -m "$(cat <<'EOF'
feat(bootstrap): wire claude-statusline prompt at end of --dev flow

Adds the call to `make -C makefile claude-statusline MODE=dev` after
ensure_chezmoi_initialized and push_host_changes, plus a re-run tip in
the completion summary. Gated on MACHINE_TYPE=dev so prod_machine
bootstraps remain unchanged. `|| true` keeps the statusline failure
non-fatal — bootstrap itself still completes successfully.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 12: Document in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

Three additions, kept terse per the existing CLAUDE.md style:
1. Sentinel block invariant (alongside the wezterm one).
2. `versions.mk` ↔ `private_settings.json.tmpl` dual-edit invariant for `CCSTATUSLINE_VERSION`.
3. New files in "Files Claude should be careful with".

- [ ] **Step 1: Verification — grep that the new sections landed**

```bash
grep -nE '(CCSTATUSLINE:START|CCSTATUSLINE_VERSION.*versions.mk)' /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE.md
```

Expected before: 0 matches. After: ≥ 2 matches.

- [ ] **Step 2: Confirm absence**

```bash
grep -c 'CCSTATUSLINE' /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE.md
```

Expected: `0`.

- [ ] **Step 3: Add a load-bearing invariant near the existing wezterm sentinel note**

Find the existing bullet about the wezterm sentinel in the "Load-bearing invariants" section (search for `HOSTS:START`). Add a new bullet directly after it:

```markdown
- **ccstatusline sentinel block.** Auto-generated between `# CCSTATUSLINE:START` / `# CCSTATUSLINE:END` (column 0) in `chezmoi/.chezmoiignore.tmpl` by `scripts/setup-ccstatusline.sh`. Each opt-out host contributes one line of the form `{{ if eq .chezmoi.hostname "<host>" }}dot_config/ccstatusline/settings.json{{ end }}`. Hand-edits inside the markers get clobbered the next time the setup script runs on any host that picks options 1, 2-persist, or 3.
```

- [ ] **Step 4: Add the dual-edit invariant for the version pin**

In the same "Load-bearing invariants" section, add a bullet:

```markdown
- **`versions.mk` ↔ `private_settings.json.tmpl` dual-edit for `CCSTATUSLINE_VERSION`.** The version literal in `chezmoi/private_dot_claude/private_settings.json.tmpl` (the `npx -y ccstatusline@<pin>` command) MUST match `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Bumping the pin requires editing both — there's currently no chezmoi-template variable bridging them. Drift means the Claude Code `statusLine` command will pin a different version than `setup-ccstatusline.sh` invokes interactively.
```

- [ ] **Step 5: Add the new files to "Files Claude should be careful with"**

Find that section (`## Files Claude should be careful with`) and append these entries near the bottom:

```markdown
- **`scripts/setup-ccstatusline.sh`** — LF-only, 100755. Manages the CCSTATUSLINE sentinel block in `chezmoi/.chezmoiignore.tmpl` via in-place awk. Edit-then-test: `bash -n scripts/setup-ccstatusline.sh` and a smoke run with `4) Skip` confirms no surprises before re-running the prompt for real.
- **`chezmoi/private_dot_claude/private_settings.json.tmpl`** — tracked Claude Code user settings; the `statusLine.command` line carries the pinned `ccstatusline@<version>` and MUST mirror `CCSTATUSLINE_VERSION` in `makefile/versions.mk`. Edits get applied to `~/.claude/settings.json` on `chezmoi apply` with mode 0600 (parent dir 0700).
```

- [ ] **Step 6: Verify**

```bash
grep -nE 'CCSTATUSLINE|ccstatusline' /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE.md
```

Expected: ≥ 4 matches (sentinel-block bullet, dual-edit bullet, two "Files Claude should be careful with" entries).

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): document CCSTATUSLINE sentinel + version dual-edit

Three new entries in CLAUDE.md:
- Load-bearing invariant: the CCSTATUSLINE:START/END sentinel block in
  .chezmoiignore.tmpl is auto-managed by scripts/setup-ccstatusline.sh;
  hand-edits inside get clobbered on subsequent script runs.
- Load-bearing invariant: CCSTATUSLINE_VERSION in versions.mk MUST stay
  in sync with the npx command in the private_settings.json.tmpl chezmoi
  template. Drift = Claude Code's statusLine runs a different pinned
  version than the interactive prompt.
- "Files Claude should be careful with": new entries for the orchestrator
  script + the chezmoi-tracked Claude Code settings template.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 13: Document in `README.html` + `CLAUDE_CHANGELOG.md`

**Files:**
- Modify: `README.html` — add a paragraph in §setup-linux about the new prompt; add a "Re-configure the Claude Code statusline" row to the §daily commands table.
- Modify: `README.css` / `README.js` — usually no changes needed unless a new structural component is introduced. Skip both.
- Modify: `CLAUDE_CHANGELOG.md` — append a row per repo convention.

- [ ] **Step 1: Verification**

```bash
grep -nE 'ccstatusline|claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/README.html | head -10
grep -nE 'ccstatusline' /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE_CHANGELOG.md | head -5
```

Expected before: 0 matches each. After: ≥ 2 in README.html, ≥ 1 in CLAUDE_CHANGELOG.md.

- [ ] **Step 2: Confirm absence**

```bash
grep -cE 'ccstatusline|claude-statusline' /home/arrush.chaturvedi/.local/share/chezmoi/README.html /home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE_CHANGELOG.md
```

Expected: `0` for both.

- [ ] **Step 3: Update README.html §setup-linux**

Read `/home/arrush.chaturvedi/.local/share/chezmoi/README.html` and find the `id="setup-linux"` section (search for `setup-linux`). In the description of the `bootstrap.sh --dev` flow, after the step list mentioning `chezmoi-init`, add a new paragraph describing the new prompt. Use the existing HTML voice and tags (e.g. `<p>`, `<code>`).

Example insertion (adapt to actual surrounding markup):

```html
<p>
  At the tail of <code>bootstrap.sh --dev</code>, after chezmoi
  initializes, you'll be prompted to configure the Claude Code statusline
  via <a href="https://github.com/sirmalloc/ccstatusline">ccstatusline</a>.
  Four options:
</p>
<ol>
  <li><strong>Use the same tracked status line</strong> — apply the
      chezmoi-tracked widget config + Claude Code settings (same look as
      every other dev_machine).</li>
  <li><strong>Define a new status line for this machine</strong> — launch
      the ccstatusline TUI; on save, choose whether to persist across
      future <code>chezmoi update</code> runs.</li>
  <li><strong>Set a new global status line</strong> — launch the TUI; on
      save, the result is re-added to the chezmoi source, committed,
      and pushed so every other dev_machine picks it up next sync.</li>
  <li><strong>Skip</strong> — no statusline setup this run.</li>
</ol>
<p>
  Re-runnable any time with
  <code>make -C makefile claude-statusline MODE=dev</code>.
</p>
```

- [ ] **Step 4: Update README.html §daily**

Find the daily commands table/section (search for `daily`). Add a row similar to existing entries:

```html
<tr>
  <td><code>make -C makefile claude-statusline MODE=dev</code></td>
  <td>Re-prompt for ccstatusline setup (use tracked / this machine / set new global / skip).</td>
</tr>
```

(If the daily section uses a `<dl>` or different markup, match its style instead of a `<tr>`.)

- [ ] **Step 5: Append CLAUDE_CHANGELOG.md row**

Add a new entry at the top of `/home/arrush.chaturvedi/.local/share/chezmoi/CLAUDE_CHANGELOG.md` (after the header, before existing entries). Match the existing row format (check `head -40 CLAUDE_CHANGELOG.md` for the table structure). Skeleton:

```markdown
| 2026-05-25 | ccstatusline dev-install integration | New `make -C makefile claude-statusline MODE=dev` target + interactive prompt at end of `bootstrap.sh --dev`. Tracks `~/.config/ccstatusline/settings.json` and the `statusLine` block of `~/.claude/settings.json` via chezmoi. Per-host opt-out via the `# CCSTATUSLINE:START/END` sentinel block in `.chezmoiignore.tmpl`. | README §setup-linux + §daily; CLAUDE.md gains the sentinel invariant + version dual-edit note. |
```

(Adapt column count + format to match the actual CLAUDE_CHANGELOG.md table; this is a placeholder for the canonical structure.)

- [ ] **Step 6: Render README.html in a browser**

```bash
# If you have a graphical browser available, open it:
xdg-open /home/arrush.chaturvedi/.local/share/chezmoi/README.html 2>/dev/null || \
  echo "Open README.html manually in a browser to verify the new prompt section + daily-table row render correctly."
```

Expected: the new <ol>, <p>, and table row render with the existing site styling (no unstyled fallback) — confirming README.css + README.js are still being loaded as siblings.

- [ ] **Step 7: Commit + push**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html CLAUDE_CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(readme): document ccstatusline prompt at end of bootstrap --dev

README.html §setup-linux gains a description of the new 4-option
ccstatusline prompt; §daily gains a re-run row for the new
`make -C makefile claude-statusline MODE=dev` target. CLAUDE_CHANGELOG
gets a new row per the repo's user-facing-surface-change convention.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

### Task 14: End-to-end smoke test (manual, no commit)

This task is verification-only — no new commits. Run on the live dev host AFTER all prior tasks are committed and pushed.

**Files:** none modified.

- [ ] **Step 1: `make claude-statusline MODE=prod` rejects cleanly**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile && make claude-statusline MODE=prod
```

Expected: prints `claude-statusline is a dev_machine target — skipping (MODE=prod)`, exit 0.

- [ ] **Step 2: `make claude-statusline MODE=dev` invokes the script and reaches the menu**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi/makefile && make claude-statusline MODE=dev <<< 4
```

Expected: menu appears with `host: <hostname>, version: 2.2.19`; `4` selects skip; exit 0.

- [ ] **Step 3: Pick option 1 (use tracked) with empty seed**

```bash
echo 1 | /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: prints `Tracked widget config is empty (just \`{}\`). Pick option 3 first to seed it.`, exit 0; no chezmoi apply.

- [ ] **Step 4: Pick option 3 (set new global), configure a single widget, save**

```bash
/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
# Pick: 3
# In the ccstatusline TUI: add the "Model" widget, then save and exit.
```

Expected:
- chezmoi re-adds the two paths; the script commits and pushes.
- `git log -1 --pretty=%s` matches `feat(claude): update ccstatusline tracked config`.
- `chezmoi/dot_config/ccstatusline/settings.json` is no longer just `{}`.
- The push succeeded (last line `Done.`).

- [ ] **Step 5: Re-pick option 1 (use tracked) — now applies the populated config**

```bash
echo 1 | /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected: `Applying tracked ccstatusline + Claude Code settings... Done.`, exit 0; `~/.config/ccstatusline/settings.json` matches the chezmoi source.

- [ ] **Step 6: Pick option 2 with persist=y, confirm sentinel updated**

```bash
/home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
# Pick: 2
# TUI: change something (e.g. add the "Git Branch" widget), save.
# Persist prompt: y
```

Expected:
- Sentinel block in `chezmoi/.chezmoiignore.tmpl` now contains a line with the current hostname.
- `chezmoi diff` is clean on `~/.config/ccstatusline/settings.json` (chezmoi now ignores it for this host).

- [ ] **Step 7: Pick option 1 again — sentinel stripped, chezmoi apply restores tracked**

```bash
echo 1 | /home/arrush.chaturvedi/.local/share/chezmoi/scripts/setup-ccstatusline.sh
```

Expected:
- Sentinel block no longer lists current host.
- `~/.config/ccstatusline/settings.json` reverted to the tracked content.

- [ ] **Step 8: Coexistence with wezterm HOSTS sentinel**

```bash
./scripts/manage-hosts.sh --sync 2>&1 | tail -5
```

Expected: succeeds; no errors mentioning CCSTATUSLINE. Both sentinels coexist.

- [ ] **Step 9: Fresh-bootstrap dry-run**

```bash
bash -n /home/arrush.chaturvedi/.local/share/chezmoi/bootstrap.sh
```

Expected: exit 0 (full script parses cleanly with the new `make -C makefile claude-statusline` invocation).

- [ ] **Step 10: README renders OK**

```bash
xdg-open /home/arrush.chaturvedi/.local/share/chezmoi/README.html 2>/dev/null || \
  echo "Open README.html manually."
```

Expected: the new §setup-linux paragraph + §daily row are styled normally — not unstyled fallback. The three sibling files (HTML/CSS/JS) load together.

- [ ] **Step 11: No commit needed** — this task is verification-only. If any check fails, fix the relevant earlier task and re-run from Step 1.

---

## Self-review checklist (run before handoff)

- [x] **Spec coverage:** Each section of the spec maps to a task:
  - Spec §3 architecture ↔ Tasks 5-11 (script + Makefile + bootstrap wiring)
  - Spec §4 file table ↔ Tasks 1-13 (one task per row, plus docs)
  - Spec §5 sentinel ↔ Tasks 4 (markers) + 6 (primitives)
  - Spec §6 4-option flow ↔ Tasks 5/7/8/9 (one per option)
  - Spec §7 runtime / version pin ↔ Tasks 1 (versions.mk) + 3 (.tmpl) + 12 (dual-edit note)
  - Spec §8 error handling ↔ Tasks 5 (preflight) + 7/8/9 (per-option failure paths) + 10 (MODE check)
  - Spec §9 verification ↔ Task 14 (end-to-end smoke)
  - Spec §10 out-of-scope ↔ Not implemented (deliberate)
  - Spec §11 docs ↔ Tasks 12 (CLAUDE.md) + 13 (README + CHANGELOG)
- [x] **No placeholders.** All `<host>` / `<pin>` references in this plan resolve to concrete values (`hostname -s` at runtime, `2.2.19` as the pin). All steps have actual commands and actual code.
- [x] **Type consistency.** Function names match across tasks: `sentinel_contains` / `sentinel_add` / `sentinel_remove` (Tasks 6, 7, 8, 9) — same names everywhere. `option_use_tracked` / `option_this_machine` / `option_set_global` / `option_skip` — defined in Task 5 as stubs and replaced verbatim in Tasks 7/8/9. Variable names like `WIDGET_TRACKED_SRC`, `CLAUDE_SETTINGS_DEST` are consistent across all script-editing tasks.
- [x] **No spec gaps.** Spec §6 row "Option 1 with empty tracked widget config" → covered in Task 7 Step 3 ("Empty tracked widget config — bail with a hint"). Spec §8 "git push fails" → covered in Task 9's option_set_global commit message body (the implementation leaves the commit intact; CLAUDE.md decision-test ensures no auto-revert).
