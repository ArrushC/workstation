# mise Dotfiles (PR3: `$HOME` on mise dotfiles, chezmoi deleted) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every file chezmoi deploys to `$HOME` on Linux and Windows is declared in a `[dotfiles]` table and applied by `mise bootstrap`, the 19 Go templates become Tera templates, the 5 lifecycle scripts become `tasks/bootstrap` steps (or a `bootstrap.ps1` step), and `chezmoi/`, `.chezmoiroot`, the chezmoi tool and every reference to it are deleted — with all eleven hosts still landing the same `$HOME` they have today.

**Architecture:** The repo root is mise's global config dir (PR1). Sources move from `chezmoi/` to `dotfiles/` under their real names; each target is one `[dotfiles]` entry keyed by target path, declared in the config file whose `MISE_ENV` token gates it (`config.linux.toml` Linux, `config.windows.toml` Windows, `config.dev.toml` dev-only, `config.local.toml` per-host). Mode per file class: `template` for the 12 converted templates, `copy` for anything an app rewrites in place, `symlink-each` + `exclude` for directories carrying `.vendor`/`.gitkeep` sidecars, `symlink` for the rest. Procedural work moves to the `bootstrap` task; `post-dotfiles` restores the `~/.ssh` and `~/.claude` modes. `bootstrap.ps1` drops chezmoi and calls `mise bootstrap --only dotfiles,tools`.

**Tech Stack:** mise 2026.9.9 (`[dotfiles]`, Tera v2, `mise dot apply|status|add --changed`, `[bootstrap.hooks]`), bash, PowerShell 5.1/7, jq, Tera, python tomllib via `wpy` / `python3` ≥3.11 in CI.

**Spec:** `docs/superpowers/specs/2026-09-16-mise-everything-design.md` — sections 1, 3, 4, 8 and the PR3 row of section 10 are binding, EXCEPT where the "Rulings" block below records a verified-fact deviation.

## Rulings (verified against mise 2026.9.9 on 2026-09-19; binding for this plan)

1. **The first apply on every existing host needs `--force-dotfiles`.** `symlink`/`symlink-each` refuse a pre-existing real file, and every target is one today (chezmoi copies). Even `--dry-run` exits 1 without the flag. `bootstrap.sh` passes it ONLY while the migration marker `~/.local/state/workstation/dotfiles-migrated` is absent, so a later conflict is still surfaced loudly instead of silently reclaimed.
2. **There is no `state = "absent"` key.** Disabling an inherited entry needs `enabled = false` AND a repeated `mode` in the overriding file — `enabled = false` alone is silently ignored. This is how the per-host ccstatusline opt-out works.
3. **One broken template aborts the whole apply.** An undefined Tera variable or a failing `exec()` in any single entry fails the entire `mise dot apply` and writes nothing at all. Therefore: every converted template is applied and diffed INDIVIDUALLY in Task 1 before any bulk run, `scripts/check-templates.sh` renders every one of them in CI, and no template may reference a var without an `is defined` guard or a `default()`.
4. **Hostname, kernel and git identity have no native Tera functions** — they are `exec(command="hostname")`, `exec(command="uname -r")`, `exec(command="git config --get user.name")`. A failing `exec()` aborts everything (ruling 3), so every `exec()` used in a template must be a command that cannot fail on a bare host, or be wrapped with a fallback.
5. **`~/.claude/settings.json` is not a dotfiles entry at all.** mise has no `modify_`-template equivalent; the three-layer merge becomes `scripts/lib/claude-settings-merge.sh` (jq) run from `tasks/bootstrap`, dev-gated. `settings.local.json` also stays out of `[dotfiles]` (Claude Code rewrites it).
6. **No `run_onchange_*` equivalent exists.** The `.wslconfig` "run `wsl --shutdown`" reminder moves into `bootstrap.ps1` as a sha256 compare against a stored marker, which is what it already does for other files.
7. **Windows entries are `copy`, never `symlink`.** File symlinks need Developer Mode and silently fall back to copying; `symlink-each` always copies on Windows; directory symlinks become junctions. Declaring `copy` makes the behaviour identical everywhere and is what `mise dot add --changed` round-trips.
8. **Symlinked dotfiles live inside the git checkout**, so editing one dirties the repo and `update-hosts.sh`'s `git pull --ff-only` then fails. Accepted (it is the spec's model and makes edits instant), mitigated by: a `tasks/health` row for a dirty checkout, a CLAUDE.md tripwire, and a README §daily note. The 12 templated targets render to independent files and are NOT affected.
9. **age/encryption is dropped**, not ported: zero `encrypted_*` files exist, no `key.txt` on any host, and the block renders empty today. `bootstrap.sh`'s `check_age_identity` and the `WORKSTATION_AGE_RECIPIENT` plumbing go with it.
10. **The dev-gate asymmetry is fixed by construction.** chezmoi's ignore block lists only Linux-form paths, so a Windows prod host would deploy `~/.claude` ungated. In mise, dev-only entries live in `config.dev.toml` and are gated by the `dev` token on both OSes.

## Global Constraints

- mise pin stays **2026.9.9** (`bootstrap.sh`, `bootstrap.ps1`, `min_version`).
- `MISE_ENV` token sets are unchanged: prod `linux`; dev WSL `linux,dev,host,wsl`; dev native `linux,dev,host,native`; Windows `windows,dev`.
- Every `[dotfiles]` entry is keyed by TARGET path (`"~/.zshrc"`), with `source` relative to the repo root. Entries live in the file whose token gates them: cross-platform in `config.toml`, Linux in `config.linux.toml`, Windows in `config.windows.toml` (new), dev-only in `config.dev.toml`, per-host overrides in `config.local.toml`.
- Mode per class, no exceptions without a comment saying why: `template` (converted templates) · `copy` (app-rewritten files, every Windows entry) · `symlink-each` + `exclude = [".vendor", ".gitkeep"]` (directories with sidecars) · `symlink` (everything else).
- Modes are preserved by `copy`/`template` from the source file's own bits, so `dotfiles/ssh/config.tera` is committed 0600 and the `~/.ssh`/`~/.claude` directory modes are restored by the `post-dotfiles` hook (`chmod 700 ~/.ssh ~/.claude; chmod 600 ~/.ssh/config`).
- Every `.tera` template must render for BOTH dev and prod var sets and for the Windows set where it applies; `scripts/check-templates.sh` is rewritten to prove exactly that and stays a CI job.
- `dotfiles/**` files keep their git modes (0755 for the `executable_*` originals, 0600 for ssh config, 0644 otherwise); `scripts/**/*.sh` and `tasks/*` stay LF + 0755 + `shfmt -i 2` + shellcheck-clean; `.ps1` files keep their UTF-8 BOM.
- No `--no-verify`; `scripts/check-invariants.sh` green at every commit; README.html + `CLAUDE_CHANGELOG.md` updated in Task 7.
- Never run `sudo`, `./bootstrap.sh --dev|--prod`, or a bulk `mise dot apply` against the real `$HOME` from a subagent. Scratch-`$HOME` applies are the test vehicle (a fake `$HOME` is the only isolation that works — `MISE_CONFIG_DIR` does not redirect the dotfiles or task lookup).
- Branch: `feat/mise-dotfiles` off `main` (7707f99 or later). Commit after every task, push after every commit, draft PR after Task 1.

---

## File map

| Path | Task | Responsibility |
|---|---|---|
| `dotfiles/**` (git mv from `chezmoi/**`, renamed) | 1 | every source file under its real name |
| `dotfiles/**/*.tera` (12 conversions) | 1 | the Go templates as Tera |
| `config.toml`, `config.linux.toml`, `config.dev.toml`, `config.windows.toml` (new) | 2 | `[dotfiles]` entries + `[bootstrap.hooks] post-dotfiles` |
| `tasks/bootstrap`, `scripts/lib/claude-settings-merge.sh` (new), `dotfiles/claude/settings.{seed,enforced}.json` (new), `scripts/setup-ccstatusline.sh` | 3 | the 4 Linux lifecycle steps, the settings merge, the per-host opt-out |
| `bootstrap.sh`, `scripts/update-hosts.sh`, `tasks/migrate-legacy`, `tasks/health` | 4 | `config.local.toml` prompts, `--force-dotfiles` gating, the chezmoi sweep, the dirty-checkout row |
| `bootstrap.ps1` | 5 | `mise bootstrap --only dotfiles,tools`, chezmoi removed, `.wslconfig` reminder |
| `scripts/check-templates.sh`, `scripts/check-invariants.sh`, `.claude/hooks/*`, `chezmoi/dot_config/zsh/completions/*` → `dotfiles/...`, `.github/workflows/lint.yml` | 6 | render checks, invariants, hooks, `ws*` aliases + completions |
| `README.html`, `CLAUDE.md`, `docs/claude/*`, `CLAUDE_CHANGELOG.md`, `.claude/memory/*` | 7 | docs |
| `chezmoi/`, `.chezmoiroot` (delete), `config.linux.toml` (`chezmoi` tool), `mise.linux.lock` | 4 | chezmoi retired |
| (no files) | 8 | on-host verification + rollout hand-off |

---

### Task 1: `dotfiles/` tree + the 12 Tera conversions, each proven individually

**Files:** `git mv chezmoi/** dotfiles/**` with real names; convert 12 templates to `.tera`; delete the 5 `.chezmoiscripts/` (their logic lands in Task 3), `.chezmoiignore.tmpl`, `.chezmoi.toml.tmpl` (Task 4 replaces them).

**Interfaces:**
- Produces: the `dotfiles/` paths every `[dotfiles]` entry in Task 2 points at; the Tera var contract (`vars.name`, `vars.email`, `vars.project_root` optional).
- Consumes: nothing.

- [ ] **Step 1: Branch + source move.** `git checkout -b feat/mise-dotfiles` off main. `git mv` each source path to its real name: `chezmoi/dot_zshrc.tmpl` → `dotfiles/zshrc.tera`, `chezmoi/private_dot_ssh/private_config.tmpl` → `dotfiles/ssh/config.tera`, `chezmoi/dot_config/zellij/` → `dotfiles/config/zellij/`, `chezmoi/AppData/...` → `dotfiles/windows/AppData/...`, `chezmoi/private_dot_claude/` → `dotfiles/claude/`, `chezmoi/dot_local/bin/executable_batpipe` → `dotfiles/local/bin/batpipe` (keep 0755), and so on for all 95 source files. Use the inventory table (`§1` of the PR3 inventory, regenerate with `chezmoi managed` if needed) as the checklist; every `dot_`/`private_`/`executable_` prefix disappears. `git mv` (not copy+delete) so history follows.
- [ ] **Step 2: Convert the 12 templates** (the other 7 of the 19 are `.chezmoiscripts/`, `.chezmoiignore.tmpl`, `.chezmoi.toml.tmpl` and `modify_private_settings.json`, none of which become dotfiles templates). Conversion table, all verified:

| chezmoi | Tera |
|---|---|
| `{{ .chezmoi.os }}` | `{{ os() }}` |
| `{{ .chezmoi.hostname }}` | `{{ exec(command="hostname") }}` |
| `{{ .chezmoi.username }}` | `{{ env.USER }}` |
| `{{ .chezmoi.homeDir }}` | `{{ env.HOME }}` |
| `contains "microsoft" (lower .chezmoi.kernel.osrelease)` | `{{ "microsoft" in (exec(command="uname -r") \| lower) }}` |
| `hasKey . "group"` / `eq .group "dev_machine"` | `"dev" in mise_env` (guard with `mise_env is defined`) |
| `{{ .name }}` / `{{ .email }}` | `{{ vars.name }}` / `{{ vars.email }}` |
| `eq .chezmoi.hostname "rhel-dev-01"` | `vars.project_root is defined` (the stale host branch becomes a var) |
| literal `{{` | `{{ "{{" }}` inline, or a `{% raw %}…{% endraw %}` block |
| `${SHELL_VAR}` | unchanged — Tera only reads `{{`, `{%`, `{#` |

  The 12: `zshenv.tera`, `zshrc.tera`, `bashrc.tera`, `gitconfig.tera`, `ssh/config.tera`, `gdbinit.tera`, `config/cheat/conf.yml.tera`, `config/environment.d/10-mise.conf.tera`, `windows/AppData/Roaming/nushell/config.nu.tera`, `windows/AppData/Roaming/helix/config.toml.tera`, `windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera`, and `dotfiles/config/zed/settings.json` only if it carries template syntax (check; if not, it is a plain `copy` entry).
  The Windows helix template is `{{ include "dot_config/helix/config.toml" }}` today → `{{ read_file(path="dotfiles/config/helix/config.toml") }}` (path resolves from the config root).
- [ ] **Step 3: Guard every variable.** Ruling 3 means one unguarded reference breaks every dotfile. For each `.tera`, ensure each `vars.*` is either guaranteed (Task 4 writes `name`/`email` into `config.local.toml` before the first apply) or written as `{{ vars.x | default(value="…") }}` / wrapped in `{% if vars.x is defined %}`. Grep the converted set for `vars\.` and list each with its guard in the report.
- [ ] **Step 4: Prove each template individually** in a scratch `$HOME` (never the real one):

```bash
S=/tmp/pr3; rm -rf $S; mkdir -p $S/home/.config/mise
cp -a config.toml $S/home/.config/mise/          # plus a [vars] block with name/email/group
ln -s "$PWD/dotfiles" $S/home/.config/mise/dotfiles
# one [dotfiles] entry per template, then, for EACH target separately:
HOME=$S/home mise dot apply '~/.zshrc'
```

  For each: render for the dev var set and the prod var set, and diff against `chezmoi execute-template` output for the same inputs (chezmoi is still installed this task). Byte-identical is the bar; record every intentional difference. A failure here is a conversion bug, not a config bug.
- [ ] **Step 5: Commit + draft PR.** `feat(dotfiles): sources move to dotfiles/ under real names; 12 Go templates become Tera`. Open the draft PR (`PR 3 of 3` title, body from the plan Goal + "Draft until Task 8 on-host verification").

---

### Task 2: `[dotfiles]` declarations, the `post-dotfiles` hook, `config.windows.toml`

**Files:** `config.toml`, `config.linux.toml`, `config.dev.toml`, `config.windows.toml` (new); `scripts/check-invariants.sh` (a `check_dotfiles_config`).

**Interfaces:**
- Consumes: every `dotfiles/` path from Task 1.
- Produces: the entry set Task 4's `bootstrap.sh` applies and Task 6's checks assert.

- [ ] **Step 1: Entry shape.** One entry per target, keyed by target path:

```toml
[dotfiles]
"~/.zshrc" = { source = "dotfiles/zshrc.tera", mode = "template" }
"~/.config/zsh/plugins/fzf-tab" = { source = "dotfiles/config/zsh/plugins/fzf-tab", mode = "symlink-each", exclude = [".vendor", ".gitkeep"] }
"~/.config/starship.toml" = { source = "dotfiles/config/starship.toml", mode = "symlink" }
"~/.config/zed/settings.json" = { source = "dotfiles/config/zed/settings.json", mode = "copy" }   # Zed rewrites it in place
```

  Placement: cross-platform (gitconfig, ssh config, helix config) in `config.toml`; Linux-only in `config.linux.toml`; dev-only (`~/.claude` tree, ccstatusline, zed, herdr, gdb/gef) in `config.dev.toml`; Windows in `config.windows.toml` (new file, `windows` token, every entry `mode = "copy"` per ruling 7).
- [ ] **Step 2: Mode assignment.** `copy` for: Warp `settings.toml`, Windows Terminal `settings.json`, Zed `settings.json`/`keymap.json` (both OSes), VS Code `settings.json`/`keybindings.json`, and every `config.windows.toml` entry. `symlink-each` + exclude for: the 5 zsh plugin dirs, `dotfiles/config/gdb/`, `dotfiles/local/bin/`, `~/.claude/agents`, `~/.claude/commands`. `template` for the 12. `symlink` for the rest. Every `copy` entry carries a one-line comment naming the app that rewrites it.
- [ ] **Step 3: `post-dotfiles` hook** in `config.linux.toml` (verified to fire, compound command works):

```toml
[bootstrap.hooks]
"post-dotfiles" = "chmod 700 ~/.ssh ~/.claude 2>/dev/null; chmod 600 ~/.ssh/config 2>/dev/null; true"
```

  Hook names are unique per file (Task 2 of PR2 established the rule and `check_bootstrap_config` enforces it) — `config.linux.toml` already owns `post-tools`, so add `post-dotfiles` to the same table there.
- [ ] **Step 4: Scratch-HOME full apply.** With a fake `$HOME`, `mise bootstrap --only dotfiles --force-dotfiles --yes` for each of the four `MISE_ENV` sets (`linux`; `linux,dev,host,wsl`; `linux,dev,host,native`; `windows,dev` — the last one renders Windows entries on Linux, which is fine for a render check). For each: the target tree matches what `chezmoi managed` lists for that host class, the modes are right (`stat -c '%a'` on `~/.ssh` = 700, `~/.ssh/config` = 600, `~/.claude` = 700), and `mise dot status` reports everything applied. Record the file counts per env set.
- [ ] **Step 5: `check_dotfiles_config`** in `scripts/check-invariants.sh` (tomllib): every entry's `source` exists; every `mode` is one of the five; every Windows entry is `copy`; every `symlink-each` entry that has a `.vendor`/`.gitkeep` in its source declares the matching `exclude`; no entry appears in two config files; every `.tera` source is referenced by exactly one entry and every `.tera` file in `dotfiles/` is referenced (no orphans). Show it failing on a scratch copy for two of those.
- [ ] **Step 6: Commit** `feat(dotfiles): declare every target, post-dotfiles modes hook, config.windows.toml`.

---

### Task 3: the lifecycle steps — bootstrap task, Claude settings merge, ccstatusline opt-out

**Files:** `tasks/bootstrap`, `scripts/lib/claude-settings-merge.sh` (new), `dotfiles/claude/settings.seed.json` + `settings.enforced.json` (new), `scripts/setup-ccstatusline.sh`.

- [ ] **Step 1: Four Linux steps into `tasks/bootstrap`**, each marker-guarded under `~/.local/state/workstation/` and soft-failing (the task must never abort the bootstrap): `nb` notebook init at `~/notes` (marker `nb-notebook`), Claude plugin marketplace + the 8 plugins (dev only, marker `claude-plugins`), herdr plugin at its pinned ref (dev only, marker `herdr-plugins` including the ref so a bump re-fires), tldr cache seed (marker `tldr-cache`). Port each body verbatim from the corresponding `.chezmoiscripts/` file before Task 1 deleted it (`git show` it).
- [ ] **Step 2: `scripts/lib/claude-settings-merge.sh`** — the three-layer merge `modify_private_settings.json` does today, in jq: read `~/.claude/settings.json` if present, start from `dotfiles/claude/settings.seed.json` for keys that are absent, then force every key in `dotfiles/claude/settings.enforced.json` to win, write back atomically at mode 0600. Split today's template into those two JSON files verbatim (seed: `model`, `effortLevel`, `theme`, `editorMode`, `tui`, `verbose`; enforced: `statusLine`, `hooks`, `enabledPlugins`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`, `remoteControlAtStartup`, `agentPushNotifEnabled`, `inputNeededNotifEnabled` — confirm against the file). Called from `tasks/bootstrap`, dev only. Test it offline with three fixtures (absent file, file with user changes to a seed key, file with a hand-changed enforced key) and assert the outcomes.
- [ ] **Step 3: ccstatusline per-host opt-out.** `scripts/setup-ccstatusline.sh`'s sentinel block in `.chezmoiignore.tmpl` has no equivalent; per ruling 2 it writes into `config.local.toml`:

```toml
[dotfiles]
"~/.config/ccstatusline/settings.json" = { source = "dotfiles/config/ccstatusline/settings.json", mode = "copy", enabled = false }
```

  Rewrite the script's block-writing logic accordingly (it must be idempotent and removable), keeping its existing menu and its `mise run statusline` entry point.
- [ ] **Step 4: Verify.** `mise run bootstrap` is NOT run against the real host here; instead run each new step's body in a scratch `$HOME` with its marker absent then present, and run the merge script's three fixtures. `bash scripts/check-invariants.sh` green.
- [ ] **Step 5: Commit** `feat(dotfiles): lifecycle steps into the bootstrap task; Claude settings merged by jq`.

---

### Task 4: `bootstrap.sh` — `config.local.toml`, the forced first apply, the chezmoi sweep

**Files:** `bootstrap.sh`, `scripts/update-hosts.sh`, `tasks/migrate-legacy`, `tasks/health`, `config.linux.toml` (drop the `chezmoi` tool), `mise.linux.lock`; delete `chezmoi/`, `.chezmoiroot`.

- [ ] **Step 1: `config.local.toml` on first run.** Replace `ensure_chezmoi_initialized` with a function that, when `config.local.toml` is absent, prompts for name and email via `/dev/tty` (the `</dev/tty` redirect is load-bearing under `curl | bash`; reuse the FD-open guard PR2 added) and writes:

```toml
# config.local.toml — per-host, git-ignored.
[vars]
name = "…"
email = "…"
```

  Migration: when `~/.config/chezmoi/chezmoi.toml` exists, read `name`/`email` out of it instead of prompting. Keep `config.local.toml` in `.gitignore` (already there) and never commit it.
- [ ] **Step 2: The forced first apply.** In `run_bootstrap()`, pass `--force-dotfiles` to `mise bootstrap` only while `~/.local/state/workstation/dotfiles-migrated` is absent, then write that marker after a successful run (ruling 1). Print one line saying why when it is used.
- [ ] **Step 3: The chezmoi sweep** in `tasks/migrate-legacy` (a third marker-guarded block, `legacy-chezmoi-swept`, using its own array name): remove `~/.config/chezmoi/chezmoistate.boltdb`, `~/.config/chezmoi/chezmoi.toml`, and the `~/.local/share/chezmoi` directory ONLY if it is empty or contains nothing but a `.git`-less leftover (never delete a non-empty directory — on this WSL host it holds unrelated `.remember` data, which must survive); keep `~/.config/chezmoi/key.txt` if it exists. The chezmoi binary itself goes when its `[tools]` entry is dropped (`mise prune` removes it).
- [ ] **Step 4: Drop chezmoi the tool.** Remove `chezmoi = "latest"` from `config.linux.toml` `[tools]` and its `mise.linux.lock` entry (relock with the documented `mise lock --global` XDG-symlink form + `normalize_lock_sidecars`, or hand-edit only if the lock format makes that safe — state which you did). Also drop `chezit` if it is only useful with chezmoi (check its purpose first and say so).
- [ ] **Step 5: Delete `chezmoi/` and `.chezmoiroot`**, and sweep every remaining reference outside them (324 lines at the start of this PR: `bootstrap.sh` 80, `bootstrap.ps1` 104 — Task 5 — `scripts/` 76, hooks 37, tasks 24, workflows 2, `config.linux.toml` 1). `grep -rn -i chezmoi --exclude-dir=.git .` must return only: `docs/superpowers/**`, `CLAUDE_CHANGELOG.md`, `.claude/memory/*` history, and explicitly past-tense migration sentences. `check_age_identity` and the `WORKSTATION_AGE_RECIPIENT` plumbing go too (ruling 9).
- [ ] **Step 6: `tasks/health`** — replace the chezmoi drift row with two rows: `mise dot status` reports no drift, and the repo checkout is clean (`git -C "$root" status --porcelain` empty → ok; non-empty → warn naming `update-hosts.sh`'s `--ff-only` hazard, ruling 8).
- [ ] **Step 7: Verify.** `bash -n`, `shfmt -d -i 2`, shellcheck, `bash scripts/check-invariants.sh`, `bash .claude/hooks/test-hooks.sh`, `./bootstrap.sh --help`, `./bootstrap.sh --doctor --dev` (read-only; reports the new rows). Do NOT run a real bootstrap.
- [ ] **Step 8: Commit** `feat(dotfiles): bootstrap.sh applies mise dotfiles; chezmoi deleted`.

---

### Task 5: `bootstrap.ps1` — Windows on `mise bootstrap`

**Files:** `bootstrap.ps1` (UTF-8 BOM, PowerShell 5.1-compatible, `${var}:` braces in double-quoted strings).

- [ ] **Step 1: Replace `Invoke-Chezmoi`** with a step that runs `mise bootstrap --only dotfiles,tools --yes` (plus `--force-dotfiles` while a `dotfiles-migrated` marker under `%LOCALAPPDATA%\workstation` is absent), after `$MiseEnv` is set and mise is on PATH. `--only dotfiles,tools` is verified to skip `[bootstrap.files]`, so no `/etc`-shaped entry can fire on Windows.
- [ ] **Step 2: Remove chezmoi** from `$PortableTools` and every helper that installs, invokes or reports it (104 referencing lines — the installer, the doctor rows, the `-CheckForUpdates` row, the comments). `Invoke-MiseRuntimes` stays but now runs as part of the same bootstrap call unless it still has a distinct job — say which you found.
- [ ] **Step 3: The `.wslconfig` reminder** (ruling 6): compare the sha256 of `dotfiles/wslconfig` against a marker under `%LOCALAPPDATA%\workstation`; when it changes, print the `wsl --shutdown` reminder and update the marker. Port the message text from the deleted `run_onchange_after_remind-wslconfig-restart.ps1.tmpl` (`git show` it).
- [ ] **Step 4: `config.local.toml` on Windows** — the same name/email prompt as Task 4, reading from `~/.config/chezmoi/chezmoi.toml` when migrating; skip prompting under `-SkipToolInstall`/non-interactive runs and warn instead.
- [ ] **Step 5: Verify** (no Windows host available to the implementer): `git diff` review, BOM intact, `check_ps_variable_drive_refs` green, `scripts/check-ps.ps1` runs in CI (the `powershell` job), `check_completion_parity` green (the flag set must not change), and `scripts/test-curl.ps1`'s parse check still passes in CI. The real run is Task 8, by the user.
- [ ] **Step 6: Commit** `feat(dotfiles): Windows bootstraps via mise; chezmoi removed from bootstrap.ps1`.

---

### Task 6: render checks, invariants, hooks, `ws*` aliases

**Files:** `scripts/check-templates.sh` (rewrite), `scripts/check-invariants.sh`, `.claude/hooks/{post-edit-guard,parity-reminder,sync-tool-memory,session-context,session-end-notify,test-hooks}.sh`, `dotfiles/config/zsh/completions/*`, `dotfiles/config/bash/completions.bash`, `dotfiles/windows/AppData/Roaming/nushell/config.nu.tera`, `dotfiles/windows/Documents/PowerShell/*.tera`, `dotfiles/config/cheat/cheatsheets/personal/workstation`, `.github/workflows/lint.yml`.

- [ ] **Step 1: `check-templates.sh` rewrite.** For each `MISE_ENV` set, apply every `[dotfiles]` entry into a throwaway `$HOME` (`mise bootstrap --only dotfiles --force-dotfiles --yes`) and syntax-check the rendered output with today's checkers (zsh `-n`, bash `-n`, `git config --file`, `nu --commands`, `pwsh -NoProfile -Command`, `yq`, python `tomllib`, `jq`). Because one bad template aborts everything (ruling 3), also apply each `.tera` target individually first and report which one failed if the bulk run fails.
- [ ] **Step 2: Invariants.** Delete `check_chezmoiignore_targets` and the chezmoi halves of `check_version_pins`, `check_line_endings_and_mode`, `check_sentinels`, `check_tools_block`, `check_lsp_plugin`, `check_completion_parity`, `check_warp_guards`, `check_zellij_config`, `check_shellcheck`, `check_shfmt` — each keeps its non-chezmoi half, repointed at `dotfiles/`. Keep `check_dotfiles_config` from Task 2. The `MISE_ENV` three-way check (zshenv ↔ bashrc ↔ environment.d) must now compare the three `.tera` sources.
- [ ] **Step 3: Hooks.** `post-edit-guard.sh` globs `dotfiles/**` for the LF/mode/BOM set; `parity-reminder.sh` pairs become `dotfiles/zshrc.tera` ↔ `dotfiles/bashrc.tera`, and the nushell ↔ PowerShell alias pair; `sync-tool-memory.sh` unchanged (TOML-driven already); `session-context.sh` and `session-end-notify.sh` replace their chezmoi probes with `mise dot status`; `test-hooks.sh` fixtures follow. Run it — all assertions pass.
- [ ] **Step 4: `cz*` → `ws*` aliases** in all four shells (zsh, bash, nushell, PowerShell): `wsa` = `mise bootstrap --only dotfiles --yes`, `wsd` = `mise dot diff`, `wss` = `mise dot status`, `wse` = edit the source, `wsr` = `mise dot add --changed`, `wsu` = `mise run update`, `wsh` = a help function. Update the zsh/bash completions, the nushell `workstation_*_flags` records, and the cheat sheet. `check_completion_parity` must stay green.
- [ ] **Step 5: CI.** `lint.yml`'s `templates` job drops the chezmoi install and runs the new `check-templates.sh`; add a Windows leg only if the render needs a real `pwsh` (it exists on the `windows-http` runner — decide and say why).
- [ ] **Step 6: Verify + commit** `feat(dotfiles): render checks, invariants and hooks off chezmoi; ws* aliases`.

---

### Task 7: Documentation

**Files:** `README.html`, `CLAUDE.md`, `docs/claude/{invariants,file-care,verification}.md`, `CLAUDE_CHANGELOG.md`, `.claude/memory/project-mise-everything.md` + `MEMORY.md`.

- [ ] **Step 1: README.html** — §layout (`dotfiles/`, no `chezmoi/`), §setup-linux/§setup-windows (no chezmoi install, no `chezmoi init`), §daily (the `ws*` workflow replaces `cz*`; how to edit a dotfile, when `wsr` is needed for copy-mode files, that symlinked files live in the repo and dirty it), §adding (adding a dotfile = one `[dotfiles]` entry + the source file), §troubleshooting (new entries: a template error aborts every dotfile and how to find the culprit; `refusing to overwrite existing files` and when `--force-dotfiles` is right; a GUI-rewritten file needing `wsr`; a dirty checkout blocking `update-hosts`). Keep `node scripts/check-readme.mjs` green and every hard-coded count in sync.
- [ ] **Step 2: CLAUDE.md + docs/claude** — replace every chezmoi invariant with the dotfiles equivalents: entry shape and mode-per-class, the four gating files, ruling 3 (one bad template kills the apply), ruling 1 (`--force-dotfiles` only on migration), ruling 2 (`enabled = false` needs `mode`), ruling 7 (Windows is copy), ruling 8 (symlinks dirty the checkout), the `post-dotfiles` chmod, the Claude settings merge, `wsr` for copy-mode round-trips. `file-care.md` per-file entries repoint at `dotfiles/`. `verification.md` recipes become `mise dot status|diff`, the scratch-`$HOME` apply, and `scripts/check-templates.sh`.
- [ ] **Step 3: Changelog row + memory** (PR3 done, the ten rulings, the migration complete — Make and chezmoi both gone).
- [ ] **Step 4: Verify + commit** `docs: mise dotfiles replace chezmoi`.

---

### Task 8: On-host verification and rollout (controller + user)

- [ ] **Step 1 (controller, read-only):** `check-invariants.sh`, `check-templates.sh`, `test-hooks.sh`, `check-readme.mjs`, `mise tasks validate`, and a scratch-`$HOME` apply for all four env sets compared against the pre-migration `chezmoi managed` list (no target lost).
- [ ] **Step 2 (user, this WSL host):** `cd ~/.config/mise && git checkout feat/mise-dotfiles && git pull && ./bootstrap.sh --dev`. Expect the forced first dotfiles apply, then `mise dot status` clean, `mise run health` 0, a working `exec zsh` (prompt, plugins, aliases, `MISE_ENV`), `~/.ssh` 700 / `~/.ssh/config` 600 / `~/.claude` 700, `~/.claude/settings.json` carrying the enforced keys, and `git status` clean.
- [ ] **Step 3 (user, Windows):** `cd ~\.config\mise; git checkout feat/mise-dotfiles; git pull; .\bootstrap.ps1`. Expect chezmoi gone, dotfiles applied by mise, Warp/WT/nushell/PowerShell files present, and `wsr` round-tripping a UI edit.
- [ ] **Step 4 (user, one native dev host + one prod host)** once reachable — this is also where PR2's native path gets its first run.
- [ ] **Step 5:** mark the PR ready, merge, roll the fleet, delete the SDD workspace.

---

## Self-review notes

- Spec coverage: §8's mapping (modes, the 19→12 templates, the 7 scripts, settings.json, ccstatusline opt-out, `ws*` aliases, age dropped, the CI render check) is covered by Tasks 1–3, 6, 7; §3's layout by Task 1; §4's env gating by Task 2; §9's bootstrap/CI/invariants by Tasks 4–6; §10's PR3 migration row by Task 4 (`--force-dotfiles`, the sweep) and Task 5 (Windows).
- Consistency: `dotfiles/` paths in Task 1 are what Task 2's entries reference and Task 6's checks assert; the marker names (`dotfiles-migrated`, `legacy-chezmoi-swept`, `nb-notebook`, `claude-plugins`, `herdr-plugins`, `tldr-cache`) are used identically in Tasks 3, 4 and 5.
- Placeholders: none — each step names its files and its verification. The one deliberate unknown is whether `dotfiles/config/zed/settings.json` carries template syntax (Task 1 Step 2 says to check and decide), and whether `chezit` survives (Task 4 Step 4).
