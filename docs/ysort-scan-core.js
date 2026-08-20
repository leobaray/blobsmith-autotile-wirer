'use strict';
// The rules behind docs/why-y-sort-draws-the-wrong-order.md, with no filesystem
// in them, so that the CLI (docs/find_y_sort_causes.js) and the web page load
// the identical bytes.
//
// Every rule carries the id of the claim it comes from. Those claims are
// measured against a real engine by docs/verify_y_sort.gd — which renders the
// scene and reads the contested pixel back, because draw order is not a
// property you can read.

// A .tscn/.tres is an INI-ish file of [header] blocks. Properties left at their
// default are NOT written to disk, which is the single most important fact for
// a scanner like this: absence means default, not "unknown".
function parseBlocks(text) {
  const blocks = [];
  let cur = null;
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    const head = line.match(/^\[([a-z_]+)([^\]]*)\]$/);
    if (head) {
      cur = { kind: head[1], attrs: parseAttrs(head[2]), props: new Map(), raw: [] };
      blocks.push(cur);
      continue;
    }
    if (!cur || !line || line.startsWith(';')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    cur.props.set(line.slice(0, eq).trim(), line.slice(eq + 1).trim());
    cur.raw.push(line);
  }
  return blocks;
}

function parseAttrs(s) {
  const out = {};
  const re = /([a-z_]+)="((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(s))) out[m[1]] = m[2];
  return out;
}

function isTrue(v) { return String(v).trim() === 'true'; }

// "Vector2i(0, -8)" -> {x:0, y:-8}
function vec2i(v) {
  const m = String(v).match(/Vector2i?\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)/);
  return m ? { x: Number(m[1]), y: Number(m[2]) } : null;
}

// Inside a TileSetAtlasSource block, per-tile properties are written as
// "<ax>:<ay>/<alt>/<property> = <value>". Group them per tile.
function tilesOf(block) {
  const tiles = new Map();
  for (const [key, value] of block.props) {
    const m = key.match(/^(-?\d+):(-?\d+)\/(\d+)\/(.+)$/);
    if (!m) continue;
    const id = `${m[1]}:${m[2]}/${m[3]}`;
    if (!tiles.has(id)) tiles.set(id, { id, props: new Map() });
    tiles.get(id).props.set(m[4], value);
  }
  return [...tiles.values()];
}


// Does this file describe any tile whose art or sort key has been moved off the
// cell? That is the evidence that somebody WANTS sorting here. A flat floor
// layer with none of it is not misconfigured — it is a flat floor, and a
// scanner that flags every one of those is noise. Measured on
// godotengine/godot-demo-projects: without this gate the rules below fire on 13
// ordinary ground layers that are perfectly correct.
function hasOffsetTiles(text) {
  for (const b of parseBlocks(text)) {
    if (!/TileSetAtlasSource/.test(b.attrs.type || '')) continue;
    for (const t of tilesOf(b)) {
      const to = vec2i(t.props.get('texture_origin'));
      if (to && to.y !== 0) return true;
      if (t.props.has('y_sort_origin') && Number(t.props.get('y_sort_origin')) !== 0) return true;
    }
  }
  return false;
}

function finding(id, claim, where, detail, fix) {
  return { id, claim, where, detail, fix };
}

// ---------------------------------------------------------------------------
// TileSet side: the art was moved, the sort key was not.
// ---------------------------------------------------------------------------
function scanTileSet(text, rel) {
  const out = [];
  for (const b of parseBlocks(text)) {
    if (!/TileSetAtlasSource/.test(b.attrs.type || '')) continue;
    for (const t of tilesOf(b)) {
      const texOrigin = vec2i(t.props.get('texture_origin'));
      const yso = t.props.has('y_sort_origin') ? Number(t.props.get('y_sort_origin')) : 0;
      const z = t.props.has('z_index') ? Number(t.props.get('z_index')) : 0;

      // Y14: texture_origin drags the pixels and leaves the sort key where it
      // was. A tile whose art hangs above its cell but whose y_sort_origin is
      // still 0 will sort as if it were flat, at every distance.
      if (texOrigin && texOrigin.y !== 0 && yso === 0) {
        out.push(finding('Y14', 'texture_origin moves the art, never the sort key',
          `${rel} tile ${t.id}`,
          `texture_origin.y = ${texOrigin.y} (the tile is drawn ${Math.abs(texOrigin.y)} px `
            + `${texOrigin.y > 0 ? 'UP' : 'DOWN'} of its cell) but y_sort_origin is still 0`,
          'Set this tile\'s Y Sort Origin to its visual contact point. The two fields sit next '
            + 'to each other in the TileSet editor and only the second one is read when sorting.'));
      }

      // Y26/Y27: a per-tile z_index outranks the y-sort result outright, in
      // both directions, and is invisible unless you open that one tile.
      if (z !== 0) {
        out.push(finding('Y26', 'a per-tile z_index outranks y-sorting entirely',
          `${rel} tile ${t.id}`,
          `z_index = ${z}`,
          'Y-sorting only orders items that share a z_index. Clear this back to 0 unless you '
            + 'meant this tile to ignore sorting.'));
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Scene side: which layers sort, and against what.
// ---------------------------------------------------------------------------
function scanScene(text, rel) {
  const out = [];
  const blocks = parseBlocks(text);
  const nodes = blocks.filter((b) => b.kind === 'node');
  const offsetArt = hasOffsetTiles(text);
  const hasChild = (n) => nodes.some((o) => o.attrs.parent !== undefined
    && (o.attrs.parent === n.attrs.name
      || o.attrs.parent.startsWith(n.attrs.name + '/')
      || (n.attrs.parent && n.attrs.parent !== '.'
        && o.attrs.parent === n.attrs.parent + '/' + n.attrs.name)));

  const layers = nodes.filter((n) => (n.attrs.type || '') === 'TileMapLayer');
  const legacy = nodes.filter((n) => (n.attrs.type || '') === 'TileMap');

  for (const n of layers) {
    const ysort = isTrue(n.props.get('y_sort_enabled'));
    const hasTiles = n.props.has('tile_map_data');

    // Y12/Y13: the checkbox is off, which is the shipped default, so nothing
    // in this layer is sorted at all.
    if (hasTiles && !ysort && (offsetArt || hasChild(n))) {
      out.push(finding('Y12', 'this layer is not y-sorted at all — the property ships OFF',
        `${rel} node "${n.attrs.name}"`,
        'y_sort_enabled is absent from the scene file, which means false — while '
          + (offsetArt ? 'this file sets a tile origin off its cell' : 'this layer has child nodes'),
        'Tick Y Sort Enabled on the TileMapLayer. On its own this changes nothing for '
          + 'tile-against-tile order (claim Y13) — it is the precondition, not the fix.'));
    }

    // Y28: a knob people are told to tune that provably does not move the result.
    const quad = n.props.get('rendering_quadrant_size');
    if (ysort && quad !== undefined && Number(quad) !== 16) {
      out.push(finding('Y28', 'rendering_quadrant_size was tuned, and it changes nothing here',
        `${rel} node "${n.attrs.name}"`,
        `rendering_quadrant_size = ${quad} on a y-sorted layer`,
        'Measured at 1, 16 and 128 with an otherwise identical scene: same winner every time. '
          + 'Put it back to 16 and look at y_sort_origin instead.'));
    }
  }

  // Y23/Y24: two sibling layers that both sort internally still stack by tree
  // order unless their COMMON PARENT is y-sorted too. Both flags, or neither
  // matters.
  const byParent = new Map();
  for (const n of layers) {
    const p = n.attrs.parent === undefined ? '<root>' : n.attrs.parent;
    if (!byParent.has(p)) byParent.set(p, []);
    byParent.get(p).push(n);
  }
  for (const [parent, group] of byParent) {
    if (group.length < 2) continue;
    const sorted = group.filter((n) => isTrue(n.props.get('y_sort_enabled')));
    if (sorted.length < 2) continue;
    const parentNode = nodes.find((n) => nodeIsAt(n, parent));
    const parentSorts = parentNode ? isTrue(parentNode.props.get('y_sort_enabled')) : false;
    if (!parentSorts && (offsetArt || sorted.some(hasChild))) {
      out.push(finding('Y23', 'sibling layers sort inside themselves but not against each other',
        `${rel} parent "${parent}"`,
        `${sorted.length} y-sorted TileMapLayer siblings (${sorted.map((n) => n.attrs.name).join(', ')}) `
          + `under a parent that is not y-sorted`,
        'Tick Y Sort Enabled on the PARENT node as well. Measured: with both flags on, tiles from '
          + 'separate layers interleave per tile (claim Y25); with only one of them on, the later '
          + 'layer covers the earlier one wholesale.'));
    }
  }

  // Y8: the superseded node still loads, and its per-layer y-sort flags are a
  // different property from the one every current answer talks about.
  for (const n of legacy) {
    out.push(finding('Y8', 'this scene still uses the superseded TileMap node',
      `${rel} node "${n.attrs.name}"`,
      'type="TileMap" (its y-sort lives in layer_N/y_sort_enabled, not in y_sort_enabled)',
      'Advice written for TileMapLayer does not name the same properties. Convert the node, or '
        + 'read the per-layer keys when following it.'));
  }
  return out;
}

// A node's own path, as its children would spell it in `parent="..."`.
function nodeIsAt(node, parentPath) {
  const own = node.attrs.parent === undefined
    ? '.'
    : (node.attrs.parent === '.' ? node.attrs.name : `${node.attrs.parent}/${node.attrs.name}`);
  return own === parentPath;
}

function scanResource(text, rel) {
  const t = String(text);
  const out = [];
  if (/\[node /.test(t)) out.push(...scanScene(t, rel));
  if (/TileSetAtlasSource/.test(t)) out.push(...scanTileSet(t, rel));
  return out;
}

const NO_CAUSE_NOTE = 'No cause found in the files read. That is not the same as "your sorting is '
  + 'correct": this scanner reads what the scene FILE says, and a y_sort_origin set correctly for '
  + 'a 16 px tile is wrong for a 32 px one. Claim Y17 gives the key it is compared against.';

const API = { parseBlocks, parseAttrs, vec2i, tilesOf, scanScene, scanTileSet, scanResource, NO_CAUSE_NOTE };

// Node (CLI + tests) and the browser (the page) load the same bytes.
if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.YSortScan = API;
