#!/bin/zsh
# Runtime and upgrade-path regression checks for the release binary:
#   Tests/runtime/regression.sh [.build/arm64-apple-macosx/release/ReadAloud]
# Works on copies of the installed voice (APFS clones, so no extra space) in a scratch
# models folder, never on the real one. The player checks open the app for a few
# seconds, muted, the way --read does.
set -uo pipefail
cd "${0:A:h}/../.."
B="${1:-.build/arm64-apple-macosx/release/ReadAloud}"
VOICE="${READALOUD_TEST_VOICE:-$HOME/Library/Application Support/ReadAloud/models/kokoro-multi-lang-v1_0}"
[[ -x "$B" ]] || { echo "no binary at $B (swift build -c release first)"; exit 2; }
[[ -f "$VOICE/model.onnx" ]] || { echo "no voice at $VOICE (scripts/setup.sh installs one)"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {  # check <description> <command…>: passes when the command succeeds
  local what=$1; shift
  if "$@"; then echo "  ✓ $what"; else echo "  ✗ $what"; fail=1; fi
}
# A models folder holding a copy of the voice.
voice_copy() {
  mkdir -p "$1/kokoro-multi-lang-v1_0"
  for f in model.onnx voices.bin tokens.txt; do
    cp -c "$VOICE/$f" "$1/kokoro-multi-lang-v1_0/" 2>/dev/null || cp "$VOICE/$f" "$1/kokoro-multi-lang-v1_0/"
  done
}
say() { READALOUD_MODELS_DIR="$1" "$B" --say "$2" 2>&1; }
# Opens the player on some text in a models folder, prints its trace, quits after $3 seconds.
read_aloud() {
  READALOUD_MODELS_DIR="$1" "$B" --read "$2" --mute --trace --script "$3:quit" >"$TMP/read.log" 2>&1 &
  local pid=$!
  ( sleep 30; kill $pid 2>/dev/null ) &
  local watchdog=$!
  wait $pid
  kill $watchdog 2>/dev/null
  cat "$TMP/read.log"
}
voice_copy "$TMP/models"  # an intact voice, for the checks that read

echo "RT-1 and RT-3: launch keeps the old voice files and clears abandoned downloads"
K="$TMP/models/kokoro-multi-lang-v1_0"
mkdir -p "$K/espeak-ng-data" "$TMP/models/.download-AAA" "$TMP/models/.unpack-BBB" "$TMP/models/.migrate-CCC"
touch "$K/espeak-ng-data/phontab" "$K/lexicon-us-en.txt" "$K/lexicon-zh.txt" \
  "$TMP/models/.download-AAA/model.onnx" "$TMP/models/.download-DDD.tar.bz2" "$TMP/models/.unpack-BBB/x" "$TMP/models/.keep"
read_aloud "$TMP/models" "Hello." 2 >/dev/null
check "eSpeak NG data and lexicons survive launch (Aloud 1.5 needs them)" \
  eval '[[ -e "$K/espeak-ng-data/phontab" && -e "$K/lexicon-us-en.txt" && -e "$K/lexicon-zh.txt" ]]'
# Scripted runs like the one above always skipped the tidy-up, so also make sure the
# only thing that still calls it is the --tidy-voice flag.
check "only --tidy-voice removes them" \
  eval '[[ "$(grep -rl "removeUnusedFiles()" Sources/ReadAloud | grep -v KokoroEngine.swift)" == "Sources/ReadAloud/DebugScript.swift" ]]'
check "abandoned .download-, .unpack- and .migrate- items are gone" \
  eval '[[ -z "$(ls -A "$TMP/models" | grep -E "^\.(download|unpack|migrate)-")" ]]'
check "nothing else in the models folder is touched" eval '[[ -e "$TMP/models/.keep" && -f "$K/model.onnx" ]]'
READALOUD_MODELS_DIR="$TMP/models" "$B" --tidy-voice
check "--tidy-voice still removes them by hand" eval '[[ ! -e "$K/espeak-ng-data" && ! -e "$K/lexicon-us-en.txt" && -f "$K/voices.bin" ]]'

echo
if (( fail == 0 )); then echo "PASSED"; else echo "FAILED"; fi
exit $fail
