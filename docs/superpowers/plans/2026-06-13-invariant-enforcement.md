# Mechanical Invariant Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mechanically enforce the repo's load-bearing invariants (version-pin dual/triple-edits, LF+0755 file set, `.ps1` BOMs, sentinel blocks, chezmoiignore target-paths, shellcheck cleanliness) via a single script wired into `make lint`, a git pre-commit hook, and GitHub Actions — and fix the one real bug this would have caught.

**Architecture:** One orchestrator script (`scripts/check-invariants.sh`) holds every check; `make lint`, `.githooks/pre-commit`, and `.github/workflows/lint.yml` are thin callers. The shellcheck gate is set at **warning and above**, so the existing tree must first be made warning-clean (1 real bug + 5 trivial unused-var warnings).

**Tech Stack:** Bash (the script + hook), GNU Make (targets), GitHub Actions (CI), shellcheck (already in `makefile/packages.mk`).

**Spec:** `docs/superpowers/specs/2026-06-13-invariant-enforcement-design.md`

**Branch:** `feat/invariant-enforcement` (already created; spec committed there).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `scripts/check-invariants.sh` | All mechanical checks; single source of truth; exits non-zero on any failure | Create (LF, 0755) |
| `.githooks/pre-commit` | Run the checker before each commit | Create (LF, 0755) |
| `.github/workflows/lint.yml` | CI backstop on push/PR | Create |
| `makefile/Makefile` | `REPO_ROOT` var + `lint` / `install-hooks` targets | Modify |
| `scripts/manage-hosts.sh` | Fix SC2095 ssh-swallows-stdin (test-all bug) + SC2034 | Modify |
| `makefile/lib/doctor.sh` | SC2034 unused `kind` | Modify |
| `makefile/lib/pipe.sh` | SC2034 unused `name` | Modify |
| `scripts/setup-ccstatusline.sh` | SC2034 unused `CLAUDE_SETTINGS_TRACKED_SRC` + `SENTINEL_START` | Modify |
| `CLAUDE_CHANGELOG.md` | Changelog row | Modify |
| `CLAUDE.md` | One-line pointer to the enforcement script | Modify |
| `README.html` | `make lint` / `make install-hooks` + CI note | Modify |

**Tripwire reminders (from CLAUDE.md):** every shell file edited here must stay **LF-only** (`file <path>` must NOT say "CRLF") and **git mode 100755** (`git ls-files --stage <path>` shows `100755`). Repairs: `sed -i 's/\r$//' <path>` and `git update-index --chmod=+x <path>`. The checker built in Task 3 verifies this for the whole set.

---

## Task 1: Fix the SC2095 ssh-swallows-stdin bug (test-all-hosts)

**Files:**
- Modify: `scripts/manage-hosts.sh:582`
- Modify: `CLAUDE_CHANGELOG.md`

**Context:** In `test_host()`, the "Test SSH connection → all" loop runs `ssh ... exit` without `-n` inside `while IFS= read -r line; do … done <<< "$hosts"`. `ssh` slurps the loop's stdin here-string, so the loop exits after the first host — only host #1 is ever tested. The PowerShell twin (`manage-hosts.ps1:562`) uses `foreach` and is unaffected. This is the canonical example of what the enforcement layer catches.

- [ ] **Step 1: Reproduce the finding**

Run: `shellcheck -x scripts/manage-hosts.sh | grep -A2 SC2095`
Expected: shows the `SC2095 (warning): Use ssh -n` at line 582 (plus an info-level SC2095 at 579).

- [ ] **Step 2: Apply the fix**

In `scripts/manage-hosts.sh`, line 582, change:

```bash
      if ssh -o ConnectTimeout=5 -o BatchMode=yes "$huser@$hip" exit 2>/dev/null; then
```

to:

```bash
      if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$huser@$hip" exit 2>/dev/null; then
```

(Only the loop case at line 582. The single-host case further down is not in a `while read` loop, so it needs no change.)

- [ ] **Step 3: Verify the warning is gone**

Run: `shellcheck -x -S warning scripts/manage-hosts.sh | grep -c SC2095`
Expected: `0` (the info-level SC2095 at 579 remains but is below the warning gate; leave it).

- [ ] **Step 4: Verify file hygiene preserved**

Run: `file scripts/manage-hosts.sh && git ls-files --stage scripts/manage-hosts.sh | awk '{print $1}'`
Expected: NOT "CRLF"; mode `100755`.

- [ ] **Step 5: Add a changelog row**

Append this row to the table in `CLAUDE_CHANGELOG.md` (after the last existing row):

```markdown
| Fixed `manage-hosts.sh` "Test SSH → all" testing only the first host (SC2095: `ssh` without `-n` swallowed the `while read` loop's stdin here-string; PowerShell twin used `foreach` and was unaffected — silent behavioral parity drift). | No | Behavior already documented as "test all hosts"; the fix restores documented behavior, no README change. |
```

- [ ] **Step 6: Commit**

```bash
git add scripts/manage-hosts.sh CLAUDE_CHANGELOG.md
git commit -m "fix(manage-hosts): ssh -n in test-all loop (only first host was tested)

SC2095: ssh without -n swallowed the while-read loop's stdin here-string, so
'Test SSH connection -> all' exited after host #1. PowerShell twin uses foreach
and was unaffected. Restores documented test-all behavior.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Make the tree shellcheck-warning-clean (5 SC2034 fixes)

**Files:**
- Modify: `makefile/lib/doctor.sh:217`
- Modify: `makefile/lib/pipe.sh:29`
- Modify: `scripts/manage-hosts.sh:401-402`
- Modify: `scripts/setup-ccstatusline.sh:14,20`

**Context:** The warning-level shellcheck gate (Task 3) requires the existing tree to be warning-clean. After Task 1 there remain 5 `SC2034` (unused variable) warnings. Three are throwaway fields from `read`/positional destructuring (fix with `_` / drop). Two are documented config vars in the sensitive `setup-ccstatusline.sh` generator (kept with an inline disable — they pair with used siblings and the awk patterns use string literals, not the shell vars).

- [ ] **Step 1: Confirm the 5 findings**

Run: `shellcheck -x -S warning bootstrap.sh makefile/lib/*.sh scripts/*.sh 2>&1 | grep SC2034`
Expected: 5 lines — `doctor.sh` (`kind`), `pipe.sh` (`name`), `manage-hosts.sh` (`cur_name`), `setup-ccstatusline.sh` (`CLAUDE_SETTINGS_TRACKED_SRC`), `setup-ccstatusline.sh` (`SENTINEL_START`).

- [ ] **Step 2: Fix `doctor.sh` (unused `kind`)**

In `makefile/lib/doctor.sh:217`, change:

```bash
    IFS='|' read -r kind name version <<<"$row"
```

to:

```bash
    IFS='|' read -r _ name version <<<"$row"
```

(The row is `bespoke|name|version`; `kind` was never used. `_` is the idiomatic throwaway.)

- [ ] **Step 3: Fix `pipe.sh` (unused `name`)**

In `makefile/lib/pipe.sh:29`, change:

```bash
name="$1"; shift
```

to:

```bash
shift   # positional <name> arg — label only, currently unused
```

(The assignment was dead; `shift` still consumes the arg so `url="$1"` on the next line is unchanged.)

- [ ] **Step 4: Fix `manage-hosts.sh` (unused `cur_name`)**

In `scripts/manage-hosts.sh`, change the two lines at 401-402:

```bash
  local cur_name cur_ip cur_user cur_group
  read -r cur_name cur_ip cur_user cur_group <<< "$current"
```

to:

```bash
  local cur_ip cur_user cur_group
  read -r _ cur_ip cur_user cur_group <<< "$current"
```

(The entry is `name ip user group`; the name field is already held in `$name`.)

- [ ] **Step 5: Fix `setup-ccstatusline.sh` (two documented unused vars)**

In `scripts/setup-ccstatusline.sh`, add an inline shellcheck-disable above line 14:

```bash
# shellcheck disable=SC2034  # documents the tracked settings source; pairs with CLAUDE_SETTINGS_DEST
CLAUDE_SETTINGS_TRACKED_SRC="$CHEZMOI_SRC/private_dot_claude/private_settings.json.tmpl"
```

and above line 20:

```bash
# shellcheck disable=SC2034  # symmetry with SENTINEL_END; awk patterns below match the literal string
SENTINEL_START='# CCSTATUSLINE:START'
```

(Both shell vars are genuinely unreferenced — the awk in `sentinel_add`/`sentinel_remove` hardcodes the `# CCSTATUSLINE:START`/`END` literals and passes only `SENTINEL_END` as a value. The inline disable keeps the documented pairs without changing behavior.)

- [ ] **Step 6: Verify the whole tree is warning-clean**

Run: `shellcheck -x -S warning bootstrap.sh makefile/lib/*.sh scripts/*.sh; echo "exit=$?"`
Expected: no output, `exit=0`.

- [ ] **Step 7: Verify file hygiene preserved on all four**

Run:
```bash
for f in makefile/lib/doctor.sh makefile/lib/pipe.sh scripts/manage-hosts.sh scripts/setup-ccstatusline.sh; do
  file "$f"; git ls-files --stage "$f" | awk '{print $1, $4}'
done
```
Expected: none say "CRLF"; each git mode is `100755`.

- [ ] **Step 8: Commit**

```bash
git add makefile/lib/doctor.sh makefile/lib/pipe.sh scripts/manage-hosts.sh scripts/setup-ccstatusline.sh
git commit -m "chore(scripts): clear SC2034 warnings to enable the warning-level lint gate

Throwaway read/positional fields -> _ (doctor.sh, manage-hosts.sh) and a dead
assignment dropped (pipe.sh). Two documented config vars in setup-ccstatusline.sh
kept with inline disables (they pair with used siblings; awk uses the literals).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Create `scripts/check-invariants.sh`

**Files:**
- Create: `scripts/check-invariants.sh`

**Context:** The orchestrator. `set -uo pipefail` (deliberately **not** `-e`: a checker must run every check and tally, not abort on the first non-zero grep). It `cd`s to the repo root, runs six check groups, prints `✓/✗` per check, and exits non-zero if any failed. Style mirrors `makefile/lib/doctor.sh` (same color glyphs). The shellcheck sub-check runs at `-S warning` over `bootstrap.sh makefile/lib/*.sh scripts/*.sh` — which includes this script itself, so it must be warning-clean.

- [ ] **Step 1: Write the script**

Create `scripts/check-invariants.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# check-invariants.sh — mechanically enforce the load-bearing repo invariants
# documented in CLAUDE.md + docs/claude/file-care.md.
#
# Single source of truth for the checks; invoked three ways:
#   - make lint                  (makefile/Makefile -> $REPO_ROOT/scripts/check-invariants.sh)
#   - .githooks/pre-commit       (installed via `make install-hooks`)
#   - .github/workflows/lint.yml (CI backstop)
#
# Runs from anywhere — it cd's to the repo root. Exits 0 if all checks pass,
# non-zero otherwise. Deliberately NOT `set -e`: a checker must run EVERY check
# and tally failures, not abort on the first non-zero grep. We keep -u and
# pipefail and guard with explicit conditionals.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

fails=0
hdr()  { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '   %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '   %s✗%s %s\n' "$RED" "$RESET" "$*"; fails=$((fails + 1)); }
note() { printf '   %s·%s %s\n' "$YELLOW" "$RESET" "$*"; }

# Extract a `NAME := value` value from makefile/versions.mk.
mkval() {
  grep -E "^$1[[:space:]]*:=" makefile/versions.mk \
    | head -1 \
    | sed -E 's/^[^:=]*:=[[:space:]]*//; s/[[:space:]]*(#.*)?$//'
}

check_version_pins() {
  hdr "version-pin dual/triple-edits"
  local v ref font_v ps_v scope_dest expect rc_z rc_b

  v=$(mkval CCSTATUSLINE_VERSION)
  ref=$(grep -oE 'ccstatusline@[0-9][0-9.]*' \
        chezmoi/private_dot_claude/private_settings.json.tmpl | head -1 | sed 's/.*@//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "ccstatusline @ $v  (versions.mk == settings.json.tmpl)"
  else
    bad "ccstatusline drift: versions.mk='$v' settings.json.tmpl='$ref'"
  fi

  v=$(mkval JETBRAINSMONO_NERD_VERSION)
  font_v=$(grep -E '\)[[:space:]]*EXPECT_SHA' makefile/lib/font.sh \
           | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  ps_v=$(grep -E '^\$Version[[:space:]]*=' scripts/install-nerd-fonts.ps1 \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$v" ] && [ "$v" = "$font_v" ] && [ "$v" = "$ps_v" ]; then
    ok "jetbrains-mono nerd @ $v  (versions.mk == font.sh == install-nerd-fonts.ps1)"
  else
    bad "jetbrains-mono nerd drift: versions.mk='$v' font.sh='$font_v' ps1='$ps_v'"
  fi

  v=$(mkval HELIX_VERSION)
  ref=$(grep -oE 'helix-editor/helix/releases/download/[0-9][0-9.]+' bootstrap.ps1 \
        | head -1 | sed 's#.*/##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "helix @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "helix drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  scope_dest=$(grep -E '^[[:space:]]*HELIX_RUNTIME_DEST[[:space:]]*:=[[:space:]]*/usr' \
               makefile/scope.mk | head -1 | sed -E 's#.*:=[[:space:]]*##; s/[[:space:]]*$//')
  expect="${scope_dest}/runtime"
  rc_z=$(grep -oE 'HELIX_RUNTIME="[^"]*"' chezmoi/dot_zshrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  rc_b=$(grep -oE 'HELIX_RUNTIME="[^"]*"' chezmoi/dot_bashrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  if [ -n "$scope_dest" ] && [ "$rc_z" = "$expect" ] && [ "$rc_b" = "$expect" ]; then
    ok "helix-runtime @ $expect  (scope.mk == zshrc == bashrc)"
  else
    bad "helix-runtime drift: expect='$expect' zshrc='$rc_z' bashrc='$rc_b'"
  fi
}

check_line_endings_and_mode() {
  hdr "line-endings (LF) + git mode (100755)"
  local f mode crlf=0 modebad=0 missing=0
  local -a files=( makefile/lib/*.sh scripts/*.sh chezmoi/dot_local/bin/executable_batpipe )
  [ -e .githooks/pre-commit ] && files+=( .githooks/pre-commit )
  for f in "${files[@]}"; do
    if [ ! -e "$f" ]; then bad "missing: $f"; missing=$((missing + 1)); continue; fi
    if LC_ALL=C grep -q $'\r' "$f"; then bad "CRLF: $f"; crlf=$((crlf + 1)); fi
    mode=$(git ls-files --stage -- "$f" | awk '{print $1}')
    if [ -z "$mode" ]; then
      note "untracked (commit it so the mode is recorded): $f"
    elif [ "$mode" != "100755" ]; then
      bad "git mode $mode, want 100755: $f"; modebad=$((modebad + 1))
    fi
  done
  if [ "$crlf" -eq 0 ] && [ "$modebad" -eq 0 ] && [ "$missing" -eq 0 ]; then
    ok "${#files[@]} files: LF + 100755"
  fi
}

check_bom() {
  hdr "UTF-8 BOM on PowerShell files"
  local f b allgood=1
  local -a files=( scripts/manage-hosts.ps1 bootstrap.ps1 scripts/install-nerd-fonts.ps1 )
  for f in "${files[@]}"; do
    if [ ! -e "$f" ]; then bad "missing: $f"; allgood=0; continue; fi
    b=$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')
    if [ "$b" != "efbbbf" ]; then bad "no BOM (first bytes: $b): $f"; allgood=0; fi
  done
  [ "$allgood" -eq 1 ] && ok "${#files[@]} .ps1 files carry EF BB BF"
}

check_sentinels() {
  hdr "sentinel blocks matched"
  local s e
  s=$(grep -c 'CCSTATUSLINE:START' chezmoi/.chezmoiignore.tmpl)
  e=$(grep -c 'CCSTATUSLINE:END' chezmoi/.chezmoiignore.tmpl)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "chezmoiignore  CCSTATUSLINE:START/END (1/1)"
  else
    bad "chezmoiignore CCSTATUSLINE sentinels START=$s END=$e (want 1/1)"
  fi
  s=$(grep -c 'HOSTS:START' chezmoi/dot_config/wezterm/wezterm.lua)
  e=$(grep -c 'HOSTS:END' chezmoi/dot_config/wezterm/wezterm.lua)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "wezterm.lua    HOSTS:START/END (1/1)"
  else
    bad "wezterm.lua HOSTS sentinels START=$s END=$e (want 1/1)"
  fi
}

check_chezmoiignore_targets() {
  hdr "chezmoiignore uses target paths (not source-state names)"
  local offenders
  offenders=$(grep -vE '^[[:space:]]*(#|\{\{|$)' chezmoi/.chezmoiignore.tmpl \
              | grep -E '(^|/)(dot_|private_dot_)|\.tmpl[[:space:]]*$')
  if [ -z "$offenders" ]; then
    ok "no dot_/private_dot_/*.tmpl source-state patterns"
  else
    bad "source-state-style ignore patterns (silent no-op — use target paths):"
    printf '%s\n' "$offenders" | sed 's/^/       /'
  fi
}

check_shellcheck() {
  hdr "shellcheck (warning and above)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    note "shellcheck not installed — skipped locally (CI enforces; 'dnf install shellcheck' to run here)"
    return 0
  fi
  local -a targets=( bootstrap.sh makefile/lib/*.sh scripts/*.sh )
  if shellcheck -x -S warning "${targets[@]}"; then
    ok "clean at warning+ over ${#targets[@]} shell files"
  else
    bad "shellcheck reported warning+ findings (listed above)"
  fi
}

printf '%s%s== workstation invariant check ==%s\n' "$BOLD" "$BLUE" "$RESET"
check_version_pins
check_line_endings_and_mode
check_bom
check_sentinels
check_chezmoiignore_targets
check_shellcheck
echo
if [ "$fails" -eq 0 ]; then
  printf '%s✓ all invariant checks passed%s\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%s✗ %d invariant check(s) failed%s\n' "$RED" "$fails" "$RESET"
  exit 1
fi
```

- [ ] **Step 2: Make it executable + LF, then verify hygiene**

Run:
```bash
chmod +x scripts/check-invariants.sh
file scripts/check-invariants.sh
```
Expected: NOT "CRLF" (it should say "a /usr/bin/env bash script, ASCII text executable").

- [ ] **Step 3: Lint the new script itself**

Run: `shellcheck -x -S warning scripts/check-invariants.sh; echo "exit=$?"`
Expected: no output, `exit=0`. (If it reports anything, fix it before continuing — the script lints itself in CI.)

- [ ] **Step 4: Run it against the clean tree (positive test)**

Run: `bash scripts/check-invariants.sh; echo "exit=$?"`
Expected: a `✓` for every check group, final line `✓ all invariant checks passed`, `exit=0`. (`check-invariants.sh` may show a `·` "untracked" note for itself until it is committed — that is a note, not a failure, and does not affect the exit code.)

- [ ] **Step 5: Negative test — break one invariant, confirm detection**

Run:
```bash
sed -i 's/^CCSTATUSLINE_VERSION := .*/CCSTATUSLINE_VERSION := 9.9.9/' makefile/versions.mk
bash scripts/check-invariants.sh; echo "exit=$?"
```
Expected: a `✗ ccstatusline drift: versions.mk='9.9.9' settings.json.tmpl='2.2.19'` line and `exit=1`.

- [ ] **Step 6: Revert the deliberate break + confirm green again**

Run:
```bash
git checkout -- makefile/versions.mk
bash scripts/check-invariants.sh; echo "exit=$?"
```
Expected: all `✓`, `exit=0`.

- [ ] **Step 7: Commit (preserving the exec bit)**

```bash
git add scripts/check-invariants.sh
git ls-files --stage scripts/check-invariants.sh | awk '{print $1}'   # expect 100755
git commit -m "feat(lint): add scripts/check-invariants.sh invariant checker

Single source of truth for the mechanical checks: version-pin dual/triple-edits,
LF+0755 set, .ps1 BOMs, sentinel blocks, chezmoiignore target-paths, shellcheck.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

If `git ls-files --stage` shows `100644`, run `git update-index --chmod=+x scripts/check-invariants.sh` then re-commit.

---

## Task 4: Add `make lint` + `make install-hooks` targets

**Files:**
- Modify: `makefile/Makefile` (add `REPO_ROOT` near line 30; add targets after the `check-updates` target ~line 483)

**Context:** `make` runs with CWD = `makefile/` (`LIB := $(CURDIR)/lib`), so the repo root is `$(CURDIR)/..`. The `lint` target is scope-independent in spirit but, like every make target, inherits `scope.mk`'s parse-time `MODE` requirement — invoke as `make lint MODE=prod`. CI and the hook bypass make and call the script directly.

- [ ] **Step 1: Add `REPO_ROOT` next to `LIB`**

In `makefile/Makefile`, immediately after the line `LIB   := $(CURDIR)/lib` (line 30), add:

```makefile
# REPO_ROOT — make runs with CWD = makefile/, so the repo root is one dir up.
# Used by the `lint` / `install-hooks` targets to reach repo-root scripts.
REPO_ROOT := $(abspath $(CURDIR)/..)
```

- [ ] **Step 2: Add the targets after `check-updates`**

In `makefile/Makefile`, after the `check-updates:` target recipe (the `@printf … | $(LIB)/check-updates.sh` line, ~483), add:

```makefile
.PHONY: lint install-hooks

# lint — run the mechanical invariant checks (version pins, line-endings/mode,
# BOM, sentinels, chezmoiignore target-paths, shellcheck). Same script the
# pre-commit hook and CI run. Like every target it inherits scope.mk's MODE
# requirement: invoke as `make lint MODE=prod`.
lint:
	@$(REPO_ROOT)/scripts/check-invariants.sh

# install-hooks — point git at the tracked .githooks/ dir so the pre-commit
# invariant check runs before every commit. Idempotent.
install-hooks:
	@git -C $(REPO_ROOT) config core.hooksPath .githooks
	@printf 'installed: git hooks now run from .githooks/ (pre-commit -> check-invariants.sh)\n'
	@printf 'bypass one commit with: git commit --no-verify\n'
```

- [ ] **Step 3: Verify `make lint` runs the checker**

Run: `make -C makefile lint MODE=prod; echo "exit=$?"`
Expected: same output as `bash scripts/check-invariants.sh` — all `✓`, `exit=0`.

- [ ] **Step 4: Verify `make install-hooks` (then unset, to test the hook freshly in Task 5)**

Run:
```bash
make -C makefile install-hooks MODE=prod
git config --get core.hooksPath          # expect: .githooks
git config --unset core.hooksPath        # reset; Task 5 re-installs and tests the block
```
Expected: prints the install confirmation; `git config --get` shows `.githooks`.

- [ ] **Step 5: Commit**

```bash
git add makefile/Makefile
git commit -m "feat(make): add lint + install-hooks targets

lint runs scripts/check-invariants.sh; install-hooks sets core.hooksPath=.githooks.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Add `.githooks/pre-commit`

**Files:**
- Create: `.githooks/pre-commit`

**Context:** A thin hook that runs the checker from the repo root. Installed via `make install-hooks` (Task 4). LF + 0755 (it is itself in the LF+0755 set the checker verifies once it exists).

- [ ] **Step 1: Write the hook**

Create `.githooks/pre-commit` with exactly this content:

```bash
#!/usr/bin/env bash
# pre-commit — block commits that violate the repo's mechanical invariants.
# Installed by `make install-hooks` (git config core.hooksPath .githooks).
# Emergency bypass for a single commit: git commit --no-verify
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
exec "$ROOT/scripts/check-invariants.sh"
```

- [ ] **Step 2: Make it executable + lint it**

Run:
```bash
chmod +x .githooks/pre-commit
file .githooks/pre-commit
shellcheck -x .githooks/pre-commit; echo "exit=$?"
```
Expected: NOT "CRLF"; shellcheck `exit=0`.

- [ ] **Step 3: Install hooks and verify the checker now includes the hook**

Run:
```bash
make -C makefile install-hooks MODE=prod
bash scripts/check-invariants.sh 2>&1 | grep -E 'line-endings|100755'
```
Expected: the line-endings check now counts `.githooks/pre-commit` in its set and still passes (it must be committed with 100755 for the mode check; until committed it shows the "untracked" note — proceed to commit in Step 5).

- [ ] **Step 4: Functional test — the hook blocks a bad commit**

Run:
```bash
printf 'x\r\n' > scripts/_crlf_probe.sh        # a CRLF file the checker will reject
chmod +x scripts/_crlf_probe.sh
git add scripts/_crlf_probe.sh
git commit -m "should be blocked" ; echo "commit exit=$?"
```
Expected: the commit is **blocked** — the checker prints `✗ CRLF: scripts/_crlf_probe.sh` and the commit exit code is non-zero.

Then clean up the probe:
```bash
git reset -q scripts/_crlf_probe.sh
rm -f scripts/_crlf_probe.sh
```

- [ ] **Step 5: Commit the hook (preserving the exec bit)**

```bash
git add .githooks/pre-commit
git ls-files --stage .githooks/pre-commit | awk '{print $1}'   # expect 100755
git commit -m "feat(hooks): add .githooks/pre-commit running check-invariants.sh

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

(This commit itself runs the now-installed hook — it must pass. If `git ls-files --stage` shows `100644`, run `git update-index --chmod=+x .githooks/pre-commit` and re-commit with `--no-verify` for this one bootstrap commit, then re-run `bash scripts/check-invariants.sh` to confirm green.)

---

## Task 6: Add the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/lint.yml`

**Context:** The CI backstop for anyone who didn't run `make install-hooks`. Runs on push + PR, installs shellcheck, runs the checker directly (no make → no MODE needed).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/lint.yml` with exactly this content:

```yaml
name: lint
on: [push, pull_request]

jobs:
  invariants:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Run invariant checks
        run: bash scripts/check-invariants.sh
```

- [ ] **Step 2: Validate YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: run check-invariants.sh on push + PR (ubuntu-latest)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Documentation

**Files:**
- Modify: `CLAUDE_CHANGELOG.md`
- Modify: `CLAUDE.md`
- Modify: `README.html`

**Context:** Per CLAUDE.md's rule, the new contributor-facing commands (`make lint`, `make install-hooks`) + CI are user-facing surface and need a README mention. CLAUDE.md gets a pointer so future sessions know the mechanical counterpart to the tripwire list exists.

- [ ] **Step 1: Add the enforcement changelog row**

Append to the table in `CLAUDE_CHANGELOG.md`:

```markdown
| Added mechanical invariant enforcement: `scripts/check-invariants.sh` (version-pin dual/triple-edits, LF+0755 set, `.ps1` BOMs, sentinel blocks, chezmoiignore target-paths, shellcheck at warning+) wired into `make lint`, a `.githooks/pre-commit` hook (`make install-hooks`), and a `.github/workflows/lint.yml` CI job. Cleared 5 pre-existing SC2034 warnings to make the gate green. | **Yes** | New "Enforcement / CI" note under `#daily`: `make lint MODE=...` runs the checks, `make install-hooks` installs the pre-commit hook (bypass with `git commit --no-verify`), and GitHub Actions runs them on push/PR. No new end-user runtime surface — these are contributor/maintenance commands. |
```

- [ ] **Step 2: Add the CLAUDE.md pointer**

In `CLAUDE.md`, under the "## Load-bearing invariants" heading (just before the bullet list), add this paragraph:

```markdown
**Mechanical enforcement:** `scripts/check-invariants.sh` checks the mechanically-checkable subset of the invariants below (version-pin dual/triple-edits, the LF+0755 set, `.ps1` BOMs, sentinel-block matching, chezmoiignore target-paths) and runs shellcheck at warning+. Run it via `make lint MODE=prod`, install it as a pre-commit hook via `make install-hooks`, or let CI (`.github/workflows/lint.yml`) run it. **When you add a new invariant of one of these shapes, add a check there too.**
```

- [ ] **Step 3: Update README.html — locate the daily/maintenance area**

Run: `grep -nE 'make doctor|check-updates|Daily.*make|id="daily"' README.html | head`
Use the result to find the `#daily` section (and the existing `make doctor` / `make -C makefile …` command styling) so the new note matches surrounding markup.

- [ ] **Step 4: Update README.html — add the Enforcement / CI note**

In the `#daily` section, adjacent to the existing make-workflow content, add a short subsection matching the surrounding HTML structure (use the same element/class pattern as the neighbouring `make doctor` note). Content to convey:

> **Enforcement / CI.** `make lint MODE=dev` (or `MODE=prod`) runs `scripts/check-invariants.sh` — it verifies the version-pin dual/triple-edits, line-endings + executable bits, PowerShell BOMs, sentinel blocks, and chezmoiignore target-paths, and runs shellcheck. `make install-hooks` installs it as a git pre-commit hook (bypass a single commit with `git commit --no-verify`). The same checks run in GitHub Actions on every push and pull request.

- [ ] **Step 5: Verify the README edit landed and is well-formed**

Run:
```bash
grep -c 'make install-hooks' README.html      # expect >= 1
grep -c 'check-invariants.sh' README.html      # expect >= 1
```
Expected: both ≥ 1. Open `README.html` in a browser if possible to confirm the new note renders inside `#daily` without breaking layout.

- [ ] **Step 6: Confirm the checker still passes (docs edits don't affect it) and commit**

```bash
bash scripts/check-invariants.sh; echo "exit=$?"     # expect all ✓, exit=0
git add CLAUDE_CHANGELOG.md CLAUDE.md README.html
git commit -m "docs: document make lint / install-hooks + CI enforcement

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Final verification + branch handoff

**Files:** none (verification only)

- [ ] **Step 1: Full green run**

Run: `bash scripts/check-invariants.sh; echo "exit=$?"`
Expected: every check `✓`, `✓ all invariant checks passed`, `exit=0` (no `·` untracked notes now — everything is committed).

- [ ] **Step 2: `make lint` parity**

Run: `make -C makefile lint MODE=prod; echo "exit=$?"`
Expected: identical to Step 1, `exit=0`.

- [ ] **Step 3: Hook is installed and active**

Run: `git config --get core.hooksPath`
Expected: `.githooks`. (If empty, run `make -C makefile install-hooks MODE=prod`.)

- [ ] **Step 4: Whole-tree hygiene sweep**

Run:
```bash
for f in $(git ls-files 'makefile/lib/*.sh' 'scripts/*.sh' '.githooks/pre-commit'); do
  m=$(git ls-files --stage "$f" | awk '{print $1}')
  c=$(file "$f" | grep -c CRLF)
  [ "$m" = 100755 ] && [ "$c" = 0 ] || echo "PROBLEM: $f mode=$m crlf=$c"
done
echo "sweep done"
```
Expected: only `sweep done` (no `PROBLEM:` lines).

- [ ] **Step 5: Confirm clean working tree + review the branch**

Run:
```bash
git status --short          # expect empty
git log --oneline main..HEAD
```
Expected: empty status; the log shows the 7 feature commits (spec + Tasks 1–7).

- [ ] **Step 6: Finish the branch**

Invoke the `superpowers:finishing-a-development-branch` skill to decide merge vs PR vs cleanup. Note: GitHub Actions only runs after the branch reaches GitHub, so opening a PR (or pushing) is how CI gets its first exercise.

---

## Self-Review Notes (author)

- **Spec coverage:** Part A → Task 1; Part B → Task 3; Part C → Task 4; Part D → Tasks 4+5; Part E → Task 6; Part F → Task 7. The spec's "fail on warning+" requirement surfaced 5 pre-existing SC2034 warnings not anticipated in the spec → added Task 2 to clear them (otherwise the gate would be red on day one).
- **Naming consistency:** function names (`check_version_pins`, `check_line_endings_and_mode`, `check_bom`, `check_sentinels`, `check_chezmoiignore_targets`, `check_shellcheck`), `REPO_ROOT`, `core.hooksPath=.githooks`, and the script path `scripts/check-invariants.sh` are used identically across the script, Makefile, hook, and CI.
- **No placeholders:** every file's full content is inline; the only "locate-then-edit" is the README note (Task 7 Step 3–4), unavoidable in a 211 KB hand-maintained HTML — mitigated with a grep anchor + exact prose + a grep verification.
- **Deviation from spec:** the script uses `set -uo pipefail` (not `set -euo pipefail`) — justified inline: a linter must run all checks and tally, not abort on the first non-zero grep.
