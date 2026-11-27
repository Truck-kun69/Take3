#!/usr/bin/env bash
# Bakes the Emberwitch's fire loops (Sfx._synth_fire_loop) and encodes them as Ogg Vorbis into
# godot/audio/sfx/, where Sfx loads them instead of synthesizing them mid-run (docs/OPTIMIZATION.md O6).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/root/toolchains/godot/godot}"
TMP="$(mktemp -d)"
"$GODOT" --headless --path godot res://tests/bake_loops.tscn -- "$TMP"
for k in fire_crackle fire_rumble; do
  ffmpeg -loglevel error -y -i "$TMP/$k.wav" -c:a libvorbis -q:a 3 "godot/audio/sfx/$k.ogg"
  echo "$k.ogg: $(stat -c %s "godot/audio/sfx/$k.ogg") bytes"
done
rm -rf "$TMP"
