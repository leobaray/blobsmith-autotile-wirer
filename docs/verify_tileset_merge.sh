#!/usr/bin/env bash
# Runs every claim in docs/merging-two-tilesets.md against a real Godot 4
# binary. Exits non-zero if any claim fails.
#
#   docs/verify_tileset_merge.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Headless is enough: every claim here is about what an index MEANS in a given
# TileSet, which is decided before anything is drawn. Nothing on screen would
# add evidence — and that is the point of the doc, since none of these
# failures show up as an error either.
#
# The script builds its TileSets in memory, so it needs no assets and runs in
# a throwaway project. Verified on 4.2, 4.3, 4.4 and 4.7: same results on all
# four, so this is the design, not a regression.
# Expect a wall of `ERROR: Index p_terrain_set = 1 is out of bounds` and
# `Cannot create TileSet atlas source` on stderr while it runs. Those are the
# engine reacting to the broken states the script builds on purpose; the
# verdict is the PASS/FAIL lines and the exit code, not the absence of noise.
set -euo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithTileSetMergeCheck"
EOF
cp "$HERE/verify_tileset_merge.gd" "$PROJ/verify_tileset_merge.gd"

"$GODOT" --headless --path "$PROJ" --script verify_tileset_merge.gd
