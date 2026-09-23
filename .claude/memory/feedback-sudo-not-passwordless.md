---
name: feedback-sudo-not-passwordless
description: "On this dev host, sudo prompts for a password — Claude can't run sudo-requiring provisioning (./bootstrap.sh --dev, host-state mise bootstrap phases) non-interactively. Hand them to the user via the `!` prefix."
metadata:
  node_type: memory
  type: feedback
  originSessionId: fc4d8a44-599f-450d-923c-6d8d1e188620
---

In a Claude Code session on this dev host (AlmaLinux 9 under WSL2), `sudo` is NOT passwordless — `sudo -n true` fails. So any provisioning step that needs root can't be run by me non-interactively: `sudo` blocks on a password prompt and hangs the command.

**Why:** Established 2026-06-20 while deploying the C/C++ toolbelt, back when the Make recipes shelled out to `sudo dnf …` / `sudo install …`. This is also why two CRB bugs ([#24] then [#25]) slipped past my pre-merge checks — I could only lint + dry-run, never exercise the live, sudo-gated EPEL/CRB path. The same holds after the Make→mise migration: mise elevates itself for the host-state phases (`[bootstrap.packages]` dnf, `[bootstrap.files]` under `/etc`, `tasks/migrate-legacy`'s first-run sweep), and those prompt for the password.

**How to apply:**
- Before attempting a sudo-requiring command, assume it needs the user — don't run it and risk a hang. Quick probe if unsure: `sudo -n true`.
- Hand sudo-gated steps to the user as a `!`-prefixed line so they run interactively and the output lands in the conversation, e.g. `! ./bootstrap.sh --dev` or `! mise bootstrap --only packages,files --yes`. (The `!` prefix is this session's mechanism for user-run interactive commands.)
- Non-sudo work I CAN still do directly: `MISE_ENV=<set> mise bootstrap plan --json`, `mise bootstrap status --missing`, `mise run health`, `mise run lint`, `mise tasks validate`, the sandbox `mise install` recipe in `docs/claude/verification.md`, and unit-testing the non-sudo portions of a task in isolation. (Applying dotfiles to the real `$HOME` needs no sudo but is barred for a different reason — see [[project-mise-everything]]'s hard limits.)
- Verification caveat: a change touching a sudo-only path (e.g. a `[bootstrap.packages]` table or the EPEL/CRB `pre-packages` hook) is only plan/dry-run-verified by me — call out that residual risk and either ask the user to run the live path, or extract and runtime-test the non-sudo logic (as I did for the os-release distro classifier in [#25]). Same spirit as [[project-verify-tool-bumps-at-runtime]].
