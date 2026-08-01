#!/usr/bin/env bash
# Fetch the pocket-tts ONNX bundle (kyutai-labs/pocket-tts, MIT) for evaluation
# beside LuxTTS and SuperTonic.
#
# pocket-tts is a 100M-parameter CPU TTS with voice cloning and streaming —
# small enough to be interesting for the phone, where MLX is closed to us (iOS
# forbids GPU submission while backgrounded). Upstream ships PyTorch; these are
# the community ONNX exports (KevinAHM/pocket-tts-onnx, MIT), which is what lets
# this repo run it through the same ONNX Runtime that LuxOnnxEngine uses.
#
# Both precisions are fetched. int8 is what would realistically ship; fp32 is
# the control, because LuxTTS taught us not to assume quantization is free —
# measure the gap before choosing.
#
#     bash scripts/fetch-pocket-tts-onnx.sh [bundle]     # default english_2026-04
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${1:-english_2026-04}"
DEST="$ROOT/Models/pocket-tts/$BUNDLE"
BASE="https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/main/onnx/$BUNDLE"

# The five graphs of the pipeline: text -> conditioning, the autoregressive
# flow LM (main + flow heads), and Mimi's codec pair (encoder clones a
# reference voice, decoder vocodes).
FILES=(
  bundle.json
  tokenizer.model
  text_conditioner.onnx      text_conditioner_int8.onnx
  flow_lm_main.onnx          flow_lm_main_int8.onnx
  flow_lm_flow.onnx          flow_lm_flow_int8.onnx
  mimi_encoder.onnx          mimi_encoder_int8.onnx
  mimi_decoder.onnx          mimi_decoder_int8.onnx
)

mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  out="$DEST/${f}"
  if [[ -s "${out}" ]]; then
    echo "✓ ${f} (already present)"
    continue
  fi
  echo "▶ ${f}…"
  # -f so a 404 fails loudly rather than writing an HTML error page as a model.
  curl -fSL --retry 3 --retry-delay 2 -o "${out}.part" "${BASE}/${f}"
  mv "${out}.part" "${out}"
done

# bos_before_voice.npy is named by bundle.json and only present on some bundles.
BOS="$(python3 -c "import json,sys; print(json.load(open('$DEST/bundle.json')).get('bos_before_voice_file') or '')" 2>/dev/null || true)"
if [[ -n "${BOS}" && ! -s "$DEST/${BOS}" ]]; then
  echo "▶ ${BOS}…"
  curl -fSL --retry 3 -o "$DEST/${BOS}" "${BASE}/${BOS}" || echo "  (absent upstream — fine, not all bundles ship one)"
fi

echo
echo "✅ pocket-tts bundle '${BUNDLE}' in $DEST ($(du -sh "$DEST" | cut -f1))"
echo "   Voices (speaker embeddings) live in kyutai/pocket-tts under"
echo "   languages/<lang>/embeddings/*.safetensors — fetch per voice as needed."
