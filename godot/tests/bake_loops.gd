extends Node
## Bakes the Emberwitch's two fire loops (Sfx._fire_loop: crackle 4 s, rumble 6 s, fixed seeds) to WAV, for
## tools/bake_loops.sh to encode as res://audio/sfx/fire_crackle.ogg and fire_rumble.ogg. Sfx loads those
## files instead of synthesizing the loops in the middle of the first fire of a run (O6: 127 ms here).
##   godot --headless --path godot res://tests/bake_loops.tscn -- <out dir>
func _ready() -> void:
	var sfx := get_node("/root/Sfx")
	var out := OS.get_cmdline_user_args()[0]
	sfx.RATE = 44100
	for spec in [["fire_crackle", 4.0, false], ["fire_rumble", 6.0, true]]:
		sfx.streams.erase(spec[0])
		var w: AudioStreamWAV = sfx._synth_fire_loop(spec[0], spec[1], spec[2])
		w.save_to_wav(out.path_join(spec[0] + ".wav"))
		print("baked %s: %.2f s at %d Hz" % [spec[0], w.get_length(), w.mix_rate])
	get_tree().quit()
