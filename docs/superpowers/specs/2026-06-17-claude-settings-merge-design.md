# Claude Code `settings.json` merge-on-apply — design

- **Date:** 2026-06-17
- **Status:** Approved (design); implementation pending
- **Topic:** Stop the two-writer thrash on `~/.claude/settings.json` by converting it from a chezmoi whole-file template into a `chezmoi:modify-template` merge that enforces infra keys while letting Claude Code own volatile keys.

## Problem

`~/.claude/settings.json` has **two writers that don't coordinate**:

1. **chezmoi** renders `chezmoi/private_dot_claude/private_settings.json.tmpl` and **replaces the whole file** on every `chezmoi apply` (`cza`).
2. **Claude Code itself** writes the same file at runtime when you change settings in-session (`/model`, theme, effort, etc.).

So in-app changes drift from the template and `cza` reverts them. Concretely: the live file has `"model": "opus[1m]"` (set in-session) while the template still says `"claude-fable-5"`, so `cza` would downgrade the model. The reordering also seen in `chezmoi diff` is cosmetic (chezmoi emits template key order; the live file has Claude Code's order) — only the `model` value actually differs today.

This is the same class of problem the repo already hit for the Windows Terminal / Zed / VSCode `settings.json` files, which it handles with "track static + `chezmoi re-add` on drift" (and explicitly rejected a merge script there as "overkill for one host"). For `~/.claude/settings.json` the merge approach is worth it: it eliminates the thrash with no manual discipline.

## Goal / non-goals

**Goal:** `cza` enforces the repo's infrastructure/safety keys identically on every dev machine, while never reverting the personal/volatile keys the user changes in-session; a fresh machine still comes up with sane defaults.

**Non-goals:**
- No new runtime dependency (no `jq`, no bash, no chezmoi `[interpreters]` config).
- Not changing `~/.claude/settings.local.json` (`{"spinnerTipsEnabled": false}`) — out of scope, stays as-is.
- Not changing the Windows Terminal / Zed / VSCode re-add pattern — only `~/.claude/settings.json`.

## Decision

Replace the static template `chezmoi/private_dot_claude/private_settings.json.tmpl` with a **`chezmoi:modify-template`** file `chezmoi/private_dot_claude/modify_private_settings.json` (target `~/.claude/settings.json`, mode 0600). A `modify_` file carrying the `chezmoi:modify-template` directive is processed by **chezmoi's own Go-template engine** (no external interpreter), with the current file content exposed as `.chezmoi.stdin`. It runs natively on every platform including the Windows dev host.

> **CRITICAL filename gotcha (verified the hard way):** the file must be named `modify_private_settings.json` with **NO `.tmpl` extension**. chezmoi docs: *"Modify templates must not have a `.tmpl` extension."* With a `.tmpl` suffix, chezmoi treats it as a `.tmpl` modify *script* (render the template, then **execute the output as a program**) — `.chezmoi.stdin` is absent during that render and you get `map has no entry for key "stdin"`, or, if it renders, `fork/exec … exec format error`. Dropping `.tmpl` switches chezmoi to modify-*template* mode where `.chezmoi.stdin` is injected and the rendered text becomes the file content. The `private_` prefix still applies (target mode 0600); the file is templated internally and never executed, so no shebang / executable bit is needed.

Verified on this host (chezmoi v2.70.5): `mergeOverwrite`, `fromJson`, `toPrettyJson`, `dict` are all available; `mergeOverwrite $a $b $c` applies left→right with later args winning; `toPrettyJson` sorts keys alphabetically (deterministic output, so no reorder-thrash); `modify_private_settings.json` resolves to target `.claude/settings.json`.

### Merge model (3 layers, later wins)

```
seed defaults  →  current file (.chezmoi.stdin)  →  enforced infra
   (lowest)            (your in-app changes)          (highest)
```

- **Seed defaults** fill a key only when it's absent from the current file (fresh machine bootstraps to good values).
- **Current file wins** over seeds → in-app changes (model, theme, …) persist across `cza`.
- **Enforced infra wins** over everything → hooks/plugins/statusLine/notification plumbing stay consistent.

### Key partition (approved)

**Enforced (chezmoi always wins):** `statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled`.

**Seed-once (Claude Code owns; chezmoi sets only when absent):** `model` (→ `opus[1m]`), `effortLevel` (→ `xhigh`), `theme` (→ `auto`), `editorMode` (→ `normal`), `tui` (→ `fullscreen`), `verbose` (→ `true`).

### Template body (the design artifact)

The enforced and seed blocks are written as **literal JSON** (backtick raw strings) and parsed with `fromJson` — far more readable/maintainable than building nested `dict`/`list` for the `hooks` tree. The `ccstatusline@<version>` pin lives in the enforced JSON string (its dual-edit invariant moves here from the old file).

The `chezmoi:modify-template` marker **must be on its own line** — chezmoi deletes any line containing that literal, then templates the rest; embedding it in a multi-line comment would orphan the comment's tail. Keep it as the bare first line, with any explanation in a *separate* comment below it:

```
{{- /* chezmoi:modify-template */ -}}
{{- /* Merge enforced infra keys over the live ~/.claude/settings.json, seeding
       personal keys only when absent. Buckets + rationale:
       docs/superpowers/specs/2026-06-17-claude-settings-merge-design.md */ -}}
{{- $seed := `{
  "model": "opus[1m]",
  "effortLevel": "xhigh",
  "theme": "auto",
  "editorMode": "normal",
  "tui": "fullscreen",
  "verbose": true
}` | fromJson -}}
{{- $current := dict -}}
{{- if .chezmoi.stdin -}}{{ $current = .chezmoi.stdin | fromJson }}{{- end -}}
{{- $enforced := `{
  "statusLine": {
    "type": "command",
    "command": "npx -y ccstatusline@2.2.19",
    "refreshInterval": 10
  },
  "skipAutoPermissionPrompt": true,
  "skipWorkflowUsageWarning": true,
  "remoteControlAtStartup": true,
  "agentPushNotifEnabled": true,
  "inputNeededNotifEnabled": true,
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|Read|Bash",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/hooks/secret-guard.sh\"" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/hooks/dangerous-command-guard.sh\"" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/notify.sh\" 'Claude Code' 'needs your approval' < /dev/null" }
        ]
      },
      {
        "matcher": "idle_prompt",
        "hooks": [
          { "type": "command", "command": "\"$HOME/.claude/notify.sh\" 'Claude Code' 'waiting for your next prompt' < /dev/null" }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "claude-code-setup@claude-plugins-official": true,
    "microsoft-docs@claude-plugins-official": true,
    "hookify@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "github@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true
  }
}` | fromJson -}}
{{ mergeOverwrite $seed $current $enforced | toPrettyJson }}
```

Notes on merge semantics (sprig `mergeOverwrite`): it deep-merges maps and **replaces arrays** (does not append). So enforced `hooks.PreToolUse` / `hooks.Notification` arrays fully replace whatever the live file had — enforced hooks win cleanly. `enabledPlugins` deep-merges: the 8 listed plugins are forced `true`; any extra plugin the user enabled is preserved.

## Cross-platform

Pure Go template → chezmoi renders it natively on Linux, WSL, and the Windows dev host. No shebang, no `jq`, no bash, no `[interpreters]` config. (`~/.claude/settings.json` is gated to `dev_machine` only — ignored on `prod_machine` via `.chezmoiignore.tmpl` — and is NOT in the Windows-ignore block, so it does deploy on the Windows dev host; the Go-template approach is what makes that safe.)

## Migration (existing hosts)

Self-migrating. On the first `cza` after this lands, the modify-template runs with the host's **current** `settings.json` as `.chezmoi.stdin`: enforced keys are applied, and the user's existing personal values (e.g. `model: opus[1m]`) win over the seeds and are preserved. No manual step. The old `private_settings.json.tmpl` is deleted in the same commit (a target can't be both a regular file and a modify file).

## Error handling / edge cases

- **Fresh machine (no file):** `.chezmoi.stdin` empty → guard leaves `$current` an empty dict → output = seed defaults + enforced. Verified the guard pattern renders `{}` rather than erroring.
- **Malformed live JSON:** `fromJson` would error and fail `cza` on this one file. Accepted risk — Claude Code always writes valid JSON; documented, not guarded (YAGNI).
- **ccstatusline interaction:** `setup-ccstatusline.sh`'s `option_set_global` still must not write `settings.json`. With the modify-template, even a stray `statusLine` block in the live file is overridden by the enforced one on apply — strictly more robust than before.

## Documentation / invariant updates (filename + semantics change)

The source filename changes (`private_settings.json.tmpl` → `modify_private_settings.json`) and the "hand-managed, whole-file" invariant becomes a "merge: enforced wins, seed/personal preserved" invariant. Update every reference:

- `scripts/check-invariants.sh` — the `CCSTATUSLINE_VERSION` dual-edit check greps `chezmoi/private_dot_claude/private_settings.json.tmpl` for `ccstatusline@<v>`; repoint to the new filename. (Re-run `make lint MODE=prod` after.)
- `CLAUDE.md` — the "`~/.claude/settings.json` is hand-managed via the chezmoi template" invariant (rewrite for merge semantics); the two `CCSTATUSLINE_VERSION` dual-edit references; the "Single-source-of-truth files" line; the hooks bullet that says "wired in `private_settings.json.tmpl`". (Filename + the enforced/seed split.)
- `docs/claude/invariants.md` — the "settings.json hand-managed" entry (rewrite) and the `CCSTATUSLINE_VERSION` dual-edit entry (filename).
- `docs/claude/file-care.md` — the `private_settings.json.tmpl` entry: rewrite for the modify-template (enforced vs seed buckets, merge precedence, the `fromJson`/`mergeOverwrite`/`toPrettyJson` mechanics, the empty-stdin guard, the malformed-JSON caveat).
- `CLAUDE_CHANGELOG.md` — append a row; README column **No** (Claude-internal config; per CLAUDE.md "edits to Claude-internal files" need no README update).

**No `README.html` change** — `settings.json` management is Claude-internal, not user-facing surface.

## Testing

chezmoi runs the modify-template against a **destination** file, so tests craft a scratch destination and assert the merged output via `--destination` + an explicit path (note: a literal `~` is expanded by the calling shell against the *real* HOME before the per-command `HOME=` applies, so pass the full scratch path, not `~/...`):

```sh
scratch=$(mktemp -d); mkdir -p "$scratch/.claude"
# case: existing personal model preserved, enforced statusLine forced
printf '{"model":"sonnet","theme":"auto","statusLine":{"command":"STALE"}}' > "$scratch/.claude/settings.json"
HOME="$scratch" chezmoi --source "$PWD/chezmoi" --destination "$scratch" \
  cat "$scratch/.claude/settings.json"
```

This exact harness was used to validate the design pre-spec (fresh/missing → seed `model=opus[1m]` + enforced; `model=sonnet` preserved; stale `statusLine` overridden to the real `ccstatusline@…`; unrelated `myCustomKey` preserved; output keys alphabetical).

Assertions across cases:
- **Missing file:** output has `model=opus[1m]` (seed) + all enforced keys; valid JSON.
- **Personal override:** input `model=sonnet` → output keeps `model=sonnet` (current beats seed).
- **Stale enforced:** input `statusLine.command=STALE` → output has the real `npx -y ccstatusline@…` (enforced beats current).
- **Extra user key:** an unrelated key in the input is preserved.
- Output parses as JSON (`| python3 -m json.tool` or chezmoi's own render succeeding).

Plus the standard post-edit checks: `chezmoi cat ~/.claude/settings.json` on this host renders and preserves the live `model`; `chezmoi diff ~/.claude/settings.json` shows only intended changes; `make lint MODE=prod` clean (incl. the repointed ccstatusline check).

## Rollback

Restore `private_settings.json.tmpl` and delete `modify_private_settings.json` (single revert), reverting the doc/check-invariants edits with it. No persisted state; nothing external changes.
