#!/usr/bin/env bash
# Regenerate ACAB firmware parts for the web flasher (ESP Web Tools).
# Builds the three PlatformIO envs, then stages bootloader + partitions + boot_app0 +
# app as SEPARATE parts, each flashed at its own offset. Keeping them separate (rather
# than one merged blob from 0x0) leaves the NVS partition (0x9000) untouched, so a
# no-erase web-flash PRESERVES the BLE bond + ignore list (no re-pair on a firmware update).
#
# NOTE: this script handles oui-spy + mesh-detect only. The v2 beacon-board build +
# manifest + OTA stamping lives in the sibling site repo, at
# soyboi.tech/firmware/build-beacon-flasher.sh (the OTA-deploy tooling is split across the
# two repos). Run that one to refresh the beacon-board flasher and firmware-latest.json entry.
set -euo pipefail

# --unsigned-usb-only: explicitly stage an UNSIGNED cut (empty manifest sigs, in-app OTA disabled).
# Without it, a missing signing key ABORTS instead of warn-and-continue, matching release.sh's
# posture: the two entry points must not disagree, or the lenient one quietly publishes a manifest
# whose empty sig makes every in-app OTA fail in the field.
UNSIGNED_OK=0
for arg in "$@"; do
  case "$arg" in
    --unsigned-usb-only) UNSIGNED_OK=1 ;;
    *) echo "unknown argument: $arg (only --unsigned-usb-only is accepted)"; exit 1 ;;
  esac
done

# Vendor guard. web/index.html loads ./vendor/esp-web-tools/install-button.js as a module, and
# .github/workflows/pages.yml deploys `path: web` on any push touching web/**. All 28 files under
# web/vendor/esp-web-tools/ were UNTRACKED, with no .gitignore rule covering them, so a deploy
# published a flasher whose install button never loads: this script rewrites tracked files
# (index.html, manifest-*.json, firmware/*.bin) and the vendor graph they depend on silently
# stayed local. The sibling soyboi.tech repo does track its copy, so this was a one-repo gap.
# Refuse to stage a release against a vendor graph that will not ship.
# Checks HEAD, not the index, on purpose: `git ls-files` is satisfied by a bare `git add`, but
# Pages builds from the PUSHED COMMIT, so a staged-only vendor graph still deploys missing.
_VENDOR_ENTRY="web/vendor/esp-web-tools/install-button.js"
_REPO="$(cd "$(dirname "$0")/.." && pwd)"
if ! git -C "$_REPO" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "!! no commits in $_REPO yet; cannot verify the vendor graph will ship."; exit 1
fi
if ! git -C "$_REPO" cat-file -e "HEAD:$_VENDOR_ENTRY" 2>/dev/null; then
  echo "!! $_VENDOR_ENTRY is not committed."
  if git -C "$_REPO" ls-files --error-unmatch "$_VENDOR_ENTRY" >/dev/null 2>&1; then
    echo "!! (it IS staged, but staging alone does not deploy: Pages builds from the pushed commit.)"
    echo "!! Fix: commit the staged web/vendor, then re-run."
  else
    echo "!! Pages deploys web/ as-is, so the flash button would 404 at runtime."
    echo "!! Fix: git add -f web/vendor, commit, then re-run."
  fi
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/firmware"
# Prefer PlatformIO's venv python, but fall back to system python3: a Homebrew upgrade of
# python@3.x leaves the penv symlink dangling, and the heredocs below are stdlib-only anyway.
PY="$HOME/.platformio/penv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
ESPTOOL="$HOME/.platformio/packages/tool-esptoolpy/esptool.py"
BOOT_APP0="$(find "$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions" -name boot_app0.bin | head -1)"

[ -x "$PY" ] || { echo "PlatformIO python not found at $PY"; exit 1; }
[ -n "$BOOT_APP0" ] || { echo "boot_app0.bin not found - build the firmware once first"; exit 1; }

echo ">> building firmware (oui-spy, mesh-detect, mesh-detect-ch1)"
( cd "$FW" && pio run -e oui-spy -e mesh-detect -e mesh-detect-ch1 )

# Stamp the firmware version (single source of truth: acab_version.h) into the web
# manifests + page footer, so the flasher's displayed version can never drift from
# what the firmware actually reports.
VER="$(sed -nE 's/.*ACAB_FW_VERSION[[:space:]]*"([^"]+)".*/\1/p' "$FW/lib/acab_core/acab_version.h")"
if [ -n "$VER" ]; then
  echo ">> stamping version $VER into manifests + footer"
  "$PY" - "$VER" "$ROOT" <<'PY'
import sys, re, glob, os
ver, root = sys.argv[1], sys.argv[2]
for m in glob.glob(os.path.join(root, "web", "manifest-*.json")):
    s = open(m).read()
    s = re.sub(r'("version":\s*")[^"]*(")', lambda mo: mo.group(1) + ver + mo.group(2), s)
    open(m, "w").write(s)
idx = os.path.join(root, "web", "index.html")
h = open(idx).read()
h = re.sub(r'(All Cameras Are Beacons v)[0-9][0-9A-Za-z.+-]*', lambda mo: mo.group(1) + ver, h)
open(idx, "w").write(h)
print("   manifests + footer set to", ver)
PY
else
  echo ">> WARNING: could not read ACAB_FW_VERSION; manifests/footer left unchanged"
fi

mkdir -p "$ROOT/web/firmware"
# Stage the four flash parts SEPARATELY (not one merged blob). esp-web-tools writes
# each at its own offset, so the NVS partition (0x9000, the gap between partitions and
# boot_app0) is never overwritten and a no-erase web-flash keeps the BLE bond + whitelist.
rm -f "$ROOT/web/firmware"/acab-*.bin
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  B="$FW/.pio/build/$ENV"
  echo ">> staging parts for $ENV"
  cp "$B/bootloader.bin" "$ROOT/web/firmware/acab-$ENV-bootloader.bin"
  cp "$B/partitions.bin" "$ROOT/web/firmware/acab-$ENV-partitions.bin"
  cp "$BOOT_APP0"        "$ROOT/web/firmware/acab-$ENV-boot_app0.bin"
  cp "$B/firmware.bin"   "$ROOT/web/firmware/acab-$ENV-app.bin"
  echo "   -> acab-$ENV-{bootloader,partitions,boot_app0,app}.bin"
done

# Stamp the app-facing firmware manifest in the sibling soyboi.tech clone, if present.
# The iOS/Android apps poll https://soyboi.tech/firmware/firmware-latest.json for
# "update available" (so a firmware release needs no App Store / Play update) and for the
# OTA image hash. Keys are the fw labels the boards report in Status: "ACAB-ouispy" for
# the oui-spy build, "mesh-detect-ACAB" for public-channel mesh, "mesh-detect-ACAB-ch1" for
# the private-channel mesh build. Remember to push soyboi.tech after.
SIBLING="$(cd "$ROOT/.." && cd soyboi.tech/firmware 2>/dev/null && pwd || true)"
if [ -n "$SIBLING" ] && [ -f "$SIBLING/firmware-latest.json" ] && [ -n "${VER:-}" ]; then
  echo ">> stamping firmware-latest.json in $SIBLING"

  # Copy the freshly built app images into the sibling clone so the bytes the manifest hashes
  # are EXACTLY the bytes soyboi.tech serves for in-app OTA. Without this the manifest sha256
  # drifts from the co-hosted file on the next release (a hash-vs-bytes desync). Only the
  # *-app.bin is hosted for OTA; the other flash parts are served from the GitHub Pages flasher.
  for BN in acab-oui-spy-app.bin acab-mesh-detect-app.bin acab-mesh-detect-ch1-app.bin; do
    cp "$ROOT/web/firmware/$BN" "$SIBLING/$BN"
  done

  # Sign each staged app image for OTA-over-BLE. The board verifies a detached ECDSA
  # P-256 / SHA-256 DER signature over the whole app.bin (the same bytes it streams and
  # whose sha256 the manifest carries) against the baked-in public key before it commits
  # an OTA. Sign with the OFFLINE private key if present; if it's missing, leave each sig
  # "" so the app's OTA gate refuses an update the board would reject anyway.
  OTA_KEY="$FW/tools/ota_signing/beacon_ota_key.pem"
  sig_hex() {  # sig_hex <app.bin> -> lowercase hex DER on stdout, empty on any failure
    [ -f "$OTA_KEY" ] && [ -f "$1" ] || return 0
    local tmp; tmp="$(mktemp)"
    if openssl dgst -sha256 -sign "$OTA_KEY" "$1" > "$tmp" 2>/dev/null; then
      xxd -p "$tmp" | tr -d '\n'
    fi
    rm -f "$tmp"
  }
  if [ ! -f "$OTA_KEY" ]; then
    if [ "$UNSIGNED_OK" = "1" ]; then
      echo "!! WARNING: OTA signing key not found at $OTA_KEY; sigs left empty (in-app OTA disabled)"
      echo "!! (--unsigned-usb-only passed: continuing on your explicit say-so)"
    else
      echo "!! OTA signing key not found at $OTA_KEY."
      echo "!! An empty sig ships a manifest every board rejects in the field (silent bricked-update"
      echo "!! release). Restore the offline key, or pass --unsigned-usb-only to stage an explicitly"
      echo "!! unsigned USB-only cut."
      exit 1
    fi
  fi
  SIG_OUISPY="$(sig_hex "$ROOT/web/firmware/acab-oui-spy-app.bin")"
  SIG_MESH="$(sig_hex "$ROOT/web/firmware/acab-mesh-detect-app.bin")"
  SIG_MESH_CH1="$(sig_hex "$ROOT/web/firmware/acab-mesh-detect-ch1-app.bin")"

  "$PY" - "$VER" "$ROOT/web/firmware" "$SIBLING/firmware-latest.json" "$SIG_OUISPY" "$SIG_MESH" "$SIG_MESH_CH1" <<'PY'
import sys, json, hashlib, os, datetime
ver, bindir, lpath = sys.argv[1], sys.argv[2], sys.argv[3]
sigs = {"ACAB-ouispy": sys.argv[4], "mesh-detect-ACAB": sys.argv[5],
        "mesh-detect-ACAB-ch1": sys.argv[6]}
m = json.load(open(lpath))
for label, binname in (("ACAB-ouispy", "acab-oui-spy-app.bin"),
                       ("mesh-detect-ACAB", "acab-mesh-detect-app.bin"),
                       ("mesh-detect-ACAB-ch1", "acab-mesh-detect-ch1-app.bin")):
    b = m["builds"].get(label)
    p = os.path.join(bindir, binname)
    if not b or not os.path.exists(p):
        continue
    data = open(p, "rb").read()
    b["version"] = ver
    b["app"]["sha256"] = hashlib.sha256(data).hexdigest()
    b["app"]["size"] = len(data)
    b["app"]["sig"] = sigs[label]  # hex DER ECDSA sig, or "" when the offline key is absent
    print("   %-18s %s  %d bytes  %s" %
          (label, ver, len(data), "signed" if sigs[label] else "UNSIGNED"))
m["updated"] = datetime.date.today().isoformat()
json.dump(m, open(lpath, "w"), indent=2)
open(lpath, "a").write("\n")
PY
else
  echo ">> note: sibling soyboi.tech clone not found; firmware-latest.json not stamped"
fi

echo ">> done. Serve web/ over localhost or HTTPS to flash."
