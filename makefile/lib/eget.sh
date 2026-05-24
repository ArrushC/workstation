#!/usr/bin/env bash
# eget.sh — install a GitHub-release binary via the eget meta-installer.
#
# Usage:
#   eget.sh <user/repo> <tag> [extra-eget-args...]
#
#   user/repo   GitHub owner/repo path (e.g. gitui-org/gitui).
#   tag         Release tag string (caller decides whether to include 'v').
#   extra args  Optional — forwarded to eget. Typical extras:
#                 --asset musl   prefer musl static over gnu glibc
#                 --asset <s>    any other disambiguator
#                 --all          install every executable in the archive
#                                (for multi-binary releases like
#                                 sg+ast-grep, age+age-keygen)
#
# Env:
#   DEST  Destination directory (required; exported by Makefile/scope.mk).
#
# Defaults baked in below:
#   --to $DEST              binary destination
#   --quiet                 suppress eget's progress bars
#   --asset '^.sbom|sig|…'  exclude SBOM / signing / checksum side-files
#                           that confuse eget's auto-detection on modern
#                           releases (glow, helix, fzf, …). Without these,
#                           eget prompts the user to pick manually, which
#                           hangs the make recipe since there's no TTY.
#
# We invoke $(DEST)/eget explicitly rather than `eget` from PATH because
# during first bootstrap, PATH may not yet include $(DEST) (shell.mk
# wires that on the same provision run). eget itself is installed to
# $(DEST) by archive.sh in tools.mk, with an order-only Make dependency
# from every EGET_TOOL.

set -euo pipefail
: "${DEST:?eget.sh: DEST not set}"

if (( $# < 2 )); then
  echo "eget.sh: usage: $0 <user/repo> <tag> [eget args...]" >&2
  exit 2
fi

user_repo="$1"
tag="$2"
shift 2

exec "$DEST/eget" "$user_repo" \
  --tag "$tag" \
  --to "$DEST" \
  --quiet \
  --asset '^.sbom' \
  --asset '^.sig' \
  --asset '^.sha' \
  --asset '^.asc' \
  --asset '^.zip.gpg' \
  --asset '^.deb' \
  --asset '^.rpm' \
  --asset '^.apk' \
  --asset '^.pkg' \
  --asset '^.proof' \
  "$@"
