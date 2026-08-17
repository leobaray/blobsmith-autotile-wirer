#!/usr/bin/env node
// Finds, in YOUR project, the things that put a seam between two tiles that touch.
//
//   node docs/find_tile_seam_causes.js /path/to/your/godot/project
//   node docs/find_tile_seam_causes.js /path/to/project --json
//
// Zero dependencies, reads only project.godot / *.tscn / *.tres, writes nothing,
// uploads nothing. Exit 1 if it found a cause, 0 if it found none.
//
// Every rule below cites the claim id it comes from. The claims are not opinion:
// they are asserted against a real engine by docs/verify_tile_seams.gd, which
// runs headless in about a second (docs/verify_tile_seams.sh <godot-binary>) and
// prints the number it measured next to each one. If a rule here disagrees with
// your build, run that script on your build and the disagreement becomes a
// number instead of an argument.
//
// Full write-up: docs/why-tiles-have-seams.md
'use strict';
const fs = require('fs');
const path = require('path');

// --- project.godot ------------------------------------------------------------
// A Godot .godot/.tscn/.tres file is INI-ish: `[section]` headers, then `key=value`
// lines. In project.godot the section name is joined to the key with a `/`, so
// `[rendering]` + `textures/canvas_textures/default_texture_filter` is the setting
// the docs call rendering/textures/canvas_textures/default_texture_filter.
function parseGodotIni(text) {
  const out = {};
  let section = '';
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith(';')) continue;
    const head = line.match(/^\[([^\]\s]+)/);
    if (head) { section = head[1]; continue; }
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    out[section ? `${section}/${key}` : key] = value;
  }
  return out;
}

const unquote = (v) => (typeof v === 'string' ? v.replace(/^"(.*)"$/, '$1') : v);

// --- scene / resource blocks --------------------------------------------------
// Returns [{ header, type, name, props: {k: v}, line }] — one entry per `[...]`
// block, with the plain `key = value` lines that follow it.
function parseBlocks(text) {
  const lines = text.split(/\r?\n/);
  const blocks = [];
  let cur = null;
  lines.forEach((raw, i) => {
    const line = raw.trim();
    if (line.startsWith('[')) {
      cur = {
        header: line,
        type: (line.match(/type="([^"]+)"/) || [])[1] || '',
        name: (line.match(/name="([^"]+)"/) || [])[1] || '',
        props: {},
        line: i + 1,
      };
      blocks.push(cur);
      return;
    }
    if (!cur) return;
    const eq = line.indexOf('=');
    if (eq < 0 || !/^[A-Za-z_]/.test(line)) return;
    cur.props[line.slice(0, eq).trim()] = { value: line.slice(eq + 1).trim(), line: i + 1 };
  });
  return blocks;
}

const vec = (v) => {
  const m = String(v).match(/Vector2i?\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)/);
  return m ? [parseFloat(m[1]), parseFloat(m[2])] : null;
};

// The two enums that use the same integers for different filters (S8).
const PROJECT_FILTER = ['Nearest', 'Linear', 'Linear Mipmap', 'Nearest Mipmap'];
const NODE_FILTER = ['Inherit (parent/project)', 'Nearest', 'Linear', 'Nearest Mipmap', 'Linear Mipmap'];

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
  const s = parseGodotIni(fs.readFileSync(file, 'utf8'));

  // S7: the shipped default of this setting is 1 = Linear, so a project that
  // never wrote the line is filtering every canvas texture with blending.
  const rawFilter = s['rendering/textures/canvas_textures/default_texture_filter'];
  const filter = rawFilter === undefined ? 1 : parseInt(rawFilter, 10);
  if (filter !== 0) {
    findings.push({
      rule: 'project-filter-not-nearest',
      claim: 'S7',
      severity: 'cause',
      file: 'project.godot',
      line: 0,
      detail: `default_texture_filter is ${filter} (${PROJECT_FILTER[filter] || '?'})`
        + (rawFilter === undefined ? ' — the line is absent, so this is the shipped default' : ''),
      fix: 'Project Settings → Rendering → Textures → Canvas Textures → Default Texture Filter = Nearest'
        + ' (writes `textures/canvas_textures/default_texture_filter=0`).',
      note: 'If your tiles are hand-drawn at display resolution rather than pixel art, Linear is a legitimate choice'
        + ' and the seam is more likely to be the stretch mode below.',
    });
  }

  // S5: both snap settings ship off, and they are two settings, not one.
  for (const key of ['2d/snap/snap_2d_transforms_to_pixel', '2d/snap/snap_2d_vertices_to_pixel']) {
    const v = s[`rendering/${key}`];
    if (v !== 'true') {
      findings.push({
        rule: 'snap-off',
        claim: 'S5',
        severity: 'cause',
        file: 'project.godot',
        line: 0,
        detail: `rendering/${key} is ${v === undefined ? 'absent (ships false)' : v}`,
        fix: `Project Settings → Rendering → 2D → Snap → set both snap-to-pixel boxes (writes \`${key}=true\`).`,
      });
    }
  }

  // S19/S20: scale_mode only bites once stretching is on, so report it honestly.
  const stretch = unquote(s['display/window/stretch/mode']) || 'disabled';
  const scale = unquote(s['display/window/stretch/scale_mode']) || 'fractional';
  if (scale !== 'integer') {
    findings.push({
      rule: stretch === 'disabled' ? 'fractional-scale-inactive' : 'fractional-scale',
      claim: 'S20',
      severity: stretch === 'disabled' ? 'note' : 'cause',
      file: 'project.godot',
      line: 0,
      detail: `stretch/mode=${stretch}, stretch/scale_mode=${scale}`
        + (stretch === 'disabled'
          ? ' — stretching is off, so scale_mode is not what is opening your seam today'
          : ' — the viewport is scaled by a fractional factor, so a tile edge can land between two screen pixels'),
      fix: 'Project Settings → Display → Window → Stretch → Scale Mode = integer (with Mode = canvas_items or viewport).',
    });
  }
  return true;
}

function checkResources(dir, findings) {
  const files = walk(dir, ['.tres', '.tscn', '.res']);
  for (const full of files) {
    const rel = path.relative(dir, full);
    let blocks;
    try { blocks = parseBlocks(fs.readFileSync(full, 'utf8')); } catch { continue; }
    for (const b of blocks) {
      // ---- atlas sources: the gutter the engine builds, and the one you cut ----
      if (b.type === 'TileSetAtlasSource') {
        const pad = b.props['use_texture_padding'];
        if (pad && pad.value === 'false') {
          findings.push({
            rule: 'atlas-padding-off',
            claim: 'S11/S15',
            severity: 'cause',
            file: rel,
            line: pad.line,
            detail: 'use_texture_padding = false — the one-texel guard Godot 4 builds around every tile is switched off',
            fix: 'Remove the line (or tick Use Texture Padding on the atlas source). With it on, the runtime atlas'
              + ' spaces 16px tiles 18px apart (S12/S13) so a blended sample cannot reach the neighbouring tile.',
          });
        }
        for (const key of ['margins', 'separation']) {
          const p = b.props[key];
          const v = p && vec(p.value);
          if (v && (v[0] || v[1])) {
            findings.push({
              rule: 'hand-cut-gutter',
              claim: 'S17/S18',
              severity: 'note',
              file: rel,
              line: p.line,
              detail: `${key} = (${v[0]}, ${v[1]}) — this sheet was cut with a hand-made gutter`,
              fix: 'Not a bug, but usually not needed on Godot 4: use_texture_padding already pads at runtime (S11),'
                + ' while a hand gutter costs grid cells — a 64x64 sheet holds 4x4 tiles without one and 3x3 with it (S18).',
            });
          }
        }
      }
      // ---- nodes that override the filter locally ----
      const isTileNode = /^TileMap(Layer)?$/.test(b.type);
      const tf = b.props['texture_filter'];
      if (tf) {
        const n = parseInt(tf.value, 10);
        if (n === 2 || n === 4) {
          findings.push({
            rule: 'node-filter-linear',
            claim: 'S8/S9',
            severity: 'cause',
            file: rel,
            line: tf.line,
            detail: `${b.type || 'node'} "${b.name}" sets texture_filter = ${n} (${NODE_FILTER[n] || '?'})`
              + ' — a node override beats the project setting',
            fix: 'Set it back to Inherit (0) once the project default is Nearest, or to Nearest (1) here.'
              + ' Careful: on a NODE, 1 means Nearest; in the PROJECT setting, 1 means Linear (S8).',
          });
        } else if (n === 1 && !isTileNode) {
          // harmless, and worth saying so rather than staying silent about a hit
        }
      }
      // ---- cameras that land on a fraction of a pixel ----
      if (b.type === 'Camera2D') {
        const z = b.props['zoom'] && vec(b.props['zoom'].value);
        if (z && (!Number.isInteger(z[0]) || !Number.isInteger(z[1]))) {
          findings.push({
            rule: 'camera-fractional-zoom',
            claim: 'S25',
            severity: 'cause',
            file: rel,
            line: b.props['zoom'].line,
            detail: `Camera2D "${b.name}" has zoom = (${z[0]}, ${z[1]}) — one source texel maps to a fractional number of screen pixels`,
            fix: 'Use a whole-number zoom, or keep zoom at 1 and scale the whole viewport with an integer stretch instead.'
              + ' Nothing on Camera2D rounds its own position for you (S24).',
          });
        }
      }
    }
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
  const causes = findings.filter((f) => f.severity === 'cause');

  if (json) {
    console.log(JSON.stringify({ project: dir, hasProjectGodot: hasProject, scannedFiles: scanned, findings }, null, 2));
    process.exit(causes.length ? 1 : 0);
  }

  if (!hasProject) {
    console.log(`note: no project.godot in ${dir} — the four project-wide causes could not be checked.`);
  }
  for (const f of findings) {
    const mark = f.severity === 'cause' ? '▲' : '·';
    console.log(`${mark} [${f.rule}] ${f.file}${f.line ? ':' + f.line : ''} (${f.claim}) — ${f.detail}`);
    console.log(`    fix: ${f.fix}`);
    if (f.note) console.log(`    note: ${f.note}`);
  }
  const notes = findings.length - causes.length;
  if (!findings.length) {
    console.log(`✔ no seam cause found: project.godot plus ${scanned} scene/resource file(s) scanned.`);
    console.log('  If you still see a line between two tiles, it is in the art, not the setup —'
      + ' check that the tile occupies its whole cell in the source PNG.');
    process.exit(0);
  }
  console.log(`\n${causes.length} cause(s) and ${notes} note(s) in project.godot plus ${scanned} scene/resource file(s).`);
  console.log('Each id above (S5, S7, S11 …) is a claim measured on a real engine by docs/verify_tile_seams.gd.');
  process.exit(causes.length ? 1 : 0);
}

main();
