# Godot 4: the tiles are y-sorted and still draw in the wrong order

Your wall is taller than one tile. The player walks below it and is drawn
*behind* it. You tick **Y Sort Enabled**, which is what every answer says to do,
and nothing changes. You drag the tile's origin in the TileSet editor until the
art lines up, and still nothing changes.

Nothing changed because the two things you did are not the thing that decides
the order. This page is a measurement of what actually decides it, in
**Godot 4.7.stable.official.5b4e0cb0f**.

Draw order is not a property you can print. It is what the renderer does with
the properties. So none of the numbers below come from reading the docs or the
scene tree: `docs/verify_y_sort.gd` builds each scene, renders it into a
SubViewport, and **reads the contested pixel back**. Run it yourself:

```
docs/verify_y_sort.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

It prints `PASS`/`FAIL` and the value it measured next to all 28 claims. Every
`Y-number` on this page is one of them. If your build disagrees with a claim,
that script turns the disagreement into a number instead of an argument.

> It needs `xvfb-run`, not `--headless`. The headless build swaps in a dummy
> renderer, `SubViewport.get_texture()` hands back a texture whose image is
> null, and there is no pixel to read. A "verification" that ran headless here
> would be measuring nothing and passing.

## The scene every claim is measured in

Two 16×16 tiles in one TileMapLayer. RED at cell `(0,0)`, BLUE at cell `(0,1)`.
RED is drawn 8 px *down* — so it hangs into BLUE's cell exactly the way a tall
wall hangs into the cell below it. The band `y=16..23` is claimed by both tiles,
and whichever colour comes back from that pixel is the one the renderer drew
last.

With no offsets at all the two cells simply tile the column, RED on rows 0..15
and BLUE on 16..31 (**Y9**) — that is the baseline the rest is measured against.

## The two things that do not do what you think

**Texture Origin moves the picture and nothing else.** Setting
`texture_origin.y = -8` moves the tile 8 px down into the next cell (**Y11**).
Setting it to `+8` moves it *up*: the offset is subtracted, not added (**Y10**),
which is already the opposite of what most people expect from a field called
"origin". But drag it as far as you like — at `-64` the art is four rows away
from home and BLUE is *still* on top (**Y14**). The picture moved. The sort key
never did.

**Ticking Y Sort Enabled, on its own, changes nothing here.** With y-sort off,
the tile written to the later cell wins the contested band (**Y12**). Turn
`y_sort_enabled` on and the pixel is identical — same winner (**Y13**).

That is the whole trap. The advice is "enable Y Sort and set your tile origins",
and someone who does exactly that, in that order, sees no change at either step
and concludes Y-sort is broken. It is not broken. `y_sort_enabled` is the
*precondition*; `texture_origin` is the wrong field.

## The property that does move it, and the key it feeds

The field you want is **Y Sort Origin** (`TileData.y_sort_origin`), which sits
directly under Texture Origin in the TileSet editor and ships at `0` (**Y3**).

Push RED's `y_sort_origin` to `+16` and BLUE still wins (**Y15**). Push it to
`+17` and the order flips (**Y16**). That one-unit step is the whole formula:

> A tile's sort key is **the centre of its cell**, plus its `y_sort_origin`.
> `cell.y × tile_size.y + tile_size.y/2 + y_sort_origin`

RED sits at cell `(0,0)` of a 16 px TileSet, so its key is `0 + 8 + y_sort_origin`.
BLUE at cell `(0,1)` has `16 + 8 = 24`. At `+16` RED ties at 24 and loses the tie
to the later cell; at `+17` it reaches 25 and wins (**Y17**).

The same number falls out of a completely different scene. Park a sprite as a
child of the layer and slide only its sort position: it goes behind the tile at
`y = 23` (**Y19**) and in front at `y = 24` (**Y20**) — the centre of cell
`(0,1)` again, arrived at from the other side. That is why "set the origin to
the tile's feet" is right in spirit and useless as an instruction: **the number
you need is measured from the centre of the cell, not from the top of the art**,
and it is negative for a tile whose base is above centre.

With y-sort *off*, that same child sprite is drawn on top no matter where it
stands (**Y18**) — the classic "my player is always in front of everything".

`TileMapLayer` also has its own `y_sort_origin`, which `Node2D` does not have
(**Y6**); setting it to `+16` shifts every tile in the layer at once and takes
the band back from the sprite (**Y21**).

## Two layers: both flags, or neither matters

The common report is "my walls are on one layer and my floor on another, and
they never sort against each other". The common answer is that Godot cannot sort
between layers and you must manage `z_index` by hand. Measured, that answer is
wrong.

Two sibling `TileMapLayer`s, one holding tiles above and below the other's:

- nothing y-sorted → the later layer covers the earlier one wholesale (**Y22**)
- y-sort on **the layers only** → identical pixels, no change (**Y23**)
- y-sort on **the parent only** → identical pixels, no change (**Y24**)
- y-sort on **the parent AND the layers** → the two layers **interleave per
  tile**: the upper tile goes behind, the lower one in front (**Y25**)

So it does sort between layers, per tile, and it needs `y_sort_enabled` ticked
in two places — on each layer *and* on the node they hang from. Tick one and you
see nothing, which is exactly why people conclude it cannot be done.

## What silently outranks all of it

`TileData.z_index` (**Y5**, ships at 0). Y-sorting only orders items that share
a z_index, so a single tile left at `z_index = 1` wins the band that sorting had
given away (**Y26**) — and it works from the other side too: dropping the
*winner* to `-1` hands the band over just the same (**Y27**). One tile edited
months ago, invisible unless you click that tile, and the sorting you set up is
simply not consulted for it.

And one knob that is *not* the problem, though it gets recommended:
`rendering_quadrant_size`. Measured at 1, 16 and 128 on an otherwise identical
y-sorted scene, the winner never moves (**Y28**). Leave it at 16 (**Y7**).

## Finding which one is yours

```
node docs/find_y_sort_causes.js /path/to/your/godot/project
node docs/find_y_sort_causes.js /path/to/project --json
```

Zero dependencies, reads only `.tscn`/`.tres`, writes nothing, uploads nothing,
exits 1 when it finds something. Each rule cites the claim above that it comes
from: **Y14** art moved without the sort key, **Y12** a layer that wants sorting
and has not got it, **Y23** sibling layers under an unsorted parent, **Y26** a
stray per-tile `z_index`, **Y28** a tuned quadrant size that cannot be the
cause, **Y8** a scene still on the superseded `TileMap` node, whose y-sort lives
in `layer_N/y_sort_enabled` and not in the property every current answer names.

Two things it deliberately does not do. It does not flag a flat floor layer
that is simply not y-sorted — that is the correct configuration for a floor, and
a scanner that flags every one of them is noise. It only speaks up when
something in the same file shows sorting was *wanted*: a tile origin pushed off
its cell, or child nodes parented to the layer. And it reads what the scene file
says, so a `y_sort_origin` that is right for a 16 px tile and wrong for a 32 px
one looks the same to it — that is what the formula in **Y17** is for.

**Measured on the official demos.** Against `godotengine/godot-demo-projects`
(533 scene and resource files) it reports exactly one hit:
`2d/role_playing_game/grid_movement/exploration.tscn`, where `Player` and
`Opponent` are children of a `Grid` layer that is not y-sorted. That is **not a
bug in the demo** — Grid is a floor layer with nothing tall on it, and a player
that always draws above the floor is what that game wants. It is reported here
as calibration, not as a finding: before the "was sorting even wanted here"
gate, the same rules fired on 13 perfectly correct ground layers.

## Where this comes from

We build [Blobsmith](https://blobsmith.itch.io/blobsmith), a Godot 4 editor
plugin that wires an autotile sheet into a fully configured TileSet — terrain
set, per-tile peering bits, optional collisions.

Being straight about the boundary: **Blobsmith does not set `y_sort_origin` for
you, and this page is not a feature list.** Sorting depends on where the art
sits inside each tile, which is a fact about your drawing, not about the
wiring — the plugin has no way to know that a tile's visual base is 6 px above
its bottom edge. What overlaps is the other end: the per-tile properties this
page is about live in the same `TileData` objects Blobsmith writes, which is why
we had the harness to measure them.

If you came here from a search, the scanner and the verify scripts above are MIT
and cost nothing. The related measured write-ups in this repo are
[why a blob autotile is 47 tiles](why-47-tiles-not-256.md),
[why terrain paints the wrong tile](why-terrain-paints-the-wrong-tile.md),
[why tiles have seams](why-tiles-have-seams.md) and
[what `tile_map_data` actually encodes](tile-map-data-format.md).
