#!/usr/bin/env bash
# Runs every claim in docs/why-get-custom-data-returns-null.md against a real
# Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_custom_data.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Headless is fine here: nothing on that page is about pixels. The physics
# claims (a CharacterBody2D landing on a tile) run real physics frames.
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

config/name="BlobsmithCustomDataCheck"
EOF
cp "$HERE/verify_tile_custom_data.gd" "$PROJ/verify_tile_custom_data.gd"

run() {
  timeout 120 "$GODOT" --headless --path "$PROJ" --script verify_tile_custom_data.gd 2>&1
}

OUT="$(run)"
echo "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |CUSTOM DATA)'

if ! printf '%s\n' "$OUT" | grep -q '^CUSTOM DATA: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# E1: a misspelled layer name is not silent — get_custom_data() and
# set_custom_data() both print an engine error. K2 is the control: a correct
# name prints nothing, so the grep below is not matching something unrelated.
E_FAIL=0
count_errors() {
  local out
  out="$(LG_CDPROBE="$1" run)"
  printf '%s\n' "$out" | grep -q '^CDPROBE DONE' || { echo "ERROR: error probe '$1' did not finish" >&2; exit 3; }
  printf '%s\n' "$out" | grep -c '^ERROR: TileSet has no layer with name'
}
GET_WRONG="$(count_errors get_wrong)"
SET_WRONG="$(count_errors set_wrong)"
GET_RIGHT="$(count_errors get_right)"
if [ "$GET_WRONG" -ge 1 ]; then
  echo "PASS  E1 get_custom_data(\"HP\") on a layer named \"hp\" prints 'TileSet has no layer with name'"
else
  echo "FAIL  E1 get_custom_data(\"HP\") printed no error (want >= 1)"; E_FAIL=1
fi
if [ "$SET_WRONG" -ge 1 ]; then
  echo "PASS  E1 set_custom_data(\"nope\", 1) prints the same error"
else
  echo "FAIL  E1 set_custom_data(\"nope\", 1) printed no error (want >= 1)"; E_FAIL=1
fi
if [ "$GET_RIGHT" -eq 0 ]; then
  echo "PASS  K2 control: get_custom_data(\"hp\") prints no such error"
else
  echo "FAIL  K2 control: get_custom_data(\"hp\") printed $GET_RIGHT errors (want 0)"; E_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^CUSTOM DATA: ALL PASS' || exit 1
[ "$E_FAIL" -eq 0 ] || exit 1
exit 0
