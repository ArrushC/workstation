#!/usr/bin/env bash
# bump-versions.sh — propose version-pin bumps across the two layers that
# remain after the tool AND host-pin move to mise:
#
#   (1) mise tool pins in config.toml / config.linux.toml / config.owned.toml,
#       via `mise outdated --bump --json` + set_pin + `mise lock`.
#   (2) the handful of host pins config.toml [vars] owns directly (vcpkg —
#       python/nerd-fonts are dual/triple-edit, reported not
#       auto-edited), via scripts/lib/check-updates.sh worker mode (the same
#       specs tasks/check-updates registers) + set_pin.
#
# Dual-edit and coupled tool pins (the Windows halves in bootstrap.ps1,
# go+gopls, node's postinstall LSP servers) are bumped by dedicated code that
# keeps every paired edit in step. Only the pins in the EXCLUDE lists below
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
# post-bump `mise lock` regeneration fails, so the weekly workflow fails
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
manual=""        # pins in either EXCLUDE list — reported, never auto-edited
skipped=""       # a pin check-updates found but couldn't map safely
vars_bumped=""   # config.toml [vars] pins bumped this run
failed=""        # pin rewrites / mise lock calls that failed this run
outdated_fail="" # captured stderr when `mise outdated` itself fails (non-empty => mise half skipped)
exit_code=0

# -----------------------------------------------------------------------------
# Layer 1: mise tool pins (config.toml / config.linux.toml / config.owned.toml)
# -----------------------------------------------------------------------------
#
# Pins that need more than a one-line edit are bumped by dedicated code
# below, not skipped (user decision 2026-09-23: "always bump those packages").
#  - DUAL-EDIT (PS1_NAME below): jq, gh, helix, opencode, omp, DevToys each
#    have a Windows half in bootstrap.ps1's $PortableTools (Version + Url +
#    Sha256), and check_version_pins asserts both halves match. bump_ps1
#    swaps the version inside the Windows Url, downloads that asset and
#    hashes it, then rewrites all three fields together with the config
#    pin. If the download fails, neither half changes, and the pin is
#    reported under "Failed to edit".
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
#    (check_tsls_typescript_coupling). A changed postinstall string makes
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
#  - python is a three-way pin (config.toml vars.python_version ==
#    config.toml tools.python == bootstrap.ps1 $PythonEnvVersion, all
#    asserted by check-invariants.sh) that ALSO needs a wheel-coverage check
#    before bumping — uv-managed pypi: dependency locks (basedpyright,
#    glances, asciinema, harlequin) can lag a brand-new CPython release
#    (duckdb/pydantic-core wheels in particular), and it's coupled to
#    UV_VERSION the same way (uv resolves interpreters from its own bundled
#    metadata, so a new CPython patch can need a newer uv first).
EXCLUDE="github:dj95/zjstatus http:ncdu python"
# Coupled pins bumped by dedicated code instead of EXCLUDE. check_bumper_exclude
# requires every dual-edit/coupled pin to be in EXCLUDE, PS1_NAME, or this list.
# shellcheck disable=SC2034  # read by check-invariants.sh, not here
COUPLED_AUTO="go go:golang.org/x/tools/gopls node"

# mise tool name -> its bootstrap.ps1 $PortableTools Name (the dual-edit pins).
declare -A PS1_NAME=(
  ["jq"]="jq"
  ["gh"]="GitHub CLI"
  ["helix"]="Helix"
  ["opencode"]="OpenCode"
  ["github:can1357/oh-my-pi"]="Oh My Pi"
  ["github:DevToys-app/DevToys"]="DevToys CLI"
)

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
      "$ROOT/mise.lock" "$ROOT/mise.linux.lock" "$ROOT/mise.owned.lock" || {
    echo "ERROR: normalize_lock_sidecars failed" >&2
    return 1
  }
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

# ps1_field NAME FIELD — one field (Version/Url/Sha256) of the bootstrap.ps1
# $PortableTools entry whose Name is NAME.
ps1_field() {
  PS1_ENTRY="$1" PS1_FIELD="$2" perl -0777 -ne '
    print $1 if /Name\s*=\s*"\Q$ENV{PS1_ENTRY}\E"[^}]*?\b\Q$ENV{PS1_FIELD}\E\s*=\s*"([^"]*)"/s
  ' bootstrap.ps1
}

# ps1_set NAME VERSION URL SHA256 — rewrite those three fields of one
# $PortableTools entry, byte-for-byte elsewhere (the UTF-8 BOM PowerShell 5.1
# needs survives, since perl only substitutes inside the match). Fails without
# writing unless exactly one entry matched.
ps1_set() {
  local n
  n="$(PS1_ENTRY="$1" PS1_V="$2" PS1_U="$3" PS1_S="$4" perl -0777 -e '
    my $f = "bootstrap.ps1";
    open(my $in, "<:raw", $f) or die "$f: $!";
    local $/; my $s = <$in>; close $in;
    my $n = ($s =~ s#(Name\s*=\s*"\Q$ENV{PS1_ENTRY}\E"[^}]*?\bVersion\s*=\s*")[^"]*("[^}]*?\bUrl\s*=\s*")[^"]*("[^}]*?\bSha256\s*=\s*")[0-9a-fA-F]*(")#$1$ENV{PS1_V}$2$ENV{PS1_U}$3$ENV{PS1_S}$4#gs);
    if ($n == 1) { open(my $out, ">:raw", $f) or die "$f: $!"; print $out $s; close $out }
    print $n + 0;
  ')" || return 1
  [ "$n" = 1 ]
}

# bump_ps1 NAME CUR NEW — move a dual-edit tool's Windows half from CUR to NEW:
# swap the version inside its Url, download that asset, hash it, and write
# Version + Url + Sha256. Old values are saved in ps1_old_* for a revert.
declare -A ps1_old_url ps1_old_sha
bump_ps1() {
  local entry="$1" cur="$2" new="$3" url newurl tmp sha
  url="$(ps1_field "$entry" Url)"
  [ -n "$url" ] || return 1
  case "$url" in *"$cur"*) ;; *) return 1 ;; esac
  newurl="${url//"$cur"/"$new"}"
  tmp="$(mktemp)"
  if ! curl -fsSL --retry 2 --max-time 600 -o "$tmp" "$newurl"; then
    printf '  ! %s: could not download %s\n' "$entry" "$newurl" >&2
    rm -f "$tmp"
    return 1
  fi
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
  rm -f "$tmp"
  ps1_old_url["$entry"]="$url"
  ps1_old_sha["$entry"]="$(ps1_field "$entry" Sha256)"
  ps1_set "$entry" "$new" "$newurl" "$sha"
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
lock_platform() {
  local mise_env="$1" platform="$2" err tool reason tries=0
  err="$(mktemp)"
  while :; do
    if mise_global "$mise_env" mise lock --global --platform "$platform" 2>"$err"; then
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
    # A dual-edit tool's Windows half moved with it; put that back too, or
    # check_version_pins fails on the half-reverted pair.
    if [ -n "${PS1_NAME["$tool"]+x}" ] &&
      ! ps1_set "${PS1_NAME["$tool"]}" "${bump_cur["$tool"]}" \
        "${ps1_old_url["${PS1_NAME["$tool"]}"]}" "${ps1_old_sha["${PS1_NAME["$tool"]}"]}"; then
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
if ! outdated="$(mise_global linux,owned,host,native mise outdated --bump --json 2>"$mise_err_file")"; then
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
    # All three config files sit flat at the repo root, so this is exact.
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
    # Dual-edit: the Windows half must land first (download + hash); if it
    # can't, leave both halves alone.
    if [ -n "${PS1_NAME["$name"]+x}" ] && ! bump_ps1 "${PS1_NAME["$name"]}" "$cur" "$new"; then
      failed="${failed}- \`$name\`: $cur → $new — could not fetch/hash its Windows asset for bootstrap.ps1; both halves left at $cur (manual)\n"
      continue
    fi
    if set_pin "$file" "$name" "$cur" "$new"; then
      if [ -n "${PS1_NAME["$name"]+x}" ]; then
        bumped="${bumped}- \`$name\` ($file + bootstrap.ps1): $cur → $new\n"
      else
        bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
      fi
      bump_file["$name"]="$file"
      bump_cur["$name"]="$cur"
      bump_new["$name"]="$new"
    else
      printf '  ! could not rewrite %s = "%s" in %s\n' "$name" "$cur" "$file" >&2
      failed="${failed}- \`$name\` ($file): could not rewrite its pin in place (manual)\n"
      if [ -n "${PS1_NAME["$name"]+x}" ]; then
        ps1_set "${PS1_NAME["$name"]}" "$cur" "${ps1_old_url["${PS1_NAME["$name"]}"]}" \
          "${ps1_old_sha["${PS1_NAME["$name"]}"]}" ||
          failed="${failed}- \`$name\`: bootstrap.ps1 was bumped but could not be reverted — fix by hand\n"
      fi
    fi
  done < <(printf '%s' "$outdated" | jq -r 'to_entries[] | select(.value.bump != null and .value.bump != .value.requested) | [.key, .value.requested, .value.bump, .value.source.path] | @tsv')

  # gopls: bump only when the floor its go.mod declares is at or below the
  # go pin this run leaves (go may have just moved).
  if [ -n "${gopls_new:-}" ]; then
    go_pin="${bump_new[go]:-$(grep -m1 -E '^go = "' config.owned.toml | sed -E 's/^go = "([^"]*)".*/\1/')}"
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
  node_line="$(grep -m1 -E '^node = \{' config.owned.toml)"
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
      bumped="${bumped}- \`$pkg\` (config.owned.toml node postinstall): $pcur → $pnew\n"
    elif PIN_OLD="$spec" PIN_NEW="$pkg@$pnew" perl -i -pe \
      's/(?<=[ "])\Q$ENV{PIN_OLD}\E(?=[ "])/$ENV{PIN_NEW}/ if /^node = \{/' config.owned.toml &&
      grep -qF "$pkg@$pnew" config.owned.toml; then
      bumped="${bumped}- \`$pkg\` (config.owned.toml node postinstall): $pcur → $pnew\n"
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
    # stops this install rewriting the lock files itself.
    if ! mise_global linux,owned,host,native env MISE_LOCKFILE=false mise install uv; then
      printf 'bump-versions.sh: mise install uv failed; pypi: dependency locks will be skipped\n' >&2
      failed="${failed}- \`mise install uv\` failed — pypi: dependency locks not regenerated (manual)\n"
      exit_code=1
    fi
    if ! lock_platform linux,owned,host,native linux-x64; then
      printf 'bump-versions.sh: mise lock --platform linux-x64 failed\n' >&2
      failed="${failed}- \`mise lock --platform linux-x64\` failed (manual)\n"
      exit_code=1
    fi
    if ! lock_platform windows,owned windows-x64; then
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
# Layer 2: config.toml [vars] host pins — vcpkg_version bumps
# automatically; python_version + nerd_font_version (EXCLUDE_VARS) are
# dual/triple-edit pins, reported only, never auto-edited. Drift is checked
# via scripts/lib/check-updates.sh worker mode against the SAME specs
# tasks/check-updates registers; claude-cli is a rolling `latest` pin outside
# [vars] (no bump path), so isn't checked here. ZJSTATUS_ZELLIJ_FLOOR is a
# coupling floor, not a pin, so it never reaches this path either.
# -----------------------------------------------------------------------------
#
# nerd_font_version dual/triple-edits scripts/install-nerd-fonts.ps1 + the SHA
# case arm in scripts/lib/font.sh (a bump needs a SHA recompute). python_version
# is the same three-way pin described in the mise EXCLUDE comment above
# (config.toml [vars] is one of its three edit points) and needs the same
# wheel-coverage check before bumping.
EXCLUDE_VARS="nerd_font_version python_version"

# config.toml [vars] key -> its current string value (a plain `key = "value"`
# line — the same shape check-invariants.sh's tomlval reads via tomllib; grep
# is enough here since every [vars] entry is a single-line string).
varval() {
  grep -E "^$1 = " config.toml | head -1 | sed -E 's/^[^"]*"([^"]*)".*/\1/'
}

# check-updates spec name -> its config.toml [vars] key.
declare -A VARS_KEY=(
  ["python-env"]=python_version
  ["nerd-fonts"]=nerd_font_version
  ["vcpkg"]=vcpkg_version
)

vars_specs="python-env|$(varval python_version)|python/cpython|v$(varval python_version)
nerd-fonts|$(varval nerd_font_version)|ryanoasis/nerd-fonts|v$(varval nerd_font_version)
vcpkg|$(varval vcpkg_version)|microsoft/vcpkg|$(varval vcpkg_version)"

updates=$(printf '%s\n' "$vars_specs" |
  CHECK_UPDATES_PORCELAIN=1 scripts/lib/check-updates.sh |
  grep '^update|' || true)

while IFS='|' read -r _ name detail; do
  [ -n "${name:-}" ] || continue
  old="${detail%% *}" # "old → new" -> "old"
  new="${detail##* }" # "old → new" -> "new"
  key="${VARS_KEY[$name]:-}"
  [ -n "$key" ] || continue

  case " $EXCLUDE_VARS " in
  *" $key "*)
    manual="${manual}- \`$key\` ($name): $old → $new — needs SHA/multi-file edit (manual)\n"
    continue
    ;;
  esac

  if $DRY; then
    vars_bumped="${vars_bumped}- \`$key\` ($name): $old → $new\n"
  elif set_pin config.toml "$key" "$old" "$new"; then
    vars_bumped="${vars_bumped}- \`$key\` ($name): $old → $new\n"
  else
    printf '  ! could not rewrite %s = "%s" in config.toml\n' "$key" "$old" >&2
    failed="${failed}- \`$key\` ($name): could not rewrite its pin in place (manual)\n"
  fi
done <<<"$updates"

# Keep the generated machine-memory TOOLS block (dotfiles/claude/CLAUDE.md)
# in sync with the pins we just bumped, in either layer. This
# script runs in CI (and locally) where the Claude Code sync-tool-memory.sh
# hook never fires, so regenerate here — otherwise the bumped pins and the
# generated file drift, and check-invariants.sh ("TOOLS block in sync")
# fails on merge. There is no longer a second generated-config script to
# call here: config*.toml IS the tool layer's single source of truth now.
if [ -n "$bumped$vars_bumped" ] && ! $DRY; then
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
} | tee "$SUMMARY"

exit "$exit_code"
