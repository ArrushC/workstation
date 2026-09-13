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
FZF_VERSION      := 0.74.3
ZOXIDE_VERSION   := 0.10.0
STARSHIP_VERSION := 1.26.0
ZELLIJ_VERSION   := 0.45.1
# zjstatus (the zellij tab bar) is a WASM plugin compiled against zellij's
# plugin ABI: each release states the zellij floor it needs (v0.25.0: ">= 0.45.0
# required"). ZJSTATUS_ZELLIJ_FLOOR records that floor next to the pin, and
# check-invariants.sh asserts ZELLIJ_VERSION meets it — a mismatch is silent at
# runtime (the bar pane renders nothing useful; `zellij setup --check` still says
# Well defined). Bump the pin AND the floor together, from the release notes;
# that is why ZJSTATUS_VERSION sits in bump-versions.sh's EXCLUDE (gopls precedent).
ZJSTATUS_VERSION := 0.25.0
ZJSTATUS_ZELLIJ_FLOOR := 0.45.0
GLOW_VERSION     := 3.0.0
NB_VERSION       := latest
HELIX_VERSION    := 25.07.1
CHEZMOI_VERSION  := latest

# --- Tier-1: static-binary toolbelt ------------------------------------------
FD_VERSION         := 10.5.0
BAT_VERSION        := 0.26.1
BTOP_VERSION       := 1.4.7
NCDU_VERSION       := 2.9.1
BANDWHICH_VERSION  := 0.23.1
JQ_VERSION         := 1.8.2
YQ_VERSION         := 4.53.6
TEALDEER_VERSION   := 1.9.0
WITR_VERSION       := 0.3.3
BROOT_VERSION      := 1.60.0
USQL_VERSION       := 0.21.4
LAZYDOCKER_VERSION := 0.25.2
DIVE_VERSION       := 0.13.1
LNAV_VERSION       := 0.14.1
GOPASS_VERSION     := 1.17.0
AGE_VERSION        := 1.3.2
FASTFETCH_VERSION  := 2.68.1
SSH_COPY_ID_VERSION := latest

# --- Second-wave expansion (2026-05) -----------------------------------------
GITUI_VERSION      := 0.28.1
LAZYGIT_VERSION    := 0.65.0
JUJUTSU_VERSION    := 0.45.1
YAZI_VERSION       := 26.9.1
AST_GREP_VERSION   := 0.45.3
TELEVISION_VERSION := 0.15.9
XH_VERSION         := 0.26.2
GPING_VERSION      := 1.21.0
ATUIN_VERSION      := 18.21.0
DELTA_VERSION      := 0.19.2
MICRO_VERSION      := 2.0.15
EZA_VERSION        := 0.23.5
SD_VERSION         := 1.1.0
CTOP_VERSION       := 0.7.7
K9S_VERSION        := 0.51.0
RCLONE_VERSION     := 1.75.1
CROC_VERSION       := 11.5.0
HYPERFINE_VERSION  := 1.20.0
MISE_VERSION       := 2026.9.1
UV_VERSION         := 0.12.7
DSQ_VERSION        := 0.23.0

# --- Robustness gap-fillers (universal static binaries) ---------------------
GH_VERSION        := 2.98.0
SOPS_VERSION      := 3.13.3
HTMLQ_VERSION     := 0.4.0
OUCH_VERSION      := 0.8.2
WATCHEXEC_VERSION := 2.7.2

# --- Service / journal / cgroup observability -------------------------------
BOTTOM_VERSION        := 0.14.9
SYSTEMCTL_TUI_VERSION := 0.8.0
LAZYJOURNAL_VERSION   := 0.8.6
SYSZ_VERSION          := 1.4.3

# --- Pip-installed (latest tracked via stamp; pip --upgrade does the rest) --
GLANCES_VERSION   := latest
ASCIINEMA_VERSION := latest
HARLEQUIN_VERSION := latest

# --- Chezmoi TUI ------------------------------------------------------------
# chezit (Go binary, EGET_TOOL). cheznav was tried first but its pip
# package requires Python 3.14 which isn't in AlmaLinux 9's modules.
CHEZIT_VERSION := 0.4.0

# --- Claude Code CLI --------------------------------------------------------
CLAUDE_VERSION := latest
CCSTATUSLINE_VERSION := 2.2.27
NODE_VERSION := 26.8.1

# --- Service / web admin (dev_machine only) ---------------------------------
# Dozzle is run as a Docker container via systemd (no native binary —
# upstream publishes Docker images only). The value below pins the Docker
# image tag (amir20/dozzle:v$(DOZZLE_VERSION) — Docker Hub tags are
# v-prefixed; the `v` lives in dozzle.env/Makefile, the pin stays plain
# numeric so bump-versions.sh can match it). The dozzle-service make
# target sed-substitutes it into the deployed /etc/dozzle/dozzle.env;
# bumping invalidates the dozzle-service stamp so the next `make dev`
# re-renders the env file, re-pulls the image, and restarts the unit.
# Cockpit comes from dnf (see packages.mk) and isn't versioned here.
DOZZLE_VERSION := 10.10.0

# --- Fonts (dev_machine only, makefile target deposits to ~/.local/share/fonts) -
# JetBrainsMono Nerd Font Mono — the six Mono-variant TTFs from the
# ryanoasis/nerd-fonts release archive. Pinned alongside its SHA256 in
# makefile/lib/font.sh (per-version case branch) and mirrored in the Windows
# installer script (scripts/install-nerd-fonts.ps1) — bumping the pin requires
# editing all three. See the triple-edit invariant in CLAUDE.md.
JETBRAINSMONO_NERD_VERSION := 3.5.1

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
NNN_VERSION      := 5.3
FX_VERSION       := 39.2.0
GITLOGUE_VERSION := 0.11.0

# --- (2026-06) gap-fillers: search / data / diff / network / git-extras / util
# Added after a deep-research sweep over the toolbelt's remaining gaps. All are
# plain EGET_TOOL single-binary installs — per-tool asset/tag notes in tools.mk.
RIPGREP_VERSION    := 15.2.0
MILLER_VERSION     := 6.21.0
CSVLENS_VERSION    := 0.15.1
DIFFTASTIC_VERSION := 0.70.0
TRIPPY_VERSION     := 0.13.0
DOGGO_VERSION      := 1.4.0
SCC_VERSION        := 4.0.0
GIT_ABSORB_VERSION := 0.9.0
MINISERVE_VERSION  := 0.35.0
NUMBAT_VERSION     := 1.24.0
QSV_VERSION        := 22.0.1
GREX_VERSION       := 1.4.6
JLESS_VERSION      := 0.9.0

# --- (2026-06) tier-1 lint/security + system/util gap-fillers -----------------
# shfmt + gitleaks are ALSO enforced by scripts/check-invariants.sh (so they run
# in pre-commit + `make lint` + CI). Their pins are a DUAL-EDIT with
# .github/workflows/lint.yml, whose CI step installs these exact versions so the
# check actually enforces there (check-invariants soft-skips a missing tool).
# check-invariants.sh verifies the two stay in sync. procs is gnu-only (upstream
# publishes no musl build) but runs fine on the glibc-2.34 fleet.
SHFMT_VERSION    := 3.14.0
GITLEAKS_VERSION := 8.30.1
PROCS_VERSION    := 0.14.12
DUST_VERSION     := 1.2.5
HEXYL_VERSION    := 0.17.0
PUEUE_VERSION    := 4.0.4
GUM_VERSION      := 2.0.0

# --- (2026-06) C / C++ development & debugging toolchain ----------------------
# Most of the toolchain is dnf packages (see packages.mk: gcc-c++ / clang /
# clang-tools-extra [clangd+clang-tidy+clang-format] / llvm / lldb / valgrind /
# cppcheck / cmake / meson / ninja-build / heaptrack / sanitizer runtimes —
# best-effort, dev_machine only). The three pins below are managed here:
#   nnd     — from-scratch TUI debugger (al13n321/nnd). Raw single binary via
#             direct.sh, NOT eget: the release assets are bare `nnd` + a
#             `nnd-dbgo` variant with no os/arch tokens, so eget can't
#             auto-disambiguate. Both scopes. v-prefixed tag (v$(NND_VERSION)).
#   pwndbg  — GDB front-end; dev-only bespoke target installs the self-contained
#             portable tarball (makefile/lib/pwndbg.sh). Tag has NO `v` prefix.
#   vcpkg   — Microsoft C/C++ package manager; dev-only bespoke target git-clones
#             + bootstraps at this tag (makefile/lib/vcpkg.sh). Tag has NO `v`.
# GEF (the other GDB front-end) is a vendored chezmoi dotfile (gef.py + a tracked
# ~/.gdbinit), rolling upstream with no release tags — pinned by commit in its
# .vendor sidecar, so it has NO versions.mk entry (cf. batpipe / cht.sh).
NND_VERSION    := 0.80
PWNDBG_VERSION := 2026.07.29
VCPKG_VERSION  := 2026.07.29

# --- Blessed Python scripting env --------------------------------------------
# python-env — uv-managed CPython + one venv (~/.local/share/workstation-python)
# with the ad-hoc-scripting libs (Textual/Click/&c). Canonical lib list lives in
# lib/python-env.sh (PY_LIBS — parity pair with $PythonLibs in bootstrap.ps1).
# Libs track LATEST at install time; only the interpreter is pinned. DUAL-EDIT:
# $PythonEnvVersion in bootstrap.ps1 (Make never runs on Windows — Helix
# precedent; check-invariants.sh verifies). Bump only to a CPython with full
# wheel coverage for the lib set on BOTH platforms (cp/abi3 check on PyPI —
# duckdb + pydantic-core are the usual laggards). Registered in UPDATE_SPECS
# (python/cpython tags, tools.mk) but EXCLUDEd from auto-bump in
# bump-versions.sh — dual-edit + wheel-coverage check required, so `make
# check-updates` reports drift but the pin is bumped by hand.
PYTHON_VERSION := 3.14.7

# --- (2026-06) Language servers (LSP) + runtimes ------------------------------
# All dev_machine only (navigation is a dev activity; Claude Code is dev-only-
# deployed). Three are single-binary EGET_TOOL static servers (tools.mk,
# both-scope). The rest install via the bespoke `lsp-servers` target (Makefile):
# lua-language-server is a multi-file TREE (not a single binary, so NOT eget);
# basedpyright via `uv tool install` (self-contained PyPI build, bundles its own
# JS runtime); the four *-language-server npm packages via node-runtime's npm;
# gopls via `go install` against the new go-runtime. clangd is provisioned
# separately (clang-tools-extra, packages.mk) and only VERIFIED by lsp-servers.
GO_VERSION                 := 1.27.0
GOPLS_VERSION              := 0.23.0
RUST_ANALYZER_VERSION      := 2026-09-07
MARKSMAN_VERSION           := 2026-02-08
TAPLO_VERSION              := 0.10.0
LUA_LS_VERSION             := 3.19.1
BASEDPYRIGHT_VERSION       := 1.39.10
TYPESCRIPT_LS_VERSION      := 6.0.0
BASH_LS_VERSION            := 5.6.0
YAML_LS_VERSION            := 1.24.0
VSCODE_LANGSERVERS_VERSION := 4.10.0

# --- (2026-07) agent multiplexer (dev_machine only) --------------------------
# herdr — a tmux/zellij-like terminal multiplexer that is AWARE of AI coding-
# agent state (each pane rolls up to working/idle/blocked/done), with a socket/
# CLI API for orchestrating agents. dev_machine ONLY: it supervises coding
# agents and Claude Code itself is dev-only-deployed, so it has no place in the
# prod toolbelt. Single-binary GitHub release (bare per-platform assets; eget
# auto-selects herdr-linux-x86_64, verified), installed via a MODE-gated
# EGET_TOOL in tools.mk — the one scope tool that isn't both-scope. It does NOT
# replace zellij (kept as the general multiplexer); herdr is the agent-aware
# addition. NOTE: pre-1.0 and dual-licensed AGPL-3.0/commercial — bump the pin
# deliberately (breaking changes are likely before 1.0).
HERDR_VERSION := 0.8.2

# --- (2026-07) AI coding agents (dev_machine only) ----------------------------
# Two terminal coding agents joining claude-cli (the bespoke Makefile target) in
# the dev-only AI belt. Both are Bun-compiled single-binary GitHub releases,
# installed via MODE-gated EGET_TOOLs in tools.mk (herdr's pattern). Both pins
# DUAL-EDIT with $PortableTools in bootstrap.ps1 (the Windows halves) — enforced
# by check-invariants.sh; bump both sides together and refresh the Sha256 there.
# opencode — open-source coding agent (anomalyco/opencode; repo moved from
#   sst/opencode, old path 301s). CAVEAT: the plain linux-x64 asset REQUIRES
#   AVX2 (Intel 2013+/AMD 2015+). verify-binary.sh can't catch a SIGILL (it
#   never executes the binary) — on a pre-AVX2 host, flip the tools.mk filters
#   to select the `-baseline` asset instead.
# omp — "Oh My Pi" (can1357/oh-my-pi): the maintained, batteries-included hard
#   fork of Mario Zechner's Pi (LSP, DAP debugger, subagents, plan mode; Rust
#   core). It REPLACES Pi — upstream Pi is deliberately NOT installed. Bare
#   per-platform binary assets; eget names the download after the REPO
#   (oh-my-pi), so the tools.mk entry passes a trailing `--to $(DEST)/omp` to
#   force the command name (verified: the later --to wins).
OPENCODE_VERSION := 1.18.25
OMP_VERSION      := 18.0.11

# --- (2026-07) DevToys CLI (dev_machine only) ---------------------------------
# devtoys.cli — scriptable command-line half of DevToys (DevToys-app/DevToys):
# offline dev utilities (json<->yaml, base64, hash, jwt, ...). dev_machine
# ONLY. NOT an EGET_TOOL: the release zip is a self-contained single-file .NET
# executable PLUS a required sibling Plugins/ tree, so lib/devtoys-cli.sh
# extracts the whole tree and symlinks $(DEST)/devtoys.cli (bespoke Makefile
# target, pwndbg's shape). Always the *_portable.zip (self-contained) — the
# plain zip is framework-dependent (needs a system .NET 8 runtime).
# CAVEAT: every DevToys 2.x release is flagged prerelease:true, so GitHub's
# /releases/latest LIES for this repo (returns 2023's v1.0.13.0) — find the
# real newest tag on the releases PAGE. Tags are vX.Y.Z.0. The pin DUAL-EDITS
# with $PortableTools in bootstrap.ps1 (the Windows half; refresh its Sha256
# when bumping) — enforced by check-invariants.sh.
DEVTOYS_CLI_VERSION := 2.0.9.0
