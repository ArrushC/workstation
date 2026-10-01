# Simplify PR 5: checks and hooks tidy — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One shared JSON helper for the repo's Claude Code hooks; hooks that name only what still exists; and one table-driven pin check, with no network call on commit. `mise run lint` runs the hook tests.

**Architecture:** `.claude/hooks/lib.sh` is sourced by the six repo hooks. It reads hook input (jq → python3 → fail open) and writes hook JSON that stays valid without jq. The two global hooks under `dotfiles/claude/hooks/` keep their inline copies, because they deploy to `~/.claude/hooks` alone.

In `scripts/check-invariants.sh`, five pin and coupling functions become one `check_pins`, built from a few row helpers; the gopls check and its network call go. A new `--only <check>` flag lets a test run one check against a temp copy of the files. A new `check_self_tests` runs `.claude/hooks/test-hooks.sh` and `scripts/test-check-pins.sh` on every lint.

**Tech Stack:** bash 5 (EL9 and CI ubuntu), jq, python3, shellcheck, `shfmt -i 2`, mise 2026.9.9.

**Spec:** `docs/superpowers/specs/2026-09-29-simplify-design.md` §PR 5. Read it with this plan.

## Global Constraints

- LF + git mode 100755: every `.claude/hooks/*.sh` (including the new `lib.sh`), every `scripts/*.sh` (including the new `test-check-pins.sh`), and `dotfiles/claude/hooks/*.sh`. Repair with `sed -i 's/\r$//' <f>` and `git update-index --chmod=+x <f>`.
- First-party shell is `shfmt -i 2`-clean, shellcheck-clean at warning and above, and gitleaks-clean (all three run inside `mise run lint`). Quote bash associative-array keys.
- Hooks always exit 0 and fail open. A missing tool, unparsable input or missing `lib.sh` means no output and exit 0, never a block or an error.
- The global hooks (`dotfiles/claude/hooks/secret-guard.sh`, `dangerous-command-guard.sh`) do not source `lib.sh`; they keep their inline helpers.
- Agents never run `mise dot apply`, `wsa` or `mise bootstrap` against the real `$HOME`. The global-hook change reaches `~/.claude/hooks` only when the user runs `wsa`.
- Size budgets: `CLAUDE.md` ≤ 14,000 bytes (it is 13,991 at the start: every addition needs a cut). `CLAUDE.md` + `docs/claude/*` ≤ 30,000 bytes. `README.md` ≤ 600 lines. `scripts/check-invariants.sh` ≤ 1,100 lines at the end of Task 4 (1,279 at the start).
- `README.md` changes only if a user-facing behaviour changes. These hooks and checks are Claude- and CI-internal, so README is expected untouched; check with `rg -n 'test-hooks|check-invariants|gopls' README.md`.
- Every commit ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```
  The pre-commit hook runs `mise run lint`. Never use `--no-verify`. Push after every commit (`git push`, branch `refactor/simplify-checks`).
- These hooks are live in this checkout as soon as a file changes (`.claude/settings.json` points at them). Run `bash .claude/hooks/test-hooks.sh` after every hook edit, before moving on.

## Review Focus

1. **Escaping without jq.** A message or reason containing `"`, `\`, a newline or a tab must still be valid JSON on the no-jq path (Claude Code drops invalid hook output). → Task 1, the "context JSON valid" cases.
2. **Missing `lib.sh`.** A hook copied without `lib.sh`, or a checkout from before this PR, exits 0 with no output; it never blocks an edit. → Task 1, the "lib.sh missing" case.
3. **Windows paths.** A `tool_input.file_path` with backslashes (`C:\Users\u\.config\mise\dotfiles\zshrc.tera`) still triggers the parity reminder. → Task 2, the "backslash path" case.
4. **Empty pin values.** A pin pattern that stops matching gives an empty value, which is drift, never a pass. If python/tomllib is missing, the TOML rows skip with a note and the other rows still run. → Task 3, the "pattern stops matching" and `CHECK_INVARIANTS_NO_PY` cases.
5. **Self-tests under pre-commit.** git exports `GIT_INDEX_FILE` (and sometimes `GIT_DIR`/`GIT_WORK_TREE`) to hooks. The self-tests make temp git repos, so they must run with those unset, or they read or write the real index. → Task 4, the "under a pre-commit-like env" case.

---

### Task 1: `.claude/hooks/lib.sh`, sourced by the six repo hooks

**Files:**
- Create: `.claude/hooks/lib.sh` (100755, LF)
- Modify: `.claude/hooks/{memory-routing-guard,post-edit-guard,parity-reminder,sync-tool-memory,session-context,session-end-notify}.sh`. Delete each inline `INPUT="$(cat)"` + `hookfield()` and each `jq -nc … else printf …` emit block, and source the lib.
- Test: `.claude/hooks/test-hooks.sh`

**Interfaces:**
- Produces, for Tasks 2 and 4:
  - `HOOK_INPUT`: the hook's stdin, read once when `lib.sh` is sourced.
  - `hook_field <.dotted.path>`: prints the string at that path, else nothing. Non-strings and malformed input give nothing.
  - `hook_context <EventName> <message>`: prints `{"hookSpecificOutput":{"hookEventName":…,"additionalContext":…},"suppressOutput":true}`.
  - `hook_deny <reason>`: prints the PreToolUse deny object.
  - Test-only env seams: `HOOK_LIB_NO_JQ=1` and `HOOK_LIB_NO_PY=1` force the fallbacks.

- [ ] **Step 1: Write the failing tests.** In `.claude/hooks/test-hooks.sh`, make `run` record the exit code, and add a section before `== memory-routing-guard ==`:

```bash
run() {
  OUT="$(printf '%s' "$2" | bash "$1" 2>/dev/null)"
  RC=$?
}
rc0() { [ "$RC" -eq 0 ]; }
```

```bash
echo "== lib.sh (R0) =="
L="$RH/lib.sh"
# lib <input-json> <snippet> [VAR=value...] — run <snippet> with lib.sh sourced
lib() {
  local input="$1" snippet="$2"
  shift 2
  OUT="$(printf '%s' "$input" | env "$@" bash -c '. "$1" && eval "$2"' _ "$L" "$snippet" 2>/dev/null)"
}
ctx_is() { # the additionalContext of $OUT decodes to exactly $1
  printf '%s' "$OUT" | EXPECT="$1" python3 -c 'import json,os,sys
d=json.load(sys.stdin)
sys.exit(d["hookSpecificOutput"]["additionalContext"]!=os.environ["EXPECT"])' 2>/dev/null
}
deny_is() {
  printf '%s' "$OUT" | EXPECT="$1" python3 -c 'import json,os,sys
d=json.load(sys.stdin)["hookSpecificOutput"]
sys.exit(not (d["permissionDecision"]=="deny" and d["permissionDecisionReason"]==os.environ["EXPECT"]))' 2>/dev/null
}
IN="$(j '{tool_input:{file_path:"/a b/c.sh",n:3}}')"
MSG=$'say "hi" \\ back\nnext\ttab'
for mode in "" HOOK_LIB_NO_JQ=1; do
  via="${mode:-jq}"
  lib "$IN" 'hook_field .tool_input.file_path' ${mode:+"$mode"}
  ok "field via $via" [ "$OUT" = "/a b/c.sh" ]
  lib "$IN" 'hook_field .tool_input.n' ${mode:+"$mode"}
  ok "non-string -> empty via $via" empty
  lib 'not json' 'hook_field .tool_input.file_path' ${mode:+"$mode"}
  ok "malformed -> empty via $via" empty
  lib "$IN" 'hook_context PostToolUse "$MSG"' MSG="$MSG" ${mode:+"$mode"}
  ok "context JSON valid and exact via $via" ctx_is "$MSG"
  lib "$IN" 'hook_deny "$MSG"' MSG="$MSG" ${mode:+"$mode"}
  ok "deny JSON valid and exact via $via" deny_is "$MSG"
done
lib "$IN" 'hook_field .tool_input.file_path' HOOK_LIB_NO_JQ=1 HOOK_LIB_NO_PY=1
ok "no jq, no python3 -> empty (fail open)" empty
T="$(mktemp -d)"
cp "$RH/parity-reminder.sh" "$T/"
run "$T/parity-reminder.sh" "$(j --arg f "$ROOT/dotfiles/zshrc.tera" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "lib.sh missing -> silent" empty
ok "lib.sh missing -> exit 0" rc0
rm -rf "$T"
ok "no repo hook keeps an inline hookfield()" bash -c '! grep -l "^hookfield()" "$1"/*.sh' _ "$RH"
```

- [ ] **Step 2: Run them and watch them fail.**

Run: `bash .claude/hooks/test-hooks.sh`

Expected FAILs:
- the `lib.sh` cases (there is no `lib.sh` yet)
- "lib.sh missing -> silent" (today's copied hook is self-contained and still prints its reminder)
- "no repo hook keeps an inline hookfield()"

- [ ] **Step 3: Create `.claude/hooks/lib.sh`.**

```bash
#!/usr/bin/env bash
# lib.sh — sourced by the repo's Claude Code hooks (.claude/hooks/*.sh); not a hook itself.
# Reads the hook input with jq, else python3, else not at all (callers then fail
# open), and writes hook JSON that stays valid on the no-jq path. The global
# hooks in dotfiles/claude/hooks/ keep their own copies: they deploy alone.
# HOOK_LIB_NO_JQ=1 / HOOK_LIB_NO_PY=1 force the fallbacks (test-hooks.sh).

HOOK_INPUT="$(cat)"

_hook_jq() { [ -z "${HOOK_LIB_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; }
_hook_py() { [ -z "${HOOK_LIB_NO_PY:-}" ] && command -v python3 >/dev/null 2>&1; }

# hook_field <.dotted.path> — the string at that path, else nothing.
hook_field() {
  if _hook_jq; then
    printf '%s' "$HOOK_INPUT" | jq -r "($1 // empty) | strings" 2>/dev/null
  elif _hook_py; then
    printf '%s' "$HOOK_INPUT" | HF="$1" python3 -c 'import os,sys,json
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

# _hook_str <s> — <s> as a JSON string literal, for the no-jq path.
_hook_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# hook_context <EventName> <message> — additionalContext for the model.
hook_context() {
  if _hook_jq; then
    jq -nc --arg e "$1" --arg c "$2" \
      '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c},suppressOutput:true}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s},"suppressOutput":true}\n' \
      "$(_hook_str "$1")" "$(_hook_str "$2")"
  fi
}

# hook_deny <reason> — PreToolUse deny.
hook_deny() {
  if _hook_jq; then
    jq -nc --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(_hook_str "$1")"
  fi
}
```

Run `git add .claude/hooks/lib.sh && git update-index --chmod=+x .claude/hooks/lib.sh`.

- [ ] **Step 4: Point each of the six hooks at the lib.** In each hook, replace the `INPUT="$(cat)"` line and the whole `hookfield() { … }` function with:

```bash
# shellcheck source=.claude/hooks/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0
```

Then:
- rename every `hookfield '` call to `hook_field '`
- replace every `if command -v jq …; then jq -nc --arg c "$msg" '{…PostToolUse…}'; else printf …; fi` block with `hook_context PostToolUse "$msg"` (SessionStart in `session-context.sh`: `hook_context SessionStart "$block"`)
- replace the deny block in `memory-routing-guard.sh` with `hook_deny "$reason"`

Leave alone the `mise dot status --json` parsing in `session-context.sh` and `session-end-notify.sh` (jq/python3 over a different JSON). If shellcheck can't follow `source=.claude/hooks/lib.sh` from the repo root, use `# shellcheck source=/dev/null`, as `scripts/lib/test-verify-binary.sh:7` does.

Also delete the comment in `session-context.sh` above the emit that says the no-jq fallback "relies on $block carrying no \" or \\"; the lib escapes now. Delete header-comment lines that describe the removed inline helper ("Idiom matches the other repo hooks: jq -> python3 -> fail-open") and replace them with "Reads input via lib.sh; fails open."

- [ ] **Step 5: Run the tests and lint.**

Run: `bash .claude/hooks/test-hooks.sh`. Expected: every case passes; the last line reads `✓ all N hook assertions passed`.

Run: `mise run lint`. Expected: `✓ all invariant checks passed` (shellcheck, shfmt and LF/100755 now cover `lib.sh`).

- [ ] **Step 6: Commit and push.**

```bash
git add .claude/hooks/
git commit -m "refactor(hooks): one lib.sh for the repo hooks' JSON in/out (jq → python3 → fail open; escaped without jq)" -m "<trailers>"
git push
```

---

### Task 2: Hooks name only what exists

**Files:**
- Modify: `.claude/hooks/parity-reminder.sh`, `.claude/hooks/sync-tool-memory.sh`, `.claude/hooks/session-context.sh`, `dotfiles/claude/hooks/secret-guard.sh`
- Modify: `docs/claude/verification.md` (the Locks line gains the regeneration recipe that sync-tool-memory points to)
- Test: `.claude/hooks/test-hooks.sh`

**Interfaces:**
- Consumes: `hook_field` and `hook_context` from Task 1.
- Produces: `session-context.sh`'s host segment becomes `host=<h> mode=<owned|shared> env=<tokens>[ MISE_ENV=<v> (exported; overrides miserc)][ miserc=missing] os=…`.

- [ ] **Step 1: Write the failing tests.** In `test-hooks.sh`:

1. In `== parity-reminder ==`, replace the `config.toml` and `config.owned.toml` cases with:

```bash
run "$RH/parity-reminder.sh" "$(j --arg f "$ROOT/config.toml" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "config.toml -> silent (sync-tool-memory covers config edits)" empty
run "$RH/parity-reminder.sh" "$(j --arg f "$ROOT/config.owned.toml" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "config.owned.toml -> silent" empty
run "$RH/parity-reminder.sh" "$(j --arg f 'C:\Users\u\.config\mise\dotfiles\zshrc.tera' '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "backslash path -> bashrc reminder" has 'bashrc'
run "$RH/parity-reminder.sh" "$(j --arg f "$ROOT/dotfiles/windows/AppData/Roaming/nushell/config.nu.tera" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "nushell config -> PowerShell profile reminder" has 'PowerShell'
run "$RH/parity-reminder.sh" "$(j --arg f "$ROOT/dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "PowerShell profile -> nushell reminder" has 'nushell'
```

2. In `== sync-tool-memory ==`, after "config.toml -> commit nudge", add:

```bash
ok "nudge says wsa deploys it" has 'wsa'
ok "nudge no longer claims a symlink" lacks 'symlink'
ok "nudge points at the lock recipe" has 'verification.md'
```

3. In `== session-context ==`, set `run_env() { OUT="$(printf '%s' "$2" | env -u CLAUDE_PROJECT_DIR -u MISE_ENV "${@:3}" bash "$1" 2>/dev/null)"; }`, then add:

```bash
SC="$(mktemp -d)"
printf 'env = ["linux", "owned", "host", "wsl"]\nauto_env = false\n' >"$SC/miserc.toml"
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "owned miserc -> mode=owned" has 'mode=owned'
ok "reports the miserc tokens" has 'env=linux,owned,host,wsl'
ok "no exported MISE_ENV -> no warning" lacks 'overrides miserc'
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')" MISE_ENV=linux
ok "exported MISE_ENV -> warned" has 'MISE_ENV=linux (exported; overrides miserc)'
printf 'env = ["linux"]\n' >"$SC/miserc.toml"
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "linux-only miserc -> mode=shared" has 'mode=shared'
rm -f "$SC/miserc.toml"
run_env "$RH/session-context.sh" "$(j --arg c "$SC" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
ok "no miserc -> miserc=missing" has 'miserc=missing'
rm -rf "$SC"
```

4. In `== secret-guard ==`, replace the two `chezmoi/key.txt` cases with:

```bash
run "$GH/secret-guard.sh" "$(j --arg f "/home/u/.config/chezmoi/key.txt" '{tool_name:"Write",tool_input:{file_path:$f}}')"
ok "chezmoi key.txt is no longer special" empty
run "$GH/secret-guard.sh" "$(j --arg c "cat ~/.ssh/id_ed25519" '{tool_name:"Bash",tool_input:{command:$c}}')"
ok "ask bash naming an SSH private key" has '"permissionDecision":"ask"'
run "$GH/secret-guard.sh" "$(j --arg c "cat notes/key.txt" '{tool_name:"Bash",tool_input:{command:$c}}')"
ok "bash naming key.txt -> silent" empty
```

- [ ] **Step 2: Run them and watch them fail.** Run `bash .claude/hooks/test-hooks.sh`. Expected FAILs:
  - config.toml/config.owned.toml silent
  - wsa / symlink / verification.md
  - env=, the MISE_ENV warning, miserc=missing
  - the two key.txt cases

- [ ] **Step 3: `parity-reminder.sh`.** Keep the four pair cases (zshrc, bashrc, the nushell config and the PowerShell profile). Delete the `*/dotfiles/*) ;;` guard comment block, the `*/config.toml)` case and the `*/config.linux.toml | */config.owned.toml)` case. Rewrite the header comment so it names the two pairs and says it never blocks. End with `[ -n "$msg" ] || exit 0` and `hook_context PostToolUse "$msg"`, then `exit 0`.

- [ ] **Step 4: `sync-tool-memory.sh`.** Replace `msg=` with:

```bash
msg="Regenerated the TOOLS block in dotfiles/claude/CLAUDE.md from your config*.toml edit; commit it with this change (\`wsa\` deploys it to ~/.claude/CLAUDE.md). A changed [tools] pin needs its lock entries regenerated (never hand-edit; recipe: docs/claude/verification.md, Locks), and a min_version change must match MISE_VERSION in bootstrap.sh and \$MiseVersion in bootstrap.ps1. \`mise run lint\` checks both."
```

- [ ] **Step 5: `docs/claude/verification.md`.** Replace the `- Locks:` bullet with:

```markdown
- Locks: never hand-edit. Regenerate from outside the checkout for the changed tools, then fold any
  `.mise/locks/` into `locks/` as `normalize_lock_sidecars` in `scripts/bump-versions.sh` does:
  `L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"`, then
  `(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=linux,owned,host,native mise lock --global --platform linux-x64 <tools>)`
  and the same with `MISE_ENV=windows,owned … --platform windows-x64` for tools that install on Windows.
  `check-invariants.sh` verifies coverage.
```

- [ ] **Step 6: `session-context.sh`.** In `seg_host`, keep the token read, and add the tokens, the exported-MISE_ENV warning and the missing-miserc marker:

```bash
  mode="" envseg=""
  if [ -r "$root/miserc.toml" ]; then
    tokens="$(sed -n 's/^env = \[\(.*\)\]$/\1/p' "$root/miserc.toml" 2>/dev/null | tr -d '" ')"
    if [ -n "$tokens" ]; then
      case ",${tokens}," in
      *,owned,*) mode="owned" ;;
      *) mode="shared" ;;
      esac
      envseg="env=$tokens"
    fi
  else
    envseg="miserc=missing"
  fi
  # An exported MISE_ENV overrides miserc for every mise call in this session.
  [ -n "${MISE_ENV:-}" ] && envseg="$envseg MISE_ENV=$MISE_ENV (exported; overrides miserc)"
```

Print `envseg` after `mode`: `[ -n "$envseg" ] && printf ' %s' "${envseg# }"`. Declare `tokens` with the other locals. Update the header bullet to "host identity & scope (hostname, owned/shared mode and miserc tokens, an exported MISE_ENV, distro / EL family)".

- [ ] **Step 7: `secret-guard.sh`** (global, so its inline helpers stay):
  - Delete the `*/chezmoi/key.txt) return 0 ;;` line.
  - Change the Bash regex to `'\bid_(rsa|ed25519|ecdsa|dsa)\b'`.
  - Reword the deny text to "it looks like a private key or a cert", and the ask text to "references what looks like an SSH private key".
  - Delete the header comment's age-identity lines; the header now says "DENY editing OR reading SSH private keys, *.pem and *.key; ASK before a Bash command that names an SSH private key".

- [ ] **Step 8: Run the tests and lint.** Run `bash .claude/hooks/test-hooks.sh` (all pass), then `mise run lint` (all pass).

- [ ] **Step 9: Commit and push.**

```bash
git add .claude/hooks/ dotfiles/claude/hooks/secret-guard.sh docs/claude/verification.md
git commit -m "fix(hooks): parity-reminder names only the two pairs; sync-tool-memory's nudge is accurate; session-context shows miserc tokens and an exported MISE_ENV; secret-guard drops the chezmoi key.txt" -m "<trailers>"
git push
```

---

### Task 3: One table-driven `check_pins`, no network on commit

**Files:**
- Modify: `scripts/check-invariants.sh`:
  - add a `--only` flag and a `CHECK_INVARIANTS_NO_PY` seam
  - add the row helpers and `check_pins`
  - delete `check_version_pins`, `check_bumper_exclude`, `check_vars_pin_coverage`, `check_zjstatus_zellij_coupling`, `check_tsls_typescript_coupling` and `check_go_gopls_coupling`, and their calls
- Create: `scripts/test-check-pins.sh` (100755, LF)
- Modify: `scripts/bump-versions.sh` comments only. Lines ~68 and ~86 name `check_tsls_typescript_coupling` / `check_bumper_exclude`; rename both to `check_pins`.

**Interfaces:**
- Consumes: `tomlval`, `PY`, `ok`, `bad`, `note`, `hdr` (already in check-invariants.sh).
- Produces, for Task 4:
  - `scripts/check-invariants.sh --only <check_name>...` runs only those checks: exit 0 if they pass, 1 if one fails, 2 on an unknown name.
  - `check_pins`.
  - `scripts/test-check-pins.sh`: exit 0 iff every case passes; its last line is `✓ all N check_pins cases passed`.

- [ ] **Step 1: Write the failing test** `scripts/test-check-pins.sh`:

```bash
#!/usr/bin/env bash
# test-check-pins.sh — check_pins passes on this repo's files and fails on each kind of drift.
# Each case runs `check-invariants.sh --only check_pins` against a temp copy of the files it reads.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(bootstrap.sh bootstrap.ps1 config.toml config.linux.toml config.owned.toml
  dotfiles/zshrc.tera dotfiles/bashrc.tera tasks/vcpkg tasks/check-updates
  scripts/bump-versions.sh scripts/gen-tool-memory.sh scripts/check-invariants.sh)
pass=0
fail=0

fresh() {
  [ -n "${T:-}" ] && rm -rf "$T"
  T="$(mktemp -d)"
  local f
  for f in "${files[@]}"; do
    mkdir -p "$T/$(dirname "$f")"
    cp -p "$ROOT/$f" "$T/$f"
  done
}
pins() { OUT="$(env "$@" bash "$T/scripts/check-invariants.sh" --only check_pins 2>&1)"; RC=$?; }
case_() { # case_ <name> <want-rc> [grep-pattern]
  local name="$1" want="$2" pat="${3:-}"
  if [ "$RC" -eq "$want" ] && { [ -z "$pat" ] || printf '%s' "$OUT" | grep -qF -- "$pat"; }; then
    printf '  \033[0;32mPASS\033[0m %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s (rc=%s)\n%s\n' "$name" "$RC" "$OUT" | sed '2,$s/^/      /'
    fail=$((fail + 1))
  fi
}

fresh
pins
case_ "unchanged repo passes" 0 "mise @"
case_ "unchanged repo: VCPKG_ROOT row" 0 "VCPKG_ROOT @"

fresh
sed -i -E 's/^(MISE_VERSION=")[0-9.]+/\10.0.1/' "$T/bootstrap.sh"
pins
case_ "bootstrap.sh MISE_VERSION drift fails" 1 "mise drift"

fresh
sed -i -E 's/^\$MiseVersion( *=)/$MiseVer\1/' "$T/bootstrap.ps1"
pins
case_ "pattern stops matching (empty value) fails" 1 "mise drift"

fresh
sed -i -E 's#(VCPKG_ROOT=")[^"]*#\1/opt/vcpkg#' "$T/dotfiles/bashrc.tera"
pins
case_ "bashrc VCPKG_ROOT drift fails" 1 "VCPKG_ROOT drift"

fresh
sed -i -E 's/^zellij = "[0-9.]+"/zellij = "0.1.0"/' "$T/config.linux.toml"
pins
case_ "zellij below the zjstatus floor fails" 1 "zellij for zjstatus"

fresh
sed -i -E 's/typescript@[0-9.]+/typescript@7.0.0/' "$T/config.owned.toml"
pins
case_ "typescript major 7 fails" 1 "typescript"

fresh
sed -i -E 's/^(COUPLED_AUTO=".*) node"/\1"/' "$T/scripts/bump-versions.sh"
pins
case_ "node missing from COUPLED_AUTO fails" 1 "node"

fresh
sed -i '/^\[vars\]/a foo_version = "1.0"' "$T/config.toml"
pins
case_ "uncovered [vars] *_version pin fails" 1 "foo_version"

fresh
sed -i -E 's#(VCPKG_ROOT=")[^"]*#\1/opt/vcpkg#' "$T/dotfiles/bashrc.tera"
pins CHECK_INVARIANTS_NO_PY=1
case_ "no python: non-TOML rows still fail on drift" 1 "VCPKG_ROOT drift"

fresh
pins CHECK_INVARIANTS_NO_PY=1
case_ "no python: clean repo passes with a skip note" 0 "skipped"

fresh
OUT="$(bash "$T/scripts/check-invariants.sh" --only check_nope 2>&1)"
RC=$?
case_ "--only with an unknown check exits 2" 2 "unknown check"

rm -rf "$T"
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d check_pins cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d check_pins cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
```

The "uncovered [vars]" case inserts the key under the existing `[vars]` table; a second `[vars]` header would be invalid TOML. While writing the test, check that the edited copy still parses: `wpy -c 'import tomllib,sys;tomllib.load(open(sys.argv[1],"rb"))' "$T/config.toml"`.

Run `git add scripts/test-check-pins.sh && git update-index --chmod=+x scripts/test-check-pins.sh`.

- [ ] **Step 2: Run it and watch it fail.** Run `bash scripts/test-check-pins.sh`. Expected: every case FAILs: `--only` doesn't exist yet, so the full check runs or the flag is ignored.

- [ ] **Step 3: Add the seam, the row helpers and `check_pins`.**
  - Right after the `PY` detection loop: `[ -n "${CHECK_INVARIANTS_NO_PY:-}" ] && PY=""  # test-check-pins.sh`
  - In place of `check_version_pins` and `check_bumper_exclude` (keep `_ps1_drive_ref_hits` where it is):

```bash
# --- pins recorded in more than one place ------------------------------------
# One row per value kept in several files, or per floor a pin must respect.
# An empty value is drift: a pattern that stops matching must fail, not pass.

# pin_equal <label> <where=value>... — every value non-empty and identical.
pin_equal() {
  local label="$1" kv first names="" shown="" sep="" drift=""
  shift
  first="${1#*=}"
  for kv in "$@"; do
    names="$names$sep${kv%%=*}"
    sep=" == "
    shown="$shown ${kv%%=*}='${kv#*=}'"
    if [ -z "${kv#*=}" ] || [ "${kv#*=}" != "$first" ]; then drift=1; fi
  done
  if [ -z "$drift" ]; then ok "$label @ $first ($names)"; else bad "$label drift:$shown"; fi
}

# pin_at_least <label> <version> <floor> <fix> — version >= floor.
pin_at_least() {
  if [ -z "$2" ] || [ -z "$3" ]; then
    bad "$1: could not read the version ('$2') or its floor ('$3')"
  elif [ "$(printf '%s\n%s\n' "$3" "$2" | sort -V | tail -1)" = "$2" ]; then
    ok "$1: $2 >= $3"
  else
    bad "$1: $2 is below $3 — $4"
  fi
}

# pin_major_at_most <label> <version> <max> <fix>
pin_major_at_most() {
  local major="${2%%.*}"
  case "$major" in
  '' | *[!0-9]*) bad "$1: could not read a version ('$2')" ;;
  *) if [ "$major" -le "$3" ]; then ok "$1: $2 (major <= $3)"; else bad "$1: $2 (major $major > $3) — $4"; fi ;;
  esac
}

# pin_bumper_handles <tool>... — each sits in bump-versions.sh's EXCLUDE or
# COUPLED_AUTO; otherwise the weekly bumper rewrites one side of a pair alone.
pin_bumper_handles() {
  local handled t missing=""
  handled=" $(sed -nE 's/^(EXCLUDE|COUPLED_AUTO)="([^"]*)".*/\2/p' scripts/bump-versions.sh | tr '\n' ' ') "
  for t in "$@"; do
    case "$handled" in *" $t "*) ;; *) missing="$missing $t" ;; esac
  done
  if [ -z "$missing" ]; then
    ok "bump-versions.sh skips or pair-bumps all $# coupled pins"
  else
    bad "bump-versions.sh would bump$missing alone — add each to EXCLUDE or COUPLED_AUTO"
  fi
}

# pin_vars_reachable — every config.toml [vars] *_version pin is reported by
# tasks/check-updates (as UPPER_CASE) and listed by scripts/gen-tool-memory.sh.
pin_vars_reachable() {
  local key missing="" n=0
  while read -r key; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    grep -q "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" tasks/check-updates || missing="$missing $key(tasks/check-updates)"
    grep -q "$key" scripts/gen-tool-memory.sh || missing="$missing $key(gen-tool-memory.sh)"
  done < <("$PY" -c 'import tomllib
for k in tomllib.load(open("config.toml","rb")).get("vars",{}):
    print(k) if k.endswith("_version") else None')
  if [ -z "$missing" ]; then ok "all $n [vars] *_version pin(s) reach check-updates and gen-tool-memory"; else bad "[vars] pin(s) not covered:$missing"; fi
}

check_pins() {
  hdr "pins recorded in more than one place"
  local want='$HOME/.local/share/vcpkg'
  pin_equal "VCPKG_ROOT" "want=$want" \
    "zshrc.tera=$(sed -nE 's/.*VCPKG_ROOT="([^"]*)".*/\1/p' dotfiles/zshrc.tera | head -1)" \
    "bashrc.tera=$(sed -nE 's/.*VCPKG_ROOT="([^"]*)".*/\1/p' dotfiles/bashrc.tera | head -1)" \
    "tasks/vcpkg=$(sed -nE 's/.*vroot="([^"]*)".*/\1/p' tasks/vcpkg | head -1)"
  # TypeScript 7 ships only bin/tsc, no lib/tsserver.js, so typescript-language-server can't start.
  pin_major_at_most "typescript (tsserver for typescript-language-server)" \
    "$(grep -E '^node = ' config.owned.toml | grep -oE 'typescript@[0-9.]+' | cut -d@ -f2)" 5 \
    "keep the 5.x line"
  pin_bumper_handles github:dj95/zjstatus http:ncdu go go:golang.org/x/tools/gopls node
  if [ -z "$PY" ]; then
    note "no python with tomllib — the TOML rows are skipped locally (CI enforces)"
    return
  fi
  pin_equal "mise" \
    "bootstrap.sh=$(sed -nE 's/^MISE_VERSION="([0-9.]+)".*/\1/p' bootstrap.sh)" \
    "bootstrap.ps1=$(sed -nE 's/^\$MiseVersion *= *"([0-9.]+)".*/\1/p' bootstrap.ps1 | head -1)" \
    "config.toml min_version=$(tomlval config.toml min_version 2>/dev/null)"
  # zjstatus states the zellij it needs in prose release notes; the floor sits next to the pin.
  pin_at_least "zellij for zjstatus" "$(tomlval config.linux.toml tools.zellij 2>/dev/null)" \
    "$(tomlval config.toml vars.zjstatus_zellij_floor 2>/dev/null)" \
    "bump zellij, or pin the zjstatus release built for it (and its floor)"
  pin_vars_reachable
}
```

Delete `check_vars_pin_coverage`, `check_zjstatus_zellij_coupling`, `check_tsls_typescript_coupling` and `check_go_gopls_coupling`, with their comment blocks. In the run list, replace `check_version_pins`, `check_bumper_exclude`, `check_vars_pin_coverage`, `check_go_gopls_coupling`, `check_tsls_typescript_coupling` and `check_zjstatus_zellij_coupling` with one `check_pins`, in the first slot. The gopls floor stays covered by `scripts/bump-versions.sh`'s `gopls_floor`, which bumps gopls only when its go.mod floor is met.

- [ ] **Step 4: Add `--only`** next to the existing `--shell-files` block, before the banner `printf`:

```bash
if [ "${1:-}" = --only ]; then
  shift
  [ "$#" -gt 0 ] || {
    echo "usage: $0 --only <check_name>..." >&2
    exit 2
  }
  for c in "$@"; do
    case "$c" in
    check_*) declare -F "$c" >/dev/null || {
      echo "unknown check: $c" >&2
      exit 2
    } ;;
    *)
      echo "unknown check: $c" >&2
      exit 2
      ;;
    esac
  done
  for c in "$@"; do "$c"; done
  [ "$fails" -eq 0 ]
  exit
fi
```

(`exit` with no argument returns the status of `[ "$fails" -eq 0 ]`: 0 or 1.)

- [ ] **Step 5: Rename the references** in `scripts/bump-versions.sh`'s comments (`check_tsls_typescript_coupling` and `check_bumper_exclude` → `check_pins`) and in `CLAUDE.md` ("checked by `check_version_pins` and friends" → "checked by `check_pins`"). Confirm with `rg -n 'check_version_pins|check_bumper_exclude|check_vars_pin_coverage|check_zjstatus_zellij_coupling|check_tsls_typescript_coupling|check_go_gopls_coupling' --glob '!docs/superpowers/**' --glob '!.superpowers/**' . || echo none` → `none`.

- [ ] **Step 6: Run the tests and lint.**
  - `bash scripts/test-check-pins.sh`: all cases pass.
  - `mise run lint`: all pass. The first section is now "pins recorded in more than one place", with six ✓ rows (VCPKG_ROOT, typescript, bumper, mise, zellij, vars), and no "gopls" section.
  - `time mise run lint` once before and once after this change: record both in the report. The gopls `curl` (up to 15 s offline) is gone.

- [ ] **Step 7: Commit and push.**

```bash
git add scripts/check-invariants.sh scripts/test-check-pins.sh scripts/bump-versions.sh CLAUDE.md
git commit -m "refactor(check-invariants): one table-driven check_pins (gopls network check dropped; --only for tests)" -m "<trailers>"
git push
```

---

### Task 4: Lint runs the self-tests; comment debris out; docs

**Files:**
- Modify: `scripts/check-invariants.sh` (add `check_self_tests`; trim comments to ≤ 1,100 lines total)
- Modify: `CLAUDE.md` (the Hooks section; stay ≤ 14,000 bytes)
- Modify: `docs/claude/verification.md` (if it names the old checks or "re-run test-hooks.sh by hand")

**Interfaces:**
- Consumes: `.claude/hooks/test-hooks.sh` (Tasks 1–2), `scripts/test-check-pins.sh` and `--only` (Task 3).

- [ ] **Step 1: Write the failing test.** Append to `scripts/test-check-pins.sh`, before the summary, a case proving the self-tests run under a pre-commit-like environment without touching the real index:

```bash
before="$(git -C "$ROOT" diff --cached --name-only | sort | md5sum)"
OUT="$(GIT_INDEX_FILE="$ROOT/.git/index" GIT_DIR="$ROOT/.git" bash "$ROOT/scripts/check-invariants.sh" --only check_self_tests 2>&1)"
RC=$?
after="$(git -C "$ROOT" diff --cached --name-only | sort | md5sum)"
case_ "self-tests pass under a pre-commit-like env" 0 "hook assertions passed"
[ "$before" = "$after" ]
RC=$?
OUT="index changed"
case_ "self-tests leave the real index alone" 0
```

To keep the two from recursing, `check_self_tests` passes `--no-self` to `test-check-pins.sh`, and `test-check-pins.sh` skips this block when its first argument is `--no-self`: `if [ "${1:-}" != --no-self ]; then …; fi`.

- [ ] **Step 2: Run it and watch it fail.** Run `bash scripts/test-check-pins.sh`. Expected: "self-tests pass under a pre-commit-like env" FAILs with exit 2 (unknown check).

- [ ] **Step 3: Add `check_self_tests`**, and call it in the run list just before `check_shellcheck`:

```bash
# The hook and pin-table self-tests run on every lint. git exports GIT_INDEX_FILE /
# GIT_DIR / GIT_WORK_TREE to its hooks; the tests make temp repos, so unset them.
check_self_tests() {
  hdr "self-tests (.claude/hooks/test-hooks.sh, scripts/test-check-pins.sh)"
  local out t
  for t in .claude/hooks/test-hooks.sh "scripts/test-check-pins.sh --no-self"; do
    if [ "${t%% *}" = .claude/hooks/test-hooks.sh ] && ! command -v jq >/dev/null 2>&1; then
      note "jq missing — test-hooks.sh skipped (it builds its inputs with jq)"
      continue
    fi
    # shellcheck disable=SC2086  # $t carries the script and its flag
    if out="$(env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE bash $t 2>&1)"; then
      ok "$(printf '%s\n' "$out" | tail -1 | sed -E 's/\x1b\[[0-9;]*m//g; s/^[^[:alnum:]]+//')"
    else
      bad "${t%% *} failed:"
      printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/      /'
    fi
  done
}
```

- [ ] **Step 4: Run it.** Run `bash scripts/test-check-pins.sh`, then `mise run lint`. Expected: all pass, and lint shows `✓ all N hook assertions passed` and `✓ all N check_pins cases passed` under "self-tests".

  CI's invariants job now runs both self-tests too. If a test needs a tool that job lacks (for example, `sync-tool-memory`'s case runs `scripts/gen-tool-memory.sh`), make that case skip with a printed reason when the tool is absent rather than fail, and note it in the report. Push and confirm the CI run is green before committing the next step.

- [ ] **Step 5: Trim the comment debris in `scripts/check-invariants.sh`** to ≤ 1,100 lines. Never change code. Remove:
  - history narrative ("used to", "PR #", "run #9", "#94", commit hashes in prose, "verified on 2026-…" anecdotes)
  - comments that restate the next line
  - "(c9709cf regression blocked)"-style suffixes in `ok` strings only where the string is a comment. Leave `ok`/`bad` strings alone: they are output.

Keep each comment that says *why* a check exists or a non-obvious constraint, in the present tense. Check the code is unchanged:

```bash
diff <(git show HEAD:scripts/check-invariants.sh | sed 's/^[[:space:]]*#.*$//' | sed '/^[[:space:]]*$/d') \
     <(sed 's/^[[:space:]]*#.*$//' scripts/check-invariants.sh | sed '/^[[:space:]]*$/d')
```

Expected: no output. Whole-line comments only, so `#` inside strings and regexes is untouched; trailing `# …` comments on code lines may stay or go, so show any such diff lines in the report. Then `wc -l scripts/check-invariants.sh` ≤ 1,100.

- [ ] **Step 6: Docs.** Edit `CLAUDE.md`'s `## Hooks` section, staying ≤ 14,000 bytes (`wc -c CLAUDE.md`):
  - Replace "After editing any of them, re-run `bash .claude/hooks/test-hooks.sh`." with "They source `lib.sh` (JSON in/out; fails open); `mise run lint` runs `test-hooks.sh`."
  - Replace the `parity-reminder.sh` line with "names the other half of zshrc/bashrc or the Nushell/PowerShell profiles."
  - Replace the `session-context.sh` line with "(SessionStart) reports dotfiles drift, host, mode and miserc tokens (and an exported `MISE_ENV`), WSL interop, tool readiness."
  - In "Working rules → Checks", add `scripts/test-check-pins.sh` if space allows. Otherwise the `check_self_tests` line in lint output is enough.

  In `docs/claude/verification.md`, update any line naming the deleted checks or saying hook tests run only by hand.

- [ ] **Step 7: Verify.** Run:
  - `mise run lint`
  - `bash scripts/check-templates.sh`
  - `wc -c CLAUDE.md docs/claude/*.md`
  - `wc -l scripts/check-invariants.sh README.md`

All within budget.

- [ ] **Step 8: Commit and push.**

```bash
git add scripts/check-invariants.sh scripts/test-check-pins.sh CLAUDE.md docs/claude/verification.md
git commit -m "chore(lint): hook and pin self-tests run on every lint; check-invariants comment debris removed; CLAUDE.md hooks section" -m "<trailers>"
git push
```

---

### Task 5: Branch verification and the PR

- [ ] **Step 1: Branch checks.**
  - `mise run lint`: all pass, including the self-tests.
  - `bash scripts/check-templates.sh` and `mise -C ~ tasks validate`: 0 warnings.
  - `git diff --stat main..HEAD`: only the files named in Tasks 1–4, plus the plan and `.claude/memory/`.
  - `rg -n 'hookfield\(\)' .claude/hooks/` → none.
  - `rg -n 'chezmoi/key\.txt|key\\\\.txt' dotfiles/claude/hooks/secret-guard.sh` → none.
  - CI on the branch head: green (invariants, templates, powershell, windows-http).
- [ ] **Step 2: Live hook check (this session).** The repo hooks are live, so the next edit in this checkout exercises `post-edit-guard`, `parity-reminder` and `sync-tool-memory` through `lib.sh`. Edit `dotfiles/zshrc.tera` (add and remove a blank line, no net change) and confirm the bashrc reminder appears; revert with `git checkout -- dotfiles/zshrc.tera`. `session-context.sh` shows `env=…` at the next session start.
- [ ] **Step 3: The global hook.** `secret-guard.sh` reaches `~/.claude/hooks` only through the user's `wsa`; that goes in the PR's after-merge steps. Don't apply it.
- [ ] **Step 4: Open the PR.** Title: `Simplify (5/5): checks and hooks tidy — one hook lib, one pin table, self-tests in lint`. The body lists:
  - each of spec §PR 5 items 1–7 and where it landed
  - the gopls network check removed, with lint time before → after
  - check-invariants.sh 1,279 → N lines
  - verification
  - after merge: `wsa` on each host (the secret-guard change), then a new Claude Code session

  End with:

  ```
  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```
