extends Node
## Persistent profile: meta currency, stash, equipped gear, crafting currency, codex (extracted
## legendary powers), bestiary, lore pages, pinnacle fragments, nemesis, rift keys, atlas and options.
## Writes are atomic (temp file + rename) and debounced, so a crash mid-write cannot corrupt the save.

const VERSION := 2
var path := "user://profile.json"
var data: Dictionary = {}
var _dirty := false
var _t := 0.0

const DEFAULT_OPTIONS := {
	"sound": true, "volume": 0.8, "shake": 1.0, "dmg_numbers": 2,   # 0 off, 1 crits/reactions only, 2 all
	"colorblind": false, "reduce_flash": false, "haptics": true, "aim": 0,   # 0 nearest, 1 strongest, 2 facing
	"joy_mode": 0, "left_handed": false, "auto_equip": true, "loot_filter": 0,   # 0 all, 1 hide normal, 2 rare+
	"show_fps": false, "quality": 1, "gfx": 0, "gpu_crowd": 0, "ambient": true, "sfx_safe": false, "frame_cap": 0, "gfx_off": [], "ui_scale": 1.0, "force_touch_ui": false, "renderer": 0, "render_scale": 0,
}

func _ready() -> void:
	load_profile()

func defaults() -> Dictionary:
	var cur := {}
	for c in Content.CURRENCY_IDS:
		cur[c] = 0
	cur["transmute"] = 4
	cur["augment"] = 2
	var eq := {}
	for s in Content.SLOTS:
		eq[s] = {}
	return {
		"version": VERSION, "gold": 0, "hero": 0, "cleared": [false, false, false, false, false],
		"options": DEFAULT_OPTIONS.duplicate(), "stash": [], "equipped": eq, "currency": cur,
		"codex": [], "codex_active": [], "bestiary": {}, "lore": [],
		"fragments": {"rupture": 0, "greed": 0, "dread": 0}, "splinters": 0,
		"passives": ["start"], "echoes": 0, "torment": 0, "torment_max": 0,
		"nemesis": {}, "gr_key": 1, "gr_best": 0, "atlas": {}, "herald_kills": 0,
		"stats": {"runs": 0, "kills": 0, "deaths": 0, "playtime": 0.0, "best_combo": 0, "champions": 0},
		"unlocked": [],                                  # weapon ids earned on the unlock track (Content.UNLOCKS)
		"selftest": {}, "bench": {},
		"prophecy": {"offers": [], "active": {}, "done": 0},
		"daily": {"best": {}, "claimed": ""},            # best: code -> score (newest 30); claimed: date of the last first-clear reward   # offers: [[id, [reward ids]]], active: {id, reward}          # graphics self-test progress (survives a crash), last benchmark
	}

func load_profile() -> void:
	data = defaults()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("profile unreadable, starting fresh")
		return
	_merge(data, parsed)
	_normalise()

## Copy keys from src into dst where dst has the key (forward compatible: unknown keys are dropped,
## missing keys keep their defaults).
func _merge(dst: Dictionary, src: Dictionary) -> void:
	for k in dst:
		if not src.has(k):
			continue
		if typeof(dst[k]) == TYPE_DICTIONARY and typeof(src[k]) == TYPE_DICTIONARY and not ["atlas", "bestiary", "nemesis", "equipped", "selftest", "bench", "prophecy", "daily"].has(k):
			_merge(dst[k], src[k])
		else:
			dst[k] = src[k]

func _normalise() -> void:
	data.gold = int(data.gold); data.hero = clampi(int(data.hero), 0, 3)
	while data.cleared.size() < Content.STAGES.size(): data.cleared.append(false)      # profiles from before Act V
	data.echoes = int(data.echoes); data.torment_max = clampi(int(data.torment_max), 0, Content.TORMENT.size() - 1)
	data.torment = clampi(int(data.torment), 0, int(data.torment_max))
	var pv: Array = []
	for id in data.passives:
		if Content.PASSIVES.has(String(id)) and not pv.has(String(id)): pv.append(String(id))
	if not pv.has("start"): pv.push_front("start")
	data.passives = pv
	data.gr_key = maxi(1, int(data.gr_key)); data.gr_best = int(data.gr_best); data.splinters = int(data.splinters)
	for c in data.currency: data.currency[c] = int(data.currency[c])
	for k in data.fragments: data.fragments[k] = int(data.fragments[k])
	for k in data.bestiary: data.bestiary[k] = int(data.bestiary[k])
	var lore: Array = []
	for p in data.lore: lore.append(int(p))
	data.lore = lore
	var st: Array = []
	for it in data.stash:
		var n := Items.normalise(it)
		if Items.valid(n): st.append(n)
	data.stash = st
	var eq := {}
	for s in Content.SLOTS:
		var it = data.equipped.get(s, {})
		eq[s] = Items.normalise(it) if (typeof(it) == TYPE_DICTIONARY and not it.is_empty() and Items.valid(Items.normalise(it))) else {}
	data.equipped = eq

func mark_dirty() -> void:
	_dirty = true

func _process(dt: float) -> void:
	_t += dt
	if _dirty and _t > 1.0:
		flush()

func flush() -> void:
	_dirty = false
	_t = 0.0
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("cannot write profile")
		return
	f.store_string(JSON.stringify(data))
	f.close()
	var d := DirAccess.open("user://")
	if d:
		d.rename(tmp.get_file(), path.get_file())

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if _dirty: flush()

# ---------------------------------------------------------------- helpers
## Weapons a run may offer: the four starters plus everything earned.
func weapon_pool() -> Array:
	var out: Array = []
	var locked := {}
	for u in Content.UNLOCKS: locked[u.w] = true
	for id in Content.WEAPON_IDS:
		if not locked.has(id) or data.unlocked.has(id): out.append(id)
	return out

## Progress toward one unlock: [have, need].
func unlock_progress(u: Dictionary) -> Array:
	var have := 0
	if u.stat == "cleared":
		for c in data.cleared:
			if c: have += 1
	else:
		have = int(data.stats.get(u.stat, 0))
	return [mini(have, int(u.need)), int(u.need)]

## Grants every unlock whose condition is now met; returns the newly earned weapon ids.
func check_unlocks() -> Array:
	var got: Array = []
	for u in Content.UNLOCKS:
		if data.unlocked.has(u.w): continue
		var pr := unlock_progress(u)
		if pr[0] >= pr[1]:
			data.unlocked.append(u.w)
			got.append(u.w)
	if not got.is_empty(): mark_dirty()
	return got

func opt(k: String):
	return data.options.get(k, DEFAULT_OPTIONS.get(k))

func set_opt(k: String, v) -> void:
	data.options[k] = v
	mark_dirty()

func add_currency(id: String, n: int = 1) -> void:
	data.currency[id] = int(data.currency.get(id, 0)) + n
	mark_dirty()

func bestiary_count(kind_id: String) -> int:
	return int(data.bestiary.get(kind_id, 0))

func bestiary_tier(kind_id: String) -> int:
	var c := bestiary_count(kind_id)
	var t := 0
	for th in Content.BESTIARY_TIERS:
		if c >= th: t += 1
	return t

func lore_sets() -> int:
	return data.lore.size() / Content.LORE_SET

func season() -> Dictionary:
	var week := int(Time.get_unix_time_from_system() / 604800.0)
	return Content.SEASONS[week % Content.SEASONS.size()]

## Three prophecies on offer, each with three reward choices; rerolled after one is fulfilled or abandoned.
func prophecy_offers() -> Array:
	var P: Dictionary = data.prophecy
	if P.offers.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var ids: Array = Content.PROPHECY_IDS.duplicate()
		var act: Dictionary = P.active
		if not act.is_empty(): ids.erase(act.id)
		for k in 3:
			var id: String = ids.pop_at(rng.randi_range(0, ids.size() - 1))
			var rw: Array = Content.PROPHECY_REWARD_IDS.duplicate()
			var pick: Array = []
			for r in 3: pick.append(rw.pop_at(rng.randi_range(0, rw.size() - 1)))
			P.offers.append([id, pick])
		mark_dirty()
	return P.offers

func has_nemesis() -> bool:
	return not data.nemesis.is_empty()
