# dotfiles.mk — run `chezmoi update` if the chezmoi config exists.
#
# Replaces ansible/roles/linux-base/tasks/dotfiles.yml. The first-run
# `chezmoi init --apply` (which prompts for name/email via
# `promptStringOnce`) is NOT done here — that needs a TTY and is
# handled by bootstrap.sh's ensure_chezmoi_initialized step, which
# runs after `make provision` returns.
#
# This target is therefore best-thought-of as "pick up dotfile changes
# from upstream on a host that's already been initialized." On a
# truly-fresh host the config doesn't exist yet; we print a note and
# return clean so bootstrap.sh can take it from here.

CHEZMOI_BIN    := $(DEST)/chezmoi
CHEZMOI_SOURCE := $(HOME)/.local/share/chezmoi
CHEZMOI_CONFIG := $(HOME)/.config/chezmoi/chezmoi.toml

.PHONY: dotfiles
dotfiles:
	@if [ -f "$(CHEZMOI_CONFIG)" ]; then \
	  printf '==> chezmoi update\n'; \
	  "$(CHEZMOI_BIN)" update --source "$(CHEZMOI_SOURCE)"; \
	else \
	  printf '  no chezmoi config yet — bootstrap.sh will run `chezmoi init --apply` after this\n'; \
	fi
