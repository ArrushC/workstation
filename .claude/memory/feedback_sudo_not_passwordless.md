---
name: feedback-sudo-not-passwordless
description: "On this dev host, sudo prompts for a password — Claude can't run sudo-requiring make targets non-interactively. Hand them to the user via the `!` prefix."
metadata:
  node_type: memory
  type: feedback
  originSessionId: fc4d8a44-599f-450d-923c-6d8d1e188620
---

In a Claude Code session on this dev host (AlmaLinux 9 under WSL2), `sudo` is NOT passwordless — `sudo -n true` fails. So any provisioning step that needs root can't be run by me non-interactively: `sudo` blocks on a password prompt and hangs the command.

**Why:** Established 2026-06-20 in the chezmoi repo while deploying the C/C++ toolbelt. `scope.mk` sets `SUDO := sudo --preserve-env=DEST,HELIX_RUNTIME_DEST` on `MODE=dev`, so `make packages`, `make dev`/`provision`, and the `$(SUDO)`-wrapped bespoke targets (`nnd`/`pwndbg`/`vcpkg`/`docker-engine`/`node-runtime`/`*-service`) all shell out to `sudo dnf …` / `sudo install …`. With no passwordless sudo, those hang waiting on stdin I can't provide. This is also why two CRB bugs ([#24] then [#25]) slipped past my pre-merge checks — I could only `make lint` + `make -n` (dry-run), never exercise the live, sudo-gated `packages-epel` path.

**How to apply:**
- Before attempting a sudo-requiring command, assume it needs the user — don't run it and risk a hang. Quick probe if unsure: `sudo -n true`.
- Hand sudo-gated steps to the user as a `!`-prefixed line so they run interactively and the output lands in the conversation, e.g. `! make -C makefile dev` or `! make -C makefile nnd pwndbg vcpkg MODE=dev`. (The `!` prefix is this session's mechanism for user-run interactive commands.)
- Non-sudo work I CAN still do directly: `chezmoi apply [--force]` (writes `$HOME`), `MODE=prod` installs (land in `~/.local/bin`, `SUDO` empty), `make lint` / `make -n <target>` / `make doctor` (read-only), and unit-testing the non-sudo portions of a recipe in isolation.
- Verification caveat: a change touching a sudo-only code path (e.g. `packages.mk` dnf logic) is only lint/dry-run-verified by me — call out that residual risk and either ask the user to run the live path, or extract and runtime-test the non-sudo logic (as I did for the os-release distro classifier in [#25]). Same spirit as [[project-verify-tool-bumps-at-runtime]].
