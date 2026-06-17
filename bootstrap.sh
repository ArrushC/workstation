#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (Make seed)
#
# Exactly one of --dev or --prod is required — it picks both the hosts.conf
# group this host registers as AND the scope `make provision` runs in:
#
#   DEV  (host you own, sudo, system-wide install to /usr/local/bin):
#     ./bootstrap.sh --dev
#
#   PROD (host you don't fully own, no sudo, install to ~/.local/bin):
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod
#     or: ./bootstrap.sh --prod
#
# The scope-aware facts (DEST, SUDO, HAS_SUDO, INSTALL_PACKAGES) are
# resolved from MODE=dev|prod by makefile/scope.mk. Same resolution
# happens whether you bootstrap locally or update remotely via
# scripts/update-hosts.sh.
#
# REINSTALL — wipe the cloned repo + chezmoi config, then re-bootstrap fresh.
# Does NOT remove installed tools or deployed dotfiles (those are idempotent
# under re-bootstrap). Combine with --dev/--prod and optional --yes:
#
#     ./bootstrap.sh --prod --reinstall          # prod-scope wipe + rebuild, prompts
#     ./bootstrap.sh --dev --reinstall --yes
#
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes that exit before any
# provisioning happens (nothing is cloned, installed, registered, or pushed):
#
#     ./bootstrap.sh --dev --doctor              # health: tools, services, repo, chezmoi
#     ./bootstrap.sh --dev --check-for-updates   # repo first, then pins vs upstream tags
#
# Per the thin-seed rule, all per-tool knowledge stays in makefile/ — these
# modes front `make doctor` / `make check-updates` with the repo-level checks
# (prereqs, git branch/ahead/behind/dirty, chezmoi init + drift, login shell).
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
#   1. preflight             — check curl/git/make/tar/unzip/iproute
#   2. clone repo            — into ~/.local/share/chezmoi (or git pull if present)
#   3. self_register         — add this host to hosts.conf + sync wezterm block
#                              (auto-skipped inside WSL — see is_wsl below)
#   4. run_make              — `make MODE=<dev|prod> provision` inside makefile/
#                              (packages + tools + shell + dotfiles in one pass)
#   4b. ensure_chezmoi_initialized — `chezmoi init --apply` interactively if
#                              ~/.config/chezmoi/chezmoi.toml is missing. The
#                              `chezmoi update` invoked by makefile/dotfiles.mk
#                              can't prompt (no TTY in make recipes), so this
#                              closes the first-run gap with stdin from /dev/tty.
#   4c. set_default_shell    — `sudo usermod -s "$(command -v zsh)" "$USER"`
#                              on --dev only. The chezmoi-tracked rc lives at
#                              ~/.zshrc; we switch the login shell so new
#                              WezTerm/SSH sessions land in zsh. Best-effort:
#                              prints the manual chsh command on prod or
#                              when usermod isn't permitted.
#   5. push_host_changes     — commit+push hosts.conf updates (warn-don't-fail)
#                              (no-op inside WSL since self_register made no edits)
#
# WSL — running inside a WSL distro is supported and treated as a managed host
# for tools + dotfiles, but NOT as an SSH target. is_wsl() (defined below)
# detects WSL via $WSL_DISTRO_NAME or /proc/version's microsoft marker and
# short-circuits self_register so hosts.conf and the wezterm SSH-domain block
# are never touched. The end-of-bootstrap copy-id tip is also suppressed.
#
# Tool versions, URLs, dnf packages, PATH wiring, chezmoi orchestration —
# everything lives under makefile/ (versions.mk, tools.mk, packages.mk,
# shell.mk, dotfiles.mk, lib/*.sh). bootstrap.sh has no per-tool knowledge.
# =============================================================================

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

log() { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok() { echo -e "${GREEN} ✓${RESET} $*"; }
warn() { echo -e "${YELLOW} !${RESET} $*"; }
fail() {
  echo -e "${RED} ✗${RESET} $*"
  exit 1
}

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
# Accepts in any order: --dev | --prod (exactly one required), --reinstall,
# --yes/-y, --doctor | --check-for-updates (read-only report modes).
MACHINE_TYPE=""
REINSTALL=false
YES=false
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dev)
    [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
    MACHINE_TYPE="dev"
    shift
    ;;
  --prod)
    [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
    MACHINE_TYPE="prod"
    shift
    ;;
  --doctor)
    [[ -n "$ACTION" ]] && fail "--doctor and --check-for-updates are mutually exclusive"
    ACTION="doctor"
    shift
    ;;
  --check-for-updates | --checkforupdates)
    [[ -n "$ACTION" ]] && fail "--doctor and --check-for-updates are mutually exclusive"
    ACTION="check-updates"
    shift
    ;;
  --full)
    fail "--full was removed.

Use one of the new mutually-exclusive flags:
  ./bootstrap.sh --dev      # Host you own        — sudo, /usr/local/bin + system packages
  ./bootstrap.sh --prod     # Host you don't own  — no sudo, ~/.local/bin only

Run ./bootstrap.sh --help for the full flag list."
    ;;
  --reinstall)
    REINSTALL=true
    shift
    ;;
  --yes | -y)
    YES=true
    shift
    ;;
  -h | --help)
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
  --doctor      Read-only health report, then exit (provisions nothing):
                prereqs, repo git state (branch, ahead/behind, dirty),
                chezmoi init + drift, login shell, then every managed
                tool/service/stamp via 'make doctor'.
  --check-for-updates
                Read-only update scan, then exit: the workstation repo
                first (fetch + commits-behind), then every pinned tool
                against its upstream release tags via 'make check-updates'
                (git ls-remote — no GitHub API, no rate limits).
                --checkforupdates is accepted as an alias.
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

# Derived value used by self_register (hosts.conf group column).
GROUP_NAME="${MACHINE_TYPE}_machine"

# The report modes are read-only — combining them with the wipe flag is
# almost certainly a mistake, so refuse rather than surprise.
if [[ -n "$ACTION" && "$REINSTALL" == true ]]; then
  fail "--reinstall can't be combined with --doctor/--check-for-updates (they are read-only and exit early)"
fi

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
  echo "    - dnf packages, SSH keys"
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
# 1. PREFLIGHT — collect-all prereq check
# =============================================================================
preflight() {
  log "Checking prerequisites..."

  local missing=()
  command -v curl &>/dev/null || missing+=("curl")
  command -v git &>/dev/null || missing+=("git")
  command -v make &>/dev/null || missing+=("make (drives makefile/Makefile)")
  command -v tar &>/dev/null || missing+=("tar (for archive extraction)")
  command -v unzip &>/dev/null || missing+=("unzip (for .zip releases like lnav/yazi/rclone)")
  command -v ip &>/dev/null || missing+=("iproute (for self-registration)")

  if ((${#missing[@]} > 0)); then
    fail "Missing required prerequisites: ${missing[*]}
Install via your distro's package manager, e.g.
  RHEL/Fedora:   sudo dnf install curl git make tar unzip iproute
  Debian/Ubuntu: sudo apt install curl git make tar unzip iproute2"
  fi

  ok "Prerequisites OK"
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

  host_ip=$(ip route get 1.1.1.1 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

  if [[ -z "$host_ip" ]]; then
    host_ip=$(ip addr show 2>/dev/null |
      awk '/inet / && !/127\.0\.0\.1/ {split($2,a,"/"); print a[1]}' | head -1)
  fi

  if [[ -z "$host_ip" ]]; then
    warn "Could not detect IP address — skipping self-registration."
    return
  fi

  log "Self-registration: ${host_name} (${host_user}@${host_ip}) as ${GROUP_NAME}"
  # --add already runs sync_all on success, so don't double-sync here —
  # any make/chezmoi step that reads hosts.conf downstream sees the
  # current inventory + wezterm block from the single --add pass.
  bash "$manage_script" --add \
    --name "$host_name" \
    --ip "$host_ip" \
    --user "$host_user" \
    --group "$GROUP_NAME" \
    --skip-confirm
}

# =============================================================================
# 3. RUN MAKE — invoke `make MODE=<dev|prod> provision` inside makefile/.
#
# The Makefile resolves DEST/SUDO/HAS_SUDO/INSTALL_PACKAGES from MODE (see
# makefile/scope.mk) and then runs the equivalent of every old Ansible task
# in one parallel pass: dnf packages, PATH wiring, tool installs, chezmoi
# update. Sudo is prefixed onto individual recipe lines that need it; make
# itself runs as the dev user end-to-end, so stamps stay under $HOME and
# pip/claude never accidentally get sudo'd.
# =============================================================================
run_make() {
  cd "$CHEZMOI_SOURCE/makefile"
  log "Running 'make MODE=${MACHINE_TYPE} provision'..."
  if [[ "$MACHINE_TYPE" == "dev" ]]; then
    log "Dev mode — sudo may prompt once early for dnf + /usr/local/bin writes"
  fi

  if ! make MODE="$MACHINE_TYPE" provision; then
    fail "make provision failed — see the output above for the failing target."
  fi

  ok "make provision complete"
}

# =============================================================================
# 4.5. ENSURE CHEZMOI IS INITIALIZED — run `chezmoi init --apply` once.
#
# `make provision` installs the chezmoi binary but can't run `chezmoi init`
# itself: `.chezmoi.toml.tmpl` calls promptStringOnce for name/email, and
# make recipes have no TTY for the prompts. So makefile/dotfiles.mk runs
# only `chezmoi update` (pull + apply), gated on the config file's existence.
#
# That leaves a first-run gap: chezmoi config doesn't exist yet, so the
# update task is skipped, and the dotfiles never land. This function closes
# the gap by running `chezmoi init --apply` interactively after `make
# provision` returns, with stdin explicitly redirected from /dev/tty so
# prompts also work under `curl … | bash` (where script stdin is the curl pipe).
#
# Idempotent: if the config file already exists, returns immediately.
# =============================================================================
ensure_chezmoi_initialized() {
  local chezmoi_bin
  chezmoi_bin=$(command -v chezmoi || true)
  if [[ -z "$chezmoi_bin" ]]; then
    warn "chezmoi binary not on PATH after 'make provision' — dotfiles not applied."
    warn "Run manually: chezmoi init --apply --source $CHEZMOI_SOURCE"
    return 0
  fi

  local config="$HOME/.config/chezmoi/chezmoi.toml"
  if [[ -f "$config" ]]; then
    ok "chezmoi already initialized ($config)"
    return 0
  fi

  if [[ ! -r /dev/tty ]]; then
    warn "No TTY — skipping chezmoi init. Run interactively after this script:"
    warn "  $chezmoi_bin init --apply --source $CHEZMOI_SOURCE"
    return 0
  fi

  log "First-time chezmoi setup — prompting for name/email..."
  # WORKSTATION_GROUP feeds the `group` field in chezmoi.toml.tmpl's [data]
  # block — drives the dev/prod conditionals in .chezmoiignore.tmpl so prod
  # hosts skip dev-only paths (~/.claude, ~/.config/ccstatusline, etc.).
  if WORKSTATION_GROUP="$GROUP_NAME" "$chezmoi_bin" init --apply --source "$CHEZMOI_SOURCE" </dev/tty; then
    ok "chezmoi initialized + dotfiles applied"
  else
    warn "chezmoi init failed. Inspect with: chezmoi diff --source $CHEZMOI_SOURCE"
    return 0
  fi
}

# =============================================================================
# 4.7. SET DEFAULT SHELL — switch the user's login shell to zsh.
#
# The chezmoi-tracked rc is `dot_zshrc.tmpl` → ~/.zshrc; switching the login
# shell is what makes new WezTerm/SSH/WSL sessions actually read it. `chsh`
# isn't installed by default on AlmaLinux 9 (needs util-linux-user) and even
# when present requires PAM auth (interactive password). `sudo usermod -s`
# edits /etc/passwd directly — works under our existing dev-mode sudo flow.
#
# Prod hosts have no sudo, so we just print the manual chsh command. Same
# fallback on dev hosts where usermod fails (most often: $SUDO_ASKPASS missing
# under curl|bash from a remote machine).
# =============================================================================
# check_age_identity — soft preflight for the age private identity when encryption
# is configured. If WORKSTATION_AGE_RECIPIENT is set but ~/.config/chezmoi/key.txt
# is absent, warn (encrypted dotfiles won't decrypt) but never fail — encryption is
# opt-in and the identity is provisioned out-of-band, never stored in the repo.
check_age_identity() {
  [ -n "${WORKSTATION_AGE_RECIPIENT:-}" ] || return 0
  log "age encryption: recipient configured (${WORKSTATION_AGE_RECIPIENT})"
  local key="$HOME/.config/chezmoi/key.txt"
  if [ -f "$key" ]; then
    ok "age identity present ($key)"
  else
    warn "age identity missing: $key"
    warn "  encrypted dotfiles won't decrypt until you place it. Create a new key:"
    warn "    mkdir -p \"$(dirname "$key")\" && age-keygen -o \"$key\"   # then export its public key as WORKSTATION_AGE_RECIPIENT"
    warn "  or copy key.txt from another host / your password store."
  fi
}

set_default_shell() {
  local zsh_path
  zsh_path=$(command -v zsh || true)
  if [[ -z "$zsh_path" ]]; then
    if [[ "$MACHINE_TYPE" == "dev" ]]; then
      warn "zsh not on PATH — default shell unchanged. Re-run after a manual install:"
      warn "  sudo dnf install -y zsh   (or apt install zsh)"
    else
      # Prod has no sudo, so the dnf hint is wrong; surface that limitation
      # plainly and tell the user what state the host is in (zshrc deployed,
      # just dormant) so the fix path is obvious.
      warn "zsh not on PATH — ~/.zshrc has been deployed but is dormant on this host."
      warn "Ask the admin to install zsh (\`sudo dnf install -y zsh\`), then either"
      warn "re-run this script or chsh manually."
    fi
    return 0
  fi

  # /etc/passwd is authoritative; don't trust $SHELL (set by the parent shell).
  local current_shell
  current_shell=$(getent passwd "$USER" | cut -d: -f7)

  if [[ "$current_shell" == "$zsh_path" ]]; then
    ok "Default shell is already zsh ($zsh_path)"
    return 0
  fi

  if [[ "$MACHINE_TYPE" != "dev" ]]; then
    # No sudo on prod. chsh would work interactively but we can't drive it
    # cleanly under curl|bash. Tell the user and move on. On minimal RHEL
    # bases chsh itself ships in util-linux-user — flag the secondary
    # install in case `command -v chsh` also fails.
    warn "Default shell is $current_shell, not zsh. Change it manually on this host:"
    warn "  chsh -s $zsh_path        (interactive — needs your account password)"
    if ! command -v chsh &>/dev/null; then
      warn "  chsh is missing on this host. Ask the admin for:"
      warn "    sudo dnf install -y util-linux-user   (or shadow-utils on apt)"
    fi
    return 0
  fi

  log "Setting default shell to $zsh_path (current: $current_shell)..."
  if sudo usermod -s "$zsh_path" "$USER" 2>/dev/null; then
    ok "Default shell set to zsh — log out + back in (or open a new tab) to land in it"
  else
    warn "Couldn't set default shell automatically. Run one of:"
    warn "  sudo usermod -s $zsh_path $USER     (no password prompt)"
    warn "  chsh -s $zsh_path                   (interactive)"
  fi
}

# =============================================================================
# 5. PUSH HOST CHANGES — commit hosts.conf + wezterm sentinel block, push upstream.
#    Warn-don't-fail: `make provision` already succeeded by now, so we never abort here.
# =============================================================================
push_host_changes() {
  cd "$CHEZMOI_SOURCE"

  # Anything to commit (working tree OR already-staged)?
  if git diff --quiet hosts.conf chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null &&
    git diff --cached --quiet hosts.conf chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null; then
    log "No host-list changes to commit"
    return 0
  fi

  log "Committing host registration..."
  git add hosts.conf chezmoi/dot_config/wezterm/wezterm.lua 2>/dev/null || true

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
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes (--doctor /
# --check-for-updates). Both exit before the provisioning flow starts:
# nothing is cloned, installed, registered, or pushed. This script owns only
# the repo-level checks (prereqs, git state, chezmoi init + drift, login
# shell) and delegates ALL per-tool knowledge to `make doctor` /
# `make check-updates` in makefile/ — the thin-seed invariant holds.
# =============================================================================
require_repo() {
  if [[ ! -d "$CHEZMOI_SOURCE/.git" ]]; then
    fail "No workstation repo at $CHEZMOI_SOURCE — bootstrap this host first:
  ./bootstrap.sh --${MACHINE_TYPE}"
  fi
}

# Shared by both modes: fetch (best-effort), then report branch, ahead/behind
# the upstream, and working-tree cleanliness. Never aborts — report-only.
report_repo_state() {
  cd "$CHEZMOI_SOURCE"
  log "Workstation repo ($CHEZMOI_SOURCE)"
  if git fetch --quiet 2>/dev/null; then
    ok "fetched origin"
  else
    warn "git fetch failed (offline or stale credentials) — using last-known remote state"
  fi

  local branch dirty upstream
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  dirty=$(git status --porcelain 2>/dev/null | wc -l)

  if upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    local behind ahead
    behind=$(git rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo 0)
    ahead=$(git rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo 0)
    if ((behind > 0)); then
      warn "branch $branch is $behind commit(s) behind $upstream — update with: git -C $CHEZMOI_SOURCE pull --ff-only"
    else
      ok "branch $branch is up to date with $upstream"
    fi
    if ((ahead > 0)); then
      warn "$ahead local commit(s) not pushed — push with: git -C $CHEZMOI_SOURCE push"
    fi
  else
    warn "branch $branch has no upstream — behind/ahead unknown"
  fi

  if ((dirty > 0)); then
    warn "$dirty uncommitted change(s) — review with: git -C $CHEZMOI_SOURCE status"
  else
    ok "working tree clean"
  fi
}

do_doctor() {
  require_repo
  log "Doctor — read-only health report (MODE=${MACHINE_TYPE}); nothing is installed or changed"
  echo ""

  # Same prereq list as preflight, but report-all instead of hard-fail.
  log "Prerequisites"
  local cmd
  for cmd in curl git make tar unzip ip; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      warn "$cmd missing — install via your distro's package manager (see ./bootstrap.sh --help)"
    fi
  done
  echo ""

  report_repo_state
  echo ""

  log "chezmoi / dotfiles"
  local chezmoi_bin
  chezmoi_bin=$(command -v chezmoi || true)
  if [[ -n "$chezmoi_bin" ]]; then
    ok "chezmoi on PATH ($chezmoi_bin)"
    if [[ -f "$HOME/.config/chezmoi/chezmoi.toml" ]]; then
      ok "initialized (~/.config/chezmoi/chezmoi.toml)"
      local pending
      pending=$("$chezmoi_bin" status --source "$CHEZMOI_SOURCE" 2>/dev/null | wc -l)
      if ((pending > 0)); then
        warn "$pending path(s) differ from the source — review: czd (chezmoi diff) · apply: cza"
      else
        ok "deployed dotfiles in sync with the source"
      fi
    else
      warn "not initialized — re-run ./bootstrap.sh --${MACHINE_TYPE} (runs chezmoi init --apply)"
    fi
  else
    warn "chezmoi not on PATH — install: make -C $CHEZMOI_SOURCE/makefile chezmoi MODE=${MACHINE_TYPE}"
  fi
  echo ""

  log "Login shell"
  local login_shell zsh_path
  login_shell=$(getent passwd "$USER" | cut -d: -f7)
  zsh_path=$(command -v zsh || true)
  if [[ -n "$zsh_path" && "$login_shell" == "$zsh_path" ]]; then
    ok "login shell is zsh ($zsh_path)"
  elif [[ -z "$zsh_path" ]]; then
    warn "zsh not installed — login shell is $login_shell"
  else
    warn "login shell is $login_shell, not zsh — fix: sudo usermod -s $zsh_path $USER (dev) / chsh -s $zsh_path (prod)"
  fi
  echo ""

  log "Tools, services, stamps — make doctor MODE=${MACHINE_TYPE}"
  make -C "$CHEZMOI_SOURCE/makefile" --no-print-directory MODE="$MACHINE_TYPE" doctor
}

do_check_updates() {
  require_repo
  log "Check for updates (MODE=${MACHINE_TYPE}) — workstation repo first, then tool pins vs upstream"
  echo ""

  report_repo_state
  echo "    (tool pins live in makefile/versions.mk of THIS clone — if the repo is behind,"
  echo "     pull first so the pins you're comparing are current)"
  echo ""

  make -C "$CHEZMOI_SOURCE/makefile" --no-print-directory MODE="$MACHINE_TYPE" check-updates
}

# =============================================================================
# MAIN
# =============================================================================
# Read-only report modes exit here, before any provisioning state changes.
if [[ -n "$ACTION" ]]; then
  case "$ACTION" in
  doctor) do_doctor ;;
  check-updates) do_check_updates ;;
  esac
  exit 0
fi

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
    git -c "${GH_HEADER_KEY}=${GH_HEADER_VAL}" clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE" ||
      fail "Clone failed. For a private repo, set GITHUB_TOKEN to a PAT with repo read access."
    git -C "$CHEZMOI_SOURCE" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  else
    git clone "$DOTFILES_REPO" "$CHEZMOI_SOURCE" ||
      fail "Clone failed. If the repo is private, set GITHUB_TOKEN and re-run."
  fi
  ok "Repo cloned"
else
  log "Repo already present at $CHEZMOI_SOURCE — pulling latest..."
  # Refresh the stored token if a new one was passed in this invocation.
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -C "$CHEZMOI_SOURCE" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  fi
  # A failed pull means we'd run make against a stale-or-broken tree —
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
run_make
ensure_chezmoi_initialized
check_age_identity
set_default_shell
push_host_changes

# --- ccstatusline setup (dev only) -----------------------------------------
# Interactive prompt for the Claude Code statusline. Re-runnable any time
# via `make -C makefile claude-statusline MODE=dev` from the repo root.
if [ "$MACHINE_TYPE" = "dev" ]; then
  make -C "$(dirname "$0")/makefile" claude-statusline MODE=dev || true
fi

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"

# Only print the "you're on zsh" tip when the user actually is. set_default_shell
# may have bailed out (prod with no sudo, missing zsh binary, usermod refused) and
# already printed its own follow-up command, so we just stay quiet here. Read the
# authoritative shell from /etc/passwd — $SHELL was set by the parent process.
_login_shell=$(getent passwd "$USER" | cut -d: -f7)
_zsh_path=$(command -v zsh || true)
if [[ -n "$_zsh_path" && "$_login_shell" == "$_zsh_path" ]]; then
  echo -e "Open a new tab (or log out + back in) to land in zsh."
  echo -e "Or switch this terminal right now: ${YELLOW}exec zsh${RESET}"
fi

if is_wsl; then
  echo -e "Running inside WSL — opening a new WezTerm WSL tab will land you in"
  echo -e "  ${YELLOW}~${RESET} with starship + the chezmoi-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux)"
  echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
fi
if [ "$MACHINE_TYPE" = "dev" ]; then
  echo -e "Re-configure the Claude Code statusline any time:"
  echo -e "  ${YELLOW}make -C makefile claude-statusline MODE=dev${RESET}"
fi
