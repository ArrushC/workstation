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
# REPO_ROOT — make runs with CWD = makefile/, so the repo root is one dir up.
# Used by the `lint` / `install-hooks` targets to reach repo-root scripts.
REPO_ROOT := $(abspath $(CURDIR)/..)

# Export so library scripts (lib/*.sh) and any sub-makes inherit these.
# MODE + HAS_SUDO are read by lib/doctor.sh (scope-aware report text + the
# wsl-config gating); IS_WSL is exported from scope.mk.
export DEST HELIX_RUNTIME_DEST LIB STAMP SUDO MODE HAS_SUDO

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
DOCTOR_ROWS += scope|$(1)|$(2)
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
	@$(SUDO) rm -f $$(DEST)/$(1)
endef

# _SOFT_RULE_BODY — like _RULE_BODY, but a FAILING install command warns and is
# skipped instead of aborting the build, and the stamp is left ABSENT so the
# next run retries. (A naive `cmd || true` in _RULE_BODY would be wrong: the
# trailing `touch` would still fire, marking the tool installed-when-it-isn't
# and never retrying.) For rolling tools fetched live from a third-party
# service whose transient outage shouldn't fail a whole `make dev` (cht.sh).
define _SOFT_RULE_BODY
$(1): $$(STAMP)/$(1)-$(2).done
$$(STAMP)/$(1)-$(2).done:
	@printf '==> %s %s\n' "$(1)" "$(2)"
	@if $(3); then mkdir -p $$(@D) && touch $$@; else printf '  ! %s install failed (service unreachable?) — skipping; will retry next run\n' "$(1)"; fi
.PHONY: $(1) clean-$(1)
endef

# SOFT_TOOL — TOOL whose install failure is non-fatal (see _SOFT_RULE_BODY).
define SOFT_TOOL
SCOPE_TOOLS += $(1)
DOCTOR_ROWS += scope|$(1)|$(2)
$(call _SOFT_RULE_BODY,$(1),$(2),$(SUDO) $(3))
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
	@$(SUDO) rm -f $$(DEST)/$(1)
endef

define USER_TOOL
USER_TOOLS += $(1)
DOCTOR_ROWS += user|$(1)|$(2)
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
DOCTOR_ROWS += scope|$(1)|$(2)
UPDATE_SPECS += $(1)|$(2)|$(3)|$(if $(4),$(4),v$(2))
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(LIB)/eget.sh $(3) $(if $(4),$(4),v$(2)) $(5))
$$(STAMP)/$(1)-$(2).done: | $$(STAMP)/eget-$$(EGET_VERSION).done
clean-$(1):
	@rm -f $$(STAMP)/$(1)-*.done
	@$(SUDO) rm -f $$(DEST)/$(1)
endef

# DOCTOR_ROWS  — one `kind|name|version` row per managed component, consumed
#                by `make doctor` (lib/doctor.sh). TOOL/EGET_TOOL register as
#                `scope`, USER_TOOL as `user`; the bespoke targets are added
#                by hand next to the doctor target below.
# UPDATE_SPECS — one `name|version|repo|tag` spec per pinned tool, consumed
#                by `make check-updates` (lib/check-updates.sh). EGET_TOOL
#                registers automatically (it knows repo + tag); everything
#                else is hand-registered in the UPDATE-CHECK REGISTRY block
#                at the bottom of tools.mk.
SCOPE_TOOLS  :=
USER_TOOLS   :=
DOCTOR_ROWS  :=
UPDATE_SPECS :=
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
# pwndbg — GDB front-end (dev_machine only). Installs the self-contained
# portable release tarball via lib/pwndbg.sh, exposing a standalone `pwndbg`
# command (its own bundled Python). It deliberately does NOT touch ~/.gdbinit,
# so plain `gdb` keeps loading GEF (the chezmoi-tracked ~/.gdbinit): `gdb` →
# GEF, `pwndbg` → pwndbg, no collision. $(SUDO) because it deposits under
# $(DEST) (/usr/local on dev), like node-runtime. Stamp bakes PWNDBG_VERSION so
# a bump in versions.mk reinstalls. No WSL skip — a debugger is useful in a WSL
# dev guest (unlike the host-management services below).
# -----------------------------------------------------------------------------
.PHONY: pwndbg clean-pwndbg
ifeq ($(MODE),dev)
pwndbg: $(STAMP)/pwndbg-$(PWNDBG_VERSION).done
$(STAMP)/pwndbg-$(PWNDBG_VERSION).done:
	@printf '==> pwndbg %s\n' "$(PWNDBG_VERSION)"
	@$(SUDO) $(LIB)/pwndbg.sh $(PWNDBG_VERSION)
	@mkdir -p $(@D) && touch $@
else
pwndbg:
	@echo "pwndbg is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-pwndbg:
	@rm -f $(STAMP)/pwndbg-*.done
	@$(SUDO) rm -f $(DEST)/pwndbg
	@$(SUDO) rm -rf $(DEST)/_pwndbg-*

# -----------------------------------------------------------------------------
# vcpkg — Microsoft C/C++ package manager (dev_machine only). git-clones +
# bootstraps the repo at VCPKG_VERSION into $(VCPKG_ROOT_DIR) (the clone IS
# $VCPKG_ROOT) via lib/vcpkg.sh, then symlinks the `vcpkg` binary into $(DEST).
# The shell rc exports the SAME VCPKG_ROOT literal (dev-gated) — keep
# dot_zshrc.tmpl / dot_bashrc.tmpl in sync with VCPKG_ROOT_DIR (CLAUDE.md
# dual-edit). $(SUDO) because the root tree + the $(DEST) symlink live under
# /usr/local on dev. Stamp bakes VCPKG_VERSION. No WSL skip (builds fine in a
# WSL dev guest).
# -----------------------------------------------------------------------------
VCPKG_ROOT_DIR := /usr/local/share/vcpkg
.PHONY: vcpkg clean-vcpkg
ifeq ($(MODE),dev)
vcpkg: $(STAMP)/vcpkg-$(VCPKG_VERSION).done
$(STAMP)/vcpkg-$(VCPKG_VERSION).done:
	@printf '==> vcpkg %s\n' "$(VCPKG_VERSION)"
	@$(SUDO) $(LIB)/vcpkg.sh $(VCPKG_VERSION) $(VCPKG_ROOT_DIR)
	@mkdir -p $(@D) && touch $@
else
vcpkg:
	@echo "vcpkg is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-vcpkg:
	@rm -f $(STAMP)/vcpkg-*.done
	@$(SUDO) rm -f $(DEST)/vcpkg
	@$(SUDO) rm -rf $(VCPKG_ROOT_DIR)

# -----------------------------------------------------------------------------
# docker-engine — Docker CE from Docker's official dnf repo, enabled via systemd.
#   - dev_machine only; skipped on WSL (the engine belongs to Docker Desktop on
#     the Windows host — same gating rationale as dozzle-/cockpit-service).
#   - Fast-path: if `docker` is already on PATH (manual install, podman shim),
#     the repo + package steps are skipped — never fight an existing engine.
#   - Repo file is curl'd straight into /etc/yum.repos.d/ (avoids a
#     dnf-plugins-core/config-manager dependency). RHEL proper gets
#     linux/rhel; Alma/Rocky/CentOS get linux/centos, per Docker's docs.
#   - No versions.mk pin and no version in the stamp — Docker CE versions
#     come from dnf, same precedent as cockpit.
#   - Adds $USER to the docker group so the user-run container TUIs
#     (lazydocker, dive, ctop) work without sudo; takes effect on next login.
#   - The enable + group steps are guarded (unit/group may not exist when the
#     fast-path found a podman shim instead of real Docker CE).
#   - dozzle-service's stamp order-only-depends on THIS stamp file (not the
#     phony — see the EGET_TOOL invariant) so `make -j` can't fire dozzle
#     before the engine exists.
#   - clean-docker-engine deliberately does NOT `dnf remove` docker-ce or
#     touch images/containers — too destructive for a clean target. It only
#     disables the service and drops the stamp.
# -----------------------------------------------------------------------------
.PHONY: docker-engine clean-docker-engine
ifeq ($(MODE),dev)
ifeq ($(IS_WSL),true)
docker-engine:
	@echo "docker-engine: skipping on WSL — Docker Desktop on the Windows host owns the engine"
else
docker-engine: $(STAMP)/docker-engine.done
$(STAMP)/docker-engine.done:
	@printf '==> docker-engine (Docker CE via dnf + systemd)\n'
	@if command -v docker >/dev/null 2>&1; then \
	   printf '  docker already on PATH — skipping repo + package install\n'; \
	 else \
	   . /etc/os-release; \
	   case "$$ID" in rhel) repo_os=rhel ;; *) repo_os=centos ;; esac; \
	   printf '  adding docker-ce repo (linux/%s)\n' "$$repo_os"; \
	   curl -fsSL "https://download.docker.com/linux/$$repo_os/docker-ce.repo" \
	     | $(SUDO) install -m 0644 /dev/stdin /etc/yum.repos.d/docker-ce.repo; \
	   $(SUDO) dnf install -y docker-ce docker-ce-cli containerd.io \
	     docker-buildx-plugin docker-compose-plugin; \
	 fi
	@if systemctl cat docker.service >/dev/null 2>&1; then \
	   $(SUDO) systemctl enable --now docker; \
	 else \
	   printf '  no docker.service unit (podman shim?) — skipping enable\n'; \
	 fi
	@if ! getent group docker >/dev/null 2>&1; then \
	   printf '  no docker group on this host — skipping group membership\n'; \
	 elif id -nG "$$USER" | grep -qw docker; then \
	   printf '  %s already in the docker group\n' "$$USER"; \
	 else \
	   $(SUDO) usermod -aG docker "$$USER"; \
	   printf '  added %s to the docker group — takes effect on next login (or run: newgrp docker)\n' "$$USER"; \
	 fi
	@mkdir -p $(@D) && touch $@
endif
else
docker-engine:
	@echo "docker-engine is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-docker-engine:
	@$(SUDO) systemctl disable --now docker 2>/dev/null || true
	@rm -f $(STAMP)/docker-engine.done

# -----------------------------------------------------------------------------
# dozzle-service — install systemd unit + env file, pull image, enable + start.
#   - dev_machine only (recipe body gated on MODE=dev).
#   - Skips on WSL (IS_WSL=true) — same rationale as nerd-fonts: the web-admin
#     stack (Dozzle + Cockpit) is for a standalone Linux dev box, and Docker
#     on WSL lives in Docker Desktop on the Windows host. Prints a skip
#     message; no stamp is written (the WSL branch is a bare phony, not a
#     stamped target).
#   - Env file is templated: `@DOZZLE_VERSION@` in configs/dozzle/dozzle.env
#     is substituted with $(DOZZLE_VERSION) at install time via sed. Keeps
#     versions.mk as the single source of truth for the image tag.
#   - Stamp encodes $(DOZZLE_VERSION); bumping the pin invalidates the
#     stamp so the next `make dev` re-renders dozzle.env, re-pulls the
#     image, and restarts the unit.
#   - Stamp order-only-depends on docker-engine's stamp FILE (not the
#     phony — EGET_TOOL invariant) so the engine exists first even under
#     `make -j`. The `command -v docker` sanity check stays as a safety
#     net for direct invocation or a failed/skipped engine install.
# -----------------------------------------------------------------------------
.PHONY: dozzle-service clean-dozzle-service
ifeq ($(MODE),dev)
ifeq ($(IS_WSL),true)
dozzle-service:
	@echo "dozzle-service: skipping on WSL — Docker + web-admin stack live on the Windows host, not the WSL guest"
else
dozzle-service: $(STAMP)/dozzle-service-$(DOZZLE_VERSION).done
$(STAMP)/dozzle-service-$(DOZZLE_VERSION).done: | $(STAMP)/docker-engine.done
	@printf '==> dozzle-service (docker + systemd)\n'
	@if ! command -v docker >/dev/null 2>&1; then \
	   printf '  ERROR: docker is not installed. Dozzle runs as a container.\n' >&2; \
	   printf '         Run `make MODE=dev docker-engine` (normally part of provision) and retry.\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0755 -d /etc/dozzle
	@sed 's|@DOZZLE_VERSION@|$(DOZZLE_VERSION)|g' ../configs/dozzle/dozzle.env \
	   | $(SUDO) install -m 0644 /dev/stdin /etc/dozzle/dozzle.env
	@$(SUDO) install -m 0644 ../configs/dozzle/dozzle.service /etc/systemd/system/dozzle.service
	@$(SUDO) systemctl daemon-reload
	@$(SUDO) systemctl enable --now dozzle.service
	@mkdir -p $(@D) && touch $@
endif
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
#   - Skips on WSL (IS_WSL=true) — Cockpit is a host/network/storage management
#     UI for a standalone dev box; it makes no sense for a WSL guest you reach
#     from the Windows host. Skipped alongside dozzle-service (see above).
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
ifeq ($(IS_WSL),true)
cockpit-service:
	@echo "cockpit-service: skipping on WSL — host management UI is for standalone dev boxes, not the WSL guest"
else
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
endif
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
# rsyslog-service — install a tracked local-routing drop-in + enable the daemon.
#   - dev_machine only (recipe gated on MODE=dev). prod has no sudo and
#     INSTALL_PACKAGES=false, so a root-owned logging daemon can't live there.
#   - Skips on WSL (IS_WSL=true) — host logging is handled on the Windows side;
#     matches docker-/dozzle-/cockpit-service.
#   - rsyslog comes from dnf (it's in LINUX_OPTIONAL_PACKAGES). Like
#     cockpit-service this target does NOT install the package itself (can't
#     depend on the `packages` phony without breaking `make -j`); it sanity-
#     checks `rpm -q rsyslog` and aborts with a clear message if absent.
#   - Deploys configs/rsyslog/30-workstation.conf to /etc/rsyslog.d/, then
#     enables + restarts rsyslog so the drop-in takes effect (the local0..local7
#     facilities funnel into /var/log/workstation.log).
#   - Stamp is content-hashed (RSYSLOG_CONF_SHA) so editing the tracked drop-in
#     auto-redeploys; cf. wsl-config. No version to bake (dnf-versioned).
# -----------------------------------------------------------------------------
.PHONY: rsyslog-service clean-rsyslog-service
ifeq ($(MODE),dev)
ifeq ($(IS_WSL),true)
rsyslog-service:
	@echo "rsyslog-service: skipping on WSL — host logging is handled on the Windows side, not the WSL guest"
else
RSYSLOG_CONF_SHA := $(shell sha256sum ../configs/rsyslog/30-workstation.conf 2>/dev/null | cut -c1-12)
rsyslog-service: $(STAMP)/rsyslog-service-$(RSYSLOG_CONF_SHA).done
$(STAMP)/rsyslog-service-$(RSYSLOG_CONF_SHA).done:
	@printf '==> rsyslog-service (daemon + local-routing drop-in)\n'
	@if ! rpm -q rsyslog >/dev/null 2>&1; then \
	   printf '  ERROR: rsyslog package not installed. Run `make MODE=dev packages` first,\n' >&2; \
	   printf '         or `make MODE=dev provision` (which runs packages before this target).\n' >&2; \
	   exit 1; \
	 fi
	@$(SUDO) install -m 0644 ../configs/rsyslog/30-workstation.conf /etc/rsyslog.d/30-workstation.conf
	@$(SUDO) systemctl enable rsyslog
	@$(SUDO) systemctl restart rsyslog
	@printf '  rsyslog enabled; local0..local7 -> /var/log/workstation.log\n'
	@mkdir -p $(@D) && touch $@
endif
else
rsyslog-service:
	@echo "rsyslog-service is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-rsyslog-service:
	@$(SUDO) rm -f /etc/rsyslog.d/30-workstation.conf
	@$(SUDO) systemctl restart rsyslog 2>/dev/null || true
	@rm -f $(STAMP)/rsyslog-service-*.done

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
.PHONY: provision dev prod all tools user-tools list clean help doctor check-updates

tools: $(SCOPE_TOOLS)
user-tools: $(USER_TOOLS)

provision: packages tools user-tools shell dotfiles wsl-config
ifeq ($(MODE),dev)
provision: claude-cli node-runtime nerd-fonts docker-engine dozzle-service cockpit-service rsyslog-service
provision: pwndbg vcpkg
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

# -----------------------------------------------------------------------------
# doctor / check-updates — read-only reports; neither installs anything.
#
#   make doctor MODE=dev|prod         what's installed / missing / stale /
#                                     active, per tool + service + stamp
#   make check-updates MODE=dev|prod  every versions.mk pin vs the newest
#                                     upstream release tag (git ls-remote)
#
# The macro-registered DOCTOR_ROWS / UPDATE_SPECS (see the macro block above)
# carry the per-tool knowledge; the rows below add the bespoke targets that
# live outside the macros. bootstrap.sh's --doctor / --check-for-updates
# flags front these targets with the repo/chezmoi-level checks.
# -----------------------------------------------------------------------------
DOCTOR_ROWS += bespoke|claude-cli|$(CLAUDE_VERSION)
DOCTOR_ROWS += bespoke|node-runtime|$(NODE_VERSION)
DOCTOR_ROWS += bespoke|nerd-fonts|$(JETBRAINSMONO_NERD_VERSION)
DOCTOR_ROWS += bespoke|docker-engine|-
DOCTOR_ROWS += bespoke|dozzle-service|$(DOZZLE_VERSION)
DOCTOR_ROWS += bespoke|cockpit-service|-
DOCTOR_ROWS += bespoke|rsyslog-service|-
DOCTOR_ROWS += bespoke|wsl-config|-
DOCTOR_ROWS += bespoke|pwndbg|$(PWNDBG_VERSION)
DOCTOR_ROWS += bespoke|vcpkg|$(VCPKG_VERSION)

# NOTE: rows/specs contain `|` — they MUST be single-quoted into the recipe
# (via $(foreach …,'…')) or the shell parses every row as a pipeline and
# executes the tool names.
doctor:
	@printf '%s\n' $(foreach r,$(DOCTOR_ROWS),'$(r)') | \
	  LINUX_PACKAGES="$(LINUX_PACKAGES)" \
	  LINUX_OPTIONAL_PACKAGES="$(LINUX_OPTIONAL_PACKAGES)" \
	  $(LIB)/doctor.sh

check-updates:
	@printf '%s\n' $(foreach s,$(UPDATE_SPECS),'$(s)') | $(LIB)/check-updates.sh

.PHONY: lint install-hooks

# lint — run the mechanical invariant checks (version pins, line-endings/mode,
# BOM, sentinels, chezmoiignore target-paths, shellcheck). Same script the
# pre-commit hook and CI run. Like every target it inherits scope.mk's MODE
# requirement: invoke as `make lint MODE=prod`.
lint:
	@$(REPO_ROOT)/scripts/check-invariants.sh

# install-hooks — point git at the tracked .githooks/ dir so the pre-commit
# invariant check runs before every commit. Idempotent.
install-hooks:
	@git -C $(REPO_ROOT) config core.hooksPath .githooks
	@printf 'installed: git hooks now run from .githooks/ (pre-commit -> check-invariants.sh)\n'
	@printf 'bypass one commit with: git commit --no-verify\n'

.PHONY: ps-lint

# ps-lint — PSScriptAnalyzer over the .ps1 scripts (same check CI runs). Soft-skips
# where pwsh is absent (the whole Linux fleet); mainly for Windows-host local use.
# Invoked `make ps-lint MODE=prod` (inherits scope.mk's MODE requirement).
ps-lint:
	@if command -v pwsh >/dev/null 2>&1; then \
	   pwsh $(REPO_ROOT)/scripts/check-ps.ps1; \
	 else \
	   printf 'pwsh not installed — skipped (CI enforces PowerShell lint)\n'; \
	 fi

.PHONY: fmt secrets

# fmt — format the first-party shell scripts in place with shfmt -i 2 (same files
# + style check-invariants.sh enforces). Fix target for the `make lint` shfmt
# check. Soft-skips if shfmt is absent. Invoke `make fmt MODE=prod`.
fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
	   cd $(REPO_ROOT) && shfmt -w -i 2 bootstrap.sh makefile/lib/*.sh scripts/*.sh \
	     .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh \
	     chezmoi/private_dot_claude/executable_notify.sh \
	     chezmoi/dot_local/bin/executable_winterop \
	   && printf 'shfmt -i 2: formatted the first-party shell scripts\n'; \
	 else \
	   printf 'shfmt not installed — `make shfmt MODE=<...>` first\n'; \
	 fi

# secrets — scan the working tree for committed secrets with gitleaks (same scan
# check-invariants.sh runs). Soft-skips if gitleaks is absent. `make secrets MODE=prod`.
secrets:
	@if command -v gitleaks >/dev/null 2>&1; then \
	   cd $(REPO_ROOT) && gitleaks dir --no-banner --redact -c .gitleaks.toml .; \
	 else \
	   printf 'gitleaks not installed — `make gitleaks MODE=<...>` first\n'; \
	 fi

list:
	@printf 'scope-tools (%d):\n' $(words $(SCOPE_TOOLS))
	@printf '  %s\n' $(sort $(SCOPE_TOOLS))
	@printf '\nuser-tools (%d):\n' $(words $(USER_TOOLS))
	@printf '  %s\n' $(sort $(USER_TOOLS))
	@printf '\nservices (provisioned on MODE=dev only; no-op on WSL):\n'
	@printf '  docker-engine\n  dozzle-service\n  cockpit-service\n  rsyslog-service\n'
	@printf '\nclaude-cli (provisioned on MODE=dev only)\n'
	@printf '\nnerd-fonts (provisioned on MODE=dev only; no-op on WSL)\n'
	@printf '\nC/C++ dev tools (provisioned on MODE=dev only): pwndbg vcpkg\n'
	@printf '  (nnd debugger is a scope-tool above; gcc/clang/gdb/valgrind/... come from dnf)\n'
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
	@echo "  make docker-engine    install Docker CE + enable the service (dev only, non-WSL)"
	@echo "  make dozzle-service   install dozzle systemd unit + start service (dev only)"
	@echo "  make cockpit-service  install cockpit.conf + enable socket + open firewall (dev only)"
	@echo "  make rsyslog-service  install local-routing drop-in + enable rsyslog (dev only, non-WSL)"
	@echo "  make pwndbg           install the pwndbg GDB front-end, portable build (dev only)"
	@echo "  make vcpkg            install the vcpkg C/C++ package manager (dev only)"
	@echo "  make wsl-config       install tracked /etc/wsl.conf (WSL hosts only)"
	@echo "  make <tool>       install just one tool, e.g. make gitui"
	@echo "  make clean-<tool> wipe stamp (+ binary for scope tools)"
	@echo "  make list         list every managed tool, grouped"
	@echo "  make clean        wipe all stamps (forces full reinstall next run)"
	@echo ""
	@echo "Health / updates (read-only — nothing is installed or changed):"
	@echo "  make doctor MODE=dev|prod         report installed/missing/stale tools, services, stamps"
	@echo "  make check-updates MODE=dev|prod  compare versions.mk pins against upstream release tags"
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
