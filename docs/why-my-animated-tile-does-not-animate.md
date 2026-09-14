# Animated tile not animating (or animating when it should not) — what the engine does

You set up an animated tile in the TileSet panel and it sits on frame 0. Or it
animates, but every water tile flips at the same instant. Or you pause the game
and the tiles keep moving, and there is no `pause()` to call.

Tile animation is not a node and not an `AnimationPlayer`. It is four numbers on
the tile in the `TileSetAtlasSource` — frame count, columns, separation, speed —
plus one duration per frame, and it runs on the rendering server's clock. This
page measures each part. Every claim has an id (`A4`, `K1`, …) and is asserted by
[`verify_tile_animation.gd`](verify_tile_animation.gd) against a real binary,
with the frame on screen read back from rendered pixels:

```
docs/verify_tile_animation.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 27
checks, 27/27 on each, two of them controls that fail if the check stops
telling right from wrong. Last run **2026-09-14**. Needs 4.3 or newer —
`TileMapLayer` does not exist in 4.2. The script needs `xvfb-run` (the headless
renderer returns no pixels) and runs at `--fixed-fps 60`, so durations below are
counted in rendered frames: 0.1 s = 6 frames.

---

## The short answer

```gdscript
var src := layer.tile_set.get_source(source_id) as TileSetAtlasSource
var tile := Vector2i(0, 0)
src.set_tile_animation_columns(tile, 4)        # BEFORE frames_count if the row is not free
src.set_tile_animation_frames_count(tile, 4)
if src.get_tile_animation_frames_count(tile) != 4:
	push_error("frame cells are occupied by other tiles — delete them first")
src.set_tile_animation_frame_duration(tile, 0, 0.15)  # default is 1.0 s per frame
```

Then put the **tile's own coordinate** in the cell, never a frame's:
`set_cell(cell, source_id, Vector2i(0, 0))`.

## Where the frames come from

A new tile has `frames_count 1`, `columns 0`, `speed 1.0`, frame duration
`1.0` s, mode `DEFAULT`, separation `(0,0)` (`A1`).

With `columns = 0` the frames are the atlas cells **to the right** of the tile:
frame 1 is `(1,0)` (`A2`). With `columns = 1` they go **down**: frame 1 is
`(0,1)` (`A4`). `separation (1,0)` skips one atlas cell between frames, so frame
1 comes from `(2,0)` and whatever is painted at `(1,0)` is never shown (`A5`).

The first thing to check when nothing moves is the duration: **1.0 s per frame
by default** (`A2`: 60 rendered frames at 60 fps, give or take one where the
float clock lands on the boundary). A 4-frame water animation drawn for 8 fps
looks frozen for the first second, then jumps.

## The frame cells must not be tiles

The cells an animation reads its frames from have to be empty in the atlas —
not empty of pixels, empty of **tiles**. When you import a sheet, the editor's
"create tiles in non-transparent areas" prompt makes every frame a tile of its
own, and then:

| id | situation | result |
|----|-----------|--------|
| `A4` | `(1,0)` is already a tile, `set_tile_animation_frames_count(2)` | **refused**: count stays `1` |
| `E1` | … what it prints | `Cannot set animation columns count, tiles are already present in the space the tile would cover.` |
| `A4` | set `columns = 1` first, then `frames_count 2` | accepted, frames read downward |

The error names **columns** although the call was `frames_count`, so searching
for the message leads to the wrong setting. Delete the extra tiles (in the
TileSet panel, select them and erase) and set the frame count again.

Once the animation owns those cells, they are not tiles any more (`A3`):
`has_tile((1,0))` is `false`, `get_tile_at_coords((1,0))` returns the animated
tile `(0,0)`, and a cell set to `(1,0)` has `null` tile data and draws nothing.
Code that places "the second water frame" by coordinate draws holes.

## Speed and per-frame duration

Each frame has its own duration: `0.1` s and `0.3` s give 6 and 18 frames
(`A6`). `speed` divides all of them — `2.0` gives 3 and 9 (`A7`).

`set_tile_animation_speed(0.0)` is **refused**: speed keeps its old value
(`A7`) and the engine prints `Condition "p_speed <= 0" is true.` (`E2`). Speed is
not a pause switch.

## All cells share one clock

In mode `DEFAULT`, every cell with that tile shows the same frame on the same
rendered frame — including a cell placed later: it joins the animation in
progress instead of starting at frame 0 (`A8`, 8 cells, one placed 9 frames
late). That is why a lake flips all at once.

`animation_mode = RANDOM_START_TIMES` gives each cell its own offset: the same 8
cells show different frames on the same rendered frame (`A9`). It is per tile,
set in the TileSet panel under Animation → Mode.

## What stops it, and what does not

| id | what you do | tile animation |
|----|-------------|----------------|
| `A10` | `get_tree().paused = true` | **keeps running** |
| `A10` | the layer's `process_mode = DISABLED` | **keeps running** |
| `A11` | `Engine.time_scale = 0` | frozen |
| `A11` | `Engine.time_scale = 0.5` | half speed: 6-frame frames become 12 |
| `A12` | `set_tile_animation_frames_count(tile, 1)` at runtime | every cell stops on frame 0 |

Pausing the tree does not reach tile animation, because no node processes it.
To freeze tiles on a pause menu without freezing everything through
`time_scale`, set the frame count to 1 (and restore it on resume) — it changes
the `TileSet` resource, so every layer using that tile stops (not measured
here: what happens if that resource is saved to disk while the count is 1 —
presumably the 1 is saved).

## Checklist

1. Nothing moves → duration is still 1.0 s per frame (`A1`, `A2`).
2. Frame count will not go above 1 → the frame cells are tiles; the error says
   "columns" (`A4`, `E1`).
3. Wrong art in the animation → frames go right unless `columns` is set; check
   `separation` (`A4`, `A5`).
4. Holes where frames were placed → cells point at a frame coordinate (`A3`).
5. All cells in sync → mode `DEFAULT`; use `RANDOM_START_TIMES` (`A8`, `A9`).
6. Keeps animating when paused → expected; `time_scale` or `frames_count 1`
   (`A10`–`A12`).
7. Trying `speed = 0` → refused (`A7`, `E2`).

## What this file does not measure

- Exact wall-clock timing. The runner fixes the frame rate so durations can be
  counted; in a real game frames are timed by the engine clock the same way,
  but frame pacing varies.
- Scene tiles (`TileSetScenesCollectionSource`), e.g. an `AnimatedSprite2D`
  placed as a tile, and whether that one pauses with the tree.
- Animated tiles with `texture_padding`, a `texture_region_size` larger than the
  tile, or tiles bigger than 1×1.
- Shader-based animation (`TIME` in a `CanvasItemMaterial`/shader on the layer).
- The legacy `TileMap` node.
