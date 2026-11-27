class_name Buffs
extends RefCounted
## Timed buffs with explicit stacking policies, feeding modifiers into a Stats pipeline.
##   REFRESH   - reapplying resets the timer (pylons, shrines)
##   INTENSITY - each application adds a stack up to `max`; stacks share one timer (Soul Harvest)
##   DURATION  - each application extends the timer up to `max_dur` (flasks)
##   UNIQUE    - cannot be reapplied while active (Aegis)
## Pylons additionally have diminishing returns: the same pylon within 60s lasts half as long.

var stats: Stats
var list: Array = []                  # [{id, t, dur, stacks}]
var _last_pylon: Dictionary = {}      # id -> run time it was last taken
var now := 0.0

func _init(s: Stats) -> void:
	stats = s

func find(id: String) -> int:
	for i in list.size():
		if list[i].id == id:
			return i
	return -1

func has(id: String) -> bool:
	return find(id) >= 0

func stacks(id: String) -> int:
	var i := find(id)
	return 0 if i < 0 else int(list[i].stacks)

func remaining(id: String) -> float:
	var i := find(id)
	return 0.0 if i < 0 else float(list[i].t)

## Returns false when the policy rejected the application.
func add(id: String, dur_mult: float = 1.0) -> bool:
	var def: Dictionary = Content.BUFFS[id]
	var dur: float = float(def.dur) * dur_mult
	if def.get("pylon", false):
		if _last_pylon.has(id) and now - float(_last_pylon[id]) < 60.0:
			dur *= 0.5
		_last_pylon[id] = now
	var i := find(id)
	var policy: int = def.policy
	if i < 0:
		list.append({"id": id, "t": dur, "dur": dur, "stacks": 1})
	else:
		var b: Dictionary = list[i]
		match policy:
			Content.Stack.UNIQUE:
				return false
			Content.Stack.REFRESH:
				b.t = maxf(b.t, dur)
				b.dur = maxf(b.dur, dur)
			Content.Stack.INTENSITY:
				b.stacks = mini(int(b.stacks) + 1, int(def.get("max", 99)))
				b.t = dur
				b.dur = dur
			Content.Stack.DURATION:
				b.t = minf(b.t + dur, float(def.get("max_dur", dur * 2.0)))
				b.dur = maxf(b.dur, b.t)
	_apply(id)
	return true

func remove(id: String) -> void:
	var i := find(id)
	if i >= 0:
		list.remove_at(i)
		stats.clear_source("buff:" + id)

func _apply(id: String) -> void:
	var i := find(id)
	var def: Dictionary = Content.BUFFS[id]
	stats.set_source("buff:" + id, def.mods, float(list[i].stacks))

func step(dt: float) -> void:
	now += dt
	var i := list.size() - 1
	while i >= 0:
		var b: Dictionary = list[i]
		b.t -= dt
		if b.t <= 0.0:
			stats.clear_source("buff:" + String(b.id))
			list.remove_at(i)
		i -= 1
