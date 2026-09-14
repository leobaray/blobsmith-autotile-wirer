# My scene tile is not there (or I cannot find its node) — what the engine does

You made a Scenes Collection source, put a chest scene in it, painted it or
called `set_cell`, and then `get_node("Chest")` is null. Or `get_cell_tile_data`
returns null on that cell. Or you set `hp` on the chest node, and a moment later
the chest is back at full health. Or you `queue_free()` the chest after opening
it and `set_cell` will not bring it back.

A scene tile is not a tile with data. The cell stores three numbers — source id,
atlas coords `(0, 0)`, and the **scene id in the alternative slot** — and the
`TileMapLayer` instances the scene as a child when it next updates. The layer
owns those nodes: it creates them late, names them as it likes, does not save
them, and throws them away and makes new ones whenever it rebuilds. This page
measures each part. Every claim has an id (`S6`, `K1`, …) and is asserted by
[`verify_scene_tiles.gd`](verify_scene_tiles.gd) against a real binary:

```
docs/verify_scene_tiles.sh /path/to/Godot_v4.7-stable_linux.x86_64
```

Measured against **Godot 4.3, 4.4 and 4.7.stable.official.5b4e0cb0f**: 47
checks, 47/47 on each, identical results; one of them (`K1`) is a control that
fails when `LG_SELFTEST=1` flips it, and the runner exits 1. Last run
**2026-09-14**. Needs 4.3 or newer — `TileMapLayer` does not exist in 4.2. Runs
on `--headless`: nodes are not pixels.

---

## The short answer

```gdscript
layer.set_cell(cell, source_id, Vector2i(0, 0), scene_id)  # scene id goes LAST
layer.update_internals()                                   # node exists after this line
var node: Node = null
for child in layer.get_children():
	if layer.local_to_map(child.position) == cell:
		node = child
```

Keep game state (opened, hp) **in your own dictionary keyed by cell**, not on
the node — the layer replaces the node (`L3`, `T1`). To react as nodes appear,
connect `layer.child_entered_tree`; `position` is already set when it fires
(`S9`).

---

## 1. The scene id is the alternative tile, and the first one is 1

| id | measured |
|----|----------|
| I1 | the first `create_scene_tile()` returns **1**, not 0 |
| I2 | the second returns 2 |
| S4 | `get_cell_source_id` is the collection's source id |
| S5 | `get_cell_atlas_coords` is `(0, 0)` |
| S6 | `get_cell_alternative_tile` is the **scene id** |
| S7 | `get_cell_tile_data` on a scene cell is **null** — scene tiles have no `TileData`, so no custom data, collision or navigation on them |

So `set_cell(cell, source_id)` or `set_cell(cell, source_id, Vector2i.ZERO, 0)`
asks for scene id 0, which the collection never handed out.

## 2. Cells that point at no scene are kept, silently

| id | measured |
|----|----------|
| B1 | atlas coords `(1, 0)`, scene id 0 and scene id 99 are all stored in `get_used_cells()` |
| B2 | none of them creates a node |
| B3 | none of them prints an error or a warning (the runner greps the output of that scenario alone) |

If a cell is "used" and nothing shows, print the three getters from section 1.

## 3. The node is created later, not by `set_cell`

| id | measured |
|----|----------|
| S1, S2 | right after `set_cell` the layer has 0 children, internal ones included |
| S3 | the cell is already stored (`get_used_cells() == [cell]`) |
| S8 | `update_internals()` creates the node on that line |
| D1, D2 | without it: 0 children and `_ready` has not run |
| D3, D4 | one `process_frame` later: the node is there and its `_ready` has run |
| E1, E2 | `erase_cell` is late the same way: the node is still a child until the next update |
| O1, O2 | a layer outside the tree creates nothing, even with `update_internals()`, and still nothing right after `add_child` |
| O3 | one frame after entering the tree the node exists |

One frame is not a promise. While writing the script, a layer that was added
to the tree and filled in the same frame had no nodes after one `process_frame`
and had them after two, on all three versions. That is why the short answer uses
`update_internals()` and `child_entered_tree` rather than `await
get_tree().process_frame`.

## 4. Where the node is, and what it is called

| id | measured |
|----|----------|
| P1 | `node.position == map_to_local(cell)` — the cell **centre**, (40, 24) for cell (2, 1) at 16 px |
| P2 | `local_to_map(node.position)` returns the cell: that is how you find a cell's node |
| P4 | isometric 64×32: cell (1, 0) → (96, 16), again `map_to_local` |
| P3 | the node's `owner` is null |
| K1 | the first instance is named after the scene root (`Chest`) |
| N1, N2 | with three chests only the first is `Chest`; the other two get generated `@Node2D@N` names |

`get_node("Chest")` finds one chest out of many, and which one depends on
creation order. Position the scene's content around (0, 0) if the tile should be
centred on the cell.

## 5. The layer replaces your nodes

| id | measured |
|----|----------|
| R1 | `set_cell` with the same values keeps the same instance |
| R2, R3 | `set_cell` with another scene id replaces it (a `Door` comes back) |
| L1 | `enabled = false` frees every scene node |
| L2, L3 | `enabled = true` makes new ones, all with new instance ids — metadata set on the old node is gone |
| T1, T2 | adding a scene tile to the TileSet (`create_scene_tile`) replaces **every** existing node on the layer, count unchanged |
| T3, T4 | `remove_scene_tile` removes that scene's nodes and leaves all its cells in `get_used_cells()` |

Anything you change on the TileSet at runtime rebuilds the layer's scene nodes,
so per-cell state on the node does not survive it.

## 6. Freeing the node yourself

| id | measured |
|----|----------|
| F1, F2 | `queue_free()` on the node removes it, but the cell stays in `get_used_cells()` |
| F3 | `set_cell` with the same values does **not** bring it back (see `R1`: nothing changed, so nothing is rebuilt) |
| F4 | `erase_cell` then `set_cell` does |

To remove an opened chest for good, `erase_cell(cell)` — not `queue_free()`,
which leaves a cell that comes back as a new chest the next time the layer
rebuilds (`L2`).

## 7. The nodes are not saved

| id | measured |
|----|----------|
| W1 | `PackedScene.pack` of the layer's parent stores 0 scene nodes (their owner is null) |
| W2 | the cell itself is saved |
| W3 | the loaded layer creates the node again, one frame later |

Changes made to a scene-tile node in the editor's scene tree, or at runtime, are
not in the saved `.tscn`. Only the cell is.

---

Related: [`set_cell` ran and nothing appeared](why-set-cell-draws-nothing.md)
(atlas tiles), [`get_custom_data` returns null](why-get-custom-data-returns-null.md),
[the tile under the mouse is the wrong one](why-the-tile-under-the-mouse-is-the-wrong-one.md).
