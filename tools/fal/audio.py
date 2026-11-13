"""Generate the game's sound effects and act music on fal, into Sfx's override slots.

    python3 tools/fal/audio.py sfx <work dir> [names...]     ElevenLabs sound effects -> godot/audio/sfx/<name>.wav
    python3 tools/fal/audio.py music <work dir> [stages...]  Lyria 2 -> godot/audio/music/<stage>.ogg (looped)

Each effect is trimmed of leading silence, cut to its length, faded out, made mono 44.1 kHz and
peak-normalised to the level the synthesised sound it replaces had, so the mix stays balanced.
Auth as gen3d.py: the cloud session's proxy adds the fal key for fal.run.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen3d import call, fetch  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STYLE = ", dark fantasy action game sound effect, clean, no music, no voice"
# name: (prompt, seconds kept, peak 0..1)
SFX = {
    "shoot": ("a quick magical ice bolt being cast, short airy whoosh with a crystalline tick", 0.25, 0.3),
    "kill": ("a small monster dying, wet crunch and a short squelch", 0.3, 0.4),
    "impact": ("a heavy sword strike landing on a leather training dummy, dull meaty thud", 0.25, 0.5),
    "crit": ("a very heavy crunching impact with a sharp metallic ring", 0.4, 0.65),
    "gem": ("picking up a small glowing crystal shard, soft bright chime", 0.25, 0.22),
    "coin": ("a few gold coins clinking as they are picked up", 0.3, 0.25),
    "hurt": ("a man in armour letting out a short sharp grunt of effort", 0.4, 0.6),
    "nova": ("a fiery shockwave bursting outward, deep whoomp", 0.7, 0.6),
    "fire": ("a burst of flame igniting, roaring whoosh", 0.6, 0.45),
    "ice": ("ice crystals forming and cracking, sharp frosty crackle", 0.4, 0.3),
    "zap": ("a short electric zap, crackling spark", 0.3, 0.3),
    "thunder": ("a lightning bolt striking the ground close by, sharp crack then a short rumble", 0.9, 0.65),
    "explode": ("a deep explosion with debris, heavy boom", 0.8, 0.75),
    "boss": ("a huge monster arriving, a deep menacing horn blast with a low growl", 1.8, 0.75),
    "roll": ("a fast dodge roll, cloth and armour whoosh", 0.3, 0.35),
    "perfect": ("a perfect dodge, time slowing with a bright reversed shimmer and a low sub drop", 0.7, 0.5),
    "ult": ("an ultimate ability unleashed, rising power surge ending in a huge magical blast", 1.4, 0.8),
    "flask": ("drinking a potion from a glass flask, gulp and a cork pop", 0.5, 0.35),
    "heal": ("a gentle healing spell, warm rising shimmer", 0.6, 0.3),
    "event": ("an ominous bell tolling once with a dark swell", 1.5, 0.5),
    "pylon": ("activating an arcane pylon, bright rising energy hum", 0.9, 0.4),
    "level": ("a triumphant level up, short rising magical chime", 0.9, 0.5),
    "win": ("victory, a short heroic brass and choir stinger", 2.2, 0.6),
    "lose": ("defeat, a dark descending low brass stinger fading out", 2.2, 0.6),
    "craft": ("an anvil strike with a magical sparkle, crafting an item", 0.5, 0.35),
    "click": ("a soft stone button click for a menu", 0.12, 0.2),
    "break": ("a clay urn shattering", 0.4, 0.5),
    "step": ("a single footstep on dirt, soft", 0.12, 0.12),
    "react": ("an elemental reaction, fire and ice colliding in a sharp hissing burst", 0.5, 0.5),
    "drop_magic": ("a magic item dropping, a soft blue chime", 0.5, 0.3),
    "drop_rare": ("a rare item dropping, a bright golden chime with a shimmer", 0.7, 0.4),
    "drop_legendary": ("a legendary item dropping, a deep resonant gong with a radiant choir shimmer", 1.6, 0.6),
    "drop_currency": ("a small orb dropping on stone, glassy ping", 0.35, 0.25),
}
MUSIC = {
    0: "dark fantasy ambient battle music, a haunted overgrown forest at night, low strings ostinato, distant choir, slow war drums, brooding, cinematic, instrumental",
    1: "dark fantasy battle music, a burning volcanic wasteland, driving taiko drums, low brass, distorted hurdy-gurdy, tense, cinematic, instrumental",
    2: "dark fantasy music, an ancient crypt, cold choir pads, bowed metal, slow heartbeat percussion, eerie, cinematic, instrumental",
    3: "dark fantasy battle music, a shattered crystal void, glassy arpeggios, deep sub bass pulses, ethereal female vocalise, urgent, cinematic, instrumental",
    4: "dark fantasy music, a drowned cathedral, pipe organ drones, dripping water, sorrowful cello, slow tolling bell, ominous, cinematic, instrumental",
}


def ff(args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + args, check=True)


def sfx(work, names):
    out = os.path.join(ROOT, "godot", "audio", "sfx")
    os.makedirs(out, exist_ok=True); os.makedirs(work, exist_ok=True)
    for n in names or list(SFX):
        prompt, secs, peak = SFX[n]
        raw = os.path.join(work, n + ".mp3")
        if not os.path.exists(raw):
            try:
                res = call("fal-ai/elevenlabs/sound-effects/v2", {"text": prompt + STYLE, "duration_seconds": max(0.5, round(secs + 0.3, 1)), "prompt_influence": 0.6}, timeout=120)
            except SystemExit as e:          # a refused prompt keeps the synthesised sound; carry on with the rest
                print("skipped", n, str(e)[:160]); continue
            fetch(res["audio"]["url"], raw)
        fade = min(0.12, secs * 0.4)
        tmp = os.path.join(work, n + "_t.wav")
        ff(["-i", raw, "-af", f"silenceremove=start_periods=1:start_threshold=-42dB,atrim=0:{secs},afade=t=out:st={secs - fade}:d={fade}", "-ac", "1", "-ar", "44100", tmp])
        # peak-normalise to the target level
        info = subprocess.run(["ffmpeg", "-hide_banner", "-i", tmp, "-af", "volumedetect", "-f", "null", "-"], capture_output=True, text=True).stderr
        mx = float(info.split("max_volume:")[1].split("dB")[0])
        import math
        gain = 20 * math.log10(peak) - mx
        ff(["-i", tmp, "-af", f"volume={gain:.2f}dB", "-c:a", "pcm_s16le", os.path.join(out, n + ".wav")])
        print("sfx", n, f"{secs}s peak {peak}")


def music(work, stages):
    out = os.path.join(ROOT, "godot", "audio", "music")
    os.makedirs(out, exist_ok=True); os.makedirs(work, exist_ok=True)
    for st in [int(x) for x in stages] or list(MUSIC):
        raw = os.path.join(work, f"music{st}.wav")
        if not os.path.exists(raw):
            res = call("fal-ai/lyria2", {"prompt": MUSIC[st], "negative_prompt": "vocals with lyrics, speech, low quality"}, timeout=300)
            json.dump(res, open(os.path.join(work, f"music{st}.json"), "w"))
            fetch(res["audio"]["url"], raw)
        # loop: crossfade the tail into the head so the seam is inaudible, then encode
        d = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", raw], capture_output=True, text=True).stdout)
        x = 2.5
        ff(["-i", raw, "-filter_complex",
            f"[0]atrim=0:{x},asetpts=PTS-STARTPTS,afade=t=in:d={x}[h];[0]atrim={d - x}:{d},asetpts=PTS-STARTPTS,afade=t=out:d={x}[t];[h][t]amix=inputs=2:normalize=0[seam];"
            f"[0]atrim={x}:{d - x},asetpts=PTS-STARTPTS[mid];[mid][seam]concat=n=2:v=0:a=1,loudnorm=I=-20:TP=-2[o]",
            "-map", "[o]", "-ar", "44100", "-ac", "2", "-c:a", "libvorbis", "-q:a", "4", os.path.join(out, f"{st}.ogg")])
        print("music", st, f"{d:.1f}s")


if __name__ == "__main__":
    {"sfx": sfx, "music": music}[sys.argv[1]](sys.argv[2], sys.argv[3:])
