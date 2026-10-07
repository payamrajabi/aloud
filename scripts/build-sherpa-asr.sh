#!/bin/zsh
# Builds sherpa-onnx from source with text-to-speech switched off, for dictation only.
#
# The prebuilt sherpa-onnx release links a GPL-licensed eSpeak NG (through its TTS
# front end). Aloud now runs Kokoro itself on ONNX Runtime, so it only needs
# sherpa-onnx for Parakeet speech recognition. With SHERPA_ONNX_ENABLE_TTS=OFF the
# build leaves out piper-phonemize and eSpeak NG entirely.
#
# Output: Vendor/sherpa-onnx-asr/{lib,include}, holding libsherpa-onnx-c-api.dylib,
# the matching libonnxruntime.dylib, and the C API headers for both.
# Needs Xcode's command-line tools, git and cmake (a Python venv is created for
# cmake/ninja if they aren't installed). Takes about 5–10 minutes.
set -euo pipefail

SHERPA_VERSION="${SHERPA_VERSION:-1.13.8}"
ROOT="${0:A:h:h}"
OUT="$ROOT/Vendor/sherpa-onnx-asr"
WORK="${SHERPA_BUILD_DIR:-$ROOT/build/sherpa-onnx-src}"

if [[ -f "$OUT/lib/libsherpa-onnx-c-api.dylib" && -f "$OUT/include/onnxruntime/onnxruntime_c_api.h" ]]; then
  echo "sherpa-onnx (ASR only): ready"
  exit 0
fi

CMAKE=$(command -v cmake || true)
NINJA=$(command -v ninja || true)
if [[ -z "$CMAKE" || -z "$NINJA" ]]; then
  echo "Installing cmake and ninja into build/tools (a private Python venv)..."
  python3 -m venv "$ROOT/build/tools"
  "$ROOT/build/tools/bin/pip" install -q cmake ninja
  CMAKE="$ROOT/build/tools/bin/cmake"
  NINJA="$ROOT/build/tools/bin/ninja"
fi

if [[ ! -d "$WORK/src/.git" ]]; then
  echo "Fetching sherpa-onnx v$SHERPA_VERSION source..."
  rm -rf "$WORK"; mkdir -p "$WORK"
  git clone -q --depth 1 --branch "v$SHERPA_VERSION" https://github.com/k2-fsa/sherpa-onnx.git "$WORK/src"
fi

echo "Building sherpa-onnx v$SHERPA_VERSION without TTS (no eSpeak NG)..."
"$CMAKE" -S "$WORK/src" -B "$WORK/build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_INSTALL_PREFIX="$WORK/install" \
  -DBUILD_SHARED_LIBS=ON \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_GPU=OFF >/dev/null
"$CMAKE" --build "$WORK/build" --config Release
"$CMAKE" --install "$WORK/build" >/dev/null

ORT_DIR=$(find "$WORK/build/_deps" -maxdepth 1 -type d -name 'onnxruntime-src' | head -1)
[[ -n "$ORT_DIR" ]] || { echo "Couldn't find the onnxruntime that cmake downloaded"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include/sherpa-onnx/c-api" "$OUT/include/onnxruntime"
cp "$WORK/install/lib/libsherpa-onnx-c-api.dylib" "$OUT/lib/"
cp -L "$ORT_DIR/lib/libonnxruntime.dylib" "$OUT/lib/"
cp "$WORK/install/include/sherpa-onnx/c-api/c-api.h" "$OUT/include/sherpa-onnx/c-api/"
cp "$ORT_DIR"/include/*.h "$ORT_DIR"/include/*.inc "$OUT/include/onnxruntime/"
cp "$ORT_DIR"/LICENSE "$OUT/onnxruntime-LICENSE"; cp "$ORT_DIR"/ThirdPartyNotices.txt "$OUT/onnxruntime-ThirdPartyNotices.txt"
cp "$WORK/src/LICENSE" "$OUT/sherpa-onnx-LICENSE"

# The whole point of this build: prove eSpeak isn't in it.
"$ROOT/scripts/check-no-espeak.sh" "$OUT/lib" >/dev/null || {
  echo "eSpeak code found in the ASR-only build; refusing to continue"; rm -rf "$OUT"; exit 1
}
echo "sherpa-onnx (ASR only): ready at $OUT"
