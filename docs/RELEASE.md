# Releases and signing

## What is built where

`.github/workflows/build.yml` runs on every push to `main` and to `claude/**` branches (and by hand
from the Actions tab). It provisions the toolchain (`tools/provision.sh`), runs the release gate without
its build step (`python3 tools/gate_check.py --no-apk`: the assets, the code rules, the unit tests and leak
checks, the voice checks and the combat render smoke under Xvfb), and only when the gate passes builds:

| File | What it is |
|---|---|
| `shardfall.apk` | The one build (`com.shardfall.riftsurvivors`, Vulkan Mobile renderer). Shardfall Lite and the web build were retired in 0.9.9. |
| `shardfall-release.aab` | The Play Store bundle. Built only when the release key is configured. |

The files are attached to the workflow run as the `shardfall-android` artifact for 30 days.

## The version

One setting holds it: `application/config/version` in `godot/project.godot` (0.11.3-alpha). The title
screen, Options and every copied report show it (`Diag.version()`), and the APK's versionName follows it
because the preset's `version/name` is left empty. The gate fails if the built APK says anything else.

`version/code` in `godot/export_presets.cfg` (22 from 0.11.3) is the number Android compares: it must go
up for every build testers install over the last one, or the phone refuses the update.

## Moving a save to a new install

A save lives in the app's own storage, so uninstalling deletes it. The switch to the release key below
forces one uninstall. Before it, testers open Options > Game > Copy save from the main menu and keep the
text somewhere safe (a note, or a message to themselves). After installing the new build, they copy that
text again and tap Options > Game > Paste save, which shows the gold and stash it holds before replacing
anything.

The text is one line: `SHARDFALL-SAVE:1:<size>:<checksum>:<base64 of the gzipped JSON>`. Spaces and line
breaks a chat app adds are ignored; a cut-off or edited copy is refused with a message and changes nothing.
The profile it replaces is kept beside the new one as `profile_before_paste.json`. Three things never
travel with a save and stay as the phone has them: the graphics self-test results, the benchmark result and
`purchases` (kept for the store purchases planned for a later version, which belong to the Google account,
not to a copied text).

## APK size

0.11.3: 140.94 MB (140,937,136 bytes): script only.

0.11.2: 140.93 MB (140,932,877 bytes): script only.

0.11.1: 140.93 MB (140,932,877 bytes): script only (the Wayside Forge's prop is built from primitives in code).

0.11.0: 140.93 MB (140,928,781 bytes). The Camp, its NPCs' pages and the first-run coach are script only
(about 34 KB of compiled scripts); no new art or sound.

0.10.6: 140.89 MB (140,887,358 bytes): script only since 0.10.4.

0.10.5: 140.89 MB (140,887,358 bytes): script only since 0.10.4.

0.10.4: 140.88 MB (140,883,262 bytes). The baked shaders add 2.34 MB (50 files), the Emberwitch's two baked fire
loops 93 KB.

0.10.3: 138.41 MB (138,410,476 bytes). The voice pack adds 2.56 MB: 61 clips shipped as Godot's imported
Ogg Vorbis streams (2.69 MB unpacked).

0.10.1: 135.85 MB (135,845,361 bytes). 0.10.0's texel budget brings the foes' albedo maps to 1024 px; the
0.10.1 features (Copy report, save transfer, the pinned page buttons) are script only.

0.10.0: 139.04 MB (139,039,754 bytes). The voice layer (manifest, VoiceBank, subtitles, intro) adds 29 KB; the
ElevenLabs voice pack, once generated, adds about 2 MB (the gate allows 2.5). See docs/VOICES.md.

0.9.9: 139.01 MB (139,010,339 bytes), the one APK. The texel budget (`tools/texture_budget.py`) imports
the normal and ORM maps of props and foes and the albedo of small clutter at 1024 px and keeps the rest
at 2048: textures 97.5 MB of it (97 files), the engine library 23.75 MB, scenes and meshes 10.1 MB, audio
2.1 MB, foe animation (`.vat`) 1.9 MB, `classes.dex` 1.7 MB.

0.9.8: 157.84 MB (157,837,190 bytes). From 0.9.8 every model and ground texture ships at
its full 1024-2048 px, VRAM-compressed and never downscaled, so the 50 MB budget of 0.9.7 is retired.
The largest parts, compressed: textures 116.4 MB (87 files; the generated heroes, bosses, foes and
props carry 2048 px maps), the engine library 23.75 MB, scenes and meshes 10.3 MB, audio 2.1 MB,
`classes.dex` 1.7 MB, foe animation (`.vat`, SVA3) 1.6 MB.

0.9.7: 49.90 MB, under that budget, with the hero and boss textures at 256-512 px.

After Godot exports the release APK, `tools/build_android.sh` repacks it (`tools/apk_repack.py`):
the `.ctex` textures Godot stores uncompressed are deflated (13.5 -> 11.3 MB) and the engine library
and `classes.dex` are recompressed with zopfli (26.3 -> 25.5 MB, needs `pip install zopfli`; cached by
content hash). Every entry's content is checked to be byte-identical (CRC and size). The APK is then
aligned (`zipalign -p 4`) and signed again with the same key, v2 and v3 only (minSdkVersion is 24).
Imported scenes use zstd level 19 with long-distance matching (`project.godot`, `[compression]`).

From 0.10.4 the export bakes the shaders (`shader_baker/enabled` in the preset): the APK carries them
compiled, so a fresh install or an update skips compiling them on its first launch (docs/OPTIMIZATION.md O4).
The baker needs the editor running on a Vulkan device with the Mobile renderer, so `tools/build_android.sh`
exports under `xvfb-run` when a Vulkan driver is installed (Mesa's software one, `mesa-vulkan-drivers`, will
do; CI installs it) and headless otherwise, which builds the same APK without baked shaders.
`NO_SHADER_BAKE=1` forces the headless export. The gate fails a build that could bake and did not.

## The release key

Until a release key is configured, APKs are signed with the shared test key in `tools/keys`. That
is fine for sideloading to testers. It must not be used for the Play Store: the key is public.

Create the release key once, on your own computer. Nobody else, including Claude, should ever see
the file or its password.

```bash
keytool -genkeypair -v -keystore shardfall-release.keystore -alias shardfall -keyalg RSA -keysize 4096 -validity 10000
```

Keep two backups of the keystore file and its password (for example a password manager and an
offline drive). If Play App Signing is enabled (the default for new apps), losing this upload key
is recoverable through Play support; losing it without Play App Signing is not.

Then add three repository secrets under GitHub > Settings > Secrets and variables > Actions:

| Secret | Value |
|---|---|
| `SHARDFALL_KEYSTORE_B64` | The output of `base64 -w0 shardfall-release.keystore` |
| `SHARDFALL_KEYSTORE_USER` | `shardfall` (the alias) |
| `SHARDFALL_KEYSTORE_PASS` | The keystore password |

The next push builds signed APKs and the bundle.

A release-signed APK will not install over a test-key APK: testers uninstall the old build once.
Their progress comes across with Copy save and Paste save (see "Moving a save to a new install" above).

## Play Console (not set up yet)

The listing, privacy policy, store graphics and App content answers are ready in `docs/PLAY_STORE.md`.

1. Create the developer account ($25 once) and the app (`com.shardfall.riftsurvivors`).
2. Upload `shardfall-release.aab` to the internal testing track and add testers by email.
3. Personal accounts created after November 2023 need a closed test with 12 testers for 14 days
   before production access. Start that clock early.
4. The pre-launch report and Android vitals then give crash traces from real devices.

## Building locally

```bash
bash tools/provision.sh
```

```bash
bash tools/build_android.sh
```

With `xvfb-run` and a Vulkan driver installed, it bakes the shaders (see APK size above).

With a release key: set `SHARDFALL_KEYSTORE`, `SHARDFALL_KEYSTORE_USER` and `SHARDFALL_KEYSTORE_PASS`
in the environment first; `bash tools/build_android.sh aab` builds the bundle.
