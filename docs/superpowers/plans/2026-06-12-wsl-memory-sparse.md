# WSL Memory Reclaim + Sparse VHD (Document, Don't Automate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Annotate the already-tracked `autoMemoryReclaim`/`sparseVhd` keys in `chezmoi/dot_wslconfig` and document manual VHD disk-reclaim recipes in README, per the approved spec `docs/superpowers/specs/2026-06-12-wsl-memory-sparse-design.md`.

**Architecture:** Comments-and-docs-only change — no values, no automation, no host behavior changes. One annotated config file, one new README troubleshooting entry + one cross-ref sentence, three bookkeeping touches. Single commit (CLAUDE.md rule: README ships in the same commit as the user-facing change), pushed to main.

**Tech Stack:** chezmoi-managed INI, hand-maintained HTML (README.html), markdown.

**Context an engineer needs (from the spec — read it first):**
- `autoMemoryReclaim` and `sparseVhd` belong under `[experimental]` in `.wslconfig`, NOT `[wsl2]` (current MS docs <https://learn.microsoft.com/windows/wsl/wsl-config> list them only there).
- Sparse VHD is upstream-disabled on WSL ≥ 2.5 over data-corruption reports (microsoft/WSL#13075); `wsl --manage --set-sparse true` refuses without `--allow-unsafe`. We deliberately keep the inert `sparseVhd=true` and do NOT automate anything.
- **NEVER run** `wsl --manage ... --set-sparse` (with or without `--allow-unsafe`) during implementation — corruption-prone, and explicitly out of scope.
- Do NOT run `chezmoi apply` on the Windows side; Windows picks the change up via the normal sync workflow later. The Windows `run_onchange` restart-reminder will fire then — expected, no action.
- Repo workflow rules (from `.claude/memory/`): work directly on `main` (no feature branches), push after committing.

---

### Task 1: Annotate `chezmoi/dot_wslconfig`

**Files:**
- Modify: `chezmoi/dot_wslconfig` (whole file — it is 11 lines)

- [ ] **Step 1: Replace the file content**

Replace the entire file with exactly this (pure ASCII, LF line endings, trailing newline). Values are unchanged except `Gradual` → `gradual` (cosmetic doc parity; WSL parses case-insensitively):

```ini
# .wslconfig -- global WSL2 settings for this Windows host. chezmoi-managed
# (deploys to %USERPROFILE%\.wslconfig, Windows only); edit here, not in place.
# Changes take effect only after `wsl --shutdown` from a Windows terminal.
# Reference: https://learn.microsoft.com/windows/wsl/wsl-config
#
# NOTE: autoMemoryReclaim + sparseVhd are [experimental]-section keys, NOT
# [wsl2] -- current MS docs list them only under [experimental]. Keep them
# here. (The networking keys below graduated to [wsl2] in newer WSL but stay
# honored here; this block is seeded verbatim from the working host config.)
[experimental]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
# Returns cached VM memory to Windows as the Linux page cache grows.
# gradual = slow trim; current WSL's default is the more aggressive dropCache.
autoMemoryReclaim=gradual
# Applies to newly created VHDs only, and currently inert: sparse support is
# upstream-disabled on WSL >= 2.5 over data-corruption reports
# (microsoft/WSL#13075); forcing needs --allow-unsafe. Deliberately kept so it
# takes effect if Microsoft re-enables it. To reclaim disk from an EXISTING
# VHD, see README.html > Troubleshooting > "WSL disk keeps growing".
sparseVhd=true
hostAddressLoopback=true
```

- [ ] **Step 2: Verify encoding and line endings**

Run:
```bash
file chezmoi/dot_wslconfig && grep -cP '[^\x00-\x7F]' chezmoi/dot_wslconfig; echo "non-ascii lines: $?"
```
Expected: `ASCII text` (must NOT say "with CRLF line terminators"); grep prints `0` and exits 1 (no non-ASCII matches — exit 1 from grep is the PASS here). Pure-ASCII is the c1150ad precedent for this file.

- [ ] **Step 3: Verify chezmoi gating is intact**

Run:
```bash
chezmoi ignored | grep -Fx '.wslconfig'
```
Expected: prints `.wslconfig` (still ignored on Linux → still Windows-only). Then:
```bash
chezmoi execute-template < chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl | wc -c
```
Expected: `0` (the reminder script still renders empty on Linux; its body OS-gate is intact).

Do NOT commit yet — single commit at the end (Task 5).

---

### Task 2: Add the README troubleshooting entry

**Files:**
- Modify: `README.html` — insert inside `<section id="troubleshooting">`, immediately after the closing `</details>` of the last entry ("`czt` / chezmoi feels slow on WSL", which ends right before the section's `</section>` at ~line 3841)

- [ ] **Step 1: Insert the new entry**

Find this unique anchor near the end of `README.html`:

```html
                            <p>
                                Trade-off: other Windows executables
                                (<code>explorer.exe</code>, VS Code&rsquo;s
                                <code>code</code>) leave the WSL
                                <code>$PATH</code>. Re-add any you want in
                                <code>~/.zshrc.local</code>.
                            </p>
                        </div>
                    </details>
                </section>
```

Insert the following between that `</details>` and `</section>` (matching the 20/24/28-space indentation of sibling entries):

```html
                    <details data-ts>
                        <summary>
                            WSL disk (<code>ext4.vhdx</code>) keeps growing
                            &mdash; freed space never returns to Windows
                        </summary>
                        <div class="ts-body">
                            <p>
                                Symptom: deleting files <em>inside</em> the
                                distro never shrinks the virtual disk on the
                                Windows side. That part is expected: WSL2 VHDs
                                grow on demand but never shrink on their own.
                            </p>
                            <p>
                                The auto-shrink feature (sparse VHD) is
                                <strong>disabled upstream</strong> on WSL
                                &ge;&nbsp;2.5 after data-corruption reports
                                (microsoft/WSL #13075) &mdash; so the tracked
                                <code>sparseVhd=true</code> in
                                <code>chezmoi/dot_wslconfig</code> is currently
                                inert (it self-activates for newly created
                                VHDs if Microsoft re-enables the feature), and
                                <code>wsl --manage &lt;Distro&gt; --set-sparse
                                true</code> refuses unless forced.
                            </p>
                            <p>Find the VHD first (regular PowerShell):</p>
                            <pre><code>Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
  ForEach-Object { Get-ItemProperty $_.PSPath } |
  Select-Object DistributionName, BasePath</code></pre>
                            <p>
                                <strong>Safe one-time reclaim</strong> (admin
                                PowerShell; manual maintenance &mdash; the repo
                                deliberately does not automate this):
                            </p>
                            <pre><code>wsl --shutdown
Optimize-VHD -Path "&lt;BasePath&gt;\ext4.vhdx" -Mode Full</code></pre>
                            <p>
                                No Hyper-V module
                                (<code>Optimize-VHD</code> missing)? Use the
                                always-available diskpart route (still admin):
                            </p>
                            <pre><code>wsl --shutdown
diskpart
# inside diskpart:
select vdisk file="&lt;BasePath&gt;\ext4.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit</code></pre>
                            <p>
                                <strong>Unsafe opt-in</strong> &mdash; only if
                                you accept the corruption risk Microsoft
                                disabled this over (read-only filesystems, lost
                                files). Back up first, then force sparse mode
                                so the disk auto-returns freed space:
                            </p>
                            <pre><code>wsl --export &lt;Distro&gt; D:\backup\&lt;Distro&gt;.tar
wsl --manage &lt;Distro&gt; --set-sparse true --allow-unsafe</code></pre>
                            <p>
                                RAM is the separate, already-solved half:
                                <code>autoMemoryReclaim=gradual</code> in the
                                tracked <code>.wslconfig</code> returns cached
                                VM memory to Windows automatically &mdash; no
                                action needed.
                            </p>
                        </div>
                    </details>
```

- [ ] **Step 2: Verify the entry count went 19 → 20**

> **Plan correction (found during execution):** the pre-change baseline was **19** entries, not 17 — CLAUDE.md's "(17 entries)" was already stale by two before this change. Count expectations in Tasks 2/4/5 updated accordingly.

Run:
```bash
grep -c '<details data-ts>' README.html
```
Expected: `20`. (No `README.js` change needed — the filter bar's `ts-count` counts `[data-ts]` nodes dynamically, `docs/README/README.js:402`.)

---

### Task 3: Add the §setup-wsl cross-reference sentence

**Files:**
- Modify: `README.html` — the "WSL config is tracked &amp; deployed" `note-row` paragraph in §setup-wsl (~line 2310)

- [ ] **Step 1: Extend the paragraph**

Find this unique anchor (end of the "WSL config is tracked & deployed" paragraph):

```html
                        <code>wsl-config</code> prints the reminder, and a
                        chezmoi <code>run_onchange</code> script prints it on
                        Windows when <code>.wslconfig</code> changes.
                    </p>
```

Replace with:

```html
                        <code>wsl-config</code> prints the reminder, and a
                        chezmoi <code>run_onchange</code> script prints it on
                        Windows when <code>.wslconfig</code> changes. The
                        tracked <code>.wslconfig</code> already opts into
                        dynamic memory
                        (<code>autoMemoryReclaim=gradual</code> returns cached
                        RAM to Windows) and pre-opts into sparse VHDs
                        (<code>sparseVhd=true</code> &mdash; currently disabled
                        upstream; see
                        <a href="#troubleshooting">Troubleshooting</a>
                        &ldquo;WSL disk keeps growing&rdquo; for manual disk
                        reclaim).
                    </p>
```

- [ ] **Step 2: Spot-check rendering**

Run:
```bash
python3 - <<'EOF'
from html.parser import HTMLParser
class P(HTMLParser):
    def __init__(self): super().__init__(); self.stack=[]
    def handle_starttag(self,t,a):
        if t not in ('br','hr','img','input','meta','link','li','p'): self.stack.append(t)
    def handle_endtag(self,t):
        while self.stack and self.stack[-1]!=t and self.stack[-1] in ('li','p'): self.stack.pop()
        if self.stack and self.stack[-1]==t: self.stack.pop()
p=P(); p.feed(open('README.html',encoding='utf-8').read())
print("leftover unclosed:", [t for t in p.stack if t in ('details','section','div','pre','code','summary')])
EOF
```
Expected: `leftover unclosed: []` (no unbalanced `details`/`section`/`div`/`pre`/`code`/`summary` tags). Also open `README.html` in a browser if available: the new entry appears last under Troubleshooting, expands/collapses, and the filter bar count shows 18.

---

### Task 4: Bookkeeping (CLAUDE.md count, file-care note, changelog row)

**Files:**
- Modify: `CLAUDE.md:42` (the "Where things are documented" table)
- Modify: `docs/claude/file-care.md:50` (the `chezmoi/dot_wslconfig` entry)
- Modify: `CLAUDE_CHANGELOG.md` (append one table row at the end)

- [ ] **Step 1: Bump the CLAUDE.md troubleshooting count**

In `CLAUDE.md`, change:
```
| Troubleshooting (17 entries) | `README.html` §troubleshooting |
```
to:
```
| Troubleshooting (20 entries) | `README.html` §troubleshooting |
```
(20, not 18: the "17" was stale — the section already had 19 entries before this change.)

- [ ] **Step 2: Extend the file-care entry**

In `docs/claude/file-care.md`, the `chezmoi/dot_wslconfig` bullet (line 50) currently ends with:
```
Editing it triggers `chezmoi/.chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl` (Windows-only `run_onchange`) which prints the `wsl --shutdown` restart reminder on apply.
```
Append this sentence to the same bullet (same line or a continuation of it):
```
**`sparseVhd=true` and `autoMemoryReclaim=gradual` are deliberate, annotated in-file** — sparse is inert on WSL >= 2.5 (upstream-disabled over corruption reports, microsoft/WSL#13075; self-activates if re-enabled), reclaim pins slow-trim over the `dropCache` default; do NOT "clean them up" or move them to `[wsl2]` (they're `[experimental]`-section keys). Spec: `docs/superpowers/specs/2026-06-12-wsl-memory-sparse-design.md`.
```

- [ ] **Step 3: Append the CLAUDE_CHANGELOG.md row**

Append this single row to the end of the table in `CLAUDE_CHANGELOG.md`:

```markdown
| Annotated `chezmoi/dot_wslconfig` after a request to "add dynamic memory + sparse VHD": investigation showed BOTH keys already tracked under `[experimental]` (the correct section — current MS docs list `autoMemoryReclaim`/`sparseVhd` only there, NOT `[wsl2]` as commonly pasted), and sparse VHD upstream-disabled on WSL >= 2.5 over data-corruption reports (microsoft/WSL#13075; `--set-sparse` refuses without `--allow-unsafe`; this host's ext4.vhdx verified not-sparse). User-approved decision: **document, don't automate** — values unchanged (only `Gradual` → `gradual` casing), comments explain why each key exists, why `sparseVhd` is deliberately kept though inert (self-activates if re-enabled), and where manual reclaim lives. No bootstrap/make changes. Editing the file makes the Windows `run_onchange` `wsl --shutdown` reminder fire on next Windows apply (expected). Spec: `docs/superpowers/specs/2026-06-12-wsl-memory-sparse-design.md`. | **Yes** | New §troubleshooting entry "WSL disk (`ext4.vhdx`) keeps growing — freed space never returns to Windows": why VHDs never shrink, the upstream sparse disablement, find-the-VHD registry one-liner, safe `Optimize-VHD` + diskpart reclaim recipes (admin, manual maintenance), clearly-flagged `--allow-unsafe` opt-in with `wsl --export` backup first, and a note that RAM reclaim is already handled. §setup-wsl "WSL config is tracked & deployed" paragraph gains a cross-ref sentence (memory opt-in + sparse pre-opt-in → troubleshooting pointer). CLAUDE.md troubleshooting count corrected 17 → 20 (the stale 17 predated this change — the section already held 19); file-care.md `dot_wslconfig` entry marks both keys deliberate (don't clean up / don't move to `[wsl2]`). |
```

---

### Task 5: Verify everything, single commit, push

**Files:** none new — commits Tasks 1–4.

- [ ] **Step 1: Run the full verification battery**

```bash
file chezmoi/dot_wslconfig                                  # ASCII text, no CRLF
grep -c '<details data-ts>' README.html                     # 20
chezmoi ignored | grep -Fx '.wslconfig'                     # prints .wslconfig
git diff --stat                                             # exactly 5 files:
# chezmoi/dot_wslconfig, README.html, CLAUDE.md,
# docs/claude/file-care.md, CLAUDE_CHANGELOG.md
git diff chezmoi/dot_wslconfig | grep '^[+-][^+-]' | grep -v '^\-#\|^+#'   # value lines:
# expect ONLY -autoMemoryReclaim=Gradual / +autoMemoryReclaim=gradual
```
Expected outputs as annotated. The last check proves no semantic value changed besides the casing.

- [ ] **Step 2: Single commit (README rides with the user-facing change, per CLAUDE.md) and push**

```bash
git add chezmoi/dot_wslconfig README.html CLAUDE.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs(wsl): annotate memory-reclaim + sparse-VHD keys; add disk-reclaim troubleshooting

autoMemoryReclaim=gradual + sparseVhd=true were already tracked in
dot_wslconfig under [experimental] (the correct section per current MS
docs -- not [wsl2]). Sparse VHD is upstream-disabled on WSL >= 2.5 over
data-corruption reports (microsoft/WSL#13075), so per the approved spec
(docs/superpowers/specs/2026-06-12-wsl-memory-sparse-design.md) this
documents instead of automating: in-file comments, a README
troubleshooting entry with safe Optimize-VHD/diskpart reclaim recipes
plus the flagged --allow-unsafe opt-in, and a setup-wsl cross-ref.
Values unchanged (Gradual -> gradual casing only); no automation added.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```
Expected: clean commit on `main`, push succeeds.

---

## Self-review notes (done at plan-writing time)

- Spec coverage: Part A → Task 1; Part B (troubleshooting entry) → Task 2; Part B (cross-ref) → Task 3; Part C bookkeeping → Task 4; spec's Verification section → Tasks 1–3 verify steps + Task 5 battery. "Not changing" list honored (no makefile/bootstrap/wsl.conf tasks).
- No placeholders; all file content is verbatim-ready. `<BasePath>` / `<Distro>` / `<your-PAT>`-style placeholders inside README code blocks are the repo's established user-facing convention, not plan gaps.
- HTML entities (`&mdash;`, `&ldquo;`, `&ge;`) and 20/24/28-space indentation match sibling entries; `<` inside `<pre><code>` escaped as `&lt;`.
