#!/usr/bin/env bash
# Runs every claim in docs/why-a-flipped-tile-is-not-a-new-tile.md against a
# real Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_transforms.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Headless is enough here: nothing in this file asks what a pixel looks like.
# The one claim that could have needed a renderer — whether a flipped cell's
# COLLISION is mirrored — is read from the physics server, which the headless
# build runs for real. (Contrast verify_y_sort.sh, which needs xvfb because
# draw order is only observable in pixels.)
#
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
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

config/name="BlobsmithTileTransformCheck"
EOF
cp "$HERE/verify_tile_transforms.gd" "$PROJ/verify_tile_transforms.gd"

"$GODOT" --headless --path "$PROJ" --script verify_tile_transforms.gd 2>&1 \
  | grep -vE '^(Godot Engine v|WARNING: [0-9]+ (RID|ObjectDB)|   at: |$)'
exit "${PIPESTATUS[0]}"
