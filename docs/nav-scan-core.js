'use strict';
// The rules behind docs/why-tiles-are-not-walkable.md, with no filesystem in
// them, so that the command line (docs/find_tile_navigation_gaps.js) and the
// node tests load the identical bytes and cannot name different tiles for the
// same file.
//
// Every rule carries the id of the claim it comes from. Those claims are
// measured against real engines by docs/verify_tile_navigation.gd, which paints
// a six-cell corridor, points a private navigation map at it and asks for a
// path -- because "can the agent get there" is not a property you can read off
// the file.
//
// Two of the rules below (one-frame-await, force-update) are about TIMING, and
// the honest version of both is that there is no number to give you. Measured:
// the frame a corridor first answers on is 1 on an idle 4.3, 2 on an idle 4.4
// and 4 on an idle 4.7 -- and the same 4.7 binary under CPU contention answered
// on 2, 11, 12, 13, 17 and 20 across runs, crossing the other builds' numbers
// in both directions. So these rules never hand out a frame count to copy. They
// point at the pattern that needs none (N30).

const CLAIMS = {
  'no-navigation-layer':
    'N4/N5: a TileSet starts with ZERO navigation layers, and setting a tile polygon without one errors and stores nothing',
  'nav-layer-bits-zero':
    'N18/N19: the region takes the navigation layer bitmask, and a NavigationAgent2D ships asking for bit 1',
  'nav-layer-bits-mismatch':
    'N18/N19/N20: bit 1 is what the default agent asks for; the same query with the right bits walks the whole corridor',
  'tile-without-navigation-polygon':
    'N28/N29: a painted cell whose tile carries no navigation polygon produces NO region — six cells, five regions',
  'corner-anchored-polygon':
    'N13/N14/N15: the region sits at the CELL CENTRE, so a (0,0)-(16,16) outline lands half a tile down-right',
  'navigation-disabled':
    'N21: navigation_enabled = false empties the map while every cell stays painted',
  'godot3-node':
    'N1/N2: there is no Navigation2D and no NavigationPolygonInstance in Godot 4',
  'godot3-api':
    'N1/N2: Navigation2D.get_simple_path() is the Godot 3 call; Godot 4 asks NavigationServer2D or a NavigationAgent2D',
  'query-in-ready':
    'N8/N9: the regions do not exist on the first physics frame on any build measured',
  'one-frame-await':
    'N10: the frame the map first answers on is not a constant — not of the engine and not of a build; only frame 0 is reliably too early',
  'force-update':
    'N12/N12b: map_force_update() publishes the regions immediately, and that is not the same as the map answering a path query',
  'empty-path-only':
    'N23/N24: a blocked corridor does not return an EMPTY path, it returns a SHORTER one',
};

const FIXES = {
  'no-navigation-layer':
    'TileSet → Navigation Layers → Add Element. Until one exists the Navigation tab is not in the tile inspector at all, which is why it looks like the feature is missing.',
  'nav-layer-bits-zero':
    'Set at least one bit on the navigation layer. With 0 no agent can ever match it.',
  'nav-layer-bits-mismatch':
    'Either set bit 1 on the navigation layer, or set the same bits on every NavigationAgent2D.navigation_layers that should walk here. Agents ship at 1.',
  'tile-without-navigation-polygon':
    'Select the tile in the TileSet editor → Navigation → draw the polygon. A painted cell without one is a hole, and the path across it comes back truncated rather than empty.',
  'corner-anchored-polygon':
    'Redraw the outline around (0,0) — for a 16x16 tile that is (-8,-8) to (8,8). The editor does this for you; a polygon written by hand or by a script usually does not.',
  'navigation-disabled':
    'TileMapLayer → Navigation → Enabled. Nothing about the painted cells changes when this is off, which is why it is invisible in the editor.',
  'godot3-node':
    'Delete it. In Godot 4 the layer navigates itself (navigation_enabled ships ON) and standalone meshes are NavigationRegion2D.',
  'godot3-api':
    'NavigationServer2D.map_get_path(map, from, to, true) or NavigationAgent2D.get_next_path_position().',
  'query-in-ready':
    'Ask for the path after the map has rebuilt, not on the first frame: poll NavigationServer2D.map_get_iteration_id(map) and query once it has moved past the value it had before you touched the map (N30).',
  'one-frame-await':
    'Do not count frames — no count is portable, and the same binary needs a different one on a busy machine. Wait for map_get_iteration_id(map) to move instead. If you are asserting on the path itself, wait for the path to stop changing: the region count and the iteration id can both be current while a query still answers from the previous mesh.',
  'force-update':
    'This is not a substitute for waiting: it publishes the regions without making the map answer, and whether a path comes back after it is not a property of the build. Wait for map_get_iteration_id() to advance instead.',
  'empty-path-only':
    'Compare the LAST point of the path to your target, not the length. A path that stops short is the normal way this fails.',
};

// Findings that are something to change vs something to know. Everything the
// scanner reports is real; only the causes are asking for an edit.
const NOTE_IDS = new Set(['nav-layer-bits-mismatch', 'one-frame-await', 'force-update', 'empty-path-only']);
const isCause = (f) => !NOTE_IDS.has(f.id);
const line = (f) => f.id.toUpperCase().replace(/-/g, '_') + '  ' + f.detail;

// A text resource is a list of [section] blocks; every key below a header
// belongs to it.
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

const TILE_DECL = /^(-?\d+):(-?\d+)\/(\d+)\s*=\s*\d+\s*$/;
const TILE_NAV = /^(-?\d+):(-?\d+)\/(\d+)\/navigation_layer_(\d+)\/polygon\s*=\s*SubResource\("([^"]+)"\)/;

// Reads one .tres/.tscn. `file` is only carried into the findings so the
// browser can say "pasted file" and a caller can pass a real path.
function scanResource(text, file) {
  const secs = sections(text);
  const findings = [];
  const add = (f) => findings.push(Object.assign({ claim: CLAIMS[f.id], fix: FIXES[f.id] }, f));

  // Godot 3 nodes, wherever they appear.
  for (const s of secs) {
    if (s.kind !== 'node') continue;
    const type = attr(s, 'type');
    if (type === 'Navigation2D' || type === 'NavigationPolygonInstance') {
      add({ id: 'godot3-node', file, detail: `the scene has a ${type} node, which does not exist in Godot 4 — the project it came from was a Godot 3 project` });
    }
    if (type === 'TileMapLayer' || type === 'TileMap') {
      if (s.lines.some((l) => /^navigation_enabled\s*=\s*false\s*$/.test(l))) {
        add({ id: 'navigation-disabled', file, node: attr(s, 'name'), detail: `TileMapLayer "${attr(s, 'name')}" has navigation_enabled = false — its cells stay painted and its regions never reach the map` });
      }
    }
  }

  // Every NavigationPolygon in the file, so a tile's polygon can be looked up.
  const polys = new Map();
  for (const s of secs) {
    if (!(s.kind === 'sub_resource' && attr(s, 'type') === 'NavigationPolygon')) continue;
    const m = s.lines.join('\n').match(/^vertices\s*=\s*PackedVector2Array\(([^)]*)\)/m);
    if (!m) continue;
    const nums = m[1].split(',').map((t) => parseFloat(t.trim())).filter((n) => !Number.isNaN(n));
    const xs = nums.filter((_, i) => i % 2 === 0);
    const ys = nums.filter((_, i) => i % 2 === 1);
    if (!xs.length) continue;
    polys.set(attr(s, 'id'), {
      minX: Math.min(...xs), minY: Math.min(...ys),
      maxX: Math.max(...xs), maxY: Math.max(...ys),
    });
  }

  // The TileSets: either a .tres whose [resource] is one, or a [sub_resource
  // type="TileSet"] embedded in a scene.
  const tilesets = secs.filter(
    (s) => s.kind === 'resource' || (s.kind === 'sub_resource' && attr(s, 'type') === 'TileSet')
  );
  let anyNavLayer = false;
  let sawTileSet = false;
  let tileSize = 16;
  for (const ts of tilesets) {
    const body = ts.lines.join('\n');
    if (ts.kind === 'resource' && !/^sources\/\d+\s*=/m.test(body)) continue; // not a TileSet
    sawTileSet = true;
    const size = body.match(/^tile_size\s*=\s*Vector2i\(\s*(\d+)\s*,\s*(\d+)\s*\)/m);
    if (size) tileSize = Number(size[1]);   // 16 is the default and is not written out
    const declared = [...body.matchAll(/^navigation_layer_(\d+)\/layers\s*=\s*(\d+)/gm)];
    const anyKey = /^navigation_layer_\d+\//m.test(body);
    if (!anyKey) {
      add({ id: 'no-navigation-layer', file, detail: 'the TileSet declares no navigation layer — no tile in it can carry a navigation polygon, and the Navigation tab does not appear in the tile inspector' });
      continue;
    }
    anyNavLayer = true;
    for (const m of declared) {
      const bits = Number(m[2]);
      if (bits === 0) {
        add({ id: 'nav-layer-bits-zero', file, layer: Number(m[1]), detail: `navigation layer ${m[1]} has layers = 0 — its regions are on no layer, so no agent's navigation_layers can match them` });
      } else if ((bits & 1) === 0) {
        add({ id: 'nav-layer-bits-mismatch', file, layer: Number(m[1]), bits, detail: `navigation layer ${m[1]} has layers = ${bits}, which does not include bit 1 — a NavigationAgent2D ships at 1 and will find no path here until you change one of the two` });
      }
    }
  }

  // The tiles themselves.
  for (const s of secs) {
    if (!(s.kind === 'sub_resource' && attr(s, 'type') === 'TileSetAtlasSource')) continue;
    const tiles = new Map();
    for (const l of s.lines) {
      const d = l.match(TILE_DECL);
      if (d) {
        const key = `${d[1]}:${d[2]}/${d[3]}`;
        if (!tiles.has(key)) tiles.set(key, { x: +d[1], y: +d[2], alt: +d[3], polys: [] });
        continue;
      }
      const n = l.match(TILE_NAV);
      if (n) {
        const key = `${n[1]}:${n[2]}/${n[3]}`;
        if (!tiles.has(key)) tiles.set(key, { x: +n[1], y: +n[2], alt: +n[3], polys: [] });
        tiles.get(key).polys.push(n[5]);
      }
    }
    for (const [key, t] of tiles) {
      if (!t.polys.length) {
        if (!anyNavLayer && sawTileSet) continue; // already reported once, for the whole set
        add({ id: 'tile-without-navigation-polygon', file, source: attr(s, 'id'), tile: key,
          detail: `tile ${t.x},${t.y} has no navigation polygon — every cell painted with it is a hole, and a path across it comes back short instead of empty` });
        continue;
      }
      for (const pid of t.polys) {
        const p = polys.get(pid);
        if (!p) continue;
        // The centred outline the editor draws has negative coordinates. One
        // that starts at the corner does not, and lands half a tile away.
        if (p.minX >= 0 && p.minY >= 0 && p.maxX > tileSize / 2) {
          add({ id: 'corner-anchored-polygon', file, source: attr(s, 'id'), tile: key,
            detail: `tile ${t.x},${t.y} has a navigation polygon spanning (${p.minX},${p.minY})-(${p.maxX},${p.maxY}) with no negative coordinate — for a ${tileSize}px tile the walkable surface lands half a tile down-right of the cell you painted` });
        }
      }
    }
  }
  return { findings, sawTileSet };
}

// The other half of the question lives in the script that asks for the path.
function scanScript(text, file) {
  const findings = [];
  const add = (f) => findings.push(Object.assign({ claim: CLAIMS[f.id], fix: FIXES[f.id] }, f));
  const src = String(text);
  const QUERY = /(map_get_path|get_next_path_position|is_target_reachable|get_current_navigation_path|is_navigation_finished)\s*\(/;

  if (/\bNavigation2D\b|\bNavigationPolygonInstance\b/.test(src)) {
    add({ id: 'godot3-node', file, detail: 'the script names Navigation2D or NavigationPolygonInstance — neither class exists in Godot 4' });
  }
  if (/get_simple_path\s*\(/.test(src)) {
    add({ id: 'godot3-api', file, detail: 'get_simple_path() is the Godot 3 call and is gone' });
  }

  // _ready() bodies: everything indented under the declaration.
  const lines = src.split(/\r?\n/);
  let inReady = false;
  let readyAwaits = 0;
  let readyQuery = -1;
  lines.forEach((l, i) => {
    if (/^func\s+_ready\s*\(/.test(l)) { inReady = true; return; }
    if (inReady && /^func\s+/.test(l)) { inReady = false; return; }
    if (!inReady) return;
    if (/\bawait\b/.test(l) && /(physics_frame|process_frame)/.test(l)) readyAwaits++;
    if (readyQuery < 0 && QUERY.test(l)) readyQuery = i + 1;
  });
  if (readyQuery > 0 && readyAwaits === 0) {
    add({ id: 'query-in-ready', file, line: readyQuery,
      detail: `_ready() asks for a path (line ${readyQuery}) without waiting for the navigation map — on every 4.x build measured the map has no regions at all on the first physics frame` });
  } else if (readyQuery > 0 && readyAwaits === 1) {
    add({ id: 'one-frame-await', file, line: readyQuery,
      detail: `_ready() waits for exactly one frame before asking for a path (line ${readyQuery}) — on an idle machine that was enough on 4.3 and not on 4.4 or 4.7, but the frame the map answers on is not a constant of a build either (N10: 1 to 20 frames on one 4.7 binary), so no fixed number of awaits is safe` });
  }

  if (/map_force_update\s*\(/.test(src)) {
    add({ id: 'force-update', file, detail: 'the script calls NavigationServer2D.map_force_update() — it publishes the regions immediately on every build measured (N12), and that is not the same as the map answering a path query: measured both ways on the same 4.7 binary (N12b), so it is not a substitute for waiting' });
  }

  if (QUERY.test(src) && /(is_empty\s*\(\s*\)|size\s*\(\s*\)\s*==\s*0|\.size\s*\(\s*\)\s*<\s*2)/.test(src)
      && !/(\[\s*-\s*1\s*\]|\.back\s*\(\s*\)|path\s*\[\s*path\.size\s*\(\s*\)\s*-\s*1\s*\])/.test(src)) {
    add({ id: 'empty-path-only', file,
      detail: 'the script decides the path failed by checking that it is empty, and never compares its last point to the target — a corridor blocked halfway returns a SHORTER path, not an empty one' });
  }
  return { findings };
}

function scan(input) {
  const out = [];
  let sawTileSet = false;
  if (input.resource && String(input.resource).trim()) {
    const r = scanResource(input.resource, input.resourceName || 'pasted resource');
    out.push(...r.findings);
    sawTileSet = r.sawTileSet;
  }
  if (input.script && String(input.script).trim()) {
    out.push(...scanScript(input.script, input.scriptName || 'pasted script').findings);
  }
  return { findings: out, sawTileSet };
}

// Said out loud wherever a clean result is shown. The two numbers that decide
// whether an agent moves are not in any file: they are how long you waited and
// whether you looked at the last point of the path.
const CLEAN_NOTE = 'Nothing in what you pasted is one of the causes this scanner can see. That is not '
  + 'the same as "navigation works": how many physics frames you wait before the first query is not a '
  + 'number anyone can give you (N10 — measured from 1 to 20 frames, and the same binary differs '
  + 'between runs), map_force_update() publishes the regions without making the map answer (N12), and '
  + 'a corridor blocked halfway answers with a SHORTER path rather than an empty one (N23, N24). None '
  + 'of those three is written down in a .tres.';

const API = { sections, scanResource, scanScript, scan, isCause, line, CLAIMS, FIXES, CLEAN_NOTE };

if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof globalThis !== 'undefined') globalThis.NavScan = API;
