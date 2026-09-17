# scope.mk — resolve provisioning scope from MODE=dev|prod.
#
# Replaces ansible/group_vars/{dev,prod}_machine.yml + the fact-derivation
# in roles/linux-base/tasks/main.yml. One source of truth, computed in Make.
#
# Used by every other .mk file under this directory (packages.mk, shell.mk,
# etc.) — they reference $(DEST), $(SUDO), $(HAS_SUDO), $(INSTALL_PACKAGES)
# without ever asking what mode we're in. DEST is now only where legacy
# (pre-mise) binaries are swept from (tasks/migrate-legacy) and where
# chezmoi's `-b` used to point — the tool layer itself is mise, not this
# Makefile.
#
# Errors at parse time if MODE is missing — there is deliberately no
# default, because the two scopes are too load-bearing to silently
# fall through to one.

ifeq ($(MODE),dev)
  DEST             := /usr/local/bin
  HAS_SUDO         := true
  INSTALL_PACKAGES := true
  SUDO             := sudo --preserve-env=DEST
else ifeq ($(MODE),prod)
  DEST             := $(HOME)/.local/bin
  HAS_SUDO         := false
  INSTALL_PACKAGES := false
  SUDO             :=
else
  $(error MODE not set. Use 'make dev' / 'make prod', or set MODE=dev|prod explicitly. For sandbox builds: 'make all MODE=prod DEST=/tmp/test STAMP=/tmp/stamps')
endif

# Sanity check — system scope without sudo is unrecoverable nonsense. This
# mirrors the fail task at the top of the old roles/linux-base/tasks/main.yml.
ifeq ($(MODE),dev)
  ifneq ($(HAS_SUDO),true)
    $(error MODE=dev requires HAS_SUDO=true — system scope without sudo is impossible)
  endif
endif

# WSL detection — true if running inside a WSL distro (any version). Centralised
# here so targets that should no-op on WSL (e.g. nerd-fonts, where the Windows
# host already supplies the font to the terminal) share one probe instead of
# duplicating the detection. Mirrors bootstrap.sh's is_wsl() helper.
IS_WSL := $(shell { [ -n "$$WSL_DISTRO_NAME" ] || grep -qi microsoft /proc/version 2>/dev/null; } && echo true || echo false)
export IS_WSL

# MISE_ENV — which config.<env>.toml files mise loads (scripts/lib/mise-env.sh is
# the single source; bootstrap.sh exports the same value). An explicit MISE_ENV
# in the environment wins (sandbox runs). ifndef + := (not `?=`, which is
# recursively-expanded like `=`) so the $(shell …) forks at most once per
# make invocation, not on every later expansion of $(MISE_ENV).
ifndef MISE_ENV
MISE_ENV := $(shell $(abspath $(CURDIR)/..)/scripts/lib/mise-env.sh $(MODE))
endif
export MISE_ENV
