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
# Flow (both modes):
#   1. preflight             — check curl/git/python3/pip/iproute, python>=3.9
#   2. clone repo            — into ~/.local/share/chezmoi (or git pull if present)
#   3. self_register         — add this VM to hosts.conf + sync inventory
#   4. ensure_ansible        — pip install --user ansible-core if missing, smoke test
#   5. run playbook          — ansible-playbook playbooks/local.yml
#   6. push_host_changes     — commit+push hosts.conf updates (warn-don't-fail)
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

# =============================================================================
# 1. PREFLIGHT — collect-all prereq check, python version + pip module gate
# =============================================================================
preflight() {
  log "Checking prerequisites..."

  local missing=()
  command -v curl    &>/dev/null || missing+=("curl")
  command -v git     &>/dev/null || missing+=("git")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v ip      &>/dev/null || missing+=("iproute (for self-registration)")

  if (( ${#missing[@]} > 0 )); then
    fail "Missing required prerequisites: ${missing[*]}
Install with: sudo dnf install curl git python3 python3-pip iproute"
  fi

  # python3 -m pip available?
  if ! python3 -m pip --version &>/dev/null; then
    fail "python3 has no pip module. Install with: sudo dnf install python3-pip"
  fi

  # python3 >= 3.9 (ansible-core requirement)
  local py_ver py_major py_minor
  py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  IFS='.' read -r py_major py_minor <<< "$py_ver"
  if (( py_major < 3 )) || (( py_major == 3 && py_minor < 9 )); then
    fail "python3 >= 3.9 required for ansible-core (found $py_ver)"
  fi

  ok "Prerequisites OK (python $py_ver)"
}

# =============================================================================
# 2. SELF-REGISTER — add this VM to hosts.conf + regenerate inventory
# =============================================================================
self_register() {
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

  # Regenerate inventory + wezterm block from the (possibly) updated hosts.conf
  # so anything Ansible/chezmoi consumes downstream sees the current list.
  bash "$manage_script" --sync
}

# =============================================================================
# 3. ENSURE ANSIBLE — install ansible-core via pip if missing, smoke-test
# =============================================================================
ensure_ansible() {
  if command -v ansible-playbook &>/dev/null; then
    ok "ansible-playbook already on PATH"
    return
  fi

  log "Installing ansible-core via pip3 --user..."
  python3 -m pip install --user --upgrade ansible-core

  # pip might have just dropped the binary somewhere not yet on PATH
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v ansible-playbook &>/dev/null; then
    fail "ansible-playbook not on PATH after pip install.
Add ~/.local/bin to PATH and re-run: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  ok "ansible-playbook: $(ansible-playbook --version 2>/dev/null | head -1)"
}

# =============================================================================
# 4. RUN PLAYBOOK — hand off to Ansible (mode-specific overrides)
# =============================================================================
run_playbook() {
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
}

# =============================================================================
# 5. PUSH HOST CHANGES — commit hosts.conf + inventory + wezterm, push upstream
#    Warn-don't-fail: the playbook already succeeded, so we never abort here.
# =============================================================================
push_host_changes() {
  cd "$CHEZMOI_SOURCE"

  # Anything to commit (working tree OR already-staged)?
  if git diff --quiet hosts.conf ansible/inventory/hosts.ini wezterm.lua 2>/dev/null \
     && git diff --cached --quiet hosts.conf ansible/inventory/hosts.ini wezterm.lua 2>/dev/null; then
    log "No host-list changes to commit"
    return 0
  fi

  log "Committing host registration..."
  git add hosts.conf ansible/inventory/hosts.ini wezterm.lua 2>/dev/null || true

  # Use a deterministic identity if user.name/email aren't configured yet,
  # so commit doesn't fail with "please tell me who you are".
  local cfg_args=()
  git config user.name  >/dev/null 2>&1 || cfg_args+=(-c "user.name=$(whoami)")
  git config user.email >/dev/null 2>&1 || cfg_args+=(-c "user.email=$(whoami)@$(hostname)")

  if ! git "${cfg_args[@]}" commit -m "chore(hosts): register $(hostname -s)" 2>/dev/null; then
    warn "Commit failed — inspect with:  cd $CHEZMOI_SOURCE && git status"
    return 0
  fi

  log "Pushing host registration..."
  if git push 2>/dev/null; then
    ok "Host registration pushed"
  else
    warn "Push failed (auth, conflict, or no upstream). Recover with:"
    warn "  cd $CHEZMOI_SOURCE && git push"
  fi
}

# =============================================================================
# MAIN
# =============================================================================
preflight
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

self_register
ensure_ansible
run_playbook
push_host_changes

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
echo -e "Re-source your shell: ${YELLOW}source ~/.bashrc${RESET}"
echo -e "Enable passwordless SSH from your client:"
echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux/RHEL)"
echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
