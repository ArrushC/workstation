# Warp returns as the primary Windows terminal — Windows Terminal retained in full

**Date:** 2026-08-31
**Scope:** `bootstrap.ps1` (Warp seed + Tab Config generator + Doctor/CheckForUpdates/epilogue), three re-tracked Warp configs, the rc `TERM_PROGRAM` guards + a new `check_warp_guards` invariant, `manage-hosts.{sh,ps1}` notes, and the CLAUDE.md/docs-claude/README/changelog sweep. No Make/Linux install changes.
**Status:** Implemented — one on-machine probe outstanding (R1 below).

## Goal

Warp becomes the day-to-day Windows terminal again. Windows Terminal is **not** retired:
it keeps every capability it has today, stays Nushell's first-class home, and keeps
Windows' default-terminal-application role. Both terminals are managed, both regenerate
per-host SSH+zellij launchers from `hosts.conf`, neither degrades the other.

This reverses the *primacy* decision of `docs/superpowers/specs/2026-07-26-windows-terminal-migration-design.md`
without reversing its work. That migration was thorough — `grep -i warp` over the tree
returned zero hits — so the Warp surface is restored from git rather than rewritten:
the three configs are **byte-identical** to `8ee4300^`, and `Install-Warp` /
`Invoke-WarpTabConfigs` are their pre-`d8a297b` selves with updated comments.
The end state matches the WezTerm→Warp arrangement recorded at `CLAUDE_CHANGELOG.md:20`
(one primary, one fully-working fallback), with the roles now Warp and WT.

## Constraints that shaped the design (verified against Warp docs, 2026-08)

- **Warp does not support Nushell.** Supported Windows shells: pwsh 7, PowerShell 5, WSL2,
  Git Bash. An unsupported login shell gets a banner and a PowerShell fallback. Nushell is
  the fleet's default local Windows shell, so the two terminals take complementary roles
  rather than duplicating each other.
- **Warp cannot register as Windows' default terminal application** (warpdotdev/warp#6261).
  Console handoff stays WT's job — an independent reason to keep WT fully configured.
- **`session.new_session_shell_override` still accepts only** `"system_default"` /
  `{ executable = … }` / `{ custom = … }` — no first-class WSL value. The
  `{ custom = "wsl.exe …" }` shape (originally a workaround for warpdotdev/warp#7576)
  remains correct; re-verified against the all-settings reference.
- **`settings.toml` is bidirectional**: Warp's Settings panel writes it, Warp hot-reloads
  external edits. Same drift model as WT's `settings.json` → `chezmoi re-add`.
  `is_settings_sync_enabled = false` keeps Warp's cloud sync from fighting chezmoi.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Warp's session shell is **AlmaLinux-9 WSL zsh** | Warp can't run Nushell; zsh is the full toolbelt and is a first-class Warp shell. Nushell stays WT's `defaultProfile`. |
| 2 | **Restore the `TERM_PROGRAM != WarpTerminal` rc guards**, tightly scoped | Warp owns the input editor and ships its own fzf/atuin/starship equivalents. Guards are runtime-only, so WT/SSH/WSL sessions are untouched. |
| 3 | Docs lead with **Warp primary, WT the compatibility path** | Matches the ask; WT keeps the default-terminal-app role regardless. |
| 4 | Warp AI / telemetry / crash reporting / cloud sync stay **off** | Restores the prior posture; chezmoi remains the single authority over `settings.toml`. |

Install shape: a bespoke best-effort `winget install --id Warp.Warp --scope user` seed
(the twin of `Install-WindowsTerminal`), **not** an `$InstallerTools` entry — Warp publishes
no GitHub release assets to hash, winget's manifest is the hash authority, and Warp
self-updates, so there is no `versions.mk` pin and no bumper `EXCLUDE` entry.
**No new `bootstrap.ps1` flag**: `-SkipToolInstall` already covers it, and a new switch would
force a matching record in `config.nu.tmpl`'s `workstation_bootstrap_flags` (there is no
`-SkipWindowsTerminal` either, so a Warp-only skip would be asymmetric).

## The guard-scope contract (the `c9709cf` lesson)

Commit `c9709cf` records that the old fzf-tab guard's `fi` had drifted past the whole
plugin-load section, silently disabling zsh-autosuggestions, zsh-syntax-highlighting,
zsh-you-should-use and zsh-history-substring-search under Warp. Nothing caught it.

**Contract:** a Warp guard may only be folded into a pre-existing `if` condition, or open a
short block containing no other `if`. Five of the six zsh guards add zero nesting; the one
new block wraps the two fzf-tab `zstyle` lines and closes four lines later, on an `fi` that
says so. The shift-select and fzf-tab block spans are byte-for-byte the same as before.

**Enforcement:** `check_warp_guards` in `scripts/check-invariants.sh` asserts the guard
counts (6 zsh / 2 bash) and depth-tracks `if`/`fi` to prove no plugin source is ever loaded
inside a Warp guard. Negative-tested by re-injecting the historical bug: the check fails and
names all four suppressed plugins.

## Two generators, one `hosts.conf`

`Invoke-WarpTabConfigs` (MAIN step 5d) sits beside `Invoke-WindowsTerminalFragments` (5c).
Same input, disjoint outputs, same self-heal contract (every run, skip-with-warn when the
terminal is absent, warn-and-continue on failure), same wholly-owned-namespace rule —
`workstation-*.toml` for Warp, `*.json` inside `Fragments\workstation\` for WT. Both emit the
identical `ssh -t <user>@<ip> zellij attach --create main`.

**Known and intended:** opening the same host in both terminals attaches the *same* remote
zellij session (`main`), so the panes mirror and zellij sizes to the smallest client. That is
zellij working as designed. Do **not** "fix" it by giving the terminals different session
names — that would double every host's server-side session count. Documented as a
troubleshooting bullet instead.

Warp needs three **local** entries that WT does not (`WSL: AlmaLinux-9`,
`Windows PowerShell`, `Nushell (compatibility)`) because its `+` menu *is* its launch
surface, whereas WT already has a profile list. The WSL entry doubles as the recovery path if
Warp ever rejects `new_session_shell_override`; the Nushell entry is the only bridge from
Warp to the fleet's default local shell, and is knowingly degraded.

## Verification

`docs/claude/verification.md` carries the full recipe (`## Warp` + the reframed
`## Windows Terminal`). Passing on the Linux side today: `make -C makefile lint MODE=prod`
(all invariants incl. the new guard check, all templates, shellcheck, shfmt, gitleaks),
Windows-PowerShell-5.1 parse of `bootstrap.ps1` + `manage-hosts.ps1`, BOM intact, README
structurally clean (no parse errors, no duplicate ids, no dangling anchors), and every
generated tab-config shape parsed as TOML with realistic substitutions.

Not runnable here: `make -C makefile ps-lint` (no pwsh on this Linux host, PSScriptAnalyzer
absent on the Windows side) — CI's `powershell` job is the gate.

## Open risks

- **R1 (blocking the guards' usefulness) — does `TERM_PROGRAM` cross into WSL?**
  If Warp doesn't export it into the WSL session, decision 2 is dead code in the primary
  session. The pre-retirement recipe asserted it did on this very host
  (`git show 19b3b75^:docs/claude/verification.md`), but that is a year of Warp releases ago.
  Probe and fallback ladder are in `docs/claude/verification.md`; **record the answer there
  and here once run.** Note that setting a user-scope `WSLENV` is not a valid fallback —
  Warp is reported to overwrite `WSLENV` rather than merge it (warpdotdev/Warp#6241).
- **R2 — `DetectName`. RESOLVED 2026-08-31.** Read-only registry probe on the Windows host:
  `DisplayName=[Warp]`, `DisplayVersion=v0.2026.08.26.17.59.stable_01`, key
  `warp-terminal-stable_is1` (HKCU) — so the `"Warp*"` glob matches, and it stays correct if
  Warp ever renames itself to "Warp Terminal". winget is present (v1.29.290). Warp was
  **already installed by hand** on this host, so `Install-Warp` will detect and skip; the seed
  exists for fresh-host reproducibility.
- **R3 — `shell = "pwsh"`** in the three local Tab Configs assumes PowerShell 7 is present.
- **R4 — VCRedist.** Warp's winget manifest declares `Microsoft.VCRedist.2015+`; on a box
  with no VC++ runtime, *winget* may install it machine-wide. Nothing here elevates, and
  declining is survivable. This is not a new exception to the no-admin rule.

## Pre-apply delta on the Windows host (measured 2026-08-31)

The host already had a live `settings.toml` (39 simple keys, largely Warp defaults) and **no**
`keybindings.yaml`, **no** themes dir and **no** `tab_configs` dir. Applying the tracked config
(93 keys) is therefore additive apart from four value changes and one dropped block:

| Key | Live | Tracked (wins) |
|---|---|---|
| `appearance.themes.theme` | `"dark"` | Catppuccin Mocha (custom) |
| `general.default_session_mode` | `"agent"` | `"terminal"` |
| `appearance.vertical_tabs.primary_info` | `"command"` | `"working_directory"` |
| `appearance.vertical_tabs.compact_subtitle` | `"working_directory"` | `"branch"` |

Dropped: the 16-key `[agents.execution_profiles.default]` block (Warp Agent permission
defaults). Inert here — the tracked config sets `is_any_ai_enabled = false`, and Warp
regenerates the block with defaults if AI is ever re-enabled. Nothing hand-tuned is lost.

The live file has no `[session]` table, so Warp currently opens the system default shell;
after the apply it opens AlmaLinux-9 WSL zsh. That is the intended change, and it is the most
visible one on first launch.

## Out of scope

- Making Warp Windows' default terminal application (it cannot register).
- Nushell support in Warp beyond the compatibility Tab Config.
- Warp AI / Agent Mode / Warp Drive / cloud settings-sync.
- Any reduction of Windows Terminal's configuration.
- Native Windows zellij (still the deferred follow-up from the 2026-07-26 spec).
