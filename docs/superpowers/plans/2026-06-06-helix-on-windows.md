# Helix on Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Helix on the Windows client via the bootstrap (admin-free portable, like WezTerm/Starship), bump Helix to 25.07.1 on both OSes, make `hx` the cross-OS editor (replacing the `zed --wait` fallback), and deploy the helix config to Windows.

**Architecture:** Add a Helix entry to `bootstrap.ps1`'s `$PortableTools` (`tree` layout → `%LOCALAPPDATA%\workstation\helix`, `hx.exe` auto-finds adjacent `runtime/`, no `HELIX_RUNTIME` env var on Windows). Bump `HELIX_VERSION` in `versions.mk` (Linux). Revert `[core] editor` / chezmoi `[edit] command` to `hx`. Deploy the helix config to `%APPDATA%\helix\config.toml` via a one-line `{{ include }}` of the existing Linux config (single source of truth). The merge tool stays Zed on Windows (Helix can't 3-way merge).

**Tech Stack:** PowerShell 5.1 (UTF-8 **with BOM**), chezmoi Go templates, Make. No `pwsh` on the authoring host — Windows verification is structural here + a manual checklist on the host; chezmoi renders + the Linux helix install ARE verifiable here.

**Spec:** `docs/superpowers/specs/2026-06-06-helix-on-windows-design.md`

**Pins (already sourced — real values, no placeholders):**
- Helix **25.07.1** Windows zip: `https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip`
- sha256: `5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6`
- Layout: single top folder `helix-25.07.1-x86_64-windows/` → `hx.exe` + `runtime/` (verified)
- Linux asset `helix-25.07.1-x86_64-linux.tar.xz` → `helix-25.07.1-x86_64-linux/{hx,runtime/}` (matches `helix.sh`; no sha pin)

---

## Task 1: Bump Helix to 25.07.1 (Linux versions.mk + Windows bootstrap.ps1 install)

**Files:**
- Modify: `makefile/versions.mk:26`
- Modify: `bootstrap.ps1` (constants ~line 118, `$PortableTools` ~line 145, header ~line 12, dir-precreate ~line 426, closing message ~line 682)

- [ ] **Step 1: Bump the Linux pin in `makefile/versions.mk`**

Replace:
```
HELIX_VERSION    := 24.03
```
with:
```
HELIX_VERSION    := 25.07.1
```
(`makefile/lib/helix.sh` needs no change — it builds `helix-${version}-x86_64-linux.tar.xz` and finds the `helix-*/` dir; the 25.07.1 asset name + layout are unchanged and it pins no sha256.)

- [ ] **Step 2: Add the `$WsHelix` path constant in `bootstrap.ps1`**

Find (around line 116–119):
```powershell
$WsRoot    = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin     = Join-Path $WsRoot "bin"
$WsWezterm = Join-Path $WsRoot "wezterm"
$WsStamps  = Join-Path $WsRoot "stamps"
```
Replace with (insert the `$WsHelix` line after `$WsWezterm`):
```powershell
$WsRoot    = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin     = Join-Path $WsRoot "bin"
$WsWezterm = Join-Path $WsRoot "wezterm"
$WsHelix   = Join-Path $WsRoot "helix"
$WsStamps  = Join-Path $WsRoot "stamps"
```

- [ ] **Step 3: Add the Helix entry to `$PortableTools`**

Find the end of the WezTerm entry (the `}` closing the WezTerm hashtable and the `)` closing the array, around line 145–146):
```powershell
        Sha256  = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
        Layout  = "tree"
        Dest    = $WsWezterm
    }
)
```
Replace with (add the Helix hashtable before the closing `)`):
```powershell
        Sha256  = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
        Layout  = "tree"
        Dest    = $WsWezterm
    },
    @{
        Name    = "Helix"
        Exe     = "hx"
        Version = "25.07.1"
        Url     = "https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip"
        Sha256  = "5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6"
        Layout  = "tree"
        Dest    = $WsHelix
    }
)
```
(No `Install-PortableTool` change — the `tree` branch already flattens the single top-level folder so `hx.exe` + `runtime/` land in `$WsHelix`, sha256-verifies, stamps, and `Add-ToUserPath $WsHelix`. `hx.exe` finds `./runtime` adjacent, so no `HELIX_RUNTIME` is set on Windows.)

- [ ] **Step 4: Update the install-model header comment**

Find (around line 11–12):
```
#   - Starship  — pinned portable .zip (sha256-verified)    → workstation\bin
#   - WezTerm   — pinned portable .zip (sha256-verified)    → workstation\wezterm
```
Replace with:
```
#   - Starship  — pinned portable .zip (sha256-verified)    → workstation\bin
#   - WezTerm   — pinned portable .zip (sha256-verified)    → workstation\wezterm
#   - Helix     — pinned portable .zip (sha256-verified)    → workstation\helix
#                 (hx.exe + bundled runtime/; no HELIX_RUNTIME env var needed)
```

- [ ] **Step 5: Pre-create `$WsHelix` in `Invoke-ToolInstall`**

Find (around line 426):
```powershell
    foreach ($d in @($WsRoot, $WsBin, $WsStamps)) {
```
Replace with:
```powershell
    foreach ($d in @($WsRoot, $WsBin, $WsHelix, $WsStamps)) {
```

- [ ] **Step 6: Mention `workstation\helix` in the closing PATH note**

Find (around line 682–683):
```powershell
Write-Host "Open a NEW PowerShell tab so the updated User PATH (${Bold}$WsBin${Reset} +"
Write-Host "${Bold}$WsWezterm${Reset}) and the chezmoi-applied `$PROFILE pick up — starship"
```
Replace with:
```powershell
Write-Host "Open a NEW PowerShell tab so the updated User PATH (${Bold}$WsBin${Reset}, ${Bold}$WsWezterm${Reset},"
Write-Host "${Bold}$WsHelix${Reset}) and the chezmoi-applied `$PROFILE pick up — starship"
```

- [ ] **Step 7: Verify (structural — these are the "tests")**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- versions.mk bumped ---"; grep -n 'HELIX_VERSION' makefile/versions.mk
echo "--- bootstrap.ps1 has Helix entry + $WsHelix ---"; grep -nE '\$WsHelix|Name    = "Helix"|helix-25.07.1-x86_64-windows.zip|5c8325ced8' bootstrap.ps1
echo "--- BOM intact, no CRLF ---"; file bootstrap.ps1
echo "--- braces/parens balanced ---"; python3 - <<'EOF'
s=open("bootstrap.ps1").read()
for a,b,n in [("{","}","braces"),("(",")","parens")]:
    print(n, s.count(a), s.count(b), "OK" if s.count(a)==s.count(b) else "MISMATCH")
EOF
echo "--- no unfilled PIN markers ---"; grep -n 'PIN-ME-' bootstrap.ps1 && echo "HAS PLACEHOLDER" || echo "OK no placeholder"
```
Expected: `HELIX_VERSION := 25.07.1`; the Helix grep shows `$WsHelix`, the Name/url/sha hits; `file` says "UTF-8 Unicode (with BOM) text" (NOT CRLF); braces + parens balanced; `OK no placeholder`.

- [ ] **Step 8: If the BOM was lost (Edit shouldn't drop it, but verify), restore it:**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
file bootstrap.ps1 | grep -q 'with BOM' || python3 -c "p='bootstrap.ps1';b=open(p,'rb').read();bom=b'\xef\xbb\xbf';open(p,'wb').write(b if b.startswith(bom) else bom+b)"
file bootstrap.ps1
```

- [ ] **Step 9: Commit**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add makefile/versions.mk bootstrap.ps1
git commit -m "feat(helix): install Helix on Windows + bump both OSes to 25.07.1

bootstrap.ps1 \$PortableTools gains a Helix entry (tree layout -> workstation\\helix,
pinned 25.07.1 + sha256); hx.exe finds its bundled runtime adjacent (no HELIX_RUNTIME
on Windows). versions.mk HELIX_VERSION 24.03 -> 25.07.1 (helix.sh unchanged)."
```

---

## Task 2: Revert the editor to `hx` (keep merge on Zed)

**Files:**
- Modify: `chezmoi/dot_gitconfig.tmpl:6-10`
- Modify: `chezmoi/.chezmoi.toml.tmpl:15-21`

- [ ] **Step 1: Revert `[core] editor` in `dot_gitconfig.tmpl`**

Replace:
```
[core]
    # hx (helix) is the Linux editor; it isn't installed on Windows, so fall
    # back to Zed there. `zed --wait` blocks until the buffer is closed, which
    # git requires to read the commit message / rebase todo.
    editor     = {{ if eq .chezmoi.os "windows" }}zed --wait{{ else }}hx{{ end }}
    autocrlf   = input
```
with:
```
[core]
    editor     = hx
    autocrlf   = input
```
(`hx` is now on PATH on both OSes via the Task 1 install, so the editor is unconditional. The `pager` conditional below it is unchanged.)

- [ ] **Step 2: Revert `[edit] command` in `.chezmoi.toml.tmpl`**

Replace:
```
[edit]
    # hx isn't on Windows — use Zed there (--wait so chezmoi blocks until the
    # buffer is closed). Linux keeps helix.
    command = "{{ if eq .chezmoi.os "windows" }}zed{{ else }}hx{{ end }}"
{{- if eq .chezmoi.os "windows" }}
    args    = ["--wait"]
{{- end }}
```
with:
```
[edit]
    command = "hx"
```
(Leave the `[diff]` and `[merge]` sections untouched — `[merge]` keeps `vimdiff` on Linux / `zed` on Windows; `[diff]` keeps the empty-pager-on-Windows.)

- [ ] **Step 3: Verify Linux renders + merge untouched**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- gitconfig editor (Linux render, expect 'editor     = hx', no conditional) ---"
chezmoi cat ~/.gitconfig 2>&1 | grep -nE 'editor|^\s*command'
echo "--- gitconfig template has no zed (expect none) ---"
grep -n 'zed' chezmoi/dot_gitconfig.tmpl || echo "OK no zed in gitconfig"
echo "--- chezmoi.toml [edit]=hx, [merge] still conditional zed/vimdiff ---"
chezmoi execute-template --init --promptString 'name=T' --promptString 'email=t@x' --promptString 'group=dev_machine' < chezmoi/.chezmoi.toml.tmpl 2>&1 | sed -n '/^\[edit\]/,/^\[git\]/p'
```
Expected: `editor     = hx` (no `{{ if }}`); `OK no zed in gitconfig`; the rendered `[edit]` shows `command = "hx"` (no args), `[merge]` shows `command = "vimdiff"` + `args = ["{{ .Destination }}", ...]` (Linux branch), `[diff]` shows `pager = "delta"`.

- [ ] **Step 4: Commit**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/dot_gitconfig.tmpl chezmoi/.chezmoi.toml.tmpl
git commit -m "fix(git/chezmoi): editor back to hx now that Helix installs on Windows

[core] editor and chezmoi [edit] command revert to unconditional hx (hx is on
PATH on both OSes via the bootstrap install). [merge] stays vimdiff/zed — Helix
has no 3-way merge."
```

---

## Task 3: Deploy the helix config to Windows (%APPDATA%\helix)

**Files:**
- Create: `chezmoi/AppData/Roaming/helix/config.toml.tmpl`

- [ ] **Step 1: Create the Windows helix config that includes the Linux one**

Create `chezmoi/AppData/Roaming/helix/config.toml.tmpl` with EXACTLY this single line (plus trailing newline):
```
{{ include "dot_config/helix/config.toml" }}
```
This renders the existing `chezmoi/dot_config/helix/config.toml` content into `%APPDATA%\helix\config.toml` on Windows. `AppData` is already ignored on Linux (so it's Windows-only); `.config/helix` stays ignored on Windows. Single source of truth — no duplicate.

- [ ] **Step 2: Verify the include resolves and renders the real config**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- file created ---"; cat chezmoi/AppData/Roaming/helix/config.toml.tmpl
echo "--- render the include (expect the catppuccin config body) ---"
chezmoi execute-template < chezmoi/AppData/Roaming/helix/config.toml.tmpl 2>&1 | grep -nE 'catppuccin_mocha|line-number|C-s' 
echo "--- on Linux this target is ignored (AppData), confirm chezmoi ignored still lists AppData ---"
chezmoi ignored 2>&1 | grep -x 'AppData' && echo "OK AppData ignored on Linux"
```
Expected: the file contains the one include line; the render shows `theme = "catppuccin_mocha"`, `line-number`, `C-s` (i.e. the Linux config content); `AppData` appears in `chezmoi ignored` on Linux (so this file won't deploy to the Linux home).

- [ ] **Step 3: Commit**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add chezmoi/AppData/Roaming/helix/config.toml.tmpl
git commit -m "feat(helix): deploy helix config to %APPDATA%\\helix on Windows

New chezmoi/AppData/Roaming/helix/config.toml.tmpl includes the existing Linux
dot_config/helix/config.toml (single source of truth). Windows-only via the
AppData Linux-ignore; .config/helix stays ignored on Windows."
```

---

## Task 4: Update `README.html` (§setup-windows)

**Files:**
- Modify: `README.html` (install list ~1889, install paragraph ~1899, flow diagram ~1956)

- [ ] **Step 1: Add Helix to the install `<ul>`**

Find (the Starship `<li>` closing the list, around line 1885–1890):
```html
                        <li>
                            <strong>Starship</strong> &mdash; pinned,
                            sha256-verified portable <code>.zip</code> into
                            <code>%LOCALAPPDATA%\workstation\bin</code>.
                        </li>
                    </ul>
```
Replace with:
```html
                        <li>
                            <strong>Starship</strong> &mdash; pinned,
                            sha256-verified portable <code>.zip</code> into
                            <code>%LOCALAPPDATA%\workstation\bin</code>.
                        </li>
                        <li>
                            <strong>Helix</strong> (<code>hx</code>) &mdash;
                            pinned, sha256-verified portable <code>.zip</code>
                            into <code>%LOCALAPPDATA%\workstation\helix</code>
                            (binary + bundled runtime). The git/chezmoi editor.
                        </li>
                    </ul>
```

- [ ] **Step 2: Update the pins sentence to include Helix + note the config target**

Find (around line 1899–1903):
```html
                        WezTerm/Starship versions are pinned in
                        <code>bootstrap.ps1</code> (<code>$PortableTools</code>),
                        the same self-contained pattern as
                        <code>install-nerd-fonts.ps1</code>.
                    </p>
```
Replace with:
```html
                        WezTerm/Starship/Helix versions are pinned in
                        <code>bootstrap.ps1</code> (<code>$PortableTools</code>),
                        the same self-contained pattern as
                        <code>install-nerd-fonts.ps1</code>; the Helix pin tracks
                        <code>HELIX_VERSION</code> in <code>makefile/versions.mk</code>.
                        Your helix config deploys to
                        <code>%APPDATA%\helix\config.toml</code> on Windows
                        (Helix&rsquo;s Windows config dir).
                    </p>
```

- [ ] **Step 3: Add Helix to the flow-diagram step 2 label**

Find (around line 1956):
```html
                            ><span class="lbl">Install chezmoi + WezTerm + Starship</span
```
Replace with:
```html
                            ><span class="lbl">Install chezmoi + WezTerm + Starship + Helix</span
```

- [ ] **Step 4: Verify**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- Helix in install list + flow + pins note ---"
grep -nE 'workstation\\helix|Starship \+ Helix|%APPDATA%\\helix|WezTerm/Starship/Helix' README.html
echo "--- <li>/<ul> balance sanity ---"
for t in li ul; do echo "$t: open=$(grep -oE "<$t[ >]" README.html | wc -l) close=$(grep -oE "</$t>" README.html | wc -l)"; done
```
Expected: the Helix install `<li>`, the flow label, the `%APPDATA%\helix` note, and the `WezTerm/Starship/Helix` pins line all match; li/ul tag counts balanced.

- [ ] **Step 5: Commit**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html
git commit -m "docs(readme): add Helix to the Windows install list + flow + config note"
```

---

## Task 5: Update Claude-internal docs (CLAUDE.md, file-care.md, changelog)

**Files:**
- Modify: `CLAUDE.md:69` (Windows-installs invariant) + the Helix-runtime bullet
- Modify: `docs/claude/file-care.md:34` (bootstrap.ps1 pinned-tools entry)
- Modify: `CLAUDE_CHANGELOG.md` (append a row)

- [ ] **Step 1: Extend the CLAUDE.md Windows-installs invariant (line 69)**

Replace:
```
- **Windows tool installs are admin-free binary/portable downloads under `%LOCALAPPDATA%\workstation`** (no Chocolatey). `bootstrap.ps1` installs chezmoi via the official `get.chezmoi.io` binary installer (→ `workstation\bin`) and WezTerm + Starship via pinned, sha256-verified portable `.zip`s (→ `workstation\wezterm` / `workstation\bin`), all added to the User PATH. **WezTerm/Starship pins (version + sha256) live in `bootstrap.ps1`'s `$PortableTools`, NOT `versions.mk`** (Make never runs on Windows — same precedent as `install-nerd-fonts.ps1`); WezTerm's pin tracks the vendored-terminfo tag. **Git is a hard prerequisite** the user installs (preflight hard-fails if absent); Zed/VSCode soft-warn; zoxide is not installed. No elevation anywhere.
```
with:
```
- **Windows tool installs are admin-free binary/portable downloads under `%LOCALAPPDATA%\workstation`** (no Chocolatey). `bootstrap.ps1` installs chezmoi via the official `get.chezmoi.io` binary installer (→ `workstation\bin`) and WezTerm + Starship + Helix via pinned, sha256-verified portable `.zip`s (→ `workstation\wezterm` / `workstation\bin` / `workstation\helix`), all added to the User PATH. **WezTerm/Starship/Helix pins (version + sha256) live in `bootstrap.ps1`'s `$PortableTools`, NOT `versions.mk`** (Make never runs on Windows — same precedent as `install-nerd-fonts.ps1`); WezTerm's pin tracks the vendored-terminfo tag, and the **Helix pin is a dual-edit with `HELIX_VERSION` in `versions.mk`** (Linux + Windows bumped together). The Windows Helix runtime is the portable `runtime/` bundled next to `hx.exe` — **no `HELIX_RUNTIME` env var on Windows** (distinct from the Linux dev-runtime bullet). **Git is a hard prerequisite** the user installs (preflight hard-fails if absent); Zed/VSCode soft-warn; zoxide is not installed. No elevation anywhere.
```

- [ ] **Step 2: Add a Windows note to the Helix-runtime bullet in CLAUDE.md**

Find the bullet that begins:
```
- **Helix dev runtime needs `HELIX_RUNTIME` exported from the rc**
```
Append to the END of that bullet (before its trailing period/newline) the sentence:
```
 (Windows is the exception: the portable install bundles `runtime/` next to `hx.exe`, so Windows needs no `HELIX_RUNTIME` — see the Windows-installs invariant.)
```
If the exact bullet wording differs, locate it by the `HELIX_RUNTIME` anchor and append the same sentence.

- [ ] **Step 3: Extend the file-care.md bootstrap.ps1 entry (line 34)**

In `docs/claude/file-care.md`, find the substring:
```
in its `$PortableTools` manifest (WezTerm + Starship) — the same self-contained pin pattern
```
and replace `(WezTerm + Starship)` with:
```
(WezTerm + Starship + Helix; Helix is a `tree`-layout install of `hx.exe` + its bundled `runtime/`, and its pin is a dual-edit with `HELIX_VERSION` in `makefile/versions.mk`) — the same self-contained pin pattern
```
Then find the substring:
```
chezmoi is the exception — installed via the official `get.chezmoi.io` binary installer (self-verifying, latest), not pinned.
```
and append after it:
```
 The Windows helix config is deployed to `%APPDATA%\helix\config.toml` by `chezmoi/AppData/Roaming/helix/config.toml.tmpl`, a one-line `{{ include "dot_config/helix/config.toml" }}` (single source of truth — NOT a duplicate; edit the Linux `dot_config/helix/config.toml` and it flows to Windows on apply).
```

- [ ] **Step 4: Append the changelog row** (LAST line of `CLAUDE_CHANGELOG.md`):
```
| Installed Helix on the Windows client and made `hx` the cross-OS editor (replacing the prior `zed --wait` fallback), bumping Helix `24.03` → `25.07.1` on BOTH OSes. `bootstrap.ps1` `$PortableTools` gains a Helix entry (`tree` layout → `%LOCALAPPDATA%\workstation\helix`, pinned `25.07.1` + sha256 `5c8325ce…`); the zip is `hx.exe` + a bundled `runtime/`, which Helix finds adjacent to the binary, so **no `HELIX_RUNTIME` env var on Windows** (unlike the Linux dev runtime). `makefile/versions.mk` `HELIX_VERSION` `24.03` → `25.07.1` (Linux; `helix.sh` unchanged — same asset naming/layout, no sha pin; next `make provision` reinstalls). Reverted `chezmoi/dot_gitconfig.tmpl` `[core] editor` and `chezmoi/.chezmoi.toml.tmpl` `[edit] command` to unconditional `hx` (now on PATH on both OSes); `[merge]` stays `vimdiff` (Linux) / `zed` (Windows) since Helix has no 3-way merge, and `[diff]` keeps the empty-pager-on-Windows. New `chezmoi/AppData/Roaming/helix/config.toml.tmpl` = `{{ include "dot_config/helix/config.toml" }}` deploys the helix config (catppuccin_mocha theme + keymaps) to `%APPDATA%\helix\config.toml` on Windows — single source of truth, Windows-only via the `AppData` Linux-ignore (`.config/helix` stays Windows-ignored). New dual-edit tripwire: the `bootstrap.ps1` Helix pin ↔ `versions.mk` `HELIX_VERSION`. | **Yes** | §setup-windows install list gains a Helix `<li>` (→ `%LOCALAPPDATA%\workstation\helix`, binary + bundled runtime, "the git/chezmoi editor"); the pins sentence now reads "WezTerm/Starship/Helix" + a note that the helix config deploys to `%APPDATA%\helix`; the flow-diagram step 2 label gains "+ Helix". CLAUDE.md's Windows-installs invariant extended (Helix + the dual-edit + the no-HELIX_RUNTIME-on-Windows note), the Helix-runtime bullet gets the Windows exception; `docs/claude/file-care.md` bootstrap.ps1 entry lists Helix + the AppData `include`. |
```

- [ ] **Step 5: Verify**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- CLAUDE.md ---"; grep -q 'WezTerm + Starship + Helix' CLAUDE.md && grep -q 'no `HELIX_RUNTIME` env var on Windows' CLAUDE.md && echo OK || echo MISSING
echo "--- file-care ---"; grep -q 'WezTerm + Starship + Helix' docs/claude/file-care.md && grep -q 'AppData/Roaming/helix/config.toml.tmpl' docs/claude/file-care.md && echo OK || echo MISSING
echo "--- changelog row ---"; tail -1 CLAUDE_CHANGELOG.md | grep -q 'Installed Helix on the Windows client' && echo OK || echo MISSING
echo "--- no CRLF in docs ---"; for f in CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md; do file "$f"; done
```
Expected: three `OK`s and no "CRLF".

- [ ] **Step 6: Commit**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(claude): record Helix-on-Windows (invariant, file-care, changelog)"
```

---

## Task 6: Whole-repo verification + Windows manual-test checklist

**Files:** none (verification) — plus commit the spec + plan.

- [ ] **Step 1: Full structural sweep**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "=== no leftover zed editor in templates (merge zed is OK) ==="
grep -nE 'editor.*zed|command = "\{\{ if eq .chezmoi.os "windows" \}\}zed' chezmoi/dot_gitconfig.tmpl chezmoi/.chezmoi.toml.tmpl || echo "OK: editor no longer zed"
echo "=== bootstrap.ps1 final encoding ==="; file bootstrap.ps1
echo "=== both helix versions aligned at 25.07.1 ==="
grep -n 'HELIX_VERSION' makefile/versions.mk; grep -n 'Version = "25.07.1"' bootstrap.ps1
echo "=== branch commits ==="; git log --oneline main..HEAD 2>/dev/null || git log --oneline -8
```
Expected: `OK: editor no longer zed`; BOM intact; versions.mk = 25.07.1 and bootstrap.ps1 Helix Version = 25.07.1.

- [ ] **Step 2: Commit the spec + plan**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add docs/superpowers/specs/2026-06-06-helix-on-windows-design.md docs/superpowers/plans/2026-06-06-helix-on-windows.md
git commit -m "docs(superpowers): archive Helix-on-Windows spec + plan" || echo "already committed"
```

- [ ] **Step 3: Hand off the Windows + Linux manual-test checklist** (surface to the user — can't run here):

  **Windows host** (`pwsh` not on the authoring box):
  1. `git pull` the Windows clone; run `.\bootstrap.ps1` (or just the tool-install path) → Helix downloads to `%LOCALAPPDATA%\workstation\helix` (hx.exe + runtime/), added to User PATH.
  2. New shell: `hx --version` → `25.07.1`; `hx --health` → shows runtime found (grammars/themes) with **no** `HELIX_RUNTIME` set (`echo $env:HELIX_RUNTIME` is empty).
  3. `git pull` + `chezmoi init` (regenerate config) + `chezmoi apply` → `git config core.editor` = `hx`; `%APPDATA%\helix\config.toml` exists and matches the repo config (catppuccin theme); `chezmoi status` clean.
  4. `git commit` (no `-m`) opens Helix and waits; `cze`/`chezmoi edit <file>` opens Helix.
  5. Open a code file in `hx` → catppuccin_mocha theme + syntax highlighting render (confirms runtime + config).

  **Linux host:**
  6. `cd makefile && make -n MODE=dev provision | grep -i helix` → the helix target fires (version bump re-triggers it). A real `make provision` installs `hx` 25.07.1; `hx --version` = `25.07.1`; `infocmp`-style smoke: open a file, catppuccin theme renders (runtime at `/usr/local/lib/helix/runtime`, `HELIX_RUNTIME` exported from the rc).

---

## Self-Review

**Spec coverage:**
- Install Helix on Windows (`$PortableTools` tree entry, `$WsHelix`, no HELIX_RUNTIME) → Task 1. ✅
- Version bump 24.03→25.07.1 both OSes (versions.mk + bootstrap.ps1) → Task 1 Steps 1+3. ✅
- Revert editor to `hx`, keep merge=zed/diff-empty → Task 2. ✅
- Deploy helix config to %APPDATA%\helix via `include` → Task 3. ✅
- README §setup-windows (4-tool list + flow + config note) → Task 4. ✅
- CLAUDE.md invariant + HELIX_RUNTIME note + dual-edit; file-care; changelog → Task 5. ✅
- Verify on Windows + Linux → Task 6 Step 3 checklist. ✅
- Risks: BOM (T1 S7-8), runtime discovery + config compat (T6 checklist), include path (T3 S2), AppData mapping/Linux-ignore (T3 S2), editor PATH (T6 checklist), Linux reinstall (T6 S3.6). ✅

**Placeholder scan:** no TBD/TODO; the sha256 + version are real (sourced from the live release); the only `PIN-ME` reference is the existing runtime guard (checked in T1 S7). ✅

**Type/name consistency:** `$WsHelix` / `Version = "25.07.1"` / `Dest = $WsHelix` / `Exe = "hx"` / `Layout = "tree"` are spelled identically across Task 1 and the verifications. `HELIX_VERSION := 25.07.1` matches between versions.mk and the bootstrap pin. The include path `dot_config/helix/config.toml` matches the actual source file. ✅
