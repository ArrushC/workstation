#!/usr/bin/env node
// check-readme.mjs — behavioural smoke test for README.html + docs/README/README.js
// under jsdom (no browser). Guards the regressions the 2026-09 console redesign
// shipped with:
//   1. tool-card headings in search results must not carry the injected chip count
//   2. an in-page anchor click must not reset an active filter (but a link INTO a
//      filtered-out card must still reveal it)
//   3. Back/forward must navigate once, not once per history listener
// Run:  npm install --no-save --no-package-lock jsdom@30  &&  node scripts/check-readme.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const root = process.env.README_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptTag = '<script src="docs/README/README.js"></script>';
const html = fs.readFileSync(path.join(root, "README.html"), "utf8");
if (!html.includes(scriptTag)) throw new Error(`README.html no longer loads ${scriptTag}`);
const js = fs.readFileSync(path.join(root, "docs/README/README.js"), "utf8");

const dom = new JSDOM(html.replace(scriptTag, ""), { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/README.html" });
const { window } = dom;
const { document } = window;
const runtimeErrors = [];
window.addEventListener("error", (e) => runtimeErrors.push(String(e.error || e.message)));
window.matchMedia = () => ({ matches: false, media: "", addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
let scrolls = 0;
window.Element.prototype.scrollIntoView = function () { scrolls++; };
window.eval(js);

const failures = [];
const check = (cond, msg) => { if (!cond) failures.push(msg); };
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cleanText = (el) => { const c = el.cloneNode(true); $$(".card-count, .heading-anchor", c).forEach((n) => n.remove()); return c.textContent.replace(/\s+/g, " ").trim(); };
const click = () => new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 });
const input = () => new window.Event("input", { bubbles: true });

// 1. search: result titles are the heading text WITHOUT the chip count
const cards = $$("#toolbelt-grid .tool-card");
check(cards.length > 0, "no tool cards found under #toolbelt-grid");
const search = $("#global-search");
async function runSearch(q) { search.value = q; search.dispatchEvent(input()); await sleep(200); return $$("#search-results .search-result"); }
for (const card of cards.slice(0, 3)) {
    const h4 = $("h4", card);
    const count = $(".card-count", h4)?.textContent ?? "";
    check(count !== "", `no .card-count injected into "${cleanText(h4)}"`);
    const clean = cleanText(h4);
    const glued = clean + count;
    const hits = await runSearch(glued.toLowerCase());
    check(hits.length === 0, `search "${glued}" matched ${hits.length} passage(s): the chip count leaked into indexed heading text`);
    const titles = (await runSearch(clean.toLowerCase())).map((r) => $("strong", r).textContent);
    check(titles.includes(clean), `search "${clean}" produced no result titled "${clean}" (titles: ${[...new Set(titles)].join(" | ")})`);
    check(!titles.includes(glued), `search "${clean}" shows a result titled "${glued}"`);
}
await runSearch("");

// 2. filters survive an in-page anchor click; a link INTO a hidden card still reveals it
const filter = $("#tool-filter");
const first = cards[0];
const term = cleanText($("h4", first)).toLowerCase();
filter.value = term; filter.dispatchEvent(input());
const hiddenBefore = cards.filter((c) => c.hidden).length;
check(hiddenBefore > 0 && !first.hidden, `filter fixture "${term}" hid ${hiddenBefore} cards (own card hidden: ${first.hidden})`);
const anchor = $("h4 a.heading-anchor", first);
check(anchor, "no .heading-anchor injected into the tool-card h4");
anchor?.dispatchEvent(click());
check(filter.value === term, `heading-anchor click reset the tool filter (value is now "${filter.value}")`);
check(cards.filter((c) => c.hidden).length === hiddenBefore, "heading-anchor click un-hid filtered-out cards");
filter.value = term; filter.dispatchEvent(input());
const hiddenCard = cards.find((c) => c.hidden);
const link = document.createElement("a"); link.href = `#${$("h4", hiddenCard).id}`; document.body.append(link);
link.dispatchEvent(click());
check(!hiddenCard.hidden, "a link into a filtered-out card did not reveal it");
link.remove();
filter.value = ""; filter.dispatchEvent(input());

// 3. Back fires popstate AND hashchange in browsers; the page must navigate once
const target = $("#daily") || $$("main section[id]")[1];
window.history.replaceState(null, "", `#${target.id}`);
scrolls = 0;
window.dispatchEvent(new window.PopStateEvent("popstate", { state: null }));
window.dispatchEvent(new window.HashChangeEvent("hashchange", { oldURL: "http://localhost/README.html", newURL: window.location.href }));
check(scrolls === 1, `Back navigation scrolled ${scrolls} time(s), expected exactly 1`);

check(runtimeErrors.length === 0, `runtime errors: ${runtimeErrors.join("; ")}`);
if (failures.length) {
    console.error(`README checks FAILED (${failures.length}):\n - ${failures.join("\n - ")}`);
    process.exit(1);
}
console.log(`README checks passed (${cards.length} tool cards, ${$$("#toolbelt-grid .chip").length} chips, ${$$("[data-ts]").length} troubleshooting entries)`);
