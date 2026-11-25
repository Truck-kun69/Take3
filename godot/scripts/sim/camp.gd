class_name Camp
extends RefCounted
## The Camp's rules (docs/superpowers/specs/2026-11-25-camp-tutorial-crafting-design.md): materials, the
## Weaponsmith's tempering, the Salvager's bench, the Fusion Furnace (gear, and weapon pairs) and the Trader.
## Static functions over a profile Dictionary: Save.data in the game, a fresh Save.defaults() in the tests.
## Every action checks first and returns "" when done or the reason it was refused, and then changes nothing.

const MATERIALS := {
	"scrap": {"name": "Shard Scrap", "col": "c9b79a", "d": "Salvaged from gear at Nim's bench."},
	"ore": {"name": "Rift Ore", "col": "ff9a5a", "d": "Carried out of the rift: from champions, tyrants and long fights."},
}
const MATERIAL_IDS := ["scrap", "ore"]

# ================================================================= materials and costs
static func mat(d: Dictionary, id: String) -> int:
	return int((d.get("materials", {}) as Dictionary).get(id, 0))

static func add_mat(d: Dictionary, id: String, n: int) -> void:
	if not d.has("materials"): d["materials"] = {"scrap": 0, "ore": 0}
	d.materials[id] = maxi(0, mat(d, id) + n)

## What the profile holds of one part of a cost: gold, a material or a crafting shard.
static func have(d: Dictionary, k: String) -> int:
	if k == "gold": return int(d.get("gold", 0))
	if MATERIALS.has(k): return mat(d, k)
	return int((d.get("currency", {}) as Dictionary).get(k, 0))

static func can_pay(d: Dictionary, cost: Dictionary) -> bool:
	for k in cost:
		if have(d, k) < int(cost[k]): return false
	return true

static func pay(d: Dictionary, cost: Dictionary) -> void:
	for k in cost:
		var n := int(cost[k])
		if k == "gold": d.gold = int(d.gold) - n
		elif MATERIALS.has(k): add_mat(d, k, -n)
		else: d.currency[k] = int(d.currency.get(k, 0)) - n

static func part_name(k: String) -> String:
	if k == "gold": return "Gold"
	if MATERIALS.has(k): return String(MATERIALS[k].name)
	return String(Content.CURRENCY[k].name) if Content.CURRENCY.has(k) else k

static func part_col(k: String) -> Color:
	if k == "gold": return Color("ffd27a")
	if MATERIALS.has(k): return Color(String(MATERIALS[k].col))
	return Content.col(Content.CURRENCY[k].col) if Content.CURRENCY.has(k) else Color.WHITE

## "120 Gold · 1 Rift Ore · 6 Shard Scrap"; short: "120 Gold · 1 Ore · 6 Scrap" (under a button).
static func cost_text(cost: Dictionary, short: bool = false) -> String:
	var parts := PackedStringArray()
	for k in ["gold", "ore", "scrap"] + Content.CURRENCY_IDS:
		if cost.has(k) and int(cost[k]) > 0:
			var nm := part_name(k)
			if short and MATERIALS.has(k): nm = nm.split(" ")[-1]
			parts.append("%d %s" % [int(cost[k]), nm])
	return (" · " if short else "  ·  ").join(parts)

## The weapons a profile can take into a run: the four starters and every one it has earned (Save.weapon_pool).
static func pool(d: Dictionary) -> Array:
	var locked := {}
	for u in Content.UNLOCKS: locked[u.w] = true
	var out: Array = []
	for id in Content.WEAPON_IDS:
		if not locked.has(id) or (d.get("unlocked", []) as Array).has(id): out.append(id)
	return out

# ================================================================= Doran Ashhand, Weaponsmith
## Temper ranks are permanent and per weapon; a run applies them when the weapon is taken (World._take_weapon).
const TEMPER_MAX := 5
const TEMPER_COST := [{"gold": 120, "ore": 1, "scrap": 6}, {"gold": 260, "ore": 2, "scrap": 12}, {"gold": 450, "ore": 4, "scrap": 20},
	{"gold": 700, "ore": 6, "scrap": 32}, {"gold": 1000, "ore": 9, "scrap": 48}]
const TEMPER_DMG := 0.08          # per rank, increased damage
const TEMPER_CD := 0.92           # from rank 3: cooldowns x0.92
const TEMPER_MASTER := 1.10       # rank 5: a further 10% more damage
const RANK_NAME := ["Untempered", "Tempered", "Honed", "Keen", "Rift-forged", "Masterwork"]

static func temper_rank(d: Dictionary, wid: String) -> int:
	return clampi(int((d.get("temper", {}) as Dictionary).get(wid, 0)), 0, TEMPER_MAX)

## The next rank's cost, or {} when the weapon is a masterwork.
static func temper_cost(d: Dictionary, wid: String) -> Dictionary:
	var r := temper_rank(d, wid)
	return {} if r >= TEMPER_MAX else (TEMPER_COST[r] as Dictionary).duplicate()

static func temper(d: Dictionary, wid: String) -> String:
	if not Content.WEAPONS.has(wid): return "No such weapon."
	if not pool(d).has(wid): return "Earn %s first." % Content.WEAPONS[wid].name
	var cost := temper_cost(d, wid)
	if cost.is_empty(): return "%s is already a masterwork." % Content.WEAPONS[wid].name
	if not can_pay(d, cost): return "Not enough: %s." % cost_text(cost)
	pay(d, cost)
	if not d.has("temper"): d["temper"] = {}
	d.temper[wid] = temper_rank(d, wid) + 1
	return ""

## The modifiers a rank gives its weapon (World.wlocal[id], source "temper").
static func temper_mods(rank: int) -> Array:
	if rank <= 0: return []
	var m: Array = [["damage", "inc", TEMPER_DMG * rank]]
	if rank >= 3: m.append(["cooldown", "more", TEMPER_CD])
	if rank >= 5: m.append(["damage", "more", TEMPER_MASTER])
	return m

static func temper_text(rank: int) -> String:
	if rank <= 0: return "No temper yet."
	var s := "+%d%% damage" % int(round(TEMPER_DMG * rank * 100.0))
	if rank >= 3: s += ", 8% faster"
	if rank >= 5: s += ", masterwork: 10% more damage"
	return s

# ================================================================= Nim, Salvager (the salvage bench)
const SCRAP := [2, 4, 8, 20]                                  # by rarity: Normal, Magic, Rare, Legendary
const SALVAGE_CUR := [["transmute", 1], ["augment", 2], ["chaos", 1], ["divine", 2]]

static func salvage_yield(it: Dictionary) -> Dictionary:
	var r := clampi(int(it.rarity), 0, 3)
	return {"scrap": SCRAP[r], String(SALVAGE_CUR[r][0]): int(SALVAGE_CUR[r][1])}

static func add_yield(d: Dictionary, y: Dictionary) -> void:
	for k in y:
		if MATERIALS.has(k): add_mat(d, k, int(y[k]))
		else: d.currency[k] = int(d.currency.get(k, 0)) + int(y[k])

## "4 Shard Scrap · 2 Augmentation Shard"
static func yield_text(y: Dictionary) -> String:
	return cost_text(y)

static func is_locked(d: Dictionary, it: Dictionary) -> bool:
	return (d.get("locked", []) as Array).has(int(it.get("uid", -1)))

static func toggle_lock(d: Dictionary, it: Dictionary) -> void:
	if not d.has("locked"): d["locked"] = []
	var u := int(it.uid)
	if d.locked.has(u): d.locked.erase(u)
	else: d.locked.append(u)

## One stash item into scrap and shards; {} (and nothing changes) when it is locked or not in the stash.
static func salvage(d: Dictionary, it: Dictionary) -> Dictionary:
	if is_locked(d, it) or not (d.stash as Array).has(it): return {}
	var y := salvage_yield(it)
	d.stash.erase(it)
	add_yield(d, y)
	return y

## The stash items "Salvage all" of one rarity would take: never locked, never Legendary (equipped gear is
## not in the stash).
static func bulk_list(d: Dictionary, rarity: int) -> Array:
	var out: Array = []
	if rarity >= Content.Rarity.LEGENDARY: return out
	for it in d.stash:
		if int(it.rarity) == rarity and not is_locked(d, it): out.append(it)
	return out

static func bulk_yield(items: Array) -> Dictionary:
	var y := {}
	for it in items:
		var one := salvage_yield(it)
		for k in one: y[k] = int(y.get(k, 0)) + int(one[k])
	return y

static func salvage_all(d: Dictionary, rarity: int) -> Dictionary:
	var items := bulk_list(d, rarity)
	var y := bulk_yield(items)
	for it in items: d.stash.erase(it)
	add_yield(d, y)
	return y

# ================================================================= Mother Kiln, the Fusion Furnace
## Gear: FUSE_N unlocked stash items of one slot and rarity become one new item of that slot a rarity higher,
## at the highest item level of the three. Rare into Legendary also takes a Divine Orb.
const FUSE_N := 3
const FUSE_COST := [{"gold": 60, "scrap": 4}, {"gold": 180, "scrap": 10}, {"gold": 500, "scrap": 24, "divine": 1}]

## Every slot and rarity with at least FUSE_N unlocked items, highest rarity first: {slot, rarity, items}.
static func fuse_groups(d: Dictionary) -> Array:
	var by := {}
	for it in d.stash:
		var r := int(it.rarity)
		if r >= Content.Rarity.LEGENDARY or is_locked(d, it): continue
		var k := "%d:%s" % [r, it.slot]
		if not by.has(k): by[k] = {"slot": String(it.slot), "rarity": r, "items": []}
		by[k].items.append(it)
	var out: Array = []
	for k in by:
		if by[k].items.size() >= FUSE_N:
			by[k].items.sort_custom(func(a, b): return Items.score(a) < Items.score(b))   # the weakest go in first
			out.append(by[k])
	out.sort_custom(func(a, b): return a.rarity > b.rarity or (a.rarity == b.rarity and Content.SLOTS.find(a.slot) < Content.SLOTS.find(b.slot)))
	return out

static func fuse_cost(rarity: int) -> Dictionary:
	return (FUSE_COST[clampi(rarity, 0, FUSE_COST.size() - 1)] as Dictionary).duplicate()

## The new item, or why the three were refused (a String; nothing changes then).
static func fuse_items(d: Dictionary, items: Array, rng: RandomNumberGenerator = null) -> Variant:
	if items.size() != FUSE_N: return "The furnace takes %d items." % FUSE_N
	var slot := String(items[0].slot)
	var r := int(items[0].rarity)
	var top := 1
	var seen := {}
	for it in items:
		if not (d.stash as Array).has(it): return "Only items in the stash can be fused."
		if String(it.slot) != slot or int(it.rarity) != r: return "Fuse three items of one slot and rarity."
		if is_locked(d, it): return "Unlock %s first." % Items.name_of(it)
		if seen.has(int(it.uid)): return "Three different items."
		seen[int(it.uid)] = true
		top = maxi(top, int(it.ilvl))
	if r >= Content.Rarity.LEGENDARY: return "Legendary items cannot be fused."
	var cost := fuse_cost(r)
	if not can_pay(d, cost): return "Not enough: %s." % cost_text(cost)
	pay(d, cost)
	for it in items: d.stash.erase(it)
	var out := Items.make(slot, r + 1, top, rng)
	d.stash.append(out)
	return out

## Weapons: kindling a pair (any two weapons the profile can take) lets them fuse in a run as soon as both
## reach their last level, evolved or not (World.make_choices), and the kindled fusion hits harder.
const KINDLED_MORE := 1.35        # an ordinary fusion: 1.25
const KINDLE_BASE := {"gold": 300, "ore": 3}
const KINDLE_STEP := {"gold": 200, "ore": 2}

static func kindled(d: Dictionary, key: String) -> bool:
	return (d.get("kindled", []) as Array).has(key)

static func kindle_cost(d: Dictionary) -> Dictionary:
	var n := (d.get("kindled", []) as Array).size()
	return {"gold": int(KINDLE_BASE.gold) + int(KINDLE_STEP.gold) * n, "ore": int(KINDLE_BASE.ore) + int(KINDLE_STEP.ore) * n}

static func kindle(d: Dictionary, a: String, b: String) -> String:
	if a == b: return "Choose two different weapons."
	var pl := pool(d)
	for id in [a, b]:
		if not Content.WEAPONS.has(id): return "No such weapon."
		if not pl.has(id): return "Earn %s first." % Content.WEAPONS[id].name
	var key := Content.fusion_key(a, b)
	if kindled(d, key): return "%s is already kindled." % Content.fusion_def(key).name
	var cost := kindle_cost(d)
	if not can_pay(d, cost): return "Not enough: %s." % cost_text(cost)
	pay(d, cost)
	if not d.has("kindled"): d["kindled"] = []
	d.kindled.append(key)
	return ""

# ================================================================= Sella Coinwright, Trader
## TRADER_SLOTS items a day, seeded by the date, the restocks bought that day and the acts cleared (item level).
## The stock is kept in the profile, so a bought item stays gone and a visit later the same day shows the rest.
const TRADER_SLOTS := 4
const RESTOCK_COST := 100          # doubles with each restock the same day
const SHARD_PRICES := {"transmute": 25, "augment": 50, "regal": 160, "chaos": 220, "divine": 380}
const SHARD_IDS := ["transmute", "augment", "regal", "chaos", "divine"]

static func today() -> String:
	return Time.get_date_string_from_system()

static func trader_ilvl(d: Dictionary) -> int:
	var c := 0
	for x in d.get("cleared", []):
		if x: c += 1
	return 10 + 8 * c

static func price_of(it: Dictionary) -> int:
	match int(it.rarity):
		Content.Rarity.MAGIC: return 90 + 2 * int(it.ilvl)
		Content.Rarity.RARE: return 300 + 6 * int(it.ilvl)
		Content.Rarity.LEGENDARY: return 1800 + 10 * int(it.ilvl)
	return 30

static func _roll_stock(d: Dictionary, day: String, rolls: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%d" % [day, rolls, trader_ilvl(d)])
	var out: Array = []
	var il := trader_ilvl(d)
	for k in TRADER_SLOTS:
		var r := Content.Rarity.MAGIC if rng.randf() < 0.6 else Content.Rarity.RARE
		if k == TRADER_SLOTS - 1:
			r = Content.Rarity.LEGENDARY if rng.randf() < 0.1 else Content.Rarity.RARE
		var it := Items.make(Content.SLOTS[rng.randi_range(0, Content.SLOTS.size() - 1)], r, il + rng.randi_range(-2, 2), rng)
		out.append({"it": it, "price": price_of(it)})
	return out

## Today's stock (a fresh day rolls a new one).
static func trader_stock(d: Dictionary, day: String = "") -> Array:
	if day == "": day = today()
	if not d.has("trader"): d["trader"] = {"day": "", "rolls": 0, "stock": []}
	var T: Dictionary = d.trader
	if String(T.get("day", "")) != day:
		T.day = day
		T.rolls = 0
		T.stock = _roll_stock(d, day, 0)
	return T.stock

static func trader_buy(d: Dictionary, k: int, day: String = "") -> String:
	var stock := trader_stock(d, day)
	if k < 0 or k >= stock.size(): return "That is sold."
	var e: Dictionary = stock[k]
	if int(d.gold) < int(e.price): return "%d Gold needed." % int(e.price)
	d.gold = int(d.gold) - int(e.price)
	var it: Dictionary = (e.it as Dictionary).duplicate(true)
	it.uid = Items.new_uid(null)
	d.stash.append(it)
	stock.remove_at(k)
	return ""

static func restock_cost(d: Dictionary) -> int:
	return RESTOCK_COST * int(pow(2.0, float(int((d.get("trader", {}) as Dictionary).get("rolls", 0)))))

static func restock(d: Dictionary, day: String = "") -> String:
	trader_stock(d, day)
	var c := restock_cost(d)
	if int(d.gold) < c: return "%d Gold needed." % c
	d.gold = int(d.gold) - c
	d.trader.rolls = int(d.trader.rolls) + 1
	d.trader.stock = _roll_stock(d, String(d.trader.day), int(d.trader.rolls))
	return ""

static func buy_shard(d: Dictionary, id: String) -> String:
	if not SHARD_PRICES.has(id): return "Sella does not sell those."
	var p := int(SHARD_PRICES[id])
	if int(d.gold) < p: return "%d Gold needed." % p
	d.gold = int(d.gold) - p
	d.currency[id] = int(d.currency.get(id, 0)) + 1
	return ""

# ================================================================= the run's ore
## 1 per Rift Champion, 3 for the act's tyrant (a won run), 1 per 400 kills, at most ORE_CAP; none in the Daily Rift.
const ORE_CAP := 12
static func ore_for_run(w: World, win: bool) -> int:
	if w.daily: return 0
	return mini(ORE_CAP, w.champions_slain + (3 if win else 0) + w.kills / 400)

# ================================================================= the camp's state, for the title
## True when a station has something to do: an affordable temper or kindle, a furnace group, or unseen stock.
static func has_news(d: Dictionary) -> bool:
	for id in pool(d):
		var c := temper_cost(d, id)
		if not c.is_empty() and can_pay(d, c): return true
	for g in fuse_groups(d):
		if can_pay(d, fuse_cost(int(g.rarity))): return true
	return String((d.get("trader", {}) as Dictionary).get("day", "")) != today() and int(d.get("gold", 0)) >= 200
