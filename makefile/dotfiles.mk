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

# Re-init the config first so a .chezmoi.toml.tmpl change (e.g. a new
# [diff] / [merge] section) flows through without manual intervention.
# chezmoi's state DB caches promptStringOnce answers from the original
# init, so this doesn't re-prompt for name/email. --no-tty makes init
# fail-fast if state's somehow corrupted; we swallow that error so
# update still runs and the underlying problem surfaces there with a
# more useful message.
.PHONY: dotfiles
dotfiles:
	@if [ ! -f "$(CHEZMOI_CONFIG)" ]; then \
	  printf '  no chezmoi config yet — bootstrap.sh will run `chezmoi init --apply` after this\n'; \
	else \
	  "$(CHEZMOI_BIN)" init --no-tty >/dev/null 2>&1 || true; \
	  printf '==> chezmoi update\n'; \
	  printf '    if prompted ("<file> has changed since chezmoi last wrote it?"), pick:\n'; \
	  printf '      d=diff (delta)   m=merge (vimdiff)   o=overwrite this   a=overwrite all\n'; \
	  printf '      s=skip (keep your version)   q=quit (abort update)\n'; \
	  "$(CHEZMOI_BIN)" update --source "$(CHEZMOI_SOURCE)"; \
	fi
