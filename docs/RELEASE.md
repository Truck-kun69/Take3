# Releases and signing

## What is built where

`.github/workflows/build.yml` runs on every push to `main` and to `claude/**` branches (and by hand
from the Actions tab). It provisions the toolchain (`tools/provision.sh`), runs the unit tests, and
builds:

| File | What it is |
|---|---|
| `shardfall.apk` | The main build (Vulkan Mobile renderer). |
| `shardfall-lite.apk` | "Shardfall Lite" (OpenGL ES 3), for budget phones. Installs beside the main app. |
| `shardfall-release.aab` | The Play Store bundle. Built only when the release key is configured. |

The files are attached to the workflow run as the `shardfall-android` artifact for 30 days.

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

```bash
bash tools/build_android.sh lite
```

With a release key: set `SHARDFALL_KEYSTORE`, `SHARDFALL_KEYSTORE_USER` and `SHARDFALL_KEYSTORE_PASS`
in the environment first; `bash tools/build_android.sh aab` builds the bundle.
