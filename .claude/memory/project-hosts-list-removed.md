---
name: project-hosts-list-removed
description: The hosts list (hosts.conf) and all tooling built on it were removed 2026-09-24 and scrubbed from git history — it was the main reason the repo was private. Do not reintroduce a tracked host inventory.
metadata:
  type: project
---

On 2026-09-24 the user removed the hosts list entirely: `hosts.conf`, `scripts/manage-hosts.{sh,ps1}`, `scripts/update-hosts.sh`, `tasks/update-hosts`, their zsh/bash/Nushell completions, `bootstrap.sh`'s self-registration + hosts.conf commit/push, `bootstrap.ps1`'s Windows Terminal SSH-profile fragment and per-host Warp tabs, and the `hosts` shell command. There is no fleet rollout any more: each host updates itself with `wsu` (or `./bootstrap.sh --<mode>`). `--dev`/`--prod` and `vars.group` (dev_machine/prod_machine) stay — they pick `MISE_ENV`, not an inventory group.

**Why:** "There's not much point in keeping a list and it's primarily the reason why the github repo is private." The user wants the repo to be publishable. History was rewritten with `git filter-repo` the same day: `hosts.conf`, the pre-mise `ansible/inventory/hosts.ini` and the old WezTerm `hosts.lua` were dropped from every commit, and the 11 real host IPs were replaced with `***REMOVED-IP***` in all other files and in commit messages. GitHub's read-only PR refs (`refs/pull/*`) can still reach pre-rewrite commits until GitHub Support purges them.

**How to apply:**
- Never add a tracked host inventory, IP address, or per-host launcher back to this repo. Per-host SSH details belong in the untracked `~/.ssh/config.local`.
- The user chose to LEAVE other work-identifying strings as they are (gitconfig's repo.atcoretec.com credential block, Zed remote-SSH projects, a VS Code Atcom regex, hostnames in historical docs/changelog) — don't scrub them unprompted, but flag them if the user asks what still blocks going public.
- Before any history rewrite, rehearse on a fresh `git clone --single-branch` in the scratchpad (`uvx git-filter-repo`), verify with `git rev-list --all | xargs git grep` and `git log --all --format=%B`, and remember commit messages need `--replace-message` too — 7 of them carried IPs.
- Related: [[project-mise-everything]], [[feedback-use-pr-review-workflow]].
