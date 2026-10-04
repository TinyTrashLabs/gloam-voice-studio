# QwenANE

Qwen3-TTS 0.6B on the Neural Engine. The talker and code predictor (stateful Core ML, iOS 18 /
macOS 15) and the vocoder upsampler run as `.mlmodelc`; the text projection, tokenizer, prompt
building, sampler and the vocoder head run on the CPU (Accelerate). Foundation, CoreML and
Accelerate only: no MLX, no ONNX Runtime.

```swift
let engine = try QwenANEEngine(modelsDirectory: modelsURL)      // seconds; once per process
let voice = try engine.loadVoice(named: "jeff")                 // or QwenVoiceFiles(refText:refCodes:spkEmbedding:)
let r = try engine.render(text: "Good evening.", voice: voice, seed: 7,
                          cancelled: { false }, pace: { /* duty-cycle sleep */ })
// r.samples: [Float] mono, r.sampleRate == 24000, r.frames, r.stopReason, r.timings
```

Streaming: pass `onAudio: { chunk in ... }` to `render` to receive each decoded vocoder chunk (12 frames,
0.96 s) as soon as it is ready, in order, from the vocoder queue. The chunks are trimmed by
`QwenStreamTrimmer`: leading silence is capped at 0.05 s, trailing silence is held back (at most 0.1 s is
delivered at the end), and internal pauses are NOT shortened (the finished `QwenRender.samples` still gets
`Options.capPauses`, unchanged). Each delivered sample is a sample of the un-capped line, so the
concatenation is a contiguous slice of it.

One engine renders one line at a time (an internal lock serialises callers). `render` blocks for
about the length of the audio; call it off the main thread. `pace` runs between stages and after
every frame; sleeping in it is how a host limits the duty cycle.

## Model directory

```
<models>/
  host/      config.json, tokenizer.json, text_embedding_{q,scales,biases}.npy,
             text_proj_linear_fc{1,2}_{w,b}.npy, talker_codec_embedding.npy, cp_codec_embedding.npy
             (text_embedding_scales/biases are fp16, bit-exact; the codec embeddings stay fp32 because
             fp16 flips near-tie sub-codes; fp32 .npy files are accepted wherever fp16 is)
  vochead/   the vocoder head weights, one fp16 .npy per tensor (quantizer.*, pre_conv.*, pre_transformer.*);
             fp16 is bit-exact for these, fp32 files also load. Matrices are widened per matmul.
  coreml/    talker0.mlmodelc, talker1.mlmodelc   (layers 0-13 and 14-27, NOT duplicates; each is
                                                   multifunction: "decode" and "prefill")
             cp_ane.mlmodelc
             upF.mlmodelc   (multifunction "w12" / "w20": one set of weights, two window widths;
                             the older upF_12 + upF_20 pair still loads)
             upMall.mlmodelc
  voices/<name>/   voice.json (ref_text), ref_codes.npy (int32 1x16xT), spk_embed.npy (float32)
```

Models must be compiled (`.mlmodelc`); compile a `.mlpackage` with `xcrun coremlcompiler compile`.
`voices/` is optional: a host can build `QwenVoiceFiles` itself and cache them next to its own voices.

### Voice prep models

Preparing a voice on the device (`QwenVoicePrep`) needs two more compiled models, both fp32 and
run on the CPU only (`.cpuOnly`; never CPU_AND_NE, it hung the ANE compiler):

```
<models>/coreml/  QwenSpeechEncoder.mlmodelc    (speech tokenizer, fixed 40 s input + valid length; 20 s on older sets)
                  QwenSpeakerEncoder.mlmodelc   (x-vector ECAPA-TDNN, mel input + valid length)
```

Source packages: `qwen-onnx-cpu/out/coreml_enc/`; compile with `xcrun coremlcompiler compile`.

A `.gvoice` pack can carry the prepared voice (`engines/qwen3-0.6b/`, docs/gvoice-format.md):
`QwenVoicePrep.prepared(fromPack:referenceWAV:transcript:cacheDirectory:modelsDirectory:)` checks the
cache, then the pack's files (sha256 of the audio, prep version, mel, transcript, array shapes), and
only then runs the encoders; `Prepared.origin` says which, and `Prepared.enginePayload(...)` makes the
folder to write back. `spike gvoice-qwen-prep <pack.gvoice>` adds or refreshes it.

```swift
// wav: mono 24 kHz PCM16, already through ReferenceStandard (or a GVoiceProductionKit PreparedReference)
let voice = try QwenVoicePrep.prepared(referenceWAV: wav, transcript: text,
                                       cacheDirectory: voiceDir, modelsDirectory: modelsURL)
```

It trims a cut-off tail (`ReferenceTail`), throws `referenceTooLong(seconds:)` past the encoder's input (40 s) (the caller
supplies a window), and caches `voice.json` / `ref_codes.npy` / `spk_embed.npy` keyed by source
sha256 + transcript + prep version. The speaker mel is the upstream one (magnitude, Slaney, reflect
pad 384), not the mlx-audio-swift fork's. Parity tests: `QWEN_ANE_MODELS=... swift test --filter QwenVoicePrepTests`.

## Notes

- The sampler reproduces numpy's `default_rng(seed)` stream (PCG64 + SeedSequence), so a render with
  a given seed is comparable to `render_fast.py --engine coreml` in qwen-onnx-cpu. fp16 on the ANE
  can flip a near-tie late in a line, so match is "nearly all frames", not bit-exact.
- The vocoder is primed with the voice's reference codes (their audio is dropped); without that the
  first word cracks. The primed state is cached per voice.
- The talker has 1024 KV slots: prompt (voice reference + text) plus generated frames must fit.
