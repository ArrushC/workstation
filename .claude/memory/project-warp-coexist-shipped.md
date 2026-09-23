---
name: project-warp-coexist-shipped
description: Warp is the primary Windows terminal again alongside Windows Terminal (#128, 2026-08-31) — one on-machine probe (R1) still unrun, plus the Warp TOML v1.1 trap
metadata:
  type: project
---

Warp returned as the **primary** Windows terminal on 2026-08-31 (PR #128, squash `23f6adc`),
with Windows Terminal retained in full — WT keeps every capability, Nushell's `defaultProfile`,
and Windows' default-terminal-application role (Warp cannot register for it). This reverses only
the *primacy* decision of the 2026-07-26 WT migration, not its work. Design + open risks:
`docs/superpowers/specs/2026-08-31-warp-coexist-design.md`.

**Still unrun — R1, the only thing gating whether a shipped feature actually works:** in a Warp
WSL tab, `echo $TERM_PROGRAM`. If it prints `WarpTerminal` the restored rc guards are live; if
it is EMPTY they are dead code in the primary session and need the fallback ladder in
`docs/claude/verification.md` §Warp. Setting a user-scope `WSLENV` is explicitly NOT a valid
fix (Warp overwrites `WSLENV`, warpdotdev/Warp#6241). Record the answer in the spec's R1 when run.
The paired regression check: in a *Windows Terminal* WSL tab, starship + atuin Ctrl-R + fzf-tab
must all still work — the guards are `TERM_PROGRAM`-conditional, so WT must be untouched.

**Why:** the change shipped on green CI before the Windows host could be exercised
(`bootstrap.ps1`/`wsa` are the user's to run — see
[[feedback-windows-commands-user-runs-them]]), so the verification debt is real and outlives
the PR.

**How to apply:** before touching the Warp rc guards or claiming they work, check whether R1 was
ever answered. Two facts already settled by read-only probes on this host: Warp's Uninstall
`DisplayName` is exactly `Warp` (key `warp-terminal-stable_is1`), so `bootstrap.ps1`'s `"Warp*"`
glob matches; and **Warp writes TOML v1.1** — its Settings panel reflows inline-table arrays to
multi-line with trailing commas, which Python `tomllib` (v1.0) cannot parse. The tracked
`settings.toml` deliberately keeps them single-line, so never wire that file into a
tomllib-based CI check without accounting for a post-`re-add` reformat. Related:
[[project-windows-apply-via-wsl-gotchas]].
