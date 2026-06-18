# SSH `TERM=wezterm` fallback — design

- **Date:** 2026-06-17
- **Status:** Approved (design); implementation pending
- **Topic:** Graceful `TERM` fallback when sshing out of a WezTerm terminal into a host that lacks the `wezterm` terminfo.

## Problem

`wezterm.lua` sets `config.term = 'wezterm'` (line 347), so WezTerm advertises `TERM=wezterm`
to everything running inside it. This repo compiles the vendored `wezterm` terminfo into
`~/.terminfo` (via `chezmoi/.chezmoiscripts/run_install-wezterm-terminfo.sh.tmpl`) on any host
where `chezmoi apply` runs, so `wezterm` resolves locally.

When the user runs `ssh` from a WezTerm terminal to a host that was **never provisioned with this
repo** (e.g. `cache-bur1`), the SSH client forwards `TERM=wezterm` into the remote pty. That host
has no `wezterm` terminfo entry, so `clear` / `tput` / any ncurses TUI fails with:

```
'wezterm': unknown terminal type.
```

Notably, **`hosts.conf` membership is not a signal for "has the terminfo."** `cache-bur1` is listed
in `hosts.conf` (as a `prod_machine`) yet still errors — being in `hosts.conf` only wires a host up
as a WezTerm SSH domain / ssh convenience target; it installs nothing on that host. Whether a host
has the terminfo depends solely on whether `chezmoi apply` ran there, independent of dev/prod group
(the install script is gated only on `linux`).

The fix must come from the **local side** — the remote is bare and cannot be changed without
mutating it.

## Goal / non-goals

**Goal:** stop the `'wezterm': unknown terminal type` error when sshing into a host that lacks the
terminfo, while preserving full `TERM=wezterm` (truecolor + extended underline) on hosts that do
have it.

**Non-goals:**
- Do **not** mutate remote hosts (no pushing/compiling terminfo on the remote — explicitly declined
  in favour of a fallback).
- Do **not** maintain a hand-curated host list as the source of truth.
- Do **not** touch WezTerm's own SSH-domain launcher path (that uses wezterm's bundled ssh, not the
  shell `ssh`; those are provisioned dev machines that already have the terminfo).

## Decision

**Runtime detection, fail-safe to downgrade, local-only.** A shell `ssh()` wrapper, when the current
terminal is `wezterm`, probes whether the *remote* recognizes the `wezterm` terminfo entry and
chooses `TERM` for the real connection accordingly. The fallback (`xterm-256color`) is the default;
`wezterm` is only kept on a positive probe.

Runtime detection was chosen over a `dev_machine`-group guess or an explicit allowlist because the
user is (legitimately) unsure which hosts are actually provisioned — detection tests the real
condition directly and self-corrects as hosts get provisioned, with no list to maintain.

Fallback `TERM` = **`xterm-256color`** (universally present, 256-color; truecolor is preserved on
provisioned remotes via their own `COLORTERM=truecolor` rc export, and bare remotes have no truecolor
either way).

## Design

An `ssh()` function added to **both** `chezmoi/dot_zshrc.tmpl` and `chezmoi/dot_bashrc.tmpl`
(parity pair). The body is **identical** in both shells (only POSIX-ish constructs — `local`,
`for … in "$@"`, `case`, parameter expansion, `command`).

```sh
# ssh — when launched from a WezTerm terminal, only keep TERM=wezterm if the
# remote actually has the wezterm terminfo; otherwise fall back to
# xterm-256color so `clear`/TUIs don't error with `unknown terminal type` on
# un-provisioned hosts. Fail-safe: anything uncertain → downgrade. Bypass once
# with `command ssh …`; disable permanently via `unset -f ssh` in ~/.zshrc.local.
ssh() {
  if [ "$TERM" != wezterm ]; then
    command ssh "$@"
    return
  fi

  # Parse the destination: first bareword that isn't an option or an option's
  # value. Mis-parses fall through to the fail-safe downgrade below.
  local arg dest='' expect_val=0
  local val_flags='bcDEeFIiJLlmOopRSWw' # short opts that consume the next arg
  for arg in "$@"; do
    if [ "$expect_val" = 1 ]; then expect_val=0; continue; fi
    case $arg in
    --) continue ;;
    -[$val_flags]) expect_val=1; continue ;;  # "-p 2222"
    -[$val_flags]*) continue ;;               # "-p2222" / "-oFoo=bar"
    -*) continue ;;                           # boolean flag(s)
    *) dest=${arg#*@}; break ;;               # bareword → dest, strip user@
    esac
  done

  # Default to the safe fallback; only upgrade on a positive, non-interactive
  # probe. BatchMode never prompts; the probe reuses the ControlMaster socket
  # (config sets ControlMaster auto / ControlPersist 60s on Linux/WSL), so it's
  # a cheap reuse within the persist window and opens the master on first use.
  local term=xterm-256color
  if [ -n "$dest" ] &&
    command ssh -o BatchMode=yes -o ConnectTimeout=5 "$dest" \
      'infocmp wezterm >/dev/null 2>&1'; then
    term=wezterm
  fi

  TERM=$term command ssh "$@"
}
```

### Properties & rationale

- **wezterm-only.** Untouched unless `TERM=wezterm`; non-wezterm terminals (Windows, tmux, plain
  xterm) get vanilla ssh.
- **Fail-safe = downgrade.** Empty/mis-parsed dest, probe timeout, password-auth host with no live
  master, ProxyJump quirk → stays `xterm-256color`. We only *upgrade* to `wezterm` on a positive
  `infocmp`.
- **Cheap.** `-o BatchMode=yes` never prompts; `-o ConnectTimeout=5` bounds the probe. The probe
  reuses the existing ControlMaster socket; first connect opens the master and the real session
  reuses it (one TCP/auth). On-LAN (`10.21.x.x`) the cost is negligible.
- **Naturally bounded blast radius.** rc files are sourced only by *interactive* shells, so scripts
  never get the function; `scp`/`rsync` invoke the ssh *binary*, not the function. Net: this only
  affects `ssh` typed at an interactive prompt. `fssh()` (which calls `ssh`) inherits the behavior
  for free.
- **Escape hatches.** `command ssh …` bypasses for one call; `unset -f ssh` in
  `~/.zshrc.local` / `~/.bashrc.local` (sourced last) disables it permanently per host.

### Known limitations (all fail-safe to downgrade)

- The probe connects with the parsed `dest` + `~/.ssh/config` Host settings, **not** ad-hoc CLI
  flags (`-p 2222`, `-i key`). A host reachable only via such CLI flags will probe-fail → downgrade
  (safe, just not upgraded). Connection params kept in `~/.ssh/config` Host blocks work fine.
- Password-auth host with no live master → `BatchMode` probe fails (no prompt) → downgrade. Key-auth
  hosts upgrade correctly.
- Bundled boolean+value short options (e.g. `-tp 2222`) may mis-parse the dest → downgrade.
- `ssh://` URIs may mis-parse → downgrade.

## Files touched

| File | Change |
|---|---|
| `chezmoi/dot_zshrc.tmpl` | Add `ssh()` near `fssh()` / the ssh helpers. |
| `chezmoi/dot_bashrc.tmpl` | Add the **identical** `ssh()` (same commit; PARITY NOTE comment cross-referencing the zsh copy). |
| `README.html` | New troubleshooting entry (`'wezterm': unknown terminal type` when sshing) documenting the auto-fallback + `command ssh` / `unset -f ssh` escape hatches; brief mention in the SSH/daily area. |
| `CLAUDE_CHANGELOG.md` | Append a row (user-facing surface changed). |

### Parity & lint notes

- **Parity pair.** `dot_zshrc.tmpl` ↔ `dot_bashrc.tmpl` must change in the same commit (the
  `parity-reminder.sh` hook will also nudge). Body is identical between the two.
- **Lint scope.** The shfmt/shellcheck invariant targets `bootstrap.sh`, `makefile/lib/*.sh`,
  `scripts/*.sh`, `.claude/hooks/*.sh`, etc. — **not** `.tmpl` rc files. So this function is not
  auto-linted; hand-match the surrounding `-i 2` (2-space) indentation and the idioms already used
  in these files.
- **CRLF/mode.** These are `.tmpl` Go templates deployed by chezmoi (not run-directly `*.sh`), so the
  LF+0755 tripwire does not apply to them in the same way; no executable bit needed.

## Verification

From a **WezTerm** terminal on the WSL host:

1. `type ssh` → shows the function. In a non-wezterm shell (or `TERM=xterm-256color`), behavior is a
   pass-through.
2. `ssh cache-bur1` → `clear` works (no error); on the remote `echo $TERM` → `xterm-256color`.
3. `ssh <a-provisioned-dev-host>` (e.g. `atc-cache-dev09`) → remote `echo $TERM` → `wezterm`.
4. `command ssh cache-bur1` → still `wezterm` and reproduces the original error — confirms the
   wrapper is what's helping, and the bypass works.
5. `fssh` → picks a host and connects through the wrapper (inherits the fallback).

## Rollback

Remove the `ssh()` function from both rc files (single revert), or `unset -f ssh` in `*.local` for a
per-host opt-out. No state is persisted; nothing is installed on remotes.
