#!/usr/bin/env bash
# Loads and paints the two-terrain TileSets in this folder in a real Godot 4
# binary. Exits non-zero if any claim in README.md fails.
#
#   examples/transitions/verify_transitions.sh /path/to/Godot_v4.x-stable_linux.x86_64
#
# Terrain matching is data, not pixels, so --headless is enough.
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
set -uo pipefail

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

config/name="BlobsmithTransitionsCheck"
EOF
mkdir "$PROJ/transitions"
cp "$HERE"/*.png "$HERE"/*.tres "$HERE/manifest.json" "$PROJ/transitions/"
cp "$HERE/verify_transitions.gd" "$PROJ/verify_transitions.gd"

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1
OUT="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script verify_transitions.gd 2>&1)"
echo "$OUT" | grep -E '^(Godot |PASS |FAIL |NOTE |TRANSITIONS)'

if ! printf '%s\n' "$OUT" | grep -q '^TRANSITIONS: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi
printf '%s\n' "$OUT" | grep -q '^TRANSITIONS: ALL PASS' || exit 1
exit 0
