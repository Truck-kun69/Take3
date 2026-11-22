# Releases and signing

## What is built where

`.github/workflows/build.yml` runs on every push to `main` and to `claude/**` branches (and by hand
from the Actions tab). It provisions the toolchain (`tools/provision.sh`), runs the unit tests, and
builds:

| File | What it is |
|---|---|
| `shardfall.apk` | The one build (`com.shardfall.riftsurvivors`, Vulkan Mobile renderer). Shardfall Lite and the web build were retired in 0.9.9. |
| `shardfall-release.aab` | The Play Store bundle. Built only when the release key is configured. |

The files are attached to the workflow run as the `shardfall-android` artifact for 30 days.

## APK size

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

A release-signed APK will not install over a test-key APK: testers uninstall the old build once
(their save is lost unless they stay on test-key builds until the switch).

## Play Console (not set up yet)

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

With a release key: set `SHARDFALL_KEYSTORE`, `SHARDFALL_KEYSTORE_USER` and `SHARDFALL_KEYSTORE_PASS`
in the environment first; `bash tools/build_android.sh aab` builds the bundle.
