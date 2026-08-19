#!/usr/bin/env node
// Predicts what Godot 4 terrain painting will put down for a region, from your
// TileSet alone — no engine, no project, no dependencies.
//
//   node docs/predict_terrain_paint.js your_tileset.tres
//   node docs/predict_terrain_paint.js your_tileset.tres --rect 5x3
//   node docs/predict_terrain_paint.js your_tileset.tres --rect 6x3 --chunks
//   node docs/predict_terrain_paint.js your_tileset.tres --terrain 1 --json
//
// Exits 1 if any cell of the painted region has no exact tile in your set — that
// is the cell the engine fills silently with a wrong-looking one, which is the
// whole reason this exists (docs/why-terrain-paints-the-wrong-tile.md, T17-T21).
// Exits 2 on a usage or parse error, 0 when every cell can be answered.
//
// The logic lives in terrain-choice-core.js so the web page at
// https://blobsmith.lbwma.com/godot-terrain-wrong-tile/ can run the same bytes.
'use strict';

const fs = require('fs');
const path = require('path');
const T = require(path.join(__dirname, 'terrain-choice-core.js'));

// Flags that swallow the next argument, so the positional file is found by
// position and not by "does the previous token look like a flag" — `--rect 3x3
// 3x3.tres` used to make indexOf pick the wrong token.
const TAKES_VALUE = ['--rect', '--terrain'];
const argv = process.argv.slice(2);
const opts = {};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) {
    opts[a] = TAKES_VALUE.indexOf(a) !== -1 ? argv[++i] : true;
  } else {
    positional.push(a);
  }
}
const flag = (name, dflt) => (opts[name] === undefined ? dflt : opts[name]);
const has = (name) => opts[name] !== undefined;

const file = positional[0];
if (!file || has('--help') || has('-h')) {
  console.error('usage: predict_terrain_paint.js <tileset.tres> [--rect WxH] [--chunks] [--terrain N] [--json]');
  process.exit(2);
}
if (!fs.existsSync(file)) {
  console.error('no such file: ' + file);
  process.exit(2);
}

const rect = String(flag('--rect', '3x3')).match(/^(\d+)x(\d+)$/);
if (!rect) { console.error('--rect wants WxH, e.g. --rect 5x3'); process.exit(2); }
const W = Number(rect[1]), H = Number(rect[2]);
if (W < 1 || H < 1 || W > 64 || H > 64) { console.error('--rect out of range (1x1 to 64x64)'); process.exit(2); }

const parsed = T.parseTileSet(fs.readFileSync(file, 'utf8'));
const terrainArg = flag('--terrain', null);
const info = T.terrainMasks(parsed, terrainArg === null ? null : Number(terrainArg));
if (info.mode === undefined) {
  console.error('no terrain_set_*/mode line in ' + file + ' — is this a TileSet .tres with terrains?');
  process.exit(2);
}

// Which neighbourhoods this mode can be asked for at all, and which are missing.
const all = T.universe(info.sidesOnly);
const holes = all.filter((m) => info.masks.indexOf(m) === -1);

const painted = new Set();
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) painted.add(T.key(x, y));
const cells = T.paintRegion(painted, info.masks, info.sidesOnly);
const unanswered = cells.filter((c) => !c.exact);

// --chunks: the same rect painted as a left half then a right half (T9).
let rewritten = [];
if (has('--chunks')) {
  const half = Math.ceil(W / 2);
  const a = new Set(), b = new Set();
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) (x < half ? a : b).add(T.key(x, y));
  rewritten = T.rewrittenBy(a, b, info.sidesOnly);
}

if (has('--json')) {
  console.log(JSON.stringify({
    file, terrain: info.terrain, mode: info.mode, modeName: info.modeName,
    tiles: info.tileCount, distinct: info.masks.length,
    neighbourhoods: all.length, holes, rect: { w: W, h: H },
    cells, unanswered: unanswered.length, rewritten,
  }, null, 2));
  process.exit(unanswered.length ? 1 : 0);
}

console.log(`${path.basename(file)} — terrain ${info.terrain}, ${info.modeName}`);
console.log(`  ${info.tileCount} tiles on this terrain, ${info.masks.length} distinct neighbourhoods, `
  + `${all.length} the engine can ask for`);
if (holes.length) {
  console.log(`  ${holes.length} neighbourhood${holes.length === 1 ? '' : 's'} your set cannot answer: `
    + holes.join(', '));
} else {
  console.log('  no holes: every neighbourhood this mode can ask for has a tile');
}

console.log(`\npainting a ${W}x${H} block on an empty layer:`);
for (const c of cells) {
  console.log('  ' + T.line(c));
}

if (has('--chunks')) {
  const half = Math.ceil(W / 2);
  console.log(`\npainted as two chunks instead (x<${half}, then the rest):`);
  if (!rewritten.length) {
    console.log('  no cell of the first chunk changes — nothing was painted against emptiness');
  } else {
    console.log(`  ${rewritten.length} cell${rewritten.length === 1 ? '' : 's'} of the first chunk get a `
      + 'DIFFERENT tile once the second arrives (T9 — the border was painted against empty):');
    for (const r of rewritten) {
      console.log(`    (${r.x},${r.y}) mask ${r.before} [${T.bitNames(r.before)}] -> ${r.after} [${T.bitNames(r.after)}]`);
    }
  }
}

console.log('');
if (unanswered.length) {
  console.log(`${unanswered.length} of ${cells.length} cells have NO tile in your set. The engine paints them `
    + 'anyway, with no error and no warning — see docs/why-terrain-paints-the-wrong-tile.md (T17-T21).');
  process.exit(1);
}
console.log(`all ${cells.length} cells have an exact tile in your set.`);
process.exit(0);
