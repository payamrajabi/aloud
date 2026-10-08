# Third-party software

The Aloud source code in this repository is MIT licensed (see LICENSE), including
its pronunciation lists (`Lexicons/`). The downloadable app also includes or
downloads the following components, each under its own license. The license text
of everything bundled is inside the app, in `Contents/Resources`, at the path
given in the last column (`scripts/build-app.sh` refuses to build an app that's
missing one of them).

| Component | Use | License | Source | License text |
|---|---|---|---|---|
| Kokoro-82M (v1.0) (downloaded on first launch, not bundled) | Voice model | Apache-2.0 | https://huggingface.co/hexgrad/Kokoro-82M, as exported to ONNX by sherpa-onnx: https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0 | downloaded with the voice |
| misaki 0.9.4: its English G2P rules and "gold" lexicons (US and GB) | Pronunciation | Apache-2.0 | https://github.com/hexgrad/misaki | `g2p/licenses/misaki-LICENSE.txt` |
| MisakiSwift (modified: Aloud's `Phonemizer` module is derived from it) | Pronunciation | Apache-2.0 | https://github.com/mlalma/MisakiSwift | `licenses/LICENSE-MisakiSwift.txt` |
| CMU Pronouncing Dictionary 0.7a | Pronunciation of words misaki doesn't know | BSD-2-Clause style, © 1993–2008 Carnegie Mellon University | https://github.com/cmusphinx/cmudict (as packaged by NLTK) | `g2p/licenses/cmudict-README.txt` |
| cisco-ai/mini-bart-g2p (quantised to int8) | Pronunciation of words in no dictionary | Apache-2.0 | https://huggingface.co/cisco-ai/mini-bart-g2p | `g2p/licenses/mini-bart-g2p-LICENSE.txt` |
| ONNX Runtime 1.28.2 | Neural network runtime (voice, G2P, dictation) | MIT | https://github.com/microsoft/onnxruntime | `licenses/onnxruntime-LICENSE.txt`, and its own third-party notices in `licenses/onnxruntime-ThirdPartyNotices.txt` |
| sherpa-onnx 1.13.8, built without text-to-speech | Dictation runtime | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx | `licenses/sherpa-onnx-LICENSE.txt` |
| Sparkle 2.10.0 | Automatic updates | MIT (its license file also covers the code it includes: bsdiff, sais-lite, ed25519) | https://github.com/sparkle-project/Sparkle | `licenses/Sparkle-LICENSE.txt` |
| NVIDIA Parakeet TDT 0.6B v2 (downloaded on first launch, not bundled) | Dictation model | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 | see the model card |

The sherpa-onnx library (`Contents/Frameworks/libsherpa-onnx-c-api.dylib`) is built
from source by `scripts/build-sherpa-asr.sh`, which compiles these libraries into it.
Their license texts are kept in this repository's `licenses/` folder, copied from
the source archives that script downloads; refresh them when `SHERPA_VERSION` changes.

| Library | License | Source | License text |
|---|---|---|---|
| OpenFst 1.8.5 (k2-fsa's packaging) | Apache-2.0, © Google LLC | https://github.com/csukuangfj/openfst (tag v1.8.5-2026-07-09) | `licenses/openfst-LICENSE.txt` |
| kaldifst 1.8.0 | Apache-2.0 | https://github.com/k2-fsa/kaldifst | `licenses/kaldifst-LICENSE.txt` |
| kaldi-decoder 0.3.0 | Apache-2.0 | https://github.com/k2-fsa/kaldi-decoder | `licenses/kaldi-decoder-LICENSE.txt` |
| kaldi-native-fbank 1.22.3 | Apache-2.0 | https://github.com/csukuangfj/kaldi-native-fbank | `licenses/kaldi-native-fbank-LICENSE.txt` |
| KISS FFT (commit febd4ca, used by kaldi-native-fbank) | BSD-3-Clause, © 2003–2010 Mark Borgerding | https://github.com/mborgerding/kissfft | `licenses/kissfft-LICENSE.txt` |
| simple-sentencepiece 0.7 | Apache-2.0 | https://github.com/pkufool/simple-sentencepiece | `licenses/simple-sentencepiece-LICENSE.txt` |
| darts-clone 0.32 (inside simple-sentencepiece) | BSD-2-Clause, © 2008–2014 Susumu Yata | https://github.com/s-yata/darts-clone | `licenses/darts-clone-LICENSE.txt` |
| nlohmann/json 3.12.0 | MIT, © 2013–2025 Niels Lohmann | https://github.com/nlohmann/json | `licenses/nlohmann-json-LICENSE.txt` |
| Eigen 5.0.1 (unmodified) | MPL-2.0 | Source code: https://gitlab.com/libeigen/eigen/-/tree/5.0.1 | `licenses/eigen-LICENSE.txt` |

Notes:

- **Kokoro** was trained on permissive or non-copyrighted audio. Its model card lists
  CC BY audio in the v1.0 training set: Koniwa `tnc` (CC BY 3.0,
  https://github.com/koniwa/koniwa) and SIWIS (CC BY 4.0,
  https://datashare.ed.ac.uk/handle/10283/2353).
- **mini-bart-g2p** was trained on CMUdict and on the LibriSpeech Alignments
  dataset by Loren Lugosch (https://zenodo.org/records/2619474), which is licensed
  CC BY 4.0 and derived from LibriSpeech (Panayotov et al., CC BY 4.0).
- **misaki's "silver" lexicons are not included.** They were generated with eSpeak NG.
- **No GPL code.** Earlier versions of Aloud (1.5 and before) used the prebuilt
  sherpa-onnx library, which links eSpeak NG (GPL-3.0) for its text-to-speech front
  end, and downloaded eSpeak NG's data with the voice. Aloud now turns text into
  phonemes itself and runs Kokoro directly on ONNX Runtime; sherpa-onnx is built from
  source with `SHERPA_ONNX_ENABLE_TTS=OFF`, which leaves out eSpeak NG and
  piper-phonemize. `scripts/check-no-espeak.sh build/Aloud.app` verifies this, and
  `scripts/build-app.sh` runs it on every build.
