/*
 * ACAB - live-notify field elision for small-MTU links (pure policy, no platform deps).
 *
 * THE DEFECT THIS EXISTS FOR. A fully populated drone Remote ID record can exceed the peer's usable
 * ATT payload. An iPhone that negotiates MTU 185 leaves ~182 usable bytes, and a record carrying
 * name + id + detail + aircraft position + operator position + altitude + speed + vertical speed +
 * heading + height-AGL + operator altitude + RID status does not fit. The old behaviour was to
 * count it, warn on serial, and SKIP: the live sighting was dropped entirely. A drone overhead
 * produced silence on the exact link the alert was supposed to travel.
 *
 * WHY ELISION AND NOT FRAGMENTATION. Fragmentation means a reassembly protocol on the live path,
 * with sequencing, retries and a partial-record state machine on both apps, to deliver telemetry
 * detail nobody reads in the moment. The live notify's job is the ALERT: something is here, what it
 * is, how sure we are, and where. Sending a shorter honest record beats sending nothing.
 *
 * AN ELIDED FIELD IS LOST, NOT DEFERRED. The offline buffer's fixed 64-byte StoredDet slot
 * (det_log.h) persists none of the elidable fields - not cid, not the drone telemetry - so a
 * replayed record cannot restore what the live notify gave up. An earlier version of this comment
 * claimed the complete record reaches the buffer; it does not, and the doc row for `cid` in
 * ble-protocol.md states the real contract. The trade still holds: what elision drops is
 * enrichment, and the fields the alert and the evidence log depend on are never elidable.
 *
 * THE ORDER IS THE CONTRACT. Fields are dropped least-meaningful first: the BLE company ID goes
 * first (it exists for after-the-fact diagnosability, not for the in-the-moment alert), and
 * operator position is
 * dropped LAST of the optional set because on a drone record it is the single most useful field to
 * a person deciding what to do. Anything a user or a parser depends on is never elidable at all:
 * type, source, method, confidence, MAC, RSSI, name, detail, the UAS id, the subject lat/lon, the
 * sighting count, and the new flag. If you change this order, change the test that pins it in the
 * same commit, and say why here.
 */
#ifndef ACAB_DETECT_ELIDE_H
#define ACAB_DETECT_ELIDE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>   // size_t, for the mandatory-key list

/// Optional fields, in the order they are given up. Each level suppresses this field AND every
/// field above it, so the level is "how hard did we have to squeeze".
enum AcabElideLevel : uint8_t {
    ACAB_ELIDE_NONE = 0,  ///< full record
    ACAB_ELIDE_CID,       ///< BLE company ID: pure diagnostics, FIRST to go
    ACAB_ELIDE_PALT,      ///< operator altitude: least actionable number in the set
    ACAB_ELIDE_HGT,       ///< height above ground
    ACAB_ELIDE_VSPD,      ///< vertical speed
    ACAB_ELIDE_SPD,       ///< horizontal speed
    ACAB_ELIDE_HDG,       ///< heading
    ACAB_ELIDE_STA,       ///< RID status byte
    ACAB_ELIDE_PILOT,     ///< operator lat/lon: LAST, it is the most user-meaningful optional field
    ACAB_ELIDE_MAX = ACAB_ELIDE_PILOT
};

/// The elidable fields, named for tests and for the serial warning.
enum AcabElidableField : uint8_t {
    ACAB_FIELD_CID = 0,
    ACAB_FIELD_PALT,
    ACAB_FIELD_HGT,
    ACAB_FIELD_VSPD,
    ACAB_FIELD_SPD,
    ACAB_FIELD_HDG,
    ACAB_FIELD_STA,
    ACAB_FIELD_PILOT,
    ACAB_FIELD_COUNT
};

/// True when `field` still belongs in a record built at `level`.
///
/// The mapping is deliberately direct rather than clever: field N survives while the level has not
/// yet reached N+1. A table or bitmask would let the order drift from the enum above without the
/// compiler noticing, and the order IS the contract.
inline bool acabElideKeeps(AcabElidableField field, uint8_t level) {
    switch (field) {
        case ACAB_FIELD_CID:   return level < ACAB_ELIDE_CID;
        case ACAB_FIELD_PALT:  return level < ACAB_ELIDE_PALT;
        case ACAB_FIELD_HGT:   return level < ACAB_ELIDE_HGT;
        case ACAB_FIELD_VSPD:  return level < ACAB_ELIDE_VSPD;
        case ACAB_FIELD_SPD:   return level < ACAB_ELIDE_SPD;
        case ACAB_FIELD_HDG:   return level < ACAB_ELIDE_HDG;
        case ACAB_FIELD_STA:   return level < ACAB_ELIDE_STA;
        case ACAB_FIELD_PILOT: return level < ACAB_ELIDE_PILOT;
        default:               return false;
    }
}

/// Wire key for a field, for the serial warning and for tests that assert the documented order
/// without reaching into the JSON builder.
inline const char* acabElideKey(AcabElidableField field) {
    switch (field) {
        case ACAB_FIELD_CID:   return "cid";
        case ACAB_FIELD_PALT:  return "palt";
        case ACAB_FIELD_HGT:   return "hgt";
        case ACAB_FIELD_VSPD:  return "vspd";
        case ACAB_FIELD_SPD:   return "spd";
        case ACAB_FIELD_HDG:   return "hdg";
        case ACAB_FIELD_STA:   return "sta";
        case ACAB_FIELD_PILOT: return "plat/plon";
        default:               return "?";
    }
}

/// The keys that must survive every level. Kept here, beside the order, so a test can assert the
/// invariant against ONE list instead of restating it (a restated list is how the two drift).
inline const char* const* acabElideMandatoryKeys(size_t* n) {
    static const char* const kKeys[] = {
        "t", "s", "meth", "c", "mac", "rssi", "name", "det", "id", "lat", "lon", "n", "new"
    };
    if (n) *n = sizeof(kKeys) / sizeof(kKeys[0]);
    return kKeys;
}

#endif // ACAB_DETECT_ELIDE_H
