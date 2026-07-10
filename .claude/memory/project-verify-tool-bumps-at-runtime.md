---
name: project-verify-tool-bumps-at-runtime
description: Version-pin bumps need runtime testing on AlmaLinux 9, not just changelog review — shared-lib deps and release-asset churn are invisible to changelogs.
metadata:
  type: project
---

When reviewing/accepting `makefile/versions.mk` bumps, changelog research is
necessary but NOT sufficient. **Sandbox-install the bumped tools and actually
execute them on AlmaLinux 9** (the dev/prod target distro) before declaring a
bump safe.

Two real blockers in the 2026-06-15 weekly bump passed source-cited changelog
review for all tools yet failed at runtime:

1. **Node 26 added a `libatomic.so.1` dependency** (new since Node 24; `ldd` on
   24 is clean). Absent on AlmaLinux 9 and not pulled by `gcc`, so `node`/`npx`
   die at startup → ccstatusline statusline breaks. The glibc analysis was
   correct (floor 2.28 ≤ 2.34) but couldn't see a *separate* shared lib. Fixed
   by adding `libatomic` to `packages.mk` core list.
2. **zellij 0.44 added a `zellij-no-web-*` release asset**, so `--asset musl`
   matched two tarballs and eget aborted non-interactively → `make dev` failed.
   The config itself was fine; only the *installer* broke. Fixed with
   `--asset '^no-web'` in `tools.mk`.

**Why:** upstream shared-lib deps and release-asset churn don't show up in
changelogs — only running the binary / running the real install reveals them.

**How to apply:**
- Sandbox install (sudo-free, live tools untouched): `cd makefile && make all MODE=prod DEST=/tmp/install-test STAMP=/tmp/install-test-stamps` with `GITHUB_TOKEN` set (eget rate limit). `scope.mk` documents this invocation.
- node-runtime is dev-only (not in `make all MODE=prod`): test it directly — `DEST=/tmp/wf-node bash makefile/lib/node.sh <ver>`, then `ldd .../bin/node | grep 'not found'` and run `node --version`.
- eget tools: run the actual `make <tool>` target — asset-ambiguity only surfaces through eget's selection.
- config-driven tools (fzf, zellij): run the bumped binary against the chezmoi config (fzf with `$FZF_DEFAULT_OPTS`; `zellij setup --check` per [[project-wsl-appendwindowspath-false]]'s sibling recipe in `docs/claude/verification.md`).
