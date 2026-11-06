# Shardfall: Rift Survivors (Godot 4)

A Godot 4.7 rebuild of the single-file web game in `reference/`, with a 20-point ARPG overhaul
(elemental reaction cascades, support gems, keystones, crafted loot, legendary powers, bestiary and
lore, pylons and shrines, an event director, greater rifts, an atlas, nemesis exiles and a pinnacle
boss), three measured critique cycles, and a PoE2-style 3D renderer with drop-in slots for
authored models, sounds and textures (`godot/models`, `godot/audio`, `godot/textures`).

* `docs/DESIGN.md` — the 20 enhancements and the three critique cycles with their numbers
* `docs/GRAPHICS.md` — the 3D renderer (PoE2 direction), models, effects, audio, asset slots
* `docs/TOOLCHAIN.md` — provisioning Godot 4 + Android SDK headlessly, compute shader, export pipeline
* `docs/screenshots/` — cycle-0 bugs and the final build on the Forward Mobile renderer

```bash
bash tools/provision.sh                 # Godot 4.7.2, Android templates, SDK, debug keystore
export PATH="$HOME/toolchains/godot:$PATH"
godot --headless --path godot res://tests/tests.tscn -- unit sim bench
bash tools/build_android.sh             # build/shardfall-debug.apk
bash tools/build_web.sh                 # build/shardfall.html: one self-contained file, double-click to play
```
