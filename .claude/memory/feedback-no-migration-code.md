---
name: feedback-no-migration-code
description: The user doesn't want migration-specific logic (one-time cleanups, stale-state tidy-ups, compatibility shims for old layouts) living in the repo; hosts are migrated by hand or by a fresh bootstrap.
metadata:
  type: feedback
---

Don't add migration code: no "one-time cleanup, remove once every host has run it" blocks, no tidy-up of old config lines, no handling of what an older version left behind. When a change leaves stale state on existing hosts, either make the stale state inert (nothing reads it) or tell the user the one-off command to run on each host, and keep the repo describing only the current setup.

**Why:** After the single-mode PR (#30) the user said "I hope there's no migration specific logic that exists in the repository". Hosts are few and set up deliberately, and the user migrates each one themselves, so permanent code for transitions is just maintenance burden. On 2026-10-07 the existing ones were removed: the stale `mode` line cleanup, the old exported-`MISE_ENV` cleanup (environment.d, systemd user manager, Windows User var), health's "old exporters" row, `Invoke-LegacyToolCleanup` (pre-mise portable installs on Windows), the zjstatus.wasm copy removal in `tasks/bootstrap`, and setup-ccstatusline's symlink materialisation.

**How to apply:**
- Before writing a cleanup step, ask whether the leftover is harmful. If it's inert, leave it and mention it; if it breaks something, give the user a one-off command for their hosts instead of committing the cleanup.
- That includes lint and tests: a check should state the current layout (e.g. `check_layout`), not list the removed files or old names. A self-updating script re-execs its pulled copy (`*_PULLED` guards) instead of carrying compatibility shims for its own previous version.
- State reconciliation is not migration and stays: the first-apply `dotfiles-first-apply-done` marker (renamed from `dotfiles-migrated` in 2026-10; the old file on existing hosts is inert) (fresh hosts need `--force-dotfiles` once), the SSH launcher/WT fragment sync that drops entries for removed hosts, nerd-font re-registration with full paths, `normalize_lock_sidecars`.
- Related: [[project-bootstrap-single-mode]].
