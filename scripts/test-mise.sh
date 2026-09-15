#!/usr/bin/env bash
# test-mise.sh — offline behavioural test of makefile/lib/mise.sh: seeding the
# generated conf.d files, the legacy sweeps, and which `mise` commands the
# install/uninstall subcommands issue (a fake `mise` on PATH records them).
# Never touches the real ~/.config/mise, ~/.local or /usr/local: everything
# runs under a scratch HOME/DEST/STAMP.
#
# Run by scripts/check-invariants.sh (check_mise_lib); usable on its own:
#   bash scripts/test-mise.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/makefile/lib/mise.sh"
src="$root/chezmoi/dot_config/mise/conf.d"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home"
export STAMP="$scratch/stamps"
export MISE_CONFIG_DIR="$scratch/home/.config/mise"
mkdir -p "$HOME" "$STAMP" "$scratch/bin"

fail() {
  echo "FAIL: $*"
  exit 1
}

# Fake mise: logs argv, answers `where node` from $FAKE_NODE_INSTALLED (exit 0
# only when the DECLARED version is installed, like the real thing), and fails
# whichever subcommand $FAKE_FAIL names.
cat >"$scratch/bin/mise" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_FAIL:-}" ] && [ "$1" = "$FAKE_FAIL" ]; then exit 1; fi
echo "$*" >>"$FAKE_LOG"
if [ "$1" = where ] && [ "$2" = node ]; then
  if [ "${FAKE_NODE_INSTALLED:-0}" = 1 ]; then
    echo "$HOME/.local/share/mise/installs/node/26.8.1"
    exit 0
  fi
  exit 1
fi
exit 0
EOF
chmod +x "$scratch/bin/mise"
export PATH="$scratch/bin:$PATH"
export FAKE_LOG="$scratch/mise.log"

# 1. seed dev → both files, identical bytes; seed prod → dev file removed
"$lib" seed dev "$src" >/dev/null
cmp -s "$src/workstation.toml" "$MISE_CONFIG_DIR/conf.d/workstation.toml" || fail "seed dev: workstation.toml differs"
cmp -s "$src/workstation-dev.toml" "$MISE_CONFIG_DIR/conf.d/workstation-dev.toml" || fail "seed dev: workstation-dev.toml differs"
"$lib" seed prod "$src" >/dev/null
[ -f "$MISE_CONFIG_DIR/conf.d/workstation.toml" ] || fail "seed prod: workstation.toml missing"
[ ! -e "$MISE_CONFIG_DIR/conf.d/workstation-dev.toml" ] || fail "seed prod: dev file should be removed"
"$lib" seed dev "$src" >/dev/null # section 2's node cases need node declared

# 2. install: declared node missing → no --force; already present → --force node;
#    prune always; a failing `mise install` propagates
: >"$FAKE_LOG"
FAKE_NODE_INSTALLED=0 "$lib" install >/dev/null
grep -qx 'install --yes' "$FAKE_LOG" || fail "install: mise install --yes not issued"
! grep -q -- '--force node' "$FAKE_LOG" || fail "install: --force node issued on a fresh host"
grep -qx 'prune --yes' "$FAKE_LOG" || fail "install: mise prune --yes not issued"
: >"$FAKE_LOG"
FAKE_NODE_INSTALLED=1 "$lib" install >/dev/null
grep -qx 'install --yes --force node' "$FAKE_LOG" || fail "install: --force node NOT issued when node was already installed"
"$lib" seed prod "$src" >/dev/null
: >"$FAKE_LOG"
FAKE_NODE_INSTALLED=1 "$lib" install >/dev/null
! grep -q -- '--force node' "$FAKE_LOG" || fail "install: --force node issued although node is no longer declared (prod seed)"
# a failing `mise install` must propagate: the Makefile recipe stops there and
# the stamp stays unwritten, so the sweeps never run against a half-install
if FAKE_FAIL=install "$lib" install >/dev/null 2>&1; then fail "install: a failing mise install must propagate (the Makefile relies on it to skip the sweeps)"; fi
"$lib" seed dev "$src" >/dev/null # restore the dev seed for the later sections

# 3. sweep-legacy: the pre-mise /usr/local set goes, unrelated files stay,
#    lib/node_modules only with a _node-* tree as evidence
dest="$scratch/usr/local/bin"
mkdir -p "$dest/_node-v26.8.1/bin" "$dest/_go-1.27.0" "$dest/_lua-language-server-3.19.1" "$scratch/usr/local/lib/node_modules/typescript"
for f in node npm npx corepack go gofmt uv uvx gopls lua-language-server typescript-language-server bash-language-server yaml-language-server vscode-json-language-server vscode-css-language-server vscode-html-language-server vscode-eslint-language-server vscode-markdown-language-server tsc tsserver; do
  ln -s "/nowhere/$f" "$dest/$f"
done
: >"$dest/rg" # unrelated tool must survive
"$lib" sweep-legacy dev "$dest" >/dev/null
for f in node npm npx corepack go gofmt uv uvx gopls lua-language-server typescript-language-server tsc tsserver; do
  [ ! -e "$dest/$f" ] && [ ! -L "$dest/$f" ] || fail "sweep-legacy: $f still present"
done
[ ! -e "$dest/_node-v26.8.1" ] || fail "sweep-legacy: _node-* tree still present"
[ ! -e "$dest/_go-1.27.0" ] || fail "sweep-legacy: _go-* tree still present"
[ ! -e "$dest/_lua-language-server-3.19.1" ] || fail "sweep-legacy: _lua-language-server-* tree still present"
[ ! -e "$scratch/usr/local/lib/node_modules" ] || fail "sweep-legacy: lib/node_modules still present"
[ -e "$dest/rg" ] || fail "sweep-legacy: unrelated rg removed"
# prod shape: only the eget uv/uvx pair this repo ever put in ~/.local/bin —
# a user's own node there, and their lib/node_modules, must survive
pdest="$scratch/home/.local/bin"
mkdir -p "$pdest" "$scratch/home/.local/lib/node_modules/keep"
: >"$pdest/uv"
: >"$pdest/node"
"$lib" sweep-legacy prod "$pdest" >/dev/null
[ ! -e "$pdest/uv" ] || fail "sweep-legacy(prod): uv still present"
[ -e "$pdest/node" ] || fail "sweep-legacy(prod): user's own ~/.local/bin/node removed"
[ -d "$scratch/home/.local/lib/node_modules/keep" ] || fail "sweep-legacy(prod): user's lib/node_modules removed without _node-* evidence"
"$lib" sweep-legacy dev "$dest" >/dev/null || fail "sweep-legacy: second run (nothing to do) must succeed"

# 4. sweep-user: old launchers + stale stamps go, python-env's wpy stays
mkdir -p "$HOME/.local/bin"
: >"$HOME/.local/bin/basedpyright"
: >"$HOME/.local/bin/basedpyright-langserver"
: >"$HOME/.local/bin/wpy"
: >"$STAMP/node-26.8.1.done"
: >"$STAMP/go-1.27.0.done"
: >"$STAMP/uv-0.12.7.done"
: >"$STAMP/lsp-servers-123.done"
: >"$STAMP/mise-2026.9.1.done"
"$lib" sweep-user >/dev/null
[ ! -e "$HOME/.local/bin/basedpyright-langserver" ] || fail "sweep-user: old basedpyright-langserver launcher still present"
[ -e "$HOME/.local/bin/wpy" ] || fail "sweep-user: wpy removed"
[ ! -e "$STAMP/node-26.8.1.done" ] && [ ! -e "$STAMP/lsp-servers-123.done" ] || fail "sweep-user: stale stamps still present"
[ -e "$STAMP/mise-2026.9.1.done" ] || fail "sweep-user: mise's own stamp removed"

# 5. uninstall: one `mise uninstall --all <key>` per declared tool (dev seed)
"$lib" seed dev "$src" >/dev/null
: >"$FAKE_LOG"
"$lib" uninstall >/dev/null
for t in uv node go 'go:golang.org/x/tools/gopls' lua-language-server 'pipx:basedpyright'; do
  grep -qxF "uninstall --all $t" "$FAKE_LOG" || fail "uninstall: no 'mise uninstall --all $t'"
done

echo "PASS: lib/mise.sh seed/install/sweep-legacy/sweep-user/uninstall behave (offline, fake mise)"
