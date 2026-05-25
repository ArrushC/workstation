# ccstatusline dev-install integration — design

**Date:** 2026-05-25
**Status:** Approved (design phase). Awaiting written-spec review before
implementation planning.
**Scope:** Linux dev_machine hosts (incl. WSL). Out-of-scope: Windows
bootstrap.ps1, prod_machine, Node.js as a managed tool.

## 1. Context

The repo provisions Claude Code (`claude-cli`) in `MODE=dev` only, via a
bespoke Makefile rule that runs the official installer. Today the binary
lands at `~/.local/bin/claude` and **nothing else happens** — no status
line is configured, no chezmoi-tracked Claude Code settings file exists.

[`ccstatusline`](https://github.com/sirmalloc/ccstatusline) is a
status-line formatter for Claude Code CLI. Its config lives at
`~/.config/ccstatusline/settings.json` (widgets, layout, colors), and it
hooks into Claude Code via a `statusLine` block inside
`~/.claude/settings.json`.

The goal is to wire ccstatusline into the dev-install flow such that:
- Fresh dev hosts get a working, visually consistent status line.
- Hosts can opt out of the shared look (local-only configuration) without
  fighting chezmoi sync.
- Updating the shared statusline is a single TUI session plus an automatic
  commit + push back to this repo.
- The user is always asked at the prompt — never silently configured.

## 2. Goals & non-goals

**Goals**
- After `bootstrap.sh --dev` succeeds, prompt the user with four options:
  1. Use the same chezmoi-tracked status line as everywhere else.
  2. Define a new status line for **this machine** only — with a follow-up
     "persist across `chezmoi update`? (y/N)" sub-prompt.
  3. Set a new **global** status line (configure interactively, then
     publish via chezmoi + git push).
  4. Skip — do nothing this run.
- Track both `~/.config/ccstatusline/settings.json` AND the `statusLine`
  block of `~/.claude/settings.json` under chezmoi, so visual parity is
  reproducible from a fresh clone.
- Pin the ccstatusline runtime version in `versions.mk` for repeatability.
- Stay re-runnable: `make claude-statusline` outside of bootstrap works
  identically and surfaces the same menu.

**Non-goals**
- Managing Node.js / Bun in this repo. ccstatusline requires Node 18+ at
  runtime; the user installs Node themselves. The script preflight-checks
  `npx`; missing-npx is non-fatal (message + exit 0).
- Tracking any other `~/.claude/` config beyond the `statusLine` block.
  Per Claude Code conventions, other user-level settings (env, plugins,
  allowlists) live in `~/.claude/settings.local.json` which stays
  untracked.
- Windows / `bootstrap.ps1` integration. WSL hosts (which are
  `dev_machine` via the existing Linux flow) are covered.
- A `prod_machine` code path. The Make target is `ifeq ($(MODE),dev)`
  gated, same shape as `claude-cli`.
- chezmoi data-variable templating for the version (the literal mirrors
  `versions.mk` and a "dual edit" note in CLAUDE.md documents the
  invariant — see §10).

## 3. Architecture

```
bootstrap.sh --dev (tail, after ensure_chezmoi_initialized)
  └─ make -C makefile claude-statusline MODE=dev      (re-runnable any time)
       └─ scripts/setup-ccstatusline.sh
            ├─ preflight: command -v npx ; chezmoi config present
            ├─ detect: is current host inside the sentinel block?
            │          does the tracked widget config have content?
            ├─ menu: 1) use tracked  2) this machine  3) set new global  4) skip
            └─ branch (see §6 table)
```

Re-runnable: `make claude-statusline` works post-install. bootstrap.sh's
call is purely convenience.

## 4. Files touched

| Path | New / edit | Mode | Purpose |
|---|---|---|---|
| `scripts/setup-ccstatusline.sh` | **new** | 100755 LF-only | The orchestrator. Pure bash. |
| `makefile/Makefile` | edit | — | New `.PHONY: claude-statusline` target, dev-gated, invokes the script. |
| `makefile/versions.mk` | edit | — | `CCSTATUSLINE_VERSION := <pin>` — implementation picks the value (latest stable at impl time, e.g. `2.2.19`). |
| `bootstrap.sh` | edit | — | After `ensure_chezmoi_initialized`, call `make -C makefile claude-statusline MODE=dev` (use `-C` not `cd && make` — bootstrap.sh stays in the repo root). Tail-tip text mentions that re-running it later is `make -C makefile claude-statusline MODE=dev` from the repo root or `cd makefile && make claude-statusline MODE=dev`. |
| `chezmoi/dot_config/ccstatusline/settings.json` | **new** | 0644 | Tracked widget config. Initial commit is `{}` (empty template — first "set new global" populates it). |
| `chezmoi/private_dot_claude/private_settings.json.tmpl` | **new** | 0600 file, 0700 dir | Tracked Claude Code user settings with the `statusLine` block. Version literal mirrors `versions.mk`. |
| `chezmoi/.chezmoiignore.tmpl` | edit | — | Add managed `# CCSTATUSLINE:START / END` sentinel block. Hosts inside the block get the widget config ignored by chezmoi for that host. |
| `CLAUDE.md` | edit | — | Document the new sentinel block (alongside wezterm/hosts), the `versions.mk` ↔ `.tmpl` dual-edit invariant, the new files in "Files Claude should be careful with". |
| `README.html` | edit | — | Document the new prompt at the end of `bootstrap.sh --dev` (likely §setup-linux or §daily). |
| `CLAUDE_CHANGELOG.md` | edit | — | Append a row per repo convention. |

## 5. State machine — the sentinel block

`.chezmoiignore.tmpl` gains:

```
# CCSTATUSLINE:START
{{ if eq .chezmoi.hostname "host-a" -}}
.config/ccstatusline/settings.json
{{ end -}}
{{ if eq .chezmoi.hostname "host-c" -}}
.config/ccstatusline/settings.json
{{ end -}}
# CCSTATUSLINE:END
```

The single source of truth for "is this host persisting locally?" lives
between the markers. Each persisting host gets a 3-line stanza.

Three primitives in `setup-ccstatusline.sh` manage the block:
- `sentinel_contains <host>` — bool. Drives the menu's current-state hint
  (`[currently: tracked]` / `[currently: local-persist]` / `[currently:
  ephemeral or not-configured]`).
- `sentinel_add <host>` — idempotent insert; sorts entries alphabetically
  for stable diffs.
- `sentinel_remove <host>` — idempotent strip.

These primitives operate on a single file in-place using sed/awk with
explicit BEGIN/END markers, mirroring the existing pattern in
`scripts/manage-hosts.sh` for the wezterm SSH-domains block.

## 6. The 4-option flow

| # | Label | TUI? | Sentinel | chezmoi action | Git action |
|---|---|---|---|---|---|
| 1 | use tracked | no | strip host | `chezmoi apply ~/.config/ccstatusline/settings.json ~/.claude/settings.json` | none |
| 2a | this machine + persist=y | yes | add host | none (chezmoi will skip widget config on this host going forward) | none |
| 2b | this machine + persist=n | yes | no change | none (next `chezmoi update` overwrites widget config) | none |
| 3 | set new global | yes | strip host | `chezmoi re-add ~/.config/ccstatusline/settings.json ~/.claude/settings.json` | `git add chezmoi/dot_config/ccstatusline/settings.json chezmoi/private_dot_claude/private_settings.json.tmpl`; commit with subject `feat(claude): update ccstatusline tracked config` (templated by the script, single-line via HEREDOC body with the standing `Co-Authored-By` trailer); push to the tracked upstream (per the always-push rule) |
| 4 | skip | no | no change | none | none |

Notes:
- Option 1 with an empty tracked widget config prints `tracked widget
  config is empty — pick option 3 first to seed it` and exits 0. Avoids
  applying an empty `{}` over an existing local config.
- Option 2 always launches the TUI before the persist sub-prompt. If the
  TUI exits non-zero or is killed (Ctrl+C), the sentinel is untouched and
  the run is treated as a skip.
- Option 3 also strips the current host from the sentinel if it was
  there. Logic: setting a new global overrides any prior "local persist"
  decision the user made on this machine.
- Option 3's git push respects the standing
  `feedback-always-push-after-commit` memory: after the commit lands, we
  push automatically. If `git push` fails (auth, branch protection,
  divergent remote), surface the error and exit non-zero — do **not**
  auto-revert the chezmoi re-add or the commit.

## 7. Runtime — how ccstatusline is invoked

The chezmoi-tracked `private_settings.json.tmpl` (deployed to
`~/.claude/settings.json`) holds:

```json
{
  "statusLine": {
    "type": "command",
    "command": "npx -y ccstatusline@X.Y.Z",
    "refreshInterval": 10
  }
}
```

`X.Y.Z` is the literal value of `CCSTATUSLINE_VERSION` in `versions.mk`.
They MUST stay in sync — a sentence in CLAUDE.md "Files Claude should be
careful with" documents this dual-edit invariant. Future iteration could
replace this with a chezmoi data variable
(`.chezmoi.data.ccstatusline_version`) seeded from `versions.mk`; deferred
to keep initial scope tight (see §10).

`refreshInterval: 10` (seconds) matches the ccstatusline-recommended
default on Claude Code ≥ 2.1.97. Older Claude Code ignores the field.

## 8. Preflight & error handling

- **`command -v npx`** → if missing, print:
  `"npx not found — install Node.js (e.g. dnf install -y nodejs / apt
  install nodejs npm) and re-run \`make claude-statusline\`"` then exit 0.
  Bootstrap continues. Non-fatal.
- **chezmoi config missing** (`~/.config/chezmoi/chezmoi.toml`) → print
  hint pointing at `bootstrap.sh --dev` and exit 1. Shouldn't happen in
  the bootstrap path; defensive for direct `make claude-statusline` use.
- **TUI non-zero exit / Ctrl+C** → treat as skip; revert any pre-emptive
  sentinel writes; exit 0.
- **Option 3, `git push` fails** → leave the chezmoi re-add intact, leave
  the commit, surface stderr, exit non-zero. The user resolves manually
  (auth, branch, etc.) and re-pushes. Do not auto-revert — the commit may
  still be valuable locally.
- **Option 1, no tracked widget config** → print
  `"tracked widget config is empty — pick option 3 first to seed it"` and
  exit 0. (See §6 notes.)
- **Non-dev MODE** → Make target is dev-gated, identical shape to
  `claude-cli`. The target is always declared (so `make help` lists it)
  but the recipe body checks `MODE` at the top and exits early with
  `"claude-statusline is a dev_machine target — skipping (MODE=$(MODE))"`
  on non-dev. Avoids the bare "No rule to make target" error a pure
  `ifeq` guard would produce.
- **WSL** → works identically to native Linux. `is_wsl()` does NOT gate
  the prompt. Claude Code is installed on WSL hosts (per existing
  `claude-cli` rule) so ccstatusline is relevant there too.

## 9. Verification recipe

(Used as the implementation's acceptance gate.)

1. `cd makefile && make claude-statusline MODE=prod` — should error (dev-gated).
2. `cd makefile && make claude-statusline MODE=dev` on a host where `command -v npx` fails — script prints the install hint and exits 0; no files touched.
3. After installing Node, re-run — menu appears; pick option 4 → exit 0, no diff.
4. Pick option 1 with the tracked widget config still `{}` → prints "tracked is empty" hint; exit 0; no diff.
5. Pick option 3 → TUI launches; configure something visible (e.g. add the Model widget); save. Verify:
   - `chezmoi/dot_config/ccstatusline/settings.json` has content.
   - A new commit exists with the file change.
   - `git log -1 --pretty=%s` matches the commit-subject convention (`feat(claude): seed ccstatusline widget config` or similar).
   - The push to `origin/main` succeeded.
6. On a second host, run `make claude-statusline MODE=dev` and pick option 1 → tracked file syncs cleanly; `chezmoi diff` is clean; `~/.config/ccstatusline/settings.json` has the same content as host #1 wrote.
7. On host #2, pick option 2 + persist=y → sentinel block now lists host #2's hostname; a subsequent `chezmoi apply` is a no-op on the widget config; `chezmoi diff` clean.
8. Back to option 1 on host #2 → sentinel stripped; tracked file restored.
9. `./scripts/manage-hosts.sh --sync` still works (the new CCSTATUSLINE sentinel doesn't conflict with the existing wezterm one in `chezmoi/dot_config/wezterm/wezterm.lua` or with the manage-hosts SSH-domains block).
10. `file scripts/setup-ccstatusline.sh` → `LF` line endings only (no CRLF).
11. `git ls-files --stage scripts/setup-ccstatusline.sh` → `100755`.
12. `bootstrap.sh --dev` on a fresh dev VM → prompt appears between `ensure_chezmoi_initialized` and the final completion banner.
13. `bootstrap.sh --dev` inside WSL → prompt also appears (WSL is not gated out).

## 10. Open questions / deferred decisions

- **Version templating.** Today: dual-edit `versions.mk` + the chezmoi
  `.tmpl`. Could be replaced with a chezmoi data variable
  (`.chezmoi.data.ccstatusline_version`) set from `versions.mk` at first
  bootstrap. Deferred — adds chezmoi config complexity. Revisit when we
  next bump the pin and find ourselves editing both files.
- **Node.js as a managed tool.** Out of scope for this design. Worth its
  own design (Bun-via-EGET_TOOL is the most natural fit; supports
  `bunx ccstatusline` as an alternative runtime).
- **Tracking the rest of `~/.claude/settings.json`** (plugins, env,
  permission allowlist). Out of scope. The project-scope `.claude/`
  inside this repo is a separate concern. User-level `~/.claude/`
  tracking starts with the `statusLine` block and grows on demand.

## 11. CLAUDE.md / README.html implications

(Per the decision-test documented in CLAUDE.md: "Would a user reading
only README.html still be able to operate this repo after my change?")

- **README.html** — yes, must update. The user-facing surface gains a
  new prompt at the end of `bootstrap.sh --dev`, plus a new daily-workflow
  entry-point (`make -C makefile claude-statusline MODE=dev`). Update
  §daily and §setup-linux; add a CLAUDE_CHANGELOG row.
- **CLAUDE.md** — yes. New invariants to document:
  - CCSTATUSLINE sentinel block in `.chezmoiignore.tmpl` — managed
    between markers, hand-edits inside get clobbered (mirror wezterm
    sentinel language).
  - `versions.mk` ↔ `private_dot_claude/private_settings.json.tmpl`
    dual-edit invariant for `CCSTATUSLINE_VERSION`.
  - New files in "Files Claude should be careful with":
    `scripts/setup-ccstatusline.sh` (LF-only, 100755),
    `chezmoi/private_dot_claude/private_settings.json.tmpl` (mirror
    pinned version).
