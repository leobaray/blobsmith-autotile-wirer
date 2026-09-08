#!/usr/bin/env bash
# Runs every claim in docs/why-terrain-paints-the-wrong-tile.md against a real
# Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_terrain_choice.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# The tilesets are the ones this repo already ships in examples/starter-pack:
# a corners-and-sides 47-blob set (T4-T8, T17-T21, U6-U9) and a sides-only set
# (T10-T13). They are copied into a throwaway project so nothing here touches
# your own files.
#
# The engine's own exit code is NOT the gate. Godot exits 0 on a GDScript parse
# error: point this at a 4.2 build, where TileMapLayer does not exist, and it
# fails to compile the script, runs not one claim and still exits 0. So the gate
# is the summary line — if the script did not reach the end and print it,
# nothing was measured, and that is reported as a skip or an error, never as a
# pass.
set -uo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PACK="$HERE/../examples/starter-pack"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithTerrainChoiceCheck"
EOF

mkdir -p "$PROJ/tiles"
cp "$PACK/grass_47blob_16px.tres" "$PROJ/tiles/blobsmith_tileset.tres"
cp "$PACK/grass_47blob_16px.png"  "$PROJ/tiles/"
cp "$PACK/grass_16sides_16px.tres" "$PROJ/tiles/sides16.tres"
cp "$PACK/grass_16sides_16px.png"  "$PROJ/tiles/"
cp "$HERE/verify_terrain_choice.gd" "$PROJ/verify_terrain_choice.gd"

# The PNGs have to be imported before the .tres files can resolve them. On a
# cold project a plain run does NOT do it: the ext_resource comes back as
# "No loader found for resource" and T0 fails with a tileset that never loaded.
# --import is the editor's import pass and is what actually writes .godot/imported.
"$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

OUT="$("$GODOT" --headless --path "$PROJ" --script verify_terrain_choice.gd 2>&1)"
echo "$OUT" | grep -E '^(Godot Engine v|---|PASS |FAIL |NOTE |SKIP |TERRAIN CHOICE)'

SUMMARY="$(printf '%s\n' "$OUT" | grep -c '^TERRAIN CHOICE: ')"
if [ "$SUMMARY" -eq 0 ]; then
  if printf '%s\n' "$OUT" | grep -q 'Could not find type "TileMapLayer"'; then
    echo "SKIP: this build has no TileMapLayer — every claim here places tiles in one, so nothing was measured."
    echo "      TileMapLayer arrived in Godot 4.3; 4.2 and earlier cannot run this file."
    exit 0
  fi
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

printf '%s\n' "$OUT" | grep -q '^TERRAIN CHOICE: ALL PASS' || exit 1
exit 0
