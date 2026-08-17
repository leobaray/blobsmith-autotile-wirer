# Thin lines between tiles in Godot 4 — what actually causes them, measured

Your tiles touch in the PNG. In the running game there is a one-pixel line
between them, and it flickers when the camera moves. Every answer you find tells
you to do four things at once, and one of the four is a setting that no longer
exists.

This page is the four causes separated, each one asked of the engine instead of
remembered. Every claim below has an id (`S1`, `S7`, …) and every id is asserted
by [`verify_tile_seams.gd`](verify_tile_seams.gd) against a real Godot binary:

```
docs/verify_tile_seams.sh /path/to/Godot_v4.7-stable_linux.x86_64
### pass 1 — stock project, nothing configured
TILE SEAMS: 23 passed / 0 failed
### pass 2 — the same project with the pixel-art settings written in
TILE SEAMS: 26 passed / 0 failed
```

Measured on **4.7-stable (official)**. Run it on your build before believing any
of it; the script prints the number it measured next to each claim, so a
disagreement comes back as a number and not as an argument.

To find which of the four is in *your* project, there is a scanner further down.

---

## First, the advice that is dead

The most repeated fix for this problem is *"Project Settings → Rendering →
Quality → 2D → Enable Pixel Snap"*. That setting is `rendering/quality/2d/use_pixel_snap`,
and **it does not exist in Godot 4** (`S1`). Neither does its GPU sibling
`use_gpu_pixel_snap` (`S2`). They were Godot 3 names. If you went looking for
that checkbox, could not find it, and concluded you were in the wrong menu — you
were in the right menu, reading advice written for the previous engine.

The Godot 4 replacement is **two** settings, not one (`S3`, `S4`):

```
rendering/2d/snap/snap_2d_transforms_to_pixel
rendering/2d/snap/snap_2d_vertices_to_pixel
```

Both ship **off** (`S5`).

## Cause 1 — the filter, and the enum that means the opposite thing

The default filter for canvas textures in a new project is not Nearest.

`rendering/textures/canvas_textures/default_texture_filter` is an enum whose
values are, in order, `Nearest, Linear, Linear Mipmap, Nearest Mipmap` (`S6`),
and it ships as **1 — Linear** (`S7`). So in a project where nobody touched it,
the GPU blends between neighbouring texels of your atlas, and at the edge of a
tile the texels it blends with belong to the *next tile over*. That is the line.

Now the part that wastes an afternoon. On a **node**, `CanvasItem.texture_filter`
is a *different* enum: `0` is Inherit, `1` is **Nearest**, `2` is **Linear**
(`S8`). The same integer `1` means Linear in the project setting and Nearest on
the node. A fresh `TileMapLayer` ships at `0`, Inherit (`S9`) — it does not force
Nearest for you, it takes whatever the project says.

And `TileSet` has no filter property at all (`S10`). If you have been hunting for
this switch inside the TileSet editor, it is not there and never was: the filter
belongs to the node and the project, never to the tileset.

## Cause 2 — the gutter Godot 4 already builds for you

The second most repeated fix is to re-export your atlas with 1–2 px of padding
between the tiles. On Godot 4 this is usually redundant work, because the engine
does it at runtime.

`TileSetAtlasSource.use_texture_padding` defaults to **true** (`S11`). With it
on, the engine builds a padded copy of your atlas: tile `(0,0)`, authored at
`(0,0)`, sits at `(1,1)` in the runtime texture (`S12`), and two 16 px tiles that
are 16 px apart in the file you drew are **18 px apart** in the copy the GPU
samples (`S13`). The tile keeps its size — the pad is added around it, the art is
not shrunk into it (`S14`). Turn the flag off and the runtime region collapses
back onto the authored one (`S15`): that is the toggle that removes the guard.

So `margins` and `separation` both default to `(0,0)` (`S16`), and a sheet drawn
with no gutter at all is the *expected* input, not a compromise. Cutting one by
hand still works — `margins = 1, separation = 2` moves tile `(1,0)` from x=16 to
x=19 (`S17`) — but it costs you tiles: the same 64×64 sheet holds a **4×4** grid
with no gutter and only **3×3** with one (`S18`).

If padding is on and you still have seams, padding is not your problem. Look at
cause 1 and cause 3.

## Cause 3 — the seam that only shows up while the camera moves

If the line appears and disappears as you pan, the sampling is fine and the
*geometry* is landing between two screen pixels.

`display/window/stretch/scale_mode` exists, its enum is exactly
`fractional, integer`, and it ships as **fractional** (`S19`, `S20`), with
`display/window/stretch/mode` shipping as **disabled** (`S20`). Two consequences
worth being precise about:

- with stretch **disabled**, `scale_mode` is not doing anything to you yet —
  changing it will not fix today's seam;
- with stretch on and `scale_mode` fractional, the viewport is scaled by a
  non-integer factor and a tile edge can land on half a screen pixel.

`Camera2D` has **no** pixel-snap property (`S24`) — nothing on the camera rounds
its own position for you; that is what the two `snap_2d_*` settings are for. And
`Camera2D.zoom` is a float pair defaulting to `(1,1)` (`S25`), so a `2.5` zoom is
one keystroke away and will re-open the seam that integer stretching just closed.

## Cause 4 — the art

`TileSet.uv_clipping` ships off (`S26`). If the scanner below finds nothing and
the line is still there, the remaining explanation is that the tile does not
occupy its whole cell in the source PNG — a transparent or off-colour row at the
bottom of the cell reads exactly like a seam and no engine setting will close it.

---

## The scanner — which of these is in your project

[`find_tile_seam_causes.js`](find_tile_seam_causes.js) reads `project.godot`,
your `.tscn` and your `.tres` files and reports the causes it finds, each tagged
with the claim id above. Zero dependencies, reads only, uploads nothing, exits 1
if it found a cause:

```
node docs/find_tile_seam_causes.js /path/to/your/godot/project
node docs/find_tile_seam_causes.js /path/to/your/project --json
```

On a stock project it says, correctly, that the first cause is already there
before you drew a single tile:

```
▲ [project-filter-not-nearest] project.godot (S7) — default_texture_filter is 1 (Linear)
  — the line is absent, so this is the shipped default
    fix: Project Settings → Rendering → Textures → Canvas Textures → Default Texture Filter = Nearest
▲ [snap-off] project.godot (S5) — rendering/2d/snap/snap_2d_transforms_to_pixel is absent (ships false)
· [fractional-scale-inactive] project.godot (S20) — stretch/mode=disabled, stretch/scale_mode=fractional
  — stretching is off, so scale_mode is not what is opening your seam today
```

It separates **causes** (`▲`, exit 1) from **notes** (`·`, exit 0): a hand-cut
gutter is reported, but as a note, because it is not a bug — it is just work the
engine would have done for you.

## The whole fix, in the order that matters

1. `default_texture_filter` → **Nearest** (`S7`), and delete any `texture_filter`
   override left on a `TileMapLayer` (`S8`, `S9`).
2. Leave `use_texture_padding` **on** (`S11`) and stop re-exporting the atlas
   with gutters (`S16`, `S18`).
3. Both `snap_2d_*` settings **on** (`S5`).
4. Only if you are stretching: `scale_mode` → **integer** (`S20`), and keep the
   camera zoom a whole number (`S25`).
5. Still there? It is in the PNG, not in the settings (`S26`).

---

Part of [Blobsmith Autotile Wirer](../README.md), the free Godot 4 plugin (MIT)
that wires a flat autotile sheet into a `TileSet`. Related measured references in
this repo: [why a blob autotile is 47 tiles and not 256](why-47-tiles-not-256.md),
[why terrain painting puts the wrong tile down](why-terrain-paints-the-wrong-tile.md),
and [the byte layout of `tile_map_data`](tile-map-data-format.md).

Note which half of the problem each tool owns: everything on this page is
settings and atlas geometry, and the plugin above does not change any of it —
`S26` is the case where the seam is painted into the PNG itself. Drawing a sheet
whose tiles actually meet at the edges is what the separate
[Blobsmith](https://blobsmith.itch.io/blobsmith) pixel-art tool is for; there is
a free browser version at [Blobsmith
Lite](https://blobsmith.itch.io/blobsmith-lite) if you just want to see the
47-blob layout being drawn.
