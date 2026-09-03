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
    ota_rotation_for_versions,
    read_baked_ota_public_key_der,
    read_esp_app_desc,
    require_manifest_image_identity,
    require_manifest_builds,
    require_ota_firmware_url,
    require_usb_only_manifest_build,
    read_nrf_dfu_application_version,
    read_nrf_source_version,
)
from stage_beacon_revb import REV_B_FILES, REV_B_LABEL, REV_B_MANIFEST, check_site_contract

# Per-release content canaries, keyed on the version the SOURCE declares. The bare invocation is
# what a person releasing in a hurry runs, i.e. exactly the person this tool exists to protect, and
# before this map it reported "3 passed, 0 failed" on staleness alone while saying nothing about
# whether the release's actual changes were in the binary. --strings overrides this; it no longer
# has to carry it. Add a row when you cut a version, naming a string only that version introduces.
#
# A row of None means "this release introduces no honest new shared literal", which is a real state
# and is reported as a SKIP, never as a pass. A version with no row at all is still a hard failure.
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
    # 2.0.6's new i-PRO/Getac literals deliberately compile only into ACAB_CAPTURE_BUILD, which is
    # a bench image and is not one of the staged production artifacts this verifier examines. The
    # shipping images therefore have no honest new shared content literal: "i-PRO" already existed
    # in the netcam OUI table and would false-pass a 2.0.5 image.
    #
    # None is that state, DECLARED. This row used to read ["2.0.6"], and the version literal lives
    # at esp_app_desc offset 48 (release_tools.ESP_APP_VERSION_OFFSET), so the VERSION section
    # below had already proved it on the same artifact: eight green "contains '2.0.6'" rows that
    # could only fail when the version row failed. The rule further down says a check that cannot
    # fail is worse than no check because it reads as a pass, and that is exactly what those rows
    # did - they turned "this release has no content proof" into eight satisfied lines. A skip
    # says the true thing.
    #
    # The independent source-mtime and raw esp_app_desc checks stay what actually proves each
    # staged image was rebuilt from current source in a round shaped like this one.
    "2.0.6": None,
    # 2.0.7 adds vendor rows to the shared netcam tables, so every production image gains detail-
    # string labels that exist in no earlier image. "Juan OEM" and "Night Owl" are two of the five
    # new labels; neither is a substring of any string a 2.0.6 image carries ("Blink" was avoided
    # as a canary because it is short enough to false-pass on an unrelated run of bytes). The
    # Flock change in this cut alters confidence arithmetic only and introduces no literal.
    "2.0.7": ["Juan OEM", "Night Owl"],
}

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(FW, ".."))
SITE = os.path.normpath(os.path.join(REPO, "..", "soyboi.tech"))

# ONE flash layout, SHARED BY EVERY USB MANIFEST THIS FILE OPENS - the web envs it globs plus the
# two beacon revisions. esp-web-tools writes each part at its own offset, so an offset is not
# decoration: moving `partitions` off 0x8000 writes the table over NVS (0x9000 in default_8MB.csv),
# which is the BLE bond + ignore list the separate-parts layout exists to preserve. The manifests
# differ only in which filenames they name at these offsets. The web profile has an explicit
# manifest inventory below: adding an environment must update both the builder and verifier rather
# than silently leaving an install button or release gate behind.
USB_PART_OFFSETS = (0, 32768, 57344, 65536)
WEB_PART_NAMES = ("bootloader", "partitions", "boot_app0", "app")
# REV_B_FILES keys the app image as "firmware"; its rev-A twin below uses the same keys.
BEACON_PART_KEYS = ("bootloader", "partitions", "boot_app0", "firmware")

# The rev-A USB flash path, which nothing in this repo stages and, until now, nothing checked. The
# sibling's build-beacon-flasher.sh writes these four files and stamps ONE field of the manifest
# (its version string) with no independent reader, and flash.html is the page rev-A boards already
# in the field are recovered from. Same shape as stage_beacon_revb.REV_B_FILES so beacon_usb_parts
# below serves both revisions.
REV_A_MANIFEST = "manifest-beacon.json"
REV_A_FLASHER_PAGE = "flash.html"
REV_A_FILES = {
    "bootloader": "beacon-bootloader.bin",
    "partitions": "beacon-partitions.bin",
    "boot_app0": "beacon-boot_app0.bin",
    "firmware": "beacon-app.bin",
}

COLONEL_OTA_FILES = {
    "ACAB-ouispy": "acab-oui-spy-app.bin",
    "mesh-detect-ACAB": "acab-mesh-detect-app.bin",
    "mesh-detect-ACAB-ch1": "acab-mesh-detect-ch1-app.bin",
}
BEACON_OTA_FILES = {
    "beacon board": REV_A_FILES["firmware"],
    REV_B_LABEL: REV_B_FILES["firmware"],
}
OTA_APP_FILES = {**COLONEL_OTA_FILES, **BEACON_OTA_FILES}
WEB_MANIFEST_ENVS = ("oui-spy", "mesh-detect", "mesh-detect-ch1")
NRF_PACKAGE_FILE = "beacon-nrf-dfu.zip"

# The OTA trust root this release is EXPECTED to bake: SHA-256 of the SubjectPublicKeyInfo DER in
# ota_pubkey.h. The stagers prove the private key on the machine matches THAT header
# (release_tools.require_ota_signing_key_identity), but nothing else in the release path says which
# header is right - release.sh only checks the private key file exists, and the signature checks
# below verify against whatever pub file is sitting in ota_signing/ - so a swapped header with its
# matching stray keypair from another checkout would sail through while every fielded board rejects
# the update. Pinning the fingerprint makes a rotation an explicit, reviewed edit of this constant.
#
# PRODUCTION KEY since 2.0.7 (private half offline and backed up; ota_pubkey.h documents the
# rotation). The development key it replaced signed every image through 2.0.6 and signs 2.0.7 ONLY:
# that transition cut bakes this root while being signed by the retiring key, so a board still
# rooted in the development key accepts it and trusts this key from its next boot. The window is
# declared once, in release_tools.OTA_ROTATION, and check_ota_key_identity below is where the one
# release in which the signer and the baked root legitimately differ is admitted.
INTENDED_OTA_KEY_SHA256 = "c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9"

FAIL = []
OK = []


def check(cond, msg):
    (OK if cond else FAIL).append(msg)
    print(f"  {'ok  ' if cond else 'FAIL'}  {msg}")


def newest_source_mtime():
    """Newest mtime across everything that ends up compiled into an ESP32-S3 app image."""
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


def nrf_source_state(nrf_root):
    """Return (declared app version, newest build-input mtime, newest input path)."""
    root = Path(nrf_root)
    main_source = root / "src/main.cpp"
    version = read_nrf_source_version(main_source)
    newest, where = 0.0, ""
    extensions = (
        ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".ino", ".s", ".S", ".ini",
    )
    for candidate in (root / "src", root / "platformio.ini"):
        if candidate.is_file():
            paths = (candidate,)
        elif candidate.is_dir():
            paths = candidate.rglob("*")
        else:
            continue
        for path in paths:
            if not path.is_file() or path.suffix not in extensions or ".pio" in path.parts:
                continue
            mtime = path.stat().st_mtime
            if mtime > newest:
                newest, where = mtime, os.fspath(path)
    if not where:
        raise ReleaseToolError(f"{root} has no nRF build inputs")
    return version, newest, where


def require_current_nrf_package(package_path, manifest_version, nrf_root):
    """Bind one DFU package to the current nRF source version and newest build input."""
    if isinstance(manifest_version, bool) or not isinstance(manifest_version, int):
        raise ReleaseToolError(f"nRF manifest version is not an integer: {manifest_version!r}")
    source_version, source_mtime, source_path = nrf_source_state(nrf_root)
    package = Path(package_path)
    if not package.is_file():
        raise ReleaseToolError(f"nRF package is missing: {package}")
    if package.stat().st_mtime < source_mtime:
        raise ReleaseToolError(
            f"{package} is older than nRF build input {source_path}; rebuild the DFU package"
        )
    inner_version = read_nrf_dfu_application_version(package)
    if inner_version != manifest_version:
        raise ReleaseToolError(
            f"{package} application_version {inner_version} disagrees with manifest {manifest_version}"
        )
    if inner_version != source_version:
        raise ReleaseToolError(
            f"{package} application_version {inner_version} disagrees with source "
            f"NRF_APP_VERSION {source_version}"
        )
    return inner_version, source_version, source_mtime, source_path


def required_ota_labels(profile):
    labels = []
    if profile in ("colonel-panic", "all"):
        labels.extend(COLONEL_OTA_FILES)
    if profile in ("beacon", "all"):
        labels.extend(BEACON_OTA_FILES)
    return labels


def web_manifest_inventory(repo):
    """Return the fixed shipping manifest map and every manifest currently staged."""
    expected = {
        os.path.join(os.fspath(repo), "web", f"manifest-{env}.json"): env
        for env in WEB_MANIFEST_ENVS
    }
    actual = set(glob.glob(os.path.join(os.fspath(repo), "web/manifest-*.json")))
    return expected, actual


def check_ota_key_identity(shared_ver, beacon_ver, images):
    """Pin the OTA trust root: header DER == recorded fingerprint == the DER inside every staged
    image, and the pub file the signatures below are verified against is that same key. The one
    exception is the declared rotation cut (release_tools.OTA_ROTATION): there the pub file must
    be the RETIRING signer, because the images bake the new root and a fielded board accepts them
    only while they are signed by the root it already runs."""
    print("\nOTA KEY IDENTITY  (the baked-in trust root must be the recorded release key)")
    header = os.path.join(FW, "lib/acab_core/ota_pubkey.h")
    header_der = None
    try:
        header_der = read_baked_ota_public_key_der(header)
    except ReleaseToolError as exc:
        check(False, f"ota_pubkey.h DER is parseable ({exc})")
    if header_der:
        digest = hashlib.sha256(header_der).hexdigest()
        check(digest == INTENDED_OTA_KEY_SHA256,
              f"baked-in OTA public key matches the recorded release fingerprint "
              f"({digest[:12]} vs {INTENDED_OTA_KEY_SHA256[:12]})")
        # THE HEADER IS NOT THE IMAGE. The board enforces whatever DER its image carries, and
        # ACAB_OTA_PUBKEY_DER is emitted as one contiguous run of bytes (every staged 2.0.6 image
        # contained the then-current DER exactly once when this row was added). An image copied
        # from a stale build product is newer than the source by mtime, current by version and
        # by signature, and still ships the retired root; the DER itself is the only thing that
        # proves the rebuild picked the rotation up.
        for p in images:
            rel = os.path.relpath(p, os.path.dirname(REPO))
            try:
                with open(p, "rb") as handle:
                    data = handle.read()
            except OSError as exc:
                check(False, f"{rel} is readable for the trust-root scan ({exc})")
                continue
            check(header_der in data, f"{rel} bakes the {digest[:12]} trust root verbatim")
    rotation = None
    if shared_ver is not None and beacon_ver is not None:
        try:
            rotation = ota_rotation_for_versions(shared_ver, beacon_ver)
        except ReleaseToolError as exc:
            check(False, f"OTA rotation declaration agrees with the declared versions ({exc})")
    if rotation is not None:
        check(rotation["trust_root_sha256"] == INTENDED_OTA_KEY_SHA256,
              "OTA_ROTATION names the recorded release fingerprint as its new trust root")
        print(f"  !!    ROTATION CUT {rotation['release']}: images bake trust root "
              f"{rotation['trust_root_sha256'][:12]} and are signed by the retiring key "
              f"{rotation['signer_sha256'][:12]}; fielded boards accept this cut only because "
              f"they still trust the retiring key")
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
    elif rotation is not None:
        check(hashlib.sha256(file_der).hexdigest() == rotation["signer_sha256"],
              f"{os.path.basename(pub)} is the retiring {rotation['signer_sha256'][:12]} key "
              f"that signs the {rotation['release']} rotation cut")
    else:
        check(hashlib.sha256(file_der).hexdigest() == INTENDED_OTA_KEY_SHA256,
              f"{os.path.basename(pub)} is the same key the boards bake in")


def beacon_usb_parts(files):
    """The four parts of one beacon revision, bound to the shared offsets."""
    return list(zip((files[key] for key in BEACON_PART_KEYS), USB_PART_OFFSETS))


def flasher_page_names(page_path, manifest_name):
    """True when an esp-web-tools page installs `firmware/<manifest_name>`, the file this gate reads.

    The manifest is only the thing customers flash if the page points at it, so checking a manifest
    the served page has stopped naming is assurance this gate has not earned. Same reasoning AND the
    same pattern as stage_beacon_revb.check_site_contract, which asserts this for the rev-B page.

    THE DIRECTORY IS NOT OPTIONAL, and that is most of what this row buys. esp-web-tools resolves the
    attribute against the PAGE's URL, the site keeps its manifests only under firmware/, and the
    caller below opens SITE/firmware/<manifest_name> from a name of its own. Leave the prefix
    optional and those two never have to agree: a page edited to a bare `manifest-beacon.json` sends
    every rev-A flash to a 404 at the site root while this row still prints ok, because the manifest
    the gate opened for itself is the staged one and is perfectly correct. Requiring the prefix is
    what binds the string the browser follows to the file this gate inspects. rev-B was already held
    to that. rev-A was not, and rev-A is the page boards already in the field are recovered from.
    """
    try:
        html = open(page_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return bool(re.search(
        r'<esp-web-install-button\b[^>]*\bmanifest\s*=\s*["\'](?:\./)?firmware/'
        + re.escape(manifest_name) + r'["\']',
        html, re.IGNORECASE | re.DOTALL))


def check_usb_manifest(label, manifest_path, expected_version, expected_parts, src_mtime):
    """One standard for every USB flash path: version, exact parts, staged, and NOT stale.

    WHAT "check the manifest" HAS TO MEAN. Counting to four and naming the parts in the check's own
    message is not checking them: an offset typo passes, and so does a cross-wired path. Both are
    live risks. manifest-mesh-detect-ch1.json is manifest-mesh-detect.json with a different name
    line and `-ch1` in its four paths, nothing else, so a next variant made the same way whose
    paths were not renamed has four parts that all exist, are all fresh, count four and carry the
    right version, while the ch1 flasher installs the public-channel image. So `expected_parts` is
    derived by the caller from the manifest's own identity and compared exactly, in order.

    Parts are resolved against the manifest's OWN DIRECTORY because that is what esp-web-tools
    resolves them against: web/manifest-*.json names `firmware/acab-*` from web/, and the sibling
    site's two name bare filenames from soyboi.tech/firmware/.
    """
    try:
        with open(manifest_path) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        check(False, f"{label} is readable ({exc})")
        return
    check(manifest.get("version") == expected_version,
          f"{label} version {manifest.get('version')!r} == {expected_version!r}")
    # Materialize FIRST: callers pass a generator, and consuming it in the comparison would leave
    # the diagnostic print below reporting an empty expectation.
    expected = list(expected_parts)
    builds = manifest.get("builds") or []
    parts = builds[0].get("parts", []) if len(builds) == 1 and isinstance(builds[0], dict) else []
    actual = [(part.get("path"), part.get("offset")) for part in parts
              if isinstance(part, dict)]
    matches = actual == expected
    check(matches, f"{label} names only its own parts, in order, at 0x0/0x8000/0xe000/0x10000")
    if not matches:
        print(f"        expected {expected}")
        print(f"        actual   {actual}")
    base = os.path.dirname(manifest_path)
    for path, _ in actual:
        path = path or ""
        # esp-web-tools resolves these against the manifest's own URL, so anything that climbs out
        # of the directory it is served from is not a part this site serves. Refuse rather than
        # stat it: an escaping path would otherwise "exist" and be "fresh" and pass the gate.
        if path.startswith("/") or ".." in path.split("/"):
            check(False, f"{label} names a part outside its own directory: {path!r}")
            continue
        full = os.path.join(base, path)
        if not path or not os.path.isfile(full):
            check(False, f"{label} names a part that is not staged: {path or '(nothing)'}")
            continue
        # EXISTENCE IS NOT FRESHNESS. This row is the whole reason the file exists (see the header):
        # a bootloader or partition table left over from an older layout exists just as convincingly
        # as a current one, and the version string cannot tell them apart.
        check(os.path.getmtime(full) >= src_mtime,
              f"{label} part staged after the last source edit: {path}")


def bin_strings(path):
    try:
        # -n 3: the default 4-char minimum silently drops 3-char literals, and the 2.0.5 canary
        # ("cid") IS one - with the default this row failed on images that genuinely contain it.
        result = subprocess.run(["strings", "-n", "3", path], capture_output=True, text=True,
                                timeout=120)
        # CHECK THE EXIT STATUS. A nonzero strings(1) hands back empty stdout, and an empty blob
        # makes the VERSION loop below print "carries no readable banner, version not checked
        # here" - a read that FAILED, reported as a deliberate skip. Fall through to the scan.
        if result.returncode == 0 and result.stdout:
            return result.stdout
    except Exception:
        pass
    # strings(1) missing or failed: fall back to a crude printable-run scan so the gate still works.
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
        # PRINT it, do not merely record it. The summary at the end prints a COUNT, not the
        # messages, so a source version this tool refuses (unreadable, or a field past 1023 that
        # acabOtaVersionPack would pack to 0) used to raise the failure count with no line
        # anywhere saying which one it was.
        check(False, f"source declares an OTA-installable version ({exc})")
    print(f"\nsource: newest {os.path.relpath(src_path, REPO)}")
    print(f"source: declares shared version {shared_ver}, beacon version {beacon_ver}\n")

    images = sorted(glob.glob(os.path.join(REPO, "web/firmware/*-app.bin")))
    images.extend(sorted(glob.glob(os.path.join(SITE, "firmware/beacon*-app.bin"))))
    images.extend(sorted(glob.glob(os.path.join(SITE, "firmware/acab-*-app.bin"))))
    images = filter_release_profile(images, args.profile)

    if args.production:
        required = []
        if args.profile in ("colonel-panic", "all"):
            colonel_names = tuple(COLONEL_OTA_FILES.values())
            required.extend(os.path.join(REPO, "web/firmware", name) for name in colonel_names)
            required.extend(os.path.join(SITE, "firmware", name) for name in colonel_names)
        if args.profile in ("beacon", "all"):
            required.extend(os.path.join(SITE, "firmware", name)
                            for name in BEACON_OTA_FILES.values())
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
    skipped_canary = False
    for p in images:
        version = expected_version_for_artifact(p, shared_ver, beacon_ver)
        canaries = args.strings or CANARIES.get(version or "", [])
        rel = os.path.relpath(p, os.path.dirname(REPO))
        if canaries is None:
            # DECLARED as having none (see CANARIES). Report the absence, do not spend a green
            # row on it: a satisfied row here would read as content proof this release does not
            # have. Same idiom as the unreadable-banner skip above.
            print(f"  --    {rel} has no honest content canary for {version}; staleness + raw"
                  f" esp_app_desc are what prove this image was rebuilt")
            skipped_canary = True
            continue
        if not canaries:
            check(False, f"{rel} has content canaries defined for version {version}")
            continue
        blob = bin_strings(p)
        for string in canaries:
            check(string in blob, f"{rel} contains {string!r}")
    if skipped_canary and args.production:
        print("  --    NOTE: --production does not fail on a DECLARED absent canary. The"
              " per-release row stays mandatory - an undeclared version fails above - and None is"
              " the reviewed way to record a round that changed no shipped literal.")

    if args.production and not args.usb_only:
        check_ota_key_identity(shared_ver, beacon_ver, images)

    mf = os.path.join(SITE, "firmware/firmware-latest.json")
    if args.production:
        check(os.path.exists(mf), "soyboi.tech firmware-latest.json is staged")
    if os.path.exists(mf):
        print("\nOTA MANIFEST  (hash + size must describe the bytes served)")
        try:
            with open(mf) as handle:
                m = json.load(handle)
        except (OSError, ValueError) as exc:
            check(False, f"firmware-latest.json is readable ({exc})")
            m = {}
        required_labels = required_ota_labels(args.profile) if args.production else []
        if required_labels:
            try:
                # This shared validator includes the apps' top-level schema==1 adoption gate, not
                # just the required build keys. Otherwise a Colonel-Panic-only release could be
                # internally perfect while both apps reject the complete published document.
                require_manifest_builds(m, required_labels, "firmware-latest.json")
            except ReleaseToolError as exc:
                check(False, f"firmware-latest.json carries every profile-required build ({exc})")
            else:
                for label in required_labels:
                    check(True, f"manifest carries exact key {label!r}")
        builds_object = m.get("builds", {}) if isinstance(m, dict) else {}
        if not isinstance(builds_object, dict):
            check(False, "firmware-latest.json builds is an object")
            builds_object = {}
        manifest_builds = filter_release_profile(
            list(builds_object.items()), args.profile, key=lambda pair: pair[0])
        for name, b in manifest_builds:
            if not isinstance(b, dict):
                check(False, f"{name}: manifest build is an object")
                continue
            if args.production and args.usb_only:
                try:
                    require_usb_only_manifest_build(b, name)
                    check(True, f"{name}: manifest is explicitly USB-only (no OTA or nRF offer)")
                except ReleaseToolError as exc:
                    check(False, str(exc))
            app = b.get("app") or {}
            if not isinstance(app, dict):
                check(False, f"{name}: app descriptor is an object")
                continue
            fn = OTA_APP_FILES.get(name)
            if not fn:
                check(False, f"{name}: no exact staged filename is defined for this OTA build")
                continue
            try:
                require_ota_firmware_url(app.get("url"), fn, f"{name} app")
                check(True, f"{name}: OTA URL is exactly /firmware/{fn} on soyboi.tech")
            except ReleaseToolError as exc:
                check(False, str(exc))
            p = os.path.join(SITE, "firmware", fn)
            if not os.path.exists(p):
                check(False, f"{name}: required staged app {fn} not found locally")
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
                check(b.get("ota") is True, f"{name}: OTA offer flag is true for the signed image")
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
            builds = builds_object
            descriptors = []
            for label in ("beacon board", REV_B_LABEL):
                build = builds.get(label, {})
                nrf = (build.get("nrf") or {}) if isinstance(build, dict) else {}
                check(isinstance(nrf, dict) and bool(nrf),
                      f"{label}: nRF package descriptor is present and is an object")
                if not isinstance(nrf, dict) or not nrf:
                    continue
                descriptors.append((label, nrf))
                try:
                    require_ota_firmware_url(nrf.get("url"), NRF_PACKAGE_FILE, f"{label} nRF")
                    check(True, f"{label}: nRF OTA URL is exactly /firmware/{NRF_PACKAGE_FILE} "
                          "on soyboi.tech")
                except ReleaseToolError as exc:
                    check(False, str(exc))
                fn = NRF_PACKAGE_FILE
                z = os.path.join(SITE, "firmware", fn)
                if not os.path.isfile(z):
                    check(False, f"{label}: nRF package {fn} is staged")
                    continue
                rel = os.path.relpath(z, os.path.dirname(REPO))
                package = open(z, "rb").read()
                check(hashlib.sha256(package).hexdigest() == nrf.get("sha256"),
                      f"{label}: nRF sha256 matches {fn}")
                check(len(package) == nrf.get("size"), f"{label}: nRF size matches {fn}")
                try:
                    inner_version, source_version, _, source_path = require_current_nrf_package(
                        z, nrf.get("version"), os.path.join(FW, "nrf-ble-scan")
                    )
                    check(True, f"{rel} was packaged after newest nRF input "
                          f"{os.path.relpath(source_path, REPO)}")
                    check(True, f"{rel} application_version {inner_version} == {label} manifest "
                          f"and source NRF_APP_VERSION {source_version}")
                except ReleaseToolError as exc:
                    check(False, f"{rel} is current with nRF source and manifest ({exc})")

                check(nrf.get("ota") is True,
                      f"{label}: nRF OTA offer flag is true for the signed package")
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

    # THE USB FLASH PATHS. There are THREE, and this verifier used to hold them to three different
    # standards: web/manifest-*.json was never opened at all, manifest-beacon.json (rev-A, the page
    # boards already in the field are recovered from) was never opened at all, and the rev-B block
    # checked its parts for EXISTENCE only. Meanwhile the STALENESS and VERSION loops above glob
    # `*-app.bin`, so on every path the bootloader, partition table and boot_app0 went unchecked -
    # and existence is not what this file is for: a partition table left over from an older layout
    # exists exactly as convincingly as a current one.
    #
    # Not a failure a documented release run reaches - the two shell stagers copy app.bin LAST per
    # env under `set -euo pipefail`, so a run that dies mid-copy leaves that env with no app.bin and
    # the required-artifact check fails it - but a mismatched partition table written at 0x8000 is
    # not a failure worth leaving to script ordering. The manifest is what the browser follows,
    # so check_usb_manifest above checks the manifest rather than a second hardcoded name list, and
    # all three paths now go through it.
    #
    # Each caller derives the parts from the manifest's OWN IDENTITY, never hand-lists them twice:
    # manifest-<env>.json must name firmware/acab-<env>-<part>.bin, which is exactly what
    # build-flasher.sh stages ("cp ... acab-$ENV-bootloader.bin" and its three siblings), and the
    # two beacon manifests name their revision's four files from REV_A_FILES / REV_B_FILES.
    if args.production and args.profile in ("colonel-panic", "all"):
        print("\nWEB USB FLASHER  (the GitHub Pages manifests and the parts they name)")
        expected_web_manifests, actual_web_manifests = web_manifest_inventory(REPO)
        expected_paths = set(expected_web_manifests)
        check(actual_web_manifests == expected_paths,
              "web carries exactly the three profile-required USB manifests")
        if actual_web_manifests != expected_paths:
            missing = sorted(os.path.basename(path) for path in expected_paths - actual_web_manifests)
            extra = sorted(os.path.basename(path) for path in actual_web_manifests - expected_paths)
            print(f"        missing {missing or '-'}; unexpected {extra or '-'}")
        for mp, env in expected_web_manifests.items():
            if not os.path.isfile(mp):
                continue
            # build-flasher.sh stamps the version from acab_version.h, and it is what the ESP Web
            # Tools install dialog shows the person flashing.
            check_usb_manifest(
                os.path.relpath(mp, REPO), mp, shared_ver,
                zip((f"firmware/acab-{env}-{name}.bin" for name in WEB_PART_NAMES),
                    USB_PART_OFFSETS),
                src_mtime)
        # THE SAME SCRIPT STAMPS THE PAGE, AND NEVER CHECKS THAT IT MATCHED. build-flasher.sh
        # rewrites web/index.html with a bare `re.sub(r'(All Cameras Are Beacons v)[0-9...]', ...)`,
        # anchored to nothing but that sentence. Reword the sentence and the stamp becomes a silent
        # no-op: new binaries, and a page that goes on advertising the previous release to the
        # person about to flash it. pages.yml deploys web/ on any push and runs no verifier, so
        # this row is the only place that no-op can become an error.
        index = os.path.join(REPO, "web/index.html")
        try:
            html = open(index, encoding="utf-8", errors="replace").read()
        except OSError as exc:
            check(False, f"web/index.html is readable ({exc})")
        else:
            stamped = re.findall(r"All Cameras Are Beacons v([0-9][0-9A-Za-z.+-]*)", html)
            check(stamped == [shared_ver],
                  f"web/index.html footer advertises exactly [{shared_ver!r}], found {stamped}")

    if args.production and args.profile in ("beacon", "all"):
        print("\nBEACON USB FLASHERS  (rev-A and rev-B, held to one standard)")
        # rev-A first: it is the older path, it is the one no gate has ever read, and its flasher
        # page is the one the sibling site advertises to the apps as `flasher` in
        # firmware-latest.json.
        check(flasher_page_names(os.path.join(SITE, REV_A_FLASHER_PAGE), REV_A_MANIFEST),
              f"sibling {REV_A_FLASHER_PAGE} installs {REV_A_MANIFEST}")
        rev_a_path = os.path.join(SITE, "firmware", REV_A_MANIFEST)
        if not os.path.isfile(rev_a_path):
            check(False, f"{REV_A_MANIFEST} is staged")
        else:
            check_usb_manifest(REV_A_MANIFEST, rev_a_path, beacon_ver,
                               beacon_usb_parts(REV_A_FILES), src_mtime)
        try:
            check_site_contract(Path(SITE))
            check(True, "sibling site has a rev-B-only flasher page and manifest reference")
        except ReleaseToolError as exc:
            check(False, f"sibling rev-B flasher contract ({exc})")
        rev_b_path = os.path.join(SITE, "firmware", REV_B_MANIFEST)
        if not os.path.isfile(rev_b_path):
            check(False, f"{REV_B_MANIFEST} is staged")
        else:
            check_usb_manifest(REV_B_MANIFEST, rev_b_path, beacon_ver,
                               beacon_usb_parts(REV_B_FILES), src_mtime)

    # PROVENANCE. A commit SHA alone cannot identify the bytes when the tree is dirty, so the
    # dirty digest is part of the record, not a footnote.
    if args.production:
        print("\nPROVENANCE")
        import subprocess
        for label, path in (("acab", REPO), ("soyboi.tech", SITE)):
            try:
                # CHECK THE EXIT STATUS. A failed rev-parse hands back an EMPTY stdout, which used
                # to print as `label:  (working tree: clean)` - a provenance line that looks
                # captured and identifies nothing. Say it is unavailable instead.
                head = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                                      capture_output=True, text=True)
                sha = head.stdout.strip()[:12]
                if head.returncode != 0 or not sha:
                    detail = head.stderr.strip().splitlines()[-1] if head.stderr.strip() else "no HEAD"
                    print(f"  --    {label}: provenance unavailable (git rev-parse: {detail})")
                    continue
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
