#!/usr/bin/env bash
# verify-binary.sh — fail-fast capability check: can this freshly-installed
# binary actually run on THIS host? Non-executing (static inspection only), so
# it is safe for TUI tools. Called by tasks/verify-tools, walking every mise
# bin dir as a post-install gate (tasks/verify-tools is the `post-tools` hook,
# running right after `mise install`).
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
  # sort -V -C: check mode reads all stdin (no SIGPIPE from head), returns 0 if
  # input is already in version order (i.e. "$1" <= "$2").
  printf '%s\n%s\n' "$1" "$2" | sort -V -C
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

# classify_ldd_output <ldd-output-text> — pure; echoes: static | ok | missing:<desc>.
# Two "not found" shapes get distinct, clear descriptors:
#   "<lib> => not found"                      -> missing:<lib>
#   "... version `GLIBC_2.38' not found ..."  -> missing:symbol GLIBC_2.38
classify_ldd_output() {
  local out="$1"
  if printf '%s' "$out" | grep -qiE 'not a dynamic executable|statically linked'; then
    echo static
    return 0
  fi
  local lib
  lib=$(printf '%s\n' "$out" | awk -F'=>' '/=> not found/ {gsub(/[ \t]/, "", $1); print $1; exit}')
  if [ -n "$lib" ]; then
    echo "missing:$lib"
    return 0
  fi
  local sym
  sym=$(printf '%s\n' "$out" | awk '/version .* not found/ {print; exit}' | grep -oE '[A-Z][A-Z0-9]*_[0-9][0-9A-Za-z_.]*' | head -1)
  if [ -n "$sym" ]; then
    echo "missing:symbol $sym"
    return 0
  fi
  echo ok
}

# classify_ldd <path> — run ldd and classify (impure wrapper).
classify_ldd() {
  classify_ldd_output "$(ldd "$1" 2>&1 || true)"
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
    sort -V | tail -1 || :
}

# host_glibc -- e.g. "ldd (GNU libc) 2.34" -> 2.34
# Capture ldd output into a variable first so we can take the first line without
# a head-in-pipeline SIGPIPE race under set -euo pipefail.
host_glibc() {
  local ver
  ver=$(ldd --version 2>/dev/null | head -1) || true
  printf '%s\n' "$ver" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?$' || true
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
