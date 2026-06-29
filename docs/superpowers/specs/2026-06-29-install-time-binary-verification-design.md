# Install-time binary verification (runs-on-this-host gate)

- **Date:** 2026-06-29
- **Status:** Approved design — ready for implementation plan
- **Author:** Claude (brainstormed with Arrush)

## Problem

Tool installs pick a release **asset variant** (musl vs glibc, an arch, a build
flavor) and trust that the downloaded binary will actually run on the host. They
have no idea whether it can. Two failures this cycle proved the gap, both
**silent successes** — the install "worked," the stamp was written, and the
breakage only surfaced when something later tried to run the binary:

1. **fastfetch via `--asset musl`** — the musl release binary is *dynamically*
   linked against `/lib/ld-musl-x86_64.so.1`, a loader the glibc fleet
   (AlmaLinux/RHEL) does not ship. `fastfetch` died at exec with
   `no such file or directory`. Fleet-wide, pre-existing (PR #48 fixed the pin).
2. **fastfetch wrong-file extraction** — at one point `/usr/local/bin/fastfetch`
   was a stray bash-completion script, not the binary. `fastfetch --version`
   exited 0 doing nothing.

`eget` (the meta-installer behind ~33 of ~42 tools) detects **OS + arch but not
libc**, so `--asset musl` is a manual per-tool guess baked into `tools.mk`. The
guess is correct *only when the musl build is statically linked* (most Rust
tools are). When it is dynamic, or when an asset's glibc floor exceeds the
host's, or when the wrong file is extracted, nothing catches it at install time.

## Goal

Add a **safety net**: when a binary install produces something that cannot run
on this host, **fail the install loudly and immediately** with an actionable
message — instead of writing a stamp for a binary that will only fail later.

One reusable, **non-executing** capability check at the shared install choke
points, protecting all current tools and every future version bump.

## Non-goals (YAGNI)

- **No host-aware asset *selection*.** We are not detecting the host libc and
  choosing musl-vs-glibc per host. The fleet is uniformly glibc (AlmaLinux/RHEL
  on dev and prod); per-host selection is machinery without a consumer today.
  (Captured as a possible future phase below.)
- **No executing the installed binary.** Many tools are TUIs (btop, k9s, yazi,
  gitui, …) that can hang or need a TTY. The check inspects statically only.
- **No new mandatory host package.** The check degrades gracefully when an
  optional tool (binutils) is absent rather than requiring it.

## Decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Driver | **Safety net** — catch broken installs; fleet stays glibc |
| 2 | Method | **Static, thorough, non-executing** — ELF + ldd + glibc-floor |
| 3 | Coverage | **Shared binary helpers** — eget.sh, direct.sh, archive.sh |
| 4 | Failure mode | **Hard fail** (no stamp; `make` stops), with a per-tool escape hatch |
| 5 | Prod degradation | **Accept** — floor sub-check skips on binutils-less hosts |

## Architecture

### New helper: `makefile/lib/verify-binary.sh`

Self-contained, non-executing. Single responsibility: decide whether an
installed file can run on this host.

```
verify-binary.sh <path-to-installed-binary>
  exit 0  → binary can run here (or static → runs anywhere)
  exit 1  → cannot; prints the file, host glibc/arch, and the specific reason
```

**Algorithm (cheapest check first; short-circuits):**

1. **ELF executable for this arch?** Read the ELF header directly (no `file`
   dependency): the first 4 bytes for the `\x7fELF` magic, and `e_machine`
   (offset 18) for the arch. Not ELF → **FAIL** `not an ELF binary (wrong file
   extracted?)` (catches the stray-completion-script class). ELF but wrong arch
   (`e_machine` ≠ host arch from `uname -m`, e.g. an aarch64 build on x86_64) →
   **FAIL** `built for <arch>, host is <host-arch>` — this is what also screens
   a *static* wrong-arch binary, which step 2 would otherwise wave through.

2. **Static or dynamic?** via `ldd <path>` (glibc-provided, always present):
   - reported as non-dynamic (`not a dynamic executable` **or** `statically
     linked`, incl. static-PIE) → **PASS** immediately. *This is the
     load-bearing rule:* most `--asset musl` tools are static and run anywhere —
     the check must never false-fail them (the right-arch guarantee comes from
     step 1).
   - any `=> not found` line (missing interpreter or NEEDED library, including
     the absent musl loader) → **FAIL** `requires <name>, absent on this host`.
     Catches the fastfetch musl-loader case.

3. **glibc floor** (dynamic binaries only): extract the maximum `GLIBC_x.y`
   versioned-symbol requirement (`objdump -T` or `readelf --dyn-syms`), compare
   to the host glibc (`ldd --version` first line / `getconf GNU_LIBC_VERSION`).
   floor > host → **FAIL** `needs GLIBC_<x.y> > host GLIBC_<a.b>`. Catches
   "built against newer glibc than this host" (the older-prod risk; the plain
   `fastfetch-linux-amd64` build needs 2.34).

**Decision logic is factored into a pure function** that takes injected inputs —
`(is_elf, elf_arch, host_arch, ldd_output, max_glibc_symbol, host_glibc)` — and
returns a verdict, so every branch is unit-testable without real binaries (see
Testing).

**Dependencies & degradation:** steps 1–2 need only ELF magic + `ldd` (present
on every glibc host). Step 3 needs binutils (`objdump`/`readelf`), present on
dev (C/C++ toolchain) but typically absent on minimal prod. When neither is
found, **skip step 3 with a one-line note** and keep 1–2. On prod that still
catches wrong-file + musl-loader + missing-lib; only "needs newer glibc" goes
unchecked there — accepted per decision #5.

### Injection points

The **caller passes the exact installed binary path** to verify; the helper
checks that one file. This is race-free under `make -j` (no before/after `$DEST`
snapshot diffing, which would mis-attribute a sibling job's output).

- **`lib/eget.sh`** — after eget installs, verify the installed binary.
- **`lib/direct.sh`** (witr, nnd), **`lib/archive.sh`** (eget itself, fonts) —
  same call after placing the binary.

**Knowing the binary name.** The installed filename is usually the stamp name
`$(1)`, but not always — e.g. `bottom`→`btm`. Add an **optional verify-name
parameter** to the `EGET_TOOL` / `TOOL` macros, defaulting to `$(1)`:
- `bottom` sets it to `btm` (it already carries a `--file btm` special-case —
  the natural place for the override).
- **Escape-hatch sentinel:** setting the param to `-` skips verification for
  that one tool. None need it today; it guarantees the gate can never wedge a
  genuinely-good install (cheap insurance, low risk).

**`--all` multi-binary installs** (age+age-keygen, sg+ast-grep): verify the
**primary** binary. Extras come from the same build/source, so the primary is a
sufficient signal; per-extra verification is a possible later refinement.

### Stamp gating

The macro recipe writes `$(STAMP)/<tool>-<ver>.done` **only if verify passes**.
A failed verify → recipe exits non-zero → no stamp → `make` stops. A re-run
retries only the failed tool (other tools keep their stamps). This is identical
to today's behavior when eget aborts on asset ambiguity — it just extends the
abort to cover "installed but won't run."

## Failure behavior

**Hard fail.** Verify failure aborts the install recipe (no stamp). Under
`make -j`, the one bad target fails while finished tools keep their stamps;
`make -k` collects all failures in one pass if desired. The message is
actionable, naming:
- the offending file path,
- the host's glibc version + arch,
- the specific reason (not-ELF / missing `<lib-or-loader>` / glibc floor gap).

This converts a silent success into a loud, self-explaining stop — the whole
point of the change.

## Testing & CI

**`verify-binary.sh` joins the first-party shell set:** LF line endings, mode
0755, shellcheck-clean (warning+), `shfmt -i 2`-clean, gitleaks-clean. Add it to
the relevant file lists in `scripts/check-invariants.sh`; CI (`lint.yml`) then
enforces it automatically.

**Behavioral test — `makefile/lib/test-verify-binary.sh`** (mirrors the
`test-hooks.sh` assert-every-decision pattern):
- Drive the pure decision function with injected inputs and assert every branch:
  - not-ELF → fail
  - ELF, wrong arch (static or dynamic) → fail
  - static, right arch → pass
  - dynamic with `=> not found` → fail
  - dynamic, floor > host → fail
  - dynamic, floor ≤ host → pass
  - floor tool absent → degrade (pass on 1–2, note)
- One real **PASS** smoke against a freshly-installed binary (e.g. `starship`).
- **No committed binary fixtures** (avoids repo bloat and arch coupling).

## Docs & invariants

- **No README update.** Internal change (makefile/lib + macro), no user-facing
  CLI/override/file-location change — per the repo's README decision test.
- **`docs/claude/invariants.md`:** add a load-bearing entry — the install-time
  verification gate (the choke point) and the **static-binary-must-pass** rule
  (regressing it would false-fail the 33 musl tools).
- **`docs/claude/file-care.md`:** note the new `verify-binary.sh` (LF+0755 set)
  and the verify-name param on `eget.sh`/the macros.
- **`CLAUDE_CHANGELOG.md`:** not required (no user-facing surface change), but a
  one-line entry is reasonable since it changes install behavior.

## Out of scope / future

- **Host-aware asset *selection* (phase 2):** a host-capability probe (libc
  flavor + version, arch) feeding per-tool `--asset` preferences — only if the
  fleet ever becomes heterogeneous (a musl/Alpine host, widely varying glibc).
- **python3 glibc-floor fallback:** a ~15-line ELF `.gnu.version_r` parser so
  the floor sub-check works on binutils-less prod without adding binutils.
  Deferred under decision #5.
- **Bespoke targets** (node-runtime, vcpkg, pwndbg) opting into the shared
  helper. node-runtime already has an ad-hoc `ldd` check that could be replaced
  by `verify-binary.sh`.
- **`make doctor` reuse:** `doctor` could re-validate installed binaries on
  demand via the same helper.

## Open questions

None — all design forks resolved.
