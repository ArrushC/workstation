# DeepSeek Harness on Windows: design

Date: 2026-11-06. Status: agreed in chat (desktop app, nightly, self-updating).

## Intent

Put DeepSeek's official **DeepSeek Harness desktop app** (an open-source agent harness,
MIT, https://github.com/deepseek-ai/deepseek-harness) on the Windows host so it opens from
the Start Menu. The user prefers the desktop app to the `dsh` npm CLI (`npx @deepseek-ai/dsh web`).

## Goals

- A Windows bootstrap (`bootstrap.ps1`) or `ws update` (`wsu`) leaves the app installed,
  per-user, with no UAC prompt and no question asked.
- Only DeepSeek's own build, verified before it runs: the SHA-512 DeepSeek's update feed
  publishes, and an Authenticode signature from DeepSeek's EV certificate.
- Once installed, the app keeps itself current through its built-in updater (nightly channel).
  The repo never moves its version.
- A failure (offline, bad download, installer error) warns and never stops a bootstrap.

## Non-goals

- Linux hosts; the `dsh` npm CLI on any host.
- Managing the app's settings or data (no `[dotfiles]` entries), same stance as codex's
  `~/.codex/config.toml`.
- Pinning or locking a version, a stable channel (none exists yet), the macOS build.
- An opt-out switch (my call: WezTerm's nightly has none either; see "Calls").
- A `mise run health` row (my call: health reads Windows from WSL through `winterop reg`,
  which can't search the Uninstall keys; the installer's own post-install check reports it).

## Anti-goals (a failure even if it "works")

- Installing from winget: every winget package named "DeepSeek Harness"
  (`Sakana-yuyu.DeepSeekHarnessDesktop`, `iuikj.DSHDesktop`,
  `hongfeiyucode.DeepSeekHarnessDesktop`, `ningbainb.DeepSeekHarnessDesktop`) is a
  third-party repackage.
- Running an installer that wasn't checked, including the website's rolling
  `https://download.deepseek.com/desktop/dsh-latest-windows-x64.exe` (no published checksum).
- Downloading ~290 MB on every `wsu` when the app is already installed.
- A UAC prompt, or a bootstrap that stops because of this step.

## Facts this rests on (checked 2026-11-06)

- Feed: `https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml` (electron-updater
  format). Today:
  ```yaml
  version: 0.2.2-rc.1
  files:
    - url: >-
        https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.1-win-x64.exe
      size: 293425336
      sha512: >-
        swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==
  path: >-
    https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.1-win-x64.exe
  sha512: >-
    swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==
  stagingPercentage: 100
  releaseDate: '2026-11-04T09:31:49.677Z'
  ```
  `stable.yml` is a 404 (HTTP 404 with an HTML body). The downloaded installer's SHA-512
  (base64) matched the feed's.
- Signature: `Get-AuthenticodeSignature` reports `Valid`, signer CN
  `Hangzhou DeepSeek Artificial Intelligence Co., Ltd.` (GlobalSign GCC R45 EV CodeSigning CA
  2020, valid to 2027-09-01). The cert will be renewed, so match the name, not a thumbprint.
- Installer (`apps/desktop/scripts/electron-builder-config.mjs`, `apps/desktop/installer/*.nsh`):
  electron-builder NSIS, `oneClick: false`, `perMachine: false`, `allowElevation: false`; it
  refuses an all-users install. `/S` installs silently per-user. A silent run does its own
  preflight and exits 2 when it refuses; it launches the app only from the finish page, so
  never in a silent run. `uninstallDisplayName: '${productName}'`, and `productName` is
  `DeepSeek Harness`, so Windows lists it under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<guid>` with
  `DisplayName = DeepSeek Harness`. The guid is derived from a build-time app id we can't see.
- Updater: electron-updater on the `nightly` channel, plus a mandatory-update policy.
- On this host, `powershell.exe` (5.1) inherited pwsh 7's `PSModulePath`. With it, 5.1 can't
  autoload `Microsoft.PowerShell.Security` (`Get-AuthenticodeSignature`) or `Get-FileHash`.
  Resetting `$env:PSModulePath` to the Machine value fixed it.

## Decided (by the user)

- The desktop app, opened from the Start Menu; not the CLI.
- Nightly channel, self-updating; `wsu` doesn't control its version.

## Design (my calls, approved in outline)

- `scripts/deepseek-harness.ps1` (ASCII, 5.1 and pwsh), run by a new
  `[tasks.deepseek-harness-win]` in `config.windows.toml`, appended to the Windows `post-tools`
  hook, the same place and shape as `wezterm-nightly-win` (`... || exit /b 0`).
- Installed? It looks for an `Uninstall` subkey whose `DisplayName` is exactly
  `DeepSeek Harness`. If one exists, it prints a line and stops, with no network access.
- Missing: it fetches the feed, reads the top-level `version`, `path` and `sha512`, and
  accepts `path` only under `https://download.deepseek.com/dsh-desk/bin/win-x64/` and ending
  in `.exe`. It downloads with curl.exe (wezterm-nightly.ps1's flags) into a fresh folder under
  `%TEMP%`, checks the SHA-512 and then the signer, runs `<installer> /S` with a 15-minute
  limit, and then checks that the app is now listed. The temp folder is always removed.
- Each refusal names its reason in one line, prefixed `deepseek-harness:`; the exit code is
  always 0.
- In Windows PowerShell 5.1 the script first resets `PSModulePath` to the Machine value, and
  it hashes with .NET (`System.Security.Cryptography.SHA512`), not `Get-FileHash`.
- Tests: `scripts/test-deepseek-harness.ps1` (5.1 and pwsh, in the `windows-http` CI job,
  linted by `check-ps.ps1`). It covers the functions through the AST helpers plus whole-script
  runs over `file://` fixtures. It never runs a real installer and never touches the real
  Uninstall key.
- Docs: a README paragraph after Codex; the `-SkipToolInstall` row names the step;
  CLAUDE.md gets a Windows invariant (no winget, verified feed, PSModulePath);
  `docs/claude/verification.md` gets the test recipe.

## Calls the user should check

1. No opt-out: if you uninstall the app, the next `wsu` installs it again.
2. No health row.
3. The installer may add a desktop shortcut (electron-builder's default); the script leaves it.
4. Nightly builds can break compatibility; that's accepted.

## Left to the builder

Message wording beyond the prefixes pinned in the plan; helper layout inside the script.
