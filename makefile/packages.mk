# packages.mk — system packages via dnf.
#
# Replaces ansible/roles/linux-base/tasks/packages.yml. Three targets:
#   packages-core      — required packages (idempotent, fails loud)
#   packages-epel      — EPEL (best-effort, RHEL family only — skipped on Fedora)
#   packages-optional  — long list of nice-to-have packages (per-pkg non-fatal)
#
# Only runs when INSTALL_PACKAGES=true (set by scope.mk for MODE=dev).
# For MODE=prod the top-level `packages` target is a no-op with a message.
#
# RHEL-only today. Adding apt/Debian support: branch on /etc/os-release
# at the top of this file and swap LINUX_PACKAGES / dnf for an apt-side
# list / apt-get. Not done yet because no managed host in hosts.conf needs it.

# Required packages — bootstrap pulls these in before tools.mk fires.
# Anything that fails here aborts the build (no `|| true` on the install line).
LINUX_PACKAGES := \
  git \
  curl \
  wget \
  unzip \
  tar \
  make \
  gcc \
  openssl-devel \
  python3 \
  python3-pip \
  zsh \
  ncurses \
  pkgconf-pkg-config

# Nice-to-haves — installed per-package with `|| true` so a missing package
# in some distro variant doesn't poison the whole bootstrap. Order doesn't
# matter; group comments match the old group_vars/all.yml.
#
# NOTE: `fswatch` is intentionally listed but is NOT packaged for EL9 — it was
# dropped after EPEL 8, so `dnf search fswatch` returns no match on AlmaLinux 9
# (verified 2026-05-30). The `|| true` path silently skips it on EL9 hosts; the
# line is kept so it installs automatically on EL7/8 or a future Debian host.
# On EL9 the file-watching need is covered by `inotify-tools` (EPEL) +
# `watchexec` (EGET_TOOL, both scopes). To get real fswatch on EL9 you'd have
# to build it from source (autotools) — deliberately not done here.
LINUX_OPTIONAL_PACKAGES := \
  ripgrep bash-completion \
  htop multitail goaccess \
  nmap mtr \
  parallel pv entr tree strace perf cronie time \
  inotify-tools fswatch \
  man-db man-pages info \
  rsync vim-common vim-enhanced \
  shellcheck gdb lsof tcpdump \
  cockpit cockpit-system cockpit-storaged cockpit-networkmanager \
  cockpit-packagekit cockpit-podman

.PHONY: packages packages-core packages-epel packages-optional

ifeq ($(INSTALL_PACKAGES),true)
packages: packages-core packages-epel packages-optional
else
packages:
	@echo "  skipping system packages (MODE=$(MODE), INSTALL_PACKAGES=$(INSTALL_PACKAGES))"
endif

# Fast-path strategy across all three package targets: `rpm -q <pkg>` is a
# local rpmdb lookup (~10ms) vs dnf's ~500ms metadata + dependency round
# trip. We probe with rpm -q first and only invoke `sudo dnf install` for
# packages that aren't already installed. On a steady-state re-run this
# means zero sudo invocations from this whole file — usually 20+ seconds
# saved end-to-end.
packages-core:
	@printf '==> dnf core packages\n'
	@missing=""; \
	for pkg in $(LINUX_PACKAGES); do \
	  rpm -q "$$pkg" >/dev/null 2>&1 || missing="$$missing $$pkg"; \
	done; \
	if [ -z "$$missing" ]; then \
	  printf '  all %d core packages already installed\n' $(words $(LINUX_PACKAGES)); \
	else \
	  printf '  installing missing:%s\n' "$$missing"; \
	  $(SUDO) dnf install -y $$missing; \
	fi

# EPEL — RHEL family (Rocky/Alma/RHEL/CentOS) only. Fedora has the same
# packages in its base repo, so EPEL would be wrong there. Detection
# matches the old `ansible_facts['os_family'] == 'RedHat' and
# ansible_facts['distribution'] != 'Fedora'` condition.
packages-epel:
	@if rpm -q epel-release >/dev/null 2>&1; then \
	  printf '  EPEL already installed\n'; \
	elif [ -f /etc/redhat-release ] && ! grep -qi fedora /etc/os-release 2>/dev/null; then \
	  printf '==> EPEL (RHEL family)\n'; \
	  $(SUDO) dnf install -y epel-release || true; \
	else \
	  printf '  skipping EPEL (non-RHEL or Fedora)\n'; \
	fi

# Optional packages — rpm-q fast-path skips dnf for installed ones. Only
# packages not on the host yet hit dnf. The dnf call is per-package
# (vs one batch call) so one bad name doesn't poison the rest — same
# semantics as the old `loop + ignore_errors` shape, just an order of
# magnitude faster on re-runs.
packages-optional:
	@printf '==> Optional packages (best-effort)\n'
	@n_installed=0; n_added=0; n_skipped=0; \
	for pkg in $(LINUX_OPTIONAL_PACKAGES); do \
	  if rpm -q "$$pkg" >/dev/null 2>&1; then \
	    n_installed=$$((n_installed + 1)); \
	  elif $(SUDO) dnf install -y "$$pkg" >/dev/null 2>&1; then \
	    printf '  added   %s\n' "$$pkg"; \
	    n_added=$$((n_added + 1)); \
	  else \
	    printf '  skipped %s\n' "$$pkg"; \
	    n_skipped=$$((n_skipped + 1)); \
	  fi; \
	done; \
	printf '  %d already installed, %d added, %d skipped\n' "$$n_installed" "$$n_added" "$$n_skipped"
