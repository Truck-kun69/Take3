class_name VoiceDirector
extends Node
## When a run speaks: the narrator's act opening as a campaign run starts; a boss's spawn line, then the exile's
## reply; the boss's die line; the ultimate; the first drop under 30% life (again once back over 50%); kill
## streaks of 25, 50, 100, 200, 400 and 800; now and then a weapon cast in a fight; and the exile's death.
## VoiceBank's priorities and cooldowns decide what is actually heard. Presentation only: it watches the World
## (its moment and ended signals, life, combo and last cast) and never changes it.

const LOW_HP := 0.3
const REARM_HP := 0.5
const STREAKS := [25, 50, 100, 200, 400, 800]
const REPLY_GAP_S := 0.4
var bank: VoiceBank
var manual_clock := false
var cast_chance := 0.3          # how often a cast in a fight tries a bark (the bank's 7 s cooldown and 2.8 s gap still apply)
var cast_min_foes := 8          # "in a fight": at least this many foes alive
var w: World
var hero := ""
var _t := 0.0
var _queue: Array = []          # [time, speaker, cue, opts], oldest first
var _hp_armed := true
var _streak := 0
var _last_cast := -9.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	if bank == null: bank = VoiceBank.current

func bind(world: World) -> void:
	unbind()
	w = world
	if w == null: return
	if bank == null: bank = VoiceBank.current
	hero = String(Content.HEROES[clampi(w.hero, 0, Content.HEROES.size() - 1)].id)
	w.moment.connect(_on_moment)
	w.ended.connect(_on_ended)
	_hp_armed = true
	_streak = 0
	_last_cast = w.cast_t
	if w.mode == "campaign" and bank != null: bank.say("narrator", "act_%d" % clampi(w.stage, 0, 4))

func unbind() -> void:
	if w != null and is_instance_valid(w):
		if w.moment.is_connected(_on_moment): w.moment.disconnect(_on_moment)
		if w.ended.is_connected(_on_ended): w.ended.disconnect(_on_ended)
	w = null
	_queue.clear()

func _process(dt: float) -> void:
	if not manual_clock: step(dt)

func step(dt: float) -> void:
	_t += dt
	while not _queue.is_empty() and _t >= float(_queue[0][0]):
		var q: Array = _queue.pop_front()
		if bank != null: bank.say(String(q[1]), String(q[2]), -1, q[3])
	if w == null or w.over or bank == null: return
	var frac := w.hp / maxf(1.0, w.max_hp)
	if frac > REARM_HP:
		_hp_armed = true
	elif _hp_armed and frac > 0.0 and frac < LOW_HP:
		if bool(bank.say(hero, "low_hp").played): _hp_armed = false
	if w.combo < 10:
		_streak = 0
	elif _streak < STREAKS.size() and w.combo >= int(STREAKS[_streak]):
		while _streak < STREAKS.size() and w.combo >= int(STREAKS[_streak]): _streak += 1
		bank.say(hero, "kill_streak")
	if w.cast_t > _last_cast:
		_last_cast = w.cast_t
		if w.sw.n >= cast_min_foes and _rng.randf() < cast_chance: bank.say(hero, "cast")

func _on_moment(kind: String, info: Dictionary) -> void:
	if bank == null: return
	match kind:
		"boss_spawn":
			var r := bank.say(String(info.get("boss", "tyrant")), "spawn", -1, {"name": String(info.get("name", ""))})
			if bool(r.played): _queue.append([_t + float(r.duration) + REPLY_GAP_S, hero, "boss_spawn", {}])
			else: bank.say(hero, "boss_spawn")
		"boss_die":
			bank.say(String(info.get("boss", "tyrant")), "die", -1, {"name": String(info.get("name", ""))})
		"ult":
			bank.say(hero, "ult")

func _on_ended(win: bool) -> void:
	if win or bank == null: return
	_queue.clear()
	bank.say(hero, "death")
