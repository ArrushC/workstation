// How each space sprite moves, for each state of its space. A sprite has a character of its
// own: a way of moving and an effect that suits what it is (the coffee steams, the rocket
// burns, the cloud rains, the terminal's cursor blinks). The space's state sets the mood:
//   idle     the character at rest: slow, slight, one wisp of its effect
//   working  the character in full
//   blocked  the same, agitated, under a blinking red light
//   done     the same with a spring in it, among gold glints
// A space with no agent at all stands still. Everything is a native loop (render never runs
// for it), drawn in the avatar's 18 px box; effects may stray a few px outside it.

// [what moves, from, to, ms there and back], around the sprite's place at left 1, top 1.
const MOVES = {
  float: ["top", 1, -1, 2200],
  hop: ["top", 1, -2, 620],
  leap: ["top", 1, -4, 780],
  flap: ["top", 2, -1, 330],
  sway: ["left", 0, 2, 1800],
  waddle: ["left", -1, 3, 1050],
  march: ["left", -2, 4, 1500],
  swim: ["left", -2, 4, 2500],
  crawl: ["left", -2, 4, 4400],
  shake: ["left", 0, 2, 230],
  still: null,
};

// [how it moves, its effect, the effect's color (a theme color's name, "fill" for the
// space's own, or #hex)]
const SPEC = {
  slime: ["hop", "drip", "fill"],
  ghost: ["float", "fade", null],
  cat: ["sway", "twinkle", "ansi3"],
  robot: ["march", "lamp", "ansi1"],
  mushroom: ["sway", "fall", "#ffffff"],
  octopus: ["swim", "rise", "ansi4"],
  skull: ["shake", "fade", null],
  heart: ["hop", "pulse", null],
  potion: ["sway", "rise", "fill"],
  frog: ["leap", "orbit", "muted"],
  rocket: ["float", "burn", "ansi3"],
  terminal: ["still", "cursor", "#ffffff"],
  coffee: ["still", "steam", "muted"],
  bomb: ["shake", "fuse", "ansi3"],
  star: ["float", "twinkle", "#ffffff"],
  invader: ["march", "zap", "ansi2"],
  bat: ["flap", "twinkle", "ansi5"],
  fish: ["swim", "rise", "ansi6"],
  tree: ["sway", "fall", "ansi2"],
  cactus: ["still", "bloom", "ansi5"],
  key: ["shake", "twinkle", "ansi3"],
  crown: ["float", "twinkle", "#ffffff"],
  bolt: ["shake", "flash", null],
  moon: ["float", "twinkle", "ansi3"],
  sun: ["still", "rays", "ansi3"],
  flower: ["sway", "fall", "ansi5"],
  gem: ["float", "twinkle", "#ffffff"],
  house: ["still", "smoke", "muted"],
  duck: ["waddle", "drip", "ansi4"],
  penguin: ["waddle", "fall", "#ffffff"],
  turtle: ["crawl", "rise", "ansi6"],
  flame: ["still", "embers", "ansi3"],
  cloud: ["float", "rain", "ansi4"],
  anchor: ["sway", "rise", "ansi4"],
  planet: ["float", "orbit", "#ffffff"],
  cherry: ["sway", "twinkle", "#ffffff"],
  sword: ["shake", "twinkle", "#ffffff"],
};

// [how much slower, how much wider the move, how many particles of the effect]
const MOOD = { idle: [2.3, 0.5, 1], working: [1, 1, 2], blocked: [0.42, 1, 2], done: [0.72, 1.35, 3] };

export function act(name, status, art, fill, t, beat, { div }) {
  const mood = MOOD[status];
  const [moveName, effect, colorKey] = SPEC[name] ?? ["hop", "twinkle", "#ffffff"];
  const spot = (left, top) => div().absolute().left(left).top(top);
  if (!mood) return [spot(1, 1).child(art)];
  const [slow, wide, count] = mood;
  const ms = (n) => Math.max(110, Math.round(n * slow) + beat);
  const color = colorKey === "fill" ? fill : colorKey?.startsWith("#") ? colorKey : (t[colorKey] ?? "#ffffff");
  const dot = (left, top, px, c = color) => spot(left, top).size(px).rounded(px / 2).bg(c);
  const bit = (left, top, w, h, c = color) => spot(left, top).w(w).h(h).bg(c);
  const rising = (el, from, period) => el.loop("top", { from, to: from - 6, period }).loop("opacity", { from: 0.95, to: 0, period });
  const falling = (el, from, period) => el.loop("top", { from, to: from + 6, period }).loop("opacity", { from: 0.95, to: 0, period });
  const some = (list) => list.slice(0, count);

  // The sprite itself, moving its way; "fade", "pulse" and "flash" play on the sprite.
  let body = art;
  if (effect === "fade") body = div().loop("opacity", { from: 0.45, to: 1, period: ms(2600) }).child(art);
  if (effect === "pulse") body = div().loop("opacity", { from: 0.55, to: 1, period: ms(700) }).child(art);
  if (effect === "flash") body = div().loop("opacity", { from: 0.35, to: 1, period: ms(260) }).child(art);
  const move = MOVES[moveName];
  let mover = spot(1, 1);
  if (move) {
    const [what, from, to, period] = move;
    mover = spot(1, 1).loop(what, { from: 1 + (from - 1) * wide, to: 1 + (to - 1) * wide, period: ms(period) });
  }
  const out = [mover.child(body)];

  // Its effect, around it.
  if (effect === "rise") out.push(...some([rising(dot(3, 0, 2), 2, ms(1500)), rising(dot(12, 0, 2), 4, ms(2100)), rising(dot(8, 0, 1), 1, ms(1200))]));
  if (effect === "steam") out.push(...some([rising(bit(6, 0, 1, 3), 1, ms(1400)), rising(bit(9, 0, 1, 3), 0, ms(1900)), rising(bit(4, 0, 1, 2), 2, ms(1100))]));
  if (effect === "smoke") out.push(...some([rising(dot(11, 0, 2), 1, ms(1700)), rising(dot(13, 0, 3), -1, ms(2300)), rising(dot(10, 0, 2), 0, ms(1300))]));
  if (effect === "embers") {
    out[0] = spot(1, 1).loop("opacity", { from: 0.6, to: 1, period: ms(240) }).child(art);
    out.push(...some([rising(dot(4, 0, 1), 2, ms(900)), rising(dot(11, 0, 1), 1, ms(1300)), rising(dot(8, 0, 1), 0, ms(700))]));
  }
  if (effect === "fall" || effect === "rain" || effect === "drip") {
    const drop = effect === "fall" ? (l) => dot(l, 0, 2) : (l) => bit(l, 0, 1, 3);
    out.push(...some([falling(drop(4), 13, ms(1300)), falling(drop(11), 14, ms(1800)), falling(drop(8), 12, ms(1000))]));
  }
  if (effect === "twinkle" || effect === "rays") {
    const at = effect === "rays" ? [[-2, 6], [16, 6], [7, -3]] : [[-1, 0], [15, 3], [12, -3]];
    out.push(...some(at.map(([l, top], n) => dot(l, top, 2).loop("opacity", { from: 0.05, to: 1, period: ms(700 + n * 430) }))));
  }
  if (effect === "lamp") out.push(dot(8, -2, 2).loop("opacity", { from: 0.1, to: 1, period: ms(520) }));
  if (effect === "bloom") out.push(dot(8, -2, 3).loop("opacity", { from: 0.2, to: 1, period: ms(1900) }));
  if (effect === "fuse") out.push(dot(14, -1, 2).loop("opacity", { from: 0.1, to: 1, period: ms(180) }), dot(15, -3, 1, "#ffffff").loop("opacity", { from: 1, to: 0, period: ms(260) }));
  if (effect === "cursor") out.push(bit(9, 9, 3, 2).loop("opacity", { from: 0, to: 1, period: ms(560) }));
  if (effect === "burn") out.push(bit(7, 15, 4, 3).loop("opacity", { from: 0.3, to: 1, period: ms(170) }), bit(8, 17, 2, 2, t.ansi1).loop("opacity", { from: 1, to: 0.2, period: ms(230) }));
  if (effect === "orbit") out.push(dot(0, 7, 2).loop("left", { from: -3, to: 17, period: ms(2400) }).loop("opacity", { from: 1, to: 0.25, period: ms(2400) }));
  if (effect === "zap") out.push(bit(-3, 6, 3, 1).loop("opacity", { from: 0, to: 1, period: ms(300) }), bit(17, 9, 3, 1).loop("opacity", { from: 1, to: 0, period: ms(300) }));

  // The mood's own mark.
  if (status === "blocked") out.push(dot(14, -3, 3, t.blocked).loop("opacity", { from: 0.1, to: 1, period: 520 + beat }));
  if (status === "done") out.push(dot(-2, -2, 2, t.ansi3).loop("opacity", { from: 0, to: 1, period: 640 + beat }), dot(16, 11, 2, t.ansi3).loop("opacity", { from: 1, to: 0, period: 880 + beat }));
  return out;
}
