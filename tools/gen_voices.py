#!/usr/bin/env python3
"""The voice pack: every line of godot/data/voice_manifest.json, synthesised with ElevenLabs.

    python3 tools/gen_voices.py                    # = --dry-run: validate the manifest, count the lines and characters,
                                                   #   estimate the cost, list which .ogg files are present. No network.
    python3 tools/gen_voices.py --generate         # every line not generated yet, or whose text or casting changed
    python3 tools/gen_voices.py --generate --speaker ember          # one speaker at a time (--all is the default)
    python3 tools/gen_voices.py --generate --provider fal           # through fal.ai instead of ElevenLabs' own API
    python3 tools/gen_voices.py --reencode         # rebuild the .ogg files from the kept downloads (free)
    python3 tools/gen_voices.py --selftest         # run the ffmpeg chain on a synthetic clip (free, no network)

Providers:
  elevenlabs (default)  POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128,
                        header xi-api-key: $ELEVENLABS_API_KEY
  fal                   fal-ai/elevenlabs/tts/multilingual-v2 through fal's queue, "Authorization: Key $FAL_KEY"
                        (a cloud session's network proxy can add the key itself, as for tools/fal_assets.py)
Voices: EL_VOICE_WARDEN, EL_VOICE_SPARK, EL_VOICE_EMBER, EL_VOICE_STORM, EL_VOICE_NARRATOR, EL_VOICE_TYRANT and
EL_VOICE_HERALD hold the ElevenLabs voice IDs (through fal a voice name such as "Aria" also works).

Each line: text-to-speech with its speaker's casting (model_id, stability, similarity_boost, style) ->
tools/.voice_raw/<key>.mp3, kept so that re-encoding never pays again -> ffmpeg: the silence trimmed at both ends,
loudness normalised to -16 LUFS / -1.0 dBTP (two-pass loudnorm), 44.1 kHz mono Ogg Vorbis at -q:a 4 ->
godot/audio/voices/<speaker>/<cue>_<variant>.ogg, with a .ogg.import (loop=false) beside it. The game picks the
clip up on the next build and times the subtitle, the ducking and the intro to its real length.
tools/voice_cache.json records every paid call under a content key, sha256 of (id, text, voice_id, model_id,
stability, similarity_boost, style): a line is only sent again when one of those changes, or with --force.
A run stops before sending more than --max-chars characters (default 6,000; the whole pack is about 3,900).
See docs/VOICES.md.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.path.join(ROOT, "godot")
MANIFEST = os.path.join(GODOT, "data", "voice_manifest.json")
RAW = os.path.join(ROOT, "tools", ".voice_raw")
CACHE = os.path.join(ROOT, "tools", "voice_cache.json")

HEROES = ("warden", "spark", "ember", "storm")
HERO_CUES = {"intro": 1, "cast": 3, "ult": 2, "kill_streak": 2, "low_hp": 2, "boss_spawn": 1, "death": 1}
NARRATOR_CUES = {"intro": 4, "act_0": 1, "act_1": 1, "act_2": 1, "act_3": 1, "act_4": 1}
BOSS_CUES = {"spawn": 1, "die": 1}
EXPECTED = {**{h: HERO_CUES for h in HEROES}, "narrator": NARRATOR_CUES, "tyrant": BOSS_CUES, "herald": BOSS_CUES}
TOTAL_LINES = sum(sum(c.values()) for c in EXPECTED.values())          # 61
PRIORITY = {"cast": 0, "kill_streak": 1, "low_hp": 2, "ult": 2, "boss_spawn": 3, "death": 3, "spawn": 3, "die": 3, "intro": 4}
COOLDOWN = {"cast": 7.0, "kill_streak": 10.0, "low_hp": 15.0, "ult": 4.0}
BARK_WORDS = (3, 8)            # combat barks
LONG_WORDS = (10, 22)          # intros, act openings and the bosses' arrivals
BUSES = ("VoiceHero", "VoiceNarrator", "VoiceBoss")
REQUIRED = ("id", "speaker", "cue", "variant", "file", "text", "priority", "cooldown_s", "duration_fallback_s")
# list prices for eleven_multilingual_v2 in Nov 2026: $0.10 per 1,000 characters through fal (its model page) and on
# ElevenLabs' usage-based API (some pages show $0.08); a subscription spends 1 credit per character instead
PRICE_PER_1K = {"elevenlabs": 0.10, "fal": 0.10}
FAL_ENDPOINT = "fal-ai/elevenlabs/tts/multilingual-v2"
TARGET_LUFS, TARGET_TP = -16.0, -1.0
TRIM = ("silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:start_silence=0.03,areverse,"
        "silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:start_silence=0.06,areverse")
IMPORT = """[remap]

importer="oggvorbisstr"
type="AudioStreamOggVorbis"

[deps]

source_file="{res}"

[params]

loop=false
loop_offset=0
bpm=0
beat_count=0
bar_beats=4
"""


def is_long(cue):
    return cue in ("intro", "spawn") or cue.startswith("act_")


def words(text):
    return len(re.findall(r"[A-Za-z0-9']+", text))


def ogg_path(line):
    return os.path.join(GODOT, "audio", "voices", line["speaker"], f"{line['cue']}_{line['variant']}.ogg")


def load_manifest(path=MANIFEST):
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------- validation
def validate(man):
    """-> (errors, notes). Everything the game and this tool rely on, checked offline."""
    err = []
    cast = man.get("casting")
    lines = man.get("lines")
    if not isinstance(cast, dict) or not isinstance(lines, list):
        return ["the manifest needs a 'casting' object and a 'lines' list"], []
    if set(cast) != set(EXPECTED):
        err.append(f"casting has {sorted(cast)}, expected {sorted(EXPECTED)}")
    envs = {}
    for sp, c in cast.items():
        for k in ("name", "bus", "color", "direction", "voice_id_env", "model_id"):
            if not isinstance(c.get(k), str) or not c.get(k):
                err.append(f"casting {sp}: '{k}' missing")
        for k in ("stability", "similarity_boost", "style"):
            v = c.get(k)
            if not isinstance(v, (int, float)) or not 0.0 <= v <= 1.0:
                err.append(f"casting {sp}: '{k}' must be a number in 0-1 (got {v!r})")
        if not isinstance(c.get("pace_wps"), (int, float)) or c.get("pace_wps", 0) <= 0:
            err.append(f"casting {sp}: 'pace_wps' must be > 0")
        if c.get("bus") not in BUSES:
            err.append(f"casting {sp}: bus {c.get('bus')!r} is not one of {BUSES}")
        if not re.fullmatch(r"[0-9a-fA-F]{6}", str(c.get("color", ""))):
            err.append(f"casting {sp}: color must be 6 hex digits")
        env = str(c.get("voice_id_env", ""))
        if not re.fullmatch(r"EL_VOICE_[A-Z]+", env):
            err.append(f"casting {sp}: voice_id_env {env!r} must look like EL_VOICE_NAME")
        if env in envs:
            err.append(f"casting {sp}: voice_id_env {env} is also {envs[env]}'s")
        envs[env] = sp
    prof = {}
    for h in HEROES:
        c = cast.get(h, {})
        key = (c.get("stability"), c.get("style"))
        if key in prof:
            err.append(f"casting {h}: stability/style {key} is the same as {prof[key]}'s (the exiles must not sound alike)")
        prof[key] = h
    ids = set()
    count = {}
    for i, ln in enumerate(lines):
        if not isinstance(ln, dict):
            err.append(f"line {i}: not an object")
            continue
        miss = [k for k in REQUIRED if k not in ln]
        if miss:
            err.append(f"line {ln.get('id', i)}: missing {', '.join(miss)}")
            continue
        lid, sp, cue, var = ln["id"], ln["speaker"], ln["cue"], ln["variant"]
        if not all(isinstance(x, str) for x in (lid, sp, cue, ln["file"], ln["text"])) or not isinstance(var, int):
            err.append(f"line {lid}: id, speaker, cue, file and text must be strings, variant an integer")
            continue
        if lid in ids:
            err.append(f"line {lid}: duplicate id")
        ids.add(lid)
        if sp not in cast:
            err.append(f"line {lid}: no casting for speaker {sp!r}")
        if lid != f"{sp}_{cue}_{var}":
            err.append(f"line {lid}: id must be {sp}_{cue}_{var}")
        if ln["file"] != f"res://audio/voices/{sp}/{cue}_{var}.ogg":
            err.append(f"line {lid}: file must be res://audio/voices/{sp}/{cue}_{var}.ogg")
        want_p = 3 if cue.startswith("act_") else PRIORITY.get(cue)
        if want_p is None or sp not in EXPECTED or cue not in EXPECTED[sp]:
            err.append(f"line {lid}: {sp} has no cue {cue!r}")
        elif ln["priority"] != want_p:
            err.append(f"line {lid}: priority {ln['priority']}, the cue table says {want_p}")
        if not isinstance(ln["cooldown_s"], (int, float)) or abs(float(ln["cooldown_s"]) - COOLDOWN.get(cue, 0.0)) > 1e-6:
            err.append(f"line {lid}: cooldown_s {ln['cooldown_s']}, the cue table says {COOLDOWN.get(cue, 0.0)}")
        d = ln["duration_fallback_s"]
        if not isinstance(d, (int, float)) or not 0.5 <= d <= 20.0:
            err.append(f"line {lid}: duration_fallback_s {d!r} must be 0.5-20 s")
        w = words(ln["text"])
        lo, hi = LONG_WORDS if is_long(cue) else BARK_WORDS
        if not lo <= w <= hi:
            err.append(f"line {lid}: {w} words, a {'long line' if is_long(cue) else 'bark'} takes {lo}-{hi}")
        count.setdefault(sp, {}).setdefault(cue, []).append(var)
    for sp, cues in EXPECTED.items():
        for cue, n in cues.items():
            got = sorted(count.get(sp, {}).get(cue, []))
            if got != list(range(n)):
                err.append(f"{sp}/{cue}: variants {got}, expected 0-{n - 1}")
    if len(lines) != TOTAL_LINES:
        err.append(f"{len(lines)} lines, expected {TOTAL_LINES}")
    return err, []


def content_key(line, voice_id, cast):
    blob = json.dumps([line["id"], line["text"], voice_id, cast["model_id"], cast["stability"], cast["similarity_boost"], cast["style"]])
    return hashlib.sha256(blob.encode()).hexdigest()[:24]


def load_cache():
    if os.path.exists(CACHE):
        with open(CACHE) as f:
            return json.load(f)
    return {"calls": {}}


def save_cache(c):
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(c, f, indent=1, sort_keys=True)
    os.replace(tmp, CACHE)


def spend(cache):
    return sum(float(v.get("usd", 0.0)) for v in cache.get("calls", {}).values())


# ---------------------------------------------------------------- dry run
def dry_run(man):
    err, _ = validate(man)
    lines = man.get("lines", [])
    cast = man.get("casting", {})
    print(f"manifest: {os.path.relpath(MANIFEST, ROOT)}")
    for e in err:
        print("  ERROR " + e)
    chars = sum(len(l.get("text", "")) for l in lines if isinstance(l, dict))
    by = {}
    for l in lines:
        if isinstance(l, dict):
            b = by.setdefault(l.get("speaker", "?"), [0, 0])
            b[0] += 1
            b[1] += len(l.get("text", ""))
    print(f"lines: {len(lines)} ({TOTAL_LINES} expected): " + ", ".join(f"{s} {n}" for s, (n, _) in by.items()))
    print(f"characters: {chars} ({', '.join(f'{s} {c}' for s, (_, c) in by.items())}); barks {BARK_WORDS[0]}-{BARK_WORDS[1]} words, "
          f"intros, acts and boss arrivals {LONG_WORDS[0]}-{LONG_WORDS[1]}")
    print(f"estimated cost: ${chars / 1000 * PRICE_PER_1K['elevenlabs']:.2f} on ElevenLabs' API (${PRICE_PER_1K['elevenlabs']:.2f} per 1,000 "
          f"characters; a subscription spends {chars} credits), ${chars / 1000 * PRICE_PER_1K['fal']:.2f} through fal "
          f"(${len(lines) * PRICE_PER_1K['fal']:.2f} if fal bills each request as at least 1,000 characters)")
    for sp, c in cast.items():
        print(f"  {sp:9s} {c.get('voice_id_env', '?'):18s} {c.get('model_id', '?')}  stability {c.get('stability')}  similarity {c.get('similarity_boost')}  "
              f"style {c.get('style')}  -> {c.get('bus')}  ({'set' if os.environ.get(str(c.get('voice_id_env'))) else 'not set'})")
    present, missing, size = [], [], 0
    for l in lines:
        if not isinstance(l, dict) or "speaker" not in l:
            continue
        p = ogg_path(l)
        if os.path.exists(p):
            present.append(l["id"])
            size += os.path.getsize(p)
        else:
            missing.append(l["id"])
    print(f"voice pack: {len(present)} of {len(lines)} .ogg present ({size / 1e6:.2f} MB), {len(missing)} missing (the game plays a chime for those)")
    if present and len(present) <= 12:
        print("  present: " + ", ".join(present))
    cache = load_cache()
    print(f"voice spend so far: ${spend(cache):.3f} over {len(cache.get('calls', {}))} calls ({os.path.relpath(CACHE, ROOT)}"
          f"{'' if os.path.exists(CACHE) else ', not created yet'})")
    keys = ", ".join(f"{k} {'set' if os.environ.get(k) else 'not set'}" for k in ("ELEVENLABS_API_KEY", "FAL_KEY"))
    print(f"keys: {keys}; ffmpeg {'found' if shutil.which('ffmpeg') else 'MISSING (needed by --generate)'}")
    print("dry run: no network calls made")
    return 1 if err else 0


# ---------------------------------------------------------------- providers
def _http(req, timeout=180, tries=4):
    for k in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read(), r.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            body = e.read()[:300].decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503, 504) and k < tries - 1:
                time.sleep(3 * (k + 1) ** 2)
                continue
            raise RuntimeError(f"HTTP {e.code} from {req.full_url.split('?')[0]}: {body}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            if k < tries - 1:
                time.sleep(3 * (k + 1) ** 2)
                continue
            raise RuntimeError(f"{req.full_url.split('?')[0]}: {e}") from None


def tts_elevenlabs(text, voice_id, cast):
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{urllib.parse.quote(voice_id)}?output_format=mp3_44100_128"
    body = {"text": text, "model_id": cast["model_id"],
            "voice_settings": {"stability": cast["stability"], "similarity_boost": cast["similarity_boost"],
                               "style": cast["style"], "use_speaker_boost": True}}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "audio/mpeg", "User-Agent": "shardfall-gen-voices"})
    if os.environ.get("ELEVENLABS_API_KEY"):
        req.add_header("xi-api-key", os.environ["ELEVENLABS_API_KEY"])
    data, ctype = _http(req)
    if not data or "json" in ctype:
        raise RuntimeError(f"ElevenLabs returned no audio ({ctype}): {data[:200]!r}")
    return data


def _fal(url, payload=None):
    req = urllib.request.Request(url, data=json.dumps(payload).encode() if payload is not None else None,
                                 method="POST" if payload is not None else "GET",
                                 headers={"Content-Type": "application/json", "User-Agent": "shardfall-gen-voices"})
    if os.environ.get("FAL_KEY"):
        req.add_header("Authorization", "Key " + os.environ["FAL_KEY"])
    data, _ = _http(req, timeout=120)
    return json.loads(data)


def tts_fal(text, voice_id, cast):
    if cast["model_id"] != "eleven_multilingual_v2":
        raise RuntimeError(f"fal's {FAL_ENDPOINT} only runs eleven_multilingual_v2, the casting asks for {cast['model_id']}")
    sub = _fal(f"https://queue.fal.run/{FAL_ENDPOINT}", {"text": text, "voice": voice_id, "stability": cast["stability"],
                                                         "similarity_boost": cast["similarity_boost"], "style": cast["style"]})
    t0 = time.time()
    while True:
        st = _fal(sub["status_url"])
        if st.get("status") == "COMPLETED":
            break
        if st.get("status") not in ("IN_QUEUE", "IN_PROGRESS") or time.time() - t0 > 300:
            raise RuntimeError(f"fal job {sub.get('request_id')}: {st}")
        time.sleep(2)
    out = _fal(sub["response_url"])
    url = (out.get("audio") or {}).get("url")
    if not url:
        raise RuntimeError(f"fal returned no audio url: {str(out)[:200]}")
    data, _ = _http(urllib.request.Request(url, headers={"User-Agent": "shardfall-gen-voices"}), timeout=120)
    return data


PROVIDERS = {"elevenlabs": tts_elevenlabs, "fal": tts_fal}


# ---------------------------------------------------------------- post-processing
def _ffmpeg(args, capture=False):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("ffmpeg failed: " + r.stderr.strip()[-400:])
    return r.stderr if capture else ""


def measure(path, pre=""):
    """Integrated loudness, true peak, loudness range and threshold (loudnorm's first pass) of a file."""
    af = (pre + "," if pre else "") + f"loudnorm=I={TARGET_LUFS}:TP={TARGET_TP}:LRA=11:print_format=json"
    err = _ffmpeg(["-i", path, "-af", af, "-f", "null", "-"], capture=True)
    return json.loads(err[err.rindex("{"):err.rindex("}") + 1])


def encode(raw, out):
    """raw (any format ffmpeg reads) -> the trimmed, loudness-normalised 44.1 kHz mono Vorbis clip at out, + .import."""
    m = measure(raw, TRIM)
    af = TRIM
    if m.get("input_i") not in (None, "-inf") and m.get("input_tp") not in (None, "-inf"):
        af += (f",loudnorm=I={TARGET_LUFS}:TP={TARGET_TP}:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}"
               f":measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    _ffmpeg(["-loglevel", "error", "-y", "-i", raw, "-af", af, "-ar", "44100", "-ac", "1", "-c:a", "libvorbis", "-q:a", "4", out])
    write_import(out)


def write_import(ogg):
    """A .ogg.import that never loops. Godot fills in the uid and the imported path on its next import; an
    existing file keeps them and only gets loop=false."""
    imp = ogg + ".import"
    if os.path.exists(imp):
        txt = open(imp).read()
        txt2 = re.sub(r"(?m)^loop=.*$", "loop=false", txt) if re.search(r"(?m)^loop=", txt) else txt.replace("[params]\n", "[params]\n\nloop=false\n")
        if txt2 != txt:
            open(imp, "w").write(txt2)
        return
    res = "res://" + os.path.relpath(ogg, GODOT).replace(os.sep, "/")
    with open(imp, "w") as f:
        f.write(IMPORT.format(res=res))


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels:format=duration",
                        "-of", "json", path], capture_output=True, text=True)
    j = json.loads(r.stdout or "{}")
    s = (j.get("streams") or [{}])[0]
    return {"codec": s.get("codec_name"), "rate": int(s.get("sample_rate", 0)), "channels": int(s.get("channels", 0)),
            "duration": float(j.get("format", {}).get("duration", 0.0))}


def selftest():
    """The post-processing chain on a synthetic line: 0.5 s of silence, 1.5 s of a voiced tone at about -30 LUFS,
    0.5 s of silence. It must come out trimmed, at -16 LUFS within 1 LU, peaking under -1 dBTP (+0.3 dB for the
    Vorbis encode), as 44.1 kHz mono Vorbis with a loop=false import. No network."""
    if not shutil.which("ffmpeg"):
        print("selftest: ffmpeg MISSING")
        return 1
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "line.wav")
        tone = "aevalsrc='0.06*sin(2*PI*140*t)*(1+0.6*sin(2*PI*4*t))+0.03*sin(2*PI*420*t)':s=44100:d=1.5"
        _ffmpeg(["-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=0.5", "-f", "lavfi", "-i", tone,
                 "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=0.5", "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", src])
        out = os.path.join(d, "voices", "warden", "cast_0.ogg")
        encode(src, out)
        p = probe(out)
        m = measure(out)
        imp = open(out + ".import").read()
        checks = [
            (p["codec"] == "vorbis" and p["rate"] == 44100 and p["channels"] == 1, f"44.1 kHz mono Vorbis ({p['codec']}, {p['rate']} Hz, {p['channels']} ch)"),
            (1.35 <= p["duration"] <= 1.75, f"silence trimmed: 2.5 s in, {p['duration']:.2f} s out"),
            (abs(float(m["input_i"]) - TARGET_LUFS) <= 1.0, f"loudness {float(m['input_i']):.1f} LUFS (target {TARGET_LUFS})"),
            (float(m["input_tp"]) <= TARGET_TP + 0.3, f"true peak {float(m['input_tp']):.1f} dBTP (ceiling {TARGET_TP})"),
            ("loop=false" in imp and 'importer="oggvorbisstr"' in imp, "a .ogg.import with loop=false"),
        ]
    bad = 0
    for ok, what in checks:
        print(("  ok   " if ok else "  FAIL ") + what)
        bad += 0 if ok else 1
    print(f"selftest: {len(checks) - bad} of {len(checks)} passed (no network calls)")
    return 1 if bad else 0


# ---------------------------------------------------------------- generate
def generate(man, provider, speaker, force, max_chars, reencode_only):
    err, _ = validate(man)
    if err:
        for e in err:
            print("ERROR " + e)
        return 1
    if not shutil.which("ffmpeg"):
        print("ERROR ffmpeg is needed to trim, normalise and encode the clips")
        return 1
    cast = man["casting"]
    lines = [l for l in man["lines"] if speaker in (None, l["speaker"])]
    if not lines:
        print(f"ERROR no lines for speaker {speaker!r}")
        return 1
    cache = load_cache()
    calls = cache.setdefault("calls", {})
    voice = {}
    if not reencode_only:
        need = sorted({cast[l["speaker"]]["voice_id_env"] for l in lines})
        missing = [e for e in need if not os.environ.get(e)]
        if missing:
            print("ERROR set the ElevenLabs voice IDs first: " + ", ".join(missing))
            return 1
        voice = {sp: os.environ[c["voice_id_env"]] for sp, c in cast.items() if os.environ.get(c["voice_id_env"])}
        if provider == "elevenlabs" and not os.environ.get("ELEVENLABS_API_KEY"):
            print("note: ELEVENLABS_API_KEY is not set; the request only works if a network proxy adds the key")
    todo, redo, keep = [], [], 0
    for l in lines:
        out = ogg_path(l)
        if reencode_only:
            hit = next((k for k, v in calls.items() if v.get("id") == l["id"] and os.path.exists(os.path.join(RAW, k + ".mp3"))), None)
            if hit:
                redo.append((l, hit))
            continue
        key = content_key(l, voice[l["speaker"]], cast[l["speaker"]])
        raw = os.path.join(RAW, key + ".mp3")
        if not force and key in calls and os.path.exists(raw):
            if os.path.exists(out) and calls[key].get("ogg_from") == key:
                keep += 1
            else:
                redo.append((l, key))
        else:
            todo.append((l, key))
    chars = sum(len(l["text"]) for l, _ in todo)
    print(f"{len(todo)} lines to synthesise ({chars} characters, about ${chars / 1000 * PRICE_PER_1K[provider]:.2f} via {provider}), "
          f"{len(redo)} to re-encode from kept downloads, {keep} up to date")
    if chars > max_chars:
        print(f"ERROR {chars} characters is over --max-chars {max_chars}; raise it to go ahead")
        return 1
    os.makedirs(RAW, exist_ok=True)
    tts = PROVIDERS[provider]
    for l, key in todo:
        raw = os.path.join(RAW, key + ".mp3")
        data = tts(l["text"], voice[l["speaker"]], cast[l["speaker"]])
        with open(raw, "wb") as f:
            f.write(data)
        calls[key] = {"id": l["id"], "provider": provider, "chars": len(l["text"]), "usd": round(len(l["text"]) / 1000 * PRICE_PER_1K[provider], 4),
                      "voice_id_env": cast[l["speaker"]]["voice_id_env"], "model_id": cast[l["speaker"]]["model_id"],
                      "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
        save_cache(cache)                                   # on disk after every paid call
        redo.append((l, key))
        print(f"  synthesised {l['id']} ({len(l['text'])} chars)")
    for l, key in redo:
        out = ogg_path(l)
        encode(os.path.join(RAW, key + ".mp3"), out)
        calls[key]["ogg_from"] = key
        p = probe(out)
        print(f"  {os.path.relpath(out, ROOT)}  {p['duration']:.2f} s  {os.path.getsize(out) / 1024:.0f} KB")
    save_cache(cache)
    total = sum(os.path.getsize(ogg_path(l)) for l in man["lines"] if os.path.exists(ogg_path(l)))
    print(f"voice pack: {sum(os.path.exists(ogg_path(l)) for l in man['lines'])} of {len(man['lines'])} clips, {total / 1e6:.2f} MB; "
          f"voice spend so far ${spend(cache):.3f}. Next: python3 tools/gate_check.py")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="validate, count and estimate (the default); no network")
    mode.add_argument("--generate", action="store_true", help="synthesise the missing or changed lines")
    mode.add_argument("--reencode", action="store_true", help="rebuild the .ogg files from tools/.voice_raw (free)")
    mode.add_argument("--selftest", action="store_true", help="the ffmpeg chain on a synthetic clip (free)")
    who = ap.add_mutually_exclusive_group()
    who.add_argument("--speaker", choices=sorted(EXPECTED), help="only this speaker's lines")
    who.add_argument("--all", action="store_true", help="every speaker (the default)")
    ap.add_argument("--provider", choices=sorted(PROVIDERS), default="elevenlabs")
    ap.add_argument("--force", action="store_true", help="synthesise again even when nothing changed (pays again)")
    ap.add_argument("--max-chars", type=int, default=6000, help="refuse a run that would send more characters (default 6000)")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    man = load_manifest()
    if a.generate or a.reencode:
        return generate(man, a.provider, a.speaker, a.force, a.max_chars, a.reencode)
    return dry_run(man)


if __name__ == "__main__":
    sys.exit(main())
