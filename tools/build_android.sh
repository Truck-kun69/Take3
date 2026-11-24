#!/usr/bin/env bash
# Headless Android export.
#   tools/build_android.sh            -> build/shardfall.apk  (release template: optimised engine, no debug
#                                        checks; signed with SHARDFALL_KEYSTORE* if set, else the shared
#                                        test key in tools/keys, so it installs over earlier test builds)
#   tools/build_android.sh debug      -> build/shardfall-debug.apk  (debug template, same key)
#   tools/build_android.sh aab        -> build/shardfall-release.aab (Gradle build; needs the Android
#                                        build template and network access to Google Maven + Gradle)
# The release APK is then repacked (tools/apk_repack.py: textures deflated, the engine library
# zopfli-compressed when `pip install zopfli` is available), aligned and signed again with the same key.
# On CI (CI=true, as GitHub Actions sets it) a release build needs SHARDFALL_KEYSTORE: it never falls back to
# the shared test key there (exit 3); locally the test key still signs sideloading builds.
# Run tools/provision.sh first. Exits non-zero if the export or the signature check fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-release}"
if [ "$MODE" = "release" ] && [ "${CI:-}" = "true" ] && [ -z "${SHARDFALL_KEYSTORE:-}" ]; then
  echo "error: a CI release build needs SHARDFALL_KEYSTORE (the release key); it is empty, and CI never signs a release with the test key" >&2
  exit 3
fi
TOOLS="${TOOLS:-$HOME/toolchains}"
GODOT="$TOOLS/godot/godot"
SDK="$TOOLS/android-sdk"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
mkdir -p "$ROOT/build"
cd "$ROOT/godot"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
# The shader baker (export_presets.cfg shader_baker/enabled; docs/OPTIMIZATION.md O4) puts the compiled shaders
# into the APK, so a fresh install skips compiling them on its first launch. It needs the editor running on a
# Vulkan device with the Mobile renderer: with xvfb-run and a Vulkan driver (Mesa's lavapipe will do) the export
# runs the editor under Xvfb; otherwise headless, which exports the same APK without baked shaders.
# NO_SHADER_BAKE=1 forces the headless export.
vulkan_icd() { ls /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json 2>/dev/null | head -1; }
godot_export() {
  if [ -z "${NO_SHADER_BAKE:-}" ] && command -v xvfb-run >/dev/null 2>&1 && [ -n "$(vulkan_icd)" ]; then
    echo "exporting under Xvfb on Vulkan: the shaders are baked into the APK"
    xvfb-run -a "$GODOT" --rendering-driver vulkan --rendering-method mobile --path . "$@"
  else
    echo "note: exporting headless (no xvfb-run or Vulkan driver, or NO_SHADER_BAKE set): shaders are not baked"
    "$GODOT" --headless --path . "$@"
  fi
}
case "$MODE" in
  debug)
    OUT="$ROOT/build/shardfall-debug.apk"
    godot_export --export-debug "Android" "$OUT" ;;
  release)
    if [ -z "${SHARDFALL_KEYSTORE:-}" ]; then
      echo "note: no SHARDFALL_KEYSTORE; signing with the shared test key (fine for sideloading, not for the Play Store)"
      SHARDFALL_KEYSTORE="$ROOT/tools/keys/debug.keystore" SHARDFALL_KEYSTORE_USER=androiddebugkey SHARDFALL_KEYSTORE_PASS=android
    fi
    export SHARDFALL_KEYSTORE SHARDFALL_KEYSTORE_USER SHARDFALL_KEYSTORE_PASS
    export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$SHARDFALL_KEYSTORE"
    export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$SHARDFALL_KEYSTORE_USER"
    export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$SHARDFALL_KEYSTORE_PASS"
    OUT="$ROOT/build/shardfall.apk"
    godot_export --export-release "Android" "$OUT" ;;
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
    cp export_presets.cfg "$ROOT/build/.export_presets.cfg.bak"
    trap 'cp "$ROOT/build/.export_presets.cfg.bak" "$ROOT/godot/export_presets.cfg"' EXIT
    sed -i 's/^gradle_build\/use_gradle_build=false/gradle_build\/use_gradle_build=true/; s/^gradle_build\/export_format=0/gradle_build\/export_format=1/' export_presets.cfg
    godot_export --export-release "Android" "$OUT" ;;
  *)
    echo "unknown mode: $MODE (release, debug or aab)" >&2; exit 2 ;;
esac
[ -f "$OUT" ] || { echo "export failed: $OUT missing" >&2; exit 1; }
if [ "$MODE" = "release" ]; then
  # Repack (tools/apk_repack.py): deflate the textures Godot stores raw and zopfli-recompress the engine
  # library, contents unchanged; then align and sign again with the same key as the export.
  RAW="$ROOT/build/.repack-raw.apk"
  ALIGNED="$ROOT/build/.repack-aligned.apk"
  python3 "$ROOT/tools/apk_repack.py" "$OUT" "$RAW" --cache "${APK_REPACK_CACHE:-$TOOLS/apk-repack-cache}"
  "$BT/zipalign" -f -p 4 "$RAW" "$ALIGNED"
  "$BT/zipalign" -c -p 4 "$ALIGNED"
  # v2 + v3 signatures; no v1 (JAR) signature: minSdkVersion is 24, and every Android from 7.0 (API 24)
  # verifies v2, so META-INF/*.SF / .MF would only add about 50 KB
  "$BT/apksigner" sign --ks "$SHARDFALL_KEYSTORE" --ks-key-alias "$SHARDFALL_KEYSTORE_USER" \
    --ks-pass env:SHARDFALL_KEYSTORE_PASS --key-pass env:SHARDFALL_KEYSTORE_PASS \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true --out "$OUT" "$ALIGNED"
  rm -f "$RAW" "$ALIGNED" "$OUT.idsig"
fi
if [ "${OUT##*.}" = "apk" ]; then
  "$BT/apksigner" verify --print-certs "$OUT" | head -3
  "$BT/aapt2" dump badging "$OUT" 2>/dev/null | grep -E "^package|sdkVersion|native-code" || true
fi
ls -lh "$OUT"
