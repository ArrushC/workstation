# README Tron Interactive 3D Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the `README.html` trio into an animated, 3D, Tron-style "digital frontier" — cyan+orange neon grid world, real depth/parallax, and a hand-written interaction engine — while preserving every anchor, all section content, and the 11 existing JS behaviors.

**Architecture:** Pure self-contained trio (`README.html` + `docs/README/README.css` + `docs/README/README.js`), no external deps beyond the existing Google Fonts `@import`. All 3D/motion is CSS 3D + a single 2D `<canvas>` + vanilla JS. `README.js` stays one file, internally split into a prefs module, a single shared `requestAnimationFrame` scheduler, the kept behaviors 1–11, and 10 capability-gated interaction subsystems (12–21). A `prefers-reduced-motion` / touch-pointer / hidden-tab gate makes every live system degrade to a static, readable page.

**Tech Stack:** HTML5, CSS custom properties + CSS 3D transforms, vanilla ES (no modules/build), Canvas 2D, Web Audio (synthesized, opt-in). Verification via headless `msedge.exe`, structural `grep`, and `make lint`.

**Spec:** `docs/superpowers/specs/2026-06-14-readme-tron-interactive-redesign-design.md`

**Branch:** `readme-tron-redesign` (already created; the spec is committed there as `4ce810e`).

**Commit convention:** Conventional Commits scoped `(readme)`. **Every commit appends the repo's standard trailer** (one blank line then):
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
The commit commands below omit it for brevity — add it to each.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `README.html` | Markup: fixed atmosphere layers, hero scene, control cluster, re-skinned components (class/id hooks + `.tilt` markers + corner brackets). All 18 anchors + all content preserved. | Modify (structural) |
| `docs/README/README.css` | The bulk: new Tron token set (dark Grid + light daylight variant), fixed grid/atmosphere, every component re-skin, glow/depth system, focus rings, full reduced-motion block. | Rewrite |
| `docs/README/README.js` | One IIFE: prefs module → shared rAF scheduler → behaviors 1–11 (kept) → interaction engine 12–21 → bootstrap. | Modify (extend) |
| `CLAUDE_CHANGELOG.md` | Append one row (user-facing surface changed). | Append |

**`README.js` internal layout (target):**
```
(function () { "use strict";
  /* === A. Capability gates + Prefs module        (Task 7) === */
  /* === B. Shared rAF Scheduler                    (Task 7) === */
  /* === C. FX canvas singleton                     (Task 9) === */
  /* === Behaviors 1–11 (kept; selectors adjusted)  (Task 6) === */
  /* === 13 parallax · 14 trail/reticle · 15 pulses ·
         16 tilt · 17 scroll-cam · 18 section-boot ·
         12 boot-intro · 19 konami · 20 sfx         (Tasks 8–16) === */
  /* === Bootstrap (DOMContentLoaded)               (Task 7+)  === */
})();
```

---

## Verification harness (referenced by every task — set up once in Task 0)

**A. File hygiene (must pass after every edit to the trio):**
```bash
file README.html docs/README/README.css docs/README/README.js | grep -i crlf && echo "FAIL: CRLF present" || echo "OK: no CRLF"
git ls-files --stage README.html docs/README/README.css docs/README/README.js | grep -v '^100644' && echo "FAIL: wrong mode" || echo "OK: 100644"
```

**B. Anchor contract (must always list exactly these 18):**
```bash
grep -oE '<(section|header|h[2-4])[^>]* id="[a-z-]+"' README.html | grep -oE 'id="[a-z-]+"' | sort -u | tr '\n' ' '
# Expect: id="adding" id="completion" id="daily" id="daily-services" id="hosts" id="intro"
#         id="layout" id="machines" id="prompt-keys" id="setup" id="setup-config"
#         id="setup-linux" id="setup-wezterm" id="setup-windows" id="setup-wsl"
#         id="stack" id="toolbelt" id="troubleshooting"
```

**C. Behavior-hook contract (must remain non-empty after the re-skin):**
```bash
for h in 'theme-toggle' 'theme-icon' 'global-search' 'toc-search-meta' 'toc-collapse-ctrl' \
         'scroll-progress' 'toolbelt-grid' 'tool-filter' 'tool-filter-meta' 'ts-filter' 'ts-count'; do
  printf '%-18s ' "$h"; grep -c "id=\"$h\"" README.html; done
# Each count must be >= 1.
grep -c 'class="term"' README.html              # hero terminal present (>=1)
grep -c 'data-typed' README.html                # typed-animation hook present (>=1)
```

**D. Headless render screenshots (visual check, both themes + mobile):**
```bash
mkdir -p /mnt/c/Temp
# serve the repo root over http (node; background it)
( cd /home/arrush.chaturvedi/.local/share/chezmoi && npx --yes http-server -p 8099 -c-1 . ) >/tmp/rmserve.log 2>&1 &
sleep 2
MSEDGE='/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
"$MSEDGE" --headless=new --disable-gpu --hide-scrollbars --force-prefers-reduced-motion=0 \
  --window-size=1440,2400 --screenshot='C:\Temp\readme-dark.png'  'http://localhost:8099/README.html'
"$MSEDGE" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=390,2400  --screenshot='C:\Temp\readme-mobile.png' 'http://localhost:8099/README.html'
# Read /mnt/c/Temp/readme-dark.png and /mnt/c/Temp/readme-mobile.png with the Read tool to eyeball.
```
Light theme: append `#__force-light` is not a thing — instead screenshot after setting `localStorage`. Simplest light check: temporarily set `<html data-theme="light">` via a query the harness can't inject; for the headless pass, open `http://localhost:8099/README.html` and rely on `--force-dark-mode` being OFF plus a manual toggle screenshot during the interaction checklist. For automated light render, use:
```bash
"$MSEDGE" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,2400 \
  --screenshot='C:\Temp\readme-light.png' \
  'http://localhost:8099/README.html?__theme=light'
```
…and in Task 1 add a tiny query-param reader (`?__theme=light|dark`) **guarded to dev/no-op in normal use** — OR skip param and just verify light mode in the manual checklist by clicking the toggle. (Decision: **manual toggle in the interaction checklist**; do not add query-param code to ship.)

**E. Lint / invariants (no regression to the repo's mechanical checks):**
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi && make lint MODE=prod
# Expect: "✓ all invariant checks passed" (the trio isn't in the LF-0755/BOM sets,
# but lint must still pass — it runs on commit via the pre-commit hook).
```

**F. Interaction checklist (manual, desktop browser — run in Tasks 6 and 17):** open `README.html`, then verify each behavior 1–21 per the spec's verification plan. This is the human gate; screenshots can't capture pointer interaction.

---

## Task 0: Baseline snapshot + harness sanity

**Files:** none committed (scratch only).

- [ ] **Step 1: Confirm branch**

Run: `git -C /home/arrush.chaturvedi/.local/share/chezmoi branch --show-current`
Expected: `readme-tron-redesign`

- [ ] **Step 2: Capture a BEFORE screenshot** (for later before/after)

Run harness **D** against the current `README.html`; Read `/mnt/c/Temp/readme-dark.png`.
Expected: the current "Terminal, Elevated" page renders. Save a copy:
```bash
cp /mnt/c/Temp/readme-dark.png /mnt/c/Temp/readme-BEFORE.png
```

- [ ] **Step 3: Confirm harness B/C list the contract**

Run harness **B** and **C**.
Expected: B lists the 18 ids; C shows every hook count ≥ 1 and `class="term"`/`data-typed` ≥ 1.

- [ ] **Step 4: Confirm lint is green at baseline**

Run harness **E**. Expected: `✓ all invariant checks passed`.

(No commit — Task 0 is a read-only baseline.)

---

## Task 1: CSS tokens — dark "Grid" + light "daylight" variants

**Files:**
- Modify: `docs/README/README.css` (the three theme-scope blocks at the top, ~lines 16–130)

- [ ] **Step 1: Replace the dark token block** (`:root,[data-theme="dark"]`)

```css
:root,
[data-theme="dark"] {
  /* surfaces / void */
  --void: #04070d; --void-2: #070c14;
  --bg: var(--void); --bg-soft: var(--void-2);
  --surface: #0a121b; --surface-2: #0e1822; --surface-3: #122231;
  --glass: rgba(8,15,24,.62); --glass-2: rgba(10,19,28,.8);
  --border: #1d3140; --border-soft: #15242f;
  --grid-line: rgba(103,240,255,.16); --grid-hot: rgba(103,240,255,.34);
  /* text */
  --text: #dbeefb; --text-soft: #b8cadb; --muted: #7f93a6; --muted-2: #5f7488;
  /* accents */
  --c1: #67f0ff; --c1-deep: #0bb6d6; --c1-glow: rgba(103,240,255,.5);
  --c2: #ffa24d; --c2-deep: #ff7a18; --c2-glow: rgba(255,150,60,.5);
  --accent: var(--c1); --accent-hover: #9af6ff; --accent-soft: rgba(103,240,255,.14); --accent-deep: var(--c1-deep);
  --hot: var(--c2); --hot-soft: rgba(255,162,77,.16);
  /* semantics (kept for category coding + states) */
  --ok: #5fe39a; --warn: #ffd166; --bad: #ff6b6b;
  --linux: #5ec8ff; --windows: #c79bff; --teal: #62e0d8; --pink: #ff9485;
  /* depth */
  --glow-sm: 0 0 10px var(--c1-glow); --glow-md: 0 0 20px -2px var(--c1-glow); --glow-lg: 0 0 34px -4px var(--c1-glow);
  --shadow: 0 1px 0 rgba(103,240,255,.05), 0 24px 50px -22px rgba(0,0,0,.85);
  --shadow-soft: 0 10px 28px -14px rgba(0,0,0,.6);
  --mark-bg: rgba(255,162,77,.22); --mark-fg: #ffe7c4;
  --glow-a: rgba(103,240,255,.12); --glow-b: rgba(255,162,77,.07);
  --r-sm: 6px; --r: 10px; --r-lg: 14px; --maxw: 64rem;
  --mono: "IBM Plex Mono", ui-monospace, monospace; --sans: "IBM Plex Sans", system-ui, sans-serif; --display: var(--mono);
  --glow-on: 1; /* multiplier hook: 1 in dark, 0 in light to suppress blooms */
}
```

- [ ] **Step 2: Replace the light auto + explicit blocks** (`@media (prefers-color-scheme: light) [data-theme="auto"]` and `[data-theme="light"]`) with the **same** restrained "daylight grid" values in both (keep the existing dual-scope structure):

```css
/* daylight grid — restrained, AA-safe, glow suppressed */
--void: #eef2f6; --void-2: #e7ecf1; --bg: var(--void); --bg-soft: var(--void-2);
--surface: #ffffff; --surface-2: #f4f7fa; --surface-3: #e9eef3;
--glass: rgba(255,255,255,.82); --glass-2: rgba(255,255,255,.9);
--border: #cdd8e2; --border-soft: #e2e8ee;
--grid-line: rgba(20,40,60,.06); --grid-hot: rgba(20,40,60,.1);
--text: #10202b; --text-soft: #33424e; --muted: #5a6b78; --muted-2: #7c8b97;
--c1: #0a86ab; --c1-deep: #06637f; --c1-glow: rgba(10,134,171,.18);
--c2: #c2410c; --c2-deep: #9a3412; --c2-glow: rgba(194,65,12,.16);
--accent: var(--c1); --accent-hover: var(--c1-deep); --accent-soft: rgba(10,134,171,.1); --accent-deep: var(--c1-deep);
--hot: var(--c2); --hot-soft: rgba(194,65,12,.1);
--ok: #1f883d; --warn: #9a6700; --bad: #cf222e; --linux: #1d5fc7; --windows: #7c3ed0; --teal: #006d77; --pink: #c92a6c;
--glow-sm: none; --glow-md: none; --glow-lg: none;
--shadow: 0 1px 0 rgba(0,0,0,.03), 0 14px 40px -18px rgba(13,17,23,.18);
--shadow-soft: 0 4px 14px -6px rgba(13,17,23,.12);
--mark-bg: #ffe2b0; --mark-fg: #3a1d00; --glow-a: rgba(10,134,171,.06); --glow-b: rgba(194,65,12,.05);
--glow-on: 0;
```
(Apply this body to BOTH the `@media (prefers-color-scheme: light){[data-theme="auto"]{…}}` and `[data-theme="light"]{…}` selectors — same as the current file's structure.)

- [ ] **Step 3: Update the stylesheet's top comment** banner from "Terminal, Elevated" to "Tron / digital frontier" (1 line; keep the preserved-selectors note).

- [ ] **Step 4: Verify render + hygiene**

Run harness **D** (dark) → Read `/mnt/c/Temp/readme-dark.png`. Expected: page loads; background near-black, text legible (components not yet re-skinned — that's fine).
Run harness **A**. Expected: OK / OK.

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.css
git commit -m "feat(readme): Tron token system (dark Grid + daylight light variant)"
```

---

## Task 2: Atmosphere — fixed grid / horizon / starfield / glow + scrim + FX canvas scaffold

**Files:**
- Modify: `README.html` (add a fixed atmosphere block as the first child of `<body>`, before `.scroll-progress`)
- Modify: `docs/README/README.css` (atmosphere layer styles)

- [ ] **Step 1: Add atmosphere markup** at the top of `<body>` (decorative → `aria-hidden`):
```html
<div class="grid-world" aria-hidden="true">
  <div class="gw-void"></div>
  <div class="gw-stars"></div>
  <div class="gw-floorwrap"><div class="gw-floor"></div></div>
  <div class="gw-horizon"></div>
  <div class="gw-glow"></div>
</div>
<canvas class="fx-canvas" id="fx-canvas" aria-hidden="true"></canvas>
```

- [ ] **Step 2: Add atmosphere CSS** (append a new section to README.css):
```css
.grid-world{ position:fixed; inset:0; z-index:-2; pointer-events:none; overflow:hidden; perspective:900px; background:var(--void); }
.gw-void{ position:absolute; inset:0; background:radial-gradient(125% 90% at 50% 8%, #0a1622 0%, var(--void) 60%); }
.gw-stars{ position:absolute; inset:-5%; opacity:.7;
  background-image:radial-gradient(1px 1px at 20% 30%,#cfeffd99,transparent),radial-gradient(1px 1px at 70% 20%,#ffffff66,transparent),
    radial-gradient(1px 1px at 85% 60%,#bfe9ff55,transparent),radial-gradient(1px 1px at 40% 70%,#ffffff44,transparent),
    radial-gradient(1px 1px at 55% 45%,#cfeffd55,transparent),radial-gradient(1px 1px at 12% 80%,#ffffff44,transparent),
    radial-gradient(1px 1px at 90% 35%,#cfeffd55,transparent); }
.gw-floorwrap{ position:absolute; left:-30%; right:-30%; bottom:0; height:46vh; }
.gw-floor{ position:absolute; inset:0;
  background-image:linear-gradient(var(--grid-hot) 1px,transparent 1px),linear-gradient(90deg,var(--grid-hot) 1px,transparent 1px);
  background-size:48px 48px; transform:perspective(440px) rotateX(76deg); transform-origin:bottom center;
  mask-image:linear-gradient(transparent 44%,#000 72%); animation:gwFloor 5.5s linear infinite; }
@keyframes gwFloor{ from{background-position:0 0;} to{background-position:0 48px;} }
.gw-horizon{ position:absolute; left:0; right:0; bottom:46vh; height:2px; background:var(--c1);
  box-shadow:0 0 26px 7px var(--c1-glow); opacity:calc(.85*var(--glow-on)); animation:gwHz 4.5s ease-in-out infinite; }
.gw-horizon::after{ content:""; position:absolute; left:0; right:0; bottom:0; height:120px;
  background:radial-gradient(60% 100% at 50% 100%, var(--c1-glow), transparent 70%); opacity:.5; }
@keyframes gwHz{ 0%,100%{opacity:calc(.7*var(--glow-on));} 50%{opacity:calc(1*var(--glow-on));} }
.gw-glow{ position:absolute; inset:0;
  background:radial-gradient(40% 30% at 18% 22%, var(--glow-a), transparent 70%),
             radial-gradient(36% 28% at 86% 70%, var(--glow-b), transparent 70%); }
.fx-canvas{ position:fixed; inset:0; z-index:-1; pointer-events:none; }
/* content sits above atmosphere; scrim added per-region in Task 5 */
.layout{ position:relative; z-index:1; }
```

- [ ] **Step 3: Verify** with harness **D** (dark). Read the screenshot.
Expected: a glowing perspective grid + horizon behind the (still-old-styled) content; text remains readable. Run harness **A** (OK/OK) and **B** (18 ids — unchanged).

- [ ] **Step 4: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): fixed Tron atmosphere (grid floor, horizon, starfield, FX canvas)"
```

---

## Task 3: Page chrome — layout, console sidebar + light-rail, control cluster

**Files:**
- Modify: `README.html` (the `.theme-toggle` button → a `.controls` cluster; sidebar brand)
- Modify: `docs/README/README.css` (layout, `.toc`, `.controls`, scroll-progress)

- [ ] **Step 1: Replace the single theme button** with a 3-button control cluster (keep `#theme-toggle`/`#theme-icon` exactly; add two new buttons — JS wired in Task 7):
```html
<div class="controls">
  <button class="ctl" id="theme-toggle" aria-label="Toggle theme (auto / light / dark)" title="Theme"><span id="theme-icon">◐</span></button>
  <button class="ctl" id="motion-toggle" aria-label="Toggle motion &amp; effects" aria-pressed="true" title="Motion / FX">◉</button>
  <button class="ctl" id="sound-toggle" aria-label="Toggle ambient sound" aria-pressed="false" title="Sound">♪</button>
</div>
```

- [ ] **Step 2: Add control-cluster + console-sidebar CSS:**
```css
.controls{ position:fixed; top:14px; right:16px; z-index:30; display:flex; gap:8px; }
.ctl{ width:38px; height:38px; border-radius:8px; cursor:pointer; font-family:var(--mono); font-size:15px;
  color:var(--c1); background:var(--glass); border:1px solid var(--border); box-shadow:var(--glow-sm);
  display:grid; place-items:center; transition:.15s; }
.ctl:hover{ border-color:var(--c1); box-shadow:var(--glow-md); }
.ctl[aria-pressed="false"]{ color:var(--muted); box-shadow:none; }
.ctl:focus-visible{ outline:2px solid var(--c1); outline-offset:2px; }
/* sidebar console + sliding light-rail on the active scroll-spy item */
nav.toc{ position:sticky; top:0; align-self:start; max-height:100vh; overflow:auto; }
nav.toc a{ position:relative; }
nav.toc a.active{ color:var(--c1); }
nav.toc a.active::before{ content:""; position:absolute; left:-12px; top:4px; bottom:4px; width:3px;
  background:var(--c1); box-shadow:var(--glow-sm); border-radius:2px; }
/* scroll-progress as a light trail */
.scroll-progress{ position:fixed; top:0; left:0; height:3px; z-index:40; width:calc(var(--scroll-progress,0)*100%);
  background:linear-gradient(90deg,var(--c1),var(--c2)); box-shadow:0 0 12px var(--c1-glow); }
```
(Adjust the `.toc a.active` selector to match the existing active-state class set by behavior 4 — keep `.active`.)

- [ ] **Step 3: Verify** harness **D** + **C** (`theme-toggle`, `scroll-progress` hooks still ≥1; new `motion-toggle`/`sound-toggle` present). Buttons render top-right.

- [ ] **Step 4: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): console sidebar light-rail + theme/motion/sound control cluster"
```

---

## Task 4: Hero scene — disc, neon terminal, glow title, CTAs, quickstart kept

**Files:**
- Modify: `README.html` (`header#intro` — restructure; KEEP `.term`, `data-typed`, `.ln`/`.cmd`/`.caret`, `.hero-quickstart`/`.qs-card`/`<pre>` content + the CTA buttons + `.lede`)
- Modify: `docs/README/README.css` (hero styles)

- [ ] **Step 1: Restructure the hero markup.** Wrap the existing hero content in a `.hero-scene` with a local grid/disc; keep the existing `.term[data-typed]` block (with its `.bar`, `.body`, `.ln`, `.cmd`, `.caret`, `.cta`) and the `.hero-quickstart` panel **verbatim in content** — only add wrapper elements + classes:
```html
<header id="intro">
  <div class="hero-scene">
    <div class="hero-disc" aria-hidden="true"><span></span><span></span><span></span><span></span></div>
    <h1 class="hero-title">workstation<span class="cursor" aria-hidden="true"></span><span class="tag">dev env</span></h1>
    <p class="lede"><!-- UNCHANGED existing lede copy --></p>
    <div class="term tilt" data-typed>
      <!-- UNCHANGED existing .bar + .body (.ln/.cmd/.caret) + .cta markup -->
    </div>
  </div>
  <div class="hero-quickstart"><!-- UNCHANGED existing .qs-card linux/windows <pre> blocks --></div>
</header>
```

- [ ] **Step 2: Add hero CSS** (disc, neon terminal, glow title, vector buttons):
```css
.hero-scene{ position:relative; padding:30px 0 26px; }
.hero-title{ font-family:var(--mono); font-size:clamp(34px,6vw,52px); font-weight:700; line-height:1; margin:0 0 14px;
  color:#eafdff; display:flex; align-items:center; gap:14px; text-shadow:0 0 calc(9px*var(--glow-on)) var(--c1-glow),0 0 calc(26px*var(--glow-on)) var(--c1-glow);
  animation:heroBreathe 5s ease-in-out infinite; }
@keyframes heroBreathe{ 0%,100%{text-shadow:0 0 calc(9px*var(--glow-on)) var(--c1-glow),0 0 calc(22px*var(--glow-on)) var(--c1-glow);}
  50%{text-shadow:0 0 calc(13px*var(--glow-on)) var(--c1-glow),0 0 calc(42px*var(--glow-on)) var(--c1-glow);} }
.hero-title .cursor{ width:12px; height:.9em; background:var(--c2); box-shadow:var(--glow-sm); animation:caret 1.1s step-end infinite; }
.hero-title .tag{ font-size:.26em; font-weight:600; letter-spacing:.16em; text-transform:uppercase; color:var(--c2);
  border:1px solid var(--c2); border-radius:5px; padding:6px 9px; box-shadow:inset 0 0 8px var(--c2-glow); }
@keyframes caret{ 50%{opacity:0;} }
.hero-disc{ position:absolute; top:6px; right:18px; width:128px; height:128px; transform:rotateX(64deg); transform-style:preserve-3d; pointer-events:none; opacity:var(--glow-on); }
.hero-disc span{ position:absolute; inset:0; border:2px solid var(--c1); border-radius:50%; box-shadow:0 0 13px var(--c1-glow),inset 0 0 13px var(--c1-glow); opacity:.85; }
.hero-disc span:nth-child(2){ inset:18px; border-color:var(--c2); box-shadow:0 0 11px var(--c2-glow),inset 0 0 11px var(--c2-glow); }
.hero-disc span:nth-child(3){ inset:36px; opacity:.55; }
.hero-disc span:nth-child(4){ inset:0; border-color:transparent; border-top-color:#fff; box-shadow:0 0 14px var(--c1-glow); animation:discScan 2.6s linear infinite; }
@keyframes discScan{ from{transform:rotateZ(0);} to{transform:rotateZ(360deg);} }
/* neon terminal */
.term{ position:relative; border-radius:var(--r); background:var(--glass); border:1px solid var(--c1);
  box-shadow:var(--glow-md), inset 0 0 28px rgba(103,240,255,calc(.06*var(--glow-on))), var(--shadow);
  backdrop-filter:blur(5px); -webkit-backdrop-filter:blur(5px); overflow:hidden; transform-style:preserve-3d; transition:transform .12s ease-out; }
.term::before{ content:""; position:absolute; top:0; left:-40%; width:40%; height:2px;
  background:linear-gradient(90deg,transparent,#fff,transparent); opacity:var(--glow-on); animation:termSweep 3.2s linear infinite; }
@keyframes termSweep{ from{left:-40%;} to{left:120%;} }
.term .bar{ border-bottom:1px solid rgba(103,240,255,.25); }
.term .cta .btn{ font-family:var(--mono); border:1px solid var(--c1); color:var(--c1); background:transparent;
  text-shadow:0 0 calc(8px*var(--glow-on)) var(--c1-glow); border-radius:8px; transition:.18s; }
.term .cta .btn:hover{ background:var(--c1); color:#04121a; text-shadow:none; box-shadow:var(--glow-md); }
.term .cta .btn.win{ border-color:var(--c2); color:var(--c2); text-shadow:0 0 calc(8px*var(--glow-on)) var(--c2-glow); }
.term .cta .btn.win:hover{ background:var(--c2); color:#1a0e02; }
/* HUD corner brackets */
.term::after{ content:""; position:absolute; right:-1px; bottom:-1px; width:13px; height:13px; border:2px solid var(--c1); border-left:0; border-top:0; }
```

- [ ] **Step 3: Verify** harness **D** + **C** (`class="term"` ≥1, `data-typed` ≥1). Read screenshot: glowing title, neon terminal, disc top-right, quickstart panel intact below. Confirm the two `<pre>` quickstart blocks still present: `grep -c '<pre>' README.html` (≥ existing count).

- [ ] **Step 4: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): Tron hero scene (identity disc, neon terminal, glow title, vector CTAs)"
```

---

## Task 5a: Component re-skin — markers, cards, chips, callouts, badges, code

**Files:**
- Modify: `docs/README/README.css` (component styles)
- Modify: `README.html` (add `.tilt` to `.stack-card`/`.tool-card`; add section-marker number via CSS only — no markup number)

- [ ] **Step 1: Section markers** (decorative number via counter; `<h2 id>` text untouched):
```css
main{ counter-reset: sec; }
main > section > h2{ counter-increment: sec; display:flex; align-items:center; gap:14px; font-family:var(--mono); color:#eafdff; text-shadow:0 0 calc(12px*var(--glow-on)) var(--c1-glow); }
main > section > h2::before{ content: counter(sec,decimal-leading-zero) " //"; font-size:.6em; color:#04121a; background:var(--c1); padding:5px 8px; border-radius:5px; box-shadow:var(--glow-sm); }
main > section > h2::after{ content:""; flex:1; height:1px; background:linear-gradient(90deg,var(--c1-glow),transparent); }
```

- [ ] **Step 2: Glass cards + chips + callouts + badges + code.** Apply the neon-glass pattern (real CSS — repeat the pattern for each listed selector):
```css
.stack-card,.tool-card,.callout,details.tree,pre,table{ background:var(--glass-2); border:1px solid var(--border); border-radius:var(--r); box-shadow:var(--shadow-soft); }
.stack-card,.tool-card{ position:relative; overflow:hidden; transition:transform .1s ease-out,border-color .2s,box-shadow .2s; }
.stack-card:hover,.tool-card:hover{ border-color:var(--c1); box-shadow:var(--glow-md); }
.tool-card.cat-1{ --cat:var(--c1);} .tool-card.cat-2{ --cat:var(--c2);} .tool-card.cat-3{ --cat:var(--ok);} .tool-card.cat-4{ --cat:var(--windows);} .tool-card.cat-5{ --cat:var(--teal);} /* map existing cat-* to hues */
.tool-card::before{ content:""; position:absolute; left:0; top:0; right:0; height:2px; background:var(--cat,var(--c1)); box-shadow:0 0 12px var(--cat,var(--c1-glow)); }
.chip{ font-family:var(--mono); color:var(--text-soft); background:var(--surface); border:1px solid var(--border); border-bottom-width:2px; border-radius:7px; padding:7px 10px; transition:.15s; }
.chip:hover,.chip.match-hit{ color:#04121a; background:var(--c1); border-color:var(--c1); box-shadow:var(--glow-md); transform:translateY(-2px); }
.callout{ position:relative; padding-left:18px; }
.callout::before{ content:""; position:absolute; left:0; top:0; bottom:0; width:3px; background:var(--c2); box-shadow:0 0 12px var(--c2-glow); }
.badge.dev{ color:var(--c1); border:1px solid var(--c1); box-shadow:var(--glow-sm); }
.badge.prod{ color:var(--c2); border:1px solid var(--c2); box-shadow:0 0 10px var(--c2-glow); }
.copy-btn{ font-family:var(--mono); color:var(--c1); background:var(--glass); border:1px solid var(--border); border-radius:6px; }
.copy-btn:hover{ border-color:var(--c1); box-shadow:var(--glow-sm); }
mark{ background:var(--mark-bg); color:var(--mark-fg); border-radius:3px; }
```

- [ ] **Step 3: Add `.tilt` hook** to the two card families in `README.html`:
```bash
# stack + tool cards become pointer-tilt targets (JS in Task 11)
sed -i 's/class="stack-card/class="stack-card tilt/g; s/class="tool-card/class="tool-card tilt/g' README.html
```
(Verify the substitution didn't double-apply: `grep -c 'tilt tilt' README.html` → 0.)

- [ ] **Step 4: Verify** harness **D** + **C** (`toolbelt-grid`, `tool-filter` hooks intact; `tool-card`/`chip`/`match-hit` classes present). Read screenshot: numbered HUD markers, neon cards/chips.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.css
git commit -m "feat(readme): neon-glass markers, cards, chips, callouts, badges, code"
```

---

## Task 5b: Component re-skin — tables, tree, flow steps, tabs, troubleshooting

**Files:**
- Modify: `docs/README/README.css`

- [ ] **Step 1: Tables (HUD readout):**
```css
table{ width:100%; border-collapse:collapse; overflow:hidden; }
thead th{ font-family:var(--mono); font-size:.72rem; letter-spacing:.12em; text-transform:uppercase; color:var(--c2); text-align:left; padding:11px 13px; border-bottom:1px solid var(--border); background:rgba(255,162,77,calc(.05*var(--glow-on))); }
tbody td{ font-family:var(--mono); padding:11px 13px; border-bottom:1px solid var(--border-soft); color:var(--text-soft); }
tbody tr{ transition:.15s; }
tbody tr:hover td{ background:rgba(103,240,255,calc(.06*var(--glow-on))); color:var(--text); }
tbody tr:hover td:first-child{ box-shadow:inset 3px 0 0 var(--c1); }
```

- [ ] **Step 2: Tree / flow steps / tabs:**
```css
details.tree summary{ cursor:pointer; font-family:var(--mono); }
.tree .note{ color:var(--muted); }
.flow .step .num{ font-family:var(--mono); color:#04121a; background:var(--c1); border-radius:5px; padding:3px 7px; box-shadow:var(--glow-sm); }
.flow .arrow{ color:var(--c1); text-shadow:var(--glow-sm); }
.tab-labels label{ font-family:var(--mono); border:1px solid var(--border); color:var(--muted); }
.tabs input:checked + .tab-labels label.sel, .tab-labels label[aria-selected="true"]{ color:var(--c1); border-color:var(--c1); box-shadow:var(--glow-sm); }
```
(Match the existing tab mechanism's checked-selector — inspect the current `.tabs` CSS and mirror its `:checked ~ ...` form; keep `panel-dev`/`panel-prod`/`ar-panel-*` ids.)

- [ ] **Step 3: Troubleshooting `<details data-ts>`:**
```css
details[data-ts]{ background:var(--glass-2); border:1px solid var(--border); border-radius:var(--r); margin:10px 0; overflow:hidden; }
details[data-ts] summary{ list-style:none; cursor:pointer; font-family:var(--mono); color:var(--text-soft); padding:12px 14px; display:flex; gap:9px; align-items:center; }
details[data-ts] summary::-webkit-details-marker{ display:none; }
details[data-ts] summary::before{ content:"❯"; color:var(--c1); text-shadow:var(--glow-sm); transition:transform .2s; }
details[data-ts][open] summary::before{ transform:rotate(90deg); }
.checklist li::before{ color:var(--c1); }
```

- [ ] **Step 4: Verify** harness **D** + **C** (`ts-filter`/`ts-count` intact). Read screenshot of a mid-page section (use `--window-size` tall + scroll via a longer height). Confirm tables/tabs/troubleshooting legible.

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.css
git commit -m "feat(readme): neon tables, tree, flow steps, tabs, troubleshooting"
```

---

## Task 5c: Content scrim + dense-content readability

**Files:**
- Modify: `docs/README/README.css`

- [ ] **Step 1: Add a scrim behind main content** so the immersive grid never fights prose:
```css
main::before{ content:""; position:fixed; inset:0; z-index:-1; pointer-events:none;
  background:linear-gradient(180deg, rgba(4,7,13,.18), rgba(4,7,13,.66)); }
[data-theme="light"] main::before, html:not([data-theme="dark"]) main::before{ background:linear-gradient(180deg, rgba(238,242,246,.35), rgba(238,242,246,.78)); }
.prose, main p, main li{ max-width:var(--maxw); }
```
(If light-auto detection via selector is awkward, gate the light scrim with the same media/attr pattern the tokens use.)

- [ ] **Step 2: Verify** harness **D** — Read screenshot; body text contrast must be strong over the grid. Spot-check a paragraph-heavy section.

- [ ] **Step 3: Commit**
```bash
git add docs/README/README.css
git commit -m "feat(readme): content scrim keeps dense prose legible over the grid"
```

---

## Task 6: Preserve + re-verify behaviors 1–11 against the new markup

**Files:**
- Modify: `docs/README/README.js` (selector touch-ups only, if needed)

- [ ] **Step 1: Re-point any selectors** the re-skin changed. The kept hooks are unchanged by design, but confirm the typed-animation still finds its nodes: `.term[data-typed]`, `.body .ln`, `lines[0] .cmd`, `.caret`. If the hero markup in Task 4 kept them (it did), no change. If the active-TOC class changed, keep `.active`.

- [ ] **Step 2: Run the structural contracts** — harness **B** (18 ids) and **C** (all hooks ≥1).

- [ ] **Step 3: Manual interaction checklist (harness F), behaviors 1–11.** Open `README.html` in a desktop browser and verify each, expected result in parentheses:
  1. Theme toggle cycles ◐/☀/☾ and persists on reload (localStorage `readme-theme`).
  2. Every `<pre>` shows a copy button; click copies (`.copied` flash).
  3. `#` anchors appear on `h2/h3/h4[id]` hover; click updates the URL hash.
  4. Scroll-spy: the sidebar light-rail follows the active section (`.active`+`aria-current`).
  5. Type in search → matches `<mark>`ed, non-matching sections `.dimmed`, TOC entries `.hidden`, count in `#toc-search-meta`.
  6. `/` focuses search; `Esc` clears/blurs.
  7. Toolbelt `#tool-filter` → dims non-matching `.tool-card`, highlights `.chip.match-hit`, count in `#tool-filter-meta`.
  8. Troubleshooting `#ts-filter` → opens/filters `[data-ts]`, count in `#ts-count`.
  9. Resize ≤900px → TOC collapses (`#toc-collapse-ctrl`, `aria-expanded`).
  10. Scroll → progress trail fills (`--scroll-progress`).
  11. On load (motion on) the hero terminal types its command + streams `✓` lines.

- [ ] **Step 4: Commit** (selector fixes, if any; otherwise a no-op verify commit is fine)
```bash
git add docs/README/README.js
git commit -m "fix(readme): keep behaviors 1-11 wired to the re-skinned markup" --allow-empty
```

---

## Task 7: JS foundation — capability gates, Prefs module, shared rAF Scheduler, toggle wiring

**Files:**
- Modify: `docs/README/README.js` (add Sections A + B near the top of the IIFE; wire `#motion-toggle`/`#sound-toggle`)

- [ ] **Step 1: Add capability gates + Prefs (Section A):**
```js
var reduceQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
var fineQuery   = window.matchMedia("(pointer: fine)");
function loadPref(k, d){ try{ var v=localStorage.getItem(k); return v===null?d:v==="1"; }catch(e){ return d; } }
function savePref(k, v){ try{ localStorage.setItem(k, v?"1":"0"); }catch(e){} }
var Prefs = {
  motion: loadPref("readme-motion", !reduceQuery.matches), // default ON unless OS reduced-motion
  sound:  loadPref("readme-sound", false)                  // default OFF
};
// fxEnabled: ambient + pointer FX allowed? (motion gate). pointerFx: also requires a fine pointer.
function fxEnabled(){ return Prefs.motion && !reduceQuery.matches; }
function pointerFx(){ return fxEnabled() && fineQuery.matches; }
document.documentElement.classList.toggle("fx-off", !fxEnabled());
```

- [ ] **Step 2: Add the single shared Scheduler (Section B):**
```js
var Scheduler = (function(){
  var subs = []; var running = false;
  function frame(t){ running = false;
    if(document.hidden) return;
    for(var i=0;i<subs.length;i++){ try{ subs[i](t); }catch(e){} }
    if(subs.length){ running = true; requestAnimationFrame(frame); }
  }
  return {
    add:function(fn){ if(subs.indexOf(fn)<0) subs.push(fn); this.kick(); },
    remove:function(fn){ var i=subs.indexOf(fn); if(i>=0) subs.splice(i,1); },
    kick:function(){ if(!running && subs.length && !document.hidden){ running=true; requestAnimationFrame(frame); } }
  };
})();
document.addEventListener("visibilitychange", function(){ if(!document.hidden) Scheduler.kick(); });
```

- [ ] **Step 3: Wire the motion + sound toggles** (sound engine itself is Task 16; here just persist + reflect state, and a hook other subsystems read):
```js
var motionBtn = document.getElementById("motion-toggle");
var soundBtn  = document.getElementById("sound-toggle");
function reflectMotion(){
  if(motionBtn){ motionBtn.setAttribute("aria-pressed", String(Prefs.motion)); motionBtn.textContent = Prefs.motion ? "◉" : "○"; }
  document.documentElement.classList.toggle("fx-off", !fxEnabled());
  window.dispatchEvent(new CustomEvent("readme:fxchange"));
}
function reflectSound(){ if(soundBtn){ soundBtn.setAttribute("aria-pressed", String(Prefs.sound)); soundBtn.textContent = Prefs.sound ? "♪" : "♪̶"; } }
if(motionBtn) motionBtn.addEventListener("click", function(){ Prefs.motion=!Prefs.motion; savePref("readme-motion",Prefs.motion); reflectMotion(); });
if(soundBtn)  soundBtn.addEventListener("click",  function(){ Prefs.sound=!Prefs.sound;  savePref("readme-sound",Prefs.sound);  reflectSound(); });
reduceQuery.addEventListener && reduceQuery.addEventListener("change", reflectMotion);
reflectMotion(); reflectSound();
```

- [ ] **Step 4: Add the `.fx-off` static guard to CSS** (README.css) — when FX is off, kill all decorative animation immediately (this is ALSO the `prefers-reduced-motion` path; include both):
```css
@media (prefers-reduced-motion: reduce){ *,*::before,*::after{ animation:none!important; transition:none!important; scroll-behavior:auto!important; } }
.fx-off *,.fx-off *::before,.fx-off *::after{ animation:none!important; }
.fx-off .fx-canvas{ display:none; }
```

- [ ] **Step 5: Verify** — open the page; click the motion toggle → grid/horizon/title animation stops and `<html>` gains `fx-off`; reload persists. Click sound toggle → `aria-pressed` flips. Harness **A**.

- [ ] **Step 6: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): JS foundation — prefs, capability gates, shared rAF scheduler, toggles"
```

---

## Task 8: Behavior 13 — mouse-parallax world + hero terminal tilt

**Files:**
- Modify: `docs/README/README.js`

- [ ] **Step 1: Add the parallax subsystem** (reads pointer, moves the fixed atmosphere layers + tilts the hero terminal; subscribes to the shared Scheduler; self-removes when `pointerFx()` is false):
```js
(function initParallax(){
  var world = document.querySelector(".grid-world");
  var floor = document.querySelector(".gw-floorwrap");
  var stars = document.querySelector(".gw-stars");
  var horizon = document.querySelector(".gw-horizon");
  var disc = document.querySelector(".hero-disc");
  var term = document.querySelector(".term[data-typed]");
  if(!world) return;
  var tx=0, ty=0, cx=0, cy=0, active=false;
  function onMove(e){ cx = e.clientX/window.innerWidth - .5; cy = e.clientY/window.innerHeight - .5; }
  function tick(){
    tx += (cx - tx)*0.06; ty += (cy - ty)*0.06;
    if(stars)   stars.style.transform   = "translate("+(-tx*14)+"px,"+(-ty*14)+"px)";
    if(floor)   floor.style.transform   = "translate("+(-tx*26)+"px,0)";
    if(horizon) horizon.style.transform = "translate("+(-tx*10)+"px,0)";
    if(disc)    disc.style.transform     = "rotateX(64deg) translate("+(-tx*30)+"px,"+(-ty*30)+"px)";
    if(term)    term.style.transform     = "rotateY("+(tx*5)+"deg) rotateX("+(-ty*5)+"deg)";
  }
  function enable(){ if(active||!pointerFx()) return; active=true; window.addEventListener("pointermove",onMove,{passive:true}); Scheduler.add(tick); }
  function disable(){ if(!active) return; active=false; window.removeEventListener("pointermove",onMove); Scheduler.remove(tick);
    [stars,floor,horizon,disc,term].forEach(function(el){ if(el) el.style.transform=""; }); }
  window.addEventListener("readme:fxchange", function(){ pointerFx()?enable():disable(); });
  enable();
})();
```

- [ ] **Step 2: Verify** — desktop: move the mouse → grid/disc/stars shift at different depths, hero terminal tilts toward cursor. Toggle motion off → everything recenters and stops. Emulate touch (DevTools device mode) → no parallax.

- [ ] **Step 3: Commit**
```bash
git add docs/README/README.js
git commit -m "feat(readme): behavior 13 — mouse-parallax world + hero terminal tilt"
```

---

## Task 9: Behavior 14 — FX canvas singleton + cursor light-trail + reticle

**Files:**
- Modify: `docs/README/README.js`

- [ ] **Step 1: Add the FX canvas singleton (Section C)** — sizing, DPR≤2, shared by Tasks 9/10:
```js
var FX = (function(){
  var cv = document.getElementById("fx-canvas"); if(!cv) return null;
  var ctx = cv.getContext("2d"), W=0,H=0,DPR=1;
  function size(){ DPR=Math.min(2,window.devicePixelRatio||1); W=window.innerWidth; H=window.innerHeight;
    cv.width=W*DPR; cv.height=H*DPR; cv.style.width=W+"px"; cv.style.height=H+"px"; ctx.setTransform(DPR,0,0,DPR,0,0); }
  window.addEventListener("resize", size); size();
  return { get ctx(){return ctx;}, get W(){return W;}, get H(){return H;}, clear:function(){ctx.clearRect(0,0,W,H);} };
})();
```

- [ ] **Step 2: Add the trail + reticle subsystem** (draws on FX; one Scheduler fn shared with ripples via a registry to keep a single clear/loop — here the trail registers a drawer):
```js
var fxDrawers = []; // each: function(ctx){...} ; registered by trail(14) + ripples(15)
function fxLoop(){ if(!FX) return; FX.clear(); for(var i=0;i<fxDrawers.length;i++) fxDrawers[i](FX.ctx); }
(function initTrail(){
  if(!FX) return;
  var trail=[], rx=-1, ry=-1, active=false;
  function onMove(e){ rx=e.clientX; ry=e.clientY; trail.push({x:rx,y:ry}); if(trail.length>24) trail.shift(); }
  function draw(ctx){
    if(trail.length>1){ ctx.lineCap="round"; ctx.shadowColor="#67f0ff";
      for(var i=1;i<trail.length;i++){ var a=i/trail.length; ctx.strokeStyle="rgba(103,240,255,"+(a*0.9)+")"; ctx.shadowBlur=14; ctx.lineWidth=a*4+0.5;
        ctx.beginPath(); ctx.moveTo(trail[i-1].x,trail[i-1].y); ctx.lineTo(trail[i].x,trail[i].y); ctx.stroke(); } }
    if(rx>=0){ ctx.shadowBlur=10; ctx.strokeStyle="rgba(103,240,255,.7)"; ctx.lineWidth=1.5;
      ctx.beginPath(); ctx.arc(rx,ry,9,0,7); ctx.stroke(); ctx.beginPath(); ctx.moveTo(rx-14,ry); ctx.lineTo(rx-5,ry); ctx.moveTo(rx+5,ry); ctx.lineTo(rx+14,ry); ctx.stroke(); }
    if(trail.length) trail.shift(); // decay when idle
    ctx.shadowBlur=0;
  }
  function enable(){ if(active||!pointerFx()) return; active=true; window.addEventListener("pointermove",onMove,{passive:true}); fxDrawers.push(draw); Scheduler.add(fxLoop); document.documentElement.classList.add("hide-cursor"); }
  function disable(){ if(!active) return; active=false; window.removeEventListener("pointermove",onMove); var i=fxDrawers.indexOf(draw); if(i>=0) fxDrawers.splice(i,1); if(!fxDrawers.length) Scheduler.remove(fxLoop); document.documentElement.classList.remove("hide-cursor"); }
  window.addEventListener("readme:fxchange", function(){ pointerFx()?enable():disable(); });
  enable();
})();
```

- [ ] **Step 3: Reticle/cursor CSS** — augment, don't break usability. Keep the native cursor on text/inputs; only dim it on the empty/background regions:
```css
.hide-cursor{ cursor:none; }
.hide-cursor a,.hide-cursor button,.hide-cursor input,.hide-cursor summary,.hide-cursor [role="button"],.hide-cursor pre,.hide-cursor code,.hide-cursor p,.hide-cursor li,.hide-cursor td,.hide-cursor th{ cursor:auto; }
```
(So links/inputs keep their normal cursor; the neon reticle rides over open space. Touch + fx-off never add `.hide-cursor`.)

- [ ] **Step 4: Verify** — desktop: a cyan trail follows the pointer and fades; a reticle rides open space; over links/inputs the normal cursor returns; clicking a link still works. Motion off → canvas hidden, native cursor everywhere.

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 14 — FX canvas + cursor light-trail + reticle"
```

---

## Task 10: Behavior 15 — click energy pulses + grid ripples

**Files:**
- Modify: `docs/README/README.js`

- [ ] **Step 1: Add the pulse/ripple subsystem** (registers a drawer on the same `fxDrawers`/`fxLoop`; capped):
```js
(function initPulses(){
  if(!FX) return;
  var ripples=[], sparks=[], active=false, MAX=6;
  function onDown(e){
    if(!fxEnabled()) return;
    if(ripples.length<MAX) ripples.push({x:e.clientX,y:e.clientY,rad:4,life:1});
    for(var i=0;i<10;i++){ var a=Math.PI*2*i/10; sparks.push({x:e.clientX,y:e.clientY,vx:Math.cos(a)*(2+i%3),vy:Math.sin(a)*(2+i%3),life:1}); }
    if(sparks.length>120) sparks.splice(0,sparks.length-120);
    Scheduler.add(fxLoop);
  }
  function draw(ctx){
    ctx.shadowBlur=12;
    for(var j=ripples.length-1;j>=0;j--){ var rp=ripples[j]; rp.rad+=6; rp.life-=0.025;
      ctx.shadowColor="#ffa24d"; ctx.strokeStyle="rgba(255,162,77,"+Math.max(0,rp.life)+")"; ctx.lineWidth=2;
      ctx.beginPath(); ctx.arc(rp.x,rp.y,rp.rad,0,7); ctx.stroke();
      ctx.strokeStyle="rgba(103,240,255,"+Math.max(0,rp.life*.7)+")"; ctx.beginPath(); ctx.arc(rp.x,rp.y,rp.rad*.6,0,7); ctx.stroke();
      if(rp.life<=0) ripples.splice(j,1); }
    for(var k=sparks.length-1;k>=0;k--){ var s=sparks[k]; s.x+=s.vx; s.y+=s.vy; s.vy+=.05; s.life-=.03;
      ctx.shadowColor="#ffa24d"; ctx.fillStyle="rgba(255,162,77,"+Math.max(0,s.life)+")";
      ctx.beginPath(); ctx.arc(s.x,s.y,1.6,0,7); ctx.fill(); if(s.life<=0) sparks.splice(k,1); }
    ctx.shadowBlur=0;
  }
  function enable(){ if(active||!fxEnabled()) return; active=true; window.addEventListener("pointerdown",onDown,{passive:true}); fxDrawers.push(draw); }
  function disable(){ if(!active) return; active=false; window.removeEventListener("pointerdown",onDown); var i=fxDrawers.indexOf(draw); if(i>=0) fxDrawers.splice(i,1); }
  window.addEventListener("readme:fxchange", function(){ fxEnabled()?enable():disable(); });
  enable();
})();
```
(Note: pulses use `fxEnabled()` not `pointerFx()` — a tap on touch may still pulse; harmless and cheap. The `fxLoop` self-stops when `fxDrawers` empties and no ripples remain — acceptable; the loop simply clears one extra frame.)

- [ ] **Step 2: Verify** — click anywhere → orange shockwave + cyan inner ring + sparks; multiple clicks capped; CPU returns to idle after. Motion off → no pulses.

- [ ] **Step 3: Commit**
```bash
git add docs/README/README.js
git commit -m "feat(readme): behavior 15 — click energy pulses + grid ripples"
```

---

## Task 11: Behavior 16 — 3D pointer-tilt on `.tilt` panels

**Files:**
- Modify: `docs/README/README.js`
- Modify: `docs/README/README.css` (glare element styles)

- [ ] **Step 1: Add a glare span to tilt targets at runtime + the delegated tilt handler:**
```js
(function initTilt(){
  var els = Array.prototype.slice.call(document.querySelectorAll(".tilt"));
  els.forEach(function(el){ if(!el.querySelector(".glare")){ var g=document.createElement("span"); g.className="glare"; g.setAttribute("aria-hidden","true"); el.appendChild(g); } });
  function onMove(e){ var el=e.currentTarget, r=el.getBoundingClientRect();
    var px=(e.clientX-r.left)/r.width-.5, py=(e.clientY-r.top)/r.height-.5;
    el.style.setProperty("--gx",(e.clientX-r.left)+"px"); el.style.setProperty("--gy",(e.clientY-r.top)+"px");
    if(pointerFx()) el.style.transform="perspective(700px) rotateY("+(px*8)+"deg) rotateX("+(-py*8)+"deg) translateZ(6px)"; }
  function onLeave(e){ e.currentTarget.style.transform=""; }
  els.forEach(function(el){ el.addEventListener("pointermove",onMove); el.addEventListener("pointerleave",onLeave); });
})();
```
(Glare tracks even when tilt is off; transform only applies under `pointerFx()`. The hero `.term` already has `.tilt` from Task 4 and is also parallax-tilted in Task 8 — to avoid double-tilt, REMOVE `.tilt` from the hero `.term` markup so parallax owns it; tool/stack cards keep `.tilt`.)

- [ ] **Step 2: Glare CSS:**
```css
.tilt{ position:relative; }
.tilt > .glare{ position:absolute; inset:0; pointer-events:none; opacity:0; transition:opacity .2s; border-radius:inherit;
  background:radial-gradient(220px circle at var(--gx,50%) var(--gy,50%), rgba(103,240,255,calc(.22*var(--glow-on))), transparent 60%); }
.tilt:hover > .glare{ opacity:1; }
```

- [ ] **Step 3: Fix the hero double-tilt** — in `README.html` remove `tilt` from the hero `.term` (Task 4 added it; parallax tilts it instead):
```bash
sed -i 's/class="term tilt"/class="term"/' README.html
grep -c 'class="term tilt"' README.html   # expect 0
```

- [ ] **Step 4: Verify** — hover a tool card → it tilts toward the cursor with a tracking glare + edge glow; hero terminal still tilts via parallax (not doubled). Motion off → glare only on hover, no rotation.

- [ ] **Step 5: Commit**
```bash
git add README.html docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 16 — 3D pointer-tilt + glare on panels"
```

---

## Task 12: Behavior 17 — scroll-as-camera

**Files:**
- Modify: `docs/README/README.js`

- [ ] **Step 1: Add scroll-camera** (parallax the global floor/horizon by scroll; piggyback the existing rAF-throttled scroll handler that drives `--scroll-progress`, or add a passive scroll listener that sets a CSS var consumed by the atmosphere):
```js
(function initScrollCam(){
  var root=document.documentElement; var pending=false;
  function paint(){ pending=false; if(!fxEnabled()){ root.style.setProperty("--cam-y","0px"); return; }
    var y=window.scrollY||0; root.style.setProperty("--cam-y", (Math.min(y*0.06,80))+"px"); }
  function onScroll(){ if(!pending){ pending=true; requestAnimationFrame(paint); } }
  window.addEventListener("scroll", onScroll, {passive:true});
  window.addEventListener("readme:fxchange", paint); paint();
})();
```

- [ ] **Step 2: Consume `--cam-y` in CSS** (atmosphere drifts down as you scroll → "flying" feel):
```css
.gw-floorwrap{ transform:translateY(calc(var(--cam-y,0px))); }
.gw-stars{ transform:translateY(calc(var(--cam-y,0px) * .4)); }
```
(Note: parallax Task 8 also sets `.gw-floorwrap`/`.gw-stars` transforms inline — reconcile by having parallax write to CSS vars `--px-floor`/`--px-stars` instead of `style.transform`, and compose both in CSS. Update Task 8's `tick()` to set vars: `floor.style.setProperty('--px-x', ...)`, then CSS `transform:translate(var(--px-x,0),0) translateY(var(--cam-y,0))`. Apply this composition fix here.)

- [ ] **Step 3: Verify** — scroll down → grid/stars drift, reinforcing depth; scroll-spy + anchor jumps still land correctly; motion off → no drift.

- [ ] **Step 4: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 17 — scroll-as-camera grid drift"
```

---

## Task 13: Behavior 18 — section boot-on-scroll (de-rez in)

**Files:**
- Modify: `docs/README/README.js`
- Modify: `docs/README/README.css`

- [ ] **Step 1: Add a SEPARATE IntersectionObserver** (do NOT touch behavior 4's scroll-spy observer) that adds `.booted` once per section:
```js
(function initSectionBoot(){
  var secs = Array.prototype.slice.call(document.querySelectorAll("main > section"));
  if(!fxEnabled()){ secs.forEach(function(s){ s.classList.add("booted"); }); return; }
  var io = new IntersectionObserver(function(entries){
    entries.forEach(function(en){ if(en.isIntersecting){ en.target.classList.add("booted"); io.unobserve(en.target); } });
  }, { rootMargin:"0px 0px -12% 0px", threshold:0.08 });
  secs.forEach(function(s){ io.observe(s); });
  window.addEventListener("readme:fxchange", function(){ if(!fxEnabled()) secs.forEach(function(s){ s.classList.add("booted"); }); });
})();
```

- [ ] **Step 2: De-rez reveal CSS** (sections start dimmed/clipped, animate in on `.booted`; reduced-motion shows them immediately because JS adds `.booted` up-front when fx off, and the CSS guard kills the transition):
```css
main > section{ opacity:1; }
.fx-on main > section:not(.booted){ opacity:0; transform:translateY(14px); clip-path:inset(0 0 100% 0); }
.fx-on main > section.booted{ opacity:1; transform:none; clip-path:inset(0 0 0 0); transition:opacity .5s ease, transform .5s ease, clip-path .6s ease; }
```
Add the `fx-on` mirror class in Task 7's `reflectMotion()`: `document.documentElement.classList.toggle("fx-on", fxEnabled());` (so CSS can scope reveal-only-when-on and never hide content when off).

- [ ] **Step 3: Guard against hidden content** — if JS fails, sections must be visible: the base rule keeps `opacity:1`; only `.fx-on …:not(.booted)` hides, and `.fx-on` is only ever set by JS when FX is on. Verify with JS disabled: all sections visible.

- [ ] **Step 4: Verify** — scroll → each section de-rezzes in once; scroll back up → no re-trigger; motion off → all sections present immediately; JS off → all visible.

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 18 — section boot-on-scroll de-rez"
```

---

## Task 14: Behavior 12 — boot / "system online" intro (folds in the typed hero)

**Files:**
- Modify: `docs/README/README.js` (this REPLACES the standalone behavior-11 trigger; the typing logic stays, now sequenced after the grid power-on)

- [ ] **Step 1: Wrap the existing typed-hero logic in a boot sequence.** Keep the current `.term[data-typed]` typing function; add a pre-roll that powers the grid on, then calls it. Skippable + once:
```js
(function initBoot(){
  var html=document.documentElement;
  function finish(){ html.classList.remove("booting"); html.classList.add("booted-done"); }
  // typeHero(): the EXISTING behavior-11 routine, refactored into a named fn returning when done.
  if(!fxEnabled()){ finish(); /* static: ensure hero fully rendered */ revealHeroStatic(); return; }
  html.classList.add("booting");
  var skipped=false;
  function skip(){ if(skipped) return; skipped=true; cleanup(); revealHeroStatic(); finish(); }
  function cleanup(){ ["click","keydown","wheel","touchstart"].forEach(function(ev){ window.removeEventListener(ev,skip); }); }
  ["click","keydown","wheel","touchstart"].forEach(function(ev){ window.addEventListener(ev,skip,{passive:true,once:true}); });
  // sequence: grid powers on (CSS via .booting), then type, then finish
  setTimeout(function(){ if(skipped) return; typeHero(function(){ cleanup(); finish(); }); }, 700);
})();
```
Define `revealHeroStatic()` = the function that shows the hero terminal's final lines instantly (the current code's reduced-motion branch already does this; extract it). `typeHero(done)` = the current typing routine with a `done` callback at the end.

- [ ] **Step 2: Boot CSS** — the grid "powers on" during `.booting` (lines draw + horizon ignites); reserve hero height to avoid layout shift:
```css
.booting .gw-floor{ animation:gwBootFloor 0.7s ease-out, gwFloor 5.5s linear .7s infinite; }
@keyframes gwBootFloor{ from{opacity:0; filter:brightness(3);} to{opacity:1; filter:brightness(1);} }
.booting .gw-horizon{ animation:gwBootHz .7s ease-out; }
@keyframes gwBootHz{ from{transform:scaleX(0); opacity:1;} to{transform:scaleX(1);} }
.term .body{ min-height:7.5em; } /* reserve so streaming lines don't shift layout */
```

- [ ] **Step 3: Verify** — fresh load (motion on): grid powers on, then the terminal types + streams; clicking/scrolling/keypress during the intro jumps to the final state; no layout shift; runs once per load. Reduced-motion / motion-off: hero fully rendered immediately, no intro. Re-verify behavior 11's final state matches the old output exactly.

- [ ] **Step 4: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 12 — boot/system-online intro (subsumes typed hero)"
```

---

## Task 15: Behavior 19 — Konami "derez" easter egg

**Files:**
- Modify: `docs/README/README.js`
- Modify: `docs/README/README.css`

- [ ] **Step 1: Add the Konami detector + derez trigger:**
```js
(function initKonami(){
  var seq=[38,38,40,40,37,39,37,39,66,65], pos=0;
  document.addEventListener("keydown", function(e){
    pos = (e.keyCode===seq[pos]) ? pos+1 : (e.keyCode===seq[0]?1:0);
    if(pos===seq.length){ pos=0; derez(); }
  });
  function derez(){ if(!fxEnabled()) return; var b=document.body; b.classList.add("derez"); setTimeout(function(){ b.classList.remove("derez"); }, 1400); }
})();
```

- [ ] **Step 2: Derez CSS** (brief glitch/reassemble; reduced-motion no-op because JS gates on `fxEnabled()`):
```css
@keyframes derez{ 0%{filter:none;transform:none;} 20%{filter:hue-rotate(40deg) contrast(1.4);transform:skewX(2deg) translateX(3px);}
  40%{filter:invert(.1) brightness(1.3);transform:skewX(-3deg) translateX(-4px);} 60%{filter:none;transform:translateY(2px);}
  100%{filter:none;transform:none;} }
.derez{ animation:derez 1.4s steps(20) 1; }
```

- [ ] **Step 3: Verify** — type ↑↑↓↓←→←→ B A → page derez/reassemble once; no functional breakage after; motion off → no-op.

- [ ] **Step 4: Commit**
```bash
git add docs/README/README.js docs/README/README.css
git commit -m "feat(readme): behavior 19 — konami derez easter egg"
```

---

## Task 16: Behavior 20 — ambient Web-Audio SFX (opt-in)

**Files:**
- Modify: `docs/README/README.js`

- [ ] **Step 1: Add a synthesized SFX engine** (no asset files; only resumes after a user gesture; gated by `Prefs.sound`):
```js
var SFX = (function(){
  var actx=null, master=null;
  function ensure(){ if(actx) return; try{ actx=new (window.AudioContext||window.webkitAudioContext)(); master=actx.createGain(); master.gain.value=0.05; master.connect(actx.destination); }catch(e){ actx=null; } }
  function blip(freq, dur, type){ if(!Prefs.sound) return; ensure(); if(!actx) return; if(actx.state==="suspended") actx.resume();
    var o=actx.createOscillator(), g=actx.createGain(); o.type=type||"sine"; o.frequency.value=freq;
    g.gain.setValueAtTime(0.0001,actx.currentTime); g.gain.exponentialRampToValueAtTime(0.6,actx.currentTime+0.01);
    g.gain.exponentialRampToValueAtTime(0.0001,actx.currentTime+(dur||0.12)); o.connect(g); g.connect(master); o.start(); o.stop(actx.currentTime+(dur||0.12)+0.02); }
  return { hover:function(){ blip(880,0.06,"sine"); }, click:function(){ blip(420,0.14,"triangle"); }, boot:function(){ blip(180,0.5,"sawtooth"); } };
})();
// wire (cheap, throttled): clicks + key nav already exist; hover only on interactive elements
document.addEventListener("pointerdown", function(){ SFX.click(); });
var lastHover=0;
document.addEventListener("pointerover", function(e){ if(!Prefs.sound) return; if(!e.target.closest("a,button,.chip,.tool-card,summary")) return;
  var t=Date.now(); if(t-lastHover>70){ lastHover=t; SFX.hover(); } });
```

- [ ] **Step 2: Trigger `SFX.boot()`** from the boot sequence (Task 14) when `Prefs.sound` — add `SFX.boot()` at the start of `typeHero`.

- [ ] **Step 3: Verify** — sound OFF by default (no audio on load/click). Toggle sound ON → clicks/hovers/boot emit subtle blips; persists across reload; no autoplay warning in console (audio only starts on gesture). Motion off but sound on → SFX still works (orthogonal).

- [ ] **Step 4: Commit**
```bash
git add docs/README/README.js
git commit -m "feat(readme): behavior 20 — opt-in synthesized Web-Audio SFX"
```

---

## Task 17: A11y + performance + light-mode AA + reduced-motion final pass

**Files:**
- Modify: `docs/README/README.css` (focus rings, light tweaks)
- Modify: `docs/README/README.js` (only if a gap is found)

- [ ] **Step 1: Focus-visible neon rings everywhere:**
```css
a:focus-visible,button:focus-visible,input:focus-visible,summary:focus-visible,.chip:focus-visible,[tabindex]:focus-visible{
  outline:2px solid var(--c1); outline-offset:2px; border-radius:4px; }
```

- [ ] **Step 2: Reduced-motion full audit.** Force it on in headless and confirm a static page:
```bash
MSEDGE='/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
"$MSEDGE" --headless=new --disable-gpu --force-prefers-reduced-motion=1 --window-size=1440,2400 \
  --screenshot='C:\Temp\readme-reduced.png' 'http://localhost:8099/README.html'
```
Read `/mnt/c/Temp/readme-reduced.png`: full hero rendered, grid static, no canvas. Also confirm in DevTools (Rendering → emulate reduce): no rAF activity (Performance monitor), `fx-canvas` hidden.

- [ ] **Step 3: Light-mode AA check.** Toggle to light; screenshot; verify body text, `--c1`/`--c2` on white, badges, table headers all read clearly (no glow haze). Adjust `--c1-deep`/`--c2-deep` darker if any pair looks weak. Re-screenshot.

- [ ] **Step 4: Performance sanity.** Long-page scroll is smooth (no jank); after the pointer stops, the Performance monitor CPU drops toward idle (trail decays, loop self-quiesces); switch tabs → `visibilitychange` pauses the loop (no canvas repaint while hidden); emulate touch → parallax/trail/reticle/tilt all off, ambient grid still animates.

- [ ] **Step 5: Commit**
```bash
git add docs/README/README.css docs/README/README.js
git commit -m "fix(readme): focus rings, light-mode AA, reduced-motion + perf hardening"
```

---

## Task 18: Changelog row + final regression sweep + file hygiene

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

- [ ] **Step 1: Append a changelog row.** Match the file's existing row format (open it first to copy the exact table/section shape). Content:
  - **Change:** README.html redesigned into an animated 3D Tron "digital frontier" (cyan+orange neon grid, parallax/3D depth, interaction engine).
  - **README update:** YES — the README trio *is* the change (visual + new motion/sound controls).
  - **Notes:** anchors + content + behaviors 1–11 preserved; behaviors 12–21 added; full reduced-motion fallback; self-contained trio (no new deps/files).

- [ ] **Step 2: Full structural regression** — harness **B** (18 ids), **C** (all hooks ≥1 + `term`/`data-typed`), **A** (no CRLF, 100644).

- [ ] **Step 3: Full behavior regression** — harness **F** for behaviors 1–21 (the full checklist in the spec's verification plan). Confirm each.

- [ ] **Step 4: Render regression** — harness **D** dark + mobile, plus light + reduced via Task 17 commands. Read all four PNGs; compare dark vs `/mnt/c/Temp/readme-BEFORE.png` for the before/after.

- [ ] **Step 5: `file://` smoke test** — open `file:///home/arrush.chaturvedi/.local/share/chezmoi/README.html` (or the Windows `\\wsl$` path) directly with no server; confirm it renders + animates (relative `docs/README/*` links resolve) and the console has no new errors.

- [ ] **Step 6: Lint** — harness **E** (`make lint MODE=prod` → all invariant checks pass). The pre-commit hook also runs it.

- [ ] **Step 7: Commit**
```bash
git add CLAUDE_CHANGELOG.md
git commit -m "docs(readme): changelog row for Tron interactive redesign"
```

- [ ] **Step 8: Offer the branch for review/PR** — summarize before/after to the user; ask whether to open a PR (repo uses a PR workflow). Do NOT merge without the user's go-ahead.

---

## Self-Review (completed by plan author)

**Spec coverage:** Every spec section maps to a task — tokens/dark+light (T1), atmosphere/grid (T2), chrome/console/controls (T3), hero scene (T4), all components incl. tables/tree/tabs/troubleshooting (T5a/5b), readability scrim (T5c), preserved behaviors 1–11 (T6), engine foundation (T7), behaviors 13/14/15/16/17/18/12/19/20 (T8–T16), behavior 21 = the prefs+scheduler+gates spread across T7 + each subsystem's `readme:fxchange` handler, a11y/perf/light/reduced-motion (T17), changelog + regression + `file://` + hygiene (T18). The 4 surfaced decisions are honored: light kept (T1/T17), cursor augments (T9), SFX synth/opt-in (T16), boot once+skippable (T14).

**Placeholder scan:** No TBD/TODO. Re-skin tasks give real CSS patterns + exact selectors; JS tasks give complete, runnable subsystem code. The only "match the existing form" notes (tab `:checked` selector in T5b, changelog row shape in T18) point at concrete files to mirror, not vague work.

**Type/identifier consistency:** Shared names are consistent across tasks — `Scheduler.add/remove/kick`, `fxEnabled()`/`pointerFx()`, `Prefs.motion/sound`, `readme:fxchange` event, `fxDrawers`/`fxLoop`/`FX`, `.tilt`/`.glare`, `.fx-off`/`.fx-on`/`.booting`/`.booted`/`.hide-cursor`/`.derez`, CSS vars `--cam-y`/`--glow-on`/`--scroll-progress`. T8↔T12 composition fix (parallax writes CSS vars, not `style.transform`, so scroll-cam can compose) is called out explicitly in T12 Step 2.

**Known integration seams to watch during execution:** (a) T8 must be refactored to CSS-var transforms when T12 lands (noted in T12). (b) hero `.term` gets `.tilt` in T4 then it's removed in T11 Step 3 so parallax owns its tilt (noted). (c) `fxLoop` is shared by T9+T10 via `fxDrawers`; both add/remove it idempotently.
