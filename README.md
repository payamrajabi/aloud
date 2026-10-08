# Aloud

A small Mac menu-bar app that reads and writes for you, entirely on your Mac.

- **Read aloud:** select text in any app, double-tap **right ⌥**, and it's read
  aloud in the background.
- **Dictation:** tap **right ⌥** once, speak, tap it again (or hold right ⌥ while you
  talk), and the words are typed into whatever app you're in. Transcription
  uses NVIDIA's Parakeet TDT 0.6B v2 model locally, about 20–30× faster than real time.
  While you talk, every 20–30 s of speech (cut at a pause) is transcribed in the
  background, so the text is ready about a second after you stop, however long you spoke.
- **Clean-up (optional download):** a small language model, Qwen 3.5 4B run by
  [llama.cpp](https://github.com/ggml-org/llama.cpp), tidies dictation while you talk:
  punctuation and paragraphs from what you said rather than where you paused, and no
  ums, stutters or false starts. It keeps your words and never answers what you dictate.

The menu bar icon animates while it reads; click it
for the player, with the text and a scrubbable timeline. Speech is generated
locally by [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), so it's free and works offline.

**Website and download:** https://aloudformac.com

## Build it yourself

```bash
./scripts/setup.sh       # one time: downloads the speech library (19 MB), llama.cpp (58 MB) and voice model (333 MB)
./scripts/build-app.sh   # builds, signs, installs to /Applications and launches
```

On first launch macOS asks for **Accessibility** access. It's needed to read
the selected text from other apps (System Settings → Privacy & Security →
Accessibility → Aloud).

## Using it

| Action | How |
|---|---|
| Read selected text | Double-tap right ⌥ (change it in Settings) |
| Pause / resume | Space in the player, the play/pause key, or AirPods |
| Open the player | Click the menu bar icon |
| Settings | Right-click the menu bar icon, or ⋯ in the player |
| Scrub | Drag the timeline. The darker bar shows audio that's already generated |
| Jump to a sentence | Click it in the text |
| Back / forward 15 s | ← / → (with ⇧: previous / next sentence) |
| Stop | ■ in the player |
| AirPods / headphones | Press once to pause or resume, twice for the next sentence, three times for the previous one |
| Keyboard media keys, Control Center | Play/pause, next/previous sentence, and scrubbing all work |
| Dictate | Tap right ⌥ to start and tap it again to finish, or hold it while you speak. ⌘Esc cancels. Start, finish and cancel each have their own shortcut in Settings. The microphone starts on the first tap; if a second tap follows (a double-tap to read), that recording is dropped silently, and the start sound plays once the double-click interval has passed |
| Settings | Right-click the menu bar icon → Settings… (⌘,). Shortcuts can be a key combination, or a tap or double-tap of any modifier key (left/right ⌥ ⌘ ⌃ ⇧, or fn) |
| Speakers and microphones | Settings lists every connected device. Drag them into order and Aloud uses the highest one that's connected, whatever macOS is set to. Until you do, it follows macOS |
| Voice and dictation models | Both download on first launch. Settings shows their progress and lets you remove either one; Aloud then asks before downloading it again the next time you use it |
| Clean-up model | A preview, not offered to everyone yet: Settings → Downloads shows Clean-up (about 2.7 GB) only on Macs that already have the model, or after `defaults write co.payamrajabi.readaloud offerCleanup -bool YES` on a Mac with 16 GB or more. Once it's there, every dictation is tidied; remove it to go back to the raw transcript |
| Updates | Aloud checks once a day. Right after launch it shows the update window; otherwise it sends a notification, and the menu item becomes Update to Aloud x.y… |
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
- `TranscriptCleaner` tidies dictation with Qwen 3.5 4B (`LlamaEngine` wraps llama.cpp
  on the GPU). With it installed, Parakeet hands over a piece every 8–15 s; each piece
  is cleaned with the text before it as context, and its last sentence stays open to
  be cleaned again with the next piece, so a sentence split by a long pause joins back
  up. The instructions and examples are processed once and remembered. If the model's
  reply adds or swaps words (an answer instead of a tidy-up), that stretch stays raw.
  The model loads when you start dictating and is let go after 20 idle minutes.

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

## Selling Aloud

Aloud is free for 7 days from first launch, then a one-time purchase (people who
installed it while it was free keep it free; `Licensing.earlyUsersFree`). Stripe
Managed Payments sells it, so Stripe is the merchant of record and handles sales tax
and VAT worldwide.

- **Buying:** the app's Buy Aloud… opens https://aloudformac.com/buy (`docs/api/buy.mjs`),
  which starts a Stripe Checkout for the price named by `ALOUD_PRICE_LOOKUP_KEY`
  (`aloud_launch`, $9.99, or `aloud_regular`, $19). Moving off the launch price is a
  change to that Vercel setting plus the prices on the landing page, not a release.
- **Unlocking:** Checkout returns to `/thanks`, which fetches the license from
  `/api/license` and opens `aloud://activate?license=…`, so the app unlocks itself.
  Stripe also calls `/api/webhook`, which emails the license (via Resend) with a link
  to `/activate#…`. `/restore` emails it again.
- **Licenses** are the purchase details signed with Ed25519, checked offline by
  `Licensing.swift` against the public key built into the app. Nothing is stored on
  a server: the same purchase always produces the same license. The private key is
  `~/.config/aloud/license-signing-key.pem` on Payam's Mac and `LICENSE_SIGNING_KEY` on
  Vercel. Back it up: without it, no new license can unlock existing installs.
- **Setup:** `STRIPE_SECRET_KEY=sk_… ./scripts/stripe-setup.sh` creates the product,
  both prices (USD, CAD, EUR, GBP, AUD) and the webhook. The Vercel settings it needs
  are listed at the top of `docs/api/_lib.mjs`.

## License

MIT for this app's code. The download also bundles Kokoro, sherpa-onnx, ONNX
Runtime and eSpeak NG under their own licenses; see THIRD-PARTY-NOTICES.md.

## Developer test modes

```bash
swift build
.build/debug/ReadAloud --say "Hello there." --voice bm_george --out /tmp/hello.wav
.build/debug/ReadAloud --read-file article.txt --mute --trace --script "3:seek=60;6:pause;7:quit"
READALOUD_MODELS_DIR=/tmp/models .build/debug/ReadAloud --download-voice   # test the first-launch download
.build/debug/ReadAloud --test-gestures                                     # tap / double-tap / hold detection
.build/debug/ReadAloud --clean-file ramble.txt --trace                     # tidy raw dictation text, time the wait after "stop"
.build/debug/ReadAloud --script "1:settings;3:settingsshot=/tmp/s.png;4:quit"  # screenshot the Settings window
ALOUD_TRIAL_START=2026-01-01 .build/debug/ReadAloud --script "1:menu;2:quit"     # pretend the free week ran out
.build/debug/ReadAloud --check-license "<license or activation link>"          # check a license offline
```
