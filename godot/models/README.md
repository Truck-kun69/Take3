# Model slots

Drop authored assets here; the game picks them up automatically and falls back to its procedural
models when a slot is empty (see `scripts/render3d/models.gd`). Formats: `.glb`/`.gltf` (Godot
imports them), `.tscn`, or a mesh resource `.tres`/`.res`. World scale: the hero is about 60 units
tall, a basic foe about 22 units, at radius 1 a foe mesh should be about 2 units tall.
Models face **+X**, up is **+Y**, feet at y = 0.

| Folder | File names | How it is used |
|---|---|---|
| `heroes/` | `warden`, `spark`, `ember`, `storm` | Replaces the hero rig. If the scene has an `AnimationPlayer`, clips named `idle`, `run`, `cast`, `roll`, `hit`, `die` are played; facing and position are still driven by the game. |
| `bosses/` | `tyrant` (stage bosses), `guardian` (rift guardian), `herald` (pinnacle) | Replaces the boss rig. Optional clips `walk`, `attack`, `hit`, `die`. |
| `foes/` | `grunt`, `runner`, `brute`, `spitter`, `splitter`, `mini`, `charger`, `breach`, `goblin`, `exile` | The first mesh found is **instanced** for the whole swarm (one draw call). Limb animation comes from the foe shader: put leg/arm/head ids in **UV2.x** (0 body, 1/2 legs, 3/4 arms, 5 head, 6 eyes (emissive), 7 glow, 8 waving tail) and the joint height in **UV2.y**. Without UV2 the mesh simply bobs. |
| `props/` | `rock`, `tree`, `crystal`, `pillar`, `bones`, `grass` | Instanced scatter props. UV2.x = 7 marks emissive parts, 8 marks parts that sway. |
