#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (mise seed). Clones this repo into
# ~/.config/mise, installs the pinned mise binary, then runs `mise bootstrap`
# to install tools, packages, /etc files, services, and dotfiles. Idempotent —
# safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#
# First run asks which of two modes this host is (or WORKSTATION_MODE=owned|
# shared, or a saved vars.mode in config.local.toml — see resolve_host_config):
#   owned   your machine  — sudo, full toolbelt, zsh login shell
#   shared  someone else's — no sudo, user-level toolbelt only
#
# See ./bootstrap.sh --help for flags (--reinstall, --doctor, --check-for-updates).
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
  echo -e "${RED} ✗${RESET} $*" >&2
  exit 1
}

# WSL detection — used to swap the end-of-bootstrap ssh-copy-id tip for a
# WSL one. WSL distros are launched directly by the Windows-side terminal
# (Windows Terminal's WSL profile, `wsl.exe`), not SSH'd into.
#   - WSL_DISTRO_NAME is exported by WSL 2 inside the distro
#   - /proc/version's "microsoft" marker is the universal backup signal
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

# --- Constants ---------------------------------------------------------------
DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
# The checkout IS mise's global config dir (config*.toml, mise.lock, tasks/ live at its root).
REPO_DIR="$HOME/.config/mise"
BIN="$HOME/.local/bin"
# The ONE pin bootstrap owns: mise itself (everything else is in config*.toml).
# DUAL-EDIT with bootstrap.ps1 $PortableTools (mise) and min_version in config.toml —
# scripts/check-invariants.sh asserts all three agree.
MISE_VERSION="2026.9.9"
MISE_SHA256="986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc" # mise-v${MISE_VERSION}-linux-x64-musl.tar.gz

# http.extraheader key scoped to github.com so the token never leaks to
# other remotes. Stored in the cloned repo's .git/config so subsequent
# git push, git pull, and manual git ops all authenticate.
GH_HEADER_KEY="http.https://github.com/.extraheader"

# --- Argument parsing ---------------------------------------------------------
# Accepts in any order: --reinstall, --yes/-y, --doctor | --check-for-updates
# (read-only report modes). No mode flag — see resolve_host_config.
parse_args() {
  REINSTALL=false
  YES=false
  ACTION=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
Usage: ./bootstrap.sh [flags]

Sets up this host with mise. The first run asks whether the host is yours:
  owned   your machine — sudo: system packages, /etc files, services, zsh
          login shell, plus the full developer toolbelt
  shared  someone else's — no sudo: the user-level toolbelt only
The answer is saved in ~/.config/mise/config.local.toml (vars.mode).
Unattended first run: WORKSTATION_MODE=owned|shared.

Flags:
  --reinstall   Wipe the cloned repo (incl. config.local.toml), then bootstrap
                fresh. Installed tools and deployed dotfiles stay.
  --yes, -y     Skip the --reinstall confirmation prompt.
  --doctor      Read-only health report, then exit.
  --check-for-updates
                Read-only update scan, then exit (--checkforupdates alias).
  -h, --help    Show this message.
EOF
      exit 0
      ;;
    *) fail "Unknown argument: $1 (try --help)" ;;
    esac
  done

  # The report modes are read-only — combining them with the wipe flag is
  # almost certainly a mistake, so refuse rather than surprise.
  if [[ -n "$ACTION" && "$REINSTALL" == true ]]; then
    fail "--reinstall can't be combined with --doctor/--check-for-updates (they are read-only and exit early)"
  fi
}

# --- Config helpers + mode functions ------------------------------------------

# config.local.toml is machine-written `key = "value"` lines under [vars], so
# plain awk reads and writes it — no Python needed before tools exist.
config_get() { # config_get <file> <key>
  [[ -f "$1" ]] || return 0
  KEY="$2" awk '
    # Tolerant [vars] header match: leading/trailing space, a trailing
    # comment, or a CRLF line ending must still be recognized. Any OTHER
    # "[...]" header line (matched by the leading /^[[:space:]]*\[/, checked
    # first) leaves the vars table.
    /^[[:space:]]*\[/ {
      in_vars = ($0 ~ /^[[:space:]]*\[[[:space:]]*vars[[:space:]]*\][[:space:]]*(#.*)?\r?$/)
      next
    }
    in_vars {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, ENVIRON["KEY"]) == 1 && substr(line, length(ENVIRON["KEY"]) + 1) ~ /^[[:space:]]*=/) {
        sub(/^[^=]*=[[:space:]]*"/, "", line); sub(/"[[:space:]]*\r?$/, "", line)
        gsub(/\\"/, "\"", line); gsub(/\\\\/, "\\", line); print line; exit
      }
    }' "$1"
}

config_set() { # config_set <file> <key> <value>
  local file=$1 key=$2 val=$3 tmp
  val=${val//\\/\\\\}
  val=${val//\"/\\\"}
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : >"$file"
  tmp=$(mktemp)
  KEY="$key" LINE="$key = \"$val\"" awk '
    # Same tolerant [vars] header match as config_get — see its comment.
    /^[[:space:]]*\[/ {
      if (in_vars && !done) { print ENVIRON["LINE"]; done = 1 }
      in_vars = ($0 ~ /^[[:space:]]*\[[[:space:]]*vars[[:space:]]*\][[:space:]]*(#.*)?\r?$/)
      if (in_vars) seen = 1
      print; next
    }
    in_vars {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, ENVIRON["KEY"]) == 1 && substr(line, length(ENVIRON["KEY"]) + 1) ~ /^[[:space:]]*=/) {
        if (!done) { print ENVIRON["LINE"]; done = 1 }
        next
      }
    }
    { print }
    END { if (!done) { if (!seen) print "[vars]"; print ENVIRON["LINE"] } }' "$file" >"$tmp" && mv "$tmp" "$file"
}

valid_mode() { [[ "${1:-}" == owned || "${1:-}" == shared ]]; }

# Prompts read fd 3: /dev/tty in real runs (so `curl | bash` still prompts),
# a here-string in tests.
open_prompt_fd() {
  { true <&3; } 2>/dev/null && return 0
  # `exec 3</dev/tty 2>/dev/null` (no command word) applies BOTH redirects to
  # the shell PERMANENTLY, not just to this attempt — a missing controlling
  # terminal would then silently redirect fd 2 to /dev/null for the rest of
  # the run. Scoping `2>/dev/null` to a `{ }` group keeps it (and any "No
  # such device" diagnostic) local to this one open attempt; `exec 3<...`
  # inside the group still opens fd 3 permanently, which is what we want.
  { exec 3</dev/tty; } 2>/dev/null
}

prompt_mode() {
  local choice
  {
    echo "Is this host yours?"
    echo "  1) owned    my machine — sudo, full install"
    echo "  2) shared   someone else's — no sudo,"
    echo "              user-level toolbelt only"
  } >&2
  while :; do
    printf 'Choose [1/2]: ' >&2
    IFS= read -r choice <&3 || fail "No answer to the setup-mode question."
    case "$choice" in
    1 | owned) echo owned && return 0 ;;
    2 | shared) echo shared && return 0 ;;
    *) echo "  Please answer 1 or 2." >&2 ;;
    esac
  done
}

# --- Step functions ------------------------------------------------------------

# =============================================================================
# PREFLIGHT — collect-all prereq check (curl, git, tar).
# =============================================================================
preflight() {
  log "Checking prerequisites..."

  local missing=()
  command -v curl &>/dev/null || missing+=("curl")
  command -v git &>/dev/null || missing+=("git")
  command -v tar &>/dev/null || missing+=("tar (for archive extraction)")

  if ((${#missing[@]} > 0)); then
    fail "Missing required prerequisites: ${missing[*]}
Install via your distro's package manager, e.g.
  RHEL/Fedora:   sudo dnf install curl git tar
  Debian/Ubuntu: sudo apt install curl git tar"
  fi

  ok "Prerequisites OK"
}

# =============================================================================
# CLONE OR UPDATE REPO — clone the workstation repo into $REPO_DIR, or
# `git pull --ff-only` if it's already there.
# =============================================================================
clone_or_update_repo() {
  # The repo is public, so no token is needed. If GITHUB_TOKEN is set anyway
  # (e.g. bootstrapping from a private fork), use it via http.extraheader
  # (scoped to github.com); it is persisted into the cloned repo's .git/config
  # so subsequent push/pull auth too.
  #
  # HTTP Basic with a base64-encoded "x-access-token:<PAT>" pair — the same
  # scheme GitHub Actions' `actions/checkout` uses. `Authorization: bearer`
  # works for the REST/raw API (and that's how curl fetches bootstrap.sh) but
  # is NOT accepted by git's smart-HTTP endpoint on github.com — GitHub falls
  # through to credential prompting, which breaks any non-interactive clone.
  local gh_header_val="" gh_header_b64
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    gh_header_b64=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
    gh_header_val="Authorization: Basic $gh_header_b64"
  fi

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "Cloning workstation repo into $REPO_DIR..."
    if [[ -n "$gh_header_val" ]]; then
      git -c "${GH_HEADER_KEY}=${gh_header_val}" clone "$DOTFILES_REPO" "$REPO_DIR" ||
        fail "Clone failed. Check network access to github.com, and that GITHUB_TOKEN is a valid PAT (it is only needed for a private fork)."
      git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$gh_header_val"
    else
      git clone "$DOTFILES_REPO" "$REPO_DIR" ||
        fail "Clone failed. Check network access to github.com (a private fork also needs GITHUB_TOKEN set to a PAT with repo read)."
    fi
    ok "Repo cloned"
  else
    log "Repo already present at $REPO_DIR — pulling latest..."
    # Refresh the stored token if a new one was passed in this invocation.
    if [[ -n "$gh_header_val" ]]; then
      git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$gh_header_val"
    fi
    # A failed pull means we'd run mise bootstrap against a stale-or-broken tree —
    # better to bail out and let the user inspect.
    if ! git -C "$REPO_DIR" pull --ff-only; then
      fail "git pull --ff-only failed in $REPO_DIR.
This usually means stale credentials in .git/config, or local commits/conflicts.
Inspect with:
  cd $REPO_DIR && git status && git log --oneline -5

To start over from scratch (wipes the cloned repo, not your tools/dotfiles):
  ./bootstrap.sh --reinstall"
    fi
  fi
}

# =============================================================================
# INSTALL MISE — the pinned mise binary into ~/.local/bin (sha256-verified).
# mise installs every other tool from config*.toml.
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

# Mode: saved in config.local.toml, else WORKSTATION_MODE, else a prompt.
# Name/email are asked on a first run; without a terminal they are left
# unset (templates guard them) rather than blocking an unattended run.
resolve_host_config() {
  local cfg="$REPO_DIR/config.local.toml" name email
  MODE=$(config_get "$cfg" mode)
  if [[ -n "$MODE" ]]; then
    valid_mode "$MODE" || fail "$cfg has mode = \"$MODE\" — expected owned or shared. Fix or delete that line and re-run."
    ok "mode: $MODE (saved in config.local.toml)"
  elif [[ -n "${WORKSTATION_MODE:-}" ]]; then
    valid_mode "$WORKSTATION_MODE" || fail "WORKSTATION_MODE=$WORKSTATION_MODE — expected owned or shared."
    MODE=$WORKSTATION_MODE
    ok "mode: $MODE (from WORKSTATION_MODE)"
  elif open_prompt_fd; then
    MODE=$(prompt_mode)
    ok "mode: $MODE"
  else
    fail "No terminal to ask the setup mode on.
   Re-run interactively:  ssh -t <host> '...'
   or answer up front:    WORKSTATION_MODE=shared   (or owned)"
  fi
  config_set "$cfg" mode "$MODE"

  name=$(config_get "$cfg" name)
  email=$(config_get "$cfg" email)
  if [[ -n "$name" && -n "$email" ]]; then
    return 0
  fi
  if ! open_prompt_fd; then
    warn "No terminal to ask your name/email on — add them to $cfg ([vars] name = \"…\", email = \"…\") for git commits."
    return 0
  fi
  log "First-time setup — name/email for git commits and the SSH config comment..."
  if [[ -z "$name" ]]; then
    printf '  Name: ' >&2
    IFS= read -r name <&3 || true
  fi
  if [[ -z "$email" ]]; then
    printf '  Email: ' >&2
    IFS= read -r email <&3 || true
  fi
  [[ -z "$name" ]] || config_set "$cfg" name "$name"
  [[ -z "$email" ]] || config_set "$cfg" email "$email"
  if [[ -n "$name" && -n "$email" ]]; then
    ok "name/email saved to $cfg"
  else
    warn "name/email incomplete — add the missing value(s) to $cfg ([vars] name = \"…\", email = \"…\")"
  fi
}

# =============================================================================
# APPLY — carry MISE_ENV onto the live systemd user manager, install tools,
# then run `mise bootstrap` (packages, /etc files, services, compose, repos,
# dotfiles, tools gate, then the `bootstrap` task itself). Sudo (owned hosts
# only) is scoped to the dnf batch and /etc files inside mise's own
# elevation — this script never runs sudo directly.
# =============================================================================
apply() {
  # The user manager must carry MISE_ENV for the pueued shim; environment.d
  # covers the next login, this covers the live manager.
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user set-environment "MISE_ENV=$MISE_ENV" || warn "could not set MISE_ENV on the systemd user manager"
  fi

  # config.local.toml (mode, and name/email if given) is already written by
  # resolve_host_config in main(), before this function runs — the Tera
  # templates guard every vars.* reference, but a real value still shapes
  # the rendered git identity.
  log "mise install (tools) — MISE_ENV=$MISE_ENV"
  "$REPO_DIR/scripts/lib/mise-install.sh" || fail "mise install failed — see above"

  # A host bootstrapped before the marker existed may still have real files
  # at these dotfiles targets — symlink/copy/template modes all refuse a
  # pre-existing real file, so even --dry-run would exit 1 without
  # --force-dotfiles. Pass it ONLY until this host's own marker exists, so
  # any LATER conflict (a real mistake) is still surfaced loudly instead of
  # silently reclaimed. The marker file name (dotfiles-migrated) is kept so
  # existing hosts do not force again.
  local marker="${XDG_STATE_HOME:-$HOME/.local/state}/workstation/dotfiles-migrated"
  local dotfiles_flags=()
  if [[ ! -f "$marker" ]]; then
    dotfiles_flags=(--force-dotfiles)
    log "First dotfiles apply on this host — passing --force-dotfiles (marker absent: $marker)"
  fi

  log "mise bootstrap — packages, /etc files, services, compose, repos, dotfiles, tools gate, then the bootstrap task"
  if [[ "$MODE" == "owned" ]]; then
    log "owned host — sudo will prompt for the dnf batch and /etc files"
  fi
  if ! mise bootstrap --yes "${dotfiles_flags[@]}"; then
    fail "mise bootstrap failed — see the failing phase above.

A dotfiles conflict aborts the WHOLE dotfiles phase (one bad entry blocks
every entry — nothing gets applied). If the failure names a target that
already exists as a real file:
  1. resolve that one entry directly:  mise dot apply --force <the path mise named above>
  2. then re-run:                      ./bootstrap.sh
For any other phase (packages, services, compose, repos, tools), re-running
this script is idempotent — fix what's reported above and run again."
  fi
  ok "mise bootstrap complete"

  if [[ ! -f "$marker" ]]; then
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
    ok "first-apply marker written ($marker)"
  fi
}

# =============================================================================
# SET LOGIN SHELL — switch the login shell to zsh. Owned hosts only — main
# calls this only when $MODE == owned, since shared hosts have no sudo.
#
# ~/.zshrc is a mise dotfiles template (config.linux.toml [dotfiles]);
# switching the login shell is what makes new SSH/WSL sessions actually read
# it. `chsh` isn't installed by default on AlmaLinux 9 (needs util-linux-user)
# and even when present requires PAM auth (interactive password). `sudo
# usermod -s` edits /etc/passwd directly instead. Best-effort: prints the
# manual fallback commands when usermod fails (most often: $SUDO_ASKPASS
# missing under curl|bash from a remote machine).
# =============================================================================
set_login_shell() {
  local zsh_path
  zsh_path=$(command -v zsh || true)
  if [[ -z "$zsh_path" ]]; then
    warn "zsh not on PATH — default shell unchanged. Re-run after a manual install:"
    warn "  sudo dnf install -y zsh   (or apt install zsh)"
    return 0
  fi

  # /etc/passwd is authoritative; don't trust $SHELL (set by the parent shell).
  local current_shell
  current_shell=$(getent passwd "$USER" | cut -d: -f7)

  if [[ "$current_shell" == "$zsh_path" ]]; then
    ok "Default shell is already zsh ($zsh_path)"
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
# PRINT NEXT STEPS — closing tips after a successful bootstrap.
# =============================================================================
print_next_steps() {
  echo ""
  echo -e "${BOLD}Bootstrap complete.${RESET}"

  # Only print the "you're on zsh" tip when the user actually is.
  # set_login_shell may have bailed out (shared host, missing zsh binary,
  # usermod refused) and already printed its own follow-up command, so we
  # just stay quiet here. Read the authoritative shell from /etc/passwd —
  # $SHELL was set by the parent process.
  local login_shell zsh_path
  login_shell=$(getent passwd "$USER" | cut -d: -f7)
  zsh_path=$(command -v zsh || true)
  if [[ -n "$zsh_path" && "$login_shell" == "$zsh_path" ]]; then
    echo -e "Log out + back in (or open a new tab) to land in zsh as your login shell."
  fi

  if is_wsl; then
    echo -e "Running inside WSL — opening a new Windows Terminal tab into this distro lands you"
    echo -e "  in ${YELLOW}~${RESET} with the dotfiles-tracked aliases active."
  else
    echo -e "Enable passwordless SSH from your client:"
    echo -e "  ${YELLOW}ssh-copy-id $(whoami)@$(hostname -s)${RESET}  (Linux/WSL, and Windows via the PowerShell profile's ssh-copy-id)"
  fi
  if [[ "$MODE" == owned ]]; then
    echo -e "Re-configure the Claude Code statusline any time:"
    echo -e "  ${YELLOW}mise run statusline${RESET}"
  fi
  echo -e "Health check any time: ${YELLOW}mise run health${RESET}"
}

# =============================================================================
# DO REINSTALL — wipe the cloned repo, then let the rest of the script
# re-bootstrap fresh. Installed tools and deployed dotfiles are left alone —
# re-running the bootstrap is idempotent on those, so the net effect is a
# fresh repo + fresh config.local.toml prompt (resolve_host_config).
# =============================================================================
do_reinstall() {
  log "Reinstall mode — wipe + re-bootstrap"
  echo ""
  echo "  Will REMOVE:"
  echo "    - $REPO_DIR   (cloned workstation repo)"
  echo ""
  echo "  Will NOT remove (leaving for re-bootstrap to no-op over):"
  echo "    - Installed tools in ~/.local/bin (tools are user-level)"
  echo "    - dnf packages, SSH keys"
  echo "    - Deployed dotfiles in \$HOME (mise bootstrap will re-apply over them)"
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
    if [[ "$script_real" == "$REPO_DIR"* ]]; then
      fail "Refusing to reinstall — running script is inside $REPO_DIR.
Either pipe the remote script (runs from memory):
  curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --reinstall

Or copy this script out of the repo first:
  cp $script_real /tmp/bootstrap.sh && bash /tmp/bootstrap.sh --reinstall"
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

  echo ""
  log "Wipe complete — continuing with fresh bootstrap..."
  echo ""
}

# =============================================================================
# REQUIRE REPO — doctor/check-updates need a bootstrapped repo to inspect.
# =============================================================================
require_repo() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    fail "No workstation repo at $REPO_DIR — bootstrap this host first:
  ./bootstrap.sh"
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

# =============================================================================
# DO DOCTOR / DO CHECK UPDATES — read-only report modes (--doctor /
# --check-for-updates). Both exit before the provisioning flow starts:
# nothing is cloned, installed, or changed. This script owns only the
# repo-level checks (prereqs, git state, dotfiles drift, login shell) and
# delegates ALL per-tool and host-state knowledge to `mise run health` /
# `mise run check-updates`.
# =============================================================================
do_doctor() {
  require_repo
  log "Doctor — read-only health report; nothing is installed or changed"
  echo ""

  # Same prereq list as preflight, but report-all instead of hard-fail.
  log "Prerequisites"
  local cmd
  for cmd in curl git tar; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      warn "$cmd missing — install via your distro's package manager (see ./bootstrap.sh --help)"
    fi
  done
  echo ""

  report_repo_state
  echo ""

  MODE=$(config_get "$REPO_DIR/config.local.toml" mode)
  if ! valid_mode "$MODE"; then
    # report_repo_state already ran above — don't fetch/report twice.
    warn "mode not set — run ./bootstrap.sh once to choose owned or shared"
    exit 1
  fi
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
  export MISE_ENV
  ok "mode: $MODE"

  log "dotfiles"
  if ! command -v mise >/dev/null 2>&1; then
    warn "mise not on PATH — can't check dotfiles status"
  elif mise dot status --missing >/dev/null 2>&1; then
    ok "deployed dotfiles in sync with the source (mise dot status)"
  else
    warn "drift — inspect: mise dot status · apply: mise dot apply"
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
    warn "login shell is $login_shell, not zsh — fix: sudo usermod -s $zsh_path $USER (owned) / chsh -s $zsh_path (shared)"
  fi
  echo ""

  log "mise"
  if command -v mise >/dev/null 2>&1; then ok "mise $(mise --version 2>/dev/null | awk '{print $1}') on PATH ($(command -v mise)) — pinned $MISE_VERSION"; else warn "mise not on PATH — re-run ./bootstrap.sh"; fi
  echo ""

  log "Tools, host state, services — mise run health"
  mise run health
  exit $?
}

do_check_updates() {
  require_repo
  MODE=$(config_get "$REPO_DIR/config.local.toml" mode)
  if ! valid_mode "$MODE"; then
    warn "mode not set — run ./bootstrap.sh once to choose owned or shared"
    report_repo_state
    exit 1
  fi
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
  export MISE_ENV
  log "Check for updates (mode=${MODE}) — workstation repo first, then tool pins vs upstream"
  echo ""

  report_repo_state
  echo "    (tool pins live in config*.toml + config.toml [vars] of THIS clone — if the repo"
  echo "     is behind, pull first so the pins you're comparing are current)"
  echo ""

  mise run check-updates
  exit $?
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  parse_args "$@"

  case "$ACTION" in
  doctor) do_doctor ;;
  check-updates) do_check_updates ;;
  esac

  if [[ "$REINSTALL" == true ]]; then
    do_reinstall
  fi
  preflight
  mkdir -p "$BIN"
  export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"

  clone_or_update_repo
  install_mise

  # Inherited fd 3 is dropped so the prompt reads /dev/tty, not whatever the
  # caller happened to pass in; fd 3 is closed again afterwards so /dev/tty
  # isn't inherited by mise/sudo/the bootstrap task below. Scoped
  # `2>/dev/null` (see open_prompt_fd) so a "not open" close never leaks or
  # clobbers stderr.
  { exec 3<&-; } 2>/dev/null || true
  resolve_host_config
  { exec 3<&-; } 2>/dev/null || true

  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MODE")"
  export MISE_ENV
  log "mise environment: MISE_ENV=$MISE_ENV"

  apply
  if [[ "$MODE" == owned ]]; then
    set_login_shell
  fi

  # ccstatusline setup (owned hosts only) — interactive prompt for the Claude
  # Code statusline. Re-runnable any time via `mise run statusline`.
  if [[ "$MODE" == owned && -t 0 ]]; then
    mise run statusline || true
  fi

  print_next_steps
}

# bash reads the whole file before main runs, so a truncated `curl | bash`
# download can't execute a partial script — this line must stay last.
[[ "${WORKSTATION_BOOTSTRAP_LIB:-}" == 1 ]] || main "$@"
