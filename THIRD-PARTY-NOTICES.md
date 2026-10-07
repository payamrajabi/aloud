# Third-party software

The Aloud source code in this repository is MIT licensed (see LICENSE), including
its pronunciation lists (`Lexicons/`). The downloadable app also includes or
downloads the following components, each under its own license. Their license
texts are inside the app, in `Contents/Resources/licenses` and
`Contents/Resources/g2p/licenses`.

| Component | Use | License | Source |
|---|---|---|---|
| Kokoro-82M (v1.0) (downloaded on first launch, not bundled) | Voice model | Apache-2.0 | https://huggingface.co/hexgrad/Kokoro-82M, as exported to ONNX by sherpa-onnx: https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0 |
| misaki 0.9.4: its English G2P rules and "gold" lexicons (US and GB) | Pronunciation | Apache-2.0 | https://github.com/hexgrad/misaki |
| MisakiSwift (modified: Aloud's `Phonemizer` module is derived from it) | Pronunciation | Apache-2.0 | https://github.com/mlalma/MisakiSwift |
| CMU Pronouncing Dictionary 0.7a | Pronunciation of words misaki doesn't know | BSD-2-Clause style, © 1993–2008 Carnegie Mellon University | https://github.com/cmusphinx/cmudict (as packaged by NLTK) |
| cisco-ai/mini-bart-g2p (quantised to int8) | Pronunciation of words in no dictionary | Apache-2.0 | https://huggingface.co/cisco-ai/mini-bart-g2p |
| ONNX Runtime 1.28.2 | Neural network runtime (voice, G2P, dictation) | MIT | https://github.com/microsoft/onnxruntime |
| sherpa-onnx 1.13.8, built without text-to-speech | Dictation runtime | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| Sparkle | Automatic updates | MIT | https://github.com/sparkle-project/Sparkle |
| NVIDIA Parakeet TDT 0.6B v2 (downloaded on first launch, not bundled) | Dictation model | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 |

Notes:

- **Kokoro** was trained on permissive or non-copyrighted audio. Its model card lists
  CC BY audio in the v1.0 training set: Koniwa `tnc` (CC BY 3.0,
  https://github.com/koniwa/koniwa) and SIWIS (CC BY 4.0,
  https://datashare.ed.ac.uk/handle/10283/2353).
- **mini-bart-g2p** was trained on CMUdict and on the LibriSpeech Alignments
  dataset by Loren Lugosch (https://zenodo.org/records/2619474), which is licensed
  CC BY 4.0 and derived from LibriSpeech (Panayotov et al., CC BY 4.0).
- **misaki's "silver" lexicons are not included.** They were generated with eSpeak NG.
- **No GPL code.** Earlier versions of Aloud (1.4 and before) used the prebuilt
  sherpa-onnx library, which links eSpeak NG (GPL-3.0) for its text-to-speech front
  end, and downloaded eSpeak NG's data with the voice. Aloud now turns text into
  phonemes itself and runs Kokoro directly on ONNX Runtime; sherpa-onnx is built from
  source with `SHERPA_ONNX_ENABLE_TTS=OFF`, which leaves out eSpeak NG and
  piper-phonemize. `scripts/check-no-espeak.sh build/Aloud.app` verifies this, and
  `scripts/build-app.sh` runs it on every build.
