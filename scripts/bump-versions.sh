#!/usr/bin/env bash
# bump-versions.sh — propose version-pin bumps across the two layers that
# remain after the tool move to mise:
#
#   (1) mise tool pins in config.toml / config.linux.toml / config.dev.toml,
#       via `mise outdated --bump --json` + `mise config set` + `mise lock`.
#   (2) the handful of pins Make still owns directly in
#       makefile/versions.mk, via the unchanged `make check-updates`
#       porcelain path.
#
# Dual/triple-edit and coupled pins in EITHER layer are reported, never
# auto-edited (see the comment above each EXCLUDE list below) — they need a
# paired file edited in lockstep, a coupling floor bumped by hand from
# release notes, or a manual sanity check the bumper can't perform safely.
#
# Used by .github/workflows/version-bumps.yml (weekly) and runnable locally.
# --dry-run prints what would change without writing config*.toml,
# makefile/versions.mk, mise.lock/mise.*.lock, or the generated files — it
# only produces the summary.
# Writes a Markdown summary to $BUMP_SUMMARY_FILE (default /tmp/bump-summary.md)
# for the PR body. Exits 0 normally (report tool; the caller decides if a
# bump changed anything) but exits 1 when `mise outdated` itself fails
# (network, broken mise, malformed config — the mise half is skipped in that
# case, though the versions.mk half still runs and is reported) or a
# post-bump `mise lock` regeneration fails, so the weekly workflow fails
# visibly instead of silently reporting "nothing to bump". Individual
# `mise config set` failures are reported under "Failed to edit (manual)"
# without forcing a nonzero exit on their own.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit

VERSIONS="makefile/versions.mk"
SUMMARY="${BUMP_SUMMARY_FILE:-/tmp/bump-summary.md}"
DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

bumped=""        # mise tool pins bumped this run (config*.toml)
manual=""        # pins in either EXCLUDE list — reported, never auto-edited
skipped=""       # versions.mk pins check-updates found but couldn't map safely
mk_bumped=""     # makefile/versions.mk pins bumped this run
failed=""        # mise config set / mise lock calls that failed this run
outdated_fail="" # captured stderr when `mise outdated` itself fails (non-empty => mise half skipped)
exit_code=0

# -----------------------------------------------------------------------------
# Layer 1: mise tool pins (config.toml / config.linux.toml / config.dev.toml)
# -----------------------------------------------------------------------------
#
# Pins `mise config set` must NOT auto-edit (reported as manual instead):
#  - jq, gh, helix, opencode, github:can1357/oh-my-pi (omp), github:DevToys-app/DevToys
#    (devtoys-cli) all DUAL-EDIT bootstrap.ps1's $PortableTools/$InstallerTools
#    (the Windows half of each tool) — a version there needs its sha256/asset
#    verified and the pin bumped in lockstep, and check-invariants.sh's
#    check_version_pins asserts config*.toml == bootstrap.ps1 for every one
#    of them, so an auto-bump in config*.toml alone would fail that check
#    immediately (the same class of bug as version-bumps run #9, one layer
#    down: gh was added as a dual-edit pin without the matching exclusion).
#  - go + go:golang.org/x/tools/gopls are a COUPLED PAIR: gopls declares a
#    hard toolchain floor in its own go.mod (0.20.0 needs go 1.24.2, 0.21.0
#    needs 1.25, 0.23.0 needs 1.26.0) and mise's go: backend builds it via
#    `go install` using the PINNED go, so bumping gopls past the current
#    go's ceiling makes GOTOOLCHAIN=auto silently fetch a second toolchain
#    mid-provision — and hard-fails under GOTOOLCHAIN=local or a restricted
#    GOPROXY. Bump both together, deliberately.
#  - github:dj95/zjstatus is ABI-coupled to zellij: every zjstatus release
#    states its zellij floor, recorded as ZJSTATUS_ZELLIJ_FLOOR in
#    makefile/versions.mk and asserted against tools.zellij by
#    check-invariants.sh. A blind bump would raise the floor silently; bump
#    the pin AND the floor together, by hand, from the release notes.
#  - http:ncdu — its linux-x86_64 binary is published at dev.yorhel.nl for
#    only SOME releases (2.9.1 has one; 2.9.2 returns 404), so a bump must
#    be verified by hand against the download URL before landing or it
#    404s the install.
#  - node carries the LSP server pins for typescript-language-server,
#    typescript, bash-language-server, yaml-language-server and
#    vscode-langservers-extracted in its free-form `postinstall` string —
#    `mise outdated` only tracks node's OWN version, not the packages
#    embedded in that string, and a node bump is the trigger point for
#    reinstalling them (scripts/lib/mise-install.sh force-reinstalls node
#    only when its declared version is already present — the postinstall
#    only re-runs then). typescript must also stay on the 5.x major: ts-ls 6.x needs
#    typescript/lib/tsserver.js, gone in TS 7 (check_tsls_typescript_coupling
#    asserts this). Review and bump the whole postinstall string by hand.
#  - python is a three-way pin (makefile/versions.mk PYTHON_VERSION ==
#    config.toml tools.python == bootstrap.ps1 $PythonEnvVersion, all
#    asserted by check-invariants.sh) that ALSO needs a wheel-coverage check
#    before bumping — uv-managed pypi: dependency locks (basedpyright,
#    glances, asciinema, harlequin) can lag a brand-new CPython release
#    (duckdb/pydantic-core wheels in particular), and it's coupled to
#    UV_VERSION the same way (uv resolves interpreters from its own bundled
#    metadata, so a new CPython patch can need a newer uv first).
EXCLUDE="jq gh helix opencode github:can1357/oh-my-pi github:DevToys-app/DevToys github:dj95/zjstatus go go:golang.org/x/tools/gopls http:ncdu node python"

# Run a mise subcommand against this checkout as mise's GLOBAL config dir,
# from OUTSIDE the checkout, via a throwaway XDG_CONFIG_HOME symlink dir.
# Verified on-host (Task 10 fix wave): this is the only invocation form that
# reliably merges all three MISE_ENV-suffixed config files under `--global`
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

# mise 2026.9.9 quirk, verified on-host (Task 10 fix wave — repro + every
# form tried is recorded in the fix report): `mise lock`, including via
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
# dependence on checkout naming. See docs/claude/file-care.md and
# check-invariants.sh's check_mise_config_files.
normalize_lock_sidecars() {
  [ -d "$ROOT/.mise/locks" ] || return 0
  mkdir -p "$ROOT/locks" &&
    cp -a "$ROOT/.mise/locks/." "$ROOT/locks/" &&
    rm -rf "${ROOT:?}/.mise" &&
    sed -i 's#path = "\.mise/locks/#path = "locks/#g' \
      "$ROOT/mise.lock" "$ROOT/mise.linux.lock" "$ROOT/mise.dev.lock" || {
    echo "ERROR: normalize_lock_sidecars failed" >&2
    return 1
  }
}

mise_err_file="$(mktemp)"
if ! outdated="$(mise_global linux,dev,host,native mise outdated --bump --json 2>"$mise_err_file")"; then
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
    # `source.path` comes back through the symlinked config root (mise
    # doesn't canonicalize it), e.g. /tmp/xxx/mise/config.toml rather than
    # $ROOT/config.toml — basename it instead of stripping a $ROOT prefix.
    # All three config files sit flat at the repo root, so this is exact.
    file="${path##*/}"
    # Table-valued entries (github:/http: with options, or a bare { version =
    # ... } table) take tools.<name>.version; everything else is a plain
    # string entry and takes tools.<name> directly. The key path passed to
    # `mise config set` must stay UNQUOTED even when <name> contains `:` or
    # `/` — verified against mise 2026.9.9: a quoted segment (tools."<name>")
    # is taken literally, quote characters and all, as an unrecognized key —
    # it appends a broken duplicate entry instead of editing the real one in
    # place, while the unquoted form correctly locates and edits it.
    if grep -qE "^\"?${name//\//\\/}\"? = \{" "$file"; then
      key="tools.$name.version"
    else
      key="tools.$name"
    fi
    if $DRY; then
      bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
    elif mise config set -f "$file" "$key" "$new"; then
      bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
    else
      printf '  ! mise config set failed for %s (%s)\n' "$name" "$file" >&2
      failed="${failed}- \`$name\` ($file): mise config set failed (manual)\n"
    fi
  done < <(printf '%s' "$outdated" | jq -r 'to_entries[] | select(.value.bump != null and .value.bump != .value.requested) | [.key, .value.requested, .value.bump, .value.source.path] | @tsv')

  if [ -n "$bumped" ] && ! $DRY; then
    if ! mise_global linux,dev,host,native mise lock --global --platform linux-x64; then
      printf 'bump-versions.sh: mise lock --platform linux-x64 failed\n' >&2
      failed="${failed}- \`mise lock --platform linux-x64\` failed (manual)\n"
      exit_code=1
    fi
    if ! mise_global windows,dev mise lock --global --platform windows-x64; then
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
# Layer 2: makefile/versions.mk pins — unchanged path (make check-updates).
# Only 5 pins are checked here (the surviving UPDATE_SPECS entries: claude-cli,
# dozzle, nerd-fonts, vcpkg, python-env); ZJSTATUS_ZELLIJ_FLOOR is a coupling
# floor, not an UPDATE_SPECS pin, so it never reaches this path.
# -----------------------------------------------------------------------------
#
# JETBRAINSMONO_NERD_VERSION dual/triple-edits install-nerd-fonts.ps1 + the
# SHA case arm in makefile/lib/font.sh (a bump needs a SHA recompute).
# PYTHON_VERSION is the same three-way pin described in the mise EXCLUDE
# comment above (versions.mk is one of its three edit points) and needs the
# same wheel-coverage check before bumping.
EXCLUDE_MK="JETBRAINSMONO_NERD_VERSION PYTHON_VERSION"

# Tool names whose versions.mk variable does NOT follow the default
# uppercase(name)+_VERSION convention (the UPDATE_SPECS registry name differs
# from the pin variable). Trimmed to the entries UPDATE_SPECS still declares
# (dozzle and vcpkg map cleanly via the default convention already).
# Keys MUST stay quoted: shfmt reformats unquoted hyphenated subscripts as
# arithmetic ([nerd-fonts] -> [nerd - fonts]), silently breaking the lookup.
declare -A ALIAS=(
  ["nerd-fonts"]=JETBRAINSMONO_NERD_VERSION
  # Spec is named python-env (the make target) but the pin is PYTHON_VERSION.
  ["python-env"]=PYTHON_VERSION
  # "claude-cli" -> CLAUDE_CLI_VERSION would be wrong; it's a rolling `latest`
  # pin so no bump is ever produced, but mapping it keeps spec coverage
  # complete.
  ["claude-cli"]=CLAUDE_VERSION
)

updates=$(CHECK_UPDATES_PORCELAIN=1 \
  make -s --no-print-directory -C makefile check-updates MODE=dev 2>/dev/null |
  grep '^update|' || true)

while IFS='|' read -r _ name detail; do
  [ -n "${name:-}" ] || continue
  old="${detail%% *}" # "old → new" -> "old"
  new="${detail##* }" # "old → new" -> "new"
  var="${ALIAS[$name]:-$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_VERSION}"
  old_re="${old//./\\.}"
  new_re="${new//./\\.}"

  case " $EXCLUDE_MK " in
  *" $var "*)
    manual="${manual}- \`$var\` ($name): $old → $new — needs SHA/multi-file edit (manual)\n"
    continue
    ;;
  esac

  # Shared-pin dedup: an earlier row may have already bumped this var — done,
  # not a skip.
  if grep -qE "^${var}[[:space:]]*:=[[:space:]]*${new_re}[[:space:]]*\$" "$VERSIONS"; then
    continue
  fi

  if grep -qE "^${var}[[:space:]]*:=[[:space:]]*${old_re}[[:space:]]*\$" "$VERSIONS"; then
    $DRY || sed -i -E "s|^(${var}[[:space:]]*:=[[:space:]]*)${old_re}[[:space:]]*\$|\1${new}|" "$VERSIONS"
    mk_bumped="${mk_bumped}- \`$var\` ($name): $old → $new\n"
  else
    skipped="${skipped}- \`$var\` ($name): reported $old → $new but no matching pin line (manual)\n"
  fi
done <<<"$updates"

# Keep the generated machine-memory TOOLS block (chezmoi/private_dot_claude/
# CLAUDE.md) in sync with the pins we just bumped, in either layer. This
# script runs in CI (and locally) where the Claude Code sync-tool-memory.sh
# hook never fires, so regenerate here — otherwise the bumped pins and the
# generated file drift, and check-invariants.sh ("TOOLS block in sync")
# fails on merge. There is no longer a second generated-config script to
# call here: config*.toml IS the tool layer's single source of truth now.
if [ -n "$bumped$mk_bumped" ] && ! $DRY; then
  scripts/gen-tool-memory.sh >/dev/null
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
    echo "_The mise tool-pin layer was skipped this run — see stderr above/in the workflow log. The makefile/versions.mk layer below, if any, still ran._"
    echo
  fi
  $DRY && echo "_dry run — nothing was written._" && echo
  if [ -n "$bumped" ]; then
    echo "### Bumped mise tool pins (config*.toml)"
    echo
    printf '%b' "$bumped"
    echo
  fi
  if [ -n "$mk_bumped" ]; then
    echo "### Bumped in \`makefile/versions.mk\`"
    echo
    printf '%b' "$mk_bumped"
    echo
  fi
  if [ -n "$manual" ]; then
    echo "### Manual bump available (not auto-edited)"
    echo
    printf '%b' "$manual"
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
  [ -n "$outdated_fail$bumped$mk_bumped$manual$failed$skipped" ] || echo "All pins up to date — nothing to bump."
  echo
  echo "_Generated by \`scripts/bump-versions.sh\`. Each bumped pin installs on the next \`make provision\` (\`mise install\`); mise.lock updated. Review before merge._"
} | tee "$SUMMARY"

exit "$exit_code"
