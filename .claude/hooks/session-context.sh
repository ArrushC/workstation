#!/usr/bin/env bash
# session-context.sh — Claude Code SessionStart hook (repo-scoped).
#
# Injects ONE compact additionalContext block of RUNTIME facts the static
# session context can't carry, for working in the workstation mise-dotfiles
# repo:
#   - dotfiles deploy state (does $HOME match the source you're editing? —
#     `mise dot status`)
#   - host identity & scope (hostname, owned/shared mode and miserc tokens, an exported MISE_ENV, distro / EL family)
#   - WSL & interop capability (interop enabled?, powershell.exe reachable?)
#   - guardrail readiness (jq/shfmt/gitleaks/shellcheck + pre-commit hook)
#
# Reads input via lib.sh; fails open; always exit 0.
# Every bucket fails OPEN independently (drops its segment on any error) and
# every external probe is timeout-bounded. It NEVER spawns a Windows process —
# interop is detected statically. See CLAUDE.md + docs/claude/.
set -u

# shellcheck source=.claude/hooks/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0

# --- resolve repo root (prefer CLAUDE_PROJECT_DIR, else cwd, else git top) ----
cwd="$(hook_field '.cwd')"
root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  root="$CLAUDE_PROJECT_DIR"
elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
  root="$cwd"
fi
[ -n "$root" ] || exit 0
top="$(timeout 2s git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$top" ] && root="$top"

# --- bucket: dotfiles deploy state -------------------------------------------
# shellcheck disable=SC2016  # $HOME is intentional literal text in the context block
seg_dotfiles() {
  command -v mise >/dev/null 2>&1 || return 0
  local json n total
  json="$(timeout 4s mise dot status --json 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    n="$(printf '%s' "$json" | jq '[.files[]? | select(.state != "applied")] | length' 2>/dev/null)"
    total="$(printf '%s' "$json" | jq '.files? | length' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    n="$(printf '%s' "$json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(sum(1 for f in d.get("files",[]) if f.get("state")!="applied"))' 2>/dev/null)"
    total="$(printf '%s' "$json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(len(d.get("files",[])))' 2>/dev/null)"
  else
    return 0
  fi
  case "$n" in '' | *[!0-9]*) return 0 ;; esac
  case "$total" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$n" -eq 0 ]; then
    printf 'dotfiles: $HOME in sync (%s tracked)' "$total"
  else
    printf 'dotfiles: %s/%s entries differ from $HOME, edits here are PENDING until `wsa`' "$n" "$total"
  fi
}

# --- bucket: host identity & scope -------------------------------------------
seg_host() {
  local host mode envseg tokens osr id ver plat el osseg
  host="$(uname -n 2>/dev/null)"
  # owned/shared is the `owned` token in miserc.toml's `env = [...]` (written by
  # scripts/lib/mise-env.sh) — not config.local.toml's vars.mode, which may not
  # exist yet on a fresh clone. Missing/unreadable miserc leaves mode unset.
  mode="" envseg=""
  if [ -r "$root/miserc.toml" ]; then
    tokens="$(sed -n 's/^env = \[\(.*\)\]$/\1/p' "$root/miserc.toml" 2>/dev/null | tr -d '" ')"
    if [ -n "$tokens" ]; then
      case ",${tokens}," in
      *,owned,*) mode="owned" ;;
      *) mode="shared" ;;
      esac
      envseg="env=$tokens"
    fi
  else
    envseg="miserc=missing"
  fi
  # An exported MISE_ENV overrides miserc for every mise call in this session.
  [ -n "${MISE_ENV:-}" ] && envseg="$envseg MISE_ENV=$MISE_ENV (exported; overrides miserc)"
  osr=/etc/os-release
  id="$(sed -nE 's/^ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  ver="$(sed -nE 's/^VERSION_ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  plat="$(sed -nE 's/^PLATFORM_ID=("?)([^"]*)\1.*/\2/p' "$osr" 2>/dev/null | head -1)"
  el="${plat#platform:}"
  osseg=""
  [ -n "$id" ] && osseg="os=$id${ver:+ $ver}"
  [ -n "$osseg" ] && [ -n "$el" ] && [ "$el" != "$plat" ] && osseg="$osseg ($el)"
  printf 'host=%s' "${host:-?}"
  [ -n "$mode" ] && printf ' mode=%s' "$mode"
  [ -n "$envseg" ] && printf ' %s' "${envseg# }"
  [ -n "$osseg" ] && printf ' %s' "$osseg"
}

# --- bucket: WSL & interop (static probes only — no Windows process spawn) ----
seg_wsl() {
  local osrel interop ps
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    osrel="$(cat /proc/sys/kernel/osrelease 2>/dev/null)"
    case "$osrel" in
    *icrosoft* | *WSL*) ;;
    *)
      printf 'WSL=no'
      return 0
      ;;
    esac
  fi
  interop=off
  if [ -r /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null && interop=on
  fi
  if command -v powershell.exe >/dev/null 2>&1; then ps=on-PATH; else ps=absent; fi
  printf 'WSL=%s interop=%s powershell.exe=%s' "${WSL_DISTRO_NAME:-yes}" "$interop" "$ps"
}

# --- bucket: guardrail readiness ---------------------------------------------
seg_guards() {
  local out tool precommit hp
  out="guards:"
  for tool in jq shfmt gitleaks shellcheck; do
    if command -v "$tool" >/dev/null 2>&1; then
      out="$out $tool=ok"
    else
      out="$out $tool=MISSING"
    fi
  done
  precommit=absent
  if [ -x "$root/.git/hooks/pre-commit" ]; then
    precommit=installed
  else
    hp="$(timeout 2s git -C "$root" config --get core.hooksPath 2>/dev/null)"
    [ -n "$hp" ] && [ -x "$hp/pre-commit" ] && precommit=installed
  fi
  printf '%s precommit=%s' "$out" "$precommit"
}

# --- assemble (each segment runs in its own subshell, so any var pollution or
#     failure is contained; empty segments are dropped) ------------------------
segs=()
s="$(seg_dotfiles)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_host)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_wsl)" && [ -n "$s" ] && segs+=("$s")
s="$(seg_guards)" && [ -n "$s" ] && segs+=("$s")
[ "${#segs[@]}" -gt 0 ] || exit 0

block="[workstation]"
sep=" "
for s in "${segs[@]}"; do
  block="${block}${sep}${s}"
  sep=" | "
done

hook_context SessionStart "$block"
exit 0
