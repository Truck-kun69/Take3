extends Node
## Layered synthesizer + sample override slots.
##
## Every sound is baked once at startup from up to four layers (tone or filtered noise, pitch slide,
## delay, one-pole low-pass), so impacts get a low thump under a bright transient, thunder a noise
## crack over a rumble, and loot drops a bell-like chord whose brightness rises with rarity.
## Authored audio wins when present:
##   res://audio/sfx/<name>.(wav|ogg|mp3)      replaces a synthesized sound of the same name
##   res://audio/music/<stage index>.(ogg|mp3)  replaces the generated stage ambience
## Playback: one player per sound, its stream set once (up to 3 overlapping voices), a per-sound rate
## limit, a cap on new voices per frame, and distance attenuation via play_at().
##
## Android (S22) crash, Nov 2026: the old round-robin pool of 16 players swapped a new stream into a
## player on every play, often while it was still playing, dozens of times a second in a fight. The
## game died ~3 s into every run with sound on and ran fine with it off; desktop never showed it
## (headless/dummy audio does not mix). Now nothing is swapped while playing, sounds are baked at
## the device's own mix rate (no resampling), and "Sound engine: Safe" (option sfx_safe) further
## drops to 1 voice per sound, no pitch jitter and no ambience.

var RATE := 22050               # set to the output mix rate in _ready
const VOICES := 3
const MAX_NEW_PER_FRAME := 6
var streams := {}
var players := {}               # name -> AudioStreamPlayer (stream fixed)
var ambience: AudioStreamPlayer
var _last := {}
var _frame := -1
var _frame_n := 0
var listener := Vector2.ZERO

# layer: [freq, seconds, wave (0 sine 1 square 2 saw 3 triangle 4 noise), slide, volume, delay, lowpass 0..1]
const DEFS := {
	"shoot": [[620.0, 0.07, 3, 0.5, 0.22, 0.0, 0.0], [2400.0, 0.04, 4, 1.0, 0.08, 0.0, 0.5]],
	"kill": [[180.0, 0.09, 0, 0.5, 0.3, 0.0, 0.0], [900.0, 0.05, 4, 1.0, 0.12, 0.0, 0.6]],
	"impact": [[110.0, 0.12, 0, 0.45, 0.45, 0.0, 0.0], [1600.0, 0.04, 4, 1.0, 0.18, 0.0, 0.3]],
	"crit": [[90.0, 0.16, 0, 0.4, 0.5, 0.0, 0.0], [3000.0, 0.06, 4, 1.0, 0.25, 0.0, 0.15], [1400.0, 0.12, 3, 0.7, 0.18, 0.01, 0.0]],
	"gem": [[880.0, 0.06, 0, 1.4, 0.16, 0.0, 0.0], [1760.0, 0.05, 0, 1.4, 0.06, 0.02, 0.0]],
	"coin": [[1320.0, 0.08, 3, 1.15, 0.15, 0.0, 0.0], [1980.0, 0.08, 0, 1.1, 0.08, 0.03, 0.0]],
	"hurt": [[150.0, 0.22, 2, 0.5, 0.4, 0.0, 0.3], [400.0, 0.08, 4, 1.0, 0.25, 0.0, 0.4]],
	"nova": [[95.0, 0.4, 0, 2.0, 0.55, 0.0, 0.0], [600.0, 0.35, 4, 1.0, 0.18, 0.0, 0.85]],
	"fire": [[200.0, 0.35, 4, 1.0, 0.3, 0.0, 0.8], [70.0, 0.3, 0, 1.5, 0.35, 0.0, 0.0]],
	"ice": [[2600.0, 0.18, 3, 0.6, 0.14, 0.0, 0.0], [3800.0, 0.12, 4, 1.0, 0.1, 0.0, 0.2], [1300.0, 0.2, 0, 0.8, 0.1, 0.03, 0.0]],
	"zap": [[1400.0, 0.12, 2, 0.3, 0.16, 0.0, 0.0], [5000.0, 0.1, 4, 1.0, 0.16, 0.0, 0.05]],
	"thunder": [[4000.0, 0.08, 4, 1.0, 0.35, 0.0, 0.0], [60.0, 0.6, 4, 1.0, 0.5, 0.03, 0.96], [45.0, 0.5, 0, 0.8, 0.35, 0.02, 0.0]],
	"explode": [[55.0, 0.5, 0, 0.6, 0.6, 0.0, 0.0], [300.0, 0.45, 4, 1.0, 0.4, 0.0, 0.9]],
	"boss": [[70.0, 0.9, 2, 0.6, 0.45, 0.0, 0.5], [140.0, 0.8, 2, 0.55, 0.3, 0.05, 0.6], [200.0, 0.7, 4, 1.0, 0.25, 0.0, 0.93]],
	"roll": [[300.0, 0.18, 4, 1.0, 0.25, 0.0, 0.85], [180.0, 0.12, 0, 0.6, 0.12, 0.0, 0.0]],
	"perfect": [[1400.0, 0.35, 0, 0.5, 0.3, 0.0, 0.0], [2100.0, 0.3, 0, 0.5, 0.15, 0.04, 0.0], [80.0, 0.3, 0, 0.5, 0.35, 0.0, 0.0]],
	"ult": [[110.0, 0.9, 2, 3.0, 0.45, 0.0, 0.4], [55.0, 0.8, 0, 1.0, 0.5, 0.0, 0.0], [800.0, 0.7, 4, 1.0, 0.25, 0.1, 0.9]],
	"flask": [[420.0, 0.22, 0, 1.6, 0.25, 0.0, 0.0], [300.0, 0.25, 4, 1.0, 0.08, 0.0, 0.95]],
	"heal": [[523.0, 0.25, 3, 1.0, 0.18, 0.0, 0.0], [659.0, 0.25, 3, 1.0, 0.14, 0.06, 0.0], [784.0, 0.3, 3, 1.0, 0.12, 0.12, 0.0]],
	"event": [[220.0, 0.8, 3, 1.0, 0.3, 0.0, 0.0], [330.0, 0.8, 3, 1.0, 0.2, 0.1, 0.0], [110.0, 0.9, 0, 1.0, 0.3, 0.0, 0.0]],
	"pylon": [[660.0, 0.6, 0, 1.0, 0.25, 0.0, 0.0], [990.0, 0.6, 0, 1.0, 0.15, 0.08, 0.0], [1320.0, 0.6, 0, 1.0, 0.1, 0.16, 0.0]],
	"level": [[523.0, 0.18, 3, 1.0, 0.25, 0.0, 0.0], [659.0, 0.18, 3, 1.0, 0.22, 0.08, 0.0], [784.0, 0.18, 3, 1.0, 0.2, 0.16, 0.0], [1046.0, 0.3, 3, 1.0, 0.2, 0.24, 0.0]],
	"win": [[523.0, 0.5, 3, 1.0, 0.25, 0.0, 0.0], [659.0, 0.5, 3, 1.0, 0.2, 0.12, 0.0], [784.0, 0.6, 3, 1.0, 0.2, 0.24, 0.0], [1046.0, 0.8, 3, 1.0, 0.2, 0.36, 0.0]],
	"lose": [[300.0, 0.7, 2, 0.6, 0.3, 0.0, 0.5], [225.0, 0.8, 2, 0.6, 0.25, 0.2, 0.5], [60.0, 1.0, 0, 0.8, 0.35, 0.0, 0.0]],
	"craft": [[880.0, 0.15, 3, 1.2, 0.25, 0.0, 0.0], [1760.0, 0.2, 0, 1.0, 0.1, 0.05, 0.0]],
	"click": [[1000.0, 0.03, 3, 1.0, 0.12, 0.0, 0.0]],
	"break": [[140.0, 0.16, 0, 0.5, 0.4, 0.0, 0.0], [2200.0, 0.12, 4, 1.0, 0.3, 0.0, 0.2], [900.0, 0.08, 4, 1.0, 0.2, 0.05, 0.5]],
	"step": [[90.0, 0.06, 4, 1.0, 0.1, 0.0, 0.92]],
	"react": [[420.0, 0.2, 1, 1.8, 0.14, 0.0, 0.4], [180.0, 0.25, 0, 0.6, 0.3, 0.0, 0.0], [2000.0, 0.1, 4, 1.0, 0.12, 0.0, 0.3]],
	# loot drops: brighter and longer with rarity, the legendary one rings like a bell
	"drop_magic": [[784.0, 0.25, 0, 1.0, 0.16, 0.0, 0.0], [1175.0, 0.2, 0, 1.0, 0.08, 0.05, 0.0]],
	"drop_rare": [[988.0, 0.4, 0, 1.0, 0.2, 0.0, 0.0], [1480.0, 0.35, 0, 1.0, 0.12, 0.06, 0.0], [1976.0, 0.3, 0, 1.0, 0.08, 0.12, 0.0]],
	"drop_legendary": [[523.0, 1.4, 0, 1.0, 0.25, 0.0, 0.0], [1046.0, 1.2, 0, 1.0, 0.18, 0.0, 0.0], [1568.0, 1.0, 0, 1.0, 0.12, 0.02, 0.0], [2637.0, 0.8, 0, 1.0, 0.08, 0.04, 0.0]],
	"drop_currency": [[1568.0, 0.18, 3, 1.0, 0.18, 0.0, 0.0], [2093.0, 0.2, 0, 1.0, 0.1, 0.06, 0.0]],
}

func _ready() -> void:
	RATE = clampi(int(AudioServer.get_mix_rate()), 22050, 48000)
	var safe := bool(Save.opt("sfx_safe"))
	for k in DEFS:
		var ov := _override("res://audio/sfx/" + k)
		streams[k] = ov if ov != null else _bake(DEFS[k])
		var p := AudioStreamPlayer.new()
		p.stream = streams[k]
		p.max_polyphony = 1 if safe else VOICES
		add_child(p)
		players[k] = p
	ambience = AudioStreamPlayer.new()
	ambience.volume_db = -14.0
	add_child(ambience)

func _override(base: String) -> AudioStream:
	for ext in ["wav", "ogg", "mp3"]:
		var p: String = base + "." + ext
		if ResourceLoader.exists(p):
			return load(p)
	return null

func _bake(layers: Array) -> AudioStreamWAV:
	var total := 0.0
	for L in layers: total = maxf(total, float(L[1]) + float(L[5]))
	var n := int(RATE * total) + 1
	var mix := PackedFloat32Array()
	mix.resize(n)
	var noise := RandomNumberGenerator.new()
	noise.seed = 7
	for L in layers:
		var f: float = L[0]; var dur: float = L[1]; var wave: int = L[2]; var slide: float = L[3]
		var vol: float = L[4]; var start := int(float(L[5]) * RATE); var lp: float = L[6]
		var ln := int(RATE * dur)
		var ph := 0.0
		var y := 0.0
		for i in ln:
			var t := float(i) / ln
			ph += f * pow(slide, t) / RATE
			var x := fmod(ph, 1.0)
			var s := 0.0
			match wave:
				0: s = sin(ph * TAU)
				1: s = 1.0 if x < 0.5 else -1.0
				2: s = 2.0 * x - 1.0
				3: s = 4.0 * absf(x - 0.5) - 1.0
				_: s = noise.randf_range(-1.0, 1.0)
			if lp > 0.0:                                   # one-pole low-pass: darker noise = thumps, rumbles
				y = y * lp + s * (1.0 - lp)
				s = y * (1.0 + lp * 3.0)
			var env := minf(1.0, t * 60.0) * pow(1.0 - t, 2.2)
			if start + i < n: mix[start + i] += s * env * vol
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(tanh(mix[i] * 1.4), -1.0, 1.0) * 32767.0))   # soft clip
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	return w

## Stage ambience: wind (filtered noise with slow gusts) over a detuned low drone, 8 s seamless loop.
func start_ambience(stage: int) -> void:
	if not Save.opt("sound") or Save.opt("sfx_safe"):
		ambience.stop()
		return
	var ov := _override("res://audio/music/%d" % stage)
	if ov == null:
		ov = _ambience_loop(stage)
	ambience.stream = ov
	ambience.volume_db = linear_to_db(maxf(0.001, float(Save.opt("volume")) * 0.35))
	Diag.first("ambience %d" % stage)
	ambience.play()

func stop_ambience() -> void:
	ambience.stop()

func _ambience_loop(stage: int) -> AudioStreamWAV:
	var key := "amb%d" % stage
	if streams.has(key): return streams[key]
	var secs := 8.0
	var n := int(RATE * secs)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var base: float = [55.0, 49.0, 41.2, 65.4, 36.7][stage % 5]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11 + stage
	var y := 0.0
	var y2 := 0.0
	for i in n:
		var t := float(i) / RATE
		var loop := TAU * t / secs                         # every modulator completes whole cycles: seamless loop
		var gust := 0.5 + 0.5 * sin(loop * 2.0) * sin(loop * 3.0 + 1.0)
		y = y * 0.985 + rng.randf_range(-1, 1) * 0.015
		y2 = y2 * 0.9 + y * 0.1
		var wind := y2 * 9.0 * (0.4 + gust)
		var drone := sin(TAU * base * t) * 0.35 + sin(TAU * base * 1.5 * t + sin(loop) * 0.5) * 0.18 + sin(TAU * base * 2.0 * t) * 0.08
		drone *= 0.6 + 0.4 * sin(loop)
		var s := clampf(wind * 0.6 + drone * 0.35, -1.0, 1.0)
		bytes.encode_s16(i * 2, int(s * 32767.0 * 0.8))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n - 2            # inside the data: the interpolator reads one frame past the loop end
	streams[key] = w
	return w

func play(name: String, pitch: float = 1.0, gain: float = 1.0) -> void:
	if not Save.opt("sound") or not players.has(name):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(name, -1000)) < 50:
		return
	var f := Engine.get_process_frames()
	if f != _frame:
		_frame = f
		_frame_n = 0
	if _frame_n >= MAX_NEW_PER_FRAME:
		return
	_frame_n += 1
	_last[name] = now
	Diag.first("sound " + name)
	var p: AudioStreamPlayer = players[name]
	var ps := 1.0 if Save.opt("sfx_safe") else clampf(pitch * randf_range(0.94, 1.06), 0.5, 2.0)
	if not is_finite(ps): ps = 1.0
	p.pitch_scale = ps
	p.volume_db = clampf(linear_to_db(maxf(0.001, float(Save.opt("volume")) * gain)), -60.0, 6.0)
	p.play()

## Option change: polyphony follows the Safe setting.
func apply_options() -> void:
	for k in players: players[k].max_polyphony = 1 if Save.opt("sfx_safe") else VOICES
	if Save.opt("sfx_safe") or not Save.opt("sound"): ambience.stop()

## Distance-attenuated: full volume within 150 units of the listener, silent past ~900.
func play_at(name: String, at: Vector2, pitch: float = 1.0) -> void:
	var d := at.distance_to(listener)
	var g := clampf(1.0 - (d - 150.0) / 750.0, 0.0, 1.0)
	if g > 0.05:
		play(name, pitch, g)
