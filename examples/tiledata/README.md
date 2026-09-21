# Free tile custom-data tileset pack (ground, move cost, walkable, damage, footstep) — Godot 4

Eight ready-to-paint **top-down ground** TileSets where every tile already says
what it is — five **custom data layers** filled in on every tile — so
`get_cell_tile_data(cell).get_custom_data("move_cost")` answers the moment the
map is painted, and an `AStarGrid2D` fed from those answers routes round the lava
and over the bridge — plus a tool that checks **your own** TileSet (and your
scripts) for the ways custom data silently reads back wrong. **MIT: use them in
commercial games, no credit required.** You do not run anything to use these; you
drop two files in and paint.

![four copies of the same 16 x 10 map painted by Godot — meadow, volcano, swamp, snow — each with a river down the middle, a ford at the top and a bridge on the road at the bottom; the white line is the path an AStarGrid2D fed the tiles' data returned, round the hazard patch and over the bridge; the orange line is the same grid fed only walkable, cutting through the hazard and the ford](tiledata_preview.png)

*Nothing in that picture was drawn by hand. Godot painted the maps with
`set_cells_terrain_connect`, read every cell back with `get_cell_tile_data()`,
and built two `AStarGrid2D`s from what it read. White: fed `walkable` and
`move_cost` — the path takes the road and the bridge. Orange: fed `walkable`
only — the shorter way, straight across the hazard patch and through the ford.*

| theme | 16px | 32px | path | ground | rough | slow | hazard | blocked |
|---|---|---|---|---|---|---|---|---|
| Meadow  | `meadow_data_16px`  | `meadow_data_32px`  | road | grass | sand | shallow water | thorns | deep water |
| Volcano | `volcano_data_16px` | `volcano_data_32px` | basalt road | ash | cinder | hot spring | lava | chasm |
| Swamp   | `swamp_data_16px`   | `swamp_data_32px`   | boardwalk | moss | mud | bog water | poison bog | deep bog |
| Snow    | `snow_data_16px`    | `snow_data_32px`    | cleared path | snow | deep snow | ice | freezing water | open water |

Each TileSet is one **Match Sides** terrain set with **six terrains, one tile
each** — the six ground kinds, in the same order in every theme, so one map fits
all four. Sheets are 3×2 cells: 48×32 for 16px, 96×64 for 32px. No tile has a
side peering bit: these tiles do not change with their neighbours, so the
terrain painter puts exactly the kind you ask for in every cell, whatever is
next to it.

## The five layers

Declared in this order, with these names and types, on every TileSet — and
**written on every tile, including the `false`s and the `0`s**:

| # | layer | type | what it is for |
|---|---|---|---|
| 0 | `ground` | String | the kind's name, e.g. `"shallow_water"` — for gameplay rules and UI |
| 1 | `move_cost` | float | the weight for `AStarGrid2D.set_point_weight_scale()`; 1.0 on the path, never below 1.0 |
| 2 | `walkable` | bool | `false` → `set_point_solid()` |
| 3 | `damage` | int | hit points per step; 0 everywhere but the hazard |
| 4 | `footstep` | String | a sound key, never empty |

The values, per theme (path / ground / rough / slow / hazard / blocked):

| theme | `move_cost` | `damage` | `walkable = false` on | `footstep` |
|---|---|---|---|---|
| Meadow  | 1.0 / 1.5 / 2.0 / 4.0 / 3.0 / 10.0 | thorns 2 | deep water | gravel, grass, sand, splash, leaves, swim |
| Volcano | 1.0 / 1.5 / 2.5 / 4.0 / 8.0 / 10.0 | lava 10 | chasm | stone, ash, gravel, splash, sizzle, none |
| Swamp   | 1.0 / 1.5 / 3.0 / 4.0 / 5.0 / 10.0 | poison bog 3 | deep bog | wood, grass, mud, splash, splash, swim |
| Snow    | 1.0 / 2.0 / 3.0 / 1.5 / 6.0 / 10.0 | freezing water 4 | open water | stone, snow, snow, ice, splash, swim |

Why write the zeros: Godot reads a value that was never written as the type's
default — `""`, `0.0`, `false`, `0` — so through the API a tile nobody filled in
and a tile whose damage really is 0 look exactly the same. Every value in this
pack is written on purpose; the generator refuses to write a TileSet where any
tile leaves a layer out.

## Use it (3 steps, ~20 seconds)

1. Copy **both** files of one entry — the `.png` **and** the `.tres` — into your
   project, any folder. They must land in the *same* folder: the `.tres` points at
   the PNG by filename, on purpose, so the pair works wherever you put it.
2. Let the editor import the PNG (it does this by itself when the Godot window
   regains focus). Don't copy any `.import` file from here — Godot writes its own.
3. Set a `TileMapLayer`'s `TileSet` to the `.tres`, open the **TileMap** panel →
   **Terrains** tab, and paint. Select a tile in the TileSet editor to see (and
   change) its five values under **Custom Data**.

No plugin needed for this pack. Needs Godot **4.3 or newer** (`TileMapLayer`).

### Reading the ground under the player, and an A* grid from the tiles

`tile_data_example.gd` in this folder does both; the gate runs it. The core of it:

```gdscript
@export var layer: TileMapLayer

func tile_data_at(global_pos: Vector2) -> TileData:
    # to_local() first: local_to_map() takes the layer's own coordinates
    return layer.get_cell_tile_data(layer.local_to_map(layer.to_local(global_pos)))

func build_astar() -> AStarGrid2D:
    var grid := AStarGrid2D.new()
    grid.region = layer.get_used_rect()
    grid.cell_size = Vector2(layer.tile_set.tile_size)
    grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
    grid.update()   # region, cell_size and mode first: update() resets the points
    for y in range(grid.region.position.y, grid.region.end.y):
        for x in range(grid.region.position.x, grid.region.end.x):
            var cell := Vector2i(x, y)
            var td := layer.get_cell_tile_data(cell)
            if td == null:                       # nothing painted here
                grid.set_point_solid(cell, true)
                continue
            grid.set_point_solid(cell, not td.get_custom_data("walkable"))
            grid.set_point_weight_scale(cell, td.get_custom_data("move_cost"))
    return grid
```

`step_at(global_position)` in the example returns `speed` (1 / `move_cost`),
`damage`, `footstep` and `walkable` for a body standing there, and
`path_between(grid, from, to)` turns a grid path back into world positions.

## The ways it goes wrong without a word — measured

Every line here is a check in `verify_tiledata_pack.gd`, and passes on Godot 4.3,
4.4 and 4.7 with the same numbers.

* **`local_to_map(global_position)` on a layer that is not at the origin.** On a
  layer moved to (123.5, −47) and scaled 3×, passing `global_position` straight to
  `local_to_map()` found the right cell for **0 of 160** cell centres;
  `local_to_map(to_local(global_position))` found it for 160 of 160.
* **An empty or erased cell has no `TileData`.** `get_cell_tile_data()` returns
  `null` there — check `td == null` before calling `.get_custom_data()` on it.
* **A misspelled layer name returns `null`, not `0.0`.** `get_custom_data("move_cst")`
  prints one `ERROR: TileSet has no layer with name` and hands back `null`;
  `tile_set.get_custom_data_layer_by_name(name)` returns `-1` without printing
  anything, so that is the way to ask first. `TileData.has_custom_data()` exists
  on 4.4 and 4.7 but **not on 4.3**.
* **A tile added after the layers were filled — or a new alternative (a flip) of a
  filled tile — reads `["", 0.0, false, 0, ""]`**, and the added tile has no
  terrain. Nothing warns: to your game it is a free (cost 0), unwalkable, nameless ground.
* **A `move_cost` of `0.0` is accepted by `set_point_weight_scale()` with no error,
  and the path stops being the cheapest.** On a 5×3 grid with the middle row at
  weight 0, A* still returned the straight 5-cell top row, costing 4.0, while the
  route along the free row costs 1.0: below 1.0 the default heuristic
  overestimates. Every `move_cost` in this pack is ≥ 1.0 for that reason.
* **Without the data, A* knows nothing about the tiles.** The same grid with no
  data fed in is a straight 14-cell line that walks across 2 `walkable = false`
  cells. Fed `walkable` only, it takes an 18-cell way through the ford and across 3
  hazard cells (cost 35.5 on meadow). Fed both, it takes the 20-cell road over the
  bridge at 19.5 — the true minimum; a Dijkstra over the same data finds the same.
* **The grid is a copy.** Paint the bridge as deep water and the old grid still
  returns the old path, across 2 now-blocked cells. Refeed those 2 cells from
  `get_cell_tile_data()` and it goes by the ford at 33.0, the new minimum.
* **Change the grid's `region` and `update()` wipes it** — every point back to
  walkable, weight 1.0. `update()` with the same region keeps them. Refeed the
  whole grid after the map grows.
* **`AStarGrid2D`'s default `diagonal_mode` is `ALWAYS`**: between two solid cells
  that touch only at a corner it returns the 2-cell diagonal. `DIAGONAL_MODE_NEVER`
  finds no path there.
* **Custom data is per tile, not per cell.** `set_custom_data()` on the `TileData`
  of ONE cell changed all 103 cells painted with that tile, and the TileSet's own
  tile. Keep per-cell state (a burnt patch, a trodden path) in a `Dictionary`.
* **Layer ids are positions, names are not.** `get_custom_data_by_layer_id(1)` is
  `move_cost` — until layer 0 is removed; then id 1 returns `walkable`'s `true`
  while the name still returns `move_cost`'s 1.0.
* **A value of the wrong type is stored as that type.** `set_custom_data("move_cost", "7")`
  stores a String with no error. Saved and loaded again, `"7"` comes back as the
  float `7.0` — but `"no"` set on the bool `walkable` layer comes back `null`.
* **Leaving out the 4th argument of `set_cells_terrain_connect` is harmless here.**
  With or without it, all 160 cells of the test map came out the kind they were
  asked for — with every side empty, the argument has nothing to decide.

## Check your own TileSet: `check_tileset_custom_data.gd`

```
godot --headless --script check_tileset_custom_data.gd -- res://tiles/my_tiles.tres
godot --headless --script check_tileset_custom_data.gd -- res://tiles/my_tiles.tres --scripts res://
```

Exit 0 and `CUSTOM-DATA-CHECK OK`, or exit 1 and one line per fault. With
`--scripts DIR` it also reads every `.gd` under `DIR` and collects the layer
names your code passes as a quoted literal to `get_custom_data()` /
`set_custom_data()`. It reports:

| fault | what it means |
|---|---|
| `NO-CUSTOM-DATA` | the TileSet declares no custom data layer at all |
| `LAYER-NO-TYPE` | a layer whose type is Nil — the type a layer added from code starts with. Every tile reads `null` from it |
| `LAYER-UNNAMED` | a layer with an empty name, reachable only by id — `add_custom_data_layer()` creates it that way |
| `TYPE-MISMATCH` | a tile's value is not of the layer's type — a value Godot could not convert to it loads as `null` |
| `TILE-UNFILLED` | a tile or alternative with every layer at its default while other tiles are filled — added after the layers |
| `EMPTY-STRING` | a String layer left `""` on a tile that is otherwise filled in |
| `NAME-NOT-DECLARED` | (`--scripts`) your code asks for a layer name no TileSet checked declares: that call returns `null` |

It also prints, without counting them as faults, how many tiles sit at each
layer's default (`DEFAULTS` — a `move_cost` of 0.0 is the one to look for), tiles
with no terrain, and layers no script reads. Run it in CI over every TileSet in
your project.

## What "measured" means here

Counting lines in a `.tres` proves nothing: a value can be written under a layer
index that is not the one you think, or in a type Godot converts on load. So the
gate for this pack (`verify_tiledata_pack.sh`) paints a 16×10 map — a river of the
blocked kind down the middle, a ford of the slow kind at the top, a road of the
path kind crossing it on a bridge at the bottom, a hazard patch on the straight
line between the start `(1,5)` and the goal `(14,5)` — into a real `TileMapLayer`,
reads every cell back through `get_cell_tile_data()`, runs `tile_data_example.gd`
against it and builds the grids above. **161 of 161 claims pass on Godot 4.3, 4.4
and 4.7**: 19 per TileSet over all eight, plus 9 traps measured once — the list
above, and that a layer added from code starts with type Nil and no name. The same run then points `check_tileset_custom_data.gd` at the eight
TileSets (0 faults over 48 tiles, and all 5 layer names found in the pack's own
script) and at TileSets and a script broken on purpose, where it must name every
fault planted.

## Files

* `meadow|volcano|swamp|snow_data_16|32px.png` + `.tres` — the eight TileSets.
* `tile_data_example.gd` — ground under a position, speed and damage for a body,
  an A* grid from the tiles. MIT.
* `check_tileset_custom_data.gd` — the checker, for your own TileSets. MIT.
* `verify_tiledata_pack.gd` / `verify_tiledata_pack.sh` — the gate above. Run
  `verify_tiledata_pack.sh /path/to/godot` to reproduce the 161 claims yourself;
  `--invert` makes it fail on purpose, so a green run means something.
* `manifest.json` — every kind's values and the test map, machine-readable.
* `tiledata_preview.png` — the picture above.

## Where this comes from

Part of the free packs from **Blobsmith**, a Godot 4 autotile wirer that turns
loose tiles into a paint-ready TileSet. The wirer, the free addon and the other
packs are at
<https://github.com/leobaray/blobsmith-autotile-wirer> and
<https://blobsmith.itch.io/blobsmith-lite>.

MIT — see `LICENSE.txt`.
