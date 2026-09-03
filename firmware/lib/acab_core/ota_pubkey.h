/*
 * ACAB - OTA image-signing PUBLIC key (ECDSA P-256, SubjectPublicKeyInfo DER).
 *
 * The board verifies a detached ECDSA-P256/SHA-256 signature over the whole OTA image
 * against THIS key before accepting an update (see ota_update.cpp otaFinish). The matching
 * PRIVATE key lives OFFLINE only (firmware/tools/ota_signing/beacon_ota_key.pem, gitignored)
 * and signs each build in the flasher build scripts. Because authenticity is rooted in this
 * baked-in key, a compromised download host / manifest / phone app still cannot get an
 * unsigned image to execute: the image must be signed by the holder of the private key.
 *
 * To rotate: generate a new P-256 key, regenerate this header (openssl ec -pubout -outform
 * DER | xxd), ship it in a signed OTA (or web-flash), then sign future builds with the new key.
 *
 * PRODUCTION KEY since 2026-09-02 (SPKI sha256 c5d86430652e...0399e9). The development key it
 * replaced (sha256 39e03b1581db...6d3df1) signed every image through 2.0.6 and signs the 2.0.7
 * transition image ONLY: 2.0.7 carries THIS key, so a board still rooted in the development key
 * accepts 2.0.7 and trusts the production key from its next boot. Every image after 2.0.7 is
 * signed with the production key, whose private half lives offline and is backed up.
 * The one-release rotation window is declared in firmware/tools/release_tools.py (OTA_ROTATION)
 * and the trust root is pinned in verify-release-artifacts.py (INTENDED_OTA_KEY_SHA256).
 */
#ifndef ACAB_OTA_PUBKEY_H
#define ACAB_OTA_PUBKEY_H

#include <stddef.h>
#include <stdint.h>

// SubjectPublicKeyInfo DER for the ECDSA P-256 (prime256v1) OTA signing public key.
static const uint8_t ACAB_OTA_PUBKEY_DER[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00, 0x04, 0x14, 0x4a, 0xb8, 0x45, 0x53, 0x63, 0x55, 0xd7, 0xc8,
    0x8f, 0x0b, 0xad, 0xf6, 0x2b, 0x3c, 0x80, 0xda, 0x2d, 0x9d, 0x72, 0x01,
    0x84, 0xa5, 0x1a, 0xbb, 0xa6, 0xfa, 0x73, 0x83, 0x82, 0x6c, 0x74, 0x8f,
    0xed, 0x29, 0x7f, 0xd9, 0x14, 0xcc, 0x90, 0xf9, 0xc8, 0x13, 0xea, 0xb3,
    0x3d, 0x96, 0x91, 0x6f, 0x8c, 0x63, 0x2e, 0xc0, 0x1b, 0xb4, 0xd2, 0xa8,
    0x3c, 0x65, 0x33, 0xa5, 0xf1, 0xf9, 0x84
};
static const size_t ACAB_OTA_PUBKEY_DER_LEN = sizeof(ACAB_OTA_PUBKEY_DER);

#endif // ACAB_OTA_PUBKEY_H
