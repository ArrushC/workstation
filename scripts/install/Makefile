# scripts/install/Makefile — parallel tool installer for workstation.
#
# Replaces the per-tool blocks in ansible/roles/linux-base/tasks/tools.yml.
# Ansible's tools.yml is now a thin wrapper that calls `make -j8 all` here.
#
# Tool definitions live in tools.mk. Versions live in versions.mk. The
# library scripts under lib/ implement five install shapes (see tools.mk
# for which one to pick when adding a tool).
#
# Common usage:
#   make all                   install everything (use -j8 for parallelism)
#   make <tool>                install just one tool, e.g. make gitui
#   make clean-<tool>          remove stamp + binary for one tool
#   make list                  list managed tools
#   make help                  this help text
#
# Override the install location (Ansible does this automatically):
#   make all DEST=/usr/local/bin              system-wide install
#   make all DEST=$HOME/.local/bin            user-wide install (default)
#   make all HELIX_RUNTIME_DEST=/usr/local/lib/helix
#
# Idempotency: each tool has a stamp file at $(STAMP)/<tool>-<version>.done.
# `make` skips the install if the stamp exists. Bumping a version in
# versions.mk changes the stamp filename, which invalidates the old one and
# triggers reinstall on the next `make all`. To force a reinstall without a
# version bump: `make clean-<tool>` (or `make clean` for everything).

include versions.mk

DEST               ?= $(HOME)/.local/bin
HELIX_RUNTIME_DEST ?= $(HOME)/.config/helix
STAMP              ?= $(HOME)/.local/share/workstation-install
LIB                := $(CURDIR)/lib

export DEST HELIX_RUNTIME_DEST LIB STAMP

# -----------------------------------------------------------------------------
# TOOL macro — used by tools.mk to register one tool.
#
# Usage:
#   $(eval $(call TOOL,<name>,<version>,<install_command>))
#
# Emits:
#   - phony <name> target that depends on the stamp file
#   - the stamp rule itself (runs the install command, then touches the stamp)
#   - clean-<name> phony target (wipes stamp + installed binary)
#   - appends <name> to $(TOOLS)
#
# Note on $$: inside `define`, the macro body is expanded twice — once by
# $(eval) and once when the rule fires. We escape $ as $$ for variables
# that need to be resolved at rule-fire time (STAMP, DEST) rather than at
# eval time. Variables that should bake in NOW (the per-call arguments
# $(1)/$(2)/$(3)) use a single $.
# -----------------------------------------------------------------------------
define TOOL
TOOLS += $(1)
.PHONY: $(1) clean-$(1)
$(1): $$(STAMP)/$(1)-$(2).done
$$(STAMP)/$(1)-$(2).done:
	@printf '==> %s %s\n' "$(1)" "$(2)"
	@$(3)
	@mkdir -p $$(@D) && touch $$@
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done $$(DEST)/$(1)
endef

TOOLS :=
include tools.mk

# -----------------------------------------------------------------------------
# Top-level phony targets
# -----------------------------------------------------------------------------
.PHONY: all list clean help

all: $(TOOLS)

list:
	@printf '%s\n' $(TOOLS) | sort

clean:
	@rm -rf "$(STAMP)"

help:
	@echo "Targets:"
	@echo "  all              install every managed tool (use -j8 for parallelism)"
	@echo "  list             list managed tool names"
	@echo "  <tool>           install just one tool, e.g. make gitui"
	@echo "  clean-<tool>     remove the stamp + binary for one tool"
	@echo "  clean            remove all stamp files (forces full reinstall next run)"
	@echo ""
	@echo "Overrides:"
	@echo "  DEST=<dir>                 destination for binaries (default: ~/.local/bin)"
	@echo "  HELIX_RUNTIME_DEST=<dir>   parent dir for helix runtime/ (default: ~/.config/helix)"
	@echo ""
	@echo "Files:"
	@echo "  versions.mk    tool versions (single source of truth)"
	@echo "  tools.mk       per-tool install rules"
	@echo "  lib/*.sh       install helper scripts"
