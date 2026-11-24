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
