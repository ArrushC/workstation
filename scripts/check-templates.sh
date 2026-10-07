#!/usr/bin/env bash
# check-templates.sh — render every dotfiles/**/*.tera template into a
# throwaway target $HOME, for each real MISE_ENV token set, and syntax-check
# the rendered output. Tera's {% %} syntax needs mise itself to render.
#
# mise's global-config discovery has a FALLBACK. Measured on 2026-09-19
# (mise 2026.9.9):
#   HOME=X mise …  and X/.config/mise/config.toml EXISTS  -> X's config loads
#   HOME=X mise …  and X/.config/mise         is ABSENT   -> mise falls back
#                                                            to the REAL
#                                                            account home's
#                                                            ~/.config/mise
# So a scratch HOME with no config of its own renders whatever the account
# home has: another checkout's templates, or nothing at all on a CI runner.
# Each scratch HOME below therefore gets its own .config/mise (make_home):
# this checkout's entries symlinked in, dotfiles/ copied (so the
# post-dotfiles chmod hook can't touch the real source), and a
# config.local.toml with the name/email the templates read. MISE_CONFIG_DIR and the
# cwd point there too, the same setup as check-invariants.sh's MISE_ENV
# render check. The dotfiles TARGET side ("~/...") honors the per-call
# `HOME=`, which keeps every render off the real $HOME.
#
# Design (ONE
# broken template aborts the WHOLE `mise dot apply`/`mise bootstrap`, and
# writes nothing at all — so a bulk run alone can never name the culprit):
#   1. For each real MISE_ENV token set (ENVS below), discover which
#      `mode = "template"` [dotfiles] entries are ACTIVE under that set (a
#      pure TOML read — config.toml is always active, config.<TOKEN>.toml is
#      active iff TOKEN is one of the MISE_ENV tokens; mirrors
#      check-invariants.sh's check_dotfiles_config and the Global
#      Constraints' file-to-token mapping).
#   2. INDIVIDUALLY apply + syntax-check every active target into one shared
#      scratch $HOME (one `mise dot apply --force --yes -- <target>` per
#      target) — a failure here names the exact target and env.
#   3. Only if every individual target passed, do ONE bulk
#      `mise bootstrap --only dotfiles --force-dotfiles --yes` into a FRESH
#      scratch $HOME (the actual operation bootstrap.sh/bootstrap.ps1 runs on
#      a real host) and re-check every rendered file there too — cheap
#      insurance against individual/bulk render divergence.
#
# Renders happen on Linux, so Tera's os() reports "linux" and exec(command=
# "uname -r") reports THIS host's kernel: Windows-target templates (helix
# config.toml, config.nu, the PS profile) still get full template-parse +
# syntax coverage, just with their Linux-rendered body (they barely branch on
# OS — see CLAUDE.md). This is a known limitation of the render check.
#
# Checkers soft-skip when their tool is absent (mirrors check-invariants.sh):
# zsh, nu, pwsh, yq, and python-with-tomllib may be missing locally. CI's
# `templates` job has them all — ubuntu-latest ships pwsh, yq and a
# tomllib-capable python3 with NO extra install steps (proven by this same
# workflow's `powershell` job already running `shell: pwsh` on ubuntu-latest
# with no pwsh install step); zsh and nu are installed explicitly.
#
# Usage: bash scripts/check-templates.sh          (from anywhere; repo-relative)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

fails=0
hdr() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok() { printf ' %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad() {
  printf ' %s✗%s %s\n' "$RED" "$RESET" "$*"
  fails=$((fails + 1))
}
note() { printf ' · %s\n' "$*"; }

command -v mise >/dev/null 2>&1 || {
  note "mise not installed — cannot render dotfiles templates (CI enforces)"
  exit 0
}

PY=""
for _p in wpy python3; do
  if command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import tomllib' 2>/dev/null; then
    PY="$_p"
    break
  fi
done
if [ -z "$PY" ]; then
  note "no python with tomllib — cannot discover [dotfiles] template entries (CI enforces)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_home <env> <dir> — a scratch $HOME with its own .config/mise (see the
# header): this checkout, plus a config.local.toml with name and email.
make_home() {
  local env=$1 home=$2 cfg entry base
  cfg="$home/.config/mise"
  mkdir -p "$cfg"
  for entry in "$REPO_ROOT"/*; do
    base=$(basename "$entry")
    case "$base" in
    config.local.toml) ;;
    dotfiles) cp -R "$entry" "$cfg/dotfiles" ;;
    *) ln -s "$entry" "$cfg/$base" ;;
    esac
  done
  printf '[vars]\nname = "Template Check"\nemail = "template-check@example.invalid"\n' >"$cfg/config.local.toml"
}

# in_home <env> <home> <cmd…> — run a mise command against that scratch HOME.
in_home() {
  local env=$1 home=$2
  shift 2
  (cd "$home" && HOME="$home" MISE_CONFIG_DIR="$home/.config/mise" MISE_ENV="$env" "$@")
}

# discover_targets <MISE_ENV> — prints one "~/..." target per line: every
# mode="template" [dotfiles] entry active under that token set.
discover_targets() {
  "$PY" - "$1" <<'PY'
import sys, tomllib

env_tokens = set(sys.argv[1].split(","))
FILES = ["config.toml", "config.linux.toml", "config.windows.toml"]

def token_for(fname):
    if fname == "config.toml":
        return None  # cross-platform: always active
    return fname[len("config."):-len(".toml")]

targets = []
for f in FILES:
    tok = token_for(f)
    if tok is not None and tok not in env_tokens:
        continue
    try:
        with open(f, "rb") as fh:
            d = tomllib.load(fh)
    except FileNotFoundError:
        continue
    for target, spec in d.get("dotfiles", {}).items():
        if not isinstance(spec, dict):
            continue  # a bare string source is always symlink mode
        if spec.get("enabled") is False:
            continue
        if spec.get("mode") == "template":
            targets.append(target)

for t in sorted(set(targets)):
    print(t)
PY
}

zsh_check() { zsh -n "$1"; }
bash_check() { bash -n "$1"; }
git_check() { git config --file "$1" --list >/dev/null; }
# config.nu is evaluated, not only parsed: a $env.config key this Nushell doesn't
# know fails only at evaluation. A bulk render also deploys the theme into the
# sibling autoload dir; it's sourced after config.nu, as Nushell does.
# USERPROFILE stands in for Windows'.
nu_check() {
  local src theme
  src="source '$1'"
  theme="$(dirname "$1")/autoload/catppuccin_mocha.nu"
  [ -f "$theme" ] && src="$src; source '$theme'"
  USERPROFILE="${TMPDIR:-/tmp}" nu --no-config-file --commands "$src"
}
pwsh_check() {
  pwsh -NoProfile -Command \
    "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$1',[ref]\$null,[ref]\$e); if (\$e) { \$e | ForEach-Object { \$_.Message }; exit 1 }"
}
yaml_check() { yq eval '.' "$1" >/dev/null; }
toml_check() { "$PY" -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$1"; }

# select_checker <target> — sets $CHECK_CMD (checker function name, or empty)
# and $CHECK_NOTE (why it's empty: soft-skip vs "no checker by design").
select_checker() {
  CHECK_CMD=""
  CHECK_NOTE=""
  # shellcheck disable=SC2088  # the ~/... literals below are mise TARGET
  # strings (case patterns to match against), not paths for the shell to
  # expand — mise's own status/config output spells targets this way.
  case "$1" in
  "~/.gitconfig")
    CHECK_CMD="git_check"
    ;;
  "~/.bashrc")
    if command -v bash >/dev/null 2>&1; then CHECK_CMD="bash_check"; else CHECK_NOTE="bash not installed"; fi
    ;;
  "~/.zshrc" | "~/.zshenv")
    if command -v zsh >/dev/null 2>&1; then CHECK_CMD="zsh_check"; else CHECK_NOTE="zsh not installed"; fi
    ;;
  "~/.config/cheat/conf.yml")
    if command -v yq >/dev/null 2>&1; then CHECK_CMD="yaml_check"; else CHECK_NOTE="yq not installed"; fi
    ;;
  "~/AppData/Roaming/helix/config.toml")
    CHECK_CMD="toml_check"
    ;; # $PY already verified present above
  "~/AppData/Roaming/nushell/config.nu")
    if command -v nu >/dev/null 2>&1; then CHECK_CMD="nu_check"; else CHECK_NOTE="nu not installed"; fi
    ;;
  "~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1")
    if command -v pwsh >/dev/null 2>&1; then CHECK_CMD="pwsh_check"; else CHECK_NOTE="pwsh not installed"; fi
    ;;
  "~/.ssh/config" | "~/.gdbinit")
    CHECK_NOTE="no dedicated syntax checker for this target (render-only, by design)"
    ;;
  *)
    CHECK_NOTE="new template target — check-templates.sh has no checker mapped yet (render-only)"
    ;;
  esac
}

# apply_and_check <env> <scratch-home> <target> [label-suffix]
# Applies exactly one target, then runs its checker. Returns 1 on any
# failure (render or syntax) so the caller can gate the bulk pass on it.
apply_and_check() {
  local env=$1 home=$2 target=$3 suffix=${4:-} label out err path
  label="$target [$env]$suffix"
  if ! out=$(in_home "$env" "$home" mise dot apply --force --yes -- "$target" 2>&1); then
    # Keep the part that says WHY. mise puts the useful lines first (the
    # entry, the source file, `error: Variable ... is not defined`, the
    # caret line) and follows them with two generic "mise ERROR Version/Run
    # with --verbose" lines — a plain `tail` keeps only that boilerplate and
    # throws the diagnosis away (the culprit must be named).
    bad "$label: mise dot apply failed: $(printf '%s' "$out" | grep -vE '^mise ERROR (Version|Run with)' | head -6 | tr '\n' ' ')"
    return 1
  fi
  path="$home/${target#\~/}"
  if [ ! -e "$path" ]; then
    bad "$label: apply exited 0 but $path was not written. mise said: $(printf '%s' "$out" | tail -5 | tr '\n' ' ') | HOME=$home ls: $(ls -la "$home" 2>&1 | tr '\n' ' ')"
    return 1
  fi
  # The vcpkg block is in every Linux render.
  # shellcheck disable=SC2088  # mise target strings, not paths
  case "$target" in
  "~/.zshrc" | "~/.bashrc")
    if [[ ",$env," == *,linux,* ]] && ! grep -q 'VCPKG_ROOT' "$path"; then
      bad "$label: rendered without the VCPKG_ROOT block"
      return 1
    fi
    ;;
  esac
  select_checker "$target"
  if [ -n "$CHECK_CMD" ]; then
    if err=$("$CHECK_CMD" "$path" 2>&1); then
      ok "$label: renders + syntax OK"
    else
      bad "$label: syntax check failed: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
      return 1
    fi
  else
    note "$label: renders OK ($CHECK_NOTE)"
  fi
  return 0
}

ENVS=("linux" "windows")

for env in "${ENVS[@]}"; do
  hdr "individual render + syntax check — MISE_ENV=$env"
  targets="$(discover_targets "$env")"
  if [ -z "$targets" ]; then
    bad "MISE_ENV=$env: discover_targets found zero mode=\"template\" [dotfiles] entries (expected at least one)"
    continue
  fi

  indiv_home="$WORK/indiv-${env//[,\/]/_}"
  make_home "$env" "$indiv_home"
  env_ok=1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    apply_and_check "$env" "$indiv_home" "$t" || env_ok=0
  done <<<"$targets"
  rm -rf "$indiv_home"

  hdr "bulk apply — MISE_ENV=$env (mise bootstrap --only dotfiles --force-dotfiles --yes)"
  if [ "$env_ok" -eq 0 ]; then
    note "skipped — an individual template failed above; fix it first (one bad template aborts the whole apply, so the bulk run would just fail opaquely)"
    continue
  fi

  bulk_home="$WORK/bulk-${env//[,\/]/_}"
  make_home "$env" "$bulk_home"
  if out=$(in_home "$env" "$bulk_home" mise bootstrap --only dotfiles --force-dotfiles --yes 2>&1); then
    ok "MISE_ENV=$env: mise bootstrap --only dotfiles --force-dotfiles --yes applied cleanly"
    bulk_ok=1
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      path="$bulk_home/${t#\~/}"
      if [ ! -e "$path" ]; then
        bad "$t [$env] (bulk): mise bootstrap reported success but $path was not written"
        bulk_ok=0
        continue
      fi
      select_checker "$t"
      if [ -n "$CHECK_CMD" ]; then
        if err=$("$CHECK_CMD" "$path" 2>&1); then
          : # already proven by the individual pass; bulk output re-checked silently
        else
          bad "$t [$env] (bulk): syntax check failed on the bulk-rendered file: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
          bulk_ok=0
        fi
      fi
    done <<<"$targets"
    [ "$bulk_ok" -eq 1 ] && ok "MISE_ENV=$env: bulk-rendered output matches the individually-verified renders"
  else
    bad "MISE_ENV=$env: bulk apply failed even though every template passed individually: $(printf '%s' "$out" | tail -5 | tr '\n' ' ')"
  fi
  rm -rf "$bulk_home"
done

hdr "summary"
if ((fails > 0)); then
  printf '   %d failure(s)\n' "$fails"
  exit 1
fi
printf '   all rendered templates pass, across all %d MISE_ENV sets\n' "${#ENVS[@]}"
