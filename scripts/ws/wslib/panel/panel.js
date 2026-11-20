// The panel's page. Everything it shows that came from a job, an issue or a model is inserted as
// text (textContent), never parsed as HTML.
"use strict";

const $ = (id) => document.getElementById(id);
const ID = /^[0-9a-f]{6,16}$/;

// This run's key arrives in the address's fragment (which a browser never sends to a server),
// moves to this page's own storage (kept per port, unlike a cookie), and leaves the address.
let key = "";
try { key = sessionStorage.getItem("ws-key") || ""; } catch (e) { key = ""; }
if (location.hash.startsWith("#t=")) {
  key = location.hash.slice(3);
  try { sessionStorage.setItem("ws-key", key); } catch (e) { /* the key then lives for this page view only */ }
  history.replaceState(null, "", location.pathname);
}
let selected = null;      // {kind, id}
let latest = null;        // the last /api/needs answer
let busy = false;

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
}

async function get(path, asText) {
  const r = await fetch(path, { credentials: "omit", cache: "no-store", headers: { "X-WS-Key": key } });
  if (!r.ok) throw new Error(`${r.status}`);
  return asText ? r.text() : r.json();
}

async function post(path, body) {
  const r = await fetch(path, {
    method: "POST", credentials: "omit",
    headers: { "Content-Type": "application/json", "X-WS-Panel": "1", "X-WS-Key": key },
    body: JSON.stringify(body || {}),
  });
  return r.json().catch(() => ({ ok: false, message: `The panel answered ${r.status}.` }));
}

function tone(row) {
  if (row.kind === "inbox" || ["needs-you", "succeeded"].includes(row.stage)) return "you";
  if (["failed", "interrupted"].includes(row.stage)) return "bad";
  if (row.stage === "delivered") return "others";
  return "engine";
}

function matches(row, q) {
  if (!q) return true;
  const hay = `${row.id} ${row.title} ${row.repo} ${row.stage}`.toLowerCase();
  return q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

function rowItem(row) {
  const li = el("li", tone(row));
  if (selected && selected.id === row.id) li.classList.add("on");
  const b = el("button", "row");
  b.type = "button";
  b.append(el("span", "waits", `Waits for ${row.waits}`), el("span", "title", row.title));
  const meta = el("span", "meta");
  meta.append(el("code", "", row.id), document.createTextNode(`  ${row.stage}  ${row.repo}`));
  if (row.checks && row.checks !== "none") meta.append(document.createTextNode(`  checks ${row.checks}`));
  b.append(meta);
  if (row.note) b.append(el("span", "note", row.note));
  b.addEventListener("click", () => choose(row.kind, row.id));
  li.append(b);
  return li;
}

function fill(listId, emptyId, rows) {
  const q = $("filter").value.trim();
  const shown = rows.filter((r) => matches(r, q));
  $(listId).replaceChildren(...shown.map(rowItem));
  $(emptyId).hidden = shown.length > 0;
}

function render() {
  if (!latest) return;
  $("host").textContent = `on ${latest.host}`;
  fill("needs", "needs-empty", latest.needs);
  fill("working", "working-empty", latest.working);
  $("health").replaceChildren(...latest.health.map((h) => el("li", h.level, h.text)));
  $("health-empty").hidden = latest.health.length > 0;
  $("clock").textContent = `as of ${new Date().toLocaleTimeString()}`;
}

async function refresh() {
  try {
    latest = await get("/api/needs");
    $("lost").hidden = true;
    render();
  } catch (e) {
    $("lost").hidden = false;
  }
}

function section(title, node) {
  const frag = document.createDocumentFragment();
  frag.append(el("h4", "", title), node);
  return frag;
}

function diffBlock(text) {
  const pre = el("pre");
  for (const line of text.split("\n")) {
    const cls = line.startsWith("@@") ? "hunk" : line.startsWith("+") && !line.startsWith("+++") ? "add"
      : line.startsWith("-") && !line.startsWith("---") ? "del" : "";
    pre.append(el("span", cls, line + "\n"));
  }
  return pre;
}

function timeline(d) {
  const ol = el("ol", "timeline");
  const events = [];
  for (const h of d.history || []) {
    const what = h.outcome === "wrote" ? h.reason : `${h.outcome}${h.reason ? ": " + h.reason : ""}`;
    events.push({ ts: h.ts, text: what, said: false });
  }
  for (const m of d.thread || []) {
    const who = m.from === "job" ? "The job" : m.from === "you" ? "You" : m.from === "gh:checks" ? "CI" : m.from.replace(/^gh:/, "") + " on GitHub";
    events.push({ ts: m.ts, text: `${who}: ${m.text}`, said: m.from !== "job" });
  }
  events.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  for (const e of events) {
    const li = el("li", e.said ? "said" : "");
    li.append(el("time", "", String(e.ts || "").replace("T", " ").slice(0, 16)), document.createTextNode(e.text));
    ol.append(li);
  }
  return ol;
}

function actionBar(d) {
  const wrap = document.createDocumentFragment();
  const out = el("div", "result");
  out.hidden = true;
  const run = async (action, text) => {
    if (busy || !ID.test(d.id)) return;
    busy = true;
    const base = d.kind === "inbox" ? "inbox" : "jobs";
    let answer;
    try {
      answer = await post(`/api/${base}/${encodeURIComponent(d.id)}/${action}`, text ? { text } : {});
    } catch (e) {
      answer = { ok: false, message: "The panel didn't answer." };
    } finally {
      busy = false;
    }
    out.hidden = false;
    out.className = "result" + (answer.ok ? "" : " bad");
    out.textContent = answer.message || answer.error || (answer.ok ? "Done." : "It didn't work.");
    await refresh();
    if (answer.ok) setTimeout(() => choose(d.kind, d.id, true), 600);
  };
  const says = (d.actions || []).filter((a) => a === "tell" || a === "interrupt");
  if (says.length) {
    const box = el("div", "say");
    const ta = el("textarea");
    ta.placeholder = d.stage === "needs-you" ? "Your answer" : "A follow-up for this job";
    ta.setAttribute("aria-label", ta.placeholder);
    box.append(ta);
    for (const a of says) {
      const label = a === "interrupt" ? "Stop this turn and send" : d.stage === "needs-you" ? "Send answer" : "Send follow-up";
      const b = el("button", "", label);
      b.type = "button";
      b.addEventListener("click", () => ta.value.trim() && run(a, ta.value.trim()));
      box.append(b);
    }
    wrap.append(box);
  }
  const bar = el("div", "actions");
  const names = { cancel: "Cancel job", retry: "Retry", close: "Close job", accept: "Accept as a job", dismiss: "Dismiss" };
  for (const a of (d.actions || []).filter((x) => names[x])) {
    const b = el("button", a === "accept" || a === "retry" ? "" : "plain", names[a]);
    b.type = "button";
    b.addEventListener("click", () => {
      if ((a === "cancel" || a === "close" || a === "dismiss") && !window.confirm(`${names[a]}: ${d.id}?`)) return;
      run(a);
    });
    bar.append(b);
  }
  if (bar.children.length) wrap.append(bar);
  wrap.append(out);
  return wrap;
}

async function choose(kind, id, keep) {
  if (!ID.test(id)) return;
  selected = { kind, id };
  if (location.hash.slice(1) !== id) history.replaceState(null, "", `#${id}`);
  render();
  const body = $("detail-body");
  let d;
  try {
    d = await get(`/api/${kind === "inbox" ? "inbox" : "jobs"}/${id}`);
  } catch (e) {
    $("detail-empty").hidden = false;
    $("detail-empty").textContent = "That one is gone: it was closed, dismissed or accepted.";
    body.hidden = true;
    selected = null;
    return;
  }
  const frag = document.createDocumentFragment();
  frag.append(el("h3", "", d.title));
  const meta = el("p", "quiet");
  meta.append(el("code", "", d.id), document.createTextNode(`  ${d.repo}  waits for ${d.waits}`));
  frag.append(meta, actionBar(d));
  if (kind === "inbox") {
    if (d.reason) frag.append(section("Why it is here", el("p", "prose", d.reason)));
    frag.append(section(`What ${d.author || "someone"} wrote`, el("p", "prose", d.text)));
  } else {
    const r = d.report || {};
    if (r.question) frag.append(section("It asks", el("p", "prose", r.question)));
    if (r.summary) frag.append(section("Its report", el("p", "prose", r.summary)));
    if (r.tests) frag.append(section("What it checked", el("p", "prose", r.tests)));
    if (r.notes) frag.append(section("Notes", el("p", "prose", r.notes)));
    const pub = Object.entries(d.published || {}).filter(([, v]) => v.url || v.pending);
    if (pub.length) {
      const ul = el("ul");
      for (const [k, v] of pub) {
        const li = el("li");
        li.append(document.createTextNode(`${k}: `));
        if (/^https:\/\/github\.com\//.test(v.url)) {
          const a = el("a", "", v.url);
          a.href = v.url; a.rel = "noreferrer noopener"; a.target = "_blank";
          li.append(a);
        } else li.append(document.createTextNode(v.pending ? "sent, never confirmed" : v.url));
        ul.append(li);
      }
      frag.append(section("Written to GitHub or SVN", ul));
    }
    if ((d.files || []).length) frag.append(section(`Changed files (${d.files.length})`, el("pre", "", d.files.join("\n"))));
  }
  if ((d.history || []).length || (d.thread || []).length) frag.append(section("What happened", timeline(d)));
  if (kind !== "inbox") {
    const diffHolder = el("div"), logHolder = el("div");
    frag.append(section("The patch", diffHolder), section("The end of its log", logHolder));
    get(`/api/jobs/${id}/diff`, true).then((t) => diffHolder.replaceChildren(t.trim() ? diffBlock(t) : el("p", "quiet", "No changes.")));
    get(`/api/jobs/${id}/log`, true).then((t) => logHolder.replaceChildren(el("pre", "", t)));
  }
  $("detail-empty").hidden = true;
  body.hidden = false;
  const top = keep ? $("detail").scrollTop : 0;
  body.replaceChildren(frag);
  $("detail").scrollTop = top;
}

// The address remembers which piece of work is open (#<id>), so a reload or a bookmark returns to it.
function fromAddress() {
  const id = location.hash.slice(1);
  if (!ID.test(id) || !latest) return;
  const row = [...latest.needs, ...latest.working].find((r) => r.id === id);
  choose(row ? row.kind : "job", id);
}

$("filter").addEventListener("input", render);
window.addEventListener("hashchange", () => { if (!selected || selected.id !== location.hash.slice(1)) fromAddress(); });
refresh().then(fromAddress);
setInterval(refresh, 5000);
