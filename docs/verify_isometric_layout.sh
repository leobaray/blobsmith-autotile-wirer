#!/usr/bin/env bash
# Runs every claim in docs/why-my-isometric-tilemap-is-not-a-diamond.md against
# a real Godot 4 binary, in a throwaway project with nothing configured.
#
#   docs/verify_isometric_layout.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Exits non-zero if any claim fails.
set -euo pipefail

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
config/name="BlobsmithIsometricCheck"
EOF
cp "$HERE/verify_isometric_layout.gd" "$PROJ/verify_isometric_layout.gd"
shift   # everything after the binary is passed through to the script

# The gate is the summary line as well as the exit code: a GDScript parse error
# still exits 0 and measures nothing.
set +e
OUT="$("$GODOT" --headless --path "$PROJ" --script verify_isometric_layout.gd -- "$@" 2>&1)"
CODE=$?
set -e
printf '%s\n' "$OUT" | grep -vE '^(Godot Engine v|$)'
if ! printf '%s\n' "$OUT" | grep -q '^ISOMETRIC [0-9]*/[0-9]* PASS'; then
  echo "ERROR: the script did not finish — no claim was measured." >&2
  exit 3
fi
exit "$CODE"
