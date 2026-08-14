#pragma once

#include <stddef.h>
#include <stdint.h>

#define MBEDTLS_MD_SHA256 6

struct mbedtls_md_info_t {};

inline const mbedtls_md_info_t* mbedtls_md_info_from_type(int type) {
    static mbedtls_md_info_t info;
    return type == MBEDTLS_MD_SHA256 ? &info : nullptr;
}

inline int mbedtls_md(const mbedtls_md_info_t* info, const unsigned char* input,
                      size_t length, unsigned char output[32]) {
    if (!info || !input || !output) return -1;
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < length; i++) hash = (hash ^ input[i]) * 16777619u;
    for (size_t i = 0; i < 32; i++) {
        hash = hash * 1664525u + 1013904223u;
        output[i] = (uint8_t)(hash >> 24);
    }
    return 0;
}
