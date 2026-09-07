#!/usr/bin/env node
'use strict';
//
// Why can your agent not walk on the tiles you painted?
//
//   node docs/find_tile_navigation_gaps.js path/to/tileset.tres [more.tscn ...]
//   node docs/find_tile_navigation_gaps.js --json project/           (recurses)
//
// Exit code 1 if anything was found, 0 if none of the causes it can see are
// present. No dependencies, no Godot, no project import: it reads the text
// resources the editor already wrote, plus any .gd that asks for a path.
//
// It exists because "the agent does not move" has about eight causes and every
// answer online is an unordered list of all of them, with no way to tell which
// are even capable of producing what you are seeing. Five of the causes are in
// files you can read, and this names them with the id of the claim behind each.
//
// What it CANNOT see, stated so a clean result is not read as more than it is:
// the two things that most often decide whether an agent moves are not in any
// file. One is how long you waited before the first query -- and there is no
// number to give you, because the frame the map first answers on is not a
// constant of the engine OR of a build (measured 1 to 20 on the same 4.7
// binary, N10). The other is whether you looked at the LAST point of the path
// instead of its length, because a corridor blocked halfway comes back SHORTER,
// not empty (N23/N24). Both are asserted against real engines in
// docs/verify_tile_navigation.gd, run by docs/verify_tile_navigation.sh.
//
// The rules live in docs/nav-scan-core.js, with no filesystem in them, so this
// command and the node tests load the identical bytes.

const fs = require('fs');
const path = require('path');
const SCAN = require('./nav-scan-core.js');

const args = process.argv.slice(2);
const JSON_OUT = args.includes('--json');
const targets = args.filter((a) => !a.startsWith('--'));

if (!targets.length) {
  console.error('usage: node find_tile_navigation_gaps.js [--json] <file.tres|file.tscn|file.gd|dir> ...');
  process.exit(2);
}

function walk(p, out) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const e of fs.readdirSync(p)) {
      if (e === '.godot' || e === '.git' || e === 'node_modules') continue;
      walk(path.join(p, e), out);
    }
  } else if (/\.(tres|tscn|gd)$/i.test(p)) {
    out.push(p);
  }
  return out;
}

const files = [];
for (const t of targets) walk(t, files);

const all = [];
let resources = 0;
let scripts = 0;
for (const f of files) {
  let text;
  try {
    text = fs.readFileSync(f, 'utf8');
  } catch (e) {
    continue;
  }
  // A .gd is asked the script questions, a .tres/.tscn the resource ones. The
  // two rule sets are disjoint and reporting a file under the wrong one is how
  // a scanner invents findings.
  if (/\.gd$/i.test(f)) {
    const r = SCAN.scanScript(text, f);
    if (r.findings.length) scripts++;
    all.push(...r.findings);
  } else {
    const r = SCAN.scanResource(text, f);
    if (r.sawTileSet) resources++;
    all.push(...r.findings);
  }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ resources, scripts, findings: all }, null, 1));
} else {
  for (const f of all) {
    // The atlas id has to be printed: tile coordinates restart at 0:0 inside
    // every TileSetAtlasSource, so one file can report `0:0/0` more than once
    // and each is a different tile.
    const where = [f.source ? `[${f.source}]` : '', f.tile || '', f.line ? `line ${f.line}` : '']
      .filter(Boolean).join(' ');
    console.log(`${f.file}${where ? '  ' + where : ''}\n    ${f.id}: ${f.detail}`);
    if (f.fix) console.log(`    fix: ${f.fix}`);
  }
  console.log(`\n${files.length} file(s) read, ${resources} with a TileSet, ${all.length} finding(s)`);
  if (!all.length) console.log('\n' + SCAN.CLEAN_NOTE);
}
process.exit(all.length ? 1 : 0);
