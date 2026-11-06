class_name Items
extends RefCounted
## Item generation and component-driven crafting. Items are plain Dictionaries so they serialise
## straight to JSON:
##   {uid, slot, base, rarity, ilvl, affixes: [{id, tier, v}], leg: "" | legendary id, corrupt: bool}
## Every crafting operation validates its preconditions and returns "" on success or a reason
## string, and never consumes the currency on failure.

static func _rng(rng: RandomNumberGenerator) -> RandomNumberGenerator:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	return rng

static func new_uid(rng: RandomNumberGenerator) -> int:
	return _rng(rng).randi() & 0x7fffffff

static func make(slot: String, rarity: int, ilvl: int, rng: RandomNumberGenerator = null) -> Dictionary:
	rng = _rng(rng)
	var bases: Array = Content.BASES[slot]
	var it := {"uid": new_uid(rng), "slot": slot, "base": rng.randi_range(0, bases.size() - 1), "rarity": Content.Rarity.NORMAL,
		"ilvl": ilvl, "affixes": [], "leg": "", "corrupt": false}
	if rarity >= Content.Rarity.MAGIC:
		it.rarity = Content.Rarity.MAGIC
		add_random_affix(it, rng)
		if rng.randf() < 0.5:
			add_random_affix(it, rng)
	if rarity >= Content.Rarity.RARE:
		it.rarity = Content.Rarity.RARE
		var want := rng.randi_range(3, 5)
		var guard := 0
		while it.affixes.size() < want and guard < 20:
			add_random_affix(it, rng)
			guard += 1
	if rarity >= Content.Rarity.LEGENDARY:
		it.rarity = Content.Rarity.LEGENDARY
		var pool: Array = []
		for id in Content.LEGENDARY_IDS:
			if Content.LEGENDARIES[id].slot == slot:
				pool.append(id)
		if pool.is_empty():
			pool = Content.LEGENDARY_IDS.duplicate()
		it.leg = pool[rng.randi_range(0, pool.size() - 1)]
	return it

## Rarity roll. `rarity_bonus` is increased item rarity (0.5 = +50%), applied to the magic/rare/legendary bands.
static func roll_rarity(rng: RandomNumberGenerator, rarity_bonus: float, floor_r: int = 0) -> int:
	rng = _rng(rng)
	var m := 1.0 + maxf(0.0, rarity_bonus)
	var r := rng.randf()
	var out := Content.Rarity.NORMAL
	if r < 0.012 * m: out = Content.Rarity.LEGENDARY
	elif r < 0.10 * m: out = Content.Rarity.RARE
	elif r < 0.45 * m: out = Content.Rarity.MAGIC
	return maxi(out, floor_r)

static func random_slot(rng: RandomNumberGenerator) -> String:
	return Content.SLOTS[_rng(rng).randi_range(0, Content.SLOTS.size() - 1)]

static func count_type(it: Dictionary, t: String) -> int:
	var c := 0
	for a in it.affixes:
		if Content.AFFIXES[a.id].type == t:
			c += 1
	return c

static func has_room(it: Dictionary) -> bool:
	var r: int = it.rarity
	return count_type(it, "prefix") < Content.MAX_PREFIX[r] or count_type(it, "suffix") < Content.MAX_SUFFIX[r]

static func max_affixes(r: int) -> int:
	return Content.MAX_PREFIX[r] + Content.MAX_SUFFIX[r]

## Adds one affix allowed by slot, item level, prefix/suffix limits and not already present.
static func add_random_affix(it: Dictionary, rng: RandomNumberGenerator) -> bool:
	rng = _rng(rng)
	var r: int = it.rarity
	var pre_ok: bool = count_type(it, "prefix") < Content.MAX_PREFIX[r]
	var suf_ok: bool = count_type(it, "suffix") < Content.MAX_SUFFIX[r]
	var have := {}
	for a in it.affixes:
		have[a.id] = true
	var pool: Array = []
	for id in Content.AFFIXES:
		var def: Dictionary = Content.AFFIXES[id]
		if have.has(id) or not def.slots.has(it.slot):
			continue
		if def.type == "prefix" and not pre_ok: continue
		if def.type == "suffix" and not suf_ok: continue
		if int(def.tiers[0][0]) > int(it.ilvl): continue
		pool.append(id)
	if pool.is_empty():
		return false
	var id: String = pool[rng.randi_range(0, pool.size() - 1)]
	it.affixes.append(roll_affix(id, int(it.ilvl), rng))
	return true

## Highest tier unlocked by ilvl is the most likely; lower tiers remain possible.
static func roll_affix(id: String, ilvl: int, rng: RandomNumberGenerator) -> Dictionary:
	var tiers: Array = Content.AFFIXES[id].tiers
	var top := 0
	for t in tiers.size():
		if int(tiers[t][0]) <= ilvl:
			top = t
	var tier := top
	while tier > 0 and rng.randf() < 0.35:
		tier -= 1
	return {"id": id, "tier": tier, "v": _roll_value(id, tier, rng)}

static func _roll_value(id: String, tier: int, rng: RandomNumberGenerator) -> float:
	var t: Array = Content.AFFIXES[id].tiers[tier]
	var lo := float(t[1])
	var hi := float(t[2])
	if lo > hi:
		var s := lo; lo = hi; hi = s
	var v := rng.randf_range(lo, hi)
	if not Content.AFFIXES[id].pct and not Content.AFFIXES[id].get("dec", false):
		v = roundf(v)
	return v

# ---------------------------------------------------------------- text
static func name_of(it: Dictionary) -> String:
	var base: String = Content.BASES[it.slot][int(it.base)].name
	if String(it.leg) != "":
		return Content.LEGENDARIES[it.leg].name
	match int(it.rarity):
		Content.Rarity.MAGIC: return "Magic " + base
		Content.Rarity.RARE: return _rare_name(int(it.uid)) + " " + base
	return base

static func _rare_name(u: int) -> String:
	var a := ["Grim", "Storm", "Ash", "Dusk", "Rift", "Gale", "Blood", "Star", "Hollow", "Ember"]
	var b := ["bane", "song", "ward", "fang", "veil", "brand", "coil", "mark", "crest", "loop"]
	return a[u % a.size()] + b[(u / 7) % b.size()]

static func affix_text(a: Dictionary) -> String:
	var def: Dictionary = Content.AFFIXES[a.id]
	var v: float = float(a.v)
	if def.get("neg", false):
		v = -v
	var s: String
	if def.pct:
		s = def.fmt % int(round(v * 100.0))
	elif def.get("dec", false):
		s = def.fmt % v
	else:
		s = def.fmt % int(v)
	return s + "  (T%d)" % (Content.AFFIXES[a.id].tiers.size() - int(a.tier))

static func lines(it: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var imp: Array = Content.BASES[it.slot][int(it.base)].imp
	out.append("Implicit: " + _mod_text(imp))
	for a in it.affixes:
		out.append(affix_text(a))
	if String(it.leg) != "":
		out.append("Legendary: " + Content.LEGENDARIES[it.leg].d)
	if it.corrupt:
		out.append("Corrupted")
	return out

static func _mod_text(m: Array) -> String:
	var v := float(m[2])
	if m[1] == "inc":
		return "+%d%% %s" % [int(round(v * 100.0)), String(m[0]).replace("_", " ")]
	if v < 1.0:
		return "+%d%% %s" % [int(round(v * 100.0)), String(m[0]).replace("_", " ")]
	return "+%d %s" % [int(v), String(m[0]).replace("_", " ")]

## Modifiers this item contributes, for Stats.set_source.
static func mods(it: Dictionary) -> Array:
	var out: Array = [Content.BASES[it.slot][int(it.base)].imp]
	for a in it.affixes:
		var def: Dictionary = Content.AFFIXES[a.id]
		out.append([def.stat, def.kind, float(a.v)])
	return out

## Rough power score used for "upgrade" arrows and auto-equip. Weights favour damage.
const SCORE_W := {"damage": 300.0, "max_hp": 1.6, "armor": 0.8, "dot_damage": 120.0, "reaction_damage": 120.0, "proj_count": 40.0,
	"cooldown": -350.0, "crit_chance": 400.0, "crit_mult": 60.0, "move_speed": 120.0, "regen": 10.0, "pickup": 30.0,
	"item_rarity": 40.0, "xp_gain": 60.0, "flask_charge": 20.0, "dodge_cd": -60.0}
static func score(it: Dictionary) -> float:
	if it.is_empty():
		return 0.0
	var s := 0.0
	for m in mods(it):
		s += float(m[2]) * float(SCORE_W.get(m[0], 10.0))
	if String(it.leg) != "":
		s += 25.0
	return s

# ---------------------------------------------------------------- crafting
static func craft(it: Dictionary, cur: String, rng: RandomNumberGenerator = null) -> String:
	rng = _rng(rng)
	if it.corrupt:
		return "Corrupted items cannot be modified."
	var r: int = it.rarity
	match cur:
		"transmute":
			if r != Content.Rarity.NORMAL: return "Needs a Normal item."
			it.rarity = Content.Rarity.MAGIC
			add_random_affix(it, rng)
			if rng.randf() < 0.5: add_random_affix(it, rng)
		"augment":
			if r != Content.Rarity.MAGIC: return "Needs a Magic item."
			if not has_room(it): return "No room for another affix."
			if not add_random_affix(it, rng): return "No affix can roll on this item."
		"regal":
			if r != Content.Rarity.MAGIC: return "Needs a Magic item."
			it.rarity = Content.Rarity.RARE
			add_random_affix(it, rng)
		"chaos":
			if r != Content.Rarity.RARE: return "Needs a Rare item."
			it.affixes = []
			var want := rng.randi_range(3, 5)
			var guard := 0
			while it.affixes.size() < want and guard < 20:
				add_random_affix(it, rng); guard += 1
			it.uid = new_uid(rng)
		"exalt":
			if r != Content.Rarity.RARE and r != Content.Rarity.LEGENDARY: return "Needs a Rare or Legendary item."
			if not has_room(it): return "No room for another affix."
			if not add_random_affix(it, rng): return "No affix can roll on this item."
		"annul":
			if it.affixes.is_empty(): return "No affixes to remove."
			it.affixes.remove_at(rng.randi_range(0, it.affixes.size() - 1))
		"divine":
			if it.affixes.is_empty(): return "No affixes to reroll."
			for a in it.affixes:
				a.v = _roll_value(a.id, int(a.tier), rng)
		"corrupt":
			it.corrupt = true
			var roll := rng.randf()
			if roll < 0.35 and not it.affixes.is_empty():
				var a: Dictionary = it.affixes[rng.randi_range(0, it.affixes.size() - 1)]
				var tiers: Array = Content.AFFIXES[a.id].tiers
				if int(a.tier) < tiers.size() - 1:
					a.tier = int(a.tier) + 1
				a.v = _roll_value(a.id, int(a.tier), rng) * 1.1     # corrupted: can exceed the tier range
			elif roll < 0.55 and not it.affixes.is_empty():
				it.affixes.remove_at(rng.randi_range(0, it.affixes.size() - 1))
			# else: unchanged, just corrupted
		_:
			return "Unknown currency."
	return ""

## Invariants checked by tests and on load (guards against bad saves).
static func valid(it: Dictionary) -> bool:
	if not Content.SLOTS.has(it.get("slot", "")):
		return false
	var r: int = int(it.get("rarity", 0))
	if count_type(it, "prefix") > Content.MAX_PREFIX[r] or count_type(it, "suffix") > Content.MAX_SUFFIX[r]:
		return false
	var seen := {}
	for a in it.affixes:
		if seen.has(a.id) or not Content.AFFIXES.has(a.id):
			return false
		seen[a.id] = true
		if not Content.AFFIXES[a.id].slots.has(it.slot):
			return false
	return true

## JSON turns ints into floats; normalise after loading.
static func normalise(it: Dictionary) -> Dictionary:
	it.uid = int(it.get("uid", 0)); it.base = int(it.get("base", 0)); it.rarity = int(it.get("rarity", 0)); it.ilvl = int(it.get("ilvl", 1))
	it.leg = String(it.get("leg", "")); it.corrupt = bool(it.get("corrupt", false))
	var aff: Array = []
	for a in it.get("affixes", []):
		aff.append({"id": String(a.id), "tier": int(a.tier), "v": float(a.v)})
	it.affixes = aff
	return it
