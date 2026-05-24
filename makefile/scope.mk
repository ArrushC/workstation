# scope.mk — resolve provisioning scope from MODE=dev|prod.
#
# Replaces ansible/group_vars/{dev,prod}_machine.yml + the fact-derivation
# in roles/linux-base/tasks/main.yml. One source of truth, computed in Make.
#
# Used by every other .mk file under this directory (packages.mk, shell.mk,
# tools.mk, etc.) — they reference $(DEST), $(SUDO), $(HAS_SUDO),
# $(INSTALL_PACKAGES), $(HELIX_RUNTIME_DEST) without ever asking what mode
# we're in.
#
# Errors at parse time if MODE is missing — there is deliberately no
# default, because the two scopes are too load-bearing to silently
# fall through to one.

ifeq ($(MODE),dev)
  # dev_machine — hosts you own, sudo available, system-wide install
  DEST               := /usr/local/bin
  HELIX_RUNTIME_DEST := /usr/local/lib/helix
  HAS_SUDO           := true
  INSTALL_PACKAGES   := true
  SUDO               := sudo
else ifeq ($(MODE),prod)
  # prod_machine — hosts you don't fully own, no sudo, per-user install
  DEST               := $(HOME)/.local/bin
  HELIX_RUNTIME_DEST := $(HOME)/.config/helix
  HAS_SUDO           := false
  INSTALL_PACKAGES   := false
  SUDO               :=
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
