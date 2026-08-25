#!/usr/bin/env node
// Converts the deprecated `TileMap` nodes in YOUR project into the `TileMapLayer`
// nodes Godot 4.3+ wants — every scene in one pass, without opening the editor.
//
//   node docs/convert_tilemap_to_tilemaplayer.js /path/to/your/godot/project
//   node docs/convert_tilemap_to_tilemaplayer.js /path/to/project --write
//   node docs/convert_tilemap_to_tilemaplayer.js scene.tscn --json
//
// Zero dependencies. Reads only *.tscn. Writes nothing at all unless you pass
// --write, and even then it writes a `.tscn.bak` next to every file it changes
// first. Uploads nothing.
//
// Why this exists when the editor has a button: the editor's extraction is one
// scene at a time, by hand, and only on scenes it can open. A project with 40
// scenes is 40 manual passes; a project that will not open — missing plugin,
// missing dependency, a build box with no display — has no path at all. This is
// the same job as a text transform, which is also why it can be checked: run it,
// then let the engine read the before and the after cell by cell
// (docs/verify_tilemap_convert.gd).
//
// The rules live in ./tilemap-convert-core.js, which has no filesystem in it so
// the identical bytes also run in the browser, for people without a terminal:
// https://blobsmith.lbwma.com/godot-tilemap-to-tilemaplayer/
//
// Write-up, including everything this does NOT do: docs/converting-tilemap-to-tilemaplayer.md
'use strict';
const fs = require('fs');
const path = require('path');
const CONVERT = require('./tilemap-convert-core.js');

function walk(dir, out = []) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return out; }
  for (const name of names) {
    if (name === '.git' || name === '.godot' || name === 'node_modules') continue;
    const full = path.join(dir, name);
    let st;
    try { st = fs.statSync(full); } catch { continue; }
    if (st.isDirectory()) walk(full, out);
    else if (path.extname(name) === '.tscn') out.push(full);
  }
  return out;
}

function main(argv) {
  const args = argv.slice(2);
  const write = args.includes('--write');
  const json = args.includes('--json');
  // Only for a project whose scripts have already been ported — see
  // docs/scan_tilemap_script.js, which does the porting and says what is left.
  const keepScripts = args.includes('--script-ported');
  const target = args.find((a) => !a.startsWith('--'));
  if (!target) {
    console.error('usage: node docs/convert_tilemap_to_tilemaplayer.js <project-dir|scene.tscn> '
      + '[--write] [--json] [--script-ported]');
    return 2;
  }
  let files;
  try {
    files = fs.statSync(target).isDirectory() ? walk(target) : [target];
  } catch (e) {
    console.error(`cannot read ${target}: ${e.message}`);
    return 2;
  }

  const report = { scanned: files.length, converted: [], blocked: [], notes: [], written: [] };

  for (const file of files) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (e) {
      report.blocked.push({ file, node: '-', reason: `cannot read: ${e.message}` });
      continue;
    }
    if (!text.includes('type="TileMap"') && !/^layer_\d+\//m.test(text)) continue;

    let result;
    try {
      result = CONVERT.convertSceneText(text, { label: file, keepScripts });
    } catch (e) {
      report.blocked.push({ file, node: '-', reason: `converter error: ${e.message}` });
      continue;
    }
    for (const b of result.blockers) report.blocked.push({ file, ...b });
    for (const n of result.notes) report.notes.push({ file, ...n });
    if (!result.changed) continue;

    // Nothing is written before the rewrite proves it only touched the TileMap
    // blocks it reported. A converter that quietly reflows the rest of the file
    // would be worse than no converter.
    const paths = result.converted.map((c) => c.node);
    const survived = CONVERT.untouchedSectionsSurvive(text, result.text, paths);
    if (!survived.ok) {
      report.blocked.push({
        file, node: '-',
        reason: `refused: the rewrite would have altered ${survived.missing.length} block(s) it does `
          + 'not own. Nothing was written. Please open an issue with this scene.',
      });
      continue;
    }
    for (const c of result.converted) report.converted.push({ file, ...c });
    if (write) {
      fs.copyFileSync(file, `${file}.bak`);
      fs.writeFileSync(file, result.text);
      report.written.push(file);
    }
  }

  if (json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    const cells = report.converted.reduce(
      (a, c) => a + c.layers.reduce((b, l) => b + l.cells, 0), 0);
    const tombs = report.converted.reduce(
      (a, c) => a + c.layers.reduce((b, l) => b + l.tombstones, 0), 0);
    console.log(`scanned ${report.scanned} .tscn file(s)`);
    for (const c of report.converted) {
      console.log(`\n${c.file}:${c.line}  ${c.node}  ->  Node2D + ${c.layers.length} TileMapLayer`);
      for (const l of c.layers) {
        console.log(`    ${l.name}: ${l.cells} cell(s)`
          + (l.tombstones ? `, ${l.tombstones} erased-cell record(s) dropped` : ''));
      }
    }
    for (const n of report.notes) console.log(`\nnote  ${n.file}:${n.line}  ${n.note}`);
    for (const b of report.blocked) console.log(`\nBLOCKED  ${b.file}:${b.line || '?'}  ${b.node}\n    ${b.reason}`);
    console.log(`\n${report.converted.length} TileMap node(s), ${cells} cell(s)`
      + (tombs ? `, ${tombs} erased-cell record(s) dropped` : '')
      + `, ${report.blocked.length} blocked`);
    if (write) {
      console.log(`WROTE ${report.written.length} file(s); the originals are next to them as .tscn.bak`);
    } else if (report.converted.length) {
      console.log('Nothing was written. Re-run with --write to apply, then open the project in Godot.');
    }
  }

  if (report.blocked.length) return 1;
  return 0;
}

if (require.main === module) process.exit(main(process.argv));
module.exports = { main, walk };
