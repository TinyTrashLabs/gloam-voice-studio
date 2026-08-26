#!/usr/bin/env bash
# Fetch Kyutai Pocket TTS for the sherpa-onnx backend (PocketSpeechModel).
#
# Two GitHub release artifacts make one runnable model directory:
#   1. the sherpa-onnx Pocket model export (k2-fsa "tts-models" release,
#      weights CC-BY-4.0) — the graphs + vocab/token_scores + test wavs
#   2. sherpa-onnx's macOS shared libs (v1.13.4, Apache-2.0) — dropped INTO the
#      model dir, because PocketSpeechModel dlopens libsherpa-onnx-c-api.dylib
#      from there (its LC_RPATH is @loader_path, so the bundled libonnxruntime
#      resolves from the same dir). One directory = everything the backend
#      needs = one resolver path for the app.
#
# The dylibs are ad-hoc re-signed after extraction: the upstream tarball's
# libonnxruntime.1.27.0.dylib ships with an INVALID code signature and macOS
# SIGKILLs ("Code Signature Invalid") the process on first page-in without this.
#
# This is distinct from scripts/fetch-pocket-tts-onnx.sh, which fetches the
# community raw-graph export (KevinAHM/pocket-tts-onnx) kept as a control for
# precision comparisons; THIS script fetches what the backend actually runs.
#
#     bash scripts/fetch-pocket-tts.sh [int8|fp32] [--install-app]
#
# --install-app additionally copies the finished directory into the sandboxed
# macOS app's model root, where AppModel's resolver looks for it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SHERPA_VERSION="1.13.4"
MODEL_DATE="2026-01-26"

PRECISION="int8"
INSTALL_APP=0
for arg in "$@"; do
  case "$arg" in
    int8|fp32) PRECISION="$arg" ;;
    --install-app) INSTALL_APP=1 ;;
    *) echo "usage: bash scripts/fetch-pocket-tts.sh [int8|fp32] [--install-app]" >&2; exit 2 ;;
  esac
done

if [[ "$PRECISION" == "int8" ]]; then
  MODEL_NAME="sherpa-onnx-pocket-tts-int8-${MODEL_DATE}"
else
  MODEL_NAME="sherpa-onnx-pocket-tts-${MODEL_DATE}"
fi
DEST_PARENT="$ROOT/Models/pocket-tts"
DEST="$DEST_PARENT/$MODEL_NAME"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/${MODEL_NAME}.tar.bz2"
LIB_NAME="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared-lib"
LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${LIB_NAME}.tar.bz2"

mkdir -p "$DEST_PARENT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$DEST/vocab.json" ]]; then
  echo "▶ ${MODEL_NAME}.tar.bz2…"
  curl -fSL --retry 3 --retry-delay 2 -o "$TMP/model.tar.bz2" "$MODEL_URL"
  tar xjf "$TMP/model.tar.bz2" -C "$DEST_PARENT"
else
  echo "✓ model ${MODEL_NAME} (already present)"
fi

if [[ ! -f "$DEST/libsherpa-onnx-c-api.dylib" ]]; then
  echo "▶ ${LIB_NAME}.tar.bz2…"
  curl -fSL --retry 3 --retry-delay 2 -o "$TMP/lib.tar.bz2" "$LIB_URL"
  tar xjf "$TMP/lib.tar.bz2" -C "$TMP"
  cp "$TMP/$LIB_NAME/lib/libsherpa-onnx-c-api.dylib" \
     "$TMP/$LIB_NAME/lib/libonnxruntime.1.27.0.dylib" "$DEST/"
  # Upstream's libonnxruntime signature is invalid — without a fresh ad-hoc
  # signature, dyld kills the host process with "Code Signature Invalid".
  codesign -f -s - "$DEST/libsherpa-onnx-c-api.dylib" "$DEST/libonnxruntime.1.27.0.dylib"
else
  echo "✓ sherpa-onnx dylibs (already present)"
fi

echo
echo "✅ Pocket TTS ($PRECISION) in $DEST ($(du -sh "$DEST" | cut -f1))"
echo "   Audition it headlessly:"
echo "     swift run spike pocket --ref \"$DEST/test_wavs/bria.wav\" \\"
echo "       --text \"Hello from Pocket TTS.\" --out /tmp/pocket.wav --model-dir \"$DEST\""

if [[ "$INSTALL_APP" == "1" ]]; then
  APP_MODELS="$HOME/Library/Containers/fm.gloam.studio/Data/Library/Application Support/Models"
  APP_DEST="$APP_MODELS/pocket-tts"
  mkdir -p "$APP_MODELS"
  rm -rf "$APP_DEST"
  cp -R "$DEST" "$APP_DEST"
  echo "   Installed for the app: $APP_DEST"
fi
