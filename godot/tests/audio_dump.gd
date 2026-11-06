extends Node
func _ready() -> void:
	var sfx := get_node("/root/Sfx")
	var out := OS.get_cmdline_user_args()[0]
	for k in ["impact", "crit", "thunder", "drop_legendary", "boss"]:
		var w: AudioStreamWAV = sfx.streams[k]
		w.save_to_wav(out.path_join(k + ".wav"))
	var a: AudioStreamWAV = sfx._ambience_loop(1)
	a.save_to_wav(out.path_join("ambience_cinder.wav"))
	get_tree().quit()
