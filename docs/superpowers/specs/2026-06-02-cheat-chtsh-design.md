# Design spec: `cheat` + `cht.sh` cheatsheet tooling

- **Date:** 2026-06-02
- **Status:** approved (design); pending implementation plan
- **Scope:** install + configure the `cheat` offline cheatsheet CLI and the
  `cht.sh` online cheat.sh client across both `dev_machine` and `prod_machine`
  Linux hosts. Windows host out of scope.

## 1. Summary

Add two complementary cheatsheet tools to the workstation toolbelt:

- **`cheat`** ([cheat/cheat](https://github.com/cheat/cheat)) — a Go single-binary
  CLI for **offline** cheatsheets. The user authors personal sheets (synced via
  this repo) and reads from a seeded read-only community pack. Works with no
  network once installed.
- **`cht.sh`** — the client for the **online** [cheat.sh](https://cheat.sh)
  service (`cht.sh go reverse a list`). A rolling bash script. Needs outbound
  network at query time; degrades to a plain error on an offline host.

Both sit alongside the existing `tldr` (tealdeer) tool, which they overlap with
but do not replace: `tldr` = curated example-driven pages; `cheat` = your own
notes + community sheets offline; `cht.sh` = live multi-source answers online.

## 2. Decisions (from brainstorming Q&A)

| Question | Decision |
|---|---|
| Which tools | **Both** `cheat` + `cht.sh` |
| Personal sheets tracked in repo | **Yes** — chezmoi-managed, synced to every host |
| Community sheets | **Seed once** via a `run_once` git clone (not vendored) |
| `cht.sh` install gating | **Both** dev + prod (offline hosts just error at query time) |
| `rlwrap` (nicer `cht.sh --shell`) | **Yes, dev-only** (system package) |
| `cht.sh` tab-completion | **Yes** — zsh only (upstream ships no bash completion) |
| Command aliases (`cht`/`chts`) | **No** — invoke `cht.sh` / `cheat` directly |

## 3. Architecture, by layer

### 3.1 Install layer — `makefile/`

**`versions.mk`** — new section after the existing pins:

```make
# --- Cheatsheets (cheat + cht.sh) -------------------------------------------
CHEAT_VERSION := 5.1.0          # cheat/cheat; non-v tag, gzipped single binary
CHTSH_VERSION := latest         # rolling client script served at cht.sh/:cht.sh
```

**`tools.mk`** — two entries; both macros do `SCOPE_TOOLS += $(1)`, so both
install on **dev** (`/usr/local/bin`) and **prod** (`~/.local/bin`):

```make
# cheat — offline cheatsheet CLI. Non-v tag (5.1.0); release assets are gzipped
# single binaries (cheat-linux-amd64.gz). Verified: eget 1.3.4 decompresses the
# .gz and installs a binary named `cheat` (not the asset name). --asset amd64
# excludes the arm5/6/7/arm64 variants published in the same release.
$(eval $(call EGET_TOOL,cheat,$(CHEAT_VERSION),cheat/cheat,$(CHEAT_VERSION),--asset amd64))

# cht.sh — client for the cheat.sh online service. A rolling bash script (not a
# GitHub release), so direct.sh fetches the raw URL and installs it 0755 as
# `cht.sh`. On an offline prod host it errors at query time; cheat + tldr stay
# offline-capable.
$(eval $(call TOOL,cht.sh,$(CHTSH_VERSION),\
  $(LIB)/direct.sh cht.sh https://cht.sh/:cht.sh))
```

Rationale for the install choice is recorded in §6 (approaches considered).

**`packages.mk`** — append `rlwrap` to `LINUX_OPTIONAL_PACKAGES` (the
best-effort, per-package `|| true` list). It is the readline wrapper that gives
`cht.sh --shell` history + line editing. Dev-only by construction: the whole
file no-ops unless `INSTALL_PACKAGES=true` (set only for `MODE=dev` in
`scope.mk`). On prod, `cht.sh --shell` still runs, just without readline polish.

### 3.2 Config layer — chezmoi-tracked

**`chezmoi/dot_config/cheat/conf.yml.tmpl`** → `~/.config/cheat/conf.yml`.
Templated only to expand the home dir in cheatpaths (robust vs `~`):

```yaml
# cheat configuration — managed by chezmoi. `editor` is intentionally omitted
# so cheat inherits $EDITOR (= hx, set repo-wide in the rc) — no dual-edit.
colorize: true
style: monokai          # chroma style (built into the cheat binary)
formatter: terminal16m  # truecolor; WezTerm supports it
pager: less -FRX
cheatpaths:
  - name: personal      # listed first -> personal sheets take precedence
    path: {{ .chezmoi.homeDir }}/.config/cheat/cheatsheets/personal
    tags: [ personal ]
    readonly: false
  - name: community     # seeded by run_once (§3.3); read-only
    path: {{ .chezmoi.homeDir }}/.config/cheat/cheatsheets/community
    tags: [ community ]
    readonly: true
```

cheat finds this at `~/.config/cheat/conf.yml` (its XDG default search path); no
`CHEAT_CONFIG_PATH` env var needed.

**`chezmoi/dot_config/cheat/cheatsheets/personal/workstation`** (new, tracked) —
a starter personal sheet. Purposes: (a) gives the `personal` cheatpath a tracked
file so git materialises the directory, (b) is genuinely useful — `cheat
workstation` becomes a synced quick-reference for this repo's own daily aliases
(`cz*`, `zj*`, the cheatsheet tools). Plain text; cheat draws tags from the
cheatpath config, not file frontmatter.

### 3.3 Community-sheets seed — `run_once`

**`chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl`**, modelled
directly on the existing `run_once_seed-tldr-cache.sh.tmpl`:

- `{{ if eq .chezmoi.os "linux" }}` body gate (`.chezmoiscripts/` are not
  covered by `.chezmoiignore`; a non-linux render is empty and chezmoi skips it).
- `set -euo pipefail`; **soft-fail throughout** — a network blip must never turn
  `cza` (`chezmoi apply`) into a hard failure.
- Skip if `cheat` is not on `PATH` (with a message); skip if
  `~/.config/cheat/cheatsheets/community` already exists (idempotent).
- Otherwise `git clone --depth 1 https://github.com/cheat/cheatsheets
  ~/.config/cheat/cheatsheets/community`, tolerating failure (offline).

**Ordering:** verified that `bootstrap.sh` runs `make … provision` (which
installs `cheat`) **before** `chezmoi init --apply` (which runs `run_once`
scripts), so `cheat` is on `PATH` on first apply — same guarantee the tldr seed
relies on. Accepted limitation (shared with the tldr seed): a host that gains
`cheat` *after* its first apply won't auto-seed; the dir-exists guard means a
manual `git clone` (or removing the run_once state) is the fix.

chezmoi only manages paths it has source for, so the unmanaged `community/`
clone living next to the managed `personal/` tree is left untouched on every
apply (chezmoi does not delete unmanaged siblings).

### 3.4 Shell layer — completion (parity pair)

**Vendored:** `chezmoi/dot_config/zsh/completions/_cht.sh` — the body of
`https://cheat.sh/:zsh` (a `#compdef cht.sh` function; on Tab it fetches the
language list via `curl cheat.sh/:list`). Vendored-file rules apply (see §3.6).
**Constraint:** zsh requires `#compdef cht.sh` to be the *literal first line*, so
the vendored header comment goes on lines 2+, not above it.

**`dot_zshrc.tmpl`** — prepend the completions dir to `$fpath` **before** the
existing `autoload -Uz compinit && compinit -C` line:

```zsh
fpath=("$HOME/.config/zsh/completions" $fpath)
```

so `compinit` autoloads `_cht.sh`. No alias lines are added (decision §2).

**`dot_bashrc.tmpl`** — **no functional change**; add a short parity comment
noting that cht.sh upstream ships zsh/fish/emacs completions but **no bash**
completion, so bash has none by design (directly analogous to the existing
"bash gets movement-only Shift+Arrow parity, no highlight — readline limitation"
note). This keeps the zshrc↔bashrc parity pair honest about the asymmetry.

The zsh completion calls the network at completion time; on an offline host Tab
returns an empty language list. Acceptable for an inherently-online tool.

### 3.5 Gating matrix

| Artifact | dev | prod | Windows |
|---|---|---|---|
| `cheat`, `cht.sh` binaries | ✅ `/usr/local/bin` | ✅ `~/.local/bin` | ❌ (ps1 untouched) |
| `rlwrap` package | ✅ | ❌ (no-op on prod) | ❌ |
| `conf.yml` + personal sheet | ✅ | ✅ | ❌ |
| community seed | ✅ | ✅ | ❌ (linux body gate) |
| `_cht.sh` zsh completion | ✅ | ✅ | ❌ |

**`.chezmoiignore.tmpl`** — add `dot_config/cheat` to the existing
`{{ if eq .chezmoi.os "windows" }}` block (mirroring `dot_config/helix`,
`dot_config/zellij`). The zsh completion needs no new ignore entry:
`dot_config/zsh` is already in that Windows block. No dev-only gating — `cht.sh`
is wanted on both scopes, so nothing goes in the dev-only ignore block.

### 3.6 Vendored-file handling

`_cht.sh` joins the repo's "vendored — don't hand-edit; re-download + refresh
sha256" category. It gets a header (lines 2+, under the mandatory `#compdef`
line 1) in the established style: upstream source URL (`https://cheat.sh/:zsh`),
the snapshot date (rolling source — no upstream tag, so pin by snapshot), the
sha256 of the fetched body, and bump instructions. Snapshot at spec time:
`sha256 = af384d0a3342e0156be150d4c1f64ccd94bcfde65f52f7f03b1becf359cdef24`
(re-verify at implementation; the source is rolling).

Tripwire bookkeeping:
- **`CLAUDE.md`** — add `_cht.sh` to the "Vendored — don't hand-edit" bullet
  under "Files Claude should be careful with".
- **`docs/claude/file-care.md`** — add a per-file entry for `_cht.sh`.

### 3.7 Docs (required by repo conventions)

- **`README.html`** — add `cheat` + `cht.sh` to the tool inventory; a short
  "Cheatsheets" usage blurb: `cheat -l` / `cheat tar` / `cheat -e tar`
  (edits a personal sheet in `$EDITOR`, synced via this repo) / `cheat -s <kw>`;
  `cht.sh <lang> <query>` and `cht.sh --shell` (with the rlwrap/dev note);
  config at `~/.config/cheat/conf.yml`; zsh Tab-completion for `cht.sh`; the
  community pack is seeded on first apply. Note the offline/online split vs tldr.
- **`CLAUDE_CHANGELOG.md`** — append a row (user-facing surface changed).

## 4. Files touched

New (5): `chezmoi/dot_config/cheat/conf.yml.tmpl`,
`chezmoi/dot_config/cheat/cheatsheets/personal/workstation`,
`chezmoi/.chezmoiscripts/run_once_seed-cheat-community.sh.tmpl`,
`chezmoi/dot_config/zsh/completions/_cht.sh`,
`docs/superpowers/specs/2026-06-02-cheat-chtsh-design.md` (this file).

Edited (10): `makefile/versions.mk`, `makefile/tools.mk`, `makefile/packages.mk`,
`chezmoi/.chezmoiignore.tmpl`, `chezmoi/dot_zshrc.tmpl`,
`chezmoi/dot_bashrc.tmpl`, `README.html`, `CLAUDE_CHANGELOG.md`,
`CLAUDE.md`, `docs/claude/file-care.md`.

## 5. Verification plan

Drawn from `docs/claude/verification.md`:

1. **Sandbox install** (no sudo, throwaway dirs):
   `make cheat cht.sh MODE=prod DEST=/tmp/t STAMP=/tmp/s` → both land in
   `/tmp/t`, executable; `/tmp/t/cheat --version` and `/tmp/t/cht.sh --help` run.
2. **dev package**: confirm `rlwrap` appears in `make packages` output on a dev
   host (or that the line is present + best-effort).
3. **chezmoi templating**: `chezmoi cat ~/.config/cheat/conf.yml` renders the
   home dir correctly; the `workstation` personal sheet deploys; `cheat -l`
   lists both `personal` and `community` paths.
4. **run_once**: `chezmoi apply` clones the community pack; a second apply is a
   no-op; offline apply soft-fails without erroring.
5. **completion**: in zsh, `cht.sh <Tab>` offers languages (online);
   `_cht.sh` is on `$fpath` before compinit.
6. **gating**: `.chezmoiignore` Windows block hides `dot_config/cheat`; no
   dev-only gating present.
7. **file hygiene**: vendored `_cht.sh` header + sha256 correct; rc files remain
   a matched parity pair; `README.html` renders.

## 6. Approaches considered (install mechanism)

- **`cheat` via `EGET_TOOL`** (chosen) — eget 1.3.4 was tested live: it
  decompresses the `.gz` single-binary asset and installs it as `cheat`. Matches
  the dominant repo pattern (~41 tools). Rejected: `direct.sh` (cannot gunzip a
  `.gz`); a new `gz.sh` lib helper (unnecessary surface area + a new LF/0755
  tripwire, since eget already produces the right result).
- **`cht.sh` via `TOOL` + `direct.sh`** (chosen) — it is a rolling raw script,
  not a GitHub release; this is the exact `sysz` / `ssh-copy-id` pattern.
  Rejected: `EGET_TOOL` (no release asset exists).

## 7. Risks & limitations

- **Offline prod**: `cht.sh` and the zsh completion's language list need the
  network; both fail gracefully. `cheat` (after seed) and `tldr` cover offline.
- **Rolling vendored completion**: `cht.sh/:zsh` has no version tag; pinned by
  snapshot sha256, refreshed on bump like other vendored files.
- **No bash completion**: upstream provides none; documented, not hand-rolled.
- **Late-install seed gap**: a host gaining `cheat` after first apply needs a
  manual community clone (shared limitation with the tldr cache seed).
