# Machine-level Claude memory for the workstation toolbelt — design

- **Date:** 2026-06-21
- **Status:** Approved (brainstorming) — pending implementation plan
- **Scope:** Claude-internal infra + a user-facing provisioning expansion (new LSP servers + Go toolchain)
- **Related:**
  - `chezmoi/private_dot_claude/` (existing global Claude config)
  - `.claude/hooks/` (existing repo hooks), `.claude/settings.json`
  - `makefile/versions.mk`, `makefile/tools.mk`, `makefile/packages.mk`, `makefile/Makefile`
  - `scripts/check-invariants.sh`, `.claude/hooks/test-hooks.sh`
  - prior art: `scripts/setup-ccstatusline.sh` (sentinel block), `scripts/manage-hosts.sh` (sentinel block), `chezmoi/private_dot_claude/modify_private_settings.json`

---

## 1. Goal

Give Claude a **machine-level memory** — `~/.claude/CLAUDE.md`, loaded into every project on the host — that:

1. **Inventories every tool this workstation installs** (name + version + grouping), so Claude reaches for the right modern tool instead of a worse default.
2. **Steers Claude to prefer the `LSP` tool over Linux text tools when navigating code** (go-to-definition / references / hover / symbols / rename), falling back to `rg`/`fd`/`ast-grep` only where no language server applies.
3. **Stays auto-fresh**: a repo hook regenerates the inventory whenever a tool-source file (`versions.mk` / `tools.mk` / `packages.mk` / `Makefile`) is edited, so the memory never drifts from what the repo actually installs.

To make (2) real (today only `clangd` is installed), the design also **expands LSP-server coverage** across the languages this user works in, and **pulls in a Go toolchain** so `gopls` works.

## 2. Locked decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Memory location | Chezmoi-tracked `chezmoi/private_dot_claude/CLAUDE.md` → `~/.claude/CLAUDE.md` | Committed + reproducible on every host; fits the repo's chezmoi-owns-`$HOME` model; inherits existing dev-only `.claude` gating. |
| Update delivery | Hook regenerates the **source** file; reaches `~/.claude` on the next `cza` (chezmoi apply) | Keeps it in source control; no hook-driven `chezmoi apply` (too heavy / can prompt). |
| Inventory generation | **Auto-write** a sentinel block (post-edit-guard style) | Always fresh; zero reliance on Claude remembering to regenerate. |
| LSP scope | **Install + document** a curated server set | "Prefer LSP" is only useful with real coverage. |
| Static LSP servers scope | **Both-scope** via `EGET_TOOL` | Tiny static binaries; matches the ~80 other both-scope tools. |
| Python server | **basedpyright** | Maintained pyright fork; self-contained PyPI package (bundles its own JS runtime — needs neither our node-runtime nor npm). |
| Go | **Pulled in now** via a new `go-runtime` target | Unblocks `gopls`; Go becomes generally available on dev as a bonus. |
| clangd | **First-class member** of the LSP set, verified by `lsp-servers` | User asked clangd be included "like the others." |

## 3. Architecture overview

Six components:

- **A. Memory file** — `chezmoi/private_dot_claude/CLAUDE.md`: hand-written prose + an auto-generated sentinel block.
- **B. Generator** — `scripts/gen-tool-memory.sh`: parses the makefile sources, rewrites the sentinel block deterministically.
- **C. Repo hook** — `.claude/hooks/sync-tool-memory.sh`: PostToolUse; on a tool-source edit, runs the generator and reports back.
- **D. LSP-server provisioning** — new `lsp-servers` meta-target + `go-runtime` runtime target + `versions.mk` pins + `lib/` helpers.
- **E. Guidance prose** — the LSP-first policy + a tight "prefer-these" tool table (the hand-written zone of A).
- **F. Enforcement & docs** — `check-invariants.sh` drift check, `test-hooks.sh` assertions, CLAUDE.md / file-care / README / changelog updates.

### Data flow / lifecycle

```
edit versions.mk / tools.mk / packages.mk / Makefile
        │  (Claude Edit/Write)
        ▼
PostToolUse: sync-tool-memory.sh   ── matches tool-source path? ──no──► exit 0
        │ yes
        ▼
scripts/gen-tool-memory.sh  ──► rewrites  TOOLS:START/END  block
        │                        in chezmoi/private_dot_claude/CLAUDE.md (SOURCE)
        ▼
additionalContext: "tool inventory regenerated — run `cza` to deploy to ~/.claude/CLAUDE.md"
        │
        ▼  (user commits; runs cza)
chezmoi apply ──► ~/.claude/CLAUDE.md  ──► loaded into every project on the host
```

The generator writes via the shell, not Claude's Edit tool, so the hook does **not** re-trigger on its own write (no loop). `check-invariants.sh` (pre-commit + CI) guarantees the committed block equals a fresh regeneration, so a missed hook firing or a hand-edit inside the block is caught.

## 4. Component A — the memory file

**Path:** `chezmoi/private_dot_claude/CLAUDE.md` → deploys to `~/.claude/CLAUDE.md`.

- **Naming:** plain `CLAUDE.md` under `private_dot_claude/` (no `.tmpl` — no templating needed; a `.tmpl` here would be fine too but is unnecessary). Confirm chezmoi maps `private_dot_claude/CLAUDE.md` → `~/.claude/CLAUDE.md` during implementation (sibling of `modify_private_settings.json`, `executable_notify.sh`).
- **Gating:** `.claude` is already dev-only in `.chezmoiignore.tmpl`, so this file deploys on `dev_machine` only — no new ignore entry. (Verify with `chezmoi ignored` after adding.)
- **Two zones:**
  1. **Curated prose** (hand-written, Component E) — top of file.
  2. **Auto-generated inventory** between sentinels:
     ```
     <!-- TOOLS:START — auto-generated by scripts/gen-tool-memory.sh; do not edit inside -->
     ...categorized tool inventory...
     <!-- TOOLS:END -->
     ```
     HTML comments (markdown-invisible) are the sentinel style, analogous to `-- HOSTS:START/END` (wezterm.lua) and `# CCSTATUSLINE:START/END` (.chezmoiignore.tmpl).

## 5. Component B — the generator (`scripts/gen-tool-memory.sh`)

**Responsibility:** rewrite *only* the `TOOLS:START/END` block of the memory file from the makefile sources. Idempotent, deterministic.

**Inputs (direct parse — no `make` invocation; fast, side-effect-free, reflects the just-edited file):**
- `makefile/versions.mk` — authoritative versions + section grouping (the `# --- Title ---` headers define the inventory's groups and order).
- `makefile/tools.mk` — maps each `*_VERSION` var → real command name(s) (e.g. `RIPGREP_VERSION`→`rg`, `TEALDEER_VERSION`→`tldr`, `PUEUE_VERSION`→`pueue`+`pueued`). Reads `EGET_TOOL`/`TOOL`/`SOFT_TOOL`/`USER_TOOL` lines.
- `makefile/packages.mk` — `LINUX_OPTIONAL_PACKAGES` (the C/C++ toolchain → clangd/gdb/valgrind/etc.) as a "dnf (dev-only)" group.
- A small fixed list of **bespoke/runtime targets** parsed from `Makefile` or hardcoded: `node-runtime`, `go-runtime`, `docker-engine`, `pwndbg`, `vcpkg`, `claude-cli`, `nerd-fonts`, plus the new `lsp-servers` members.

**Algorithm:**
1. Build `VAR → version` map from `versions.mk`; remember each var's section header.
2. Build `VAR → [command names]` map from `tools.mk`.
3. Emit one group per `versions.mk` section header (preserving file order), listing `command vX.Y.Z` for each tool, sorted stably within the group.
4. Append a **"C/C++ toolchain (dnf, dev-only)"** group from `LINUX_OPTIONAL_PACKAGES` and a **"Runtimes & bespoke"** group for the bespoke targets.
5. Append a dedicated **"Language servers (LSP)"** group listing every server + the language it covers + its `LSP`-tool relevance (this is the part Claude consults most for navigation).
6. Replace the block between sentinels; leave the prose untouched.

**Grouping choice:** by `versions.mk` section header — zero-maintenance and fully automatic. The historical/chronological labels ("Second-wave expansion") are acceptable because the curated prose (Component E) carries the *functional* "use X over Y" guidance. (Functional re-grouping via a curated category map is a possible future enhancement; deferred to keep the auto-update promise pure.) Unmapped new tools still appear (under their section), so the inventory is never silently incomplete.

**Conventions:** LF-only, mode `100755`, `#!/usr/bin/env bash`, `set -u`, shellcheck-clean at warning+, `shfmt -i 2`-clean — joins the first-party shell set enforced by `check-invariants.sh`. No network, no `sudo`.

**Considered alternative:** drive generation off a new read-only `make tool-manifest` target (make resolves all vars → most robust, immune to parser drift). Deferred: it couples the hook to invoking `make` and still needs a grouping source. Revisit if direct parsing proves brittle.

## 6. Component C — the repo hook (`.claude/hooks/sync-tool-memory.sh`)

**Event:** `PostToolUse`, matcher `Edit|Write|MultiEdit`. Wired in `.claude/settings.json` as a third `PostToolUse` hook alongside `post-edit-guard.sh` and `parity-reminder.sh`.

**Behavior:**
1. Read hook JSON on stdin; extract `.tool_input.file_path` via the established `jq → python3 → fail-open` helper (copied from the sibling hooks).
2. Normalize backslashes; match against the **trigger set**: `*/makefile/versions.mk`, `*/makefile/tools.mk`, `*/makefile/packages.mk`, `*/makefile/Makefile`. No match → `exit 0`.
3. Run `scripts/gen-tool-memory.sh` (resolve repo root from `$CLAUDE_PROJECT_DIR` or the edited file's path). On success, emit compact PostToolUse JSON with `additionalContext`:
   > "Tool inventory regenerated in `chezmoi/private_dot_claude/CLAUDE.md` (TOOLS block) from your makefile edit. Commit it alongside this change, and run `cza` to deploy the refreshed memory to `~/.claude/CLAUDE.md`."
4. **Optional nudge:** if the edited file *is* `chezmoi/private_dot_claude/CLAUDE.md` and the diff touched inside the sentinels, warn that the block is auto-generated (hand-edits get clobbered) — mirrors the `.chezmoiignore` reminder in `parity-reminder.sh`.

**Contract:** fail-open (do nothing if input unparseable or generator errors), always `exit 0`, compact single-line JSON, `suppressOutput:true`. Mirrors `post-edit-guard.sh` exactly.

**Auto-write vs nudge:** auto-write — the hook *performs* the regeneration (like post-edit-guard auto-repairs), not merely reminds.

## 7. Component D — LSP-server provisioning

Dev-gated, unified under a new **`lsp-servers`** meta-target that joins `provision` on `MODE=dev`. One `make lsp-servers` installs/verifies the entire stack.

### 7.1 Server matrix

| Server | Language(s) | Install mechanism | Scope | `versions.mk` pin |
|---|---|---|---|---|
| clangd | C/C++ | already via `clang-tools-extra` (dnf, `LINUX_OPTIONAL_PACKAGES`); `lsp-servers` **verifies + reports** | dev | — (dnf-versioned) |
| rust-analyzer | Rust | `EGET_TOOL` (`rust-lang/rust-analyzer`, `.gz` raw binary) | both | `RUST_ANALYZER_VERSION` |
| marksman | Markdown | `EGET_TOOL` (`artempyanykh/marksman`, raw binary) | both | `MARKSMAN_VERSION` |
| taplo | TOML | `EGET_TOOL` (`tamasfe/taplo`; `taplo lsp`) | both | `TAPLO_VERSION` |
| lua-language-server | Lua | `TOOL` + `archive.sh` (LuaLS tarball: `bin/lua-language-server` wrapper + runtime) | both | `LUA_LS_VERSION` |
| basedpyright | Python | `uv tool install basedpyright==$(BASEDPYRIGHT_VERSION)` (uv already provisioned) | dev | `BASEDPYRIGHT_VERSION` |
| typescript-language-server | JS/TS | `npm -g` via `node-runtime` (also installs `typescript`) | dev | `TYPESCRIPT_LS_VERSION` |
| bash-language-server | Bash | `npm -g` via `node-runtime` | dev | `BASH_LS_VERSION` |
| yaml-language-server | YAML | `npm -g` via `node-runtime` | dev | `YAML_LS_VERSION` |
| vscode-langservers-extracted | JSON/CSS/HTML | `npm -g` via `node-runtime` | dev | `VSCODE_LANGSERVERS_VERSION` |
| gopls | Go | `GOBIN=$(DEST) go install golang.org/x/tools/gopls@v$(GOPLS_VERSION)` via `go-runtime` | dev | `GOPLS_VERSION` |

### 7.2 New `go-runtime` target (mirrors `node-runtime`)

- Bespoke target, **dev-only**, joins `provision` on `MODE=dev`.
- `lib/go.sh <version>`: download the official go tarball from `https://go.dev/dl/go<ver>.linux-amd64.tar.gz` (sha256-verified), extract to `$(DEST)/_go-<ver>/`, symlink `go` + `gofmt` into `$(DEST)`. Strips older `_go-*` trees on reinstall.
- `$(SUDO)` (deposits under `/usr/local` on dev). Stamp bakes `GO_VERSION`.
- `clean-go-runtime` removes the symlinks + `_go-*` tree + stamp.

### 7.3 New `lsp-servers` meta-target

```
.PHONY: lsp-servers clean-lsp-servers
ifeq ($(MODE),dev)
lsp-servers: rust-analyzer marksman taplo lua-language-server node-runtime go-runtime
	@# verify clangd (from clang-tools-extra); warn if missing
	@# npm -g (via node-runtime npm, --prefix so bins land on PATH):
	@#   typescript-language-server typescript bash-language-server
	@#   yaml-language-server vscode-langservers-extracted   (pinned)
	@# uv tool install basedpyright==<pin>
	@# GOBIN=$(DEST) go install golang.org/x/tools/gopls@v<pin>
	@# stamp baked with a combined hash of all LSP pins
else
lsp-servers:
	@echo "lsp-servers is a dev_machine target — skipping (MODE=$(MODE))"
endif
```

- **PATH landing:** npm `-g` uses `--prefix "$(dirname $(DEST))"` so binaries land in `$(DEST)` (e.g. `/usr/local/bin`); `gopls` via `GOBIN=$(DEST)`; basedpyright via uv's default user bin (`~/.local/bin`, on PATH). `lib/lsp.sh` encapsulates these.
- **Stamp:** baked with a short hash of all the LSP version pins (so bumping any pin reinstalls), or per-mechanism sub-stamps — decided in the plan.
- `provision` (MODE=dev) gains: `go-runtime` and `lsp-servers` (added to the existing `provision: claude-cli node-runtime ... pwndbg vcpkg` dev block).

### 7.4 Registry bookkeeping

- `RUST_ANALYZER`/`MARKSMAN`/`TAPLO` (EGET_TOOL) auto-register `UPDATE_SPECS` + `DOCTOR_ROWS`.
- `LUA_LS` (TOOL) → hand-add `UPDATE_SPECS` (`LuaLS/lua-language-server|v$(LUA_LS_VERSION)`).
- npm / basedpyright / gopls / go-runtime → hand-add `UPDATE_SPECS` lines (GitHub repos: `typescript-language-server/typescript-language-server`, `bash-lsp/bash-language-server`, `redhat-developer/yaml-language-server`, `hrsh7th/vscode-langservers-extracted`, `DetachHead/basedpyright`, `golang/tools` for gopls, `golang/go` for go) and `DOCTOR_ROWS` (`bespoke|go-runtime|$(GO_VERSION)`, `bespoke|lsp-servers|-`, plus per-server rows as useful).
- `make list` updated to mention the LSP servers + `go-runtime` (like the existing "C/C++ dev tools" line).
- Weekly `version-bumps.yml` / `scripts/bump-versions.sh`: simple pins auto-PR'd where a tag source exists; npm/uv/go pins reported if not auto-bumpable (same treatment as existing non-trivial pins).

## 8. Component E — guidance prose (hand-written zone of A)

Concise, high-signal. Sections:

1. **LSP-first navigation policy.** Prefer the `LSP` tool for: go-to-definition, find-references, hover/type info, document & workspace symbols, diagnostics, and rename. Use `rg`/`fd`/`ast-grep`/`sg` only for text/file/structural search where no server applies, or as a fallback when a server isn't running for that language. Note that a server must be installed *and* the file's language detected; list which languages are covered (C/C++, Rust, Python, JS/TS, Go, Bash, YAML, JSON/CSS/HTML, TOML, Markdown, Lua).
2. **"Prefer-these" tool table** (tight): `rg`>grep, `fd`>find, `bat`>cat, `eza`>ls, `delta`/`difft` for diffs, `ast-grep`/`sg` for structural search/rewrite, `jq`/`yq`/`fx` for JSON/YAML, `dust`/`ncdu` for disk, `btop`/`procs` for processes, `sd`>sed for simple substitution, `gh` for GitHub, `hyperfine` for benchmarking. Kept short — the generated block carries the full inventory.
3. **Pointer** to the auto-generated inventory below and a one-liner that it's machine-generated from the workstation's makefile (don't hand-edit inside the sentinels).

The prose explicitly avoids duplicating the full tool list (that's the generated block) and avoids project-specific content (this is host-global, loaded everywhere).

## 9. Component F — enforcement & docs

**Mechanical (`scripts/check-invariants.sh`):**
- Add `gen-tool-memory.sh` + `sync-tool-memory.sh` to the LF+0755 + shellcheck + `shfmt -i 2` set (the `.claude/hooks/*.sh` glob already covers the hook; add the `scripts/*.sh` generator if not already globbed).
- Add a **TOOLS-block drift check**: run `gen-tool-memory.sh` to a temp copy and diff the `TOOLS:START/END` block against the committed `chezmoi/private_dot_claude/CLAUDE.md`; fail on mismatch (same shape as the existing CCSTATUSLINE / sentinel checks). Guarantees the committed block is never stale.
- Add `<!-- TOOLS:START/END -->` to the sentinel-block invariant set.

**Hook tests (`.claude/hooks/test-hooks.sh`):**
- Assert `sync-tool-memory.sh` regenerates on a `versions.mk` (and `tools.mk`/`packages.mk`/`Makefile`) edit and no-ops on an unrelated path.
- Assert fail-open on malformed JSON.

**Docs:**
- **`CLAUDE.md` (project):** add `sync-tool-memory.sh` to the "Claude Code hooks" repo list; add the `TOOLS:START/END` sentinel-block invariant; add `gen-tool-memory.sh` + the memory file to single-source-of-truth / file-care; add `go-runtime` + `lsp-servers` + the LSP pins as a dev-only-provisioning bullet (node-runtime-style); add the new memory file to the chezmoi-managed `~/.claude` notes.
- **`docs/claude/invariants.md` + `docs/claude/file-care.md`:** deep entries (the generator/hook/sentinel; go-runtime/lsp-servers install shapes; the memory file's gating + auto-generated block).
- **`README.html` (+ `docs/README/README.css`/`.js` if needed):** user-facing — the new LSP servers + Go toolchain are new tools installed on dev machines. Update the tool list / machines / "adding a tool" surface and add an "LSP / code intelligence" mention. **Append a `CLAUDE_CHANGELOG.md` row.**
- The memory file itself + hook + generator are Claude-internal and need no README beyond the LSP-server/Go provisioning surface above.

## 10. Error handling

- **Hook:** fail-open everywhere (unparseable input, missing generator, generator non-zero) → `exit 0`, never blocks an edit. Worst case the block is briefly stale; the drift check catches it at commit.
- **Generator:** if a `*_VERSION` var has no matching command in `tools.mk`, emit the var-derived name with a `?` marker rather than aborting (keeps the inventory complete + signals the gap). Never partial-writes the file (write to temp, then move).
- **`lsp-servers` target:** each server install is best-effort with a clear per-server warning on failure (matches the C/C++ `|| true` fail-soft and `cht.sh` SOFT_TOOL precedent); a single server's network blip must not abort `make dev`. clangd "missing" is a warning, not an error (it comes from a separate dnf group that may be skipped on non-RHEL).
- **`go install gopls`** compiles (slow, ~30–60s) and needs network — acceptable for a provision step (cf. vcpkg bootstrap); wrapped best-effort.

## 11. Testing & verification

- `bash .claude/hooks/test-hooks.sh` passes (new assertions included).
- `make lint MODE=prod` passes (shellcheck/shfmt/sentinel/drift checks, incl. the new TOOLS-block drift check).
- `scripts/gen-tool-memory.sh` run twice produces identical output (determinism) and a no-op diff against the committed block.
- `make lsp-servers MODE=dev` on a dev host installs the stack; `clangd`, `rust-analyzer`, `basedpyright`, `gopls`, `typescript-language-server`, etc. resolve on PATH; `make doctor MODE=dev` lists them.
- `chezmoi ignored` shows `.claude` (hence the new `CLAUDE.md`) ignored on prod, deployed on dev; `chezmoi diff` shows `~/.claude/CLAUDE.md` after `cza`.
- A `versions.mk` edit during a Claude session triggers `sync-tool-memory.sh` → regenerated block + the `cza` nudge.

## 12. Out of scope / future

- Functional (rather than section-based) grouping of the inventory via a curated category map.
- A `make tool-manifest`-driven generator (more robust, make-coupled) — only if direct parsing proves brittle.
- Additional language servers beyond the matrix (e.g. `vue-language-server`, `dockerfile-language-server`) — additive later via the same `lsp-servers` target.
- Windows-side LSP/memory parity (this design is Linux dev_machine only; Windows Claude config is out of scope here).
- Hook-driven `chezmoi apply` (explicitly rejected — `cza` stays manual).

## 13. File-change checklist (for the implementation plan)

**New files:**
- `chezmoi/private_dot_claude/CLAUDE.md` (memory: prose + sentinel block)
- `scripts/gen-tool-memory.sh` (generator; LF, 0755)
- `.claude/hooks/sync-tool-memory.sh` (hook; LF, 0755)
- `makefile/lib/go.sh` (Go toolchain installer; LF, 0755)
- `makefile/lib/lsp.sh` (npm/uv/go LSP installer; LF, 0755)

**Edited files:**
- `makefile/versions.mk` (+ ~11 LSP/Go pins, in a new section)
- `makefile/tools.mk` (rust-analyzer / marksman / taplo `EGET_TOOL`; lua-language-server `TOOL`; `UPDATE_SPECS` lines)
- `makefile/Makefile` (`go-runtime` + `lsp-servers` targets; `provision` dev block; `DOCTOR_ROWS`; `list` text)
- `.claude/settings.json` (wire the new PostToolUse hook)
- `scripts/check-invariants.sh` (drift check + shell-set membership + sentinel set)
- `.claude/hooks/test-hooks.sh` (new assertions)
- `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md` (internal docs)
- `README.html` (+ css/js if needed), `CLAUDE_CHANGELOG.md` (user-facing LSP/Go surface)

## 14. Risks

- **Generator brittleness** vs `tools.mk` syntax drift — mitigated by the drift check + hook tests; fallback to `make tool-manifest` documented.
- **npm global PATH landing** — must verify `--prefix` puts bins in `$(DEST)`; covered by the `lib/lsp.sh` design + `make doctor` check.
- **lua-language-server packaging** — it's a wrapper-dir tarball (not a single binary); confirm `archive.sh`'s `find`-based install picks `bin/lua-language-server` correctly, else use an explicit `src=dst` spec.
- **basedpyright on AlmaLinux 9 Python** — uv-managed isolated env sidesteps the system-Python-version concern.
- **README scope creep** — keep the README change to the LSP/Go tool surface; the memory/hook/generator are internal.
