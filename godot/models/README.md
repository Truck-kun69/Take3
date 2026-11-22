# Model slots

Drop authored assets here; the game picks them up automatically and falls back to its procedural
models when a slot is empty (see `scripts/render3d/models.gd`). Formats: `.glb`/`.gltf` (Godot
imports them), `.tscn`, or a mesh resource `.tres`/`.res`. World scale: heroes are modelled 38 units
tall (the rig draws them at 1.3x), bosses 88. A foe mesh is either about 2 units tall at radius 1
(the packs: scaled by the radius) or modelled at its height for the kind's base radius (the generated
ones, 24-42 units: scaled by radius / base radius). Props are modelled at their size (tree 130, arch
120, pillar 95, wall 65, rock 38, bush 26, bones 22). Models face **+X**, up is **+Y**, feet at y = 0.
Foe and prop meshes are instanced without their node transforms: write the mesh at the identity.

| Folder | File names | How it is used |
|---|---|---|
| `heroes/` | `warden`, `spark`, `ember`, `storm` | Replaces the hero rig. If the scene has an `AnimationPlayer`, clips named `idle`, `walk`, `run`, `cast`, `roll`, `jump`, `die` are played (names matched case-insensitively; a hit is a procedural flinch); facing and position are still driven by the game. |
| `bosses/` | `tyrant` (stage bosses), `guardian` (rift guardian), `herald` (pinnacle) | Replaces the boss rig. Optional clips `walk`, `attack`, `hit`, `die`. |
| `foes/` | `grunt`, `runner`, `brute`, `spitter`, `splitter`, `mini`, `charger`, `breach`, `goblin`, `exile` | The first mesh found is **instanced** for the whole swarm (one draw call). Limb animation comes from the foe shader: put leg/arm/head ids in **UV2.x** (0 body, 1/2 legs, 3/4 arms, 5 head, 6 eyes (emissive), 7 glow, 8 waving tail) and the joint height in **UV2.y**. Without UV2 the mesh simply bobs. |
| `props/` | `rock`, `tree`, `tree_dead`, `bush`, `arch`, `wall`, `crystal`, `pillar`, `bones`, `grass` | Instanced scatter props. A model with its own PBR maps draws its own materials; one without them takes the shared prop shader, where UV2.x = 7 marks emissive parts and 8 parts that sway. `props_hi/` (High tier) now holds only the crystal and the Act V set pieces. |

## Shipped models (generated)

`heroes/*.glb`, `bosses/{tyrant,herald}.glb`, `foes/{grunt,runner,brute,spitter,charger}.glb` (+ `.vat`)
and `props/{tree,tree_dead,rock,bush,arch,wall,pillar,bones}.glb` are generated through fal.ai and
finished in Blender (`docs/MODELS.md`, "Generated models"), each with its own 2048 px maps.
`bosses/guardian.gltf` is built by `tools/blender/build_models.py` from the CC0 sets in `textures/`
(1024 px, `textures/CREDITS.md`). Delete a file to fall back to the procedural model, or overwrite it
with your own using the same clip names.

Material naming the game understands:
* `glow*` materials are emissive; heroes flare them on casts, bosses pulse them and recolour them to
  the act's boss colour (one tyrant model serves all four acts).
* Every authored material gets a per-instance copy with a rim light and a red hit-flash overlay.
