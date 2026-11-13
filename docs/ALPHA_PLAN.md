# Road to alpha: critique and plan (Nov 2026)

This is the working plan for taking Shardfall from "runs on two phones" to an alpha that testers can
judge fairly. Every finding below is backed by something checked in the code, in a captured frame or
in a cited source. Anything not yet verified is marked **unverified**.

## 0. Status (13 Nov 2026, build 0.9.0-alpha)

| Milestone | State | What was done | What is still open |
|---|---|---|---|
| M0 Measure | Done, except device numbers | Clip filmstrips (`tests/model_view` modes `foe`, `strip`); `tests/shimmer`; `tests/view_bench` | Benchmark screenshots from the S22 and A05 on this build |
| M1 Animation | Done | Foes play the packs' own clips from vertex animation textures. Heroes and the Act V boss play CC0 KayKit clips retargeted in Blender (`tools/blender/retarget.py`), through an `AnimationTree`: speed-matched idle/walk/run, attacks while running, dodge, hit, death | Meshy rigging was not usable: fal's synchronous endpoint times out after 30 s and the queue endpoint is not authorised for this session's key. The three older procedural bosses (acts I to IV) still use sine-wave clips. No fingers or foot IK |
| M2 Image | Done | Mipmapped CC0 ground textures per act, broad grass, contact shadows, native resolution + MSAA on flagship phones | Heroes are realistic and foes low-poly: the style gap remains. The shimmer metric read the same before and after (0.30 vs 0.35), so on this software renderer the old ground was dark and low-contrast rather than aliased; whether phones still shimmer needs a screen recording |
| M3 Performance | Partly | Measured: 3.3 ms simulation + 2.2 ms view at 680 foes on the build server. Grunt cut from 1,130 to 703 triangles. Cheaper ground shader | No C++ extension and no sprite impostors: the measurements did not show the CPU as the limit, and the GPU side cannot be measured here. Decide from device numbers |
| M4 Replayability | Mostly | 13 weapons, any-pair fusions, 8-minute acts, Rift Champions at each third, unlock track with a Codex page | No new regular foe behaviours (shielded, summoner, leaper). Boss life was raised 2.2x for the long acts; bots now take 9 to 43 s, which still needs a human check |
| M5 Audio | Done | 33 generated sound effects and five looping act tracks in the override slots | Nobody has listened to them yet: I cannot hear audio. Levels were matched by peak, not by ear. No menu or boss music |
| M6 Infrastructure | Done, except Play Console | CI workflow (tests, both APKs, bundle when the key is set), `docs/RELEASE.md` | Release key and secrets (owner), Play Console (owner), Firebase Test Lab |

fal spend for this plan: about $0.60 (five Lyria tracks, 33 short sound effects, one image test).

## 1. Critique: where the game stood before this plan

### Animation (the worst area)

- **Heroes and bosses have no authored motion.** Every clip is sine-wave maths on joint angles that
  I wrote in `tools/blender/build_models.py` (`hero_clips`, `boss_clips`). There is no motion
  capture, no hand-keyed animation and no foot planting.
- **The hero skeleton is minimal.** It has 21 joints and was fitted to the mesh by pose detection.
  It has no fingers, no twist bones and no proper rest orientation.
- **Only one clip plays at a time.** `hero_rig.gd` uses a single `AnimationPlayer` with a
  cross-fade. A hero cannot cast while running, and the run cycle is not matched to movement speed,
  so feet slide.
- **Foes have no skeleton at all.** `foe.gdshader` swings each limb rigidly around one pivot. A foe
  has a walk swing and nothing else: no attack, no hit reaction, no death, no spawn.
- **The frames confirm it.** In a four-state capture of the Warden, idle and cast are nearly the
  same stiff stance, the run is a crouched lunge, and the roll is a rigid plank.
- **Real animation was thrown away.** The CC0 packs the foes were built from ship with authored
  clips. The KayKit skeleton has 95 clips on a humanoid rig (runs, attacks, hits, deaths, dodges,
  "resurrect"). Each Quaternius monster has about 14 (idle, walk, run, punch, hit, death). The
  import baked each foe into a single pose and discarded the rest.

### Image quality (the "grainy" look)

- **The ground is fully procedural.** `textures/terrain/` is empty, so `terrain.gdshader` builds the
  ground from noise functions. Procedural noise has no mipmaps, so fine terms (pebbles, cracks,
  `vn(p / 9.0)`) alias and shimmer as the camera moves. Shipped games use mipmapped textures, which
  the GPU filters for free.
- **Grass is sub-pixel geometry.** Each tuft is seven thin cones, 60 tufts per chunk in Act I. At
  the game camera these are thinner than a pixel, which reads as noise.
- **Anti-aliasing is weak on phones.** The Mobile renderer has no temporal anti-aliasing. FXAA only
  smooths edges. Auto renders at 85% and upscales with a plain bilinear filter, because FSR is not
  available on the Mobile renderer.
- **Styles clash.** Heroes are realistic, textured meshes. Foes are flat-shaded low-poly models with
  one colour per face. The two do not look like one game.

### Performance (unknown since the fixes)

- The only real-device numbers are from an old debug build: 13 FPS on a Galaxy S22 at 400 foes.
- Since then the build moved to the release engine, the torch shadow was cut, a frame cap was added
  and a Low tier and Lite APK were made. **None of this has been re-measured on a phone.**
- The FPS overlay now shows simulation and scene-preparation time, so one screenshot from a big
  fight will show whether the phone is limited by the CPU or the GPU.

### Replayability

| Content | Count now | Comparable games |
|---|---|---|
| Weapons | 4 (and 4 slots, so every long run ends with the same four) | dozens; 40+ in Deep Rock Galactic: Survivor |
| Fusions | 6 (every possible pair) | - |
| Perks / support gems / keystones | 11 / 11 / 9 | - |
| Foe behaviours | 6, plus event foes | - |
| Run length | 2.5 minutes, then the boss | about 20 to 30 minutes on PC |

The meta layer is deep (gear, Shard Web, Torment, Prophecies, Daily Rift, bargains), but runs
themselves converge on the same build. More systems will not fix that; more weapons and a longer
run arc will.

### Audio

All sound is synthesised from sine, saw and noise layers in `sfx.gd`. There is no music, only a
filtered-noise drone.

### Process

There is no way to see the game on a real device from here. Both device bugs so far (the sound crash
and the budget-phone crash) took several round trips of screenshots to find.

## 2. What comparable games do

- **Halls of Torment** (also built in Godot) is fully 2D. Its developer says the assets are modelled
  in Blender and rendered to sprites by scripts. Authored 3D animation is pre-rendered, so it costs
  almost nothing at run time on any hardware.
- **Vertex animation textures (VAT)** are the standard way to animate thousands of 3D instances.
  Every frame of every clip is baked into a texture, and the vertex shader reads it per instance.
  The technique dates back to GPU Gems 3, and several Godot 4 plugins implement it on `MultiMesh`.
- **Mipmapped textures, not procedural noise,** are how shipped games keep ground detail stable
  under a moving camera.

## 3. The plan

Each milestone ends with a three-step critique: capture a fixed shot list at phone resolution,
critique it against the last milestone, fix. Device numbers are part of every critique.

### M0. Measure first

1. Benchmark screenshots from the S22 (main APK) and the A05 (Lite), with Show FPS on.
2. Add two automated checks to the test suite:
   - a shimmer metric: render two frames one pixel apart and compare them;
   - an animation filmstrip per character.
3. Probe the Meshy rigging endpoint on one hero (about $0.32) to verify it accepts our meshes.

### M1. Animation

- **Foes: bake the packs' own clips into vertex animation textures.** Walk, attack, hit, death and
  a spawn clip, played per instance in the foe shader. No cost; the source files are already here.
- **Heroes and humanoid bosses: a real skeleton and authored clips.** fal hosts Meshy's rigging
  endpoint. It rigs any humanoid model to a standard skeleton and applies clips from a library of
  roughly 700 presets (idle, runs, sword slashes, spell casts, roll dodges, hit reactions, deaths).
  Rigging costs $0.20 per model and $0.32 with one animation. The multi-animation endpoint returns
  up to 10 clips per call; its price is **unverified**. Whether it handles our TRELLIS meshes
  (capes, robes) is **unverified** until the M0 probe.
- **Fallback if the probe fails:** retarget a CC0 library onto our rig in Blender. The free tier of
  Quaternius's Universal Animation Library has 45 clips; the KayKit clips are already on disk.
- **In Godot:** replace the single `AnimationPlayer` with an `AnimationTree`:
  - a blend between idle, walk and run driven by speed;
  - an upper-body layer so heroes cast while moving;
  - one-shots for roll, hit and death;
  - playback rate matched to ground speed to stop foot sliding.

### M2. A smooth image

1. Replace the procedural ground with mipmapped, tiling PBR textures (CC0 sets; the fetch script
   exists), blended by a low-frequency mask. Keep noise only for broad colour variation.
2. Replace cone grass with fewer, larger alpha-tested cards that fade with distance.
3. Render at native resolution with MSAA on flagship phones; keep reduced resolution for budget.
4. Smooth-shade the foes and add a soft contact shadow under each one.

### M3. Performance

Decide from the M0 numbers:
- **CPU-bound:** move the per-foe simulation and upload loops from GDScript to a C++ extension.
- **GPU-bound on budget phones:** pre-rendered sprite impostors for distant foes, as Halls of
  Torment does for everything.

### M4. Replayable runs

- Weapons from 4 to at least 12, each with a distinct behaviour so choices exclude each other.
- A longer run arc (proposed: 8 to 10 minutes with mid-bosses), so builds have time to form.
- An unlock track: weapons and heroes earned by achievements.
- More foe behaviours (ranged lines, shielded, summoners, leapers).

### M5. Audio

Generated sound effects and layered music, using audio models on fal (ElevenLabs sound effects,
Lyria or Stable Audio for music). Prices per clip are **unverified**.

### M6. Alpha infrastructure

- A release signing key, stored as a GitHub Actions secret and backed up by the owner.
- A CI workflow that builds the APK and bundle on every push.
- Google Play Console, internal testing track: testers update through Play; the pre-launch report
  runs the build on real devices; Android vitals collects crash traces from testers.
- Personal Play accounts created after November 2023 must run a closed test with 12 testers for 14
  days before production access. That clock should start early.

## 4. Alpha exit criteria

| Area | Bar |
|---|---|
| Stability | No crash in 30-minute sessions on three device classes (budget, mid, flagship) |
| Performance | At least 55 FPS average on a flagship at 300 foes; at least 30 FPS on a budget phone at 200 |
| Animation | Every hero, boss and foe on authored clips; locomotion matched to speed |
| Image | Shimmer metric under an agreed threshold on a camera pan; no sub-pixel geometry |
| Content | At least 12 weapons; agreed run length; unlock track in place |
| Audio | No synthesised placeholder sounds left |

## 5. Access, keys and accounts

| Need | What it unlocks | Status |
|---|---|---|
| fal key | Rigging and animation (Meshy), 3D (TRELLIS), concepts (FLUX), audio | Connected; about $10 left. Estimated need for M1 + M5: $12 to $20 (**partly unverified prices**) |
| Benchmark screenshots | Real performance numbers | Needs the owner and tester; no setup |
| Screen recordings | Seeing motion on a real phone | Needs the owner; no setup |
| Google Play Console ($25 once) | Internal track, pre-launch report, crash traces | Owner must create the account |
| Firebase Test Lab (free tier: 5 physical-device runs a day) | Video and logs from real phones, run from CI | Needs a Firebase project and a service-account key added as a GitHub secret, never pasted in chat |
| GitHub Actions on the repo | CI builds and Test Lab runs | Repo is connected; secrets are added by the owner in GitHub settings |
| A computer with a GPU, connected through the Claude desktop app | Running the game on real graphics hardware during development | Optional |

No other API key is needed to start M0 and M1.

## 6. Other models and agents

- **Through fal:** Meshy (rigging, animation), TRELLIS 2 (meshes), FLUX (concepts, textures),
  ElevenLabs sound effects, Lyria or Stable Audio (music).
- **Other Claude agents:** an independent reviewer agent for the critique step would remove my bias
  toward my own work. Parallel agents could also take separate workstreams (weapons content, audio)
  while the animation work runs. Both cost extra usage and happen only on request.

## Sources

- Halls of Torment pipeline: https://steamcommunity.com/app/2218750/discussions/0/4033602028574439249/ and https://www.w4games.com/blog/w4-games-news-1/interview-with-chasing-carrots-developer-of-halls-of-torment-120
- Vertex animation textures in Godot: https://github.com/antzGames/Godot_Vertex_Animation_Textures_Plugin , https://github.com/GalamilGames/godot-vertex-animation-plugin , https://developer.nvidia.com/gpugems/GPUGems3/gpugems3_ch02.html
- Meshy rigging on fal: https://fal.ai/models/fal-ai/meshy/rigging/api , https://fal.ai/models/fal-ai/meshy/rigging/multi-animation/api , https://docs.meshy.ai/en/api/animation-library
- Quaternius Universal Animation Library: https://quaternius.com/packs/universalanimationlibrary.html , https://opengameart.org/content/universal-animation-library
- Godot anti-aliasing support by renderer: https://docs.godotengine.org/en/4.4/tutorials/3d/3d_antialiasing.html
- Firebase Test Lab quotas: https://firebase.google.com/docs/test-lab/usage-quotas-pricing
- Google Play closed-testing rule: https://dev.to/founder_can/google-play-12-testers-for-14-days-the-complete-guide-2026-18o8
- fal audio models and prices: https://fal.ai/learn/tools/best-text-to-music-apis-2026
