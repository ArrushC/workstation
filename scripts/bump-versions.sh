#!/usr/bin/env bash
# bump-versions.sh — propose version-pin bumps across the two layers that
# remain after the tool AND host-pin move to mise:
#
#   (1) mise tool pins in config.toml / config.linux.toml,
#       via `mise outdated --bump --json` + set_pin + `mise lock`.
#   (2) the one host pin config.toml [vars] bumps (vcpkg_version), via
#       scripts/lib/latest-tag.sh (the lookup tasks/check-updates reports) + set_pin.
#       zjstatus_zellij_floor is a coupling floor, never bumped.
#
# Coupled tool pins (go+gopls, node's postinstall LSP servers) are bumped by
# dedicated code that keeps every paired edit in step. Only the pins in the EXCLUDE list below
# are reported and never edited: those need a coupling floor read from release
# notes, a download check, or a wheel-coverage check the bumper can't do.
#
# Used by .github/workflows/version-bumps.yml (weekly) and runnable locally.
# --dry-run prints what would change without writing config*.toml,
# mise.lock/mise.*.lock, or the generated files — it only produces the
# summary.
# Writes a Markdown summary to $BUMP_SUMMARY_FILE (default /tmp/bump-summary.md)
# for the PR body. Exits 0 normally (report tool; the caller decides if a
# bump changed anything) but exits 1 when `mise outdated` itself fails
# (network, broken mise, malformed config — the mise tool-pin layer is
# skipped in that case, though the config.toml [vars] layer still runs and
# is reported) or a
# post-bump `mise lock` or TOOLS-block regeneration fails, so the weekly workflow fails
# visibly instead of silently reporting "nothing to bump". A lock failure
# that names one bumped tool is NOT fatal: that pin is reverted and reported
# under "Refused by mise lock", and the lock retried (see lock_platform).
# Individual pin-rewrite failures are reported under "Failed to edit
# (manual)" without forcing a nonzero exit on their own.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit

SUMMARY="${BUMP_SUMMARY_FILE:-/tmp/bump-summary.md}"
DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

bumped=""        # mise tool pins bumped this run (config*.toml)
manual=""        # pins in the EXCLUDE list — reported, never auto-edited
skipped=""       # a pin check-updates found but couldn't map safely
vars_bumped=""   # config.toml [vars] pins bumped this run
failed=""        # pin rewrites / mise lock calls that failed this run
outdated_fail="" # captured stderr when `mise outdated` itself fails (non-empty => mise half skipped)
exit_code=0

# -----------------------------------------------------------------------------
# Layer 1: mise tool pins (config.toml / config.linux.toml)
# -----------------------------------------------------------------------------
#
# Pins that need more than a one-line edit are bumped by dedicated code
# below, not skipped (user decision 2026-09-23: "always bump those packages").
#  - go + go:golang.org/x/tools/gopls are a COUPLED PAIR: gopls declares a
#    hard toolchain floor in its own go.mod (0.23.0 needs go 1.26.0), and
#    mise's go: backend builds it with the PINNED go. go bumps freely. gopls
#    bumps only when its floor is at or below the go pin this run leaves.
#    Otherwise it is reported as manual.
#  - node's `postinstall` string pins the LSP servers (typescript-language-
#    server, typescript, bash-/yaml-language-server,
#    vscode-langservers-extracted). `mise outdated` sees only node itself, so
#    the postinstall step after the main loop moves each package to the newest release within
#    its CURRENT major, straight from the npm registry. A new major is
#    reported as manual: an LSP server's major can change which TypeScript
#    or node it needs. typescript is also held on 5.x, because ts-ls needs
#    typescript/lib/tsserver.js, which TS 7 removed
#    (check_pins). A changed postinstall string makes
#    scripts/lib/mise-install.sh reinstall node on each host, so the
#    servers are actually refreshed.
# Still EXCLUDED (reported, never auto-edited):
#  - github:dj95/zjstatus is ABI-coupled to zellij: every zjstatus release
#    states its zellij floor, recorded as vars.zjstatus_zellij_floor in
#    config.toml and asserted against tools.zellij by check-invariants.sh. A
#    blind bump would raise the floor silently; bump the pin AND the floor
#    together, by hand, from the release notes.
#  - http:ncdu — its linux-x86_64 binary is published at dev.yorhel.nl for
#    only SOME releases (2.9.1 has one; 2.9.2 returns 404), so a bump must
#    be verified by hand against the download URL before landing or it
#    404s the install.
#  - python needs a wheel-coverage check before bumping — the
#    dependency-locked pypi: tools (basedpyright, glances, asciinema,
#    harlequin) and python-env's libraries (built on it on both OSes) can lag
#    a brand-new CPython release (duckdb/pydantic-core wheels in particular).
EXCLUDE="github:dj95/zjstatus http:ncdu python"
# Coupled pins bumped by dedicated code instead of EXCLUDE. check_pins
# requires every dual-edit/coupled pin to be in EXCLUDE or this list.
# shellcheck disable=SC2034  # read by check-invariants.sh, not here
COUPLED_AUTO="go go:golang.org/x/tools/gopls node"

# Run a mise subcommand against this checkout as mise's GLOBAL config dir,
# from OUTSIDE the checkout, via a throwaway XDG_CONFIG_HOME symlink dir.
# Verified on-host: this is the only invocation form that
# reliably merges the MISE_ENV-selected config files under `--global`
# — running with MISE_CONFIG_DIR pointing straight at the checkout (the old
# form here), or from inside the checkout with neither override set, both
# leave which config root gets read/written ambiguous. One throwaway
# symlink dir is created for the whole script run and cleaned up on exit.
MISE_GLOBAL_LINKDIR="$(mktemp -d)"
ln -s "$ROOT" "$MISE_GLOBAL_LINKDIR/mise"
trap 'rm -rf "$MISE_GLOBAL_LINKDIR"' EXIT

mise_global() {
  local mise_env="$1"
  shift
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$MISE_GLOBAL_LINKDIR" MISE_ENV="$mise_env" "$@")
}

# mise 2026.9.9 quirk, verified on-host: `mise lock`, including via
# --global in every invocation form tried (MISE_CONFIG_DIR, an
# XDG_CONFIG_HOME symlink, or no override at all), always (re)serializes the
# pypi:/npm: dependency-locked sidecar refs under the stale `.mise/locks/**`
# layout and writes fresh sidecar content there — never the tracked
# `locks/**` layout. mise's `install` command CAN write `locks/**` instead,
# but only when its config root is literally $HOME/.config/mise — the
# on-host layout; MISE_CONFIG_DIR, the XDG_CONFIG_HOME-symlink form this
# script uses, and any other directory all get `.mise/locks/**` instead, so
# this isn't something this script (or an arbitrarily-named CI checkout,
# without touching the workflow — see lint.yml's MISE_LOCKFILE=false) can
# arrange. So compensate mechanically instead of chasing that: fold any
# freshly written `.mise/locks/**` content into `locks/**` and repoint the
# lock files' path refs. Pure filesystem ops, no extra mise invocation, no
# dependence on checkout naming. See CLAUDE.md and
# check-invariants.sh's check_mise_config_files.
normalize_lock_sidecars() {
  if [ -d "$ROOT/.mise/locks" ]; then
    mkdir -p "$ROOT/locks" &&
      cp -a "$ROOT/.mise/locks/." "$ROOT/locks/" &&
      rm -rf "${ROOT:?}/.mise" &&
      sed -i 's#path = "\.mise/locks/#path = "locks/#g' \
        "$ROOT/mise.lock" "$ROOT/mise.linux.lock" || {
      echo "ERROR: normalize_lock_sidecars failed" >&2
      return 1
    }
  fi
  # A bump writes the new version's sidecar and leaves the old one behind.
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "${ROOT:?}/$d"
  done < <(bash "$ROOT/scripts/lib/lock-sidecar-orphans.sh" "$ROOT")
  find "$ROOT/locks" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Rewrite one pin's version string in place and leave the rest of the file
# byte-for-byte alone. Don't use `mise config set` here: in mise 2026.9.9 it
# re-serializes the key it edits and drops the comments around it — the
# comment lines above a plain `name = "ver"` entry and its trailing `# ...`.
# The 2026-09-23 run lost uv's 6-line note about its version floor, the aqua
# registry section header, and two inline notes that way. set_pin matches
# `name = "cur"` or `name = { ... version = "cur" ... }` at the start of a
# line (name optionally quoted, matched literally). Anything other than
# exactly one match fails without writing, so the caller reports the pin as
# manual instead of guessing.
set_pin() {
  local file="$1" name="$2" cur="$3" new="$4" n
  n="$(PIN_NAME="$name" PIN_CUR="$cur" PIN_NEW="$new" perl -e '
    my ($f) = @ARGV;
    open(my $in, "<", $f) or die "$f: $!";
    my @lines = <$in>;
    close $in;
    my $n = 0;
    for (@lines) {
      $n++ if s/^("?\Q$ENV{PIN_NAME}\E"?\s*=\s*(?:\{[^#]*?\bversion\s*=\s*)?)"\Q$ENV{PIN_CUR}\E"/$1"$ENV{PIN_NEW}"/;
    }
    if ($n == 1) {
      open(my $out, ">", $f) or die "$f: $!";
      print $out @lines;
      close $out;
    }
    print $n;
  ' "$file")" || return 1
  [ "$n" = 1 ]
}

# version_gt A B — true when A is strictly newer than B (sort -V). mise
# outdated --bump can offer an OLDER version: it offered DevToys 1.0.13.0
# for the pinned 2.0.9.0, because upstream flags every release prerelease.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# gopls_floor VERSION — the go toolchain floor gopls VERSION declares in its
# own go.mod (empty when offline or the tag is missing).
gopls_floor() {
  curl -fsSL --max-time 15 \
    "https://raw.githubusercontent.com/golang/tools/gopls/v$1/gopls/go.mod" 2>/dev/null |
    awk '/^go /{print $2; exit}'
}

# npm_latest_in_major PKG MAJOR — newest stable PKG release with that major,
# from the npm registry's abbreviated metadata (no npm needed on the runner).
npm_latest_in_major() {
  curl -fsSL --max-time 60 -H 'Accept: application/vnd.npm.install-v1+json' \
    "https://registry.npmjs.org/$1" 2>/dev/null |
    jq -r '.versions | keys[]' | grep -E "^$2\.[0-9]+\.[0-9]+$" | sort -V | tail -n1
}

# npm_latest PKG — the registry's `latest` dist-tag for PKG.
npm_latest() {
  curl -fsSL --max-time 30 "https://registry.npmjs.org/$1/latest" 2>/dev/null | jq -r '.version // empty'
}

# Per-tool record of every pin this run bumped, so lock_platform can put one
# back. Keys are mise tool names (may contain `:`/`/`), always quoted.
declare -A bump_file bump_cur bump_new
refused="" # bumps reverted because `mise lock` refused the new version

# `mise lock` one platform. `mise lock` is all-or-nothing: if it refuses ONE
# tool's new version it writes nothing and exits 1, which used to fail the
# whole weekly run and open no PR. It names the refused tool ("failed to
# resolve <tool>@<ver> for <platform>; refusing to replace locked version(s)
# ..."), so revert just that pin, record mise's reason, and retry until the
# lock succeeds. Two real causes so far:
#  - 2026-09-21, difftastic@0.71.0: upstream renamed its assets and the aqua
#    registry had not caught up.
#  - 2026-09-23, ouch@0.8.3: releases moved from GitHub attestations to
#    cosign bundles. mise treats that as a provenance downgrade and refuses
#    by design; it has no flag to override this, and there should not be one.
#    Verify such a release by hand (e.g. `cosign verify-blob`) before
#    bumping it.
# Returns 1 only when the failure doesn't name a tool this run bumped (a
# genuine lock error), leaving the old hard-fail behaviour for those.
# MISE_LOCKED=0: a pypi: tool's dependency lock runs uv through its shim, and in
# locked mode (config.toml) that shim refuses a just-bumped uv the lock doesn't list
# yet ("No version is set for shim: uv"; both platforms failed on 2026-10-05).
lock_platform() {
  local mise_env="$1" platform="$2" err tool reason tries=0
  err="$(mktemp)"
  while :; do
    if mise_global "$mise_env" env MISE_LOCKED=0 mise lock --global --platform "$platform" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2
    sed -i 's/\x1b\[[0-9;]*m//g' "$err"
    tool="$(sed -n 's/.*failed to resolve \([^ ]*\)@[^ ]* for .*/\1/p' "$err" | head -n1)"
    if [ -z "$tool" ] || [ -z "${bump_cur["$tool"]+x}" ] || [ "$tries" -ge 20 ]; then
      rm -f "$err"
      return 1
    fi
    # Non-verbose mise gives only the refusal line. The cause (for example a
    # provenance downgrade, or an asset it cannot find) appears only with -v,
    # so point the reader there.
    reason="$(sed -n 's/.*failed to resolve [^ ]* for [^;]*; \(.*\)/\1/p' "$err" | head -n1)"
    reason="${reason:-could not resolve it} on $platform; \`mise -v lock\` shows why"
    if ! set_pin "${bump_file["$tool"]}" "$tool" "${bump_new["$tool"]}" "${bump_cur["$tool"]}"; then
      rm -f "$err"
      return 1
    fi
    printf '  ! mise lock refused %s@%s on %s — reverted to %s, retrying\n' \
      "$tool" "${bump_new["$tool"]}" "$platform" "${bump_cur["$tool"]}" >&2
    bumped="${bumped/"- \`$tool\` (${bump_file["$tool"]}): ${bump_cur["$tool"]} → ${bump_new["$tool"]}\n"/}"
    refused="${refused}- \`$tool\`: ${bump_cur["$tool"]} → ${bump_new["$tool"]} — ${reason}\n"
    unset 'bump_cur["$tool"]'
    tries=$((tries + 1))
  done
}

mise_err_file="$(mktemp)"
if ! outdated="$(mise_global linux mise outdated --bump --json 2>"$mise_err_file")"; then
  outdated_fail="$(cat "$mise_err_file")"
  printf 'bump-versions.sh: mise outdated failed:\n%s\n' "$outdated_fail" >&2
  exit_code=1
fi
rm -f "$mise_err_file"

if [ -z "$outdated_fail" ]; then
  while IFS=$'\t' read -r name cur new path; do
    [ -n "$name" ] || continue
    case " $EXCLUDE " in
    *" $name "*)
      manual="${manual}- \`$name\`: $cur → $new — coupled/dual-edit pin (manual)\n"
      continue
      ;;
    esac
    if ! version_gt "$new" "$cur"; then
      skipped="${skipped}- \`$name\`: mise offered $new, which is not newer than the pinned $cur — left alone\n"
      continue
    fi
    # `source.path` comes back through the symlinked config root (mise
    # doesn't canonicalize it), e.g. /tmp/xxx/mise/config.toml rather than
    # $ROOT/config.toml — basename it instead of stripping a $ROOT prefix.
    # The config files sit flat at the repo root, so this is exact.
    file="${path##*/}"
    # gopls waits until go's final pin is known (below the loop).
    if [ "$name" = "go:golang.org/x/tools/gopls" ]; then
      gopls_cur="$cur" gopls_new="$new" gopls_file="$file"
      continue
    fi
    if $DRY; then
      bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
      continue
    fi
    if set_pin "$file" "$name" "$cur" "$new"; then
      bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
      bump_file["$name"]="$file"
      bump_cur["$name"]="$cur"
      bump_new["$name"]="$new"
    else
      printf '  ! could not rewrite %s = "%s" in %s\n' "$name" "$cur" "$file" >&2
      failed="${failed}- \`$name\` ($file): could not rewrite its pin in place (manual)\n"
    fi
  done < <(printf '%s' "$outdated" | jq -r 'to_entries[] | select(.value.bump != null and .value.bump != .value.requested) | [.key, .value.requested, .value.bump, .value.source.path] | @tsv')

  # gopls: bump only when the floor its go.mod declares is at or below the
  # go pin this run leaves (go may have just moved).
  if [ -n "${gopls_new:-}" ]; then
    go_pin="${bump_new[go]:-$(grep -m1 -E '^go = "' config.toml | sed -E 's/^go = "([^"]*)".*/\1/')}"
    floor="$(gopls_floor "$gopls_new")"
    if [ -z "$floor" ]; then
      manual="${manual}- \`go:golang.org/x/tools/gopls\`: $gopls_cur → $gopls_new — could not read its go.mod floor (offline?) (manual)\n"
    elif ! version_gt "$floor" "$go_pin"; then
      if $DRY; then
        bumped="${bumped}- \`go:golang.org/x/tools/gopls\` ($gopls_file): $gopls_cur → $gopls_new (needs go >= $floor)\n"
      elif set_pin "$gopls_file" "go:golang.org/x/tools/gopls" "$gopls_cur" "$gopls_new"; then
        bumped="${bumped}- \`go:golang.org/x/tools/gopls\` ($gopls_file): $gopls_cur → $gopls_new (needs go >= $floor)\n"
        bump_file["go:golang.org/x/tools/gopls"]="$gopls_file"
        bump_cur["go:golang.org/x/tools/gopls"]="$gopls_cur"
        bump_new["go:golang.org/x/tools/gopls"]="$gopls_new"
      else
        failed="${failed}- \`go:golang.org/x/tools/gopls\` ($gopls_file): could not rewrite its pin in place (manual)\n"
      fi
    else
      manual="${manual}- \`go:golang.org/x/tools/gopls\`: $gopls_cur → $gopls_new — needs go >= $floor, pinned go is $go_pin (waits for a go bump)\n"
    fi
  fi

  # node's postinstall LSP servers: newest release within each package's
  # CURRENT major (typescript: the 5.x line, see the header). A new major is
  # reported, not taken.
  node_line="$(grep -m1 -E '^node = \{' config.toml)"
  for spec in $(grep -oE '[a-z@/.-]+@[0-9]+\.[0-9]+\.[0-9]+' <<<"$node_line"); do
    pkg="${spec%@*}" pcur="${spec##*@}" major="${pcur%%.*}"
    pnew="$(npm_latest_in_major "$pkg" "$major")"
    platest="$(npm_latest "$pkg")"
    if [ -n "$platest" ] && [ "${platest%%.*}" != "$major" ] && version_gt "$platest" "$pcur"; then
      if [ "$pkg" = typescript ]; then
        manual="${manual}- \`typescript\` (node postinstall): held on ${major}.x — $platest has no lib/tsserver.js, which typescript-language-server needs\n"
      else
        manual="${manual}- \`$pkg\` (node postinstall): $pcur → $platest is a new major — take it by hand once its compatibility is checked\n"
      fi
    fi
    [ -n "$pnew" ] && version_gt "$pnew" "$pcur" || continue
    if $DRY; then
      bumped="${bumped}- \`$pkg\` (config.toml node postinstall): $pcur → $pnew\n"
    elif PIN_OLD="$spec" PIN_NEW="$pkg@$pnew" perl -i -pe \
      's/(?<=[ "])\Q$ENV{PIN_OLD}\E(?=[ "])/$ENV{PIN_NEW}/ if /^node = \{/' config.toml &&
      grep -qF "$pkg@$pnew" config.toml; then
      bumped="${bumped}- \`$pkg\` (config.toml node postinstall): $pcur → $pnew\n"
    else
      failed="${failed}- \`$pkg\` (node postinstall): could not rewrite $spec (manual)\n"
    fi
  done

  if [ -n "$bumped" ] && ! $DRY; then
    # mise lock writes a pypi: tool's dependency lock (its `uv = { path =
    # "locks/..." }` sidecar) only when uv >= 0.12.10 is installed. Without
    # uv it warns and skips, and the CI runner has none (mise-action runs
    # with install: false). That shipped basedpyright@1.40.1 without its
    # lock in #152; the first `wsu` on a host then generated the lock
    # inside the tracked checkout, and tasks/update's `git pull --ff-only`
    # refused the dirty tree. Install the pinned uv first. MISE_LOCKFILE=false
    # stops this install rewriting the lock files itself; locked mode (config.toml)
    # refuses a lock-file-off install, so MISE_LOCKED=0 lifts it for this one call.
    if ! mise_global linux env MISE_LOCKFILE=false MISE_LOCKED=0 mise install uv; then
      printf 'bump-versions.sh: mise install uv failed; pypi: dependency locks will be skipped\n' >&2
      failed="${failed}- \`mise install uv\` failed — pypi: dependency locks not regenerated (manual)\n"
      exit_code=1
    fi
    if ! lock_platform linux linux-x64; then
      printf 'bump-versions.sh: mise lock --platform linux-x64 failed\n' >&2
      failed="${failed}- \`mise lock --platform linux-x64\` failed (manual)\n"
      exit_code=1
    fi
    if ! lock_platform windows windows-x64; then
      printf 'bump-versions.sh: mise lock --platform windows-x64 failed\n' >&2
      failed="${failed}- \`mise lock --platform windows-x64\` failed (manual)\n"
      exit_code=1
    fi
    # Both `mise lock` calls above just reset the pypi:/npm: sidecar path
    # refs back to the stale .mise/locks/** layout (see
    # normalize_lock_sidecars above) — normalize them back to locks/** in
    # one pass now that both platforms are locked.
    if ! normalize_lock_sidecars; then
      printf 'bump-versions.sh: normalize_lock_sidecars failed\n' >&2
      failed="${failed}- \`normalize_lock_sidecars\` (locks/** sidecar normalization) failed (manual)\n"
      exit_code=1
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Layer 2: config.toml [vars] vcpkg_version, to the newest upstream release tag
# (scripts/lib/latest-tag.sh, the lookup tasks/check-updates reports).
# zjstatus_zellij_floor is a coupling floor, not a pin, so it is never bumped.
# -----------------------------------------------------------------------------
vcpkg_cur="$(grep -m1 -E '^vcpkg_version = ' config.toml | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
vcpkg_new="$(scripts/lib/latest-tag.sh microsoft/vcpkg)"
if [ -n "$vcpkg_new" ] && version_gt "$vcpkg_new" "$vcpkg_cur"; then
  if $DRY || set_pin config.toml vcpkg_version "$vcpkg_cur" "$vcpkg_new"; then
    vars_bumped="- \`vcpkg_version\` (vcpkg): $vcpkg_cur → $vcpkg_new\n"
  else
    printf '  ! could not rewrite vcpkg_version = "%s" in config.toml\n' "$vcpkg_cur" >&2
    failed="${failed}- \`vcpkg_version\` (vcpkg): could not rewrite its pin in place (manual)\n"
  fi
fi

# Keep the generated machine-memory TOOLS block (dotfiles/claude/CLAUDE.md)
# in sync with the pins we just bumped, in either layer. This
# script runs in CI (and locally) where the Claude Code sync-tool-memory.sh
# hook never fires, so regenerate here — otherwise the bumped pins and the
# generated file drift, and check-invariants.sh ("TOOLS block in sync")
# fails on merge. config*.toml is the single source of the tool list, so this is
# the only generated file to refresh.
# It needs a python with tomllib (3.11+); its stderr says why it failed.
if [ -n "$bumped$vars_bumped" ] && ! $DRY; then
  if ! scripts/gen-tool-memory.sh >/dev/null; then
    printf 'bump-versions.sh: scripts/gen-tool-memory.sh failed\n' >&2
    failed="${failed}- \`scripts/gen-tool-memory.sh\` failed — the TOOLS block in dotfiles/claude/CLAUDE.md is stale (manual)\n"
    exit_code=1
  fi
fi

{
  echo "## Automated version-pin bumps"
  echo
  if [ -n "$outdated_fail" ]; then
    echo "### mise outdated FAILED"
    echo
    echo '```'
    printf '%s\n' "$outdated_fail"
    echo '```'
    echo
    echo "_The mise tool-pin layer was skipped this run — see stderr above/in the workflow log. The config.toml [vars] layer below, if any, still ran._"
    echo
  fi
  $DRY && echo "_dry run — nothing was written._" && echo
  if [ -n "$bumped" ]; then
    echo "### Bumped mise tool pins (config*.toml)"
    echo
    printf '%b' "$bumped"
    echo
  fi
  if [ -n "$vars_bumped" ]; then
    echo "### Bumped in \`config.toml\` [vars]"
    echo
    printf '%b' "$vars_bumped"
    echo
  fi
  if [ -n "$manual" ]; then
    echo "### Manual bump available (not auto-edited)"
    echo
    printf '%b' "$manual"
    echo
  fi
  if [ -n "$refused" ]; then
    echo "### Refused by \`mise lock\` (reverted, manual)"
    echo
    echo "_mise would not lock these new versions, so they were left at the current pin. Check the reason, verify the release by hand, then bump it deliberately._"
    echo
    printf '%b' "$refused"
    echo
  fi
  if [ -n "$failed" ]; then
    echo "### Failed to edit (manual)"
    echo
    printf '%b' "$failed"
    echo
  fi
  if [ -n "$skipped" ]; then
    echo "### Skipped (could not map safely)"
    echo
    printf '%b' "$skipped"
    echo
  fi
  [ -n "$outdated_fail$bumped$vars_bumped$manual$refused$failed$skipped" ] || echo "All pins up to date — nothing to bump."
  echo
  echo "_Generated by \`scripts/bump-versions.sh\`. Each bumped pin installs on the next \`./bootstrap.sh\` (\`mise install\`); mise.lock updated. Review before merge._"
  # GitHub holds workflow runs on a PR opened by github-actions[bot] for approval.
  echo
  echo "_Lint doesn't start by itself on a PR opened by github-actions[bot]: click **Approve workflows to run** on this PR, and merge once it passes._"
} | tee "$SUMMARY"

exit "$exit_code"
