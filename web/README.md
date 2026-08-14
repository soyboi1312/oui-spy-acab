# The All Cameras Are Beacons web flasher

This is the little web page that lets anyone flash a board straight from their
browser, with nothing to install. It uses
[ESP Web Tools](https://esphome.github.io/esp-web-tools/), which talks to the
board over USB right from Chrome.

The beacon you buy ships pre-flashed and ready to pair, so this page isn't how
you get it running out of the box. It's mostly here so owners can update to newer
firmware in one click when the app flags a release, and so anyone building the
public XIAO firmware themselves has a no-toolchain way to flash it.

Note: the sold beacon has its own dedicated flasher page on
[soyboi.tech/flash](https://soyboi.tech/flash.html). This page hosts the public
XIAO builds (OUI-Spy and Mesh-Detect).

```
web/
├── index.html                    # the flasher page
├── privacy.html                  # privacy note linked from the flasher
├── manifest-oui-spy.json         # tells the flasher about the app-scanner (beacon) firmware
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
4. Keep [`soyboi.tech/flash.html`](https://soyboi.tech/flash.html) in lockstep (it self-hosts an identical vendored copy).

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
the live copy lands at https://soyboi1312.github.io/all-cameras-are-beacons/, with
[soyboi.tech/flash](https://soyboi.tech/flash.html) as the friendlier front door
to the same page. If you fork this, switch Pages on under
**Settings → Pages → Source: GitHub Actions** and yours will do the same.

## Rebuilding the firmware files

After you change the firmware, regenerate the flashable images:

```bash
./web/build-flasher.sh
```

If you don't hold the OTA signing key, the script aborts rather than stage a
manifest whose empty signature makes every in-app OTA fail in the field; pass
`--unsigned-usb-only` to build an explicitly unsigned, USB-only cut instead. It
also refuses to run unless `web/vendor/esp-web-tools/` is committed to HEAD, since
Pages deploys from the pushed commit and a staged-only vendor graph would 404 the
flash button at runtime.

That rebuilds all three firmware variants (oui-spy, mesh-detect, mesh-detect-ch1)
and stages each as four separate part files flashed at their own offsets, kept
apart so a web flash preserves your pairing. Commit the updated files in
`firmware/` and the hosted page refreshes itself.
