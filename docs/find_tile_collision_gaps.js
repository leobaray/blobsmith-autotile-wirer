#!/usr/bin/env node
'use strict';
//
// Which of your tiles will the player walk straight through?
//
//   node docs/find_tile_collision_gaps.js path/to/tileset.tres [more.tscn ...]
//   node docs/find_tile_collision_gaps.js --json project/            (recurses)
//
// Exit code 1 if anything was found, 0 if every painted tile carries a shape.
// No dependencies, no Godot, no project import: it reads the text resource the
// editor already wrote.
//
// It exists because the failure is silent. A tile with no collision polygon is
// not an error, not a warning and not visibly different in the tile picker --
// the body just passes through it at runtime. `Visible Collision Shapes` draws
// the shapes that ARE there; nothing draws the ones that are missing, and on a
// 47-tile blob set that is 47 chances to miss one. Every rule is asserted
// against a real Godot 4.7 build in docs/verify_tile_collision.gd (26 claims).
//
// What it CANNOT see, stated so the green result is not read as more than it is:
// a polygon whose count was set but whose points were never drawn is saved to
// disk byte-identically to a tile with no polygon at all (measured: both are
// just `X:Y/0 = 0`). Both are reported the same way, which is also how the
// engine treats them -- as nothing.
//
// The rules live in docs/collision-scan-core.js, with no filesystem in them, so
// this command and the browser page at
// https://blobsmith.lbwma.com/godot-tilemap-collision-not-working/ load the
// identical bytes and cannot name different tiles for the same file.

const fs = require('fs');
const path = require('path');
const SCAN = require('./collision-scan-core.js');

const args = process.argv.slice(2);
const JSON_OUT = args.includes('--json');
const targets = args.filter((a) => !a.startsWith('--'));

if (!targets.length) {
  console.error('usage: node find_tile_collision_gaps.js [--json] <file.tres|file.tscn|dir> ...');
  process.exit(2);
}

function walk(p, out) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const e of fs.readdirSync(p)) {
      if (e === '.godot' || e === '.git' || e === 'node_modules') continue;
      walk(path.join(p, e), out);
    }
  } else if (/\.(tres|tscn)$/i.test(p)) {
    out.push(p);
  }
  return out;
}

const files = [];
for (const t of targets) walk(t, files);

const all = [];
let tiles = 0;
let scanned = 0;
for (const f of files) {
  let r;
  try {
    r = SCAN.scanText(fs.readFileSync(f, 'utf8'), f);
  } catch (e) {
    continue;
  }
  if (!r.sawTileSet && !r.tilesSeen) continue;
  scanned++;
  tiles += r.tilesSeen;
  all.push(...r.findings);
}

if (JSON_OUT) {
  console.log(JSON.stringify({ files: scanned, tiles, findings: all }, null, 1));
} else {
  for (const f of all) {
    // The atlas has to be printed: tile coordinates restart at 0:0 inside every
    // TileSetAtlasSource, so one file reports `0:0/0` once per atlas and each
    // one is a different tile. Without this the report reads as a repetition,
    // or as a contradiction of the atlas above it that has a shape on 0:0/0.
    const where = [f.source ? `[${f.source}]` : '', f.tile || ''].filter(Boolean).join(' ');
    console.log(`${f.file}${where ? '  ' + where : ''}\n    ${f.id}: ${f.detail}`);
  }
  console.log(`\n${scanned} file(s) with a TileSet, ${tiles} painted tile(s), ${all.length} finding(s)`);
  if (!all.length) {
    console.log('Every tile carries a collision polygon. That is not "collision works" —');
    console.log('the layer bits, TileMapLayer.collision_enabled and the body mask still');
    console.log('have to line up (verify_tile_collision.gd C13..C17).');
  }
}
process.exit(all.length ? 1 : 0);
