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

**Asset ambiguity has now recurred (2026-08-31, omp 16.4.4 → 18.0.11):** omp 18.x
added `omp-linux-musl-*` assets 16.x never published, leaving two x64 candidates
and the same non-interactive eget abort ("2 candidates found for asset chain").
Treat this as the DEFAULT failure mode of any EGET_TOOL major bump, not a
one-off — run the real `make <tool>` for every eget tool crossing a major, and
when adding an anti-match prefer the build already installed (omp kept glibc via
`--asset '^musl'`) so a bump doesn't smuggle in a behaviour change.

**Why:** upstream shared-lib deps and release-asset churn don't show up in
changelogs — only running the binary / running the real install reveals them.

**How to apply (post Make→mise, 2026-09):** the file names above (`versions.mk`,
`packages.mk`, `tools.mk`, eget) are history — pins now live in
`config.linux.toml`/`config.dev.toml`, dnf packages in `config.host.toml`, and a
`github:` tool's asset choice is an explicit `asset_pattern`. The lesson is unchanged.
- Sandbox install (sudo-free, live tools untouched): the `MISE_CONFIG_DIR=$PWD MISE_DATA_DIR=/tmp/mise-sandbox … mise install && … tasks/verify-tools` recipe in `docs/claude/verification.md` (set `GITHUB_TOKEN` for the API rate limit). `tasks/verify-tools` checks ELF arch, loader and glibc floor via `ldd`, so a libatomic-class missing shared lib now fails the gate — but still EXECUTE the bumped binary (`--version`), since ldd can't see everything.
- Asset ambiguity on a `github:`-backend major bump: run the real sandbox `mise install` for that tool; when pinning an `asset_pattern`, prefer the build already installed (glibc vs musl) so a bump doesn't smuggle in a behaviour change.
- config-driven tools (fzf, zellij): run the bumped binary against the repo's `dotfiles/` config (fzf with `$FZF_DEFAULT_OPTS`; the zellij headless probe in `docs/claude/verification.md`).
