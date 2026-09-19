#!/usr/bin/env bash
# enable-el-repos.sh — EPEL + CRB on RHEL-family dev hosts. Invoked by
# tasks/enable-el-repos (config.host.toml's pre-packages hook), NOT directly.
# Replaced the Make-era packages-epel target (was makefile/packages.mk).
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
# (heaptrack, bear) — without it they silently degrade to the packages-optional
# skip path. Enabling is best-effort + idempotent: ensure dnf-plugins-core (for
# config-manager), then --set-enabled across the known CRB repo ids — `crb`
# (EL9 Alma/Rocky/Stream), `powertools` (EL8), and the `codeready-builder-*`
# name (subscribed RHEL). A failure there only warns (never aborts). NOTE:
# --set-enabled is dnf4 syntax (EL9); a future EL10/dnf5 host would need
# `config-manager setopt <repo>.enabled=1` instead.
#
# sudo — dev hosts only, always interactive or with cached credentials (mise
# elevates the packages phase the same way; this hook runs before it, via
# config.host.toml's [bootstrap.hooks] "pre-packages"). Exit 0 always, except
# when `sudo dnf install -y epel-release` fails on an EL host — the packages
# batch that follows would fail anyway, so this exits 1.

set -uo pipefail

if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
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
rpm -q dnf-plugins-core >/dev/null 2>&1 || sudo dnf install -y dnf-plugins-core || true

crb_ok=""
for repo in crb powertools "codeready-builder-for-rhel-9-$(uname -m)-rpms"; do
  if sudo dnf config-manager --set-enabled "$repo" >/dev/null 2>&1; then
    printf '  CRB enabled (repo: %s)\n' "$repo"
    crb_ok=1
    break
  fi
done
[ -n "$crb_ok" ] || printf '  ! could not auto-enable CRB — meson/ninja-build/heaptrack/bear may skip (enable manually: sudo dnf config-manager --set-enabled crb)\n'

exit 0
