# The autotile has a seam exactly where your two TileMapLayers meet

You split your map across two `TileMapLayer` nodes — ground and cliffs, or floor
and walls, or just "background" and "foreground" — paint the same terrain on
both, and a seam appears along the line where one layer ends and the other
begins. Every tile away from the boundary is right. The tiles *at* the boundary
are edge pieces facing outward, as if each half were alone in the world.

Nothing in the editor reports an error, the tileset is fine, and repainting does
not help. The usual advice — "check your peering bits", "re-run the terrain
setup" — is aimed at the wrong thing.

Every claim below has an id (`X1`, `X6`, …) and is asserted by
[`verify_cross_layer_terrain.gd`](verify_cross_layer_terrain.gd), which re-runs
the whole thing against your Godot build and exits non-zero if any of it stops
holding. One-line runner:
[`verify_cross_layer_terrain.sh`](verify_cross_layer_terrain.sh).

Measured against **Godot 4.3.stable**, **4.4.stable** and
**4.7.stable.official.5b4e0cb0f**, 9 checks, 9/9 on each, byte-identical results
on the three. Last re-run **2026-09-19**. On **4.2** the file is a deliberate
skip: `TileMapLayer` did not exist yet.

---

## The short answer

`set_cells_terrain_connect()` looks at **one layer — the one you called it on**.
It has no way to see a tile sitting in a sibling layer, at the same coordinate or
next to it. So each half autotiles as though the other half were empty space,
which is exactly what an outward-facing edge tile means.

The boundary is **the layer, not the call**.

## The measurement

The shape is a 2×2 block of grass, using the 47-blob set from this repo's
[free starter pack](../examples/starter-pack/). Painted whole, it is four
different corner tiles. Split down the middle, it is two vertical strips.

| id | what was done | result |
|----|---------------|--------|
| `X1` | the 2×2 block, one layer, one call | `(2,1) (4,0) (2,3) (2,4)` — four different tiles, a corner each |
| `X2` | left column on layer A, right column on layer B | both halves come out **identical**: `(5,0) (1,0)` |
| `X3` | the split result vs the one-layer result | different on the touching cells — this is the seam you see |
| `X4` | painting layer B, then re-reading layer A | not one cell of A changed |
| `X5` | painting right-then-left instead of left-then-right | same wrong shape — order does not rescue it |

`X2` is the tell. The two halves are not merely wrong, they are *the same* — each
one is the tileset's answer to "an isolated 1×2 column", because from inside each
layer that is genuinely all there is.

`X4` matters for a different reason: there is no deferred fixup. People assume
the second paint will reconcile the first once both exist. It does not, and it
never will — the first layer is not read.

## What fixes it

**Put the terrain on one layer.** That is the whole fix, and it does not mean
one call:

| id | what was done | result |
|----|---------------|--------|
| `X6` | left column, then right column, as **two separate calls on the same layer** | `(2,1) (4,0) (2,3) (2,4)` — identical to the single-call block |
| `X8` | the second call, on cells the first call had already painted | rewrote them |

`X6` is the practical half of this page. You do not have to gather every cell
into one array, and you do not have to paint the map in one shot — incremental,
chunk-by-chunk, player-driven painting all connect correctly, **as long as the
calls land on the same layer**. `X8` is why: `connect` reads the layer's existing
cells, including ones you did not pass in, and rewrites the ones whose
neighbourhood changed.

So a chunked world generator that paints chunk by chunk into a single
`TileMapLayer` produces a seamless result. The same generator with one layer per
chunk produces a grid of seams.

## When you genuinely need two layers

Sometimes the split is not negotiable — different `z_index`, different collision
layer, different `modulate`, a foreground that has to draw over the player.

Paint on one layer, then copy the **result** to the second:

```gdscript
# terrain is autotiled once, on `ground`, so every cell sees its neighbours
ground.set_cells_terrain_connect(all_cells, 0, 0)

# `overlay` gets the finished tiles, not a second terrain pass
for c in cells_that_belong_on_top:
    overlay.set_cell(
        c,
        ground.get_cell_source_id(c),
        ground.get_cell_atlas_coords(c),
        ground.get_cell_alternative_tile(c),
    )
    ground.erase_cell(c)   # if the cell should not be in both
```

`X7` asserts that the copied cells keep the connected tiles: `set_cell` moves a
chosen tile verbatim and re-runs no terrain logic, which here is precisely what
you want. The choice was already made on a layer that could see the whole shape.

The rule of thumb: **terrain decisions on one layer, presentation split
afterwards.** Once you have split, you have thrown away the neighbourhood.

## What this is not

- It is not a peering-bit problem. The same tileset paints the block correctly
  (`X1`) and the halves incorrectly (`X2`) in the same run.
- It is not non-determinism. `X5` paints in the reverse order and gets the same
  result; see [why terrain paints the wrong
  tile](why-terrain-paints-the-wrong-tile.md) for the 30× repeat.
- It is not a 4.7 regression. 4.3, 4.4 and 4.7 return the same atlas coordinates
  for all nine claims.

## Run it yourself

```
docs/verify_cross_layer_terrain.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

It copies the grass tileset into a throwaway project, so it touches nothing of
yours, and prints one `PASS`/`FAIL` line per claim. The gate is the summary line,
not the engine's exit code — Godot exits 0 on a parse error, so "no summary" is
reported as an error or a skip, never as a pass.

---

MIT, like the rest of this repository. Part of
[Blobsmith Autotile Wirer](../README.md) — the free tool that wires a 47-blob
sheet into a paint-ready Godot 4 TileSet.
