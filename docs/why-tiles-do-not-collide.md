# Your Godot 4 player walks through a painted tile — the six ways, measured

The tile is on screen. The player walks onto it and drops through it. There is
nothing in the output log, no warning in the editor, and the tile looks exactly
like the one two cells over that works.

Every answer to this online is a list of things to check, in no particular
order, with no way to tell which of them is even capable of causing what you are
seeing. This page is that list turned into measurements. Each claim has an id
(`C1`, `C11`, …) and each id is asserted against a real engine by
[`verify_tile_collision.gd`](verify_tile_collision.gd):

```
docs/verify_tile_collision.sh /path/to/Godot_v4.7-stable_linux.x86_64
godot 4.7-stable (official)
26 checks, 0 failed
```

Half of these cannot be answered by reading a property. The question is not
"what does the `TileSet` say" but "does the body stop", so the script builds a
real `TileMapLayer` and a real `CharacterBody2D` per case, lets the tree run a
physics frame, and calls `move_and_collide`.

**The geometry, so the numbers below can be read.** Tiles are 16×16 and painted
on row 2, so the row occupies `y = 32..48`. The body is a 4×4 box that starts at
`y = 24` and is pushed straight down. *Stopped at y = 32* therefore means it
landed on top of the tiles; *no collision* means it went through them.

---

## The six ways through, and the engine is silent for all six

| id | what is set | result |
|----|-------------|--------|
| `C11` | physics layer exists, that tile has **no polygon** | falls through |
| `C12` | polygon **count** set to 1, points never drawn | falls through |
| `C13` | `TileMapLayer.collision_enabled = false` | falls through |
| `C14` | `TileMapLayer.enabled = false` | falls through |
| `C15` | physics layer `collision_layer = 0` | falls through |
| `C16` | tiles on bit 2, body's mask on bit 1 | falls through |

Not one of them prints anything. For comparison, the same scene with a physics
layer and a real polygon stops the body at `y = 32` (`C10`).

Three of the six are not in the `TileSet` at all — `C13` and `C14` are
checkboxes on the *node*, and `C16` is a bit on the *body*. That is the reason
the tile "looks fine": you are inspecting the wrong object.

## The column that sends people the wrong way

A `TileSet` physics layer has two bit fields side by side, `collision_layer` and
`collision_mask`. Only the first one gates this. Set the physics layer's
**`collision_mask` to `0`** and the body **still stops** (`C17`).

That column is what the *tiles* detect, not permission for a body to stand on
them. If you are hunting a fall-through by flipping bits in it, you are flipping
bits that cannot produce the symptom.

## Before any of that: a new `TileSet` has nowhere to put a shape

A `TileSet` starts with **zero** physics layers (`C1`). Ask a tile about a
polygon on layer 0 before adding one and the engine pushes an error into the
log — and `get_collision_polygons_count(0)` still returns `0` (`C2`). Code that
checks the count instead of reading the log sees a perfectly ordinary zero.

Add the layer and it defaults to `collision_layer = 1` (`C3`) and
`collision_mask = 1` (`C4`), which is why "it just works" for most people and
why the two cases above (`C15`, `C16`) look like someone else's problem until
you inherit a project where those bits were edited.

## The edits that look applied and are not

A collision polygon needs 0 points or at least 3. Hand it 2 and the engine
refuses the assignment:

- the four points already on that tile are **left intact** — the bad edit is
  dropped, not applied (`C7`);
- on a polygon that never had points, it stays at 0 (`C7b`).

Both print an error and neither changes what you see in the picker. And a
polygon whose count is 1 with nothing drawn in it (`C12` — the state you get by
clicking *add polygon* and then moving on) is saved to disk **byte-identically**
to a tile with no polygon at all. On the file, and to the engine, they are the
same nothing.

## An alternative tile inherits nothing

`create_alternative_tile()` returns a tile with **no** collision shape from its
base (`C6`). If you use alternatives for variants — and an autotile terrain
often does — every one of them needs its own polygon.

This is not a corner case. In Godot's own `2d/platformer` demo, the tiles that
collide carry the polygon **rewritten on all eight** flip/transpose
alternatives, with the coordinates mirrored by hand:

```
0:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-32, -22, 32, -22, 32, 32, -32, 32)
0:0/1/flip_h = true
0:0/1/physics_layer_0/polygon_0/points = PackedVector2Array(32, -22, -32, -22, -32, 32, 32, 32)
```

That repetition is what "inherits nothing" costs in a real project.

## Flipping a cell flips the shape with the art

Paint an asymmetric polygon — the left half of the tile only — and the body
lands on the left half (`C18`) and falls through the right half (`C19`). Paint
the same cell with `TRANSFORM_FLIP_H` and the solid half moves to the right
(`C20`).

That is correct behaviour, and it means a mirrored cell cannot be debugged by
looking at the atlas alone: the shape you are inspecting is not the shape in
that cell.

## The shape is never clipped to the cell

32 px art on a 16 px grid, polygon drawn to the art: collision reaches **8 px
above** the cell — the body stops at `y = 24`, not `y = 32` (`C21`).

Invisible ledges floating above tall tiles are this, not a bug in your level.

## One-way tiles, and the step that walks straight through them

One-way is per polygon, and `one_way_margin` defaults to `1.0` (`C8`).

- arriving from **above** at 10 px per step: stops (`C22`);
- arriving from **below**: passes through, which is the entire point (`C23`);
- arriving from above at **48 px in one step**: passes through (`C24`);
- the **same** 48 px step against the same polygon **without** one-way: stops
  (`C25`).

So a one-way platform that a fast-falling player tunnels through is not a
mystery and not a physics bug: `C24` and `C25` isolate one-way as the
difference — same polygon, same 48 px step, one flag apart. The knob the engine
offers for it is `one_way_margin`, whose documented job is exactly this
("higher values … work better for colliders that enter the tile from a high
velocity"); this page measures its default (`C8`) and not its cure.

## And why none of this is visible

`Visible Collision Shapes` is a debug **draw** (`C9`). It renders the shapes
that are there, never the ones that are missing, and it shows nothing headless
and nothing in CI. There is no view in the editor whose job is to answer "which
of my painted tiles has no shape".

---

## Finding it in your own project

That last gap is what [`find_tile_collision_gaps.js`](find_tile_collision_gaps.js)
fills. It reads the text resources the editor already wrote — no engine, no
project import, no dependencies:

```
node docs/find_tile_collision_gaps.js /path/to/project
node docs/find_tile_collision_gaps.js --json project/
```

Exit `1` if it found anything, `0` if every painted tile carries a shape, so it
works as a CI gate. It reports three things: a `TileSet` with no physics layer
at all, a painted tile with no polygon, and an alternative without a polygon of
its own.

Nothing to clone if you would rather not: it ships in an MIT zip with the
studio's other Godot scanners, no email and no account, at
<https://blobsmith.lbwma.com/godot-scanners/>.

**What it cannot see, so a clean run is not read as more than it is:** `C13`
through `C17` live in node state and layer bits, not in the tileset file. A
green result means every painted tile carries a shape. It does not mean
collision works.

### Run against Godot's own demos

Measured today against
[`godotengine/godot-demo-projects`](https://github.com/godotengine/godot-demo-projects)
at `34fc995` — **13 files with a `TileSet`, 703 painted tiles, 75 findings**:

- **5 × `no-physics-layer`**, one per tileset: the hexagonal map, the A\*
  navigation demo, and the three grid-movement tilesets of the RPG demo. Those
  demos move on a grid or a graph and never ask physics about a tile. The
  finding is correct and the tilesets are correct — which is why this rule
  reports once per file and not once per tile.
- **70 inside tilesets that do collide elsewhere**: the two platformer demos
  contribute 3 tiles and 21 alternatives each, next to more than a hundred
  polygons that are drawn. Those are decoration and background props, and
  deciding that is a human's job — the scanner lists what a body will pass
  through, it does not know what you meant.

Read it as a list to review, not as 75 bugs in the official demos. The number
that matters in your project is the one you cannot explain.

---

## The order to check things in

1. Does the `TileSet` have a physics layer at all (`C1`)?
2. Does **that tile** have a polygon with points in it (`C11`, `C12`)? The
   scanner above answers 1 and 2 for the whole project at once.
3. Is it an **alternative**? It inherits nothing (`C6`).
4. On the node: `collision_enabled`, `enabled` (`C13`, `C14`).
5. Bits: physics layer `collision_layer` vs the body's `collision_mask`
   (`C15`, `C16`) — and *not* the layer's `collision_mask` column (`C17`).
6. Still through it? Measure the step size before blaming physics (`C24`).

---

Part of [Blobsmith Autotile Wirer](../README.md), the free Godot 4 plugin (MIT)
that wires a flat autotile sheet into a `TileSet`. Related measured references
in this repo: [what actually decides tile draw
order](why-y-sort-draws-the-wrong-order.md), [why a blob autotile is 47 tiles
and not 256](why-47-tiles-not-256.md), [what the engine picks when terrain
painting falls short](why-terrain-paints-the-wrong-tile.md), [the four causes of
a thin line between tiles](why-tiles-have-seams.md), and [the byte layout of
`tile_map_data`](tile-map-data-format.md).

Which half of the problem the plugin owns: when you ask it to, it writes **one
full-square collision polygon per tile** on physics layer 0 as it wires the 47
tiles — so the `C11` case does not happen to a set it generated. It does not
draw per-shape edge collision, it does not touch the node checkboxes of `C13`
and `C14`, and it does not choose your layer bits. The scanner, the probe and
this page are MIT and cost nothing; the plugin they live in is free too, and the
paid [Blobsmith](https://blobsmith.itch.io/blobsmith) is the pixel-art side —
drawing the 6 tiles that become the sheet, with a free browser version at
[Blobsmith Lite](https://blobsmith.itch.io/blobsmith-lite).
