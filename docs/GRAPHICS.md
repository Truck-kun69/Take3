# Graphics, audio and feel upgrade (PoE2 direction)

The first Godot build drew a flat 2D world. The HTML version you started from had a Three.js 3D
scene (tilted camera, articulated characters, instanced swarm, sun, torch, fog), so the Godot
build now has a full 3D renderer. The simulation is untouched (sim `(x, y)` becomes 3D
`(x, height, y)`), so balance, tests and the bot runs are unaffected. The classic 2D renderer is
still there under **Options > Renderer** as a fallback.

## What is on screen

| Layer | Implementation | Draw calls |
|---|---|---|
| Camera | 40° FOV perspective at a 52° pitch, leads the hero in the movement direction, pulls back 18% during boss fights, trauma shake with a little roll, portrait phones get a higher camera | - |
| Post | ACES tonemap, soft-light bloom on everything emissive, exponential fog in the stage colour, contrast/saturation grade, screen vignette; SSAO when running Forward+ | - |
| Lights | low sun with 2-split shadows; flickering torch on the hero (the PoE "light pool"); a key light on the camera side of the hero; **8 pooled omni lights** reassigned every frame to the brightest effects (novas, reactions, lightning, slams, meteors, elite deaths, rare loot, shrines, events), weighted by distance to the hero | - |
| Ground | `shaders/3d/terrain.gdshader`: world-space fbm palette per stage, rare flagstone patches with cracks, dirt hollows, pebbles, normals derived from the height field so light rakes across it, faint pulsing shard veins; optional authored texture slot | 1 |
| Props | 6 instanced kinds scattered per 640-unit chunk (trees, rocks, glowing crystals, ruined pillars, bones, grass that sways), density per stage, dithered see-through when between camera and hero | 1 per kind |
| Hero | `HeroRig`: 4 articulated heroes (pivots for hips, torso, head, arms, weapon, cape) with procedural run, cast (turns to and thrusts at the target), roll (tuck and flip), red hit tint, breathing, death | ~40 meshes |
| Foes | one baked mesh per kind, **one MultiMesh per kind**; the vertex shader swings legs and arms, bobs heads, waves tendrils, leans into the chase and squashes on hits; eyes and crystals glow; statuses glow at the rim; elites and exiles get gold/orange rims | 1 per kind |
| Bosses | `BossRig`: horned tyrant with wings, ribcage furnace and a slam wind-up; the Herald as a translucent crystal with a glowing core, orbiting shards and halo | ~30 meshes |
| Effects | projectiles with 3-ghost trails; gem crystals; death debris that tumbles, bounces and settles; sparks with gravity; spinning blades; 3D pickups (coins, orbs, items, fragments); rarity loot beams; lightning as camera-facing ribbons from the sky; one decal shader for telegraphs (circle, ring, line, cone), shockwaves, rune circles; blood, scorch and crater marks that fade over 20 s; event props (chests, pylons, shrines, merchant, altar) | ~12 + up to 110 decals |
| Overlay | damage numbers that pop and rise, PoE-style loot plates (dark plate, rarity border), elite affix tags, exile nameplate and bar, event timers | 2D |

## Asset slots ("space for the models")

Every visual and sound has a drop-in slot; empty slots use the procedural version.

* `godot/models/heroes|bosses|foes|props/` (see `godot/models/README.md` for names, scale, axes,
  and the UV2 convention that lets an authored foe mesh keep the shader's limb animation)
* `godot/audio/sfx/<name>` and `godot/audio/music/<stage>` (`godot/audio/README.md`)
* `godot/textures/terrain/<stage>.png`

## Feel (PoE2 references)

* **Turning to cast:** the hero snaps toward each spell's target for 0.35 s, then back to the movement direction.
* **Weight on crits:** a 25 ms freeze plus a crack sound and a small shake, limited to at most ~4% of play time.
* **Hits read without strobing:** foes pop with a short, curved flash and a squash-recoil. The hero gets a red tint, not white.
* **Deaths:** bodies burst into tumbling shards that bounce and settle, and leave a mark that fades.
* **Loot:** beams grow taller with rarity, and plates show the name in rarity colour. Drop chimes get brighter with rarity, and the legendary one rings like a bell with a banner.
* **Sound:** layered synthesis instead of single beeps: a low thump under each impact, a noise crack over a rumble for thunder, filtered noise for fire, glassy highs for ice. Each stage has a wind-and-drone ambience loop. Sounds fade with distance from the hero.

## How it was tuned (visual critique passes)

All passes were checked with the screenshot tour on the real Forward Mobile renderer (Vulkan via
lavapipe) and the model turntable (`tests/model_view.tscn`).

| Pass | Problem seen | Fix |
|---|---|---|
| G1 | Too bright and busy: the flagstone pattern covered every surface (the patch mask was inverted), veins glowed like neon, orange foes on orange ground, the hero ~40 px tall | Flagstones only in rare patches, dirt hollows, desaturated and darker ground, thin dim veins, darker foe bodies with glowing accents, camera 760 → 600 |
| G2 | Herald and anything in melee range flashed **pure white**, because they are hit continuously and the flash was strong and linear | Short, curved, tinted flash, much weaker on bosses |
| G3 | Turntable showed the heroes as blocky crates (huge box torso, tiny head, weapons hanging down) | Rebuilt with heroic proportions: tapered chest, rounded limbs, bigger head, upright staves, robes, hood, pauldrons |
| G4 | Metal rendered black (no sky to reflect); the Herald's core was hidden inside an opaque shell | Low metallic, translucent crystal shell |
| G5 | **No torch pool at all**, on both Mobile and Forward+ | Godot's omni falloff is `distance^-attenuation` in world units. At this scale (hero ~60 units, torch 52 units up) the usual 1.0–1.6 falloff multiplied every light by ~0.002. Fixed with a 0.5 falloff and an energy gain; the torch pool, spell lights and boss furnace lights all appear. |

## Performance notes

* CPU cost of the 3D view (all buffer uploads, rigs, effects, light assignment) measured
  0.8–1.0 ms per frame in the screenshot tour. GPU cost could not be measured here (software
  Vulkan runs at ~5 fps); it needs a real device.
* Foe buffers are written into one flat member array and sliced per kind at upload. In GDScript,
  writing into an element of an Array of PackedFloat32Arrays copies the whole array on every
  write, which would have cost ~40 MB of copying per frame.
* Low effects quality turns off sun shadows and foe shadow casting, uses 3 terrain noise octaves
  instead of 5, and lowers the caps on sparks and debris.


## PoE2 pass 2: characters, enemies and a reactive world

### Characters and enemies

* **Material shader** (`shaders/3d/char.gdshader`) for heroes, bosses and exiles. Detail is computed
  in part-local space so it stays on the part while it animates: cloth gets a weave and grime,
  leather gets mottled grain and scuffs, metal gets worn bright edges and pits, and skin gets a warm
  tint. Runes and crystals glow and flare on every cast. A dim reflection sky stops metal from
  rendering black.
* **Heroes rebuilt** with layered gear. The Warden has a gambeson under a breastplate, layered
  pauldron lames, tassets, greaves, a sallet with a plume, a rune-etched bastard sword and an oak
  heater shield painted with heraldry. Sparkcaller has a cowl, fur mantle, ice talismans and a
  pronged staff. The Emberwitch has a corset, a bent witch hat, hair, a skull talisman, an
  ember-lit hem and a gnarled staff. Stormwright has a mantle, sash, glowing arm tattoos and a
  forked rod. Knees and elbows bend.
* **Muted dyes:** each hero's colour is now a desaturated dye on the cloth, and full saturation is
  saved for runes and heraldry (PoE2 palettes).
* **Cape and robes in motion:** the cape is four chained segments on a damped spring driven by
  speed, with flutter that grows when running. Robes are front and back panels that kick and trail
  with the stride.
* **Grim foes:** a ghoul with ribs, claws and crystal growths; a feral hound; a rubble golem with
  a glowing core; a pustule-covered bloat; a crystal-swallowed husk; a crystal mite; a tusked boar;
  an abyssal tentacle mass; a sack-hauling imp.
* **Foe skin:** the foe shader adds dark, desaturated, mottled skin with veins and crevice
  darkening, plus a per-foe seed so no two look alike.
* **Corpses** fall backwards away from the hero, lie for a moment, then crumble from the edges
  with an ember burn line (PoE2 keeps corpses on the ground; here they are a timed visual so the
  simulation is unchanged).
* **Monster rarity:** magic monsters (one affix) get a blue rune ring on the ground, rare monsters
  (two or more affixes) a gold one.
* **Rogue Exiles** are drawn with the full hero rig in dark gear and turn and cast like a player.
* **The tyrant boss** is a charred demon: ashen hide with ember cracks, digitigrade legs, curved
  segmented horns, membrane wings with a glowing trailing edge, bone ribs over a pulsing furnace.

### Environment reacting to the hero and the swarm (`scripts/render3d/env_fx.gd`)

| Effect | How |
|---|---|
| Grass bends and flattens around bodies, and shockwaves roll over it | `pushers[16]` uniform (hero, a rotating sample of nearby foes, expanding nova and reaction rings) bends every swaying vertex in the prop shader |
| Low ground fog that parts | lit translucent plane with drifting noise; the same pushers clear holes, and the torch and spell lights glow inside it |
| Footsteps | dust puffs on each footfall (plus a soft step sound), a dust ring on roll, a dust cloud when a slam lands |
| Statuses in the world | burning foes trail flame sparks and smoke, chilled ones shed frost mist, poisoned ones leak green fumes, shocked ones crackle |
| Hits | fresh hits spray ichor sparks and sometimes leave a splatter mark that fades |
| Casting | every cast flashes a short light in the element's colour at the hero's hand, with sparks |
| Ambient motes | per stage: fireflies (Mossglen), rising embers (Cinder), dust (Crypt), data sparks (Neon) |
| Breakables | urns and barrels appear in clusters near the hero; any skill area, projectile or blade shatters them into shards and dust for coins, sometimes a heart, power-up or currency (simulation side in `World.shatter`, unit-tested) |
| Light | warm torch against a cool ambient (PoE2's warm/cool split); on high quality the torch casts shadows that radiate from the hero |

### Critique loops for this pass

| Loop | Seen | Fixed |
|---|---|---|
| 1 | Toy-bright, saturated hero cloth; robes like stacked lampshades; a black mask box on Sparkcaller; foes pink and plastic; the ghoul read as a pig; huge eyes; corpse dissolve glowing white with pixel noise | Muted dyes; one flared robe split into swinging panels; an open cowl; dark desaturated foe skin with stronger rim; an upright ghoul; small eyes; a broader, dimmer burn line |
| 2 | Golem faces speckled (z-fighting between overlapping boxes and the core gem); tyrant a saturated orange toy robot | Separated surfaces; tyrant rebuilt as a charred demon on the character shader |
| 3 | Tyrant wing struts like white sticks, ribs like stitches, then ribs as hoops around its belly; Warden's shield a bright yellow slab, pauldrons like round ears | Dark horn struts, bigger membranes with an ember edge, V-shaped rib bars; oak shield with steel bands and painted heraldry; flat layered lames |
| Env 1 | Hit pops still blew out to white on the darker foes; urns looked like pink balls; cool fog washed the forest ground blue-grey | Tinted, weaker hit pop; darker urns with a foot and straps; lighter, per-stage fog density |
