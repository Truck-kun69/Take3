# Shardfall: Rift Survivors — Godot 4 overhaul

The original single-file HTML game (`reference/shardfall_survivors_web.html`, ~5,900 lines of
canvas + three.js) was re-built as a Godot 4.7 project in `godot/`. The core loop is the same
(auto-firing weapons, a swarm, XP gems, level-up cards, a boss at 2:30) and the four heroes, four
weapons, four stages, elemental perks and elite affixes were carried over. Around it sit 20 new or
reworked systems, then three rounds of measured critique and fixes.

## Architecture

```
scripts/sim/      pure simulation, no nodes; runs headless at any speed
  world.gd        run state, player, weapons, damage pipeline, reactions, drops, level-ups
  swarm.gd        all foes as packed struct-of-arrays (swap-remove, uid index)
  spatial_grid.gd hashed uniform grid, linked buckets, allocation-free rebuild
  stats.gd        base / added / increased / more modifier pipeline, grouped by source
  buffs.gd        timed buffs with stacking policies, feeding Stats
  items.gd        item generation, affix tiers, crafting operations, validation
  director.gd     pacing director + event deck (the "happenings")
  bosses.gd       stage tyrants, rift guardian, rogue exiles / nemesis, pinnacle Herald
  atlas.gd        seeded node-graph map
  crowd_compute.gd GPU separation (local RenderingDevice) with CPU fallback
scripts/render/   WorldView: MultiMesh swarm + glow batches, canvas-drawn telegraphs/loot/UI-in-world
scripts/ui/       HUD, touch controls, every menu/overlay, theme kit
shaders/          swarm SDF bodies, additive glow sprites, procedural ground
tests/            unit tests, bot player, stress bench, screenshot tour
```

The simulation never touches rendering, so the same `World` is driven by a touch/keyboard/gamepad
player in the game and by `tests/bot.gd` in headless balance runs. That separation is what made the
three critique cycles measurable instead of opinion.

## The 20 enhancements

| # | Area | Enhancement | Where |
|---|---|---|---|
| 1 | Graphics | **Batched SDF swarm renderer.** Every foe is one MultiMesh instance; a canvas shader draws the body from a per-kind polar profile with fake lighting, outline, eyes, crystal facets, elite/exile/ally rim glow, hit flash, status tint and contact shadow. 700 foes = 1 draw call. | `shaders/swarm.gdshader`, `world_view.gd` |
| 2 | Graphics | **Juice layer.** Trauma-based screen shake (squared, option-scaled), hit-stop on elite kills, slow-motion on perfect dodges, full-screen flash (dampened by *Reduce flashing*), low-life pulsing vignette, roll afterimages, additive particle bursts, loot beams whose height encodes rarity, edge-of-screen compass to off-screen objectives. Damage numbers are pooled, merged per foe within 0.12 s, tiered (normal / crit / reaction / reaction label / DoT) and filtered by option. | `world_view.gd`, `hud.gd`, `world.gd::_text` |
| 3 | Graphics | **Unified telegraph system.** One `Tele` type (circle, ring, line, cone) with arm-time fill, persistent ticking zones, spinning beams, following zones, friendly/hostile flags. Every boss attack, meteor, volatile death and consecrated ground uses it, so every threat is readable. Colour-blind mode adds hatching. | `world.gd::Tele`, `_draw_tele` |
| 4 | Controls | **Floating virtual joystick** with dead zone and a 1.6 power response curve, fixed-stick option, left-handed mirroring, multi-touch buttons with charge rings; keyboard and gamepad through a runtime InputMap; Android back button and focus-loss auto-pause. | `touch_controls.gd`, `main.gd` |
| 5 | Controls | **Dodge roll with input buffer and Perfect Dodge.** 0.26 s i-frames, 0.15 s buffer so an early press still rolls, and a hit absorbed in the first 0.2 s of a roll triggers 0.35 s slow-mo and *Riposte* (guaranteed crits for 2 s). | `world.gd::_roll`, `hurt_player` |
| 6 | Controls / Options | **Targeting modes** (nearest / strongest / facing cone), a manual **hero Ultimate** charged by damage, two **flasks** charged by kills, and a full **Options** screen: sound, volume, shake, damage numbers, aim mode, joystick mode, left-handed, colour-blind palette, reduce flashing, haptics, auto-equip, loot filter, effects quality, FPS, touch-button override. | `world.gd::use_ult/use_flask/_target`, `screens.gd::show_options` |
| 7 | Powersets | **Cross-element reaction cascades** (PoE2-style). Seven reactions (Thermal Shock, Toxic Combustion, Superconduct, Overload, Hemorrhagic Arc, Septic Wound, Frostbite). Applying an element to a foe carrying a partner status queues a reaction; reactions re-apply an element to what they hit, which can trigger more. Bounded by depth cap (2), 0.7x falloff per step, a 0.45 s per-foe cooldown and a 24-per-frame budget. | `content.gd::REACTIONS`, `world.gd::apply_elements/_react` |
| 8 | Powersets | **Support-gem links.** 11 gems (Chain, Multiple Projectiles, Concentrated Effect, Increased Area, Faster Casting, Spell Echo, four Infusions, Brutality), two sockets per weapon, tag-gated (projectile / area / spell). Gems are weapon-local `Stats` layered over the global pipeline. | `content.gd::GEMS`, `stats.gd`, `world.gd::wlocal` |
| 9 | Powersets | **Keystones** offered at levels 8, 16 and 26: rule changers such as Elemental Equilibrium, Glass Cannon, Chain Reaction, Blood Magic, Iron Reflexes, Pain Attunement, Vaal Pact, Unstoppable Momentum and Avatar of Catalysis. | `content.gd::KEYSTONES`, `world.gd::make_choices` |
| 10 | Lootables | **Rarity-tiered items** in four slots, 15 affixes with item-level-gated tiers, prefix/suffix limits per rarity, implicit mods, a power score for upgrade arrows and auto-equip, loot beams, loot filter (filtered drops auto-sell). | `items.gd`, `content.gd::AFFIXES` |
| 11 | Lootables | **Component crafting**: eight shards (Change, Growth, Crown, Chaos, Star, Null, Divine, Rift Ember corruption). Every operation validates preconditions, never consumes currency on failure, and keeps items valid (property-tested over 600 items x 8 operations). | `items.gd::craft`, `screens.gd::show_stash` |
| 12 | Lootables | **Legendary powers + Cube.** Eight unique powers (The Furnace, Stormherald Coil, Rimeheart, Gorefeast, Cascade Sigil, Gremlin's Greed, Phoenix Ember, Ouroboros Treads). Dissolving a legendary in the Cube stores its power in the Codex; three are active per run regardless of gear (D3 Kanai's Cube). | `content.gd::LEGENDARIES`, `main.gd` "extract" |
| 13 | Collectibles | **Bestiary and Lore.** Kill counts per foe type unlock tiers (10 / 100 / 1000) worth +3% damage each and a lore line; 12 lore pages drop from events, shrines and bosses; each set of four grants +5% damage and +10 life permanently. | `save.gd`, `world.gd::drop_lore`, Codex screen |
| 14 | Powerups | **Pylons and shrines** (D3): Power, Conduit, Channeling, Shield and Speed pylons; Fortune, Enlightened, Frenzied and Empowered shrines, placed by the Director. | `director.gd::_place_object`, `content.gd::BUFFS` |
| 15 | Powerups | **Buff framework with stacking policies** (refresh, intensity, duration-extend, unique) and pylon diminishing returns; also drives flasks, Soul Harvest stacks, Aegis, Overclock, Vital Surge and ultimates. | `buffs.gd` |
| 16 | Optional boss | **Pinnacle: the Shard Herald.** Summoned with three fragments (Rupture from Breach splinters, Greed from gremlins, Dread from cursed chests, or any from Citadels). Arena lock, three phases at 66% / 33% with invulnerable transitions and adds, weighted no-repeat attack selection biased by range (volley, slam chain, summon, twin spinning beams, closing arena ring, shard storm), enrage at 3:00. | `bosses.gd::_herald` |
| 17 | Optional boss | **Rogue Exiles and Nemesis.** A named rival with one of your weapons' patterns and a blink-away reaction to burst damage. If an exile kills you it is saved as your Nemesis and returns next run one level stronger, guarding a guaranteed legendary. | `bosses.gd::spawn_exile/on_player_death` |
| 18 | Events | **Pacing Director + happenings deck.** Build / Peak / Relax phases driven by smoothed intensity (damage taken + swarm density); weighted deck with cooldowns, earliest times, no repeats, concurrency cap and prerequisites. Ten events: Breach, Treasure Gremlin, Cursed Chest, Strongbox, Eclipse, Starfall, Wandering Merchant (gamble), Delirium Mirror, Blood Ritual, Rogue Exile. | `director.gd` |
| 19 | Endgame | **Greater Rifts + seasonal affixes.** Keyed levels with +17% monster life per level (D3), a 5:00 timer, a progress bar fed by kills and progress orbs, a Rift Guardian at 100%, key upgrades (+1/+2/+3) by time left. A weekly rotating season affix (Souls, Echoes, Avarice, Blight, Mirrors) changes every mode. | `bosses.gd`, `world.gd`, `content.gd::SEASONS` |
| 20 | Endgame | **Atlas of Falls** (PoE2 node map): a seeded 7x5 graph with pruned-but-connected edges, map tiers by distance, rolled map modifiers that add item quantity/rarity, Corrupted nodes, four Citadels that drop pinnacle fragments; completing a node reveals its neighbours. | `atlas.gd`, `screens.gd::AtlasView` |

## Critique cycles

See the three sections below: each lists what was measured, what was wrong (engineering, player
friction, balance), and the change made for the next cycle. Measurements come from
`tests/run_tests.gd` (9 bot-played runs across all modes, plus a 680-foe stress bench) and
`tests/shots.gd` (screenshots on the real Forward Mobile renderer).

<!-- CYCLES -->
