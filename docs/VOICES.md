# Voices

Every spoken line in Shardfall lives in one file, `godot/data/voice_manifest.json`: 61 lines for the four
exiles, the narrator and the two bosses, with the ElevenLabs casting for each speaker. The game reads it
(`VoiceBank`) and so does the generator (`tools/gen_voices.py`). Nothing else holds a line's words: the gate
fails if a script repeats one. (The story's written half, the act banners, Rift Echoes and bios, lives in
`godot/scripts/data/story.gd` and never repeats a spoken line.)

Until the voice pack exists, each line plays a short chime of its speaker's own and shows its subtitle for the
manifest's estimated length. Drop the clips in and the game plays them instead, timed to their real length.
No script changes are needed.

## Making the voice pack (two commands)

Set the key. The seven voices default to ElevenLabs stock (premade) voices, one per speaker (the casting
table below), so no voice IDs are needed; set any `EL_VOICE_*` variable to cast your own voice instead.

| Variable | What |
|---|---|
| `ELEVENLABS_API_KEY` | your ElevenLabs API key (sent as the `xi-api-key` header) |
| `EL_VOICE_WARDEN` | optional: a voice ID for the Warden (default: stock Clyde) |
| `EL_VOICE_SPARK` | optional: the Sparkcaller (default: stock Freya) |
| `EL_VOICE_EMBER` | optional: the Emberwitch (default: stock Charlotte) |
| `EL_VOICE_STORM` | optional: the Stormwright (default: stock Daniel) |
| `EL_VOICE_NARRATOR` | optional: the narrator (default: stock George) |
| `EL_VOICE_TYRANT` | optional: the act bosses and the Rift Guardian (default: stock Callum) |
| `EL_VOICE_HERALD` | optional: the Shard Herald (default: stock Emily) |
| `FAL_KEY` | only with `--provider fal` (fal's ElevenLabs endpoint; there a voice name such as "Aria" also works) |

In a Claude cloud session, add the key as a network secret for `api.elevenlabs.io` (header `xi-api-key`)
rather than an environment variable: the proxy adds it to each request.

Then:

```bash
python3 tools/gen_voices.py --generate --provider elevenlabs
```

```bash
python3 tools/gate_check.py
```

The first checks that ffmpeg is installed before anything else, synthesises every line that has no clip yet
and writes `godot/audio/voices/<speaker>/<cue>_<n>.ogg`. The second checks everything and builds the APK with
the clips in it.

`python3 tools/gen_voices.py` on its own is a dry run (`--dry-run` is the default). It validates the manifest,
counts the lines and characters, checks that every speaker's casting is distinct, lists the escalation lines,
estimates the cost and lists which clips are present. It makes no network calls.

Other modes:
- `--speaker ember` generates one speaker only (`--all` is the default).
- `--provider fal` goes through fal.ai instead of ElevenLabs' own API.
- `--force` regenerates lines that haven't changed (and pays again).
- `--reencode` rebuilds the `.ogg` files from the kept downloads (free).
- `--selftest` runs the ffmpeg chain on a synthetic clip (free).

## Cost

The pack is 4,064 characters (the manifest must stay within 4,000-5,500). At $0.10 per 1,000 characters (fal's
ElevenLabs Multilingual v2 price, and ElevenLabs' usage-based API rate; some of their pages show $0.08), it
costs about **$0.41**. On an ElevenLabs subscription it spends 4,064 credits. One unconfirmed listing says fal
bills each request as at least 1,000 characters; if so, the 61 requests would cost about $6.10.

The generator never pays twice for a line:
- `tools/voice_cache.json` records every call under a content key: sha256 of the line's id, text, voice ID,
  model and voice settings.
- An unchanged line is skipped. Change a line's text or its speaker's casting and only that line is sent again.
- The raw downloads stay in `tools/.voice_raw/` (not committed), so re-encoding is free.
- A run refuses to send more than `--max-chars` (default 6,000) characters.

## What happens to each clip

1. ElevenLabs text-to-speech: `eleven_multilingual_v2` with the speaker's stability, similarity boost and
   style. Requested as 44.1 kHz MP3 (`POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`).
2. ffmpeg trims leading and trailing silence (`silenceremove`, −50 dB).
3. Two-pass `loudnorm` brings it to **−16 LUFS, −1.0 dBTP**.
4. It is encoded as **44.1 kHz mono Ogg Vorbis, `-q:a 4`** (about 64 kbps for speech).
5. A `.ogg.import` with `loop=false` is written beside it; Godot fills in the rest on its next import.

The whole pack must stay under **2.5 MB** (the generator fails a run that ends over it, and so does the gate).

## Casting

| Speaker | Voice direction | Default voice | Variable | Stability | Similarity | Style | Bus |
|---|---|---|---|---|---|---|---|
| Warden | stoic, gravelly, oath-bound vanguard baritone | Clyde `2EiwWnXFnvU5JabPnv8n` | `EL_VOICE_WARDEN` | 0.68 | 0.78 | 0.25 | VoiceHero |
| Sparkcaller | fast, bright, irreverent arcane skirmisher | Freya `jsCqWAovK2LkecY7zXl4` | `EL_VOICE_SPARK` | 0.38 | 0.74 | 0.65 | VoiceHero |
| Emberwitch | low, smoky, feverish contagion pyromancer | Charlotte `XB0fDUnXU5powFXDhCwa` | `EL_VOICE_EMBER` | 0.33 | 0.82 | 0.75 | VoiceHero |
| Stormwright | cold, commanding, formal tempest scholar | Daniel `onwK4e9ZLuTAKqWW03F9` | `EL_VOICE_STORM` | 0.72 | 0.80 | 0.35 | VoiceHero |
| Narrator | weathered dark-fantasy chronicler | George `JBFqnCBsd6RMkjVDRZzb` | `EL_VOICE_NARRATOR` | 0.78 | 0.76 | 0.18 | VoiceNarrator |
| Tyrant (act bosses, Rift Guardian) | menacing warlord | Callum `N2lVS1w4EtoT3dr4eOWO` | `EL_VOICE_TYRANT` | 0.50 | 0.85 | 0.55 | VoiceBoss |
| The Shard Herald | cold crystalline entity | Emily `LcfcDJNUP1GQjkzn1xUU` | `EL_VOICE_HERALD` | 0.62 | 0.70 | 0.45 | VoiceBoss |

All use `eleven_multilingual_v2`. No two speakers share a stability, similarity boost or style value, and no
two share a default voice; the dry run and the gate check both. The boss bus pitches its voices down to 0.90
and adds a reverb, so record them at their natural pitch.

## The lines

Each line in the manifest has these fields:
- `id`: `<speaker>_<cue>_<n>`.
- `speaker`, `cue` and `variant`.
- `file`: always `res://audio/voices/<speaker>/<cue>_<n>.ogg`.
- `text`: the spoken script. It is also the subtitle, word for word.
- `priority` and `cooldown_s`, from the table below.
- `duration_fallback_s`: the estimated spoken length (words ÷ the speaker's pace + 0.3 s), used until the clip
  exists.
- `escalation` (four lines) and `random` (see below).

| Who | Cues | Lines |
|---|---|---|
| each exile | `intro` 1, `cast` 3, `ult` 2, `kill_streak` 2, `low_hp` 2, `boss_spawn` 1, `death` 1 | 12 each, 48 |
| narrator | `intro` 4 (the cold open's beats), `act_0`–`act_4` 1 each | 9 |
| tyrant, herald | `spawn` 1, `die` 1 | 4 |

Combat barks are 3–12 words. The exiles' intros, act openings and the bosses' arrivals are 10–26 words. The
narrator's four cold-open beats are 4–8 words (about 2.5 s each, so the cold open runs about 12 s). The dry run
enforces the limits; edit a line and run it to check.

### Escalations

Four lines answer a moment of their own instead of their cue's usual trigger (`VoiceDirector`):

| Trigger | Line | When |
|---|---|---|
| `burning_12` | the Emberwitch's `kill_streak` 1 (her frenzy) | 12 or more foes burning at once; again once fewer than 8 burn |
| `hp_30` | the Warden's `low_hp` 1 (his oath) | the first time his life falls under 30% in a run |
| `ricochet_2` | the Sparkcaller's `cast` 2 | a Rime Bolt's second ricochet off stone |
| `conduct` | the Stormwright's `cast` 2 | Skyfall conducted through shallow water or a rift crystal |

`"random": false` keeps the frenzy, ricochet and conduction lines out of their cue's ordinary picks; the oath
can also come up as an ordinary low-life line later in a run.

## In the game

- **Priorities.** Only one line plays at a time:
  - a line of higher priority cuts the current one off with a 0.08 s fade;
  - a line of equal or lower priority is skipped while another plays.
  - The priorities are: 3 intros, boss lines, an exile's boss reply and death, act openings; 2 low life and
    ultimate; 1 kill streak; 0 cast.
- **Cooldowns.**
  - Each cue waits its own `cooldown_s` from its start: cast 7 s, kill streak 10 s, low life 15 s, ultimate 4 s.
  - A priority 0–1 bark also waits 2.8 s after the last line ended (or after the current one started).
- **Ducking.** While a line plays, the Music bus drops 6 dB and SFX 3 dB, fading in over 0.12 s and back over
  0.25 s.
- **Stopping.** `VoiceBank.stop_all()` is immediate: every voice stops, the ducking is cancelled and the Music
  and SFX buses are back at 0 dB. The cold open's Tap and Skip, the hero showcase, leaving a run and the main
  menu all use it.
- **Subtitles.**
  - Each line's subtitle stays up for its length + 0.35 s.
  - During play they sit above the action bar; in menus and on the level-up, pause and end screens they move
    to the top, and every page keeps that band clear.
- **Buses.**
  - Master takes Music, SFX, UI and Voice.
  - Voice takes VoiceHero (a compressor, so barks cut through a fight), VoiceNarrator, and VoiceBoss (a 0.90
    pitch shift and a reverb).
  - Options › Audio: Master sets the Master bus and Voice the Voice bus (0 mutes either); Music and SFX scale
    their players, so the ducking can always return those two buses to 0 dB.
- **Memory.** At most 16 clips stay loaded, dropping the least recently used.
- **The cold open.**
  - On first launch, and from Main Menu › Replay Intro, the narrator's four beats play over Act I itself: the
    camera sweeps down over Mossglen Hollow while a Rift Shard streaks in and strikes, then glides on as the
    screen fades into the title.
  - Each beat holds for its line's length + 0.5 s. Tap moves on and Skip ends it; both call
    `VoiceBank.stop_all()` and mark the intro seen.
- **Hero showcase.** Main Menu › Heroes: picking an exile stops whatever was speaking, frames them, and they
  cast and settle to idle while their intro line plays.
- **In a run** (`VoiceDirector`):
  - A campaign run opens with its act's narration.
  - A boss arrives with its spawn line and the exile replies; the boss's fall plays its die line.
  - The ultimate plays an ult line.
  - The first drop under 30% life plays a low-life line, re-armed above 50%.
  - Kill streaks of 25, 50, 100, 200, 400 and 800 play a streak line.
  - Now and then a weapon cast in a fight barks.
  - The escalations above.
  - Death plays the exile's last line.
  - It only listens to the simulation; it never changes it.

Code:
- `godot/scripts/audio/voice_bank.gd` (the `Voice` autoload).
- `godot/scripts/audio/voice_director.gd`.
- `godot/scripts/ui/subtitles.gd`.
- `godot/scripts/ui/intro_screen.gd` and `godot/scripts/render3d/cold_open.gd`.

The tests are the "0.10.0 voice" and "0.10.0 alpha" groups in `godot/tests/run_tests.gd`, plus the voice
section of `tools/gate_check.py`.
