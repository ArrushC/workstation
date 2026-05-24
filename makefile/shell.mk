# shell.mk — PATH wiring + bash-completion sourcing.
#
# Replaces ansible/roles/linux-base/tasks/shell.yml. Two paths:
#   - HAS_SUDO=true:  write /etc/profile.d/local-bin.sh (system-wide)
#   - HAS_SUDO=false: append the same export to ~/.bashrc (per-user)
#
# bash-completion is sourced from ~/.bashrc unconditionally (it never
# needs sudo — the system file at /etc/bash_completion is sourced from
# the user's rc).

PROFILE_D_FILE := /etc/profile.d/local-bin.sh
BASHRC         := $(HOME)/.bashrc
PATH_LINE      := export PATH="$$HOME/.local/bin:$$PATH"
BC_LINE        := [[ -f /etc/bash_completion ]] && source /etc/bash_completion

.PHONY: shell shell-path shell-bashcompletion

shell: shell-path shell-bashcompletion

ifeq ($(HAS_SUDO),true)
shell-path:
	@printf '==> PATH via %s\n' "$(PROFILE_D_FILE)"
	@printf '%s\n' '$(PATH_LINE)' | $(SUDO) tee $(PROFILE_D_FILE) >/dev/null
	@$(SUDO) chmod 0644 $(PROFILE_D_FILE)
else
# No-sudo path: append to ~/.bashrc if not already there. grep -qxF matches
# exact whole lines, so a partial substring elsewhere in the file won't
# fool the duplicate-check.
shell-path:
	@printf '==> PATH via %s (no sudo)\n' "$(BASHRC)"
	@if ! grep -qxF '$(PATH_LINE)' $(BASHRC) 2>/dev/null; then \
	  printf '%s\n' '$(PATH_LINE)' >> $(BASHRC); \
	fi
endif

# bash-completion is always sourced from ~/.bashrc regardless of scope.
# Idempotent: same grep -qxF guard as above.
shell-bashcompletion:
	@if ! grep -qxF '$(BC_LINE)' $(BASHRC) 2>/dev/null; then \
	  printf '==> bash-completion source line added to %s\n' "$(BASHRC)"; \
	  printf '%s\n' '$(BC_LINE)' >> $(BASHRC); \
	fi
