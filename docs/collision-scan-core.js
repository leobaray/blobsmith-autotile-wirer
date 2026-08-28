'use strict';
// The rules behind docs/why-tiles-do-not-collide.md, with no filesystem in
// them, so that the CLI (docs/find_tile_collision_gaps.js) and the web page
// (/godot-tilemap-collision-not-working/) load the identical bytes.
//
// Extracted from the CLI on 27/08 without changing a rule: the scanner had
// shipped in the public zip since 19/08 and was the only one of the nine with
// no browser page, because its parser lived inside the command-line file.
//
// Every rule carries the id of the claim it comes from. Those claims are
// measured against a real engine by docs/verify_tile_collision.gd, which builds
// a TileMapLayer and a CharacterBody2D per case and calls move_and_collide --
// because "does the body stop" is not a property you can read off the file.

// The one measured sentence behind each rule, so a finding can cite what was
// put to the engine instead of asserting itself. Text kept short on purpose:
// the page prints it next to the finding.
const CLAIMS = {
  'no-physics-layer':
    'C1: a TileSet starts with ZERO physics layers — there is nowhere for a shape to live',
  'layer-bits-zero':
    'C15: physics layer collision_layer = 0 — the body falls through, silently',
  'no-collision-shape':
    'C11: physics layer present, tile has NO polygon — the body falls through. No error, no warning',
  'alternative-without-shape':
    'C6: an alternative made with create_alternative_tile() inherits NO collision shape from its base tile',
};

// What to do about it. Separate from the claim so the page can show the
// measurement and the fix as two different kinds of sentence.
const FIXES = {
  'no-physics-layer':
    'TileSet → Physics Layers → Add Element. A layer added in code defaults to collision_layer = 1 and collision_mask = 1 (C3, C4).',
  'layer-bits-zero':
    'Set at least one bit in the physics layer\'s collision_layer. Do NOT reach for the collision_mask column beside it: with that at 0 the body still stops (C17).',
  'no-collision-shape':
    'Select the tile in the TileSet editor, Physics → add a polygon and draw it. A polygon whose count is 1 with no points drawn is saved byte-identically to no polygon at all (C12).',
  'alternative-without-shape':
    'Draw a polygon on the alternative itself. Godot\'s own platformer demo rewrites the polygon on all eight flip/transpose alternatives, coordinates mirrored by hand.',
};

// A text resource is a list of [section] blocks; every key below a header
// belongs to it. TileSets live either in [resource] (a .tres whose type is
// TileSet) or in a [sub_resource type="TileSet"] (a TileSet embedded in a
// scene); the atlases are always [sub_resource type="TileSetAtlasSource"].
function sections(text) {
  const out = [];
  let cur = null;
  for (const raw of String(text).split(/\r?\n/)) {
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

// Reads one .tres/.tscn. `file` is only carried through into the findings, so
// the browser can pass "pasted file" and the CLI a real path.
function scanText(text, file) {
  const secs = sections(text);
  const findings = [];
  let tilesSeen = 0;

  const add = (f) => {
    findings.push(Object.assign({ claim: CLAIMS[f.id], fix: FIXES[f.id] }, f));
  };

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
      add({
        id: 'no-physics-layer',
        file,
        detail: 'the TileSet declares no physics layer at all — no tile in it can carry a collision shape',
      });
    } else {
      anyPhysicsLayer = true;
      for (const m of layers) {
        if (Number(m[2]) === 0) {
          add({
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
      add({
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

// Said out loud wherever a clean result is shown. C13..C17 are node state and
// body bits; they are not in the tileset file, so this scanner cannot see them
// and a green run is not "collision works".
const CLEAN_NOTE = 'Every painted tile in this file carries a collision polygon. That is not the '
  + 'same as "collision works": TileMapLayer.collision_enabled (C13), TileMapLayer.enabled (C14) '
  + 'and the body\'s own collision_mask against the layer bits (C15, C16) live on the node and on '
  + 'the body, not in this file — each of them drops the body through a perfectly shaped tile, and '
  + 'the engine says nothing for any of them.';

const API = { sections, scanText, CLAIMS, FIXES, CLEAN_NOTE };

// Node (CLI + tests) and the browser (the page) load the same bytes.
if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.CollisionScan = API;
