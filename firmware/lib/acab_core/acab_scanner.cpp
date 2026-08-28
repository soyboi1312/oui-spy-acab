/*
 * ACAB - Unified scanner implementation.
 *
 * Concurrency (same WiFi-promiscuous + NimBLE combo sky-spy proved out on the
 * XIAO ESP32-S3):
 *   - BLE scan runs in its own FreeRTOS task (bleScanTask).
 *   - The WiFi promiscuous RX callback runs in the WiFi driver task.
 *   - Both funnel through handleDetection(), which grabs a short critical
 *     section just to touch the dedup table, then calls the sink outside it.
 */
#include "acab_scanner.h"
#include "flock_detect.h"
#include "axon_detect.h"
#include "drone_detect.h"
#include "tracker_detect.h"
#include "glasses_detect.h"
#include "police_detect.h"
#include "netcam_detect.h"
#include "desert_detect.h"
#include "det_log.h"
#include "ble_adv16.h"   // structural 16-bit UUID / company-ID decoding
#include "mark_table.h"  // marker-window accounting (pure, host-tested)
#include "sink_claim.h"   // acabClaimRollbackAllowed: the ABA-safe rollback decision
#include "dedup_key.h"    // acabDedupKey: ONE derivation, shared with the host tests
#include "acab_ble_service.h"
#ifdef ACAB_CAPTURE_BUILD
#include "alpr_candidates.h"  // exact-width registered-prefix watchlist; never a classifier
#endif
// Same guard as the shared advName buffer in acabScannerIngestBLE: the capture build's body-cam
// name candidates AND the ACAB_DIAG Pigvision marker both match against it, and ACAB_DIAG can be
// set on its own (nothing forces it to imply a capture build).
#if defined(ACAB_CAPTURE_BUILD) || defined(ACAB_DIAG)
#include "ascii_match.h"      // shared acabAsciiCiContains (capture/diag name annotations)
#endif

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <atomic>
#include <stdlib.h>   // qsort for the sorted ignore/watch lists

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static AcabScannerConfig  gCfg;
static AcabDetectionSink  gSink = nullptr;
static AcabCmdSink        gCmdSink = nullptr;   // dual-radio: mirror radio cmds to the co-processor
static NimBLEScan*        gScan = nullptr;
static QueueHandle_t      gSinkQ = nullptr;   // detections handed off to sinkTask
static volatile bool      gScannerReady = false;

static portMUX_TYPE       gDedupMux = portMUX_INITIALIZER_UNLOCKED;
static std::atomic<uint32_t> gTotal{0};      // both radios write it, so atomic
static std::atomic<uint32_t> gBleSeen{0};    // raw BLE adverts seen (diagnostic)
static std::atomic<uint32_t> gWifiSeen{0};   // raw 802.11 mgmt frames seen (diagnostic)
// Sink-queue drop accounting. Atomic for the same reason as the counters above: both radio tasks
// write them. The three drop categories are EXCLUSIVE by construction (one enqueue takes exactly
// one branch), so their sum is the honest total and is what ships as `sdrop` in status.
static std::atomic<uint32_t> gSinkDropDeliverOnly{0};  // live-notify item dropped; it just re-arrives
static std::atomic<uint32_t> gSinkDropBuffered{0};     // buffer-bearing item dropped AFTER rollback
static std::atomic<uint32_t> gSinkDropReplay{0};       // replay item dropped from one dump attempt
static std::atomic<uint32_t> gSinkHighWater{0};        // deepest the queue has ever been
// One definition for the queue depth: the high-water math derives depth from it, so a hand-edited
// literal at the xQueueCreate call would silently skew every reported depth.
#define ACAB_SINK_Q_LEN 32
static volatile bool      gBleEnabled = true;   // app-toggleable BLE scan
static volatile bool      gWifiEnabled = true;  // app-toggleable WiFi scan
// Serializes promiscuous-mode transitions between the app toggle and wifiHopTask's eco sleep.
// The driver call cannot run under a spinlock, so use a task mutex and always re-check the desired
// state while holding it before an eco wake re-enables RX.
static SemaphoreHandle_t  gWifiModeMux = nullptr;

static double gSelfLat = 0, gSelfLon = 0;
static bool   gSelfGPSValid = false;

// Dedup table -------------------------------------------------------------
// One entry per device we've recently seen, so we don't re-report it every advert.
struct DedupEntry {
    bool          used;
    AcabDeviceType type;
    uint8_t       mac[6];
    uint32_t      firstSeen;
    uint32_t      lastSeen;
    uint16_t      count;
    uint32_t      loggedGen;   // capture generation this entry last buffered in (0 = never)
    uint32_t      logClaim;    // token of the claim that set loggedGen (see sink_claim.h)
    bool          alerted;     // tracker capture debounce: has the post-debounce `new` edge fired
    int16_t       hnext;       // next entry index in this slot's hash bucket chain (-1 = end)
};
// NOT sized to hold every device Desert mode sees, and it cannot be: entries are only ever
// dropped by eviction (there is no time-based expiry), and phones rotate their randomized MAC
// every ~15 min, so the key population is unbounded over a deploy and no fixed table survives
// it. The table is a recent-sighting cache that thrashes by design in a dense area; what makes
// that safe is the eviction priority in dedupFind() plus the type gate on buffering, NOT the
// size. Raising this only moves the thrash point.
#define ACAB_DEDUP_MAX     256
#define ACAB_DEDUP_BUCKETS 256   // power of two; MAC-keyed hash index for O(1)-avg lookup
static DedupEntry gDedup[ACAB_DEDUP_MAX];
static int16_t    gDedupBucket[ACAB_DEDUP_BUCKETS];   // per-bucket head index into gDedup (-1 = empty)

// FNV-1a over (type, 6-byte mac). Computed OFF the lock (touches no shared state) so the
// interrupt-disabled critical section only does the short chain walk + slot mutation, not
// the old O(256) linear memcmp scan.
static inline uint32_t dedupHash(AcabDeviceType type, const uint8_t mac[6]) {
    uint32_t h = 2166136261u;
    h ^= (uint8_t)type; h *= 16777619u;
    for (int i = 0; i < 6; i++) { h ^= mac[i]; h *= 16777619u; }
    return h;
}

// CAPTURE DEBOUNCE ONLY. This does NOT decide whether a tracker is following you, and the board
// cannot decide that: judging "following" needs your LOCATION OVER TIME and this board has no GPS
// and no wall clock. That call is made in the app, which has both. See docs/ble-protocol.md.
//
// The name is historical and the buzzer is not what it buys: ACAB_TRACKER's case in alerts.cpp is
// an empty pattern and alertsSignal excludes the type from the reveal sting, so a tracker makes no
// sound whatever this constant does. What this does hold, for the first minute of a tracker's life,
// is the wire `new` flag and the offline-buffer write, so a tag you drift past in a parking lot
// does not spend the board's capture, while the detection is still DELIVERED to the app
// immediately. Delivery and capture are deliberately decoupled (see the gate below) , the app needs
// the early sightings to build its location trail, so suppressing delivery would blind the very
// thing that makes the judgement. The old code returned early here and the phone never saw those
// sightings.
//
// 60s, not the old 5s: five seconds holds back nothing real. It is also not an attempt at a
// follow-me threshold, since Apple's own equivalent runs 8 hours by day and ~30 minutes at night
// against signals we do not have. 60s is simply longer than a traffic light next to a parked car.
// Trackers ONLY: other surveillance gear alerts on first sight, since a Flock/drone/body-cam you
// pass is worth knowing about immediately.
static const uint32_t TRACKER_ALERT_DEBOUNCE_MS = 60000;
// Offline-capture generation: bumped on each BLE disconnect so the first sighting of
// every device AFTER the app leaves buffers once more, not just once per boot.
static volatile uint32_t gCaptureGen = 1;
// Owner/link admission is distinct from capture cadence. gCaptureGen also advances every 15
// minutes in Stationary mode; that periodic re-arm must not invalidate a legitimate queued row.
// Authentication and disconnect publish det_log-owned owner-admission epochs here, under the same
// dedup lock used to stamp SinkItem claims. Periodic capture cadence never touches this value.
static uint32_t gAdmissionEpoch = 1;
// Reserved by the det_log boundary while authentication or disconnect clears prior-owner state.
// Scanner claims are stamped 0 during that window; only the explicit auth admit or disconnect
// re-arm step publishes this nonzero token.
static uint32_t gPendingAdmissionEpoch = 0;
// Monotonic token stamped on every offline-buffer claim. Only ever read/incremented while holding
// gDedupMux, so a plain uint32_t is correct and an atomic would be misleading about the locking.
// Wraparound is a non-issue: it would take ~4.3 billion buffered claims in one power cycle, and a
// collision would additionally have to land on the same evicted-and-reinserted slot in the same
// generation. See sink_claim.h for what the token defends against.
static uint32_t gLogClaimCounter = 0;

// Whitelist (app-pushed): MACs we drop silently - no report, beep, or mesh.
#define ACAB_IGNORE_MAX 256
static uint8_t      gIgnore[ACAB_IGNORE_MAX][6];
static volatile int gIgnoreCount = 0;
static portMUX_TYPE gIgnoreMux = portMUX_INITIALIZER_UNLOCKED;

// Ignore/watch MACs are kept sorted (memcmp order over the 6 bytes) so the radio path can
// binary-search them - O(log n) comparisons inside the spinlock instead of a linear O(256)
// memcmp scan with interrupts disabled on every advert. Writers (the config path) sort a
// scratch copy off the lock and publish it under the mux, so the sorted invariant holds for
// every locked read.
static int macCmp(const void* a, const void* b) { return memcmp(a, b, 6); }
static bool macInSorted(const uint8_t list[][6], int count, const uint8_t mac[6]) {
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        int c = memcmp(list[mid], mac, 6);
        if (c == 0) return true;
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return false;
}
// Scratch for building a sorted list off the lock before publishing it under the mux. The
// config-write path (BLE GATT) is single-threaded, so one buffer serves both setters.
static uint8_t gMacSortScratch[ACAB_IGNORE_MAX][6];

static bool isIgnored(const uint8_t mac[6]) {
    bool hit;
    portENTER_CRITICAL(&gIgnoreMux);
    hit = macInSorted(gIgnore, gIgnoreCount, mac);   // sorted -> binary search, short ISR-off window
    portEXIT_CRITICAL(&gIgnoreMux);
    return hit;
}

// Watchlist (app-pushed): the inverse of the ignore list. A starred MAC alerts every time
// it is seen even with no signature match. Mirrors the ignore storage exactly.
#define ACAB_WATCH_MAX 256
static uint8_t      gWatch[ACAB_WATCH_MAX][6];
static volatile int gWatchCount = 0;
static portMUX_TYPE gWatchMux = portMUX_INITIALIZER_UNLOCKED;

static bool isWatched(const uint8_t mac[6]) {
    bool hit;
    portENTER_CRITICAL(&gWatchMux);
    hit = macInSorted(gWatch, gWatchCount, mac);   // sorted -> binary search, short ISR-off window
    portEXIT_CRITICAL(&gWatchMux);
    return hit;
}

// Persist the whitelist to NVS so it survives reboots - the app doesn't have to
// re-push it, and a board keeps ignoring known-friendly tags on its own.
static void saveIgnoreList() {
    Preferences p;
    p.begin("acab-ignore", false);
    p.putInt("n", gIgnoreCount);
    if (gIgnoreCount > 0) p.putBytes("macs", gIgnore, (size_t)gIgnoreCount * 6);
    p.end();
}

static void loadIgnoreList() {
    // Hold the published count at 0 for the whole load. This runs on the setup task while the GATT
    // server may already be advertising, and every reader (isIgnored, publishIgnoreMirror's merge)
    // walks the array unlocked against the count. A count published before the bytes are in place
    // and sorted lets a reader binary-search garbage.
    gIgnoreCount = 0;
    Preferences p;
    p.begin("acab-ignore", true);
    int n = p.getInt("n", 0);
    if (n < 0) n = 0;
    if (n > ACAB_IGNORE_MAX) n = ACAB_IGNORE_MAX;
    if (n > 0) p.getBytes("macs", gIgnore, (size_t)n * 6);
    p.end();
    // Sort BEFORE the count goes live: isIgnored binary-searches on the other core without
    // taking a lock here, so publishing n first let a boot-time reader bisect a partly-sorted
    // array and answer wrongly for a MAC that is on the list. The comment above promises the
    // count is held at 0 for the whole load; the load includes the sort.
    qsort(gIgnore, n, 6, macCmp);   // keep sorted for binary-search isIgnored (old blobs may be unsorted)
    gIgnoreCount = n;
}

// Persist the watchlist to NVS so starred devices survive reboots (own namespace).
static void saveWatchList() {
    Preferences p;
    p.begin("acab-watch", false);
    p.putInt("n", gWatchCount);
    if (gWatchCount > 0) p.putBytes("macs", gWatch, (size_t)gWatchCount * 6);
    p.end();
}

static void loadWatchList() {
    gWatchCount = 0;   // see loadIgnoreList
    Preferences p;
    p.begin("acab-watch", true);
    int n = p.getInt("n", 0);
    if (n < 0) n = 0;
    if (n > ACAB_WATCH_MAX) n = ACAB_WATCH_MAX;
    if (n > 0) p.getBytes("macs", gWatch, (size_t)n * 6);
    p.end();
    // Same order rule as loadIgnoreList above: sort first, then publish the count.
    qsort(gWatch, n, 6, macCmp);   // keep sorted for binary-search isWatched (old blobs may be unsorted)
    gWatchCount = n;
}

// The entry for (type, mac), creating/evicting as needed. Caller holds gDedupMux and passes
// the precomputed bucket (dedupHash & mask). The common case (device already tracked) is an
// O(1)-average bucket-chain walk instead of the old O(256) linear memcmp scan, so far less
// runs with interrupts disabled; only a genuinely new device pays the O(256) free/oldest
// search (and only that path mutates the hash chains).
// LOOKUP ONLY: walks the bucket chain and returns nullptr on a miss. dedupFind (below) CREATES
// OR EVICTS on a miss, which is right for ingest and catastrophic for failure recovery - a
// rollback path that mutated the table merely by looking could evict a live entry to re-create one
// the table had already decided to forget. Keep these two separate.
// ---- the real dedup table, behind the injected interface acabSinkClaimRollback takes ----------
// The rollback lives in sink_claim.h and can only see an AcabSinkClaim, so it is structurally
// unable to look an entry up by d.mac. These three functions are the only bridge to the table.
static DedupEntry* gRollbackHit = nullptr;   // set by claimTableLookup, consumed by claimTableRestore

static DedupEntry* dedupLookup(AcabDeviceType type, const uint8_t mac[6], uint32_t bucket) {
    for (int16_t i = gDedupBucket[bucket]; i >= 0; i = gDedup[i].hnext) {
        DedupEntry* e = &gDedup[i];
        if (e->type == type && memcmp(e->mac, mac, 6) == 0) return e;
    }
    return nullptr;
}

// (definitions for the claim-table bridge declared above)
static bool claimTableLookup(void*, uint8_t type, const uint8_t key[6], uint32_t bucket,
                             uint32_t* outLoggedGen, uint32_t* outLogClaim) {
    gRollbackHit = dedupLookup((AcabDeviceType)type, key, bucket);
    if (!gRollbackHit) return false;
    *outLoggedGen = gRollbackHit->loggedGen;
    *outLogClaim  = gRollbackHit->logClaim;
    return true;
}
static void claimTableRestore(void*, uint32_t loggedGen) {
    if (gRollbackHit) gRollbackHit->loggedGen = loggedGen;
}
static uint32_t claimTableGenNow(void*) { return gCaptureGen; }

static bool rollbackBufferClaim(const AcabSinkClaim& claim) {
    static const AcabClaimTable kTable{ claimTableLookup, claimTableRestore,
                                        claimTableGenNow, nullptr };
    portENTER_CRITICAL(&gDedupMux);
    const bool restored = acabSinkClaimRollback(claim, kTable);
    portEXIT_CRITICAL(&gDedupMux);
    return restored;
}

static DedupEntry* dedupFind(AcabDeviceType type, const uint8_t mac[6], uint32_t bucket,
                             uint32_t now) {
    // fast path: already tracked -> walk just this bucket's chain
    for (int16_t i = gDedupBucket[bucket]; i >= 0; i = gDedup[i].hnext) {
        DedupEntry* e = &gDedup[i];
        if (e->type == type && memcmp(e->mac, mac, 6) == 0) return e;
    }
    // not tracked yet: take a free slot, else evict the least-recently-seen entry. A signature
    // match outranks Desert's ACAB_NEARBY_DEVICE for tenure: Desert keys every phone in range
    // and each MAC rotation mints a fresh key, so an unfiltered LRU would spend the whole table
    // on one-shot phone entries and keep re-admitting (and so re-arming) the cameras/trackers
    // this exists to track. Evict the oldest NEARBY_DEVICE first, and only fall back to the
    // oldest entry overall once the table holds nothing but real matches.
    //
    // "Oldest" is measured as ELAPSED AGE (now - lastSeen), never by comparing the raw stamps.
    // millis() wraps every ~49.7 days and this table has NO time-based expiry - entries leave
    // only by eviction - so a raw `<` inverts across the wrap: an entry stamped just before it
    // (~0xFFFFFFxx) reads as the newest forever and is never chosen, while every freshly stamped
    // entry looks oldest and is evicted the moment the next new key arrives. On a deploy-and-
    // leave unit that collapses the table to the handful of post-wrap slots, and a real camera or
    // tracker then gets re-admitted instead of refreshed - which zeroes count (so it re-alerts the
    // buzzer, defeating the tracker dwell gate) and zeroes loggedGen (so the offline flash ring
    // refills with duplicates of one device and wraps away the evidence). The unsigned subtraction
    // below is wrap-correct, matching the `now - e->lastSeen > gCfg.dedupWindowMs` test in
    // handleDetection that already gets this right.
    int freeIdx = -1, oldestIdx = -1, oldestNearbyIdx = -1;
    uint32_t oldestAge = 0, oldestNearbyAge = 0;
    for (int i = 0; i < ACAB_DEDUP_MAX; i++) {
        DedupEntry* e = &gDedup[i];
        if (!e->used) { freeIdx = i; break; }
        const uint32_t age = now - e->lastSeen;
        if (oldestIdx < 0 || age > oldestAge) { oldestIdx = i; oldestAge = age; }
        if (e->type == ACAB_NEARBY_DEVICE &&
            (oldestNearbyIdx < 0 || age > oldestNearbyAge)) { oldestNearbyIdx = i; oldestNearbyAge = age; }
    }
    int idx = (freeIdx >= 0) ? freeIdx : (oldestNearbyIdx >= 0 ? oldestNearbyIdx : oldestIdx);
    DedupEntry* slot = &gDedup[idx];
    if (slot->used) {                                   // evicting: unlink from its old bucket chain
        uint32_t ob = dedupHash(slot->type, slot->mac) & (ACAB_DEDUP_BUCKETS - 1);
        int16_t* pp = &gDedupBucket[ob];
        while (*pp >= 0 && *pp != idx) pp = &gDedup[*pp].hnext;
        if (*pp == idx) *pp = slot->hnext;
    }
    slot->used = true;
    slot->type = type;
    memcpy(slot->mac, mac, 6);
    slot->firstSeen = 0;
    slot->lastSeen = 0;
    slot->count = 0;
    slot->loggedGen = 0;   // a reused slot re-arms capture for the new device
    slot->alerted = false; // and re-arms the tracker dwell gate
    slot->hnext = gDedupBucket[bucket];                 // link at the head of its bucket
    gDedupBucket[bucket] = (int16_t)idx;
    return slot;
}

// The sink runs on its own task so heavy work (serial, BLE notify, mesh UART) never runs
// inside the WiFi driver callback or the BLE scan task - the radios just enqueue and move
// on. The offline-buffer flash write rides the same task (PERF-2): its 4KB sector erase
// every 64 records used to run INLINE on the radio path and stall scanning, so it moved
// here. `buffer` = append this record to det_log; `deliver` = call the firmware sink. The two
// are separate flags because they gate on different things. This comment used to claim they
// could not both be interesting at once ("a deliver=false item is now always buffer=false too"),
// and that claim is FALSE in two ways, so do not restore it: ACAB_NETCAM is a firehose type whose
// buffering is deliberately not gated on deliver, and detLogBufferAll() now admits a throttled
// Desert ACAB_NEARBY_DEVICE to the buffer as well. Treat the two flags as genuinely independent -
// which is what the code has always actually done, both here and in sinkTask.
//
// `bufGps` rides BESIDE `d`, never inside it. It is the retained phone fix, the only position a
// board can offer once its owner has walked away, and the notify path must not be able to reach
// it: `d` is the very object gSink hands to acabBleNotifyDetection, and `buffer` and `deliver` are
// resolved on opposite sides of a possible connect. See the stamp in handleDetection and
// DetLogGpsStamp in det_log.h for the failure this shape rules out.
//
// THE COST OF CARRYING IT, since this struct is what sets the queue's heap budget: SinkItem is
// 272 B (224 of AcabDetection, 3 flag bytes, a 12-byte DetLogGpsStamp, the 32-byte ABA-safe claim,
// and padding), so xQueueCreate below takes 32 * 272 = 8,704 B of heap. The claim must travel to
// the sink: a successful queue send is not evidence that the later flash append was accepted.
// The stamp holds StoredDet's own e7/whole-second units rather than the live doubles precisely to
// keep that number down: two doubles plus the age would be 20 B rather than 12, so after padding
// that is a further 16 B per queue item (512 B of heap) for no precision at all, since det_log
// truncates to e7 on the way in regardless.
struct SinkItem {
    AcabDetection d;
    bool isNew;
    bool deliver;
    bool buffer;
    DetLogGpsStamp bufGps;
    AcabSinkClaim claim;
};
// Self-checking, in the same spirit as the sizeof(AcabDetection) assert in detection.h: the two
// figures in the paragraph above are the queue's heap budget, and a silently grown SinkItem is
// exactly how a budget comment goes stale.
static_assert(sizeof(SinkItem) == 272,
              "SinkItem size changed; re-measure the ACAB_SINK_Q_LEN heap budget above "
              "(and the derived figure in detection.h) before bumping this.");

struct SinkDeliveryContext {
    AcabDetectionSink sink;
    const AcabDetection* detection;
    bool isNew;
};

static void deliverSinkItem(void* raw) {
    SinkDeliveryContext* context = static_cast<SinkDeliveryContext*>(raw);
    context->sink(*context->detection, context->isNew);
}

static void sinkTask(void*) {
    SinkItem it;
    for (;;) {
        if (xQueueReceive(gSinkQ, &it, portMAX_DELAY) != pdTRUE) continue;
        // flash write happens HERE, off both radio tasks. det_log no-ops when the app is
        // connected / buffering is disabled / no key - same guards as before, just now
        // evaluated on the sink task a beat later than at ingest.
#ifdef ACAB_BENCH_SINK_STALL
        // BENCH ONLY (capture builds; see the #error guard family in main.cpp). Makes the sink
        // slow enough that the queue actually saturates on demand, so the rollback path can be
        // exercised deliberately instead of waiting for a flash erase to collide with traffic.
        // Never ship: this would drop most of a real capture on the floor.
        vTaskDelay(pdMS_TO_TICKS(50));
#endif
        // bufGps is handed to the RING and is never merged into it.d, so the retained phone fix
        // it may carry cannot reach the sink below - which is where a notify is built. That is the
        // whole reason it travels as a separate argument; see the stamp in handleDetection.
        if (it.buffer) {
            const DetLogAppendResult result =
                detLogAppendClaimed(it.d, &it.bufGps, it.claim.admissionEpoch);
            if (detLogAppendReleasesClaim(result)) {
                // Queue admission was only the first asynchronous boundary. Startup/key/NVS/wipe
                // state can change before this task reaches flash; a retryable refusal must release
                // the exact claim so the same device can buffer later this generation. The claim
                // token prevents a late sink result from undoing a newer successful ABA claim.
                rollbackBufferClaim(it.claim);
            }
            // CAPACITY_DROP is intentional Stationary-mode censorship: keep the claim consumed or
            // every advert would hammer the full ring and inflate bufdrops indefinitely.
        }
        if (it.deliver && gSink) {
            // Append rejection alone is insufficient: the same queued object feeds BLE/mesh and
            // may carry prior-owner live GPS. Validate at the final delivery boundary and keep the
            // dedicated owner-delivery mutex through the callback, so disconnect/authentication
            // cannot pass a check and then hand the row to the next phone. det_log's flash mutex is
            // released first, preserving the BLE JSON-pool lock order.
            SinkDeliveryContext context{gSink, &it.d, it.isNew};
            detLogDeliverIfCaptureEpochCurrent(it.claim.admissionEpoch,
                                               deliverSinkItem, &context);
        }
    }
}

// Drones rotate their MAC and broadcast on both radios, so key them by UAS-ID
// instead - the stable "one drone = one entry" identity. Everything else keys by
// MAC. Returns d.mac, or a hashed 6-byte key written into scratch.
// Moved to dedup_key.h so the rollback tests exercise the real derivation, not a copy.
#define dedupKey acabDedupKey

// Desert-mode notify gate. Desert mode reports every device in range, so it
// emits a detection for every advert of every nearby device. Streaming all of
// them saturates the single BLE link and starves the inbound config-write path,
// so the app can't even turn the mode back off and the board looks locked up.
// Let a nearby device through only on its isNew edge (first sighting or a
// dedup-window refresh) and cap the burst rate, leaving the link headroom for
// commands. Real detections (Flock/drone/Axon/...) are rare and never gated.
#define ACAB_DESERT_MAX_NOTIFY_PER_SEC 20
static portMUX_TYPE gDesertMux = portMUX_INITIALIZER_UNLOCKED;
// Shared notify token bucket for the per-frame firehoses (Desert's every-advert path and the
// netcam opt-in's every-data-frame path). Repeat sightings never notify; new ones are capped.
static bool desertNotifyAllowed(bool isNew, uint32_t now) {
    if (!isNew) return false;   // repeat sighting inside the dedup window: don't stream it
    static uint32_t windowStart = 0;
    static uint16_t inWindow = 0;
    bool allow;
    portENTER_CRITICAL(&gDesertMux);
    if (now - windowStart >= 1000) { windowStart = now; inWindow = 0; }
    allow = inWindow < ACAB_DESERT_MAX_NOTIFY_PER_SEC;
    if (allow) inWindow++;
    portEXIT_CRITICAL(&gDesertMux);
    return allow;
}

// Where both radios converge.
static void handleDetection(AcabDetection& d, bool isReplay = false) {
    // Watchlist beats the ignore drop for the synthesized ACAB_WATCHED path: a starred
    // device alerts even if its MAC is also on the ignore list. A watched MAC that ALSO
    // matches a built-in signature keeps its specific type and so still honors the ignore
    // drop; the apps prevent that overlap by enforcing star/ignore exclusivity.
    if (d.type != ACAB_WATCHED && isIgnored(d.mac)) return;   // whitelisted by the app - drop silently
    acabApplyDurability(&d);        // cap an OUI-only hit on a randomized MAC (durability policy)

    // nRF black-box replay: deliver the recovered record to the app, but keep it OUT of
    // the live pipeline - no buzzer (onDetection skips it), no live dedup-table / gTotal
    // pollution, no re-buffering. See AcabDetection::replay.
    if (isReplay) {
        d.replay = true;
        // replay delivers to the app but never buffers (no re-buffering of recovered records)
        if (gSinkQ) {
            SinkItem it{d, false, true, false, {}, {}};
            // nRF black-box replay shares the asynchronous sink queue, so it needs the same owner
            // token even though it never claims an offline-buffer row. Otherwise A can request a
            // dump, disconnect, and have the delayed item notify B.
            portENTER_CRITICAL(&gDedupMux);
            it.claim.admissionEpoch = gAdmissionEpoch;
            portEXIT_CRITICAL(&gDedupMux);
            // A dropped REPLAY record is lost from THIS dump attempt only - bbDump() does not
            // erase the nRF ring (BCLR is a separate command), and the whole black box is a
            // bench-only capture build. Counted, but not permanent loss; do not describe it as one.
            if (xQueueSend(gSinkQ, &it, 0) != pdTRUE)
                gSinkDropReplay.fetch_add(1, std::memory_order_relaxed);
        }
        return;
    }
    uint32_t now = millis();
    bool isNew;

    uint8_t keyScratch[6];
    const uint8_t* key = dedupKey(d, keyScratch);
    // hash the key OFF the lock (no shared state) so the critical section stays short
    uint32_t bucket = dedupHash(d.type, key) & (ACAB_DEDUP_BUCKETS - 1);
    // Read the "record everything" flag OFF the lock too. detLogBufferAll() is a deliberately
    // LOCK-FREE read of a volatile bool (see the rationale on its definition in det_log.cpp - it
    // is lock-free precisely BECAUSE this radio hot path calls it, and gIoMutex is held across
    // multi-ms flash erases). The flag only changes on an app config write, so a one-advert-stale
    // read is harmless. Keep the call out here anyway: nothing but plain memory access belongs
    // inside portENTER_CRITICAL, and this is the last place that should acquire the habit of
    // calling into another module with interrupts disabled.
    const bool bufferAll = detLogBufferAll();

    portENTER_CRITICAL(&gDedupMux);
    DedupEntry* e = dedupFind(d.type, key, bucket, now);
    isNew = (e->count == 0) || (now - e->lastSeen > gCfg.dedupWindowMs);
    if (e->count == 0) e->firstSeen = now;
    e->lastSeen = now;
    if (e->count < 0xFFFF) e->count++;
    // Tracker capture debounce. Named for the buzzer, but the buzzer is not what it buys: the
    // ACAB_TRACKER case in alerts.cpp is an empty pattern and alertsSignal excludes the type from
    // the reveal sting, so a tracker is silent for its whole life whatever this does. What the
    // first TRACKER_ALERT_DEBOUNCE_MS actually holds back is the wire `new` flag and the
    // offline-buffer write (both below); the detection itself is still delivered to the app on
    // every sighting from the very first one.
    //
    // This used to `return` early (see the deleted line below the critical section), which also
    // skipped the GPS stamp and the sink enqueue, so the phone never saw a sub-dwell tracker at
    // all. That was backwards: the app is the thing that decides whether a tag is FOLLOWING you,
    // it needs location-over-time to do it, and the early sightings are exactly the data it needs.
    // Suppressing delivery blinded the judgement it was meant to support.
    //
    // Mechanism: clear isNew while debouncing. isNew is what the sink hands alertsSignal and what
    // acabBleNotifyDetection serializes as `new`, so the row goes out as a repeat sighting; the
    // first sighting past the window sets it true once, via the `alerted` latch. shouldBuffer
    // stays gated on it so the offline flash ring does not fill with tags you merely walked past.
    bool debouncing = false;
    if (d.type == ACAB_TRACKER) {
        if (now - e->firstSeen < TRACKER_ALERT_DEBOUNCE_MS) { debouncing = true; isNew = false; }
        else if (!e->alerted) { e->alerted = true; isNew = true; }
    }
    // Buffer a device once per capture generation: its first sighting this boot AND its
    // first sighting after each link drop (gCaptureGen bumps on disconnect), so capture
    // re-arms when the app leaves instead of firing only once per boot.
    // NEVER buffer a Desert ACAB_NEARBY_DEVICE. The offline buffer exists to capture
    // surveillance hits while the phone is away, and the ring is append-only with no
    // type filter of its own, so letting phones in lets them WRAP it: a dense area churns
    // the dedup table, every re-admitted phone comes back with loggedGen reset to 0 and so
    // reads as a first sighting again, and the resulting flood of duplicate phone records
    // evicts the real ALPR / body-cam records the user synced to get. Live delivery of
    // nearby devices is unaffected; only the flash ring is gated.
    // ...UNLESS the owner turned on "record everything" (detLogBufferAll, det_log.h). That switch
    // exists for the deploy-and-leave case: a board left unattended for days somewhere with almost
    // no RF, where the question is whether ANYTHING came by and an uncategorized device is the
    // entire finding. The wrap argument above is an argument about DENSITY, and it inverts in a
    // place with nothing to crowd out. It stays off by default, so the dense-area default is
    // unchanged. Re-arm for those records comes from acabScannerBufferAllTick() below, not from
    // a per-entry timestamp: the claim/rollback machinery in sink_claim.h is keyed on loggedGen
    // vs gCaptureGen and carries an ABA guard, so driving re-arm through the SAME generation
    // counter reuses that proven path instead of opening a second, untested one beside it.
    // The tracker debounce term is ALSO relaxed by the mode, and this is not incidental. A
    // separated tag passing through in under TRACKER_ALERT_DEBOUNCE_MS (60 s) has `debouncing`
    // true on every advert of that pass, so with the term unconditional it writes NOTHING. It
    // cannot fall through to Desert either: trackerClassifyBLE claims the advert first, so no
    // ACAB_NEARBY_DEVICE row is ever synthesized for that MAC. A tracker that came by once and
    // left is close to the most interesting thing this mode could catch, and it was the single
    // class it structurally could not. The debounce's own comment says it is a BUZZER gate plus
    // a density argument, and this change already decided the density argument inverts here.
    bool shouldBuffer = (!debouncing || bufferAll)
                     && (d.type != ACAB_NEARBY_DEVICE || bufferAll)
                     && (e->loggedGen != gCaptureGen);
    // Claim bookkeeping for the rollback path at the enqueue below. The claim is committed HERE,
    // ~50 lines before the item actually reaches the sink queue, so if that send fails the claim
    // has to be undoable - otherwise the device reads as "already buffered this generation" with
    // nothing written. priorLoggedGen is restored rather than 0: gCaptureGen starts at 1 so 0
    // happens to mean "never logged" today, but restoring the real prior value stays correct
    // across generation wraparound and bakes in no sentinel assumption.
    uint32_t priorLoggedGen = e->loggedGen;
    uint32_t logClaim = 0;
    uint32_t claimGen = gCaptureGen;
    // COPY THE KEY THE CLAIM WAS MADE UNDER. The dedup key is NOT always the MAC: dedupKey()
    // hashes the UAS ID for a Remote ID drone, deliberately, because drones rotate MACs across
    // both radios. The rollback used to look the entry up by d.mac, which for exactly that device
    // class never matches the entry it claimed - so entryFound came back false, the rollback
    // refused, and the record stayed marked as already-buffered for the whole capture generation.
    // The evidence-loss bug this whole mechanism exists to fix therefore survived intact for
    // drones, while gSinkDropBuffered counted it as "dropped and rolled back".
    //
    // Copy once, here, and reuse the bytes: re-deriving in the rollback path would be a second
    // chance to diverge (d.id could in principle differ by then).
    AcabSinkClaim claim{};
    claim.type           = (uint8_t)d.type;
    memcpy(claim.key, key, 6);
    claim.bucket         = bucket;
    claim.priorLoggedGen = priorLoggedGen;
    claim.captureGen     = claimGen;
    claim.admissionEpoch = gAdmissionEpoch;
    claim.active         = shouldBuffer;
    if (shouldBuffer) {
        e->loggedGen = gCaptureGen;
        logClaim = ++gLogClaimCounter;
        e->logClaim = logClaim;
        claim.token = logClaim;
    }
    d.firstSeen = e->firstSeen;
    d.lastSeen  = e->lastSeen;
    d.count     = e->count;
    portEXIT_CRITICAL(&gDedupMux);
    // (No early return for a debouncing tracker. It falls through to the GPS stamp and the sink
    // exactly like any other detection, just with isNew cleared so it goes out as a repeat
    // sighting and stays out of the offline buffer.)

    // Stamp EVERY non-drone hit with a GPS fix (drones broadcast their own) and record the fix's
    // age, so the app can say "location from a fix N old" instead of implying it is live.
    //
    // Two sources go ON the detection:
    //   1. gSelfGPSValid - an onboard or nRF-forwarded fix. NO CALLER TODAY: acabScannerSetSelfGPS
    //      has never been wired up by any main, and the nRF forward frame carries no coordinates,
    //      so on every shipped board this arm is false and the stamp comes from the phone.
    //   2. the live phone fix, which exists only while a phone is connected. It is taken at "any
    //      age" - see DET_LOG_GPS_MAX_AGE_MS, which is NOT a bound on this arm.
    //
    // And one source goes BESIDE it, never on it:
    //   3. THE OFFLINE-BUFFER PATH. acabBleGetPhoneGps is cleared on disconnect, and det_log
    //      accepts rows only while the phone is away, so 1 and 2 together stamped nothing at all
    //      onto a buffered record: a deploy-and-leave capture recorded what went by and lost
    //      where, which is half of what it was left there to record. The retained fix
    //      (acabBleGetLastPhoneGps) fills that in, but it may reach the encrypted ring and NOTHING
    //      ELSE, so it goes into bufGps rather than into d.
    //
    //      IT IS NOT ENOUGH TO GUARD THE NOTIFY. `d` is the same object sinkTask hands to gSink,
    //      and buffering and delivery are decided here but happen there: a buffer-bearing item
    //      takes ~10 ms of deliberate backpressure while the sink is mid flash-erase, a phone can
    //      finish connecting inside that window, and then detLogAppend correctly REFUSES the row
    //      (the ring only accepts while the app is away) while the notify goes out anyway. That
    //      notify could carry previous-session coordinates across an owner handoff. The final
    //      owner-admission guard now drops the whole stale SinkItem too; keeping the fix out of `d`
    //      makes the coordinate leak unrepresentable even if another delivery call site appears.
    //
    //      Two further conditions, both load-bearing: only while genuinely disconnected (a
    //      connected board with no fix means the app is not sharing location right now, and a fix
    //      from an earlier session must not be passed off as this one's), and only when this row
    //      is actually going to the ring - a Desert row that is delivered but not buffered has no
    //      sanctioned use for the retained fix, so it must not even read it.
    DetLogGpsStamp bufGps{};
    if (d.type != ACAB_DRONE && d.lat == 0 && d.lon == 0) {
        if (gSelfGPSValid) {
            d.lat = gSelfLat;
            d.lon = gSelfLon;
        } else {
            double la, lo; uint32_t ageMs = 0;
            if (acabBleGetPhoneGps(&la, &lo, 0xFFFFFFFFu, &ageMs)) {
                d.lat = la;
                d.lon = lo;
                d.gpsAgeMs = ageMs;
            } else if (shouldBuffer && !acabBleClientConnected() &&
                       acabBleGetLastPhoneGps(&la, &lo, DET_LOG_GPS_MAX_AGE_MS, &ageMs)) {
                // Converted to StoredDet's own units here so det_log stores exactly what was
                // read, and so this struct cannot be mistaken for something a live path may use.
                // The getter's maxAgeMs bound is what makes ageSec fit a uint16 without clamping.
                bufGps.lat_e7 = (int32_t)(la * 1e7);
                bufGps.lon_e7 = (int32_t)(lo * 1e7);
                bufGps.ageSec = (uint16_t)(ageMs / 1000);
                bufGps.valid  = true;
            }
        }
    }

    gTotal++;

    // Throttle the two per-frame firehoses so they can't saturate the BLE link. This is a
    // NOTIFY gate only: a throttled device is simply not delivered to the app. gTotal above still
    // counts it either way.
    //
    // This used to add that a throttled nearby device "has nothing left to do and drops out of
    // the queue entirely", which kept Desert's volume off the buffer-bearing backpressure path.
    // detLogBufferAll() BREAKS THAT: with the mode on, a throttled Desert row can still be
    // buffer-bearing, so Desert volume does now reach that path. Nothing here depends on the old
    // invariant (the enqueue below tests deliver || shouldBuffer, and sinkTask branches on the
    // two flags independently), but it is written down because a stated invariant left standing
    // after it stops holding is how the assumption gets rebuilt on top of.
    //
    // ACAB_NETCAM joins Desert here (2026-07-23). The netcam opt-in widens the promiscuous
    // filter to DATA frames and classifies EVERY delivered one, so a single streaming IP camera
    // produced one detection + one BLE notify per frame, orders of magnitude more than any
    // advert-based source. desertNotifyAllowed is the right gate for both: it drops repeat
    // sightings inside the dedup window outright and caps new ones at ACAB_DESERT_MAX_NOTIFY_PER_SEC.
    // A netcam loses nothing by it, since its OUI and vendor label are identical on every frame,
    // and the dedup window still lets it refresh (so the closest-approach pin keeps improving).
    // Buffering is deliberately NOT gated: a throttled netcam still records to the offline log.
    bool firehose = (d.type == ACAB_NEARBY_DEVICE || d.type == ACAB_NETCAM);
    bool deliver = !(firehose && !desertNotifyAllowed(isNew, now));

    // Hand off to the sink task: it (not this radio path) does the det_log flash write
    // (PERF-2) and calls the firmware sink. Only queue when there is something to do.
    if (gSinkQ && (deliver || shouldBuffer)) {
        SinkItem it{d, isNew, deliver, shouldBuffer, bufGps, claim};
        // buffer-bearing items get brief backpressure (~10ms) rather than a silent drop: shouldBuffer
        // committed loggedGen at ingest, so a dropped buffer item would be a non-retryable evidence
        // loss for this capture generation. deliver-only items still drop on overflow (a missed live
        // notify just re-arrives). the block only bites while the sink task is mid flash-erase.
        // High-water mark BEFORE the send, so the depth reported is what this item faced.
        {
            uint32_t depth = ACAB_SINK_Q_LEN - (uint32_t)uxQueueSpacesAvailable(gSinkQ);
            uint32_t hw = gSinkHighWater.load(std::memory_order_relaxed);
            while (depth > hw &&
                   !gSinkHighWater.compare_exchange_weak(hw, depth, std::memory_order_relaxed)) {}
        }
        if (xQueueSend(gSinkQ, &it, shouldBuffer ? pdMS_TO_TICKS(10) : 0) != pdTRUE) {
            if (shouldBuffer) {
                // THE FIX. Undo the claim so this device buffers again later in this same capture
                // generation, instead of being silently marked done with nothing written. Guarded
                // against the ABA race by the claim token - see sink_claim.h for why every
                // condition is load-bearing. dedupLookup, never dedupFind: recovery must not
                // create or evict.
                // The rollback owns this: it takes ONLY the claim object, which carries the key
                // copied at claim time. There is no AcabDetection in its scope, so reaching for
                // d.mac here (the shipped bug, which made the rollback a no-op for every Remote ID
                // drone) is now a compile error rather than a judgement call. See sink_claim.h.
                rollbackBufferClaim(claim);
                gSinkDropBuffered.fetch_add(1, std::memory_order_relaxed);
            } else {
                gSinkDropDeliverOnly.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
// Clamp an attacker-sourced byte string to printable ASCII on copy (see the header).
// A crafted advert name / SSID / ODID id cannot smuggle control bytes into the JSON.
void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap) {
    if (!dst || cap == 0) return;
    size_t m = n;
    if (m > cap - 1) m = cap - 1;
    size_t j = 0;
    for (; j < m; j++) {
        uint8_t c = src ? src[j] : 0;
        dst[j] = (c >= 0x20 && c <= 0x7E) ? (char)c : '.';
    }
    dst[j] = 0;
}

// Pull the advertised local name (AD type 0x08 short / 0x09 complete) out of a BLE
// advert into name[outSz] for a synthesized watchlist hit. Empty if there is none.
static void bleWatchName(const uint8_t* adv, size_t advLen, char* name, size_t outSz) {
    name[0] = 0;
    if (!adv || !advLen) return;
    for (size_t i = 0; i + 1 < advLen; ) {
        uint8_t l = adv[i];
        if (l == 0 || i + 1 + (size_t)l > advLen) break;
        uint8_t t = adv[i + 1];
        if (t == 0x08 || t == 0x09) {                 // shortened / complete local name
            size_t n = (size_t)l - 1;
            if (n >= outSz) n = outSz - 1;
            acabSanitizeAscii(name, adv + i + 2, n, outSz);   // clamp to printable ASCII on ingest
            return;
        }
        i += (size_t)l + 1;
    }
}

// Is this advert one of OUR OWN boards? Two beacons in the same room (a test rig, or a
// user who owns two) otherwise flag each other forever as the strongest nearby device in
// range, burying real hits under a -20 dBm neighbour. Matched on our own advertising name
// rather than an OUI, because the OUI here is Espressif's and is shared with a vast amount
// of unrelated hardware. Only ever consulted AFTER the signature chain, see the call site.
// Covers the whole product family, not just this build's own name: the SKUs advertise
// different names ("beacon" on the dual-radio board, "ACAB" on oui-spy), so matching only
// gCfg.bleDeviceName would still leave a user who owns both, or a bench with both on it,
// staring at the other one pinned at the top of the nearby list.
static const char* const SELF_BLE_NAMES[] = { "beacon", "ACAB" };

static bool isSiblingBoard(const uint8_t* adv, size_t advLen) {
    char name[32];
    bleWatchName(adv, advLen, name, sizeof(name));
    if (!name[0]) return false;
    for (size_t i = 0; i < sizeof(SELF_BLE_NAMES) / sizeof(SELF_BLE_NAMES[0]); i++)
        if (strcmp(name, SELF_BLE_NAMES[i]) == 0) return true;
    // Belt and braces: a build configured with some other advertising name still filters itself.
    const char* self = gCfg.bleDeviceName;
    return self && *self && strcmp(name, self) == 0;
}

#ifdef ACAB_CAPTURE_BUILD
static std::atomic<uint32_t> gAlprCandidateBleSeen{0};
static std::atomic<uint32_t> gAlprCandidateWifiSeen{0};
static std::atomic<uint32_t> gAlprCandidateMacs{0};
static std::atomic<uint32_t> gAlprCandidateTableFull{0};

uint32_t acabScannerAlprCandidateBleSeen()  { return gAlprCandidateBleSeen.load(); }
uint32_t acabScannerAlprCandidateWifiSeen() { return gAlprCandidateWifiSeen.load(); }

// Official product documentation confirms that these camera and activation systems use BLE,
// but it does not publish a stable company ID, UUID, payload or advertised name. Do NOT turn
// these strings into production detections: model-like local names are useful capture leads,
// not yet ground truth. The capture build calls them out so a bracketed visit can establish the
// full advert and what disappears when the equipment leaves.
struct BodyCamNameCandidate { const char* needle; const char* label; };
static const BodyCamNameCandidate BODYCAM_NAME_CANDIDATES[] = {
    // Needles are matched as case-insensitive SUBSTRINGS and the loop returns on the FIRST hit, so
    // a needle that contains another row's needle can never be reached. "WV-BWC4000" used to sit
    // here below the bare "BWC4000" and was dead weight. If a future row needs to distinguish a
    // prefixed model, put the LONGER needle first and give it its own label so the match shows up.
    { "BWC4000", "i-PRO BWC4000 camera" },
    { "IPS-BTS", "i-PRO activation accessory" },
    { "BC-02", "Getac BC-02 camera" },
    { "BC-03", "Getac BC-03 camera" },
    { "BC-04", "Getac BC-04 camera" },
    { "TB-02", "Getac vehicle trigger" },
    { "TB-03", "Getac vehicle trigger" },
    { "HS-01", "Getac holster trigger" },
};

// Takes the advert name already parsed by the caller (acabScannerIngestBLE parses it once
// per live packet and shares the buffer with every capture/diag consumer).
static void logBodyCamNameCandidate(const uint8_t mac[6], const char* name, int rssi) {
    if (!name[0]) return;
    for (const auto& candidate : BODYCAM_NAME_CANDIDATES) {
        if (!acabAsciiCiContains(name, candidate.needle)) continue;
        Serial.printf("[ble] *** BODYCAM CAPTURE CANDIDATE *** kind=\"%s\" "
                      "%02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\"\n",
                      candidate.label, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                      rssi, name);
        return;
    }
}
#endif

// Shared BLE classifier funnel: run every BLE detector on one advert (most-
// specific first) and push any match into handleDetection(). Called by the
// NimBLE scan callback below, and by a dual-radio build for adverts forwarded
// from a companion nRF52840 over UART. Counts toward acabScannerBleSeen().
#ifdef ACAB_CAPTURE_BUILD
// ---------------------------------------------------------------------------------------------
// OFFICIAL VENDOR BLE IDENTIFIERS - capture builds only, and deliberately NOT a classifier.
//
// These are Bluetooth SIG ASSIGNED NUMBERS, i.e. registered to a named company, which makes them
// a categorically better class of evidence than the MAC OUI lists this project has been burned by.
// An OUI names whoever made the radio module (Liteon, Espressif, Murata) and is shared across
// millions of unrelated devices. A SIG company ID or a 16-bit service UUID is issued to the
// product vendor. Matching one says "this is that company's equipment" with far less ambiguity.
//
// WHAT IT STILL DOES NOT SAY IS *WHICH* PRODUCT. Axon's own Device Manager compatibility list
// spans Body 2/3/4 and Body Mini, Flex, Signal Sidearm holster sensors, Signal Vehicle and Fleet
// gear, and TASER 7/10 handles and batteries. Motorola Solutions covers APX radios, V500/V700/
// VB400 cameras, M500 in-car video, Holster Aware sensors and accessories - and the same vendor
// identifiers are carried by fire, EMS, security and retail hardware. So the eventual shipping
// label is "<vendor> equipment, device type unknown", never "Body camera". This build exists to
// find out which values map to which products BEFORE any of that is written.
//
// THE LOCAL NAME IS THE PAYLOAD THAT MATTERS. The identifier tells you the vendor; the advertised
// name is the only field likely to separate a Body 4 from a TASER 10 battery. It is logged beside
// every hit for exactly that reason.
//
// Sources: Bluetooth SIG Assigned Numbers (company identifiers + 16-bit UUIDs). Both vendors are
// live locally, which is why this is worth the flash: San Diego has an active Axon body-camera
// contract and a five-year TASER 10 agreement.
struct VendorBleId {
    uint8_t     kind;    // 0 = manufacturer company ID (AD 0xFF), 1 = 16-bit service UUID
    uint16_t    val;
    const char* tag;
};
static const VendorBleId VENDOR_BLE_ID[] = {
    // --- Axon / TASER. FIRST validation target: locally deployed, and the narrower vendor. ---
    { 0, 0x034D, "AXON-CID" },   // TASER International, manufacturer company ID
    { 1, 0xFC81, "AXON-SVC" },   // Axon Enterprise, 16-bit service UUID
    { 1, 0xFE6B, "AXON-SVC" },   // TASER International
    { 1, 0xFE6C, "AXON-SVC" },   // TASER International
    // --- Motorola Solutions. Second in the SHIPPING order, but riding along in capture from the
    // start on purpose: a drive not instrumented today cannot be re-taken retroactively, and the
    // cost of carrying three more comparisons is nil. Kept tagged separately so the analysis can
    // hold them apart, and so the Axon work is never blocked on Motorola data. ---
    { 0, 0x04EC, "MOTO-CID" },   // Motorola Solutions, manufacturer company ID
    { 1, 0xFD8E, "MOTO-SVC" },   // Motorola Solutions
    { 1, 0xFE04, "MOTO-SVC" },   // Motorola Solutions
};
#define VENDOR_BLE_ID_N (sizeof(VENDOR_BLE_ID) / sizeof(VENDOR_BLE_ID[0]))

struct VendorRec {
    uint8_t  mac[6];
    uint32_t n;
    int8_t   best;
    uint8_t  hits;        // bitmask over VENDOR_BLE_ID, so one line shows every identifier a device carries
    uint32_t firstMs;
    uint32_t lastLogMs;
    bool     used;
};
static const size_t   VENDOR_MAX = 12;
// Own constant rather than reusing the WiFi side's WATCH_LOG_EVERY_MS, which is declared further
// down the file and lives inside the ACAB_DIAG_WIFI guard. Borrowing it would make this block fail
// to compile in a capture build without WiFi diag, for no benefit.
static const uint32_t VENDOR_LOG_EVERY_MS = 5000;
// SEPARATE TABLES PER VENDOR, because a shared one is not neutral. Motorola rides along in this
// capture for free in CPU terms, but not in SLOTS: twelve Motorola radios at a station car park
// would fill a shared table and the Axon device the trip was made for would never get a row. Axon
// is the first validation target, so it gets its own reservation and cannot be starved by traffic
// from the vendor that is only here opportunistically. Sizes are deliberately lopsided for the
// same reason. A device carrying BOTH vendors' identifiers lands in the Axon table (checked
// first), which is the correct bias for what this capture is for.
struct VendorTable {
    VendorRec*  rec;
    size_t      n;
    uint32_t    full;           // adverts dropped because every slot was taken
    uint32_t    fullLastLogMs;  // throttle for the overflow notice, see below
    const char* what;
};
static VendorRec gVendorAxRec[12];
static VendorRec gVendorMoRec[8];
static VendorTable gVendorTab[2] = {
    { gVendorAxRec, 12, 0, 0, "axon" },
    { gVendorMoRec,  8, 0, 0, "moto" },
};
static volatile uint32_t gVendorAxon = 0;   // adverts carrying ANY Axon/TASER identifier
static volatile uint32_t gVendorMoto = 0;
uint32_t acabScannerVendorAxon() { return gVendorAxon; }
uint32_t acabScannerVendorMoto() { return gVendorMoto; }
uint32_t acabScannerVendorFull() { return gVendorTab[0].full + gVendorTab[1].full; }
uint32_t acabScannerVendorMacs() {
    uint32_t n = 0;
    for (size_t t = 0; t < 2; t++)
        for (size_t i = 0; i < gVendorTab[t].n; i++) if (gVendorTab[t].rec[i].used) n++;
    return n;
}
static VendorRec* vendorFind(VendorTable* tab, const uint8_t* mac) {
    VendorRec* freeSlot = nullptr;
    for (size_t i = 0; i < tab->n; i++) {
        if (tab->rec[i].used && memcmp(tab->rec[i].mac, mac, 6) == 0) return &tab->rec[i];
        if (!tab->rec[i].used && !freeSlot) freeSlot = &tab->rec[i];
    }
    if (!freeSlot) { tab->full++; return nullptr; }
    memset(freeSlot, 0, sizeof(*freeSlot));
    memcpy(freeSlot->mac, mac, 6);
    freeSlot->best = -127;
    freeSlot->firstMs = millis();
    freeSlot->used = true;
    return freeSlot;
}

// Bitmask of VENDOR_BLE_ID entries this advert structurally carries.
//
// Decoding lives in ble_adv16.h so there is ONE implementation: whatever proves out in a field
// capture is byte-for-byte what a shipping classifier would later match on. An inline copy here
// would drift from the shipping path, and the whole point of the capture is to justify that path.
// It walks AD 0x02/0x03 (service UUID lists), 0x14 (solicitation) and 0x16 (service data, UUID in
// the first two bytes only), and reads EVERY 0xFF structure rather than latching the first.
// SOLICITATION IS KEPT APART FROM CONFIRMATION, and the distinction is not pedantic.
//
// AD 0x02/0x03 (service UUID lists) and 0x16 (service data) are a device SAYING WHAT IT IS. AD
// 0x14 is service SOLICITATION: per the Core Specification Supplement it is a peripheral inviting
// centrals that PROVIDE the named service. So an Axon UUID in 0x14 is a device looking FOR Axon
// equipment - plausibly a phone running Axon's app, or an accessory hunting for a camera. Folding
// it into the same mask would let a bystander's handset be counted as vendor equipment, which is
// the precise failure mode this whole capture-first approach exists to avoid.
//
// It is still worth recording. "Something here was looking for an Axon service" is a real
// observation, and near a confirmed device the two together are more informative than either. It
// just never counts as vendor-confirmed, and it is rendered on its own axis.
struct VendorScanCtx { uint8_t mask; uint8_t solicit; };
static void vendorUuidCb(uint16_t u, uint8_t adType, void* ctx) {
    VendorScanCtx* c = (VendorScanCtx*)ctx;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
        if (VENDOR_BLE_ID[k].kind != 1 || VENDOR_BLE_ID[k].val != u) continue;
        if (adType == ACAB_AD_UUID16_SOLICIT) c->solicit |= (uint8_t)(1u << k);
        else                                  c->mask    |= (uint8_t)(1u << k);
    }
}
static void vendorCidCb(uint16_t cid, void* ctx) {
    VendorScanCtx* c = (VendorScanCtx*)ctx;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++)
        if (VENDOR_BLE_ID[k].kind == 0 && VENDOR_BLE_ID[k].val == cid) c->mask |= (uint8_t)(1u << k);
}
static void vendorScanAdv(const uint8_t* adv, size_t len, uint8_t* mask, uint8_t* solicit) {
    VendorScanCtx c; c.mask = 0; c.solicit = 0;
    acabAdvForEachUuid16(adv, len, vendorUuidCb, &c);
    acabAdvForEachCompanyId(adv, len, vendorCidCb, &c);
    *mask = c.mask; *solicit = c.solicit;
}

// ---------------------------------------------------------------------------------------------
// GROUND-TRUTH MARKER WINDOWS - capture builds only. {"mark":"<label>"} over the config channel.
//
// A mark CLOSES the previous window (printing its summary) and opens a new one. Bracketing a visit
// therefore takes THREE commands, because a mark only ever prints the window it closes:
//     {"mark":"axon-near"}   opens `axon-near`                (prints nothing yet)
//     {"mark":"left"}        prints `axon-near`, opens `left`
//     {"mark":"end"}         prints `left`
// The pair of summaries is the point: what was present, then what persisted.
//
// SCOPE: THE SUMMARY IS BLE ONLY. markNote is fed from the BLE ingest funnel, so WiFi frames and
// Remote ID never appear in it. The [mark] SWITCH line still brackets those in the RAW capture. An
// empty summary means no BLE advert qualified, NOT that nothing was there.
//
// The accounting itself lives in mark_table.h, off-target-testable and free of Arduino. This file
// owns three things it cannot: the lock, the clock, and the printing.
#define MARK_MAX_MACS   24
#define MARK_NEAR_RSSI  (-70)     // "close enough to plausibly be what I am standing next to"

// The table is touched from more than one task: on the dual-radio board the S3's own NimBLE scan
// callback and the nRF UART forwarder both funnel through acabScannerIngestBLE, while the config
// write that raises a mark arrives on the NimBLE host task.
//
// THE CLOCK IS READ INSIDE THE LOCK, always, and that is load-bearing rather than tidiness. When
// millis() was sampled before acquiring the mutex, an advert could carry a timestamp from before
// the boundary and still land in the NEW window - printing first= as an unsigned underflow - or
// carry a newer one and land in the OLD window, printing last= past the window's own dur=. Taking
// the lock is what orders the mutation, so it must also be what orders the timestamp.
//
// PRINTING happens OUTSIDE the lock, against a static snapshot taken inside it: serial output is
// slow and holding a spinlock across it would stall the other radio's task with interrupts off.
// Two concurrent acabScannerMark() calls cannot happen (config writes serialise on the NimBLE host
// task), so the snapshot buffer needs no second guard.
static portMUX_TYPE gMarkMux = portMUX_INITIALIZER_UNLOCKED;
static AcabMarkRec  gMarkRec[MARK_MAX_MACS];
static AcabMarkRec  gMarkSnap[MARK_MAX_MACS];   // print buffer; static so no 1 KB stack frame
static AcabMarkTable gMarkTab = { gMarkRec, MARK_MAX_MACS, 0, 0, 0, 0, false };
static char gMarkLabel[40] = {0};

static void markPrintSnapshot(const char* label, uint32_t startMs, uint32_t durMs,
                              uint32_t otherObs, uint32_t fullObs, uint32_t totalObs) {
    AcabMarkTable snap = { gMarkSnap, MARK_MAX_MACS, otherObs, fullObs, totalObs, startMs, true };
    const uint32_t macs = acabMarkListedMacs(&snap);
    const uint32_t obs  = acabMarkListedObs(&snap);
    // listed_macs is a DEVICE count; listed_obs, other_obs, full_obs and total_obs are ADVERT
    // counts. Mixing the two units is how an earlier version of this printed an "invariant" that
    // could not balance in principle. accounted= asserts the real one, so a reader never has to
    // take it on trust: listed_obs + other_obs + full_obs must equal total_obs.
    Serial.printf("[mark] SUMMARY \"%s\" dur=%lus listed_macs=%lu listed_obs=%lu other_obs=%lu "
                  "full_obs=%lu total_obs=%lu accounted=%s\n",
                  label, (unsigned long)(durMs / 1000), (unsigned long)macs, (unsigned long)obs,
                  (unsigned long)otherObs, (unsigned long)fullObs, (unsigned long)totalObs,
                  acabMarkAccounted(&snap) ? "yes" : "NO");
    for (size_t i = 0; i < MARK_MAX_MACS; i++) {
        AcabMarkRec* m = &gMarkSnap[i];
        if (!m->used) continue;
        char ids[80]; int q = 0; ids[0] = 0;
        for (size_t k = 0; k < VENDOR_BLE_ID_N && q < (int)sizeof(ids) - 18; k++) {
            if (!(m->vendorMask & (1u << k))) continue;
            q += snprintf(ids + q, sizeof(ids) - q, "%s%s:%04X",
                          q ? "," : "", VENDOR_BLE_ID[k].tag, VENDOR_BLE_ID[k].val);
        }
        char sol[80]; int r = 0; sol[0] = 0;
        for (size_t k = 0; k < VENDOR_BLE_ID_N && r < (int)sizeof(sol) - 22; k++) {
            if (!(m->solicitMask & (1u << k))) continue;
            r += snprintf(sol + r, sizeof(sol) - r, "%s%s-SOLICIT:%04X",
                          r ? "," : "", VENDOR_BLE_ID[k].tag, VENDOR_BLE_ID[k].val);
        }
        // addr=unknown until the address TYPE is threaded through ingestion. The top-two-bits
        // encoding describes the random-address SUBTYPE and only means anything once the controller
        // has said the address is random; a PUBLIC address may hold any pattern. Applied blind it
        // mislabels exactly the devices this capture is for - Axon's public 00:25:DF has top bits
        // 00 and printed as "rand-nonres". Guessing invents a property of the device.
        Serial.printf("[mark]   %02X:%02X:%02X:%02X:%02X:%02X addr=unknown n=%lu best=%d "
                      "first=%lus last=%lus classifier=%s vendor=%s solicit=%s name=\"%s\"\n",
                      m->mac[0], m->mac[1], m->mac[2], m->mac[3], m->mac[4], m->mac[5],
                      (unsigned long)m->n, (int)m->best,
                      (unsigned long)((m->firstMs - startMs) / 1000),
                      (unsigned long)((m->lastMs  - startMs) / 1000),
                      m->matchedType == 0xFF ? "none" : acabTypeLabel((AcabDeviceType)m->matchedType),
                      ids[0] ? ids : "-", sol[0] ? sol : "-", m->name);
    }
    Serial.printf("[mark] END \"%s\"\n", label);
}

void acabScannerMark(const char* label) {
    // Sanitise FIRST, outside the lock: running acabSanitizeAscii on attacker-supplied text with
    // interrupts disabled is not a trade worth making, and the result is needed before the switch.
    char clean[sizeof(gMarkLabel)];
    acabSanitizeAscii(clean, (const uint8_t*)(label ? label : ""),
                      label ? strlen(label) : 0, sizeof(clean));

    char     prevLabel[sizeof(gMarkLabel)] = {0};
    uint32_t prevStart = 0, prevDur = 0, prevOther = 0, prevFull = 0, prevTotal = 0;
    bool     hadOpen = false;
    uint32_t atMs;

    portENTER_CRITICAL(&gMarkMux);
    atMs = millis();                       // inside the lock: THIS instant is the boundary
    hadOpen = gMarkTab.open;
    if (hadOpen) {
        memcpy(gMarkSnap, gMarkRec, sizeof(gMarkRec));
        memcpy(prevLabel, gMarkLabel, sizeof(prevLabel));
        prevStart = gMarkTab.startMs;
        prevDur   = atMs - gMarkTab.startMs;
        prevOther = gMarkTab.otherObs;
        prevFull  = gMarkTab.fullObs;
        prevTotal = gMarkTab.totalObs;
    }
    acabMarkReset(&gMarkTab, atMs);
    memcpy(gMarkLabel, clean, sizeof(gMarkLabel));
    portEXIT_CRITICAL(&gMarkMux);

    // at_ms IS THE AUTHORITATIVE BOUNDARY. Not this line's position in the serial stream.
    //
    // The line is emitted immediately after the unlock, which removes the previous ambiguity (the
    // summary's up-to-24 rows used to print first, so WiFi and Remote ID arriving during them
    // appeared BEFORE the marker despite belonging after it). It does not make serial ordering
    // strict: another task can still slip one line in between the true boundary and this print.
    // Guaranteeing literal line order would mean routing every diagnostic through a single queue,
    // which is not worth it for a bench build.
    //
    // So a reader compares at_ms against the timestamps around it, and never infers the boundary
    // from position alone. The summary that follows is a report about the window just closed.
    Serial.printf("[mark] SWITCH at_ms=%lu closed=\"%s\" opened=\"%s\"\n",
                  (unsigned long)atMs, hadOpen ? prevLabel : "-", clean);
    if (hadOpen) markPrintSnapshot(prevLabel, prevStart, prevDur, prevOther, prevFull, prevTotal);
}

// Feed one advert into the open window. Called AFTER the classifier chain, so the summary can say
// which shipping classifier would have claimed the device - the field that tells you whether a new
// signature is needed at all or an existing one already covers it.
static void markNote(const uint8_t* mac, int rssi, const char* name,
                     uint8_t vendorMask, uint8_t solicitMask, bool matched, uint8_t matchedType) {
    portENTER_CRITICAL(&gMarkMux);
    acabMarkNote(&gMarkTab, mac, rssi, name, vendorMask, solicitMask, matched, matchedType,
                 millis(), MARK_NEAR_RSSI);   // clock sampled under the same lock, see above
    portEXIT_CRITICAL(&gMarkMux);
}
#endif  // ACAB_CAPTURE_BUILD

void acabScannerIngestBLE(const uint8_t mac[6], const uint8_t* payload, size_t plen, int rssi, bool isReplay) {
    gBleSeen++;
#if defined(ACAB_CAPTURE_BUILD) || defined(ACAB_DIAG)
    // Parse the advert's local name ONCE per live packet and share the buffer. Capture builds
    // otherwise paid this payload walk up to three times per advert (the body-cam candidate
    // annotation, the [ble] raw line, the marker window) - real money at drive-test advert
    // rates. Live builds (neither define set) compile this out entirely.
    char advName[32];
    advName[0] = 0;
    if (!isReplay) bleWatchName(payload, plen, advName, sizeof(advName));
#endif
#ifdef ACAB_CAPTURE_BUILD
    // OUI candidates are a capture annotation only. They do not join the classifier chain below,
    // do not fill AcabDetection, and never reach the apps. Keep the pointer for the existing raw
    // [ble] line so annotating a candidate adds no second high-rate serial record.
    const AcabAlprCandidate* alprCandidate = isReplay ? nullptr : acabAlprCandidateMatch(mac);
    if (alprCandidate) gAlprCandidateBleSeen++;
    if (!isReplay && payload && plen) logBodyCamNameCandidate(mac, advName, rssi);
    // Vendor-identifier scan. Logs, never classifies, never reaches the apps. Runs before the
    // classifier chain so a device that ALSO matches a shipping signature is still recorded here:
    // the co-occurrence (which identifier travels with which existing detection) is one of the
    // more useful things this capture can produce. The mask is hoisted to function scope because
    // the marker window below needs it AFTER the chain has run, to pair the vendor evidence with
    // whichever classifier did or did not claim the device.
    uint8_t vendorHit = 0, vendorSol = 0;
    if (!isReplay && payload && plen) {
        uint8_t hit = 0, sol = 0;
        vendorScanAdv(payload, plen, &hit, &sol);
        vendorHit = hit; vendorSol = sol;
        // Only a CONFIRMED identifier opens a vendor record. A solicitation-only advert is carried
        // into the marker window (below) but never counted as this vendor's equipment.
        if (hit) {
            bool axon = false, moto = false;
            for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
                if (!(hit & (1u << k))) continue;
                if (VENDOR_BLE_ID[k].tag[0] == 'A') axon = true; else moto = true;
            }
            if (axon) gVendorAxon++;
            if (moto) gVendorMoto++;
            VendorTable* tab = axon ? &gVendorTab[0] : &gVendorTab[1];
            VendorRec* v = vendorFind(tab, mac);
            const uint32_t nowMs = millis();
            bool emit;
            if (v) {
                v->n++;
                if ((int8_t)rssi > v->best) v->best = (int8_t)rssi;
                v->hits |= hit;
                // First sighting always, then throttled: a radio in a patrol car parked next to
                // you would otherwise print continuously and bury everything else in the capture.
                emit = (v->n == 1) || (nowMs - v->lastLogMs >= VENDOR_LOG_EVERY_MS);
                if (emit) v->lastLogMs = nowMs;
            } else {
                // TABLE FULL. This branch used to leave emit at its `true` initialiser, so the one
                // device that could not get a slot was the only device printed on EVERY advert -
                // the throttle inverted, and the untracked device burying the tracked ones. Throttle
                // the overflow notice itself, and say plainly that the log is now incomplete.
                emit = (nowMs - tab->fullLastLogMs >= VENDOR_LOG_EVERY_MS);
                if (emit) {
                    tab->fullLastLogMs = nowMs;
                    Serial.printf("[vendor] TABLE FULL (%s, %u slots) dropped=%lu - this capture is INCOMPLETE\n",
                                  tab->what, (unsigned)tab->n, (unsigned long)tab->full);
                }
                emit = false;   // the notice above replaces the per-device line
            }
            if (emit) {
                // TWO masks, deliberately. `packet=` is what THIS advert carried; `seen=` is every
                // identifier this MAC has ever shown. They differ constantly, because a device
                // routinely splits its company ID, its service UUIDs and its name across separate
                // adverts. Rendering only the packet mask (as this did) meant the co-occurrence
                // this capture exists to find could never appear in the log even when the firmware
                // had already accumulated it.
                char pk[64]; int q = 0; pk[0] = 0;
                for (size_t k = 0; k < VENDOR_BLE_ID_N && q < (int)sizeof(pk) - 14; k++) {
                    if (!(hit & (1u << k))) continue;
                    q += snprintf(pk + q, sizeof(pk) - q, "%s%s:%04X",
                                  q ? "," : "", VENDOR_BLE_ID[k].tag, VENDOR_BLE_ID[k].val);
                }
                char sn[64]; int r = 0; sn[0] = 0;
                for (size_t k = 0; k < VENDOR_BLE_ID_N && r < (int)sizeof(sn) - 14; k++) {
                    if (!(v->hits & (1u << k))) continue;
                    r += snprintf(sn + r, sizeof(sn) - r, "%s%s:%04X",
                                  r ? "," : "", VENDOR_BLE_ID[k].tag, VENDOR_BLE_ID[k].val);
                }
                // The NAME is the point: the identifier gives the vendor, the name is the only
                // field likely to separate a Body 4 from a TASER 10 battery. It can legitimately be
                // empty here - this build scans PASSIVELY, so a name carried only in the scan
                // response is never requested. An identifier with no name is a reason to repeat
                // that one test with active scanning, not evidence the device is nameless.
                Serial.printf("[vendor] packet=%s seen=%s %02X:%02X:%02X:%02X:%02X:%02X rssi=%d n=%lu %lus best=%d name=\"%s\"\n",
                              pk[0] ? pk : "-", sn[0] ? sn : "-",
                              mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi,
                              (unsigned long)v->n, (unsigned long)((nowMs - v->firstMs) / 1000),
                              (int)v->best, advName);
            }
        }
    }
#endif
#ifdef ACAB_DIAG
    // Ground-truth trace (bench/drive builds only): one line per LIVE advert, matched or not, with
    // the decoded local name if the advert carries one (AD 0x08/0x09) - the nRF-Connect-style name.
    // This is the SHARED path, so it fires for BOTH the S3's own scan (oui-spy) AND the nRF-
    // forwarded adverts (dual-radio board over UART). There is deliberately NO diag block left in
    // AcabAdvCallbacks::onResult: the capture envs that define ACAB_DIAG clear cfg.enableBLE, so
    // that callback is never installed and anything logged from it would be dead code.
    // Scan-response-only names appear here only in a -DACAB_ACTIVE_SCAN capture build (RF-loud).
    if (!isReplay) {
#ifdef ACAB_CAPTURE_BUILD
        // Candidate annotations add useful context, but raw evidence still comes first. This holds
        // the full hex for a 255-byte scanner payload plus the longest candidate preamble. If a
        // future scanner forwards more, the line says exactly how many bytes were retained.
        char line[768];
#else
        char line[240];
#endif
        int p;
#ifdef ACAB_CAPTURE_BUILD
        if (alprCandidate) {
            p = snprintf(line, sizeof(line),
                         "[ble] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\" "
                         "note=\"vendor prefix candidate; product unknown\" "
                         "addr_type=unknown candidate=\"%s/%s/%u\" adv=",
                         mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, advName,
                         alprCandidate->tag,
                         acabAlprCandidateRegistryLabel(alprCandidate->registry),
                         (unsigned)alprCandidate->prefixBits);
        } else
#endif
        {
            p = snprintf(line, sizeof(line),
                         "[ble] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\" adv=",
                         mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, advName);
        }
        size_t used = p > 0 ? (size_t)p : 0;
        if (used >= sizeof(line)) used = sizeof(line) - 1;
        const size_t rawRoom = sizeof(line) - 1 - used;
        const size_t truncNoteRoom = 64;
        size_t shown = payload ? plen : 0;
        if (shown > rawRoom / 2)
            shown = rawRoom > truncNoteRoom ? (rawRoom - truncNoteRoom) / 2 : 0;
        static const char HEX_DIGIT[] = "0123456789ABCDEF";
        for (size_t k = 0; k < shown; k++) {
            line[used++] = HEX_DIGIT[payload[k] >> 4];
            line[used++] = HEX_DIGIT[payload[k] & 0x0f];
        }
        line[used] = 0;
        if (shown < plen)
            snprintf(line + used, sizeof(line) - used,
                     " [adv_truncated shown=%lu total=%lu]",
                     (unsigned long)shown, (unsigned long)plen);
        Serial.println(line);
        // "Pigvision" is a candidate Flock BLE name we have not field-confirmed yet, so it is
        // deliberately NOT in the production name table (FLOCK_NAME_PATTERNS, flock_signatures.h).
        // Flag it loudly so a bracketed capture next to a real unit is the signal to promote it.
        // This lives on the SHARED funnel, not in AcabAdvCallbacks::onResult where it started: the
        // only envs that define ACAB_DIAG are the dual-radio capture builds, and those clear
        // cfg.enableBLE (the nRF does the BLE scanning), so the callback is never installed and the
        // marker could not fire in any checked-in configuration. Reuses advName, parsed once above,
        // so the check costs no second payload walk and no per-advert allocation.
        if (acabAsciiCiContains(advName, "pigvision"))
            Serial.printf("[ble] *** PIGVISION CANDIDATE *** %02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\"\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, advName);
    }
#endif
    AcabDetection d;
    // The BLE mfg company ID (SIG assigned #) rides in the advert payload, MAC-independent, so
    // grab it once and stamp it on whatever matches. It's the field the glasses/tracker detectors
    // key on; surfacing it lets the app show/log why a device did (or didn't) classify.
    const uint16_t companyId = acabBleCompanyId(payload, plen);
    // Try most-specific first: drone (standardised) -> Flock -> tracker -> glasses -> Axon, then
    // the broad Motorola/LE-gear OUI last so it never preempts a real match. The || chain
    // short-circuits at the first match, preserving that priority (only the winner fills `d`).
    bool matched = droneClassifyBLE(mac, payload, plen, rssi, &d)
                || flockClassifyBLE(mac, payload, plen, rssi, &d)
                || trackerClassifyBLE(mac, payload, plen, rssi, &d)
                || glassesClassifyBLE(mac, payload, plen, rssi, &d)
                || axonClassifyBLE(mac, payload, plen, rssi, &d)
                || policeClassifyBLE(mac, payload, plen, rssi, &d);
#ifdef ACAB_CAPTURE_BUILD
    // Ground-truth marker window (see acabScannerMark). Placed HERE, after the chain, so the
    // summary can report which shipping classifier claimed the device - "classifier=none beside a
    // confirmed vendor identifier" is precisely the row that justifies a new signature, and
    // "classifier=Body camera" is the row that says one already exists.
    if (!isReplay && payload && plen) {
        // advName may run longer than the mark table's 24-byte field; acabMarkNote clamps on
        // copy, and the sanitizer maps bytes 1:1, so the stored prefix is identical either way.
        markNote(mac, rssi, advName, vendorHit, vendorSol, matched,
                 matched ? (uint8_t)d.type : (uint8_t)0xFF);
    }
#endif
    // Watchlist (AFTER the built-in signatures so a real match keeps its specific type,
    // BEFORE desert): a user-starred MAC alerts even with no signature. Synthesize a
    // ACAB_WATCHED hit and run it through the normal pipeline. Carry the advert name.
    if (!matched && isWatched(mac)) {
        acabInit(&d, ACAB_WATCHED, SRC_BLE, mac, (int16_t)rssi);
        d.method     = M_WATCHLIST;   // exact-MAC user rule; NOT M_OUI, so durability leaves it at 100
        d.confidence = 100;
        bleWatchName(payload, plen, d.name, sizeof(d.name));
        matched = true;
    }
    // Our own sibling board, if any: drop it before Desert synthesises a nearby-device row.
    // Deliberately AFTER the whole signature chain and the watchlist, so a device that merely
    // names itself "beacon" is still fully classified by every real signature and can still be
    // starred; this only suppresses the generic Desert row. See isSiblingBoard().
    if (!matched && isSiblingBoard(payload, plen)) return;
    // Desert mode (LAST): catch every remaining device as a generic "nearby device".
    if (!matched) matched = desertClassifyBLE(mac, payload, plen, rssi, &d);
    if (!matched) return;
    if (companyId) d.companyId = companyId;   // stamp the BLE mfg company ID on the match
    handleDetection(d, isReplay);
}

class AcabAdvCallbacks : public NimBLEAdvertisedDeviceCallbacks {
public:
    void onResult(NimBLEAdvertisedDevice* dev) override {
        // NimBLE keeps the address little-endian and getNative() points at a
        // temporary, so copy it AND flip to human order (mac[0] = OUI byte), which
        // is what our OUI tables expect.
        NimBLEAddress addr = dev->getAddress();
        const uint8_t* nat = addr.getNative();
        if (!nat) return;
        uint8_t mac[6];
        for (int i = 0; i < 6; i++) mac[i] = nat[5 - i];

        int rssi = dev->getRSSI();
        uint8_t* payload = dev->getPayload();
        size_t   plen    = dev->getPayloadLength();

        // The per-advert "[ble] ... name=... adv=..." diag line now lives in the SHARED
        // acabScannerIngestBLE (below), so it covers the dual-radio UART path too, not just
        // this S3-only scan. It decodes the local name there. The Pigvision candidate marker
        // moved with it, for a stronger version of the same reason: ACAB_DIAG is only ever
        // defined by the dual-radio capture envs, which clear cfg.enableBLE, so this callback
        // is not even installed there and anything left behind here is dead. Nothing to log here.

        // Hand the advert to the shared classifier chain (kept in one place so the
        // dual-radio UART path runs the exact same detectors).
        acabScannerIngestBLE(mac, payload, plen, rssi);
    }
};

static void bleScanTask(void*) {
    for (;;) {
        if (gScan && gBleEnabled) {
            gScan->start(2, false);   // 2 s windows, then clear results and go again
            gScan->clearResults();
        } else {
            vTaskDelay(pdMS_TO_TICKS(200));
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// ---------------------------------------------------------------------------
// WiFi
// ---------------------------------------------------------------------------
#ifdef ACAB_DIAG_WIFI
// Bench diagnostic: log every beacon / probe-response (BSSID + SSID + RSSI), so a
// field test next to a pole-mounted camera can spot its WiFi presence, if any.
// Parsing + serial run off the promiscuous callback via a queue and task.
// The first 33 bytes still hold every legal SSID. Capture-only annotations need enough room to
// state the evidence boundary in the log itself: vendor prefix candidate, product unknown.
struct WifiDiagItem { uint8_t bssid[6]; int8_t rssi; char ssid[128]; };
static QueueHandle_t gWifiDiagQ = nullptr;

// EVERY diagnostic enqueue goes through wifiDiagPush so a full queue is COUNTED, never silently
// swallowed. xQueueSend(..., 0) drops on a full queue by design, because the promiscuous
// callback must not block; the cost is that loss is invisible at the point it happens. That
// matters now: the capture build logs every probe request, which is a large step up in queue
// pressure, and "nothing appeared in the capture" is only evidence of absence if the log can
// also say nothing was dropped. The [diag] line reports both counters.
static volatile uint32_t gWifiDiagSent = 0;
static volatile uint32_t gWifiDiagDropped = 0;
static inline void wifiDiagPush(const WifiDiagItem& it) {
    if (!gWifiDiagQ) return;
    if (xQueueSend(gWifiDiagQ, &it, 0) == pdTRUE) gWifiDiagSent++;
    else                                          gWifiDiagDropped++;
}
uint32_t acabScannerWifiDiagDropped() { return gWifiDiagDropped; }
uint32_t acabScannerWifiDiagSent()    { return gWifiDiagSent; }
static void wifiDiagTask(void*) {
    WifiDiagItem it;
    for (;;)
        if (xQueueReceive(gWifiDiagQ, &it, portMAX_DELAY) == pdTRUE)
            Serial.printf("[wifi] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d ssid=\"%s\"\n",
                          it.bssid[0], it.bssid[1], it.bssid[2], it.bssid[3], it.bssid[4],
                          it.bssid[5], it.rssi, it.ssid);
}

#ifdef ACAB_CAPTURE_BUILD
// Registered ALPR-vendor prefixes, capture builds only. This is deliberately separate from the
// older diagnostic watchlist: these rows have exact IEEE widths and a named registrant, while the
// WATCH row is one ambiguous shared-silicon lead. Neither produces a detection.
//
// Data traffic can arrive hundreds of times a second. Keep one record per exact MAC and emit its
// first frame plus one summary every five seconds. The counters remain exact even when output is
// throttled, and alpr_full on the [diag] heartbeat says when the distinct-device count is only a
// floor. Management frames also pass through this throttle because the ordinary [wifi] line still
// preserves every beacon/probe; the extra ALPR line is an index, not the evidence itself.
struct AlprWifiRec {
    uint8_t  mac[6];
    uint32_t count;
    uint32_t data;
    uint32_t mgmt;
    uint16_t subtypes;
    int8_t   best;
    uint8_t  addrMask;
    uint32_t lastLogMs;
    bool     used;
};
static const size_t ALPR_WIFI_MAX = 24;
static const uint32_t ALPR_WIFI_LOG_EVERY_MS = 5000;
static AlprWifiRec gAlprWifi[ALPR_WIFI_MAX];

uint32_t acabScannerAlprCandidateMacs() {
    return gAlprCandidateMacs.load();
}
uint32_t acabScannerAlprCandidateTableFull() { return gAlprCandidateTableFull.load(); }

static AlprWifiRec* alprWifiFind(const uint8_t mac[6]) {
    AlprWifiRec* freeSlot = nullptr;
    for (size_t i = 0; i < ALPR_WIFI_MAX; i++) {
        if (gAlprWifi[i].used && memcmp(gAlprWifi[i].mac, mac, 6) == 0) return &gAlprWifi[i];
        if (!gAlprWifi[i].used && !freeSlot) freeSlot = &gAlprWifi[i];
    }
    if (!freeSlot) { gAlprCandidateTableFull++; return nullptr; }
    memset(freeSlot, 0, sizeof(*freeSlot));
    memcpy(freeSlot->mac, mac, 6);
    freeSlot->best = -127;
    freeSlot->used = true;
    gAlprCandidateMacs++;
    return freeSlot;
}

static bool alprWifiNote(const uint8_t mac[6], uint8_t addressMask, bool data,
                         uint8_t frameControl, int rssi) {
    const AcabAlprCandidate* candidate = acabAlprCandidateMatch(mac);
    if (!candidate) return false;
    gAlprCandidateWifiSeen++;

    AlprWifiRec* rec = alprWifiFind(mac);
    const uint32_t nowMs = millis();
    bool emit = false;
    if (rec) {
        rec->count++;
        if (data) rec->data++;
        else {
            rec->mgmt++;
            rec->subtypes |= (uint16_t)(1u << ((frameControl >> 4) & 0x0f));
        }
        if ((int8_t)rssi > rec->best) rec->best = (int8_t)rssi;
        rec->addrMask |= addressMask;
        emit = (rec->count == 1) || (nowMs - rec->lastLogMs >= ALPR_WIFI_LOG_EVERY_MS);
        if (emit) rec->lastLogMs = nowMs;
    } else {
        // A full table must not make the untracked device the loudest one in the log. Throttle the
        // warning itself, matching the established WATCH/Falcon overflow policy.
        static uint32_t fullLastMs = 0;
        if (nowMs - fullLastMs >= ALPR_WIFI_LOG_EVERY_MS) {
            fullLastMs = nowMs;
            WifiDiagItem it; memcpy(it.bssid, mac, 6); it.rssi = (int8_t)rssi;
            snprintf(it.ssid, sizeof(it.ssid),
                     "vendor prefix candidate TABLEFULL product unknown dropped=%lu",
                     (unsigned long)gAlprCandidateTableFull.load());
            wifiDiagPush(it);
        }
    }
    if (emit) {
        WifiDiagItem it; memcpy(it.bssid, mac, 6); it.rssi = (int8_t)rssi;
        snprintf(it.ssid, sizeof(it.ssid),
                 "vendor prefix candidate %s/%s/%u product unknown n=%lu d=%lu m=%lu "
                 "st=%04X best=%d a=%X",
                 candidate->tag, acabAlprCandidateRegistryLabel(candidate->registry),
                 (unsigned)candidate->prefixBits, (unsigned long)rec->count,
                 (unsigned long)rec->data, (unsigned long)rec->mgmt,
                 (unsigned)rec->subtypes, (int)rec->best, (unsigned)rec->addrMask);
        wifiDiagPush(it);
    }
    return true;
}

// Inspect every address the delivered 802.11 header actually carries. addr2 is the transmitter on
// management frames; on data frames the candidate can be addr1, addr2, addr3, or addr4 depending
// on ToDS/FromDS. The log's a= mask preserves where it matched instead of pretending every address
// was the source. Repeated copies of the same MAC in one header count once, while their complete
// union of address-field roles is retained.
static bool alprWifiScanAddresses(const uint8_t* frame, size_t len, bool data, int rssi) {
    if (!frame || len < 24) return false;
    const uint8_t* addr[4] = { frame + 4, frame + 10, frame + 16, nullptr };
    size_t count = 3;
    if (data && len >= 30 && (frame[1] & 0x03) == 0x03) addr[count++] = frame + 24;
    bool any = false;
    for (size_t i = 0; i < count; i++) {
        bool duplicate = false;
        for (size_t j = 0; j < i; j++)
            if (memcmp(addr[i], addr[j], 6) == 0) { duplicate = true; break; }
        if (duplicate) continue;
        uint8_t addressMask = 0;
        for (size_t j = i; j < count; j++)
            if (memcmp(addr[i], addr[j], 6) == 0) addressMask |= (uint8_t)(1u << j);
        if (alprWifiNote(addr[i], addressMask, data, frame[0], rssi)) any = true;
    }
    return any;
}
#endif

// Flock Falcon Wi-Fi OUIs seen in the field (own captures, 2026-06),
// all Liteon allocations. Liteon is shared silicon = FP-prone (bench only); a
// production match needs the specific Falcon sub-OUI range, not the whole block.
static inline bool falconOui(const uint8_t* m) {
    return (m[0]==0xD8 && m[1]==0xF3 && m[2]==0xBC) ||   // D8:F3:BC
           (m[0]==0xC0 && m[1]==0x35 && m[2]==0x32) ||   // C0:35:32
           (m[0]==0x24 && m[1]==0xB2 && m[2]==0xB9) ||   // 24:B2:B9
           (m[0]==0xF4 && m[1]==0x6A && m[2]==0xDD);     // F4:6A:DD
}

#ifdef ACAB_CAPTURE_BUILD
// DIAGNOSTIC WATCHLIST - capture builds only, and deliberately NOT a classifier.
//
// OUIs that are interesting enough to want every frame of, but nowhere near good enough to
// label a device by. A match logs the frame type and lets the co-signals in the surrounding
// capture speak; it never produces a detection, never reaches the apps, and is compiled out of
// every shipping build.
//
// 08:3A:88 is the current occupant. A crowdsourced list called it "Espressif Flock Falcon V2
// Wi-Fi module" AND, on the same page, flagged a Ring conflict; IEEE actually assigns it to
// Universal Global Scientific Industrial. It showed up twice in the 2026-08-07 capture eight
// seconds after the confirmed FS-BEC46A hit, which is the only reason it is here, but it carried
// an unrelated-looking "MH1M-PEB200827-000975" payload and was completely absent from the
// six-minute capture taken ten feet from a camera. So: worth watching, not worth believing.
static inline bool diagWatchOui(const uint8_t* m) {
    return (m[0]==0x08 && m[1]==0x3A && m[2]==0x88);     // 08:3A:88  UGSI; see note above
}
// PER-MAC watch accounting, so a hit is interpretable instead of just counted.
//
// The first cut of this logged the first GLOBAL hit and then every 250th. On the 2026-08-08 drive
// that produced exactly ONE line for 143 frames, and the one thing that mattered - that 142 of
// those frames landed inside a single visually-confirmed Flock stop, starting on approach and
// stopping on departure - was only recoverable because the running total happens to ride the 5 s
// [diag] heartbeat. Do not rely on that again: log per MAC, keep per-MAC evidence, and rate limit
// on TIME so the shape of a sighting survives however few or many frames it contains.
struct WatchRec {
    uint8_t  mac[6];
    uint32_t count;        // frames from this MAC
    int8_t   best;         // strongest RSSI seen
    uint8_t  addrMask;     // bit k set = matched in address field k+1 (addr1/2/3)
    uint32_t lastLogMs;    // time-based throttle, per MAC
    bool     used;
};
static const uint32_t WATCH_LOG_EVERY_MS = 5000;   // at most one line per MAC per 5 s
static const size_t   WATCH_MAX = 8;               // distinct watched MACs tracked at once
static WatchRec gDiagWatch[WATCH_MAX];
static volatile uint32_t gWatchDataSeen = 0;       // total across every watched MAC
uint32_t acabScannerWatchDataSeen() { return gWatchDataSeen; }

// Returns the record for `mac`, allocating on first sight. Null only if the table is full, which
// is itself worth knowing, so the caller still counts the frame.
static WatchRec* watchFind(const uint8_t* mac) {
    WatchRec* freeSlot = nullptr;
    for (size_t i = 0; i < WATCH_MAX; i++) {
        if (gDiagWatch[i].used && memcmp(gDiagWatch[i].mac, mac, 6) == 0) return &gDiagWatch[i];
        if (!gDiagWatch[i].used && !freeSlot) freeSlot = &gDiagWatch[i];
    }
    if (!freeSlot) return nullptr;
    memcpy(freeSlot->mac, mac, 6);
    freeSlot->count = 0; freeSlot->best = -127; freeSlot->addrMask = 0;
    freeSlot->lastLogMs = 0; freeSlot->used = true;
    return freeSlot;
}

// FALCON-OUI MODE ACCOUNTING - capture builds only, and deliberately NOT a classifier.
//
// Measures the one thing the shipping WiFi rule cannot see. EVERY WiFi ALPR hit this project has
// ever recorded came from a single rule (flock_detect.cpp, falconWifiOui() on subtype 0x4), and
// the app's own exported history says so without exception: all six 2026-07-17 ALPR rows and both
// 2026-07-24 rows matched on "wildcard probe". A station emits wildcard probes while it is
// SCANNING for a network and stops once it associates, so a Falcon that joins its backhaul goes
// silent to us with nothing having changed in the firmware. That is what the 2026-08-08 drives
// recorded: 17,156 probe requests from 5,007 distinct MAC prefixes and ZERO from a Falcon OUI,
// while still catching four DATA frames from 24:B2:B9 - the same hardware, associated. A 2026-07-17
// detection sits 40 m from a pole that produced nothing across ~28 minutes of parking on 08-08,
// under two firmware versions from either side of the suspected regression window.
//
// The fix under consideration is a data-frame path for falconWifiOui(). It must not ship on a
// guess. These are Liteon NICs (see flock_signatures.h), and an ASSOCIATED Liteon device is far
// more common than a probing one, so a bare OUI match on data frames is a WORSE false-positive
// magnet than the probe gate it would relax. So measure the false-positive population and the
// dwell separation first, which is the same discipline flock_signatures.h already demands
// ("confirm at a live Falcon in our own capture") and bodycam_vendor_signatures.h's
// field-validation queue.
//
// What to read off a capture, per Falcon-OUI MAC: DATA frame count, MGMT frame count and WHICH
// subtypes, the dwell span, and the best RSSI. A pole-mounted camera should show a long dwell and
// a large data count; a laptop driving past should not. If those two populations do not separate
// cleanly, the data-frame rule does not ship.
struct FalconRec {
    uint8_t  mac[6];
    uint32_t data;        // data frames from this MAC
    uint32_t mgmt;        // management frames from this MAC
    uint16_t subtypes;    // bit k set = mgmt subtype k seen (0x4 probe-req, 0x5 probe-resp, 0x8 beacon)
    int8_t   best;        // strongest RSSI on any path
    uint8_t  addrMask;    // bit k set = matched in address field k+1 (addr1/2/3)
    uint32_t firstMs;     // start of the dwell span a promotion threshold would key on
    uint32_t lastLogMs;   // per-MAC time throttle, data path only
    bool     used;
};
static const size_t FALCON_MAX = 16;          // distinct Falcon-OUI MACs tracked at once
static FalconRec gFalcon[FALCON_MAX];
static volatile uint32_t gFalconData      = 0;   // true totals, independent of how many lines printed
static volatile uint32_t gFalconMgmt      = 0;
static volatile uint32_t gFalconTableFull = 0;   // a nonzero here means FALCON_MAX is too small to trust
uint32_t acabScannerFalconData()      { return gFalconData; }
uint32_t acabScannerFalconMgmt()      { return gFalconMgmt; }
uint32_t acabScannerFalconTableFull() { return gFalconTableFull; }
uint32_t acabScannerFalconMacs() {
    uint32_t n = 0;
    for (size_t i = 0; i < FALCON_MAX; i++) if (gFalcon[i].used) n++;
    return n;
}

// Record for `mac`, allocating on first sight. Null when the table is full, which is itself a
// finding (too many Falcon-OUI devices around for the proposed rule to be safe), so the caller
// still counts the frame and gFalconTableFull records that it happened.
static FalconRec* falconRecFind(const uint8_t* mac) {
    FalconRec* freeSlot = nullptr;
    for (size_t i = 0; i < FALCON_MAX; i++) {
        if (gFalcon[i].used && memcmp(gFalcon[i].mac, mac, 6) == 0) return &gFalcon[i];
        if (!gFalcon[i].used && !freeSlot) freeSlot = &gFalcon[i];
    }
    if (!freeSlot) { gFalconTableFull++; return nullptr; }
    memcpy(freeSlot->mac, mac, 6);
    freeSlot->data = 0; freeSlot->mgmt = 0; freeSlot->subtypes = 0;
    freeSlot->best = -127; freeSlot->addrMask = 0;
    freeSlot->firstMs = millis(); freeSlot->lastLogMs = 0; freeSlot->used = true;
    return freeSlot;
}
#endif
#endif

// Compute + install the promiscuous frame filter. Production is MGMT-only (beacons + probe
// req/resp): data frames are a firehose whose CPU + 2.4GHz-coexistence cost we refuse to pay
// by default. We widen to DATA ONLY when the network-camera opt-in is on (its source-MAC OUI
// match needs data frames) or in a bench diag build. When the opt-in is off the driver never
// delivers a data frame at all, so the OFF path is genuinely zero-cost. Callable at runtime:
// netcamSetEnabled() invokes acabScannerRefreshWifiFilter() on every flip.
static void applyWifiPromiscFilter() {
    wifi_promiscuous_filter_t pf;
    uint32_t mask = WIFI_PROMIS_FILTER_MASK_MGMT;
    if (netcamIsEnabled()) mask |= WIFI_PROMIS_FILTER_MASK_DATA;   // opt-in camera data-frame OUI match
#ifdef ACAB_DIAG_WIFI
    mask |= WIFI_PROMIS_FILTER_MASK_DATA;                          // bench: also capture data frames
#endif
    pf.filter_mask = mask;
    esp_wifi_set_promiscuous_filter(&pf);
}

static void IRAM_ATTR wifiRxCallback(void* buf, wifi_promiscuous_pkt_type_t type) {
    if (!gWifiEnabled) return;
    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    const uint8_t* payload = pkt->payload;
    int len  = pkt->rx_ctrl.sig_len;
    int rssi = pkt->rx_ctrl.rssi;
    if (len < 24) return;

#ifdef ACAB_DIAG_WIFI
    // DATA frames: Falcon cams ride as WiFi clients (no "Flock-" beacon), so look for
    // a Falcon MAC OUI in any of the three address fields (addr1 @+4, addr2 @+10,
    // addr3 @+16) and log it. PROVISIONAL OUIs from own captures; Liteon is shared
    // silicon so this is FP-prone - bench validation only.
    if (type == WIFI_PKT_DATA && gWifiDiagQ) {
        static uint32_t gDataN = 0; gDataN++;
        const uint8_t* aa[3] = { payload + 4, payload + 10, payload + 16 };
        // The two scans below are INDEPENDENT, and deliberately so. An earlier version made the
        // watchlist conditional on the Falcon scan missing, which meant a frame carrying BOTH a
        // known Falcon address and a watched OUI logged only the Falcon and hid the watch hit.
        // That co-occurrence, a watched device exchanging data with a confirmed Falcon, is the
        // single most valuable thing this capture path could ever record, and it was the one
        // case suppressed. loggedAnything exists ONLY to suppress the generic DATA-sample below.
        bool loggedAnything = false;
#ifdef ACAB_CAPTURE_BUILD
        loggedAnything = alprWifiScanAddresses(payload, (size_t)len, /*data=*/true, rssi);
#endif
        for (int k = 0; k < 3; k++) {
            const uint8_t* m = aa[k];
            if (!falconOui(m)) continue;
#ifdef ACAB_CAPTURE_BUILD
            // ACCOUNTED + TIME-THROTTLED (see FalconRec). An associated camera streams data by
            // the hundred per second, and the unthrottled push this replaces would fill the diag
            // queue and discard the probe/beacon co-signals that give the sighting its meaning -
            // the same way the watchlist above already had to learn. gFalconData keeps the true
            // total regardless of how few lines were printed, and rides the [diag] heartbeat.
            //
            // The count and the dwell ARE the measurement: they are what a promotion threshold
            // ("N frames spanning T seconds") would have to key on to separate a pole-mounted
            // camera from a laptop driving past. Print them per MAC or there is nothing to fit
            // the threshold to.
            gFalconData++;
            FalconRec* f = falconRecFind(m);
            const uint32_t nowMs = millis();
            bool emit;
            if (f) {
                f->data++;
                if ((int8_t)rssi > f->best) f->best = (int8_t)rssi;
                f->addrMask |= (uint8_t)(1u << k);
                emit = (f->data == 1) || (nowMs - f->lastLogMs >= WATCH_LOG_EVERY_MS);
                if (emit) f->lastLogMs = nowMs;
            } else {
                // TABLE FULL. Leaving emit at a `true` initialiser here inverted the throttle: the
                // one device that could NOT be tracked became the only one printed on every single
                // frame, burying the ones that were. Throttle the overflow notice instead.
                static uint32_t fullLastMs = 0;
                emit = false;
                if (nowMs - fullLastMs >= WATCH_LOG_EVERY_MS) {
                    fullLastMs = nowMs;
                    WifiDiagItem it; memcpy(it.bssid, m, 6); it.rssi = (int8_t)rssi;
                    snprintf(it.ssid, sizeof(it.ssid), "FAL-DATA TABLEFULL n=%lu",
                             (unsigned long)gFalconTableFull);
                    wifiDiagPush(it);
                }
            }
            if (emit) {
                WifiDiagItem it;
                memcpy(it.bssid, m, 6);
                it.rssi = (int8_t)rssi;
                snprintf(it.ssid, sizeof(it.ssid), "FAL-DATA n=%lu %lus b=%d a=%u",
                         (unsigned long)f->data,
                         (unsigned long)((nowMs - f->firstMs) / 1000),
                         (int)f->best, (unsigned)f->addrMask);   // f is non-null: emit is only true above when it is
                wifiDiagPush(it);
            }
#else
            WifiDiagItem it;
            memcpy(it.bssid, m, 6);
            it.rssi = (int8_t)rssi;
            // "fwnote:" prefix, NOT a bare word. This label lands in the ssid= field of the
            // [wifi] diagnostic line, and it only prints once falconOui() has already matched,
            // so it says nothing the OUI table did not already say. The old spelling was
            // "DATA-FALCON", which read back out of a capture as a broadcast SSID and became the
            // sole evidence for a shipping conf-85 "*-FALCON" SSID rule (now ext=1; see
            // FLOCK_SSID_FALCON_SUFFIX). Keep any label written here impossible to mistake for
            // an SSID the air actually carried.
            memcpy(it.ssid, "fwnote:falcon-oui-data", sizeof("fwnote:falcon-oui-data"));
            wifiDiagPush(it);
#endif
            loggedAnything = true;
            break;
        }
#ifdef ACAB_CAPTURE_BUILD
        // Diagnostic watchlist on the DATA path too (see diagWatchOui). The mgmt-side copy of
        // this check only fires on management frames, so a watched device that is ASSOCIATED to
        // a network and sending nothing but data would have been invisible unless it happened to
        // probe. That is exactly the case worth catching: a camera on a backhaul link. Checked
        // against all three address fields, like the Falcon match above, since a client's MAC
        // lands in addr1/2/3 depending on the frame's direction.
        //
        // RATE LIMITED, because a watched device that is actively streaming emits data packets
        // by the hundred per second. One serial record each would overflow the diag queue within
        // a second and throw away the probe/beacon co-signals that give the sighting its meaning,
        // i.e. the logging would destroy the evidence it exists to collect. So: per-MAC time
        // throttling (WatchRec + WATCH_LOG_EVERY_MS, below): log a MAC's first match, then at
        // most one line per interval, each carrying the running total.
        // gWatchDataSeen keeps the true count regardless of how few lines were printed, and is
        // reported on the [diag] line, so the log always states the real volume.
        for (int k = 0; k < 3; k++) {
            if (!diagWatchOui(aa[k])) continue;
            gWatchDataSeen++;
            WatchRec* w = watchFind(aa[k]);
            const uint32_t now = millis();
            bool emit;
            if (w) {
                w->count++;
                if ((int8_t)rssi > w->best) w->best = (int8_t)rssi;
                w->addrMask |= (uint8_t)(1u << k);
                // ALWAYS log the first sighting of THIS mac, then throttle on time.
                emit = (w->count == 1) || (now - w->lastLogMs >= WATCH_LOG_EVERY_MS);
                if (emit) w->lastLogMs = now;
            } else {
                // TABLE FULL: same inverted-throttle defect as the Falcon arm above. The untracked
                // MAC must not become the loudest thing in the capture.
                static uint32_t fullLastMs = 0;
                emit = false;
                if (now - fullLastMs >= WATCH_LOG_EVERY_MS) {
                    fullLastMs = now;
                    WifiDiagItem it; memcpy(it.bssid, aa[k], 6); it.rssi = (int8_t)rssi;
                    snprintf(it.ssid, sizeof(it.ssid), "WATCH TABLEFULL");
                    wifiDiagPush(it);
                }
            }
            if (emit) {
                WifiDiagItem it;
                memcpy(it.bssid, aa[k], 6);
                it.rssi = (int8_t)rssi;
                snprintf(it.ssid, sizeof(it.ssid), "WATCH n=%lu best=%d a=%u",
                         (unsigned long)w->count, (int)w->best, (unsigned)w->addrMask);
                wifiDiagPush(it);
            }
            loggedAnything = true;
            break;
        }
#endif
        if (!loggedAnything && (gDataN % 300) == 0) {   // sample: proves data frames are arriving
            WifiDiagItem it;
            memcpy(it.bssid, aa[1], 6);           // addr2 = source
            it.rssi = (int8_t)rssi;
            memcpy(it.ssid, "DATA-sample", 12);
            wifiDiagPush(it);
        }
    }
#endif

    // Production data-frame path: the ONLY thing we do with a data frame is the opt-in
    // network-camera OUI match. It is unreachable unless the user turned the toggle on
    // (the filter above is MGMT-only otherwise, so no data frame is ever delivered), and
    // even then the work is one cheap source-MAC OUI compare. We NEVER serial-log a data
    // frame in production (privacy + firehose). netcamClassifyWiFi self-gates on the toggle.
    if (type == WIFI_PKT_DATA) {
        AcabDetection dc;
        if (netcamClassifyWiFi(payload, len, /*isDataFrame=*/true, rssi, &dc)) handleDetection(dc);
        return;   // data frames never fall through to the mgmt classifiers
    }
    if (type != WIFI_PKT_MGMT) return;
    gWifiSeen++;

#ifdef ACAB_DIAG_WIFI
    // probe request (0x40): Falcon cams scan for networks as WiFi clients, so addr2 is the
    // prober. A KNOWN Falcon OUI is called out by name; in a capture build EVERY prober is
    // logged instead, with the SSID it is asking for.
    //
    // Why the unconditional arm exists: gating this on falconOui() made the capture build
    // circular. Its whole job is to discover a signature we do NOT have yet, but a client on an
    // unknown OUI could not reach the log at all - the mgmt path below only records beacons and
    // probe-responses (i.e. APs), and a client's data frames only surface through the 1-in-300
    // "DATA-sample" heartbeat further up. So a camera that associates to a backhaul network,
    // which is exactly what the comment above says Falcons do, was effectively invisible unless
    // it already matched a signature we had. Field capture 2026-08-07 was read against that
    // blind spot before it was found. Probe requests are chatty, which is the point here and the
    // reason this stays out of shipping builds.
    if (gWifiDiagQ && payload[0] == 0x40) {
        const bool known = falconOui(payload + 10);
#ifndef ACAB_CAPTURE_BUILD
        if (known)
#endif
        {
            WifiDiagItem it;
            memcpy(it.bssid, payload + 10, 6);
            it.rssi = (int8_t)rssi;
            if (known) {
                // "fwnote:" prefix for the same reason as the data-frame label above: this is
                // OUR note about OUR OUI match, not an SSID the frame carried. The old spelling
                // "PROBE-FALCON" was read back out of a capture as a broadcast SSID and became
                // the evidence for a conf-85 rule (now ext=1; see FLOCK_SSID_FALCON_SUFFIX).
                memcpy(it.ssid, "fwnote:falcon-oui-probe", sizeof("fwnote:falcon-oui-probe"));
            } else {
                // "PROBE:<ssid>", or "PROBE:*" for the broadcast (wildcard) probe every client
                // sends. SSID IE sits at [24] for a probe request: tag 0x00, len, then the name.
                memcpy(it.ssid, "PROBE:", 6);
                uint8_t sl = (len >= 26 && payload[24] == 0x00) ? payload[25] : 0;
                if (sl > sizeof(it.ssid) - 7) sl = sizeof(it.ssid) - 7;
                if (sl && 26 + sl <= len) { memcpy(it.ssid + 6, payload + 26, sl); it.ssid[6 + sl] = 0; }
                else                      { it.ssid[6] = '*'; it.ssid[7] = 0; }
            }
            wifiDiagPush(it);
        }
    }
#ifdef ACAB_CAPTURE_BUILD
    // Exact-width ALPR vendor-prefix annotations are an independent capture surface. They never
    // short-circuit the generic probe/beacon trace or any shipping classifier below.
    if (gWifiDiagQ) alprWifiScanAddresses(payload, (size_t)len, /*data=*/false, rssi);

    // Diagnostic watchlist (see diagWatchOui): log the FRAME TYPE, so the capture shows whether
    // the MAC is currently acting as an access point (0x80 beacon), as a client hunting for one
    // (0x40 probe request), or as an associated client (data, logged on the other path).
    // That is BEHAVIOUR AT THAT MOMENT, not identity: plenty of ordinary gear beacons, and a
    // roadside unit on a cellular backhaul may never do any of it. Frame type narrows what a
    // sighting could be; the co-signals around it in the capture are what decide.
    if (gWifiDiagQ && diagWatchOui(payload + 10)) {
        // Management frames are rare and each one is informative (type separates an AP from a
        // client hunting for one), so these are NOT time-throttled. They still feed the per-MAC
        // record so the counts and best RSSI cover every path this MAC was heard on.
        WatchRec* w = watchFind(payload + 10);
        if (w) { w->count++; if ((int8_t)rssi > w->best) w->best = (int8_t)rssi; }
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);
        it.rssi = (int8_t)rssi;
        snprintf(it.ssid, sizeof(it.ssid), "WATCH type=0x%02X n=%lu best=%d", payload[0],
                 (unsigned long)(w ? w->count : 0), (int)(w ? w->best : rssi));
        wifiDiagPush(it);
    }
    // Falcon OUI on a MANAGEMENT frame, ANY subtype (see FalconRec). The probe-request arm below
    // notes "fwnote:falcon-oui-probe" and is the form the shipping OUI rule keys on; this records
    // the frame TYPE for every mgmt frame instead, because the distinction is the whole question:
    // probing (subtype 0x4, scanning, the only form we have ever detected), beaconing (0x8, standing up
    // its own AP), or answering (0x5). Which of those a unit is doing decides whether the
    // data-frame rule is needed at all, and no capture so far has recorded it.
    //
    // NOT throttled. Mgmt frames from one MAC are rare and each is informative, the same reason
    // the watchlist's mgmt arm above is unthrottled while its data arm is not.
    if (gWifiDiagQ && falconOui(payload + 10)) {
        gFalconMgmt++;
        FalconRec* f = falconRecFind(payload + 10);
        if (f) {
            f->mgmt++;
            if ((int8_t)rssi > f->best) f->best = (int8_t)rssi;
            f->subtypes |= (uint16_t)(1u << ((payload[0] >> 4) & 0xF));
        }
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);
        it.rssi = (int8_t)rssi;
        if (f) snprintf(it.ssid, sizeof(it.ssid), "FAL-MGMT t=0x%02X n=%lu st=0x%04X",
                        payload[0], (unsigned long)f->mgmt, (unsigned)f->subtypes);
        else    snprintf(it.ssid, sizeof(it.ssid), "FAL-MGMT t=0x%02X tablefull", payload[0]);
        wifiDiagPush(it);
    }
#endif
    // beacon (0x80) or probe-response (0x50): grab BSSID + SSID for the bench log
    if (gWifiDiagQ && (payload[0] == 0x80 || payload[0] == 0x50) && len >= 38) {
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);   // addr2 = transmitter / BSSID
        it.rssi = (int8_t)rssi;
        it.ssid[0] = 0;
        uint8_t sl = payload[37];            // SSID IE: tag at [36]==0, len at [37]
        if (payload[36] == 0x00 && sl <= 32 && 38 + sl <= len) {
            memcpy(it.ssid, payload + 38, sl); it.ssid[sl] = 0;
        }
        wifiDiagPush(it);                    // counted; drops on overflow rather than blocking
    }
#endif

    AcabDetection d;
    if (droneClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (flockClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    // Axon OUI on a mgmt frame (2026-07-31). Ordered BEFORE the Motorola proxy so that when a
    // frame could satisfy both, the specific named vendor wins over the broad gear guess.
    // In-car video (Axon Fleet) is a WiFi device, so before this an in-car system could only
    // ever land as a generic Nearby Device. Registry-sourced, UNVALIDATED on WiFi - the
    // rationale and the deliberately-lower confidence are documented in axon_detect.h.
    if (axonClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (policeClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    // Network-camera OUI on a mgmt frame (BONUS, opt-in): a branded IP camera acting as its
    // own AP (beacon/probe-resp BSSID) or probing (probe-req) shows its vendor OUI here on the
    // mgmt path we already inspect in production. Self-gates on the opt-in, so it is zero-cost
    // when off. The primary camera signal is the data-frame path above.
    if (netcamClassifyWiFi(payload, len, /*isDataFrame=*/false, rssi, &d)) { handleDetection(d); return; }
    // Watchlist (AFTER the built-in signatures, BEFORE desert): a user-starred MAC alerts
    // even with no signature. addr2 (payload+10) is the transmitter address. No name parse
    // is available on this path, so leave it empty. Runs through the normal pipeline.
    {
        const uint8_t* addr2 = payload + 10;
        if (isWatched(addr2)) {
            acabInit(&d, ACAB_WATCHED, SRC_WIFI, addr2, (int16_t)rssi);
            d.method     = M_WATCHLIST;   // exact-MAC user rule; NOT M_OUI, so durability leaves it at 100
            d.confidence = 100;
            handleDetection(d);
            return;
        }
    }
    // Desert mode (LAST): catch every remaining mgmt-frame source as a "nearby device".
    if (desertClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
}

// Channel 6 is the OpenDroneID Wi-Fi "social" channel - Remote-ID NAN/beacon
// frames live there, and sky-spy just parks on it for drones. A plain 1..13 sweep
// would sit on ch6 only ~8% of the time and miss a drone we drive past. So this
// sequence comes back to ch6 between every step (~50% dwell) while still touching
// all 13 (and favouring the 1/6/11 non-overlappers). That keeps Flock Wi-Fi
// covered too, since it can sit anywhere.
static const uint8_t WIFI_HOP_SEQ[] = {
    6, 1, 6, 11, 6, 2, 6, 3, 6, 4, 6, 5, 6, 7, 6, 8, 6, 9, 6, 10, 6, 12, 6, 13
};
static const int WIFI_HOP_SEQ_LEN = sizeof(WIFI_HOP_SEQ) / sizeof(WIFI_HOP_SEQ[0]);

// WiFi eco: seconds of promiscuous-OFF sleep inserted after each full channel sweep. 0 = off
// (continuous). Only 0/3/7/15 are offered; the setter snaps a stray value to the ladder so a bad
// write can't make a weird duty cycle. See the header for the tradeoff.
static volatile int gWifiEcoSec = 0;
static const char* WIFI_ECO_NS = "acab-wifi";
void acabScannerSetWifiEco(int sec) {
    int v = (sec <= 0) ? 0 : (sec <= 5) ? 3 : (sec <= 11) ? 7 : 15;
    gWifiEcoSec = v;
    Preferences p; p.begin(WIFI_ECO_NS, false); p.putInt("eco", v); p.end();
}
int acabScannerWifiEco() { return gWifiEcoSec; }
static void restoreWifiEco() {
    Preferences p; p.begin(WIFI_ECO_NS, true); gWifiEcoSec = p.getInt("eco", 0); p.end();
#ifdef ACAB_CAPTURE_BUILD
    // Announce the mismatch once, in the capture log itself, so an operator who sees the app
    // report eco>0 knows why the RX never actually sleeps (see wifiHopTask).
    if (gWifiEcoSec > 0)
        Serial.printf("[capture] stored wifiEco=%ds IGNORED - capture builds never sleep the WiFi RX\n",
                      (int)gWifiEcoSec);
#endif
}

static void wifiHopTask(void*) {
    int idx = 0;
    for (;;) {
        if (gCfg.wifiChannelHop) {
            esp_wifi_set_channel(WIFI_HOP_SEQ[idx], WIFI_SECOND_CHAN_NONE);
            idx++;
            if (idx >= WIFI_HOP_SEQ_LEN) {
                idx = 0;
                // A full channel sweep just finished. If eco is on, drop the WiFi RX for
                // gWifiEcoSec before the next sweep - this is where the battery is saved (the
                // promiscuous RX is the board's biggest single draw). BLE keeps running throughout.
                // Skip while the WiFi toggle is off (its own promiscuous(false) owns the radio then),
                // and re-check both flags every 100ms so a config change interrupts the sleep early.
#ifdef ACAB_CAPTURE_BUILD
                // Capture builds never sleep the receiver. The NVS eco level survives the
                // reflash from a shipping image, and honoring it here would punch eco-sized
                // holes in the exact firehose this build exists to record. The stored value
                // is left alone (and still shows in the app) for the shipping image later.
                const int eco = 0;
#else
                int eco = gWifiEcoSec;
#endif
                if (eco > 0 && gWifiEnabled) {
                    if (gWifiModeMux) xSemaphoreTake(gWifiModeMux, portMAX_DELAY);
                    const bool shouldSleep = gWifiEnabled && gWifiEcoSec > 0;
                    if (shouldSleep) esp_wifi_set_promiscuous(false);
                    if (gWifiModeMux) xSemaphoreGive(gWifiModeMux);
                    if (!shouldSleep) continue;
                    uint32_t until = millis() + (uint32_t)eco * 1000;
                    while ((int32_t)(millis() - until) < 0 && gWifiEcoSec > 0 && gWifiEnabled)
                        vTaskDelay(pdMS_TO_TICKS(100));
                    // The app toggle may have run after the loop condition was last read. Holding
                    // the same mutex for the final check plus driver call makes the desired flag
                    // and actual radio state one transition: eco can never re-arm over WiFi-off.
                    if (gWifiModeMux) xSemaphoreTake(gWifiModeMux, portMAX_DELAY);
                    if (gWifiEnabled) esp_wifi_set_promiscuous(true);
                    if (gWifiModeMux) xSemaphoreGive(gWifiModeMux);
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(gCfg.wifiHopIntervalMs));
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
AcabScannerConfig acabScannerDefaults() {
    AcabScannerConfig c;
    c.enableBLE        = true;
    c.enableWiFi       = true;
    c.initNimBLE       = true;
    c.bleDeviceName    = "ACAB";
    c.wifiChannelHop   = true;
    c.wifiFixedChannel = 6;
    c.wifiHopIntervalMs= 300;
    c.dedupWindowMs    = 60000;
    return c;
}

void acabScannerSetSelfGPS(double lat, double lon, bool valid) {
    gSelfLat = lat; gSelfLon = lon; gSelfGPSValid = valid;
}

bool acabScannerBlockCaptureForOwnerSession() {
    // Reserve the det_log epoch first, then publish NO admissible scanner token while prior-owner
    // GPS/config privacy preparation runs. An item queued in either publication window is refused:
    // before this store det_log is already blocked; afterward its claim carries the zero sentinel.
    const uint32_t nextAdmissionEpoch = detLogBlockCaptureForOwnerSession();
    portENTER_CRITICAL(&gDedupMux);
    gPendingAdmissionEpoch = nextAdmissionEpoch;
    gAdmissionEpoch = 0;
    portEXIT_CRITICAL(&gDedupMux);
    return nextAdmissionEpoch != 0;
}

bool acabScannerAdmitCaptureForOwnerSession() {
    uint32_t pending;
    portENTER_CRITICAL(&gDedupMux);
    pending = gPendingAdmissionEpoch;
    portEXIT_CRITICAL(&gDedupMux);
    if (pending == 0 || !detLogAdmitCaptureForOwnerSession(pending)) return false;

    // det_log is now open for this exact owner token. Publish it only after the service has made
    // gConnected=true; a claim stamped in the tiny window before this store still carries 0 and
    // is discarded rather than inheriting pre-authentication GPS/state.
    portENTER_CRITICAL(&gDedupMux);
    if (gPendingAdmissionEpoch != pending) {
        gAdmissionEpoch = 0;
        portEXIT_CRITICAL(&gDedupMux);
        return false;
    }
    gAdmissionEpoch = pending;
    gPendingAdmissionEpoch = 0;
    portEXIT_CRITICAL(&gDedupMux);
    return true;
}

// Finish the two-phase disconnect boundary: publish the already-reserved away-session epoch and
// bump the generation so the next sighting of every device buffers once more. onDisconnect calls
// Block before publishing connection teardown, then calls this only after GPS/replay/key cleanup.
bool acabScannerReArmCapture(volatile bool* ownerCaptureBlocked) {
    if (!ownerCaptureBlocked) return false;
    uint32_t pending;
    portENTER_CRITICAL(&gDedupMux);
    pending = gPendingAdmissionEpoch;
    portEXIT_CRITICAL(&gDedupMux);

    // Ordinarily Block already advanced det_log and left this exact token closed. Admit it only
    // after all link-owned state has been torn down. The fallback repairs a failed/missing reserve
    // without ever treating an unchanged token as live; both det_log calls return a zero/failure
    // sentinel if their owner-delivery or flash-state lock cannot be acquired.
    uint32_t nextAdmissionEpoch = 0;
    if (pending != 0) {
        if (detLogAdmitCaptureForOwnerSession(pending)) nextAdmissionEpoch = pending;
    } else {
        nextAdmissionEpoch = detLogAdvanceCaptureEpoch();
    }

    // Scanner ingest takes this same lock when it snapshots capture generation + admission epoch.
    // Publishing both together closes the old race: nothing can claim the NEW away generation
    // while connected still reads true, receive NOT_ARMED, and stay consumed for the away session.
    bool published = false;
    portENTER_CRITICAL(&gDedupMux);
    gCaptureGen++;
    if (gPendingAdmissionEpoch == pending) {
        gAdmissionEpoch = nextAdmissionEpoch;
        gPendingAdmissionEpoch = 0;
        if (nextAdmissionEpoch != 0) {
            // This store must remain inside gDedupMux and AFTER both publications. Radio ingest
            // uses the same lock, so it cannot claim the new generation until the service-side
            // connected gate is false as well. On failure the caller's true value is untouched.
            *ownerCaptureBlocked = false;
            published = true;
        }
    } else {
        // A superseding owner boundary is not expected because NimBLE serializes its callbacks,
        // but never publish a completion against the wrong reservation if that invariant changes.
        gAdmissionEpoch = 0;
    }
    portEXIT_CRITICAL(&gDedupMux);
    return published;
}

static void rearmCaptureCadenceOnly() {
    portENTER_CRITICAL(&gDedupMux);
    gCaptureGen++;
    portEXIT_CRITICAL(&gDedupMux);
}

// How often "record everything" re-arms capture. This is the resolution of the answer the mode
// exists to give: at 15 minutes, a vehicle that stops by on Monday and again on Thursday writes
// two records instead of one, and a device parked in range all week writes one row per window so
// its dwell is visible rather than collapsed to a single first-sighting point.
//
// THIS IS A TARGET, NOT A GUARANTEED CADENCE, and the firmware must not be read as promising one.
// The interval only bounds re-admission for a device that KEEPS ITS DEDUP ENTRY. dedupFind evicts
// the oldest ACAB_NEARBY_DEVICE first under table pressure and sets slot->loggedGen = 0 on reuse,
// so in a busy environment a device evicted and re-admitted buffers again on its very next advert,
// no matter how recently it last wrote. In a 256-entry table the real write rate is set by THRASH,
// not by this constant. Quiet, stationary sites are where the interval actually governs, which is
// the only environment this mode is for.
//
// Capacity at N=5, stated with that caveat. Ring = 0x180000 / 64 = 24576 slots. Five STABLE-MAC
// devices continuously in range for a week cost 1 admission + 671 re-arms each = 3360 records,
// about 14%. That is roughly 2x optimistic for phones: a randomized MAC rotates about every 15
// minutes, the SAME period as this interval, so each rotation mints a fresh dedup key that pays an
// admission and then a re-arm, call it ~1344 per phone per week, ~27% at N=5. Under table thrash
// there is no useful upper bound at all. The ring-full guard in detLogAppend is what actually
// bounds the bad case, and it sets the persisted saturation flag when it fires.
static const uint32_t REBUFFER_AFTER_MS = 15UL * 60UL * 1000UL;

// Periodic re-arm for "record everything". Call from the main loop; cheap and self-throttling.
//
// WHY A GLOBAL TICK RATHER THAN A PER-DEVICE TIMESTAMP. Adding a lastLoggedMs to DedupEntry would
// mean the failed-enqueue rollback in sink_claim.h has to restore it too, or a dropped record
// would leave the device looking recently-buffered with nothing written - a time-based rerun of
// the exact evidence-loss defect that header exists to prevent, and one its host tests would not
// catch because the field would not be part of the claim. Bumping gCaptureGen instead re-arms
// every device through machinery that is already correct and already tested.
//
// Deliberately gated on the app being AWAY: detLogAppend refuses to write while a phone is
// connected, so re-arming then would only churn the generation counter and enqueue sink items
// that do nothing.
void acabScannerBufferAllTick() {
    // The phase RESETS on every early return, which matters on the connected branch. If it froze
    // instead, then a long app session would leave (now - lastReArm) already past the interval at
    // the moment the link drops: the disconnect handler bumps the generation, and within one loop
    // pass (~20 ms) this tick would bump it AGAIN, re-arming any device that had claimed inside
    // that crack and writing a duplicate ring record. Small, but a duplicate produced by a race is
    // exactly the class sink_claim.h's ABA guard exists to prevent, so do not "optimize" the reset
    // away. Zeroing here also re-uses the sentinel below to re-phase from the disconnect, leaving
    // the disconnect handler's own re-arm as the single bump for that event.
    static uint32_t lastReArm = 0;
    if (!detLogBufferAll() || acabBleClientConnected()) { lastReArm = 0; return; }
    const uint32_t now = millis();
    if (lastReArm == 0) { lastReArm = now; return; }   // first call sets the phase, never fires
    if (now - lastReArm < REBUFFER_AFTER_MS) return;
    lastReArm = now;
    rearmCaptureCadenceOnly();
}

// Single-writer discipline for the co-processor UART line stream. gCmdSink lines are emitted
// from the NimBLE host task (S0/S1 via config writes, DUMP/BCLR) AND the loop task (the
// deferred ignore mirror below, otaQuiesce's radio restore via the OTA watchdog), and two
// tasks inside Serial1.println at once can interleave bytes mid-line. Held per line only.
static SemaphoreHandle_t gCmdSinkMux = nullptr;
static void cmdSinkLine(const char* line) {
    if (!gCmdSink) return;
    if (gCmdSinkMux) xSemaphoreTake(gCmdSinkMux, portMAX_DELAY);
    gCmdSink(line);
    if (gCmdSinkMux) xSemaphoreGive(gCmdSinkMux);
}

// Deferred nRF ignore-list mirror (dual-radio). acabScannerSetIgnoreList runs inside the GATT
// config-write callback on the NimBLE host task, and streaming one paced 'IA' line per MAC
// there stalled every GATT op ~300ms on a full 256-entry list (the apps re-push the whole
// list on every single toggle). The commit now snapshots the sorted list here (its own buffer:
// gMacSortScratch is reused by the watchlist path) and acabScannerMirrorTick streams it from
// the loop task. A re-commit mid-stream atomically replaces the snapshot and restarts with a
// fresh 'IC', so a quick ignore-then-unignore never leaves the nRF filtering (= not
// forwarding) a MAC the user just un-ignored.
static uint8_t       gMirrorList[ACAB_IGNORE_MAX][6];
static int           gMirrorCount  = 0;
static int           gMirrorPos    = -1;    // -1 = 'IC' not yet sent; else next gMirrorList index
static volatile bool gMirrorActive = false;
static portMUX_TYPE  gMirrorMux    = portMUX_INITIALIZER_UNLOCKED;
static const int     MIRROR_LINES_PER_TICK = 8;   // ~160B/pass: well inside the nRF's 2KB ring

// Pump the deferred mirror: a few lines per loop pass (via acabBleDrainTick). No-op unless a
// commit is in flight, so single-radio builds pay one flag test.
void acabScannerMirrorTick() {
    if (!gCmdSink || !gMirrorActive) return;
    for (int i = 0; i < MIRROR_LINES_PER_TICK; i++) {
        bool ic = false, ia = false;
        uint8_t mac[6];
        portENTER_CRITICAL(&gMirrorMux);
        if (gMirrorActive) {
            if (gMirrorPos < 0)                 { ic = true; gMirrorPos = 0; }
            else if (gMirrorPos < gMirrorCount) { memcpy(mac, gMirrorList[gMirrorPos], 6); gMirrorPos++; ia = true; }
            else                                gMirrorActive = false;   // snapshot fully mirrored
        }
        portEXIT_CRITICAL(&gMirrorMux);
        if (ic) cmdSinkLine("IC");
        else if (ia) {
            char line[24];
            snprintf(line, sizeof(line), "IA %02X%02X%02X%02X%02X%02X",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
            cmdSinkLine(line);
        } else return;
        // pace the burst: a back-to-back 256-line stream can outrun the nRF's 2 KB RX
        // ring before its loop drains it. delay(1) opens a wire gap between lines;
        // Serial1.flush() would NOT help (it only waits on local TX, adds no gap).
        delay(1);
    }
}

// Publish the co-processor's ignore mirror as (ignore MINUS watch).
//
// WHY THE SUBTRACTION. handleDetection() lets a starred MAC through even when it is also on the
// ignore list ("watchlist beats the ignore drop"). On the SHIPPING dual-radio board that rule was
// unreachable for BLE: cfg.enableBLE is false there (the S3 does WiFi only), every advert arrives
// over UART from the nRF, and the nRF drops ignore-listed MACs before forwarding
// (nrf-ble-scan/src/main.cpp scan_callback). The advert never reached the ESP32, so the rule the
// comment describes could never run. Both apps enforce star/ignore exclusivity, which is why this
// never showed up in testing, but the lists persist per-board and are re-pushed per-phone: phone A
// ignoring a MAC and phone B starring it lands both entries on the same board.
//
// Filtering here rather than teaching the nRF about the watchlist keeps the co-processor protocol
// unchanged (no second mirrored list, no nRF reflash) and keeps ONE definition of the rule.
//
// THE SINGLE PUBLISHER. Every write of gMirrorList goes through here, from all THREE callers: both
// list setters (GATT config-write task) and acabScannerResyncCoProc (loop task, on every nRF boot).
// An earlier version of this let the resync path re-seed the mirror from the raw gIgnore list,
// which silently undid the subtraction on every co-processor reset - including the RESET the S3
// pulses in its own setup(), so the filtered mirror was gone before the board finished booting.
//
// LOCKING. The whole merge runs under gIgnoreMux -> gWatchMux -> gMirrorMux, in that order. That
// is a superset of the only nesting the file already had (gIgnoreMux -> gMirrorMux), so the order
// stays globally consistent and there is no deadlock. Building OUTSIDE the muxes and merely
// clearing gMirrorActive first is NOT sufficient: clearing the flag holds off acabScannerMirrorTick
// but not the resync path, which is a second writer of the same buffer on a different task. Every
// caller releases its own list mux before calling, so this cannot self-deadlock. The walk is a
// sorted merge (<=512 six-byte compares, bounded), the same order of magnitude as the 1536-byte
// memcpy the previous code already did with interrupts disabled.
static void publishIgnoreMirror() {
    if (!gCmdSink) return;
    portENTER_CRITICAL(&gIgnoreMux);
    portENTER_CRITICAL(&gWatchMux);
    portENTER_CRITICAL(&gMirrorMux);
    int n = 0, wi = 0;
    for (int i = 0; i < gIgnoreCount && n < ACAB_IGNORE_MAX; i++) {
        while (wi < gWatchCount && memcmp(gWatch[wi], gIgnore[i], 6) < 0) wi++;
        if (wi < gWatchCount && memcmp(gWatch[wi], gIgnore[i], 6) == 0) continue;   // starred: keep forwarding
        memcpy(gMirrorList[n++], gIgnore[i], 6);
    }
    gMirrorCount  = n;
    gMirrorPos    = -1;      // restart: fresh 'IC', then the new snapshot
    gMirrorActive = true;
    portEXIT_CRITICAL(&gMirrorMux);
    portEXIT_CRITICAL(&gWatchMux);
    portEXIT_CRITICAL(&gIgnoreMux);
}

void acabScannerSetIgnoreList(const uint8_t macs[][6], int count) {
    if (count < 0) count = 0;
    if (count > ACAB_IGNORE_MAX) count = ACAB_IGNORE_MAX;
    // sort a scratch copy OFF the lock (qsort must not run with interrupts disabled), then
    // publish it under the mux with one memcpy - same lock cost as before, but the radio
    // path can now binary-search it.
    for (int i = 0; i < count; i++) memcpy(gMacSortScratch[i], macs[i], 6);
    qsort(gMacSortScratch, count, 6, macCmp);
    portENTER_CRITICAL(&gIgnoreMux);
    if (count > 0) memcpy(gIgnore, gMacSortScratch, (size_t)count * 6);
    gIgnoreCount = count;
    portEXIT_CRITICAL(&gIgnoreMux);
    saveIgnoreList();   // persist outside the critical section - NVS writes are slow

    // Dual-radio: mirror the whitelist to the co-processor so it can skip forwarding
    // ignored MACs (the ESP32 still filters them regardless - this only trims UART).
    // DEFERRED to acabScannerMirrorTick (see above): pacing the burst here, on the NimBLE
    // host task, stalled all GATT traffic for the whole stream.
    publishIgnoreMirror();
}

void acabScannerSetWatchList(const uint8_t macs[][6], int count) {
    if (count < 0) count = 0;
    if (count > ACAB_WATCH_MAX) count = ACAB_WATCH_MAX;
    // sort off the lock, then publish under the mux (see acabScannerSetIgnoreList) so the
    // radio path can binary-search the watchlist.
    for (int i = 0; i < count; i++) memcpy(gMacSortScratch[i], macs[i], 6);
    qsort(gMacSortScratch, count, 6, macCmp);
    portENTER_CRITICAL(&gWatchMux);
    if (count > 0) memcpy(gWatch, gMacSortScratch, (size_t)count * 6);
    gWatchCount = count;
    portEXIT_CRITICAL(&gWatchMux);
    saveWatchList();   // persist outside the critical section - NVS writes are slow
    // The watchlist itself is never mirrored: the watch check runs on the ESP32 over the same
    // classifier chain the dual-radio UART path feeds, so a FORWARDED advert is matched regardless.
    // But the ignore mirror is (ignore MINUS watch), so starring a MAC has to rebuild it - else the
    // nRF keeps dropping the advert and it is never forwarded at all. See publishIgnoreMirror().
    publishIgnoreMirror();
}

uint32_t acabScannerTotalDetections() { return gTotal; }
uint32_t acabScannerBleSeen()  { return gBleSeen; }
uint32_t acabScannerWifiSeen() { return gWifiSeen; }
uint32_t acabScannerSinkDropDeliverOnly() { return gSinkDropDeliverOnly.load(std::memory_order_relaxed); }
uint32_t acabScannerSinkDropBuffered()    { return gSinkDropBuffered.load(std::memory_order_relaxed); }
uint32_t acabScannerSinkDropReplay()      { return gSinkDropReplay.load(std::memory_order_relaxed); }
uint32_t acabScannerSinkHighWater()       { return gSinkHighWater.load(std::memory_order_relaxed); }
uint32_t acabScannerSinkDropTotal() {
    // Valid as a plain sum: the three categories are exclusive by construction (one enqueue takes
    // exactly one branch), so nothing is double-counted.
    return acabScannerSinkDropDeliverOnly() + acabScannerSinkDropBuffered() + acabScannerSinkDropReplay();
}

// Co-processor (nRF) stats, fed by the dual-radio UART path.
static std::atomic<uint32_t> gCoAdv{0}, gCoFwd{0}, gCoBb{0};
static std::atomic<uint32_t> gCoLastRx{0};   // millis() of the last nRF UART line (0 = never)
static volatile bool gCoScan = false, gHasCo = false;
// Liveness window: the nRF sends a "D" heartbeat every 5s plus adverts, so ~15s of total
// silence means the co-processor radio is dead and the BLE-detection half has gone dark.
static const uint32_t kCoProcTimeoutMs = 15000;
// Startup grace after an S3 boot (millis() from reset). Right after a reboot - most importantly the
// reboot at the END of an OTA - the nRF still has to reset, boot and send its first UART line (the
// S3 pulses its RESET on boot), so gCoLastRx is legitimately 0 for a few seconds. Report the
// co-processor as alive through this window so a normal reboot never flashes the "nRF radio fault"
// banner on a healthy board (it reads as "my device broke" right after an update). Only a nRF still
// silent PAST the grace - one that never came up - is treated as a real fault. 20s comfortably
// covers S3 boot + nRF reset + nRF boot + its 5s heartbeat interval, with margin for untested
// real-PCB timing (erring long here just delays a genuine dead-nRF warning by a few seconds; erring
// short reintroduces the exact false banner we are killing).
static const uint32_t kCoProcBootGraceMs = 20000;
void acabScannerSetCoProcStats(uint32_t a, uint32_t f, bool s, uint32_t bb) { gCoAdv = a; gCoFwd = f; gCoScan = s; gCoBb = bb; gHasCo = true; }
void     acabScannerNoteCoProcRx()    { gCoLastRx = millis(); }
bool     acabScannerHasCoProc()       { return gHasCo; }
bool     acabScannerCoProcAlive() {
    // A dead nRF used to look alive: gHasCo latched true on the first stats line and never
    // cleared. Gate on recency instead - once heard, going silent past the timeout reads as a fault.
    uint32_t last = gCoLastRx;
    if (!gHasCo || last == 0) {
        // Never heard from the co-processor yet. Hold "alive" through the boot grace so a fresh S3
        // reboot (notably the one at the end of an OTA) does not flash a radio-fault banner while
        // the nRF is still resetting/booting/re-syncing. A nRF that never speaks by the end of the
        // grace is a genuine fault and falls through to false below.
        if (millis() < kCoProcBootGraceMs) return true;
        return false;
    }
    return (millis() - last) <= kCoProcTimeoutMs;
}
uint32_t acabScannerCoProcAdvSeen()   { return gCoAdv; }
uint32_t acabScannerCoProcForwarded() { return gCoFwd; }
bool     acabScannerCoProcScanning()  { return gCoScan; }
uint32_t acabScannerCoProcBbCount()   { return gCoBb; }
void     acabScannerSendCoProcCmd(const char* cmd) { cmdSinkLine(cmd); }

// Re-assert everything the co-processor holds only in RAM. The nRF loses its scan on/off state
// and its whole ignore-list mirror on ANY reset (power blip, WDT, and most visibly a BLE DFU),
// and we used to push both exactly once, so it came back scanning at its default with an empty
// ignore list and nothing ever corrected it. The nRF announces "V<n>" on every boot, so the
// dual-radio UART parser calls this from that branch: cheap, idempotent, and it also covers the
// first boot, where the ignore list is restored from NVS and was never mirrored at all.
// Single-radio builds have no cmd sink, so this is a no-op there.
void acabScannerResyncCoProc() {
    if (!gCmdSink) return;
    cmdSinkLine(gBleEnabled ? "S1" : "S0");   // same line acabScannerSetBLE emits
    // Re-seed the mirror snapshot from the live lists and restart the deferred stream: gMirrorPos
    // = -1 makes acabScannerMirrorTick send a fresh 'IC' and then the paced 'IA' burst from the
    // loop task. Goes through publishIgnoreMirror so the nRF gets (ignore MINUS watch) here too.
    // This used to memcpy the RAW gIgnore list, which re-armed the co-processor to drop starred
    // MACs on every single nRF boot - the filtered mirror never survived to steady state.
    publishIgnoreMirror();
}

uint32_t acabScannerIgnoreCount() { return (uint32_t)gIgnoreCount; }
uint32_t acabScannerWatchCount()  { return (uint32_t)gWatchCount; }

void acabScannerSetBLE(bool on) {
    gBleEnabled = on;
    if (gScan && !on) gScan->stop();    // cut the in-flight 2 s window short
    cmdSinkLine(on ? "S1" : "S0");      // dual-radio: tell the nRF to scan / stop
}
void acabScannerSetWiFi(bool on) {
    if (gWifiModeMux) xSemaphoreTake(gWifiModeMux, portMAX_DELAY);
    gWifiEnabled = on;
    esp_wifi_set_promiscuous(on);        // stop feeding the RX callback at all
    if (gWifiModeMux) xSemaphoreGive(gWifiModeMux);
}
// Recompute + reinstall the promiscuous filter (see applyWifiPromiscFilter). Called by
// netcamSetEnabled() when the camera opt-in flips, so the data-frame firehose is delivered
// only while the toggle is on. Guarded on WiFi being configured: before acabScannerBegin
// (netcam restore/config can run first) there is no promiscuous mode yet, so skip - Begin
// installs the filter from the current toggle state itself.
void acabScannerRefreshWifiFilter() {
    if (!gCfg.enableWiFi) return;
    applyWifiPromiscFilter();
}
bool acabScannerBLEEnabled()  { return gBleEnabled; }
bool acabScannerWiFiEnabled() { return gWifiEnabled; }
bool acabScannerHealthy()     { return gScannerReady; }
void acabScannerSetCmdSink(AcabCmdSink sink) {
    if (sink && !gCmdSinkMux) gCmdSinkMux = xSemaphoreCreateMutex();   // per-line writer lock (see cmdSinkLine)
    gCmdSink = sink;
}

// Bring up both radios per cfg, register the sink, and launch the scanner tasks.
void acabScannerBegin(const AcabScannerConfig& cfg, AcabDetectionSink sink) {
    gScannerReady = false;
    gCfg  = cfg;
    gSink = sink;
    memset(gDedup, 0, sizeof(gDedup));
    memset(gDedupBucket, 0xFF, sizeof(gDedupBucket));   // all buckets empty (-1); no chain refs the zeroed entries
    gTotal = gBleSeen = gWifiSeen = 0;
    gBleEnabled = gWifiEnabled = true;
    restoreWifiEco();   // honor a persisted eco level from the first sweep
    loadIgnoreList();   // restore the persisted whitelist before any frame arrives
    loadWatchList();    // restore the persisted starred-device watchlist too

    // Reset the drop accounting for this session, so a counter can never read as the sum of two
    // power cycles (acabScannerBegin is the one entry point that starts a capture session).
    gSinkDropDeliverOnly.store(0, std::memory_order_relaxed);
    gSinkDropBuffered.store(0, std::memory_order_relaxed);
    gSinkDropReplay.store(0, std::memory_order_relaxed);
    gSinkHighWater.store(0, std::memory_order_relaxed);

    // One sink task drains detections from both radios (see SinkItem above).
    //
    // BOTH RETURNS ARE CHECKED, and failure is fatal rather than tolerated. An unchecked failure
    // here is the worst shape this codebase has: a null queue makes every enqueue a silent no-op,
    // and a created queue with no task to drain it fills once and then swallows everything
    // forever - both look exactly like "nothing is out there" to the user, which is the one lie
    // this product must never tell. Announce and restart; do not limp.
    gSinkQ = xQueueCreate(ACAB_SINK_Q_LEN, sizeof(SinkItem));
    if (!gSinkQ) {
        Serial.println("[fatal] sink queue alloc failed - restarting");
        delay(250); ESP.restart();
    }
    if (xTaskCreatePinnedToCore(sinkTask, "acabSink", 8192, nullptr, 1, nullptr, 1) != pdPASS) {
        Serial.println("[fatal] sink task create failed - restarting");
        delay(250); ESP.restart();
    }

    if (cfg.enableWiFi) {
        if (!gWifiModeMux) gWifiModeMux = xSemaphoreCreateMutex();
        if (!gWifiModeMux) {
            Serial.println("[fatal] WiFi mode mutex alloc failed - restarting");
            delay(250); ESP.restart();
        }
        WiFi.mode(WIFI_STA);
        WiFi.disconnect();
        esp_wifi_set_promiscuous(true);
        // Install the frame filter: MGMT-only in production, widened to DATA only when the
        // network-camera opt-in is on (or a diag build). netcamRestoreEnabled() already ran
        // in main() before this, so a persisted opt-in is honored from the first frame.
        applyWifiPromiscFilter();
        esp_wifi_set_promiscuous_rx_cb(&wifiRxCallback);
        esp_wifi_set_channel(cfg.wifiChannelHop ? 6 : cfg.wifiFixedChannel,
                             WIFI_SECOND_CHAN_NONE);
        if (xTaskCreatePinnedToCore(wifiHopTask, "acabWifiHop", 4096, nullptr, 1, nullptr, 0) != pdPASS) {
            Serial.println("[fatal] wifi hop task create failed - restarting");
            delay(250); ESP.restart();
        }
#ifdef ACAB_DIAG_WIFI
        gWifiDiagQ = xQueueCreate(64, sizeof(WifiDiagItem));
        if (!gWifiDiagQ ||
            xTaskCreatePinnedToCore(wifiDiagTask, "acabWifiDiag", 4096, nullptr, 1, nullptr, 0) != pdPASS) {
            Serial.println("[fatal] wifi diag task create failed - restarting");
            delay(250); ESP.restart();
        }
#endif
    }

    if (cfg.enableBLE) {
        if (cfg.initNimBLE && !NimBLEDevice::getInitialized()) {
            NimBLEDevice::init(cfg.bleDeviceName ? cfg.bleDeviceName : "ACAB");
        }
        // hush the lib's warnings about zero-length adverts we ignore anyway
        esp_log_level_set("NimBLEAdvertisedDevice", ESP_LOG_NONE);

        gScan = NimBLEDevice::getScan();
        gScan->setAdvertisedDeviceCallbacks(new AcabAdvCallbacks(), /*wantDuplicates=*/true);
        // PERF-1: don't RETAIN scanned devices. wantDuplicates=true already feeds the callback
        // every advert (which is all we consume), but the library ALSO stores each distinct
        // device in its results vector; at the default maxResults (0xFF) that vector grows and
        // pins memory over a long session. 0 = keep nothing - the callback consumed it already.
        gScan->setMaxResults(0);
        // PASSIVE scan by default: active scanning transmits a SCAN_REQ (carrying our own
        // address) to every advertiser heard , including the gear being detected , which
        // contradicts the passive product claim. Detectors key on primary-advert payloads;
        // only scan-response device names are lost. Field-capture/dev builds may re-enable
        // with -DACAB_ACTIVE_SCAN (never ship it).
#ifdef ACAB_ACTIVE_SCAN
        gScan->setActiveScan(true);      // CAPTURE BUILD: RF-loud, fingerprintable
#else
        gScan->setActiveScan(false);
#endif
        gScan->setInterval(131);  // ~82 ms, prime to dodge sync; ~51% duty (down from 97/69%)
        gScan->setWindow(67);     // so WiFi promiscuous isn't starved on the shared radio
        if (xTaskCreatePinnedToCore(bleScanTask, "acabBleScan", 12288, nullptr, 1,
                                    nullptr, 1) != pdPASS) {
            Serial.println("[fatal] BLE scan task create failed - restarting");
            delay(250); ESP.restart();
        }
    }
    gScannerReady = true;
}
