#!/usr/bin/env bash
# check-invariants.sh — mechanically enforce the load-bearing repo invariants
# documented in CLAUDE.md + docs/claude/file-care.md.
#
# Single source of truth for the checks; invoked three ways:
#   - make lint                  (makefile/Makefile -> $REPO_ROOT/scripts/check-invariants.sh)
#   - .githooks/pre-commit       (installed via `make install-hooks`)
#   - .github/workflows/lint.yml (CI backstop)
#
# Runs from anywhere — it cd's to the repo root. Exits 0 if all checks pass,
# non-zero otherwise. Deliberately NOT `set -e`: a checker must run EVERY check
# and tally failures, not abort on the first non-zero grep. We keep -u and
# pipefail and guard with explicit conditionals.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

fails=0
hdr() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok() { printf '   %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad() {
  printf '   %s✗%s %s\n' "$RED" "$RESET" "$*"
  fails=$((fails + 1))
}
note() { printf '   %s·%s %s\n' "$YELLOW" "$RESET" "$*"; }

# Extract a `NAME := value` value from makefile/versions.mk.
mkval() {
  grep -E "^$1[[:space:]]*:=" makefile/versions.mk |
    head -1 |
    sed -E 's/^[^:=]*:=[[:space:]]*//; s/[[:space:]]*(#.*)?$//'
}

check_version_pins() {
  hdr "version-pin dual/triple-edits"
  local v ref ps_v scope_dest expect rc_z rc_b font_re font_has

  v=$(mkval CCSTATUSLINE_VERSION)
  ref=$(grep -oE 'ccstatusline@[0-9][0-9.]*' \
    chezmoi/private_dot_claude/modify_private_settings.json | head -1 | sed 's/.*@//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "ccstatusline @ $v  (versions.mk == modify_private_settings.json)"
  else
    bad "ccstatusline drift: versions.mk='$v' modify_private_settings.json='$ref'"
  fi

  v=$(mkval JETBRAINSMONO_NERD_VERSION)
  ps_v=$(grep -E '^\$Version[[:space:]]*=' scripts/install-nerd-fonts.ps1 |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  # font.sh pins the SHA per version in a `case "$VERSION"` block; the runtime
  # looks it up BY VALUE, so verify an arm for $v EXISTS (position-independent)
  # — appending a new arm on a bump (as font.sh instructs) must still pass.
  font_re="^[[:space:]]*${v//./\\.}\\)[[:space:]]*EXPECT_SHA"
  if grep -qE "$font_re" makefile/lib/font.sh; then font_has=yes; else font_has=no; fi
  if [ -n "$v" ] && [ "$v" = "$ps_v" ] && [ "$font_has" = yes ]; then
    ok "jetbrains-mono nerd @ $v  (versions.mk == install-nerd-fonts.ps1; font.sh SHA arm present)"
  else
    bad "jetbrains-mono nerd drift: versions.mk='$v' install-nerd-fonts.ps1='$ps_v' font.sh-SHA-arm=$font_has"
  fi

  v=$(mkval HELIX_VERSION)
  ref=$(grep -oE 'helix-editor/helix/releases/download/[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "helix @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "helix drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval JQ_VERSION)
  ref=$(grep -oE 'jqlang/jq/releases/download/jq-[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/jq-##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "jq @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "jq drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval OPENCODE_VERSION)
  ref=$(grep -oE 'anomalyco/opencode/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "opencode @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "opencode drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval OMP_VERSION)
  ref=$(grep -oE 'can1357/oh-my-pi/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "omp @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "omp drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval DEVTOYS_CLI_VERSION)
  ref=$(grep -oE 'DevToys-app/DevToys/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "devtoys-cli @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "devtoys-cli drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval GH_VERSION)
  ref=$(grep -oE 'cli/cli/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "gh @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "gh drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval MISE_VERSION)
  ref=$(grep -oE 'jdx/mise/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "mise @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "mise drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  v=$(mkval PYTHON_VERSION)
  ref=$(grep -oE '^\$PythonEnvVersion *= *"[0-9][0-9.]+"' bootstrap.ps1 |
    grep -oE '[0-9][0-9.]+' | head -1)
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "python-env @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "python-env drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi

  # shfmt + gitleaks are enforced below (check_shfmt / check_gitleaks). CI
  # (.github/workflows/lint.yml) installs these exact versions so the checks
  # actually run there, so the pins dual-edit with lint.yml's `SHFMT=`/`GITLEAKS=`.
  v=$(mkval SHFMT_VERSION)
  ref=$(grep -oE 'SHFMT=[0-9][0-9.]+' .github/workflows/lint.yml | head -1 | sed 's/SHFMT=//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "shfmt @ $v  (versions.mk == lint.yml)"
  else
    bad "shfmt drift: versions.mk='$v' lint.yml='$ref'"
  fi

  v=$(mkval GITLEAKS_VERSION)
  ref=$(grep -oE 'GITLEAKS=[0-9][0-9.]+' .github/workflows/lint.yml | head -1 | sed 's/GITLEAKS=//')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "gitleaks @ $v  (versions.mk == lint.yml)"
  else
    bad "gitleaks drift: versions.mk='$v' lint.yml='$ref'"
  fi

  scope_dest=$(grep -E '^[[:space:]]*HELIX_RUNTIME_DEST[[:space:]]*:=[[:space:]]*/usr' \
    makefile/scope.mk | head -1 | sed -E 's#.*:=[[:space:]]*##; s/[[:space:]]*$//')
  expect="${scope_dest}/runtime"
  rc_z=$(grep -oE 'HELIX_RUNTIME="[^"]*"' chezmoi/dot_zshrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  rc_b=$(grep -oE 'HELIX_RUNTIME="[^"]*"' chezmoi/dot_bashrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  if [ -n "$scope_dest" ] && [ "$rc_z" = "$expect" ] && [ "$rc_b" = "$expect" ]; then
    ok "helix-runtime @ $expect  (scope.mk == zshrc == bashrc)"
  else
    bad "helix-runtime drift: expect='$expect' zshrc='$rc_z' bashrc='$rc_b'"
  fi

  # VCPKG_ROOT — the dev-gated rc literal must match VCPKG_ROOT_DIR in the
  # Makefile (the vcpkg target clones the tree there; the rc exports it).
  mk_vcpkg=$(grep -E '^[[:space:]]*VCPKG_ROOT_DIR[[:space:]]*:=[[:space:]]*/' \
    makefile/Makefile | head -1 | sed -E 's#.*:=[[:space:]]*##; s/[[:space:]]*$//')
  rc_z=$(grep -oE 'VCPKG_ROOT="[^"]*"' chezmoi/dot_zshrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  rc_b=$(grep -oE 'VCPKG_ROOT="[^"]*"' chezmoi/dot_bashrc.tmpl | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  if [ -n "$mk_vcpkg" ] && [ "$rc_z" = "$mk_vcpkg" ] && [ "$rc_b" = "$mk_vcpkg" ]; then
    ok "vcpkg-root @ $mk_vcpkg  (Makefile == zshrc == bashrc)"
  else
    bad "vcpkg-root drift: Makefile='$mk_vcpkg' zshrc='$rc_z' bashrc='$rc_b'"
  fi
}

# Every dual-edit version pin verified by check_version_pins must also sit in
# scripts/bump-versions.sh's EXCLUDE list — otherwise the weekly bumper edits
# the versions.mk half alone and this script fails the bump workflow on its
# own PR (version-bumps run #9: gh 2.97.0, added as a dual-edit in #94 without
# the exclusion). The pin set is derived from check_version_pins' own source
# (its mkval calls), so a new dual-edit pin check added there is asserted here
# automatically — no second list to drift. One-directional: extra EXCLUDE
# entries (NCDU's 404-prone binary) are fine.
check_bumper_exclude() {
  hdr "bump-versions.sh EXCLUDE covers dual-edit pins"
  local exclude pins var missing="" n=0
  exclude=$(grep -m1 -E '^EXCLUDE=' scripts/bump-versions.sh |
    sed -E 's/^EXCLUDE="//; s/"[[:space:]]*$//')
  if [ -z "$exclude" ]; then
    bad "scripts/bump-versions.sh: EXCLUDE= line not found"
    return
  fi
  pins=$(awk '/^check_version_pins\(\) \{/,/^\}/' scripts/check-invariants.sh |
    grep -oE 'mkval [A-Z_]+_VERSION' | awk '{print $2}' | sort -u)
  while read -r var; do
    [ -n "$var" ] || continue
    n=$((n + 1))
    case " $exclude " in
    *" $var "*) ;;
    *) missing="$missing $var" ;;
    esac
  done <<<"$pins"
  if [ "$n" -gt 0 ] && [ -z "$missing" ]; then
    ok "all $n dual-edit pins in bumper EXCLUDE (bump-versions.sh)"
  else
    bad "dual-edit pin(s) missing from bump-versions.sh EXCLUDE:${missing:- <none derived>} — the weekly bumper would auto-edit versions.mk alone and fail the pin check"
  fi
}

check_line_endings_and_mode() {
  hdr "line-endings (LF) + git mode (100755)"
  local f mode crlf=0 modebad=0 missing=0
  local -a files=(makefile/lib/*.sh scripts/*.sh .claude/hooks/*.sh chezmoi/dot_local/bin/executable_*)
  [ -e .githooks/pre-commit ] && files+=(.githooks/pre-commit)
  for f in "${files[@]}"; do
    if [ ! -e "$f" ]; then
      bad "missing: $f"
      missing=$((missing + 1))
      continue
    fi
    if LC_ALL=C grep -q $'\r' "$f"; then
      bad "CRLF: $f"
      crlf=$((crlf + 1))
    fi
    mode=$(git ls-files --stage -- "$f" | awk '{print $1}')
    if [ -z "$mode" ]; then
      note "untracked (commit it so the mode is recorded): $f"
    elif [ "$mode" != "100755" ]; then
      bad "git mode $mode, want 100755: $f"
      modebad=$((modebad + 1))
    fi
  done
  if [ "$crlf" -eq 0 ] && [ "$modebad" -eq 0 ] && [ "$missing" -eq 0 ]; then
    ok "${#files[@]} files: LF + 100755"
  fi
}

check_bom() {
  hdr "UTF-8 BOM on PowerShell files"
  local f b allgood=1
  local -a files=(scripts/manage-hosts.ps1 bootstrap.ps1 scripts/install-nerd-fonts.ps1)
  for f in "${files[@]}"; do
    if [ ! -e "$f" ]; then
      bad "missing: $f"
      allgood=0
      continue
    fi
    b=$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')
    if [ "$b" != "efbbbf" ]; then
      bad "no BOM (first bytes: $b): $f"
      allgood=0
    fi
  done
  [ "$allgood" -eq 1 ] && ok "${#files[@]} .ps1 files carry EF BB BF"
}

check_sentinels() {
  hdr "sentinel blocks matched"
  local s e
  # Anchor to a whole marker line — prose that merely mentions the token
  # must not count.
  s=$(grep -cE '^[[:space:]]*# CCSTATUSLINE:START[[:space:]]*$' chezmoi/.chezmoiignore.tmpl)
  e=$(grep -cE '^[[:space:]]*# CCSTATUSLINE:END[[:space:]]*$' chezmoi/.chezmoiignore.tmpl)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "chezmoiignore  CCSTATUSLINE:START/END (1/1)"
  else
    bad "chezmoiignore CCSTATUSLINE sentinels START=$s END=$e (want 1/1)"
  fi
  s=$(grep -cE '<!-- TOOLS:START' chezmoi/private_dot_claude/CLAUDE.md)
  e=$(grep -cE '<!-- TOOLS:END -->' chezmoi/private_dot_claude/CLAUDE.md)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "machine-memory  TOOLS:START/END (1/1)"
  else
    bad "machine-memory TOOLS sentinels START=$s END=$e (want 1/1)"
  fi
}

check_tools_block() {
  hdr "machine-memory TOOLS block in sync"
  local mem="chezmoi/private_dot_claude/CLAUDE.md" tmp
  if [ ! -f "$mem" ]; then
    bad "missing: $mem"
    return
  fi
  tmp="$(mktemp)"
  cp "$mem" "$tmp"
  if MEMFILE="$tmp" scripts/gen-tool-memory.sh >/dev/null 2>&1; then
    if diff -q "$mem" "$tmp" >/dev/null; then
      ok "TOOLS block matches gen-tool-memory.sh output"
    else
      bad "TOOLS block stale — run: scripts/gen-tool-memory.sh"
      diff "$mem" "$tmp" | sed 's/^/       /' | head -30
    fi
  else
    bad "gen-tool-memory.sh failed against a temp copy"
  fi
  rm -f "$tmp"
}

check_mise_config() {
  hdr "mise conf.d (generated from versions.mk) in sync + parseable"
  local dir="chezmoi/dot_config/mise/conf.d" tmp f py
  for f in workstation.toml workstation-dev.toml; do
    if [ ! -f "$dir/$f" ]; then
      bad "missing: $dir/$f — run: scripts/gen-mise-config.sh"
      return
    fi
  done
  tmp="$(mktemp -d)"
  if OUTDIR="$tmp" scripts/gen-mise-config.sh >/dev/null 2>&1; then
    if diff -q "$dir/workstation.toml" "$tmp/workstation.toml" >/dev/null &&
      diff -q "$dir/workstation-dev.toml" "$tmp/workstation-dev.toml" >/dev/null; then
      ok "conf.d matches gen-mise-config.sh output"
    else
      bad "conf.d stale — run: scripts/gen-mise-config.sh"
      diff -r "$dir" "$tmp" | sed 's/^/       /' | head -30
    fi
  else
    bad "gen-mise-config.sh failed against a temp OUTDIR"
  fi
  rm -rf "$tmp"
  # TOML parse: EL9's python3 is 3.9 (no tomllib); prefer the python-env wpy
  # (3.14) when present, soft-skip otherwise (CI's python3 is 3.11+).
  py=""
  for f in wpy python3; do
    if command -v "$f" >/dev/null 2>&1 && "$f" -c 'import tomllib' 2>/dev/null; then
      py="$f"
      break
    fi
  done
  if [ -z "$py" ]; then
    note "no python with tomllib — TOML parse check skipped locally (CI enforces)"
    return
  fi
  if "$py" - "$dir/workstation.toml" "$dir/workstation-dev.toml" <<'PY' 2>/dev/null
import sys, tomllib
for p in sys.argv[1:]:
    with open(p, "rb") as fh:
        d = tomllib.load(fh)
    if not d.get("tools"):
        raise SystemExit(f"{p}: no [tools]")
PY
  then
    ok "both files parse (tomllib) and declare [tools]"
  else
    bad "conf.d TOML parse failed (tomllib) — regenerate: scripts/gen-mise-config.sh"
  fi
}

check_lsp_plugin() {
  hdr "workstation-lsp plugin manifest"
  local src="chezmoi/private_dot_claude/skills/workstation-lsp"
  if [ ! -f "$src/dot_claude-plugin/plugin.json" ] || [ ! -f "$src/dot_lsp.json" ]; then
    bad "missing workstation-lsp plugin source ($src/dot_claude-plugin/plugin.json + dot_lsp.json)"
    return
  fi
  if ! command -v claude >/dev/null 2>&1; then
    note "claude not installed — skipped LSP plugin validate (dev hosts enforce; CI has no claude)"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude-plugin"
  cp "$src/dot_claude-plugin/plugin.json" "$tmp/.claude-plugin/plugin.json"
  cp "$src/dot_lsp.json" "$tmp/.lsp.json"
  [ -f "$src/SKILL.md" ] && cp "$src/SKILL.md" "$tmp/SKILL.md"
  if claude plugin validate "$tmp" --strict >/dev/null 2>&1; then
    ok "workstation-lsp manifest validates (claude plugin validate --strict)"
  else
    bad "workstation-lsp manifest failed claude plugin validate --strict:"
    claude plugin validate "$tmp" --strict 2>&1 | sed 's/^/       /' | head -20
  fi
  rm -rf "$tmp"
}

check_chezmoiignore_targets() {
  hdr "chezmoiignore uses target paths (not source-state names)"
  local offenders
  # Strip {{/* ... */}} Go-template comment blocks (their prose documents the
  # dot_/private_dot_/.tmpl naming, which would false-positive), then keep only
  # real pattern lines (a single token — not a # comment, {{ }} directive, or
  # prose), then flag any that use a source-state name instead of a target path.
  offenders=$(awk '
    /\{\{\/\*/ { inblk=1 }
    inblk { if ($0 ~ /\*\/\}\}/) inblk=0; next }
    { print }
  ' chezmoi/.chezmoiignore.tmpl |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    grep -vE '^(#|\{\{|$)' |
    grep -E '^[^[:space:]]+$' |
    grep -E '(^|/)(dot_|private_dot_)|\.tmpl$')
  if [ -z "$offenders" ]; then
    ok "no dot_/private_dot_/*.tmpl source-state patterns"
  else
    bad "source-state-style ignore patterns (silent no-op — use target paths):"
    printf '%s\n' "$offenders" | sed 's/^/       /'
  fi
}

# --- flag-parity: repo-script flags == completion-surface flags --------------
# Spec: docs/superpowers/specs/2026-07-13-script-flag-completions-design.md.
# Five pairs: the three .sh scripts -> zsh _<name> files + completions.bash;
# the two .ps1 scripts -> the workstation_*_flags records in config.nu.tmpl.
# Long-form flags only. Trailing args to _sh_script_flags are EXCLUSIONS —
# flags the script accepts but completions deliberately omit
# (bootstrap.sh: the removed-flag --full fail arm, the --checkforupdates
# compat alias).

# Long flags a bash script accepts: its case arms (any nesting depth),
# alternatives split, short forms dropped. $2+ = exclusions.
_sh_script_flags() {
  local script=$1 out f
  shift
  out=$(grep -E '^[[:space:]]*-{1,2}[A-Za-z-]+([[:space:]]*\|[[:space:]]*-{1,2}[A-Za-z-]+)*\)' "$script" |
    grep -oE -- '--[a-z-]+' | sort -u)
  for f in "$@"; do
    out=$(printf '%s\n' "$out" | grep -vx -- "$f")
  done
  printf '%s\n' "$out"
}

# -Flag names from a PowerShell script's param() block.
_ps_script_flags() {
  awk '/^param\(/{f=1} f{print} f&&/^\)/{exit}' "$1" |
    grep -oE '\[(switch|string)\]\$[A-Za-z]+' | sed 's/.*\$/-/' | sort -u
}

# --flag tokens from a zsh completion file (full-line comments stripped —
# comments may legitimately name excluded flags).
_zsh_completion_flags() {
  grep -v '^#' "$1" | grep -oE -- '--[a-z-]+' | sort -u
}

# --flag tokens from one function body in completions.bash.
_bash_completion_flags() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" {f=1} f{print} f&&/^}/{exit}' \
    chezmoi/dot_config/bash/completions.bash |
    grep -oE -- '--[a-z-]+' | sort -u
}

# Quoted "-Flag" values from one `let workstation_*_flags` list in config.nu.tmpl.
_nu_completion_flags() {
  awk -v v="$1" '$0 ~ "^let "v {f=1} f{print} f&&/^\]/{exit}' \
    chezmoi/AppData/Roaming/nushell/config.nu.tmpl |
    grep -oE '"-[A-Za-z]+"' | tr -d '"' | sort -u
}

_flags_eq() { # $1=label  $2=script-side set  $3=completion-side set
  if [ -n "$2" ] && [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 drift (<:script-only  >:completion-only):"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/       /' | head -20
  fi
}

check_completion_parity() {
  hdr "script-flag <-> completion parity"
  local want

  want=$(_sh_script_flags bootstrap.sh --full --checkforupdates)
  _flags_eq "bootstrap.sh == _bootstrap.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_bootstrap.sh)"
  _flags_eq "bootstrap.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_bootstrap)"

  want=$(_sh_script_flags scripts/manage-hosts.sh)
  _flags_eq "manage-hosts.sh == _manage-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_manage-hosts.sh)"
  _flags_eq "manage-hosts.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_manage_hosts)"

  want=$(_sh_script_flags scripts/update-hosts.sh)
  _flags_eq "update-hosts.sh == _update-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags chezmoi/dot_config/zsh/completions/_update-hosts.sh)"
  _flags_eq "update-hosts.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_update_hosts)"

  want=$(_ps_script_flags bootstrap.ps1)
  _flags_eq "bootstrap.ps1 == config.nu (nushell)" "$want" \
    "$(_nu_completion_flags workstation_bootstrap_flags)"

  want=$(_ps_script_flags scripts/manage-hosts.ps1)
  _flags_eq "manage-hosts.ps1 == config.nu (nushell)" "$want" \
    "$(_nu_completion_flags workstation_manage_hosts_flags)"
}

# --- python-env lib-list parity ----------------------------------------------
# The blessed-env library list is defined twice (Make never runs on Windows):
# PY_LIBS in makefile/lib/python-env.sh and $PythonLibs in bootstrap.ps1. Both
# are one-line arrays by contract (comments at each site) so single-line greps
# can extract them. Order-insensitive compare (sort) — content is the contract.
check_zjstatus_zellij_coupling() {
  hdr "zjstatus <-> zellij plugin-ABI floor"
  local zj zjs floor
  zj=$(mkval ZELLIJ_VERSION)
  zjs=$(mkval ZJSTATUS_VERSION)
  floor=$(mkval ZJSTATUS_ZELLIJ_FLOOR)
  if [ -z "$zj" ] || [ -z "$zjs" ] || [ -z "$floor" ]; then
    bad "could not read ZELLIJ_VERSION / ZJSTATUS_VERSION / ZJSTATUS_ZELLIJ_FLOOR from versions.mk"
    return
  fi
  # zjstatus is compiled against zellij-tile, and each release states the
  # zellij floor it needs (v0.25.0: ">= 0.45.0 required" — it fixed frame
  # flicker that 0.45.0 introduced). The floor is recorded next to the pin
  # rather than fetched: the release notes are prose, and this check must
  # pass offline. A mismatch is silent at runtime — the bar pane just fails
  # to render — and `zellij setup --check` still reports Well defined.
  if [ "$(printf '%s\n%s\n' "$floor" "$zj" | sort -V | tail -1)" = "$zj" ]; then
    ok "zjstatus $zjs needs zellij >= $floor; pinned zellij is $zj"
  else
    bad "zjstatus $zjs needs zellij >= $floor but ZELLIJ_VERSION is $zj — bump zellij, or pin the zjstatus release built for $zj (and its floor)"
  fi
}

check_zellij_plugin_installer() {
  hdr "zellij plugin installer (lib/zellij-plugin.sh lands in zellij's data dir)"
  local out
  # Offline behavioural test: fake \0asm module over file://, scratch HOME.
  # Guards the 2026-09-13 regression — plugin installed to ~/.config/zellij/
  # plugins, which zellij never searches, so every session showed
  # "ERROR IN PLUGIN" while dump-layout looked fine.
  if out=$(bash scripts/test-zellij-plugin.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-zellij-plugin.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}

check_mise_lib() {
  hdr "mise runtimes lib (lib/mise.sh seed / install / sweeps / uninstall)"
  local out
  # Offline behavioural test with a fake `mise` on PATH and a scratch HOME.
  if out=$(bash scripts/test-mise.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-mise.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}

check_python_env_parity() {
  hdr "python-env lib-list parity (python-env.sh == bootstrap.ps1)"
  local sh_libs ps_libs
  sh_libs=$(grep -oE '^PY_LIBS=\([^)]*\)' makefile/lib/python-env.sh |
    sed 's/^PY_LIBS=(//; s/)$//' | tr ' ' '\n' | grep -v '^$' | sort)
  ps_libs=$(grep -oE '^\$PythonLibs *= *@\([^)]*\)' bootstrap.ps1 |
    sed 's/.*@(//; s/)$//' | tr -d '",' | tr ' ' '\n' | grep -v '^$' | sort)
  if [ -n "$sh_libs" ] && [ "$sh_libs" = "$ps_libs" ]; then
    ok "$(printf '%s\n' "$sh_libs" | wc -l) libs match"
  else
    bad "lib-list drift (<:python-env.sh  >:bootstrap.ps1):"
    diff <(printf '%s\n' "$sh_libs") <(printf '%s\n' "$ps_libs") | sed 's/^/       /'
  fi
}

check_curl_helper_parity() {
  hdr "curl helper parity (Invoke-CurlRequest: bootstrap.ps1 == install-nerd-fonts.ps1)"
  local a b
  a=$(awk '/^function Invoke-CurlRequest \{/,/^\}/' bootstrap.ps1)
  b=$(awk '/^function Invoke-CurlRequest \{/,/^\}/' scripts/install-nerd-fonts.ps1)
  if [ -z "$a" ]; then
    bad "Invoke-CurlRequest not found in bootstrap.ps1"
  elif [ -z "$b" ]; then
    bad "Invoke-CurlRequest not found in scripts/install-nerd-fonts.ps1"
  elif [ "$a" = "$b" ]; then
    ok "$(printf '%s\n' "$a" | wc -l)-line helper is byte-identical in both scripts"
  else
    bad "Invoke-CurlRequest drift (<:bootstrap.ps1  >:install-nerd-fonts.ps1):"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/       /'
  fi
}

check_shellcheck() {
  hdr "shellcheck (warning and above)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    note "shellcheck not installed — skipped locally (CI enforces; 'dnf install shellcheck' to run here)"
    return 0
  fi
  # NB: executable_winterop is first-party (shellchecked); executable_batpipe is
  # vendored (eth-p/bat-extras) and deliberately excluded.
  local -a targets=(bootstrap.sh makefile/lib/*.sh scripts/*.sh
    .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh
    chezmoi/private_dot_claude/executable_notify.sh
    chezmoi/dot_local/bin/executable_winterop
    chezmoi/dot_config/bash/completions.bash)
  if shellcheck -x -S warning "${targets[@]}"; then
    ok "clean at warning+ over ${#targets[@]} shell files"
  else
    bad "shellcheck reported warning+ findings (listed above)"
  fi
}

check_shfmt() {
  hdr "shfmt (shell formatting, -i 2)"
  if ! command -v shfmt >/dev/null 2>&1; then
    note "shfmt not installed — skipped locally (CI enforces; 'make fmt MODE=prod' to format here)"
    return 0
  fi
  # Same first-party set as shellcheck (vendored _cht.sh / batpipe excluded).
  local -a targets=(bootstrap.sh makefile/lib/*.sh scripts/*.sh
    .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh
    chezmoi/private_dot_claude/executable_notify.sh
    chezmoi/dot_local/bin/executable_winterop
    chezmoi/dot_config/bash/completions.bash)
  local out
  if out=$(shfmt -d -i 2 "${targets[@]}" 2>&1); then
    ok "clean over ${#targets[@]} shell files (shfmt -i 2)"
  else
    bad "shfmt formatting diffs (fix: make fmt MODE=prod):"
    printf '%s\n' "$out" | sed 's/^/       /' | head -40
  fi
}

check_gitleaks() {
  hdr "gitleaks (committed-secret scan)"
  if ! command -v gitleaks >/dev/null 2>&1; then
    note "gitleaks not installed — skipped locally (CI enforces; 'make secrets MODE=prod' to scan here)"
    return 0
  fi
  local out
  if out=$(gitleaks dir --no-banner --redact -c .gitleaks.toml . 2>&1); then
    ok "no secrets detected (gitleaks dir)"
  else
    bad "gitleaks flagged potential secret(s) (values redacted):"
    printf '%s\n' "$out" | sed 's/^/       /' | head -40
  fi
}

# --- Warp rc guards: correct scope, and never over the plugin chain ----------
# The rc files skip fzf/atuin/starship/shift-select/fzf-tab under Warp
# (TERM_PROGRAM=WarpTerminal) because Warp owns the input editor. Commit
# c9709cf records what happens when such a guard's `fi` is allowed to drift:
# the fzf-tab guard swallowed the whole plugin-load section and silently
# disabled zsh-autosuggestions, zsh-syntax-highlighting, zsh-you-should-use and
# zsh-history-substring-search under Warp. Nothing caught it for months.
#
# The contract this enforces: a Warp guard may only be folded into a
# pre-existing `if` condition, or open a SHORT block; and the four plugin
# sources must never sit inside one. Guard counts are asserted too, so a
# dropped or duplicated guard is a failure rather than a silent behavior change.
check_warp_guards() {
  hdr "Warp TERM_PROGRAM guards (scope + plugin-chain safety)"
  local zsh=chezmoi/dot_zshrc.tmpl bash=chezmoi/dot_bashrc.tmpl
  local n_zsh n_bash out
  n_zsh=$(grep -c 'TERM_PROGRAM:-.* != WarpTerminal' "$zsh" || true)
  n_bash=$(grep -c 'TERM_PROGRAM:-.* != WarpTerminal' "$bash" || true)
  if [ "$n_zsh" -eq 6 ]; then
    ok "dot_zshrc.tmpl: 6 Warp guards (fzf, atuin, starship, shift-select, zstyles, fzf-tab)"
  else
    bad "dot_zshrc.tmpl: $n_zsh Warp guards, want 6 — a guard was added, dropped, or reworded"
  fi
  if [ "$n_bash" -eq 2 ]; then
    ok "dot_bashrc.tmpl: 2 Warp guards (fzf, starship)"
  else
    bad "dot_bashrc.tmpl: $n_bash Warp guards, want 2 — parity pair with dot_zshrc.tmpl"
  fi

  # Depth-track top-level if/fi and report any plugin source loaded while
  # inside a Warp guard. Single-line `if ...; then ...; fi` bodies (the
  # fzf-preview zstyle contains one) never open a block here because the
  # close pattern only matches a line that IS an `fi`.
  out=$(awk '
    /WarpTerminal/ && /;[[:space:]]*then[[:space:]]*$/ { warp[depth+1] = 1 }
    /;[[:space:]]*then[[:space:]]*$/                   { depth++; next }
    /^[[:space:]]*fi([[:space:]]|$)/ { if (depth > 0) { warp[depth] = 0; depth-- } ; next }
    /zsh-autosuggestions\.zsh|zsh-syntax-highlighting\.zsh|you-should-use\.plugin\.zsh|zsh-history-substring-search\.zsh/ {
      for (d = 1; d <= depth; d++)
        if (warp[d]) { printf "line %d inside a Warp guard: %s\n", NR, $0; break }
    }
    END { if (depth != 0) printf "unbalanced if/fi at EOF (depth %d)\n", depth }
  ' "$zsh")
  if [ -z "$out" ]; then
    ok "no plugin source sits inside a Warp guard (c9709cf regression blocked)"
  else
    bad "Warp guard scope regression — a guard's fi has been widened:"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

check_zellij_config() {
  hdr "zellij config (theme dual-edit, OSC 52, KDL parse)"
  local dir=chezmoi/dot_config/zellij
  local cfg="$dir/config.kdl"
  local theme hits bad_hash tmp

  # 1. theme "<name>" in config.kdl must name a theme block in themes/*.kdl.
  #    Nothing upstream catches a dangling name: `zellij setup --check` reports
  #    "Well defined" for a bogus theme and zellij then falls back to its
  #    built-in default at runtime, silently, with the wrong accent colour.
  theme=$(sed -nE 's/^[[:space:]]*theme[[:space:]]+"([^"]+)".*/\1/p' "$cfg" | head -1)
  if [ -z "$theme" ]; then
    bad "$cfg: no theme \"...\" line found"
  elif grep -qE "^[[:space:]]*${theme}[[:space:]]*\{" "$dir"/themes/*.kdl 2>/dev/null; then
    ok "theme \"$theme\" is defined in $dir/themes/"
  else
    bad "theme \"$theme\" in $cfg has no matching block in $dir/themes/*.kdl"
  fi

  # 2. KDL comments are //, never #. A single '#' line invalidates the WHOLE
  #    file and zellij falls back to built-in defaults with no error at all —
  #    theme, keybinds and scroll_buffer_size all dropped silently.
  bad_hash=$(grep -lE '^[[:space:]]*#' "$cfg" "$dir"/layouts/*.kdl "$dir"/themes/*.kdl 2>/dev/null || true)
  if [ -z "$bad_hash" ]; then
    ok "no '#' comment lines in any tracked .kdl (KDL needs //)"
  else
    bad "'#' comment line(s) invalidate these KDL files:"
    printf '%s\n' "$bad_hash" | sed 's/^/       /'
  fi

  # 3. copy_command must stay UNSET — it overrides OSC 52 with a binary that
  #    runs on the REMOTE host, where there is no display. Regressed until
  #    2026-08-31 (ad444df); every yank in a remote session went nowhere.
  hits=$(grep -nE '^[[:space:]]*copy_command' "$cfg" || true)
  if [ -z "$hits" ]; then
    ok "copy_command unset — OSC 52 clipboard path intact (ad444df)"
  else
    bad "$cfg sets copy_command, which kills OSC 52 over SSH:"
    printf '%s\n' "$hits" | sed 's/^/       /'
  fi

  # 4. Web server pinned off. The installed build is web-CAPABLE: tools.mk
  #    excludes the no-web asset, so these are not redundant with upstream.
  if grep -qE '^[[:space:]]*web_server[[:space:]]+false' "$cfg" &&
    grep -qE '^[[:space:]]*web_sharing[[:space:]]+"disabled"' "$cfg"; then
    ok "web_server false + web_sharing \"disabled\" pinned"
  else
    bad "$cfg must pin web_server false AND web_sharing \"disabled\" (build is web-capable)"
  fi

  # 5. The tab-bar alias must point at the RELATIVE plugin path. zellij resolves
  #    `file:<name>.wasm` against its DATA dir, ~/.local/share/zellij/plugins/
  #    (after /usr/share/zellij/plugins; NOT ~/.config/zellij/plugins — that
  #    mistake shipped once, 2026-09-13) — where tools.mk's USER_TOOL zjstatus
  #    installs it — and keeps that relative string as the
  #    plugin's identity, including the ~/.cache/zellij/permissions.kdl key.
  #    An absolute or ~ path expands per host (verified on 0.45.1: "file:~/x"
  #    dumps as "file:/home/<user>/x"), so the one-time permission grant would
  #    stop matching across the fleet and every host would prompt again.
  if grep -qE '^[[:space:]]*tab-bar[[:space:]]+location="file:zjstatus\.wasm"' "$cfg"; then
    ok "tab-bar alias -> file:zjstatus.wasm (relative: host-independent permission key)"
  else
    bad "$cfg: plugins { tab-bar location=\"file:zjstatus.wasm\" ... } missing, or the path is not the relative form"
  fi

  # 6. The zjstatus pills are Nerd Font half-circles, U+E0B6 (left) and U+E0B4
  #    (right), sitting between the style tags. They are invisible in most
  #    editors and were silently dropped once (2026-09-13: the bar shipped as
  #    square colour blocks). Every pill must open and close, so the two
  #    counts must match and be non-zero.
  local lc rc
  lc=$(grep -o $'\xee\x82\xb6' "$cfg" | wc -l)
  rc=$(grep -o $'\xee\x82\xb4' "$cfg" | wc -l)
  if [ "$lc" -gt 0 ] && [ "$lc" -eq "$rc" ]; then
    ok "zjstatus pills: $lc rounded-left (U+E0B6) + $rc rounded-right (U+E0B4) glyphs present"
  else
    bad "$cfg: zjstatus pill glyphs missing or unbalanced (U+E0B6 x$lc, U+E0B4 x$rc) — the bar renders square blocks"
  fi

  # 7. Real parse, when zellij is available. Soft-skip in CI, where it is not
  #    installed — same posture as the other optional-checker skips.
  if command -v zellij >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    # Stage layouts/ and themes/ alongside: default_layout and theme are both
    # resolved relative to the config dir, and a missing dir is a false failure.
    cp "$cfg" "$tmp/" && cp -r "$dir/layouts" "$dir/themes" "$tmp/"
    if ZELLIJ_CONFIG_DIR="$tmp" zellij setup --check 2>&1 | grep -q 'CONFIG FILE.*Well defined'; then
      ok "zellij setup --check: config file well defined"
    else
      bad "zellij setup --check rejected $cfg"
    fi
    rm -rf "$tmp"
  else
    note "zellij not on PATH — skipped the live 'setup --check' parse"
  fi
}

check_update_spec_coverage() {
  hdr "every versions.mk pin is reachable by check-updates"
  local specs pins alias_lines covered missing="" n_pins=0 n_specs=0 var

  # MODE=dev deliberately: the dev-only block in tools.mk registers herdr,
  # opencode and omp, and MODE=prod never defines them. Checking under prod is
  # exactly the bug this guard exists to prevent recurring.
  specs=$(make -s --no-print-directory -C makefile -p MODE=dev 2>/dev/null |
    grep -E '^UPDATE_SPECS :?=' | head -1 | tr ' ' '\n' | grep '|' | cut -d'|' -f1 | sort -u)
  pins=$(grep -oE '^[A-Z][A-Z0-9_]*_VERSION' makefile/versions.mk | sort -u)
  if [ -z "$specs" ] || [ -z "$pins" ]; then
    bad "could not read UPDATE_SPECS or versions.mk pins"
    return
  fi

  # Spec names normally derive to their pin var (uppercase, - => _, +_VERSION).
  # Where they don't, bump-versions.sh's ALIAS map is the single source of truth
  # for the mapping — parse it rather than duplicating the list here.
  alias_lines=$(sed -n 's/^[[:space:]]*\["\([^"]*\)"\]=\([A-Z0-9_]*\).*/\1 \2/p' scripts/bump-versions.sh)

  covered=$(
    while read -r spec; do
      [ -n "$spec" ] || continue
      var=$(printf '%s\n' "$alias_lines" | awk -v s="$spec" '$1 == s {print $2; exit}')
      [ -n "$var" ] || var=$(printf '%s' "$spec" | tr '[:lower:].-' '[:upper:]__')_VERSION
      printf '%s\n' "$var"
    done <<<"$specs" | sort -u
  )

  while read -r pin; do
    [ -n "$pin" ] || continue
    n_pins=$((n_pins + 1))
    grep -qxF "$pin" <<<"$covered" || missing="$missing $pin"
  done <<<"$pins"
  n_specs=$(printf '%s\n' "$specs" | grep -c .)

  if [ -z "$missing" ]; then
    ok "all $n_pins pins covered by $n_specs update specs"
  else
    bad "versions.mk pin(s) with no UPDATE_SPECS entry:${missing} — check-updates emits NO line for these (not even '?') and the weekly bumper inherits the blind spot; add a spec in tools.mk's registry block"
  fi
}

check_go_gopls_coupling() {
  hdr "gopls <-> Go toolchain floor"
  local gov goplsv floor
  gov=$(mkval GO_VERSION)
  goplsv=$(mkval GOPLS_VERSION)
  if [ -z "$gov" ] || [ -z "$goplsv" ]; then
    bad "could not read GO_VERSION / GOPLS_VERSION from versions.mk"
    return
  fi

  # gopls declares its minimum toolchain in its OWN go.mod, and mise's go: backend builds
  # it with `go install` using the PINNED Go (mise-runtimes). A mismatch fails
  # that one tool; the others still install and the stamp stays unwritten, so
  # the host keeps a stale gopls (or none) until the pins agree.
  # Verified both directions on 2026-08-31: gopls 0.23.0 + go 1.24.4 fails with
  # "requires go >= 1.26.0", and gopls 0.23.0 + go 1.27.0 builds under
  # GOTOOLCHAIN=local (i.e. without silently fetching a second toolchain).
  floor=$(curl -fsSL --max-time 15 \
    "https://raw.githubusercontent.com/golang/tools/gopls/v${goplsv}/gopls/go.mod" 2>/dev/null |
    awk '/^go /{print $2; exit}')
  if [ -z "$floor" ]; then
    note "offline or tag missing — skipped the gopls go.mod floor check"
    return
  fi
  if [ "$(printf '%s\n%s\n' "$floor" "$gov" | sort -V | tail -1)" = "$gov" ]; then
    ok "gopls $goplsv needs go >= $floor; pinned go is $gov"
  else
    bad "gopls $goplsv requires go >= $floor but GO_VERSION is $gov — mise-runtimes would fail on gopls, leaving it stale or absent; bump both together"
  fi
}

check_tsls_typescript_coupling() {
  hdr "typescript-language-server <-> typescript major"
  local tsv tslsv major
  tsv=$(mkval TYPESCRIPT_VERSION)
  tslsv=$(mkval TYPESCRIPT_LS_VERSION)
  if [ -z "$tsv" ] || [ -z "$tslsv" ]; then
    bad "could not read TYPESCRIPT_VERSION / TYPESCRIPT_LS_VERSION from versions.mk"
    return
  fi
  # typescript-language-server (every release through 6.0.0) drives
  # typescript/lib/tsserver.js; TypeScript 7.x (the native Go compiler) ships
  # only bin/tsc, so ts-ls fails `initialize` with "Could not find a valid
  # TypeScript installation" (verified 2026-09-13 against 7.0.2). Until a
  # ts-ls release targets TS 7, the pin must stay on the 5.x line — the weekly
  # bumper would otherwise walk it back to 7.x (hence the EXCLUDE entry).
  major=${tsv%%.*}
  if [ "$major" -le 5 ] 2>/dev/null; then
    ok "typescript $tsv (major $major) is tsserver-capable for typescript-language-server $tslsv"
  else
    bad "typescript $tsv has no lib/tsserver.js — typescript-language-server $tslsv cannot initialize; keep the 5.x line until ts-ls supports TS 7"
  fi
}

printf '%s%s== workstation invariant check ==%s\n' "$BOLD" "$BLUE" "$RESET"
check_version_pins
check_bumper_exclude
check_line_endings_and_mode
check_bom
check_sentinels
check_tools_block
check_mise_config
check_lsp_plugin
check_chezmoiignore_targets
check_completion_parity
check_warp_guards
check_zellij_config
check_update_spec_coverage
check_go_gopls_coupling
check_tsls_typescript_coupling
check_zjstatus_zellij_coupling
check_zellij_plugin_installer
check_mise_lib
check_python_env_parity
check_curl_helper_parity
check_shellcheck
check_shfmt
check_gitleaks
echo
if [ "$fails" -eq 0 ]; then
  printf '%s✓ all invariant checks passed%s\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%s✗ %d invariant check(s) failed%s\n' "$RED" "$fails" "$RESET"
  exit 1
fi
