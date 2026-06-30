# Session-lifecycle hooks: SessionStart context + SessionEnd reminder

- **Date:** 2026-06-29
- **Status:** Approved design — ready for implementation plan
- **Author:** Claude (brainstormed with Arrush)

## Problem

When a Claude Code session opens in the `workstation` repo, Claude is handed a
fixed slice of environment context (working dir, "is a git repo", platform, the
OS-version string, shell, git branch + status + recent commits). That slice is
**static** — it cannot answer the runtime questions that actually bite when
editing a chezmoi dotfiles-source repo on a provisioned fleet box:

1. **chezmoi deploy state.** This repo is the chezmoi *source*. An edit here does
   nothing to the live `$HOME` until `chezmoi apply` (`cza`). Claude has no way to
   know whether the deployed dotfiles already match the source or whether N
   entries are pending — so it can reason as if its edits are live when they are
   not.
2. **Host identity & scope.** Whether this box is `dev_machine` or `prod_machine`
   decides which gating branch is live across the whole repo, yet it is not
   injected. The distro/version (e.g. EL9) governs real constraints (the GEF
   Python floor, dnf package availability).
3. **WSL & interop capability.** Whether Windows interop is reachable
   (`powershell.exe`) and whether the `appendWindowsPath=false` invariant holds is
   knowable only at runtime, and it drives `notify.sh` behavior and any
   Windows-side reasoning.
4. **Guardrail readiness.** The repo's own hooks depend on `jq`; the lint stack
   depends on `shfmt`/`gitleaks`/`shellcheck`; commit safety depends on the
   `check-invariants.sh` pre-commit hook. When any is silently absent, the
   guardrails Claude relies on are quietly off.

Separately, it is easy to **end** a session in this repo with uncommitted work or
a pending `chezmoi apply` and not notice.

## Goal

Add two repo-scoped session-lifecycle hooks (siblings to the existing
`.claude/hooks/` set), matching the established hook idiom exactly:

- A **SessionStart** hook that injects one compact, non-redundant context block
  covering the four runtime facts above.
- A **SessionEnd** hook that fires a desktop toast when the repo is left dirty or
  with a pending `chezmoi apply`.

## Non-goals (YAGNI)

- **Not machine-global.** These live in `.claude/hooks/` (this repo only), not in
  `chezmoi/private_dot_claude/hooks/`. The workstation repo is the one place that
  reasons about the host, so the host facts belong to its session, not every
  project's. (A global variant is a possible future phase.)
- **No per-prompt refresh.** We do not re-inject volatile state on every
  `UserPromptSubmit`; SessionStart (re-firing on `compact`) is sufficient and not
  noisy.
- **No "deployed-copy edit" PreToolUse guard** (denying edits to `~/.zshrc` vs the
  chezmoi source). Real footgun, but a global concern; out of scope here.
- **No Stop-hook lint nag.** Overlaps with `post-edit-guard.sh`, which already
  auto-repairs the mechanical cases.
- **SessionEnd injects no context.** The session is ending; there is nothing to
  inject into. Its only output is the toast side-effect.
- **Never spawn a Windows process to probe interop.** Launching `powershell.exe`
  to test reachability costs ~1s per session; interop is detected statically.

## Decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Scope | **Repo-only** (`.claude/hooks/`, wired in `.claude/settings.json`) |
| 2 | Events | **SessionStart** (context) **+ SessionEnd** (toast) |
| 3 | SessionStart buckets | All four: chezmoi state, host/scope, WSL/interop, guard readiness |
| 4 | Shape | **One self-contained script per event**, mirroring existing hooks (`jq → python3 → fail-open`) |
| 5 | Interop probe | **Static only** — `binfmt_misc/WSLInterop` + `command -v powershell.exe`; never exec a Windows binary |
| 6 | Performance | Every external probe `timeout`-guarded; chezmoi is the long pole and is capped |
| 7 | Failure mode | **Fail-open** — malformed stdin / missing tool → segment dropped or silent exit 0, never an error |
| 8 | SessionEnd output | **Toast only** via reused `notify.sh`; no stdout (cannot inject context) |

## Architecture

Two new scripts under `.claude/hooks/`, each self-contained and following the
existing hooks' conventions (`set -u`; `INPUT="$(cat)"`; the `jq → python3 →
fail-open` `hookfield()` helper copied verbatim; always `exit 0`).

```
SessionStart ─▶ session-context.sh ─▶ {hookSpecificOutput:{hookEventName,additionalContext}, suppressOutput}
SessionEnd   ─▶ session-end-notify.sh ─▶ (side-effect) notify.sh toast | silent
```

Both are automatically covered by existing enforcement — `.claude/hooks/*.sh`
already falls under `check-invariants.sh` (LF endings, 0755 git mode, shellcheck,
`shfmt -i 2`) and `post-edit-guard.sh` auto-repairs the mechanical cases. No new
invariant wiring is required.

### Files

| File | Change |
|---|---|
| `.claude/hooks/session-context.sh` | **NEW** (LF, 0755) — SessionStart context block |
| `.claude/hooks/session-end-notify.sh` | **NEW** (LF, 0755) — SessionEnd dirty/pending toast |
| `.claude/settings.json` | add `SessionStart` + `SessionEnd` hook arrays |
| `.claude/hooks/test-hooks.sh` | add assertion blocks for both hooks |
| `CLAUDE.md` (project) | document both hooks in the "Claude Code hooks" section |

No `README.html` update and no `CLAUDE_CHANGELOG.md` row — both new files live
under `.claude/`, which the README-update rule explicitly exempts as
Claude-internal.

## Component: `session-context.sh` (SessionStart)

**Input:** SessionStart hook JSON on stdin. Reads `.source`
(`startup|resume|clear|compact`) and `.cwd` via `hookfield()`.

**Repo root resolution:** prefer `$CLAUDE_PROJECT_DIR`; fall back to `.cwd`, then
walk up. (The hook is only wired in this repo, so cwd is in-repo in practice.) If
no root can be resolved AND stdin is unparseable → silent `exit 0`.

**Output:** a single compact one-line `additionalContext` block, kept
**JSON-fallback-safe** — no embedded `"`, no backslashes, no control characters
(newline/tab) — so the no-`jq` `printf` path still emits valid JSON. Multibyte
printable separators (`—`, `|`) are valid JSON string content and are fine; the
guard tokens stay `ok`/`MISSING` for grep-stable tests. Emitted as:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"},"suppressOutput":true}
```

Example block:

```
[workstation] host=almabox group=dev_machine os=almalinux 9 (EL9) | WSL=AlmaLinux-9 interop=on powershell.exe=on-PATH | chezmoi: 3 entries differ from $HOME — edits here are PENDING until `cza` | guards: jq=ok shfmt=ok gitleaks=MISSING shellcheck=ok precommit=installed
```

Each bucket is a function that fail-opens independently (omits its segment, or
prints a short `unknown`, on any error):

- **chezmoi state** — `timeout 4s chezmoi status 2>/dev/null` → count non-empty
  lines. `0` → `chezmoi: $HOME in sync`; `>0` → `chezmoi: N entries differ from
  $HOME — edits here are PENDING until \`cza\``; chezmoi absent or timeout →
  segment dropped.
- **host & scope** — hostname from `uname -n`; group from `timeout 3s chezmoi data
  --format=json` piped through `jq -r .group` (fallback: grep `group` in
  `~/.config/chezmoi/chezmoi.toml`); distro `ID` + `VERSION_ID` from
  `/etc/os-release`, annotating the EL9 family.
- **WSL & interop** — WSL if `$WSL_DISTRO_NAME` set or
  `/proc/sys/kernel/osrelease` matches `microsoft`/`WSL`; interop = first line of
  `/proc/sys/fs/binfmt_misc/WSLInterop` is `enabled`; `command -v powershell.exe`
  decides `powershell.exe=on-PATH|absent`. Non-WSL → `WSL=no`. **No process
  spawn.**
- **guards** — `command -v` for `jq`/`shfmt`/`gitleaks`/`shellcheck`; pre-commit
  installed if `$root/.git/hooks/pre-commit` is executable (or `core.hooksPath`
  points at an installed hook). Reports `tool=ok|MISSING` so a missing dep (esp.
  `jq`, which the other hooks need) stands out.

**Performance:** the only potentially-slow calls are the two `chezmoi`
invocations, both `timeout`-bounded; everything else is a local file read or
`command -v`. Target well under ~300 ms.

## Component: `session-end-notify.sh` (SessionEnd)

**Input:** SessionEnd hook JSON on stdin. Reads `.reason` and `.cwd`.

**Behavior:**

1. If `reason == clear` → `exit 0` (do not nag on `/clear`, which is not a real
   departure). *(Reason strings to be confirmed against Claude Code docs during
   implementation; default-safe — unknown reasons proceed.)*
2. Resolve repo root (`$CLAUDE_PROJECT_DIR` → `.cwd` → walk-up). Not a git repo →
   `exit 0`.
3. `dirty` = `git -C $root status --porcelain` non-empty (with count); `pending` =
   `timeout 4s chezmoi status` non-empty (with count).
4. Neither → silent `exit 0`.
5. Otherwise build `workstation: N uncommitted change(s)` + optional ` ·
   chezmoi apply pending (M)`, and fire:
   `"${WORKSTATION_NOTIFY:-$HOME/.claude/notify.sh}" 'Workstation repo' "$msg"
   </dev/null >/dev/null 2>&1 || true`.
6. Always `exit 0`. No stdout (SessionEnd cannot inject context).

**Reuse:** the toast goes through the existing global `notify.sh` (WSL
BurntToast/MessageBox → `notify-send` → terminal bell), exactly as the
`Notification` hooks do; fail-open if it is absent (fresh clone / prod / global
chezmoi not yet applied).

**Testability:** the `WORKSTATION_NOTIFY` override exists solely so the test can
point the toast at a recording stub (the same MEMFILE-override pattern
`sync-tool-memory.sh` uses for testability).

## Wiring (`.claude/settings.json`)

Add two keys alongside the existing `PreToolUse`/`PostToolUse` blocks:

```json
"SessionStart": [
  { "hooks": [ { "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/session-context.sh\"" } ] }
],
"SessionEnd": [
  { "hooks": [ { "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/session-end-notify.sh\"" } ] }
]
```

SessionStart is left matcher-less so it fires for all sources
(`startup|resume|clear|compact`) — re-firing on `compact` re-seeds the facts
after a summary consumes them. SessionEnd is matcher-less; the `clear` skip is
done in-script (robust to matcher semantics).

## Testing (`test-hooks.sh` additions)

New assertion blocks in the existing harness (which already builds inputs with
`jq` and asserts on captured stdout / side-effects):

**SessionStart**
- Valid payload `{hook_event_name:"SessionStart",source:"startup",cwd:$ROOT}` →
  output contains `"hookEventName":"SessionStart"`, `host=`, and `guards:`.
- Malformed input (`not json at all`) → silent, `exit 0`.

**SessionEnd** (using `WORKSTATION_NOTIFY` pointed at a recording stub that
appends its args to a file)
- Dirty temp git repo, `reason:"logout"` → stub file contains `uncommitted`.
- Clean committed temp repo → stub un-called (silent).
- Dirty repo, `reason:"clear"` → silent (no stub call).
- Malformed input → silent.

After editing, the whole suite (`bash .claude/hooks/test-hooks.sh`) must exit 0,
and `make -C makefile lint MODE=prod` must pass (shellcheck + `shfmt -i 2` over
the new scripts).

## Documentation

`CLAUDE.md` "Claude Code hooks (edit-time enforcement)" section gains two bullets
under the Repo list, framed as session-lifecycle (not edit-time) hooks:

- `session-context.sh` — SessionStart; injects the four-bucket context block;
  static interop probe; fail-open.
- `session-end-notify.sh` — SessionEnd; toasts on dirty/pending; reuses
  `notify.sh`; skips `/clear`.

The existing "Edit any hook → re-run test-hooks.sh" note and the
`check-invariants.sh` coverage line already apply to the new scripts (the
`.claude/hooks/*.sh` glob), so no other doc surface changes.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `chezmoi status` slow on a large tree blocks session open | `timeout`-bounded (4 s); segment dropped on timeout |
| SessionEnd `reason` strings differ from assumption | Confirm against docs at impl time; default-safe (unknown → proceed); only `clear` is suppressed |
| `notify.sh` absent (fresh clone / prod) | Fail-open `|| true`; no error |
| no-`jq` `printf` fallback emits invalid JSON | Block carries no `"`/`\`/control chars (the only chars needing JSON escaping); multibyte separators are valid content |
| New hooks regress LF/mode | Auto-covered by `check-invariants.sh` + `post-edit-guard.sh` |
