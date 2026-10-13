#!/bin/zsh
# Fails if any Mach-O binary under the given paths contains eSpeak NG or
# piper-phonemize code (symbols or strings), or if espeak-ng-data is present.
#   ./scripts/check-no-espeak.sh build/Aloud.app
# Case-sensitive on purpose: "OfflineSpeakerDiarization" contains "eSpeak" if you
# ignore case, and it's ordinary speech-recognition code.
set -uo pipefail
(( $# )) || set -- build/Aloud.app

PATTERN='espeak|eSpeak|ESPEAK|piper_phonemize|PiperPhonemize|piper-phonemize'
ALLOW='eSpeaker|wespeaker|WeSpeaker'
fail=0
for root in "$@"; do
  if [[ -n "$(find "$root" -name 'espeak-ng-data' 2>/dev/null)" ]]; then
    echo "✗ espeak-ng-data found under $root"; fail=1
  fi
  while IFS= read -r f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    syms=$(nm -a "$f" 2>/dev/null | grep -E "$PATTERN" | grep -v -E "$ALLOW" | wc -l | tr -d ' ' || true)
    # The app names the leftover folder "espeak-ng-data" so it can delete it; that string alone is allowed.
    strs=$(strings -a "$f" 2>/dev/null | grep -E "$PATTERN" | grep -v -E "$ALLOW" | grep -v -x 'espeak-ng-data' | wc -l | tr -d ' ' || true)
    if [[ "$syms" != 0 || "$strs" != 0 ]]; then
      echo "✗ ${f#$root/}: $syms eSpeak symbols, $strs eSpeak strings"; fail=1
    else
      echo "✓ ${f#$root/}"
    fi
  done < <(find "$root" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
done
(( fail == 0 )) && echo "No eSpeak NG code or data found."
exit $fail
