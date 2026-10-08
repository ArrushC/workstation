#!/usr/bin/env bash
# latest-tag.sh <github owner/repo> — print the newest clean numeric release tag
# upstream (git ls-remote: no API, no rate limit); nothing when offline or none match.
# tasks/check-updates reports it and scripts/bump-versions.sh bumps vcpkg_version to it.
set -uo pipefail
GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null |
  sed 's#.*refs/tags/##' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
