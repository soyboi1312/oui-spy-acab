/*
 * ACAB - structural decoding of 16-bit identifiers out of a BLE advertisement.
 *
 * WHY THIS EXISTS. The detectors used to reach service-UUID evidence by concatenating the payload
 * bytes of several AD types into one flat buffer and then SEARCHING it (see the `svc[48]` field in
 * axon_detect.cpp's parseAdv). That works for an ASCII tag like "BWCDEVICE", and it is the wrong
 * tool for a 16-bit UUID: a two-byte needle will hit anywhere those bytes happen to fall, including
 * across the boundary between two concatenated structures, inside a 128-bit UUID, or in the payload
 * of unrelated service data. The match then reads as "this vendor's equipment" on a coincidence.
 *
 * It also missed AD types 0x02 and 0x03 entirely, the incomplete and complete 16-bit service-UUID
 * lists, which is where a device is most likely to advertise a registered UUID in the first place.
 * So a Bluetooth SIG assignment could sit in plain sight in the advert and match nothing.
 *
 * This header decodes the AD structures properly and compares whole 16-bit values at their real
 * offsets. Same evidence, no accidental hits.
 *
 * WHAT A MATCH MEANS. A SIG 16-bit UUID or company identifier is issued to the PRODUCT VENDOR,
 * unlike a MAC OUI, which names whoever made the radio module and is shared across millions of
 * unrelated devices. So a hit is good evidence of WHOSE equipment it is, and no evidence at all of
 * WHICH product. Label accordingly: "<vendor> equipment", never a device class, until a field
 * capture ties a specific value to a specific product.
 *
 * Deliberately free of Arduino, NimBLE and FreeRTOS so the host tests can exercise it directly.
 */
#ifndef ACAB_BLE_ADV16_H
#define ACAB_BLE_ADV16_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// AD types carrying 16-bit UUIDs. 0x02/0x03 are the incomplete/complete SERVICE UUID lists,
// 0x14 is the 16-bit SOLICITATION list (a device asking for a service, which is itself a useful
// tell), and 0x16 is SERVICE DATA whose first two bytes are the UUID and the rest is payload.
#define ACAB_AD_UUID16_INCOMPLETE  0x02
#define ACAB_AD_UUID16_COMPLETE    0x03
#define ACAB_AD_UUID16_SOLICIT     0x14
#define ACAB_AD_SERVICE_DATA_16    0x16
#define ACAB_AD_MANUFACTURER       0xFF

/// Call `fn(uuid, adType, ctx)` for every 16-bit UUID the advert structurally contains.
/// Returns the number of UUIDs visited. Malformed adverts stop the walk rather than over-read:
/// a zero length or a structure claiming to run past the buffer ends it.
static inline size_t acabAdvForEachUuid16(const uint8_t* adv, size_t len,
                                          void (*fn)(uint16_t, uint8_t, void*), void* ctx) {
    if (!adv || !fn) return 0;
    size_t seen = 0, i = 0;
    while (i + 1 < len) {
        const uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + (size_t)adLen > len) break;
        const uint8_t  adType  = adv[i + 1];
        const uint8_t* data    = &adv[i + 2];
        const uint8_t  dataLen = (uint8_t)(adLen - 1);
        if (adType == ACAB_AD_UUID16_INCOMPLETE || adType == ACAB_AD_UUID16_COMPLETE ||
            adType == ACAB_AD_UUID16_SOLICIT) {
            // A LIST: two little-endian bytes per entry. A trailing odd byte is malformed and
            // is skipped rather than half-read.
            for (uint8_t o = 0; (uint8_t)(o + 1) < dataLen; o = (uint8_t)(o + 2)) {
                fn((uint16_t)data[o] | ((uint16_t)data[o + 1] << 8), adType, ctx);
                seen++;
            }
        } else if (adType == ACAB_AD_SERVICE_DATA_16 && dataLen >= 2) {
            // SERVICE DATA: exactly ONE UUID, in the first two bytes. The remaining bytes are
            // vendor payload and must never be scanned for UUIDs, which is the specific
            // false-positive the flat-buffer search used to allow.
            fn((uint16_t)data[0] | ((uint16_t)data[1] << 8), adType, ctx);
            seen++;
        }
        i += 1 + (size_t)adLen;
    }
    return seen;
}

struct AcabUuid16Probe { uint16_t want; bool found; uint8_t foundIn; };
static inline void acabUuid16ProbeCb(uint16_t u, uint8_t adType, void* ctx) {
    AcabUuid16Probe* p = (AcabUuid16Probe*)ctx;
    if (!p->found && u == p->want) { p->found = true; p->foundIn = adType; }
}

/// True when the advert structurally advertises `uuid` as a 16-bit service UUID. When non-null,
/// `*foundInAdType` receives which AD type carried it, because "advertised in a service list"
/// and "present as service data" are different claims about the device and worth keeping apart
/// in a capture.
static inline bool acabAdvHasUuid16(const uint8_t* adv, size_t len, uint16_t uuid,
                                    uint8_t* foundInAdType) {
    AcabUuid16Probe p; p.want = uuid; p.found = false; p.foundIn = 0;
    acabAdvForEachUuid16(adv, len, acabUuid16ProbeCb, &p);
    if (foundInAdType) *foundInAdType = p.foundIn;
    return p.found;
}

/// Call `fn(companyId, ctx)` for EVERY manufacturer-specific structure in the advert.
/// detection.h's acabBleCompanyId returns only the first; an advert may legitimately carry more
/// than one, and stopping at the first is how a vendor identifier in a later structure is missed.
static inline size_t acabAdvForEachCompanyId(const uint8_t* adv, size_t len,
                                             void (*fn)(uint16_t, void*), void* ctx) {
    if (!adv || !fn) return 0;
    size_t seen = 0, i = 0;
    while (i + 1 < len) {
        const uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + (size_t)adLen > len) break;
        if (adv[i + 1] == ACAB_AD_MANUFACTURER && adLen >= 3) {
            fn((uint16_t)adv[i + 2] | ((uint16_t)adv[i + 3] << 8), ctx);
            seen++;
        }
        i += 1 + (size_t)adLen;
    }
    return seen;
}

struct AcabCidProbe { uint16_t want; bool found; };
static inline void acabCidProbeCb(uint16_t c, void* ctx) {
    AcabCidProbe* p = (AcabCidProbe*)ctx;
    if (c == p->want) p->found = true;
}

/// True when ANY manufacturer structure in the advert carries `cid`.
static inline bool acabAdvHasCompanyId(const uint8_t* adv, size_t len, uint16_t cid) {
    AcabCidProbe p; p.want = cid; p.found = false;
    acabAdvForEachCompanyId(adv, len, acabCidProbeCb, &p);
    return p.found;
}

#endif // ACAB_BLE_ADV16_H
