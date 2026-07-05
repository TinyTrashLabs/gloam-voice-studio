#!/usr/bin/env python3
"""Phase 0 harness — does OpenAudio S1-mini apply emotion markers WHILE cloning?

Generates the SAME line from the SAME reference clip with a FIXED SEED, varying only
the leading emotion marker: base, (angry), (whisper), (sad), (excited). Fixing the seed
is the whole point — if the clips differ, it's the marker, not sampling randomness.
Then it runs measure_audio.py for the go/no-go verdict.

This drives the fish-speech HTTP API server (its `/v1/tts` endpoint, ormsgpack body).
That's the most stable surface. START THE SERVER FIRST (see README.md), then run this.

    pip install ormsgpack requests          # (in the fish-speech venv)
    python run_s1_emotion_test.py

⚠️ fish-speech's request schema evolves — if a field is rejected, open the current
`ServeTTSRequest` in the fish-speech repo (tools/server/*) and adjust REQUEST_BASE below.
If the HTTP path is a pain, the README's "manual path" (WebUI / CLI) gets the same clips;
just point measure_audio.py at them.
"""
import os, sys, subprocess

try:
    import ormsgpack, requests
except Exception:
    sys.exit("pip install ormsgpack requests  (inside the fish-speech venv)")

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.environ.get("FISH_API", "http://127.0.0.1:8080/v1/tts")
REF_WAV = os.path.join(HERE, "reference.wav")
REF_TXT = open(os.path.join(HERE, "reference.txt")).read().strip()
OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)

# The line every clip speaks. S1 uses (parentheses) markers at the sentence start.
LINE = "So here's the plan, and I need you to really hear me on this one."
PROMPTS = {
    "base":    LINE,
    "angry":   f"(angry) {LINE}",
    "whisper": f"(whisper) {LINE}",
    "sad":     f"(sad) {LINE}",
    "excited": f"(excited) {LINE}",
}

# Same seed for every clip → differences are the MARKER, not sampling.
REQUEST_BASE = dict(
    references=[dict(audio=open(REF_WAV, "rb").read(), text=REF_TXT)],
    format="wav",
    chunk_length=200,
    top_p=0.8,
    repetition_penalty=1.1,
    temperature=0.8,
    max_new_tokens=1024,
    seed=1234,
)


def synth(name, text):
    req = dict(REQUEST_BASE, text=text)
    r = requests.post(SERVER, data=ormsgpack.packb(req),
                      headers={"content-type": "application/msgpack"}, timeout=300)
    r.raise_for_status()
    path = os.path.join(OUT, f"{name}.wav")
    with open(path, "wb") as f:
        f.write(r.content)
    print(f"  wrote {path} ({len(r.content)} bytes)")
    return path


def main():
    print(f"Reference: {REF_WAV}\nTranscript: {REF_TXT!r}\nServer: {SERVER}\n")
    paths = []
    for name, text in PROMPTS.items():
        print(f"[{name}] {text!r}")
        try:
            paths.append(synth(name, text))
        except Exception as e:
            print(f"  FAILED: {e}\n  (adjust REQUEST_BASE to the current ServeTTSRequest schema)")
    if len(paths) >= 2:
        print("\n" + "=" * 60)
        subprocess.run([sys.executable, os.path.join(HERE, "measure_audio.py"), *paths])
        print("=" * 60)
        print("\nNow GOLDEN-DUMP: with the same reference+text, dump the exact input token")
        print("IDs the model receives (see README §4) and save them — the Swift port")
        print("(Phase 2) validates its tokenizer + model logits against them.")


if __name__ == "__main__":
    main()
