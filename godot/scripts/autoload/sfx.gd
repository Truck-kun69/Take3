extends Node
## Tiny synthesizer: every sound effect is baked once at startup into a 16-bit AudioStreamWAV from
## (frequency, slide, waveform, envelope), so the game ships no audio files. Playback goes through a
## small round-robin pool with per-sound rate limiting, so 300 simultaneous kills make one click,
## not 300.

const RATE := 22050
const POOL := 12
var streams := {}
var players: Array[AudioStreamPlayer] = []
var _last := {}
var _rr := 0

# name: [freq, seconds, wave (0 sine, 1 square, 2 saw, 3 triangle, 4 noise), slide, volume]
const DEFS := {
	"shoot": [520.0, 0.08, 3, 0.5, 0.25], "kill": [240.0, 0.07, 1, 0.55, 0.14], "gem": [760.0, 0.06, 0, 1.4, 0.18],
	"coin": [1240.0, 0.07, 3, 1.25, 0.18], "hurt": [170.0, 0.2, 2, 0.5, 0.4], "nova": [130.0, 0.28, 0, 2.2, 0.5],
	"zap": [900.0, 0.14, 2, 0.3, 0.2], "boss": [80.0, 0.7, 2, 0.5, 0.55], "roll": [300.0, 0.12, 4, 0.6, 0.16],
	"perfect": [1400.0, 0.3, 0, 0.5, 0.35], "ult": [110.0, 0.8, 2, 3.0, 0.5], "flask": [420.0, 0.2, 0, 1.6, 0.25],
	"heal": [520.0, 0.18, 3, 1.5, 0.25], "event": [330.0, 0.5, 3, 1.5, 0.35], "pylon": [660.0, 0.45, 0, 1.5, 0.35],
	"level": [660.0, 0.3, 3, 1.33, 0.3], "win": [520.0, 0.6, 3, 2.0, 0.35], "lose": [300.0, 0.7, 2, 0.6, 0.35],
	"craft": [880.0, 0.15, 3, 1.2, 0.25], "click": [1000.0, 0.03, 3, 1.0, 0.12], "react": [420.0, 0.16, 1, 1.8, 0.16],
}

func _ready() -> void:
	for k in DEFS:
		var d: Array = DEFS[k]
		streams[k] = _bake(d[0], d[1], d[2], d[3], d[4])
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)

func _bake(f: float, dur: float, wave: int, slide: float, vol: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var ph := 0.0
	var noise := RandomNumberGenerator.new()
	noise.seed = 7
	for i in n:
		var t := float(i) / n
		ph += f * pow(slide, t) / RATE
		var x := fmod(ph, 1.0)
		var s := 0.0
		match wave:
			0: s = sin(ph * TAU)
			1: s = 1.0 if x < 0.5 else -1.0
			2: s = 2.0 * x - 1.0
			3: s = 4.0 * absf(x - 0.5) - 1.0
			_: s = noise.randf_range(-1.0, 1.0)
		var env := minf(1.0, t * 40.0) * pow(1.0 - t, 2.0)
		bytes.encode_s16(i * 2, int(clampf(s * env * vol, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	return w

func play(name: String, pitch: float = 1.0) -> void:
	if not Save.opt("sound") or not streams.has(name) or players.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(name, -1000)) < 50:
		return
	_last[name] = now
	var p := players[_rr]
	_rr = (_rr + 1) % POOL
	p.stream = streams[name]
	p.pitch_scale = pitch * randf_range(0.95, 1.05)
	p.volume_db = linear_to_db(maxf(0.001, float(Save.opt("volume"))))
	p.play()
