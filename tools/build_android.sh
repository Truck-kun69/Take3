#!/usr/bin/env bash
# Headless Android export.
#   tools/build_android.sh            -> build/shardfall-debug.apk  (debug-signed, arm64-v8a + x86_64)
#   tools/build_android.sh release    -> build/shardfall-release.apk (needs SHARDFALL_KEYSTORE* env vars)
#   tools/build_android.sh aab        -> build/shardfall-release.aab (Gradle build; needs the Android
#                                        build template and network access to Google Maven + Gradle)
# Run tools/provision.sh first. Exits non-zero if the export or the signature check fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${TOOLS:-$HOME/toolchains}"
GODOT="$TOOLS/godot/godot"
SDK="$TOOLS/android-sdk"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
MODE="${1:-debug}"
mkdir -p "$ROOT/build"
cd "$ROOT/godot"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
case "$MODE" in
  debug)
    OUT="$ROOT/build/shardfall-debug.apk"
    "$GODOT" --headless --path . --export-debug "Android" "$OUT" ;;
  release)
    : "${SHARDFALL_KEYSTORE:?set SHARDFALL_KEYSTORE, SHARDFALL_KEYSTORE_USER, SHARDFALL_KEYSTORE_PASS}"
    export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$SHARDFALL_KEYSTORE"
    export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$SHARDFALL_KEYSTORE_USER"
    export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$SHARDFALL_KEYSTORE_PASS"
    OUT="$ROOT/build/shardfall-release.apk"
    "$GODOT" --headless --path . --export-release "Android" "$OUT" ;;
  aab)
    # Gradle builds need res://android/build (installed from the export templates' android_source.zip).
    if [ ! -d android/build ]; then
      mkdir -p android/build
      unzip -q -o "$HOME/.local/share/godot/export_templates/"*/android_source.zip -d android/build
      cat "$HOME/.local/share/godot/export_templates/"*/version.txt > android/.build_version
      touch android/build/.gdignore
    fi
    : "${SHARDFALL_KEYSTORE:?a release keystore is required for an AAB}"
    export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$SHARDFALL_KEYSTORE" GODOT_ANDROID_KEYSTORE_RELEASE_USER="$SHARDFALL_KEYSTORE_USER" GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$SHARDFALL_KEYSTORE_PASS"
    OUT="$ROOT/build/shardfall-release.aab"
    sed -i 's/^gradle_build\/use_gradle_build=false/gradle_build\/use_gradle_build=true/; s/^gradle_build\/export_format=0/gradle_build\/export_format=1/' export_presets.cfg
    trap 'git -C "$ROOT" checkout -- godot/export_presets.cfg' EXIT
    "$GODOT" --headless --path . --export-release "Android" "$OUT" ;;
esac
[ -f "$OUT" ] || { echo "export failed: $OUT missing" >&2; exit 1; }
if [ "${OUT##*.}" = "apk" ]; then
  "$BT/apksigner" verify --print-certs "$OUT" | head -3
  "$BT/aapt2" dump badging "$OUT" 2>/dev/null | grep -E "^package|sdkVersion|native-code" || true
fi
ls -lh "$OUT"
