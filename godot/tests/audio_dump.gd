extends Node
func _ready() -> void:
	var sfx := get_node("/root/Sfx")
	var out := OS.get_cmdline_user_args()[0]
	for k in ["impact", "crit", "thunder", "drop_legendary", "boss"]:
		var w: AudioStreamWAV = sfx.streams[k]
		w.save_to_wav(out.path_join(k + ".wav"))
	var a: AudioStreamWAV = sfx._ambience_loop(1)
	a.save_to_wav(out.path_join("ambience_cinder.wav"))
	var vb: VoiceBank = get_node("/root/Voice")
	for s in VoiceBank.CHIMES:                         # the voice lines' stand-in chimes
		vb.chime(s).save_to_wav(out.path_join("voice_chime_%s.wav" % s))
	get_tree().quit()
