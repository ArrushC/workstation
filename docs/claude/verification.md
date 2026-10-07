# Quick verification

> Recipes for verifying a change, grouped by subsystem. The rules they protect are in CLAUDE.md.
> Automated checks (`mise run lint` = `scripts/check-invariants.sh`, `bash scripts/check-templates.sh`,
> and the `lint.yml` CI jobs; lint also runs the hook and pin self-tests) cover most static invariants; the recipes below are what they don't.

## Host state and tools (read-only, no sudo)

- `MISE_ENV=<set> mise bootstrap plan --json | jq .summary` gives create/update/remove/unchanged
  counts (0/0/0/N on a stable host). `mise bootstrap status --missing` lists only rows needing
  attention. Sets: `linux` and `windows`. Safe unprivileged
  because there is no firewall table. Both refuse a dotfiles conflict like a real apply unless
  `--force-dotfiles` is passed.
- `mise run health` is the full report (config set and system steps, `miserc.toml`, pueued, python-env,
  dotfiles drift, dirty checkout); exit 1 on a hard failure. `mise tasks validate`
  catches malformed `#MISE` headers; `mise ls --missing` should be empty.
- Sandbox install plus capability gate (no sudo):
  ```
  MISE_CONFIG_DIR=$PWD MISE_DATA_DIR=/tmp/mise-sandbox MISE_STATE_DIR=/tmp/mise-sandbox-state \
    MISE_CACHE_DIR=/tmp/mise-sandbox-cache MISE_ENV=linux mise install \
    && MISE_DATA_DIR=/tmp/mise-sandbox tasks/verify-tools
  ```
  Expect `✓ verify-tools: N ELF binaries pass`. A failure means that tool needs an explicit
  `github:` `asset_pattern`. Set `GITHUB_TOKEN` to avoid API rate limits.
- Tools install path (after touching `mise-env.sh`, `mise-install.sh`, `verify-tools`, the rc guard
  block): `bash scripts/test-mise-install.sh` (PASS), then on a real host `mise doctor`
  (activated + shims_on_path yes) and `zsh -c 'command -v node'` resolving to the mise shim. A
  second `mise bootstrap --yes` is a fast no-op.
- Locks: never hand-edit. Regenerate from outside the checkout for the changed tools, then fold any
  `.mise/locks/` into `locks/` as `normalize_lock_sidecars` in `scripts/bump-versions.sh` does:
  `L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"`, then
  `(cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=linux mise lock --global --platform linux-x64 <tools>)`
  and the same with `MISE_ENV=windows … --platform windows-x64` for tools that install on Windows.
  `check-invariants.sh` verifies coverage.
- pueued: `systemctl --user cat dev.mise.pueued.service` has no `Environment=MISE_ENV=` line;
  `~/.config/mise/miserc.toml` has the right `env = [...]`; `systemctl --user is-active dev.mise.pueued`
  prints `active`.
- python-env: `mise run python-env && wpy -c "import textual, click, rich, httpx, pydantic, typer, polars, duckdb; print('ok')"`.
  A second run prints "up to date"; `mise run python-env --rebuild` forces an upgrade. The env is built on
  `mise where python`. Windows' `Invoke-PythonEnv` reads the same `scripts/python-env.txt` (`scripts/test-python-fonts.ps1`).
- Fonts: `fc-list | grep -i 'jetbrainsmono nerd font mono' | wc -l` is 6 on native Linux hosts, 0 on
  WSL. Windows: 6 `JetBrainsMonoNerdFontMono-*.ttf` under
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
  run it. It renders every template individually for both token sets, syntax-checks, then
  bulk-applies; clean output ends `all rendered templates pass under every MISE_ENV set (linux windows)`.
- fastfetch finds `~/.config/fastfetch` through the passwd home, not `$HOME`: in a scratch home also set
  `XDG_CONFIG_HOME="$SCRATCH/.config"`, or it silently prints its default layout.
## Windows (`bootstrap.ps1`)

- Parse check under 5.1, the floor (no ternary, `??` or `&&`): copy the file to `%TEMP%\bs.ps1`, then
  `powershell.exe -NoProfile -Command 'Set-Location $env:USERPROFILE; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\bs.ps1",[ref]$null,[ref]$e); if($e){$e|%{$_.ToString()}; exit 1}else{"parse OK"}'`.
  A bare `ParseFile(...,[ref]$null)` prints ok even on errors. `mise run lint` checks the BOM and
  `${name}:` braces.
- Offline tests: each `scripts/test-*.ps1` runs under 5.1 and pwsh in the `windows-http` CI job, and
  PSScriptAnalyzer covers them in the `powershell` job. They load functions from the script's AST;
  those that reach `mise`, `winget`, the registry or the User environment stub them and refuse to run
  unless the stub is what would be called.

  | Test | Covers |
  |---|---|
  | `test-curl.ps1` | `Invoke-CurlRequest` |
  | `test-config-local.ps1` | `Set-ConfigLocalVar`, `Invoke-EnsureConfigLocal` |
  | `test-ssh-launchers.ps1` | SSH host parsing, the WT fragment, the Warp Tab Configs |
  | `test-mise-env.ps1` | `miserc.toml`; `Install-Mise` (rename-aside, keep-old, sha mismatch); the `config.windows.toml` guard; `-C` pinning; the node marker |
  | `test-winget-apps.ps1` | `Install-WingetApps` (`mise bootstrap --only packages`, pinned `-C`) and `Install-SshfsWin` (presence by `winget list`, no `--silent`, the UAC warning, `-SkipElevated`, exit codes) |
  | `test-python-fonts.ps1` | `Invoke-PythonEnv`, `Invoke-InstallNerdFonts`, and `install-nerd-fonts.ps1` on fake TTFs |
- From WSL interop: copy `bootstrap.ps1`, `scripts/*.ps1` and `scripts/python-env.txt` under
  `%TEMP%` (keep the `scripts\` layout: tests find the repo as their parent dir), `cd` to
  `%USERPROFILE%` and run each with `-NoProfile -ExecutionPolicy Bypass -File` under `powershell.exe`
  and `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`. powershell.exe 5.1 needs the Machine
  PSModulePath (`PSModulePath="$(powershell.exe -NoProfile -Command
  "[Environment]::GetEnvironmentVariable('PSModulePath','Machine')" | tr -d '\r')"
  WSLENV=PSModulePath/w powershell.exe ...`): the inherited pwsh 7 path makes 5.1 report
  "Get-FileHash is not recognized" (a false failure; CI is unaffected).
- Live checks (the user runs `.\bootstrap.ps1`; then, in a new PowerShell window):
  - `$env:MISE_ENV` is empty and `miserc.toml` holds `env = ["windows"]`.
  - `Get-Command starship, jq, hx, nu, omp, opencode, DevToys.CLI, gh` resolve under
    `%LOCALAPPDATA%\mise\shims` (gh may be a machine-wide install).
  - `mise doctor` says `activated: yes` and `shims_on_path: yes`; `mise dot status` lists nothing
    unapplied; `mise bootstrap status` is clean.
  - `mise bootstrap packages status` lists the eight `config.windows.toml` apps as installed, and `winget --info` prints no settings warning.
  - `wpy -c "import sys, textual; print(sys.version)"` prints the `tools.python` version; there are six
    `JetBrainsMonoNerdFontMono-*.ttf` under `%LOCALAPPDATA%\Microsoft\Windows\Fonts`.
  - Windows Terminal opens Nushell, and so does Warp's `Nushell (compatibility)` tab.
  - The run installed no app that was present (no second DevToys or Zed); a second run reports
    "already installed"/"present" throughout.
  - Only a live host shows: a `$MiseVersion` bump with a Nushell tab open (`mise.exe` renamed to
    `*.old`), SSHFS-Win's UAC prompt(s) on a fresh host, Zed installing per-user from its
    machine-scope-only installer despite winget's user-scope preference, and a font bump replacing a loaded TTF.

## zellij

- `copy_command` must stay unset (OSC 52 is the only clipboard path over SSH). Verify by yanking in a
  remote pane and pasting locally; zellij reads config at session creation, so `zellij kill-session main`
  first. `check_zellij_config` covers the theme name, KDL comments, `web_server`, tab-bar alias and
  `zellij setup --check`.
- zjstatus: loads from mise's install dir. Headless check: start a throwaway background session with
  the tracked config (`ZELLIJ_CONFIG_DIR=<temp copy of dotfiles/config/zellij> zellij attach
  --create-background <name>`), judge by zellij's log, not `dump-layout`
  (`grep -E "Loaded plugin|No such file" /tmp/zellij-$UID/zellij-log/zellij.log` must show
  `Loaded plugin '…/github-dj95-zjstatus/latest/zjstatus.wasm'`), then `zellij kill-session <name>`.
  On a host: `wsa`, `zellij kill-session main`, reattach, press `y` at the permission prompt.

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
  config.local has no hosts). Offline: `scripts/test-ssh-launchers.ps1`.
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
