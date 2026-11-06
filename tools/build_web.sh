#!/usr/bin/env bash
# Web export -> one self-contained HTML file you can double-click, host anywhere, or publish.
#   tools/build_web.sh   ->  build/shardfall.html (standalone) and build/shardfall_artifact.html (body-only, for hosts that wrap pages)
# Needs the web export templates (tools/provision.sh installs Android only; this fetches the web ones if missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${TOOLS:-$HOME/toolchains}"
TPL="$HOME/.local/share/godot/export_templates/4.7.2.stable"
if [ ! -f "$TPL/web_nothreads_release.zip" ]; then
  curl -fL --retry 4 -o "$TOOLS/templates.tpz" https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
  unzip -o -q -j "$TOOLS/templates.tpz" 'templates/web_nothreads*' -d "$TPL" && rm -f "$TOOLS/templates.tpz"
fi
mkdir -p "$ROOT/build/web"
cd "$ROOT/godot"
"$TOOLS/godot/godot" --headless --path . --import >/dev/null 2>&1 || true
"$TOOLS/godot/godot" --headless --path . --export-release "Web" "$ROOT/build/web/index.html"
python3 "$ROOT/tools/pack_web.py" "$ROOT/build/web" "$ROOT/build/shardfall.html"
python3 "$ROOT/tools/pack_web.py" "$ROOT/build/web" "$ROOT/build/shardfall_artifact.html" --artifact
