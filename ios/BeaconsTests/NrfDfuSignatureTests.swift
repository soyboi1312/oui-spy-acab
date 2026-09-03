import XCTest
import CryptoKit
@testable import Beacons

final class NrfDfuSignatureTests: XCTestCase {
    /// Public test vector: 41 ASCII bytes ("beacons nrf dfu signature test vector v1" plus a
    /// newline) signed with the DEVELOPMENT key, the signer of every release through 2.0.6 and
    /// of the 2.0.7 transition package. Nothing here is secret. When the development entry is
    /// retired from `NrfDfuSignature.trustedPublicKeyPEMs`, replace `devSignatureHex` with a vector
    /// signed by the production key so this gate keeps a positive acceptance test, as the Android
    /// twin `NrfDfuSignatureTest` says.
    private let payload = Data(base64Encoded: "YmVhY29ucyBucmYgZGZ1IHNpZ25hdHVyZSB0ZXN0IHZlY3RvciB2MQo=")!
    private let devSignatureHex =
        "304502200aadae7edec572847c0945318f08da9da79656ab363d51479e98409ea3cc424f" +
        "0221008117ecdaee1365c6fdd760d0b777160bfce5214a3096eb74c98feb5a6181a6e9"

    /// SPKI DER sha256 of each trusted key, in the order the gate tries them. Both fingerprints
    /// are the ones named in the firmware/lib/acab_core/ota_pubkey.h header comment, and the
    /// production one is the sha256 of the DER bytes that header pins.
    private let productionFingerprint = "c5d86430652e89c02dc357a1ee15601f95ea18726dbeed486d9b98f57c0399e9"
    private let developmentFingerprint = "39e03b1581db574822be12631df557ac136a3c5b9c00b8e32e07dc4a9b6d3df1"

    func testDevSignedVectorIsAccepted() {
        XCTAssertEqual(payload.count, 41)
        XCTAssertTrue(NrfDfuSignature.isValid(zip: payload, sigHexDER: devSignatureHex))
        XCTAssertTrue(NrfDfuSignature.isValid(zip: payload, sigHexDER: devSignatureHex.uppercased()))
    }

    func testOneFlippedPayloadByteIsRejected() {
        var tampered = payload
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertFalse(NrfDfuSignature.isValid(zip: tampered, sigHexDER: devSignatureHex))
    }

    func testMalformedSignaturesAreRejectedWithoutThrowing() {
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: ""))
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: "abc"))
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: "zz"))
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: "deadbeef"))
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: String(devSignatureHex.dropLast(2))))
        var flippedSig = devSignatureHex
        let last = flippedSig.removeLast()
        flippedSig.append(last == "9" ? "8" : "9")
        XCTAssertFalse(NrfDfuSignature.isValid(zip: payload, sigHexDER: flippedSig))
    }

    func testDevVectorDoesNotVerifyUnderProductionKeyAlone() throws {
        // The two keys differ, so the vector passing `isValid` above is proof that the
        // development entry (not the production one) accepted it.
        let production = try P256.Signing.PublicKey(pemRepresentation: NrfDfuSignature.trustedPublicKeyPEMs[0])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(Data(hexString: devSignatureHex)))
        XCTAssertFalse(production.isValidSignature(signature, for: payload))
    }

    /// Structural guard: every pasted PEM parses as a P-256 public key, the production key is
    /// first and the development key second, and each one's SPKI fingerprint matches the board's
    /// declared trust root, so a typo in a pasted key cannot ship.
    func testTrustedKeysParseInDeclaredOrderWithDeclaredFingerprints() throws {
        let pems = NrfDfuSignature.trustedPublicKeyPEMs
        XCTAssertEqual(pems.count, 2)
        let fingerprints = try pems.map { pem -> String in
            let key = try P256.Signing.PublicKey(pemRepresentation: pem)
            return SHA256.hash(data: key.derRepresentation).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(fingerprints, [productionFingerprint, developmentFingerprint])
    }
}
