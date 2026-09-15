#!/usr/bin/env bash
# doctor.sh — read-only health report over the make-managed install surface.
#
# Invoked by `make doctor MODE=dev|prod` (makefile/Makefile), which pipes one
# row per managed component on stdin and passes the dnf package lists via env:
#
#   scope|<name>|<version>     TOOL/EGET_TOOL registrations  → binary in $DEST
#   user|<name>|<version>      USER_TOOL registrations       → ~/.local/bin (pip)
#   bespoke|<name>|<version>   bespoke Makefile targets (claude-cli,
#                              mise-runtimes, nerd-fonts, docker-engine,
#                              dozzle-service, cockpit-service, rsyslog-service,
#                              wsl-config)
#
# Env (exported by the Makefile/scope.mk): DEST, STAMP, MODE, IS_WSL, HAS_SUDO.
# Recipe-passed: LINUX_PACKAGES, LINUX_OPTIONAL_PACKAGES.
#
# Per-tool verdicts (stamp = $STAMP/<stamp-key>-<version>.done):
#   ✓  binary present + pinned stamp present
#   !  binary present, pinned stamp missing — the pin moved (or the stamp was
#      wiped); the next `make provision` reinstalls it
#   ✗  stamp without binary (manual delete?) or fully missing — the line
#      carries the exact `make` command that repairs it
#   ·  not applicable in this scope (dev-only target on prod, non-WSL, …)
#
# READ-ONLY: no installs, no sudo, exits 0 always (it's a report, not a gate).
# Must be invoked with CWD = makefile/ (make does this) — the wsl-config check
# reads ../configs/wsl/wsl.conf relative to it.

set -euo pipefail

: "${DEST:?doctor.sh: DEST not set (run via: make doctor MODE=dev|prod)}"
: "${STAMP:?doctor.sh: STAMP not set (run via: make doctor MODE=dev|prod)}"
: "${MODE:?doctor.sh: MODE not set (run via: make doctor MODE=dev|prod)}"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

n_ok=0
n_warn=0
n_bad=0
n_skip=0

hdr() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
row_ok() {
  printf ' %s✓%s %-16s %s\n' "$GREEN" "$RESET" "$1" "$2"
  n_ok=$((n_ok + 1))
}
row_warn() {
  printf ' %s!%s %-16s %s\n' "$YELLOW" "$RESET" "$1" "$2"
  n_warn=$((n_warn + 1))
}
row_bad() {
  printf ' %s✗%s %-16s %s\n' "$RED" "$RESET" "$1" "$2"
  n_bad=$((n_bad + 1))
}
row_skip() {
  printf ' · %-16s %s\n' "$1" "$2"
  n_skip=$((n_skip + 1))
}

# Registered-name → installed-binary-name exceptions. The stamp always uses
# the registered name; these three release archives ship a different binary.
bin_for() {
  case "$1" in
  helix) echo hx ;;
  television) echo tv ;;
  bottom) echo btm ;;
  *) echo "$1" ;;
  esac
}

# check_component <label> <stamp-key> <binary> <bindir> <version>
# label = make target name (used in the repair hints); stamp-key differs from
# it only for the bespoke targets (claude-cli stamps as claude-*, etc.).
check_component() {
  local label=$1 key=$2 bin=$3 bindir=$4 version=$5
  local have_bin=false have_stamp=false
  [[ -x "$bindir/$bin" ]] && have_bin=true
  [[ -f "$STAMP/$key-$version.done" ]] && have_stamp=true
  if $have_bin && $have_stamp; then
    row_ok "$label" "$version"
  elif $have_bin; then
    row_warn "$label" "installed, but no $version stamp — pin moved? next 'make provision' reinstalls"
  elif $have_stamp; then
    row_bad "$label" "stamped but $bindir/$bin is gone — repair: make clean-$label $label MODE=$MODE"
  else
    row_bad "$label" "missing — install: make $label MODE=$MODE"
  fi
}

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

check_bespoke() {
  local name=$1 version=$2
  # Everything in this section is dev_machine-only except the three both-scopes
  # rows: wsl-config, mise-runtimes (uv on prod) and python-env.
  case "$name" in
  wsl-config | mise-runtimes | python-env) ;;
  *)
    if [[ "$MODE" != dev ]]; then
      row_skip "$name" "dev_machine only (MODE=$MODE)"
      return
    fi
    ;;
  esac
  case "$name" in
  claude-cli)
    check_component claude-cli claude claude "$HOME/.local/bin" "$version"
    ;;
  mise-runtimes)
    # $version is the cksum of the consumed conf.d file(s) (the stamp suffix),
    # so a pin change shows as "pins moved". Presence = one shim per tool the
    # config declares for this scope; mise's own binary is a scope-tool row.
    local shims="${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims" want b missing=()
    if [[ "$MODE" == dev ]]; then
      want="node npm npx go gofmt uv uvx gopls lua-language-server basedpyright-langserver typescript-language-server bash-language-server yaml-language-server vscode-json-language-server"
    else
      want="uv uvx"
    fi
    for b in $want; do
      [[ -x "$shims/$b" ]] || missing+=("$b")
    done
    if [[ -f "$STAMP/mise-runtimes-$version.done" ]] && ((${#missing[@]} == 0)); then
      row_ok "$name" "all shims present ($shims)"
    elif ((${#missing[@]} == 0)); then
      row_warn "$name" "shims present, but no $version stamp — pins moved? next 'make provision' reinstalls"
    else
      row_bad "$name" "missing shims: ${missing[*]} — install: make mise-runtimes MODE=$MODE"
    fi
    ;;
  nerd-fonts)
    if [[ "${IS_WSL:-false}" == true ]]; then
      if [[ -f "$STAMP/nerd-fonts-$version.done" ]]; then
        row_ok "$name" "WSL — Windows side owns fonts (skip-stamp present)"
      else
        row_warn "$name" "WSL skip not stamped yet — next 'make provision' writes it"
      fi
    else
      local fdir="$HOME/.local/share/fonts/JetBrainsMonoNerdFontMono"
      local have_dir=false have_stamp=false
      [[ -d "$fdir" ]] && have_dir=true
      [[ -f "$STAMP/nerd-fonts-$version.done" ]] && have_stamp=true
      if $have_dir && $have_stamp; then
        row_ok "$name" "$version ($fdir)"
      elif $have_dir; then
        row_warn "$name" "fonts present, no $version stamp — next 'make provision' reinstalls"
      else
        row_bad "$name" "missing — install: make nerd-fonts MODE=dev"
      fi
    fi
    ;;
  docker-engine)
    if [[ "${IS_WSL:-false}" == true ]]; then
      row_skip "$name" "WSL — Docker Desktop on the Windows host owns the engine"
    elif command -v docker >/dev/null 2>&1; then
      if svc_active docker; then
        row_ok "$name" "docker on PATH, service active"
      else
        row_warn "$name" "docker installed but service inactive — sudo systemctl start docker"
      fi
    else
      row_bad "$name" "docker missing — install: make docker-engine MODE=dev"
    fi
    ;;
  dozzle-service)
    if [[ "${IS_WSL:-false}" == true ]]; then
      row_skip "$name" "WSL — web-admin stack lives on the Windows host"
    elif svc_active dozzle.service; then
      row_ok "$name" "active (image pin $version)"
    elif [[ -f /etc/systemd/system/dozzle.service ]]; then
      row_warn "$name" "unit installed but inactive — sudo systemctl start dozzle"
    else
      row_bad "$name" "not installed — install: make dozzle-service MODE=dev"
    fi
    ;;
  cockpit-service)
    if [[ "${IS_WSL:-false}" == true ]]; then
      row_skip "$name" "WSL — web-admin stack lives on the Windows host"
    elif svc_active cockpit.socket; then
      row_ok "$name" "cockpit.socket active"
    elif rpm -q cockpit >/dev/null 2>&1; then
      row_warn "$name" "cockpit package present, socket inactive — make cockpit-service MODE=dev"
    else
      row_bad "$name" "not installed — install: make packages cockpit-service MODE=dev"
    fi
    ;;
  wsl-config)
    if [[ "${IS_WSL:-false}" != true ]]; then
      row_skip "$name" "not a WSL host"
    elif [[ "${HAS_SUDO:-false}" != true ]]; then
      row_skip "$name" "needs sudo (MODE=$MODE) — /etc/wsl.conf unmanaged here"
    else
      local sha=""
      [[ -f ../configs/wsl/wsl.conf ]] && sha=$(sha256sum ../configs/wsl/wsl.conf | cut -c1-12)
      if [[ -n "$sha" && -f "$STAMP/wsl-config-$sha.done" && -f /etc/wsl.conf ]]; then
        row_ok "$name" "/etc/wsl.conf current (content $sha)"
      elif [[ -f /etc/wsl.conf ]]; then
        row_warn "$name" "tracked configs/wsl/wsl.conf changed (or stamp missing) — make wsl-config MODE=dev redeploys"
      else
        row_bad "$name" "/etc/wsl.conf not deployed — install: make wsl-config MODE=dev"
      fi
    fi
    ;;
  rsyslog-service)
    if [[ "${IS_WSL:-false}" == true ]]; then
      row_skip "$name" "WSL — host logging is handled on the Windows side"
    elif ! rpm -q rsyslog >/dev/null 2>&1; then
      row_bad "$name" "rsyslog missing — install: make packages rsyslog-service MODE=dev"
    else
      local sha=""
      [[ -f ../configs/rsyslog/30-workstation.conf ]] && sha=$(sha256sum ../configs/rsyslog/30-workstation.conf | cut -c1-12)
      if [[ -n "$sha" && -f "$STAMP/rsyslog-service-$sha.done" && -f /etc/rsyslog.d/30-workstation.conf ]] && svc_active rsyslog; then
        row_ok "$name" "active, drop-in current (content $sha)"
      elif [[ -f /etc/rsyslog.d/30-workstation.conf ]]; then
        row_warn "$name" "drop-in changed or service inactive — make rsyslog-service MODE=dev redeploys + restarts"
      else
        row_bad "$name" "drop-in not deployed — install: make rsyslog-service MODE=dev"
      fi
    fi
    ;;
  pwndbg)
    check_component pwndbg pwndbg pwndbg "$DEST" "$version"
    ;;
  vcpkg)
    check_component vcpkg vcpkg vcpkg "$DEST" "$version"
    ;;
  python-env)
    # $version is "<PYTHON_VERSION>-<cksum-of-lib/python-env.sh>" — matches the
    # stamp suffix, so a pin bump OR lib-list edit shows as "pin moved".
    check_component python-env python-env wpy "$HOME/.local/bin" "$version"
    ;;
  *)
    row_warn "$name" "doctor.sh has no check for this bespoke target — add one"
    ;;
  esac
}

packages_section() {
  [[ "$MODE" == dev ]] || return 0
  echo ""
  hdr "system packages (dnf)"
  if ! command -v rpm >/dev/null 2>&1; then
    row_skip packages "rpm not available — package check skipped"
    return 0
  fi
  local pkg missing_core=() missing_opt=() core_total opt_total
  for pkg in ${LINUX_PACKAGES:-}; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing_core+=("$pkg")
  done
  for pkg in ${LINUX_OPTIONAL_PACKAGES:-}; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing_opt+=("$pkg")
  done
  core_total=$(wc -w <<<"${LINUX_PACKAGES:-}")
  opt_total=$(wc -w <<<"${LINUX_OPTIONAL_PACKAGES:-}")
  if ((${#missing_core[@]} > 0)); then
    row_bad core "${#missing_core[@]}/$core_total missing (${missing_core[*]}) — make packages MODE=dev"
  else
    row_ok core "all $core_total installed"
  fi
  if ((${#missing_opt[@]} > 0)); then
    row_warn optional "$((opt_total - ${#missing_opt[@]}))/$opt_total installed (missing: ${missing_opt[*]}; best-effort list)"
  else
    row_ok optional "all $opt_total installed"
  fi
}

# --- wiring — tools that need more than a binary on PATH ---------------------
# verify-binary.sh gates "installed but won't RUN"; this gates "installed but
# won't DO anything": tools whose value depends on a shell hook or a running
# daemon. Read-only, like everything else in this report.
check_wiring() {
  hdr "wiring (shell hooks + daemons)"

  # mise — inert without `mise activate` in the interactive shell rc.
  if command -v mise >/dev/null 2>&1; then
    if grep -q 'mise activate' "$HOME/.zshrc" 2>/dev/null; then
      row_ok "mise" "activated in ~/.zshrc"
    else
      row_warn "mise" "no 'mise activate' in ~/.zshrc — run: chezmoi apply"
    fi
  else
    row_skip "mise" "not installed"
  fi

  # mise shims — non-interactive shells (`ssh host cmd`, Make over
  # update-hosts.sh, IDE/LSP spawns) only see mise-managed tools through the
  # shims dir: ~/.zshenv (chezmoi dot_zshenv) and ~/.bashrc above its guard.
  if command -v mise >/dev/null 2>&1; then
    if grep -q 'mise/shims' "$HOME/.zshenv" 2>/dev/null; then
      row_ok "mise-shims" "on PATH via ~/.zshenv (non-interactive shells)"
    else
      row_warn "mise-shims" "no shims line in ~/.zshenv — run: chezmoi apply"
    fi
  fi

  # pueued — every pueue command fails until the daemon runs.
  if command -v pueued >/dev/null 2>&1; then
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
      row_skip "pueued" "no systemd user manager (start manually: pueued -d)"
    elif systemctl --user is-active --quiet pueued.service; then
      row_ok "pueued" "user service active"
    else
      row_warn "pueued" "daemon not running — run: systemctl --user enable --now pueued (jobs that must survive logout also need: loginctl enable-linger)"
    fi
  else
    row_skip "pueued" "not installed"
  fi
}

main() {
  local scope_rows=() user_rows=() bespoke_rows=() row name version

  while IFS= read -r row; do
    case "$row" in
    scope\|*) scope_rows+=("$row") ;;
    user\|*) user_rows+=("$row") ;;
    bespoke\|*) bespoke_rows+=("$row") ;;
    '') ;;
    *) printf 'doctor.sh: ignoring malformed row: %s\n' "$row" >&2 ;;
    esac
  done

  hdr "workstation doctor — MODE=$MODE · DEST=$DEST · WSL=${IS_WSL:-false} · read-only"
  printf '   stamps: %s\n' "$STAMP"
  echo ""

  hdr "scope tools (${#scope_rows[@]}) → $DEST"
  while IFS='|' read -r _ name version; do
    check_component "$name" "$name" "$(bin_for "$name")" "$DEST" "$version"
  done < <(printf '%s\n' "${scope_rows[@]}" | sort -t'|' -k2,2)
  echo ""

  hdr "user tools (${#user_rows[@]}) → $HOME/.local/bin (pip user-site)"
  while IFS='|' read -r _ name version; do
    check_component "$name" "$name" "$name" "$HOME/.local/bin" "$version"
  done < <(printf '%s\n' "${user_rows[@]}" | sort -t'|' -k2,2)
  echo ""

  hdr "dev-only components & services"
  for row in "${bespoke_rows[@]}"; do
    IFS='|' read -r _ name version <<<"$row"
    check_bespoke "$name" "$version"
  done

  packages_section

  echo ""
  check_wiring

  echo ""
  hdr "summary"
  printf '   %d ok · %d warnings · %d problems · %d n/a\n' "$n_ok" "$n_warn" "$n_bad" "$n_skip"
  if ((n_bad + n_warn > 0)); then
    printf '   fix-everything pass: make provision MODE=%s   (per-tool commands are on each line above)\n' "$MODE"
  fi
}

main
