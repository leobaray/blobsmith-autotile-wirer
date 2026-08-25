#!/usr/bin/env bash
# Proves docs/tilemap-script-scan-core.js against real Godot binaries, three ways.
#
#   docs/verify_tilemap_script_api.sh godot-4.2 godot-4.3 godot-4.4 godot-4.7
#
#   1. DRIFT     — every engine dumps its own ClassDB (docs/dump_tilemap_api.gd),
#                  the table is rebuilt from those dumps, and it has to come out
#                  byte for byte like the API_TABLE the core carries. The core has
#                  to embed the table because it runs in a browser; this is what
#                  keeps the embedded copy honest.
#   2. ADVICE    — every replacement the core names has to exist on TileMapLayer
#                  in each engine that has one (docs/check_tilemap_replacements.gd).
#                  The engine cannot say the advice is RIGHT; it can say it is not
#                  pointing at something imaginary.
#   3. ROUND TRIP — the oldest engine writes a scene with a scripted TileMap and
#                  prints what the script reads out of it. Then the converter and
#                  the scanner port BOTH, with no hand edits, and the newest engine
#                  runs the result and prints the same thing. Different digest,
#                  failed port.
#
# Exits non-zero if any of the three fails. Zero dependencies beyond node + the
# binaries you name.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 /path/to/godot-binary [more binaries, oldest first...]" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
for GODOT in "$@"; do
  [ -x "$GODOT" ] || { echo "not an executable: $GODOT" >&2; exit 2; }
done

QUIET='^(Godot Engine v|WARNING:|ERROR:| *at: |$)'
status=0
DUMPS=()
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bare_project() {  # $1 = dir
  printf 'config_version=5\n\n[application]\nconfig/name="BlobsmithScriptApiCheck"\n' > "$1/project.godot"
}

echo "### 1. DRIFT — the table in the core vs what the engines say"
for GODOT in "$@"; do
  proj="$WORK/dump-$(basename "$GODOT")"
  mkdir -p "$proj"; bare_project "$proj"
  cp "$HERE/dump_tilemap_api.gd" "$proj/"
  out="$proj/dump.log"
  "$GODOT" --headless --path "$proj" --script dump_tilemap_api.gd > "$out" 2>&1 || true
  if ! grep -q '^APIDUMP ' "$out"; then
    echo "FAIL  $GODOT printed no APIDUMP"; grep -vE "$QUIET" "$out" | head -5 || true
    status=1; continue
  fi
  sed -n 's/^APIDUMP //p' "$out" > "$proj/api.json"
  DUMPS+=("$proj/api.json")
  echo "  read $("$GODOT" --version 2>/dev/null | head -1)"
done
if [ "${#DUMPS[@]}" -gt 0 ]; then
  node "$HERE/build_tilemap_api_map.js" "${DUMPS[@]}" --check-core || status=1
else
  echo "FAIL  no engine produced a dump"; status=1
fi
echo

echo "### 2. ADVICE — every replacement the core names has to exist"
TARGETS=$(node -e '
  const C = require(process.argv[1]);
  const out = [];
  for (const [name, r] of Object.entries(C.GONE_REPLACEMENTS)) {
    if (r.call) out.push(`${name}|call|${r.call}`);
    if (r.prop) out.push(`${name}|prop|${r.prop}`);
  }
  console.log(out.join(";"));
' "$HERE/tilemap-script-scan-core.js")
ENUMS=$(node -e '
  const C = require(process.argv[1]);
  console.log(Object.entries(C.ENUM_CONSTANTS).map(([a, b]) => `${a}|${b}`).join(";"));
' "$HERE/tilemap-script-scan-core.js")
for GODOT in "$@"; do
  proj="$WORK/rep-$(basename "$GODOT")"
  mkdir -p "$proj"; bare_project "$proj"
  cp "$HERE/check_tilemap_replacements.gd" "$proj/"
  out="$proj/rep.log"
  "$GODOT" --headless --path "$proj" --script check_tilemap_replacements.gd -- \
    "--targets=$TARGETS" "--enums=$ENUMS" > "$out" 2>&1 || true
  grep -vE "$QUIET" "$out" | grep -E '^(FAIL|SKIP|REPLACEMENTS)' || true
  if grep -q '^SKIP' "$out"; then
    echo "  $("$GODOT" --version 2>/dev/null | head -1): no TileMapLayer, nothing to check"
    continue
  fi
  if ! grep -q '^REPLACEMENTS VERIFY: ALL PASS' "$out"; then
    echo "FAIL  $GODOT did not pass the replacement check"; status=1
  else
    echo "  $("$GODOT" --version 2>/dev/null | head -1): $(sed -n 's/^REPLACEMENTS: //p' "$out")"
  fi
done
echo

echo "### 3. ROUND TRIP — a scripted TileMap ported by the tools alone"
first="$1"; for last in "$@"; do :; done
if [ "$first" = "$last" ]; then
  echo "  only one engine given; the round trip needs an old one and a new one"
else
  proj="$WORK/trip"
  mkdir -p "$proj"; bare_project "$proj"
  cp "$HERE/tilemap_probe.gd" "$HERE/make_scripted_tilemap_fixture.gd" "$HERE/run_tilemap_probe.gd" "$proj/"

  out="$proj/make.log"
  "$first" --headless --path "$proj" --script make_scripted_tilemap_fixture.gd > "$out" 2>&1 || true
  grep -vE "$QUIET" "$out" | grep -E '^(SCRIPTED FIXTURE|FAIL)' || true
  if ! grep -q '^SCRIPTED FIXTURE .*saved=true .*script=true .*tile_data=true' "$out"; then
    echo "FAIL  $first did not write the scripted fixture"; status=1
  else
    out="$proj/before.log"
    "$first" --headless --path "$proj" --script run_tilemap_probe.gd > "$out" 2>&1 || true
    before="$(sed -n 's/^DIGEST //p' "$out" | head -1)"
    if [ -z "$before" ]; then
      echo "FAIL  the old engine printed no digest"; grep -vE "$QUIET" "$out" | head -5 || true
      status=1
    else
      echo "  before ($("$first" --version 2>/dev/null | head -1)): ${#before} chars"

      # The port, with no hand edits anywhere in it.
      scan="$proj/scan.log"
      node "$HERE/scan_tilemap_script.js" "$proj/tilemap_probe.gd" \
        --scene="$proj/scripted.tscn" --write > "$scan" 2>&1 || true
      manual="$(sed -n 's/.*mechanical (written), \([0-9]*\) for a human.*/\1/p' "$scan" | head -1)"
      rewrote="$(sed -n 's/.*: \([0-9]*\) mechanical (written).*/\1/p' "$scan" | head -1)"
      echo "  scanner: ${rewrote:-0} rewrites applied, ${manual:-?} left for a human"
      if [ "${manual:-1}" != "0" ]; then
        echo "FAIL  the fixture is supposed to be fully mechanical; something needs a hand now"
        grep -E 'BY HAND' "$scan" | head -10 || true
        status=1
      fi
      node "$HERE/convert_tilemap_to_tilemaplayer.js" "$proj/scripted.tscn" --write --script-ported \
        | sed 's/^/    /'

      out="$proj/after.log"
      "$last" --headless --path "$proj" --script run_tilemap_probe.gd > "$out" 2>&1 || true
      after="$(sed -n 's/^DIGEST //p' "$out" | head -1)"
      if [ -z "$after" ]; then
        echo "FAIL  the new engine printed no digest — the ported script did not run"
        grep -vE "$QUIET" "$out" | head -10 || true
        status=1
      elif [ "$before" != "$after" ]; then
        echo "FAIL  the digests differ"
        echo "    before: $before"
        echo "    after:  $after"
        status=1
      else
        echo "  after  ($("$last" --version 2>/dev/null | head -1)): identical digest"
        echo "PASS  the ported script reads the converted scene exactly as the original read the original"
      fi
    fi
  fi
fi
echo

if [ "$status" -eq 0 ]; then
  echo "TILEMAP SCRIPT API: every check green"
else
  echo "TILEMAP SCRIPT API: at least one check failed"
fi
exit "$status"
