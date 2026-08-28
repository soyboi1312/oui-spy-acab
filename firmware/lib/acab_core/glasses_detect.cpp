/*
 * ACAB - Smart / recording-glasses detector implementation.
 *
 * THREE MATCH SURFACES, all payload-borne so they survive BLE MAC randomization (which is
 * the whole point: real glasses use rotating resolvable private addresses, so no OUI list
 * can ever find them). Every surface is scored and the HIGHEST-confidence hit wins. Order only
 * decides TIES: the comparison is `<=`, so an equal-confidence later surface does not displace
 * an earlier one. First-listed wins a tie, deliberately. The surfaces:
 *   1. The 128-bit HeyCyan SDK service UUID (AD 0x06/0x07/0x21). Names the glasses SOFTWARE,
 *      so it carries none of the Quest / earbud ambiguity the corporate IDs do.
 *   2. 16-bit SIG MEMBER service UUIDs (AD 0x02/0x03/0x16). A SEPARATE namespace from company
 *      IDs, easily confused with them: 0xFEB7 is not company ID 0xFEB7.
 *   3. The manufacturer-data company ID (AD 0xFF), first two payload bytes, LITTLE-ENDIAN per
 *      the BLE spec (data[0] = low byte), against the table in glasses_signatures.h.
 * Surfaces 1 and 2 need no manufacturer data at all, which is why they run above the
 * !haveMfg bail: an advert can carry a UUID list and no 0xFF record whatsoever.
 *
 * Quest disambiguation: for the Meta corporate IDs (shared with the Meta Quest VR
 * headset) we also look for the "META_RB_GLASS" ASCII token in the manufacturer data.
 * When it is present, the hit is confirmed glasses (higher confidence, no Quest caveat).
 * When it is absent, shared corporate IDs (Quest / TCL-phone overlap) do NOT emit at
 * all in shipped builds: a Quest advertises from a rotating private address, so a bare
 * shared-ID match re-alerts on every rotation and the exact-MAC Ignore can never
 * silence it. CAPTURE-PENDING: the token's on-wire framing is unverified, so it is
 * only ever a confidence bump, never a standalone match.
 */
#include "glasses_detect.h"
#include "glasses_signatures.h"
#include "ascii_match.h"     // shared acabBytesContainAscii (META_RB_GLASS token, both byte orders)
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <string.h>
#include <stdio.h>
#include <Preferences.h>   // persist the on/off toggle across reboots (NVS)

static bool gEnabled = true;   // default ON: the company-ID match is specific, not a flood risk

// Bare matches on SHARED corporate IDs (sharedId in glasses_signatures.h) are compile-time
// OFF: 0x058E is also the Meta Quest's own registration, and a Quest's rotating private
// address defeats dedup and per-MAC ignore, so a household Quest would beep forever with
// no way to mute it short of disabling the whole category. Build-time only, deliberately
// no setter / NVS / BLE toggle: flip it only after a field-verified payload discriminator
// exists (the META_RB_GLASS token path below stays live regardless of this flag).
static const bool kGlassesSharedIdsEnabled = false;

// NVS-backed so an app-set toggle survives a reboot. Only writes on a real change
// (toggles are rare), so flash wear is negligible.
void glassesSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p;
    p.begin("acab-glass", false);
    p.putBool("on", enabled);
    p.end();
}
bool glassesIsEnabled() { return gEnabled; }

// Restore the persisted on/off (or `defaultEnabled` if never set). Call once in setup()
// instead of hard-coding the default, so a board remembers an app-set toggle across
// power cycles.
void glassesRestoreEnabled(bool defaultEnabled) {
    Preferences p;
    p.begin("acab-glass", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// Pull out the manufacturer-specific data (AD type 0xFF) plus any 128-bit service UUIDs.
// The service-UUID half was added 2026-07-31 for the HeyCyan SDK UUID; it mirrors the
// collection axon_detect.cpp already does for the BWCDEVICE tag, deliberately, so both
// detectors accumulate advert payload the same way.
struct GlAdv {
    uint16_t mfgId;     bool haveMfg;
    const uint8_t* mfg; uint8_t mfgLen;   // includes the 2 company-id bytes
    uint8_t svc[64];    uint8_t svcLen;   // concatenated 128-bit service UUID / service-data bytes
    uint16_t u16[12];   uint8_t u16Len;   // 16-bit SIG member UUIDs (AD 0x02/0x03 lists, 0x16 data)
};

static void parseAdv(const uint8_t* adv, size_t len, GlAdv* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;
        if (adType == 0xFF && dataLen >= 2 && !f->haveMfg) {
            // BLE company ID is little-endian: low byte first.
            f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
            f->mfg = data; f->mfgLen = dataLen; f->haveMfg = true;
        } else if (adType == 0x02 || adType == 0x03) {
            // 16-bit service-UUID list (incomplete/complete): a packed array of LE u16.
            for (uint8_t k = 0; k + 1 < dataLen && f->u16Len < 12; k += 2)
                f->u16[f->u16Len++] = (uint16_t)data[k] | ((uint16_t)data[k + 1] << 8);
        } else if (adType == 0x16) {
            // Service DATA, 16-bit UUID: only the first 2 bytes are the UUID, the rest is
            // payload. Taking the whole record as UUIDs here would invent identifiers out
            // of arbitrary service-data bytes, which is exactly how a table like this
            // starts producing phantom matches.
            if (dataLen >= 2 && f->u16Len < 12)
                f->u16[f->u16Len++] = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
        } else if (adType == 0x06 || adType == 0x07 ||   // 128-bit service-UUID list (partial/complete)
                   adType == 0x21) {                      // service data, 128-bit UUID
            // Append, clamped. Concatenating separate AD structures can in principle create a
            // false 16-byte span across a boundary, but that needs 16 specific bytes to line
            // up exactly across two records - not a realistic collision, and the same
            // trade-off axon_detect already accepts for its tag search.
            uint8_t room = (uint8_t)(sizeof(f->svc) - f->svcLen);
            uint8_t n = dataLen < room ? dataLen : room;
            memcpy(f->svc + f->svcLen, data, n);
            f->svcLen = (uint8_t)(f->svcLen + n);
        }
        i += 1 + adLen;
    }
}

// Exact 16-byte search. MUST stay an exact full-length match, never a prefix: this UUID
// shares its whole base with Apple's ANCS (7905F431-...), so a partial match would fire on
// every notification-consuming wearable. See the warning in glasses_signatures.h.
static bool svcHasUuid(const uint8_t* hay, uint8_t hayLen, const uint8_t* needle) {
    if (hayLen < GLASSES_HEYCYAN_UUID_LEN) return false;
    for (uint8_t i = 0; i + GLASSES_HEYCYAN_UUID_LEN <= hayLen; i++)
        if (memcmp(hay + i, needle, GLASSES_HEYCYAN_UUID_LEN) == 0) return true;
    return false;
}

bool glassesClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out) {
    if ((!gEnabled && !desertIsEnabled()) || !adv || !advLen) return false;

    GlAdv f; parseAdv(adv, advLen, &f);

    // THREE MATCH SURFACES, and we keep the BEST rather than the FIRST.
    //
    // Returning on the first hit was wrong: an advert carrying both a 16-bit member UUID
    // (0xFEB7, conf 45) AND the company ID with the META_RB_GLASS token (conf 72) would emit
    // at 45 with the Quest caveat, because the UUID loop ran first and returned. The token is
    // the strongest evidence we have that a Meta device is glasses rather than a headset, so
    // letting a weaker surface preempt it defeated the point of checking for it at all.
    // Score-and-keep costs one stack AcabDetection and stops a weaker surface preempting a
    // stronger one. It does NOT make surface order free: every comparison below is `<=`, so on a
    // tie the FIRST surface evaluated wins (an equal-confidence later surface is skipped), and
    // docs/signatures.md publishes that evaluation order as the contract a reimplementer follows
    // to emit the same `meth` - it says the same, as does this file's header. Reordering these
    // loops silently changes `meth` on any advert carrying two equal-confidence surfaces.
    AcabDetection best; int bestConf = -1;

    // HeyCyan SDK service UUID: identifies the glasses SOFTWARE rather than a corporate
    // registrant, so it has none of the Quest / earbud ambiguity the shared company IDs
    // carry, and it needs no manufacturer data at all - an advert can carry a service UUID
    // and no 0xFF record whatsoever, which is why these run above the !haveMfg bail.
    if (f.svcLen && (svcHasUuid(f.svc, f.svcLen, GLASSES_HEYCYAN_UUID_LE) ||
                     svcHasUuid(f.svc, f.svcLen, GLASSES_HEYCYAN_UUID_BE))) {
        acabInit(&best, ACAB_GLASSES, SRC_BLE, mac, (int16_t)rssi);
        best.method     = M_SERVICE_DATA;   // 128-bit UUID / service data, payload-borne
        best.confidence = GLASSES_HEYCYAN_CONF;
        snprintf(best.detail, sizeof(best.detail), "HeyCyan glasses UUID");
        bestConf = GLASSES_HEYCYAN_CONF;
    }

    // 16-bit SIG member service UUIDs: the OTHER namespace a vendor can advertise under
    // (see glasses_signatures.h).
    for (uint8_t k = 0; k < f.u16Len; k++) {
        for (size_t i = 0; i < GLASSES_SVC_UUID_COUNT; i++) {
            const GlassesSvcUuid& s = GLASSES_SVC_UUIDS[i];
            if (f.u16[k] != s.uuid) continue;
            if (s.sharedId && !kGlassesSharedIdsEnabled) continue;   // Quest-registrant UUIDs stay gated
            if ((int)s.confidence <= bestConf) continue;
            acabInit(&best, ACAB_GLASSES, SRC_BLE, mac, (int16_t)rssi);
            // A UUID LIST entry, not service data: the wire method has its own value, which
            // both apps and docs/ble-protocol.md already define.
            best.method     = M_SERVICE_UUID;
            best.confidence = s.confidence;
            snprintf(best.detail, sizeof(best.detail), "%s", s.detail);
            bestConf = s.confidence;
        }
    }

    if (!f.haveMfg) {
        if (bestConf < 0) return false;
        *out = best;
        return true;
    }

    for (size_t i = 0; i < GLASSES_SIG_COUNT; i++) {
        const GlassesSig& s = GLASSES_SIGS[i];
        if (f.mfgId != s.companyId) continue;

        // For the Meta corporate IDs (shared with the Quest), the META_RB_GLASS token in
        // the manufacturer data confirms glasses over a VR headset. Token search skips
        // the 2 company-id bytes.
        bool tokenConfirmed = s.metaShared && f.mfgLen > 2 &&
            acabBytesContainAscii(f.mfg + 2, (uint8_t)(f.mfgLen - 2), GLASSES_META_TOKEN);

        // Shared corporate IDs (Quest / TCL phones) only emit when the token confirms
        // glasses; a bare shared-ID hit is a Quest-shaped false alarm (see the gate above).
        if (s.sharedId && !kGlassesSharedIdsEnabled && !tokenConfirmed) continue;

        // Score against the UUID surfaces rather than overwriting them: the token-confirmed
        // tier (72) must be able to beat a 45-confidence member-UUID hit on the same advert,
        // and an eyewear-only company ID (70) must not be demoted by one either.
        const uint8_t conf = tokenConfirmed ? GLASSES_META_CONFIRMED_CONF : s.confidence;
        if ((int)conf <= bestConf) continue;
        acabInit(&best, ACAB_GLASSES, SRC_BLE, mac, (int16_t)rssi);
        best.method     = M_MFG_ID;   // company ID in the payload; survives MAC randomization
        best.confidence = conf;
        if (tokenConfirmed) snprintf(best.detail, sizeof(best.detail), "Ray-Ban Meta: recording glasses");
        else                snprintf(best.detail, sizeof(best.detail), "%s", s.detail);
        bestConf = conf;
    }

    if (bestConf < 0) return false;
    *out = best;
    return true;
}
