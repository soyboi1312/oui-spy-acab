"""PlatformIO post-build action: stamp ACAB identity into the ESP app descriptor.

Arduino's prebuilt ESP-IDF archive carries its framework build string in app_desc.version. The OTA
anti-rollback check needs the product version and revision label inside the signed binary instead.
The rewrite repairs both the ROM checksum and appended SHA-256 digest.
"""
from pathlib import Path
import hashlib
import re
import sys

Import("env")  # type: ignore[name-defined]  # supplied by PlatformIO/SCons


FW_ROOT = Path(env["PROJECT_DIR"])


def build_define(name: str):
    parsed = env.ParseFlags(env.get("BUILD_FLAGS", ""))
    for define in parsed.get("CPPDEFINES", []):
        if not isinstance(define, (list, tuple)) or len(define) != 2 or define[0] != name:
            continue
        value = str(define[1]).strip()
        while len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        return value.replace(r'\"', '"')
    return None


def declared_version() -> str:
    value = build_define("ACAB_FW_VERSION")
    if value:
        match = re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value)
        if not match:
            raise RuntimeError(f"invalid ACAB_FW_VERSION {value!r}")
        return value
    header = (FW_ROOT / "lib/acab_core/acab_version.h").read_text(encoding="utf-8")
    match = re.search(r'#define\s+ACAB_FW_VERSION\s+"([0-9]+\.[0-9]+\.[0-9]+)"', header)
    if not match:
        raise RuntimeError("ACAB_FW_VERSION is not declared")
    return match.group(1)


def declared_label() -> str:
    value = build_define("ACAB_FW_LABEL")
    if value:
        return value
    pio_env = str(env.get("PIOENV", ""))
    if pio_env == "oui-spy":
        return "ACAB-ouispy"
    if pio_env == "mesh-detect":
        return "mesh-detect-ACAB"
    if pio_env == "mesh-detect-ch1":
        return "mesh-detect-ACAB-ch1"
    if pio_env.startswith("beacon-board"):
        return "beacon board"
    return pio_env or "ACAB firmware"


def fixed_field(value: str, size: int, name: str) -> bytes:
    encoded = value.encode("ascii")
    if len(encoded) >= size:
        raise RuntimeError(f"{name} does not fit the {size}-byte app descriptor field")
    return encoded + bytes(size - len(encoded))


def stamp_app_desc(source, target, env):
    esptool_dir = env.PioPlatform().get_package_dir("tool-esptoolpy")
    if not esptool_dir:
        raise RuntimeError("PlatformIO tool-esptoolpy package is unavailable")
    if esptool_dir not in sys.path:
        sys.path.insert(0, esptool_dir)
    try:
        from esptool.bin_image import LoadFirmwareImage
    except ModuleNotFoundError:
        # esptool's import chain pulls in intelhex, which PlatformIO's python does not ship
        # (the subprocess esptool that builds the image runs in a different interpreter that
        # has it; THIS import runs inside SCons). Broke every env on a fresh CI runner, and
        # the same gap has bitten fresh Macs before. Install into the running interpreter
        # once and retry; self-heals any environment instead of patching one CI workflow.
        import subprocess
        # pyserial rides along: PlatformIO's own python has it, but a bare interpreter does not,
        # and esptool imports serial right after intelhex (proven in a clean-venv replay).
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "intelhex", "pyserial"])
        from esptool.bin_image import LoadFirmwareImage

    image_path = Path(str(target[0]))
    image = LoadFirmwareImage("esp32s3", str(image_path))
    magic = bytes.fromhex("3254cdab")
    app_segments = [segment for segment in image.segments if segment.data[:4] == magic]
    if len(app_segments) != 1:
        raise RuntimeError(f"expected one ESP app descriptor segment, found {len(app_segments)}")

    version_text = declared_version()
    label_text = declared_label()
    version = fixed_field(version_text, 32, "ACAB_FW_VERSION")
    label = fixed_field(label_text, 32, "firmware label")
    segment = app_segments[0]
    data = bytearray(segment.data)
    data[16:48] = version
    data[48:80] = label
    segment.data = bytes(data)

    # Loaded ImageSegment.file_offs points at its 8-byte segment header. Patch the existing image
    # in place so the ELF-derived segment layout stays byte-for-byte stable, then repair the ROM
    # checksum and the optional appended image digest.
    raw = bytearray(image_path.read_bytes())
    data_offset = segment.file_offs + image.SEG_HEADER_LEN
    raw[data_offset + 16 : data_offset + 48] = version
    raw[data_offset + 48 : data_offset + 80] = label
    segment_end = max(s.file_offs + image.SEG_HEADER_LEN + len(s.data) for s in image.segments)
    checksum_offset = segment_end + (15 - (segment_end % 16))
    image_length = checksum_offset + 1
    raw[checksum_offset] = image.calculate_checksum()
    if image.append_digest:
        raw[image_length : image_length + image.SHA256_DIGEST_LEN] = hashlib.sha256(
            raw[:image_length]
        ).digest()
    image_path.write_bytes(raw)

    # Re-open through esptool. This validates the checksum and appended digest after the rewrite.
    verified = LoadFirmwareImage("esp32s3", str(image_path))
    verified_app = next(s for s in verified.segments if s.data[:4] == magic).data
    if verified_app[16:48] != version or verified_app[48:80] != label:
        raise RuntimeError("ESP app descriptor stamp did not survive image rewrite")
    if verified.checksum != verified.calculate_checksum():
        raise RuntimeError("ESP image checksum is invalid after app descriptor stamp")
    if verified.append_digest and verified.stored_digest != verified.calc_digest:
        raise RuntimeError("ESP image digest is invalid after app descriptor stamp")
    print(
        f"Stamped esp_app_desc.version={version_text} project_name={label_text!r} "
        f"in {image_path.name}"
    )


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", stamp_app_desc)
