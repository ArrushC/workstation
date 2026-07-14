---
name: feedback-app-list-means-manual-list
description: '"Add X to the application list (Windows)" = one row in docs/windows/application_list.md, NOT a bootstrap.ps1 installer-class entry'
metadata:
  type: feedback
---

"Add \<app\> to the application list for Windows" means appending a row to `docs/windows/application_list.md` — the manual-install reference list — and nothing else.

**Why:** On 2026-07-14 the request "Add HTTP Toolkit to the application list" was over-scoped into a full fifth `$InstallerTools` entry in `bootstrap.ps1` plus README/CLAUDE/changelog edits; the user had it all reverted down to the one-line list addition. Promoting an app to auto-install (installer class, `$PortableTools`, elevated class) is a separate, explicit ask — apps only *leave* the manual list when they become auto-installed.

**How to apply:** Edit only `docs/windows/application_list.md` (a `- <App>` row; slashed alternatives only if the user names them). No README.html or CLAUDE_CHANGELOG.md updates — the file is a personal reference list, not README-operable surface.
