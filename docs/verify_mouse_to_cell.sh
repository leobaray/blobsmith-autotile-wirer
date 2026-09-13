#!/usr/bin/env bash
# Runs every claim in docs/why-the-tile-under-the-mouse-is-the-wrong-one.md
# against a real Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_mouse_to_cell.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Headless is enough: every claim is arithmetic the engine does on a transform,
# and a headless build still runs Camera2D and the canvas transform for real.
#
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

config/name="BlobsmithMouseToCellCheck"
EOF
cp "$HERE/verify_mouse_to_cell.gd" "$PROJ/verify_mouse_to_cell.gd"

OUT="$("$GODOT" --headless --path "$PROJ" --script verify_mouse_to_cell.gd 2>&1)"
echo "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |MOUSE TO CELL)'

if ! printf '%s\n' "$OUT" | grep -q '^MOUSE TO CELL: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

printf '%s\n' "$OUT" | grep -q '^MOUSE TO CELL: ALL PASS' || exit 1
exit 0
