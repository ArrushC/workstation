# Encrypted secrets via age (chezmoi) — design

**Date:** 2026-06-13
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

The repo installs `age`, `sops`, and `gopass` but stores **zero** secrets in
source control — there is no way to keep a real secret (API token, `.netrc`, an
env file, an SSH key) in the repo and have it deploy to `$HOME`. chezmoi's native
age encryption is the flagship dotfiles capability for exactly this and is unused.

## Decision (user-approved)

Wire chezmoi's **age** encryption as a **mechanism + docs** deliverable — commit
no real secret. The encryption config is **dormant by default**: it is emitted
into `chezmoi.toml` only when an age **recipient (public key)** is configured, so
existing hosts are completely unaffected until the user opts in. The private
**identity** lives at `~/.config/chezmoi/key.txt`, never in the repo; bootstrap
detects it and, if missing while a recipient is configured, warns with
instructions (soft, non-fatal).

Rejected alternatives:
- *sops* — heavier (multi-backend, more config) than needed for a single-user
  fleet; age is chezmoi-native and already installed.
- *Auto-generate a per-host key in bootstrap* — gives each host a different
  recipient, forcing per-host re-encryption; wrong for a single-user model.
- *Commit an encrypted demo file* — would break `chezmoi apply` on every host that
  lacks the demo identity. No committed secret of any kind.

## Findings (investigation, 2026-06-13)

1. `chezmoi/.chezmoi.toml.tmpl` currently sets `[data]` (name/email/hostname/os/
   group), `[edit]`, `[diff]`, `[merge]`, `[git]`. `group` already uses the
   env-or-prompt pattern: `{{ if env "WORKSTATION_GROUP" }}…{{ else }}…{{ end }}`
   — the precedent for an env-driven config value.
2. chezmoi enables encryption via top-level `encryption = "age"` plus an `[age]`
   table (`identity`, `recipient`). With no such block, chezmoi does no
   encryption — so conditionally omitting the block is a clean dormant state.
3. The age **identity** is the only secret that must reach each host out-of-band;
   the **recipient** is a public key and is safe to commit / log.
4. Windows: chezmoi supports age if an `age` binary is on PATH, but the repo does
   not install `age` on Windows (`$PortableTools` has none). So Windows is
   mechanism-compatible only if the user installs `age` themselves.

## Design

### Part A — `chezmoi/.chezmoi.toml.tmpl`: dormant age block

- Capture the recipient once at the top:
  `{{- $ageRecipient := env "WORKSTATION_AGE_RECIPIENT" -}}` (empty when unset; no
  prompt, so non-secret users get zero friction).
- Add `age_recipient = "{{ $ageRecipient }}"` under `[data]` (so templates can
  reference it / it's visible in the generated config).
- After the existing tables, conditionally emit:
  ```
  {{ if $ageRecipient }}
  encryption = "age"
  [age]
      identity  = {{ (joinPath .chezmoi.homeDir ".config/chezmoi/key.txt") | quote }}
      recipient = {{ $ageRecipient | quote }}
  {{ end }}
  ```
- Net effect: recipient unset → identical to today (no encryption). Recipient set
  (via env at `chezmoi init`) → encryption active, `chezmoi add --encrypt` works,
  `encrypted_*.age` source files decrypt on apply using `key.txt`.

### Part B — `bootstrap.sh`: identity preflight/warn (soft)

- The recipient env (`WORKSTATION_AGE_RECIPIENT`) is already inherited by the
  `chezmoi init` call (same process); add a log line when it is set
  ("age encryption: recipient configured (…)").
- New step `check_age_identity` (runs after chezmoi init/apply, both `--dev` and
  `--prod`): if `WORKSTATION_AGE_RECIPIENT` is set AND
  `~/.config/chezmoi/key.txt` is absent → `warn` with the recovery instructions
  (generate with `age-keygen -o ~/.config/chezmoi/key.txt`, or copy the existing
  identity from another host / gopass) and continue. Never fails the run —
  encrypted files simply won't decrypt until the key is present. Reuses the
  existing `is_wsl`/log/warn helpers; no new dependencies.

### Part C — `bootstrap.ps1`: parity mirror (lighter)

- The recipient env is likewise inherited by the Windows `chezmoi init`.
- Mirror the warning: if `$env:WORKSTATION_AGE_RECIPIENT` is set AND either
  `~/.config/chezmoi/key.txt` is missing OR `age` is not on PATH → `Write-Warn`
  with the same guidance plus "install `age` (not bundled by this repo) to use
  encrypted dotfiles on Windows". Soft, non-fatal.

### Part D — docs

- `README.html`: a new "Encrypted secrets" subsection (under §setup or §daily)
  covering the one-time setup (`age-keygen`, set `WORKSTATION_AGE_RECIPIENT`,
  re-run init), adding a secret (`chezmoi add --encrypt`), a new host (place
  `key.txt` before `apply`), and **identity backup/recovery** (the identity is the
  master secret; losing it loses all secrets).
- `CLAUDE_CHANGELOG.md`: one row (README update = Yes).
- `CLAUDE.md`: a new load-bearing invariant — identity at
  `~/.config/chezmoi/key.txt` is out-of-band and NEVER committed; the recipient
  public key lives in `chezmoi.toml`; the encryption block is dormant unless
  `WORKSTATION_AGE_RECIPIENT` is set at init; `encrypted_*.age` source files
  decrypt only with the identity present.

## Footprint

- **Edited:** `chezmoi/.chezmoi.toml.tmpl`, `bootstrap.sh`, `bootstrap.ps1`,
  `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md`.
- **New:** none (no scripts; mechanism is config + docs).
- **No committed secret, no encrypted demo file.**

## Verification

- With `WORKSTATION_AGE_RECIPIENT` unset: `chezmoi execute-template < .chezmoi.toml.tmpl`
  (or a fresh `chezmoi init` dry view) produces a config with **no** `encryption`/
  `[age]` block — byte-identical behavior to today; `chezmoi diff` unchanged.
- With `WORKSTATION_AGE_RECIPIENT=age1example…` set: the rendered config contains
  `encryption = "age"` and the `[age]` block with the correct identity path and
  recipient.
- End-to-end (manual, documented, NOT committed): `age-keygen -o ~/.config/chezmoi/key.txt`,
  export the recipient, `chezmoi add --encrypt` a throwaway file → an
  `encrypted_*.age` appears in the source → `chezmoi apply` round-trips it. (Done
  only as a local smoke test; nothing from it is committed.)
- `bootstrap.sh` still passes its own shellcheck (invariant checker) after the new
  step; LF + 0755 preserved.
- bootstrap.ps1 retains its UTF-8 BOM after editing.

## Out of scope

- Committing any real secret or encrypted demo file.
- Installing `age` on Windows.
- A `check-invariants.sh` guard for "key.txt never tracked" (possible future add).
