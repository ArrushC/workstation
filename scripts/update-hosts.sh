#!/usr/bin/env bash
# =============================================================================
# scripts/update-hosts.sh
#
# Multi-host updater — replaces `ansible-playbook playbooks/linux.yml`
# from the pre-Make era. Reads hosts.conf, optionally filters by group
# or name, and runs over SSH for each matching host:
#
#     d=~/.config/mise; [ -d "$d/.git" ] || d=~/.local/share/chezmoi
#     cd "$d"
#     git pull --ff-only
#     ./bootstrap.sh --<dev|prod> --yes
#
# The flag (and the MISE_ENV it resolves to) is derived from each host's
# group column in hosts.conf: dev_machine → --dev (sudo for dnf + /etc),
# prod_machine → --prod (no sudo).
#
# This is a PROD-HOST tool: prod never sudos, so the remote run is fully
# non-interactive and safe to fire at the whole fleet in parallel
# (--group prod_machine, or the default run). Dev hosts are bootstrapped
# interactively BY HAND instead, one at a time — their `mise bootstrap`
# prompts for sudo, which a non-interactive SSH run can never
# satisfy:
#     ssh -t <host> 'cd ~/.config/mise 2>/dev/null || cd ~/.local/share/chezmoi; \
#       git pull --ff-only && ./bootstrap.sh --dev'
#
# A bare run (no --group/--name) SKIPS dev_machine hosts automatically —
# printing one "skipped <name> (dev_machine — ...)" line per host — instead
# of trying (and failing) to bootstrap them non-interactively. Pass an
# explicit --group dev_machine or --name <dev host> to target them anyway
# (still non-interactive: only use that against a dev host reachable without
# a sudo prompt, or run the ssh -t one-liner above instead).
#
# Usage:
#   ./scripts/update-hosts.sh                       every host in hosts.conf
#   ./scripts/update-hosts.sh --group dev_machine   just dev hosts
#   ./scripts/update-hosts.sh --group prod_machine  just prod hosts
#   ./scripts/update-hosts.sh --name dev-cache-qa1  one specific host
#   ./scripts/update-hosts.sh --check               print actions, don't ssh
#   ./scripts/update-hosts.sh --parallel 1          serialise (default 4)
#   ./scripts/update-hosts.sh --parallel 8 --group prod_machine
#
# This script is best-effort: a failed host doesn't abort the rest. The
# final line summarises N successful / M failed. Exit 0 even on partial
# failure (mirrors manage-hosts.sh's --copy-id --all behaviour).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTS_CONF="$REPO_ROOT/hosts.conf"

# --- Colours -----------------------------------------------------------------
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

# --- Argument parsing --------------------------------------------------------
GROUP_FILTER=""
NAME_FILTER=""
CHECK=false
PARALLEL=4

while (($# > 0)); do
  case "$1" in
  --group)
    GROUP_FILTER="$2"
    shift 2
    ;;
  --name)
    NAME_FILTER="$2"
    shift 2
    ;;
  --check)
    CHECK=true
    shift
    ;;
  --parallel)
    PARALLEL="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '3,/^# ====/p' "$0" | sed -n '1,/^# ===/p' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    fail "Unknown argument: $1 — try --help"
    ;;
  esac
done

[[ -f "$HOSTS_CONF" ]] || fail "hosts.conf not found at $HOSTS_CONF"

# --- Build the host list -----------------------------------------------------
# Read hosts.conf, strip comments / blank lines, optionally filter.
# Each row → "name|ip|user|group" (pipe-separated for xargs-friendly parsing).
hosts_iter() {
  grep -Ev '^\s*(#|$)' "$HOSTS_CONF" |
    awk -v g="$GROUP_FILTER" -v n="$NAME_FILTER" '
        { name=$1; ip=$2; user=$3; group=$4 }
        g != "" && group != g { next }
        n != "" && name  != n { next }
        { print name "|" ip "|" user "|" group }
      '
}

mapfile -t HOSTS < <(hosts_iter)

if ((${#HOSTS[@]} == 0)); then
  if [[ -n "$GROUP_FILTER" || -n "$NAME_FILTER" ]]; then
    fail "No hosts matched the filter (group='$GROUP_FILTER' name='$NAME_FILTER')."
  else
    fail "hosts.conf has no managed hosts (every line was a comment or blank)."
  fi
fi

# A bare run (no --group/--name) must not try to bootstrap dev_machine hosts
# non-interactively — their `mise bootstrap` prompts for sudo, which this
# script's non-interactive `ssh -o BatchMode=yes` can never satisfy (see the
# header above). Skip them, one printed line each; an explicit --group
# dev_machine or --name <dev host> still targets them.
if [[ -z "$GROUP_FILTER" && -z "$NAME_FILTER" ]]; then
  kept=()
  for h in "${HOSTS[@]}"; do
    IFS='|' read -r name _ _ group <<<"$h"
    if [[ "$group" == "dev_machine" ]]; then
      warn "skipped $name (dev_machine — bootstrap dev hosts interactively: ssh -t …)"
      continue
    fi
    kept+=("$h")
  done
  HOSTS=("${kept[@]}")
fi

# --- Per-host worker ---------------------------------------------------------
# Run as a subshell from xargs. Writes a single status line per host so the
# parallel output stays readable. Don't `set -e` inside — partial failures
# shouldn't kill the worker before we report them.
update_one() {
  local spec="$1"
  local name ip user group mode
  IFS='|' read -r name ip user group <<<"$spec"

  case "$group" in
  dev_machine) mode=dev ;;
  prod_machine) mode=prod ;;
  *)
    printf "${RED} ✗${RESET} %-24s unknown group '%s' — skipping\n" "$name" "$group"
    return 1
    ;;
  esac

  local remote_cmd
  remote_cmd="set -e
d=\$HOME/.config/mise; [ -d \"\$d/.git\" ] || d=\$HOME/.local/share/chezmoi
cd \"\$d\"
git pull --ff-only
./bootstrap.sh --$mode --yes"

  if $CHECK; then
    printf " ${BLUE}-${RESET} %-24s would: ssh %s@%s '<git pull && ./bootstrap.sh --%s --yes>'\n" \
      "$name" "$user" "$ip" "$mode"
    return 0
  fi

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$user@$ip" "$remote_cmd" >/tmp/update-hosts-$$-"$name".log 2>&1; then
    printf " ${GREEN}✓${RESET} %-24s updated (MODE=%s)\n" "$name" "$mode"
    rm -f /tmp/update-hosts-$$-"$name".log
    return 0
  else
    printf " ${RED}✗${RESET} %-24s FAILED — see /tmp/update-hosts-$$-%s.log\n" "$name" "$name"
    return 1
  fi
}

# Export so xargs subshells can call it.
export -f update_one
export RED GREEN BLUE BOLD YELLOW RESET CHECK

# --- Run, in parallel --------------------------------------------------------
if $CHECK; then
  log "Dry run — would update ${#HOSTS[@]} host(s) (parallel=$PARALLEL):"
else
  log "Updating ${#HOSTS[@]} host(s) in parallel (-P $PARALLEL)..."
fi

printf '%s\n' "${HOSTS[@]}" |
  xargs -I{} -P "$PARALLEL" bash -c 'update_one "$@"' _ {} ||
  true # don't let xargs's exit code (non-zero on any failure) kill us;
# per-host status was already printed inside update_one.

# --- Summary -----------------------------------------------------------------
# Count log files left behind in /tmp — one per failed host.
shopt -s nullglob
failed_logs=(/tmp/update-hosts-$$-*.log)
n_total=${#HOSTS[@]}
n_failed=${#failed_logs[@]}
n_ok=$((n_total - n_failed))

echo ""
if $CHECK; then
  ok "Dry run complete ($n_total host(s) would be updated)"
elif ((n_failed == 0)); then
  ok "All $n_total hosts updated successfully"
else
  warn "$n_ok of $n_total hosts updated; $n_failed failed. Logs:"
  for f in "${failed_logs[@]}"; do warn "  $f"; done
fi
