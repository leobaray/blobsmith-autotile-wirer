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

Measured against **Godot 4.7.stable.official.5b4e0cb0f**, 22 checks, two
identical runs.

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

The "non-deterministic" claim does not reproduce. Three ways of asking:

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

That is the **unique** minimum-mismatch tile in the set: no remaining tile
disagrees on fewer than 1 bit, and exactly one tile ties at 1 (`T18`). The
engine scored every candidate and took the best. Visually: a field cell that
renders with a notch cut out of its bottom-right corner. Nothing about that
looks like "you are missing a tile", which is why people go looking for a bug
in the algorithm.

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

## Run it yourself

Copy the script into a Godot project and point it at **your** `.tres` — this
repo ships the addon, not a tileset, so there is no default set to fall back on:

```bash
# arg 1: a corners-and-sides TileSet (required)
godot --headless --script docs/verify_terrain_choice.gd -- res://your_tileset.tres

# arg 2 (optional): a sides-only TileSet, which is what T10-T13 need
godot --headless --script docs/verify_terrain_choice.gd -- res://your_tileset.tres res://sides16.tres
```

With no arguments it looks for `res://tiles/blobsmith_tileset.tres`, which is
where our own test project keeps it; in a fresh clone that path does not exist
and `T0` fails. The other two edges are just as loud on purpose: a path that
does not load fails `T0` and exits 1, and a set that is *not* in corners-and-
sides mode prints `SKIP` and exits 1 rather than pretending the corner claims
were checked. Omit arg 2 and `T10-T13` print `SKIP` — the remaining 18 still
run and still gate the exit code.

It prints `PASS`/`FAIL` per claim and exits non-zero if any stops holding, so
pointing it at a newer Godot tells you exactly which line of this page changed.

---

Part of [Blobsmith Autotile Wirer](../README.md), which turns 6 hand-drawn tiles
into a wired 47-tile Godot 4 `TileSet`. Related measurements in this repo:
[why a blob autotile has 47 tiles and not 256](why-47-tiles-not-256.md) and
[the `tile_map_data` binary format](tile-map-data-format.md).
