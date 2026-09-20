# Free solid-collision tileset pack (Match Sides, 16 tiles) — Godot 4

Eight ready-to-paint **solid** TileSets whose collision the physics server
confirms, plus a tool that checks **your own** TileSet for the four ways a
collision setup silently does nothing. **MIT: use them in commercial games, no
credit required.** Every `.tres` here already has a physics layer, a
`collision_layer` that is not zero, and a full-cell collision polygon on **all 16
tiles**. You do not run anything to use these; you drop two files in and paint.

![left: a rock platform run with a gap and a ledge; middle: a brick wall with a one-cell hole and a two-cell shaft; right: an ice floor with a pit — each mass outlined in magenta where the physics server says its collision ends, with white marks where a ray dropped down each column stopped](collision_preview.png)

*Nothing in that picture was drawn by hand. Godot painted the tiles, and the
magenta outline is the boundary of what `PhysicsDirectSpaceState2D` reports as
solid, cell by cell; the white marks are where a ray dropped down each column
actually stopped. If the collision were missing, the outline would be missing.*

| terrain | 16px | 32px | physics layer | polygon |
|---|---|---|---|---|
| Rock  | `rock_solid_16px`  | `rock_solid_32px`  | 0, `collision_layer = 1` | full cell |
| Brick | `brick_solid_16px` | `brick_solid_32px` | 0, `collision_layer = 1` | full cell |
| Ice   | `ice_solid_16px`   | `ice_solid_32px`   | 0, `collision_layer = 1` | full cell |
| Wood  | `wood_solid_16px`  | `wood_solid_32px`  | 0, `collision_layer = 1` | full cell |

Sheets are 4×4 cells: 64×64 for 16px, 128×128 for 32px. The tiles are **opaque**
and the terrain is **Match Sides**, so a complete set is **2⁴ = 16 tiles** — the
dark edge band is drawn only on the sides with no neighbour, and two painted
cells side by side read as one mass.

## Use it (3 steps, ~20 seconds)

1. Copy **both** files of one entry — the `.png` **and** the `.tres` — into your
   project, any folder. They must land in the *same* folder: the `.tres` points at
   the PNG by filename, on purpose, so the pair works wherever you put it.
2. Let the editor import the PNG (it does this by itself when the Godot window
   regains focus). Don't copy any `.import` file from here — Godot writes its own.
3. Set a `TileMapLayer`'s `TileSet` to the `.tres`, open the **TileMap** panel →
   **Terrains** tab and paint. Connect mode is the right one here.

No plugin needed for this pack. Needs Godot **4.3 or newer** (`TileMapLayer`).

## Check your own TileSet: `check_tileset_collision.gd`

The useful half of this pack is the script, and it is not about our tiles:

```
godot --headless --script check_tileset_collision.gd -- res://tiles/my_tiles.tres
```

Exit 0 and `COLLISION-CHECK OK`, or exit 1 and one line per fault. It reports the
four ways a TileSet ends up looking wired while nothing collides, in the order
they bite:

| fault | what it means |
|---|---|
| `NO-PHYSICS-LAYER` | the TileSet has no physics layer at all, so every polygon you drew has nowhere to live |
| `LAYER-MASK-ZERO` | a physics layer exists but its `collision_layer` is **0**: the bodies are created and are on no layer, so nothing ever sees them. Invisible in the editor |
| `TILE-NO-POLYGON` | a tile carries no collision polygon — usually the tiles added *after* you drew the first ones, because the editor does not carry the shape forward |
| `POLYGON-DEGENERATE` | a polygon with fewer than 3 points, or zero area. The editor lets you click two points and move on |

Run it in CI over every TileSet in your project and a tile that lost its collision
stops being something a player reports.

## What "the physics server confirms it" means here

Counting polygons in a `.tres` proves nothing: a polygon can be declared and never
reach the physics server. So the gate for this pack
(`verify_collision_pack.sh`) paints the tiles into a real `TileMapLayer` inside a
running scene tree and asks `PhysicsDirectSpaceState2D` — **112 of 112 claims
pass on Godot 4.3, 4.4 and 4.7**, over all eight TileSets:

**A ray dropped on a painted cell stops at the cell's top edge.** Not inside the
cell, not at the far end of the map: `y = 0.000` for the cell at `(0, 0)`. The
collision is where the art is.

**The shared edge of two painted cells is solid.** A point query exactly on the
seam between `(0,0)` and `(1,0)` finds colliders. This is the "my character falls
through the crack between two tiles" report, and with full-cell polygons it does
not happen.

**Collision exists exactly where tiles do.** A one-cell hole in a painted block is
empty, and so is a cell nobody painted. A solid pack that quietly rounds the hole
shut would be worse than no collision.

**Erasing a cell drops its collider in the same frame.** The collision does not
outlive the tile.

**`collision_enabled = false` removes every collider while the TileSet stays
perfectly wired.** This is the switch that makes a correct pack look broken: the
property is on the `TileMapLayer`, not on the TileSet, so no amount of checking
the `.tres` will ever show it. If our own pack behaves as if it had no collision
in your project, look here first.

## The gotcha that produced this pack

In a `.tres`, a tile's collision polygon lives under its **alternative id**:

```
0:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
```

Drop the second `/0` — write `0:0/physics_layer_0/...` — and Godot loads the file
with **no error, no warning**, and the tile simply has no collision. The same
thing happens to any polygon assigned before the TileSet has a physics layer.
That is the shape of every fault in the table above: nothing is broken loudly.

## Files

* `rock|brick|ice|wood_solid_16|32px.png` + `.tres` — the eight TileSets.
* `check_tileset_collision.gd` — the checker, for your own TileSets. MIT.
* `verify_collision_pack.gd` / `verify_collision_pack.sh` — the gate above. Run
  `verify_collision_pack.sh /path/to/godot` to reproduce the 112 claims yourself;
  `--invert` makes it fail on purpose, so a green run means something.
* `manifest.json` — what each TileSet is, machine-readable.
* `collision_preview.png` — the picture above.

## Where this comes from

Part of the free packs from **Blobsmith**, a Godot 4 autotile wirer that turns
loose tiles into a paint-ready TileSet. The wirer, the free addon and the other
packs are at
<https://github.com/leobaray/blobsmith-autotile-wirer> and
<https://blobsmith.itch.io/blobsmith-lite>.

MIT — see `LICENSE.txt`.
