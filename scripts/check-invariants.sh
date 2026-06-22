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
  # (e.g. wezterm.lua's "between HOSTS:START / HOSTS:END" comment) must not count.
  s=$(grep -cE '^[[:space:]]*# CCSTATUSLINE:START[[:space:]]*$' chezmoi/.chezmoiignore.tmpl)
  e=$(grep -cE '^[[:space:]]*# CCSTATUSLINE:END[[:space:]]*$' chezmoi/.chezmoiignore.tmpl)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "chezmoiignore  CCSTATUSLINE:START/END (1/1)"
  else
    bad "chezmoiignore CCSTATUSLINE sentinels START=$s END=$e (want 1/1)"
  fi
  s=$(grep -cE '^[[:space:]]*-- HOSTS:START[[:space:]]*$' chezmoi/dot_config/wezterm/wezterm.lua)
  e=$(grep -cE '^[[:space:]]*-- HOSTS:END[[:space:]]*$' chezmoi/dot_config/wezterm/wezterm.lua)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "wezterm.lua    HOSTS:START/END (1/1)"
  else
    bad "wezterm.lua HOSTS sentinels START=$s END=$e (want 1/1)"
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
    chezmoi/dot_local/bin/executable_winterop)
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
    chezmoi/dot_local/bin/executable_winterop)
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

printf '%s%s== workstation invariant check ==%s\n' "$BOLD" "$BLUE" "$RESET"
check_version_pins
check_line_endings_and_mode
check_bom
check_sentinels
check_tools_block
check_lsp_plugin
check_chezmoiignore_targets
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
