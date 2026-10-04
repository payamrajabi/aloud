# Third-party software

The Read Aloud source code in this repository is MIT licensed (see LICENSE).
The downloadable app also includes the following components, each under its
own license:

| Component | Use | License | Source |
|---|---|---|---|
| Kokoro-82M (v1.0) | Voice model | Apache-2.0 | https://huggingface.co/hexgrad/Kokoro-82M |
| sherpa-onnx | Speech runtime | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime | Neural network runtime | MIT | https://github.com/microsoft/onnxruntime |
| eSpeak NG and its data | Pronunciation of unknown words | GPL-3.0-or-later | https://github.com/espeak-ng/espeak-ng |
| piper-phonemize | Phonemizer wrapper | MIT | https://github.com/rhasspy/piper-phonemize |

eSpeak NG is licensed under the GNU General Public License v3. Its complete
source code is available at the link above; the build of sherpa-onnx used here
is release v1.13.8 (https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8),
and this app's own source is in this repository.
