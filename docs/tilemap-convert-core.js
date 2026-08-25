// The engine behind docs/convert_tilemap_to_tilemaplayer.js — the pure half, with
// no filesystem and no process in it, so the exact same bytes run in the CLI and
// in the browser.
//
// It converts the `TileMap` nodes inside a `.tscn` into the `TileMapLayer` nodes
// Godot 4.3+ wants, WITHOUT opening the scene in the editor. That is the whole
// point: the editor's built-in extraction is one scene at a time, by hand, and
// only on scenes you can open — a project that will not open (missing plugin,
// missing dependency, a machine with no display) has no path at all today.
//
// The two on-disk shapes are not the same bytes, so this is a re-encode, not a
// copy. A TileMap writes its cells as `layer_N/tile_data = PackedInt32Array(...)`,
// three int32 per cell; a TileMapLayer writes `tile_map_data = PackedByteArray(...)`,
// a 2-byte header plus a 12-byte record per cell. The byte format is documented,
// field by field, in docs/tile-map-data-format.md and asserted against a real
// engine by docs/verify_tile_map_data.gd; the int32 format is asserted here by
// docs/verify_tilemap_convert.gd, which converts a scene and then makes Godot
// itself read both versions back cell by cell.
//
// Refusing beats guessing. Anything this file does not understand — an unknown
// `layer_N/` key, a `format` it has not been checked against, a script on the
// node, a layer name that would collide with an existing sibling — comes back as
// a blocker and the scene is left exactly as it was.
'use strict';

// --- the two cell formats -----------------------------------------------------

// Legacy TileMap: three int32 per cell, little-endian words.
//
//   w0 = (coords.y << 16) | (coords.x & 0xffff)     both int16, two's complement
//   w1 = (atlas.x   << 16) | (source_id & 0xffff)
//   w2 = (alternative << 16) | (atlas.y & 0xffff)
//
// An erased cell is the word triple (coords, -1, -1): source id 0xffff is the
// engine's "no source". Godot keeps those tombstone records in the file — see
// the same behaviour on the new side in docs/tile-map-data-format.md.
const EMPTY_SOURCE = 0xffff;

const s16 = (v) => (v & 0x8000 ? v - 0x10000 : v);

function decodeTileData(ints) {
  if (ints.length % 3 !== 0) {
    throw new Error(`tile_data has ${ints.length} ints, which is not a whole number of 3-int cells`);
  }
  const cells = [];
  for (let i = 0; i < ints.length; i += 3) {
    const w0 = ints[i] >>> 0, w1 = ints[i + 1] >>> 0, w2 = ints[i + 2] >>> 0;
    cells.push({
      x: s16(w0 & 0xffff),
      y: s16((w0 >>> 16) & 0xffff),
      source_id: w1 & 0xffff,
      atlas_x: (w1 >>> 16) & 0xffff,
      atlas_y: w2 & 0xffff,
      alternative: (w2 >>> 16) & 0xffff,
    });
  }
  return cells;
}

// New TileMapLayer: uint16 format header (only 0 exists) + 12 bytes per cell.
// Field order and sizes: docs/tile-map-data-format.md.
function encodeTileMapData(cells) {
  const buf = new Uint8Array(2 + cells.length * 12);
  const put16 = (off, v) => { buf[off] = v & 0xff; buf[off + 1] = (v >>> 8) & 0xff; };
  put16(0, 0);
  cells.forEach((c, i) => {
    const o = 2 + i * 12;
    put16(o + 0, c.x & 0xffff);
    put16(o + 2, c.y & 0xffff);
    put16(o + 4, c.source_id);
    put16(o + 6, c.atlas_x);
    put16(o + 8, c.atlas_y);
    put16(o + 10, c.alternative);
  });
  return buf;
}

// A record whose source is 0xffff paints nothing: it is the corpse of a cell that
// was erased. Carrying it across would be copying a no-op, so the converted layer
// drops it — and says how many, because "your file got smaller" should never be a
// surprise. The cells the engine reads back are identical either way; that is what
// verify_tilemap_convert.gd checks.
function stripTombstones(cells) {
  return cells.filter((c) => c.source_id !== EMPTY_SOURCE);
}

// --- .tscn text -----------------------------------------------------------------
// A .tscn is INI-ish: `[section attr="v" ...]` headers followed by `key = value`
// lines, where a value may run over several lines (a pretty-printed Dictionary).
// Sections are kept with their raw text so every block this file does not touch is
// re-emitted byte for byte.
const SECTION_RE = /^\[([a-z_]+)([^\]]*)\]\s*$/;

function splitSections(text) {
  const sections = [];
  let cur = { kind: null, attrText: '', lines: [], line: 1 };
  text.split('\n').forEach((raw, i) => {
    const m = raw.match(SECTION_RE);
    if (m) {
      sections.push(cur);
      cur = { kind: m[1], attrText: m[2], lines: [raw], line: i + 1 };
    } else {
      cur.lines.push(raw);
    }
  });
  sections.push(cur);
  return sections.filter((s) => s.kind !== null || s.lines.join('\n').length > 0);
}

function parseAttrs(attrText) {
  const out = {};
  const re = /([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|\[[^\]]*\]|[^\s\]]+)/g;
  let m;
  while ((m = re.exec(attrText)) !== null) {
    out[m[1]] = m[2].startsWith('"') ? m[2].slice(1, -1) : m[2];
  }
  return out;
}

// A property starts at column 0 with `name = `. Continuation lines of a
// multi-line value never do: Godot indents them, or they start with `"` or `}`.
const PROP_RE = /^([A-Za-z_][A-Za-z0-9_/.:]*)\s*=\s?([\s\S]*)$/;

function parseProps(bodyLines) {
  const props = [];
  for (const raw of bodyLines) {
    const m = raw.match(PROP_RE);
    if (m) props.push({ key: m[1], value: m[2], lines: [raw] });
    else if (props.length) props[props.length - 1].lines.push(raw);
  }
  // The blank line that separates two blocks is not part of the last property's
  // value. Left in, it rode along into the rewritten node and opened a hole in
  // the middle of a block — caught by the first fixture that had a layer whose
  // last key was the last line of its section.
  for (const p of props) {
    while (p.lines.length > 1 && p.lines[p.lines.length - 1].trim() === '') p.lines.pop();
    p.value = p.lines.join('\n').replace(PROP_RE, '$2');
  }
  return props;
}

function parseIntArray(value) {
  const m = value.match(/PackedInt32Array\(([^)]*)\)/);
  if (!m) throw new Error(`expected PackedInt32Array(...), got: ${value.slice(0, 60)}`);
  const body = m[1].trim();
  if (!body) return [];
  return body.split(',').map((s) => {
    const n = Number(s.trim());
    if (!Number.isInteger(n)) throw new Error(`not an integer in tile_data: ${s.trim()}`);
    return n | 0;
  });
}

// --- what maps to what ----------------------------------------------------------
// The eight per-layer keys a TileMap serialises, and where each one lands on a
// TileMapLayer. Measured, not remembered: docs/verify_tilemap_convert.gd prints
// the TileMap property list of the engine it is run against and fails if this
// table does not cover it.
const LAYER_KEY_MAP = {
  name: null,            // becomes the node's name
  enabled: 'enabled',
  modulate: 'modulate',
  y_sort_enabled: 'y_sort_enabled',
  y_sort_origin: 'y_sort_origin',
  z_index: 'z_index',
  navigation_enabled: 'navigation_enabled',
  tile_data: 'tile_map_data',  // re-encoded, not copied
};

// TileMap properties that are not Node2D properties. They belong to the tile data,
// so every extracted layer gets its own copy; the wrapper keeps only what a Node2D
// can keep (its transform, visibility, material, groups...).
const MAP_KEY_MAP = {
  tile_set: 'tile_set',
  rendering_quadrant_size: 'rendering_quadrant_size',
  collision_animatable: 'use_kinematic_bodies',   // renamed in 4.3
  collision_visibility_mode: 'collision_visibility_mode',
  navigation_visibility_mode: 'navigation_visibility_mode',
};

// `format` is the TileMap's own on-disk version counter, not the cell format.
// Only the value this converter has been checked against is accepted; a file
// that says anything else is refused rather than guessed at.
const KNOWN_TILEMAP_FORMAT = 2;

function quoteName(name) {
  return `"${name.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function packedByteArrayLiteral(bytes) {
  return `PackedByteArray(${Array.from(bytes).join(', ')})`;
}

// --- the conversion --------------------------------------------------------------

function convertSceneText(text, opts = {}) {
  const label = opts.label || 'scene';
  const sections = splitSections(text);
  const blockers = [];
  const notes = [];
  const converted = [];

  const nodeSections = sections.filter((s) => s.kind === 'node');
  const parsed = nodeSections.map((s) => ({
    section: s,
    attrs: parseAttrs(s.attrText),
    props: parseProps(s.lines.slice(1)),
  }));

  // Full path of every node in the file, so a layer name can be checked against
  // the names already taken under the same parent.
  const pathOf = (n) => {
    const parent = n.attrs.parent;
    if (parent === undefined) return '.';
    if (parent === '.') return n.attrs.name;
    return `${parent}/${n.attrs.name}`;
  };
  const takenUnder = new Map();
  for (const n of parsed) {
    const parent = n.attrs.parent === undefined ? null : n.attrs.parent;
    if (parent === null) continue;
    if (!takenUnder.has(parent)) takenUnder.set(parent, new Set());
    takenUnder.get(parent).add(n.attrs.name);
  }

  // An inherited or instanced scene overrides a TileMap that lives in ANOTHER
  // file: the node block here has layer_N/ properties but no type. Converting the
  // base scene alone would leave these overrides pointing at a node that no longer
  // exists, so they are reported instead of quietly skipped.
  for (const n of parsed) {
    if (n.attrs.type === 'TileMap') continue;
    if (n.props.some((p) => /^layer_\d+\//.test(p.key))) {
      blockers.push({
        node: pathOf(n),
        line: n.section.line,
        reason: 'layer_N/ overrides on a node with no type — this scene inherits or instances '
          + 'another one. Convert the base scene, then re-check this file by hand.',
      });
    }
  }

  const targets = parsed.filter((n) => n.attrs.type === 'TileMap');
  if (targets.length === 0) {
    return { changed: false, text, converted, blockers, notes, tileMapCount: 0 };
  }

  const rewrites = new Map();  // section -> replacement text

  for (const n of targets) {
    const nodePath = pathOf(n);
    const where = { node: nodePath, line: n.section.line };
    const layers = new Map();   // index -> { key: prop }
    const mapProps = [];        // TileMap-only props to push down
    const keepProps = [];       // Node2D props that stay on the wrapper
    let refused = false;

    for (const p of n.props) {
      const layerMatch = p.key.match(/^layer_(\d+)\/(.+)$/);
      if (layerMatch) {
        const key = layerMatch[2];
        if (!(key in LAYER_KEY_MAP)) {
          blockers.push({ ...where, reason: `unknown per-layer key "${p.key}" — refusing to drop it` });
          refused = true;
          continue;
        }
        const idx = Number(layerMatch[1]);
        if (!layers.has(idx)) layers.set(idx, {});
        layers.get(idx)[key] = p;
        continue;
      }
      if (p.key === 'format') {
        const v = Number(p.value.trim());
        if (v !== KNOWN_TILEMAP_FORMAT) {
          blockers.push({
            ...where,
            reason: `format = ${p.value.trim()}; this converter has only been checked against `
              + `format ${KNOWN_TILEMAP_FORMAT} (Godot 4.2+). Open the scene once in a Godot `
              + `4.2-4.4 editor to let the engine upgrade it, then convert.`,
          });
          refused = true;
        }
        continue;  // the wrapper is a Node2D; it has no format
      }
      if (p.key === 'script') {
        // Default: refuse. A script that `extends TileMap` cannot extend the Node2D
        // this node becomes, and rewriting it is not a text transform.
        //
        // `keepScripts` is the caller saying it already ported the script — that is
        // what docs/scan_tilemap_script.js produces. Then the script line simply
        // rides along on the wrapper, which keeps the node's name, path and
        // transform, so `$Level/TileMap` still finds the script it always found.
        if (!opts.keepScripts) {
          blockers.push({
            ...where,
            reason: 'the node carries a script. A script that extends TileMap cannot extend the '
              + 'Node2D this node becomes; port it first — docs/scan_tilemap_script.js reads the '
              + '.gd and names every call that has to change — then convert with keepScripts.',
          });
          refused = true;
          continue;
        }
        notes.push({
          ...where,
          note: 'script kept on the Node2D wrapper (keepScripts) — it must already extend Node2D '
            + 'and address the layers as child nodes',
        });
        keepProps.push(p);
        continue;
      }
      if (p.key in MAP_KEY_MAP) { mapProps.push(p); continue; }
      keepProps.push(p);
    }
    if (refused) continue;

    if (layers.size === 0) {
      notes.push({ ...where, note: 'TileMap with no layer data — converted to an empty Node2D wrapper' });
    }

    // Layer names: Godot allows blank ones and allows duplicates; node names may
    // not be blank, may not repeat under one parent, and may not contain / : @ % ".
    const siblingsOfLayers = takenUnder.get(nodePath) || new Set();
    const used = new Set();
    const indices = [...layers.keys()].sort((a, b) => a - b);
    const layerNodes = [];
    for (const idx of indices) {
      const props = layers.get(idx);
      let name = props.name ? props.name.value.trim().replace(/^"(.*)"$/, '$1') : '';
      const rawName = name;
      if (!name) name = `Layer${idx}`;
      name = name.replace(/[.:@%/"]/g, '_');
      if (siblingsOfLayers.has(name)) {
        blockers.push({
          ...where,
          reason: `layer ${idx} is named "${rawName}", and "${nodePath}" already has a child with `
            + 'that name. Rename one of them and convert again.',
        });
        refused = true;
        break;
      }
      if (used.has(name)) {
        blockers.push({ ...where, reason: `two layers are both named "${name}" — node names must be unique` });
        refused = true;
        break;
      }
      used.add(name);
      if (name !== rawName) {
        notes.push({ ...where, note: `layer ${idx} name "${rawName}" -> node name "${name}"` });
      }

      let cells = [];
      let tombstones = 0;
      if (props.tile_data) {
        let ints;
        try {
          ints = parseIntArray(props.tile_data.value);
        } catch (e) {
          blockers.push({ ...where, reason: `layer ${idx}: ${e.message}` });
          refused = true;
          break;
        }
        try {
          cells = decodeTileData(ints);
        } catch (e) {
          blockers.push({ ...where, reason: `layer ${idx}: ${e.message}` });
          refused = true;
          break;
        }
        const before = cells.length;
        // 65535 is not a source id a project can be using: both formats spend that
        // value on "no source" (the old one writes the whole word as -1). So a
        // record carrying it is an erased cell in either format, and there is no
        // ambiguity here to refuse — only a corpse to leave behind.
        cells = stripTombstones(cells);
        tombstones = before - cells.length;
      }
      layerNodes.push({ idx, name, props, cells, tombstones });
    }
    if (refused) continue;

    // Emit: the TileMap becomes a Node2D of the same name, same parent, same
    // transform — so every `$Level/TileMap` path in every script still resolves,
    // and every existing child keeps its `parent=` line untouched.
    // The file's own line ending survives: lines were split on \n, so a CRLF file
    // still carries its \r, and every line generated here gets one too.
    const cr = n.section.lines[0].endsWith('\r') ? '\r' : '';
    const out = [n.section.lines[0].replace('type="TileMap"', 'type="Node2D"')];
    const emit = (s) => out.push(s + cr);
    for (const p of keepProps) out.push(...p.lines);
    // Trailing blank lines of the block are kept so the file's spacing survives.
    const tail = [];
    for (let i = n.section.lines.length - 1; i >= 1; i--) {
      if (n.section.lines[i].trim() === '') tail.unshift(n.section.lines[i]); else break;
    }
    while (out.length > 1 && out[out.length - 1].trim() === '') out.pop();

    const childParent = n.attrs.parent === undefined ? '.' : nodePath;
    for (const ln of layerNodes) {
      emit('');
      emit(`[node name=${quoteName(ln.name)} type="TileMapLayer" parent="${childParent}"]`);
      if (ln.cells.length) {
        emit(`tile_map_data = ${packedByteArrayLiteral(encodeTileMapData(ln.cells))}`);
      }
      for (const [srcKey, dstKey] of Object.entries(LAYER_KEY_MAP)) {
        if (!dstKey || srcKey === 'tile_data') continue;
        const p = ln.props[srcKey];
        if (p) emit(`${dstKey} = ${p.value}`);
      }
      for (const p of mapProps) emit(`${MAP_KEY_MAP[p.key]} = ${p.value}`);
    }
    out.push(...(tail.length ? tail : ['' + cr]));

    rewrites.set(n.section, out.join('\n'));
    converted.push({
      node: nodePath,
      line: n.section.line,
      layers: layerNodes.map((l) => ({
        name: l.name, cells: l.cells.length, tombstones: l.tombstones,
      })),
    });
  }

  if (rewrites.size === 0) {
    return { changed: false, text, converted, blockers, notes, tileMapCount: targets.length };
  }

  const outText = sections
    .map((s) => (rewrites.has(s) ? rewrites.get(s) : s.lines.join('\n')))
    .join('\n');

  return { changed: true, text: outText, converted, blockers, notes, tileMapCount: targets.length };
}

// Proof that the rewrite touched only what it claimed to touch: every section of
// the original that was not a converted TileMap must appear, byte for byte, in the
// output. The CLI runs this before writing anything to disk.
function untouchedSectionsSurvive(before, after, convertedPaths) {
  const isConverted = (s) => {
    if (s.kind !== 'node') return false;
    const a = parseAttrs(s.attrText);
    const parent = a.parent;
    const p = parent === undefined ? '.' : (parent === '.' ? a.name : `${parent}/${a.name}`);
    return a.type === 'TileMap' && convertedPaths.includes(p);
  };
  const kept = splitSections(before).filter((s) => !isConverted(s)).map((s) => s.lines.join('\n'));
  const haystack = after;
  const missing = kept.filter((block) => block.trim() && !haystack.includes(block.trim()));
  return { ok: missing.length === 0, missing };
}

const API = {
  EMPTY_SOURCE, KNOWN_TILEMAP_FORMAT, LAYER_KEY_MAP, MAP_KEY_MAP,
  decodeTileData, encodeTileMapData, stripTombstones,
  splitSections, parseAttrs, parseProps, parseIntArray,
  convertSceneText, untouchedSectionsSurvive,
};

// Node (CLI + tests) and the browser (the page) load the same bytes.
if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.TileMapConvert = API;
