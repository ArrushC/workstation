# WSL dynamic memory reclaim + sparse VHD — design

**Date:** 2026-06-12
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

Request: make the repo's WSL configuration guarantee (1) dynamic memory usage
(`autoMemoryReclaim`) and (2) automatic return of freed disk space to Windows
(sparse VHD, via `wsl --manage <Distro> --set-sparse true`).

## Findings (investigation, 2026-06-12)

1. **The memory half is already implemented.** `chezmoi/dot_wslconfig` (the
   tracked `%USERPROFILE%\.wslconfig`, seeded verbatim from the Windows host in
   `07e50ca`) already carries `autoMemoryReclaim=Gradual` and `sparseVhd=true`
   under `[experimental]`.
2. **`[experimental]` is the correct section**, not `[wsl2]` as the request's
   snippet suggested: per current MS Learn docs
   (<https://learn.microsoft.com/windows/wsl/wsl-config>), `autoMemoryReclaim`
   and `sparseVhd` are documented only under `[experimental]`. Current WSL also
   defaults `autoMemoryReclaim` to `dropCache`, so reclaim is on even without
   the key; `gradual` pins the gentler slow-trim behavior.
3. **Sparse VHD is upstream-disabled for safety.** On WSL ≥ 2.5/2.6 (this host:
   2.6.2.0), `wsl --manage <Distro> --set-sparse true` is refused with *"Due to
   potential data corruption, sparse VHD support is currently disabled"* and
   only proceeds with an explicit `--allow-unsafe` flag
   (microsoft/WSL#13075, #12103 — real corruption reports: read-only
   filesystems, lost files). The tracked `sparseVhd=true` is currently inert
   for the same reason.
4. **Host state verified:** the AlmaLinux-9 `ext4.vhdx` (5.6 GB,
   `%LOCALAPPDATA%\wsl\{guid}\`) is NOT sparse (`Attributes: Archive`, no
   `SparseFile`). This host's `wsl --manage` offers only `--move` and
   `--set-sparse` — no safe `--compact` subcommand exists; offline compaction
   (`Optimize-VHD` / diskpart) requires admin.

## Decision (user-approved)

**Document, don't automate.** Do not run `--set-sparse` (with or without
`--allow-unsafe`) from bootstrap/make — it would override a deliberate
upstream safety disablement. Keep `sparseVhd=true` tracked (it self-activates
for newly created VHDs if Microsoft re-enables the feature) and document the
manual recipes in README.

Rejected alternatives:
- *Automate with `--allow-unsafe`* (bootstrap.ps1 or a make target invoking
  `wsl.exe` via interop) — knowingly opts every host into a corruption-prone
  code path; one-time disk savings don't justify it.
- *Drop sparse entirely* (remove `sparseVhd=true`) — loses the free automatic
  re-enable if a fixed sparse mode ships later; the inert key costs nothing.

## Design

### Part A — `chezmoi/dot_wslconfig`: annotate; semantics unchanged

- Comment above `autoMemoryReclaim=gradual`: reclaims cached VM memory back to
  Windows (`gradual` = slow trim; WSL's default is the more aggressive
  `dropCache`); note these keys are `[experimental]`-section keys, NOT
  `[wsl2]`.
- Comment above `sparseVhd=true`: applies to newly created VHDs only; inert on
  WSL ≥ 2.5 (sparse support upstream-disabled over data-corruption reports);
  kept so it takes effect if re-enabled; see README §troubleshooting for
  manual reclaim of an existing VHD.
- Normalize `Gradual` → `gradual` (cosmetic doc parity; parsing is
  case-insensitive).
- Expected side effect: the embedded sha256 in
  `run_onchange_after_remind-wslconfig-restart.ps1.tmpl` changes, so the
  `wsl --shutdown` reminder fires on the next Windows `chezmoi apply`.
  Harmless; no action needed.

### Part B — README.html: one new troubleshooting entry

Title: "WSL disk (`ext4.vhdx`) keeps growing / freed space never returns".
Content:

- Why: WSL2 VHDs grow on demand but never shrink on their own; deleting files
  inside Linux does not return space to Windows.
- Status: sparse-VHD auto-shrink is upstream-disabled for data-corruption risk
  (the repo's tracked `sparseVhd=true` is inert until Microsoft re-enables it).
- **Safe one-time reclaim** (admin, manual maintenance — consistent with the
  no-admin rule, which governs bootstrap, not user-run maintenance):
  `wsl --shutdown`, then `Optimize-VHD -Path <vhdx> -Mode Full` (Hyper-V
  module) or the always-available diskpart fallback
  (`select vdisk file=<vhdx>` → `attach vdisk readonly` → `compact vdisk` →
  `detach vdisk`).
- **Opt-in unsafe route**, clearly flagged with the corruption warning:
  `wsl --manage <Distro> --set-sparse true --allow-unsafe` (after backing up
  with `wsl --export`).
- How to find the VHD: `HKCU\...\Lxss\{guid}\BasePath` →
  `%LOCALAPPDATA%\wsl\{guid}\ext4.vhdx`.
- Cross-reference sentence in §setup-wsl: the tracked `.wslconfig` already
  enables memory reclaim (`autoMemoryReclaim=gradual`) and pre-opts into
  sparse VHDs for when Microsoft re-enables them.

### Part C — bookkeeping (per CLAUDE.md conventions, same commit)

- `CLAUDE_CHANGELOG.md`: append a row.
- `CLAUDE.md`: bump "Troubleshooting (17 entries)" → 18.
- `docs/claude/file-care.md`: one line in the `chezmoi/dot_wslconfig` entry —
  `sparseVhd=true` is deliberately kept though inert on WSL ≥ 2.5; the
  annotation comments explain; don't "clean up" either.

## Not changing

- `configs/wsl/wsl.conf` — per-distro file; memory/sparse are global VM
  settings and belong in `.wslconfig` only.
- `bootstrap.ps1`, `bootstrap.sh`, `makefile/` — no new automation.
- No values change anywhere; this is comments + docs only, so no host
  behavior changes.

## Verification

- `chezmoi ignored` on Linux still lists `.wslconfig` (Windows-only deploy
  intact).
- `chezmoi execute-template < chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl`
  on Linux still renders empty (body OS-gate intact).
- `dot_wslconfig` stays pure ASCII (c1150ad precedent) and LF-only.
- README.html renders correctly in a browser; new entry anchors/styles match
  the existing 17.

## Out of scope (YAGNI)

- Automating `--set-sparse` or VHD compaction.
- Memory/CPU caps (`[wsl2] memory=`/`processors=`) — not requested; defaults
  fine on this host.
- Watching microsoft/WSL for the re-enable; revisit if/when it ships.

## References

- <https://learn.microsoft.com/windows/wsl/wsl-config> — section labels,
  defaults.
- <https://github.com/microsoft/WSL/issues/13075>,
  <https://github.com/microsoft/WSL/issues/12103> — sparse disablement,
  `--allow-unsafe`.
- Prior spec: `2026-06-08-wsl-config-tracking-design.md` (how the two WSL
  config files are tracked/deployed).
