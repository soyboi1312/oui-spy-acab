#!/usr/bin/env python3

from pathlib import Path
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shlex
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.fspath(TOOLS))

import release_tools  # noqa: E402
from release_tools import (  # noqa: E402
    ESP_APP_DESC_MAGIC,
    ESP_APP_DESC_OFFSET,
    ESP_APP_PROJECT_OFFSET,
    ESP_APP_VERSION_OFFSET,
    ESP_IMAGE_MAGIC,
    OTA_VERSION_FIELD_MAX,
    ReleaseToolError,
    declared_versions,
    dirty_tree_digest,
    expected_project_for_artifact,
    filter_release_profile,
    ota_rotation_for_versions,
    parse_esp_app_desc,
    read_baked_ota_public_key_der,
    read_esp_app_desc,
    read_nrf_source_version,
    require_ota_packable_version,
    require_manifest_image_identity,
    require_manifest_builds,
    require_ota_firmware_url,
    require_ota_signing_key_identity,
    require_usb_only_manifest_build,
    read_nrf_dfu_application_version,
    release_profile,
)
from stage_beacon_revb import (  # noqa: E402
    REV_B_FILES,
    REV_B_LABEL,
    ReleaseToolError as StageError,
    check_site_contract,
    stage_rev_b,
)


def load_verifier():
    """Import verify-release-artifacts.py, whose filename is not a Python identifier.

    Importing it is side-effect-free: everything below the constants is a def, and main() runs only
    under __main__.
    """
    spec = importlib.util.spec_from_file_location(
        "verify_release_artifacts", TOOLS / "verify-release-artifacts.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", os.fspath(repo), *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_image(version: str = "2.0.4", project: str = "beacon board rev-B") -> bytes:
    data = bytearray(256)
    data[0] = ESP_IMAGE_MAGIC
    struct.pack_into("<I", data, ESP_APP_DESC_OFFSET, ESP_APP_DESC_MAGIC)
    data[ESP_APP_VERSION_OFFSET:ESP_APP_VERSION_OFFSET + len(version)] = version.encode("ascii")
    data[ESP_APP_PROJECT_OFFSET:ESP_APP_PROJECT_OFFSET + len(project)] = project.encode("ascii")
    return bytes(data)


def write_ota_public_key_header(path: Path, der: bytes) -> None:
    values = ", ".join(f"0x{value:02x}" for value in der)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"static const unsigned char ACAB_OTA_PUBKEY_DER[] = {{{values}}};\n",
        encoding="utf-8",
    )


def generate_p256_key(key: Path) -> bytes:
    """Write a throwaway P-256 private key and return its SubjectPublicKeyInfo DER."""
    subprocess.run(
        ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    result = subprocess.run(
        ["openssl", "pkey", "-in", key, "-pubout", "-outform", "DER"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    return result.stdout


def declare_versions(firmware: Path, shared: str, beacon: str) -> None:
    """Write the two version sources declared_versions reads, in the shapes the real tree uses."""
    (firmware / "lib/acab_core").mkdir(parents=True, exist_ok=True)
    (firmware / "lib/acab_core/acab_version.h").write_text(
        f'#define ACAB_FW_VERSION "{shared}"\n', encoding="utf-8"
    )
    (firmware / "platformio.ini").write_text(
        f'[env:beacon-board]\nbuild_flags = -DACAB_FW_VERSION=\\"{beacon}\\"\n',
        encoding="utf-8",
    )


class OtaSigningKeyIdentityTests(unittest.TestCase):
    """The signer must be the baked root, except in the ONE declared rotation cut.

    In that cut the header bakes the NEW root and the RETIRING key signs, because a fielded board
    accepts only an image signed by the root it already runs. Every other pairing in that release,
    and the rotation pairing in any other release, fails closed.
    """

    ROTATION_REFUSED = "must bake the new trust root .* and be signed by the retiring key"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.retiring_key = root / "retiring.pem"
        self.new_key = root / "new.pem"
        self.retiring_der = generate_p256_key(self.retiring_key)
        self.new_der = generate_p256_key(self.new_key)
        self.firmware = root / "firmware"
        self.header = self.firmware / "lib/acab_core/ota_pubkey.h"
        self.rotation = {
            "release": "2.0.7",
            "trust_root_sha256": hashlib.sha256(self.new_der).hexdigest(),
            "signer_sha256": hashlib.sha256(self.retiring_der).hexdigest(),
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def rotation_declared(self, value):
        return mock.patch.object(release_tools, "OTA_ROTATION", value)

    def test_private_key_must_match_the_baked_public_der(self) -> None:
        # No rotation in progress: the plain rule, and no firmware tree is needed around the header.
        header = Path(self.temp.name) / "ota_pubkey.h"
        write_ota_public_key_header(header, self.retiring_der)
        with self.rotation_declared(None):
            self.assertIsNone(ota_rotation_for_versions("2.0.7", "2.0.7"))
            self.assertEqual(read_baked_ota_public_key_der(header), self.retiring_der)
            self.assertEqual(
                require_ota_signing_key_identity(self.retiring_key, header),
                hashlib.sha256(self.retiring_der).hexdigest(),
            )
            with self.assertRaisesRegex(ReleaseToolError, "does not match the OTA trust root"):
                require_ota_signing_key_identity(self.new_key, header)

    def test_rotation_cut_bakes_the_new_root_and_is_signed_by_the_retiring_key(self) -> None:
        declare_versions(self.firmware, "2.0.7", "2.0.7")
        write_ota_public_key_header(self.header, self.new_der)
        with self.rotation_declared(self.rotation):
            self.assertIs(ota_rotation_for_versions("2.0.7", "2.0.7"), self.rotation)
            self.assertEqual(
                require_ota_signing_key_identity(self.retiring_key, self.header),
                self.rotation["trust_root_sha256"],
            )

    def test_rotation_cut_refuses_a_header_that_was_not_rotated(self) -> None:
        declare_versions(self.firmware, "2.0.7", "2.0.7")
        write_ota_public_key_header(self.header, self.retiring_der)
        with self.rotation_declared(self.rotation), self.assertRaisesRegex(
            ReleaseToolError, self.ROTATION_REFUSED
        ):
            require_ota_signing_key_identity(self.retiring_key, self.header)

    def test_rotation_cut_refuses_the_new_key_as_signer(self) -> None:
        declare_versions(self.firmware, "2.0.7", "2.0.7")
        write_ota_public_key_header(self.header, self.new_der)
        with self.rotation_declared(self.rotation), self.assertRaisesRegex(
            ReleaseToolError, self.ROTATION_REFUSED
        ):
            require_ota_signing_key_identity(self.new_key, self.header)

    def test_versions_outside_the_window_keep_the_plain_rule(self) -> None:
        # Declared for 2.0.7 while the tree still says 2.0.6: inactive, so signer == baked root.
        declare_versions(self.firmware, "2.0.6", "2.0.6")
        write_ota_public_key_header(self.header, self.retiring_der)
        with self.rotation_declared(self.rotation):
            self.assertIsNone(ota_rotation_for_versions("2.0.6", "2.0.6"))
            self.assertEqual(
                require_ota_signing_key_identity(self.retiring_key, self.header),
                self.rotation["signer_sha256"],
            )
            with self.assertRaisesRegex(ReleaseToolError, "does not match the OTA trust root"):
                require_ota_signing_key_identity(self.new_key, self.header)
        # The pairing the window admits is refused outside it.
        write_ota_public_key_header(self.header, self.new_der)
        with self.rotation_declared(self.rotation), self.assertRaisesRegex(
            ReleaseToolError, "does not match the OTA trust root"
        ):
            require_ota_signing_key_identity(self.retiring_key, self.header)

    def test_rotation_cut_needs_both_declared_versions(self) -> None:
        declare_versions(self.firmware, "2.0.7", "2.0.6")
        write_ota_public_key_header(self.header, self.new_der)
        with self.rotation_declared(self.rotation), self.assertRaisesRegex(
            ReleaseToolError, "both must declare 2.0.7"
        ):
            require_ota_signing_key_identity(self.retiring_key, self.header)

    def test_stale_rotation_declaration_is_refused(self) -> None:
        # The new key over the new root would pass the plain rule; the leftover declaration is
        # what fails, on either declared version having moved past the rotation release.
        write_ota_public_key_header(self.header, self.new_der)
        for shared, beacon in (("2.0.8", "2.0.8"), ("2.0.7", "2.0.8"), ("2.1", "2.1")):
            with self.subTest(shared=shared, beacon=beacon):
                declare_versions(self.firmware, shared, beacon)
                with self.rotation_declared(self.rotation), self.assertRaisesRegex(
                    ReleaseToolError, "delete the stale declaration"
                ):
                    require_ota_signing_key_identity(self.new_key, self.header)

    def test_a_declared_rotation_cannot_be_placed_without_the_declared_versions(self) -> None:
        # A header with no firmware tree around it fails closed instead of falling back to the
        # plain rule, and as ReleaseToolError, which is what every caller catches.
        header = Path(self.temp.name) / "ota_pubkey.h"
        write_ota_public_key_header(header, self.new_der)
        with self.rotation_declared(self.rotation), self.assertRaisesRegex(
            ReleaseToolError, "cannot read the declared versions"
        ):
            require_ota_signing_key_identity(self.retiring_key, header)


class VerifierOtaKeyIdentityTests(unittest.TestCase):
    """check_ota_key_identity: the recorded root, the pub file, and the DER inside every image."""

    def setUp(self) -> None:
        self.verifier = load_verifier()
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.repo = root / "all-cameras-are-beacons"
        self.firmware = self.repo / "firmware"
        (self.firmware / "tools/ota_signing").mkdir(parents=True)
        self.retiring_key = root / "retiring.pem"
        self.new_key = root / "new.pem"
        self.retiring_der = generate_p256_key(self.retiring_key)
        self.new_der = generate_p256_key(self.new_key)
        write_ota_public_key_header(self.firmware / "lib/acab_core/ota_pubkey.h", self.new_der)
        images = root / "images"
        images.mkdir()
        self.fresh = images / "beacon-app.bin"
        self.fresh.write_bytes(make_image() + self.new_der + b"tail")
        self.stale = images / "acab-oui-spy-app.bin"
        self.stale.write_bytes(make_image() + self.retiring_der + b"tail")
        self.rotation = {
            "release": "2.0.7",
            "trust_root_sha256": hashlib.sha256(self.new_der).hexdigest(),
            "signer_sha256": hashlib.sha256(self.retiring_der).hexdigest(),
        }
        for name, value in (
            ("FW", os.fspath(self.firmware)),
            ("REPO", os.fspath(self.repo)),
            ("INTENDED_OTA_KEY_SHA256", self.rotation["trust_root_sha256"]),
        ):
            patcher = mock.patch.object(self.verifier, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def install_pub(self, key: Path) -> None:
        subprocess.run(
            ["openssl", "pkey", "-in", key, "-pubout", "-out",
             self.firmware / "tools/ota_signing/beacon_ota_pub.pem"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def run_check(self, shared: str, beacon: str, images, rotation):
        """The FAIL messages and printed output of one identity check, output swallowed."""
        module = self.verifier
        module.OK.clear()
        module.FAIL.clear()
        out = io.StringIO()
        with mock.patch.object(release_tools, "OTA_ROTATION", rotation), \
                contextlib.redirect_stdout(out):
            module.check_ota_key_identity(shared, beacon, [os.fspath(p) for p in images])
        return list(module.FAIL), out.getvalue()

    def test_rotation_cut_accepts_the_retiring_pub_file_and_says_so(self) -> None:
        self.install_pub(self.retiring_key)
        failures, out = self.run_check("2.0.7", "2.0.7", [self.fresh], self.rotation)
        self.assertEqual(failures, [], out)
        self.assertIn("ROTATION CUT 2.0.7", out)
        self.assertIn(self.rotation["trust_root_sha256"][:12], out)
        self.assertIn(self.rotation["signer_sha256"][:12], out)

    def test_rotation_cut_refuses_the_new_key_as_pub_file(self) -> None:
        # Inside the window the signatures are made by the RETIRING key, so a pub file holding the
        # new key would verify nothing the cut actually ships; the row must fail, not pass by
        # matching the recorded root.
        self.install_pub(self.new_key)
        failures, out = self.run_check("2.0.7", "2.0.7", [self.fresh], self.rotation)
        self.assertTrue(any("is the retiring" in m and "rotation cut" in m for m in failures), out)
        self.assertIn("ROTATION CUT 2.0.7", out)

    def test_an_image_without_the_baked_root_fails_even_in_the_rotation_cut(self) -> None:
        self.install_pub(self.retiring_key)
        failures, out = self.run_check(
            "2.0.7", "2.0.7", [self.fresh, self.stale], self.rotation
        )
        self.assertTrue(any("acab-oui-spy-app.bin bakes" in m for m in failures), out)
        self.assertFalse(any("beacon-app.bin bakes" in m for m in failures), out)

    def test_outside_the_window_the_pub_file_must_be_the_recorded_root(self) -> None:
        self.install_pub(self.retiring_key)
        failures, out = self.run_check("2.0.8", "2.0.8", [self.fresh], None)
        self.assertTrue(any("same key the boards bake in" in m for m in failures), out)
        self.assertNotIn("ROTATION CUT", out)
        self.install_pub(self.new_key)
        failures, out = self.run_check("2.0.8", "2.0.8", [self.fresh], None)
        self.assertEqual(failures, [], out)

    def test_a_stale_declaration_is_a_failure_not_a_skip(self) -> None:
        self.install_pub(self.new_key)
        failures, out = self.run_check("2.0.8", "2.0.8", [self.fresh], self.rotation)
        self.assertTrue(any("delete the stale declaration" in m for m in failures), out)

    def test_the_declared_new_root_must_be_the_recorded_fingerprint(self) -> None:
        self.install_pub(self.retiring_key)
        wrong = dict(self.rotation, trust_root_sha256=hashlib.sha256(b"other").hexdigest())
        failures, out = self.run_check("2.0.7", "2.0.7", [self.fresh], wrong)
        self.assertTrue(
            any("recorded release fingerprint as its new trust root" in m for m in failures), out
        )


class DirtyTreeDigestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "release test")
        git(self.repo, "config", "user.email", "release@test.invalid")
        (self.repo / "tracked.txt").write_text("base\n", encoding="utf-8")
        git(self.repo, "add", "tracked.txt")
        git(self.repo, "commit", "-qm", "base")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_clean_tree_has_no_digest(self) -> None:
        self.assertIsNone(dirty_tree_digest(self.repo))

    def test_same_status_different_tracked_bytes_change_digest(self) -> None:
        (self.repo / "tracked.txt").write_text("first dirty value\n", encoding="utf-8")
        first = dirty_tree_digest(self.repo)
        (self.repo / "tracked.txt").write_text("second dirty value\n", encoding="utf-8")
        second = dirty_tree_digest(self.repo)
        self.assertNotEqual(first, second)

    def test_index_location_does_not_change_final_content_digest(self) -> None:
        (self.repo / "tracked.txt").write_text("same final bytes\n", encoding="utf-8")
        unstaged = dirty_tree_digest(self.repo)
        git(self.repo, "add", "tracked.txt")
        staged = dirty_tree_digest(self.repo)
        self.assertEqual(unstaged, staged)

    def test_untracked_path_and_bytes_are_both_authenticated(self) -> None:
        extra = self.repo / "new.bin"
        extra.write_bytes(b"one\x00")
        one = dirty_tree_digest(self.repo)
        extra.write_bytes(b"two\x00")
        two = dirty_tree_digest(self.repo)
        extra.rename(self.repo / "renamed.bin")
        renamed = dirty_tree_digest(self.repo)
        self.assertNotEqual(one, two)
        self.assertNotEqual(two, renamed)


class EspAppDescriptorTests(unittest.TestCase):
    def test_reads_raw_descriptor_version_and_project(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.bin"
            path.write_bytes(make_image())
            self.assertEqual(read_esp_app_desc(path), ("2.0.4", "beacon board rev-B"))
            self.assertEqual(parse_esp_app_desc(path.read_bytes()),
                             ("2.0.4", "beacon board rev-B"))

    def test_rejects_bad_descriptor_magic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.bin"
            data = bytearray(make_image())
            data[ESP_APP_DESC_OFFSET] ^= 0xFF
            path.write_bytes(data)
            with self.assertRaises(ReleaseToolError):
                read_esp_app_desc(path)

    def test_artifact_names_map_to_exact_runtime_labels(self) -> None:
        self.assertEqual(expected_project_for_artifact("beacon-app.bin"), "beacon board")
        self.assertEqual(
            expected_project_for_artifact("beacon-revb-app.bin"), "beacon board rev-B"
        )
        self.assertEqual(
            expected_project_for_artifact("acab-mesh-detect-ch1-app.bin"),
            "mesh-detect-ACAB-ch1",
        )

    def test_manifest_identity_is_bound_to_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.bin"
            path.write_bytes(make_image(version="2.0.4", project="beacon board rev-B"))
            self.assertEqual(
                require_manifest_image_identity(path, "beacon board rev-B", "2.0.4"),
                ("2.0.4", "beacon board rev-B"),
            )
            with self.assertRaises(ReleaseToolError):
                require_manifest_image_identity(path, "beacon board", "2.0.4")
            with self.assertRaises(ReleaseToolError):
                require_manifest_image_identity(path, "beacon board rev-B", "2.0.5")

    def test_nrf_package_version_is_read_from_inner_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nrf.zip"
            def init_packet(version: int) -> bytes:
                return struct.pack("<HHIHHH", 82, 0xFFFF, version, 1, 0xFFFE, 0)

            payload = {"manifest": {"application": {"init_packet_data": {
                "application_version": 7,
            }, "bin_file": "firmware.bin", "dat_file": "firmware.dat"}}}
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(payload))
                archive.writestr("firmware.bin", b"app")
                archive.writestr("firmware.dat", init_packet(7))
            self.assertEqual(read_nrf_dfu_application_version(path), 7)

            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(payload))
                archive.writestr("firmware.bin", b"app")
                archive.writestr("firmware.dat", init_packet(8))
            with self.assertRaises(ReleaseToolError):
                read_nrf_dfu_application_version(path)

            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps({"manifest": {}}))
            with self.assertRaises(ReleaseToolError):
                read_nrf_dfu_application_version(path)

            payload["manifest"]["bootloader"] = {}
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(payload))
                archive.writestr("firmware.bin", b"app")
                archive.writestr("firmware.dat", init_packet(7))
            with self.assertRaises(ReleaseToolError):
                read_nrf_dfu_application_version(path)

    def test_release_profiles_isolate_beacon_and_colonel_panic_artifacts(self) -> None:
        artifacts = ["/tmp/beacon-app.bin", "/tmp/beacon-revb-app.bin",
                     "/tmp/acab-oui-spy-app.bin", "/tmp/acab-mesh-detect-app.bin"]
        self.assertEqual(release_profile("beacon board rev-B"), "beacon")
        self.assertEqual(release_profile("mesh-detect-ACAB"), "colonel-panic")
        self.assertEqual(filter_release_profile(artifacts, "beacon"), artifacts[:2])
        self.assertEqual(filter_release_profile(artifacts, "colonel-panic"), artifacts[2:])
        self.assertEqual(filter_release_profile(artifacts, "all"), artifacts)


class OtaVersionBoundTests(unittest.TestCase):
    """The release label must mean the same thing to tooling, firmware, Android, and iOS."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.firmware = Path(self.temp.name) / "firmware"
        (self.firmware / "lib/acab_core").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def declare(self, header: str, beacon: str) -> None:
        (self.firmware / "lib/acab_core/acab_version.h").write_text(
            f'#define ACAB_FW_VERSION "{header}"\n', encoding="utf-8"
        )
        (self.firmware / "platformio.ini").write_text(
            f'[env:beacon-board]\nbuild_flags = -DACAB_FW_VERSION=\\"{beacon}\\"\n',
            encoding="utf-8",
        )

    def test_the_widest_installable_field_is_still_accepted(self) -> None:
        self.assertEqual(OTA_VERSION_FIELD_MAX, 1023)
        self.declare("2.0.1023", "2.0.1023")
        self.assertEqual(declared_versions(self.firmware), ("2.0.1023", "2.0.1023"))

    def test_a_suffix_is_ignored_exactly_as_the_packer_ignores_it(self) -> None:
        self.declare("2.0.6-rc1", "2.0.6")
        self.assertEqual(declared_versions(self.firmware)[0], "2.0.6-rc1")

    def test_one_to_three_numeric_fields_are_accepted(self) -> None:
        for version in ("2", "2.0", "2.0.6", "2.0.6-rc.1", "2.0.6-" + "r" * 25):
            with self.subTest(version=version):
                self.assertEqual(require_ota_packable_version(version, "test"), version)

    def test_complete_incompatible_spellings_are_refused(self) -> None:
        for version in (
            "", "2..6", "2.0.x", "2.0.6+meta", "2.0.6.1", "2.0.6-",
            "-2.0.6", "2.0.6_rc1", "2.0.6-rc+meta", "0", "0.0", "0.0.0",
            "2.0.6-" + "r" * 26,
        ):
            with self.subTest(version=version), self.assertRaises(ReleaseToolError):
                require_ota_packable_version(version, "test")

    def test_header_parser_does_not_accept_a_valid_prefix_of_an_invalid_label(self) -> None:
        self.declare("2.0.6_bad", "2.0.6")
        with self.assertRaises(ReleaseToolError):
            declared_versions(self.firmware)

    def test_beacon_parser_does_not_accept_a_valid_prefix_of_an_invalid_label(self) -> None:
        self.declare("2.0.6", "2.0.6+meta")
        with self.assertRaises(ReleaseToolError):
            declared_versions(self.firmware)

    def test_beacon_parser_rejects_unbalanced_or_trailing_escape_content(self) -> None:
        for raw in (r"2.0.6\\garbage", r'\\"2.0.6\\garbage\\"', r'\\"2.0.6'):
            with self.subTest(raw=raw):
                self.declare("2.0.6", raw)
                with self.assertRaises(ReleaseToolError):
                    declared_versions(self.firmware)

    def test_header_field_past_the_bound_is_refused(self) -> None:
        self.declare("2.0.1024", "2.0.6")
        with self.assertRaises(ReleaseToolError):
            declared_versions(self.firmware)

    def test_beacon_override_past_the_bound_is_refused(self) -> None:
        # The override is the version SHIPPING hardware compares, so it needs its own case: the
        # header can be perfectly in bounds while platformio.ini is not.
        self.declare("2.0.6", "2.0.1024")
        with self.assertRaises(ReleaseToolError):
            declared_versions(self.firmware)


class ReleaseManifestContractTests(unittest.TestCase):
    def test_usb_only_manifest_forbids_every_app_delivered_update(self) -> None:
        valid = {"ota": False, "app": {"sig": ""}}
        self.assertIs(require_usb_only_manifest_build(valid, "test"), valid)
        for invalid in (
            {"ota": True, "app": {"sig": ""}},
            {"ota": False, "app": {"sig": "3044"}},
            {"ota": False, "app": {"sig": ""}, "nrf": {}},
            {"app": {"sig": ""}},
        ):
            with self.subTest(build=invalid), self.assertRaises(ReleaseToolError):
                require_usb_only_manifest_build(invalid, "test")

    def test_profile_required_build_keys_cannot_be_skipped(self) -> None:
        required = ("ACAB-ouispy", "mesh-detect-ACAB", "mesh-detect-ACAB-ch1")
        verifier = load_verifier()
        self.assertEqual(tuple(verifier.required_ota_labels("colonel-panic")), required)
        self.assertEqual(set(verifier.required_ota_labels("all")),
                         set(required) | {"beacon board", "beacon board rev-B"})
        manifest = {"schema": 1, "builds": {label: {"app": {}} for label in required}}
        self.assertEqual(set(require_manifest_builds(manifest, required, "test")), set(required))
        del manifest["builds"]["mesh-detect-ACAB-ch1"]
        with self.assertRaisesRegex(ReleaseToolError, "mesh-detect-ACAB-ch1"):
            require_manifest_builds(manifest, required, "test")
        with self.assertRaises(ReleaseToolError):
            require_manifest_builds({"schema": 1, "builds": []}, required, "test")

    def test_app_manifest_schema_must_be_exactly_integer_one(self) -> None:
        required = ("ACAB-ouispy", "mesh-detect-ACAB", "mesh-detect-ACAB-ch1")
        builds = {label: {"app": {}} for label in required}
        for schema in (None, True, 0, 2, "1"):
            with self.subTest(schema=schema), self.assertRaisesRegex(
                ReleaseToolError, "schema must be exactly integer 1"
            ):
                manifest = {"builds": builds}
                if schema is not None:
                    manifest["schema"] = schema
                require_manifest_builds(manifest, required, "colonel-only manifest")

    def test_ota_url_is_bound_to_exact_served_host_path(self) -> None:
        filename = "acab-oui-spy-app.bin"
        exact = "https://soyboi.tech/firmware/" + filename
        self.assertEqual(require_ota_firmware_url(exact, filename, "test"), exact)
        for wrong in (
            "https://example.invalid/firmware/" + filename,
            "https://soyboi.tech/wrong/" + filename,
            exact + "?old=1",
            exact + "#fragment",
        ):
            with self.subTest(url=wrong), self.assertRaises(ReleaseToolError):
                require_ota_firmware_url(wrong, filename, "test")

    def test_nrf_source_version_requires_one_exact_integer_define(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "main.cpp"
            source.write_text("#define NRF_APP_VERSION 7\n", encoding="utf-8")
            self.assertEqual(read_nrf_source_version(source), 7)
            for invalid in (
                "#define NRF_APP_VERSION 7garbage\n",
                "#define NRF_APP_VERSION 7\n#define NRF_APP_VERSION 8\n",
                "#define NRF_APP_VERSION 4294967296\n",
            ):
                with self.subTest(source=invalid):
                    source.write_text(invalid, encoding="utf-8")
                    with self.assertRaises(ReleaseToolError):
                        read_nrf_source_version(source)

    def test_nrf_freshness_state_tracks_newest_source_or_build_config(self) -> None:
        verifier = load_verifier()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            main = root / "src/main.cpp"
            config = root / "platformio.ini"
            main.write_text("#define NRF_APP_VERSION 9\n", encoding="utf-8")
            config.write_text("[env:test]\n", encoding="utf-8")
            os.utime(main, (100, 100))
            os.utime(config, (200, 200))
            version, mtime, newest = verifier.nrf_source_state(root)
            self.assertEqual(version, 9)
            self.assertEqual(mtime, 200)
            self.assertEqual(Path(newest), config)

            package = root / "nrf.zip"
            def write_package(package_version: int) -> None:
                payload = {"manifest": {"application": {"init_packet_data": {
                    "application_version": package_version,
                }, "bin_file": "firmware.bin", "dat_file": "firmware.dat"}}}
                init = struct.pack("<HHIHHH", 82, 0xFFFF, package_version, 1, 0xFFFE, 0)
                with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
                    archive.writestr("manifest.json", json.dumps(payload))
                    archive.writestr("firmware.bin", b"app")
                    archive.writestr("firmware.dat", init)

            write_package(9)
            os.utime(package, (300, 300))
            current = verifier.require_current_nrf_package(package, 9, root)
            self.assertEqual(current[:2], (9, 9))
            with self.assertRaisesRegex(ReleaseToolError, "not an integer"):
                verifier.require_current_nrf_package(package, True, root)
            os.utime(package, (150, 150))
            with self.assertRaisesRegex(ReleaseToolError, "older than nRF build input"):
                verifier.require_current_nrf_package(package, 9, root)
            write_package(8)
            os.utime(package, (300, 300))
            with self.assertRaisesRegex(ReleaseToolError, "NRF_APP_VERSION"):
                verifier.require_current_nrf_package(package, 8, root)

    def test_web_manifest_inventory_requires_all_three_and_no_substitutes(self) -> None:
        verifier = load_verifier()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            web = root / "web"
            web.mkdir()
            for env in verifier.WEB_MANIFEST_ENVS:
                (web / f"manifest-{env}.json").write_text("{}\n", encoding="utf-8")
            expected, actual = verifier.web_manifest_inventory(root)
            self.assertEqual(set(expected), actual)
            (web / "manifest-mesh-detect-ch1.json").unlink()
            (web / "manifest-substitute.json").write_text("{}\n", encoding="utf-8")
            expected, actual = verifier.web_manifest_inventory(root)
            self.assertNotEqual(set(expected), actual)


class UsbManifestGateTests(unittest.TestCase):
    """All three USB flash paths go through check_usb_manifest, so pin what it REFUSES.

    A gate that reports more assurance than it delivers is worse than no gate, and the rev-A and
    rev-B blocks used to check existence only: a bootloader or partition table left over from an
    older layout exists exactly as convincingly as a current one.
    """

    def setUp(self) -> None:
        self.verifier = load_verifier()
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.src_mtime = 1_000_000.0
        for name in self.verifier.REV_A_FILES.values():
            path = self.dir / name
            path.write_bytes(b"staged")
            os.utime(path, (self.src_mtime + 10, self.src_mtime + 10))
        self.parts = self.verifier.beacon_usb_parts(self.verifier.REV_A_FILES)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def failures(self, parts, version: str = "2.0.6"):
        """The gate's FAIL messages for a manifest naming `parts`, output swallowed."""
        module = self.verifier
        manifest = self.dir / module.REV_A_MANIFEST
        manifest.write_text(json.dumps({
            "version": version,
            "builds": [{"chipFamily": "ESP32-S3",
                        "parts": [{"path": p, "offset": o} for p, o in parts]}],
        }), encoding="utf-8")
        module.OK.clear()
        module.FAIL.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            module.check_usb_manifest(module.REV_A_MANIFEST, os.fspath(manifest), "2.0.6",
                                      self.parts, self.src_mtime)
        return list(module.FAIL)

    def test_a_correct_fresh_manifest_passes(self) -> None:
        self.assertEqual(self.failures(self.parts), [])
        self.assertTrue(self.verifier.OK)

    def test_a_moved_partition_offset_fails(self) -> None:
        # 36864 (0x9000) is NVS in default_8MB.csv: the BLE bond + ignore list. This is the typo
        # the offsets are compared exactly for.
        moved = [(path, 36864 if offset == 32768 else offset) for path, offset in self.parts]
        self.assertTrue(self.failures(moved))

    def test_a_cross_wired_path_fails(self) -> None:
        crossed = [("beacon-revb-app.bin" if path.endswith("-app.bin") else path, offset)
                   for path, offset in self.parts]
        self.assertTrue(self.failures(crossed))

    def test_a_part_older_than_the_newest_source_fails(self) -> None:
        stale = self.dir / self.verifier.REV_A_FILES["partitions"]
        os.utime(stale, (self.src_mtime - 10, self.src_mtime - 10))
        messages = self.failures(self.parts)
        self.assertTrue(any("staged after the last source edit" in m for m in messages))

    def test_an_absent_part_fails(self) -> None:
        (self.dir / self.verifier.REV_A_FILES["boot_app0"]).unlink()
        messages = self.failures(self.parts)
        self.assertTrue(any("not staged" in m for m in messages))

    def test_a_part_outside_the_served_directory_is_refused_not_stat_ed(self) -> None:
        escaping = [("../" + path, offset) for path, offset in self.parts]
        messages = self.failures(escaping)
        self.assertTrue(any("outside its own directory" in m for m in messages))

    def test_a_stale_version_string_fails(self) -> None:
        self.assertTrue(self.failures(self.parts, version="2.0.5"))

    def test_both_beacon_revisions_use_the_same_offsets(self) -> None:
        from stage_beacon_revb import REV_B_FILES as revb  # noqa: PLC0415
        self.assertEqual([offset for _, offset in self.parts],
                         [offset for _, offset in self.verifier.beacon_usb_parts(revb)])
        self.assertEqual([offset for _, offset in self.parts],
                         list(self.verifier.USB_PART_OFFSETS))


class ReleaseOrchestratorContractTests(unittest.TestCase):
    def test_app_release_regenerates_ignored_xcode_project(self) -> None:
        script = (TOOLS / "release.sh").read_text(encoding="utf-8")
        self.assertIn("command -v xcodegen", script)
        self.assertLess(script.index("xcodegen generate"), script.index("xcodebuild -project"))

    def test_release_delegates_both_beacon_revisions_to_one_transaction(self) -> None:
        script = (TOOLS / "release.sh").read_text(encoding="utf-8")
        self.assertNotIn("REV_B_ARGS", script)
        self.assertNotIn("pio run -e beacon-board-revb", script)
        self.assertIn("sibling beacon stager owns rev-A, rev-B", script)

    def test_nrf_packager_binds_inner_application_version(self) -> None:
        stager = (TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh")
        if not stager.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")
        script = stager.read_text(encoding="utf-8")
        self.assertIn('--application-version "$NRF_VER"', script)

    def test_beacon_rev_a_signature_and_served_copy_use_one_frozen_payload(self) -> None:
        stager = TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh"
        if not stager.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")
        script = stager.read_text(encoding="utf-8")
        frozen = '"$REV_A_PAYLOAD_DIR/firmware.bin"'
        self.assertIn(f'openssl dgst -sha256 -passin pass: -sign "$OTA_KEY" \\\n      {frozen}', script)
        self.assertIn(f'cp {frozen}   "$HERE/beacon-app.bin"', script)
        self.assertEqual(script.count('"$B/firmware.bin"'), 1)

    def test_colonel_stager_aborts_on_missing_ota_build_instead_of_skipping_it(self) -> None:
        script = (TOOLS.parents[1] / "web/build-flasher.sh").read_text(encoding="utf-8")
        self.assertIn("require_manifest_builds(manifest, required, manifest_path)", script)
        self.assertLess(
            script.index("require_manifest_builds(manifest, required, manifest_path)"),
            script.index("for BN in acab-oui-spy-app.bin"),
        )
        self.assertIn('b = m["builds"][label]', script)
        self.assertNotIn("if not b or not os.path.exists(p):\n        continue", script)

    def test_explicit_usb_only_mode_is_forced_and_forwarded(self) -> None:
        release = (TOOLS / "release.sh").read_text(encoding="utf-8")
        web = (TOOLS.parents[1] / "web/build-flasher.sh").read_text(encoding="utf-8")
        self.assertIn("./build-beacon-flasher.sh --unsigned-usb-only", release)
        self.assertIn('if [ "$UNSIGNED_OK" = "1" ]; then return 0; fi', web)
        sibling = TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh"
        if sibling.is_file():
            sibling_text = sibling.read_text(encoding="utf-8")
            self.assertIn("--unsigned-usb-only) UNSIGNED_OK=1", sibling_text)
            self.assertIn('if [ "$UNSIGNED_OK" = "1" ]; then', sibling_text)

    def test_beacon_stager_never_falls_back_to_implicit_unsigned_output(self) -> None:
        sibling = TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh"
        if not sibling.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")
        script = sibling.read_text(encoding="utf-8")
        self.assertIn('if [ "$UNSIGNED_OK" != "1" ] && [ ! -f "$OTA_KEY" ]; then', script)
        self.assertIn("refusing to stage an implicit unsigned release", script)
        self.assertIn("refusing to stage a partial signed release", script)
        self.assertNotIn("OTA sig left empty", script)
        self.assertNotIn("staging rev-B USB-only (no OTA sig)", script)

    def test_standalone_stagers_check_key_identity_before_building(self) -> None:
        web = (TOOLS.parents[1] / "web/build-flasher.sh").read_text(encoding="utf-8")
        self.assertIn("require_ota_signing_key_identity", web)
        self.assertLess(web.index("require_ota_signing_key_identity"), web.index("pio run"))
        sibling = TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh"
        if not sibling.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")
        beacon = sibling.read_text(encoding="utf-8")
        self.assertIn("require_ota_signing_key_identity", beacon)
        self.assertLess(beacon.index("require_ota_signing_key_identity"), beacon.index("pio run"))

    def test_signed_beacon_stager_failures_leave_served_artifacts_untouched(self) -> None:
        sibling = TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh"
        if not sibling.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")

        scenarios = ("wrong_key", "missing_project", "build_failure", "missing_hex",
                     "bad_version", "packager_failure", "manifest_stamp_failure",
                     "revb_build_failure")
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                served = root / "site/firmware"
                firmware = root / "source/firmware"
                fake_bin = root / "bin"
                fake_home = root / "home"
                served.mkdir(parents=True)
                fake_bin.mkdir()
                (firmware / ".pio/build/beacon-board").mkdir(parents=True)
                (firmware / "lib/acab_core").mkdir(parents=True)
                (firmware / "tools/ota_signing").mkdir(parents=True)

                stager = served / "build-beacon-flasher.sh"
                stager.write_bytes(sibling.read_bytes())
                stager.chmod(0o755)
                (firmware / "tools/release_tools.py").write_bytes(
                    (TOOLS / "release_tools.py").read_bytes()
                )
                (firmware / "lib/acab_core/acab_version.h").write_text(
                    '#define ACAB_FW_VERSION "2.0.6"\n', encoding="utf-8"
                )
                write_ota_public_key_header(
                    firmware / "lib/acab_core/ota_pubkey.h", b"fake-public-der"
                )
                (firmware / "platformio.ini").write_text(
                    '[env:beacon-board]\nbuild_flags = -DACAB_FW_VERSION=\\"2.0.6\\"\n',
                    encoding="utf-8",
                )
                (firmware / "tools/ota_signing/beacon_ota_key.pem").write_text(
                    "test-key-not-reached\n", encoding="utf-8"
                )
                for name in ("bootloader.bin", "partitions.bin", "firmware.bin"):
                    (firmware / ".pio/build/beacon-board" / name).write_bytes(
                        ("new-" + name).encode()
                    )

                boot_app0 = (fake_home / ".platformio/packages/framework-arduinoespressif32/"
                             "tools/partitions/boot_app0.bin")
                boot_app0.parent.mkdir(parents=True)
                boot_app0.write_bytes(b"new-boot-app0")

                pio = fake_bin / "pio"
                pio.write_text(
                    "#!/bin/sh\n"
                    "[ -z \"${PIO_MARKER:-}\" ] || printf ran >> \"$PIO_MARKER\"\n"
                    "case \"$PWD\" in\n"
                    "  */nrf-ble-scan) [ \"${FAKE_NRF_BUILD_FAIL:-0}\" = 1 ] && exit 23 ;;\n"
                    "esac\n"
                    "case \"$*\" in\n"
                    "  *beacon-board-revb*) [ \"${FAKE_REVB_BUILD_FAIL:-0}\" = 1 ] && exit 31 ;;\n"
                    "esac\n"
                    "exit 0\n",
                    encoding="utf-8",
                )
                pio.chmod(0o755)
                (fake_bin / "python3").symlink_to(sys.executable)
                openssl = fake_bin / "openssl"
                openssl.write_text(
                    "#!/bin/sh\n"
                    "case \"$1\" in\n"
                    "  pkey)\n"
                    "    if [ \"${FAKE_WRONG_KEY:-0}\" = 1 ]; then\n"
                    "      printf 'wrong-public-der'\n"
                    "    else\n"
                    "      printf 'fake-public-der'\n"
                    "    fi\n"
                    "    ;;\n"
                    "  dgst) printf 'fake-signature' ;;\n"
                    "  *) echo \"unexpected openssl command: $*\" >&2; exit 97 ;;\n"
                    "esac\n",
                    encoding="utf-8",
                )
                openssl.chmod(0o755)

                if scenario != "missing_project":
                    nrf = firmware / "nrf-ble-scan"
                    (nrf / "src").mkdir(parents=True)
                    (nrf / "platformio.ini").write_text("[env:xiao-nrf52840]\n", encoding="utf-8")
                    source = "#define NRF_APP_VERSION 7\n"
                    if scenario == "bad_version":
                        source += "#define NRF_APP_VERSION 8\n"
                    (nrf / "src/main.cpp").write_text(source, encoding="utf-8")
                    if scenario != "missing_hex":
                        nrf_hex = nrf / ".pio/build/xiao-nrf52840/firmware.hex"
                        nrf_hex.parent.mkdir(parents=True)
                        nrf_hex.write_text(":00000001FF\n", encoding="ascii")

                if scenario in ("packager_failure", "manifest_stamp_failure",
                                "revb_build_failure"):
                    nrfutil = fake_bin / "adafruit-nrfutil"
                    if scenario == "packager_failure":
                        nrfutil.write_text("#!/bin/sh\nexit 29\n", encoding="utf-8")
                    else:
                        nrfutil.write_text(
                            "#!/bin/sh\n"
                            "for output in \"$@\"; do :; done\n"
                            "printf 'fake-nrf-package' > \"$output\"\n",
                            encoding="utf-8",
                        )
                    nrfutil.chmod(0o755)

                if scenario == "revb_build_failure":
                    (firmware / "tools/stage_beacon_revb.py").write_text(
                        "raise SystemExit('must not run after failed rev-B build')\n",
                        encoding="utf-8",
                    )

                artifact_names = (
                    "beacon-bootloader.bin", "beacon-partitions.bin", "beacon-boot_app0.bin",
                    "beacon-app.bin", "beacon-nrf-dfu.zip", "manifest-beacon.json",
                    "beacon-revb-bootloader.bin", "beacon-revb-partitions.bin",
                    "beacon-revb-boot_app0.bin", "beacon-revb-app.bin",
                    "manifest-beacon-revb.json", "firmware-latest.json",
                )
                before = {}
                for name in artifact_names:
                    value = ("previous-" + name).encode()
                    (served / name).write_bytes(value)
                    before[name] = value
                if scenario in ("manifest_stamp_failure", "revb_build_failure"):
                    before["manifest-beacon.json"] = (
                        b'{"name":"missing version marker"}\n'
                        if scenario == "manifest_stamp_failure"
                        else b'{"version":"previous"}\n'
                    )
                    before["firmware-latest.json"] = (
                        b'{"schema":1,"builds":{"beacon board":{"version":"previous",'
                        b'"app":{}}}}\n'
                    )
                    (served / "manifest-beacon.json").write_bytes(before["manifest-beacon.json"])
                    (served / "firmware-latest.json").write_bytes(before["firmware-latest.json"])

                env = os.environ.copy()
                env.update({
                    "HOME": os.fspath(fake_home),
                    "PATH": os.pathsep.join((os.fspath(fake_bin), "/usr/bin", "/bin")),
                    "PIO_MARKER": os.fspath(root / "pio-ran"),
                    "FAKE_WRONG_KEY": "1" if scenario == "wrong_key" else "0",
                    "FAKE_NRF_BUILD_FAIL": "1" if scenario == "build_failure" else "0",
                    "FAKE_REVB_BUILD_FAIL": "1" if scenario == "revb_build_failure" else "0",
                })
                proc = subprocess.run(
                    [os.fspath(stager), os.fspath(firmware)],
                    cwd=served,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                if scenario == "wrong_key":
                    self.assertIn("does not match the OTA trust root", proc.stdout)
                    self.assertFalse((root / "pio-ran").exists(), proc.stdout)
                if scenario == "manifest_stamp_failure":
                    self.assertIn("exactly one version field", proc.stdout)
                self.assertEqual(
                    {name: (served / name).read_bytes() for name in artifact_names},
                    before,
                    proc.stdout,
                )


class WebStagerFailureTests(unittest.TestCase):
    """The Colonel-Panic stager changes two served repos, so failure must change neither."""

    envs = ("oui-spy", "mesh-detect", "mesh-detect-ch1")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.repo = root / "all-cameras-are-beacons"
        self.site_firmware = root / "soyboi.tech/firmware"
        self.web = self.repo / "web"
        self.firmware = self.repo / "firmware"
        self.fake_home = root / "home"
        self.fake_bin = root / "bin"
        self.fake_bin.mkdir(parents=True)
        self.site_firmware.mkdir(parents=True)
        (self.web / "vendor/esp-web-tools").mkdir(parents=True)
        (self.web / "firmware").mkdir()
        (self.firmware / "lib/acab_core").mkdir(parents=True)
        (self.firmware / "tools").mkdir(parents=True)

        stager = self.web / "build-flasher.sh"
        stager.write_bytes((TOOLS.parents[1] / "web/build-flasher.sh").read_bytes())
        stager.chmod(0o755)
        (self.firmware / "tools/release_tools.py").write_bytes(
            (TOOLS / "release_tools.py").read_bytes()
        )
        (self.firmware / "lib/acab_core/acab_version.h").write_text(
            '#define ACAB_FW_VERSION "2.0.6"\n', encoding="utf-8"
        )
        write_ota_public_key_header(
            self.firmware / "lib/acab_core/ota_pubkey.h", b"fake-public-der"
        )
        (self.firmware / "platformio.ini").write_text(
            '[env:beacon-board]\nbuild_flags = -DACAB_FW_VERSION=\\"2.0.6\\"\n',
            encoding="utf-8",
        )

        for name in ("install-button.js", "chunk.js"):
            (self.web / "vendor/esp-web-tools" / name).write_text(
                f"// tracked {name}\n", encoding="utf-8"
            )
        for env in self.envs:
            build = self.firmware / f".pio/build/{env}"
            build.mkdir(parents=True)
            for part in ("bootloader", "partitions", "firmware"):
                (build / f"{part}.bin").write_bytes(f"new-{env}-{part}".encode())
            manifest = self.web / f"manifest-{env}.json"
            manifest.write_text(
                json_text({"name": env, "version": "1.0.0", "builds": []}),
                encoding="utf-8",
            )
            for part in ("bootloader", "partitions", "boot_app0", "app"):
                (self.web / "firmware" / f"acab-{env}-{part}.bin").write_bytes(
                    f"previous-web-{env}-{part}".encode()
                )
        (self.web / "index.html").write_text(
            "<span>All Cameras Are Beacons v1.0.0</span>\n", encoding="utf-8"
        )

        labels = {
            "ACAB-ouispy": "acab-oui-spy-app.bin",
            "mesh-detect-ACAB": "acab-mesh-detect-app.bin",
            "mesh-detect-ACAB-ch1": "acab-mesh-detect-ch1-app.bin",
        }
        builds = {}
        for label, filename in labels.items():
            builds[label] = {
                "version": "1.0.0",
                "ota": True,
                "app": {
                    "url": "https://soyboi.tech/firmware/" + filename,
                    "sha256": "old",
                    "size": 3,
                    "sig": "old",
                },
            }
            (self.site_firmware / filename).write_bytes(("previous-site-" + filename).encode())
        (self.site_firmware / "firmware-latest.json").write_text(
            json_text({"schema": 1, "builds": builds}), encoding="utf-8"
        )

        boot_app0 = (self.fake_home / ".platformio/packages/framework-arduinoespressif32/"
                     "tools/partitions/boot_app0.bin")
        boot_app0.parent.mkdir(parents=True)
        boot_app0.write_bytes(b"new-boot-app0")
        self.pio_marker = root / "pio-ran"
        pio = self.fake_bin / "pio"
        pio.write_text(
            '#!/bin/sh\nprintf ran > "$PIO_MARKER"\nexit 0\n', encoding="utf-8"
        )
        pio.chmod(0o755)
        (self.fake_bin / "python3").symlink_to(sys.executable)

        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "release test")
        git(self.repo, "config", "user.email", "release@test.invalid")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "fixture")
        self.stager = stager
        self.served_paths = (
            [self.web / "index.html"]
            + [self.web / f"manifest-{env}.json" for env in self.envs]
            + [self.web / "firmware" / f"acab-{env}-{part}.bin"
               for env in self.envs for part in ("bootloader", "partitions", "boot_app0", "app")]
            + [self.site_firmware / name for name in labels.values()]
            + [self.site_firmware / "firmware-latest.json"]
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def snapshot(self):
        return {os.fspath(path): path.read_bytes() for path in self.served_paths}

    def run_stager(self, *args, **extra_env):
        env = os.environ.copy()
        env.update({
            "HOME": os.fspath(self.fake_home),
            "PATH": os.pathsep.join((os.fspath(self.fake_bin), "/usr/bin", "/bin")),
            "PIO_MARKER": os.fspath(self.pio_marker),
        })
        env.update(extra_env)
        return subprocess.run(
            [os.fspath(self.stager), *args], cwd=self.repo, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )

    def install_key(self) -> None:
        key = self.firmware / "tools/ota_signing/beacon_ota_key.pem"
        key.parent.mkdir(parents=True, exist_ok=True)
        key.write_text("test key\n", encoding="utf-8")

    def install_openssl(self, body: str) -> None:
        openssl = self.fake_bin / "openssl"
        openssl.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        openssl.chmod(0o755)

    def install_working_openssl(self, public_der: str = "fake-public-der") -> None:
        self.install_openssl(
            "case \"$1\" in\n"
            f"  pkey) printf '{public_der}' ;;\n"
            "  dgst) printf 'fake-signature' ;;\n"
            "  *) echo \"unexpected openssl command: $*\" >&2; exit 97 ;;\n"
            "esac\n"
        )

    def test_missing_or_unusable_key_fails_before_served_mutation(self) -> None:
        for scenario in ("missing", "corrupt", "passphrase", "wrong"):
            with self.subTest(scenario=scenario):
                before = self.snapshot()
                if scenario != "missing":
                    self.install_key()
                    if scenario == "wrong":
                        self.install_working_openssl("wrong-public-der")
                    else:
                        self.install_openssl(
                            f"echo '{scenario} key cannot sign' >&2\nexit 41\n"
                        )
                proc = self.run_stager()
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertEqual(self.snapshot(), before, proc.stdout)
                self.assertFalse(self.pio_marker.exists(), proc.stdout)
                if scenario == "wrong":
                    self.assertIn("does not match the OTA trust root", proc.stdout)
                key = self.firmware / "tools/ota_signing/beacon_ota_key.pem"
                if key.exists():
                    key.unlink()
                openssl = self.fake_bin / "openssl"
                if openssl.exists():
                    openssl.unlink()

    def test_late_cross_repo_failure_rolls_back_every_served_path(self) -> None:
        self.install_key()
        self.install_working_openssl()
        counter = Path(self.temp.name) / "python-count"
        wrapper = self.fake_bin / "python3"
        wrapper.unlink()
        wrapper.write_text(
            "#!/bin/sh\n"
            'n=0; [ ! -f "$PY_COUNT_FILE" ] || n=$(cat "$PY_COUNT_FILE")\n'
            'n=$((n + 1)); printf "%s" "$n" > "$PY_COUNT_FILE"\n'
            'if [ "$n" = 5 ]; then echo "injected final manifest failure" >&2; exit 47; fi\n'
            f"exec {shlex.quote(sys.executable)} \"$@\"\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        before = self.snapshot()
        proc = self.run_stager(PY_COUNT_FILE=os.fspath(counter))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("restoring both served trees", proc.stdout)
        self.assertEqual(self.snapshot(), before, proc.stdout)

    def test_signed_success_commits_one_frozen_app_copy_to_both_repos(self) -> None:
        self.install_key()
        self.install_working_openssl()
        proc = self.run_stager()
        self.assertEqual(proc.returncode, 0, proc.stdout)
        latest = json.loads((self.site_firmware / "firmware-latest.json").read_text())
        labels = {
            "ACAB-ouispy": "oui-spy",
            "mesh-detect-ACAB": "mesh-detect",
            "mesh-detect-ACAB-ch1": "mesh-detect-ch1",
        }
        for label, env in labels.items():
            expected = (self.firmware / f".pio/build/{env}/firmware.bin").read_bytes()
            web_app = self.web / "firmware" / f"acab-{env}-app.bin"
            site_app = self.site_firmware / f"acab-{env}-app.bin"
            self.assertEqual(web_app.read_bytes(), expected)
            self.assertEqual(site_app.read_bytes(), expected)
            entry = latest["builds"][label]
            self.assertEqual(entry["version"], "2.0.6")
            self.assertTrue(entry["ota"])
            self.assertEqual(entry["app"]["size"], len(expected))
            self.assertEqual(entry["app"]["sig"], b"fake-signature".hex())
        self.assertIn("All Cameras Are Beacons v2.0.6",
                      (self.web / "index.html").read_text())

    def test_unsigned_mode_skips_even_a_wrong_signing_key(self) -> None:
        self.install_key()
        self.install_openssl("echo 'openssl must not run in USB-only mode' >&2\nexit 99\n")
        proc = self.run_stager("--unsigned-usb-only")
        self.assertEqual(proc.returncode, 0, proc.stdout)
        latest = json.loads((self.site_firmware / "firmware-latest.json").read_text())
        for label in ("ACAB-ouispy", "mesh-detect-ACAB", "mesh-detect-ACAB-ch1"):
            self.assertIs(latest["builds"][label]["ota"], False)
            self.assertEqual(latest["builds"][label]["app"]["sig"], "")

    def test_one_deleted_tracked_vendor_chunk_is_rejected(self) -> None:
        (self.web / "vendor/esp-web-tools/chunk.js").unlink()
        before = self.snapshot()
        proc = self.run_stager()
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("TRACKED IN HEAD BUT MISSING ON DISK", proc.stdout)
        self.assertFalse(self.pio_marker.exists(), proc.stdout)
        self.assertEqual(self.snapshot(), before, proc.stdout)


class RevBStagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.firmware = root / "firmware"
        self.site = root / "site"
        build = self.firmware / ".pio/build/beacon-board-revb"
        build.mkdir(parents=True)
        (self.firmware / "lib/acab_core").mkdir(parents=True)
        (self.firmware / "lib/acab_core/acab_version.h").write_text(
            '#define ACAB_FW_VERSION "2.0.4"\n', encoding="utf-8"
        )
        (self.firmware / "platformio.ini").write_text(
            '[env:beacon-board]\nflag = -DACAB_FW_VERSION=\\"2.0.4\\"\n',
            encoding="utf-8",
        )
        (build / "bootloader.bin").write_bytes(b"boot")
        (build / "partitions.bin").write_bytes(b"part")
        (build / "firmware.bin").write_bytes(make_image())
        self.boot_app0 = root / "boot_app0.bin"
        self.boot_app0.write_bytes(b"app0")
        (self.site / "firmware").mkdir(parents=True)
        (self.site / "flash-revb.html").write_text(
            '<esp-web-install-button manifest="./firmware/manifest-beacon-revb.json">',
            encoding="utf-8",
        )
        (self.site / "firmware/firmware-latest.json").write_text(
            json_text({
                "schema": 1,
                "builds": {
                    "beacon board": {
                        "nrf": {"version": 3, "url": "nrf.zip", "sha256": "aa"}
                    }
                },
            }),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_stages_distinct_files_and_revision_key(self) -> None:
        stage_rev_b(self.firmware, self.site, self.boot_app0, None, True)
        staged = self.site / "firmware"
        for name in REV_B_FILES.values():
            self.assertTrue((staged / name).is_file())
        latest = json.loads((staged / "firmware-latest.json").read_text())
        entry = latest["builds"][REV_B_LABEL]
        self.assertEqual(entry["version"], "2.0.4")
        self.assertFalse(entry["ota"])
        self.assertNotIn("nrf", entry)
        web = json.loads((staged / "manifest-beacon-revb.json").read_text())
        self.assertEqual(web["builds"][0]["parts"][-1]["path"], "beacon-revb-app.bin")

    def test_signed_stage_publishes_signature_over_exact_staged_bytes(self) -> None:
        key = Path(self.temp.name) / "key.pem"
        public = Path(self.temp.name) / "public.pem"
        public_der = Path(self.temp.name) / "public.der"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "ec", "-in", key, "-pubout", "-out", public],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", public, "-outform", "DER",
             "-out", public_der],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        write_ota_public_key_header(
            self.firmware / "lib/acab_core/ota_pubkey.h", public_der.read_bytes()
        )
        stage_rev_b(self.firmware, self.site, self.boot_app0, key)
        latest = json.loads((self.site / "firmware/firmware-latest.json").read_text())
        entry = latest["builds"][REV_B_LABEL]
        self.assertEqual(entry["nrf"]["version"], 3)
        signature = Path(self.temp.name) / "signature.der"
        signature.write_bytes(bytes.fromhex(entry["app"]["sig"]))
        staged_image = self.site / "firmware/beacon-revb-app.bin"
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", public, "-signature", signature,
             staged_image],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertTrue(entry["ota"])
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))

    def test_valid_but_wrong_signing_key_fails_before_staging(self) -> None:
        expected_key = Path(self.temp.name) / "expected.pem"
        wrong_key = Path(self.temp.name) / "wrong.pem"
        public_der = Path(self.temp.name) / "expected.der"
        for key in (expected_key, wrong_key):
            subprocess.run(
                ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout",
                 "-out", key],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        subprocess.run(
            ["openssl", "pkey", "-in", expected_key, "-pubout", "-outform", "DER",
             "-out", public_der],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        write_ota_public_key_header(
            self.firmware / "lib/acab_core/ota_pubkey.h", public_der.read_bytes()
        )
        before = (self.site / "firmware/firmware-latest.json").read_bytes()
        with self.assertRaisesRegex(StageError, "does not match the OTA trust root"):
            stage_rev_b(self.firmware, self.site, self.boot_app0, wrong_key)
        self.assertEqual((self.site / "firmware/firmware-latest.json").read_bytes(), before)
        self.assertFalse((self.site / "firmware/beacon-revb-app.bin").exists())

    def test_missing_site_page_fails_before_staging(self) -> None:
        (self.site / "flash-revb.html").unlink()
        with self.assertRaises(StageError):
            check_site_contract(self.site)
        self.assertFalse((self.site / "firmware/beacon-revb-app.bin").exists())

    def test_site_contract_rejects_noninteger_schema_one(self) -> None:
        latest = self.site / "firmware/firmware-latest.json"
        manifest = json.loads(latest.read_text())
        manifest["schema"] = True
        latest.write_text(json_text(manifest), encoding="utf-8")
        with self.assertRaisesRegex(StageError, "schema must be exactly integer 1"):
            check_site_contract(self.site)

    def test_wrong_revision_descriptor_is_rejected(self) -> None:
        image = self.firmware / ".pio/build/beacon-board-revb/firmware.bin"
        image.write_bytes(make_image(project="acab firmware"))
        with self.assertRaises(StageError):
            stage_rev_b(self.firmware, self.site, self.boot_app0, None, True)


def json_text(value) -> str:
    return json.dumps(value) + "\n"


if __name__ == "__main__":
    unittest.main()
