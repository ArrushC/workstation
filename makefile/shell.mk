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

# Both branches probe the destination first and skip the write if it
# already has the right content. Saves a sudo round-trip on re-runs (the
# sudo-side branch) and an extra grep on the user-side branch — small
# wins, but they add up across many `make provision` invocations.
ifeq ($(HAS_SUDO),true)
shell-path:
	@if [ -f $(PROFILE_D_FILE) ] && grep -qxF '$(PATH_LINE)' $(PROFILE_D_FILE) 2>/dev/null; then \
	  printf '  PATH already wired via %s\n' "$(PROFILE_D_FILE)"; \
	else \
	  printf '==> PATH via %s\n' "$(PROFILE_D_FILE)"; \
	  printf '%s\n' '$(PATH_LINE)' | $(SUDO) tee $(PROFILE_D_FILE) >/dev/null; \
	  $(SUDO) chmod 0644 $(PROFILE_D_FILE); \
	fi
else
# No-sudo path: append to ~/.bashrc if not already there. grep -qxF matches
# exact whole lines, so a partial substring elsewhere in the file won't
# fool the duplicate-check.
shell-path:
	@if grep -qxF '$(PATH_LINE)' $(BASHRC) 2>/dev/null; then \
	  printf '  PATH already in %s\n' "$(BASHRC)"; \
	else \
	  printf '==> PATH via %s (no sudo)\n' "$(BASHRC)"; \
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
