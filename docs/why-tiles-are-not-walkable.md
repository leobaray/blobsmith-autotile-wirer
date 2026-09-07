# My agent will not walk on the tiles I painted — the eight causes, measured

You painted a corridor on a `TileMapLayer`, gave the tile a navigation polygon,
asked `NavigationServer2D.map_get_path()` for a route, and got nothing back —
or got a route that stops halfway and never told you.

Every answer to this online is the same unordered list of eight possible
causes, with no way to tell which of them can even produce what you are seeing.
This page is that list with the guesswork taken out: each claim has an id
(`N1`, `N13`, …) and is asserted against a real engine by
[`verify_tile_navigation.gd`](verify_tile_navigation.gd), which exits non-zero
the moment one of them stops holding:

```
docs/verify_tile_navigation.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official**, 31 checks,
**31/31 on all three**. Last re-run **2026-09-07**. Needs 4.3 or newer:
`TileMapLayer` does not exist in 4.2, and there the script prints a SKIP rather
than a failure.

There is also a scanner for the five causes that are readable in the files the
editor already wrote, so you do not have to try them one at a time:

```
node docs/find_tile_navigation_gaps.js path/to/your_tileset.tres your_agent.gd
node docs/find_tile_navigation_gaps.js --json project/          # recurses
```

It reports the id of the claim behind each finding. What it cannot see is
stated below, because a clean result from it is not "navigation works".

---

## The subject under test

Six 16×16 cells painted in a row on one `TileMapLayer`, each carrying the same
`NavigationPolygon`, and a path asked from the middle of the first cell
`(8,8)` to the middle of the last `(88,8)`. Every number on this page comes
from that corridor.

---

## Cause 0: you are looking for Godot 3 nodes

- **N1** — there is no `Navigation2D` in Godot 4. The tutorial telling you to
  add one is for Godot 3.
- **N2** — there is no `NavigationPolygonInstance` either; the Godot 4 node is
  `NavigationRegion2D`.
- **N3** — and a `TileMapLayer` needs neither: `navigation_enabled` is a
  property of the layer and ships **on**.

`Navigation2D.get_simple_path()` is likewise gone; Godot 4 asks
`NavigationServer2D` or a `NavigationAgent2D`.

## Cause 1: the TileSet has no navigation layer

- **N4** — a `TileSet` starts with **zero** navigation layers. There is
  nowhere for a polygon to live, and the Navigation tab does not appear in the
  tile inspector.
- **N5** — with no navigation layer, setting a tile's navigation polygon
  **errors and stores nothing**. The error is on stderr; the editor does not
  stop you.
- **N6** — after `add_navigation_layer()` the same polygon is stored and reads
  back with its one polygon.

## Cause 2: you asked too early — and no number of frames is the answer

This is the one that produces the most wrong advice, because the advice is
always a number.

- **N8** — the regions do not exist on the first physics frame. Measured
  regions per frame: `[0, 6]` on 4.3, `[0, 6, 6]` on 4.4, `[0, 6, 6, 6, 6]`
  on 4.7.
- **N9** — one physics frame is not enough: the corridor still answers no path.
- **N7** — once settled, the map holds **one region per painted cell** (6 cells
  → 6 regions). A `TileMapLayer` is not one navigation mesh.
- **N11** — and then the corridor is walkable end to end (7 points, last
  `(88,8)`).

- **N10 — the frame that answers is not a constant. Not of the engine, and not
  of a build.** On an idle machine the first path comes back on frame 1 (4.3),
  2 (4.4) and 4 (4.7), six runs per build, identical every time — which is
  exactly what makes the table look like a fact. Put the **same 4.7 binary**
  under CPU contention (200 spinning shells on a 160-core box) and it answered
  on frames 2, 11, 13 and 20 across four runs: above the number tabled for it,
  and below it, crossing the values tabled for 4.3 and 4.4 on the way. The only
  safe statement is that frame 0 is too early.

  An earlier revision of the verifier asserted the idle table as an
  expectation. It was wrong, and it is the reason this claim exists.

- **N12** — `map_force_update()`, the usual "just force it" answer, **does**
  publish the regions immediately: six painted cells, six regions, no frame
  waited, on every build measured.
- **N12b** — and publishing the regions is not the same as answering a query.
  Whether a path comes back after the call is **not a property of the build**:
  4.3 answered, idle 4.4 and 4.7 did not, and a starved 4.7 did. Reported by
  the verifier, deliberately not asserted — a claim that measures both ways on
  one binary is not a pass/fail statement.

**N30 is what to do instead**, and it is asserted rather than recommended:
`NavigationServer2D.map_get_iteration_id()` (**N30a**) is the number the server
bumps when it has rebuilt. Poll it, ask once it has moved, and the same code
walks the corridor on 4.3, 4.4 and 4.7 with no per-build number anywhere in it —
including on the starved run where a hardcoded `await` is not correct.

```gdscript
var before := NavigationServer2D.map_get_iteration_id(map)
while true:
    await get_tree().physics_frame
    if NavigationServer2D.map_get_iteration_id(map) == before:
        continue
    var path := NavigationServer2D.map_get_path(map, from, to, true)
    if not path.is_empty():
        break
```

If you are asserting on the path itself, wait for the **path** to stop
changing: the region count and the iteration id can both be current while a
query still answers from the previous mesh (measured on a starved 4.7 — five
regions, moved id, and `map_get_path()` still returning the old six-cell
route).

## Cause 3: the polygon is authored around the wrong origin

The single most common silent one, because everything looks painted and the
agent walks in the neighbouring cell.

- **N13** — a tile's region is placed at the **cell centre**, not at its
  top-left corner.
- **N14** — so an outline authored `(0,0)`–`(16,16)` puts the walkable surface
  half a tile down and right: `(4,4)`, inside the only painted cell, is **off**
  the mesh.
- **N15** — while `(20,20)`, which is in the next cell over where nothing is
  painted, **is** walkable.
- **N16** — the centred outline `(-8,-8)`–`(8,8)` puts `(4,4)` on the mesh,
- **N17** — and pulls `(20,20)` back to the cell edge instead of accepting it.

## Cause 4: the layer bits do not match the agent

- **N18** — `TileSet.set_navigation_layer_layers(0, 2)` reaches the region as
  `navigation_layers = 2`.
- **N19** — a `NavigationAgent2D` ships with `navigation_layers = 1`, so it
  cannot use that corridor **at all**: zero points, no error.
- **N20** — the same query asked with `layers = 2` walks the whole corridor.

A navigation layer with `layers = 0` is the same failure with nothing to match
against.

## Cause 5: navigation is switched off on the layer

- **N21** — `navigation_enabled = false` removes every region. The cells stay
  painted; the map empties.
- **N22** — turning it back on restores them without repainting anything.

## Cause 6: a hole in the corridor — and it does not look like one

- **N23** — erasing one cell mid-corridor does **not** empty the path. It
  **truncates** it: 4 points, last `(48,8)`, instead of 7 points ending at
  `(88,8)`.
- **N24** — so `if path.is_empty()` never fires and the agent walks into the
  wall.
- **N25** — repainting the cell restores the end-to-end path.
- **N28** — a painted cell whose **tile carries no navigation polygon**
  produces no region: six cells, five regions, a hole in the middle of the
  corridor.
- **N29** — and the path over that hole is truncated exactly like an erased
  cell. Same symptom, different cause.

**Check the last point of the path against your target, not its emptiness.**

## Cause 7: the two settings that are not your problem

Worth stating, because both are widely recommended for this symptom and
neither can produce it here.

- **N26** — `map_set_use_edge_connections(false)` does not break a tilemap
  corridor. Neighbouring cells share an exact edge, so edge connections are not
  what is joining them.
- **N27** — `make_polygons_from_outlines()` still works and is deprecated;
  `NavigationServer2D.bake_from_source_geometry_data()` is the Godot 4 baking
  entry point. Neither is required for a tilemap corridor.

---

## What the scanner cannot see

Three of the causes above are not written down in any file, so a clean run of
`find_tile_navigation_gaps.js` does not mean navigation works:

- how long you waited before the first query (**N10** — no number exists),
- that `map_force_update()` publishes regions without making the map answer
  (**N12/N12b**),
- and that a corridor blocked halfway returns a **shorter** path rather than an
  empty one (**N23/N24**).

The scanner says this out loud on every clean result rather than reporting
success.

## Reproducing

```
docs/verify_tile_navigation.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

31 checks, exit 0 only if every one holds. The script builds its TileSet and
its corridor in memory and needs no assets from this repository. On 4.2 it
prints a SKIP and exits 0.

Two details of it are deliberate: it never uses the `World2D` navigation map
(in a `--script` SceneTree that map is never activated, so every query would
come back empty and every claim would "pass" for the wrong reason), and it
counts physics frames rather than awaiting a fixed number of them, because the
count is the thing under test.

## Related

- [I changed one tile and every copy changed](why-one-cell-changed-every-cell.md)
  — `get_cell_tile_data()` hands you the TileSet's object, not the cell's.
- [What a TileSet merge has to remap](merging-two-tilesets.md) — every index in
  a `TileData` only means anything inside its owning TileSet.
- [Why a blob autotile has 47 tiles and not 256](why-47-tiles-not-256.md).
