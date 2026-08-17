#!/usr/bin/env node
// Finds, in YOUR project, the things that put a seam between two tiles that touch.
//
//   node docs/find_tile_seam_causes.js /path/to/your/godot/project
//   node docs/find_tile_seam_causes.js /path/to/project --json
//
// Zero dependencies, reads only project.godot / *.tscn / *.tres, writes nothing,
// uploads nothing. Exit 1 if it found a cause, 0 if it found none.
//
// The rules themselves live in ./seam-scan-core.js, which has no filesystem in it
// so the identical bytes also run in the browser, on the page that offers this
// scanner to people without a terminal:
// https://blobsmith.lbwma.com/godot-tilemap-lines-between-tiles/
// This file is the part a web page cannot have: walking a directory.
//
// Every rule cites the claim id it comes from. The claims are not opinion: they
// are asserted against a real engine by docs/verify_tile_seams.gd, which runs
// headless in about a second (docs/verify_tile_seams.sh <godot-binary>) and prints
// the number it measured next to each one. If a rule here disagrees with your
// build, run that script on your build and the disagreement becomes a number
// instead of an argument.
//
// Full write-up: docs/why-tiles-have-seams.md
'use strict';
const fs = require('fs');
const path = require('path');
const SCAN = require('./seam-scan-core.js');

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

function checkProjectSettings(dir, findings) {
  const file = path.join(dir, 'project.godot');
  if (!fs.existsSync(file)) return false;
  findings.push(...SCAN.scanProjectGodot(fs.readFileSync(file, 'utf8')));
  return true;
}

function checkResources(dir, findings) {
  const files = walk(dir, ['.tres', '.tscn', '.res']);
  for (const full of files) {
    let text;
    try { text = fs.readFileSync(full, 'utf8'); } catch { continue; }
    findings.push(...SCAN.scanResource(text, path.relative(dir, full)));
  }
  return files.length;
}

function main() {
  const argv = process.argv.slice(2);
  const json = argv.includes('--json');
  const dir = argv.find((a) => !a.startsWith('--'));
  if (!dir) {
    console.log('usage: node find_tile_seam_causes.js <godot-project-dir> [--json]');
    process.exit(2);
  }
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
    console.error(`not a directory: ${dir}`);
    process.exit(2);
  }

  const findings = [];
  const hasProject = checkProjectSettings(dir, findings);
  const scanned = checkResources(dir, findings);
  const causes = findings.filter(SCAN.isCause);

  if (json) {
    console.log(JSON.stringify({ project: dir, hasProjectGodot: hasProject, scannedFiles: scanned, findings }, null, 2));
    process.exit(causes.length ? 1 : 0);
  }

  if (!hasProject) {
    console.log(`note: no project.godot in ${dir} — the four project-wide causes could not be checked.`);
  }
  for (const f of findings) {
    const mark = SCAN.isCause(f) ? '▲' : '·';
    console.log(`${mark} ${SCAN.line(f)}`);
    console.log(`    fix: ${f.fix}`);
    if (f.note) console.log(`    note: ${f.note}`);
  }
  const notes = findings.length - causes.length;
  if (!findings.length) {
    console.log(`✔ no seam cause found: project.godot plus ${scanned} scene/resource file(s) scanned.`);
    console.log(`  ${SCAN.ART_NOTE}`);
    process.exit(0);
  }
  console.log(`\n${causes.length} cause(s) and ${notes} note(s) in project.godot plus ${scanned} scene/resource file(s).`);
  console.log('Each id above (S5, S7, S11 …) is a claim measured on a real engine by docs/verify_tile_seams.gd.');
  process.exit(causes.length ? 1 : 0);
}

main();
