#!/usr/bin/env bash
# font.sh — install JetBrainsMono Nerd Font Mono variants for user-scope use.
#
# Invoked by makefile/Makefile's nerd-fonts target (NOT directly). Downloads
# the JetBrainsMono.tar.xz release archive from ryanoasis/nerd-fonts, verifies
# its SHA256 against a per-version pin, extracts the six Mono variants into
# $PARENT/JetBrainsMonoNerdFontMono/, refreshes fontconfig, writes a stamp.
#
# Args: $1 = parent dir under which JetBrainsMonoNerdFontMono/ is created
#               (passed as the value of ~/.local/share/fonts at call time)
#       $2 = upstream Nerd Fonts release version (e.g. 3.4.0)
#       $3 = stamp file path to touch on success
#
# Honours $GITHUB_TOKEN (Authorization: Bearer header) to avoid the
# 60-req/hour unauthenticated GitHub rate limit. Soft-fails with a stderr
# warning and exit 0 if fc-cache is absent (font deposit still succeeds);
# hard-fails on download or SHA256 issues.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'usage: font.sh <parent-dir> <version> <stamp-file>\n' >&2
  exit 2
fi

PARENT="$1"
VERSION="$2"
STAMP="$3"

# Per-version SHA256 of JetBrainsMono.tar.xz. Bump by adding a new branch
# and verifying against the upstream SHA-256.txt:
#   curl -sL https://github.com/ryanoasis/nerd-fonts/releases/download/v<VER>/SHA-256.txt | grep JetBrainsMono.tar.xz
case "$VERSION" in
  3.4.0) EXPECT_SHA='ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582' ;;
  *)
    printf 'font.sh: no SHA256 pinned for v%s — add a case branch and verify against upstream\n' "$VERSION" >&2
    exit 1
    ;;
esac

DEST_DIR="$PARENT/JetBrainsMonoNerdFontMono"
TARBALL_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${VERSION}/JetBrainsMono.tar.xz"

printf '==> JetBrainsMono Nerd Font Mono v%s\n' "$VERSION"

FONT_TMPDIR=$(mktemp -d)
trap 'rm -rf "$FONT_TMPDIR"' EXIT

TARBALL="$FONT_TMPDIR/JetBrainsMono.tar.xz"
CURL_AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURL_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
curl -fsSL --retry 3 --retry-delay 2 "${CURL_AUTH[@]}" -o "$TARBALL" "$TARBALL_URL"

ACTUAL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
  printf 'font.sh: SHA256 mismatch for v%s\n  expected: %s\n  actual:   %s\n' \
    "$VERSION" "$EXPECT_SHA" "$ACTUAL_SHA" >&2
  exit 1
fi

# Sweep stale install (in case upstream renames TTF files between releases),
# then recreate empty.
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# Extract only the six Mono variants. Top-level archive layout has all
# TTFs at the root of the tarball, so --strip-components is not needed.
tar -C "$DEST_DIR" -xJf "$TARBALL" \
  'JetBrainsMonoNerdFontMono-Regular.ttf' \
  'JetBrainsMonoNerdFontMono-Italic.ttf' \
  'JetBrainsMonoNerdFontMono-Bold.ttf' \
  'JetBrainsMonoNerdFontMono-BoldItalic.ttf' \
  'JetBrainsMonoNerdFontMono-Medium.ttf' \
  'JetBrainsMonoNerdFontMono-MediumItalic.ttf'

INSTALLED=$(find "$DEST_DIR" -maxdepth 1 -name 'JetBrainsMonoNerdFontMono-*.ttf' | wc -l)
if [ "$INSTALLED" -ne 6 ]; then
  printf 'font.sh: extracted %d of 6 expected TTF files\n' "$INSTALLED" >&2
  exit 1
fi

# Refresh fontconfig cache. Scope to the new dir so it's fast (<100ms). Soft-fail
# with a warning if fc-cache is missing — the deposit itself succeeded.
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f "$DEST_DIR" >/dev/null
else
  printf '  warning: fc-cache not on PATH — install `fontconfig` for font discovery\n' >&2
fi

mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
printf '  installed 6 Mono variants to %s\n' "$DEST_DIR"
