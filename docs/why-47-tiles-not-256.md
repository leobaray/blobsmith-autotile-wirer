# Why a Godot 4 blob autotile has 47 tiles and not 256

Eight neighbours, each either matching terrain or not, is 2⁸ = **256**
combinations. Every blob tileset you can find ships **47** tiles. The gap is not
an approximation, a compression trick, or an artist's shortcut — 209 of those
256 neighbourhoods are *not distinguishable* by the rule Godot's terrain matcher
uses, so a tile for them would be a tile the engine could never choose.

This page shows the rule, the arithmetic, and the engine transcript that
confirms both — plus the failure mode that makes this worth knowing: a blob set
with a **missing** tile does not error and does not leave a hole. It quietly
paints the wrong tile.

There is a version of this page you can click:
**<https://blobsmith.lbwma.com/godot-autotile-47-tiles/>** — toggle the eight
neighbours and watch which of the 47 answers your case, and drop in a `TileSet`
`.tres` to get the list of neighbourhoods it cannot answer. Nothing is uploaded.

Everything below was measured against **Godot 4.7 stable**
(`4.7.stable.official.5b4e0cb0f`) by
[`verify_blob47.gd`](verify_blob47.gd), which sits next to this file:

```bash
godot --headless --script docs/verify_blob47.gd
# PASS per check, then "BLOB47 SWEEP: ALL PASS"; exit 0
```

## The eight bits

```
NW  N  NE          128  1   2
 W   ·   E   →      64   ·   4
SW   S  SE          32  16   8
```

Sides are `N`, `E`, `S`, `W`; corners are `NE`, `SE`, `SW`, `NW`.

## The rule: a corner only counts when both its sides are there

> **A corner bit is meaningful only if both of the side bits adjacent to it are
> also set.** A lone diagonal neighbour does not produce a distinct tile.

The reason is what the tile has to *draw*. `NE` describes the small square where
the north and east edges meet. If there is no neighbour to the north, that
corner of the cell is already an outside edge — whatever sits diagonally cannot
change the silhouette. There is nothing for a separate tile to look like.

So the 256 raw neighbourhoods collapse: keep all four side bits, and keep each
corner bit only when its two sides survive.

```gdscript
func canonical(mask: int) -> int:
    var m := mask & 0b01010101          # the four side bits, always kept
    if (mask & NE) and (mask & N) and (mask & E): m |= NE
    if (mask & SE) and (mask & S) and (mask & E): m |= SE
    if (mask & SW) and (mask & S) and (mask & W): m |= SW
    if (mask & NW) and (mask & N) and (mask & W): m |= NW
    return m
```

Run that over `0..255` and the image has exactly **47** elements. That is the
whole derivation.

### Counting it without enumerating

The count falls out of how many *adjacent side pairs* a tile has. Each of the
four pairs — N+E, E+S, S+W, W+N — that is **not** present leaves its corner bit
free, and a free bit doubles the number of raw neighbourhoods folding onto that
tile:

> a tile answers **2^(4 − adjacent side pairs present)** neighbourhoods

| adjacent side pairs | tiles | each answers | subtotal |
|---|---|---|---|
| 0 (`—`, `N`, `E`, `S`, `W`, `N+S`, `E+W`) | 7 | 16 | 112 |
| 1 | 8 | 8 | 64 |
| 2 | 16 | 4 | 64 |
| 4 (all four sides) | 16 | 1 | 16 |
| | **47** | | **256** |

Note the row that is missing: you cannot have exactly 3 adjacent pairs. Three
pairs means three corners are pinned, which forces all four sides, which is four
pairs. The engine agrees — `verify_blob47.gd` checks the formula tile by tile.

The 16 tiles at the bottom are the ones with all four sides present, each the
answer to exactly one neighbourhood — every diagonal matters, so nothing folds
onto them. The 7 at the top are the isolated and straight-run pieces, each
covering 16 raw neighbourhoods, because with no adjacent sides all four
diagonals are irrelevant at once.

## Asking the engine instead of the arithmetic

The rule above is a claim about what Godot does, so it was put to Godot. For
each mask `0..255`, `verify_blob47.gd` paints a centre cell plus exactly the
neighbours the mask names with `set_cells_terrain_connect()`, then reads the
terrain peering bits back off the tile **the engine chose**:

```
PASS  tileset loads (res://tiles/blobsmith_tileset.tres)
PASS  all 256 neighbourhoods painted a tile (0 empty)
PASS  engine agrees with the corner-needs-both-sides rule on all 256
PASS  engine distinguishes exactly 47 tiles (got 47)
PASS  a lone cell resolves to mask 0
PASS  all 8 neighbours resolves to mask 255
PASS  a lone NE corner is not distinguished from no neighbour at all
PASS  N+E without the NE corner differs from N+E+NE
PASS  each tile answers 2^(4 - adjacent side pairs) neighbourhoods
HISTOGRAM {"1":16,"4":16,"8":8,"16":7}
BLOB47 SWEEP: ALL PASS
```

The engine's read-back agrees with the rule on all 256, and the number of
distinct tiles it can reach is 47 — not 47-ish, and not dependent on the art.

## The trap: a missing tile is silently substituted

This is the part that costs an afternoon. Delete one tile from a blob set and
the neighbourhoods that needed it do **not** produce an error, a warning, or an
empty cell. The engine picks the closest tile it still has.

Measured by [`verify_blob47_holes.gd`](verify_blob47_holes.gd): take the
complete set, remove the fully-surrounded tile at atlas `(6, 5)` — 46 left — and
repaint a 3×3 block. The centre still gets a tile. It is a *different* tile,
missing a peering bit the neighbourhood actually has:

```
neighbourhood 255 (N+NE+E+SE+S+SW+W+NW)
    wanted tile 255 (N+NE+E+SE+S+SW+W+NW)
    engine used 247 (N+NE+E+S+SW+W+NW)
```

Every fully-surrounded cell in the map now renders with a notched south-east
corner, and nothing anywhere says so. If your autotiling "mostly works but looks
wrong in a few places", this is the first thing to rule out — run
`verify_blob47.gd` against your own set and it prints every neighbourhood in
this state:

```bash
godot --headless --script docs/verify_blob47.gd -- res://my_tileset.tres
```

## "But I only have 16 tiles"

Then your terrain set is probably in **`MATCH_SIDES`** (or `MATCH_CORNERS`)
mode, not `MATCH_CORNERS_AND_SIDES`. Those modes read 4 of the 8 neighbours, so
a complete set is 2⁴ = 16 tiles. Both are valid; they are different questions:

| terrain mode | neighbours read | complete set |
|---|---|---|
| `MATCH_SIDES` | 4 sides | 16 tiles |
| `MATCH_CORNERS` | 4 corners | 16 tiles |
| `MATCH_CORNERS_AND_SIDES` | all 8 | **47 tiles** |

No mode has 256. `verify_blob47.gd` checks the mode first and says so rather
than reporting a spurious failure.

## The full table

The engine's own sweep, one row per canonical tile: which mask it is, where it
sits in an 8-column blob sheet, and which of the 256 raw neighbourhoods resolve
to it. Sheet position is verified against the shipped tileset — the 47 masks in
ascending order occupy column `i % 8`, row `i / 8`.

| # | sheet cell | mask | neighbours the tile claims | answers | neighbourhoods that resolve to it |
|---|---|---|---|---|---|
| 0 | col 0, row 0 | `0` | — | 16 | 0, 2, 8, 10, 32, 34, 40, 42, 128, 130, 136, 138, 160, 162, 168, 170 |
| 1 | col 1, row 0 | `1` | N | 16 | 1, 3, 9, 11, 33, 35, 41, 43, 129, 131, 137, 139, 161, 163, 169, 171 |
| 2 | col 2, row 0 | `4` | E | 16 | 4, 6, 12, 14, 36, 38, 44, 46, 132, 134, 140, 142, 164, 166, 172, 174 |
| 3 | col 3, row 0 | `5` | N+E | 8 | 5, 13, 37, 45, 133, 141, 165, 173 |
| 4 | col 4, row 0 | `7` | N+NE+E | 8 | 7, 15, 39, 47, 135, 143, 167, 175 |
| 5 | col 5, row 0 | `16` | S | 16 | 16, 18, 24, 26, 48, 50, 56, 58, 144, 146, 152, 154, 176, 178, 184, 186 |
| 6 | col 6, row 0 | `17` | N+S | 16 | 17, 19, 25, 27, 49, 51, 57, 59, 145, 147, 153, 155, 177, 179, 185, 187 |
| 7 | col 7, row 0 | `20` | E+S | 8 | 20, 22, 52, 54, 148, 150, 180, 182 |
| 8 | col 0, row 1 | `21` | N+E+S | 4 | 21, 53, 149, 181 |
| 9 | col 1, row 1 | `23` | N+NE+E+S | 4 | 23, 55, 151, 183 |
| 10 | col 2, row 1 | `28` | E+SE+S | 8 | 28, 30, 60, 62, 156, 158, 188, 190 |
| 11 | col 3, row 1 | `29` | N+E+SE+S | 4 | 29, 61, 157, 189 |
| 12 | col 4, row 1 | `31` | N+NE+E+SE+S | 4 | 31, 63, 159, 191 |
| 13 | col 5, row 1 | `64` | W | 16 | 64, 66, 72, 74, 96, 98, 104, 106, 192, 194, 200, 202, 224, 226, 232, 234 |
| 14 | col 6, row 1 | `65` | N+W | 8 | 65, 67, 73, 75, 97, 99, 105, 107 |
| 15 | col 7, row 1 | `68` | E+W | 16 | 68, 70, 76, 78, 100, 102, 108, 110, 196, 198, 204, 206, 228, 230, 236, 238 |
| 16 | col 0, row 2 | `69` | N+E+W | 4 | 69, 77, 101, 109 |
| 17 | col 1, row 2 | `71` | N+NE+E+W | 4 | 71, 79, 103, 111 |
| 18 | col 2, row 2 | `80` | S+W | 8 | 80, 82, 88, 90, 208, 210, 216, 218 |
| 19 | col 3, row 2 | `81` | N+S+W | 4 | 81, 83, 89, 91 |
| 20 | col 4, row 2 | `84` | E+S+W | 4 | 84, 86, 212, 214 |
| 21 | col 5, row 2 | `85` | N+E+S+W | 1 | 85 |
| 22 | col 6, row 2 | `87` | N+NE+E+S+W | 1 | 87 |
| 23 | col 7, row 2 | `92` | E+SE+S+W | 4 | 92, 94, 220, 222 |
| 24 | col 0, row 3 | `93` | N+E+SE+S+W | 1 | 93 |
| 25 | col 1, row 3 | `95` | N+NE+E+SE+S+W | 1 | 95 |
| 26 | col 2, row 3 | `112` | S+SW+W | 8 | 112, 114, 120, 122, 240, 242, 248, 250 |
| 27 | col 3, row 3 | `113` | N+S+SW+W | 4 | 113, 115, 121, 123 |
| 28 | col 4, row 3 | `116` | E+S+SW+W | 4 | 116, 118, 244, 246 |
| 29 | col 5, row 3 | `117` | N+E+S+SW+W | 1 | 117 |
| 30 | col 6, row 3 | `119` | N+NE+E+S+SW+W | 1 | 119 |
| 31 | col 7, row 3 | `124` | E+SE+S+SW+W | 4 | 124, 126, 252, 254 |
| 32 | col 0, row 4 | `125` | N+E+SE+S+SW+W | 1 | 125 |
| 33 | col 1, row 4 | `127` | N+NE+E+SE+S+SW+W | 1 | 127 |
| 34 | col 2, row 4 | `193` | N+W+NW | 8 | 193, 195, 201, 203, 225, 227, 233, 235 |
| 35 | col 3, row 4 | `197` | N+E+W+NW | 4 | 197, 205, 229, 237 |
| 36 | col 4, row 4 | `199` | N+NE+E+W+NW | 4 | 199, 207, 231, 239 |
| 37 | col 5, row 4 | `209` | N+S+W+NW | 4 | 209, 211, 217, 219 |
| 38 | col 6, row 4 | `213` | N+E+S+W+NW | 1 | 213 |
| 39 | col 7, row 4 | `215` | N+NE+E+S+W+NW | 1 | 215 |
| 40 | col 0, row 5 | `221` | N+E+SE+S+W+NW | 1 | 221 |
| 41 | col 1, row 5 | `223` | N+NE+E+SE+S+W+NW | 1 | 223 |
| 42 | col 2, row 5 | `241` | N+S+SW+W+NW | 4 | 241, 243, 249, 251 |
| 43 | col 3, row 5 | `245` | N+E+S+SW+W+NW | 1 | 245 |
| 44 | col 4, row 5 | `247` | N+NE+E+S+SW+W+NW | 1 | 247 |
| 45 | col 5, row 5 | `253` | N+E+SE+S+SW+W+NW | 1 | 253 |
| 46 | col 6, row 5 | `255` | N+NE+E+SE+S+SW+W+NW | 1 | 255 |

## Reproducing this

- `godot --headless --script docs/verify_blob47.gd` — the 256-neighbourhood
  sweep above, against the set this repo's plugin generates.
- `godot --headless --script docs/verify_blob47.gd -- res://your.tres` — the
  same sweep against your set, with the gap report.
- `godot --headless --script docs/verify_blob47_holes.gd` — the substitution
  experiment: control, punch the hole, repaint, compare.

If a future Godot version changes any of this, those scripts fail loudly and
name the check, rather than letting this page drift quietly out of date.

## Further reading

- [`TileSet` terrain modes](https://docs.godotengine.org/en/stable/classes/class_tileset.html#enum-tileset-terrainmode) — the enum behind the table above.
- [`set_cells_terrain_connect`](https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html#class-tilemaplayer-method-set-cells-terrain-connect) — the call the sweep drives.
- [The `tile_map_data` binary format](tile-map-data-format.md) — what a painted layer serialises to, if you are generating maps outside the editor.

---

Part of [Blobsmith Autotile Wirer](../README.md), which takes a 47-blob sheet
and wires it into a Godot 4 `TileSet` with these peering bits already set. MIT.
Corrections welcome — open an issue with the tileset that disagrees.

The plugin assumes you already have the 47 tiles. Painting them is the other
half of the job: [Blobsmith](https://blobsmith.itch.io/blobsmith) is a pixel-art
tool that draws a 47-blob sheet in the layout this page describes, and
[Blobsmith Lite](https://blobsmith.itch.io/blobsmith-lite) is a free browser
version of it.
