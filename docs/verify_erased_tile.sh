#!/usr/bin/env bash
# Runs every claim in docs/why-the-erased-tile-still-collides.md against a real
# Godot 4 binary, in a throwaway project with nothing configured.
#
#   docs/verify_erased_tile.sh /path/to/Godot_v4.7-stable_linux.x86_64
#   docs/verify_erased_tile.sh /path/to/godot --invert   # must exit 1
#
# Headless is fine: nothing on that page is about pixels. The claims run real
# physics frames and real physics queries.
#
# X1-X3 are counted here, not in the script: they are about the engine's error
# lines, which GDScript cannot read.
#
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# Exit: 0 all pass, 1 any FAIL, 2 usage, 3 the script did not finish.
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
set -uo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary [--invert]" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOT'
config_version=5

[application]

config/name="BlobsmithErasedTileCheck"
EOT
cp "$HERE/verify_erased_tile.gd" "$PROJ/verify_erased_tile.gd"
shift   # everything after the binary is passed through to the script

run() {
  timeout 180 "$GODOT" --headless --path "$PROJ" --script verify_erased_tile.gd -- "$@" 2>&1
}

OUT="$(run "$@")"
printf '%s\n' "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |NOTE |ERASED TILE)'

if ! printf '%s\n' "$OUT" | grep -q '^ERASED TILE: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

MINOR="$(printf '%s\n' "$OUT" | grep -oE '^Godot Engine v4\.[0-9]+' | head -1 | sed 's/.*v4\.//')"
X_FAIL=0
xcheck() {  # id got want why
  if [ "$2" = "$3" ]; then
    echo "PASS $1  $4"
  else
    echo "FAIL $1  $4  (got $2, want $3)"; X_FAIL=1
  fi
}

# X1: C1 (erase_cell + update_internals inside body_shape_entered) is the only
# place the main run touches the layer while queries are flushed.
FLUSH="$(printf '%s\n' "$OUT" | grep -c "Can't change this state while flushing queries")"
if [ "${MINOR:-0}" -ge 7 ]; then
  xcheck X1 "$FLUSH" 2 "4.$MINOR: C1 prints \"Can't change this state while flushing queries\" twice, and still works"
else
  xcheck X1 "$FLUSH" 0 "4.$MINOR: C1 prints no \"flushing queries\" error"
fi

# X2: R3 asks get_coords_for_body_rid() about a dead RID exactly once.
FOUND="$(printf '%s\n' "$OUT" | grep -c 'Parameter "found" is null')"
xcheck X2 "$FOUND" 1 "R3's dead RID prints one 'Parameter \"found\" is null' error"

# X3: erase_cell alone inside body_shape_entered, and erase_cell + update_internals
# inside a physics_frame handler, print no error on any version.
P_ERR=0
for p in area physframe_upd; do
  P="$(run "--probe=$p")"
  if ! printf '%s\n' "$P" | grep -q '^ERASEPROBE DONE fired=1 sweep_C=false sweep_N2=true row_right=true'; then
    echo "ERROR: probe '$p' did not finish as expected:" >&2
    printf '%s\n' "$P" >&2
    exit 3
  fi
  P_ERR=$(( P_ERR + $(printf '%s\n' "$P" | grep -cE '^(ERROR|WARNING|SCRIPT ERROR)') ))
done
xcheck X3 "$P_ERR" 0 "erase_cell alone in body_shape_entered, and erase_cell + update_internals in a physics_frame handler: 0 error lines"

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
[ "$X_FAIL" -eq 0 ] || exit 1
printf '%s\n' "$OUT" | grep -q '^ERASED TILE: ALL PASS' || exit 1
exit 0
