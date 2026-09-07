#!/usr/bin/env bash
# Runs every claim in docs/why-tiles-are-not-walkable.md against a real Godot 4
# binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_navigation.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Two claims (N5, N8) assert that the engine ERRORS or refuses a query, and
# those messages land on stderr as part of the evidence, so stderr is kept.
#
# The engine's own exit code is NOT the gate. Godot exits 0 on a GDScript parse
# error: point this at a 4.2 build, where TileMapLayer does not exist, and it
# fails to compile the script, runs not one claim and still exits 0. An earlier
# revision reported that as a pass. So the gate is the summary line — if the
# script did not reach the end and print it, nothing was measured, and that is
# reported as a skip or an error rather than as success.
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

config/name="BlobsmithTileNavigationCheck"
EOF
cp "$HERE/verify_tile_navigation.gd" "$PROJ/verify_tile_navigation.gd"

OUT="$("$GODOT" --headless --path "$PROJ" --script verify_tile_navigation.gd 2>&1)"
echo "$OUT" | grep -E '^(godot |---|PASS |FAIL |NOTE |TILE NAVIGATION)'

SUMMARY="$(printf '%s\n' "$OUT" | grep -c '^TILE NAVIGATION: ')"
if [ "$SUMMARY" -eq 0 ]; then
  if printf '%s\n' "$OUT" | grep -q 'Could not find type "TileMapLayer"'; then
    echo "SKIP: this build has no TileMapLayer — every claim here is about one, so nothing was measured."
    echo "      TileMapLayer arrived in Godot 4.3; 4.2 and earlier cannot run this file."
    exit 0
  fi
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

FAILED="$(printf '%s\n' "$OUT" | sed -n 's/^TILE NAVIGATION: .* passed \/ \([0-9]*\) failed.*/\1/p' | tail -1)"
[ "${FAILED:-1}" -eq 0 ] || exit 1
exit 0
