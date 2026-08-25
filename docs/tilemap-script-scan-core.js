// The other half of docs/convert_tilemap_to_tilemaplayer.js.
//
// That converter rewrites the SCENE and refuses any `TileMap` node carrying a
// script, because a script that `extends TileMap` cannot extend the `Node2D` the
// node becomes. Measured against `godotengine/godot-demo-projects` on branch 4.2,
// that is 3 of 17 real `TileMap` nodes — roughly one in six. This file is what
// those three get instead of a dead end: it reads the `.gd` and says, call by
// call, what the port is.
//
// The whole reason a port exists at all is the shape the converter emits. One
// `TileMap` becomes a `Node2D` wrapper of the SAME NAME plus one `TileMapLayer`
// child per layer, so `$Level/TileMap` still resolves and the layer index stops
// being an argument and becomes a child node:
//
//     set_cell(0, pos, 1, Vector2i(2, 3))   ->   $Ground.set_cell(pos, 1, Vector2i(2, 3))
//
// That single sentence covers 20 of the 63 `TileMap` methods. The table below
// covers the rest, and it is not typed from the online class reference: every
// name, arity and drop in API_TABLE comes out of `ClassDB` in a real binary via
// docs/dump_tilemap_api.gd + docs/build_tilemap_api_map.js, and
// docs/verify_tilemap_script_api.sh rebuilds it from Godot 4.2/4.3/4.4/4.7 and
// fails if one byte here drifts from what the engines say.
//
// What this file will not do is guess. A layer index that is not an integer
// literal, a method whose replacement is a node operation rather than a call —
// those come back as findings a human has to answer, never as a silent rewrite.
'use strict';

// --- what the engines say ------------------------------------------------------
//
// kind:
//   same  — identical signature on TileMapLayer; only the receiver changes
//   drop  — same method, minus the listed arguments (always the leading `layer`,
//           and for the seven getters also the trailing `use_proxies`)
//   enum  — same arity, but TileMap.VisibilityMode became
//           TileMapLayer.DebugVisibilityMode (same three values, new names)
//   gone  — no method of this name on TileMapLayer at all
// old/new are argument counts INCLUDING optional ones.
const API_TABLE = {
  _tile_data_runtime_update: { kind: 'drop', drop: ['layer'], old: 3, new: 2 },
  _use_tile_data_runtime_update: { kind: 'drop', drop: ['layer'], old: 2, new: 1 },
  add_layer: { kind: 'gone', old: 1 },
  clear: { kind: 'same', old: 0, new: 0 },
  clear_layer: { kind: 'gone', old: 1 },
  erase_cell: { kind: 'drop', drop: ['layer'], old: 2, new: 1 },
  fix_invalid_tiles: { kind: 'same', old: 0, new: 0 },
  force_update: { kind: 'gone', old: 1 },
  get_cell_alternative_tile: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  get_cell_atlas_coords: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  get_cell_source_id: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  get_cell_tile_data: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  get_collision_visibility_mode: { kind: 'enum', old: 0, new: 0 },
  get_coords_for_body_rid: { kind: 'same', old: 1, new: 1 },
  get_layer_for_body_rid: { kind: 'gone', old: 1 },
  get_layer_modulate: { kind: 'gone', old: 1 },
  get_layer_name: { kind: 'gone', old: 1 },
  get_layer_navigation_map: { kind: 'gone', old: 1 },
  get_layer_y_sort_origin: { kind: 'gone', old: 1 },
  get_layer_z_index: { kind: 'gone', old: 1 },
  get_layers_count: { kind: 'gone', old: 0 },
  get_navigation_map: { kind: 'drop', drop: ['layer'], old: 1, new: 0 },
  get_navigation_visibility_mode: { kind: 'enum', old: 0, new: 0 },
  get_neighbor_cell: { kind: 'same', old: 2, new: 2 },
  get_pattern: { kind: 'drop', drop: ['layer'], old: 2, new: 1 },
  get_rendering_quadrant_size: { kind: 'same', old: 0, new: 0 },
  get_surrounding_cells: { kind: 'same', old: 1, new: 1 },
  get_tileset: { kind: 'gone', old: 0 },
  get_used_cells: { kind: 'drop', drop: ['layer'], old: 1, new: 0 },
  get_used_cells_by_id: { kind: 'drop', drop: ['layer'], old: 4, new: 3 },
  get_used_rect: { kind: 'same', old: 0, new: 0 },
  is_cell_flipped_h: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  is_cell_flipped_v: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  is_cell_transposed: { kind: 'drop', drop: ['layer', 'use_proxies'], old: 3, new: 1 },
  is_collision_animatable: { kind: 'gone', old: 0 },
  is_layer_enabled: { kind: 'gone', old: 1 },
  is_layer_navigation_enabled: { kind: 'gone', old: 1 },
  is_layer_y_sort_enabled: { kind: 'gone', old: 1 },
  local_to_map: { kind: 'same', old: 1, new: 1 },
  map_pattern: { kind: 'same', old: 3, new: 3 },
  map_to_local: { kind: 'same', old: 1, new: 1 },
  move_layer: { kind: 'gone', old: 2 },
  notify_runtime_tile_data_update: { kind: 'drop', drop: ['layer'], old: 1, new: 0 },
  remove_layer: { kind: 'gone', old: 1 },
  set_cell: { kind: 'drop', drop: ['layer'], old: 5, new: 4 },
  set_cells_terrain_connect: { kind: 'drop', drop: ['layer'], old: 5, new: 4 },
  set_cells_terrain_path: { kind: 'drop', drop: ['layer'], old: 5, new: 4 },
  set_collision_animatable: { kind: 'gone', old: 1 },
  set_collision_visibility_mode: { kind: 'enum', old: 1, new: 1 },
  set_layer_enabled: { kind: 'gone', old: 2 },
  set_layer_modulate: { kind: 'gone', old: 2 },
  set_layer_name: { kind: 'gone', old: 2 },
  set_layer_navigation_enabled: { kind: 'gone', old: 2 },
  set_layer_navigation_map: { kind: 'gone', old: 2 },
  set_layer_y_sort_enabled: { kind: 'gone', old: 2 },
  set_layer_y_sort_origin: { kind: 'gone', old: 2 },
  set_layer_z_index: { kind: 'gone', old: 2 },
  set_navigation_map: { kind: 'drop', drop: ['layer'], old: 2, new: 1 },
  set_navigation_visibility_mode: { kind: 'enum', old: 1, new: 1 },
  set_pattern: { kind: 'drop', drop: ['layer'], old: 3, new: 2 },
  set_rendering_quadrant_size: { kind: 'same', old: 1, new: 1 },
  set_tileset: { kind: 'gone', old: 1 },
  update_internals: { kind: 'same', old: 0, new: 0 },
};

// --- what we say the replacement is -------------------------------------------
//
// Everything above is the engine's word. Everything here is OURS: the engine can
// say `set_layer_z_index` is gone, it cannot say what to write instead. Each entry
// is checked for existence by docs/verify_tilemap_script_api.sh — `prop` must be a
// property and `call` a method that TileMapLayer really has, inheritance included
// — so the advice can never name something that does not exist. Whether it is the
// RIGHT advice is a claim this file makes and the doc argues.
//
//   prop      the layer node property that replaces the call
//   call      the layer node method that replaces the call
//   perLayer  true when the old call addressed one layer by index, so the
//             rewrite is mechanical once the index is a literal
//   manual    prose for the cases where no single call replaces it
const GONE_REPLACEMENTS = {
  set_layer_name: { prop: 'name', perLayer: true, assign: true, base: 'Node' },
  get_layer_name: { prop: 'name', perLayer: true, base: 'Node' },
  set_layer_enabled: { prop: 'enabled', perLayer: true, assign: true },
  is_layer_enabled: { prop: 'enabled', perLayer: true },
  set_layer_modulate: { prop: 'modulate', perLayer: true, assign: true, base: 'CanvasItem' },
  get_layer_modulate: { prop: 'modulate', perLayer: true, base: 'CanvasItem' },
  set_layer_y_sort_enabled: { prop: 'y_sort_enabled', perLayer: true, assign: true, base: 'CanvasItem' },
  is_layer_y_sort_enabled: { prop: 'y_sort_enabled', perLayer: true, base: 'CanvasItem' },
  set_layer_y_sort_origin: { prop: 'y_sort_origin', perLayer: true, assign: true },
  get_layer_y_sort_origin: { prop: 'y_sort_origin', perLayer: true },
  set_layer_z_index: { prop: 'z_index', perLayer: true, assign: true, base: 'CanvasItem' },
  get_layer_z_index: { prop: 'z_index', perLayer: true, base: 'CanvasItem' },
  set_layer_navigation_enabled: { prop: 'navigation_enabled', perLayer: true, assign: true },
  is_layer_navigation_enabled: { prop: 'navigation_enabled', perLayer: true },
  set_layer_navigation_map: { call: 'set_navigation_map', perLayer: true },
  get_layer_navigation_map: { call: 'get_navigation_map', perLayer: true },
  clear_layer: { call: 'clear', perLayer: true },
  force_update: { call: 'update_internals', perLayer: true },
  set_tileset: {
    prop: 'tile_set',
    manual: 'every extracted TileMapLayer carries its own `tile_set`; set it on each layer node.',
  },
  get_tileset: {
    prop: 'tile_set',
    manual: 'read `tile_set` off any one of the layer nodes — the converter copies the same one into all of them.',
  },
  set_collision_animatable: {
    prop: 'use_kinematic_bodies',
    manual: 'renamed: `collision_animatable` is `use_kinematic_bodies` on each layer node.',
  },
  is_collision_animatable: {
    prop: 'use_kinematic_bodies',
    manual: 'renamed: read `use_kinematic_bodies` off a layer node.',
  },
  get_layers_count: {
    manual: 'layers are now child nodes — count them, e.g. with a filter on `get_children()`.',
  },
  add_layer: { manual: 'add a `TileMapLayer` child node instead (`add_child`).' },
  move_layer: { manual: 'reorder the child nodes instead (`move_child`); draw order follows tree order.' },
  remove_layer: { manual: 'free the layer node instead (`queue_free`).' },
  get_layer_for_body_rid: {
    call: 'has_body_rid',
    manual: 'ask each layer node `has_body_rid(body)` — it answers per node instead of returning an index.',
  },
};

// The three VisibilityMode constants kept their values and changed their names.
const ENUM_CONSTANTS = {
  VISIBILITY_MODE_DEFAULT: 'DEBUG_VISIBILITY_MODE_DEFAULT',
  VISIBILITY_MODE_FORCE_HIDE: 'DEBUG_VISIBILITY_MODE_FORCE_HIDE',
  VISIBILITY_MODE_FORCE_SHOW: 'DEBUG_VISIBILITY_MODE_FORCE_SHOW',
};

// TileMap properties a script can touch that are not on TileMapLayer under that
// name. `layers` is the inspector's array of layers and has no successor at all.
const PROPERTY_RENAMES = {
  collision_animatable: 'use_kinematic_bodies',
};

// --- reading GDScript without parsing it ---------------------------------------

// A mask that is 1 wherever the character is inside a string or a comment, so the
// scan never fires on `"set_cell"` in a printed message or on a commented-out line.
// GDScript strings: "..." '...' with backslash escapes, and """...""" / '''...'''.
function maskLiterals(src) {
  const mask = new Uint8Array(src.length);
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '#') {
      while (i < src.length && src[i] !== '\n') mask[i++] = 1;
      continue;
    }
    if (c === '"' || c === "'") {
      const triple = src.startsWith(c.repeat(3), i);
      const quote = triple ? c.repeat(3) : c;
      let j = i + quote.length;
      while (j < src.length) {
        if (src[j] === '\\') { j += 2; continue; }
        if (src.startsWith(quote, j)) { j += quote.length; break; }
        if (!triple && src[j] === '\n') break;   // unterminated: stop at the line
        j++;
      }
      for (let k = i; k < Math.min(j, src.length); k++) mask[k] = 1;
      i = Math.max(j, i + 1);
      continue;
    }
    i++;
  }
  return mask;
}

const OPEN = { '(': ')', '[': ']', '{': '}' };

// Walks from the index of an opening bracket to its match, using the mask so that
// a bracket inside a string does not count. Returns -1 if it never closes.
function matchBracket(src, mask, open) {
  const stack = [OPEN[src[open]]];
  for (let i = open + 1; i < src.length; i++) {
    if (mask[i]) continue;
    const c = src[i];
    if (OPEN[c]) { stack.push(OPEN[c]); continue; }
    if (c === stack[stack.length - 1]) {
      stack.pop();
      if (!stack.length) return i;
    }
  }
  return -1;
}

// Top-level commas only: `set_cell(0, pos, id, Vector2i(1, 2))` is four arguments.
function splitArgs(src, mask, open, close) {
  const inner = src.slice(open + 1, close);
  if (!inner.trim()) return [];
  const args = [];
  let depth = 0, start = 0;
  for (let i = 0; i < inner.length; i++) {
    const abs = open + 1 + i;
    if (mask[abs]) continue;
    const c = inner[i];
    if (OPEN[c]) depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === ',' && depth === 0) { args.push(inner.slice(start, i)); start = i + 1; }
  }
  args.push(inner.slice(start));
  return args.map((a) => a.trim());
}

const IDENT_CHAR = /[A-Za-z0-9_]/;

// The receiver is what sits immediately before `.method(`: `$Level/TileMap`,
// `self`, `tm`, `get_node("x")`, or nothing at all for a bare call.
function receiverBefore(src, mask, dotIndex) {
  let i = dotIndex - 1;
  while (i >= 0 && (src[i] === ' ' || src[i] === '\t')) i--;
  if (i < 0) return null;
  const end = i + 1;
  if (src[i] === ')' || src[i] === ']') {
    const want = src[i] === ')' ? '(' : '[';
    let depth = 0;
    for (; i >= 0; i--) {
      if (mask[i]) continue;
      if (src[i] === ')' || src[i] === ']') depth++;
      else if (src[i] === want || src[i] === '(') {
        depth--;
        if (!depth) break;
      }
    }
    if (i < 0) return null;
    i--;
    while (i >= 0 && IDENT_CHAR.test(src[i])) i--;
    return src.slice(i + 1, end);
  }
  while (i >= 0 && (IDENT_CHAR.test(src[i]) || src[i] === '.' || src[i] === '/' || src[i] === '$' || src[i] === '%')) i--;
  const recv = src.slice(i + 1, end);
  return recv || null;
}

const lineOf = (src, index) => src.slice(0, index).split('\n').length;
const colOf = (src, index) => index - (src.lastIndexOf('\n', index - 1) + 1) + 1;
const lineTextAt = (src, index) => {
  const a = src.lastIndexOf('\n', index - 1) + 1;
  const b = src.indexOf('\n', index);
  return src.slice(a, b === -1 ? src.length : b);
};

// --- the scan ------------------------------------------------------------------

// layerNames: what the converter named the layer nodes, index -> node name, e.g.
// ["Ground", "Walls"]. With it, a literal layer index becomes a real node path and
// the rewrite is exact. Without it, the finding still names the call and the shape
// of the fix, and says the index could not be resolved.
function layerTarget(layerNames, index, recv) {
  const name = layerNames && layerNames[index];
  if (name === undefined || name === null) return null;
  // A bare call means the script sits on the wrapper, so the layers are its own
  // children and `$Name` is the shortest true path. Through another receiver the
  // wrapper is a Node2D, and `get_node` is the only thing that works on it.
  if (recv === null || recv === 'self') return `$${/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : `"${name}"`}`;
  return `${recv}.get_node(${JSON.stringify(name)})`;
}

function scanScriptText(src, opts = {}) {
  const layerNames = opts.layerNames || null;
  const mask = maskLiterals(src);
  const findings = [];
  const edits = [];   // {start, end, text} — only the ones safe to apply
  // Half of these method names are not TileMap's alone: `clear()` is on Array and
  // Dictionary, `get_used_rect()` is on Image. A name whose signature did not change
  // is only worth reporting in a file that has already proved it talks to a TileMap —
  // `extends TileMap`, a method only TileMap ever had, or a layer index written as an
  // integer. Without one of those, the same-signature calls are somebody else's.
  let strong = false;
  const deferred = [];
  const pushLater = (f) => deferred.push(f);
  // A receiver that IS one of the layer nodes means this line was ported already.
  const isLayerReceiver = (recv) => {
    if (!recv || !layerNames) return false;
    const m2 = recv.match(/^[$%]"?([A-Za-z_][A-Za-z0-9_]*)"?$/) || recv.match(/^get_node\(\s*"([^"]+)"\s*\)$/);
    return Boolean(m2 && layerNames.includes(m2[1]));
  };

  const push = (f, edit) => {
    findings.push(f);
    if (edit) edits.push(edit);
  };

  // `extends TileMap` — the reason the converter refused in the first place.
  const extendsRe = /^[ \t]*extends[ \t]+TileMap[ \t]*$/gm;
  for (let m; (m = extendsRe.exec(src)); ) {
    if (mask[m.index]) continue;
    strong = true;
    const ext = m[0].replace('TileMap', 'Node2D');
    push({
      line: lineOf(src, m.index), col: colOf(src, m.index),
      what: 'extends TileMap', kind: 'extends', auto: true,
      before: m[0].trim(),
      after: ext.trim(),
      note: 'the converter turns the TileMap into a Node2D wrapper with one TileMapLayer child per '
        + 'layer, and the script stays on that wrapper — same name, same path, so every `$Level/TileMap` '
        + 'elsewhere still resolves. If the map had exactly ONE layer you can instead move this script '
        + 'onto that child and write `extends TileMapLayer`; then the calls below lose their receiver '
        + 'instead of gaining one.',
    }, { start: m.index, end: m.index + m[0].length, text: ext });
  }

  // `TileMap.VISIBILITY_MODE_*` — same three values, new names, so this one is exact.
  const constRe = /\bTileMap\.(VISIBILITY_MODE_[A-Z_]+)\b/g;
  for (let m; (m = constRe.exec(src)); ) {
    if (mask[m.index]) continue;
    const to = ENUM_CONSTANTS[m[1]];
    if (!to) continue;
    push({
      line: lineOf(src, m.index), col: colOf(src, m.index),
      what: m[0], kind: 'constant', auto: true,
      before: m[0], after: `TileMapLayer.${to}`,
      note: 'the enum kept its three values and changed its name.',
    }, { start: m.index, end: m.index + m[0].length, text: `TileMapLayer.${to}` });
  }

  // Every other bare mention of the class: `as TileMap`, `is TileMap`, `: TileMap`,
  // `TileMap.new()`. TileMap still EXISTS in 4.7, so none of these is an error —
  // they are just no longer true about a node the converter has rewritten.
  const classRe = /\bTileMap\b(?!Layer)(?!\.VISIBILITY_MODE_)/g;
  for (let m; (m = classRe.exec(src)); ) {
    if (mask[m.index]) continue;
    const text = lineTextAt(src, m.index);
    if (/^[ \t]*extends[ \t]+TileMap[ \t]*$/.test(text)) continue;   // already reported
    strong = true;
    push({
      line: lineOf(src, m.index), col: colOf(src, m.index),
      what: 'TileMap', kind: 'class-reference', auto: false,
      before: text.trim(), after: null,
      note: 'the node this used to describe is a Node2D wrapper now, and the tiles live in its '
        + 'TileMapLayer children. TileMap is still a real class in 4.7, so this compiles — it is '
        + 'just no longer the type of that node.',
    });
  }

  // Property names that moved.
  for (const [from, to] of Object.entries(PROPERTY_RENAMES)) {
    const re = new RegExp(`(?<![A-Za-z0-9_])${from}(?![A-Za-z0-9_])`, 'g');
    for (let m; (m = re.exec(src)); ) {
      if (mask[m.index]) continue;
      strong = true;
      push({
        line: lineOf(src, m.index), col: colOf(src, m.index),
        what: from, kind: 'property-renamed', auto: false,
        before: lineTextAt(src, m.index).trim(), after: null,
        note: `on TileMapLayer this property is \`${to}\`, and it lives on each layer node.`,
      });
    }
  }

  // The calls.
  const callRe = /(?<![A-Za-z0-9_])([a-z_][a-z0-9_]*)[ \t]*\(/g;
  for (let m; (m = callRe.exec(src)); ) {
    const name = m[1];
    const entry = API_TABLE[name];
    if (!entry || mask[m.index]) continue;
    const open = m.index + m[0].length - 1;
    const close = matchBracket(src, mask, open);
    if (close === -1) continue;
    const args = splitArgs(src, mask, open, close);
    const dot = m.index - 1;
    const recv = src[dot] === '.' ? receiverBefore(src, mask, dot) : null;
    // `func set_cell(...)` is a declaration of someone else's method, not a call.
    const head = lineTextAt(src, m.index).trimStart();
    if (head.startsWith('func ') || head.startsWith('static func ')) continue;
    const callStart = recv === null ? m.index : m.index - 1 - recv.length;
    const before = src.slice(callStart, close + 1);
    const at = { line: lineOf(src, m.index), col: colOf(src, callStart), what: name };

    if (isLayerReceiver(recv)) continue;   // this line is already ported

    if (entry.kind === 'same') {
      // Through a plain variable this is almost always some other object's method
      // of the same name; on the node itself (`clear()`, `self.clear()`, `$Map.clear()`)
      // it is worth a line.
      const onNode = recv === null || recv === 'self' || /^[$%]/.test(recv);
      if (!onNode) continue;
      // With exactly one layer there is only one node the receiver can be, so the
      // rewrite is not a guess. With more than one, which layer `clear()` meant is
      // a question only the author can answer.
      const only = layerNames && layerNames.length === 1 ? layerTarget(layerNames, 0, recv) : null;
      if (only) {
        const after = `${only}.${name}(${args.join(', ')})`;
        pushLater({ ...at, kind: 'same-signature', auto: true, before, after,
          note: `same signature on TileMapLayer; the map had one layer, so the receiver is \`${layerNames[0]}\`.`,
          _edit: { start: callStart, end: close + 1, text: after } });
        continue;
      }
      pushLater({
        ...at, kind: 'same-signature', auto: false, before, after: null,
        note: 'same signature on TileMapLayer — only the receiver has to change, from the map to a layer node.',
      });
      continue;
    }

    if (entry.kind === 'enum') {
      strong = true;
      push({
        ...at, kind: 'enum-argument', auto: false, before, after: null,
        note: 'same arity, but the receiver has to become a layer node AND the value type is '
          + 'TileMapLayer.DebugVisibilityMode now — see the constant rename on the same line if '
          + 'there is one.',
      });
      continue;
    }

    if (entry.kind === 'drop') {
      // A call with no layer index to drop is either already ported or, far more
      // often, somebody else's method of the same name — `get_world_3d().get_navigation_map()`
      // is a World3D call, not a TileMap one. Same filter as the same-signature names.
      const onNode = recv === null || recv === 'self' || /^[$%]/.test(recv);
      if (!args.length) {
        if (!onNode) continue;
        pushLater({ ...at, kind: 'call-changed', auto: false, before, after: null,
          note: 'this method drops its leading `layer` argument on TileMapLayer, and this call has '
            + 'none to drop — either it is ported already or it is a method of the same name on '
            + 'something else.' });
        continue;
      }
      const layerArg = args[0];
      let rest = args.slice(1);
      const dropsProxies = entry.drop.includes('use_proxies') && args.length === entry.old;
      if (dropsProxies) {
        const proxies = rest.pop();
        if (/^true$/i.test(proxies)) {
          push({ ...at, kind: 'proxies-dropped', auto: false, before, after: null,
            note: 'this call passed `use_proxies = true`, and TileMapLayer has no such argument. '
              + 'If the project uses TileSet source/coords proxies, resolve them yourself before the call.' });
        }
      }
      const literal = /^-?\d+$/.test(layerArg) ? Number(layerArg) : null;
      if (literal !== null) strong = true;
      const target = literal === null ? null : layerTarget(layerNames, literal, recv);
      const call = `${name}(${rest.join(', ')})`;
      if (target) {
        const after = `${target}.${call}`;
        push({ ...at, kind: 'call-changed', auto: true, before, after,
          note: `layer ${literal} is the node \`${layerNames[literal]}\`; the index becomes the receiver.` },
          { start: callStart, end: close + 1, text: after });
      } else {
        const shown = literal === null
          ? `<the layer node for ${layerArg}>`
          : `<the node for layer ${literal}>`;
        const f = { ...at, kind: 'call-changed', auto: false, before, after: `${shown}.${call}`,
          note: literal === null
            ? 'the layer index is an expression, so which node this call means is decided at run time — '
              + 'pick the layer node the same way the expression picks the index. If this call is already '
              + 'ported, the first argument is the coordinate and there is nothing to do.'
            : 'convert the scene first (or pass the layer names) and this one becomes exact.' };
        if (literal === null) { if (onNode) pushLater(f); } else push(f);
      }
      continue;
    }

    // gone
    strong = true;
    const rep = GONE_REPLACEMENTS[name] || {};
    if (rep.perLayer && args.length) {
      const layerArg = args[0];
      const rest = args.slice(1);
      const literal = /^-?\d+$/.test(layerArg) ? Number(layerArg) : null;
      const target = literal === null ? null : layerTarget(layerNames, literal, recv);
      const shown = target || (literal === null ? `<the layer node for ${layerArg}>` : `<the node for layer ${literal}>`);
      const after = rep.call
        ? `${shown}.${rep.call}(${rest.join(', ')})`
        : rep.assign
          ? `${shown}.${rep.prop} = ${rest.join(', ')}`
          : `${shown}.${rep.prop}`;
      const auto = Boolean(target) && !rep.assign;   // an assignment is a statement, not an expression
      push({ ...at, kind: 'gone', auto, before, after,
        note: rep.assign
          ? `no such method on TileMapLayer; it is the \`${rep.prop}\` property of the layer node. `
            + 'Written out rather than applied, because a call becomes an assignment here.'
          : `no such method on TileMapLayer; ${rep.call ? `use \`${rep.call}()\`` : `read \`${rep.prop}\``} on the layer node.` },
        auto ? { start: callStart, end: close + 1, text: after } : null);
      continue;
    }
    push({ ...at, kind: 'gone', auto: false, before, after: null,
      note: rep.manual || 'no method of this name exists on TileMapLayer.' });
  }

  // Deferred findings only survive in a file that proved it talks to a TileMap;
  // the edits they carry are applied on the same condition.
  if (strong) {
    for (const f of deferred) {
      if (f._edit) { edits.push(f._edit); delete f._edit; }
      findings.push(f);
    }
  }
  findings.sort((a, b) => a.line - b.line || a.col - b.col);

  // Apply the safe edits back to front so earlier offsets stay valid.
  let rewritten = src;
  const applied = edits.slice().sort((a, b) => b.start - a.start);
  for (const e of applied) rewritten = rewritten.slice(0, e.start) + e.text + rewritten.slice(e.end);

  const counts = {};
  for (const f of findings) counts[f.kind] = (counts[f.kind] || 0) + 1;
  return {
    findings,
    rewritten,
    rewrites: edits.length,
    manual: findings.filter((f) => !f.auto).length,
    counts,
    layerNames,
  };
}

function formatReport(result, label) {
  const out = [];
  const head = label ? `${label}: ` : '';
  if (!result.findings.length) {
    out.push(`${head}nothing to port — no TileMap API in this script.`);
    return out.join('\n');
  }
  out.push(`${head}${result.findings.length} place${result.findings.length === 1 ? '' : 's'} to port `
    + `(${result.rewrites} rewritten here, ${result.manual} for you)`);
  for (const f of result.findings) {
    out.push(`  ${String(f.line).padStart(4)}:${f.col}  ${f.auto ? 'rewritten' : 'BY HAND '}  ${f.what}`);
    out.push(`        ${f.before.split('\n').join(' ')}`);
    if (f.after) out.push(`     -> ${f.after.split('\n').join(' ')}`);
    out.push(`        ${f.note}`);
  }
  return out.join('\n');
}

const API = {
  API_TABLE, GONE_REPLACEMENTS, ENUM_CONSTANTS, PROPERTY_RENAMES,
  maskLiterals, matchBracket, splitArgs, receiverBefore,
  scanScriptText, formatReport,
};

// Node (CLI + tests) and the browser (the page) load the same bytes.
if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.TileMapScriptScan = API;
