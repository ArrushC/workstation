# packages.mk — system packages via dnf.
#
# Replaces ansible/roles/linux-base/tasks/packages.yml. Three targets:
#   packages-core      — required packages (idempotent, fails loud)
#   packages-epel      — EPEL + CRB (best-effort, RHEL family only — skipped on Fedora)
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
#
# `libatomic` is the runtime shared lib the Node.js >=25 binary links against
# (node is mise-managed and dev-only, and this file only runs on dev). Node 24 did NOT
# need it, and `gcc` ships only the dev `.so` (a linker script, not the runtime
# SONAME), so without the package `node`/`npx` die at startup with
# "libatomic.so.1: cannot open shared object file" — which breaks the
# ccstatusline statusline. BaseOS package on RHEL-family; a future Debian host
# would need `libatomic1` instead.
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
  libatomic \
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
#
# C/C++ TOOLCHAIN GROUP (gcc-c++ … heaptrack): the GNU + LLVM toolchains plus
# debuggers, analysis, build systems, and the sanitizer runtimes. `gcc`/`make`
# are already core (LINUX_PACKAGES); `gdb`/`perf`/`strace` are already listed
# above — not repeated here. (`gdb-gdbserver`, the separate EL subpackage for the
# remote-debug stub `gdbserver` — `gdb` doesn't bundle it — is paired with `gdb`
# in that general group above.) Several of these come from EPEL/CRB rather than
# BaseOS (clang-tools-extra → clangd+clang-tidy+clang-format, cppcheck, meson,
# ninja-build, heaptrack), so the per-package `|| true` best-effort path is
# load-bearing: on a host without those repos enabled they skip cleanly instead
# of failing the build. The sanitizers themselves (ASan/UBSan/TSan) are compiler
# features — libasan/libubsan/libtsan are only the gcc runtime .so's the
# `-fsanitize=` link step needs (clang ships its own compiler-rt). GOTCHA: on
# RHEL the ninja binary is `ninja-build`, not `ninja` (symlink it in
# ~/.local/bin if a build expects `ninja`). `bear` generates a
# compile_commands.json (`bear -- make`) so clangd works on Make-based projects
# that aren't CMake/meson; `ccache` is a compiler cache (use via `ccache gcc` or
# PATH shims). nnd/pwndbg/vcpkg are NOT here — see tools.mk (nnd) and the
# bespoke pwndbg/vcpkg targets in the Makefile.
#
# `bind-utils` is the classic ISC DNS toolset (dig/nslookup/host/delv/nsupdate,
# EL9 AppStream). Kept alongside the modern `doggo` (EGET_TOOL, both scopes)
# because scripts, docs, and muscle memory everywhere assume plain
# `dig`/`nslookup` exist. No WSL gate — DNS tooling works fine there.
LINUX_OPTIONAL_PACKAGES := \
  ripgrep bash-completion \
  htop multitail goaccess rsyslog \
  nmap mtr bind-utils \
  parallel pv entr tree strace perf cronie time \
  rlwrap \
  inotify-tools fswatch \
  man-db man-pages info \
  rsync vim-common vim-enhanced \
  shellcheck gdb gdb-gdbserver lsof tcpdump \
  gcc-c++ clang clang-tools-extra llvm lldb \
  valgrind cppcheck ltrace \
  libasan libubsan libtsan \
  cmake meson ninja-build heaptrack bear ccache \
  cockpit cockpit-system cockpit-storaged cockpit-networkmanager \
  cockpit-packagekit cockpit-podman

# NFS CLIENT GROUP — dev-only like everything in this file, and additionally
# skipped on WSL hosts (IS_WSL comes from scope.mk). Client-side tooling only:
# mount/inspect/debug NFS shares served elsewhere — this repo never turns a
# dev box into an NFS server (no nfs-server/exportfs/rpcbind service wiring).
#   nfs-utils      — mount.nfs, showmount, nfsstat, nfsiostat, mountstats (BaseOS)
#   nfs4-acl-tools — nfs4_getfacl / nfs4_setfacl / nfs4_editfacl (AppStream)
#   autofs         — on-demand automounter; installed but NOT enabled/configured
#                    (maps are per-host /etc config this repo doesn't manage;
#                    activate per host: write maps, then
#                    `sudo systemctl enable --now autofs`)
# The WSL exclusion matches the docker-engine/cockpit/rsyslog-service policy:
# NFS on WSL2 is out of scope. The conditional append keeps the group out of
# LINUX_OPTIONAL_PACKAGES entirely on WSL; packages-optional prints a skip
# line there so provision output stays auditable. gen-tool-memory.sh extracts
# this variable by name for the TOOLS memory block — rename it and the
# generator stanza must move with it.
LINUX_NFS_PACKAGES := nfs-utils nfs4-acl-tools autofs

ifeq ($(IS_WSL),false)
LINUX_OPTIONAL_PACKAGES += $(LINUX_NFS_PACKAGES)
endif

.PHONY: packages packages-core packages-epel packages-optional

ifeq ($(INSTALL_PACKAGES),true)
packages: packages-core packages-epel packages-optional
else
packages:
	@echo "  skipping system packages (MODE=$(MODE), INSTALL_PACKAGES=$(INSTALL_PACKAGES))"
endif

# core → epel → optional is a REAL dependency chain, not just a nice order:
# packages-optional silently degrades (per-package `|| true`) for anything
# EPEL/CRB-backed, so it MUST run after packages-epel has enabled those repos.
# Before these edges the ordering was incidental (left-to-right prereqs of
# `packages` under serial make) — under `make -j` the siblings would race and
# reintroduce the exact CRB failure mode documented in the packages-epel
# comment above. The edges also serialize dnf, which holds a global lock.
packages-epel: packages-core
packages-optional: packages-epel

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

# EPEL + CRB — RHEL family (Rocky/Alma/RHEL/CentOS) only. Fedora has the same
# packages in its base repo, so EPEL would be wrong there.
#
# Detection sources /etc/os-release and matches on $ID / $ID_LIKE. Do NOT use a
# loose `grep -i fedora /etc/os-release` (the previous approach): AlmaLinux's
# os-release carries `ID_LIKE="rhel centos fedora"` AND `LOGO="fedora-logo-icon"`,
# so the substring match wrongly classified Alma as Fedora and skipped EPEL/CRB
# entirely (was masked while epel-release happened to be pre-installed; exposed
# once CRB enable moved ahead of that fast-path). So: exclude ONLY true Fedora
# (`$ID = fedora`), then require an EL marker in `$ID $ID_LIKE` (rhel/centos/
# almalinux/rocky — RHEL itself is `ID=rhel` even though its `ID_LIKE` is just
# "fedora"). os-release is also more reliable than `[ -f /etc/redhat-release ]`,
# which is absent on some minimal/container images.
#
# CRB (CodeReady Builder) is enabled here too because EPEL on EL9 REQUIRES it:
# many EPEL packages fail dependency resolution without CRB, and some toolbelt
# packages live directly in CRB (meson, ninja-build) or pull CRB-resident deps
# (heaptrack, bear) — without it they silently land on the packages-optional
# skip path. Enabling is best-effort + idempotent: ensure dnf-plugins-core (for
# config-manager), then `--set-enabled` across the known CRB repo ids — `crb`
# (EL9 Alma/Rocky/Stream), `powertools` (EL8), and the `codeready-builder-*`
# name (subscribed RHEL). A failure only warns (the optional packages degrade to
# skip, as before); it never aborts the build. Idempotent, so it re-runs as a
# no-op on every provision. NOTE: `--set-enabled` is dnf4 syntax (EL9); a future
# EL10/dnf5 host would need `config-manager setopt <repo>.enabled=1` instead.
packages-epel:
	@if [ -r /etc/os-release ]; then . /etc/os-release; fi; \
	if [ "$$ID" = fedora ]; then \
	  printf '  skipping EPEL/CRB (Fedora — these packages are in the base repo)\n'; \
	elif ! printf '%s %s' "$$ID" "$$ID_LIKE" | grep -qiwE 'rhel|centos|almalinux|rocky'; then \
	  printf '  skipping EPEL/CRB (not RHEL-family: ID=%s)\n' "$${ID:-unknown}"; \
	else \
	  if rpm -q epel-release >/dev/null 2>&1; then \
	    printf '  EPEL already installed\n'; \
	  else \
	    printf '==> EPEL (RHEL family)\n'; \
	    $(SUDO) dnf install -y epel-release || true; \
	  fi; \
	  printf '==> CRB (CodeReady Builder — required by many EPEL packages)\n'; \
	  rpm -q dnf-plugins-core >/dev/null 2>&1 || $(SUDO) dnf install -y dnf-plugins-core || true; \
	  crb_ok=""; \
	  for repo in crb powertools "codeready-builder-for-rhel-9-$$(uname -m)-rpms"; do \
	    if $(SUDO) dnf config-manager --set-enabled "$$repo" >/dev/null 2>&1; then \
	      printf '  CRB enabled (repo: %s)\n' "$$repo"; crb_ok=1; break; \
	    fi; \
	  done; \
	  [ -n "$$crb_ok" ] || printf '  ! could not auto-enable CRB — meson/ninja-build/heaptrack/bear may skip (enable manually: sudo dnf config-manager --set-enabled crb)\n'; \
	fi

# Optional packages — rpm-q fast-path skips dnf for installed ones. Only
# packages not on the host yet hit dnf. The dnf call is per-package
# (vs one batch call) so one bad name doesn't poison the rest — same
# semantics as the old `loop + ignore_errors` shape, just an order of
# magnitude faster on re-runs.
packages-optional:
	@printf '==> Optional packages (best-effort)\n'
	@if [ "$(IS_WSL)" = "true" ]; then printf '  skipping NFS client group on WSL (%s)\n' "$(LINUX_NFS_PACKAGES)"; fi
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
