# WezTerm nightly via mirrored weekly snapshots — design

**Date:** 2026-07-16
**Status:** approved (brainstorm → design conversation, this session)
**Scope:** new `.github/workflows/wezterm-nightly.yml` + `scripts/bump-wezterm-nightly.sh`;
`bootstrap.ps1` (WezTerm `$PortableTools` entry, one `-CheckForUpdates` branch, and one
contained opt-in auth-download branch in `Install-PortableTool` — see decision 4);
vendored `chezmoi/dot_local/share/wezterm/wezterm.terminfo` refresh; comment sweep in
`chezmoi/dot_config/wezterm/`; README/CLAUDE.md/file-care/invariants/changelog updates.

## Context

The Windows WezTerm install is pinned to stable `20240203-110809-5046fc22` —
still the latest stable as of 2026-07-16 (verified via the GitHub API); upstream
has shipped 2.5 years of improvements only on the rolling `nightly` release.
The user wants to move to nightly.

**The rolling-asset problem (drives the whole design):** upstream keeps exactly
ONE `nightly` release whose `WezTerm-windows-nightly.zip` is overwritten
near-daily (asset `updated_at` 2026-07-16T09:03Z at design time), and old
nightlies are **not downloadable**. A repo-recorded sha256 against the upstream
URL goes stale within ~a day, hard-failing every fresh bootstrap; dropping the
sha entirely abandons the repo's pinned+verified ethos and any rollback story.

**Facts verified during design (2026-07-16):**
- GitHub's API exposes a per-asset sha256 `digest` on the nightly asset — the
  same verification source `$InstallerTools` already uses.
- The nightly changelog section ("Continuous/Nightly", ~330 lines) contains **no
  breaking changes for this config** (closest: Copy Mode `Close` no longer
  implicitly scrolls to bottom — harmless, `copy_all_scrollback` explicitly
  moves to bottom before closing; `show_update_window` deprecated — not set).
- `config/src/lua.rs` on main still does NOT add the config file's directory to
  `package.path` — the module-split entry shim stays load-bearing.
- Upstream `termwiz/data/wezterm.terminfo` changed since 20240203 (2025-05-03
  "Advertize the Su capability too") — the vendored copy is stale vs nightly.
- **`ArrushC/workstation` is PRIVATE** — release assets 404 on the plain
  `releases/download/...` URL without auth; downloading requires the API asset
  endpoint with a token. Bootstrap already mandates `$env:GITHUB_TOKEN` on
  fresh machines (the private-repo clone step), so the token is present.

## Decisions (user-confirmed)

1. **Architecture: mirrored weekly snapshot.** A weekly workflow re-hosts the
   current nightly zip as a dated, immutable release asset on
   `ArrushC/workstation` and PRs an ordinary pin bump. Rejected alternatives:
   live-digest rolling install (no reproducibility, no rollback, new install
   machinery); workflow-recorded digest without a mirror (repo sha not
   load-bearing, fresh bootstraps drift from the recorded build).
2. **Terminfo auto-sync** in the same workflow (vs manual re-vendor or one-time
   refresh).
3. Update cadence = weekly PR + `workflow_dispatch` for on-demand; updates land
   on the Windows box via the normal "merge → re-run bootstrap" pin-bump flow.
4. **Private mirror → opt-in auth-download branch in `Install-PortableTool`**
   (user-confirmed after the visibility discovery): new `PrivateRepo` field on
   the WezTerm entry; when present AND the pinned `Url` points into that repo,
   the download resolves the asset id by name via the GitHub API and fetches
   through the asset endpoint with `Authorization: Bearer $env:GITHUB_TOKEN` +
   `Accept: application/octet-stream` (plain auto-redirect download — .NET
   Framework strips the Authorization header on the redirect hop, verified
   live; a manual -MaximumRedirection 0 capture is impossible on PS 5.1,
   which throws with a null Response).
   Absent token → warn-and-skip, the download-failure posture. Sha256 verify
   unchanged. Rejected: a separate public mirror repo (cross-repo PAT secret +
   second repo to maintain) and dropping the mirror (loses reproducibility +
   rollback — the reasons it was chosen).
   **Amendment (2026-07-16, post-migration, user-directed):** the gh CLI is
   promoted to a Windows hard prerequisite (like Git; preflight hard-fails if
   absent or unauthenticated) and becomes the token source — `gh auth token`
   honors a set `GITHUB_TOKEN` (token-only/CI flows unchanged) and otherwise
   returns the stored `gh auth login` credential, so fresh machines
   browser-login once instead of managing a PAT, and existing boxes' re-runs
   need no session token at all.

## Design

### 1. Workflow: `.github/workflows/wezterm-nightly.yml`

Weekly cron `0 7 * * 1` (Mondays 07:00 UTC — an hour after
`version-bumps.yml`'s `0 6 * * 1`, so the PRs don't collide) +
`workflow_dispatch`. Separate PR from the versions.mk bumps — a broken nightly
must never block toolbelt bumps.

**Job A — validate & identify (windows-latest):**
1. Resolve `repos/wez/wezterm/releases/tags/nightly`; capture the Windows zip
   asset's `browser_download_url`, `updated_at`, and `digest`.
2. Download; verify sha256 against `digest` (hard-fail mismatch; warn+proceed
   into the PR body if the digest is absent — the established installer-class
   posture).
3. Extract; run `wezterm.exe --version` → the real build string (e.g.
   `20260716-081015-abc123`) — this becomes the pin `Version`.
4. **Config smoke gate:** `wezterm.exe --config-file
   chezmoi/dot_config/wezterm/wezterm.lua show-keys` against the checked-out
   repo. Non-zero exit or `error:` output → the workflow FAILS and no PR is
   created. (Runner has no WSL — `wezterm.default_wsl_domains()` returns an
   empty list; the config handles 0 distros by design.) This is the tripwire
   that makes riding nightly safe.
5. Early-exit success (no PR) when the resolved build == the currently pinned
   `Version` in `bootstrap.ps1`.

**Job B — mirror & PR (needs Job A; ubuntu):**
1. Upload the verified zip (passed as a job artifact) to the
   `wezterm-nightly-snapshots` release on `ArrushC/workstation` as
   `WezTerm-windows-<version>.zip`; **prune to the newest 8 snapshots**
   (~70MB each → ~560MB ceiling, ~2 months of rollback depth). Workflow
   permissions: `contents: write` (release assets + PR branch).
2. Run `scripts/bump-wezterm-nightly.sh <version> <mirror-url> <sha256>` —
   rewrites the `Version`/`Url`/`Sha256` lines inside the WezTerm
   `$PortableTools` entry, anchored to the entry (between `Name       =
   "WezTerm"` and the entry's closing brace). Must be BOM-safe (edits are not
   at file start; verify `EF BB BF` retained) and must not re-wrap other lines.
   Lives in `scripts/` so it is shellcheck/shfmt-covered by
   `check-invariants.sh` (LF + 0755).
3. **Terminfo sync:** fetch `termwiz/data/wezterm.terminfo` from upstream main;
   if the payload differs from the vendored
   `chezmoi/dot_local/share/wezterm/wezterm.terminfo` (ignoring the provenance
   header), replace it and update the leading `#` provenance comment to the
   upstream commit hash + date (the file-care provenance convention; "pinned
   tag" becomes "workflow-synced snapshot"). Per-host propagation is already
   handled by the self-healing `run_` re-tic script on the next `cza`.
4. Open the PR (same bot/branch/label conventions as `version-bumps.yml`):
   title `chore(wezterm): nightly snapshot <version>`; body records the
   upstream `updated_at`, the digest source (or its absence), the smoke-gate
   result, and whether terminfo was refreshed.

### 2. `bootstrap.ps1` (small, additive)

- **WezTerm `$PortableTools` entry:** `Version` = nightly build string, `Url` =
  the immutable mirror asset, `Sha256` = the snapshot hash, plus the new
  `PrivateRepo`/`NightlyAsset` fields. Stamp-name change
  (`wezterm.<version>.stamp`) triggers the reinstall exactly like any pin bump.
  The existing tree-wipe locked-file warn covers "bootstrap re-run from inside
  WezTerm" (close WezTerm, re-run from Windows Terminal/Nushell; self-heals on
  a later run).
- **`Install-PortableTool` gains ONE contained branch** (decision 4): the
  `PrivateRepo` auth download. Everything else (stamp, sha verify, layouts,
  PATH, shortcuts) is untouched.
- **New opt-in field `NightlyAsset`** (WezTerm only): its presence routes the
  tool's `-CheckForUpdates` row away from `Get-LatestGitTag` (meaningless for a
  rolling tag) to the nightly release's asset `updated_at`:
  `snapshot <pinned version> · upstream nightly updated <date>` — hinting
  "dispatch wezterm-nightly.yml or wait for the weekly PR". The now-dead
  `TagFilter`/`TagSort` keys on the WezTerm entry are removed; `UpdateHint`
  rewritten (the old one said the pin tracks the vendored-terminfo tag).
- `-Doctor` needs no change (stamp-based rows).

### 3. Config comment sweep (`chezmoi/dot_config/wezterm/`)

- `appearance.lua` `check_for_updates` block: stays `false`; rationale
  rewritten — the update channel is now the weekly workflow, and the in-app
  toast is noise on nightly builds. (The old comment cites the 20240203 pin.)
- "20240203" references become floor/verified-through statements. Two
  source-level claims get re-verified against main during implementation and
  their comments updated with the verification date: the SHIFT+click
  `inputmap.rs` default-bindings analysis (`keys.lua`) and the `package.path`
  claim in the entry file (already re-confirmed on main at design time).
- The `pane.current_working_dir` "(20240203+)" note in `tabs.lua` stays
  correct as a floor.

### 4. Docs

- **CLAUDE.md:** the Windows-installs invariant sentence "WezTerm's pin tracks
  the vendored-terminfo tag" → "WezTerm rides nightly via mirrored snapshots:
  the pin (Version/Url/Sha256 → `wezterm-nightly-snapshots` release assets)
  AND the vendored terminfo are both bumped by `.github/workflows/
  wezterm-nightly.yml`, never by hand."
- **docs/claude/file-care.md:** `bootstrap.ps1` entry — WezTerm is the
  workflow-bumped exception among the pinned portable tools; wezterm.terminfo
  entry — vendoring provenance is now a snapshot commit, refreshed by the
  workflow (manual re-vendor recipe stays as fallback).
- **docs/claude/invariants.md:** `config.term` chain gains the workflow as the
  terminfo-refresh mechanism; note the four artifacts still move together.
- **README.html §setup-windows:** WezTerm tool entry — pinned-stable wording →
  weekly nightly snapshot (mirror, smoke gate, how updates land); §stack if it
  names the WezTerm version. **§troubleshooting: new entry "Roll back a bad
  WezTerm nightly"** — flip the `$PortableTools` pin to any retained snapshot
  asset (immutable mirror URLs; last 8 kept) or to the stable
  `20240203` upstream URL (release assets on real tags are immutable forever),
  then re-run bootstrap; optionally revert the weekly PR.
- **CLAUDE_CHANGELOG.md:** one row.

### 5. Migration sequence

1. Land the implementation PR (workflow + bump script + bootstrap.ps1 +
   comments + docs). The WezTerm pin in that PR is still stable 20240203 —
   the flip happens via the workflow so the first bump exercises the real path.
2. `workflow_dispatch` `wezterm-nightly.yml` → first snapshot + first pin-bump
   PR; review + merge.
3. Windows box: `git pull` the chezmoi clone, **close WezTerm**, ensure
   `$env:GITHUB_TOKEN` is set (already required on this private-repo machine),
   run `.\bootstrap.ps1` from Windows Terminal/Nushell → nightly installs via
   the auth path; Start Menu shortcut self-heals; `WEZTERM_CONFIG_FILE`
   unchanged.
4. Linux hosts: next `czu && cza` re-tics the refreshed terminfo
   (self-healing; verify `infocmp wezterm` lists `Su` on one host).
5. Live checks on the nightly build: config loads (reload toast), tab bar +
   right status render, SHIFT+click link-open still works (mouse-default
   re-verify), Zellij attach over SSH domains, kitty graphics in yazi.

## Risks

- **Nightly regressions show-keys can't catch** (rendering, input, runtime):
  weekly-not-daily cadence limits exposure; rollback is one re-pin + bootstrap
  re-run. The A/B history rule stands — any perceived-latency change on the
  nightly gets investigated before blaming config.
- **GitHub digest absent** on some future asset: warn+proceed, recorded in the
  PR body (installer-class posture); the mirrored asset still gets OUR sha256
  in the pin, so machines always verify.
- **Upstream rename of the nightly asset**: Job A fails loudly (asset lookup),
  no PR; fix the workflow's asset match.
- **Mirror bloat**: prune-to-8 in Job B.

## Out of scope

Adopting new nightly-only config features (OSC 9;4 progress, `wezterm.serde`,
`is_last_active`, `input_selector_label_*` colors, …) — candidates for a later
pass once nightly is running. Linux WezTerm installs (still none). Per-host
render tuning (standing no-go).
