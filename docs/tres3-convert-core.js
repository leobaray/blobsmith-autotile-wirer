// tres3-convert-core.js — read a Godot 3 TileSet resource (.tres) and write the
// Godot 4 TileSet that means the same thing, naming every place where "the same
// thing" is not available in Godot 4.
//
// Why this file exists. Godot 4 deleted the Godot 3 TileSet format outright:
// there is no importer, no upgrade dialog and no compatibility path. The engine
// opens a `format=2` TileSet and gives you an empty resource. That hits hardest
// the people who did NOT hand-roll their tileset — the ones who paid for a tool.
// Tilesetter's own docs list Godot 3.x as its Godot export, and TilePipe2 says
// "plain texture export or Godot 3.x tileset format". Their output is a
// `format=2` .tres, and in Godot 4 it is worth nothing.
//
// The two halves of the job are not equally hard:
//
//   geometry — exact. A Godot 3 autotile is `region` + `autotile/tile_size` +
//     `autotile/spacing`, and a subtile at coord c covers
//         region.position + (tile_size + spacing) * c
//     (tile_map.cpp:489). Godot 4's TileSetAtlasSource covers
//         margins + coords * (texture_region_size + separation)
//     The two are the same expression, so margins := region.position,
//     separation := spacing, texture_region_size := tile_size, and every
//     subtile keeps the coordinate it already had. Nothing is guessed.
//
//   bitmasks — lossy in exactly one direction, and this is the part every
//     "just re-draw it" answer on the forums skips. Godot 3 had three bitmask
//     modes; Godot 4 has three terrain modes; they are not the same three.
//         3 BITMASK_2X2        (16 tiles, corners)      -> 4 MATCH_CORNERS
//         3 BITMASK_3X3_MINIMAL(47 tiles, canonical)    -> 4 MATCH_CORNERS_AND_SIDES
//         3 BITMASK_3X3        (256 tiles, free corners)-> nothing
//     Godot 4 cannot express "the top-left neighbour is mine but the top one is
//     not": a corner peering bit is only read when both of its sides are set.
//     So a BITMASK_3X3 tileset converts by canonicalising every mask, which
//     silently merges subtiles — two different drawings answering to one
//     neighbourhood. This module does the canonicalisation AND reports, subtile
//     by subtile, which masks changed and which ones now collide. That report is
//     the thing you cannot get from the engine, from Tilesetter, or from a
//     forum thread.
//
// Refusing beats guessing, same rule as the rest of this site: an occluder, a
// navigation polygon, a priority map, a circle collision shape, a rotated shape
// transform — none of those are invented into something Godot 4-shaped. They
// come back as a named note with the tile id and the coordinate, so you know
// what to redo and where, instead of finding out in play.
'use strict';

// --------------------------------------------------------------------------
// Godot 3 constants (scene/resources/tile_set.h)
// --------------------------------------------------------------------------

var BIND = {
  TOPLEFT: 1, TOP: 2, TOPRIGHT: 4,
  LEFT: 8, CENTER: 16, RIGHT: 32,
  BOTTOMLEFT: 64, BOTTOM: 128, BOTTOMRIGHT: 256,
};
// 1<<16 .. 1<<24 are the BIND_IGNORE_* bits. Godot 4 has no "ignore" concept.
var IGNORE_MASK = 0x1ff0000;

var TILE_MODE = { SINGLE: 0, AUTO: 1, ATLAS: 2 };
var BITMASK_MODE = { X2X2: 0, X3X3_MINIMAL: 1, X3X3: 2 };

// Godot 4 peering-bit property names, by the Godot 3 bind bit they carry.
// Order matches the engine's own enum so a diff against a hand-made file reads
// cleanly.
var PEERING = [
  [BIND.RIGHT, 'right_side', 'side'],
  [BIND.BOTTOMRIGHT, 'bottom_right_corner', 'corner'],
  [BIND.BOTTOM, 'bottom_side', 'side'],
  [BIND.BOTTOMLEFT, 'bottom_left_corner', 'corner'],
  [BIND.LEFT, 'left_side', 'side'],
  [BIND.TOPLEFT, 'top_left_corner', 'corner'],
  [BIND.TOP, 'top_side', 'side'],
  [BIND.TOPRIGHT, 'top_right_corner', 'corner'],
];

// Which side bits guard which corner bit, for canonicalisation.
var CORNER_GUARD = {};
CORNER_GUARD[BIND.TOPLEFT] = [BIND.TOP, BIND.LEFT];
CORNER_GUARD[BIND.TOPRIGHT] = [BIND.TOP, BIND.RIGHT];
CORNER_GUARD[BIND.BOTTOMLEFT] = [BIND.BOTTOM, BIND.LEFT];
CORNER_GUARD[BIND.BOTTOMRIGHT] = [BIND.BOTTOM, BIND.RIGHT];

var SIDE_BITS = BIND.TOP | BIND.BOTTOM | BIND.LEFT | BIND.RIGHT;
var CORNER_BITS = BIND.TOPLEFT | BIND.TOPRIGHT | BIND.BOTTOMLEFT | BIND.BOTTOMRIGHT;

// A Godot 4 terrain mode reads only some of the eight bits. Everything outside
// the mode's own set is not "lost detail", it is a bit the engine never looks
// at — which is why it is reported separately from a real loss.
var GODOT4_MODE = { CORNERS_AND_SIDES: 0, CORNERS: 1, SIDES: 2 };

// --------------------------------------------------------------------------
// A very small reader for the .tres value grammar
// --------------------------------------------------------------------------
// Godot's text format is not JSON and not INI. Values are one of: a quoted
// string, a number, true/false, a null, a typed constructor call
// `Name( a, b )`, an array `[ a, b ]` or a dictionary `{ "k": v }` — and any of
// those can nest and span lines. A regex per shape is how a parser starts
// passing on the file it was written against and failing on the next one, so
// this is a real recursive reader over the whole value.

function Reader(src) { this.s = String(src); this.i = 0; }

Reader.prototype.ws = function () {
  while (this.i < this.s.length && /\s/.test(this.s[this.i])) this.i++;
};
Reader.prototype.eof = function () { this.ws(); return this.i >= this.s.length; };
Reader.prototype.peek = function () { this.ws(); return this.s[this.i]; };
Reader.prototype.expect = function (ch) {
  this.ws();
  if (this.s[this.i] !== ch) {
    throw new Error('expected "' + ch + '" at offset ' + this.i + ', found "'
      + (this.s[this.i] === undefined ? '<end>' : this.s[this.i]) + '"');
  }
  this.i++;
};

Reader.prototype.value = function () {
  this.ws();
  var c = this.s[this.i];
  if (c === undefined) throw new Error('value ended early');
  if (c === '"') return this.string();
  if (c === '[') return this.array();
  if (c === '{') return this.dict();
  if (c === '-' || c === '+' || c === '.' || (c >= '0' && c <= '9')) return this.number();
  var word = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.s.slice(this.i));
  if (!word) throw new Error('unreadable value at offset ' + this.i);
  var name = word[0];
  this.i += name.length;
  if (name === 'true') return true;
  if (name === 'false') return false;
  if (name === 'null') return null;
  this.ws();
  if (this.s[this.i] !== '(') return { type: 'ident', name: name };
  this.i++;
  var args = [];
  this.ws();
  if (this.s[this.i] === ')') { this.i++; }
  else {
    for (;;) {
      args.push(this.value());
      this.ws();
      if (this.s[this.i] === ',') { this.i++; continue; }
      this.expect(')');
      break;
    }
  }
  return { type: 'call', name: name, args: args };
};

Reader.prototype.string = function () {
  this.expect('"');
  var out = '';
  while (this.i < this.s.length) {
    var c = this.s[this.i++];
    if (c === '\\') { out += this.s[this.i++]; continue; }
    if (c === '"') return out;
    out += c;
  }
  throw new Error('unterminated string');
};

Reader.prototype.number = function () {
  var m = /^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.exec(this.s.slice(this.i));
  if (!m) throw new Error('bad number at offset ' + this.i);
  this.i += m[0].length;
  return parseFloat(m[0]);
};

Reader.prototype.array = function () {
  this.expect('[');
  var out = [];
  this.ws();
  if (this.s[this.i] === ']') { this.i++; return out; }
  for (;;) {
    out.push(this.value());
    this.ws();
    if (this.s[this.i] === ',') {
      this.i++;
      this.ws();
      if (this.s[this.i] === ']') { this.i++; return out; }  // trailing comma
      continue;
    }
    this.expect(']');
    return out;
  }
};

Reader.prototype.dict = function () {
  this.expect('{');
  var out = {};
  this.ws();
  if (this.s[this.i] === '}') { this.i++; return out; }
  for (;;) {
    var k = this.value();
    this.expect(':');
    out[String(k)] = this.value();
    this.ws();
    if (this.s[this.i] === ',') {
      this.i++;
      this.ws();
      if (this.s[this.i] === '}') { this.i++; return out; }
      continue;
    }
    this.expect('}');
    return out;
  }
};

function parseValue(text) {
  var r = new Reader(text);
  var v = r.value();
  return v;
}

// Typed-call helpers. `call('Vector2')` shapes are the only ones this converter
// needs to understand; anything else is kept as-is so it can be REPORTED by
// name rather than silently dropped.
function isCall(v, name) { return v && v.type === 'call' && v.name === name; }
function vec2(v) {
  if (!v || v.type !== 'call') return null;
  if (v.name !== 'Vector2' && v.name !== 'Vector2i') return null;
  return { x: v.args[0], y: v.args[1] };
}
function rect2(v) {
  if (!isCall(v, 'Rect2') && !isCall(v, 'Rect2i')) return null;
  return { x: v.args[0], y: v.args[1], w: v.args[2], h: v.args[3] };
}

// --------------------------------------------------------------------------
// Section splitting
// --------------------------------------------------------------------------
// A .tres is a sequence of `[header key=value ...]` blocks, each followed by
// `property = value` lines. A property's value may span many lines (a long
// bitmask_flags array always does), so lines are accumulated until every
// bracket opened on the first line has been closed.

function splitSections(text) {
  var lines = String(text).replace(/\r\n?/g, '\n').split('\n');
  var sections = [];
  var cur = null;
  var pending = null;   // { key, parts }
  var depth = 0;

  function flush() {
    if (pending && cur) cur.props.push({ key: pending.key, raw: pending.parts.join('\n') });
    pending = null;
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (depth === 0 && /^\s*\[[^\]]/.test(line) && !/^\s*\[\s*(?:\]|$)/.test(line)) {
      // a section header — but only when we are not inside an array value
      var head = /^\s*\[(.*)\]\s*$/.exec(line);
      if (head) {
        flush();
        cur = { header: head[1].trim(), props: [] };
        sections.push(cur);
        continue;
      }
    }
    if (depth === 0) {
      // Keys in the [resource] block start with the tile id — `0/name`, not
      // `name` — so the first character can be a digit. A `[A-Za-z_]` opener
      // here reads the whole tile table as blank lines and converts an empty
      // TileSet without complaining.
      var m = /^([A-Za-z0-9_][A-Za-z0-9_/:.\-]*)\s*=\s*(.*)$/.exec(line);
      if (m) {
        flush();
        pending = { key: m[1], parts: [m[2]] };
        depth = bracketDelta(m[2]);
        continue;
      }
      if (/^\s*(;.*)?$/.test(line)) { continue; }   // blank or comment
      if (pending === null && cur === null) continue;
    }
    if (pending) {
      pending.parts.push(line);
      depth += bracketDelta(line);
      if (depth <= 0) { depth = 0; flush(); }
    }
  }
  flush();
  return sections;
}

// Counts brackets outside of quoted strings, so a `"["` inside a tile name
// cannot make the reader swallow the rest of the file.
function bracketDelta(s) {
  var d = 0, inStr = false;
  for (var i = 0; i < s.length; i++) {
    var c = s[i];
    if (inStr) {
      if (c === '\\') { i++; continue; }
      if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === '(' || c === '[' || c === '{') d++;
    else if (c === ')' || c === ']' || c === '}') d--;
  }
  return d;
}

function headerAttrs(header) {
  var out = { _name: (/^\s*([A-Za-z_][A-Za-z0-9_]*)/.exec(header) || [, ''])[1] };
  var re = /([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|[^\s\]]+)/g;
  var m;
  while ((m = re.exec(header))) {
    var v = m[2];
    out[m[1]] = v[0] === '"' ? v.slice(1, -1).replace(/\\(.)/g, '$1') : v;
  }
  return out;
}

// --------------------------------------------------------------------------
// Parse: .tres text -> a plain description of the Godot 3 TileSet
// --------------------------------------------------------------------------

function parseGodot3TileSet(text) {
  var sections = splitSections(text);
  if (!sections.length) throw new Error('this file has no [sections] in it — it is not a Godot resource.');

  var head = headerAttrs(sections[0].header);
  if (head._name !== 'gd_resource') {
    throw new Error('the file starts with [' + sections[0].header + '] — a TileSet resource starts with [gd_resource type="TileSet" ...].');
  }
  if (head.type !== 'TileSet') {
    throw new Error('this is a ' + (head.type || 'nameless') + ' resource, not a TileSet.');
  }
  var format = parseInt(head.format, 10);
  if (format >= 3) {
    throw new Error('this file is already format=' + format + ' — a Godot 4 TileSet. There is nothing to convert.');
  }

  var ext = {};     // id -> { path, type }
  var sub = {};     // id -> { type, props }
  var resource = null;

  for (var i = 1; i < sections.length; i++) {
    var s = sections[i];
    var a = headerAttrs(s.header);
    if (a._name === 'ext_resource') {
      ext[String(a.id)] = { id: String(a.id), path: a.path || '', type: a.type || '' };
    } else if (a._name === 'sub_resource') {
      var props = {};
      for (var p = 0; p < s.props.length; p++) {
        try { props[s.props[p].key] = parseValue(s.props[p].raw); } catch (e) { /* reported later */ }
      }
      sub[String(a.id)] = { id: String(a.id), type: a.type || '', props: props };
    } else if (a._name === 'resource') {
      resource = s;
    }
  }
  if (!resource) throw new Error('this file has no [resource] block, so it defines no tiles.');

  // The [resource] block is a flat `<id>/<what>` namespace.
  var tiles = {};
  var order = [];
  var stray = [];
  for (var q = 0; q < resource.props.length; q++) {
    var key = resource.props[q].key;
    var raw = resource.props[q].raw;
    var km = /^(\d+)\/(.+)$/.exec(key);
    if (!km) { stray.push(key); continue; }
    var id = parseInt(km[1], 10);
    if (!tiles[id]) { tiles[id] = { id: id, props: {} }; order.push(id); }
    try {
      tiles[id].props[km[2]] = parseValue(raw);
    } catch (e) {
      tiles[id].props[km[2]] = { type: 'unreadable', error: e.message, raw: raw };
    }
  }
  order.sort(function (a2, b2) { return a2 - b2; });

  return { format: format, ext: ext, sub: sub, tiles: tiles, order: order, stray: stray };
}

// --------------------------------------------------------------------------
// Bitmask handling
// --------------------------------------------------------------------------

// `bitmask_flags` is a FLAT array that alternates Vector2 coord and int mask —
// not a list of pairs (tile_set.cpp:81-93: it walks the array remembering the
// last Vector2 it saw). An entry with two ints after one Vector2 is legal and
// means the second int overwrites the first for that same coord.
function readBitmaskFlags(arr) {
  var out = [];
  if (!Array.isArray(arr)) return out;
  var last = null;
  var byKey = {};
  for (var i = 0; i < arr.length; i++) {
    var v = arr[i];
    var c = vec2(v);
    if (c) { last = c; continue; }
    if (typeof v === 'number' && last) {
      var k = last.x + ',' + last.y;
      if (byKey[k] === undefined) { byKey[k] = out.length; out.push({ x: last.x, y: last.y, mask: v }); }
      else out[byKey[k]].mask = v;
    }
  }
  return out;
}

// Godot 4 only reads a corner bit when both of its sides are set. This is the
// same rule the paid app's canonicalMask() applies to blob masks; it is written
// again here over Godot 3's bind layout instead of translating twice.
function canonicaliseForGodot4(mask, mode) {
  var m = mask & (SIDE_BITS | CORNER_BITS);
  if (mode === GODOT4_MODE.SIDES) return m & SIDE_BITS;
  if (mode === GODOT4_MODE.CORNERS) return m & CORNER_BITS;
  var out = m & SIDE_BITS;
  for (var bit in CORNER_GUARD) {
    var b = parseInt(bit, 10);
    var g = CORNER_GUARD[b];
    if ((m & b) && (m & g[0]) && (m & g[1])) out |= b;
  }
  return out;
}

function bitmaskModeToTerrainMode(bm) {
  if (bm === BITMASK_MODE.X2X2) return GODOT4_MODE.CORNERS;
  return GODOT4_MODE.CORNERS_AND_SIDES;   // 3X3 and 3X3_MINIMAL
}

function describeMask(mask) {
  var names = [];
  for (var i = 0; i < PEERING.length; i++) {
    if (mask & PEERING[i][0]) names.push(PEERING[i][1]);
  }
  if (!names.length) return 'no neighbours';
  return names.join(' + ');
}

// --------------------------------------------------------------------------
// Collision shapes
// --------------------------------------------------------------------------
// Godot 3 stores a tile's collision as `N/shapes = [ {shape, shape_transform,
// autotile_coord, one_way, one_way_margin} ]`, and the polygon's points are in
// tile-local pixels with (0,0) at the tile's TOP-LEFT plus the transform's
// origin (tile_map.cpp:611-620). Godot 4's polygon points are relative to the
// tile's CENTRE. So every point moves by shape_transform.origin - tile_size/2,
// and nothing else about it changes.
function convertShapes(tile, sub, tileSize, notes, label) {
  var shapes = tile.props['shapes'];
  var out = {};   // "x,y" -> [ {points:[...], oneWay, margin} ]
  if (!Array.isArray(shapes) || !shapes.length) return out;

  for (var i = 0; i < shapes.length; i++) {
    var entry = shapes[i];
    if (!entry || typeof entry !== 'object' || entry.type) {
      notes.push({ level: 'dropped', where: label, what: 'a shapes[] entry that is not a dictionary was ignored' });
      continue;
    }
    var ref = entry['shape'];
    if (!isCall(ref, 'SubResource')) {
      notes.push({ level: 'dropped', where: label, what: 'a collision entry with no shape resource was ignored' });
      continue;
    }
    var sr = sub[String(subId(ref))];
    if (!sr) {
      notes.push({ level: 'dropped', where: label, what: 'collision shape SubResource(' + subId(ref) + ') is not in this file' });
      continue;
    }

    var coord = vec2(entry['autotile_coord']) || { x: 0, y: 0 };
    var key = coord.x + ',' + coord.y;
    var ox = 0, oy = 0;
    var xf = entry['shape_transform'];
    if (isCall(xf, 'Transform2D')) {
      var a = xf.args;
      if (a[0] !== 1 || a[1] !== 0 || a[2] !== 0 || a[3] !== 1) {
        notes.push({
          level: 'blocked', where: label + ' subtile ' + key,
          what: 'its collision shape is rotated or scaled (Transform2D basis '
            + a.slice(0, 4).join(', ') + '). Godot 4 stores collision as plain points, '
            + 'so a rotated shape has to be re-drawn; this one was left out rather than '
            + 'baked in wrong.',
        });
        continue;
      }
      ox = a[4]; oy = a[5];
    }

    var pts = shapePoints(sr, notes, label + ' subtile ' + key);
    if (!pts) continue;

    var moved = [];
    for (var p = 0; p < pts.length; p += 2) {
      moved.push(round4(pts[p] + ox - tileSize.x / 2));
      moved.push(round4(pts[p + 1] + oy - tileSize.y / 2));
    }
    if (!out[key]) out[key] = [];
    out[key].push({
      points: moved,
      oneWay: entry['one_way'] === true,
      margin: typeof entry['one_way_margin'] === 'number' ? entry['one_way_margin'] : null,
    });
  }
  return out;
}

function subId(ref) {
  var a = ref.args[0];
  return typeof a === 'object' && a && a.name ? a.name : a;
}

function shapePoints(sr, notes, where) {
  if (sr.type === 'ConvexPolygonShape2D') {
    var pts = sr.props['points'];
    if (isCall(pts, 'PoolVector2Array') || isCall(pts, 'PackedVector2Array')) {
      var nums = pts.args.filter(function (n) { return typeof n === 'number'; });
      if (nums.length >= 6 && nums.length % 2 === 0) return nums;
    }
    notes.push({ level: 'blocked', where: where, what: 'its ConvexPolygonShape2D has no readable points array' });
    return null;
  }
  if (sr.type === 'RectangleShape2D') {
    // Godot 3 rectangles are centred on the shape's own origin and given as
    // half-extents, so the four corners are ±extents.
    var e = vec2(sr.props['extents']);
    if (!e) {
      notes.push({ level: 'blocked', where: where, what: 'its RectangleShape2D has no extents' });
      return null;
    }
    return [-e.x, -e.y, e.x, -e.y, e.x, e.y, -e.x, e.y];
  }
  notes.push({
    level: 'blocked', where: where,
    what: 'its collision is a ' + (sr.type || 'shape of unknown type')
      + '. Godot 4 tile collision is a polygon; draw this one again in the TileSet editor.',
  });
  return null;
}

function round4(n) { return Math.round(n * 10000) / 10000; }

// --------------------------------------------------------------------------
// Convert
// --------------------------------------------------------------------------

var TERRAIN_COLOURS = [
  [0.35, 0.55, 0.25], [0.25, 0.42, 0.62], [0.66, 0.36, 0.24],
  [0.5, 0.35, 0.6], [0.72, 0.6, 0.2], [0.25, 0.55, 0.55],
];

function convertGodot3TileSet(text, opts) {
  opts = opts || {};
  var parsed = parseGodot3TileSet(text);
  var notes = [];
  var tilesOut = [];       // one Godot 4 atlas source per Godot 3 tile
  var terrainSets = [];

  if (parsed.stray.length) {
    notes.push({
      level: 'info', where: 'the [resource] block',
      what: 'ignored ' + parsed.stray.length + ' key(s) that are not per-tile: '
        + parsed.stray.slice(0, 6).join(', ') + (parsed.stray.length > 6 ? ' …' : ''),
    });
  }

  for (var oi = 0; oi < parsed.order.length; oi++) {
    var id = parsed.order[oi];
    var t = parsed.tiles[id];
    var name = typeof t.props['name'] === 'string' ? t.props['name'] : ('tile ' + id);
    var label = 'tile ' + id + ' ("' + name + '")';

    var texRef = t.props['texture'];
    if (!isCall(texRef, 'ExtResource')) {
      notes.push({ level: 'blocked', where: label, what: 'has no texture, so there is no atlas to build from it' });
      continue;
    }
    var tex = parsed.ext[String(subId(texRef))];
    if (!tex) {
      notes.push({ level: 'blocked', where: label, what: 'points at ExtResource(' + subId(texRef) + '), which this file does not declare' });
      continue;
    }

    var region = rect2(t.props['region']);
    if (!region) {
      notes.push({ level: 'blocked', where: label, what: 'has no region rectangle' });
      continue;
    }

    var mode = typeof t.props['tile_mode'] === 'number' ? t.props['tile_mode'] : TILE_MODE.SINGLE;
    var spacing = typeof t.props['autotile/spacing'] === 'number' ? t.props['autotile/spacing'] : 0;
    var size = vec2(t.props['autotile/tile_size']);
    if (mode === TILE_MODE.SINGLE || !size || !size.x || !size.y) {
      size = { x: region.w, y: region.h };
      spacing = 0;
    }

    var cols = Math.floor((region.w + spacing) / (size.x + spacing));
    var rows = Math.floor((region.h + spacing) / (size.y + spacing));
    if (cols < 1 || rows < 1) {
      notes.push({
        level: 'blocked', where: label,
        what: 'its region is ' + region.w + 'x' + region.h + ' but one subtile is '
          + size.x + 'x' + size.y + ' — no whole subtile fits',
      });
      continue;
    }
    var usedW = cols * size.x + (cols - 1) * spacing;
    var usedH = rows * size.y + (rows - 1) * spacing;
    if (usedW !== region.w || usedH !== region.h) {
      notes.push({
        level: 'info', where: label,
        what: 'its region is ' + region.w + 'x' + region.h + ', which is not a whole number of '
          + size.x + 'x' + size.y + ' subtiles; the ' + (region.w - usedW) + 'x'
          + (region.h - usedH) + ' px left over at the right/bottom edge is not part of any tile '
          + 'and was not turned into one',
      });
    }

    var shapesByCoord = convertShapes(t, parsed.sub, size, notes, label);

    // ---- terrain, if this was an autotile ---------------------------------
    var terrain = null;
    if (mode === TILE_MODE.AUTO) {
      var bm = typeof t.props['autotile/bitmask_mode'] === 'number'
        ? t.props['autotile/bitmask_mode'] : BITMASK_MODE.X2X2;
      var g4mode = bitmaskModeToTerrainMode(bm);
      var flags = readBitmaskFlags(t.props['autotile/bitmask_flags']);

      // Every Godot 3 autotile becomes its own terrain SET, not a second
      // terrain inside a shared one. In Godot 3 an autotile only ever matched
      // itself; terrains inside one Godot 4 terrain set match each other, so
      // merging them would invent adjacency rules the original never had.
      var setIndex = terrainSets.length;
      terrain = { set: setIndex, index: 0, mode: g4mode, byCoord: {} };
      terrainSets.push({
        mode: g4mode,
        name: name,
        colour: TERRAIN_COLOURS[setIndex % TERRAIN_COLOURS.length],
      });

      if (bm === BITMASK_MODE.X3X3) {
        notes.push({
          level: 'changed', where: label,
          what: 'was BITMASK_3X3 (256 combinations, corners free of their sides). Godot 4 '
            + 'only has MATCH_CORNERS_AND_SIDES (47), where a corner bit is read only when '
            + 'both of its sides are set. Every mask below was put through that rule.',
        });
      }

      var seen = {};
      for (var f = 0; f < flags.length; f++) {
        var fl = flags[f];
        var ck = fl.x + ',' + fl.y;
        if (fl.x < 0 || fl.y < 0 || fl.x >= cols || fl.y >= rows) {
          notes.push({
            level: 'dropped', where: label,
            what: 'bitmask for subtile ' + ck + ' is outside the ' + cols + 'x' + rows
              + ' grid its region describes, and was dropped',
          });
          continue;
        }
        if (fl.mask & IGNORE_MASK) {
          notes.push({
            level: 'changed', where: label + ' subtile ' + ck,
            what: 'used Godot 3 "ignore" bits. Godot 4 has no ignore state; the bit was '
              + 'read as "no neighbour there".',
          });
        }
        if (!(fl.mask & BIND.CENTER)) {
          notes.push({
            level: 'info', where: label + ' subtile ' + ck,
            what: 'its bitmask has no CENTER bit — in Godot 3 that subtile was never picked. '
              + 'It still becomes a tile here, just with no terrain on it.',
          });
          continue;
        }
        var canon = canonicaliseForGodot4(fl.mask, g4mode);
        var dropped = (fl.mask & (SIDE_BITS | CORNER_BITS)) & ~canon;
        if (dropped) {
          notes.push({
            level: 'changed', where: label + ' subtile ' + ck,
            what: 'Godot 3 said "' + describeMask(fl.mask & (SIDE_BITS | CORNER_BITS))
              + '"; Godot 4 can only say "' + describeMask(canon) + '" (dropped: '
              + describeMask(dropped) + ')',
          });
        }
        if (seen[canon] !== undefined) {
          notes.push({
            level: 'collision', where: label,
            what: 'subtiles ' + seen[canon] + ' and ' + ck + ' both answer to "'
              + describeMask(canon) + '" in Godot 4. The engine will paint one of them and '
              + 'never the other — pick the one you want and delete the terrain data on the '
              + 'other, or the map will look like a tile went missing.',
          });
        } else {
          seen[canon] = ck;
        }
        terrain.byCoord[ck] = canon;
      }
      if (!flags.length) {
        notes.push({
          level: 'info', where: label,
          what: 'is an autotile with an empty bitmask table, so it converts to plain tiles '
            + 'with no terrain on them',
        });
      }
    }

    // ---- per-tile data that Godot 4 either keeps or cannot ----------------
    var texOffset = vec2(t.props['tex_offset']);
    if (texOffset && (texOffset.x || texOffset.y)) {
      notes.push({
        level: 'dropped', where: label,
        what: 'had tex_offset ' + texOffset.x + ', ' + texOffset.y + '. Godot 4\'s equivalent '
          + '(texture_origin) is measured from the tile centre with the opposite sign '
          + 'convention, so it is named here instead of being written in with a guessed sign.',
      });
    }
    var modulate = isCall(t.props['modulate'], 'Color') ? t.props['modulate'].args : null;
    if (modulate && !(modulate[0] === 1 && modulate[1] === 1 && modulate[2] === 1 && (modulate[3] === undefined || modulate[3] === 1))) {
      notes.push({
        level: 'kept', where: label,
        what: 'its modulate colour was carried over onto every subtile',
      });
    } else { modulate = null; }
    var zIndex = typeof t.props['z_index'] === 'number' && t.props['z_index'] !== 0
      ? t.props['z_index'] : null;

    for (var extra in { 'occluder': 1, 'navigation': 1, 'autotile/occluder_map': 1, 'autotile/navpoly_map': 1 }) {
      var val = t.props[extra];
      var has = val !== undefined && val !== null
        && !(Array.isArray(val) && val.length === 0)
        && !(val && val.type === 'ident' && val.name === 'null');
      if (has) {
        notes.push({
          level: 'dropped', where: label,
          what: extra + ' is not converted. Godot 4 keeps light occluders and navigation '
            + 'polygons on their own layers with a different shape, and inventing them from '
            + 'the Godot 3 data would put geometry in your scene that you never drew.',
        });
      }
    }
    var prio = t.props['autotile/priority_map'];
    if (Array.isArray(prio) && prio.length) {
      notes.push({
        level: 'dropped', where: label,
        what: 'its subtile priority map was dropped. Godot 4 has per-alternative '
          + 'probability instead; set it on the tiles you wanted to appear more often.',
      });
    }
    var zmap = t.props['autotile/z_index_map'];
    if (Array.isArray(zmap) && zmap.length) {
      notes.push({ level: 'dropped', where: label, what: 'its per-subtile z_index map was dropped' });
    }

    tilesOut.push({
      id: id, name: name, mode: mode, texture: tex, region: region, size: size,
      spacing: spacing, cols: cols, rows: rows, terrain: terrain,
      shapes: shapesByCoord, modulate: modulate, zIndex: zIndex,
    });
  }

  if (!tilesOut.length) {
    return { ok: false, tres: null, tiles: tilesOut, terrainSets: terrainSets, notes: notes,
      error: 'nothing in this TileSet could be converted — see the notes.' };
  }

  var tres = writeGodot4TileSet(tilesOut, terrainSets, opts);
  return { ok: true, tres: tres, tiles: tilesOut, terrainSets: terrainSets, notes: notes, error: null };
}

// --------------------------------------------------------------------------
// Emit the Godot 4 .tres
// --------------------------------------------------------------------------

function escTres(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function writeGodot4TileSet(tiles, terrainSets, opts) {
  var extByPath = {};
  var extList = [];
  for (var i = 0; i < tiles.length; i++) {
    var p = tiles[i].texture.path;
    if (extByPath[p] === undefined) {
      extByPath[p] = 'tex_' + extList.length;
      extList.push({ path: p, id: extByPath[p] });
    }
  }

  var anyCollision = tiles.some(function (t) { return Object.keys(t.shapes).length > 0; });

  var L = [];
  L.push('[gd_resource type="TileSet" load_steps=' + (extList.length + tiles.length + 1) + ' format=3]');
  L.push('');
  for (var e = 0; e < extList.length; e++) {
    L.push('[ext_resource type="Texture2D" path="' + escTres(extList[e].path) + '" id="' + extList[e].id + '"]');
  }
  L.push('');

  for (var ti = 0; ti < tiles.length; ti++) {
    var t = tiles[ti];
    var srcId = 'TileSetAtlasSource_' + t.id;
    L.push('[sub_resource type="TileSetAtlasSource" id="' + srcId + '"]');
    L.push('texture = ExtResource("' + extByPath[t.texture.path] + '")');
    if (t.region.x || t.region.y) L.push('margins = Vector2i(' + t.region.x + ', ' + t.region.y + ')');
    if (t.spacing) L.push('separation = Vector2i(' + t.spacing + ', ' + t.spacing + ')');
    L.push('texture_region_size = Vector2i(' + t.size.x + ', ' + t.size.y + ')');

    for (var y = 0; y < t.rows; y++) {
      for (var x = 0; x < t.cols; x++) {
        var ck = x + ',' + y;
        var pre = x + ':' + y + '/0';
        L.push(pre + ' = 0');
        if (t.terrain && t.terrain.byCoord[ck] !== undefined) {
          var mask = t.terrain.byCoord[ck];
          L.push(pre + '/terrain_set = ' + t.terrain.set);
          L.push(pre + '/terrain = ' + t.terrain.index);
          for (var b = 0; b < PEERING.length; b++) {
            var bit = PEERING[b][0], pname = PEERING[b][1], kind = PEERING[b][2];
            if (t.terrain.mode === 2 && kind !== 'side') continue;
            if (t.terrain.mode === 1 && kind !== 'corner') continue;
            if (mask & bit) L.push(pre + '/terrains_peering_bit/' + pname + ' = ' + t.terrain.index);
          }
        }
        if (t.modulate) {
          var m = t.modulate;
          L.push(pre + '/modulate = Color(' + m[0] + ', ' + m[1] + ', ' + m[2] + ', '
            + (m[3] === undefined ? 1 : m[3]) + ')');
        }
        if (t.zIndex !== null) L.push(pre + '/z_index = ' + t.zIndex);
        var polys = t.shapes[ck] || [];
        for (var pi = 0; pi < polys.length; pi++) {
          L.push(pre + '/physics_layer_0/polygon_' + pi + '/points = PackedVector2Array('
            + polys[pi].points.join(', ') + ')');
          if (polys[pi].oneWay) {
            L.push(pre + '/physics_layer_0/polygon_' + pi + '/one_way = true');
            if (polys[pi].margin !== null) {
              L.push(pre + '/physics_layer_0/polygon_' + pi + '/one_way_margin = ' + polys[pi].margin);
            }
          }
        }
      }
    }
    L.push('');
  }

  L.push('[resource]');
  if (anyCollision) {
    L.push('physics_layer_0/collision_layer = 1');
    L.push('physics_layer_0/collision_mask = 1');
  }
  for (var s = 0; s < terrainSets.length; s++) {
    var ts = terrainSets[s];
    L.push('terrain_set_' + s + '/mode = ' + ts.mode);
    L.push('terrain_set_' + s + '/terrain_0/name = "' + escTres(ts.name) + '"');
    L.push('terrain_set_' + s + '/terrain_0/color = Color(' + ts.colour[0] + ', '
      + ts.colour[1] + ', ' + ts.colour[2] + ', 1)');
  }
  for (var t2 = 0; t2 < tiles.length; t2++) {
    L.push('sources/' + tiles[t2].id + ' = SubResource("TileSetAtlasSource_' + tiles[t2].id + '")');
  }
  L.push('');
  return L.join('\n');
}

// --------------------------------------------------------------------------

var API = {
  BIND: BIND,
  TILE_MODE: TILE_MODE,
  BITMASK_MODE: BITMASK_MODE,
  GODOT4_MODE: GODOT4_MODE,
  PEERING: PEERING,
  parseValue: parseValue,
  splitSections: splitSections,
  headerAttrs: headerAttrs,
  parseGodot3TileSet: parseGodot3TileSet,
  readBitmaskFlags: readBitmaskFlags,
  canonicaliseForGodot4: canonicaliseForGodot4,
  bitmaskModeToTerrainMode: bitmaskModeToTerrainMode,
  describeMask: describeMask,
  writeGodot4TileSet: writeGodot4TileSet,
  convertGodot3TileSet: convertGodot3TileSet,
};

if (typeof module !== 'undefined' && module.exports) module.exports = API;
if (typeof window !== 'undefined') window.Tres3 = API;
