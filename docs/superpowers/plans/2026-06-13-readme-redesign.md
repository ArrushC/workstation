# README.html "Terminal, Elevated" Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the look & feel of `README.html` (with `docs/README/README.css` + `docs/README/README.js`) into a higher-craft "terminal, elevated" developer doc — living terminal hero, numbered section markers, unified components, dark-first — without changing content, anchors, or the three-file structure.

**Architecture:** Pure static docs, no build step. CSS custom-property token system with three theme scopes (dark / auto-light / forced-light). HTML restructured per-component but every `#anchor` id and all section content preserved. README.js keeps its 10 behaviors (refactored to new selectors) and gains one new progressive-enhancement behavior (hero typed animation). The approved mockup at `/tmp/mock/index.html` is the canonical visual reference for tokens and component styling.

**Tech Stack:** HTML5, CSS3 (custom properties, grid, counters, `color-mix`), vanilla JS (IIFE, IntersectionObserver, `matchMedia`), IBM Plex Mono/Sans via Google Fonts `@import`. Headless MS Edge for render verification.

**Spec:** `docs/superpowers/specs/2026-06-13-readme-redesign-design.md` (read it first).

---

## Conventions used by every task

### Render-verify snippet (the "test" for visual tasks)
From repo root. Renders the live `README.html` to a PNG you then view with the Read tool.
The WSL distro in this checkout is `AlmaLinux-9`; adjust if different (`wslpath -w README.html`).

```bash
EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
URL='file://///wsl.localhost/AlmaLinux-9/home/arrush.chaturvedi/.local/share/chezmoi/README.html'
render() { # $1=outfile $2=width $3=height $4=scale
  "$EDGE" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor="${4:-1}" --window-size="$2,$3" \
    --screenshot="\\\\wsl.localhost\\AlmaLinux-9\\tmp\\$1" "$URL" 2>/dev/null | tail -1
}
# desktop dark assumes localStorage default 'auto' follows OS; to force a theme for a shot,
# temporarily set <html data-theme="dark"> / "light", render, then revert.
render readme-new.png 1440 3200 1
```
Then `Read /tmp/readme-new.png`. For light/dark proof, temporarily flip the `<html data-theme>`
attribute (the runtime default is `auto`), render, and revert before committing.

### File-hygiene gate (run before every commit that touches the three files)
```bash
file README.html docs/README/README.css docs/README/README.js   # must NOT say "CRLF"
git ls-files --stage README.html docs/README/README.css docs/README/README.js  # must be 100644
```

### Anchor gate (run before the final commit)
```bash
for a in intro stack toolbelt machines layout setup setup-config setup-linux setup-windows \
  setup-wsl setup-wezterm prompt-keys completion hosts daily daily-services adding troubleshooting; do
  grep -q "id=\"$a\"" README.html || echo "MISSING ANCHOR: $a"
done; echo "anchor check done"
```

### Selector + behavior contract (README.js depends on these — keep or update in lockstep)
| # | Behavior | Ids / classes the JS touches |
|---|---|---|
| 1 | Theme toggle | `#theme-toggle`, `#theme-icon`, `html[data-theme]`, `localStorage["readme-theme"]` |
| 2 | Copy buttons | every `<pre>`; injects `.copy-btn` (`.copied`) |
| 3 | Heading anchors | `main h2[id], h3[id], h4[id]`; injects `.heading-anchor` |
| 4 | Scroll-spy | `nav.toc a[href^="#"]`, `main section[id]`, `main h3[id]`, `.active`, `aria-current` |
| 5 | Global search | `#global-search`, `#toc-search-meta`, `main section`, `<mark>`, `.dimmed`, `li.hidden` |
| 6 | `/` + `Esc` | `#global-search`, `#tool-filter`, `#ts-filter` |
| 7 | Toolbelt filter | `#tool-filter`, `#tool-filter-meta`, `#toolbelt-grid .tool-card`, `.chip`, `.match-hit`, `.dimmed`, `.no-match`, `[data-cat]`, `h4`, `[data-tip]` |
| 8 | Troubleshooting filter | `#ts-filter`, `#ts-count`, `[data-ts]` (`hidden`/`open`) |
| 9 | Mobile TOC | `#toc-collapse-ctrl`, `#toc`, `.mobile-collapsed`, `aria-expanded` |
| 10 | Scroll-progress | `#scroll-progress`, `--scroll-progress` |
| 11 | **NEW** hero anim | `.term[data-typed]`, `.term .body .ln`, `prefers-reduced-motion` |

### Token block (paste verbatim into README.css; the design source-of-truth)
```css
:root,[data-theme="dark"]{
  --bg:#0a0d12;--bg-soft:#0d1117;--surface:#11161e;--surface-2:#161c25;--surface-3:#1d2530;
  --border:#2a323e;--border-soft:#1c2330;
  --text:#e8eef5;--text-soft:#c4cdd9;--muted:#8893a4;--muted-2:#6b7585;
  --accent:#6bb6ff;--accent-hover:#93cbff;--accent-soft:rgba(107,182,255,.14);--accent-deep:#2d6fc4;
  --hot:#d4ff5a;--hot-soft:rgba(212,255,90,.15);
  --linux:#5aa9ff;--windows:#b88dff;--warn:#f1bf65;--ok:#5fd87a;--bad:#ff7676;--pink:#ff9485;--teal:#62e0d8;
  --grid-line:rgba(168,184,207,.05);--grain-opacity:.04;
  --shadow:0 1px 0 rgba(255,255,255,.04),0 18px 50px -18px rgba(0,0,0,.75);
  --shadow-soft:0 1px 0 rgba(255,255,255,.03),0 8px 24px -10px rgba(0,0,0,.5);
  --mark-bg:rgba(212,255,90,.22);--mark-fg:#e8ffae;
}
@media (prefers-color-scheme:light){[data-theme="auto"]{ /* paste the light values below */ }}
[data-theme="light"]{
  --bg:#fbfaf6;--bg-soft:#f3f1ea;--surface:#ffffff;--surface-2:#f6f3ec;--surface-3:#ece8de;
  --border:#d8d2c4;--border-soft:#e7e2d4;
  --text:#161a1f;--text-soft:#3a4049;--muted:#5b6471;--muted-2:#7d8694;
  --accent:#1d5fc7;--accent-hover:#0e4ca6;--accent-soft:rgba(29,95,199,.1);--accent-deep:#103a85;
  --hot:#3f7d12;--hot-soft:rgba(63,125,18,.12);
  --linux:#1d5fc7;--windows:#7c3ed0;--warn:#9a6700;--ok:#1f883d;--bad:#cf222e;--pink:#c92a6c;--teal:#006d77;
  --grid-line:rgba(20,28,42,.045);--grain-opacity:.025;
  --shadow:0 1px 0 rgba(0,0,0,.03),0 14px 40px -16px rgba(13,17,23,.18);
  --shadow-soft:0 1px 0 rgba(0,0,0,.02),0 4px 14px -6px rgba(13,17,23,.12);
  --mark-bg:#fff3a8;--mark-fg:#2a1f00;
}
:root{--mono:"IBM Plex Mono",ui-monospace,"Cascadia Mono",Menlo,Consolas,monospace;
  --sans:"IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  --r-sm:5px;--r:9px;--r-lg:14px;--maxw:62rem;
  --t-fast:120ms cubic-bezier(.2,.7,.3,1);--t-med:180ms cubic-bezier(.2,.7,.3,1);
  --scroll-progress:0;color-scheme:light dark;}
```
> Token **names are a superset of the current sheet's** — so any component CSS not yet rewritten keeps resolving its variables and the page never renders fully broken mid-redesign.

---

## Task 1: Branch, baseline capture, and CSS token foundation

**Files:**
- Modify: `docs/README/README.css` (lines 15–160: token + reset blocks)
- Reference: `/tmp/mock/index.html` (approved visual source)

- [ ] **Step 1: Create the working branch** (currently on `main` — must branch first)
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git checkout -b feat/readme-redesign
```

- [ ] **Step 2: Capture the BEFORE baseline** (for later visual diffing)
```bash
EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
URL='file://///wsl.localhost/AlmaLinux-9/home/arrush.chaturvedi/.local/share/chezmoi/README.html'
"$EDGE" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,3200 \
  --screenshot='\\wsl.localhost\AlmaLinux-9\tmp\before-desktop.png' "$URL" 2>/dev/null | tail -1
```
View `/tmp/before-desktop.png` and keep it as the reference to beat.

- [ ] **Step 3: Replace the token + root vars** in README.css with the Token block above
(both theme scopes + the `:root` font/radius vars). Keep the file's leading comment header
(update the visual-direction note to "Terminal, Elevated"). Keep `* { box-sizing }`, the
`html`/`body` base rules — but update `body` to add the grid background + `--sans` font:
```css
body{margin:0;background:var(--bg);color:var(--text);font-family:var(--sans);
  font-size:15.5px;line-height:1.62;-webkit-font-smoothing:antialiased;
  background-image:linear-gradient(var(--grid-line) 1px,transparent 1px),
    linear-gradient(90deg,var(--grid-line) 1px,transparent 1px);
  background-size:46px 46px,46px 46px;}
body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:0;
  background:radial-gradient(60rem 38rem at 72% -8%,rgba(107,182,255,.10),transparent 60%),
    radial-gradient(50rem 30rem at 8% 4%,rgba(212,255,90,.05),transparent 55%);}
```

- [ ] **Step 4: Render & verify** the page still loads (components below will look transitional but
must not be invisible/unstyled-white). Run the render snippet; `Read /tmp/readme-new.png`.
Expected: dark background, grid texture, fonts loading, content readable.

- [ ] **Step 5: File-hygiene gate + commit**
```bash
file docs/README/README.css | grep -vq CRLF && echo OK
git add docs/README/README.css
git commit -m "feat(readme): new token system + page chrome (terminal-elevated redesign)"
```

---

## Task 2: Layout shell — sidebar / TOC redesign

**Files:** Modify `README.html` (the `nav.toc` block, ~L45–111), `docs/README/README.css`
(`.layout`, `.toc`, `.toc-search`, `.theme-toggle`, `.scroll-progress`).

- [ ] **Step 1: Restructure the TOC markup** — keep `#toc`, `#toc-collapse-ctrl`, `#global-search`,
`.kbd-hint`, `#toc-search-meta`, `#toc-list`, and every `<a href="#...">` exactly. Add a brand row
above search: `<div class="brand"><span class="logo">w</span><b>workstation</b></div>`. Wrap the
search input so a `/` keycap can sit inside: keep the input id, add `<span class="key">/</span>`.
Keep the nested `<ol class="sub">` entries.

- [ ] **Step 2: Add layout + sidebar CSS** (port from `/tmp/mock/index.html` `.layout/.toc/.brand/
.toc-search/.toc a`). Required: numbered list via `counter-reset:s` / `counter-increment:s` /
`a::before{content:counter(s,decimal-leading-zero)}`; `.toc a.active` = `--accent-soft` bg + sliding
3px left bar (`a.active::after`); sub-items indented one notch and not double-numbered (reset/scope
the counter so sub `<ol>` uses its own or no number — match current TOC depth behavior).
`.scroll-progress` stays a thin top bar; drive width from `--scroll-progress` (keep current rule
shape that the JS feeds).

- [ ] **Step 3: Theme-toggle CSS** — restyle `.theme-toggle` as a square ~38px button top-right,
surface bg, accent on hover. Keep `#theme-icon` span.

- [ ] **Step 4: Render & verify** sidebar: numbered items, active state on the first link, search
field with `/` keycap, brand mark, theme button. `Read` the screenshot.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): redesigned sidebar TOC (numbered, active bar, search keycap)"
```

---

## Task 3: Hero — terminal window + quickstart panel

**Files:** Modify `README.html` (`header#intro`, ~L114–171), `docs/README/README.css`
(`.eyebrow`, `.hero`, `.term*`, `.btn*`, `.hero-quickstart`, `.qs-card`, `.hero-help`).

- [ ] **Step 1: Rebuild the hero markup.** Keep `<header id="intro">`, the `<h1>` text
`workstation` (add `<span class="cursor">` + keep `<span class="tag">dev env</span>`), and the lede
paragraph (content unchanged). Insert the terminal block (port from mock `.term`): bar with 3 dots +
`arrush@workstation: ~/.local/share/chezmoi` title + `DEV ENV` badge; body with one `❯ make MODE=dev
provision` line, 3–4 `✓ … done` lines, and a `# …` hint line ending in `<span class="caret">`. Give
the terminal `data-typed` for the animation hook. Add the `.cta` button row (Linux quickstart /
Windows quickstart / View on GitHub — the GitHub button links to the repo; the quickstart buttons are
`<a href="#setup-linux">` / `<a href="#setup-windows">`).

- [ ] **Step 2: Keep the two quickstart one-liners.** Directly below `.term`, retain the existing
`.hero-quickstart` with both `.qs-card` (`linux` / `windows`) blocks — **content and the two `<pre>`
one-liners unchanged** (copy-buttons attach to them). Restyle via CSS only. Keep `.hero-help` jump
links.

- [ ] **Step 3: Hero CSS** — port `.eyebrow` (with `//` accent), `.hero h1` (mono clamp + blinking
`.cursor`/`.tag`), `.term` window (bar/dots/title/badge/body/line colors/`.caret`), `.cta` + `.btn`
(+ `.btn.primary/.lin/.win`) from the mock. Restyle `.qs-card` to the new surface/edge language
(keep `.qs-card.linux/.windows`, `.qs-icon`, `.qs-sub`, badges). Add `@keyframes blink`.

- [ ] **Step 4: Render & verify** the hero (static, since JS animation is Task 10): terminal reads as
a real window, caret blinks, CTA buttons styled, quickstart cards below look cohesive, one-liners
present and copyable-looking. `Read` the shot.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): terminal-window hero + restyled quickstart panel"
```

---

## Task 4: Section markers + Stack cards

**Files:** Modify `README.html` (`#stack` stack-grid, ~L173–255), `docs/README/README.css`
(`section`, `.mark`, `.lede`, `.grid`, `.stack-card`).

- [ ] **Step 1: Section-marker pattern.** Decide the mechanism: wrap each `<section>`'s `<h2>` so a
numbered chip + dashed rule render around it WITHOUT changing `<h2 id>`/text (needed for scroll-spy +
heading-anchors). Implement as: `<div class="mark"><span class="n"></span><h2 id="stack">Stack</h2>
<span class="rule"></span></div>` with the number from a CSS counter on `main` (`counter-reset` on
main, `counter-increment` per `.mark`, `.n::before{content:counter(...)}`) so numbers auto-sequence.
Apply the `.mark` wrapper to ALL top-level section `<h2>`s (do the rest in their tasks; establish the
CSS here).

- [ ] **Step 2: Stack-grid CSS.** Port `.grid.s4/.s3`, `.scard` (rename-free: keep `.stack-card`,
`.layer-label`, `.ico`) — category-colored left edge via a per-card `--c` (set inline
`style="--c:var(--accent)"` etc. or via existing `nth-child` rules; keep existing `.stack-card
nth-child` accent assignments if simpler). Mono `.layer-label`, mono `h3`, hover-lift.

- [ ] **Step 3: Apply `.mark` to the Stack `<h2>`** and confirm the number shows `01`.

- [ ] **Step 4: Render & verify** stack cards + the `01 — Stack` marker.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): numbered section markers + restyled stack cards"
```

---

## Task 5: Toolbelt — tool cards, keycap chips, filter bar

**Files:** Modify `README.html` (`#toolbelt` … `#toolbelt-grid`, ~L257–1227), `docs/README/README.css`
(`.tools-meta`, `.filter-bar`, `.filter-meta`, `.toolbelt-grid`, `.tool-card`, `.tool-card.cat-*`,
`.chips`, `.chip`, `.chip small`, `.chip.match-hit`, `.chip[data-tip]::after`, `.sr-only`).

- [ ] **Step 1: Preserve all tool-card markup contracts** — `#toolbelt-grid`, every `.tool-card`
with its `data-cat`, every `.chip` with `tabindex`, `data-tip`, `.sr-only` span, and `<small>`
sub-tags. Do NOT remove/rename chips or change their text (the filter + tooltips depend on it). Wrap
the `<h3 id="toolbelt">` in the `.mark` pattern.

- [ ] **Step 2: Tool-card + chip CSS.** Port `.tcard`→ keep class `.tool-card`: category top edge
via the existing `.tool-card.cat-*::before` color rules (keep them), mono uppercase `h4`. Chips →
keycap pills (mono, `--surface-3`, 2px bottom border, hover→accent). Keep `.chip small`,
`.chip.match-hit` (use `--hot`/`--mark-bg`), `.chip[data-tip]::after` tooltip, `.sr-only`. Restyle
`.filter-bar` input + `.filter-meta` (+ `.no-match`).

- [ ] **Step 3: Render & verify** the toolbelt grid + chips + filter bar.

- [ ] **Step 4: Manually verify the toolbelt filter still works** (JS untouched yet, selectors
preserved): open page, type `docker` in the tool filter → matching chips highlight, non-matching
cards dim, meta count updates. (If it breaks, a selector was renamed — fix the HTML.)

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): tool cards + keycap chips + filter bar"
```

---

## Task 6: Machines table + Repo-layout tree

**Files:** Modify `README.html` (`#machines` ~L1228–1287, `#layout` ~L1288–1584),
`docs/README/README.css` (`table`, `th`, `td`, `.tree*`, `.os-card`, `.note`, `.badge`).

- [ ] **Step 1: Wrap both `<h2>`s** (`#machines`, `#layout`) in the `.mark` pattern. Keep the table
markup and the `.tree` `<details>/<summary>` structure + `.note` annotations + `.os-card` content
verbatim.

- [ ] **Step 2: Table CSS** — mono uppercase `muted` `th`, `border-soft` row rules, rounded
container, comfortable padding; reads like terminal output. **Restyle `.os-card`** (keep
`.os-card.linux/.windows`, `.os-label`) to the new edge/surface language.

- [ ] **Step 3: Tree CSS** — keep `.tree details` open/close, restyle `summary::before` caret +
faint mono guide lines; `.tree .note` muted.

- [ ] **Step 4: Render & verify** machines table + layout tree (expand a node).

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): terminal-style machines table + repo-layout tree"
```

---

## Task 7: Setup — flow steps, tabs, callouts, code blocks, badges

**Files:** Modify `README.html` (`#setup` … `#completion`, ~L1585–2739),
`docs/README/README.css` (`.flow`, `.flow .step`, `.num`, `.lbl`, `.arrow`, `.tabs`, `.tab-labels`,
`.tab-panels`, `.tab-panel`, `.tab-meta`, `.callout`, `.note-row`, `.checklist`, `pre`, `.copy-btn`,
`kbd`, `code`).

- [ ] **Step 1: Wrap section `<h2 id="setup">` + keep all `<h3 id="setup-*"/#prompt-keys/#completion>`
ids** (these are scroll-spy targets; the `.mark` pattern is for `<h2>` only — `<h3>`s keep their
heading-anchor `#` icon). Preserve the `.tabs` radio inputs + `panel-dev`/`panel-prod`/`ar-panel-*`
ids, the `.flow`/`.step` sequences, all `<pre>` code, `.callout`, `.badge`, `.checklist`, keybind
tables.

- [ ] **Step 2: Component CSS** — port from mock + extend: `.code` terminal chrome around `<pre>`
(top dots) and reposition the injected `.copy-btn` top-right (+ `.copied` state, `:focus-visible`);
`.flow .step` numbered mono tokens + `.arrow`; `.tabs` segmented control (keep CSS-only radio
mechanism); `.callout` accent-left card; `.badge.dev/.prod` keycaps; `.checklist li::before` glyph;
`kbd` keycap; inline `code`.

- [ ] **Step 3: Render & verify** the Setup section: env-var table, one-liner code blocks with copy +
chrome, the "what bootstrap does" flow steps, the dev/prod tabs switch, WSL + WezTerm keybind tables,
prompt-keys + completion.

- [ ] **Step 4: Manually verify** copy button on a `<pre>` and the dev/prod tab radios still work.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): setup section — flow steps, tabs, code chrome, callouts"
```

---

## Task 8: Hosts + Daily workflows + Adding sections

**Files:** Modify `README.html` (`#hosts` ~L2740–2874, `#daily`/`#daily-services` ~L2875–3165,
`#adding` ~L3166–3294). CSS: reuse components from Tasks 4–7 (tables, flow, callouts, code, cards).

- [ ] **Step 1: Wrap the three `<h2>`s** (`#hosts`, `#daily`, `#adding`) in `.mark`; keep
`#daily-services` `<h3>` id and all sub-`<h3>`s. Preserve command lists, the per-machine-overrides
note, the SSH-key copy steps, and the add-a-tool / bump-a-version / add-a-host walkthroughs verbatim.

- [ ] **Step 2: Apply existing component classes** (no new components expected). Where these sections
use ad-hoc markup, map to `.callout` / `.flow` / `.code` / table styles already defined. Add small
CSS only if a sub-pattern here has no home.

- [ ] **Step 3: Render & verify** all three sections; confirm numbering continues (06/07/08).

- [ ] **Step 4: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): hosts, daily workflows, and adding sections restyled"
```

---

## Task 9: Troubleshooting

**Files:** Modify `README.html` (`#troubleshooting` ~L3295–4020), `docs/README/README.css`
(`details`, `[data-ts]`, summary, `#ts-filter`, `#ts-count`, `.checklist`).

- [ ] **Step 1: Wrap `<h2 id="troubleshooting">`** in `.mark`; keep the `#ts-filter` input +
`#ts-count` meta and EVERY `<details data-ts>` entry (content + the `hidden`/`open` contract the JS
drives) verbatim.

- [ ] **Step 2: CSS** — keycap/terminal-styled `summary` with a rotating caret on `[open]`,
`details` surface/border, the filter bar styled like the toolbelt one, `.checklist` glyphs.

- [ ] **Step 3: Render & verify** the troubleshooting list (collapsed + one expanded).

- [ ] **Step 4: Manually verify the troubleshooting filter** — type a known term → only matching
`<details>` show and auto-open, `#ts-count` updates.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): troubleshooting accordion + filter restyle"
```

---

## Task 10: README.js — preserve 10 behaviors + add hero typed-animation

**Files:** Modify `docs/README/README.js`.

- [ ] **Step 1: Audit selectors.** Diff the contract table above against the rewritten HTML. For
behaviors 1–10, the ids/classes were preserved by design — confirm each still resolves
(`grep` each id in README.html). Update any selector the redesign legitimately changed. Do NOT change
the behavior of 1–10.

- [ ] **Step 2: Add behavior 11 — hero typed animation** (append a new IIFE section). The terminal's
full text lives in the HTML; this hides then reveals it. Reduced-motion / no-JS → static (HTML as-is).
```js
// 11. Hero terminal typed animation (progressive enhancement)
(function () {
  const term = document.querySelector('.term[data-typed]');
  if (!term) return;
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduce) return; // leave the fully-rendered static terminal in place
  const lines = Array.from(term.querySelectorAll('.body .ln'));
  if (!lines.length) return;
  const cmd = lines[0];
  const cmdEl = cmd.querySelector('.cmd');
  const full = cmdEl ? cmdEl.textContent : '';
  // reserve height so nothing shifts, then blank the lines
  const h = term.querySelector('.body').offsetHeight;
  term.querySelector('.body').style.minHeight = h + 'px';
  if (cmdEl) cmdEl.textContent = '';
  lines.slice(1).forEach((l) => { l.style.visibility = 'hidden'; });
  let i = 0;
  function type() {
    if (!cmdEl) return revealLines();
    cmdEl.textContent = full.slice(0, i++);
    if (i <= full.length) setTimeout(type, 28);
    else setTimeout(revealLines, 220);
  }
  let j = 1;
  function revealLines() {
    if (j < lines.length) {
      lines[j].style.visibility = 'visible';
      j++;
      setTimeout(revealLines, 160);
    }
  }
  // start after first paint
  requestAnimationFrame(() => setTimeout(type, 250));
})();
```
(Adjust the inner selectors `.cmd`/`.ln` to match the exact hero markup from Task 3.)

- [ ] **Step 3: Render & verify the animation** — open the page fresh: command types out, `✓` lines
stream, caret blinks, no layout jump. Then verify reduced-motion fallback:
```bash
# emulate reduced-motion in headless and confirm static render (everything visible)
EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
URL='file://///wsl.localhost/AlmaLinux-9/home/arrush.chaturvedi/.local/share/chezmoi/README.html'
"$EDGE" --headless=new --disable-gpu --force-prefers-reduced-motion --window-size=1440,1000 \
  --screenshot='\\wsl.localhost\AlmaLinux-9\tmp\hero-reduced.png' "$URL" 2>/dev/null | tail -1
```
`Read /tmp/hero-reduced.png` — all terminal lines must be visible. (If the flag is unsupported, set
the OS reduced-motion pref or trust the `matchMedia` guard + code review.)

- [ ] **Step 4: Re-verify behaviors 1–10** quickly (theme cycle/persist, copy, anchors, scroll-spy,
search highlight+dim+count, `/`+Esc, toolbelt filter, troubleshooting filter, mobile collapse,
scroll-progress).

- [ ] **Step 5: Commit**
```bash
file docs/README/README.js | grep -vq CRLF && echo OK
git add docs/README/README.js
git commit -m "feat(readme): hero typed-animation + JS behavior parity"
```

---

## Task 11: Responsive / mobile + reduced-motion + accessibility pass

**Files:** Modify `docs/README/README.css` (media queries + `@media (prefers-reduced-motion)` +
`:focus-visible`).

- [ ] **Step 1: Mobile media query (≤900px)** — single-column main, grids reflow to 1–2 cols,
sidebar uses the existing `.mobile-collapsed` mechanism (keep `#toc-collapse-ctrl` styling so it
shows on mobile), terminal hero stays legible (font clamps; command line may scroll-x), touch targets
≥40px, theme toggle reachable.

- [ ] **Step 2: `@media (prefers-reduced-motion: reduce)`** — disable `.cursor`/`.caret` blink,
hover `transform` lifts, and set `scroll-behavior:auto`. (Hero JS already bails — Task 10.)

- [ ] **Step 3: `:focus-visible` rings** on `.theme-toggle`, `.toc-search input`, `.toc a`, `.chip`,
`.btn`, `.copy-btn`, `#tool-filter`, `#ts-filter`, `.heading-anchor`. Verify contrast in both themes
(esp. light-mode lime `--hot #3f7d12`).

- [ ] **Step 4: Render & verify** mobile (390 wide) dark + light, and tab-key through interactive
elements for visible focus.
```bash
EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
URL='file://///wsl.localhost/AlmaLinux-9/home/arrush.chaturvedi/.local/share/chezmoi/README.html'
"$EDGE" --headless=new --disable-gpu --hide-scrollbars --window-size=390,2600 \
  --screenshot='\\wsl.localhost\AlmaLinux-9\tmp\mobile-new.png' "$URL" 2>/dev/null | tail -1
```

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.css
git commit -m "feat(readme): responsive, reduced-motion, and focus-visible passes"
```

---

## Task 12: Full verification sweep + CLAUDE_CHANGELOG row

**Files:** Modify `CLAUDE_CHANGELOG.md` (append a row, matching existing format).

- [ ] **Step 1: Anchor gate** — run the Anchor gate snippet; expect "anchor check done" with no
MISSING lines.

- [ ] **Step 2: Full visual sweep** — render desktop dark + desktop light + mobile, scroll-read every
section type (hero, stack, toolbelt, machines, layout tree, setup steps/tabs/code, hosts, daily,
troubleshooting). Compare against `/tmp/before-desktop.png`. `Read` each shot; confirm no unstyled /
overflowing / illegible areas and that light-mode contrast holds.

- [ ] **Step 3: Behavior sweep** — exercise all 11 behaviors once more end-to-end in a real browser
view (or via the renders + code review for the JS ones). Record pass/fail for each.

- [ ] **Step 4: File-hygiene gate** — run it for all three files; expect no CRLF, mode 100644, UTF-8
glyphs (`✓ ❯ ◐`) intact (`grep -c '❯' README.html`).

- [ ] **Step 5: Append CLAUDE_CHANGELOG.md row** describing the user-facing redesign (per CLAUDE.md:
user-facing surface changed → changelog required). Match the table/format of existing rows.

- [ ] **Step 6: Commit**
```bash
git add README.html docs/README/README.css docs/README/README.js CLAUDE_CHANGELOG.md \
  docs/superpowers/specs/2026-06-13-readme-redesign-design.md \
  docs/superpowers/plans/2026-06-13-readme-redesign.md
git commit -m "docs(readme): finalize terminal-elevated redesign + changelog"
```

- [ ] **Step 7: Final review handoff** — present before/after screenshots; use
`superpowers:finishing-a-development-branch` to decide merge / PR / cleanup. (Do NOT push or open a
PR until the user asks.)

---

## Notes for the executor
- **CLAUDE.md compliance:** README is the user-facing reference; this redesign requires the
  `CLAUDE_CHANGELOG.md` row (Task 12). It does NOT touch Make/bootstrap/versions/chezmoi, so no other
  invariant applies. The three files are NOT in the BOM set (PowerShell-only) or the 0755 set (shell
  scripts) — keep them LF / UTF-8 / 100644.
- **Never break the page mid-redesign:** token names are a superset of the old set, so un-converted
  components keep resolving variables. If a render ever shows unstyled white blocks, a token was
  renamed — restore the name.
- **The mockup `/tmp/mock/index.html` is the visual source of truth** for tokens and component look.
  When in doubt about a color/spacing/treatment, match the mockup.
- **Content is frozen.** If a copy edit seems warranted for clarity, it must not change a technical
  fact, a command, a path, or an anchor.
