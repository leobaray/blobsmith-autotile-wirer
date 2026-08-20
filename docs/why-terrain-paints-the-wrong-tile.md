# Godot 4 terrain painting puts the wrong tile down — what the engine actually does

You paint a terrain, and one cell comes out visibly wrong: a corner piece in the
middle of a field, a seam that should not be there, an edge tile facing the wrong
way. Search for it and page 1 gives you two answers that cannot both be true:

- *"Godot picks the closest match."* — said without saying what "closest" means.
- *"The terrain algorithm is non-deterministic."* — said without a repro.

Both are guesses. This page is the measurement instead. Every claim below has an
id (`T1`, `T4`, …) and is asserted by
[`verify_terrain_choice.gd`](verify_terrain_choice.gd), which re-runs the whole
thing against your Godot build and exits non-zero if any of it stops holding.

Measured against **Godot 4.7.stable.official.5b4e0cb0f**, 24 checks, two
identical runs. Last re-run **2026-08-18**.

There is a browser version of the sweep, with a region you paint and no install:
[**godot-terrain-wrong-tile**](https://blobsmith.lbwma.com/godot-terrain-wrong-tile/).

---

## The short answer

Terrain painting in 4.7 is **deterministic**, and it picks the tile that
**disagrees with the fewest peering bits** — restricted to tiles that belong to
the terrain you are painting. It will never leave the cell empty and never
borrow a tile from a neighbouring terrain. That last part is the whole reason
you see a wrong tile instead of an error: *the engine would rather give you an
ugly tile of the right terrain than no tile at all.*

So a wrong tile almost always means **your set cannot answer that
neighbourhood** — not that the algorithm misfired.

## It is not random

The "non-deterministic" claim does not reproduce. Five ways of asking:

| id | what was done | result |
|----|---------------|--------|
| `T1` | the same paint repeated 30× in 30 fresh layers | **1** distinct tile |
| `T2` | the same cells passed in reversed array order | same tile |
| `T3` | the region painted cell-by-cell vs all at once | same tiles |
| `T13` | 30× repeat of a neighbourhood with **no** exact match | **1** distinct tile |
| `T19` | 20× repeat with the needed tile deleted from the atlas | **1** distinct tile |

Same input, same output — including in the ambiguous cases, which is where a
random tie-break would show up if there were one.

## What it picks when nothing matches

Take the complete 47-tile blob set, and **delete** the one tile that means
"surrounded on all eight sides" (mask `255`). Then paint a 3×3 block, whose
centre needs exactly that tile.

The centre cell is still painted (`T17`) — not left empty, no error, no warning.
It gets the tile with mask **247**:

```
wanted:  255  = N NE E SE S SW W NW
placed:  247  = N NE E    S SW W NW      (247 = 255 - 8, the SE corner bit)
                        ^^ one bit off
```

One bit off is the best any remaining tile can do (`T18`): the engine scored
every candidate and took a minimum. Visually: a field cell that renders with a
notch cut out of its bottom-right corner. Nothing about that looks like "you are
missing a tile", which is why people go looking for a bug in the algorithm.

But **247 is not the only tile that scores 1**. So do `127`, `223` and `253`,
and nothing in the score decides between the four.

### The score tells you how wrong, never which tile

This page used to say "exactly one tile ties at 1", citing `T18`. `T18` never
asserted that: the note beside it printed `available.count(got)`, which is how
many times *one* mask appears in the array — in a set with no duplicate tiles,
always 1. Corrected on 2026-08-18, and replaced with a sweep instead of a single
sample. Knock out each of the 47 tiles in turn and ask for exactly the
neighbourhood that tile answered:

| id | over all 47 holes | result |
|----|-------------------|--------|
| `T20` | is the substitute always a minimum-mismatch tile? | **47 of 47** — yes, every time |
| `T21` | how often does exactly one tile reach that minimum? | **0 of 47**. Between **3 and 8** tiles tie |

So the rule in "the short answer" holds everywhere, and it is *not* a rule that
names a tile. Which of the tied tiles you get is deterministic (`T19`) but is not
the lowest-numbered one (2 of 47) and not the first one in the atlas (7 of 47).
Predict how wrong the cell will look; do not predict what goes in it.

Three of the checks above only started measuring the whole set on 2026-08-18.
`load()` on the same path hands back the same cached `TileSet`, so the blocks
that *mutate* a set — deleting a tile for the hole test, moving a tile out of
terrain 0 — were quietly editing the "complete set" that later checks swept.
`T16` said "with a complete set" while running against 46 tiles. The three now
load with `CACHE_MODE_IGNORE_DEEP`; if you vendor this script, keep that.

The same rule with a sides-only set (`T12`): the fallback still matches **every
side** the neighbourhood asked for, and only ever gives up corner information.

## It never reaches into another terrain

There is a well-travelled issue titled *"TileMap Terrain paints incorrect tiles
from unrelated terrains"*. On 4.7 we could not make that happen.

Build one terrain set holding **two** terrains, where terrain 0 cannot answer
every neighbourhood, and sweep all 256 of them (`T15`): a tile belonging to
terrain 1 was placed **0 times out of 256**. With a complete set, the painted
cell belongs to the requested terrain in all 256 (`T16`).

Stronger still (`T7`, `T7b`): make the *only exact match* a tile that belongs to
**no terrain at all**. The engine still refuses it and places the 1-bit-off
tile from terrain 0 instead. Candidacy is decided by terrain membership first,
score second.

If your terrain looks like it borrowed a tile from a neighbour, check whether
those tiles are assigned to the terrain you think they are.

## The empty cells around your painted region are constraints

This is the most common surprise, and it is not a bug.

Paint a 3×3 block on an empty layer. The centre gets the fully-surrounded tile
(`T4`), and the corner does **not** (`T5`):

```
corner (0,0):  mask 28   = E SE S          — an outer-corner tile
edge   (1,0):  mask 124  = E SE S SW W     — a top-edge tile
centre (1,1):  mask 255                    — fully surrounded
```

The empty cells outside the block count as "not this terrain", so the border of
anything you paint gets edge tiles. If you are generating a map in chunks, the
seam between two chunks is painted against emptiness and then **rewritten** when
the neighbouring chunk arrives (`T9`: painting a cell rewrites the tile of the
cell already next to it). Paint the whole region in one call, or accept that
borders are provisional.

### `ignore_empty_terrains` does not turn that off

`set_cells_terrain_connect()` takes a 4th argument, `ignore_empty_terrains`, and
it is the first thing people reach for here. In three constructions it changed
**nothing** on 4.7:

- neighbours are cells with no tile at all → 0 of 9 cells differ (`T6`)
- neighbours hold a tile belonging to no terrain → no difference
- the only exact match is a tile belonging to no terrain → no difference (`T7`)

**Honest limit of this one:** a negative result is not proof that the flag does
nothing — it means we could not build a case on 4.7 where it bites, and the
three obvious readings of its name are all wrong. If you have a repro where it
changes the output, it belongs in an issue on this repo; it becomes a fixture.
What we can say is: if you are chasing a wrong border tile, this flag is not the
lever.

## The terrain *mode* decides what is knowable

A terrain set has a mode, and it silently caps what your tiles can express:

| mode | bits used | distinct neighbourhoods |
|------|-----------|------------------------|
| `MATCH_CORNERS_AND_SIDES` | all 8 | 47 |
| `MATCH_SIDES` | 4 sides | 16 |
| `MATCH_CORNERS` | 4 corners | 16 |

A sides-only set paints all 256 neighbourhoods without complaint (`T10`) and can
only ever produce its own 16 tiles (`T11`). It is not broken and not incomplete
— it simply cannot see corners, so every corner-only difference collapses to the
same tile. If you drew 47 tiles and the set is in sides mode, 31 of them are
unreachable and you will never be told.

(There is no `is_valid_terrain_peering_bit()` on `TileSet` in 4.7 — asking a
sides-only set for a corner bit is an engine error, not a zero. Derive the valid
bits from `get_terrain_set_mode()`, as the script does.)

## So: why is my tile wrong?

In the order worth checking:

1. **Your set has no tile for that neighbourhood.** By far the most common. The
   engine substitutes silently, so the only way to see it is to sweep.
   [`verify_blob47.gd`](verify_blob47.gd) takes **your** `.tres` and lists every
   neighbourhood your set cannot answer plus the tile the engine substitutes.
2. **The terrain mode does not match the sheet you drew.** 16 vs 47.
3. **The peering bits are painted wrong on the tile.** The classic advice, and
   the one page 1 gives — it is real, just third in line.
4. **The cell is on the border of what you painted**, against empty cells. Not a
   bug; see above.

## The same sweep without an engine

`verify_terrain_choice.gd` needs Godot. The sweep of *your* set does not, because
the neighbourhood each cell asks for is decided by the region you paint
(`T4`/`T5`/`T9`) and the tiles you own are in the `.tres`:

```bash
# which cells of a 5x3 block your set has no tile for
node docs/predict_terrain_paint.js your_tileset.tres --rect 5x3

# and what the chunk seam does to the first half (T9)
node docs/predict_terrain_paint.js your_tileset.tres --rect 6x3 --chunks
```

No dependencies, exits 1 if any cell of the region has no exact tile, `--json`
for a build script. The logic is [`terrain-choice-core.js`](terrain-choice-core.js),
which is also the file the web page runs, byte for byte.

It is a model of the engine, so it is pinned to the engine:
[`dump_terrain_paint_fixtures.gd`](dump_terrain_paint_fixtures.gd) reads the
masks Godot actually places for 12 regions in both terrain modes into
[`terrain-paint-fixtures.json`](terrain-paint-fixtures.json), and
`test/web-terrain.test.js` replays **258 cells** and fails on one disagreement.
It reports the tie set and refuses to name the placed tile, for the reason `T21`
measured above.

## Run it yourself

Copy the script into a Godot project and point it at **your** `.tres` — this
repo ships the addon, not a tileset, so there is no default set to fall back on:

```bash
# arg 1: a corners-and-sides TileSet (required)
godot --headless --script docs/verify_terrain_choice.gd -- res://your_tileset.tres

# arg 2 (optional): a sides-only TileSet, which is what T10-T13 need
godot --headless --script docs/verify_terrain_choice.gd -- res://your_tileset.tres res://sides16.tres
```

The two defaults are `res://tiles/blobsmith_tileset.tres` and
`res://tiles/sides16.tres`, which is where our own test project keeps them; in
a fresh clone neither path exists and `T0` fails. The other edges are just as
loud on purpose: a path that does not load fails `T0` and exits 1, and a set
that is *not* in corners-and-sides mode prints `SKIP` and exits 1 rather than
pretending the corner claims were checked. Omit arg 2 and the six claims that
need a sides-only set (`T10-T15`) print `SKIP` — the remaining **16** still run
and still gate the exit code.

Measured on 2026-08-18 against 4.7.stable: with both sets, 24 PASS / 0 SKIP,
exit 0.

It prints `PASS`/`FAIL` per claim and exits non-zero if any stops holding, so
pointing it at a newer Godot tells you exactly which line of this page changed.

---

Part of [Blobsmith Autotile Wirer](../README.md), which turns 6 hand-drawn tiles
into a wired 47-tile Godot 4 `TileSet`. Related measurements in this repo:
[why a blob autotile has 47 tiles and not 256](why-47-tiles-not-256.md),
[why tiles show thin seams between them](why-tiles-have-seams.md),
[the `tile_map_data` binary format](tile-map-data-format.md) and
[which painted tiles a body walks straight through](why-tiles-do-not-collide.md).

If the wrong tile is going down because the sheet itself is in an unexpected
order, [Blobsmith](https://blobsmith.itch.io/blobsmith) is the pixel-art tool
that draws the sheet in the canonical layout the wirer expects; [Blobsmith
Lite](https://blobsmith.itch.io/blobsmith-lite) is a free browser version.
