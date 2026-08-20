#!/usr/bin/env bash
# Runs the 26 collision claims that docs/find_tile_collision_gaps.js implements
# against a real Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_collision.sh /path/to/Godot_v4.7-stable_linux.x86_64
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

config/name="BlobsmithTileCollisionCheck"
EOF
cp "$HERE/verify_tile_collision.gd" "$PROJ/verify_tile_collision.gd"

# Two claims (C2, C7) assert that the engine ERRORS. Those errors land on
# stderr and are part of the evidence, so stderr is kept, not swallowed.
"$GODOT" --headless --path "$PROJ" --script verify_tile_collision.gd 2>&1 \
  | grep -vE '^(Godot Engine v|$)'
exit "${PIPESTATUS[0]}"
