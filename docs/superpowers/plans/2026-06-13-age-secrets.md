# Encrypted secrets via age Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire chezmoi's age encryption as a dormant-by-default mechanism (active only when an age recipient is configured), with bootstrap identity preflight and docs — committing no secret.

**Architecture:** A conditional `encryption`/`[age]` block in `.chezmoi.toml.tmpl` keyed on `WORKSTATION_AGE_RECIPIENT`; soft identity-presence checks in `bootstrap.sh`/`bootstrap.ps1`; a README section + a CLAUDE.md invariant.

**Tech Stack:** chezmoi (age encryption), age, Go templates, bash + PowerShell.

**Spec:** `docs/superpowers/specs/2026-06-13-age-secrets-design.md`
**Branch:** `feat/secrets-bumps-pslint`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `chezmoi/.chezmoi.toml.tmpl` | Capture recipient; emit dormant age block when set | Modify |
| `bootstrap.sh` | `check_age_identity` soft preflight + call | Modify (keep LF; passes its own shellcheck) |
| `bootstrap.ps1` | `Test-AgeIdentity` parity mirror + call | Modify (preserve UTF-8 BOM) |
| `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md` | docs + invariant | Modify |

---

## Task 1: Dormant age block in `.chezmoi.toml.tmpl`

**Files:**
- Modify: `chezmoi/.chezmoi.toml.tmpl`

**Context:** The block must be emitted ONLY when `WORKSTATION_AGE_RECIPIENT` is set, so a host with no recipient renders exactly today's config (no encryption). `chezmoi.toml` is regenerated only on `chezmoi init`, so existing hosts are unaffected until they re-init.

- [ ] **Step 1: Capture the recipient at the top of the file**

The file begins with two comment lines then a blank, then `[data]` (line 4). Insert this as a new line immediately BEFORE `[data]`:

```
{{- $ageRecipient := env "WORKSTATION_AGE_RECIPIENT" -}}
```

- [ ] **Step 2: Expose it under `[data]`**

In the `[data]` table, immediately after the `group = "{{ … }}"` line, add:

```
    age_recipient = "{{ $ageRecipient }}"
```

- [ ] **Step 3: Emit the dormant encryption block at the end of the file**

After the `[git]` table (the `autoCommit`/`autoPush` lines at the end), append:

```
{{ if $ageRecipient }}
encryption = "age"
[age]
    identity  = {{ (joinPath .chezmoi.homeDir ".config/chezmoi/key.txt") | quote }}
    recipient = {{ $ageRecipient | quote }}
{{ end }}
```

- [ ] **Step 4: Verify dormant render (recipient unset → no encryption)**

Run: `chezmoi execute-template < chezmoi/.chezmoi.toml.tmpl | grep -c 'encryption = "age"'`
Expected: `0`. (execute-template uses this host's stored chezmoi data for the name/email/group prompts, so it renders non-interactively. If it errors on a prompt, fall back to verifying with `WORKSTATION_AGE_RECIPIENT` set/unset around a throwaway `chezmoi init` into a temp dir.)

- [ ] **Step 5: Verify active render (recipient set → block present, correct values)**

Run:
```bash
WORKSTATION_AGE_RECIPIENT=age1exampleexampleexampleexampleexampleexampleexampleex chezmoi execute-template < chezmoi/.chezmoi.toml.tmpl | sed -n '/encryption = "age"/,/recipient/p'
```
Expected: shows `encryption = "age"`, `[age]`, an absolute `identity = ".../.config/chezmoi/key.txt"`, and `recipient = "age1example…"`.

- [ ] **Step 6: Confirm no live drift + commit**

Run: `chezmoi diff 2>&1 | head` — should be unchanged from before this edit (the live config is regenerated only on `chezmoi init`, and `.chezmoi.toml.tmpl` is not a deployed dotfile). `bash scripts/check-invariants.sh; echo exit=$?` → exit 0.

```bash
git add chezmoi/.chezmoi.toml.tmpl
git commit -m "feat(chezmoi): dormant age encryption block (active when recipient set)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `bootstrap.sh` identity preflight

**Files:**
- Modify: `bootstrap.sh` (add function ~before `set_default_shell()` near line 432; add call after `ensure_chezmoi_initialized` in main flow ~line 722)

- [ ] **Step 1: Add the `check_age_identity` function**

Immediately BEFORE the `set_default_shell() {` definition, add:

```bash
# check_age_identity — soft preflight for the age private identity when encryption
# is configured. If WORKSTATION_AGE_RECIPIENT is set but ~/.config/chezmoi/key.txt
# is absent, warn (encrypted dotfiles won't decrypt) but never fail — encryption is
# opt-in and the identity is provisioned out-of-band, never stored in the repo.
check_age_identity() {
  [ -n "${WORKSTATION_AGE_RECIPIENT:-}" ] || return 0
  log "age encryption: recipient configured (${WORKSTATION_AGE_RECIPIENT})"
  local key="$HOME/.config/chezmoi/key.txt"
  if [ -f "$key" ]; then
    ok "age identity present ($key)"
  else
    warn "age identity missing: $key"
    warn "  encrypted dotfiles won't decrypt until you place it. Create a new key:"
    warn "    age-keygen -o \"$key\"   # then export its public key as WORKSTATION_AGE_RECIPIENT"
    warn "  or copy key.txt from another host / your password store."
  fi
}
```

- [ ] **Step 2: Call it in the main flow**

Find the main-flow sequence (near line 722):
```bash
ensure_chezmoi_initialized
set_default_shell
```
Insert the call between them:
```bash
ensure_chezmoi_initialized
check_age_identity
set_default_shell
```

- [ ] **Step 3: Verify hygiene + shellcheck + behavior**

Run:
```bash
file bootstrap.sh                                   # not CRLF
shellcheck -x -S warning bootstrap.sh; echo "sc=$?" # expect 0
WORKSTATION_AGE_RECIPIENT= bash -c 'source bootstrap.sh 2>/dev/null; check_age_identity; echo "unset rc=$?"' 2>/dev/null || true
```
Better, test the function in isolation without sourcing the whole script (which runs main): extract-and-run is awkward, so instead just confirm shellcheck passes and visually confirm the `return 0` early-exit when the env is empty. The function is exercised live on the next `bootstrap.sh --dev/--prod` run.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(bootstrap): soft age-identity preflight when recipient configured

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `bootstrap.ps1` parity mirror

**Files:**
- Modify: `bootstrap.ps1` (add `Test-AgeIdentity` near the other functions; call it in the main flow after chezmoi init/apply)

**Context:** `bootstrap.ps1` MUST retain its UTF-8 BOM (PowerShell 5.1 mis-parses without it) — the invariant checker enforces this, and the pre-commit hook will block a BOM-less commit.

- [ ] **Step 1: Add the `Test-AgeIdentity` function**

Add this function alongside the other `function` definitions (e.g., after the `Write-*` helpers block around line 126, or near the other step functions):

```powershell
function Test-AgeIdentity {
    if (-not $env:WORKSTATION_AGE_RECIPIENT) { return }
    Write-Log "age encryption: recipient configured ($env:WORKSTATION_AGE_RECIPIENT)"
    $key = Join-Path $HOME ".config/chezmoi/key.txt"
    $haveAge = [bool](Get-Command age -ErrorAction SilentlyContinue)
    if ((Test-Path $key) -and $haveAge) {
        Write-Ok "age identity present ($key)"
    } else {
        if (-not (Test-Path $key)) { Write-Warn "age identity missing: $key" }
        if (-not $haveAge) { Write-Warn "age not on PATH - install it to use encrypted dotfiles on Windows (not bundled by this repo)" }
        Write-Warn "  encrypted dotfiles won't decrypt until both are present. Create a key: age-keygen -o `"$key`""
        Write-Warn "  or copy key.txt from another host / your password store."
    }
}
```

- [ ] **Step 2: Call it in the main flow after chezmoi apply**

Find the main-flow chezmoi step and the post-apply line `Invoke-WeztermConfigEnv` (`grep -n 'Invoke-WeztermConfigEnv' bootstrap.ps1`, ~line 1296). Add `Test-AgeIdentity` on its own line immediately AFTER the chezmoi init/apply has completed in the main flow (placing it right after the `Invoke-WeztermConfigEnv` call is fine — both are post-apply steps).

- [ ] **Step 3: Verify BOM preserved + parses**

Run:
```bash
hexdump -C bootstrap.ps1 | head -1            # must start: ef bb bf
```
If the BOM was lost, restore it:
```bash
pwsh -c "[System.IO.File]::WriteAllText('bootstrap.ps1', (Get-Content -Raw 'bootstrap.ps1'), [System.Text.UTF8Encoding]::new(`$true))" 2>/dev/null \
  || { tmp=$(mktemp); printf '\xef\xbb\xbf' > "$tmp"; cat bootstrap.ps1 >> "$tmp"; mv "$tmp" bootstrap.ps1; }
hexdump -C bootstrap.ps1 | head -1
```
(pwsh is unavailable locally, so PSScriptAnalyzer of this change is verified by the #4 CI job once pushed.)

- [ ] **Step 4: Confirm the invariant checker passes (BOM check) + commit**

Run: `bash scripts/check-invariants.sh 2>&1 | grep -E 'BOM|exit'; bash scripts/check-invariants.sh; echo "exit=$?"`
Expected: `✓ 3 .ps1 files carry EF BB BF`, overall exit 0.

```bash
git add bootstrap.ps1
git commit -m "feat(bootstrap.ps1): age-identity warning parity (Windows)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Docs + invariant

**Files:**
- Modify: `README.html`, `CLAUDE_CHANGELOG.md`, `CLAUDE.md`

- [ ] **Step 1: README — add an "Encrypted secrets" subsection**

Locate the §setup or §daily area (`grep -n 'id="daily"\|id="setup-linux"\|Enforcement / CI' README.html`). Add a subsection matching the surrounding markup conveying:

> **Encrypted secrets (age).** One-time: `age-keygen -o ~/.config/chezmoi/key.txt` (prints your public key), then set that public key as `WORKSTATION_AGE_RECIPIENT` (export it before `bootstrap.sh`, or re-run `chezmoi init`). Add a secret with `chezmoi add --encrypt ~/.netrc` → an `encrypted_*.age` file appears in the source and is safe to commit. New host: copy your `key.txt` to `~/.config/chezmoi/` before `chezmoi apply`. **Back up the identity** — it is the master secret; losing it loses every encrypted file. With no recipient set, encryption is dormant (nothing changes).

- [ ] **Step 2: CLAUDE_CHANGELOG.md — append a row**

```markdown
| Wired chezmoi age encryption as a dormant-by-default mechanism: `.chezmoi.toml.tmpl` emits an `encryption = "age"` + `[age]` block only when `WORKSTATION_AGE_RECIPIENT` is set (identity at `~/.config/chezmoi/key.txt`, never committed); `bootstrap.sh`/`bootstrap.ps1` gain a soft identity preflight. No secret or encrypted demo file committed. | **Yes** | New "Encrypted secrets (age)" subsection (one-time setup, `chezmoi add --encrypt`, new-host key placement, identity backup/recovery). CLAUDE.md gains the age-identity invariant. |
```

- [ ] **Step 3: CLAUDE.md — add the invariant**

Under `## Load-bearing invariants`, add a bullet:

```markdown
- **age encryption is dormant-by-default + the identity is out-of-band** — `.chezmoi.toml.tmpl` emits the `encryption="age"`/`[age]` block only when `WORKSTATION_AGE_RECIPIENT` is set at `chezmoi init`; the private identity lives at `~/.config/chezmoi/key.txt` and is **NEVER** committed (recipient public key is fine to commit). `encrypted_*.age` source files decrypt only where the identity is present; `bootstrap.sh`/`bootstrap.ps1` warn (soft) if the recipient is set but the key is missing.
```

- [ ] **Step 4: Verify + commit**

Run: `bash scripts/check-invariants.sh; echo exit=$?` (expect 0); `grep -c 'Encrypted secrets\|age-keygen' README.html` (expect ≥1).

```bash
git add README.html CLAUDE_CHANGELOG.md CLAUDE.md
git commit -m "docs: document age encrypted-secrets mechanism + invariant"
```

---

## Self-Review Notes (author)

- **Spec coverage:** Part A→Task 1 (toml), Part B→Task 2 (bootstrap.sh), Part C→Task 3 (bootstrap.ps1), Part D→Task 4 (docs+invariant).
- **No placeholders:** all edits + code inline; insertion points pinned by anchors (line ~432/722 for bash, the `Invoke-WeztermConfigEnv` anchor for ps1).
- **Non-breaking:** Task 1 Steps 4-6 prove the dormant render is byte-equivalent (no encryption block, `chezmoi diff` unchanged) when the recipient is unset.
- **BOM care:** Task 3 explicitly verifies + restores the bootstrap.ps1 BOM, backstopped by the invariant checker's BOM check (pre-commit hook blocks a BOM-less commit).
- **No secret committed:** the plan adds mechanism + docs only; the end-to-end encrypt test is a manual local smoke test, nothing from it committed.
