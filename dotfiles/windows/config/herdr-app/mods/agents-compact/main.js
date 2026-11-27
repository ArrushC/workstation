// Agents in grouped or priority views; parents take their most urgent sub-agent's place.

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, panes, focused, spaces, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout, settings } from "herdr";

// Text sizes were chosen for Geist. A monospaced panel font (settings.json's `ui_font`, e.g.
// JetBrains Mono) is about a sixth wider, so it is drawn a step smaller to fit the same rows.
const sz = (n) => (/mono|courier|consol/i.test(String(settings()?.ui_font ?? "")) ? Math.round(n * 0.92 * 2) / 2 : n);

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// The sidebar's rail goes by its width, not a flag: dragging its edge narrows it too.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// To the rail (on macOS wide enough for the traffic lights), or back to the width it had.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  // Mods edited before the rail went by width still read the flag.
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 268) : window()?.platform === "macos" ? 76 : 44 });
}

// Drops what an agent puts before its title: a status glyph or spinner and the separator
// after it ("✦  Working", "⠋ - Thinking"), and Codex's blinking "[ ! ] " / "[ . ] " mark.
// Stops at an opening bracket or quote, so a title that starts with one ("[web] login") keeps it,
// and at an emoji ("🔴 login", "❤️ deploy"), except for known status marks.
const clean = (s) => (s ?? "").replace(/^(?:\[ [!.] \] |[✋⏳]\uFE0F?(?=\s)|(?!(?:\p{Emoji}\uFE0F|[#*]\u20E3))[^\p{L}\p{N}\p{Ps}\p{Pi}\p{Emoji_Presentation}])+/u, "").trim();

function leadPanes(all) {
  const leads = new Map();
  for (const p of all) {
    if (!p.terminal) continue;
    const current = leads.get(p.tab);
    // First agent, else first focused terminal, else first terminal in the tab.
    if (!current || (!current.program?.agent && (p.program?.agent || (!current.focused && p.focused)))) leads.set(p.tab, p);
  }
  return leads;
}

function title(tab, l) {
  const prog = l?.program?.name;
  const live = clean(l?.title);
  // clean() would strip a path's leading ~ or /: test the title with only its status glyph gone.
  const path = /^[~/]|^[A-Za-z]:\\/.test((l?.title ?? "").replace(/^[^\p{L}\p{N}~/]+/u, ""));
  const telling = live && live !== (l?.terminal ?? l?.address) && live !== prog && !path && !live.includes("@") && live.toLowerCase() !== l?.program?.key;
  return (tab.name === prog || !tab.named) && telling ? live : tab.name;
}
const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
// A sub-agent without a pane isn't in agents(): its raw word, error counting as
// blocked. It's never done: it reports to its parent, and the parent's done is the news.
// A kept sub-agent (one with a pane) is in agents() too: it keeps its own status, done included.
const kidStatus = (k, listed) => {
  if (listed.has(k.address)) return listed.get(k.address);
  const s = k.status;
  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
};
const SORTS = [
  { id: "priority", label: "Priority", icon: "clock" },
  { id: "grouped", label: "Grouped by space", icon: "layers" },
];
const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];
const SECTION = { 4: "Needs you", 3: "Done", 2: "Working", 1: "Idle" };
const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working" };

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// The agent's icon from the app's program table: a one-color glyph or a picture.
function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

// An agent's icon moves with its state, each agent to its own rhythm (set by its address, so
// two agents never march in step and one agent always moves the same way). Claude Code's is
// its mascot, the pixel creature of its icon, drawn from our own pieces (clawd-*.svg).
// Working: it wanders left and right across its slot (two sideways swings of unrelated
// lengths, so the path doesn't visibly repeat), stepping (two pairs of legs cross-fading under
// a solid body) and bobbing. Blocked: it hops on the spot. Idle: it passes the time, one of
// five ways picked like a celebration: asleep under rising z's, watching a flickering
// television, meditating (hovering over its shadow), nodding along in headphones, or having
// a steaming coffee. Done (finished while you weren't looking): it celebrates, one of four
// ways picked by that finish (the agent's address and when it finished), so the next one
// differs: a party hat and a happy hop, fireworks overhead, confetti twinkling around it, or
// cheering with its arms up. Any other agent's own icon wanders, hops, dims and celebrates
// the same way (it cheers by hopping). All native loops: render never runs for them.
// The icon rests 1 px into an 18 px slot, exactly where spaces-compact draws a space's sprite,
// so the two lists' pictures and names line up. A walking icon strays ROAM px around that.
const SLOT = 18, REST = 1, ROAM = 6;
function rhythm(text) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619) >>> 0;
  // The nth number in 0..1, the same every time for this text.
  return (n) => ((Math.imul(h ^ (n * 2654435761), 2246822519) >>> 0) % 1000) / 1000;
}
// Small parts every act is built from, placed in the icon's slot (and the gap around it).
const spot = (left, top) => div().absolute().left(left).top(top);
const letters = (left, top, color, list, ms, px = 9) => spot(left, top).font_family("JetBrains Mono").text_size(px).font_bold().text_color(color).frames(list, ms);
const thing = (name, left, top, w, h) => image(`mods/agents-compact/${name}.svg`).absolute().left(left).top(top).w(w).h(h);

// What a working agent looks busy with, besides wandering (kind 0): 1 at a laptop, 2 thinking
// (pacing under a row of dots), 3 juggling, 4 having an idea (a bulb glowing overhead),
// 5 searching (a magnifying glass sweeping), 6 running flat out (speed lines behind),
// 7 turning two cogs. `walking` is the icon stepping on the spot.
function labour(kind, pic, walking, size, t, r) {
  const beat = 380 + Math.round(r(16) * 180);
  if (kind === 1) {
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -0.6, period: 240 + Math.round(r(17) * 80) }).child(pic),
      thing("laptop", SLOT, 8, 7, 6),
      spot(SLOT + 2, 9).w(3).h(2).bg(t.ansi2).loop("opacity", { from: 0.3, to: 1, period: 230 + Math.round(r(18) * 90) })];
  }
  if (kind === 2) {
    return [spot(REST, 0).size(size).loop("left", { from: REST - 1.5, to: REST + 1.5, period: 2200 + Math.round(r(19) * 900) }).child(walking),
      letters(SLOT - 7, -9, t.muted, [".", "..", "...", "...", " "], 360)];
  }
  if (kind === 4) {
    return [spot(REST, 1).size(size).loop("top", { from: 1, to: 0, period: 1100 }).child(pic),
      thing("bulb", SLOT - 6, -9, 6, 8).loop("opacity", { from: 0.2, to: 1, period: 800 + Math.round(r(25) * 500) })];
  }
  if (kind === 5) {
    return [spot(REST, 0).size(size).loop("left", { from: REST - 1, to: REST + 1, period: 1900 }).child(walking),
      thing("magnifier", SLOT - 2, 6, 8, 8).loop("left", { from: SLOT - 4, to: SLOT + 1, period: 1200 + Math.round(r(26) * 600) })];
  }
  if (kind === 6) {
    const dash = (top, period) => spot(-6, top).w(5).h(1).bg(t.muted).loop("opacity", { from: 0, to: 0.9, period }).loop("left", { from: -3, to: -7, period });
    return [spot(REST + 1, 0).size(size).loop("top", { from: 0, to: -1, period: 150 + Math.round(r(27) * 50) }).child(walking),
      dash(4, 260), dash(8, 340), dash(12, 430)];
  }
  if (kind === 7) {
    const cog = (left, top, px, color, ms) => svg("mods/agents-compact/gear.svg").absolute().left(left).top(top).size(px).text_color(color).spin(ms);
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -0.6, period: 520 }).child(pic),
      cog(SLOT - 1, 6, 8, t.muted, 2400 + Math.round(r(28) * 1200)), cog(SLOT - 6, -6, 6, t.dim, 1700)];
  }
  const ball = (left, color, period) => spot(left, 0).size(2).rounded(1).bg(color).loop("top", { from: -1, to: -9, period });
  return [spot(REST, 0).size(size).loop("top", { from: 0, to: -1, period: beat }).child(pic),
    ball(2, t.ansi3, beat), ball(8, t.ansi4, Math.round(beat * 1.31)), ball(14, t.ansi5, Math.round(beat * 1.67))];
}

// How a blocked agent asks for you, besides hopping (kind 0): 1 waving under a "!", 2 a "?"
// popping up, 3 shaking with two warning lights, 4 ringing a bell, 5 waiting by an hourglass,
// 6 fretting (pacing, a bead of sweat falling), 7 waving a red flag. `waving` is the mascot
// with its arms going.
function plea(kind, pic, waving, size, t, r) {
  if (kind === 1) {
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -1.5, period: 460 + Math.round(r(20) * 160) }).child(waving ?? pic),
      letters(SLOT - 5, -10, t.blocked, ["!", "!", " "], 300, 11)];
  }
  if (kind === 2) {
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -1, period: 900 + Math.round(r(21) * 400) }).child(pic),
      letters(SLOT - 5, -10, t.blocked, [" ", "?", "?", "?"], 420, 11)];
  }
  if (kind === 4) {
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -1, period: 380 }).child(pic),
      thing("bell", SLOT, 5, 7, 8).loop("left", { from: SLOT - 1.5, to: SLOT + 1.5, period: 150 + Math.round(r(29) * 60) })];
  }
  if (kind === 5) {
    const sand = (top, from, to) => spot(SLOT + 2, top).w(2).h(2).bg(t.ansi3).loop("opacity", { from, to, period: 1500 + Math.round(r(30) * 600) });
    return [spot(REST, 0).size(size).child(pic), thing("hourglass", SLOT, 5, 6, 9), sand(7, 1, 0), sand(11, 0, 1)];
  }
  if (kind === 6) {
    const fall = 640 + Math.round(r(31) * 240);
    return [spot(REST, 0).size(size).loop("left", { from: REST - 2, to: REST + 2, period: 520 }).child(pic),
      spot(SLOT - 3, -3).w(2).h(3).rounded(1).bg(t.ansi4).loop("top", { from: -4, to: 3, period: fall }).loop("opacity", { from: 1, to: 0, period: fall })];
  }
  if (kind === 7) {
    return [spot(REST, 0).size(size).loop("top", { from: 0, to: -2, period: 440 }).child(pic),
      thing("flag", SLOT - 5, -8, 8, 9).loop("left", { from: SLOT - 7, to: SLOT - 4, period: 260 + Math.round(r(32) * 100) })];
  }
  const light = (left, from, to) => spot(left, -4).size(3).rounded(2).bg(t.blocked).loop("opacity", { from, to, period: 520 });
  return [spot(REST, 0).size(size).loop("left", { from: REST - 1, to: REST + 1, period: 170 + Math.round(r(22) * 60) }).child(pic),
    light(-1, 1, 0.1), light(SLOT - 2, 0.1, 1)];
}

const SPARKS = ["\u00b7", "\u2726", "\u2738", "\u273a", "\u2738", "\u00b7", " ", " "];
// The party around a finished agent's icon: `kind` 0 hat, 1 fireworks, 2 confetti, 3 cheer,
// 4 a trophy, 5 a balloon, 6 a crown, 7 dancing (swaying, arms going, a note in the air).
function celebration(kind, pic, cheer, size, t, r) {
  const hop = (lift, period, child) => div().absolute().left(REST).size(size).loop("top", { from: 0, to: -lift, period }).child(child);
  const colors = [t.ansi3, t.ansi5, t.ansi4, t.ansi2, t.ansi1, t.ansi6];
  if (kind === 0) {
    return [hop(2, 480 + Math.round(r(8) * 200), div().size(size).relative().child(pic)
      .child(image("mods/agents-compact/party-hat.svg").absolute().left(size / 2 - 4).top(-3).w(8).h(6)))];
  }
  if (kind === 1) {
    const burst = (left, top, color, ms) => div().absolute().left(left).top(top).w(8).flex().justify_center()
      .font_family("JetBrains Mono").text_size(9).font_bold().text_color(color).frames(SPARKS, ms);
    return [div().absolute().top(1).left(REST).size(size).child(pic),
      burst(-4, -8, colors[0], 140), burst(11, -9, colors[1], 190), burst(4, -11, colors[2], 240)];
  }
  if (kind === 2) {
    const bit = (n, left, top) => div().absolute().left(left).size(2).bg(colors[n % colors.length])
      .loop("top", { from: top, to: top + 3, period: 900 + n * 170 }).loop("opacity", { from: 0.15, to: 1, period: 520 + n * 130 });
    return [hop(1, 600, pic), bit(0, -2, -4), bit(1, 4, -6), bit(2, 10, -5), bit(3, 16, -3), bit(4, 18, 5), bit(5, -3, 6)];
  }
  if (kind === 4) {
    // A trophy beside it, glinting.
    return [hop(1.5, 560, pic), thing("trophy", SLOT, 6, 7, 8),
      letters(SLOT + 1, -6, t.ansi3, ["\u2726", " ", "\u00b7", " "], 330, 7)];
  }
  if (kind === 5) {
    // A balloon bobbing on its string above.
    return [spot(REST, 1).size(size).child(pic),
      thing("balloon", SLOT - 5, -7, 5, 8).loop("top", { from: -7, to: -9, period: 1500 + Math.round(r(24) * 700) })];
  }
  if (kind === 6) {
    // Crowned, with two glints.
    const glint = (left, top, period) => spot(left, top).size(2).rounded(1).bg("#ffffff").loop("opacity", { from: 0, to: 0.9, period });
    return [spot(REST, 1).size(size).child(div().size(size).relative().child(pic).child(thing("crown", size / 2 - 5, -4, 10, 6))),
      glint(1, -5, 700), glint(SLOT - 2, -3, 1100)];
  }
  if (kind === 7) {
    const sway = 480 + Math.round(r(33) * 200);
    const dancer = cheer
      ? div().size(size).relative()
        .child(div().absolute().inset_0().child(cheer("torso")))
        .child(div().absolute().inset_0().loop("opacity", { from: 1, to: 0, period: sway / 2 }).child(cheer("arms-down")))
        .child(div().absolute().inset_0().loop("opacity", { from: 0, to: 1, period: sway / 2 }).child(cheer("arms-up")))
      : pic;
    return [spot(REST, 0).size(size).loop("left", { from: REST - 2, to: REST + 2, period: sway })
        .child(div().absolute().left(0).size(size).loop("top", { from: 0, to: -1, period: sway / 2 }).child(dancer)),
      letters(SLOT - 5, -9, t.ansi5, ["\u266a", " ", " \u266a", " "], 400)];
  }
  // Arms up and down under a solid body (only the arms trade places), with a hop.
  const wave = 520 + Math.round(r(9) * 240);
  return [hop(2, wave, cheer
    ? div().size(size).relative()
      .child(div().absolute().inset_0().child(cheer("torso")))
      .child(div().absolute().inset_0().loop("opacity", { from: 1, to: 0, period: wave }).child(cheer("arms-down")))
      .child(div().absolute().inset_0().loop("opacity", { from: 0, to: 1, period: wave }).child(cheer("arms-up")))
    : pic)];
}

// What an idle agent does meanwhile: `kind` 0 sleeps, 1 watches television, 2 meditates,
// 3 listens to music, 4 has a coffee, 5 reads, 6 stargazes, 7 sunbathes in shades. `pose(name)` draws a mascot piece; without one (another
// agent's icon) the icon itself sits there with the same props around it.
function pastime(kind, pic, pose, size, t, r) {
  const at = (left, top) => div().absolute().left(left).top(top);
  const me = (child) => at(REST, 0).size(size).child(child);
  const body = (name) => (pose ? pose(name) : pic);
  const glyphs = (left, top, color, list, ms, px = 8) => at(left, top).font_family("JetBrains Mono").text_size(px).font_bold().text_color(color).frames(list, ms);
  const prop = (name, left, top, w, h) => image(`mods/agents-compact/${name}.svg`).absolute().left(left).top(top).w(w).h(h);
  if (kind === 1) {
    // Eyes on the set beside it; the screen flickers in two unrelated beats.
    return [me(body("look-right")), prop("tv", SLOT, 6, 7, 7),
      at(SLOT + 1, 9).w(5).h(3).bg(t.ansi4).loop("opacity", { from: 0.35, to: 1, period: 310 + Math.round(r(10) * 120) }),
      at(SLOT + 1, 9).w(5).h(3).bg("#ffffff").loop("opacity", { from: 0, to: 0.45, period: 730 + Math.round(r(11) * 300) })];
  }
  if (kind === 2) {
    const breath = 2600 + Math.round(r(12) * 1400);
    return [at(REST, 0).size(size).loop("top", { from: -1, to: -3, period: breath }).child(body("lotus")),
      at(REST + 3, size - 1).h(1).bg(t.dim).loop("width", { from: 10, to: 6, period: breath }),
      at(-2, 2).size(2).rounded(1).bg(t.ansi5).loop("opacity", { from: 0, to: 0.9, period: breath / 2 }),
      at(SLOT, 5).size(2).rounded(1).bg(t.ansi6).loop("opacity", { from: 0.9, to: 0, period: breath / 2 })];
  }
  if (kind === 3) {
    return [at(REST, 0).size(size).loop("top", { from: 0, to: -1, period: 430 + Math.round(r(13) * 160) })
        .child(div().size(size).relative().child(body("body-legs")).child(prop("headphones", 0, 0, size, size))),
      glyphs(SLOT - 4, -9, t.ansi5, ["\u266a", " ", " \u266a", " "], 470, 9)];
  }
  if (kind === 4) {
    const steam = (left, period) => at(left, 0).w(1).h(3).bg(t.muted).loop("top", { from: 4, to: 1, period }).loop("opacity", { from: 0.8, to: 0, period });
    return [me(body("body-legs")), prop("mug", SLOT, 8, 7, 6), steam(SLOT + 2, 1300), steam(SLOT + 4, 1700)];
  }
  if (kind === 5) {
    // Reading: eyes on the book, a page catching the light now and then.
    return [me(body("look-right")), prop("book", SLOT, 8, 7, 6),
      at(SLOT + 4, 9).w(2).h(3).bg("#ffffff").loop("opacity", { from: 0, to: 0.7, period: 1700 + Math.round(r(23) * 900) })];
  }
  if (kind === 6) {
    // Stargazing: eyes up, three stars twinkling out of step.
    const star = (left, top, period) => at(left, top).size(2).rounded(1).bg(t.ansi3).loop("opacity", { from: 0.1, to: 1, period });
    return [me(body("look-up")), star(1, -6, 900), star(9, -9, 1400), star(SLOT - 1, -5, 1150),
      glyphs(SLOT - 9, -11, t.ansi3, [" ", " ", "\u2726", " "], 800, 7)];
  }
  if (kind === 7) {
    // Sunbathing: shades on, a sun glowing overhead.
    return [me(div().size(size).relative().child(body("body-legs")).child(prop("sunglasses", 0, 0, size, size))),
      at(SLOT - 5, -8).size(6).rounded(3).bg(t.ansi3).loop("opacity", { from: 0.55, to: 1, period: 1900 })];
  }
  // Asleep: breathing slowly, z's rising.
  return [me(div().size(size).loop("opacity", { from: 0.5, to: 0.9, period: 2800 + Math.round(r(6) * 2200) }).child(body("asleep"))),
    glyphs(SLOT - 5, -8, t.muted, [" ", "z", "zz", "zzz", "zzz", " "], 520, 8)];
}

function agentIcon(a, size, t, since = 0, kind = null) {
  const pic = icon(a.program, size, t.foreground);
  if (!pic) return null;
  const r = rhythm(a.address);
  const slot = (child) => div().w(SLOT).h(size).flex_none().relative().child(child);
  const still = (child) => slot(div().absolute().top(0).left(REST).size(size).child(child));
  const claude = /claude/.test(a.program.key ?? "");
  const pose = (name) => image(`mods/agents-compact/clawd-${name}.svg`).w(size).h(size);
  if (a.status === "working") {
    const step = 340 + Math.round(r(1) * 200);
    const body = claude
      ? div().size(size).relative()
        .child(div().absolute().inset_0().child(pose("body")))
        .child(div().absolute().inset_0().loop("opacity", { from: 1, to: 0, period: step * 2 }).child(pose("legs-a")))
        .child(div().absolute().inset_0().loop("opacity", { from: 0, to: 1, period: step * 2 }).child(pose("legs-b")))
      : pic;
    if (kind) {
      const walking = claude ? body : pic;
      return div().w(SLOT).h(size).flex_none().relative().children(labour(kind, pic, walking, size, t, r));
    }
    const far = r(2) < 0.5 ? [REST - ROAM / 2, REST + ROAM / 2] : [REST + ROAM / 2, REST - ROAM / 2]; // which way it sets off
    return slot(div().absolute().top(0).size(size).loop("left", { from: far[0], to: far[1], period: 2600 + Math.round(r(3) * 2400) })
      .child(div().absolute().top(0).size(size).loop("left", { from: -1, to: 1, period: 900 + Math.round(r(4) * 800) })
        .child(div().absolute().left(0).size(size).loop("top", { from: 0, to: -1, period: step }).child(body))));
  }
  if (a.status === "blocked" && kind) {
    const waving = claude ? div().size(size).relative()
      .child(div().absolute().inset_0().child(pose("torso")))
      .child(div().absolute().inset_0().loop("opacity", { from: 1, to: 0, period: 400 }).child(pose("arms-down")))
      .child(div().absolute().inset_0().loop("opacity", { from: 0, to: 1, period: 400 }).child(pose("arms-up"))) : null;
    return div().w(SLOT).h(size).flex_none().relative().children(plea(kind, pic, waving, size, t, r));
  }
  if (a.status === "blocked") {
    return slot(div().absolute().left(REST).size(size).loop("top", { from: 0, to: -3, period: 420 + Math.round(r(5) * 240) }).child(pic));
  }
  if (a.status === "idle") {
    const pick = rhythm(`${a.address}:${since}`);
    // "body-legs" is the mascot as it stands: its own icon.
    const piece = claude ? (name) => (name === "body-legs" ? pic : pose(name)) : null;
    return div().w(SLOT).h(size).flex_none().relative().opacity(0.85)
      .children(pastime(kind ?? Math.floor(pick(14) * 8) % 8, pic, piece, size, t, pick));
  }
  if (a.status === "done") {
    const pick = rhythm(`${a.address}:${since}`);
    return div().w(SLOT).h(size).flex_none().relative()
      .children(celebration(kind ?? Math.floor(pick(7) * 8) % 8, pic, claude ? pose : null, size, t, pick));
  }
  return still(pic);
}

// Status marks. Working: the braille "dots" spinner (cli-spinners), drawn natively frame by
// frame. Blocked: breathes, so the one waiting on you catches the eye. Done: a still check.
// Idle: a crescent moon.
const SPINNER = ["\u280b", "\u2819", "\u2839", "\u2838", "\u283c", "\u2834", "\u2826", "\u2827", "\u2807", "\u280f"];
const spinner = (t) => div().w(12).flex_none().flex().justify_center().font_family("JetBrains Mono").text_size(sz(13)).text_color(t.working).frames(SPINNER, 80);
const BREATHE = { from: 0.35, to: 1, period: 1300 };

export default class Agents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    this.folded = new Set();
    // Each agent's last state and when it changed (ms), kept across restarts.
    try { this.changed = JSON.parse(localStorage.getItem("changed") ?? "{}"); } catch { this.changed = {}; }
    try { this.acts = JSON.parse(localStorage.getItem("acts") ?? "{}"); } catch { this.acts = {}; }
    if (!this.acts || typeof this.acts !== "object" || Array.isArray(this.acts)) this.acts = {};
    if (!this.changed || typeof this.changed !== "object" || Array.isArray(this.changed)) this.changed = {};
    try { this.pendingPins = JSON.parse(localStorage.getItem("pins") ?? "[]"); } catch { this.pendingPins = []; }
    if (!Array.isArray(this.pendingPins)) this.pendingPins = [];
    if (!this.pendingPins.length) localStorage.removeItem("pins");
    this.migratingPins = new Set();
    cx.timer.every(30000, (cx) => cx.notify());
  }

  // Stamps agents whose state changed. Done and idle count as one: looking at a
  // finished agent turns done into idle, and looking isn't the agent doing anything.
  track(list, now) {
    let dirty = false;
    for (const a of list) {
      const s = a.status === "done" ? "idle" : a.status;
      if (this.changed[a.address]?.s === s) continue;
      this.changed[a.address] = { s, at: now };
      dirty = true;
    }
    if (!dirty) return;
    // Gone and old: the list alone is empty right after a start.
    const listed = new Set(list.map((a) => a.address));
    for (const [k, c] of Object.entries(this.changed)) if (!listed.has(k) && now - c.at > 30 * 86400000) delete this.changed[k];
    localStorage.setItem("changed", JSON.stringify(this.changed));
  }

  // Keep offline pins until their terminal returns, and keep each pending until
  // core echoes the label so a failed write doesn't erase the old pin.
  migratePins(all) {
    const listed = new Map(all.filter((t) => t.state === "live").map((t) => [t.address, t]));
    const pending = this.pendingPins.filter((address) => {
      const terminal = listed.get(address);
      if (!terminal) return true;
      if (terminal.labels?.["herdr.pinned"]) return false;
      if (!this.migratingPins.has(address)) {
        this.migratingPins.add(address);
        run("terminal.pin", { terminal: address, pinned: true });
      }
      return true;
    });
    if (pending.length === this.pendingPins.length) return;
    this.pendingPins = pending;
    if (pending.length) localStorage.setItem("pins", JSON.stringify(pending));
    else localStorage.removeItem("pins");
  }

  // Which act each agent plays for its state (eight for each state). Chance alone
  // repeats itself (three of five asleep), so an agent entering the state takes the one
  // fewest others are playing now, chance only breaking ties; it keeps it until its state
  // changes. Kept across restarts.
  cast(list) {
    const COUNT = { working: 8, blocked: 8, idle: 8, done: 8 };
    const live = new Map(list.map((a) => [a.address, a]));
    let dirty = false;
    for (const address of Object.keys(this.acts)) {
      const a = live.get(address);
      if (!a || !(a.status in COUNT) || this.acts[address].key !== `${a.status}:${this.since(a)}`) { delete this.acts[address]; dirty = true; }
    }
    for (const a of list) {
      if (!(a.status in COUNT) || this.acts[a.address]) continue;
      const uses = (k) => Object.values(this.acts).filter((act) => act.status === a.status && act.kind === k).length;
      const kinds = Array.from({ length: COUNT[a.status] }, (_, k) => k);
      const least = Math.min(...kinds.map(uses));
      const free = kinds.filter((k) => uses(k) === least);
      const pick = rhythm(`${a.address}:${this.since(a)}`);
      this.acts[a.address] = { key: `${a.status}:${this.since(a)}`, status: a.status, kind: free[Math.floor(pick(15) * free.length) % free.length] };
      dirty = true;
    }
    if (dirty) localStorage.setItem("acts", JSON.stringify(this.acts));
  }

  since(a) {
    return this.changed[a.address]?.at ?? 0;
  }

  rank(a) {
    return RANK[a.status] ?? 0;
  }

  sortMenu(t) {
    const on = sortOf().id;
    return v_flex()
      .w_full()
      .p(5)
      .bg(t.popover)
      .text_size(sz(12.8))
      .child(div().px(8).pt(4).pb(6).text_size(sz(11)).text_color(t.dim).child("Sort agents"))
      .children(SORTS.map((s) => h_flex()
        .id(`sort-${s.id}`)
        .h(31)
        .px(8)
        .gap(9)
        .rounded(7)
        .items_center()
        .text_color(t.foreground)
        .hover((el) => el.bg(t.hover))
        .on_click(() => {
          setShared("agents.sort", s.id);
          closeOverlay(props().overlay);
        })
        .child(svg(`mods/workspace-chrome/${s.icon}.svg`).size(14).flex_none().text_color(t.muted))
        .child(div().flex_1().child(s.label))
        .when(s.id === on, (el) => el.child(svg("mods/workspace-chrome/check.svg").size(14).flex_none().text_color(t.foreground)))));
  }

  peek(addr) {
    run("terminal.peek", { terminal: addr });
  }

  // Live sub-agents of `addr`, depth first, each with the tree lines in front of it.
  tree(all, addr, lead = []) {
    const kids = all.filter((k) => k.parent === addr && k.state === "live");
    return kids.flatMap((k, i) => {
      const last = i === kids.length - 1;
      return [
        { t: k, lines: [...lead, last ? "└" : "├"] },
        ...this.tree(all, k.address, [...lead, last ? "" : "│"]),
      ];
    });
  }

  subRow(t, s, shown, compact) {
    const k = s.t;
    const st = kidStatus(k, this.listed);
    const pic = icon(k.program, 14, t.foreground);
    const on = k.address === shown;
    return h_flex()
      .id(`sub-${k.address}`)
      .pl(39)
      .pr(8)
      .rounded(8)
      .h(26)
      .flex_none()
      .gap(0)
      .items_center()
      .text_size(sz(12.5))
      .when(on, (el) => el.bg(t.raised))
      .hover((s) => s.bg(t.hover))
      .on_click(() => (this.listed.has(k.address) ? run("pane.focus", { terminal: k.address }) : this.peek(k.address)))
      .children(s.lines.map(l => div().self_start().mt(-4).w(9).h(17).mr(4).flex_none()
        .when(Boolean(l), el => el.border_l(1.5).border_color(t.input))
        .when(l === "└" || l === "├", el => el.border_b(1.5).rounded_bl(6))))
      .when(Boolean(pic), el => el.child(div().mr(8).child(pic)))
      .child(div().flex_1().truncate().text_color(on ? t.foreground : t.muted).child(k.name || k.template || k.program?.name || k.address))
      .child(this.status(t, { status: st }, compact));
  }

  // compact: a ! for blocked where a header already says "Needs you".
  status(t, a, compact = false) {
    const color = t[a.status] ?? t.dim;
    if (a.status === "working") return spinner(t).mx(1);
    if (a.status === "blocked" && compact) return div().size(14).flex_none().rounded(4).bg(t.blocked + "26").text_size(sz(10.5)).font_bold().text_color(t.blocked).flex().items_center().justify_center().loop("opacity", BREATHE).child("!");
    if (a.status === "blocked") return div().flex_none().px(6).h(18).rounded(5).bg(t.blocked + "26").text_size(sz(10.5)).font_semibold().text_color(t.blocked).flex().items_center().loop("opacity", BREATHE).child("Needs you");
    // Idle: a crescent moon (asleep); done: a check.
    if (a.status === "idle") return svg("mods/agents-compact/idle.svg").size(11).mx(1).flex_none().text_color(t.dim);
    if (a.status === "done") return div().w(13).flex_none().flex().justify_center().text_size(sz(11)).font_bold().text_color(color).child("\u2713");
    return div().size(7).mx(3).flex_none().rounded(4).bg(t.dim + "00");
  }

  render(cx) {
    const t = theme();
    if (props()?.sortMenu) return this.sortMenu(t);
    const collapsed = narrow();
    const sort = sortOf();
    let list = agents();
    this.listed = new Map(list.map((a) => [a.address, a.status]));
    const all = terminals();
    this.migratePins(all);
    const shown = focused()?.agent;
    const now = Date.now();
    this.track(list, now);
    this.cast(list);
    // A kept sub-agent (one with a pane) is in agents() too: where a tree shows
    // it, it gets no row of its own, unless it's pinned.
    const nested = new Set(collapsed ? [] : list.flatMap((a) => this.tree(all, a.address).map((s) => s.t.address)));
    list = list.filter((a) => a.pinned || !nested.has(a.address));
    const tabCounts = new Map();
    for (const a of list) tabCounts.set(a.tab, (tabCounts.get(a.tab) ?? 0) + 1);
    const byPriority = sort.id === "priority";
    // A helper's done is its own row's news: it doesn't pull a working parent out of Working.
    const kidRank = (k) => { const s = kidStatus(k, this.listed); return RANK[s === "done" ? "idle" : s] ?? 0; };
    const urgency = new Map(list.map((a) => [a.address, Math.max(this.rank(a), ...this.tree(all, a.address).map((s) => kidRank(s.t)))]));
    const rankOf = (a) => urgency.get(a.address);
    if (byPriority) list = [...list].sort((x, y) => rankOf(y) - rankOf(x) || this.since(y) - this.since(x) || y.seq - x.seq);
    const pinned = list.filter((a) => a.pinned);
    const rest = list.filter((a) => !a.pinned);
    list = [...pinned, ...rest];
    setAgentOrder(list.map((a) => a.address));

    const withKids = (a, i) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, i, subs);
      if (this.folded.has(a.address)) return [r];
      return [r, ...subs.map((s) => this.subRow(t, s, shown, byPriority))];
    };

    // The fold chevron; folded, the count too, colored by the most urgent one.
    const fold = (a, subs) => {
      const sts = subs.map((s) => kidStatus(s.t, this.listed));
      const top = sts.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);
      const open = !this.folded.has(a.address);
      return div()
        .id(`fold-${a.address}`)
        .h(18)
        .px(3)
        .gap(3)
        .flex()
        .items_center()
        .rounded(4)
        .text_size(sz(11))
        .text_color(open ? t.dim : (t[top] ?? t.dim))
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => {
          cx.stop_propagation();
          open ? this.folded.add(a.address) : this.folded.delete(a.address);
          cx.notify();
        })
        .child(svg(`mods/workspace-chrome/chevron-${open ? "down" : "right"}.svg`).size(11).flex_none())
        .when(!open, (el) => el.child(String(subs.length)));
    };

    // A row reads "space \u00b7 detail": the detail is a tab someone named or the
    // agent's own title, never an automatic tab number unless two rows would
    // otherwise read the same.
    // Read the pane snapshot once: every host read copies the whole list into JS.
    const leads = leadPanes(panes());
    const tabs = new Map(spaces().flatMap(s => s.tabs).map(tab => [tab.id, tab]));
    const labels = new Map(list.map(a => {
      const tab = tabs.get(a.tab);
      const many = tabCounts.get(a.tab) > 1;
      return [a.address, tab ? title(many ? { ...tab, named: false } : tab, many ? a : leads.get(a.tab)) : (a.title || a.program?.name || "")];
    }));
    const label = (a) => labels.get(a.address);
    const detail = new Map(list.map(a => [a.address, /^\d+$/.test(label(a)) ? null : label(a)]));
    const seen = {};
    for (const a of list) { const k = `${a.space_name}\u0000${detail.get(a.address) ?? ""}`; seen[k] = (seen[k] ?? 0) + 1; }
    for (const a of list) {
      if (detail.get(a.address) == null && seen[`${a.space_name}\u0000`] > 1) detail.set(a.address, label(a));
    }

    const row = (a, i, subs = []) => {
      const pic = agentIcon(a, 16, t, this.since(a), this.acts[a.address]?.kind ?? null);
      const more = detail.get(a.address);
      // An agent on another machine (`vps/t7`) says which.
      const machine = a.address.includes("/") ? a.address.split("/")[0] : null;
      if (collapsed) {
        return h_flex()
          .id(`ag-${a.address}`)
          .h(26)
          .mx(6)
          .px(2)
          .rounded(6)
          .flex_none()
          .items_center()
          .gap(4)
          .when(a.focused, (el) => el.bg(t.selected))
          .hover((s) => s.bg(t.hover))
          .on_click(() => run("pane.focus", { pane: a.pane }))
          .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_color(a.focused ? t.foreground : t.muted).child(String(i + 1)))
          .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, a, true)));
      }
      const when = this.since(a);
      const idle = a.status === "idle" && !a.focused;
      const isPinned = a.pinned;
      const pin = div()
        .id(`pin-${a.address}`)
        .flex_none()
        .p(2)
        .rounded(4)
        .text_color(t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(isPinned ? "Unpin" : "Pin to the top")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          run("terminal.pin", { terminal: a.address, pinned: !isPinned });
          // The row moves away from under the pointer, and no hover-out comes.
          this.hovered = null;
          cx.notify();
        })
        .child(svg(`mods/workspace-chrome/${isPinned ? "pin-off" : "pin"}.svg`).size(13));
      // Under a space header the space goes without saying; an automatic tab number says nothing.
      // Without a space header above (priority, pinned) the row names its space.
      const full = byPriority || isPinned;
      const name = full ? a.space_name || label(a) : more ?? (/^\d+$/.test(label(a)) ? a.program?.name || label(a) : label(a));
      // One line per agent, the name alone: its machine and detail are the row's tooltip.
      const under = [machine, full ? more : null].filter(Boolean).join(" \u00b7 ");
      return h_flex()
        .id(`ag-${a.address}`)
        .px(8)
        .h(28)
        .when(Boolean(under), (el) => el.tooltip(under))
        .flex_none()
        .rounded(8)
        .items_center()
        .gap(9)
        .when(a.focused, (el) => el.bg(t.selected))
        .cursor_pointer()
        .hover((s) => s.bg(t.hover))
        .on_hover((on, cx) => {
          if (on) this.hovered = a.address;
          else if (this.hovered === a.address) this.hovered = null;
          cx.notify();
        })
        .on_click(() => run("pane.focus", { pane: a.pane }))
        .when(Boolean(pic), el => el.child(div().id(`agent-fold-${a.address}`)
          .when(subs.length > 0, el => el.on_click((_e, cx) => {
            cx.stop_propagation();
            this.folded.has(a.address) ? this.folded.delete(a.address) : this.folded.add(a.address);
            cx.notify();
          })).child(pic)))
        .child(div().flex_1().min_w(0).truncate().text_color(idle ? t.muted : t.foreground).child(name))
        .when(subs.length > 0, el => el.child(fold(a, subs)))
        .when(this.hovered === a.address, el => el.child(pin))
        .when(this.hovered !== a.address && Boolean(when), el => el.child(div().flex_none().text_size(sz(11)).text_color(t.dim).child(duration(now - when))))
        .child(this.status(t, a, byPriority && !isPinned));
    };

    // Groups in list order: spaces (grouped) or priority sections. Agents of a
    // space are next to each other in agents(), so neighbours make a group.
    const groups = pinned.length ? [{ id: "pinned", label: "Pinned", status: null, members: pinned }] : [];
    for (const a of rest) {
      const r = rankOf(a) || RANK.idle;
      const id = byPriority ? `sec-${r}` : `sp-${a.space}`;
      if (groups.at(-1)?.id === id) groups.at(-1).members.push(a);
      else groups.push({ id, label: byPriority ? SECTION[r] : a.space_name || "", status: byPriority ? SECTION_STATUS[r] : null, members: [a] });
    }

    // A group's header; it folds the group. Folded, it says how many and the most urgent state.
    const header = (g) => {
      const open = !this.folded.has(g.id);
      const top = g.members.reduce((m, a) => ((RANK[a.status] ?? 0) > (RANK[m] ?? 0) ? a.status : m), null);
      return h_flex()
        .id(g.id)
        .px(8)
        .pt(8)
        .h(30)
        .flex_none()
        .gap(6)
        .items_center()
        .text_size(sz(11))
        .font_medium()
        .cursor_pointer()
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          open ? this.folded.add(g.id) : this.folded.delete(g.id);
          cx.notify();
        })
        .child(div().truncate().text_color(t[g.status] ?? t.dim).child(g.label))
        .when(byPriority || !open, (el) => el.child(div().text_color(t.dim).child(String(g.members.length))))
        .child(div().flex_1())
        .when(!open, (el) => el
          .when(!byPriority && top && top !== "idle", (el) => el.child(this.status(t, { status: top }, true)))
          .child(svg("mods/workspace-chrome/chevron-right.svg").size(11).flex_none().text_color(t.dim)));
    };
    const rows = collapsed
      ? list.flatMap(withKids)
      : groups.flatMap((g) => [header(g), ...(this.folded.has(g.id) ? [] : g.members.flatMap(withKids))]);

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .border_t(1)
      .border_color(t.border)
      .text_size(sz(13))
      .when(!collapsed, (el) =>
        el.child(
          h_flex()
            .px(16)
            .h(41)
            .pt(14)
            .pb(5)
            .flex_none()
            .items_center()
            .justify_between()
            .child(div().text_size(sz(11.5)).font_medium().text_color(t.dim).child("Agents"))
            .child(
              div()
                .id("ag-sort")
                .text_size(sz(11))
                .text_color(t.dim)
                .hover((s) => s.text_color(t.foreground))
                .on_click(() => openOverlay({ mod: "agents-compact", kind: "popup", width: 200, height: 140, props: { sortMenu: true } }))
                .tooltip(`Sort agents: ${sort.label}`)
                .child(svg(`mods/workspace-chrome/${sort.icon}.svg`).size(14)),
            ),
        ),
      )
      .when(list.length === 0 && !collapsed, (el) =>
        el.child(div().px(12).text_size(sz(12)).text_color(t.dim).child("No agent status yet. Agents show up here when they report their status. Older versions and agents inside tmux may not.")),
      )
      .child(v_flex().id("ag-list").flex_1().min_h(0).px(collapsed ? 0 : 8).overflow_y_scrollbar().mode("always").children(rows))
      .when(collapsed, (el) =>
        el.child(
          h_flex()
            .h(28)
            .items_center()
            .justify_center()
            .child(
              div()
                .id("collapse")
                .text_size(sz(13))
                .text_color(t.dim)
                .hover((s) => s.text_color(t.foreground))
                .on_click(toggleSidebar)
                .child("»"),
            ),
        ),
      );
  }
}
