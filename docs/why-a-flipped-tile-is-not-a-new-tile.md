# A flipped tile in Godot 4 is not a new tile — what the three transform bits actually buy you

Two questions bring people here, and the answers point in opposite directions:

- *"My sheet is symmetric — can I draw half the tiles and flip the rest?"*
- *"I flipped a tile. Did its collision flip too?"*

Search gives you confident answers to both. This page is the measurement
instead. Every claim below has an id (`C2`, `C5`, …) and is asserted by
[`verify_tile_transforms.gd`](verify_tile_transforms.gd), which re-runs the
whole thing against your Godot build and exits non-zero if any of it stops
holding:

```
docs/verify_tile_transforms.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, 33
checks, two identical runs on each. Last re-run **2026-08-31**. Needs 4.3 or
newer — `TileMapLayer` does not exist in 4.2.

---

## The short answer

A flip is a property of the **cell**, not of the tile. It is three bits stored
next to the cell's alternative id, and it changes exactly one thing: how the
tile is drawn, and the collision shape that gets built from it.

It does **not** create a tile. There is no TileData behind a flipped cell — the
cell resolves to the *unflipped* tile's TileData, the same object (`C3`). So a
flip cannot carry its own terrain bits, its own custom data, or its own
navigation polygon, because there is nothing there to carry them on.

And the consequence that answers the first question: **the terrain autotiler
never emits a transform bit** (`C5`). It will not flip a tile you drew to fill a
neighbourhood you did not draw. A symmetric sheet does not let you draw fewer
tiles — it lets you draw the same tiles faster.

## The three bits

| constant | value |
|----------|-------|
| `TileSetAtlasSource.TRANSFORM_FLIP_H` | `4096` (`0x1000`) |
| `TileSetAtlasSource.TRANSFORM_FLIP_V` | `8192` (`0x2000`) |
| `TileSetAtlasSource.TRANSFORM_TRANSPOSE` | `16384` (`0x4000`) |

They are OR-ed into the `alternative_tile` argument of `set_cell()`. `C1`
pins the values; [the `tile_map_data` format
doc](tile-map-data-format.md) covers how they are stored on disk.

**You do not author anything to use them** (`C2`). Setting a cell with
`FLIP_H` on a tile that has no alternatives works, and creates none — the
atlas still reports one alternative for that tile afterwards, and the cell
still reads back with the base source id and the base atlas coords. Building
four alternative tiles per sheet tile to get the four flips is work the engine
did not ask for.

## Can flips shrink a 47-tile blob sheet?

No, and here is the experiment rather than the assertion.

Build a sides-only terrain set with two pieces: a **middle** (connects left and
right) and a **left end** (connects right only). Deliberately withhold the
**right end** — the mirror image of the left end, the one piece the sheet is
missing. Then ask the engine to paint a three-cell run, whose right-hand cell
needs exactly that missing piece.

| id | what was done | result |
|----|---------------|--------|
| `C5` | paint the run with the mirror **absent** | all 3 cells painted, **0** carry a transform bit |
| `C5` | the cell whose piece is missing | got the **middle** tile — a piece that connects rightward into empty space |
| `K1` | the same paint with the mirror **drawn** | that cell takes the mirror instead |
| `K1` | …and even with the sheet complete | still **0** transform bits |

`K1` is the control, and it is the reason `C5` means anything: with the mirror
present the engine picks it, so the fallback in `C5` is caused by the missing
tile and not by the check always reading the same answer.

What you see in the game is the failure mode the [terrain-choice
page](why-terrain-paints-the-wrong-tile.md) describes: no error, no empty cell,
just a tile whose edge points at nothing. The engine would rather give you a
wrong tile of the right terrain than no tile — and flipping a tile it already
has is not among the options it considers.

So the count in [why a blob autotile has 47 tiles](why-47-tiles-not-256.md)
is not negotiable by symmetry. Draw all 47.

## What a flipped cell shares with the tile it came from

`C3`: a flipped cell's `get_cell_tile_data()` returns the **same TileData
object** as the unflipped cell — with one transform bit or all three. Its
custom data is the base tile's custom data. `K2` is the control: two different
base tiles do not compare equal, so "same object" is a real finding and not
something true of any two TileData.

The practical reading: there is no per-flip TileData to edit, so there is
nothing you can give a flipped tile that its base does not already have.

## …but the collision *is* mirrored

This is where the two obvious answers are both half right, and where reading
your own code will mislead you.

Give a tile a right triangle for a collision polygon — no flip of it maps back
onto itself, so there is no ambiguity — and place two cells, one plain and one
`FLIP_H`:

| id | where you look | what you get |
|----|----------------|--------------|
| `C3` | `get_cell_tile_data().get_collision_polygon_points()` | the polygon **as authored**, not mirrored |
| `C7` | the shape the physics server actually holds | **mirrored** |

Both are true at once, because they are two different things: TileData is the
tile's authored data, and the physics shape is built from it per cell, with the
cell's transform applied. `K4` is the control — it fails if the polygon under
test is symmetric enough that mirrored and unmirrored are the same set.

So: your player collides with a mirrored shape, and the API you would naturally
call to check reports an unmirrored one. Anyone who inspects `TileData` and
concludes "collision does not follow the flip" has read a true value and drawn
a false conclusion.

Measured for `FLIP_H` only. `FLIP_V` and `TRANSPOSE` are not covered by `C7`.

## Transform bits and authored alternatives are different fields

`create_alternative_tile()` hands out small ids — `1`, `2`, `3` — that sit
below the transform bits, so a cell can carry both at once (`C4`). Set a cell
with `alt | FLIP_H` and it reads back as `alt | FLIP_H`, and
`get_cell_tile_data()` resolves to the **authored alternative's** TileData, not
the base tile's.

That is the escape hatch for everything the previous two sections take away: if
you need a mirrored-looking tile that also has its own terrain bits, custom
data or navigation, an authored alternative is the thing that has a TileData of
its own. A transform bit is not.

## The repaint trap

If you hand-fix an autotiled map by flipping a cell, the next terrain repaint
that includes that cell erases the flip (`C6`) — the autotiler owns the cells
it is given, and since it has no way to consider a flip a match (`C5`), it
overwrites it. `K3` is the control: a flip on a cell **outside** the repainted
set survives, so it is the repaint doing this and not flips failing to persist.

## Where flips are the right tool

Decorative and hand-placed tiles, set from code or from the editor's transform
shortcuts, where all you want is a mirrored image that shares the base tile's
data. That is a real saving in sheet size — for tiles nothing autotiles.

For anything the terrain system paints, the transform bits are not part of the
conversation.

## What this file does not measure

- Which visual orientation each combination of the three bits produces. The
  bits are stored and resolve to the base TileData (`C3`); the resulting
  rotation is not asserted.
- `FLIP_V` and `TRANSPOSE` against the physics server (`C7` covers `FLIP_H`).
- Godot 4.2, which has no `TileMapLayer`. The three bits exist in the
  `tile_map_data` buffer there too — see [the format
  doc](tile-map-data-format.md) — but nothing on this page was run against it.
- Navigation polygons, which are a TileData property like the collision one and
  would plausibly behave the same way. Plausible is not measured, so it is not
  claimed.
