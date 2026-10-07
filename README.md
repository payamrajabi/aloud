# Aloud

A small Mac menu-bar app that reads and writes for you, entirely on your Mac.

- **Read aloud:** select text in any app, double-tap **left ⌥**, and it's read
  aloud in the background.
- **Dictation:** double-tap **right ⌥**, speak, tap it once more (or hold right ⌥ while you
  talk), and the words are typed into whatever app you're in. Transcription
  uses NVIDIA's Parakeet TDT 0.6B v2 model locally, about 20–30× faster than real time.
  While you talk, every 20–30 s of speech (cut at a pause) is transcribed in the
  background, so the text is ready about a second after you stop, however long you spoke. The menu bar icon animates while it reads; click it
for the player, with the text and a scrubbable timeline. Speech is generated
locally by [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on
[ONNX Runtime](https://onnxruntime.ai), so it's free and works offline.

**Website and download:** https://aloudformac.com

## Build it yourself

```bash
./scripts/setup.sh       # one time, ~10 min: builds the dictation library, the pronunciation data, downloads the models
./scripts/build-app.sh   # builds, signs, installs to /Applications and launches
```

`setup.sh` builds sherpa-onnx 1.13.8 from source without text-to-speech (so without
eSpeak NG) into `Vendor/sherpa-onnx-asr` (needs Xcode's command-line tools; it fetches
cmake into a private venv if you don't have it), builds the pronunciation data into
`Vendor/g2p` (`scripts/make-g2p-data.py`: misaki's gold lexicons, CMUdict and the
mini-bart G2P model, pinned by checksum), and downloads the voice (355 MB) and the
dictation model (460 MB). `INSTALL=0 ./scripts/build-app.sh` builds without installing.

On first launch macOS asks for **Accessibility** access. It's needed to read
the selected text from other apps (System Settings → Privacy & Security →
Accessibility → Aloud).

## Using it

| Action | How |
|---|---|
| Read selected text | Double-tap left ⌥ (change it in Settings) |
| Pause / resume | Press the shortcut again, or space in the player |
| Open the player | Click the menu bar icon |
| Settings | Right-click the menu bar icon, or ⋯ in the player |
| Scrub | Drag the timeline. The darker bar shows audio that's already generated |
| Jump to a sentence | Click it in the text |
| Back / forward 15 s | ← / → (with ⇧: previous / next sentence) |
| Stop | ■ in the player |
| AirPods / headphones | Press once to pause or resume, twice for the next sentence, three times for the previous one |
| Keyboard media keys, Control Center | Play/pause, next/previous sentence, and scrubbing all work |
| Dictate | Double-tap right ⌥ to start and tap it once to finish, or hold it while you speak. ⌃⌥Esc cancels. Change either in Settings |
| Settings | Right-click the menu bar icon → Settings… (⌘,). Shortcuts can be a key combination, or a tap or double-tap of any modifier key (left/right ⌥ ⌘ ⌃ ⇧, or fn) |
| Speakers and microphones | Settings lists every connected device. Drag them into order and Aloud uses the highest one that's connected, whatever macOS is set to. Until you do, it follows macOS |
| Voice and dictation models | Both download on first launch. Settings shows their progress and lets you remove either one; Aloud then asks before downloading it again the next time you use it |
| Updates | Aloud checks once a day. Right after launch it shows the update window; otherwise it sends a notification, and the menu item becomes Update to Aloud x.y… |
| Copy last dictation | Right-click the menu bar icon → Copy Last Dictation |
| Voice, speed | Menus in the player or the right-click menu |

## How it works

- `SelectionReader` asks the frontmost app for its selected text through the
  Accessibility API, falling back to a simulated ⌘C that restores the clipboard.
- `TextPrep` cleans the text and splits it into sentences.
- The `Phonemizer` module turns each sentence into the phonemes Kokoro was trained
  on (misaki's notation). Each word comes from the first source that knows it: the
  hand-written lists in `Lexicons/` (tech terms, Irish names), misaki's gold lexicon
  (US or GB, with its rules for numbers, heteronyms and stress), CMUdict, then the
  small mini-bart G2P model. Before that, units, times, dates and fractions are
  rewritten as words. It's a Swift port of [misaki](https://github.com/hexgrad/misaki)
  by way of [MisakiSwift](https://github.com/mlalma/MisakiSwift), with spaCy-style
  tokenization and context rules for verb tenses ("I read it yesterday").
- `KokoroEngine` feeds those phonemes to Kokoro on ONNX Runtime, picking the voice's
  style vector by length, as sherpa-onnx did. One model serves every voice.
- `Synthesizer` generates just in time: only the current sentence and about
  25 seconds ahead of it, so nothing is wasted if you stop early. The opening
  sentence is split at a natural break so the first audio arrives in about
  half a second. Kokoro runs about 2–4× faster than real time on an M1 Max.
- `PlayerModel` schedules generated sentences on an `AVAudioEngine`; speed
  changes use a time-stretch unit, so the pitch stays natural.

The app was called Read Aloud before 1.2. The bundle ID, the `ReadAloud` folder in
Application Support, this repo and the Swift module keep that name, so settings,
permissions and downloaded models carry over.

Both models live in `~/Library/Application Support/ReadAloud/models`. The app
downloads them in the background on first launch (the voice first, then dictation),
and `scripts/setup.sh` puts them there for developers. `BUNDLE_MODEL=1
./scripts/build-app.sh` still builds an app with the voice inside, if you want one.
Set `READALOUD_MODELS_DIR` to use a different folder, e.g. to test a fresh install.

On launch, the installed app also quits and trashes older copies of itself in
/Applications or ~/Applications (such as "Read Aloud.app"), moving their bundled
voice over first so it isn't downloaded again.

## Publishing a release

```bash
./scripts/release.sh 1.0.1
```

This builds the app (about 11 MB; the voice downloads on first launch), wraps it
in `Aloud.dmg`, notarizes it, publishes it as a release of the public
[aloud-releases](https://github.com/payamrajabi/aloud-releases) repo, and adds it to
`docs/appcast.xml`. Commit and push that file to `main` afterwards: it's the feed
[Sparkle](https://sparkle-project.org) reads, so installed copies (1.4 and later)
offer the update once aloudformac.com serves it. The website's download button
(`/download`) always points at the latest release. Notarization with Apple runs automatically
once a Developer ID Application certificate and saved notary credentials
(`xcrun notarytool store-credentials readaloud ...`) exist on the Mac.

The feed address baked into every copy is `FEED_URL` in `scripts/build-app.sh`, and
the download address the feed points at is `DOWNLOAD_BASE_URL` in `scripts/release.sh`
(both on aloudformac.com, and both can be overridden as environment variables).
`/download` and `/releases/...` on aloudformac.com redirect to the aloud-releases repo
(`docs/vercel.json`), so downloads can move hosts without changing the feed. Installed copies check `FEED_URL` forever, so pick one that
will stay public.

Updates are signed with an EdDSA key whose private half lives in the login
Keychain ("Private key for signing Sparkle updates"); its public half is
`SUPublicEDKey` in `scripts/build-app.sh`. Back it up somewhere safe
(`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`): without it, no
update can ever reach existing installs again.

The landing page lives in `docs/` and is served at https://aloudformac.com by Vercel.

## License

MIT for this app's code. The download also bundles or fetches Kokoro, misaki's
lexicons, CMUdict, mini-bart-g2p, ONNX Runtime, sherpa-onnx and Sparkle under their
own licenses; see THIRD-PARTY-NOTICES.md. Nothing in it is GPL: eSpeak NG is gone as
of this version (`scripts/check-no-espeak.sh build/Aloud.app` proves it).

## Pronunciations

Add or fix a word by editing `Lexicons/tech-lexicon.json` (or another `*.json` file
there): `{ "word": "Kubernetes", "match": "case-insensitive", "us": "kˌubəɹnˈɛTiz", "gb": "kˌuːbənˈɛtiːz" }`.
Phonemes use misaki's symbols (`--phonemize` shows what Aloud says now). Files in
`~/Library/Application Support/ReadAloud/lexicons` are read last and win, so a list can
be updated without a new build. Run the regression suite after changing anything:

```bash
.build/debug/ReadAloud --g2p-test Tests/g2p/regression.json [--verbose]
```

## Developer test modes

```bash
swift build
.build/debug/ReadAloud --say "Hello there." --voice bm_george --out /tmp/hello.wav --show-phonemes
echo "Siobhan's K8s cluster" | .build/debug/ReadAloud --phonemize [--gb]    # what Aloud will say
.build/debug/ReadAloud --g2p-test Tests/g2p/regression.json               # pronunciation regression suite
.build/debug/ReadAloud --read-file article.txt --mute --trace --script "3:seek=60;6:pause;7:quit"
READALOUD_MODELS_DIR=/tmp/models .build/debug/ReadAloud --download-voice   # test the first-launch download
.build/debug/ReadAloud --test-gestures                                     # tap / double-tap / hold detection
.build/debug/ReadAloud --script "1:settings;3:settingsshot=/tmp/s.png;4:quit"  # screenshot the Settings window
```
