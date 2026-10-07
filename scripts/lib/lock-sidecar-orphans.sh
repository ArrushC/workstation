#!/usr/bin/env bash
# lock-sidecar-orphans.sh [repo-root] — print the locks/ sidecar dirs (the dirs that hold
# files) that no mise*.lock `path = "locks/..."` refers to. A pypi:/npm: bump writes the new
# version's sidecar and leaves the old one; scripts/bump-versions.sh deletes what this
# prints, and check-invariants.sh fails while anything is printed.
set -euo pipefail
cd "${1:-$(dirname "$(readlink -f "$0")")/../..}"
comm -13 \
  <(grep -ho 'path = "locks/[^"]*"' mise.lock mise.linux.lock 2>/dev/null | sed -E 's/^path = "(.*)"$/\1/' | sort -u) \
  <(find locks -type f -printf '%h\n' 2>/dev/null | sort -u)
