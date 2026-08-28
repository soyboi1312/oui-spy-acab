# Working rules for this repo

beacons is a counter-surveillance detector: dual-radio firmware (`firmware/`), an iOS app
(`ios/Beacons`), an Android app (`android/app`), a web flasher (`web/`) and release tooling
(`firmware/tools/`). Users may be surveilled or have hardware seized. Treat a defect that leaks
location, uploads without consent, makes a muted device emit sound or light, or destroys captured
evidence as far more severe than a crash.

## Before you finish any change, re-read your own diff for these four defect classes

Every one of them has shipped here repeatedly.

1. Expensive work on a hot path: the BLE publish runs ~3 Hz and app view bodies re-run with it;
   the firmware advert path runs per packet; constructors and the main thread are cold-start paths.
2. A comment or doc that asserts a number, a cost, or another file's behavior. Open what you cite
   and verify it in the same sitting. Name symbols, never line numbers - line pointers rot.
3. Cross-platform drift. A rule the two apps share has ONE owner per change. A twin comment names
   its twin; shared thresholds are identical; artwork-derived numbers may differ per platform, but
   then each side documents its own derivation and neither copies the other's number.
4. A string, cue, or branch that is written but never rendered or reached.

## Docs and comments move with the code

Update every affected doc and comment in the same commit as the behavior change. Most documentation
drift here came from deliberate changes whose prose never moved. Prefer per-change review over
whole-tree review rounds.

Never mix a behavior pass and a prose pass in one change set. When both are needed, land the
behavior first, then true the prose against the settled code.

## Copy rules

User-facing copy is lowercase-first, uses no em-dashes, and renders the wordmark as lowercase
"beacons". Name the body-camera category "body cam", not the p-word, in user-facing strings and
commit messages. The two FAQ files (`ios/Beacons/Resources/faq-content.json` and
`android/app/src/main/assets/faq-content.json`) must stay byte-identical; edit both and check with
`cmp`. `firmware/tools/check-signature-drift.py` enforces this and other cross-platform strings.

## Verify like you mean it

- Firmware: `bash firmware/tools/host-tests/run.sh`, then `pio run -e beacon-board -e
  beacon-board-revb` from `firmware/`. A `pio run` that returns SUCCESS in about a second with no
  compile lines is a cached no-op, not a build - check object mtimes.
- Android: `./gradlew --console=plain :app:testDebugUnitTest --rerun` from `android/`.
  UP-TO-DATE is not evidence; `--rerun` forces execution.
- iOS: `xcodegen generate` after any `project.yml` or file-list change (the xcodeproj is
  generated), then `xcodebuild -scheme Beacons -destination "generic/platform=iOS Simulator"
  CODE_SIGNING_ALLOWED=NO build` and the BeaconsTests bundle on a simulator.
- Release: any change under `firmware/lib/acab_core` stales EVERY product's binaries. Re-run both
  stagers, then `python3 firmware/tools/verify-release-artifacts.py --production` must pass clean.
  Smoke-test a real board before publishing the OTA manifest.

## Deliberately local, by design

`hardware/`, `firmware/nrf-ble-scan/` and `firmware/OTA.md` are gitignored because they describe
the proprietary board design and its update path. Do not un-ignore them, and do not describe the
project as fully open source in user-facing copy.

## Tests must be able to fail

A test that passes by construction, a stub that mirrors nothing real, or a gate whose regex can
match nothing are worse than absent, because they are trusted. When you strengthen one, prove it
can fail with a deliberately wrong input before you rely on it. Tests must never write to real
user state (the App Group, shared preferences, a live widget).
