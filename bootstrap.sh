#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — workstation setup (mise seed)
#
# Exactly one of --dev or --prod is required — it picks the MISE_ENV token
# set `mise bootstrap` loads (scripts/lib/mise-env.sh maps MACHINE_TYPE →
# MISE_ENV):
#
#   DEV  (host you own, sudo for system packages + /etc files; tools are user-level):
#     ./bootstrap.sh --dev
#
#   PROD (host you don't fully own, no sudo, install to ~/.local/bin):
#     curl -fsSL https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod
#     or: ./bootstrap.sh --prod
#
# MISE_ENV picks which config*.toml [bootstrap.*] tables load (dnf packages,
# /etc files, services, compose, repos, hooks) — dev hosts load host state
# that needs sudo, prod hosts load none. Each host updates itself afterwards
# with `wsu` (`mise run update`); there is no central host list or fleet
# rollout (removed 2026-09-24).
#
# REINSTALL — wipe the cloned repo + any leftover pre-migration chezmoi
# state, then re-bootstrap fresh. Does NOT remove installed tools or deployed
# dotfiles (those are idempotent under re-bootstrap). Combine with --dev/--prod
# and optional --yes:
#
#     ./bootstrap.sh --prod --reinstall          # prod-scope wipe + rebuild, prompts
#     ./bootstrap.sh --dev --reinstall --yes
#
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes that exit before any
# provisioning happens (nothing is cloned, installed, or changed):
#
#     ./bootstrap.sh --dev --doctor              # health: tools, services, repo, dotfiles
#     ./bootstrap.sh --dev --check-for-updates   # repo first, then pins vs upstream tags
#
# This script owns only the repo-level checks (prereqs, git branch/
# ahead/behind/dirty, dotfiles drift, login shell) — these modes front
# `mise run health` / `mise run check-updates`, which carry ALL per-tool and
# per-host-state knowledge (tasks/, config*.toml).
#
# PRIVATE REPO — set GITHUB_TOKEN before running. It is used for both the
# bootstrap.sh fetch AND the script's internal git clone/pull.
#
#   export GITHUB_TOKEN='<your-PAT>'
#   curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
#     https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash
#
# Flow (both modes):
#   1. preflight             — check curl/git/tar
#   1a. do_reinstall (opt.)  — wipe the cloned repo + any leftover
#                              pre-migration chezmoi state (--reinstall); then
#                              falls through to a fresh run
#   1.5. relocate_repo       — one-time move of a pre-2026-09 checkout from
#                              ~/.local/share/chezmoi to ~/.config/mise (idempotent)
#   2. clone repo            — into ~/.config/mise (or git pull if present)
#   2.5. install_mise        — the pinned mise binary into ~/.local/bin
#                              (sha256-verified)
#   2.6. MISE_ENV             — resolved from MACHINE_TYPE via
#                              scripts/lib/mise-env.sh and exported
#   3.5. user-manager env    — `systemctl --user set-environment MISE_ENV=…`
#                              so the live systemd user manager sees it too
#                              (the pueued shim needs MISE_ENV to resolve mise)
#   3.6. ensure_config_local — write/migrate config.local.toml (per-host
#                              vars.name/vars.email) BEFORE any dotfiles
#                              render — see the function's own header.
#   4. mise install (tools)  — scripts/lib/mise-install.sh installs every
#                              tool the active MISE_ENV declares
#   4.5. mise bootstrap      — packages, /etc files, services, compose,
#                              repos, dotfiles (--force-dotfiles on the first
#                              run only, see run_bootstrap), tools gate, then
#                              the `bootstrap` task
#   4c. set_default_shell    — `sudo usermod -s "$(command -v zsh)" "$USER"`
#                              on --dev only. ~/.zshrc is a mise dotfiles
#                              template; we switch the login shell so new
#                              SSH/WSL sessions land in zsh. Best-effort:
#                              prints the manual chsh command on prod or
#                              when usermod isn't permitted.
#
# WSL — running inside a WSL distro is supported and treated as a managed host
# for tools + dotfiles, but NOT as an SSH target. is_wsl() (defined below)
# detects WSL via $WSL_DISTRO_NAME or /proc/version's microsoft marker; the
# end-of-bootstrap ssh-copy-id tip is replaced by a WSL-specific one.
#
# Tool versions, dnf packages, /etc files, services, PATH wiring, dotfiles —
# everything lives in config*.toml [bootstrap.*]/[dotfiles] tables and global
# mise tasks under tasks/ (discovered from this checkout, mise's global
# config dir). bootstrap.sh has no per-tool knowledge.
# =============================================================================

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

log() { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
ok() { echo -e "${GREEN} ✓${RESET} $*"; }
warn() { echo -e "${YELLOW} !${RESET} $*"; }
fail() {
  echo -e "${RED} ✗${RESET} $*"
  exit 1
}

# WSL detection — used to swap the end-of-bootstrap ssh-copy-id tip for a
# WSL one. WSL distros are launched directly by the Windows-side terminal
# (Windows Terminal's WSL profile, `wsl.exe`), not SSH'd into.
#   - WSL_DISTRO_NAME is exported by WSL 2 inside the distro
#   - /proc/version's "microsoft" marker is the universal backup signal
is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
# The checkout IS mise's global config dir (config*.toml, mise.lock, tasks/ live at its root).
REPO_DIR="$HOME/.config/mise"
LEGACY_REPO_DIR="$HOME/.local/share/chezmoi" # pre-2026-09 location; relocate_repo() moves it
BIN="$HOME/.local/bin"
# The ONE pin bootstrap owns: mise itself (everything else is in config*.toml).
# DUAL-EDIT with bootstrap.ps1 $PortableTools (mise) and min_version in config.toml —
# scripts/check-invariants.sh asserts all three agree.
MISE_VERSION="2026.9.9"
MISE_SHA256="986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc" # mise-v${MISE_VERSION}-linux-x64-musl.tar.gz

# http.extraheader key scoped to github.com so the token never leaks to
# other remotes. Stored in the cloned repo's .git/config so subsequent
# git push, git pull, and manual git ops all authenticate.
GH_HEADER_KEY="http.https://github.com/.extraheader"

# --- Argument parsing -------------------------------------------------------
# Accepts in any order: --dev | --prod (exactly one required), --reinstall,
# --yes/-y, --doctor | --check-for-updates (read-only report modes).
MACHINE_TYPE=""
REINSTALL=false
YES=false
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dev)
    [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
    MACHINE_TYPE="dev"
    shift
    ;;
  --prod)
    [[ -n "$MACHINE_TYPE" ]] && fail "--dev and --prod are mutually exclusive"
    MACHINE_TYPE="prod"
    shift
    ;;
  --doctor)
    [[ -n "$ACTION" ]] && fail "--doctor and --check-for-updates are mutually exclusive"
    ACTION="doctor"
    shift
    ;;
  --check-for-updates | --checkforupdates)
    [[ -n "$ACTION" ]] && fail "--doctor and --check-for-updates are mutually exclusive"
    ACTION="check-updates"
    shift
    ;;
  --full)
    fail "--full was removed.

Use one of the new mutually-exclusive flags:
  ./bootstrap.sh --dev      # Host you own        — sudo for system packages + /etc files; tools are user-level
  ./bootstrap.sh --prod     # Host you don't own  — no sudo, ~/.local/bin only

Run ./bootstrap.sh --help for the full flag list."
    ;;
  --reinstall)
    REINSTALL=true
    shift
    ;;
  --yes | -y)
    YES=true
    shift
    ;;
  -h | --help)
    cat <<'EOF'
Usage: ./bootstrap.sh (--dev | --prod) [flags]

Required (exactly one):
  --dev         Host you own. Sudo available for system packages + /etc
                files (dnf on RHEL/Fedora today); tools install user-level.
  --prod        Host you don't fully own. No sudo. Installs user-wide to
                ~/.local/bin.

Optional flags:
  --reinstall   Wipe the cloned repo and any leftover pre-migration chezmoi
                state, then bootstrap fresh. Does NOT remove installed
                tools or deployed dotfiles (those are no-op idempotent on
                re-bootstrap).
  --yes, -y     Skip the --reinstall confirmation prompt.
  --doctor      Read-only health report, then exit (provisions nothing):
                prereqs, repo git state (branch, ahead/behind, dirty),
                dotfiles drift, login shell, then every managed
                tool/host-state/service via 'mise run health'.
  --check-for-updates
                Read-only update scan, then exit: the workstation repo
                first (fetch + commits-behind), then every pinned tool
                against its upstream release tags via 'mise run check-updates'
                (git ls-remote — no GitHub API, no rate limits).
                --checkforupdates is accepted as an alias.
  -h, --help    Show this message.
EOF
    exit 0
    ;;
  *) fail "Unknown argument: $1 (try --help)" ;;
  esac
done

if [[ -z "$MACHINE_TYPE" ]]; then
  fail "Missing required flag: --dev or --prod.

Pick one based on the host you're bootstrapping:
  ./bootstrap.sh --dev      # Host you own        — sudo for system packages + /etc files; tools are user-level
  ./bootstrap.sh --prod     # Host you don't own  — no sudo, ~/.local/bin only

Curl-pipe form (private repo with token):
  curl -fsSL -H \"Authorization: token \$GITHUB_TOKEN\" \\
    https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --prod

Run ./bootstrap.sh --help for all flags."
fi

# Derived value written to config.local.toml as vars.group (ensure_config_local),
# which the rc templates read to bake the right MISE_ENV.
GROUP_NAME="${MACHINE_TYPE}_machine"

# The report modes are read-only — combining them with the wipe flag is
# almost certainly a mistake, so refuse rather than surprise.
if [[ -n "$ACTION" && "$REINSTALL" == true ]]; then
  fail "--reinstall can't be combined with --doctor/--check-for-updates (they are read-only and exit early)"
fi

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + any leftover pre-migration
#    chezmoi config, then let the rest of the script re-bootstrap fresh.
#    Installed tools and deployed dotfiles are left alone — re-running the
#    bootstrap is idempotent on those, so the net effect is a fresh repo +
#    fresh config.local.toml prompt (Step 3.6, ensure_config_local).
# =============================================================================
do_reinstall() {
  log "Reinstall mode — wipe + re-bootstrap"
  echo ""
  echo "  Will REMOVE:"
  echo "    - $REPO_DIR   (cloned workstation repo)"
  if [[ -d "$LEGACY_REPO_DIR" ]]; then
    echo "    - $LEGACY_REPO_DIR   (pre-relocation checkout, not yet swept)"
  fi
  if [[ -d "$HOME/.config/chezmoi" ]]; then
    echo "    - $HOME/.config/chezmoi/{chezmoistate.boltdb,chezmoi.toml}   (leftover pre-migration chezmoi state, if any — key.txt, if any, is preserved)"
  fi
  echo ""
  echo "  Will NOT remove (leaving for re-bootstrap to no-op over):"
  echo "    - Installed tools in ~/.local/bin (tools are user-level since PR1)"
  echo "    - dnf packages, SSH keys"
  echo "    - Deployed dotfiles in \$HOME (mise bootstrap will re-apply over them)"
  echo ""
  echo "  For a deeper uninstall (remove tools too), do that manually first:"
  echo "    mise implode                 # removes every mise-installed tool + mise's data dir"
  echo "    rm -rf ~/.local/share/mise   # if implode isn't available (older mise, or already gone)"
  echo ""

  # Self-deletion guard: if this script is being run from inside the path
  # we're about to delete, refuse. Use the curl-pipe form instead — it
  # streams the script body through bash without backing it on disk.
  local script_path="${BASH_SOURCE[0]}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_real
    script_real=$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")
    if [[ "$script_real" == "$REPO_DIR"* || "$script_real" == "$LEGACY_REPO_DIR"* ]]; then
      fail "Refusing to reinstall — running script is inside $REPO_DIR or $LEGACY_REPO_DIR.
Either pipe the remote script (runs from memory):
  curl -fsSL -H \"Authorization: token \$GITHUB_TOKEN\" \\
    https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.sh | bash -s -- --${MACHINE_TYPE} --reinstall

Or copy this script out of the repo first:
  cp $script_real /tmp/bootstrap.sh && bash /tmp/bootstrap.sh --${MACHINE_TYPE} --reinstall"
    fi
  fi

  if [[ "$YES" != true ]]; then
    read -rp "  Proceed? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "Aborted."
      exit 0
    fi
  fi

  if [[ -d "$REPO_DIR" ]]; then
    log "Removing $REPO_DIR..."
    rm -rf "$REPO_DIR"
    ok "Repo removed"
  else
    log "$REPO_DIR not present — nothing to remove"
  fi

  if [[ -d "$LEGACY_REPO_DIR" ]]; then
    log "Removing $LEGACY_REPO_DIR..."
    rm -rf "$LEGACY_REPO_DIR"
    ok "Legacy repo removed"
  else
    log "$LEGACY_REPO_DIR not present — nothing to remove"
  fi

  if [[ -d "$HOME/.config/chezmoi" ]]; then
    # I9 fix (final-fix-brief.md): tasks/migrate-legacy's own chezmoi sweep
    # deliberately removes only chezmoistate.boltdb + chezmoi.toml, never
    # key.txt (the age identity, if a host ever had one, is out-of-band and
    # not ours to touch or judge — see that task's own comment). A whole-
    # directory rm -rf here disagreed and would take key.txt with it. Match
    # tasks/migrate-legacy exactly: same two paths, nothing else.
    log "Removing leftover $HOME/.config/chezmoi state (chezmoistate.boltdb, chezmoi.toml)..."
    rm -f "$HOME/.config/chezmoi/chezmoistate.boltdb" "$HOME/.config/chezmoi/chezmoi.toml"
    ok "leftover pre-migration chezmoi state removed (key.txt, if any, preserved)"
  fi

  echo ""
  log "Wipe complete — continuing with fresh bootstrap..."
  echo ""
}

# =============================================================================
# 1. PREFLIGHT — collect-all prereq check
# =============================================================================
preflight() {
  log "Checking prerequisites..."

  local missing=()
  command -v curl &>/dev/null || missing+=("curl")
  command -v git &>/dev/null || missing+=("git")
  command -v tar &>/dev/null || missing+=("tar (for archive extraction)")

  if ((${#missing[@]} > 0)); then
    fail "Missing required prerequisites: ${missing[*]}
Install via your distro's package manager, e.g.
  RHEL/Fedora:   sudo dnf install curl git tar
  Debian/Ubuntu: sudo apt install curl git tar"
  fi

  ok "Prerequisites OK"
}

# =============================================================================
# 1.5 RELOCATE — the checkout moved from ~/.local/share/chezmoi to ~/.config/mise
# (this repo IS mise's global config dir since 2026-09). One-time, idempotent.
# A pre-existing ~/.config/mise (the chezmoi-deployed conf.d era) is moved aside.
# =============================================================================
relocate_repo() {
  [[ -d "$REPO_DIR/.git" ]] && return 0
  [[ -d "$LEGACY_REPO_DIR/.git" ]] || return 0
  log "Relocating the workstation checkout: $LEGACY_REPO_DIR → $REPO_DIR"
  if [[ -e "$REPO_DIR" ]]; then
    local aside
    aside="$REPO_DIR.pre-relocation.$(date +%Y%m%d%H%M%S)"
    mv "$REPO_DIR" "$aside" || fail "could not move aside $REPO_DIR"
    warn "moved the old $REPO_DIR (chezmoi-deployed mise conf.d) to $aside — delete it once the new layout works"
  fi
  mkdir -p "$(dirname "$REPO_DIR")"
  mv "$LEGACY_REPO_DIR" "$REPO_DIR" || fail "could not move $LEGACY_REPO_DIR to $REPO_DIR"
  ok "checkout now at $REPO_DIR"
}

# =============================================================================
# 2.5 MISE — the pinned mise binary into ~/.local/bin (sha256-verified). mise
# installs every other tool from config*.toml; the Make layer only orchestrates.
# =============================================================================
install_mise() {
  if [[ -x "$BIN/mise" ]] && [[ "$("$BIN/mise" --version 2>/dev/null | awk '{print $1}')" == "$MISE_VERSION" ]]; then
    ok "mise $MISE_VERSION present ($BIN/mise)"
    return 0
  fi
  log "Installing mise $MISE_VERSION into $BIN..."
  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64-musl.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/mise.tgz" "$url" || fail "mise download failed: $url"
  printf '%s  %s\n' "$MISE_SHA256" "$tmp/mise.tgz" | sha256sum -c --quiet - || fail "mise tarball sha256 mismatch — refusing to install"
  tar -xzf "$tmp/mise.tgz" -C "$tmp"
  install -m 0755 "$tmp/mise/bin/mise" "$BIN/mise"
  rm -rf "$tmp"
  ok "mise $MISE_VERSION installed ($BIN/mise)"
}

# =============================================================================
# 3.6. ENSURE CONFIG.LOCAL.TOML — per-host `[vars]` (name/email/group) that
# used to live in chezmoi.toml's [data] block. mise's Tera dotfiles templates
# read them as vars.name/vars.email/vars.group (every reference guarded —
# Ruling 3 — so a missing file doesn't abort the apply, but a real value
# still shapes the rendered ~/.gitconfig etc.), so this MUST run before the
# first `mise bootstrap` dotfiles apply. vars.group additionally gates which
# MISE_ENV token set zshenv.tera/bashrc.tera/10-mise.conf.tera bake in
# (dev_machine -> linux,dev,host,…; anything else -> linux) — see
# scripts/lib/mise-env.sh, the canonical source of those token sets.
# Idempotent: once the file exists, only a missing vars.group is repaired
# (see repair_config_local_group below); name/email are never touched again.
#
# Migration: a host that already ran chezmoi has name/email/group cached in
# ~/.config/chezmoi/chezmoi.toml's [data] table — read them from there
# instead of prompting (parsed with tomllib, never sed/grep: TOML string
# escaping is not regex-safe). Fresh hosts (no chezmoi.toml, or python
# lacking tomllib) fall back to prompting via /dev/tty, reusing the same
# FD-open guard PR2's chezmoi-init step used: `[[ ! -r /dev/tty ]]` is an
# access(2) test that returns true (readable) even under `ssh host 'cmd'`
# with no controlling terminal, so it never actually detects "no TTY" — open
# the descriptor for real instead, which fails when there truly is none.
# group falls back to this run's $GROUP_NAME ("${MACHINE_TYPE}_machine")
# whenever chezmoi.toml has none to migrate.
# =============================================================================
# Idempotent repair for a config.local.toml written by an earlier bootstrap.sh
# that predates vars.group (2026-09-19 fix: MISE_ENV was baking as "linux" on
# every host because nothing ever wrote vars.group — see the fix report).
# Appends `group = "$GROUP_NAME"` when the file exists but never got one.
# Parsed with tomllib — never sed/grep — for the same TOML-escaping reason
# ensure_config_local's own migration path below uses it. No-ops (with a
# warning) when no tomllib-capable interpreter is on PATH; the next
# bootstrap run that has one will repair it then.
repair_config_local_group() {
  local target="$1" py="$2"
  if [[ -z "$py" ]]; then
    warn "no tomllib-capable python on PATH — cannot check $target for vars.group (skipping repair)"
    return 0
  fi
  if "$py" - "$target" <<'PYEOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
sys.exit(0 if (data.get("vars") or {}).get("group") else 1)
PYEOF
  then
    return 0 # vars.group already present — nothing to do
  fi
  local group="$GROUP_NAME"
  # I2 fix (final-fix-brief.md): a bare `>>` append glues onto whatever table
  # happens to be last in the file. scripts/setup-ccstatusline.sh legitimately
  # appends a [dotfiles] table to this same config.local.toml, so an EOF
  # append after that runs lands `group = "..."` inside [dotfiles] instead of
  # [vars] (run 1: a bogus dotfiles.group key; run 2: the file no longer
  # parses at all — "Cannot overwrite a value" — and mise can't load its
  # global config). Insert the key on the line right after the `[vars]`
  # header instead, via tomllib — never a bare `>>` — and re-parse afterward
  # to prove the insert landed in the right table before trusting it.
  if ! "$py" - "$target" "$group" <<'PYEOF'
import sys
import tomllib

path, group = sys.argv[1], sys.argv[2]
esc = group.replace("\\", "\\\\").replace('"', '\\"')
new_line = 'group = "%s"\n' % esc

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.strip() == "[vars]":
        out.append(new_line)
        inserted = True
if not inserted:
    # No [vars] table at all (shouldn't happen — ensure_config_local always
    # writes one) — prepend a fresh one rather than risk an EOF append
    # landing in whatever table happens to be last.
    out = ["[vars]\n", new_line] + out

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)

# Re-parse to prove the rewrite didn't corrupt the file and the key landed
# in [vars], not wherever EOF happened to be.
with open(path, "rb") as f:
    check = tomllib.load(f)
if (check.get("vars") or {}).get("group") != group:
    sys.exit(1)
PYEOF
  then
    warn "failed to repair $target's vars.group safely — inspect by hand ([vars] table, vars.group=$GROUP_NAME)"
    return 1
  fi
  ok "repaired $target: inserted vars.group=$GROUP_NAME under [vars] (was missing)"
}

ensure_config_local() {
  local target="$REPO_DIR/config.local.toml"

  local py candidate
  for candidate in "$BIN/wpy" python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
      py="$candidate"
      break
    fi
  done

  if [[ -f "$target" ]]; then
    repair_config_local_group "$target" "${py:-}"
    ok "config.local.toml already present ($target)"
    return 0
  fi

  local name="" email="" group="" legacy_toml="$HOME/.config/chezmoi/chezmoi.toml"

  if [[ -f "$legacy_toml" && -n "${py:-}" ]]; then
    local parsed
    parsed=$(
      "$py" - "$legacy_toml" <<'PYEOF'
import sys
import tomllib

path = sys.argv[1]
try:
    with open(path, "rb") as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(0)

d = data.get("data") or {}
name = d.get("name") or ""
email = d.get("email") or ""
group = d.get("group") or ""
if name:
    print("name\t" + name)
if email:
    print("email\t" + email)
if group:
    print("group\t" + group)
PYEOF
    )
    while IFS=$'\t' read -r k v; do
      case "$k" in
      name) name="$v" ;;
      email) email="$v" ;;
      group) group="$v" ;;
      esac
    done <<<"$parsed"
    if [[ -n "$name" || -n "$email" || -n "$group" ]]; then
      log "Migrating name/email/group from $legacy_toml"
    fi
  fi

  [[ -n "$group" ]] || group="$GROUP_NAME"

  if [[ -z "$name" || -z "$email" ]]; then
    if ! exec 3</dev/tty 2>/dev/null; then
      # I6 fix (final-fix-brief.md): a silent skip-and-continue here used to
      # leave BOTH ~/.gitconfig (empty name/email — git then refuses to
      # commit) and vars.group (undefined — zshenv.tera/bashrc.tera's
      # MISE_ENV expression falls to its "else" branch) wrong, with no
      # signal beyond a scrollback warning easy to miss under
      # `curl | bash`. A PROD host bootstrapped with no TTY (curl | bash
      # over a non-interactive ssh) has no prompt to give, and prod's
      # "else" branch IS the correct MISE_ENV ("linux")
      # even with vars.group undefined, so prod must keep skipping quietly.
      # A --dev host has no such safety net: the "else" branch bakes
      # "linux" — indistinguishable from prod, silently dropping every
      # dev-only tool/dotfile — so hard-fail there instead of limping on
      # mis-configured. --reinstall removes config.local.toml AND the
      # legacy chezmoi.toml identity source together, so a --dev
      # --reinstall run over a non-interactive channel (no TTY, nothing to
      # migrate from) is exactly the case this catches.
      if [[ "$MACHINE_TYPE" == "dev" ]]; then
        fail "No TTY and no $legacy_toml to migrate a git identity from — refusing to bootstrap a --dev host with an undefined vars.group (would silently bake MISE_ENV=\"linux\", indistinguishable from prod) and an empty ~/.gitconfig identity (git would then refuse to commit).
Fix: run bootstrap.sh --dev from a real terminal once, or pre-create $target by hand:
  cat > $target <<'CFG'
  [vars]
  name = \"Your Name\"
  email = \"you@example.com\"
  group = \"$group\"
  CFG"
      fi
      warn "No TTY and no $legacy_toml to migrate from — skipping config.local.toml."
      warn "Create it by hand before the next bootstrap run:"
      warn "  cat > $target <<'CFG'"
      warn "  [vars]"
      warn "  name = \"Your Name\""
      warn "  email = \"you@example.com\""
      warn "  group = \"$group\""
      warn "  CFG"
      return 0
    fi
    exec 3<&-
    log "First-time setup — name/email for git commits and the SSH config comment..."
    [[ -n "$name" ]] || read -rp "  Name: " name </dev/tty
    [[ -n "$email" ]] || read -rp "  Email: " email </dev/tty
  fi

  name="${name//\\/\\\\}"
  name="${name//\"/\\\"}"
  email="${email//\\/\\\\}"
  email="${email//\"/\\\"}"
  group="${group//\\/\\\\}"
  group="${group//\"/\\\"}"

  mkdir -p "$(dirname "$target")"
  cat >"$target" <<CFG
# config.local.toml — per-host, git-ignored.
[vars]
name = "$name"
email = "$email"
group = "$group"
CFG
  ok "wrote $target"
}

# =============================================================================
# 3.5/3.6/4/4.5. RUN BOOTSTRAP — carry MISE_ENV onto the live systemd user
# manager, retire the legacy (pre-mise) pueued unit, ensure config.local.toml
# exists, install tools, then run `mise bootstrap` (packages, /etc files,
# services, compose, repos, dotfiles, tools gate, then the `bootstrap` task
# itself). Sudo (dev only) is scoped to the dnf batch and /etc files inside
# mise's own elevation — this script never runs sudo directly.
# =============================================================================
run_bootstrap() {
  # The user manager must carry MISE_ENV for the pueued shim (dev.mise.pueued.service);
  # environment.d covers the next login, this covers the live manager.
  if systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user set-environment "MISE_ENV=$MISE_ENV" || warn "could not set MISE_ENV on the systemd user manager"
  fi
  # Legacy (pre-mise) pueued unit: retire BEFORE mise's services phase starts
  # dev.mise.pueued (same daemon/socket, different unit name).
  if [[ -f "$HOME/.config/systemd/user/pueued.service" ]]; then
    systemctl --user disable --now pueued.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/pueued.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "retired the legacy pueued.service (mise owns dev.mise.pueued.service now)"
  fi

  # config.local.toml must exist BEFORE the first dotfiles apply below — the
  # Tera templates guard every vars.* reference, but a real value still
  # shapes the rendered git identity (Step 3.6).
  ensure_config_local

  log "mise install (tools) — MISE_ENV=$MISE_ENV"
  "$REPO_DIR/scripts/lib/mise-install.sh" || fail "mise install failed — see above"

  # Ruling 1: the first dotfiles apply on a host migrating off chezmoi finds
  # every target already a real file (chezmoi's own deploy) — symlink/copy/
  # template modes all refuse a pre-existing real file, so even --dry-run
  # would exit 1 without --force-dotfiles. Pass it ONLY until this host's own
  # migration marker exists, so any LATER conflict (a real mistake) is still
  # surfaced loudly instead of silently reclaimed.
  local migrated_marker="${XDG_STATE_HOME:-$HOME/.local/state}/workstation/dotfiles-migrated"
  local dotfiles_flags=()
  if [[ ! -f "$migrated_marker" ]]; then
    dotfiles_flags=(--force-dotfiles)
    log "First dotfiles apply on this host — passing --force-dotfiles (migration marker absent: $migrated_marker)"
  fi

  log "mise bootstrap — packages, /etc files, services, compose, repos, dotfiles, tools gate, then the bootstrap task"
  if [[ "$MACHINE_TYPE" == "dev" ]]; then
    log "Dev mode — sudo will prompt for the dnf batch and /etc files (dev runs are interactive by design)"
  fi
  if ! mise bootstrap --yes "${dotfiles_flags[@]}"; then
    fail "mise bootstrap failed — see the failing phase above.

A dotfiles conflict aborts the WHOLE dotfiles phase (one bad entry blocks
every entry — nothing gets applied). If the failure names a target that
already exists as a real file:
  1. resolve that one entry directly:  mise dot apply --force <the path mise named above>
  2. then re-run:                      ./bootstrap.sh --${MACHINE_TYPE}
For any other phase (packages, services, compose, repos, tools), re-running
this script is idempotent — fix what's reported above and run again."
  fi
  ok "mise bootstrap complete"

  if [[ ! -f "$migrated_marker" ]]; then
    mkdir -p "$(dirname "$migrated_marker")"
    : >"$migrated_marker"
    ok "dotfiles migration marker written ($migrated_marker) — future runs no longer force-reclaim dotfiles targets"
  fi
}

# =============================================================================
# 4.7. SET DEFAULT SHELL — switch the user's login shell to zsh.
#
# ~/.zshrc is a mise dotfiles template (config.linux.toml [dotfiles]);
# switching the login shell is what makes new SSH/WSL sessions actually read
# it. `chsh` isn't installed by default on AlmaLinux 9 (needs util-linux-user)
# and even when present requires PAM auth (interactive password). `sudo
# usermod -s` edits /etc/passwd directly — works under our existing dev-mode
# sudo flow.
#
# Prod hosts have no sudo, so we just print the manual chsh command. Same
# fallback on dev hosts where usermod fails (most often: $SUDO_ASKPASS missing
# under curl|bash from a remote machine).
# =============================================================================
set_default_shell() {
  local zsh_path
  zsh_path=$(command -v zsh || true)
  if [[ -z "$zsh_path" ]]; then
    if [[ "$MACHINE_TYPE" == "dev" ]]; then
      warn "zsh not on PATH — default shell unchanged. Re-run after a manual install:"
      warn "  sudo dnf install -y zsh   (or apt install zsh)"
    else
      # Prod has no sudo, so the dnf hint is wrong; surface that limitation
      # plainly and tell the user what state the host is in (zshrc deployed,
      # just dormant) so the fix path is obvious.
      warn "zsh not on PATH — ~/.zshrc has been deployed but is dormant on this host."
      warn "Ask the admin to install zsh (\`sudo dnf install -y zsh\`), then either"
      warn "re-run this script or chsh manually."
    fi
    return 0
  fi

  # /etc/passwd is authoritative; don't trust $SHELL (set by the parent shell).
  local current_shell
  current_shell=$(getent passwd "$USER" | cut -d: -f7)

  if [[ "$current_shell" == "$zsh_path" ]]; then
    ok "Default shell is already zsh ($zsh_path)"
    return 0
  fi

  if [[ "$MACHINE_TYPE" != "dev" ]]; then
    # No sudo on prod. chsh would work interactively but we can't drive it
    # cleanly under curl|bash. Tell the user and move on. On minimal RHEL
    # bases chsh itself ships in util-linux-user — flag the secondary
    # install in case `command -v chsh` also fails.
    warn "Default shell is $current_shell, not zsh. Change it manually on this host:"
    warn "  chsh -s $zsh_path        (interactive — needs your account password)"
    if ! command -v chsh &>/dev/null; then
      warn "  chsh is missing on this host. Ask the admin for:"
      warn "    sudo dnf install -y util-linux-user   (or shadow-utils on apt)"
    fi
    return 0
  fi

  log "Setting default shell to $zsh_path (current: $current_shell)..."
  if sudo usermod -s "$zsh_path" "$USER" 2>/dev/null; then
    ok "Default shell set to zsh — log out + back in (or open a new tab) to land in it"
  else
    warn "Couldn't set default shell automatically. Run one of:"
    warn "  sudo usermod -s $zsh_path $USER     (no password prompt)"
    warn "  chsh -s $zsh_path                   (interactive)"
  fi
}

# =============================================================================
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes (--doctor /
# --check-for-updates). Both exit before the provisioning flow starts:
# nothing is cloned, installed, or changed. This script owns only
# the repo-level checks (prereqs, git state, dotfiles drift, login shell) and
# delegates ALL per-tool and host-state knowledge to `mise run health` /
# `mise run check-updates`.
# =============================================================================
require_repo() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if [[ -d "$LEGACY_REPO_DIR/.git" ]]; then
      REPO_DIR="$LEGACY_REPO_DIR"
      warn "checkout not yet relocated to ~/.config/mise — run ./bootstrap.sh --${MACHINE_TYPE} once"
      return 0
    fi
    fail "No workstation repo at $REPO_DIR — bootstrap this host first:
  ./bootstrap.sh --${MACHINE_TYPE}"
  fi
}

# Shared by both modes: fetch (best-effort), then report branch, ahead/behind
# the upstream, and working-tree cleanliness. Never aborts — report-only.
report_repo_state() {
  cd "$REPO_DIR"
  log "Workstation repo ($REPO_DIR)"
  if git fetch --quiet 2>/dev/null; then
    ok "fetched origin"
  else
    warn "git fetch failed (offline or stale credentials) — using last-known remote state"
  fi

  local branch dirty upstream
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  dirty=$(git status --porcelain 2>/dev/null | wc -l)

  if upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    local behind ahead
    behind=$(git rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo 0)
    ahead=$(git rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo 0)
    if ((behind > 0)); then
      warn "branch $branch is $behind commit(s) behind $upstream — update with: git -C $REPO_DIR pull --ff-only"
    else
      ok "branch $branch is up to date with $upstream"
    fi
    if ((ahead > 0)); then
      warn "$ahead local commit(s) not pushed — push with: git -C $REPO_DIR push"
    fi
  else
    warn "branch $branch has no upstream — behind/ahead unknown"
  fi

  if ((dirty > 0)); then
    warn "$dirty uncommitted change(s) — review with: git -C $REPO_DIR status"
  else
    ok "working tree clean"
  fi
}

do_doctor() {
  require_repo
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
  export MISE_ENV
  log "Doctor — read-only health report (MODE=${MACHINE_TYPE}); nothing is installed or changed"
  echo ""

  # Same prereq list as preflight, but report-all instead of hard-fail.
  log "Prerequisites"
  local cmd
  for cmd in curl git tar ip; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      warn "$cmd missing — install via your distro's package manager (see ./bootstrap.sh --help)"
    fi
  done
  echo ""

  report_repo_state
  echo ""

  log "dotfiles"
  if ! command -v mise >/dev/null 2>&1; then
    warn "mise not on PATH — can't check dotfiles status"
  elif mise dot status --missing >/dev/null 2>&1; then
    ok "deployed dotfiles in sync with the source (mise dot status)"
  else
    warn "drift — inspect: mise dot status · apply: mise dot apply"
  fi
  echo ""

  log "Login shell"
  local login_shell zsh_path
  login_shell=$(getent passwd "$USER" | cut -d: -f7)
  zsh_path=$(command -v zsh || true)
  if [[ -n "$zsh_path" && "$login_shell" == "$zsh_path" ]]; then
    ok "login shell is zsh ($zsh_path)"
  elif [[ -z "$zsh_path" ]]; then
    warn "zsh not installed — login shell is $login_shell"
  else
    warn "login shell is $login_shell, not zsh — fix: sudo usermod -s $zsh_path $USER (dev) / chsh -s $zsh_path (prod)"
  fi
  echo ""

  log "mise"
  if command -v mise >/dev/null 2>&1; then ok "mise $(mise --version 2>/dev/null | awk '{print $1}') on PATH ($(command -v mise)) — pinned $MISE_VERSION"; else warn "mise not on PATH — re-run ./bootstrap.sh --${MACHINE_TYPE}"; fi
  echo ""

  log "Tools, host state, services — mise run health"
  mise run health
  exit $?
}

do_check_updates() {
  require_repo
  MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
  export MISE_ENV
  log "Check for updates (MODE=${MACHINE_TYPE}) — workstation repo first, then tool pins vs upstream"
  echo ""

  report_repo_state
  echo "    (tool pins live in config*.toml + config.toml [vars] of THIS clone — if the repo"
  echo "     is behind, pull first so the pins you're comparing are current)"
  echo ""

  mise run check-updates
}

# =============================================================================
# MAIN
# =============================================================================
# Read-only report modes exit here, before any provisioning state changes.
if [[ -n "$ACTION" ]]; then
  case "$ACTION" in
  doctor) do_doctor ;;
  check-updates) do_check_updates ;;
  esac
  exit 0
fi

if [[ "$REINSTALL" == true ]]; then
  do_reinstall
fi
preflight
mkdir -p "$BIN"
export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"
relocate_repo

# --- Repo --------------------------------------------------------------------
# If GITHUB_TOKEN is set, use it via http.extraheader (scoped to github.com).
# This works for both public and private repos. The token is persisted into
# the cloned repo's .git/config so subsequent push/pull all auth.
#
# We use HTTP Basic with a base64-encoded "x-access-token:<PAT>" pair — the
# same scheme GitHub Actions' `actions/checkout` uses. `Authorization: bearer`
# works for the REST/raw API (and that's how curl fetches bootstrap.sh) but
# is NOT accepted by git's smart-HTTP endpoint on github.com — GitHub falls
# through to credential prompting, which breaks any non-interactive clone.
GH_HEADER_VAL=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  GH_HEADER_B64=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
  GH_HEADER_VAL="Authorization: Basic $GH_HEADER_B64"
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning workstation repo into $REPO_DIR..."
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -c "${GH_HEADER_KEY}=${GH_HEADER_VAL}" clone "$DOTFILES_REPO" "$REPO_DIR" ||
      fail "Clone failed. For a private repo, set GITHUB_TOKEN to a PAT with repo read access."
    git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  else
    git clone "$DOTFILES_REPO" "$REPO_DIR" ||
      fail "Clone failed. If the repo is private, set GITHUB_TOKEN and re-run."
  fi
  ok "Repo cloned"
else
  log "Repo already present at $REPO_DIR — pulling latest..."
  # Refresh the stored token if a new one was passed in this invocation.
  if [[ -n "$GH_HEADER_VAL" ]]; then
    git -C "$REPO_DIR" config "$GH_HEADER_KEY" "$GH_HEADER_VAL"
  fi
  # A failed pull means we'd run mise bootstrap against a stale-or-broken tree —
  # better to bail out and let the user inspect.
  if ! git -C "$REPO_DIR" pull --ff-only; then
    fail "git pull --ff-only failed in $REPO_DIR.
This usually means stale credentials in .git/config, or local commits/conflicts.
Inspect with:
  cd $REPO_DIR && git status && git log --oneline -5

To start over from scratch (wipes the cloned repo, not your tools/dotfiles):
  ./bootstrap.sh --${MACHINE_TYPE} --reinstall"
  fi
fi

install_mise
MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
export MISE_ENV
log "mise environment: MISE_ENV=$MISE_ENV"

run_bootstrap
set_default_shell

# --- ccstatusline setup (dev only) -----------------------------------------
# Interactive prompt for the Claude Code statusline. Re-runnable any time
# via `mise run statusline` from anywhere.
if [[ "$MACHINE_TYPE" == dev && -t 0 ]]; then
  mise run statusline || true
fi

echo ""
echo -e "${BOLD}Bootstrap complete.${RESET}"

echo -e "${YELLOW}Replace this shell now:${RESET} run ${YELLOW}exec zsh${RESET} (or open a new tab)."
echo -e "  The shell you ran this from still has its mise/starship prompt hooks bound to the"
echo -e "  pre-migration /usr/local binaries, which the legacy sweep just removed — its prompt"
echo -e "  will print 'no such file or directory' on every keystroke until it is replaced."

# Only print the "you're on zsh" tip when the user actually is. set_default_shell
# may have bailed out (prod with no sudo, missing zsh binary, usermod refused) and
# already printed its own follow-up command, so we just stay quiet here. Read the
# authoritative shell from /etc/passwd — $SHELL was set by the parent process.
_login_shell=$(getent passwd "$USER" | cut -d: -f7)
_zsh_path=$(command -v zsh || true)
if [[ -n "$_zsh_path" && "$_login_shell" == "$_zsh_path" ]]; then
  echo -e "Log out + back in (or open a new tab) to land in zsh as your login shell."
fi

if is_wsl; then
  echo -e "Running inside WSL — opening a new Windows Terminal tab into this distro lands you"
  echo -e "  in ${YELLOW}~${RESET} with the dotfiles-tracked aliases active."
else
  echo -e "Enable passwordless SSH from your client:"
  echo -e "  ${YELLOW}ssh-copy-id $(whoami)@$(hostname -s)${RESET}  (Linux/WSL, and Windows via the PowerShell profile's ssh-copy-id)"
fi
if [ "$MACHINE_TYPE" = "dev" ]; then
  echo -e "Re-configure the Claude Code statusline any time:"
  echo -e "  ${YELLOW}mise run statusline${RESET}"
fi
echo -e "Health check any time: ${YELLOW}mise run health${RESET}"
