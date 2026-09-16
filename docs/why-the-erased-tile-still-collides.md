# I erased the tile and it still collides — `erase_cell` and the physics body it leaves behind

You are making a mining or destructible-terrain game. The player breaks a tile,
you call `erase_cell()`, the tile disappears from `get_cell_source_id()` — and on
that same frame the player still stands on it, the pickaxe raycast still hits
it, and `move_and_collide` still stops at it.

You found the tile with
[which tile did the player hit?](why-the-tile-you-hit-is-the-wrong-one.md); this
page is about removing it.

Every claim below has an id (`S1`, `U3`, …) and is asserted by
[`verify_erased_tile.gd`](verify_erased_tile.gd) against a real binary, except
`X1`–`X3`, which count the engine's error lines and are asserted by the wrapper:

```
docs/verify_erased_tile.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, headless:
24 checks on each (21 in the script, 3 in the wrapper), all passing. `K1` and
`K2` are controls, and `--invert` flips `S1` and `U3` on purpose: it exits 1 on
all three. A GDScript parse error exits 3, not 0. Last run **2026-09-16**. Needs
4.3 or newer — `TileMapLayer` does not exist in 4.2.

The test: 16×16 tiles, one with a full-square collision polygon and one with
none. A floor of eight solid tiles, cells `(0,5)`..`(7,5)`, plus one solid tile
at `(20,5)` — on 4.7 that is the next 16×16 physics quadrant. The erased cell is
`(3,5)`. "Does it still collide" is asked four ways: `intersect_ray` through the
cell centre, `intersect_point` at the centre, a `RayCast2D` with
`force_raycast_update()`, and a `CharacterBody2D` `move_and_collide()` 40 px down
into the cell.

---

## The fix

```gdscript
func mine(layer: TileMapLayer, cell: Vector2i) -> void:
    layer.erase_cell(cell)
    layer.update_internals()   # the collision is gone on this line, not at the end of the frame
```

After `update_internals()`, all four questions miss the erased cell on the same
line (`U1`), and `move_and_collide` still stops on the neighbours (`U2`). The
same goes for `set_cell()` to a tile without collision (`S3`). Mining many tiles
at once, erase them all and call `update_internals()` once: eight erases and one
update, 0 of 8 sweeps collide (`M1`).

Two things to know before you rely on it:

- **On 4.7, raycasts in the same frame miss the neighbours too** (`U3`). See
  below. If you raycast again right after mining — a pickaxe that hits the tile
  behind, a ground check — wait one `physics_frame` first (`F3`).
- **Inside `Area2D.body_shape_entered` on 4.7, `update_internals()` prints two
  errors** (`X1`). It still works (`C1`). If you don't need the change on that
  frame, call `erase_cell()` alone there: no error on any version (`X3`).

If the tile is a scene tile, the node is late the same way —
[why my scene tile is not there](why-my-scene-tile-is-not-there.md) (`E1`, `E2`)
measured it; this page is about collision only.

## Same frame, no `update_internals()`: the tile is gone, the body is not

| id | measured, all three versions |
|----|------------------------------|
| `K1` | control: before the erase, ray, point, `RayCast2D` and `move_and_collide` all hit `(3,5)` and `(2,5)` |
| `K2` | control: a cell never painted is a miss on all four |
| `S1` | right after `erase_cell`, `get_cell_source_id()` is **-1**, and ray, point and `RayCast2D` still hit the cell |
| `S2` | `move_and_collide` into it on the same frame still collides |
| `S3` | `set_cell()` to a tile with no collision polygon: same — still hits on the same frame, misses after `update_internals()` |
| `F1` | without `update_internals()`, rays see the erase after exactly **1** `process_frame` (20/20 trials) |
| `F2` | … and after exactly **1** `physics_frame` (20/20 trials) |
| `F5` | an enabled `RayCast2D` over the cell, erase made while `physics_frame` is emitted: `is_colliding()` is still **true on the next physics frame**, false on the one after |

The layer applies cell changes in a deferred update at the end of the frame.
`erase_cell()` only changes the map; the physics body goes when that update
runs, or when you call `update_internals()`.

## With `update_internals()`

| id | measured, all three versions |
|----|------------------------------|
| `U1` | on the same line, ray, point, `RayCast2D` and `move_and_collide` all miss the erased cell |
| `U2` | `move_and_collide` still collides with `(2,5)`, `(4,5)` and `(20,5)` |
| `U4` | after erase + `update_internals()`, one `test_move()` call 1000 px away and rays hit 7 of the 8 floor cells (below) |
| `U5` | a tile **placed** with `set_cell` + `update_internals()`: `move_and_collide` hits it, ray, point and `RayCast2D` do **not** until the next frame |
| `F6` | the enabled `RayCast2D` over the erased cell is false on the very next physics frame |
| `C1` | `erase_cell` + `update_internals()` inside `Area2D.body_shape_entered` works: the sweep misses `(3,5)`, hits `(2,5)`, and 5 frames later the floor is right |
| `M1` | eight erases and one `update_internals()`: 0 of 8 sweeps collide, the far tile still does |

`U5` looks like the same effect behind the 4.7 difference: a body the layer has **just created** is
invisible to `intersect_ray`, `intersect_point` and `RayCast2D` until the next
frame, while `move_and_collide` sees it at once. On 4.3/4.4 erasing a tile only
removes a body (8 → 7, `R1`). On 4.7 it replaces the chunk's body with a new one (`R1`).

## Per version: 4.3/4.4 remove one body, 4.7 rebuilds the chunk

| | 4.3 | 4.4 | 4.7 |
|-|-----|-----|-----|
| `physics_quadrant_size` | does not exist (`R1`) | does not exist (`R1`) | exists, default **16** (`R1`) |
| bodies for the 8-tile floor, before → after the erase | 8 → 7; neighbour keeps its RID (`R1`) | 8 → 7; neighbour keeps its RID (`R1`) | **1 → 1, with a new RID**; the tile in the next quadrant keeps its RID (`R1`) |
| shape index along the floor after the erase | every tile shape 0 of its own body (`R2`) | same (`R2`) | the floor was one shape 0; now `(0..2,5)` is shape 0 and `(4..7,5)` shape 1 (`R2`) |
| ray, point, `RayCast2D` on the **neighbours** right after `update_internals()` | hit (`U3`) | hit (`U3`) | **miss** — `(2,5)` and `(4,5)`; `(20,5)` in the next quadrant still hits (`U3`) |
| rays hitting the 8-cell floor right after `update_internals()` | 7 (`U4`) | 7 (`U4`) | **0** (`U4`) |
| frames until rays see the floor right, with `update_internals()` | **0** (20/20 each for `process_frame` and `physics_frame`, `F3`) | **0** (`F3`) | **1** `process_frame` or **1** `physics_frame` (20/20 each, `F3`) |
| a `call_deferred()` query after `erase_cell` (it runs after the layer's own update) | 7 of 8 floor cells hit (`F4`) | 7 of 8 (`F4`) | **0 of 8** (`F4`) |
| enabled `RayCast2D` over the neighbour, erase + `update_internals()` from `physics_frame` | true, true, true (`F6`) | true, true, true (`F6`) | **false**, true, true (`F6`) |
| `erase_cell` + `update_internals()` in `body_shape_entered` | no error (`X1`) | no error (`X1`) | 2× `Can't change this state while flushing queries` — and it still works (`X1`, `C1`) |

So on 4.7 a ground-check `RayCast2D` standing on the neighbouring tile reports
**not colliding for one physics frame** when you mine next to it with
`update_internals()` (`F6`). Without `update_internals()` it does not flicker:
`true, true, true` on all three (`F5`). `move_and_collide` is never affected
(`U2`).

`U4` shows why: after one `test_move()` call, even 1000 px away, the rays see
the rebuilt body again. That is an observation, not an API to build on;
waiting one physics frame (`F3`) is the plain way.

## RIDs you stored are dead

`get_coords_for_body_rid()` with the erased tile's old RID returns `(0,0)` and
prints `Parameter "found" is null` (`R3`, `X2`), on all three versions. On 4.7
a live neighbour's RID also returns `(0,0)` — that is its chunk
([tile-hit page](why-the-tile-you-hit-is-the-wrong-one.md)) — so on 4.7 a dead
RID and a live one in chunk `(0,0)` give the same answer, and every stored RID
of the rebuilt chunk is stale (`R1`).

---

## Checklist

1. `erase_cell()` changes the map now and the collision at the end of the frame
   (`S1`, `S2`, `F1`).
2. Need it gone this frame: `update_internals()` right after (`U1`); batch many
   erases before one call (`M1`).
3. On 4.7, don't raycast the same chunk on the same frame after
   `update_internals()` — wait one `physics_frame` (`U3`, `F3`, `F6`).
4. In `body_shape_entered`, `erase_cell()` alone is error-free everywhere; adding
   `update_internals()` prints two errors on 4.7 (`X1`, `X3`).
5. Don't keep collider RIDs across a mine (`R1`, `R3`).

## Run it yourself

```
docs/verify_erased_tile.sh /path/to/godot             # 24 PASS (21 in the script + X1-X3), exit 0
docs/verify_erased_tile.sh /path/to/godot --invert    # 2 FAIL, exit 1
```

## What this file does not measure

- One-way collision tiles — the two 4.7 errors come from the one-way-collision
  setter, so they may matter there; untested.
- `RigidBody2D`, `Area2D` overlap lists, and `move_and_slide` / `is_on_floor()`
  of a body standing next to the mined tile.
- `physics_quadrant_size` other than the default 16 on 4.7, and 4.5 and 4.6.
- Physics run on a separate thread, Jolt, or non-headless builds.
- Frame counts outside a headless run: 1 frame was the answer on 20/20 trials
  here, which is not a promise.
- The time `update_internals()` costs on a large layer.

MIT, from <https://github.com/leobaray/blobsmith-autotile-wirer>.
