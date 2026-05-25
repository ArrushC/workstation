# makefile/Makefile — single-tool provisioning for workstation hosts.
#
# Replaces the old ansible/ tree entirely. One language (Make + bash),
# one dependency graph, one set of stamps for idempotency.
#
# Entry points:
#   make dev                      provision a dev_machine (sudo, /usr/local/bin)
#   make prod                     provision a prod_machine (no sudo, ~/.local/bin)
#   make provision MODE=dev|prod  same, explicit
#   make <tool>      MODE=...     install just one tool, e.g. make gitui MODE=prod
#   make clean-<tool> MODE=...    wipe stamp (+ binary for scope tools)
#   make list        MODE=...     list every managed tool, grouped
#   make help                     this help text
#
# Composition (in include order — order matters for variable visibility):
#   scope.mk      DEST / SUDO / HAS_SUDO / INSTALL_PACKAGES from MODE
#   versions.mk   tool versions (single source of truth)
#   packages.mk   dnf packages + EPEL (replaces packages.yml)
#   shell.mk      PATH wiring (replaces shell.yml)
#   dotfiles.mk   chezmoi update (replaces dotfiles.yml)
#   tools.mk      per-tool install rules (uses TOOL / USER_TOOL macros below)
#
# Bootstrap.sh calls `make MODE=dev provision` (or MODE=prod). The
# update-hosts.sh script does the same for remote hosts over ssh.

include scope.mk
include versions.mk

STAMP ?= $(HOME)/.local/share/workstation-install
LIB   := $(CURDIR)/lib

# Export so library scripts (lib/*.sh) and any sub-makes inherit these.
export DEST HELIX_RUNTIME_DEST LIB STAMP SUDO

# -----------------------------------------------------------------------------
# Macros — used by tools.mk to register one tool per call.
#
#   $(eval $(call TOOL,<name>,<version>,<install_cmd>))       scope-aware
#   $(eval $(call USER_TOOL,<name>,<version>,<install_cmd>))  always ~/.local
#
# Difference: TOOL prefixes the install command (and the rm in clean-*) with
# $(SUDO), so dev mode writes /usr/local/bin via sudo while prod mode (SUDO
# empty) just runs as the dev user. USER_TOOL never sudos — pip/claude
# always land in the user's site, regardless of mode.
#
# Note on $$: inside `define`, the body is expanded twice — once at $(eval)
# time and once when the rule fires. We escape $ as $$ for variables that
# need to resolve at rule-fire time (STAMP, DEST). Per-call args $(1)/$(2)/$(3)
# use single $ to bake in NOW.
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
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
	@$(SUDO) rm -f $$(DEST)/$(1)
endef

define USER_TOOL
USER_TOOLS += $(1)
$(call _RULE_BODY,$(1),$(2),$(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
endef

# -----------------------------------------------------------------------------
# EGET_TOOL — register a GitHub-release single-binary install via eget.
#
#   $(eval $(call EGET_TOOL,<name>,<version>,<user/repo>[,<tag>][,<extra>]))
#
#   $(1)  name        tool name (stamp + phony target + binary at $(DEST)).
#   $(2)  version     pinned in versions.mk; baked into the stamp filename.
#   $(3)  user/repo   GitHub owner/repo path.
#   $(4)  tag         OPTIONAL explicit tag. Defaults to v$(version).
#                     Override for tools whose release tag doesn't follow
#                     vX.Y.Z (e.g. delta uses "0.19.2", gping uses
#                     "gping-vX.Y.Z").
#   $(5)  extra       OPTIONAL extra args forwarded to eget. Common cases:
#                       --asset musl   prefer musl static over gnu
#                       --asset <s>    other disambiguator
#                       --all          install every executable in the
#                                      archive (for multi-binary releases)
#
# Like TOOL: joins $(SCOPE_TOOLS), emits a stamp rule, threads $(SUDO).
# Unlike TOOL: adds an order-only `| eget` prerequisite so the eget binary
# (installed by archive.sh in tools.mk) exists before this rule fires.
# -----------------------------------------------------------------------------
define EGET_TOOL
SCOPE_TOOLS += $(1)
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(LIB)/eget.sh $(3) $(if $(4),$(4),v$(2)) $(5))
$$(STAMP)/$(1)-$(2).done: | $$(STAMP)/eget-$$(EGET_VERSION).done
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
	@$(SUDO) rm -f $$(DEST)/$(1)
endef

SCOPE_TOOLS :=
USER_TOOLS  :=
include tools.mk

# -----------------------------------------------------------------------------
# Claude — bespoke rule outside the macros.
#   - The official installer always lands in ~/.local/bin (doesn't accept
#     a destination flag); never sudo'd.
#   - Has its own phony target so `provision` can choose to invoke it or
#     not based on MODE — dev_machine only, prod_machine skips.
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
# claude-statusline — interactive ccstatusline setup prompt.
#   - Dev-only. The recipe body conditionally compiles based on MODE.
#   - Re-runnable any time post-bootstrap; bootstrap.sh's tail also invokes
#     this target on --dev runs after ensure_chezmoi_initialized.
#   - Version passed via env so versions.mk stays the single source of truth.
# -----------------------------------------------------------------------------
.PHONY: claude-statusline
claude-statusline:
ifeq ($(MODE),dev)
	@CCSTATUSLINE_VERSION=$(CCSTATUSLINE_VERSION) ../scripts/setup-ccstatusline.sh
else
	@echo "claude-statusline is a dev_machine target — skipping (MODE=$(MODE))"
endif

include packages.mk
include shell.mk
include dotfiles.mk

# -----------------------------------------------------------------------------
# Top-level targets.
#
# `provision` is the full bootstrap — packages + shell + tools + user-tools
# + dotfiles, plus claude-cli on dev mode only. `dev` and `prod` are
# friendlies that set MODE and re-invoke.
#
# Order of phony deps matches the old playbook order:
#   packages.yml  → packages
#   tools.yml     → tools (scope) + user-tools + claude-cli (dev only)
#   shell.yml     → shell
#   dotfiles.yml  → dotfiles
# -----------------------------------------------------------------------------
.PHONY: provision dev prod all tools user-tools list clean help

tools: $(SCOPE_TOOLS)
user-tools: $(USER_TOOLS)

provision: packages tools user-tools shell dotfiles
ifeq ($(MODE),dev)
provision: claude-cli
endif

# Friendly aliases — re-invoke make with the right MODE so scope.mk
# resolves before any rule fires.
dev:
	@$(MAKE) --no-print-directory MODE=dev provision

prod:
	@$(MAKE) --no-print-directory MODE=prod provision

# `make all` — synonym for `make tools` (scope-aware bulk install).
# Predates the provision target; preserved so existing muscle memory works.
all: tools

list:
	@printf 'scope-tools (%d):\n' $(words $(SCOPE_TOOLS))
	@printf '  %s\n' $(sort $(SCOPE_TOOLS))
	@printf '\nuser-tools (%d):\n' $(words $(USER_TOOLS))
	@printf '  %s\n' $(sort $(USER_TOOLS))
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'

clean:
	@rm -rf "$(STAMP)"

help:
	@echo "Provisioning:"
	@echo "  make dev                      full provision, dev_machine scope (sudo, /usr/local/bin)"
	@echo "  make prod                     full provision, prod_machine scope (~/.local/bin)"
	@echo "  make provision MODE=dev|prod  same, explicit"
	@echo ""
	@echo "Tool installs (scope-aware via MODE):"
	@echo "  make all          install every scope-aware tool (use -j8 for parallelism)"
	@echo "  make user-tools   install pip user-site tools (glances, asciinema, harlequin)"
	@echo "  make claude-cli   install the Claude Code CLI"
	@echo "  make <tool>       install just one tool, e.g. make gitui"
	@echo "  make clean-<tool> wipe stamp (+ binary for scope tools)"
	@echo "  make list         list every managed tool, grouped"
	@echo "  make clean        wipe all stamps (forces full reinstall next run)"
	@echo ""
	@echo "Sub-targets (rarely invoked directly):"
	@echo "  make packages     dnf core + EPEL + optional (MODE=dev only)"
	@echo "  make shell        PATH via /etc/profile.d or ~/.bashrc"
	@echo "  make dotfiles     chezmoi update (skipped if no config yet)"
	@echo ""
	@echo "Required vars:"
	@echo "  MODE=dev|prod     scope selector — set explicitly or via 'make dev' / 'make prod'"
	@echo ""
	@echo "Files:"
	@echo "  scope.mk     MODE → DEST/SUDO/HAS_SUDO/INSTALL_PACKAGES"
	@echo "  versions.mk  tool versions"
	@echo "  packages.mk  dnf packages"
	@echo "  shell.mk     PATH wiring"
	@echo "  dotfiles.mk  chezmoi orchestration"
	@echo "  tools.mk     per-tool rules"
	@echo "  lib/*.sh     install helpers"
