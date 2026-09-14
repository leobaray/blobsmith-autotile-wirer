# `set_cell` ran and nothing appeared — what the engine stores instead

You call `set_cell()` from code and the tile does not show up. No error in the
Output panel, no crash, the game keeps running. Sometimes the cell even shows
up in `get_used_cells()`, which makes it look like the map has the tile and the
renderer lost it.

It did not lose it. `set_cell()` writes whatever ids you give it, and a cell
whose ids point at no tile is drawn as nothing, without an error.
This page measures each way that happens. Every claim has an id (`S3`, `K1`, …)
and is asserted by [`verify_set_cell.gd`](verify_set_cell.gd) against a real
binary, with "draws nothing" read back from rendered pixels:

```
docs/verify_set_cell.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 30
checks, 30/30 on each, two of them controls that fail if the check stops
telling right from wrong. Last run **2026-09-13**. Needs 4.3 or newer —
`TileMapLayer` does not exist in 4.2. The script needs `xvfb-run`, because the
headless renderer returns no pixels.

---

## The short answer

```gdscript
# all three ids, and check them before you blame the renderer:
layer.set_cell(cell, source_id, atlas_coords, alternative)

var td := layer.get_cell_tile_data(cell)
if td == null:
	push_warning("cell %s points at no tile: source %d, atlas %s, alt %d" % [
		cell, layer.get_cell_source_id(cell),
		layer.get_cell_atlas_coords(cell), layer.get_cell_alternative_tile(cell)])
```

`get_cell_tile_data()` is the only call on this page that notices: it returns
`null` and prints the engine error. `set_cell()` and drawing the cell print
nothing (`E1`, with `K2` as the control that the error is visible when printed).

## You erased it: the default arguments

`set_cell(coords, source_id := -1, atlas_coords := Vector2i(-1, -1), alternative_tile := 0)`.
The defaults are the erase values.

| id | call | result |
|----|------|--------|
| `S1` | `set_cell(cell)` | source id `-1`, gone from `get_used_cells()`, nothing drawn |
| `S2` | `set_cell(cell, 0)` | also erased: atlas coords default to `(-1,-1)` |

So a call that "sets tile 0" without the atlas coordinates is an
`erase_cell()`. There is no such thing as a default tile.

## The cell is stored even when no tile exists

When the ids are wrong but not the erase values, the cell is kept exactly as
written — it is in `get_used_cells()`, `get_cell_source_id()` returns your
number — and it draws nothing.

| id | what is wrong | stored as | drawn |
|----|---------------|-----------|-------|
| `S3` | atlas coords `(1,0)` where no tile was created | source `0`, atlas `(1,0)` | nothing |
| `S4` | source id `5`, no such source | source `5` | nothing |
| `S5` | alternative `3`, no such alternative | alternative `3` | nothing |

That is why "the cell is in `get_used_cells()`" proves nothing about whether a
tile is there. A texture with tiles painted on it is not an atlas with tiles in
it: in the editor, the tiles exist only after you create them in the TileSet
panel (or the automatic "create tiles in non-transparent areas" prompt). In
code, every coordinate needs `create_tile()`.

Because the cell keeps its ids, fixing the `TileSet` fixes the map without
touching it: `create_tile((0,1))` after the `set_cell` makes the same cell draw
(`S6`). The same goes for a layer that had no `tile_set` when you filled it — the
cells are kept and draw as soon as one is assigned (`S7`). Order of setup is not
the bug; the ids are.

## Source ids are not positions

`TileSet.add_source()` hands out ids, and it does not reuse them. Remove the
only source and add one back, and the new one is `1` with a source count of `1`
(`S8`). Every `set_cell(cell, 0, ...)` in your code now draws nothing.

Deleting and re-adding an atlas in the TileSet editor does the same. Look the
id up instead of writing `0`:

```gdscript
var source_id := layer.tile_set.get_source_id(0)  # first source, whatever its id
```

(`S8`: `get_source_id(0)` returns `1` and that cell draws.)

## Big tiles are addressed by their origin

A tile that covers 2×2 atlas cells exists only at its top-left coordinate.
`set_cell(cell, 0, Vector2i(1,1))` on one draws nothing, even though `(1,1)` is
inside it (`S9`). `get_tile_at_coords((1,1))` returns the origin `(0,0)`; pass
that.

## `create_tile` can fail without your code knowing

`create_tile()` returns nothing. When the tile would not fit it prints an error
and creates nothing, so the `set_cell` that follows points at no tile:

- a coordinate outside the texture — `(3,0)` on a 32 px texture with 16 px
  regions (`S10`);
- **any** coordinate on an atlas whose `texture` is not set yet (`S10`). Assign
  the texture and `texture_region_size` first, then create tiles.

Check `has_tile()` after creating if the atlas is built from code.

## The layer is switched off

`enabled = false` keeps every cell and draws none (`S11`). It is a separate
property from `visible`, so a layer can be visible in the inspector and still
draw nothing.

## Checklist, in the order it usually goes wrong

1. Fewer than three arguments to `set_cell` → erased (`S1`, `S2`).
2. Atlas coordinate that was never created as a tile → stored, not drawn (`S3`, `S6`).
3. Hard-coded source id `0` after an atlas was removed and re-added → `S8`.
4. Coordinate inside a big tile instead of its origin → `S9`.
5. `create_tile()` before the texture, or outside it → `S10`.
6. Layer `enabled` off → `S11`.
7. Wrong source or alternative id → `S4`, `S5`.

In every case `get_cell_tile_data(cell) == null` tells you, and in none of them
does anything else.

## What this file does not measure

- Scene tiles (`TileSetScenesCollectionSource`). Everything here is an atlas
  source.
- The legacy `TileMap` node, whose `set_cell` takes a layer index first.
- A tile that exists but is invisible for another reason — transparent art,
  `modulate`, a `z_index` under a background, a `texture_origin` that pushes it
  off screen, or a cell outside the camera.
- The editor's own painting tools; this is about calls from code.
