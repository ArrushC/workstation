#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (Ansible seed)
#
# Two modes — both delegate ALL tool installs to Ansible:
#
#   FULL (sudo, system-wide install to /usr/local/bin):
#     ./bootstrap.sh --full
#
#   USER (no sudo, install to ~/.local/bin):
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#     or: ./bootstrap.sh
#
# This script does the bare minimum needed to hand off to Ansible:
#   - clone the repo
#   - install ansible-core via pip3 --user (if missing)
#   - run ansible/playbooks/local.yml against this machine
#
# Tool versions, URLs, and install logic live in
#   ansible/group_vars/all.yml + ansible/roles/rhel-base/tasks/tools.yml
# — there is no longer a duplicate set of versions in this script.
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

MODE="${1:-user}"

# --- Prereqs -----------------------------------------------------------------
log "Checking prerequisites..."
command -v curl    &>/dev/null || fail "curl is required"
command -v git     &>/dev/null || fail "git is required"
command -v python3 &>/dev/null || fail "python3 is required (used to install ansible-core)"

mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# --- Repo --------------------------------------------------------------------
if [[ ! -d "$CHEZMOI_SOURCE/.git" ]]; then
  log "Cloning workstation repo into $CHEZMOI_SOURCE..."
  git clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE"
  ok "Repo cloned"
else
  log "Repo already present at $CHEZMOI_SOURCE — pulling latest..."
  git -C "$CHEZMOI_SOURCE" pull --ff-only \
    || warn "Could not fast-forward — continuing with current state"
fi

# --- Seed Ansible (user-space) if missing ------------------------------------
if ! command -v ansible-playbook &>/dev/null; then
  log "Installing ansible-core via pip3 --user..."
  python3 -m pip install --user --upgrade ansible-core
  ok "ansible-core installed"
else
  ok "ansible-playbook already on PATH"
fi

# --- Hand off to Ansible -----------------------------------------------------
cd "$CHEZMOI_SOURCE/ansible"

if [[ "$MODE" == "--full" ]]; then
  log "Full mode — system-wide install (sudo)"
  ansible-playbook playbooks/local.yml \
    -e "tool_scope=system has_sudo=true" \
    --ask-become-pass
else
  log "User mode — installing to ~/.local/bin (no sudo)"
  ansible-playbook playbooks/local.yml \
    -e "tool_scope=user has_sudo=false install_system_packages=false"
fi

# =============================================================================
# SELF-REGISTER — add this VM to hosts.conf if not already present
# =============================================================================
register_host() {
  local manage_script="$CHEZMOI_SOURCE/scripts/manage-hosts.sh"

  if [[ ! -x "$manage_script" ]]; then
    warn "manage-hosts.sh not found at $manage_script — skipping self-registration."
    return
  fi

  local vm_name vm_ip vm_user
  vm_name=$(hostname -s 2>/dev/null || hostname)
  vm_user=$(whoami)

  vm_ip=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

  if [[ -z "$vm_ip" ]]; then
    vm_ip=$(ip addr show 2>/dev/null \
      | awk '/inet / && !/127\.0\.0\.1/ {split($2,a,"/"); print a[1]}' | head -1)
  fi

  if [[ -z "$vm_ip" ]]; then
    warn "Could not detect IP address — skipping self-registration."
    return
  fi

  log "Self-registration: ${vm_name} (${vm_user}@${vm_ip})"
  bash "$manage_script" --add \
    --name  "$vm_name" \
    --ip    "$vm_ip" \
    --user  "$vm_user" \
    --group "rhel_vms" \
    --skip-confirm
}

register_host

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
echo -e "Re-source your shell: ${YELLOW}source ~/.bashrc${RESET}"
