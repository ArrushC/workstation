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

# static / no-GLIBC-symbols regression: max_glibc_floor must exit 0 with empty
# output when grep finds no versioned symbols (exercises the || : fix).
static_bin=""
if command -v cc >/dev/null 2>&1 && printf 'int main(void){return 0;}' | cc -static -x c -o "/tmp/vb-static-$$" - 2>/dev/null; then
  static_bin="/tmp/vb-static-$$"
fi
if [ -n "$static_bin" ]; then
  floor_out=""
  floor_rc=0
  floor_out=$(max_glibc_floor "$static_bin") || floor_rc=$?
  if [ "$floor_rc" = 0 ]; then ok "max_glibc_floor static-ELF: exit 0"; else no "max_glibc_floor static-ELF: exit 0 (got $floor_rc)"; fi
  if [ -z "$floor_out" ]; then ok "max_glibc_floor static-ELF: empty output"; else no "max_glibc_floor static-ELF: empty (got '$floor_out')"; fi
  if ./verify-binary.sh "$static_bin" >/dev/null 2>&1; then ok "verify static-ELF -> pass"; else no "verify static-ELF -> pass"; fi
  rm -f "$static_bin"
else
  # Fallback: /dev/null has no GLIBC symbols; exercises same grep-no-match path.
  # (Compiler or static libc unavailable — compiled static-ELF path not covered.)
  floor_out=""
  floor_rc=0
  floor_out=$(max_glibc_floor /dev/null) || floor_rc=$?
  if [ "$floor_rc" = 0 ]; then ok "max_glibc_floor /dev/null: exit 0 (fallback)"; else no "max_glibc_floor /dev/null: exit 0 (got $floor_rc, fallback)"; fi
  if [ -z "$floor_out" ]; then ok "max_glibc_floor /dev/null: empty (fallback)"; else no "max_glibc_floor /dev/null: empty (got '$floor_out', fallback)"; fi
fi

# classify_ldd_output() — pure function tests (no real ldd needed)
out=$(classify_ldd_output 'not a dynamic executable')
[ "$out" = "static" ] && ok "classify_ldd_output: 'not a dynamic executable' -> static" || no "classify_ldd_output: 'not a dynamic executable' -> static (got '$out')"

out=$(classify_ldd_output "$(printf '\t')libc.so.6 => /lib64/libc.so.6 (0x0)")
[ "$out" = "ok" ] && ok "classify_ldd_output: normal resolved line -> ok" || no "classify_ldd_output: normal resolved line -> ok (got '$out')"

out=$(classify_ldd_output "$(printf '\t')libfoo.so.1 => not found")
[ "$out" = "missing:libfoo.so.1" ] && ok "classify_ldd_output: libfoo.so.1 => not found -> missing:libfoo.so.1" || no "classify_ldd_output: libfoo.so.1 => not found -> missing:libfoo.so.1 (got '$out')"

out=$(classify_ldd_output "/x/usql: /lib64/libm.so.6: version 'GLIBC_2.38' not found (required by /x/usql)")
case "$out" in
*GLIBC_2.38*) ok "classify_ldd_output: glibc-version-not-found -> contains GLIBC_2.38" ;;
*) no "classify_ldd_output: glibc-version-not-found -> contains GLIBC_2.38 (got '$out')" ;;
esac

if [ "$fail" = 0 ]; then
  echo "all verify-binary tests passed"
else
  echo "FAILURES"
  exit 1
fi
