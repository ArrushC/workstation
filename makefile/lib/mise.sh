#!/usr/bin/env bash
# mise.sh — the runtime layer (node, Go, uv, gopls, lua-language-server,
# basedpyright, the npm language servers) via mise. Dispatched by the
# `mise-runtimes` Makefile target (BOTH scopes, USER-LEVEL — mise installs under
# ~/.local/share/mise; the only privileged step is sweep-legacy of $(DEST)).
#
# Subcommands:
#   seed <dev|prod> <src-dir>  copy the GENERATED conf.d file(s) from the chezmoi
#                              source into ${MISE_CONFIG_DIR:-~/.config/mise}/conf.d/
#                              (the provision fanout runs BEFORE the dotfiles
#                              phase; chezmoi later deploys identical bytes)
#   install                    `mise install`; force-reinstall node when the
#                              DECLARED version is already installed so a changed
#                              npm postinstall re-runs (a NODE_VERSION bump
#                              installs once); prune versions no config references
#   sweep-legacy <dev|prod> <dest>
#                              remove the pre-mise artifacts under <dest> — dev:
#                              the whole node/go/uv/LSP set plus the _node-*/
#                              _go-*/_lua-language-server-* trees (run under
#                              $(SUDO): /usr/local/bin); prod: ONLY uv/uvx
#   sweep-user                 remove the old user-site basedpyright + stale
#                              stamps (NEVER sudo)
#   uninstall                  `mise uninstall --all` every tool the seeded
#                              conf.d declares (clean-mise-runtimes)
#
# Env: MISE_CONFIG_DIR (seed/uninstall), STAMP (sweep-user), HOME.
# `mise` must be on PATH (the Makefile prepends $(DEST)).
set -euo pipefail

cmd="${1:-}"
shift || true

conf_dir="${MISE_CONFIG_DIR:-$HOME/.config/mise}/conf.d"

# Tool keys declared in the seeded conf.d files: the LHS of every `x = ...`
# line, quotes stripped (`"go:golang.org/x/tools/gopls" = "0.23.0"` → the key).
declared_tools() {
  cat "$conf_dir"/workstation*.toml 2>/dev/null |
    grep -E '^"?[^#=[:space:]"]+"?[[:space:]]*=' |
    sed -E 's/^"?([^"=[:space:]]+)"?[[:space:]]*=.*/\1/'
}

# `mise where node` succeeds only when the version the config declares is
# installed — a NODE_VERSION bump therefore installs once (postinstall runs)
# with no force; an unchanged node with changed npm pins is forced so the
# postinstall re-runs.
declared_node_present() {
  mise where node >/dev/null 2>&1
}

case "$cmd" in
seed)
  mode="${1:?mise.sh seed: mode (dev|prod) required}"
  src="${2:?mise.sh seed: source dir required}"
  mkdir -p "$conf_dir"
  install -m 0644 "$src/workstation.toml" "$conf_dir/workstation.toml"
  if [ "$mode" = dev ]; then
    install -m 0644 "$src/workstation-dev.toml" "$conf_dir/workstation-dev.toml"
  else
    rm -f "$conf_dir/workstation-dev.toml" # a host demoted to prod drops the dev set
  fi
  printf '  ✓ seeded %s (%s)\n' "$conf_dir" "$mode"
  ;;
install)
  had_node=false
  if declared_node_present; then had_node=true; fi
  mise install --yes
  # postinstall (the npm servers) only runs when node itself installs. With the
  # declared node already present, `mise install` is a no-op for node while the
  # npm pins inside its postinstall may have moved — force the reinstall so the
  # hook re-runs. (A NODE_VERSION bump is NOT already-present: it installs once.)
  if $had_node && declared_tools | grep -qx node; then
    printf '  ↪ node was already installed — forcing a reinstall so its npm postinstall re-runs\n'
    mise install --yes --force node
  fi
  # Drop versions no config references (the old _node-*/_go-* tree sweep).
  mise prune --yes
  ;;
sweep-legacy)
  mode="${1:?mise.sh sweep-legacy: mode (dev|prod) required}"
  dest="${2:?mise.sh sweep-legacy: dest required}"
  removed=0
  # Prod only ever received uv/uvx from this repo (eget into ~/.local/bin);
  # node/go/LSP were dev-only under /usr/local — never touch a user's own
  # ~/.local/bin/node there.
  if [ "$mode" = dev ]; then
    legacy_names=(node npm npx corepack go gofmt uv uvx gopls lua-language-server
      typescript-language-server bash-language-server yaml-language-server
      vscode-json-language-server vscode-css-language-server
      vscode-html-language-server vscode-eslint-language-server
      vscode-markdown-language-server tsc tsserver)
  else
    legacy_names=(uv uvx)
  fi
  for f in "${legacy_names[@]}"; do
    if [ -e "$dest/$f" ] || [ -L "$dest/$f" ]; then
      rm -f "$dest/$f"
      removed=$((removed + 1))
    fi
  done
  if [ "$mode" = dev ]; then
    had_node_tree=false
    for d in "$dest"/_node-*; do
      if [ -e "$d" ]; then had_node_tree=true; fi
    done
    for d in "$dest"/_node-* "$dest"/_go-* "$dest"/_lua-language-server-*; do
      [ -e "$d" ] || continue
      rm -rf "$d"
      removed=$((removed + 1))
    done
    # The npm -g --prefix tree (lib/node_modules next to bin/) is only ours when
    # a _node-* tree proved this repo installed node here — a hand-installed
    # node under the same prefix keeps its modules.
    if $had_node_tree && [ -d "$(dirname "$dest")/lib/node_modules" ]; then
      rm -rf "$(dirname "$dest")/lib/node_modules"
      removed=$((removed + 1))
    fi
  fi
  if [ "$removed" -gt 0 ]; then
    printf '  ✓ swept %d pre-mise artifact(s) from %s\n' "$removed" "$dest"
  fi
  ;;
sweep-user)
  stamp="${STAMP:-$HOME/.local/share/workstation-install}"
  # The old lsp.sh basedpyright lived in uv's default tool dir with launchers in
  # ~/.local/bin; mise's pipx: backend installs its own copy elsewhere.
  if mise x -- uv tool list 2>/dev/null | grep -q '^basedpyright '; then
    mise x -- uv tool uninstall basedpyright >/dev/null 2>&1 || true
  fi
  rm -f "$HOME/.local/bin/basedpyright" "$HOME/.local/bin/basedpyright-langserver"
  rm -f "$stamp"/node-*.done "$stamp"/go-*.done "$stamp"/uv-*.done "$stamp"/lsp-servers-*.done
  ;;
uninstall)
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    mise uninstall --all "$tool" 2>/dev/null || true
  done < <(declared_tools)
  ;;
*)
  printf 'mise.sh: unknown subcommand "%s"\n' "$cmd" >&2
  exit 2
  ;;
esac
