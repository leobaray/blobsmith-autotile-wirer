#!/usr/bin/env bash
# Runs docs/convert_tilemap_to_tilemaplayer.js against real Godot binaries and
# makes the ENGINE compare the before and the after, cell by cell.
#
#   docs/verify_tilemap_convert.sh /path/to/Godot_v4.3-stable_linux.x86_64
#   docs/verify_tilemap_convert.sh godot-4.2 godot-4.3 godot-4.4 godot-4.7
#
# Each binary that has `TileMapLayer` (4.3+) gets a same-version pass: it writes
# the legacy scene, the converter rewrites a copy of it, and the same engine reads
# both back.
#
# Then, if more than one binary was given, one CROSS-VERSION pass: the FIRST
# binary writes the scene and the LAST one reads the conversion. That is the run
# that matters, and the only one that can use 4.2 — the last Godot before
# TileMapLayer existed. A project that never saw 4.3 is exactly the project this
# script is for, and a fixture written by the new engine would quietly assume the
# file on disk already looks modern.
#
# Exits non-zero if any check fails in any pass.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 /path/to/godot-binary [more binaries, oldest first...]" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
for GODOT in "$@"; do
  [ -x "$GODOT" ] || { echo "not an executable: $GODOT" >&2; exit 2; }
done

# The per-layer key table the converter actually uses, read out of the converter
# instead of re-typed here — the GDScript checks it against the engine's own
# property list, so the two can never drift apart quietly.
KEYS=$(node -e '
  const C = require(process.argv[1]);
  console.log(Object.keys(C.LAYER_KEY_MAP).join(","));
' "$HERE/tilemap-convert-core.js")

QUIET='^(Godot Engine v|WARNING:|ERROR:| *at: |$)'
status=0

new_project() {
  local proj="$1"
  cat > "$proj/project.godot" <<'EOF'
config_version=5

[application]
config/name="BlobsmithTileMapConvertCheck"
EOF
  cp "$HERE/make_tilemap_fixture.gd" "$HERE/verify_tilemap_convert.gd" "$proj/"
}

# A pass is green only if the engine PRINTED the line that says so. Exit codes are
# not enough and this is not theoretical: Godot 4.2 exits 0 after a GDScript parse
# error, so the first version of this runner reported a clean green for a pass in
# which not one check had run.
run_pass() {  # $1 = engine that writes the scene, $2 = engine that reads it back
  local maker="$1" reader="$2"
  local proj out
  proj="$(mktemp -d)"
  new_project "$proj"

  out="$proj/make.log"
  "$maker" --headless --path "$proj" --script make_tilemap_fixture.gd > "$out" 2>&1 || true
  grep -vE "$QUIET" "$out" || true
  if ! grep -q "^FIXTURE .*saved=true .*format2=true .*tile_data=true" "$out"; then
    echo "FAIL  the 'before' scene was not written by $maker"
    status=1; rm -rf "$proj"; return
  fi

  cp "$proj/legacy.tscn" "$proj/converted.tscn"
  node "$HERE/convert_tilemap_to_tilemaplayer.js" "$proj/converted.tscn" --write | sed 's/^/    /'

  out="$proj/verify.log"
  "$reader" --headless --path "$proj" --script verify_tilemap_convert.gd -- "--keys=$KEYS" \
    > "$out" 2>&1 || true
  grep -vE "$QUIET" "$out" || true
  if ! grep -q "^TILEMAP CONVERT VERIFY: ALL PASS" "$out"; then
    echo "FAIL  $reader did not print ALL PASS for this pass"
    status=1
  fi
  rm -rf "$proj"
}

# Also printed rather than returned, for the same reason.
has_tilemaplayer() {
  local proj answer
  proj="$(mktemp -d)"
  printf 'config_version=5\n\n[application]\nconfig/name="probe"\n' > "$proj/project.godot"
  printf 'extends SceneTree\nfunc _init():\n\tprint("HAS_TML=", ClassDB.class_exists("TileMapLayer"))\n\tquit()\n' \
    > "$proj/probe.gd"
  answer="$("$1" --headless --path "$proj" --script probe.gd 2>&1 | grep -c '^HAS_TML=true' || true)"
  rm -rf "$proj"
  [ "$answer" = "1" ]
}

for GODOT in "$@"; do
  ver="$("$GODOT" --version 2>/dev/null | head -1)"
  if has_tilemaplayer "$GODOT"; then
    echo "### same-version pass — $ver"
    run_pass "$GODOT" "$GODOT"
  else
    echo "### $ver has no TileMapLayer — it can only write the 'before' scene, so it is"
    echo "###   used in the cross-version pass below instead of on its own"
  fi
  echo
done

if [ "$#" -gt 1 ]; then
  first="$1"
  for last in "$@"; do :; done
  echo "### cross-version pass — scene written by $("$first" --version 2>/dev/null | head -1)," \
       "converted on the command line, read back by $("$last" --version 2>/dev/null | head -1)"
  run_pass "$first" "$last"
  echo
fi

if [ "$status" -eq 0 ]; then
  echo "TILEMAP CONVERT: every pass green"
else
  echo "TILEMAP CONVERT: at least one pass failed"
fi
exit "$status"
