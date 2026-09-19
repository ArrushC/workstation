#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (mise seed)
#
# Exactly one of --dev or --prod is required — it picks both the hosts.conf
# group this host registers as AND the MISE_ENV token set `mise bootstrap`
# loads (scripts/lib/mise-env.sh maps MACHINE_TYPE → MISE_ENV):
#
#   DEV  (host you own, sudo for system packages + /etc files; tools are user-level):
#     ./bootstrap.sh --dev
#
#   PROD (host you don't fully own, no sudo, install to ~/.local/bin):
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod
#     or: ./bootstrap.sh --prod
#
# MISE_ENV picks which config*.toml [bootstrap.*] tables load (dnf packages,
# /etc files, services, compose, repos, hooks) — dev hosts load host state
# that needs sudo, prod hosts load none. Same resolution happens whether you
# bootstrap locally or update remotely via scripts/update-hosts.sh.
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
# This script owns only the repo-level checks (prereqs, git branch/
# ahead/behind/dirty, chezmoi init + drift, login shell) — these modes front
# `mise run health` / `mise run check-updates`, which carry ALL per-tool and
# per-host-state knowledge (tasks/, config*.toml).
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
#   1. preflight             — check curl/git/tar/iproute
#   1a. do_reinstall (opt.)  — wipe the cloned repo + chezmoi config
#                              (--reinstall); then falls through to a fresh run
#   1.5. relocate_repo       — one-time move of a pre-2026-09 checkout from
#                              ~/.local/share/chezmoi to ~/.config/mise (idempotent)
#   2. clone repo            — into ~/.config/mise (or git pull if present)
#   2.5. install_mise        — the pinned mise binary into ~/.local/bin
#                              (sha256-verified)
#   2.6. MISE_ENV             — resolved from MACHINE_TYPE via
#                              scripts/lib/mise-env.sh and exported
#   3. self_register         — add this host to hosts.conf
#                              (auto-skipped inside WSL — see is_wsl below)
#   3.5. user-manager env    — `systemctl --user set-environment MISE_ENV=…`
#                              so the live systemd user manager sees it too
#                              (the pueued shim needs MISE_ENV to resolve mise)
#   4. mise install (tools)  — scripts/lib/mise-install.sh installs every
#                              tool the active MISE_ENV declares
#   4.5. mise bootstrap      — packages, /etc files, services, compose,
#                              repos, tools gate, then the `bootstrap` task
#   4b. ensure_chezmoi_initialized — `chezmoi init --apply` interactively if
#                              ~/.config/chezmoi/chezmoi.toml is missing.
#                              mise bootstrap has no TTY for interactive
#                              prompts, so this closes the first-run gap with
#                              stdin from /dev/tty.
#   4c. set_default_shell    — `sudo usermod -s "$(command -v zsh)" "$USER"`
#                              on --dev only. The chezmoi-tracked rc lives at
#                              ~/.zshrc; we switch the login shell so new
#                              SSH/WSL sessions land in zsh. Best-effort:
#                              prints the manual chsh command on prod or
#                              when usermod isn't permitted.
#   5. push_host_changes     — commit+push hosts.conf updates (warn-don't-fail)
#                              (no-op inside WSL since self_register made no edits)
#
# WSL — running inside a WSL distro is supported and treated as a managed host
# for tools + dotfiles, but NOT as an SSH target. is_wsl() (defined below)
# detects WSL via $WSL_DISTRO_NAME or /proc/version's microsoft marker and
# short-circuits self_register so hosts.conf is never touched. The
# end-of-bootstrap copy-id tip is also suppressed.
#
# Tool versions, dnf packages, /etc files, services, PATH wiring, chezmoi
# orchestration — everything lives in config*.toml [bootstrap.*] tables and
# global mise tasks under tasks/ (discovered from this checkout, mise's
# global config dir). bootstrap.sh has no per-tool knowledge.
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
# copy-id tip. WSL distros are launched directly by the Windows-side
# terminal (Windows Terminal's WSL profile, `wsl.exe`), not SSH'd into, so
# registering them as SSH targets would pollute the inventory with an IP
# that's only reachable from the host Windows machine.
#   - WSL_DISTRO_NAME is exported by WSL 2 inside the distro
#   - /proc/version's "microsoft" marker is the universal backup signal
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
# The checkout IS mise's global config dir (config*.toml, mise.lock, tasks/ live at its root).
REPO_DIR="$HOME/.config/mise"
LEGACY_REPO_DIR="$HOME/.local/share/chezmoi" # pre-2026-09 location; relocate_repo() moves it
CHEZMOI_SOURCE="$REPO_DIR"                   # chezmoi's --source (its .chezmoiroot points at chezmoi/ inside)
BIN="$HOME/.local/bin"
# The ONE pin bootstrap owns: mise itself (everything else is in config*.toml).
# DUAL-EDIT with bootstrap.ps1 $PortableTools (mise) and min_version in config.toml —
# scripts/check-invariants.sh asserts all three agree.
MISE_VERSION="2026.9.9"
MISE_SHA256="986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc" # mise-v${MISE_VERSION}-linux-x64-musl.tar.gz

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
  ./bootstrap.sh --dev      # Host you own        — sudo for system packages + /etc files; tools are user-level
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
  --dev         Host you own. Sudo available for system packages + /etc
                files (dnf on RHEL/Fedora today); tools install user-level.
                Registers as group dev_machine.
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
                tool/host-state/service via 'mise run health'.
  --check-for-updates
                Read-only update scan, then exit: the workstation repo
                first (fetch + commits-behind), then every pinned tool
                against its upstream release tags via 'mise run check-updates'
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
  ./bootstrap.sh --dev      # Host you own        — sudo for system packages + /etc files; tools are user-level
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
  echo "    - $REPO_DIR   (cloned workstation repo)"
  if [[ -d "$LEGACY_REPO_DIR" ]]; then
    echo "    - $LEGACY_REPO_DIR   (pre-relocation checkout, not yet swept)"
  fi
  echo "    - $HOME/.config/chezmoi/    (chezmoi config + cached init data)"
  echo ""
  echo "  Will NOT remove (leaving for re-bootstrap to no-op over):"
  echo "    - Installed tools in ~/.local/bin (tools are user-level since PR1)"
  echo "    - dnf packages, SSH keys"
  echo "    - Deployed dotfiles in \$HOME (chezmoi will re-apply over them)"
  echo ""
  echo "  For a deeper uninstall (remove tools too), do that manually first:"
  echo "    mise implode                 # removes every mise-installed tool + mise's data dir"
  echo "    rm -rf ~/.local/share/mise   # if implode isn't available (older mise, or already gone)"
  echo ""

  # Self-deletion guard: if this script is being run from inside the path
  # we're about to delete, refuse. Use the curl-pipe form instead — it
  # streams the script body through bash without backing it on disk.
  local script_path="${BASH_SOURCE[0]}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_real
    script_real=$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")
    if [[ "$script_real" == "$REPO_DIR"* || "$script_real" == "$LEGACY_REPO_DIR"* ]]; then
      fail "Refusing to reinstall — running script is inside $REPO_DIR or $LEGACY_REPO_DIR.
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

  if [[ -d "$REPO_DIR" ]]; then
    log "Removing $REPO_DIR..."
    rm -rf "$REPO_DIR"
    ok "Repo removed"
  else
    log "$REPO_DIR not present — nothing to remove"
  fi

  if [[ -d "$LEGACY_REPO_DIR" ]]; then
    log "Removing $LEGACY_REPO_DIR..."
    rm -rf "$LEGACY_REPO_DIR"
    ok "Legacy repo removed"
  else
    log "$LEGACY_REPO_DIR not present — nothing to remove"
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
  command -v tar &>/dev/null || missing+=("tar (for archive extraction)")
  command -v ip &>/dev/null || missing+=("iproute (for self-registration)")

  if ((${#missing[@]} > 0)); then
    fail "Missing required prerequisites: ${missing[*]}
Install via your distro's package manager, e.g.
  RHEL/Fedora:   sudo dnf install curl git tar iproute
  Debian/Ubuntu: sudo apt install curl git tar iproute2"
  fi

  ok "Prerequisites OK"
}

# =============================================================================
# 1.5 RELOCATE — the checkout moved from ~/.local/share/chezmoi to ~/.config/mise
# (this repo IS mise's global config dir since 2026-09). One-time, idempotent.
# A pre-existing ~/.config/mise (the chezmoi-deployed conf.d era) is moved aside.
# =============================================================================
relocate_repo() {
  [[ -d "$REPO_DIR/.git" ]] && return 0
  [[ -d "$LEGACY_REPO_DIR/.git" ]] || return 0
  log "Relocating the workstation checkout: $LEGACY_REPO_DIR → $REPO_DIR"
  if [[ -e "$REPO_DIR" ]]; then
    local aside
    aside="$REPO_DIR.pre-relocation.$(date +%Y%m%d%H%M%S)"
    mv "$REPO_DIR" "$aside" || fail "could not move aside $REPO_DIR"
    warn "moved the old $REPO_DIR (chezmoi-deployed mise conf.d) to $aside — delete it once the new layout works"
  fi
  mkdir -p "$(dirname "$REPO_DIR")"
  mv "$LEGACY_REPO_DIR" "$REPO_DIR" || fail "could not move $LEGACY_REPO_DIR to $REPO_DIR"
  ok "checkout now at $REPO_DIR"
}

# =============================================================================
# 2. SELF-REGISTER — add this host to hosts.conf + regenerate inventory
# =============================================================================
self_register() {
  # WSL distros are launched directly by the Windows-side terminal (Windows
  # Terminal's WSL profile), not SSH'd into. Registering them in hosts.conf would
  # generate a redundant SSH Tab Config and record a WSL-internal IP that's
  # only reachable from the host Windows machine. Skip.
  if is_wsl; then
    log "Detected WSL (${WSL_DISTRO_NAME:-via /proc/version}) — skipping hosts.conf self-registration"
    ok "WSL is reached through the Windows terminal's WSL integration, not SSH"
    return
  fi

  local manage_script="$REPO_DIR/scripts/manage-hosts.sh"

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
  # Any mise/chezmoi step that reads hosts.conf downstream sees the current
  # inventory from the single --add pass; the Windows-side Windows Terminal
  # SSH profiles (fragment) regenerate from it on the next bootstrap.ps1 run.
  bash "$manage_script" --add \
    --name "$host_name" \
    --ip "$host_ip" \
    --user "$host_user" \
    --group "$GROUP_NAME" \
    --skip-confirm
}

# =============================================================================
# 2.5 MISE — the pinned mise binary into ~/.local/bin (sha256-verified). mise
# installs every other tool from config*.toml; the Make layer only orchestrates.
# =============================================================================
install_mise() {
  if [[ -x "$BIN/mise" ]] && [[ "$("$BIN/mise" --version 2>/dev/null | awk '{print $1}')" == "$MISE_VERSION" ]]; then
    ok "mise $MISE_VERSION present ($BIN/mise)"
    return 0
  fi
  log "Installing mise $MISE_VERSION into $BIN..."
  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64-musl.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/mise.tgz" "$url" || fail "mise download failed: $url"
  printf '%s  %s\n' "$MISE_SHA256" "$tmp/mise.tgz" | sha256sum -c --quiet - || fail "mise tarball sha256 mismatch — refusing to install"
  tar -xzf "$tmp/mise.tgz" -C "$tmp"
  install -m 0755 "$tmp/mise/bin/mise" "$BIN/mise"
  rm -rf "$tmp"
  ok "mise $MISE_VERSION installed ($BIN/mise)"
}

# =============================================================================
# 3.5/4/4.5. RUN BOOTSTRAP — carry MISE_ENV onto the live systemd user
# manager, retire the chezmoi-era pueued unit, install tools, then run
# `mise bootstrap` (packages, /etc files, services, compose, repos, tools
# gate, then the `bootstrap` task itself). Sudo (dev only) is scoped to the
# dnf batch and /etc files inside mise's own elevation — this script never
# runs sudo directly.
# =============================================================================
run_bootstrap() {
  # The user manager must carry MISE_ENV for the pueued shim (dev.mise.pueued.service);
  # environment.d covers the next login, this covers the live manager.
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user set-environment "MISE_ENV=$MISE_ENV" || warn "could not set MISE_ENV on the systemd user manager"
  fi
  # chezmoi-era pueued unit: retire BEFORE mise's services phase starts dev.mise.pueued (same daemon/socket).
  if [[ -f "$HOME/.config/systemd/user/pueued.service" ]]; then
    systemctl --user disable --now pueued.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/pueued.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "retired the chezmoi-era pueued.service (mise owns dev.mise.pueued.service now)"
  fi
  log "mise install (tools) — MISE_ENV=$MISE_ENV"
  "$REPO_DIR/scripts/lib/mise-install.sh" || fail "mise install failed — see above"
  log "mise bootstrap — packages, /etc files, services, compose, repos, tools gate, then the bootstrap task"
  if [[ "$MACHINE_TYPE" == "dev" ]]; then
    log "Dev mode — sudo will prompt for the dnf batch and /etc files (fleet runs on dev hosts are interactive by design)"
  fi
  mise bootstrap --yes || fail "mise bootstrap failed — see the failing phase above; re-run after fixing (idempotent)"
  ok "mise bootstrap complete"
}

# =============================================================================
# 4.5. ENSURE CHEZMOI IS INITIALIZED — run `chezmoi init --apply` once.
#
# `mise bootstrap` installs the chezmoi binary (a mise tool pin) but can't run
# `chezmoi init` itself: `.chezmoi.toml.tmpl` calls promptStringOnce for
# name/email, and mise's hooks have no TTY for the prompts.
#
# That leaves a first-run gap: chezmoi config doesn't exist yet, so the
# dotfiles never land on their own. This function closes the gap by running
# `chezmoi init --apply` interactively after mise bootstrap returns, with
# stdin explicitly redirected from /dev/tty so prompts also work under
# `curl … | bash` (where script stdin is the curl pipe).
#
# Idempotent: if the config file already exists, returns immediately.
# =============================================================================
ensure_chezmoi_initialized() {
  local chezmoi_bin
  chezmoi_bin=$(command -v chezmoi || true)
  if [[ -z "$chezmoi_bin" ]]; then
    warn "chezmoi binary not on PATH after mise bootstrap — dotfiles not applied."
    warn "Run manually: chezmoi init --apply --source $CHEZMOI_SOURCE"
    return 0
  fi

  local config="$HOME/.config/chezmoi/chezmoi.toml"
  if [[ -f "$config" ]]; then
    ok "chezmoi already initialized ($config)"
    return 0
  fi

  # `[[ ! -r /dev/tty ]]` is an access(2) test: it returns true (readable)
  # even under `ssh host 'cmd'` with no controlling terminal, so it never
  # actually detects "no TTY" — open the device instead, which fails for
  # real when there is none.
  if ! exec 3</dev/tty 2>/dev/null; then
    warn "No TTY — skipping chezmoi init. Run interactively after this script:"
    warn "  $chezmoi_bin init --apply --source $CHEZMOI_SOURCE"
    return 0
  fi
  exec 3<&-

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
# 4.6. REFRESH CHEZMOI CONFIG — re-render chezmoi's config when it predates
# the sourceDir key (the relocation): `init` without --apply re-runs
# .chezmoi.toml.tmpl; cached prompt answers mean no prompts.
# =============================================================================
refresh_chezmoi_config() {
  local config="$HOME/.config/chezmoi/chezmoi.toml" chezmoi_bin
  chezmoi_bin=$(command -v chezmoi || true)
  [[ -n "$chezmoi_bin" && -f "$config" ]] || return 0
  grep -q '^sourceDir' "$config" && return 0
  log "Refreshing chezmoi config (sourceDir → $REPO_DIR)..."
  WORKSTATION_GROUP="$GROUP_NAME" "$chezmoi_bin" init --no-tty --source "$CHEZMOI_SOURCE" && ok "chezmoi config refreshed" || warn "chezmoi init --no-tty failed; run: chezmoi init --source $CHEZMOI_SOURCE"
}

# =============================================================================
# 4.7. SET DEFAULT SHELL — switch the user's login shell to zsh.
#
# The chezmoi-tracked rc is `dot_zshrc.tmpl` → ~/.zshrc; switching the login
# shell is what makes new SSH/WSL sessions actually read it. `chsh`
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
# 5. PUSH HOST CHANGES — commit hosts.conf, push upstream.
#    Warn-don't-fail: mise bootstrap already succeeded by now, so we never abort here.
# =============================================================================
push_host_changes() {
  cd "$REPO_DIR"

  # Anything to commit (working tree OR already-staged)?
  if git diff --quiet hosts.conf 2>/dev/null &&
    git diff --cached --quiet hosts.conf 2>/dev/null; then
    log "No host-list changes to commit"
    return 0
  fi

  # Non-interactive runs (fleet updates via update-hosts.sh) must never write
  # to the shared repo on the caller's behalf — commit+push only when stdin
  # is a TTY (an interactive ./bootstrap.sh run).
  if [[ ! -t 0 ]]; then
    warn "hosts.conf changed but this is a non-interactive run — commit it by hand: cd $REPO_DIR && git add hosts.conf && git commit -m 'hosts: …' && git push"
    return 0
  fi

  log "Committing host registration..."
  git add hosts.conf 2>/dev/null || true

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
    warn "Commit failed — inspect with:  cd $REPO_DIR && git status"
    return 0
  fi

  log "Pushing host registration..."
  if git push 2>/dev/null; then
    ok "Host registration pushed"
  else
    warn "Push failed (auth, conflict, or no upstream). Recover with:"
    warn "  cd $REPO_DIR && git push"
  fi
}

# =============================================================================
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes (--doctor /
# --check-for-updates). Both exit before the provisioning flow starts:
# nothing is cloned, installed, registered, or pushed. This script owns only
# the repo-level checks (prereqs, git state, chezmoi init + drift, login
# shell) and delegates ALL per-tool and host-state knowledge to
# `mise run health` / `mise run check-updates`.
# =============================================================================
require_repo() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if [[ -d "$LEGACY_REPO_DIR/.git" ]]; then
      REPO_DIR="$LEGACY_REPO_DIR"
      CHEZMOI_SOURCE="$REPO_DIR"
      warn "checkout not yet relocated to ~/.config/mise — run ./bootstrap.sh --${MACHINE_TYPE} once"
      return 0
    fi
    fail "No workstation repo at $REPO_DIR — bootstrap this host first:
  ./bootstrap.sh --${MACHINE_TYPE}"
  fi
}

# Shared by both modes: fetch (best-effort), then report branch, ahead/behind
# the upstream, and working-tree cleanliness. Never aborts — report-only.
report_repo_state() {
  cd "$REPO_DIR"
  log "Workstation repo ($REPO_DIR)"
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
      warn "branch $branch is $behind commit(s) behind $upstream — update with: git -C $REPO_DIR pull --ff-only"
    else
      ok "branch $branch is up to date with $upstream"
    fi
    if ((ahead > 0)); then
      warn "$ahead local commit(s) not pushed — push with: git -C $REPO_DIR push"
    fi
  else
    warn "branch $branch has no upstream — behind/ahead unknown"
  fi

  if ((dirty > 0)); then
    warn "$dirty uncommitted change(s) — review with: git -C $REPO_DIR status"
  else
    ok "working tree clean"
  fi
}

do_doctor() {
  require_repo
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
  export MISE_ENV
  log "Doctor — read-only health report (MODE=${MACHINE_TYPE}); nothing is installed or changed"
  echo ""

  # Same prereq list as preflight, but report-all instead of hard-fail.
  log "Prerequisites"
  local cmd
  for cmd in curl git tar ip; do
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
    warn "chezmoi not on PATH — install: mise install chezmoi"
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

  log "mise"
  if command -v mise >/dev/null 2>&1; then ok "mise $(mise --version 2>/dev/null | awk '{print $1}') on PATH ($(command -v mise)) — pinned $MISE_VERSION"; else warn "mise not on PATH — re-run ./bootstrap.sh --${MACHINE_TYPE}"; fi
  echo ""

  log "Tools, host state, services — mise run health"
  mise run health
  exit $?
}

do_check_updates() {
  require_repo
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
  export MISE_ENV
  log "Check for updates (MODE=${MACHINE_TYPE}) — workstation repo first, then tool pins vs upstream"
  echo ""

  report_repo_state
  echo "    (tool pins live in config*.toml + config.toml [vars] of THIS clone — if the repo"
  echo "     is behind, pull first so the pins you're comparing are current)"
  echo ""

  mise run check-updates
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
export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"
relocate_repo

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

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning workstation repo into $REPO_DIR..."
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -c "${GH_HEADER_KEY}=${GH_HEADER_VAL}" clone "$DOTFILES_REPO" "$REPO_DIR" ||
      fail "Clone failed. For a private repo, set GITHUB_TOKEN to a PAT with repo read access."
    git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  else
    git clone "$DOTFILES_REPO" "$REPO_DIR" ||
      fail "Clone failed. If the repo is private, set GITHUB_TOKEN and re-run."
  fi
  ok "Repo cloned"
else
  log "Repo already present at $REPO_DIR — pulling latest..."
  # Refresh the stored token if a new one was passed in this invocation.
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  fi
  # A failed pull means we'd run mise bootstrap against a stale-or-broken tree —
  # better to bail out and let the user inspect.
  if ! git -C "$REPO_DIR" pull --ff-only; then
    fail "git pull --ff-only failed in $REPO_DIR.
This usually means stale credentials in .git/config, or local commits/conflicts.
Inspect with:
  cd $REPO_DIR && git status && git log --oneline -5

To start over from scratch (wipes the cloned repo, not your tools/dotfiles):
  ./bootstrap.sh --${MACHINE_TYPE} --reinstall"
  fi
fi

install_mise
MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
export MISE_ENV
log "mise environment: MISE_ENV=$MISE_ENV"

self_register
run_bootstrap
ensure_chezmoi_initialized
refresh_chezmoi_config
check_age_identity
set_default_shell
push_host_changes

# --- ccstatusline setup (dev only) -----------------------------------------
# Interactive prompt for the Claude Code statusline. Re-runnable any time
# via `mise run statusline` from anywhere.
if [[ "$MACHINE_TYPE" == dev && -t 0 ]]; then
  mise run statusline || true
fi

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"

echo -e "${YELLOW}Replace this shell now:${RESET} run ${YELLOW}exec zsh${RESET} (or open a new tab)."
echo -e "  The shell you ran this from still has its mise/starship prompt hooks bound to the"
echo -e "  pre-migration /usr/local binaries, which the legacy sweep just removed — its prompt"
echo -e "  will print 'no such file or directory' on every keystroke until it is replaced."

# Only print the "you're on zsh" tip when the user actually is. set_default_shell
# may have bailed out (prod with no sudo, missing zsh binary, usermod refused) and
# already printed its own follow-up command, so we just stay quiet here. Read the
# authoritative shell from /etc/passwd — $SHELL was set by the parent process.
_login_shell=$(getent passwd "$USER" | cut -d: -f7)
_zsh_path=$(command -v zsh || true)
if [[ -n "$_zsh_path" && "$_login_shell" == "$_zsh_path" ]]; then
  echo -e "Log out + back in (or open a new tab) to land in zsh as your login shell."
fi

if is_wsl; then
  echo -e "Running inside WSL — opening a new Windows Terminal tab into this distro lands you"
  echo -e "  in ${YELLOW}~${RESET} with the chezmoi-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}./scripts/manage-hosts.sh --copy-id --name $(hostname -s)${RESET}  (Linux)"
  echo -e "  ${YELLOW}.\\scripts\\manage-hosts.ps1 -CopyId -Name $(hostname -s)${RESET}  (Windows)"
fi
if [ "$MACHINE_TYPE" = "dev" ]; then
  echo -e "Re-configure the Claude Code statusline any time:"
  echo -e "  ${YELLOW}mise run statusline${RESET}"
fi
echo -e "Health check any time: ${YELLOW}mise run health${RESET}"
