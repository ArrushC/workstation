#!/usr/bin/env bash
# check-templates.sh — render every dotfiles/**/*.tera template into a
# throwaway target $HOME, for each real MISE_ENV token set, and syntax-check
# the rendered output. Replaces the chezmoi-based render pass PR3 Task 1
# retired (chezmoi execute-template cannot parse Tera's {% %} syntax at all).
#
# mise's global-config discovery has a FALLBACK, which is the whole reason
# this script needs the symlink below. Measured on 2026-09-19 (mise 2026.9.9):
#   HOME=X mise …  and X/.config/mise/config.toml EXISTS  -> X's config loads
#   HOME=X mise …  and X/.config/mise         is ABSENT   -> mise falls back
#                                                            to the REAL
#                                                            account home's
#                                                            ~/.config/mise
# So a scratch HOME with no config of its own does NOT isolate the read side:
# it silently reads whatever the account home has. On every real host the
# account home IS this checkout (bootstrap.sh clones there by design), so the
# fallback happens to land on the right config and overriding HOME alone
# "works". On a CI runner the account home (/home/runner) is NOT the checkout
# ($GITHUB_WORKSPACE), the fallback finds nothing, and `dot apply`/`bootstrap`
# silently no-op — no error, nothing written. Fixed once below by symlinking
# <account-home>/.config/mise at the checkout when nothing is there (additive
# only, never overwrites a real one; removed again by the EXIT trap). The
# dotfiles TARGET side (where "~/..." actually lands) is a SEPARATE mechanism
# that always honors the per-call `HOME=` override, which is what keeps every
# render in this script off the real $HOME.
#
# Design (docs/superpowers/plans/2026-09-19-mise-dotfiles.md ruling 3: ONE
# broken template aborts the WHOLE `mise dot apply`/`mise bootstrap`, and
# writes nothing at all — so a bulk run alone can never name the culprit):
#   1. For each of the four real MISE_ENV token sets, discover which
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
# OS — see CLAUDE.md). This mirrors the chezmoi-era script's own documented
# limitation, not a new gap.
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

# A scratch HOME only isolates the config READ side when it carries its own
# .config/mise; with none, mise falls back to the real account home's config
# (measured 2026-09-19, mise 2026.9.9 — see the header block). On every real
# host the account home IS this checkout, which is why overriding HOME alone
# "worked" in every local test. A CI runner's account home (/home/runner) is
# NOT the checkout ($GITHUB_WORKSPACE), so the fallback finds nothing and
# `dot apply`/`dot bootstrap` silently no-op instead of erroring. Fix: if the
# real account home has no ~/.config/mise yet, symlink it at the checkout —
# additive only, never overwrites a real one, removed again by the EXIT trap,
# and writes nothing under the dotfiles TARGET side (that's still isolated
# per-call by the scratch `HOME=` override below).
REAL_HOME="$HOME"
CREATED_MISE_SYMLINK=0
if [ "$(readlink -f "$REAL_HOME/.config/mise" 2>/dev/null)" != "$REPO_ROOT" ] && [ ! -e "$REAL_HOME/.config/mise" ]; then
  mkdir -p "$REAL_HOME/.config"
  ln -s "$REPO_ROOT" "$REAL_HOME/.config/mise"
  CREATED_MISE_SYMLINK=1
fi

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
cleanup() {
  rm -rf "$WORK"
  [ "$CREATED_MISE_SYMLINK" -eq 1 ] && rm -f "$REAL_HOME/.config/mise"
}
trap cleanup EXIT

# discover_targets <MISE_ENV> — prints one "~/..." target per line: every
# mode="template" [dotfiles] entry active under that token set.
discover_targets() {
  "$PY" - "$1" <<'PY'
import sys, tomllib

env_tokens = set(sys.argv[1].split(","))
FILES = ["config.toml", "config.linux.toml", "config.owned.toml", "config.host.toml", "config.windows.toml"]

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
nu_check() { nu --no-config-file --commands "if (nu-check '$1') { exit 0 } else { exit 1 }"; }
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
  "~/.ssh/config" | "~/.gdbinit" | "~/.config/environment.d/10-mise.conf")
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
  if ! out=$(HOME="$home" MISE_ENV="$env" mise dot apply --force --yes -- "$target" 2>&1); then
    # Keep the part that says WHY. mise puts the useful lines first (the
    # entry, the source file, `error: Variable ... is not defined`, the
    # caret line) and follows them with two generic "mise ERROR Version/Run
    # with --verbose" lines — a plain `tail` keeps only that boilerplate and
    # throws the diagnosis away (ruling 3 wants the culprit named).
    bad "$label: mise dot apply failed: $(printf '%s' "$out" | grep -vE '^mise ERROR (Version|Run with)' | head -6 | tr '\n' ' ')"
    return 1
  fi
  path="$home/${target#\~/}"
  if [ ! -e "$path" ]; then
    bad "$label: apply exited 0 but $path was not written. mise said: $(printf '%s' "$out" | tail -5 | tr '\n' ' ') | HOME=$home ls: $(ls -la "$home" 2>&1 | tr '\n' ' ')"
    return 1
  fi
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

ENVS=("linux" "linux,owned,host,wsl" "linux,owned,host,native" "windows,owned")

for env in "${ENVS[@]}"; do
  hdr "individual render + syntax check — MISE_ENV=$env"
  targets="$(discover_targets "$env")"
  if [ -z "$targets" ]; then
    bad "MISE_ENV=$env: discover_targets found zero mode=\"template\" [dotfiles] entries (expected at least one)"
    continue
  fi

  indiv_home="$WORK/indiv-${env//[,\/]/_}"
  mkdir -p "$indiv_home"
  env_ok=1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    apply_and_check "$env" "$indiv_home" "$t" || env_ok=0
  done <<<"$targets"
  rm -rf "$indiv_home"

  hdr "bulk apply — MISE_ENV=$env (mise bootstrap --only dotfiles --force-dotfiles --yes)"
  if [ "$env_ok" -eq 0 ]; then
    note "skipped — an individual template failed above; fix it first (ruling 3: one bad template aborts the whole apply, so the bulk run would just fail opaquely)"
    continue
  fi

  bulk_home="$WORK/bulk-${env//[,\/]/_}"
  mkdir -p "$bulk_home"
  if out=$(HOME="$bulk_home" MISE_ENV="$env" mise bootstrap --only dotfiles --force-dotfiles --yes 2>&1); then
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
printf '   all rendered templates pass, across all four MISE_ENV sets\n'
