#!/usr/bin/env bash
# Runs every claim in docs/why-y-sort-draws-the-wrong-order.md against a real
# Godot 4 binary.
#
#   docs/verify_y_sort.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Unlike the other verify_*.sh in this repo, this one cannot use --headless.
# Most of the claims are about which tile the renderer draws LAST, and the
# headless build substitutes a dummy renderer: SubViewport.get_texture()
# returns a texture whose image comes back null, so there is no pixel to read.
# We therefore ask for a real GL context on a virtual X server. If xvfb-run is
# missing the script says so and exits 2 rather than quietly measuring nothing.
set -euo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary" >&2
  exit 2
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found: these claims are about rendered draw order and" >&2
  echo "cannot be measured on the headless (dummy) renderer." >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]
config/name="BlobsmithYSortCheck"
EOF
cp "$HERE/verify_y_sort.gd" "$PROJ/verify_y_sort.gd"

# ALSA has no card in CI and Godot's fallback chatter would bury the results.
xvfb-run -a -s "-screen 0 640x480x24" \
  "$GODOT" --rendering-driver opengl3 --path "$PROJ" --script verify_y_sort.gd 2>&1 \
  | grep -vE '^(Godot Engine v|ALSA lib |OpenGL API |WARNING: |ERROR: |  +at: |$)'
exit "${PIPESTATUS[0]}"
