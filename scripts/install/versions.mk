# versions.mk — single source of truth for tool versions.
#
# Edit a value, then `make <tool>` (or `make all`) — the version is baked
# into the per-tool stamp filename, so changing it here invalidates the
# stamp and forces a reinstall on the next run. No manual cleanup needed.
#
# Tools that have no upstream version pinning (e.g. nb downloads from
# master, chezmoi uses get.chezmoi.io which always fetches latest) use
# the literal string "latest" — the stamp filename never changes, so
# re-running `make` won't redownload them. `make clean-<tool>` forces it.
#
# Phase 1 — pilot tools only. Phase 2 will add the remaining ~50.

# Pilot batch (one per install shape, for verifying the helpers)
GITUI_VERSION   := 0.28.1
YAZI_VERSION    := 26.5.6
HELIX_VERSION   := 24.03
CHEZMOI_VERSION := latest
NB_VERSION      := latest
