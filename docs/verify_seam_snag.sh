#!/usr/bin/env bash
# Runs every claim in docs/why-bodies-catch-on-tile-seams.md
# against a real Godot 4 binary, in a throwaway project with nothing configured.
#
#   docs/verify_seam_snag.sh /path/to/Godot_v4.7-stable_linux.x86_64
#   docs/verify_seam_snag.sh /path/to/godot --invert   # must exit 1
#
# Headless is fine: nothing on that page is about pixels. --fixed-fps 60 makes
# every run the same sequence of 1/60 s steps and runs them as fast as it can.
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

config/name="BlobsmithSeamSnagCheck"
EOT
cp "$HERE/verify_seam_snag.gd" "$PROJ/verify_seam_snag.gd"
shift   # everything after the binary is passed through to the script

OUT="$(timeout 300 "$GODOT" --headless --fixed-fps 60 --path "$PROJ" --script verify_seam_snag.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |NOTE |SEAM SNAG)'

if ! printf '%s\n' "$OUT" | grep -q '^SEAM SNAG: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -q '^SEAM SNAG: ALL PASS' || exit 1
exit 0
