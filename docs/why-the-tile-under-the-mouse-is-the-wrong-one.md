# The tile under the mouse is the wrong one — what `local_to_map` actually takes

You click a tile and a different one changes. Maybe it is one cell up and to the
left, maybe it is fine at the top-left of the screen and drifts the further you
go, maybe it broke the moment you added a `Camera2D` with zoom, or it only goes
wrong left of the origin.

`local_to_map()` is not broken in any of those cases. Every one is a coordinate
you handed it in the wrong space, and the engine gives no warning, because any
`Vector2` is a valid argument. This page measures what it does with each wrong
one. Every claim has an id (`M4`, `K2`, …) and is asserted by
[`verify_mouse_to_cell.gd`](verify_mouse_to_cell.gd) against a real binary:

```
docs/verify_mouse_to_cell.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 33
checks, 33/33 on each, three of them controls that fail if the check stops
telling right from wrong. Last run **2026-09-13**. Needs 4.3 or newer —
`TileMapLayer` does not exist in 4.2.

---

## The short answer

```gdscript
# in any script, for a mouse position you read yourself:
var cell := layer.local_to_map(layer.get_local_mouse_position())

# in _input / _unhandled_input, for the event you were handed:
var cell := layer.local_to_map(layer.make_input_local(event).position)
```

Both are correct under a camera, a moved layer, a scaled layer and a rotated
parent (`M7`, `M8`). Everything below is what goes wrong with the other
versions people write.

## `local_to_map` wants the layer's own coordinates

The name says it and it is still the most common bug. The argument is in the
**layer's local space**, not world space and not screen space.

| id | what you pass | cell you get | cell under the pointer |
|----|---------------|--------------|------------------------|
| `M4` | layer at `(100,50)`, world `(120,60)` passed raw | `(7,3)` | `(1,0)` |
| `M5` | layer scaled 2×, world `(40,0)` passed raw | `(2,0)` | `(1,0)` |
| `M6` | parent rotated 90°, `pos - layer.global_position` | `(0,1)` | `(1,0)` |

`M4` is the "off by a fixed amount" symptom and `M5` the "fine near the origin,
drifts further out" one. `M6` is the fix people reach for after `M4`:
subtracting `global_position` undoes the offset and nothing else, so it breaks
the day a parent is scaled or rotated. `to_local()` handles all three.

The reverse trip has the same shape: `map_to_local()` returns a **local**
position (`M5`: `(24,8)` on the 2× layer), which is `(48,16)` in the world only
after `to_global()`. Put a sprite at the unconverted value and it lands in the
wrong place by exactly the layer's transform.

## The camera is not in the node's transform

A `Camera2D` does not move your nodes. It moves the **canvas transform** of the
viewport (`M7`: origin = viewport centre − camera position × zoom), and the
positions in a mouse event are viewport pixels, before that transform.

| id | how the event position is converted | result under zoom 2, camera at `(200,0)` |
|----|--------------------------------------|------------------------------------------|
| `M7` | `event.position` passed raw | a cell near the top-left of the **screen**, not the world |
| `M7` | `layer.make_input_local(event).position` | the cell under the pointer |
| `M7` | `layer.to_local(get_canvas_transform().affine_inverse() * event.position)` | the same cell |

So `to_local(event.position)` is still wrong: it fixes the layer and skips the
camera. `make_input_local()` does both.

`get_global_mouse_position()` already includes the camera (`M8`), and
`get_local_mouse_position()` is exactly `to_local()` of it, measured with a
camera, an offset and a scale at once. `K2` is the control: in that setup the
global and local positions really differ, so `M8` is not passing because the two
happen to coincide.

**A layer under a `CanvasLayer`** — a HUD grid, an inventory — is not moved by
the camera at all, and `make_input_local()` knows it (`M9`: same cell as the raw
position). Converting that one through the camera by hand is the bug in the
other direction.

## Negative coordinates: do not divide by the tile size yourself

`local_to_map()` **floors** (`M1`): `(15.9,0)` is cell `(0,0)`, `(16,0)` is
`(1,0)`, `(-1,-1)` is `(-1,-1)` and `(-16.1,0)` is `(-2,0)`.

The hand-rolled `Vector2i(pos / 16)` **truncates toward zero** (`M2`): `(-1,-1)`
becomes `(0,0)`. That is the bug that only exists left of and above the origin —
row and column 0 are twice as wide as every other one. `K1` is the control:
`(pos / 16).floor()` gives `(-1,-1)`. Better still, do not write it — it is also
wrong for every non-square shape below.

## `map_to_local` returns the centre

`map_to_local(Vector2i(0,0))` is `(8,8)` on a 16×16 grid, not `(0,0)` (`M3`).
Snapping something to "the tile's position" with it puts it in the middle of the
cell; subtract half of `tile_set.tile_size` if you meant the corner. A
highlight rectangle drawn at that position without the subtraction sits half a
tile down and right of the cell the click resolved to.

## Isometric and hexagon grids

Here even a correct conversion into local space gives confusing numbers if you
expect the square-grid picture.

- **Local `(0,0)` is cell `(-1,-1)`** on a 64×32 isometric layer, and cell
  `(0,0)` is centred at `(32,16)` (`M10`). The top-left corner of the bounding
  box belongs to the diamond above and to the left.
- `(0,17)` is cell `(-1,1)`; `floor(pos / tile_size)` says `(0,0)` for the same
  point (`K3`). Dividing by the tile size is not an approximation of an
  isometric pick — it is a different grid.
- **A new `TileSet` is `TILE_LAYOUT_STACKED`** (`M11`), so row 1 is not below
  row 0 diagonally: `map_to_local(0,1)` is `(64,32)` and `(1,1)` is `(128,32)`.
  If you expected a diamond-shaped map with `(0,1)` down-left, that is the
  `tile_layout` property, not a picking bug.
- `local_to_map(map_to_local(c)) == c` holds for every isometric cell tested,
  including negative ones (`M12`). The engine's two functions agree with each
  other; only a hand-written formula can disagree with them.
- Hexagons are stacked the same way: on a 16×16 hexagon layer,
  `map_to_local(0,1)` is `(16,20)`, half a tile right of row 0 (`M12`).

## Checklist, in the order it usually goes wrong

1. Passing a world or screen position straight into `local_to_map` → `M4`/`M5`.
2. Subtracting `global_position` instead of `to_local()` → `M6`.
3. `event.position` or `to_local(event.position)` under a `Camera2D` → `M7`.
4. Converting a `CanvasLayer` grid through the camera → `M9`.
5. `Vector2i(pos / tile_size)` with negative coordinates → `M2`.
6. Treating `map_to_local` as the corner → `M3`.
7. A square-grid formula on an isometric or hexagon grid → `M10`–`M12`.

## What this file does not measure

- Window stretch modes (`canvas_items`, `viewport`) and `SubViewport`s. The
  events here are delivered to the root viewport at a 1:1 window scale; a
  `SubViewportContainer` passes its own transformed events and is not covered.
- The legacy `TileMap` node. It has `local_to_map` too; nothing on this page was
  run against it.
- Where a tile with a non-zero `texture_origin` or a Y-sorted offset is **drawn**.
  Picking uses the grid only; if the art is drawn away from its cell, the click
  resolves to the cell, not to the art.
- `DIAMOND_*` tile layouts beyond the default `STACKED` one.
