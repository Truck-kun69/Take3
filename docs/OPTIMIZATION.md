# Optimisation log (0.10.4)

Each optimisation is measured before it starts, then improved in cycles: change, measure, critique what the
numbers still show, change again. Every hot loop that changes is checked in the unit group "0.10.4
performance" against the plain definition of what it computes (or a copy of the code it replaced).

All timings are on the build machine's desktop CPU (single-threaded GDScript, Godot 4.7.2). A phone runs
the same scripts roughly 3 to 5 times slower, so 1 ms here is 3-5 ms of a phone's 16.7 ms frame.

Tools:
- `godot --headless --path godot res://tests/tests.tscn -- bench`: the simulation at a full swarm (680 foes)
  around a standing hero, per system, and the foe step's own parts. The crowd keeps moving, so totals vary
  by about 10% between runs.
- `PERF_BENCH=1 godot --headless --path godot res://tests/tests.tscn -- perf`: the same functions on a frozen
  crowd, best of several rounds: the number to compare between versions.
- `godot --headless --path godot res://tests/tests.tscn -- lodprobe`: the foe meshes' triangles and imported
  LODs (the numbers at the end of O2).
- `godot --headless --fixed-fps 60 --path godot res://tests/soak.tscn -- [runs] [seconds]`: bot-played runs
  back to back on the real game scene (O3, O6, O7). `SOAK_NODES=1` times every node's `_process`, the view's
  parts and the simulation tick's parts (`World.profile`) in each frame over `SOAK_HITCH_MS` (25);
  `SOAK_LOADS=1` marks the frames that loaded a resource (with `--verbose`, the loads print before the mark).
- `PERF_BENCH=1 godot --headless --path godot res://tests/tests.tscn -- stream`: 8 chunk crossings and the
  walk back, timed (O6).
- `godot --path godot res://tests/startup.tscn` (headless, or under `xvfb-run` with `--rendering-method mobile`
  for the shader and pipeline compiles): the engine, the main scene's load and `_ready`, and the first frames (O4).

## O1. The foe step (CPU), 680 foes

Baseline (0.10.3): 4.2-4.5 ms a tick. The foe step is 3.5 ms of it: separation 2.6 ms, movement with the
terrain 1.6 ms (0.17 ms of that is the movement itself), timers 0.13 ms.

| Cycle | Change | Measured | Critique |
|---|---|---|---|
| 1 | Separation: the grid query inlined into the loop; terrain: open-ground fast path | tick 3.9-4.2 ms; separation unchanged | The cost is the candidates tested, not the query's overhead. On a frozen crowd the inlined loop was 2% slower than the query (2.86 vs 2.79 ms): building a difference vector per candidate costs more than the engine's `distance_squared_to`. |
| 2 | Separation on its own 32-unit grid (the world's is 64) | 2.33 ms (-16%) | A foe's neighbours come from about half the area. The reach still used the old query's r x 1.6 + 24. |
| 3 | The built-in distance first, the push vector only on overlap; arrays read through locals | 2.18 ms (-22%) | The reach is still wider than any push. |
| 4 | Reach r + 18 (the largest swarm foe); bosses (radius 36 and 44) push in their own pass | 1.44 ms (-48%) | First test run: the boss pass double-counted a boss whose centre also fell in a foe's own range (78 foes differed from the all-pairs definition). Fixed: the main loop leaves big bodies to their pass. The old query could also miss a boss's push entirely; now it never does. |
| 5 | Terrain: `foe_move`'s one-step case inlined, the prop cell looked up once | 3.78 -> 2.88 us a move (-24%) | Each move still called `cell_of` and `cell_type`. |
| 6 | The cell lookup inlined (same chunk cache, same Act V tide reclassification) | 2.51-2.59 us a move (-30% overall) | Checked bit-identical on 12,000 moves through Act I's forest and Act V under a risen tide. |

Result: separation 2.6 -> 1.6 ms in the moving benchmark (1.44 ms on the frozen crowd, from 2.79), movement
with the terrain 1.6 -> 1.27 ms, the tick 4.2-4.5 -> 3.4-4.0 ms. Tests: separation against the all-pairs
definition on a packed crowd with and without bosses; `foe_move` bit-identical to 0.10.3's.

## O2. The 3D view's CPU cost per frame

`tests/render_bench.tscn` now runs headless too (`godot --headless --path godot res://tests/render_bench.tscn`):
the dummy renderer draws nothing, so what it measures is the scripts' own time, at real frame rates, in 8
seconds instead of minutes under Xvfb. It prints the view's frame by part (`RPROF`, including the effects'
parts as `fx:*`), and with `BENCH_NODES=1` the HUD, overlay, touch controls, subtitles and the audio and save
autoloads, each timed around its own `_process`.

Baseline (0.10.3, 500 foes): the view 2.9-3.6 ms a frame. Foes 1.58-1.82 ms, effects 0.54-0.78, ambient
effects 0.17-0.23, bosses 0.15-0.17, camera 0.07. Everything outside the simulation and the view (HUD, overlay,
touch, subtitles, audio, save) is under 0.05 ms each.

| Cycle | Change | Measured | Critique |
|---|---|---|---|
| 1 | The foe instance writer and its first pass read the swarm's arrays and the clocks through locals (a member read on another object is a lookup per use: about a dozen per foe), and the status code is inlined | foes 0.76-0.96 ms at 500 (-50%), 0.50-0.64 at 300 (-45%) | Bit-identical buffers to 0.10.3's writer on a real frame with a mixed crowd. The test's first version left its run's World undisposed: 28 objects leaked at exit, caught by the leak count. |

Not done, and why: the swarm foes are 1,800 triangles each (grunt, runner, brute, charger, spitter) and
cast sun shadows: about 1.8M of the 4M triangles a frame at 500 foes. Their imported LODs barely reduce
them (1,124-1,324 triangles, none for the brute and spitter: their UV seams stop the simplifier), and a
MultiMesh draws one LOD for the whole crowd. A seam-aware index-buffer simplifier (meshoptimizer) would keep
the vertex animation valid (each vertex carries its animation column in UV2.x), but installing its Python
package was refused in this session, and the GPU gain cannot be measured without a phone.

## O5. How often the exiles speak

`godot --headless --path godot res://tests/tests.tscn -- voicesim` plays a campaign act with each exile (a bot,
up to 8 minutes, Acts I to III) with the game's VoiceDirector and VoiceBank on the run's clock, and prints per
run: lines a minute by cue, the share of the time a voice is heard, the same line again within a minute, and
the longest silence. `VOICE_SIM_REPEATS=1` lists each repeat. (The Warden's bot dies in Act I at 1.8 minutes,
so his row is a short run; the other three play the full 8.)

Baseline (0.10.3: cast cooldown 7 s, kill streak 10 s, one cast in three tries a bark): 7.7-9.0 lines a minute,
a voice 41-52% of the time, 43-57 lines repeated within a minute, never more than 11-21 s of quiet. Casts were
5.6-8.0 of those a minute: each exile's three cast lines in turn.

| Cycle | Change | Measured (Sparkcaller, Emberwitch, Stormwright) | Critique |
|---|---|---|---|
| 1 | Cast cooldown 30 s, kill streak 20 s; one cast in five tries a bark; a random bark picks only among lines not said in the last 90 s | 3.2, 4.4, 3.0 a minute; 18-24% of the time; 9, 8 and 0 repeats; longest silence 28-40 s | Every remaining repeat was an escalation line, which the director asks for by number and so skipped the random pick's filter: the Sparkcaller's ricochet line 8 times (30 s apart, its cast cooldown) and the Emberwitch's frenzy 8 times (20-34 s apart). |
| 2 | The no-repeat rule covers every line of priority 0-2 asked for by number too, and an escalation line waits twice as long (180 s); cast cooldown 40 s, kill streak 30 s | 2.7, 3.1, 2.6 a minute; 16-18%; 0 repeats; longest silence 39-45 s | No repeats. Casts are still the largest share (1.4-1.5 a minute): one exile's three lines each heard about every 2 minutes, which still reads as chatter in a long run. |
| 3 | Cast cooldown 60 s | 2.4, 2.6, 2.2 a minute; 14-15%; 0 repeats; longest silence 53-62 s | Casts 1.0-1.1 a minute, below ultimates plus streaks together. The longest silence is now about a minute; longer, and the exiles would seem mute between waves, so it stops here. |

Result: 7.7-9.0 -> 2.2-2.6 lines a minute, a voice heard 41-52% -> 14-15% of the time, 43-57 -> 0 lines repeated
within a minute. Story lines (priority 3: act openings, boss lines, intros, deaths) are never held back. The
voice pack itself is unchanged (no new lines, no cost). Tests (unit group "0.10.4 voice pacing", on a stepped
clock): eight cast barks over 488 s, none repeated within 90 s; an escalation line refused as a repeat 61 s
later and allowed after 180 s; an intro said twice in a row both times.

## O3. Memory and long sessions

`tests/soak.tscn` plays runs back to back on the real game scene: every act and exile in turn, a bot playing
(level-ups, bargains, the merchant), each run ending through the end screen or Pause > Main Menu. At each
run's start (the menu, the last run's world freed) it records the engine's object, resource and node counts,
orphan nodes, static memory and the process's resident memory, and the sizes of every container in the
autoloads and the static caches. Headless, so the renderer draws nothing: no GPU memory is measured.

10 runs of 4 minutes (40 minutes of play, 324 s here):

| At run start | Run 1 | Runs 2-10 | After the last |
|---|---|---|---|
| Objects | 3,794 | 3,908-4,083 | 4,009 |
| Resources | 239 | 253-274 (each act's models load once) | 288 |
| Nodes | 726 | 714-784 | 708 |
| Orphan nodes | 0 | 0 | 0 |
| Resident memory | 278 MB | 284-298 MB | 306 MB |

Nothing grows run over run. Every cache holds a bounded set: 16 voice clips (its LRU cap), 35 sounds, 41
models (all five acts), 33 lines' repeat times (of 61), 93 first-occurrence marks. The profile's JSON grows
from 1.2 to 20.4 KB over the first five runs (unlocks, codex, stash) and then holds. Inside a run, the
containers that grow do so with the fight and empty again: surface pools (10-30 s each), frozen cells, the
terrain's prop cells (pruned around the hero), corpses.

The first soak's exit reported 5-11 leaked resources: the sounds still playing when it quit hold their streams
past the audio server's shutdown. The soak now stops its players before quitting, and reports none. The
headless renderer also prints `Parameter "material" is null` (material_get_instance_shader_parameters); the
same runs under Xvfb on the Vulkan renderer do not, so it is the dummy renderer's.

## O6. Hitches: what the first frames of new ground cost

The soak (O3) also logs every frame over 25 ms. Baseline, three runs of 100-150 s: 3-7 such frames a run, the
worst 49-153 ms (on a phone, 3-5 times that). Per node and per part (`SOAK_NODES=1`), nearly all of them are
the 3D view at a chunk crossing (every 640 units the hero walks, every few seconds): `_props` built the five
new prop cells of the 5 x 5 around the hero (12-27 ms) and `_terrain_tex` recomposed the 7 x 7 height window,
generating the seven chunks that enter it (12-15 ms). The other: 115-153 ms in main, 3-4 s into the
Emberwitch's runs: the fire bed's two loops, synthesized sample by sample on the first fire.

`-- stream` measures a crossing on its own: the hero walks east through 8 chunks of Act I, the world ticking
between crossings as walking does, and each crossing frame's parts are timed. Baseline: props 23.7-24.9 ms,
terrain textures 3.6-3.9 ms (benchmark order), worst crossing 30-36 ms.

| Cycle | Change | Measured (a crossing) | Critique |
|---|---|---|---|
| 1 | Each prop batch's MultiMesh written as one buffer (it was a call per instance) | no change: 5.6-6.0 ms a cell before and after, on the Vulkan renderer too | The calls were not the cost. Kept: one upload instead of 300 calls, the same bytes (checked on the real renderer, where MultiMesh keeps them). Timing a cell in parts found ~2 ms in `Models.prop_mesh`, which probes up to ten file paths with ResourceLoader.exists before it checks its cache, for every kind of every cell. |
| 2 | The prop and foe mesh lookups memoized per (kind, act, tier) | props 15.5-16.6 ms (a cell 4.5 -> 2.15 ms) | The benchmark ran the props before the textures; a frame runs `_camera` (the textures) first. |
| 3 | The benchmark in the frame's order | props 7.4 ms, textures 13.1 ms | The seven new chunks are generated inside the crossing frame (1.3 ms each): the world prefetches chunks one a tick, but only out to ring 3, the window's own radius. |
| 4 | Prefetch to ring 4 | textures 0.5 ms; no chunk generated in a crossing frame; worst crossing 7.9 ms | Generation moved to the walk, a chunk a tick, 2.0-2.7 ms each. `_raw` read five values of the act's profile dictionary for each of a chunk's 1,764 height samples. |
| 5 | Those read once per act | 1.36 ms a chunk (-33%); heights identical on all five acts | The five cells of a crossing still land in one frame. |
| 6 | The outer ring of cells queued, one built a frame, nearest first; the hero's chunk and its ring at once (a run's start, a teleport) | crossing frame 0.5-1.1 ms; the worst frame after it 1.7-4.7 ms (one cell) | A cell is still ~2 ms: the layout 0.8, the transforms 1.2. |
| 7 | Upright props written straight into the buffers, no Basis or Transform3D | no gain; reverted | The per-prop cost is GDScript's own (array reads, the height lookup), not the basis math. The first version also wrote through a copy of each batch's buffer per prop (copy-on-write). |
| 8 | Built cells' batches cached (81 cells, ~1.3 MB): a run circles over the same chunks | walking back over 4 crossings: the worst frame 1.5 ms | That frame is the texture window's recompose (0.4 ms) and any cell the cache no longer held. |
| 9 | The fire loops baked to Ogg (`tools/bake_loops.sh`, the game's own synthesizer and seeds, 93 KB) | 127 ms of synthesis -> 0.4-0.9 ms to load | |

Result, the same three soak runs: no frame over 25 ms (3-7 a run before); the worst frame 10.6-16.6 ms (49-153
ms before); a crossing frame 0.5-1.1 ms (30-36 ms). Tests (unit group "0.10.4 streaming"): 25 cells around the
hero after the crossings and the queue; a teleport builds the 3 x 3 at once and queues 16; the cells' buffers
equal 0.10.3's per-instance transforms exactly; a cached cell equals a fresh build; chunk heights equal 0.10.3's
on all five acts; the fire loops are the baked files, looping.

## O4. Startup and the APK

**What a launch spends**, `tests/startup.tscn`. Headless (scripts and loading only): the engine and its four
autoloads 400-490 ms, loading `main.tscn` 400-490 ms (compiling `main.gd` and the 18,000 lines of script it
reaches; the APK ships them as binary tokens, which skips only the tokenizer), `main._ready` 170-220 ms (the
title's 3D stage 85-92 ms, its exile 25 ms, the menu 62 ms), the first frame at 1.0-1.2 s. On the Vulkan
renderer (Mobile, Mesa's software driver under Xvfb), the shaders dominate:

| Caches on disk | The title's first frame | The frame after it |
|---|---|---|
| None (a fresh install or an update) | 5.8 s | 5.9 s |
| Compiled shaders (SPIR-V), no driver pipelines | 3.9 s | 8.1 s |
| Both | 3.8 s | 7.1 s |

Godot compiles every shader from source on a launch with an empty cache: here that is the 2 s between the first
two rows (on a phone, several seconds more). The second frame is the driver building its pipelines, which no
cache here removes (the software driver is slow at it; a phone's driver is faster).

| Cycle | Change | Measured | Critique |
|---|---|---|---|
| 1 | A `startup:` line in Copy report and the trail: when the engine reached the first autoload, when main was ready, when its first three frames were drawn (`Diag.startup`) | in the test runner: the engine up at 2.00 s, main ready at 3.46 s, the first frames at 11.43 s | No phone can be measured from here; testers' reports now carry the real numbers. |
| 2 | The shader baker (Godot 4.5+, `shader_baker/enabled`): the export compiles the shaders into the APK, so a fresh install skips that step | 50 shaders baked, +2.44 MB in the APK; the step the second row of the table above skips | It cannot run in a `--headless` export (no GPU), which still works and simply bakes nothing. `tools/build_android.sh` now exports under Xvfb on Vulkan when it can; CI installs Mesa's Vulkan driver for it (its render smoke had been falling back to OpenGL) and the gate fails a Vulkan-capable build that baked nothing. Pipelines are still built on the phone. |

Not done, and why:
- Scripts compiled later (main.gd's typed references to the run's classes made lazy): it would only move the
  ~0.4 s to a run's start, at the cost of main.gd's static typing.
- The title stage's four props load their PBR textures though the stage draws them with its own material: the
  first run uses the same cached meshes and textures, so this is a prefetch, not waste.
- The APK (138 MB) is 94 MB of textures, which 0.9.8 settled on keeping at their full 1,024-2,048 px. Nothing
  shipped is unused: the files the unit suite never loads are each reached by a path built at run time (Acts
  IV-V's terrain and props, the guardian's textures, the Emberwitch and the Herald).

## O7. The next tier of spikes: frames over 8 ms here (25-40 ms on a phone)

With O6's hitches gone, the soak's line moved to 8 ms (`SOAK_HITCH_MS=8`) and the simulation's tick got a
per-part profile of its own (`World.profile`: one branch a part when off; the director split in four inside
it). Four runs of 150 s: 75-84 frames over 8 ms, worst 25-34 ms. Where they come from:

| Frames | What | Here | Kept as it is? |
|---|---|---|---|
| 40-46 | A modal screen built inside the tick: the level-up cards (5-7 ms, a card ~1 ms) and the Whisperer's bargain (the director's 6-7 ms, at the touch) | 5-11 ms | Yes: the game stops for the choice there, and a cheaper build means rebuilding how every screen is made. |
| 12-18 | Engine work and the soak's own (its bot, its picks) | 8-17 ms | Not the game's. |
| 2 | A rival exile's or a boss's model loaded in the frame it appears (the view's `bosses` part) | 22.5-24.7 ms | No (cycle 2). |
| 2 | The effects' lightning-decals-props part | 4.7-16.8 ms | Cycle 1 ruled out the lightning. |
| the rest | Heavy ticks of the foe step, terrain, the hero's ultimate | 8-16 ms | Bursts of play. |

| Cycle | Change | Measured | Critique |
|---|---|---|---|
| 1 | The lightning ribbons built in packed arrays and handed to an ArrayMesh in one call (it was ~13 ImmediateMesh calls a segment) | 114 strikes: 1.46-1.72 ms, against 1.24-1.45 ms through ImmediateMesh | Slower: those calls cost ~0.07 us each, less than the arrays' allocations. Reverted. And 114 strikes are 1.3 ms, so the 16.8 ms spike was not the lightning: the part is now three (`lightning`, `decals`, `event_props`). Event props were ruled out too (0.1-0.9 ms each to build). |
| 2 | The models a run will need later loaded on a loader thread ahead of time (`WorldView3D.ahead`): the act's tyrant 45 s before it comes at 8:00, the rift's guardian and the pinnacle's Herald from the start, a nemesis's hero model from the start (it comes after 45 s); each held until the next run, collected if the view leaves while one still loads | the tyrant's model loads in 3 frames on the thread; a rig built from it 0.9-1.0 ms, against 15-24 ms loading it in the frame | A random rogue exile's model (one of three) is chosen by the run's dice as it spawns, so it still loads then: loading all three ahead would hold ~30 MB of textures for an event a run meets once at most, and choosing earlier would change the run's dice (the Daily Rift's codes). The first test run leaked a load token: a test freed the view while the tyrant's load was still running; `_exit_tree` now collects it. |

Tests (unit group "0.10.4 streaming"): the tyrant is not loaded at a run's start and is loaded on a thread 45 s
before it comes; a new run lets the old run's models go; a pinnacle run loads the Herald from its start.
