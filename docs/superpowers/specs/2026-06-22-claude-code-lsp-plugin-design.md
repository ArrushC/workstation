# Wiring the workstation's LSP servers into Claude Code's LSP tool — design

- **Date:** 2026-06-22
- **Status:** Approved (brainstorming) — pending implementation plan
- **Scope:** Claude-internal infra (a chezmoi-tracked local Claude Code plugin), dev_machine only
- **Related:**
  - `chezmoi/private_dot_claude/` (existing global Claude config), `modify_private_settings.json`
  - `makefile/Makefile` `lsp-servers` target + `makefile/lib/lsp.sh` (installs the server binaries)
  - `chezmoi/private_dot_claude/CLAUDE.md` (the machine memory's LSP-first guidance)
  - prior feature: `docs/superpowers/specs/2026-06-21-claude-machine-memory-tooling-design.md`

---

## 1. Goal

Make the machine memory's "**prefer the `LSP` tool over Linux text tools**" guidance *actually true* in Claude Code. Today the LSP servers we provision (`make lsp-servers`) are installed on `$PATH` — usable by external editors — but Claude Code's in-app `LSP` tool returns "No LSP server available for file type" for everything except Lua, because **the `LSP` tool only uses servers registered by an enabled plugin**, and only the `lua-lsp` plugin is enabled.

This feature registers the workstation's installed servers with Claude Code's `LSP` tool, reproducibly, so `goToDefinition` / `findReferences` / `documentSymbol` / `hover` / etc. work for the languages this repo (and the user) actually use.

## 2. Background — the mechanism (proven via POC)

- Claude Code's `LSP` tool is fed **only** by plugins declaring an `lspServers` manifest (`.lsp.json` at plugin root, or inline in `plugin.json`). There is **no settings.json-only** path. (Confirmed against the Claude Code plugin docs.)
- The official `claude-plugins-official` marketplace ships per-language LSP plugins (`clangd-lsp`, `gopls-lsp`, `rust-analyzer-lsp`, `typescript-lsp`, `pyright-lsp`, …) — but **none** for bash, yaml, json, css, html, toml, or markdown, and `pyright-lsp` expects Pyright (we provision **basedpyright**).
- **`claude plugin init` scaffolds a "skills-dir" plugin** at `~/.claude/skills/<name>/` that **auto-loads next session as `<name>@skills-dir` with no marketplace registration and no install command**. We proved (POC) that a skills-dir plugin's `.lsp.json` registers servers with the `LSP` tool: after `/reload-plugins`, `bash-language-server` returned 19 real symbols from a `.sh` file and `marksman` returned symbols from a `.md` file.
- **Skills-dir plugins auto-enable by presence** — the POC plugin appears in no settings file or `installed_plugins.json`, yet loaded and served LSP. So deploying the directory is sufficient to enable it.

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Packaging | **Self-contained** local plugin declaring ALL servers (supersedes the earlier "hybrid" pick) | Skills-dir is purely declarative (deploy files, done); the official plugins would need an imperative `claude plugin install` step (state in `installed_plugins.json`). All binaries already exist, so one plugin is simpler + more reproducible. |
| Diagnostics | **Left at the default (ON)**; the `diagnostics: false` toggle is present only as a **comment** in `.lsp.json` | The diagnostics are genuinely useful — e.g. marksman correctly flags the broken `[[wikilink]]`s in `.claude/memory/*.md` (the links use hyphens but the files use underscores, so they really are broken). Commenting (not setting) keeps default-on and documents the lever for easy future suppression. |
| SKILL.md | **Minimal honest internal-marker** (stretch: drop it if skills-dir loads an LSP-only plugin) | Skills-dir is skill-discovery-based, so a marker is the safe default; a clear description won't spuriously trigger and replaces the scaffold's `TODO`. |
| Install commands | **None** | No `claude plugin install`, no marketplace add. Binaries come from `make lsp-servers`; the plugin is chezmoi-deployed. |
| Enablement | Presence auto-enables; **also** add `workstation-lsp@skills-dir: true` to the enforced `enabledPlugins` in `modify_private_settings.json` | Belt-and-suspenders: explicit + robust against any change to presence-auto-enable behavior. |

## 4. Architecture / components

### 4.1 The chezmoi-tracked plugin

Source tree (chezmoi naming — leading-dot files use the `dot_` prefix):

```
chezmoi/private_dot_claude/skills/workstation-lsp/
├── dot_claude-plugin/plugin.json     → ~/.claude/skills/workstation-lsp/.claude-plugin/plugin.json
├── dot_lsp.json                      → ~/.claude/skills/workstation-lsp/.lsp.json
└── SKILL.md                          → ~/.claude/skills/workstation-lsp/SKILL.md
```

Deploys to `~/.claude/skills/workstation-lsp/` (dev_machine only — inherits the existing `.claude` dev/prod gate in `.chezmoiignore.tmpl`; no new ignore entry).

**`plugin.json`** — manifest: `$schema`, `name: "workstation-lsp"`, `version`, `description`, `author`. Keeps `"skills": ["./"]` only if the SKILL.md marker is retained.

**`.lsp.json`** — the full server table. **Diagnostics are left at the default (on)** — they surface genuine issues (e.g. marksman's broken-wikilink warnings). The file carries a JSONC `//` comment documenting that `"diagnostics": false` can be added to any server to suppress its diagnostic injection. (JSONC `//` comments pass `claude plugin validate --strict`, tested; the runtime loader's tolerance is confirmed during implementation — fallback below.) Commands are bare executables on `$PATH`; subcommands/flags go in `args`:

| key | command | args | extensions → language |
|---|---|---|---|
| bash | `bash-language-server` | `["start"]` | `.sh`,`.bash` → `shellscript` |
| yaml | `yaml-language-server` | `["--stdio"]` | `.yaml`,`.yml` → `yaml` |
| json | `vscode-json-language-server` | `["--stdio"]` | `.json` → `json` |
| css | `vscode-css-language-server` | `["--stdio"]` | `.css` → `css` |
| html | `vscode-html-language-server` | `["--stdio"]` | `.html` → `html` |
| toml | `taplo` | `["lsp","stdio"]` | `.toml` → `toml` |
| markdown | `marksman` | `["server"]` | `.md`,`.markdown` → `markdown` |
| python | `basedpyright-langserver` | `["--stdio"]` | `.py` → `python` |
| c-cpp | `clangd` | `[]` | `.c`,`.h`,`.cpp`,`.hpp`,`.cc`,`.cxx` → `c`/`cpp` |
| go | `gopls` | `[]` | `.go` → `go` |
| rust | `rust-analyzer` | `[]` | `.rs` → `rust` |
| typescript | `typescript-language-server` | `["--stdio"]` | `.ts`,`.tsx`,`.js`,`.jsx` → `typescript`/`javascript` |

The exact `args` for each server are confirmed at implementation time (the bash/markdown pair is already POC-verified; the rest are the servers' standard stdio-mode invocations).

**`SKILL.md`** — minimal frontmatter (`name`, short `description` making clear it's an internal LSP-registration marker, not a user skill) + a one-paragraph body. Stretch goal: if removing `SKILL.md` + the `skills` key still loads the LSP servers (verify with `/reload-plugins`), drop it for zero skill footprint.

### 4.2 Enablement

Add `"workstation-lsp@skills-dir": true` to the **enforced** `enabledPlugins` block in `chezmoi/private_dot_claude/modify_private_settings.json` (the existing merge-template forces this key on every apply). Presence already auto-enables; this is the explicit, declarative belt-and-suspenders.

### 4.3 Binaries

No new installs. All 12 servers' binaries are already provisioned (verified present): `bash-language-server`, `yaml-language-server`, `vscode-json/css/html-language-server`, `taplo`, `marksman`, `basedpyright-langserver` (uv), `clangd` (dnf), `gopls`, `rust-analyzer`, `typescript-language-server` — from `make lsp-servers` / the C/C++ dnf group / eget.

### 4.4 POC conversion

The live POC plugin at `~/.claude/skills/workstation-lsp/` (untracked) is **converted in place**: its files move into the chezmoi source tree (expanded to all 12 servers + `diagnostics: false`), so chezmoi takes ownership and it keeps working — no removal/re-add gap.

## 5. Reproducibility flow

Fresh dev box: `make lsp-servers MODE=dev` (binaries) → `cza` (deploys the plugin dir + the `enabledPlugins` toggle) → next session (or `/reload-plugins`) auto-loads `workstation-lsp@skills-dir` → the `LSP` tool serves all 12 languages. **Zero imperative plugin commands.**

## 6. Error handling

- **Server binary absent** (e.g. a language's server didn't install): that language simply has no LSP; the `LSP` tool returns "No LSP server available" for it — no crash. (`make lsp-servers` is best-effort per-server already.)
- **Diagnostics are on by default** — surfaced into Claude's context after edits (marksman's broken-wikilink warnings, basedpyright type errors, etc.). Intentional; the commented `diagnostics: false` per-server toggle is the escape hatch if one proves too noisy.
- **Cold start:** the first `LSP` call to a server may return "server is starting" (observed); a retry succeeds. Documented, not a defect.
- **Malformed manifest:** caught by `claude plugin validate --strict` (see Testing) before it can break loading.

## 7. Testing / verification

- **`claude plugin validate --strict <plugin dir>`** passes — add it as a check (in `scripts/check-invariants.sh`, soft-skipped if `claude` is absent, like the shfmt/gitleaks soft-skips; or a dedicated `make` target).
- **Manual (post-`/reload-plugins`):** the `LSP` tool returns real results for a `.sh`, `.md`, `.yaml`, `.json`, and `.py` file in the repo. (bash + markdown already POC-verified.)
- **`make lint MODE=prod`** + **`bash .claude/hooks/test-hooks.sh`** stay green (the machine-memory drift check etc. unaffected).
- **`chezmoi diff` / `chezmoi ignored`** confirm the plugin deploys on dev and is ignored on prod.

## 8. Docs to update

- **`chezmoi/private_dot_claude/CLAUDE.md`** (the machine memory): the "Navigate code with the LSP tool first" section can now state the servers are wired into the `LSP` tool (not just installed for editors); the coverage table stands.
- **`CLAUDE.md`** (project): note the `workstation-lsp` skills-dir plugin + that `.lsp.json` registers the servers; add `modify_private_settings.json`'s new `enabledPlugins` entry to the relevant invariant.
- **`docs/claude/invariants.md` + `file-care.md`**: the plugin's purpose, the `diagnostics: false` rationale, the chezmoi `dot_lsp.json`/`dot_claude-plugin/` naming, the "binaries from `make lsp-servers`, registration from this plugin" split.
- **`README.html` + `CLAUDE_CHANGELOG.md`**: user-facing note that Claude Code's `LSP` tool now covers the toolbelt's languages on dev machines (and a CHANGELOG row).
- The memory file is auto-generated only inside its `TOOLS` block; these are prose edits outside it — the drift check is unaffected.

## 9. File-change checklist (for the plan)

**New files:**
- `chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json`
- `chezmoi/private_dot_claude/skills/workstation-lsp/dot_lsp.json`
- `chezmoi/private_dot_claude/skills/workstation-lsp/SKILL.md` (unless the stretch drop succeeds)

**Edited files:**
- `chezmoi/private_dot_claude/modify_private_settings.json` (enforced `enabledPlugins` += `workstation-lsp@skills-dir`)
- `scripts/check-invariants.sh` (soft `claude plugin validate --strict` check)
- `chezmoi/private_dot_claude/CLAUDE.md` (prose), `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `README.html`, `CLAUDE_CHANGELOG.md`

## 10. Out of scope / future

- The official `*-lsp` marketplace plugins (rejected in favor of self-contained).
- Per-server `settings`/`initializationOptions` tuning (e.g. basedpyright type-checking mode) — start with navigation-only defaults; add later if wanted.
- Windows parity (this is Linux dev_machine only; Claude Code LSP config on Windows is out of scope).
- Selectively **disabling** diagnostics for a server that proves too noisy (via the commented `diagnostics: false` toggle) — a deliberate later tweak, not now.
- Fixing the broken `[[wikilink]]`s in `.claude/memory/*.md` that diagnostics now surface (hyphen-vs-underscore filename mismatch) — a separate memory-file cleanup, not this feature.

## 11. Risks

- **`args` correctness per server** — bash/markdown POC-verified; the rest use standard stdio invocations but are confirmed at implementation time by a `/reload-plugins` + `LSP`-tool smoke test.
- **Skills-dir SKILL.md requirement** — if a marker is required, we keep a minimal one (small always-on cost); the stretch drop is verified, not assumed.
- **`chezmoi` dot_-prefix nesting** (`dot_claude-plugin/`) — verify `chezmoi apply` produces `.claude-plugin/plugin.json` (not a literal `dot_claude-plugin`); a quick `chezmoi diff` confirms.
- **Presence auto-enable behavior could change** across Claude Code versions — mitigated by the explicit `enabledPlugins` entry.
- **JSONC `//` comment in `.lsp.json`** — passes `claude plugin validate --strict` (tested), but the *runtime* LSP loader's tolerance is confirmed via a `/reload-plugins` + `LSP`-tool smoke test during implementation. Fallback if the runtime parser is strict JSON: document the toggle in `SKILL.md` (or a JSON-native `"//"` doc key) instead, so a comment never risks breaking server loading.
