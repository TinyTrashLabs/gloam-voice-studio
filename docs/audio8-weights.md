# Audio8 weights

Studio's Audio8 engine loads a repack of Edge0's Audio8 TTS in the Fish DualAR MLX layout
(`model_type: fish_qwen3_omni`), loaded by the Fish code in `TinyTrashLabs/mlx-audio-swift`.

- Source: [Edge0/Audio8-TTS-Realistic-0.6b](https://huggingface.co/Edge0/Audio8-TTS-Realistic-0.6b), revision `1e857568bfd4f02931aca3988ee773a44d2d26d3`
- Published repo: [tinytrashlabs/Audio8-TTS-0.6B-MLX](https://huggingface.co/tinytrashlabs/Audio8-TTS-0.6B-MLX) (public), commit `de28670703174f4be5a9de453c95d4cb42ab1c56`
- Size: 2,565,321,473 bytes of repo content (model.safetensors 1,202,343,880; codec.safetensors 1,349,781,960; tokenizer and config files the rest)
- Licence: Apache 2.0 (`LICENSE` and `NOTICE` copied from the source), so `needsLicenseAck` is false.

## Producing the repo

```sh
hf download Edge0/Audio8-TTS-Realistic-0.6b --revision 1e857568bfd4f02931aca3988ee773a44d2d26d3
python -I scripts/convert_audio8.py <snapshot dir> <out dir>   # needs torch + safetensors, venv outside the repo
hf upload tinytrashlabs/Audio8-TTS-0.6B-MLX <out dir> .
```

The converter does not re-train or quantise weights (the codec tensors are stored as fp32; the transformer tensors are copied as they are). It prefixes the slow/fast transformer tensors with `model.`,
converts `codec.pth` to `codec.safetensors`, and writes `config.json` with every `FishS1DACBuildConfig` key explicit
(missing keys silently fall back to Fish defaults) plus the Audio8-specific `max_frames_per_text_token: 12.0` and
`reference_budget_scale: 1.95`. It also writes the README model card crediting Edge0.

Verified by rendering the Benson line with the fork's `mlx-audio-swift-tts --model <out dir>`; Whisper transcript word-perfect.
