# Audio

Everything here was generated for this game and replaces the synthesised placeholder of the same
name (`Sfx` loads `sfx/<name>.wav` and `music/<act>.ogg` when they exist).

- `sfx/*.wav`: ElevenLabs sound effects (via fal), trimmed, mono 44.1 kHz, peak-normalised to the
  level of the synthesised sound each one replaces.
- `music/0-4.ogg`: one 33 s loop per act from Google Lyria 2 (via fal), the tail cross-faded into
  the head so the loop has no seam. Imported with `loop=true`.

Regenerate with `python3 tools/fal/audio.py sfx <work dir> [names]` and `... music <work dir> [acts]`;
the prompts are in that file. Delete a file to fall back to the synthesiser.
