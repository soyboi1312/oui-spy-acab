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
