# PowerShell lint in CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lint the repo's three PowerShell scripts with PSScriptAnalyzer (Warning+) in CI, via a single runner script reusable locally, mirroring the shellcheck gate.

**Architecture:** A `scripts/check-ps.ps1` runner + a `PSScriptAnalyzerSettings.psd1` (excludes intentional-style rules) drive both a new `powershell` job in `.github/workflows/lint.yml` and an optional `make ps-lint`. Verified by CI iteration (pwsh unavailable locally).

**Tech Stack:** PowerShell 7 (pwsh), PSScriptAnalyzer, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-06-13-powershell-lint-ci-design.md`
**Branch:** `feat/secrets-bumps-pslint` (already created).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `PSScriptAnalyzerSettings.psd1` | Severity (Error+Warning) + excluded rules | Create |
| `scripts/check-ps.ps1` | Runner: analyze the 3 `.ps1` files + itself; exit non-zero on Warning+ | Create (LF, no BOM) |
| `.github/workflows/lint.yml` | Add a `powershell` job | Modify |
| `makefile/Makefile` | `make ps-lint` (soft-skip without pwsh) | Modify |
| `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md` | docs | Modify |

Note: `check-ps.ps1` is `.ps1`, so it is NOT matched by the invariant checker's `scripts/*.sh` shellcheck/mode globs nor its `.ps1` BOM set (which is the 3 named bootstrap files) — no conflict.

---

## Task 1: Settings file + runner script

**Files:**
- Create: `PSScriptAnalyzerSettings.psd1`
- Create: `scripts/check-ps.ps1`

- [ ] **Step 1: Create `PSScriptAnalyzerSettings.psd1`**

```powershell
@{
    # Mirror the shellcheck gate's rigor: fail on Warning and Error.
    Severity = @('Error', 'Warning')

    # Rules excluded because they fight an intentional, documented style choice.
    # Expand this list ONLY for confirmed intentional-style false positives,
    # each with a one-line reason (see the CI-iteration step in the plan).
    ExcludeRules = @(
        # The scripts use Write-Host extensively for colored, interactive UX.
        'PSAvoidUsingWriteHost'
    )
}
```

- [ ] **Step 2: Create `scripts/check-ps.ps1`**

```powershell
#!/usr/bin/env pwsh
# check-ps.ps1 — run PSScriptAnalyzer over the repo's PowerShell scripts.
# Single source for `make ps-lint` and the CI `powershell` job. Exits non-zero
# if any finding at Warning or Error remains after PSScriptAnalyzerSettings.psd1.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot   # scripts/ -> repo root
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

$targets = @(
    'bootstrap.ps1',
    'scripts/manage-hosts.ps1',
    'scripts/install-nerd-fonts.ps1',
    'scripts/check-ps.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Error 'PSScriptAnalyzer not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 2
}

$results = foreach ($t in $targets) {
    Invoke-ScriptAnalyzer -Path $t -Settings $settings
}

if ($results) {
    $results |
        Sort-Object ScriptName, Line |
        Format-Table -AutoSize Severity, ScriptName, Line, RuleName, Message |
        Out-String -Width 200 |
        Write-Host
    $n = ($results | Measure-Object).Count
    Write-Host "PSScriptAnalyzer: $n finding(s) at Warning+ (see above)" -ForegroundColor Red
    exit 1
}

Write-Host "PSScriptAnalyzer: clean (Warning+) over $($targets.Count) files" -ForegroundColor Green
exit 0
```

- [ ] **Step 3: Ensure LF endings (no CRLF)**

Run: `sed -i 's/\r$//' scripts/check-ps.ps1 PSScriptAnalyzerSettings.psd1; file scripts/check-ps.ps1`
Expected: not "CRLF". (These are pwsh7/CI files — no BOM needed; do NOT add a BOM.)

- [ ] **Step 4: Make the runner executable (harmless on the .ps1; keeps parity with scripts/)**

Run: `chmod +x scripts/check-ps.ps1`
(It runs via `pwsh scripts/check-ps.ps1` regardless; the bit is cosmetic.)

- [ ] **Step 5: Confirm the invariant checker is unaffected, then commit**

Run: `bash scripts/check-invariants.sh; echo "exit=$?"`
Expected: all ✓, exit=0 (the new `.ps1`/`.psd1` files are outside its checked sets).

```bash
git add PSScriptAnalyzerSettings.psd1 scripts/check-ps.ps1
git commit -m "feat(ci): add PSScriptAnalyzer runner + settings

scripts/check-ps.ps1 lints the .ps1 files at Warning+ using
PSScriptAnalyzerSettings.psd1 (excludes intentional Write-Host UX).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: CI job + make target

**Files:**
- Modify: `.github/workflows/lint.yml`
- Modify: `makefile/Makefile`

- [ ] **Step 1: Add the `powershell` job to `.github/workflows/lint.yml`**

The current file ends with the `invariants` job's last step (`run: bash scripts/check-invariants.sh`). Append this job at the same indentation level as `invariants:` (a sibling under `jobs:`):

```yaml
  powershell:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Install PSScriptAnalyzer
        shell: pwsh
        run: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
      - name: Run PSScriptAnalyzer
        shell: pwsh
        run: ./scripts/check-ps.ps1
```

- [ ] **Step 2: Validate the workflow YAML**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/lint.yml')); print('jobs:', list(d['jobs']))"`
Expected: `jobs: ['invariants', 'powershell']`.

- [ ] **Step 3: Add `make ps-lint` to `makefile/Makefile`**

After the `install-hooks` target (added on the prior branch), add:

```makefile
.PHONY: ps-lint

# ps-lint — PSScriptAnalyzer over the .ps1 scripts (same check CI runs). Soft-skips
# where pwsh is absent (the whole Linux fleet); mainly for Windows-host local use.
# Invoked `make ps-lint MODE=prod` (inherits scope.mk's MODE requirement).
ps-lint:
	@if command -v pwsh >/dev/null 2>&1; then \
	   pwsh $(REPO_ROOT)/scripts/check-ps.ps1; \
	 else \
	   printf 'pwsh not installed — skipped (CI enforces PowerShell lint)\n'; \
	 fi
```

CRITICAL: the recipe lines (the `@if …` block) MUST be TAB-indented; comment lines are not.

- [ ] **Step 4: Verify `make ps-lint` soft-skips locally**

Run: `make -C makefile ps-lint MODE=prod`
Expected: `pwsh not installed — skipped (CI enforces PowerShell lint)` (no error; exit 0).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint.yml makefile/Makefile
git commit -m "ci: add powershell job + make ps-lint target

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: CI-driven tuning (iterate until green)

**Files:** possibly `PSScriptAnalyzerSettings.psd1` (more exclusions) and/or the `.ps1` files (real fixes).

**Context:** pwsh isn't available locally, so the actual findings are only visible from CI. This task pushes the branch and iterates.

- [ ] **Step 1: Push the branch so CI runs**

```bash
git push -u origin feat/secrets-bumps-pslint
```

- [ ] **Step 2: Watch the `powershell` job**

Run: `gh run list --workflow=lint.yml --limit 1 --json databaseId,status,conclusion --jq '.[0]'`
Then: `gh run view <id> --job <jobId>` or `gh run view <id> --log-failed` to read findings.

- [ ] **Step 3: For each finding, fix or exclude**

- If it's a **real issue** (unused var, unreachable code, unsafe pattern), fix it in the `.ps1` file. Preserve the file's UTF-8 BOM if it's one of the 3 bootstrap files (`bootstrap.ps1`, `manage-hosts.ps1`, `install-nerd-fonts.ps1`) — restore with:
  `pwsh -c "[System.IO.File]::WriteAllText('<path>', (Get-Content -Raw '<path>'), [System.Text.UTF8Encoding]::new($true))"` (or the documented sed/iconv approach), then verify `hexdump -C <path> | head -1` starts `ef bb bf`.
- If it's an **intentional-style false positive**, add its `RuleName` to `ExcludeRules` in `PSScriptAnalyzerSettings.psd1` with a one-line `#` reason.

- [ ] **Step 4: Commit each round and re-push; repeat until the `powershell` job is green**

```bash
git add -A && git commit -m "ci(ps): <fix or exclude rule X> to clear PSScriptAnalyzer" && git push
```
(The pre-commit hook runs check-invariants.sh on each commit — if you touched a bootstrap `.ps1`, confirm its BOM check still passes; the hook will block if the BOM was lost.)

- [ ] **Step 5: Confirm green + invariant checker still passes**

Run: `gh run view <latest-id>` → `powershell` job ✓. Then `bash scripts/check-invariants.sh; echo exit=$?` → exit 0.

---

## Task 4: Docs

**Files:**
- Modify: `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md`

- [ ] **Step 1: README — extend the Enforcement / CI note**

Find the existing enforcement note: `grep -n 'check-invariants.sh\|Enforcement / CI' README.html | head`. In that `<details>` block, add a sentence to the existing prose (matching surrounding markup): "PowerShell scripts (`bootstrap.ps1`, `manage-hosts.ps1`, `install-nerd-fonts.ps1`) are linted by <strong>PSScriptAnalyzer</strong> at warning+ in the same CI workflow (`make ps-lint` runs it locally on a host with `pwsh`)."

- [ ] **Step 2: CLAUDE_CHANGELOG.md — append a row**

```markdown
| Added a PowerShell lint gate: `scripts/check-ps.ps1` + `PSScriptAnalyzerSettings.psd1` run PSScriptAnalyzer at warning+ over the three tracked `.ps1` files (and itself), wired into a new `powershell` job in `.github/workflows/lint.yml` and a soft-skipping `make ps-lint`. Closes the bash-vs-PowerShell linting asymmetry. | No | Contributor/maintenance surface; the Enforcement/CI README note gains one sentence. |
```

- [ ] **Step 3: CLAUDE.md — extend the Mechanical enforcement paragraph**

In the "Mechanical enforcement" paragraph under `## Load-bearing invariants`, append: "PowerShell scripts are linted by PSScriptAnalyzer (`scripts/check-ps.ps1` / `PSScriptAnalyzerSettings.psd1`) in the same CI workflow; run locally with `make ps-lint`."

- [ ] **Step 4: Verify + commit**

Run: `bash scripts/check-invariants.sh; echo exit=$?` (expect 0); `grep -c 'check-ps.ps1\|PSScriptAnalyzer' README.html` (expect ≥1).

```bash
git add README.html CLAUDE_CHANGELOG.md CLAUDE.md
git commit -m "docs: document PowerShell lint gate"
git push
```

---

## Self-Review Notes (author)

- **Spec coverage:** Part A→Task 1 (runner), Part B→Task 1 (settings), Part C→Task 2 (CI job), Part D→Task 3 (iteration), Part E→Task 2 (make ps-lint), Part F→Task 4 (docs).
- **No placeholders:** all file contents inline. The "expand ExcludeRules" step is genuinely CI-discovery (pwsh unavailable locally) — bounded by Task 3's explicit loop, not a hand-wave.
- **Naming consistency:** `scripts/check-ps.ps1`, `PSScriptAnalyzerSettings.psd1`, job `powershell`, target `ps-lint` used identically throughout.
- **BOM care:** Task 3 Step 3 explicitly preserves the bootstrap `.ps1` BOMs (and the invariant checker enforces it).
