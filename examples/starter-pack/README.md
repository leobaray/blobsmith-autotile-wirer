# Free 47-blob tileset starter pack — Godot 4

Eight ready-to-paint TileSets. **MIT: use them in commercial games, no credit
required.** Every `.tres` here is already wired — terrain set configured, terrain
peering bits set on all 47 tiles, collision shape on every tile. You do not run
anything to use these; you drop two files in and paint.

| terrain | 16px sheet | 32px sheet | terrain name in the editor |
|---|---|---|---|
| Grass | `grass_47blob_16px` (128×96) | `grass_47blob_32px` (256×192) | `Grass` |
| Stone | `stone_47blob_16px` (128×96) | `stone_47blob_32px` (256×192) | `Stone` |
| Sand  | `sand_47blob_16px` (128×96)  | `sand_47blob_32px` (256×192)  | `Sand` |
| Water | `water_47blob_16px` (128×96) | `water_47blob_32px` (256×192) | `Water` |

## Use it (3 steps, ~20 seconds)

1. Copy **both** files of one row — the `.png` **and** the `.tres` — into your
   project, any folder. They must land in the *same* folder: the `.tres` points
   at the PNG by filename, on purpose, so the pair works wherever you put it.
2. Let the editor import the PNG (it does this by itself when the Godot window
   regains focus). Don't copy any `.import` file from here — Godot writes its own.
3. Add a `TileMapLayer`, set its `TileSet` to the `.tres`, open the **TileMap**
   panel → **Terrains** tab, pick **Connect** mode, and paint.

That's it. No plugin needed for this pack.

## What's in each TileSet

- **47 tiles**, 8 columns, ascending canonical-mask order (the full blob set —
  every corner/side combination that can actually occur).
- **Terrain set 0**, mode **Match Corners and Sides**, one terrain, named after
  the material so eight of these in one project stay distinguishable.
- **Peering bits** set on all 47 tiles — this is the part that makes Connect
  mode choose the right tile instead of leaving holes.
- **Collision**: a full-square polygon on every tile, physics layer 0. If you
  want the terrain walkable instead, delete the physics layer in the TileSet
  inspector, or re-export without it (see below).

## Honest description of the art

This is **procedural placeholder art**, not a hand-drawn asset pack. It is meant
for prototyping, for learning how Godot 4 terrains behave, and as a correct
reference sheet when your own tileset paints the wrong tile. It will not carry
the look of a finished game — swap it for your own art when you have some.

The layout, though, is the real thing: if your own 47-tile sheet matches this
one's ordering, it will wire up exactly the same way.

## Where these came from, and how to make your own

- Drawn from a 6-tile base block by **Blobsmith**, which composes the 47-tile
  sheet and exports this exact `.png` + `.tres` pair. Free in-browser version:
  <https://blobsmith.itch.io/blobsmith-lite> · full version:
  <https://blobsmith.itch.io/blobsmith>
- Already have a 47-blob sheet of your own? The addon in this repo — **Blobsmith
  Autotile Wirer**, MIT, also on the Godot Asset Library — turns it into a wired
  `.tres` in one click: `Project > Tools > Blobsmith Autotile Wirer…`
- Why 47 and not 256, and what "Match Corners and Sides" actually matches:
  [`docs/why-47-tiles-not-256.md`](../../docs/why-47-tiles-not-256.md)

## Verified, not asserted

These files are not "should work". Each of the eight was loaded in a real
engine, headless, painted onto a real `TileMapLayer` with
`set_cells_terrain_connect`, and read back — 13 checks per tileset, 104 total.
Run on three stable builds on 2026-08-23, **104/104 on each**:

| Godot | starter pack |
|---|---|
| 4.3.stable | 104 pass / 0 fail |
| 4.4.stable | 104 pass / 0 fail |
| 4.7.stable | 104 pass / 0 fail |

(4.2 is not covered: `TileMapLayer` does not exist there, so the workflow in
step 3 above has nothing to paint on.) The gate is
`tools/godot-test/verify_starter_pack.gd` in the Blobsmith build repo and it
iterates over `manifest.json` here, so a tileset added to this folder cannot
skip the engine.

Per tileset it checks: the `.tres` loads with the relative texture path, the
atlas source and texture resolve, the sheet is the expected size, 47 tiles are
present, tile size is right, terrain mode is Match Corners and Sides, the terrain
carries its name, the physics layer exists, **47/47** tiles have a collision
polygon, a 20-cell terrain paint fills every cell, and the interior cell reports
all 8 peering neighbours.

## License

MIT — see `LICENSE.txt`. Both the art and the `.tres` files.
