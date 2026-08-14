#!/usr/bin/env python3
"""Stage the rev-B beacon image without ever reusing the rev-A artifact names."""

from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Optional

from release_tools import ReleaseToolError, declared_versions, parse_esp_app_desc


REV_B_LABEL = "beacon board rev-B"
REV_B_FLASHER = "https://soyboi.tech/flash-revb.html"
REV_B_MANIFEST = "manifest-beacon-revb.json"
REV_B_FILES = {
    "bootloader": "beacon-revb-bootloader.bin",
    "partitions": "beacon-revb-partitions.bin",
    "boot_app0": "beacon-revb-boot_app0.bin",
    "firmware": "beacon-revb-app.bin",
}


def check_site_contract(site_dir: Path) -> None:
    """Require the sibling-owned page that makes USB recovery revision-safe."""
    page = site_dir / "flash-revb.html"
    latest = site_dir / "firmware/firmware-latest.json"
    if not page.is_file():
        raise ReleaseToolError(
            f"{page} is missing. The sibling site must add a rev-B-only flasher page before "
            "a rev-B release can be staged. Refusing to fall back to the rev-A flasher."
        )
    html = page.read_text(encoding="utf-8", errors="replace")
    reference = re.compile(
        r'<esp-web-install-button\b[^>]*\bmanifest\s*=\s*["\']'
        r'(?:\./)?firmware/manifest-beacon-revb\.json["\']',
        re.IGNORECASE | re.DOTALL,
    )
    if not reference.search(html):
        raise ReleaseToolError(
            f"{page} does not reference ./firmware/{REV_B_MANIFEST}. Refusing a page that could "
            "hand rev-B hardware the rev-A image."
        )
    if not latest.is_file():
        raise ReleaseToolError(f"{latest} is missing")
    try:
        manifest = json.loads(latest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ReleaseToolError(f"cannot parse {latest}: {exc}") from exc
    if manifest.get("schema") != 1 or not isinstance(manifest.get("builds"), dict):
        raise ReleaseToolError(f"{latest} is not a schema 1 firmware manifest")


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=os.fspath(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def _sign(image: bytes, key: Path) -> str:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.fspath(key)],
        input=image,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or not result.stdout:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ReleaseToolError(f"could not sign rev-B app image: {detail or 'empty signature'}")
    return result.stdout.hex()


def stage_rev_b(
    firmware_dir: Path,
    site_dir: Path,
    boot_app0: Path,
    signing_key: Optional[Path],
    unsigned_usb_only: bool = False,
) -> None:
    check_site_contract(site_dir)
    build_dir = firmware_dir / ".pio/build/beacon-board-revb"
    sources = {
        "bootloader": build_dir / "bootloader.bin",
        "partitions": build_dir / "partitions.bin",
        "boot_app0": boot_app0,
        "firmware": build_dir / "firmware.bin",
    }
    missing = [os.fspath(path) for path in sources.values() if not path.is_file()]
    if missing:
        raise ReleaseToolError("missing rev-B build artifact(s): " + ", ".join(missing))

    # Freeze all four build outputs once. Descriptor checks, signature, manifest hash, and staged
    # bytes all consume this snapshot, so a concurrent rebuild cannot mix generations.
    payloads = {name: path.read_bytes() for name, path in sources.items()}
    _, beacon_version = declared_versions(firmware_dir)
    descriptor_version, project_name = parse_esp_app_desc(
        payloads["firmware"], os.fspath(sources["firmware"])
    )
    if descriptor_version != beacon_version:
        raise ReleaseToolError(
            f"rev-B esp_app_desc version {descriptor_version!r} does not match declared "
            f"version {beacon_version!r}"
        )
    if project_name != REV_B_LABEL:
        raise ReleaseToolError(
            f"rev-B esp_app_desc project_name {project_name!r} does not equal {REV_B_LABEL!r}"
        )

    if unsigned_usb_only:
        signature = ""
    else:
        if signing_key is None or not signing_key.is_file():
            raise ReleaseToolError("the rev-B OTA signing key is missing")
        signature = _sign(payloads["firmware"], signing_key)

    firmware_site = site_dir / "firmware"
    latest_path = firmware_site / "firmware-latest.json"
    latest = json.loads(latest_path.read_text(encoding="utf-8"))
    rev_a = latest["builds"].get("beacon board", {})
    app_data = payloads["firmware"]
    entry = {
        "version": beacon_version,
        "ota": bool(signature),
        "app": {
            "url": "https://soyboi.tech/firmware/beacon-revb-app.bin",
            "sha256": hashlib.sha256(app_data).hexdigest(),
            "size": len(app_data),
            "sig": signature,
        },
        "flasher": REV_B_FLASHER,
        "notes": "rev-B carrier only. Do not install this image on rev-A hardware.",
    }
    if isinstance(rev_a.get("nrf"), dict):
        entry["nrf"] = copy.deepcopy(rev_a["nrf"])
    latest["builds"][REV_B_LABEL] = entry
    latest["updated"] = datetime.date.today().isoformat()

    web_manifest = {
        "name": "beacon rev-B",
        "version": beacon_version,
        "funding_url": "",
        "new_install_prompt_erase": True,
        "builds": [{
            "chipFamily": "ESP32-S3",
            "parts": [
                {"path": REV_B_FILES["bootloader"], "offset": 0},
                {"path": REV_B_FILES["partitions"], "offset": 32768},
                {"path": REV_B_FILES["boot_app0"], "offset": 57344},
                {"path": REV_B_FILES["firmware"], "offset": 65536},
            ],
        }],
    }

    # Replace each complete artifact atomically and write both manifests last. A process
    # interruption cannot leave a partial binary or a new manifest that names absent bytes.
    for source_key in ("bootloader", "partitions", "boot_app0", "firmware"):
        _atomic_write(firmware_site / REV_B_FILES[source_key], payloads[source_key])
    _atomic_write(
        firmware_site / REV_B_MANIFEST,
        (json.dumps(web_manifest, indent=2) + "\n").encode("utf-8"),
    )
    _atomic_write(
        latest_path,
        (json.dumps(latest, indent=2) + "\n").encode("utf-8"),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware-dir", type=Path, required=True)
    parser.add_argument("--site-dir", type=Path, required=True)
    parser.add_argument("--boot-app0", type=Path)
    parser.add_argument("--signing-key", type=Path)
    parser.add_argument("--unsigned-usb-only", action="store_true")
    parser.add_argument("--check-contract", action="store_true")
    args = parser.parse_args()
    try:
        check_site_contract(args.site_dir)
        if args.check_contract:
            print("rev-B sibling-site contract is present")
            return 0
        if args.boot_app0 is None:
            raise ReleaseToolError("--boot-app0 is required when staging")
        stage_rev_b(
            args.firmware_dir,
            args.site_dir,
            args.boot_app0,
            args.signing_key,
            args.unsigned_usb_only,
        )
    except (KeyError, OSError, ReleaseToolError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print("staged rev-B USB and OTA artifacts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
