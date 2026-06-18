# Claude `settings.json` Merge-on-Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `~/.claude/settings.json` from a whole-file chezmoi template into a `chezmoi:modify-template` that merges enforced infra keys over the live file while letting Claude Code own volatile keys — so `cza` stops reverting in-app changes like `/model`.

**Architecture:** A single source file `chezmoi/private_dot_claude/modify_private_settings.json` (a `chezmoi:modify-template`, **no `.tmpl`**) does a 3-layer `mergeOverwrite` (seed defaults → live file via `.chezmoi.stdin` → enforced keys; later wins) and emits `toPrettyJson`. Pure chezmoi Go-templating — no jq/bash/interpreters, native on Windows. The old `private_settings.json.tmpl` is deleted and every reference to it (check-invariants, setup-ccstatusline, parity-reminder, the CLAUDE/invariants/file-care docs) is repointed.

**Tech Stack:** chezmoi modify-templates (`fromJson`/`mergeOverwrite`/`toPrettyJson`/`.chezmoi.stdin`), bash test harness, the repo's `check-invariants.sh` lint.

## Global Constraints

- **Filename is `chezmoi/private_dot_claude/modify_private_settings.json` — NO `.tmpl` extension.** With `.tmpl`, chezmoi runs it as a *script* (render → exec) and you get `exec format error` / `map has no entry for key "stdin"`. The bare marker `{{- /* chezmoi:modify-template */ -}}` MUST be the first line on its own (chezmoi deletes the line containing that literal, then templates the rest).
- **Delete the old file in the same commit** as creating the new one — a target can't be both a regular file and a modify file (`chezmoi/private_dot_claude/private_settings.json.tmpl`).
- **Merge precedence:** `mergeOverwrite $seed $current $enforced` — seed (lowest) < current live file < enforced (highest). Guard `.chezmoi.stdin` for empty (fresh machine) before `fromJson`.
- **Enforced keys (always win):** `statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`.
- **Seed keys (set only when absent):** `model`→`opus[1m]`, `effortLevel`→`xhigh`, `theme`→`auto`, `editorMode`→`normal`, `tui`→`fullscreen`, `verbose`→`true`.
- **ccstatusline pin = `2.2.19`** in the enforced `statusLine.command` (`npx -y ccstatusline@2.2.19`) — MUST equal `CCSTATUSLINE_VERSION` in `makefile/versions.mk` (currently `2.2.19`). `check-invariants.sh` greps this file for it, so the check repoint MUST be in the same commit as the rename (Task 1) or the pre-commit/CI lint fails.
- **Encoding:** LF line endings; **no executable bit** (templated internally, never executed); target mode 0600 via the `private_` prefix.
- **No `README.html` change** (Claude-internal config). `CLAUDE_CHANGELOG.md` row, README column = **No**. Leave the historical changelog rows (32/49/84) that mention the old filename as-is — they're past-tense records.
- **Hook edits:** `parity-reminder.sh` is in the LF+0755 + shellcheck + shfmt set; after editing it, re-run `bash .claude/hooks/test-hooks.sh` (per CLAUDE.md).
- **Branch + conventional commit** ending with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **`settings.local.json` (`{"spinnerTipsEnabled": false}`) is out of scope — do not touch it.**

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `chezmoi/private_dot_claude/modify_private_settings.json` | the settings.json merge-template | **Create** |
| `chezmoi/private_dot_claude/private_settings.json.tmpl` | old whole-file template | **Delete** (`git rm`) |
| `scripts/check-invariants.sh` | ccstatusline dual-edit check | Repoint grep to the new filename (Task 1 — lint-critical) |
| `scripts/setup-ccstatusline.sh` | ccstatusline setup | Repoint the doc-only path var + a comment (Task 2) |
| `.claude/hooks/parity-reminder.sh` | edit-time nudges | Repoint the `case` pattern + the versions.mk message (Task 2) |
| `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md` | internal docs | Rewrite the settings.json entries for merge semantics + filename (Task 2) |
| `CLAUDE_CHANGELOG.md` | precedent log | Append one row (Task 2) |
| `/tmp/test-claude-settings-merge.sh` | offline test (throwaway, not committed) | New (Task 1) |

---

### Task 1: The merge-template + lint repoint (single commit)

**Files:**
- Create: `chezmoi/private_dot_claude/modify_private_settings.json`
- Delete: `chezmoi/private_dot_claude/private_settings.json.tmpl`
- Modify: `scripts/check-invariants.sh` (lines ~48-49, the ccstatusline grep)
- Create (throwaway): `/tmp/test-claude-settings-merge.sh`

**Interfaces:**
- Produces: the target `~/.claude/settings.json`, rendered by chezmoi on apply as `mergeOverwrite seed current enforced | toPrettyJson`. Consumers: Claude Code reads it; `setup-ccstatusline.sh` and the docs reference the source path (updated in Task 2).
- Consumes: nothing from earlier tasks (first task).

- [ ] **Step 1: Create the feature branch**

```bash
cd ~/.local/share/chezmoi
git checkout -b feat/claude-settings-merge
```

- [ ] **Step 2: Write the failing offline test**

Create `/tmp/test-claude-settings-merge.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Offline test for the ~/.claude/settings.json modify-template merge.
# Copies the real source file into a bare temp source, runs `chezmoi cat`
# against crafted scratch destinations, asserts the 3-layer merge in both the
# fresh and existing-file cases. Throwaway — not committed.
set -u
REPO="${1:-$HOME/.local/share/chezmoi}"
MODIFY="$REPO/chezmoi/private_dot_claude/modify_private_settings.json"

if [ ! -f "$MODIFY" ]; then
  echo "FAIL: modify-template not found at $MODIFY (not implemented yet?)"
  exit 1
fi

src="$(mktemp -d)"; trap 'rm -rf "$src"' EXIT
mkdir -p "$src/private_dot_claude"
cp "$MODIFY" "$src/private_dot_claude/modify_private_settings.json"

# render CURRENT_JSON ("" = missing file) -> merged output on stdout
render() {
  local dst; dst="$(mktemp -d)"; mkdir -p "$dst/.claude"
  [ -n "$1" ] && printf '%s' "$1" > "$dst/.claude/settings.json"
  HOME="$dst" chezmoi --source "$src" --destination "$dst" \
    cat "$dst/.claude/settings.json" 2>&1
  rm -rf "$dst"
}

fails=0
assert() { # label  python-bool-expr-on-`d`  output-json
  if printf '%s' "$3" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if ($2) else 1)" 2>/dev/null; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     output: %s\n' "$1" "$3"; fails=$((fails + 1))
  fi
}

o="$(render '')"
assert "fresh: model seeded opus[1m]"          'd["model"]=="opus[1m]"' "$o"
assert "fresh: statusLine enforced"            '"ccstatusline@" in d["statusLine"]["command"]' "$o"
assert "fresh: 14 keys, sorted"               'list(d)==sorted(d) and len(d)==14' "$o"

o="$(render '{"model":"sonnet","statusLine":{"command":"STALE"},"myCustomKey":42}')"
assert "preserve: model stays sonnet"          'd["model"]=="sonnet"' "$o"
assert "enforce: statusLine overrides STALE"   'd["statusLine"]["command"]!="STALE" and "ccstatusline@" in d["statusLine"]["command"]' "$o"
assert "preserve: unrelated key kept"          'd.get("myCustomKey")==42' "$o"

o="$(render '{"skipAutoPermissionPrompt":false}')"
assert "enforce: skipAuto forced true"         'd["skipAutoPermissionPrompt"] is True' "$o"
assert "enforce: secret-guard hook present"    'any("secret-guard" in h["command"] for m in d["hooks"]["PreToolUse"] for h in m["hooks"])' "$o"
assert "enforce: 8 plugins"                    'len(d["enabledPlugins"])==8' "$o"

o="$(render '{"enabledPlugins":{"superpowers@claude-plugins-official":false,"myplugin@x":true}}')"
assert "enforce: superpowers forced true"      'd["enabledPlugins"]["superpowers@claude-plugins-official"] is True' "$o"
assert "preserve: user extra plugin kept"      'd["enabledPlugins"].get("myplugin@x") is True' "$o"

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
```

- [ ] **Step 3: Run the test to verify it FAILS**

```bash
bash /tmp/test-claude-settings-merge.sh ~/.local/share/chezmoi
```

Expected: `FAIL: modify-template not found …` and exit 1 (the file doesn't exist yet).

- [ ] **Step 4: Create the merge-template**

Create `chezmoi/private_dot_claude/modify_private_settings.json` with exactly this content (note: first line is the bare marker; file has NO `.tmpl` extension):

```
{{- /* chezmoi:modify-template */ -}}
{{- /* Merge enforced infra keys over the live ~/.claude/settings.json, seeding
       personal keys only when absent. Buckets + rationale:
       docs/superpowers/specs/2026-06-17-claude-settings-merge-design.md
       This file MUST NOT have a .tmpl extension or chezmoi runs it as a script. */ -}}
{{- $seed := `{
  "model": "opus[1m]",
  "effortLevel": "xhigh",
  "theme": "auto",
  "editorMode": "normal",
  "tui": "fullscreen",
  "verbose": true
}` | fromJson -}}
{{- $current := dict -}}
{{- if .chezmoi.stdin -}}{{ $current = .chezmoi.stdin | fromJson }}{{- end -}}
{{- $enforced := `{
  "statusLine": {
    "type": "command",
    "command": "npx -y ccstatusline@2.2.19",
    "refreshInterval": 10
  },
  "skipAutoPermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "remoteControlAtStartup": true,
  "agentPushNotifEnabled": true,
  "inputNeededNotifEnabled": true,
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|Read|Bash",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/hooks/secret-guard.sh\"" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/hooks/dangerous-command-guard.sh\"" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/notify.sh\" 'Claude Code' 'needs your approval' < /dev/null" }
        ]
      },
      {
        "matcher": "idle_prompt",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/notify.sh\" 'Claude Code' 'waiting for your next prompt' < /dev/null" }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "claude-code-setup@claude-plugins-official": true,
    "microsoft-docs@claude-plugins-official": true,
    "hookify@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "github@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true
  }
}` | fromJson -}}
{{ mergeOverwrite $seed $current $enforced | toPrettyJson }}
```

- [ ] **Step 5: Delete the old whole-file template**

```bash
cd ~/.local/share/chezmoi
git rm chezmoi/private_dot_claude/private_settings.json.tmpl
```

- [ ] **Step 6: Repoint the ccstatusline check in `check-invariants.sh`**

In `scripts/check-invariants.sh`, the `ref=$(grep …)` line (~49) reads the old file. Change the path and the `ok` message:

Old:
```sh
  ref=$(grep -oE 'ccstatusline@[0-9][0-9.]*' \
    chezmoi/private_dot_claude/private_settings.json.tmpl | head -1 | sed 's/.*@//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "ccstatusline @ $v  (versions.mk == settings.json.tmpl)"
```
New:
```sh
  ref=$(grep -oE 'ccstatusline@[0-9][0-9.]*' \
    chezmoi/private_dot_claude/modify_private_settings.json | head -1 | sed 's/.*@//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "ccstatusline @ $v  (versions.mk == modify_private_settings.json)"
```
(Leave the `bad "ccstatusline drift: …"` line as-is — it still reads `$v`/`$ref`.)

- [ ] **Step 7: Run the offline test to verify it PASSES**

```bash
bash /tmp/test-claude-settings-merge.sh ~/.local/share/chezmoi
```

Expected: every `ok …` line, ending `ALL PASS`, exit 0.

- [ ] **Step 8: Sanity-check on this host (render + self-migration + lint)**

```bash
cd ~/.local/share/chezmoi
file chezmoi/private_dot_claude/modify_private_settings.json   # must NOT say CRLF
# Self-migration: the live model must be preserved, enforced keys applied.
chezmoi diff ~/.claude/settings.json --no-pager | sed -r 's/\x1b\[[0-9;]*[mGKH]//g' | grep -E '"model"|ccstatusline@' || true
make lint MODE=prod   # the repointed ccstatusline check must pass; no new failures
```

Expected: `file` is not CRLF; the diff keeps `"model": "opus[1m]"` (your live value, not reverted to a seed) and shows the enforced `ccstatusline@2.2.19`; `make lint` passes (ccstatusline check now reads the new filename).

- [ ] **Step 9: Commit (single commit)**

```bash
cd ~/.local/share/chezmoi
git add chezmoi/private_dot_claude/modify_private_settings.json scripts/check-invariants.sh \
        docs/superpowers/specs/2026-06-17-claude-settings-merge-design.md \
        docs/superpowers/plans/2026-06-17-claude-settings-merge.md
git rm --cached chezmoi/private_dot_claude/private_settings.json.tmpl 2>/dev/null || true
git commit -m "feat(claude): merge ~/.claude/settings.json on apply instead of whole-file template

Replace private_settings.json.tmpl with modify_private_settings.json (a
chezmoi:modify-template, no .tmpl). It mergeOverwrites seed defaults ->
the live file (.chezmoi.stdin) -> enforced infra keys, so Claude Code's
in-app changes (model, theme, effort, …) survive cza while hooks/plugins/
statusline stay enforced. Pure chezmoi Go-templating; no jq/bash. Repoint
the CCSTATUSLINE_VERSION check to the new filename.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

(The `git rm` in Step 5 already staged the deletion; the `--cached … || true` is a no-op safety net.)

---

### Task 2: Repoint remaining references + docs + changelog (single commit)

**Files:**
- Modify: `scripts/setup-ccstatusline.sh` (lines ~15 and ~163)
- Modify: `.claude/hooks/parity-reminder.sh` (lines ~42 and ~59)
- Modify: `CLAUDE.md` (lines 63, 81, 88, 127, 129)
- Modify: `docs/claude/invariants.md` (lines 16, 21)
- Modify: `docs/claude/file-care.md` (lines 39, 40)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: the new filename `modify_private_settings.json` and the merge semantics established in Task 1.
- Produces: nothing code-facing; brings docs/hooks/scripts into agreement with Task 1.

- [ ] **Step 1: Repoint `scripts/setup-ccstatusline.sh`**

Line ~15 — change the doc-only path var:
```sh
CLAUDE_SETTINGS_TRACKED_SRC="$CHEZMOI_SRC/private_dot_claude/modify_private_settings.json"
```
Line ~163 — the comment mentions the source path; change `private_settings.json.tmpl` → `modify_private_settings.json` in that comment.

- [ ] **Step 2: Repoint `.claude/hooks/parity-reminder.sh`**

Line ~42 (the versions.mk-change message) — change `ccstatusline@ in private_settings.json.tmpl` → `ccstatusline@ in modify_private_settings.json`.

Line ~59 (the `case` arm) — change the pattern and message:
```sh
  modify_private_settings.json)
    msg="If you changed the ccstatusline@ pin here, mirror it in CCSTATUSLINE_VERSION in makefile/versions.mk (dual-edit, no bridge)."
    ;;
```

- [ ] **Step 3: Verify the hook still passes its tests**

```bash
cd ~/.local/share/chezmoi
bash .claude/hooks/test-hooks.sh
file .claude/hooks/parity-reminder.sh                 # must NOT say CRLF
git ls-files --stage .claude/hooks/parity-reminder.sh # must show 100755
```
Expected: test-hooks all-pass; LF; mode 100755. (`test-hooks.sh` does not assert the settings filename, so the case rename stays green.)

- [ ] **Step 4: Rewrite the `CLAUDE.md` settings.json entries**

Line 63 — change `wired in `private_settings.json.tmpl`` → `wired in `modify_private_settings.json``.

Line 81 — change `the `ccstatusline@<pin>` literal in `private_settings.json.tmpl`` → `… in `modify_private_settings.json``.

Line 88 — replace the whole bullet with:
```
- **`~/.claude/settings.json` is a chezmoi merge-on-apply (`modify_private_settings.json`), NOT a whole-file template** — the source is a `chezmoi:modify-template` (it MUST NOT have a `.tmpl` extension, or chezmoi executes it as a script). Each apply deep-merges three layers, later winning: **seed defaults** (`model`→`opus[1m]`, `effortLevel`, `theme`, `editorMode`, `tui`, `verbose`) set only when absent → **the live file** (`.chezmoi.stdin`) → **enforced keys** (`statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`) which always win. So Claude Code's in-app changes to seed keys survive `cza`, while enforced infra/safety keys stay consistent. `setup-ccstatusline.sh` still must never write settings.json (the enforced `statusLine` overrides it anyway). To change an enforced key cross-host, edit the enforced block in `modify_private_settings.json`.
```

Line 127 — change `CCSTATUSLINE_VERSION` (`versions.mk` + `private_settings.json.tmpl`)` → `… + `modify_private_settings.json`)`.

Line 129 — change the settings entry to:
```
`modify_private_settings.json` (the `~/.claude/settings.json` merge-template — enforced keys forced every apply, seed keys set-if-absent; Notification hooks → `~/.claude/notify.sh`)
```

- [ ] **Step 5: Rewrite the `docs/claude/invariants.md` entries**

Line 16 — change both occurrences of `private_settings.json.tmpl` → `modify_private_settings.json`, and clarify the check reads the enforced block. Replace the entry with:
```
- **`versions.mk` ↔ `modify_private_settings.json` dual-edit for `CCSTATUSLINE_VERSION`.** The `ccstatusline@<pin>` literal in the enforced `statusLine.command` of `chezmoi/private_dot_claude/modify_private_settings.json` MUST match `CCSTATUSLINE_VERSION` in `makefile/versions.mk` (no chezmoi-template variable bridges them; `check-invariants.sh` greps this file). Drift means Claude Code's `statusLine` pins a different version than `setup-ccstatusline.sh` invokes interactively.
```

Line 21 — replace the whole entry with:
```
- **Claude Code `~/.claude/settings.json` is a chezmoi merge-on-apply, not a whole-file template.** The source `chezmoi/private_dot_claude/modify_private_settings.json` is a `chezmoi:modify-template` (no `.tmpl` extension) that deep-merges seed defaults → the live file (`.chezmoi.stdin`) → enforced keys (later wins) via `mergeOverwrite … | toPrettyJson`. **Enforced** (forced every apply): `statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`. **Seed** (set only when absent, so Claude Code's in-app changes persist): `model`, `effortLevel`, `theme`, `editorMode`, `tui`, `verbose`. `option_set_global` in `setup-ccstatusline.sh` still must NOT write settings.json (the enforced `statusLine` overrides a stray statusLine-only block anyway). Cross-host changes to an enforced key = edit the enforced block, commit, push.
```

- [ ] **Step 6: Rewrite the `docs/claude/file-care.md` entries**

Line 39 — replace the `private_settings.json.tmpl` entry with:
```
- **`chezmoi/private_dot_claude/modify_private_settings.json`** — the `~/.claude/settings.json` **merge-template** (a `chezmoi:modify-template`; **MUST NOT have a `.tmpl` extension** or chezmoi runs it as a script → `exec format error`). First line is the bare marker `{{- /* chezmoi:modify-template */ -}}`. Body: `mergeOverwrite $seed $current $enforced | toPrettyJson`, where `$current` is `.chezmoi.stdin | fromJson` guarded for empty (fresh machine). **Enforced** block (always wins): `statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`. **Seed** block (set only if absent): `model`→`opus[1m]`, `effortLevel`, `theme`, `editorMode`, `tui`, `verbose`. The enforced `statusLine.command` carries the pinned `ccstatusline@<version>` and MUST mirror `CCSTATUSLINE_VERSION` in `makefile/versions.mk` (`check-invariants.sh` greps THIS file). The enforced `hooks.Notification[*].command` entries reference `"$HOME/.claude/notify.sh"` literally — keep in lockstep with `executable_notify.sh`. Applies to `~/.claude/settings.json` at mode 0600 (parent 0700 via `private_`). LF, no executable bit (templated internally, never executed). Caveat: a malformed live `settings.json` makes `fromJson` error and fails `cza` on this one file (accepted — Claude Code writes valid JSON).
```

Line 40 — change `invoked by the `Notification` hooks in `private_settings.json.tmpl`` → `… in `modify_private_settings.json``.

- [ ] **Step 7: Append the `CLAUDE_CHANGELOG.md` row**

Add at the end of the table:
```markdown
| Converted `~/.claude/settings.json` from a whole-file chezmoi template (`private_settings.json.tmpl`) to a `chezmoi:modify-template` merge (`modify_private_settings.json`, no `.tmpl`): a 3-layer `mergeOverwrite` of seed defaults → the live file (`.chezmoi.stdin`) → enforced infra keys (later wins), emitted via `toPrettyJson`. Enforced keys (`statusLine`, `hooks`, `enabledPlugins`, skip/notify/remote toggles) are forced every apply; seed keys (`model`→`opus[1m]`, `effortLevel`, `theme`, `editorMode`, `tui`, `verbose`) are set only when absent, so Claude Code's in-app changes (e.g. `/model`) survive `cza` instead of being reverted. Pure chezmoi Go-templating (`fromJson`/`mergeOverwrite`/`toPrettyJson`) — no jq/bash, runs natively on the Windows dev host. Repointed the `CCSTATUSLINE_VERSION` check in `check-invariants.sh`, `parity-reminder.sh`, the `setup-ccstatusline.sh` path var, and the CLAUDE.md / invariants.md / file-care.md entries to the new filename + merge semantics. | No | Claude-internal config (same precedent as the model-tracking and plugin-set rows) — README documents the user-facing tool surface, not Claude Code settings. |
```

- [ ] **Step 8: Verify no stale references remain + lint clean**

```bash
cd ~/.local/share/chezmoi
# Only historical CLAUDE_CHANGELOG rows (32/49/84) + the superpowers spec/plan
# (which reference the OLD name as "the old file") may still match:
grep -rn "private_settings.json.tmpl" . --include='*.sh' --include='*.md' --include='*.mk' --include='*.yml' \
  | grep -v "docs/superpowers/" | grep -v "CLAUDE_CHANGELOG.md"
make lint MODE=prod
```
Expected: the `grep` prints nothing (all live references repointed); `make lint` passes.

- [ ] **Step 9: Commit**

```bash
cd ~/.local/share/chezmoi
git add scripts/setup-ccstatusline.sh .claude/hooks/parity-reminder.sh \
        CLAUDE.md docs/claude/invariants.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): repoint settings.json references to the merge-template

Update setup-ccstatusline.sh, parity-reminder.sh, and the CLAUDE.md /
invariants.md / file-care.md entries from private_settings.json.tmpl to
modify_private_settings.json and the new merge-on-apply semantics; add a
changelog row.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- modify-template (no `.tmpl`, marker first line) → Task 1 Step 4 + Global Constraints. ✓
- 3-layer merge precedence + partition → Task 1 Step 4 content; asserted in Step 2 test. ✓
- Delete old file → Task 1 Step 5. ✓
- Cross-platform (pure Go template) → inherent in the file (no shebang/jq); noted in constraints. ✓
- Self-migration (live model preserved) → Task 1 Step 8 diff check + Step 2 test case 2. ✓
- Empty-stdin/fresh-machine guard → Task 1 Step 4 (`if .chezmoi.stdin`) + Step 2 test case 1. ✓
- ccstatusline dual-edit moves to new file → Task 1 Step 6 (check-invariants) + Task 2 parity-reminder/docs. ✓
- Doc/invariant updates (CLAUDE.md, invariants.md, file-care.md) + changelog, No-README → Task 2. ✓
- All references repointed (setup-ccstatusline, parity-reminder) → Task 2 Steps 1-2 + Step 8 grep sweep. ✓
- settings.local.json untouched → Global Constraints; not in any file list. ✓
- No README change → Global Constraints + changelog No column. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every step has concrete file content or exact commands with expected output. The full merge-template body and the full test script are inline. ✓

**3. Type/name consistency:** Filename `modify_private_settings.json` (no `.tmpl`) used consistently everywhere; ccstatusline pin `2.2.19` matches `versions.mk`; the 8 enforced + 6 seed keys are identical between the Global Constraints, the Task 1 file content, the Task 2 doc rewrites, and the test's `14 keys` assertion (8+6=14). The test's `render`/`assert` helpers and the `.chezmoi.stdin` accessor match the implemented file. ✓
