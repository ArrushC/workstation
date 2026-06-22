#!/usr/bin/env bash
# lsp.sh — install/verify language servers that don't fit the single-binary
# eget path. Dispatched per-mechanism by the `lsp-servers` Makefile target.
#
# Subcommands (each best-effort: a failure WARNS and exits 0 so one server's
# outage never aborts `make dev`):
#   npm <dest> <pkg@ver>...   global npm installs landing bins in <dest>
#   lua <dest> <ver>          lua-language-server TREE install + symlink
#   gopls <dest> <ver>        `go install` with GOBIN=<dest>
#   basedpyright <ver>        `uv tool install` (user-site, NEVER sudo)
#   verify-clangd             warn if clangd (clang-tools-extra) is absent
#
# Sudo is the Makefile's job for the system-dest subcommands (npm/lua/gopls);
# basedpyright is invoked WITHOUT sudo (uv writes the user site).
# -e is intentionally omitted: each subcommand is best-effort and must warn-
# and-continue so one failing server never aborts the others.
set -uo pipefail

warn() { printf '  ! %s\n' "$*" >&2; }

cmd="${1:-}"
shift || true

case "$cmd" in
npm)
  dest="${1:?lsp.sh npm: dest required}"
  shift
  # $(SUDO) resets PATH to secure_path, which excludes $dest (=/usr/local/bin),
  # so node/npm land off-PATH under sudo. Prepend $dest so bare `npm` resolves
  # AND npm's own `#!/usr/bin/env node` shebang finds node. (lib/eget.sh documents
  # the same sudo-PATH gotcha and sidesteps it by invoking $DEST/eget absolutely.)
  export PATH="$dest:$PATH"
  prefix="$(dirname "$dest")" # npm --prefix <p> puts bins in <p>/bin == $dest
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found (node-runtime missing?) — skipping npm servers"
    exit 0
  fi
  for spec in "$@"; do
    printf '  ↪ npm -g %s\n' "$spec"
    npm install -g --prefix "$prefix" "$spec" >/dev/null 2>&1 ||
      warn "npm install $spec failed — skipping"
  done
  ;;
lua)
  dest="${1:?lsp.sh lua: dest required}"
  ver="${2:?lsp.sh lua: version required}"
  arch="$(uname -m)"
  case "$arch" in
  x86_64) la="x64" ;;
  aarch64 | arm64) la="arm64" ;;
  *)
    warn "lua-language-server: unsupported arch $arch — skipping"
    exit 0
    ;;
  esac
  url="https://github.com/LuaLS/lua-language-server/releases/download/${ver}/lua-language-server-${ver}-linux-${la}.tar.gz"
  install_dir="${dest}/_lua-language-server-${ver}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  printf '  ↓ %s\n' "$url"
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/ls.tar.gz" "$url"; then
    warn "lua-language-server download failed — skipping"
    exit 0
  fi
  for old in "$dest"/_lua-language-server-*; do
    [ -e "$old" ] || continue
    rm -rf "$old"
  done
  mkdir -p "$install_dir"
  tar -xzf "$tmp/ls.tar.gz" -C "$install_dir" # archive has no top-level wrapper dir
  ln -sfn "${install_dir}/bin/lua-language-server" "${dest}/lua-language-server"
  printf '  ✓ lua-language-server %s\n' "$ver"
  ;;
gopls)
  dest="${1:?lsp.sh gopls: dest required}"
  ver="${2:?lsp.sh gopls: version required}"
  export PATH="$dest:$PATH" # $(SUDO) drops $dest from PATH — see the npm note above
  if ! command -v go >/dev/null 2>&1; then
    warn "go not found (go-runtime missing?) — skipping gopls"
    exit 0
  fi
  printf '  ↪ go install gopls@v%s (GOBIN=%s)\n' "$ver" "$dest"
  GOBIN="$dest" GOFLAGS=-mod=mod go install "golang.org/x/tools/gopls@v${ver}" 2>&1 ||
    warn "gopls install failed — skipping"
  ;;
basedpyright)
  ver="${1:?lsp.sh basedpyright: version required}"
  if ! command -v uv >/dev/null 2>&1; then
    warn "uv not found — skipping basedpyright"
    exit 0
  fi
  printf '  ↪ uv tool install basedpyright==%s\n' "$ver"
  uv tool install --force "basedpyright==${ver}" >/dev/null 2>&1 ||
    warn "basedpyright install failed — skipping"
  ;;
verify-clangd)
  if command -v clangd >/dev/null 2>&1; then
    printf '  ✓ clangd present: %s\n' "$(command -v clangd)"
  else
    warn "clangd not found — install clang-tools-extra (packages-optional; needs EPEL/CRB on EL9)"
  fi
  ;;
*)
  printf 'lsp.sh: unknown subcommand "%s"\n' "$cmd" >&2
  exit 2
  ;;
esac
exit 0
