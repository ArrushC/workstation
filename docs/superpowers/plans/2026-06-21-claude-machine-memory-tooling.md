# Machine-level Claude Memory + LSP Toolbelt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a chezmoi-tracked `~/.claude/CLAUDE.md` that inventories the workstation toolbelt and steers Claude to prefer the `LSP` tool over Linux text tools, kept auto-fresh by a repo hook; plus expand real LSP-server coverage (rust-analyzer, marksman, taplo, lua-language-server, basedpyright, gopls, and four npm servers) backed by a new Go toolchain.

**Architecture:** Two separable phases in one plan. **Phase 1 (Tasks 1–4)** is the provisioning expansion — `versions.mk` pins, three `EGET_TOOL` static servers, a `go-runtime` target, and a unified dev-only `lsp-servers` meta-target. **Phase 2 (Tasks 5–8)** is the memory system — a generator that rewrites a sentinel block from the makefile sources, the memory file (prose + block), the PostToolUse hook that regenerates on makefile edits, and the drift check. **Task 9** is docs. Phase 1 lands first so the generated inventory already includes the new servers.

**Tech Stack:** GNU Make, bash + awk, chezmoi, eget, npm (via existing `node-runtime`), `uv` (already provisioned), Go (new `go-runtime`), Claude Code hooks (jq→python3→fail-open), `scripts/check-invariants.sh` + `.claude/hooks/test-hooks.sh` as the test harnesses.

## Global Constraints

_Every task's requirements implicitly include this section. Values copied verbatim from CLAUDE.md / the spec._

- **New shell scripts must be LF-only, git mode `100755`, `#!/usr/bin/env bash`.** `scripts/check-invariants.sh` already globs `scripts/*.sh` + `.claude/hooks/*.sh` for LF/mode/shellcheck/shfmt — new files are auto-covered once committed. No edits to those globs needed.
- **First-party shell must be `shfmt -i 2`-clean and `shellcheck -S warning`-clean.** Fix with `make fmt MODE=prod`; `shfmt -w` preserves mode but re-verify LF+0755 after.
- **Tool versions ONLY in `makefile/versions.mk`** — baked into stamp filenames. Never in scripts/bootstrap.
- **`MODE` has no default** — always invoke make as `make <target> MODE=dev` (or `MODE=prod`). `scope.mk` errors at parse time otherwise.
- **`$(SUDO)` thread** — recipes use `$(SUDO)` (= `sudo --preserve-env=DEST,HELIX_RUNTIME_DEST` on dev, empty on prod), never literal `sudo`. Library scripts assume they can write `$DEST`; sudo is the Makefile's job.
- **`EGET_TOOL` per-tool stamp order-only-deps the eget stamp file** — the macro handles this automatically; don't hand-add deps.
- **Makefile recipe lines are TAB-indented**; macro/`define` bodies use `$$` for rule-fire-time expansion.
- **The memory file is dev-only automatically** — `.claude` is already dev-gated in `.chezmoiignore.tmpl`. Do NOT add a new ignore entry. Verify with `chezmoi ignored`.
- **Sentinel blocks are auto-generated; never hand-edit inside `<!-- TOOLS:START -->` / `<!-- TOOLS:END -->`.**
- **README update IS required for the new LSP servers + Go toolchain** (user-facing tools). NOT required for the memory file / hook / generator (Claude-internal). Append a `CLAUDE_CHANGELOG.md` row.
- **Hooks fail open** — unparseable input or generator error → `exit 0`, never block an edit. Compact single-line JSON.

---

## File Structure

**New files:**
- `makefile/lib/go.sh` — Go toolchain installer (mirrors `lib/node.sh`). Responsibility: download+extract go tarball, symlink `go`/`gofmt`.
- `makefile/lib/lsp.sh` — LSP-server installer dispatcher (subcommands: `npm`, `lua`, `gopls`, `basedpyright`, `verify-clangd`).
- `scripts/gen-tool-memory.sh` — regenerate the `TOOLS` block from `versions.mk`/`tools.mk`/`packages.mk`. Honors `MEMFILE` env override (for tests/drift-check).
- `.claude/hooks/sync-tool-memory.sh` — PostToolUse hook; runs the generator on a makefile edit.
- `chezmoi/private_dot_claude/CLAUDE.md` — the machine-level memory (prose + sentinel block) → `~/.claude/CLAUDE.md`.

**Modified files:**
- `makefile/versions.mk` — new `Language servers (LSP) + runtimes` pin section.
- `makefile/tools.mk` — rust-analyzer/marksman/taplo `EGET_TOOL` + `UPDATE_SPECS`.
- `makefile/Makefile` — `go-runtime` + `lsp-servers` targets; `provision` dev block; `DOCTOR_ROWS`; `list` text.
- `.claude/settings.json` — wire the new PostToolUse hook.
- `scripts/check-invariants.sh` — TOOLS sentinel + drift check.
- `.claude/hooks/test-hooks.sh` — hook assertions.
- `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `README.html`, `CLAUDE_CHANGELOG.md` — docs.

---

## Task 1: LSP/Go version pins

**Files:**
- Modify: `makefile/versions.mk` (append a new section near the end, after the C/C++ section)

**Interfaces:**
- Produces: makefile variables `GO_VERSION`, `GOPLS_VERSION`, `RUST_ANALYZER_VERSION`, `MARKSMAN_VERSION`, `TAPLO_VERSION`, `LUA_LS_VERSION`, `BASEDPYRIGHT_VERSION`, `TYPESCRIPT_LS_VERSION`, `BASH_LS_VERSION`, `YAML_LS_VERSION`, `VSCODE_LANGSERVERS_VERSION` — consumed by Tasks 2–4 and the generator (Task 5).

- [ ] **Step 1: Discover current upstream versions**

Run (network required; substitute the printed values in Step 2):
```bash
gh release list -R rust-lang/rust-analyzer -L1        # date tag, e.g. 2026-06-15
gh release list -R artempyanykh/marksman   -L1        # date tag, e.g. 2024-12-18
gh release list -R tamasfe/taplo           -L1        # e.g. 0.9.3 (no v)
gh release list -R LuaLS/lua-language-server -L1      # e.g. 3.13.0 (no v)
gh release list -R DetachHead/basedpyright -L1        # e.g. v1.29.0  -> use 1.29.0
gh release list -R golang/tools -L20 | grep gopls     # e.g. gopls/v0.18.1 -> 0.18.1
curl -s https://go.dev/dl/?mode=json | jq -r '.[0].version'   # e.g. go1.24.4 -> 1.24.4
npm view typescript-language-server version
npm view bash-language-server version
npm view yaml-language-server version
npm view vscode-langservers-extracted version
```

- [ ] **Step 2: Append the pin section to `makefile/versions.mk`**

Append after the C/C++ block (current last block ends at `VCPKG_VERSION`). Replace each value with the Step 1 result:

```makefile

# --- (2026-06) Language servers (LSP) + runtimes ------------------------------
# All dev_machine only (navigation is a dev activity; Claude Code is dev-only-
# deployed). Three are single-binary EGET_TOOL static servers (tools.mk,
# both-scope). The rest install via the bespoke `lsp-servers` target (Makefile):
# lua-language-server is a multi-file TREE (not a single binary, so NOT eget);
# basedpyright via `uv tool install` (self-contained PyPI build, bundles its own
# JS runtime); the four *-language-server npm packages via node-runtime's npm;
# gopls via `go install` against the new go-runtime. clangd is provisioned
# separately (clang-tools-extra, packages.mk) and only VERIFIED by lsp-servers.
GO_VERSION                 := 1.24.4
GOPLS_VERSION              := 0.18.1
RUST_ANALYZER_VERSION      := 2026-06-15
MARKSMAN_VERSION           := 2024-12-18
TAPLO_VERSION              := 0.9.3
LUA_LS_VERSION             := 3.13.0
BASEDPYRIGHT_VERSION       := 1.29.0
TYPESCRIPT_LS_VERSION      := 4.3.4
BASH_LS_VERSION            := 5.4.3
YAML_LS_VERSION            := 1.15.0
VSCODE_LANGSERVERS_VERSION := 4.10.0
```

- [ ] **Step 3: Verify make still parses and the pins resolve**

Run:
```bash
cd makefile && make MODE=dev -p 2>/dev/null | grep -E '^(GO_VERSION|GOPLS_VERSION|RUST_ANALYZER_VERSION|BASEDPYRIGHT_VERSION) :=' ; cd ..
```
Expected: four lines echoing the pins (e.g. `GO_VERSION := 1.24.4`). No `*** ` make errors.

- [ ] **Step 4: Lint**

Run: `make lint MODE=prod`
Expected: `✓ all invariant checks passed` (the `versions.mk` parity-reminder is a hook nudge, not a lint failure; none of the new pins are dual-edits).

- [ ] **Step 5: Commit**

```bash
git add makefile/versions.mk
git commit -m "feat(versions): pin LSP servers + Go toolchain"
```

---

## Task 2: Static single-binary LSP servers (rust-analyzer, marksman, taplo)

**Files:**
- Modify: `makefile/tools.mk` (add three `EGET_TOOL` lines in the gap-fillers area; add three `UPDATE_SPECS` — actually EGET_TOOL self-registers UPDATE_SPECS, so none needed)

**Interfaces:**
- Consumes: `RUST_ANALYZER_VERSION`, `MARKSMAN_VERSION`, `TAPLO_VERSION` (Task 1).
- Produces: phony targets `rust-analyzer`, `marksman`, `taplo` (both-scope, join `$(SCOPE_TOOLS)`) — depended on by `lsp-servers` (Task 4); binaries on PATH for the `LSP` tool.

- [ ] **Step 1: Add the three EGET_TOOL lines to `makefile/tools.mk`**

Insert before the `# ===` "DIRECT" section header (after the `gum` entry, ~line 322). The `--asset` flags are best-known starting points; Step 3 confirms/adjusts them empirically (the repo's documented "Adding a tool" loop):

```makefile

# --- (2026-06) Language servers (single-binary, both-scope) -------------------
# rust-analyzer — date-tagged release; asset rust-analyzer-x86_64-unknown-linux-
# gnu.gz (eget decompresses the .gz to the `rust-analyzer` binary). gnu-only for
# x86_64; tag == the date pin (no `v`).
$(eval $(call EGET_TOOL,rust-analyzer,$(RUST_ANALYZER_VERSION),rust-lang/rust-analyzer,$(RUST_ANALYZER_VERSION),--asset gnu))

# marksman — Markdown LSP. Date-tagged; asset is a BARE binary `marksman-linux-x64`
# (no archive), so eget renames it to the repo name `marksman`. Tag == the date.
$(eval $(call EGET_TOOL,marksman,$(MARKSMAN_VERSION),artempyanykh/marksman,$(MARKSMAN_VERSION),--asset linux-x64))

# taplo — TOML LSP (`taplo lsp stdio`). Non-v tag; asset taplo-full-linux-x86_64.gz
# (the `full` build includes the LSP). eget decompresses the .gz to `taplo`.
$(eval $(call EGET_TOOL,taplo,$(TAPLO_VERSION),tamasfe/taplo,$(TAPLO_VERSION),--asset full --asset x86_64))
```

- [ ] **Step 2: Verify the recipes generate without make errors**

Run:
```bash
cd makefile && make -n rust-analyzer marksman taplo MODE=prod ; cd ..
```
Expected: each prints an `eget.sh ... ` install command line, no `*** ` errors.

- [ ] **Step 3: Install + confirm on a host with network (adjust `--asset` if eget reports ambiguity)**

Run (prod scope = no sudo, lands in `~/.local/bin`):
```bash
cd makefile && make rust-analyzer marksman taplo MODE=prod ; cd ..
rust-analyzer --version && marksman --version && taplo --version
```
Expected: each binary resolves and prints a version. If eget aborts with "N candidates", refine the `--asset` filter per the message (mirror the tools.mk comments on existing tools), then re-run.

- [ ] **Step 4: Confirm they show up in `make list` + lint**

Run:
```bash
cd makefile && make list MODE=prod | grep -E 'rust-analyzer|marksman|taplo' ; cd ..
make lint MODE=prod
```
Expected: all three listed under scope-tools; `✓ all invariant checks passed`.

- [ ] **Step 5: Commit**

```bash
git add makefile/tools.mk
git commit -m "feat(tools): add rust-analyzer/marksman/taplo language servers (eget, both-scope)"
```

---

## Task 3: Go toolchain (`lib/go.sh` + `go-runtime` target)

**Files:**
- Create: `makefile/lib/go.sh`
- Modify: `makefile/Makefile` (add `go-runtime` target; will be joined to `provision` in Task 4)

**Interfaces:**
- Consumes: `GO_VERSION` (Task 1); `DEST` (scope.mk).
- Produces: phony target `go-runtime`; `go` + `gofmt` symlinked into `$(DEST)` — consumed by `lsp-servers`' gopls step (Task 4).

- [ ] **Step 1: Create `makefile/lib/go.sh`** (mirrors `lib/node.sh`)

```bash
#!/usr/bin/env bash
# go.sh — install the Go toolchain from the official go.dev tarball.
#
# Usage:   go.sh <version>        (version with no leading 'go', e.g. 1.24.4)
# Env:     DEST                   destination dir (required; from scope.mk)
#
# Extracts the full tree to $DEST/_go-<ver>/ (go needs its bundled std + pkg
# next to the binary, like node), strips older _go-* trees, then symlinks
# $DEST/{go,gofmt} -> _go-<ver>/bin/<binary>. Sudo is the Makefile's job.
set -euo pipefail

: "${DEST:?go.sh: DEST not set}"

if (($# != 1)); then
  printf 'go.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) go_arch="amd64" ;;
aarch64 | arm64) go_arch="arm64" ;;
*)
  printf 'go.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

tarball="go${version}.linux-${go_arch}.tar.gz"
url="https://go.dev/dl/${tarball}"
install_dir="${DEST}/_go-${version}"

mkdir -p "$DEST"

# Strip older _go-* trees so re-installs don't accumulate.
for old in "$DEST"/_go-*; do
  [ -e "$old" ] || continue
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
tar -xzf "$tmp/$tarball" -C "$tmp" # extracts a top-level ./go/
mv "$tmp/go" "$install_dir"

for bin in go gofmt; do
  if [ -e "${install_dir}/bin/${bin}" ]; then
    ln -sfn "${install_dir}/bin/${bin}" "${DEST}/${bin}"
  else
    rm -f "${DEST}/${bin}"
  fi
done

printf '  ✓ go%s ready at %s/go\n' "$version" "$DEST"
```

- [ ] **Step 2: Make it LF + executable**

Run:
```bash
chmod +x makefile/lib/go.sh
file makefile/lib/go.sh   # must NOT say "with CRLF line terminators"
```
Expected: no CRLF; executable.

- [ ] **Step 3: Add the `go-runtime` target to `makefile/Makefile`**

Insert directly after the `node-runtime` block (after its `clean-node-runtime`, ~line 187):

```makefile

# -----------------------------------------------------------------------------
# go-runtime — Go toolchain from the official go.dev tarball. Dev-only (gopls
# is built from it; Go is generally useful on a dev box). Pinned to GO_VERSION
# in versions.mk. lib/go.sh extracts to $(DEST)/_go-X.Y.Z/ and symlinks go +
# gofmt into $(DEST). Older _go-* trees are stripped on every (re-)install.
# -----------------------------------------------------------------------------
.PHONY: go-runtime clean-go-runtime
go-runtime: $(STAMP)/go-$(GO_VERSION).done
$(STAMP)/go-$(GO_VERSION).done:
	@printf '==> go %s\n' "$(GO_VERSION)"
	@$(SUDO) $(LIB)/go.sh $(GO_VERSION)
	@mkdir -p $(@D) && touch $@
clean-go-runtime:
	@rm -f $(STAMP)/go-*.done
	@$(SUDO) rm -f $(DEST)/go $(DEST)/gofmt
	@$(SUDO) rm -rf $(DEST)/_go-*
```

- [ ] **Step 4: Verify the recipe + shellcheck/shfmt**

Run:
```bash
cd makefile && make -n go-runtime MODE=dev ; cd ..
shellcheck -x -S warning makefile/lib/go.sh && shfmt -d -i 2 makefile/lib/go.sh
make lint MODE=prod
```
Expected: dry-run shows `go.sh 1.24.4`; shellcheck/shfmt clean; `✓ all invariant checks passed`.

- [ ] **Step 5: Install + confirm on a dev host (sudo + network)**

Run:
```bash
cd makefile && make go-runtime MODE=dev ; cd ..
go version
```
Expected: `go version go1.24.4 linux/amd64`.

- [ ] **Step 6: Commit**

```bash
git add makefile/lib/go.sh makefile/Makefile
git commit -m "feat(tools): add go-runtime target (go.dev tarball, dev-only)"
```

---

## Task 4: `lib/lsp.sh` + the `lsp-servers` meta-target + provision wiring

**Files:**
- Create: `makefile/lib/lsp.sh`
- Modify: `makefile/Makefile` (`lsp-servers` target; `provision` dev block; `DOCTOR_ROWS`; `list` text)

**Interfaces:**
- Consumes: `LUA_LS_VERSION`, `BASEDPYRIGHT_VERSION`, `TYPESCRIPT_LS_VERSION`, `BASH_LS_VERSION`, `YAML_LS_VERSION`, `VSCODE_LANGSERVERS_VERSION`, `GOPLS_VERSION` (Task 1); targets `rust-analyzer`/`marksman`/`taplo` (Task 2), `node-runtime`, `go-runtime` (Task 3); `DEST` (scope.mk).
- Produces: phony target `lsp-servers`; joins `provision` on `MODE=dev`.

- [ ] **Step 1: Create `makefile/lib/lsp.sh`** (subcommand dispatcher)

```bash
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
set -uo pipefail

warn() { printf '  ! %s\n' "$*" >&2; }

cmd="${1:-}"
shift || true

case "$cmd" in
npm)
  dest="${1:?lsp.sh npm: dest required}"
  shift
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
```

- [ ] **Step 2: LF + executable + lint the script**

Run:
```bash
chmod +x makefile/lib/lsp.sh
file makefile/lib/lsp.sh
shellcheck -x -S warning makefile/lib/lsp.sh && shfmt -d -i 2 makefile/lib/lsp.sh
```
Expected: no CRLF; shellcheck/shfmt clean.

- [ ] **Step 3: Add the `lsp-servers` target to `makefile/Makefile`**

Insert after the `vcpkg` block (after `clean-vcpkg`, ~line 289):

```makefile

# -----------------------------------------------------------------------------
# lsp-servers — install/verify the whole language-server stack (dev_machine
# only). One coherent target so `make lsp-servers` covers every server. The
# single-binary servers (rust-analyzer/marksman/taplo) are both-scope EGET_TOOLs
# installed by `tools`; this target DEPENDS on them and adds the rest:
#   - lua-language-server  (TREE install via lib/lsp.sh; not a single binary)
#   - npm servers          (typescript/bash/yaml/vscode-langservers via node)
#   - gopls                (go install via go-runtime)
#   - basedpyright         (uv tool install — user-site, no sudo)
#   - clangd               (VERIFIED only; comes from clang-tools-extra, dnf)
# Each install is best-effort inside lib/lsp.sh (a server's outage never aborts
# the provision, matching the C/C++ `|| true` and cht.sh SOFT_TOOL precedent).
# Stamp bakes a hash of all the LSP pins so bumping any reinstalls.
# -----------------------------------------------------------------------------
LSP_PINS := $(GOPLS_VERSION)|$(LUA_LS_VERSION)|$(BASEDPYRIGHT_VERSION)|$(TYPESCRIPT_LS_VERSION)|$(BASH_LS_VERSION)|$(YAML_LS_VERSION)|$(VSCODE_LANGSERVERS_VERSION)
LSP_STAMP := $(shell printf '%s' '$(LSP_PINS)' | cksum | cut -d' ' -f1)
.PHONY: lsp-servers clean-lsp-servers
ifeq ($(MODE),dev)
lsp-servers: rust-analyzer marksman taplo node-runtime go-runtime $(STAMP)/lsp-servers-$(LSP_STAMP).done
$(STAMP)/lsp-servers-$(LSP_STAMP).done:
	@printf '==> lsp-servers (language-server stack)\n'
	@$(LIB)/lsp.sh verify-clangd
	@$(SUDO) $(LIB)/lsp.sh lua $(DEST) $(LUA_LS_VERSION)
	@$(SUDO) $(LIB)/lsp.sh npm $(DEST) \
	  typescript-language-server@$(TYPESCRIPT_LS_VERSION) typescript \
	  bash-language-server@$(BASH_LS_VERSION) \
	  yaml-language-server@$(YAML_LS_VERSION) \
	  vscode-langservers-extracted@$(VSCODE_LANGSERVERS_VERSION)
	@$(SUDO) $(LIB)/lsp.sh gopls $(DEST) $(GOPLS_VERSION)
	@$(LIB)/lsp.sh basedpyright $(BASEDPYRIGHT_VERSION)
	@mkdir -p $(@D) && touch $@
else
lsp-servers:
	@echo "lsp-servers is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-lsp-servers:
	@rm -f $(STAMP)/lsp-servers-*.done
	@$(SUDO) rm -f $(DEST)/lua-language-server $(DEST)/gopls \
	  $(DEST)/typescript-language-server $(DEST)/bash-language-server \
	  $(DEST)/yaml-language-server $(DEST)/vscode-json-language-server
	@$(SUDO) rm -rf $(DEST)/_lua-language-server-*
```

- [ ] **Step 4: Wire `go-runtime` + `lsp-servers` into the dev `provision` block**

In `makefile/Makefile`, find (~line 562):
```makefile
provision: pwndbg vcpkg
endif
```
Replace with:
```makefile
provision: pwndbg vcpkg go-runtime lsp-servers
endif
```

- [ ] **Step 5: Add doctor rows + update `list` text**

In the `DOCTOR_ROWS` block near the doctor target (~line 601, after `bespoke|vcpkg`):
```makefile
DOCTOR_ROWS += bespoke|go-runtime|$(GO_VERSION)
DOCTOR_ROWS += bespoke|lsp-servers|-
```

In the `list` recipe (~line 677), after the `C/C++ dev tools` line, add:
```makefile
	@printf '\nLanguage servers (provisioned on MODE=dev only): lsp-servers (+ go-runtime)\n'
	@printf '  (rust-analyzer/marksman/taplo are scope-tools above; clangd from clang-tools-extra)\n'
```

- [ ] **Step 6: Verify gating + provision wiring**

Run:
```bash
cd makefile
make -n lsp-servers MODE=prod            # must print the skip message
make -n lsp-servers MODE=dev | head -5   # must show verify-clangd + lsp.sh calls
make -np MODE=dev 2>/dev/null | grep -E '^provision:.*lsp-servers' # provision includes it
cd ..
make lint MODE=prod
```
Expected: prod prints "lsp-servers is a dev_machine target — skipping"; dev shows the recipe; provision line includes `lsp-servers`; lint passes.

- [ ] **Step 7: Full install + confirm on a dev host (sudo + network)**

Run:
```bash
cd makefile && make lsp-servers MODE=dev ; cd ..
for s in clangd rust-analyzer marksman taplo lua-language-server gopls \
         typescript-language-server bash-language-server yaml-language-server \
         vscode-json-language-server basedpyright; do
  printf '%-32s %s\n' "$s" "$(command -v "$s" || echo MISSING)"
done
```
Expected: every server resolves on PATH (clangd may warn-MISSING if EPEL/CRB unavailable — acceptable, it's verify-only).

- [ ] **Step 8: Commit**

```bash
git add makefile/lib/lsp.sh makefile/Makefile
git commit -m "feat(tools): add lsp-servers meta-target (lua/npm/gopls/basedpyright + clangd verify)"
```

---

## Task 5: The inventory generator (`scripts/gen-tool-memory.sh`)

**Files:**
- Create: `scripts/gen-tool-memory.sh`

**Interfaces:**
- Consumes: `makefile/versions.mk`, `makefile/tools.mk`, `makefile/packages.mk`; env `MEMFILE` (optional override).
- Produces: rewrites the `<!-- TOOLS:START --> … <!-- TOOLS:END -->` block in `$MEMFILE` (default `chezmoi/private_dot_claude/CLAUDE.md`). Idempotent + deterministic.

- [ ] **Step 1: Write the determinism test (failing — the script doesn't exist yet)**

Create `scripts/gen-tool-memory.test.sh` as a throwaway check (deleted in Step 5):
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'prose\n\n<!-- TOOLS:START -->\nstale\n<!-- TOOLS:END -->\n' > "$T/mem.md"
MEMFILE="$T/mem.md" "$ROOT/scripts/gen-tool-memory.sh"
cp "$T/mem.md" "$T/run1.md"
MEMFILE="$T/mem.md" "$ROOT/scripts/gen-tool-memory.sh"   # second run
diff "$T/run1.md" "$T/mem.md"                            # idempotent -> no diff
grep -q '`rg`' "$T/mem.md"                               # a known tool present
grep -q 'Language servers (LSP)' "$T/mem.md"             # the new pin section
grep -q '`basedpyright`' "$T/mem.md"                     # a non-macro LSP server
grep -q 'clang-tools-extra' "$T/mem.md"                  # dnf packages present
echo "GEN TEST PASS"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash scripts/gen-tool-memory.test.sh`
Expected: FAIL — `gen-tool-memory.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/gen-tool-memory.sh`**

```bash
#!/usr/bin/env bash
# gen-tool-memory.sh — regenerate the <!-- TOOLS:START/END --> inventory block
# in the machine-level Claude memory file from the makefile single-source-of-
# truth (versions.mk drives grouping + completeness; tools.mk + a small bespoke
# map resolve VAR -> command name; packages.mk supplies the dnf list).
#
# Run by .claude/hooks/sync-tool-memory.sh on makefile edits, and by
# scripts/check-invariants.sh (drift check) against a temp MEMFILE.
#
#   MEMFILE=<path>  override the target file (default: the chezmoi source).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MK="$ROOT/makefile"
MEMFILE="${MEMFILE:-$ROOT/chezmoi/private_dot_claude/CLAUDE.md}"

[ -f "$MEMFILE" ] || {
  printf 'gen-tool-memory.sh: no memory file at %s\n' "$MEMFILE" >&2
  exit 1
}

# 1. VAR -> command names: from tools.mk macro calls...
declare -A NAMES
while IFS= read -r line; do
  [[ "$line" =~ call[[:space:]]+(EGET_TOOL|TOOL|SOFT_TOOL|USER_TOOL),([^,]+),\$\(([A-Z0-9_]+)\) ]] || continue
  nm="${BASH_REMATCH[2]}"
  var="${BASH_REMATCH[3]}"
  NAMES["$var"]+="${NAMES["$var"]:+ }$nm"
done <"$MK/tools.mk"

# ...plus bespoke / non-macro tools (installed by Makefile targets or npm/uv/go).
NAMES[EGET_VERSION]="eget"
NAMES[NODE_VERSION]="node"
NAMES[GO_VERSION]="go"
NAMES[GOPLS_VERSION]="gopls"
NAMES[CLAUDE_VERSION]="claude"
NAMES[PWNDBG_VERSION]="pwndbg"
NAMES[VCPKG_VERSION]="vcpkg"
NAMES[DOZZLE_VERSION]="dozzle"
NAMES[JETBRAINSMONO_NERD_VERSION]="nerd-fonts"
NAMES[CCSTATUSLINE_VERSION]="ccstatusline"
NAMES[LUA_LS_VERSION]="lua-language-server"
NAMES[BASEDPYRIGHT_VERSION]="basedpyright"
NAMES[TYPESCRIPT_LS_VERSION]="typescript-language-server"
NAMES[BASH_LS_VERSION]="bash-language-server"
NAMES[YAML_LS_VERSION]="yaml-language-server"
NAMES[VSCODE_LANGSERVERS_VERSION]="vscode-langservers-extracted"

# 2. Walk versions.mk top-to-bottom, emit grouped by its `# --- Section ---`.
emit_block() {
  printf '<!-- TOOLS:START — auto-generated by scripts/gen-tool-memory.sh; do not edit inside -->\n'
  printf '<!-- regenerated on makefile edits by .claude/hooks/sync-tool-memory.sh; run `cza` to deploy -->\n'
  local section="" last=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^#[[:space:]]+-+[[:space:]]+(.+[^[:space:]-])[[:space:]]+-+ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*:=[[:space:]]*([^[:space:]#]+) ]] || continue
    local var="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    local names="${NAMES[$var]:-}"
    [ -n "$names" ] || continue
    if [ "$section" != "$last" ]; then
      printf '\n### %s\n' "$section"
      last="$section"
    fi
    local n
    for n in $names; do printf -- '- `%s` %s\n' "$n" "$val"; done
  done <"$MK/versions.mk"

  # 3. dnf optional packages (the C/C++ toolchain + general system tools).
  printf '\n### System packages (dnf, dev-only)\n'
  awk '/^LINUX_OPTIONAL_PACKAGES[[:space:]]*:=/{f=1}
       f{print}
       f && $0 !~ /\\$/{exit}' "$MK/packages.mk" |
    sed -E 's/^LINUX_OPTIONAL_PACKAGES[[:space:]]*:=//; s/\\//g' |
    tr ' ' '\n' | grep -vE '^$' | sort -u | paste -sd' ' - | sed 's/^/- /'

  printf '\n<!-- TOOLS:END -->\n'
}

block="$(emit_block)"

# 4. Splice the block in place of the existing one (atomic via temp + mv).
tmp="$(mktemp)"
awk -v block="$block" '
  index($0, "<!-- TOOLS:START") { print block; skip=1; next }
  index($0, "<!-- TOOLS:END -->") { skip=0; next }
  !skip { print }
' "$MEMFILE" >"$tmp"
mv "$tmp" "$MEMFILE"
```

- [ ] **Step 4: Make it LF+exec, then run the test to verify it passes**

Run:
```bash
chmod +x scripts/gen-tool-memory.sh
bash scripts/gen-tool-memory.test.sh
shellcheck -x -S warning scripts/gen-tool-memory.sh && shfmt -d -i 2 scripts/gen-tool-memory.sh
```
Expected: `GEN TEST PASS`; shellcheck/shfmt clean. (If a section header isn't captured, adjust the `# --- … ---` regex; if a tool is missing, check its `NAMES` mapping.)

- [ ] **Step 5: Remove the throwaway test + commit**

```bash
rm -f scripts/gen-tool-memory.test.sh
git add scripts/gen-tool-memory.sh
git commit -m "feat(memory): add tool-inventory generator (sentinel-block, idempotent)"
```

---

## Task 6: The machine-level memory file

**Files:**
- Create: `chezmoi/private_dot_claude/CLAUDE.md`

**Interfaces:**
- Consumes: `scripts/gen-tool-memory.sh` (Task 5) to populate the block.
- Produces: `~/.claude/CLAUDE.md` on `cza` (dev-only). Read by the drift check (Task 8).

- [ ] **Step 1: Create `chezmoi/private_dot_claude/CLAUDE.md` with prose + empty sentinels**

```markdown
# Workstation machine memory

Host-global guidance loaded into every project on this machine. The tool
inventory below the line is **auto-generated** from this workstation's
provisioning makefiles — do not hand-edit inside the `TOOLS` sentinels.

## Navigate code with the LSP tool first

When exploring or understanding code, **prefer the `LSP` tool over grep/find**
for anything a language server answers better:

- **go-to-definition, find-references, hover/type-info, document & workspace
  symbols, diagnostics, rename** → use the `LSP` tool.
- Reach for text/file search (`rg`, `fd`, `ast-grep`/`sg`) only when no server
  applies, for literal/regex/structural matches, or as a fallback when a server
  isn't running for that language.

A server must be **installed** and the file's **language detected**. Coverage on
this host (install via `make lsp-servers MODE=dev`):

| Language | Server |
|---|---|
| C / C++ | clangd |
| Rust | rust-analyzer |
| Python | basedpyright (`basedpyright-langserver`) |
| JavaScript / TypeScript | typescript-language-server |
| Go | gopls |
| Bash | bash-language-server |
| YAML | yaml-language-server |
| JSON / CSS / HTML | vscode-langservers-extracted |
| TOML | taplo (`taplo lsp`) |
| Markdown | marksman |
| Lua | lua-language-server |

## Prefer the modern tool

This box installs a large modern toolbelt. Default to these over their classic
equivalents:

- search/files: `rg` (not grep), `fd` (not find), `ast-grep`/`sg` (structural)
- view: `bat` (not cat), `eza` (not ls), `delta` / `difft` (diffs)
- data: `jq` / `yq` / `fx` (JSON/YAML), `mlr` / `qsv` (CSV), `usql` (SQL)
- system: `btop` / `procs` (processes), `dust` / `ncdu` (disk), `sd` (simple sed)
- dev: `gh` (GitHub), `hyperfine` (benchmark), `gitui` / `lazygit`, `jj` (VCS)

The full, always-current inventory of what's installed (with versions) is below.

<!-- TOOLS:START — auto-generated by scripts/gen-tool-memory.sh; do not edit inside -->
<!-- TOOLS:END -->
```

- [ ] **Step 2: Populate the block by running the generator against the real file**

Run:
```bash
scripts/gen-tool-memory.sh
grep -c '<!-- TOOLS:START' chezmoi/private_dot_claude/CLAUDE.md  # -> 1
grep -c '<!-- TOOLS:END -->' chezmoi/private_dot_claude/CLAUDE.md # -> 1
grep -E '`rust-analyzer`|`basedpyright`|`gopls`' chezmoi/private_dot_claude/CLAUDE.md
```
Expected: exactly one of each sentinel; the LSP servers appear in the block.

- [ ] **Step 3: Verify chezmoi naming + dev-only gating**

Run:
```bash
chezmoi source-path ~/.claude/CLAUDE.md 2>/dev/null \
  || chezmoi target-path chezmoi/private_dot_claude/CLAUDE.md
chezmoi ignored | grep -E '^\.claude$' && echo "DEV-GATED OK"   # on a prod-group host
chezmoi diff ~/.claude/CLAUDE.md 2>/dev/null | head -5           # on a dev host
```
Expected: source maps to `~/.claude/CLAUDE.md`; on prod-group hosts `.claude` is in `chezmoi ignored` (file won't deploy); on dev, `chezmoi diff` shows it pending. If the source path doesn't resolve, confirm the filename is exactly `CLAUDE.md` under `private_dot_claude/` (no `.tmpl`).

- [ ] **Step 4: Commit**

```bash
git add chezmoi/private_dot_claude/CLAUDE.md
git commit -m "feat(memory): add machine-level ~/.claude/CLAUDE.md (LSP-first + auto inventory)"
```

---

## Task 7: The sync hook + its tests

**Files:**
- Create: `.claude/hooks/sync-tool-memory.sh`
- Modify: `.claude/settings.json`, `.claude/hooks/test-hooks.sh`

**Interfaces:**
- Consumes: hook JSON on stdin (`.tool_input.file_path`); `scripts/gen-tool-memory.sh` (Task 5); env `MEMFILE` (passed through to the generator, used by the test).
- Produces: regenerated `TOOLS` block + a `cza` nudge in `additionalContext`.

- [ ] **Step 1: Add failing assertions to `.claude/hooks/test-hooks.sh`**

Insert before the final `echo` / summary block (after the `parity-reminder` section, ~line 73):
```bash
echo "== sync-tool-memory (R5) =="
ST="$(mktemp -d)"
printf 'x\n<!-- TOOLS:START -->\nstale\n<!-- TOOLS:END -->\n' >"$ST/CLAUDE.md"
MEMFILE="$ST/CLAUDE.md" run "$RH/sync-tool-memory.sh" "$(j --arg f "$ROOT/makefile/versions.mk" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "versions.mk -> cza nudge" has 'cza'
ok "block regenerated (stale gone)" bash -c '! grep -q stale "'"$ST"'/CLAUDE.md"'
run "$RH/sync-tool-memory.sh" "$(j --arg f "/tmp/unrelated.go" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
ok "unrelated path -> silent" empty
run "$RH/sync-tool-memory.sh" 'not json at all'
ok "malformed input -> fail-open silent" empty
rm -rf "$ST"
```

Note: `run` overrides do not pass env; change the `R5` first `run` to set `MEMFILE` inline. Replace the `run` helper invocation for that one case with:
```bash
OUT="$(printf '%s' "$(j --arg f "$ROOT/makefile/versions.mk" '{tool_name:"Edit",tool_input:{file_path:$f}}')" | MEMFILE="$ST/CLAUDE.md" bash "$RH/sync-tool-memory.sh" 2>/dev/null)"
ok "versions.mk -> cza nudge" has 'cza'
ok "block regenerated (stale gone)" bash -c '! grep -q stale "'"$ST"'/CLAUDE.md"'
```
(Keep the unrelated/malformed cases using the plain `run` helper.)

- [ ] **Step 2: Run the tests to confirm the new section fails**

Run: `bash .claude/hooks/test-hooks.sh`
Expected: the existing sections PASS; the `sync-tool-memory` asserts FAIL (script missing).

- [ ] **Step 3: Write `.claude/hooks/sync-tool-memory.sh`**

```bash
#!/usr/bin/env bash
# sync-tool-memory.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. When Claude edits a tool-source makefile, regenerate the
# auto-inventory block in the machine-level Claude memory (chezmoi source
# chezmoi/private_dot_claude/CLAUDE.md) so it never drifts from what the repo
# installs. Pure: fails OPEN (does nothing) on unparseable input or a generator
# error, always exits 0. Reports back so Claude commits it + runs `cza`.
#
# Honors MEMFILE in the environment (passed through to the generator) so the
# hook test can target a throwaway file. See CLAUDE.md + docs/claude/.
set -u

INPUT="$(cat)"
hookfield() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | HF="$1" python3 -c 'import os,sys,json
p=os.environ["HF"].lstrip(".").split(".")
try:
    v=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in p:
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")' 2>/dev/null
  fi
}

f="$(hookfield '.tool_input.file_path')"
[ -n "$f" ] || exit 0
norm="${f//\\//}"

case "$norm" in
*/makefile/versions.mk | */makefile/tools.mk | */makefile/packages.mk | */makefile/Makefile) ;;
*) exit 0 ;;
esac

# Resolve the generator: prefer CLAUDE_PROJECT_DIR, else walk up from the file.
gen=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh" ]; then
  gen="$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh"
else
  d="$(dirname "$norm")"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -x "$d/scripts/gen-tool-memory.sh" ]; then
      gen="$d/scripts/gen-tool-memory.sh"
      break
    fi
    d="$(dirname "$d")"
  done
fi
[ -n "$gen" ] || exit 0

"$gen" >/dev/null 2>&1 || exit 0

msg="Tool inventory regenerated in chezmoi/private_dot_claude/CLAUDE.md (TOOLS block) from your makefile edit — commit it with this change and run \`cza\` to deploy the refreshed memory to ~/.claude/CLAUDE.md."

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"suppressOutput":true}\n' "$msg"
fi
exit 0
```

- [ ] **Step 4: LF+exec, run the hook tests to verify pass**

Run:
```bash
chmod +x .claude/hooks/sync-tool-memory.sh
bash .claude/hooks/test-hooks.sh
```
Expected: `✓ all N hook assertions passed` (existing + the 4 new `sync-tool-memory` asserts).

- [ ] **Step 5: Wire the hook in `.claude/settings.json`**

Add a third entry to the existing `PostToolUse` array (after `parity-reminder.sh`):
```json
            {
              "type": "command",
              "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/sync-tool-memory.sh\""
            }
```
The `PostToolUse` `hooks` array for matcher `Edit|Write|MultiEdit` becomes three entries: `post-edit-guard.sh`, `parity-reminder.sh`, `sync-tool-memory.sh`.

- [ ] **Step 6: Validate settings JSON + lint**

Run:
```bash
jq . .claude/settings.json >/dev/null && echo "JSON OK"
make lint MODE=prod
```
Expected: `JSON OK`; `✓ all invariant checks passed` (shellcheck/shfmt over the new hook auto-included).

- [ ] **Step 7: Commit**

```bash
git add .claude/hooks/sync-tool-memory.sh .claude/hooks/test-hooks.sh .claude/settings.json
git commit -m "feat(hooks): add sync-tool-memory PostToolUse hook (regen inventory on makefile edits)"
```

---

## Task 8: Drift check in `check-invariants.sh`

**Files:**
- Modify: `scripts/check-invariants.sh`

**Interfaces:**
- Consumes: `scripts/gen-tool-memory.sh` (Task 5), `chezmoi/private_dot_claude/CLAUDE.md` (Task 6).
- Produces: a `check_tools_block` check + a TOOLS sentinel assertion; fails CI if the committed block is stale.

- [ ] **Step 1: Add the TOOLS sentinel to `check_sentinels`**

In `scripts/check-invariants.sh`, inside `check_sentinels()` (after the wezterm block, before the closing `}`, ~line 196):
```bash
  s=$(grep -cE '<!-- TOOLS:START' chezmoi/private_dot_claude/CLAUDE.md)
  e=$(grep -cE '<!-- TOOLS:END -->' chezmoi/private_dot_claude/CLAUDE.md)
  if [ "$s" = "1" ] && [ "$e" = "1" ]; then
    ok "machine-memory  TOOLS:START/END (1/1)"
  else
    bad "machine-memory TOOLS sentinels START=$s END=$e (want 1/1)"
  fi
```

- [ ] **Step 2: Add a `check_tools_block` function**

Insert after `check_sentinels()` (before `check_chezmoiignore_targets`, ~line 198):
```bash
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
```

- [ ] **Step 3: Call it in the runner**

At the bottom of the file (~line 281), after `check_sentinels`:
```bash
check_tools_block
```

- [ ] **Step 4: Verify the check passes, then verify it catches drift**

Run:
```bash
make lint MODE=prod        # must pass (block currently in sync from Task 6)
# negative test: perturb the block, expect failure
sed -i 's/`rg`/`RIGHT_BROKE`/' chezmoi/private_dot_claude/CLAUDE.md
make lint MODE=prod ; echo "exit=$?"   # expect "TOOLS block stale" + exit=1
git checkout chezmoi/private_dot_claude/CLAUDE.md   # restore
make lint MODE=prod        # passes again
```
Expected: clean → stale (exit 1) → clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-invariants.sh
git commit -m "feat(lint): drift-check the machine-memory TOOLS block + sentinel"
```

---

## Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `README.html`, `CLAUDE_CHANGELOG.md`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: the documentation surface; no code.

- [ ] **Step 1: Update `CLAUDE.md` (project)** — make these edits:
  - In the "Claude Code hooks" → "Repo" bullet list, add: `sync-tool-memory.sh` — PostToolUse; on edits to `makefile/versions.mk|tools.mk|packages.mk|Makefile`, regenerates the `TOOLS` block in `chezmoi/private_dot_claude/CLAUDE.md`; nudges to `cza`.
  - In "Load-bearing invariants", add a bullet: machine-level memory is `chezmoi/private_dot_claude/CLAUDE.md` → `~/.claude/CLAUDE.md` (dev-only via existing `.claude` gating); the `<!-- TOOLS:START/END -->` block is auto-generated by `scripts/gen-tool-memory.sh` — never hand-edit inside.
  - Add a bullet near the node-runtime/pwndbg/vcpkg entries: `go-runtime` (dev-only, `lib/go.sh`) + `lsp-servers` (dev-only meta-target, `lib/lsp.sh`) install the language-server stack; rust-analyzer/marksman/taplo are both-scope eget; clangd is verified-only (from `clang-tools-extra`).
  - In "Files Claude should be careful with" → sentinel-blocks list, add `chezmoi/private_dot_claude/CLAUDE.md` (`<!-- TOOLS:START/END -->`).
  - In "Single-source-of-truth files", add `scripts/gen-tool-memory.sh` (the TOOLS-block generator).

- [ ] **Step 2: Update `docs/claude/invariants.md` + `docs/claude/file-care.md`** — add deep entries:
  - invariants.md: the `go-runtime`/`lsp-servers` install shapes (dev-only, best-effort per-server, the npm `--prefix`/`GOBIN`/uv bin landing) and the memory-file gating + auto-block.
  - file-care.md: `chezmoi/private_dot_claude/CLAUDE.md` (auto-generated block, don't hand-edit inside sentinels; regenerate with `scripts/gen-tool-memory.sh`); `lib/go.sh`/`lib/lsp.sh`/`scripts/gen-tool-memory.sh`/`.claude/hooks/sync-tool-memory.sh` are LF+0755 first-party shell.

- [ ] **Step 3: Update `README.html`** — the new LSP servers + Go toolchain are user-facing. Add them to the tool inventory / machines surface and add a short "Code intelligence (LSP)" note: `make lsp-servers MODE=dev` installs clangd (verify), rust-analyzer, marksman, taplo, lua-language-server, basedpyright, gopls, and the typescript/bash/yaml/json language servers; `go-runtime` provides Go. Keep the change scoped to the tool surface (the memory/hook/generator stay internal). Decision test: "could a user operate the repo from README.html alone?" — yes, with the new `make lsp-servers` / `make go-runtime` targets documented.

- [ ] **Step 4: Append a `CLAUDE_CHANGELOG.md` row** summarizing: machine-level Claude memory + auto-inventory hook; LSP-server stack + Go toolchain; which README sections changed.

- [ ] **Step 5: Lint + final full-suite check**

Run:
```bash
make lint MODE=prod
bash .claude/hooks/test-hooks.sh
```
Expected: both green.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/claude/invariants.md docs/claude/file-care.md README.html CLAUDE_CHANGELOG.md
git commit -m "docs: machine-memory + LSP/Go provisioning (README, CLAUDE.md, changelog)"
```

---

## Self-Review

**1. Spec coverage** — every spec component maps to a task:
- A (memory file) → Task 6. B (generator) → Task 5. C (hook) → Task 7. D (LSP provisioning) → Tasks 1–4. E (guidance prose) → Task 6 Step 1. F (enforcement & docs) → Tasks 7 (test-hooks), 8 (drift check), 9 (docs).
- Spec §13 file-change checklist — every file appears in a task's Files block. ✓

**2. Placeholder scan** — no "TBD/TODO/handle errors". The version *values* in Task 1 are concrete starting pins with an exact discovery command (Step 1) — not placeholders. The `--asset` flags in Task 2 have a concrete starting value + an empirical-confirm step (mirrors the repo's documented tool-adding loop). ✓

**3. Type/name consistency** — names match across tasks: `gen-tool-memory.sh` (Tasks 5/6/7/8), `sync-tool-memory.sh` (Task 7), `lsp-servers`/`go-runtime` (Tasks 3/4/9), `LSP_STAMP`/`LSP_PINS` (Task 4 only), env `MEMFILE` (Tasks 5/7/8), the sentinels `<!-- TOOLS:START -->`/`<!-- TOOLS:END -->` (Tasks 5/6/8). The `clean-lsp-servers` removes `vscode-json-language-server` (the binary `vscode-langservers-extracted` actually installs) — confirm during Task 4 Step 7 and adjust the clean list if the package ships differently-named bins. ✓

**Deviations from spec (justified):** lua-language-server moved from a both-scope eget `TOOL` to the dev-only `lsp-servers` target because it is a multi-file tree (the binary needs its runtime tree alongside; `archive.sh`'s binary-only install would break it). Noted in Task 1's section comment and Task 4.
