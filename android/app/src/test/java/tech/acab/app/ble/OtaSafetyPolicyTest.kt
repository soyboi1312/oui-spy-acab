package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.net.NrfBuild
import tech.acab.app.net.firmwareArtifactResponseAllowed
import tech.acab.app.net.readBoundedManifestBody
import tech.acab.app.net.trustedFirmwareArtifactUrl
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.zip.CRC32

class OtaSafetyPolicyTest {
    private fun nrf(ota: Boolean = true, size: Long = 1024) = NrfBuild(
        version = 2,
        ota = ota,
        zipUrl = "https://soyboi.tech/firmware/nrf.zip",
        sha256 = "a".repeat(64),
        size = size,
        sig = "01",
    )

    @Test
    fun `nrf offer requires manifest opt-in exact board and newer bounded image`() {
        assertTrue(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "beacon board", 1, 2))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(ota = false), "beacon board", "beacon board", 1, 2))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "other board", 1, 2))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "beacon board", null, 2))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "beacon board", 2, 2))
        assertFalse(nrfUpdateOfferAllowed(false, nrf(), "beacon board", "beacon board", 1, 2))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "beacon board", 1, 1))
        assertFalse(nrfUpdateOfferAllowed(true, nrf(), "beacon board", "beacon board", 1, 3))
        assertFalse(nrfUpdateOfferAllowed(
            true, nrf(size = NrfBuild.MAX_PACKAGE_BYTES + 1), "beacon board", "beacon board", 1, 2))
    }

    @Test
    fun `dfu candidate decision never picks first when two addresses qualify`() {
        assertTrue(preflightDfuClear(emptyList()))
        assertFalse(preflightDfuClear(listOf("OLD")))
        assertEquals(DfuCandidateDecision.None, decideDfuCandidates(emptyList()))
        assertEquals(DfuCandidateDecision.One("AA"), decideDfuCandidates(listOf("AA", "AA")))
        assertEquals(DfuCandidateDecision.Ambiguous, decideDfuCandidates(listOf("AA", "BB")))
    }

    @Test
    fun `protocol two handoff requires fresh nrfup from owner session`() {
        assertTrue(nrfHandoffStatusIsFresh(2, true, 11, 10, 7, 7))
        assertFalse(nrfHandoffStatusIsFresh(1, true, 11, 10, 7, 7))
        assertFalse(nrfHandoffStatusIsFresh(3, true, 11, 10, 7, 7))
        assertFalse(nrfHandoffStatusIsFresh(2, false, 11, 10, 7, 7))
        assertFalse(nrfHandoffStatusIsFresh(2, true, 10, 10, 7, 7))
        assertFalse(nrfHandoffStatusIsFresh(2, true, 11, 10, 7, 8))
    }

    @Test
    fun `s3 ota replies require the exact armed gatt generation`() {
        assertTrue(otaReplyBelongsToArmedSession(true, 9, 9))
        assertFalse(otaReplyBelongsToArmedSession(false, 9, 9))
        assertFalse(otaReplyBelongsToArmedSession(true, 8, 9))
        assertFalse(otaReplyBelongsToArmedSession(true, -1, -1))
        assertFalse(otaDoneCanAdvance(OtaPhase.SENDING, imageEnded = false))
        assertFalse(otaDoneCanAdvance(OtaPhase.CHECKING, imageEnded = true))
        assertTrue(otaDoneCanAdvance(OtaPhase.SENDING, imageEnded = true))
    }

    @Test
    fun `post reboot confirmation requires exact product label and numeric target`() {
        assertEquals(
            OtaPostRebootDecision.CONFIRM,
            decideOtaPostReboot("2.0.4", "beacon board", "2.0.4", "beacon board"),
        )
        assertEquals(
            OtaPostRebootDecision.LABEL_MISMATCH,
            decideOtaPostReboot("2.0.4", "beacon board rev-b", "2.0.4", "beacon board"),
        )
        assertEquals(
            OtaPostRebootDecision.ROLLED_BACK,
            decideOtaPostReboot("2.0.3", "beacon board", "2.0.4", "beacon board"),
        )
        assertEquals(
            OtaPostRebootDecision.UNKNOWN,
            decideOtaPostReboot("ESP32", "beacon board", "2.0.4", "beacon board"),
        )
        assertEquals(
            OtaPostRebootDecision.UNKNOWN,
            decideOtaPostReboot("2.0.4", "beacon board", "999999999999999999", "beacon board"),
        )
    }

    @Test
    fun `non-ascii digits never pass the firmware version gate`() {
        // Char.isDigit() is Unicode-aware; each of these parsed as "numeric" before the ASCII
        // gate, and a spoofed running version reaching CONFIRM disarms bootloader rollback.
        assertFalse(isNumericFirmwareVersion("２.０.４"))      // fullwidth 2.0.4
        assertFalse(isNumericFirmwareVersion("٢.٠.٤"))      // Arabic-Indic
        assertFalse(isNumericFirmwareVersion("२.०.४"))      // Devanagari
        assertFalse(isNumericFirmwareVersion("2.０.4"))                // one smuggled field
        assertFalse(isNumericFirmwareVersion("12345.0.0"))                 // field > 4 digits
        // Leading dash: substringBefore("-") yields "" here, rejected by isNotEmpty(). Pinned
        // because iOS's split() needed omittingEmptySubsequences: false to agree; same board
        // state must read the same on both platforms.
        assertFalse(isNumericFirmwareVersion("-1"))
        assertFalse(isNumericFirmwareVersion("-2.0.4"))
        assertFalse(isNumericFirmwareVersion("--1"))
        assertTrue(isNumericFirmwareVersion("2.0.4"))
        assertTrue(isNumericFirmwareVersion("2.0.4-rc1"))
        assertTrue(isNumericFirmwareVersion("1023.0.0"))
        assertEquals(
            OtaPostRebootDecision.UNKNOWN,
            decideOtaPostReboot("２.０.４", "beacon board", "2.0.4", "beacon board"),
        )
    }

    @Test
    fun `manifest body enforces declared and streaming caps`() {
        val cap = 256
        val good = ByteArray(256) { 1 }
        assertEquals(256, readBoundedManifestBody(ByteArrayInputStream(good), 256, cap)?.size)
        assertNull(readBoundedManifestBody(ByteArrayInputStream(good), 257, cap))
        assertNull(readBoundedManifestBody(ByteArrayInputStream(ByteArray(257)), -1, cap))
    }

    @Test
    fun `firmware artifacts stay on exact soyboi https origin without redirects`() {
        val good = URL("https://soyboi.tech/firmware/app.bin")
        assertEquals(good, trustedFirmwareArtifactUrl(good.toExternalForm()))
        assertNull(trustedFirmwareArtifactUrl("http://soyboi.tech/firmware/app.bin"))
        assertNull(trustedFirmwareArtifactUrl("https://cdn.soyboi.tech/firmware/app.bin"))
        assertNull(trustedFirmwareArtifactUrl("https://soyboi.tech.evil.test/app.bin"))
        assertNull(trustedFirmwareArtifactUrl("https://user@soyboi.tech/app.bin"))
        assertNull(trustedFirmwareArtifactUrl("https://soyboi.tech:8443/app.bin"))
        assertTrue(firmwareArtifactResponseAllowed(good, good, HttpURLConnection.HTTP_OK))
        assertFalse(firmwareArtifactResponseAllowed(good, good, HttpURLConnection.HTTP_MOVED_TEMP))
        assertFalse(firmwareArtifactResponseAllowed(
            good, URL("https://soyboi.tech/firmware/other.bin"), HttpURLConnection.HTTP_OK))
    }

    @Test
    fun `signed nrf package exposes exact embedded application version`() {
        assertEquals(2L, nrfPackageApplicationVersion(dfuZip(2)))
        assertEquals(0xffff_ffffL, nrfPackageApplicationVersion(dfuZip(0xffff_ffffL)))
        assertNull(nrfPackageApplicationVersion(dfuZip(null)))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, padding = "x".repeat(65 * 1024))))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, forbiddenSection = "softdevice")))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, extraEntry = "other.bin")))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, binFile = "nested/firmware.bin")))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, stored = false)))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, datVersion = 3)))
        assertNull(nrfPackageApplicationVersion(dfuZip(2, datBytes = byteArrayOf(1, 2, 3, 4))))
        assertEquals(2L, legacyDfuInitPacketVersion(initPacket(2)))
        assertEquals(0xffff_ffffL, legacyDfuInitPacketVersion(initPacket(0xffff_ffffL)))
        assertNull(legacyDfuInitPacketVersion(ByteArray(7)))
    }

    private fun dfuZip(
        version: Long?,
        padding: String = "",
        forbiddenSection: String? = null,
        extraEntry: String? = null,
        binFile: String = "firmware.bin",
        stored: Boolean = true,
        datVersion: Long = version ?: 2,
        datBytes: ByteArray = initPacket(datVersion),
    ): ByteArray {
        val versionField = version?.let { "\"application_version\":$it" } ?: ""
        val forbidden = forbiddenSection?.let { ",\"$it\":{}" } ?: ""
        val manifest = """{"manifest":{"application":{"bin_file":"$binFile","dat_file":"firmware.dat","init_packet_data":{$versionField},"pad":"$padding"}$forbidden}}"""
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            zip.putTestEntry("manifest.json", manifest.toByteArray(), stored)
            zip.putTestEntry(binFile, byteArrayOf(1, 2, 3), stored)
            zip.putTestEntry("firmware.dat", datBytes, stored)
            extraEntry?.let {
                zip.putTestEntry(it, byteArrayOf(7), stored)
            }
        }
        return out.toByteArray()
    }

    private fun initPacket(version: Long): ByteArray = ByteArray(8).also { bytes ->
        for (i in 0..3) bytes[4 + i] = ((version ushr (i * 8)) and 0xff).toByte()
    }

    private fun ZipOutputStream.putStored(name: String, bytes: ByteArray) {
        val checksum = CRC32().apply { update(bytes) }.value
        putNextEntry(ZipEntry(name).apply {
            method = ZipEntry.STORED
            size = bytes.size.toLong()
            compressedSize = bytes.size.toLong()
            crc = checksum
        })
        write(bytes)
        closeEntry()
    }

    private fun ZipOutputStream.putTestEntry(name: String, bytes: ByteArray, stored: Boolean) {
        if (stored) {
            putStored(name, bytes)
        } else {
            putNextEntry(ZipEntry(name))
            write(bytes)
            closeEntry()
        }
    }
}
