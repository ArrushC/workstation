# zsh autosuggestions, syntax highlighting & fzf-tab completion

**Date:** 2026-06-03
**Status:** Approved (design)
**Scope:** zsh interactive prompt only (three vendored plugins + rc wiring). bash
gets parity notes. No new tools, no Makefile changes, no WezTerm changes.

## Problem

The zsh prompt has solid completion bones already — `compinit -C` runs
(`dot_zshrc.tmpl:102`), `~/.config/zsh/completions` is on `fpath` (line 101),
and `fzf` is installed and wired (Ctrl-T/Ctrl-R/Alt-C, Catppuccin-themed). What
it lacks is the modern interactive layer most people mean by "good zsh":

- **Inline history suggestions** (fish-style) as you type.
- **Live syntax highlighting** of the command line (valid command vs typo,
  quoting, paths).
- **A richer completion menu** — the default zsh menu is plain; an fzf-driven
  picker fits the repo's existing fzf + Catppuccin theming.

The user's source snippet also asked to "enable zsh's built-in completion"
(`autoload -Uz compinit && compinit`) — that is **already present** and out of
scope. `zsh-completions` (a large bundle of extra completion functions) was
considered and **deliberately excluded** (see Rejected alternatives).

## Key architectural decision

**Hand-vendor the three plugins at pinned tags**, exactly like the existing
`zsh-shift-select.zsh` and `_cht.sh`: committed into the repo, reproducible
after a fresh clone, offline-capable, no apply-time network, no plugin manager.
A plugin manager (zinit/antidote/sheldon) or `.chezmoiexternal` fetch were
rejected to keep the Make+chezmoi model and the no-supply-chain-surprise
philosophy intact (see Rejected alternatives).

The only behavioral subtlety is **load order**, which is load-bearing and
documented inline (see Implementation → load order).

## Behavior

### zsh prompt (interactive only)

- **Autosuggestions** — as you type, a greyed-out suggestion from history
  appears inline. Accept the whole suggestion with `→` (forward-char) or `End`;
  accept one word with the standard `Ctrl-→` motion. `Ctrl-R` is unchanged
  (stays fzf's history widget). Suggestion color is a muted Catppuccin Mocha
  overlay (`fg=#6c7086`).
- **Syntax highlighting** — the command line is colored live: unknown commands
  in red, valid commands/builtins/aliases in their styles, strings/paths/options
  distinguished. Palette is **Catppuccin Mocha** (`ZSH_HIGHLIGHT_STYLES`), to
  match dircolors / fzf / the rest of the setup.
- **fzf-tab** — pressing `Tab` opens an **fzf picker** over the completion
  candidates instead of the plain zsh menu. It inherits the existing
  `FZF_DEFAULT_OPTS` Catppuccin theme; `<` / `>` switch completion groups. This
  is the default Tab behavior (user-approved), not opt-in.

All three are **interactive-only** and each `source` is guarded with
`[[ -r … ]]`, so a host that hasn't applied the files yet degrades silently
(same pattern as the shift-select guard).

### bash prompt — parity notes only

autosuggestions / syntax-highlighting / fzf-tab all require zsh's ZLE; readline
has no equivalent without a heavy third-party layer (ble.sh), which is out of
scope. `dot_bashrc.tmpl` therefore gets **PARITY NOTES** documenting the
asymmetry — the same shape as the existing cht.sh and Shift+Arrow notes. No
behavior change to bash. (bash already has colored completion via the existing
`colored-stats` readline binding and system `bash-completion`.)

## Implementation

### New vendored files

Each plugin in its own subdir under the existing
`chezmoi/dot_config/zsh/plugins/` (the existing flat `zsh-shift-select.zsh` is
untouched):

```
plugins/
  zsh-shift-select.zsh                          (existing — untouched)
  zsh-autosuggestions/
    zsh-autosuggestions.zsh                      (single combined upstream file)
    .vendor
  zsh-syntax-highlighting/
    zsh-syntax-highlighting.zsh                  (entry point)
    highlighters/…                               (main, brackets, pattern, cursor,
                                                  line, regexp, root)
    .vendor
  fzf-tab/
    fzf-tab.zsh                                  (entry point)
    lib/…                                        (-ftb-* helper sources)
    .vendor
```

- **Pinned versions** (exact commit + tarball sha256 recorded at vendor time in
  each `.vendor`):
  - `zsh-users/zsh-autosuggestions` **v0.7.1** — MIT. Ships a single
    self-contained `zsh-autosuggestions.zsh`; vendor that one file.
  - `zsh-users/zsh-syntax-highlighting` **0.8.0** — BSD-3-Clause. Entry file +
    the `highlighters/` tree (the entry uses `${0:A:h}` to find its own dir, so
    the tree must stay intact). Vendor the full `highlighters/` set.
  - `Aloxaf/fzf-tab` **latest stable tag** — MIT. Entry file + `lib/`. **Skip
    the optional compiled C `modules/`** (needs a build step; the pure-zsh path
    works everywhere — that is the no-build, portable choice consistent with the
    repo's musl-static-everywhere bias).
- **Provenance** lives in a per-plugin **`.vendor`** sidecar (upstream repo URL,
  pinned tag, commit SHA, tarball sha256, license, vendor date). Reason for a
  sidecar instead of a leading header comment (as shift-select / _cht.sh use):
  these are multi-file, and a sidecar lets us vendor every upstream file
  **verbatim** with zero hand-edits. chezmoi auto-ignores any source entry whose
  name begins with `.` (the same mechanism the repo relies on for `.gitkeep`),
  so `.vendor` is repo-only and never deploys to `$HOME`.
- All vendored files are **static** (no `.tmpl`), **LF-only**, plain mode
  (sourced, not executed — no executable bit needed).
- The whole `dot_config/zsh` subtree is **already Windows-ignored** (the
  existing `.chezmoiignore.tmpl` Windows-block line) — no `.chezmoiignore.tmpl`
  change needed; nested subdirs are covered.
- Deploys on **dev and prod** — general shell niceties, not behind the dev gate
  (matches shift-select / cht.sh).

### `chezmoi/dot_zshrc.tmpl` — load order (load-bearing)

A new **"zsh plugins"** block, sourced **after** the existing Shift+Arrow
block, in this exact order:

1. **fzf-tab** — must be sourced *after* `compinit` and *before* any
   widget-wrapping plugin (autosuggestions / syntax-highlighting). Add a small
   set of `zstyle ':fzf-tab:*'` settings: reuse the Catppuccin fzf look, enable
   group switching with `<` / `>`, disable the default sort where it hurts (e.g.
   keep `git` completion order). fzf-tab reads `:completion:*` zstyles at
   completion time, so the existing `list-colors` zstyle (line 105) already
   applies.
2. **zsh-autosuggestions** — sourced after fzf-tab (and after the shift-select
   block, so it can wrap those selection widgets). Set
   `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#6c7086'` (Catppuccin overlay0). Leave
   the default `history` strategy (no atuin dependency — atuin is installed but
   not wired into the rc).
3. **zsh-syntax-highlighting** — **absolute last** of the ZLE-touching code (it
   wraps widgets and must see all previously-defined ones). Define a Catppuccin
   Mocha `ZSH_HIGHLIGHT_STYLES` map before sourcing.

Documented in-file nuance: syntax-highlighting sits **before** the final
`~/.zshrc.local` source, so custom ZLE widgets defined in a local override
won't be auto-highlighted. Acceptable for the normal case; called out in a
comment so the edge case isn't a surprise.

Each `source` is `[[ -r … ]]`-guarded and the block is interactive-only (the rc
already returns early for non-interactive shells at line 7).

### `chezmoi/dot_bashrc.tmpl` — parity notes

Add a PARITY NOTE comment block near the existing completion section noting that
autosuggestions / syntax-highlighting / fzf-tab are zsh-only (ZLE), mirroring
the existing cht.sh and Shift+Arrow asymmetry notes. No functional bash change.

## Files touched

- `chezmoi/dot_config/zsh/plugins/zsh-autosuggestions/` (new, vendored + `.vendor`)
- `chezmoi/dot_config/zsh/plugins/zsh-syntax-highlighting/` (new, vendored + `.vendor`)
- `chezmoi/dot_config/zsh/plugins/fzf-tab/` (new, vendored + `.vendor`)
- `chezmoi/dot_zshrc.tmpl` (new "zsh plugins" block: fzf-tab → autosuggestions →
  syntax-highlighting, themed)
- `chezmoi/dot_bashrc.tmpl` (parity-note comment block)
- `README.html` (+ `docs/README/README.css` / `.js` only if needed) — short
  "Completion & suggestions" addition + TOC entry, following the shift-select
  precedent
- `CLAUDE.md` — "Files Claude should be careful with" entries for the three
  vendored plugin dirs + the load-order note + parity pointer
- `docs/claude/file-care.md` — per-plugin care entries
- `CLAUDE_CHANGELOG.md` — one row

No changes to: `makefile/*` (no new tools), `.chezmoiignore.tmpl` (already
covers `dot_config/zsh`), `scope.mk`, Windows scripts.

## Verification

- `chezmoi diff` on a Linux host shows the new files + rc edits; nothing new on
  Windows.
- `zsh -n ~/.zshrc` — rc parses.
- Fresh interactive login (`zsh -i`): no errors; `echo $ZSH_HIGHLIGHT_VERSION`
  is set; `print ${+functions[_zsh_autosuggest_widget_accept]}` (or an
  `_zsh_autosuggest*` function) exists; `zstyle -L ':fzf-tab:*'` shows the
  fzf-tab config; pressing `Tab` opens the fzf picker.
- Interactive smoke test in a WezTerm pane: type a known command prefix → grey
  suggestion appears, `→` accepts; typo → command colored red; `Tab` on `cd `
  opens the fzf directory picker themed Catppuccin; `<`/`>` switch groups.
- Startup still snappy (`for i in {1..5}; do time zsh -ic exit; done`) — the
  three plugins add only a few ms; `compinit -C` already fast-paths.
- Each vendored file: `file <path>` must **not** say "with CRLF line
  terminators"; `.vendor` sha256 matches the downloaded tarball.
- The existing shift-select behavior (Shift+Arrow select, replace-on-type,
  Alt+W OSC 52 copy) still works — confirms no widget-wrapping regression from
  autosuggestions / syntax-highlighting loading after it.

## Rejected alternatives

- **`zsh-completions`** (the 4th plugin in the user's source snippet): a large
  bundle (hundreds of `_*` functions), mostly redundant now that most tools ship
  their own completions, and impractical to hand-vendor. Excluded by the user's
  "Trio" choice. If wanted later, it is the one piece that genuinely suits a
  `.chezmoiexternal` fetch — add it as its own change.
- **Plugin manager (zinit / antidote / sheldon):** network fetch at startup +
  a major new moving part; against the Make+chezmoi, pinned-and-vendored model.
  (Same reasoning that rejected it for shift-select.)
- **`.chezmoiexternal` fetch for these three:** introduces apply-time network
  and a new version-pin location for plugins that are small enough to vendor.
  Reserved for the bulky `zsh-completions` case only.
- **fast-syntax-highlighting (zdharma-continuum)** instead of
  zsh-syntax-highlighting: faster, but a less-maintained upstream and a more
  complex multi-file theme system; the canonical zsh-syntax-highlighting is the
  lower-risk, better-documented choice.
- **Compiling fzf-tab's C `modules/`:** marginal perf gain, requires a build
  toolchain step at vendor/apply time. The pure-zsh fallback is portable and
  needs no build — consistent with the repo's static-binary bias.
