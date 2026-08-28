#pragma once

#include <stddef.h>
#include <stdint.h>

// NOT SHA-256. This mbedtls_md is a deterministic, NON-CRYPTOGRAPHIC stand-in: an FNV-1a seed
// expanded by an LCG into 32 bytes. Production builds link ESP-IDF's real mbedtls; this stub
// emulates exactly one property - "a stable 32-byte function of the input" - which is all
// det_log's key-fingerprint plumbing (gKeyFp, a truncated digest of the at-rest key) needs to
// distinguish one key from another in test_det_log.cpp.
//
// Same hazard the sibling aes.h documents at length: unlabeled fake crypto in this suite has
// already masked injected defects. Any test asserting collision resistance, known SHA-256
// digests, preimage behaviour, or key-separation PROPERTIES (rather than mere key
// distinguishability) must not rely on this stub - swap in a real SHA-256 first, the way aes.h
// swapped in a real AES-256-CTR.
#define MBEDTLS_MD_SHA256 6

struct mbedtls_md_info_t {};

// Deterministic crypto-failure seam for det_log's fail-closed key lifecycle tests. C++17 inline
// storage is shared by the test and the separately compiled production source translation unit.
inline uint32_t acabHostMdFailures = 0;

inline const mbedtls_md_info_t* mbedtls_md_info_from_type(int type) {
    static mbedtls_md_info_t info;
    return type == MBEDTLS_MD_SHA256 ? &info : nullptr;
}

inline int mbedtls_md(const mbedtls_md_info_t* info, const unsigned char* input,
                      size_t length, unsigned char output[32]) {
    if (!info || !input || !output) return -1;
    if (acabHostMdFailures != 0) { acabHostMdFailures--; return -1; }
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < length; i++) hash = (hash ^ input[i]) * 16777619u;
    for (size_t i = 0; i < 32; i++) {
        hash = hash * 1664525u + 1013904223u;
        output[i] = (uint8_t)(hash >> 24);
    }
    return 0;
}
