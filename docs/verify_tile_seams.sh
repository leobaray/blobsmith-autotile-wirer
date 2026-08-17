#!/usr/bin/env bash
# Runs every claim in docs/why-tiles-have-seams.md against a real Godot 4 binary,
# twice: once in a stock project and once in a project that already carries the
# pixel-art settings.
#
#   docs/verify_tile_seams.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# The second pass is not decoration. The whole argument of the doc is that the
# atlas gutter is a TileSet property and the blur is a renderer setting, and that
# people conflate them; the tuned pass shows the atlas numbers not moving while
# the renderer settings do. Exits non-zero if any claim fails in either pass.
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
config/name="BlobsmithTileSeamCheck"
EOF
cp "$HERE/verify_tile_seams.gd" "$PROJ/verify_tile_seams.gd"

run_probe() {
  "$GODOT" --headless --path "$PROJ" --script verify_tile_seams.gd -- "$@" 2>&1 \
    | grep -vE '^(Godot Engine v|$)'
  return "${PIPESTATUS[0]}"
}

status=0
echo "### pass 1 — stock project, nothing configured"
run_probe || status=1

# The three settings a pixel-art project is told to set. Written to disk rather
# than assigned at runtime because default_texture_filter is read when the
# canvas texture is created, not when the setting is queried.
cat >> "$PROJ/project.godot" <<'EOF'

[rendering]

textures/canvas_textures/default_texture_filter=0
2d/snap/snap_2d_transforms_to_pixel=true
2d/snap/snap_2d_vertices_to_pixel=true

[display]

window/stretch/mode="canvas_items"
window/stretch/scale_mode="integer"
EOF

echo
echo "### pass 2 — the same project with the pixel-art settings written in"
run_probe --tuned || status=1
exit "$status"
