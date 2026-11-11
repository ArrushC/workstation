---
name: project-dev10-graft-hand-installed
description: On atc-cache-dev10 graft runs from a hand-installed 0.18.0 in ~/.local/bin; mise's 0.21.1 install there is an empty leftover that must stay. The user uses graft there and chose to keep both.
metadata:
  type: project
---

On atc-cache-dev10 (RHEL 8.10), `graft` resolves through mise's shim to `~/.local/bin/graft`, a
hand-installed 0.18.0 (the repo never installs there). mise's
`installs/npm-nanonets-graft/0.21.1~aube~0bb1c890c178522e` holds only `node_modules`, no `bin`
(dated 2026-10-12: the lazy first-use install failed on EL8, whose libstdc++ lacks
GLIBCXX_3.4.29). mise counts it installed; `mise which graft` errors and the shim falls through
to the 0.18.0 copy. Checked 2026-11-03; see [[project-directory-accounts-sssd]] for the host.

**Why:** the user uses graft there and decided on 2026-11-03 to keep it as it is. Removing the
empty 0.21.1 directory would make every `graft` run retry the failing EL8 install first.
**How to apply:** an executables check (`mise bin-paths`) flags `npm:@nanonets/graft` there:
expected, not drift. Don't propose `mise uninstall` or deleting `~/.local/bin/graft` there. The
repo's telemetry opt-out (graft's postinstall) never ran for that copy.
