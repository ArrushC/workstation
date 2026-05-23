# scripts/install/Makefile — parallel tool installer for workstation.
#
# Replaces the per-tool blocks that used to live in
# ansible/roles/linux-base/tasks/tools.yml. Ansible's tools.yml is now a
# thin wrapper that invokes this Makefile (one task per top-level target).
#
# Tool definitions live in tools.mk. Versions live in versions.mk. The
# library scripts under lib/ implement five install shapes (see tools.mk
# for which helper to pick when adding a tool).
#
# Three top-level targets, each invoked separately by Ansible:
#   all          — scope-aware tools ($(SCOPE_TOOLS)). Honors DEST/become
#                  per ansible/group_vars/<group>.yml. Bulk of the tools.
#   user-tools   — pip-installed Python tools ($(USER_TOOLS)). Always lands
#                  in the dev user's site-packages; never run under sudo.
#   claude-cli   — the Claude Code CLI. Ansible only runs this target when
#                  tool_scope == 'system' (dev_machine only), without
#                  become.
#
# Common usage:
#   make all                           install scope-aware tools (use -j8)
#   make user-tools                    install pip tools
#   make claude-cli                    install claude (dev_machine only)
#   make <tool>                        install just one tool, e.g. make gitui
#   make clean-<tool>                  remove stamp + binary for one tool
#   make list                          list managed tools (all targets)
#   make help                          this help text
#
# Override the install location (Ansible does this automatically):
#   make all DEST=/usr/local/bin              system-wide install
#   make all DEST=$HOME/.local/bin            user-wide install (default)
#   make all HELIX_RUNTIME_DEST=/usr/local/lib/helix
#
# Idempotency: each tool has a stamp file at $(STAMP)/<tool>-<version>.done.
# `make` skips the install if the stamp exists. Bumping a version in
# versions.mk changes the stamp filename, invalidating the old one and
# triggering reinstall on the next `make`. To force reinstall without a
# version bump: `make clean-<tool>` (or `make clean` for everything).

include versions.mk

DEST               ?= $(HOME)/.local/bin
HELIX_RUNTIME_DEST ?= $(HOME)/.config/helix
STAMP              ?= $(HOME)/.local/share/workstation-install
LIB                := $(CURDIR)/lib

export DEST HELIX_RUNTIME_DEST LIB STAMP

# -----------------------------------------------------------------------------
# Macros — used by tools.mk to register one tool per call.
#
#   $(eval $(call TOOL,<name>,<version>,<install_cmd>))
#   $(eval $(call USER_TOOL,<name>,<version>,<install_cmd>))
#
# Both emit identical rule plumbing (phony target, stamp rule, clean-<name>);
# they differ only in which list ($(SCOPE_TOOLS) vs $(USER_TOOLS)) the tool
# joins, which controls whether `make all` or `make user-tools` includes it.
#
# Note on $$: inside `define`, the body is expanded twice — once at $(eval)
# time and once when the rule fires. We escape $ as $$ for variables that
# need to resolve at rule-fire time ($(STAMP), $(DEST)); per-call arguments
# $(1)/$(2)/$(3) use single $ to bake in NOW.
# -----------------------------------------------------------------------------
define _RULE_BODY
$(1): $$(STAMP)/$(1)-$(2).done
$$(STAMP)/$(1)-$(2).done:
	@printf '==> %s %s\n' "$(1)" "$(2)"
	@$(3)
	@mkdir -p $$(@D) && touch $$@
.PHONY: $(1) clean-$(1)
endef

define TOOL
SCOPE_TOOLS += $(1)
$(call _RULE_BODY,$(1),$(2),$(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done $$(DEST)/$(1)
endef

define USER_TOOL
USER_TOOLS += $(1)
$(call _RULE_BODY,$(1),$(2),$(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
endef

SCOPE_TOOLS :=
USER_TOOLS  :=
include tools.mk

# -----------------------------------------------------------------------------
# Claude — special-cased rather than registered via a macro.
#   - Doesn't accept DEST (its installer always lands in ~/.local/bin).
#   - Has its own phony target so Ansible can choose to invoke it or not.
#     The current rule: install on dev_machine, skip on prod_machine
#     (matches the historical tool_scope=='system' gate from tools.yml).
# -----------------------------------------------------------------------------
.PHONY: claude-cli clean-claude-cli
claude-cli: $(STAMP)/claude-$(CLAUDE_VERSION).done
$(STAMP)/claude-$(CLAUDE_VERSION).done:
	@printf '==> claude %s\n' "$(CLAUDE_VERSION)"
	@$(LIB)/pipe.sh claude https://claude.ai/install.sh
	@mkdir -p $(@D) && touch $@
clean-claude-cli:
	@rm -f $(STAMP)/claude-*.done $(HOME)/.local/bin/claude

# -----------------------------------------------------------------------------
# Top-level phony targets
# -----------------------------------------------------------------------------
.PHONY: all user-tools list clean help

all: $(SCOPE_TOOLS)

user-tools: $(USER_TOOLS)

list:
	@printf 'scope-tools (%d):\n' $(words $(SCOPE_TOOLS))
	@printf '  %s\n' $(sort $(SCOPE_TOOLS))
	@printf '\nuser-tools (%d):\n' $(words $(USER_TOOLS))
	@printf '  %s\n' $(sort $(USER_TOOLS))
	@printf '\nclaude-cli (Ansible-gated, dev_machine only)\n'

clean:
	@rm -rf "$(STAMP)"

help:
	@echo "Targets:"
	@echo "  all              install every scope-aware tool (use -j8 for parallelism)"
	@echo "  user-tools       install Python (pip) tools to ~/.local"
	@echo "  claude-cli       install the Claude Code CLI (dev_machine only)"
	@echo "  <tool>           install just one tool, e.g. make gitui"
	@echo "  clean-<tool>     remove the stamp (+ binary for scope-tools) for one tool"
	@echo "  clean            wipe all stamps (forces full reinstall next run)"
	@echo "  list             list every managed tool, grouped by target"
	@echo ""
	@echo "Overrides:"
	@echo "  DEST=<dir>                 destination for binaries (default: ~/.local/bin)"
	@echo "  HELIX_RUNTIME_DEST=<dir>   parent dir for helix runtime/ (default: ~/.config/helix)"
	@echo ""
	@echo "Files:"
	@echo "  versions.mk    tool versions (single source of truth)"
	@echo "  tools.mk       per-tool install rules"
	@echo "  lib/*.sh       install helper scripts"
