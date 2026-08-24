# Godot 4: converting `TileMap` to `TileMapLayer` outside the editor

`TileMap` is deprecated since **Godot 4.3**. The editor grew a
**TileMap → TileMapLayer** extraction button, and if your project has three
scenes you should use it and stop reading here.

This page is about the other project: the one with forty levels, or the one that
does not open at all any more, or the one that lives on a build machine with no
display. That project needs the same edit applied to a lot of files, and the
edit is a text transform on a text file — which means it can be scripted, and,
more importantly, **checked**.

Two files do it:

```
docs/convert_tilemap_to_tilemaplayer.js   # the CLI, whole project in one pass
docs/tilemap-convert-core.js              # the rules, no filesystem in them
```

Zero dependencies, MIT, reads only `.tscn`, uploads nothing, and writes nothing
at all unless you pass `--write` — and even then it copies each file to
`<name>.tscn.bak` before touching it.

```
# see what would happen; writes nothing
node docs/convert_tilemap_to_tilemaplayer.js /path/to/project

# apply it
node docs/convert_tilemap_to_tilemaplayer.js /path/to/project --write

# one scene, machine-readable
node docs/convert_tilemap_to_tilemaplayer.js level.tscn --json
```

The same bytes run in a browser, for people without a terminal:
<https://blobsmith.lbwma.com/godot-tilemap-to-tilemaplayer/>

## What the conversion actually is

A `TileMap` holds every layer inside one node, as numbered properties. A
`TileMapLayer` **is** a layer, so each one has to leave the property list and
become a node:

```
[node name="TileMap" type="TileMap" parent="."]      [node name="TileMap" type="Node2D" parent="."]
tile_set = ExtResource("1")                 ->
format = 2                                           [node name="Ground" type="TileMapLayer" parent="TileMap"]
layer_0/name = "Ground"                              tile_set = ExtResource("1")
layer_0/tile_data = PackedInt32Array(...)            tile_map_data = PackedByteArray(...)
```

The wrapper stays a `Node2D` so the transform, the visibility, the groups and
anything else attached to the old node keep working, and so paths like
`$Level/TileMap` do not all break at once — `$Level/TileMap/Ground` is one
segment longer, not somewhere else entirely.

### The cell data is re-encoded, not copied

The two on-disk shapes are different bytes:

| | legacy `layer_N/tile_data` | new `tile_map_data` |
|---|---|---|
| container | `PackedInt32Array` | `PackedByteArray` |
| header | none | 2 bytes, format version (only `0` exists) |
| per cell | 3 × int32 = 12 bytes | 12 bytes |
| coordinates | `(y << 16) \| (x & 0xffff)`, two int16 | two int16, little-endian |
| source / atlas / alternative | packed into the other two words | four uint16 |

Field by field, both formats are written out in
[`tile-map-data-format.md`](tile-map-data-format.md), which was measured against
a real engine by [`verify_tile_map_data.gd`](verify_tile_map_data.gd).

### Erased cells disappear, and your file gets smaller

`erase_cell()` does not remove the record. It writes a tombstone — a cell whose
source id is `0xffff`, the engine's "no source" — and Godot keeps it in the
file. Carrying those across would be copying a no-op, so the converted layer
drops them and the report says how many. The cells the engine reads back are
identical either way; that is asserted, not assumed (see the checks below).

### The property table

Measured, not remembered: [`verify_tilemap_convert.gd`](verify_tilemap_convert.gd)
prints the `TileMap` property list of the engine it is run against and **fails if
this table does not cover it**, so a Godot release that adds a per-layer property
turns into a red test instead of a silently dropped value.

| on `TileMap` | on the converted node | note |
|---|---|---|
| `layer_N/name` | the node's name | blank → `LayerN`; `. : @ % / "` replaced |
| `layer_N/enabled` | `enabled` | |
| `layer_N/modulate` | `modulate` | |
| `layer_N/y_sort_enabled` | `y_sort_enabled` | |
| `layer_N/y_sort_origin` | `y_sort_origin` | |
| `layer_N/z_index` | `z_index` | |
| `layer_N/navigation_enabled` | `navigation_enabled` | |
| `layer_N/tile_data` | `tile_map_data` | re-encoded |
| `tile_set` | `tile_set` on **every** layer | a `Node2D` cannot hold it |
| `rendering_quadrant_size` | same, every layer | |
| `collision_visibility_mode` | same, every layer | |
| `navigation_visibility_mode` | same, every layer | |
| `collision_animatable` | `use_kinematic_bodies` | renamed by the engine in 4.3 |
| `format` | dropped | the `TileMap`'s own on-disk version counter |
| everything else | untouched | transform, visibility, material, groups, other nodes |

## What it refuses, on purpose

A converter that half-understands a scene and rewrites it anyway corrupts a
project quietly, and you find out three weeks later. Each of these stops that
node, prints why, and leaves the file exactly as it was:

- **a `script` on the node** — a script that `extends TileMap` cannot extend the
  `Node2D` the node becomes. Port it to `TileMapLayer` first. This is the one
  case where a human has to decide something, and it is not rare (see below);
- **an unknown `layer_N/` key** — anything outside the table above would be
  silently dropped;
- **`format` other than `2`** — only the value this has been checked against is
  accepted. Open the scene once in a 4.2–4.4 editor to let the engine upgrade
  it, then convert;
- **a layer name that is already a sibling's name**, or **two layers with the
  same name** — Godot allows both on a `TileMap` and neither on a node tree.
  You rename one; the tool will not pick for you;
- **`layer_N/` overrides on a node with no `type`** — the scene inherits or
  instances another one and the real `TileMap` is in that other file. Convert
  the base scene first, then re-check this one by hand;
- **a `tile_data` that is not a whole number of 3-int cells.**

And one gate that runs on every scene, clean or not: after the rewrite, the
converter checks that **every block it does not own is still present, character
for character**. If one untouched node came back different, nothing is written.
`--write` on a project where any node was refused still converts the rest and
exits `1`, so it drops into a build script.

## What it does not do

- **It does not touch `.gd` files.** `$TileMap.set_cell(0, pos, ...)` has to
  become `$TileMap/Ground.set_cell(pos, ...)` — the layer index argument is gone,
  because the node *is* the layer. Rewriting code that merely looks like a tile
  call is exactly the kind of guess this tool refuses to make elsewhere.
- **It does not open your project or your `.tres` files.** Only `.tscn`.
- **It does not read binary `.scn`.** Re-save as text first.
- **It does not renumber or reorder anything else** in the file.

## What was measured

### The engine reads both versions back, cell by cell

[`verify_tilemap_convert.sh`](verify_tilemap_convert.sh) writes a legacy scene
with a real Godot, converts a copy of it on the command line, and makes a real
Godot read **both** back: coordinates, source id, atlas coordinates, alternative
id, cell counts with and without tombstones, and each per-layer property against
the engine's own property list.

```
docs/verify_tilemap_convert.sh godot-4.2 godot-4.3 godot-4.4 godot-4.7
```

Run on 2026-08-24 against the four official Linux builds:

```
### same-version pass — 4.3.stable.official.77dcf97d8    160 checks, 0 failed   ALL PASS
### same-version pass — 4.4.stable.official.4c311cbee    160 checks, 0 failed   ALL PASS
### same-version pass — 4.7.stable.official.5b4e0cb0f    160 checks, 0 failed   ALL PASS
### cross-version pass — written by 4.2.stable.official.46dc27791,
###   converted on the command line, read back by 4.7.stable.official.5b4e0cb0f
                                                        160 checks, 0 failed   ALL PASS
TILEMAP CONVERT: every pass green
```

**640 assertions.** The last pass is the one that matters: **4.2 is the last
Godot before `TileMapLayer` existed**, and a project that never saw 4.3 is
exactly the project this tool is for. A fixture written by a modern engine would
quietly assume the file on disk already looks modern.

A pass counts as green only if the engine **printed** the line saying so. That is
not pedantry: Godot 4.2 exits `0` after a GDScript parse error, and the first
version of the runner reported a clean green for a pass in which not one check
had run.

### Godot's own demo projects

Run over
[`godotengine/godot-demo-projects` at branch `4.2`](https://github.com/godotengine/godot-demo-projects/tree/4.2)
— 298 scene files, nobody's code but Godot's:

| | |
|---|---|
| `.tscn` scanned | 298 |
| `TileMap` nodes found | 17 |
| converted in one pass | **14** — 13 layers, **3 427 cells** |
| refused | **3**, every one of them carrying a script |
| notes | 14 — 12 blank layer names renamed to `Layer0`, 1 `TileMap` with no layer data |

The interesting number is the **3**: `2d/dynamic_tilemap_layers`,
`2d/navigation_astar`, and the `Grid` node of `2d/role_playing_game`. Roughly one
real-world `TileMap` in six carries a script, and there is no automatic answer
for a script that extends a node which is about to stop being that node. A tool
that claimed to handle everything would have rewritten those three into a broken
scene tree.

The same corpus at `master`: 396 scenes, **zero** `TileMap` nodes left. The demos
have finished this migration — which is why the measurement uses the 4.2 branch,
the state the projects that still need it are actually in.

### The refusals themselves

The engine can judge the happy path but it cannot judge a refusal, so those are
asserted in `test/tilemap-convert.test.js` (21 checks) — every one a case where
the converter must stop and leave the bytes alone — and the browser page is
compared against the CLI output on a real demo scene in
`test/web-tilemap-convert.test.js` (16 checks).

## After you convert

1. **Open the project in Godot 4.3+ and save once.** The scenes are valid text
   already; saving lets the engine write its own `uid` bookkeeping.
2. **Fix the code that talked to the `TileMap`** — the layer index argument is
   gone from `set_cell` / `get_cell_*`.
3. **Check the draw order.** Layers used to be ordered by index inside one node
   and are now siblings, ordered by tree position. The converter emits them in
   layer order, which preserves it — but per-layer `z_index` or y-sort tricks are
   worth a look: [why y-sorted tiles still draw in the wrong
   order](why-y-sort-draws-the-wrong-order.md).

---

Part of [Blobsmith Autotile Wirer](https://github.com/leobaray/blobsmith-autotile-wirer)
(MIT). The plugin itself wires an already-drawn 47-blob sheet into a `TileSet`
with the terrain bits set; [Blobsmith](https://blobsmith.itch.io/blobsmith) is the
pixel-art tool that draws the sheet from 6 tiles. Neither is needed to run
anything on this page.
