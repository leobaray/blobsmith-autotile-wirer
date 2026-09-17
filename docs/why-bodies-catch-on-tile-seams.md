# My box gets stuck between two tiles — `RigidBody2D` catching on `TileMapLayer` seams

You push a crate across a floor painted with a `TileMapLayer`, and it stops dead
in the middle of the floor and will not move again. Or a ball rolling along the
same floor hops for no reason. Put the same crate on one `StaticBody2D` and it
slides fine.

This is the complaint behind
[#89458](https://github.com/godotengine/godot/issues/89458) ("Physics bodies can
collide with tile seams", where #93509, #72372 and #65204 were folded in) and
the still-open [#47148](https://github.com/godotengine/godot/issues/47148). The
threads disagree on whether Godot 4.5 fixed it and on what
`physics_quadrant_size` does. This page measures it.

Every claim below has an id (`B1`, `Q3`, …) and is asserted by
[`verify_seam_snag.gd`](verify_seam_snag.gd) against a real binary:

```
docs/verify_seam_snag.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, headless
with `--fixed-fps 60`: 8 checks on 4.3 and 4.4 and 13 on 4.7, all passing. `K1`
and `K2` are controls, and `--invert` flips `K1` and `B1` on purpose: it exits 1.
A GDScript parse error exits 3, not 0. Last run **2026-09-17**. Needs 4.3 or
newer — `TileMapLayer` does not exist in 4.2.

The test: 16×16 tiles, each with one full-square collision polygon, a floor of
62 of them, cells `(-2,10)`..`(59,10)` (top edge `y = 160`). The **box** is a
`RigidBody2D` with a 14×14 rectangle and `lock_rotation` on; the **ball** is a
radius-7 circle with rotation free. Each is placed on the floor, left 20 frames,
then given `linear_velocity.x = 120` every physics frame for 240 frames. The
**control** is one `StaticBody2D` with one 1000×16 rectangle at the same height.
Every other property is at its default.

---

## What happens

On **4.3 and 4.4** every cell with a collision polygon is its own physics body:
the 62-cell floor is **62 bodies** (`S1`). A flat floor made of 62 squares has 61
internal edges the box can catch on, and it does:

| id | push the box from | control (one `StaticBody2D`) | 4.3 / 4.4 tiles |
|---|---|---|---|
| `K1`, `B1` | x = 8 | ends at 421.9, 0 frames stalled | **stops at 25.2** (seam x = 32) |
| `B1` | x = 17.7 | — | **stops at 121.2** (seam x = 128) |
| `K1`, `B1` | x = 240 | ends at 653.9, 0 frames stalled | **stops at 345.2** (seam x = 352) |

Each time the box's leading edge is 0.2 px past a seam, and it **stays there**:
230, 180 and 179 of the 240 frames make no progress (`B2`). It does not catch on
every seam — it rode over the first few in each run — which is why it looks
random in a game. With the frame sequence fixed it is not random: the same run
stops at the same place every time.

The ball never stops, but the seams kick it upward — the first at x = 16.9, at
16.3 px/s (`R1`). On the control floor it never moves up at all (`K2`). That is
the "golf ball bounces off a flat floor" of #65204.

Friction 0 on the box (`PhysicsMaterial`) is a partial cure on 4.3/4.4: it
reaches 457.3 instead of 25.2, but still stalls 15 frames (`F1`).

## What changed in 4.5: tiles are merged per chunk

Since 4.5 ([PR #102662](https://github.com/godotengine/godot/pull/102662)) a
`TileMapLayer` merges the collision shapes of neighbouring cells into one body
per **physics quadrant**, 16×16 cells by default. On 4.7 the same 62-cell floor is
**5 bodies** — chunks -1, 0, 1, 2 and 3 (`S1`) — and:

- the box ends at **exactly** the control's numbers, 421.9, 431.6 and 653.9, with
  0 stalled frames, including the run that crosses the chunk border at x = 256
  (`B1`, `B2`);
- friction 0 changes nothing that needs changing: 487.2, 0 stalls (`F1`);
- **the ball is still kicked upward, but only within 4 px of a chunk border** —
  at x = 256.4 at 23.9 px/s, and at x = 512.8 on a second run — and never at the
  seams inside a chunk (`R1`);
- two different tiles alternating along the floor merge the same way: 5 bodies,
  bounces only at chunk borders (`Q5`). Merging is by shape, not by tile.

So 4.5+ fixed the seams **inside** each chunk. The seams **between** chunks are
still there, one every 16 cells.

`physics_quadrant_size` is the switch, both ways:

| id | 4.7, `physics_quadrant_size` | bodies under the floor | result |
|---|---|---|---|
| `Q1`, `Q2` | 1 | 62 | box stops at **25.2**, exactly as on 4.3/4.4 |
| `S1`, `B1`, `R1` | 16 (default) | 5 | box as the control; ball bounces at chunk borders |
| `Q3`, `Q4` | 64 (covers this whole floor) | 2 | ball **never moves up** — same as the control |

## The fix

**On 4.5 or newer:** raise `physics_quadrant_size` on the `TileMapLayer` so a
floor the bodies travel along is inside one quadrant (`Q3`, `Q4`):

```gdscript
$Ground.physics_quadrant_size = 64   # or larger than your level, if it never changes
```

The cost is on the other side: a quadrant is one body, and changing one tile
rebuilds the body of its whole quadrant (the 4.7 rebuild is measured on
[why the erased tile still collides](why-the-erased-tile-still-collides.md)). A
level you mine or dig in wants small quadrants; a level that never changes can
be one quadrant. Do **not** set it to 1 to get a per-cell `get_coords_for_body_rid()`
on a floor boxes slide on — that brings the 4.3 snag back (`Q2`).

**On 4.3 or 4.4:** the tiles cannot be merged. Take collision off the floor
tiles and give the floor its own body with one shape per straight run — the
control in `K1`/`K2` is exactly that, and nothing catches on it. Friction 0 on
the pushed body helps but does not cure it (`F1`).

## What does not snag: `CharacterBody2D`

A `CharacterBody2D` moved by `move_and_slide()` stalled on **0 frames** in every
case measured, on all three versions (`C1`): walking the floor at 200 px/s with
gravity (12×14 rectangle, and a radius-6 capsule), flush under a tile ceiling
with `velocity.y = 0`, and `MOTION_MODE_FLOATING` sliding along a tile wall while
pushing into it. If your *player* stops at a seam on a flat floor, the cause is
more likely a collision polygon that is not a full square or not flush with its
neighbour — see [why my tiles do not collide](why-tiles-do-not-collide.md) — than
the seam itself.

This does **not** reproduce the ceiling case in the still-open
[#87477](https://github.com/godotengine/godot/issues/87477): its project uses a
specific tile arrangement this page does not rebuild.

## Checklist

1. A `RigidBody2D` that stops on a flat tile floor, or a ball that hops: it is
   the seams (`B1`, `R1`) — the same body on one `StaticBody2D` does not (`K1`, `K2`).
2. 4.3/4.4: one body per tile (`S1`). Replace floor collision with your own
   `StaticBody2D`; friction 0 only helps (`F1`).
3. 4.5+: seams inside a chunk are gone (`B1`); seams between chunks still kick
   a ball (`R1`). Raise `physics_quadrant_size` until the floor fits (`Q4`).
4. `physics_quadrant_size = 1` is the 4.3 behaviour back (`Q2`).
5. A `CharacterBody2D` is not what catches here (`C1`).

## Run it yourself

```
docs/verify_seam_snag.sh /path/to/godot             # 8 PASS on 4.3/4.4, 13 on 4.7, exit 0
docs/verify_seam_snag.sh /path/to/godot --invert    # 2 FAIL, exit 1
```

## What this file does not measure

- Godot 4.5 and 4.6 (the script treats them as 4.7; not run), and Jolt or any
  other physics engine.
- Tile shapes other than a full square, slopes, one-way tiles, and corners where
  a floor meets a wall (the "ghost collision on corners" in #89458 comments).
- Speeds, sizes, gravity and tick rates other than those listed, and
  `continuous_cd`, `safe_margin`, bounce and mass.
- Rotation free on the box, and shapes other than the ones listed.
- Chunk borders on a vertical wall, and seams crossed by a `CharacterBody2D` at
  speeds other than 200 px/s.
- Physics run on a separate thread, or non-headless builds.

MIT, from <https://github.com/leobaray/blobsmith-autotile-wirer>.
