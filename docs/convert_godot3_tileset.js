#!/usr/bin/env node
// Converts a Godot 3 (`format=2`) TileSet resource into the Godot 4 TileSet
// that means the same thing — and prints, subtile by subtile, everything the
// conversion could not carry across.
//
//   node docs/convert_godot3_tileset.js old_tileset.tres
//   node docs/convert_godot3_tileset.js old_tileset.tres --write new_tileset.tres
//   node docs/convert_godot3_tileset.js /path/to/project        # every .tres in it
//   node docs/convert_godot3_tileset.js old_tileset.tres --json
//
// Zero dependencies. Writes nothing unless you pass --write. Uploads nothing.
//
// Why this exists when Godot 4 opens the file without an error: it opens it and
// drops the autotile. Measured on 4.3, 4.4 and 4.7 by
// docs/verify_godot3_tileset.sh — every autotile arrives as an atlas source
// with ZERO tiles in it, `get_terrain_sets_count()` is 0, and a collision shape
// shared by several tiles is re-origined once per sharer, so the second tile's
// collision sits half a tile off and the third a whole tile off, with no
// warning. The write-up is docs/why-a-godot-3-tileset-does-not-open-empty.md.
//
// The rules live in ./tres3-convert-core.js, which has no filesystem in it, so
// the identical bytes also run in the browser for people without a terminal:
// https://blobsmith.lbwma.com/godot-3-tileset-to-godot-4/
'use strict';
const fs = require('fs');
const path = require('path');
const T = require('./tres3-convert-core.js');

const LEVELS = ['blocked', 'collision', 'changed', 'dropped'];

function isGodot3TileSet(text) {
  const head = text.slice(0, 200);
  return /^\[gd_resource type="TileSet"/.test(head) && /format=2\]/.test(head);
}

function walk(dir, out = []) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return out; }
  for (const name of names) {
    if (name === '.git' || name === '.godot' || name === 'node_modules') continue;
    const full = path.join(dir, name);
    let st;
    try { st = fs.statSync(full); } catch { continue; }
    if (st.isDirectory()) walk(full, out);
    else if (path.extname(name) === '.tres') out.push(full);
  }
  return out;
}

function report(file, res) {
  console.log(`\n${file}`);
  console.log(`  ${res.tiles.length} Godot 3 tiles -> ${res.terrainSets.length} terrain set(s), `
    + `${res.tiles.reduce((a, t) => a + (t.cols || 1) * (t.rows || 1), 0)} tiles`);
  if (res.notes.length === 0) {
    console.log('  nothing was lost: every tile, bitmask and shape has a Godot 4 equivalent');
    return;
  }
  for (const level of LEVELS) {
    const ns = res.notes.filter((n) => n.level === level);
    for (const n of ns) console.log(`  [${level}] ${n.where}: ${n.what}`);
  }
}

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0 || args[0] === '-h' || args[0] === '--help') {
    console.log('usage: convert_godot3_tileset.js <file.tres|project-dir> [--write [out.tres]] [--json]');
    return 2;
  }
  const target = args[0];
  const json = args.includes('--json');
  const wi = args.indexOf('--write');
  const write = wi !== -1;
  const outArg = write && args[wi + 1] && !args[wi + 1].startsWith('--') ? args[wi + 1] : null;

  let files;
  let st;
  try { st = fs.statSync(target); } catch { console.error(`no such path: ${target}`); return 2; }
  if (st.isDirectory()) {
    files = walk(target).filter((f) => isGodot3TileSet(fs.readFileSync(f, 'utf8')));
    if (files.length === 0) {
      console.log(`no Godot 3 (format=2) TileSet found under ${target}`);
      return 0;
    }
    if (outArg) { console.error('--write takes no filename when the target is a directory'); return 2; }
  } else {
    files = [target];
  }

  const out = [];
  let failed = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    let res;
    try {
      res = T.convertGodot3TileSet(text);
    } catch (e) {
      failed++;
      if (json) out.push({ file, error: e.message });
      else console.error(`\n${file}\n  REFUSED: ${e.message}`);
      continue;
    }
    if (json) out.push({ file, notes: res.notes, tiles: res.tiles.length, terrainSets: res.terrainSets.length });
    else report(file, res);
    if (write) {
      // Never overwrite the Godot 3 file: it is the only copy of the bitmasks.
      const dest = outArg || file.replace(/\.tres$/, '') + '.godot4.tres';
      if (fs.existsSync(dest) && dest !== outArg) {
        console.error(`  not written: ${dest} already exists`);
        failed++;
        continue;
      }
      fs.writeFileSync(dest, res.tres);
      if (!json) console.log(`  written: ${dest}`);
    }
  }
  if (json) console.log(JSON.stringify(out, null, 2));
  else if (!write) console.log('\n(nothing written — pass --write to save the Godot 4 file)');
  return failed > 0 ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv));
module.exports = { isGodot3TileSet, main };
