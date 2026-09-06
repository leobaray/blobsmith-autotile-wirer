# Merging two TileSets in Godot 4 — what actually has to be remapped

You have two `TileSet` resources and you want one. Maybe a tool generated an
autotile set and you want it inside your hand-made one; maybe each of your
`TileMapLayer`s grew its own tileset and you now want a single one. The engine
has no merge: the editor can add a source to the TileSet you are editing, but
it cannot take two TileSet *resources* and produce a third.

The advice you will find is a one-liner:

```gdscript
tileset_b.add_source(tileset_a.get_source(0))
```

**That is a move, not a copy.** After it runs, `tileset_a` has zero sources. It
is documented — *"TileSetSource can only be added to one TileSet at the same
time"* — and it is easy to miss, because if something saves `tileset_a` while
it is in that state, the tiles are gone from the file as well.

The obvious repair is `duplicate(true)`:

```gdscript
tileset_b.add_source(tileset_a.get_source(0).duplicate(true))
```

That one keeps both TileSets. It is also where the real problem starts, and the
reason this document exists.

## Every index in a TileData means something only inside its own TileSet

A `TileData` does not store "grass". It stores `terrain_set = 0, terrain = 0`.
It does not store "this tile is a ladder"; it stores a value at custom data
layer index 2. Terrain sets, terrains, custom data layers, physics layers,
navigation layers and occlusion layers are all **positional** — the meaning
lives in the TileSet, the number lives in the tile.

Copy the source into another TileSet and the numbers come along unchanged.
Nothing translates them. So:

- If both TileSets have a terrain set 0, the copied tile now paints the
  receiver's terrain set 0 — a different terrain, with a different name.
  No error, no warning. You find out when you paint.
- If the donor's tile sat on terrain set 1 and the receiver has only one
  terrain set, the tile keeps the number 1 and it now points at nothing. The
  peering bits read back as `-1`: the terrain wiring is gone.
- A custom data value written under the donor's layer 0 comes back under the
  receiver's layer 0, whatever that layer happens to be called, and whatever
  type it happens to be.

Physics layers behave identically, and it is the same shape of failure: a
collision polygon authored on the donor's physics layer 1 arrives in a receiver
that has only layer 0 still attached to index 1, which means the tile has no
collision there at all. Navigation and occlusion layers are referenced the same
positional way.

## Source ids do not survive either

`add_source(source, id)` with an id the receiver already uses **returns `-1`
and adds nothing at all**. A loop that copies sources under their original ids
silently drops every one that collides. Let the engine pick instead and the
sources get renumbered — which matters, because every cell of every
`TileMapLayer` you have already painted stores the **old** source id. Renumber
the sources without rewriting the maps and the maps point at the wrong atlas,
or at no atlas.

## Merging the `.tres` files as text has the same trap, plus one of its own

A `.tres` is a text file, so hand-merging looks tempting. Two files written by
the same generator usually carry the **same `sub_resource` id** — every file in
our starter pack calls its atlas `TileSetAtlasSource_bsmith`. Concatenate them
and you get a file that loads with no error and no warning, in which
`sources/0` and `sources/1` are the same atlas: one terrain painted twice, the
other simply gone. Everything in the section above still applies on top of
that, now as `terrain_set` and `custom_data_N` keys you have to renumber by
hand.

## The checklist

When you merge, for every tile you bring over:

1. **Source ids** — assign fresh ones, and rewrite the source id stored in
   every already-painted map that used the old one.
2. **`sub_resource` ids** (text merge only) — renumber; identical ids across
   two files collapse into one resource silently.
3. **Terrain sets and terrains** — match by *name*, create the missing ones in
   the receiver, then rewrite `terrain_set` / `terrain` and every peering bit
   on the tile to the receiver's indices.
4. **Custom data layers** — match by name *and* type, then move each value
   from the donor's layer index to the receiver's.
5. **Physics / navigation / occlusion layers** — same: match by the layer's
   properties, then rewrite the per-tile indices.
6. **Grid settings** — `tile_shape`, `tile_layout`, `tile_offset_axis`,
   `tile_size`, `uv_clipping`. These are the one group that is not per-tile:
   they belong to the TileSet, so a merge cannot carry both. Two TileSets that
   disagree on any of them describe grids that cannot share one resource — the
   right move is to refuse the merge rather than pick a winner silently.

Every failure in this list is silent. That is the whole difficulty: a merge
that skips a step produces a file that loads cleanly and is wrong, so reading
the bytes back cannot tell you it worked.

## Proving it on your own engine

`docs/verify_tileset_merge.gd` asserts all of the above against a real binary.
It builds its TileSets in memory, so it needs no assets:

```
docs/verify_tileset_merge.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

22 checks. They pass identically on **4.2, 4.3, 4.4 and 4.7** — this is the
design, not a regression. `G1` and `G2` are the control: they
remap the indices by name and show the tile then painting the terrain it was
drawn for. Without them the script would only prove that something is broken,
not that anything fixes it.

Related, in this repo: [`tile-map-data-format.md`](tile-map-data-format.md) —
the binary layout of `tile_map_data`, which is where those source ids live in
an already-painted map.
