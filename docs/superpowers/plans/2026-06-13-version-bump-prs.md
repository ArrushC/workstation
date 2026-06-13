# Automated version-bump PRs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weekly GitHub Actions job that auto-bumps the simple single-location `versions.mk` pins and opens one reviewable PR; the 3 dual/triple-edit pins are reported, not auto-edited.

**Architecture:** A porcelain mode on the existing `check-updates.sh` feeds a new `scripts/bump-versions.sh` that validates-then-bumps `versions.mk`; a scheduled workflow runs it and opens/updates a PR via `peter-evans/create-pull-request`. The merged invariant checker validates every PR.

**Tech Stack:** Bash, GNU Make, GitHub Actions, `peter-evans/create-pull-request`.

**Spec:** `docs/superpowers/specs/2026-06-13-version-bump-prs-design.md`
**Branch:** `feat/secrets-bumps-pslint`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `makefile/lib/check-updates.sh` | Add `CHECK_UPDATES_PORCELAIN=1` raw-output mode | Modify |
| `scripts/bump-versions.sh` | Parse drifts → validate → bump simple pins → write PR-body summary | Create (LF, 0755) |
| `.github/workflows/version-bumps.yml` | Weekly schedule → run bumper → open PR | Create |
| `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md` | docs | Modify |

---

## Task 1: Porcelain mode for check-updates.sh

**Files:**
- Modify: `makefile/lib/check-updates.sh` (driver section, ~lines 96-100)

**Context:** The driver currently prints a colored header, a formatted per-tool loop, and a summary. Porcelain mode emits only the raw `status|name|detail` lines (the worker output already collected in `$tmp`) so a script can parse it. Worker mode is unchanged.

- [ ] **Step 1: Guard the header with the porcelain switch**

Find (around line 97):
```bash
printf '%s==>%s %schecking pinned versions against upstream tags (git ls-remote, %s jobs)%s\n' \
  "$BLUE" "$RESET" "$BOLD" "$JOBS" "$RESET"
```
Replace with:
```bash
if [[ -z "${CHECK_UPDATES_PORCELAIN:-}" ]]; then
  printf '%s==>%s %schecking pinned versions against upstream tags (git ls-remote, %s jobs)%s\n' \
    "$BLUE" "$RESET" "$BOLD" "$JOBS" "$RESET"
fi
```

- [ ] **Step 2: After the xargs collection, dump raw lines and exit in porcelain mode**

Find (around line 100):
```bash
xargs -r -P "$JOBS" -n 1 "$0" >"$tmp" || true
```
Immediately AFTER that line, add:
```bash
if [[ -n "${CHECK_UPDATES_PORCELAIN:-}" ]]; then
  cat "$tmp"
  exit 0
fi
```

- [ ] **Step 3: Verify porcelain output is clean (raw lines only)**

Run:
```bash
CHECK_UPDATES_PORCELAIN=1 make -s --no-print-directory -C makefile check-updates MODE=prod 2>/dev/null | head
```
Expected: only `status|name|detail` lines (e.g. `ok|gitui|0.28.1`, `update|foo|1.2.3 → 1.2.4`, `rolling|broot|...`) — no header, no colored summary. (This hits the network for ~60 repos; allow ~30-60s.)

- [ ] **Step 4: Verify normal mode is unchanged**

Run: `make -C makefile check-updates MODE=prod 2>/dev/null | head -3`
Expected: the usual `==> checking pinned versions…` header + formatted lines.

- [ ] **Step 5: shellcheck + hygiene + commit**

Run: `shellcheck -x -S warning makefile/lib/check-updates.sh; echo "exit=$?"` (expect 0); `file makefile/lib/check-updates.sh` (not CRLF); `git ls-files --stage makefile/lib/check-updates.sh | awk '{print $1}'` (100755).

```bash
git add makefile/lib/check-updates.sh
git commit -m "feat(check-updates): add CHECK_UPDATES_PORCELAIN raw-output mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The bumper script

**Files:**
- Create: `scripts/bump-versions.sh`

- [ ] **Step 1: Create `scripts/bump-versions.sh`**

```bash
#!/usr/bin/env bash
# bump-versions.sh — propose version-pin bumps for makefile/versions.mk.
# Runs check-updates (porcelain) and, for each SIMPLE single-location pin that has
# drifted, bumps it in versions.mk. The dual/triple-edit pins (helix, jetbrains-
# mono, ccstatusline) are reported, never auto-edited (they need a SHA recompute /
# multi-file edits, and check-invariants.sh guards their consistency).
#
# Used by .github/workflows/version-bumps.yml (weekly) and runnable locally.
# Writes a Markdown summary to $BUMP_SUMMARY_FILE (default /tmp/bump-summary.md)
# for the PR body. Exits 0 (report tool); the caller decides if anything changed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSIONS="makefile/versions.mk"
SUMMARY="${BUMP_SUMMARY_FILE:-/tmp/bump-summary.md}"

# Dual/triple-edit pins — reported, never auto-edited.
EXCLUDE="HELIX_VERSION JETBRAINSMONO_NERD_VERSION CCSTATUSLINE_VERSION"

bumped=""; manual=""; skipped=""

updates=$(CHECK_UPDATES_PORCELAIN=1 \
            make -s --no-print-directory -C makefile check-updates MODE=prod 2>/dev/null \
          | grep '^update|' || true)

while IFS='|' read -r _ name detail; do
  [ -n "${name:-}" ] || continue
  old="${detail%% *}"          # "old → new" -> "old"
  new="${detail##* }"          # "old → new" -> "new"
  var="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_VERSION"
  old_re="${old//./\\.}"

  case " $EXCLUDE " in
    *" $var "*)
      manual="${manual}- \`$var\` ($name): $old → $new — needs SHA/multi-file edit (manual)\n"
      continue ;;
  esac

  if grep -qE "^${var}[[:space:]]*:=[[:space:]]*${old_re}[[:space:]]*\$" "$VERSIONS"; then
    sed -i -E "s|^(${var}[[:space:]]*:=[[:space:]]*)${old_re}[[:space:]]*\$|\1${new}|" "$VERSIONS"
    bumped="${bumped}- \`$var\` ($name): $old → $new\n"
  else
    skipped="${skipped}- \`$var\` ($name): reported $old → $new but no matching pin line (manual)\n"
  fi
done <<< "$updates"

{
  echo "## Automated version-pin bumps"
  echo
  if [ -n "$bumped" ];  then echo "### Bumped in \`makefile/versions.mk\`"; echo; printf '%b' "$bumped";  echo; fi
  if [ -n "$manual" ];  then echo "### Manual bump available (not auto-edited)"; echo; printf '%b' "$manual"; echo; fi
  if [ -n "$skipped" ]; then echo "### Skipped (could not map safely)"; echo; printf '%b' "$skipped"; echo; fi
  [ -n "$bumped$manual$skipped" ] || echo "All pins up to date — nothing to bump."
  echo
  echo "_Generated by \`scripts/bump-versions.sh\`. Each bumped pin reinstalls on next \`make provision\` (version baked into the stamp). Review before merge._"
} | tee "$SUMMARY"
```

- [ ] **Step 2: Executable + LF + shellcheck**

Run:
```bash
chmod +x scripts/bump-versions.sh
sed -i 's/\r$//' scripts/bump-versions.sh
shellcheck -x -S warning scripts/bump-versions.sh; echo "exit=$?"
```
Expected: shellcheck exit=0. (Fix any finding before continuing — the invariant checker lints `scripts/*.sh`.)

- [ ] **Step 3: Functional test on the real tree (no-op expected if all current)**

Run: `BUMP_SUMMARY_FILE=/tmp/bs.md bash scripts/bump-versions.sh; echo "exit=$?"; git diff --stat makefile/versions.mk`
Expected: prints a summary; the 3 EXCLUDE pins, if drifted, appear under "Manual bump available"; if any simple pin is genuinely behind upstream, `versions.mk` shows that bump in `git diff`. Exit 0.
Then **revert any real edits** so this commit only adds the script: `git checkout -- makefile/versions.mk`.

- [ ] **Step 4: Simulated bump test (prove it edits exactly the right line)**

Run:
```bash
# pick a known simple pin and fake an older value
sed -i 's/^FD_VERSION *:= .*/FD_VERSION         := 0.0.1/' makefile/versions.mk
BUMP_SUMMARY_FILE=/tmp/bs.md bash scripts/bump-versions.sh >/dev/null
grep '^FD_VERSION' makefile/versions.mk    # expect bumped to the real latest (not 0.0.1)
git checkout -- makefile/versions.mk
```
Expected: `FD_VERSION` is rewritten from `0.0.1` to the current upstream `fd` version; no other line changed. Revert restores the real pin.

- [ ] **Step 5: Commit (hook runs check-invariants.sh — must pass)**

```bash
git add scripts/bump-versions.sh
git ls-files --stage scripts/bump-versions.sh | awk '{print $1}'   # expect 100755
git commit -m "feat: scripts/bump-versions.sh — auto-bump simple versions.mk pins

Validates each pin before editing; the 3 dual/triple-edit pins are reported, not
auto-edited (check-invariants.sh backstops consistency).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
If git mode shows 100644: `git update-index --chmod=+x scripts/bump-versions.sh` then re-commit.

---

## Task 3: Scheduled workflow

**Files:**
- Create: `.github/workflows/version-bumps.yml`

- [ ] **Step 1: Create `.github/workflows/version-bumps.yml`**

```yaml
name: version-bumps
on:
  schedule:
    - cron: '0 6 * * 1'   # Mondays 06:00 UTC
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Propose version bumps
        run: bash scripts/bump-versions.sh
        env:
          BUMP_SUMMARY_FILE: bump-summary.md
      - name: Create or update PR
        uses: peter-evans/create-pull-request@v6
        with:
          branch: automation/version-bumps
          delete-branch: true
          title: 'chore(versions): weekly pin bumps'
          commit-message: 'chore(versions): weekly pin bumps'
          body-path: bump-summary.md
```

- [ ] **Step 2: Validate YAML**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/version-bumps.yml')); print('jobs:', list(d['jobs']), 'on:', list(d['on']) if isinstance(d.get('on'),dict) else d.get(True))"`
Expected: `jobs: ['bump']` and the `on` includes `schedule` + `workflow_dispatch`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/version-bumps.yml
git commit -m "ci: weekly version-bump PR workflow (workflow_dispatch + Monday cron)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: (after push) manually trigger once to validate end-to-end**

After the branch is pushed (Task 4 of the overall branch, or now if pushed):
Run: `gh workflow run version-bumps.yml --ref feat/secrets-bumps-pslint` then `gh run watch` / `gh run view`.
Expected: the job runs the bumper and, if any simple pin is behind, opens PR `automation/version-bumps`; if nothing's behind, the create-pull-request step reports "No changes" and opens no PR. Either is a pass. (Note: scheduled `cron` only fires from the default branch once merged; `workflow_dispatch` is how we test pre-merge.)

---

## Task 4: Docs

**Files:**
- Modify: `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md`

- [ ] **Step 1: README — note the weekly bump automation**

In the existing "Enforcement / CI" `<details>` (`grep -n 'Enforcement / CI' README.html`), add a sentence: "A weekly GitHub Actions job (`version-bumps.yml`) runs `scripts/bump-versions.sh` and opens a PR bumping any drifted single-location `versions.mk` pins (the dual/triple-edit pins are listed for manual bumping); every such PR is validated by the invariant checker."

- [ ] **Step 2: CLAUDE_CHANGELOG.md — append a row**

```markdown
| Added automated weekly version-bump PRs: `CHECK_UPDATES_PORCELAIN` mode on `check-updates.sh` feeds `scripts/bump-versions.sh`, which validates-then-bumps the simple single-location `versions.mk` pins; `.github/workflows/version-bumps.yml` runs it weekly (+ workflow_dispatch) and opens one PR via peter-evans/create-pull-request. The 3 dual/triple-edit pins are reported, not auto-edited; the invariant checker validates each PR. No auto-merge. | No | Contributor/maintenance automation; the Enforcement/CI README note gains one sentence. |
```

- [ ] **Step 3: CLAUDE.md — note the bumper**

Append to the "Mechanical enforcement" paragraph: "A weekly `version-bumps.yml` workflow runs `scripts/bump-versions.sh` to PR simple-pin bumps (the 3 dual/triple-edit pins are reported, not auto-edited)."

- [ ] **Step 4: Verify + commit**

Run: `bash scripts/check-invariants.sh; echo exit=$?` (expect 0); `grep -c 'bump-versions\|version-bumps' README.html` (expect ≥1).

```bash
git add README.html CLAUDE_CHANGELOG.md CLAUDE.md
git commit -m "docs: document weekly version-bump PR automation"
```

---

## Self-Review Notes (author)

- **Spec coverage:** Part A→Task 1 (porcelain), Part B→Task 2 (bumper), Part C→Task 3 (workflow), Part D→Task 4 (docs).
- **No placeholders:** all code inline; the EXCLUDE set and var-derivation are concrete.
- **Safety:** validate-before-edit (grep `^VAR := old`) + EXCLUDE set + the invariant checker as CI backstop = a mis-mapped name is skipped, never mis-edited (Task 2 Steps 3-4 prove both the no-op and the targeted-edit cases).
- **Naming consistency:** `CHECK_UPDATES_PORCELAIN`, `scripts/bump-versions.sh`, `BUMP_SUMMARY_FILE`, branch `automation/version-bumps`, workflow `version-bumps.yml` used identically across tasks.
