# Firmware release gate

`release.sh` builds, stages, and verifies a release. It does not commit, tag, push, or publish.

For a beacon release, rev-A and rev-B are separate products at the artifact boundary:

- rev-A reports `beacon board` and stages as `beacon-app.bin`.
- rev-B reports `beacon board rev-B` and stages as `beacon-revb-app.bin`.
- Each image must carry its declared version and exact runtime label in raw `esp_app_desc` bytes.
- The app manifest must contain both exact keys. A rev-B entry never reuses a rev-A URL.

The firmware repository owns `stage_beacon_revb.py`, but the sibling `soyboi.tech` repository owns
the browser page. That sibling must provide `flash-revb.html` with an install button that references
`./firmware/manifest-beacon-revb.json`. The sibling provides that page today; if it is ever absent
or points elsewhere, the release preflight fails before either site stager runs. This is
intentional: falling back to `flash.html` would install rev-A firmware on rev-B hardware and leave
USB recovery as the only repair.

The rev-B stager publishes distinct bootloader, partition,
boot_app0, and app files. It replaces each complete artifact atomically and writes both manifests
last, so an interrupted run cannot leave a partial binary or a new manifest that names absent
bytes.

For an allowed dirty tree, provenance is a SHA-256 of Git's full binary patch from `HEAD` plus the
path, type, mode, and exact bytes of every untracked file. Moving the same final bytes between the
index and worktree does not change the digest, while changing dirty content does.

Focused tooling tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s firmware/tools/tests -p 'test_release_tools.py' -v
```

## OTA key rotation

The board pins one OTA trust root, `firmware/lib/acab_core/ota_pubkey.h`, and accepts only an
image signed by the root it already runs. A rotation therefore takes exactly one transition
release: that image bakes the new root but is signed by the retiring key, so every fielded board
accepts it and trusts the new root from its next boot. The tooling admits a signer that differs
from the baked root for that one release and for nothing else.

The 2.0.7 cut is that release for the current rotation: it bakes the production key (SPKI SHA-256
`c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9`) and is signed by the retiring
development key (`39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1`), which signed
every image through 2.0.6. Every image from 2.0.8 on is signed by the production key alone.

boards still trusting the development key must install the transition image before moving to
production-key-only releases. a board that skips the transition needs a USB flash once the
development-key update path is retired.

To rotate:

1. Generate the new P-256 keypair offline and back up the private half. Do not put it on the
   release machine yet: the transition cut is signed by the retiring key, and
   `require_ota_signing_key_identity` refuses the new key as signer inside the window.
2. Regenerate `firmware/lib/acab_core/ota_pubkey.h` from the new public key (SubjectPublicKeyInfo
   DER; the header comment gives the openssl form). This stales every product's binaries.
3. Declare the window in `firmware/tools/release_tools.py`: set `OTA_ROTATION` to
   `{"release": <transition version>, "trust_root_sha256": <SHA-256 of the new SPKI DER>,
   "signer_sha256": <SHA-256 of the retiring SPKI DER>}`. In the same change set
   `INTENDED_OTA_KEY_SHA256` in `verify-release-artifacts.py` to the new root, because the
   verifier requires the header, the declaration's new root, and that constant to agree. Set both
   declared versions, `ACAB_FW_VERSION` in `firmware/lib/acab_core/acab_version.h` and
   `-DACAB_FW_VERSION` in `firmware/platformio.ini` under `[env:beacon-board]`, to the transition
   release; `ota_rotation_for_versions` refuses a cut in which only one of them names it. Add the
   new key FIRST to both phone apps' trusted lists (`trustedPublicKeyPEMs` in
   `ios/Beacons/BLE/NrfDfuSignature.swift` and `TRUSTED_SPKI_B64` in
   `android/app/src/main/java/tech/acab/app/ble/NrfDfuSignature.kt`, new key first, retiring key
   second) so the apps accept the nRF package of the transition cut and of every release after it;
   the two lists must stay identical.
4. Leave the retiring private key at `firmware/tools/ota_signing/beacon_ota_key.pem` with its
   public half as `beacon_ota_pub.pem`, and run `release.sh` as usual. The verifier reads the
   `.pem` and falls back to the git-tracked `beacon_ota_pub.der` only when the `.pem` is absent, so
   the two must hold the same key. Both stagers
   call `require_ota_signing_key_identity` before they build or stage anything; inside the window
   it requires the header to bake the new root AND the key to be the retiring signer, and fails
   closed on any other pairing.
5. `python3 firmware/tools/verify-release-artifacts.py --production` must pass. Inside the window
   its OTA KEY IDENTITY block prints a `ROTATION CUT` notice, requires the header to equal
   `INTENDED_OTA_KEY_SHA256`, requires every staged app image to contain the header's DER
   verbatim (a stale image that still bakes the old root fails this row even though its
   signature verifies), and requires the pub file to be the retiring signer. Outside the window the
   pub file must be the recorded root. A declaration whose release either declared version has
   moved past, or that only one declared version names, is a FAIL row, not a skip.
6. Smoke-test a real board, then publish the manifest.
7. Before the next version is cut: place the new private key at
   `firmware/tools/ota_signing/beacon_ota_key.pem`, its public half at `beacon_ota_pub.pem`, and
   the same public key as the git-tracked `beacon_ota_pub.der` (that file is what a fresh clone
   verifies against; it is public, so commit it), and set `OTA_ROTATION` back to `None`. Once either declared version moves past the
   transition release, `ota_rotation_for_versions` raises `delete the stale declaration` and both
   gates fail until it is gone. `INTENDED_OTA_KEY_SHA256` already names the new root and changes
   only at the next rotation. Retire the old key from both apps' lists, together with the
   dev-signed test vector in `NrfDfuSignatureTests.swift` and `NrfDfuSignatureTest.kt`, once every
   fielded board and app has passed the transition release.

`OtaSigningKeyIdentityTests` and `VerifierOtaKeyIdentityTests` in
`firmware/tools/tests/test_release_tools.py` cover the window, the stale and mixed declarations,
the verbatim-DER image row, and the rule that the pub file inside the window is the retiring signer.

## Rev-B hardware gate

Before publishing a rev-B image, record the pairing-window serial signature for each distinct
start path on a real prototype:

- cold power-on through the Panasonic button
- wake from deep sleep through the button
- warm OTA restart, which must not reopen the physical pairing window
- USB-only or no-cell auto-on

Also verify the reported board label is `beacon board rev-B`, the software UART cross reaches the
nRF co-processor, committed-off behavior survives the intended power transitions, and both phone
apps can complete a real rev-B S3 update. Keep only one nearby beacon in legacy Nordic DFU during
the co-processor portion of the bench pass.
