#!/usr/bin/env bash
# Idempotent toolchain provisioning for Shardfall (Godot 4 + Android).
# Installs into $TOOLS (default ~/toolchains):
#   godot/               Godot editor binary (headless-capable) for Linux x86_64
#   ~/.local/share/godot/export_templates/<ver>/   Android export templates (only the files Android needs)
#   android-sdk/         cmdline-tools, platform-tools, build-tools, platform
#   debug.keystore       Android debug signing key
# and writes Godot's editor settings so headless exports find the SDK, JDK and keystore.
#
# Usage:  bash tools/provision.sh          (safe to re-run; skips what is already there)
set -euo pipefail

GODOT_VER="${GODOT_VER:-4.7.2}"
GODOT_TAG="${GODOT_VER}-stable"
TOOLS="${TOOLS:-$HOME/toolchains}"
SDK="$TOOLS/android-sdk"
BUILD_TOOLS="${BUILD_TOOLS:-35.0.1}"
PLATFORM="${PLATFORM:-android-35}"
CMDLINE_ZIP="commandlinetools-linux-11076708_latest.zip"
REL="https://github.com/godotengine/godot/releases/download/$GODOT_TAG"
TPL_DIR="$HOME/.local/share/godot/export_templates/${GODOT_VER}.stable"

mkdir -p "$TOOLS/godot" "$SDK" "$TPL_DIR"
log() { printf '\033[1;36m[provision]\033[0m %s\n' "$*"; }
fetch() { # url dest, with retries
  local n=0
  until curl -fL --retry 4 --retry-delay 2 -o "$2.part" "$1"; do
    n=$((n+1)); [ $n -ge 4 ] && { echo "download failed: $1" >&2; exit 1; }; sleep $((2**n))
  done
  mv "$2.part" "$2"
}

# 1. Godot editor (the same binary runs headless with --headless)
GODOT_BIN="$TOOLS/godot/Godot_v${GODOT_TAG}_linux.x86_64"
if [ ! -x "$GODOT_BIN" ]; then
  log "Downloading Godot $GODOT_TAG"
  fetch "$REL/Godot_v${GODOT_TAG}_linux.x86_64.zip" "$TOOLS/godot/godot.zip"
  unzip -o -q "$TOOLS/godot/godot.zip" -d "$TOOLS/godot" && rm "$TOOLS/godot/godot.zip"
  chmod +x "$GODOT_BIN"
fi
ln -sf "$GODOT_BIN" "$TOOLS/godot/godot"

# 2. Export templates. The .tpz is ~1.3 GB; only the Android members are extracted to keep disk use low.
if [ ! -f "$TPL_DIR/android_debug.apk" ]; then
  log "Downloading export templates (large)"
  fetch "$REL/Godot_v${GODOT_TAG}_export_templates.tpz" "$TOOLS/templates.tpz"
  unzip -o -q -j "$TOOLS/templates.tpz" 'templates/android_*' 'templates/version.txt' -d "$TPL_DIR"
  rm -f "$TOOLS/templates.tpz"
fi

# 3. Android SDK (command-line tools, then sdkmanager for the rest)
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  log "Downloading Android command-line tools"
  fetch "https://dl.google.com/android/repository/$CMDLINE_ZIP" "$SDK/cmdline.zip"
  rm -rf "$SDK/cmdline-tools" && mkdir -p "$SDK/cmdline-tools"
  unzip -q "$SDK/cmdline.zip" -d "$SDK/cmdline-tools" && mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest" && rm "$SDK/cmdline.zip"
fi
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
if [ ! -x "$SDK/build-tools/$BUILD_TOOLS/apksigner" ]; then
  log "Installing platform-tools, build-tools;$BUILD_TOOLS, platforms;$PLATFORM"
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null || true
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" "platform-tools" "build-tools;$BUILD_TOOLS" "platforms;$PLATFORM" >/dev/null
fi

# 4. Debug keystore (standard Android debug credentials)
KS="$TOOLS/debug.keystore"
if [ ! -f "$KS" ]; then
  log "Creating debug keystore"
  keytool -genkeypair -v -keystore "$KS" -storepass android -alias androiddebugkey -keypass android \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi

# 5. Editor settings: where headless exports look for the SDK, JDK and keystore
JAVA_SDK="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
ES_DIR="$HOME/.config/godot"
mkdir -p "$ES_DIR"
ES="$ES_DIR/editor_settings-${GODOT_VER%.*}.tres"
cat > "$ES" <<EOF
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/android_sdk_path = "$SDK"
export/android/java_sdk_path = "$JAVA_SDK"
export/android/debug_keystore = "$KS"
export/android/debug_keystore_user = "androiddebugkey"
export/android/debug_keystore_pass = "android"
EOF
# Some versions key the file by major.minor, some by major only
cp "$ES" "$ES_DIR/editor_settings-4.tres"

log "Godot:     $("$GODOT_BIN" --headless --version 2>/dev/null | tail -1)"
log "Templates: $(cat "$TPL_DIR/version.txt" 2>/dev/null)"
log "SDK:       $SDK (build-tools $BUILD_TOOLS, $PLATFORM)"
log "JDK:       $JAVA_SDK"
log "Done. Add to PATH:  export PATH=\"$TOOLS/godot:\$PATH\""
