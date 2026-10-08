# The llama.cpp release Aloud builds against, pinned by checksum (sourced by setup.sh and
# build-app.sh, the way make-g2p-data.py --verify pins the pronunciation data).
LLAMA_VERSION="b11138"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/llama-${LLAMA_VERSION}-xcframework.zip"
# llama-b11138-xcframework.zip as published (58,176,710 bytes).
LLAMA_ZIP_SHA256="14cebdb646f139643b4176c97206c74bd1b08a9e1e895024988fb7927fdba67e"
# The macOS library inside it, which the app bundles (its arm64 slice).
LLAMA_MACOS_LIB="macos-arm64_x86_64/llama.framework/Versions/A/llama"
LLAMA_MACOS_SHA256="2ca41f142c85feb640aacc1d7525edc25e74d787d9d6b47e6934a9de06c1764e"

# verify_llama <path to llama.xcframework>: fails, saying what to do, unless the macOS
# library is exactly the pinned one.
verify_llama() {
  local lib="$1/$LLAMA_MACOS_LIB" got
  if [[ ! -f "$lib" ]]; then
    echo "llama.cpp: $lib is missing. Delete $1 and run ./scripts/setup.sh." >&2
    return 1
  fi
  got=$(shasum -a 256 "$lib" | cut -d' ' -f1)
  if [[ "$got" != "$LLAMA_MACOS_SHA256" ]]; then
    echo "llama.cpp: $lib doesn't match the pinned $LLAMA_VERSION release" >&2
    echo "  expected sha256 $LLAMA_MACOS_SHA256" >&2
    echo "  found           $got" >&2
    echo "  Delete $1 and run ./scripts/setup.sh to download it again." >&2
    return 1
  fi
}
