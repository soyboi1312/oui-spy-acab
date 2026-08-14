#!/usr/bin/env python3
"""Release gate: prove the staged/signed artifacts were built from the CURRENT source.

WHY THIS EXISTS. On 2026-08-02 the web-flasher binaries and the OTA-signed beacon image all
reported version 2.0.3 and contained NEITHER the FMDN tracker match NOR the new netcam OUIs: the
staging scripts had been run right after the version bump and before the detection work landed,
and nobody re-ran them. Nothing caught it, and nothing could have:

  - The VERSION STRING cannot catch it. A fresh 2.0.3 image and a stale 2.0.3 image are
    indistinguishable by version, which is the whole trap.
  - The OTA SHA GATE cannot catch it. The manifest hash correctly described the stale binary, so
    the signature verified, the transfer verified, and the board would have accepted an image
    missing every change the release was named for.
  - A CHECK INSIDE THE BUILD SCRIPT cannot catch it. The scripts build then stage, so their output
    is always fresh at the moment they run. The failure is forgetting to run them again.

So the gate has to live OUTSIDE the build, compare artifacts against SOURCE MTIMES, and be run
before publishing. That is this file.

    ./verify-release-artifacts.py            # check everything it can find
    ./verify-release-artifacts.py --strings "Google Find Hub (separated)" "Ezviz"

Exit status is 1 on any failure, so it can gate a release step or a CI job.
"""
import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from release_tools import (
    ReleaseToolError,
    declared_versions,
    dirty_tree_digest,
    expected_project_for_artifact,
    expected_version_for_artifact,
    filter_release_profile,
    read_esp_app_desc,
    require_manifest_image_identity,
    read_nrf_dfu_application_version,
)
from stage_beacon_revb import REV_B_FILES, REV_B_LABEL, REV_B_MANIFEST, check_site_contract

# Per-release content canaries, keyed on the version the SOURCE declares. The bare invocation is
# what a person releasing in a hurry runs, i.e. exactly the person this tool exists to protect, and
# before this map it reported "3 passed, 0 failed" on staleness alone while saying nothing about
# whether the release's actual changes were in the binary. --strings overrides this; it no longer
# has to carry it. Add a row when you cut a version, naming a string only that version introduces.
CANARIES = {
    "2.0.3": ["Google Find Hub (separated)", "Ezviz"],
    # "Arlo base station" is the ideal canary for this round: it is the detail string of the NEW
    # SSID match path, so it exists in no earlier image. "Arlo" alone would also match the OUI
    # table, which cannot prove the SSID rule shipped.
    "2.0.4": ["Arlo base station", "Arlo"],
    # "cid" is the one string literal 2.0.5 introduces into EVERY app image (serializeDetection
    # emits the company-ID key for the first time; no earlier image contains the wire key).
    # Weakness, stated: it is a 3-char substring test, so any stray "...cid..." run in a stale
    # 2.0.4 image would false-pass this row - accepted because the staleness + descriptor-version
    # gates above run on the same artifacts and would still catch a stale image.
    "2.0.5": ["cid"],
}

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(FW, ".."))
SITE = os.path.normpath(os.path.join(REPO, "..", "soyboi.tech"))

# The OTA signing key this release is EXPECTED to be rooted in: SHA-256 of the
# SubjectPublicKeyInfo DER baked into ota_pubkey.h. Nothing else in the release path tests WHICH
# key is in force - release.sh only checks the private key file exists, and the signature checks
# below verify against whatever pub file is sitting in ota_signing/ - so a silent key swap (or a
# stray keypair from another checkout) would sail through while every fielded board rejects the
# update. Pinning the fingerprint makes a rotation an explicit, reviewed edit of this constant.
#
# THIS IS THE DOCUMENTED DEV KEY (ota_pubkey.h says so). When the production key is generated,
# rotate the header and update this hash in the same commit, and flip IS_DEV to False.
INTENDED_OTA_KEY_SHA256 = "39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1"
INTENDED_OTA_KEY_IS_DEV = True

FAIL = []
OK = []


def check(cond, msg):
    (OK if cond else FAIL).append(msg)
    print(f"  {'ok  ' if cond else 'FAIL'}  {msg}")


def newest_source_mtime():
    """Newest mtime across everything that ends up compiled into an app image."""
    newest, where = 0.0, ""
    for root in (os.path.join(FW, "lib"), os.path.join(FW, "src"),
                 os.path.join(FW, "platformio.ini"),
                 os.path.join(FW, "tools/stamp_app_desc.py")):
        if os.path.isfile(root):
            if os.path.getmtime(root) > newest:
                newest, where = os.path.getmtime(root), root
            continue
        for dirpath, _, files in os.walk(root):
            if ".pio" in dirpath:
                continue
            for f in files:
                if not f.endswith((".c", ".cpp", ".h", ".hpp", ".ini")):
                    continue
                p = os.path.join(dirpath, f)
                m = os.path.getmtime(p)
                if m > newest:
                    newest, where = m, p
    return newest, where


def check_ota_key_identity():
    """Pin the OTA trust root: header DER == recorded fingerprint == the pub file signatures are
    verified against. The header is what fielded boards enforce, so all three must be one key."""
    print("\nOTA KEY IDENTITY  (the baked-in trust root must be the recorded release key)")
    header = os.path.join(FW, "lib/acab_core/ota_pubkey.h")
    header_der = None
    try:
        text = open(header).read()
        m = re.search(r"ACAB_OTA_PUBKEY_DER\[\]\s*=\s*\{(.*?)\};", text, re.S)
        header_der = bytes(int(h, 16) for h in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1)))
    except Exception as exc:
        check(False, f"ota_pubkey.h DER is parseable ({exc})")
    if header_der:
        digest = hashlib.sha256(header_der).hexdigest()
        check(digest == INTENDED_OTA_KEY_SHA256,
              f"baked-in OTA public key matches the recorded release fingerprint "
              f"({digest[:12]} vs {INTENDED_OTA_KEY_SHA256[:12]})")
    pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.pem")
    file_der = None
    if os.path.exists(pub):
        r = subprocess.run(["openssl", "pkey", "-pubin", "-in", pub, "-outform", "DER"],
                           capture_output=True)
        file_der = r.stdout if r.returncode == 0 else None
    else:
        pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.der")
        if os.path.exists(pub):
            file_der = open(pub, "rb").read()
    if file_der is None:
        check(False, "ota_signing pub key file exists and is readable")
    else:
        check(hashlib.sha256(file_der).hexdigest() == INTENDED_OTA_KEY_SHA256,
              f"{os.path.basename(pub)} is the same key the boards bake in")
    if INTENDED_OTA_KEY_IS_DEV:
        print("  --    NOTE: this is the documented DEV key (ota_pubkey.h). Rotate to an offline"
              " production key before shipping OTA-capable hardware, then update"
              " INTENDED_OTA_KEY_SHA256 in the same commit.")


def bin_strings(path):
    try:
        # -n 3: the default 4-char minimum silently drops 3-char literals, and the 2.0.5 canary
        # ("cid") IS one - with the default this row failed on images that genuinely contain it.
        return subprocess.run(["strings", "-n", "3", path], capture_output=True, text=True,
                              timeout=120).stdout
    except Exception:
        # strings(1) missing: fall back to a crude printable-run scan so the gate still works.
        data = open(path, "rb").read()
        return "".join(chr(b) if 32 <= b < 127 else "\n" for b in data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strings", nargs="*", default=[],
                    help="strings that MUST appear in every app image (this release's canaries)")
    ap.add_argument("--production", action="store_true",
                    help="RELEASE GATE mode: absence of an expected artifact is a FAILURE, not a "
                         "skip; OTA signatures must be present and verify against the baked-in "
                         "public key; the nRF DFU zip must be well-formed. Without this flag the "
                         "script stays the lenient bench check it has always been.")
    ap.add_argument("--profile", choices=("beacon", "colonel-panic", "all"), default="all",
                    help="artifact family required in production mode (default: all)")
    ap.add_argument("--usb-only", action="store_true",
                    help="verify an explicitly unsigned USB-only cut without requiring OTA sigs")
    args = ap.parse_args()

    src_mtime, src_path = newest_source_mtime()
    try:
        shared_ver, beacon_ver = declared_versions(FW)
    except ReleaseToolError as exc:
        shared_ver, beacon_ver = None, None
        FAIL.append(str(exc))
    print(f"\nsource: newest {os.path.relpath(src_path, REPO)}")
    print(f"source: declares shared version {shared_ver}, beacon version {beacon_ver}\n")

    images = sorted(glob.glob(os.path.join(REPO, "web/firmware/*-app.bin")))
    images.extend(sorted(glob.glob(os.path.join(SITE, "firmware/beacon*-app.bin"))))
    images.extend(sorted(glob.glob(os.path.join(SITE, "firmware/acab-*-app.bin"))))
    images = filter_release_profile(images, args.profile)

    if args.production:
        required = []
        if args.profile in ("colonel-panic", "all"):
            colonel_names = (
                "acab-oui-spy-app.bin",
                "acab-mesh-detect-app.bin",
                "acab-mesh-detect-ch1-app.bin",
            )
            required.extend(os.path.join(REPO, "web/firmware", name) for name in colonel_names)
            required.extend(os.path.join(SITE, "firmware", name) for name in colonel_names)
        if args.profile in ("beacon", "all"):
            required.extend(os.path.join(SITE, "firmware", name) for name in (
                "beacon-app.bin",
                "beacon-revb-app.bin",
            ))
        for path in required:
            check(os.path.isfile(path), f"required artifact exists: {os.path.relpath(path, REPO)}")
    if not images:
        # NOT a pass. Returning success here is how a release with NOTHING staged sails through
        # the gate - the failure mode this script exists to prevent, in its own front door.
        if args.production:
            print("  FAIL  no staged app images found, and --production requires them")
            FAIL.append("no staged app images")
            return 1
        print("  no staged app images found; nothing to verify")
        # ...but still honor any failure already recorded (e.g. an unreadable version/config from
        # declared_versions()): returning 0 here would drop it before the FAIL summary at the end.
        return 1 if FAIL else 0

    print("STALENESS  (artifact must be newer than the newest source file)")
    for p in images:
        rel = os.path.relpath(p, os.path.dirname(REPO))
        check(os.path.getmtime(p) >= src_mtime,
              f"{rel} built after the last source edit")

    print("\nVERSION  (the image must say what the source says)")
    for p in images:
        rel = os.path.relpath(p, os.path.dirname(REPO))
        expected = expected_version_for_artifact(p, shared_ver, beacon_ver)
        try:
            descriptor_version, descriptor_project = read_esp_app_desc(p)
            check(descriptor_version == expected,
                  f"{rel} raw esp_app_desc version {descriptor_version!r} == {expected!r}")
            expected_project = expected_project_for_artifact(p)
            if expected_project:
                check(descriptor_project == expected_project,
                      f"{rel} raw esp_app_desc project_name is {expected_project!r}")
        except (OSError, ReleaseToolError) as exc:
            check(False, f"{rel} has a readable raw esp_app_desc ({exc})")
        # TWO banner forms, and missing the second made this section dead on the web path , the
        # exact path the 2026-08-02 stale-artifact incident came through. beacon-board prints
        # "=== All Cameras Are Beacons 2.0.3 ===", the Colonel Panic images print
        # "=== ACAB OUI-Spy 2.0.3 ===" / "=== ACAB Mesh-Detect 2.0.3 ===". A version check that
        # cannot fail is worse than no version check, because it reads as a pass.
        blob = bin_strings(p)
        found = (re.findall(r"All Cameras Are Beacons ([0-9.]+)", blob)
                 + re.findall(r"=== ACAB [\w-]+ ([0-9.]+) ===", blob))
        if not found:
            # oui-spy / mesh-detect images carry a different banner; only gate what we can read.
            print(f"  --    {rel} carries no readable banner, version not checked here")
            continue
        check(expected in found, f"{rel} reports {sorted(set(found))}, source says {expected}")

    print("\nCONTENT  (release canaries selected per artifact version)")
    for p in images:
        version = expected_version_for_artifact(p, shared_ver, beacon_ver)
        canaries = args.strings or CANARIES.get(version or "", [])
        rel = os.path.relpath(p, os.path.dirname(REPO))
        if not canaries:
            check(False, f"{rel} has content canaries defined for version {version}")
            continue
        blob = bin_strings(p)
        for string in canaries:
            check(string in blob, f"{rel} contains {string!r}")

    if args.production and not args.usb_only:
        check_ota_key_identity()

    mf = os.path.join(SITE, "firmware/firmware-latest.json")
    if args.production and args.profile in ("beacon", "all"):
        check(os.path.exists(mf), "soyboi.tech firmware-latest.json is staged")
    if os.path.exists(mf):
        print("\nOTA MANIFEST  (hash + size must describe the bytes served)")
        m = json.load(open(mf))
        if args.production and args.profile in ("beacon", "all"):
            for label in ("beacon board", REV_B_LABEL):
                check(label in m.get("builds", {}), f"manifest carries exact key {label!r}")
        manifest_builds = filter_release_profile(
            list(m.get("builds", {}).items()), args.profile, key=lambda pair: pair[0])
        for name, b in manifest_builds:
            app = b.get("app") or {}
            fn = app.get("url", "").split("/")[-1].split("?")[0]
            p = os.path.join(SITE, "firmware", fn)
            if not fn or not os.path.exists(p):
                check(False, f"{name}: manifest points at {fn or '(nothing)'}, not found locally")
                continue
            data = open(p, "rb").read()
            check(hashlib.sha256(data).hexdigest() == app.get("sha256"), f"{name}: sha256 matches {fn}")
            check(len(data) == app.get("size"), f"{name}: size matches {fn}")
            try:
                require_manifest_image_identity(p, name, b.get("version", ""))
                check(True, f"{name}: manifest key and version match {fn} esp_app_desc")
            except ReleaseToolError as exc:
                check(False, f"{name}: manifest artifact identity mismatch ({exc})")
            expected = beacon_ver if name in ("beacon board", REV_B_LABEL) else shared_ver
            check(b.get("version") == expected,
                  f"{name}: manifest version {b.get('version')} == {expected}")

            # SIGNATURE. The staging scripts WARN-AND-CONTINUE when openssl fails, which produces a
            # manifest carrying an empty signature - and until now this verifier accepted it. An
            # unsigned image is one the board's OTA gate will reject in the field, so shipping it
            # is a silent bricked-update release.
            if args.production and not args.usb_only:
                sig = (app.get("sig") or "").strip()
                check(bool(sig), f"{name}: OTA signature present and non-empty")
                if sig:
                    # HEX, not Base64, and the key is beacon_ota_pub.pem (or .der). Both were wrong
                    # in the first version of this gate: it looked for a beacon_ota_key.pub that has
                    # never existed and b64decoded a hex DER signature. Either mistake fails EVERY
                    # legitimate release, which is the worst possible failure for a release gate -
                    # it trains you to ignore it. build-beacon-flasher.sh emits
                    # `openssl dgst -sha256 -sign ... | xxd -p`, i.e. hex of a DER ECDSA signature,
                    # which is why a real one starts with 3044/3045.
                    pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.pem")
                    if not os.path.exists(pub):
                        pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.der")
                    if not os.path.exists(pub):
                        check(False, f"{name}: no OTA public key found to verify against")
                    else:
                        import binascii, subprocess, tempfile
                        try:
                            raw = binascii.unhexlify(sig.strip())
                        except Exception as e:
                            raw = None
                            check(False, f"{name}: signature is not hex ({e}); "
                                         f"expected hex DER from build-beacon-flasher.sh")
                        if raw:
                            with tempfile.NamedTemporaryFile(delete=False) as sf:
                                sf.write(raw); sigf = sf.name
                            keyform = "PEM" if pub.endswith(".pem") else "DER"
                            r = subprocess.run(
                                ["openssl", "dgst", "-sha256", "-verify", pub,
                                 "-keyform", keyform, "-signature", sigf, p],
                                capture_output=True)
                            check(r.returncode == 0,
                                  f"{name}: OTA signature VERIFIES against {os.path.basename(pub)}")
                            os.unlink(sigf)

        # nRF DFU package. Bind the manifest entry to the exact signed ZIP and the application
        # version inside its init packet, not just an unsigned outer version number.
        if args.production and args.profile in ("beacon", "all") and not args.usb_only:
            print("\nnRF DFU PACKAGE")
            builds = m.get("builds", {})
            descriptors = []
            for label in ("beacon board", REV_B_LABEL):
                nrf = (builds.get(label, {}).get("nrf") or {})
                check(bool(nrf), f"{label}: nRF package descriptor is present")
                if not nrf:
                    continue
                descriptors.append((label, nrf))
                fn = (nrf.get("url") or "").split("/")[-1].split("?")[0]
                z = os.path.join(SITE, "firmware", fn)
                if not fn or not os.path.isfile(z):
                    check(False, f"{label}: nRF package {fn or '(nothing)'} is staged")
                    continue
                rel = os.path.relpath(z, os.path.dirname(REPO))
                package = open(z, "rb").read()
                check(hashlib.sha256(package).hexdigest() == nrf.get("sha256"),
                      f"{label}: nRF sha256 matches {fn}")
                check(len(package) == nrf.get("size"), f"{label}: nRF size matches {fn}")
                try:
                    inner_version = read_nrf_dfu_application_version(z)
                    check(inner_version == nrf.get("version"),
                          f"{rel} application_version {inner_version} == {label} {nrf.get('version')}")
                except ReleaseToolError as exc:
                    check(False, f"{rel} inner application-only package is valid ({exc})")

                sig = (nrf.get("sig") or "").strip()
                check(bool(sig), f"{label}: nRF OTA signature present and non-empty")
                if not sig:
                    continue
                import binascii, tempfile
                try:
                    raw = binascii.unhexlify(sig)
                except Exception as exc:
                    raw = None
                    check(False, f"{label}: nRF signature is not hex ({exc})")
                if not raw:
                    continue
                pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.pem")
                if not os.path.exists(pub):
                    pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.der")
                if not os.path.exists(pub):
                    check(False, f"{label}: no OTA public key for nRF signature")
                    continue
                with tempfile.NamedTemporaryFile(delete=False) as sf:
                    sf.write(raw); sigf = sf.name
                keyform = "PEM" if pub.endswith(".pem") else "DER"
                result = subprocess.run(
                    ["openssl", "dgst", "-sha256", "-verify", pub,
                     "-keyform", keyform, "-signature", sigf, z],
                    capture_output=True,
                )
                check(result.returncode == 0,
                      f"{label}: nRF signature verifies against OTA public key")
                os.unlink(sigf)
            if len(descriptors) == 2:
                check(descriptors[0][1] == descriptors[1][1],
                      "rev-A and rev-B carry the exact same co-processor package descriptor")

    if args.production and args.profile in ("beacon", "all"):
        print("\nREV-B USB FLASHER")
        try:
            check_site_contract(Path(SITE))
            check(True, "sibling site has a rev-B-only flasher page and manifest reference")
        except ReleaseToolError as exc:
            check(False, f"sibling rev-B flasher contract ({exc})")
        usb_manifest_path = os.path.join(SITE, "firmware", REV_B_MANIFEST)
        if not os.path.exists(usb_manifest_path):
            check(False, f"{REV_B_MANIFEST} is staged")
        else:
            try:
                usb_manifest = json.load(open(usb_manifest_path))
                check(usb_manifest.get("version") == beacon_ver,
                      f"{REV_B_MANIFEST} version == {beacon_ver}")
                builds = usb_manifest.get("builds", [])
                parts = builds[0].get("parts", []) if len(builds) == 1 else []
                expected_parts = [
                    (REV_B_FILES["bootloader"], 0),
                    (REV_B_FILES["partitions"], 32768),
                    (REV_B_FILES["boot_app0"], 57344),
                    (REV_B_FILES["firmware"], 65536),
                ]
                actual_parts = [(part.get("path"), part.get("offset")) for part in parts]
                check(actual_parts == expected_parts,
                      f"{REV_B_MANIFEST} names only rev-B parts at the required offsets")
                for filename, _ in expected_parts:
                    check(os.path.isfile(os.path.join(SITE, "firmware", filename)),
                          f"rev-B USB part exists: {filename}")
            except (IndexError, OSError, ValueError) as exc:
                check(False, f"{REV_B_MANIFEST} is readable ({exc})")

    # PROVENANCE. A commit SHA alone cannot identify the bytes when the tree is dirty, so the
    # dirty digest is part of the record, not a footnote.
    if args.production:
        print("\nPROVENANCE")
        import subprocess
        for label, path in (("acab", REPO), ("soyboi.tech", SITE)):
            try:
                sha = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                                     capture_output=True, text=True).stdout.strip()[:12]
                content_digest = dirty_tree_digest(path)
                digest = content_digest[:12] if content_digest else "clean"
                print(f"  --    {label}: {sha} (working tree: {digest})")
            except Exception as e:
                print(f"  --    {label}: provenance unavailable ({e})")
        print("  --    toolchain: espressif32@6.13.0, NimBLE-Arduino@1.4.3")

    print(f"\n{len(OK)} passed, {len(FAIL)} failed\n")
    if FAIL:
        print("Re-stage before publishing:")
        print("  (cd web && ./build-flasher.sh)")
        print("  (cd ../soyboi.tech/firmware && ./build-beacon-flasher.sh)")
        print("  python3 firmware/tools/stage_beacon_revb.py --help")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
