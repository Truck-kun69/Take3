class_name Daily
extends RefCounted
## The Daily Rift: one seeded run per calendar day, the same for everyone.
##
## The date hashes to a 20-bit seed, written as a share code (SHARD-XXXX, Crockford-style alphabet
## with no 0/O/1/I). The seed fixes the act, the exile, two map modifiers and the run's RNG; gear,
## the Shard Web, legendary powers, the Moon and prophecies are all left at home, so a score
## compares play, not profiles. Typing a friend's code plays their rift.
##   score = kills + 2 per second survived + 1500 for a win + half the hoard banked

const ALPHA := "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
const BITS := 20
const MODS := ["hardened", "lethal", "swift", "packed", "elite", "hexed", "breached", "volatile", "twinned", "eclipsed"]

static func date_key(d: Dictionary = {}) -> String:
	if d.is_empty(): d = Time.get_date_dict_from_system()
	return "%04d%02d%02d" % [int(d.year), int(d.month), int(d.day)]

static func seed_for_date(key: String) -> int:
	return hash("shardfall-daily-" + key) & ((1 << BITS) - 1)

static func code_for(s: int) -> String:
	var out := ""
	for k in 4:
		out = ALPHA[(s >> (5 * k)) & 31] + out
	return "SHARD-" + out

## -1 when the code is not a valid rift code. Accepts "shard-7kq2", "7KQ2", spaces.
static func seed_from_code(code: String) -> int:
	var c := code.strip_edges().to_upper().replace(" ", "").trim_prefix("SHARD-").trim_prefix("SHARD")
	if c.length() != 4: return -1
	var s := 0
	for ch in c:
		var v := ALPHA.find(ch)
		if v < 0: return -1
		s = (s << 5) | v
	return s

## The run configuration a seed stands for (World.setup reads "daily" and "mods").
static func config(s: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = s * 7919 + 13
	var stage := rng.randi_range(0, Content.STAGES.size() - 1)
	var hero := rng.randi_range(0, Content.HEROES.size() - 1)
	var pool: Array = MODS.duplicate()
	var mods: Array = []
	for k in 2: mods.append(pool.pop_at(rng.randi_range(0, pool.size() - 1)))
	return {"mode": "campaign", "stage": stage, "hero": hero, "mods": mods, "seed": s, "daily": true, "code": code_for(s),
		"moon": -1.0, "torment": 0, "prophecy": {}}

static func today() -> Dictionary:
	var c := config(seed_for_date(date_key()))
	c["date"] = date_key()
	return c

static func score(w: World) -> int:
	return w.kills + int(w.t) * 2 + (1500 if w.won else 0) + int(w.hoard_banked * 0.5)
