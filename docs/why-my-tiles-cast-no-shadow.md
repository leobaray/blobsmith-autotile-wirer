# My tiles cast no shadow — what a `PointLight2D` needs from a TileSet

You drew occluder polygons on your wall tiles, added a `PointLight2D`, and the
light goes straight through the walls. Or the shadow is there but half a tile
off, or it works in one project and not after upgrading.

A tile shadow needs five things to line up, and none of them warns when it is
missing. This page measures each one. Every claim has an id (`S1`, `M1`, …) and
is asserted by [`verify_tile_occlusion.gd`](verify_tile_occlusion.gd) against a
real binary, reading the rendered pixels back:

```
docs/verify_tile_occlusion.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f** on the
OpenGL renderer: 23 checks on 4.3, 27 on 4.4 and 4.7 (some claims only exist on
some versions), all passing, three of them controls that fail if the check
stops telling light from shadow. Last run **2026-09-15**. Needs 4.3 or newer —
`TileMapLayer` does not exist in 4.2.

The scene every check uses: a grey floor, a `PointLight2D` at the left, one
16 px wall tile in the middle, and two pixels read back — one between the light
and the tile, one behind it.

---

## The short answer

```gdscript
# TileSet: one occlusion layer (TileSet inspector > Occlusion Layers > Add Element)
tile_set.add_occlusion_layer()

# the tile: a polygon around the tile's CENTER, not its top-left corner
var poly := OccluderPolygon2D.new()
poly.polygon = PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)])
tile_data.set_occluder_polygons_count(0, 1)   # 4.4+; on 4.3: tile_data.set_occluder(0, poly)
tile_data.set_occluder_polygon(0, 0, poly)

# the light: a texture and shadows on
light.texture = preload("res://light.png")
light.shadow_enabled = true
```

That casts a shadow behind the tile on all three versions (`S1`), the same
shadow a `LightOccluder2D` node casts (`K1`, the control).

## 1. `shadow_enabled` is off by default

`PointLight2D.shadow_enabled` starts `false` (`S2`). With it off, nothing casts
a shadow: not the tile, and not a `LightOccluder2D` node either (`S2`), while
the light itself still looks fine.

A `PointLight2D` with no texture lights nothing at all, in front of the wall or
behind it (`S3`) — if the floor is not lit anywhere, the problem is the light,
not the tiles.

## 2. The TileSet needs an occlusion layer first

A new TileSet has **0** occlusion layers (`L1`). Without one there is nowhere to
put a polygon, and the tile casts nothing (`L1`). In the TileSet inspector:
**Occlusion Layers > Add Element**, then draw the polygons in the TileSet editor.

## 3. The polygon is relative to the tile's center

Polygon points are in tile-local coordinates with `(0, 0)` at the **center** of
the tile. A 16 px square is `(-8,-8)..(8,8)` (`P1`). Written as `(0,0)..(16,16)`
— the natural thing when you think in texture pixels — the occluder sits half a
tile down and right: a row that should be in shadow is lit, and the shadow
appears where it should not (`P1`). Watch for it in polygons made from code or
copied from a `LightOccluder2D` whose origin was a corner.

## 4. Three masks, and 4.4 added the third

Each occlusion layer has a `light_mask` (default `1`, `M1`); the light has
`shadow_item_cull_mask` (default `1`, `M1`). They must share a bit:

| occlusion layer `light_mask` | light `shadow_item_cull_mask` | shadow |
|---|---|---|
| 1 | 1 | yes (`S1`) |
| 2 | 1 | no (`M1`) |
| 1 | 2 | no (`M1`) |
| 3 | 2 | yes, if the floor passes the next rule (`M2`) |

**Since 4.4 the item receiving the shadow is filtered too.** The floor (any
`CanvasItem` being lit) has its own `light_mask`, default `1`. On 4.4 and 4.7,
when the floor's `light_mask` shares no bit with the light's
`shadow_item_cull_mask`, the floor is lit but never shadowed — occluder mask
`3`, shadow mask `2`, floor mask `1` gives no shadow; on 4.3 the same scene
casts one (`M3`). Setting the floor to `light_mask = 3` brings the shadow back on
all three (`M2`). A `LightOccluder2D` node behaves the same way (`M2`, `M3`).

So after moving a project from 4.3 to 4.4+, a light whose
`shadow_item_cull_mask` you changed can stop casting shadows on floors you never
touched: give those floors a matching `light_mask` bit.

## 5. `TileMapLayer.occlusion_enabled` (4.4+)

From 4.4, each `TileMapLayer` has `occlusion_enabled`, default `true` (`O1`).
Turned off, that layer casts no shadow (`O1`); turned back on at runtime, the
shadow returns on the next frames (`O2`). 4.3 has no such property (`O1`), so
`set("occlusion_enabled", false)` there does nothing.

## Which API writes the polygon

`TileData.set_occluder(layer, polygon)` exists on all three (`A1`). 4.4 added
several polygons per layer: `set_occluder_polygons_count(layer, n)` then
`set_occluder_polygon(layer, index, polygon)` (`A1`). The old
`set_occluder(0, polygon)` is deprecated but still casts on 4.4 and 4.7 (`A2`),
so code written for 4.3 keeps working.

## The wall tile is drawn in its own shadow

An opaque tile under its own occluder is not lit by that light: its center
reads the texture value `0.5`, where the same tile with shadows off reads about
`0.8` (`T1`). So a wall tile whose polygon covers the whole tile renders unlit
next to a lit floor. Covering only the base of the wall, or lighting walls with
a second light that has no shadows, are the usual ways around it (neither
measured here).

## Checklist, in the order it usually goes wrong

1. `shadow_enabled` still `false` on the light (`S2`).
2. No occlusion layer on the TileSet, so no polygon was saved (`L1`).
3. Polygon drawn from the corner, `0..16` instead of `-8..8` (`P1`).
4. Occlusion layer `light_mask` and light `shadow_item_cull_mask` share no bit
   (`M1`).
5. 4.4+: the floor's `light_mask` shares no bit with `shadow_item_cull_mask`
   (`M3`).
6. 4.4+: `occlusion_enabled` off on that `TileMapLayer` (`O1`).
7. The light has no texture, so nothing is lit to be shadowed (`S3`).

## What this file does not measure

- The legacy `TileMap` node, and the Forward+/Mobile renderers (OpenGL only).
- `DirectionalLight2D`, `shadow_filter`, `shadow_color` and light `height`.
- `OccluderPolygon2D.cull_mode` and open (non-closed) polygons.
- Flipped or transposed tiles; how transforms move collision is in
  [why a flipped tile is not a new tile](why-a-flipped-tile-is-not-a-new-tile.md),
  occluders were not checked there.
- Signed-distance-field (`sdf_collision`) use of tile occluders.
