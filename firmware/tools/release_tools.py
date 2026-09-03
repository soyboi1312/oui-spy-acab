#!/usr/bin/env python3
"""Shared, side-effect-free helpers for the firmware release gates."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile
from typing import Iterable, List, Optional, Tuple, TypeVar, Union


ESP_IMAGE_MAGIC = 0xE9
ESP_APP_DESC_MAGIC = 0xABCD5432
# Each dotted field packs into 10 bits. acabOtaVersionPack (firmware/lib/acab_core/ota_policy.h)
# returns 0 for a field past this, and acabOtaAuthenticatedVersionAllowed hard-rejects 0, so a
# field above 1023 is not a cosmetic version: it is a fully signed, fully staged release that no
# board will ever install over the air while both apps go on offering it forever. acab_version.h
# states the rule in prose ("KEEP EVERY DOTTED FIELD UNDER 1024"); every parser in the tooling was
# looser than the prose, so the release could be cut. USB recovery still works, so this is a dead
# OTA path, not a brick.
OTA_VERSION_FIELD_MAX = 1023
# The board packs at most three dotted numeric fields. Both apps deliberately strip only a
# dash-prefixed suffix before validating/comparing the numeric core, so this is the one source
# grammar every release surface can interpret identically. Keep it ASCII-only: these values are
# copied into esp_app_desc and cross an attacker-influenced status boundary later.
OTA_VERSION_RE = re.compile(
    r"(?P<core>[0-9]+(?:\.[0-9]+){0,2})(?:-(?P<suffix>[0-9A-Za-z][0-9A-Za-z.-]*))?\Z"
)
ESP_APP_DESC_OFFSET = 24 + 8
ESP_APP_VERSION_OFFSET = ESP_APP_DESC_OFFSET + 16
ESP_APP_PROJECT_OFFSET = ESP_APP_VERSION_OFFSET + 32
ESP_APP_TEXT_FIELD_SIZE = 32
OTA_FIRMWARE_BASE_URL = "https://soyboi.tech/firmware/"

# ONE-RELEASE OTA KEY ROTATION WINDOW, or None while no rotation is in progress.
#
# The board pins exactly one trust root (lib/acab_core/ota_pubkey.h) and accepts only an image
# signed by the root it already runs, so a rotation needs one transition cut that BAKES the new
# root while being SIGNED by the retiring key: every fielded board accepts that cut and trusts the
# new root from its next boot. It is the one release in which the signer and the baked root may
# legitimately differ. require_ota_signing_key_identity admits the difference only for the release
# named here (every stager calls it before it builds or stages anything), and
# verify-release-artifacts.py re-proves it against the staged images. Every later release is
# signed by the new root alone, and both gates refuse a declaration that has outlived its release,
# so set OTA_ROTATION back to None when the version after "release" is cut. Keep the name:
# ota_rotation_for_versions reads it, and the tests patch it by name.
#
# 2.0.7 retires the development key, which signed every image through 2.0.6, for the offline
# production key. Both fingerprints are SHA-256 over SubjectPublicKeyInfo DER.
OTA_ROTATION: Optional[dict] = {
    "release": "2.0.7",
    "trust_root_sha256": "c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9",
    "signer_sha256": "39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1",
}


class ReleaseToolError(RuntimeError):
    """A release artifact or source tree does not satisfy its contract."""


def _git_bytes(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", os.fspath(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ReleaseToolError(f"git {' '.join(args)} failed in {repo}: {detail}")
    return result.stdout


def _hash_record(digest: "hashlib._Hash", kind: bytes, name: bytes, payload: bytes) -> None:
    """Hash unambiguous length-delimited records, including names with any byte value."""
    digest.update(struct.pack(">Q", len(kind)))
    digest.update(kind)
    digest.update(struct.pack(">Q", len(name)))
    digest.update(name)
    digest.update(struct.pack(">Q", len(payload)))
    digest.update(payload)


def dirty_tree_digest(repo: Union[os.PathLike, str]) -> Optional[str]:
    """Return a SHA-256 of dirty content, or None for a clean working tree.

    Tracked changes are represented by Git's full binary patch from HEAD to the final working
    tree. Untracked files are represented by path, type, mode, and exact bytes. Index placement
    is deliberately absent: staging the same final bytes must not change their provenance.
    """
    root = Path(repo).resolve()
    _git_bytes(root, "rev-parse", "--verify", "HEAD")

    tracked = _git_bytes(
        root,
        "--no-pager",
        "diff",
        "--binary",
        "--full-index",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--no-color",
        "HEAD",
        "--",
    )
    untracked_raw = _git_bytes(
        root, "ls-files", "--others", "--exclude-standard", "-z", "--"
    )
    untracked = sorted(path for path in untracked_raw.split(b"\0") if path)
    if not tracked and not untracked:
        return None

    digest = hashlib.sha256()
    digest.update(b"ACAB dirty tree provenance v1\0")
    if tracked:
        _hash_record(digest, b"tracked-binary-patch", b"HEAD", tracked)

    root_bytes = os.fsencode(root)
    for rel in untracked:
        if rel.startswith(b"/") or b"\0" in rel:
            raise ReleaseToolError(f"unsafe untracked path from git: {rel!r}")
        path_bytes = os.path.join(root_bytes, rel)
        try:
            stat_result = os.lstat(path_bytes)
        except OSError as exc:
            raise ReleaseToolError(f"cannot read untracked path {rel!r}: {exc}") from exc

        mode = stat_result.st_mode
        if os.path.islink(path_bytes):
            kind = b"symlink"
            payload = os.fsencode(os.readlink(path_bytes))
        elif os.path.isfile(path_bytes):
            kind = b"file"
            with open(path_bytes, "rb") as handle:
                payload = handle.read()
        else:
            kind = b"special"
            payload = b""
        metadata = f"{mode:o}".encode("ascii") + b"\0" + payload
        _hash_record(digest, kind, rel, metadata)

    return digest.hexdigest()


def _decode_desc_field(raw: bytes, field_name: str) -> str:
    value = raw.split(b"\0", 1)[0]
    if not value:
        raise ReleaseToolError(f"esp_app_desc {field_name} is empty")
    try:
        return value.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ReleaseToolError(f"esp_app_desc {field_name} is not ASCII") from exc


def parse_esp_app_desc(prefix: bytes, source: str = "ESP image") -> Tuple[str, str]:
    """Return version and project name from raw bytes at the start of an ESP32 app image."""
    minimum = ESP_APP_PROJECT_OFFSET + ESP_APP_TEXT_FIELD_SIZE
    if len(prefix) < minimum:
        raise ReleaseToolError(f"{source} is too short to contain esp_app_desc")
    if prefix[0] != ESP_IMAGE_MAGIC:
        raise ReleaseToolError(
            f"{source} has ESP image magic 0x{prefix[0]:02x}, expected 0x{ESP_IMAGE_MAGIC:02x}"
        )
    desc_magic = struct.unpack_from("<I", prefix, ESP_APP_DESC_OFFSET)[0]
    if desc_magic != ESP_APP_DESC_MAGIC:
        raise ReleaseToolError(
            f"{source} has esp_app_desc magic 0x{desc_magic:08x}, "
            f"expected 0x{ESP_APP_DESC_MAGIC:08x}"
        )
    version = _decode_desc_field(
        prefix[ESP_APP_VERSION_OFFSET:ESP_APP_VERSION_OFFSET + ESP_APP_TEXT_FIELD_SIZE],
        "version",
    )
    project = _decode_desc_field(
        prefix[ESP_APP_PROJECT_OFFSET:ESP_APP_PROJECT_OFFSET + ESP_APP_TEXT_FIELD_SIZE],
        "project_name",
    )
    return version, project


def read_esp_app_desc(path: Union[os.PathLike, str]) -> Tuple[str, str]:
    """Return version and project name from the first ESP32 app image segment."""
    image = Path(path)
    minimum = ESP_APP_PROJECT_OFFSET + ESP_APP_TEXT_FIELD_SIZE
    with image.open("rb") as handle:
        prefix = handle.read(minimum)
    return parse_esp_app_desc(prefix, os.fspath(image))


def require_manifest_image_identity(
    path: Union[os.PathLike, str], manifest_label: str, manifest_version: str
) -> Tuple[str, str]:
    """Require a manifest entry to name the exact signed ESP image product and version."""
    version, project = read_esp_app_desc(path)
    if project != manifest_label:
        raise ReleaseToolError(
            f"manifest key {manifest_label!r} references image project_name {project!r}"
        )
    if version != manifest_version:
        raise ReleaseToolError(
            f"manifest version {manifest_version!r} references image version {version!r}"
        )
    return version, project


def read_nrf_dfu_application_version(path: Union[os.PathLike, str]) -> int:
    """Read the version bound inside a signed Adafruit legacy-DFU package."""
    package = Path(path)
    try:
        with zipfile.ZipFile(package) as archive:
            all_infos = archive.infolist()
            infos = [info for info in all_infos if info.filename == "manifest.json"]
            if len(infos) != 1:
                raise ReleaseToolError(
                    f"{package} must contain exactly one root manifest.json"
                )
            info = infos[0]
            if info.flag_bits & 0x1:
                raise ReleaseToolError(f"{package} manifest.json is encrypted")
            if info.compress_type != zipfile.ZIP_STORED:
                raise ReleaseToolError(f"{package} manifest.json is not stored")
            if info.file_size <= 0 or info.file_size > 64 * 1024:
                raise ReleaseToolError(f"{package} manifest.json has an invalid size")
            if any(item.flag_bits & 0x1 for item in all_infos):
                raise ReleaseToolError(f"{package} contains an encrypted entry")
            if any(item.compress_type != zipfile.ZIP_STORED for item in all_infos):
                raise ReleaseToolError(f"{package} contains a non-stored entry")
            manifest = json.loads(archive.read(info))
    except ReleaseToolError:
        raise
    except (OSError, zipfile.BadZipFile, KeyError, TypeError, ValueError) as exc:
        raise ReleaseToolError(f"cannot read nRF DFU package {package}: {exc}") from exc
    try:
        body = manifest["manifest"]
        application = body["application"]
        version = application["init_packet_data"]["application_version"]
        bin_file = application["bin_file"]
        dat_file = application["dat_file"]
    except (KeyError, TypeError) as exc:
        raise ReleaseToolError(f"{package} has an incomplete application manifest") from exc
    forbidden = {"softdevice", "bootloader", "softdevice_bootloader"}.intersection(body)
    if forbidden:
        raise ReleaseToolError(
            f"{package} includes forbidden non-application sections {sorted(forbidden)}"
        )
    if not isinstance(bin_file, str) or not isinstance(dat_file, str) or not bin_file or not dat_file:
        raise ReleaseToolError(f"{package} has invalid application filenames")
    if "/" in bin_file or "/" in dat_file or "\\" in bin_file or "\\" in dat_file:
        raise ReleaseToolError(f"{package} application filenames must be root basenames")
    names = [info.filename for info in all_infos]
    expected_names = {"manifest.json", bin_file, dat_file}
    if len(names) != len(set(names)) or set(names) != expected_names:
        raise ReleaseToolError(
            f"{package} must contain exactly manifest.json, {bin_file}, and {dat_file}"
        )
    if isinstance(version, bool) or not isinstance(version, int) or not 0 <= version <= 0xFFFFFFFF:
        raise ReleaseToolError(f"{package} has invalid application_version {version!r}")
    dat_infos = [info for info in all_infos if info.filename == dat_file]
    if len(dat_infos) != 1 or not 0 < dat_infos[0].file_size <= 4 * 1024:
        raise ReleaseToolError(f"{package} has an invalid legacy init packet")
    try:
        with zipfile.ZipFile(package) as archive:
            init_packet = archive.read(dat_infos[0])
    except (OSError, zipfile.BadZipFile, KeyError, RuntimeError) as exc:
        raise ReleaseToolError(f"cannot read nRF init packet from {package}: {exc}") from exc
    if len(init_packet) < 12:
        raise ReleaseToolError(f"{package} has a truncated legacy init packet")
    requirement_count = struct.unpack_from("<H", init_packet, 8)[0]
    if len(init_packet) != 12 + requirement_count * 2:
        raise ReleaseToolError(f"{package} has a malformed legacy init packet")
    packet_version = struct.unpack_from("<I", init_packet, 4)[0]
    if packet_version != version:
        raise ReleaseToolError(
            f"{package} manifest version {version} disagrees with init packet {packet_version}"
        )
    return version


def read_nrf_source_version(path: Union[os.PathLike, str]) -> int:
    """Read the one integer ``NRF_APP_VERSION`` shipped by the co-processor source.

    The DFU package carries this number in both manifest.json and its legacy init packet. Reading
    the source independently lets the release gate distinguish a self-consistent OLD package from
    one rebuilt after the current nRF source changed.
    """
    source = Path(path)
    try:
        text = source.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ReleaseToolError(f"cannot read nRF source version from {source}: {exc}") from exc
    matches = re.findall(
        r"(?m)^\s*#define\s+NRF_APP_VERSION\s+([0-9]+)\s*(?://[^\r\n]*)?$", text
    )
    if len(matches) != 1:
        raise ReleaseToolError(
            f"{source} must declare exactly one integer NRF_APP_VERSION (found {len(matches)})"
        )
    version = int(matches[0])
    if version > 0xFFFFFFFF:
        raise ReleaseToolError(f"{source} NRF_APP_VERSION {version} exceeds uint32")
    return version


def require_manifest_builds(manifest: object, labels: Iterable[str], source: str) -> dict:
    """Return a schema-1 app-manifest build map with every profile-required label.

    Both phone apps reject the whole document before consulting ``builds`` unless ``schema`` is
    exactly the integer 1. Keep that adoption gate here, in the validator shared by the stager and
    production verifier, so a self-consistent set of signed artifacts cannot be published inside
    a manifest neither app will accept.
    """
    if not isinstance(manifest, dict):
        raise ReleaseToolError(f"{source} is not an object")
    if type(manifest.get("schema")) is not int or manifest.get("schema") != 1:
        raise ReleaseToolError(f"{source} schema must be exactly integer 1")
    if not isinstance(manifest.get("builds"), dict):
        raise ReleaseToolError(f"{source} has no builds object")
    builds = manifest["builds"]
    missing = [label for label in labels if not isinstance(builds.get(label), dict)]
    if missing:
        raise ReleaseToolError(f"{source} is missing required build key(s): {', '.join(missing)}")
    return builds


def require_ota_firmware_url(url: object, filename: str, source: str) -> str:
    """Require the URL the apps fetch to name the exact file this release gate verifies locally."""
    expected = OTA_FIRMWARE_BASE_URL + filename
    if url != expected:
        raise ReleaseToolError(f"{source} URL {url!r} must equal {expected!r}")
    return expected


def read_baked_ota_public_key_der(path: Union[os.PathLike, str]) -> bytes:
    """Read the SubjectPublicKeyInfo DER byte array enforced by the firmware."""
    header = Path(path)
    try:
        text = header.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ReleaseToolError(f"cannot read OTA public-key header {header}: {exc}") from exc
    match = re.search(r"ACAB_OTA_PUBKEY_DER\[\]\s*=\s*\{(.*?)\};", text, re.S)
    if not match:
        raise ReleaseToolError(f"{header} has no ACAB_OTA_PUBKEY_DER byte array")
    values = re.findall(r"0x([0-9A-Fa-f]{2})", match.group(1))
    if not values:
        raise ReleaseToolError(f"{header} ACAB_OTA_PUBKEY_DER is empty")
    return bytes(int(value, 16) for value in values)


def require_ota_signing_key_identity(
    key_path: Union[os.PathLike, str], header_path: Union[os.PathLike, str]
) -> str:
    """Require a usable, unencrypted private key rooted in the public key boards enforce.

    Release scripts deliberately have no passphrase channel. ``-passin pass:`` makes an encrypted
    key fail without opening an interactive prompt, while a normal offline key derives its SPKI
    public DER. Comparing those bytes directly to the firmware header catches a valid key from a
    different checkout before it signs and stages a release every fielded board would reject.

    The one exception is the declared rotation cut (OTA_ROTATION). The header belongs to a
    firmware tree (``<firmware>/lib/acab_core/ota_pubkey.h``), and when the versions that tree
    declares name the rotation release, the header must bake the NEW root and the key must be the
    RETIRING signer, because a fielded board accepts only an image signed by the root it already
    runs. Any other pairing in that release fails closed: the new key cannot sign the transition
    cut, and an unrotated header cannot ship under the rotation's name. Returns the baked
    trust-root fingerprint for the release log in both cases.
    """
    key = Path(key_path)
    if not key.is_file():
        raise ReleaseToolError(f"OTA signing key is missing: {key}")
    try:
        result = subprocess.run(
            [
                "openssl", "pkey", "-in", os.fspath(key), "-passin", "pass:",
                "-pubout", "-outform", "DER",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        raise ReleaseToolError(f"cannot run openssl to inspect OTA signing key: {exc}") from exc
    if result.returncode != 0 or not result.stdout:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ReleaseToolError(
            f"cannot derive public key from {key}: {detail or 'empty public key'}"
        )
    signer = result.stdout
    baked = read_baked_ota_public_key_der(header_path)
    signer_digest = hashlib.sha256(signer).hexdigest()
    baked_digest = hashlib.sha256(baked).hexdigest()
    rotation = None
    if OTA_ROTATION is not None:
        # The window is placed by the versions of the tree that owns the header. A declared
        # rotation that cannot be placed is refused rather than demoted to the plain rule: an
        # unplaceable header is exactly the misrouted or stale one this check exists to stop.
        try:
            firmware_dir = Path(os.path.abspath(header_path)).parents[2]
            shared, beacon = declared_versions(firmware_dir)
        except (IndexError, OSError) as exc:
            raise ReleaseToolError(
                f"cannot read the declared versions of the firmware tree that owns {header_path} "
                f"to place the {OTA_ROTATION['release']} OTA rotation window: {exc}"
            ) from exc
        rotation = ota_rotation_for_versions(shared, beacon)
    if rotation is not None:
        if (baked_digest != rotation["trust_root_sha256"]
                or signer_digest != rotation["signer_sha256"]):
            raise ReleaseToolError(
                f"the {rotation['release']} OTA rotation cut must bake the new trust root "
                f"{rotation['trust_root_sha256'][:12]} and be signed by the retiring key "
                f"{rotation['signer_sha256'][:12]}, but {header_path} bakes {baked_digest[:12]} "
                f"and {key} signs as {signer_digest[:12]}"
            )
        return baked_digest
    if signer != baked:
        raise ReleaseToolError(
            f"{key} does not match the OTA trust root baked into {header_path} "
            f"({signer_digest[:12]} vs {baked_digest[:12]})"
        )
    return baked_digest


def require_usb_only_manifest_build(build: object, source: str) -> dict:
    """Require an explicitly unsigned build that neither app can offer over the air.

    USB-only is an operator-selected release mode, not a fallback for a missing key. Its manifest
    must therefore describe that mode unambiguously even when a usable signing key happens to be
    present on the build machine. Companion nRF DFU is app-delivered too, so it must not be
    advertised by a USB-only cut.
    """
    if not isinstance(build, dict):
        raise ReleaseToolError(f"{source} build must be an object")
    app = build.get("app")
    if not isinstance(app, dict):
        raise ReleaseToolError(f"{source} app must be an object")
    if build.get("ota") is not False:
        raise ReleaseToolError(f"{source} ota must be exactly false for a USB-only cut")
    if app.get("sig") != "":
        raise ReleaseToolError(f"{source} app.sig must be exactly empty for a USB-only cut")
    if "nrf" in build:
        raise ReleaseToolError(f"{source} must not advertise nRF DFU in a USB-only cut")
    return build


def require_ota_packable_version(version: str, source: str) -> str:
    """Require one version spelling the board and both apps interpret identically.

    The numeric core is one to three nonempty dotted ASCII fields. A nonempty dash suffix is
    allowed because the board packer and both app OTA gates deliberately ignore it. Everything
    else is rejected in full rather than letting the packer's prefix parsing silently reinterpret
    a release label. The packed value must also be nonzero: every OTA gate reserves zero for a
    malformed version.
    """
    match = OTA_VERSION_RE.fullmatch(version)
    if not match:
        raise ReleaseToolError(
            f"{source} declares version {version!r}: expected 1-3 dotted ASCII numeric fields "
            "with an optional nonempty '-suffix'"
        )
    if len(version.encode("ascii")) >= ESP_APP_TEXT_FIELD_SIZE:
        raise ReleaseToolError(
            f"{source} declares version {version!r}: it does not fit the "
            f"{ESP_APP_TEXT_FIELD_SIZE - 1}-byte esp_app_desc version field"
        )

    fields = [int(field) for field in match.group("core").split(".")]
    for field in fields:
        if field > OTA_VERSION_FIELD_MAX:
            raise ReleaseToolError(
                f"{source} declares version {version!r}: field {field} exceeds "
                f"{OTA_VERSION_FIELD_MAX}, which acabOtaVersionPack packs to 0 and every OTA gate "
                f"rejects. Bump the minor instead."
            )
    if not any(fields):
        raise ReleaseToolError(
            f"{source} declares version {version!r}: acabOtaVersionPack reserves packed value 0 "
            "for malformed versions and every OTA gate rejects it"
        )
    return version


def _version_from_header(firmware_dir: Path) -> str:
    header = (firmware_dir / "lib/acab_core/acab_version.h").read_text(
        encoding="utf-8", errors="replace"
    )
    match = re.search(r'#define\s+ACAB_FW_VERSION\s+"([^"\r\n]+)"', header)
    if not match:
        raise ReleaseToolError("could not read ACAB_FW_VERSION from acab_version.h")
    return require_ota_packable_version(match.group(1), "acab_version.h")


def _platformio_define_value(raw: str) -> str:
    """Remove only balanced quoting wrappers from one PlatformIO build-flag value."""
    value = raw
    wrappers = ((r'\"', r'\"'), ('"', '"'), ("'", "'"))
    while True:
        for opening, closing in wrappers:
            if len(value) >= len(opening) + len(closing) and value.startswith(opening) and value.endswith(closing):
                value = value[len(opening):-len(closing)]
                break
        else:
            return value


def declared_versions(firmware_dir: Union[os.PathLike, str]) -> Tuple[str, str]:
    """Return the shared S3 version and the beacon-board override."""
    root = Path(firmware_dir)
    shared = _version_from_header(root)
    ini = (root / "platformio.ini").read_text(encoding="utf-8", errors="replace")
    section_match = re.search(
        r"(?ms)^\[env:beacon-board\]\s*$\n(?P<body>.*?)(?=^\[|\Z)", ini
    )
    if not section_match:
        raise ReleaseToolError("platformio.ini has no [env:beacon-board] section")
    # Capture the WHOLE non-whitespace build-flag value, then unwrap only balanced quoting.
    # Stopping at the first backslash/quote accepted a valid prefix of an invalid or unterminated
    # value (for example ``2.0.6\\garbage``), defeating the full-match validator below.
    version_match = re.search(r'-DACAB_FW_VERSION=([^\s;#]+)', section_match.group("body"))
    # The beacon board carries its OWN version here, and it is the one the OTA gate on shipping
    # hardware compares, so it needs the same bound as the header default above.
    beacon = (
        require_ota_packable_version(
            _platformio_define_value(version_match.group(1)),
            "platformio.ini [env:beacon-board]",
        )
        if version_match
        else shared
    )
    return shared, beacon


def _ota_version_core(version: str) -> Tuple[int, int, int]:
    """Return the three fields acabOtaVersionPack packs, absent trailing fields as 0.

    The packer (firmware/lib/acab_core/ota_policy.h) starts every field at 0 and stops at the
    first non-digit, so "2.0" and "2.0.0" order the same here as they do on the board and a
    dash suffix is ignored the same way.
    """
    match = OTA_VERSION_RE.fullmatch(version)
    if not match:
        raise ReleaseToolError(f"{version!r} is not an OTA-packable version")
    fields = [int(field) for field in match.group("core").split(".")] + [0, 0]
    return fields[0], fields[1], fields[2]


def ota_rotation_for_versions(shared_version: str, beacon_version: str) -> Optional[dict]:
    """Return OTA_ROTATION when the declared versions ARE its transition cut, else None.

    Both declared versions must name the rotation release: the shared version labels the Colonel
    Panic images and the beacon override labels the beacon images, one signing key on the release
    machine signs all of them, and ota_pubkey.h is shared source that stales every product at once.
    A declaration whose release either declared version has moved past is stale and raises: the
    window is one release by contract, and a leftover declaration would misdescribe the next
    rotation. A declaration for a release the source has not reached yet is simply inactive.
    """
    rotation = OTA_ROTATION
    if rotation is None:
        return None
    release = require_ota_packable_version(str(rotation["release"]), "release_tools.OTA_ROTATION")
    declared = (
        ("acab_version.h", shared_version),
        ("platformio.ini [env:beacon-board]", beacon_version),
    )
    if all(version == release for _, version in declared):
        return rotation
    release_core = _ota_version_core(release)
    for source, version in declared:
        if _ota_version_core(version) > release_core:
            raise ReleaseToolError(
                f"release_tools.OTA_ROTATION still declares the {release} rotation cut, but "
                f"{source} declares {version!r}; every image after {release} is signed by the "
                f"new trust root alone, so delete the stale declaration"
            )
    if any(version == release for _, version in declared):
        raise ReleaseToolError(
            f"release_tools.OTA_ROTATION declares the {release} rotation cut, but acab_version.h "
            f"declares {shared_version!r} and platformio.ini [env:beacon-board] declares "
            f"{beacon_version!r}; both must declare {release} to cut the rotation"
        )
    return None


def expected_version_for_artifact(
    path: Union[os.PathLike, str], shared_version: str, beacon_version: str
) -> str:
    name = Path(path).name
    if name in {"beacon-app.bin", "beacon-revb-app.bin"}:
        return beacon_version
    return shared_version


def expected_project_for_artifact(path: Union[os.PathLike, str]) -> Optional[str]:
    """Return the exact runtime firmware label implied by a staged app filename."""
    return {
        "acab-oui-spy-app.bin": "ACAB-ouispy",
        "acab-mesh-detect-app.bin": "mesh-detect-ACAB",
        "acab-mesh-detect-ch1-app.bin": "mesh-detect-ACAB-ch1",
        "beacon-app.bin": "beacon board",
        "beacon-revb-app.bin": "beacon board rev-B",
    }.get(Path(path).name)


def release_profile(value: Union[os.PathLike, str]) -> Optional[str]:
    """Return the independently releasable artifact family for a file or manifest label."""
    text = os.fspath(value)
    name = Path(text).name
    if name.startswith("beacon-") or text in {"beacon board", "beacon board rev-B"}:
        return "beacon"
    if name.startswith("acab-") or text in {
        "ACAB-ouispy", "mesh-detect-ACAB", "mesh-detect-ACAB-ch1"
    }:
        return "colonel-panic"
    return None


T = TypeVar("T")


def filter_release_profile(values: Iterable[T], profile: str, key=lambda value: value) -> List[T]:
    """Filter artifacts/build entries without letting one release fail on another family."""
    if profile == "all":
        return list(values)
    return [value for value in values if release_profile(key(value)) == profile]
