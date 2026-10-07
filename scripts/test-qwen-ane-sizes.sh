#!/bin/zsh
# Runs the QwenANE test suite once per model size, against the installed sets:
#   scripts/test-qwen-ane-sizes.sh            quick (frame-capped renders)
#   QWEN_SLOW_TESTS=1 scripts/test-qwen-ane-sizes.sh   everything (use `-c release`)
# Sets: GLOAM_QWEN_ANE_MODELS / GLOAM_QWEN_ANE_17B_MODELS, else Application Support/GloamVoiceStudio/Models/qwen3-{0.6b,1.7b}-ane.
# Each set needs a voices/{jeff,benson,cruz} folder (voice.json, ref_codes.npy, spk_embed.npy of ITS size).
cd "$(dirname "$0")/.." || exit 1
support="$HOME/Library/Application Support/GloamVoiceStudio/Models"
for size in 0.6b 1.7b; do
  if [[ $size == 0.6b ]]; then dir=${GLOAM_QWEN_ANE_MODELS:-$support/qwen3-0.6b-ane}; else dir=${GLOAM_QWEN_ANE_17B_MODELS:-$support/qwen3-1.7b-ane}; fi
  if [[ ! -d $dir/coreml ]]; then echo "== $size: no model set at $dir, skipped"; continue; fi
  echo "== QwenANE tests, $size ($dir)"
  QWEN_ANE_MODELS=$dir swift test --filter QwenANETests || exit 1
done
