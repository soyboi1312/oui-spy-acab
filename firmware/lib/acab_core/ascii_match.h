/*
 * ACAB - shared ASCII-in-bytes matching.
 *
 * BLE carries 128-bit UUIDs and service data little-endian, so an ASCII-encoded tag
 * (like Axon's "BWCDEVICE", or the "reelyActive"-style UUIDs seen in the wild) often
 * only reads right when the bytes are reversed. This helper searches a raw byte
 * buffer for an ASCII needle case-insensitively, in BOTH byte orders.
 *
 * Shared so every detector can text-match service-data / 128-bit-UUID payloads, not
 * just Axon - a service-data tag is MAC-independent, so it survives the BLE MAC
 * randomization that breaks OUI matching.
 */
#ifndef ACAB_ASCII_MATCH_H
#define ACAB_ASCII_MATCH_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
// NO <ctype.h>, deliberately. tolower() folds by the C locale, and BOTH matchers below must agree
// with each other and with the firmware no matter what locale a host test happens to run under -
// tr_TR, for one, maps 'I' outside a-z, which would quietly stop "BWCDEVICE" from matching. The
// A-Z fold here is the only fold this header uses.
static inline char acabAsciiLower(uint8_t c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : (char)c;
}

// C-string sibling: case-insensitive substring over an already-parsed (NUL-terminated)
// name, so no dependence on GNU strcasestr. The case fold maps A-Z only - deliberately
// locale-blind, matching this header's ASCII scope - so host tests and firmware agree no
// matter what locale the host runs under. Every needle in this codebase is plain ASCII
// (letters/digits/space/hyphen) and every haystack is acabSanitizeAscii-clamped, so the
// narrow fold loses nothing. Shared here because three detectors had drifting local copies.
static inline bool acabAsciiCiContains(const char* hay, const char* needle) {
    if (!hay || !needle || !*needle) return false;
    for (const char* p = hay; *p; p++) {
        const char* a = p; const char* b = needle;
        while (*a && *b) {
            if (acabAsciiLower((uint8_t)*a) != acabAsciiLower((uint8_t)*b)) break;
            a++; b++;
        }
        if (!*b) return true;
    }
    return false;
}

static inline bool acabBytesContainAscii(const uint8_t* buf, uint8_t len, const char* needle) {
    if (!buf || !needle || !*needle) return false;
    size_t nl = strlen(needle);
    if (len < nl) return false;
    for (uint8_t i = 0; i + nl <= len; i++) {           // forward
        size_t k = 0;
        while (k < nl && acabAsciiLower(buf[i + k]) == acabAsciiLower((uint8_t)needle[k])) k++;
        if (k == nl) return true;
    }
    for (uint8_t i = 0; i + nl <= len; i++) {           // reversed (little-endian UUID / svc-data)
        size_t k = 0;
        while (k < nl && acabAsciiLower(buf[len - 1 - (i + k)]) == acabAsciiLower((uint8_t)needle[k])) k++;
        if (k == nl) return true;
    }
    return false;
}

#endif // ACAB_ASCII_MATCH_H
