class_name Stats
extends RefCounted
## PoE-style stat pipeline:  final = (base + sum(added)) * (1 + sum(increased)) * prod(more)
## Modifiers are grouped by source ("perk:might", "item:ring", "buff:power", "gem:bolt:chain", ...)
## so a whole source can be replaced or removed atomically when an item is swapped or a buff ends.
## Per-key components are cached and only rebuilt for keys touched since the last read.

var _src: Dictionary = {}        # source -> Array of [key, kind, value]
var _cache: Dictionary = {}      # key -> Vector3(added, increased, more)
var _dirty: Dictionary = {}      # key -> true
var version := 0                 # bumps on any change; consumers can cheaply detect "something changed"

const KIND_ADD := 0
const KIND_INC := 1
const KIND_MORE := 2

static func kind_of(s: String) -> int:
	match s:
		"add": return KIND_ADD
		"inc": return KIND_INC
		_: return KIND_MORE

## Replace every modifier from `source` with `mods` ([[key, "add"|"inc"|"more", value], ...]).
## `scale` multiplies add/inc values and is applied as an exponent to "more" (stacking buffs).
func set_source(source: String, mods: Array, scale: float = 1.0) -> void:
	clear_source(source)
	if mods.is_empty() or scale == 0.0:
		return
	var list: Array = []
	for m in mods:
		var k: int = kind_of(m[1])
		var v: float = float(m[2])
		if k == KIND_MORE:
			v = pow(v, scale)
		else:
			v *= scale
		list.append([m[0], k, v])
		_dirty[m[0]] = true
	_src[source] = list
	version += 1

func clear_source(source: String) -> void:
	if not _src.has(source):
		return
	for m in _src[source]:
		_dirty[m[0]] = true
	_src.erase(source)
	version += 1

func has_source(source: String) -> bool:
	return _src.has(source)

func clear_prefix(prefix: String) -> void:
	for s in _src.keys():
		if String(s).begins_with(prefix):
			clear_source(s)

func components(key: String) -> Vector3:
	if _dirty.has(key) or not _cache.has(key):
		var a := 0.0
		var i := 0.0
		var m := 1.0
		for s in _src:
			for mod in _src[s]:
				if mod[0] != key:
					continue
				match mod[1]:
					KIND_ADD: a += mod[2]
					KIND_INC: i += mod[2]
					_: m *= mod[2]
		_cache[key] = Vector3(a, i, m)
		_dirty.erase(key)
	return _cache[key]

## Final value for `key` starting from `base`. Increased is floored at -90% so stacking
## "faster cooldown" or negative rolls can never invert a stat.
func value(key: String, base: float = 0.0, local: Stats = null) -> float:
	var c := components(key)
	if local != null:
		var l := local.components(key)
		c = Vector3(c.x + l.x, c.y + l.y, c.z * l.z)
	return (base + c.x) * maxf(0.1, 1.0 + c.y) * c.z

## Convenience for flag-like stats (anything added > 0).
func flag(key: String, local: Stats = null) -> bool:
	return value(key, 0.0, local) > 0.0

func sources() -> Array:
	return _src.keys()
