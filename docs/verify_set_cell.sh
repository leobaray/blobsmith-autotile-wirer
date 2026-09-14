#!/usr/bin/env bash
# Runs every claim in docs/why-set-cell-draws-nothing.md against a real Godot 4
# binary. Exits non-zero if any claim fails.
#
#   docs/verify_set_cell.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Like verify_y_sort.sh, this one cannot use --headless: "draws nothing" is read
# back from a rendered SubViewport, and the headless dummy renderer returns no
# image. It asks for a real GL context on a virtual X server.
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
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found: these claims are about what is rendered and" >&2
  echo "cannot be measured on the headless (dummy) renderer." >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithSetCellCheck"
EOF
cp "$HERE/verify_set_cell.gd" "$PROJ/verify_set_cell.gd"

run() {
  xvfb-run -a -s "-screen 0 640x480x24" \
    "$GODOT" --rendering-driver opengl3 --path "$PROJ" --script verify_set_cell.gd 2>&1
}

OUT="$(run)"
echo "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |SET CELL)'

if ! printf '%s\n' "$OUT" | grep -q '^SET CELL: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# E1: set_cell() on a tile that does not exist prints nothing, and neither does
# drawing that cell. K2 is the control: get_cell_tile_data() on the same cell
# does print the error, so the grep below can see one when there is one.
E_FAIL=0
count_errors() {
  local out
  out="$(LG_SERRPROBE="$1" run)"
  printf '%s\n' "$out" | grep -q '^SERRPROBE DONE' || { echo "ERROR: error probe '$1' did not finish" >&2; exit 3; }
  printf '%s\n' "$out" | grep -c '^ERROR: The TileSetAtlasSource atlas has no tile at (1, 0)'
}
SETONLY="$(count_errors setonly)"
DRAW="$(count_errors draw)"
LOOKUP="$(count_errors lookup)"
if [ "$SETONLY" -eq 0 ]; then
  echo "PASS  E1 set_cell() on a missing tile: 0 errors printed"
else
  echo "FAIL  E1 set_cell() on a missing tile: $SETONLY errors printed (want 0)"; E_FAIL=1
fi
if [ "$DRAW" -eq 0 ]; then
  echo "PASS  E1 the same cell drawn for two frames: 0 errors printed"
else
  echo "FAIL  E1 the same cell drawn for two frames: $DRAW errors printed (want 0)"; E_FAIL=1
fi
if [ "$LOOKUP" -ge 1 ]; then
  echo "PASS  K2 control: get_cell_tile_data() on it prints 'atlas has no tile at (1, 0)'"
else
  echo "FAIL  K2 control: get_cell_tile_data() on it printed nothing (want >= 1)"; E_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^SET CELL: ALL PASS' || exit 1
[ "$E_FAIL" -eq 0 ] || exit 1
exit 0
