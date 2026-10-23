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
    dotfiles/claude/notify.sh dotfiles/local/bin/winterop dotfiles/local/bin/zcc dotfiles/local/bin/zc++ \
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
# tasks/check-updates (as UPPER_CASE), bumped by scripts/bump-versions.sh (by name)
# and listed by scripts/gen-tool-memory.sh.
pin_vars_reachable() {
  local key missing="" n=0
  while read -r key; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    grep -q "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" tasks/check-updates || missing="$missing $key(tasks/check-updates)"
    grep -q "$key" scripts/bump-versions.sh || missing="$missing $key(bump-versions.sh)"
    grep -q "$key" scripts/gen-tool-memory.sh || missing="$missing $key(gen-tool-memory.sh)"
  done < <("$PY" -c 'import tomllib
for k in tomllib.load(open("config.toml","rb")).get("vars",{}):
    print(k) if k.endswith("_version") else None')
  if [ "$n" -eq 0 ]; then missing=" <none found>"; fi
  if [ "$n" -gt 0 ] && [ -z "$missing" ]; then ok "all $n [vars] *_version pin(s) reach check-updates, bump-versions and gen-tool-memory"; else bad "[vars] pin(s) not covered:$missing"; fi
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
  # 404s on some releases), go + gopls, node (its postinstall pins the LSP servers), gob
  # (its vendored skill).
  pin_bumper_handles github:dj95/zjstatus http:ncdu go go:golang.org/x/tools/gopls node github:juanibiapina/gob
  # gob's Claude Code skill is vendored at the pin's tag, so it describes the installed CLI.
  pin_equal "gob (its vendored Claude Code skill)" \
    "config.linux.toml=$(sed -nE 's#^"github:juanibiapina/gob" = \{ version = "([^"]+)".*#\1#p' config.linux.toml)" \
    "skills/gob/.vendor=$(sed -nE 's/^tag: +v([^ ]+)$/\1/p' dotfiles/claude/skills/gob/.vendor)"
  # The bumper locks NO_SLSA tools with mise's SLSA check off: only ever tools this repo pins.
  local t no_slsa_bad=0
  for t in $(sed -n 's/^NO_SLSA="\(.*\)"$/\1/p' scripts/bump-versions.sh); do
    if ! grep -qF "\"$t\" = " config.toml config.linux.toml config.windows.toml; then
      bad "bump-versions.sh NO_SLSA names $t, which no config*.toml pins"
      no_slsa_bad=1
    fi
  done
  [ "$no_slsa_bad" -eq 0 ] && ok "bump-versions.sh NO_SLSA names only pinned tools"
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
  # zig assumes glibc 2.31 on EL8 (2.28), so its users pin the floor explicitly.
  local floor
  floor="$(sed -nE 's/.*WORKSTATION_GLIBC_FLOOR=([0-9.]+).*/\1/p' .github/workflows/disk-budget.yml | head -1)"
  pin_equal "zig's glibc target (EL8 floor)" "disk-budget.yml=$floor" \
    "treesitter.lua=$(sed -nE 's/.*linux-gnu\.([0-9.]+).*/\1/p' dotfiles/config/nvim/lua/ws/treesitter.lua | head -1)" \
    "zcc=$(sed -nE 's/.*linux-gnu\.([0-9.]+).*/\1/p' dotfiles/local/bin/zcc | head -1)" \
    "zc++=$(sed -nE 's/.*linux-gnu\.([0-9.]+).*/\1/p' dotfiles/local/bin/zc++ | head -1)"
  if cmp -s dotfiles/local/bin/zcc dotfiles/local/bin/zc++; then ok "zcc and zc++ are the same script"; else bad "dotfiles/local/bin/zcc and zc++ differ (one script, dispatched on \$0)"; fi
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
  "dotfiles/local/bin/zcc"                           # ~/.local/bin copy entry — zig as a C compiler, invoked directly
  "dotfiles/local/bin/zc++"                          # ~/.local/bin copy entry — the same script as C++
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

# Every pull of this checkout passes --prune, so the origin/* branches GitHub has deleted
# (a merged PR's) don't pile up on the hosts. Each file must still have its pull.
check_git_pull_prune() {
  hdr "git pull of this checkout passes --prune"
  local f hits allgood=1
  for f in bootstrap.sh bootstrap.ps1 tasks/update \
    dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera \
    dotfiles/windows/AppData/Roaming/nushell/config.nu.tera; do
    hits=$(grep -nE '^[^#]*git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+pull([[:space:]]|$)' "$f")
    if [ -z "$hits" ]; then
      allgood=0
      bad "$f: no \`git -C <repo> pull\` found (moved? update check_git_pull_prune)"
    elif grep -v -- '--prune' <<<"$hits" | grep -q .; then
      allgood=0
      bad "$f: a pull without --prune: $(grep -v -- '--prune' <<<"$hits" | head -1)"
    fi
  done
  [ "$allgood" -eq 1 ] && ok "bootstrap.sh, bootstrap.ps1, tasks/update and both Windows wsu pull with --prune"
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


# Hooks: `mise run [--skip-tools] <task>[ ::: <task>]`, each task existing; mise runs a name
# from every loaded file. A hook that runs before the tools phase must pass --skip-tools:
# `mise run` otherwise installs every missing tool first, so a fresh host's tools (node's
# postinstall needs dnf's libatomic) would install before the dnf batch.
hook_re = re.compile(r"^mise run (--skip-tools )?[a-z-]+( ::: [a-z-]+)*$")
AFTER_TOOLS_HOOKS = {"post-tools", "final"}
toml_tasks = {t for d in loaded.values() for t in d.get("tasks", {})}
# config.linux.toml's post-dotfiles is the raw chmod line restoring ~/.ssh and ~/.claude
# modes, then ws reconcile's baseline, pinned to an exact literal: mise runs hooks as
# `sh -o errexit`, so each command needs its own `|| true` (where ~/.claude doesn't exist
# yet the first chmod would abort the bootstrap). Windows' is an ordinary `mise run` hook.
EXPECTED_POST_DOTFILES_HOOK = (
    "chmod 700 ~/.ssh ~/.claude 2>/dev/null || true; "
    "chmod 600 ~/.ssh/config 2>/dev/null || true; "
    "chmod 600 ~/.config/mise/dotfiles/ssh/config.tera 2>/dev/null || true; "
    "mise run --skip-tools dotfiles-baseline || true"
)
# Both OSes keep ws reconcile's baseline (post-dotfiles) and back up local edits before an
# apply (pre-dotfiles): a hook that went missing would leave reconcile guessing again.
WS_HOOKS = {
    "config.linux.toml": {"pre-dotfiles": "mise run --skip-tools dotfiles-snapshot",
                          "post-dotfiles": EXPECTED_POST_DOTFILES_HOOK},
    "config.windows.toml": {"pre-dotfiles": "mise run --skip-tools dotfiles-snapshot-win",
                            "post-dotfiles": "mise run --skip-tools dotfiles-baseline-win"},
}
bad_hooks = []
n_hooks = 0
for f, want in WS_HOOKS.items():
    have = loaded.get(f, {}).get("bootstrap", {}).get("hooks", {})
    for name, val in want.items():
        if have.get(name) != val:
            bad_hooks.append(f"{f}:{name} must be {val!r} (got {have.get(name)!r})")
for f, d in loaded.items():
    for name, val in d.get("bootstrap", {}).get("hooks", {}).items():
        n_hooks += 1
        if name == "post-dotfiles" and f == "config.linux.toml":
            continue  # the pinned literal, checked above
        if not hook_re.match(val):
            bad_hooks.append(f"{f}:{name}={val!r} (want 'mise run <task>')")
            continue
        if name not in AFTER_TOOLS_HOOKS and "--skip-tools" not in val:
            bad_hooks.append(f"{f}:{name} runs before the tools phase: use 'mise run --skip-tools <task>' (else it installs every tool before dnf)")
        for task in val.split("mise run ", 1)[1].removeprefix("--skip-tools ").split(" ::: "):
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
    "dnf:curl": "conflicts with EL9's default curl-minimal, failing the batch; bootstrap.sh needs a curl first anyway",
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
# sidecar present anywhere under its source (mise matches exclude names at any depth).
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
    sidecars = {n for _, _, names in os.walk(src) for n in names if n in (".vendor", ".gitkeep")}
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

# Claude Code mods: plugins of function hooks (a hooks/hooks.json beside
# .claude-plugin/plugin.json) in this repo's .claude/skills, which Claude Code loads as
# project-scope <name>@skills-dir plugins in a session in this checkout (once the folder is
# trusted) and nowhere else. They stay project-level: none under dotfiles/claude/skills (the
# ~/.claude/skills copy would load them in every session) and none named in
# settings.enforced.json. A module that fails to load, or a hook that throws, is skipped
# without a word in a session that isn't hot-reloading it, so each mod is held here: its
# manifest names its folder, every module hooks.json lists exists, it has tests, and where
# claude is installed it passes `claude plugin validate --strict` and `claude plugin test`
# (each run on a copy, so neither can write into the checkout). CI has no claude.
check_claude_mods() {
  hdr "Claude Code mods (.claude/skills/*/hooks, project scope)"
  local hooks dir name tmp n=0 module
  for hooks in dotfiles/claude/skills/*/hooks/hooks.json; do
    [ -f "$hooks" ] && bad "${hooks%/hooks/hooks.json} is a mod under dotfiles/claude/skills: it would load in every session; mods live in .claude/skills"
  done
  if jq -e '.enabledPlugins // {} | keys[] | select(startswith("workstation-") and . != "workstation-lsp@skills-dir")' \
    dotfiles/claude/settings.enforced.json >/dev/null 2>&1; then
    bad "dotfiles/claude/settings.enforced.json names a workstation mod: project-scope mods load without it"
  fi
  for hooks in .claude/skills/*/hooks/hooks.json; do
    [ -f "$hooks" ] || continue
    dir=${hooks%/hooks/hooks.json}
    n=$((n + 1))
    name=$(jq -r '.name // empty' "$dir/.claude-plugin/plugin.json" 2>/dev/null)
    if [ "$name" != "${dir##*/}" ]; then
      bad "$dir: .claude-plugin/plugin.json's name is '${name}', not its folder's (${dir##*/})"
      continue
    fi
    while IFS= read -r module; do
      [ -f "$dir/hooks/$module" ] || bad "$hooks lists $module, which $dir/hooks/ doesn't have"
    done < <(jq -r '.modules[]?' "$hooks")
    compgen -G "$dir/tests/*.test.ts*" >/dev/null || bad "$dir has no tests/*.test.ts"
    if command -v claude >/dev/null 2>&1; then
      tmp=$(mktemp -d)
      cp -r "$dir/." "$tmp/"
      if ! claude plugin validate "$tmp" --strict >/dev/null 2>&1; then
        bad "$name failed claude plugin validate --strict:"
        claude plugin validate "$tmp" --strict 2>&1 | sed 's/^/       /' | head -20
      elif ! claude plugin test "$tmp" >"$tmp.log" 2>&1; then
        bad "$name's tests failed (claude plugin test):"
        grep -E '^\(fail\)|^ +[0-9]+ (pass|fail)$' "$tmp.log" | sed 's/^/       /' | head -20
      fi
      rm -rf "$tmp" "$tmp.log"
    fi
  done
  [ "$n" -gt 0 ] || bad "no mods under .claude/skills (workstation-sync, workstation-ship, workstation-lint-fold)"
  command -v claude >/dev/null 2>&1 || note "claude not installed — skipped the mods' validate and tests (CI has no claude)"
  [ "$fails" -eq 0 ] && ok "$n project-scope mod(s) in .claude/skills, none under dotfiles or in settings.enforced.json: manifests, modules and tests present$(command -v claude >/dev/null 2>&1 && echo ', validated --strict, tests pass')"
}

# Claude Code's theme, keybindings and plugin list (dotfiles/claude). Claude Code ignores
# an unknown colour token, a bad colour or a bad keybinding without a word, so a typo would
# just not show: the enforced theme must name a theme file here, a theme must set only the
# documented tokens (code.claude.com/docs/en/terminal-config) or the two undocumented ones
# below, with colours Claude Code accepts, and keybindings.json must use known contexts,
# action names and keys it can rebind. A token left out keeps the base theme's colour, so
# a theme that sets a colour sets its shimmer too (or the animation flashes the base's
# colour), and one that sets the accent sets the logo's (or the logo stays orange). The
# status line matches: ccstatusline's built-in catppuccin powerline theme, at colorLevel 3,
# whose row is Mocha's own hex colours (levels 1 and 2 are ANSI approximations). clangd
# is registered once, by workstation-lsp: the official clangd-lsp plugin would start a
# second clangd for the same files, so the enforced file turns it off.
check_claude_config() {
  hdr "Claude Code theme, status line, keybindings and plugins (dotfiles/claude, ccstatusline)"
  if [ -z "$PY" ]; then
    note "no python with tomllib on PATH — skipped"
    return 0
  fi
  local out line
  out=$(
    "$PY" - <<'PY' 2>&1
import glob, json, os, re
d = "dotfiles/claude"
bad = []
def load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except (OSError, ValueError) as e:
        bad.append(f"{p}: {e}")
tokens = set("""claude text inverseText inactive subtle suggestion permission remember
success error warning merged promptBorder planMode autoAccept bashBorder ide fastMode effortUltra
diffAdded diffRemoved diffAddedDimmed diffRemovedDimmed diffAddedWord diffRemovedWord
userMessageBackground userMessageBackgroundHover bashMessageBackgroundColor memoryBackgroundColor selectionBg
rate_limit_fill rate_limit_empty briefLabelYou briefLabelClaude claudeShimmer warningShimmer
permissionShimmer promptBorderShimmer inactiveShimmer fastModeShimmer""".split())
# Undocumented, but every built-in theme in 2.1.301 sets them: the logo's colour, and the
# accept-edits shimmer.
tokens |= {"clawd_body", "autoAcceptShimmer"}
tokens |= {f"{c}_FOR_SUBAGENTS_ONLY" for c in "red blue green yellow purple orange pink cyan".split()}
for c in "red orange yellow green blue indigo violet".split():
    tokens |= {f"rainbow_{c}", f"rainbow_{c}_shimmer"}
colour = re.compile(r"#[0-9a-fA-F]{6}|#[0-9a-fA-F]{3}|rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)|ansi256\(\d{1,3}\)"
                    r"|ansi:(black|red|green|yellow|blue|magenta|cyan|white)(Bright)?")
themes = sorted(glob.glob(f"{d}/themes/*.json"))
for p in themes:
    t = load(p) or {}
    for k in set(t) - {"name", "base", "overrides"}:
        bad.append(f"{p}: unknown field {k}")
    if t.get("base", "dark") not in "dark light dark-daltonized light-daltonized dark-ansi light-ansi".split():
        bad.append(f"{p}: base {t.get('base')!r} is not a built-in theme")
    over = t.get("overrides") or {}
    for k, v in over.items():
        if k not in tokens:
            bad.append(f"{p}: {k} is not a colour token Claude Code reads")
        elif not isinstance(v, str) or not colour.fullmatch(v):
            bad.append(f"{p}: {k} = {v!r} is not a colour Claude Code accepts")
        for shimmer in (k + "Shimmer", k + "_shimmer"):
            if shimmer in tokens and shimmer not in over:
                bad.append(f"{p}: sets {k} but not {shimmer}, so its shimmer keeps the base theme's colour")
    if "claude" in over and "clawd_body" not in over:
        bad.append(f"{p}: sets claude but not clawd_body, so the logo keeps the base theme's orange")
enforced = load(f"{d}/settings.enforced.json") or {}
theme = enforced.get("theme", "")
if theme.startswith("custom:") and not os.path.isfile(f"{d}/themes/{theme[7:]}.json"):
    bad.append(f"settings.enforced.json's theme {theme} has no {d}/themes/{theme[7:]}.json")
contexts = set("""Global Chat Autocomplete Confirmation Help Transcript HistorySearch Task ThemePicker Settings
Tabs Attachments Footer AbovePrompt AbovePromptInput AbovePromptSelect Pane PaneField MessageSelector
DiffDialog DiffPanel ModelPicker EffortSlider Select Plugin Scroll Agents""".split())
mods = {"ctrl", "control", "alt", "opt", "option", "shift", "meta", "cmd", "command", "super", "win"}
fixed = {"ctrl+c", "ctrl+d", "ctrl+m", "ctrl+[", "ctrl+i", "ctrl+h"}
kb_path = f"{d}/keybindings.json"
kb = load(kb_path) if os.path.exists(kb_path) else bad.append(f"no {kb_path}")
binds = 0
if kb is not None:
    if not isinstance(kb.get("bindings"), list):
        bad.append(f'{kb_path}: no "bindings" array')
    for block in kb.get("bindings") or []:
        if block.get("context") not in contexts:
            bad.append(f"{kb_path}: unknown context {block.get('context')!r}")
        for keys, action in (block.get("bindings") or {}).items():
            binds += 1
            if action is not None and not (isinstance(action, str) and re.fullmatch(r"[a-zA-Z]+:[a-zA-Z]+", action)):
                bad.append(f"{kb_path}: {keys} -> {action!r} is not an action name")
            strokes = keys.split(" ")
            if len(strokes) == 1 and keys in fixed:
                bad.append(f"{kb_path}: {keys} can't be rebound")
            for s in strokes:
                *m, key = s.split("+")
                if not key or set(m) - mods:
                    bad.append(f"{kb_path}: {keys!r} is not a keystroke Claude Code reads")
ccs_path = "dotfiles/config/ccstatusline/settings.json"
ccs = load(ccs_path) or {}
if (ccs.get("powerline") or {}).get("theme") != "catppuccin" or ccs.get("colorLevel") != 3:
    bad.append(f"{ccs_path}: the status line wants powerline.theme \"catppuccin\" at colorLevel 3 (Mocha's hex colours)")
lsp = load(f"{d}/skills/workstation-lsp/.lsp.json") or {}
if any(s.get("command") == "clangd" for s in lsp.values()) and enforced.get("enabledPlugins", {}).get("clangd-lsp@claude-plugins-official") is not False:
    bad.append("workstation-lsp registers clangd, so settings.enforced.json must set clangd-lsp@claude-plugins-official to false")
for b in bad:
    print("BAD " + b)
if not bad:
    print(f"OK {len(themes)} theme(s) with known tokens, valid colours, every shimmer and the logo, the enforced {theme or 'default'} theme present, the status line in catppuccin, {binds} keybindings in known contexts, clangd registered once")
PY
  )
  while IFS= read -r line; do
    case "$line" in
    OK\ *) ok "${line#OK }" ;;
    BAD\ *) bad "${line#BAD }" ;;
    *) [ -n "$line" ] && bad "$line" ;;
    esac
  done <<<"$out"
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
  hdr "self-tests (.claude/hooks/test-hooks.sh, scripts/test-check-pins.sh, scripts/lib/test-verify-binary.sh, scripts/test-term-fallback.sh, scripts/test-shell-marks.sh, scripts/test-editing-keys.sh, scripts/test-wezterm-sshconfig.sh, scripts/test-ws.sh)"
  local out t
  for t in .claude/hooks/test-hooks.sh "scripts/test-check-pins.sh --no-self" scripts/lib/test-verify-binary.sh scripts/test-term-fallback.sh scripts/test-shell-marks.sh scripts/test-editing-keys.sh scripts/test-wezterm-sshconfig.sh scripts/test-ws.sh; do
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
  if [ "$n_zsh" -eq 7 ]; then
    ok "zshrc.tera: 7 Warp guards (fzf, atuin, starship, shift-select, zstyles, fzf-tab, prompt marks)"
  else
    bad "zshrc.tera: $n_zsh Warp guards, want 7 — a guard was added, dropped, or reworded"
  fi
  if [ "$n_bash" -eq 3 ]; then
    ok "bashrc.tera: 3 Warp guards (fzf, starship, prompt marks)"
  else
    bad "bashrc.tera: $n_bash Warp guards, want 3 — parity pair with zshrc.tera"
  fi

  # Depth-track if/fi and report any plugin source inside a Warp guard; one-line
  # `if ...; fi` bodies never open a block (the close pattern matches only a bare `fi`),
  # and an `elif ...; then` continues the open one.
  out=$(awk '
    /^[[:space:]]*elif[[:space:]]/ { next }
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

# No tracked Linux tool is part of the C/C++ toolchain or its build drivers: dnf owns them
# where there is sudo, and a mise copy first on PATH would shadow them (another
# gcc/libstdc++ for every build and ccache; CMake 4 refuses cmake_minimum_required < 3.5).
# zig is the fallback compiler under its own name; a no-sudo host without cmake, ninja or
# make adds them in its git-ignored config.local.toml. tasks/verify-tools checks the
# installed result (no mise binary named cc, gcc, g++, c++, cpp, clang, clang++, ld, as).
check_toolchain_shadow() {
  hdr "no tracked Linux mise tool shadows the dnf C/C++ toolchain"
  py_report "toolchain-shadow" <<'PY'
import tomllib
deny = {"gcc", "gxx", "clang", "clangxx", "llvm", "binutils", "compilers", "c-compiler",
        "cxx-compiler", "make", "cmake", "ninja"}
hits, n = [], 0
for f in ("config.toml", "config.linux.toml"):
    with open(f, "rb") as fh:
        tools = tomllib.load(fh).get("tools", {})
    for key, val in tools.items():
        if isinstance(val, dict) and val.get("os") and "linux" not in val["os"]:
            continue
        n += 1
        name = key.split(":", 1)[-1].rsplit("/", 1)[-1].lower()
        if name in deny or name.split("_", 1)[0] in deny:
            hits.append(f"{f}:{key}")
if hits:
    print("FAIL|shadow|" + "; ".join(hits) + " shadow the dnf toolchain (a no-sudo host adds cmake/ninja/make in config.local.toml; the compiler fallback is zig)")
else:
    print(f"PASS|shadow|{n} Linux tool key(s), none from the C/C++ toolchain")
PY
}

# WezTerm's config (dotfiles/config/wezterm/wezterm.lua and the modules it requires, loaded on
# Windows) runs in WezTerm's Lua at startup, and an error there leaves WezTerm on its defaults.
# Run it under Neovim's LuaJIT with a stand-in wezterm module, as Windows and as Linux, against
# a fake ~/.ssh/config.local and Nushell shim. Soft-skipped without nvim (CI's lint job).
check_wezterm_config() {
  hdr "WezTerm config (runs with a stand-in wezterm module, handlers included)"
  local cfg=dotfiles/config/wezterm/wezterm.lua tmp out lua modules
  # LuaJIT either way: plain luajit (CI installs it) or the one inside nvim.
  if command -v luajit >/dev/null 2>&1; then
    lua=(luajit)
  elif command -v nvim >/dev/null 2>&1; then
    lua=(nvim --clean --headless -l)
  else
    note "neither luajit nor nvim on PATH — skipped running $cfg"
    return 0
  fi
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.ssh" "$tmp/t"
  printf 'Host alpha beta\n  HostName atc-alpha.corp\nHost *.corp\nHost !bad\n  HostName x.example\n  host = gamma # comment\n  HostName = 10.0.0.9\nMatch host foo\n  HostName y.example\nHost bad"quote\n' >"$tmp/.ssh/config.local"
  # The config builds the Windows shim path with backslashes; on Linux that is one file name.
  : >"$tmp/la\\mise\\shims\\nu.exe"
  # The stand-in records what the config hands WezTerm: actions as { action, args } tables
  # (callable, as WezTerm's are), callbacks as { callback }, event handlers by name.
  cat >"$tmp/check.lua" <<'LUA'
local path, triple, home, localappdata, modules = arg[1], arg[2], arg[3], arg[4], arg[5]
local real_getenv = os.getenv
os.getenv = function(k) if k == 'LOCALAPPDATA' then return localappdata end return real_getenv(k) end
local handlers, battery, live = {}, {}, {}
local function named(name)
  return setmetatable({ action = name }, { __call = function(_, args) return { action = name, args = args } end })
end
local wezterm = {
  target_triple = triple,
  config_file = path,
  home_dir = home,
  GLOBAL = {},
  nerdfonts = {},
  config_builder = function() return {} end,
  font_with_fallback = function(list) return { fallback = list } end,
  color = {
    get_builtin_schemes = function() return { ['Catppuccin Mocha'] = { background = '#1e1e2e' } } end,
    -- A colour whose adjustments return a darker marker, so a test can tell them apart.
    parse = function(hex)
      local c = { hex = hex }
      local function dim() return setmetatable({ hex = 'dim' .. hex }, getmetatable(c)) end
      return setmetatable(c, { __index = { desaturate = dim, darken = dim }, __tostring = function(x) return x.hex end })
    end,
  },
  hostname = function() return 'PC.corp' end,
  default_wsl_domains = function() return { { name = 'WSL:Alma', distribution = 'Alma' } } end,
  mux = { get_pane = function(id) return live[id] end },
  url = {
    parse = function(u)
      local scheme, host, path = u:match('^(%a+)://([^/]*)(/.*)$')
      if not scheme then error('not a URL: ' .. u) end
      local url = { scheme = scheme, host = host, file_path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end) }
      return setmetatable(url, { __tostring = function() return u end })
    end,
  },
  action = setmetatable({}, { __index = function(_, name) return named(name) end }),
  action_callback = function(fn) return { callback = fn } end,
  on = function(event, fn) handlers[event] = fn end,
  default_hyperlink_rules = function() return { { regex = 'default' } } end,
  strftime = function(fmt) return os.date(fmt) end,
  battery_info = function() return battery end,
  column_width = function(s) local _, n = s:gsub('[^\128-\191]', '') return n end,
  truncate_right = function(s, n) return s:sub(1, n) end,
  format = function(items)
    local out = {}
    for _, it in ipairs(items) do if it.Text then out[#out + 1] = it.Text end end
    return table.concat(out)
  end,
}
package.loaded.wezterm = wezterm
local c = dofile(path)
local function check(cond, msg) if not cond then error(msg, 0) end end
local function has(s, sub) return s ~= nil and s:find(sub, 1, true) ~= nil end

check(type(c) == 'table', 'the file does not return the config table')
for m in modules:gmatch('[^,]+') do check(package.loaded[m], m .. '.lua is never required, so WezTerm ignores it') end
local scheme = c.color_schemes and c.color_schemes[c.color_scheme]
check(scheme, 'color_scheme names no scheme in color_schemes')
check(scheme.tab_bar.active_tab.bg_color == '#cba6f7' and scheme.cursor_bg == '#cba6f7', 'the active tab and the cursor are not mauve')
for _, k in ipairs({ 'launcher_label_bg', 'input_selector_label_bg', 'quick_select_label_bg', 'copy_mode_active_highlight_bg' }) do
  check(type(scheme[k]) == 'table' and scheme[k].Color, 'scheme.' .. k .. ' is not a { Color = ... } spec')
end
check(c.command_palette_bg_color == '#11111b' and c.char_select_bg_color == '#11111b', 'the command palette or char select is not Mocha crust')
check(c.font and c.font.fallback[1] == 'JetBrainsMono NFM' and c.font_size == 10.5, 'font is not JetBrainsMono NFM 10.5')
check(c.check_for_updates == false, 'check_for_updates is not false (wezterm-nightly.ps1 updates WezTerm)')
check(c.term == 'wezterm', 'term is not wezterm')
check(c.scrollback_lines == 1000000, 'scrollback_lines is not 1,000,000')
check(c.front_end == 'WebGpu' and c.webgpu_power_preference == 'HighPerformance' and c.max_fps == 120, 'rendering is not WebGpu + HighPerformance + 120 fps')
check(c.window_decorations == 'RESIZE' and c.tab_bar_at_bottom == true and c.use_fancy_tab_bar == false, 'chrome: not RESIZE with the retro tab bar at the bottom')
check(c.visual_bell and c.visual_bell.target == 'CursorColor', 'no visual bell')
check(c.default_cursor_style == 'BlinkingBar' and c.cursor_blink_rate > 0, 'the cursor is not a blinking bar')
-- WezTerm reads an easing's four numbers as a one-dimensional cubic: one whose first isn't 0
-- (Ease, EaseIn, EaseInOut) starts each blink fade part-way, a visible jump.
for _, k in ipairs({ 'cursor_blink_ease_in', 'cursor_blink_ease_out' }) do
  local e = c[k]
  local from_0 = e == nil or e == 'Linear' or e == 'EaseOut' or e == 'Constant' or (type(e) == 'table' and e.CubicBezier and e.CubicBezier[1] == 0)
  check(from_0, k .. ' starts its fade part-way (a CubicBezier must start with 0)')
end
-- An unfocused cursor is a hollow box with sides 1.5x this thickness: 2 px or more at 100%
-- scaling fills JetBrainsMono 10.5's 8 px cell, and the box looks like a split bar.
local pt = c.cursor_thickness == nil and 0 or tonumber(tostring(c.cursor_thickness):match('^([%d.]+)pt$'))
check(pt and math.floor(pt * 96 / 72) <= 1, 'cursor_thickness is not below 1.5pt (an unfocused cursor would look like a split bar)')
check(c.notification_handling == 'SuppressFromFocusedPane', 'notification_handling is not SuppressFromFocusedPane')
check(c.window_close_confirmation == 'NeverPrompt' and c.enable_kitty_keyboard == true, 'closing the window asks, or the kitty keyboard protocol is off')
-- A middle-click on a tab always confirms, so only this hook stops it asking.
check(handlers['mux-is-process-stateful'] and handlers['mux-is-process-stateful']({ name = 'hx', executable = 'hx' }) == false, 'a middle-click on a tab asks before closing it (mux-is-process-stateful does not return false)')
check(c.key_tables and c.key_tables.resize_pane and #c.key_tables.resize_pane == 6, 'no resize_pane key table (arrows, Esc, Enter)')
check(type(c.ssh_domains) == 'table' and #c.ssh_domains == 0, 'ssh_domains is not empty')
check(has(c.hyperlink_rules[#c.hyperlink_rules].format, 'ArrushC/workstation/issues/$1') and #c.hyperlink_rules == 2, 'no #123 hyperlink rule after the defaults')

local keys = {}
for _, k in ipairs(c.keys) do keys[k.mods .. '+' .. k.key] = k.action end
local function key(chord, name)
  local a = keys[chord]
  check(a and (a.action == name or (name == 'callback' and a.callback)), chord .. ' is not ' .. name)
  return a
end
key('CTRL|ALT+l', 'ShowLauncherArgs')
key('CTRL+UpArrow', 'ScrollToPrompt')
check(key('CTRL|SHIFT+UpArrow', 'ScrollToPrompt').args == -1 and key('CTRL|SHIFT+DownArrow', 'ScrollToPrompt').args == 1, 'Ctrl+Shift+Up/Down do not jump between prompts')
key('CTRL|SHIFT+LeftArrow', 'DisableDefaultAssignment')
key('CTRL|SHIFT+RightArrow', 'DisableDefaultAssignment')
local scroll = key('CTRL|SHIFT+a', 'Multiple')
check(scroll.args[#scroll.args - 1].action == 'ScrollToBottom', 'Ctrl+Shift+A does not scroll back to the bottom')
for _, k in ipairs({ 'c', 'e', 'h', 's', 'o', 'F5', 't' }) do key('CTRL|SHIFT+' .. k, 'callback') end
key('CTRL|ALT+t', 'callback')
check(keys['CTRL+Insert'] == keys['CTRL|SHIFT+c'], 'Ctrl+Insert is not the Ctrl+Shift+C copy')
key('ALT|SHIFT+D', 'callback')
key('ALT|SHIFT+R', 'callback')
check(key('CTRL|SHIFT+w', 'CloseCurrentTab').args.confirm == false, 'Ctrl+Shift+W asks before closing the tab')
key('CTRL|SHIFT+q', 'PaneSelect')
key('ALT+0', 'ActivateLastTab')
check(key('ALT|SHIFT+S', 'ActivateKeyTable').args.name == 'resize_pane', 'Alt+Shift+S does not enter resize mode')
local helix, sha = key('CTRL|SHIFT+g', 'QuickSelectArgs'), key('CTRL|SHIFT+y', 'QuickSelectArgs')
local mouse = {}
for _, m in ipairs(c.mouse_bindings) do
  local kind, ev = next(m.event)
  mouse[m.mods .. '+' .. kind .. ev.streak] = m.action
end
local shift_up = mouse['SHIFT+Up1']
check(shift_up and shift_up.action == 'Multiple' and shift_up.args[1].action == 'CompleteSelectionOrOpenLinkAtMouseCursor', 'Shift+click does not open links')
check(mouse['SHIFT+Down1'] and mouse['SHIFT+Down1'].action == 'SelectTextAtMouseCursor', 'Shift+press still extends the selection, so Shift+click never opens a link')
check(mouse['SUPER+Drag1'] and mouse['SUPER+Drag1'].action == 'StartWindowDrag', 'Win+drag does not move the window')
for n = 1, 3 do
  local up = mouse['NONE+Up' .. n]
  check(up and up.action == 'Multiple' and up.args[1].action == 'CompleteSelection' and up.args[2].callback, 'releasing a ' .. n .. '-click selection does not copy it and say so')
end
check(mouse['CTRL+Up1'] and mouse['CTRL+Up1'].action == 'OpenLinkAtMouseCursor' and mouse['CTRL+Down1'].action == 'Nop', 'Ctrl+click does not open links')
check(mouse['CTRL+Down3'] and mouse['CTRL+Down3'].args == 'SemanticZone' and mouse['CTRL+Up3'], "Ctrl+triple-click does not select a command's output")

local labels = {}
for _, item in ipairs(c.launch_menu) do
  labels[#labels + 1] = item.label
  check(item.domain and item.domain.DomainName == 'local', item.label .. ': not pinned to the local domain')
end
local got = table.concat(labels, ',')
if triple:find('windows') then
  check(c.wsl_domains and c.wsl_domains[1].default_cwd == '~', 'Windows: WSL tabs do not start in ~')
  check(c.default_prog and c.default_prog[1] == localappdata .. '\\mise\\shims\\nu.exe', 'Windows: default_prog is not the Nushell shim')
  check(got == 'Nushell,PowerShell,Windows PowerShell,cmd,SSH: alpha,SSH: beta,SSH: gamma', 'Windows launch menu: ' .. got)
else
  check(c.default_prog == nil, 'Linux: default_prog is set')
  check(got == 'SSH: alpha,SSH: beta,SSH: gamma', 'Linux launch menu: ' .. got)
end
local ssh = c.launch_menu[#c.launch_menu].args
check(ssh[1] == 'ssh' and ssh[2] == '-t' and ssh[3] == 'gamma' and #ssh == 4, 'SSH entries do not run ssh -t <host> <command>')
check(has(ssh[4], 'infocmp wezterm') and has(ssh[4], 'TERM=xterm-256color') and has(ssh[4], 'exec zellij attach --create main'), 'SSH entries do not fall back to xterm-256color before zellij: ' .. ssh[4])

for _, e in ipairs({ 'update-status', 'format-tab-title', 'bell', 'window-config-reloaded', 'augment-command-palette', 'copied-scrollback', 'open-uri', 'new-tab-button-click' }) do
  check(type(handlers[e]) == 'function', 'no ' .. e .. ' handler')
end

-- Footer.
local status, performed, pasted, sent
local function window(key_table, id)
  return {
    window_id = function() return id or 1 end,
    active_key_table = function() return key_table end,
    set_right_status = function(_, s) status = s end,
    get_selection_text_for_pane = function() return 'src/a.rs:12' end,
    perform_action = function(_, a) performed = a end,
  }
end
-- A pane: `opts` sets its id, domain, OSC 7 cwd, title and foreground process ({ name, argv };
-- false once it has exited). Registered with the stand-in wezterm.mux.get_pane.
local function pane(dims, alt, cursor_y, opts)
  opts = opts or {}
  pasted, sent = {}, {}
  local p = {
    get_dimensions = function() return dims end,
    is_alt_screen_active = function() return alt end,
    get_cursor_position = function() return { y = cursor_y } end,
    pane_id = function() return opts.id or 7 end,
    get_domain_name = function() return opts.domain or 'local' end,
    get_current_working_dir = function() return opts.cwd and wezterm.url.parse(opts.cwd) or nil end,
    get_title = function() return opts.title or 'x' end,
    get_foreground_process_info = function(self) return self.proc or nil end,
    get_lines_as_text = function() return 'line 1\nline 2\n' end,
    paste = function(_, t) pasted[#pasted + 1] = t end,
    send_text = function(_, t) sent[#sent + 1] = t end,
    proc = opts.proc == nil and { name = 'nu.exe', argv = { 'nu.exe' } } or opts.proc,
  }
  live[opts.id or 7] = p
  return p
end
local wide = { cols = 140, viewport_rows = 38, scrollback_rows = 10234, scrollback_top = 0 }
battery = { { state_of_charge = 0.42, state = 'Discharging' } }
handlers['update-status'](window(nil), pane(wide, false, 10233))
check(has(status, '10,234 · 38 rows') and has(status, '42%') and has(status, os.date('%a')), 'footer: ' .. tostring(status))
handlers['update-status'](window(nil), pane(wide, false, 9799))
check(has(status, '9,800/10,234'), 'footer does not show the cursor line once a program moves it up: ' .. status)
handlers['update-status'](window('copy_mode'), pane(wide, true, 0))
check(has(status, 'COPY') and not has(status, 'rows'), 'footer in copy mode over a full-screen app: ' .. status)
handlers['update-status'](window('search_mode'), pane(wide, false, 0))
check(has(status, 'SEARCH'), 'footer has no SEARCH badge: ' .. status)
handlers['update-status'](window('resize_pane'), pane(wide, false, 0))
check(has(status, 'RESIZE'), 'footer has no RESIZE badge: ' .. status)
battery = { { state_of_charge = 1, state = 'Full' } }
handlers['update-status'](window(nil), pane({ cols = 70, viewport_rows = 38, scrollback_rows = 500, scrollback_top = 0 }, false, 499))
check(not has(status, 'rows') and not has(status, '%') and has(status, os.date('%H:%M')), 'narrow footer: ' .. status)

-- Notices.
local w, p = window(nil), pane(wide, false, 10233)
handlers['window-config-reloaded'](w, p)
check(not has(status, 'reloaded'), 'a window opening flashed "Config reloaded"')
handlers['window-config-reloaded'](w, p)
check(has(status, 'Config reloaded'), 'a reload shows no notice: ' .. tostring(status))
keys['CTRL|SHIFT+c'].callback(w, p)
check(performed.action == 'CopyTo' and has(status, 'Copied'), 'Ctrl+Shift+C does not copy and say so')

-- Quick selects type into the pane; Enter only when no full-screen app holds it.
helix.args.action.callback(w, pane(wide, false, 0))
check(pasted[1] == 'hx src/a.rs:12' and sent[1] == '\r', 'Ctrl+Shift+G does not run hx <file:line> at the prompt')
helix.args.action.callback(w, pane(wide, true, 0))
check(pasted[1] == 'hx src/a.rs:12' and #sent == 0, 'Ctrl+Shift+G presses Enter inside a full-screen app')
sha.args.action.callback(w, pane(wide, false, 0))
check(pasted[1] == 'src/a.rs:12' and #sent == 0, 'Ctrl+Shift+Y does not paste the pick')

-- Tab titles: marks, glyphs and names.
local function title(tab, tabs)
  local out = {}
  for _, it in ipairs(handlers['format-tab-title'](tab, tabs or { tab }, nil, nil, false, 32)) do
    if it.Text then out[#out + 1] = it.Text end
  end
  return table.concat(out)
end
local ssh_argv = { 'C:\\Windows\\System32\\OpenSSH\\ssh.exe', '-p', '2222', '-t', 'me@dev10', 'exec zellij attach --create main' }
local sp = pane(wide, true, 0, { id = 7, proc = { name = 'ssh.exe', argv = ssh_argv } })
local ssh_pane = { pane_id = 7, title = 'Zellij (main)', domain_name = 'local', progress = 'None' }
local first = { tab_id = 1, tab_index = 0, is_active = true, tab_title = '', active_pane = { pane_id = 1, title = 'x', progress = 'None' }, panes = {} }
local bg = { tab_id = 2, tab_index = 5, is_active = false, tab_title = '', active_pane = ssh_pane, panes = { { pane_id = 7, has_unseen_output = true } } }
handlers['bell'](w, sp)
check(title(bg, { first, bg }) == ' ! > 2: dev10 ', 'background SSH tab after a bell: [' .. title(bg, { first, bg }) .. ']')
local function tab_bg(tab)
  for _, it in ipairs(handlers['format-tab-title'](tab, { tab }, nil, nil, false, 32)) do
    if it.Background then return it.Background.Color end
  end
end
bg.is_active = true
local host_colour = tab_bg(bg)
check(not wezterm.GLOBAL.bell_panes['7'], 'viewing the tab does not clear its bell mark')
check(host_colour ~= '#cba6f7' and host_colour:match('^#%x+$'), 'an active SSH tab is not filled with its host colour: ' .. tostring(host_colour))
handlers['update-status'](window(nil, 2), sp)
check(has(status, 'dev10 · zellij:main'), 'the footer does not name the SSH host and its zellij session: ' .. status)
local sp_dims = sp.get_dimensions
sp.get_dimensions = function() return { cols = 120, viewport_rows = 38, scrollback_rows = 10, scrollback_top = 0 } end
handlers['update-status'](window(nil, 2), sp)
check(has(status, 'dev10') and not has(status, 'zellij'), 'a narrower footer keeps the zellij session: ' .. status)
sp.get_dimensions = sp_dims
bg.is_active = false
check(title(bg) == ' ● > 1: dev10 ', 'unseen output: [' .. title(bg) .. ']')
check(tab_bg(bg) == '#1e1e2e', 'an inactive SSH tab is not on the bar colour')
bg.tab_title = 'build'
check(title(bg) == ' ● > 1: build ', 'a name set with Ctrl+Shift+E does not win: [' .. title(bg) .. ']')
bg.tab_title = ''
ssh_pane.progress = { Percentage = 42 }
check(has(title(bg), '42%'), 'no progress mark: ' .. title(bg))
ssh_pane.progress = 'Indeterminate'
check(title(bg):sub(1, 3) == ' ~ ', 'no busy mark: ' .. title(bg))
-- On the active tab a mark keeps its colour, so an error % reads as one.
first.active_pane.progress = { Error = 13 }
local mark_item = handlers['format-tab-title'](first, { first }, nil, nil, false, 32)[2]
check(mark_item and mark_item.Foreground and mark_item.Foreground.Color == '#f38ba8', 'an error mark on the active tab is not red')
first.active_pane.progress = 'None'
pane(wide, false, 0, { id = 8, proc = { name = 'pwsh.exe', argv = { 'pwsh.exe' } } })
local win = { tab_id = 4, tab_index = 0, is_active = false, tab_title = '', panes = {},
  active_pane = { pane_id = 8, title = 'C:\\Program Files\\PowerShell\\7\\pwsh.exe', domain_name = 'local', progress = 'None' } }
check(title(win) == ' > 1: pwsh ', '.exe trimming: [' .. title(win) .. ']')
-- The previous tab (Alt+0's, and where closing this one lands) is underlined; the active one never is.
local function underlined(tab)
  for _, it in ipairs(handlers['format-tab-title'](tab, { tab }, nil, nil, false, 32)) do
    if it.Attribute and it.Attribute.Underline == 'Single' then return true end
  end
  return false
end
win.is_last_active = true
check(underlined(win), 'the previous tab is not underlined')
win.is_active = true
check(not underlined(win), 'the active tab is underlined')
win.is_active, win.is_last_active = false, false
check(not underlined(win), 'a tab other than the previous one is underlined')
pane(wide, false, 0, { id = 9, domain = 'WSL:AlmaLinux-9', proc = { name = 'wsl.exe', argv = { 'wsl.exe' } } })
local wsl = { tab_id = 3, tab_index = 0, is_active = false, tab_title = '', panes = {},
  active_pane = { pane_id = 9, title = 'wsl.exe', domain_name = 'WSL:AlmaLinux-9', progress = 'None', current_working_dir = 'file://PC/home/me' } }
check(title(wsl) == ' $ 1: AlmaLinux-9 ', 'a WSL tab is not named after its distro: [' .. title(wsl) .. ']')
-- At rest a WSL tab takes its distro's colour, as an SSH tab takes its host's: muted in the
-- name when inactive, the fill when active.
local alma = package.loaded.appearance.accent('AlmaLinux-9')
local function name_fg(tab)
  local fg
  for _, it in ipairs(handlers['format-tab-title'](tab, { tab }, nil, nil, false, 32)) do
    if it.Foreground then fg = it.Foreground.Color end
    if it.Text and it.Text:find(':', 1, true) then return fg end
  end
end
check(alma ~= '#cba6f7' and name_fg(wsl) == 'dim' .. alma, "an inactive WSL tab's name is not in its distro's colour: " .. tostring(name_fg(wsl)))
wsl.is_active = true
check(tab_bg(wsl) == alma, "an active WSL tab is not filled with its distro's colour: " .. tostring(tab_bg(wsl)))
wsl.is_active = false
wsl.active_pane.current_working_dir = 'file://build01.corp/home/me'
check(title(wsl) == ' > 1: build01.corp ', "a WSL tab that ssh'd elsewhere is not named after that host: [" .. title(wsl) .. ']')
-- A host's real name maps to its ~/.ssh/config.local alias: same name, same colour.
wsl.active_pane.current_working_dir = 'file://atc-alpha/home/me'
check(title(wsl) == ' > 1: alpha ', "a WSL tab on alpha's HostName is not named alpha: [" .. title(wsl) .. ']')
wsl.is_active = true
local wsl_colour = tab_bg(wsl)
wsl.is_active = false
pane(wide, false, 0, { id = 10, proc = { name = 'ssh', argv = { 'ssh', 'me@atc-alpha.corp' } } })
local to_alpha = { tab_id = 5, tab_index = 0, is_active = true, tab_title = '', panes = {}, active_pane = { pane_id = 10, title = 'x', domain_name = 'local', progress = 'None' } }
check(title(to_alpha) == ' > 1: alpha ' and tab_bg(to_alpha) == wsl_colour, 'ssh to a HostName is not the alias tab in its colour: [' .. title(to_alpha) .. ']')
pane(wide, false, 0, { id = 10, proc = { name = 'ssh', argv = { 'ssh', '10.0.0.9' } } })
check(title(to_alpha) == ' > 1: gamma ', 'ssh to an address HostName is not its alias: [' .. title(to_alpha) .. ']')
pane(wide, false, 0, { id = 10, proc = { name = 'ssh', argv = { 'ssh', 'x.example' } } })
check(title(to_alpha) == ' > 1: x.example ', 'a HostName in a block with no alias was mapped: [' .. title(to_alpha) .. ']')
pane(wide, false, 0, { id = 10, proc = { name = 'ssh', argv = { 'ssh', 'y.example' } } })
check(title(to_alpha) == ' > 1: y.example ', "a Match block's HostName was mapped to the Host above it: [" .. title(to_alpha) .. ']')
pane(wide, false, 0, { id = 10, proc = { name = 'ssh', argv = { 'ssh', '10.0.0.10' } } })
check(title(to_alpha) == ' > 1: 10.0.0.10 ', 'an address HostName gave its first number as a short name: [' .. title(to_alpha) .. ']')
-- A host sending no OSC 7 but its own user@host title names the tab; this machine's
-- title (zshrc/bashrc set it at each prompt under WezTerm) puts it back.
wsl.active_pane.current_working_dir = 'file://PC/home/me'
wsl.active_pane.title = 'me@cache-apl:~'
check(title(wsl) == ' > 1: cache-apl ', 'a WSL tab on a host that sets only its title is not named after it: [' .. title(wsl) .. ']')
wsl.active_pane.title = 'me@PC:~/src'
check(title(wsl) == ' $ 1: AlmaLinux-9 ', 'a WSL tab back from ssh is not named after its distro: [' .. title(wsl) .. ']')
wsl.tab_title = string.rep('n', 60)
check(#title(wsl) <= 32, 'a long name overflows max_width: ' .. #title(wsl))

-- The footer names the host a WSL tab has ssh'd to (OSC 7, else a user@host title).
local wsl_proc = { name = 'wsl.exe', argv = { 'wsl.exe' } }
handlers['update-status'](window(nil, 3), pane(wide, false, 0, { id = 44, domain = 'WSL:AlmaLinux-9', cwd = 'file://build01.corp/home/me', proc = wsl_proc }))
check(has(status, 'build01.corp'), "the footer does not name the host a WSL tab has ssh'd to: " .. status)
handlers['update-status'](window(nil, 3), pane(wide, false, 0, { id = 45, domain = 'WSL:AlmaLinux-9', cwd = 'file://PC/home/me', title = 'me@cache-apl:~', proc = wsl_proc }))
check(has(status, 'cache-apl'), 'the footer does not name a host known only from its title: ' .. status)
handlers['update-status'](window(nil, 3), pane(wide, false, 0, { id = 46, domain = 'WSL:AlmaLinux-9', cwd = 'file://PC/home/me', title = 'me@PC:~', proc = wsl_proc }))
check(not has(status, 'PC'), 'the footer names this machine as a WSL tab\'s host: ' .. status)

-- New tabs and splits: WezTerm's default, except a WSL pane whose directory isn't in the
-- distro starts in ~ (wsl.exe --cd ~), and an SSH tab's run its ssh again.
local function spawned(k, opts)
  keys[k].callback(w, pane(wide, false, 0, opts))
  return performed
end
local function wsl_at(cwd) return { id = 40, domain = 'WSL:AlmaLinux-9', cwd = cwd, proc = { name = 'wsl.exe', argv = { 'wsl.exe' } } } end
local t = spawned('CTRL|SHIFT+t', wsl_at('file://PC/home/me/src'))
check(t.action == 'SpawnCommandInNewTab' and t.args.domain == 'CurrentPaneDomain' and t.args.cwd == nil, 'Ctrl+Shift+T in a WSL tab does not follow its OSC 7')
for _, cwd in ipairs({ false, 'file:///C:/Users/me/', 'file://build01.corp/home/me' }) do
  t = spawned('CTRL|SHIFT+t', wsl_at(cwd or nil))
  check(t.args.domain.DomainName == 'WSL:AlmaLinux-9' and t.args.cwd == '~', 'Ctrl+Shift+T in a WSL tab at ' .. tostring(cwd) .. ' does not start in ~')
end
t = spawned('ALT|SHIFT+D', wsl_at('file://build01.corp/home/me'))
check(t.action == 'SplitVertical' and t.args.cwd == '~', "Alt+Shift+D in a WSL tab that ssh'd elsewhere does not start in ~")
t = spawned('ALT|SHIFT+R', { id = 41, cwd = 'file://PC/C:/src' })
check(t.action == 'SplitHorizontal' and t.args.domain == 'CurrentPaneDomain', 'Alt+Shift+R in a local tab is not the default split')
t = spawned('CTRL|SHIFT+t', { id = 43, domain = 'WSL:AlmaLinux-9', cwd = 'file://PC/home/me', title = 'me@cache-apl:~', proc = wsl_proc })
check(t.args.cwd == '~', "Ctrl+Shift+T in a WSL tab on a host known from its title does not start in ~")
local ssh_tab = { id = 47, proc = { name = 'ssh.exe', argv = ssh_argv } }
t = spawned('CTRL|SHIFT+t', ssh_tab)
check(t.action == 'SpawnCommandInNewTab' and t.args.args == ssh_argv and t.args.domain.DomainName == 'local', 'Ctrl+Shift+T in an SSH tab does not open another ssh to its host')
t = spawned('ALT|SHIFT+D', ssh_tab)
check(t.action == 'SplitVertical' and t.args.args == ssh_argv and t.args.domain.DomainName == 'local', 'Alt+Shift+D in an SSH tab does not split onto its host')
-- Ctrl+Alt+T: never another ssh. An SSH tab's is the default shell here, in the directory
-- its ssh started from (home once ssh has exited); any other tab's is Ctrl+Shift+T's.
t = spawned('CTRL|ALT+t', { id = 48, proc = { name = 'ssh.exe', argv = ssh_argv, cwd = 'C:\\src' } })
check(t.action == 'SpawnCommandInNewTab' and t.args.args == nil and t.args.domain.DomainName == 'local' and t.args.cwd == 'C:\\src',
  "Ctrl+Alt+T in an SSH tab is not a local shell in ssh's directory: " .. tostring(t.args.args and t.args.args[1]) .. ' ' .. tostring(t.args.cwd))
t = spawned('CTRL|ALT+t', { id = 48, proc = false })
check(t.args.args == nil and t.args.domain.DomainName == 'local' and t.args.cwd == wezterm.home_dir, 'Ctrl+Alt+T in an SSH tab whose ssh has exited does not start at home: ' .. tostring(t.args.cwd))
t = spawned('CTRL|ALT+t', wsl_at('file://build01.corp/home/me'))
check(t.args.domain.DomainName == 'WSL:AlmaLinux-9' and t.args.cwd == '~', "Ctrl+Alt+T in a WSL tab that ssh'd elsewhere is not Ctrl+Shift+T's ~")
t = spawned('CTRL|ALT+t', { id = 41, cwd = 'file://PC/C:/src' })
check(t.args.domain == 'CurrentPaneDomain' and t.args.args == nil, 'Ctrl+Alt+T in a local tab is not the default new tab')
for button, k in pairs({ Left = 'CTRL|SHIFT+t', Middle = 'CTRL|SHIFT+s', Right = 'CTRL|ALT+l' }) do
  performed = nil
  check(handlers['new-tab-button-click'](w, p, button) == false and performed == keys[k], button .. '-click on + is not ' .. k)
end

-- Reconnect: reruns the ssh seen in the pane after it has exited; elsewhere it says why not.
sp.proc = false
keys['CTRL|SHIFT+F5'].callback(w, sp)
check(performed.action == 'SpawnCommandInNewTab' and performed.args.args == ssh_argv and performed.args.domain.DomainName == 'local', 'Ctrl+Shift+F5 does not rerun the exited ssh')
keys['CTRL|SHIFT+F5'].callback(w, pane(wide, false, 0, { id = 20 }))
check(has(status, 'nothing to reconnect'), 'Ctrl+Shift+F5 in a local shell says nothing: ' .. tostring(status))

-- File links: over the same ssh with -t; inside the WSL distro; a remote host's from WSL
-- says so; anything else falls through to WezTerm.
check(handlers['open-uri'](w, sp, 'file://dev10/home/me/it%27s%20here.c') == false, 'a file link in an SSH tab falls through')
local a = performed.args.args
check(table.concat(a, ' ', 2) == "-t -p 2222 -t me@dev10 hx '/home/me/it'\\''s here.c'", 'SSH file link: ' .. table.concat(a, ' '))
sp.proc = { name = 'nu.exe', argv = { 'nu.exe' } }
check(not has(title(bg), 'dev10'), 'a shell back from ssh still shows the old host: [' .. title(bg) .. ']')
local wp = pane(wide, false, 0, { id = 21, domain = 'WSL:AlmaLinux-9', proc = { name = 'wsl.exe', argv = { 'wsl.exe' } } })
check(handlers['open-uri'](w, wp, 'file://PC/home/me/a%20b.txt') == false, 'a WSL file link falls through')
check(performed.args.domain.DomainName == 'WSL:AlmaLinux-9' and performed.args.args[1] == 'sh' and performed.args.args[5] == '/home/me/a b.txt', 'WSL file link does not open hx in the distro')
check(handlers['open-uri'](w, wp, 'file://build01/home/me/x') == false and has(status, 'build01'), 'a remote file link in a WSL tab is not explained')
check(handlers['open-uri'](w, wp, 'https://example.com/') == nil, 'an https link does not fall through to WezTerm')
check(handlers['open-uri'](w, pane(wide, false, 0, { id = 22 }), 'file://PC/C:/x.txt') == nil, 'a Windows file link does not fall through to WezTerm')

-- Scrollback in helix: a temp file, opened on the pane's machine; an SSH tab is refused.
keys['CTRL|SHIFT+o'].callback(w, pane(wide, false, 0, { id = 23 }))
local file = performed.args.args[#performed.args.args]
local fh = io.open(file, 'r')
check(fh and fh:read('*a') == 'line 1\nline 2\n', 'Ctrl+Shift+O did not write the scrollback to ' .. tostring(file))
if fh then fh:close() end
check(performed.args.domain.DomainName == 'local' and has(performed.args.args[1], 'hx'), 'Ctrl+Shift+O does not open helix locally')
keys['CTRL|SHIFT+o'].callback(w, pane(wide, false, 0, { id = 24, domain = 'WSL:AlmaLinux-9', proc = { name = 'wsl.exe', argv = { 'wsl.exe' } } }))
check(performed.args.domain.DomainName == 'WSL:AlmaLinux-9' and performed.args.args[1] == 'sh' and not performed.args.args[5]:find('\\', 1, true), 'Ctrl+Shift+O does not open helix in the WSL distro on a Linux path')
keys['CTRL|SHIFT+o'].callback(w, pane(wide, true, 0, { id = 25, proc = { name = 'ssh', argv = { 'ssh', 'dev10' } } }))
check(has(status, 'zellij'), 'Ctrl+Shift+O in an SSH tab does not point at zellij: ' .. tostring(status))

-- Mouse release: says Copied only when something was selected.
mouse['NONE+Up1'].args[2].callback(w, p)
check(has(status, 'Copied'), 'a mouse selection does not say Copied')

-- Tab switcher: real numbers, the host beside an SSH tab, activates the pick.
local activated
local function mtab(id, title, p)
  return { tab_id = function() return id end, get_title = function() return title end, active_pane = function() return p end, activate = function() activated = id end }
end
local sw = window(nil)
sw.active_tab = function() return { tab_id = function() return 31 end } end
local tp = pane(wide, false, 0, { id = 30, proc = { name = 'ssh', argv = { 'ssh', 'dev10' } } })
tp.get_title = function() return 'zellij' end
sw.mux_window = function() return { tabs = function() return { mtab(31, 'notes', pane(wide, false, 0, { id = 32 })), mtab(33, '', tp) } end } end
keys['CTRL|SHIFT+s'].callback(sw, p)
local labels = {}
for _, ch in ipairs(performed.args.choices) do labels[#labels + 1] = ch.label end
check(labels[1] == '● 1: notes' and labels[2] == '  2: zellij  [dev10]', 'tab switcher rows: ' .. table.concat(labels, ' | '))
performed.args.action.callback(sw, p, '33')
check(activated == 33, 'the tab switcher does not activate the pick')

-- Cheatsheet: the custom keys, WezTerm's defaults, and launch rows that open their entry.
keys['CTRL|SHIFT+h'].callback(w, p)
check(performed.action == 'InputSelector', 'Ctrl+Shift+H does not open the cheatsheet')
local rows, launch = {}, 0
for _, r in ipairs(performed.args.choices) do
  rows[#rows + 1] = r.label
  if r.id then launch = launch + 1 end
end
local text = table.concat(rows, '\n')
for _, k in ipairs({ 'Ctrl+Alt+L', 'Ctrl+Alt+S', 'Ctrl+Shift+T', 'Ctrl+Alt+T', 'Alt+Shift+D', 'Alt+Shift+arrows', 'Ctrl(+Shift)+Up / Down', 'Ctrl+Shift+Left / Right', 'Ctrl+Shift+A', 'Ctrl+Shift+C', 'Ctrl+Insert', '+ on the tab bar', 'Ctrl+Shift+E', 'Ctrl+Shift+G', 'Ctrl+Shift+Y', 'Ctrl+Shift+H', 'Ctrl+Shift+W', 'Ctrl+Shift+S', 'Alt+0', 'Ctrl+Shift+Q', 'Alt+Shift+S', 'Ctrl+Shift+F5', 'Ctrl+Shift+O', 'Ctrl+click', 'Shift+click', 'Ctrl+triple-click', 'Ctrl+Shift+F', 'drop a file', 'images', '#123' }) do
  check(has(text, k .. ' '), 'the cheatsheet has no ' .. k .. ' row')
end
check(launch == #c.launch_menu, 'the cheatsheet lists ' .. launch .. ' launch rows for ' .. #c.launch_menu .. ' entries')
performed.args.action.callback(w, p, '1')
check(performed.action == 'SpawnCommandInNewTab' and performed.args == c.launch_menu[1], 'a launch row does not open its entry')
local palette = handlers['augment-command-palette']()
check(#palette == 13 and palette[1].action == keys['CTRL|SHIFT+h'], 'the command palette does not list the custom actions')
local briefs = {}
for _, e in ipairs(palette) do briefs[e.brief] = e.action end
check(briefs['Split pane down'] == keys['ALT|SHIFT+D'] and briefs['Split pane right'] == keys['ALT|SHIFT+R'], 'the command palette has no Alt+Shift+D/R splits')
check(briefs['SSH hosts: connect, add, edit or delete'] == keys['CTRL|ALT+s'], 'the command palette has no SSH host editor')

-- Ctrl+Alt+S: the SSH host editor over ~/.ssh/config.local (sshconfig.lua's own cases are
-- scripts/test-wezterm-sshconfig.sh). Each pick or answer goes to the callback WezTerm
-- would call; the file is put back at the end, for the next triple's run.
local conf = home .. '/.ssh/config.local'
local function slurp()
  local fh = io.open(conf, 'rb')
  local s = fh:read('*a')
  fh:close()
  return s
end
local original = slurp()
local function pick(match)
  for _, ch in ipairs(performed.args.choices) do
    if has(ch.label, match) then return performed.args.action.callback(w, p, ch.id, ch.label) end
  end
  error('no "' .. match .. '" row in: ' .. tostring(performed.args.title), 0)
end
local function answer(line) performed.args.action.callback(w, p, line) end
local function open_host(name, item)
  keys['CTRL|ALT+s'].callback(w, p)
  pick(name .. ' ')
  if item then pick(item) end
end
keys['CTRL|ALT+s'].callback(w, p)
check(performed.action == 'InputSelector', 'Ctrl+Alt+S does not open the host list')
local rows = {}
for _, ch in ipairs(performed.args.choices) do rows[#rows + 1] = ch.label end
check(#rows == 4 and has(rows[1], 'Add') and has(rows[2], 'alpha ') and has(rows[2], 'atc-alpha.corp') and has(rows[4], 'gamma ') and has(rows[4], '10.0.0.9'),
  'the host list is not Add, then each host and its address: ' .. table.concat(rows, ' | '))
-- Add: a name (a taken one is asked again, saying why), an address, a note; the save
-- reloads the config, and the reload's notice names the host.
pick('Add')
check(performed.action == 'PromptInputLine' and performed.args.initial_value == '', 'Add does not ask for a name')
answer('Alpha')
check(performed.action == 'PromptInputLine' and has(performed.args.description, 'already') and performed.args.initial_value == 'Alpha',
  'a taken name is not asked for again with the reason: ' .. tostring(performed.args.description))
answer('delta')
check(performed.action == 'PromptInputLine' and has(performed.args.description, 'delta'), 'Add does not ask for the address')
answer('me@delta.corp:99999')
check(performed.action == 'PromptInputLine' and has(performed.args.description, 'port') and performed.args.initial_value == 'me@delta.corp:99999', 'a bad port is not asked for again with the reason')
answer('me@delta.corp:2200')
check(performed.action == 'PromptInputLine' and performed.args.initial_value == '', 'Add does not ask for a note')
answer('the db box')
check(has(slurp(), 'atc-alpha.corp\nHost delta\n  # the db box\n  HostName delta.corp\n  User me\n  Port 2200\nHost *.corp\n'), 'Add did not write the block before Host *.corp: ' .. slurp())
check(performed.action == 'ReloadConfiguration', 'a save does not reload the config, so the launcher would not list it')
handlers['window-config-reloaded'](w, p)
check(has(status, 'delta'), 'the reload after a save does not name the host: ' .. tostring(status))
-- Columns: name, address, note, each padded to its longest, no separator glyph, no
-- trailing spaces on a row without a note.
keys['CTRL|ALT+s'].callback(w, p)
rows = {}
for _, ch in ipairs(performed.args.choices) do rows[#rows + 1] = ch.label end
check(rows[4] == 'delta  me@delta.corp:2200  the db box' and rows[2] == 'alpha  atc-alpha.corp' and rows[5] == 'gamma  10.0.0.9',
  'the host list is not in aligned columns: ' .. table.concat(rows, ' | '))
-- Esc at any prompt leaves the file as it was.
local before = slurp()
keys['CTRL|ALT+s'].callback(w, p)
pick('Add')
answer('epsilon')
answer(nil)
check(slurp() == before and performed.action == 'PromptInputLine', 'Esc at a prompt saved something')
-- A host: connect (the launcher's command), edit (prefilled), delete (asks first).
open_host('alpha', 'Connect')
check(performed.action == 'SpawnCommandInNewTab' and performed.args.domain.DomainName == 'local' and table.concat(performed.args.args, ' ') == table.concat(c.launch_menu[#c.launch_menu - 2].args, ' '),
  "Connect does not run the launcher's ssh: " .. table.concat(performed.args.args or {}, ' '))
open_host('gamma', 'Edit')
check(performed.args.initial_value == 'gamma', 'Edit does not start from the name: ' .. tostring(performed.args.initial_value))
answer('gamma')
check(performed.args.initial_value == '10.0.0.9', 'Edit does not start from the address: ' .. tostring(performed.args.initial_value))
answer('root@10.0.0.9')
answer('')
check(has(slurp(), '  host = gamma # comment\n  HostName = 10.0.0.9\n  User root\nMatch host foo\n'), 'Edit did not add User in place: ' .. slurp())
open_host('delta', 'Delete')
check(performed.action == 'InputSelector' and has(performed.args.choices[1].label, 'No'), 'Delete does not ask first, with No first')
pick('No')
check(has(slurp(), 'Host delta'), 'No deleted the host')
open_host('delta', 'Delete')
pick('Yes')
check(not has(slurp(), 'delta') and performed.action == 'ReloadConfiguration', 'Yes did not delete the host and reload: ' .. slurp())
-- A file it can't write: the footer says so, nothing reloads.
os.execute('chmod 444 "' .. conf .. '"')
performed = nil
open_host('beta', 'Delete')
pick('Yes')
os.execute('chmod 644 "' .. conf .. '"')
check(has(status, 'Could not write') and performed.action ~= 'ReloadConfiguration', 'a failed write is not reported: ' .. tostring(status))
local fh = io.open(conf, 'wb')
fh:write(original)
fh:close()
io.write('ok')
LUA
  # Every other .lua beside it is a module wezterm.lua links (require), checked as loaded.
  modules=$(find "${cfg%/*}" -maxdepth 1 -name '*.lua' ! -name wezterm.lua -printf '%f\n' | sed 's/\.lua$//' | sort | paste -sd, -)
  for triple in x86_64-pc-windows-msvc x86_64-unknown-linux-gnu; do
    # Ctrl+Shift+O writes under TEMP (as the Windows triple, $tmp/t\name: a file in $tmp).
    out=$(TEMP="$tmp/t" "${lua[@]}" "$tmp/check.lua" "$cfg" "$triple" "$tmp" "$tmp/la" "$modules" 2>&1)
    if [ "$out" = ok ]; then
      ok "$cfg and its modules (${modules//,/, }) run as $triple: theme, chrome, cursor, TERM, keys, mouse, launcher, new tabs and splits, footer, notices, SSH tabs and host aliases, the SSH host editor, file links, scrollback, tab marks, cheatsheet"
    else
      bad "$cfg as $triple: $out"
    fi
  done
  rm -rf "$tmp"
  # reedline sets the cursor at every prompt, so a steady shape there stops the blink in Nushell tabs.
  if grep -qxF '$env.config.cursor_shape.emacs = "blink_line"' dotfiles/windows/AppData/Roaming/nushell/config.nu.tera; then
    ok "Nushell asks for WezTerm's blinking bar"
  else
    bad "config.nu.tera's cursor_shape.emacs isn't \"blink_line\": a steady shape stops the cursor blinking in Nushell tabs"
  fi
}

# TERM=wezterm needs its whole chain, or a host shows "unknown terminal" / loses colour:
# the vendored entry must compile with its extended capabilities, the final hook must
# compile it, dircolors must match the name, and the Windows shells must drop it (Windows
# has no terminfo database). The rc-file fallbacks run in scripts/test-term-fallback.sh.
check_wezterm_term() {
  hdr "TERM=wezterm chain (terminfo, final hook, dircolors, Windows shells)"
  local src=dotfiles/config/wezterm/wezterm.terminfo tmp caps missing=()
  grep -qx 'TERM wezterm' dotfiles/dircolors || missing+=("dotfiles/dircolors has no 'TERM wezterm' line (ls loses its colours)")
  grep -qE '^"final" = ".*::: wezterm-terminfo' config.linux.toml || missing+=("config.linux.toml's final hook doesn't run wezterm-terminfo")
  grep -qF 'if ($env.TERM? == "wezterm") { $env.TERM = "xterm-256color" }' dotfiles/windows/AppData/Roaming/nushell/config.nu.tera ||
    missing+=("config.nu.tera doesn't switch TERM=wezterm to xterm-256color")
  grep -qF "if (\$env:TERM -eq 'wezterm') { \$env:TERM = 'xterm-256color' }" dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera ||
    missing+=("the PowerShell profile doesn't switch TERM=wezterm to xterm-256color")
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "final hook compiles it; dircolors matches it; Nushell and PowerShell switch it to xterm-256color"
  else
    for m in "${missing[@]}"; do bad "$m"; done
  fi
  if ! command -v tic >/dev/null 2>&1 || ! command -v infocmp >/dev/null 2>&1; then
    note "tic/infocmp not on PATH — skipped compiling $src"
    return 0
  fi
  tmp=$(mktemp -d)
  if tic -x -o "$tmp" "$src" 2>"$tmp/err" && caps=$(TERMINFO="$tmp" infocmp -x wezterm 2>&1); then
    if grep -qw Tc <<<"$caps" && grep -q 'Smulx=' <<<"$caps" && grep -q 'Setulc=' <<<"$caps"; then
      ok "$src compiles with tic -x and keeps Tc, Smulx and Setulc"
    else
      bad "$src compiled without Tc / Smulx / Setulc"
    fi
  else
    bad "$src does not compile: $(cat "$tmp/err")"
  fi
  rm -rf "$tmp"
}

# PowerShell runs a built-in alias before a function of the same name, so a profile
# function named like one (gc, gp, gl) never runs unless the profile removes that alias
# first. The names are Windows PowerShell 5.1's and pwsh 7's built-in aliases.
check_ps_alias_shadow() {
  hdr "PowerShell profile functions aren't shadowed by built-in aliases"
  py_report "ps-alias" <<'PY'
import re
builtin = set("""% ? ac asnp cat cd chdir clc clear clhy cli clp cls clv cnsn compare copy cp cpi cpp curl
cvpa dbp del diff dir dnsn ebp echo epal epcsv epsn erase etsn exsn fc fl foreach ft fw gal gbp gc gci
gcm gcs gdr ghy gi gjb gl gm gmo gp gps gpv group gsn gsnp gsv gu gv gwmi h history icm iex ihy ii ipal
ipcsv ipmo ipsn irm ise iwmi iwr kill lp ls man md measure mi mount move mp mv nal ndr ni nmo npssc nsn
nv ogv oh popd ps pushd pwd r rbp rcjb rcsn rd rdr ren ri rjb rm rmdir rmo rni rnp rp rsn rsnp rujb rv
rvpa rwmi sajb sal saps sasv sbp sc select set shcm si sl sleep sls sort sp spjb spps spsv start sujb sv
swmi tee trcm type wget where wjb write""".split())
f = "dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera"
text = open(f, encoding="utf-8").read()
funcs = {m.lower() for m in re.findall(r"(?mi)^\s*function\s+(?:global:)?([\w.-]+)", text)}
removed = set()
for line in text.splitlines():
    if re.search(r"Remove-Item\s+[\"']?Alias:", line, re.I):
        removed |= {n.lower() for n in re.findall(r"'([\w.-]+)'", line)}
        removed |= {n.lower() for n in re.findall(r"Alias:([\w.-]+)", line)}
bad = sorted((funcs & builtin) - removed)
if bad:
    print("FAIL|alias|" + ", ".join(bad) + f" in {f} are built-in aliases: remove each (Remove-Item Alias:<name> -Force) before the function")
else:
    print(f"PASS|alias|{len(funcs)} profile functions; the {len(funcs & builtin)} named like built-in aliases have them removed")
PY
}

# An npm tool that compiles at install (allow_builds runs node-gyp) needs Python >= 3.8 and a
# C++20 g++, which EL8 lacks: eager, it would fail the tools phase there and stop `wsu`.
check_lazy_builds() {
  hdr "tools that compile at install are lazy"
  py_report "lazy-builds" <<'PY'
import tomllib
eager, n = [], 0
for f in ("config.toml", "config.linux.toml"):
    with open(f, "rb") as fh:
        tools = tomllib.load(fh).get("tools", {})
    for key, val in tools.items():
        if isinstance(val, dict) and val.get("allow_builds"):
            n += 1
            if val.get("lazy") is not True:
                eager.append(f"{f}:{key}")
if eager:
    print("FAIL|lazy|" + "; ".join(eager) + " set allow_builds without lazy = true (an EL8 host fails the build)")
else:
    print(f"PASS|lazy|{n} tool(s) with allow_builds, all lazy")
PY
}

check_debugger_config() {
  hdr "gdb and valgrind config (~/.gdbinit loads in gdb 8.2-17; ~/.valgrindrc starts every tool)"
  # valgrind reads ~/.valgrindrc as whitespace-separated options: a `#` is an option
  # ("Unknown option: #") and an unprefixed tool option (--leak-check) stops every other
  # tool, so only core options go bare and the rest carry --<tool>:.
  local rc=dotfiles/valgrindrc opt bare=() core=" --num-callers "
  if grep -q '#' "$rc"; then
    bad "$rc has a '#': valgrind takes it as an option and refuses to start (notes go in config.linux.toml)"
  else
    for opt in $(cat "$rc"); do
      case "$opt" in
      --[a-z]*:*) ;;
      *) [[ $core == *" ${opt%%=*} "* ]] || bare+=("$opt") ;;
      esac
    done
    if [ "${#bare[@]}" -eq 0 ]; then
      ok "$rc: no comments; tool options carry --<tool>: (bare only:$core)"
    else
      bad "$rc: prefix these with --memcheck: (or add a core option to the list here): ${bare[*]}"
    fi
  fi
  # gdb 16/17 and pwndbg read ~/.config/gdb/gdbinit INSTEAD of ~/.gdbinit; gdb 8.2 never does.
  if [ -e dotfiles/config/gdb/gdbinit ]; then
    bad "dotfiles/config/gdb/gdbinit would replace ~/.gdbinit in gdb 16/17 and pwndbg; keep settings in dotfiles/gdbinit.tera"
  else
    ok "no ~/.config/gdb/gdbinit to shadow ~/.gdbinit"
  fi
  # The python block runs under EL8's /usr/bin/gdb (Python 3.6) too.
  py_report "gdbinit python check" dotfiles/gdbinit.tera <<'PY'
import ast, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^python\n(.*?)^end$", text, re.M | re.S)
if not m:
    print("FAIL|gdbinit|dotfiles/gdbinit.tera has no python ... end block")
    sys.exit()
src = re.sub(r"\{\{.*?\}\}", "X", m[1])
try:
    ast.parse(src, feature_version=(3, 6))
    print("PASS|gdbinit|dotfiles/gdbinit.tera's python block parses as Python 3.6 (EL8's gdb)")
except SyntaxError as e:
    print(f"FAIL|gdbinit|dotfiles/gdbinit.tera's python block isn't Python 3.6: line {e.lineno}: {e.msg}")
PY
}

check_helix_config() {
  hdr "helix config (custom theme present; one OSC 52 clipboard line for the Windows swap)"
  local cfg=dotfiles/config/helix/config.toml theme n
  # helix falls back to its default theme without a word when `theme =` names no theme.
  theme=$(sed -n 's/^theme *= *"\([^"]*\)".*/\1/p' "$cfg")
  if [ -f "dotfiles/config/helix/themes/$theme.toml" ]; then
    ok "theme \"$theme\" is dotfiles/config/helix/themes/$theme.toml"
  else
    bad "$cfg: theme \"$theme\" has no dotfiles/config/helix/themes/$theme.toml (helix would silently use its default)"
  fi
  # The Windows template replaces this exact line with clipboard-provider = "windows".
  n=$(grep -c '^clipboard-provider = "termcode"$' "$cfg" || true)
  if [ "$n" -eq 1 ]; then
    ok "$cfg: one clipboard-provider = \"termcode\" line for the Windows template's replace"
  else
    bad "$cfg: want exactly one 'clipboard-provider = \"termcode\"' line (found $n); the Windows template replaces it"
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
# --- ws (scripts/ws): compiles, and every shell reaches it the same way ----------
# One program behind every shell's `ws` and `wsh`, so the four wrappers must call it (and
# wsh must be `ws help`, the catalogue, not a heredoc that drifts from it). The bash and zsh
# bodies are the same but for WS_SHELL and the prompt insert. ws.py itself must stay
# parseable by EL8's python3.6, so a hook that reaches it early prints a message.
check_ws() {
  hdr "ws (scripts/ws: compiles; zsh, bash, Nushell and PowerShell wrappers)"
  local f out n=0 errs=0 zsh_body bash_body
  if [ -n "$PY" ]; then
    if out=$(
      "$PY" - <<'PY' 2>&1
import ast, pathlib, sys
bad = []
for p in sorted(pathlib.Path("scripts/ws").rglob("*.py")):
    try:
        compile(p.read_text(encoding="utf-8"), str(p), "exec")
    except SyntaxError as e:
        bad.append(f"{p}: {e}")
tree = ast.parse(pathlib.Path("scripts/ws/ws.py").read_text(), feature_version=(3, 6))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    ); then
      ok "scripts/ws: every .py compiles; ws.py parses as Python 3.6"
    else
      bad "scripts/ws doesn't compile: $out"
    fi
  else
    note "no python with tomllib — skipped compiling scripts/ws (CI enforces)"
  fi
  for f in dotfiles/zshrc.tera dotfiles/bashrc.tera; do
    grep -q 'python-cli "$HOME/.config/mise/scripts/ws/ws.py" "$@"' "$f" || {
      bad "$f: ws() doesn't run scripts/ws/ws.py through python-cli"
      errs=$((errs + 1))
    }
    n=$((n + 1))
  done
  grep -q 'join scripts ws ws.py) \.\.\.\$args' dotfiles/windows/AppData/Roaming/nushell/config.nu.tera || {
    bad "config.nu.tera: ws doesn't run scripts/ws/ws.py"
    errs=$((errs + 1))
  }
  grep -qF "Join-Path \$env:WORKSTATION_REPO 'scripts\\ws\\ws.py') @args" dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera || {
    bad "PowerShell profile: ws doesn't run scripts\\ws\\ws.py"
    errs=$((errs + 1))
  }
  for f in dotfiles/zshrc.tera dotfiles/bashrc.tera dotfiles/windows/AppData/Roaming/nushell/config.nu.tera dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera; do
    if ! grep -qE '^(wsh\(\) \{$|def wsh \[\] \{ ws help \}$|function wsh \{ ws help \}$)' "$f" || grep -q "^workstation aliases\|^workstation commands" "$f"; then
      bad "$f: wsh must be \`ws help\` (the catalogue), not its own text"
      errs=$((errs + 1))
    fi
    # wsa's logic is ws apply's (scripts/ws/wslib/apply.py): a profile only hands over.
    if ! grep -qxE 'wsa\(\) \{ ws apply "\$@"; \}|def --wrapped wsa \[\.\.\.args\] \{ ws apply \.\.\.\$args \}|function wsa \{ ws apply @args \}' "$f"; then
      bad "$f: wsa must be one line calling \`ws apply\`, not its own apply logic"
      errs=$((errs + 1))
    fi
  done
  zsh_body=$(sed -n '/^ws() {/,/^}/p' dotfiles/zshrc.tera | grep -v -e 'WS_SHELL=' -e 'print -z')
  bash_body=$(sed -n '/^ws() {/,/^}/p' dotfiles/bashrc.tera | grep -v -e 'WS_SHELL=' -e 'read -r -e' -e 'history -s' -e 'eval "$cmd"' -e '^  fi$' -e 'bash has no print -z')
  if [ "$zsh_body" != "$bash_body" ]; then
    bad "ws() in zshrc.tera and bashrc.tera differ beyond WS_SHELL and the prompt insert:"
    diff <(printf '%s\n' "$zsh_body") <(printf '%s\n' "$bash_body") | sed 's/^/       /' | head -20
    errs=$((errs + 1))
  fi
  [ "$errs" -eq 0 ] && ok "ws, wsh and wsa in zshrc/bashrc (same ws body), config.nu and the PowerShell profile call scripts/ws/ws.py"
}

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
check_git_pull_prune
check_sentinels
check_tools_block
check_mise_config_files
check_bootstrap_config
check_toolchain_shadow
check_lazy_builds
check_ps_alias_shadow
check_dotfiles_config
check_completion_parity
check_warp_guards
check_zellij_config
check_fastfetch_config
check_zed_settings
check_shell_highlight_parity
check_colorterm
check_debugger_config
check_helix_config
check_ws
check_wezterm_config
check_wezterm_term
check_claude_config
check_disk_budget
check_layout
# The test suites and linters take most of the time and share nothing.
run_parallel check_lsp_plugin check_claude_mods check_mise_install_lib check_bootstrap check_self_tests check_shellcheck check_shfmt check_gitleaks
echo
if [ "$fails" -eq 0 ]; then
  printf '%s✓ all invariant checks passed%s\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%s✗ %d invariant check(s) failed%s\n' "$RED" "$fails" "$RESET"
  exit 1
fi
