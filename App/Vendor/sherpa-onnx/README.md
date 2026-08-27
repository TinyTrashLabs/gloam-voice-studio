# sherpa-onnx runtime (vendored)

`libsherpa-onnx-c-api.dylib` and `libonnxruntime.1.27.0.dylib` are the macOS
arm64 shared libs from the [sherpa-onnx v1.13.4 release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.4)
(`sherpa-onnx-v1.13.4-osx-arm64-shared-lib.tar.bz2`, Apache-2.0 — see
`LICENSE`), vendored here so xcodegen can embed and code-sign them inside the
app bundle (`Contents/Frameworks/`) instead of the app dlopen-ing code from
outside its bundle. The dylibs are Apache-2.0 (this `LICENSE`); the Kyutai
Pocket TTS model weights fetched separately into `Models/` are CC-BY-4.0 —
a different license covering different files, not to be confused with this
one. To refresh to a newer sherpa-onnx release, re-run
`scripts/fetch-pocket-tts.sh` to pull the new binaries into `Models/`, copy
the two dylibs from there into this directory (see Step 1 of the task-1
brief for the exact commands), fetch the matching release's `LICENSE` from
`https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v<version>/LICENSE`
(the sherpa-onnx software license — do not copy the `LICENSE` from the
`Models/` dir, that's the model weights' CC-BY-4.0 license), bump the
version in this README, and re-run `xcodegen generate`.
