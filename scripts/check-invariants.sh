#!/usr/bin/env bash
# check-invariants.sh — mechanically enforce the load-bearing invariants in CLAUDE.md.
# Run by `mise run lint`, the pre-commit hook and CI; cd's to the repo root. Deliberately
# NOT `set -e`: every check runs and failures are tallied, so guard with conditionals.

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

# Every tracked path's index mode, from one `git ls-files -s`; load_git_modes fills it
# once (call it directly, not in $(...), or the table is lost with the subshell).
declare -A GIT_MODES=()
load_git_modes() {
  [ "${#GIT_MODES[@]}" -eq 0 ] || return 0
  local m f
  while IFS=$'\t' read -r m f; do GIT_MODES["$f"]="${m%% *}"; done < <(git ls-files -s)
}

# First-party shell files for shellcheck, shfmt and `mise run fmt` (vendored scripts excluded).
shell_targets() {
  printf '%s\n' bootstrap.sh scripts/*.sh scripts/lib/*.sh tasks/* \
    .claude/hooks/*.sh dotfiles/claude/hooks/*.sh \
    dotfiles/claude/notify.sh dotfiles/local/bin/winterop \
    dotfiles/config/bash/completions.bash
}

# Python with tomllib (EL9's python3 is 3.9, so prefer wpy); empty when none, and callers soft-skip.
PY=""
for _p in wpy python3; do
  if command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import tomllib' 2>/dev/null; then
    PY="$_p"
    break
  fi
done
[ -n "${CHECK_INVARIANTS_NO_PY:-}" ] && PY="" # test-check-pins.sh
# tomlval <file> <dotted.key> — print a TOML value (or a table's `version`); quoted keys may contain dots.
tomlval() {
  [ -n "$PY" ] || return 1
  "$PY" - "$1" "$2" <<'PY'
import re, sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
for k in re.findall(r'"[^"]+"|[^.]+', sys.argv[2]):
    d = d[k.strip('"')]
print(d["version"] if isinstance(d, dict) else d)
PY
}

# need_py <what> — true with a tomllib python; otherwise notes that <what> is skipped.
need_py() {
  [ -n "$PY" ] && return 0
  note "no python with tomllib — $1 skipped locally (CI enforces)"
  return 1
}

# py_report <what> [arg...] <<'PY' — run the Python check on stdin (args become sys.argv[1:])
# and report each `RESULT|key|detail` line it prints: PASS -> ok, NOTE -> note, else bad.
# A non-zero exit (a traceback) fails too. Without python, notes that <what> is skipped.
py_report() {
  local what="$1" out rc result detail
  shift
  need_py "$what" || return 0
  out=$("$PY" - "$@")
  rc=$?
  while IFS='|' read -r result _ detail; do
    [ -n "$result" ] || continue
    case "$result" in
    PASS) ok "$detail" ;;
    NOTE) note "$detail" ;;
    *) bad "$detail" ;;
    esac
  done <<<"$out"
  [ "$rc" -eq 0 ] || bad "$what: python exited $rc"
}

# _ps1_drive_ref_hits <file> — non-comment lines with an unbraced $name: reference.
# In a double-quoted PowerShell string "$name:" parses as a drive-qualified variable
# and throws, unless the colon is a real scope ($env:, $script:, ...) or the ref is ${name}:.
_ps1_drive_ref_hits() {
  grep -nE '\$[A-Za-z_][A-Za-z0-9_]*:' "$1" |
    grep -vE '\$(env|script|global|local|private|using|variable|function|alias):' |
    grep -vE '^[0-9]+:[[:space:]]*#'
}

# --- pins recorded in more than one place ------------------------------------
# An empty value is drift: a pattern that stops matching must fail, not pass.

# pin_equal <label> <where=value>... — every value non-empty and identical.
pin_equal() {
  local label="$1" kv first names="" shown="" sep="" drift=""
  shift
  first="${1#*=}"
  for kv in "$@"; do
    names="$names$sep${kv%%=*}"
    sep=" == "
    shown="$shown ${kv%%=*}='${kv#*=}'"
    if [ -z "${kv#*=}" ] || [ "${kv#*=}" != "$first" ]; then drift=1; fi
  done
  if [ -z "$drift" ]; then ok "$label @ $first ($names)"; else bad "$label drift:$shown"; fi
}

# _mise_action_versions <workflow>: one line per jdx/mise-action step, the
# `version:` it pins within the next few lines, or an empty line (drift) without one.
_mise_action_versions() {
  awk '
    /uses:[ \t]*jdx\/mise-action/ { if (p) print ""; p = 1; left = 5; next }
    p && /^[ \t]*version:/ { v = $0; sub(/^[ \t]*version:[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v); gsub(/"/, "", v); print v; p = 0; next }
    p && --left == 0 { print ""; p = 0 }
    END { if (p) print "" }' "$1"
}

pin_at_least() {
  if [ -z "$2" ] || [ -z "$3" ]; then
    bad "$1: could not read the version ('$2') or its floor ('$3')"
  elif [ "$(printf '%s\n%s\n' "$3" "$2" | sort -V | tail -1)" = "$2" ]; then
    ok "$1: $2 >= $3"
  else
    bad "$1: $2 is below $3 — $4"
  fi
}

pin_major_at_most() {
  local major="${2%%.*}"
  case "$major" in
  '' | *[!0-9]*) bad "$1: could not read a version ('$2')" ;;
  *) if [ "$major" -le "$3" ]; then ok "$1: $2 (major <= $3)"; else bad "$1: $2 (major $major > $3) — $4"; fi ;;
  esac
}

# pin_bumper_handles <tool>... — each sits in bump-versions.sh's EXCLUDE or
# COUPLED_AUTO; otherwise the weekly bumper rewrites one side of a pair alone.
pin_bumper_handles() {
  local handled t missing=""
  handled=" $(sed -nE 's/^(EXCLUDE|COUPLED_AUTO)="([^"]*)".*/\2/p' scripts/bump-versions.sh | tr '\n' ' ') "
  for t in "$@"; do
    case "$handled" in *" $t "*) ;; *) missing="$missing $t" ;; esac
  done
  if [ -z "$missing" ]; then
    ok "bump-versions.sh skips or pair-bumps all $# coupled pins"
  else
    bad "bump-versions.sh would bump$missing alone — add each to EXCLUDE or COUPLED_AUTO"
  fi
}

# pin_vars_reachable — every config.toml [vars] *_version pin is reported by
# tasks/check-updates (as UPPER_CASE) and listed by scripts/gen-tool-memory.sh.
pin_vars_reachable() {
  local key missing="" n=0
  while read -r key; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    grep -q "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" tasks/check-updates || missing="$missing $key(tasks/check-updates)"
    grep -q "$key" scripts/gen-tool-memory.sh || missing="$missing $key(gen-tool-memory.sh)"
  done < <("$PY" -c 'import tomllib
for k in tomllib.load(open("config.toml","rb")).get("vars",{}):
    print(k) if k.endswith("_version") else None')
  if [ "$n" -eq 0 ]; then missing=" <none found>"; fi
  if [ "$n" -gt 0 ] && [ -z "$missing" ]; then ok "all $n [vars] *_version pin(s) reach check-updates and gen-tool-memory"; else bad "[vars] pin(s) not covered:$missing"; fi
}

check_pins() {
  hdr "pins recorded in more than one place"
  local want='$HOME/.local/share/vcpkg'
  pin_equal "VCPKG_ROOT" "want=$want" \
    "zshrc.tera=$(sed -nE 's/.*VCPKG_ROOT="([^"]*)".*/\1/p' dotfiles/zshrc.tera | head -1)" \
    "bashrc.tera=$(sed -nE 's/.*VCPKG_ROOT="([^"]*)".*/\1/p' dotfiles/bashrc.tera | head -1)" \
    "tasks/vcpkg=$(sed -nE 's/.*vroot="([^"]*)".*/\1/p' tasks/vcpkg | head -1)"
  # TypeScript 7 ships only bin/tsc, no lib/tsserver.js, so typescript-language-server can't start.
  pin_major_at_most "typescript (tsserver for typescript-language-server)" \
    "$(grep -E '^node = ' config.toml | grep -oE 'typescript@[0-9.]+' | cut -d@ -f2)" 5 \
    "keep the 5.x line"
  if grep -E '^node = ' config.toml | grep -q 'typescript-language-server@'; then
    ok "typescript-language-server is in node's postinstall"
  else
    bad "typescript-language-server@ missing from node's postinstall in config.toml"
  fi
  # Pins the bumper must skip or bump as a pair: zjstatus (its zellij floor), ncdu (URL
  # 404s on some releases), go + gopls, node (its postinstall pins the LSP servers).
  pin_bumper_handles github:dj95/zjstatus http:ncdu go go:golang.org/x/tools/gopls node
  if [ -z "$PY" ]; then
    note "no python with tomllib — the TOML rows are skipped locally (CI enforces)"
    return
  fi
  # CI runs the same mise: every jdx/mise-action step pins it with `version:`.
  local wf v i
  local -a ci_pins=()
  for wf in .github/workflows/*.yml; do
    i=0
    while IFS= read -r v; do
      i=$((i + 1))
      ci_pins+=("${wf##*/}#$i=$v")
    done < <(_mise_action_versions "$wf")
  done
  pin_equal "mise" \
    "bootstrap.sh=$(sed -nE 's/^MISE_VERSION="([0-9.]+)".*/\1/p' bootstrap.sh)" \
    "bootstrap.ps1=$(sed -nE 's/^\$MiseVersion *= *"([0-9.]+)".*/\1/p' bootstrap.ps1 | head -1)" \
    "config.toml min_version=$(tomlval config.toml min_version 2>/dev/null)" \
    "${ci_pins[@]}"
  # zjstatus states the zellij it needs in prose release notes; the floor sits next to the pin.
  # A mismatch fails silently at runtime (the bar pane doesn't render) and
  # `zellij setup --check` still reports "Well defined".
  if [ -n "$(tomlval config.linux.toml 'tools."github:dj95/zjstatus"' 2>/dev/null)" ]; then
    ok "zjstatus pin readable"
  else
    bad "zjstatus pin unreadable in config.linux.toml (tools.\"github:dj95/zjstatus\")"
  fi
  pin_at_least "zellij for zjstatus" "$(tomlval config.linux.toml tools.zellij 2>/dev/null)" \
    "$(tomlval config.toml vars.zjstatus_zellij_floor 2>/dev/null)" \
    "bump zellij, or pin the zjstatus release built for it (and its floor)"
  pin_vars_reachable
}

check_line_endings_and_mode() {
  hdr "line-endings (LF) + git mode (100755)"
  local f mode crlf=0 modebad=0 missing=0
  local -a files=(scripts/*.sh scripts/lib/*.sh tasks/* .claude/hooks/*.sh dotfiles/local/bin/*)
  load_git_modes
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
    mode="${GIT_MODES["$f"]:-}"
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

# The converse of check_line_endings_and_mode: dotfile SOURCES are git mode 100644 except
# this hand-kept allowlist, because copy/template propagate the exec bit onto $HOME (a 0744
# DrvFs checkout would chmod +x every managed dotfile).
DOTFILES_MODE_ALLOWLIST=(
  "dotfiles/claude/hooks/dangerous-command-guard.sh" # ~/.claude/hooks copy entry — a Claude Code hook script
  "dotfiles/claude/hooks/secret-guard.sh"            # ~/.claude/hooks copy entry — a Claude Code hook script
  "dotfiles/claude/notify.sh"                        # ~/.claude/notify.sh copy entry — invoked directly as a hook command
  "dotfiles/local/bin/batpipe"                       # ~/.local/bin copy entry — a LESSOPEN preprocessor invoked directly
  "dotfiles/local/bin/winterop"                      # ~/.local/bin copy entry — a script invoked directly from the shell
)
check_dotfiles_mode() {
  hdr "dotfiles/ sources: git mode 100644 except the allowlist"
  local f a mode bad_count=0 n=0 allowed
  local -a tracked
  mapfile -t tracked < <(git ls-files dotfiles/)
  load_git_modes
  for f in "${tracked[@]}"; do
    n=$((n + 1))
    mode="${GIT_MODES["$f"]:-}"
    allowed=0
    for a in "${DOTFILES_MODE_ALLOWLIST[@]}"; do
      [ "$f" = "$a" ] && {
        allowed=1
        break
      }
    done
    if [ "$allowed" -eq 1 ]; then
      if [ "$mode" != "100755" ]; then
        bad "allowlisted as executable but git mode is $mode, want 100755: $f"
        bad_count=$((bad_count + 1))
      fi
    elif [ "$mode" != "100644" ]; then
      bad "git mode $mode, want 100644 (not in the executable allowlist): $f"
      bad_count=$((bad_count + 1))
      case "$f" in
      *.tera) bad "  ^ a .tera TEMPLATE source — its executable bit propagates straight into \$HOME on the next apply" ;;
      esac
    fi
  done
  [ "$bad_count" -eq 0 ] && ok "$n tracked dotfiles/ sources, ${#DOTFILES_MODE_ALLOWLIST[@]} allowlisted executable"
}

check_bom() {
  hdr "UTF-8 BOM on PowerShell files"
  local f b allgood=1
  local -a files=(bootstrap.ps1 scripts/install-nerd-fonts.ps1)
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

check_ps_variable_drive_refs() {
  hdr "PowerShell \$name: drive-lookalike refs (parse trap in double-quoted strings)"
  local f line allgood=1 n=0
  local -a files
  mapfile -t files < <(git ls-files '*.ps1')
  for f in "${files[@]}"; do
    n=$((n + 1))
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      allgood=0
      bad "$f:$line"
    done < <(_ps1_drive_ref_hits "$f")
  done
  [ "$allgood" -eq 1 ] && ok "no unbraced \$name: drive-lookalike refs in $n tracked .ps1 files"
}

# A bare a,b among a command's arguments is a PowerShell array. A native exe gets
# "a,b", but `mise` is a function under `mise activate pwsh`, which splats it as two
# arguments: `mise bootstrap --only dotfiles,tools` ran `--only dotfiles tools`.
# Quoted strings, comments and here-string bodies don't count.
_ps1_comma_list_hits() {
  awk -v q="'" '
    hs { if ($0 ~ "^[\"" q "]@") hs = 0; next }
    $0 ~ "@[\"" q "][ \t]*$" { hs = 1 }
    /^[ \t]*#/ { next }
    {
      l = $0
      gsub(/"[^"]*"/, "", l)
      gsub(q "[^" q "]*" q, "", l)
      sub(/#.*/, "", l)
      if (l ~ /(^|[ \t;{(&|])mise[ \t]/ && l ~ /[ \t][A-Za-z0-9_.-]+,[A-Za-z0-9_.-]+([ \t;})|]|$)/) print FNR ":" $0
    }' "$1"
}

check_ps_mise_comma_lists() {
  hdr "PowerShell: comma lists passed to mise are quoted (the mise function splits a bare a,b)"
  local f line allgood=1 n=0
  local -a files
  mapfile -t files < <(git ls-files '*.ps1' '*.ps1.tera')
  for f in "${files[@]}"; do
    n=$((n + 1))
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      allgood=0
      bad "$f:$line (quote the list: 'a,b')"
    done < <(_ps1_comma_list_hits "$f")
  done
  [ "$allgood" -eq 1 ] && ok "no bare a,b argument to mise in $n tracked PowerShell files"
}

check_sentinels() {
  hdr "sentinel blocks matched"
  local s e
  # Anchor to a whole marker line: prose that merely mentions the token must not count.
  # The per-host CCSTATUSLINE-OPTOUT block lives in git-ignored config.local.toml: nothing tracked to assert.
  s=$(grep -cE '<!-- TOOLS:START' dotfiles/claude/CLAUDE.md)
  e=$(grep -cE '<!-- TOOLS:END -->' dotfiles/claude/CLAUDE.md)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "machine-memory  TOOLS:START/END (1/1)"
  else
    bad "machine-memory TOOLS sentinels START=$s END=$e (want 1/1)"
  fi
}

check_tools_block() {
  hdr "machine-memory TOOLS block in sync"
  local mem="dotfiles/claude/CLAUDE.md" tmp
  if [ ! -f "$mem" ]; then
    bad "missing: $mem"
    return
  fi
  need_py "TOOLS block drift check" || return
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

check_mise_config_files() {
  hdr "mise config*.toml parse + lockfile coverage + min_version"
  local f
  for f in config.toml config.linux.toml mise.lock mise.linux.lock; do
    [ -f "$f" ] || {
      bad "missing: $f"
      return
    }
  done
  local hint
  hint="run: mise lock --global (from OUTSIDE the checkout with XDG_CONFIG_HOME pointing at a dir whose mise/ is a symlink to it — see scripts/bump-versions.sh)"
  # One pass over the lock files: [tools] coverage and pins, then the pypi:/npm: sidecars.
  py_report "lock coverage and pypi:/npm: sidecar checks" "$hint" <<'PY'
import tomllib, sys

def load(f):
    with open(f, "rb") as fh:
        return tomllib.load(fh)

lockmap = {"config.toml": "mise.lock", "config.linux.toml": "mise.linux.lock"}
locks = {lf: load(lf).get("tools", {}) for lf in lockmap.values()}
missing = []
for f, need_win in (("config.toml", True), ("config.linux.toml", False)):
    ltools = locks[lockmap[f]]
    for name, spec in load(f).get("tools", {}).items():
        short = name.split(":", 1)[1] if ":" in name and not name.startswith(("go:", "pypi:", "pipx:", "npm:", "http:")) else name
        entries = ltools.get(name) or ltools.get(short)
        if not entries:
            missing.append(f"{f}:{name} (no lock entry)")
            continue
        plats = set()
        for e in entries if isinstance(entries, list) else [entries]:
            plats |= {k.split(".", 1)[1] for k in e if k.startswith("platforms.")}
        linux_only = isinstance(spec, dict) and spec.get("os") == ["linux"]
        no_platform_backend = name.startswith(("go:", "npm:", "pypi:", "pipx:"))
        if not no_platform_backend and "linux-x64" not in plats:
            missing.append(f"{f}:{name} (no linux-x64 lock)")
        if not linux_only and need_win and not no_platform_backend and "windows-x64" not in plats:
            missing.append(f"{f}:{name} (no windows-x64 lock)")
        # pin<->lock equality: a pin bumped without `mise lock` leaves a stale lock entry
        # that every host rewrites on install. "latest" is skipped; any matching block counts.
        pin = spec.get("version") if isinstance(spec, dict) else spec
        if pin and pin != "latest":
            blocks = entries if isinstance(entries, list) else [entries]
            lock_vers = sorted({e.get("version") for e in blocks})
            if pin not in lock_vers:
                missing.append(f"{f}:{name} pin {pin} != lock {','.join(str(v) for v in lock_vers)}")
if missing:
    items = "; ".join(missing)
    print(f"FAIL|coverage|a config*.toml lock is missing entries ({items}) — run: MISE_ENV=linux mise lock --global --platform linux-x64 && MISE_ENV=windows mise lock --global --platform windows-x64")
else:
    print("PASS|coverage|every [tools] entry has a lock entry (linux-x64; windows-x64 where it installs on Windows)")

# Every pypi:/npm: lock entry needs its dependency-lock sidecar ref: `mise lock` only
# warns when uv < 0.12.10, and the next install then dirties the tracked checkout.
no_sidecar = []
for lf, tools in locks.items():
    for name, entries in tools.items():
        key = {"pypi": "uv", "npm": "aube"}.get(name.split(":", 1)[0])
        if not key:
            continue
        for e in entries if isinstance(entries, list) else [entries]:
            if not isinstance(e.get(key), dict) or "path" not in e[key]:
                no_sidecar.append(f"FAIL|sidecar|{lf}: {name}@{e.get('version')} has no {key} dependency lock — install uv (pypi:) then re-run: {sys.argv[1]}")
print("\n".join(no_sidecar) or "PASS|sidecar|every pypi:/npm: lock entry carries its dependency-lock sidecar")
PY
  if command -v mise >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp -d)"
    ln -s "$PWD" "$tmp/mise"
    if XDG_CONFIG_HOME="$tmp" MISE_ENV=linux mise config ls >/dev/null 2>&1 &&
      env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$tmp" mise tasks validate >/dev/null 2>&1; then
      ok "mise loads the config files and validates tasks/"
    else
      bad "mise config ls / tasks validate failed against this checkout"
    fi
    rm -rf "$tmp"
  else
    note "mise not installed — config load check skipped"
  fi
  # mise reads every task-file line that starts `# MISE` or `# USAGE` (any
  # spacing, any suffix) as a directive, so a wrapped comment such as
  # "# MISE_ENV would ..." breaks the task's parse with a WARN on each `mise run`.
  local stray
  stray=$(grep -nHE '^[[:space:]]*(#|//)[[:space:]]*(MISE|USAGE)' tasks/* 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:#(MISE [a-z_]+=|USAGE )' || true)
  if [ -z "$stray" ]; then
    ok "tasks/*: every line starting #MISE/#USAGE is a real directive"
  else
    bad "tasks/* comment lines mise parses as directives (reword so they don't start with MISE/USAGE):"
    printf '%s\n' "$stray" | sed 's/^/       /'
  fi
  # locks/** sidecar layout: a stale .mise/locks/** ref dirties every host's checkout
  # on its next install, which rewrites it to locks/ in place.
  local lock_ok=1 pathref
  while IFS= read -r pathref; do
    [ -n "$pathref" ] || continue
    case "$pathref" in
    locks/*)
      if [ ! -d "$pathref" ]; then
        bad "lock sidecar dir missing: $pathref — $hint"
        lock_ok=0
      fi
      ;;
    *)
      bad "lock sidecar path ref not under locks/: $pathref — $hint"
      lock_ok=0
      ;;
    esac
  done < <(grep -ho 'path = "[^"]*"' mise.lock mise.linux.lock 2>/dev/null | sed -E 's/^path = "(.*)"$/\1/')
  if [ "$lock_ok" -eq 1 ]; then
    ok "every lock sidecar path ref is under locks/ and the directory exists"
  fi
  # ...and the converse: a sidecar dir no lock refers to (scripts/bump-versions.sh prunes them).
  local orphans
  orphans=$(bash scripts/lib/lock-sidecar-orphans.sh "$ROOT")
  if [ -z "$orphans" ]; then
    ok "every locks/ sidecar dir is referenced by a lock"
  else
    bad "locks/ sidecar dirs no lock refers to (a bump left them; delete them): $(tr '\n' ' ' <<<"$orphans")"
  fi
}

# Bootstrap-config invariants over the [bootstrap.*] files; the last check is a live `mise bootstrap
# plan`, skipped unless mise and dnf exist (CI has no dnf).
check_bootstrap_config() {
  hdr "bootstrap-config invariants ([bootstrap.*] across config.toml/linux/windows.toml)"
  py_report "bootstrap-config checks" <<'PY'
import os, re, tomllib

# config.toml loads on every host, config.linux.toml on Linux, config.windows.toml on Windows.
loaded = {}
for f in ("config.toml", "config.linux.toml", "config.windows.toml"):
    try:
        with open(f, "rb") as fh:
            loaded[f] = tomllib.load(fh)
        print(f"PASS|parse|{f} parses")
    except Exception as e:
        print(f"FAIL|parse|{f} failed to parse: {e}")


def boot(f):
    return loaded.get(f, {}).get("bootstrap", {})


# Hooks: `mise run <task>[ ::: <task>]`, each task existing; mise runs a name from every loaded file.
hook_re = re.compile(r"^mise run [a-z-]+( ::: [a-z-]+)*$")
toml_tasks = {t for d in loaded.values() for t in d.get("tasks", {})}
# post-dotfiles is the raw chmod line restoring ~/.ssh and ~/.claude modes, pinned to an
# exact literal: mise runs hooks as `sh -o errexit`, so each command needs its own `|| true`
# (where ~/.claude doesn't exist yet the first chmod would abort the bootstrap).
EXPECTED_POST_DOTFILES_HOOK = (
    "chmod 700 ~/.ssh ~/.claude 2>/dev/null || true; "
    "chmod 600 ~/.ssh/config 2>/dev/null || true; "
    "chmod 600 ~/.config/mise/dotfiles/ssh/config.tera 2>/dev/null || true"
)
bad_hooks = []
n_hooks = 0
for f, d in loaded.items():
    for name, val in d.get("bootstrap", {}).get("hooks", {}).items():
        n_hooks += 1
        if name == "post-dotfiles":
            if val != EXPECTED_POST_DOTFILES_HOOK:
                bad_hooks.append(f"{f}:post-dotfiles != the verified-safe literal (got {val!r})")
            continue
        if not hook_re.match(val):
            bad_hooks.append(f"{f}:{name}={val!r} (want 'mise run <task>')")
            continue
        for task in val.split("mise run ", 1)[1].split(" ::: "):
            if not (os.path.isfile(os.path.join("tasks", task)) or task in toml_tasks):
                bad_hooks.append(f"{f}:{name} -> task {task} is neither tasks/{task} nor a [tasks.{task}] table")
if bad_hooks:
    print("FAIL|hooks|" + "; ".join(bad_hooks))
else:
    print(f"PASS|hooks|{n_hooks} hook(s) run existing tasks or are the pinned post-dotfiles literal")

bad_files = []
n_files = 0
for f, d in loaded.items():
    for path, spec in d.get("bootstrap", {}).get("files", {}).items():
        n_files += 1
        src = spec.get("source")
        if not src or not os.path.isfile(src):
            bad_files.append(f"{f}:{path} source missing: {src}")
        phase = spec.get("phase")
        if phase is not None and phase not in ("pre-packages", "post-packages"):
            bad_files.append(f"{f}:{path} phase={phase!r} (want pre-packages/post-packages)")
if bad_files:
    print("FAIL|files|" + "; ".join(bad_files))
else:
    print(f"PASS|files|{n_files} bootstrap.files entry/ies: source exists, phase valid")

# dnf installs config.linux.toml's packages in one batch, so a name EL8 or EL9 can't resolve
# fails the whole run. Names known to be wrong, and why:
dropped = {
    "dnf:fswatch": "not packaged for EL",
    "dnf:entr": "not packaged for EL",
    "dnf:shellcheck": "the package is ShellCheck",
    "dnf:cockpit-networkmanager": "a virtual provide: `rpm -q` never sees it installed, so it drifts forever",
    "dnf:python3": "no package of that name on EL8 (python36 provides it), so it drifts forever; python3-pip brings the interpreter",
}
pkgs = boot("config.linux.toml").get("packages", {})
bad_pkg = [f"config.linux.toml:{k} (missing dnf: prefix)" for k in pkgs if not k.startswith("dnf:")]
bad_pkg += [f"config.linux.toml:{k} ({dropped[k]})" for k in pkgs if k in dropped]
if bad_pkg:
    print("FAIL|packages|" + "; ".join(bad_pkg))
else:
    print(f"PASS|packages|{len(pkgs)} dnf: package key(s) in config.linux.toml, no dropped names")

# winget GUI apps are Windows-only, so they live in config.windows.toml alone; SSHFS-Win
# stays in bootstrap.ps1 (mise installs silently, and its WinFsp MSI must raise UAC).
win_hits = []
n_winget = 0
for f, d in loaded.items():
    for key, val in d.get("bootstrap", {}).get("packages", {}).items():
        if f == "config.windows.toml":
            if not key.startswith("winget:"):
                win_hits.append(f"{f}:{key} (only winget: packages belong here)")
                continue
            n_winget += 1
            if key.lower() == "winget:sshfs-win.sshfs-win":
                win_hits.append(f"{f}:{key} (SSHFS-Win must raise UAC; it stays in bootstrap.ps1's Install-SshfsWin)")
            if val != "latest":
                win_hits.append(f"{f}:{key} = {val!r} (want \"latest\": the apps self-update)")
        elif key.startswith("winget:"):
            win_hits.append(f"{f}:{key} (winget: packages belong in config.windows.toml)")
if win_hits:
    print("FAIL|winget|" + "; ".join(win_hits))
elif n_winget == 0:
    print("FAIL|winget|config.windows.toml declares no winget: packages")
else:
    print(f"PASS|winget|{n_winget} winget: GUI app(s), all in config.windows.toml, \"latest\", SSHFS-Win not among them")

# System state sits in the OS file that applies it: config.toml loads on both OSes, and
# /etc files are Linux host state (skipped with `--skip packages,files` without sudo).
placement = []
if "bootstrap" in loaded.get("config.toml", {}):
    placement.append("config.toml has a [bootstrap] table (every host loads it; system state lives in the OS files)")
if boot("config.windows.toml").get("files"):
    placement.append("config.windows.toml has [bootstrap.files] (/etc files belong in config.linux.toml)")
if placement:
    print("FAIL|placement|" + "; ".join(placement))
else:
    print("PASS|placement|config.toml carries no [bootstrap] table; [bootstrap.files] only in config.linux.toml")

# Each OS's mise rewrites the other OS's lock entries for tools with per-platform
# options (Windows reorders them, Linux drops them), which dirties the checkout and
# breaks wsu's `git pull --ff-only`. config.toml sets [settings] locked = true for every
# host (installs read the lock files, never write them; `mise lock` still writes).
lock_hits = []
for f, d in loaded.items():
    settings = d.get("settings", {})
    if f == "config.toml":
        if settings.get("locked") is not True:
            lock_hits.append("config.toml must set [settings] locked = true (installs would rewrite the lock files and dirty the checkout)")
    elif "locked" in settings:
        lock_hits.append(f"{f} sets [settings] locked (it belongs in config.toml, for every host)")
if lock_hits:
    print("FAIL|locked|" + "; ".join(lock_hits))
else:
    print("PASS|locked|config.toml sets [settings] locked = true; no other config sets it")

ruling_hits = []
for f, d in loaded.items():
    bs = d.get("bootstrap", {})
    if "user" in bs:
        ruling_hits.append(f"{f} has [bootstrap.user] (chsh needs util-linux-user + prompts for a password)")
    linux = bs.get("linux", {})
    if isinstance(linux, dict) and "firewall" in linux:
        ruling_hits.append(f"{f} has [bootstrap.linux.firewall] (aborts unprivileged mise bootstrap plan/status)")
if ruling_hits:
    print("FAIL|rulings|" + "; ".join(ruling_hits))
else:
    print("PASS|rulings|no [bootstrap.linux.firewall] or [bootstrap.user] table (plan/status would need sudo; login_shell needs chsh)")
PY

  if command -v mise >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    if MISE_ENV=linux mise bootstrap plan --json >/dev/null 2>&1; then
      ok "mise bootstrap plan --json (MISE_ENV=linux) exits 0"
    else
      bad "mise bootstrap plan --json (MISE_ENV=linux) failed"
    fi
  else
    note "mise and/or dnf not on PATH — skipped the live 'mise bootstrap plan' check (CI has no dnf)"
  fi
}

check_dotfiles_config() {
  hdr "dotfiles-config invariants (config.toml/linux/windows.toml [dotfiles])"
  py_report "dotfiles-config checks" <<'PY'
import glob, os, tomllib

# config.local.toml (git-ignored) is excluded: it exists to REPEAT a key from these files.
# config.linux.toml holds the Linux-only gdb/herdr/zed entries.
files = ["config.toml", "config.linux.toml", "config.windows.toml"]
loaded = {}
for f in files:
    try:
        with open(f, "rb") as fh:
            loaded[f] = tomllib.load(fh)
        print(f"PASS|parse|{f} parses")
    except FileNotFoundError:
        print(f"FAIL|parse|{f} missing")
    except Exception as e:
        print(f"FAIL|parse|{f} failed to parse: {e}")

VALID_MODES = {"symlink", "symlink-each", "copy", "template", "track"}
entries = []  # (file, target, spec): whole-file entries
edits = []    # (file, "<target>/<id>", spec): line / block edits inside a file mise doesn't own
for f, d in loaded.items():
    for target, spec in d.get("dotfiles", {}).items():
        if isinstance(spec, str):
            spec = {"source": spec, "mode": "symlink"}
        if "line" in spec or "block" in spec or ("template" in spec and "mode" not in spec):
            edits.append((f, target, spec))
        else:
            entries.append((f, target, spec))

# Edit entries: mise 2026.9.9 has line and block (block content inline or from a
# `source` with template = "tera"). It has no `merge`: such an entry silently becomes a
# whole-file symlink of its source, so it is refused here.
bad_edit = []
for f, d in loaded.items():
    for target, spec in d.get("dotfiles", {}).items():
        if isinstance(spec, dict) and "merge" in spec:
            bad_edit.append(f"{f}:{target} uses merge (unsupported by the pinned mise: it becomes a whole-file symlink)")
for f, target, spec in edits:
    src = spec.get("source")
    if src is not None:
        if spec.get("template") != "tera":
            bad_edit.append(f"{f}:{target} has a source without template = \"tera\"")
        elif not os.path.exists(src):
            bad_edit.append(f"{f}:{target} source missing: {src}")
    elif "line" not in spec and "block" not in spec:
        bad_edit.append(f"{f}:{target} is an edit with no line, block or source")
if bad_edit:
    print("FAIL|edits|" + "; ".join(bad_edit))
else:
    print(f"PASS|edits|{len(edits)} line/block edit entries, every source present, no merge")

bad_src = []
for f, target, spec in entries:
    src = spec.get("source")
    if src is None:
        bad_src.append(f"{f}:{target} has no source")
    elif not os.path.exists(src):
        bad_src.append(f"{f}:{target} source missing: {src}")
if bad_src:
    print("FAIL|source-exists|" + "; ".join(bad_src))
else:
    print(f"PASS|source-exists|{len(entries)} entries, every source exists")

bad_mode = []
for f, target, spec in entries:
    mode = spec.get("mode")
    if mode not in VALID_MODES:
        bad_mode.append(f"{f}:{target} mode={mode!r} (want one of {sorted(VALID_MODES)})")
if bad_mode:
    print("FAIL|mode-valid|" + "; ".join(bad_mode))
else:
    print(f"PASS|mode-valid|every entry's mode is one of {sorted(VALID_MODES)}")

# No entry is `symlink` or `symlink-each`: every entry is `copy` or `template`
# (Windows symlinks need Developer Mode; a directory symlink becomes a junction).
bad_symlink = []
n_total = 0
for f, target, spec in entries:
    n_total += 1
    mode = spec.get("mode", "symlink")
    if mode in ("symlink", "symlink-each"):
        bad_symlink.append(f"{f}:{target} mode={mode!r} (want copy or template — symlink/symlink-each are retired everywhere)")
if bad_symlink:
    print("FAIL|no-symlink-anywhere|" + "; ".join(bad_symlink))
else:
    print(f"PASS|no-symlink-anywhere|{n_total} entries across all {len(files)} config files are copy or template, none symlink/symlink-each")

# Every directory entry that declares `exclude` covers each .vendor/.gitkeep
# sidecar actually present there.
bad_exclude = []
n_each = 0
for f, target, spec in entries:
    if "exclude" not in spec:
        continue
    n_each += 1
    src = spec.get("source")
    exclude = set(spec.get("exclude", []))
    if not src or not os.path.isdir(src):
        continue
    sidecars = {name for name in (".vendor", ".gitkeep") if os.path.exists(os.path.join(src, name))}
    missing = sidecars - exclude
    if missing:
        bad_exclude.append(f"{f}:{target} source has {sorted(missing)} but exclude={sorted(exclude)}")
if bad_exclude:
    print("FAIL|dir-copy-exclude|" + "; ".join(bad_exclude))
else:
    print(f"PASS|dir-copy-exclude|{n_each} directory entries with an exclude list cover every .vendor/.gitkeep sidecar in their source")

seen = {}
for f, target, _spec in entries:
    seen.setdefault(target, []).append(f)
dupes = [f"{t} in {fs}" for t, fs in seen.items() if len(fs) > 1]
if dupes:
    print("FAIL|no-dupes|target(s) declared in more than one config file: " + "; ".join(dupes))
else:
    print(f"PASS|no-dupes|{len(seen)} distinct target(s), none declared in more than one config file")

tera_files = set(glob.glob("dotfiles/**/*.tera", recursive=True))
tera_refs = {}
for f, target, spec in entries:
    src = spec.get("source")
    if src and src.endswith(".tera"):
        tera_refs.setdefault(src, []).append((f, target))
bad_tera = []
for src in sorted(tera_files):
    refs = tera_refs.get(src, [])
    if len(refs) == 0:
        bad_tera.append(f"{src} is an orphan (no [dotfiles] entry references it)")
    elif len(refs) > 1:
        bad_tera.append(f"{src} is referenced by {len(refs)} entries: {refs}")
for src in sorted(set(tera_refs) - tera_files):
    bad_tera.append(f"{src} referenced by an entry but not found under dotfiles/**/*.tera")
if bad_tera:
    print("FAIL|tera-coverage|" + "; ".join(bad_tera))
else:
    print(f"PASS|tera-coverage|{len(tera_files)} dotfiles/**/*.tera file(s), each referenced by exactly one entry")
PY
}

check_lsp_plugin() {
  hdr "workstation-lsp plugin manifest"
  local src="dotfiles/claude/skills/workstation-lsp"
  # Both leading dots are load-bearing: Claude Code needs .claude-plugin/plugin.json and
  # the LSP registry needs .lsp.json, which deploy as spelled under the ~/.claude/skills copy entry.
  if [ ! -f "$src/.claude-plugin/plugin.json" ] || [ ! -f "$src/.lsp.json" ]; then
    bad "missing workstation-lsp plugin source ($src/.claude-plugin/plugin.json + .lsp.json)"
    return
  fi
  if ! command -v claude >/dev/null 2>&1; then
    note "claude not installed — skipped LSP plugin validate (hosts with claude enforce; CI has no claude)"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude-plugin"
  cp "$src/.claude-plugin/plugin.json" "$tmp/.claude-plugin/plugin.json"
  cp "$src/.lsp.json" "$tmp/.lsp.json"
  [ -f "$src/SKILL.md" ] && cp "$src/SKILL.md" "$tmp/SKILL.md"
  if claude plugin validate "$tmp" --strict >/dev/null 2>&1; then
    ok "workstation-lsp manifest validates (claude plugin validate --strict)"
  else
    bad "workstation-lsp manifest failed claude plugin validate --strict:"
    claude plugin validate "$tmp" --strict 2>&1 | sed 's/^/       /' | head -20
  fi
  rm -rf "$tmp"
}

# --- flag-parity: repo-script flags == completion-surface flags --------------
# Three pairs: bootstrap.sh's long flags against its zsh and bash completions, and
# bootstrap.ps1's parameters against config.nu's flag record.

# Long flags a bash script accepts from its case arms.
_sh_script_flags() {
  grep -E '^[[:space:]]*-{1,2}[A-Za-z-]+([[:space:]]*\|[[:space:]]*-{1,2}[A-Za-z-]+)*\)' "$1" |
    grep -oE -- '--[a-z-]+' | sort -u
}

_ps_script_flags() {
  awk '/^param\(/{f=1} f{print} f&&/^\)/{exit}' "$1" |
    grep -oE '\[(switch|string)\]\$[A-Za-z]+' | sed 's/.*\$/-/' | sort -u
}

# --flag tokens from a zsh completion file (full-line comments stripped; they may name excluded flags).
_zsh_completion_flags() {
  grep -v '^#' "$1" | grep -oE -- '--[a-z-]+' | sort -u
}

_bash_completion_flags() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" {f=1} f{print} f&&/^}/{exit}' \
    dotfiles/config/bash/completions.bash |
    grep -oE -- '--[a-z-]+' | sort -u
}

_nu_completion_flags() {
  awk -v v="$1" '$0 ~ "^let "v {f=1} f{print} f&&/^\]/{exit}' \
    dotfiles/windows/AppData/Roaming/nushell/config.nu.tera |
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

  want=$(_sh_script_flags bootstrap.sh)
  _flags_eq "bootstrap.sh == _bootstrap.sh (zsh)" "$want" \
    "$(_zsh_completion_flags dotfiles/config/zsh/completions/_bootstrap.sh)"
  _flags_eq "bootstrap.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_bootstrap)"

  want=$(_ps_script_flags bootstrap.ps1)
  _flags_eq "bootstrap.ps1 == config.nu (nushell)" "$want" \
    "$(_nu_completion_flags workstation_bootstrap_flags)"
}

# One setup per OS: exactly three tracked config files, and the token set is the OS
# alone (scripts/lib/mise-env.sh prints `linux`, bootstrap.ps1 writes `windows`).
check_layout() {
  hdr "layout (three config files, OS-only token sets)"
  local files tokens
  files=$(git ls-files 'config*.toml' | paste -sd' ' -)
  tokens=$(bash scripts/lib/mise-env.sh 2>/dev/null)
  if [ "$files" != "config.linux.toml config.toml config.windows.toml" ]; then
    bad "tracked config files are \"$files\" (want config.toml, config.linux.toml, config.windows.toml; per-host settings go in the git-ignored config.local.toml)"
  elif [ "$tokens" != linux ]; then
    bad "scripts/lib/mise-env.sh prints \"$tokens\" (want linux)"
  elif ! grep -qF 'env = [`"windows`"]' bootstrap.ps1; then
    bad "bootstrap.ps1 no longer writes miserc.toml's env = [\"windows\"]"
  else
    ok "config.toml + config.linux.toml + config.windows.toml; tokens linux / windows"
  fi
}

# disk-budget.toml is generated by .github/workflows/disk-budget.yml and read with
# a regex by the free-space checks (scripts/lib/mise-install.sh, bootstrap.ps1):
# exactly one `<os> = <MB>` line per OS, each a positive number.
check_disk_budget() {
  hdr "disk-budget.toml (generated by disk-budget.yml; read by the free-space checks)"
  local k v allgood=1
  if [ ! -f disk-budget.toml ]; then
    bad "disk-budget.toml missing — regenerate it: gh workflow run disk-budget.yml"
    return
  fi
  for k in linux windows; do
    v=$(sed -n "s/^$k = \([0-9][0-9]*\)\$/\1/p" disk-budget.toml)
    if [ "$(grep -c "^$k *=" disk-budget.toml)" != 1 ] || [ -z "$v" ] || [ "$v" -le 0 ]; then
      bad "disk-budget.toml: want exactly one \`$k = <MB>\` line with a positive number"
      allgood=0
    fi
  done
  [ "$allgood" -eq 1 ] && ok "disk-budget.toml: linux and windows figures present"
}

check_mise_install_lib() {
  hdr "mise install lib (scripts/lib/mise-install.sh: force-reinstall-on-change, tasks/verify-tools)"
  local out
  if out=$(bash scripts/test-mise-install.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-mise-install.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}

check_bootstrap() {
  hdr "bootstrap.sh (scripts/test-bootstrap.sh)"
  local out
  if out=$(bash scripts/test-bootstrap.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-bootstrap.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}

# The hook and pin-table self-tests run on every lint. git exports GIT_INDEX_FILE /
# GIT_DIR / GIT_WORK_TREE to its hooks; the tests make temp repos, so unset them.
check_self_tests() {
  hdr "self-tests (.claude/hooks/test-hooks.sh, scripts/test-check-pins.sh, scripts/lib/test-verify-binary.sh)"
  local out t
  for t in .claude/hooks/test-hooks.sh "scripts/test-check-pins.sh --no-self" scripts/lib/test-verify-binary.sh; do
    if [ "${t%% *}" = .claude/hooks/test-hooks.sh ] && ! command -v jq >/dev/null 2>&1; then
      note "jq missing — test-hooks.sh skipped (it builds its inputs with jq)"
      continue
    fi
    # shellcheck disable=SC2086  # $t carries the script and its flag
    if out="$(env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE bash $t 2>&1)"; then
      ok "$(printf '%s\n' "$out" | tail -1 | sed -E 's/\x1b\[[0-9;]*m//g; s/^[^[:alnum:]]+//')"
    else
      bad "${t%% *} failed:"
      { printf '%s\n' "$out" | grep -E 'FAIL' || printf '%s\n' "$out" | tail -5; } | sed 's/^/      /'
    fi
  done
}

check_shellcheck() {
  hdr "shellcheck (warning and above)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    note "shellcheck not installed — skipped locally (CI enforces; 'dnf install shellcheck' to run here)"
    return 0
  fi
  # winterop is first-party; the vendored batpipe is excluded.
  local -a targets
  mapfile -t targets < <(shell_targets)
  if shellcheck -x -S warning "${targets[@]}"; then
    ok "clean at warning+ over ${#targets[@]} shell files"
  else
    bad "shellcheck reported warning+ findings (listed above)"
  fi
}

check_shfmt() {
  hdr "shfmt (shell formatting, -i 2)"
  if ! command -v shfmt >/dev/null 2>&1; then
    note "shfmt not installed — skipped locally (CI enforces; 'mise run fmt' to format here)"
    return 0
  fi
  local -a targets
  mapfile -t targets < <(shell_targets)
  local out
  if out=$(shfmt -d -i 2 "${targets[@]}" 2>&1); then
    ok "clean over ${#targets[@]} shell files (shfmt -i 2)"
  else
    bad "shfmt formatting diffs (fix: mise run fmt):"
    printf '%s\n' "$out" | sed 's/^/       /' | head -40
  fi
}

check_gitleaks() {
  hdr "gitleaks (committed-secret scan)"
  if ! command -v gitleaks >/dev/null 2>&1; then
    note "gitleaks not installed — skipped locally (CI enforces; 'mise run secrets' to scan here)"
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
# A guard whose `fi` drifts can swallow the plugin-load section and silently disable four
# zsh plugins under Warp: a guard may only fold into an `if` or open a SHORT block, and no
# plugin source may sit inside one. Guard counts are asserted.
check_warp_guards() {
  hdr "Warp TERM_PROGRAM guards (scope + plugin-chain safety)"
  local zsh=dotfiles/zshrc.tera bash=dotfiles/bashrc.tera
  local n_zsh n_bash out
  n_zsh=$(grep -c 'TERM_PROGRAM:-.* != WarpTerminal' "$zsh" || true)
  n_bash=$(grep -c 'TERM_PROGRAM:-.* != WarpTerminal' "$bash" || true)
  if [ "$n_zsh" -eq 6 ]; then
    ok "zshrc.tera: 6 Warp guards (fzf, atuin, starship, shift-select, zstyles, fzf-tab)"
  else
    bad "zshrc.tera: $n_zsh Warp guards, want 6 — a guard was added, dropped, or reworded"
  fi
  if [ "$n_bash" -eq 2 ]; then
    ok "bashrc.tera: 2 Warp guards (fzf, starship)"
  else
    bad "bashrc.tera: $n_bash Warp guards, want 2 — parity pair with zshrc.tera"
  fi

  # Depth-track if/fi and report any plugin source inside a Warp guard; one-line
  # `if ...; fi` bodies never open a block (the close pattern matches only a bare `fi`).
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
  local dir=dotfiles/config/zellij
  local cfg="$dir/config.kdl"
  local theme hits bad_hash tmp

  # 1. theme "<name>" must name a theme in themes/*.kdl; `setup --check` misses a bogus one.
  theme=$(sed -nE 's/^[[:space:]]*theme[[:space:]]+"([^"]+)".*/\1/p' "$cfg" | head -1)
  if [ -z "$theme" ]; then
    bad "$cfg: no theme \"...\" line found"
  elif grep -qE "^[[:space:]]*${theme}[[:space:]]*\{" "$dir"/themes/*.kdl 2>/dev/null; then
    ok "theme \"$theme\" is defined in $dir/themes/"
  else
    bad "theme \"$theme\" in $cfg has no matching block in $dir/themes/*.kdl"
  fi

  # 2. KDL comments are //, never #: one '#' line silently drops the whole file.
  bad_hash=$(grep -lE '^[[:space:]]*#' "$cfg" "$dir"/layouts/*.kdl "$dir"/themes/*.kdl 2>/dev/null || true)
  if [ -z "$bad_hash" ]; then
    ok "no '#' comment lines in any tracked .kdl (KDL needs //)"
  else
    bad "'#' comment line(s) invalidate these KDL files:"
    printf '%s\n' "$bad_hash" | sed 's/^/       /'
  fi

  # 3. copy_command must stay UNSET: it overrides OSC 52 with a binary that runs on the
  #    REMOTE host, where there is no display.
  hits=$(grep -nE '^[[:space:]]*copy_command' "$cfg" || true)
  if [ -z "$hits" ]; then
    ok "copy_command unset — OSC 52 clipboard path intact (ad444df)"
  else
    bad "$cfg sets copy_command, which kills OSC 52 over SSH:"
    printf '%s\n' "$hits" | sed 's/^/       /'
  fi

  # 4. Web server pinned off: the build is web-CAPABLE, so the pins aren't redundant.
  if grep -qE '^[[:space:]]*web_server[[:space:]]+false' "$cfg" &&
    grep -qE '^[[:space:]]*web_sharing[[:space:]]+"disabled"' "$cfg"; then
    ok "web_server false + web_sharing \"disabled\" pinned"
  else
    bad "$cfg must pin web_server false AND web_sharing \"disabled\" (build is web-capable)"
  fi

  # 5. The tab-bar alias points at mise's `latest` link for zjstatus: stable across bumps,
  #    so the permission-cache key survives, and no copy step.
  if grep -qE '^[[:space:]]*tab-bar[[:space:]]+location="file:~/\.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus\.wasm"' "$cfg"; then
    ok "tab-bar alias -> mise's install dir (github-dj95-zjstatus/latest/zjstatus.wasm)"
  else
    bad "$cfg: plugins { tab-bar location=\"file:~/.local/share/mise/installs/github-dj95-zjstatus/latest/zjstatus.wasm\" ... } missing or different"
  fi

  # 6. The zjstatus pills are invisible Nerd Font half-circles (U+E0B6 / U+E0B4); every
  #    pill must open and close, so the two counts must match and be non-zero.
  local lc rc
  lc=$(grep -o $'\xee\x82\xb6' "$cfg" | wc -l)
  rc=$(grep -o $'\xee\x82\xb4' "$cfg" | wc -l)
  if [ "$lc" -gt 0 ] && [ "$lc" -eq "$rc" ]; then
    ok "zjstatus pills: $lc rounded-left (U+E0B6) + $rc rounded-right (U+E0B4) glyphs present"
  else
    bad "$cfg: zjstatus pill glyphs missing or unbalanced (U+E0B6 x$lc, U+E0B4 x$rc) — the bar renders square blocks"
  fi

  # 7. Real parse when zellij is installed; soft-skipped in CI.
  if command -v zellij >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    # Stage layouts/ and themes/ alongside: both resolve relative to the config dir.
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

check_fastfetch_config() {
  hdr "fastfetch config (loads cleanly, known module types)"
  local cfg=dotfiles/config/fastfetch/config.jsonc err unknown
  if ! command -v fastfetch >/dev/null 2>&1; then
    note "fastfetch not on PATH — skipped the live config load"
    return
  fi
  # A JSON syntax error or an unknown key exits non-zero with the reason on stderr,
  # which every new top-level shell would print.
  if err=$(fastfetch --config "$PWD/$cfg" --logo none --pipe true 2>&1 >/dev/null) && [ -z "$err" ]; then
    ok "$cfg loads cleanly"
  else
    bad "fastfetch rejects $cfg: ${err:-non-zero exit, no message}"
  fi
  # An unknown module type is dropped without a word, so match each against the list.
  unknown=$(comm -23 <(sed -nE 's/.*"type": "([^"]+)".*/\1/p' "$cfg" | tr '[:upper:]' '[:lower:]' | sort -u) \
    <(fastfetch --list-modules autocompletion | cut -d: -f1 | tr '[:upper:]' '[:lower:]' | sort -u))
  if [ -z "$unknown" ]; then
    ok "every module type in $cfg is one fastfetch knows"
  else
    bad "$cfg names module types fastfetch doesn't know (their rows vanish silently): ${unknown//$'\n'/ }"
  fi
}

check_zed_settings() {
  hdr "Zed settings (no top-level terminal.shell: SSH remotes inherit it)"
  # Zed sends the client's user settings to an SSH remote's server, and since Zed 1.23.1
  # the remote terminal launches the terminal.shell those settings resolve to there. A
  # top-level shell (Windows' "nu") then runs on Linux hosts that don't have it; one under
  # a "windows"/"linux"/"macos" key only applies on that OS.
  py_report "Zed settings check" \
    dotfiles/windows/AppData/Roaming/Zed/settings.json dotfiles/config/zed/settings.json <<'PY'
import json, sys

def jsonc(text):
    # Drop // and /* */ comments outside strings, then trailing commas before } or ].
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1]); i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True; out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    s, res, in_str, j = "".join(out), [], False, 0
    while j < len(s):
        c = s[j]
        if in_str:
            res.append(c)
            if c == "\\":
                res.append(s[j + 1]); j += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True; res.append(c)
        elif c == ",":
            k = j + 1
            while k < len(s) and s[k] in " \t\r\n":
                k += 1
            if k < len(s) and s[k] in "}]":
                j += 1
                continue
            res.append(c)
        else:
            res.append(c)
        j += 1
    return json.loads("".join(res))

for path in sys.argv[1:]:
    try:
        d = jsonc(open(path, encoding="utf-8").read())
    except Exception as e:
        print(f"FAIL|zed|{path} doesn't parse as JSONC: {e}")
        continue
    if "shell" in d.get("terminal", {}):
        print(f"FAIL|zed|{path}: top-level terminal.shell ({d['terminal']['shell']!r}) reaches SSH remotes; move it under \"windows\"/\"linux\"")
    else:
        where = [k for k in ("windows", "linux", "macos") if "shell" in d.get(k, {}).get("terminal", {})]
        print(f"PASS|zed|{path}: no top-level terminal.shell" + (f" (per-OS: {', '.join(where)})" if where else ""))
PY
}

check_shell_highlight_parity() {
  hdr "Nushell command-line colours == zsh's (syntax-highlight.nu vs zshrc.tera)"
  py_report "highlight parity check" \
    dotfiles/zshrc.tera dotfiles/windows/AppData/Roaming/nushell/autoload/syntax-highlight.nu <<'PY'
import re, sys
zshrc, nu = (open(p, encoding="utf-8").read() for p in sys.argv[1:])
ATTR = {"bold": "b", "underline": "u", "italic": "i"}

def zsh_style(spec):
    fg, attrs = None, set()
    for part in spec.split(","):
        if part.startswith("fg="):
            fg = part[3:].lower()
        elif part in ATTR:
            attrs.add(ATTR[part])
    return fg, attrs

zsh = {m[1]: zsh_style(m[2]) for m in re.finditer(r"^ZSH_HIGHLIGHT_STYLES\[([a-z0-9-]+)\]='([^']*)'", zshrc, re.M)}
m = re.search(r"^ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='([^']*)'", zshrc, re.M)
if m:
    zsh["autosuggest"] = zsh_style(m[1])

block = re.search(r"^let zsh = \{\n(.*?)^\}", nu, re.M | re.S)
if not block:
    print("FAIL|highlight|syntax-highlight.nu has no `let zsh = {...}` record")
    sys.exit()
bad, n = [], 0
for line in block[1].splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    km = re.match(r'"?([a-z0-9-]+)"?:\s*(.*)$', line)
    if not km:
        bad.append(f"unparsed line {line!r}")
        continue
    key, val = km[1], km[2]
    vm = re.match(r'"(#[0-9a-fA-F]{6})"$', val) or re.match(r'\{ fg: "(#[0-9a-fA-F]{6})" attr: ([a-z]+) \}$', val)
    if not vm:
        bad.append(f"{key}: unparsed value {val!r}")
        continue
    nu_style = (vm[1].lower(), set(vm[2]) if vm.lastindex == 2 else set())
    n += 1
    if key not in zsh:
        bad.append(f"{key}: no ZSH_HIGHLIGHT_STYLES[{key}] in zshrc.tera")
    elif zsh[key] != nu_style:
        bad.append(f"{key}: Nushell {nu_style} != zsh {zsh[key]}")
if bad:
    print("FAIL|highlight|" + "; ".join(bad))
else:
    print(f"PASS|highlight|{n} Nushell styles match zshrc.tera's (colour and bold/underline/italic)")
PY
}

check_colorterm() {
  hdr "COLORTERM=truecolor in every interactive shell profile"
  # Without it bat (and other apps) fall back to 256 colours, so the Catppuccin themes drift.
  local f missing=()
  local -A want=(
    ["dotfiles/zshrc.tera"]='^export COLORTERM=truecolor'
    ["dotfiles/bashrc.tera"]='^export COLORTERM=truecolor'
    ["dotfiles/windows/AppData/Roaming/nushell/config.nu.tera"]='^\$env\.COLORTERM = "truecolor"'
    ["dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera"]="^\\\$env:COLORTERM = 'truecolor'"
  )
  for f in "${!want[@]}"; do
    grep -qE "${want[$f]}" "$f" || missing+=("$f")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "zshrc, bashrc, config.nu and the PowerShell profile set COLORTERM=truecolor"
  else
    bad "COLORTERM=truecolor missing from: ${missing[*]}"
  fi
}

if [ "${1:-}" = --shell-files ]; then
  shell_targets
  exit 0
fi
if [ "${1:-}" = --only ]; then
  shift
  [ "$#" -gt 0 ] || {
    echo "usage: $0 --only <check_name>..." >&2
    exit 2
  }
  for c in "$@"; do
    case "$c" in
    check_*) declare -F "$c" >/dev/null || {
      echo "unknown check: $c" >&2
      exit 2
    } ;;
    *)
      echo "unknown check: $c" >&2
      exit 2
      ;;
    esac
  done
  for c in "$@"; do "$c"; done
  [ "$fails" -eq 0 ]
  exit
fi
# run_parallel <check>...: run the checks concurrently, then print each one's buffered
# output in this order and add up its failures (each runs in its own subshell).
run_parallel() {
  local d c
  d=$(mktemp -d)
  for c in "$@"; do
    (
      fails=0
      "$c" >"$d/$c.out" 2>&1
      echo "$fails" >"$d/$c.n"
    ) &
  done
  wait
  for c in "$@"; do
    cat "$d/$c.out"
    fails=$((fails + $(cat "$d/$c.n")))
  done
  rm -rf "$d"
}

printf '%s%s== workstation invariant check ==%s\n' "$BOLD" "$BLUE" "$RESET"
check_pins
check_line_endings_and_mode
check_dotfiles_mode
check_bom
check_ps_variable_drive_refs
check_ps_mise_comma_lists
check_sentinels
check_tools_block
check_mise_config_files
check_bootstrap_config
check_dotfiles_config
check_completion_parity
check_warp_guards
check_zellij_config
check_fastfetch_config
check_zed_settings
check_shell_highlight_parity
check_colorterm
check_disk_budget
check_layout
# The test suites and linters take most of the time and share nothing.
run_parallel check_lsp_plugin check_mise_install_lib check_bootstrap check_self_tests check_shellcheck check_shfmt check_gitleaks
echo
if [ "$fails" -eq 0 ]; then
  printf '%s✓ all invariant checks passed%s\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%s✗ %d invariant check(s) failed%s\n' "$RED" "$fails" "$RESET"
  exit 1
fi
