#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup
#
# Two modes:
#
#   FULL (Ansible + chezmoi) — use when you have sudo and Ansible installed:
#     ./bootstrap.sh --full
#
#   USER ONLY (chezmoi + static binaries, no sudo) — use on any VM:
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#     or: ./bootstrap.sh
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo -e "${GREEN} ✓${RESET} $*"; }
warn() { echo -e "${YELLOW} !${RESET} $*"; }
fail() { echo -e "${RED} ✗${RESET} $*"; exit 1; }

DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
CHEZMOI_SOURCE="$HOME/.local/share/chezmoi"
BIN="$HOME/.local/bin"

FZF_VERSION="0.54.0"
ZOXIDE_VERSION="0.9.4"
STARSHIP_VERSION="1.19.0"
ZELLIJ_VERSION="0.40.1"
GLOW_VERSION="1.5.1"
HELIX_VERSION="24.03"
ARCH="x86_64"

MODE="${1:-user}"

log "Checking environment..."
command -v curl &>/dev/null || fail "curl is required"
command -v git  &>/dev/null || fail "git is required"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# =============================================================================
# FULL MODE — Ansible handles system packages then applies chezmoi
# =============================================================================
if [[ "$MODE" == "--full" ]]; then
  log "Full mode: running Ansible playbook..."
  command -v ansible-playbook &>/dev/null \
    || fail "ansible-playbook not found. Install with: pip3 install --user ansible"

  if [[ ! -d "$CHEZMOI_SOURCE/.git" ]]; then
    git clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE"
  fi

  cd "$CHEZMOI_SOURCE/ansible"
  ansible-playbook playbooks/rhel.yml \
    -i inventory/hosts.ini \
    --ask-become-pass

  ok "Full provisioning complete"
  exit 0
fi

# =============================================================================
# USER MODE — static binaries + chezmoi, no sudo required
# =============================================================================
log "User mode: installing tools to ~/.local/bin (no sudo required)"

install_tar() {
  local name="$1" url="$2" binary_path="$3"
  if [[ -x "$BIN/$name" ]]; then warn "$name already installed, skipping"; return; fi
  log "Installing $name..."
  local tmp; tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  cp "$tmp/$binary_path" "$BIN/$name"
  chmod +x "$BIN/$name"
  rm -rf "$tmp"
  ok "$name installed"
}

install_tar "fzf"     "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" "fzf"
install_tar "zoxide"  "https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" "zoxide"
install_tar "starship" "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${ARCH}-unknown-linux-musl.tar.gz" "starship"
install_tar "zellij"  "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${ARCH}-unknown-linux-musl.tar.gz" "zellij"
install_tar "glow"    "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_x86_64.tar.gz" "glow"

if [[ ! -x "$BIN/nb" ]]; then
  log "Installing nb..."
  curl -fsSL "https://raw.githubusercontent.com/xwmx/nb/master/nb" -o "$BIN/nb"
  chmod +x "$BIN/nb"
  ok "nb installed"
else warn "nb already installed, skipping"; fi

if [[ ! -x "$BIN/hx" ]]; then
  log "Installing helix..."
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-${ARCH}-linux.tar.xz" \
    | tar -xJ -C "$tmp"
  cp "$tmp/helix-${HELIX_VERSION}-${ARCH}-linux/hx" "$BIN/hx"
  mkdir -p "$HOME/.config/helix"
  cp -r "$tmp/helix-${HELIX_VERSION}-${ARCH}-linux/runtime" "$HOME/.config/helix/runtime"
  rm -rf "$tmp"
  ok "helix installed"
else warn "helix already installed, skipping"; fi

if [[ ! -x "$BIN/chezmoi" ]]; then
  log "Installing chezmoi..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$BIN"
  ok "chezmoi installed"
else warn "chezmoi already installed, skipping"; fi

log "Applying dotfiles via chezmoi..."
if [[ -d "$CHEZMOI_SOURCE/.git" ]]; then
  "$BIN/chezmoi" update --apply --source "$CHEZMOI_SOURCE"
  ok "Dotfiles updated"
else
  "$BIN/chezmoi" init --apply --source "$CHEZMOI_SOURCE" "$DOTFILES_REPO"
  ok "Dotfiles applied"
fi

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
echo -e "Re-source your shell: ${YELLOW}source ~/.bashrc${RESET}"
