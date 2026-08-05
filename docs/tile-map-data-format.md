# The `tile_map_data` binary format (Godot 4)

`TileMapLayer` does not store its cells as readable text. Everything you painted
lives in one property, `tile_map_data`, a `PackedByteArray` that lands in the
`.tscn` as a wall of integers:

```
[node name="Ground" type="TileMapLayer"]
tile_map_data = PackedByteArray(0, 0, 1, 0, 2, 0, 7, 0, 1, 0, 1, 0, 0, 0)
tile_set = ExtResource("1_abcde")
```

That is a fully painted layer with one tile in it. This page documents the
layout so you can read or write those bytes from outside the engine — a map
generator, a migration script, a diff tool, a linter in CI.

Everything below was measured against **Godot 4.7 stable** with
[`verify_tile_map_data.gd`](verify_tile_map_data.gd), which sits next to this
file and re-checks all 46 claims on demand:

```bash
godot --headless --script verify_tile_map_data.gd
# ... PASS per check, then "TILE_MAP_DATA VERIFY: ALL PASS"; exit 0
```

If a future Godot version changes something here, that script tells you which
line — it fails loudly rather than drifting quietly out of date.

## The layout

A buffer is a **2-byte header** followed by a flat run of **12-byte cell
records**. Nothing else: no cell count, no bounding box, no index, no
compression, no padding.

```
 0        2                14                26
 ┌────────┬────────────────┬────────────────┬─────  ···
 │ format │  cell record   │  cell record   │
 │ uint16 │    12 bytes    │    12 bytes    │
 └────────┴────────────────┴────────────────┴─────  ···
```

So a valid buffer always satisfies:

```
(data.size() - 2) % 12 == 0
cell_count = (data.size() - 2) / 12
```

**Every value is little-endian.**

### The header

| Offset | Size | Type | Meaning |
|--------|------|------|---------|
| `+0` | 2 | `uint16` | format version |

The only version that exists is **0**. In the engine it is the enum
`TileMapLayerDataFormat { TILE_MAP_LAYER_DATA_FORMAT_0 = 0, TILE_MAP_LAYER_DATA_FORMAT_MAX }`
in `scene/2d/tile_map_layer.h`. A higher value is rejected outright — see
[Malformed buffers](#malformed-buffers).

An empty layer is an **empty** `PackedByteArray`, not a lone 2-byte header.

### The cell record

| Offset | Size | Type | Field | Notes |
|--------|------|------|-------|-------|
| `+0` | 2 | **`int16`** | `coords.x` | map coordinate, **signed** |
| `+2` | 2 | **`int16`** | `coords.y` | map coordinate, **signed** |
| `+4` | 2 | `uint16` | `source_id` | `TileSet` source id; `0xFFFF` = erased |
| `+6` | 2 | `uint16` | `atlas_coords.x` | column in the atlas source |
| `+8` | 2 | `uint16` | `atlas_coords.y` | row in the atlas source |
| `+10` | 2 | `uint16` | `alternative_tile` | alternative id **plus transform flags** |

The two coordinate fields are the only signed ones. Negative coordinates are
plain two's complement, so `x = -1` is `ff ff` and `x = -2` is `fe ff` — a cell
at `(-1, -1)` starts with four `ff` bytes.

### Transform flags in `alternative_tile`

The last field is not just the alternative-tile id. The three cell transforms
are packed into its high bits:

| Bit | Constant | GDScript |
|-----|----------|----------|
| `0x1000` | `TRANSFORM_FLIP_H` | `TileSetAtlasSource.TRANSFORM_FLIP_H` |
| `0x2000` | `TRANSFORM_FLIP_V` | `TileSetAtlasSource.TRANSFORM_FLIP_V` |
| `0x4000` | `TRANSFORM_TRANSPOSE` | `TileSetAtlasSource.TRANSFORM_TRANSPOSE` |

which leaves the low 12 bits for the id itself:

```
 15   14   13   12   11 ─────────────────── 0
┌────┬────┬────┬────┬──────────────────────┐
│ ?  │ T  │ V  │ H  │  alternative id      │
└────┴────┴────┴────┴──────────────────────┘
```

So `alternative_id = field & 0x0FFF`, and each flag is a plain bit test. An id
and all three flags coexist in the one field: `5 | 0x1000 | 0x2000 | 0x4000`
reads back as alternative 5, flipped both ways, transposed.

Two consequences worth knowing:

- **Practical alternative ids stop at 4095.** Anything larger collides with the
  flag bits.
- **Read the field as unsigned.** Godot's own
  `get_cell_alternative_tile()` returns it sign-extended, so a value with bit 15
  set comes back as a large negative number rather than the id you wrote.

## A worked example, byte by byte

Three cells: a plain tile, a horizontally flipped one, and one at negative
coordinates. All three use source id `7`.

| Cell | `coords` | `source_id` | `atlas_coords` | `alternative` |
|------|----------|-------------|----------------|---------------|
| 0 | `(1, 2)` | 7 | `(1, 1)` | 0 |
| 1 | `(2, 2)` | 7 | `(0, 0)` | `0x1000` (flip H) |
| 2 | `(-1, -1)` | 7 | `(0, 0)` | 0 |

The buffer is `2 + 3 * 12 = 38` bytes:

```
0000 010002000700010001000000 020002000700000000000010 ffffffff0700000000000000
^^^^ ^-- cell 0 ------------- ^-- cell 1 ------------- ^-- cell 2 -------------
head
```

Split into fields:

```
       coords.x  coords.y  source_id  atlas.x  atlas.y  alternative
head   -- -- 00 00
cell 0    01 00     02 00      07 00    01 00    01 00        00 00   → (1,2)   src 7 atlas (1,1)
cell 1    02 00     02 00      07 00    00 00    00 00        00 10   → (2,2)   src 7 atlas (0,0) flip H
cell 2    ff ff     ff ff      07 00    00 00    00 00        00 00   → (-1,-1) src 7 atlas (0,0)
```

Note cell 1's `00 10`: little-endian `0x1000`, the flip-H bit — the byte order
is the thing people misread here.

As it appears in a `.tscn`:

```
tile_map_data = PackedByteArray(0, 0, 1, 0, 2, 0, 7, 0, 1, 0, 1, 0, 0, 0, 2, 0, 2, 0, 7, 0, 0, 0, 0, 0, 0, 16, 255, 255, 255, 255, 7, 0, 0, 0, 0, 0, 0, 0)
```

`verify_tile_map_data.gd` builds exactly this buffer from the spec above,
asserts the bytes match, hands it to a real `TileMapLayer`, and checks the
engine reads back the table — then saves the scene, reloads it, and checks the
bytes survive unchanged.

### Writing one

```gdscript
const HEADER_SIZE := 2
const RECORD_SIZE := 12

func encode(cells: Array) -> PackedByteArray:
    var buf := PackedByteArray()
    buf.resize(HEADER_SIZE + cells.size() * RECORD_SIZE)
    buf.encode_u16(0, 0)  # format 0
    for i in cells.size():
        var c: Dictionary = cells[i]
        var o := HEADER_SIZE + i * RECORD_SIZE
        buf.encode_s16(o + 0, c.coords.x)
        buf.encode_s16(o + 2, c.coords.y)
        buf.encode_u16(o + 4, c.source_id)
        buf.encode_u16(o + 6, c.atlas.x)
        buf.encode_u16(o + 8, c.atlas.y)
        buf.encode_u16(o + 10, c.get("alternative", 0))
    return buf
```

### Reading one

```gdscript
func decode(buf: PackedByteArray) -> Array:
    assert(buf.size() >= HEADER_SIZE and (buf.size() - HEADER_SIZE) % RECORD_SIZE == 0)
    assert(buf.decode_u16(0) == 0)
    var out := []
    for o in range(HEADER_SIZE, buf.size(), RECORD_SIZE):
        var source_id := buf.decode_u16(o + 4)
        if source_id == 0xFFFF:
            continue  # erased cell — see below
        var alt := buf.decode_u16(o + 10)
        out.append({
            "coords": Vector2i(buf.decode_s16(o + 0), buf.decode_s16(o + 2)),
            "source_id": source_id,
            "atlas": Vector2i(buf.decode_u16(o + 6), buf.decode_u16(o + 8)),
            "alternative": alt & 0x0FFF,
            "flip_h": bool(alt & 0x1000),
            "flip_v": bool(alt & 0x2000),
            "transpose": bool(alt & 0x4000),
        })
    return out
```

That `continue` is not optional. Here is why.

## Gotchas

### Erased cells leave a record behind

`erase_cell()` does **not** remove the 12 bytes. It overwrites the record's
`source_id`, `atlas_coords` and `alternative` with `0xFFFF` and leaves the
coordinates where they were:

```
before erase_cell((1,1)):  0000 010001000700000000000000 020002000700010000000000
after  erase_cell((1,1)):  0000 01000100ffffffffffffffff 020002000700010000000000
                                         ^^^^ ^^^^^^^^^^^^^^^ tombstone
```

The buffer does not shrink, the tombstone **is written to the `.tscn`**, and it
is still there after a reload. So:

- **Cell count ≠ `(len - 2) / 12`.** That is the record count. Painted cells are
  the records whose `source_id` is not `0xFFFF`.
- A parser that trusts every record reports phantom tiles at coordinates the
  user erased — with a nonsense source id of 65535 and atlas coords `(65535,
  65535)`.
- A layer that was painted and cleared serializes as a buffer full of
  tombstones, not as an empty one.

### Coordinates outside int16 are silently truncated

The map coordinate is 16 bits, but `set_cell()` accepts a full `Vector2i`. In
memory the cell keeps the coordinate you gave it and `get_used_cells()` reports
it faithfully. The moment it is serialized, it wraps:

```gdscript
layer.set_cell(Vector2i(40000, -40000), 7, Vector2i(0, 0), 0)
layer.get_cell_source_id(Vector2i(40000, -40000))  # 7 — fine, in memory

# ... save, reload ...
reloaded.get_used_cells()                          # [(-25536, 25536)] — moved
reloaded.get_cell_source_id(Vector2i(40000, -40000))  # -1 — gone
```

No warning, no error. **The usable coordinate range is −32768 … 32767 per
axis**, and both extremes round-trip exactly. If you generate maps
programmatically from world coordinates, clamp or chunk before you write, or
tiles teleport across the map on the next load.

### Record order is insertion order, and duplicates are legal

Records come out in the order cells were set — not sorted by coordinate, not
row-major. Do not rely on it for diffing; sort by coordinate yourself.

A buffer may also contain two records for the same coordinate. The engine
applies them in order, so **the last record wins**, and re-serializing collapses
them to one. Handy for appending, but it means the record count of a
hand-written buffer can legitimately exceed the number of cells that end up on
the map.

### Malformed buffers

The engine's parser is in `set_tile_map_data_from_array` (`scene/2d/tile_map_layer.cpp`).
Two distinct failures:

| Problem | Engine says | Result |
|---------|-------------|--------|
| Header > 0 | `Unsupported tile map data format: N. Expected format ID lower or equal to: 0` | Whole assignment refused. The layer keeps its **previous** contents — this is a no-op, not a clear. |
| `(len - 2) % 12 != 0` | `Corrupted tile map data: tiles might be missing.` | Complete records load; the trailing partial record is dropped. |

The second is a partial success that prints an error and carries on, which is
easy to miss in a noisy log. If you generate buffers, assert the length rule on
your side before assigning.

## Related gotchas from building this addon

Not format details, but the things that actually cost us time while producing
`TileSet` resources that the above then paints:

- **Add the source to the `TileSet` before touching `TileData`.** Terrain and
  physics layers only propagate to tiles once the source belongs to a `TileSet`.
  Call `ts.add_source(src, id)` first; configure tiles after. Do it the other
  way round and `set_terrain_peering_bit()` writes into a tile that has no
  terrain layer to write to. See `addons/blobsmith_wirer/wirer_core.gd`.
- **`.tres` is a quoted-string format — escape what you put in it.** A terrain
  name containing a `"` or a `\` produced a file Godot refused to load with
  `Parse Error: Unterminated string`. Anything user-supplied that reaches a
  resource file needs escaping.
- **A corner peering bit only counts when both adjacent side bits are set.** A
  lone diagonal neighbour does not make a distinct tile. That rule is exactly
  why a blob autotile has 47 tiles and not 256 — see
  [Neighbor bit layout](../README.md#neighbor-bit-layout).

## Further reading

- [`TileMapLayer` class reference](https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html) — the public API this format backs.
- [`TileSetAtlasSource` transform constants](https://docs.godotengine.org/en/stable/classes/class_tilesetatlassource.html) — the `0x1000` / `0x2000` / `0x4000` flags.
- [itch.io forum thread on `tile_map_data`](https://itch.io/t/6706489/godot-4s-tile-map-data-byte-layout-decoded-for-anyone-generating-tscn-files-outside-the-editor) — community discussion of the same property.

---

Part of [Blobsmith Autotile Wirer](../README.md). Corrections welcome — open an
issue with a failing case and the buffer that produced it.
