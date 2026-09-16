# Why my isometric TileMap is not a diamond

You set `TileSet.tile_shape` to **Isometric**, you painted, and the map came out
as a rectangular grid of overlapping tiles. Nothing looks isometric. The tiles
themselves are fine — the same art in any other engine lays out correctly.

The shape is not the layout. In Godot 4 those are two separate properties on the
`TileSet`, and **changing `tile_shape` does not change `tile_layout`**. A new
`TileSet` starts at `Stacked`, and it is still `Stacked` after you pick Isometric
(`I1a`, `I1b`). Isometric + Stacked is a real, supported combination that simply
is not the diamond you wanted.

Everything below was measured, in a project with nothing else configured, on
Godot **4.3, 4.4 and 4.7 stable**, at `tile_size = (64, 32)`. The script that
asks the engine each of these questions is next to this file:

```
docs/verify_isometric_layout.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

24 checks, identical on all three engines.

---

## The one-line fix

`TileSet` → **Tile Layout** → `Diamond Right`.

In code:

```gdscript
tile_set.tile_shape  = TileSet.TILE_SHAPE_ISOMETRIC
tile_set.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_RIGHT   # this is the missing line
```

## What the two layouts actually do

`map_to_local()` returns the **centre** of a cell in the layer's local space
(`I6a`). Reading its output for the first few cells is the fastest way to see
which grid you are on.

| cell | Isometric + **Stacked** (default) | Isometric + **Diamond Right** |
|------|-----------------------------------|-------------------------------|
| (0,0) | (32, 16) | (32, 16) |
| (1,0) | **(96, 16)** — a whole tile width right | **(64, 0)** — half a width right, half a height *up* |
| (0,1) | (64, 32) | (64, 32) — half a width right, half a height down |
| (1,1) | (128, 32) | (96, 16) — one full width right of (0,0) |

Stacked steps `+x` by a whole tile width, exactly like a square grid (`I2a`).
That is the rectangle you are looking at. Diamond Right steps `+x` by *half* a
tile in each axis (`I3a`), which is what makes two diagonal axes on screen.

**Stairs Right is not a third option here.** At this tile size it places
(1,0), (0,1) and (1,1) on exactly the same points as Stacked (`I4`). If you
are cycling through the layouts hoping to spot the diamond, those two look
identical and you will conclude the property does nothing.

## Tile Offset Axis is not the answer

It is right below Tile Layout in the inspector, it mentions offsetting, and on
an isometric TileSet **it does nothing at all**: flipping it between Horizontal
and Vertical leaves every cell on the same point (`I5a`).

The property is not broken — it belongs to the other two shapes. On
Half-Offset Square and on Hexagon, flipping the same axis does move the cell
(`I5b`, `I5c`). Those are the controls in the script; they exist so that "it
did nothing" cannot be blamed on the test.

## Your art is taller than the grid

The usual isometric sheet is 64×64 art on a 64×32 grid: the top half is the
height of the block, the bottom diamond is its footprint. The tempting fix is to
raise `tile_size` to (64, 64). That is wrong — `tile_size` is the **grid**, and
raising it spreads every cell apart.

The grid stays at the footprint, and the drawing is pushed up with
`TileData.texture_origin`:

```gdscript
tile_set.tile_size = Vector2i(64, 32)        # the diamond footprint
source.texture_region_size = Vector2i(64, 64) # the art, block included
source.get_tile_data(Vector2i(0,0), 0).texture_origin = Vector2i(0, -16)
```

`texture_origin` moves the drawing and leaves the logical grid untouched:
`map_to_local()` returns the same point before and after (`I8b`), with
`tile_size` still (64, 32) (`I8c`).

## The origin is not where you think

`map_to_local(Vector2i(0,0))` is `(32, 16)` — the centre of the diamond, not its
corner (`I6a`). So the local point `(0, 0)` does **not** fall in cell (0,0): it
falls in cell **(0,-1)** (`I6b`).

This is where mouse-picking goes wrong on isometric maps. Do not compute the
cell from the mouse position yourself; the round trip through the engine is
exact for every cell tried, including negatives (`I7`):

```gdscript
var cell := layer.local_to_map(layer.to_local(get_global_mouse_position()))
```

## The neighbour constants flip over

This one silently breaks code that already worked. `get_neighbor_cell()` with a
direction the shape does not have **returns the cell you passed in**. It prints
an engine error, but the value your script reads is the cell it started on — so
a walk loop stops moving instead of crashing.

Square and isometric take almost opposite halves of the enum:

| constant | square | isometric |
|----------|--------|-----------|
| `CELL_NEIGHBOR_RIGHT_SIDE` | (1, 0) | **(0, 0)** — no move (`I9a`, `I9b`) |
| `CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE` | **(0, 0)** — no move (`I9g`) | (0, 1) (`I9c`) |
| `CELL_NEIGHBOR_TOP_RIGHT_SIDE` | no move | (1, 0) (`I9d`) |
| `CELL_NEIGHBOR_BOTTOM_LEFT_SIDE` | no move | (-1, 0) (`I9e`) |
| `CELL_NEIGHBOR_TOP_LEFT_SIDE` | no move | (0, -1) (`I9f`) |

On an isometric grid the four sides of a diamond are the **corner-named**
constants, and `+x` is `TOP_RIGHT_SIDE`, not `RIGHT_SIDE`.

The same applies to terrain peering bits: an isometric terrain set peers across
`TOP_RIGHT_SIDE`/`BOTTOM_RIGHT_SIDE`/`BOTTOM_LEFT_SIDE`/`TOP_LEFT_SIDE`, so a
47-blob sheet wired for a square grid does not transfer to an isometric one by
changing the shape.

---

## Checklist

1. `tile_layout` = **Diamond Right** — the shape alone does not do it (`I1b`).
2. Ignore **Tile Offset Axis**; on Isometric it moves nothing (`I5a`).
3. `tile_size` = the diamond footprint; tall art goes in `texture_origin`
   (`I8b`).
4. Mouse → cell through `local_to_map(to_local(...))`, never by hand — local
   `(0,0)` is cell `(0,-1)` (`I6b`).
5. Walking the map: corner-named neighbour constants, `TOP_RIGHT_SIDE` for `+x`
   (`I9d`).

## Run it yourself

```
docs/verify_isometric_layout.sh /path/to/godot                 # 24/24 PASS, exit 0
docs/verify_isometric_layout.sh /path/to/godot --invert        # 22/24, exit 1
```

The second form flips two expectations on purpose, so you can see the script is
able to fail.

MIT, from <https://github.com/leobaray/blobsmith-autotile-wirer>.
