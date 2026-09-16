# `set_cells_terrain_connect` is slow in procedural generation — what it costs and what to do instead

You generate a map in code, paint it with `set_cells_terrain_connect`, and the
generation step that took milliseconds now takes seconds. Or you paint cell by
cell inside the generator loop and it gets slower still.

This page measures what the call costs, how that cost grows, whether the ways
people work around it (one call per cell, one call per chunk, computing the tile
yourself) change the map, and how much faster the last one is. Every claim has
an id (`A1`, `P2`, …) and is asserted by
[`verify_terrain_connect_speed.gd`](verify_terrain_connect_speed.gd) against a
real binary:

```
docs/verify_terrain_connect_speed.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 16 checks,
16/16 on all three, headless. `K1` is a control that fails if the map comparison
stops telling two maps apart, and `--invert` flips `A1` and `P2` on purpose: it
exits 1 on all three. A GDScript parse error exits 3, not 0. Last run
**2026-09-16**. Needs 4.3 or newer — `TileMapLayer` does not exist in 4.2.

The test map: one atlas source, 47 tiles, one terrain set in
Match Corners and Sides with one terrain, built in memory the same way
[`wirer_core.gd`](../addons/blobsmith_wirer/wirer_core.gd) builds a TileSet. The
map is a 128×128 square where each cell is land with probability 0.6 (seed
`1234`): 9852 land cells. Noise on purpose — it produces isolated cells, one-wide
strips and every one of the 47 neighbourhoods; the engine used all 47 tiles on it
(`S1`).

---

## The short answer

If your TileSet is a complete 47-tile set (every neighbourhood has a tile), you
do not need the terrain solver at generation time. Compute each land cell's
8-neighbour mask, drop the corner bits that do not count, look the tile up, and
call `set_cell`:

```gdscript
const BITS := {
	1: TileSet.CELL_NEIGHBOR_TOP_SIDE, 2: TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	4: TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 8: TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	16: TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, 32: TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	64: TileSet.CELL_NEIGHBOR_LEFT_SIDE, 128: TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
}
const OFFSETS := {
	1: Vector2i(0, -1), 2: Vector2i(1, -1), 4: Vector2i(1, 0), 8: Vector2i(1, 1),
	16: Vector2i(0, 1), 32: Vector2i(-1, 1), 64: Vector2i(-1, 0), 128: Vector2i(-1, -1),
}

# Once per TileSet: mask -> atlas coords, read from the tiles' own peering bits.
func tile_lookup(ts: TileSet, source_id: int, terrain: int) -> Dictionary:
	var src := ts.get_source(source_id) as TileSetAtlasSource
	var out := {}
	for i in src.get_tiles_count():
		var coords := src.get_tile_id(i)
		var td := src.get_tile_data(coords, 0)
		if td.terrain != terrain:
			continue
		var m := 0
		for bit in BITS:
			if td.get_terrain_peering_bit(BITS[bit]) == terrain:
				m |= bit
		out[m] = coords
	return out

# A corner only counts when both sides next to it are land.
func canonical_mask(mask: int) -> int:
	var m := mask & 0b01010101
	if mask & 2 and mask & 1 and mask & 4: m |= 2
	if mask & 8 and mask & 16 and mask & 4: m |= 8
	if mask & 32 and mask & 16 and mask & 64: m |= 32
	if mask & 128 and mask & 1 and mask & 64: m |= 128
	return m

func paint(layer: TileMapLayer, cells: Array[Vector2i], lookup: Dictionary) -> void:
	var land := {}
	for c in cells:
		land[c] = true
	for c in cells:
		var m := 0
		for bit in OFFSETS:
			if land.has(c + OFFSETS[bit]):
				m |= bit
		layer.set_cell(c, 0, lookup[canonical_mask(m)])
```

On the test map this produced **the same map as one `set_cells_terrain_connect`
call, 0 of 16900 cells different** (the square plus a one-cell border, `B1`), on
4.3, 4.4 and 4.7. It ran 38× to 56× faster (`P2`, numbers below). The corner
rule is the whole trick; why it is 47 and not 256 is in
[why 47 tiles, not 256](why-47-tiles-not-256.md). The control `K1` runs the same
lookup with raw masks (corner rule skipped): 7767 cells differ, so the comparison
does see a wrong map.

`tile_lookup` reads the peering bits back from the TileSet (`S2`: 47 masks, one
tile each), so it does not depend on the order of tiles in your sheet.

## What the call costs

Median of 3 runs, same machine, same map, milliseconds:

| | 4.3 | 4.4 | 4.7 |
|---|---:|---:|---:|
| one `set_cells_terrain_connect` call, 128×128 (9852 cells) | 778.1 | 719.1 | 564.8 |
| one call per cell, same cells | 3154.4 | 2910.4 | 2148.6 |
| one call per 16×16 chunk | 881.7 | 808.6 | 643.0 |
| precomputed mask + `set_cell` (the code above) | 13.8 | 16.0 | 14.6 |
| one call, 64×64 (2479 cells) | 195.6 | 182.2 | 144.5 |
| cost per land cell, one call | 79.0 µs | 73.0 µs | 57.3 µs |

What the script asserts from that, with wide margins because wall time is noisy:

- **`P1`** — one call per cell is at least 2× slower than one call. Measured
  **4.1× / 4.0× / 3.8×**. The loop is slower, but by about 4×, not by an
  order of magnitude.
- **`P2`** — one terrain call is at least 10× slower than the precomputed
  `set_cell` loop. Measured **56.2× / 45.1× / 38.6×**. The `set_cell` time is all
  GDScript (dictionary, 8 lookups per cell) and stays near 14–16 ms on every
  version; the terrain call got faster from 4.3 to 4.7, so the gap narrows.
- **`P3`** — going from 64×64 to 128×128 (3.97× the land cells), one call takes
  between 2× and 8× the time. Measured **3.98× / 3.95× / 3.91×**: the cost is
  linear in the cells you pass, a fixed ~57–79 µs each, not quadratic. A 512×512
  map at this density would be roughly 16× the 128×128 numbers — extrapolated,
  not measured.
- **`P4`** — 16×16 chunks cost within 3× of one call either way. Measured
  **1.13× / 1.12× / 1.14×** — slightly slower, not faster. Chunking does not buy
  speed; it only spreads the same cost over frames if you paint one chunk per
  frame.

Painting the same cells again on a layer that already holds the map cost the same
as painting an empty layer (803.6 / 744.1 / 600.5 ms, one run each, printed but
not asserted). Repainting a map that is already correct is not cheaper.

## Why a loop gives the same map — and still pays more

**A call rewrites cells you did not list.** Erasing one cell through the terrain
API (`set_cells_terrain_connect([cell], 0, -1)`) inside a filled 20×20 block
changed 9 cells: that cell and its 8 neighbours, which lost a connection (`N2`).
Painting one cell next to existing tiles has to do the same, or `A1` below could
not hold. That is what makes piecemeal painting correct: every
call fixes up the neighbours of what it touched.

So the results do not depend on how you split the work, on this set:

- one call for all 9852 cells vs one call per cell, in row order: **0 cells
  differ** (`A1`);
- one call per 16×16 chunk: **0 cells differ**, no seam at chunk edges (`A2`).

And on an empty layer one call writes exactly the listed cells, no more
(`N1`: 9852 used, 9852 listed) — the neighbours it rewrites are neighbours that
already hold a tile.

A reading consistent with `N2` and `P1`, not measured directly: the per-cell
loop pays for fixing up intermediate states that the next call overwrites. The
script does not measure the solver's internals.

## `set_cells_terrain_path` is not a faster `connect`

`path` joins each cell only to the one before and after it in the array. On a
2×2 block given in ring order `(0,0) (1,0) (1,1) (0,1)`:

| cell | `connect` mask | `path` mask |
|---|---|---|
| (0,0) | 28 (E, SE, S) | 4 (E) |
| (1,0) | 112 (S, SW, W) | 80 (S, W) |
| (1,1) | 193 (N, W, NW) | 65 (N, W) |
| (0,1) | 7 (N, NE, E) | 4 (E) |

`connect` joins every pair, corners included (`C1`); `path` joins no corners and
does not close the ring from the last cell back to the first (`C2`). On a straight
3-cell line they agree (`C3`). For a filled region from a noise or height map,
`path` gives a different map, not a quicker version of the same one.

## When the precomputed lookup is not enough

The lookup reproduces the solver only when there is exactly one tile for each of
the 47 masks. If your set is missing tiles, the engine substitutes a different
tile and the lookup has no entry for that mask — see
[why terrain paints the wrong tile](why-terrain-paints-the-wrong-tile.md). If a
mask has several tiles (variants with probabilities), pick among them yourself;
the lookup above keeps only the last one it read.

## Checklist

1. Painting inside the generator loop, one call per cell → same map, ~4× the
   cost of one call (`A1`, `P1`). Collect the cells, call once.
2. Splitting into chunks for speed → same map, same cost (`A2`, `P4`).
3. Still too slow with one call → the cost is ~60–80 µs per cell and linear
   (`P3`); with a complete 47-tile set, compute the mask and `set_cell`: same map,
   38–56× faster here (`B1`, `P2`).
4. Using `set_cells_terrain_path` for areas → it only joins consecutive cells
   (`C2`).

## What this file does not measure

- Timings on any machine but the one the script last ran on. The table is one
  run of the script; the milliseconds are printed, never asserted. Only the
  ratios `P1`–`P4` are checked, and a heavily loaded machine can still move them.
- Maps larger than 128×128, fill densities other than 0.6, or smooth blobs
  instead of noise. The 512×512 figure above is extrapolated from `P3`.
- TileSets with more than one terrain, more than one terrain set, variants of the
  same mask, missing tiles, or `Match Sides` / `Match Corners` modes.
- The `ignore_empty_terrains` argument (left at its default) and painting next to
  cells of another terrain.
- The legacy `TileMap` node, and C# or GDExtension callers — the `set_cell` loop
  here is GDScript; its 14–16 ms is mostly interpreter cost.
- Rendering, physics or navigation rebuild cost after the cells change: every
  number above is the call itself, before any frame is drawn.
- Why the solver costs what it costs; only its observable behaviour (`N2`) and
  timing.
