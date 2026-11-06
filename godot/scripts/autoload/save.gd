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
	"show_fps": false, "quality": 1, "ui_scale": 1.0, "force_touch_ui": false, "renderer": 0,
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
		"version": VERSION, "gold": 0, "hero": 0, "cleared": [false, false, false, false],
		"options": DEFAULT_OPTIONS.duplicate(), "stash": [], "equipped": eq, "currency": cur,
		"codex": [], "codex_active": [], "bestiary": {}, "lore": [],
		"fragments": {"rupture": 0, "greed": 0, "dread": 0}, "splinters": 0,
		"nemesis": {}, "gr_key": 1, "gr_best": 0, "atlas": {}, "herald_kills": 0,
		"stats": {"runs": 0, "kills": 0, "deaths": 0, "playtime": 0.0, "best_combo": 0},
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
		if typeof(dst[k]) == TYPE_DICTIONARY and typeof(src[k]) == TYPE_DICTIONARY and not ["atlas", "bestiary", "nemesis", "equipped"].has(k):
			_merge(dst[k], src[k])
		else:
			dst[k] = src[k]

func _normalise() -> void:
	data.gold = int(data.gold); data.hero = clampi(int(data.hero), 0, 3)
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

func has_nemesis() -> bool:
	return not data.nemesis.is_empty()
