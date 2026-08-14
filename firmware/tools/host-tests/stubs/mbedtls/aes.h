#pragma once

#include <stddef.h>
#include <stdint.h>

struct mbedtls_aes_context {
    uint8_t key[32];
};

inline void mbedtls_aes_init(mbedtls_aes_context*) {}
inline void mbedtls_aes_free(mbedtls_aes_context*) {}
inline int mbedtls_aes_setkey_enc(mbedtls_aes_context* ctx, const unsigned char* key,
                                  unsigned int bits) {
    if (!ctx || !key || bits != 256) return -1;
    for (size_t i = 0; i < 32; i++) ctx->key[i] = key[i];
    return 0;
}

// The ring tests exercise flash ordering and cursor invariants, not AES. A no-op is
// still symmetric, so production encrypt/decrypt call sites and record validation run.
inline int mbedtls_aes_crypt_ctr(mbedtls_aes_context*, size_t length, size_t*,
                                 unsigned char[16], unsigned char[16],
                                 const unsigned char* input, unsigned char* output) {
    if (!input || !output) return -1;
    if (input != output) {
        for (size_t i = 0; i < length; i++) output[i] = input[i];
    }
    return 0;
}
