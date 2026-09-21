# Free walkable-floor navigation tileset pack (floor + wall, Match Sides) — Godot 4

Eight ready-to-paint **top-down floor + wall** TileSets where the floor already
carries a navigation polygon and the wall already carries collision, so
`NavigationServer2D` — the server a `NavigationAgent2D` asks — returns a path
around the walls the moment the room is painted — plus a tool that
checks **your own** TileSet for the ways a navigation setup silently does
nothing. **MIT: use them in commercial games, no credit required.** You do not
run anything to use these; you drop two files in and paint.

![four copies of the same 11 x 9 room painted by Godot: in the dungeon and deck rooms the path goes down through the gap in the inner wall and back up; in the meadow room a door was painted in the wall and the path is a straight line; in the cave room the gap was painted shut and the path stops against the wall, marked with a yellow cross](navigation_preview.png)

*Nothing in that picture was drawn by hand. Godot painted the rooms with
`set_cells_terrain_connect`, and the white line is the path
`NavigationServer2D.map_get_path()` returned from the green square to the red
one. Bottom right: the gap in the inner wall painted shut. The path does not come
back empty — it comes back shorter, ending against the wall (yellow cross).*

| theme | 16px | 32px | floor | wall |
|---|---|---|---|---|
| Dungeon | `dungeon_nav_16px` | `dungeon_nav_32px` | flagstones | dark stone |
| Meadow  | `meadow_nav_16px`  | `meadow_nav_32px`  | grass | hedge |
| Deck    | `deck_nav_16px`    | `deck_nav_32px`    | planks | dark timber |
| Cave    | `cave_nav_16px`    | `cave_nav_32px`    | dirt | rock |

Each TileSet is one **Match Sides** terrain set with two terrains — terrain 0
**Floor** and terrain 1 **Wall** — and **17 tiles**: 16 floor tiles and one wall
tile. Sheets are 5×4 cells: 80×64 for 16px, 160×128 for 32px (the three cells
under the wall tile are empty and are not tiles).

* **Every floor tile** has a full-cell navigation polygon on navigation layer 0,
  whose `layers` bitmask is **1** — the value `NavigationAgent2D.navigation_layers`
  ships with. The polygon is authored in the tile's own centred coordinates,
  `(-8,-8)..(8,8)` at 16px, not `(0,0)..(16,16)`. No collision.
* **The wall tile** has a full-cell collision polygon on physics layer 0
  (`collision_layer = 1`) and **no** navigation polygon: a wall is a hole in the
  navigation mesh, which is what makes the path go around it.

Why 16 + 1 and not 16 + 16: in Godot a side peering bit is the terrain *of that
edge*, and the two cells that share the edge must agree on it. The edge between a
floor cell and a wall cell belongs to the wall here, so the floor tiles have 2⁴ =
16 variants (a darker band on each side that touches a wall) and the wall tile is
Wall on all four sides. A first draft gave both terrains 16 tiles, each side naming
the neighbour's terrain; the two cells then disagree about every floor/wall edge,
and `set_cells_terrain_connect` painted 37 of the 99 cells of the test room with
the wrong tile.

## Use it (3 steps, ~20 seconds)

1. Copy **both** files of one entry — the `.png` **and** the `.tres` — into your
   project, any folder. They must land in the *same* folder: the `.tres` points at
   the PNG by filename, on purpose, so the pair works wherever you put it.
2. Let the editor import the PNG (it does this by itself when the Godot window
   regains focus). Don't copy any `.import` file from here — Godot writes its own.
3. Set a `TileMapLayer`'s `TileSet` to the `.tres`, open the **TileMap** panel →
   **Terrains** tab, choose Connect, and paint **Floor first, then Wall** on the
   same layer. Add a `NavigationAgent2D` to your character; nothing else to wire —
   `navigation_enabled` is on by default on a `TileMapLayer`.

No plugin needed for this pack. Needs Godot **4.3 or newer** (`TileMapLayer`).

### Painting from code: two things the gate measured

```gdscript
layer.set_cells_terrain_connect(floor_cells, 0, 0, false)  # Floor first
layer.set_cells_terrain_connect(wall_cells, 0, 1, false)   # then Wall
```

* **Pass `false` as the 4th argument.** The editor's Connect tool passes
  `ignore_empty_terrains = false`; a script that leaves the argument out gets
  `true`. With `true`, the same two calls on an empty layer painted **20 of the 99
  cells of the test room, and none of the walls** — every cell next to an empty
  cell is left empty, because no tile in this pack has an empty side.
* **Floor first, then Wall.** The other order gives the same navigation (same
  regions, same path) but 21 floor cells come out missing their shade band on a
  side that touches a wall. Only the art is affected.

### Asking for a path: wait for the map, not for a number of frames

A path asked in the same frame the room is painted comes back **empty** — the map
has not been rebuilt yet (on 4.3 the engine also prints `ERROR: NavigationServer
navigation map query failed because it was made before first map
synchronization`). How many frames that takes is not a constant: over the 24
room paints behind this README (8 TileSets × 3 engines) the id first moved on
frame 1, 2, 3 or 8. Wait for the map's iteration id to move:

```gdscript
var map := layer.get_world_2d().navigation_map
var id := NavigationServer2D.map_get_iteration_id(map)
# ... paint ...
while NavigationServer2D.map_get_iteration_id(map) == id:
    await get_tree().physics_frame
var path := NavigationServer2D.map_get_path(map, from, to, true)
```

The gate is stricter than that snippet: after the id moves it also waits until
the region count is the one the edit should produce and the answer has stopped
changing for 8 frames, because the id and the path are updated separately
([`docs/verify_tile_navigation.gd`](../../docs/verify_tile_navigation.gd) measured
a moved id with a stale path under load).

## Check your own TileSet: `check_tileset_navigation.gd`

```
godot --headless --script check_tileset_navigation.gd -- res://tiles/my_tiles.tres
```

Exit 0 and `NAVIGATION-CHECK OK`, or exit 1 and one line per fault. A tile counts
as a **wall** when it carries a collision polygon on a physics layer with a
non-zero `collision_layer`, and as a **floor** otherwise. It reports:

| fault | what it means |
|---|---|
| `NO-NAVIGATION-LAYER` | the TileSet has no navigation layer, so every navigation polygon you draw has nowhere to live |
| `NAV-LAYERS-ZERO` | a navigation layer exists but its `layers` bitmask is **0**: the regions are built on no layer and no agent ever finds them |
| `FLOOR-NO-POLYGON` | a floor tile carries no navigation polygon. Painted, it is a hole in the mesh — usually the tiles added *after* you drew the first ones |
| `POLYGON-EMPTY` | a navigation polygon with outlines or vertices but no polygons: the resource exists and builds nothing |
| `POLYGON-OFFSET` | a vertex lies outside the centred cell: the polygon was authored from `(0,0)` to `(size,size)` and the walkable surface sits half a tile down-right of the art |
| `WALL-HAS-NAV` | a wall tile carries a navigation polygon, so agents are routed through the thing they collide with |

Run it in CI over every TileSet in your project.

## What "the navigation server confirms it" means here

Counting polygons in a `.tres` proves nothing: a polygon can be declared on a
layer no agent asks, or half a tile away from the art. So the gate for this pack
(`verify_navigation_pack.sh`) paints an 11×9 room — walled all round, split by an
inner wall open only at the bottom — into a real `TileMapLayer` and asks
`NavigationServer2D` and `PhysicsDirectSpaceState2D`. **168 of 168 claims pass on
Godot 4.3, 4.4 and 4.7**, over all eight TileSets (21 per TileSet):

**One navigation region per floor cell, none for the walls.** 57 regions for 57
floor and 42 wall cells, read only after `map_get_iteration_id()` moved.

**The path goes around the wall, never through it.** From the centre of cell
`(2,3)` to the centre of `(8,3)`: 96 px apart in a straight line at 16px, the
returned path is 161.6 px long on 4.3 and 4.7 and 160.9 px on 4.4 (the two
versions place the corner points differently), passes through the gap, and not
one sample along it — every 0.25 px — lies inside a wall cell.

**The endpoints land in the right cells.** The first and last path points are the
exact centres of the start and goal cells. A point in the top-left quarter of a
floor cell is on the mesh, and the centre of a wall cell is pulled exactly half a
tile to the wall's edge — the polygon covers the art, not the cell half a tile
down-right.

**Walls block bodies, floors do not.** The physics server finds a collider at a
wall cell's centre and none on a floor cell.

**Closing the corridor does not empty the path — it shortens it.** Paint the gap
as wall and the room is two rooms; the path comes back 4 points long, ending
against the wall 56 px short of the goal (at 16px). `if path.is_empty()` never
fires. Paint the gap back as floor and the full path returns, same length; paint
a door in the inner wall and the path becomes the 96 px straight line.

## Files

* `dungeon|meadow|deck|cave_nav_16|32px.png` + `.tres` — the eight TileSets.
* `check_tileset_navigation.gd` — the checker, for your own TileSets. MIT.
* `verify_navigation_pack.gd` / `verify_navigation_pack.sh` — the gate above. Run
  `verify_navigation_pack.sh /path/to/godot` to reproduce the 168 claims yourself;
  `--invert` makes it fail on purpose, so a green run means something.
* `manifest.json` — what each TileSet is, and the test room, machine-readable.
* `navigation_preview.png` — the picture above.

## Where this comes from

Part of the free packs from **Blobsmith**, a Godot 4 autotile wirer that turns
loose tiles into a paint-ready TileSet. The wirer, the free addon and the other
packs are at
<https://github.com/leobaray/blobsmith-autotile-wirer> and
<https://blobsmith.itch.io/blobsmith-lite>.

MIT — see `LICENSE.txt`.
