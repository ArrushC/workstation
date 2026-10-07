#!/usr/bin/env bash
# enable-el-repos.sh — EPEL + CRB on RHEL-family hosts. Invoked by
# tasks/enable-el-repos (config.linux.toml's pre-packages hook), NOT directly.
#
# Detection sources /etc/os-release and matches on $ID / $ID_LIKE. Do NOT use a
# loose `grep -i fedora /etc/os-release`: AlmaLinux's os-release carries
# `ID_LIKE="rhel centos fedora"` AND `LOGO="fedora-logo-icon"`, so a substring
# match would wrongly classify Alma as Fedora and skip EPEL/CRB entirely. So:
# exclude ONLY true Fedora ($ID = fedora), then require an EL marker in
# $ID $ID_LIKE (rhel/centos/almalinux/rocky — RHEL itself is ID=rhel even
# though its ID_LIKE is just "fedora").
#
# CRB (CodeReady Builder) is enabled too because EPEL on EL9 REQUIRES it: many
# EPEL packages fail dependency resolution without CRB, and some toolbelt
# packages live directly in CRB (meson, ninja-build) or pull CRB-resident deps
# (heaptrack, bear); on EL8 cppcheck is in CRB too. The dnf batch is all-or-
# nothing, so without CRB it fails. The repo is picked from the host: subscribed
# RHEL enables `codeready-builder-for-rhel-<major>-<arch>-rpms` through
# subscription-manager; Alma/Rocky/Stream enable `crb` (EL9+) or `powertools`
# (EL8) with dnf config-manager (dnf-plugins-core). NOTE: --set-enabled is dnf4
# syntax; a future EL10/dnf5 host would need `config-manager setopt
# <repo>.enabled=1` instead.
#
# sudo — always interactive or with cached credentials (mise
# elevates the packages phase the same way; this hook runs before it, via
# config.linux.toml's [bootstrap.hooks] "pre-packages"). Exits 1 when EPEL
# can't be installed or CRB can't be enabled on an EL host: the packages batch
# that follows would fail anyway, and this names the repo to fix.

set -uo pipefail

osr="${WORKSTATION_OS_RELEASE:-/etc/os-release}" # tests point it at a fixture
if [ -r "$osr" ]; then
  # shellcheck source=/dev/null
  . "$osr"
fi

if [ "${ID:-}" = fedora ]; then
  printf '  skipping EPEL/CRB (Fedora — these packages are in the base repo)\n'
  exit 0
fi
if ! printf '%s %s' "${ID:-}" "${ID_LIKE:-}" | grep -qiwE 'rhel|centos|almalinux|rocky'; then
  printf '  skipping EPEL/CRB (not RHEL-family: ID=%s)\n' "${ID:-unknown}"
  exit 0
fi

if rpm -q epel-release >/dev/null 2>&1; then
  printf '  EPEL already installed\n'
else
  printf '==> EPEL (RHEL family)\n'
  if ! sudo dnf install -y epel-release; then
    printf 'enable-el-repos.sh: epel-release install failed — the packages batch would fail anyway\n' >&2
    exit 1
  fi
fi

printf '==> CRB (CodeReady Builder — required by many EPEL packages)\n'
# Already on? `dnf repolist --enabled` needs no sudo. Without this check,
# every wsu ran `sudo dnf config-manager --set-enabled` again: an interactive
# host got a sudo prompt each time for a repo already enabled, and a
# password-sudo host run without a TTY printed a false "could not
# auto-enable CRB" warning.
if dnf repolist --enabled -q 2>/dev/null | awk '{print $1}' |
  grep -qxE 'crb|powertools|codeready-builder-for-rhel-[0-9]+-.*-rpms'; then
  printf '  CRB already enabled\n'
  exit 0
fi
major="${VERSION_ID%%.*}"
if [ "${ID:-}" = rhel ] && command -v subscription-manager >/dev/null 2>&1; then
  repo="codeready-builder-for-rhel-${major}-$(uname -m)-rpms"
  cmd=(sudo subscription-manager repos --enable "$repo")
else
  repo=powertools
  [ "${major:-0}" -ge 9 ] 2>/dev/null && repo=crb
  rpm -q dnf-plugins-core >/dev/null 2>&1 || sudo dnf install -y dnf-plugins-core || true
  cmd=(sudo dnf config-manager --set-enabled "$repo")
fi
if "${cmd[@]}" >/dev/null 2>&1; then
  printf '  CRB enabled (repo: %s)\n' "$repo"
  exit 0
fi
printf 'enable-el-repos.sh: could not enable CRB (%s), so the packages batch would fail on meson/ninja-build/cppcheck. Enable it with: %s\n' "$repo" "${cmd[*]}" >&2
exit 1
