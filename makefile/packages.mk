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
  python3-pip

# Nice-to-haves — installed per-package with `|| true` so a missing package
# in some distro variant doesn't poison the whole bootstrap. Order doesn't
# matter; group comments match the old group_vars/all.yml.
LINUX_OPTIONAL_PACKAGES := \
  ripgrep bash-completion \
  htop multitail goaccess \
  nmap mtr \
  zsh parallel pv entr tree strace perf cronie time \
  rsync vim-common \
  shellcheck gdb lsof tcpdump

.PHONY: packages packages-core packages-epel packages-optional

ifeq ($(INSTALL_PACKAGES),true)
packages: packages-core packages-epel packages-optional
else
packages:
	@echo "  skipping system packages (MODE=$(MODE), INSTALL_PACKAGES=$(INSTALL_PACKAGES))"
endif

packages-core:
	@printf '==> dnf core packages\n'
	$(SUDO) dnf install -y $(LINUX_PACKAGES)

# EPEL — RHEL family (Rocky/Alma/RHEL/CentOS) only. Fedora has the same
# packages in its base repo, so EPEL would be wrong there. Detection
# matches the old `ansible_facts['os_family'] == 'RedHat' and
# ansible_facts['distribution'] != 'Fedora'` condition.
#
# Wrapped in `|| true` to match the old `ignore_errors: true` — some
# managed images already have EPEL configured at the system level and
# dnf will exit non-zero with "Package epel-release is already installed".
packages-epel:
	@if [ -f /etc/redhat-release ] && ! grep -qi fedora /etc/os-release 2>/dev/null; then \
	  printf '==> EPEL (RHEL family)\n'; \
	  $(SUDO) dnf install -y epel-release || true; \
	else \
	  printf '  skipping EPEL (non-RHEL or Fedora)\n'; \
	fi

# Optional packages — each in its own dnf call so one missing package
# doesn't abort the rest. Equivalent to ansible's loop+ignore_errors.
# Output is friendlier than ansible's JSON: skipped packages are named.
packages-optional:
	@printf '==> Optional packages (best-effort)\n'
	@for pkg in $(LINUX_OPTIONAL_PACKAGES); do \
	  if $(SUDO) dnf install -y "$$pkg" >/dev/null 2>&1; then \
	    printf '  ok      %s\n' "$$pkg"; \
	  else \
	    printf '  skipped %s\n' "$$pkg"; \
	  fi; \
	done
