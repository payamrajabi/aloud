#!/bin/zsh
# One-time setup. Safe to re-run; each step is skipped when it's already done.
#   1. sherpa-onnx built from source without text-to-speech (no eSpeak NG), plus the
#      ONNX Runtime it uses, into Vendor/sherpa-onnx-asr (for building)
#   2. the pronunciation data (misaki gold lexicons, CMUdict, mini-bart G2P) into
#      Vendor/g2p (bundled into the app)
#   3. the Kokoro voice and the Parakeet dictation model into Application Support
#      (for running; the app also downloads both itself on first launch)
#   4. llama.cpp, which runs the optional dictation clean-up model (for building)
set -euo pipefail

ASR_MODEL="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
VOICE_DIR_NAME="kokoro-multi-lang-v1_0"
VOICE_BASE="https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/f7b96bb6bef5c5da4d3aa4f4e0498fbbf62dc78b"

ROOT="${0:A:h:h}"
MODELS="${READALOUD_MODELS_DIR:-$HOME/Library/Application Support/ReadAloud/models}"

"$ROOT/scripts/build-sherpa-asr.sh"

if [[ ! -f "$ROOT/Vendor/g2p/manifest.json" ]]; then
  echo "Building the pronunciation data (about 14 MB)..."
  # The quantised G2P model depends on the onnx/onnxruntime versions, so make-g2p-data.py
  # pins every package (they have wheels for Python 3.9 to 3.12) and checks its output.
  # The data Aloud ships was built with macOS's own Python 3.9; PYTHON=... picks another.
  PYTHON="${PYTHON:-/usr/bin/python3}"
  VENV="$ROOT/build/g2p-venv"
  [[ -x "$VENV/bin/python" ]] || "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check --only-binary=:all: \
      $("$VENV/bin/python" "$ROOT/scripts/make-g2p-data.py" --requirements) || {
    echo "Couldn't install the pinned packages into $VENV ($("$VENV/bin/python" --version))."
    echo "They need Python 3.9 to 3.12: rm -rf build/g2p-venv, then PYTHON=/path/to/python3.9 ./scripts/setup.sh"
    exit 1
  }
  "$VENV/bin/python" "$ROOT/scripts/make-g2p-data.py" "$ROOT/Vendor/g2p"
fi
python3 "$ROOT/scripts/make-g2p-data.py" --verify "$ROOT/Vendor/g2p" >/dev/null
echo "Pronunciation data: ready"

# llama.cpp runs the small language model that tidies dictation (Metal, built in).
# The release is pinned by checksum (scripts/llama-pin.sh): the download is checked
# before it's unpacked, and the unpacked library on every run.
source "$ROOT/scripts/llama-pin.sh"
LLAMA="$ROOT/Vendor/llama.xcframework"
if [[ ! -f "$LLAMA/.version-$LLAMA_VERSION" ]]; then
  echo "Downloading llama.cpp $LLAMA_VERSION (about 58 MB)..."
  tmp=$(mktemp -d)
  curl -fL --progress-bar -o "$tmp/llama.zip" "$LLAMA_URL"
  got=$(shasum -a 256 "$tmp/llama.zip" | cut -d' ' -f1)
  if [[ "$got" != "$LLAMA_ZIP_SHA256" ]]; then
    echo "The llama.cpp $LLAMA_VERSION download doesn't match its pinned checksum"
    echo "  expected sha256 $LLAMA_ZIP_SHA256"
    echo "  found           $got"
    rm -rf "$tmp"
    exit 1
  fi
  ditto -x -k "$tmp/llama.zip" "$tmp"
  rm -rf "$LLAMA"
  ditto "$tmp/build-apple/llama.xcframework" "$LLAMA"
  touch "$LLAMA/.version-$LLAMA_VERSION"
  rm -rf "$tmp"
fi
verify_llama "$LLAMA" || exit 1
echo "llama.cpp library: ready (matches its pinned checksum)"

# The voice: the model, the voice styles and the symbol table (about 355 MB), the same
# files the app fetches. (Not sherpa-onnx's tar archive, which also carries eSpeak NG's data.)
VOICE="$MODELS/$VOICE_DIR_NAME"
if [[ ! -f "$VOICE/model.onnx" || ! -f "$VOICE/voices.bin" || ! -f "$VOICE/tokens.txt" ]]; then
  echo "Downloading the Kokoro voice (about 355 MB)..."
  mkdir -p "$VOICE"
  for f in model.onnx voices.bin tokens.txt LICENSE; do
    curl -fL --progress-bar -o "$VOICE/$f.part" "$VOICE_BASE/$f"
    mv "$VOICE/$f.part" "$VOICE/$f"
  done
  echo "b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11  $VOICE/model.onnx" | shasum -a 256 -c -
  echo "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29  $VOICE/voices.bin" | shasum -a 256 -c -
fi
echo "Kokoro voice: ready at $VOICE"

# Dictation model (Parakeet). The app can also download this itself on first use.
if [[ ! -f "$MODELS/$ASR_MODEL/tokens.txt" ]]; then
  echo "Downloading Parakeet dictation model (about 460 MB)..."
  mkdir -p "$MODELS"
  curl -fL --progress-bar -o "$MODELS/$ASR_MODEL.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${ASR_MODEL}.tar.bz2"
  tar -xjf "$MODELS/$ASR_MODEL.tar.bz2" -C "$MODELS"
  rm -f "$MODELS/$ASR_MODEL.tar.bz2"
fi
echo "Parakeet model: ready at $MODELS/$ASR_MODEL"
