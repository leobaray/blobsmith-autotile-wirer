#!/usr/bin/env bash
# Runs every claim in docs/why-one-cell-changed-every-cell.md against a real
# Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_data_sharing.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Optionally add your own TileSet, copied into the throwaway project, to see
# the same sharing on your tiles:
#
#   docs/verify_tile_data_sharing.sh /path/to/godot /path/to/your_tileset.tres
#
# Headless is enough: every claim here is about object identity and what
# ResourceSaver writes, neither of which needs a pixel. The one thing a
# renderer WOULD be needed for — TileMapLayer._tile_data_runtime_update() —
# is deliberately not claimed by this script; it never fired in our headless
# runs, so the doc describes it rather than asserting about it.
#
# The doc's "no private copy" claim (S20-S22) is asserted here too: TileData
# extends Object, not Resource, and has no duplicate(). What looks like a hang
# when you call one is the SceneTree script dying before quit() -- a
# nonexistent call on a plain Node does exactly the same.
# On Godot 4.2 the script prints a SKIP and exits 0: TileMapLayer landed in
# 4.3, and a missing class is not a failed claim.
set -euo pipefail

GODOT="${1:-}"
USER_TS="${2:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary [/path/to/your_tileset.tres]" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithTileDataSharingCheck"
EOF
cp "$HERE/verify_tile_data_sharing.gd" "$PROJ/verify_tile_data_sharing.gd"

ARGS=()
if [ -n "$USER_TS" ]; then
  if [ ! -f "$USER_TS" ]; then
    echo "no such TileSet: $USER_TS" >&2
    exit 2
  fi
  # A .tres names its texture with a res:// path, which only resolves inside
  # the project that owns it. So when you pass one we run in YOUR project,
  # not in the throwaway one -- copying the script in and taking it out after.
  TSDIR="$(cd "$(dirname "$USER_TS")" && pwd)"
  USER_PROJ="$TSDIR"
  while [ ! -f "$USER_PROJ/project.godot" ] && [ "$USER_PROJ" != "/" ]; do
    USER_PROJ="$(dirname "$USER_PROJ")"
  done
  if [ ! -f "$USER_PROJ/project.godot" ]; then
    echo "no project.godot above $USER_TS -- a TileSet can only be loaded" >&2
    echo "from inside its own Godot project." >&2
    exit 2
  fi
  REL="${USER_TS#"$USER_PROJ"/}"
  cp "$HERE/verify_tile_data_sharing.gd" "$USER_PROJ/.verify_tile_data_sharing.gd"
  trap 'rm -rf "$PROJ"; rm -f "$USER_PROJ/.verify_tile_data_sharing.gd"' EXIT
  "$GODOT" --headless --path "$USER_PROJ" --script .verify_tile_data_sharing.gd \
    -- "res://$REL" 2>&1 \
    | grep -vE '^(Godot Engine v|WARNING: [0-9]+ (RID|ObjectDB)|   at: |$)'
  exit "${PIPESTATUS[0]}"
fi

"$GODOT" --headless --path "$PROJ" --script verify_tile_data_sharing.gd "${ARGS[@]}" 2>&1 \
  | grep -vE '^(Godot Engine v|WARNING: [0-9]+ (RID|ObjectDB)|   at: |$)'
exit "${PIPESTATUS[0]}"
