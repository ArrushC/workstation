# WezTerm Nightly via Mirrored Weekly Snapshots — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Windows WezTerm install from the pinned stable 20240203 release to weekly, validated, mirrored nightly snapshots, per `docs/superpowers/specs/2026-07-16-wezterm-nightly-design.md`.

**Architecture:** A weekly GitHub workflow validates upstream's rolling nightly on a windows runner (API-digest verify + a `show-keys` smoke gate against OUR config), mirrors the zip as an immutable release asset on this (private) repo, and PRs an ordinary `bootstrap.ps1` pin bump via a new `scripts/bump-wezterm-nightly.sh`. `Install-PortableTool` gains exactly one opt-in branch (`PrivateRepo` auth download — private-repo assets 404 unauthenticated); `-CheckForUpdates` gains a `NightlyAsset` branch. The vendored terminfo auto-syncs in the same PR.

**Tech Stack:** GitHub Actions (windows-latest + ubuntu-latest, `peter-evans/create-pull-request@v7`), bash (GNU sed/awk), PowerShell 5.1-compatible `bootstrap.ps1`, `gh` CLI.

## Global Constraints

- `bootstrap.ps1` is UTF-8 **with BOM**, LF line endings, and must stay PowerShell **5.1-compatible** (no ternary, no `??`, `$x.PSObject.Properties['k']` guards under `Set-StrictMode -Version Latest`).
- New `scripts/*.sh` are auto-covered by `check-invariants.sh`: **LF + git mode 100755 + shellcheck warning+ clean + `shfmt -i 2` formatted** (the `scripts/*.sh` glob at `scripts/check-invariants.sh:161`).
- The repo is **PRIVATE**: mirror-asset downloads need `$env:GITHUB_TOKEN`; the workflow's own `GH_TOKEN: ${{ github.token }}` suffices inside Actions.
- The implementation PR ships with the **stable 20240203 pin still in place** — the first pin flip happens via the workflow (spec migration step 1), so the real path gets exercised.
- WezTerm `$PortableTools` pin values at time of writing (needed by tests): `Version = "20240203-110809-5046fc22"`, `Sha256 = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"`.
- Work happens on the existing branch `feat/wezterm-nightly` (already carries the spec commit). Repo root: `/home/arrush.chaturvedi/.local/share/chezmoi`.
- Every user-facing change lands in README.html + a CLAUDE_CHANGELOG.md row (repo rule).

---

### Task 1: `scripts/bump-wezterm-nightly.sh`

**Files:**
- Create: `scripts/bump-wezterm-nightly.sh`
- Test: manual test cycle against a temp copy (no test framework in this repo; `check-invariants.sh` is the lint gate)

**Interfaces:**
- Consumes: `bootstrap.ps1`'s WezTerm `$PortableTools` entry (anchored on the `Name<spaces>= "WezTerm"` line through the next `},` line).
- Produces: `bump-wezterm-nightly.sh <version> <url> <sha256> [file]` — rewrites the entry's `Version`/`Url`/`Sha256` lines in place; exits non-zero on anchor drift or BOM loss. Task 4's workflow calls it with exactly these three positional args.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# bump-wezterm-nightly.sh — rewrite the WezTerm pin (Version/Url/Sha256) inside
# bootstrap.ps1's $PortableTools entry. Used by
# .github/workflows/wezterm-nightly.yml (weekly mirror job); runnable locally.
#
# Usage: bump-wezterm-nightly.sh <version> <url> <sha256> [file]
#   version  nightly build string, e.g. 20260716-081015-abc123
#   url      immutable mirror asset URL
#   sha256   sha256 of the mirrored zip (lowercase hex)
#   file     target (default: repo bootstrap.ps1; overridable for tests)
#
# Edits ONLY the three pin lines between the entry's `Name ... = "WezTerm"`
# line and its closing `},`. sed (not awk) on purpose: gawk 5.1+ silently
# strips a UTF-8 BOM from its input, and bootstrap.ps1's BOM is load-bearing
# for PowerShell 5.1. Exits non-zero if any of the three values didn't land
# or the BOM was lost, so the workflow fails loudly instead of PRing a dud.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:?usage: bump-wezterm-nightly.sh <version> <url> <sha256> [file]}"
URL="${2:?missing url}"
SHA256="${3:?missing sha256}"
FILE="${4:-$ROOT/bootstrap.ps1}"

[ -f "$FILE" ] || {
  echo "target not found: $FILE" >&2
  exit 1
}
grep -q 'Name[[:space:]]*= "WezTerm"' "$FILE" || {
  echo "WezTerm entry anchor not found in $FILE — aborting" >&2
  exit 1
}

sed -i -e '/^[[:space:]]*Name[[:space:]]*= "WezTerm"$/,/^[[:space:]]*},[[:space:]]*$/ {
  s|^\([[:space:]]*Version[[:space:]]*= \).*|\1"'"$VERSION"'"|
  s|^\([[:space:]]*Url[[:space:]]*= \).*|\1"'"$URL"'"|
  s|^\([[:space:]]*Sha256[[:space:]]*= \).*|\1"'"$SHA256"'"|
}' "$FILE"

for needle in "\"$VERSION\"" "\"$URL\"" "\"$SHA256\""; do
  grep -qF "$needle" "$FILE" || {
    echo "bump failed: $needle not present after edit (anchor drift?)" >&2
    exit 1
  }
done

[ "$(head -c 3 "$FILE" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] || {
  echo "UTF-8 BOM lost from $FILE — refusing" >&2
  exit 1
}

echo "WezTerm pin -> $VERSION"
```

- [ ] **Step 2: Positive test on a temp copy**

```bash
SCRATCH=$(mktemp -d)
cp bootstrap.ps1 "$SCRATCH/test.ps1"
bash scripts/bump-wezterm-nightly.sh \
  "20990101-000000-deadbeef" \
  "https://github.com/ArrushC/workstation/releases/download/wezterm-nightly-snapshots/WezTerm-windows-20990101-000000-deadbeef.zip" \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "$SCRATCH/test.ps1"
# Three replaced lines, inside the WezTerm block only:
diff bootstrap.ps1 "$SCRATCH/test.ps1" | grep '^[<>]' | wc -l   # expect: 6
grep -c '20990101-000000-deadbeef' "$SCRATCH/test.ps1"          # expect: 2 (Version + Url)
# Other entries untouched (starship pin still present):
grep -c 'a07cf3e428afab09324e510fb786041ebcc491a68b1ca6fba044c5a461f9b017' "$SCRATCH/test.ps1"  # expect: 1
# BOM survived:
head -c 3 "$SCRATCH/test.ps1" | od -An -tx1                     # expect: ef bb bf
```

Expected: exact counts above; script prints `WezTerm pin -> 20990101-000000-deadbeef`.

- [ ] **Step 3: Identity test on the real file (no-op bump leaves tree clean)**

```bash
bash scripts/bump-wezterm-nightly.sh \
  "20240203-110809-5046fc22" \
  "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip" \
  "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
git diff --quiet bootstrap.ps1 && echo IDENTITY-OK
```

Expected: `IDENTITY-OK`. (NOTE: run this BEFORE Task 3 re-aligns the entry's field padding — after Task 3 the `= ` spacing inside the entry changes and the identity property still holds, but re-verify with Task 3's values.)

- [ ] **Step 4: Negative test (anchor missing → exit 1)**

```bash
echo 'no anchor here' > "$SCRATCH/empty.ps1"
bash scripts/bump-wezterm-nightly.sh v u s "$SCRATCH/empty.ps1"; echo "exit=$?"
```

Expected: `WezTerm entry anchor not found...` on stderr, `exit=1`.

- [ ] **Step 5: Lint + commit**

```bash
file scripts/bump-wezterm-nightly.sh          # no CRLF
git add scripts/bump-wezterm-nightly.sh
git update-index --chmod=+x scripts/bump-wezterm-nightly.sh
bash scripts/check-invariants.sh              # LF/0755/shellcheck/shfmt incl. the new script
git commit -m "feat(scripts): bump-wezterm-nightly.sh — BOM-safe WezTerm pin rewriter"
```

Expected: invariant check all green (the new script joins the `scripts/*.sh` set automatically).

---

### Task 2: `Install-PortableTool` — opt-in `PrivateRepo` auth download

**Files:**
- Modify: `bootstrap.ps1` — the download `try/catch` inside `Install-PortableTool` (currently lines ~735–743: the block that sets `SecurityProtocol` and calls `Invoke-WebRequest -Uri $Tool.Url`)

**Interfaces:**
- Consumes: optional `$Tool.PrivateRepo` (string `"owner/repo"`) on a `$PortableTools` entry (Task 3 adds it to WezTerm); `$env:GITHUB_TOKEN`.
- Produces: authenticated asset download when `PrivateRepo` is set AND `$Tool.Url` points into that repo; plain download otherwise. Warn-and-skip (not fail) when the token is absent.

- [ ] **Step 1: Replace the download block**

Find this exact block in `Install-PortableTool`:

```powershell
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $Tool.Url -OutFile $tmpZip -UseBasicParsing
    } catch {
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }
```

Replace with:

```powershell
    # Private-mirror download (opt-in via PrivateRepo — today only WezTerm's
    # nightly-snapshot mirror): release assets on a PRIVATE repo 404 on the
    # plain releases/download URL, so resolve the asset id by name via the
    # API and fetch through the asset endpoint with the token. Gated on the
    # Url actually pointing INTO PrivateRepo, so a rollback re-pin to the
    # public upstream stable URL takes the plain path with no field edits.
    # GITHUB_TOKEN is already mandatory on private-repo machines (the clone
    # step below) — an absent token warns-and-skips like a download failure.
    $usePrivate = $Tool.ContainsKey('PrivateRepo') -and
        ($Tool.Url -like "*github.com/$($Tool.PrivateRepo)/*")
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        if ($usePrivate) {
            if (-not $env:GITHUB_TOKEN) {
                Write-Warn "$($Tool.Name): GITHUB_TOKEN not set — can't download the private mirror asset. Skipping."
                return
            }
            $assetName = $Tool.Url.Split('/')[-1]
            $relTag    = $Tool.Url.Split('/')[-2]
            $headers   = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; 'User-Agent' = 'workstation-bootstrap' }
            $rel   = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Tool.PrivateRepo)/releases/tags/$relTag" `
                -Headers $headers -UseBasicParsing
            $asset = @($rel.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
            if (-not $asset) { throw "asset '$assetName' not found on release '$relTag'" }
            # The asset endpoint + Accept: octet-stream 302s to a pre-signed
            # CDN URL. .NET Framework's HttpWebRequest (PS 5.1's engine)
            # STRIPS the Authorization header when auto-following the
            # redirect, so the pre-signed hop arrives clean — no manual 302
            # handling needed (proven live 2026-07-16: fetched-asset sha256
            # matched the pin; the -MaximumRedirection 0 capture alternative
            # instead throws InvalidOperationException with a null Response
            # on PS 5.1, so it can never work there).
            $headers['Accept'] = 'application/octet-stream'
            Invoke-WebRequest -Uri "https://api.github.com/repos/$($Tool.PrivateRepo)/releases/assets/$($asset.id)" `
                -Headers $headers -OutFile $tmpZip -UseBasicParsing
        } else {
            Invoke-WebRequest -Uri $Tool.Url -OutFile $tmpZip -UseBasicParsing
        }
    } catch {
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }
```

- [ ] **Step 2: Verify BOM retained + PS 5.1 parses the file**

```bash
head -c 3 bootstrap.ps1 | od -An -tx1    # expect: ef bb bf
timeout 60 powershell.exe -NoProfile -Command '
$t = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw "\\wsl.localhost\AlmaLinux-9\home\arrush.chaturvedi\.local\share\chezmoi\bootstrap.ps1"), [ref]$null)
Write-Output ("TOKENS=" + $t.Count)'
```

Expected: BOM bytes present; `TOKENS=<large number>` with no parse exception. (Full behavioral validation of the auth path happens in Task 8 after the first snapshot exists — there is nothing to download yet.)

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): PrivateRepo auth-download branch in Install-PortableTool"
```

---

### Task 3: WezTerm entry fields + `-CheckForUpdates` `NightlyAsset` branch

**Files:**
- Modify: `bootstrap.ps1` — the WezTerm `$PortableTools` entry (~line 222); the `$PortableTools` field-documentation banner (~lines 376–418); the portable-tools loop inside `Invoke-CheckForUpdates` (~line 2004).

**Interfaces:**
- Consumes: Task 2's `PrivateRepo` semantics.
- Produces: `NightlyAsset` (string, upstream asset filename) — its presence routes the tool's update-scan row through the upstream nightly release's `updated_at`; `Repo` on such an entry means the UPSTREAM repo. Task 4's workflow assumes the entry keeps line-per-field `Version`/`Url`/`Sha256` shape (bump-script contract).

- [ ] **Step 1: Rewrite the WezTerm entry**

Replace the current entry (from `        Name       = "WezTerm"` through its `        Shortcut   = @{ ... }` line) with:

```powershell
        Name         = "WezTerm"
        Exe          = "wezterm"
        Version      = "20240203-110809-5046fc22"
        Url          = "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip"
        Sha256       = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
        Layout       = "tree"
        Dest         = $WsWezterm
        Repo         = "wez/wezterm"
        NightlyAsset = "WezTerm-windows-nightly.zip"
        PrivateRepo  = "ArrushC/workstation"
        UpdateHint   = "weekly wezterm-nightly.yml PRs snapshot bumps; dispatch it for an immediate refresh"
        Shortcut     = @{ Target = "wezterm-gui"; Description = "WezTerm terminal emulator" }
```

Notes: `TagPrefix`/`TagFilter`/`TagSort` are REMOVED (dead once `NightlyAsset` drives the row). Pin values unchanged (stable) — the workflow performs the first flip. Field alignment widens to the longest key (`NightlyAsset`).

- [ ] **Step 2: Document the two new fields in the `$PortableTools` banner**

In the field-documentation comment block (the one describing `Repo`/`TagPrefix`/`UpdateHint`, ~line 389), add:

```powershell
#   NightlyAsset       upstream rolling-nightly asset filename (WezTerm). Its
#                      presence switches the -CheckForUpdates row from a git-tag
#                      lookup (meaningless against a single rolling 'nightly'
#                      tag) to comparing the pin's leading yyyymmdd against the
#                      asset's updated_at. Repo then means the UPSTREAM repo.
#   PrivateRepo        owner/repo of OUR private mirror. When set AND Url points
#                      into it, Install-PortableTool downloads via the GitHub
#                      API asset endpoint with GITHUB_TOKEN (private release
#                      assets 404 unauthenticated); absent token warns-and-skips.
```

- [ ] **Step 3: Add the `NightlyAsset` branch to `Invoke-CheckForUpdates`**

The portable loop currently reads:

```powershell
    foreach ($tool in $PortableTools) {
        $filter    = if ($tool.ContainsKey('TagFilter')) { $tool.TagFilter } else { '^\d+(\.\d+)*$' }
        $useString = ($tool.ContainsKey('TagSort') -and $tool.TagSort -eq 'string')
        $hint      = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "" }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tool.TagPrefix -Filter $filter -StringSort:$useString
        Write-UpdateStatus -Name $tool.Name -Pinned $tool.Version -Latest $latest -Hint $hint -StringSort:$useString
    }
```

Change to:

```powershell
    foreach ($tool in $PortableTools) {
        if ($tool.ContainsKey('NightlyAsset')) {
            # Rolling-nightly snapshot (WezTerm): upstream has ONE rolling
            # 'nightly' tag, so a tag lookup is meaningless — compare our
            # snapshot's build date (Version leads with yyyymmdd) against the
            # upstream asset's updated_at instead.
            $asset = $null
            try {
                $rel   = Invoke-RestMethod -Uri "https://api.github.com/repos/$($tool.Repo)/releases/tags/nightly" `
                    -Headers @{ 'User-Agent' = 'workstation-bootstrap' } -UseBasicParsing
                $asset = @($rel.assets) | Where-Object { $_.name -eq $tool.NightlyAsset } | Select-Object -First 1
            } catch { $asset = $null }   # network/API failure -> unresolved; warn below
            if (-not $asset) {
                Write-Warn "$($tool.Name): couldn't resolve the upstream nightly asset (offline? renamed?)"
                continue
            }
            $upstreamDay = ([datetime]$asset.updated_at).ToUniversalTime().ToString('yyyyMMdd')
            $pinnedDay   = ($tool.Version -split '-')[0]
            $hint        = if ($tool.ContainsKey('UpdateHint')) { " — $($tool.UpdateHint)" } else { "" }
            if ($upstreamDay -gt $pinnedDay) {
                Write-Warn "$($tool.Name) snapshot $($tool.Version) — upstream nightly rebuilt $upstreamDay$hint"
            } else {
                Write-Ok "$($tool.Name) snapshot $($tool.Version) is current (upstream nightly $upstreamDay)"
            }
            continue
        }
        $filter    = if ($tool.ContainsKey('TagFilter')) { $tool.TagFilter } else { '^\d+(\.\d+)*$' }
        $useString = ($tool.ContainsKey('TagSort') -and $tool.TagSort -eq 'string')
        $hint      = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "" }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tool.TagPrefix -Filter $filter -StringSort:$useString
        Write-UpdateStatus -Name $tool.Name -Pinned $tool.Version -Latest $latest -Hint $hint -StringSort:$useString
    }
```

- [ ] **Step 4: Behavioral test via interop**

```bash
timeout 300 powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
& "\\wsl.localhost\AlmaLinux-9\home\arrush.chaturvedi\.local\share\chezmoi\bootstrap.ps1" -CheckForUpdates
' 2>&1 | rg -i 'wezterm'
```

Expected: exactly one WezTerm line, of the form `WezTerm snapshot 20240203-110809-5046fc22 — upstream nightly rebuilt <yyyymmdd> — weekly wezterm-nightly.yml PRs snapshot bumps...` (upstream rebuilds daily, so with the stable pin the "rebuilt" warn arm is the expected one). No `Get-LatestGitTag` error for WezTerm.

- [ ] **Step 5: Bump-script contract check + BOM + commit**

```bash
# Task 1 identity test against the REALIGNED entry (spacing changed):
bash scripts/bump-wezterm-nightly.sh \
  "20240203-110809-5046fc22" \
  "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip" \
  "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
git diff --quiet bootstrap.ps1 && echo IDENTITY-OK   # expect IDENTITY-OK (sed keeps the new alignment)
head -c 3 bootstrap.ps1 | od -An -tx1                # ef bb bf
git add bootstrap.ps1
git commit -m "feat(windows): NightlyAsset update-scan branch + WezTerm nightly-mirror fields"
```

NOTE: sed's replacement is `\1"<value>"` where `\1` captures `<spaces>Version<spaces>= ` — alignment inside the entry is preserved verbatim, so identity holds after the realignment.

---

### Task 4: `.github/workflows/wezterm-nightly.yml`

**Files:**
- Create: `.github/workflows/wezterm-nightly.yml`

**Interfaces:**
- Consumes: `scripts/bump-wezterm-nightly.sh <version> <url> <sha256>` (Task 1); the WezTerm entry's `Name ... = "WezTerm"` / `Version = "..."` shape (Task 3); `chezmoi/dot_local/share/wezterm/wezterm.terminfo` with a 2-line provenance header.
- Produces: the `wezterm-nightly-snapshots` release + dated assets; PRs on branch `automation/wezterm-nightly`.

- [ ] **Step 1: Write the workflow**

```yaml
name: wezterm-nightly

# Weekly WezTerm nightly snapshot: validate upstream's rolling nightly on a
# windows runner (API-digest verify + a show-keys smoke gate against OUR
# config), mirror the zip as an immutable release asset (upstream keeps only
# ONE rolling nightly — old builds vanish), then PR the bootstrap.ps1 pin
# bump + a vendored-terminfo refresh when upstream drifted.
# Design: docs/superpowers/specs/2026-07-16-wezterm-nightly-design.md
on:
  schedule:
    - cron: '0 7 * * 1'   # Mondays 07:00 UTC — an hour after version-bumps
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  validate:
    runs-on: windows-latest
    outputs:
      proceed:     ${{ steps.nightly.outputs.proceed }}
      version:     ${{ steps.nightly.outputs.version }}
      sha256:      ${{ steps.nightly.outputs.sha256 }}
      digest_note: ${{ steps.nightly.outputs.digest_note }}
      updated_at:  ${{ steps.nightly.outputs.updated_at }}
    steps:
      - uses: actions/checkout@v5
      - name: Download, verify, identify, smoke-test
        id: nightly
        shell: pwsh
        run: |
          $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/wez/wezterm/releases/tags/nightly' `
            -Headers @{ 'User-Agent' = 'workstation-wezterm-nightly' }
          $asset = @($rel.assets) | Where-Object { $_.name -eq 'WezTerm-windows-nightly.zip' } | Select-Object -First 1
          if (-not $asset) { throw 'WezTerm-windows-nightly.zip not found on the nightly release (renamed upstream?)' }

          Invoke-WebRequest -Uri $asset.browser_download_url -OutFile nightly.zip
          $actual = (Get-FileHash nightly.zip -Algorithm SHA256).Hash.ToLower()

          $digestNote = 'upstream API digest verified'
          $digest = if ($asset.PSObject.Properties['digest']) { $asset.digest } else { $null }
          if ($digest) {
            $expected = ($digest -replace '^sha256:', '').ToLower()
            if ($actual -ne $expected) { throw "digest mismatch - api=$expected actual=$actual" }
          } else {
            $digestNote = 'WARNING: upstream asset had no API digest - sha pinned from the download itself'
          }

          Expand-Archive nightly.zip -DestinationPath wt
          $exe = (Get-ChildItem wt -Recurse -Filter wezterm.exe | Select-Object -First 1).FullName
          $ver = ((& $exe --version) -split '\s+')[1]
          if ($ver -notmatch '^\d{8}-\d{6}-[0-9a-f]+$') { throw "unexpected version string: $ver" }

          # Config smoke gate: a nightly that can't load OUR config never ships.
          # 'error' on stderr may false-positive on benign text — acceptable:
          # it fails toward a human looking at the run, never toward a bad PR.
          & $exe --config-file chezmoi/dot_config/wezterm/wezterm.lua show-keys 1> keys.txt 2> err.txt
          if ($LASTEXITCODE -ne 0 -or (Select-String -Path err.txt -Pattern 'error' -Quiet)) {
            Get-Content err.txt
            throw "show-keys smoke gate FAILED on nightly $ver - config incompatible, no PR will be created"
          }
          if (-not (Select-String -Path keys.txt -Pattern 'ActivateLastTab' -Quiet)) {
            throw 'show-keys ran but our bindings are missing - config fell back to defaults?'
          }

          # Early-exit success (no PR) when this exact build is already pinned.
          $bootstrap = Get-Content bootstrap.ps1 -Raw
          $pinned = [regex]::Match($bootstrap, '(?s)Name\s+=\s+"WezTerm".*?Version\s+=\s+"([^"]+)"').Groups[1].Value
          $proceed = if ($pinned -eq $ver) { 'false' } else { 'true' }

          "proceed=$proceed"                >> $env:GITHUB_OUTPUT
          "version=$ver"                    >> $env:GITHUB_OUTPUT
          "sha256=$actual"                  >> $env:GITHUB_OUTPUT
          "digest_note=$digestNote"         >> $env:GITHUB_OUTPUT
          "updated_at=$($asset.updated_at)" >> $env:GITHUB_OUTPUT
          Write-Host "nightly $ver (pinned: $pinned, proceed: $proceed)"
      - name: Stash the verified zip for the mirror job
        if: steps.nightly.outputs.proceed == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: wezterm-nightly-zip
          path: nightly.zip
          retention-days: 3

  mirror-and-pr:
    needs: validate
    if: needs.validate.outputs.proceed == 'true'
    runs-on: ubuntu-latest
    env:
      VERSION: ${{ needs.validate.outputs.version }}
      SHA256:  ${{ needs.validate.outputs.sha256 }}
    steps:
      - uses: actions/checkout@v5
      - uses: actions/download-artifact@v4
        with:
          name: wezterm-nightly-zip
          path: ${{ runner.temp }}
      - name: Mirror the snapshot (immutable asset; prune to newest 8)
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          TAG=wezterm-nightly-snapshots
          gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" \
            --title "WezTerm nightly snapshots (mirror)" --latest=false \
            --notes "Immutable mirror of upstream WezTerm nightly builds (upstream keeps only ONE rolling nightly). Pinned by bootstrap.ps1; pruned to the newest 8. Managed by wezterm-nightly.yml."
          # Stage the asset OUTSIDE the workspace — peter-evans git-add -A's
          # the whole tree, and a workspace-resident zip lands IN the bump PR
          # (bit the first dispatch, 2026-07-16).
          mv "$RUNNER_TEMP/nightly.zip" "$RUNNER_TEMP/WezTerm-windows-${VERSION}.zip"
          gh release upload "$TAG" "$RUNNER_TEMP/WezTerm-windows-${VERSION}.zip" --clobber
          gh api "repos/${GITHUB_REPOSITORY}/releases/tags/$TAG" \
            --jq '.assets | sort_by(.created_at) | reverse | .[8:][].id' |
            while read -r id; do
              gh api -X DELETE "repos/${GITHUB_REPOSITORY}/releases/assets/$id"
            done
      - name: Bump the bootstrap.ps1 pin
        run: |
          bash scripts/bump-wezterm-nightly.sh "$VERSION" \
            "https://github.com/${GITHUB_REPOSITORY}/releases/download/wezterm-nightly-snapshots/WezTerm-windows-${VERSION}.zip" \
            "$SHA256"
      - name: Sync vendored wezterm.terminfo from upstream main
        id: terminfo
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VENDORED=chezmoi/dot_local/share/wezterm/wezterm.terminfo
          COMMIT=$(gh api 'repos/wez/wezterm/commits?path=termwiz/data/wezterm.terminfo&per_page=1' --jq '.[0].sha')
          curl -fsSL "https://raw.githubusercontent.com/wez/wezterm/${COMMIT}/termwiz/data/wezterm.terminfo" -o upstream.terminfo
          # tic-validate before adopting (ubuntu runners ship ncurses tic)
          tic -x -o "$(mktemp -d)" upstream.terminfo
          if cmp -s <(tail -n +3 "$VENDORED") upstream.terminfo; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            {
              echo "# Vendored from wezterm/wezterm@${COMMIT:0:12} termwiz/data/wezterm.terminfo (nightly snapshot $(date -u +%F))"
              echo "# Synced by .github/workflows/wezterm-nightly.yml; manual re-vendor recipe in docs/claude/file-care.md. chezmoi's run_ script auto-re-tic's on next cza."
              cat upstream.terminfo
            } > "$VENDORED"
            echo "changed=true" >> "$GITHUB_OUTPUT"
          fi
          rm -f upstream.terminfo
      # A PR opened by GITHUB_TOKEN does NOT trigger lint.yml (GitHub's
      # recursion guard) — validate the bumped tree here, like version-bumps.
      - name: Verify invariants on the bumped tree
        run: bash scripts/check-invariants.sh
      - name: Write PR body
        run: |
          cat > "$RUNNER_TEMP/pr-body.md" <<EOF
          Weekly WezTerm nightly snapshot.

          - build: \`${VERSION}\` (upstream asset updated ${{ needs.validate.outputs.updated_at }})
          - integrity: ${{ needs.validate.outputs.digest_note }}; mirrored sha256 \`${SHA256}\`
          - smoke gate: \`wezterm show-keys\` PASSED against the repo config on windows-latest
          - terminfo: $([ "${{ steps.terminfo.outputs.changed }}" = "true" ] && echo "refreshed from upstream main — hosts re-tic on next cza" || echo "unchanged")

          After merge, on the Windows box: close WezTerm, \`git pull\` the chezmoi clone, re-run \`bootstrap.ps1\`.
          EOF
      - name: Create or update PR
        uses: peter-evans/create-pull-request@v7
        with:
          branch: automation/wezterm-nightly
          delete-branch: true
          title: 'chore(wezterm): nightly snapshot ${{ needs.validate.outputs.version }}'
          commit-message: 'chore(wezterm): nightly snapshot ${{ needs.validate.outputs.version }}'
          body-path: ${{ runner.temp }}/pr-body.md
```

- [ ] **Step 2: Static validation**

```bash
yq e '.jobs | keys' .github/workflows/wezterm-nightly.yml     # expect: [validate, mirror-and-pr]
yq e '.on.schedule[0].cron' .github/workflows/wezterm-nightly.yml  # expect: 0 7 * * 1
# terminfo header-line assumption (cmp uses tail -n +3):
head -2 chezmoi/dot_local/share/wezterm/wezterm.terminfo | grep -c '^#'   # expect: 2
```

Expected: exact outputs above. (Full end-to-end validation is the Task 8 dispatch — Actions can't run locally.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/wezterm-nightly.yml
git commit -m "feat(ci): wezterm-nightly.yml — validated + mirrored weekly nightly snapshots"
```

---

### Task 5: Config comment sweep (`chezmoi/dot_config/wezterm/`)

**Files:**
- Modify: `chezmoi/dot_config/wezterm/appearance.lua` (the `check_for_updates` block), `chezmoi/dot_config/wezterm/wezterm.lua` (package.path comment), `chezmoi/dot_config/wezterm/keys.lua` (inputmap verification comments)

**Interfaces:** none (comments only; NO behavioral change in this task).

- [ ] **Step 1: Re-verify the two source-level claims against upstream main**

```bash
# (a) SHIFT+Down default is still ExtendSelectionToMouseCursor(Cell), and no
#     default CTRL-click OpenLink exists:
curl -sL 'https://raw.githubusercontent.com/wez/wezterm/main/wezterm-gui/src/inputmap.rs' \
  | rg -n 'SHIFT|OpenLinkAtMouseCursor|ExtendSelectionToMouseCursor' | head -30
# (b) package.path (already verified 2026-07-16, re-run for the record):
curl -sL 'https://raw.githubusercontent.com/wez/wezterm/main/config/src/lua.rs' \
  | rg -n 'prefix_path\(&mut path_array'
```

Expected for (a): a `(Modifiers::SHIFT, MouseEventTrigger::Down …)` mapping to `ExtendSelectionToMouseCursor(… Cell …)` and NO `Modifiers::CTRL` mapping to `OpenLinkAtMouseCursor`. Expected for (b): only `~/.wezterm`, `CONFIG_DIRS`, and `wezterm_modules` prefixes. **If either differs, STOP — report the drift to the user before editing any comment** (the SHIFT-click override design may need rework on nightly).

- [ ] **Step 2: appearance.lua — rewrite the update-toast rationale**

Replace:

```lua
-- Update-check toast off — the Windows build is deliberately pinned at
-- 20240203 (bootstrap.ps1 $PortableTools), so "new version available" is
-- pure noise. Re-enable if the pin policy ever changes. (Supersedes the
-- 2026-07-09 UX-sweep spec's decline — re-approved 2026-07-10.)
config.check_for_updates = false
```

with:

```lua
-- Update-check toast off — the WezTerm pin is maintained as weekly
-- mirrored NIGHTLY snapshots (bootstrap.ps1 $PortableTools, bumped only by
-- .github/workflows/wezterm-nightly.yml), so the update channel is the
-- weekly PR + bootstrap re-run; against a rolling nightly the in-app toast
-- is pure noise. (History: pinned stable 20240203 from 2026-05; nightly
-- snapshot policy adopted 2026-07-16 — the stable pin stays until the
-- first workflow-driven bump PR lands. Toast declined 2026-07-09,
-- re-approved 2026-07-10, kept off under the nightly policy.)
config.check_for_updates = false
```

- [ ] **Step 3: wezterm.lua (entry) — date-stamp the package.path claim**

Replace the sentence in the shim comment:

```lua
-- wezterm 20240203 does NOT add the config file's own directory to
-- package.path (only ~/.config/wezterm, ~/.wezterm, and wezterm_modules
-- next to the exe — see config/src/lua.rs at the pinned tag). On Windows
```

with:

```lua
-- wezterm does NOT add the config file's own directory to package.path
-- (only ~/.config/wezterm, ~/.wezterm, and wezterm_modules next to the
-- exe — config/src/lua.rs, verified at 20240203 AND on nightly main
-- 2026-07-16; the pin policy is weekly nightly snapshots). On Windows
```

- [ ] **Step 4: keys.lua — date-stamp the inputmap verifications**

Two edits (both inside the mouse-bindings comments):

```
old: "(the wezterm.org/config/mouse.html page incorrectly lists one — the source at\n  -- wezterm-gui/src/inputmap.rs disagrees, and the recipes page is correct)"
new: "(the wezterm.org/config/mouse.html page incorrectly lists one — the source at\n  -- wezterm-gui/src/inputmap.rs disagrees, verified at 20240203 + nightly main 2026-07-16)"

old: "(verified against inputmap.rs at the pinned 20240203 tag)"
new: "(verified against inputmap.rs at 20240203 + nightly main 2026-07-16)"
```

(Exact current phrasing may wrap differently across lines — locate with `rg -n 'inputmap' chezmoi/dot_config/wezterm/keys.lua` and keep each comment's meaning while adding the nightly re-verification date.)

- [ ] **Step 5: Lint + commit**

```bash
lua-language-server --check chezmoi/dot_config/wezterm/ --checklevel=Error \
  --logpath=/tmp/claude-1000/-home-arrush-chaturvedi--local-share-chezmoi/f72acaab-c999-43d2-a124-987be1616faf/scratchpad/luals-nightly 2>&1 | tail -1
git add chezmoi/dot_config/wezterm/
git commit -m "docs(wezterm): comment sweep for the nightly pin policy"
```

Expected: `no problems found`.

---

### Task 6: Docs — CLAUDE.md, file-care, invariants, README, changelog

**Files:**
- Modify: `CLAUDE.md` (Windows-installs invariant bullet), `docs/claude/file-care.md` (bootstrap.ps1 + wezterm.terminfo entries), `docs/claude/invariants.md` (config.term chain), `README.html` (§setup-windows WezTerm card + §troubleshooting new entry), `CLAUDE_CHANGELOG.md` (one row)

**Interfaces:** none (docs).

- [ ] **Step 1: CLAUDE.md**

In the Windows-installs invariant bullet, replace the clause `WezTerm's pin tracks the vendored-terminfo tag, and the` with:

```
**WezTerm rides NIGHTLY via mirrored weekly snapshots** — its pin (Version/Url/Sha256 → the private `wezterm-nightly-snapshots` release assets) AND the vendored `wezterm.terminfo` are bumped ONLY by `.github/workflows/wezterm-nightly.yml` (windows-runner digest verify + `show-keys` config smoke gate; never hand-bumped), downloaded via `Install-PortableTool`'s opt-in `PrivateRepo` auth branch (needs `GITHUB_TOKEN` — private release assets 404 unauthenticated; rollback = re-pin a retained snapshot or the immutable stable 20240203 upstream URL), and the
```

- [ ] **Step 2: docs/claude/file-care.md**

(a) In the `scripts/manage-hosts.ps1 and bootstrap.ps1` entry, replace `WezTerm's pin tracks the same tag as the vendored wezterm.terminfo.` with:

```
WezTerm is the workflow-bumped exception: it rides nightly via mirrored snapshots — `.github/workflows/wezterm-nightly.yml` rewrites its Version/Url/Sha256 (via `scripts/bump-wezterm-nightly.sh`, BOM-safe) and refreshes the vendored terminfo in the same PR; never bump the WezTerm pin by hand. Its `PrivateRepo`/`NightlyAsset` fields drive the auth download and the -CheckForUpdates row.
```

(b) In the `chezmoi/dot_local/share/wezterm/wezterm.terminfo` entry, replace `Editing this file by hand defeats the vendoring contract; bump by re-downloading from the upstream tag and committing.` with:

```
Editing this file by hand defeats the vendoring contract; it is refreshed automatically by `.github/workflows/wezterm-nightly.yml` when upstream main drifts (provenance header records the upstream commit + snapshot date). Manual fallback: re-download from https://raw.githubusercontent.com/wez/wezterm/<commit>/termwiz/data/wezterm.terminfo and keep the 2-line provenance header shape (the workflow's cmp skips those 2 lines).
```

- [ ] **Step 3: docs/claude/invariants.md**

In the `config.term='wezterm'` chain entry, after the sentence ending `(vendored upstream).`, insert:

```
The vendored source is refreshed by `.github/workflows/wezterm-nightly.yml` whenever upstream main's terminfo drifts (2-line provenance header, tic-validated before adoption) — the four artifacts still move together, the workflow just automates the vendored-source leg.
```

- [ ] **Step 4: README.html**

(a) Locate the WezTerm entry in §setup-windows's portable-tools list (`rg -n 'WezTerm' README.html` — the `<li>` describing the pinned portable install) and rewrite its version story: pinned-stable wording → "rides nightly via weekly mirrored snapshots: a scheduled workflow validates each nightly (sha256 digest + a config smoke test on a Windows runner), mirrors it as an immutable release asset, and opens a pin-bump PR; merging + re-running `bootstrap.ps1` (with WezTerm closed) installs it. Requires `GITHUB_TOKEN` (already required on this private repo)."

(b) Add a §troubleshooting entry (match the existing `<details data-ts>` shape used by neighboring entries):

```html
<details data-ts>
    <summary>Roll back a bad WezTerm nightly</summary>
    <div class="ts-body">
        <p>
            The mirror keeps the newest 8 snapshots as immutable
            release assets (<code>wezterm-nightly-snapshots</code>).
            To roll back: edit the WezTerm entry in
            <code>bootstrap.ps1</code>'s <code>$PortableTools</code> —
            set <code>Version</code>/<code>Url</code>/<code>Sha256</code>
            to any retained snapshot (or to the forever-immutable
            stable <code>20240203</code> upstream URL), close WezTerm,
            re-run <code>.\bootstrap.ps1</code>. Revert or close the
            offending weekly PR so the next run doesn't re-bump.
        </p>
        <pre><code>gh release view wezterm-nightly-snapshots --json assets --jq '.assets[].name'</code></pre>
    </div>
</details>
```

(c) `rg -n -i 'pinned' README.html | rg -i wezterm` — sweep any remaining "pinned at 20240203"-style WezTerm claims.

- [ ] **Step 5: CLAUDE_CHANGELOG.md row**

Append one row (same table shape as existing rows): WezTerm moves from pinned stable 20240203 to weekly mirrored nightly snapshots — new `wezterm-nightly.yml` (windows-runner digest verify + show-keys config smoke gate, immutable mirror assets pruned to 8, pin bump via BOM-safe `bump-wezterm-nightly.sh`, terminfo auto-sync), `Install-PortableTool` `PrivateRepo` auth branch (private-repo assets 404 unauthenticated; GITHUB_TOKEN warn-skip), `NightlyAsset` -CheckForUpdates branch, config-comment sweep. README = **Yes** (§setup-windows WezTerm card, §troubleshooting rollback entry).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/claude/file-care.md docs/claude/invariants.md README.html CLAUDE_CHANGELOG.md
git commit -m "docs: WezTerm nightly snapshot model — invariants, file-care, README, changelog"
```

---

### Task 7: Repo-wide verification + push + PR

**Files:** none new.

- [ ] **Step 1: Full lint**

```bash
make lint MODE=prod
```

Expected: all invariant checks green (incl. the new script in the LF/0755/shellcheck/shfmt sets) + template render checks green.

- [ ] **Step 2: PS 5.1 re-parse + BOM after all bootstrap.ps1 edits**

```bash
head -c 3 bootstrap.ps1 | od -An -tx1   # ef bb bf
timeout 300 powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
& "\\wsl.localhost\AlmaLinux-9\home\arrush.chaturvedi\.local\share\chezmoi\bootstrap.ps1" -CheckForUpdates
' 2>&1 | tail -25
```

Expected: full update scan completes; WezTerm row uses the nightly comparison; every other tool row unchanged in shape.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feat/wezterm-nightly
gh pr create --title "WezTerm: ride nightly via validated, mirrored weekly snapshots" --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-07-16-wezterm-nightly-design.md.

- **wezterm-nightly.yml** (Mondays 07:00 UTC + dispatch): windows-runner job verifies the upstream nightly against the API sha256 digest, extracts the real build string, and runs a `show-keys` smoke gate against OUR config — an incompatible nightly fails the run and no PR is created. Then it mirrors the zip as an immutable `wezterm-nightly-snapshots` release asset (pruned to the newest 8), bumps the pin via the new BOM-safe `scripts/bump-wezterm-nightly.sh`, auto-syncs the vendored terminfo when upstream drifted, and PRs the result (branch `automation/wezterm-nightly`).
- **bootstrap.ps1**: `Install-PortableTool` gains one opt-in `PrivateRepo` auth-download branch (private-repo release assets 404 unauthenticated; token warn-skip; manual 302 handling — PS 5.1 re-sends Authorization to S3, which S3 rejects); `-CheckForUpdates` gains a `NightlyAsset` branch comparing the pin's build date to upstream's asset `updated_at`.
- **Config + docs**: comment sweep for the new pin policy (check_for_updates rationale, package.path + inputmap claims re-verified on nightly main), CLAUDE.md/file-care/invariants updates, README §setup-windows card + new "Roll back a bad WezTerm nightly" troubleshooting entry, changelog row.

**The WezTerm pin in this PR is still stable 20240203** — the first flip happens via `gh workflow run wezterm-nightly.yml` after merge, so the real path gets exercised (migration steps in the spec).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: CI green (invariants, powershell/PSScriptAnalyzer, templates).

---

### Task 8: Migration (after the implementation PR merges)

**Files:** none (operational).

- [ ] **Step 1: First snapshot via dispatch**

```bash
gh workflow run wezterm-nightly.yml
gh run watch $(gh run list --workflow=wezterm-nightly.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: `validate` passes (digest + smoke gate on the real nightly), `mirror-and-pr` uploads `WezTerm-windows-<version>.zip` and opens PR `chore(wezterm): nightly snapshot <version>` containing the pin bump AND the terminfo refresh (drift exists — the `Su` capability).

- [ ] **Step 2: Standalone auth-download test via interop (validates Task 2's redirect handling against the real asset, before touching the Windows install)**

```bash
timeout 120 powershell.exe -NoProfile -Command '
$tok = $env:GITHUB_TOKEN; if (-not $tok) { Write-Output "SET GITHUB_TOKEN FIRST"; exit 1 }
$h = @{ Authorization = "Bearer $tok"; "User-Agent" = "workstation-bootstrap" }
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/ArrushC/workstation/releases/tags/wezterm-nightly-snapshots" -Headers $h -UseBasicParsing
$asset = @($rel.assets) | Select-Object -First 1
$h["Accept"] = "application/octet-stream"
Invoke-WebRequest -Uri "https://api.github.com/repos/ArrushC/workstation/releases/assets/$($asset.id)" -Headers $h -OutFile "$env:TEMP\wz-test.zip" -UseBasicParsing
Write-Output ("SHA=" + (Get-FileHash "$env:TEMP\wz-test.zip" -Algorithm SHA256).Hash.ToLower())
Remove-Item "$env:TEMP\wz-test.zip" -Force
'
```

Expected: `SHA=<value>` equal to the `Sha256` in the bump PR. If an S3 auth error appears, fix Task 2's download handling BEFORE merging the bump PR.

- [ ] **Step 3: Merge the bump PR; update the Windows box (user-performed)**

Close WezTerm → `git pull` in the Windows chezmoi clone → ensure `$env:GITHUB_TOKEN` is set → `.\bootstrap.ps1` from Windows Terminal/Nushell. Expected: `Installing WezTerm <nightly-version> (portable)...` via the auth path, shortcut self-heals, WezTerm relaunches on the nightly (`wezterm --version` from a tab).

- [ ] **Step 4: Fleet terminfo + live checks**

```bash
# any Linux host / WSL after czu && cza:
infocmp -x wezterm | grep -o 'Su' | head -1    # expect: Su (the new capability)
```

Live on nightly WezTerm: reload toast; tab bar + right status render; SHIFT+click opens links (inputmap re-verify held); Zellij attach on an SSH domain; `-Doctor` shows the snapshot version; `-CheckForUpdates` shows "is current".

---

## Self-review notes

- Spec coverage: workflow (Task 4), bump script (Task 1), auth branch (Task 2), NightlyAsset + entry fields (Task 3), comment sweep (Task 5), docs + rollback entry (Task 6), migration incl. first dispatch + fleet terminfo (Task 8). Early-exit, prune-to-8, cron `0 7 * * 1`, BOM safety, PS 5.1 redirect handling all encoded.
- The bump-script ↔ entry-shape contract is tested twice (Task 1 Step 3 pre-realignment, Task 3 Step 5 post-realignment).
- Types/names consistent: `PrivateRepo`, `NightlyAsset`, `wezterm-nightly-snapshots`, `automation/wezterm-nightly`, `bump-wezterm-nightly.sh <version> <url> <sha256> [file]` used identically across Tasks 1/3/4/8.
