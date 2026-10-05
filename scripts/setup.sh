#!/bin/zsh
# One-time setup: downloads the sherpa-onnx speech library (for building)
# and the Kokoro voice model (for running). Safe to re-run.
set -euo pipefail

SHERPA_VERSION="1.13.8"
MODEL_NAME="kokoro-multi-lang-v1_0"
ASR_MODEL="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"

ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor/sherpa-onnx"
MODELS="$HOME/Library/Application Support/ReadAloud/models"

if [[ ! -f "$VENDOR/lib/libsherpa-onnx-c-api.dylib" ]]; then
  echo "Downloading sherpa-onnx $SHERPA_VERSION (about 19 MB)..."
  tmp=$(mktemp -d)
  name="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared"
  curl -fL --progress-bar -o "$tmp/sherpa.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${name}.tar.bz2"
  tar -xjf "$tmp/sherpa.tar.bz2" -C "$tmp"
  rm -rf "$VENDOR"; mkdir -p "$VENDOR"
  cp -R "$tmp/$name/lib" "$tmp/$name/include" "$VENDOR/"
  rm -rf "$tmp"
fi
echo "sherpa-onnx library: ready"

if [[ ! -f "$MODELS/$MODEL_NAME/model.onnx" ]]; then
  echo "Downloading Kokoro voice model (about 333 MB)..."
  mkdir -p "$MODELS"
  curl -fL --progress-bar -o "$MODELS/$MODEL_NAME.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/${MODEL_NAME}.tar.bz2"
  tar -xjf "$MODELS/$MODEL_NAME.tar.bz2" -C "$MODELS"
  rm -f "$MODELS/$MODEL_NAME.tar.bz2"
fi
echo "Kokoro model: ready at $MODELS/$MODEL_NAME"

# Dictation model (Parakeet). The app can also download this itself on first use.
if [[ ! -f "$MODELS/$ASR_MODEL/tokens.txt" ]]; then
  echo "Downloading Parakeet dictation model (about 460 MB)..."
  curl -fL --progress-bar -o "$MODELS/$ASR_MODEL.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${ASR_MODEL}.tar.bz2"
  tar -xjf "$MODELS/$ASR_MODEL.tar.bz2" -C "$MODELS"
  rm -f "$MODELS/$ASR_MODEL.tar.bz2"
fi
echo "Parakeet model: ready at $MODELS/$ASR_MODEL"
