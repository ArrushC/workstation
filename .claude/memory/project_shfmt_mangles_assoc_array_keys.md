---
name: shfmt-mangles-assoc-array-keys
description: shfmt rewrites unquoted hyphenated bash associative-array keys as arithmetic ([nerd-fonts] -> [nerd - fonts]), silently changing the key — always quote assoc-array keys in first-party shell
metadata:
  type: project
---

`shfmt` (which `check-invariants.sh` enforces and `make fmt` applies) parses
unquoted associative-array subscripts as arithmetic and inserts spaces around
operators: `ALIAS=([nerd-fonts]=X)` becomes `ALIAS=([nerd - fonts]=X)`. That is
not a style change — the key literally becomes `"nerd - fonts"`, so lookups on
`nerd-fonts` miss. This silently broke `scripts/bump-versions.sh`'s ALIAS table
when c3fe7b4 bulk-formatted the shell set (alias added in f5ca79d, fixed in PR #62).

**Why:** shfmt is semantics-preserving for almost everything else, so a bulk
`shfmt -w` diff gets skimmed; this is the one known case in this repo where it
changes behavior. `bash -n` and shellcheck both stay silent about it.

**How to apply:** always write bash assoc-array keys quoted
(`["nerd-fonts"]=X`) — shfmt leaves quoted subscripts verbatim. When reviewing
a bulk-format diff, treat any `[a-b]` → `[a - b]` hunk as a behavior change,
not formatting. Related: the repo's other bulk-format tripwire is re-verifying
LF+0755 after `shfmt -w` (see CLAUDE.md file-care section).
