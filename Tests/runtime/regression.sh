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
# (Braces matter: zsh reads "$3:q…" as $3 with its :q modifier, which made "2uit".) A run
# the watchdog has to kill is noted in $TMP/killed, and fails the check at the end. The
# watchdog's output goes nowhere, or its sleep would hold $(read_aloud …) open for 30 s.
read_aloud() {
  READALOUD_MODELS_DIR="$1" "$B" --read "$2" --mute --trace --script "${3}:quit" >"$TMP/read.log" 2>&1 &
  local pid=$!
  ( sleep 30; kill $pid 2>/dev/null && echo "$2" >>"$TMP/killed" ) >/dev/null 2>&1 &
  local watchdog=$!
  wait $pid
  kill $watchdog 2>/dev/null
  cat "$TMP/read.log"
}
voice_copy "$TMP/models"  # an intact voice, for the checks that read

echo "RT-1 and RT-3: launch keeps the old voice files and clears abandoned downloads"
K="$TMP/models/kokoro-multi-lang-v1_0"
M="$TMP/models"
mkdir -p "$K/espeak-ng-data" "$M/.download-AAA" "$M/.unpack-BBB" "$M/.migrate-CCC" "$M/.download-EEE" "$M/.unpack-FFF"
touch "$K/espeak-ng-data/phontab" "$K/lexicon-us-en.txt" "$K/lexicon-zh.txt" \
  "$M/.download-AAA/model.onnx" "$M/.download-DDD.tar.bz2" "$M/.unpack-BBB/x" "$M/.keep" \
  "$M/.download-EEE/model.onnx" "$M/.unpack-FFF/x" "$M/.download-GGG.tar.bz2"
# AAA to DDD were left behind two days ago. EEE to GGG were touched just now, like the
# download another copy of Aloud (opened from the disk image, say) is making right now.
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$M/.download-AAA" "$M/.download-DDD.tar.bz2" "$M/.unpack-BBB" "$M/.migrate-CCC"
read_aloud "$TMP/models" "Hello." 2 >/dev/null
check "eSpeak NG data and lexicons survive launch (Aloud 1.5 needs them)" \
  eval '[[ -e "$K/espeak-ng-data/phontab" && -e "$K/lexicon-us-en.txt" && -e "$K/lexicon-zh.txt" ]]'
# Scripted runs like the one above always skipped the tidy-up, so also make sure the
# only thing that still calls it is the --tidy-voice flag.
check "only --tidy-voice removes them" \
  eval '[[ "$(grep -rl "removeUnusedFiles()" Sources/ReadAloud | grep -v KokoroEngine.swift)" == "Sources/ReadAloud/DebugScript.swift" ]]'
check "abandoned .download-, .unpack- and .migrate- items are gone" \
  eval '[[ ! -e "$M/.download-AAA" && ! -e "$M/.download-DDD.tar.bz2" && ! -e "$M/.unpack-BBB" && ! -e "$M/.migrate-CCC" ]]'
check "a download in progress elsewhere (touched in the last day) is left alone" \
  eval '[[ -f "$M/.download-EEE/model.onnx" && -f "$M/.unpack-FFF/x" && -f "$M/.download-GGG.tar.bz2" ]]'
check "nothing else in the models folder is touched" eval '[[ -e "$TMP/models/.keep" && -f "$K/model.onnx" ]]'
READALOUD_MODELS_DIR="$TMP/models" "$B" --tidy-voice
check "--tidy-voice still removes them by hand" eval '[[ ! -e "$K/espeak-ng-data" && ! -e "$K/lexicon-us-en.txt" && -f "$K/voices.bin" ]]'

echo "RT-2: a damaged voice is refused, not played as silence"
voice_copy "$TMP/cut-voices"
head -c 1048576 "$VOICE/voices.bin" >"$TMP/cut-voices/kokoro-multi-lang-v1_0/voices.bin"
out=$(say "$TMP/cut-voices" "Hello there."); code=$?
check "voices.bin cut to 1 MB: an error, not 0.00 s of audio" eval '(( code == 1 )) && [[ "$out" == *"voice on this Mac is damaged (voices.bin is 1048576 bytes"* ]]'
voice_copy "$TMP/cut-model"
head -c 10485760 "$VOICE/model.onnx" >"$TMP/cut-model/kokoro-multi-lang-v1_0/model.onnx"
out=$(say "$TMP/cut-model" "Hello there."); code=$?
check "model.onnx cut short: counts as damaged" eval '(( code == 1 )) && [[ "$out" == *"damaged (model.onnx is 10485760 bytes"* ]]'
voice_copy "$TMP/bad-model"
dd if=/dev/zero of="$TMP/bad-model/kokoro-multi-lang-v1_0/model.onnx" bs=1048576 count=1 conv=notrunc 2>/dev/null
out=$(say "$TMP/bad-model" "Hello there."); code=$?
check "model.onnx the right size but corrupt: removed so it downloads again" \
  eval '(( code == 1 )) && [[ "$out" == *"model.onnx is corrupt"* && ! -e "$TMP/bad-model/kokoro-multi-lang-v1_0/model.onnx" ]]'
out=$(say "$TMP/models" "Hello there."); code=$?
check "an intact voice still speaks" eval '(( code == 0 )) && [[ "$out" != *" 0.00s audio"* ]]'

echo "R3: text in other scripts gets a message, not silence"
NOT_ENGLISH="Aloud reads English text, and this selection isn't in English."
out=$(say "$TMP/models" "Привет, как дела?")
check "Russian makes no near-silent audio from its punctuation" eval '[[ "$out" == *"0.00s audio"* ]]'
check "Chinese: the player says it reads English" eval 'read_aloud "$TMP/models" "我们今天去公园散步。天气很好。" 2 | grep -qF "$NOT_ENGLISH"'
check "Greek (no phonemes at all): the same message once nothing could be said" \
  eval 'read_aloud "$TMP/models" "Καλημέρα κόσμε. Τι κάνεις;" 3 | grep -qF "$NOT_ENGLISH"'
check "mixed text reads the English and skips the Chinese sentence" \
  eval 'log=$(read_aloud "$TMP/models" "Tokyo is big. 东京是日本的首都。 It is old." 3); [[ "$log" == *"sentence 1/2"* && "$log" != *"$NOT_ENGLISH"* ]]'

echo "PKG-4: no build-machine paths in the binary; lexicons still found from a checkout"
check "no path into Sources/ReadAloud is compiled in" eval '! strings -a "$B" | grep -q "/Sources/ReadAloud/"'
check "dictation still uses the checkout's Lexicons/" eval '"$B" --correct-dictation "push it to git hub" | grep -q "GitHub"'

echo "Test harness"
check "every scripted run quit on cue, not at the 30 s watchdog" eval '[[ ! -s "$TMP/killed" ]]'

echo
if (( fail == 0 )); then echo "PASSED"; else echo "FAILED"; fi
exit $fail
