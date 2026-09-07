# I changed one tile at runtime and every copy of it changed — what `get_cell_tile_data()` actually returns

Two bug reports on the Godot tracker are the same bug, and neither title says so:

- [#108067](https://github.com/godotengine/godot/issues/108067) — *"Calling
  `set_custom_data()` on TileData is changing all TileData in TileMapLayer"*
- [#93327](https://github.com/godotengine/godot/issues/93327) — *"Runtime
  TileData modifications are reset after TileMapLayer `_rendering_update`"*

The first one is surprised the write went too far. The second is surprised it
did not last. Both follow from one fact that neither report states: **a cell
does not own a TileData. The TileSet does.** `get_cell_tile_data()` hands you
the atlas's object, and every cell drawn from that tile is looking at the same
one.

This page is the measurement. Every claim has an id (`S1`, `S13`, …) and is
asserted by [`verify_tile_data_sharing.gd`](verify_tile_data_sharing.gd), which
re-runs all of it against your own build and exits non-zero if any of it stops
holding:

```
docs/verify_tile_data_sharing.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Point it at your own tileset to see the sharing on your tiles — it runs inside
your project, because a `.tres` names its texture with a `res://` path that
resolves nowhere else:

```
docs/verify_tile_data_sharing.sh /path/to/godot /path/to/your_tileset.tres
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**, 22
checks, identical results on all three. Last re-run **2026-09-07**. Needs 4.3 or
newer — `TileMapLayer` does not exist in 4.2, and on 4.2 the script prints a
SKIP rather than a failure.

---

## The short answer

```gdscript
var td := layer.get_cell_tile_data(Vector2i(0, 0))
td.set_custom_data("hp", 3)
```

That second line did not set the hp of *a cell*. It set the hp of *a tile*, in
the TileSet, for the rest of the process — and, if anything saves that TileSet,
for the rest of the project's life.

Concretely, measured:

- Two cells placed from the same atlas tile return **one object**, not two
  equal ones (`S1`) — same `get_instance_id()`.
- That object **is** `TileSetAtlasSource.get_tile_data(coords, alt)` (`S2`). It
  is not a copy handed to the cell; it is the TileSet's property.
- So a write through one cell is read back through the other (`S5`), through
  the TileSet itself (`S6`), and through a cell in a **different
  `TileMapLayer`** that merely shares the TileSet (`S9`, `S10`).
- It is not global, though: a cell of a *different* atlas tile is a different
  object (`S3`) and does not see the write (`S8`). **The blast radius is the
  tile, not the layer.**

## Flipped cells are not an exception

A cell placed with a transform bit resolves to the **same TileData as the
unflipped cell** (`S4`) and sees the same write (`S7`).

This is the general rule behind the narrower one measured in
[a flipped tile is not a new tile](why-a-flipped-tile-is-not-a-new-tile.md): a
flip has no TileData of its own to carry anything on, because a *cell* never
has one.

## It is not just custom data

`set_custom_data()` is how people usually notice, but nothing about it is
special. Collision is shared identically — a polygon added at runtime through
one cell is counted by the other (`S11`). Everything reachable through a
`TileData` reference behaves this way: terrain bits, z-index, navigation,
occlusion, modulate.

## The part no bug report mentions: the write outlives the run

This is the one worth knowing before you ship. After the runtime write, saving
the TileSet succeeds (`S12`) and **the saved file contains the runtime value**
(`S13`):

```
ResourceSaver.save(tile_set, "user://out.tres")   # -> OK
# the .tres now literally contains "written-via-A"
```

So a change you thought was a temporary in-game state is a change to a
*resource*. If the tileset is open in the editor when this runs — a `@tool`
script, a plugin, an in-editor test — the editor holds the mutated object, and
the next save writes your runtime state into the file under version control.
That is the mechanism behind "my tileset changed and I didn't touch it".

## Why the write also seems to *vanish* (#93327)

Both reported symptoms come from the same ownership. The engine treats the
TileSet's TileData as the authority and rebuilds what it draws from it. A
runtime write is therefore neither yours nor durable: too wide while it lasts,
and liable to be re-derived out from under you.

**We do not claim a measurement here.** The engine's answer for per-cell
runtime variation is
[`TileMapLayer._tile_data_runtime_update()`](https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html)
with `_use_tile_data_runtime_update()`, which lets you re-apply per-cell changes
as the layer builds. In our headless runs that hook fired **zero** times after
both `notify_runtime_tile_data_update()` and `update_internals()`, so the verify
script asserts nothing about it and neither does this page. Test it in your own
running game before relying on it.

## There is no private copy to take

The obvious escape is to take one:

```gdscript
var mine: TileData = td.duplicate()   # there is no such method
```

**`TileData` is not a `Resource`.** It extends `Object`
(`ClassDB.get_parent_class("TileData")` is `"Object"`, `S20`;
`is_parent_class("TileData", "Resource")` is `false`, `S21`), and it has no
`duplicate()` at all (`S22`) — on 4.3, 4.4 and 4.7 alike. The call raises
`Invalid call. Nonexistent function 'duplicate' in base 'TileData'`.

Worth knowing, because it is easy to misread as an engine bug: after that
error a `--script` run *appears to hang*. It is not stuck in `duplicate()`.
A runtime error in a `SceneTree._init()` never reaches `quit()`, so the
process just keeps running — a nonexistent call on a plain `Node` leaves it
sitting there in exactly the same way (measured as a control on 4.3 and 4.7;
an error-free script quits normally). Killing it tells you nothing about
`TileData`.

The consequence is the real point: `duplicate()` is not a workaround you are
missing, and neither is any other private copy. The object is the TileSet's,
and the only ways not to share it are below.

## What to do instead

**Per-cell state that is yours** — hp, ownership, damage, visited-ness — does
not belong in TileData at all. Keep it in your own `Dictionary` keyed by cell
coordinates. It is the only option here that is genuinely per-cell, and it
serialises with your save game instead of with your tileset:

```gdscript
var cell_hp := {}                      # Vector2i -> int
cell_hp[Vector2i(0, 0)] = 3
```

**A genuinely different tile** — a variant that should differ everywhere it is
placed — is `create_alternative_tile()`. It does give you a distinct TileData
object (`S14`). Know what it costs: the alternative inherits **nothing** from
the tile it was made from. Measured on a base tile carrying custom data, a
terrain, a collision polygon and `z_index = 42`, the fresh alternative came back
with custom data `null` (`S15`), `terrain_set` `-1` (`S16`), `terrain` `-1`
(`S17`), zero collision polygons (`S18`) and `z_index` `0` (`S19`).

That blankness is, we suspect, most of why people mutate the shared object
instead: the correct tool starts empty and every property has to be set by hand.

**Static per-tile data** — what this tile *is*, the same everywhere — is exactly
what custom data layers are for. Set it in the editor, or once at import, and
then only ever read it at runtime. The sharing that causes this bug is the
intended behaviour for that use.

---

## Reproducing

```
docs/verify_tile_data_sharing.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

22 checks, exit 0 only if every one holds. The script builds its own TileSet in
memory and needs no assets from this repository. On 4.2 it prints a SKIP and
exits 0.

## Related

- [A flipped tile is not a new tile](why-a-flipped-tile-is-not-a-new-tile.md) —
  the transform bits, and why a flipped cell has no TileData of its own.
- [Why a blob autotile has 47 tiles and not 256](why-47-tiles-not-256.md).
- [The `tile_map_data` binary format](tile-map-data-format.md) — what a cell
  actually stores, which is a source id, atlas coords and a 16-bit alternative
  field, and no TileData whatsoever.
