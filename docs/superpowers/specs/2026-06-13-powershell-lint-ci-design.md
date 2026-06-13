# PowerShell lint in CI (PSScriptAnalyzer) — design

**Date:** 2026-06-13
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

The branch `feat/invariant-enforcement` (merged) added a shellcheck gate over the
repo's bash scripts, but the three tracked PowerShell scripts —
`bootstrap.ps1` (1338 lines), `scripts/manage-hosts.ps1` (646),
`scripts/install-nerd-fonts.ps1` (191) — are **not linted anywhere**. This is an
asymmetry: the bash side has a mechanical quality gate, the Windows side does
not. PowerShell bugs (unused vars, unreachable code, unsafe patterns, alias
misuse) ship unchecked.

## Decision (user-approved)

Add a `PSScriptAnalyzer` job to the existing `.github/workflows/lint.yml`, driven
by a single runner script (`scripts/check-ps.ps1`) so the check is reproducible
locally on any host with `pwsh` + the module, mirroring how `check-invariants.sh`
backs `make lint`. Gate at **Warning and above**, with a `PSScriptAnalyzerSettings.psd1`
that excludes rules which conflict with the scripts' intentional style.

Rejected alternatives:
- *Inline the analyzer call in the workflow YAML* — not locally runnable; diverges
  from the `check-invariants.sh` single-source pattern.
- *Error-only gate* — weaker than the bash side (Warning+); the user chose parity.

## Findings (investigation, 2026-06-13)

1. `pwsh` is **not available in the dev environment**, so PSScriptAnalyzer cannot
   be run locally during the build. Verification is therefore **CI-driven**:
   push the branch, read the run, tune the settings/fixes until green. (`gh` is
   authenticated, so runs can be watched from the CLI.)
2. GitHub `ubuntu-latest` runners ship `pwsh` preinstalled; `PSScriptAnalyzer`
   installs via `Install-Module … -Scope CurrentUser -Force`.
3. The scripts use `Write-Host` heavily for colored UX, so the default
   `PSAvoidUsingWriteHost` rule will fire pervasively and must be excluded.
   Other exclusions are unknown until the first CI run reveals them.

## Design

### Part A — `scripts/check-ps.ps1` (the runner, single source of truth)

- A PowerShell script (LF; no BOM required — it runs under pwsh 7 in CI / locally,
  not the Windows-5.1 bootstrap path, so it is NOT in the invariant checker's
  BOM-checked set).
- Resolves the repo root from its own location, runs
  `Invoke-ScriptAnalyzer -Path <file> -Settings <repo>/PSScriptAnalyzerSettings.psd1`
  over the targets: `bootstrap.ps1`, `scripts/manage-hosts.ps1`,
  `scripts/install-nerd-fonts.ps1`, and itself (`scripts/check-ps.ps1`).
- Prints findings grouped by file; exits non-zero if any finding at severity
  Warning or Error remains after the settings filter, else prints a clean summary
  and exits 0.

### Part B — `PSScriptAnalyzerSettings.psd1` (repo root)

- `Severity = @('Error','Warning')`.
- `ExcludeRules` — starts with `PSAvoidUsingWriteHost` (confirmed needed) and is
  expanded during the build (Part D) with any other rule that fires only because
  of an intentional, documented style choice. Each exclusion carries a one-line
  comment explaining why.

### Part C — `.github/workflows/lint.yml` (add a second job)

- Keep the existing `invariants` job unchanged. Add a parallel job `powershell`:
  - `runs-on: ubuntu-latest`
  - `actions/checkout@v5`
  - install PSScriptAnalyzer
  - `pwsh scripts/check-ps.ps1`
- Both jobs run on `push` + `pull_request` (already the workflow's triggers).

### Part D — iterative tuning (build-time, CI-driven)

Because the analyzer can't run locally: push the branch, read the `powershell`
job output, and for each finding either (a) fix it if it's a real issue, or
(b) add the rule to `ExcludeRules` if it's an intentional-style false positive
(with a justifying comment). Repeat until the job is green. Document the final
exclusion set in the settings file's comments.

### Part E — optional `make ps-lint`

- A `.PHONY: ps-lint` target that runs `pwsh scripts/check-ps.ps1` if `pwsh` is on
  PATH, else prints a soft "pwsh not installed — skipped (CI enforces)" notice
  (mirrors the shellcheck soft-skip in `check-invariants.sh`). Marginal on the
  Linux fleet (no pwsh); useful on a Windows host. Invoked `make ps-lint MODE=prod`
  per the standard MODE convention.

### Part F — docs

- `README.html`: extend the existing "Enforcement / CI" note to mention PowerShell
  scripts are linted by PSScriptAnalyzer in CI.
- `CLAUDE_CHANGELOG.md`: one row.
- `CLAUDE.md`: extend the "Mechanical enforcement" paragraph to note the PS side.

## Footprint

- **New:** `scripts/check-ps.ps1`, `PSScriptAnalyzerSettings.psd1`.
- **Edited:** `.github/workflows/lint.yml` (+job), `makefile/Makefile` (+`ps-lint`),
  `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md`.
- **No new Linux runtime deps** (pwsh only in CI).

## Verification

- CI `powershell` job is green on the branch.
- Deliberately introduce a real Warning-level issue (e.g. an unused variable) in a
  scratch edit → the job fails → revert.
- `make ps-lint MODE=prod` soft-skips on the Linux dev box (no pwsh) without error.

## Out of scope

- Installing pwsh on the Linux fleet.
- Auto-fixing findings (`Invoke-ScriptAnalyzer -Fix`) — review-and-fix by hand.
