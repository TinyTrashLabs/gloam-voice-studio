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

One engine renders one line at a time (an internal lock serialises callers). `render` blocks for
about the length of the audio; call it off the main thread. `pace` runs between stages and after
every frame; sleeping in it is how a host limits the duty cycle.

## Model directory

```
<models>/
  host/      config.json, tokenizer.json, text_embedding_{q,scales,biases}.npy,
             text_proj_linear_fc{1,2}_{w,b}.npy, talker_codec_embedding.npy, cp_codec_embedding.npy
  vochead/   the vocoder head weights, one fp32 .npy per tensor (quantizer.*, pre_conv.*, pre_transformer.*)
  coreml/    talker0.mlmodelc, talker1.mlmodelc   (multifunction: "decode" and "prefill")
             cp_ane.mlmodelc
             upF_12.mlmodelc, upF_20.mlmodelc, upMall.mlmodelc
  voices/<name>/   voice.json (ref_text), ref_codes.npy (int32 1x16xT), spk_embed.npy (float32)
```

Models must be compiled (`.mlmodelc`); compile a `.mlpackage` with `xcrun coremlcompiler compile`.
`voices/` is optional: a host can build `QwenVoiceFiles` itself and cache them next to its own voices.

## Notes

- The sampler reproduces numpy's `default_rng(seed)` stream (PCG64 + SeedSequence), so a render with
  a given seed is comparable to `render_fast.py --engine coreml` in qwen-onnx-cpu. fp16 on the ANE
  can flip a near-tie late in a line, so match is "nearly all frames", not bit-exact.
- The vocoder is primed with the voice's reference codes (their audio is dropped); without that the
  first word cracks. The primed state is cached per voice.
- The talker has 1024 KV slots: prompt (voice reference + text) plus generated frames must fit.
