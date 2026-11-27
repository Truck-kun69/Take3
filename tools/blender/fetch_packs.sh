#!/usr/bin/env bash
# Download the CC0 creature packs that tools/blender/import_packs.py turns into swarm foes.
#   bash tools/blender/fetch_packs.sh /tmp/packs
# KayKit (Kay Lousberg) is on GitHub; Quaternius' "Ultimate Monsters" is a public Google Drive folder
# (gdown fetches it; pip install gdown). Both are CC0: free for any use, no attribution required.
set -euo pipefail
OUT="${1:-/tmp/packs}"
mkdir -p "$OUT" && cd "$OUT"
for r in KayKit-Character-Pack-Skeletons-1.0; do
  [ -d "$r" ] || git clone -q --depth 1 "https://github.com/KayKit-Game-Assets/$r.git"
done
[ -d quaternius_monsters ] || python3 -m gdown --folder -O quaternius_monsters "https://drive.google.com/drive/folders/18m4KpzpEzhC9wl7jzr6dUc0N8Jozr79C"
echo "packs in $OUT; next:"
echo "  ~/toolchains/blender-4.5.15-linux-x64/blender -b --factory-startup --python tools/blender/import_packs.py -- $OUT"
