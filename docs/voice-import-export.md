# Voice profiles: import, export, and moving them around

How to get a voice in or out of the engine — verified end-to-end 2026-07-26
by importing Billie Frost from a bake reference. Endpoint reference:
[api.md](api.md). Everything below talks to the engine at
`http://127.0.0.1:8799`.

## What a voice is

One reference clip plus its exact transcript, addressed by slug:

```json
{"slug": "cruz", "name": "Cruz", "refText": "Hey, welcome in. …", "createdAt": "…"}
```

- **Reference audio**: 10–30 s of clean, mono speech in the voice. The engine
  clones zero-shot from this clip; there is no training step.
- **`refText`**: the words actually spoken in the clip, verbatim. A wrong or
  partial transcript audibly degrades the clone.
- **Variants convention**: emotion flavors are separate voices with suffixed
  slugs — `cruz`, `cruz-chill`, `cruz-hyped` — each with its own reference
  clip in that mood. Delivery-hint tags like `[calm]`/`[excited]` may appear
  inside a variant's `refText`.

## The `.gvoice` pack

`GET /voices/:slug/export` returns a zip (`Content-Disposition:
<slug>.gvoice`) containing exactly:

| entry | content |
|---|---|
| `meta.json` | `{"slug", "name", "refText", "createdAt"}` |
| `ref.wav` | the reference audio bytes |

**The `ref.wav` entry is not necessarily WAV.** Bundled voices store 128 kbps
mono MP3 bytes under the name `ref.wav`; the engine decodes via CoreAudio,
which sniffs the real container. Keep that trick when building packs — see
the size cap below.

## The 2 MB rule (HTTP 413)

`POST /voices/import` takes `{"data": "<base64 of the .gvoice>"}` in a JSON
body, and the server caps request bodies at 2 MB. Base64 inflates by ~33%,
so the pack itself must stay under ~1.5 MB. A 27 s reference as 44.1 kHz
PCM-16 blows past that; the same clip as 128 kbps MP3 is ~425 KB. Rules of
thumb:

- Encode the reference as **mono MP3 (~128 kbps)** before packing, or
- keep PCM references **under ~15 s at 24 kHz**, or you will get `413`.

The direct-create route (`POST /voices` with `refAudio` base64 WAV) has the
same body cap — same math applies.

## Recipes

### Export a voice (backup / move between machines)

```bash
curl -s http://127.0.0.1:8799/voices/cruz/export -o cruz.gvoice
```

### Import a pack

```bash
python3 - <<'PY'
import base64, json
print(json.dumps({"data": base64.b64encode(open("cruz.gvoice","rb").read()).decode()}))
PY
# → import.json, then:
curl -s -X POST http://127.0.0.1:8799/voices/import \
  -H "Content-Type: application/json" --data @import.json
```

Import is idempotent-by-slug: re-importing an existing slug errors; delete
first (`curl -X DELETE …/voices/<slug>`) to replace wholesale, or use
`PATCH /voices/:slug` for in-place edits (renaming re-slugs).

### Build a pack from a raw recording (the Billie Frost path)

```bash
uv run --python 3.12 --with soundfile --with numpy --with lameenc python3 - <<'PY'
import base64, datetime, io, json, zipfile
import numpy as np, soundfile as sf, lameenc

REF, TEXT = "billie_ref.wav", open("billie_ref.txt").read().strip()
w, sr = sf.read(REF, dtype="float32", always_2d=True)
pcm = (np.clip(w.mean(axis=1), -1, 1) * 32767).astype(np.int16)
enc = lameenc.Encoder()
enc.set_bit_rate(128); enc.set_in_sample_rate(sr); enc.set_channels(1); enc.set_quality(2)
mp3 = bytes(enc.encode(pcm.tobytes())) + bytes(enc.flush())

meta = {"createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "slug": "billie-frost", "refText": TEXT, "name": "Billie Frost"}
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("meta.json", json.dumps(meta))
    z.writestr("ref.wav", mp3)
open("import.json", "w").write(json.dumps({"data": base64.b64encode(buf.getvalue()).decode()}))
PY
curl -s -X POST http://127.0.0.1:8799/voices/import \
  -H "Content-Type: application/json" --data @import.json
```

(No ffmpeg on the machine is why `lameenc` — mlx-whisper and afconvert can't
encode MP3.)

### Verify a new voice end-to-end

```bash
curl -s http://127.0.0.1:8799/voices | python3 -m json.tool | grep slug
curl -s -X POST http://127.0.0.1:8799/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"Quick check — one two three.","voice":"billie-frost"}' \
  -o check.wav && afplay check.wav
```

First synth after an engine start pays the model cold-load (can be ~2 min on
first-ever run; ~10 s per line after).

## How the gloam app picks these up

The mac shell's web app lists the engine's voices dynamically
(`LocalTtsClient` fetches `/voices` lazily on first synth) — an imported
voice appears in the DJ voice picker by its `name` with no app rebuild or
restart. TTS goes through the OpenAI-compatible `POST /v1/audio/speech`
with `voice: <slug>`.
