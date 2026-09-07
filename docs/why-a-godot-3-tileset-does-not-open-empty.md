# Your Godot 3 tileset does not open empty in Godot 4 — it opens without the autotile

You exported a tileset from Tilesetter or TilePipe2, or you carried one over
from a Godot 3 project. Godot 4 opens it, shows you something, and the Terrains
tab is empty. The usual advice is that Godot 4 "cannot read Godot 3 tilesets"
and that you have to re-draw the whole thing.

That is not what the engine does, and the difference decides how much work you
actually have in front of you.

Every number below was read out of a running engine by
[`docs/verify_godot3_tileset.sh`](verify_godot3_tileset.sh), which builds the
Godot 3 files, loads them and prints PASS/FAIL per claim. **15 claims, 15
passing, identical on Godot 4.3, 4.4 and 4.7 stable.** Run it against your own
build:

```
docs/verify_godot3_tileset.sh /path/to/Godot_v4.4-stable_linux.x86_64
```

## What the engine actually does

Godot 4 has a compatibility path for `format=2` TileSets
(`_compatibility_conversion`, `scene/resources/2d/tile_set.cpp`). Loading one
does **not** fail and does **not** return null. From a file with two autotiles
and three single tiles:

| | Godot 3 file | what Godot 4 hands back |
|---|---|---|
| atlas sources | 5 tiles | **5 sources** — one per Godot 3 tile |
| tiles inside them | 8 autotile subtiles + 3 single | **3** |
| terrain sets | 3 bitmask modes | **0** |
| diagnostics | — | **one WARNING** |

So the resource is not empty: the sources are there, the texture is there, the
single tiles are there with their regions and their `z_index`. What is gone is
every **autotile** — each one arrives as a source with **zero tiles in it**, and
that source is left at `margins (0, 0)`, so the region it used to cover is gone
with it. You cannot even read back which part of the sheet it was.

The engine says so, once, as a warning:

```
WARNING: Could not convert 3.x autotiles to 4.x. This operation cannot be done
automatically, autotiles must be re-created using the terrain system.
```

A warning in the Output panel, not an error, not a dialog. If you opened the
project and clicked on the tileset, you very likely never saw it.

## The part nobody warns you about: shared collision shapes drift

The single tiles come through — including their collision. Godot 3 stored a
shape in tile-local coordinates counted from the tile's **top-left**; Godot 4
counts from the tile **centre**, so a quad covering the bottom half of a 16px
tile has to move by `-8, -8`. Alone in a file, that is exactly what the engine
does: `(0,8) (16,8) (16,16) (0,16)` comes back as `(-8,0) (8,0) (8,8) (-8,8)`.
Correct.

Now put three tiles in the file that share one shape sub-resource — which is how
Godot 3 tilesets were normally made, since you draw one full-tile box and reuse
it. The shape is re-origined **in place, once per tile that points at it**:

| tile | collision Godot 4 reads back | |
|---|---|---|
| 1st sharer | `(-8,0) (8,0) (8,8) (-8,8)` | correct |
| 2nd sharer | `(-16,-8) (0,-8) (0,0) (-16,0)` | half a tile up and left |
| 3rd sharer | `(-24,-16) (-8,-16) (-8,-8) (-24,-8)` | a whole tile up and left |

Three identical tiles, three different collisions, and the drift is cumulative.
No warning is printed for this one. It is the kind of thing you find in play, as
a floor you fall through or a wall you walk into a tile early — long after you
stopped suspecting the import.

## And the source ids move

A Godot 3 tile written as `2/...`, alone in its file, comes back as Godot 4
source id **0**. Ids are re-issued in order, not kept. Anything that stored a
tile id — a painted map, a saved level, a script that calls `set_cell` with a
source id — is now pointing at a number that means something else.

## What to do with the file you have

The geometry is exact and needs no guessing. A Godot 3 subtile at coord `c`
covers `region.position + (tile_size + spacing) * c`; a Godot 4
`TileSetAtlasSource` covers `margins + coords * (texture_region_size +
separation)`. Same expression: `margins := region.position`, `separation :=
spacing`, `texture_region_size := tile_size`, and every subtile keeps the
coordinate it already had.

The bitmasks are lossy in exactly one direction:

| Godot 3 | Godot 4 |
|---|---|
| `BITMASK_2X2` (16 tiles) | `MATCH_CORNERS` |
| `BITMASK_3X3_MINIMAL` (47 tiles) | `MATCH_CORNERS_AND_SIDES` |
| `BITMASK_3X3` (256 tiles) | nothing — see below |

Godot 4 cannot say "the top-left neighbour is mine but the top one is not": a
corner peering bit is only read when both of its sides are set. A `BITMASK_3X3`
tileset therefore converts by canonicalising every mask, and canonicalising can
make two different subtiles answer to the same neighbourhood — the engine will
then paint one of them and never the other, which looks like a tile going
missing.

`docs/convert_godot3_tileset.js` does the arithmetic and, more to the point,
reports every mask it changed and every pair it collapsed, by tile and by
subtile coordinate:

```
node docs/convert_godot3_tileset.js old_tileset.tres
node docs/convert_godot3_tileset.js /path/to/project        # scans for format=2
node docs/convert_godot3_tileset.js old_tileset.tres --write
```

It reads the Godot 3 file, keeps the tile ids as source ids (so a painted map
still resolves), re-origins each collision polygon from the tile that owns it —
which is why a shared shape does not drift — and writes nothing unless you ask.
It refuses rather than invents: an occluder, a navigation polygon, a priority
map, a rotated or scaled shape transform and a `tex_offset` come back as named
notes with the tile and the coordinate, so you know what to redo and where,
instead of finding out in play.

Same rules in the browser, no install and no account:
<https://blobsmith.lbwma.com/godot-3-tileset-to-godot-4/>

## What this does not do

- It does not re-draw art. A `BITMASK_3X3` sheet that used free corners has
  drawings Godot 4 has no neighbourhood for; the tool names them, you decide.
- It does not touch your scenes. Cells already painted with a `TileMap` are a
  separate job — see
  [converting `TileMap` to `TileMapLayer`](converting-tilemap-to-tilemaplayer.md).
- It does not merge tilesets. Two converted files are still two files; see
  [what a TileSet merge has to remap](merging-two-tilesets.md).

## Files

| | |
|---|---|
| [`convert_godot3_tileset.js`](convert_godot3_tileset.js) | the CLI |
| [`tres3-convert-core.js`](tres3-convert-core.js) | the rules, no filesystem — the same bytes the browser tool runs |
| [`verify_godot3_tileset.gd`](verify_godot3_tileset.gd) | the 15 claims above, as a script |
| [`verify_godot3_tileset.sh`](verify_godot3_tileset.sh) | builds the project and runs them |

MIT, like the rest of this repository.
