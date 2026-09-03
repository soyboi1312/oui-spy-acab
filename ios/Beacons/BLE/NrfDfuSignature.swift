import Foundation
import CryptoKit

/// App-side signature check for the nRF co-processor DFU package.
///
/// The S3 image is verified ON the board (its OTA gate pins the public key in
/// firmware/lib/acab_core/ota_pubkey.h). The nRF is different: its stock Adafruit/Seeed
/// bootloader speaks legacy DFU, which is CRC-only and cannot verify our ECDSA signature. So for
/// the nRF the APP is the only gate, and it MUST verify before pushing the package to a
/// bootloader that will flash whatever it's handed. This gate is nRF-only: it never sees the S3
/// image.
///
/// The manifest's nrf.sig is a DER-encoded ECDSA P-256 signature over SHA-256 of the whole
/// .zip, produced by `openssl dgst -sha256 -sign`, so `isValidSignature(_:for:)` (which hashes
/// the data with SHA-256 internally) is the exact inverse. Verified against the real staged
/// artifact with `openssl dgst -sha256 -verify` before shipping this.
///
/// Key rotation (2.0.7): the signing key moved from a development key to a production key whose
/// private half lives offline. Every fielded board and app before 2.0.7 trusts only the
/// development key, so 2.0.7 is signed with the development key while carrying the production
/// key, and the apps accept EITHER key for that one release cycle. The board side of the
/// rotation is documented in firmware/lib/acab_core/ota_pubkey.h.
enum NrfDfuSignature {
    /// Trusted signing public keys (SubjectPublicKeyInfo / X.509, PEM), tried in this order:
    ///
    /// 1. PRODUCTION key, SPKI sha256 c5d86430652e...0399e9: the key pinned in the board's
    ///    ota_pubkey.h since 2.0.7 and the signer of every release after 2.0.7. Its private half
    ///    is offline and is not in this tree.
    /// 2. DEVELOPMENT key, SPKI sha256 39e03b1581db...6d3df1: signed every release through 2.0.6
    ///    and the 2.0.7 transition package. Its private half is
    ///    firmware/tools/ota_signing/beacon_ota_key.pem (gitignored). RETIRE this entry, and the
    ///    dev-signed vector in NrfDfuSignatureTests, once every fielded board and app has passed
    ///    2.0.7; from 2.0.8 on nothing is signed with it.
    ///
    /// Twin: android/app/src/main/java/tech/acab/app/ble/NrfDfuSignature.kt must hold the same
    /// keys in the same order; a key added or retired here is added or retired there in the same
    /// change. NrfDfuSignatureTests pins each entry's SPKI fingerprint so a paste typo cannot ship.
    static let trustedPublicKeyPEMs: [String] = [
        """
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFEq4RVNjVdfIjwut9is8gNotnXIB
        hKUau6b6c4OCbHSP7Sl/2RTMkPnIE+qzPZaRb4xjLsAbtNKoPGUzpfH5hA==
        -----END PUBLIC KEY-----
        """,
        """
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpgFKoOmugxeYHXEirno5rN7DO9uJ
        ESOP7a/OfJD9nAbBmpNFq1tFgVewzRm90F1yIkn2HvlkCSto75t5vTmybw==
        -----END PUBLIC KEY-----
        """,
    ]

    /// True when `sigHexDER` is a valid signature over `zip` from ANY key in
    /// `trustedPublicKeyPEMs` (first match wins). Any malformed input (bad hex, non-DER
    /// signature, no key that validates) returns false, never throws: the caller treats false as
    /// "refuse to flash". Cold path: it runs once per downloaded package, so the PEMs are parsed
    /// on each call rather than cached.
    static func isValid(zip: Data, sigHexDER: String) -> Bool {
        guard let sigData = Data(hexString: sigHexDER), !sigData.isEmpty,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData)
        else { return false }
        return trustedPublicKeyPEMs.contains { pem in
            guard let key = try? P256.Signing.PublicKey(pemRepresentation: pem) else { return false }
            return key.isValidSignature(signature, for: zip)
        }
    }
}

extension Data {
    /// Parse a lowercase/uppercase hex string ("3046...") into bytes, or nil on any bad char /
    /// odd length. Local to this file so the crypto gate owns its own parsing.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = out
    }
}
