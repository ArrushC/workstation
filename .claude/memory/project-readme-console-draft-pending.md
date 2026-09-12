---
name: readme-console-draft-pending
description: Codex CLI's README "developer console" rewrite (README.html + docs/README/README.{css,js}) is an UNCOMMITTED draft on main awaiting the user's Tron-grid decision — known defects and the two ways to close it out
metadata:
  type: project
---

On 2026-09-12 Codex CLI left two unrelated changes in one working tree. The Windows curl.exe HTTP migration was split out, hardened and landed via PR #146 (`feat/windows-curl-transport`). The **README "developer console" rewrite was deliberately NOT committed** and sits as unstaged changes on `main`: `README.html`, `docs/README/README.css`, `docs/README/README.js`, plus one intro-line edit in `CLAUDE.md` and one `CLAUDE_CHANGELOG.md` row ("Renovated the README as a developer console…").

**Why it was held (the user's call, not a defect Claude could fix alone):**
1. It silently removes the WebGL Tron grid, the Web-Audio music, and the motion/sound toggles the user shipped on purpose in `a1129b1` — and its changelog row claims to "preserve" existing features.
2. It orphans `docs/README/vendor/three/` (9 tracked files, ~650 KB) and leaves the `CLAUDE.md` "Files Claude should be careful with" Three.js vendoring paragraph describing a load-bearing dependency that nothing loads any more.
3. Two confirmed JS bugs in the rewritten `README.js`: `setupFilter` appends the chip-count span into every tool-card `<h4>` before the passage index reads `textContent`, so search titles/announcements read "File ops & viewing11"; and `reveal()` resets both filters on every in-page anchor click (incl. the injected heading-anchor links), while `popstate` + `hashchange` both call `navigate()` so Back runs reveal/focus/scroll twice.
4. Codex stated it did no browser render ("source checks only") for a 3,775-line CSS + from-scratch JS rewrite.

**Recommendation on file:** keep the rewrite only if the user actually asked for the Tron grid to go; otherwise revert (`git checkout -- README.html docs/README/README.css docs/README/README.js` and drop the CLAUDE.md intro line + changelog row). If kept: fix the two JS bugs, `git rm -r docs/README/vendor/three`, delete the Three.js file-care paragraph in `CLAUDE.md`, disclose the removals in the changelog row, and open it in a browser at least once — then land it via its own PR.

**How to apply:** if a session starts and those files are still modified on `main`, this is why — do not "helpfully" commit or revert them without the user's decision. Once the user decides and the tree is clean, delete this memory (and its index line) in the same PR.

Related: [[workstation-tui-removed]] (the other big "user decided, don't re-propose" record).
