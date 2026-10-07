#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (mise seed). Clones this repo into
# ~/.config/mise, installs the pinned mise binary, then runs `mise bootstrap`
# to install tools, packages, /etc files, services, and dotfiles. Idempotent —
# safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#
# Every host gets the same setup. The steps that need sudo (dnf packages, /etc
# files, zsh as login shell) run when sudo works and are skipped, with a
# warning, when it doesn't; see resolve_system_steps.
#
# See ./bootstrap.sh --help for flags (--reinstall, --yes).
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
# DUAL-EDIT with bootstrap.ps1 $MiseVersion, min_version in config.toml and the
# CI workflows' mise-action `version:` — scripts/check-invariants.sh asserts all agree.
MISE_VERSION="2026.9.9"
MISE_SHA256="986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc" # mise-v${MISE_VERSION}-linux-x64-musl.tar.gz

# --- Usage ---------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [flags]

Sets up this host with mise: the toolbelt, dotfiles and, where sudo works,
system packages, /etc files and zsh as login shell. Without sudo those are
skipped (the result is saved as sudo = "no" in ~/.config/mise/config.local.toml;
re-run with sudo to apply them).

Flags:
  --reinstall   Wipe the cloned repo (incl. config.local.toml), then bootstrap
                fresh. Installed tools and deployed dotfiles stay.
  --yes, -y     Skip the --reinstall confirmation prompt.
  -h, --help    Show this message.

Health report: mise run health. Update scan: mise run check-updates.
EOF
}

# --- Argument parsing ---------------------------------------------------------
# Accepts in any order: --reinstall, --yes/-y.
parse_args() {
  REINSTALL=false
  YES=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --reinstall)
      REINSTALL=true
      shift
      ;;
    --yes | -y)
      YES=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "Unknown argument: $1 (try --help)" ;;
    esac
  done
}

# --- Config helpers ------------------------------------------

# config.local.toml is `key = "value"` lines under [vars], so plain awk reads
# and writes it — no Python needed before tools exist. The reader also takes
# hand edits: a trailing comment and 'literal' strings.
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
        sub(/^[^=]*=[[:space:]]*/, "", line)
        q = substr(line, 1, 1); out = ""
        if (q == "\"") {
          # Basic string: \" and \\ unescape; the closing quote ends it.
          for (i = 2; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\\") {
              n = substr(line, i + 1, 1)
              if (n == "\"" || n == "\\") { out = out n; i++; continue }
            }
            if (c == "\"") break
            out = out c
          }
        } else if (q == "\047") {
          # Literal string: no escapes; the next single quote ends it.
          out = substr(line, 2)
          j = index(out, "\047")
          if (j) out = substr(out, 1, j - 1)
        } else {
          # Unquoted (not valid TOML): the value up to a comment.
          out = line
          sub(/[[:space:]]*(#.*)?\r?$/, "", out)
        }
        print out; exit
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

# sudo_state <file>: the saved decision; a missing value means yes (hosts set up
# before the decision was saved all had sudo).
sudo_state() {
  [[ "$(config_get "$1" sudo)" == no ]] && echo no || echo yes
}

# detect_sudo: 0 sudo works, 1 it doesn't (no binary, or the password prompt
# failed or was interrupted with Ctrl-C), 2 undecided (no terminal to ask on
# and no cached credentials). The terminal sends Ctrl-C's SIGINT to the whole
# foreground group, this shell included, so it is trapped around sudo -v alone.
# sudo -v reads the password from the terminal itself, and the credentials it
# caches cover mise's own sudo calls for the rest of the run.
detect_sudo() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true 2>/dev/null && return 0
  open_prompt_fd || return 2
  local rc=0
  trap ':' INT
  sudo -v || rc=$?
  trap - INT
  [[ $rc -eq 0 ]] && return 0
  return 1
}

# resolve_system_steps: SYSTEM=yes|no for this run. A real answer is saved as
# vars.sudo, so `mise run update` never has to ask; "no terminal" decides
# nothing beyond this run.
resolve_system_steps() {
  local cfg="$REPO_DIR/config.local.toml" rc=0
  detect_sudo || rc=$?
  case "$rc" in
  0) SYSTEM=yes && config_set "$cfg" sudo yes ;;
  1) SYSTEM=no && config_set "$cfg" sudo no ;;
  *) SYSTEM=no ;;
  esac
  if [[ "$SYSTEM" == no ]]; then
    warn "No sudo here — skipping the system steps: dnf packages, /etc files, zsh as login shell."
    warn "  Everything user-level still installs. To apply them later: get sudo, then re-run ./bootstrap.sh"
  fi
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
  # The repo is public: a plain HTTPS clone, no token.
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "Cloning workstation repo into $REPO_DIR..."
    git clone "$DOTFILES_REPO" "$REPO_DIR" ||
      fail "Clone failed. Check network access to github.com."
    ok "Repo cloned"
  else
    log "Repo already present at $REPO_DIR — pulling latest..."
    # A failed pull means we'd run mise bootstrap against a stale-or-broken tree —
    # better to bail out and let the user inspect.
    if ! git -C "$REPO_DIR" pull --ff-only; then
      fail "git pull --ff-only failed in $REPO_DIR.
This usually means local commits or conflicts.
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

# Name/email are asked on a first run; without a terminal they are left
# unset (templates guard them) rather than blocking an unattended run.
resolve_host_config() {
  local cfg="$REPO_DIR/config.local.toml" name email
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
# APPLY — install tools, then run `mise bootstrap` (packages, /etc files, services, compose, repos,
# dotfiles, tools gate, then the `bootstrap` task itself). Sudo is scoped to
# the dnf batch and /etc files inside mise's own elevation, and skipped
# entirely when SYSTEM=no.
# =============================================================================
apply() {
  # config.local.toml (name/email if given, sudo) is already written by
  # resolve_host_config in main(), before this function runs — the Tera
  # templates guard every vars.* reference, but a real value still shapes
  # the rendered git identity.
  log "mise install (tools) — $TOKENS"
  "$REPO_DIR/scripts/lib/mise-install.sh" || fail "mise install failed — see above"

  # Forces only on the first apply: a fresh host's pre-existing files (e.g.
  # /etc/skel's ~/.bashrc) would otherwise make copy/template refuse. Pass
  # it ONLY until this host's own marker exists, so any LATER conflict (a
  # real mistake) is still surfaced loudly instead of silently reclaimed.
  # The marker file name (dotfiles-migrated) is kept so existing hosts do
  # not force again.
  local marker="${XDG_STATE_HOME:-$HOME/.local/state}/workstation/dotfiles-migrated"
  local dotfiles_flags=()
  if [[ ! -f "$marker" ]]; then
    dotfiles_flags=(--force-dotfiles)
    log "First dotfiles apply on this host — passing --force-dotfiles (marker absent: $marker)"
  fi

  log "mise bootstrap — packages, /etc files, services, compose, repos, dotfiles, tools gate, then the bootstrap task"
  local skip_flags=()
  if [[ "$SYSTEM" == no ]]; then
    skip_flags=(--skip "packages,files")
    log "skipping the system steps (no sudo): mise bootstrap --skip packages,files"
  fi
  if ! mise bootstrap --yes "${dotfiles_flags[@]}" "${skip_flags[@]}"; then
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
# SET LOGIN SHELL — switch the login shell to zsh. Only when SYSTEM=yes (it
# needs sudo).
#
# ~/.zshrc is a mise dotfiles template (config.linux.toml [dotfiles]);
# switching the login shell is what makes new SSH/WSL sessions actually read
# it. Where the account lives decides how:
#  - local (/etc/passwd): `sudo usermod -s`. `chsh` isn't installed by default
#    on AlmaLinux 9 (util-linux-user) and needs PAM auth anyway.
#  - a directory account (AD/LDAP) served by SSSD: the shell comes from the
#    directory, so usermod and chsh fail. `sss_override user-add -s` (sssd-tools)
#    sets a per-host override, applied by restarting sssd.
#  - a directory account outside SSSD (winbind, nslcd): no per-user override
#    exists, so it only explains.
# Best-effort: a failure warns and the bootstrap carries on.
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
  local err
  if getent -s files passwd "$USER" >/dev/null 2>&1; then
    if err=$(sudo usermod -s "$zsh_path" "$USER" 2>&1); then
      ok "Default shell set to zsh — log out + back in (or open a new tab) to land in it"
    else
      warn "usermod couldn't set the login shell: ${err:-no error text}"
      warn "  set it by hand: sudo usermod -s $zsh_path $USER"
    fi
  elif getent -s sss passwd "$USER" >/dev/null 2>&1; then
    set_login_shell_sssd "$zsh_path" "$current_shell"
  else
    warn "$USER is a directory account outside SSSD (not in /etc/passwd): its login shell"
    warn "  comes from the directory and has no per-host override. Ask its admin to set"
    warn "  loginShell to $zsh_path, or start zsh from ~/.bashrc.local."
  fi
}

# set_login_shell_sssd <zsh-path> <current-shell>: a per-host SSSD override for a
# directory account, then an sssd restart so it takes effect.
set_login_shell_sssd() {
  local zsh_path=$1 current_shell=$2 now
  log "$USER is a directory account (SSSD): setting a per-host shell override"
  if ! rpm -q sssd-tools >/dev/null 2>&1 && ! sudo dnf install -y sssd-tools; then
    warn "couldn't install sssd-tools (sss_override); login shell unchanged"
    return 0
  fi
  if ! sudo sss_override user-add "$USER" -s "$zsh_path"; then
    warn "sss_override failed; login shell unchanged"
    return 0
  fi
  sudo systemctl restart sssd || warn "couldn't restart sssd; the override applies after its next restart"
  now=$(getent passwd "$USER" | cut -d: -f7)
  if [[ "$now" == "$zsh_path" ]]; then
    ok "Default shell set to zsh (SSSD override on this host) — log out + back in to land in it"
  else
    warn "SSSD still reports ${now:-$current_shell} for $USER after the override; check: sudo sss_override user-show $USER"
  fi
}

# =============================================================================
# PRINT NEXT STEPS — closing tips after a successful bootstrap.
# =============================================================================
print_next_steps() {
  echo ""
  echo -e "${BOLD}Bootstrap complete.${RESET}"

  # Only print the "you're on zsh" tip when the user actually is. Without
  # sudo set_login_shell never runs, so this stays quiet on its own; with
  # sudo it may have bailed out (missing zsh binary, usermod
  # refused) and already printed its own follow-up command. Read the
  # authoritative shell from /etc/passwd — $SHELL was set by the parent
  # process.
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
  echo -e "Re-configure the Claude Code statusline any time:"
  echo -e "  ${YELLOW}mise run statusline${RESET}"
  echo -e "Health check any time: ${YELLOW}mise run health${RESET}"
}

# Reads the --reinstall confirmation from fd 3, like the other prompts —
# under `curl | bash -s -- --reinstall`, plain stdin is the piped script
# itself, so a plain `read` there hits EOF and set -e used to exit silently
# right after the "Will REMOVE" block. Returns 0 to proceed, 1 to abort.
confirm_reinstall() {
  if [[ "$YES" == true ]]; then
    return 0
  fi
  if ! open_prompt_fd; then
    fail "No terminal to confirm --reinstall on. Re-run with --yes to skip the confirmation."
  fi
  local confirm=""
  printf '  Proceed? [y/N]: ' >&2
  IFS= read -r confirm <&3 || true
  [[ "$confirm" =~ ^[Yy]$ ]]
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
  echo "    - config.local.toml (name, email, sudo) — asked again after the wipe"
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

  if ! confirm_reinstall; then
    warn "Aborted."
    exit 0
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
# MAIN
# =============================================================================
main() {
  # Prompts read fd 3; an inherited one is not our terminal, so drop it
  # before any prompt. Scoped `2>/dev/null` (see open_prompt_fd) so a "not
  # open" close never leaks or clobbers stderr.
  { exec 3<&-; } 2>/dev/null || true
  parse_args "$@"

  if [[ "$REINSTALL" == true ]]; then
    do_reinstall
    # Don't keep /dev/tty open across the clone and mise install.
    { exec 3<&-; } 2>/dev/null || true
  fi
  preflight
  mkdir -p "$BIN"
  export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"

  clone_or_update_repo
  install_mise

  # fd 3 is opened fresh for the prompts, then closed so /dev/tty isn't
  # inherited by mise/sudo/the bootstrap task below.
  { exec 3<&-; } 2>/dev/null || true
  resolve_host_config
  resolve_system_steps
  { exec 3<&-; } 2>/dev/null || true

  TOKENS="$("$REPO_DIR/scripts/lib/mise-env.sh" --write)"
  # miserc.toml is the source from here on; an inherited export would override it.
  unset MISE_ENV
  log "mise config set: $TOKENS (saved in $REPO_DIR/miserc.toml)"

  apply
  if [[ "$SYSTEM" == yes ]]; then
    set_login_shell
  fi

  # ccstatusline setup — interactive prompt for the Claude Code statusline.
  # Re-runnable any time via `mise run statusline`.
  if [[ -t 0 ]]; then
    mise run statusline || true
  fi

  print_next_steps
}

# bash reads the whole file before main runs, so a truncated `curl | bash`
# download can't execute a partial script — this line must stay last.
[[ "${WORKSTATION_BOOTSTRAP_LIB:-}" == 1 ]] || main "$@"
