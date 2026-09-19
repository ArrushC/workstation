#!/usr/bin/env bash
# check-updates.sh — compare pinned tool versions (config.toml [vars]) against the
# newest upstream release tags, via `git ls-remote --tags` (plain git, no
# GitHub API, no rate limits, GITHUB_TOKEN not needed for public repos).
#
# Invoked by tasks/check-updates, which pipes one spec per line on stdin:
#
#   <name>|<version>|<repo>|<tag>
#
#   name     registered tool name (display only)
#   version  the pin from config.toml [vars] ("latest" → reported as rolling)
#   repo     GitHub owner/repo, a full git URL (anything with ://), or "-"
#            when there is no tag source to compare against
#   tag      the exact upstream tag the pin installs (v1.2.3, jq-1.8.1,
#            gping-v1.20.1, 25.07.1, …). MUST end with <version> — the
#            leading remainder becomes the ls-remote tag-glob prefix.
#
# The toolbelt itself (mise-managed, config*.toml) is covered by `mise
# outdated`, not this script. The handful of pins config.toml [vars] still
# owns directly (claude-cli, dozzle, nerd-fonts, vcpkg, python-env) are
# hand-registered as spec lines built by tasks/check-updates.
#
# Self-exec fan-out: with no args this is the driver (reads specs on stdin,
# fans out via xargs -P, sorts, summarizes); with one arg it is a worker that
# checks a single spec and prints one `status|name|detail` line, where
# status ∈ ok | update | ahead | rolling | unknown.
#
# READ-ONLY + network-bound. Report only — updating a pin is still a manual
# config.toml [vars] edit (mind the CCSTATUSLINE / JETBRAINSMONO / HELIX dual-
# and triple-edit invariants in CLAUDE.md), followed by `mise bootstrap`
# (bootstrap.sh).

set -euo pipefail

JOBS="${CHECK_UPDATES_JOBS:-8}"

# ---------------------------------------------------------------------------
# Worker mode: $1 = one spec. Prints exactly one `status|name|detail` line.
# ---------------------------------------------------------------------------
if (($# == 1)); then
  IFS='|' read -r name version repo tag <<<"$1"

  if [[ "$version" == "latest" ]]; then
    echo "rolling|$name|tracks latest — self-updates; reinstall: rm ~/.local/bin/claude and re-run ./bootstrap.sh --dev"
    exit 0
  fi
  if [[ "$repo" == "-" || -z "$repo" ]]; then
    echo "unknown|$name|no upstream tag source registered"
    exit 0
  fi

  # npm source kind: `npm:<package>`. Some upstreams publish ONLY to npm and
  # their GitHub tags are unusable — yaml-language-server's tag list is
  # `untagged-<sha>` junk plus a stray v0.0.1, so a git-tag check there would be
  # permanently wrong. Read dist-tags.latest, never the full version list: that
  # registry carries hundreds of `X.Y.Z-<sha>.0` prerelease snapshots and a
  # "highest version" scrape would happily pick one.
  if [[ "$repo" == npm:* ]]; then
    pkg="${repo#npm:}"
    latest=$(timeout 30 curl -fsSL "https://registry.npmjs.org/$pkg" 2>/dev/null |
      sed -n 's/.*"dist-tags":{[^}]*"latest":"\([^"]*\)".*/\1/p' | head -1) || latest=""
    if [[ -z "$latest" ]]; then
      echo "unknown|$name|npm registry lookup failed for $pkg (offline?)"
    elif [[ "$latest" == "$version" ]]; then
      echo "ok|$name|$version"
    elif [[ "$(printf '%s\n%s\n' "$version" "$latest" | sort -V | tail -1)" == "$latest" ]]; then
      echo "update|$name|$version → $latest"
    else
      echo "ahead|$name|pin $version is newer than npm's latest $latest"
    fi
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
    # Two tag families exist in this fleet: numeric (1.2.3) and ISO date
    # (2026-08-31, used by rust-analyzer and marksman). Choose the family from
    # the PINNED version's own shape so we never compare across families.
    #
    # The numeric-only filter this replaces silently blinded every date-tagged
    # tool: 0 of rust-analyzer's 360 tags and 0 of marksman's 59 matched, so both
    # reported `?` forever and could never offer a bump — marksman sat ~14 months
    # stale that way. sort -V already orders ISO dates correctly, so only the
    # filter needed changing.
    if [[ "$version" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      tag_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    else
      tag_re='^[0-9]+(\.[0-9]+)*$'
    fi
    latest=$(while IFS=$'\t' read -r _sha ref; do
      v="${ref#refs/tags/}"
      v="${v#"$prefix"}"
      if [[ "$v" =~ $tag_re ]]; then printf '%s\n' "$v"; fi
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
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [[ -z "${CHECK_UPDATES_PORCELAIN:-}" ]]; then
  printf '%s==>%s %schecking pinned versions against upstream tags (git ls-remote, %s jobs)%s\n' \
    "$BLUE" "$RESET" "$BOLD" "$JOBS" "$RESET"
fi

xargs -r -P "$JOBS" -n 1 "$0" >"$tmp" || true

if [[ -n "${CHECK_UPDATES_PORCELAIN:-}" ]]; then
  cat "$tmp"
  exit 0
fi

sort -t'|' -k2,2 -f "$tmp" | while IFS='|' read -r status name detail; do
  case "$status" in
  update) printf ' %s↑%s %-16s %s\n' "$YELLOW" "$RESET" "$name" "$detail" ;;
  ok) printf ' %s✓%s %-16s up to date (%s)\n' "$GREEN" "$RESET" "$name" "$detail" ;;
  rolling) printf ' · %-16s %s\n' "$name" "$detail" ;;
  ahead) printf ' %s!%s %-16s %s\n' "$YELLOW" "$RESET" "$name" "$detail" ;;
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
if ((n_update > 0)); then
  printf '   to update: edit the pin in config.toml [vars], then ./bootstrap.sh --<dev|prod>\n'
  printf '   (mind the dual/triple-edit pins — CCSTATUSLINE, JETBRAINSMONO, HELIX; see CLAUDE.md)\n'
fi
