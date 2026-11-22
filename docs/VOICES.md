# Voices

Every spoken line in Shardfall lives in one file, `godot/data/voice_manifest.json`: 61 lines for the four
exiles, the narrator and the two bosses, with the ElevenLabs casting for each speaker. The game reads it
(`VoiceBank`) and so does the generator (`tools/gen_voices.py`). Nothing else holds a line's words: the gate
fails if a script repeats one.

Until the voice pack exists, each line plays a short chime of its speaker's own and shows its subtitle for the
manifest's estimated length. Drop the clips in and the game plays them instead, timed to their real length.
No script changes are needed.

## Making the voice pack (two commands)

Set the keys and the seven voice IDs (pick or design the voices in ElevenLabs' Voice Library, one per
speaker, using the casting notes below):

| Variable | What |
|---|---|
| `ELEVENLABS_API_KEY` | your ElevenLabs API key (sent as the `xi-api-key` header) |
| `EL_VOICE_WARDEN` | voice ID for the Warden |
| `EL_VOICE_SPARK` | voice ID for the Sparkcaller |
| `EL_VOICE_EMBER` | voice ID for the Emberwitch |
| `EL_VOICE_STORM` | voice ID for the Stormwright |
| `EL_VOICE_NARRATOR` | voice ID for the narrator |
| `EL_VOICE_TYRANT` | voice ID for the act bosses and the Rift Guardian |
| `EL_VOICE_HERALD` | voice ID for the Shard Herald |
| `FAL_KEY` | only with `--provider fal` (fal's ElevenLabs endpoint; there a voice name such as "Aria" also works) |

In a Claude cloud session, add the key as a network secret for `api.elevenlabs.io` (header `xi-api-key`)
rather than an environment variable: the proxy adds it to each request.

Then:

```bash
python3 tools/gen_voices.py --generate
```

```bash
python3 tools/gate_check.py
```

The first synthesises every line that has no clip yet and writes `godot/audio/voices/<speaker>/<cue>_<n>.ogg`.
The second checks everything and builds the APK with the clips in it.

`python3 tools/gen_voices.py` on its own is a dry run. It validates the manifest, counts the lines and
characters, estimates the cost, and lists which clips are present. It makes no network calls.

Other modes:
- `--speaker ember` generates one speaker only (`--all` is the default).
- `--provider fal` goes through fal.ai instead of ElevenLabs' own API.
- `--force` regenerates lines that haven't changed (and pays again).
- `--reencode` rebuilds the `.ogg` files from the kept downloads (free).
- `--selftest` runs the ffmpeg chain on a synthetic clip (free).

## Cost

The pack is 3,909 characters. At $0.10 per 1,000 characters (fal's ElevenLabs Multilingual v2 price, and
ElevenLabs' usage-based API rate; some of their pages show $0.08), it costs about **$0.39**. On an ElevenLabs
subscription it spends 3,909 credits. One unconfirmed listing says fal bills each request as at least 1,000
characters; if so, the 61 requests would cost about $6.10.

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

The whole pack should come to about 2 MB; the gate fails it above 2.5 MB. The manifest's estimates add up
to 335 s of speech, and real clips are usually shorter.

## Casting

| Speaker | Voice direction | Variable | Stability | Similarity | Style | Bus |
|---|---|---|---|---|---|---|
| Warden | stoic, gravelly, oath-bound vanguard baritone | `EL_VOICE_WARDEN` | 0.68 | 0.78 | 0.25 | VoiceHero |
| Sparkcaller | fast, bright, irreverent arcane skirmisher | `EL_VOICE_SPARK` | 0.38 | 0.75 | 0.65 | VoiceHero |
| Emberwitch | low, smoky, feverish contagion pyromancer | `EL_VOICE_EMBER` | 0.35 | 0.80 | 0.75 | VoiceHero |
| Stormwright | cold, commanding, formal tempest scholar | `EL_VOICE_STORM` | 0.72 | 0.80 | 0.35 | VoiceHero |
| Narrator | weathered dark-fantasy chronicler | `EL_VOICE_NARRATOR` | 0.75 | 0.75 | 0.20 | VoiceNarrator |
| Tyrant (act bosses, Rift Guardian) | menacing warlord | `EL_VOICE_TYRANT` | 0.55 | 0.80 | 0.50 | VoiceBoss |
| The Shard Herald | cold crystalline entity | `EL_VOICE_HERALD` | 0.55 | 0.75 | 0.50 | VoiceBoss |

All use `eleven_multilingual_v2`. The four exiles must stay on different voices and different
stability/style profiles; the gate checks both. The boss bus pitches its voices down to 0.90 and adds a
reverb, so record them at their natural pitch.

## The lines

Each line in the manifest has these fields:
- `id`: `<speaker>_<cue>_<n>`.
- `speaker`, `cue` and `variant`.
- `file`: always `res://audio/voices/<speaker>/<cue>_<n>.ogg`.
- `text`: the spoken script. It is also the subtitle, word for word.
- `priority` and `cooldown_s`, from the table below.
- `duration_fallback_s`: the estimated spoken length, used until the clip exists.

| Who | Cues | Lines |
|---|---|---|
| each exile | `intro` 1, `cast` 3, `ult` 2, `kill_streak` 2, `low_hp` 2, `boss_spawn` 1, `death` 1 | 12 each, 48 |
| narrator | `intro` 4 (the cold open), `act_0`–`act_4` 1 each | 9 |
| tyrant, herald | `spawn` 1, `die` 1 | 4 |

Combat barks are 3–8 words. Intros, act openings and the bosses' arrivals are 10–22 words. The word limits
cap a 61-line pack at about 4,000 characters, so the pack is 3,909 rather than the 4,000–5,500 first
budgeted. The dry run enforces the limits; edit a line and run it to check.

## In the game

- **Priorities.** Only one line plays at a time:
  - a line of higher priority cuts the current one off with a 0.08 s fade;
  - a line of equal or lower priority is skipped while another plays.
  - The priorities are: 0 cast; 1 kill streak; 2 low life and ultimate; 3 boss lines, an exile's boss
    reply and death, act openings; 4 intros.
- **Cooldowns.**
  - Each cue waits its own `cooldown_s` from its start: cast 7 s, kill streak 10 s, low life 15 s, ultimate 4 s.
  - A priority 0–1 bark also waits 2.8 s after the last line ended (or after the current one started).
- **Ducking.** While a line plays, the Music bus drops 6 dB and SFX 3 dB, fading in over 0.12 s and back over
  0.25 s.
- **Subtitles.**
  - Each line's subtitle stays up for max(2.0 s, length + 0.35 s), so a clip is never cut off on screen.
  - During play they sit above the action bar; in menus and on the level-up, pause and end screens they move
    to the top.
- **Buses.**
  - Master takes Music, SFX, UI and Voice.
  - Voice takes VoiceHero (a compressor, so barks cut through a fight), VoiceNarrator, and VoiceBoss (a 0.90
    pitch shift and a reverb).
  - Options › Voice volume sets the Voice bus; 0 mutes it.
- **Memory.** At most 16 clips stay loaded, dropping the least recently used.
- **The intro.**
  - On first launch, the narrator's four beats play over a dark screen (Options › Replay intro shows them
    again).
  - Each beat holds for its line's length + 0.6 s. A tap moves on, and Skip ends it, stopping the narrator.
- **Hero select.** Picking an exile on the title screen stops the previous intro line. The exile casts, then
  settles to idle, while their intro plays.
- **In a run** (`VoiceDirector`):
  - A campaign run opens with its act's narration.
  - A boss arrives with its spawn line and the exile replies; the boss's fall plays its die line.
  - The ultimate plays an ult line.
  - The first drop under 30% life plays a low-life line, re-armed above 50%.
  - Kill streaks of 25, 50, 100, 200, 400 and 800 play a streak line.
  - Now and then a weapon cast in a fight barks.
  - Death plays the exile's last line.
  - It only listens to the simulation; it never changes it.

Code:
- `godot/scripts/audio/voice_bank.gd` (the `Voice` autoload).
- `godot/scripts/audio/voice_director.gd`.
- `godot/scripts/ui/subtitles.gd`.
- `godot/scripts/ui/intro_screen.gd`.

The tests are the "0.10.0 voice" group in `godot/tests/run_tests.gd`, plus section 6 of
`tools/gate_check.py`.
