#!/usr/bin/env node
// Finds, in YOUR project, the reasons a y-sorted TileMapLayer draws tiles in
// the wrong order.
//
//   node docs/find_y_sort_causes.js /path/to/your/godot/project
//   node docs/find_y_sort_causes.js /path/to/project --json
//
// Zero dependencies, reads only *.tscn / *.tres, writes nothing, uploads
// nothing. Exit 1 if it found a cause, 0 if it found none.
//
// The rules live in ./ysort-scan-core.js, which has no filesystem in it, so the
// identical bytes also run in the browser for people without a terminal.
// This file is the part a web page cannot have: walking a directory.
//
// Every rule cites the claim id it comes from, and those claims are not
// opinion — docs/verify_y_sort.sh <godot-binary> renders each scene and reads
// the contested pixel back, printing the measurement next to every id. If a
// rule here disagrees with your build, run that script on your build and the
// disagreement becomes a number instead of an argument.
//
// Full write-up: docs/why-y-sort-draws-the-wrong-order.md
'use strict';
const fs = require('fs');
const path = require('path');
const SCAN = require('./ysort-scan-core.js');

function walk(dir, exts, out = []) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return out; }
  for (const name of names) {
    if (name === '.git' || name === '.godot' || name === 'node_modules') continue;
    const full = path.join(dir, name);
    let st;
    try { st = fs.statSync(full); } catch { continue; }
    if (st.isDirectory()) walk(full, exts, out);
    else if (exts.includes(path.extname(name))) out.push(full);
  }
  return out;
}

function main() {
  const argv = process.argv.slice(2);
  const json = argv.includes('--json');
  const dir = argv.find((a) => !a.startsWith('--'));
  if (!dir) {
    console.log('usage: node find_y_sort_causes.js <godot-project-dir> [--json]');
    process.exit(2);
  }
  if (!fs.existsSync(dir)) {
    console.error(`no such directory: ${dir}`);
    process.exit(2);
  }

  const files = walk(dir, ['.tscn', '.tres']);
  const causes = [];
  for (const full of files) {
    let text;
    try { text = fs.readFileSync(full, 'utf8'); } catch { continue; }
    causes.push(...SCAN.scanResource(text, path.relative(dir, full) || path.basename(full)));
  }

  if (json) {
    console.log(JSON.stringify({ scanned: files.length, causes }, null, 2));
    process.exit(causes.length ? 1 : 0);
  }

  console.log(`read ${files.length} scene/resource file${files.length === 1 ? '' : 's'} under ${dir}`);
  if (!causes.length) {
    console.log('');
    console.log(SCAN.NO_CAUSE_NOTE);
    process.exit(0);
  }
  console.log('');
  for (const c of causes) {
    console.log(`${c.id}  ${c.claim}`);
    console.log(`    where: ${c.where}`);
    console.log(`    found: ${c.detail}`);
    console.log(`    fix:   ${c.fix}`);
    console.log('');
  }
  console.log(`${causes.length} cause${causes.length === 1 ? '' : 's'} found.`);
  process.exit(1);
}

main();
