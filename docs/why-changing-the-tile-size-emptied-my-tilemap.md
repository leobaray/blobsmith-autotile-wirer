# I changed the tile size and half the map went invisible — what the engine does

You typed a new number into a field called tile size, and the map came back
wrong: some cells blank, the rest showing the wrong art. Nothing errored.
Undo in the TileSet panel does not obviously bring it back, and the cells are
still there in the editor's tile map.

There are **two** fields called something like tile size, they do different
things, and only one of them can break an atlas:

- `TileSet.tile_size` — how big a **cell on the map** is. Changing it never
  touches the atlas (`D1`, `D2`).
- `TileSetAtlasSource.texture_region_size` — how big a **cell in the sheet**
  is. Changing it re-cuts the sheet under tiles that already exist (`A3`–`A7`).

Every claim here has an id (`A4`, `B3`, …) and is asserted by
[`verify_tile_size_change.gd`](verify_tile_size_change.gd) against a real
binary, with what a cell draws read back from rendered pixels:

```
docs/verify_tile_size_change.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3.stable.official.77dcf97d8, 4.4.stable.official.4c311cbee
and 4.7.stable.official.5b4e0cb0f**: 19 checks, 19/19 on each. Last run
**2026-09-17**. Needs 4.3 or newer — `TileMapLayer` does not exist in 4.2. The
script needs `xvfb-run`; the headless renderer returns no pixels.

---

## The short answer

Your map is fine. Your atlas is not. Put `texture_region_size` back to what it
was and everything returns, exactly (`E1`, `E2`):

```gdscript
var src := layer.tile_set.get_source(source_id) as TileSetAtlasSource
src.texture_region_size = Vector2i(16, 16)   # the size the sheet was drawn at
```

If 32 px really is the size you want, the sheet has to be redrawn at 32 px —
the tiles that used to fit no longer do, and they have to go (`E3`, below).

## What actually happened

Take a 64x32 sheet cut into 4x2 cells of 16 px, one tile per cell: 8 tiles,
atlas grid 4x2 (`A1`). Tile `(3,1)` reads the last cell, `Rect2i(48, 16, 16, 16)`
(`A2`).

Now set `texture_region_size` to 32x32. The engine does **not** delete a single
tile — the source still lists all 8 (`A3`). What changes is the ruler they are
measured with:

- the atlas grid becomes **2x1** (`A4`), because a 64x32 texture only holds two
  32 px cells;
- six of the eight tiles are now outside that grid, and their regions are
  computed anyway: tile `(3,1)` claims `Rect2i(96, 32, 32, 32)` — a rectangle
  that lies entirely outside a 64x32 texture (`A5`);
- `has_tile(Vector2i(3, 1))` still answers `true` (`A6`). There is no error, no
  warning, and no API that tells you the tile is now pointing at nothing.

The two tiles that stayed inside did not survive intact either: tile `(0,0)`
now reads `Rect2i(0, 0, 32, 32)` — four of the sheet's original cells at once
(`A7`).

## What that looks like on screen

Before the change, a cell painted with tile `(0,0)` draws that sheet cell's
colour (`B1`). After it, the same cell, the same `set_cell` call, draws a
**different** colour: the 32 px region is centred on the 16 px map cell, so what
you see is the middle of four sheet cells, not the tile you picked (`B2`).

A cell painted with a tile whose region left the texture draws **nothing at
all** — fully transparent, no magenta, no placeholder (`B3`). That is the blank
half of the map.

## The map data was never touched

This is the part worth checking before you rebuild anything by hand. After the
atlas change, the layer still reports the same source id and the same atlas
coordinates for the cell (`C1`), and the cell is still in `get_used_cells()`
(`C2`). Nothing was erased. An invisible cell and an empty cell are different
things, and only one of them needs re-painting.

## The other "tile size"

`TileSet.tile_size = Vector2i(32, 32)` on the same setup leaves
`texture_region_size` at 16, the atlas grid at 4x2 and all 8 tiles in place
(`D1`), and tile `(3,1)` still reads its original sheet cell (`D2`). Nothing
breaks in the atlas.

What you get instead is 16 px of art dropped in the middle of a 32 px cell
(`D3`): correct art, centred, with transparent margin all round — a map that
looks like it grew gaps between every tile. Different symptom, different field,
different fix (draw the sheet bigger, or put the cell size back).

## If you do want a bigger region

Changing the number is only the first half. The tiles that no longer fit have
to be removed, and the engine will not do it for you. Dropping every tile whose
region has left the texture removes exactly the six that broke, and leaves the
two that still fit (`E3`):

```gdscript
var tex := Rect2i(Vector2i.ZERO, Vector2i(src.texture.get_size()))
var doomed: Array[Vector2i] = []
for i in src.get_tiles_count():
	var coords: Vector2i = src.get_tile_id(i)
	if not tex.encloses(src.get_tile_texture_region(coords)):
		doomed.append(coords)
for coords in doomed:
	src.remove_tile(coords)
```

Collect first, remove after. `remove_tile` re-indexes the source under you: the
same test written as a loop over `get_tile_id(i)` removes only 4 of the 6 and
leaves two broken tiles behind (`E4`).

Removing a tile is the destructive step — it takes its collision shapes,
terrain bits and custom data with it, and cells in the map that referenced it
stay set and draw nothing. Re-cutting a sheet is cheap; re-wiring 47 terrain
tiles is not. If the sheet is a 47-blob layout,
[Blobsmith](https://blobsmith.itch.io/blobsmith-lite) re-wires the peering bits
from the new atlas instead of you clicking them back in.

## Related

- [Why `set_cell` draws nothing](why-set-cell-draws-nothing.md) — the other
  ways a cell you did set stays blank.
- [Why tiles have seams](why-tiles-have-seams.md) — gaps between tiles that are
  about filtering, not about cell size.
- [Why one cell changed every cell](why-one-cell-changed-every-cell.md) — when
  the atlas is fine and terrain is the thing rewriting your map.
