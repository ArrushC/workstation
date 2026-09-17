# mise Tools (PR1: toolbelt on mise + repo relocation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Linux toolbelt tool and every runtime is declared in `config*.toml` at the repo root and installed by mise, the repo checkout becomes `~/.config/mise` (Linux) / `%USERPROFILE%\.config\mise` (Windows), the eget/archive/direct/pip installer layer and `tools.mk` are deleted, and the fleet migrates on its next bootstrap — with Make, chezmoi and every non-tool target left in place for PR2/PR3.

**Architecture:** mise's global config dir IS the repo: `config.toml` (cross-platform: uv), `config.linux.toml` (the ~85-tool Linux toolbelt, both scopes), `config.dev.toml` (dev tools on both OSes + Linux-only dev tools with `os = ["linux"]`), `mise.lock` (versions, URLs, sha256 for linux-x64 and windows-x64). Which env files load is selected by `MISE_ENV` (`linux` / `linux,dev,host,wsl` / `linux,dev,host,native` / `windows,dev`), computed by `scripts/lib/mise-env.sh` and exported by the rc files. `scripts/lib/mise-install.sh` does the install (+ node postinstall re-run marker + prune); `tasks/verify-tools` is the capability gate (existing `verify-binary.sh` over every ELF in `mise bin-paths`); `tasks/migrate-legacy` sweeps the pre-mise binaries once. Make keeps packages/shell/dotfiles/services/python-env/claude/nerd-fonts/vcpkg; its `tools` target now just calls the three scripts. Windows keeps `$PortableTools` and runs `mise install` against the same config files.

**Tech Stack:** mise 2026.9.9 (aqua/github/http/core/pypi/npm backends, lockfile), bash, GNU make (transitional), PowerShell 5.1/7, chezmoi (transitional), python tomllib via `wpy` (3.14) locally / `python3` ≥3.11 in CI.

**Spec:** `docs/superpowers/specs/2026-09-16-mise-everything-design.md` — sections 1, 2, 3, 5, 9 and the PR1 row of section 10 are binding for this plan.

## Global Constraints

- mise pin is **2026.9.9** everywhere: `MISE_VERSION="2026.9.9"` in `bootstrap.sh`, `Version = "2026.9.9"` in `bootstrap.ps1`'s `$PortableTools`, `min_version = "2026.9.9"` in `config.toml`. Linux asset `mise-v2026.9.9-linux-x64-musl.tar.gz` sha256 `986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc`; Windows asset `mise-v2026.9.9-windows-x64.zip` sha256 `f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07`.
- Repo path after this PR: Linux `$HOME/.config/mise`, Windows `%USERPROFILE%\.config\mise`. The old path `~/.local/share/chezmoi` is migrated by `bootstrap.sh` / `bootstrap.ps1`, never assumed elsewhere except in that migration code and in `update-hosts.sh`'s remote fallback.
- `MISE_ENV` token sets are exactly: prod Linux `linux`; dev WSL `linux,dev,host,wsl`; dev native `linux,dev,host,native`; Windows `windows,dev`. `config.host.toml`, `config.native.toml`, `config.wsl.toml`, `config.windows.toml` do NOT exist yet (PR2/PR3); mise must tolerate a named env with no file (verified in Task 1 step 2).
- Every tool that was in `makefile/tools.mk` appears exactly once across `config.toml` / `config.linux.toml` / `config.dev.toml` with the SAME version pin `makefile/versions.mk` had on `main` at `304f943` (except: `eget` is dropped; `chezmoi` stays at `latest`; `cht.sh` becomes a soft-fail Make recipe step; `claude` stays a Make target).
- Tools are user-level only (mise's data dir). No `[tools]` entry may need sudo. `/usr/local/bin` is only ever *cleaned* by `tasks/migrate-legacy`.
- Do NOT set `[settings] lockfile = true` (it would auto-create lockfiles in the user's other projects); commit `mise.lock` and rely on mise updating an existing lockfile. Do NOT set `[task_config].includes` (breaks global task discovery, verified).
- `[tools]` entries in `config.dev.toml` that must not install on Windows carry `os = ["linux"]`; entries in `config.linux.toml` never need it (that file loads only with the `linux` token).
- LF line endings + git mode 100755 for every `scripts/**/*.sh`, `tasks/*`, `makefile/lib/*.sh`; UTF-8 BOM on `bootstrap.ps1`; `shfmt -i 2` clean; shellcheck clean at warning+.
- README.html + `CLAUDE_CHANGELOG.md` are updated in this PR for every user-facing change (repo path, `make tools`, `mise outdated`, adding a tool, troubleshooting).
- Never run `sudo` non-interactively from a task or from the controller; hand sudo-requiring commands to the user (`!` prefix). `mise install`, `tasks/verify-tools`, `make doctor` need no sudo.
- Branch: `feat/mise-tools` (spec already committed there as `304f943`). Commit after every task; push after every commit.

---

## File map

| Path | Task | Responsibility |
|---|---|---|
| `config.toml` (new) | 1 | `min_version`, cross-platform `[tools]` (uv) |
| `config.linux.toml` (new) | 1 | Linux toolbelt, both scopes |
| `config.dev.toml` (new) | 1 | dev tools (both OSes) + Linux-only dev tools with `os` |
| `mise.lock` (new) | 1 | linux-x64 + windows-x64 lock |
| `.gitignore` | 1 | `config.local.toml`, `.superpowers/` unchanged |
| `chezmoi/dot_config/mise/` (delete) | 1 | old generated conf.d |
| `scripts/gen-mise-config.sh`, `scripts/test-mise.sh` (delete) | 1 | old generator + its test |
| `scripts/lib/mise-env.sh` (new) | 2 | prints the MISE_ENV token set for `<dev|prod>` |
| `scripts/lib/mise-install.sh` (new) | 2 | `mise install` + node postinstall marker + prune |
| `scripts/lib/verify-binary.sh`, `scripts/lib/test-verify-binary.sh` (moved from `makefile/lib/`) | 2 | capability check |
| `tasks/verify-tools` (new) | 2 | gate over `mise bin-paths` |
| `tasks/migrate-legacy` (new) | 2 | one-time sweep of pre-mise artifacts |
| `scripts/test-mise-install.sh` (new) | 2 | offline test of mise-install.sh with a fake mise |
| `makefile/tools.mk`, `makefile/lib/{eget,archive,direct,pip,pipe,helix,mise,pwndbg,devtoys-cli,zellij-plugin}.sh` (delete; zellij-plugin.sh MOVES to `scripts/lib/`) | 3 | old installer layer |
| `makefile/Makefile`, `makefile/scope.mk`, `makefile/versions.mk`, `makefile/lib/doctor.sh`, `makefile/lib/check-updates.sh` | 3 | `tools` target = the three scripts; bespoke-only doctor/updates |
| `bootstrap.sh`, `scripts/update-hosts.sh`, `chezmoi/.chezmoi.toml.tmpl`, `chezmoi/.chezmoiignore.tmpl` | 4 | relocation, pinned mise install, MISE_ENV, chezmoi sourceDir |
| `bootstrap.ps1` | 5 | RepoPath move, MISE_ENV user var, mise 2026.9.9, config-file stamp |
| `chezmoi/dot_zshenv` → `chezmoi/dot_zshenv.tmpl`, `chezmoi/dot_zshrc.tmpl`, `chezmoi/dot_bashrc.tmpl`, `chezmoi/dot_config/systemd/user/pueued.service.tmpl`, `chezmoi/private_dot_claude/modify_private_settings.json`, `scripts/setup-ccstatusline.sh`, `scripts/check-templates.sh`, `chezmoi/private_dot_claude/{CLAUDE.md,skills/workstation-lsp/SKILL.md}` | 6 | rc/env wiring, ccstatusline command |
| `scripts/check-invariants.sh`, `scripts/gen-tool-memory.sh`, `.claude/hooks/{sync-tool-memory,parity-reminder,post-edit-guard,test-hooks}.sh` | 7 | pins from TOML, lock coverage, hook triggers |
| `scripts/bump-versions.sh`, `.github/workflows/{lint,version-bumps}.yml` | 8 | bumper on `mise outdated`, CI on mise-action |
| `README.html`, `CLAUDE.md`, `docs/claude/{invariants,file-care,verification}.md`, `CLAUDE_CHANGELOG.md`, `.claude/memory/*` | 9 | docs |
| (no files) | 10 | on-host verification + rollout hand-off |

---

### Task 1: Tool declarations + lockfile, proven by a scratch install

**Files:**
- Create: `config.toml`, `config.linux.toml`, `config.dev.toml`, `mise.lock`
- Modify: `.gitignore`
- Delete: `chezmoi/dot_config/mise/conf.d/workstation.toml`, `chezmoi/dot_config/mise/conf.d/workstation-dev.toml`, `scripts/gen-mise-config.sh`, `scripts/test-mise.sh`
- Test: the scratch install itself (`mise ls --missing` empty, `verify-binary.sh` clean over every ELF)

**Interfaces:**
- Consumes: pins in `makefile/versions.mk` (read them from the file; the table below is derived from it), the existing `chezmoi/dot_config/mise/conf.d/*.toml` (carry their `[tools]` entries over verbatim).
- Produces: the three config files with the exact tool keys later tasks grep (`node`, `uv`, `jq`, `gh`, `helix`, `opencode`, `"github:can1357/oh-my-pi"`, `"github:DevToys-app/DevToys"`, `zellij`, `"github:dj95/zjstatus"`, `shfmt`, `gitleaks`, `go`, `"go:golang.org/x/tools/gopls"`, `"npm:ccstatusline"`), `mise.lock` at the repo root.

- [ ] **Step 1: Bump the locally installed mise first (it is the build tool for this task)**

```bash
cd ~/.local/share/chezmoi
mkdir -p ~/.local/bin
curl -fsSL -o /tmp/mise.tgz https://github.com/jdx/mise/releases/download/v2026.9.9/mise-v2026.9.9-linux-x64-musl.tar.gz
echo "986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc  /tmp/mise.tgz" | sha256sum -c -
tar -xzf /tmp/mise.tgz -C /tmp && install -m 0755 /tmp/mise/bin/mise ~/.local/bin/mise
export PATH="$HOME/.local/bin:$PATH"; hash -r; mise --version   # expect 2026.9.9
```
(`/usr/local/bin/mise` 2026.9.1 stays until the sweep in Task 10; `~/.local/bin` precedes it on PATH in every shell this repo manages.)

- [ ] **Step 2: Verify two assumptions on the new binary before writing config**

```bash
S=/tmp/mise-t1; rm -rf $S; mkdir -p $S/cfg $S/home $S/data $S/state $S/cache
printf 'min_version = "2026.9.9"\n[tools]\njq = "1.8.2"\n' > $S/cfg/config.toml
export MISE_CONFIG_DIR=$S/cfg MISE_DATA_DIR=$S/data MISE_STATE_DIR=$S/state MISE_CACHE_DIR=$S/cache HOME=$S/home MISE_YES=1
mise -E linux,dev,host,wsl config ls          # expect: only config.toml listed, NO error about missing config.wsl.toml
mise -E linux,dev,host,wsl install && mise ls  # jq 1.8.2 installed from aqua
unset HOME; export HOME=/home/arrush.chaturvedi
```
Expected: no warning for the absent env files. If mise errors on a missing `config.<env>.toml`, STOP and report (the env scheme in the spec needs revisiting); do not work around it.

- [ ] **Step 3: Write `config.toml`**

```toml
# ~/.config/mise/config.toml — this repository IS mise's global config dir.
#
# Which files load is picked by MISE_ENV (scripts/lib/mise-env.sh):
#   config.toml          always            (cross-platform: uv)
#   config.linux.toml    linux             (the Linux toolbelt, both scopes)
#   config.dev.toml      dev               (dev tools on both OSes)
#   config.local.toml    always, git-ignored — per-host overrides
# Pins live here and in mise.lock (URLs + sha256 per platform). Bump with
# `mise outdated --bump`, then `scripts/bump-versions.sh` or `mise use`.
min_version = "2026.9.9"

[tools]
# uv — the Python installer behind python-env (both scopes, both OSes).
uv = "0.12.7"
```

- [ ] **Step 4: Write `config.linux.toml`**

Transcribe every both-scopes tool from `makefile/tools.mk` (`grep -nE 'call (EGET_TOOL|TOOL|SOFT_TOOL|USER_TOOL)' makefile/tools.mk`, everything outside the `ifeq ($(MODE),dev)` block at lines 348–361) with the pin from `makefile/versions.mk`. Registry short names for the tools `mise registry <name>` resolves; explicit backends otherwise:

```toml
# config.linux.toml — the Linux toolbelt, BOTH scopes (loads when MISE_ENV has `linux`).
# User-level under ~/.local/share/mise; interactive shells see the real bin
# dirs via `mise activate`, everything else via ~/.local/share/mise/shims.
[tools]
# --- aqua registry (short names) ---
fzf = "0.74.3"
zoxide = "0.10.0"
starship = "1.26.0"
zellij = "0.45.1"
glow = "3.0.0"
helix = "25.07.1"          # archive carries runtime/ beside hx — no HELIX_RUNTIME needed
chezmoi = "latest"         # retired in PR3 (dotfiles move to mise)
fd = "10.5.0"
bat = "0.26.1"
btop = "1.4.7"
jq = "1.8.2"
yq = "4.53.6"
witr = "0.3.3"
lazydocker = "0.25.2"
dive = "0.13.1"
lnav = "0.14.1"
gopass = "1.17.0"
age = "1.3.2"
gitui = "0.28.1"
lazygit = "0.65.0"
jj = "0.45.1"
yazi = "26.9.1"
ast-grep = "0.45.3"
television = "0.15.9"
xh = "0.26.2"
gping = "1.21.0"
atuin = "18.21.0"
delta = "0.19.2"
micro = "2.0.15"
eza = "0.23.5"
sd = "1.1.0"
ctop = "0.7.7"
k9s = "0.51.0"
rclone = "1.75.1"
croc = "11.5.0"
hyperfine = "1.20.0"
gh = "2.98.0"
sops = "3.13.3"
htmlq = "0.4.0"
watchexec = "2.7.2"
bottom = "0.14.9"
systemctl-tui = "0.8.0"
lazyjournal = "0.8.6"
cheat = "5.1.0"
fx = "39.2.0"
ripgrep = "15.2.0"
miller = "6.21.0"
difftastic = "0.70.0"
doggo = "1.4.0"
miniserve = "0.35.0"
numbat = "1.24.0"
qsv = "22.0.1"
grex = "1.4.6"
shfmt = "3.14.0"
gitleaks = "8.30.1"
dust = "1.2.5"
hexyl = "0.17.0"
gum = "2.0.0"
rust-analyzer = "2026-09-07"
marksman = "2026-02-08"
taplo = "0.10.0"
# --- github: (registry entry absent or picks the wrong asset for EL9) ---
"github:xo/usql" = { version = "0.21.4", asset_pattern = "usql_static-{{version}}-linux-amd64.tar.bz2", rename_exe = { "usql_static" = "usql" } }   # dynamic build needs glibc 2.38
"github:fastfetch-cli/fastfetch" = { version = "2.68.1", asset_pattern = "fastfetch-linux-amd64-polyfilled.tar.gz" }   # plain build's loader fails on EL9
"github:dalance/procs" = { version = "0.14.12", asset_pattern = "procs-v{{version}}-x86_64-linux.zip" }
"github:imsnif/bandwhich" = { version = "0.23.1", asset_pattern = "bandwhich-v{{version}}-x86_64-unknown-linux-musl.tar.gz" }
"github:tealdeer-rs/tealdeer" = { version = "1.9.0", asset_pattern = "tealdeer-linux-x86_64-musl", bin = "tldr" }
"github:jarun/nnn" = { version = "5.3", asset_pattern = "nnn-musl-static-{{version}}.x86_64.tar.gz", rename_exe = { "nnn-musl-static" = "nnn" } }
"github:YS-L/csvlens" = { version = "0.15.1", asset_pattern = "csvlens-x86_64-unknown-linux-musl.tar.xz" }
"github:fujiapple852/trippy" = { version = "0.13.0", asset_pattern = "trippy-{{version}}-x86_64-unknown-linux-musl.tar.gz" }   # binary is `trip`
"github:tummychow/git-absorb" = { version = "0.9.0", asset_pattern = "git-absorb-{{version}}-x86_64-unknown-linux-musl.tar.gz" }
"github:ouch-org/ouch" = { version = "0.8.2", asset_pattern = "ouch-x86_64-unknown-linux-musl.tar.gz" }
"github:boyter/scc" = { version = "4.0.0", asset_pattern = "scc_Linux_x86_64.tar.gz" }
"github:multiprocessio/dsq" = { version = "0.23.0" }
"github:unhappychoice/gitlogue" = { version = "0.11.0" }
"github:daptify14/chezit" = { version = "0.4.0", matching = "linux_amd64" }     # retired in PR3
"github:PaulJuliusMartinez/jless" = { version = "0.9.0", asset_pattern = "jless-v{{version}}-x86_64-unknown-linux-gnu.zip" }
"github:Canop/broot" = { version = "1.60.0", asset_pattern = "broot_{{version}}.zip", bin_path = "x86_64-unknown-linux-musl" }
"github:al13n321/nnd" = { version = "0.80", asset_pattern = "nnd" }
"github:dj95/zjstatus" = { version = "0.25.0", asset_pattern = "zjstatus.wasm" }   # copied into zellij's data dir by `make tools`
# --- http: (no GitHub release, bare assets, or scripts) ---
"http:ncdu" = { version = "2.9.1", url = "https://dev.yorhel.nl/download/ncdu-{{version}}-linux-x86_64.tar.gz" }
"http:pueue" = { version = "4.0.4", url = "https://github.com/Nukesor/pueue/releases/download/v{{version}}/pueue-x86_64-unknown-linux-musl", bin = "pueue" }
"http:pueued" = { version = "4.0.4", url = "https://github.com/Nukesor/pueue/releases/download/v{{version}}/pueued-x86_64-unknown-linux-musl", bin = "pueued" }
"http:nb" = { version = "7.21.1", url = "https://raw.githubusercontent.com/xwmx/nb/{{version}}/nb", bin = "nb" }
"http:sysz" = { version = "1.4.3", url = "https://raw.githubusercontent.com/joehillen/sysz/{{version}}/sysz", bin = "sysz" }
"http:ssh-copy-id" = { version = "10.0p2", url = "https://raw.githubusercontent.com/openssh/openssh-portable/V_10_0_P2/contrib/ssh-copy-id", bin = "ssh-copy-id" }
# --- pypi: (latest at install time, pinned by mise.lock; was pip --user) ---
"pypi:glances" = "latest"
"pypi:asciinema" = "latest"
"pypi:harlequin" = "latest"
```
For `nb` and `ssh-copy-id` resolve the newest tag first (`gh release list --repo xwmx/nb --limit 1`; `git ls-remote --tags https://github.com/openssh/openssh-portable 'V_*_P*' | tail -1`) and use those instead of the values above if newer. For `nnd`, `dsq`, `gitlogue`, `chezit`, `jless`, `broot` the exact tag prefix / asset is settled in Step 7.

- [ ] **Step 5: Write `config.dev.toml`**

Carry the current `chezmoi/dot_config/mise/conf.d/workstation-dev.toml` `[tools]` block over verbatim (node with its postinstall string, go, gopls, lua-language-server, basedpyright), then add:

```toml
# config.dev.toml — dev-machine tools on BOTH OSes (loads when MISE_ENV has `dev`).
# Linux-only entries carry os = ["linux"]; everything else also installs on the
# Windows host (%USERPROFILE%\.config\mise is this same checkout there).
[tools]
# <verbatim from the old workstation-dev.toml: node = { version = "26.8.1", postinstall = "npm install -g typescript-language-server@6.0.0 typescript@5.9.3 bash-language-server@5.6.0 yaml-language-server@1.24.0 vscode-langservers-extracted@4.10.0" }, go = "1.27.0", "go:golang.org/x/tools/gopls" = "0.23.0", lua-language-server = "3.19.1", "pipx:basedpyright" = "1.39.10" — keep the exact keys; rename "pipx:basedpyright" to "pypi:basedpyright" ONLY if Step 7's install shows `pypi:` is accepted by 2026.9.9, otherwise keep pipx:>
"npm:ccstatusline" = "2.2.27"                 # Claude Code statusline; enforced statusLine command becomes plain `ccstatusline`
herdr = { version = "0.8.2", os = ["linux"] }
opencode = { version = "1.18.25", os = ["linux"] }              # Windows half stays in bootstrap.ps1 $PortableTools
"github:can1357/oh-my-pi" = { version = "18.0.11", os = ["linux"], rename_exe = { "omp-*" = "omp" } }   # settle in Step 7
"github:pwndbg/pwndbg" = { version = "2026.07.29", os = ["linux"], version_prefix = "", asset_pattern = "pwndbg_{{version}}_x86_64-portable.tar.xz", bin_path = "bin" }   # bin_path settled in Step 7
"github:DevToys-app/DevToys" = { version = "2.0.9.0", os = ["linux"], asset_pattern = "devtoys.cli_linux_x64_portable.zip", rename_exe = { "DevToys.CLI" = "devtoys.cli" } }
```

- [ ] **Step 6: Scratch-install the WHOLE Linux dev set and gate it**

```bash
S=/tmp/mise-t1; rm -rf $S; mkdir -p $S/data $S/state $S/cache
export MISE_CONFIG_DIR=$HOME/.local/share/chezmoi MISE_DATA_DIR=$S/data MISE_STATE_DIR=$S/state MISE_CACHE_DIR=$S/cache MISE_YES=1
export MISE_ENV=linux,dev,host,wsl
mise install 2>&1 | tee $S/install.log        # 10–20 min; ~2 GB
mise ls --missing                              # expect: empty
# capability gate over every ELF mise put on PATH (uses the existing checker; moved in Task 2)
for d in $(mise bin-paths); do for f in "$d"/*; do [ -f "$f" ] && head -c4 "$f" | grep -q $'\x7fELF' && { makefile/lib/verify-binary.sh "$f" >/dev/null 2>&1 || echo "FAIL $f"; }; done; done
```
Expected: no `FAIL` lines. For every FAIL: read the checker's output, switch that tool to a `github:` entry with an explicit musl/static `asset_pattern` (list the release assets with `gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[].name'`), re-run `mise install <tool>` and the gate. Record every such change in the report.

- [ ] **Step 7: Settle the open asset questions and smoke each special tool**

```bash
mise which nnd tldr trip nnn usql fastfetch procs broot devtoys.cli pwndbg omp zjstatus 2>&1
hx --health | head -5          # runtime dir must be under $S/data/installs/helix/
tldr --version; nnn -V; usql --version; fastfetch --version | head -1; procs --version; jless --version; broot --version; trip --version
pwndbg --version 2>&1 | head -1; devtoys.cli --help | head -2; omp --version
ls "$(mise where github:dj95/zjstatus)"       # must contain zjstatus.wasm
```
Rules for what you find:
- nnd tag `0.80` vs `v0.80`: `gh api repos/al13n321/nnd/releases --jq '.[0:3][].tag_name'`; if bare, add `version_prefix = ""`.
- zjstatus: if the github backend refuses a non-executable asset, replace with `"http:zjstatus" = { version = "0.25.0", url = "https://github.com/dj95/zjstatus/releases/download/v{{version}}/zjstatus.wasm", bin = "zjstatus.wasm" }` and note that Task 3's Makefile recipe uses `mise where http:zjstatus`.
- pwndbg: set `bin_path` to the directory that holds the `pwndbg` launcher inside the extracted tree (`find "$(mise where github:pwndbg/pwndbg)" -name pwndbg -type f`).
- omp: the release asset is a bare binary named after the target (`omp-linux-x64` or similar); use `bin = "omp"` if bare, `rename_exe` if archived.
- `pipx:` vs `pypi:` prefix: whichever the installed mise accepts without a deprecation warning; use it consistently for all four python tools.
- `mise ls --missing` must be empty and the gate clean before moving on.

- [ ] **Step 8: Prove the prod and Windows selections resolve**

```bash
MISE_ENV=linux mise ls --missing | wc -l           # count = number of tools NOT yet installed for prod = 0 (subset of dev)
MISE_ENV=windows,dev mise ls 2>&1 | head            # must list node/go/gopls/uv/ccstatusline/rust-analyzer/marksman/taplo/lua-ls/basedpyright and NOTHING from config.linux.toml
```

- [ ] **Step 9: Produce `mise.lock` for both platforms**

```bash
cd ~/.local/share/chezmoi
MISE_ENV=linux,dev,host,native mise lock --global --platform linux-x64
MISE_ENV=windows,dev            mise lock --global --platform windows-x64
ls -la mise.lock; grep -c '^\[\[tools\.' mise.lock   # one block per tool
grep -A3 '"platforms.windows-x64"' mise.lock | head   # windows URLs present for node/go/uv/... only
```
If the second `lock` overwrote the first (no linux-x64 entries left), run both platforms in one invocation under the union env: `MISE_ENV=linux,dev,host,native,windows mise lock --global --platform linux-x64,windows-x64` and check that Linux-only tools carry only linux-x64 entries. Record which form worked in the report; Task 8's bumper uses the same form.

- [ ] **Step 10: Remove the generated conf.d and its generator; ignore local config**

```bash
git rm -r chezmoi/dot_config/mise scripts/gen-mise-config.sh scripts/test-mise.sh
printf '\n# Per-host mise overrides (name/email vars from PR3 onward) — never committed\nconfig.local.toml\n' >> .gitignore
```

- [ ] **Step 11: Commit**

```bash
git add config.toml config.linux.toml config.dev.toml mise.lock .gitignore
git commit -m "feat(mise): declare the whole toolbelt in config*.toml + mise.lock

Every tools.mk entry becomes a [tools] pin (aqua short names; github:/http:
for EL9-specific assets — usql static, fastfetch polyfilled, musl builds);
pypi: for the pip tools; npm: for ccstatusline. Proven by a scratch install
+ the verify-binary gate on the WSL host. Lock covers linux-x64 + windows-x64.
The generated conf.d and gen-mise-config.sh are gone: this repo is the config dir."
git push
```

---

### Task 2: mise helper scripts, the verify gate and the legacy sweep

**Files:**
- Create: `scripts/lib/mise-env.sh`, `scripts/lib/mise-install.sh`, `tasks/verify-tools`, `tasks/migrate-legacy`, `scripts/test-mise-install.sh`
- Move: `makefile/lib/verify-binary.sh` → `scripts/lib/verify-binary.sh`, `makefile/lib/test-verify-binary.sh` → `scripts/lib/test-verify-binary.sh` (`git mv`; fix the `$(dirname "$0")` reference inside the test if it names `../lib`)
- Test: `bash scripts/test-mise-install.sh`, `bash scripts/lib/test-verify-binary.sh`, `bash tasks/migrate-legacy` against a scratch HOME

**Interfaces:**
- Produces: `scripts/lib/mise-env.sh <dev|prod>` → prints one line (`linux` or `linux,dev,host,{wsl|native}`); `scripts/lib/mise-install.sh` (needs `MISE_ENV`; exits non-zero on install failure); `tasks/verify-tools` (exit 1 on any failing ELF); `tasks/migrate-legacy` (honours `MISE_ENV` containing `host` OR `HAS_SUDO=true` to use sudo for `/usr/local`; marker `~/.local/state/workstation/legacy-tools-swept`; idempotent).

- [ ] **Step 1: `scripts/lib/mise-env.sh`**

```bash
#!/usr/bin/env bash
# mise-env.sh <dev|prod> — print the MISE_ENV token set for THIS Linux host.
#   prod → linux
#   dev  → linux,dev,host,wsl   (WSL guest)  |  linux,dev,host,native (bare metal / VM)
# Single source for bootstrap.sh, the Makefile and update-hosts.sh; the rc
# files persist the same value (chezmoi templates until PR3, Tera after).
set -euo pipefail
mode="${1:?usage: mise-env.sh <dev|prod>}"
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
case "$mode" in
dev) if is_wsl; then echo "linux,dev,host,wsl"; else echo "linux,dev,host,native"; fi ;;
prod) echo "linux" ;;
*)
  printf 'mise-env.sh: unknown mode %q (dev|prod)\n' "$mode" >&2
  exit 2
  ;;
esac
```

- [ ] **Step 2: `scripts/lib/mise-install.sh`**

```bash
#!/usr/bin/env bash
# mise-install.sh — install every tool the active MISE_ENV declares.
#
# node's npm postinstall carries the language servers; mise re-runs it only on
# a (re)install, so a changed postinstall string with an unchanged node pin
# would otherwise never land. Marker = cksum of node's declaration under
# ~/.local/state/workstation/; when node was ALREADY installed and the marker
# is stale, node is force-reinstalled once. Then `mise prune` drops versions no
# config references. User-level; never sudo. Used by `make tools` (PR1) and by
# tasks/bootstrap (PR2+).
set -euo pipefail
: "${MISE_ENV:?mise-install.sh: MISE_ENV must be set (scripts/lib/mise-env.sh <dev|prod>)}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
mkdir -p "$state"
export MISE_YES=1

had_node=false
if mise where node >/dev/null 2>&1; then had_node=true; fi

mise install

if mise where node >/dev/null 2>&1; then
  decl="$(mise config get tools.node 2>/dev/null || true)"
  sum="$(printf '%s' "$decl" | cksum | cut -d' ' -f1)"
  if $had_node && [ ! -f "$state/node-postinstall.$sum" ]; then
    printf '  node already installed but its declaration changed — reinstalling so the npm postinstall re-runs\n'
    mise install --force node
  fi
  rm -f "$state"/node-postinstall.*
  : >"$state/node-postinstall.$sum"
fi

mise prune
mise reshim
printf '  ✓ mise tools installed (MISE_ENV=%s)\n' "$MISE_ENV"
```

- [ ] **Step 3: `scripts/test-mise-install.sh` (offline, fake mise) — write it, run it, expect PASS**

```bash
#!/usr/bin/env bash
# test-mise-install.sh — offline behavioural test of scripts/lib/mise-install.sh
# with a fake `mise` on PATH. Asserts: (1) fresh install writes the marker
# without forcing; (2) unchanged declaration → no force; (3) changed declaration
# with node already present → exactly one `install --force node`.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat >"$T/bin/mise" <<'EOF'
#!/usr/bin/env bash
log="${FAKE_LOG:?}"
case "$1 ${2:-}" in
"where node") [ -f "$FAKE_NODE" ] && exit 0 || exit 1 ;;
"install --force") echo "install --force $3" >>"$log"; exit 0 ;;
"install ") echo "install" >>"$log"; : >"$FAKE_NODE"; exit 0 ;;
"config get") printf '%s\n' "$FAKE_DECL"; exit 0 ;;
"prune "|"reshim ") exit 0 ;;
esac
echo "fake mise: unexpected args: $*" >&2; exit 99
EOF
chmod +x "$T/bin/mise"
export PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.local/state" MISE_ENV=linux,dev,host,wsl
export FAKE_LOG="$T/log" FAKE_NODE="$T/node-installed" FAKE_DECL='{ version = "26.8.1", postinstall = "npm install -g a@1" }'
fail() { echo "FAIL: $*" >&2; exit 1; }
# 1. fresh
bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -qx install "$FAKE_LOG" || fail "first run did not install"
grep -q 'install --force' "$FAKE_LOG" && fail "fresh install forced node"
ls "$XDG_STATE_HOME/workstation"/node-postinstall.* >/dev/null || fail "marker not written"
# 2. unchanged
: >"$FAKE_LOG"; bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -q 'install --force' "$FAKE_LOG" && fail "unchanged declaration forced node"
# 3. changed
FAKE_DECL='{ version = "26.8.1", postinstall = "npm install -g a@2" }' bash "$root/scripts/lib/mise-install.sh" >/dev/null
[ "$(grep -c 'install --force node' "$FAKE_LOG")" = 1 ] || fail "changed declaration should force node exactly once"
echo "PASS: mise-install.sh installs, writes the node marker, and forces node only when its declaration changed"
```
Run: `bash scripts/test-mise-install.sh` → `PASS: …`.

- [ ] **Step 4: `tasks/verify-tools`**

```bash
#!/usr/bin/env bash
#MISE description="Capability-check every mise-installed Linux binary (ELF arch, loader, glibc floor)"
# The install-time gate the Make macros used to &&-chain onto every install.
# Walks every active bin dir mise exposes, runs scripts/lib/verify-binary.sh on
# each ELF (scripts pass through), and fails loudly on the first host that
# cannot run an asset — the fix is an explicit github: asset_pattern for that
# tool in config*.toml. Read-only. Linux only (no-op elsewhere).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify="$root/scripts/lib/verify-binary.sh"
[ "$(uname -s)" = Linux ] || { echo "verify-tools: Linux only — skipped"; exit 0; }
command -v mise >/dev/null || { echo "verify-tools: mise not on PATH" >&2; exit 1; }
n=0 bad=0
while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    n=$((n + 1))
    if ! out="$("$verify" "$f" 2>&1)"; then
      bad=$((bad + 1))
      printf ' ✗ %s\n%s\n' "$f" "$(printf '%s\n' "$out" | sed 's/^/     /')"
    fi
  done
done < <(mise bin-paths 2>/dev/null)
if [ "$bad" -gt 0 ]; then
  printf 'verify-tools: %d of %d binaries cannot run on this host — pick an explicit asset (github: asset_pattern) for each in config*.toml\n' "$bad" "$n" >&2
  exit 1
fi
printf ' ✓ verify-tools: %d ELF binaries pass (arch, loader, glibc floor)\n' "$n"
```
`chmod +x tasks/verify-tools`. Run it against the Task 1 scratch data dir: `MISE_DATA_DIR=/tmp/mise-t1/data MISE_ENV=linux,dev,host,wsl tasks/verify-tools` → `✓ verify-tools: N ELF binaries pass`.

- [ ] **Step 5: `tasks/migrate-legacy`**

```bash
#!/usr/bin/env bash
#MISE description="One-time sweep of the pre-mise tool installs (/usr/local/bin or ~/.local/bin, helix runtime, eget, tool stamps)"
#MISE hide=true
# Idempotent; marker ~/.local/state/workstation/legacy-tools-swept skips the
# whole sweep on later runs. sudo is used ONLY for /usr/local paths and ONLY
# when this host is a dev machine (MISE_ENV contains `host`, or the Make era's
# HAS_SUDO=true). Everything removed here is reinstalled by mise from
# config*.toml — nothing is unrecoverable.
set -uo pipefail
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
marker="$state/legacy-tools-swept"
if [ -f "$marker" ]; then
  echo "  legacy sweep already done ($marker)"
  exit 0
fi
use_sudo=false
case ",${MISE_ENV:-}," in *,host,*) use_sudo=true ;; esac
[ "${HAS_SUDO:-}" = true ] && use_sudo=true
rm_p() { # rm_p <path>… — rm -rf, via sudo only where the parent is not ours
  local p
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ -w "$(dirname "$p")" ]; then rm -rf "$p"
    elif $use_sudo; then sudo rm -rf "$p"
    else printf '  ! cannot remove %s (no sudo on this host) — remove by hand\n' "$p"; continue; fi
    printf '  - removed %s\n' "$p"
  done
}
# Every binary the Make macros used to place in DEST (registered names → binaries).
names=(fzf zoxide starship zellij glow hx fd bat btop bandwhich lazydocker dive lnav gopass fastfetch
  gitui lazygit jj ast-grep sg tv fx gitlogue xh gping atuin delta micro eza sd k9s rclone croc hyperfine
  mise dsq gh htmlq ouch watchexec btm systemctl-tui rg mlr csvlens difft trip doggo scc git-absorb
  miniserve numbat qsv grex jless gitleaks procs dust hexyl gum rust-analyzer marksman taplo herdr
  opencode omp broot chezit cheat eget ncdu usql yazi ya nnn age age-keygen nb jq yq tldr witr ctop sops
  lazyjournal sysz ssh-copy-id shfmt pueue pueued nnd chezmoi cht.sh devtoys.cli pwndbg
  node npm npx corepack go gofmt uv uvx gopls lua-language-server typescript-language-server
  bash-language-server yaml-language-server vscode-json-language-server vscode-css-language-server
  vscode-html-language-server vscode-eslint-language-server vscode-markdown-language-server tsc tsserver)
for d in /usr/local/bin "$HOME/.local/bin"; do
  [ -d "$d" ] || continue
  # ~/.local/bin/mise is the NEW pinned mise (bootstrap.sh) — never remove it there.
  for n in "${names[@]}"; do
    [ "$d" = "$HOME/.local/bin" ] && [ "$n" = mise ] && continue
    rm_p "$d/$n"
  done
  rm_p "$d"/_pwndbg-* "$d"/_devtoys-cli-* "$d"/_node-* "$d"/_go-* "$d"/_lua-language-server-*
done
rm_p /usr/local/lib/helix /usr/local/lib/node_modules
# pip --user era of glances/asciinema/harlequin (now pypi: tools behind shims)
python3 -m pip uninstall -y -q glances asciinema harlequin >/dev/null 2>&1 || true
# stamps of the retired Make targets (keep the ones PR2 still owns)
stamps="$HOME/.local/share/workstation-install"
if [ -d "$stamps" ]; then
  find "$stamps" -maxdepth 1 -name '*.done' \
    ! -name 'claude-*' ! -name 'nerd-fonts-*' ! -name 'vcpkg-*' ! -name 'python-env-*' \
    ! -name 'docker-engine*' ! -name 'dozzle-service-*' ! -name 'cockpit-service*' \
    ! -name 'rsyslog-service-*' ! -name 'wsl-config-*' -print -delete | sed 's/^/  - removed stamp /'
fi
mkdir -p "$state" && : >"$marker"
echo "  ✓ legacy tool installs swept ($marker)"
```
`chmod +x tasks/migrate-legacy`. Test against a scratch HOME (no sudo path exercised):
```bash
T=$(mktemp -d); mkdir -p $T/.local/bin $T/.local/share/workstation-install
touch $T/.local/bin/{fzf,mise,wpy} $T/.local/share/workstation-install/{fzf-0.74.3.done,python-env-3.14.7-1.done}
HOME=$T XDG_STATE_HOME=$T/.local/state MISE_ENV=linux bash tasks/migrate-legacy
ls $T/.local/bin            # expect: mise wpy  (fzf gone)
ls $T/.local/share/workstation-install   # expect: python-env-3.14.7-1.done only
HOME=$T XDG_STATE_HOME=$T/.local/state MISE_ENV=linux bash tasks/migrate-legacy   # expect: "already done"
```

- [ ] **Step 6: Move verify-binary.sh + its test; run the test**

```bash
git mv makefile/lib/verify-binary.sh scripts/lib/verify-binary.sh
git mv makefile/lib/test-verify-binary.sh scripts/lib/test-verify-binary.sh
grep -n 'dirname\|verify-binary' scripts/lib/test-verify-binary.sh | head   # fix any relative path it uses
bash scripts/lib/test-verify-binary.sh      # expect its PASS line
```

- [ ] **Step 7: Line endings, mode, formatting; commit**

```bash
chmod 755 scripts/lib/*.sh tasks/* scripts/test-mise-install.sh
shfmt -w -i 2 scripts/lib/mise-env.sh scripts/lib/mise-install.sh tasks/verify-tools tasks/migrate-legacy scripts/test-mise-install.sh
shellcheck -x -S warning scripts/lib/mise-env.sh scripts/lib/mise-install.sh tasks/verify-tools tasks/migrate-legacy scripts/test-mise-install.sh
git add -A scripts/lib tasks scripts/test-mise-install.sh makefile/lib
git commit -m "feat(mise): env/install helpers, verify-tools gate, legacy sweep task"
git push
```

---

### Task 3: Make surgery — `tools` = mise, installer layer deleted

**Files:**
- Delete: `makefile/tools.mk`, `makefile/lib/eget.sh`, `makefile/lib/archive.sh`, `makefile/lib/direct.sh`, `makefile/lib/pip.sh`, `makefile/lib/helix.sh`, `makefile/lib/mise.sh`, `makefile/lib/pwndbg.sh`, `makefile/lib/devtoys-cli.sh`
- Move: `makefile/lib/zellij-plugin.sh` → `scripts/lib/zellij-plugin.sh` (and update `scripts/test-zellij-plugin.sh` line 14's path)
- Modify: `makefile/Makefile`, `makefile/scope.mk`, `makefile/versions.mk`, `makefile/lib/doctor.sh`, `makefile/lib/check-updates.sh` (only if it references tools.mk — it does not; leave)
- Test: `make -n MODE=prod provision`, `make -n MODE=dev provision`, `make list MODE=dev`, `make doctor MODE=dev`, `make check-updates MODE=dev`

**Interfaces:**
- Consumes: `scripts/lib/mise-env.sh`, `scripts/lib/mise-install.sh`, `tasks/verify-tools`, `tasks/migrate-legacy`, `scripts/lib/zellij-plugin.sh` (Task 2); `[tools]` key `"github:dj95/zjstatus"` (or `http:zjstatus` per Task 1's ruling).
- Produces: `make tools MODE=<dev|prod>` (installs + verifies + sweeps), `make provision` phases packages → tools → fanout → dotfiles, `MISE_ENV` exported to every recipe, `MISE_SHIMS` unchanged.

- [ ] **Step 1: `makefile/scope.mk` — drop HELIX_RUNTIME_DEST, add MISE_ENV**

Replace the dev/prod blocks with:
```make
ifeq ($(MODE),dev)
  DEST             := /usr/local/bin
  HAS_SUDO         := true
  INSTALL_PACKAGES := true
  SUDO             := sudo --preserve-env=DEST
else ifeq ($(MODE),prod)
  DEST             := $(HOME)/.local/bin
  HAS_SUDO         := false
  INSTALL_PACKAGES := false
  SUDO             :=
else
  $(error MODE not set. Use 'make dev' / 'make prod', or set MODE=dev|prod explicitly.)
endif
```
Keep the `HAS_SUDO` sanity gate and `IS_WSL`. Append:
```make
# MISE_ENV — which config.<env>.toml files mise loads (scripts/lib/mise-env.sh is
# the single source; bootstrap.sh exports the same value). An explicit MISE_ENV
# in the environment wins (sandbox runs).
MISE_ENV ?= $(shell $(abspath $(CURDIR)/..)/scripts/lib/mise-env.sh $(MODE))
export MISE_ENV
```
Update the header comment (DEST is now only where legacy binaries are swept from and where chezmoi's `-b` used to point; `HELIX_RUNTIME_DEST` gone).

- [ ] **Step 2: `makefile/versions.mk` — keep only the pins Make still owns**

The file becomes exactly (comments allowed):
```make
# versions.mk — the pins Make still owns after the tools moved to config*.toml.
# Every TOOL pin now lives in config.toml / config.linux.toml / config.dev.toml
# (+ mise.lock). PR2 moves the rest into [vars].
ZJSTATUS_ZELLIJ_FLOOR := 0.45.0   # zjstatus' stated zellij floor; check-invariants asserts tools.zellij >= this
CLAUDE_VERSION := latest
CCSTATUSLINE_VERSION := 2.2.27    # TEMP: only setup-ccstatusline.sh's TUI launch uses it; retired in Task 6
DOZZLE_VERSION := 10.10.0
JETBRAINSMONO_NERD_VERSION := 3.5.1
VCPKG_VERSION  := 2026.07.29
PYTHON_VERSION := 3.14.7
```
(Task 6 then deletes `CCSTATUSLINE_VERSION`.) Keep the `# --- Section ---` comment style gen-tool-memory.sh parses for these leftovers.

- [ ] **Step 3: `makefile/Makefile` — delete the macro layer and tools.mk include**

Delete lines 82–207 region contents: `verify_cmd`, `_RULE_BODY`, `TOOL`, `_SOFT_RULE_BODY`, `SOFT_TOOL`, `USER_TOOL`, `EGET_TOOL`, the `SCOPE_TOOLS/USER_TOOLS/DOCTOR_ROWS/UPDATE_SPECS :=` resets except keep `DOCTOR_ROWS :=` and `UPDATE_SPECS :=`, and `include tools.mk`. Change the export line to `export DEST LIB STAMP SUDO MODE HAS_SUDO`. Update the header comment block (composition list: no tools.mk; "tools: mise install from config*.toml").

- [ ] **Step 4: `makefile/Makefile` — the new `tools` target replaces `mise-runtimes`**

Replace the whole `mise-runtimes` block (lines 226–267) with:
```make
# -----------------------------------------------------------------------------
# tools — every toolbelt tool + runtime, installed by mise from config*.toml at
# the repo root (this checkout is ~/.config/mise). USER-LEVEL: never $(SUDO).
# Three steps: scripts/lib/mise-install.sh (install, node-postinstall marker,
# prune), tasks/verify-tools (the capability gate the old macros &&-chained),
# tasks/migrate-legacy (one-time sweep of the pre-mise binaries; sudo inside
# only for /usr/local on dev). No stamp: mise is idempotent itself. Runs as its
# own provision phase BEFORE the fanout so python-env / claude-statusline /
# zjstatus see the shims.
# -----------------------------------------------------------------------------
MISE_SHIMS := $(or $(MISE_DATA_DIR),$(HOME)/.local/share/mise)/shims
.PHONY: tools
tools:
	@printf '==> tools (mise install, MISE_ENV=%s)\n' "$(MISE_ENV)"
	@PATH="$(HOME)/.local/bin:$$PATH" $(REPO_ROOT)/scripts/lib/mise-install.sh
	@PATH="$(HOME)/.local/bin:$$PATH" $(REPO_ROOT)/tasks/verify-tools
	@PATH="$(HOME)/.local/bin:$$PATH" $(REPO_ROOT)/tasks/migrate-legacy
	# zjstatus.wasm goes into zellij's DATA plugin dir (not a bin dir): copy from mise's install.
	@PATH="$(MISE_SHIMS):$(HOME)/.local/bin:$$PATH" $(REPO_ROOT)/scripts/lib/zellij-plugin.sh zjstatus "file://$$(mise where github:dj95/zjstatus)/zjstatus.wasm"
	# cht.sh — the one artifact with no versioned release; soft-fail exactly like the old SOFT_TOOL.
	@if curl -fsSL --retry 3 -o "$(HOME)/.local/bin/cht.sh.tmp" https://cht.sh/:cht.sh; then \
	   install -m 0755 "$(HOME)/.local/bin/cht.sh.tmp" "$(HOME)/.local/bin/cht.sh" && rm -f "$(HOME)/.local/bin/cht.sh.tmp"; \
	 else rm -f "$(HOME)/.local/bin/cht.sh.tmp"; printf '  ! cht.sh download failed (retried next run)\n'; fi
```
(If Task 1 ruled `http:zjstatus`, use `mise where http:zjstatus`.)

- [ ] **Step 5: `makefile/Makefile` — retire pwndbg/devtoys-cli targets, fix dependents**

- Delete the `pwndbg` and `devtoys-cli` target blocks (they are `[tools]` now) and their DOCTOR_ROWS lines.
- `claude-statusline`: remove the `claude-statusline: mise-runtimes` dep lines; keep the recipe but drop `CCSTATUSLINE_VERSION=…` from it after Task 6 (leave for now).
- `python-env`: change the order-only dep line to `$(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done:` (no dep — `tools` is now a prior provision phase); keep the PATH prepend.
- `lsp-servers`: `lsp-servers: tools` + the clangd check.
- `PROVISION_FANOUT := shell wsl-config` / `PROVISION_FANOUT += python-env` / dev block `claude-cli nerd-fonts docker-engine dozzle-service cockpit-service rsyslog-service vcpkg lsp-servers` (no `tools user-tools mise-runtimes pwndbg devtoys-cli`).
- `provision`:
```make
provision:
	+@$(MAKE) --no-print-directory packages
	+@$(MAKE) --no-print-directory tools
	+@$(MAKE) --no-print-directory --output-sync=target provision-fanout
	+@$(MAKE) --no-print-directory dotfiles
```
- `user-tools:` line deleted; `.PHONY` list updated; `all: tools` stays.
- `DOCTOR_ROWS`: delete `mise-runtimes`, `pwndbg`, `devtoys-cli` rows.
- `UPDATE_SPECS` (hand-registered, previously in tools.mk lines 549–600): add to the Makefile after `DOCTOR_ROWS`, ONLY the surviving versions.mk pins:
```make
UPDATE_SPECS += claude-cli|$(CLAUDE_VERSION)|-|-
UPDATE_SPECS += dozzle|$(DOZZLE_VERSION)|amir20/dozzle|v$(DOZZLE_VERSION)
UPDATE_SPECS += nerd-fonts|$(JETBRAINSMONO_NERD_VERSION)|ryanoasis/nerd-fonts|v$(JETBRAINSMONO_NERD_VERSION)
UPDATE_SPECS += vcpkg|$(VCPKG_VERSION)|microsoft/vcpkg|$(VCPKG_VERSION)
UPDATE_SPECS += python-env|$(PYTHON_VERSION)|python/cpython|v$(PYTHON_VERSION)
```
- `check-updates` recipe: prepend `@printf '==> mise tools (config*.toml): mise outdated --bump\n'; PATH="$(HOME)/.local/bin:$$PATH" mise outdated --bump || true` before the existing UPDATE_SPECS pipe.
- `list`: replace the scope/user printing with `@PATH="$(HOME)/.local/bin:$$PATH" mise ls` followed by the existing services/nerd-fonts/python-env/wsl-config lines (drop the C/C++ and mise-runtimes lines; add `pwndbg / devtoys.cli / nnd are mise tools (config.dev.toml / config.linux.toml)`).
- `help`: replace "make <tool>" lines with `make tools MODE=…  (mise install + verify + legacy sweep)` and `mise install <tool> / mise outdated --bump`.
- `fmt`: file list becomes `bootstrap.sh makefile/lib/*.sh scripts/*.sh scripts/lib/*.sh tasks/* .claude/hooks/*.sh chezmoi/private_dot_claude/hooks/*.sh chezmoi/private_dot_claude/executable_notify.sh chezmoi/dot_local/bin/executable_winterop`.
- Delete the `.PHONY: … user-tools …` mention and every comment that names `EGET_TOOL`/`tools.mk`/`eget`.

- [ ] **Step 6: `makefile/lib/doctor.sh` — tools section instead of per-tool rows**

Delete `bin_for`, the `scope|`/`user|` row handling in `main`, and the `mise-runtimes`, `pwndbg`, `devtoys-cli` cases. Add before `packages_section`:
```bash
tools_section() {
  hdr "tools (mise, config*.toml — MISE_ENV=${MISE_ENV:-unset})"
  if ! command -v mise >/dev/null 2>&1; then
    row_bad "mise" "not on PATH — re-run ./bootstrap.sh --$MODE (installs the pinned mise into ~/.local/bin)"
    return
  fi
  local missing
  missing=$(mise ls --missing 2>/dev/null | awk 'NF {print $1}' | paste -sd' ' -)
  if [[ -z "$missing" ]]; then
    row_ok "mise tools" "every declared tool installed ($(mise ls 2>/dev/null | grep -c .) entries)"
  else
    row_bad "mise tools" "missing: $missing — install: make tools MODE=$MODE"
  fi
  if [[ -f "$HOME/.local/share/zellij/plugins/zjstatus.wasm" ]]; then
    row_ok "zjstatus" "plugin in zellij's data dir"
  else
    row_warn "zjstatus" "zjstatus.wasm not in ~/.local/share/zellij/plugins — make tools MODE=$MODE copies it"
  fi
  if [[ -f "${XDG_STATE_HOME:-$HOME/.local/state}/workstation/legacy-tools-swept" ]]; then
    row_ok "legacy sweep" "pre-mise binaries removed"
  else
    row_warn "legacy sweep" "not yet run — make tools MODE=$MODE (needs sudo once on dev)"
  fi
}
```
Call `tools_section` from `main` before the bespoke rows; adjust the summary/header text (`DEST=` no longer meaningful — print `MISE_ENV=` instead). The `check_wiring` mise rows stay.

- [ ] **Step 7: Move zellij-plugin.sh; delete the installer libs and tools.mk; dry-run**

```bash
git mv makefile/lib/zellij-plugin.sh scripts/lib/zellij-plugin.sh
sed -i 's|makefile/lib/zellij-plugin.sh|scripts/lib/zellij-plugin.sh|' scripts/test-zellij-plugin.sh && bash scripts/test-zellij-plugin.sh
git rm makefile/tools.mk makefile/lib/{eget,archive,direct,pip,pipe,helix,mise,pwndbg,devtoys-cli}.sh
# pipe.sh is used by claude-cli → keep it! (undo: git checkout HEAD -- makefile/lib/pipe.sh) — claude-cli's recipe calls $(LIB)/pipe.sh
cd makefile
make -n MODE=prod provision | head -40     # phases: packages skip → tools (3 scripts) → fanout → dotfiles
make -n MODE=dev provision | grep -E '==> ' | head -20
make list MODE=dev | head -20
make doctor MODE=dev | head -40            # tools section present; no per-tool rows; no errors
make check-updates MODE=dev | head -20     # mise outdated line + 5 specs
cd ..
```
Expected: no reference to `tools.mk`, `EGET`, `HELIX_RUNTIME_DEST` remains: `grep -rn 'tools.mk\|EGET\|HELIX_RUNTIME_DEST\|mise-runtimes\|lib/mise.sh' makefile GNUmakefile` → empty.

- [ ] **Step 8: Commit**

```bash
git add -A makefile scripts/lib/zellij-plugin.sh scripts/test-zellij-plugin.sh
git commit -m "refactor(make): tools target = mise install + verify + legacy sweep; installer layer deleted"
git push
```

---

### Task 4: `bootstrap.sh` — pinned mise, repo relocation, MISE_ENV; chezmoi sourceDir; update-hosts

**Files:**
- Modify: `bootstrap.sh`, `scripts/update-hosts.sh:127-140`, `chezmoi/.chezmoi.toml.tmpl:4-5`, `chezmoi/.chezmoiignore.tmpl:77-80`
- Test: `bash -n bootstrap.sh`; `shellcheck -x -S warning bootstrap.sh`; `./bootstrap.sh --doctor --dev` (read-only) after the relocation in Task 10; `scripts/update-hosts.sh --check`

**Interfaces:**
- Consumes: `scripts/lib/mise-env.sh` (Task 2).
- Produces: `REPO_DIR="$HOME/.config/mise"` (with `CHEZMOI_SOURCE="$REPO_DIR"` kept as the chezmoi-facing name), functions `install_mise`, `relocate_repo`, exported `MISE_ENV`, `MISE_VERSION`/`MISE_SHA256` constants (the ONLY pins in bootstrap.sh; `check-invariants.sh` asserts them).

- [ ] **Step 1: Constants and paths (top of file, near line 108)**

```bash
DOTFILES_REPO="https://github.com/ArrushC/workstation.git"
# The checkout IS mise's global config dir (config*.toml, mise.lock, tasks/ live at its root).
REPO_DIR="$HOME/.config/mise"
LEGACY_REPO_DIR="$HOME/.local/share/chezmoi" # pre-2026-09 location; relocate_repo() moves it
CHEZMOI_SOURCE="$REPO_DIR" # chezmoi's --source (its .chezmoiroot points at chezmoi/ inside)
BIN="$HOME/.local/bin"
# The ONE pin bootstrap owns: mise itself (everything else is in config*.toml).
# DUAL-EDIT with bootstrap.ps1 $PortableTools (mise) and min_version in config.toml —
# scripts/check-invariants.sh asserts all three agree.
MISE_VERSION="2026.9.9"
MISE_SHA256="986f36c5efef4302f6252f1b1e58c32052f3696fcf19b1ed44a1976b3c2b4ffc" # mise-v${MISE_VERSION}-linux-x64-musl.tar.gz
```
Replace every remaining `$CHEZMOI_SOURCE` that means "the repo" with `$REPO_DIR` (keep `$CHEZMOI_SOURCE` only in chezmoi invocations); update the `do_reinstall` text (repo path; the manual-uninstall hint becomes `mise implode` / `rm -rf ~/.local/share/mise`).

- [ ] **Step 2: `relocate_repo()` — run right before the clone/pull block**

```bash
# =============================================================================
# 1.5 RELOCATE — the checkout moved from ~/.local/share/chezmoi to ~/.config/mise
# (this repo IS mise's global config dir since 2026-09). One-time, idempotent.
# A pre-existing ~/.config/mise (the chezmoi-deployed conf.d era) is moved aside.
# =============================================================================
relocate_repo() {
  [[ -d "$REPO_DIR/.git" ]] && return 0
  [[ -d "$LEGACY_REPO_DIR/.git" ]] || return 0
  log "Relocating the workstation checkout: $LEGACY_REPO_DIR → $REPO_DIR"
  if [[ -e "$REPO_DIR" ]]; then
    local aside="$REPO_DIR.pre-relocation.$(date +%Y%m%d%H%M%S)"
    mv "$REPO_DIR" "$aside"
    warn "moved the old $REPO_DIR (chezmoi-deployed mise conf.d) to $aside — delete it once the new layout works"
  fi
  mkdir -p "$(dirname "$REPO_DIR")"
  mv "$LEGACY_REPO_DIR" "$REPO_DIR" || fail "could not move $LEGACY_REPO_DIR to $REPO_DIR"
  ok "checkout now at $REPO_DIR"
}
```

- [ ] **Step 3: `install_mise()` — run after the clone/pull, before `run_make`**

```bash
# =============================================================================
# 2.5 MISE — the pinned mise binary into ~/.local/bin (sha256-verified). mise
# installs every other tool from config*.toml; the Make layer only orchestrates.
# =============================================================================
install_mise() {
  if [[ -x "$BIN/mise" ]] && [[ "$("$BIN/mise" --version 2>/dev/null | awk '{print $1}')" == "$MISE_VERSION" ]]; then
    ok "mise $MISE_VERSION present ($BIN/mise)"
    return 0
  fi
  log "Installing mise $MISE_VERSION into $BIN..."
  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64-musl.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/mise.tgz" "$url" || fail "mise download failed: $url"
  printf '%s  %s\n' "$MISE_SHA256" "$tmp/mise.tgz" | sha256sum -c --quiet - || fail "mise tarball sha256 mismatch — refusing to install"
  tar -xzf "$tmp/mise.tgz" -C "$tmp"
  install -m 0755 "$tmp/mise/bin/mise" "$BIN/mise"
  rm -rf "$tmp"
  ok "mise $MISE_VERSION installed ($BIN/mise)"
}
```

- [ ] **Step 4: MISE_ENV + PATH wiring in MAIN**

After `preflight` / `mkdir -p "$BIN"`:
```bash
export PATH="$BIN:$HOME/.local/share/mise/shims:$PATH"
```
After the clone/pull block and `install_mise`:
```bash
MISE_ENV="$("$REPO_DIR/scripts/lib/mise-env.sh" "$MACHINE_TYPE")"
export MISE_ENV
log "mise environment: MISE_ENV=$MISE_ENV"
```
Order in MAIN: `preflight` → `relocate_repo` → clone/pull (using `$REPO_DIR`) → `install_mise` → MISE_ENV → `self_register` → `run_make` → `ensure_chezmoi_initialized` → `refresh_chezmoi_config` (new, Step 5) → `check_age_identity` → `set_default_shell` → `push_host_changes`.

- [ ] **Step 5: chezmoi `sourceDir` + config refresh**

`chezmoi/.chezmoi.toml.tmpl` — insert after line 3 (before `[data]`):
```
# The checkout lives at ~/.config/mise (it is mise's global config dir); chezmoi's
# source state is the chezmoi/ subdir inside it (.chezmoiroot). Persisted here so
# bare `chezmoi apply`/`cza` (no --source) keep working after the relocation.
sourceDir = {{ joinPath .chezmoi.homeDir ".config/mise" | quote }}
```
`bootstrap.sh` — new function, called right after `ensure_chezmoi_initialized`:
```bash
# Re-render chezmoi's config when it predates the sourceDir key (the
# relocation): `init` without --apply re-runs .chezmoi.toml.tmpl; cached
# prompt answers mean no prompts.
refresh_chezmoi_config() {
  local config="$HOME/.config/chezmoi/chezmoi.toml" chezmoi_bin
  chezmoi_bin=$(command -v chezmoi || true)
  [[ -n "$chezmoi_bin" && -f "$config" ]] || return 0
  grep -q '^sourceDir' "$config" && return 0
  log "Refreshing chezmoi config (sourceDir → $REPO_DIR)..."
  WORKSTATION_GROUP="$GROUP_NAME" "$chezmoi_bin" init --no-tty --source "$CHEZMOI_SOURCE" && ok "chezmoi config refreshed" || warn "chezmoi init --no-tty failed; run: chezmoi init --source $CHEZMOI_SOURCE"
}
```
`chezmoi/.chezmoiignore.tmpl` — delete lines 77–80 (the `.config/mise/conf.d/workstation-dev.toml` entry and its comment).

- [ ] **Step 6: preflight, doctor and closing text**

- `preflight`: drop `unzip` from the required list and the install hints (mise extracts its own archives); keep `curl git make tar ip`.
- `do_doctor`: the "Tools, services, stamps" call stays (`make … doctor`), add before it:
```bash
  log "mise"
  if command -v mise >/dev/null 2>&1; then ok "mise $(mise --version 2>/dev/null | awk '{print $1}') on PATH ($(command -v mise)) — pinned $MISE_VERSION"; else warn "mise not on PATH — re-run ./bootstrap.sh --${MACHINE_TYPE}"; fi
```
and export `MISE_ENV` in the report modes too (compute it right after `require_repo`).
- Replace the `make -C makefile mise-runtimes` / `claude-statusline` hints to `make -C makefile claude-statusline MODE=dev` (unchanged) and the closing "Re-configure the statusline" text unchanged; nothing else mentions eget.
- `update-hosts.sh:131-136` remote command:
```bash
  remote_cmd="set -e
d=\$HOME/.config/mise; [ -d \"\$d/.git\" ] || d=\$HOME/.local/share/chezmoi
cd \"\$d\"
git pull --ff-only
./bootstrap.sh --$mode --yes"
```
and the `--check` message text to `'<git pull && ./bootstrap.sh --%s --yes>'`.

- [ ] **Step 7: Verify statically; commit**

```bash
bash -n bootstrap.sh && shellcheck -x -S warning bootstrap.sh scripts/update-hosts.sh && shfmt -d -i 2 bootstrap.sh scripts/update-hosts.sh
scripts/update-hosts.sh --check | head -3
bash scripts/check-templates.sh 2>&1 | tail -3     # .chezmoi.toml.tmpl is excluded there; ignore-file renders
git add bootstrap.sh scripts/update-hosts.sh chezmoi/.chezmoi.toml.tmpl chezmoi/.chezmoiignore.tmpl
git commit -m "feat(bootstrap): pinned mise seed, checkout relocated to ~/.config/mise, MISE_ENV"
git push
```

---

### Task 5: `bootstrap.ps1` — repo path, MISE_ENV, mise 2026.9.9, config-file stamp

**Files:**
- Modify: `bootstrap.ps1` (lines 46, 106–112 comments; 148 `$RepoPath`; 370–391 mise entry; 1433–1482 `Invoke-CloneRepo`; 1509–1626 mise section; 2588–2607 doctor rows; 2819 closing line)
- Test: BOM retained (`head -c3 bootstrap.ps1 | xxd`), `pwsh scripts/check-ps.ps1` if pwsh is available locally (else CI), `scripts/check-invariants.sh` pin rows after Task 7.

**Interfaces:**
- Produces: `$RepoPath` default `%USERPROFILE%\.config\mise`; `$MiseConfigFiles = @("config.toml","config.dev.toml")` under `$RepoPath`; User env var `MISE_ENV=windows,dev`.

- [ ] **Step 1: RepoPath default + relocation in `Invoke-CloneRepo`**

Line 148: `[string]$RepoPath = (Join-Path $env:USERPROFILE ".config\mise"),`. At the top of `Invoke-CloneRepo`, before the clone check:
```powershell
    # One-time relocation: the checkout moved from .local\share\chezmoi to
    # .config\mise (the repo IS mise's global config dir). A pre-existing
    # .config\mise (the chezmoi-deployed conf.d era) is moved aside.
    $legacyRepo = Join-Path $env:USERPROFILE ".local\share\chezmoi"
    if (-not (Test-Path "$RepoPath\.git") -and (Test-Path "$legacyRepo\.git")) {
        if (Test-Path $RepoPath) {
            $aside = "$RepoPath.pre-relocation.$(Get-Date -Format yyyyMMddHHmmss)"
            Move-Item -LiteralPath $RepoPath -Destination $aside
            Write-Warn "moved the old $RepoPath (mise conf.d) to $aside — delete it once the new layout works"
        }
        $parent = Split-Path $RepoPath -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Move-Item -LiteralPath $legacyRepo -Destination $RepoPath
        Write-Ok "Relocated the checkout: $legacyRepo -> $RepoPath"
    }
```
Update the header comments at lines 46 and 106–112 to the new default path.

- [ ] **Step 2: mise pin**

In the mise `$PortableTools` entry: `Version = "2026.9.9"`, `Url = "https://github.com/jdx/mise/releases/download/v2026.9.9/mise-v2026.9.9-windows-x64.zip"`, `Sha256 = "f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07"`, `UpdateHint = "dual-edit: `$PortableTools here AND MISE_VERSION in bootstrap.sh AND min_version in config.toml"`. Rewrite the entry's comment: WHAT mise installs is declared by `config.toml` + `config.dev.toml` at the root of the checkout (`%USERPROFILE%\.config\mise` IS the checkout).

- [ ] **Step 3: `Invoke-MiseRuntimes` reads the repo config; MISE_ENV persisted**

Replace `$MiseConfDir` with:
```powershell
$MiseConfigFiles = @("config.toml", "config.dev.toml")   # config.windows.toml joins in PR3
$MiseShims       = Join-Path $env:LOCALAPPDATA "mise\shims"
$MiseEnv         = "windows,dev"
```
`Get-MiseRuntimesStamp`: hash `$MiseConfigFiles | ForEach-Object { Join-Path $RepoPath $_ }` (same fixed-order rule). `Invoke-MiseRuntimes`:
- after the `mise` presence check, persist the env: `[Environment]::SetEnvironmentVariable("MISE_ENV", $MiseEnv, "User"); $env:MISE_ENV = $MiseEnv` (with a one-line comment: every process — shells, hooks, Claude Code — must see the same env set).
- the "no conf.d deployed" warning becomes `"mise tools skipped — $RepoPath\config.toml missing (clone step failed?)"`.
- `$nodeDeclared = [bool](Select-String -Path (Join-Path $RepoPath "config.dev.toml") -Pattern '^node\s*=' -Quiet)`.
- log line: `"Installing mise tools from $RepoPath\config*.toml (node / Go / uv / gopls / LSP servers / ccstatusline — a few minutes on first run)..."`; stamp file name stays `mise-runtimes.<hash>.stamp`.
- Doctor block (2588–2607): messages say `config*.toml` instead of conf.d; add `if ([Environment]::GetEnvironmentVariable("MISE_ENV","User") -eq $MiseEnv) { Write-Ok "MISE_ENV=$MiseEnv persisted (User)" } else { Write-Warn "MISE_ENV not persisted — re-run .\bootstrap.ps1" }`.
- Section header comment 4b: rewrite to the new source of truth (no gen-mise-config.sh, no versions.mk).
- `-SkipToolInstall` message at line 1396 and the closing line 2819: "mise-installed tools" wording; no chezmoi text changes yet.

- [ ] **Step 4: Verify + commit**

```bash
head -c3 bootstrap.ps1 | xxd | head -1           # ef bb bf
grep -n 'local\\share\\chezmoi' bootstrap.ps1     # only the $legacyRepo line + the relocation comment
command -v pwsh >/dev/null && pwsh scripts/check-ps.ps1 || echo "pwsh absent — CI runs PSScriptAnalyzer"
git add bootstrap.ps1 && git commit -m "feat(windows): checkout at .config\\mise, MISE_ENV persisted, mise 2026.9.9, tools from config*.toml" && git push
```

---

### Task 6: rc/env wiring, pueued unit, ccstatusline command, memory pointers

**Files:**
- Rename: `chezmoi/dot_zshenv` → `chezmoi/dot_zshenv.tmpl`
- Modify: `chezmoi/dot_zshenv.tmpl`, `chezmoi/dot_zshrc.tmpl:39-54,184-190`, `chezmoi/dot_bashrc.tmpl:6-26,55-70,243-248`, `chezmoi/dot_config/systemd/user/pueued.service.tmpl:10-15`, `chezmoi/private_dot_claude/modify_private_settings.json:19`, `scripts/setup-ccstatusline.sh`, `makefile/Makefile` (claude-statusline recipe), `makefile/versions.mk` (drop `CCSTATUSLINE_VERSION`), `scripts/check-templates.sh` (add zshenv), `chezmoi/private_dot_claude/CLAUDE.md:20` (non-generated sentence), `chezmoi/private_dot_claude/skills/workstation-lsp/SKILL.md:12`
- Test: `bash scripts/check-templates.sh` (renders both groups; zsh -n on the new zshenv), `scripts/check-invariants.sh` (after Task 7), `bash .claude/hooks/test-hooks.sh` (after Task 7)

- [ ] **Step 1: `dot_zshenv.tmpl` — add the MISE_ENV export (both prepends stay)**

Append (and update the header comment to "three exports"):
```
# --- MISE_ENV: which config.<env>.toml files mise loads on this host ---------
# Computed once by bootstrap.sh (scripts/lib/mise-env.sh) and persisted here so
# every zsh — interactive, `ssh host cmd`, cron — sees the same tool set.
export MISE_ENV="{{ if and (hasKey . "group") (eq .group "dev_machine") }}linux,dev,host,{{ if contains "microsoft" (lower .chezmoi.kernel.osrelease) }}wsl{{ else }}native{{ end }}{{ else }}linux{{ end }}"
```
`dot_bashrc.tmpl` — the same `export MISE_ENV=…` line + a two-line comment inside the ABOVE-the-guard block (after the shims prepend). Update the comments that say "(make mise-runtimes)" / "generated from versions.mk" in all three files to "declared in ~/.config/mise/config*.toml (this checkout)".

- [ ] **Step 2: Remove HELIX_RUNTIME from both rc templates**

In `dot_zshrc.tmpl` lines 40–49 and `dot_bashrc.tmpl` lines 56–65: delete the Helix comment block and the `export HELIX_RUNTIME=…` line; keep the `{{ if … dev_machine }}` gate around `VCPKG_ROOT` only, with its comment. (Helix now finds `runtime/` beside `hx` inside mise's install dir.)

- [ ] **Step 3: pueued unit → shims path (both scopes)**

`pueued.service.tmpl` lines 10–15 become:
```
{{- /* pueued is a mise-installed tool (config.linux.toml); systemd resolves
       ExecStart from a fixed path list, never $PATH, so point at mise's shims
       dir (%h = the user's home). Same path on dev and prod. */}}
ExecStart=%h/.local/share/mise/shims/pueued -v
```
(The `run_onchange_after_enable-pueued` script re-fires on this content change and restarts the daemon.)

- [ ] **Step 4: ccstatusline runs from mise, not npx**

- `modify_private_settings.json:19`: `"command": "ccstatusline",` (the `npm:ccstatusline` shim is on PATH via `~/.zshenv`).
- `scripts/setup-ccstatusline.sh`: delete `CCSTATUSLINE_VERSION=…` (line 28); `preflight` checks `command -v ccstatusline` (message: "ccstatusline not found — `make tools MODE=dev` installs it (npm:ccstatusline in config.dev.toml)"); the WSL `npx` trap becomes a check that `command -v ccstatusline` does not resolve under `/mnt/*`; both TUI launches become `ccstatusline </dev/tty`; the two `make -C makefile mise-runtimes MODE=dev` hints become `make -C makefile tools MODE=dev`; the comment block at ~line 154 ("statusline version bumps are a dual-edit with versions.mk") becomes "the pin is `npm:ccstatusline` in config.dev.toml".
- `makefile/Makefile` claude-statusline recipe: drop `CCSTATUSLINE_VERSION=$(CCSTATUSLINE_VERSION)`; `makefile/versions.mk`: delete the `CCSTATUSLINE_VERSION` line.

- [ ] **Step 5: check-templates matrix + memory pointers**

- `scripts/check-templates.sh`: in the per-group matrix add `dot_zshenv.tmpl` with the `zsh` checker (next to `dot_zshrc.tmpl`).
- `chezmoi/private_dot_claude/CLAUDE.md:20`: "their binaries come from mise (`config.dev.toml`, installed by `make tools MODE=dev`)". `SKILL.md:12`: same wording.

- [ ] **Step 6: Verify + commit**

```bash
bash scripts/check-templates.sh 2>&1 | tail -5     # all green incl. dot_zshenv.tmpl
grep -rn 'HELIX_RUNTIME\|mise-runtimes\|npx -y ccstatusline' chezmoi scripts makefile | grep -v CHANGELOG   # expect: empty
git add -A chezmoi scripts/setup-ccstatusline.sh scripts/check-templates.sh makefile
git commit -m "feat(rc): MISE_ENV exported by the rc files; HELIX_RUNTIME gone; pueued + ccstatusline via mise shims" && git push
```

---

### Task 7: check-invariants, gen-tool-memory, hooks

**Files:**
- Modify: `scripts/check-invariants.sh` (functions `mkval`, `check_version_pins`, `check_bumper_exclude`, `check_line_endings_and_mode`, `check_mise_config`→replace, `check_mise_lib`→delete, `check_go_gopls_coupling`, `check_tsls_typescript_coupling`, `check_zjstatus_zellij_coupling`, `check_shellcheck`, `check_shfmt`, dispatch list), `scripts/gen-tool-memory.sh`, `.claude/hooks/sync-tool-memory.sh`, `.claude/hooks/parity-reminder.sh`, `.claude/hooks/post-edit-guard.sh`, `.claude/hooks/test-hooks.sh`
- Test: `scripts/check-invariants.sh` (all green), `bash .claude/hooks/test-hooks.sh` (all green), `scripts/gen-tool-memory.sh && git diff --stat chezmoi/private_dot_claude/CLAUDE.md`

**Interfaces:**
- Produces: `tomlval <file> <dotted.key>` helper in check-invariants.sh; EXCLUDE contract with Task 8: `bump-versions.sh` carries `EXCLUDE="…"` listing mise TOOL NAMES (not `_VERSION` vars) and `check_bumper_exclude` derives the required names from `check_version_pins`'s `tomlval … tools.<name>` calls.

- [ ] **Step 1: `tomlval` helper (after `mkval`)**

```bash
# Python with tomllib: EL9's python3 is 3.9 (no tomllib) — prefer the python-env
# wpy (3.14); CI's python3 is 3.11+. Empty when neither exists (callers soft-skip).
PY=""
for _p in wpy python3; do
  if command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import tomllib' 2>/dev/null; then PY="$_p"; break; fi
done
# tomlval <file> <dotted.key> — print a TOML value (string, or a table's `version`).
# Keys with dots/colons inside quotes are supported: tomlval config.dev.toml 'tools."github:DevToys-app/DevToys"'
tomlval() {
  [ -n "$PY" ] || return 1
  "$PY" - "$1" "$2" <<'PY'
import re, sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
for k in re.findall(r'"[^"]+"|[^.]+', sys.argv[2]):
    d = d[k.strip('"')]
print(d["version"] if isinstance(d, dict) else d)
PY
}
```

- [ ] **Step 2: `check_version_pins` — new pairs**

Replace the body with pairs (each `ok`/`bad` in the existing style; skip with `note` when `PY` is empty):
| pair | left | right |
|---|---|---|
| jq | `tomlval config.linux.toml tools.jq` | bootstrap.ps1 `Name = "jq"` entry `Version` |
| gh | `tomlval config.linux.toml tools.gh` | bootstrap.ps1 `Name = "gh"` |
| helix | `tomlval config.linux.toml tools.helix` | bootstrap.ps1 `Name = "Helix"` |
| opencode | `tomlval config.dev.toml tools.opencode` | bootstrap.ps1 `Name = "OpenCode"` |
| omp | `tomlval config.dev.toml 'tools."github:can1357/oh-my-pi"'` | bootstrap.ps1 `Name = "omp"` (match the existing `Name` string) |
| devtoys-cli | `tomlval config.dev.toml 'tools."github:DevToys-app/DevToys"'` | bootstrap.ps1 DevToys CLI entry |
| mise (three-way) | `grep -E '^MISE_VERSION=' bootstrap.sh` | bootstrap.ps1 `Name = "mise"` `Version` AND `tomlval config.toml min_version` (all three equal) |
| python-env | `mkval PYTHON_VERSION` | `$PythonEnvVersion` (unchanged) |
| jetbrains nerd | unchanged (versions.mk ↔ ps1 ↔ font.sh) |
| vcpkg-root | unchanged (Makefile ↔ zshrc ↔ bashrc) |
Delete: ccstatusline pair, shfmt/gitleaks ↔ lint.yml pair, helix-runtime pair. The ps1 version extraction helper stays as it is (grep the `Name = "<x>"` block for `Version`).

- [ ] **Step 3: `check_bumper_exclude` — derive TOOL NAMES**

```bash
  pins=$(awk '/^check_version_pins\(\) \{/,/^\}/' scripts/check-invariants.sh |
    grep -oE "tomlval config[a-z.]*toml '?tools\.[^ ']+'?" | sed -E "s/.*tools\.//; s/^\"//; s/\"'?$//" | sort -u)
```
and assert every one (`jq gh helix opencode github:can1357/oh-my-pi github:DevToys-app/DevToys`) is in `EXCLUDE`, plus the coupled set the message names (`github:dj95/zjstatus go go:golang.org/x/tools/gopls http:ncdu node`). Message text: "the weekly bumper would rewrite config*.toml alone and fail the pin check".

- [ ] **Step 4: replace `check_mise_config` with `check_mise_config_files`; delete `check_mise_lib`; adjust couplings**

```bash
check_mise_config_files() {
  hdr "mise config*.toml parse + lockfile coverage + min_version"
  local f
  for f in config.toml config.linux.toml config.dev.toml mise.lock; do [ -f "$f" ] || { bad "missing: $f"; return; }; done
  if [ -z "$PY" ]; then note "no python with tomllib — parse/lock coverage skipped locally (CI enforces)"; return; fi
  if "$PY" - <<'PY'
import tomllib, sys
lock = tomllib.load(open("mise.lock", "rb"))
locked = {k for k in lock.get("tools", {})}
missing = []
for f, need_win in (("config.toml", True), ("config.linux.toml", False), ("config.dev.toml", True)):
    for name, spec in tomllib.load(open(f, "rb")).get("tools", {}).items():
        short = name.split(":", 1)[1] if ":" in name and not name.startswith(("go:","pypi:","pipx:","npm:","http:")) else name
        entries = lock.get("tools", {}).get(name) or lock.get("tools", {}).get(short)
        if not entries:
            missing.append(f"{f}:{name}"); continue
        plats = set()
        for e in entries if isinstance(entries, list) else [entries]:
            plats |= {k.split(".",1)[1] for k in e if k.startswith("platforms.")}
        linux_only = isinstance(spec, dict) and spec.get("os") == ["linux"]
        if not linux_only and need_win and "windows-x64" not in plats and not name.startswith(("pypi:","pipx:","npm:","go:")):
            missing.append(f"{f}:{name} (no windows-x64 lock)")
if missing:
    print("\n".join(missing)); sys.exit(1)
PY
  then ok "every [tools] entry has a mise.lock entry (linux-x64; windows-x64 where it installs on Windows)"
  else bad "mise.lock is missing entries — run: MISE_ENV=linux,dev,host,native mise lock --global --platform linux-x64 && MISE_ENV=windows,dev mise lock --global --platform windows-x64"; fi
  if command -v mise >/dev/null 2>&1; then
    if MISE_CONFIG_DIR="$PWD" MISE_ENV=linux,dev,host,native mise config ls >/dev/null 2>&1 && MISE_CONFIG_DIR="$PWD" mise tasks validate >/dev/null 2>&1; then ok "mise loads the config files and validates tasks/"; else bad "mise config ls / tasks validate failed against this checkout"; fi
  else note "mise not installed — config load check skipped"; fi
}
```
(Adjust the lock-entry lookup to the real `mise.lock` key shape observed in Task 1 — the block header is `[[tools.<name>]]` where `<name>` may be the full backend key; the script above tries both.)
- `check_go_gopls_coupling`: `gov=$(tomlval config.dev.toml tools.go)`, `goplsv=$(tomlval config.dev.toml 'tools."go:golang.org/x/tools/gopls"')`.
- `check_tsls_typescript_coupling`: parse `tomlval config.dev.toml tools.node` is not enough (postinstall string) — read the raw line: `post=$(grep -E '^node = ' config.dev.toml)`; `tslsv=$(grep -oE 'typescript-language-server@[0-9.]+' <<<"$post" | cut -d@ -f2)`; `tsv=$(grep -oE 'typescript@[0-9.]+' <<<"$post" | cut -d@ -f2)`.
- `check_zjstatus_zellij_coupling`: `zellijv=$(tomlval config.linux.toml tools.zellij)`, `zjv=$(tomlval config.linux.toml 'tools."github:dj95/zjstatus"')` (or the `http:zjstatus` key per Task 1), floor from `mkval ZJSTATUS_ZELLIJ_FLOOR`.
- `check_line_endings_and_mode` files: `makefile/lib/*.sh scripts/*.sh scripts/lib/*.sh tasks/* .claude/hooks/*.sh chezmoi/dot_local/bin/executable_*`; `check_shellcheck` + `check_shfmt` lists gain `scripts/lib/*.sh tasks/*`.
- Dispatch: remove `check_mise_config`, `check_mise_lib`; add `check_mise_config_files` after `check_tools_block`; add `check_mise_install_lib` running `bash scripts/test-mise-install.sh` (same shape as the old `check_mise_lib`).
- `check_update_spec_coverage` stays (5 pins, still `make -p`).

- [ ] **Step 5: `scripts/gen-tool-memory.sh` — read the TOML**

Rewrite the VAR→name map + versions.mk walk as: (a) sections from the three config files via `$PY` (same tomllib discovery as check-invariants; exit 1 with a message if none): `### Cross-platform tools (config.toml)`, `### Linux toolbelt, both scopes (config.linux.toml)`, `### Dev tools (config.dev.toml)`; each entry `- `<short>` <version>` where `<short>` strips `github:<owner>/`, `http:`, `pypi:`/`pipx:`, `npm:`, and `go:…/` prefixes and `<version>` is the string or the table's `version`; node's postinstall adds one line per `<pkg>@<ver>` it names; (b) keep the versions.mk walk for the leftover pins (`### Make-owned pins (versions.mk)`); (c) the two dnf sections unchanged. Then regenerate: `scripts/gen-tool-memory.sh && git diff --stat chezmoi/private_dot_claude/CLAUDE.md` (expect a rewritten TOOLS block).

- [ ] **Step 6: hooks**

- `sync-tool-memory.sh`: trigger `case` → `*/config.toml | */config.*.toml | */makefile/versions.mk | */makefile/packages.mk) ;;`; drop the gen-mise-config block; message: "Regenerated the TOOLS block in chezmoi/private_dot_claude/CLAUDE.md from your config*.toml/versions.mk edit — commit it with this change and run `cza`. If you changed a pin: `mise lock --global` refreshes mise.lock (commit it too)."
- `parity-reminder.sh`: `*/makefile/versions.mk)` message → "versions.mk holds only the Make-era pins (python, nerd font, dozzle, vcpkg): PYTHON_VERSION dual-edits bootstrap.ps1 $PythonEnvVersion; JETBRAINSMONO_NERD_VERSION → lib/font.sh SHA arm + install-nerd-fonts.ps1."; add `*/config.linux.toml | */config.dev.toml | */config.toml)` → "Tool pins changed. jq/gh/helix (config.linux.toml) and opencode/omp/DevToys (config.dev.toml) dual-edit bootstrap.ps1 $PortableTools; min_version dual-edits MISE_VERSION in bootstrap.sh + bootstrap.ps1. Refresh mise.lock: `mise lock --global --platform linux-x64,windows-x64`."; delete the `scope.mk` arm; delete the `modify_private_settings.json` arm.
- `post-edit-guard.sh:45`: glob adds `| */scripts/lib/*.sh | */tasks/*`.
- `test-hooks.sh`: the parity test `versions.mk -> pins` expects `PYTHON_VERSION`; add `run … config.dev.toml …; ok "config.dev.toml -> pins" has 'PortableTools'`; sync-tool-memory tests: drop the conf.d assertions (lines 129–133 and the worktree `conf.d` assertion), the worktree fixture copies `config.toml config.linux.toml config.dev.toml` + `makefile/versions.mk makefile/packages.mk` and expects `cza` + stale gone.

- [ ] **Step 7: Run everything; commit**

```bash
scripts/check-invariants.sh          # all green
bash .claude/hooks/test-hooks.sh     # all green
git add -A scripts .claude chezmoi/private_dot_claude/CLAUDE.md
git commit -m "chore(invariants): pins from config*.toml, lockfile coverage, mise-install test; hooks track config*.toml" && git push
```

---

### Task 8: Bumper on `mise outdated`; CI on mise-action

**Files:**
- Modify: `scripts/bump-versions.sh`, `.github/workflows/lint.yml`, `.github/workflows/version-bumps.yml`
- Test: `BUMP_SUMMARY_FILE=/tmp/b.md scripts/bump-versions.sh --dry-run` (add the flag), `scripts/check-invariants.sh`, CI green on the PR

**Interfaces:**
- Consumes: `mise outdated --bump --json` (verify the shape on this host: `mise outdated --bump --json | head`; keys per tool: `current`, `latest`/`bump`, `source.path`), `mise config set -f <file> 'tools.<name>' <ver>` (string entries) / `'tools.<name>.version'` (table entries), `mise lock --global --platform …` (form from Task 1 step 9).
- Produces: `EXCLUDE` of mise tool names + `EXCLUDE_MK` of versions.mk vars.

- [ ] **Step 1: rewrite `scripts/bump-versions.sh`**

Keep the header/summary structure. New body:
```bash
EXCLUDE="jq gh helix opencode github:can1357/oh-my-pi github:DevToys-app/DevToys github:dj95/zjstatus go go:golang.org/x/tools/gopls http:ncdu node"
EXCLUDE_MK="JETBRAINSMONO_NERD_VERSION PYTHON_VERSION"
DRY=false; [ "${1:-}" = "--dry-run" ] && DRY=true
export MISE_CONFIG_DIR="$ROOT" MISE_ENV="linux,dev,host,native"
outdated="$(mise outdated --bump --json 2>/dev/null || echo '{}')"
while IFS=$'\t' read -r name cur new path; do
  [ -n "$name" ] || continue
  case " $EXCLUDE " in *" $name "*) manual="${manual}- \`$name\`: $cur → $new — coupled/dual-edit pin (manual)\n"; continue ;; esac
  file="${path##"$ROOT"/}"
  # table-valued entries (github:/http: with options) take tools.<name>.version
  if grep -qE "^\"?${name//\//\\/}\"? = \{" "$file"; then key="tools.\"$name\".version"; else key="tools.\"$name\""; fi
  $DRY || mise config set -f "$file" "$key" "$new"
  bumped="${bumped}- \`$name\` ($file): $cur → $new\n"
done < <(printf '%s' "$outdated" | jq -r 'to_entries[] | select(.value.bump != null and .value.bump != .value.requested) | [.key, .value.requested, .value.bump, .value.source.path] | @tsv')
if [ -n "$bumped" ] && ! $DRY; then
  MISE_ENV=linux,dev,host,native mise lock --global --platform linux-x64
  MISE_ENV=windows,dev mise lock --global --platform windows-x64
  scripts/gen-tool-memory.sh >/dev/null
fi
```
followed by the OLD versions.mk half restricted to the 5 remaining specs (unchanged code path via `make check-updates` porcelain, `EXCLUDE_MK`). Adjust the `jq` filter to the real JSON field names you observed. Summary footer: "Each bumped pin installs on the next `make provision` (`mise install`); mise.lock updated."

- [ ] **Step 2: `lint.yml` invariants job on mise-action**

Replace the "Install shfmt + gitleaks (pinned)" step with:
```yaml
      - uses: jdx/mise-action@v3
        with:
          version: 2026.9.9
          install: false
          cache: true
      - name: Install shfmt + gitleaks from the repo's own config (lockfile-verified)
        run: mise install shfmt gitleaks && shfmt --version && gitleaks version
        env:
          MISE_CONFIG_DIR: ${{ github.workspace }}
          MISE_ENV: linux
```
and set `MISE_CONFIG_DIR: ${{ github.workspace }}` + `MISE_ENV: linux` as `env:` on the "Run invariant checks" step too (the config-load check). Delete the dual-edit comment. Confirm `jdx/mise-action` latest major on the Marketplace before pinning (`gh api repos/jdx/mise-action/releases/latest --jq .tag_name`); use that major.

- [ ] **Step 3: `version-bumps.yml`**

Insert the same `jdx/mise-action` step (with `version: 2026.9.9`, `install: false`) plus `sudo apt-get install -y jq` before "Propose version bumps"; pass `MISE_CONFIG_DIR: ${{ github.workspace }}` in that step's `env:`.

- [ ] **Step 4: Dry-run + commit**

```bash
BUMP_SUMMARY_FILE=/tmp/b.md scripts/bump-versions.sh --dry-run && cat /tmp/b.md | head -20
scripts/check-invariants.sh | tail -3
git add scripts/bump-versions.sh .github/workflows
git commit -m "ci: bumper on mise outdated + mise config set; lint installs shfmt/gitleaks via mise-action" && git push
gh pr create --draft --title "feat(mise): toolbelt on mise, checkout at ~/.config/mise (PR 1/3)" --body "Draft until Task 10 verification. See docs/superpowers/specs/2026-09-16-mise-everything-design.md" --base main
gh pr checks --watch   # all five lint jobs green
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.html` (§`stack` mise/tools cards ~1459–1493, §`layout` tree ~2016–2100, §`setup-linux` ~2345–2600 (prereqs, path, steps, ccstatusline/mise hints), §`daily` ~4055–4340 (make tool commands, check-updates, mise-runtimes, zjstatus 6045, update-hosts text 4254–4280, `~/.local/share/chezmoi` mentions), §`adding` ~4716–4800 (add a tool = `[tools]` + `mise lock`), §`troubleshooting` entries for eget/verify-binary/lsp-servers/mise-runtimes/DEST/"make errored with"); `CLAUDE.md`; `docs/claude/invariants.md` bullets 9, 10, 12, 23, 28, 48; `docs/claude/file-care.md` bullets 26–33, 35, 54–59 and new `config*.toml`/`mise.lock`/`tasks/` entries; `docs/claude/verification.md` lines 11–15, 26–27, 40; `CLAUDE_CHANGELOG.md` (one row at the top of the table); `.claude/memory/project-mise-everything.md` (new) + `MEMORY.md` line
- Test: `npm install --no-save --no-package-lock --no-audit --no-fund jsdom@30.0.1 && node scripts/check-readme.mjs`; `rg -n 'local/share/chezmoi|make (gitui|mise-runtimes|lsp-servers|clean-)|versions\.mk' README.html CLAUDE.md docs/claude` — every remaining hit must be a deliberate historical mention

- [ ] **Step 1: README** — for each section above: replace `make <tool> MODE=…`/`make clean-<tool>` with `mise install <tool>` / `mise uninstall <tool>` / `make tools MODE=…`; `make check-updates` → `mise outdated --bump` (+ `make check-updates` for the four Make-owned pins); `~/.local/share/chezmoi` → `~/.config/mise` (setup, daily, hosts, troubleshooting; add a troubleshooting entry "the checkout moved — bootstrap relocates it; `chezmoi` config gets `sourceDir`"); §adding: "add `name = "x.y.z"` to `config.linux.toml` (or `config.dev.toml`), run `mise install name`, `tasks/verify-tools`, `MISE_ENV=… mise lock --global --platform linux-x64,windows-x64`, commit the lock"; §stack mise card: "owns every tool now"; prerequisites: drop `unzip`; keep `make` (until PR2). Windows §setup-windows: repo path + `MISE_ENV` sentence. Preserve every `id=` anchor (check-readme asserts them).
- [ ] **Step 2: CLAUDE.md** — rewrite the "Load-bearing invariants" entries: "Tool versions only in versions.mk" → "Tool pins live in `config*.toml` + `mise.lock` at the repo root (the checkout IS `~/.config/mise`); `versions.mk` keeps only the four Make-owned pins until PR2"; delete the `EGET_TOOL` stamp bullet and the Helix-runtime bullet; the verify-gate bullet → `tasks/verify-tools` (post-install, not pre-stamp); the mise-runtimes bullet → "Tools are mise-managed via `make tools` …" (env scheme, `mise-env.sh`, `mise-install.sh`, node marker, sweep, shims); Windows bullet: config from the checkout at `%USERPROFILE%\.config\mise`, `MISE_ENV` user var; dual-edit list: drop SHFMT/GITLEAKS/CCSTATUSLINE/HELIX_RUNTIME, add "MISE three-way", jq/gh/helix/opencode/omp/devtoys now `config*.toml` ↔ `bootstrap.ps1`; hooks section (`sync-tool-memory.sh` triggers); "Files Claude should be careful with": `tasks/*`, `scripts/lib/*.sh` in the LF/0755 set, `config*.toml` + `mise.lock` ("never hand-edit mise.lock"), remove `tools.mk`/`eget.sh`/`mise.sh`/conf.d entries; "single-source-of-truth files": `config*.toml`, `scripts/lib/mise-env.sh`.
- [ ] **Step 3: docs/claude/*.md** — mirror Step 2 in `invariants.md` (full why) and `file-care.md` (per-file); `verification.md`: replace the `make list`/`make -j8 all … DEST=/tmp` sandbox recipe with `MISE_CONFIG_DIR=$PWD MISE_DATA_DIR=/tmp/mise-sandbox MISE_ENV=linux,dev,host,native mise install && tasks/verify-tools`, and the mise-runtimes recipe with the `make tools` one.
- [ ] **Step 4: CHANGELOG row** (top of the table): "**Toolbelt on mise (PR 1/3 of the Make→mise migration).** Every tools.mk tool → `config.linux.toml`/`config.dev.toml`/`config.toml` + `mise.lock`; the checkout moves to `~/.config/mise` (Linux) / `%USERPROFILE%\.config\mise` (Windows) — it IS mise's global config dir; `MISE_ENV` selects env files (rc-exported; Windows User var); `make tools` = `mise-install.sh` + `tasks/verify-tools` + `tasks/migrate-legacy`; eget/archive/direct/pip/helix/mise libs + tools.mk + gen-mise-config deleted; ccstatusline via `npm:`; `HELIX_RUNTIME` gone; bumper on `mise outdated`; CI on mise-action. | **Yes** | §setup (path, prereqs), §daily (mise commands), §adding (rewritten), §layout, §troubleshooting."
- [ ] **Step 5: memory** — `.claude/memory/project-mise-everything.md` (type project): PR1 shipped state, the env token table, the "repo IS ~/.config/mise" fact, the spike rulings (asset patterns), "Windows spike/bootstrap runs are the user's", link `[[project-mise-runtimes-shipped]]`; add the MEMORY.md line.
- [ ] **Step 6: Checks + commit**

```bash
npm install --no-save --no-package-lock --no-audit --no-fund jsdom@30.0.1 && node scripts/check-readme.mjs
scripts/check-invariants.sh | tail -2
git add README.html CLAUDE.md docs/claude CLAUDE_CHANGELOG.md .claude/memory
git commit -m "docs: mise owns the toolbelt; checkout at ~/.config/mise; CLAUDE.md invariants for the mise era" && git push
```

---

### Task 10: On-host verification and rollout hand-off (controller + user)

**Files:** none (runtime only).

- [ ] **Step 1: Controller — user-level path first (no sudo)**

```bash
cd ~/.local/share/chezmoi && git status --short | wc -l   # 0
export PATH="$HOME/.local/bin:$PATH"; mise --version        # 2026.9.9 (Task 1 step 1)
MISE_ENV=linux,dev,host,wsl scripts/lib/mise-install.sh     # real data dir this time
MISE_ENV=linux,dev,host,wsl tasks/verify-tools              # ✓ N ELF binaries pass
MISE_ENV=linux,dev,host,wsl mise ls --missing | wc -l       # 0
```

- [ ] **Step 2: User — the full bootstrap (relocation + make + sweep need sudo once)**

Hand over exactly:
```
! cd ~/.local/share/chezmoi && ./bootstrap.sh --dev
```
Expected in the output: "Relocating the workstation checkout … → ~/.config/mise", "mise 2026.9.9 present", "==> tools (mise install, MISE_ENV=linux,dev,host,wsl)", "✓ verify-tools", "✓ legacy tool installs swept", "chezmoi config refreshed", "Bootstrap complete."

- [ ] **Step 3: Controller — post-run checks (from the NEW path)**

```bash
cd ~/.config/mise && git status --short | wc -l           # 0 (only hosts.conf may have been touched by self_register)
grep -n sourceDir ~/.config/chezmoi/chezmoi.toml           # sourceDir = ".../.config/mise"
chezmoi status | wc -l                                     # 0 after the user's run (cza applied); else `chezmoi diff`
ls /usr/local/bin | grep -cE '^(fzf|zellij|hx|rg|eget|mise)$'   # 0
for t in hx zellij rg fzf starship bat jq gh pueue tldr nnn usql fastfetch procs jless broot trip nnd chezmoi cheat gitleaks shfmt rust-analyzer marksman taplo gopls node go uv ccstatusline pwndbg devtoys.cli omp herdr opencode glances; do printf '%-14s %s\n' "$t" "$(command -v $t)"; done   # every one under ~/.local/share/mise/
hx --health | head -3; tldr --version; zellij --version
grep 'Loaded plugin' /tmp/zellij-$(id -u)/zellij-log/zellij.log | tail -1   # after `zellij kill-session main; zellij` in a tab (user)
make -C makefile doctor MODE=dev | tail -8                 # tools ✓, legacy sweep ✓, wiring ✓
env | grep MISE_ENV                                        # in a NEW shell: linux,dev,host,wsl
systemctl --user is-active pueued.service                  # active (unit now points at the shim)
```

- [ ] **Step 4: Windows (user runs; not before Step 3 is green)**

Hand over: on Windows, `cd $env:USERPROFILE\.local\share\chezmoi; git fetch; git checkout feat/mise-tools; git pull; .\bootstrap.ps1`. Expected: "Relocated the checkout: … -> …\.config\mise", mise 2026.9.9 downloaded, "mise tools installed", `-Doctor` rows: MISE_ENV persisted, mise tools nothing missing. Then in a new PowerShell: `mise ls` shows node/go/gopls/uv/ccstatusline/rust-analyzer/marksman/taplo/lua-language-server/basedpyright; `ccstatusline --version` resolves.

- [ ] **Step 5: Mark the PR ready; hand-off**

```bash
gh pr ready
```
Report: the verification results, the rulings from Task 1 step 7, and the rollout plan — after merge, `scripts/update-hosts.sh --group prod_machine --name cache-apl` first (one prod host: no sudo path exercised), then `--group prod_machine`, then `--group dev_machine` (dev hosts prompt for sudo once inside `./bootstrap.sh --dev`, so run them with a TTY: `update-hosts.sh --parallel 1`).

---

## Self-review

- Spec coverage (PR1 scope: §3 layout for config files/lock/tasks/scripts-lib, §4 env scheme, §5 tools mapping + gate + helix + lock, §9 bootstrap.sh mise pin + relocation + MISE_ENV, bootstrap.ps1 path/env/pin, update-hosts remote command, bumper, CI, invariants, hooks, docs, §10 PR1 migration row): Task 1 (§3 files, §5 mapping/lock), Task 2 (§5 gate, §7 `verify-tools`/`migrate-legacy`), Task 3 (`make tools`, `provision` phases, doctor), Task 4 (§9 bootstrap.sh, update-hosts, chezmoi sourceDir), Task 5 (§9 bootstrap.ps1), Task 6 (§4 rc exports, helix runtime, pueued path, ccstatusline command), Task 7 (§9 invariants + hooks + memory generator), Task 8 (§9 bumper + CI), Task 9 (docs), Task 10 (§10 PR1 row). `[bootstrap.*]`, `tasks/bootstrap`, `health`, dotfiles, `hosts.conf` remote env are PR2/PR3 — out of scope here by design.
- Placeholders: none — every open item (nnd tag, zjstatus backend, pwndbg bin_path, omp asset, pipx/pypi prefix, lock invocation form, outdated JSON shape, mise-action major) has an explicit resolution rule and a step that records the ruling.
- Name consistency: `scripts/lib/mise-env.sh`, `scripts/lib/mise-install.sh`, `tasks/verify-tools`, `tasks/migrate-legacy`, `scripts/lib/verify-binary.sh`, `scripts/lib/zellij-plugin.sh`, `REPO_DIR`, `MISE_VERSION`/`MISE_SHA256`, `$MiseConfigFiles`, `$MiseEnv`, `tomlval`, `check_mise_config_files`, `check_mise_install_lib`, tool keys `"github:dj95/zjstatus"`, `"github:can1357/oh-my-pi"`, `"github:DevToys-app/DevToys"`, `"npm:ccstatusline"` are used identically across Tasks 1–9.
