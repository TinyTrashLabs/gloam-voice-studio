#!/usr/bin/env python3
"""Phase 0 measurement — are the emotion variants actually distinct?

This is the go/no-go instrument. It's deliberately dependency-light and correct:
given several WAVs (base, angry, whisper, …) it reports per-clip acoustic features
and a pairwise distinctness verdict. If (angry) vs (whisper) come out with nearly
identical energy/brightness/pace — the same failure we already measured with the
Qwen3 S2 port — emotion is NOT working and Phase 0 is a NO-GO.

Usage:
    python measure_audio.py out/base.wav out/angry.wav out/whisper.wav out/sad.wav

Only needs the stdlib. Uses numpy for the spectral feature if available (optional).
"""
import sys, os, wave, array, math

try:
    import numpy as np
    HAVE_NP = True
except Exception:
    HAVE_NP = False


def load(path):
    w = wave.open(path, "rb")
    n, sr, ch, sw = w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()
    raw = w.readframes(n); w.close()
    if sw != 2:
        raise SystemExit(f"{path}: expected 16-bit PCM, got sampwidth={sw}")
    a = array.array("h"); a.frombytes(raw)
    if ch > 1:
        a = a[::ch]  # take channel 0
    return list(a), sr


def features(samples, sr):
    n = len(samples)
    if n == 0:
        return dict(dur=0, rms=0, peak=0, crest=0, zcr=0, centroid=0)
    rms = math.sqrt(sum(x * x for x in samples) / n)
    peak = max(abs(x) for x in samples) or 1
    crest = peak / rms if rms else 0
    # zero-crossing rate — a rough proxy for pace/agitation
    zc = sum(1 for i in range(1, n) if (samples[i - 1] >= 0) != (samples[i] >= 0))
    zcr = zc / n
    centroid = 0.0
    if HAVE_NP:
        x = np.asarray(samples, dtype=np.float64)
        x = x - x.mean()
        win = np.hanning(len(x)) if len(x) > 1 else np.ones(len(x))
        spec = np.abs(np.fft.rfft(x * win))
        freqs = np.fft.rfftfreq(len(x), 1.0 / sr)
        centroid = float((freqs * spec).sum() / (spec.sum() + 1e-9))  # brightness (Hz)
    return dict(dur=n / sr, rms=rms, peak=peak, crest=crest, zcr=zcr, centroid=centroid)


def main(paths):
    rows = {}
    print(f"{'clip':14s} {'dur':>6s} {'rms':>8s} {'crest':>6s} {'zcr':>7s} {'centroid':>9s}")
    for p in paths:
        name = os.path.splitext(os.path.basename(p))[0]
        try:
            s, sr = load(p)
            f = features(s, sr)
            rows[name] = f
            cen = f"{f['centroid']:8.0f}" if HAVE_NP else "    (np?)"
            print(f"{name:14s} {f['dur']:6.2f} {f['rms']:8.0f} {f['crest']:6.2f} "
                  f"{f['zcr']:7.4f} {cen}")
        except Exception as e:
            print(f"{name:14s}  ERROR: {e}")

    # Verdict: compare the emotional clips against the base and each other.
    names = list(rows)
    if len(names) < 2:
        print("\nNeed at least 2 clips to judge distinctness."); return
    print("\n--- distinctness vs each other (relative % difference) ---")
    def rel(a, b):
        return abs(a - b) / (abs(a) + abs(b) + 1e-9) * 2 * 100
    distinct_pairs = 0
    total_pairs = 0
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = rows[names[i]], rows[names[j]]
            drms = rel(a["rms"], b["rms"])
            dzcr = rel(a["zcr"], b["zcr"])
            dcen = rel(a["centroid"], b["centroid"]) if HAVE_NP else 0
            # "meaningfully different" heuristic: any feature differs by >12%
            diff = max(drms, dzcr, dcen)
            mark = "DISTINCT" if diff > 12 else "~same"
            total_pairs += 1
            if diff > 12:
                distinct_pairs += 1
            print(f"{names[i]:>10s} vs {names[j]:<10s}  "
                  f"rms {drms:4.0f}%  zcr {dzcr:4.0f}%  centroid {dcen:4.0f}%   -> {mark}")

    print("\n=== VERDICT ===")
    if distinct_pairs >= max(1, total_pairs // 2):
        print(f"GO — {distinct_pairs}/{total_pairs} pairs are acoustically distinct. "
              "Emotion markers appear to WORK. Capture the golden token dump and proceed.")
    else:
        print(f"NO-GO — only {distinct_pairs}/{total_pairs} pairs differ. Emotion markers "
              "are NOT moving the audio (same failure as the S2 port). Do NOT start the "
              "Swift port; re-check the model/prompt, or the premise is dead.")
    print("(Also LISTEN — numbers are a screen, ears are the real test.)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    main(sys.argv[1:])
