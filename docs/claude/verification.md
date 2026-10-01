# Quick verification

> Recipes for verifying a change, grouped by subsystem. The rules they protect are in CLAUDE.md.
> Automated checks (`mise run lint` = `scripts/check-invariants.sh`, `bash scripts/check-templates.sh`,
> and the `lint.yml` CI jobs) cover most static invariants; the recipes below are what they don't.

## Host state and tools (read-only, no sudo)

- `MISE_ENV=<set> mise bootstrap plan --json | jq .summary` gives create/update/remove/unchanged
  counts (0/0/0/N on a stable host). `mise bootstrap status --missing` lists only rows needing
  attention. Sets: `linux` (shared), `linux,owned,host,native`, `linux,owned,host,wsl`. Safe unprivileged
  because there is no firewall table. Both refuse a dotfiles conflict like a real apply unless
  `--force-dotfiles` is passed.
- `mise run health` is the full report (saved mode, `MISE_ENV` persistence, pueued, python-env,
  dotfiles drift, dirty checkout); exit 1 on a hard failure. `mise tasks validate` catches malformed `#MISE` headers; `mise ls --missing`
  should be empty.
- Sandbox install plus capability gate (no sudo):
  ```
  MISE_CONFIG_DIR=$PWD MISE_DATA_DIR=/tmp/mise-sandbox MISE_STATE_DIR=/tmp/mise-sandbox-state \
    MISE_CACHE_DIR=/tmp/mise-sandbox-cache MISE_ENV=linux,owned,host,native mise install \
    && MISE_DATA_DIR=/tmp/mise-sandbox tasks/verify-tools
  ```
  Expect `✓ verify-tools: N ELF binaries pass`. A failure means that tool needs an explicit
  `github:` `asset_pattern`. Set `GITHUB_TOKEN` to avoid API rate limits.
- Tools install path (after touching `mise-env.sh`, `mise-install.sh`, `verify-tools`, the rc guard
  block): `bash scripts/test-mise-install.sh` (PASS), then on a real host `mise doctor`
  (activated + shims_on_path yes) and `zsh -c 'command -v node'` resolving to the mise shim. A
  second `mise bootstrap --yes` is a fast no-op.
- Locks: never hand-edit. Regeneration (from outside the checkout, then sidecar-path normalisation)
  is implemented in `scripts/bump-versions.sh`; `check-invariants.sh` verifies lock coverage.
- pueued: `systemctl --user cat dev.mise.pueued.service` has no `Environment=MISE_ENV=` line;
  `systemctl --user show-environment | grep MISE_ENV` and `~/.config/environment.d/10-mise.conf`
  carry it; the service is `active (running)`.
- python-env: `mise run python-env && wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"`.
  A second run prints "already up to date"; `mise run python-env --rebuild` forces an upgrade. Library-list parity with
  `bootstrap.ps1` is checked by `check-invariants.sh`.
- Fonts: `fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l` is 6 on Linux owned hosts, 0 on
  WSL and shared hosts. Windows: 6 `JetBrainsMonoNerdFontMono-*.ttf` under
  `$env:LOCALAPPDATA\Microsoft\Windows\Fonts`.
- Misc after `wsa`: `tldr tar | head -1` prints a page (tealdeer cache seeded); `man ls | head` is
  bat-coloured; `ssh -G <host> | grep -iE 'serveralive|tcpkeepalive|connecttimeout'` shows 30/3/yes/10.
- `winterop` (after editing it): on WSL `winterop selftest` prints `selftest: PASS`; `winterop clip
  set X` then `clip get` round-trips. shellcheck and LF+0755 are covered by `check-invariants.sh`.
- Weekly `version-bumps.yml` PR: bumping a STRING pin drops its same-line and preceding comment;
  a TABLE pin's `.version` keeps both. Re-add comments that carried real information (asset-pattern
  rationale, glibc-floor note).

## Dotfiles

- `mise dot status` (`wss`) lists each entry with `applied`/`differs`/`missing`; `mise dot diff`
  (`wsd`) shows pending changes.
- **Never run `mise dot apply`/`mise bootstrap` against the real `$HOME` from an agent.** Use a
  scratch home: `SCRATCH=$(mktemp -d) && HOME="$SCRATCH" MISE_ENV=<set> mise dot apply --force --yes -- "<target>"`,
  inspect `$SCRATCH`, then `rm -rf "$SCRATCH"`. `--force` is needed when the target is an existing
  file (the single-entry form of `--force-dotfiles`). mise falls back to the account home's
  `~/.config/mise` when the scratch `HOME` has none, so from a worktree it silently renders the wrong
  checkout; `scripts/check-templates.sh` (`make_home`/`in_home`) shows the working pattern, or just
  run it. It renders every template individually for all four token sets, syntax-checks, then
  bulk-applies; clean output ends `all rendered templates pass, across all four MISE_ENV sets`.
- Windows: `.\bootstrap.ps1 -Doctor` shows mise, runtimes, PATH shims, Nushell activation, Python
  env and dotfiles sync; a second `.\bootstrap.ps1` reports "already installed"/stamp hits. Parse
  check: `powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('bootstrap.ps1',[ref]$null,[ref]$null);'ok'"`.
  `scripts/test-curl.ps1` (HTTP helper) runs in both shells in the `windows-http` CI job.

## zellij

- `copy_command` must stay unset (OSC 52 is the only clipboard path over SSH). Verify by yanking in a
  remote pane and pasting locally; zellij reads config at session creation, so `zellij kill-session main`
  first. `check_zellij_config` covers the theme name, KDL comments, `web_server`, tab-bar alias and
  `zellij setup --check`.
- zjstatus: `bash scripts/test-zellij-plugin.sh` (also in `check-invariants.sh`). To probe a live
  session with the repo config, judge by zellij's log, not `dump-layout`:
  `grep -E "Loaded plugin|No such file" /tmp/zellij-$UID/zellij-log/zellij.log` must show
  `Loaded plugin 'zjstatus.wasm'`. On a host: `wsa`, `zellij kill-session main`, reattach, press `y`
  at the permission prompt.

## Warp (the primary Windows terminal)

After `bootstrap.ps1` and the dotfiles apply, restart Warp, then:
- It opens into AlmaLinux-9 (WSL zsh) with Catppuccin Mocha and JetBrainsMono NFM; the `+` menu lists
  exactly `WSL: AlmaLinux-9`, `Windows PowerShell`, `Nushell (compatibility)`. A hand-made Tab Config
  (name not starting `workstation-`) survives a bootstrap re-run; `workstation-*.toml` are rewritten.
- `mise dot status` drift on `settings.toml` after using Warp's Settings panel is expected; re-capture
  with `wsr`. Nushell in Warp is knowingly degraded (unsupported-shell banner); its home is WT.
- **Guard probe, run first:** in a Warp WSL tab, `echo $TERM_PROGRAM; env | grep -iE 'WARP|TERM_PROGRAM'; echo "$WSLENV"`.
  The probe, not documentation, is the source of truth.
  - `WarpTerminal` printed: guards are live. No starship prompt, no fzf Ctrl-T/Ctrl-R, no atuin
    Ctrl-R, no fzf-tab menu, but zsh-autosuggestions, syntax-highlighting, you-should-use and
    history-substring-search must all still work. If one is dead, a guard's `fi` was widened
    (`check_warp_guards` should have caught it).
  - Empty: the guards never fire. Fallback ladder, cheapest first: (a) widen the guard predicate to a
    `WARP_*` variable that does cross; (b) put the value in the launch command,
    `new_session_shell_override = { custom = "wsl.exe --distribution AlmaLinux-9 --cd ~ -- env TERM_PROGRAM=WarpTerminal zsh -l" }`
    (a config change; get sign-off); (c) drop the guards rather than ship dead code. Setting a
    user-scope `WSLENV` is not on the ladder: Warp overwrites rather than merges it
    (warpdotdev/Warp#6241).

## Windows Terminal (the compatibility path; must stay fully working)

After `bootstrap.ps1` and the dotfiles apply, restart WT, then:
- Catppuccin Mocha chrome and scheme, JetBrainsMono NFM 10.5, bar cursor. CTRL+SHIFT+T lands in
  Nushell. The dropdown lists local profiles plus one `SSH: <alias>` per concrete `Host` in
  `%USERPROFILE%\.ssh\config.local`, with no zellij-less duplicate (built-in `Windows.Terminal.SSH`
  stays disabled); an alias lands in that host's zellij `main` session.
- alt+shift+d / alt+shift+r split, alt+shift+arrows move focus, ctrl+shift+z zooms.
- A hand-made profile in `settings.json` and a foreign fragment (`Fragments\other-app\x.json`) both
  survive a bootstrap re-run; `Fragments\workstation\hosts.json` is rewritten (removed when
  config.local has no hosts). Offline: `scripts/test-ssh-launchers.ps1`. Doctor shows an "SSH host
  launcher(s)" row.
- In a WSL tab, starship renders, atuin Ctrl-R works and fzf-tab completes. This is the regression
  check for the Warp guards: WT must behave as before Warp returned. A remote zellij pane shows
  exactly one OSC 133 prompt-zone set.
- Marks: `true` then `false` gives two coloured scrollbar marks; ctrl+up/down jump between prompts;
  alt+shift+d reopens the same WSL dir. alt+shift+b broadcasts to all panes.
- alt+shift+s lists the 7 "Snippet: …" entries and inserts without executing (if stable WT lacks
  `showSuggestions`, drop the action and its README row).
- Taskbar progress shows during `mise run lint` in a WSL tab and clears at the next prompt (needs
  Windows "Show animations"). `$env:WT_SESSION` is non-empty in pwsh; scroll a long output to confirm
  the effective historySize (record the real ceiling in CLAUDE.md if WT clamps below 100000).
