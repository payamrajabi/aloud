# Read Aloud

A small Mac menu-bar app that reads and writes for you, entirely on your Mac.

- **Read aloud:** select text in any app, press **⌃⌥R**, and it's read
  aloud in the background.
- **Dictation:** tap **right ⌥**, speak, tap again (or hold right ⌥ while you
  talk), and the words are typed into whatever app you're in. Transcription
  uses NVIDIA's Parakeet TDT 0.6B v2 model locally, about 20–30× faster than real time.
  While you talk, every 20–30 s of speech (cut at a pause) is transcribed in the
  background, so the text is ready about a second after you stop, however long you spoke. The menu bar icon animates while it reads; click it
for the player, with the text and a scrubbable timeline. Speech is generated
locally by [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), so it's free and works offline.

**Website and download:** https://payamrajabi.github.io/readaloud/

## Build it yourself

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
| Read selected text | ⌃⌥R (change it: right-click the menu bar icon → Shortcut) |
| Pause / resume | Press the shortcut again, or space in the player |
| Open the player | Click the menu bar icon |
| Settings | Right-click the menu bar icon, or ⋯ in the player |
| Scrub | Drag the timeline. The darker bar shows audio that's already generated |
| Jump to a sentence | Click it in the text |
| Back / forward 15 s | ← / → (with ⇧: previous / next sentence) |
| Stop | ■ in the player |
| AirPods / headphones | Press once to pause or resume, twice for the next sentence, three times for the previous one |
| Keyboard media keys, Control Center | Play/pause, next/previous sentence, and scrubbing all work |
| Dictate | Tap right ⌥ to start and again to finish, or hold it while you speak. Esc cancels. Change the key under right-click → Dictation Shortcut |
| Copy last dictation | Right-click the menu bar icon → Copy Last Dictation |
| Voice, speed | Menus in the player or the right-click menu |

## How it works

- `SelectionReader` asks the frontmost app for its selected text through the
  Accessibility API, falling back to a simulated ⌘C that restores the clipboard.
- `TextPrep` cleans the text and splits it into sentences.
- `Synthesizer` generates just in time: only the current sentence and about
  25 seconds ahead of it, so nothing is wasted if you stop early. The opening
  sentence is split at a natural break so the first audio arrives in about
  half a second. Kokoro runs about 2–4× faster than real time on an M1 Max.
- `PlayerModel` schedules generated sentences on an `AVAudioEngine`; speed
  changes use a time-stretch unit, so the pitch stays natural.

Developer builds read the model from `~/Library/Application Support/ReadAloud/models`;
downloadable builds carry it inside the app.

## Publishing a release

```bash
./scripts/release.sh 1.0.1
```

This builds the app with the model inside, wraps it in `ReadAloud.dmg`, and
uploads it as a GitHub release. The website's download button always points
at the latest release. Notarization with Apple runs automatically once a
Developer ID Application certificate and saved notary credentials
(`xcrun notarytool store-credentials readaloud ...`) exist on the Mac.

The landing page lives in `docs/` and is served by GitHub Pages.

## License

MIT for this app's code. The download also bundles Kokoro, sherpa-onnx, ONNX
Runtime and eSpeak NG under their own licenses; see THIRD-PARTY-NOTICES.md.

## Developer test modes

```bash
swift build
.build/debug/ReadAloud --say "Hello there." --voice bm_george --out /tmp/hello.wav
.build/debug/ReadAloud --read-file article.txt --mute --trace --script "3:seek=60;6:pause;7:quit"
```
