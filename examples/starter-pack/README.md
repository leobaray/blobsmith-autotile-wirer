# Free 47-blob and 16-tile tileset starter pack — Godot 4

Sixteen ready-to-paint TileSets. **MIT: use them in commercial games, no credit
required.** Every `.tres` here is already wired — terrain set configured, terrain
peering bits set on every tile, collision shape on every tile. You do not run
anything to use these; you drop two files in and paint.

Both of Godot 4's terrain layouts are here, because the mode you pick in the
inspector decides how many tiles the sheet needs:

| terrain | Match Corners and Sides (47 tiles) | Match Sides (16 tiles) | terrain name in the editor |
|---|---|---|---|
| Grass | `grass_47blob_16px` · `grass_47blob_32px` | `grass_16sides_16px` · `grass_16sides_32px` | `Grass` |
| Stone | `stone_47blob_16px` · `stone_47blob_32px` | `stone_16sides_16px` · `stone_16sides_32px` | `Stone` |
| Sand  | `sand_47blob_16px` · `sand_47blob_32px`   | `sand_16sides_16px` · `sand_16sides_32px`   | `Sand` |
| Water | `water_47blob_16px` · `water_47blob_32px` | `water_16sides_16px` · `water_16sides_32px` | `Water` |

Sheet sizes: 47-blob is 8×6 tiles (128×96 at 16px, 256×192 at 32px); 16-tile is
8×2 tiles (128×32 at 16px, 256×64 at 32px).

## Which one do I want?

- **47-blob / Match Corners and Sides** — the default, and what you want for
  ground that meets other ground: grass against dirt, an island in water. It
  resolves diagonals, so two blobs touching at a corner get the right tile
  instead of a notch.
- **16-tile / Match Sides** — pipes, fences, wires, cave walls, roads, anything
  where only the four orthogonal neighbours matter and a diagonal touch should
  *not* connect. It is a third of the tiles to draw when you replace this art
  with your own, which is the main reason to choose it.

Set the mode in the TileSet inspector under **Terrain Sets** — but you do not
have to here: each `.tres` already declares its own mode, so dropping in a
`_16sides_` file gives you a Match Sides terrain and a `_47blob_` file gives you
Match Corners and Sides.

## Use it (3 steps, ~20 seconds)

1. Copy **both** files of one entry — the `.png` **and** the `.tres` — into your
   project, any folder. They must land in the *same* folder: the `.tres` points
   at the PNG by filename, on purpose, so the pair works wherever you put it.
2. Let the editor import the PNG (it does this by itself when the Godot window
   regains focus). Don't copy any `.import` file from here — Godot writes its own.
3. Add a `TileMapLayer`, set its `TileSet` to the `.tres`, open the **TileMap**
   panel → **Terrains** tab, pick **Connect** mode, and paint.

That's it. No plugin needed for this pack.

## What's in each TileSet

- **47 or 16 tiles**, 8 columns, ascending canonical-mask order — the full blob
  set (every corner/side combination that can occur), or the sides-only set.
- **Terrain set 0**, mode **Match Corners and Sides** or **Match Sides**, one
  terrain, named after the material so sixteen of these in one project stay
  distinguishable.
- **Peering bits** set on every tile — this is the part that makes Connect mode
  choose the right tile instead of leaving holes. The 16-tile files carry the
  four side bits and no corner bits; that difference *is* the layout.
- **Collision**: a full-square polygon on every tile, physics layer 0. If you
  want the terrain walkable instead, delete the physics layer in the TileSet
  inspector, or re-export without it (see below).

## Honest description of the art

This is **procedural placeholder art**, not a hand-drawn asset pack. It is meant
for prototyping, for learning how Godot 4 terrains behave, and as a correct
reference sheet when your own tileset paints the wrong tile. It will not carry
the look of a finished game — swap it for your own art when you have some.

The layout, though, is the real thing: if your own 47-tile or 16-tile sheet
matches the corresponding sheet's ordering, it will wire up exactly the same way.

## Where these came from, and how to make your own

- Drawn from a 6-tile base block by **Blobsmith**, which composes the sheet and
  exports this exact `.png` + `.tres` pair. Both layouts come from the same base
  block — the 16-tile row of a material is the same art as its 47-tile row.
  Free in-browser version: <https://blobsmith.itch.io/blobsmith-lite> ·
  full version: <https://blobsmith.itch.io/blobsmith>
- Already have a sheet of your own? The addon in this repo — **Blobsmith
  Autotile Wirer**, MIT, also on the Godot Asset Library — turns it into a wired
  `.tres` in one click, in either layout:
  `Project > Tools > Blobsmith Autotile Wirer…`
- Why 47 and not 256, and what "Match Corners and Sides" actually matches:
  [`docs/why-47-tiles-not-256.md`](../../docs/why-47-tiles-not-256.md)

## Verified, not asserted

These files are not "should work". Each of the sixteen was loaded in a real
engine, headless, painted onto a real `TileMapLayer` with
`set_cells_terrain_connect`, and read back. Run on three stable builds on
2026-09-01, **216/216 on each**:

| Godot | starter pack |
|---|---|
| 4.3.stable | 216 pass / 0 fail |
| 4.4.stable | 216 pass / 0 fail |
| 4.7.stable | 216 pass / 0 fail |

(4.2 is not covered: `TileMapLayer` does not exist there, so the workflow in
step 3 above has nothing to paint on.) The gate is
`tools/godot-test/verify_starter_pack.gd` in the Blobsmith build repo and it
iterates over `manifest.json` here, so a tileset added to this folder cannot
skip the engine — and it reads each entry's tile count and terrain mode from the
manifest, so the 16-tile files are held to the 16-tile shape rather than to a
loosened check that both layouts could pass.

Per tileset it checks: the `.tres` loads with the relative texture path, the
atlas source and texture resolve, the sheet is the expected size, the declared
number of tiles is present, tile size is right, the terrain mode is the one this
layout needs, the terrain carries its name, the physics layer exists, **every**
tile has a collision polygon, a 20-cell terrain paint fills every cell, and the
interior cell reports all 4 side peering neighbours — plus, for the 47-blob
files, all 4 corners.

One honest limit, found by mutation on 2026-09-01: injecting a corner peering
bit into a 16-tile `.tres` and re-running the engine gate still reports ALL PASS,
because Godot normalises corner bits away in `MATCH_SIDES`. So "the 16-tile files
carry no corner bits" is not an engine claim — it is asserted on the written
bytes by `tools/make-starter-pack.js` (32 side bits / 0 corner bits per file,
against 136 / 52 for a 47-blob file).

## License

MIT — see `LICENSE.txt`. Both the art and the `.tres` files.
