package tech.acab.app.ble

import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/**
 * App-side signature check for the nRF co-processor DFU package.
 * Twin: ios/Beacons/BLE/NrfDfuSignature.swift. Keep the trusted-key list, its order and the
 * retirement rule identical on both phones.
 *
 * The S3 image is verified ON the board (its OTA gate holds the public key). The nRF is
 * different: its stock Adafruit/Seeed bootloader speaks legacy DFU, which is CRC-only and cannot
 * verify our ECDSA signature. So for the nRF the APP is the only gate, and it MUST verify before
 * pushing the package to a bootloader that will flash whatever it's handed.
 *
 * The manifest's nrf.sig is a DER-encoded ECDSA P-256 signature over SHA-256 of the whole .zip,
 * produced by `openssl dgst -sha256 -sign`, so "SHA256withECDSA" over the zip bytes is the exact
 * inverse. Verified against the real staged artifact with `openssl dgst -sha256 -verify` first.
 *
 * TRUST ROOTS. The board pins ONE key for the S3 image (ACAB_OTA_PUBKEY_DER in
 * firmware/lib/acab_core/ota_pubkey.h); this object is the app-side pin for the nRF package. On
 * 2026-09-02 the board's pin moved from the development key to the production key, and 2.0.7 is
 * the transition cut: built with the production key baked in but SIGNED with the development key,
 * so every fielded 2.0.5/2.0.6 board (which trusts only the development key) accepts it. The nRF
 * package of that same release is signed with the development key too, so this gate accepts
 * EITHER key for one release cycle. [TRUSTED_SPKI_B64] carries the order; [DEVELOPMENT_SPKI_B64]
 * carries the retirement rule.
 *
 * Decoding a key and verifying a signature happen once per DFU download (in
 * NrfDfuCoordinator.downloadAndVerify), never on the BLE publish path, so no key is cached.
 */
object NrfDfuSignature {
    /** PRODUCTION signing key (SubjectPublicKeyInfo / X.509 DER, base64). Byte-identical to the
     *  ACAB_OTA_PUBKEY_DER bytes in firmware/lib/acab_core/ota_pubkey.h (SPKI sha256
     *  c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9; NrfDfuSignatureTest pins
     *  it). Its private half lives offline and is NOT in this tree. Signs every package from
     *  2.0.8 on. */
    private const val PRODUCTION_SPKI_B64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFEq4RVNjVdfIjwut9is8gNotnXIB" +
        "hKUau6b6c4OCbHSP7Sl/2RTMkPnIE+qzPZaRb4xjLsAbtNKoPGUzpfH5hA=="

    /** DEVELOPMENT signing key, same encoding (SPKI sha256
     *  39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1). Signed every package
     *  through 2.0.6 and the 2.0.7 transition package. Pairs with
     *  firmware/tools/ota_signing/beacon_ota_key.pem (gitignored). RETIRE this entry, together with
     *  the dev-signed vector in NrfDfuSignatureTest, once every fielded board and app has passed
     *  2.0.7; until then a 2.0.7 package would be refused without it. */
    private const val DEVELOPMENT_SPKI_B64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpgFKoOmugxeYHXEirno5rN7DO9uJ" +
        "ESOP7a/OfJD9nAbBmpNFq1tFgVewzRm90F1yIkn2HvlkCSto75t5vTmybw=="

    /** Trusted keys in the order they are tried: production first, development second. Internal
     *  so the unit test can pin each entry's SPKI sha256 and prove the second entry is consulted. */
    internal val TRUSTED_SPKI_B64: List<String> = listOf(PRODUCTION_SPKI_B64, DEVELOPMENT_SPKI_B64)

    /** True when [sigHexDer] is a valid signature over [zip] from ANY key in [TRUSTED_SPKI_B64].
     *  Any malformed input returns false, never throws: the caller treats false as "refuse to
     *  flash". */
    fun isValid(zip: ByteArray, sigHexDer: String): Boolean = isValid(zip, sigHexDer, TRUSTED_SPKI_B64)

    /** [isValid] against an explicit key list, so the unit test can show which entry verified.
     *  Each key is tried under its own runCatching: a key that fails to decode, or a signature
     *  that fails to parse, counts as "not verified by this key" and the next key is still tried,
     *  so one bad entry can never mask the other. Nothing in here throws. */
    internal fun isValid(zip: ByteArray, sigHexDer: String, trustedSpkiB64: List<String>): Boolean {
        val der = hexToBytes(sigHexDer) ?: return false
        return trustedSpkiB64.any { spkiB64 ->
            runCatching {
                Signature.getInstance("SHA256withECDSA").run {
                    initVerify(decodeSpki(spkiB64))
                    update(zip)
                    verify(der)
                }
            }.getOrDefault(false)
        }
    }

    /** Decode one base64 SubjectPublicKeyInfo into an EC public key. Throws on any malformed
     *  input; [isValid] catches per key, and the unit test calls it bare so a typo fails loudly. */
    internal fun decodeSpki(spkiB64: String): PublicKey =
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(spkiB64)))

    private fun hexToBytes(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val hi = Character.digit(hex[i], 16)
            val lo = Character.digit(hex[i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i / 2] = ((hi shl 4) or lo).toByte()
            i += 2
        }
        return out
    }
}
