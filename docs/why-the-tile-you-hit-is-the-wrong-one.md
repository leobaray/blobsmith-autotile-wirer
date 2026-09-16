# Which tile did the player hit? — why `local_to_map(collision point)` gives the neighbour

Your `CharacterBody2D` runs into a tile, you want to know **which** tile (to
break it, damage the player, read its data), and you write the obvious line:

```gdscript
var col := move_and_collide(velocity * delta)
var cell := layer.local_to_map(layer.to_local(col.get_position()))
```

Sometimes it is right. Hit the tile from below or from the right and it is the
**empty cell next to it**, every time. And on Godot 4.7 the other obvious
answer, `get_coords_for_body_rid()`, returns a chunk index instead of a cell.

Every claim below has an id (`N1`, `R2`, …) and is asserted by
[`verify_tile_hit.gd`](verify_tile_hit.gd) against a real binary:

```
docs/verify_tile_hit.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, headless:
17 checks on 4.3 and 4.4, 20 on 4.7 (the physics-quadrant checks only exist
where the property does), all passing. `K1`, `K2` and `Q1` are controls, and
`--invert` flips `N1` and `R2` on purpose: it exits 1 on all three. A GDScript
parse error exits 3, not 0. Last run **2026-09-16**. Needs 4.3 or newer —
`TileMapLayer` does not exist in 4.2.

The test: 16×16 tiles with one full-square collision polygon, one isolated tile
at cell `(20,20)`. A body starts 30 px away and `move_and_collide()`s toward the
tile's centre from 8 directions (above, below, left, right, four diagonals),
shifted sideways from −10 to +10 px in steps of 2: **88 approaches per shape**,
run with a 10×12 `RectangleShape2D` and a radius-5 `CapsuleShape2D`. The tile is
isolated, so whatever the body hit, it hit `(20,20)`, and every answer can be
scored.

---

## The pattern that got 88/88

```gdscript
const EPS := 0.5

func hit_cell(layer: TileMapLayer, col: KinematicCollision2D) -> Vector2i:
    # step half a pixel into the surface…
    var p := col.get_position() - col.get_normal() * EPS
    # …and if that is an empty cell, the contact was a tile corner: look around it
    for o in [Vector2.ZERO, Vector2(-EPS, 0), Vector2(EPS, 0), Vector2(0, -EPS), Vector2(0, EPS)]:
        var c := layer.local_to_map(layer.to_local(p + o))
        if layer.get_cell_source_id(c) != -1:
            return c
    return layer.local_to_map(layer.to_local(p))
```

Identical results on 4.3, 4.4 and 4.7, including 4.7's default 16×16 physics
quadrants (`F3`, `Q1`). The seam test below uses the same function on
`get_slide_collision(i)` after `move_and_slide()` (`S2`).

## The collider is the layer, not the tile

`col.get_collider()` is the `TileMapLayer` node on 88/88 hits for both shapes
(`C1`). There is no per-tile object to ask. The cell has to come from the
contact point or from the collider RID.

## The contact point sits on the edge — and the edge belongs to the next cell

A tile at cell `(20,20)` covers `x` 320..336. `local_to_map()` puts `336.0` in
cell `(21,20)`: the right and bottom edges of a tile belong to the cell after
it (`K1`, `N2`). The contact point is **on** the edge, so:

| approach | `local_to_map(get_position())` is the hit tile |
|----------|------------------------------------------------|
| from below | 0 of 11 (`N2`) |
| from the right | 0 of 11 (`N2`) |
| all 8 directions, rectangle | 37 of 88 (`N1`) |
| all 8 directions, capsule | 37 of 88 (`N1`) |

Every wrong answer is an **empty** neighbour cell — 51/51 for each shape,
`get_cell_source_id() == -1` (`N3`) — so the bug tends to look like "my tile
has no data" rather than "wrong tile".

## Minus the normal is most of the fix, not all of it

The usual advice, `get_position() - get_normal() * 0.5`, moves the point inside
the tile along the normal. It gets **72/88** with the rectangle and **81/88**
with the capsule (`F1`). Every one it still misses (16 and 7) is a contact point
exactly on a tile **corner** (`F2`): the normal moves the point along one axis
only, and a corner is on an edge in both. Probing half a pixel either way along each axis for a cell that holds a tile closes the gap:
88/88 for both (`F3`).

## `get_coords_for_body_rid()` is a chunk index on 4.7

The RID route — `layer.get_coords_for_body_rid(col.get_collider_rid())` — is
exact on 4.3 and 4.4 and wrong by default on 4.7:

| | 4.3 | 4.4 | 4.7 |
|-|-----|-----|-----|
| `physics_quadrant_size` property | does not exist (`R1`) | does not exist (`R1`) | exists, default **16** (`R1`) |
| RID → coords is the hit cell, 88-approach sweep | 88/88 (`R2`) | 88/88 (`R2`) | **0/88** — `(1,1)`, the 16×16 chunk, on 88/88 (`R2`) |
| tiles `(20,20)`, `(23,20)`, `(40,20)` | three bodies, three cells (`Q2`, `Q3`) | three bodies, three cells (`Q2`, `Q3`) | `(20,20)` and `(23,20)` are **one body** (same RID, shape index 0 and 1); coords `(1,1)`, `(1,1)`, `(2,1)` (`Q2`, `Q3`) |

So on 4.7, hitting two different tiles of the same chunk returns the same
coordinates, and neither is a cell. Setting `physics_quadrant_size = 1` brings
it back: 88/88 in the sweep (`P1`), and one body with its own cell per tile
(`P2`). On 4.3/4.4 the property is not there to set; the default already
behaves that way. The contact-point pattern above does not care either way.

## Standing on the seam between two floor tiles

A 10×12 body centred on the boundary between floor cells `(2,5)` and `(3,5)`,
under `move_and_slide()` with gravity, 30 frames recorded after landing:

- `is_on_floor()` on 30/30 frames, and `get_slide_collision_count()` is **1**
  on 30/30 — never one collision per tile (`S1`, all three versions).
- The contact-point pattern reports `(3,5)` on every frame (`S2`). You get one
  of the two tiles, not both.
- `get_coords_for_body_rid()` reports `(2,5)` on some frames and `(3,5)` on
  others on 4.3 and 4.4 (`S3`), and on 4.7 with `physics_quadrant_size = 1`
  (`P3`). On 4.7 with the default it is `(0,0)`, the chunk, on every frame
  (`S3`).

---

## Checklist

1. `get_collider()` is the layer; the cell comes from the point or the RID
   (`C1`).
2. Never `local_to_map(col.get_position())` raw — from below or the right it is
   the empty neighbour, every time (`N2`).
3. Minus the normal still misses tile corners; add the half-pixel probe (`F2`,
   `F3`).
4. `get_coords_for_body_rid()` on 4.7 → chunk, not cell, unless
   `physics_quadrant_size = 1` (`R2`, `P1`).
5. Standing on a seam gives one collision and one cell, not two (`S1`, `S2`).

## Run it yourself

```
docs/verify_tile_hit.sh /path/to/godot             # ALL PASS (17 checks on 4.3/4.4, 20 on 4.7), exit 0
docs/verify_tile_hit.sh /path/to/godot --invert    # 2 FAIL, exit 1
```

## What this file does not measure

- Tile shapes other than a full 16×16 square, one-way collision, or polygons
  that do not reach the tile's edges.
- Isometric or hexagon layouts, and layers that are scaled or rotated.
- Epsilons other than 0.5 px, or tiles other than 16 px.
- `RigidBody2D`, `Area2D` and raycasts — only `CharacterBody2D`'s
  `move_and_collide()` and `move_and_slide()`.
- 4.5 and 4.6: the quadrant rows were measured on 4.7 only.
- Which frames the RID route reports `(2,5)` vs `(3,5)` on a seam, only that
  both occur.
- The performance cost of `physics_quadrant_size = 1`.

MIT, from <https://github.com/leobaray/blobsmith-autotile-wirer>.
