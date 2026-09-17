# I can jump up through the one-way tile but not drop down through it — pressing down on a `TileMapLayer` platform

You gave a tile a collision polygon with **One Way** on. The player jumps up
through it and lands on top, as expected. Now you want "down + jump" to drop
through it, and nothing you try moves the player: a big downward velocity does
nothing, and `add_collision_exception_with()` does nothing either.

Tunnelling through a one-way tile *by accident* while falling fast, and what
`one_way_margin` defaults to, are on
[why my tiles do not collide](why-tiles-do-not-collide.md) (`C8`, `C24`,
`C25`). This page is about dropping through *on purpose*.

Every claim below has an id (`D1`, `M2`, …) and is asserted by
[`verify_one_way_drop.gd`](verify_one_way_drop.gd) against a real binary,
except `X1`, which counts an engine error line and is asserted by the wrapper:

```
docs/verify_one_way_drop.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, headless:
19 checks on each (18 in the script, 1 in the wrapper), all passing. `K1` and
`J2` are controls, and `--invert` flips `D2` and `M1` on purpose: it exits 1 on
all three. A GDScript parse error exits 3, not 0. Last run **2026-09-16**. Needs
4.3 or newer — `TileMapLayer` does not exist in 4.2.

The test: 16×16 tiles, each with one full-square collision polygon. A row of
one-way platform tiles, cells `(0,5)`..`(9,5)` (top edge `y = 80`), and a row of
solid ground `(0,10)`..`(9,10)` (top edge `y = 160`). The player is a
`CharacterBody2D` with a 12×14 rectangle and every property at its default
(`floor_snap_length` 1, `safe_margin` 0.08), so it rests at `y = 73` on the
platform and `y = 153` on the ground. Every frame is
`velocity.y += 980 / 60` then `move_and_slide()`, at the default 60 physics
ticks. `one_way_margin` is the default 1 unless a row says 4.

---

## The fix

Put the platform tiles on **their own TileSet physics layer** (a different
`collision_layer` bit from the ground), and to drop, clear that bit from the
player's `collision_mask` for a few physics frames:

```gdscript
const PLATFORM_BIT := 2   # the TileSet physics layer the one-way tiles use

func drop_through() -> void:
    set_collision_mask_value(PLATFORM_BIT, false)
    for i in 3:            # 3 at one_way_margin 1 and this gravity; see M1, M2
        await get_tree().physics_frame
    set_collision_mask_value(PLATFORM_BIT, true)
```

With the platforms on bit 2, clearing bit 2 for 3 frames drops the player
through, clearing bit 1 does not, and a player standing on the ground with bit
2 cleared for 30 frames stays on the ground (`L1`). Restoring the bit while the
player is still inside the platform does not push it back up (`M3`).

The frame count is not a constant. The drop only sticks once the player has
sunk **deeper than `one_way_margin`** into the platform before the bit comes
back (`M1`, `M2`). A slower fall, a lower gravity or a larger margin needs more
frames.

## Why pressing down does nothing

| id | measured, all three versions |
|----|------------------------------|
| `K1` | control: dropped from `y = 60`, the body settles on the one-way platform, `is_on_floor()` true |
| `D1` | `velocity.y = 2000` (33 px a frame) + `move_and_slide()` for 30 frames: still on the platform, `is_on_floor()` true |
| `D2` | `position.y += 0.9`, then gravity: back on the platform. `position.y += 1.0`: falls through to the ground. Identical with `floor_snap_length` 0, 1 and 32 |
| `D3` | with `one_way_margin = 4`: `+= 3.9` comes back onto the platform, `+= 4.0` falls through |
| `D4` | `position.y += 1.0` with velocity 0 and no gravity: 5 frames later the body is still **inside** the platform, not pushed out, and `is_on_floor()` is false |

A one-way tile blocks a body moving down that is not yet deeper into it than
`one_way_margin`, and a body already deeper than that is let through and
not pushed back out (`D2`, `D3`, `D4`). Downward velocity alone did not get
the body past the margin in 30 frames (`D1`). Floor snap is not what pulls the body back: `floor_snap_length` 0, 1
and 32 give the same result (`D2`).

So a nudge of `one_way_margin` pixels is also a drop (`D2`, `D3`). It skips the
physics-layer setup, but it teleports the body into the tile. What a nudge does
on solid ground is not measured here.

## Clearing the mask bit: how many frames

| id | measured, all three versions |
|----|------------------------------|
| `M1` | from standing, bit cleared for 1 or 2 frames then restored (sunk 0.27 and 0.81 px in): back on the platform. For 3 frames (1.63 px in): falls to the ground |
| `M2` | `one_way_margin = 4`: 4 frames is not enough (back on the platform), 5 frames drops |
| `M3` | restored after 3 frames, the body is still inside the platform, and it is not pushed up — it keeps falling |

## Why one shared physics layer goes wrong

If platforms and ground share one physics layer, clearing the bit turns off the
ground too. Standing on the **solid** ground with that bit cleared:

| id | | 4.3 | 4.4 | 4.7 |
|----|-|-----|-----|-----|
| `L2` | 3 frames, then restored | pushed back up onto the ground | same | same |
| `L2` | 20 frames | falls through the ground | same | same |
| `L3` | 10 frames, then restored | **stuck inside the ground**, `is_on_floor()` false | **stuck inside** | pushed back up onto the ground |

A "drop" pressed while standing on solid ground can leave the player stuck
inside it or send it through it (`L2`, `L3`). Separate physics layers avoid all of it (`L1`).

## Collision exceptions

| id | | 4.3 | 4.4 | 4.7 |
|----|-|-----|-----|-----|
| `E1` | `add_collision_exception_with(tile_map_layer)` | nothing: `get_collision_exceptions()` stays empty, body stays on the platform | same | same |
| `X1` | … and the engine prints | `Collision exception only works between two nodes that inherit from PhysicsBody2D`, once | same | same |
| `E2` | `PhysicsServer2D.body_add_collision_exception(get_rid(), get_last_slide_collision().get_collider_rid())` | drops through, lands on the ground, which still collides | same | same |
| `E3` | the same, body standing across `(3,5)` and `(4,5)` | that RID is **one cell** (`get_coords_for_body_rid` → `(3,5)`); the body stays up on `(4,5)` | same | that RID is **chunk `(0,0)`**; the body drops through both tiles; the platform tile `(20,5)` in the next 16×16 chunk still collides |

`TileMapLayer` is not a `PhysicsBody2D`, so the node API refuses it (`E1`,
`X1`). The server API works, but what it turns off depends on the version: one
tile on 4.3/4.4, which leaves the player standing on the tile next to it, and
every platform tile of a 16×16 physics chunk on 4.7 (`E3`). The solid ground
row, in the same chunk on 4.7, still collided (`E2`). Why 4.7 hands out chunk
RIDs is on
[which tile did the player hit?](why-the-tile-you-hit-is-the-wrong-one.md).
You also have to remove the exception yourself later. The mask bit (`L1`) has
neither problem.

## Transforms: which side blocks

| id | measured, all three versions |
|----|------------------------------|
| `T1` | a one-way tile placed with the `TRANSFORM_FLIP_V`, `TRANSFORM_FLIP_H` or `TRANSFORM_TRANSPOSE` alternative still blocks from **above** and lets a body moving up at 600 px/s through from below |
| `T2` | the `TileMapLayer` **node** rotated 180°: a falling body passes through the platform, and a body moving up at 600 px/s is stopped under it (highest `y = -73`, the bottom edge is `-80`) |

Flipping or transposing the tile does not flip its one-way direction (`T1`).
Rotating the layer node does (`T2`). A ceiling you can fall through but not
jump through needs a rotated layer, not a flipped tile.

## Jumping up through it

| id | measured, all three versions |
|----|------------------------------|
| `J1` | jump at -500 px/s from the ground: rises past the platform (top `y` < 66), `is_on_ceiling()` is never true, lands on the platform |
| `J2` | control: the same jump under a solid (not one-way) row: `is_on_ceiling()` becomes true and the body comes back to the ground |

---

## Checklist

1. Holding down does nothing, whatever the velocity (`D1`).
2. Put one-way tiles on their own TileSet physics layer (`L1`, `L2`, `L3`).
3. Drop = clear that mask bit until the player is deeper than `one_way_margin`
   (3 frames here, `M1`; 5 at margin 4, `M2`), then restore it; restoring
   too early snaps back; restoring while the player is inside it is fine (`M3`).
4. Not `add_collision_exception_with(tile_map_layer)` — it prints an error and
   does nothing (`E1`, `X1`). Server exceptions by RID cover one tile on
   4.3/4.4 and a whole chunk on 4.7 (`E3`).
5. `floor_snap_length` is not the cause (`D2`).
6. To make tiles block from below, rotate the layer node, not the tile (`T1`, `T2`).

## Run it yourself

```
docs/verify_one_way_drop.sh /path/to/godot             # 19 PASS (18 in the script + X1), exit 0
docs/verify_one_way_drop.sh /path/to/godot --invert    # 2 FAIL, exit 1
```

## What this file does not measure

- One-way tiles falling through at speed and a cure for that — see
  [why my tiles do not collide](why-tiles-do-not-collide.md) (`C24`, `C25`).
- Shapes other than a 12×14 rectangle (capsules, circles), slopes, and
  one-way polygons that are not a full square.
- Gravity, tick rates and `one_way_margin` values other than those listed;
  the frame counts in `M1` and `M2` are for exactly those.
- What a `position.y` nudge does to a body on solid ground.
- `RigidBody2D`, `Area2D`, `AnimatableBody2D` and moving platforms.
- `physics_quadrant_size` other than the default 16 on 4.7, and 4.5 and 4.6.
- Rotations other than 180°, and a rotated or scaled player.
- Physics run on a separate thread, Jolt, or non-headless builds.

MIT, from <https://github.com/leobaray/blobsmith-autotile-wirer>.
