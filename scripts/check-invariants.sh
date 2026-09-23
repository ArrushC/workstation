#!/usr/bin/env bash
# check-invariants.sh — mechanically enforce the load-bearing repo invariants
# documented in CLAUDE.md + docs/claude/file-care.md.
#
# Single source of truth for the checks; invoked three ways:
#   - mise run lint               (tasks/lint -> $REPO_ROOT/scripts/check-invariants.sh)
#   - .githooks/pre-commit       (installed via `mise run install-hooks`)
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

# Python with tomllib: EL9's python3 is 3.9 (no tomllib) — prefer the python-env
# wpy (3.14); CI's python3 is 3.11+. Empty when neither exists (callers soft-skip).
PY=""
for _p in wpy python3; do
  if command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import tomllib' 2>/dev/null; then
    PY="$_p"
    break
  fi
done
# tomlval <file> <dotted.key> — print a TOML value (string, or a table's `version`).
# Keys with dots/colons inside quotes are supported: tomlval config.dev.toml 'tools."github:DevToys-app/DevToys"'
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

# Version="..." value from the $PortableTools block whose Name = "<name>" in
# bootstrap.ps1 (one generic extractor for every jq/gh/Helix/OpenCode/... pin).
ps1_tool_version() {
  awk -v pat="Name[[:space:]]*=[[:space:]]*\"$1\"[[:space:]]*\$" '
    $0 ~ pat { f = 1 }
    f && /Version[[:space:]]*=/ { print; exit }
  ' bootstrap.ps1 | grep -oE '[0-9][0-9.]+' | head -1
}

# _ps1_drive_ref_hits <file> — print "LINE:CONTENT" for any non-comment line
# carrying an unbraced $name: reference. Inside a double-quoted string/
# here-string PowerShell's parser reads "$name:" as a drive-qualified
# variable and throws InvalidVariableReferenceWithDrive (the exact parse
# error `scripts/test-curl.ps1`'s Parser::ParseFile hit on bootstrap.ps1
# after 69bded7) unless the colon is a real scope ($env:/$script:/...) or
# the ref is braced (${name}:). Comment-only lines (first non-blank char
# `#`) are exempt.
_ps1_drive_ref_hits() {
  grep -nE '\$[A-Za-z_][A-Za-z0-9_]*:' "$1" |
    grep -vE '\$(env|script|global|local|private|using|variable|function|alias):' |
    grep -vE '^[0-9]+:[[:space:]]*#'
}

check_version_pins() {
  hdr "version-pin dual/triple-edits"
  local v v2 ref ps_v font_re font_has

  if [ -z "$PY" ]; then
    note "no python with tomllib — TOML-sourced pin checks skipped locally (CI enforces)"
  else
    v=$(tomlval config.linux.toml tools.jq)
    ref=$(ps1_tool_version jq)
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "jq @ $v  (config.linux.toml == bootstrap.ps1)"
    else
      bad "jq drift: config.linux.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.linux.toml tools.gh)
    ref=$(ps1_tool_version "GitHub CLI")
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "gh @ $v  (config.linux.toml == bootstrap.ps1)"
    else
      bad "gh drift: config.linux.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.linux.toml tools.helix)
    ref=$(ps1_tool_version Helix)
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "helix @ $v  (config.linux.toml == bootstrap.ps1)"
    else
      bad "helix drift: config.linux.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.dev.toml tools.opencode)
    ref=$(ps1_tool_version OpenCode)
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "opencode @ $v  (config.dev.toml == bootstrap.ps1)"
    else
      bad "opencode drift: config.dev.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.dev.toml 'tools."github:can1357/oh-my-pi"')
    ref=$(ps1_tool_version "Oh My Pi")
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "omp @ $v  (config.dev.toml == bootstrap.ps1)"
    else
      bad "omp drift: config.dev.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.dev.toml 'tools."github:DevToys-app/DevToys"')
    ref=$(ps1_tool_version "DevToys CLI")
    if [ -n "$v" ] && [ "$v" = "$ref" ]; then
      ok "devtoys-cli @ $v  (config.dev.toml == bootstrap.ps1)"
    else
      bad "devtoys-cli drift: config.dev.toml='$v' bootstrap.ps1='$ref'"
    fi

    v=$(grep -oE '^MISE_VERSION="[0-9][0-9.]+"' bootstrap.sh | grep -oE '[0-9][0-9.]+')
    ref=$(ps1_tool_version mise)
    v2=$(tomlval config.toml min_version)
    if [ -n "$v" ] && [ "$v" = "$ref" ] && [ "$v" = "$v2" ]; then
      ok "mise @ $v  (bootstrap.sh == bootstrap.ps1 == config.toml min_version)"
    else
      bad "mise drift: bootstrap.sh='$v' bootstrap.ps1='$ref' config.toml-min_version='$v2'"
    fi

    v=$(tomlval config.toml vars.python_version)
    v2=$(tomlval config.toml tools.python)
    ref=$(grep -oE '^\$PythonEnvVersion *= *"[0-9][0-9.]+"' bootstrap.ps1 |
      grep -oE '[0-9][0-9.]+' | head -1)
    if [ -n "$v" ] && [ "$v" = "$v2" ] && [ "$v" = "$ref" ]; then
      ok "python-env @ $v  (config.toml [vars] == config.toml tools.python == bootstrap.ps1)"
    else
      bad "python-env drift: config.toml-vars.python_version='$v' config.toml-tools.python='$v2' bootstrap.ps1='$ref'"
    fi

    v=$(tomlval config.toml vars.nerd_font_version)
    ps_v=$(grep -E '^\$Version[[:space:]]*=' scripts/install-nerd-fonts.ps1 |
      grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    # font.sh pins the SHA per version in a `case "$VERSION"` block; the runtime
    # looks it up BY VALUE, so verify an arm for $v EXISTS (position-independent)
    # — appending a new arm on a bump (as font.sh instructs) must still pass.
    font_re="^[[:space:]]*${v//./\\.}\\)[[:space:]]*EXPECT_SHA"
    if grep -qE "$font_re" scripts/lib/font.sh; then font_has=yes; else font_has=no; fi
    if [ -n "$v" ] && [ "$v" = "$ps_v" ] && [ "$font_has" = yes ]; then
      ok "jetbrains-mono nerd @ $v  (config.toml [vars] == install-nerd-fonts.ps1; scripts/lib/font.sh SHA arm present)"
    else
      bad "jetbrains-mono nerd drift: config.toml-vars.nerd_font_version='$v' install-nerd-fonts.ps1='$ps_v' font.sh-SHA-arm=$font_has"
    fi
  fi

  # VCPKG_ROOT — both rc files must export the SAME literal, and tasks/vcpkg's
  # vroot= literal is the one that actually decides where vcpkg lands. The rc
  # literal is asserted equal to that same $HOME/.local/share/vcpkg.
  local rc_z rc_b vroot_task want='$HOME/.local/share/vcpkg'
  rc_z=$(grep -oE 'VCPKG_ROOT="[^"]*"' dotfiles/zshrc.tera | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  rc_b=$(grep -oE 'VCPKG_ROOT="[^"]*"' dotfiles/bashrc.tera | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  vroot_task=$(grep -oE 'vroot="[^"]*"' tasks/vcpkg | head -1 | sed -E 's/.*="([^"]*)"/\1/')
  if [ -n "$rc_z" ] && [ "$rc_z" = "$rc_b" ] && [ "$rc_z" = "$want" ] && [ "$vroot_task" = "$want" ]; then
    ok "vcpkg-root @ zshrc == bashrc == $want; tasks/vcpkg vroot == $want"
  else
    bad "vcpkg-root drift: zshrc='$rc_z' bashrc='$rc_b' tasks/vcpkg-vroot='$vroot_task' (want $want)"
  fi
}

# MISE_ENV is computed identically in THREE places (a host's interactive rc
# files plus the file systemd's user manager imports at login/re-exec — see
# config/environment.d/10-mise.conf.tera's own header comment) — a triple-edit
# pin, not a dual one. All three must carry the byte-identical Tera
# conditional or a host can end up with a DIFFERENT MISE_ENV in an
# interactive shell than in a systemd user unit (exactly the pueued-startup
# class of bug docs/claude/invariants.md documents). PR3 converted all three
# sources from chezmoi Go templates to Tera.
#
# 2026-09-19 fix: a text-only three-way comparison passes when all three
# expressions are IDENTICALLY WRONG (which they were — see the fix report:
# every {% if vars.group is defined ... %} guard was always false because
# nothing ever wrote vars.group, so all three silently baked "linux" on
# every host). Kept below as a cheap first pass, but the check that actually
# catches that class of bug is the render comparison that follows it: each
# template is rendered for real, twice (vars.group="dev_machine" and
# "prod_machine"), into a scratch $HOME, and the baked MISE_ENV is asserted
# against scripts/lib/mise-env.sh — the canonical source of these token sets
# — run on THIS machine (same `uname -r` branch the templates themselves take,
# so it's apples-to-apples).
#
# Render setup mirrors scripts/check-templates.sh's measured discovery rule
# (see that script's header): a scratch $HOME only isolates mise's config
# READ side when it carries its own .config/mise — with none, mise falls
# BACK to the real account home's config, which is precisely the trap here
# (a fallback to the real, ungrouped config.local.toml would render "linux"
# for every group and the check would never catch the original bug). So
# each render below builds its scratch $HOME a genuine .config/mise of its
# own: every entry of the repo symlinked in verbatim EXCEPT config.local.toml,
# which is written fresh with vars.group pinned to exactly the value under
# test. Nothing under the real repo or the real $HOME is ever touched or
# applied to — only a fresh /tmp scratch dir per render, removed right after.
_render_baked_mise_env() {
  local target=$1 group=$2 env=$3 home out path baked entry base
  home="$(mktemp -d)"
  mkdir -p "$home/.config/mise"
  for entry in "$ROOT"/*; do
    base=$(basename "$entry")
    [ "$base" = "config.local.toml" ] && continue
    ln -s "$entry" "$home/.config/mise/$base"
  done
  cat >"$home/.config/mise/config.local.toml" <<EOF
[vars]
group = "$group"
EOF
  # Two independent overrides, deliberately redundant: CI's invariants job
  # sets MISE_CONFIG_DIR=$GITHUB_WORKSPACE for the whole step (see
  # .github/workflows/lint.yml — needed so mise doesn't rewrite lock files'
  # sidecar refs), which otherwise wins over HOME-based discovery entirely —
  # measured directly: with an ambient MISE_CONFIG_DIR pointed at this repo,
  # HOME alone rendered the real (group-less) config every time, exactly
  # reproducing the CI failure this fixes. cd-ing into $home makes any
  # cwd-ancestor config walk land on the scratch config too. Passing
  # MISE_CONFIG_DIR="$home/.config/mise" explicitly overrides whatever the
  # ambient value is (set by CI, or unset locally) for this one subshell only.
  if ! out=$(cd "$home" && HOME="$home" MISE_CONFIG_DIR="$home/.config/mise" MISE_ENV="$env" mise dot apply --force --yes -- "$target" 2>&1); then
    note "render $target [group=$group]: mise dot apply failed: $(printf '%s' "$out" | grep -vE '^mise ERROR (Version|Run with)' | head -3 | tr '\n' ' ')"
    rm -rf "$home"
    return 1
  fi
  path="$home/${target#\~/}"
  if [ ! -e "$path" ]; then
    note "render $target [group=$group]: apply exited 0 but $path was not written"
    rm -rf "$home"
    return 1
  fi
  # Matches both the rc-file form (export MISE_ENV="linux,dev,host,wsl") and
  # environment.d's unquoted systemd form (MISE_ENV=linux,dev,host,wsl).
  baked=$(grep -oE '(export )?MISE_ENV="?[a-z,]+"?' "$path" | head -1 | sed -E 's/^export //; s/^MISE_ENV="?//; s/"$//')
  rm -rf "$home"
  [ -n "$baked" ] || return 1
  printf '%s' "$baked"
}

check_mise_env_three_way() {
  hdr "MISE_ENV computed identically (zshenv.tera == bashrc.tera == environment.d/10-mise.conf.tera)"
  local zshenv_expr bashrc_expr envd_expr
  zshenv_expr=$(grep -oE 'export MISE_ENV=".*"$' dotfiles/zshenv.tera | head -1 | sed -E 's/^export MISE_ENV="//; s/"$//')
  bashrc_expr=$(grep -oE 'export MISE_ENV=".*"$' dotfiles/bashrc.tera | head -1 | sed -E 's/^export MISE_ENV="//; s/"$//')
  envd_expr=$(grep -E '^MISE_ENV=' dotfiles/config/environment.d/10-mise.conf.tera | head -1 | sed -E 's/^MISE_ENV=//')
  if [ -n "$zshenv_expr" ] && [ "$zshenv_expr" = "$bashrc_expr" ] && [ "$zshenv_expr" = "$envd_expr" ]; then
    ok "zshenv.tera == bashrc.tera == environment.d/10-mise.conf.tera (expression text)"
  else
    bad "MISE_ENV expression drift: zshenv.tera='$zshenv_expr' bashrc.tera='$bashrc_expr' environment.d/10-mise.conf.tera='$envd_expr'"
  fi

  hdr "MISE_ENV renders match scripts/lib/mise-env.sh (catches an expression that is text-identical but wrong)"
  if ! command -v mise >/dev/null 2>&1; then
    note "mise not installed — cannot render dotfiles templates to verify baked MISE_ENV (CI enforces)"
    return
  fi
  if [ ! -x scripts/lib/mise-env.sh ]; then
    bad "scripts/lib/mise-env.sh missing or not executable — cannot establish the canonical MISE_ENV token sets"
    return
  fi

  local dev_env prod_env
  dev_env=$(scripts/lib/mise-env.sh dev)
  prod_env=$(scripts/lib/mise-env.sh prod)
  if [ -z "$dev_env" ] || [ -z "$prod_env" ]; then
    bad "scripts/lib/mise-env.sh dev/prod produced no output — cannot verify renders against it"
    return
  fi

  # shellcheck disable=SC2088  # the ~/... literals below are mise TARGET
  # strings (dotfiles table keys), not paths for the shell to expand — mirrors
  # scripts/check-templates.sh's own select_checker (same reasoning there).
  local -a targets=("~/.zshenv" "~/.bashrc" "~/.config/environment.d/10-mise.conf")
  local t d p all_agree=1
  local -a devs=() prods=()
  for t in "${targets[@]}"; do
    d=$(_render_baked_mise_env "$t" "dev_machine" "$dev_env") || d=""
    p=$(_render_baked_mise_env "$t" "prod_machine" "$prod_env") || p=""
    devs+=("$d")
    prods+=("$p")
    if [ "$d" = "$dev_env" ]; then
      ok "$t [vars.group=dev_machine]: renders MISE_ENV=\"$d\" == scripts/lib/mise-env.sh dev"
    else
      bad "$t [vars.group=dev_machine]: renders MISE_ENV=\"$d\" != scripts/lib/mise-env.sh dev (\"$dev_env\")"
    fi
    if [ "$p" = "$prod_env" ]; then
      ok "$t [vars.group=prod_machine]: renders MISE_ENV=\"$p\" == scripts/lib/mise-env.sh prod"
    else
      bad "$t [vars.group=prod_machine]: renders MISE_ENV=\"$p\" != scripts/lib/mise-env.sh prod (\"$prod_env\")"
    fi
  done

  for t in "${devs[@]}"; do [ "$t" = "${devs[0]}" ] || all_agree=0; done
  for t in "${prods[@]}"; do [ "$t" = "${prods[0]}" ] || all_agree=0; done
  if [ "$all_agree" -eq 1 ]; then
    ok "zshenv.tera == bashrc.tera == environment.d/10-mise.conf.tera (rendered output, both groups)"
  else
    bad "rendered MISE_ENV disagrees across the three templates: dev=(${devs[*]}) prod=(${prods[*]})"
  fi
}

# Every dual-edit version pin verified by check_version_pins must also sit in
# scripts/bump-versions.sh's EXCLUDE list — otherwise the weekly bumper would
# rewrite config*.toml alone and fail the pin check (version-bumps run #9: gh
# 2.97.0, added as a dual-edit in #94 without the exclusion, is the same class
# of bug one layer down). The pin set is derived from check_version_pins' own
# source (its `tomlval … tools.<name>` calls), so a new dual-edit pin check
# added there is asserted here automatically — no second list to drift. The
# coupled tools (gopls/typescript/zjstatus/node/ncdu pins with a version
# floor or postinstall string elsewhere) are NOT read from check_version_pins
# (they live in their own coupling-check functions) so are named explicitly.
# One-directional: extra EXCLUDE entries are fine.
check_bumper_exclude() {
  hdr "bump-versions.sh handles every dual-edit/coupled pin"
  local exclude handled pins var missing="" n=0
  local -a coupled=(github:dj95/zjstatus go go:golang.org/x/tools/gopls http:ncdu node)
  exclude=$(grep -m1 -E '^EXCLUDE=' scripts/bump-versions.sh |
    sed -E 's/^EXCLUDE="//; s/"[[:space:]]*$//')
  # A dual-edit/coupled pin is safe when the bumper either skips it (EXCLUDE)
  # or bumps it with dedicated code that keeps its pair in step: the Windows
  # half via the PS1_NAME map, go+gopls / node via COUPLED_AUTO. Anything else
  # would get a blind one-sided edit and fail check_version_pins.
  handled="$exclude $(grep -m1 -E '^COUPLED_AUTO=' scripts/bump-versions.sh |
    sed -E 's/^COUPLED_AUTO="//; s/"[[:space:]]*$//') $(awk '/^declare -A PS1_NAME=\(/,/^\)/' scripts/bump-versions.sh |
      sed -nE 's/^[[:space:]]*\["([^"]+)"\]=.*/\1/p' | tr '\n' ' ')"
  if [ -z "$exclude" ]; then
    bad "scripts/bump-versions.sh: EXCLUDE= line not found"
  else
    pins=$(awk '/^check_version_pins\(\) \{/,/^\}/' scripts/check-invariants.sh |
      grep -oE "tomlval config[a-z.]*toml '?tools\.[^ ']+'?" |
      sed -E "s/.*tools\.//; s/^\"//; s/\"'?\$//; s/\)\$//" | sort -u)
    pins="$pins
$(printf '%s\n' "${coupled[@]}")"
    while read -r var; do
      [ -n "$var" ] || continue
      n=$((n + 1))
      case " $handled " in
      *" $var "*) ;;
      *) missing="$missing $var" ;;
      esac
    done <<<"$pins"
    if [ "$n" -gt 0 ] && [ -z "$missing" ]; then
      ok "all $n dual-edit/coupled tool pins excluded or paired-bumped (bump-versions.sh EXCLUDE / PS1_NAME / COUPLED_AUTO)"
    else
      bad "dual-edit/coupled tool pin(s) the bumper doesn't handle:${missing:- <none derived>} — add each to bump-versions.sh's PS1_NAME map (Windows half), COUPLED_AUTO, or EXCLUDE, or the weekly bumper rewrites one side alone and fails the pin check"
    fi
  fi

  # Same coverage for config.toml [vars] pins: any vars.<name> read by
  # check_version_pins is a dual/triple-edit host pin and must sit in the
  # bumper's EXCLUDE_VARS (Layer 2) — otherwise a blind bump rewrites
  # config.toml [vars] alone and immediately fails check_version_pins.
  # vcpkg_version is a single-edit pin (never referenced via
  # `tomlval config.toml vars.*` in check_version_pins) so is correctly NOT
  # derived here, and zjstatus_zellij_floor is a coupling floor, not a pin
  # (read only by check_zjstatus_zellij_coupling) so is correctly absent too.
  local exclude_vars vpins vmissing="" vn=0
  exclude_vars=$(grep -m1 -E '^EXCLUDE_VARS=' scripts/bump-versions.sh |
    sed -E 's/^EXCLUDE_VARS="//; s/"[[:space:]]*$//')
  if [ -z "$exclude_vars" ]; then
    bad "scripts/bump-versions.sh: EXCLUDE_VARS= line not found"
    return
  fi
  vpins=$(awk '/^check_version_pins\(\) \{/,/^\}/' scripts/check-invariants.sh |
    grep -oE 'tomlval config\.toml vars\.[a-z_]+' |
    sed -E 's/.*vars\.//' | sort -u)
  while read -r var; do
    [ -n "$var" ] || continue
    vn=$((vn + 1))
    case " $exclude_vars " in
    *" $var "*) ;;
    *) vmissing="$vmissing $var" ;;
    esac
  done <<<"$vpins"
  if [ "$vn" -gt 0 ] && [ -z "$vmissing" ]; then
    ok "all $vn dual-edit [vars] pin(s) in bumper EXCLUDE_VARS (bump-versions.sh)"
  else
    bad "dual-edit [vars] pin(s) missing from bump-versions.sh EXCLUDE_VARS:${vmissing:- <none derived>} — the weekly bumper would rewrite config.toml [vars] alone and fail the pin check"
  fi
}

check_line_endings_and_mode() {
  hdr "line-endings (LF) + git mode (100755)"
  local f mode crlf=0 modebad=0 missing=0
  local -a files=(scripts/*.sh scripts/lib/*.sh tasks/* .claude/hooks/*.sh dotfiles/local/bin/*)
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

# The converse of check_line_endings_and_mode: every dotfile SOURCE must be
# git mode 100644, except this explicit, deliberately hand-maintained
# allowlist (find candidates with `git ls-files -s dotfiles/ | grep 100755`).
# A NEW executable dotfile source must be added here on purpose, in the same
# commit that adds it — that's the point of writing the list out literally
# instead of deriving it. `template`-mode sources are the highest-stakes
# case: `template`/`copy` both propagate the SOURCE's own git-tracked
# executable bit onto $HOME (post-dotfiles-hook territory, ~/.ssh/~/.claude
# excepted), and a filesystem that reports every file 0744 regardless of git
# mode (DrvFs, over a Windows drive mount) turns that propagation into a
# blanket, invisible chmod +x across every managed dotfile the moment `mise
# dot apply`/`wsa` runs from there — this is exactly what corrupted
# ~/.gitconfig, ~/.bashrc, ~/.zshrc, ~/.zshenv, ~/.config/cheat/conf.yml,
# ~/.config/environment.d/10-mise.conf and ~/.gdbinit on 2026-09-22.
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
  for f in "${tracked[@]}"; do
    n=$((n + 1))
    mode=$(git ls-files --stage -- "$f" | awk '{print $1}')
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

check_sentinels() {
  hdr "sentinel blocks matched"
  local s e
  # Anchor to a whole marker line — prose that merely mentions the token
  # must not count.
  #
  # The chezmoi-era half of this check (# CCSTATUSLINE:START/END in
  # chezmoi/.chezmoiignore.tmpl) has no successor to repoint at: PR3 Task 3
  # moved the per-host ccstatusline opt-out to a # CCSTATUSLINE-OPTOUT:START/
  # END block that scripts/setup-ccstatusline.sh writes into config.local.toml
  # — per-host and git-ignored (ruling 2), so there is no longer a tracked,
  # committed file for a repo-level invariant to assert against.
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
  if [ -z "$PY" ]; then
    note "no python with tomllib — TOOLS block drift check skipped locally (CI enforces)"
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

check_mise_config_files() {
  hdr "mise config*.toml parse + lockfile coverage + min_version"
  local f
  for f in config.toml config.linux.toml config.dev.toml mise.lock mise.linux.lock mise.dev.lock; do
    [ -f "$f" ] || {
      bad "missing: $f"
      return
    }
  done
  if [ -z "$PY" ]; then
    note "no python with tomllib — parse/lock coverage skipped locally (CI enforces)"
  elif "$PY" - <<'PY'
import tomllib, sys

def load(f):
    with open(f, "rb") as fh:
        return tomllib.load(fh)

lockmap = {"config.toml": "mise.lock", "config.linux.toml": "mise.linux.lock", "config.dev.toml": "mise.dev.lock"}
missing = []
for f, need_win in (("config.toml", True), ("config.linux.toml", False), ("config.dev.toml", True)):
    ltools = load(lockmap[f]).get("tools", {})
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
        # pin<->lock version equality: a config pin bumped without `mise lock`
        # still passes coverage above (the lock entry exists, just stale) —
        # catch that here so every host doesn't silently rewrite the tracked
        # lock on its next `mise install`. "latest" pins have no fixed version
        # to compare. A lock entry can have multiple blocks (e.g. os=["linux"]
        # tools still carry an inert windows-x64 table); any matching block
        # is accepted.
        pin = spec.get("version") if isinstance(spec, dict) else spec
        if pin and pin != "latest":
            blocks = entries if isinstance(entries, list) else [entries]
            lock_vers = sorted({e.get("version") for e in blocks})
            if pin not in lock_vers:
                missing.append(f"{f}:{name} pin {pin} != lock {','.join(str(v) for v in lock_vers)} — run: MISE_ENV=linux,dev,host,native mise lock --global --platform linux-x64 && MISE_ENV=windows,dev mise lock --global --platform windows-x64")
if missing:
    print("\n".join(missing))
    sys.exit(1)
PY
  then
    ok "every [tools] entry has a lock entry (linux-x64; windows-x64 where it installs on Windows)"
  else
    bad "a config*.toml lock is missing entries — run: MISE_ENV=linux,dev,host,native mise lock --global --platform linux-x64 && MISE_ENV=windows,dev mise lock --global --platform windows-x64"
  fi
  # PR2 host-state files: config.host.toml / config.native.toml / config.wsl.toml
  # must parse and declare no [tools] (lock coverage above stays three files),
  # and config.toml must carry the four [vars] pins the host-state tasks read.
  if [ -z "$PY" ]; then
    note "no python with tomllib — host-state file / [vars] checks skipped locally (CI enforces)"
  else
    for f in config.host.toml config.native.toml config.wsl.toml; do
      if [ ! -f "$f" ]; then
        bad "missing: $f"
        continue
      fi
      if "$PY" - "$f" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
sys.exit(1 if "tools" in d else 0)
PY
      then
        ok "$f parses and declares no [tools]"
      else
        bad "$f declares [tools] — host-state files must not (lock coverage is three files)"
      fi
    done
    local vk vars_bad=0
    for vk in python_version nerd_font_version vcpkg_version zjstatus_zellij_floor; do
      if "$PY" - "$vk" <<'PY'
import sys, tomllib
with open("config.toml", "rb") as fh:
    d = tomllib.load(fh)
sys.exit(0 if sys.argv[1] in d.get("vars", {}) else 1)
PY
      then
        :
      else
        bad "config.toml [vars] missing: $vk"
        vars_bad=1
      fi
    done
    [ "$vars_bad" -eq 0 ] && ok "config.toml [vars] has all four host pins"
  fi
  if command -v mise >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp -d)"
    ln -s "$PWD" "$tmp/mise"
    if XDG_CONFIG_HOME="$tmp" MISE_ENV=linux,dev,host,native mise config ls >/dev/null 2>&1 &&
      env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$tmp" mise tasks validate >/dev/null 2>&1; then
      ok "mise loads the config files and validates tasks/"
    else
      bad "mise config ls / tasks validate failed against this checkout"
    fi
    rm -rf "$tmp"
  else
    note "mise not installed — config load check skipped"
  fi
  # locks/** sidecar layout — mise writes the pypi:/npm: dependency-locked
  # sidecars at locks/<lockfile-stem>/<backend>-<tool>/<version>/ under the
  # config root. A stale .mise/locks/** ref (the pre-move layout) silently
  # dirties every host's checkout on its next `mise install`, which rewrites
  # it to locks/ in place (see docs/claude/file-care.md).
  local lock_ok=1 pathref hint
  hint="run: mise lock --global (from OUTSIDE the checkout with XDG_CONFIG_HOME pointing at a dir whose mise/ is a symlink to it — see scripts/bump-versions.sh)"
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
  done < <(grep -ho 'path = "[^"]*"' mise.lock mise.linux.lock mise.dev.lock 2>/dev/null | sed -E 's/^path = "(.*)"$/\1/')
  if [ "$lock_ok" -eq 1 ]; then
    ok "every lock sidecar path ref is under locks/ and the directory exists"
  fi
  # Every pypi:/npm: lock entry must carry its dependency-lock sidecar ref
  # (pypi: `uv = { path = ... }`, npm: `aube = { path = ... }`). mise lock
  # SKIPS a pypi: sidecar with only a warning when no uv >= 0.12.10 is
  # installed. #152 shipped pypi:basedpyright@1.40.1 that way, and the first
  # `wsu` on a host then generated the sidecar inside the tracked checkout.
  # That left the tree dirty, so tasks/update's `git pull --ff-only` failed.
  if [ -n "$PY" ]; then
    local missing
    missing="$(
      "$PY" - mise.lock mise.linux.lock mise.dev.lock <<'PYEOF'
import sys, tomllib
for f in sys.argv[1:]:
    try:
        tools = tomllib.load(open(f, "rb")).get("tools", {})
    except FileNotFoundError:
        continue
    for name, entries in tools.items():
        key = {"pypi": "uv", "npm": "aube"}.get(name.split(":", 1)[0])
        if not key:
            continue
        for e in entries if isinstance(entries, list) else [entries]:
            if not isinstance(e.get(key), dict) or "path" not in e[key]:
                print(f"{f}: {name}@{e.get('version')} has no {key} dependency lock")
PYEOF
    )"
    if [ -n "$missing" ]; then
      while IFS= read -r m; do bad "$m — install uv (pypi:) then re-run: $hint"; done <<<"$missing"
    else
      ok "every pypi:/npm: lock entry carries its dependency-lock sidecar"
    fi
  else
    note "no python with tomllib — pypi:/npm: sidecar presence check skipped locally (CI enforces)"
  fi
}

# Every config.toml [vars] *_version pin must be reachable two ways, or a
# bump nobody sees: tasks/check-updates (the upstream-drift report) and
# scripts/gen-tool-memory.sh (the machine-memory inventory). zjstatus_zellij_
# floor is deliberately excluded (it's a coupling floor, not a pin — see
# check_zjstatus_zellij_coupling).
check_vars_pin_coverage() {
  hdr "config.toml [vars] *_version pins reachable by check-updates + gen-tool-memory"
  if [ -z "$PY" ]; then
    note "no python with tomllib — vars-pin coverage skipped locally (CI enforces)"
    return
  fi
  local keys key env_name missing="" n=0
  keys=$(
    "$PY" - <<'PY'
import tomllib
with open("config.toml", "rb") as fh:
    d = tomllib.load(fh)
for k in d.get("vars", {}):
    if k.endswith("_version"):
        print(k)
PY
  )
  while read -r key; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    env_name=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
    grep -q "$env_name" tasks/check-updates || missing="$missing $key(tasks/check-updates)"
    grep -q "$key" scripts/gen-tool-memory.sh || missing="$missing $key(gen-tool-memory.sh)"
  done <<<"$keys"
  if [ "$n" -gt 0 ] && [ -z "$missing" ]; then
    ok "all $n [vars] *_version pin(s) covered by tasks/check-updates + gen-tool-memory.sh"
  else
    bad "config.toml [vars] *_version pin(s) not fully covered:${missing:- <none derived>} — check-updates emits no line for these, or gen-tool-memory.sh doesn't read them"
  fi
}

# Bootstrap-config invariants over the four [bootstrap.*] TOML files (PR2
# Task 3): parse, hook shape + task existence + name uniqueness, file source
# existence + phase, package key shape + uniqueness + dropped names, the two
# no-sudo rulings (docs/superpowers/plans/2026-09-17-mise-host.md Rulings
# 1-2), and prod/Windows safety (config.toml/config.dev.toml never gain a
# [bootstrap] table). (h) is a live `mise bootstrap plan` — soft-skipped
# unless both mise and dnf are on PATH (CI has no dnf).
check_bootstrap_config() {
  hdr "bootstrap-config invariants (config.host/native/wsl/linux.toml)"
  if [ -z "$PY" ]; then
    note "no python with tomllib — bootstrap-config checks skipped locally (CI enforces)"
  else
    local out result detail
    out=$(
      "$PY" - <<'PY'
import os, re, tomllib

files = ["config.host.toml", "config.native.toml", "config.wsl.toml", "config.linux.toml"]
loaded = {}
for f in files:
    try:
        with open(f, "rb") as fh:
            loaded[f] = tomllib.load(fh)
        print(f"PASS|parse|{f} parses")
    except Exception as e:
        print(f"FAIL|parse|{f} failed to parse: {e}")

# (b)/(c): hooks — value shape ("mise run <task>"), task file exists, hook
# NAME appears in exactly one config file.
hook_re = re.compile(r"^mise run [a-z-]+$")
# post-dotfiles (config.linux.toml) is not a "mise run <task>" hook — it's the
# raw compound chmod restoring ~/.ssh and ~/.claude modes that copy/template
# mode can't express (PR3 Task 2 carry-forward: the ONLY guarantee of the SSH
# security posture). It must land byte-for-byte, so pin it to the exact
# verified-safe literal here rather than just exempting the shape check: a
# bare `chmod ... ; chmod ... ; true` LOOKS unconditional but is not — mise
# runs hooks as `sh -o errexit -c '<hook>'`, and errexit aborts at the first
# failing command in a `;`-chain (verified: on a prod host, MISE_ENV=linux
# never loads config.dev.toml, so ~/.claude never exists, and the first
# chmod's failure on that missing operand aborted the whole bootstrap before
# `; true` was ever reached). Each command needs its own `|| true`.
EXPECTED_POST_DOTFILES_HOOK = (
    "chmod 700 ~/.ssh ~/.claude 2>/dev/null || true; "
    "chmod 600 ~/.ssh/config 2>/dev/null || true; "
    "chmod 600 ~/.config/mise/dotfiles/ssh/config.tera 2>/dev/null || true"
)
seen = {}
bad_hooks = []
n_hooks = 0
for f, d in loaded.items():
    for name, val in d.get("bootstrap", {}).get("hooks", {}).items():
        n_hooks += 1
        if name == "post-dotfiles":
            if val != EXPECTED_POST_DOTFILES_HOOK:
                bad_hooks.append(f"{f}:post-dotfiles != the verified-safe literal (got {val!r})")
            seen.setdefault(name, []).append(f)
            continue
        if not hook_re.match(val):
            bad_hooks.append(f"{f}:{name}={val!r} (want 'mise run <task>')")
            continue
        task = val.split("mise run ", 1)[1]
        if not os.path.isfile(os.path.join("tasks", task)):
            bad_hooks.append(f"{f}:{name} -> task file tasks/{task} missing")
        seen.setdefault(name, []).append(f)
if bad_hooks:
    print("FAIL|hooks|" + "; ".join(bad_hooks))
else:
    print(f"PASS|hooks|{n_hooks} hook(s) are 'mise run <task>' (task file exists) or the pinned post-dotfiles literal")
dupes = [f"{name} in {fs}" for name, fs in seen.items() if len(fs) > 1]
if dupes:
    print("FAIL|hook-unique|duplicated hook name(s) across config files: " + "; ".join(dupes))
else:
    print(f"PASS|hook-unique|{len(seen)} hook name(s) each appear in exactly one config file")

# (d): files — source exists relative to the repo root, phase valid when present.
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

# (e): packages — dnf: prefix, unique across host+native, dropped names absent.
dropped = {"dnf:fswatch", "dnf:entr", "dnf:cockpit-networkmanager", "dnf:shellcheck"}
seen_pkg = {}
bad_pkg = []
for f in ("config.host.toml", "config.native.toml"):
    for key in loaded.get(f, {}).get("bootstrap", {}).get("packages", {}):
        if not key.startswith("dnf:"):
            bad_pkg.append(f"{f}:{key} (missing dnf: prefix)")
        if key in dropped:
            bad_pkg.append(f"{f}:{key} (dropped name — not packaged/virtual/renamed on EL9)")
        seen_pkg.setdefault(key, []).append(f)
pkg_dupes = [f"{k} in {fs}" for k, fs in seen_pkg.items() if len(fs) > 1]
if bad_pkg or pkg_dupes:
    print("FAIL|packages|" + "; ".join(bad_pkg + pkg_dupes))
else:
    print(f"PASS|packages|{len(seen_pkg)} dnf: package key(s) across host+native, unique, no dropped names")

# (f): no [bootstrap.linux.firewall] and no [bootstrap.user] anywhere (rulings 1-2).
ruling_hits = []
for f, d in loaded.items():
    bs = d.get("bootstrap", {})
    if "user" in bs:
        ruling_hits.append(f"{f} has [bootstrap.user] (ruling 2: chsh needs util-linux-user + prompts for a password)")
    linux = bs.get("linux", {})
    if isinstance(linux, dict) and "firewall" in linux:
        ruling_hits.append(f"{f} has [bootstrap.linux.firewall] (ruling 1: aborts unprivileged mise bootstrap plan/status)")
if ruling_hits:
    print("FAIL|rulings|" + "; ".join(ruling_hits))
else:
    print("PASS|rulings|no [bootstrap.linux.firewall] or [bootstrap.user] table (rulings 1-2)")

# (g): config.toml / config.dev.toml carry no [bootstrap] table (prod hosts / Windows never load one).
prod_hits = []
for f in ("config.toml", "config.dev.toml"):
    try:
        with open(f, "rb") as fh:
            d = tomllib.load(fh)
    except Exception as e:
        prod_hits.append(f"{f} failed to parse: {e}")
        continue
    if "bootstrap" in d:
        prod_hits.append(f"{f} has a [bootstrap] table (prod hosts / Windows must never load one)")
if prod_hits:
    print("FAIL|prod-safety|" + "; ".join(prod_hits))
else:
    print("PASS|prod-safety|config.toml and config.dev.toml carry no [bootstrap] table")
PY
    )
    while IFS='|' read -r result _ detail; do
      [ -n "$result" ] || continue
      if [ "$result" = PASS ]; then
        ok "$detail"
      else
        bad "$detail"
      fi
    done <<<"$out"
  fi

  # (h) live plan — dev host with dnf only; CI has no dnf.
  if command -v mise >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    if MISE_ENV=linux,dev,host,native mise bootstrap plan --json >/dev/null 2>&1; then
      ok "mise bootstrap plan --json (MISE_ENV=linux,dev,host,native) exits 0"
    else
      bad "mise bootstrap plan --json (MISE_ENV=linux,dev,host,native) failed"
    fi
  else
    note "mise and/or dnf not on PATH — skipped the live 'mise bootstrap plan' check (CI has no dnf)"
  fi
}

check_dotfiles_config() {
  hdr "dotfiles-config invariants (config.toml/linux/dev/host/windows.toml [dotfiles])"
  if [ -z "$PY" ]; then
    note "no python with tomllib — dotfiles-config checks skipped locally (CI enforces)"
    return
  fi
  local out result detail
  out=$(
    "$PY" - <<'PY'
import glob, os, tomllib

# config.local.toml (git-ignored, per-host) is deliberately excluded: it
# exists precisely to REPEAT a key from one of these five files (the
# { mode = ..., enabled = false } override pattern — findings.md §9), so a
# "no entry in two files" check would misfire against its own documented use.
# config.host.toml joined this list in PR3 Task 3 (gdbinit/gdb/herdr config
# moved there from config.dev.toml so they stop deploying dead files on a
# Windows dev host — see config.host.toml's own [dotfiles] comment).
files = ["config.toml", "config.linux.toml", "config.dev.toml", "config.host.toml", "config.windows.toml"]
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
entries = []  # (file, target, spec)
for f, d in loaded.items():
    for target, spec in d.get("dotfiles", {}).items():
        if isinstance(spec, str):
            spec = {"source": spec, "mode": "symlink"}
        entries.append((f, target, spec))

# (a) every entry's source exists.
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

# (b) every mode is one of the five.
bad_mode = []
for f, target, spec in entries:
    mode = spec.get("mode")
    if mode not in VALID_MODES:
        bad_mode.append(f"{f}:{target} mode={mode!r} (want one of {sorted(VALID_MODES)})")
if bad_mode:
    print("FAIL|mode-valid|" + "; ".join(bad_mode))
else:
    print(f"PASS|mode-valid|every entry's mode is one of {sorted(VALID_MODES)}")

# (c) ruling 7, broadened by the 2026-09-22 copy-migration (user decision:
# chezmoi's copy semantics survive applications on either OS that don't
# respect symlinks): no `[dotfiles]` entry, in ANY of the five files, on ANY
# platform, is `symlink` or `symlink-each` any more — every entry is `copy`
# or `template`. This used to iterate only the entries that actually LOAD on
# a Windows host (config.toml + config.dev.toml + config.windows.toml —
# config.linux.toml and config.host.toml never load there), because before
# this migration a `symlink`/`symlink-each` entry was fine as long as it was
# Linux-only; a bare `symlink` on Windows needs Developer Mode and silently
# falls back to copy (functional but undeclared) and a directory `symlink`
# becomes a junction instead of a copy. Now the rule is unconditional, so
# checking "every entry" and "every Windows-loaded entry" catch the same
# thing — this checks everything directly rather than re-deriving the
# Windows-load gate. check-invariants I4 (final-fix-brief.md) is the reason
# this iterates all 5 files rather than just config.windows.toml (a
# `windows,dev` scratch apply proved config.toml/config.dev.toml entries
# land on a Windows host too).
bad_symlink = []
n_total = 0
for f, target, spec in entries:
    n_total += 1
    mode = spec.get("mode", "symlink")
    if mode in ("symlink", "symlink-each"):
        bad_symlink.append(f"{f}:{target} mode={mode!r} (want copy or template — symlink/symlink-each are retired everywhere, ruling 7)")
if bad_symlink:
    print("FAIL|no-symlink-anywhere|" + "; ".join(bad_symlink))
else:
    print(f"PASS|no-symlink-anywhere|{n_total} entries across all 5 config files are copy or template, none symlink/symlink-each")

# (d) every entry with a directory source and an `exclude` list covers every
# .vendor/.gitkeep sidecar actually present there. Used to only check
# `symlink-each` entries (the only mode that took `exclude` pre-migration);
# now every directory entry is `copy` instead, so this checks any entry that
# DECLARES `exclude` at all, regardless of mode — the controller verified
# `exclude` works for `copy` on a directory source the same way it worked
# for `symlink-each`.
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

# (e) no target key appears in more than one of the four files.
seen = {}
for f, target, _spec in entries:
    seen.setdefault(target, []).append(f)
dupes = [f"{t} in {fs}" for t, fs in seen.items() if len(fs) > 1]
if dupes:
    print("FAIL|no-dupes|target(s) declared in more than one config file: " + "; ".join(dupes))
else:
    print(f"PASS|no-dupes|{len(seen)} distinct target(s), none declared in more than one config file")

# (f) every .tera file under dotfiles/ is referenced by exactly one entry
# (no orphans, no double-use of one template by two targets).
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
  )
  while IFS='|' read -r result _ detail; do
    [ -n "$result" ] || continue
    if [ "$result" = PASS ]; then
      ok "$detail"
    elif [ "$result" = NOTE ]; then
      note "$detail"
    else
      bad "$detail"
    fi
  done <<<"$out"
}

check_lsp_plugin() {
  hdr "workstation-lsp plugin manifest"
  local src="dotfiles/claude/skills/workstation-lsp"
  # Both leading dots are load-bearing: Claude Code's own plugin-manifest
  # convention needs .claude-plugin/plugin.json, and the LSP registry needs
  # .lsp.json. dotfiles/ keeps them literally, matching the real ~/.claude
  # tree (PR3 Task 2: workstation-lsp/ nests inside the `~/.claude/skills`
  # [dotfiles] entry in config.dev.toml — copy mode, 2026-09-22 migration —
  # so nested names deploy exactly as spelled here).
  if [ ! -f "$src/.claude-plugin/plugin.json" ] || [ ! -f "$src/.lsp.json" ]; then
    bad "missing workstation-lsp plugin source ($src/.claude-plugin/plugin.json + .lsp.json)"
    return
  fi
  if ! command -v claude >/dev/null 2>&1; then
    note "claude not installed — skipped LSP plugin validate (dev hosts enforce; CI has no claude)"
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
    dotfiles/config/bash/completions.bash |
    grep -oE -- '--[a-z-]+' | sort -u
}

# Quoted "-Flag" values from one `let workstation_*_flags` list in config.nu.tmpl.
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

  want=$(_sh_script_flags bootstrap.sh --full --checkforupdates)
  _flags_eq "bootstrap.sh == _bootstrap.sh (zsh)" "$want" \
    "$(_zsh_completion_flags dotfiles/config/zsh/completions/_bootstrap.sh)"
  _flags_eq "bootstrap.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_bootstrap)"

  want=$(_sh_script_flags scripts/manage-hosts.sh)
  _flags_eq "manage-hosts.sh == _manage-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags dotfiles/config/zsh/completions/_manage-hosts.sh)"
  _flags_eq "manage-hosts.sh == completions.bash" "$want" \
    "$(_bash_completion_flags _workstation_complete_manage_hosts)"

  want=$(_sh_script_flags scripts/update-hosts.sh)
  _flags_eq "update-hosts.sh == _update-hosts.sh (zsh)" "$want" \
    "$(_zsh_completion_flags dotfiles/config/zsh/completions/_update-hosts.sh)"
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
# PY_LIBS in scripts/lib/python-env.sh and $PythonLibs in bootstrap.ps1. Both
# are one-line arrays by contract (comments at each site) so single-line greps
# can extract them. Order-insensitive compare (sort) — content is the contract.
check_zjstatus_zellij_coupling() {
  hdr "zjstatus <-> zellij plugin-ABI floor"
  local zj zjs floor
  if [ -z "$PY" ]; then
    note "no python with tomllib — zjstatus/zellij coupling skipped locally (CI enforces)"
    return
  fi
  zj=$(tomlval config.linux.toml tools.zellij)
  zjs=$(tomlval config.linux.toml 'tools."github:dj95/zjstatus"')
  floor=$(tomlval config.toml vars.zjstatus_zellij_floor)
  if [ -z "$zj" ] || [ -z "$zjs" ] || [ -z "$floor" ]; then
    bad "could not read tools.zellij / tools.\"github:dj95/zjstatus\" from config.linux.toml, or vars.zjstatus_zellij_floor from config.toml"
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

check_mise_install_lib() {
  hdr "mise install lib (scripts/lib/mise-install.sh: force-reinstall-on-change, tasks/migrate-legacy, tasks/verify-tools)"
  local out
  # Offline behavioural test with a fake `mise` on PATH and a scratch HOME.
  if out=$(bash scripts/test-mise-install.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-mise-install.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}

check_python_env_parity() {
  hdr "python-env lib-list parity (python-env.sh == bootstrap.ps1)"
  local sh_libs ps_libs
  sh_libs=$(grep -oE '^PY_LIBS=\([^)]*\)' scripts/lib/python-env.sh |
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
  local -a targets=(bootstrap.sh scripts/*.sh scripts/lib/*.sh tasks/*
    .claude/hooks/*.sh dotfiles/claude/hooks/*.sh
    dotfiles/claude/notify.sh
    dotfiles/local/bin/winterop
    dotfiles/config/bash/completions.bash)
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
  # Same first-party set as shellcheck (vendored _cht.sh / batpipe excluded).
  local -a targets=(bootstrap.sh scripts/*.sh scripts/lib/*.sh tasks/*
    .claude/hooks/*.sh dotfiles/claude/hooks/*.sh
    dotfiles/claude/notify.sh
    dotfiles/local/bin/winterop
    dotfiles/config/bash/completions.bash)
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
  local dir=dotfiles/config/zellij
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

check_go_gopls_coupling() {
  hdr "gopls <-> Go toolchain floor"
  local gov goplsv floor
  if [ -z "$PY" ]; then
    note "no python with tomllib — go/gopls coupling skipped locally (CI enforces)"
    return
  fi
  gov=$(tomlval config.dev.toml tools.go)
  goplsv=$(tomlval config.dev.toml 'tools."go:golang.org/x/tools/gopls"')
  if [ -z "$gov" ] || [ -z "$goplsv" ]; then
    bad "could not read tools.go / tools.\"go:golang.org/x/tools/gopls\" from config.dev.toml"
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
    bad "gopls $goplsv requires go >= $floor but tools.go (config.dev.toml) is $gov — \`mise install\` would fail on gopls, leaving it stale or absent; bump both together"
  fi
}

check_tsls_typescript_coupling() {
  hdr "typescript-language-server <-> typescript major"
  local post tsv tslsv major
  post=$(grep -E '^node = ' config.dev.toml)
  tslsv=$(grep -oE 'typescript-language-server@[0-9.]+' <<<"$post" | cut -d@ -f2)
  tsv=$(grep -oE 'typescript@[0-9.]+' <<<"$post" | cut -d@ -f2)
  if [ -z "$tsv" ] || [ -z "$tslsv" ]; then
    bad "could not read typescript / typescript-language-server versions from config.dev.toml's node postinstall"
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
check_mise_env_three_way
check_bumper_exclude
check_line_endings_and_mode
check_dotfiles_mode
check_bom
check_ps_variable_drive_refs
check_sentinels
check_tools_block
check_mise_config_files
check_vars_pin_coverage
check_bootstrap_config
check_dotfiles_config
check_lsp_plugin
check_completion_parity
check_warp_guards
check_zellij_config
check_go_gopls_coupling
check_tsls_typescript_coupling
check_zjstatus_zellij_coupling
check_zellij_plugin_installer
check_mise_install_lib
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
