# Mechanical invariant enforcement (lint + CI + pre-commit) — design

**Date:** 2026-06-13
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

The repo carries ~a dozen load-bearing invariants (documented in `CLAUDE.md` +
`docs/claude/file-care.md`) whose violation has historically caused regressions:
version-pin dual/triple-edits drifting apart, shell scripts acquiring CRLF or
losing their `100755` mode bit (breaks fresh clones: `sudo: archive.sh: command
not found`), `.ps1` files losing their UTF-8 BOM (PowerShell 5.1 fails to parse),
sentinel blocks being hand-edited, and `.chezmoiignore.tmpl` patterns silently
no-op'ing when written as source-state names instead of target paths.

Today these are protected **only by human discipline + CLAUDE.md tripwires**.
There is no CI, no git hook, and no `make lint`/`make test` target — verified
2026-06-13: no `.github/`, no `.pre-commit-config.yaml`, no `.git/hooks` beyond
samples. Notably, `shellcheck` is already installed by `makefile/packages.mk:52`
but is **never run against the repo's own scripts**.

A second, smaller problem surfaced during the audit and is bundled here because
it is exactly the class of bug the enforcement layer would have caught.

## Findings (investigation, 2026-06-13)

1. **All invariants are currently intact** — version pins agree, the LF+0755 set
   is clean, the 3 `.ps1` files keep their BOM, sentinels are matched,
   `.chezmoiignore.tmpl` uses target paths. So this work is *preventive*, not a
   cleanup.
2. **Standalone scripts are already shellcheck-clean** — `bootstrap.sh` and every
   `makefile/lib/*.sh` pass `shellcheck -x` with zero findings (shellcheck 0.10.0).
3. **Real latent bug found by shellcheck:** `scripts/manage-hosts.sh:582`
   (SC2095). In the "Test SSH connection → all" loop, `ssh ... exit` runs without
   `-n` inside `while IFS= read -r line; do … done <<< "$hosts"`, so `ssh`
   swallows the loop's stdin here-string and the loop exits after host #1 — only
   the first host is ever tested. The PowerShell twin (`manage-hosts.ps1:562`)
   uses a real `foreach` and works correctly, so this is silent behavioral
   parity drift. Fix: `ssh -n`.
4. **`make` requires `MODE`** — `makefile/Makefile:26` `include`s `scope.mk`
   unconditionally, and `scope.mk` errors at parse time if `MODE` is unset. So
   *every* make invocation (including `doctor`/`list`/`check-updates`) needs
   `MODE`. The enforcement entry point must therefore be a standalone script so
   CI and the git hook stay scope-independent.

## Decision (user-approved)

Build a single orchestrator script (`scripts/check-invariants.sh`) that performs
every mechanical check, and call it from three thin surfaces: `make lint`, a git
pre-commit hook, and a GitHub Actions job. Also fix the `ssh -n` bug.

Rejected alternatives:
- *Checks inline in the Makefile* — shell-in-recipe can't be reused by the hook
  or CI without duplication; that duplication becomes the very parity-drift
  problem we're eliminating.
- *Adopt a framework (`pre-commit`/`lefthook`)* — adds a Python/Go dependency +
  config DSL, clashing with the repo's self-contained, admin-free,
  vendored-everything ethos.

## Design

### Part A — bug fix: `scripts/manage-hosts.sh`

- Line 582: `ssh` → `ssh -n` in the test-all-hosts loop. No other change; the
  `.ps1` counterpart is already correct.
- During implementation, re-run shellcheck and fix any other **warning**-level
  finding in the same file (SC2034 `cur_name` unused, SC2029 are info-level —
  leave unless trivially correct to silence).
- No README change (behavior is already documented as "test all"); add a
  `CLAUDE_CHANGELOG.md` row.

### Part B — `scripts/check-invariants.sh` (the orchestrator)

- LF-only, mode `0755`, `set -euo pipefail`, BOM-free. Runs from repo root
  (resolves its own dir, `cd`s to repo root). Self-hosting: it is itself a member
  of the LF+0755 set it checks.
- Structure: file/pin lists declared once in arrays at the top; one function per
  check; a runner that executes all, prints `✓ <check>` / `✗ <check>: <hint>`,
  and exits non-zero if any failed. A `--list` or summary line reports counts.
- Checks:
  1. **version-pins**
     - `CCSTATUSLINE_VERSION` (`versions.mk`) == `ccstatusline@<v>`
       (`private_settings.json.tmpl`)
     - `JETBRAINSMONO_NERD_VERSION` (`versions.mk`) == case branch
       (`lib/font.sh`) == `$Version` (`install-nerd-fonts.ps1`)
     - `HELIX_VERSION` (`versions.mk`) == Helix pin (`bootstrap.ps1`
       `$PortableTools`)
     - `HELIX_RUNTIME_DEST` (`scope.mk`, `/usr/local/lib/helix`) consistent with
       the `HELIX_RUNTIME=".../helix/runtime"` literal in both `dot_zshrc.tmpl`
       and `dot_bashrc.tmpl`
  2. **line-endings + git mode** — for the LF+0755 set (`makefile/lib/*.sh`,
     `scripts/update-hosts.sh`, `scripts/manage-hosts.sh`,
     `scripts/setup-ccstatusline.sh`, `scripts/check-invariants.sh`,
     `.githooks/pre-commit`, `chezmoi/dot_local/bin/executable_batpipe`):
     assert no CRLF and `git ls-files --stage` shows `100755`.
  3. **BOM** — `scripts/manage-hosts.ps1`, `bootstrap.ps1`,
     `scripts/install-nerd-fonts.ps1` start with bytes `EF BB BF`.
  4. **sentinels** — matched `# CCSTATUSLINE:START`/`END` in
     `chezmoi/.chezmoiignore.tmpl`; matched `-- HOSTS:START`/`END` in
     `chezmoi/dot_config/wezterm/wezterm.lua` (count of START == count of END == 1).
  5. **chezmoiignore target-paths** — no active (non-comment) ignore line begins
     with `dot_`, `private_dot_`, or ends in `.tmpl` (the silent no-op trap).
  6. **shellcheck** — `shellcheck -x` over the pure-shell set (`bootstrap.sh`,
     `makefile/lib/*.sh`, `scripts/*.sh`; excludes `.tmpl` because chezmoi Go
     templates aren't valid shell). Fail on **warning and above**; do not gate on
     info/style. If `shellcheck` is absent: print a notice and skip locally
     (return success), but CI installs it so the gate is real there.

### Part C — `make lint`

- `make` runs with CWD = `makefile/` (`LIB := $(CURDIR)/lib`), so the repo root
  is `$(CURDIR)/..`. Define `REPO_ROOT := $(abspath $(CURDIR)/..)` and make the
  `.PHONY: lint` recipe `@$(REPO_ROOT)/scripts/check-invariants.sh`. Follows the
  existing MODE convention — invoked `make lint MODE=prod`, same as `doctor`/
  `list` (the lint target uses no scope vars, but `scope.mk`'s unconditional
  parse-time `MODE` requirement applies to every make invocation). CI and the
  hook bypass make (call the script directly) so they need no MODE.

### Part D — `.githooks/pre-commit` + `make install-hooks`

- `.githooks/pre-commit`: LF-only, `0755`, BOM-free. `cd`s to repo root, runs
  `scripts/check-invariants.sh`. On failure: non-zero exit blocks the commit,
  prints the failed check(s) and notes the `git commit --no-verify` escape hatch.
  (Also a member of the LF+0755 set — add it to the check list.)
- `make install-hooks`: `.PHONY`; `git config core.hooksPath .githooks`. Prints a
  confirmation. Idempotent.

### Part E — `.github/workflows/lint.yml`

- Triggers: `push` and `pull_request`. Runner: `ubuntu-latest`.
- Steps: `actions/checkout`, install shellcheck
  (`sudo apt-get update && sudo apt-get install -y shellcheck`), then
  `bash scripts/check-invariants.sh`.
- This is the backstop for anyone who didn't run `make install-hooks`.

### Part F — docs

- `README.html`: add `make lint` + `make install-hooks` to the daily/maintenance
  surface and a short "Enforcement / CI" note. Update `docs/README/README.css` /
  `README.js` only if a new section structure needs it.
- `CLAUDE_CHANGELOG.md`: append a row (per the repo's user-facing-change rule).
- `CLAUDE.md`: one line pointing future sessions at `scripts/check-invariants.sh`
  as the mechanical counterpart to the tripwire list (and `make lint` /
  `make install-hooks`).

## Footprint

- **New files:** `scripts/check-invariants.sh`, `.githooks/pre-commit`,
  `.github/workflows/lint.yml`.
- **Edited:** `makefile/Makefile` (+`lint`, +`install-hooks`),
  `scripts/manage-hosts.sh` (1 char), `README.html`, `CLAUDE_CHANGELOG.md`,
  `CLAUDE.md`.
- **No new runtime dependencies** — shellcheck is already in `packages.mk`.

## Out of scope (YAGNI)

- A full `tests/` harness for manage-hosts parsing / scope logic / chezmoi
  template rendering (valuable, but a separate effort).
- Extending `lib/doctor.sh` to surface invariants (the user chose `make lint` as
  the home; doctor stays a runtime-health check). Can be revisited later.
- Touching `scope.mk` to exempt read-only goals from the `MODE` requirement
  (would alter a load-bearing invariant for marginal convenience).

## Verification

- `bash scripts/check-invariants.sh` exits 0 on the current clean tree, printing
  a ✓ for every check.
- Deliberately break one invariant (e.g. bump `CCSTATUSLINE_VERSION` in
  `versions.mk` only) → script exits non-zero, names that check; revert.
- `make lint MODE=prod` runs the script.
- `make install-hooks` then a commit that introduces a CRLF file is blocked;
  `--no-verify` overrides.
- `scripts/check-invariants.sh` and `.githooks/pre-commit` are themselves
  LF+0755 (the script confirms its own membership).
