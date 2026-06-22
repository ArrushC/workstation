# Claude Code LSP Plugin (`workstation-lsp`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register the workstation's installed language servers with Claude Code's in-app `LSP` tool via a chezmoi-tracked, declarative skills-dir plugin, so "prefer the LSP tool" works for all the languages we provision.

**Architecture:** A single self-contained plugin at `~/.claude/skills/workstation-lsp/` (deployed by chezmoi) whose `.lsp.json` declares all 12 servers. Skills-dir plugins auto-load + auto-enable by presence (proven via POC), so there is **no marketplace registration and no `claude plugin install`** — chezmoi deploying the directory is the entire install. Binaries come from the existing `make lsp-servers`.

**Tech Stack:** Claude Code plugins (`.lsp.json` `lspServers` manifest), chezmoi (`private_dot_claude` tree, `dot_` prefix naming), the `modify_private_settings.json` merge-template, `scripts/check-invariants.sh`, `claude plugin validate`.

## Global Constraints

_Every task's requirements implicitly include this section. Values verbatim from the spec._

- **Self-contained:** ONE plugin declaring all 12 servers. No official `*-lsp` plugins, no `claude plugin install`, no marketplace.
- **chezmoi naming:** source files use the `dot_` prefix for leading-dot targets: `dot_lsp.json` → `.lsp.json`; `dot_claude-plugin/plugin.json` → `.claude-plugin/plugin.json`; `SKILL.md` stays `SKILL.md`. Verify with `chezmoi cat`/`chezmoi managed` (target paths, `dot_` stripped).
- **Dev-only:** the plugin lives under `~/.claude/`, already dev-gated by the `.claude` block in `.chezmoiignore.tmpl`. **Add no new `.chezmoiignore` entry.**
- **Diagnostics ON (default):** do NOT set `diagnostics` on any server. Include a JSONC `//` comment in `.lsp.json` documenting that `"diagnostics": false` can be added per-server to suppress injection. (JSONC `//` passes `claude plugin validate --strict` — tested; runtime acceptance is confirmed in Task 4 with a fallback.)
- **`command` is a bare executable on `$PATH`;** subcommands/flags go in `args`.
- **Enablement:** presence auto-enables; ALSO add `"workstation-lsp@skills-dir": true` to the enforced `enabledPlugins` in `modify_private_settings.json`.
- **No README update needed for the plugin/memory internals**, BUT the user-facing fact "Claude Code's LSP tool now covers the toolbelt's languages on dev machines" IS user-facing → README + a `CLAUDE_CHANGELOG.md` row.
- The POC plugin at `~/.claude/skills/workstation-lsp/` (untracked) is converted in place — the chezmoi source supersedes it on `cza`.

---

## File Structure

**New (chezmoi source):**
- `chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json` — plugin manifest.
- `chezmoi/private_dot_claude/skills/workstation-lsp/dot_lsp.json` — the 12-server `lspServers` manifest.
- `chezmoi/private_dot_claude/skills/workstation-lsp/SKILL.md` — minimal internal-marker skill (skills-dir discovery).

**Modified:**
- `chezmoi/private_dot_claude/modify_private_settings.json` — enforced `enabledPlugins` += `workstation-lsp@skills-dir`.
- `scripts/check-invariants.sh` — soft `claude plugin validate --strict` check.
- `chezmoi/private_dot_claude/CLAUDE.md`, `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `README.html`, `CLAUDE_CHANGELOG.md` — docs.

---

## Task 1: The chezmoi-tracked plugin

**Files:**
- Create: `chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json`
- Create: `chezmoi/private_dot_claude/skills/workstation-lsp/dot_lsp.json`
- Create: `chezmoi/private_dot_claude/skills/workstation-lsp/SKILL.md`

**Interfaces:**
- Produces: the chezmoi source for `~/.claude/skills/workstation-lsp/` — consumed by Task 2 (enablement key `workstation-lsp@skills-dir`), Task 3 (validate check reads these source files), Task 4 (deploy + smoke test).

- [ ] **Step 1: Create the plugin manifest**

`chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json`:
```json
{
  "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "workstation-lsp",
  "version": "0.1.0",
  "description": "Registers the workstation toolbelt's installed language servers with Claude Code's LSP tool (bash, yaml, json, css, html, toml, markdown, python, c/c++, go, rust, typescript). Internal — not a user-invocable skill. Server binaries are provisioned by `make lsp-servers`.",
  "author": {
    "name": "Arrush Chaturvedi"
  },
  "skills": [
    "./"
  ]
}
```

- [ ] **Step 2: Create the LSP manifest** (`dot_lsp.json`)

`chezmoi/private_dot_claude/skills/workstation-lsp/dot_lsp.json`:
```json
{
  // diagnostics default to ON and are left on — these servers surface genuine
  // issues (e.g. marksman flags broken [[wikilinks]] in .claude/memory/*.md).
  // To silence one server's diagnostics, add  "diagnostics": false  to its entry.
  "bash": {
    "command": "bash-language-server",
    "args": ["start"],
    "extensionToLanguage": { ".sh": "shellscript", ".bash": "shellscript" }
  },
  "yaml": {
    "command": "yaml-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": { ".yaml": "yaml", ".yml": "yaml" }
  },
  "json": {
    "command": "vscode-json-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": { ".json": "json", ".jsonc": "jsonc" }
  },
  "css": {
    "command": "vscode-css-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": { ".css": "css", ".scss": "scss", ".less": "less" }
  },
  "html": {
    "command": "vscode-html-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": { ".html": "html" }
  },
  "toml": {
    "command": "taplo",
    "args": ["lsp", "stdio"],
    "extensionToLanguage": { ".toml": "toml" }
  },
  "markdown": {
    "command": "marksman",
    "args": ["server"],
    "extensionToLanguage": { ".md": "markdown", ".markdown": "markdown" }
  },
  "python": {
    "command": "basedpyright-langserver",
    "args": ["--stdio"],
    "extensionToLanguage": { ".py": "python", ".pyi": "python" }
  },
  "c-cpp": {
    "command": "clangd",
    "extensionToLanguage": {
      ".c": "c", ".h": "c",
      ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hh": "cpp"
    }
  },
  "go": {
    "command": "gopls",
    "extensionToLanguage": { ".go": "go" }
  },
  "rust": {
    "command": "rust-analyzer",
    "extensionToLanguage": { ".rs": "rust" }
  },
  "typescript": {
    "command": "typescript-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": {
      ".ts": "typescript", ".tsx": "typescriptreact",
      ".js": "javascript", ".jsx": "javascriptreact",
      ".mjs": "javascript", ".cjs": "javascript"
    }
  }
}
```
(clangd/gopls/rust-analyzer take no args and serve over stdio by default, so `args` is omitted for them.)

- [ ] **Step 3: Create the marker skill** (`SKILL.md`)

`chezmoi/private_dot_claude/skills/workstation-lsp/SKILL.md`:
```markdown
---
name: workstation-lsp
description: Internal marker for the workstation's local LSP-server plugin. It registers installed language servers (bash, yaml, json, css, html, toml, markdown, python, c/c++, go, rust, typescript) with Claude Code's LSP tool via .lsp.json. Not a user-invocable skill — do not invoke it.
---

# workstation-lsp (internal)

This directory is a Claude Code **skills-dir plugin** whose only purpose is to
register the workstation toolbelt's installed language servers with Claude Code's
`LSP` tool (see the sibling `.lsp.json`). It exposes no user-facing skill behavior.

- **Server binaries** are provisioned by `make lsp-servers MODE=dev` (plus clangd
  from the C/C++ dnf group). This plugin only *registers* them; it installs nothing.
- **Diagnostics** are on by default; to silence one server, add `"diagnostics": false`
  to its entry in `.lsp.json`.
- Source of truth is chezmoi: `chezmoi/private_dot_claude/skills/workstation-lsp/`.
```

- [ ] **Step 4: Verify chezmoi naming maps to the right target paths** (no apply)

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
chezmoi managed | grep -E 'skills/workstation-lsp'
chezmoi cat ~/.claude/skills/workstation-lsp/.lsp.json | head -5
chezmoi cat ~/.claude/skills/workstation-lsp/.claude-plugin/plugin.json | head -3
```
Expected: `managed` lists `.claude/skills/workstation-lsp/.lsp.json`, `.claude/skills/workstation-lsp/.claude-plugin/plugin.json`, `.claude/skills/workstation-lsp/SKILL.md` (the `dot_` prefixes stripped). `chezmoi cat` renders the real JSON for each target path (proving the source maps correctly).

- [ ] **Step 5: Verify the reconstructed plugin validates**

Run (reconstruct the target filenames in a temp dir, since the source uses `dot_` prefixes):
```bash
T=$(mktemp -d); mkdir -p "$T/.claude-plugin"
SRC=chezmoi/private_dot_claude/skills/workstation-lsp
cp "$SRC/dot_claude-plugin/plugin.json" "$T/.claude-plugin/plugin.json"
cp "$SRC/dot_lsp.json" "$T/.lsp.json"
cp "$SRC/SKILL.md" "$T/SKILL.md"
claude plugin validate "$T" --strict; echo "exit=$?"
rm -rf "$T"
```
Expected: `✔ Validation passed`, `exit=0`. (If `claude` is absent, skip — but on this dev host it's present.)

- [ ] **Step 6: Lint + commit**

Run: `make -C makefile lint MODE=prod` (must pass — these are new JSON/MD files, not shell, so no LF/shellcheck impact).
```bash
git add chezmoi/private_dot_claude/skills/workstation-lsp/
git commit -m "feat(lsp): chezmoi-tracked workstation-lsp plugin (12 language servers)"
```

---

## Task 2: Enablement via the enforced settings merge

**Files:**
- Modify: `chezmoi/private_dot_claude/modify_private_settings.json` (enforced `enabledPlugins` block)

**Interfaces:**
- Consumes: the plugin name `workstation-lsp@skills-dir` (Task 1).
- Produces: the deployed `~/.claude/settings.json` enables the plugin on every `cza`.

- [ ] **Step 1: Add the plugin to the enforced `enabledPlugins`**

In `chezmoi/private_dot_claude/modify_private_settings.json`, find the enforced block:
```json
    "frontend-design@claude-plugins-official": true
  }
```
Replace with (add a comma + the new line):
```json
    "frontend-design@claude-plugins-official": true,
    "workstation-lsp@skills-dir": true
  }
```

- [ ] **Step 2: Verify the merge-template still renders valid JSON**

Run (render the modify-template against the current live settings and check it parses):
```bash
chezmoi cat ~/.claude/settings.json | python3 -m json.tool >/dev/null && echo "settings.json renders as valid JSON ✓"
chezmoi cat ~/.claude/settings.json | python3 -c 'import json,sys; print("workstation-lsp@skills-dir enabled:", json.load(sys.stdin)["enabledPlugins"].get("workstation-lsp@skills-dir"))'
```
Expected: "valid JSON ✓" and "workstation-lsp@skills-dir enabled: True".

- [ ] **Step 3: Lint + commit**

Run: `make -C makefile lint MODE=prod` (must pass).
```bash
git add chezmoi/private_dot_claude/modify_private_settings.json
git commit -m "feat(lsp): enable workstation-lsp@skills-dir in enforced settings"
```

---

## Task 3: Manifest validate check in `check-invariants.sh`

**Files:**
- Modify: `scripts/check-invariants.sh` (add `check_lsp_plugin` + call it)

**Interfaces:**
- Consumes: the plugin source files (Task 1).
- Produces: a lint check that fails if the plugin manifest is invalid (soft-skips where `claude` is absent, e.g. CI).

- [ ] **Step 1: Add the `check_lsp_plugin` function**

In `scripts/check-invariants.sh`, insert after the `check_tools_block()` function (before `check_chezmoiignore_targets`):
```bash
check_lsp_plugin() {
  hdr "workstation-lsp plugin manifest"
  local src="chezmoi/private_dot_claude/skills/workstation-lsp"
  if [ ! -f "$src/dot_claude-plugin/plugin.json" ] || [ ! -f "$src/dot_lsp.json" ]; then
    bad "missing workstation-lsp plugin source ($src/dot_claude-plugin/plugin.json + dot_lsp.json)"
    return
  fi
  if ! command -v claude >/dev/null 2>&1; then
    note "claude not installed — skipped LSP plugin validate (dev hosts enforce; CI has no claude)"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude-plugin"
  cp "$src/dot_claude-plugin/plugin.json" "$tmp/.claude-plugin/plugin.json"
  cp "$src/dot_lsp.json" "$tmp/.lsp.json"
  [ -f "$src/SKILL.md" ] && cp "$src/SKILL.md" "$tmp/SKILL.md"
  if claude plugin validate "$tmp" --strict >/dev/null 2>&1; then
    ok "workstation-lsp manifest validates (claude plugin validate --strict)"
  else
    bad "workstation-lsp manifest failed claude plugin validate --strict:"
    claude plugin validate "$tmp" --strict 2>&1 | sed 's/^/       /' | head -20
  fi
  rm -rf "$tmp"
}
```

- [ ] **Step 2: Call it in the runner**

Near the bottom of `scripts/check-invariants.sh`, after the `check_tools_block` call, add:
```bash
check_lsp_plugin
```

- [ ] **Step 3: Verify it passes (and that it catches a broken manifest)**

Run:
```bash
make -C makefile lint MODE=prod   # must pass, incl. "workstation-lsp manifest validates"
# negative: break the manifest, confirm the check fails, then restore
python3 -c "import pathlib; p=pathlib.Path('chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json'); p.write_text(p.read_text().replace('\"name\"','\"nmae\"'))"
make -C makefile lint MODE=prod; echo "exit=$?"   # expect a workstation-lsp failure + non-zero
git checkout -- chezmoi/private_dot_claude/skills/workstation-lsp/dot_claude-plugin/plugin.json
make -C makefile lint MODE=prod   # green again
```
Expected: clean → fails on the broken manifest (exit non-zero) → clean after restore.

- [ ] **Step 4: shellcheck/shfmt + commit**

Run: `shellcheck -x -S warning scripts/check-invariants.sh && shfmt -d -i 2 scripts/check-invariants.sh` (clean).
```bash
git add scripts/check-invariants.sh
git commit -m "feat(lint): validate the workstation-lsp plugin manifest (soft-skip without claude)"
```

---

## Task 4: Deploy + runtime LSP smoke test

> **This task needs a `/reload-plugins` (a user slash command) — it is a controller+user step, not a subagent step.** It converts the untracked POC into the chezmoi-managed plugin and proves the `LSP` tool serves the languages at runtime, including that the JSONC `//` comment doesn't break loading.

**Files:** none changed unless the fallback is needed.

- [ ] **Step 1: Deploy the plugin**

Run:
```bash
chezmoi diff ~/.claude/skills/workstation-lsp    # review: POC (3 servers) -> tracked (12 servers + comment)
cza --force                                       # apply (per the repo's apply-hangs gotcha)
cat ~/.claude/skills/workstation-lsp/.lsp.json | head -3   # confirm the // comment + content deployed
```
Expected: `~/.claude/skills/workstation-lsp/.lsp.json` now has all 12 servers + the comment; `.claude-plugin/plugin.json` present (NOT a literal `dot_claude-plugin`).

- [ ] **Step 2: Reload + confirm the servers registered**

Ask the user to run `/reload-plugins`. Expected output shows an increased "plugin LSP servers" count (was 3 with the POC; now reflects the 12 declared, for the languages whose binaries are present).

- [ ] **Step 3: Smoke-test the `LSP` tool across languages**

Using the `LSP` tool (`documentSymbol`), confirm real results (not "No LSP server available") for one file per language family that exists in the repo:
- bash: `makefile/lib/lsp.sh`
- markdown: `docs/claude/invariants.md`
- yaml: `.github/workflows/lint.yml`
- json: `.claude/settings.json`
- python: create a throwaway `/tmp/lsp_probe.py` with `def f(x): return x` if no `.py` exists in-repo.

A first call per server may return "server is starting" — retry once. Expected: each returns symbols.

- [ ] **Step 4: Verify the `//` comment didn't break loading (fallback if it did)**

If Step 3 shows servers failing to load (e.g. "No LSP server available" for ALL languages after reload, or a parse error), the runtime `.lsp.json` parser is strict JSON. Fallback: remove the `//` comment from `dot_lsp.json` and instead document the `diagnostics: false` toggle in `SKILL.md` only; re-apply (`cza --force`), reload, re-test. Commit the fallback as `fix(lsp): document diagnostics toggle in SKILL.md (runtime .lsp.json is strict JSON)`. If Step 3 passed, no action — the comment is fine.

- [ ] **Step 5: Confirm clean tree**

Run: `git status --short` → clean (no stray working-tree changes from the smoke test; the throwaway `.py` is in `/tmp`, not the repo).

---

## Task 5: Documentation

**Files:**
- Modify: `chezmoi/private_dot_claude/CLAUDE.md`, `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `README.html`, `CLAUDE_CHANGELOG.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Update the machine memory's LSP section**

In `chezmoi/private_dot_claude/CLAUDE.md`, in the "Navigate code with the LSP tool first" section, change the line that introduces the coverage table so it states the servers are **wired into Claude Code's `LSP` tool** (via the `workstation-lsp` plugin), not merely installed. Replace:
```
A server must be **installed** and the file's **language detected**. Coverage on
this host (install via `make lsp-servers MODE=dev`):
```
with:
```
These servers are registered with Claude Code's `LSP` tool by the bundled
`workstation-lsp` plugin (`~/.claude/skills/workstation-lsp/`); their binaries
come from `make lsp-servers MODE=dev`. Coverage on this host:
```
(This is prose OUTSIDE the `TOOLS` sentinels — the drift check is unaffected.)

- [ ] **Step 2: Update `CLAUDE.md` (project)** — add to the relevant sections:
  - Near the machine-memory invariant bullet, note: the `workstation-lsp` skills-dir plugin (`chezmoi/private_dot_claude/skills/workstation-lsp/`, dev-only via the `.claude` gate) registers the installed LSP servers with Claude Code's `LSP` tool via `.lsp.json`; enabled by presence + the `workstation-lsp@skills-dir` entry in the enforced `enabledPlugins` of `modify_private_settings.json`. Diagnostics are on by default (commented toggle). Binaries from `make lsp-servers`; the plugin installs nothing.
  - In the chezmoi-naming note, mention the `dot_lsp.json` / `dot_claude-plugin/` convention for this plugin.

- [ ] **Step 3: Update `docs/claude/invariants.md` + `docs/claude/file-care.md`:**
  - invariants.md: the skills-dir auto-load mechanism (declarative, no install), the `enabledPlugins` belt-and-suspenders, the `diagnostics`-on decision, the validate check.
  - file-care.md: the plugin source files (`dot_claude-plugin/plugin.json`, `dot_lsp.json` carries a JSONC `//` comment so it is NOT plain-JSON-parseable by `python -m json.tool`; validate with `claude plugin validate`), and the `SKILL.md` marker.

- [ ] **Step 4: Update `README.html` + `CLAUDE_CHANGELOG.md`:**
  - README.html: a short note (near the LSP card added in the prior feature) that Claude Code's own `LSP` tool now covers the toolbelt's languages on dev machines via the bundled `workstation-lsp` plugin (no extra setup; `cza` deploys it).
  - CLAUDE_CHANGELOG.md: append a row summarizing this change + which README section changed.

- [ ] **Step 5: Lint + commit**

Run: `make -C makefile lint MODE=prod` and `bash .claude/hooks/test-hooks.sh` (both green; the memory edit is outside the TOOLS block so the drift check still passes).
```bash
git add chezmoi/private_dot_claude/CLAUDE.md CLAUDE.md docs/claude/invariants.md docs/claude/file-care.md README.html CLAUDE_CHANGELOG.md
git commit -m "docs(lsp): document the workstation-lsp plugin + LSP-tool coverage"
```

---

## Self-Review

**1. Spec coverage:** §3 decisions → Tasks 1 (self-contained plugin, diagnostics-comment, SKILL marker), 2 (enablement), 4 (no-install deploy). §4 components → Tasks 1+2. §7 testing → Task 3 (validate check) + Task 4 (runtime smoke). §8 docs → Task 5. §11 risks (chezmoi dot_ naming, JSONC comment) → Task 1 Step 4 + Task 4 Step 4. All covered.

**2. Placeholder scan:** No TBD/TODO. Code is complete for the plugin files, the settings edit, and the check function. Doc steps give concrete replacement text for the load-bearing edit (memory file) and concrete bullet content for the rest (prose, no code).

**3. Type/name consistency:** plugin name `workstation-lsp`; enablement key `workstation-lsp@skills-dir` (Tasks 2/4); source paths `chezmoi/private_dot_claude/skills/workstation-lsp/{dot_claude-plugin/plugin.json,dot_lsp.json,SKILL.md}` consistent across Tasks 1/3/4/5; check function `check_lsp_plugin` (defined + called, Task 3); the 12 server keys in `dot_lsp.json` match the spec's table. Consistent.

**Note on execution:** Tasks 1, 2, 3, 5 are subagent-able (file edits + lint + validate, no reload). **Task 4 requires the user to run `/reload-plugins`** and the controller to drive the `LSP` tool — run it inline (not via a subagent).
