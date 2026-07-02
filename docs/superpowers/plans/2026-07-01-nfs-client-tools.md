# NFS Client Tooling (dev-only, non-WSL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install client-side NFS tooling (`nfs-utils`, `nfs4-acl-tools`, `autofs`) on `dev_machine` hosts only, skipping WSL hosts entirely.

**Architecture:** A new `LINUX_NFS_PACKAGES` variable in `makefile/packages.mk`, appended to `LINUX_OPTIONAL_PACKAGES` only when `IS_WSL=false` (already exported by `scope.mk`). The existing `packages-optional` machinery (dev-only gating, `rpm -q` fast path, per-package `|| true`) handles installation. `scripts/gen-tool-memory.sh` gains a stanza so the auto-generated TOOLS block lists the group; README.html documents the chips + WSL exclusion + autofs activation.

**Tech Stack:** GNU Make, bash, dnf (EL9), HTML (hand-formatted, prettier-style wrapping).

**Spec:** `docs/superpowers/specs/2026-07-01-nfs-client-tools-design.md`

## Global Constraints

- Working directory for all commands: repo root `~/.local/share/chezmoi`.
- `make` must be invoked as `make -C makefile ...` (the makefile lives in `makefile/`; a bare `make` at root fails).
- This host IS a WSL dev machine (`IS_WSL=true` by default) — use `IS_WSL=false` command-line overrides to exercise the non-WSL path in dry-runs. NEVER run a real `make packages` install in this plan; verification is dry-run (`make -n`) + text checks only.
- `makefile/packages.mk` recipe lines are TAB-indented (make hard requirement).
- `scripts/gen-tool-memory.sh` must stay LF-only, git mode 100755, `shfmt -i 2`-clean (check-invariants enforces all three; the `post-edit-guard.sh` hook auto-repairs CRLF/mode after edits).
- The `<!-- TOOLS:START/END -->` block in `chezmoi/private_dot_claude/CLAUDE.md` is generator-owned — regenerate via `bash scripts/gen-tool-memory.sh`, never hand-edit inside.
- Every commit triggers the pre-commit invariant check; it must pass (do not `--no-verify`).
- README.html + CLAUDE_CHANGELOG.md updates land in the same commit as each other (repo convention).
- No NFS server capability, no autofs enablement/config, no `check-invariants.sh` changes, no Windows-side changes (all out of scope per spec).

---

### Task 1: `packages.mk` — WSL-gated NFS client package group

**Files:**
- Modify: `makefile/packages.mk` (variable block after the `LINUX_OPTIONAL_PACKAGES` list ending `cockpit-packagekit cockpit-podman`, i.e. before the `.PHONY: packages ...` line; recipe line inside `packages-optional`)

**Interfaces:**
- Consumes: `IS_WSL` (`true`/`false` string, computed + exported by `makefile/scope.mk`), `LINUX_OPTIONAL_PACKAGES`, `packages-optional` recipe.
- Produces: `LINUX_NFS_PACKAGES := nfs-utils nfs4-acl-tools autofs` — Task 2's generator stanza extracts this exact variable name from the file text (not make-evaluated, so the conditional append is invisible to it and the generated block stays host-independent).

- [ ] **Step 1: Baseline check (must FAIL to find the packages)**

Run:
```bash
make -C makefile -n packages-optional MODE=dev IS_WSL=false | grep 'for pkg in' | grep -c 'nfs-utils'
```
Expected: `0` (grep exits 1) — NFS packages are not in the optional list yet.

- [ ] **Step 2: Add the package group**

In `makefile/packages.mk`, insert between the end of the `LINUX_OPTIONAL_PACKAGES` definition (line ending `cockpit-packagekit cockpit-podman`) and the `.PHONY: packages packages-core packages-epel packages-optional` line:

```make
# NFS CLIENT GROUP — dev-only like everything in this file, and additionally
# skipped on WSL hosts (IS_WSL comes from scope.mk). Client-side tooling only:
# mount/inspect/debug NFS shares served elsewhere — this repo never turns a
# dev box into an NFS server (no nfs-server/exportfs/rpcbind service wiring).
#   nfs-utils      — mount.nfs, showmount, nfsstat, nfsiostat, mountstats (BaseOS)
#   nfs4-acl-tools — nfs4_getfacl / nfs4_setfacl / nfs4_editfacl (AppStream)
#   autofs         — on-demand automounter; installed but NOT enabled/configured
#                    (maps are per-host /etc config this repo doesn't manage;
#                    activate per host: write maps, then
#                    `sudo systemctl enable --now autofs`)
# The WSL exclusion matches the docker-engine/cockpit/rsyslog-service policy:
# NFS on WSL2 is out of scope. The conditional append keeps the group out of
# LINUX_OPTIONAL_PACKAGES entirely on WSL; packages-optional prints a skip
# line there so provision output stays auditable. gen-tool-memory.sh extracts
# this variable by name for the TOOLS memory block — rename it and the
# generator stanza must move with it.
LINUX_NFS_PACKAGES := nfs-utils nfs4-acl-tools autofs

ifeq ($(IS_WSL),false)
LINUX_OPTIONAL_PACKAGES += $(LINUX_NFS_PACKAGES)
endif
```

- [ ] **Step 3: Add the skip-visibility line to the recipe**

In the `packages-optional` recipe, directly after the line
`	@printf '==> Optional packages (best-effort)\n'`, insert (TAB-indented):

```make
	@if [ "$(IS_WSL)" = "true" ]; then printf '  skipping NFS client group on WSL (%s)\n' "$(LINUX_NFS_PACKAGES)"; fi
```

- [ ] **Step 4: Verify both gating directions via dry-run**

Run (this host is WSL, so no override = the WSL path):
```bash
make -C makefile -n packages-optional MODE=dev | grep 'for pkg in' | grep -c 'nfs-utils'
```
Expected: `0` (exit 1) — group absent from the install loop on WSL.

```bash
make -C makefile -n packages-optional MODE=dev | grep -c '\[ "true" = "true" \]'
```
Expected: `1` — the skip guard expanded with IS_WSL=true, so the skip line fires at run time.

```bash
make -C makefile -n packages-optional MODE=dev IS_WSL=false | grep 'for pkg in' | grep -c 'nfs-utils'
```
Expected: `1` — group present in the install loop off WSL.

```bash
make -C makefile packages MODE=prod
```
Expected output contains: `skipping system packages (MODE=prod, INSTALL_PACKAGES=false)` — prod stays a no-op (this target is safe to run for real; it only echoes).

- [ ] **Step 5: Confirm the sync-tool-memory hook produced no memory drift**

The PostToolUse hook regenerates the TOOLS block on packages.mk edits, but the generator doesn't know `LINUX_NFS_PACKAGES` yet, so nothing should change:
```bash
git status --porcelain
```
Expected: only ` M makefile/packages.mk` (plus the untracked plan file if not yet committed). If `chezmoi/private_dot_claude/CLAUDE.md` shows modified here, STOP — the generator picked something up unexpectedly; inspect `git diff chezmoi/private_dot_claude/CLAUDE.md` before proceeding.

- [ ] **Step 6: Commit**

```bash
git add makefile/packages.mk
git commit -m "feat(packages): NFS client group (nfs-utils, nfs4-acl-tools, autofs) — dev-only, skipped on WSL

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EcSCBeCF79HeSLcqVKX7T9"
```
Expected: pre-commit invariant check passes (the TOOLS drift check is a no-op because the generator ignores the new variable until Task 2).

---

### Task 2: `gen-tool-memory.sh` stanza + regenerated TOOLS block

**Files:**
- Modify: `scripts/gen-tool-memory.sh` (after the existing dnf stanza — the `paste -sd' ' - | sed 's/^/- /'` line — and before `printf '\n<!-- TOOLS:END -->\n'`)
- Modify (generated): `chezmoi/private_dot_claude/CLAUDE.md` (regenerated TOOLS block)

**Interfaces:**
- Consumes: the literal variable name `LINUX_NFS_PACKAGES` in `makefile/packages.mk` (from Task 1).
- Produces: a `### System packages (dnf, dev-only, non-WSL)` section inside the `<!-- TOOLS:START/END -->` block. `check-invariants.sh` diffs generator output against the committed file, so both must land in the same commit.

- [ ] **Step 1: Baseline check (must FAIL to find the section)**

```bash
rg -c 'non-WSL' chezmoi/private_dot_claude/CLAUDE.md
```
Expected: no output (exit 1) — section doesn't exist yet.

- [ ] **Step 2: Add the extraction stanza**

In `scripts/gen-tool-memory.sh`, inside `emit_block()`, directly after the existing dnf stanza (the block that starts `# 3. dnf optional packages` and ends `... paste -sd' ' - | sed 's/^/- /'`) and before `printf '\n<!-- TOOLS:END -->\n'`, insert:

```bash

  # 4. dnf NFS client group — dev-only AND skipped on WSL (the IS_WSL append
  # in packages.mk). Extracted by variable name from the file text, so the
  # output is host-independent (never make-evaluated).
  printf '\n### System packages (dnf, dev-only, non-WSL)\n'
  awk '/^LINUX_NFS_PACKAGES[[:space:]]*:=/{f=1}
       f{print}
       f && $0 !~ /\\$/{exit}' "$MK/packages.mk" |
    sed -E 's/^LINUX_NFS_PACKAGES[[:space:]]*:=//; s/\\//g' |
    tr ' ' '\n' | grep -vE '^$' | LC_ALL=C sort -u | paste -sd' ' - | sed 's/^/- /'
```

Then renumber the splice comment near the bottom of the file from `# 4. Splice the block` to `# 5. Splice the block`.

- [ ] **Step 3: Regenerate and verify the block**

```bash
bash scripts/gen-tool-memory.sh
rg -A1 'non-WSL' chezmoi/private_dot_claude/CLAUDE.md
```
Expected:
```
### System packages (dnf, dev-only, non-WSL)
- autofs nfs-utils nfs4-acl-tools
```
(`LC_ALL=C sort -u` order: `-` sorts before `4`, so `nfs-utils` precedes `nfs4-acl-tools`.)

- [ ] **Step 4: Verify script hygiene (LF, mode, shfmt, shellcheck)**

```bash
file scripts/gen-tool-memory.sh                      # must NOT say "with CRLF line terminators"
git ls-files --stage scripts/gen-tool-memory.sh      # must show 100755
shfmt -d -i 2 scripts/gen-tool-memory.sh             # no output = clean
shellcheck -S warning scripts/gen-tool-memory.sh     # no output = clean
```

- [ ] **Step 5: Run the full invariant check**

```bash
make -C makefile lint MODE=prod
```
Expected: all green, including `✓ TOOLS block matches gen-tool-memory.sh output`.

- [ ] **Step 6: Commit (script + regenerated memory together)**

```bash
git add scripts/gen-tool-memory.sh chezmoi/private_dot_claude/CLAUDE.md
git commit -m "feat(memory): TOOLS block gains 'dnf, dev-only, non-WSL' section for the NFS client group

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EcSCBeCF79HeSLcqVKX7T9"
```
Expected: pre-commit invariant check passes (drift check now sees matching generator output + committed block).

---

### Task 3: README.html chips + card note + troubleshooting entry + changelog row

**Files:**
- Modify: `README.html` — "File transfer" tool-card (the `<article class="tool-card tilt cat-transfer" data-cat="transfer">` block, chips `rclone`/`croc`/`rsync`/`miniserve`), and the `#troubleshooting` section (insert after the LAST `</details>` — the "C / C++ toolchain" entry — before `</section>`)
- Modify: `CLAUDE.md` (repo root) — the "Where things are documented" row `| Troubleshooting (20 entries) | ... |` is already stale (23 entries exist); update the count to 24
- Modify: `CLAUDE_CHANGELOG.md` — append one row

**Interfaces:**
- Consumes: package names + semantics fixed in Task 1 (`nfs-utils`, `nfs4-acl-tools`, `autofs`; skip message text `skipping NFS client group on WSL`).
- Produces: user-facing docs only; nothing downstream consumes this.

- [ ] **Step 1: Add three chips to the File transfer card**

In `README.html`, inside the File transfer card's `<div class="chips">`, after the `miniserve` chip's closing `>` and before the `</div>`, insert (match the file's existing prettier-style wrapping — 32-space base indent for `<span`):

```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="NFS client tools — mount.nfs, showmount, nfsstat, nfsiostat"
                                    >nfs-utils <small>(dnf)</small
                                    ><span class="sr-only">
                                        — NFS client tools: mount.nfs,
                                        showmount, nfsstat, nfsiostat
                                        (dev_machine only via dnf; skipped on
                                        WSL)</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="NFSv4 ACL tools — nfs4_getfacl / nfs4_setfacl"
                                    >nfs4-acl-tools <small>(dnf)</small
                                    ><span class="sr-only">
                                        — NFSv4 ACL tools: nfs4_getfacl /
                                        nfs4_setfacl (dev_machine only via dnf;
                                        skipped on WSL)</span
                                    ></span
                                >
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="On-demand NFS automounter (installed, not enabled)"
                                    >autofs <small>(dnf)</small
                                    ><span class="sr-only">
                                        — on-demand automounter daemon
                                        (dev_machine only via dnf; skipped on
                                        WSL; installed but not enabled)</span
                                    ></span
                                >
```

- [ ] **Step 2: Add the card note**

Directly after that same card's closing `</div>` (of `class="chips"`), before `</article>`, insert:

```html
                            <p class="card-note">
                                The NFS client group (<code>nfs-utils</code>,
                                <code>nfs4-acl-tools</code>,
                                <code>autofs</code>) is
                                <span class="badge dev">dev_machine</span> only
                                and <strong>skips WSL hosts entirely</strong>.
                                <code>autofs</code> is installed but never
                                enabled &mdash; write your maps
                                (<code>/etc/auto.master</code>&hellip;), then
                                <code>sudo systemctl enable --now autofs</code>.
                            </p>
```

- [ ] **Step 3: Add the troubleshooting entry**

In the `#troubleshooting` section, after the closing `</details>` of the "C / C++ toolchain" entry (the last one, immediately before `</section>`), insert:

```html
                    <details data-ts>
                        <summary>
                            NFS tools (<code>showmount</code>,
                            <code>nfsstat</code>, <code>autofs</code>) are
                            missing on a dev host
                        </summary>
                        <div class="ts-body">
                            <p>
                                The NFS client group (<code>nfs-utils</code>,
                                <code>nfs4-acl-tools</code>,
                                <code>autofs</code>) installs via dnf on
                                <span class="badge dev">dev_machine</span> only
                                &mdash; and is
                                <strong>skipped entirely on WSL hosts</strong>
                                by design (same policy as the Docker engine and
                                Cockpit: provision prints
                                <code>skipping NFS client group on WSL</code>).
                                On a native dev host, re-run
                                <code>make -C makefile MODE=dev packages</code>.
                            </p>
                            <p>
                                <code>autofs</code> is installed but
                                <strong>not enabled</strong> &mdash; an
                                automounter with no maps does nothing. Write
                                your maps first, then
                                <code>sudo systemctl enable --now autofs</code>.
                            </p>
                        </div>
                    </details>
```

- [ ] **Step 4: Fix the troubleshooting count in root CLAUDE.md**

In `CLAUDE.md` (repo root, "Where things are documented" table), change:
`| Troubleshooting (20 entries) | ... |` → `| Troubleshooting (24 entries) | ... |`
(23 entries pre-existed the stale "20"; this change adds the 24th.)

- [ ] **Step 5: Append the CLAUDE_CHANGELOG.md row**

Append to the end of the table in `CLAUDE_CHANGELOG.md`:

```markdown
| Added an **NFS client group** to the dev toolbelt: `LINUX_NFS_PACKAGES := nfs-utils nfs4-acl-tools autofs` in `makefile/packages.mk`, appended to `LINUX_OPTIONAL_PACKAGES` only when `IS_WSL=false` (first WSL-conditional package group; `IS_WSL` already exported by `scope.mk`) — same WSL-exclusion policy as docker-engine/cockpit/rsyslog-service, with a `skipping NFS client group on WSL (…)` line in `packages-optional` output. Client-side only (no nfs-server/exportfs/rpcbind wiring); `autofs` is installed but never enabled/configured (maps are per-host). `gen-tool-memory.sh` gains a stanza emitting a `### System packages (dnf, dev-only, non-WSL)` TOOLS-block section. Spec: `docs/superpowers/specs/2026-07-01-nfs-client-tools-design.md`. | **Yes** | Three `(dnf)` chips (`nfs-utils`, `nfs4-acl-tools`, `autofs`) + a `card-note` (WSL skip + autofs activation) on the `#toolbelt` "File transfer" card; new `#troubleshooting` entry "NFS tools … missing on a dev host" (WSL-by-design + `systemctl enable --now autofs` hint). Root CLAUDE.md troubleshooting count refreshed (was stale at 20; now 24). |
```

- [ ] **Step 6: Verify the docs edits**

```bash
rg -c '<details data-ts>' README.html          # expect 24
rg -c 'nfs-utils' README.html                  # expect >= 3 (chip + card-note + troubleshooting)
rg -n 'skipping NFS client group' README.html  # expect 1 hit (troubleshooting entry)
rg -n 'Troubleshooting \(24 entries\)' CLAUDE.md   # expect 1 hit
tail -1 CLAUDE_CHANGELOG.md | head -c 60           # expect the new row's opening text
```

- [ ] **Step 7: Commit**

```bash
git add README.html CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "docs(readme): NFS client group — chips, card note, troubleshooting entry, changelog row

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EcSCBeCF79HeSLcqVKX7T9"
```
Expected: pre-commit invariant check passes.

---

### Task 4: Final verification sweep

**Files:** none modified.

**Interfaces:**
- Consumes: everything above.
- Produces: the done-report evidence.

- [ ] **Step 1: Full lint**

```bash
make -C makefile lint MODE=prod
```
Expected: `✓ all invariant checks passed`.

- [ ] **Step 2: Re-run the gating dry-runs (regression check)**

```bash
make -C makefile -n packages-optional MODE=dev | grep 'for pkg in' | grep -c 'nfs-utils'            # 0 (WSL host)
make -C makefile -n packages-optional MODE=dev IS_WSL=false | grep 'for pkg in' | grep -c 'nfs-utils' # 1
make -C makefile packages MODE=prod                                                                  # prints the prod skip line
```

- [ ] **Step 3: Confirm clean tree + note the deploy step**

```bash
git status --porcelain   # empty
git log --oneline -4     # the three feature commits + spec commit visible
```
The machine-level memory change (`chezmoi/private_dot_claude/CLAUDE.md`) reaches `~/.claude/CLAUDE.md` on the next `cza` (chezmoi apply) — mention this in the done-report; do not run `cza` unprompted.
