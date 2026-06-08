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
# node-runtime — Node.js (+ npm + npx + corepack) from the nodejs.org
# tarball. Dev-only (the ccstatusline statusLine command runs `npx`, and
# any future npm-based tool needs it). Pinned to NODE_VERSION in
# versions.mk. The lib/node.sh helper extracts the tarball to
# $(DEST)/_node-vX.Y.Z/ and symlinks the four bin entries into $(DEST).
# Older _node-* trees are stripped on every (re-)install.
# -----------------------------------------------------------------------------
.PHONY: node-runtime clean-node-runtime
node-runtime: $(STAMP)/node-$(NODE_VERSION).done
$(STAMP)/node-$(NODE_VERSION).done:
	@printf '==> node %s\n' "$(NODE_VERSION)"
	@$(SUDO) $(LIB)/node.sh $(NODE_VERSION)
	@mkdir -p $(@D) && touch $@
clean-node-runtime:
	@rm -f $(STAMP)/node-*.done
	@$(SUDO) rm -f $(DEST)/node $(DEST)/npm $(DEST)/npx $(DEST)/corepack
	@$(SUDO) rm -rf $(DEST)/_node-*

# -----------------------------------------------------------------------------
# nerd-fonts — JetBrainsMono Nerd Font Mono variants from ryanoasis/nerd-fonts.
#   - dev_machine only (added to provision's deps only on MODE=dev, below).
#   - Skips on WSL hosts (IS_WSL=true) because WezTerm runs on the Windows
#     host where the Windows-side installer (scripts/install-nerd-fonts.ps1,
#     invoked from bootstrap.ps1) handles registration. Stamp still written
#     so `make nerd-fonts` returns fast on subsequent WSL runs.
#   - NO $(SUDO) — deposits to $HOME/.local/share/fonts/JetBrainsMonoNerdFontMono/
#     which is user-owned; fc-cache also runs against a user-scope dir. Other
#     bespoke targets (node-runtime, claude-cli) use $(SUDO) because they
#     deposit to $(DEST) (/usr/local/bin on dev) which is system-owned.
#   - Stamp encodes $(JETBRAINSMONO_NERD_VERSION); bumping the pin in
#     versions.mk invalidates the stamp on the next run.
# -----------------------------------------------------------------------------
.PHONY: nerd-fonts clean-nerd-fonts
nerd-fonts: $(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done
$(STAMP)/nerd-fonts-$(JETBRAINSMONO_NERD_VERSION).done:
	@if [ "$(IS_WSL)" = "true" ]; then \
	  printf '  skipping nerd-fonts on WSL — fonts resolved by Windows-side WezTerm\n'; \
	  mkdir -p $(@D) && touch $@; \
	else \
	  $(LIB)/font.sh "$$HOME/.local/share/fonts" $(JETBRAINSMONO_NERD_VERSION) $@; \
	fi
clean-nerd-fonts:
	@rm -rf "$$HOME/.local/share/fonts/JetBrainsMonoNerdFontMono"
	@rm -f $(STAMP)/nerd-fonts-*.done

# -----------------------------------------------------------------------------
# claude-statusline — interactive ccstatusline setup prompt.
#   - Dev-only. The recipe body conditionally compiles based on MODE.
#   - Depends on node-runtime (also dev-only) so the npx the script
#     invokes is the chezmoi-managed Linux-native one, not a Windows
#     passthrough that crashes on WSL working dirs.
#   - Re-runnable any time post-bootstrap; bootstrap.sh's tail also
#     invokes this target on --dev runs after ensure_chezmoi_initialized.
#   - Version passed via env so versions.mk stays the single source of
#     truth.
# -----------------------------------------------------------------------------
.PHONY: claude-statusline
ifeq ($(MODE),dev)
claude-statusline: node-runtime
endif
claude-statusline:
ifeq ($(MODE),dev)
	@CCSTATUSLINE_VERSION=$(CCSTATUSLINE_VERSION) ../scripts/setup-ccstatusline.sh
else
	@echo "claude-statusline is a dev_machine target — skipping (MODE=$(MODE))"
endif

# -----------------------------------------------------------------------------
# dozzle-service — install systemd unit + env file, pull image, enable + start.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - Env file is templated: `@DOZZLE_VERSION@` in configs/dozzle/dozzle.env
#     is substituted with $(DOZZLE_VERSION) at install time via sed. Keeps
#     versions.mk as the single source of truth for the image tag.
#   - Stamp encodes $(DOZZLE_VERSION); bumping the pin invalidates the
#     stamp so the next `make dev` re-renders dozzle.env, re-pulls the
#     image, and restarts the unit.
#   - Sanity-checks `command -v docker` at the top of the recipe (this
#     repo doesn't install Docker; lazydocker/dive/ctop already assume
#     it). Loud failure with a clear message if Docker is missing.
# -----------------------------------------------------------------------------
.PHONY: dozzle-service clean-dozzle-service
ifeq ($(MODE),dev)
dozzle-service: $(STAMP)/dozzle-service-$(DOZZLE_VERSION).done
$(STAMP)/dozzle-service-$(DOZZLE_VERSION).done:
	@printf '==> dozzle-service (docker + systemd)\n'
	@if ! command -v docker >/dev/null 2>&1; then \
	   printf '  ERROR: docker is not installed. Dozzle runs as a container.\n' >&2; \
	   printf '         Install Docker (or Podman with a docker shim) and retry.\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0755 -d /etc/dozzle
	@sed 's|@DOZZLE_VERSION@|$(DOZZLE_VERSION)|g' ../configs/dozzle/dozzle.env \
	   | $(SUDO) install -m 0644 /dev/stdin /etc/dozzle/dozzle.env
	@$(SUDO) install -m 0644 ../configs/dozzle/dozzle.service /etc/systemd/system/dozzle.service
	@$(SUDO) systemctl daemon-reload
	@$(SUDO) systemctl enable --now dozzle.service
	@mkdir -p $(@D) && touch $@
else
dozzle-service:
	@echo "dozzle-service is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-dozzle-service:
	@$(SUDO) systemctl disable --now dozzle.service 2>/dev/null || true
	@$(SUDO) docker rm -f dozzle 2>/dev/null || true
	@$(SUDO) docker image rm amir20/dozzle:$(DOZZLE_VERSION) 2>/dev/null || true
	@$(SUDO) rm -f /etc/systemd/system/dozzle.service /etc/dozzle/dozzle.env
	@$(SUDO) rmdir /etc/dozzle 2>/dev/null || true
	@$(SUDO) systemctl daemon-reload
	@rm -f $(STAMP)/dozzle-service-*.done

# -----------------------------------------------------------------------------
# cockpit-service — install cockpit.conf, enable cockpit.socket, open firewalld.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - CANNOT depend on the `packages` phony (would break `make -j8`).
#     packages.mk doesn't produce a stamp file either, so there's no stamp
#     to order-only-depend on. Instead the recipe sanity-checks
#     `rpm -q cockpit` and aborts with a clear message if the package
#     isn't installed yet. Correct under both serial and -j make.
#   - Stamp has no version suffix; Cockpit's package version comes from dnf.
#   - firewalld step skipped (with a message) when firewalld is inactive.
# -----------------------------------------------------------------------------
.PHONY: cockpit-service clean-cockpit-service
ifeq ($(MODE),dev)
cockpit-service: $(STAMP)/cockpit-service.done
$(STAMP)/cockpit-service.done:
	@printf '==> cockpit-service (socket + firewall + conf)\n'
	@if ! rpm -q cockpit >/dev/null 2>&1; then \
	   printf '  ERROR: cockpit package not installed. Run `make MODE=dev packages` first,\n' >&2; \
	   printf '         or `make MODE=dev provision` (which runs packages before this target).\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0755 -d /etc/cockpit
	@$(SUDO) install -m 0644 ../configs/cockpit/cockpit.conf /etc/cockpit/cockpit.conf
	@$(SUDO) systemctl enable --now cockpit.socket
	@if systemctl is-active --quiet firewalld 2>/dev/null; then \
	   $(SUDO) firewall-cmd --permanent --add-service=cockpit >/dev/null && \
	   $(SUDO) firewall-cmd --reload >/dev/null && \
	   printf '  firewalld: cockpit service opened\n'; \
	 else \
	   printf '  firewalld inactive — skipping firewall step\n'; \
	 fi
	@mkdir -p $(@D) && touch $@
else
cockpit-service:
	@echo "cockpit-service is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-cockpit-service:
	@$(SUDO) systemctl disable --now cockpit.socket 2>/dev/null || true
	@if systemctl is-active --quiet firewalld 2>/dev/null; then \
	   $(SUDO) firewall-cmd --permanent --remove-service=cockpit >/dev/null 2>&1 || true; \
	   $(SUDO) firewall-cmd --reload >/dev/null 2>&1 || true; \
	 fi
	@$(SUDO) rm -f /etc/cockpit/cockpit.conf
	@rm -f $(STAMP)/cockpit-service.done

# -----------------------------------------------------------------------------
# wsl-config — install the tracked /etc/wsl.conf on WSL hosts.
#   - Runs only when IS_WSL=true AND HAS_SUDO=true. Writing /etc/ needs root,
#     so a non-WSL host or a sudo-less prod scope skips with a message.
#   - Verbatim copy from configs/wsl/wsl.conf (no templating — values are
#     hardcoded for this single-host setup).
#   - Stamp is content-hashed (WSL_CONF_SHA) so editing the tracked file
#     auto-redeploys; an unchanged re-run is a no-op. wsl.conf has no version,
#     so the content hash is the re-run trigger (cf. version-baked stamps).
#   - Changes only take effect after `wsl --shutdown` from a Windows terminal,
#     so the recipe prints that reminder.
# -----------------------------------------------------------------------------
.PHONY: wsl-config clean-wsl-config
ifeq ($(IS_WSL):$(HAS_SUDO),true:true)
WSL_CONF_SHA := $(shell sha256sum ../configs/wsl/wsl.conf 2>/dev/null | cut -c1-12)
wsl-config: $(STAMP)/wsl-config-$(WSL_CONF_SHA).done
$(STAMP)/wsl-config-$(WSL_CONF_SHA).done:
	@printf '==> wsl-config (/etc/wsl.conf)\n'
	@$(SUDO) install -m 0644 ../configs/wsl/wsl.conf /etc/wsl.conf
	@printf '  installed /etc/wsl.conf — run `wsl --shutdown` from a Windows\n'
	@printf '  terminal for changes to take effect (restarts all WSL distros).\n'
	@mkdir -p $(@D) && touch $@
else
wsl-config:
	@echo "wsl-config: skipping (IS_WSL=$(IS_WSL), HAS_SUDO=$(HAS_SUDO); needs both true)"
endif
clean-wsl-config:
	@$(SUDO) rm -f /etc/wsl.conf
	@rm -f $(STAMP)/wsl-config-*.done

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

provision: packages tools user-tools shell dotfiles wsl-config
ifeq ($(MODE),dev)
provision: claude-cli node-runtime nerd-fonts dozzle-service cockpit-service
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
	@printf '\nservices (provisioned on MODE=dev only):\n'
	@printf '  dozzle-service\n  cockpit-service\n'
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
	@printf '\nnerd-fonts (provisioned on MODE=dev only; no-op on WSL)\n'
	@printf '\nwsl-config (WSL hosts with sudo only; deploys /etc/wsl.conf)\n'

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
	@echo "  make dozzle-service   install dozzle systemd unit + start service (dev only)"
	@echo "  make cockpit-service  install cockpit.conf + enable socket + open firewall (dev only)"
	@echo "  make wsl-config       install tracked /etc/wsl.conf (WSL hosts only)"
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
