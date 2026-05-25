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
FZF_VERSION      := 0.54.0
ZOXIDE_VERSION   := 0.9.4
STARSHIP_VERSION := 1.19.0
ZELLIJ_VERSION   := 0.40.1
GLOW_VERSION     := 2.1.2
NB_VERSION       := latest
HELIX_VERSION    := 24.03
CHEZMOI_VERSION  := latest

# --- Tier-1: static-binary toolbelt ------------------------------------------
FD_VERSION         := 10.4.2
BAT_VERSION        := 0.26.1
BTOP_VERSION       := 1.4.7
NCDU_VERSION       := 2.9.1
BANDWHICH_VERSION  := 0.23.1
JQ_VERSION         := 1.8.1
YQ_VERSION         := 4.53.2
TEALDEER_VERSION   := 1.8.1
WITR_VERSION       := 0.3.2
BROOT_VERSION      := latest
USQL_VERSION       := 0.21.4
LAZYDOCKER_VERSION := 0.25.2
DIVE_VERSION       := 0.13.1
LNAV_VERSION       := 0.14.0
GOPASS_VERSION     := 1.16.1
AGE_VERSION        := 1.3.1
FASTFETCH_VERSION  := 2.63.1
SSH_COPY_ID_VERSION := latest

# --- Second-wave expansion (2026-05) -----------------------------------------
GITUI_VERSION      := 0.28.1
LAZYGIT_VERSION    := 0.61.1
JUJUTSU_VERSION    := 0.41.0
YAZI_VERSION       := 26.5.6
AST_GREP_VERSION   := 0.42.2
TELEVISION_VERSION := 0.15.7
XH_VERSION         := 0.25.3
GPING_VERSION      := 1.20.1
ATUIN_VERSION      := 18.16.1
DELTA_VERSION      := 0.19.2
MICRO_VERSION      := 2.0.15
EZA_VERSION        := 0.23.4
SD_VERSION         := 1.1.0
CTOP_VERSION       := 0.7.7
K9S_VERSION        := 0.50.18
RCLONE_VERSION     := 1.74.1
CROC_VERSION       := 10.4.3
HYPERFINE_VERSION  := 1.20.0
MISE_VERSION       := 2026.5.10
UV_VERSION         := 0.11.14
DSQ_VERSION        := 0.23.0

# --- Robustness gap-fillers (universal static binaries) ---------------------
GH_VERSION    := 2.92.0
SOPS_VERSION  := 3.13.1
HTMLQ_VERSION := 0.4.0
OUCH_VERSION  := 0.7.1

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
CHEZIT_VERSION := 0.2.2

# --- Claude Code CLI --------------------------------------------------------
CLAUDE_VERSION := latest
CCSTATUSLINE_VERSION := 2.2.19
NODE_VERSION := 24.16.0
