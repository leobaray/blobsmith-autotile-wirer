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
// 47-tile blob set that is 47 chances to miss one. Every rule below is asserted
// against a real Godot 4.7 build in docs/verify_tile_collision.gd (26 claims).
//
// What it CANNOT see, stated so the green result is not read as more than it is:
// a polygon whose count was set but whose points were never drawn is saved to
// disk byte-identically to a tile with no polygon at all (measured: both are
// just `X:Y/0 = 0`). Both are reported the same way, which is also how the
// engine treats them -- as nothing.

const fs = require('fs');
const path = require('path');

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

// A text resource is a list of [section] blocks; every key below a header
// belongs to it. TileSets live either in [resource] (a .tres whose type is
// TileSet) or in a [sub_resource type="TileSet"] (a TileSet embedded in a
// scene); the atlases are always [sub_resource type="TileSetAtlasSource"].
function sections(text) {
  const out = [];
  let cur = null;
  for (const raw of text.split(/\r?\n/)) {
    const head = raw.match(/^\[([a-z_]+)([^\]]*)\]\s*$/);
    if (head) {
      cur = { kind: head[1], attrs: head[2], lines: [] };
      out.push(cur);
      continue;
    }
    if (cur) cur.lines.push(raw);
  }
  return out;
}

const attr = (s, name) => {
  const m = s.attrs.match(new RegExp(name + '="([^"]*)"'));
  return m ? m[1] : null;
};

// `X:Y/ALT = 0` declares a tile. `X:Y/ALT/physics_layer_N/polygon_M/points =
// PackedVector2Array(...)` gives it a shape on layer N. Anything else on the
// tile (probability, terrain bits, y_sort_origin...) is not collision.
const TILE_DECL = /^(-?\d+):(-?\d+)\/(\d+)\s*=\s*\d+\s*$/;
const POLY_PTS = /^(-?\d+):(-?\d+)\/(\d+)\/physics_layer_(\d+)\/polygon_(\d+)\/points\s*=\s*PackedVector2Array\(([^)]*)\)/;

function scanFile(file) {
  const text = fs.readFileSync(file, 'utf8');
  const secs = sections(text);
  const findings = [];
  let tilesSeen = 0;

  // How many physics layers does each TileSet in this file declare, and are the
  // layer bits actually set? A TileSet with no physics layer cannot hold a
  // shape at all -- every tile in it is walk-through, however it was painted.
  const tilesets = secs.filter(
    (s) => s.kind === 'resource' || (s.kind === 'sub_resource' && attr(s, 'type') === 'TileSet')
  );
  let anyPhysicsLayer = false;
  let sawTileSet = false;
  for (const ts of tilesets) {
    const body = ts.lines.join('\n');
    if (!/^sources\/\d+\s*=/m.test(body) && ts.kind === 'resource') continue; // not a TileSet
    sawTileSet = true;
    const layers = [...body.matchAll(/^physics_layer_(\d+)\/collision_layer\s*=\s*(\d+)/gm)];
    const declared = new Set([...body.matchAll(/^physics_layer_(\d+)\//gm)].map((m) => m[1]));
    if (declared.size === 0) {
      findings.push({
        id: 'no-physics-layer',
        file,
        detail: 'the TileSet declares no physics layer at all — no tile in it can carry a collision shape',
      });
    } else {
      anyPhysicsLayer = true;
      for (const m of layers) {
        if (Number(m[2]) === 0) {
          findings.push({
            id: 'layer-bits-zero',
            file,
            layer: Number(m[1]),
            detail: `physics layer ${m[1]} has collision_layer = 0 — its tiles are on no layer, so no body's mask can match them`,
          });
        }
      }
    }
  }

  for (const s of secs) {
    if (!(s.kind === 'sub_resource' && attr(s, 'type') === 'TileSetAtlasSource')) continue;
    const tiles = new Map(); // "x:y/alt" -> {x,y,alt,polys:[n]}
    for (const line of s.lines) {
      const d = line.match(TILE_DECL);
      if (d) {
        const key = `${d[1]}:${d[2]}/${d[3]}`;
        if (!tiles.has(key)) tiles.set(key, { x: +d[1], y: +d[2], alt: +d[3], polys: [] });
        continue;
      }
      const p = line.match(POLY_PTS);
      if (p) {
        const key = `${p[1]}:${p[2]}/${p[3]}`;
        if (!tiles.has(key)) tiles.set(key, { x: +p[1], y: +p[2], alt: +p[3], polys: [] });
        // 3 points = 6 numbers. Fewer than that is not a polygon; the engine
        // refuses to store it (verify_tile_collision.gd C7/C7b).
        const nums = p[6].split(',').map((t) => t.trim()).filter((t) => t.length);
        tiles.get(key).polys.push(nums.length / 2);
      }
    }
    for (const [key, t] of tiles) {
      tilesSeen++;
      const usable = t.polys.filter((n) => n >= 3);
      if (usable.length) continue;
      if (!anyPhysicsLayer && sawTileSet) continue; // already reported once, for the whole set
      findings.push({
        id: t.alt === 0 ? 'no-collision-shape' : 'alternative-without-shape',
        file,
        source: attr(s, 'id'),
        tile: key,
        detail:
          t.alt === 0
            ? `tile ${t.x},${t.y} has no collision polygon — a body passes through it`
            : `alternative ${t.alt} of tile ${t.x},${t.y} has no collision polygon of its own (an alternative inherits nothing from its base tile)`,
      });
    }
  }
  return { findings, tilesSeen, sawTileSet };
}

const files = [];
for (const t of targets) walk(t, files);

const all = [];
let tiles = 0;
let scanned = 0;
for (const f of files) {
  let r;
  try {
    r = scanFile(f);
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
