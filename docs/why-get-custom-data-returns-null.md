# `get_custom_data` returns null (or the wrong value) — what the engine reads

You gave your tiles a custom data layer — `surface`, `damage`, `ladder` — and
the game reads `null`, `0`, or another layer's value. The editor shows the
right value on the tile.

Almost always the lookup is fine and it is asking a different cell, a different
name or a different type than you think. One case is an engine bug: reordering
layers from code leaves the name lookup pointing at the old positions.
This page measures each one. Every claim has an id (`D1`, `R1`, …) and is
asserted by [`verify_tile_custom_data.gd`](verify_tile_custom_data.gd) against a
real binary:

```
docs/verify_tile_custom_data.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, with the
physics claims run on real physics frames: 34 checks on 4.3, 35 on 4.4, 38 on
4.7 (some claims only exist on some versions), all passing, four of them
controls that fail if the check stops telling right from wrong. Last run **2026-09-14**. Needs 4.3
or newer — `TileMapLayer` does not exist in 4.2.

---

## The short answer: the tile under a character

```gdscript
# after move_and_slide():
for i in get_slide_collision_count():
	var col := get_slide_collision(i)
	var layer := col.get_collider() as TileMapLayer
	if layer == null:
		continue
	# step from the contact point INTO the tile, then ask for that cell
	var cell := layer.local_to_map(layer.to_local(col.get_position() - col.get_normal()))
	var td := layer.get_cell_tile_data(cell)
	if td:
		print(td.get_custom_data("surface"))
```

Two things this avoids:

**The cell at a character's feet is the empty one above the floor.** A
`CharacterBody2D` whose origin is at its feet does not rest on the floor's top
edge, it rests `safe_margin` (0.08 px) above it: measured `y = 31.987` on a
floor whose top is `y = 32` (`C3`). `local_to_map` of that point is the empty
cell above, `get_cell_tile_data()` is `null` (`C1`, `C3`), and one pixel lower
is the floor tile (`C4`). The edge itself belongs to the cell below: local
`y = 16.0` is row 1, `y = 15.99` is row 0 (`C2`). Nudging by a fixed pixel
works for flat floors only; the contact point minus the normal works for walls
and ceilings too (`C5`).

**`get_coords_for_body_rid()` changed meaning in 4.5.** Since 4.5 a
`TileMapLayer` merges its collision into one body per chunk
(`physics_quadrant_size`, default `16`, `Q1`). The function now returns the
**chunk index**, not the cell: `(0,0)` for a body standing on cell `(2,2)`
(`Q1`), `(1,0)` on cell `(17,2)` (`Q2`). On 4.3 and 4.4 the same call returns
`(2,2)` (`Q1`). Setting `physics_quadrant_size = 1` brings back the cell
(`Q3`) and gives up the merge. Upstream called this expected, see
[godotengine/godot#105489](https://github.com/godotengine/godot/issues/105489).
So on 4.5+ every "`get_coords_for_body_rid` + `get_cell_tile_data`" snippet
reads the tile at a chunk corner, which is usually empty or a different tile.
It says nothing, because `(0,0)` is a valid cell.

## `0`, `false` or `""` is not "not set"

A layer with a type returns that type's default on every tile you did not set
it on: `0`, `false`, `""` (`D1`), and so does a tile made before the layer
existed (`D3`). So `if td.get_custom_data("damage") == null` is never true for
an int layer, and a `0` is not proof the lookup worked.

A layer added without choosing a type is `TYPE_NIL` and reads `null` on every
tile, even though the layer exists (`D2`). In the TileSet inspector that is a
custom data layer whose type was left at `Nil`.

## Names: exact, and loud when wrong

- Case matters: `get_custom_data("HP")` on a layer named `hp` is `null` (`D4`).
- This one **is not silent**: a missing name prints
  `ERROR: TileSet has no layer with name: HP`, for `get_custom_data` and for
  `set_custom_data` (`E1`, with `K2` as the control that a correct name prints
  nothing). If you see `null` and no such error, the name is right and the
  problem is the cell or the type.
- `set_custom_data` on a missing name creates no layer (`D4`).
  `has_custom_data(name)` exists from 4.4 (`D4`); on 4.3 use
  `tile_set.get_custom_data_layer_by_name(name) != -1`.
- Renaming a layer keeps its values under the new name (`D6`).

## Types are not enforced on write

`set_custom_data("hp", "7")` on an `int` layer stores the String `"7"` (`D7`);
nothing converts it and nothing complains. Changing a layer's type afterwards
converts what it can and drops what it cannot: `int` → `String` turned `5` into
`null`, `float` → `int` turned `2.5` into `2` (`D8`). Changing a type in the
inspector on a TileSet already filled in is a way to lose values.

## Engine bug: reordering layers from code breaks lookup by name

Inserting a layer at a position, or moving one, shifts both the values and the
names, but not the name → index lookup:

| id | after | `get_custom_data("hp")` | `get_custom_data("ladder")` |
|----|-------|-----|-----|
| — | `hp = 5`, `ladder = true` | `5` | `true` |
| `R1` | `add_custom_data_layer(0)` | `null` (reads the new empty layer) | `5` (hp's value) |
| `R2` | `move_custom_data_layer(1, 0)` | `true` (ladder's value) | `5` (hp's value) |

`get_custom_data_layer_by_name()` still returns the old positions, and naming
the new layer does not refresh it (`R1`). `remove_custom_data_layer()` does
refresh it (`R3`, control). Reading by index —
`get_custom_data_by_layer_id()` — is right the whole time (`D5`, `R1`).

What fixes it: the name table is rebuilt when the TileSet is loaded. The same
TileSet saved and loaded again reads `hp = 5`, `ladder = true` (`R4`). So a game
that loads its `.tres` normally is not affected; a tool script, editor plugin
or procedural TileSet that inserts or moves layers and then reads by name in the
same session is. Workaround: add layers only at the end (`add_custom_data_layer()`
with no argument), or read by `get_custom_data_by_layer_id()` after a reorder.
Not measured: whether dragging layers in the TileSet inspector goes through the
same path.

## Checklist, in the order it usually goes wrong

1. Asking the cell at the character's feet → the empty cell above (`C3`); use
   contact point minus normal (`C5`).
2. `get_coords_for_body_rid` on 4.5+ → chunk index, not cell (`Q1`, `Q2`).
3. Layer type left at `Nil` → always `null` (`D2`).
4. Treating `0`/`false`/`""` as "not set" → it is the default (`D1`, `D3`).
5. Wrong case in the name → `null` plus an error in Output (`D4`, `E1`).
6. Wrong type written from code, or type changed later (`D7`, `D8`).
7. Layers inserted or moved from code, then read by name → another layer's
   value (`R1`, `R2`).

## What this file does not measure

- The legacy `TileMap` node.
- Scene tiles (`TileSetScenesCollectionSource`), which have no `TileData`.
- `Area2D` `body_shape_entered` with a `TileMapLayer`; the chunk change in
  `Q1` applies to it too per #105489, but this script only lands a
  `CharacterBody2D`.
- Per-cell data that differs between cells of the same tile — custom data
  lives on the tile, not the cell; see
  [why one cell changed every cell](why-one-cell-changed-every-cell.md).
