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
#
# chezmoi is a mise tool (config.linux.toml) — CHEZMOI_BIN is the bare
# `chezmoi` shim name, not a $(DEST) path (tasks/migrate-legacy deletes
# the old $(DEST)/chezmoi, so a $(DEST) reference here would silently
# break post-sweep). sshd's PATH carries neither the mise shims dir nor
# ~/.local/bin, so both invocations below are PATH-prefixed. CHEZMOI_SOURCE
# is the repo root (this checkout IS the chezmoi source since the 2026-09
# relocation to ~/.config/mise) — kept explicit on both `init --no-tty` and
# `update` because on the first migrating run chezmoi.toml has no sourceDir
# yet when this phase runs.

CHEZMOI_BIN    := chezmoi
CHEZMOI_SOURCE := $(REPO_ROOT)
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
	  PATH="$(MISE_SHIMS):$(HOME)/.local/bin:$$PATH" "$(CHEZMOI_BIN)" init --no-tty --source "$(CHEZMOI_SOURCE)" >/dev/null 2>&1 || true; \
	  printf '==> chezmoi update\n'; \
	  printf '    if prompted ("<file> has changed since chezmoi last wrote it?"), pick:\n'; \
	  printf '      d=diff (delta)   m=merge (vimdiff)   o=overwrite this   a=overwrite all\n'; \
	  printf '      s=skip (keep your version)   q=quit (abort update)\n'; \
	  PATH="$(MISE_SHIMS):$(HOME)/.local/bin:$$PATH" "$(CHEZMOI_BIN)" update --source "$(CHEZMOI_SOURCE)"; \
	fi
