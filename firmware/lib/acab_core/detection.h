/*
 * ACAB - All Cameras Are Beacons
 * Shared detection model (firmware-agnostic core).
 *
 * Every detector produces one of these, and every output path consumes it:
 *   - OUI-Spy build  -> streamed over the ACAB BLE GATT service to the iOS app
 *   - Mesh-Detect build -> formatted as a labelled line for the Meshtastic node
 *
 * Keep it POD and self-contained - it gets memcpy'd across FreeRTOS queues and
 * packed onto the wire. No std::string, no heap.
 */
#ifndef ACAB_DETECTION_H
#define ACAB_DETECTION_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>

// ---------------------------------------------------------------------------
// The device classes ACAB looks for (+ an unknown sentinel).
// ---------------------------------------------------------------------------
enum AcabDeviceType : uint8_t {
    ACAB_UNKNOWN       = 0,
    ACAB_FLOCK_CAMERA  = 1,   // Flock Safety ALPR camera (BLE or WiFi signature)
    ACAB_FLOCK_RAVEN   = 2,   // Flock "Raven" audio / gunshot detector
    ACAB_AXON_BODYCAM  = 3,   // body-worn camera (Axon 00:25:DF signature, field-validated)
    ACAB_DRONE         = 4,   // FAA Remote ID broadcasting UAS
    ACAB_TRACKER       = 5,   // BLE item tracker (AirTag/Find My, Tile, Samsung SmartTag)
    // 6 retired: was a Motorola/LE-equipment proxy type. Those OUI matches now report as
    // ACAB_AXON_BODYCAM (folded into the body-cam category), so no detector emits 6. The
    // value stays a reserved gap so ACAB_NEARBY_DEVICE / ACAB_WATCHED keep their wire
    // numbering (the BLE t= field) stable and nothing renumbers.
    ACAB_NEARBY_DEVICE = 7,   // Desert mode: any device in range (no specific signature)
    ACAB_WATCHED       = 8,   // user-starred device: alert on this exact MAC even with no signature match
    ACAB_GLASSES       = 9,   // smart/recording glasses (Ray-Ban/Oakley Meta, Snap Spectacles, Luxottica) by BLE mfg company ID
    ACAB_NETCAM        = 10,  // branded IP camera on host WiFi (Hikvision/Dahua/Amcrest/Axis/Reolink OUI on an 802.11
                              // frame). OPT-IN (default off): matches known IP-camera BRANDS, NOT "hidden cameras" - it
                              // could be an NVR/doorbell/disclosed cam, and it cannot find every camera. See netcam_detect.cpp.
    ACAB_TYPE_COUNT    = 11
};

// How we saw it on the radio.
enum AcabSource : uint8_t {
    SRC_BLE      = 0,   // BLE advertisement
    SRC_WIFI     = 1,   // 802.11 management frame (promiscuous)
    SRC_REMOTEID = 2    // OpenDroneID payload (over BLE or WiFi)
};

// Why it matched - handy to surface in the app/mesh.
enum AcabMethod : uint8_t {
    M_NONE        = 0,
    M_OUI         = 1,   // MAC OUI / prefix table hit
    M_NAME        = 2,   // advertised-name substring
    M_MFG_ID      = 3,   // BLE manufacturer company ID
    M_SERVICE_UUID= 4,   // service UUID (Raven services)
    M_SSID        = 5,   // WiFi SSID pattern
    M_PROBE       = 6,   // empty-SSID probe from a known OUI
    M_REMOTE_ID   = 7,   // decoded OpenDroneID message
    M_SERVICE_DATA= 8,   // ASCII tag in service data / 128-bit UUID (e.g. Axon "BWCDEVICE") - MAC-independent
    M_MFG_SUBTYPE = 9,   // decoded manufacturer-data subtype (structured vendor frame)
    M_WATCHLIST   =10    // exact-MAC user rule (starred device). Full-MAC match, NOT an OUI prefix, so
                         // the durability policy leaves it alone (only M_OUI on a random MAC is down-capped).
};

// ---------------------------------------------------------------------------
// The detection event. 224 bytes on every target this builds for (the double members force
// 8-byte alignment plus trailing padding, which an eyeball estimate misses - this comment
// said "~160 bytes" for a long time and was 40% low). Passing it BY VALUE through queues is
// deliberate: it is POD, so a copy is what keeps the radio callbacks out of the business of
// owning a lifetime.
//
// The number is load-bearing on the most memory-constrained target in the product. The
// scanner's sink queue is ACAB_SINK_Q_LEN (32) items of SinkItem, and SinkItem embeds one of
// these, so that queue costs several KB of HEAP, via xQueueCreate in acab_scanner.cpp, not a
// static array. SinkItem carries more than this struct, so the exact byte figure lives with
// SinkItem in acab_scanner.cpp and is pinned there by its own static_assert - do not restate it
// here, because a second copy of a derived number is what went stale last time. The same 224 bytes is also
// the stack frame this struct occupies inside the IRAM_ATTR WiFi promiscuous callback, which
// runs on the WiFi driver task's stack. Anyone deepening the queue to cut gSinkDropBuffered
// during a Desert firehose is budgeting against this number, so the static_assert below is
// here to surface a future field addition at COMPILE time instead of letting it silently
// grow both.
// ---------------------------------------------------------------------------
struct AcabDetection {
    AcabDeviceType type;
    AcabSource     src;
    AcabMethod     method;
    uint8_t        confidence;     // 0..100

    uint8_t        mac[6];         // transmitter address
    int16_t        rssi;
    uint16_t       companyId;      // BLE mfg-specific company ID (SIG assigned #); 0 = none / not BLE

    char           id[40];         // RID UAS serial / operator id
    char           name[40];       // advertised device name (if any)
    char           detail[48];     // free-form: raven fw, ssid, drone op-id, etc.

    // Location. For drones, the broadcast UAS coordinates; for fixed devices,
    // our own GPS fix (0 if we don't have one).
    double         lat, lon;
    double         pilotLat, pilotLon;   // drone operator location (0 if n/a)
    int32_t        altitude;             // metres MSL (drones)
    uint32_t       gpsAgeMs;             // age of the phone fix used to stamp lat/lon (0 = fresh / none)

    // Drone Remote ID flight telemetry (0 / unset for everything else).
    float          speedH;               // horizontal speed (m/s)
    float          speedV;               // vertical speed (m/s)
    float          heading;              // track direction (deg, 0..360)
    float          heightAGL;            // height above takeoff (m)
    int32_t        pilotAlt;             // operator altitude (m MSL)
    uint8_t        ridStatus;            // ODID op status: 1 ground, 2 airborne, 3 emergency, 4 fault

    uint32_t       firstSeen;      // millis() we first saw it
    uint32_t       lastSeen;       // millis() we last saw it
    uint16_t       count;          // sightings this session

    // True when the transmitter address is randomized / locally-administered. A real IEEE OUI
    // implies a public address, so an OUI-only match on a random address isn't trustworthy -
    // the durability policy (acabApplyDurability) down-weights it. Set in acabInit.
    //
    // TRUSTWORTHY FOR SRC_WIFI ONLY, AND KNOWN TO UNDER-DETECT ON SRC_BLE. acabInit derives it
    // from the 802.11 locally-administered bit (mac[0] & 0x02), which is the right test for a
    // randomized WiFi MAC and the wrong one for BLE. BLE puts randomness in the ADDRESS TYPE the
    // controller reports, and the flavour lives in the top TWO bits of the most significant
    // octet (11 static random, 01 resolvable private, 00 non-resolvable private - the same
    // classifier acabBleBegin runs on the board's own address as rnd.val[5] >> 6). 0x02 is one
    // of the random bits BELOW those, so it reads false for roughly half of BLE private
    // addresses.
    //
    // It cannot be repaired from the bytes here, and guessing would be worse than the gap: an
    // address is public because the TYPE field says so, not because of any bit pattern. Axon's
    // 00:25:DF has the 0x02 bit clear AND top bits 00, so a "top two bits" rule applied blind
    // would call every body-cam OUI hit a non-resolvable private address and cap its confidence
    // at 25. The fix belongs at ingest: NimBLE hands the type to AcabAdvCallbacks::onResult
    // (acab_scanner.cpp, NimBLEAddress::getType()) where it is currently discarded, and the
    // dual-radio nRF forward frame needs the same byte added before dual-radio adverts are
    // covered. Until that lands, read this as "randomized WiFi MAC".
    //
    // Nothing serializes it - there is no "rnd" key anywhere under firmware/ - so no app has
    // ever seen a board-sourced value. iOS decodes "rnd" and defaults it false; Android does not
    // read it at all. Both then run the identical local 0x02 test on the MAC string, so both
    // inherit exactly this gap, and they keep inheriting it until the firmware emits the flag.
    bool           randomAddr;

    // Transient routing flag: true when this is a REPLAY of a stored record (nRF
    // black-box dump). The app-notify still fires, but the buzzer + the live dedup
    // table / gTotal / offline buffer are all skipped. Never serialized; defaults false.
    bool           replay;
};

// Self-checking version of the size stated above, so it can never go stale the way "~160 bytes"
// did. If this fires, the struct grew: re-check the ACAB_SINK_Q_LEN heap budget in
// acab_scanner.cpp and the stack frame in the IRAM_ATTR WiFi RX callback before bumping it.
static_assert(sizeof(AcabDetection) == 224,
              "AcabDetection size changed; re-check ACAB_SINK_Q_LEN sizing and the WiFi RX "
              "callback stack frame, then update the size comment above.");

// ---------------------------------------------------------------------------
// Human-readable labels for serial + mesh output.
// ---------------------------------------------------------------------------
static inline const char* acabTypeLabel(AcabDeviceType t) {
    switch (t) {
        case ACAB_FLOCK_CAMERA: return "ALPR camera";
        case ACAB_FLOCK_RAVEN:  return "Flock Raven";
        case ACAB_AXON_BODYCAM: return "Body camera";
        case ACAB_DRONE:        return "Drone";
        case ACAB_TRACKER:      return "Tracker";
        case ACAB_NEARBY_DEVICE:return "Nearby device";
        case ACAB_WATCHED:      return "Watched device";
        case ACAB_GLASSES:      return "Recording glasses";
        case ACAB_NETCAM:       return "Network camera";
        default:                return "Unknown";
    }
}

static inline const char* acabSourceLabel(AcabSource s) {
    switch (s) {
        case SRC_BLE:      return "BLE";
        case SRC_WIFI:     return "WiFi";
        case SRC_REMOTEID: return "RID";
        default:           return "?";
    }
}

// Zero out a detection and stamp the basics.
static inline void acabInit(AcabDetection* d, AcabDeviceType type, AcabSource src,
                            const uint8_t mac[6], int16_t rssi) {
    memset(d, 0, sizeof(*d));
    d->type = type;
    d->src  = src;
    d->rssi = rssi;
    if (mac) {
        memcpy(d->mac, mac, 6);
        // 802.11 locally-administered bit. Right for SRC_WIFI, and a KNOWN under-detect for
        // SRC_BLE, which encodes randomness in the address TYPE and not in this bit. The type
        // is not available at this call site; see the long note on AcabDetection::randomAddr
        // for why it must be plumbed from the scanner rather than guessed from the bytes.
        d->randomAddr = (mac[0] & 0x02) != 0;
    }
}

// Durability policy: an OUI-only match on a randomized / locally-administered address
// isn't trustworthy (a real IEEE OUI implies a global public address), so cap its
// confidence. Applied centrally (handleDetection) so it holds for every detector.
//
// WHAT ACTUALLY PROVIDES GRACEFUL DEGRADATION as vendors (e.g. Axon) move to rotating BLE
// MACs is the MAC-INDEPENDENT signature work - service-data / mfg-subtype / UUID tag matches,
// which keep their confidence because they never depended on the address. This cap is not
// that mechanism, and the comment here used to imply it was.
//
// DEFENCE IN DEPTH, AND UNREACHABLE TODAY. Every M_OUI emitter already refuses a
// locally-administered MAC before it stamps a record - flock_detect ouiMatch/falconWifiOui,
// police_detect ouiMatch, netcam_detect netcamEntry, drone_detect through
// acabOuiPrefixMatches, axon_detect utilOui and axonOuiHit - and the one arm with no
// source-level guard, axonClassifyBLE's signature-table loop, can only match 00:25:DF, whose
// 0x02 bit is clear. So at the single call site the condition never holds, and no INGEST path
// can reach the branch: the assertion that pins it (test_flock.cpp) has to take a real OUI hit
// and then set randomAddr by hand, because no scan input produces both together. It is kept as
// the central backstop for a future matcher added WITHOUT its own guard.
//
// It also stops being unreachable the moment randomAddr is derived correctly for BLE (see the
// note on that field): a resolvable private address such as 44:xx:xx has the 0x02 bit CLEAR,
// so it walks straight through every per-matcher guard, and this cap is the only thing that
// would catch the OUI hit it can produce.
static inline void acabApplyDurability(AcabDetection* d) {
    if (d->method == M_OUI && d->randomAddr && d->confidence > 25) d->confidence = 25;
}

// Format a MAC into "aa:bb:cc:dd:ee:ff". buf needs >= 18 bytes.
static inline void acabFormatMac(const uint8_t mac[6], char* buf) {
    snprintf(buf, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

// Pull the BLE manufacturer company ID (Bluetooth SIG assigned number) out of an advert:
// the first two bytes of the AD type 0xFF (manufacturer-specific data) block, little-endian
// on the wire. Returns 0 when there's no manufacturer data. The ID rides in the PAYLOAD, not
// the MAC, so it survives BLE address randomization - the same reason the glasses/tracker
// detectors key on it. Surfacing it lets the app show/log why a device did (or didn't) match.
static inline uint16_t acabBleCompanyId(const uint8_t* adv, size_t advLen) {
    if (!adv) return 0;
    for (size_t i = 0; i + 1 < advLen; ) {
        uint8_t l = adv[i];
        if (l == 0 || i + 1 + (size_t)l > advLen) break;
        uint8_t t = adv[i + 1];
        if (t == 0xFF && l >= 3) {   // mfg-specific data with at least the 2 company-ID bytes
            return (uint16_t)adv[i + 2] | ((uint16_t)adv[i + 3] << 8);   // little-endian
        }
        i += (size_t)l + 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Detection sink: the firmware registers one of these with the scanner, and it
// fires whenever a target is (re)seen. `isNew` is true only on the first
// sighting within the dedup window.
// ---------------------------------------------------------------------------
typedef void (*AcabDetectionSink)(const AcabDetection& det, bool isNew);

#endif // ACAB_DETECTION_H
