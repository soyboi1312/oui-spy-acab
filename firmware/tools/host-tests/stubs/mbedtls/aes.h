#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// A REAL AES-256-CTR, not a pass-through.
//
// THIS USED TO BE AN IDENTITY COPY ("the ring tests exercise flash ordering, not AES"), and that
// made the encrypt-at-rest guarantee untestable in the one suite that touches det_log. Proven by
// mutation against the identity version: deleting the cryptPayload() call outright, forcing a
// single reused nonce, and encrypting only 8 of the 52 payload bytes ALL left every check in
// test_det_log.cpp green. The seizure posture in det_log.h ("the detection log can be encrypted at
// rest") therefore had zero automated defence, and the nonce-reuse hazard det_log.cpp flags in
// clearLocked() could not be exercised at all.
//
// Production is unaffected either way: on-device builds link ESP-IDF's real mbedtls. The point of
// a real cipher here is that the host tests can now assert the two properties that matter and see
// them FAIL when the production code stops holding them up:
//   - no plaintext field survives into the raw partition image, and
//   - two records under one key never share a keystream.
//
// Encrypt-only on purpose: CTR is symmetric, so det_log's decrypt path is the same call.
// Verified against FIPS-197 C.3 (AES-256 ECB) and NIST SP 800-38A F.5.5 (CTR-AES256.Encrypt);
// test_det_log.cpp re-runs the SP 800-38A vector at startup so a broken cipher here cannot make
// the flash-plaintext assertions pass for the wrong reason.
struct mbedtls_aes_context {
    uint8_t rk[15][16];   // round keys: initial AddRoundKey + 14 rounds
    bool    ready;
};

inline const uint8_t acabHostAesSbox[256] = {
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16};

// Multiply by x in GF(2^8), modulo the AES polynomial.
inline uint8_t acabHostAesXtime(uint8_t a) {
    return (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1b : 0x00));
}

inline void mbedtls_aes_init(mbedtls_aes_context* ctx) {
    if (ctx) memset(ctx, 0, sizeof(*ctx));
}
inline void mbedtls_aes_free(mbedtls_aes_context* ctx) {
    if (ctx) memset(ctx, 0, sizeof(*ctx));
}

// AES-256 key schedule: 60 words, Nk=8, Nr=14. Only the 256-bit size is accepted, matching the
// real call site (det_log.cpp always passes 256), so a wrong key length still fails loudly here.
inline int mbedtls_aes_setkey_enc(mbedtls_aes_context* ctx, const unsigned char* key,
                                  unsigned int bits) {
    if (!ctx || !key || bits != 256) return -1;
    uint8_t w[60][4];
    for (int i = 0; i < 8; i++)
        for (int b = 0; b < 4; b++) w[i][b] = key[i * 4 + b];
    uint8_t rcon = 1;
    for (int i = 8; i < 60; i++) {
        uint8_t t[4] = { w[i - 1][0], w[i - 1][1], w[i - 1][2], w[i - 1][3] };
        if (i % 8 == 0) {                       // RotWord + SubWord + Rcon
            const uint8_t first = t[0];
            t[0] = acabHostAesSbox[t[1]];
            t[1] = acabHostAesSbox[t[2]];
            t[2] = acabHostAesSbox[t[3]];
            t[3] = acabHostAesSbox[first];
            t[0] ^= rcon;
            rcon = acabHostAesXtime(rcon);
        } else if (i % 8 == 4) {                // AES-256 only: an extra SubWord at the half-step
            for (int b = 0; b < 4; b++) t[b] = acabHostAesSbox[t[b]];
        }
        for (int b = 0; b < 4; b++) w[i][b] = (uint8_t)(w[i - 8][b] ^ t[b]);
    }
    for (int r = 0; r < 15; r++)
        for (int c = 0; c < 16; c++) ctx->rk[r][c] = w[r * 4 + c / 4][c % 4];
    ctx->ready = true;
    return 0;
}

// One 16-byte block, column-major state (byte i is state[i % 4][i / 4]).
inline void acabHostAesEncryptBlock(const mbedtls_aes_context* ctx, const uint8_t in[16],
                                    uint8_t out[16]) {
    uint8_t s[16];
    for (int i = 0; i < 16; i++) s[i] = (uint8_t)(in[i] ^ ctx->rk[0][i]);
    for (int round = 1; round <= 14; round++) {
        for (int i = 0; i < 16; i++) s[i] = acabHostAesSbox[s[i]];
        uint8_t shifted[16];                                     // ShiftRows: row r left by r
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) shifted[r + 4 * c] = s[r + 4 * ((c + r) % 4)];
        memcpy(s, shifted, 16);
        if (round != 14) {                                       // no MixColumns in the last round
            for (int c = 0; c < 4; c++) {
                uint8_t* a = s + 4 * c;
                const uint8_t a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
                const uint8_t all = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);
                a[0] = (uint8_t)(a0 ^ all ^ acabHostAesXtime((uint8_t)(a0 ^ a1)));
                a[1] = (uint8_t)(a1 ^ all ^ acabHostAesXtime((uint8_t)(a1 ^ a2)));
                a[2] = (uint8_t)(a2 ^ all ^ acabHostAesXtime((uint8_t)(a2 ^ a3)));
                a[3] = (uint8_t)(a3 ^ all ^ acabHostAesXtime((uint8_t)(a3 ^ a0)));
            }
        }
        for (int i = 0; i < 16; i++) s[i] ^= ctx->rk[round][i];
    }
    memcpy(out, s, 16);
}

// Same contract as mbedtls: nc_off carries the offset into stream_block across calls, the counter
// increments big-endian over the whole 16-byte block, and encrypt == decrypt.
inline int mbedtls_aes_crypt_ctr(mbedtls_aes_context* ctx, size_t length, size_t* nc_off,
                                 unsigned char nonce_counter[16], unsigned char stream_block[16],
                                 const unsigned char* input, unsigned char* output) {
    if (!ctx || !ctx->ready || !nc_off || !nonce_counter || !stream_block) return -1;
    if (!input || !output) return -1;
    size_t n = *nc_off;
    if (n > 15) return -1;
    for (size_t i = 0; i < length; i++) {
        if (n == 0) {
            acabHostAesEncryptBlock(ctx, nonce_counter, stream_block);
            for (int b = 15; b >= 0; b--) if (++nonce_counter[b] != 0) break;
        }
        output[i] = (unsigned char)(input[i] ^ stream_block[n]);
        n = (n + 1) & 0x0F;
    }
    *nc_off = n;
    return 0;
}
