# Automated weekly version-bump PRs — design

**Date:** 2026-06-13
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

`makefile/lib/check-updates.sh` already detects when a pinned tool version in
`makefile/versions.mk` drifts behind its newest upstream tag (via `git ls-remote`),
but it is **report-only** — bumping is a manual `versions.mk` edit followed by
`make provision`. Across ~60 pinned tools this is ongoing toil and pins quietly
fall behind. We want the fleet to be self-maintaining: a scheduled job that opens
a reviewable PR bumping the drifted pins.

## Decision (user-approved)

A custom script (`scripts/bump-versions.sh`) reusing the existing check-updates
machinery, run by a **weekly** scheduled GitHub Actions workflow that opens **one
combined PR** for human review (no auto-merge). Auto-bump only the **simple
single-location pins**; the three dual/triple-edit pins are reported in the PR
body as "manual bump available," never auto-edited.

Rejected alternatives:
- *Renovate / Dependabot* — the version scheme is bespoke (eget repos, the
  dual/triple-edit pins, the `latest` rolling pins); custom regex-managers would be
  complex and still couldn't safely handle the SHA-bearing pins. The existing
  `check-updates.sh` already does the drift detection.
- *Auto-merge* — would need idea #1 (container-provision CI) to prove installs;
  without it, bumps stay human-reviewed (preserves the report-only philosophy).
- *One PR per tool* — noisy (potentially many PRs/week); a combined PR is reviewed
  once and the lint CI validates it.

## Findings (investigation, 2026-06-13)

1. `check-updates.sh` worker mode prints machine-readable `status|name|detail`
   lines (`status ∈ ok|update|ahead|rolling|unknown`); for `update`,
   `detail = "<old> → <new>"`. The driver mode formats/colors these and adds a
   header+summary. A porcelain switch that emits the raw worker lines is a small,
   localized addition.
2. Specs (`name|version|repo|tag`) are assembled by the Makefile from
   `UPDATE_SPECS` (EGET_TOOL auto-registrations + hand-registered TOOL/USER_TOOL/
   bespoke entries), so the bumper must obtain them via `make check-updates`, not
   re-derive them.
3. The `versions.mk` variable for a tool follows the convention
   `uppercase(name) with '-'→'_' + '_VERSION'` (e.g. `ast-grep` →
   `AST_GREP_VERSION`, `ssh-copy-id` → `SSH_COPY_ID_VERSION`). It is NOT 100%
   guaranteed, so the bumper must **validate** (var exists AND its current value
   equals the reported `<old>`) before editing — a mismatch is skipped, never
   mis-edited.
4. The dual/triple-edit pins — `HELIX_VERSION` (↔ bootstrap.ps1),
   `JETBRAINSMONO_NERD_VERSION` (↔ font.sh SHA case ↔ install-nerd-fonts.ps1),
   `CCSTATUSLINE_VERSION` (↔ private_settings.json.tmpl) — require a new SHA
   and/or multi-file edits, so they are out of scope for auto-edit. The merged
   invariant checker (`check-invariants.sh`, run by lint CI) guarantees a
   half-bumped dual-edit can never pass, acting as a backstop.
5. `latest` pins are reported by check-updates as `rolling`, never `update`, so
   they are naturally skipped.

## Design

### Part A — porcelain mode in `makefile/lib/check-updates.sh`

- Honor an env switch `CHECK_UPDATES_PORCELAIN=1`: in driver mode, skip the header,
  the formatted/colored loop, and the summary; instead emit the raw collected
  `status|name|detail` lines (the contents of the existing `$tmp`) to stdout.
  Worker mode is unchanged. No new flags to the Makefile; the env var passes
  through `make`.

### Part B — `scripts/bump-versions.sh` (LF, 0755)

- `set -uo pipefail`; runs from repo root.
- Obtains updates: `CHECK_UPDATES_PORCELAIN=1 make -s --no-print-directory -C makefile check-updates MODE=prod`, then `grep '^update|'`. (Robust to stray lines via the grep anchor.)
- `EXCLUDE` set (var names): `HELIX_VERSION JETBRAINSMONO_NERD_VERSION CCSTATUSLINE_VERSION`.
- For each `update|<name>|<old> → <new>`:
  - Derive `VAR = uppercase(name)` with `-`→`_`, then `+_VERSION`.
  - If `VAR` ∈ EXCLUDE → add to the **manual** list (with old→new), skip.
  - Else if `versions.mk` contains a line `^VAR[[:space:]]*:=[[:space:]]*<old>$`
    → bump it in place (sed) to `<new>`, add to the **bumped** list.
  - Else → add to the **skipped** list ("var not found / value mismatch — manual").
- Print a summary to stdout (bumped / manual / skipped) AND write a Markdown
  summary to a file path given by `$BUMP_SUMMARY_FILE` (default `/tmp/bump-summary.md`)
  for the workflow to use as the PR body. Exit 0 always (report tool; the workflow
  decides whether anything changed).

### Part C — `.github/workflows/version-bumps.yml`

- Triggers: `schedule` (weekly cron, e.g. `'0 6 * * 1'` — Monday 06:00 UTC) +
  `workflow_dispatch` (manual run button).
- `permissions: { contents: write, pull-requests: write }`.
- `runs-on: ubuntu-latest`. Steps:
  1. `actions/checkout@v5`
  2. `bash scripts/bump-versions.sh` (env `BUMP_SUMMARY_FILE=bump-summary.md`)
  3. `peter-evans/create-pull-request@v6` with a fixed branch
     (`automation/version-bumps`), title `chore(versions): weekly pin bumps`, and
     `body-path: bump-summary.md`. The action no-ops if there is no diff, and
     updates the same PR on subsequent runs.
- The opened PR triggers `lint.yml` (invariant checker), validating consistency.

### Part D — docs

- `README.html`: brief note under "Enforcement / CI" that a weekly job proposes
  version bumps as a PR.
- `CLAUDE_CHANGELOG.md`: one row.
- `CLAUDE.md`: a line noting `scripts/bump-versions.sh` + the weekly workflow, and
  that the 3 dual/triple-edit pins are reported (not auto-bumped).

## Footprint

- **New:** `scripts/bump-versions.sh`, `.github/workflows/version-bumps.yml`.
- **Edited:** `makefile/lib/check-updates.sh` (+porcelain), `README.html`,
  `CLAUDE_CHANGELOG.md`, `CLAUDE.md`.

## Verification

- `CHECK_UPDATES_PORCELAIN=1 make -s --no-print-directory -C makefile check-updates MODE=prod`
  emits only `status|name|detail` lines (no header/summary/color).
- `bash scripts/bump-versions.sh` on the current tree: prints a sane bumped/manual/
  skipped summary; any `versions.mk` edits it makes are real drifts; the 3 special
  pins always land in the manual list; `git checkout -- makefile/versions.mk` reverts.
- A simulated case: force a single simple pin in `versions.mk` to an older value,
  run the bumper, confirm it bumps exactly that var and nothing else; revert.
- `scripts/bump-versions.sh` is LF + 0755 and passes the invariant checker's
  shellcheck (it's under `scripts/*.sh`).
- Workflow YAML parses; `workflow_dispatch` is present for manual testing.

## Out of scope

- Auto-recomputing SHAs / editing the 3 dual-triple-edit pins.
- Proving the bumped version actually installs (needs container-provision CI).
- Auto-merge.
