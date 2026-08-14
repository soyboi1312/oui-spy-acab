#!/usr/bin/env python3

from pathlib import Path
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.fspath(TOOLS))

from release_tools import (  # noqa: E402
    ESP_APP_DESC_MAGIC,
    ESP_APP_DESC_OFFSET,
    ESP_APP_PROJECT_OFFSET,
    ESP_APP_VERSION_OFFSET,
    ESP_IMAGE_MAGIC,
    ReleaseToolError,
    dirty_tree_digest,
    expected_project_for_artifact,
    filter_release_profile,
    parse_esp_app_desc,
    read_esp_app_desc,
    require_manifest_image_identity,
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


class ReleaseOrchestratorContractTests(unittest.TestCase):
    def test_app_release_regenerates_ignored_xcode_project(self) -> None:
        script = (TOOLS / "release.sh").read_text(encoding="utf-8")
        self.assertIn("command -v xcodegen", script)
        self.assertLess(script.index("xcodegen generate"), script.index("xcodebuild -project"))

    def test_nrf_packager_binds_inner_application_version(self) -> None:
        stager = (TOOLS.parents[2] / "soyboi.tech/firmware/build-beacon-flasher.sh")
        if not stager.is_file():
            self.skipTest("sibling soyboi.tech checkout is unavailable")
        script = stager.read_text(encoding="utf-8")
        self.assertIn('--application-version "$NRF_VER"', script)


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
        self.assertEqual(entry["nrf"]["version"], 3)
        web = json.loads((staged / "manifest-beacon-revb.json").read_text())
        self.assertEqual(web["builds"][0]["parts"][-1]["path"], "beacon-revb-app.bin")

    def test_signed_stage_publishes_signature_over_exact_staged_bytes(self) -> None:
        key = Path(self.temp.name) / "key.pem"
        public = Path(self.temp.name) / "public.pem"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "ec", "-in", key, "-pubout", "-out", public],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        stage_rev_b(self.firmware, self.site, self.boot_app0, key)
        latest = json.loads((self.site / "firmware/firmware-latest.json").read_text())
        entry = latest["builds"][REV_B_LABEL]
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

    def test_missing_site_page_fails_before_staging(self) -> None:
        (self.site / "flash-revb.html").unlink()
        with self.assertRaises(StageError):
            check_site_contract(self.site)
        self.assertFalse((self.site / "firmware/beacon-revb-app.bin").exists())

    def test_wrong_revision_descriptor_is_rejected(self) -> None:
        image = self.firmware / ".pio/build/beacon-board-revb/firmware.bin"
        image.write_bytes(make_image(project="acab firmware"))
        with self.assertRaises(StageError):
            stage_rev_b(self.firmware, self.site, self.boot_app0, None, True)


def json_text(value) -> str:
    return json.dumps(value) + "\n"


if __name__ == "__main__":
    unittest.main()
