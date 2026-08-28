# The All Cameras Are Beacons web flasher

This is the little web page that lets anyone flash a board straight from their
browser, with nothing to install. It uses
[ESP Web Tools](https://esphome.github.io/esp-web-tools/), which talks to the
board over USB right from Chrome.

This page hosts the public XIAO builds only, OUI-Spy and Mesh-Detect, so anyone
building that hardware themselves has a no-toolchain way to flash it.

**The beacon you buy is not flashed from here.** It ships pre-flashed and takes its
updates over Bluetooth from the app, and its USB recovery images are board-revision
specific and live on their own pages:
[rev-A](https://soyboi.tech/flash.html) and [rev-B](https://soyboi.tech/flash-revb.html).
Both beacon products are chipFamily ESP32-S3, exactly like the XIAO builds here, so ESP
Web Tools cannot refuse a wrong image for us. Routing people in copy is the only guard
there is, which is why `index.html` opens with a caution box that names both pages.

```
web/
├── index.html                    # the flasher page
├── privacy.html                  # the canonical privacy policy, linked from the flasher footer
├── manifest-oui-spy.json         # tells the flasher about the app-controlled OUI-Spy firmware
├── manifest-mesh-detect.json     # ...and the public Mesh-Detect firmware
├── manifest-mesh-detect-ch1.json # ...and the private-channel Mesh-Detect build
├── build-flasher.sh              # rebuilds the flashable firmware files
├── vendor/
│   └── esp-web-tools/            # self-hosted ESP Web Tools 10.2.1 (see below)
└── firmware/                     # per-part images, one set of four per build
    ├── acab-oui-spy-{bootloader,partitions,boot_app0,app}.bin
    ├── acab-mesh-detect-{bootloader,partitions,boot_app0,app}.bin
    └── acab-mesh-detect-ch1-{bootloader,partitions,boot_app0,app}.bin
```

## One canonical privacy policy

`docs/signatures.md` designates `web/privacy.html` as the canonical privacy wording, and both apps
open the deployed GitHub Pages copy directly:
`https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html`. Do not point either app back
at a separately maintained site copy; the old `soyboi.tech/privacy.html` drifted and falsely said
the phone's GPS fix never left the phone after offline geotagging shipped.

`check-signature-drift.py` pins both app URLs to this page and checks the policy still discloses
the load-bearing facts from `docs/signatures.md`: the phone sends its fix to the board, the offline
buffer can retain that fix for about 18 hours, the board stores the buffer key, and the buffer is
not sealed against a seized board.

## Self-hosted ESP Web Tools

`index.html` loads ESP Web Tools from `vendor/esp-web-tools/install-button.js`, a local
copy pinned at **10.2.1**, rather than a live CDN. Serving it ourselves keeps the flash path
off a third-party host, so a hijacked future unpkg publish can't inject code into the flasher.

The vendored copy is the whole `?module` import graph from unpkg (27 JS chunks, all of them
relative imports, with the `?module` query stripped so each chunk loads by plain relative name).
It is JS only; there are no wasm or asset side-files to fetch.

To refresh it on an esp-web-tools bump:

1. Resolve the new exact version: `curl -sI "https://unpkg.com/esp-web-tools@10/dist/web/install-button.js?module"` and read the `location:` redirect.
2. Recursively pull every `./chunk.js?module` reachable from `install-button.js` into `vendor/esp-web-tools/`, then strip the `?module` query from every import.
3. Verify no `?module` and no bare (non-`./`) imports remain, and that every referenced chunk exists on disk, before committing. A half-vendored graph 404s at runtime.
4. Keep the sibling site repo's `vendor/esp-web-tools/` in lockstep: `soyboi.tech/flash.html` and `flash-revb.html` load a byte-identical copy of the same 28 files.

## Which browsers work

You'll need **Chrome, Edge, or Opera on a desktop or laptop.** Safari and Firefox
don't support the USB feature this relies on, and phones won't work either. The
page checks for you and shows a friendly warning if you're somewhere it can't run.

## Trying it on your own machine

You don't need to host anything to test it. Browsers allow this over `localhost`:

```bash
cd web
python3 -m http.server 8000
# then open http://localhost:8000 in Chrome and click Flash
```

## How it gets published

This repo publishes the flasher for you automatically. There's a GitHub Actions
workflow ([.github/workflows/pages.yml](../.github/workflows/pages.yml)) that
copies the `web/` folder up to GitHub Pages any time something in it changes, and
the live copy lands at https://soyboi1312.github.io/all-cameras-are-beacons/.

That github.io URL is this page's whole public address. `soyboi.tech/flash.html` is **not**
a friendlier front door to it: it is a separate page in the sibling site repo that installs
`firmware/manifest-beacon.json`, the rev-A beacon image. Do not describe the two as the same
page anywhere, in docs or in copy, because the mix-up is what puts a XIAO build on someone's
beacon board. If you fork this, switch Pages on under
**Settings → Pages → Source: GitHub Actions** and yours will do the same.

## Rebuilding the firmware files

After you change the firmware, regenerate the flashable images:

```bash
./web/build-flasher.sh
```

It aborts rather than publish something it cannot stand behind:

- **No OTA signing key.** An empty signature ships a manifest every board rejects in the
  field. Pass `--unsigned-usb-only` to build an explicitly unsigned, USB-only cut instead.
- **The key is there but cannot sign it—or it is the wrong valid key.** A passphrase-protected or
  corrupt PEM, an unreadable file, an openssl that rejects the arguments, or a key whose derived
  public DER differs from `firmware/lib/acab_core/ota_pubkey.h`: the run prints the failure and
  stops before building or changing either served tree, instead of producing an OTA every board
  rejects. `--unsigned-usb-only` continues here too, with an empty sig, on your explicit say-so.
  The flag defines the output, so it deliberately leaves signatures empty even when a usable key
  is present; moving the same USB-only command to another machine cannot silently turn OTA back on.
- **The vendored ESP Web Tools graph is not what HEAD would deploy.** Every file under
  `web/vendor/esp-web-tools/` has to have exactly the same path set and bytes in HEAD as it has on
  disk. That is deliberately two-way: a new untracked chunk and a tracked chunk deleted locally
  both fail. Pages deploys from the pushed commit, so either mismatch can make the flash button
  404 partway through its dynamic imports. Only `install-button.js` keeps a stable name across
  upstream bumps; the other 26 JS chunks are content-hashed, so a refresh renames them all and
  `git commit -a` alone will not pick them up.
- **`ACAB_FW_VERSION` does not parse to one well-formed version.** The manifests and the page
  footer would keep advertising the previous version while fresh binaries got staged, and the
  manifest version is what the install dialog shows the person flashing.
- **A version stamp matched nothing to rewrite.** Each `web/manifest-*.json` must carry exactly
  one `"version"` field and `web/index.html` exactly one `All Cameras Are Beacons v<ver>` footer
  marker. Wording that drifts off either pattern used to be rewritten unchanged and reported as
  success, which is the same silently-stale advertisement as the bullet above, so the stamper
  now dies at the file it could not write.

That rebuilds all three firmware variants (oui-spy, mesh-detect, mesh-detect-ch1)
and stages each as four separate part files flashed at their own offsets, kept
apart so a web flash preserves your pairing. Build outputs are frozen and signed before the first
served file changes. The GitHub Pages files plus the sibling site's app binaries and manifest are
then one rollback-guarded transaction, so a late copy or stamp failure restores both previous
trees. Commit the updated files in `firmware/` and the hosted page refreshes itself.
