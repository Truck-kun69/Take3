class_name Content
extends RefCounted
## Static game data. Everything here is plain dictionaries/arrays so systems stay data-driven:
## adding an affix, reaction, gem, event or map mod is a table edit, not a code change.

# ---------------------------------------------------------------- elements & statuses
enum El { PHYS, FIRE, COLD, LIGHT, CHAOS }
const EL_NAME := ["Physical", "Fire", "Cold", "Lightning", "Chaos"]
const EL_STATUS := ["Bleed", "Burn", "Chill", "Shock", "Poison"]
const EL_COL := ["ff4a5e", "ff8a3c", "7fe6ff", "e6d24a", "7dff6b"]
# Colour-blind safe alternates (Okabe-Ito); the renderer also adds per-element mote shapes.
const EL_COL_CB := ["d55e00", "e69f00", "56b4e9", "f0e442", "009e73"]

# ---------------------------------------------------------------- heroes / weapons
const HEROES := [
	{"id": "warden", "name": "Warden", "blurb": "Orbiting blades. Bleeds.", "weapon": "orbit", "hp": 130.0, "spd": 150.0, "col": "f0b94d", "elem": El.PHYS,
		"ult": "Blade Cyclone", "ult_d": "Blades double in reach and triple in damage for 6s."},
	{"id": "spark", "name": "Sparkcaller", "blurb": "Rime bolts. Chills.", "weapon": "bolt", "hp": 105.0, "spd": 162.0, "col": "5ad6ff", "elem": El.COLD,
		"ult": "Absolute Zero", "ult_d": "Freezes everything on screen for 2.5s and deals cold damage."},
	{"id": "ember", "name": "Emberwitch", "blurb": "Shock pulses. Burns.", "weapon": "nova", "hp": 95.0, "spd": 155.0, "col": "ff7b50", "elem": El.FIRE,
		"ult": "Cataclysm", "ult_d": "A screen-wide fire wave that leaves burning ground."},
	{"id": "storm", "name": "Stormwright", "blurb": "Skyfall strikes. Shocks.", "weapon": "storm", "hp": 100.0, "spd": 155.0, "col": "b890ff", "elem": El.LIGHT,
		"ult": "Thunderdome", "ult_d": "Ten lightning strikes per second for 4s."},
]

# Weapon tags gate which support gems can link. lv = per-level base stats (index 0 = level 1).
const WEAPONS := {
	"bolt": {"name": "Rime Bolt", "col": "5ad6ff", "elem": El.COLD, "tags": ["projectile", "spell"], "pair": "haste",
		"evo": "Glacial Volley", "evo_d": "Six piercing bolts in a fan.",
		"lv": [{"cd": 0.9, "n": 1, "dmg": 9.0, "pierce": 0}, {"cd": 0.8, "n": 2, "dmg": 9.0, "pierce": 0}, {"cd": 0.8, "n": 2, "dmg": 11.0, "pierce": 1},
			{"cd": 0.7, "n": 3, "dmg": 12.0, "pierce": 1}, {"cd": 0.6, "n": 4, "dmg": 15.0, "pierce": 2}],
		"evo_s": {"cd": 0.5, "n": 6, "dmg": 16.0, "pierce": 3},
		"d": ["Fires a bolt at a foe.", "Fires 2 bolts.", "Bolts pierce a foe.", "3 bolts, faster.", "4 bolts that pierce twice."]},
	"orbit": {"name": "Spin Blades", "col": "f0b94d", "elem": El.PHYS, "tags": ["melee", "area"], "pair": "might",
		"evo": "Razor Halo", "evo_d": "Nine huge blades, double damage.",
		"lv": [{"n": 3, "rad": 56.0, "spd": 2.6, "dmg": 8.0}, {"n": 3, "rad": 66.0, "spd": 2.8, "dmg": 10.0}, {"n": 4, "rad": 66.0, "spd": 3.0, "dmg": 11.0},
			{"n": 5, "rad": 72.0, "spd": 3.2, "dmg": 12.0}, {"n": 7, "rad": 80.0, "spd": 3.6, "dmg": 14.0}],
		"evo_s": {"n": 9, "rad": 92.0, "spd": 4.0, "dmg": 22.0},
		"d": ["Three blades circle you.", "Wider orbit, more damage.", "Four blades.", "Five blades, faster.", "Seven blades."]},
	"nova": {"name": "Shock Pulse", "col": "ff7b50", "elem": El.FIRE, "tags": ["area", "spell"], "pair": "vigor",
		"evo": "Cataclysm Ring", "evo_d": "A vast rapid shockwave with heavy knockback.",
		"lv": [{"cd": 2.8, "rad": 85.0, "dmg": 10.0}, {"cd": 2.5, "rad": 100.0, "dmg": 12.0}, {"cd": 2.5, "rad": 100.0, "dmg": 16.0},
			{"cd": 2.2, "rad": 125.0, "dmg": 18.0}, {"cd": 1.5, "rad": 150.0, "dmg": 24.0}],
		"evo_s": {"cd": 1.1, "rad": 200.0, "dmg": 42.0},
		"d": ["A shockwave bursts around you.", "Larger, quicker pulses.", "More damage.", "Larger again.", "Huge, very fast pulses."]},
	"storm": {"name": "Skyfall", "col": "b890ff", "elem": El.LIGHT, "tags": ["area", "spell", "strike"], "pair": "boots",
		"evo": "Thunderfall", "evo_d": "Eight heavy strikes every 0.7s.",
		"lv": [{"cd": 1.7, "n": 1, "rad": 34.0, "dmg": 20.0}, {"cd": 1.6, "n": 2, "rad": 34.0, "dmg": 22.0}, {"cd": 1.6, "n": 2, "rad": 48.0, "dmg": 26.0},
			{"cd": 1.4, "n": 3, "rad": 48.0, "dmg": 28.0}, {"cd": 1.0, "n": 5, "rad": 52.0, "dmg": 34.0}],
		"evo_s": {"cd": 0.7, "n": 8, "rad": 64.0, "dmg": 50.0},
		"d": ["Lightning strikes a foe.", "Two strikes.", "Wider blasts.", "Three strikes.", "Five strikes, faster."]},
}
const WEAPON_IDS := ["bolt", "orbit", "nova", "storm"]

# Passive perks: [stat, kind, value per level]. kind: add | inc | more
const PERKS := {
	"might": {"name": "Sharpened Edge", "d": "+15% increased damage.", "mods": [["damage", "inc", 0.15]]},
	"haste": {"name": "Quickened Pulse", "d": "8% faster weapon cooldowns.", "mods": [["cooldown", "inc", -0.08]]},
	"vigor": {"name": "Stout Heart", "d": "+20 max life.", "mods": [["max_hp", "add", 20.0]]},
	"boots": {"name": "Light Steps", "d": "+8% movement speed.", "mods": [["move_speed", "inc", 0.08]]},
	"magnet": {"name": "Gem Pull", "d": "+35% pickup radius.", "mods": [["pickup", "inc", 0.35]]},
	"regen": {"name": "Mending", "d": "+0.6 life regenerated per second.", "mods": [["regen", "add", 0.6]]},
	"venom": {"name": "Venom Coating", "d": "Hits also poison (chaos).", "mods": [["apply_chaos", "add", 1.0], ["dot_damage", "inc", 0.05]]},
	"searing": {"name": "Searing Rounds", "d": "Hits also burn (fire).", "mods": [["apply_fire", "add", 1.0], ["dot_damage", "inc", 0.05]]},
	"serrated": {"name": "Serrated Edge", "d": "Hits also bleed (physical).", "mods": [["apply_phys", "add", 1.0], ["dot_damage", "inc", 0.05]]},
	"cryo": {"name": "Cryo Core", "d": "Hits also chill (cold).", "mods": [["apply_cold", "add", 1.0], ["reaction_damage", "inc", 0.08]]},
	"static": {"name": "Static Field", "d": "Hits also shock (lightning).", "mods": [["apply_light", "add", 1.0], ["reaction_damage", "inc", 0.08]]},
}
const PERK_IDS := ["might", "haste", "vigor", "boots", "magnet", "regen", "venom", "searing", "serrated", "cryo", "static"]

# ---------------------------------------------------------------- support gems (PoE-style links)
const GEMS := {
	"chain": {"name": "Chain", "req": "projectile", "d": "Bolts chain to 2 more foes. 10% less damage.", "mods": [["chain", "add", 2.0], ["damage", "more", 0.9]]},
	"gmp": {"name": "Multiple Projectiles", "req": "projectile", "d": "+2 projectiles. 26% less damage.", "mods": [["proj_count", "add", 2.0], ["damage", "more", 0.74]]},
	"conc": {"name": "Concentrated Effect", "req": "area", "d": "35% more damage, 25% less area.", "mods": [["area", "more", 0.75], ["damage", "more", 1.35]]},
	"aoe": {"name": "Increased Area", "req": "area", "d": "40% increased area.", "mods": [["area", "inc", 0.4]]},
	"fast": {"name": "Faster Casting", "req": "", "d": "25% less cooldown, 10% less damage.", "mods": [["cooldown", "more", 0.75], ["damage", "more", 0.9]]},
	"echo": {"name": "Spell Echo", "req": "spell", "d": "Repeats once at 70% damage.", "mods": [["echo", "add", 1.0], ["damage", "more", 0.85]]},
	"inf_fire": {"name": "Fire Infusion", "req": "", "d": "Hits also ignite. +10% fire damage.", "mods": [["apply_fire", "add", 1.0], ["damage", "inc", 0.1]]},
	"inf_cold": {"name": "Cold Infusion", "req": "", "d": "Hits also chill. +10% cold damage.", "mods": [["apply_cold", "add", 1.0], ["damage", "inc", 0.1]]},
	"inf_light": {"name": "Lightning Infusion", "req": "", "d": "Hits also shock. +10% lightning damage.", "mods": [["apply_light", "add", 1.0], ["damage", "inc", 0.1]]},
	"inf_chaos": {"name": "Chaos Infusion", "req": "", "d": "Hits also poison.", "mods": [["apply_chaos", "add", 1.0], ["dot_damage", "inc", 0.1]]},
	"brutal": {"name": "Brutality", "req": "", "d": "30% more damage, but no elemental application.", "mods": [["damage", "more", 1.3], ["no_status", "add", 1.0]]},
}
const GEM_IDS := ["chain", "gmp", "conc", "aoe", "fast", "echo", "inf_fire", "inf_cold", "inf_light", "inf_chaos", "brutal"]
const SOCKETS := 2

# ---------------------------------------------------------------- elemental reactions
# Applying element `a` to a foe carrying status `b` (or vice-versa) triggers the reaction.
# spread: element re-applied to everything caught, which is what lets reactions cascade.
const REACTIONS := [
	{"id": "thermal", "a": El.FIRE, "b": El.COLD, "name": "Thermal Shock", "r": 70.0, "dmg": 26.0, "spread": El.FIRE, "col": "ffd0a0"},
	{"id": "combust", "a": El.FIRE, "b": El.CHAOS, "name": "Toxic Combustion", "r": 80.0, "dmg": 22.0, "spread": El.CHAOS, "col": "b6ff4a"},
	{"id": "supercon", "a": El.LIGHT, "b": El.COLD, "name": "Superconduct", "r": 64.0, "dmg": 14.0, "spread": El.COLD, "col": "a8f0ff", "debuff": 4.0},
	{"id": "overload", "a": El.LIGHT, "b": El.FIRE, "name": "Overload", "r": 90.0, "dmg": 30.0, "spread": El.LIGHT, "col": "fff07a", "kb": 380.0},
	{"id": "hemoarc", "a": El.LIGHT, "b": El.PHYS, "name": "Hemorrhagic Arc", "r": 160.0, "dmg": 8.0, "spread": El.PHYS, "col": "ff5a7a", "arc": 3},
	{"id": "septic", "a": El.CHAOS, "b": El.PHYS, "name": "Septic Wound", "r": 0.0, "dmg": 0.0, "spread": -1, "col": "9aff6a", "payout": 0.6},
	{"id": "frostbite", "a": El.COLD, "b": El.PHYS, "name": "Frostbite", "r": 0.0, "dmg": 18.0, "spread": -1, "col": "d8fbff", "freeze": 1.2},
]
const REACT_DEPTH := 2          # cascade depth cap (Chain Reaction keystone raises it)
const REACT_FALLOFF := 0.7      # damage multiplier per cascade step
const REACT_BUDGET := 24        # reactions resolved per frame; the rest are dropped (perf + readability)

# ---------------------------------------------------------------- keystones (rule changers, PoE passive-tree style)
const KEYSTONES := {
	"equilibrium": {"name": "Elemental Equilibrium", "d": "Hitting a foe with an element makes it take 40% more damage from the other elements for 3s."},
	"glass": {"name": "Glass Cannon", "d": "60% more damage. 40% less maximum life.", "mods": [["damage", "more", 1.6], ["max_hp", "more", 0.6]]},
	"chainreact": {"name": "Chain Reaction", "d": "Reactions cascade 2 steps deeper but deal 20% less damage.", "mods": [["react_depth", "add", 2.0], ["reaction_damage", "more", 0.8]]},
	"bloodmagic": {"name": "Blood Magic", "d": "Your Ultimate costs 30% life instead of charge. No flask healing.", "mods": [["flask_heal", "more", 0.0]]},
	"ironreflex": {"name": "Iron Reflexes", "d": "You cannot dodge roll. +150 armour and 25% more life.", "mods": [["armor", "add", 150.0], ["max_hp", "more", 1.25], ["no_roll", "add", 1.0]]},
	"pain": {"name": "Pain Attunement", "d": "50% more damage while below half life.", "mods": []},
	"vaal": {"name": "Vaal Pact", "d": "Hits leech 2% of damage as life. No life regeneration.", "mods": [["leech", "add", 0.02], ["regen", "more", 0.0]]},
	"momentum": {"name": "Unstoppable Momentum", "d": "Each second spent moving grants 4% more damage (max 40%). Standing still resets it.", "mods": []},
	"avatar": {"name": "Avatar of Catalysis", "d": "Every hit applies a random element. 15% less damage.", "mods": [["apply_random", "add", 1.0], ["damage", "more", 0.85]]},
}
const KEYSTONE_IDS := ["equilibrium", "glass", "chainreact", "bloodmagic", "ironreflex", "pain", "vaal", "momentum", "avatar"]
const KEYSTONE_LEVELS := [8, 16, 26]

# ---------------------------------------------------------------- enemies
const ENEMIES := [
	{"id": "grunt", "name": "Shardling", "hp": 12.0, "spd": 60.0, "r": 11.0, "dmg": 6.0, "xp": 1.0, "lore": "Splinters of the fallen star given hunger."},
	{"id": "runner", "name": "Skitterer", "hp": 7.0, "spd": 112.0, "r": 8.0, "dmg": 4.0, "xp": 1.0, "lore": "They run before they know what they chase."},
	{"id": "brute", "name": "Shardhulk", "hp": 70.0, "spd": 40.0, "r": 18.0, "dmg": 12.0, "xp": 5.0, "lore": "Crystal grown around a stubborn heart."},
	{"id": "spitter", "name": "Glassmaw", "hp": 16.0, "spd": 52.0, "r": 10.0, "dmg": 6.0, "xp": 2.0, "lore": "It spits what it cannot digest: you."},
	{"id": "splitter", "name": "Fractal", "hp": 30.0, "spd": 50.0, "r": 14.0, "dmg": 8.0, "xp": 3.0, "lore": "Break it and you have three problems."},
	{"id": "mini", "name": "Fractal Shard", "hp": 6.0, "spd": 80.0, "r": 7.0, "dmg": 4.0, "xp": 0.5, "lore": "The three problems."},
	{"id": "charger", "name": "Ramshard", "hp": 22.0, "spd": 70.0, "r": 12.0, "dmg": 10.0, "xp": 3.0, "lore": "Aims once. Commits fully."},
	{"id": "breach", "name": "Breachspawn", "hp": 18.0, "spd": 95.0, "r": 10.0, "dmg": 7.0, "xp": 1.5, "lore": "Hands of something on the other side of the rupture."},
	{"id": "goblin", "name": "Treasure Gremlin", "hp": 260.0, "spd": 135.0, "r": 13.0, "dmg": 0.0, "xp": 10.0, "lore": "Steals from the dead. Runs from the living."},
	{"id": "exile", "name": "Rogue Exile", "hp": 900.0, "spd": 92.0, "r": 16.0, "dmg": 14.0, "xp": 60.0, "lore": "Another survivor. Worse at sharing."},
	{"id": "boss", "name": "Stage Tyrant", "hp": 1400.0, "spd": 46.0, "r": 36.0, "dmg": 16.0, "xp": 0.0, "lore": "Each world crowns the hungriest thing in it."},
	{"id": "herald", "name": "The Shard Herald", "hp": 9000.0, "spd": 70.0, "r": 44.0, "dmg": 20.0, "xp": 0.0, "lore": "It announced the shardfall. It intends to announce the next one."},
]
enum E { GRUNT, RUNNER, BRUTE, SPITTER, SPLITTER, MINI, CHARGER, BREACH, GOBLIN, EXILE, BOSS, HERALD }
const BESTIARY_TIERS := [10, 100, 1000]      # each tier: +3% damage against that foe, and a lore line

# Elite affixes (bitmask)
enum Aff { HASTED = 1, SHIELDED = 2, VOLATILE = 4, VAMPIRIC = 8, ARCANE = 16, MIRRORED = 32 }
const AFFIX_NAMES := {1: "Hasted", 2: "Shielded", 4: "Volatile", 8: "Vampiric", 16: "Arcane", 32: "Mirrored"}

# ---------------------------------------------------------------- stages
const STAGES := [
	{"name": "Mossglen Hollow", "blurb": "Roots, wisps and an angry stump.", "boss": "Elder Thornback", "boss_col": "9be04e",
		"g0": "10241b", "g1": "1a4a2c", "g2": "2c7a43", "acc": "9ad06a", "hp": 1.0, "dmg": 1.0, "spd": 1.0, "gold": 1.0},
	{"name": "Cinder Wastes", "blurb": "Ash, embers and slag.", "boss": "Cindermaw", "boss_col": "ff6a2a",
		"g0": "2a1210", "g1": "4a2019", "g2": "6a2a18", "acc": "ff9a3c", "hp": 1.5, "dmg": 1.2, "spd": 1.05, "gold": 1.3},
	{"name": "Gravebound Crypt", "blurb": "Bones that refuse to stay down.", "boss": "The Pale Regent", "boss_col": "e6e0ff",
		"g0": "15131f", "g1": "2c2942", "g2": "3a3658", "acc": "cfc9ee", "hp": 2.2, "dmg": 1.4, "spd": 1.1, "gold": 1.7},
	{"name": "Neon Rift", "blurb": "A torn seam in the grid.", "boss": "Overclock Prime", "boss_col": "ff4fd8",
		"g0": "081426", "g1": "12365c", "g2": "164070", "acc": "25e0ff", "hp": 3.0, "dmg": 1.7, "spd": 1.15, "gold": 2.2},
	{"name": "Drowned Cathedral", "blurb": "The tide is rising, and the bells still ring.", "boss": "The Tide Bishop", "boss_col": "7fe0c0",
		"g0": "10171a", "g1": "26353a", "g2": "3d5052", "acc": "f2c66d", "hp": 4.0, "dmg": 2.0, "spd": 1.2, "gold": 2.8},
]
## Terrain per stage (scripts/sim/terrain.gd). Heights in world units (a hero is ~50 tall).
##   amp: hill height; scale: hill wavelength; terraces: plateau steps (0 = rolling); cliff: max walkable
##   rise per cell; liquid: water | lava | void | none, its surface `level`; river: width of carved channels.
const TERRAIN := [
	{"amp": 85.0, "scale": 1200.0, "terraces": 0, "cliff": 0.9, "liquid": "water", "level": -46.0, "deep": 20.0,
		"river": 0.07, "river_scale": 1700.0, "river_depth": 24.0, "detail": 5.0, "shore": 20.0},     # Mossglen: rolling hills, lakes, streams
	{"amp": 110.0, "scale": 1000.0, "terraces": 5, "cliff": 1.2, "liquid": "lava", "level": -62.0, "deep": 8.0,
		"river": 0.04, "river_scale": 1400.0, "river_depth": 20.0, "detail": 4.0, "shore": 26.0},     # Cinder: terraces and lava rivers
	{"amp": 90.0, "scale": 800.0, "terraces": 3, "cliff": 0.75, "liquid": "water", "level": -38.0, "deep": 9.0,
		"river": 0.0, "detail": 2.5, "shore": 20.0},                                                     # Crypt: sunken pits, ledges, black pools
	{"amp": 120.0, "scale": 1300.0, "terraces": 4, "cliff": 1.05, "liquid": "void", "level": -78.0, "deep": 999.0,
		"river": 0.03, "river_scale": 1600.0, "river_depth": 40.0, "detail": 3.0, "shore": 30.0},    # Neon Rift: plateaus over void chasms
	{"amp": 40.0, "scale": 700.0, "terraces": 3, "cliff": 1.3, "liquid": "water", "level": -8.0, "deep": 22.0,
		"river": 0.09, "river_scale": 1100.0, "river_depth": 34.0, "detail": 2.0, "shore": 16.0, "tide": 16.0},   # Drowned Cathedral: flooded nave, deep aisles, rising tide
]

const STAGE_TIME := 150.0

# ---------------------------------------------------------------- items
const SLOTS := ["relic", "amulet", "ring", "boots"]
const SLOT_NAME := {"relic": "Relic", "amulet": "Amulet", "ring": "Ring", "boots": "Boots"}
enum Rarity { NORMAL, MAGIC, RARE, LEGENDARY }
const RARITY_NAME := ["Normal", "Magic", "Rare", "Legendary"]
const RARITY_COL := ["d8d8d8", "6f9bff", "ffd84a", "ff8a2b"]
const MAX_PREFIX := {0: 0, 1: 1, 2: 3, 3: 3}
const MAX_SUFFIX := {0: 0, 1: 1, 2: 3, 3: 3}
const BASES := {
	"relic": [{"name": "Shard Idol", "imp": ["damage", "inc", 0.08]}, {"name": "Prism Fetish", "imp": ["reaction_damage", "inc", 0.15]}],
	"amulet": [{"name": "Jade Amulet", "imp": ["max_hp", "add", 15.0]}, {"name": "Onyx Amulet", "imp": ["crit_chance", "add", 0.03]}],
	"ring": [{"name": "Iron Ring", "imp": ["armor", "add", 12.0]}, {"name": "Coral Ring", "imp": ["regen", "add", 0.4]}],
	"boots": [{"name": "Leather Boots", "imp": ["move_speed", "inc", 0.05]}, {"name": "Rift Treads", "imp": ["dodge_cd", "inc", -0.1]}],
}
# tiers: [min_item_level, lo, hi] -- higher tiers need higher item level, like PoE.
const AFFIXES := {
	"dmg": {"type": "prefix", "stat": "damage", "kind": "inc", "slots": ["relic", "amulet", "ring"], "fmt": "+%d%% increased Damage", "pct": true,
		"tiers": [[1, 0.06, 0.10], [8, 0.11, 0.16], [18, 0.17, 0.24], [30, 0.25, 0.34]]},
	"life": {"type": "prefix", "stat": "max_hp", "kind": "add", "slots": ["amulet", "ring", "boots", "relic"], "fmt": "+%d to maximum Life", "pct": false,
		"tiers": [[1, 8.0, 14.0], [8, 15.0, 24.0], [18, 25.0, 38.0], [30, 39.0, 55.0]]},
	"armor": {"type": "prefix", "stat": "armor", "kind": "add", "slots": ["ring", "boots", "amulet"], "fmt": "+%d to Armour", "pct": false,
		"tiers": [[1, 8.0, 15.0], [10, 16.0, 30.0], [22, 31.0, 50.0]]},
	"dot": {"type": "prefix", "stat": "dot_damage", "kind": "inc", "slots": ["relic", "amulet"], "fmt": "+%d%% increased Damage over Time", "pct": true,
		"tiers": [[1, 0.10, 0.18], [12, 0.19, 0.30], [25, 0.31, 0.45]]},
	"react": {"type": "prefix", "stat": "reaction_damage", "kind": "inc", "slots": ["relic", "amulet", "ring"], "fmt": "+%d%% increased Reaction Damage", "pct": true,
		"tiers": [[1, 0.12, 0.20], [12, 0.21, 0.35], [25, 0.36, 0.55]]},
	"proj": {"type": "prefix", "stat": "proj_count", "kind": "add", "slots": ["relic"], "fmt": "+%d Projectiles", "pct": false,
		"tiers": [[15, 1.0, 1.0], [32, 2.0, 2.0]]},
	"cdr": {"type": "suffix", "stat": "cooldown", "kind": "inc", "slots": ["relic", "amulet", "ring"], "fmt": "%d%% faster Cooldowns", "pct": true, "neg": true,
		"tiers": [[1, -0.04, -0.07], [10, -0.08, -0.11], [22, -0.12, -0.15]]},
	"crit": {"type": "suffix", "stat": "crit_chance", "kind": "add", "slots": ["relic", "amulet", "ring"], "fmt": "+%d%% Critical Strike Chance", "pct": true,
		"tiers": [[1, 0.02, 0.03], [10, 0.04, 0.05], [22, 0.06, 0.08]]},
	"critm": {"type": "suffix", "stat": "crit_mult", "kind": "add", "slots": ["relic", "amulet"], "fmt": "+%d%% Critical Multiplier", "pct": true,
		"tiers": [[1, 0.10, 0.18], [12, 0.19, 0.30], [25, 0.31, 0.45]]},
	"speed": {"type": "suffix", "stat": "move_speed", "kind": "inc", "slots": ["boots"], "fmt": "+%d%% Movement Speed", "pct": true,
		"tiers": [[1, 0.05, 0.08], [10, 0.09, 0.13], [22, 0.14, 0.20]]},
	"regen": {"type": "suffix", "stat": "regen", "kind": "add", "slots": ["ring", "amulet", "boots"], "fmt": "+%.1f Life Regeneration per second", "pct": false, "dec": true,
		"tiers": [[1, 0.3, 0.6], [10, 0.7, 1.2], [22, 1.3, 2.2]]},
	"pickup": {"type": "suffix", "stat": "pickup", "kind": "inc", "slots": ["boots", "ring"], "fmt": "+%d%% Pickup Radius", "pct": true,
		"tiers": [[1, 0.10, 0.20], [10, 0.21, 0.35]]},
	"rarity": {"type": "suffix", "stat": "item_rarity", "kind": "inc", "slots": ["amulet", "ring", "boots"], "fmt": "+%d%% Item Rarity", "pct": true,
		"tiers": [[1, 0.08, 0.14], [12, 0.15, 0.24], [25, 0.25, 0.35]]},
	"xp": {"type": "suffix", "stat": "xp_gain", "kind": "inc", "slots": ["amulet", "relic"], "fmt": "+%d%% Experience gained", "pct": true,
		"tiers": [[1, 0.05, 0.08], [12, 0.09, 0.14]]},
	"flask": {"type": "suffix", "stat": "flask_charge", "kind": "inc", "slots": ["ring", "boots"], "fmt": "+%d%% Flask Charges gained", "pct": true,
		"tiers": [[1, 0.10, 0.20], [12, 0.21, 0.35]]},
}

# Legendary powers. The Cube extracts them into the Codex; up to 3 codex powers are active per run (D3 Kanai's Cube).
const LEGENDARIES := {
	"furnace": {"name": "The Furnace", "slot": "relic", "d": "50% more damage against elites, exiles and bosses."},
	"stormherald": {"name": "Stormherald Coil", "slot": "amulet", "d": "Every 12th hit calls a chain of lightning through 5 foes."},
	"rimeheart": {"name": "Rimeheart", "slot": "ring", "d": "Hits against chilled foes have a 12% chance to freeze them for 1.5s."},
	"gorefeast": {"name": "Gorefeast Band", "slot": "ring", "d": "Killing a bleeding foe heals 1% of your maximum life."},
	"cascade": {"name": "Cascade Sigil", "slot": "relic", "d": "Reactions echo once more at 50% damage."},
	"greed": {"name": "Gremlin's Greed", "slot": "amulet", "d": "Doubles gold found. Treasure Gremlins appear twice as often."},
	"phoenix": {"name": "Phoenix Ember", "slot": "amulet", "d": "Once per run, lethal damage instead restores 50% life and erupts in flame."},
	"ouroboros": {"name": "Ouroboros Treads", "slot": "boots", "d": "Dodge rolling leaves a fire nova behind you."},
}
const LEGENDARY_IDS := ["furnace", "stormherald", "rimeheart", "gorefeast", "cascade", "greed", "phoenix", "ouroboros"]
const CODEX_SLOTS := 3

# ---------------------------------------------------------------- crafting currency (component-driven, PoE orbs)
const CURRENCY := {
	"transmute": {"name": "Shard of Change", "d": "Normal to Magic.", "col": "9fc8ff"},
	"augment": {"name": "Shard of Growth", "d": "Adds an affix to a Magic item with room.", "col": "6f9bff"},
	"regal": {"name": "Crown Shard", "d": "Magic to Rare, adding an affix.", "col": "ffe07a"},
	"chaos": {"name": "Chaos Shard", "d": "Rerolls every affix of a Rare item.", "col": "ffb24a"},
	"exalt": {"name": "Star Shard", "d": "Adds an affix to a Rare item with room.", "col": "fff2b0"},
	"annul": {"name": "Null Shard", "d": "Removes a random affix.", "col": "c0c0c0"},
	"divine": {"name": "Divine Shard", "d": "Rerolls the values of every affix within its tier.", "col": "ffd0f0"},
	"corrupt": {"name": "Rift Ember", "d": "Corrupts: upgrades a random affix tier, or bricks it. Corrupted items cannot be crafted.", "col": "ff4a4a"},
}
const CURRENCY_IDS := ["transmute", "augment", "regal", "chaos", "exalt", "annul", "divine", "corrupt"]
const CURRENCY_WEIGHT := {"transmute": 30, "augment": 24, "regal": 10, "chaos": 12, "exalt": 4, "annul": 8, "divine": 6, "corrupt": 6}

# ---------------------------------------------------------------- buffs: pylons, shrines, flasks (D3 / PoE)
enum Stack { REFRESH, INTENSITY, DURATION, UNIQUE }
const BUFFS := {
	"power": {"name": "Power Pylon", "dur": 20.0, "policy": Stack.REFRESH, "col": "ff5a5a", "mods": [["damage", "more", 3.0]], "pylon": true},
	"conduit": {"name": "Conduit Pylon", "dur": 20.0, "policy": Stack.REFRESH, "col": "fff07a", "mods": [], "pylon": true},
	"channel": {"name": "Channeling Pylon", "dur": 20.0, "policy": Stack.REFRESH, "col": "6bd6ff", "mods": [["cooldown", "more", 0.35]], "pylon": true},
	"shield": {"name": "Shield Pylon", "dur": 15.0, "policy": Stack.REFRESH, "col": "8affd0", "mods": [["invuln", "add", 1.0]], "pylon": true},
	"speed": {"name": "Speed Pylon", "dur": 20.0, "policy": Stack.REFRESH, "col": "b890ff", "mods": [["move_speed", "more", 1.8]], "pylon": true},
	"fortune": {"name": "Fortune Shrine", "dur": 60.0, "policy": Stack.REFRESH, "col": "ffd84a", "mods": [["item_rarity", "inc", 0.75], ["gold_find", "inc", 0.5]]},
	"enlight": {"name": "Enlightened Shrine", "dur": 60.0, "policy": Stack.REFRESH, "col": "7dff6b", "mods": [["xp_gain", "inc", 0.25]]},
	"frenzied": {"name": "Frenzied Shrine", "dur": 45.0, "policy": Stack.REFRESH, "col": "ff9a3c", "mods": [["cooldown", "more", 0.8]]},
	"empowered": {"name": "Empowered Shrine", "dur": 45.0, "policy": Stack.REFRESH, "col": "ff6bd6", "mods": [["ult_charge", "inc", 1.0]]},
	"riposte": {"name": "Riposte", "dur": 2.0, "policy": Stack.REFRESH, "col": "ffffff", "mods": [["crit_chance", "add", 1.0]]},
	"soulharvest": {"name": "Soul Harvest", "dur": 8.0, "policy": Stack.INTENSITY, "max": 25, "col": "c48aff", "mods": [["damage", "inc", 0.02]]},
	"quicksilver": {"name": "Quicksilver", "dur": 5.0, "policy": Stack.DURATION, "max_dur": 10.0, "col": "c9f3ff", "mods": [["move_speed", "inc", 0.4]]},
	"granite": {"name": "Granite", "dur": 5.0, "policy": Stack.DURATION, "max_dur": 10.0, "col": "a0a0a0", "mods": [["armor", "add", 120.0]]},
	"diamond": {"name": "Diamond", "dur": 5.0, "policy": Stack.DURATION, "max_dur": 10.0, "col": "e0faff", "mods": [["crit_chance", "add", 0.3]]},
	"frenzy": {"name": "Overclock", "dur": 12.0, "policy": Stack.REFRESH, "col": "ff8a2b", "mods": [["cooldown", "more", 0.5]]},
	"aegis": {"name": "Aegis", "dur": 12.0, "policy": Stack.UNIQUE, "col": "ffd24a", "mods": [["invuln", "add", 1.0], ["move_speed", "inc", 0.3]]},
	"vital": {"name": "Vital Surge", "dur": 10.0, "policy": Stack.REFRESH, "col": "5dff6b", "mods": [["regen_pct", "add", 0.05]]},
	"cyclone": {"name": "Blade Cyclone", "dur": 6.0, "policy": Stack.REFRESH, "col": "f0b94d", "mods": []},
	"thunderdome": {"name": "Thunderdome", "dur": 4.0, "policy": Stack.REFRESH, "col": "b890ff", "mods": []},
}
const PYLON_IDS := ["power", "conduit", "channel", "shield", "speed"]
const SHRINE_IDS := ["fortune", "enlight", "frenzied", "empowered"]
const UTIL_FLASKS := ["quicksilver", "granite", "diamond", "sulphur"]
const FLASK_NAME := {"life": "Life Flask", "quicksilver": "Quicksilver Flask", "granite": "Granite Flask", "diamond": "Diamond Flask", "sulphur": "Sulphur Flask"}

# ---------------------------------------------------------------- lore (collectibles)
const LORE := [
	["The Shardfall I", "The sky broke on a quiet night. Nobody remembers the sound, only the light."],
	["The Shardfall II", "The pieces fell everywhere at once, and where they landed, things began to grow teeth."],
	["The Shardfall III", "We called them shards. They called us food."],
	["The Shardfall IV", "The Herald was seen before every fall. Tall. Patient. Singing."],
	["Survivor's Log I", "Day 3. The gremlins steal from the dead. I follow them. They lead to gold."],
	["Survivor's Log II", "Day 9. The breaches open where the shards fell thickest. Something reaches through."],
	["Survivor's Log III", "Day 14. Another survivor tried to kill me for my boots. I have his boots now."],
	["Survivor's Log IV", "Day 30. Fire and ice together make the shards scream. I have started to enjoy the sound."],
	["Rift Notes I", "Rifts fold time. The deeper the rift, the less of it you get."],
	["Rift Notes II", "Every guardian is the same guardian, wearing a different hunger."],
	["Rift Notes III", "The atlas is not a map of places. It is a map of falls."],
	["Rift Notes IV", "Collect the three fragments. Summon the Herald. End the song."],
]
const LORE_SET := 4      # each completed set of 4 pages: +5% damage and +10 life, permanently

# ---------------------------------------------------------------- season (rotating weekly) affixes
const SEASONS := [
	{"id": "soulharvest", "name": "Season of Souls", "d": "Kills grant Soul Harvest: +2% damage per stack, up to 25 stacks."},
	{"id": "ethereal", "name": "Season of Echoes", "d": "Slain elites return as ethereal allies for 10s."},
	{"id": "avarice", "name": "Season of Avarice", "d": "Foes drop 50% more gold, but elites burst into coins that bite."},
	{"id": "blight", "name": "Season of Blight", "d": "Foes leave poison clouds on death. +25% item quantity."},
	{"id": "mirrored", "name": "Season of Mirrors", "d": "Elites spawn with a twin. +40% elite rewards."},
]

# ---------------------------------------------------------------- events (happenings) for the Director
# weight: base pick weight; cd: per-event cooldown seconds; min_t: earliest run time
const EVENTS := {
	"breach": {"name": "Breach", "d": "A rupture opens. Kill inside it to keep it open.", "weight": 10, "cd": 70.0, "min_t": 30.0, "col": "c48aff"},
	"goblin": {"name": "Treasure Gremlin", "d": "Catch it before it escapes.", "weight": 8, "cd": 60.0, "min_t": 20.0, "col": "ffd84a"},
	"cursed": {"name": "Cursed Chest", "d": "Survive the onslaught to claim it.", "weight": 7, "cd": 80.0, "min_t": 40.0, "col": "ff4a5e"},
	"strongbox": {"name": "Strongbox", "d": "Open it. Its guardians wake.", "weight": 9, "cd": 45.0, "min_t": 15.0, "col": "c8a070"},
	"eclipse": {"name": "Eclipse", "d": "Darkness falls. Foes hide in it. Loot shines brighter.", "weight": 4, "cd": 120.0, "min_t": 60.0, "col": "403070"},
	"meteor": {"name": "Starfall", "d": "Shards rain from the sky. They hit everything.", "weight": 6, "cd": 90.0, "min_t": 50.0, "col": "ffb24a"},
	"merchant": {"name": "Wandering Merchant", "d": "A gambler with wares of unknown quality.", "weight": 4, "cd": 150.0, "min_t": 45.0, "col": "7dff6b"},
	"delirium": {"name": "Delirium Mirror", "d": "Step into the fog. The deeper you go, the more it pays.", "weight": 5, "cd": 110.0, "min_t": 70.0, "col": "d8d8e8"},
	"ritual": {"name": "Blood Ritual", "d": "Slay everything the altar summons.", "weight": 6, "cd": 90.0, "min_t": 35.0, "col": "ff2b4a"},
	"exile": {"name": "Rogue Exile", "d": "Another survivor wants your loot.", "weight": 5, "cd": 999.0, "min_t": 55.0, "col": "ff8a2b"},
}
const EVENT_IDS := ["breach", "goblin", "cursed", "strongbox", "eclipse", "meteor", "merchant", "delirium", "ritual", "exile"]
const EXILE_NAMES := ["Varkas", "Ilsa", "Torven", "Mireth", "Dunmor", "Kesh", "Oriane", "Bram", "Sefa", "Corvin"]
const EXILE_TITLES := ["the Unbroken", "of the Ninth Fall", "Shardeater", "the Hollow", "Gravebinder", "the Last Light", "Who Walks Twice"]

# ---------------------------------------------------------------- atlas map modifiers (PoE map mods)
# qty/rar: bonus item quantity / rarity granted for running a map with that mod.
const MAP_MODS := {
	"hardened": {"name": "Hardened", "d": "Monsters have 40% more life", "qty": 0.10, "rar": 0.05},
	"lethal": {"name": "Lethal", "d": "Monsters deal 30% more damage", "qty": 0.12, "rar": 0.06},
	"swift": {"name": "Swift", "d": "Monsters move 20% faster", "qty": 0.08, "rar": 0.05},
	"packed": {"name": "Teeming", "d": "40% more monsters", "qty": 0.18, "rar": 0.04},
	"elite": {"name": "Champions", "d": "Elites are three times as common", "qty": 0.12, "rar": 0.12},
	"hexed": {"name": "Hexed", "d": "Players have 50% less life regeneration and flask charges", "qty": 0.10, "rar": 0.08},
	"breached": {"name": "Breach-touched", "d": "A Breach always opens", "qty": 0.10, "rar": 0.05},
	"volatile": {"name": "Volatile", "d": "Elites explode on death", "qty": 0.08, "rar": 0.06},
	"twinned": {"name": "Twinned", "d": "The map boss has a twin", "qty": 0.15, "rar": 0.15},
	"eclipsed": {"name": "Eclipsed", "d": "Permanent darkness", "qty": 0.14, "rar": 0.14},
}
const MAP_MOD_IDS := ["hardened", "lethal", "swift", "packed", "elite", "hexed", "breached", "volatile", "twinned", "eclipsed"]
const ATLAS_W := 7
const ATLAS_H := 5

# ---------------------------------------------------------------- greater rifts
const GR_TIME := 300.0
const GR_PROGRESS := 100.0
static func gr_hp_mult(lvl: int) -> float: return pow(1.17, lvl - 1)      # D3: +17% monster life per level
static func gr_dmg_mult(lvl: int) -> float: return pow(1.035, lvl - 1)

static func col(hex: String) -> Color: return Color.html(hex)
static func el_col(e: int, cb: bool = false) -> Color: return Color.html(EL_COL_CB[e] if cb else EL_COL[e])
