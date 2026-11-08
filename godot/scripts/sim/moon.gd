class_name Moon
extends RefCounted
## The real sky over the player: the Moon's phase from the system clock, plus a few calendar omens.
##
## Phase is the fraction of the synodic month since a known new moon (2000-01-06 18:14 UTC); the
## mean month is 29.530589 days, so the estimate drifts by at most ~half a day against the true
## Moon, which is fine for a game. Only the new and full moon (±1.5 days) and the calendar omens
## change rules; the waxing and waning halves give a small nudge each. World takes the phase and
## date through its setup cfg ("moon", "sky_date") so tests and sims stay deterministic.

const SYNODIC := 29.530588853
const NEW_EPOCH := 947182440.0

const PHASES := {
	"new": {"name": "New Moon", "d": "The sky is empty. Eclipses come three times as often and the dark falls faster, but what it hides is richer (+20% rarity).",
		"mods": [["item_rarity", "inc", 0.2], ["dark_rate", "more", 1.25]], "eclipse": 3.0},
	"waxing": {"name": "Waxing", "d": "The Moon is growing: +5% experience.", "mods": [["xp_gain", "inc", 0.05]], "eclipse": 1.0},
	"full": {"name": "Full Moon", "d": "The hunter's lantern. The dark fades slowly and packs run thicker (+15% item quantity).",
		"mods": [["item_quantity", "inc", 0.15], ["dark_rate", "more", 0.6]], "eclipse": 0.5, "spawn": 1.15},
	"waning": {"name": "Waning", "d": "The Moon is shrinking: +10% gold.", "mods": [["gold_find", "inc", 0.1]], "eclipse": 1.0},
}

## Calendar omens: [month, first day, month, last day] (the range may wrap the new year).
const OMENS := {
	"veil": {"name": "The Veil is Thin", "d": "All Hallows: the Whisperer comes sooner and more often.", "from": [10, 24], "to": [11, 2], "whisper": 0.6},
	"longnight": {"name": "The Longest Night", "d": "Midwinter: the dark falls 25% faster; +20% gold.", "from": [12, 18], "to": [1, 3],
		"mods": [["dark_rate", "more", 1.25], ["gold_find", "inc", 0.2]]},
	"midsummer": {"name": "Midsummer", "d": "The shortest night: the light fades 40% slower.", "from": [6, 18], "to": [6, 25], "mods": [["dark_rate", "more", 0.6]]},
}

static func phase_at(unix: float) -> float:
	return fposmod((unix - NEW_EPOCH) / 86400.0 / SYNODIC, 1.0)

static func now() -> float:
	return phase_at(Time.get_unix_time_from_system())

static func today() -> Array:
	var d := Time.get_date_dict_from_system()
	return [int(d.month), int(d.day)]

## 0 = new, 0.5 = full.
static func phase_id(ph: float) -> String:
	if ph < 0.05 or ph > 0.95: return "new"
	if absf(ph - 0.5) < 0.05: return "full"
	return "waxing" if ph < 0.5 else "waning"

## Lit fraction of the disc (0 new, 1 full).
static func illumination(ph: float) -> float:
	return 0.5 * (1.0 - cos(TAU * ph))

## Descriptive name for the title screen, e.g. "Waxing Gibbous".
static func phase_name(ph: float) -> String:
	var id := phase_id(ph)
	if id == "new" or id == "full": return PHASES[id].name
	var q := absf(ph - 0.5)
	var shape := "Gibbous" if q < 0.2 else ("Quarter" if q < 0.3 else "Crescent")
	if shape == "Quarter": return "First Quarter" if ph < 0.5 else "Last Quarter"
	return ("Waxing " if ph < 0.5 else "Waning ") + shape

static func omen_id(md: Array) -> String:
	if md.size() < 2: return ""
	var v := int(md[0]) * 100 + int(md[1])
	for id in OMENS:
		var a: int = OMENS[id].from[0] * 100 + OMENS[id].from[1]
		var b: int = OMENS[id].to[0] * 100 + OMENS[id].to[1]
		if (a <= b and v >= a and v <= b) or (a > b and (v >= a or v <= b)):
			return id
	return ""

## Stat modifiers for a phase (negative phase: no sky, e.g. tests) and a date.
static func mods(ph: float, md: Array) -> Array:
	var out: Array = []
	if ph >= 0.0: out.append_array(PHASES[phase_id(ph)].mods)
	var o := omen_id(md)
	if o != "": out.append_array(OMENS[o].get("mods", []))
	return out

static func eclipse_weight(ph: float) -> float:
	return float(PHASES[phase_id(ph)].eclipse) if ph >= 0.0 else 1.0

static func spawn_mult(ph: float) -> float:
	return float(PHASES[phase_id(ph)].get("spawn", 1.0)) if ph >= 0.0 else 1.0

static func whisper_mult(md: Array) -> float:
	var o := omen_id(md)
	return float(OMENS[o].get("whisper", 1.0)) if o != "" else 1.0
