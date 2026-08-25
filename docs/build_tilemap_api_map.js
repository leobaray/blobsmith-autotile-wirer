#!/usr/bin/env node
// Turns the raw APIDUMP files written by docs/dump_tilemap_api.gd into
// docs/tilemap-api-map.json — the table docs/tilemap-script-scan-core.js scans
// with and docs/tilemap-to-tilemaplayer-script-api.md is written from.
//
//   node docs/build_tilemap_api_map.js dump-4.2.json ... > docs/tilemap-api-map.json
//
// Nothing here is typed from the online class reference. Every name, argument and
// type comes out of a Godot binary's own ClassDB; this file only classifies.
//
// No engine can produce the table alone: 4.2 is the last Godot that ships a full
// `TileMap` and the first with none is still in the future, so `TileMap` is read
// from the OLDEST dump and `TileMapLayer` from the NEWEST. Passing more versions
// widens the union and is how a method added in 4.4 gets into the table.
'use strict';
const fs = require('fs');

const sigOf = (m) => `${m.name}(${m.args.map((a) => `${a.name}: ${a.class || a.type}`).join(', ')}) -> ${m.ret_class || m.ret}`;
const argsEqual = (a, b) =>
  a.length === b.length && a.every((x, i) => x.name === b[i].name && (x.class || x.type) === (b[i].class || b[i].type));

// Same shape, minus the leading `layer: int` the multi-layer node needed.
const isLayerArg = (a) => a.name === 'layer' && a.type === 'int' && !a.class;
// `use_proxies` was a TileMap-only convenience; TileMapLayer resolves proxies itself.
const isProxiesArg = (a) => a.name === 'use_proxies' && a.type === 'bool';

function classify(oldM, newM) {
  if (!newM) return { kind: 'gone' };
  if (argsEqual(oldM.args, newM.args)) {
    return (oldM.ret_class || oldM.ret) === (newM.ret_class || newM.ret)
      ? { kind: 'same' }
      : { kind: 'return_changed' };
  }
  let args = oldM.args.slice();
  const dropped = [];
  if (args.length && isLayerArg(args[0])) { dropped.push(args[0].name); args = args.slice(1); }
  while (args.length && isProxiesArg(args[args.length - 1])) { dropped.push(args.pop().name); }
  if (argsEqual(args, newM.args)) return { kind: 'drop_args', dropped };
  return { kind: 'args_changed' };
}

// Compares the table the core carries against the one just rebuilt from the
// engines. The core has to embed its table — it runs in a browser with no
// filesystem — so this is what stops the two from drifting apart quietly.
function checkCore(map) {
  const { API_TABLE } = require('./tilemap-script-scan-core.js');
  const fresh = {};
  for (const m of map.methods) {
    fresh[m.name] = m.kind === 'drop_args' ? { kind: 'drop', drop: m.dropped, old: m.old, new: m.new }
      : m.kind === 'gone' ? { kind: 'gone', old: m.old }
      : m.kind === 'same' ? { kind: 'same', old: m.old, new: m.new }
      : { kind: 'enum', old: m.old, new: m.new };
  }
  let bad = 0;
  for (const name of new Set([...Object.keys(fresh), ...Object.keys(API_TABLE)])) {
    const a = JSON.stringify(fresh[name]), b = JSON.stringify(API_TABLE[name]);
    if (a === b) continue;
    bad++;
    console.log(`FAIL  ${name}\n        engines say ${a}\n        core says    ${b}`);
  }
  console.log(bad === 0
    ? `PASS  API_TABLE matches the engines, all ${Object.keys(fresh).length} methods`
    : `FAIL  ${bad} method(s) drifted`);
  return bad === 0;
}

function main(paths) {
  if (!paths.length) {
    console.error('usage: build_tilemap_api_map.js <APIDUMP json>... (oldest first)');
    process.exit(2);
  }
  const dumps = paths.map((p) => JSON.parse(fs.readFileSync(p, 'utf8')));
  const versions = dumps.map((d) => d.version);
  const withTileMap = dumps.filter((d) => d.classes.TileMap);
  const withLayer = dumps.filter((d) => d.classes.TileMapLayer);
  if (!withTileMap.length || !withLayer.length) {
    console.error('need at least one dump with TileMap and one with TileMapLayer');
    process.exit(2);
  }

  // Union across versions, first sighting wins, so a method added in 4.4 is in the
  // table and one that only 4.2 had would still be too.
  const union = (list, cls) => {
    const byName = new Map();
    for (const d of list) for (const m of d.classes[cls].methods) if (!byName.has(m.name)) byName.set(m.name, m);
    return byName;
  };
  const oldM = union(withTileMap, 'TileMap');
  const newM = union(withLayer, 'TileMapLayer');

  const methods = [];
  for (const name of [...oldM.keys()].sort()) {
    const o = oldM.get(name), n = newM.get(name);
    const c = classify(o, n);
    methods.push({
      name,
      tilemap: sigOf(o),
      tilemaplayer: n ? sigOf(n) : null,
      old: o.args.length,
      new: n ? n.args.length : null,
      ...c,
    });
  }
  const added = [...newM.keys()].sort().filter((n) => !oldM.has(n)).map((n) => ({ name: n, tilemaplayer: sigOf(newM.get(n)) }));

  const propNames = (list, cls) => {
    const seen = new Map();
    for (const d of list) for (const p of d.classes[cls].properties) if (!seen.has(p.name)) seen.set(p.name, p.type);
    return [...seen.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([name, type]) => ({ name, type }));
  };
  const constNames = (list, cls) => {
    const seen = new Map();
    for (const d of list) for (const c of d.classes[cls].constants) if (!seen.has(c.name)) seen.set(c.name, c);
    return [...seen.values()].sort((a, b) => (a.name < b.name ? -1 : 1));
  };

  const out = {
    generated_from: {
      versions,
      tilemap_read_from: withTileMap.map((d) => d.version),
      tilemaplayer_read_from: withLayer.map((d) => d.version),
      how: 'docs/dump_tilemap_api.gd (ClassDB) -> docs/build_tilemap_api_map.js',
    },
    counts: {
      tilemap_methods: methods.length,
      same: methods.filter((m) => m.kind === 'same').length,
      drop_args: methods.filter((m) => m.kind === 'drop_args').length,
      args_changed: methods.filter((m) => m.kind === 'args_changed').length,
      return_changed: methods.filter((m) => m.kind === 'return_changed').length,
      gone: methods.filter((m) => m.kind === 'gone').length,
      tilemaplayer_only: added.length,
    },
    methods,
    tilemaplayer_only: added,
    properties: {
      tilemap: propNames(withTileMap, 'TileMap'),
      tilemaplayer: propNames(withLayer, 'TileMapLayer'),
    },
    constants: {
      tilemap: constNames(withTileMap, 'TileMap'),
      tilemaplayer: constNames(withLayer, 'TileMapLayer'),
    },
    signals: {
      tilemap: withTileMap[0].classes.TileMap.signals,
      tilemaplayer: withLayer[withLayer.length - 1].classes.TileMapLayer.signals,
    },
  };
  if (check) {
    process.exit(checkCore(out) ? 0 : 1);
  }
  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
}

const argv = process.argv.slice(2);
const check = argv.includes('--check-core');
main(argv.filter((a) => !a.startsWith('--')));
