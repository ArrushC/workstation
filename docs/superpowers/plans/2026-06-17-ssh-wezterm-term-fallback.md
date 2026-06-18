# SSH `TERM=wezterm` Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ssh()` shell wrapper so that, when launched from a WezTerm terminal, ssh keeps `TERM=wezterm` only on hosts that actually have the `wezterm` terminfo and otherwise falls back to `xterm-256color` — eliminating `'wezterm': unknown terminal type` on un-provisioned remotes.

**Architecture:** A single `ssh()` function added identically to `chezmoi/dot_zshrc.tmpl` and `chezmoi/dot_bashrc.tmpl`. When `$TERM=wezterm`, it parses the destination, runs a cheap non-interactive `infocmp wezterm` probe over the existing ControlMaster connection, and execs the real `ssh` with `TERM` set accordingly. Fail-safe: anything uncertain downgrades. Purely local — nothing is installed on remotes.

**Tech Stack:** POSIX-ish shell (bash + zsh), chezmoi Go-template `.tmpl` files, OpenSSH (`ControlMaster`/`infocmp`), README.html (hand-maintained), CLAUDE_CHANGELOG.md.

## Global Constraints

- **Parity pair:** `chezmoi/dot_zshrc.tmpl` ↔ `chezmoi/dot_bashrc.tmpl` must change in the **same commit**; the `ssh()` body is **byte-identical** between them.
- **User-facing surface → docs in the SAME commit:** per `CLAUDE.md`, `README.html` (troubleshooting entry) **and** a `CLAUDE_CHANGELOG.md` row land in the same commit as the rc change. This is why the whole feature is one commit, not split.
- **rc files are `.tmpl` Go templates**, deployed by chezmoi. They are **not** covered by the shfmt/shellcheck invariant (targets are `bootstrap.sh`, `makefile/lib/*.sh`, `scripts/*.sh`, `.claude/hooks/*.sh`, …). Match the surrounding **2-space (`-i 2`)** indentation and the idioms already in these files by hand. No executable bit; LF line endings only (never introduce CRLF).
- **Place the function un-gated** (no surrounding `{{ if … }}`), immediately after `fssh()`, so it always renders and the offline test can extract it from the raw template.
- **Fallback `TERM` is exactly `xterm-256color`.** Only **upgrade** to `wezterm` on a positive `infocmp`.
- **Branch + conventional commit.** Work on a branch (not `main`); commit subject in `feat(shell): …` style; end the commit message with the required `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `chezmoi/dot_zshrc.tmpl` | zsh interactive rc | Add `ssh()` after `fssh()` (zsh ~line 460). |
| `chezmoi/dot_bashrc.tmpl` | bash interactive rc | Add **identical** `ssh()` after `fssh()` (bash ~line 322). |
| `README.html` | user-facing reference | New Troubleshooting `<details data-ts>` entry. |
| `CLAUDE_CHANGELOG.md` | precedent log | Append one row. |
| `/tmp/test-ssh-term.sh` | offline test (throwaway, **not committed**) | New — extracts the function, stubs ssh on PATH, asserts TERM selection in bash + zsh. |

---

### Task 1: `ssh()` TERM-fallback wrapper + docs (single commit)

**Files:**
- Create: `/tmp/test-ssh-term.sh` (throwaway test, not committed)
- Modify: `chezmoi/dot_zshrc.tmpl` (insert after the `fssh()` block)
- Modify: `chezmoi/dot_bashrc.tmpl` (insert after the `fssh()` block)
- Modify: `README.html` (Troubleshooting section, after the filter-bar)
- Modify: `CLAUDE_CHANGELOG.md` (append a table row)

**Interfaces:**
- Produces: a shell function `ssh` (overrides the `ssh` binary for interactive shells only). Contract: `ssh [ssh-args…]` behaves exactly like the real ssh except it sets `TERM=xterm-256color` for the remote session unless the remote has the `wezterm` terminfo. `command ssh …` always reaches the binary unchanged.
- Consumes: the existing SSH config (`ControlMaster auto` / `ControlPersist 60s` from `chezmoi/private_dot_ssh/private_config.tmpl`) for cheap probe reuse. `fssh()` calls `ssh "$host"` and so inherits the wrapper automatically.

- [ ] **Step 1: Create the feature branch**

```bash
cd ~/.local/share/chezmoi
git checkout -b feat/ssh-wezterm-term-fallback
```

- [ ] **Step 2: Write the failing offline test**

Create `/tmp/test-ssh-term.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Offline test for the ssh() TERM-fallback wrapper in dot_zshrc.tmpl / dot_bashrc.tmpl.
# Extracts the function (it has no template vars), stubs `ssh` on PATH, and asserts
# TERM selection across arg forms in BOTH bash and zsh. Throwaway — not committed.
set -u
REPO="${1:-$HOME/.local/share/chezmoi}"
ZRC="$REPO/chezmoi/dot_zshrc.tmpl"
BRC="$REPO/chezmoi/dot_bashrc.tmpl"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# fake ssh: probe (last arg mentions infocmp) -> exit FAKE_PROBE_RESULT;
#           real connection -> print the TERM it was handed.
cat >"$workdir/ssh" <<'EOF'
#!/usr/bin/env bash
last="${@: -1}"
case "$last" in
  *'infocmp wezterm'*) exit "${FAKE_PROBE_RESULT:-1}" ;;
  *) echo "REAL TERM=$TERM" ;;
esac
EOF
chmod +x "$workdir/ssh"

# extract `ssh() { … }` from a rc template (function opens at col 0, closes with `^}$`).
extract() { awk '/^ssh\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$1"; }
extract "$ZRC" >"$workdir/fn_zsh.sh"
extract "$BRC" >"$workdir/fn_bash.sh"

fails=0
check() { # label shell fn env expected ssh-args...
  local label="$1" shell="$2" fn="$3" env="$4" expected="$5"
  shift 5
  local got
  got="$(env PATH="$workdir:$PATH" $env "$shell" -c "source '$fn'; ssh $*" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$label" "$expected" "$got"
    fails=$((fails + 1))
  fi
}

for s in bash zsh; do
  command -v "$s" >/dev/null 2>&1 || { printf 'skip %s (not installed)\n' "$s"; continue; }
  fn="$workdir/fn_$s.sh"
  check "$s: wezterm + remote-has-it -> wezterm"    "$s" "$fn" "TERM=wezterm FAKE_PROBE_RESULT=0" "REAL TERM=wezterm"        host
  check "$s: wezterm + remote-lacks-it -> fallback" "$s" "$fn" "TERM=wezterm FAKE_PROBE_RESULT=1" "REAL TERM=xterm-256color" host
  check "$s: user@host parsed"                      "$s" "$fn" "TERM=wezterm FAKE_PROBE_RESULT=0" "REAL TERM=wezterm"        user@host
  check "$s: -p flag skipped"                       "$s" "$fn" "TERM=wezterm FAKE_PROBE_RESULT=0" "REAL TERM=wezterm"        "-p 2222 host"
  check "$s: no dest -> fallback"                    "$s" "$fn" "TERM=wezterm FAKE_PROBE_RESULT=1" "REAL TERM=xterm-256color" ""
  check "$s: non-wezterm passthrough"               "$s" "$fn" "TERM=xterm-256color"              "REAL TERM=xterm-256color" host
done

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
```

- [ ] **Step 3: Run the test to verify it FAILS**

```bash
bash /tmp/test-ssh-term.sh ~/.local/share/chezmoi
```

Expected: the `wezterm + remote-lacks-it -> fallback` and `no dest -> fallback` cases **FAIL** for both bash and zsh (no `ssh` function exists yet, so the stub binary runs with `TERM=wezterm`), ending with `2 FAILURE(S)` per installed shell. The `passthrough` and `remote-has-it` cases incidentally pass. Overall exit non-zero.

- [ ] **Step 4: Add `ssh()` to `chezmoi/dot_zshrc.tmpl`**

Insert the block below **between** the `fssh()` closing `}` and the `# Start or attach to a named zellij session` comment (zsh ~line 460). The anchor `fssh()` block to insert after:

```sh
fssh() {
  local host
  host=$(grep -E "^Host " ~/.ssh/config 2>/dev/null | awk '{print $2}' | fzf)
  [[ -n "$host" ]] && ssh "$host"
}
```

New block to insert immediately after it (preserve the blank line before `# Start or attach…`):

```sh

# ssh — launched from WezTerm, keep TERM=wezterm only if the remote actually has
# the wezterm terminfo; otherwise fall back to xterm-256color so `clear`/TUIs
# don't error with `unknown terminal type` on hosts not provisioned with this
# repo. Fail-safe: anything uncertain (unparsable dest, probe timeout, password-
# only host with no live ControlMaster) downgrades; we only *upgrade* on a
# positive infocmp. Bypass once with `command ssh …`; disable permanently via
# `unset -f ssh` in ~/.zshrc.local. PARITY: identical body in dot_bashrc.tmpl.
ssh() {
  if [ "$TERM" != wezterm ]; then
    command ssh "$@"
    return
  fi

  # Destination = first bareword that isn't an option or an option's value.
  local arg dest='' expect_val=0
  local val_flags='bcDEeFIiJLlmOopRSWw'
  for arg in "$@"; do
    if [ "$expect_val" = 1 ]; then
      expect_val=0
      continue
    fi
    case $arg in
    --) continue ;;
    -[$val_flags]) expect_val=1 ;;
    -[$val_flags]*) continue ;;
    -*) continue ;;
    *)
      dest=${arg#*@}
      break
      ;;
    esac
  done

  # Default to the safe fallback; only upgrade on a positive non-interactive
  # probe. -o BatchMode=yes never prompts; the probe reuses the ControlMaster
  # socket (ControlMaster auto / ControlPersist 60s, Linux/WSL) so it's cheap.
  local term=xterm-256color
  if [ -n "$dest" ] &&
    command ssh -o BatchMode=yes -o ConnectTimeout=5 "$dest" \
      'infocmp wezterm >/dev/null 2>&1'; then
    term=wezterm
  fi

  TERM=$term command ssh "$@"
}
```

- [ ] **Step 5: Add the IDENTICAL `ssh()` to `chezmoi/dot_bashrc.tmpl`**

Insert the **same block** (byte-identical body) after the identical `fssh()` block in `dot_bashrc.tmpl` (bash ~line 322). The only difference is the PARITY comment's reference — change the last comment line to read:

```sh
# `unset -f ssh` in ~/.bashrc.local. PARITY: identical body in dot_zshrc.tmpl.
```

(Everything else, including indentation, is identical to Step 4.)

- [ ] **Step 6: Run the offline test to verify it PASSES**

```bash
bash /tmp/test-ssh-term.sh ~/.local/share/chezmoi
```

Expected: every case prints `ok …` for both bash and zsh, ending with `ALL PASS` and exit 0. (If zsh isn't installed it prints `skip zsh …` and still passes on bash.)

- [ ] **Step 7: Add the README troubleshooting entry**

In `README.html`, inside `<section id="troubleshooting">`, insert this new entry immediately **after** the filter-bar `</div>` (≈ line 3616) and **before** the first `<details data-ts>` (the "Bootstrap reports …" entry). Match the existing 20-space indentation:

```html
                    <details data-ts>
                        <summary>
                            <code>clear</code> on a remote server says
                            <em
                                >&ldquo;&lsquo;wezterm&rsquo;: unknown terminal
                                type&rdquo;</em
                            >
                        </summary>
                        <div class="ts-body">
                            <p>
                                You ssh&rsquo;d from a WezTerm terminal into a
                                host that doesn&rsquo;t have the
                                <code>wezterm</code> terminfo (it was never
                                provisioned with this repo). WezTerm advertises
                                <code>TERM=wezterm</code> and the remote ncurses
                                can&rsquo;t resolve it.
                            </p>
                            <p>
                                The <code>ssh</code> shell function handles this
                                automatically: launched from WezTerm it probes
                                the remote and, if it doesn&rsquo;t recognise
                                <code>wezterm</code>, falls back to
                                <code>xterm-256color</code> for that session.
                                Hosts that <em>do</em> have the terminfo keep the
                                full <code>wezterm</code> type.
                            </p>
                            <p>
                                Bypass the wrapper for one call with
                                <code>command ssh &hellip;</code>; disable it
                                permanently by adding <code>unset -f ssh</code>
                                to <code>~/.zshrc.local</code> (or
                                <code>~/.bashrc.local</code>). To fix the remote
                                itself, provision it with this repo or copy the
                                terminfo over:
                                <code
                                    >infocmp -x wezterm | ssh HOST tic -x -o
                                    ~/.terminfo -</code
                                >.
                            </p>
                        </div>
                    </details>
```

- [ ] **Step 8: Append the CLAUDE_CHANGELOG.md row**

Add this row at the end of the table in `CLAUDE_CHANGELOG.md`:

```markdown
| Added an `ssh()` shell wrapper (parity pair: `dot_zshrc.tmpl` + `dot_bashrc.tmpl`) that, when launched from a WezTerm terminal, probes the remote for the `wezterm` terminfo and uses `TERM=xterm-256color` when it's absent (fail-safe; only upgrades to `wezterm` on a positive `infocmp` over a reused ControlMaster probe). Fixes `'wezterm': unknown terminal type` when sshing into un-provisioned hosts. Bypass with `command ssh …`; disable via `unset -f ssh` in `*.local`. | **Yes** | New Troubleshooting entry (`clear` → `'wezterm': unknown terminal type`) explaining the auto-fallback, the `command ssh` / `unset -f ssh` escape hatches, and the manual remote terminfo-copy option. No TOC or layout change (Troubleshooting entries aren't individually linked). |
```

- [ ] **Step 9: Sanity checks (no CRLF, renders, invariants clean)**

```bash
cd ~/.local/share/chezmoi
file chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl   # must NOT say "with CRLF line terminators"
chezmoi cat ~/.zshrc  | awk '/^ssh\(\) \{/{f=1} f{print} f&&/^}$/{exit}'   # function renders intact
chezmoi cat ~/.bashrc | awk '/^ssh\(\) \{/{f=1} f{print} f&&/^}$/{exit}'
make lint MODE=prod   # check-invariants + shellcheck/shfmt/gitleaks; expect no NEW failures (.tmpl not linted)
```

Expected: `file` reports neither as CRLF; both `chezmoi cat` blocks print the full function (template renders without error); `make lint` finishes without new failures attributable to this change.

- [ ] **Step 10: Commit (single commit, all four tracked files)**

```bash
cd ~/.local/share/chezmoi
git add chezmoi/dot_zshrc.tmpl chezmoi/dot_bashrc.tmpl README.html CLAUDE_CHANGELOG.md \
        docs/superpowers/specs/2026-06-17-ssh-wezterm-term-fallback-design.md \
        docs/superpowers/plans/2026-06-17-ssh-wezterm-term-fallback.md
git commit -m "feat(shell): fall back from TERM=wezterm to xterm-256color over ssh

Add an ssh() wrapper (zsh+bash parity) that, when launched from WezTerm,
probes the remote for the wezterm terminfo and downgrades TERM to
xterm-256color when absent — fixing \`'wezterm': unknown terminal type\`
on un-provisioned hosts. Fail-safe to downgrade; only upgrades on a
positive infocmp over a reused ControlMaster probe. Bypass with
\`command ssh\`; disable via \`unset -f ssh\` in *.local.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Live verification + open PR

This task needs a **real WezTerm session** and reachable hosts, so the verification steps are run by the user (or by an agent that has ssh access to the fleet). The offline test in Task 1 already proves the parsing + TERM-selection logic; these steps confirm the live probe and the deployed rc.

**Files:** none modified (verification + PR only).

- [ ] **Step 1: Deploy the updated rc and reload**

```bash
cza            # chezmoi apply
exec zsh       # or: exec bash
type ssh       # expect: "ssh is a shell function"
```

- [ ] **Step 2: Verify the fallback on an un-provisioned host**

```bash
ssh cache-bur1 'echo TERM=$TERM; clear; echo cleared-ok'
```

Expected: prints `TERM=xterm-256color`, no `unknown terminal type` error, and `cleared-ok`.

- [ ] **Step 3: Verify wezterm is kept on a provisioned host**

```bash
ssh atc-cache-dev09 'echo TERM=$TERM'
```

Expected: `TERM=wezterm` (a host that has the terminfo). If this host also lacks it, the probe will (correctly) report `xterm-256color` — provision it or treat that as expected.

- [ ] **Step 4: Confirm the bypass reproduces the original behavior**

```bash
command ssh cache-bur1 'echo TERM=$TERM'
```

Expected: `TERM=wezterm` (the bare binary still forwards wezterm) — confirms the wrapper is what's fixing the interactive case.

- [ ] **Step 5: Push the branch and open a PR** (when ready / with the user's go-ahead)

```bash
cd ~/.local/share/chezmoi
git push -u origin feat/ssh-wezterm-term-fallback
gh pr create --fill --base main
```

PR body should summarize: the problem (`TERM=wezterm` unknown on un-provisioned remotes), the local-only fix (ssh wrapper, fail-safe downgrade, runtime detection), and the escape hatches. End the PR body with the Claude Code generation line.

---

## Self-Review

**1. Spec coverage:**
- Problem (TERM=wezterm forwarded to bare remote) → Task 1 `ssh()` wrapper. ✓
- Runtime detection / fail-safe downgrade / local-only → Task 1 Steps 4–5 (probe + default `xterm-256color`). ✓
- `xterm-256color` fallback exactly → Task 1 (`term=xterm-256color`). ✓
- Parity pair, same commit → Task 1 Steps 4, 5, 10 + Global Constraints. ✓
- Escape hatches (`command ssh`, `unset -f ssh`) → in the function comment + README entry. ✓
- Known limits documented → README entry + spec (no code needed). ✓
- README troubleshooting entry + changelog row → Task 1 Steps 7–8. ✓
- Verification recipe (function present, fallback host, provisioned host, bypass) → Task 2. ✓
- Doesn't touch WezTerm SSH-domain launcher → no code touches `wezterm.lua`; verified by scope. ✓
- Note: the spec mentioned an *optional* "brief mention in the SSH/daily area" of README. Scoped out to keep the change minimal — the Troubleshooting entry is the documentation surface. (Auditable scoping decision.)

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every step has concrete code/commands and expected output. ✓

**3. Type consistency:** Function name `ssh` used consistently; the offline test extracts `fn_$s.sh` matching the `extract` output names `fn_zsh.sh`/`fn_bash.sh`; `val_flags` / `expect_val` / `dest` / `term` names consistent across Steps 4–6. The fake-ssh probe match string `infocmp wezterm` matches the function's probe command exactly. ✓
