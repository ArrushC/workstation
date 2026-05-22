#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (Ansible seed)
#
# Exactly one of --dev or --prod is required — it decides both the inventory
# group this host registers as AND the scope the local playbook runs in:
#
#   DEV  (host you own, sudo, system-wide install to /usr/local/bin):
#     ./bootstrap.sh --dev
#
#   PROD (host you don't fully own, no sudo, install to ~/.local/bin):
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod
#     or: ./bootstrap.sh --prod
#
# The scope values come from ansible/group_vars/{dev,prod}_machine.yml —
# the same files the remote linux.yml playbook uses, so a host configured
# locally and a host configured remotely end up identical.
#
# REINSTALL — wipe the cloned repo + chezmoi config, then re-bootstrap fresh.
# Does NOT remove installed tools or deployed dotfiles (those are idempotent
# under re-bootstrap). Combine with --dev/--prod and optional --yes:
#
#     ./bootstrap.sh --prod --reinstall          # prod-scope wipe + rebuild, prompts
#     ./bootstrap.sh --dev --reinstall --yes
#
# PRIVATE REPO + commit attribution — set GITHUB_TOKEN, GIT_USER_NAME, and
# GIT_USER_EMAIL before running. The token is used for both the bootstrap.sh
# fetch AND the script's internal git clone/pull/push; the name/email drive
# the auto-registration commit's author identity.
#
#   export GITHUB_TOKEN='<your-PAT>' \
#          GIT_USER_NAME='Arrush Chaturvedi' \
#          GIT_USER_EMAIL='contact@arrushc.com'
#   curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
#     https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#
# Flow (both modes):
#   1. preflight             — check curl/git/python3/pip/iproute, python>=3.9
#   2. clone repo            — into ~/.local/share/chezmoi (or git pull if present)
#   3. self_register         — add this host to hosts.conf + sync inventory
#                              (auto-skipped inside WSL — see is_wsl below)
#   4. ensure_ansible        — pip install --user ansible-core if missing, smoke test
#   5. run playbook          — ansible-playbook playbooks/local.yml
#   6. push_host_changes     — commit+push hosts.conf updates (warn-don't-fail)
#                              (no-op inside WSL since self_register made no edits)
#
# WSL — running inside a WSL distro is supported and treated as a managed host
# for tools + dotfiles, but NOT as an SSH target. is_wsl() (defined below)
# detects WSL via $WSL_DISTRO_NAME or /proc/version's microsoft marker and
# short-circuits self_register so hosts.conf and the wezterm SSH-domain block
# are never touched. The end-of-bootstrap copy-id tip is also suppressed.
#
# Tool versions, URLs, and install logic live in
#   ansible/group_vars/all.yml + ansible/roles/linux-base/tasks/tools.yml
# — there is no longer a duplicate set of versions in this script.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo -e "${GREEN} ✓${RESET} $*"; }
warn() { echo -e "${YELLOW} !${RESET} $*"; }
fail() { echo -e "${RED} ✗${RESET} $*"; exit 1; }

# WSL detection — used to skip hosts.conf self-registration and the SSH
# copy-id tip. WSL distros are accessed via wezterm WSL domains (not SSH),
# so registering them as SSH targets would pollute the inventory with an
# IP that's only reachable from the host Windows machine and would also
# create a redundant wezterm SSH-domain entry alongside the WSL one.
#   - WSL_DISTRO_NAME is exported by WSL 2 inside the distro
#   - /proc/version's "microsoft" marker is the universal backup signal
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
CHEZMOI_SOURCE="$HOME/.local/share/chezmoi"
BIN="$HOME/.local/bin"

# http.extraheader key scoped to github.com so the token never leaks to
# other remotes. Stored in the cloned repo's .git/config so subsequent
# git push, `chezmoi update`, and manual git ops all authenticate.
GH_HEADER_KEY="http.https://github.com/.extraheader"

# --- Argument parsing -------------------------------------------------------
# Accepts in any order: --dev | --prod (exactly one required), --reinstall, --yes/-y
MACHINE_TYPE=""
REINSTALL=false
YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
      MACHINE_TYPE="dev"; shift ;;
    --prod)
      [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
      MACHINE_TYPE="prod"; shift ;;
    --full)
      fail "--full was removed.

Use one of the new mutually-exclusive flags:
  ./bootstrap.sh --dev      # Host you own        — sudo, /usr/local/bin + system packages
  ./bootstrap.sh --prod     # Host you don't own  — no sudo, ~/.local/bin only

Run ./bootstrap.sh --help for the full flag list." ;;
    --reinstall) REINSTALL=true; shift ;;
    --yes|-y)    YES=true;       shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./bootstrap.sh (--dev | --prod) [flags]

Required (exactly one):
  --dev         Host you own. Sudo available. Installs system-wide to
                /usr/local/bin and pulls system packages via the OS package
                manager (dnf on RHEL/Fedora today). Registers as group
                dev_machine.
  --prod        Host you don't fully own. No sudo. Installs user-wide to
                ~/.local/bin. Registers as group prod_machine.

Optional flags:
  --reinstall   Wipe the cloned repo and chezmoi config, then bootstrap
                fresh. Does NOT remove installed tools or deployed
                dotfiles (those are no-op idempotent on re-bootstrap).
  --yes, -y     Skip the --reinstall confirmation prompt.
  -h, --help    Show this message.
EOF
      exit 0
      ;;
    *) fail "Unknown argument: $1 (try --help)" ;;
  esac
done

if [[ -z "$MACHINE_TYPE" ]]; then
  fail "Missing required flag: --dev or --prod.

Pick one based on the host you're bootstrapping:
  ./bootstrap.sh --dev      # Host you own        — sudo, /usr/local/bin + system packages
  ./bootstrap.sh --prod     # Host you don't own  — no sudo, ~/.local/bin only

Curl-pipe form (private repo with token):
  curl -fsSL -H \"Authorization: token \$GITHUB_TOKEN\" \\
    https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod

Run ./bootstrap.sh --help for all flags."
fi

# Derived values used by self_register and run_playbook
GROUP_NAME="${MACHINE_TYPE}_machine"
GROUP_VARS_FILE="group_vars/${GROUP_NAME}.yml"

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + chezmoi config, then let
#    the rest of the script re-bootstrap fresh. Installed tools and deployed
#    dotfiles are left alone — re-running the bootstrap is idempotent on
#    those, so the net effect is a fresh repo + fresh chezmoi init prompt.
# =============================================================================
do_reinstall() {
  log "Reinstall mode — wipe + re-bootstrap"
  echo ""
  echo "  Will REMOVE:"
  echo "    - $CHEZMOI_SOURCE   (cloned workstation repo)"
  echo "    - $HOME/.config/chezmoi/    (chezmoi config + cached init data)"
  echo ""
  echo "  Will NOT remove (leaving for re-bootstrap to no-op over):"
  echo "    - Installed tools in ~/.local/bin or /usr/local/bin"
  echo "    - dnf packages, ansible-core, SSH keys"
  echo "    - Deployed dotfiles in \$HOME (chezmoi will re-apply over them)"
  echo ""
  echo "  For a deeper uninstall (remove tools too), do that manually first:"
  echo "    rm -f ~/.local/bin/{fzf,zoxide,starship,zellij,glow,hx,nb,chezmoi}"
  echo "    sudo rm -f /usr/local/bin/{fzf,zoxide,starship,zellij,glow,hx,nb,chezmoi}"
  echo ""

  # Self-deletion guard: if this script is being run from inside the path
  # we're about to delete, refuse. Use the curl-pipe form instead — it
  # streams the script body through bash without backing it on disk.
  local script_path="${BASH_SOURCE[0]}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_real
    script_real=$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")
    if [[ "$script_real" == "$CHEZMOI_SOURCE"* ]]; then
      fail "Refusing to reinstall — running script is inside $CHEZMOI_SOURCE.
Either pipe the remote script (runs from memory):
  curl -fsSL -H \"Authorization: token \$GITHUB_TOKEN\" \\
    https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --${MACHINE_TYPE} --reinstall

Or copy this script out of the repo first:
  cp $script_real /tmp/bootstrap.sh && bash /tmp/bootstrap.sh --${MACHINE_TYPE} --reinstall"
    fi
  fi

  if [[ "$YES" != true ]]; then
    read -rp "  Proceed? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "Aborted."
      exit 0
    fi
  fi

  if [[ -d "$CHEZMOI_SOURCE" ]]; then
    log "Removing $CHEZMOI_SOURCE..."
    rm -rf "$CHEZMOI_SOURCE"
    ok "Repo removed"
  else
    log "$CHEZMOI_SOURCE not present — nothing to remove"
  fi

  if [[ -d "$HOME/.config/chezmoi" ]]; then
    log "Removing $HOME/.config/chezmoi/..."
    rm -rf "$HOME/.config/chezmoi"
    ok "chezmoi config removed"
  else
    log "$HOME/.config/chezmoi/ not present — nothing to remove"
  fi

  echo ""
  log "Wipe complete — continuing with fresh bootstrap..."
  echo ""
}

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
Install via your distro's package manager, e.g.
  RHEL/Fedora:   sudo dnf install curl git python3 python3-pip iproute
  Debian/Ubuntu: sudo apt install curl git python3 python3-pip iproute2"
  fi

  # python3 -m pip available?
  if ! python3 -m pip --version &>/dev/null; then
    fail "python3 has no pip module. Install via your distro's package manager
(RHEL/Fedora: sudo dnf install python3-pip; Debian/Ubuntu: sudo apt install python3-pip)"
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
# 2. SELF-REGISTER — add this host to hosts.conf + regenerate inventory
# =============================================================================
self_register() {
  # WSL distros are accessed via wezterm WSL domains, not SSH. Registering
  # them in hosts.conf would (a) add an SSH-domain entry to wezterm.lua that
  # duplicates the existing WSL domain, and (b) record a WSL-internal IP
  # that's only reachable from the host Windows machine. Skip.
  if is_wsl; then
    log "Detected WSL (${WSL_DISTRO_NAME:-via /proc/version}) — skipping hosts.conf self-registration"
    ok "WSL is reached through wezterm WSL domains, not SSH"
    return
  fi

  local manage_script="$CHEZMOI_SOURCE/scripts/manage-hosts.sh"

  # We invoke via `bash "$manage_script"` below, so the executable bit isn't
  # required — just the file. -x would skip on any clone where git didn't
  # preserve mode 0755 (Windows checkouts, fresh clones with core.filemode=false).
  if [[ ! -f "$manage_script" ]]; then
    warn "manage-hosts.sh not found at $manage_script — skipping self-registration."
    return
  fi

  local host_name host_ip host_user
  host_name=$(hostname -s 2>/dev/null || hostname)
  host_user=$(whoami)

  host_ip=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

  if [[ -z "$host_ip" ]]; then
    host_ip=$(ip addr show 2>/dev/null \
      | awk '/inet / && !/127\.0\.0\.1/ {split($2,a,"/"); print a[1]}' | head -1)
  fi

  if [[ -z "$host_ip" ]]; then
    warn "Could not detect IP address — skipping self-registration."
    return
  fi

  log "Self-registration: ${host_name} (${host_user}@${host_ip}) as ${GROUP_NAME}"
  # --add already runs sync_all on success, so don't double-sync here —
  # any Ansible/chezmoi step that reads hosts.conf downstream sees the
  # current inventory + wezterm block from the single --add pass.
  bash "$manage_script" --add \
    --name  "$host_name" \
    --ip    "$host_ip" \
    --user  "$host_user" \
    --group "$GROUP_NAME" \
    --skip-confirm
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

  if [[ "$MACHINE_TYPE" == "dev" ]]; then
    log "Dev mode — system-wide install (sudo) from ${GROUP_VARS_FILE}"
    ansible-playbook playbooks/local.yml \
      -e "@${GROUP_VARS_FILE}" \
      --ask-become-pass
  else
    log "Prod mode — user-scope install (no sudo) from ${GROUP_VARS_FILE}"
    ansible-playbook playbooks/local.yml \
      -e "@${GROUP_VARS_FILE}"
  fi
}

# =============================================================================
# 5. PUSH HOST CHANGES — commit hosts.conf + inventory + wezterm, push upstream
#    Warn-don't-fail: the playbook already succeeded, so we never abort here.
# =============================================================================
push_host_changes() {
  cd "$CHEZMOI_SOURCE"

  # Anything to commit (working tree OR already-staged)?
  if git diff --quiet hosts.conf ansible/inventory/hosts.ini chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null \
     && git diff --cached --quiet hosts.conf ansible/inventory/hosts.ini chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null; then
    log "No host-list changes to commit"
    return 0
  fi

  log "Committing host registration..."
  git add hosts.conf ansible/inventory/hosts.ini chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null || true

  # Identity priority for the auto-commit:
  #   1. GIT_USER_NAME / GIT_USER_EMAIL env vars (set in the bootstrap one-liner)
  #   2. Existing git config (e.g. ~/.gitconfig already populated by chezmoi)
  #   3. Synthetic fallback (whoami@hostname) so the commit never fails outright
  local cfg_args=()
  if [[ -n "${GIT_USER_NAME:-}" ]]; then
    cfg_args+=(-c "user.name=$GIT_USER_NAME")
  elif ! git config user.name >/dev/null 2>&1; then
    cfg_args+=(-c "user.name=$(whoami)")
  fi
  if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    cfg_args+=(-c "user.email=$GIT_USER_EMAIL")
  elif ! git config user.email >/dev/null 2>&1; then
    cfg_args+=(-c "user.email=$(whoami)@$(hostname)")
  fi

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
if [[ "$REINSTALL" == true ]]; then
  do_reinstall
fi
preflight
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# --- Repo --------------------------------------------------------------------
# If GITHUB_TOKEN is set, use it via http.extraheader (scoped to github.com).
# This works for both public and private repos. The token is persisted into
# the cloned repo's .git/config so push, pull, and chezmoi update all auth.
#
# We use HTTP Basic with a base64-encoded "x-access-token:<PAT>" pair — the
# same scheme GitHub Actions' `actions/checkout` uses. `Authorization: bearer`
# works for the REST/raw API (and that's how curl fetches bootstrap.sh) but
# is NOT accepted by git's smart-HTTP endpoint on github.com — GitHub falls
# through to credential prompting, which breaks any non-interactive clone.
GH_HEADER_VAL=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  GH_HEADER_B64=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
  GH_HEADER_VAL="Authorization: Basic $GH_HEADER_B64"
fi

if [[ ! -d "$CHEZMOI_SOURCE/.git" ]]; then
  log "Cloning workstation repo into $CHEZMOI_SOURCE..."
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -c "${GH_HEADER_KEY}=${GH_HEADER_VAL}" clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE" \
      || fail "Clone failed. For a private repo, set GITHUB_TOKEN to a PAT with repo read access."
    git -C "$CHEZMOI_SOURCE" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  else
    git clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE" \
      || fail "Clone failed. If the repo is private, set GITHUB_TOKEN and re-run."
  fi
  ok "Repo cloned"
else
  log "Repo already present at $CHEZMOI_SOURCE — pulling latest..."
  # Refresh the stored token if a new one was passed in this invocation.
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -C "$CHEZMOI_SOURCE" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  fi
  # A failed pull means we'd run Ansible against a stale-or-broken tree —
  # better to bail out and let the user inspect.
  if ! git -C "$CHEZMOI_SOURCE" pull --ff-only; then
    fail "git pull --ff-only failed in $CHEZMOI_SOURCE.
This usually means stale credentials in .git/config, or local commits/conflicts.
Inspect with:
  cd $CHEZMOI_SOURCE && git status && git log --oneline -5

To start over from scratch (wipes the cloned repo, not your tools/dotfiles):
  ./bootstrap.sh --${MACHINE_TYPE} --reinstall"
  fi
fi

self_register
ensure_ansible
run_playbook
push_host_changes

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"
echo -e "Re-source your shell: ${YELLOW}source ~/.bashrc${RESET}"
if is_wsl; then
  echo -e "Running inside WSL — opening a new WezTerm WSL tab will land you in"
  echo -e "  ${YELLOW}~${RESET} with starship + the chezmoi-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux)"
  echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
fi
