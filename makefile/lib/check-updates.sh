#!/usr/bin/env bash
# check-updates.sh — compare pinned tool versions (versions.mk) against the
# newest upstream release tags, via `git ls-remote --tags` (plain git, no
# GitHub API, no rate limits, GITHUB_TOKEN not needed for public repos).
#
# Invoked by `make check-updates MODE=dev|prod` (makefile/Makefile), which
# pipes one spec per line on stdin:
#
#   <name>|<version>|<repo>|<tag>
#
#   name     registered tool name (display only)
#   version  the pin from versions.mk ("latest" → reported as rolling)
#   repo     GitHub owner/repo, a full git URL (anything with ://), or "-"
#            when there is no tag source to compare against
#   tag      the exact upstream tag the pin installs (v1.2.3, jq-1.8.1,
#            gping-v1.20.1, 25.07.1, …). MUST end with <version> — the
#            leading remainder becomes the ls-remote tag-glob prefix.
#
# EGET_TOOL registrations feed this automatically (the macro in
# makefile/Makefile); TOOL/USER_TOOL/bespoke pins are hand-registered in the
# UPDATE-CHECK REGISTRY block at the bottom of tools.mk.
#
# Self-exec fan-out: with no args this is the driver (reads specs on stdin,
# fans out via xargs -P, sorts, summarizes); with one arg it is a worker that
# checks a single spec and prints one `status|name|detail` line, where
# status ∈ ok | update | ahead | rolling | unknown.
#
# READ-ONLY + network-bound. Report only — updating a pin is still the manual
# versions.mk edit (mind the CCSTATUSLINE / JETBRAINSMONO / HELIX dual- and
# triple-edit invariants in CLAUDE.md), followed by `make provision`.

set -euo pipefail

JOBS="${CHECK_UPDATES_JOBS:-8}"

# ---------------------------------------------------------------------------
# Worker mode: $1 = one spec. Prints exactly one `status|name|detail` line.
# ---------------------------------------------------------------------------
if (( $# == 1 )); then
  IFS='|' read -r name version repo tag <<<"$1"

  if [[ "$version" == "latest" ]]; then
    echo "rolling|$name|tracks latest — force a refresh: make clean-$name $name MODE=<dev|prod>"
    exit 0
  fi
  if [[ "$repo" == "-" || -z "$repo" ]]; then
    echo "unknown|$name|no upstream tag source registered"
    exit 0
  fi

  url="$repo"
  [[ "$url" != *://* ]] && url="https://github.com/$repo.git"

  if [[ "$tag" != *"$version" ]]; then
    echo "unknown|$name|tag template '$tag' doesn't end with version '$version' — fix the spec"
    exit 0
  fi
  prefix="${tag%"$version"}"

  refs=$(GIT_TERMINAL_PROMPT=0 timeout 30 \
           git ls-remote --tags --refs "$url" "refs/tags/${prefix}*" 2>/dev/null) || refs=""

  latest=""
  if [[ -n "$refs" ]]; then
    # Strip refs/tags/<prefix>, keep clean numeric versions only (drops
    # -rc/-beta/-pre tags and unrelated tag families), newest by sort -V.
    # The filter must be an `if` (not `[[ ]] &&`): when the LAST tag fails
    # the regex, the && form makes the while segment exit 1, and under
    # `set -eo pipefail` that kills the worker with no output at all.
    latest=$(while IFS=$'\t' read -r _sha ref; do
               v="${ref#refs/tags/}"; v="${v#"$prefix"}"
               if [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then printf '%s\n' "$v"; fi
             done <<<"$refs" | sort -V | tail -1)
  fi

  if [[ -z "$latest" ]]; then
    echo "unknown|$name|no matching tags at $url (offline? upstream tag scheme changed?)"
  elif [[ "$latest" == "$version" ]]; then
    echo "ok|$name|$version"
  elif [[ "$(printf '%s\n%s\n' "$version" "$latest" | sort -V | tail -1)" == "$latest" ]]; then
    echo "update|$name|$version → $latest"
  else
    echo "ahead|$name|pin $version is newer than the latest clean tag $latest"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Driver mode: specs on stdin → parallel workers → sorted report + summary.
# ---------------------------------------------------------------------------
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

printf '%s==>%s %schecking pinned versions against upstream tags (git ls-remote, %s jobs)%s\n' \
  "$BLUE" "$RESET" "$BOLD" "$JOBS" "$RESET"

xargs -r -P "$JOBS" -n 1 "$0" >"$tmp" || true

sort -t'|' -k2,2 -f "$tmp" | while IFS='|' read -r status name detail; do
  case "$status" in
    update)  printf ' %s↑%s %-16s %s\n' "$YELLOW" "$RESET" "$name" "$detail" ;;
    ok)      printf ' %s✓%s %-16s up to date (%s)\n' "$GREEN" "$RESET" "$name" "$detail" ;;
    rolling) printf ' · %-16s %s\n' "$name" "$detail" ;;
    ahead)   printf ' %s!%s %-16s %s\n' "$YELLOW" "$RESET" "$name" "$detail" ;;
    unknown) printf ' %s?%s %-16s %s\n' "$RED" "$RESET" "$name" "$detail" ;;
  esac
done

n_update=$(grep -c '^update|' "$tmp" || true)
n_ok=$(grep -c '^ok|' "$tmp" || true)
n_roll=$(grep -c '^rolling|' "$tmp" || true)
n_unk=$(grep -c -E '^(unknown|ahead)\|' "$tmp" || true)

echo ""
printf '   %s update(s) available · %s up to date · %s rolling · %s unchecked\n' \
  "$n_update" "$n_ok" "$n_roll" "$n_unk"
if (( n_update > 0 )); then
  printf '   to update: edit the pin in makefile/versions.mk, then make provision MODE=%s\n' "${MODE:-dev|prod}"
  printf '   (mind the dual/triple-edit pins — CCSTATUSLINE, JETBRAINSMONO, HELIX; see CLAUDE.md)\n'
fi
