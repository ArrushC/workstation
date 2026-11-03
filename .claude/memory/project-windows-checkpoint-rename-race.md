---
name: project-windows-checkpoint-rename-race
description: Check Point Endpoint's scan-on-close on the Windows host makes a rename onto a just-closed file fail with WinError 5 about once in 20k writes; Restart Manager never shows it as the holder.
metadata:
  type: project
---

The Windows host's active antivirus is Check Point Endpoint Security (Defender is passive). Its
on-access scan opens each file as it closes. If `os.replace` lands in that window, it fails with
`PermissionError: [WinError 5] Access is denied` (the temp file -> the target). Its logs are in
`C:\ProgramData\CheckPoint\Logs` (`AntiMalwareE2.log`, `TELog.log*`). Investigated 2026-11-02.

**Evidence:** `scripts/test-tool-env.py` failed about once in 160 suites, but only in a
long-lived process running hundreds of shuffled suites. In 510 fresh one-suite processes it
never failed. Each of 4 instrumented failures had a Check Point scan entry for that exact
`.workstation-*` temp file 8-18 ms after the failure. Restart Manager (`RmGetList`), called
right after the failure, reported "no process holds it" every time, so it can't show the
scanner. A deliberately held handle does show up there as `Python`. Tight loops of up to 18k
writes outside the suite never reproduced it.

**How to apply:** tool-env's `atomic_write` skips a rewrite when the bytes are unchanged and on
Windows retries the rename for up to 1 s, only on WinError 5/32 (CLAUDE.md invariant). Other
code that renames or rewrites files it has just closed on Windows (ws's baseline store,
bootstrap tasks) can hit the same race. If one fails like this, check the scanner logs first.
Don't diagnose it with Restart Manager calls inside a retry loop: each call took up to ~2.7 s
and used up the retry window. Don't make a regression test's handle release depend on a timer:
release it from the patched retry `sleep`. Related: [[project-tool-env-rollout]].
