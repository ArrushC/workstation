# Install-time Binary Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hard-fail a binary install when the produced binary can't run on this
host (wrong file, wrong arch, absent loader/lib, or glibc too new), instead of
silently stamping a dud.

**Architecture:** One non-executing helper `makefile/lib/verify-binary.sh`
(ELF+arch → ldd → glibc-floor) is `&&`-chained onto the install command by the
`EGET_TOOL`/`TOOL` macros, so verify failure aborts the recipe before the stamp
is written. Static binaries pass (run anywhere). Verify is automatic for all
eget tools and opt-in (per ELF tool) for `TOOL`.

**Tech Stack:** GNU Make, bash, coreutils (`od`,`head`,`sort -V`), `ldd`
(glibc), optional binutils (`objdump`/`readelf`).

## Global Constraints

- **Shell files are LF line endings, git mode 100755**, shellcheck-clean
  (`-S warning`), `shfmt -i 2`-clean, gitleaks-clean. New `makefile/lib/*.sh`
  files are auto-covered by `scripts/check-invariants.sh` globs — no edit to
  that script, but mode/format must be correct.
- **Non-executing only** — never run the installed binary (TUI-safe).
- **Static binaries MUST pass** — most `--asset musl` tools are static; the gate
  must not false-fail them.
- **Hard fail** — verify failure exits non-zero; no stamp; `make` stops.
- **Accept degradation** — when neither `objdump` nor `readelf` exists (minimal
  prod), skip the glibc-floor sub-check with a note; keep ELF+arch+ldd.
- **No README update** (internal makefile/lib change). Docs go to
  `docs/claude/invariants.md` + `docs/claude/file-care.md`.
- **Sandbox install recipe** (sudo-free, live tools untouched), used in tests:
  `cd makefile && make <target> MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps`
  with `GITHUB_TOKEN="$(gh auth token)"` exported (eget rate limit).

---

### Task 1: The check + its unit test (`verify-binary.sh`)

**Files:**
- Create: `makefile/lib/verify-binary.sh`
- Create: `makefile/lib/test-verify-binary.sh`

**Interfaces:**
- Produces:
  - `decide <is_elf:1|0> <arch_ok:1|0> <ldd_class> <floor> <host_glibc>` — pure;
    `ldd_class` ∈ {`static`,`ok`,`missing:<name>`}; prints reason on FAIL;
    returns 0 PASS / 1 FAIL.
  - `glibc_le <a.b> <c.d>` — pure; returns 0 if `a.b <= c.d`.
  - CLI `verify-binary.sh <path>` — exit 0 runs-here / exit 1 cannot (prints why).

- [ ] **Step 1: Write the failing test**

Create `makefile/lib/test-verify-binary.sh`:

```bash
#!/usr/bin/env bash
# test-verify-binary.sh — asserts verify-binary.sh's pure decision logic across
# every branch, plus one real-binary smoke. Mirrors .claude/hooks/test-hooks.sh.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=/dev/null
source ./verify-binary.sh # main() is guarded, so sourcing does not run it

fail=0
ok() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
no() {
  printf '  \xe2\x9c\x97 %s\n' "$1"
  fail=1
}

# expect <want-exit> <desc> <decide-args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  decide "$@" >/dev/null 2>&1 || got=1
  if [ "$got" = "$want" ]; then ok "$desc"; else no "$desc (want $want got $got)"; fi
}

# decide() branches
expect 1 "not-ELF -> fail" 0 1 ok "" 2.34
expect 1 "wrong-arch -> fail" 1 0 static "" 2.34
expect 0 "static right-arch -> pass" 1 1 static "" 2.34
expect 1 "missing lib -> fail" 1 1 missing:libc.musl-x86_64.so.1 "" 2.34
expect 1 "glibc floor too high -> fail" 1 1 ok 2.34 2.28
expect 0 "glibc floor ok -> pass" 1 1 ok 2.17 2.34
expect 0 "floor undeterminable -> pass (degraded)" 1 1 ok "" 2.34

# glibc_le()
glibc_le 2.17 2.34 && ok "glibc_le 2.17<=2.34" || no "glibc_le 2.17<=2.34"
glibc_le 2.34 2.34 && ok "glibc_le equal" || no "glibc_le equal"
if glibc_le 2.40 2.34; then no "glibc_le 2.40<=2.34 must be false"; else ok "glibc_le 2.40>2.34"; fi

# real-binary smoke: a known-good host binary passes
if ./verify-binary.sh /bin/true >/dev/null 2>&1; then ok "real /bin/true -> pass"; else no "real /bin/true -> pass"; fi

if [ "$fail" = 0 ]; then
  echo "all verify-binary tests passed"
else
  echo "FAILURES"
  exit 1
fi
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd makefile && bash lib/test-verify-binary.sh
```
Expected: FAIL — `./verify-binary.sh: No such file or directory` (helper not written yet).

- [ ] **Step 3: Write the implementation**

Create `makefile/lib/verify-binary.sh`:

```bash
#!/usr/bin/env bash
# verify-binary.sh — fail-fast capability check: can this freshly-installed
# binary actually run on THIS host? Non-executing (static inspection only), so
# it is safe for TUI tools. Called by the install helpers via the TOOL /
# EGET_TOOL macros, gating the install stamp.
#
# Usage:
#   verify-binary.sh <path-to-installed-binary>
#     exit 0  -> runs here (or static -> runs anywhere)
#     exit 1  -> cannot run here; prints the file, host glibc/arch, and reason
#
# Checks, cheapest first (short-circuits):
#   1. ELF magic + e_machine == host arch    (catches wrong-file / wrong-arch)
#   2. ldd: static -> PASS; any "not found" -> FAIL  (absent loader/lib)
#   3. glibc floor: max required GLIBC_x.y <= host glibc  (built too new)
#      -- needs objdump/readelf (binutils); skipped with a note if absent.
#
# Pure decision logic is decide()/glibc_le(); gather helpers wrap the system
# tools. The bottom `if main` guard lets test-verify-binary.sh source this file
# and unit-test the pure functions without running main. Assumes little-endian
# ELF (the x86-64/aarch64 fleet).

set -euo pipefail

# ---- pure decision helpers (unit-tested) ------------------------------------

# glibc_le <a.b> <c.d> -- 0 (true) if version a.b <= c.d, else 1.
glibc_le() {
  [ "$1" = "$2" ] && return 0
  local lo
  lo=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
  [ "$lo" = "$1" ]
}

# decide <is_elf> <arch_ok> <ldd_class> <floor> <host_glibc>
#   ldd_class: static | ok | missing:<name>
#   floor/host_glibc: x.y, or empty when undeterminable
# Prints a reason on FAIL; returns 0 PASS / 1 FAIL.
decide() {
  local is_elf="$1" arch_ok="$2" ldd_class="$3" floor="$4" host="$5"
  if [ "$is_elf" != 1 ]; then
    echo "not an ELF executable (wrong file extracted?)"
    return 1
  fi
  if [ "$arch_ok" != 1 ]; then
    echo "built for a different CPU architecture than this host"
    return 1
  fi
  case "$ldd_class" in
  static) return 0 ;;
  ok) : ;;
  missing:*)
    echo "requires ${ldd_class#missing:}, which is absent on this host"
    return 1
    ;;
  *)
    echo "unrecognised ldd classification: $ldd_class"
    return 1
    ;;
  esac
  if [ -n "$floor" ] && [ -n "$host" ]; then
    if ! glibc_le "$floor" "$host"; then
      echo "needs GLIBC_$floor but this host provides only GLIBC_$host"
      return 1
    fi
  fi
  return 0
}

# ---- gather helpers (wrap system tools; covered by the real-binary smoke) ----

# read_is_elf <path> -- 0 if the first 4 bytes are the ELF magic.
read_is_elf() {
  local magic
  magic=$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

# elf_arch <path> -- normalized e_machine token (low byte at offset 18).
elf_arch() {
  local m
  m=$(od -An -tu1 -j18 -N1 "$1" 2>/dev/null | tr -d ' ')
  case "$m" in
  62) echo x86-64 ;;   # 0x3e EM_X86_64
  183) echo aarch64 ;; # 0xb7 EM_AARCH64
  *) echo other ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) echo x86-64 ;;
  aarch64 | arm64) echo aarch64 ;;
  *) echo other ;;
  esac
}

# classify_ldd <path> -- echo: static | ok | missing:<name>
classify_ldd() {
  local out
  out=$(ldd "$1" 2>&1) || true # ldd exits non-zero for static / wrong-arch
  if printf '%s' "$out" | grep -qiE 'not a dynamic executable|statically linked'; then
    echo static
    return 0
  fi
  local missing
  missing=$(printf '%s\n' "$out" | awk '/not found/ {print $1; exit}')
  if [ -n "$missing" ]; then
    echo "missing:$missing"
    return 0
  fi
  echo ok
}

# max_glibc_floor <path> -- max required GLIBC_x.y (e.g. 2.34), or empty when no
# binutils tool is present (degraded) or there are no versioned glibc symbols.
max_glibc_floor() {
  local dumper=""
  if command -v objdump >/dev/null 2>&1; then
    dumper="objdump -T"
  elif command -v readelf >/dev/null 2>&1; then
    dumper="readelf --dyn-syms"
  else
    return 0
  fi
  $dumper "$1" 2>/dev/null |
    grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' |
    sed 's/GLIBC_//' |
    sort -V | tail -1
}

# host_glibc -- e.g. "ldd (GNU libc) 2.34" -> 2.34
host_glibc() {
  ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?$'
}

# ---- main -------------------------------------------------------------------

main() {
  local bin="${1:?verify-binary.sh: usage: $0 <path-to-binary>}"
  if [ ! -e "$bin" ]; then
    printf '  \xe2\x9c\x97 verify %s: file missing (install did not place it)\n' "$bin" >&2
    exit 1
  fi

  local is_elf=0 arch_ok=0 ldd_class floor host reason
  read_is_elf "$bin" && is_elf=1
  [ "$(elf_arch "$bin")" = "$(host_arch)" ] && arch_ok=1
  ldd_class=$(classify_ldd "$bin")
  floor=$(max_glibc_floor "$bin")
  host=$(host_glibc)

  if reason=$(decide "$is_elf" "$arch_ok" "$ldd_class" "$floor" "$host"); then
    if [ "$ldd_class" = ok ] && [ -z "$floor" ]; then
      printf '  \xe2\x9c\x93 verify %s (glibc-floor skipped: no objdump/readelf)\n' "$(basename "$bin")"
    else
      printf '  \xe2\x9c\x93 verify %s\n' "$(basename "$bin")"
    fi
    exit 0
  fi
  printf '  \xe2\x9c\x97 verify %s: %s\n' "$bin" "$reason" >&2
  printf '      host: glibc %s, arch %s\n' "${host:-?}" "$(uname -m)" >&2
  exit 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Make both files LF + executable, run the test to verify it passes**

```bash
cd makefile
sed -i 's/\r$//' lib/verify-binary.sh lib/test-verify-binary.sh
chmod +x lib/verify-binary.sh lib/test-verify-binary.sh
bash lib/test-verify-binary.sh
```
Expected: all `✓`, final line `all verify-binary tests passed`, exit 0.

- [ ] **Step 5: Confirm it flags the real-world bad case (musl-dynamic) and lints clean**

```bash
cd makefile
shellcheck -x -S warning lib/verify-binary.sh lib/test-verify-binary.sh && shfmt -d -i 2 lib/verify-binary.sh lib/test-verify-binary.sh && echo LINT-OK
# Negative smoke: a musl-dynamic binary on this glibc host must FAIL.
# (Reuse any musl-dynamic asset; if none handy, this is already covered by the
#  decide() 'missing lib' unit case in Step 1 — skip if no artifact available.)
```
Expected: `LINT-OK` (no shellcheck/shfmt output).

- [ ] **Step 6: Commit**

```bash
git add makefile/lib/verify-binary.sh makefile/lib/test-verify-binary.sh
git update-index --chmod=+x makefile/lib/verify-binary.sh makefile/lib/test-verify-binary.sh
git commit -m "feat(verify): add non-executing install-time binary capability check"
```

---

### Task 2: Wire verify into the macros (auto for all eget tools)

**Files:**
- Modify: `makefile/Makefile` (add `verify_cmd`; edit `EGET_TOOL` + `TOOL` macros)
- Modify: `makefile/tools.mk:211` (bottom — add `btm` verify-name override)

**Interfaces:**
- Consumes: `lib/verify-binary.sh` from Task 1.
- Produces:
  - `verify_cmd <basename>` make function — expands to the verify command for
    `$(DEST)/<basename>`, or `:` (no-op) when `<basename>` is `-`.
  - `EGET_TOOL` gains optional `$(6)` verify-name (default `$(1)`, `-` = skip).
  - `TOOL` gains optional `$(4)` verify-name (absent = no verify; opt-in).

- [ ] **Step 1: Add the `verify_cmd` function to `makefile/Makefile`**

After the `export DEST HELIX_RUNTIME_DEST LIB STAMP SUDO MODE HAS_SUDO` line
(currently line 38), add:

```makefile

# verify_cmd <basename> — shell snippet (for &&-chaining onto an install
# command) that runs the install-time capability check against $(DEST)/<basename>,
# or a no-op `:` when <basename> is the skip sentinel `-`. A failing check exits
# non-zero so _RULE_BODY's trailing `touch` never fires — no stamp for a binary
# that cannot run on this host. See docs/claude/invariants.md.
verify_cmd = $(if $(filter -,$1),:,$(SUDO) $(LIB)/verify-binary.sh '$(DEST)/$1')
```

- [ ] **Step 2: Edit the `EGET_TOOL` macro install command**

In `makefile/Makefile`, the `EGET_TOOL` `_RULE_BODY` line (currently line 132):

Replace:
```makefile
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(LIB)/eget.sh $(3) $(if $(4),$(4),v$(2)) $(5))
```
With:
```makefile
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(LIB)/eget.sh $(3) $(if $(4),$(4),v$(2)) $(5) && $(call verify_cmd,$(if $(6),$(6),$(1))))
```
Also extend the `EGET_TOOL` header comment block (the `$(5) extra` section) with:
```makefile
#   $(6)  verify     OPTIONAL installed-binary basename for the capability
#                    check. Defaults to $(1); set when the binary name differs
#                    (bottom -> btm). Set to `-` to skip verification.
```

- [ ] **Step 3: Edit the `TOOL` macro install command**

In `makefile/Makefile`, the `TOOL` macro `_RULE_BODY` line (currently line 68):

Replace:
```makefile
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(3))
```
With:
```makefile
$(call _RULE_BODY,$(1),$(2),$(SUDO) $(3)$(if $(4), && $(call verify_cmd,$(4))))
```
Add to the `TOOL`/macro comment header (near line 43):
```makefile
#   $(eval $(call TOOL,<name>,<version>,<install_cmd>[,<verify-binary>]))
# <verify-binary> (optional, opt-in): basename under $(DEST) to capability-check
# after install. Pass it for ELF-binary installs (archive.sh/direct.sh); omit
# for script installs (nb, sysz, ssh-copy-id) and non-binary helpers.
```

- [ ] **Step 4: Add bottom's verify-name override in `tools.mk`**

In `makefile/tools.mk:211`, replace:
```makefile
$(eval $(call EGET_TOOL,bottom,$(BOTTOM_VERSION),ClementTsang/bottom,$(BOTTOM_VERSION),--asset musl --file btm))
```
With:
```makefile
$(eval $(call EGET_TOOL,bottom,$(BOTTOM_VERSION),ClementTsang/bottom,$(BOTTOM_VERSION),--asset musl --file btm,btm))
```

- [ ] **Step 5: Verify the macro expands correctly (dry run, no install)**

```bash
cd makefile
# starship (eget, $(6) default): expect the recipe to chain verify-binary.sh on $(DEST)/starship
make -n starship MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -- 'verify-binary.sh'
# bottom (eget, $(6)=btm): expect verify against $(DEST)/btm, NOT /bottom
make -n bottom MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -- 'verify-binary.sh'
```
Expected: starship line ends `verify-binary.sh '/tmp/vb-test/starship'`; bottom line ends `verify-binary.sh '/tmp/vb-test/btm'`.

- [ ] **Step 6: Real install of an eget tool passes verify + stamps**

```bash
cd makefile
export GITHUB_TOKEN="$(gh auth token)"
rm -rf /tmp/vb-test /tmp/vb-stamps
make eget starship bottom MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -E 'verify|==>'
ls /tmp/vb-stamps/*.done
```
Expected: each shows `✓ verify <name>`; stamps `eget-*.done`, `starship-*.done`, `bottom-*.done` exist. (`eget` is installed first by archive.sh as its own tool; it then self-verifies once Task 3 adds its `$(4)` — here it is unguarded, which is fine.)

- [ ] **Step 7: Commit**

```bash
git add makefile/Makefile makefile/tools.mk
git commit -m "feat(verify): gate install stamps on verify-binary (eget auto + macro opt-in)"
```

---

### Task 3: Opt-in the in-scope `TOOL` (archive.sh/direct.sh) binaries

**Files:**
- Modify: `makefile/tools.mk` — add `,<name>` verify arg to 18 ELF-binary TOOL
  entries. **Do NOT touch** the script tools (`nb` 349, `sysz` 378,
  `ssh-copy-id` 381), `helix` (414, helix.sh), `chezmoi` (421, pipe.sh), or
  `cht.sh` (459, SOFT_TOOL).

**Interfaces:**
- Consumes: `TOOL` `$(4)` verify-name from Task 2.

The 18 entries and the exact arg to append before the closing `))`:

| line | tool | helper | append |
|---|---|---|---|
| 47 | eget | archive | `,eget` |
| 76 | ncdu | archive | `,ncdu` |
| 114 | yazi | archive | `,yazi` |
| 134 | nnn | archive | `,nnn` |
| 219 | age | archive | `,age` |
| 300 | clipse | archive | `,clipse` |
| 352 | jq | direct | `,jq` |
| 355 | yq | direct | `,yq` |
| 359 | tldr | direct | `,tldr` |
| 362 | witr | direct | `,witr` |
| 366 | broot | direct | `,broot` |
| 369 | ctop | direct | `,ctop` |
| 372 | sops | direct | `,sops` |
| 375 | lazyjournal | direct | `,lazyjournal` |
| 388 | shfmt | direct | `,shfmt` |
| 396 | pueue | direct | `,pueue` |
| 398 | pueued | direct | `,pueued` |
| 407 | nnd | direct | `,nnd` |

- [ ] **Step 1: Edit each entry**

Each TOOL entry ends with `...))`. Insert the verify-name before the final `))`.
Example — `eget` (lines 47-48):

From:
```makefile
$(eval $(call TOOL,eget,$(EGET_VERSION),\
  $(LIB)/archive.sh eget https://github.com/zyedidia/eget/releases/download/v$(EGET_VERSION)/eget-$(EGET_VERSION)-linux_amd64.tar.gz))
```
To:
```makefile
$(eval $(call TOOL,eget,$(EGET_VERSION),\
  $(LIB)/archive.sh eget https://github.com/zyedidia/eget/releases/download/v$(EGET_VERSION)/eget-$(EGET_VERSION)-linux_amd64.tar.gz,eget))
```
Example — `witr` (lines 362-363):

From:
```makefile
$(eval $(call TOOL,witr,$(WITR_VERSION),\
  $(LIB)/direct.sh witr https://github.com/pranshuparmar/witr/releases/download/v$(WITR_VERSION)/witr-linux-amd64))
```
To:
```makefile
$(eval $(call TOOL,witr,$(WITR_VERSION),\
  $(LIB)/direct.sh witr https://github.com/pranshuparmar/witr/releases/download/v$(WITR_VERSION)/witr-linux-amd64,witr))
```
Apply the same pattern to all 18 rows in the table above.

- [ ] **Step 2: Confirm script tools are untouched (negative check)**

```bash
cd makefile
# These must NOT chain verify (they are scripts / out of scope):
for t in nb sysz ssh-copy-id helix chezmoi; do
  printf '%s: ' "$t"; make -n "$t" MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -c 'verify-binary.sh'
done
```
Expected: each prints `0`.

- [ ] **Step 3: Confirm an opt-in TOOL chains verify on the right path**

```bash
cd makefile
make -n witr MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -- 'verify-binary.sh'
make -n age  MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -- 'verify-binary.sh'
```
Expected: witr line ends `verify-binary.sh '/tmp/vb-test/witr'`; age ends `.../age'`.

- [ ] **Step 4: Real install of opt-in TOOL tools passes + stamps**

```bash
cd makefile
export GITHUB_TOKEN="$(gh auth token)"
make jq witr nnd age MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -E 'verify|==>'
# Script tools still install fine WITHOUT verify:
make nb sysz MODE=prod DEST=/tmp/vb-test STAMP=/tmp/vb-stamps 2>&1 | grep -E '==>'
ls /tmp/vb-stamps/{jq,witr,nnd,age,nb,sysz}-*.done
```
Expected: jq/witr/nnd/age show `✓ verify`; nb/sysz show `==>` only (no verify line); all six stamps exist.

- [ ] **Step 5: Commit**

```bash
git add makefile/tools.mk
git commit -m "feat(verify): opt the ELF-binary archive/direct tools into verification"
```

---

### Task 4: Docs + invariant note

**Files:**
- Modify: `docs/claude/invariants.md` (new load-bearing entry)
- Modify: `docs/claude/file-care.md` (note the new helper + verify-name params)

- [ ] **Step 1: Add the invariant entry**

Append to `docs/claude/invariants.md` (match the file's existing heading style):

```markdown
## Install-time binary verification gate

`EGET_TOOL`/`TOOL` `&&`-chain `lib/verify-binary.sh '$(DEST)/<name>'` onto the
install command (via the `verify_cmd` make function), so a binary that cannot
run on this host fails the install **before** the stamp is written — converting
silent "installed but won't run" successes (the fastfetch musl-loader and
wrong-file breakages) into loud, retryable stops.

- **Non-executing**: ELF magic + `e_machine` arch, then `ldd` (static → PASS;
  any `not found` → FAIL), then glibc-floor via `objdump`/`readelf`.
- **Static binaries MUST pass** (most `--asset musl` tools are static). Do not
  "tighten" the check to fail non-dynamic binaries — it would false-fail ~33
  eget tools.
- **Degrades**: no `objdump`/`readelf` (minimal prod) → skip the glibc-floor
  sub-check with a note; keep ELF+arch+ldd.
- **Verify is automatic for `EGET_TOOL`** (override the binary name via the 6th
  arg — bottom→`btm`; skip with `-`) and **opt-in for `TOOL`** (4th arg = the
  ELF binary's basename). Script "tools" (nb, sysz, ssh-copy-id) and non-binary
  helpers (helix.sh, pipe.sh) are deliberately NOT verified.
- Verify with: `make <tool> MODE=prod DEST=/tmp/t STAMP=/tmp/s` — a passing
  install prints `✓ verify <tool>` and writes the stamp.
```

- [ ] **Step 2: Add the file-care note**

Append to the LF-only/0755 list context in `docs/claude/file-care.md`:

```markdown
- `makefile/lib/verify-binary.sh` + `makefile/lib/test-verify-binary.sh` — the
  install-time capability check and its unit test. LF + 0755 (auto-covered by
  the `makefile/lib/*.sh` glob in `check-invariants.sh`). The decision logic
  (`decide`/`glibc_le`) is pure and unit-tested; edits must keep `bash
  lib/test-verify-binary.sh` green. The macros pass the binary basename to
  verify (`EGET_TOOL` 6th arg / `TOOL` 4th arg) — keep bottom's `btm` override
  in sync if bottom's `--file` target changes.
```

- [ ] **Step 3: Commit**

```bash
git add docs/claude/invariants.md docs/claude/file-care.md
git commit -m "docs(verify): record the install-time verification gate"
```

---

### Task 5: Full-fleet sandbox integration + lint + finish

**Files:** none (verification only).

- [ ] **Step 1: Run the invariant check (lint) on the branch**

```bash
make -C makefile lint MODE=prod
```
Expected: `✓ all invariant checks passed` (the new `lib/*.sh` files appear in the
LF+0755 / shellcheck / shfmt counts).

- [ ] **Step 2: Run the unit test once more**

```bash
cd makefile && bash lib/test-verify-binary.sh
```
Expected: `all verify-binary tests passed`.

- [ ] **Step 3: Full sandbox provision — every tool installs AND verifies**

This exercises the gate against all ~33 eget + 18 opt-in TOOL binaries at once,
catching any tool the new check legitimately flags (a latent bad asset — the
whole point).

```bash
cd makefile
export GITHUB_TOKEN="$(gh auth token)"
rm -rf /tmp/vb-all /tmp/vb-all-stamps
make all MODE=prod DEST=/tmp/vb-all STAMP=/tmp/vb-all-stamps 2>&1 | tee /tmp/vb-all.log | tail -30
echo "--- any verify failures? ---"
grep -E '✗ verify' /tmp/vb-all.log || echo "none — all binaries verified"
```
Expected: build completes; `none — all binaries verified`. If any tool shows
`✗ verify`, that is a real latent breakage: fix its asset (cf. PR #48's
fastfetch fix) or, only if genuinely a false positive, set the `-` skip sentinel
and note why in `tools.mk`.

- [ ] **Step 4: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to open the PR
(branch `feat/install-time-binary-verification`, which already carries the spec
commit). Summarize: the gate, the fastfetch/wrong-file classes it now catches,
the full-sandbox result, and that it is internal (no README).

## Self-Review

- **Spec coverage:** check helper (T1) ✓; ELF+arch/ldd/floor algorithm + static
  pass + degradation (T1) ✓; shared-helper coverage via macro wiring (T2/T3) ✓;
  bottom→btm rename + `-` escape hatch (T2) ✓; `--all` primary-only (age/ast-grep
  via $(1)) ✓; hard-fail stamp gating (T2) ✓; testing/CI incl. LF+0755 glob (T1/T5)
  ✓; docs/invariants, no README (T4) ✓; out-of-scope items untouched (T3) ✓.
- **Placeholder scan:** no TBD/TODO; every code/command step is complete.
- **Type/name consistency:** `decide`/`glibc_le`/`verify_cmd` names and the
  `static|ok|missing:<name>` classification are used identically in T1 (impl),
  T1 (test), and T2 (macro). `$(6)` (EGET verify-name) and `$(4)` (TOOL
  verify-name) consistent across T2/T3.
```
