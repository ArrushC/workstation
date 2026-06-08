# WSL Config Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repo the source of truth for both WSL config files — `/etc/wsl.conf` (deployed by a new `wsl-config` make target) and `%USERPROFILE%\.wslconfig` (deployed by chezmoi) — so a fresh clone reproduces them.

**Architecture:** Two files, two mechanisms dictated by hard repo invariants (Make never runs on Windows; chezmoi owns `$HOME` only). `/etc/wsl.conf` follows the `configs/` → `/etc/` sudo-install pattern (`cockpit-service` shape): tracked at `configs/wsl/wsl.conf`, installed by a `IS_WSL`+`HAS_SUDO`-gated make target with a content-hash stamp. `.wslconfig` is a Windows-gated chezmoi file (`dot_wslconfig`) plus a `run_onchange` PowerShell script that prints the `wsl --shutdown` restart reminder when the file changes.

**Tech Stack:** GNU Make, chezmoi (Go templates, `run_onchange` scripts), INI config files, HTML docs.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `configs/wsl/wsl.conf` | Create | Tracked canonical `/etc/wsl.conf` (verbatim current values) |
| `makefile/Makefile` | Modify | `wsl-config` + `clean-wsl-config` targets; wire into `provision`/`list`/`help` |
| `chezmoi/dot_wslconfig` | Create | Windows-side global WSL2 config (commented template) |
| `chezmoi/.chezmoiignore.tmpl` | Modify | Ignore `.wslconfig` on Linux/macOS (Windows-only deploy) |
| `chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl` | Create | Windows-only restart reminder on `.wslconfig` change |
| `README.html` | Modify | §setup-wsl note-row; troubleshooting cross-ref |
| `CLAUDE.md` | Modify | Extend the `configs/`→`/etc/` invariant |
| `docs/claude/file-care.md` | Modify | Per-file care entries |
| `.claude/memory/project_wsl_appendwindowspath_false.md` | Modify | "NOT repo-tracked" → now repo-deployed |
| `CLAUDE_CHANGELOG.md` | Modify | Append a worked-example entry |

> **Note on running make:** the Makefile recipes reference `../configs/...`, i.e. make runs with CWD = `makefile/`. All verify commands below use `make -C makefile …` so the relative paths resolve correctly.

---

## Task 1: `/etc/wsl.conf` — tracked source + `wsl-config` make target

**Files:**
- Create: `configs/wsl/wsl.conf`
- Modify: `makefile/Makefile` (insert targets after `clean-cockpit-service` at line ~280, before `include packages.mk`; edit `provision`/`list`/`help`)

- [ ] **Step 1: Create the tracked wsl.conf (verbatim current values)**

Create `configs/wsl/wsl.conf` with exactly this content (LF line endings):

```ini
[boot]
systemd=true

[automount]
enabled=true
options="metadata,umask=22,fmask=11"
mountFsTab=true

[network]
generateHosts=true
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false

[user]
default=arrush.chaturvedi
```

- [ ] **Step 2: Verify the file is LF-only and matches the live host file**

Run:
```bash
file configs/wsl/wsl.conf
diff /etc/wsl.conf configs/wsl/wsl.conf && echo "MATCH"
```
Expected: `file` output does NOT contain "CRLF"; `diff` prints `MATCH` (the tracked copy is byte-identical to the live file).

- [ ] **Step 3: Add the `wsl-config` + `clean-wsl-config` targets to the Makefile**

In `makefile/Makefile`, immediately after the `clean-cockpit-service` recipe (the line `@rm -f $(STAMP)/cockpit-service.done`) and before `include packages.mk`, insert:

```makefile

# -----------------------------------------------------------------------------
# wsl-config — install the tracked /etc/wsl.conf on WSL hosts.
#   - Runs only when IS_WSL=true AND HAS_SUDO=true. Writing /etc/ needs root,
#     so a non-WSL host or a sudo-less prod scope skips with a message.
#   - Verbatim copy from configs/wsl/wsl.conf (no templating — values are
#     hardcoded for this single-host setup).
#   - Stamp is content-hashed (WSL_CONF_SHA) so editing the tracked file
#     auto-redeploys; an unchanged re-run is a no-op. wsl.conf has no version,
#     so the content hash is the re-run trigger (cf. version-baked stamps).
#   - Changes only take effect after `wsl --shutdown` from a Windows terminal,
#     so the recipe prints that reminder.
# -----------------------------------------------------------------------------
.PHONY: wsl-config clean-wsl-config
ifeq ($(IS_WSL):$(HAS_SUDO),true:true)
WSL_CONF_SHA := $(shell sha256sum ../configs/wsl/wsl.conf 2>/dev/null | cut -c1-12)
wsl-config: $(STAMP)/wsl-config-$(WSL_CONF_SHA).done
$(STAMP)/wsl-config-$(WSL_CONF_SHA).done:
	@printf '==> wsl-config (/etc/wsl.conf)\n'
	@$(SUDO) install -m 0644 ../configs/wsl/wsl.conf /etc/wsl.conf
	@printf '  installed /etc/wsl.conf — run `wsl --shutdown` from a Windows\n'
	@printf '  terminal for changes to take effect (restarts all WSL distros).\n'
	@mkdir -p $(@D) && touch $@
else
wsl-config:
	@echo "wsl-config: skipping (IS_WSL=$(IS_WSL), HAS_SUDO=$(HAS_SUDO); needs both true)"
endif
clean-wsl-config:
	@$(SUDO) rm -f /etc/wsl.conf
	@rm -f $(STAMP)/wsl-config-*.done
```

- [ ] **Step 4: Wire `wsl-config` into `provision`, `list`, and `help`**

In `makefile/Makefile`, change the base provision line (currently `provision: packages tools user-tools shell dotfiles`) to:

```makefile
provision: packages tools user-tools shell dotfiles wsl-config
```

In the `list:` recipe, after the existing `@printf '\nnerd-fonts (provisioned on MODE=dev only; no-op on WSL)\n'` line, add:

```makefile
	@printf '\nwsl-config (WSL hosts with sudo only; deploys /etc/wsl.conf)\n'
```

In the `help:` recipe, after the `make cockpit-service` line, add:

```makefile
	@echo "  make wsl-config       install tracked /etc/wsl.conf (WSL hosts only)"
```

- [ ] **Step 5: Verify the Makefile parses and the target behaves (dry-run, gating)**

Run from the repo root:
```bash
make -C makefile -n wsl-config MODE=dev
```
Expected (this host is WSL with sudo): prints the `==> wsl-config` banner line and the `install -m 0644 ../configs/wsl/wsl.conf /etc/wsl.conf` command and the reminder `printf`s — without executing them.

Run the gating-off case:
```bash
make -C makefile wsl-config MODE=prod
```
Expected: `wsl-config: skipping (IS_WSL=true, HAS_SUDO=false; needs both true)` (prod scope has no sudo → skip; no `/etc` write attempted).

- [ ] **Step 6: (Manual, interactive) Apply for real and confirm idempotency**

> Requires interactive sudo (the agent has no TTY for the password) — run via `!` in the session.

Run:
```bash
make -C makefile wsl-config MODE=dev
```
Expected: installs `/etc/wsl.conf`, prints the `wsl --shutdown` reminder, writes a `wsl-config-<sha>.done` stamp. Re-running prints nothing new (no-op — stamp present). `diff /etc/wsl.conf configs/wsl/wsl.conf` is empty.

- [ ] **Step 7: Commit**

```bash
git add configs/wsl/wsl.conf makefile/Makefile
git commit -m "feat(wsl): deploy /etc/wsl.conf via IS_WSL-gated wsl-config make target"
```

---

## Task 2: `.wslconfig` — chezmoi source + Windows gating + restart reminder

**Files:**
- Create: `chezmoi/dot_wslconfig`
- Modify: `chezmoi/.chezmoiignore.tmpl` (Linux/macOS ignore block, the `{{ else }}` branch)
- Create: `chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl`

- [ ] **Step 1: Create the commented `.wslconfig` template**

Create `chezmoi/dot_wslconfig` with exactly this content:

```ini
# .wslconfig — global WSL2 settings shared by every distro on this Windows
# host. chezmoi deploys this to %USERPROFILE%\.wslconfig (Windows only).
# Changes take effect only after `wsl --shutdown` from a Windows terminal.
# Reference: https://learn.microsoft.com/windows/wsl/wsl-config
#
# All keys are commented out — deploying this file is a safe no-op until you
# uncomment and tune values for this machine.
[wsl2]
# memory=8GB           # cap VM memory (default: 50% of host RAM)
# processors=4         # cap vCPUs (default: all host cores)
# swap=0               # swap file size; 0 disables swap
# networkingMode=NAT   # 'NAT' (default) or 'mirrored'
# dnsTunneling=true    # improves DNS compatibility on some networks
# firewall=true        # apply Windows Firewall rules to WSL traffic
```

- [ ] **Step 2: Ignore `.wslconfig` on Linux/macOS so it only lands on Windows**

In `chezmoi/.chezmoiignore.tmpl`, inside the `{{ else }}` block (the "On Linux/macOS, ignore Windows-only paths" branch, which currently lists `AppData`, `Documents`, `.config/wezterm`), add after the `Documents` line:

```
# .wslconfig is the Windows host's global WSL2 config; meaningless on Linux.
.wslconfig
```

> Use the TARGET path `.wslconfig` (NOT the source name `dot_wslconfig`) — `.chezmoiignore` matches destination paths; a `dot_*` form is a silent no-op. See CLAUDE.md's target-path tripwire.

- [ ] **Step 3: Verify the Linux ignore takes effect**

Run from the repo root:
```bash
chezmoi ignored | grep -x '.wslconfig'
```
Expected: prints `.wslconfig` (chezmoi will NOT deploy it on this Linux host). An empty result means the pattern is wrong (likely the source-name bug).

- [ ] **Step 4: Create the `run_onchange` restart-reminder script (Windows-only)**

Create `chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl` with exactly this content:

```powershell
{{ if eq .chezmoi.os "windows" -}}
# run_onchange_after_remind-wslconfig-restart.ps1 — prints a reminder to run
# `wsl --shutdown` after .wslconfig changes, since WSL only re-reads the global
# config when the VM restarts. run_onchange semantics: chezmoi diffs the
# rendered script text, so the embedded .wslconfig hash below makes this fire
# only on applies where .wslconfig actually changed.
#
# .tmpl gate: windows only. .chezmoiignore does NOT apply to .chezmoiscripts/,
# so the gate lives in the body; on non-windows hosts the file renders empty
# and chezmoi skips it. ASCII-only output — a chezmoi-rendered temp .ps1 has
# no BOM, and PowerShell 5.1 mis-decodes non-ASCII glyphs without one.
#
# .wslconfig hash: {{ include (joinPath .chezmoi.sourceDir "dot_wslconfig") | sha256sum }}

Write-Host ""
Write-Host ".wslconfig changed -- run 'wsl --shutdown' from a Windows terminal"
Write-Host "for the new WSL2 settings to take effect (restarts all distros)."
{{- end }}
```

- [ ] **Step 5: Verify the script renders empty on Linux (so chezmoi skips it)**

Run from the repo root:
```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl | tr -d '[:space:]' | wc -c
```
Expected: `0` — on this Linux host the `{{ if eq .chezmoi.os "windows" }}` gate is false, so the body (and the `include` of `dot_wslconfig`) is skipped and the script renders to whitespace only. chezmoi skips zero-byte scripts.

- [ ] **Step 6: Commit**

```bash
git add chezmoi/dot_wslconfig chezmoi/.chezmoiignore.tmpl chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl
git commit -m "feat(wsl): track global .wslconfig via chezmoi with run_onchange restart reminder"
```

---

## Task 3: Documentation, memory, and changelog

**Files:**
- Modify: `README.html`, `CLAUDE.md`, `docs/claude/file-care.md`, `.claude/memory/project_wsl_appendwindowspath_false.md`, `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Add a README §setup-wsl note-row**

In `README.html`, in the §setup-wsl section, immediately after the "Truecolor signaling" note-row (the `<p class="note-row">` that ends with `<code>echo $TERM</code> in a new pane (prints <code>wezterm</code>).` followed by `</p>`, around line 2212), insert:

```html
                    <p class="note-row">
                        <strong>WSL config is tracked &amp; deployed.</strong>
                        Two files configure WSL, and the repo owns both.
                        <code>/etc/wsl.conf</code> (per-distro: systemd,
                        automount, interop, default user) is deployed on WSL
                        hosts by <code>make wsl-config</code> &mdash; part of
                        <code>make dev</code> / <code>provision</code>, gated to
                        WSL hosts with sudo, from the tracked
                        <code>configs/wsl/wsl.conf</code>. The global
                        <code>%USERPROFILE%\.wslconfig</code> (WSL2 VM memory /
                        CPU / networking, all distros) is deployed by chezmoi on
                        the Windows host from <code>chezmoi/dot_wslconfig</code>.
                        <strong>Both need <code>wsl --shutdown</code></strong>
                        from a Windows terminal to take effect;
                        <code>wsl-config</code> prints the reminder, and a
                        chezmoi <code>run_onchange</code> script prints it on
                        Windows when <code>.wslconfig</code> changes.
                    </p>
```

- [ ] **Step 2: Cross-reference the new target in the "chezmoi feels slow on WSL" troubleshooting entry**

In `README.html`, in the troubleshooting entry whose Fix list's first `<li>` currently reads "Set `appendWindowsPath=false` … in `/etc/wsl.conf`, then `wsl --shutdown` …" (around lines 3611–3619), replace that `<li>`…`</li>` with:

```html
                                <li>
                                    Set
                                    <code>appendWindowsPath=false</code> under
                                    <code>[interop]</code> in
                                    <code>/etc/wsl.conf</code> &mdash; now
                                    deployed for you by
                                    <code>make wsl-config</code> (tracked at
                                    <code>configs/wsl/wsl.conf</code>) &mdash;
                                    then <code>wsl --shutdown</code> from a
                                    <em>Windows</em> terminal (ends all WSL
                                    sessions) and reopen.
                                </li>
```

- [ ] **Step 3: Verify the README still parses (well-formed, no broken tags)**

Run from the repo root:
```bash
python3 -c "import html.parser,sys
class P(html.parser.HTMLParser):
    pass
P().feed(open('README.html').read()); print('PARSED OK')"
grep -c 'make wsl-config' README.html
```
Expected: `PARSED OK`; the grep count is `>= 2` (note-row + troubleshooting reference).

- [ ] **Step 4: Extend the `configs/`→`/etc/` invariant in CLAUDE.md**

In `CLAUDE.md`, under "Load-bearing invariants", replace the bullet:

> - **`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed** — deployed by paired `<tool>-service` make targets (`dozzle-service`, `cockpit-service`). Chezmoi owns `$HOME` only.

with:

```markdown
- **`configs/` is sudo-installed to `/etc/`, NOT chezmoi-managed** — deployed by paired make targets (`dozzle-service`, `cockpit-service`, and `wsl-config` for `/etc/wsl.conf`). Chezmoi owns `$HOME` only. `wsl-config` is gated on `IS_WSL`+`HAS_SUDO` (no-op off WSL / on sudo-less prod), content-hash stamped (no version to bake), and prints a `wsl --shutdown` reminder; it joins the base `provision` line. The Windows-side global `%USERPROFILE%\.wslconfig` is the chezmoi counterpart (`chezmoi/dot_wslconfig`, Windows-gated as a TARGET path in `.chezmoiignore.tmpl`, plus a `run_onchange` restart reminder script). Together they make WSL config reproducible — and `wsl-config` now auto-applies the `appendWindowsPath=false` flip that `project_wsl_appendwindowspath_false.md` previously called a manual per-host step.
```

- [ ] **Step 5: Add per-file care entries to `docs/claude/file-care.md`**

Read `docs/claude/file-care.md` first to see its section structure. Then:
- Add `configs/wsl/wsl.conf` to the **LF-only** risk-category list (it's a Linux `/etc` file; CRLF would corrupt the deployed config) — alongside the existing `configs/*` mentions.
- Add an entry stating: the **live `/etc/wsl.conf` is overwritten** by `make wsl-config` (don't hand-edit it; edit `configs/wsl/wsl.conf` and re-run — same "don't hand-edit the deployed copy" rule as other `configs/*` → `/etc/` files), and `chezmoi/dot_wslconfig` deploys to `%USERPROFILE%\.wslconfig` **Windows-only** with an initial commented-template body (editing it triggers the `run_onchange` restart reminder).

- [ ] **Step 6: Correct the `appendWindowsPath` memory ("NOT repo-tracked" is now false)**

In `.claude/memory/project_wsl_appendwindowspath_false.md`, replace list item 1 under "The adopted fix":

> 1. **Host-global:** `appendWindowsPath=false` under `[interop]` in `/etc/wsl.conf`, then `wsl --shutdown` from a Windows terminal so the distro re-reads it. NOT repo-tracked (chezmoi owns `$HOME` only; `/etc/wsl.conf` is outside scope). Needs sudo — run via `!` in the session, since the agent has no TTY for the sudo password.

with:

```markdown
1. **Host-global:** `appendWindowsPath=false` under `[interop]` in `/etc/wsl.conf`, then `wsl --shutdown` from a Windows terminal so the distro re-reads it. **Now repo-deployed** via `make wsl-config` (tracked at `configs/wsl/wsl.conf`; sudo-installed to `/etc/wsl.conf`, `IS_WSL`+`HAS_SUDO`-gated, joins the base `provision`) — a fresh WSL host gets the flip from the repo instead of by hand, though `wsl --shutdown` is still required afterward. Manual sudo runs need `!` in the session (agent has no TTY for the password).
```

Also update the "How to apply" bullet that reads "Other WSL hosts each need their own `wsl.conf` flip + restart; the tracked rc re-add reaches them via `czu`/`cza` but is a no-op until they flip." — change "need their own `wsl.conf` flip" to "get the `wsl.conf` flip from `make wsl-config` (via `make dev`/provision), then need a `wsl --shutdown`; the tracked rc re-add is a no-op until the restart".

- [ ] **Step 7: Append a `CLAUDE_CHANGELOG.md` entry**

Read the most recent entry in `CLAUDE_CHANGELOG.md` to match its format exactly, then append a new entry covering this change. Content to convey:
- **What:** Repo now tracks + deploys both WSL config files. `configs/wsl/wsl.conf` → `/etc/wsl.conf` via the `IS_WSL`+`HAS_SUDO`-gated `wsl-config` make target (content-hash stamp, `wsl --shutdown` reminder, joins `provision`). `chezmoi/dot_wslconfig` → `%USERPROFILE%\.wslconfig` (Windows-gated, commented template) with a `run_onchange` restart-reminder script.
- **Why it mattered:** WSL config was hand-managed/unversioned; the `appendWindowsPath=false` perf fix needed a manual per-host flip. `wsl-config` now applies it from the repo.
- **README updates required:** §setup-wsl note-row + the "chezmoi feels slow on WSL" troubleshooting cross-ref.

- [ ] **Step 8: Verify and commit**

Run:
```bash
file configs/wsl/wsl.conf            # must NOT say CRLF (re-check after all edits)
chezmoi ignored | grep -x '.wslconfig'   # still prints .wslconfig
```
Expected: no CRLF; `.wslconfig` listed.

```bash
git add README.html CLAUDE.md docs/claude/file-care.md .claude/memory/project_wsl_appendwindowspath_false.md CLAUDE_CHANGELOG.md
git commit -m "docs(wsl): document WSL config tracking + correct appendWindowsPath memory"
```

---

## Final verification (whole feature)

- [ ] `make -C makefile -n wsl-config MODE=dev` shows the install + reminder (WSL+sudo host).
- [ ] `make -C makefile wsl-config MODE=prod` prints the skip message (no `/etc` write).
- [ ] `diff /etc/wsl.conf configs/wsl/wsl.conf` is empty after a real apply.
- [ ] `chezmoi ignored` lists `.wslconfig` on Linux; (Windows-native check, when available, does NOT list it).
- [ ] `chezmoi execute-template < …remind-wslconfig-restart.ps1.tmpl` renders empty on Linux.
- [ ] `file configs/wsl/wsl.conf` shows no CRLF.
- [ ] `grep -c 'make wsl-config' README.html` ≥ 2; README parses.
- [ ] CLAUDE.md, file-care.md, the memory, and CLAUDE_CHANGELOG.md all updated in the docs commit.
