#!/usr/bin/env bash
# Runs every claim in examples/variants/README.md against a real Godot 4 binary,
# with the real TileSets, in a throwaway project.
#
#   examples/variants/verify_variants_pack.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/variants/verify_variants_pack.sh /path/to/godot --invert   # must exit 1
#
# The gate is the summary line as well as the exit code: a GDScript parse error
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

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithVariantsPackCheck"
EOF
mkdir "$PROJ/variants"
cp "$HERE"/*.png "$HERE"/*.tres "$HERE/manifest.json" "$PROJ/variants/"
cp "$HERE/verify_variants_pack.gd" "$PROJ/verify_variants_pack.gd"
shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

OUT="$(timeout 300 "$GODOT" --headless --path "$PROJ" --script verify_variants_pack.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |MANIFEST |VARIANTS)'

if ! printf '%s\n' "$OUT" | grep -qE '^VARIANTS'; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

E="$(printf '%s\n' "$OUT" | grep -cE 'ERROR')"
if [ "$E" = "0" ]; then
  echo "PASS P0  the verification run (8 TileSets, load, connect, probability weighting) prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL P0  the verification run printed $E ERROR lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR' | head -5
  exit 1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -qE '^VARIANTS [0-9]+/[0-9]+ PASS' || exit 1
exit 0
