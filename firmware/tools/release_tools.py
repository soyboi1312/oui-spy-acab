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
ESP_APP_DESC_OFFSET = 24 + 8
ESP_APP_VERSION_OFFSET = ESP_APP_DESC_OFFSET + 16
ESP_APP_PROJECT_OFFSET = ESP_APP_VERSION_OFFSET + 32
ESP_APP_TEXT_FIELD_SIZE = 32


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


def _version_from_header(firmware_dir: Path) -> str:
    header = (firmware_dir / "lib/acab_core/acab_version.h").read_text(
        encoding="utf-8", errors="replace"
    )
    match = re.search(r'#define\s+ACAB_FW_VERSION\s+"([0-9][0-9A-Za-z.+-]*)"', header)
    if not match:
        raise ReleaseToolError("could not read ACAB_FW_VERSION from acab_version.h")
    return match.group(1)


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
    version_match = re.search(
        r'-DACAB_FW_VERSION=(?:\\?"|\'"|"\')*([0-9][0-9A-Za-z.+-]*)',
        section_match.group("body"),
    )
    beacon = version_match.group(1) if version_match else shared
    return shared, beacon


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
