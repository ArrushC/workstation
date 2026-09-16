# mise-runtimes: one runtime manager for node, Go, uv and the LSP servers (2026-09-13)

## Goal

Collapse the four runtime install paths (`node-runtime`, `go-runtime`, the
eget `uv` entry, and the multi-mechanism `lsp-servers`) onto **mise**, on
Linux and Windows, with every pin still single-sourced in
`makefile/versions.mk`. mise was installed in the 2026-05 wave and activated in
2026-07 but never given a tool to manage; this makes it the runtime layer.

**In scope:** node, Go, uv, gopls, lua-language-server, basedpyright, the four
npm language-server packages (+ a pinned `typescript`), non-interactive PATH
wiring, the Windows bootstrap, docs and guards.

**Out of scope, deliberately:** the eget static-binary toolbelt stays on
`EGET_TOOL` (eget still installs mise itself — something has to); `python-env`
keeps its uv-built venv (mise never declares `python`, so the system
interpreter is never shadowed); the three both-scopes eget LSP binaries
(`rust-analyzer`, `marksman`, `taplo`) stay `EGET_TOOL`s; clangd stays dnf.

## Verified facts the design rests on (2026-09-13)

- **Isolated spike** (`MISE_DATA_DIR`/`MISE_CONFIG_DIR` in the scratchpad,
  mise 2026.8.16): a `conf.d/*.toml` declaring `uv`, `pipx:basedpyright`,
  `lua-language-server` and `node = { postinstall = "npm install -g …" }`
  installed in 7.6 s. mise verified the uv tarball via **GitHub artifact
  attestations + checksum** (today's `node.sh`/`go.sh` curl without verifying
  anything). `pipx:basedpyright` ran `uv tool install` — **no mise python was
  installed**, `python3` still resolved to `/usr/bin/python3`. Native shims
  appeared for every bin, including the npm-global ones
  (`typescript-language-server`, `tsc`, `bash-language-server`) and
  `basedpyright-langserver`. `typescript-language-server --version` worked,
  i.e. it found `typescript` as its global sibling — but `--version` never
  loads tsserver; the final review (2026-09-13) showed TS 7.0.2 has no
  `lib/tsserver.js` and ts-ls 6.0.0 fails `initialize` against it, so the pin
  is 5.9.3 (bumper-EXCLUDEd, coupling-checked) and the verification is an
  `initialize` round-trip.
- **Registry / version formats** (`mise ls-remote`): `node`, `go`, `uv`
  (aqua), `lua-language-server` (aqua), `go:golang.org/x/tools/gopls`,
  `npm:…`, `pipx:basedpyright` all list versions in exactly the form
  `versions.mk` pins them (no `v`).
- **Shims + activate coexist**: with `~/.local/share/mise/shims` prepended
  before `eval "$(mise activate zsh)"`, `mise doctor` reports
  `activated: yes` and `shims_on_path: yes`; the shims dir stays on PATH.
- **Nushell autoload**: `mise activate nu` saved under
  `$nu.data-dir/vendor/autoload/mise.nu` is picked up (its `export-env` ran;
  `MISE_SHELL` set) with nu 0.113.1 — the starship precedent transfers.
- **mise dirs on Windows** (src/env.rs): config dir = `XDG_CONFIG_HOME/mise`
  with `XDG_CONFIG_HOME` defaulting to `HOME/.config` on **every** platform;
  data dir = `%LOCALAPPDATA%\mise`; shims = `<data>/shims`. So chezmoi's
  `.config/mise/conf.d/` lands where mise reads it on both OSes.
- **Windows release zip** `mise-v2026.9.1-windows-x64.zip` (sha256
  `9556296db217774e7dae8fc241542d6bbc2351122ba93c8df2a65d3b921d7a28`) nests
  `mise/bin/mise.exe` + `mise/bin/mise-shim.exe`; `src/shims.rs` validates
  the shim source next to the binary — native `.exe` shims need both.
- **postinstall** runs after the tool's own install with the tool's bin dirs
  and its dependencies' bin dirs on PATH (`npm` for a node hook), env
  `MISE_TOOL_INSTALL_PATH`; it does **not** re-run for an already-installed
  version, which is why the target force-reinstalls node whenever the
  declared version is already present and still declared.

## Decisions

1. **One generated config, deployed by chezmoi to both OSes.**
   `scripts/gen-mise-config.sh` reads `versions.mk` and writes two **plain**
   TOML files (not templates, so Make can consume them before dotfiles
   exist) into `chezmoi/dot_config/mise/conf.d/`, each with a do-not-edit
   banner:

   ```toml
   # workstation.toml — both scopes
   [tools]
   uv = "0.12.7"
   ```
   ```toml
   # workstation-dev.toml — dev_machine only
   [tools]
   node = { version = "26.8.1", postinstall = "npm install -g typescript-language-server@6.0.0 typescript@5.9.3 bash-language-server@5.6.0 yaml-language-server@1.24.0 vscode-langservers-extracted@4.10.0" }
   go = "1.27.0"
   "go:golang.org/x/tools/gopls" = "0.23.0"
   lua-language-server = "3.19.1"
   "pipx:basedpyright" = "1.39.10"
   ```
   Sync is the TOOLS-block pattern: `.claude/hooks/sync-tool-memory.sh` runs
   the generator on makefile edits, `scripts/bump-versions.sh` runs it after
   bumping, `check-invariants.sh` regenerates to a temp dir and diffs, and
   parses both files with `python3 tomllib`. Rejected alternatives:
   imperative `mise use -g` lists on each side (≈10 new dual-edits with
   `bootstrap.ps1`, and mise would own a config chezmoi doesn't track) and a
   hand-maintained template holding the pins (breaks the versions.mk
   invariant, the weekly bumper and `make check-updates`).
2. **The npm servers ride node's `postinstall`, as one `npm install -g`
   line — not per-tool `npm:` entries.** `typescript-language-server` resolves
   `typescript` by walking up from its own global install; per-tool trees
   would break that (the reason `lsp.sh` installs `typescript` alongside
   today). `typescript` gets its own pin, `TYPESCRIPT_VERSION := 5.9.3`
   (the last tsserver-capable line; see Verified facts) (today it floats).
   Consequence: a pin change for any npm server changes the
   postinstall string but not node's version, so the target runs
   `mise install --yes --force node` whenever its stamp is stale **and** node
   was already installed (skipped on a fresh host, where the first install
   already ran the hook).
3. **Backends for the rest:** `go:golang.org/x/tools/gopls` (compiled with
   mise's pinned Go — `check_go_gopls_coupling` stays valid), `lua-language-
   server` via its registry (aqua) entry, `pipx:basedpyright` (uses `uv tool
   install`; never adds a python). `python` is never declared.
4. **`mise-runtimes` is a BOTH-scopes, user-level Make target** joining
   `PROVISION_FANOUT`; order-only dep on the mise eget stamp **file**
   (`$(STAMP)/mise-$(MISE_VERSION).done`). Its stamp bakes `cksum` of the
   config file(s) it consumes (both-scopes file, plus the dev file on
   `MODE=dev`), so any pin change re-fires it. Recipe via a new
   `makefile/lib/mise.sh` (LF, 0755, shfmt/shellcheck-clean):
   - `seed <mode> <src-dir>` — copies the right file(s) into
     `~/.config/mise/conf.d/` (`install -m 0644`). chezmoi later deploys
     identical bytes, so `chezmoi update` never prompts. Needed because the
     fanout runs before the `dotfiles` phase, and on a virgin host before
     `bootstrap.sh`'s `chezmoi init --apply`.
   - `install` — `mise install --yes`; then the conditional `--force node`
     (decision 2); then `mise prune --yes` (drops versions no config
     references — the old `_node-*`/`_go-*` sweep, and it also removes the
     stray `aqua:nushell/nushell` on this host); mise reshims on its own.
     A failure leaves the stamp unwritten (next `make` retries); mise still
     installs the other tools, so a single server outage never takes the
     rest down.
   - `sweep-legacy <mode> <dest>` — one-time removal of the pre-mise artifacts
     under `$(DEST)`: the `node npm npx corepack go gofmt uv uvx gopls
     lua-language-server typescript-language-server bash-language-server
     yaml-language-server vscode-*-language-server tsc tsserver` entries, the
     `_node-*`, `_go-*`, `_lua-language-server-*` trees and
     `$(DEST)/../lib/node_modules`. prod: only `uv`/`uvx` — the eget pair this
     repo put in `~/.local/bin`; the full list is dev-only (node/go/LSP were
     never installed on prod, so a matching name there is the user's own).
     Invoked under `$(SUDO)` (dev: `/usr/local`; prod: `~/.local/bin`, `SUDO`
     empty). Idempotent, prints what it removed.
   - `sweep-user` — never sudo: `uv tool uninstall basedpyright` (the old
     user-site install) + its `~/.local/bin/basedpyright*` launchers, and the
     stale `node-*`, `go-*`, `uv-*`, `lsp-servers-*` stamps.
   `clean-mise-runtimes` uninstalls the declared tools and drops the stamp.
   `verify-binary.sh` is not applied — mise verifies its own downloads.
5. **`lsp-servers` survives as a thin dev alias** (`rust-analyzer marksman
   taplo mise-runtimes` + the clangd presence check inlined), so
   `make lsp-servers MODE=dev` in the README keeps working. `LSP_PINS`/
   `LSP_STAMP` go. `node-runtime`, `go-runtime`, `clean-node-runtime`,
   `clean-go-runtime`, `clean-lsp-servers`, `lib/node.sh`, `lib/go.sh`,
   `lib/lsp.sh` are deleted. The `uv` `EGET_TOOL` line leaves `tools.mk`
   (a manual `UPDATE_SPECS += uv|$(UV_VERSION)|astral-sh/uv|$(UV_VERSION)`
   replaces the macro-registered spec; `typescript|…|microsoft/TypeScript|
   v$(TYPESCRIPT_VERSION)` is added).
6. **Consumers re-point at the stamp and prefix PATH themselves.**
   `python-env`'s order-only dep becomes the `mise-runtimes` stamp file; its
   recipe (and `claude-statusline`'s) runs with
   `PATH="$(MISE_SHIMS):…"` where `MISE_SHIMS := $(HOME)/.local/share/mise/shims`,
   so the bootstrap tail finds `npx` before any shell has activated mise.
   `setup-ccstatusline.sh`'s hint text and `python-env.sh`'s "run `make uv`
   first" message say `make mise-runtimes`.
7. **Non-interactive PATH = shims, interactive = activate on top.** New
   tracked `chezmoi/dot_zshenv` (two guarded prepends: `~/.local/bin` — the
   host's pre-chezmoi `.zshenv` already carried it — then the shims) (zsh
   reads it for every invocation, including `ssh host cmd`) and a guarded
   export **above** the `[[ $- != *i* ]] &&
   return` guard in `dot_bashrc.tmpl`; both guard against duplicate entries
   (`case ":$PATH:" in …`). The existing `mise activate` blocks stay; their
   comments now describe the global pins. `~/.local/bin` still sits ahead of
   the shims in interactive shells — harmless (activate's real bin dirs win)
   and the sweeps remove every stale launcher that could have shadowed a shim.
   `.zshenv` is Linux-only: `.zshenv` joins the Windows block of
   `.chezmoiignore.tmpl` (target path). The dev config file joins the prod
   block: `.config/mise/conf.d/workstation-dev.toml`.
8. **Pin bookkeeping.** Already in PR 1: `gen-tool-memory.sh` gains
   `NAMES[UV_VERSION]="uv"` and `NAMES[TYPESCRIPT_VERSION]="typescript"`
   (neither is a macro tool now), plus manual `uv` and `typescript` update
   specs in `tools.mk`. In PR 2 (Windows still installs uv directly until
   then): `UV_VERSION` leaves `bump-versions.sh`'s `EXCLUDE` and
   `check_version_pins` (no Windows half any more); `MISE_VERSION` joins both
   (`versions.mk` ↔ the `jdx/mise/releases/download/v<ver>` URL in
   `$PortableTools`).
9. **Doctor.** `DOCTOR_ROWS` swaps `bespoke|node-runtime|…` for
   `bespoke|mise-runtimes|<stamp>`; `doctor.sh`'s case checks stamp present,
   `mise ls --missing` empty, and each expected shim resolvable (dev: node npm
   npx go gofmt uv uvx gopls lua-language-server basedpyright-langserver
   typescript-language-server bash-language-server yaml-language-server
   vscode-json-language-server; prod: uv uvx). `check_wiring` gains a
   `~/.zshenv` shims row beside the existing `mise activate` row.
10. **Windows: mise is a pinned portable tool** (`Layout = "tree"` →
    `workstation\mise`) with a new opt-in `BinSubdir = "bin"` key —
    `Install-PortableTool` honours it in exactly two places: the stamp's exe
    check and the dir handed to `Add-ToUserPath`. `Repo = "jdx/mise"`,
    `TagPrefix = "v"`, `UpdateHint` names the dual-edit. `uv` leaves
    `$PortableTools` (and `$WsUv`); the `-SkipToolInstall` summary text and
    doctor rows follow.
11. **Windows: `Invoke-MiseRuntimes` runs right after `Invoke-Chezmoi`** (new
    step 4b): chezmoi has just deployed both config files to
    `%USERPROFILE%\.config\mise\conf.d\`. Stamp = `mise-runtimes.<sha256 of
    the two files>.stamp` under `$WsStamps` (shared with Doctor via a
    `Get-MiseRuntimesStamp` helper, the `Get-PythonEnvStamp` precedent). When
    stale: `mise install --yes`, the conditional `--force node`, `mise prune
    --yes`. Every run: `Add-ToUserPath "$env:LOCALAPPDATA\mise\shims"`
    (self-heals like the Start Menu shortcuts). Warn-and-continue; skipped by
    `-SkipToolInstall`; requires `mise` on PATH (else warn).
12. **Windows shells.** `Invoke-NushellMise` (sibling of `Invoke-NushellStarship`,
    every run, UTF-8 no BOM) writes `%APPDATA%\nushell\vendor\autoload\mise.nu`
    from `mise activate nu`; `config.nu.tmpl` only gains a comment (autoload
    files need no `source`). `Microsoft.PowerShell_profile.ps1.tmpl` gets a
    `Get-Command`-guarded `(& mise activate pwsh) | Out-String |
    Invoke-Expression` block next to starship/zoxide.
13. **Windows Python env.** `Invoke-PythonEnv` resolves `$uvExe = (& mise
    which uv)` and warns-and-skips if empty ("mise runtimes step failed?").
    Stamp, `$PythonEnvVersion`, `$PythonLibs` and the lib-list parity check
    are untouched.
14. **Side effect, not a goal:** the dev config deploys to Windows, so the
    Windows host installs node, Go, gopls and the LSP servers for the first
    time; `.lsp.json` resolves them by bare name through the shims dir.
    Verified on the host during PR 2 but not a merge blocker; `.lsp.json` is
    not edited.

## Data flow

```
makefile/versions.mk ──gen-mise-config.sh──▶ chezmoi/dot_config/mise/conf.d/{workstation,workstation-dev}.toml
        │                                                 │
        │ (hook on edit; bumper after bump; drift-checked in CI)
        │                                                 │
Linux:  make mise-runtimes ──seed──▶ ~/.config/mise/conf.d/ ──mise install──▶ ~/.local/share/mise/{installs,shims}
        chezmoi update later deploys the same bytes (no prompt)
        .zshenv / .bashrc (shims) + .zshrc / .bashrc (activate) expose them
Windows: chezmoi init --apply ──▶ %USERPROFILE%\.config\mise\conf.d\ ──Invoke-MiseRuntimes──▶ %LOCALAPPDATA%\mise\{installs,shims}
        vendor\autoload\mise.nu (nu) + profile activate (pwsh) + shims on User PATH
```

## Migration on existing hosts

Linux dev: `make dev` (or `czu` → `update-hosts.sh`) installs via mise and
sweeps `/usr/local`; open a new shell (or `exec zsh`) to pick up `.zshenv`.
Prod: the same, user-level; the eget `uv`/`uvx` in `~/.local/bin` are swept.
Windows: re-run `.\bootstrap.ps1`; restart the terminal for the User PATH. The
mise step also sweeps the retired portable uv (`%LOCALAPPDATA%\workstation\uv`,
its stamp and its User PATH entry — the counterpart of decision 4's prod
`uv`/`uvx` sweep) so the stale copy cannot shadow mise's uv.

## Documentation

- `CLAUDE.md`: the `node-runtime`, `go-runtime + lsp-servers` and
  `python-env` bullets collapse into one **mise-runtimes** invariant; the
  Windows-installs bullet (mise portable + `BinSubdir`; uv removed), the
  dual/triple-edit list (`UV_VERSION` out, `MISE_VERSION` in), the
  careful-files list (`lib/mise.sh` in; `node.sh`/`go.sh`/`lsp.sh` out), the
  hooks paragraph (`sync-tool-memory.sh` regenerates both artifacts), the
  single-source list (`gen-mise-config.sh`), the zsh section (`.zshenv`).
- `docs/claude/invariants.md`, `file-care.md`, `verification.md`: matching
  entries (verification: the recipes below).
- `README.html`: stack cards (mise, uv, Go, the LSP set), the LSP
  troubleshooting entry, the Windows tools paragraph, every
  `make … node-runtime`/`go-runtime` mention → `make mise-runtimes`,
  the `-SkipToolInstall` lists.
- `CLAUDE_CHANGELOG.md`: one row per PR.

## Verification

Linux (this host): `make lint MODE=prod`, `bash .claude/hooks/test-hooks.sh`,
`scripts/check-templates.sh`, `node scripts/check-readme.mjs`; then for real:
`make -C makefile mise-runtimes MODE=dev`, `make doctor MODE=dev`,
`mise doctor` (activated: yes, shims_on_path: yes), `mise ls --missing` empty,
`typescript-language-server --version`, `gopls version`,
`basedpyright-langserver --version`, `lua-language-server --version`,
`zsh -c 'command -v node'` and `bash -c 'command -v node'` resolving to the
shims dir, `make -C makefile python-env MODE=dev` + the wpy import line, and
a prod sandbox `make all MODE=prod DEST=/tmp/test STAMP=/tmp/stamps -n`.
Windows (the host): `.\bootstrap.ps1`, `mise doctor`, `mise ls --missing`,
`nu -c 'which node'`, `Get-Command node` in pwsh, the Python env rebuilt via
mise's uv, `.\bootstrap.ps1 -Doctor`, `-CheckForUpdates`,
`pwsh scripts/check-ps.ps1`.

## Delivery

- **PR 1 (Linux):** `scripts/gen-mise-config.sh` + generated TOML,
  `makefile/{Makefile,tools.mk,versions.mk}`, `lib/mise.sh` (+ deletions),
  `lib/doctor.sh`, `lib/python-env.sh`, `scripts/setup-ccstatusline.sh`,
  `dot_zshenv`, `dot_bashrc.tmpl`/`dot_zshrc.tmpl` comments,
  `.chezmoiignore.tmpl`, hook + `test-hooks.sh`, `check-invariants.sh`,
  `bump-versions.sh`, `gen-tool-memory.sh`, docs.
- **PR 2 (Windows):** `bootstrap.ps1` (portable entry + `BinSubdir`,
  `Invoke-MiseRuntimes`, `Invoke-NushellMise`, `Invoke-PythonEnv`, Doctor),
  `config.nu.tmpl` comment, `Microsoft.PowerShell_profile.ps1.tmpl`,
  `check-invariants.sh` (mise dual-edit), docs.
