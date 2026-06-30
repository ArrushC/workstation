# Session-lifecycle Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two repo-scoped Claude Code hooks — a SessionStart hook that injects one compact block of runtime facts (chezmoi deploy state, host/scope, WSL+interop, guard-tool readiness) and a SessionEnd hook that toasts when the repo is left dirty or with a pending `chezmoi apply`.

**Architecture:** Two self-contained POSIX-ish bash scripts under `.claude/hooks/`, each copying the existing hooks' `jq → python3 → fail-open` `hookfield()` idiom, always exiting 0, with every external probe `timeout`-bounded and every fact computed by a function that fail-opens independently. They are wired via new `SessionStart`/`SessionEnd` keys in `.claude/settings.json` and proven by new assertion blocks in the existing `test-hooks.sh` harness. Documentation lands in the project `CLAUDE.md`.

**Tech Stack:** bash, `jq` (with a `python3` fallback), `chezmoi`, `git`, the existing `.claude/hooks/test-hooks.sh` harness, `check-invariants.sh` (pre-commit: shellcheck + `shfmt -i 2` + LF/0755).

## Global Constraints

- **LF line endings + git mode 100755** for every `.claude/hooks/*.sh` file. CRLF or mode 100644 breaks fresh clones. Enforced by `check-invariants.sh` (pre-commit + CI).
- **Must pass `shellcheck` at warning+ and `shfmt -i 2`** — the pre-commit hook runs both over all first-party shell files; a commit fails otherwise. Use 2-space indentation.
- **Fail-open always:** malformed stdin, missing `chezmoi`/`git`/tool → drop the segment or silently `exit 0`. Never emit an error, never a non-zero exit.
- **Never spawn a Windows process** to probe interop — static probes only (`/proc/sys/fs/binfmt_misc/WSLInterop`, `command -v powershell.exe`).
- **Every external probe is `timeout`-bounded** (`chezmoi` calls use `timeout 4s`).
- **`additionalContext` carries no `"`, `\`, or control chars** so the no-`jq` `printf` fallback still emits valid JSON.
- **Idiom parity:** copy the `set -u` / `INPUT="$(cat)"` / `hookfield()` preamble verbatim from `.claude/hooks/sync-tool-memory.sh` so all repo hooks read identically.
- **No `README.html` / `CLAUDE_CHANGELOG.md` changes** — `.claude/` is Claude-internal, explicitly exempt from the README-update rule.
- **Branch:** all work on `feat/session-lifecycle-hooks` (already created; the spec commit `cc8f7aa` is its first commit).

---

### Task 1: `session-context.sh` (SessionStart context block)

**Files:**
- Create: `.claude/hooks/session-context.sh`
- Modify: `.claude/settings.json` (add the `SessionStart` key)
- Test: `.claude/hooks/test-hooks.sh` (new `== session-context ==` block)

**Interfaces:**
- Consumes: SessionStart hook JSON on stdin — fields `.cwd` (string) and `.source` (string; unused but documented). Environment: `CLAUDE_PROJECT_DIR` (optional).
- Produces: a single line of JSON on stdout: `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<block>"},"suppressOutput":true}`. The `<block>` always begins with `[workstation]` and contains, when resolvable, the segments `host=… group=… os=…`, `WSL=… interop=… powershell.exe=…`, `chezmoi: …`, and `guards: jq=… shfmt=… gitleaks=… shellcheck=… precommit=…` joined by ` | `. Exits 0 with no output when no repo root resolves.

- [ ] **Step 1: Write the failing tests**

Add this block to `.claude/hooks/test-hooks.sh` immediately **before** the final `echo` / summary block (after the `== sync-tool-memory (R5) ==` block, before line `echo` near the bottom):

```bash
echo "== session-context (R6) =="
run_env() { OUT="$(printf '%s' "$2" | env -u CLAUDE_PROJECT_DIR bash "$1" 2>/dev/null)"; }
run_env "$RH/session-context.sh" "$(j --arg c "$ROOT" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "emits SessionStart event" has '"hookEventName":"SessionStart"'
ok "reports host" has 'host='
ok "reports guard readiness" has 'guards:'
ok "is one JSON object (single line)" bash -c '[ "$(printf "%s" "'"$OUT"'" | grep -c .)" = 1 ]'
run_env "$RH/session-context.sh" 'not json at all'
ok "malformed input -> fail-open silent" empty
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash .claude/hooks/test-hooks.sh`
Expected: the `== session-context (R6) ==` assertions FAIL (e.g. `FAIL emits SessionStart event`) because the script does not exist yet; the suite exits non-zero. Earlier blocks still PASS.

- [ ] **Step 3: Create the script**

Create `.claude/hooks/session-context.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# session-context.sh — Claude Code SessionStart hook (repo-scoped).
#
# Injects ONE compact additionalContext block of RUNTIME facts the static
# session context can't carry, for working in the workstation chezmoi repo:
#   - chezmoi deploy state (does $HOME match the source you're editing?)
#   - host identity & scope (hostname, dev/prod group, distro / EL family)
#   - WSL & interop capability (interop enabled?, powershell.exe reachable?)
#   - guardrail readiness (jq/shfmt/gitleaks/shellcheck + pre-commit hook)
#
# Idiom matches the other repo hooks: jq -> python3 -> fail-open; always exit 0.
# Every bucket fails OPEN independently (drops its segment on any error) and
# every external probe is timeout-bounded. It NEVER spawns a Windows process —
# interop is detected statically. See CLAUDE.md + docs/claude/.
set -u

INPUT="$(cat)"
hookfield() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | HF="$1" python3 -c 'import os,sys,json
p=os.environ["HF"].lstrip(".").split(".")
try:
    v=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in p:
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")' 2>/dev/null
  fi
}

# --- resolve repo root (prefer CLAUDE_PROJECT_DIR, else cwd, else git top) ----
cwd="$(hookfield '.cwd')"
root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  root="$CLAUDE_PROJECT_DIR"
elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
  root="$cwd"
fi
[ -n "$root" ] || exit 0
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$top" ] && root="$top"

# --- bucket: chezmoi deploy state --------------------------------------------
seg_chezmoi() {
  command -v chezmoi >/dev/null 2>&1 || return 0
  local out n
  out="$(timeout 4s chezmoi status 2>/dev/null)" || return 0
  if [ -z "$out" ]; then
    printf 'chezmoi: $HOME in sync'
  else
    n="$(printf '%s\n' "$out" | grep -c .)"
    printf 'chezmoi: %s entries differ from $HOME, edits here are PENDING until `cza`' "$n"
  fi
}

# --- bucket: host identity & scope -------------------------------------------
seg_host() {
  local host group osr id ver plat el osseg
  host="$(uname -n 2>/dev/null)"
  group="$(sed -nE 's/^[[:space:]]*group[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' \
    "$HOME/.config/chezmoi/chezmoi.toml" 2>/dev/null | head -1)"
  osr=/etc/os-release
  id="$(sed -nE 's/^ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  ver="$(sed -nE 's/^VERSION_ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  plat="$(sed -nE 's/^PLATFORM_ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  el="${plat#platform:}"
  osseg=""
  [ -n "$id" ] && osseg="os=$id${ver:+ $ver}"
  [ -n "$osseg" ] && [ -n "$el" ] && [ "$el" != "$plat" ] && osseg="$osseg ($el)"
  printf 'host=%s' "${host:-?}"
  [ -n "$group" ] && printf ' group=%s' "$group"
  [ -n "$osseg" ] && printf ' %s' "$osseg"
}

# --- bucket: WSL & interop (static probes only — no Windows process spawn) ----
seg_wsl() {
  local osrel interop ps
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    osrel="$(cat /proc/sys/kernel/osrelease 2>/dev/null)"
    case "$osrel" in
    *icrosoft* | *WSL*) ;;
    *)
      printf 'WSL=no'
      return 0
      ;;
    esac
  fi
  interop=off
  if [ -r /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null && interop=on
  fi
  if command -v powershell.exe >/dev/null 2>&1; then ps=on-PATH; else ps=absent; fi
  printf 'WSL=%s interop=%s powershell.exe=%s' "${WSL_DISTRO_NAME:-yes}" "$interop" "$ps"
}

# --- bucket: guardrail readiness ---------------------------------------------
seg_guards() {
  local out tool precommit hp
  out="guards:"
  for tool in jq shfmt gitleaks shellcheck; do
    if command -v "$tool" >/dev/null 2>&1; then
      out="$out $tool=ok"
    else
      out="$out $tool=MISSING"
    fi
  done
  precommit=absent
  if [ -x "$root/.git/hooks/pre-commit" ]; then
    precommit=installed
  else
    hp="$(git -C "$root" config --get core.hooksPath 2>/dev/null)"
    [ -n "$hp" ] && [ -x "$hp/pre-commit" ] && precommit=installed
  fi
  printf '%s precommit=%s' "$out" "$precommit"
}

# --- assemble (each segment runs in its own subshell, so any var pollution or
#     failure is contained; empty segments are dropped) ------------------------
segs=()
s="$(seg_chezmoi)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_host)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_wsl)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_guards)" && [ -n "$s" ] && segs+=("$s")
[ "${#segs[@]}" -gt 0 ] || exit 0

block="[workstation]"
sep=" "
for s in "${segs[@]}"; do
  block="${block}${sep}${s}"
  sep=" | "
done

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$block" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"},"suppressOutput":true}\n' "$block"
fi
exit 0
```

- [ ] **Step 4: Make it executable (LF + 0755)**

Run:
```bash
chmod +x .claude/hooks/session-context.sh
file .claude/hooks/session-context.sh
```
Expected: `file` output does NOT contain "CRLF line terminators".

- [ ] **Step 5: Wire it into `.claude/settings.json`**

Edit `.claude/settings.json`. Replace this exact 4-line anchor (the end of the `PostToolUse` array, the `hooks` close, and the `enabledPlugins` opener):

```json
      }
    ]
  },
  "enabledPlugins": {
```

with:

```json
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/session-context.sh\""
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
```

Then verify it is valid JSON:
```bash
jq . .claude/settings.json >/dev/null && echo "settings.json OK"
```
Expected: `settings.json OK`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash .claude/hooks/test-hooks.sh`
Expected: every assertion PASSes including the five new `session-context` ones; suite exits 0 (`✓ all N hook assertions passed`).

- [ ] **Step 7: Sanity-check real output**

Run:
```bash
printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$PWD" \
  | .claude/hooks/session-context.sh | jq -r '.hookSpecificOutput.additionalContext'
```
Expected: one line beginning `[workstation] ` containing `host=`, `group=dev_machine`, `os=almalinux 9.8 (el9)`, `WSL=…`, `chezmoi: …`, and `guards: jq=ok …`.

- [ ] **Step 8: Commit**

```bash
git add .claude/hooks/session-context.sh .claude/settings.json .claude/hooks/test-hooks.sh
git commit -m "$(cat <<'EOF'
feat(hooks): SessionStart context hook for the workstation repo

Injects one compact additionalContext block at session open: chezmoi deploy
state (pending-vs-synced), host identity + dev/prod group + EL family, WSL +
static interop capability, and guard-tool readiness (jq/shfmt/gitleaks/
shellcheck + pre-commit). Fail-open per segment, timeout-bounded, no Windows
process spawn. Wired via SessionStart in .claude/settings.json; covered by
test-hooks.sh.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QgNbWew7eYzm1RJYRZAB98
EOF
)"
```
Expected: the pre-commit invariant check prints `✓ all invariant checks passed` and the commit succeeds.

---

### Task 2: `session-end-notify.sh` (SessionEnd dirty/pending toast)

**Files:**
- Create: `.claude/hooks/session-end-notify.sh`
- Modify: `.claude/settings.json` (add the `SessionEnd` key)
- Test: `.claude/hooks/test-hooks.sh` (new `== session-end-notify ==` block)

**Interfaces:**
- Consumes: SessionEnd hook JSON on stdin — fields `.reason` (string) and `.cwd` (string). Environment: `CLAUDE_PROJECT_DIR` (optional); `WORKSTATION_NOTIFY` (optional override of the notifier command, default `$HOME/.claude/notify.sh`); `HOME`.
- Produces: NO stdout (SessionEnd cannot inject context). Side-effect only: invokes `"$notify" 'Workstation repo' "<msg>"` when the resolved repo is dirty and/or chezmoi-apply is pending and `reason != clear`. `<msg>` = `workstation: N uncommitted change(s)` optionally followed by `; chezmoi apply pending (M)`. Always exits 0.

- [ ] **Step 1: Write the failing tests**

Add this block to `.claude/hooks/test-hooks.sh` immediately after the `== session-context (R6) ==` block from Task 1:

```bash
echo "== session-end-notify (R7) =="
SE="$(mktemp -d)"
mkdir -p "$SE/repo" "$SE/home"
git -C "$SE/repo" init -q
# recording stub for the notifier
cat >"$SE/stub.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SE/notified.log"
STUB
chmod +x "$SE/stub.sh"
se_run() {
  : >"$SE/notified.log"
  printf '%s' "$2" | env -u CLAUDE_PROJECT_DIR HOME="$SE/home" \
    WORKSTATION_NOTIFY="$SE/stub.sh" bash "$1" >/dev/null 2>&1
}
notified() { [ -s "$SE/notified.log" ] && grep -qF "$1" "$SE/notified.log"; }
silent() { [ ! -s "$SE/notified.log" ]; }

# dirty repo (untracked file) -> toast mentions uncommitted
printf 'x\n' >"$SE/repo/dirty.txt"
se_run "$RH/session-end-notify.sh" "$(j --arg c "$SE/repo" '{hook_event_name:"SessionEnd",reason:"logout",cwd:$c}')"
ok "dirty repo -> toast mentions uncommitted" notified 'uncommitted'

# reason=clear on dirty repo -> silent (no nag on /clear)
se_run "$RH/session-end-notify.sh" "$(j --arg c "$SE/repo" '{hook_event_name:"SessionEnd",reason:"clear",cwd:$c}')"
ok "reason=clear -> silent" silent

# clean repo -> silent
rm -f "$SE/repo/dirty.txt"
se_run "$RH/session-end-notify.sh" "$(j --arg c "$SE/repo" '{hook_event_name:"SessionEnd",reason:"logout",cwd:$c}')"
ok "clean repo -> silent" silent

# malformed input -> silent
se_run "$RH/session-end-notify.sh" 'not json at all'
ok "malformed input -> fail-open silent" silent
rm -rf "$SE"
```

> Note: setting `HOME` to a throwaway dir makes `chezmoi status` find no config and return empty, so the SessionEnd tests depend only on the temp git repo's dirtiness — never on the real machine's chezmoi state.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash .claude/hooks/test-hooks.sh`
Expected: the `== session-end-notify (R7) ==` assertions FAIL (the first, `dirty repo -> toast mentions uncommitted`, fails because the script does not exist so nothing is written to the log); suite exits non-zero.

- [ ] **Step 3: Create the script**

Create `.claude/hooks/session-end-notify.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# session-end-notify.sh — Claude Code SessionEnd hook (repo-scoped).
#
# When a session in the workstation repo ends with uncommitted changes and/or a
# pending `chezmoi apply`, fire a desktop toast so the work isn't forgotten.
# Reuses the global notify.sh (WSL toast / notify-send / bell). SessionEnd can't
# inject context, so the only output is the toast side-effect. Fail-open; always
# exit 0. Skips reason=clear (a /clear is not a real departure).
#
# Honors WORKSTATION_NOTIFY (override the notifier) so the hook test can target a
# recording stub. See CLAUDE.md + docs/claude/.
set -u

INPUT="$(cat)"
hookfield() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | HF="$1" python3 -c 'import os,sys,json
p=os.environ["HF"].lstrip(".").split(".")
try:
    v=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in p:
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")' 2>/dev/null
  fi
}

reason="$(hookfield '.reason')"
[ "$reason" = "clear" ] && exit 0

cwd="$(hookfield '.cwd')"
root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  root="$CLAUDE_PROJECT_DIR"
elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
  root="$cwd"
fi
[ -n "$root" ] || exit 0
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$top" ] && root="$top"

# uncommitted changes
nd=0
dirty="$(git -C "$root" status --porcelain 2>/dev/null)"
[ -n "$dirty" ] && nd="$(printf '%s\n' "$dirty" | grep -c .)"

# pending chezmoi apply
np=0
if command -v chezmoi >/dev/null 2>&1; then
  pend="$(timeout 4s chezmoi status 2>/dev/null)" || pend=""
  [ -n "$pend" ] && np="$(printf '%s\n' "$pend" | grep -c .)"
fi

[ "$nd" -eq 0 ] && [ "$np" -eq 0 ] && exit 0

msg="workstation: $nd uncommitted change(s)"
[ "$np" -gt 0 ] && msg="$msg; chezmoi apply pending ($np)"

notify="${WORKSTATION_NOTIFY:-$HOME/.claude/notify.sh}"
[ -x "$notify" ] && "$notify" 'Workstation repo' "$msg" </dev/null >/dev/null 2>&1
exit 0
```

- [ ] **Step 4: Make it executable (LF + 0755)**

Run:
```bash
chmod +x .claude/hooks/session-end-notify.sh
file .claude/hooks/session-end-notify.sh
```
Expected: `file` output does NOT contain "CRLF line terminators".

- [ ] **Step 5: Wire it into `.claude/settings.json`**

Edit `.claude/settings.json`. Replace this exact anchor (the end of the `SessionStart` array added in Task 1, plus the `hooks` close and `enabledPlugins` opener):

```json
      }
    ]
  },
  "enabledPlugins": {
```

with:

```json
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/session-end-notify.sh\""
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
```

Then verify valid JSON:
```bash
jq . .claude/settings.json >/dev/null && echo "settings.json OK"
```
Expected: `settings.json OK`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash .claude/hooks/test-hooks.sh`
Expected: all assertions PASS including the four new `session-end-notify` ones; suite exits 0.

- [ ] **Step 7: Commit**

```bash
git add .claude/hooks/session-end-notify.sh .claude/settings.json .claude/hooks/test-hooks.sh
git commit -m "$(cat <<'EOF'
feat(hooks): SessionEnd dirty/pending toast for the workstation repo

On session end (except /clear), toast via the existing notify.sh when the repo
has uncommitted changes and/or a pending chezmoi apply, so work isn't left
behind. Fail-open; emits no context (SessionEnd can't). WORKSTATION_NOTIFY
override keeps it testable. Wired via SessionEnd; covered by test-hooks.sh.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QgNbWew7eYzm1RJYRZAB98
EOF
)"
```
Expected: the pre-commit invariant check passes and the commit succeeds.

---

### Task 3: Document both hooks in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (the "Claude Code hooks (edit-time enforcement)" section, Repo bullet list)

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: two new bullets describing the hooks; no code depends on this.

- [ ] **Step 1: Add the documentation bullets**

In `CLAUDE.md`, find the Repo-hooks bullet list inside the "## Claude Code hooks (edit-time enforcement)" section. It currently ends with the `sync-tool-memory.sh` bullet:

```markdown
  - `sync-tool-memory.sh` — PostToolUse; on edits to `makefile/versions.mk|tools.mk|packages.mk|Makefile`, regenerates the `TOOLS` block in `chezmoi/private_dot_claude/CLAUDE.md`; nudges to `cza`.
```

Insert these two bullets immediately after it (same indentation — 2 spaces, `- `):

```markdown
  - `session-context.sh` — SessionStart (session-lifecycle, not edit-time); injects one compact `additionalContext` block of runtime facts: chezmoi deploy state (pending vs `$HOME` in sync), host identity + dev/prod group + EL family, WSL + **static** interop capability (probes `binfmt_misc/WSLInterop` + `command -v powershell.exe`, never spawns a Windows process), and guard-tool readiness (jq/shfmt/gitleaks/shellcheck + pre-commit). Each segment fail-opens independently; `chezmoi` probe is `timeout`-bounded.
  - `session-end-notify.sh` — SessionEnd (session-lifecycle); when the repo is left with uncommitted changes and/or a pending `chezmoi apply` (and `reason != clear`), fires a toast via the global `~/.claude/notify.sh`. Emits no context (SessionEnd can't). `WORKSTATION_NOTIFY` overrides the notifier for the hook test.
```

- [ ] **Step 2: Verify the section still reads correctly**

Run:
```bash
rg -n 'session-context|session-end-notify' CLAUDE.md
```
Expected: two matching lines in the hooks section.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): index the SessionStart/SessionEnd hooks in CLAUDE.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QgNbWew7eYzm1RJYRZAB98
EOF
)"
```
Expected: pre-commit check passes; commit succeeds.

---

## Final verification (after all tasks)

- [ ] **Run the full hook suite:** `bash .claude/hooks/test-hooks.sh` → `✓ all N hook assertions passed`, exit 0.
- [ ] **Run the invariant linter explicitly:** `make -C makefile lint MODE=prod` → `✓ all invariant checks passed` (shellcheck + `shfmt -i 2` over the two new scripts; LF + 100755 confirmed).
- [ ] **Confirm git modes:** `git ls-files --stage .claude/hooks/session-context.sh .claude/hooks/session-end-notify.sh` → both show `100755`.
- [ ] **Live smoke test (optional):** open a fresh Claude Code session in this repo and confirm the `[workstation] …` context line appears at start.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-29-session-context-hooks-design.md`):
- chezmoi deploy state → Task 1 `seg_chezmoi`. ✓
- host identity & scope → Task 1 `seg_host` (hostname, group via toml-grep, distro+EL family). ✓ *(Implementation note: the spec listed `chezmoi data` as nominal primary with toml-grep as fallback; the plan uses toml-grep directly — spawn-free, dependency-free, same value, consistent with the spec's intent and stated fallback.)*
- WSL & interop, static-only → Task 1 `seg_wsl`. ✓
- guardrail readiness → Task 1 `seg_guards`. ✓
- one consolidated `additionalContext`, JSON-fallback-safe → Task 1 assembly + emit (no `"`/`\`, comma instead of em-dash). ✓
- SessionEnd dirty/pending toast, skip `clear`, reuse notify.sh, `WORKSTATION_NOTIFY` testability → Task 2. ✓
- settings wiring (matcher-less SessionStart/SessionEnd) → Tasks 1 & 2 Step 5. ✓
- test coverage (SessionStart valid + malformed; SessionEnd dirty/clear/clean/malformed) → Tasks 1 & 2 test blocks. ✓
- CLAUDE.md docs, no README/CHANGELOG → Task 3. ✓
- fail-open / timeout / LF+0755 / shellcheck+shfmt → Global Constraints + per-task Steps. ✓

**Placeholder scan:** No TBD/TODO; all code blocks are complete and runnable; every command has an expected result. The single open item from the spec (exact SessionEnd `reason` strings) is handled default-safe in code — only the literal `clear` is suppressed; any other/unknown reason proceeds.

**Type/name consistency:** `seg_chezmoi`/`seg_host`/`seg_wsl`/`seg_guards`, `$root`, `$block`, `WORKSTATION_NOTIFY`, the `run_env`/`se_run`/`notified`/`silent` test helpers, and the `hookEventName:"SessionStart"` literal are used consistently across tasks. The `.claude/settings.json` anchors in Task 2 correctly assume Task 1's `SessionStart` block is already present (the second anchor matches the SessionStart array's close, not PostToolUse's).
