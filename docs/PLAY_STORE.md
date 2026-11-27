# Google Play listing (paste-ready)

Everything the Play Console asks for when the app is created, in its order. Files are in `docs/store/`.
The release key steps are in `docs/RELEASE.md`.

## Create app

| Field | Answer |
|---|---|
| App name | Shardfall: Rift Survivors |
| Default language | English (United States) |
| App or game | Game |
| Free or paid | Free |
| Package (set by the first upload) | `com.shardfall.riftsurvivors` |

## Store listing

**Short description** (76 of 80 characters):

> Four exiles. Five acts. Endless hordes. A dark action RPG that runs offline.

**Full description:**

> The Veil has torn and the shards have fallen. Choose one of four exiles and hold the rift against
> hundreds of creatures at once.
>
> - Four exiles, each built around one mechanic: the Warden's shieldwall, the Sparkcaller's ricochets, the
>   Emberwitch's spreading fire, the Stormwright's lightning.
> - Five acts, from Mossglen Hollow to the Drowned Cathedral, each with its own boss.
> - Build as you fight: weapons, support gems, perks, evolutions and fusions at every level-up.
> - Gear and crafting with shards, a passive web, Torment difficulties and a Daily Rift with a share code.
> - Bargain with the Whisperer, bank or push your hoard at extraction portals, and find the Rift Echoes
>   that tell the story.
> - Built for phones: touch controls, left-handed layout, colour-blind palette, a graphics self-test.
> - No ads, no accounts, no internet needed.

| Asset | File |
|---|---|
| App icon (512 x 512) | `docs/store/icon-512.png` |
| Feature graphic (1024 x 500) | `docs/store/feature-graphic-1024x500.png` |
| Phone screenshots (1920 x 1080) | `docs/store/phone-1-combat.jpg` to `phone-6-shard-web.jpg` |

Category: **Action**. Contact email: yours (shown publicly on the listing).

## App content

| Section | Answer |
|---|---|
| Privacy policy URL | `https://github.com/Truck-kun69/Take3/blob/main/docs/PRIVACY.md` (after this branch is merged; until then the same path on `claude/zealous-einstein-4qh7dn`) |
| App access | All functionality is available without special access |
| Ads | No, the app does not contain ads |
| Content rating | IARC questionnaire, category Game: fantasy violence against monsters (no realistic violence, no gore; red "blood pools" are a terrain hazard); no sexual content, drugs, crude language or real-money gambling. Shards and gold buy random items, but only in-game currency, never money. |
| Target audience | 13 and over (not designed for children) |
| News app | No |
| Data safety | Collects no data, shares no data. Nothing leaves the phone, so encryption and deletion requests do not apply. |
| Advertising ID | No, not used |
| Government, financial, health features | None |

## Releases

1. Testing › Internal testing: upload `shardfall-release.aab` (built by CI once the release key's secrets are
   set). Add testers by email.
2. Personal developer accounts made after November 2023 must run a closed test with at least 12 testers
   opted in for 14 days in a row before applying for production.
3. Play App Signing (the default) keeps the app signing key; the release keystore in `docs/RELEASE.md` is the
   upload key.

The APK targets API 36 (Android 16), arm64-v8a, and requests one permission (vibrate).
