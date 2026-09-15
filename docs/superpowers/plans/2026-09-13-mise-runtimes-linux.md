# mise-runtimes (PR 1, Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `node-runtime`, `go-runtime`, the eget `uv` entry and the multi-mechanism `lsp-servers` with one both-scopes, user-level `mise-runtimes` Make target driven by a `versions.mk`-generated mise config that chezmoi also deploys.

**Architecture:** `scripts/gen-mise-config.sh` renders two plain TOML fragments into the chezmoi source (`dot_config/mise/conf.d/`), kept in sync by the existing edit hook, the weekly bumper and a drift check. `makefile/lib/mise.sh` seeds those fragments into `~/.config/mise/conf.d/`, runs `mise install`, prunes, and sweeps the pre-mise artifacts. Shells get the shims dir for non-interactive use (`~/.zshenv`, `~/.bashrc` above its guard) and keep `mise activate` for interactive use.

**Tech Stack:** GNU make, bash (shfmt -i 2, shellcheck warning+), mise 2026.9.x (core node/go, aqua, `go:`/`pipx:` backends, tool `postinstall`), chezmoi, Go-template-free plain TOML.

**Spec:** `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md` — read it first; this plan implements its decisions 1–9 (Linux). PR 2 (Windows, decisions 10–14) gets its own plan.

## Global Constraints

- Every pin lives ONLY in `makefile/versions.mk`; the generated TOML is derived, never hand-edited.
- New pin: `TYPESCRIPT_VERSION := 7.0.2` (was floating). Existing pins consumed: `UV_VERSION 0.12.7`, `NODE_VERSION 26.8.1`, `GO_VERSION 1.27.0`, `GOPLS_VERSION 0.23.0`, `LUA_LS_VERSION 3.19.1`, `BASEDPYRIGHT_VERSION 1.39.10`, `TYPESCRIPT_LS_VERSION 6.0.0`, `BASH_LS_VERSION 5.6.0`, `YAML_LS_VERSION 1.24.0`, `VSCODE_LANGSERVERS_VERSION 4.10.0`.
- `mise-runtimes` is BOTH scopes and USER-LEVEL: the only `$(SUDO)` step is `sweep-legacy` of `$(DEST)`. Never declare `python` in mise.
- Stamp-on-stamp: order-only deps go on stamp FILES (`$(STAMP)/mise-$(MISE_VERSION).done`, `$(STAMP)/mise-runtimes-<cksum>.done`), never phony targets.
- First-party shell: LF, mode 100755 for `makefile/lib/*.sh` + `scripts/*.sh`, `shfmt -i 2` clean, shellcheck warning+ clean. After editing any of them run `file <path>` and `git ls-files --stage <path>`.
- `.chezmoiignore.tmpl` patterns are TARGET paths (`.zshenv`, `.config/mise/conf.d/workstation-dev.toml`).
- Edit any hook → run `bash .claude/hooks/test-hooks.sh`.
- This host needs a sudo password (`sudo -n true` fails), so the real `make dev` migration (Task 8) is run by the user; every other verification is sudo-free (MODE=prod sandbox or `lib/mise.sh` under `HOME`/`MISE_DATA_DIR`/`MISE_CONFIG_DIR` overrides — ALWAYS pass a scratch `HOME` to sandbox runs: `sweep-user` and uv's tool dir are HOME-relative).
- `UV_VERSION` keeps its `bootstrap.ps1` dual-edit (Windows still installs uv directly until PR 2) — do NOT touch the uv block in `check_version_pins` or `EXCLUDE` in this PR.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG
  ```
- Branch: `feat/mise-runtimes` (already holds the spec commit `31c5fa4`).

---

## File map

| File | Responsibility |
|---|---|
| `makefile/versions.mk` | `TYPESCRIPT_VERSION` pin; section comments say "via mise" |
| `scripts/gen-mise-config.sh` (new) | versions.mk → `chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml` |
| `chezmoi/dot_config/mise/conf.d/workstation.toml` (generated) | both-scopes tools (uv) |
| `chezmoi/dot_config/mise/conf.d/workstation-dev.toml` (generated) | dev-only tools (node+npm servers, go, gopls, lua-ls, basedpyright) |
| `.claude/hooks/sync-tool-memory.sh` | also runs the mise generator; `test-hooks.sh` asserts it |
| `scripts/bump-versions.sh` | runs the generator after bumping |
| `scripts/check-invariants.sh` | `check_mise_config` (drift + TOML parse), `check_mise_lib` (offline lib test) |
| `scripts/gen-tool-memory.sh` | `NAMES` for uv + typescript (no longer/never macro tools) |
| `makefile/tools.mk` | uv `EGET_TOOL` line removed; manual `uv` + `typescript` update specs |
| `makefile/lib/mise.sh` (new) | `seed`, `install`, `sweep-legacy`, `sweep-user`, `uninstall` |
| `scripts/test-mise.sh` (new) | offline behavioural test of `lib/mise.sh` with a fake `mise` |
| `makefile/Makefile` | `mise-runtimes` + `clean-mise-runtimes`; `lsp-servers` alias; `python-env`/`claude-statusline` rewired; `node-runtime`/`go-runtime` removed; fanout, doctor rows, `list` |
| `makefile/lib/{node,go,lsp}.sh` | deleted |
| `makefile/lib/doctor.sh` | `mise-runtimes` component + shims wiring row; both-scopes exception list |
| `makefile/lib/python-env.sh`, `scripts/setup-ccstatusline.sh` | hint text → `make mise-runtimes` |
| `chezmoi/dot_zshenv` (new), `chezmoi/dot_bashrc.tmpl`, `chezmoi/dot_zshrc.tmpl` | shims PATH for non-interactive shells; activate comments |
| `chezmoi/.chezmoiignore.tmpl` | `.zshenv` (Windows block), `.config/mise/conf.d/workstation-dev.toml` (prod block) |
| `CLAUDE.md`, `docs/claude/{invariants,file-care,verification}.md`, `README.html`, `CLAUDE_CHANGELOG.md` | docs |

---

### Task 1: TYPESCRIPT pin + the config generator + generated files

**Files:**
- Modify: `makefile/versions.mk:215-232` (LSP section)
- Create: `scripts/gen-mise-config.sh`
- Create (generated): `chezmoi/dot_config/mise/conf.d/workstation.toml`, `chezmoi/dot_config/mise/conf.d/workstation-dev.toml`
- Modify: `chezmoi/.chezmoiignore.tmpl` (prod block, after the `.config/zed` line)

**Interfaces:**
- Produces: `scripts/gen-mise-config.sh` — no args; honours `OUTDIR` (default `<repo>/chezmoi/dot_config/mise/conf.d`); exit 1 if any pin is missing. Later tasks (hook, bumper, drift check) call it exactly like that.
- Produces: the two TOML files with the exact content shown in Step 3.

- [ ] **Step 1: Add the pin and reword the LSP section comment in `makefile/versions.mk`**

Replace the comment block + pins at lines 215-232 with:

```make
# --- (2026-06) Language servers (LSP) + runtimes ------------------------------
# All dev_machine only (navigation is a dev activity; Claude Code is dev-only-
# deployed). Three are single-binary EGET_TOOL static servers (tools.mk,
# both-scope). Everything else here is installed by mise (the `mise-runtimes`
# target, Makefile): scripts/gen-mise-config.sh renders these pins into
# chezmoi/dot_config/mise/conf.d/workstation-dev.toml — node carries the npm
# servers as its postinstall (typescript-language-server needs `typescript` as
# a global sibling), gopls via the go: backend against the pinned Go, lua-
# language-server via mise's registry (aqua), basedpyright via pipx: (uv tool
# install; mise never declares python). clangd is provisioned separately
# (clang-tools-extra, packages.mk) and only VERIFIED by lsp-servers.
# TYPESCRIPT_VERSION is the tsserver typescript-language-server drives (was
# unpinned `latest` before mise).
GO_VERSION                 := 1.27.0
GOPLS_VERSION              := 0.23.0
RUST_ANALYZER_VERSION      := 2026-09-07
MARKSMAN_VERSION           := 2026-02-08
TAPLO_VERSION              := 0.10.0
LUA_LS_VERSION             := 3.19.1
BASEDPYRIGHT_VERSION       := 1.39.10
TYPESCRIPT_LS_VERSION      := 6.0.0
TYPESCRIPT_VERSION         := 7.0.2
BASH_LS_VERSION            := 5.6.0
YAML_LS_VERSION            := 1.24.0
VSCODE_LANGSERVERS_VERSION := 4.10.0
```

Also change line 78 `UV_VERSION         := 0.12.7` to carry a trailing note on the line ABOVE it (keep the pin line itself untouched so `mkval` keeps working):

```make
# uv — consumed by scripts/gen-mise-config.sh (installed via mise-runtimes on
# both scopes, NOT eget). Dual-edits bootstrap.ps1's $PortableTools until PR 2.
UV_VERSION         := 0.12.7
```

- [ ] **Step 2: Write `scripts/gen-mise-config.sh`**

```bash
#!/usr/bin/env bash
# gen-mise-config.sh — render the mise tool declarations from makefile/versions.mk
# into chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml.
#
# The two files are GENERATED (never hand-edited): versions.mk stays the single
# source of every pin, and both Linux (`make mise-runtimes` seeds them, chezmoi
# deploys them) and Windows (chezmoi deploys them, bootstrap.ps1 runs `mise
# install`) consume the same bytes. Plain TOML — not templates — so Make can
# read them before dotfiles exist on a virgin host.
#
# Run by .claude/hooks/sync-tool-memory.sh on makefile edits, by
# scripts/bump-versions.sh after a bump, and by scripts/check-invariants.sh
# (drift check) against a temp OUTDIR.
#
#   OUTDIR=<dir>  override the output directory (default: the chezmoi source).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/makefile/versions.mk"
OUTDIR="${OUTDIR:-$ROOT/chezmoi/dot_config/mise/conf.d}"

mkval() {
  grep -E "^$1[[:space:]]*:=" "$VERSIONS" | head -1 |
    sed -E 's/^[^:=]*:=[[:space:]]*//; s/[[:space:]]*(#.*)?$//'
}
need() {
  local v
  v="$(mkval "$1")"
  if [ -z "$v" ]; then
    printf 'gen-mise-config.sh: %s not found in %s\n' "$1" "$VERSIONS" >&2
    exit 1
  fi
  printf '%s' "$v"
}

UV=$(need UV_VERSION)
NODE=$(need NODE_VERSION)
GO=$(need GO_VERSION)
GOPLS=$(need GOPLS_VERSION)
LUA_LS=$(need LUA_LS_VERSION)
BASEDPYRIGHT=$(need BASEDPYRIGHT_VERSION)
TS_LS=$(need TYPESCRIPT_LS_VERSION)
TS=$(need TYPESCRIPT_VERSION)
BASH_LS=$(need BASH_LS_VERSION)
YAML_LS=$(need YAML_LS_VERSION)
VSCODE_LS=$(need VSCODE_LANGSERVERS_VERSION)

banner() {
  printf '# GENERATED by scripts/gen-mise-config.sh from makefile/versions.mk — DO NOT EDIT.\n'
  printf '# Regenerated by .claude/hooks/sync-tool-memory.sh on makefile edits and by\n'
  printf '# scripts/bump-versions.sh; scripts/check-invariants.sh fails on drift.\n'
}

mkdir -p "$OUTDIR"

{
  banner
  printf '# Both-scopes runtimes (every host). Dev-only tools live in workstation-dev.toml.\n'
  printf '[tools]\n'
  printf 'uv = "%s"\n' "$UV"
} >"$OUTDIR/workstation.toml"

{
  banner
  printf '# dev_machine only — .chezmoiignore.tmpl skips this file on prod_machine.\n'
  printf '[tools]\n'
  printf '# The npm language servers ride node'"'"'s postinstall so typescript-language-server\n'
  printf '# finds typescript as a global sibling (separate npm: trees would break that).\n'
  printf '# A changed postinstall only re-runs when node reinstalls: lib/mise.sh forces it.\n'
  printf 'node = { version = "%s", postinstall = "npm install -g typescript-language-server@%s typescript@%s bash-language-server@%s yaml-language-server@%s vscode-langservers-extracted@%s" }\n' \
    "$NODE" "$TS_LS" "$TS" "$BASH_LS" "$YAML_LS" "$VSCODE_LS"
  printf 'go = "%s"\n' "$GO"
  printf '"go:golang.org/x/tools/gopls" = "%s"\n' "$GOPLS"
  printf 'lua-language-server = "%s"\n' "$LUA_LS"
  printf '"pipx:basedpyright" = "%s"\n' "$BASEDPYRIGHT"
} >"$OUTDIR/workstation-dev.toml"

printf 'gen-mise-config.sh: wrote %s/{workstation,workstation-dev}.toml\n' "$OUTDIR"
```

Then: `chmod 0755 scripts/gen-mise-config.sh`.

- [ ] **Step 3: Run the generator into a scratch dir and verify the exact content**

Run:
```bash
S=$(mktemp -d) && OUTDIR="$S" scripts/gen-mise-config.sh && cat "$S/workstation.toml" && echo ---- && cat "$S/workstation-dev.toml"
```
Expected `workstation.toml` (after the 3 banner lines):
```toml
# Both-scopes runtimes (every host). Dev-only tools live in workstation-dev.toml.
[tools]
uv = "0.12.7"
```
Expected `workstation-dev.toml` (after the 3 banner lines):
```toml
# dev_machine only — .chezmoiignore.tmpl skips this file on prod_machine.
[tools]
# The npm language servers ride node's postinstall so typescript-language-server
# finds typescript as a global sibling (separate npm: trees would break that).
# A changed postinstall only re-runs when node reinstalls: lib/mise.sh forces it.
node = { version = "26.8.1", postinstall = "npm install -g typescript-language-server@6.0.0 typescript@7.0.2 bash-language-server@5.6.0 yaml-language-server@1.24.0 vscode-langservers-extracted@4.10.0" }
go = "1.27.0"
"go:golang.org/x/tools/gopls" = "0.23.0"
lua-language-server = "3.19.1"
"pipx:basedpyright" = "1.39.10"
```
Also verify determinism and the missing-pin path:
```bash
OUTDIR="$S" scripts/gen-mise-config.sh >/dev/null && OUTDIR="$S/2" scripts/gen-mise-config.sh >/dev/null && diff -r "$S/workstation.toml" "$S/2/workstation.toml" && echo deterministic
V=$(mktemp) && grep -v TYPESCRIPT_VERSION makefile/versions.mk > "$V" && ( cd "$(dirname "$V")" && sed "s#^VERSIONS=.*#VERSIONS=$V#" "$OLDPWD/scripts/gen-mise-config.sh" > gm.sh && OUTDIR="$S/3" bash gm.sh; echo "exit=$?" )
```
Expected: `deterministic`, then `gen-mise-config.sh: TYPESCRIPT_VERSION not found in …` and `exit=1`.

- [ ] **Step 4: Generate the real files and gate the dev one on prod**

Run `scripts/gen-mise-config.sh` (no OUTDIR). Then in `chezmoi/.chezmoiignore.tmpl`, inside the `{{ if and (hasKey . "group") (ne .group "dev_machine") }}` block, after the `.config/zed` line add:

```
# mise's dev-only tool set (node/go/gopls/LSP servers) — generated from
# versions.mk by scripts/gen-mise-config.sh; prod hosts get only the
# both-scopes .config/mise/conf.d/workstation.toml (uv).
.config/mise/conf.d/workstation-dev.toml
```

Verify: `chezmoi execute-template --init --promptString name=x --promptString email=x < chezmoi/.chezmoiignore.tmpl 2>/dev/null | grep -c workstation-dev` — if the local chezmoi config is a dev_machine that prints `0` (block not rendered) — fine; the real assertion is `scripts/check-invariants.sh` (target-path check) staying green in Step 5.

- [ ] **Step 5: Lint and commit**

Run: `file scripts/gen-mise-config.sh` (no CRLF), `git add -A && git ls-files --stage scripts/gen-mise-config.sh` (100755), `scripts/check-invariants.sh` — expected: `✗ … TYPESCRIPT_VERSION` under "every versions.mk pin is reachable by check-updates" is the ONLY failure (Task 2 adds the spec); everything else green.

```bash
git add makefile/versions.mk scripts/gen-mise-config.sh chezmoi/dot_config/mise chezmoi/.chezmoiignore.tmpl
git commit -m "feat(mise): generate the mise conf.d tool declarations from versions.mk

scripts/gen-mise-config.sh renders workstation.toml (both scopes: uv) and
workstation-dev.toml (node + npm LSP servers via postinstall, go, gopls,
lua-language-server, basedpyright) into the chezmoi source. New pin
TYPESCRIPT_VERSION (was floating). Dev file ignored on prod (target path).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 2: Keep the generated files in sync (hook, bumper, drift check, tool memory, update specs)

**Files:**
- Modify: `.claude/hooks/sync-tool-memory.sh:44-62`
- Modify: `.claude/hooks/test-hooks.sh:120-141`
- Modify: `scripts/bump-versions.sh:122-132`
- Modify: `scripts/check-invariants.sh` (new function after `check_tools_block`, ~line 308; call list ~line 806)
- Modify: `scripts/gen-tool-memory.sh:36-52` (NAMES)
- Modify: `makefile/tools.mk:564-601` (update specs)

**Interfaces:**
- Consumes: `scripts/gen-mise-config.sh` with `OUTDIR` (Task 1).
- Produces: `check_mise_config` in `check-invariants.sh`; `UPDATE_SPECS` entries named `typescript` (→ `TYPESCRIPT_VERSION`). The manual `uv` spec is added in Task 4 together with the removal of the eget line (avoids a duplicate spec in between).

- [ ] **Step 1: Extend the hook test first (it must fail)**

In `.claude/hooks/test-hooks.sh`, inside the `== sync-tool-memory (R5) ==` block, after the line `ok "block regenerated (stale gone)" …` add:

```bash
mkdir -p "$ST/conf.d"
printf 'stale\n' >"$ST/conf.d/workstation.toml"
OUT="$(printf '%s' "$(j --arg f "$ROOT/makefile/versions.mk" '{tool_name:"Edit",tool_input:{file_path:$f}}')" | MEMFILE="$ST/CLAUDE.md" OUTDIR="$ST/conf.d" bash "$RH/sync-tool-memory.sh" 2>/dev/null)"
ok "versions.mk -> mise conf.d nudge" has 'conf.d'
ok "mise conf.d regenerated (stale gone)" bash -c 'grep -q "^uv = " "'"$ST"'/conf.d/workstation.toml" && grep -q "^node = " "'"$ST"'/conf.d/workstation-dev.toml"'
```

And in the worktree sub-test, change the `cp "$ROOT/scripts/gen-tool-memory.sh" "$WT/scripts/"` line to also copy the mise generator, and add an assertion after `ok "worktree's own memory regenerated" …`:

```bash
cp "$ROOT/scripts/gen-tool-memory.sh" "$ROOT/scripts/gen-mise-config.sh" "$WT/scripts/"
```
```bash
ok "worktree's own mise conf.d generated" test -f "$WT/chezmoi/dot_config/mise/conf.d/workstation-dev.toml"
```

Run: `bash .claude/hooks/test-hooks.sh 2>&1 | tail -15` — expected: the three new assertions FAIL, everything else passes.

- [ ] **Step 2: Make the hook run both generators**

In `.claude/hooks/sync-tool-memory.sh` replace the block from `gen=""` through the `printf` fallback (lines 44-62) with:

```bash
# Resolve the generators from the EDITED FILE's checkout (walk up from the
# file), so an edit inside a git worktree regenerates THAT worktree's files.
# CLAUDE_PROJECT_DIR is only a fallback: it points at the main checkout, and
# preferring it used to silently regenerate the WRONG copy (a content no-op)
# while claiming success for the worktree edit.
scripts=""
d="$(dirname "$norm")"
while [ "$d" != "/" ] && [ -n "$d" ]; do
  if [ -x "$d/scripts/gen-tool-memory.sh" ]; then
    scripts="$d/scripts"
    break
  fi
  d="$(dirname "$d")"
done
if [ -z "$scripts" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh" ]; then
  scripts="$CLAUDE_PROJECT_DIR/scripts"
fi
[ -n "$scripts" ] || exit 0

"$scripts/gen-tool-memory.sh" >/dev/null 2>&1 || exit 0
# Second generated artifact: the mise conf.d tool declarations (OUTDIR honoured
# for the hook test). Missing generator (older checkout) → skip, never fail.
if [ -x "$scripts/gen-mise-config.sh" ]; then
  "$scripts/gen-mise-config.sh" >/dev/null 2>&1 || exit 0
fi

msg="Regenerated from your makefile edit: the TOOLS block in chezmoi/private_dot_claude/CLAUDE.md and the mise tool declarations in chezmoi/dot_config/mise/conf.d/ — commit both with this change and run \`cza\` to deploy them (~/.claude/CLAUDE.md, ~/.config/mise/conf.d/)."

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"suppressOutput":true}\n' "$msg"
fi
exit 0
```

Run: `bash .claude/hooks/test-hooks.sh 2>&1 | tail -5` — expected: all pass (the existing `has 'cza'` assertions still hold — the message keeps the word `cza`).

- [ ] **Step 3: Bumper regenerates the config too**

In `scripts/bump-versions.sh` replace lines 122-132 (the comment + `if [ -n "$bumped" ]` block) with:

```bash
# Keep the two GENERATED artifacts in sync with the pins we just bumped: the
# machine-memory TOOLS block (chezmoi/private_dot_claude/CLAUDE.md) and the mise
# conf.d tool declarations (chezmoi/dot_config/mise/conf.d/). This script runs
# in CI (and locally) where the Claude Code sync-tool-memory.sh hook never
# fires, so regenerate here — otherwise the bumped versions.mk and the
# generated files drift, and check-invariants.sh ("TOOLS block in sync" /
# "mise conf.d in sync") fails on merge.
if [ -n "$bumped" ]; then
  scripts/gen-tool-memory.sh >/dev/null
  scripts/gen-mise-config.sh >/dev/null
fi
```

Also update the comment at line 35 (`… and lib/lsp.sh installs …`): replace `lib/lsp.sh installs` with `mise's go: backend builds`.

- [ ] **Step 4: Drift + parse check in `check-invariants.sh`**

Add after `check_tools_block()` (before `check_lsp_plugin()`):

```bash
check_mise_config() {
  hdr "mise conf.d (generated from versions.mk) in sync + parseable"
  local dir="chezmoi/dot_config/mise/conf.d" tmp f py
  for f in workstation.toml workstation-dev.toml; do
    if [ ! -f "$dir/$f" ]; then
      bad "missing: $dir/$f — run: scripts/gen-mise-config.sh"
      return
    fi
  done
  tmp="$(mktemp -d)"
  if OUTDIR="$tmp" scripts/gen-mise-config.sh >/dev/null 2>&1; then
    if diff -q "$dir/workstation.toml" "$tmp/workstation.toml" >/dev/null &&
      diff -q "$dir/workstation-dev.toml" "$tmp/workstation-dev.toml" >/dev/null; then
      ok "conf.d matches gen-mise-config.sh output"
    else
      bad "conf.d stale — run: scripts/gen-mise-config.sh"
      diff -r "$dir" "$tmp" | sed 's/^/       /' | head -30
    fi
  else
    bad "gen-mise-config.sh failed against a temp OUTDIR"
  fi
  rm -rf "$tmp"
  # TOML parse: EL9's python3 is 3.9 (no tomllib); prefer the python-env wpy
  # (3.14) when present, soft-skip otherwise (CI's python3 is 3.11+).
  py=""
  for f in wpy python3; do
    if command -v "$f" >/dev/null 2>&1 && "$f" -c 'import tomllib' 2>/dev/null; then
      py="$f"
      break
    fi
  done
  if [ -z "$py" ]; then
    note "no python with tomllib — TOML parse check skipped locally (CI enforces)"
    return
  fi
  if "$py" - "$dir/workstation.toml" "$dir/workstation-dev.toml" <<'PY' 2>/dev/null
import sys, tomllib
for p in sys.argv[1:]:
    with open(p, "rb") as fh:
        d = tomllib.load(fh)
    if not d.get("tools"):
        raise SystemExit(f"{p}: no [tools]")
PY
  then
    ok "both files parse (tomllib) and declare [tools]"
  else
    bad "conf.d TOML parse failed (tomllib) — regenerate: scripts/gen-mise-config.sh"
  fi
}
```

Add `check_mise_config` to the call list right after `check_tools_block`.

- [ ] **Step 5: Tool memory names + typescript update spec**

In `scripts/gen-tool-memory.sh`, after `NAMES[EGET_VERSION]="eget"` add:

```bash
NAMES[UV_VERSION]="uv"                 # installed via mise-runtimes (not a tools.mk macro)
NAMES[TYPESCRIPT_VERSION]="typescript" # tsserver behind typescript-language-server (mise node postinstall)
```

In `makefile/tools.mk`, in the "Dev-only bespoke targets" block, change the header comment's first line `# Dev-only bespoke targets (go-runtime, lsp-servers). These had NO spec at all` to `# Dev-only mise-managed runtimes + servers (mise-runtimes). These had NO spec at all`, and after the `typescript-ls` line add:

```make
UPDATE_SPECS += typescript|$(TYPESCRIPT_VERSION)|microsoft/TypeScript|v$(TYPESCRIPT_VERSION)
```

Run `scripts/gen-tool-memory.sh` (the hook may already have done it) and check `git diff chezmoi/private_dot_claude/CLAUDE.md` shows a `- \`typescript\` 7.0.2` line under the LSP section.

- [ ] **Step 6: Verify and commit**

Run: `scripts/check-invariants.sh` — expected all green (including `mise conf.d … in sync`, `both files parse`, `all N pins covered`). `bash .claude/hooks/test-hooks.sh` — all pass.

```bash
git add .claude/hooks/sync-tool-memory.sh .claude/hooks/test-hooks.sh scripts/bump-versions.sh scripts/check-invariants.sh scripts/gen-tool-memory.sh makefile/tools.mk chezmoi/private_dot_claude/CLAUDE.md
git commit -m "feat(mise): keep the generated conf.d in sync (hook, bumper, drift check)

sync-tool-memory.sh runs gen-mise-config.sh next to gen-tool-memory.sh,
bump-versions.sh regenerates after a bump, check-invariants gains
check_mise_config (regenerate-and-diff + tomllib parse), typescript joins
UPDATE_SPECS and the tool memory.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 3: `makefile/lib/mise.sh` with an offline behavioural test

**Files:**
- Create: `scripts/test-mise.sh`
- Create: `makefile/lib/mise.sh`
- Modify: `scripts/check-invariants.sh` (new `check_mise_lib` after `check_zellij_plugin_installer`; call list)

**Interfaces:**
- Produces: `lib/mise.sh <subcommand>`:
  - `seed <dev|prod> <src-dir>` → writes `${MISE_CONFIG_DIR:-$HOME/.config/mise}/conf.d/workstation.toml` (+ `workstation-dev.toml` on dev; removes it on prod).
  - `install` → `mise install --yes`; `mise install --yes --force node` when node was installed BEFORE and is declared; `mise prune --yes`.
  - `sweep-legacy <dest>` → removes the pre-mise entries under `<dest>` (list below); `<dest>/../lib/node_modules` only when a `<dest>/_node-*` tree existed.
  - `sweep-user` → `mise x -- uv tool uninstall basedpyright` when the old user-site tool exists; removes `~/.local/bin/basedpyright{,-langserver}`; removes `$STAMP/{node,go,uv,lsp-servers}-*.done`.
  - `uninstall` → `mise uninstall --all <tool>` for every key in the seeded conf.d files.
  - Env: `MISE_CONFIG_DIR` (seed/uninstall), `STAMP` (sweep-user; default `~/.local/share/workstation-install`), `HOME`.

- [ ] **Step 1: Write the failing test `scripts/test-mise.sh`**

```bash
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

# Fake mise: logs argv, answers `ls --json node` from $FAKE_NODE_INSTALLED.
cat >"$scratch/bin/mise" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
if [ "$1" = ls ] && [ "${*: -1}" = node ]; then
  if [ "${FAKE_NODE_INSTALLED:-0}" = 1 ]; then echo '[{"version":"26.8.1","installed":true}]'; else echo '[]'; fi
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

# 2. install: fresh host → no --force; node already present → --force node; prune always
: >"$FAKE_LOG"
FAKE_NODE_INSTALLED=0 "$lib" install >/dev/null
grep -qx 'install --yes' "$FAKE_LOG" || fail "install: mise install --yes not issued"
! grep -q -- '--force node' "$FAKE_LOG" || fail "install: --force node issued on a fresh host"
grep -qx 'prune --yes' "$FAKE_LOG" || fail "install: mise prune --yes not issued"
: >"$FAKE_LOG"
FAKE_NODE_INSTALLED=1 "$lib" install >/dev/null
grep -qx 'install --yes --force node' "$FAKE_LOG" || fail "install: --force node NOT issued when node was already installed"

# 3. sweep-legacy: the pre-mise /usr/local set goes, unrelated files stay,
#    lib/node_modules only with a _node-* tree as evidence
dest="$scratch/usr/local/bin"
mkdir -p "$dest/_node-v26.8.1/bin" "$dest/_go-1.27.0" "$dest/_lua-language-server-3.19.1" "$scratch/usr/local/lib/node_modules/typescript"
for f in node npm npx corepack go gofmt uv uvx gopls lua-language-server typescript-language-server bash-language-server yaml-language-server vscode-json-language-server vscode-css-language-server vscode-html-language-server vscode-eslint-language-server vscode-markdown-language-server tsc tsserver; do
  ln -s "/nowhere/$f" "$dest/$f"
done
: >"$dest/rg" # unrelated tool must survive
"$lib" sweep-legacy "$dest" >/dev/null
for f in node npm npx corepack go gofmt uv uvx gopls lua-language-server typescript-language-server tsc tsserver; do
  [ ! -e "$dest/$f" ] && [ ! -L "$dest/$f" ] || fail "sweep-legacy: $f still present"
done
[ ! -e "$dest/_node-v26.8.1" ] || fail "sweep-legacy: _node-* tree still present"
[ ! -e "$dest/_go-1.27.0" ] || fail "sweep-legacy: _go-* tree still present"
[ ! -e "$dest/_lua-language-server-3.19.1" ] || fail "sweep-legacy: _lua-language-server-* tree still present"
[ ! -e "$scratch/usr/local/lib/node_modules" ] || fail "sweep-legacy: lib/node_modules still present"
[ -e "$dest/rg" ] || fail "sweep-legacy: unrelated rg removed"
# prod shape: no _node-* evidence → lib/node_modules is left alone
pdest="$scratch/home/.local/bin"
mkdir -p "$pdest" "$scratch/home/.local/lib/node_modules/keep"
: >"$pdest/uv"
"$lib" sweep-legacy "$pdest" >/dev/null
[ ! -e "$pdest/uv" ] || fail "sweep-legacy(prod): uv still present"
[ -d "$scratch/home/.local/lib/node_modules/keep" ] || fail "sweep-legacy(prod): user's lib/node_modules removed without _node-* evidence"
"$lib" sweep-legacy "$dest" >/dev/null || fail "sweep-legacy: second run (nothing to do) must succeed"

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
```

`chmod 0755 scripts/test-mise.sh`. Run: `bash scripts/test-mise.sh` — expected: fails immediately (`…/makefile/lib/mise.sh: No such file or directory`).

- [ ] **Step 2: Write `makefile/lib/mise.sh`**

```bash
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
#   install                    `mise install`; force-reinstall node when it was
#                              already present so a changed npm postinstall
#                              re-runs; prune versions no config references
#   sweep-legacy <dest>        remove the pre-mise artifacts under <dest>
#                              (run under $(SUDO) on dev: /usr/local/bin)
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

node_installed() {
  mise ls --json node 2>/dev/null | grep -q '"version"'
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
  if node_installed; then had_node=true; fi
  mise install --yes
  # postinstall (the npm servers) only runs when node itself installs. On a
  # stale stamp with node already present the pins may have moved without
  # node's version moving — force the reinstall so the hook re-runs.
  if $had_node && node_installed; then
    printf '  ↪ node was already installed — forcing a reinstall so its npm postinstall re-runs\n'
    mise install --yes --force node
  fi
  # Drop versions no config references (the old _node-*/_go-* tree sweep).
  mise prune --yes
  ;;
sweep-legacy)
  dest="${1:?mise.sh sweep-legacy: dest required}"
  removed=0
  had_node_tree=false
  for d in "$dest"/_node-*; do
    if [ -e "$d" ]; then had_node_tree=true; fi
  done
  for f in node npm npx corepack go gofmt uv uvx gopls lua-language-server \
    typescript-language-server bash-language-server yaml-language-server \
    vscode-json-language-server vscode-css-language-server \
    vscode-html-language-server vscode-eslint-language-server \
    vscode-markdown-language-server tsc tsserver; do
    if [ -e "$dest/$f" ] || [ -L "$dest/$f" ]; then
      rm -f "$dest/$f"
      removed=$((removed + 1))
    fi
  done
  for d in "$dest"/_node-* "$dest"/_go-* "$dest"/_lua-language-server-*; do
    [ -e "$d" ] || continue
    rm -rf "$d"
    removed=$((removed + 1))
  done
  # The npm -g --prefix tree (lib/node_modules next to bin/) is only ours when
  # a _node-* tree proved this repo installed node here — never touch a user's
  # own ~/.local/lib/node_modules on prod.
  if $had_node_tree && [ -d "$(dirname "$dest")/lib/node_modules" ]; then
    rm -rf "$(dirname "$dest")/lib/node_modules"
    removed=$((removed + 1))
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
```

`chmod 0755 makefile/lib/mise.sh`.

- [ ] **Step 3: Run the test until it passes**

Run: `bash scripts/test-mise.sh` — expected: `PASS: lib/mise.sh seed/install/sweep-legacy/sweep-user/uninstall behave (offline, fake mise)`. Then `shellcheck -x -S warning makefile/lib/mise.sh scripts/test-mise.sh && shfmt -d -i 2 makefile/lib/mise.sh scripts/test-mise.sh && echo clean`.

- [ ] **Step 4: Wire the test into the invariant checker**

In `scripts/check-invariants.sh` add after `check_zellij_plugin_installer()`:

```bash
check_mise_lib() {
  hdr "mise runtimes lib (lib/mise.sh seed / install / sweeps / uninstall)"
  local out
  # Offline behavioural test with a fake `mise` on PATH and a scratch HOME.
  if out=$(bash scripts/test-mise.sh 2>&1); then
    ok "${out#PASS: }"
  else
    bad "scripts/test-mise.sh failed:"
    printf '%s\n' "$out" | sed 's/^/       /' | head -10
  fi
}
```

Call it right after `check_zellij_plugin_installer` in the main list. Run `scripts/check-invariants.sh` — all green (the LF+0755 check now covers the two new scripts automatically).

- [ ] **Step 5: Commit**

```bash
git add makefile/lib/mise.sh scripts/test-mise.sh scripts/check-invariants.sh
git commit -m "feat(mise): lib/mise.sh — seed, install, legacy sweeps, uninstall (+ offline test)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 4: Rewire the Makefile onto `mise-runtimes`

**Files:**
- Modify: `makefile/Makefile` (blocks at 224-262, 262-306, 364-385, 425-475, 764-771, 803-816, 901)
- Modify: `makefile/tools.mk:170-180` (uv block), `:564` (uv spec)
- Delete: `makefile/lib/node.sh`, `makefile/lib/go.sh`, `makefile/lib/lsp.sh`
- Modify: `makefile/lib/python-env.sh:41-44`, `scripts/setup-ccstatusline.sh:33-37,48-53`
- Modify (comments only): `makefile/Makefile:270,316`, `makefile/packages.mk:19`, `makefile/lib/pwndbg.sh:21`, `scripts/check-invariants.sh:779-796`, `docs/claude/file-care.md:48-50` (delete the three entries — full rewrite lands in Task 7)

**Interfaces:**
- Consumes: `lib/mise.sh` subcommands (Task 3); the generated conf.d (Task 1).
- Produces: Make variables `MISE_CONF_SRC`, `MISE_CONF_FILES`, `MISE_RUNTIMES_STAMP`, `MISE_SHIMS`; targets `mise-runtimes`, `clean-mise-runtimes`, `lsp-servers` (alias); `DOCTOR_ROWS` row `bespoke|mise-runtimes|$(MISE_RUNTIMES_STAMP)` (Task 5 consumes).

- [ ] **Step 1: Remove `node-runtime` and `go-runtime`, add `mise-runtimes`**

Replace lines 224-262 of `makefile/Makefile` (from the `# ----` line above `# node-runtime — …` through the `clean-go-runtime:` recipe's last line `@$(SUDO) rm -rf $(DEST)/_go-*`) with:

```make
# -----------------------------------------------------------------------------
# mise-runtimes — node, Go, uv and the LSP servers via mise. BOTH scopes and
# USER-LEVEL: mise installs under ~/.local/share/mise; the one privileged step
# is the legacy sweep of $(DEST). What gets installed is declared in
# chezmoi/dot_config/mise/conf.d/workstation.toml (both scopes: uv) +
# workstation-dev.toml (node with the npm servers as its postinstall, go,
# gopls, lua-language-server, basedpyright) — GENERATED from versions.mk by
# scripts/gen-mise-config.sh (never hand-edited; check-invariants asserts no
# drift). lib/mise.sh seeds the right file(s) into ~/.config/mise/conf.d/ (the
# fanout runs before the dotfiles phase; chezmoi later deploys identical
# bytes), runs `mise install`, force-reinstalls node when the stamp is stale so
# a changed postinstall re-runs, prunes superseded versions, then sweeps the
# pre-mise /usr/local artifacts ($(SUDO)) and the old user-site basedpyright.
# Stamp bakes a cksum of the consumed config file(s): any pin change re-fires
# it. Order-only dep on mise's eget stamp FILE (stamp-on-stamp invariant).
# Interactive shells see the tools via `mise activate`; non-interactive ones
# (this Makefile's own recipes, ssh, IDE spawns) via the shims dir below.
# -----------------------------------------------------------------------------
MISE_CONF_SRC   := $(REPO_ROOT)/chezmoi/dot_config/mise/conf.d
MISE_CONF_FILES := $(MISE_CONF_SRC)/workstation.toml
ifeq ($(MODE),dev)
MISE_CONF_FILES += $(MISE_CONF_SRC)/workstation-dev.toml
endif
MISE_RUNTIMES_STAMP := $(shell cat $(MISE_CONF_FILES) | cksum | cut -d' ' -f1)
# Recipes that need a mise-managed tool before any shell has activated mise
# (python-env's uv, claude-statusline's npx) prepend this. MISE_DATA_DIR is
# honoured so sandbox runs never touch the real install.
MISE_SHIMS := $(or $(MISE_DATA_DIR),$(HOME)/.local/share/mise)/shims
.PHONY: mise-runtimes clean-mise-runtimes
mise-runtimes: $(STAMP)/mise-runtimes-$(MISE_RUNTIMES_STAMP).done
$(STAMP)/mise-runtimes-$(MISE_RUNTIMES_STAMP).done: | $(STAMP)/mise-$(MISE_VERSION).done
	@printf '==> mise-runtimes (%s)\n' "$(MODE)"
	@$(LIB)/mise.sh seed $(MODE) $(MISE_CONF_SRC)
	# $(DEST) first so `mise` resolves over non-interactive ssh on prod (~/.local/bin is off PATH there).
	@PATH="$(DEST):$$PATH" $(LIB)/mise.sh install
	@$(SUDO) $(LIB)/mise.sh sweep-legacy $(DEST)
	@PATH="$(DEST):$$PATH" $(LIB)/mise.sh sweep-user
	@mkdir -p $(@D) && touch $@
clean-mise-runtimes:
	@rm -f $(STAMP)/mise-runtimes-*.done
	@PATH="$(DEST):$$PATH" $(LIB)/mise.sh uninstall
```

Edit the two comment mentions: line ~270 (nerd-fonts block) `bespoke targets (node-runtime, claude-cli) use $(SUDO)` → `bespoke targets (pwndbg, devtoys-cli) use $(SUDO)`; line ~316 (pwndbg block) `like node-runtime` → `like devtoys-cli`.

- [ ] **Step 2: `claude-statusline` depends on `mise-runtimes` and prefixes the shims**

Replace the `claude-statusline` comment lines `#   - Depends on node-runtime (also dev-only) so the npx the script` / `#     invokes is the chezmoi-managed Linux-native one, not a Windows` / `#     passthrough that crashes on WSL working dirs.` with:

```make
#   - Depends on mise-runtimes (node is mise-managed) and prepends the mise
#     shims dir, so the npx the script invokes is the Linux-native pinned one
#     even from bootstrap.sh's tail (no shell has activated mise yet) — never
#     a Windows passthrough that crashes on WSL working dirs.
```

and the target:

```make
.PHONY: claude-statusline
ifeq ($(MODE),dev)
claude-statusline: mise-runtimes
endif
claude-statusline:
ifeq ($(MODE),dev)
	@PATH="$(MISE_SHIMS):$$PATH" CCSTATUSLINE_VERSION=$(CCSTATUSLINE_VERSION) ../scripts/setup-ccstatusline.sh
else
	@echo "claude-statusline is a dev_machine target — skipping (MODE=$(MODE))"
endif
```

- [ ] **Step 3: `python-env` re-points at the mise-runtimes stamp**

In the `python-env` block: change the comment sentence `Order-only\n# dep on uv's stamp FILE (never the phony — EGET_TOOL stamp-on-stamp\n# invariant).` to `Order-only\n# dep on the mise-runtimes stamp FILE — uv is mise-managed (never the phony;\n# stamp-on-stamp invariant).` and the rule to:

```make
$(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done: | $(STAMP)/mise-runtimes-$(MISE_RUNTIMES_STAMP).done
	@printf '==> python-env %s\n' "$(PYTHON_VERSION)"
	# uv lives behind mise: the shims dir first (no shell has activated mise inside make); DEST next for prod's off-PATH ~/.local/bin over ssh.
	@PATH="$(MISE_SHIMS):$(DEST):$$PATH" $(LIB)/python-env.sh $(PYTHON_VERSION)
	@mkdir -p $(@D) && touch $@
```

- [ ] **Step 4: `lsp-servers` becomes the thin alias**

Replace the whole `lsp-servers` block (comment at `# lsp-servers — install/verify the whole language-server stack` through the end of `clean-lsp-servers:`'s recipe, i.e. lines 425-475 — `LSP_PINS`, `LSP_STAMP`, both `ifeq` arms and `clean-lsp-servers`) with:

```make
# -----------------------------------------------------------------------------
# lsp-servers — dev-only alias over the whole language-server stack: the three
# both-scopes eget servers + mise-runtimes (gopls / lua-language-server /
# basedpyright / the npm servers, declared in workstation-dev.toml) + a clangd
# presence check (clangd comes from clang-tools-extra via dnf — verified only,
# a warning never aborts the provision). Kept so `make lsp-servers MODE=dev`
# (README) still means "the whole stack"; there is no stamp of its own.
# -----------------------------------------------------------------------------
.PHONY: lsp-servers
ifeq ($(MODE),dev)
lsp-servers: rust-analyzer marksman taplo mise-runtimes
	@if command -v clangd >/dev/null 2>&1; then \
	  printf '  ✓ clangd present: %s\n' "$$(command -v clangd)"; \
	else \
	  printf '  ! clangd not found — install clang-tools-extra (packages-optional; needs EPEL/CRB on EL9)\n' >&2; \
	fi
else
lsp-servers:
	@echo "lsp-servers is a dev_machine target — skipping (MODE=$(MODE))"
endif
```

Also fix the `lsp-servers` mention in the `go-gopls` invariant comment in `scripts/check-invariants.sh:779-781,796`: `lib/lsp.sh builds\n  # it with `go install` using the PINNED Go. Mismatch is not loud: lsp.sh ends\n  # that line with …` → `mise's go: backend builds\n  # it with `go install` using the PINNED Go (mise-runtimes). A mismatch fails\n  # that one tool; the others still install and the stamp stays unwritten, so\n  # the host keeps a stale gopls (or none) until the pins agree.` and in the `bad` message replace `lsp.sh would warn-and-skip, leaving gopls stale or absent` with `mise-runtimes would fail on gopls, leaving it stale or absent`.

- [ ] **Step 5: Fanout, doctor rows, `list`**

```make
PROVISION_FANOUT := tools user-tools shell wsl-config
# both-scopes: the mise-managed runtimes (uv everywhere; node/go/LSP on dev)
# and the ad-hoc scripting venv every host gets — the dev-gated block below
# keeps the genuinely dev-only targets.
PROVISION_FANOUT += mise-runtimes python-env
ifeq ($(MODE),dev)
PROVISION_FANOUT += claude-cli nerd-fonts docker-engine dozzle-service cockpit-service rsyslog-service
PROVISION_FANOUT += pwndbg vcpkg lsp-servers devtoys-cli
endif
```

`DOCTOR_ROWS`: replace `DOCTOR_ROWS += bespoke|node-runtime|$(NODE_VERSION)` with `DOCTOR_ROWS += bespoke|mise-runtimes|$(MISE_RUNTIMES_STAMP)` and delete the `DOCTOR_ROWS += bespoke|go-runtime|$(GO_VERSION)` line.

`list` (line ~901): replace the two Language-servers printf lines with:

```make
	@printf '\nmise-runtimes (both scopes): uv; on MODE=dev also node (+ npm LSP servers), go, gopls, lua-language-server, basedpyright\n'
	@printf '  declared in chezmoi/dot_config/mise/conf.d/ (generated from versions.mk); lsp-servers = alias + clangd check\n'
	@printf '  (rust-analyzer/marksman/taplo are scope-tools above; clangd from clang-tools-extra)\n'
```

- [ ] **Step 6: tools.mk — drop the uv eget entry, add its manual update spec**

Delete lines 175-180 of `makefile/tools.mk` (the `# uv — multi-binary tarball …` comment through `$(eval $(call EGET_TOOL,uv,…))`). In the `# Bespoke / non-tool pins from versions.mk:` block, after the `node` line add:

```make
# uv — mise-managed on both scopes (mise-runtimes; declared in the generated
# conf.d), so no EGET_TOOL registers it. Tags are bare (0.12.7, no v).
UPDATE_SPECS += uv|$(UV_VERSION)|astral-sh/uv|$(UV_VERSION)
```

- [ ] **Step 7: Delete the three lib scripts and fix the hint texts**

```bash
git rm -q makefile/lib/node.sh makefile/lib/go.sh makefile/lib/lsp.sh
```

`makefile/lib/python-env.sh` lines 41-44: message `python-env.sh: uv not on PATH — run \`make uv\` first` → `python-env.sh: uv not on PATH — run \`make mise-runtimes\` first (uv is mise-managed)`; and the header comment sentence `uv (the EGET_TOOL already on PATH) downloads` → `uv (mise-managed — the Makefile prepends mise's shims dir) downloads`.

`scripts/setup-ccstatusline.sh`: both `make -C makefile node-runtime MODE=dev` hints → `make -C makefile mise-runtimes MODE=dev`; the first hint's `(this repo, pinned LTS)` → `(this repo; node is mise-managed, pinned in versions.mk)`.

`makefile/packages.mk:19`: `(node-runtime is dev-only, and this file only runs on dev)` → `(node is mise-managed and dev-only, and this file only runs on dev)`.
`makefile/lib/pwndbg.sh:21`: `Layout mirrors lib/node.sh:` → `Layout (tree-extract + sweep, the pattern lib/node.sh used before mise):`.
`docs/claude/file-care.md`: delete the three bullets for `lib/node.sh`, `lib/go.sh`, `lib/lsp.sh` (lines 48-50). Task 7 adds the `lib/mise.sh` bullet.

- [ ] **Step 8: Dry-run both modes and lint**

```bash
cd makefile && make -n MODE=dev IS_WSL=false provision 2>&1 | grep -E '==> (mise-runtimes|python-env|claude-statusline)|mise.sh (seed|install|sweep|uninstall)' ; cd ..
```
Expected: `==> mise-runtimes (dev)`, `mise.sh seed dev …`, `mise.sh install`, `sudo … mise.sh sweep-legacy /usr/local/bin`, `mise.sh sweep-user`, `==> python-env 3.14.7` — and NO `node.sh`/`go.sh`/`lsp.sh` lines.

```bash
cd makefile && make -n MODE=prod provision 2>&1 | grep -E 'mise.sh|node|lsp' ; cd ..
```
Expected: `mise.sh seed prod …`, `mise.sh install`, `mise.sh sweep-legacy` WITHOUT `sudo`, `mise.sh sweep-user`; no lsp/node lines.

```bash
cd makefile && make -s list MODE=dev | grep -A2 mise-runtimes && make -s inventory MODE=dev | grep -E 'mise-runtimes|node-runtime|go-runtime|\|uv\|' ; cd ..
```
Expected: the mise-runtimes list block; inventory shows `bespoke|mise-runtimes|<number>` only (no node-runtime/go-runtime/uv rows).

`scripts/check-invariants.sh` — all green (pin coverage now counts the manual uv spec).

- [ ] **Step 9: Sandbox run for real (no sudo): prod scope end-to-end, then the dev set via the lib**

```bash
SB=$(mktemp -d) && mkdir -p "$SB/bin" "$SB/stamps" "$SB/data" "$SB/cfg" "$SB/home" && \
HOME="$SB/home" make -C makefile mise mise-runtimes MODE=prod DEST="$SB/bin" STAMP="$SB/stamps" MISE_DATA_DIR="$SB/data" MISE_CONFIG_DIR="$SB/cfg" MISE_CACHE_DIR="$SB/cache" 2>&1 | tail -15 && \
ls "$SB/stamps" && cat "$SB/cfg/conf.d/workstation.toml" | tail -2 && ls "$SB/data/shims" && ls "$SB/cfg/conf.d"
```
Expected: `==> mise-runtimes (prod)`, `✓ seeded …`, `mise uv@0.12.7 ✓ installed`, stamps `eget-*.done mise-2026.9.1.done mise-runtimes-<n>.done`, shims `uv uvx`, conf.d holds ONLY `workstation.toml`.

Then the dev set from the generated file (network; go download + gopls build take a few minutes):
```bash
HOME="$SB/home" MISE_CONFIG_DIR="$SB/cfg" makefile/lib/mise.sh seed dev chezmoi/dot_config/mise/conf.d && \
HOME="$SB/home" MISE_DATA_DIR="$SB/data" MISE_CONFIG_DIR="$SB/cfg" MISE_CACHE_DIR="$SB/cache" PATH="$SB/bin:$PATH" makefile/lib/mise.sh install 2>&1 | tail -20 && \
ls "$SB/data/shims" | paste -sd' ' - && \
for b in typescript-language-server bash-language-server yaml-language-server vscode-json-language-server lua-language-server basedpyright-langserver; do printf '%s: ' "$b"; HOME="$SB/home" MISE_DATA_DIR="$SB/data" MISE_CONFIG_DIR="$SB/cfg" "$SB/data/shims/$b" --version 2>&1 | head -1; done; \
printf 'gopls: '; HOME="$SB/home" MISE_DATA_DIR="$SB/data" MISE_CONFIG_DIR="$SB/cfg" "$SB/data/shims/gopls" version 2>&1 | head -1; \
ls "$SB/data/installs" | grep -ci python || echo 'no mise python (good)'
```
Expected: every tool `✓ installed`; shims include `node npm npx go gofmt uv uvx gopls lua-language-server basedpyright basedpyright-langserver typescript-language-server tsc tsserver bash-language-server yaml-language-server vscode-json-language-server …`; each `--version` prints a version and `gopls version` prints `golang.org/x/tools/gopls v0.23.0`; `no mise python (good)`. `rm -rf "$SB"` afterwards.

- [ ] **Step 10: Commit**

```bash
git add -A makefile scripts/setup-ccstatusline.sh scripts/check-invariants.sh docs/claude/file-care.md
git commit -m "feat(mise): mise-runtimes replaces node-runtime, go-runtime, the eget uv and lsp.sh

Both-scopes, user-level target seeded from the generated conf.d; python-env
and claude-statusline re-point at its stamp and prepend the shims dir;
lsp-servers is a thin alias + clangd check; node.sh/go.sh/lsp.sh deleted.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 5: Doctor knows about `mise-runtimes`

**Files:**
- Modify: `makefile/lib/doctor.sh:8-13` (header), `:96-110` (both-scopes exception + component case), `:251-263` (wiring)

**Interfaces:**
- Consumes: `DOCTOR_ROWS` row `bespoke|mise-runtimes|<cksum>` (Task 4); shims dir `${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims`.

- [ ] **Step 1: Header + both-scopes exception**

Header comment lines 9-13: replace `node-runtime, nerd-fonts, docker-engine,` with `mise-runtimes, nerd-fonts, docker-engine,`.

In `check_bespoke`, replace
```bash
  # Everything in this section except wsl-config is dev_machine-only.
  if [[ "$MODE" != dev && "$name" != wsl-config ]]; then
```
with
```bash
  # Everything in this section is dev_machine-only except the three both-scopes
  # rows: wsl-config, mise-runtimes (uv on prod) and python-env.
  case "$name" in
  wsl-config | mise-runtimes | python-env) ;;
  *)
    if [[ "$MODE" != dev ]]; then
      row_skip "$name" "dev_machine only (MODE=$MODE)"
      return
    fi
    ;;
  esac
```
(and delete the two lines `row_skip "$name" "dev_machine only (MODE=$MODE)"` / `return` / `fi` that followed the old `if`).

- [ ] **Step 2: Replace the `node-runtime)` case with `mise-runtimes)`**

```bash
  mise-runtimes)
    # $version is the cksum of the consumed conf.d file(s) (the stamp suffix),
    # so a pin change shows as "pins moved". Presence = one shim per tool the
    # config declares for this scope; mise's own binary is a scope-tool row.
    local shims="${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims" want b missing=()
    if [[ "$MODE" == dev ]]; then
      want="node npm npx go gofmt uv uvx gopls lua-language-server basedpyright-langserver typescript-language-server bash-language-server yaml-language-server vscode-json-language-server"
    else
      want="uv uvx"
    fi
    for b in $want; do
      [[ -x "$shims/$b" ]] || missing+=("$b")
    done
    if [[ -f "$STAMP/mise-runtimes-$version.done" ]] && ((${#missing[@]} == 0)); then
      row_ok "$name" "all shims present ($shims)"
    elif ((${#missing[@]} == 0)); then
      row_warn "$name" "shims present, but no $version stamp — pins moved? next 'make provision' reinstalls"
    else
      row_bad "$name" "missing shims: ${missing[*]} — install: make mise-runtimes MODE=$MODE"
    fi
    ;;
```

- [ ] **Step 3: Wiring row for the shims dir**

In `check_wiring`, after the existing mise `activate` block (before the pueued comment) add:

```bash
  # mise shims — non-interactive shells (`ssh host cmd`, Make over
  # update-hosts.sh, IDE/LSP spawns) only see mise-managed tools through the
  # shims dir: ~/.zshenv (chezmoi dot_zshenv) and ~/.bashrc above its guard.
  if command -v mise >/dev/null 2>&1; then
    if grep -q 'mise/shims' "$HOME/.zshenv" 2>/dev/null; then
      row_ok "mise-shims" "on PATH via ~/.zshenv (non-interactive shells)"
    else
      row_warn "mise-shims" "no shims line in ~/.zshenv — run: chezmoi apply"
    fi
  fi
```

- [ ] **Step 4: Verify**

`shellcheck -x -S warning makefile/lib/doctor.sh && shfmt -d -i 2 makefile/lib/doctor.sh && echo clean`.

Real host (pre-migration): `make -C makefile doctor MODE=dev 2>&1 | grep -E 'mise'` — expected: `✗ mise-runtimes  missing shims: … — install: make mise-runtimes MODE=dev`, `✓ mise  activated in ~/.zshrc`, `! mise-shims  no shims line in ~/.zshenv — run: chezmoi apply` (Task 6/8 turn these green).

Sandbox (prod, sudo-free, reusing the Task 4 Step 9 shape):
```bash
SB=$(mktemp -d) && mkdir -p "$SB/bin" "$SB/stamps" "$SB/data" "$SB/cfg" "$SB/home" && HOME="$SB/home" make -C makefile mise mise-runtimes MODE=prod DEST="$SB/bin" STAMP="$SB/stamps" MISE_DATA_DIR="$SB/data" MISE_CONFIG_DIR="$SB/cfg" >/dev/null 2>&1; HOME="$SB/home" make -C makefile doctor MODE=prod DEST="$SB/bin" STAMP="$SB/stamps" MISE_DATA_DIR="$SB/data" 2>&1 | grep -E 'mise-runtimes|python-env'; rm -rf "$SB"
```
Expected: `✓ mise-runtimes  all shims present (…/data/shims)` and python-env shown as a real row (not `dev_machine only`).

- [ ] **Step 5: Commit**

```bash
git add makefile/lib/doctor.sh
git commit -m "feat(doctor): mise-runtimes component (shims per scope) + shims wiring row; both-scopes rows no longer skipped on prod

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 6: Shell wiring — shims for non-interactive shells

**Files:**
- Create: `chezmoi/dot_zshenv`
- Modify: `chezmoi/dot_bashrc.tmpl:6-10`, `:227-232`
- Modify: `chezmoi/dot_zshrc.tmpl:184-190`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Windows block, after `.zshrc`)

- [ ] **Step 1: `chezmoi/dot_zshenv`**

```zsh
# =============================================================================
# ~/.zshenv — managed by chezmoi. Sourced by EVERY zsh: login, interactive,
# `zsh -c`, and the shell sshd spawns for `ssh host cmd`. Keep it tiny.
# =============================================================================

# --- mise shims: runtimes for NON-interactive shells -------------------------
# node / go / uv / gopls / the LSP servers are mise-managed (make
# mise-runtimes). Interactive shells get the real bin dirs from `mise activate
# zsh` (~/.zshrc); everything else — Make over update-hosts.sh, `ssh host
# cmd`, IDE/LSP spawns — only sees them through mise's shims dir. Guarded: zsh
# re-reads this file in every subshell. PARITY: dot_bashrc.tmpl carries the
# bash twin above its interactive guard.
case ":$PATH:" in
*":$HOME/.local/share/mise/shims:"*) ;;
*) export PATH="$HOME/.local/share/mise/shims:$PATH" ;;
esac
```

- [ ] **Step 2: bash twin ABOVE the interactive guard**

In `chezmoi/dot_bashrc.tmpl` replace lines 6-7 (`# Not running interactively? Stop here.` / `[[ $- != *i* ]] && return`) with:

```bash
# --- mise shims: runtimes for NON-interactive shells (ABOVE the guard) -------
# The bash sshd spawns for `ssh host cmd` reads ~/.bashrc but is NOT
# interactive, so this must precede the return below. Interactive shells layer
# `mise activate bash` (further down) on top. PARITY: dot_zshenv is the zsh
# twin (zsh reads .zshenv for every invocation instead).
case ":$PATH:" in
*":$HOME/.local/share/mise/shims:"*) ;;
*) export PATH="$HOME/.local/share/mise/shims:$PATH" ;;
esac

# Not running interactively? Stop here.
[[ $- != *i* ]] && return
```

- [ ] **Step 3: Refresh the two activate comments**

`dot_zshrc.tmpl` lines 184-187 →
```zsh
# --- mise (runtimes: node/go/uv/LSP servers + per-project mise.toml) ---------
# The global pins live in ~/.config/mise/conf.d/ (generated from versions.mk,
# installed by `make mise-runtimes`). `mise activate` installs a precmd/chpwd
# hook that puts the real bin dirs on PATH (in front of the shims from
# ~/.zshenv) and layers any project mise.toml on top as you cd.
```
`dot_bashrc.tmpl` lines 227-229 →
```bash
# --- mise (runtimes: node/go/uv/LSP servers + per-project mise.toml) ---------
# Global pins in ~/.config/mise/conf.d/ (generated from versions.mk, installed
# by `make mise-runtimes`). `mise activate` hooks PROMPT_COMMAND to put the
# real bin dirs on PATH (in front of the shims exported above the guard).
```

- [ ] **Step 4: `.zshenv` is Linux-only**

In `chezmoi/.chezmoiignore.tmpl`'s `{{ if eq .chezmoi.os "windows" }}` block, after `.zshrc` add `.zshenv`.

- [ ] **Step 5: Verify**

```bash
zsh -n chezmoi/dot_zshenv && echo zshenv-ok
scripts/check-templates.sh 2>&1 | tail -3
scripts/check-invariants.sh 2>&1 | grep -E 'chezmoiignore|Warp|✗' 
chezmoi execute-template < chezmoi/dot_bashrc.tmpl | bash -n && echo bashrc-ok
chezmoi ignored | grep -E 'zshenv|mise' ; echo "(dev Linux host: expected NO matches above)"
```
Expected: `zshenv-ok`, templates pass, no `✗`, `bashrc-ok`, no ignored matches on this dev Linux host. Then confirm the bash guard order with a non-interactive probe of the RENDERED file:
```bash
chezmoi execute-template < chezmoi/dot_bashrc.tmpl > /tmp/claude-1000/bashrc.probe && bash -c 'source /tmp/claude-1000/bashrc.probe; case ":$PATH:" in *mise/shims*) echo shims-on-path;; *) echo MISSING;; esac'
```
Expected: `shims-on-path` (the probe shell is non-interactive, so only the block above the guard ran).

- [ ] **Step 6: Commit**

```bash
git add chezmoi/dot_zshenv chezmoi/dot_bashrc.tmpl chezmoi/dot_zshrc.tmpl chezmoi/.chezmoiignore.tmpl
git commit -m "feat(shell): mise shims on PATH for non-interactive shells (~/.zshenv, ~/.bashrc above its guard)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (invariant bullets; dual-edit list; careful-files; hooks; single-source; zsh section)
- Modify: `docs/claude/invariants.md:23-25`, `docs/claude/file-care.md` (new `lib/mise.sh`, `dot_zshenv`, conf.d entries), `docs/claude/verification.md` (new recipe)
- Modify: `README.html` (lines 1452-1500, 1540-1625, 2535-2545, 4146-4172, 5765-5795)
- Modify: `CLAUDE_CHANGELOG.md` (one row at the top of the table)

- [ ] **Step 1: `CLAUDE.md`**

(a) Replace the three bullets **`Node.js is dev-only via node-runtime`**, **`go-runtime + lsp-servers are dev-only install targets`** and the Node-related clause of **`python-env`** as follows — new single bullet in place of the first two:

```markdown
- **Runtimes are mise-managed via `mise-runtimes` (BOTH scopes, USER-LEVEL — never `$(SUDO)` except its legacy sweep).** node, Go, uv, gopls, lua-language-server, basedpyright and the four npm language servers (+ a pinned `typescript`) are declared in `chezmoi/dot_config/mise/conf.d/workstation.toml` (both scopes: uv) and `workstation-dev.toml` (dev only) — **GENERATED from `versions.mk` by `scripts/gen-mise-config.sh`, never hand-edited** (the `sync-tool-memory.sh` hook + `bump-versions.sh` regenerate; `check_mise_config` fails on drift). `lib/mise.sh` seeds the right file(s) into `~/.config/mise/conf.d/` (fanout runs before dotfiles; chezmoi later deploys identical bytes), runs `mise install`, **force-reinstalls node when the stamp is stale** (the npm servers ride node's `postinstall` so typescript-language-server finds `typescript` as a global sibling — per-tool `npm:` trees would break that; a hook only re-runs when node reinstalls), prunes, then sweeps the pre-mise `/usr/local` artifacts. Stamp = cksum of the consumed conf.d file(s); order-only dep on mise's eget stamp FILE. `python` is NEVER declared in mise (system interpreter stays unshadowed; `pipx:basedpyright` uses `uv tool install`). Non-interactive shells see the tools through `~/.local/share/mise/shims` (`dot_zshenv`; `dot_bashrc.tmpl` ABOVE its interactive guard — parity pair), interactive ones through `mise activate`; Make recipes that need a tool (`python-env`, `claude-statusline`) prepend `$(MISE_SHIMS)` themselves. `lsp-servers` is now a thin dev alias (+ clangd verify). `mise-shim`/`activate` coexistence verified 2026-09-13 (`mise doctor`: activated yes, shims_on_path yes). Windows half in PR 2 (spec `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md`).
```
In the `python-env` bullet, change `uv builds a pinned CPython` → `uv (mise-managed — the recipe prepends the shims dir) builds a pinned CPython` and `Order-only dep on uv's stamp *file*.` → `Order-only dep on the `mise-runtimes` stamp *file*.`

(b) **Version-pin dual/triple-edits** list: leave `UV_VERSION` as is (PR 2 retires it). Add to the **Single-source-of-truth files** sentence: `` `scripts/gen-mise-config.sh` (the generator of `chezmoi/dot_config/mise/conf.d/*.toml`) ``.

(c) **Files Claude should be careful with → LF-only + mode 100755** set: nothing to add (glob-covered). **Sentinel/generated** bullet: add `` `chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml` (whole-file generated — regenerate, never edit) `` to the **Don't hand-edit** bullet. **Parity pairs**: add `` `dot_zshenv` ↔ the shims block above the guard in `dot_bashrc.tmpl` ``.

(d) **Claude Code hooks** → `sync-tool-memory.sh` bullet: `regenerates the `TOOLS` block in … CLAUDE.md; nudges to `cza`` → `regenerates the `TOOLS` block in `chezmoi/private_dot_claude/CLAUDE.md` AND the mise conf.d files via `scripts/gen-mise-config.sh`; nudges to `cza``.

(e) **zsh interactive plugin load order** bullet: append `` `~/.zshenv` (new, Linux-only, ignored on Windows) carries ONLY the mise shims PATH prepend — keep it tiny, it runs for every zsh. ``

- [ ] **Step 2: `docs/claude/invariants.md`, `file-care.md`, `verification.md`**

`invariants.md`: replace the two bullets at lines 23-24 (`Node.js is dev-only…`, `go-runtime + lsp-servers…`) with one bullet carrying the CLAUDE.md text above plus these failure stories: (1) the old `node.sh`/`go.sh` curl'd tarballs WITHOUT checksum verification — mise verifies (uv even via GitHub artifact attestations, observed 2026-09-13); (2) `mise` had been installed since 2026-05 and activated since 2026-07 with nothing to manage; (3) why the seed step exists (virgin host: fanout precedes `chezmoi init --apply`); (4) `mise prune` also removes unreferenced ad-hoc installs (the stray `aqua:nushell/nushell` on the WSL host). In the `python-env` bullet (line 25) apply the same two edits as CLAUDE.md.

`file-care.md`: add after the `lib/eget.sh` entry (line 31):
```markdown
- **`makefile/lib/mise.sh`** — LF-only, mode 100755. Subcommands `seed`/`install`/`sweep-legacy`/`sweep-user`/`uninstall` for the `mise-runtimes` target; `sweep-legacy` is the ONLY step the Makefile runs under `$(SUDO)` (it only ever `rm`s under `$(DEST)`; the `lib/node_modules` removal is gated on a `_node-*` tree as evidence so a user's own `~/.local/lib/node_modules` on prod survives). `install` force-reinstalls node when it was already present (postinstall re-run). Guarded by `scripts/test-mise.sh` (offline, fake `mise`), run from `check-invariants.sh`.
- **`chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml`** — GENERATED by `scripts/gen-mise-config.sh` from `versions.mk`; never hand-edit (drift fails `check_mise_config`). Plain TOML, not templates — Make reads them before dotfiles exist. `workstation-dev.toml` is ignored on prod via a TARGET path in `.chezmoiignore.tmpl`.
- **`chezmoi/dot_zshenv`** — Linux-only (ignored on Windows), runs for EVERY zsh; carries only the guarded mise-shims PATH prepend. Parity twin: the block ABOVE the interactive guard in `dot_bashrc.tmpl`.
```

`verification.md`: add after the python-env recipe (line 25):
```markdown
- **mise-runtimes** (after touching `lib/mise.sh`, `scripts/gen-mise-config.sh`, the generated conf.d, the `mise-runtimes`/`lsp-servers`/`python-env` targets, `dot_zshenv`, or the bashrc guard block): offline — `bash scripts/test-mise.sh` (PASS line) + `scripts/check-invariants.sh` (`mise conf.d … in sync`, `both files parse`, `mise runtimes lib` green). Sudo-free sandbox (scratch HOME so the sweeps never touch the real one) — `SB=$(mktemp -d); mkdir -p $SB/home; HOME=$SB/home make -C makefile mise mise-runtimes MODE=prod DEST=$SB/bin STAMP=$SB/stamps MISE_DATA_DIR=$SB/data MISE_CONFIG_DIR=$SB/cfg` → `ls $SB/data/shims` shows `uv uvx`, conf.d holds only `workstation.toml`; the dev set: `MISE_CONFIG_DIR=$SB/cfg makefile/lib/mise.sh seed dev chezmoi/dot_config/mise/conf.d && MISE_DATA_DIR=$SB/data MISE_CONFIG_DIR=$SB/cfg PATH=$SB/bin:$PATH makefile/lib/mise.sh install` → shims for node/npm/npx/go/gofmt/gopls/lua-language-server/basedpyright-langserver/typescript-language-server/tsc/bash-language-server/yaml-language-server/vscode-json-language-server, NO `installs/python`. Real host after `make dev` + `cza` + a new shell: `mise doctor` (activated: yes, shims_on_path: yes), `mise ls --missing` empty, `zsh -c 'command -v node'` and `bash -c 'command -v node'` → `~/.local/share/mise/shims/node`, `typescript-language-server --version`, `gopls version`, `basedpyright-langserver --version`, `lua-language-server --version`, `ls /usr/local/bin | grep -E '^(node|go|uv|gopls)$'` empty (swept), `make doctor MODE=dev` shows `✓ mise-runtimes` + `✓ mise-shims`, then the python-env recipe above still passes.
```

- [ ] **Step 3: `README.html`**

(a) Lines 1452-1500, Lang managers card: mise chip `data-tip` → `Polyglot runtime manager — owns node/Go/uv + the LSP servers (make mise-runtimes; global pins generated from versions.mk)`, sr-only → `— polyglot runtime manager; installs node, Go, uv and the language servers from pins generated out of versions.mk (make mise-runtimes)`. uv chip tip → `Fast Python installer + venv (mise-managed, both scopes; replaces pip + venv)`. Go chip tip → `Go toolchain via mise (dev_machine only — make mise-runtimes MODE=dev)`, sr-only → `— official Go toolchain, installed user-level by mise (dev_machine only via mise-runtimes)`. Add a node chip after Go:
```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="Node.js via mise (dev_machine only — npx for ccstatusline + the npm language servers)"
                                    >node <small>(dev)</small
                                    ><span class="sr-only">
                                        — Node.js, installed user-level by mise
                                        (dev_machine only); provides npx for
                                        ccstatusline and carries the npm
                                        language servers as its postinstall</span
                                    ></span
                                >
```
(b) Lines 1540-1625, LSP card: gopls tip → `Go language server (mise go: backend, dev_machine only)`, sr-only → `— Go language server; built by mise's go: backend against the pinned Go (dev_machine only)`; lua tip → `Lua language server (mise registry install, dev_machine only)`; basedpyright tip → `Type-strict Python LSP (mise pipx: backend via uv tool install, dev_machine only)`, sr-only `installed via uv tool install to the user site` → `installed by mise's pipx: backend (uv tool install)`; typescript/bash/yaml/json tips: replace `(npm, dev_machine only)` / `(npm via vscode-langservers-extracted, dev_machine only)` with `(npm postinstall of mise's node, dev_machine only)` / `(npm postinstall of mise's node via vscode-langservers-extracted, dev_machine only)`; sr-only `(dev_machine only, needs node-runtime)` → `(dev_machine only; npm postinstall of mise's node)`. Card note: replace `Each server is best-effort &mdash; one failure never aborts the rest.` with `The mise-managed servers come from <code>make mise-runtimes</code>; mise installs each tool independently, so one failure leaves the others usable and the next <code>make</code> retries.`
(c) Lines 2535-2545: `Auto-installs Linux-native Node.js (pinned LTS) as a dep via <code>make -C makefile node-runtime MODE=dev</code>,` → `Auto-installs the mise-managed Linux-native Node.js as a dep via <code>make -C makefile mise-runtimes MODE=dev</code>,`.
(d) Lines 4146-4172: heading `Node.js runtime` → `Runtimes via mise`; paragraph → `Install or refresh the mise-managed runtimes (Node.js, Go, uv) and language servers. Pins live in <code>makefile/versions.mk</code> and are rendered into <code>~/.config/mise/conf.d/</code>; consumed by the ccstatusline <code>statusLine</code> command, the Claude Code <code>LSP</code> plugin, and anything else that needs <code>npx</code>, <code>go</code> or <code>uv</code>:`; pre → `make -C makefile mise-runtimes MODE=dev   # MODE=prod installs uv only`; note-row → `Everything lands user-level under <code>~/.local/share/mise</code> (no sudo). Interactive shells see the tools through <code>mise activate</code>; non-interactive ones (<code>ssh host cmd</code>, Make, IDE spawns) through <code>~/.local/share/mise/shims</code>, exported from <code>~/.zshenv</code> and from <code>~/.bashrc</code> above its interactive guard. Auto-runs as a dep of <code>claude-statusline</code> and <code>python-env</code>, so you rarely need to call it directly. Force a full redo as two commands: <code>make clean-mise-runtimes MODE=dev</code> then <code>make mise-runtimes MODE=dev</code>. WSL note: if your <code>PATH</code> leaks a Windows-side <code>npx</code> from <code>/mnt/c/...</code>, the setup script detects it and points you at this target.`
(e) Lines 5765-5795, troubleshooting entry: keep the summary; body paragraph → `<code>make lsp-servers MODE=dev</code> (also runs as part of <code>make dev</code>) covers the whole stack. Servers and their mechanisms:`; list items:
```html
                                <li><strong>rust-analyzer / marksman / taplo</strong> &mdash; eget binaries, dev + prod; re-run <code>make provision MODE=dev</code>.</li>
                                <li><strong>gopls / lua-language-server / basedpyright / typescript-language-server / bash-language-server / yaml-language-server / vscode-json-language-server</strong> &mdash; mise-managed (<code>make mise-runtimes MODE=dev</code>). <code>mise ls --missing</code> lists what did not install; <code>mise doctor</code> must report <code>activated: yes</code> and <code>shims_on_path: yes</code> (else <code>cza</code> and open a new shell). A stale npm server after a pin bump means node's postinstall did not re-run: <code>mise install --force node</code>.</li>
                                <li><strong>clangd</strong> &mdash; verified-only (comes from <code>clang-tools-extra</code> via dnf, see the C/C++ entry below); <code>make lsp-servers</code> only warns if absent.</li>
```
closing paragraph → `Re-run the stack: <code>make lsp-servers MODE=dev</code>. Force a reinstall of everything mise-managed, as two commands (a combined goal list races under <code>-j</code>): <code>make clean-mise-runtimes MODE=dev</code> then <code>make mise-runtimes MODE=dev</code>.`

- [ ] **Step 4: `CLAUDE_CHANGELOG.md`**

Insert as the first table row:
```markdown
| **mise owns the runtime layer (Linux, PR 1 of 2).** `node-runtime`, `go-runtime`, the eget `uv` entry and the multi-mechanism `lsp-servers` collapse into one both-scopes, user-level `mise-runtimes` target: `scripts/gen-mise-config.sh` renders `versions.mk` pins into `chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml` (hook + bumper regenerate, `check_mise_config` drift-checks), `lib/mise.sh` seeds/installs/prunes/sweeps (the npm servers ride node's `postinstall` so typescript-language-server finds `typescript`; node is force-reinstalled on a stale stamp), `~/.zshenv` (new) + `~/.bashrc` above its guard export the shims dir for non-interactive shells, `lsp-servers` becomes an alias + clangd check, `lib/{node,go,lsp}.sh` deleted, new `TYPESCRIPT_VERSION` pin. Migration: `make dev` sweeps `/usr/local`'s node/go/uv/LSP artifacts; `mise prune` also drops unreferenced ad-hoc installs (the stray `aqua:nushell/nushell` on the WSL host). Windows follows in PR 2 (`UV_VERSION` keeps its `bootstrap.ps1` dual-edit until then). | **Yes** | Lang-managers + LSP cards (mise/uv/go/node chips, mechanisms), the ccstatusline dep sentence, the "Runtimes via mise" section (was "Node.js runtime"), the LSP troubleshooting entry. |
```

- [ ] **Step 5: Verify and commit**

```bash
npm install --no-save --no-package-lock jsdom@30.0.1 >/dev/null 2>&1 && node scripts/check-readme.mjs && scripts/check-invariants.sh | tail -2
rg -n 'node-runtime|go-runtime|lib/node\.sh|lib/go\.sh|lib/lsp\.sh' README.html CLAUDE.md docs/claude/ makefile/ scripts/ chezmoi/ ; echo "(expect no output above except historical prose in docs/claude/invariants.md failure stories)"
```
Expected: readme check passes; invariants all green; no live references remain.

```bash
git add CLAUDE.md docs/claude README.html CLAUDE_CHANGELOG.md
git commit -m "docs(mise): mise-runtimes invariant, file-care, verification recipe, README + changelog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG"
```

---

### Task 8: Host migration, end-to-end verification, PR

**Files:** none (verification only)

- [ ] **Step 1: Deploy the dotfiles half first**

`cza` (chezmoi apply) → `~/.zshenv`, the updated `~/.bashrc`/`~/.zshrc`, and `~/.config/mise/conf.d/{workstation,workstation-dev}.toml` land. Verify: `test -f ~/.zshenv && test -f ~/.config/mise/conf.d/workstation-dev.toml && echo deployed`.

- [ ] **Step 2: The user runs the migration (needs the sudo password)**

Ask the user to run, in their terminal:
```
! make -C makefile dev
```
Expected in the output: `==> mise-runtimes (dev)`, `✓ seeded …`, every mise tool `✓ installed`, `↪ node was already installed …` does NOT appear on the first migration (node was never in mise), `✓ swept N pre-mise artifact(s) from /usr/local/bin`, then `==> python-env 3.14.7` rebuilding, and `chezmoi update` at the tail. The mise binary itself is bumped `2026.8.16 → 2026.9.1` on the way (pin from #145).

- [ ] **Step 3: Verify on the host (from a NEW shell)**

```bash
mise doctor | grep -E 'activated|shims_on_path'          # activated: yes / shims_on_path: yes
mise ls --missing                                        # empty
mise ls | grep -cE '^(uv|node|go|go:golang.org/x/tools/gopls|lua-language-server|pipx:basedpyright) '  # 6
zsh -c 'command -v node'; bash -c 'command -v node'       # both: ~/.local/share/mise/shims/node
typescript-language-server --version; gopls version; basedpyright-langserver --version; lua-language-server --version
ls /usr/local/bin | grep -E '^(node|npm|npx|go|gofmt|uv|uvx|gopls|lua-language-server|typescript-language-server)$' ; echo "(expect nothing above)"
ls -d /usr/local/_node-* /usr/local/_go-* /usr/local/lib/node_modules 2>&1 | grep -c 'No such'   # 3
make -C makefile doctor MODE=dev 2>&1 | grep -E 'mise|python-env'   # ✓ mise-runtimes, ✓ mise, ✓ mise-shims, ✓ python-env
wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"
```

- [ ] **Step 4: Full lint + hooks, then open the PR**

```bash
scripts/check-invariants.sh | tail -1 && bash .claude/hooks/test-hooks.sh | tail -1 && scripts/check-templates.sh | tail -1
git push -u origin feat/mise-runtimes
gh pr create --title "feat(mise): mise-runtimes — one runtime manager for node/go/uv/LSP (Linux, PR 1/2)" --body "$(cat <<'EOF'
## Summary
- `mise-runtimes` (both scopes, user-level) replaces `node-runtime`, `go-runtime`, the eget `uv` entry and the multi-mechanism `lsp-servers`
- pins stay in `versions.mk`; `scripts/gen-mise-config.sh` renders them into `chezmoi/dot_config/mise/conf.d/` (hook + bumper regenerate, drift-checked)
- `lib/mise.sh` seeds / installs / prunes / sweeps the pre-mise `/usr/local` artifacts; npm servers ride node's postinstall; offline test in `scripts/test-mise.sh`
- shims dir exported for non-interactive shells (`~/.zshenv`, `~/.bashrc` above its guard); `mise activate` unchanged
- doctor rows, README, CLAUDE.md + docs/claude updated; spec: `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md`

## Test plan
- [x] `scripts/check-invariants.sh`, `.claude/hooks/test-hooks.sh`, `scripts/check-templates.sh`, `scripts/check-readme.mjs`
- [x] sudo-free sandbox: `make mise-runtimes MODE=prod` under `DEST`/`STAMP`/`MISE_*` overrides; dev set via `lib/mise.sh install`
- [x] real host: `make dev` migration, `mise doctor`, shims resolution from `zsh -c`/`bash -c`, every server `--version`, python-env rebuilt

Windows (portable mise, `Invoke-MiseRuntimes`, Nushell/PowerShell activation) follows in PR 2.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018qchvqkSaAKVvmPyS4MKKG
EOF
)"
```
Then watch CI: `gh pr checks --watch`.
