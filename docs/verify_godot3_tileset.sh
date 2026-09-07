#!/usr/bin/env bash
# Runs every claim in docs/why-a-godot-3-tileset-does-not-open-empty.md against
# a real Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_godot3_tileset.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Three headless runs in a throwaway project: one writes the atlas and the two
# Godot 3 fixtures, one imports the atlas (a project never opened has no import
# cache, and an unimported texture makes the .tres fail to load for a reason
# that has nothing to do with the conversion), one reads the fixtures back.
#
# Expect `WARNING: Could not convert 3.x autotiles to 4.x` on stderr while it
# runs. That warning is one of the things being measured, not noise — the
# verdict is the PASS/FAIL lines and the exit code.
#
# Verified on 4.3, 4.4 and 4.7 stable: same numbers on all three.
set -euo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

mkdir -p "$PROJ/tiles"
cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithGodot3TileSetCheck"
EOF
cp "$HERE/verify_godot3_tileset.gd" "$PROJ/verify_godot3_tileset.gd"

"$GODOT" --headless --path "$PROJ" --script verify_godot3_tileset.gd -- --prepare >/dev/null
"$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$PROJ" --script verify_godot3_tileset.gd
