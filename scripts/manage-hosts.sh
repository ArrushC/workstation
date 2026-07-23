#!/usr/bin/env bash
# =============================================================================
# scripts/manage-hosts.sh
#
# Menu-driven host manager. Reads and edits hosts.conf, the single source of
# truth for the fleet inventory.
#
# Provisioning consumes hosts.conf directly: bootstrap.sh self-registers
# this host into it, scripts/update-hosts.sh iterates over it for bulk
# multi-host updates, and on Windows bootstrap.ps1's Invoke-WarpTabConfigs
# regenerates the managed Warp Tab Configs (workstation-*.toml) from it on
# every run. No separate inventory file is generated.
#
# Usage (no args opens the interactive menu):
#   ./scripts/manage-hosts.sh
#   ./scripts/manage-hosts.sh --list
#   ./scripts/manage-hosts.sh --format
#   ./scripts/manage-hosts.sh --remove
#   ./scripts/manage-hosts.sh --add  --name N --ip I --user U --group G [--skip-confirm]
#   ./scripts/manage-hosts.sh --copy-id [--name N]
#   ./scripts/manage-hosts.sh --copy-id --all [--skip-confirm]
#
# This script is feature-paired with scripts/manage-hosts.ps1 — every
# capability (flags, prompts, post-add flow) MUST be kept in lockstep.
# =============================================================================

set -euo pipefail

# --- Resolve repo root -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTS_CONF="$REPO_ROOT/hosts.conf"

# Valid host groups. dev_machine → MODE=dev provisioning (sudo, system-wide);
# prod_machine → MODE=prod (no sudo, ~/.local/bin). makefile/scope.mk maps
# these groups to scope. An unknown group breaks update-hosts.sh's MODE
# derivation, so we reject anything else at save time.
VALID_GROUPS=("dev_machine" "prod_machine")

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log() { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok() { echo -e "${GREEN} ✓${RESET} $*"; }
warn() { echo -e "${YELLOW} !${RESET} $*"; }
fail() {
  echo -e "${RED} ✗${RESET} $*"
  exit 1
}
header() {
  echo -e "\n${BOLD}${CYAN}$*${RESET}"
  echo -e "${CYAN}$(printf '─%.0s' {1..50})${RESET}"
}

# =============================================================================
# PARSING
# =============================================================================

# Read hosts.conf and return non-comment, non-empty lines
read_hosts() {
  grep -v '^\s*#' "$HOSTS_CONF" | grep -v '^\s*$' || true
}

# Print a formatted table of current hosts
print_hosts() {
  local hosts
  hosts=$(read_hosts)

  if [[ -z "$hosts" ]]; then
    warn "No hosts configured yet."
    return
  fi

  # Calculate column widths from data; minimum = header label length.
  local w_name=4 w_ip=2 w_user=4 w_group=5
  local name ip user group
  while IFS= read -r line; do
    read -r name ip user group <<<"$line"
    ((${#name} > w_name)) && w_name=${#name}
    ((${#ip} > w_ip)) && w_ip=${#ip}
    ((${#user} > w_user)) && w_user=${#user}
    ((${#group} > w_group)) && w_group=${#group}
  done <<<"$hosts"

  printf "\n${BOLD}%-${w_name}s  %-${w_ip}s  %-${w_user}s  %-${w_group}s${RESET}\n" \
    "NAME" "IP" "USER" "GROUP"

  # ASCII separator with byte-exact widths (Unicode dashes break printf width math).
  local sep_name sep_ip sep_user sep_group
  sep_name=$(printf '%*s' "$w_name" '' | tr ' ' '-')
  sep_ip=$(printf '%*s' "$w_ip" '' | tr ' ' '-')
  sep_user=$(printf '%*s' "$w_user" '' | tr ' ' '-')
  sep_group=$(printf '%*s' "$w_group" '' | tr ' ' '-')
  printf "%s  %s  %s  %s\n" "$sep_name" "$sep_ip" "$sep_user" "$sep_group"

  while IFS= read -r line; do
    read -r name ip user group <<<"$line"
    printf "%-${w_name}s  %-${w_ip}s  %-${w_user}s  %-${w_group}s\n" \
      "$name" "$ip" "$user" "$group"
  done <<<"$hosts"
  echo ""
}

# Check if a host name already exists
host_exists() {
  local name="$1"
  read_hosts | awk '{print $1}' | grep -qx "$name" 2>/dev/null
}

# Validate a group name against VALID_GROUPS. Echos a comma-separated list
# of valid options on failure for the caller's error message.
is_valid_group() {
  local g="$1"
  local v
  for v in "${VALID_GROUPS[@]}"; do
    [[ "$g" == "$v" ]] && return 0
  done
  return 1
}

# Printed after any hosts.conf change. Nothing is generated on the Linux
# side; the Windows terminal entries (Warp Tab Configs) are regenerated from
# hosts.conf by bootstrap.ps1's Invoke-WarpTabConfigs. PARITY: manage-hosts.ps1
# prints the same note.
note_warp_refresh() {
  log "Warp Tab Configs (Windows) pick this up on the next bootstrap.ps1 run"
}

# =============================================================================
# SAVE & FORMAT
# =============================================================================

# Rewrites the data rows in hosts.conf with dynamically padded columns.
# Preserves header comments. Called by add, remove, edit, and format.
# Sorts rows by group (column 4) then name (column 1) so hosts.conf is
# always in deterministic order after a save.
save_hosts() {
  local sorted_lines
  sorted_lines=$(read_hosts | sort -k4,4 -k1,1)

  # Build arrays from sorted hosts
  local names=() ips=() users=() groups=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r n i u g <<<"$line"
    names+=("$n")
    ips+=("$i")
    users+=("$u")
    groups+=("$g")
  done <<<"$sorted_lines"

  # Calculate column widths (minimum widths enforced)
  local w_name=16 w_ip=14 w_user=10
  for n in "${names[@]}"; do ((${#n} > w_name)) && w_name=${#n}; done
  for i in "${ips[@]}"; do ((${#i} > w_ip)) && w_ip=${#i}; done
  for u in "${users[@]}"; do ((${#u} > w_user)) && w_user=${#u}; done

  local tmp
  tmp=$(mktemp)

  # Preserve only comment lines from the top of the file. Blank lines are
  # dropped — preserving them caused one more blank to accumulate on every save.
  local had_comments=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      echo "$line" >>"$tmp"
      had_comments=true
    elif [[ -z "$line" ]]; then
      continue
    else
      break
    fi
  done <"$HOSTS_CONF"

  # One blank separator between comment header and data, only if comments exist.
  [[ "$had_comments" == true ]] && echo "" >>"$tmp"

  # Write data rows with recalculated padding
  for idx in "${!names[@]}"; do
    printf "%-${w_name}s  %-${w_ip}s  %-${w_user}s  %s
" "${names[$idx]}" "${ips[$idx]}" "${users[$idx]}" "${groups[$idx]}" >>"$tmp"
  done

  mv "$tmp" "$HOSTS_CONF"
}

format_hosts() {
  local count
  count=$(read_hosts | wc -l | tr -d ' ')
  [[ "$count" -eq 0 ]] && {
    warn "No hosts to format."
    return
  }
  save_hosts
  ok "hosts.conf reformatted ($count hosts)"
}

# =============================================================================
# CRUD OPERATIONS
# =============================================================================

add_host() {
  # Supports two calling modes:
  #
  #   Interactive (menu or --add with no args):
  #     add_host
  #
  #   Non-interactive (from bootstrap.sh or other scripts):
  #     add_host --name dev-01 --ip 10.0.0.12 --user arrush --group prod_machine --skip-confirm
  #
  # Group MUST be one of VALID_GROUPS (dev_machine, prod_machine).
  local name="" ip="" user="" group="" skip_confirm=false

  # Parse named flags if any were passed
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --ip)
      ip="$2"
      shift 2
      ;;
    --user)
      user="$2"
      shift 2
      ;;
    --group)
      group="$2"
      shift 2
      ;;
    --skip-confirm)
      skip_confirm=true
      shift
      ;;
    *)
      warn "Unknown flag: $1"
      shift
      ;;
    esac
  done

  # If any required field is missing, fall into interactive prompts
  if [[ -z "$name" ]]; then
    header "Add a new host"
    read -rp "  Host name (e.g. dev-01):  " name
    [[ -z "$name" ]] && fail "Name cannot be empty"
  fi

  if host_exists "$name"; then
    warn "Host '$name' already exists in hosts.conf — skipping."
    return 0
  fi

  if [[ -z "$ip" ]]; then
    read -rp "  IP / hostname:                  " ip
    [[ -z "$ip" ]] && fail "IP cannot be empty"
  fi

  if [[ -z "$user" ]]; then
    local current_user lower_user upper_user choice custom_user
    current_user=$(whoami)
    lower_user="${current_user,,}"
    upper_user="${current_user^^}"

    echo ""
    echo "  SSH user options:"
    echo "    1) ${current_user}  (as-is)"
    echo "    2) ${lower_user}  (lowercase)"
    echo "    3) ${upper_user}  (uppercase)"
    echo "    4) custom"
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
    1) user="$current_user" ;;
    2) user="$lower_user" ;;
    3) user="$upper_user" ;;
    4)
      read -rp "  Custom username: " custom_user
      user="${custom_user:-$current_user}"
      ;;
    *)
      warn "Unknown choice — using as-is"
      user="$current_user"
      ;;
    esac
  fi

  if [[ -z "$group" ]]; then
    local group_choice
    echo ""
    echo "  Host group options:"
    echo "    1) prod_machine  (no sudo, user-wide — default)"
    echo "    2) dev_machine   (sudo, system-wide)"
    read -rp "  Choice [1]: " group_choice
    group_choice="${group_choice:-1}"

    case "$group_choice" in
    1) group="prod_machine" ;;
    2) group="dev_machine" ;;
    *) fail "Invalid choice '$group_choice'. Pick 1 or 2." ;;
    esac
  fi

  if ! is_valid_group "$group"; then
    fail "Invalid group '$group'. Must be one of: ${VALID_GROUPS[*]}"
  fi

  echo ""
  printf "  Adding: ${BOLD}%-20s %-18s %-14s %-14s${RESET}\n" "$name" "$ip" "$user" "$group"

  if [[ "$skip_confirm" == false ]]; then
    read -rp "  Confirm? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    [[ ! "$confirm" =~ ^[Yy]$ ]] && {
      warn "Aborted."
      return 0
    }
  fi

  # Append raw entry then reformat the whole file for consistent alignment
  printf "%s  %s  %s  %s\n" "$name" "$ip" "$user" "$group" >>"$HOSTS_CONF"
  save_hosts
  ok "Host '$name' added to hosts.conf"

  if [[ "$skip_confirm" == true ]]; then
    # Non-interactive default: don't copy keys.
    note_warp_refresh
    return
  fi

  echo ""
  read -rp "  Copy SSH key now? [y/N]: " copy_ans
  if [[ "$copy_ans" =~ ^[Yy]$ ]]; then
    copy_ssh_id "$name"
  fi

  note_warp_refresh
}

remove_host() {
  header "Remove a host"
  print_hosts

  local hosts
  hosts=$(read_hosts)
  [[ -z "$hosts" ]] && return

  read -rp "  Host name to remove: " name
  [[ -z "$name" ]] && return

  if ! host_exists "$name"; then
    warn "Host '$name' not found."
    return
  fi

  read -rp "  Remove '$name'? This cannot be undone. [y/N]: " confirm
  confirm="${confirm:-N}"

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Remove matching data line then reformat
    local tmp
    tmp=$(mktemp)
    grep -v "^${name}[[:space:]]" "$HOSTS_CONF" >"$tmp"
    mv "$tmp" "$HOSTS_CONF"
    save_hosts
    ok "Host '$name' removed from hosts.conf"
    note_warp_refresh
  else
    warn "Aborted."
  fi
}

edit_host() {
  header "Edit a host"
  print_hosts

  local hosts
  hosts=$(read_hosts)
  [[ -z "$hosts" ]] && return

  read -rp "  Host name to edit: " name
  [[ -z "$name" ]] && return

  if ! host_exists "$name"; then
    warn "Host '$name' not found."
    return
  fi

  # Get current values
  local current
  current=$(read_hosts | grep "^${name}[[:space:]]")
  local cur_ip cur_user cur_group
  read -r _ cur_ip cur_user cur_group <<<"$current"

  echo ""
  echo -e "  Current values (press Enter to keep):"

  read -rp "  IP / hostname [$cur_ip]:         " new_ip
  new_ip="${new_ip:-$cur_ip}"

  read -rp "  SSH user [$cur_user]:            " new_user
  new_user="${new_user:-$cur_user}"

  read -rp "  Host group [$cur_group]:      " new_group
  new_group="${new_group:-$cur_group}"

  if ! is_valid_group "$new_group"; then
    fail "Invalid group '$new_group'. Must be one of: ${VALID_GROUPS[*]}"
  fi

  echo ""
  printf "  Updated: ${BOLD}%-20s %-18s %-14s %-14s${RESET}\n" "$name" "$new_ip" "$new_user" "$new_group"
  read -rp "  Confirm? [Y/n]: " confirm
  confirm="${confirm:-Y}"

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Replace the matching line then reformat
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      if echo "$line" | grep -q "^${name}[[:space:]]"; then
        printf "%s  %s  %s  %s\n" "$name" "$new_ip" "$new_user" "$new_group"
      else
        echo "$line"
      fi
    done <"$HOSTS_CONF" >"$tmp"
    mv "$tmp" "$HOSTS_CONF"
    save_hosts
    ok "Host '$name' updated"
    note_warp_refresh
  else
    warn "Aborted."
  fi
}

# Ensure ~/.ssh/id_ed25519.pub exists; prompt to ssh-keygen if missing.
# Calls fail() if the user declines — single-host copy_ssh_id and bulk
# copy_ssh_id_all both rely on this happening exactly once at the top.
ensure_ssh_key() {
  local privkey="$HOME/.ssh/id_ed25519"
  local pubkey="$HOME/.ssh/id_ed25519.pub"

  [[ -f "$pubkey" ]] && return 0

  warn "No SSH key at $privkey"
  read -rp "  Generate one now? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$privkey" -N "" -C "$(whoami)@$(hostname -s)" ||
      fail "ssh-keygen failed"
    ok "Generated $privkey"
  else
    fail "Cannot copy without a key. Generate with: ssh-keygen -t ed25519"
  fi
}

# Push the local pubkey to <user>@<ip>. Returns 0 on success, non-zero on
# failure — caller decides whether to abort (single-host) or continue
# (bulk). Stderr/stdout are NOT swallowed so password prompts and useful
# error text still reach the user.
do_copy_ssh_id() {
  local user="$1" ip="$2"
  local pubkey="$HOME/.ssh/id_ed25519.pub"

  if command -v ssh-copy-id &>/dev/null; then
    ssh-copy-id -i "$pubkey" "${user}@${ip}"
  else
    # Manual fallback for distros without ssh-copy-id
    local key_content
    key_content=$(cat "$pubkey")
    ssh "${user}@${ip}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
echo '$key_content' >> ~/.ssh/authorized_keys && \
sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
chmod 600 ~/.ssh/authorized_keys"
  fi
}

copy_ssh_id() {
  local target="${1:-}"

  # Interactive picker if no name supplied
  if [[ -z "$target" ]]; then
    header "Copy SSH key to a host"
    print_hosts
    read -rp "  Host name: " target
    [[ -z "$target" ]] && {
      warn "Cancelled."
      return
    }
  fi

  if ! host_exists "$target"; then
    fail "Host '$target' not found in hosts.conf"
  fi

  local line user ip
  line=$(read_hosts | awk -v n="$target" '$1==n {print; exit}')
  read -r _ ip user _ <<<"$line"

  ensure_ssh_key

  log "Copying $HOME/.ssh/id_ed25519.pub to ${user}@${ip}..."
  if do_copy_ssh_id "$user" "$ip"; then
    ok "Key copied to ${user}@${ip}"
  else
    fail "Copy failed (check connectivity, password, sshd config)"
  fi
}

# Bulk: copy the local pubkey to every host in hosts.conf. Loop is
# deliberately best-effort — partial success is normal (some hosts offline,
# password fatigue, key already installed). Final summary lists failures.
copy_ssh_id_all() {
  local skip_confirm="${1:-false}"

  header "Copy SSH key to ALL hosts"

  local hosts
  hosts=$(read_hosts)
  if [[ -z "$hosts" ]]; then
    warn "No hosts in hosts.conf"
    return
  fi

  print_hosts

  local count
  count=$(echo "$hosts" | wc -l | tr -d ' ')

  if [[ "$skip_confirm" != "true" ]]; then
    read -rp "  Copy SSH key to all $count hosts? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    [[ ! "$confirm" =~ ^[Yy]$ ]] && {
      warn "Aborted."
      return
    }
  fi

  ensure_ssh_key
  echo ""

  local ok_count=0 fail_count=0
  local failed=()
  local name ip user
  while IFS= read -r line; do
    read -r name ip user _ <<<"$line"
    echo -ne "  ${BOLD}${name}${RESET} (${user}@${ip})... "
    if do_copy_ssh_id "$user" "$ip" >/dev/null 2>&1; then
      echo -e "${GREEN}✓${RESET}"
      ((ok_count++)) || true
    else
      echo -e "${RED}✗${RESET}"
      failed+=("$name")
      ((fail_count++)) || true
    fi
  done <<<"$hosts"

  echo ""
  ok "$ok_count host(s) successful"
  if ((fail_count > 0)); then
    warn "$fail_count host(s) failed: ${failed[*]}"
  fi
}

test_host() {
  header "Test SSH connection"
  print_hosts

  local hosts
  hosts=$(read_hosts)
  [[ -z "$hosts" ]] && return

  read -rp "  Host name to test (or 'all'): " name

  if [[ "$name" == "all" ]]; then
    while IFS= read -r line; do
      read -r hname hip huser _ <<<"$line"
      echo -ne "  Testing ${BOLD}$hname${RESET} ($huser@$hip)... "
      if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$huser@$hip" exit 2>/dev/null; then
        echo -e "${GREEN}✓ OK${RESET}"
      else
        echo -e "${RED}✗ Failed${RESET}"
      fi
    done <<<"$hosts"
  else
    if ! host_exists "$name"; then
      warn "Host '$name' not found."
      return
    fi
    local line
    line=$(read_hosts | grep "^${name}[[:space:]]")
    read -r hname hip huser _ <<<"$line"
    echo -ne "  Testing ${BOLD}$hname${RESET} ($huser@$hip)... "
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$huser@$hip" exit 2>/dev/null; then
      echo -e "${GREEN}✓ Connected successfully${RESET}"
    else
      echo -e "${RED}✗ Connection failed — check IP, user, and SSH key${RESET}"
    fi
  fi
}

# =============================================================================
# MENU
# =============================================================================

show_menu() {
  header "Workstation host manager"
  print_hosts
  echo -e "${BOLD}Pick an option:${RESET}"
  echo -e "  ${BOLD}1)${RESET} Add host"
  echo -e "  ${BOLD}2)${RESET} Remove host"
  echo -e "  ${BOLD}3)${RESET} Edit host"
  echo -e "  ${BOLD}4)${RESET} Test SSH connection"
  echo -e "  ${BOLD}5)${RESET} Copy SSH key"
  echo -e "  ${BOLD}6)${RESET} Copy SSH key to ALL hosts"
  echo -e "  ${BOLD}7)${RESET} View hosts.conf"
  echo -e "  ${BOLD}8)${RESET} Reformat hosts.conf"
  echo -e "  ${BOLD}q)${RESET} Quit"
  echo ""
  read -rp "Choice: " choice
  echo ""

  case "$choice" in
  1) add_host ;;
  2) remove_host ;;
  3) edit_host ;;
  4) test_host ;;
  5) copy_ssh_id ;;
  6) copy_ssh_id_all ;;
  7) cat "$HOSTS_CONF" ;;
  8) format_hosts ;;
  q | Q)
    echo "Bye."
    exit 0
    ;;
  *) warn "Unknown option: $choice" ;;
  esac
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

# Validate hosts.conf exists
[[ -f "$HOSTS_CONF" ]] || fail "hosts.conf not found at $HOSTS_CONF"

case "${1:-}" in
--list)
  print_hosts
  exit 0
  ;;
--format)
  format_hosts
  exit 0
  ;;
--add)
  shift
  add_host "$@"
  exit 0
  ;;
--remove)
  remove_host
  exit 0
  ;;
--copy-id)
  shift
  cid_name=""
  cid_all=false
  cid_skip_confirm=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      cid_name="$2"
      shift 2
      ;;
    --all)
      cid_all=true
      shift
      ;;
    --skip-confirm)
      cid_skip_confirm=true
      shift
      ;;
    *) shift ;;
    esac
  done
  if [[ "$cid_all" == true ]]; then
    # --all wins over --name if both are passed
    copy_ssh_id_all "$cid_skip_confirm"
  else
    copy_ssh_id "$cid_name"
  fi
  exit 0
  ;;
"")
  while true; do
    show_menu
  done
  ;;
*)
  echo "Usage: $0 [--list | --format | --remove"
  echo "          | --add [--name N --ip I --user U --group G --skip-confirm]"
  echo "          | --copy-id [--name N | --all [--skip-confirm]]]"
  exit 1
  ;;
esac
