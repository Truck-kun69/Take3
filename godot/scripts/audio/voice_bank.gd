class_name VoiceBank
extends Node
## Voice lines: the manifest, playback rules, ducking and subtitle timing.
##
## res://data/voice_manifest.json is the one copy of every line (tools/gen_voices.py reads the same file to
## synthesise them). A line plays its .ogg when the file exists: drop a clip at the line's "file" path and the
## next build uses it, timed to its real length, with no script edits. Otherwise a short chime of the speaker's
## own (made here, below) stands in and the line is held for the manifest's duration_fallback_s. Either way the
## line speaks for that long: the subtitle stays up duration + 0.35 s, Music ducks 6 dB and SFX 3 dB
## (in over 0.12 s, back over 0.25 s), and the cold open waits for it.
##
## Rules (say): one line at a time. A higher priority cuts the current line off with a quick fade; an equal or
## lower one is refused while a line plays ("busy"). Each cue has its own cooldown_s, counted from its start
## ("cooldown"), and priority 0-1 barks also wait GLOBAL_GAP_S since the last line ended, or since the current
## one started ("gap"). Priorities: intro, boss_spawn, death, the act openings and the bosses' lines 3 > ult and
## low_hp 2 > kill_streak 1 > cast 0. An escalation line ("escalation": its trigger) answers a moment of its own
## (VoiceDirector asks for it by variant); "random": false keeps it out of its cue's ordinary picks.
## stop_all() is immediate: every player stops, the ducking is cancelled and Music and SFX are back at 0 dB.
##
## Memory: at most LRU_MAX clips stay loaded (a 4 GB phone shares its RAM with the GPU).
## Android: a player's stream is only set while it is stopped (swapping the stream of a playing player crashed
## the S22's audio, see Sfx), so lines take turns on a small pool of players.
##
## The autoload ("Voice") is VoiceBank.current, and VoiceBank.play() forwards to it. The tests build their own
## banks with manual_clock and step() them.

signal line_started(info: Dictionary)     # id, speaker, name, color, cue, text, duration, using_pack, subtitle_s, subtitle
signal line_ended(info: Dictionary)       # id, stopped (cut off or stopped, rather than finished)

const MANIFEST := "res://data/voice_manifest.json"
const GLOBAL_GAP_S := 2.8
const GAP_MAX_PRIORITY := 1
const REPEAT_S := 90.0                   # a line of priority 0-2 is not said again within this (an escalation line,
                                         # twice this); a random bark with every variant that recent is skipped
                                         # ("repeat"), never repeated. Story lines (priority 3) always play.
const REPEAT_MAX_PRIORITY := 2
const DUCK_MUSIC_DB := -6.0
const DUCK_SFX_DB := -3.0
const DUCK_ATTACK_S := 0.12
const DUCK_RELEASE_S := 0.25
const LRU_MAX := 16
const SUBTITLE_PAD_S := 0.35
const STOP_FADE_S := 0.08
const PLAYERS := 3
const VOICE_BUSES := ["VoiceHero", "VoiceNarrator", "VoiceBoss"]
const REQUIRED := ["id", "speaker", "cue", "file", "text", "priority", "cooldown_s", "duration_fallback_s"]

static var current: VoiceBank

var manual_clock := false
var now := 0.0                       # the bank's own clock, in seconds
var entries := {}                    # id -> line (the manifest's dictionaries)
var casting := {}                    # speaker -> profile: name, bus, color and the ElevenLabs parameters
var errors := PackedStringArray()
var _cues := {}                      # "speaker/cue" -> lines, by variant
var _players: Array[AudioStreamPlayer] = []
var _cur := {}                       # the line speaking: line, start, ends, player, using_pack
var _cool := {}                      # "speaker/cue" -> when it may play again
var _last_end := -1.0e9
var _last_variant := {}
var _said := {}                       # line id -> when it last started (the barks' REPEAT_S)
var _fades: Array = []               # [player, seconds left, seconds total, from dB]
var _duck := 0.0
var _duck_applied := -1.0
var _base := {}                      # bus index -> its level before ducking, and the depth it ducks by
var _chimes := {}
var _warm: Array = []
var _lru := {}                       # path -> AudioStream
var _lru_order: Array[String] = []
var _rng := RandomNumberGenerator.new()
## A headless run (the tests, the gate's boot check) has no audio device: lines run on the clock, subtitled and
## ducking as usual, but nothing is started on a player (a chime still playing when `--quit` tears the engine down
## after one frame leaked its stream and playback).
var _device := DisplayServer.get_name() != "headless"

static func play(speaker: String, cue: String, variant: int = -1, opts: Dictionary = {}) -> Dictionary:
	if current == null: return {"played": false, "reason": "no voice bank"}
	return current.say(speaker, cue, variant, opts)

## Stops every voice at once (the fade argument is kept for old callers and ignored): see stop_now().
static func stop_all(_fade: float = 0.0) -> void:
	if current != null: current.stop_now()

static func subtitle_seconds(duration: float) -> float:
	return maxf(0.0, duration) + SUBTITLE_PAD_S

func _enter_tree() -> void:
	if current == null: current = self

func _exit_tree() -> void:
	if current == self: current = null
	for p in _players: p.stop()
	_duck = 0.0
	_apply_duck()

func _ready() -> void:
	_rng.randomize()
	load_manifest()
	for k in PLAYERS:
		var p := AudioStreamPlayer.new()
		p.bus = &"VoiceHero"
		p.finished.connect(_on_finished.bind(p))
		add_child(p)
		_players.append(p)
	for b in [["Music", DUCK_MUSIC_DB], ["SFX", DUCK_SFX_DB]]:
		var i := AudioServer.get_bus_index(b[0])
		if i >= 0: _base[i] = [AudioServer.get_bus_volume_db(i), float(b[1])]
	_warm = casting.keys()

func _process(dt: float) -> void:
	if not _warm.is_empty() and not manual_clock: chime(String(_warm.pop_back()))   # one chime a frame, off the first bark
	if not manual_clock: step(dt)

# ---------------------------------------------------------------- manifest
func load_manifest(path: String = MANIFEST) -> bool:
	entries = {}
	casting = {}
	_cues = {}
	errors = PackedStringArray()
	if not FileAccess.file_exists(path):
		errors.append("missing " + path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("not a JSON object: " + path)
		return false
	casting = parsed.get("casting", {})
	for e in parsed.get("lines", []):
		if typeof(e) != TYPE_DICTIONARY:
			errors.append("a line that is not an object")
			continue
		var miss: Array = []
		for k in REQUIRED:
			if not e.has(k): miss.append(k)
		if not miss.is_empty():
			errors.append("%s: missing %s" % [e.get("id", "?"), ", ".join(miss)])
			continue
		var id := String(e.id)
		if entries.has(id):
			errors.append("duplicate id " + id)
			continue
		if not casting.has(String(e.speaker)): errors.append("%s: no casting for %s" % [id, e.speaker])
		e.priority = int(e.priority)
		e.cooldown_s = float(e.cooldown_s)
		e.duration_fallback_s = float(e.duration_fallback_s)
		e["variant"] = int(e.get("variant", 0))
		entries[id] = e
		var key := "%s/%s" % [e.speaker, e.cue]
		if not _cues.has(key): _cues[key] = []
		_cues[key].append(e)
	for key in _cues: _cues[key].sort_custom(func(a, b): return int(a.variant) < int(b.variant))
	return errors.is_empty()

func variants(speaker: String, cue: String) -> int:
	return _cues.get("%s/%s" % [speaker, cue], []).size()

func line(speaker: String, cue: String, variant: int) -> Dictionary:
	var list: Array = _cues.get("%s/%s" % [speaker, cue], [])
	return list[variant] if variant >= 0 and variant < list.size() else {}

## How long a line speaks when played: its clip's length once the voice pack is in, the manifest's estimate
## until then (the cold open lays its camera sweep over the sum before it starts).
func duration_of(speaker: String, cue: String, variant: int) -> float:
	var ln := line(speaker, cue, variant)
	if ln.is_empty(): return 0.0
	var path := String(ln.file)
	if ResourceLoader.exists(path):
		var st := cache_get(path)
		if st == null:
			st = load(path) as AudioStream
			if st != null: cache_put(path, st)
		if st != null and st.get_length() > 0.0: return st.get_length()
	return float(ln.duration_fallback_s)

# ---------------------------------------------------------------- playback
## Plays one line of speaker's cue (variant -1: any but the one played last). Returns {played, using_pack,
## duration, text, speaker, id, cue, variant}, or {played: false, reason}. opts: "name" overrides the subtitle's
## speaker name (the act's boss), "subtitle": false keeps it off the subtitle banner (the intro shows its own text).
func say(speaker: String, cue: String, variant: int = -1, opts: Dictionary = {}) -> Dictionary:
	var key := "%s/%s" % [speaker, cue]
	var list: Array = _cues.get(key, [])
	if list.is_empty(): return _no("unknown cue " + key)
	var ln: Dictionary
	if variant >= 0:
		if variant >= list.size(): return _no("no variant %d of %s" % [variant, key])
		ln = list[variant]
		if int(ln.priority) <= REPEAT_MAX_PRIORITY and _said_lately(ln): return _no("repeat")
	elif int(list[0].priority) <= GAP_MAX_PRIORITY:     # a bark: only lines not said lately
		var fresh := list.filter(func(e): return bool(e.get("random", true)) and not _said_lately(e))
		if fresh.is_empty(): return _no("repeat")
		ln = _pick(key, fresh)
	else:
		ln = _pick(key, list)
	var pr := int(ln.priority)
	if not _cur.is_empty() and pr <= int(_cur.line.priority): return _no("busy")
	if now < float(_cool.get(key, -1.0e9)): return _no("cooldown")
	if pr <= GAP_MAX_PRIORITY and now - (float(_cur.start) if not _cur.is_empty() else _last_end) < GLOBAL_GAP_S: return _no("gap")
	if not _cur.is_empty(): _end_line(true, STOP_FADE_S)
	var stream: AudioStream = null
	var using_pack := false
	var path := String(ln.file)
	if ResourceLoader.exists(path):
		stream = cache_get(path)
		if stream == null:
			stream = load(path) as AudioStream
			if stream != null: cache_put(path, stream)
		using_pack = stream != null
	var dur := float(ln.duration_fallback_s)
	if using_pack:
		_no_loop(stream)
		if stream.get_length() > 0.0: dur = stream.get_length()
	else:
		stream = chime(speaker)
	var p := _free_player()
	p.bus = _bus(speaker)
	p.volume_db = 0.0                    # the Master and Voice buses carry the player's levels (Save.apply_audio)
	p.stream = stream
	if bool(Save.opt("sound")) and _device: p.play()
	_cur = {"line": ln, "start": now, "ends": now + dur, "player": p, "using_pack": using_pack}
	_cool[key] = now + float(ln.cooldown_s)
	_last_variant[key] = int(ln.variant)
	_said[String(ln.id)] = now
	var prof: Dictionary = casting.get(speaker, {})
	line_started.emit({"id": String(ln.id), "speaker": speaker, "name": String(opts.get("name", "")) if String(opts.get("name", "")) != "" else String(prof.get("name", speaker.capitalize())),
		"color": Color(String(prof.get("color", "e9e1cf"))), "cue": cue, "text": String(ln.text), "duration": dur, "using_pack": using_pack,
		"subtitle_s": subtitle_seconds(dur), "subtitle": bool(opts.get("subtitle", true))})
	Diag.first("voice " + ("clip" if using_pack else "chime"))
	return {"played": true, "using_pack": using_pack, "duration": dur, "text": String(ln.text), "speaker": speaker, "id": String(ln.id), "cue": cue, "variant": int(ln.variant)}

## Hero select: the new exile's intro replaces whatever was playing, the last exile's intro included.
func preview_hero(hero_id: String) -> Dictionary:
	stop(0.05)
	return say(hero_id, "intro", 0)

func stop(fade: float = STOP_FADE_S) -> void:
	_end_line(true, fade)

## Everything silent now: the line ends (stopped), every player stops (fading ones too), the ducking is cancelled
## and the Music and SFX buses are set back to 0 dB.
func stop_now() -> void:
	_end_line(true, 0.0)
	for p in _players: p.stop()
	_fades.clear()
	_duck = 0.0
	_duck_applied = 0.0
	for i in _base:
		_base[i][0] = 0.0
		AudioServer.set_bus_volume_db(i, 0.0)

## The variant of speaker's cue that answers `trigger` (an escalation line), or -1.
func escalation_variant(speaker: String, trigger: String) -> int:
	for e in _cues.get(_escalation_cue(speaker, trigger), []):
		if String(e.get("escalation", "")) == trigger: return int(e.variant)
	return -1

func _escalation_cue(speaker: String, trigger: String) -> String:
	for key in _cues:
		if not String(key).begins_with(speaker + "/"): continue
		for e in _cues[key]:
			if String(e.get("escalation", "")) == trigger: return key
	return ""

func is_speaking() -> bool:
	return not _cur.is_empty()

func remaining() -> float:
	return maxf(0.0, float(_cur.ends) - now) if not _cur.is_empty() else 0.0

func active_player() -> AudioStreamPlayer:
	return _cur.player if not _cur.is_empty() else null

func active_id() -> String:
	return String(_cur.line.id) if not _cur.is_empty() else ""

func active_cue() -> String:
	return String(_cur.line.cue) if not _cur.is_empty() else ""

func active_speaker() -> String:
	return String(_cur.line.speaker) if not _cur.is_empty() else ""

## Advances the bank's clock: a line ends at its length (a clip's real one, or the manifest's estimate), cut-off
## lines fade out, and the ducking follows. Steps split at a line's end, so any dt lands exactly.
func step(dt: float) -> void:
	var left := maxf(0.0, dt)
	for _i in 8:
		var h := left
		if not _cur.is_empty(): h = minf(h, maxf(0.0, float(_cur.ends) - now))
		_advance(h)
		left -= h
		if not _cur.is_empty() and now >= float(_cur.ends) - 1e-6: _end_line(false, 0.0)
		if left <= 1e-9: break

func _advance(h: float) -> void:
	now += h
	var target := 1.0 if not _cur.is_empty() else 0.0
	if h > 0.0 and _duck != target:
		_duck = move_toward(_duck, target, h / (DUCK_ATTACK_S if target > _duck else DUCK_RELEASE_S))
	_apply_duck()
	for i in range(_fades.size() - 1, -1, -1):
		var f: Array = _fades[i]
		f[1] = float(f[1]) - h
		var q: AudioStreamPlayer = f[0]
		if float(f[1]) <= 0.0:
			q.stop()
			_fades.remove_at(i)
		else:
			q.volume_db = lerpf(-60.0, float(f[3]), float(f[1]) / float(f[2]))

func _apply_duck() -> void:
	if is_equal_approx(_duck, _duck_applied): return
	_duck_applied = _duck
	for i in _base:
		AudioServer.set_bus_volume_db(i, float(_base[i][0]) + float(_base[i][1]) * _duck)

func _end_line(stopped: bool, fade: float) -> void:
	if _cur.is_empty(): return
	var p: AudioStreamPlayer = _cur.player
	if stopped and p.playing:
		if fade > 0.0: _fades.append([p, fade, fade, p.volume_db])
		else: p.stop()
	var id := String(_cur.line.id)
	_last_end = now
	_cur = {}
	line_ended.emit({"id": id, "stopped": stopped})

## A clip that finishes before the clock says so ends its line (a chime is short: its line runs on the clock).
func _on_finished(p: AudioStreamPlayer) -> void:
	if not _cur.is_empty() and _cur.player == p and bool(_cur.using_pack): _end_line(false, 0.0)

func _free_player() -> AudioStreamPlayer:
	for p in _players:
		var fading := false
		for f in _fades:
			if f[0] == p: fading = true
		if not p.playing and not fading: return p
	var q := _players[0]
	for i in range(_fades.size() - 1, -1, -1):
		if _fades[i][0] == q: _fades.remove_at(i)
	q.stop()
	return q

## Whether a line started within its repeat window: REPEAT_S, or twice that for an escalation line ("random": false).
func _said_lately(e: Dictionary) -> bool:
	var win := REPEAT_S * (2.0 if not bool(e.get("random", true)) else 1.0)
	return now - float(_said.get(String(e.id), -1.0e9)) < win

func _pick(key: String, list: Array) -> Dictionary:
	var open := list.filter(func(e): return bool(e.get("random", true)))     # escalation-only lines wait for their moment
	if not open.is_empty() and open.size() < list.size():
		list = open
		var last0 := int(_last_variant.get(key, -1))
		var others := list.filter(func(e): return int(e.variant) != last0)
		return others[_rng.randi_range(0, others.size() - 1)] if not others.is_empty() else list[0]
	if list.size() == 1: return list[0]
	var last := int(_last_variant.get(key, -1))
	if last < 0: return list[_rng.randi_range(0, list.size() - 1)]
	var k := _rng.randi_range(0, list.size() - 2)
	if k >= last: k += 1
	return list[k]

func _bus(speaker: String) -> StringName:
	var b := String(casting.get(speaker, {}).get("bus", "VoiceHero"))
	return StringName(b if VOICE_BUSES.has(b) else "VoiceHero")

func _no(why: String) -> Dictionary:
	return {"played": false, "using_pack": false, "duration": 0.0, "text": "", "speaker": "", "reason": why}

func _no_loop(s: AudioStream) -> void:
	if s is AudioStreamOggVorbis: (s as AudioStreamOggVorbis).loop = false
	elif s is AudioStreamMP3: (s as AudioStreamMP3).loop = false
	elif s is AudioStreamWAV: (s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED

# ---------------------------------------------------------------- clip cache
func cache_get(path: String) -> AudioStream:
	if not _lru.has(path): return null
	_lru_order.erase(path)
	_lru_order.append(path)
	return _lru[path]

func cache_put(path: String, s: AudioStream) -> void:
	if _lru.has(path): _lru_order.erase(path)
	_lru[path] = s
	_lru_order.append(path)
	while _lru_order.size() > LRU_MAX:
		_lru.erase(_lru_order.pop_front())

func cache_has(path: String) -> bool:
	return _lru.has(path)

func cache_size() -> int:
	return _lru.size()

# ---------------------------------------------------------------- chimes
## Stand-ins until the voice pack exists: a few sung syllables per speaker, each a single-cycle wavetable of
## harmonics shaped by two vowel formants, so a chime reads as that character's voice. Per speaker: pitch (Hz),
## syllables [seconds, pitch ratio, F1, F2], gap between them (s), breath (smoky noise), bell (a glassy
## inharmonic partial), tilt (harmonic roll-off: lower is brighter).
const CHIMES := {
	"warden": [105.0, [[0.13, 1.0, 500, 900], [0.11, 0.94, 700, 1150], [0.18, 0.86, 450, 800]], 0.04, 0.0, 0.0, 0.7],
	"spark": [280.0, [[0.06, 1.0, 300, 2300], [0.055, 1.12, 450, 1900], [0.06, 1.05, 750, 1250], [0.05, 1.2, 300, 2300], [0.09, 1.32, 450, 1950]], 0.02, 0.0, 0.15, 0.9],
	"ember": [165.0, [[0.11, 1.0, 750, 1200], [0.1, 1.08, 350, 750], [0.12, 0.96, 700, 1150], [0.16, 1.1, 380, 800]], 0.03, 0.35, 0.0, 0.8],
	"storm": [140.0, [[0.11, 1.0, 480, 1850], [0.11, 1.0, 500, 950], [0.11, 0.95, 480, 1850]], 0.05, 0.0, 0.1, 0.75],
	"narrator": [115.0, [[0.15, 1.0, 520, 920], [0.13, 0.97, 380, 760], [0.2, 0.9, 500, 880]], 0.05, 0.1, 0.0, 0.8],
	"tyrant": [72.0, [[0.2, 1.0, 480, 820], [0.26, 0.85, 640, 1050]], 0.06, 0.15, 0.0, 0.45],
	"herald": [392.0, [[0.16, 1.0, 300, 2500], [0.14, 1.335, 300, 2500], [0.22, 1.5, 300, 2500]], 0.03, 0.0, 0.6, 1.1],
}
const CHIME_RATE := 16000
const TABLE := 256

func chime(speaker: String) -> AudioStreamWAV:
	if _chimes.has(speaker): return _chimes[speaker]
	var d: Array = CHIMES.get(speaker, CHIMES.narrator)
	var f0: float = d[0]
	var syl: Array = d[1]
	var gap: float = d[2]
	var breath: float = d[3]
	var bell: float = d[4]
	var tilt: float = d[5]
	var total := 0.08
	for s in syl: total += float(s[0]) + gap
	var n := int(total * CHIME_RATE)
	var mix := PackedFloat32Array()
	mix.resize(n)
	var noise := RandomNumberGenerator.new()
	noise.seed = hash(speaker)
	var at := 0
	for s in syl:
		var slen := int(float(s[0]) * CHIME_RATE)
		var f := f0 * float(s[1])
		var tab := _formant_table(f, float(s[2]), float(s[3]), tilt)
		var inc := f / CHIME_RATE * TABLE
		var bell_w := TAU * f * 2.76 / CHIME_RATE
		var ph := 0.0
		var y := 0.0
		for i in slen:
			var t := float(i) / slen
			ph += inc
			if ph >= TABLE: ph -= TABLE
			var k := int(ph)
			var v: float = lerpf(tab[k], tab[(k + 1) % TABLE], ph - k)
			var u := 1.0 - t
			var env := minf(1.0, t * 18.0) * u * u
			if breath > 0.0:
				y = y * 0.72 + noise.randf_range(-1.0, 1.0) * 0.28
				v += y * breath * 2.2
			if bell > 0.0: v += sin(bell_w * i) * bell * u * u * u
			if at + i < n: mix[at + i] += v * env
		at += slen + int(gap * CHIME_RATE)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(tanh(mix[i] * 1.2) * 0.5, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = CHIME_RATE
	w.data = bytes
	_chimes[speaker] = w
	return w

## One cycle of a voiced vowel at pitch f: harmonics up to 4.5 kHz weighted by the formants F1 and F2 (the
## harmonics by recurrence: two trig calls per sample of the cycle).
func _formant_table(f: float, f1: float, f2: float, tilt: float) -> PackedFloat32Array:
	var amps := PackedFloat32Array()
	var h := 1
	while h * f < 4500.0 and h <= 24:
		var hf := h * f
		amps.append((1.0 / (1.0 + pow((hf - f1) / 110.0, 2.0)) + 0.6 / (1.0 + pow((hf - f2) / 160.0, 2.0)) + 0.06) / pow(float(h), tilt))
		h += 1
	var tab := PackedFloat32Array()
	tab.resize(TABLE)
	var peak := 0.0
	for i in TABLE:
		var th := TAU * i / TABLE
		var c2 := 2.0 * cos(th)
		var s_prev := 0.0
		var s_cur := sin(th)
		var v := 0.0
		for j in amps.size():
			v += amps[j] * s_cur
			var s_next := c2 * s_cur - s_prev
			s_prev = s_cur
			s_cur = s_next
		tab[i] = v
		peak = maxf(peak, absf(v))
	if peak > 0.0:
		for i in TABLE: tab[i] /= peak
	return tab
