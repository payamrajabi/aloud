# Read Aloud

A small Mac menu-bar app: select text in any app, press **⌃⌥R**, and it's read
aloud in a floating player with a scrubbable timeline. Speech is generated
locally by [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), so it's free and works offline.

## Install

```bash
./scripts/setup.sh       # one time: downloads the speech library (19 MB) and voice model (333 MB)
./scripts/build-app.sh   # builds, signs, installs to /Applications and launches
```

On first launch macOS asks for **Accessibility** access. It's needed to read
the selected text from other apps (System Settings → Privacy & Security →
Accessibility → Read Aloud).

## Using it

| Action | How |
|---|---|
| Read selected text | ⌃⌥R (change it from the menu bar icon → Shortcut) |
| Pause / resume | Press the shortcut again, or space in the player |
| Scrub | Drag the timeline. The darker bar shows audio that's already generated |
| Jump to a sentence | Click it in the text |
| Back / forward 15 s | ← / → (with ⇧: previous / next sentence) |
| Close | Esc or the close button |
| Voice, speed | Menus in the player or the menu bar icon |

## How it works

- `SelectionReader` asks the frontmost app for its selected text through the
  Accessibility API, falling back to a simulated ⌘C that restores the clipboard.
- `TextPrep` cleans the text and splits it into sentences.
- `Synthesizer` generates sentences on a background queue, starting wherever
  you are listening and working outward. Kokoro runs about 3–4× faster than
  real time on an M1 Max.
- `PlayerModel` schedules generated sentences on an `AVAudioEngine`; speed
  changes use a time-stretch unit, so the pitch stays natural.

The model lives in `~/Library/Application Support/ReadAloud/models`.

## Developer test modes

```bash
swift build
.build/debug/ReadAloud --say "Hello there." --voice bm_george --out /tmp/hello.wav
.build/debug/ReadAloud --read-file article.txt --mute --trace --script "3:seek=60;6:pause;7:quit"
```
