#!/usr/bin/env bash
# bump-versions.sh — propose version-pin bumps for makefile/versions.mk.
# Runs check-updates (porcelain) and, for each SIMPLE single-location pin that has
# drifted, bumps it in versions.mk. The dual/triple-edit pins (helix, jetbrains-
# mono, ccstatusline, jq) are reported, never auto-edited (they need a SHA recompute /
# multi-file edits, and check-invariants.sh guards their consistency).
#
# Used by .github/workflows/version-bumps.yml (weekly) and runnable locally.
# Writes a Markdown summary to $BUMP_SUMMARY_FILE (default /tmp/bump-summary.md)
# for the PR body. Exits 0 (report tool); the caller decides if anything changed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit

VERSIONS="makefile/versions.mk"
SUMMARY="${BUMP_SUMMARY_FILE:-/tmp/bump-summary.md}"

# Pins the bumper must NOT auto-edit (reported as manual instead). Two reasons:
#  (1) dual/triple-edit pins — HELIX/JETBRAINSMONO_NERD/CCSTATUSLINE/JQ need a SHA
#      recompute or a paired file (bootstrap.ps1, font.sh, settings.json) edited in
#      lockstep; JQ + SHFMT + GITLEAKS are guarded by check-invariants.sh (the
#      latter two dual-edit .github/workflows/lint.yml's pinned install step), so
#      an auto-bump in versions.mk alone would fail the workflow's own invariant step.
#      UV joins the list because its pin now dual-edits bootstrap.ps1's
#      $PortableTools (Windows half of the Python env). PYTHON_VERSION joins
#      too — it dual-edits bootstrap.ps1's $PythonEnvVersion and a bump needs
#      a wheel-coverage check (duckdb/pydantic-core lag new CPython releases).
#  (2) NCDU — its linux-x86_64 binary is published at dev.yorhel.nl for only SOME
#      releases (2.9.1 has one; 2.9.2 returns 404), so a bump must be verified by
#      hand against the download URL before landing or it 404s the install.
EXCLUDE="HELIX_VERSION JETBRAINSMONO_NERD_VERSION CCSTATUSLINE_VERSION JQ_VERSION SHFMT_VERSION GITLEAKS_VERSION NCDU_VERSION UV_VERSION PYTHON_VERSION"

# Tool names whose versions.mk variable does NOT follow the default
# uppercase(name)+_VERSION convention (the UPDATE_SPECS registry name differs
# from the pin variable). Without these the tool lands in "skipped — no matching
# pin line" forever (and the nerd-fonts EXCLUDE guard would be unreachable).
# Keys MUST stay quoted: shfmt reformats unquoted hyphenated subscripts as
# arithmetic ([nerd-fonts] -> [nerd - fonts]), silently breaking the lookup.
declare -A ALIAS=(
  ["tldr"]=TEALDEER_VERSION
  ["jj"]=JUJUTSU_VERSION
  ["nerd-fonts"]=JETBRAINSMONO_NERD_VERSION
  ["mlr"]=MILLER_VERSION
  ["rg"]=RIPGREP_VERSION
  ["difft"]=DIFFTASTIC_VERSION
  ["trip"]=TRIPPY_VERSION
  ["pueued"]=PUEUE_VERSION # shares pueue's pin (one release covers both)
)

bumped=""
manual=""
skipped=""

updates=$(CHECK_UPDATES_PORCELAIN=1 \
  make -s --no-print-directory -C makefile check-updates MODE=prod 2>/dev/null |
  grep '^update|' || true)

while IFS='|' read -r _ name detail; do
  [ -n "${name:-}" ] || continue
  old="${detail%% *}" # "old → new" -> "old"
  new="${detail##* }" # "old → new" -> "new"
  var="${ALIAS[$name]:-$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_VERSION}"
  old_re="${old//./\\.}"
  new_re="${new//./\\.}"

  case " $EXCLUDE " in
  *" $var "*)
    manual="${manual}- \`$var\` ($name): $old → $new — needs SHA/multi-file edit (manual)\n"
    continue
    ;;
  esac

  # Shared-pin dedup (pueue+pueued both map to PUEUE_VERSION): an earlier row
  # may have already bumped this var to $new — that's done, not a skip.
  if grep -qE "^${var}[[:space:]]*:=[[:space:]]*${new_re}[[:space:]]*\$" "$VERSIONS"; then
    continue
  fi

  if grep -qE "^${var}[[:space:]]*:=[[:space:]]*${old_re}[[:space:]]*\$" "$VERSIONS"; then
    sed -i -E "s|^(${var}[[:space:]]*:=[[:space:]]*)${old_re}[[:space:]]*\$|\1${new}|" "$VERSIONS"
    bumped="${bumped}- \`$var\` ($name): $old → $new\n"
  else
    skipped="${skipped}- \`$var\` ($name): reported $old → $new but no matching pin line (manual)\n"
  fi
done <<<"$updates"

# Keep the machine-memory TOOLS block in sync with the pins we just bumped.
# This script runs in CI (and locally) where the Claude Code sync-tool-memory.sh
# hook never fires, so regenerate the block here — otherwise the bumped
# versions.mk and the <!-- TOOLS --> block in chezmoi/private_dot_claude/CLAUDE.md
# drift, and check-invariants.sh ("machine-memory TOOLS block in sync") fails on
# merge (the bumped pin reinstalls, but the verify step the workflow runs before
# opening the PR — and lint.yml on merge — go red).
if [ -n "$bumped" ]; then
  scripts/gen-tool-memory.sh >/dev/null
fi

{
  echo "## Automated version-pin bumps"
  echo
  if [ -n "$bumped" ]; then
    echo "### Bumped in \`makefile/versions.mk\`"
    echo
    printf '%b' "$bumped"
    echo
  fi
  if [ -n "$manual" ]; then
    echo "### Manual bump available (not auto-edited)"
    echo
    printf '%b' "$manual"
    echo
  fi
  if [ -n "$skipped" ]; then
    echo "### Skipped (could not map safely)"
    echo
    printf '%b' "$skipped"
    echo
  fi
  [ -n "$bumped$manual$skipped" ] || echo "All pins up to date — nothing to bump."
  echo
  echo "_Generated by \`scripts/bump-versions.sh\`. Each bumped pin reinstalls on next \`make provision\` (version baked into the stamp). Review before merge._"
} | tee "$SUMMARY"
