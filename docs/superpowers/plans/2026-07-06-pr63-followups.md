# PR #63 Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the four deferred follow-ups from PR #63's final review: full template render coverage in `check-templates.sh`, the `sync-tool-memory.sh` worktree false-success fix, least-privilege CI permissions, and the README services-section retitle.

**Architecture:** Four independent, small tasks on one feature branch (`feat/pr63-followups`), one commit each, pushed immediately after each commit. Tasks 1–2 extend existing bash test/check harnesses (`scripts/check-templates.sh` render loop; `.claude/hooks/test-hooks.sh` assertion framework). Tasks 3–4 are one-file config/doc edits.

**Tech Stack:** bash, chezmoi `execute-template`, GitHub Actions, jq-driven Claude Code hooks.

## Global Constraints

- Workflow: feature branch + PR (the **user** merges — never self-merge); **push every commit** right after committing.
- Commit message footer (every commit):
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and the Claude-Session URL line (per harness instructions).
- First-party shell scripts must stay **LF-only, mode 100755 in git, `shfmt -i 2`-clean, shellcheck-clean at warning+**. Verify after editing: `file <path>` (no "CRLF"), `git ls-files --stage <path>` (100755). The repo's `post-edit-guard.sh` hook auto-repairs; still verify.
- After editing ANY hook file: re-run `bash .claude/hooks/test-hooks.sh` — all assertions must pass.
- Before every commit: `make lint MODE=prod` must pass (runs check-invariants + check-templates from the repo root via the GNUmakefile shim).
- Every task appends a row to `CLAUDE_CHANGELOG.md` (columns: `| Change | README update? | What to add |`) in the same commit.
- sudo commands are NEVER run by the agent — hand them to the user via `!` syntax.
- Local checker availability (AlmaLinux 9.8): `zsh` ✓, `yq` 4.53.3 ✓, `pwsh` ✗, `nu` ✗, python3 is 3.9 (no `tomllib`) — TOML/pwsh/nu checks soft-skip locally and enforce in CI (ubuntu-latest ships python 3.12 + yq; nothing new to install in `lint.yml`).
- Empirically verified 2026-07-06: all 13 currently-uncovered templates render cleanly via `chezmoi --config <synthetic> --source chezmoi/ execute-template` for the dev_machine group — the existing `render()` harness (which passes `--source`, needed by the pueued script's `include`) requires no changes.

---

### Task 0: Branch + plan commit

**Files:**
- Create: `docs/superpowers/plans/2026-07-06-pr63-followups.md` (this file)

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feat/pr63-followups
```

- [ ] **Step 2: Commit the plan and push**

```bash
git add docs/superpowers/plans/2026-07-06-pr63-followups.md
git commit -m "docs(plan): PR #63 follow-ups implementation plan"
git push -u origin feat/pr63-followups
```

---

### Task 1: Extend `check-templates.sh` to `.chezmoiscripts` + remaining dotfile templates, `(no stderr)` fallback

**Files:**
- Modify: `scripts/check-templates.sh` (header comment ~lines 1–16; `check()` ~lines 68–85; checkers ~lines 87–94; per-group loop ~lines 97–107; Windows section ~lines 109–121)
- Modify: `CLAUDE.md` line 74 (mechanical-enforcement paragraph, the check-templates sentence)
- Modify: `CLAUDE_CHANGELOG.md` (append row)
- Test: the script itself is the test — run green, then two deliberate-breakage red runs, then green again.

**Interfaces:**
- Consumes: existing helpers `check <group> <src-relative-tmpl> <label> [checker-fn]`, `render`, `ok`/`bad`/`note`, `$SRC`, `$WORK`.
- Produces: new checker fns `yaml_check(file)` and `toml_check(file)` (same contract as `bash_check`: exit 0 = pass); check labels `<script-basename>`, `pueued.service`, `cheat conf.yml`, `.gdbinit`, `ssh config`, `helix config.toml`, `wslconfig ps1`.

**Coverage being added** (everything `fd '\.tmpl$' chezmoi/` lists that isn't already covered, EXCEPT `chezmoi/.chezmoi.toml.tmpl` — that's the config template, needs `promptStringOnce` data; deliberately out of scope, note it in the header comment):

| Template | Check |
|---|---|
| `.chezmoiscripts/*.sh.tmpl` (7 files) | render per-group + `bash -n` (gated-out renders are empty → trivially pass) |
| `.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl` | render + pwsh parse (empty body on Linux; template-parse coverage, like the PS profile) |
| `dot_config/systemd/user/pueued.service.tmpl` | render per-group (branches on `.group` for ExecStart) — render-only |
| `dot_config/cheat/conf.yml.tmpl` | render + `yq` parse |
| `dot_gdbinit.tmpl` | render-only |
| `private_dot_ssh/private_config.tmpl` | render-only |
| `AppData/Roaming/helix/config.toml.tmpl` | render + python3 `tomllib` parse (soft-skip on py<3.11) |

- [ ] **Step 1: Add the `(no stderr)` fallback to both failure paths in `check()`**

Replace the current `check()` body (lines 68–85) with:

```bash
# check <group> <template> <label> <checker-cmd...>   (checker gets $out appended)
check() {
  local group=$1 tmpl=$2 label=$3
  shift 3
  local out="$WORK/out" err
  if ! render "$group" "$tmpl" "$out"; then
    err="$(head -1 "$WORK/render-err")"
    bad "$label [$group]: template render failed: ${err:-(no stderr)}"
    return
  fi
  if [ "$#" -eq 0 ]; then
    ok "$label [$group]: renders"
    return
  fi
  if "$@" "$out" >"$WORK/check-err" 2>&1; then
    ok "$label [$group]: renders + syntax OK"
  else
    err="$(head -1 "$WORK/check-err")"
    bad "$label [$group]: syntax check failed: ${err:-(no stderr)}"
  fi
}
```

- [ ] **Step 2: Add the two new checker functions** after `pwsh_check()` (line 94):

```bash
yaml_check() { yq eval '.' "$1" >/dev/null; }
toml_check() { python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$1"; }
```

- [ ] **Step 3: Extend the per-group loop** — inside `for group in dev_machine prod_machine; do ... done`, after the `.chezmoiignore` check (line 106), add:

```bash
  # chezmoi scripts: every .sh body must be valid bash in every group render
  # (a gated-out render is an empty file — bash -n passes trivially).
  for s in "$SRC"/.chezmoiscripts/*.sh.tmpl; do
    check "$group" ".chezmoiscripts/$(basename "$s")" "$(basename "$s" .tmpl)" bash_check
  done
  # systemd user unit: ExecStart branches on .group — render both ways.
  check "$group" dot_config/systemd/user/pueued.service.tmpl "pueued.service"
```

- [ ] **Step 4: Add the group-independent Linux-target singles** after the loop's `done` (before the Windows-target section):

```bash
# Group-independent Linux-target files: render once as dev_machine.
if command -v yq >/dev/null 2>&1; then
  check dev_machine dot_config/cheat/conf.yml.tmpl "cheat conf.yml" yaml_check
else
  note "cheat conf.yml: yq not installed — render-only (CI enforces)"
  check dev_machine dot_config/cheat/conf.yml.tmpl "cheat conf.yml(render)"
fi
check dev_machine dot_gdbinit.tmpl ".gdbinit"
check dev_machine private_dot_ssh/private_config.tmpl "ssh config"
```

- [ ] **Step 5: Extend the Windows-target section.** Add the helix TOML check before the `nu` block, and the wslconfig ps1 script inside BOTH arms of the existing pwsh if/else:

```bash
if python3 -c 'import tomllib' 2>/dev/null; then
  check dev_machine AppData/Roaming/helix/config.toml.tmpl "helix config.toml" toml_check
else
  note "helix config.toml: python3 tomllib (3.11+) unavailable — render-only (CI enforces)"
  check dev_machine AppData/Roaming/helix/config.toml.tmpl "helix config.toml(render)"
fi
```

and change the pwsh block to:

```bash
if command -v pwsh >/dev/null 2>&1; then
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile" pwsh_check
  check dev_machine .chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl "wslconfig ps1" pwsh_check
else
  note "PS profile: pwsh not installed — render-only (CI enforces)"
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile(render)"
  check dev_machine .chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl "wslconfig ps1(render)"
fi
```

- [ ] **Step 6: Update the header comment** (lines 1–16). Reword to state: renders ALL tracked templates (rc files, `.chezmoiscripts/*.tmpl`, `dot_config`/dotfile/AppData templates) for both host groups; checker matrix now zsh/bash/gitconfig/nu/pwsh/yq(yaml)/tomllib(toml); `.chezmoi.toml.tmpl` is deliberately excluded (config template — needs prompt data, not renderable with the synthetic config). Keep the existing soft-skip paragraph.

- [ ] **Step 7: Green run**

```bash
bash scripts/check-templates.sh
```
Expected: exit 0, `all rendered templates pass`, new lines visible — 7 script checks + `pueued.service` × 2 groups, `cheat conf.yml … syntax OK`, `.gdbinit … renders`, `ssh config … renders`, `helix config.toml` + `wslconfig ps1` as render-only notes (no pwsh/tomllib locally).

- [ ] **Step 8: Red run 1 — template error is caught with real stderr**

```bash
printf '{{ bogus }}\n' >> chezmoi/dot_gdbinit.tmpl
bash scripts/check-templates.sh; echo "exit=$?"
git checkout -- chezmoi/dot_gdbinit.tmpl
```
Expected: `✗ .gdbinit [dev_machine]: template render failed: …bogus…`, `exit=1`.

- [ ] **Step 9: Red run 2 — bash syntax error in a chezmoiscript is caught**

```bash
printf 'if [\n' >> chezmoi/.chezmoiscripts/run_once_after_init.sh.tmpl
bash scripts/check-templates.sh; echo "exit=$?"
git checkout -- chezmoi/.chezmoiscripts/run_once_after_init.sh.tmpl
```
Expected: `✗ run_once_after_init.sh [dev_machine]: syntax check failed: …` (and for prod_machine too — the appended line lands outside the `{{ end -}}` gate), `exit=1`.

- [ ] **Step 10: Final green run + lint + file hygiene**

```bash
bash scripts/check-templates.sh && make lint MODE=prod
file scripts/check-templates.sh                 # no CRLF
git ls-files --stage scripts/check-templates.sh # 100755
```
Expected: both pass.

- [ ] **Step 11: Update `CLAUDE.md` line 74.** Replace the sentence
`` `scripts/check-templates.sh` renders the tracked templates for both host groups and syntax-checks the output (zsh/bash/gitconfig/nu/pwsh; soft-skips missing checkers locally, the lint.yml `templates` job enforces the full set in CI). ``
with
`` `scripts/check-templates.sh` renders ALL tracked templates for both host groups — rc files, `.chezmoiscripts/*.tmpl`, `dot_config`/dotfile/AppData templates (only `.chezmoi.toml.tmpl` is excluded: config template, needs prompt data) — and syntax-checks the output (zsh/bash/gitconfig/nu/pwsh + yq for YAML + python3 tomllib for TOML; soft-skips missing checkers locally, the lint.yml `templates` job enforces the full set in CI). ``

- [ ] **Step 12: Append the `CLAUDE_CHANGELOG.md` row**

```markdown
| Extended `scripts/check-templates.sh` to every previously-uncovered template: all 7 `.chezmoiscripts/*.sh.tmpl` render per-group + `bash -n`; the wslconfig `.ps1.tmpl` script joins the pwsh parse check; `dot_config/cheat/conf.yml.tmpl` → `yq`; helix `config.toml.tmpl` → python3 `tomllib` (soft-skip on py<3.11); `pueued.service.tmpl` (per-group), `.gdbinit`, ssh `private_config.tmpl` render-checked. Only `.chezmoi.toml.tmpl` stays excluded (config template — needs prompt data). Failure messages print `(no stderr)` instead of trailing nothing when a checker dies silently. No lint.yml changes — CI's ubuntu runner already ships yq + python 3.12. | No | CI/lint internals (precedent: the original check-templates row). CLAUDE.md mechanical-enforcement paragraph updated instead. |
```

- [ ] **Step 13: Commit + push**

```bash
git add scripts/check-templates.sh CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "feat(lint): check-templates covers chezmoiscripts + remaining templates"
git push
```

---

### Task 2: Fix `sync-tool-memory.sh` false "regenerated" claim in git worktrees

**Files:**
- Modify: `.claude/hooks/sync-tool-memory.sh:40-56` (generator resolution + its comment)
- Test: `.claude/hooks/test-hooks.sh` (R5 section, lines 120–130 — add worktree case)

**Interfaces:**
- Consumes: test-hooks.sh helpers `j` (jq JSON builder), `ok <name> <cmd...>`, `has <substr>`, `$ROOT`, `$RH`.
- Produces: no new interfaces — behavior fix only. Contract: the hook regenerates the memory file of the checkout CONTAINING the edited file; `CLAUDE_PROJECT_DIR` is only a fallback when no `scripts/gen-tool-memory.sh` is found walking up from the edited file.

**The bug:** resolution prefers `$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh` unconditionally. When the edit happens in a git worktree, `CLAUDE_PROJECT_DIR` points at the main checkout, so the hook regenerates the MAIN checkout's `chezmoi/private_dot_claude/CLAUDE.md` from the MAIN checkout's (unedited) makefiles — a content no-op — while telling Claude the inventory was "regenerated … commit it with this change". The worktree's memory file is never touched. (`gen-tool-memory.sh` derives both its makefile inputs and its default `MEMFILE` from its own location, so whichever copy runs decides which checkout gets written.)

- [ ] **Step 1: Write the failing test.** In `.claude/hooks/test-hooks.sh`, at the end of the R5 section (after line 129 `ok "malformed input -> fail-open silent" empty`, before `rm -rf "$ST"`), add:

```bash
# worktree: an edit in a SECOND checkout must regenerate THAT checkout's
# memory file even when CLAUDE_PROJECT_DIR points at this (main) one.
WT="$(mktemp -d)"
mkdir -p "$WT/scripts" "$WT/makefile" "$WT/chezmoi/private_dot_claude"
cp "$ROOT/scripts/gen-tool-memory.sh" "$WT/scripts/"
cp "$ROOT/makefile/versions.mk" "$ROOT/makefile/tools.mk" "$ROOT/makefile/packages.mk" "$WT/makefile/"
printf 'x\n<!-- TOOLS:START -->\nstale\n<!-- TOOLS:END -->\n' >"$WT/chezmoi/private_dot_claude/CLAUDE.md"
OUT="$(printf '%s' "$(j --arg f "$WT/makefile/versions.mk" '{tool_name:"Edit",tool_input:{file_path:$f}}')" | CLAUDE_PROJECT_DIR="$ROOT" bash "$RH/sync-tool-memory.sh" 2>/dev/null)"
ok "worktree edit -> cza nudge" has 'cza'
ok "worktree's own memory regenerated" bash -c '! grep -q stale "'"$WT"'/chezmoi/private_dot_claude/CLAUDE.md"'
rm -rf "$WT"
```

- [ ] **Step 2: Run to verify it fails**

```bash
bash .claude/hooks/test-hooks.sh
```
Expected: `FAIL worktree's own memory regenerated` (the nudge assertion passes — that IS the bug: claims success, wrong file), everything else passes, exit 1.

- [ ] **Step 3: Fix the resolution order.** Replace lines 40–53 of `.claude/hooks/sync-tool-memory.sh` (the comment + `gen` resolution up to but not including `[ -n "$gen" ] || exit 0`) with:

```bash
# Resolve the generator from the EDITED FILE's checkout (walk up from the
# file), so an edit inside a git worktree regenerates THAT worktree's memory
# file. CLAUDE_PROJECT_DIR is only a fallback: it points at the main checkout,
# and preferring it used to silently regenerate the WRONG copy (a content
# no-op) while claiming success for the worktree edit.
gen=""
d="$(dirname "$norm")"
while [ "$d" != "/" ] && [ -n "$d" ]; do
  if [ -x "$d/scripts/gen-tool-memory.sh" ]; then
    gen="$d/scripts/gen-tool-memory.sh"
    break
  fi
  d="$(dirname "$d")"
done
if [ -z "$gen" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh" ]; then
  gen="$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh"
fi
```

Also update the file's header comment (lines 2–11): the sentence about resolution is inside the "Resolve the generator" comment being replaced — no other header change needed.

- [ ] **Step 4: Run tests to verify all pass**

```bash
bash .claude/hooks/test-hooks.sh
```
Expected: all assertions pass (previous total + 2), exit 0. The pre-existing R5 cases prove the normal main-checkout path still works (walk-up from `$ROOT/makefile/versions.mk` finds `$ROOT/scripts/gen-tool-memory.sh`).

- [ ] **Step 5: Lint + hygiene + changelog**

```bash
make lint MODE=prod
file .claude/hooks/sync-tool-memory.sh .claude/hooks/test-hooks.sh   # no CRLF
git ls-files --stage .claude/hooks/sync-tool-memory.sh .claude/hooks/test-hooks.sh  # 100755
```

Append to `CLAUDE_CHANGELOG.md`:

```markdown
| Fixed `.claude/hooks/sync-tool-memory.sh` false "regenerated" claim for edits in git worktrees: generator resolution now walks up from the EDITED file first (its own checkout's memory gets regenerated), demoting `CLAUDE_PROJECT_DIR` (which points at the main checkout) to a fallback. Regression test added to test-hooks.sh R5 (simulated second checkout + CLAUDE_PROJECT_DIR pointing elsewhere). | No | Claude-internal hook — invisible to a README-only user. |
```

- [ ] **Step 6: Commit + push**

```bash
git add .claude/hooks/sync-tool-memory.sh .claude/hooks/test-hooks.sh CLAUDE_CHANGELOG.md
git commit -m "fix(hooks): sync-tool-memory regenerates the edited file's own checkout"
git push
```

---

### Task 3: `permissions: contents: read` in lint.yml

**Files:**
- Modify: `.github/workflows/lint.yml:1-3` (top-level block after `on:`)
- Modify: `CLAUDE_CHANGELOG.md` (append row)

**Interfaces:** none — workflow metadata only. Scope note: `version-bumps.yml` is out of scope (it creates PRs and needs write perms; the review finding named lint.yml).

- [ ] **Step 1: Add the block.** Change the top of `.github/workflows/lint.yml` from:

```yaml
name: lint
on: [push, pull_request]

jobs:
```

to:

```yaml
name: lint
on: [push, pull_request]

# All three jobs only read the checkout — pin the token to least privilege.
permissions:
  contents: read

jobs:
```

- [ ] **Step 2: Sanity-check the YAML + lint**

```bash
yq eval '.permissions' .github/workflows/lint.yml
make lint MODE=prod
```
Expected: `contents: read`; lint passes.

- [ ] **Step 3: Changelog row**

```markdown
| Added top-level `permissions: contents: read` to `.github/workflows/lint.yml` — least-privilege GITHUB_TOKEN for all three lint jobs (they only read the checkout); was the default read/write. `version-bumps.yml` untouched (it opens PRs and manages its own permissions). | No | CI internals — invisible to a README-only user. |
```

- [ ] **Step 4: Commit + push**

```bash
git add .github/workflows/lint.yml CLAUDE_CHANGELOG.md
git commit -m "ci(lint): least-privilege workflow permissions (contents: read)"
git push
```

Expected after push: all three lint.yml jobs still green on the branch (verify with `gh run list --branch feat/pr63-followups`).

---

### Task 4: Retitle README `daily-services` h3 to "Services"

**Files:**
- Modify: `README.html:3810` (the h3) + `README.html:112-115` (the TOC link text)
- Modify: `CLAUDE_CHANGELOG.md` (append row)

**Interfaces:** the anchor id `daily-services` MUST NOT change — it's linked from the TOC and referenced (as `§daily-services`) by `CLAUDE.md`'s docs table.

**Why:** the section gained a `pueue` bullet in PR #63 that runs on EVERY Linux host (both groups, WSL included) — the old title "Web admin services (dev_machine, non-WSL)" now mis-scopes a third of its content. The dev-only/non-WSL scope moves into a lead-in sentence so no information is lost.

- [ ] **Step 1: Retitle the h3 and add the scope lead-in.** Replace (line ~3810):

```html
                    <h3 id="daily-services">Web admin services (dev_machine, non-WSL)</h3>
```

with:

```html
                    <h3 id="daily-services">Services</h3>
                    <p>
                        The web-admin trio below (Docker engine, Cockpit,
                        Dozzle) is <strong>dev_machine-only</strong> and
                        skipped on WSL; <code>pueue</code> runs on every
                        Linux host, both groups.
                    </p>
```

(Match the file's existing indentation — h3 at 20 spaces, block content at 24.)

- [ ] **Step 2: Update the TOC link text** (line ~112–115). Replace:

```html
                                <a href="#daily-services"
                                    >Web admin services</a
                                >
```

with:

```html
                                <a href="#daily-services"
                                    >Services</a
                                >
```

- [ ] **Step 3: Verify no dangling references**

```bash
rg -n 'Web admin services' README.html docs/README/README.js docs/README/README.css
rg -c 'id="daily-services"' README.html
```
Expected: first command → no matches (the §stack "Web admin" card text is a different string and untouched); second → `1`.

- [ ] **Step 4: Changelog row**

```markdown
| Retitled README `§daily-services` h3 "Web admin services (dev_machine, non-WSL)" → "Services" (+ matching TOC text): the section's new pueue bullet runs on every Linux host, so the old title mis-scoped it. Scope info preserved in a new lead-in sentence (web-admin trio = dev-only + non-WSL; pueue = everywhere). Anchor id unchanged — CLAUDE.md `§daily-services` pointers stay valid. | **Yes** | The change IS the README update: h3 + TOC text + lead-in `<p>` in §daily. |
```

- [ ] **Step 5: Lint, commit + push**

```bash
make lint MODE=prod
git add README.html CLAUDE_CHANGELOG.md
git commit -m "docs(readme): retitle daily-services h3 to Services"
git push
```

---

### Task 5: Final verification + PR

- [ ] **Step 1: Whole-branch check**

```bash
make lint MODE=prod && bash scripts/check-templates.sh && bash .claude/hooks/test-hooks.sh
git log --oneline main..HEAD    # expect 5 commits: plan + 4 tasks
```

- [ ] **Step 2: Confirm CI green on the branch**

```bash
gh run list --branch feat/pr63-followups --limit 5
```
Expected: lint workflow (all jobs incl. `templates`) green on the head commit.

- [ ] **Step 3: Open the PR** (the user merges — do NOT self-merge without explicit go-ahead)

```bash
gh pr create --title "chore: PR #63 follow-ups (template coverage, worktree hook fix, CI perms, README retitle)" --body "<summary of the four follow-ups, verification results, and the standard footer>"
```

- [ ] **Step 4: Remind the user** to remove the orphaned clipse binary (confirmed still present at `/usr/local/bin/clipse`):
type `! sudo rm -f /usr/local/bin/clipse` in the prompt.
