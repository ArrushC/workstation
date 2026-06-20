#!/usr/bin/env bash
# vcpkg.sh — install Microsoft's vcpkg C/C++ package manager by git-cloning the
# repo at a pinned release tag and running its bootstrap script.
#
# Usage:
#   vcpkg.sh <version-tag> <root-dir>
#
#   version-tag  Release tag to check out (e.g. 2026.06.01).
#   root-dir     Where the vcpkg tree lives = $VCPKG_ROOT. The shell rc exports
#                this SAME literal (dev-gated) — keep dot_zshrc.tmpl /
#                dot_bashrc.tmpl in sync with VCPKG_ROOT_DIR in makefile/Makefile
#                (see CLAUDE.md's VCPKG_ROOT dual-edit invariant).
#
# Env:
#   DEST         Destination directory for the `vcpkg` symlink (required;
#                provided by scope.mk).
#
# Unlike a normal single-binary tool, vcpkg IS its own VCPKG_ROOT tree: the
# ports registry and the bootstrapped `vcpkg` binary both live inside the clone.
# So we clone to <root-dir>, bootstrap, then symlink only the binary into $DEST
# (which is on PATH). Re-runs fast-forward the existing clone to the pinned tag
# rather than re-cloning. bootstrap needs network + a C++ compiler (gcc-c++ from
# packages.mk). Sudo is the Makefile's job (SUDO wrapper from scope.mk).

set -euo pipefail

: "${DEST:?vcpkg.sh: DEST not set}"

if (($# != 2)); then
  printf 'vcpkg.sh: usage: %s <version-tag> <root-dir>\n' "$0" >&2
  exit 2
fi

version="$1"
root="$2"

mkdir -p "$DEST"

# -c advice.detachedHead=false silences git's detached-HEAD advisory — both the
# tag checkout and the --branch <tag> clone land on a detached HEAD, and the
# hint is noise in a clean `make dev` log.
if [ -d "$root/.git" ]; then
  printf '  ↻ updating vcpkg clone at %s -> %s\n' "$root" "$version"
  git -C "$root" fetch --depth 1 origin "refs/tags/$version" --quiet
  git -C "$root" -c advice.detachedHead=false checkout --quiet --force FETCH_HEAD
else
  printf '  ↓ cloning microsoft/vcpkg @ %s -> %s\n' "$version" "$root"
  rm -rf "$root"
  git -c advice.detachedHead=false clone --depth 1 --branch "$version" \
    https://github.com/microsoft/vcpkg.git "$root" --quiet
fi

printf '  ↪ bootstrapping vcpkg\n'
# -disableMetrics opts out of vcpkg's telemetry permanently (drops a
# vcpkg.disable-metrics marker in the root tree).
"$root/bootstrap-vcpkg.sh" -disableMetrics

if [ ! -x "$root/vcpkg" ]; then
  printf 'vcpkg.sh: bootstrap did not produce %s/vcpkg\n' "$root" >&2
  exit 1
fi

ln -sfn "$root/vcpkg" "$DEST/vcpkg"
printf '  ✓ vcpkg %s ready at %s/vcpkg (VCPKG_ROOT=%s)\n' "$version" "$DEST" "$root"
