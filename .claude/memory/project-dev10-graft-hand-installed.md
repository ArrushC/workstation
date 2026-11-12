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

**2026-11-12 update (from a report the user pasted; the host wasn't named, taken to be this one):**
on an EL8 host, `~/.local/bin/graft` was a wrapper hardcoding nvm's Node 22 path, gone after the
nvm→mise move; it was deleted there and 0.21.1 force-reinstalled with gcc-toolset-14 plus
`CXXFLAGS=-std=gnu++20` (Node 26's V8 headers need C++20; tree-sitter's binding.gyp says gnu++17).
That session also edited the graft comment in that host's live `config.linux.toml`: revert it
there before `wsu`. The repo's answer is the pin: graft 0.29.0 parses with WASM and builds
nothing (branch `graft-0.29-wasm`). Once that reaches the host, the "keep both" rule above is
moot; graft stays lazy until 0.29 has run on EL8, then it can go eager (lint's `lazy_exceptions`,
README, CLAUDE.md).
