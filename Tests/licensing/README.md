# Offline licensing checks

Run from the repository root on a Mac with Swift and Node:

```sh
bash Tests/licensing/run.sh
```

The harness imports the backend's real `licenseFor()` issuer, creates a fresh Ed25519 key
in Node memory, and verifies its signed licenses with the production `LicensePolicy` code
compiled using Foundation and CryptoKit. `LICENSING_TESTS` excludes only the AppKit/storage
adapter. The private key never leaves the fixture-generation process. Fixtures, compiled
test executable and module cache live in a temporary folder removed on exit.

Checks cover live/test separation, wrong keys and tampering, malformed signed schemas,
activation URLs with tracking/duplicate/crafted query parameters, the seven-day boundary,
legacy free installs, paid-install relaunches, and license removal after trial expiry.
They make no network calls, do not build or launch Aloud, and never initialize
`Licensing.shared` or touch `UserDefaults.standard`.

Production only accepts live licenses against its embedded public key. The expected mode
and ephemeral public key are injected into the pure verifier by these tests, never through
an app setting or environment override. Trial-date overrides and scripted license edits
exist only in `DEBUG` app builds. The trial lasts seven elapsed 24-hour days; it is local
storage, not a tamper-resistant online subscription system.

These checks do not replace full-app tests for expired provisional dictation, reading via
player/pill/media controls, activation UI, Settings links or Sparkle updates. Before live
sales, verify the release's embedded public key matches the configured issuer and complete
the sandbox purchase/fulfillment/restore acceptance flow.
