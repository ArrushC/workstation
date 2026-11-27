// 8x8 pixel sprites for space avatars. Drawn for Herdr, not taken from any game.
// "." clear, "x" the space's color, "o" white, "k" near-black.
// The first 15 are pilmokim's herdr-pixel-spaces (Apache-2.0); the rest are ours: see .vendor.

export const SPRITES = {
  slime: [
    "........",
    "...xx...",
    "..xxxx..",
    ".xxxxxx.",
    ".xokxok.",
    "xxxxxxxx",
    "xxxxxxxx",
    ".xxxxxx.",
  ],
  ghost: [
    "..xxxx..",
    ".xxxxxx.",
    "xxxxxxxx",
    "xokxxokx",
    "xxxxxxxx",
    "xxxxxxxx",
    "xxxxxxxx",
    "xx.xx.xx",
  ],
  cat: [
    ".x....x.",
    ".xx..xx.",
    ".xxxxxx.",
    "xxoxxoxx",
    "xxxxxxxx",
    "xxxkkxxx",
    ".xxxxxx.",
    "..xxxx..",
  ],
  robot: [
    "...xx...",
    ".xxxxxx.",
    ".xoxxox.",
    ".xxxxxx.",
    ".xkkkkx.",
    ".xxxxxx.",
    "..x..x..",
    ".xx..xx.",
  ],
  mushroom: [
    "..xxxx..",
    ".xoxxox.",
    "xxxxxxxx",
    "xoxxxxox",
    "xxxxxxxx",
    ".oooooo.",
    ".okooko.",
    "..oooo..",
  ],
  octopus: [
    "..xxxx..",
    ".xxxxxx.",
    "xxxxxxxx",
    "xokxxokx",
    "xxxxxxxx",
    ".xxxxxx.",
    "x.x..x.x",
    ".x.xx.x.",
  ],
  skull: [
    ".xxxxxx.",
    "xxxxxxxx",
    "xkkxxkkx",
    "xkkxxkkx",
    "xxxkkxxx",
    ".xxxxxx.",
    ".x.xx.x.",
    ".xxxxxx.",
  ],
  heart: [
    "........",
    ".xx..xx.",
    "xoxxxxxx",
    "xxxxxxxx",
    "xxxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
    "...xx...",
  ],
  potion: [
    "...oo...",
    "...xx...",
    "...xx...",
    "..xxxx..",
    ".xxxxxx.",
    ".xoxxxx.",
    ".xxxxxx.",
    "..xxxx..",
  ],
  frog: [
    ".xx..xx.",
    "xokxxokx",
    "xxxxxxxx",
    "xkxxxxkx",
    "xxkkkkxx",
    "xxxxxxxx",
    ".xxxxxx.",
    "xx....xx",
  ],
  rocket: [
    "...xx...",
    "..xxxx..",
    "..xoox..",
    "..xxxx..",
    ".xxxxxx.",
    "xxxxxxxx",
    "x.xxxx.x",
    "...oo...",
  ],
  terminal: [
    "xxxxxxxx",
    "xkkkkkkx",
    "xokkkkkx",
    "xkokkkkx",
    "xokkookx",
    "xkkkkkkx",
    "xxxxxxxx",
    "..xxxx..",
  ],
  coffee: [
    ".o..o...",
    "..o..o..",
    "xxxxxx..",
    "xxxxxxxx",
    "xxxxxx.x",
    "xxxxxxxx",
    "xxxxxx..",
    ".xxxx...",
  ],
  bomb: [
    "......o.",
    ".....x..",
    "..xxxx..",
    ".xxxxxx.",
    "xoxxxxxx",
    "xxxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
  ],
  star: [
    "...xx...",
    "...xx...",
    "xxxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
    ".xxxxxx.",
    ".xx..xx.",
    ".x....x.",
  ],
  // Ours from here on (2026-11-27): the same alphabet, drawn for this layout.
  invader: [
    "..x..x..",
    "...xx...",
    "..xxxx..",
    ".xoxxox.",
    "xxxxxxxx",
    "x.xxxx.x",
    "x.x..x.x",
    "...xx...",
  ],
  bat: [
    "........",
    "x......x",
    "xx.xx.xx",
    "xxxxxxxx",
    "xxoxxoxx",
    ".xxxxxx.",
    "..x..x..",
  ],
  fish: [
    "........",
    "..xxx..x",
    ".xxxxxxx",
    "xoxxxxx.",
    "xxxxxxxx",
    ".xxxxx.x",
    "..xxx...",
  ],
  tree: [
    "...xx...",
    "..xxxx..",
    ".xxxxxx.",
    "xxxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
    "...oo...",
    "...oo...",
  ],
  cactus: [
    "...xx...",
    "x..xx...",
    "x..xx..x",
    "xxxxx..x",
    "...xxxxx",
    "...xx...",
    "...xx...",
    "..xxxx..",
  ],
  key: [
    "..xxx...",
    ".x...x..",
    ".x...x..",
    "..xxx...",
    "...x....",
    "...xx...",
    "...x....",
    "...xx...",
  ],
  crown: [
    "........",
    "x..xx..x",
    "xx.xx.xx",
    "xxxxxxxx",
    "xoxxxxox",
    "xxxxxxxx",
    "........",
  ],
  bolt: [
    "....xx..",
    "...xx...",
    "..xx....",
    ".xxxxxx.",
    "....xx..",
    "...xx...",
    "..xx....",
    ".x......",
  ],
  moon: [
    "..xxx...",
    ".xxx....",
    "xxx.....",
    "xxx.....",
    "xxx....x",
    ".xxx..xx",
    "..xxxxx.",
  ],
  sun: [
    "...x....",
    "x.xxx.x.",
    ".xxxxx..",
    "xxxoxxx.",
    ".xxxxx..",
    "x.xxx.x.",
    "...x....",
  ],
  flower: [
    "..x..x..",
    ".xxxxxx.",
    "..xoox..",
    ".xxxxxx.",
    "..x..x..",
    "...o....",
    "..oo....",
    "...o....",
  ],
  gem: [
    "........",
    ".xxxxxx.",
    "xxoxxxxx",
    "xoxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
    "...xx...",
  ],
  house: [
    "...xx...",
    "..xxxx..",
    ".xxxxxx.",
    "xxxxxxxx",
    ".xoxxox.",
    ".xxkkxx.",
    ".xxkkxx.",
  ],
  duck: [
    "..xxx...",
    ".xkxxx..",
    "ooxxxx..",
    "..xxx..x",
    ".xxxxxxx",
    ".xxxxxx.",
    "..xxxx..",
  ],
  penguin: [
    "..xxxx..",
    ".xxxxxx.",
    ".xkxxkx.",
    "xxooooxx",
    "xxooooxx",
    ".xoooox.",
    "..o..o..",
  ],
  turtle: [
    "........",
    "..xxxx..",
    ".xxkxxx.",
    "xxxxxxoo",
    "xxkxxxok",
    ".xxxxxx.",
    ".x....x.",
  ],
  flame: [
    "...x....",
    "..xx....",
    "..xxx.x.",
    ".xxxxxx.",
    "xxxooxxx",
    "xxooooxx",
    ".xoooox.",
    "..xxxx..",
  ],
  cloud: [
    "........",
    "..xxx...",
    ".xxxxxx.",
    "xxxxxxxx",
    "xxxxxxxx",
    ".xxxxxx.",
    "........",
  ],
  anchor: [
    "...xx...",
    "..x..x..",
    "...xx...",
    "..xxxx..",
    "...xx...",
    "x..xx..x",
    "xx.xx.xx",
    ".xxxxxx.",
  ],
  planet: [
    "..xxxx.o",
    ".xxxxxo.",
    "xxxxoxxx",
    "xxooxxxx",
    "ooxxxxx.",
    "..xxxx..",
    "........",
  ],
  cherry: [
    "....xx..",
    "...x.x..",
    "..x...x.",
    ".xx..xx.",
    "xoxxxoxx",
    "xxxxxxxx",
    ".xx..xx.",
  ],
  sword: [
    "......xx",
    ".....xxx",
    "....xxx.",
    "x..xxx..",
    ".xxxx...",
    "..xx....",
    ".x.xx...",
    "x...x...",
  ],
};

export const NAMES = Object.keys(SPRITES);

// Each run of one color in a row is one rectangle: [char, length].
function runs(row) {
  const out = [];
  for (let i = 0; i < row.length; ) {
    let j = i;
    while (j < row.length && row[j] === row[i]) j++;
    out.push([row[i], j - i]);
    i = j;
  }
  return out;
}

// The sprite as GPUI rectangles, `px` pixels per sprite pixel.
export function sprite(name, fill, { div, v_flex, h_flex }, px = 2) {
  const rows = SPRITES[name] ?? SPRITES.slime;
  const ink = { x: fill, o: "#ffffff", k: "#17181c" };
  return v_flex().flex_none().w(px * 8).h(px * rows.length).children(
    rows.map((row) => h_flex().flex_none().h(px).children(
      runs(row).map(([c, n]) => {
        const cell = div().flex_none().w(px * n).h(px);
        return c === "." ? cell : cell.bg(ink[c]);
      }),
    )),
  );
}

// A sprite for each space: kept once picked, new spaces get the least used one.
export function assign(spaces, kept) {
  const out = { ...kept };
  let changed = false;
  for (const s of spaces) {
    if (out[s.id] && NAMES.includes(out[s.id])) continue;
    const uses = (n) => Object.values(out).filter((v) => v === n).length;
    const least = Math.min(...NAMES.map(uses));
    const free = NAMES.filter((n) => uses(n) === least);
    let h = 0;
    for (const ch of s.name ?? s.id) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    out[s.id] = free[h % free.length];
    changed = true;
  }
  return { out, changed };
}
