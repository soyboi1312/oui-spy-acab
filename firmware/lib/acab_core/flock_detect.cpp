/*
 * ACAB - Flock Safety detector implementation.
 * Matching logic only; the signature tables are in flock_signatures.h, sourced
 * from public registries and research (see docs/signatures.md).
 */
#include "flock_detect.h"
#include "flock_signatures.h"
#include "acab_scanner.h"    // acabSanitizeAscii: clamp attacker-sourced names on ingest
#include "ascii_match.h"     // shared acabAsciiCiContains (case-insensitive name substring)
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <Preferences.h>     // persist the Flock/ALPR toggle across reboots (NVS)
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// Master on/off (default ON, field-validated). NVS-backed so an app-set Flock/ALPR
// toggle survives a reboot (mirrors axon/tracker/glasses).
static bool gEnabled = true;
void flockSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-flock", false); p.putBool("on", enabled); p.end();
}
bool flockIsEnabled() { return gEnabled; }

// Reload the persisted toggle on boot; if none saved yet, use defaultEnabled.
void flockRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-flock", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// ---------------------------------------------------------------------------
// Signature tables now live in flock_signatures.h (public-sourced; see
// docs/signatures.md). Retune detection by editing that header; this file is
// matching logic only.
// ---------------------------------------------------------------------------
// Compile-time only: no setter, no NVS restore, no BLE toggle. ext=1 table entries are
// therefore NOT a user-enableable tier - they are removed-until-validated candidates
// kept in the tables purely as a provenance record.
static bool gFlockExtendedOui = false;

// True only for the vendor-specific Raven UUIDs (0x31xx-0x35xx), not the generic BT SIG ones.
static bool isRavenVendorSvc(uint16_t u) {
    return u == RAVEN_SVC_GPS || u == RAVEN_SVC_POWER || u == RAVEN_SVC_NETWORK ||
           u == RAVEN_SVC_UPLOAD || u == RAVEN_SVC_ERROR;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static bool ouiMatch(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;   // skip locally-administered / random MACs (no real OUI)
    for (size_t i = 0; i < FLOCK_OUI_COUNT; i++) {
        if (mac[0] == FLOCK_OUI[i].b[0] && mac[1] == FLOCK_OUI[i].b[1] &&
            mac[2] == FLOCK_OUI[i].b[2]) {
            if (FLOCK_OUI[i].ext && !gFlockExtendedOui) continue;  // extended-only
            return true;
        }
    }
    return false;
}

// Falcon cameras' Liteon WiFi-module OUIs (probe-request matched - see
// flockClassifyWiFi). Same random-MAC guard as ouiMatch.
static bool falconWifiOui(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;
    for (size_t i = 0; i < FALCON_WIFI_OUI_COUNT; i++) {
        if (mac[0] == FALCON_WIFI_OUI[i].b[0] && mac[1] == FALCON_WIFI_OUI[i].b[1] &&
            mac[2] == FALCON_WIFI_OUI[i].b[2]) {
            if (FALCON_WIFI_OUI[i].ext && !gFlockExtendedOui) continue;   // non-shipping candidate (compiled out; no runtime toggle)
            return true;
        }
    }
    return false;
}

// case-insensitive substring: shared acabAsciiCiContains (ascii_match.h)

// case-insensitive prefix; returns the tail (name past the prefix) on a hit
static const char* ciPrefix(const char* name, const char* prefix) {
    const char* a = name; const char* b = prefix;
    while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
    return *b ? NULL : a;
}

// case-insensitive suffix test (e.g. an SSID ending in "-FALCON")
static bool ciEndsWith(const char* s, const char* suf) {
    if (!s || !suf) return false;
    size_t ls = strlen(s), lf = strlen(suf);
    if (lf == 0 || lf > ls) return false;
    const char* a = s + (ls - lf); const char* b = suf;
    while (*b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
    return *b == 0;
}

// The "*-FALCON" SSID rule, behind the SAME ext gate as an unvalidated OUI row: retired to
// ext=1 on 2026-08-25 because its only evidence was this firmware's own diagnostic label read
// back out of a capture as though it were a broadcast SSID. Full account, and what a capture
// would have to show to ship it, at FLOCK_SSID_FALCON_SUFFIX in flock_signatures.h.
// gFlockExtendedOui is compile-time false, so both call sites fold away in every build.
static bool falconSsidSuffix(const char* ssid) {
    if (FLOCK_SSID_FALCON_SUFFIX_EXT && !gFlockExtendedOui) return false;
    return ciEndsWith(ssid, FLOCK_SSID_FALCON_SUFFIX);
}

// Anchored name matching (see FLOCK_NAME_PATTERNS in flock_signatures.h).
//   NM_NONE     no pattern hit
//   NM_LITERAL  "FS Ext Battery" - specific enough to rank strong on its own
//   NM_ANCHORED "Penguin-"+digits / "FS-"+hex - the documented structural forms, but
//               generic enough ("FS-100" is common white-label naming) that ranking
//               strong needs a co-signal; hint-grade otherwise
//   NM_LOOSE    bare "Flock" prefix - hint-grade unless a co-signal backs it
// The substring-anywhere matching this replaces flagged any "FS-100" speaker or a
// phone named "penguins fan" as a strong ALPR hit.
enum { NM_NONE = 0, NM_LITERAL, NM_ANCHORED, NM_LOOSE };
static int nameMatch(const char* name) {
    if (!name || !name[0]) return NM_NONE;
    for (size_t i = 0; i < FLOCK_NAME_COUNT; i++) {
        const FlockNamePat& p = FLOCK_NAME_PATTERNS[i];
        switch (p.form) {
            case FLOCK_NAME_LITERAL:
                if (acabAsciiCiContains(name, p.pat)) return NM_LITERAL;
                break;
            case FLOCK_NAME_PREFIX_DIGITS: {
                const char* t = ciPrefix(name, p.pat);
                if (t && *t) {
                    bool ok = true;
                    for (; *t; t++) if (!isdigit((unsigned char)*t)) { ok = false; break; }
                    if (ok) return NM_ANCHORED;
                }
                break;
            }
            case FLOCK_NAME_PREFIX_HEX: {
                const char* t = ciPrefix(name, p.pat);
                if (t && *t) {
                    bool ok = true;
                    for (; *t; t++) if (!isxdigit((unsigned char)*t)) { ok = false; break; }
                    if (ok) return NM_ANCHORED;
                }
                break;
            }
            case FLOCK_NAME_PREFIX:
                if (ciPrefix(name, p.pat)) return NM_LOOSE;
                break;
        }
    }
    // Bare 10-digit-name matching removed 2026-06-18: in the field it false-
    // positived on rotating/private BLE addresses with placeholder numeric names (a
    // phone advertising "0102000000", not a camera). The specific Flock signatures
    // (Penguin / FS / 0x09C8 / Flock- SSID / b4:1e:52) stay. Reconsider 10-digit
    // matching only with independent Flock-specific evidence; a public address
    // alone cannot establish that identity.
    return NM_NONE;
}

// ---------------------------------------------------------------------------
// BLE advertisement AD-structure parser.
// Pulls out the name, manufacturer company id, and the 16-bit service UUIDs.
// ---------------------------------------------------------------------------
struct AdvFields {
    char     name[40];
    bool     haveName;
    uint16_t mfgId;
    bool     haveMfg;
    uint16_t svc16[16];   // up to 16 short service UUIDs
    uint8_t  svcCount;
    bool     raven_gps, raven_power, raven_oldloc;
    // Evidence must displace proximity (mark_table.h): the Raven checks run on every UUID in the
    // advert, BEFORE the 16-entry svc16 cap, so an advert that packs 16 unrelated UUIDs ahead of a
    // Raven vendor UUID cannot silently drop the one entry that carries the evidence.
    bool     ravenVendor;
};

static void parseAdv(const uint8_t* adv, size_t len, AdvFields* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;

        switch (adType) {
            case 0x08: // shortened local name
            case 0x09: // complete local name
                if (!f->haveName) {
                    // clamp the attacker-controlled advertised name to printable ASCII on ingest
                    // (same invariant as the other ingest paths), not a raw memcpy.
                    acabSanitizeAscii(f->name, data, dataLen, sizeof(f->name));
                    f->haveName = true;
                }
                break;
            case 0xFF: // manufacturer specific data: [company_id LE][...]
                if (dataLen >= 2 && !f->haveMfg) {
                    f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
                    f->haveMfg = true;
                }
                break;
            case 0x02: // incomplete list of 16-bit service UUIDs
            case 0x03: // complete list of 16-bit service UUIDs
                for (uint8_t k = 0; k + 1 < dataLen; k += 2) {
                    uint16_t u = (uint16_t)data[k] | ((uint16_t)data[k+1] << 8);
                    if (f->svcCount < 16) f->svc16[f->svcCount++] = u;
                    if (isRavenVendorSvc(u)) f->ravenVendor = true;
                    if (u == RAVEN_SVC_GPS)    f->raven_gps = true;
                    if (u == RAVEN_SVC_POWER)  f->raven_power = true;
                    if (u == RAVEN_SVC_OLDLOC) f->raven_oldloc = true;
                }
                break;
            case 0x06: // incomplete list of 128-bit service UUIDs
            case 0x07: { // complete list of 128-bit service UUIDs
                // Raven advertises its services in 128-bit form, which the 16-bit
                // walk above never sees - so Ravens used to fall through to a
                // camera OUI/name match. Each UUID is 16 bytes, little-endian, and
                // Raven's all sit on the Bluetooth base UUID
                // (0000xxxx-0000-1000-8000-00805f9b34fb), so match that LE prefix
                // and pull the 16-bit short back out for the Raven test below.
                static const uint8_t BT_BASE_LE[12] =
                    { 0xfb,0x34,0x9b,0x5f,0x80,0x00,0x00,0x80,0x00,0x10,0x00,0x00 };
                for (uint8_t k = 0; k + 16 <= dataLen; k += 16) {
                    const uint8_t* u = &data[k];
                    if (memcmp(u, BT_BASE_LE, 12) != 0 || u[14] || u[15]) continue;
                    uint16_t s = (uint16_t)u[12] | ((uint16_t)u[13] << 8);
                    if (f->svcCount < 16) f->svc16[f->svcCount++] = s;
                    if (isRavenVendorSvc(s)) f->ravenVendor = true;
                    if (s == RAVEN_SVC_GPS)    f->raven_gps = true;
                    if (s == RAVEN_SVC_POWER)  f->raven_power = true;
                    if (s == RAVEN_SVC_OLDLOC) f->raven_oldloc = true;
                }
                break;
            }
            default: break;
        }
        i += 1 + adLen;
    }
}

// Rough Raven firmware-family guess from which service UUIDs are present - the
// set changes between Raven generations, so it's only a hint.
static const char* estimateRavenFW(const AdvFields* f) {
    if (f->raven_oldloc && !f->raven_gps) return "1.1.x";
    if (f->raven_gps && !f->raven_power)  return "1.2.x";
    if (f->raven_gps && f->raven_power)   return "1.3.x";
    return "?";
}

// ---------------------------------------------------------------------------
// Public: BLE classifier
// ---------------------------------------------------------------------------
bool flockClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                      int rssi, AcabDetection* out) {
    if (!gEnabled && !desertIsEnabled()) return false;

    AdvFields f;
    if (adv && advLen) parseAdv(adv, advLen, &f);
    else memset(&f, 0, sizeof(f));

    // Set during the AD walk on the raw UUIDs, not derived from svc16, so the 16-entry cap can
    // never hide the evidence (see AdvFields).
    const bool ravenVendor = f.ravenVendor;

    // --- Raven (audio/gunshot detector): most specific, so check it first ---
    if (ravenVendor) {
        acabInit(out, ACAB_FLOCK_RAVEN, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_SERVICE_UUID;
        out->confidence = 92;
        if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
        snprintf(out->detail, sizeof(out->detail), "raven fw %s", estimateRavenFW(&f));
        return true;
    }

    // --- Flock camera: advertised-name pattern (checked before the mfg-ID hint so a
    //     named Flock beacon reports the strong name match, not the weak shared-silicon
    //     one) ---
    int nm = f.haveName ? nameMatch(f.name) : NM_NONE;
    if (nm != NM_NONE) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_NAME;
        // Only the "FS Ext Battery" literal ranks strong on its own. The anchored
        // prefix forms and the loose "Flock" prefix need the 0x09C8 mfg co-signal
        // to rank 80; name-only hits stay hint-grade (70) for every address.
        // A public address does not identify Flock, and mac[0] & 0x02 cannot tell
        // public from random BLE addresses: that requires controller metadata.
        // 0x09C8 is shared XUNTONG silicon; this retains the existing name+mfg tier.
        bool mfgHit = false;
        for (size_t i = 0; f.haveMfg && i < FLOCK_MFG_COUNT; i++)
            if (f.mfgId == FLOCK_MFG_IDS[i]) { mfgHit = true; break; }
        out->confidence = (nm == NM_LITERAL || mfgHit) ? 80 : 70;
        strncpy(out->name, f.name, sizeof(out->name) - 1);
        return true;
    }

    // --- Flock camera: manufacturer ID (XUNTONG) ---
    if (f.haveMfg) {
        for (size_t i = 0; i < FLOCK_MFG_COUNT; i++) {
            if (f.mfgId == FLOCK_MFG_IDS[i]) {
                acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
                out->method = M_MFG_ID;
                // 0x09C8 is a SHARED-silicon company ID (registered to XUNTONG, seen on Flock
                // BT beacons but not exclusive to them) AND unverified against the current SIG
                // registry. Held below 50 so both apps draw their weak-match "verify this"
                // treatment: a bare hit is a hint, not an assertion, and other XUNTONG-module
                // gear would otherwise false-positive as a mid-confidence ALPR camera.
                out->confidence = 45;
                if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
                snprintf(out->detail, sizeof(out->detail), "mfg 0x%04X", f.mfgId);
                return true;
            }
        }
    }

    // --- Flock camera: known OUI (weakest signal - OUIs drift over time) ---
    if (ouiMatch(mac)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_OUI;
        out->confidence = 65;
        if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// Public: WiFi classifier (802.11 management frames)
// Frame layout: [fc(2)][dur(2)][addr1(6)][addr2(6)][addr3(6)][seq(2)]...
// ---------------------------------------------------------------------------
bool flockClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                       AcabDetection* out) {
    if (!gEnabled && !desertIsEnabled()) return false;
    if (!frame || len < 24) return false;

    uint8_t ftype    = (frame[0] >> 2) & 0x3;   // 0 = management
    uint8_t subtype  = (frame[0] >> 4) & 0xF;
    if (ftype != 0x0) return false;

    const uint8_t* addr2 = &frame[10];  // transmitter
    const uint8_t* addr3 = &frame[16];  // BSSID

    // Pull the SSID IE (id 0) if this frame carries one (beacon / probe-resp /
    // probe-req). Read up front, because the SSID is now the primary signal.
    //
    // The IEs do NOT start at the same offset for every subtype, and getting this
    // wrong is silent: a probe request (0x4) has no fixed body, so its IEs begin
    // right after the 24-byte header, but a beacon (0x8) and a probe response (0x5)
    // carry a 12-byte fixed body (timestamp / beacon-interval / capability) first,
    // so theirs begin at 36. Walking a beacon from 24 parses the free-running TSF
    // timestamp as an IE header and random-walks the rest of the frame, which
    // matched a real "Flock-<mac>" AP well under 1% of the time (it only looked fine
    // in the field because the two OUI paths below are probe-request-only, where 24
    // is correct). Do NOT flatten this to a single offset in either direction.
    // Other mgmt subtypes put their IEs somewhere else again (assoc-req 28, auth 30,
    // reassoc-req 34) and none of them carries a Flock-relevant SSID, so skip them
    // outright rather than walk them at an offset that is wrong for them too.
    // desert_detect.cpp does the same offset split on the same buffer.
    char ssid[33] = {0};
    bool sawSSID = false, emptySSID = false;
    if (subtype == 0x4 || subtype == 0x5 || subtype == 0x8) {
        for (size_t ie = (subtype == 0x4) ? 24 : 36; ie + 2 <= len; ) {
            uint8_t id = frame[ie], l = frame[ie + 1];
            if (ie + 2 + l > len) break;
            if (id == 0) {                       // SSID element
                sawSSID = true;
                emptySSID = (l == 0);
                uint8_t n = l < 32 ? l : 32;
                memcpy(ssid, &frame[ie + 2], n);
                ssid[n] = 0;
                break;
            }
            ie += 2 + l;
        }
    }

    // --- Primary: the "Flock-<partial MAC>" AP name is the strong WiFi signature
    //     (src: ryanohoro / GainSec). Match it directly with no OUI gate, since a
    //     camera's WiFi MAC belongs to the module maker, not Flock's own OUI. ---
    // SELF-ATTESTATION ONLY (beacon 0x8 / probe-response 0x5). Corrected 2026-08-05; this is the
    // same defect netcam_detect.cpp fixed in the same round. On a probe REQUEST the SSID IE is the
    // network being SEARCHED FOR and addr2 is the searching station, so the frame attests nothing
    // about the transmitter - which is the whole justification for the 88 tier. Admitting 0x4
    // reported any station with a "Flock-" network saved, on a rotating random MAC, as a Flock
    // CAMERA at 88: a row the app's exact-MAC ignore can never silence. M_SSID also bypasses
    // acabApplyDurability's randomized-address down-cap (which only touches M_OUI), so nothing
    // downstream caught it. The probe-borne form is already graded lower at M_PROBE 72/78 below.
    const bool selfAttested = (subtype == 0x5 || subtype == 0x8);
    size_t pfxLen = strlen(FLOCK_SSID_PREFIX);
    if (selfAttested && sawSSID && !emptySSID && strncmp(ssid, FLOCK_SSID_PREFIX, pfxLen) == 0) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_SSID;
        out->confidence = 88;
        // Attacker-controlled text: clamp on ingest like every other name path, instead of
        // strncpy'ing raw control/high bytes straight into the record.
        acabSanitizeAscii(out->name, (const uint8_t*)ssid, strlen(ssid), sizeof(out->name));
        return true;
    }

    // --- The "*-FALCON" SSID rule. RETIRED TO ext=1 on 2026-08-25 (falconSsidSuffix is
    //     compile-time false), because its evidence turned out to be this firmware's own
    //     diagnostic label read back out of a capture. It is kept, gated, as a provenance record
    //     and as the shape the rule should take if a real capture ever justifies it; the account
    //     and the bar to re-ship live at FLOCK_SSID_FALCON_SUFFIX in flock_signatures.h. ---
    // SELF-ATTESTATION ONLY, same gate as the "Flock-" branch above and for the same reason: on a
    // probe request the SSID names the network being SEARCHED FOR, so the frame attests nothing
    // about the transmitter. The probe-borne form lands in the M_PROBE 72 regrade below.
    if (selfAttested && sawSSID && !emptySSID && falconSsidSuffix(ssid)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_SSID;
        out->confidence = 85;
        acabSanitizeAscii(out->name, (const uint8_t*)ssid, strlen(ssid), sizeof(out->name));
        return true;
    }

    // The probe-request form, REGRADED rather than dropped (2026-08-05). A station asking for
    // "Flock-..." is still a real signal - a Falcon riding as a WiFi client is the documented
    // case, and it is what the 88 branch above used to swallow. But the frame identifies the
    // SEEKER, not the network's owner, so it belongs at the probe tier beside the Falcon-OUI rule
    // below, with a detail that says which it is. Sits after the two self-attestation branches so
    // a beacon/probe-response can never land here.
    // The "*-FALCON" half rides the same ext=1 gate as the branch above, so today only the
    // "Flock-" prefix can reach this tier.
    if (subtype == 0x4 && sawSSID && !emptySSID &&
        (strncmp(ssid, FLOCK_SSID_PREFIX, pfxLen) == 0 || falconSsidSuffix(ssid))) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_PROBE;
        out->confidence = 72;
        acabSanitizeAscii(out->name, (const uint8_t*)ssid, strlen(ssid), sizeof(out->name));
        snprintf(out->detail, sizeof(out->detail), "probing for a Flock network");
        return true;
    }

    // --- Secondary: Flock's own OUI (B4:1E:52) on the transmitter or BSSID ---
    bool txHit  = ouiMatch(addr2);
    bool bssHit = ouiMatch(addr3);

    // Falcon cams ride as WiFi clients (Liteon module, no "Flock-" AP) and give
    // themselves away with PROBE REQUESTS. Match their OUI on a probe request only -
    // Liteon is shared silicon, so the probe-req gate holds the false positives down.
    // (Field-validated at a live Falcon, 2026-06.)
    if (subtype == 0x4 && falconWifiOui(addr2)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_PROBE;
        out->confidence = 72;
        snprintf(out->detail, sizeof(out->detail), "Falcon probe (OUI)");
        return true;
    }

    if (!txHit && !bssHit) return false;

    const uint8_t* src = txHit ? addr2 : addr3;
    acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, src, (int16_t)rssi);

    // An empty-SSID probe request from a Flock OUI is the documented strong signal.
    if (subtype == 0x4 && sawSSID && emptySSID) {
        out->method = M_PROBE;
        out->confidence = 78;
        snprintf(out->detail, sizeof(out->detail), "wildcard probe");
    } else {
        out->method = M_OUI;
        out->confidence = 68;
        // Attacker-controlled text: clamp like every other name path (acab_scanner.h contract).
        if (ssid[0]) acabSanitizeAscii(out->name, (const uint8_t*)ssid, strlen(ssid), sizeof(out->name));
    }
    return true;
}
