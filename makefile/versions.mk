# versions.mk — single source of truth for tool versions.
#
# Edit a value, then `make <tool>` (or `make all`): the version is baked
# into the per-tool stamp filename, so changing it here invalidates the
# stamp and forces a reinstall on the next run. No manual cleanup needed.
#
# Tools that have no upstream version pinning (broot floats off latest,
# nb pulls from master, pip --upgrade always grabs the newest) use the
# literal string "latest" — the stamp filename never changes, so re-running
# `make` won't redownload them. `make clean-<tool>` forces it.

# --- Meta-installer ----------------------------------------------------------
# eget downloads GitHub releases and figures out the right asset by repo+tag.
# Tools registered via EGET_TOOL in tools.mk depend on this binary (installed
# first via the regular archive.sh helper). Bumping invalidates the
# eget-<version>.done stamp and triggers reinstall like any other tool.
EGET_VERSION := 1.3.4

# --- Tier-0: original toolbelt -----------------------------------------------
FZF_VERSION      := 0.73.1
ZOXIDE_VERSION   := 0.9.9
STARSHIP_VERSION := 1.25.1
ZELLIJ_VERSION   := 0.44.3
GLOW_VERSION     := 2.1.2
NB_VERSION       := latest
HELIX_VERSION    := 25.07.1
CHEZMOI_VERSION  := latest

# --- Tier-1: static-binary toolbelt ------------------------------------------
FD_VERSION         := 10.4.2
BAT_VERSION        := 0.26.1
BTOP_VERSION       := 1.4.7
NCDU_VERSION       := 2.9.2
BANDWHICH_VERSION  := 0.23.1
JQ_VERSION         := 1.8.1
YQ_VERSION         := 4.53.3
TEALDEER_VERSION   := 1.8.1
WITR_VERSION       := 0.3.2
BROOT_VERSION      := latest
USQL_VERSION       := 0.21.4
LAZYDOCKER_VERSION := 0.25.2
DIVE_VERSION       := 0.13.1
LNAV_VERSION       := 0.14.0
GOPASS_VERSION     := 1.16.1
AGE_VERSION        := 1.3.1
FASTFETCH_VERSION  := 2.64.2
SSH_COPY_ID_VERSION := latest

# --- Second-wave expansion (2026-05) -----------------------------------------
GITUI_VERSION      := 0.28.1
LAZYGIT_VERSION    := 0.62.2
JUJUTSU_VERSION    := 0.42.0
YAZI_VERSION       := 26.5.6
AST_GREP_VERSION   := 0.43.0
TELEVISION_VERSION := 0.15.9
XH_VERSION         := 0.25.3
GPING_VERSION      := 1.20.2
ATUIN_VERSION      := 18.16.1
DELTA_VERSION      := 0.19.2
MICRO_VERSION      := 2.0.15
EZA_VERSION        := 0.23.4
SD_VERSION         := 1.1.0
CTOP_VERSION       := 0.7.7
K9S_VERSION        := 0.51.0
RCLONE_VERSION     := 1.74.3
CROC_VERSION       := 10.4.4
HYPERFINE_VERSION  := 1.20.0
MISE_VERSION       := 2026.6.10
UV_VERSION         := 0.11.21
DSQ_VERSION        := 0.23.0

# --- Robustness gap-fillers (universal static binaries) ---------------------
GH_VERSION        := 2.94.0
SOPS_VERSION      := 3.13.1
HTMLQ_VERSION     := 0.4.0
OUCH_VERSION      := 0.8.0
WATCHEXEC_VERSION := 2.5.1

# --- Service / journal / cgroup observability -------------------------------
BOTTOM_VERSION        := 0.12.3
SYSTEMCTL_TUI_VERSION := 0.5.2
LAZYJOURNAL_VERSION   := 0.8.6
SYSZ_VERSION          := 1.4.3

# --- Pip-installed (latest tracked via stamp; pip --upgrade does the rest) --
GLANCES_VERSION   := latest
ASCIINEMA_VERSION := latest
HARLEQUIN_VERSION := latest

# --- Chezmoi TUI ------------------------------------------------------------
# chezit (Go binary, EGET_TOOL). cheznav was tried first but its pip
# package requires Python 3.14 which isn't in AlmaLinux 9's modules.
CHEZIT_VERSION := 0.3.0

# --- Claude Code CLI --------------------------------------------------------
CLAUDE_VERSION := latest
CCSTATUSLINE_VERSION := 2.2.19
NODE_VERSION := 26.3.0

# --- Service / web admin (dev_machine only) ---------------------------------
# Dozzle is run as a Docker container via systemd (no native binary —
# upstream publishes Docker images only). The value below pins the Docker
# image tag (amir20/dozzle:$(DOZZLE_VERSION)). The dozzle-service make
# target sed-substitutes it into the deployed /etc/dozzle/dozzle.env;
# bumping invalidates the dozzle-service stamp so the next `make dev`
# re-renders the env file, re-pulls the image, and restarts the unit.
# Cockpit comes from dnf (see packages.mk) and isn't versioned here.
DOZZLE_VERSION := 10.6.5

# --- Fonts (dev_machine only, makefile target deposits to ~/.local/share/fonts) -
# JetBrainsMono Nerd Font Mono — the six Mono-variant TTFs from the
# ryanoasis/nerd-fonts release archive. Pinned alongside its SHA256 in
# makefile/lib/font.sh (per-version case branch) and mirrored in the Windows
# installer script (scripts/install-nerd-fonts.ps1) — bumping the pin requires
# editing all three. See the triple-edit invariant in CLAUDE.md.
JETBRAINSMONO_NERD_VERSION := 3.4.0

# --- Cheatsheets (cheat + cht.sh) -------------------------------------------
# cheat — offline cheatsheet CLI (cheat/cheat). Non-v tag; release assets are
# gzipped single binaries (cheat-linux-amd64.gz) which eget decompresses.
# cht.sh — client for the cheat.sh online service; a rolling raw script (no
# release), so it has no real version (direct.sh always fetches latest).
CHEAT_VERSION := 5.1.0
CHTSH_VERSION := latest

# --- (2026-06) interactive explorers + git replay ---------------------------
# nnn — ncurses file manager (jarun/nnn). tools.mk installs the plain musl-static
# tarball via archive.sh, renaming its internal `nnn-musl-static` binary to `nnn`.
# fx — interactive JSON viewer (antonmedv/fx). Non-v tag; raw-binary assets.
# gitlogue — cinematic git commit-replay TUI (unhappychoice/gitlogue).
# gnu-glibc only (no musl build) — fine on this glibc fleet.
NNN_VERSION      := 5.2
FX_VERSION       := 39.2.0
GITLOGUE_VERSION := 0.9.0
