class_name WhatsNew
extends RefCounted
## "What's new" (0.11.2): shown once on the title after an update to a profile that has played, listing what changed
## in every version since the one it last saw (Save.data.seen_version). A new profile never sees it (the tutorial
## covers it), and it can be reread from Captain Brask's page. Newest first; keep each version to a few lines.

const NOTES := {
	"0.11.2": [
		["Salvage on the way", "Nim can break down weak Normal or Magic finds as you pick them up. Set it at his bench."],
		["New finds marked", "Items found since your last look are marked NEW on the Gear page, and the stash shows how full it is."],
	],
	"0.11.1": [
		["The Wayside Forge", "In a run, Doran's apprentice may set up an anvil: hone a weapon you carry for 80 gold a rank."],
		["A safer stash", "A full stash never throws away a Legendary or an item you locked."],
		["Tempers in runs", "Level-up cards name a weapon's temper, and a kindled pair says when its fusion is ready."],
	],
	"0.11.0": [
		["The Camp", "Between runs, where Gear was: temper weapons, fuse and salvage gear, trade, and learn the ropes."],
		["Rift Ore and Shard Scrap", "Runs bring back ore and salvage gives scrap; the smith and the furnace use both."],
		["Captain Brask's tips", "New exiles get one tip at a time in their first campaign runs. Options > Game turns them off."],
	],
}

## 0.11.2-alpha -> 1102 (major, minor, patch), for ordering.
static func key(v: String) -> int:
	var p := v.split("-")[0].split(".")
	var k := 0
	for i in 3:
		k = k * 100 + (int(p[i]) if i < p.size() else 0)
	return k

## The notes newer than `seen`, newest first: [[version, [[title, text], ...]], ...].
static func since(seen: String) -> Array:
	var ks := key(seen) if seen != "" else 0
	var vs: Array = NOTES.keys()
	vs.sort_custom(func(a, b): return key(a) > key(b))
	var out: Array = []
	for v in vs:
		if key(v) > ks: out.append([v, NOTES[v]])
	return out

## Show it now: the profile has played, has not seen this version, and there is something newer to say.
static func due(d: Dictionary, ver: String) -> bool:
	if int((d.get("stats", {}) as Dictionary).get("runs", 0)) <= 0: return false
	var seen := String(d.get("seen_version", ""))
	return seen != ver and not since(seen if seen != "" else "0.10.6").is_empty()
