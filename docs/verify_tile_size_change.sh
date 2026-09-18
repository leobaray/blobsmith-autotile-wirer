#!/usr/bin/env bash
# Runs every claim in docs/why-changing-the-tile-size-emptied-my-tilemap.md
# against a real Godot 4 binary, in a throwaway project with nothing configured.
#
#   docs/verify_tile_size_change.sh /path/to/Godot_v4.7-stable_linux.x86_64
#   docs/verify_tile_size_change.sh /path/to/godot --selftest   # must exit 1
#
# Cannot use --headless: half of these claims are about what a cell draws after
# the atlas changes, read back from a rendered SubViewport, and the headless
# dummy renderer returns no image. It asks for a real GL context on a virtual
# X server.
#
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# Exit: 0 all pass, 1 any FAIL, 2 usage, 3 the script did not finish.
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
set -uo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary [--selftest]" >&2
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

config/name="BlobsmithTileSizeChangeCheck"
EOF
cp "$HERE/verify_tile_size_change.gd" "$PROJ/verify_tile_size_change.gd"

SELFTEST=0
[ "${2:-}" = "--selftest" ] && SELFTEST=1

OUT="$(LG_SELFTEST="$SELFTEST" timeout 300 xvfb-run -a -s "-screen 0 640x480x24" \
  "$GODOT" --rendering-driver opengl3 --path "$PROJ" \
  --script verify_tile_size_change.gd 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |NOTE |TILE SIZE CHANGE)'

if ! printf '%s\n' "$OUT" | grep -q '^TILE SIZE CHANGE: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -q '^TILE SIZE CHANGE: ALL PASS' || exit 1
exit 0
