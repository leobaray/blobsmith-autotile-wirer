#!/usr/bin/env node
// Reads the GDScript that docs/convert_tilemap_to_tilemaplayer.js refuses to
// guess about, and says what the port is — call by call, with the layer index
// turned into the layer node the converter actually emits.
//
//   node docs/scan_tilemap_script.js res://player.gd
//   node docs/scan_tilemap_script.js scripts/ --layers=Ground,Walls
//   node docs/scan_tilemap_script.js path/to/project          # whole project
//   node docs/scan_tilemap_script.js player.gd --scene=level.tscn --write
//
// With a project directory or --scene, the layer names come from the scene
// itself: the converter is run on it to find out what each layer becomes, so
// `set_cell(0, ...)` is reported as `$Ground.set_cell(...)` and not as a shrug.
// Without a scene, --layers=A,B says it by hand; with neither, the findings still
// name every call and the shape of the fix.
//
// --write applies only the rewrites marked safe and leaves the rest alone. Exit
// code is 1 when anything still needs a human, so it drops into a build script.
//
// Zero dependencies, MIT, reads .gd and .tscn only.
'use strict';
const fs = require('fs');
const path = require('path');
const { scanScriptText, formatReport } = require('./tilemap-script-scan-core.js');
const CONVERT = require('./tilemap-convert-core.js');

const SKIP_DIRS = new Set(['.git', '.godot', '.import', 'node_modules', 'addons']);

function walk(dir, ext, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.') && e.name !== '.') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (!SKIP_DIRS.has(e.name)) walk(p, ext, out);
    } else if (e.name.toLowerCase().endsWith(ext)) out.push(p);
  }
  return out;
}

// The layer node names for every TileMap in a scene, keyed by node path.
//
// The converter refuses a TileMap that carries a script, and refusing is the
// whole point of it — but the names it WOULD have produced are exactly what this
// scanner needs. So the script line is dropped from a copy of the block and the
// real converter answers on that copy: the naming rule (blank -> LayerN, illegal
// characters replaced, collisions refused) is never re-implemented here.
function layerNamesFromScene(text) {
  const stripped = text.replace(/^script = .*$/gm, '');
  let report;
  try {
    report = CONVERT.convertSceneText(stripped, { label: 'scene' });
  } catch (_) {
    return new Map();
  }
  const out = new Map();
  for (const c of report.converted) out.set(c.node, c.layers.map((l) => l.name));
  return out;
}

// Which script each TileMap in a scene carries, as a res:// path.
function scriptsOfTileMaps(text) {
  const ext = new Map();
  const out = [];
  for (const s of CONVERT.splitSections(text)) {
    const a = CONVERT.parseAttrs(s.lines[0]);
    if (s.lines[0].startsWith('[ext_resource')) {
      if (a.id !== undefined && a.path) ext.set(String(a.id), a.path);
      continue;
    }
    if (!s.lines[0].startsWith('[node') || a.type !== 'TileMap') continue;
    const p = CONVERT.parseProps(s.lines.slice(1)).find((x) => x.key === 'script');
    if (!p) continue;
    const id = p.value.match(/ExtResource\(\s*"?([^")]+)"?\s*\)/);
    const nodePath = a.parent === undefined ? '.' : (a.parent === '.' ? a.name : `${a.parent}/${a.name}`);
    out.push({ node: nodePath, res: id ? ext.get(id[1]) : null });
  }
  return out;
}

// `res://` is relative to the directory holding project.godot, not to whatever
// directory the scan was pointed at. A folder of demos is a folder of PROJECTS,
// and resolving from the top silently found nothing for every one of them.
function projectRootOf(file, fallback) {
  let dir = path.dirname(path.resolve(file));
  for (;;) {
    if (fs.existsSync(path.join(dir, 'project.godot'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) return path.resolve(fallback);
    dir = up;
  }
}

function resToFile(res, projectDir) {
  if (!res || !res.startsWith('res://')) return null;
  const p = path.join(projectDir, res.slice('res://'.length));
  return fs.existsSync(p) ? p : null;
}

function main(argv) {
  const args = argv.filter((a) => !a.startsWith('--'));
  const flags = new Map(argv.filter((a) => a.startsWith('--')).map((a) => {
    const i = a.indexOf('=');
    return i === -1 ? [a.slice(2), true] : [a.slice(2, i), a.slice(i + 1)];
  }));
  if (!args.length || flags.has('help')) {
    console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(1, 20).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    process.exit(args.length ? 0 : 2);
  }
  const write = flags.has('write');
  const explicitLayers = typeof flags.get('layers') === 'string'
    ? String(flags.get('layers')).split(',').map((s) => s.trim()).filter(Boolean)
    : null;

  // target -> layer names, built from the scenes before any script is read.
  const jobs = new Map();   // file -> {layerNames, from}
  const addJob = (rawFile, layerNames, from) => {
    // Keyed by absolute path: a scene resolves its script through res:// and the
    // directory walk finds the same file relatively, and the two spellings landed
    // in the map as two jobs — the second one with no layer names.
    const file = path.resolve(rawFile);
    const prev = jobs.get(file);
    if (!prev) { jobs.set(file, { layerNames, from }); return; }
    if (!layerNames || !prev.layerNames) return;   // nothing new to say
    // One script on two TileMaps with different layer names cannot be rewritten
    // for both, so the names are dropped and the findings stay descriptive.
    if (JSON.stringify(prev.layerNames) !== JSON.stringify(layerNames)) {
      jobs.set(file, { layerNames: null, from: `${prev.from} + ${from} (they disagree)` });
    }
  };

  const sceneFlag = typeof flags.get('scene') === 'string' ? String(flags.get('scene')) : null;
  let sceneLayerNames = explicitLayers;
  if (sceneFlag) {
    const byNode = layerNamesFromScene(fs.readFileSync(sceneFlag, 'utf8'));
    const all = [...byNode.values()];
    if (all.length === 1) sceneLayerNames = all[0];
    else if (all.length > 1) console.error(`${sceneFlag}: ${all.length} TileMap nodes, so --scene cannot pick one; use --layers=`);
  }

  for (const target of args) {
    const st = fs.statSync(target);
    if (st.isDirectory()) {
      for (const scene of walk(target, '.tscn')) {
        const text = fs.readFileSync(scene, 'utf8');
        const names = layerNamesFromScene(text);
        const root = projectRootOf(scene, target);
        for (const { node, res } of scriptsOfTileMaps(text)) {
          const file = resToFile(res, root);
          if (file) addJob(file, names.get(node) || null, `${path.relative(target, scene)} ${node}`);
        }
      }
      for (const gd of walk(target, '.gd')) {
        if (!jobs.has(path.resolve(gd))) addJob(gd, explicitLayers, 'no scene found for it');
      }
    } else {
      addJob(target, sceneLayerNames, sceneFlag ? path.basename(sceneFlag) : (explicitLayers ? '--layers' : 'no scene given'));
    }
  }

  let files = 0, findings = 0, rewrites = 0, manual = 0;
  for (const [file, job] of [...jobs.entries()].sort()) {
    const src = fs.readFileSync(file, 'utf8');
    const r = scanScriptText(src, { layerNames: job.layerNames });
    if (!r.findings.length) continue;
    files++;
    findings += r.findings.length;
    rewrites += r.rewrites;
    manual += r.manual;
    console.log(formatReport(r, path.relative(process.cwd(), file) || file));
    console.log(`        layer names: ${job.layerNames ? job.layerNames.join(', ') : 'unknown'}  (${job.from})`);
    if (write && r.rewrites) {
      fs.writeFileSync(file, r.rewritten);
      console.log(`        wrote ${r.rewrites} rewrite${r.rewrites === 1 ? '' : 's'} to ${file}`);
    }
    console.log('');
  }

  if (!files) {
    console.log('no TileMap API in any script here.');
    process.exit(0);
  }
  console.log(`${files} script${files === 1 ? '' : 's'}, ${findings} place${findings === 1 ? '' : 's'} to port: `
    + `${rewrites} mechanical${write ? ' (written)' : ' (run again with --write)'}, ${manual} for a human.`);
  process.exit(manual ? 1 : 0);
}

main(process.argv.slice(2));
