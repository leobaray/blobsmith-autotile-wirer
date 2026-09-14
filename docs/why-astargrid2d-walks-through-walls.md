# AStarGrid2D walks through my walls (or finds no path at all) — what the engine does

You built an `AStarGrid2D` for your `TileMapLayer`, marked the walls solid, and
the character walks straight through them. Or slips diagonally between two wall
tiles. Or `get_id_path` returns `[]` and the output says "out of bounds". Or the
path is right but the character walks along the tile corners, a few pixels off.
Or the isometric map paths through nonsense.

`AStarGrid2D` knows nothing about your layer. It is a rectangle of points with
its own size, its own origin and its own shape, and each of those has to be
told to match the layer by hand. The traps are in *when* you tell it: `update()`
rebuilds the grid from scratch and throws away every solid and weight you set
before it. This page measures each part. Every claim has an id (`U2`, `D1`, …)
and is asserted by [`verify_astar_grid.gd`](verify_astar_grid.gd) against a real
binary:

```
docs/verify_astar_grid.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 45
checks, 45/45 on each; two of them (`P5`, `P6`) expect different results per
version, and one (`K1`) is a control that fails when `LG_SELFTEST=1` flips it,
and the runner exits 1. Last run **2026-09-14**. Needs 4.3 or newer for the
`TileMapLayer` checks. Runs on `--headless`.

---

## The short answer

```gdscript
var astar := AStarGrid2D.new()
astar.region = layer.get_used_rect()                 # C1, C2
astar.cell_size = layer.tile_set.tile_size           # C4
astar.offset = layer.tile_set.tile_size / 2.0        # C6: centre, like map_to_local
astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES  # D1, D2
astar.update()                                       # BEFORE any set_point_solid (U2)

for cell in layer.get_used_cells():
	var data := layer.get_cell_tile_data(cell)
	if data and data.get_custom_data("solid"):
		astar.set_point_solid(cell)

var path := astar.get_point_path(from_cell, to_cell)  # layer-local positions (C7)
```

Any later change to `region`, `cell_size` or `offset` needs another `update()`,
and that `update()` wipes the solids again (`U6`, `U9`) — run the
`set_point_solid` loop after it every time.

---

## 1. A new grid has no cells

| id | measured |
|----|----------|
| R1 | `region` starts as `Rect2i(0, 0, 0, 0)` — zero points |
| R2 | `cell_size` starts as `(1, 1)`, so positions come out in cells, not pixels |
| R3 | `get_id_path` on that grid returns `[]` |
| E1 | ...and prints `Can't get id path. Point (0, 0) out of bounds [P: (0, 0), S: (0, 0)]` |
| R4 | `diagonal_mode` starts as `DIAGONAL_MODE_ALWAYS` |
| P8 | a target outside `region` also returns `[]` with the same error |

If the error shows `S: (0, 0)`, the region was never set. If it shows a size,
the point is outside it — see section 5 for negative cells.

## 2. `update()` throws away every solid and weight

This is the one that makes the walls disappear.

| id | measured |
|----|----------|
| U1 | setting `region` marks the grid dirty (`is_dirty()` true) |
| E2 | `set_point_solid` on a dirty grid prints `Grid is not initialized. Call the update method.` |
| U2 | ...and after `update()` that point is **not** solid |
| U3 | `update()` clears the dirty flag |
| U4 | a solid set **after** `update()` sticks |
| U5 | changing `region` again marks it dirty |
| U6 | the next `update()` wipes the solid set in U4 |
| U7 | ...and resets weight scales to 1 |
| U8 | changing `cell_size` marks it dirty |
| U9 | ...and its `update()` wipes solids too |
| U10 | changing `offset` marks it dirty |
| U11 | changing `diagonal_mode` does **not** — no `update()` needed for it |
| U12 | an unpainted cell inside the region is walkable: every point starts non-solid |
| U13 | `fill_solid_region(region)` marks every point solid and does not mark the grid dirty |

U12 matters when the map has holes: `get_used_cells()` only gives you painted
cells, so a void cell inside `get_used_rect()` is floor to the pathfinder. If
the void is not walkable, mark it solid too, or fill the region solid first with
`fill_solid_region(astar.region)` and clear the floor cells.

Resizing the grid when the map grows (`region = layer.get_used_rect()` again)
is the usual way to hit U6 in a running game.

## 3. Diagonals squeeze between walls by default

| id | measured |
|----|----------|
| D1 | `ALWAYS`: with `(1, 0)` and `(0, 1)` solid, `(0, 0) → (1, 1)` is `[(0, 0), (1, 1)]` — through the corner where two walls touch |
| D2 | `ONLY_IF_NO_OBSTACLES`: the same query returns `[]` |
| D3 | `AT_LEAST_ONE_WALKABLE`: with only `(1, 0)` solid, it still cuts the corner |
| D4 | `ALWAYS` on an open grid walks `(0, 0) → (3, 3)` as a pure diagonal |

`ONLY_IF_NO_OBSTACLES` keeps diagonals in open space and
refuses them next to any solid. `NEVER` gives 4-way movement.

## 4. Solid ends, walls, and partial paths

Grid: 5×3, 4-way, column `x = 2` solid top to bottom.

| id | measured |
|----|----------|
| P1 | target behind the wall: `[]` |
| P2 | `get_id_path(from, to, true)` (`allow_partial_path`): `[(0, 1), (1, 1)]`, the closest reachable cell |
| P3 | target cell itself solid: `[]` |
| P4 | `get_point_path` to a solid target: empty too |
| P5 | solid target with `allow_partial_path = true`: **4.3 returns `[]`; 4.4 and 4.7 return `[(0, 1), (1, 1)]`** |
| P6 | solid **start**: **4.3 and 4.4 still return a path out of it; 4.7 returns `[]`** |
| P7 | `from == to` returns that one cell |

P6 is the one that changes under you on upgrade. A unit standing on a cell that
becomes solid — a door closing on it, a building placed under it — could walk
off in 4.4 and freezes in 4.7. If units can stand on solid cells, clear the
start cell's solid flag for the query and restore it after. (Versions between
4.4 and 4.7 were not measured; the script prints a `NOTE` there instead of
asserting.)

"Click on a wall and walk as close as you can" needs P5, which 4.3 does not do:
on 4.3, pick a walkable neighbour of the target yourself.

## 5. Positions: corner not centre, layer-local not global

Layer at `position (100, 50)`, 16×16 tiles, cells painted at `(-3, -2)` and `(1, 1)`.

| id | measured |
|----|----------|
| C1 | `get_used_rect()` is `Rect2i(-3, -2, 5, 4)` — starts at the negative cell; size is exclusive |
| C2 | with `region = get_used_rect()`, `(1, 1)` is in bounds |
| C3 | negative cells have negative positions: `(-3, -2)` → `(-48, -32)` |
| C4 | with `offset` 0, `(1, 1)` → `(16, 16)`: the **top-left corner** |
| C5 | `map_to_local((1, 1))` is `(24, 24)`: the **centre** |
| C6 | `offset = cell_size / 2` makes `get_point_position` equal `map_to_local` |
| C7 | both are layer-local: the node that has to stand there is at `to_global(...)` = `(124, 74)` |
| K1 | control: `map_to_local((1, 1))` is not the corner |

A character following C4 points walks along tile corners — half a tile up and
left. A character following C6 points without C7 is off by the layer's
position. Converting each point with `layer.to_global(p)` fixes both; if the
character is a child of the layer, the local points are already right.

## 6. Isometric: the TileSet layout must match `cell_shape`

64×32 isometric TileSet; each layout compared with each `cell_shape`, offset 0
and offset `(32, 16)`, on every cell of `(-3..4, -3..4)`.

| id | measured |
|----|----------|
| I1 | a new isometric TileSet has `tile_layout = STACKED` |
| I2 | `STACKED` matches **no** `AStarGrid2D` shape, with either offset |
| I2 | `DIAMOND_RIGHT` matches `CELL_SHAPE_ISOMETRIC_RIGHT` with offset 0 |
| I2 | `DIAMOND_DOWN` matches `CELL_SHAPE_ISOMETRIC_DOWN` with offset 0 |

So on a `STACKED` isometric map the positions the grid returns are not where
the layer draws those cells. Pick a `DIAMOND_*` layout before painting a map you
pathfind with `AStarGrid2D`, and set the matching `cell_shape`. Unlike the
square case, do **not** add a half-tile offset for the diamond layouts: with
offset 0 the positions already equal `map_to_local`, which is the centre.

## 7. Weights

| id | measured |
|----|----------|
| W1 | 3×3 open grid, 4-way: `(0, 1) → (2, 1)` goes straight through `(1, 1)` |
| W2 | with `set_point_weight_scale((1, 1), 10)`, the path goes around it (5 cells) |

Weights are wiped by `update()` exactly like solids (`U7`).

---

## Reproduce

```
docs/verify_astar_grid.sh /path/to/godot   # 45 checks; exit 0 = all pass
LG_SELFTEST=1 docs/verify_astar_grid.sh /path/to/godot   # must exit 1 (K1 flipped)
```

The `.gd` builds its own grids, TileSets and layers in memory; nothing from your
project is read. If a claim fails on your version, the line tells you which one
and what the engine returned.
