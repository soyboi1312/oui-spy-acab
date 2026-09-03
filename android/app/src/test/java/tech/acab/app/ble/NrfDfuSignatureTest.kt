package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/**
 * The nRF DFU package signature gate, the only gate the nRF has (its bootloader is CRC-only).
 *
 * WHY THIS EXISTS. The 2026-09-02 key rotation turned one pinned key into an ordered list of two
 * (production first, development second) that NrfDfuSignature.isValid must accept EITHER of for
 * one release cycle. A gate that quietly consulted only the first entry would refuse every 2.0.7
 * package in the field, and a base64 typo in the production entry would ship a key no signer
 * holds. Both would surface only on a real phone against a real manifest, so they are pinned here.
 *
 * The vector is public data: the payload is the ASCII line "beacons nrf dfu signature test vector
 * v1" plus a newline, and the signature was made with the DEVELOPMENT key, the one that signs the
 * 2.0.7 transition package. When the development entry is retired from TRUSTED_SPKI_B64, retire
 * this vector with it and re-sign one with the production key.
 *
 * The SPKI sha256 pins are the full forms of the digests the firmware header comment abbreviates
 * (firmware/lib/acab_core/ota_pubkey.h, PRODUCTION KEY paragraph); the production DER bytes there
 * were compared byte-for-byte to the base64 here on the day this test was written.
 */
class NrfDfuSignatureTest {
    private val payload: ByteArray =
        Base64.getDecoder().decode("YmVhY29ucyBucmYgZGZ1IHNpZ25hdHVyZSB0ZXN0IHZlY3RvciB2MQo=")

    /** DER ECDSA P-256 signature over SHA-256(payload), made with the development key. */
    private val devSigHex =
        "304502200aadae7edec572847c0945318f08da9da79656ab363d51479e98409ea3cc424f" +
        "0221008117ecdaee1365c6fdd760d0b777160bfce5214a3096eb74c98feb5a6181a6e9"

    private val productionSha256 = "c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9"
    private val developmentSha256 = "39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1"

    private fun spkiSha256(b64: String): String =
        MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
            .joinToString("") { "%02x".format(it) }

    @Test fun devSignedVector_isAcceptedByTheShippingKeyList() {
        assertEquals("the vector payload is 41 bytes", 41, payload.size)
        assertTrue(NrfDfuSignature.isValid(payload, devSigHex))
    }

    @Test fun devSignedVector_isRefusedByTheProductionKeyAlone() {
        // Proves the keys differ AND that isValid consults the second entry: the same vector that
        // the full list accepts is refused when only the first entry is offered.
        val productionOnly = NrfDfuSignature.TRUSTED_SPKI_B64.take(1)
        assertFalse(NrfDfuSignature.isValid(payload, devSigHex, productionOnly))
        assertTrue(NrfDfuSignature.isValid(payload, devSigHex, NrfDfuSignature.TRUSTED_SPKI_B64))
    }

    @Test fun oneFlippedPayloadByte_isRefused() {
        val tampered = payload.copyOf()
        tampered[0] = (tampered[0].toInt() xor 0x01).toByte()
        assertFalse(NrfDfuSignature.isValid(tampered, devSigHex))
    }

    @Test fun garbageSignature_isRefusedWithoutThrowing() {
        assertFalse("non-hex characters", NrfDfuSignature.isValid(payload, "zz".repeat(35)))
        assertFalse("odd-length hex", NrfDfuSignature.isValid(payload, devSigHex.dropLast(1)))
        assertFalse("hex that is not DER", NrfDfuSignature.isValid(payload, "00".repeat(70)))
        assertFalse("truncated DER", NrfDfuSignature.isValid(payload, devSigHex.dropLast(2)))
    }

    @Test fun emptySignature_isRefused() {
        assertFalse(NrfDfuSignature.isValid(payload, ""))
    }

    @Test fun undecodableFirstKey_doesNotMaskTheSecond() {
        // A per-key catch is what lets a bad entry fail closed on its own instead of taking the
        // whole list with it.
        val listWithGarbageFirst = listOf("not base64 at all!") + NrfDfuSignature.TRUSTED_SPKI_B64
        assertTrue(NrfDfuSignature.isValid(payload, devSigHex, listWithGarbageFirst))
        assertFalse(NrfDfuSignature.isValid(payload, devSigHex, listOf("not base64 at all!")))
        assertFalse(NrfDfuSignature.isValid(payload, devSigHex, emptyList()))
    }

    @Test fun trustedKeys_areProductionThenDevelopment_andBothDecode() {
        val keys = NrfDfuSignature.TRUSTED_SPKI_B64
        assertEquals("exactly two trust roots during the rotation window", 2, keys.size)
        assertEquals("production first", productionSha256, spkiSha256(keys[0]))
        assertEquals("development second", developmentSha256, spkiSha256(keys[1]))
        // Structural: each entry is a real EC SubjectPublicKeyInfo, decoded bare (no runCatching)
        // through the same KeyFactory path the gate uses, so a typo fails here and not on a phone.
        for (b64 in keys) {
            val key = KeyFactory.getInstance("EC")
                .generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(b64)))
            assertEquals("EC", key.algorithm)
            assertEquals(key.encoded.toList(), NrfDfuSignature.decodeSpki(b64).encoded.toList())
        }
    }
}
