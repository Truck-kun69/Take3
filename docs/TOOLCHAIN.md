# Toolchain: Godot 4 + Android SDK in a headless session

Everything below was actually run in this cloud session (Ubuntu 24.04, x86_64, no GPU).
The scripts are idempotent, so they double as an environment setup script.

## 1. Provisioning (`tools/provision.sh`)

| Component | Version | Source | Size on disk |
|---|---|---|---|
| Godot editor (headless-capable) | 4.7.2-stable | `github.com/godotengine/godot/releases` | ~150 MB |
| Export templates (Android only) | 4.7.2-stable | same release, `.tpz` (1.28 GB download, only `android_*` extracted) | ~130 MB |
| Android cmdline-tools | 11076708 | `dl.google.com/android/repository` | ~150 MB |
| platform-tools, build-tools 35.0.1, platforms;android-35 | via `sdkmanager` | Google repository | ~300 MB |
| JDK | OpenJDK 21 (pre-installed) | apt | - |
| Debug keystore | RSA 2048, `androiddebugkey` / `android` | `keytool` | 3 KB |

The script also writes Godot's editor settings (`~/.config/godot/editor_settings-4.7.tres`) with
`export/android/android_sdk_path`, `java_sdk_path` and the debug keystore, which is how a
**headless** export finds the SDK: there is no editor UI to configure it in.

Network hosts needed: `github.com` (+ its release CDN), `dl.google.com`. For Gradle/AAB builds
additionally `services.gradle.org`, `plugins.gradle.org`, `repo.maven.apache.org` and Google's Maven
(`dl.google.com/dl/android/maven2`). All were reachable in this session.

For on-device-free rendering tests the session also needs Mesa's software Vulkan driver:

```bash
apt-get install -y mesa-vulkan-drivers vulkan-tools
```

`lavapipe` (llvmpipe Vulkan 1.4) lets Godot run the real **Forward Mobile** renderer under
`xvfb-run`, which is how the screenshots and the GPU compute path were verified without a GPU.

## 2. Running the project headless

```bash
export PATH="$HOME/toolchains/godot:$PATH"
cd godot
godot --headless --path . --import                                  # builds .godot/ and the class cache
godot --headless --path . res://tests/tests.tscn -- unit            # 30+ invariant tests
godot --headless --path . res://tests/tests.tscn -- sim bench       # bot-played runs + stress bench
xvfb-run -a godot --path . --rendering-method mobile --rendering-driver vulkan res://tests/shots.tscn -- /tmp/shots
```

Tests run as a **scene**, not with `-s script.gd`: in script mode autoload singletons (`Save`,
`Sfx`) are not registered as globals when dependent classes compile, which fails every script
that references them.

## 3. Android export (`tools/build_android.sh`)

```bash
tools/build_android.sh            # build/shardfall-debug.apk, debug-signed, arm64-v8a + x86_64
tools/build_android.sh release    # needs SHARDFALL_KEYSTORE, SHARDFALL_KEYSTORE_USER, SHARDFALL_KEYSTORE_PASS
tools/build_android.sh aab        # Play Store bundle through Gradle (installs the Android build template)
```

* The **APK** path uses Godot's prebuilt templates (`android_debug.apk` / `android_release.apk`):
  no Gradle, no NDK, ~1 minute. The script verifies the signature with `apksigner verify` and
  prints the manifest summary with `aapt2 dump badging`.
* The **AAB** path flips `gradle_build/use_gradle_build` and `export_format` for one export,
  unpacks `android_source.zip` into `godot/android/build`, and lets Gradle fetch its dependencies.
  Release signing keys are passed through `GODOT_ANDROID_KEYSTORE_RELEASE_*` environment variables
  so they never land in `export_presets.cfg`.
* Renderer: `rendering_method.mobile="mobile"` (Vulkan). Devices without Vulkan fall back to the
  Compatibility renderer automatically in Godot 4.4+; the game then uses the CPU crowd solver.

## 4. Engine integration points

### Compute shader (crowd separation)
`scripts/sim/crowd_compute.gd` compiles GLSL at runtime on a **local RenderingDevice**
(`RenderingServer.create_local_rendering_device()`), so it does not compete with the main
render graph. Each frame it uploads `[x, y, radius, pad]` per foe, dispatches a tiled O(n²)
solver (64-body shared-memory tiles), and **reads the result back one frame later** so the CPU
never blocks on `rd.sync()` waiting for the GPU it just submitted to. Results are mapped back by
foe `uid` because swap-removal reorders the swarm between dispatch and collect.

When no RenderingDevice exists (Compatibility renderer, `--headless`, old GLES phones) `init()`
returns false and `Swarm.cpu_separation` (spatial-hash, staggered 30 Hz) takes over. Both
paths were exercised in this session: headless runs report `cpu`, `xvfb` + lavapipe runs report `gpu`.

### Status system: GDScript today, C++ GDExtension path
The status/DoT/reaction system lives in `Swarm` as **packed struct-of-arrays** (`burn`, `burn_t`,
`chill_t`, ...) with all per-foe writes inside methods on that object. This is deliberate:

* In GDScript, `other.packed_array[i] = v` copies the whole array through a temporary
  (copy-on-write), while `packed_array[i] = v` on `self` writes in place. Keeping writes inside
  `Swarm` avoids an O(n) copy per hit.
* The same layout maps 1:1 onto a C++ GDExtension class (`PackedFloat32Array` members, the same
  method names), so `tick_timers`, `step_move` and `cpu_separation` can be moved to C++ without
  touching callers. That move is only worth it on the CPU-fallback path; the bench numbers in
  `docs/DESIGN.md` show where the time goes.
* A GDExtension build needs `godot-cpp` (matching 4.7), SCons, and for Android the NDK
  (`sdkmanager "ndk;28.1.13356709"`) to cross-compile `arm64-v8a`. That was not done in this
  session; the GDScript version runs a 680-foe stress test in about 1–1.5 ms of simulation per
  frame on the CPU path after the cycle 1 and 2 fixes.
