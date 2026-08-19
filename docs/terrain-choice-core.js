// The engine behind docs/predict_terrain_paint.js — the pure half, with no
// filesystem and no process in it, so the exact same bytes run in the CLI and in
// a browser.
//
// It exists as its own file because of a promise made on the web page at
// https://blobsmith.lbwma.com/godot-terrain-wrong-tile/ : "this is the same
// predictor the command line runs, byte for byte". A copy of THIS file is served
// under that page, and test/web-terrain.test.js refuses to run if the two differ.
//
// What it models, and what it refuses to model. Every rule below is one of the
// claims measured against a real engine by docs/verify_terrain_choice.gd
// (22 checks, re-run 2026-08-18 against 4.7.stable.official.5b4e0cb0f):
//
//   T4/T5/T9  the neighbourhood a painted cell asks for is decided by which of
//             its 8 neighbours are painted, and empty cells count as "not this
//             terrain" — so it can be computed from the region alone.
//   T17/T18   when your set has no tile for that neighbourhood, the cell is
//             still painted, silently, with a tile that disagrees on the fewest
//             peering bits.
//   T20       swept over all 47 holes: the placed tile is a minimum-mismatch
//             tile every time (47/47).
//   T21       and in 47 of 47 holes SEVERAL tiles tie at that minimum (3 to 8 of
//             them). Which one of the tied tiles the engine hands you is
//             deterministic (T19) but is not the lowest-valued one (2 of 47) and
//             not the first one in the atlas (7 of 47).
//
// So this file predicts HOW WRONG the tile will be (the score, and the tiles
// that tie for it) and deliberately does NOT name which one you get. A tool that
// guessed would be right about a third of the time and unfalsifiable the rest.
'use strict';

// N=1, NE=2, E=4, SE=8, S=16, SW=32, W=64, NW=128 — the layout src/core.js uses.
const BIT = { N: 1, NE: 2, E: 4, SE: 8, S: 16, SW: 32, W: 64, NW: 128 };

// The offset each bit points at, y growing downward, as docs/verify_terrain_choice.gd
// asserts by asking the engine for the same cells.
const OFFSET = [
  [BIT.N, 0, -1], [BIT.NE, 1, -1], [BIT.E, 1, 0], [BIT.SE, 1, 1],
  [BIT.S, 0, 1], [BIT.SW, -1, 1], [BIT.W, -1, 0], [BIT.NW, -1, -1],
];

// The property names Godot writes into a .tres for each peering bit.
const PEERING = {
  top_side: BIT.N, top_right_corner: BIT.NE, right_side: BIT.E,
  bottom_right_corner: BIT.SE, bottom_side: BIT.S, bottom_left_corner: BIT.SW,
  left_side: BIT.W, top_left_corner: BIT.NW,
};

// terrain_set_N/mode in the file. 0 is the only mode that can see corners.
const MODE = { CORNERS_AND_SIDES: 0, CORNERS: 1, SIDES: 2 };
const MODE_NAME = {
  0: 'corners and sides (47 neighbourhoods)',
  1: 'corners only (16 neighbourhoods)',
  2: 'sides only (16 neighbourhoods)',
};

// A corner neighbour only counts when both adjacent side neighbours are there.
// This is what collapses 256 raw neighbourhoods into the 47 the engine asks for.
function canonicalMask(mask) {
  let m = mask & 0b01010101;
  if ((mask & BIT.NE) && (mask & BIT.N) && (mask & BIT.E)) m |= BIT.NE;
  if ((mask & BIT.SE) && (mask & BIT.S) && (mask & BIT.E)) m |= BIT.SE;
  if ((mask & BIT.SW) && (mask & BIT.S) && (mask & BIT.W)) m |= BIT.SW;
  if ((mask & BIT.NW) && (mask & BIT.N) && (mask & BIT.W)) m |= BIT.NW;
  return m;
}

function blob47() {
  const set = new Set();
  for (let m = 0; m < 256; m++) set.add(canonicalMask(m));
  return [...set].sort((a, b) => a - b);
}

// A sides-only set sees 4 bits, so its 16 neighbourhoods are the side subsets.
function blob16() {
  const out = [];
  for (let m = 0; m < 16; m++) {
    let v = 0;
    if (m & 1) v |= BIT.N;
    if (m & 2) v |= BIT.E;
    if (m & 4) v |= BIT.S;
    if (m & 8) v |= BIT.W;
    out.push(v);
  }
  return out.sort((a, b) => a - b);
}

const popcount = (v) => { let c = 0; while (v) { c += v & 1; v >>>= 1; } return c; };

// --- the paint -------------------------------------------------------------
// `painted` is a Set of "x,y" keys. Cells outside it are empty, and T6 measured
// that ignore_empty_terrains does not change that: empty is "not this terrain".
const key = (x, y) => x + ',' + y;

function maskAt(painted, x, y, sidesOnly) {
  let raw = 0;
  for (const [bit, dx, dy] of OFFSET) {
    if (painted.has(key(x + dx, y + dy))) raw |= bit;
  }
  return sidesOnly ? (raw & (BIT.N | BIT.E | BIT.S | BIT.W)) : canonicalMask(raw);
}

// Given the neighbourhood a cell asks for and the neighbourhoods your set can
// actually express, what happens. `available` is an array of masks.
function resolve(want, available) {
  if (!available.length) return { want, exact: false, empty: true, best: null, ties: [] };
  if (available.indexOf(want) !== -1) return { want, exact: true, empty: false, best: 0, ties: [want] };
  let best = 99;
  for (const m of available) best = Math.min(best, popcount(m ^ want));
  const ties = available.filter((m) => popcount(m ^ want) === best).sort((a, b) => a - b);
  return { want, exact: false, empty: false, best, ties };
}

// The whole region at once. Returns one entry per painted cell, in reading order.
function paintRegion(painted, available, sidesOnly) {
  const cells = [...painted].map((k) => k.split(',').map(Number))
    .sort((a, b) => (a[1] - b[1]) || (a[0] - b[0]));
  return cells.map(([x, y]) => {
    const want = maskAt(painted, x, y, sidesOnly);
    const r = resolve(want, available);
    return { x, y, ...r };
  });
}

// T9: painting a cell rewrites the tile of the cell already next to it. Paint A,
// then paint B, and these are the cells of A whose neighbourhood changed —
// the chunk seam, and the reason a border tile is provisional until its
// neighbour arrives.
function rewrittenBy(chunkA, chunkB, sidesOnly) {
  const both = new Set([...chunkA, ...chunkB]);
  const out = [];
  for (const k of chunkA) {
    const [x, y] = k.split(',').map(Number);
    const before = maskAt(chunkA, x, y, sidesOnly);
    const after = maskAt(both, x, y, sidesOnly);
    if (before !== after) out.push({ x, y, before, after });
  }
  return out.sort((a, b) => (a.y - b.y) || (a.x - b.x));
}

// --- reading a .tres -------------------------------------------------------
// Same shape as the parser on /godot-autotile-47-tiles/; test/web-terrain.test.js
// pins it against the two real TileSets in tools/godot-test/tiles.
function parseTileSet(text) {
  const tiles = {}, modes = {}, names = {};
  String(text).split(/\r?\n/).forEach((line) => {
    const t = line.trim();
    const mMode = t.match(/^terrain_set_(\d+)\/mode\s*=\s*(-?\d+)/);
    if (mMode) { modes[mMode[1]] = Number(mMode[2]); return; }
    const mName = t.match(/^terrain_set_(\d+)\/terrain_(\d+)\/name\s*=\s*"(.*)"/);
    if (mName) { names[mName[1] + '/' + mName[2]] = mName[3]; return; }
    const mTile = t.match(/^(-?\d+):(-?\d+)\/(\d+)\/?(\S*)\s*=\s*(.+)$/);
    if (!mTile) return;
    const id = mTile[1] + ':' + mTile[2] + '/' + mTile[3];
    if (!tiles[id]) tiles[id] = { id, terrain: null, terrainSet: null, bits: [] };
    const prop = mTile[4], value = mTile[5].trim();
    if (prop === 'terrain_set') tiles[id].terrainSet = Number(value);
    else if (prop === 'terrain') tiles[id].terrain = Number(value);
    else {
      const mBit = prop.match(/^terrains_peering_bit\/(\w+)$/);
      if (mBit && PEERING[mBit[1]] !== undefined) {
        tiles[id].bits.push({ name: mBit[1], bit: PEERING[mBit[1]], terrain: Number(value) });
      }
    }
  });
  return { tiles: Object.values(tiles), modes, names };
}

// The neighbourhoods one terrain of a parsed set can actually express.
// A peering bit carries a TERRAIN INDEX, not a boolean: a bit pointing at a
// different terrain is not this terrain's bit, which is the `wrong-terrain`
// finding on the 47-tile page and the reason `terrain` is compared, not `!== -1`.
function terrainMasks(parsed, terrain) {
  const tiles = parsed.tiles.filter((t) => t.terrain !== null && t.terrainSet !== null);
  const setId = tiles.length ? String(tiles[0].terrainSet) : '0';
  const mode = parsed.modes[setId];
  const sidesOnly = mode === MODE.SIDES || mode === MODE.CORNERS;
  const want = terrain === undefined || terrain === null ? (tiles.length ? tiles[0].terrain : 0) : terrain;
  const masks = [];
  for (const t of tiles) {
    if (t.terrain !== want) continue;
    let m = 0;
    for (const b of t.bits) if (b.terrain === t.terrain) m |= b.bit;
    masks.push(sidesOnly ? (m & (BIT.N | BIT.E | BIT.S | BIT.W)) : m);
  }
  return {
    terrain: want, mode, sidesOnly, setId,
    modeName: MODE_NAME[mode] || 'unknown mode ' + mode,
    masks: [...new Set(masks)].sort((a, b) => a - b),
    tileCount: masks.length,
  };
}

// The neighbourhoods the engine can ask a set of this mode for.
const universe = (sidesOnly) => (sidesOnly ? blob16() : blob47());

// The name a reader can act on. Lives here so the terminal and the page cannot
// describe the same cell differently.
function bitNames(mask) {
  const order = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return order.filter((n) => mask & BIT[n]).join(' ') || '(alone)';
}

function line(cell) {
  if (cell.exact) return `(${cell.x},${cell.y}) mask ${cell.want} [${bitNames(cell.want)}] — exact tile in your set`;
  if (cell.empty) return `(${cell.x},${cell.y}) mask ${cell.want} — your set has no tile for this terrain at all`;
  return `(${cell.x},${cell.y}) mask ${cell.want} [${bitNames(cell.want)}] — NO tile; the engine substitutes one that is `
    + `${cell.best} peering bit${cell.best === 1 ? '' : 's'} off (${cell.ties.length} tile${cell.ties.length === 1 ? '' : 's'} tie: `
    + `${cell.ties.join(', ')})`;
}

const API = {
  BIT, OFFSET, PEERING, MODE, MODE_NAME,
  canonicalMask, blob47, blob16, popcount, key,
  maskAt, resolve, paintRegion, rewrittenBy,
  parseTileSet, terrainMasks, universe, bitNames, line,
};

if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.TerrainChoice = API;
