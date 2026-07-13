# Repo-script flag completion: zsh + bash (Linux) and Nushell (Windows)

**Date:** 2026-07-13
**Scope:** three new zsh completion files under `chezmoi/dot_config/zsh/completions/`, one new bash file `chezmoi/dot_config/bash/completions.bash` + a source line in `chezmoi/dot_bashrc.tmpl`, an external-completer block in `chezmoi/AppData/Roaming/nushell/config.nu.tmpl`, a new flag-parity check in `scripts/check-invariants.sh`, docs (`README.html`, `CLAUDE.md`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`).
**Status:** Design — pending user review.

## Goal

Typing `-`/`--` + Tab after any flag-bearing repo script completes its flags,
in every shell the repo manages:

- **Linux zsh + bash:** `bootstrap.sh`, `scripts/manage-hosts.sh`,
  `scripts/update-hosts.sh`
- **Windows Nushell:** `bootstrap.ps1`, `scripts/manage-hosts.ps1`
  (today: "NO RECORDS FOUND" — nu has no completion source for externals)
- **Windows PowerShell:** already completes `param()` blocks natively — no
  work, just a README mention so it's discoverable.

**User decisions (2026-07-13):** scope = "everything with flags" — surveyed to
exactly the five scripts above (`setup-ccstatusline.sh`, `bump-versions.sh`,
`install-nerd-fonts.ps1` take no flags — excluded); approach A — static
hand-written completions + a mechanical drift check in `check-invariants.sh`
(over generated completions [more machinery than data] and carapace [new
runtime dependency on every host]).

## Flag surfaces (verified 2026-07-13 — the data being completed)

- **`bootstrap.sh`:** `--dev`, `--prod`, `--reinstall`, `--yes`/`-y`,
  `--doctor`, `--check-for-updates`, `--help`/`-h`. Mutual exclusions:
  `--dev`↔`--prod`, `--doctor`↔`--check-for-updates`. NOT completed: the
  removed-flag `--full` fail arm and the `--checkforupdates` compatibility
  alias (both accepted-but-not-advertised; the invariant check must therefore
  compare completions ⊆ script flags with an explicit allowlist for these two,
  or strip them — exact mechanism is plan detail, but the two names must not
  appear in completions).
- **`bootstrap.ps1`** (12): `-RepoPath <string>`, `-SkipKeyGen`,
  `-SkipToolInstall`, `-SkipChezmoi`, `-SkipBurntToast`, `-SkipNerdFonts`,
  `-ForceInstaller`, `-SkipElevated`, `-Reinstall`, `-Yes`, `-Doctor`,
  `-CheckForUpdates`.
- **`scripts/manage-hosts.sh`:** actions `--sync`, `--list`, `--format`,
  `--add`, `--remove`, `--copy-id`; option flags `--name <v>`, `--ip <v>`,
  `--user <v>`, `--group <v>`, `--skip-confirm`, `--all`. Completed as a flat
  union (context-aware per-action completion is YAGNI).
- **`scripts/manage-hosts.ps1`** (12): `-Sync`, `-List`, `-Add`, `-Remove`,
  `-CopyId`, `-All`, `-Name <string>`, `-Ip <string>`, `-User <string>`,
  `-Group <string>`, `-SkipConfirm`, `-Format`.
- **`scripts/update-hosts.sh`:** `--group <v>`, `--name <v>`, `--check`,
  `--parallel <n>`, `--help`/`-h`. `--group` values complete to the only two
  valid groups, `dev_machine` / `prod_machine` (same enum in the zsh file for
  manage-hosts' `--group`).

## Design

### 1. Zsh completions (Linux) — three first-party files

`chezmoi/dot_config/zsh/completions/{_bootstrap.sh,_manage-hosts.sh,_update-hosts.sh}`
→ deploy to `~/.config/zsh/completions/` (dir already on `fpath` before
`compinit` in `dot_zshrc.tmpl:115` — zero wiring changes). Each file:
`#compdef <script-basename>` + an `_arguments` spec with per-flag descriptions
lifted from the script's usage text. zsh's completion dispatch strips
directory prefixes, so `./bootstrap.sh` and `./scripts/manage-hosts.sh` match
their basename compdefs (same mechanism `_cht.sh` relies on). Encoded
exclusions in `_bootstrap.sh`: `(--prod)--dev`, `(--dev)--prod`,
`(--check-for-updates)--doctor`, `(--doctor)--check-for-updates`. `--group`
completes `(dev_machine prod_machine)`. Completions flow through fzf-tab
automatically (it wraps all of compsys).

These are FIRST-PARTY files (unlike the vendored `_cht.sh` neighbor): no
`.vendor` sidecar, normal review/edit rules, LF + 0644 (chezmoi source name
without `executable_`). They are zsh syntax — NOT part of the
shellcheck/shfmt bash set (same exclusion as the zsh plugin files).

### 2. Bash completions (Linux) — one new tracked file + source line

New `chezmoi/dot_config/bash/completions.bash` → `~/.config/bash/completions.bash`
(first file in that dir; chezmoi creates it). Sourced from `dot_bashrc.tmpl`
immediately after the existing `/etc/bash_completion` block (~line 110), with
the standard PARITY NOTE comments on both sides (zsh files ↔ bash file).
Content: one `_workstation_complete_<script>` function per script using
`compgen -W "<flag words>"` against the current word (bash shows no
descriptions — accepted), plus `--group` value completion for
manage-hosts/update-hosts. Registered for the invocation forms bash matches
literally: `complete -F <fn> <basename> ./<basename> scripts/<basename>
./scripts/<basename>` (bash keys on the exact command word — no basename
fallback like zsh).

First-party bash → automatically joins the `check-invariants.sh`
shellcheck/shfmt/LF set (it globs first-party shell files; confirm the glob
picks up the new path at plan time — if the set is an explicit list, add it).
Mode 0644 (sourced, not executed) — NOT in the 100755 set.

### 3. Nushell external completer (Windows) — `config.nu.tmpl`

Append a completion block to
`chezmoi/AppData/Roaming/nushell/config.nu.tmpl` (Windows-only deploy —
already covered by the blanket AppData Linux-ignore):

```
$env.config.completions.external = {
  enable: true
  completer: {|spans|
    let cmd = ($spans | first | path basename | str downcase)
    let word = ($spans | last)
    let flags = if $cmd == "bootstrap.ps1" {
      [ {value: "-RepoPath", description: "alternate clone path"}, ... ]
    } else if $cmd == "manage-hosts.ps1" {
      [ {value: "-Sync", description: "regenerate wezterm hosts block"}, ... ]
    } else { null }
    if $flags == null { null } else {
      $flags | where {|f| $f.value | str downcase | str starts-with ($word | str downcase) }
    }
  }
}
```

(Illustrative — exact nu syntax pinned at plan time against nu 0.113.1 docs.)
Matching on `path basename` means `.\bootstrap.ps1`, absolute paths, and
`scripts\manage-hosts.ps1` all complete; every other external returns `null`
→ nu's default file completion (unchanged behavior elsewhere). Records carry
descriptions (nu's menu shows them). Nushell is pre-1.0: the completer block
joins the existing "re-check `config.nu` on every nu pin bump" discipline
(CLAUDE.md nushell bullet — the external-completer API is a churn surface).

### 4. Drift enforcement — new `check-invariants.sh` check

New check "script flags == completion flags", five pairs:

| Script (source of truth) | Completion surfaces checked |
|---|---|
| `bootstrap.sh` case arms | `_bootstrap.sh`, `completions.bash` |
| `scripts/manage-hosts.sh` case arms | `_manage-hosts.sh`, `completions.bash` |
| `scripts/update-hosts.sh` case arms | `_update-hosts.sh`, `completions.bash` |
| `bootstrap.ps1` `param()` | `config.nu.tmpl` records |
| `scripts/manage-hosts.ps1` `param()` | `config.nu.tmpl` records |

Extraction: bash side — `--flag)` case-arm patterns (including combined
`-h | --help)` arms); PS side — `param()` block `[switch]$X`/`[string]$X`
names rendered as `-X`. Set-compare both directions (a completion offering a
dead flag fails too), with the deliberate exclusions from the flag-surface
section (`--full`, `--checkforupdates`) handled explicitly. Failure output
names the script, the missing/extra flags, and both files to fix — same style
as the version-pin checks. Runs in pre-commit and CI (`lint.yml`) like every
other invariant. Per the repo rule, this lands because it is a new
mechanically-checkable dual-edit shape.

No edit-time parity-reminder hook extension — the invariant check suffices
(YAGNI; revisit only if drift keeps reaching commit time).

### 5. Docs (same PR)

- **`README.html`:** §daily — short "tab completion" note (Linux: flags for
  `bootstrap.sh`/`manage-hosts.sh`/`update-hosts.sh` complete in zsh and
  bash); §setup-windows — one line (Nushell completes
  `bootstrap.ps1`/`manage-hosts.ps1` flags; classic PowerShell does this
  natively).
- **`CLAUDE.md`:** the flag-parity check joins the mechanical-enforcement
  paragraph's enumeration; the zsh-completions/`completions.bash`/`config.nu`
  files get their dual-edit relationship named in the version-pin/parity
  bullet list (shape: "script flag surface ↔ its completion files").
- **`docs/claude/file-care.md`:** entries for the new files (first-party vs
  the vendored `_cht.sh` distinction in the completions dir; completions.bash
  is sourced-not-executed 0644 bash).
- **`CLAUDE_CHANGELOG.md`:** one row.

### 6. Verification

- **bash:** non-interactive behavior test — source `completions.bash`, set
  `COMP_WORDS`/`COMP_CWORD`, invoke the function, assert `COMPREPLY` contains
  the expected flags (exact commands in the plan; runs on this host).
- **zsh:** `zsh -n` syntax check on each `_*` file + the rendered-template
  pipeline; live Tab behavior manually confirmed on this host (zsh is the
  login shell).
- **nu:** `check-templates.sh` renders `config.nu.tmpl` and nu-syntax-checks
  the output (soft-skips locally if `nu` absent; the `lint.yml` templates job
  enforces in CI). Live completion behavior = PR test plan on the Windows
  host (nu isn't installed on this Linux host).
- **invariant check:** prove RED (temporarily remove a flag word → check
  fails naming it) then GREEN — TDD-style evidence in the plan.
- `make -C makefile lint MODE=prod` green end-to-end; `bash
  .claude/hooks/test-hooks.sh` unchanged-green.

## Out of scope (deliberate)

- Completions for no-flag scripts (`setup-ccstatusline.sh`,
  `bump-versions.sh`, `install-nerd-fonts.ps1`) and make targets (`make`
  completion is the shell's own).
- Context-aware per-action completion for `manage-hosts.sh` (flat union only).
- carapace or any external completion engine; fish/other shells.
- PowerShell profile completers (native `param()` completion already covers
  both `.ps1` scripts).
- Completing hostnames from `hosts.conf` for `--name` (nice later; not now).
- A generated-completions pipeline (approach B — rejected as more machinery
  than data).
