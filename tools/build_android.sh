#!/usr/bin/env bash
# Headless Android export.
#   tools/build_android.sh            -> build/shardfall.apk  (release template: optimised engine, no debug
#                                        checks; signed with SHARDFALL_KEYSTORE* if set, else the shared
#                                        test key in tools/keys, so it installs over earlier test builds)
#   tools/build_android.sh debug      -> build/shardfall-debug.apk  (debug template, same key)
#   tools/build_android.sh lite       -> build/shardfall-lite.apk  ("Shardfall Lite", its own app id: the
#                                        Compatibility renderer on OpenGL ES 3, for budget phones whose
#                                        Vulkan drivers crash, e.g. Mali-G52; release template, same key)
#   tools/build_android.sh aab        -> build/shardfall-release.aab (Gradle build; needs the Android
#                                        build template and network access to Google Maven + Gradle)
# Run tools/provision.sh first. Exits non-zero if the export or the signature check fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${TOOLS:-$HOME/toolchains}"
GODOT="$TOOLS/godot/godot"
SDK="$TOOLS/android-sdk"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
MODE="${1:-release}"
mkdir -p "$ROOT/build"
cd "$ROOT/godot"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
case "$MODE" in
  debug)
    OUT="$ROOT/build/shardfall-debug.apk"
    "$GODOT" --headless --path . --export-debug "Android" "$OUT" ;;
  release|lite)
    if [ -z "${SHARDFALL_KEYSTORE:-}" ]; then
      echo "note: no SHARDFALL_KEYSTORE; signing with the shared test key (fine for sideloading, not for the Play Store)"
      SHARDFALL_KEYSTORE="$ROOT/tools/keys/debug.keystore" SHARDFALL_KEYSTORE_USER=androiddebugkey SHARDFALL_KEYSTORE_PASS=android
    fi
    export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$SHARDFALL_KEYSTORE"
    export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$SHARDFALL_KEYSTORE_USER"
    export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$SHARDFALL_KEYSTORE_PASS"
    if [ "$MODE" = "lite" ]; then
      # the phone renderer is a project setting: switch it for this export only, restore it after
      sed -i 's/^renderer\/rendering_method.mobile=.*/renderer\/rendering_method.mobile="gl_compatibility"/' project.godot
      trap 'git -C "$ROOT" checkout -- godot/project.godot' EXIT
      OUT="$ROOT/build/shardfall-lite.apk"
      "$GODOT" --headless --path . --export-release "Android Lite" "$OUT"
    else
      OUT="$ROOT/build/shardfall.apk"
      "$GODOT" --headless --path . --export-release "Android" "$OUT"
    fi ;;
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
